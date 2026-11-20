"""The real ``chrome-devtools-mcp`` drives the real browser host through the proxy.

Runs the pinned MCP server exactly as the runner configures it
(``browser_devtools_server``), against the runner's scoped CDP proxy in front of
a real ``omnigent-browser-host``. The agent must reach every DevTools tool on
its own session's tab and never see another session's tab.

Needs ``OMNIGENT_TEST_BROWSER_HOST_BIN`` (the built host launcher) and Node
20.19+ with npm able to fetch the package (``~/.npmrc`` or
``npm_config_registry`` name the registry)::

    OMNIGENT_TEST_BROWSER_HOST_BIN=browser-host/build/mac/host/omnigent-browser-host \\
        uv run --no-sync pytest tests/e2e/test_chrome_devtools_mcp_browser_host_e2e.py
"""

from __future__ import annotations

import asyncio
import contextlib
import functools
import http.server
import os
import re
import shutil
import subprocess
import threading
from collections.abc import AsyncIterator, Iterator, Mapping
from pathlib import Path
from typing import Any

import pytest

from omnigent.browser_devtools_availability import browser_devtools_server
from omnigent.runner.browser_devtools.resolver import RunnerBrowserResolver
from omnigent.runner.browser_devtools.server import BrowserDevtoolsService
from omnigent.runner.browser_host import BrowserHostManager, BrowserHostSettings, host_request
from tests._helpers.live_server import terminate_process
from tests._helpers.stdio_jsonrpc import read_json_line, write_json_line

pytestmark = pytest.mark.skipif(os.name != "posix", reason="browser hosts use Unix sockets")

_REPO_ROOT = Path(__file__).resolve().parents[2]
# The first call waits for npm to fetch the package.
_FIRST_CALL_TIMEOUT_S = 240.0
_CALL_TIMEOUT_S = 90.0

_PAGES = {
    "agent.html": (
        "<!doctype html><title>Agent page</title>"
        '<label for="name">Name</label><input id="name">'
        '<button id="go" onclick="console.log(\'clicked \' + '
        "document.getElementById('name').value); fetch('/data.json')\">Go</button>"
    ),
    "second.html": "<!doctype html><title>Second page</title><p>second</p>",
    "opened.html": "<!doctype html><title>Opened page</title><p>opened</p>",
    "personal.html": "<!doctype html><title>Personal inbox</title><p>private</p>",
    "data.json": '{"ok": true}',
}


@contextlib.contextmanager
def _page_server(root: Path) -> Iterator[str]:
    for name, body in _PAGES.items():
        (root / name).write_text(body, encoding="utf-8")
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}"
    finally:
        server.shutdown()
        server.server_close()


class _McpClient:
    """Newline-delimited JSON-RPC to the MCP server's stdio, off the event loop."""

    def __init__(self, process: subprocess.Popen[str], stderr_path: Path) -> None:
        self._process = process
        self._stderr_path = stderr_path
        self._next_id = 1

    async def request(
        self, method: str, params: Mapping[str, object], *, timeout_s: float = _CALL_TIMEOUT_S
    ) -> dict[str, Any]:
        request_id = self._next_id
        self._next_id += 1
        assert self._process.stdin is not None and self._process.stdout is not None
        write_json_line(
            self._process.stdin,
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": dict(params)},
        )
        while True:
            try:
                message = await asyncio.to_thread(
                    read_json_line, self._process.stdout, timeout_s=timeout_s
                )
            except (EOFError, TimeoutError) as exc:
                stderr = self._stderr_path.read_text(errors="replace")[-4000:]
                raise AssertionError(
                    f"chrome_devtools stopped answering {method}:\n{stderr}"
                ) from exc
            if message.get("id") == request_id:
                assert "error" not in message, message
                result = message["result"]
                assert isinstance(result, dict)
                return result

    def notify(self, method: str) -> None:
        assert self._process.stdin is not None
        write_json_line(self._process.stdin, {"jsonrpc": "2.0", "method": method})

    async def call(self, tool: str, arguments: Mapping[str, object]) -> dict[str, Any]:
        result = await self.request("tools/call", {"name": tool, "arguments": dict(arguments)})
        assert not result.get("isError"), (tool, result)
        return result


def _text(result: Mapping[str, Any]) -> str:
    return "\n".join(item.get("text", "") for item in result["content"] if item["type"] == "text")


def _page_ids(listing: str) -> dict[str, int]:
    """Map each listed page's URL to its pageId (``"<id>: <title> (<url>)"`` lines)."""
    pages: dict[str, int] = {}
    for page_id, label in re.findall(r"^(\d+): (.*)$", listing, flags=re.MULTILINE):
        url = label.removesuffix(" [selected]").rsplit(" ", 1)[-1].strip("()")
        pages[url] = int(page_id)
    return pages


def _uid(snapshot: str, role: str, name: str) -> str:
    match = re.search(rf'uid=(\S+) {role} "{re.escape(name)}"', snapshot)
    assert match, snapshot
    return match.group(1)


@pytest.fixture
async def host_manager(tmp_path: Path) -> AsyncIterator[BrowserHostManager]:
    host_bin = os.environ.get("OMNIGENT_TEST_BROWSER_HOST_BIN")
    if not host_bin:
        pytest.skip("set OMNIGENT_TEST_BROWSER_HOST_BIN to the real omnigent-browser-host")
    if shutil.which("npm") is None:
        pytest.skip("chrome-devtools-mcp needs Node 20.19+ with npm on PATH")
    # Nothing attaches a viewer, so the encoder only has to answer --version.
    encoder = tmp_path / "bin" / "x264"
    encoder.parent.mkdir()
    encoder.write_text("#!/bin/sh\necho 'x264 0.164 stub for CDP-only tests'\n")
    encoder.chmod(0o755)
    manager = BrowserHostManager(
        BrowserHostSettings(
            enabled=True,
            data_dir=tmp_path / "data",
            binary=Path(host_bin),
            encoder=encoder,
            start_timeout_s=60,
        )
    )
    try:
        yield manager
    finally:
        for state in await manager.running_hosts():
            await host_request(state.socket, "host.shutdown")
            async with asyncio.timeout(20):
                while _alive(state.pid):
                    await asyncio.sleep(0.1)


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


async def test_chrome_devtools_mcp_drives_only_the_sessions_tabs(
    host_manager: BrowserHostManager, tmp_path: Path
) -> None:
    site_root = tmp_path / "site"
    site_root.mkdir()
    published: list[dict[str, object]] = []
    with _page_server(site_root) as base:
        personal = await host_manager.create_tab("conv_personal", url=f"{base}/personal.html")
        await host_manager.create_tab("conv_agent", url=f"{base}/agent.html")
        service = BrowserDevtoolsService(
            # No server client: the browser host is the only backend.
            RunnerBrowserResolver(
                host_manager, lambda _session, event: published.append(dict(event)), None
            )
        )
        await service.ensure_started()
        config = browser_devtools_server(service.endpoint_for("conv_agent"))
        assert config.command is not None
        stderr_log = (tmp_path / "chrome-devtools-mcp.log").open("w")
        # A test venv may install another omnigent copy, so the launcher runs from this
        # checkout: without -I, ``-m`` puts the working directory first on the path.
        process = subprocess.Popen(
            [config.command, *(arg for arg in config.args if arg != "-I")],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr_log,
            text=True,
            cwd=_REPO_ROOT,
            # The launcher installs the pinned release into this test's own data dir.
            env={**os.environ, **config.env, "OMNIGENT_DATA_DIR": str(tmp_path / "mcp-data")},
        )
        try:
            mcp = _McpClient(process, tmp_path / "chrome-devtools-mcp.log")
            await mcp.request(
                "initialize",
                {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "omnigent-e2e", "version": "0"},
                },
                timeout_s=_FIRST_CALL_TIMEOUT_S,
            )
            mcp.notify("notifications/initialized")
            tools = {tool["name"] for tool in (await mcp.request("tools/list", {}))["tools"]}
            assert {
                "list_pages",
                "new_page",
                "navigate_page",
                "take_snapshot",
                "click",
                "fill",
                "press_key",
                "evaluate_script",
                "list_console_messages",
                "list_network_requests",
                "take_screenshot",
                "performance_start_trace",
                "emulate",
                "resize_page",
                "wait_for",
            } <= tools, sorted(tools)

            listing = _text(await mcp.call("list_pages", {}))
            pages = _page_ids(listing)
            assert f"{base}/agent.html" in pages, listing
            assert "personal" not in listing
            page = pages[f"{base}/agent.html"]

            snapshot = _text(await mcp.call("take_snapshot", {"pageId": page}))
            await mcp.call(
                "fill", {"pageId": page, "uid": _uid(snapshot, "textbox", "Name"), "value": "Ada"}
            )
            await mcp.call("click", {"pageId": page, "uid": _uid(snapshot, "button", "Go")})
            value = await mcp.call(
                "evaluate_script",
                {"pageId": page, "function": "() => document.getElementById('name').value"},
            )
            assert "Ada" in _text(value)
            console = _text(await mcp.call("list_console_messages", {"pageId": page}))
            assert "clicked Ada" in console
            await mcp.call("wait_for", {"pageId": page, "text": ["Go"]})
            network = _text(await mcp.call("list_network_requests", {"pageId": page}))
            assert "data.json" in network
            screenshot = await mcp.call("take_screenshot", {"pageId": page})
            assert any(item["type"] == "image" for item in screenshot["content"]), screenshot

            await mcp.call(
                "navigate_page", {"pageId": page, "type": "url", "url": f"{base}/second.html"}
            )
            title = await mcp.call(
                "evaluate_script", {"pageId": page, "function": "() => document.title"}
            )
            assert "Second page" in _text(title)

            opened = _text(
                await mcp.call("new_page", {"url": f"{base}/opened.html", "background": True})
            )
            assert f"{base}/opened.html" in opened and "personal" not in opened
            agent_tabs = await host_manager.list_tabs("conv_agent")
            assert sorted(str(tab["url"]) for tab in agent_tabs) == [
                f"{base}/opened.html",
                f"{base}/second.html",
            ]
            assert [tab["created_by"] for tab in agent_tabs if "opened" in str(tab["url"])] == [
                "agent"
            ]
            # The proxy badged the tab it clicked, filled and navigated on the host.
            acted = [tab for tab in agent_tabs if "second" in str(tab["url"])]
            assert [tab.get("agent_state") for tab in acted] == ["active"]
            assert [event["type"] for event in published] == ["session.resource.created"]
            personal_tabs = await host_manager.list_tabs("conv_personal")
            assert [(tab["id"], tab["url"]) for tab in personal_tabs] == [
                (personal["id"], f"{base}/personal.html")
            ]
        finally:
            terminate_process(process, timeout_s=10)
            stderr_log.close()
            await service.stop()
