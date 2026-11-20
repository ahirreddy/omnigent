"""The runner's loopback CDP endpoint for session agents.

:class:`BrowserDevtoolsService` listens on ``127.0.0.1``. Each session gets a
URL ``ws://127.0.0.1:<port>/devtools/browser/<session_id>.<mac>``, where the MAC
is an HMAC of the session id under a secret held only by this runner process.
The URL is a pure function of (secret, port, session id), so the spec loader can
compute it from a worker thread. A connection is resolved to a browser backend,
then served by :class:`~omnigent.runner.browser_devtools.session.ScopedCdpSession`.
"""

from __future__ import annotations

import asyncio
import dataclasses
import hashlib
import hmac
import logging
import secrets
from typing import TYPE_CHECKING, Final, Protocol
from urllib.parse import urlsplit

import httpx
from websockets.asyncio.client import connect as websocket_connect
from websockets.asyncio.server import Server, ServerConnection, serve
from websockets.exceptions import ConnectionClosed, InvalidHandshake, InvalidURI
from websockets.http11 import Request, Response

from omnigent.runner.browser_devtools.directory import TabDirectoryError
from omnigent.runner.browser_devtools.session import (
    CdpCommandError,
    ScopedCdpSession,
    serve_unavailable,
)

if TYPE_CHECKING:
    from omnigent.runner.browser_devtools.directory import TabDirectory

_logger = logging.getLogger(__name__)

BIND_HOST: Final[str] = "127.0.0.1"
PATH_PREFIX: Final[str] = "/devtools/browser/"
_MAC_HEX_CHARS: Final[int] = 32
_VERSION_TIMEOUT_S: Final[float] = 5.0
# How often a connection checks that the session still selects its browser.
SELECTION_CHECK_S: Final[float] = 10.0


class BrowserUnavailableError(Exception):
    """No browser can serve the session; the message is shown to the agent.

    :param message: Why, and what would fix it.
    """


@dataclasses.dataclass(frozen=True)
class BrowserBackend:
    """A real browser and the session's view of it.

    :param upstream_url: Browser-level CDP WebSocket URL on loopback.
    :param directory: The session's tabs on that browser.
    :param kind: ``"local"`` (the Mac app) or ``"remote"`` (a browser host).
    """

    upstream_url: str
    directory: TabDirectory
    kind: str


class BackendResolver(Protocol):
    """Picks the browser a session's agent connection uses."""

    async def resolve(self, session_id: str) -> BrowserBackend:
        """Return the session's browser backend.

        :raises BrowserUnavailableError: When no browser can serve the session.
        """
        ...

    async def still_selected(self, session_id: str, kind: str) -> bool:
        """Whether the session may keep using a *kind* backend (the user may switch)."""
        ...


def session_token(secret: bytes, session_id: str) -> str:
    """The URL token for *session_id*: ``<session_id>.<mac>``."""
    digest = hmac.new(secret, session_id.encode(), hashlib.sha256).hexdigest()
    return f"{session_id}.{digest[:_MAC_HEX_CHARS]}"


def session_from_path(secret: bytes, path: str) -> str | None:
    """Return the session id a request path authorizes, or ``None``.

    :param path: The request path, e.g. ``"/devtools/browser/conv_a.1f2e..."``.
    """
    if not path.startswith(PATH_PREFIX):
        return None
    token = path[len(PATH_PREFIX) :].split("?", 1)[0]
    session_id, _, _mac = token.rpartition(".")
    if not session_id:
        return None
    expected = session_token(secret, session_id)
    if not hmac.compare_digest(expected, token):
        return None
    return session_id


async def browser_websocket_url(port: int) -> str:
    """Ask a loopback DevTools server for its browser WebSocket URL.

    :param port: The DevTools port, e.g. ``9333``.
    :returns: ``ws://127.0.0.1:<port>/devtools/browser/<id>``.
    :raises BrowserUnavailableError: When the server does not answer sensibly.
    """
    url = f"http://{BIND_HOST}:{port}/json/version"
    try:
        async with httpx.AsyncClient(timeout=_VERSION_TIMEOUT_S, trust_env=False) as client:
            response = await client.get(url)
        response.raise_for_status()
        reported = response.json().get("webSocketDebuggerUrl")
    except (httpx.HTTPError, ValueError, AttributeError) as exc:
        raise BrowserUnavailableError(
            f"The browser's DevTools port {port} did not answer: {exc}"
        ) from exc
    if not isinstance(reported, str) or not urlsplit(reported).path.startswith("/devtools/"):
        raise BrowserUnavailableError(f"The browser's DevTools port {port} gave no browser URL.")
    # Keep the literal loopback address; the browser may report another host name.
    return f"ws://{BIND_HOST}:{port}{urlsplit(reported).path}"


class BrowserDevtoolsService:
    """Owns the loopback listener and the agent connections it serves.

    :param resolver: Picks each session's browser.
    :param secret: Token secret; a fresh random one by default.
    """

    def __init__(self, resolver: BackendResolver, *, secret: bytes | None = None) -> None:
        self._resolver = resolver
        self._secret = secret or secrets.token_bytes(32)
        self.port: int | None = None
        self._server: Server | None = None
        self._start_lock = asyncio.Lock()
        self._connections: dict[str, set[ServerConnection]] = {}

    def endpoint_for(self, session_id: str) -> str:
        """The WebSocket URL that *session_id*'s agent connects to. Thread-safe.

        :raises RuntimeError: Before :meth:`ensure_started` bound the port.
        """
        if self.port is None:
            raise RuntimeError("the agent browser proxy is not listening yet")
        token = session_token(self._secret, session_id)
        return f"ws://{BIND_HOST}:{self.port}{PATH_PREFIX}{token}"

    async def ensure_started(self) -> None:
        """Bind ``127.0.0.1`` on a free port and serve it; later calls return at once.

        :raises OSError: When the loopback port cannot be bound.
        """
        async with self._start_lock:
            if self._server is None:
                self._server = await serve(
                    self._handle,
                    BIND_HOST,
                    0,
                    process_request=self._authorize,
                    max_size=None,
                    ping_interval=None,
                    compression=None,
                )
                self.port = next(iter(self._server.sockets)).getsockname()[1]

    async def stop(self) -> None:
        """Close the listener and every agent connection."""
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    async def disconnect_session(self, session_id: str) -> int:
        """Close *session_id*'s agent connections, e.g. after a browser switch.

        ``chrome-devtools-mcp`` reconnects on its next tool call and lands on the
        session's newly selected browser.

        :returns: How many connections were closed.
        """
        connections = list(self._connections.get(session_id, ()))
        for connection in connections:
            await connection.close(code=1001, reason="browser switched")
        return len(connections)

    def _authorize(self, connection: ServerConnection, request: Request) -> Response | None:
        if session_from_path(self._secret, request.path) is None:
            return connection.respond(403, "Unknown or expired DevTools URL.\n")
        return None

    async def _handle(self, connection: ServerConnection) -> None:
        request = connection.request
        session_id = session_from_path(self._secret, request.path) if request else None
        if session_id is None:  # _authorize already refused it.
            return
        peers = self._connections.setdefault(session_id, set())
        peers.add(connection)
        try:
            await self._serve(connection, session_id)
        except ConnectionClosed:
            pass  # Either side hung up: the normal end of an agent connection.
        finally:
            peers.discard(connection)
            if not peers:
                self._connections.pop(session_id, None)

    async def _serve(self, connection: ServerConnection, session_id: str) -> None:
        try:
            backend = await self._resolver.resolve(session_id)
        except BrowserUnavailableError as exc:
            _logger.info("agent browser unavailable: %s", exc, extra={"session_id": session_id})
            await serve_unavailable(connection, str(exc))
            return
        try:
            upstream = await websocket_connect(
                backend.upstream_url, max_size=None, ping_interval=None, compression=None
            )
        except (OSError, InvalidHandshake, InvalidURI, TimeoutError) as exc:
            reason = f"Could not reach the {backend.kind} browser's DevTools endpoint: {exc}"
            _logger.warning(reason, extra={"session_id": session_id})
            await serve_unavailable(connection, reason)
            return
        async with upstream:
            session = ScopedCdpSession(
                client=connection,
                upstream=upstream,
                directory=backend.directory,
                label=f"{session_id}/{backend.kind}",
            )
            watcher = asyncio.create_task(self._watch_selection(connection, session_id, backend))
            try:
                await session.run()
            except (TabDirectoryError, CdpCommandError) as exc:
                reason = f"The {backend.kind} browser could not list this session's tabs: {exc}"
                _logger.warning(reason, extra={"session_id": session_id})
                await serve_unavailable(connection, reason)
            finally:
                watcher.cancel()

    async def _watch_selection(
        self, connection: ServerConnection, session_id: str, backend: BrowserBackend
    ) -> None:
        """Close *connection* once the session switches away from *backend*'s browser.

        ``chrome-devtools-mcp`` reconnects on its next call and lands on the new choice.
        """
        while True:
            await asyncio.sleep(SELECTION_CHECK_S)
            if not await self._resolver.still_selected(session_id, backend.kind):
                _logger.info(
                    "agent browser switched away from %s",
                    backend.kind,
                    extra={"session_id": session_id},
                )
                await connection.close(code=1001, reason="browser switched")
                return
