"""The runner's loopback CDP endpoint: session URLs, refusals and switching.

Real WebSockets on 127.0.0.1; the browser behind it is a small scripted CDP
server, since the proxy's scoping rules are covered in
``test_browser_devtools_proxy.py``.
"""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from typing import Any

import pytest
from websockets.asyncio.client import connect
from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed, InvalidStatus

from omnigent.runner.browser_devtools.directory import AgentTabState, ScopedTab
from omnigent.runner.browser_devtools.server import (
    BrowserBackend,
    BrowserDevtoolsService,
    BrowserUnavailableError,
    session_from_path,
    session_token,
)

_SECRET = b"s" * 32


def test_session_urls_authorize_only_their_own_session() -> None:
    token = session_token(_SECRET, "conv_a")
    other = session_token(_SECRET, "conv_b")

    assert session_from_path(_SECRET, f"/devtools/browser/{token}") == "conv_a"
    assert session_from_path(b"x" * 32, f"/devtools/browser/{token}") is None
    assert session_from_path(_SECRET, f"/devtools/browser/conv_b.{token.split('.')[1]}") is None
    assert session_from_path(_SECRET, f"/devtools/page/{token}") is None
    assert session_from_path(_SECRET, f"/devtools/browser/{other}") == "conv_b"
    assert session_from_path(_SECRET, "/devtools/browser/nodot") is None


class _Tabs:
    refresh_interval_s = 0.05

    async def list_tabs(self) -> list[ScopedTab]:
        return [ScopedTab(tab_id="tab_1", target_id="MINE")]

    async def create_tab(self, url: str) -> ScopedTab:
        raise AssertionError(f"unexpected create_tab({url})")

    async def close_tab(self, target_id: str) -> None:
        raise AssertionError(f"unexpected close_tab({target_id})")

    async def report_agent_state(self, target_id: str, state: AgentTabState) -> None:
        return None


async def _browser(connection: ServerConnection) -> None:
    targets = [
        {"targetId": "MINE", "type": "page", "url": "https://example.com/"},
        {"targetId": "PERSONAL", "type": "page", "url": "https://mail.example.com/"},
    ]
    async for frame in connection:
        message = json.loads(frame)
        if message["method"] == "Target.setDiscoverTargets":
            for info in targets:
                await connection.send(
                    json.dumps({"method": "Target.targetCreated", "params": {"targetInfo": info}})
                )
        await connection.send(json.dumps({"id": message["id"], "result": {}}))


class _Resolver:
    def __init__(self, upstream_url: str | None) -> None:
        self.upstream_url = upstream_url
        self.sessions: list[str] = []

    async def resolve(self, session_id: str) -> BrowserBackend:
        self.sessions.append(session_id)
        if self.upstream_url is None:
            raise BrowserUnavailableError("This runner has no agent browser: host not installed")
        return BrowserBackend(upstream_url=self.upstream_url, directory=_Tabs(), kind="remote")


@pytest.fixture
async def upstream_url() -> AsyncIterator[str]:
    async with serve(_browser, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        yield f"ws://127.0.0.1:{port}/devtools/browser/fake"


async def _request(connection: Any, request_id: int, method: str) -> dict[str, Any]:
    await connection.send(json.dumps({"id": request_id, "method": method, "params": {}}))
    while True:
        message = json.loads(await connection.recv())
        if message.get("id") == request_id:
            return message


async def test_an_agent_reaches_only_its_tabs_and_a_switch_disconnects_it(
    upstream_url: str,
) -> None:
    resolver = _Resolver(upstream_url)
    service = BrowserDevtoolsService(resolver, secret=_SECRET)
    await service.ensure_started()
    try:
        async with connect(service.endpoint_for("conv_a")) as agent:
            listed = await _request(agent, 1, "Target.getTargets")
            assert [info["targetId"] for info in listed["result"]["targetInfos"]] == ["MINE"]

            assert await service.disconnect_session("conv_a") == 1
            with pytest.raises(ConnectionClosed) as closed:
                await agent.recv()
        assert closed.value.rcvd is not None and closed.value.rcvd.code == 1001
        assert resolver.sessions == ["conv_a"]
    finally:
        await service.stop()


async def test_unknown_urls_are_refused_before_the_upgrade() -> None:
    resolver = _Resolver(None)
    service = BrowserDevtoolsService(resolver, secret=_SECRET)
    await service.ensure_started()
    forged = service.endpoint_for("conv_a").replace("conv_a.", "conv_b.")
    try:
        with pytest.raises(InvalidStatus) as refused:
            async with connect(forged):
                pass
        assert refused.value.response.status_code == 403
        assert resolver.sessions == []
    finally:
        await service.stop()


async def test_an_unavailable_browser_tells_the_agent_why() -> None:
    service = BrowserDevtoolsService(_Resolver(None), secret=_SECRET)
    await service.ensure_started()
    try:
        async with connect(service.endpoint_for("conv_a")) as agent:
            reply = await _request(agent, 7, "Target.getBrowserContexts")
        assert reply["error"]["message"] == (
            "This runner has no agent browser: host not installed"
        )
    finally:
        await service.stop()


def test_the_endpoint_needs_a_listening_port() -> None:
    service = BrowserDevtoolsService(_Resolver(None), secret=_SECRET)
    with pytest.raises(RuntimeError, match="not listening"):
        service.endpoint_for("conv_a")
