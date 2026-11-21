"""The scoped CDP proxy shows an agent only its session's tabs.

A scripted browser stands in for Chromium's browser-level CDP endpoint, and a
recording directory stands in for the browser's tab list, so each test drives
:class:`ScopedCdpSession` exactly as ``chrome-devtools-mcp``'s Puppeteer does.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
from collections.abc import AsyncIterator
from typing import Any

import pytest

from omnigent.runner.browser_devtools.directory import (
    AgentTabState,
    ScopedTab,
    TabDirectoryError,
    TabOwner,
)
from omnigent.runner.browser_devtools.session import ScopedCdpSession, serve_unavailable
from tests._helpers.polling import poll_until_async

_WAIT_S = 5.0


class _Closed(ConnectionError):
    """The in-memory channel closed."""


class _Channel:
    """One direction pair of an in-memory WebSocket."""

    def __init__(self, inbound: asyncio.Queue[str | None], outbound: asyncio.Queue[str | None]):
        self._inbound = inbound
        self._outbound = outbound

    async def recv(self) -> str:
        frame = await self._inbound.get()
        if frame is None:
            raise _Closed()
        return frame

    async def send(self, message: str) -> None:
        await self._outbound.put(message)


def _pipe() -> tuple[_Channel, _Channel]:
    left: asyncio.Queue[str | None] = asyncio.Queue()
    right: asyncio.Queue[str | None] = asyncio.Queue()
    return _Channel(left, right), _Channel(right, left)


def _page(target_id: str, url: str = "https://example.com/", **extra: Any) -> dict[str, Any]:
    return {"targetId": target_id, "type": "page", "url": url, "title": target_id, **extra}


class _Browser:
    """A browser-level CDP endpoint with pages, flatten sessions and a call log."""

    def __init__(self, channel: _Channel, targets: list[dict[str, Any]]):
        self._channel = channel
        self.targets = {info["targetId"]: info for info in targets}
        self.sessions: dict[str, str] = {}
        self.children: dict[str, list[dict[str, Any]]] = {}
        self.calls: list[tuple[str, dict[str, Any], str | None]] = []
        self._discovering = False
        self._next_session = 1

    def methods(self, session_id: str | None = None) -> list[str]:
        return [method for method, _params, session in self.calls if session == session_id]

    async def emit(self, method: str, params: dict[str, Any], session_id: str | None = None):
        message: dict[str, Any] = {"method": method, "params": params}
        if session_id is not None:
            message["sessionId"] = session_id
        await self._channel.send(json.dumps(message))

    async def add_target(self, info: dict[str, Any]) -> None:
        self.targets[info["targetId"]] = info
        if self._discovering:
            await self.emit("Target.targetCreated", {"targetInfo": info})

    async def remove_target(self, target_id: str) -> None:
        self.targets.pop(target_id, None)
        for session_id, owner in list(self.sessions.items()):
            if owner == target_id:
                del self.sessions[session_id]
                await self.emit(
                    "Target.detachedFromTarget", {"sessionId": session_id, "targetId": target_id}
                )
        await self.emit("Target.targetDestroyed", {"targetId": target_id})

    async def serve(self) -> None:
        with contextlib.suppress(_Closed):
            while True:
                message = json.loads(await self._channel.recv())
                params = message.get("params", {})
                session_id = message.get("sessionId")
                self.calls.append((message["method"], params, session_id))
                result = await self._answer(message["method"], params, session_id)
                reply: dict[str, Any] = {"id": message["id"], "result": result}
                if session_id is not None:
                    reply["sessionId"] = session_id
                await self._channel.send(json.dumps(reply))

    async def _answer(self, method: str, params: dict[str, Any], session_id: str | None):
        if method == "Target.setDiscoverTargets" and session_id is None:
            self._discovering = True
            for info in list(self.targets.values()):
                await self.emit("Target.targetCreated", {"targetInfo": info})
            return {}
        if method == "Target.attachToTarget":
            new_session = f"S{self._next_session}"
            self._next_session += 1
            self.sessions[new_session] = params["targetId"]
            info = self.targets[params["targetId"]]
            await self.emit(
                "Target.attachedToTarget",
                {"sessionId": new_session, "targetInfo": info, "waitingForDebugger": False},
            )
            return {"sessionId": new_session}
        if method == "Target.detachFromTarget":
            target_id = self.sessions.pop(params["sessionId"], "")
            await self.emit(
                "Target.detachedFromTarget",
                {"sessionId": params["sessionId"], "targetId": target_id},
            )
            return {}
        if method == "Target.setAutoAttach" and session_id is not None:
            for child in self.children.get(self.sessions[session_id], []):
                child_session = f"C{self._next_session}"
                self._next_session += 1
                await self.emit(
                    "Target.attachedToTarget",
                    {"sessionId": child_session, "targetInfo": child, "waitingForDebugger": True},
                    session_id,
                )
            return {}
        if method == "Browser.getVersion":
            return {"product": "Chrome/156.0.0.0"}
        return {"echo": method}


class _Directory:
    """A session tab list that records what the proxy asks of it."""

    def __init__(self, browser: _Browser, tabs: list[ScopedTab]):
        self._browser = browser
        self.tabs = list(tabs)
        self.created: list[str] = []
        self.closed: list[str] = []
        self.states: list[tuple[str, AgentTabState]] = []
        self.fail_listing = False
        self.listings = 0
        self.failed_listings = 0

    @property
    def refresh_interval_s(self) -> float:
        return 0.02

    async def list_tabs(self) -> list[ScopedTab]:
        if self.fail_listing:
            self.failed_listings += 1
            raise TabDirectoryError("browser host went away")
        self.listings += 1
        return list(self.tabs)

    async def create_tab(self, url: str) -> ScopedTab:
        self.created.append(url)
        target_id = f"NEW{len(self.created)}"
        tab = ScopedTab(tab_id=f"tab_{target_id}", target_id=target_id, url=url)
        self.tabs.append(tab)
        await self._browser.add_target(_page(target_id, url))
        return tab

    async def close_tab(self, target_id: str) -> None:
        self.closed.append(target_id)
        self.tabs = [tab for tab in self.tabs if tab.target_id != target_id]
        await self._browser.remove_target(target_id)

    async def report_agent_state(self, target_id: str, state: AgentTabState) -> None:
        self.states.append((target_id, state))


class _Agent:
    """The agent's CDP client: numbered requests, buffered events."""

    def __init__(self, channel: _Channel):
        self._channel = channel
        self._next_id = 1
        self.events: list[dict[str, Any]] = []
        self._replies: dict[int, dict[str, Any]] = {}

    async def request(
        self, method: str, params: dict[str, Any] | None = None, session_id: str | None = None
    ) -> dict[str, Any]:
        request_id = self._next_id
        self._next_id += 1
        message: dict[str, Any] = {"id": request_id, "method": method, "params": params or {}}
        if session_id is not None:
            message["sessionId"] = session_id
        await self._channel.send(json.dumps(message))
        async with asyncio.timeout(_WAIT_S):
            while request_id not in self._replies:
                await self._pump()
        return self._replies.pop(request_id)

    async def _pump(self) -> None:
        message = json.loads(await self._channel.recv())
        if "id" in message:
            self._replies[message["id"]] = message
        else:
            self.events.append(message)

    async def wait_for_event(self, method: str, **params: Any) -> dict[str, Any]:
        async with asyncio.timeout(_WAIT_S):
            while True:
                for event in self.events:
                    if event["method"] == method and all(
                        _lookup(event["params"], key) == value for key, value in params.items()
                    ):
                        return event
                await self._pump()

    def event_targets(self, method: str) -> list[str]:
        return [
            _lookup(event["params"], "targetId")
            for event in self.events
            if event["method"] == method
        ]


def _lookup(params: dict[str, Any], key: str) -> Any:
    if key in params:
        return params[key]
    return params.get("targetInfo", {}).get(key)


class _Stack:
    def __init__(self, agent: _Agent, browser: _Browser, directory: _Directory):
        self.agent = agent
        self.browser = browser
        self.directory = directory


@contextlib.asynccontextmanager
async def _proxy(
    targets: list[dict[str, Any]], tabs: list[ScopedTab], *, clock: Any = None
) -> AsyncIterator[_Stack]:
    agent_side, proxy_client_side = _pipe()
    proxy_upstream_side, browser_side = _pipe()
    browser = _Browser(browser_side, targets)
    directory = _Directory(browser, tabs)
    kwargs = {"clock": clock} if clock is not None else {}
    session = ScopedCdpSession(
        client=proxy_client_side,
        upstream=proxy_upstream_side,
        directory=directory,
        label="conv_test/remote",
        **kwargs,
    )
    browser_task = asyncio.create_task(browser.serve())
    proxy_task = asyncio.create_task(session.run())
    try:
        yield _Stack(_Agent(agent_side), browser, directory)
    finally:
        await agent_side._outbound.put(None)
        with contextlib.suppress(_Closed):
            await asyncio.wait_for(proxy_task, _WAIT_S)
        await browser_side._outbound.put(None)
        await proxy_upstream_side._outbound.put(None)
        browser_task.cancel()


def _session_tab(target_id: str, owner: TabOwner = "agent") -> ScopedTab:
    return ScopedTab(tab_id=f"tab_{target_id}", target_id=target_id, owner=owner)


_MINE = _page("MINE", "https://example.com/mine")
_PERSONAL = _page("PERSONAL", "https://mail.example.com/inbox")


async def test_discovery_and_target_listing_show_only_the_sessions_tabs() -> None:
    async with _proxy([_MINE, _PERSONAL], [_session_tab("MINE")]) as stack:
        assert await stack.agent.request("Target.setDiscoverTargets", {"discover": True}) == {
            "id": 1,
            "result": {},
        }
        listed = await stack.agent.request("Target.getTargets")

        assert stack.agent.event_targets("Target.targetCreated") == ["MINE"]
        assert [info["targetId"] for info in listed["result"]["targetInfos"]] == ["MINE"]


async def test_auto_attach_attaches_session_pages_without_forwarding_browser_auto_attach() -> None:
    async with _proxy([_MINE, _PERSONAL], [_session_tab("MINE")]) as stack:
        await stack.agent.request(
            "Target.setAutoAttach",
            {"autoAttach": True, "waitForDebuggerOnStart": True, "flatten": True},
        )
        attached = await stack.agent.wait_for_event("Target.attachedToTarget", targetId="MINE")
        session_id = attached["params"]["sessionId"]
        await stack.agent.request("Runtime.enable", session_id=session_id)

        browser_attaches = [
            params["targetId"]
            for method, params, session in stack.browser.calls
            if method == "Target.attachToTarget" and session is None
        ]
        assert browser_attaches == ["MINE"]
        assert "Target.setAutoAttach" not in stack.browser.methods(None)
        # Focus emulation keeps pages acting focused with the window in the background.
        assert "Emulation.setFocusEmulationEnabled" in stack.browser.methods(session_id)
        assert "Runtime.enable" in stack.browser.methods(session_id)


async def test_new_pages_open_as_directory_tabs_not_raw_browser_targets() -> None:
    async with _proxy([_MINE], [_session_tab("MINE")]) as stack:
        await stack.agent.request("Target.setDiscoverTargets", {"discover": True})
        await stack.agent.request("Target.setAutoAttach", {"autoAttach": True, "flatten": True})
        created = await stack.agent.request(
            "Target.createTarget", {"url": "about:blank", "background": True}
        )

        assert created["result"] == {"targetId": "NEW1"}
        assert stack.directory.created == ["about:blank"]
        assert "Target.createTarget" not in stack.browser.methods(None)
        await stack.agent.wait_for_event("Target.targetCreated", targetId="NEW1")
        await stack.agent.wait_for_event("Target.attachedToTarget", targetId="NEW1")


async def test_separate_browser_contexts_are_refused() -> None:
    async with _proxy([_MINE], [_session_tab("MINE")]) as stack:
        reply = await stack.agent.request(
            "Target.createTarget", {"url": "about:blank", "browserContextId": "CTX"}
        )

        assert "Separate browser contexts" in reply["error"]["message"]
        assert stack.directory.created == []


async def test_closing_goes_through_the_directory_and_other_tabs_are_unknown() -> None:
    async with _proxy([_MINE, _PERSONAL], [_session_tab("MINE")]) as stack:
        foreign = await stack.agent.request("Target.closeTarget", {"targetId": "PERSONAL"})
        closed = await stack.agent.request("Target.closeTarget", {"targetId": "MINE"})

        assert foreign["error"]["message"] == "No target with given id found"
        assert closed["result"] == {"success": True}
        assert stack.directory.closed == ["MINE"]
        assert "Target.closeTarget" not in stack.browser.methods(None)


async def test_foreign_targets_cannot_be_attached_or_inspected() -> None:
    async with _proxy([_MINE, _PERSONAL], [_session_tab("MINE")]) as stack:
        attach = await stack.agent.request(
            "Target.attachToTarget", {"targetId": "PERSONAL", "flatten": True}
        )
        info = await stack.agent.request("Target.getTargetInfo", {"targetId": "PERSONAL"})
        unknown_session = await stack.agent.request("Runtime.evaluate", session_id="S99")

        assert attach["error"]["message"] == "No target with given id found"
        assert info["error"]["message"] == "No target with given id found"
        assert "No session with given id" in unknown_session["error"]["message"]
        assert ("Target.attachToTarget", {"targetId": "PERSONAL", "flatten": True}, None) not in (
            stack.browser.calls
        )


@pytest.mark.parametrize(
    ("method", "on_page"),
    [
        ("Browser.close", False),
        ("Target.attachToBrowserTarget", False),
        ("Target.createBrowserContext", False),
        ("Browser.setDownloadBehavior", False),
        ("SystemInfo.getProcessInfo", False),
        ("Network.getAllCookies", True),
        ("Storage.getCookies", True),
        ("Network.clearBrowserCookies", True),
        ("WebAuthn.enable", True),
        ("Extensions.loadUnpacked", True),
        ("Target.exposeDevToolsProtocol", True),
    ],
)
async def test_methods_that_reach_beyond_the_tab_are_refused(method: str, on_page: bool) -> None:
    async with _proxy([_MINE], [_session_tab("MINE")]) as stack:
        session_id = None
        if on_page:
            attached = await stack.agent.request(
                "Target.attachToTarget", {"targetId": "MINE", "flatten": True}
            )
            session_id = attached["result"]["sessionId"]
        reply = await stack.agent.request(method, session_id=session_id)

        assert "error" in reply, reply
        assert method not in stack.browser.methods(session_id)


async def test_user_control_holds_actuating_calls_but_not_reads() -> None:
    async with _proxy([_MINE], [_session_tab("MINE", owner="user")]) as stack:
        attached = await stack.agent.request(
            "Target.attachToTarget", {"targetId": "MINE", "flatten": True}
        )
        session_id = attached["result"]["sessionId"]
        click = await stack.agent.request(
            "Input.dispatchMouseEvent", {"type": "mousePressed", "x": 5, "y": 5}, session_id
        )
        navigate = await stack.agent.request(
            "Page.navigate", {"url": "https://example.com/next"}, session_id
        )
        read = await stack.agent.request(
            "Runtime.evaluate", {"expression": "document.title"}, session_id
        )

        assert click["error"]["message"].startswith("user_in_control")
        assert navigate["error"]["message"].startswith("user_in_control")
        assert read["result"] == {"echo": "Runtime.evaluate"}
        assert "Input.dispatchMouseEvent" not in stack.browser.methods(session_id)

        # Handing back lets the agent act again.
        stack.directory.tabs = [_session_tab("MINE", owner="agent")]
        # A listing already under way may predate the change; the one after it cannot.
        seen = stack.directory.listings
        await poll_until_async(lambda: stack.directory.listings >= seen + 2)
        again = await stack.agent.request(
            "Input.dispatchMouseEvent", {"type": "mousePressed", "x": 5, "y": 5}, session_id
        )
        assert again["result"] == {"echo": "Input.dispatchMouseEvent"}


async def test_child_frames_and_workers_are_reachable_through_their_page() -> None:
    async with _proxy([_MINE], [_session_tab("MINE")]) as stack:
        stack.browser.children["MINE"] = [
            {"targetId": "FRAME", "type": "iframe", "url": "https://ads.example.com/"}
        ]
        attached = await stack.agent.request(
            "Target.attachToTarget", {"targetId": "MINE", "flatten": True}
        )
        page_session = attached["result"]["sessionId"]
        await stack.agent.request(
            "Target.setAutoAttach",
            {"autoAttach": True, "waitForDebuggerOnStart": True, "flatten": True},
            page_session,
        )
        child = await stack.agent.wait_for_event("Target.attachedToTarget", targetId="FRAME")
        child_session = child["params"]["sessionId"]
        resumed = await stack.agent.request(
            "Runtime.runIfWaitingForDebugger", session_id=child_session
        )

        assert child["sessionId"] == page_session
        assert resumed["result"] == {"echo": "Runtime.runIfWaitingForDebugger"}


async def test_popups_opened_by_session_pages_join_the_session() -> None:
    async with _proxy([_MINE, _PERSONAL], [_session_tab("MINE")]) as stack:
        await stack.agent.request("Target.setDiscoverTargets", {"discover": True})
        await stack.browser.add_target(
            _page("POPUP", "https://example.com/oauth", openerId="MINE")
        )
        await stack.browser.add_target(
            _page("OTHER", "https://example.com/x", openerId="PERSONAL")
        )
        await stack.agent.wait_for_event("Target.targetCreated", targetId="POPUP")
        # Both reached the proxy before this round trip's answer.
        await stack.agent.request("Target.getTargets")

        assert "OTHER" not in stack.agent.event_targets("Target.targetCreated")


async def test_a_tab_that_leaves_the_session_disappears_for_the_agent() -> None:
    async with _proxy([_MINE], [_session_tab("MINE")]) as stack:
        await stack.agent.request("Target.setDiscoverTargets", {"discover": True})
        await stack.agent.request("Target.setAutoAttach", {"autoAttach": True, "flatten": True})
        await stack.agent.wait_for_event("Target.attachedToTarget", targetId="MINE")
        stack.directory.tabs = []

        await stack.agent.wait_for_event("Target.targetDestroyed", targetId="MINE")
        await stack.agent.wait_for_event("Target.detachedFromTarget", targetId="MINE")
        listed = await stack.agent.request("Target.getTargets")
        assert listed["result"]["targetInfos"] == []


async def test_resizing_emulates_the_viewport_instead_of_moving_the_window() -> None:
    async with _proxy([_MINE], [_session_tab("MINE")]) as stack:
        attached = await stack.agent.request(
            "Target.attachToTarget", {"targetId": "MINE", "flatten": True}
        )
        session_id = attached["result"]["sessionId"]
        window = await stack.agent.request("Browser.getWindowForTarget", session_id=session_id)
        window_id = window["result"]["windowId"]
        bounds = await stack.agent.request(
            "Browser.setWindowBounds",
            {"windowId": window_id, "bounds": {"windowState": "normal"}},
            session_id,
        )
        resized = await stack.agent.request(
            "Browser.setContentsSize",
            {"windowId": window_id, "width": 800, "height": 600},
            session_id,
        )
        after = await stack.agent.request("Browser.getWindowBounds", {"windowId": window_id})

        assert bounds["result"] == {} and resized["result"] == {}
        emulated = [
            params
            for method, params, session in stack.browser.calls
            if method == "Emulation.setDeviceMetricsOverride" and session == session_id
        ]
        assert emulated == [{"width": 800, "height": 600, "deviceScaleFactor": 0, "mobile": False}]
        assert not any(
            method.startswith("Browser.") and method != "Browser.getVersion"
            for method, _p, _s in stack.browser.calls
        )
        assert after["result"]["bounds"]["width"] == 800


async def test_focus_and_activation_requests_never_raise_the_users_window() -> None:
    async with _proxy([_MINE], [_session_tab("MINE")]) as stack:
        attached = await stack.agent.request(
            "Target.attachToTarget", {"targetId": "MINE", "flatten": True}
        )
        session_id = attached["result"]["sessionId"]
        front = await stack.agent.request("Page.bringToFront", session_id=session_id)
        activate = await stack.agent.request("Target.activateTarget", {"targetId": "MINE"})

        assert front["result"] == {} and activate["result"] == {}
        assert "Page.bringToFront" not in stack.browser.methods(session_id)
        assert "Target.activateTarget" not in stack.browser.methods(None)


async def test_agent_activity_badges_the_tab_then_goes_idle_and_is_released() -> None:
    now = [100.0]
    async with _proxy([_MINE], [_session_tab("MINE")], clock=lambda: now[0]) as stack:
        attached = await stack.agent.request(
            "Target.attachToTarget", {"targetId": "MINE", "flatten": True}
        )
        session_id = attached["result"]["sessionId"]
        for _ in range(3):
            await stack.agent.request("Input.dispatchKeyEvent", {"type": "char"}, session_id)
        await poll_until_async(lambda: bool(stack.directory.states))
        # Three keystrokes inside the debounce window are one report.
        assert stack.directory.states == [("MINE", "active")]

        now[0] += 30
        await poll_until_async(lambda: ("MINE", "idle") in stack.directory.states)
    assert stack.directory.states[-1] == ("MINE", "released")


async def test_a_directory_failure_after_connect_keeps_the_last_known_tabs() -> None:
    async with _proxy([_MINE], [_session_tab("MINE")]) as stack:
        # The first answer means the proxy finished its initial listing.
        await stack.agent.request("Target.getTargets")
        stack.directory.fail_listing = True
        await poll_until_async(lambda: stack.directory.failed_listings >= 1)
        listed = await stack.agent.request("Target.getTargets")

        assert [info["targetId"] for info in listed["result"]["targetInfos"]] == ["MINE"]


async def test_unavailable_browser_answers_every_request_with_the_reason() -> None:
    agent_side, proxy_side = _pipe()
    task = asyncio.create_task(serve_unavailable(proxy_side, "This runner has no agent browser."))
    agent = _Agent(agent_side)

    reply = await agent.request("Target.getBrowserContexts")
    paged = await agent.request("Runtime.enable", session_id="S1")

    assert reply["error"]["message"] == "This runner has no agent browser."
    assert paged["sessionId"] == "S1"
    task.cancel()
