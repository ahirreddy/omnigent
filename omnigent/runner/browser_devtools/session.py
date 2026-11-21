"""A virtual CDP browser that holds only one session's tabs.

The agent's CDP client (``chrome-devtools-mcp``'s Puppeteer) connects to the
proxy as if it were a browser. :class:`ScopedCdpSession` owns one upstream
browser connection per client. It turns on target discovery upstream for its own
bookkeeping and emulates the browser-level ``Target`` domain, so the client only
ever learns about, and attaches to, page targets the session's
:class:`~omnigent.runner.browser_devtools.directory.TabDirectory` lists (plus
popups those pages open). Browser-level auto-attach is never forwarded: the
proxy attaches to allowed pages itself, so other tabs in the profile are never
touched.
"""

from __future__ import annotations

import asyncio
import contextlib
import dataclasses
import json
import logging
import time
from collections.abc import Awaitable, Callable
from typing import Any, Final, Protocol

from omnigent.runner.browser_devtools import policy
from omnigent.runner.browser_devtools.directory import (
    AgentTabState,
    ScopedTab,
    TabDirectory,
    TabDirectoryError,
    TabOwner,
)

_logger = logging.getLogger(__name__)

JsonObject = dict[str, Any]

# Chrome's generic server error code; the message carries the reason.
CDP_SERVER_ERROR: Final[int] = -32000
_AGENT_STATE_REPORT_INTERVAL_S: Final[float] = 2.0
AGENT_IDLE_AFTER_S: Final[float] = 10.0
# The owner the proxy gates on may be this old before an actuating call
# refreshes it first.
_OWNER_MAX_AGE_S: Final[float] = 1.0
_TARGET_ID_WAIT_S: Final[float] = 5.0
# A dialog the agent dismissed while the user holds the tab opens again after this long, so
# the reopening never races the client clearing the dismissed one.
_USER_DIALOG_REOPEN_AFTER_S: Final[float] = 0.5
_TARGET_ID_POLL_S: Final[float] = 0.1
_DEFAULT_WINDOW_SIZE: Final[tuple[int, int]] = (1280, 800)


class CdpChannel(Protocol):
    """One side of a CDP WebSocket: text frames of JSON."""

    async def recv(self) -> str | bytes:
        """Return the next frame; raises when the connection closes."""
        ...

    async def send(self, message: str) -> None:
        """Send one frame."""
        ...


class CdpCommandError(Exception):
    """An upstream command answered with a CDP error.

    :param method: The command, e.g. ``"Target.attachToTarget"``.
    :param error: The CDP error object, e.g. ``{"code": -32000, "message": "..."}``.
    """

    def __init__(self, method: str, error: JsonObject) -> None:
        super().__init__(f"{method}: {error.get('message', error)}")
        self.error = error


class ClientRequestError(Exception):
    """A client request the proxy answers with a CDP error.

    :param message: The error message, e.g. ``"No target with given id found"``.
    """


@dataclasses.dataclass
class _Session:
    """A CDP session the client may use.

    :param target_id: The session's own target (a page, frame or worker).
    :param root_target_id: The allowed page the session belongs to.
    :param parent: The parent session id for a child session, else ``None``.
    """

    target_id: str
    root_target_id: str
    parent: str | None


@dataclasses.dataclass
class _ClientRequest:
    """An upstream id that answers a client request.

    :param client_id: The id the client used.
    :param session_id: The client's ``sessionId``, echoed on the response.
    :param method: The client's method, for result rewriting.
    """

    client_id: int
    session_id: str | None
    method: str


class ScopedCdpSession:
    """Serve one agent CDP connection over a fresh upstream browser connection.

    :param client: The agent's WebSocket.
    :param upstream: A browser-level CDP WebSocket to the real browser.
    :param directory: The session's tab directory on that browser.
    :param label: Text for logs, e.g. ``"conv_abc123/remote"``.
    :param clock: Monotonic clock, injectable for tests.
    """

    def __init__(
        self,
        *,
        client: CdpChannel,
        upstream: CdpChannel,
        directory: TabDirectory,
        label: str,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._client = client
        self._upstream = upstream
        self._directory = directory
        self._label = label
        self._clock = clock
        self._next_upstream_id = 1
        self._internal: dict[int, tuple[str, asyncio.Future[JsonObject]]] = {}
        self._client_requests: dict[int, _ClientRequest] = {}
        # Every upstream target (from the proxy's own discovery), by id.
        self._targets: dict[str, JsonObject] = {}
        self._listed: set[str] = set()
        self._popups: set[str] = set()
        self._announced: set[str] = set()
        self._auto_attached: set[str] = set()
        self._attaching: set[str] = set()
        self._sessions: dict[str, _Session] = {}
        self._owners: dict[str, TabOwner] = {}
        self._owners_at = float("-inf")
        self._discover = False
        self._auto_attach = False
        self._window_ids: dict[str, int] = {}
        self._window_sizes: dict[str, tuple[int, int]] = {}
        self._last_actuation: dict[str, float] = {}
        self._last_report: dict[str, float] = {}
        self._reported_active: set[str] = set()
        # Root page sessions shown the user's control as an open dialog, and when the agent
        # last dismissed one.
        self._user_dialogs: set[str] = set()
        self._user_dialog_dismissed: dict[str, float] = {}
        self._background: set[asyncio.Task[None]] = set()
        self._send_lock = asyncio.Lock()

    @property
    def allowed_targets(self) -> frozenset[str]:
        """Page targets the client may see: the session's tabs and their popups."""
        return frozenset((self._listed | self._popups) & set(self._targets))

    async def run(self) -> None:
        """Serve the client until either side closes; release the agent's tabs after."""
        reader = asyncio.create_task(self._read_upstream(), name=f"cdp-upstream:{self._label}")
        try:
            await self._command("Target.setDiscoverTargets", {"discover": True})
            await self._refresh()
            refresher = asyncio.create_task(
                self._refresh_loop(), name=f"cdp-refresh:{self._label}"
            )
            client_loop = asyncio.create_task(
                self._read_client(), name=f"cdp-client:{self._label}"
            )
            done, _pending = await asyncio.wait(
                {reader, refresher, client_loop}, return_when=asyncio.FIRST_COMPLETED
            )
            for task in (reader, refresher, client_loop):
                task.cancel()
            for task in done:
                if not task.cancelled() and (exc := task.exception()) is not None:
                    raise exc
        finally:
            reader.cancel()
            for task in list(self._background):
                task.cancel()
            await self._release_reported_tabs()

    # MARK: client side

    async def _read_client(self) -> None:
        while True:
            frame = await self._client.recv()
            try:
                message = json.loads(frame)
            except ValueError:
                _logger.warning("cdp proxy %s: client sent a non-JSON frame", self._label)
                continue
            if not isinstance(message, dict):
                continue
            await self._on_client_message(message)

    async def _on_client_message(self, message: JsonObject) -> None:
        request_id = message.get("id")
        method = message.get("method")
        if not isinstance(request_id, int) or not isinstance(method, str):
            return
        params = message.get("params")
        if not isinstance(params, dict):
            params = {}
        session_id = message.get("sessionId")
        try:
            if isinstance(session_id, str):
                await self._on_session_request(request_id, method, params, session_id)
            else:
                await self._on_browser_request(request_id, method, params)
        except ClientRequestError as exc:
            await self._reply_error(request_id, session_id, str(exc))
        except TabDirectoryError as exc:
            await self._reply_error(request_id, session_id, str(exc))
        except CdpCommandError as exc:
            await self._reply_error(request_id, session_id, str(exc.error.get("message", exc)))

    async def _on_browser_request(self, request_id: int, method: str, params: JsonObject) -> None:
        handler = self._browser_handlers().get(method)
        if handler is not None:
            await self._reply(request_id, None, await handler(params, None))
            return
        if method == "Target.attachToTarget":
            target_id = self._require_allowed(params.get("targetId"))
            if params.get("flatten") is not True:
                raise ClientRequestError("Only flatten mode attach is supported.")
            await self._forward(request_id, None, method, {"targetId": target_id, "flatten": True})
            return
        if method == "Target.detachFromTarget":
            self._require_session(params.get("sessionId"))
            await self._forward(request_id, None, method, params)
            return
        if method == "Target.getTargetInfo" and "targetId" in params:
            self._require_allowed(params.get("targetId"))
            await self._forward(request_id, None, method, params)
            return
        if method in policy.BROWSER_FORWARDED_METHODS or method == "Target.getTargetInfo":
            await self._forward(request_id, None, method, params)
            return
        if policy.is_refused(method):
            raise ClientRequestError(policy.refused_message(method))
        raise ClientRequestError(
            f"{method} is not available on the browser target through the Omnigent proxy."
        )

    async def _on_session_request(
        self, request_id: int, method: str, params: JsonObject, session_id: str
    ) -> None:
        session = self._sessions.get(session_id)
        if session is None:
            raise ClientRequestError(f"No session with given id: {session_id}")
        if policy.is_refused(method):
            raise ClientRequestError(policy.refused_message(method))
        root = session.root_target_id
        if method == "Page.handleJavaScriptDialog" and session_id in self._user_dialogs:
            await self._dismiss_user_dialog(request_id, session_id)
            return
        if policy.is_actuating(method):
            # Answering a real dialog races the client's own dialog bookkeeping; no reminder.
            remind = method != "Page.handleJavaScriptDialog"
            await self._require_agent_holds(root, remind=remind)
            self._note_actuation(root)
        if method == "Page.bringToFront":
            self._note_actuation(root)
            await self._reply(request_id, session_id, {})
            return
        if method == "Page.close" and session.parent is None:
            await self._directory.close_tab(root)
            await self._reply(request_id, session_id, {})
            return
        if method == "Browser.setContentsSize":
            await self._set_contents_size(request_id, session_id, params, root)
            return
        handler = self._browser_handlers().get(method)
        if handler is not None and method != "Target.setAutoAttach":
            await self._reply(request_id, session_id, await handler(params, session))
            return
        domain = policy.method_domain(method)
        if domain in {"Target", "Browser"}:
            self._check_session_target_method(method, params)
        await self._forward(request_id, session_id, method, params)

    def _check_session_target_method(self, method: str, params: JsonObject) -> None:
        """Allow the page-session ``Target``/``Browser`` calls that stay inside the session."""
        if method in {"Target.setAutoAttach", "Browser.getVersion"}:
            return
        if method == "Target.getTargetInfo":
            if "targetId" in params:
                self._require_allowed(params.get("targetId"))
            return
        if method == "Target.attachToTarget":
            self._require_allowed(params.get("targetId"))
            if params.get("flatten") is not True:
                raise ClientRequestError("Only flatten mode attach is supported.")
            return
        if method == "Target.detachFromTarget":
            self._require_session(params.get("sessionId"))
            return
        raise ClientRequestError(
            f"{method} is not available on a page through the Omnigent proxy."
        )

    def _browser_handlers(
        self,
    ) -> dict[str, Callable[[JsonObject, _Session | None], Awaitable[JsonObject]]]:
        return {
            "Target.setDiscoverTargets": self._set_discover_targets,
            "Target.setAutoAttach": self._set_auto_attach,
            "Target.getTargets": self._get_targets,
            "Target.createTarget": self._create_target,
            "Target.closeTarget": self._close_target,
            "Target.activateTarget": self._activate_target,
            "Browser.getWindowForTarget": self._get_window_for_target,
            "Browser.getWindowBounds": self._get_window_bounds,
            "Browser.setWindowBounds": self._set_window_bounds,
        }

    async def _set_discover_targets(
        self, params: JsonObject, session: _Session | None
    ) -> JsonObject:
        if session is not None:
            raise ClientRequestError("Target discovery is only available on the browser target.")
        self._discover = params.get("discover") is True
        if self._discover:
            for target_id in sorted(self.allowed_targets):
                await self._announce(target_id)
        else:
            self._announced.clear()
        return {}

    async def _set_auto_attach(self, params: JsonObject, _session: _Session | None) -> JsonObject:
        # Browser level only; page sessions forward it to reach their own frames and workers.
        auto_attach = params.get("autoAttach") is True
        if auto_attach and params.get("flatten") is not True:
            raise ClientRequestError("Only flatten mode auto-attach is supported.")
        self._auto_attach = auto_attach
        if auto_attach:
            for target_id in sorted(self.allowed_targets):
                await self._attach(target_id)
        return {}

    async def _get_targets(self, _params: JsonObject, _session: _Session | None) -> JsonObject:
        infos = [self._targets[target_id] for target_id in sorted(self.allowed_targets)]
        return {"targetInfos": infos}

    async def _create_target(self, params: JsonObject, _session: _Session | None) -> JsonObject:
        context = params.get("browserContextId")
        if context:
            raise ClientRequestError(
                "Separate browser contexts are not available; new pages open in the session's "
                "browser profile."
            )
        url = params.get("url")
        tab = await self._directory.create_tab(
            url if isinstance(url, str) and url else "about:blank"
        )
        target_id = tab.target_id or await self._wait_for_target_id(tab.tab_id)
        self._listed.add(target_id)
        self._owners[target_id] = tab.owner
        self._note_actuation(target_id)
        if target_id in self._targets:
            await self._admit(target_id)
        return {"targetId": target_id}

    async def _close_target(self, params: JsonObject, _session: _Session | None) -> JsonObject:
        target_id = self._require_allowed(params.get("targetId"))
        await self._require_agent_holds(target_id)
        await self._directory.close_tab(target_id)
        return {"success": True}

    async def _activate_target(self, params: JsonObject, _session: _Session | None) -> JsonObject:
        # Never raise the user's window or switch their tab for the agent.
        self._require_allowed(params.get("targetId"))
        return {}

    async def _get_window_for_target(
        self, params: JsonObject, session: _Session | None
    ) -> JsonObject:
        raw = params.get("targetId")
        target_id = (
            self._require_allowed(raw)
            if raw is not None or session is None
            else session.root_target_id
        )
        return {"windowId": self._window_id(target_id), "bounds": self._bounds(target_id)}

    async def _get_window_bounds(
        self, params: JsonObject, _session: _Session | None
    ) -> JsonObject:
        return {"bounds": self._bounds(self._target_for_window(params.get("windowId")))}

    async def _set_window_bounds(
        self, params: JsonObject, _session: _Session | None
    ) -> JsonObject:
        # The user's window is theirs; agent resizes go through setContentsSize.
        self._target_for_window(params.get("windowId"))
        return {}

    async def _set_contents_size(
        self, request_id: int, session_id: str, params: JsonObject, root: str
    ) -> None:
        target_id = self._target_for_window(params.get("windowId"))
        if target_id != root:
            raise ClientRequestError("The window belongs to another page.")
        width, height = self._window_sizes.get(target_id, _DEFAULT_WINDOW_SIZE)
        width = int(params.get("width") or width)
        height = int(params.get("height") or height)
        self._window_sizes[target_id] = (width, height)
        await self._forward(
            request_id,
            session_id,
            "Emulation.setDeviceMetricsOverride",
            {"width": width, "height": height, "deviceScaleFactor": 0, "mobile": False},
            client_method="Browser.setContentsSize",
        )

    # MARK: upstream side

    async def _read_upstream(self) -> None:
        while True:
            frame = await self._upstream.recv()
            try:
                message = json.loads(frame)
            except ValueError:
                _logger.warning("cdp proxy %s: browser sent a non-JSON frame", self._label)
                continue
            if isinstance(message, dict):
                await self._on_upstream_message(message)

    async def _on_upstream_message(self, message: JsonObject) -> None:
        upstream_id = message.get("id")
        if isinstance(upstream_id, int):
            await self._on_upstream_response(upstream_id, message)
            return
        method = message.get("method")
        params = message.get("params")
        if not isinstance(method, str) or not isinstance(params, dict):
            return
        session_id = message.get("sessionId")
        if isinstance(session_id, str):
            await self._on_session_event(session_id, method, params, message)
        else:
            await self._on_browser_event(method, params)

    async def _on_upstream_response(self, upstream_id: int, message: JsonObject) -> None:
        internal = self._internal.pop(upstream_id, None)
        if internal is not None:
            method, future = internal
            if future.done():
                return
            error = message.get("error")
            if isinstance(error, dict):
                future.set_exception(CdpCommandError(method, error))
            else:
                result = message.get("result")
                future.set_result(result if isinstance(result, dict) else {})
            return
        request = self._client_requests.pop(upstream_id, None)
        if request is None:
            return
        reply: JsonObject = {"id": request.client_id}
        if request.session_id is not None:
            reply["sessionId"] = request.session_id
        if "error" in message:
            reply["error"] = message["error"]
        else:
            result = message.get("result")
            reply["result"] = {} if request.method == "Browser.setContentsSize" else result or {}
        await self._send_client(reply)

    async def _on_browser_event(self, method: str, params: JsonObject) -> None:
        if method in {"Target.targetCreated", "Target.targetInfoChanged"}:
            info = params.get("targetInfo")
            if isinstance(info, dict) and isinstance(info.get("targetId"), str):
                await self._on_target_info(info, created=method == "Target.targetCreated")
            return
        if method == "Target.targetDestroyed":
            target_id = params.get("targetId")
            if isinstance(target_id, str):
                await self._on_target_destroyed(target_id)
            return
        if method == "Target.attachedToTarget":
            await self._on_attached(None, params)
            return
        if method == "Target.detachedFromTarget":
            session_id = params.get("sessionId")
            if isinstance(session_id, str) and session_id in self._sessions:
                self._drop_session(session_id)
                await self._send_client({"method": method, "params": params})
            return
        # Other browser-wide events (downloads, other contexts) are not the session's.

    async def _on_session_event(
        self, session_id: str, method: str, params: JsonObject, message: JsonObject
    ) -> None:
        if session_id not in self._sessions:
            return
        if method == "Target.attachedToTarget":
            await self._on_attached(session_id, params)
            return
        if method == "Target.detachedFromTarget":
            child = params.get("sessionId")
            if isinstance(child, str):
                self._drop_session(child)
        await self._send_client(message)

    async def _on_target_info(self, info: JsonObject, *, created: bool) -> None:
        target_id = info["targetId"]
        self._targets[target_id] = info
        opener = info.get("openerId")
        if (
            info.get("type") == "page"
            and isinstance(opener, str)
            and opener in self.allowed_targets
            and target_id not in self._listed
        ):
            self._popups.add(target_id)
        if target_id not in self.allowed_targets:
            return
        if target_id in self._announced and not created:
            await self._send_client(
                {"method": "Target.targetInfoChanged", "params": {"targetInfo": info}}
            )
            return
        await self._admit(target_id)

    async def _on_target_destroyed(self, target_id: str) -> None:
        self._targets.pop(target_id, None)
        self._popups.discard(target_id)
        self._auto_attached.discard(target_id)
        for session_id, session in list(self._sessions.items()):
            if session.root_target_id == target_id:
                self._drop_session(session_id)
        if target_id in self._announced:
            self._announced.discard(target_id)
            await self._send_client(
                {"method": "Target.targetDestroyed", "params": {"targetId": target_id}}
            )

    async def _on_attached(self, parent: str | None, params: JsonObject) -> None:
        session_id = params.get("sessionId")
        info = params.get("targetInfo")
        if not isinstance(session_id, str) or not isinstance(info, dict):
            return
        target_id = info.get("targetId")
        if not isinstance(target_id, str):
            return
        if parent is None:
            if target_id not in self.allowed_targets:
                # Only the proxy attaches at browser level, and only to allowed pages.
                self._spawn(self._detach_quietly(session_id))
                return
            self._sessions[session_id] = _Session(target_id, target_id, None)
            self._spawn(self._enable_focus_emulation(session_id))
            await self._send_client({"method": "Target.attachedToTarget", "params": params})
            return
        root = self._sessions[parent].root_target_id
        self._sessions[session_id] = _Session(target_id, root, parent)
        await self._send_client(
            {"method": "Target.attachedToTarget", "params": params, "sessionId": parent}
        )

    # MARK: directory

    async def _refresh_loop(self) -> None:
        while True:
            await asyncio.sleep(self._directory.refresh_interval_s)
            try:
                await self._refresh()
            except TabDirectoryError as exc:
                _logger.warning("cdp proxy %s: tab directory refresh failed: %s", self._label, exc)
            await self._report_idle_tabs()

    async def _refresh(self) -> None:
        tabs = await self._directory.list_tabs()
        self._apply_tabs(tabs)
        for target_id in sorted(self.allowed_targets):
            await self._admit(target_id)
        for target_id in sorted(self._announced - self.allowed_targets):
            await self._evict(target_id)
        await self._show_user_control()

    def _apply_tabs(self, tabs: list[ScopedTab]) -> None:
        self._listed = {tab.target_id for tab in tabs if tab.target_id}
        self._owners = {tab.target_id: tab.owner for tab in tabs if tab.target_id}
        self._owners_at = self._clock()
        self._popups &= set(self._targets)

    async def _admit(self, target_id: str) -> None:
        """Announce and auto-attach an allowed target the client has not seen yet."""
        if self._discover:
            await self._announce(target_id)
        if self._auto_attach:
            self._spawn(self._attach_quietly(target_id))

    async def _evict(self, target_id: str) -> None:
        """Hide a target that left the session (it moved to another session's tabs)."""
        for session_id, session in list(self._sessions.items()):
            if session.target_id == target_id and session.parent is None:
                self._spawn(self._detach_quietly(session_id))
        self._auto_attached.discard(target_id)
        self._announced.discard(target_id)
        await self._send_client(
            {"method": "Target.targetDestroyed", "params": {"targetId": target_id}}
        )

    async def _wait_for_target_id(self, tab_id: str) -> str:
        deadline = self._clock() + _TARGET_ID_WAIT_S
        while self._clock() < deadline:
            for tab in await self._directory.list_tabs():
                if tab.tab_id == tab_id and tab.target_id:
                    return tab.target_id
            await asyncio.sleep(_TARGET_ID_POLL_S)
        raise ClientRequestError("The new tab opened, but the browser did not report its target.")

    async def _require_agent_holds(self, target_id: str, *, remind: bool = False) -> None:
        """Refuse an actuating call while the user holds *target_id*.

        :param remind: Open the user-control dialog on the tab's pages again before
            refusing, so an action already past the client's dialog check ends at once.
        """
        if self._clock() - self._owners_at > _OWNER_MAX_AGE_S:
            self._apply_tabs(await self._directory.list_tabs())
            await self._show_user_control()
        if self._owners.get(target_id) == "user":
            if remind:
                for session_id in self._root_sessions(target_id):
                    await self._open_user_dialog(session_id)
            raise ClientRequestError(policy.USER_IN_CONTROL_MESSAGE)

    # MARK: user control

    async def _show_user_control(self) -> None:
        """Open the user-control dialog on pages the user took over; close it on hand-back.

        chrome-devtools-mcp refuses its input tools on a page with an open dialog and quotes
        the dialog's text, so the agent hears at once that it must wait.
        """
        now = self._clock()
        for session_id, session in list(self._sessions.items()):
            if session.parent is not None:
                continue
            held = self._owners.get(session.root_target_id) == "user"
            if held and session_id not in self._user_dialogs:
                dismissed = self._user_dialog_dismissed.get(session_id, float("-inf"))
                if now - dismissed >= _USER_DIALOG_REOPEN_AFTER_S:
                    await self._open_user_dialog(session_id)
            elif not held and session_id in self._user_dialogs:
                self._user_dialogs.discard(session_id)
                await self._send_client(
                    {
                        "method": "Page.javascriptDialogClosed",
                        "sessionId": session_id,
                        "params": {
                            "frameId": session.root_target_id,
                            "result": True,
                            "userInput": "",
                        },
                    }
                )

    async def _open_user_dialog(self, session_id: str) -> None:
        session = self._sessions[session_id]
        self._user_dialogs.add(session_id)
        info = self._targets.get(session.root_target_id, {})
        await self._send_client(
            {
                "method": "Page.javascriptDialogOpening",
                "sessionId": session_id,
                "params": {
                    "url": info.get("url", ""),
                    "frameId": session.root_target_id,
                    "message": policy.USER_IN_CONTROL_DIALOG_MESSAGE,
                    "type": "alert",
                    "hasBrowserHandler": False,
                    "defaultPrompt": "",
                },
            }
        )

    async def _dismiss_user_dialog(self, request_id: int, session_id: str) -> None:
        """Accept the agent's answer to the user-control dialog; it opens again shortly.

        The answer succeeds: clients treat a failed dialog answer as handled anyway, and
        some never await it.
        """
        self._user_dialogs.discard(session_id)
        self._user_dialog_dismissed[session_id] = self._clock()
        await self._reply(request_id, session_id, {})

    def _root_sessions(self, target_id: str) -> list[str]:
        return [
            session_id
            for session_id, session in self._sessions.items()
            if session.parent is None and session.target_id == target_id
        ]

    def _note_actuation(self, target_id: str) -> None:
        now = self._clock()
        self._last_actuation[target_id] = now
        last = self._last_report.get(target_id)
        if target_id in self._reported_active and last is not None:
            if now - last < _AGENT_STATE_REPORT_INTERVAL_S:
                return
        self._last_report[target_id] = now
        self._reported_active.add(target_id)
        self._spawn(self._report(target_id, "active"))

    async def _report_idle_tabs(self) -> None:
        now = self._clock()
        for target_id in sorted(self._reported_active):
            if now - self._last_actuation.get(target_id, now) >= AGENT_IDLE_AFTER_S:
                self._reported_active.discard(target_id)
                await self._report(target_id, "idle")

    async def _release_reported_tabs(self) -> None:
        for target_id in sorted(set(self._last_report)):
            await self._report(target_id, "released")

    async def _report(self, target_id: str, state: AgentTabState) -> None:
        try:
            await self._directory.report_agent_state(target_id, state)
        except TabDirectoryError as exc:
            _logger.warning(
                "cdp proxy %s: could not report agent state %s for %s: %s",
                self._label,
                state,
                target_id,
                exc,
            )

    # MARK: attach and announce

    async def _announce(self, target_id: str) -> None:
        if target_id in self._announced or target_id not in self._targets:
            return
        self._announced.add(target_id)
        await self._send_client(
            {"method": "Target.targetCreated", "params": {"targetInfo": self._targets[target_id]}}
        )

    async def _attach(self, target_id: str) -> None:
        if target_id in self._auto_attached or target_id in self._attaching:
            return
        self._attaching.add(target_id)
        try:
            await self._command("Target.attachToTarget", {"targetId": target_id, "flatten": True})
            self._auto_attached.add(target_id)
        finally:
            self._attaching.discard(target_id)

    async def _attach_quietly(self, target_id: str) -> None:
        try:
            await self._attach(target_id)
        except CdpCommandError as exc:
            # The page may close while the attach is in flight.
            _logger.info("cdp proxy %s: attach to %s failed: %s", self._label, target_id, exc)

    async def _detach_quietly(self, session_id: str) -> None:
        try:
            await self._command("Target.detachFromTarget", {"sessionId": session_id})
        except CdpCommandError as exc:
            _logger.info("cdp proxy %s: detach of %s failed: %s", self._label, session_id, exc)

    async def _enable_focus_emulation(self, session_id: str) -> None:
        # Pages act focused with the window in the background or the tab hidden.
        try:
            await self._command(
                "Emulation.setFocusEmulationEnabled", {"enabled": True}, session_id=session_id
            )
        except CdpCommandError as exc:
            _logger.warning(
                "cdp proxy %s: focus emulation failed on %s: %s", self._label, session_id, exc
            )

    def _drop_session(self, session_id: str) -> None:
        self._sessions.pop(session_id, None)
        self._user_dialogs.discard(session_id)
        self._user_dialog_dismissed.pop(session_id, None)
        for child_id, child in list(self._sessions.items()):
            if child.parent == session_id:
                self._drop_session(child_id)

    # MARK: helpers

    def _require_allowed(self, raw: object) -> str:
        if not isinstance(raw, str) or raw not in self.allowed_targets:
            raise ClientRequestError("No target with given id found")
        return raw

    def _require_session(self, raw: object) -> str:
        if not isinstance(raw, str) or raw not in self._sessions:
            raise ClientRequestError(f"No session with given id: {raw}")
        return raw

    def _window_id(self, target_id: str) -> int:
        if target_id not in self._window_ids:
            self._window_ids[target_id] = len(self._window_ids) + 1
        return self._window_ids[target_id]

    def _target_for_window(self, raw: object) -> str:
        for target_id, window_id in self._window_ids.items():
            if window_id == raw and target_id in self.allowed_targets:
                return target_id
        raise ClientRequestError(f"Browser window not found: {raw}")

    def _bounds(self, target_id: str) -> JsonObject:
        width, height = self._window_sizes.get(target_id, _DEFAULT_WINDOW_SIZE)
        return {"left": 0, "top": 0, "width": width, "height": height, "windowState": "normal"}

    def _spawn(self, coroutine: Awaitable[None]) -> None:
        task = asyncio.ensure_future(coroutine)
        self._background.add(task)
        task.add_done_callback(self._background.discard)

    async def _command(
        self, method: str, params: JsonObject, *, session_id: str | None = None
    ) -> JsonObject:
        upstream_id = self._take_upstream_id()
        future: asyncio.Future[JsonObject] = asyncio.get_running_loop().create_future()
        self._internal[upstream_id] = (method, future)
        message: JsonObject = {"id": upstream_id, "method": method, "params": params}
        if session_id is not None:
            message["sessionId"] = session_id
        try:
            await self._upstream.send(json.dumps(message))
            return await future
        finally:
            self._internal.pop(upstream_id, None)

    async def _forward(
        self,
        request_id: int,
        session_id: str | None,
        method: str,
        params: JsonObject,
        *,
        client_method: str | None = None,
    ) -> None:
        upstream_id = self._take_upstream_id()
        self._client_requests[upstream_id] = _ClientRequest(
            request_id, session_id, client_method or method
        )
        message: JsonObject = {"id": upstream_id, "method": method, "params": params}
        if session_id is not None:
            message["sessionId"] = session_id
        await self._upstream.send(json.dumps(message))

    def _take_upstream_id(self) -> int:
        upstream_id = self._next_upstream_id
        self._next_upstream_id += 1
        return upstream_id

    async def _reply(self, request_id: int, session_id: str | None, result: JsonObject) -> None:
        reply: JsonObject = {"id": request_id, "result": result}
        if session_id is not None:
            reply["sessionId"] = session_id
        await self._send_client(reply)

    async def _reply_error(self, request_id: int, session_id: object, message: str) -> None:
        reply: JsonObject = {
            "id": request_id,
            "error": {"code": CDP_SERVER_ERROR, "message": message},
        }
        if isinstance(session_id, str):
            reply["sessionId"] = session_id
        await self._send_client(reply)

    async def _send_client(self, message: JsonObject) -> None:
        async with self._send_lock:
            await self._client.send(json.dumps(message))


async def serve_unavailable(client: CdpChannel, reason: str) -> None:
    """Answer every request on *client* with *reason* until it disconnects.

    Puppeteer surfaces the first answer's message, so the agent reads why no
    browser is available instead of a bare connection failure.
    """
    with contextlib.suppress(asyncio.CancelledError):
        while True:
            frame = await client.recv()
            try:
                message = json.loads(frame)
            except ValueError:
                continue
            if not isinstance(message, dict) or not isinstance(message.get("id"), int):
                continue
            reply: JsonObject = {
                "id": message["id"],
                "error": {"code": CDP_SERVER_ERROR, "message": reason},
            }
            if isinstance(message.get("sessionId"), str):
                reply["sessionId"] = message["sessionId"]
            await client.send(json.dumps(reply))
