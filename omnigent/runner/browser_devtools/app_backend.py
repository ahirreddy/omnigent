"""The local browser backend: the session owner's Mac app and its in-app Chromium.

Chromium never opens a DevTools port. The app holds its DevTools pipe and, on
request, opens a loopback WebSocket gate in front of it whose path carries a
secret for one session; the gate shows that session only its own tabs. The
runner asks for the gate, and for the session's tabs, through the owner-only
``/v1/sessions/{id}/browser/devtools_request`` relay, then connects straight to
``127.0.0.1``. Only a runner on the same Mac reaches the gate, which proves the
runner shares the Mac. The secret is never logged.
"""

from __future__ import annotations

import logging
import re
from collections.abc import Mapping
from typing import Final, cast

import httpx
from websockets.exceptions import InvalidHandshake, InvalidStatus

from omnigent.runner.browser_devtools.directory import (
    AgentTabState,
    ScopedTab,
    TabDirectoryError,
    TabOwner,
)
from omnigent.runner.browser_devtools.server import (
    BIND_HOST,
    BrowserBackend,
    BrowserUnavailableError,
    connect_upstream,
)

_logger = logging.getLogger(__name__)

# Each listing is a round trip through the server to the app, so poll gently.
_APP_REFRESH_INTERVAL_S: Final[float] = 2.0
# The server waits 2 s for a claim and 30 s for the app's answer.
_RELAY_TIMEOUT = httpx.Timeout(40.0, connect=10.0)
# The gate's path: a fixed prefix and the session's 256-bit secret in hex.
_GATE_PATH: Final[re.Pattern[str]] = re.compile(r"/devtools/browser/[0-9a-f]{64}")


def _scoped_tab(record: Mapping[str, object]) -> ScopedTab:
    owner = record.get("owner")
    return ScopedTab(
        tab_id=str(record.get("tab_id") or ""),
        target_id=str(record.get("target_id") or ""),
        url=str(record.get("url") or ""),
        title=str(record.get("title") or ""),
        owner=cast(TabOwner, owner) if owner in ("agent", "user") else "agent",
    )


async def devtools_request(
    server_client: httpx.AsyncClient,
    session_id: str,
    op: str,
    args: Mapping[str, object] | None = None,
) -> dict[str, object]:
    """Send one directory operation to the session owner's app and return its data.

    :param op: e.g. ``"tabs.list"``.
    :returns: The app's ``data`` object.
    :raises TabDirectoryError: When no app answered, or it refused.
    """
    try:
        response = await server_client.post(
            f"/v1/sessions/{session_id}/browser/devtools_request",
            json={"op": op, "args": dict(args or {})},
            timeout=_RELAY_TIMEOUT,
        )
        response.raise_for_status()
        result = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        raise TabDirectoryError(f"The Mac app could not be asked ({op}): {exc}") from exc
    if not isinstance(result, dict):
        raise TabDirectoryError(f"The Mac app answered {op} with {result!r}.")
    if result.get("ok") is not True:
        detail = result.get("message") or result.get("error") or "no answer"
        raise TabDirectoryError(f"The Mac app's browser did not answer {op}: {detail}")
    data = result.get("data")
    return cast(dict[str, object], data) if isinstance(data, dict) else {}


class AppTabDirectory:
    """One session's tabs in the owner's Mac app.

    :param server_client: The runner's authenticated server client.
    :param session_id: The session, e.g. ``"conv_abc123"``.
    """

    def __init__(self, server_client: httpx.AsyncClient, session_id: str) -> None:
        self._server_client = server_client
        self._session_id = session_id

    @property
    def refresh_interval_s(self) -> float:
        """Poll interval while an agent is connected."""
        return _APP_REFRESH_INTERVAL_S

    async def list_tabs(self) -> list[ScopedTab]:
        """List the session's browser tabs in the app."""
        data = await devtools_request(self._server_client, self._session_id, "tabs.list")
        tabs = data.get("tabs")
        if not isinstance(tabs, list):
            raise TabDirectoryError("The Mac app answered tabs.list without a tab list.")
        return [_scoped_tab(tab) for tab in tabs if isinstance(tab, dict)]

    async def create_tab(self, url: str) -> ScopedTab:
        """Open a background tab in the session's tab set."""
        data = await devtools_request(
            self._server_client, self._session_id, "tabs.create", {"url": url}
        )
        return _scoped_tab(data)

    async def close_tab(self, target_id: str) -> None:
        """Close the session's tab for *target_id*."""
        await devtools_request(
            self._server_client, self._session_id, "tabs.close", {"target_id": target_id}
        )

    async def report_agent_state(self, target_id: str, state: AgentTabState) -> None:
        """Badge the app tab and keep it rendering while the agent holds it."""
        await devtools_request(
            self._server_client,
            self._session_id,
            "tabs.agent_state",
            {"target_id": target_id, "state": state},
        )


async def app_backend(server_client: httpx.AsyncClient, session_id: str) -> BrowserBackend:
    """The owner's Mac app browser, when it runs on this machine.

    Asks the app to open its gate and connects to it, so a runner on another
    machine finds out here and the resolver can try the next browser.

    :raises BrowserUnavailableError: When no app answered, the owner turned agent
        browsing off, or the app runs on another machine.
    """
    try:
        data = await devtools_request(server_client, session_id, "attach")
    except TabDirectoryError as exc:
        raise BrowserUnavailableError(str(exc)) from exc
    port = data.get("port")
    path = data.get("path")
    if (
        not isinstance(port, int)
        or isinstance(port, bool)
        or not 0 < port < 65536
        or not isinstance(path, str)
        or not _GATE_PATH.fullmatch(path)
    ):
        raise BrowserUnavailableError("The Mac app did not report its browser's DevTools gate.")
    url = f"ws://{BIND_HOST}:{port}{path}"
    try:
        upstream = await connect_upstream(url)
    except InvalidStatus as exc:
        raise BrowserUnavailableError(
            "The Mac app's browser is not on this machine: the listener on port "
            f"{port} here refused the session (HTTP {exc.response.status_code})."
        ) from exc
    except (OSError, InvalidHandshake, TimeoutError) as exc:
        raise BrowserUnavailableError(
            "The Mac app's browser is not on this machine: nothing here answered on "
            f"port {port} ({type(exc).__name__})."
        ) from exc
    return BrowserBackend(
        upstream_url=url,
        directory=AppTabDirectory(server_client, session_id),
        kind="local",
        upstream=upstream,
    )
