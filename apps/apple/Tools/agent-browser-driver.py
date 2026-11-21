"""Plays a session's agent against the Mac app's own Chromium, for the agent browser UI flow.

The real ``chrome-devtools-mcp`` connects to the runner's scoped CDP proxy, which reaches
the app through the owner-only ``browser.devtools_request`` relay and the app's gated
DevTools endpoint, exactly as a runner on the same Mac does. ``MacAgentBrowserFlowUITests``
starts this script and drives it one command per stdin line; each answer is one JSON line
on stdout:

- ``act``: lists the session's pages, opens a page of a local site in a new tab, fills a
  field, clicks a button, reads the result with a script and takes a screenshot.
- ``click``: clicks the button again; while the user holds the tab it answers ``ok: false``
  and ``user_in_control: true`` with chrome-devtools-mcp's text.
- ``quit``: disconnects the agent and exits.

Usage: agent-browser-driver.py --server http://127.0.0.1:6767 --session SESSION_ID
       --data-dir DIR (where the pinned chrome-devtools-mcp is installed)
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import functools
import http.server
import json
import logging
import sys
import threading
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import httpx

from omnigent.runner.browser_devtools.resolver import RunnerBrowserResolver
from omnigent.runner.browser_devtools.server import BrowserDevtoolsService
from omnigent.runner.browser_host import BrowserHostManager, BrowserHostSettings
from tests._helpers.chrome_devtools_mcp import (
    McpClient,
    page_ids,
    snapshot_uid,
    start_chrome_devtools_mcp,
    tool_text,
)
from tests._helpers.live_server import terminate_process

REPO_ROOT = Path(__file__).resolve().parents[3]
FORM_PAGE = (
    "<!doctype html><title>Agent form</title>"
    '<label for="name">Name</label><input id="name">'
    '<button id="go" onclick="document.getElementById(\'out\').textContent = '
    "'Hello ' + document.getElementById('name').value; document.title = "
    "'Greeted ' + document.getElementById('name').value\">Greet</button>"
    '<p id="out"></p>'
)


@contextlib.contextmanager
def _site(root: Path) -> Iterator[str]:
    (root / "form.html").write_text(FORM_PAGE, encoding="utf-8")
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}/form.html"
    finally:
        server.shutdown()
        server.server_close()


def _answer(payload: dict[str, Any]) -> None:
    print(json.dumps(payload), flush=True)


class Agent:
    """The session's agent: one MCP client and the page it works on."""

    def __init__(self, mcp: McpClient, form_url: str) -> None:
        self._mcp = mcp
        self._form_url = form_url
        self._page: int | None = None
        self._button: str | None = None

    async def act(self) -> dict[str, Any]:
        before = tool_text(await self._mcp.call("list_pages", {}))
        opened = tool_text(
            await self._mcp.call("new_page", {"url": self._form_url, "background": True})
        )
        self._page = page_ids(opened)[self._form_url]
        await self._mcp.call("wait_for", {"pageId": self._page, "text": ["Greet"]})
        snapshot = tool_text(await self._mcp.call("take_snapshot", {"pageId": self._page}))
        field = snapshot_uid(snapshot, "textbox", "Name")
        self._button = snapshot_uid(snapshot, "button", "Greet")
        await self._mcp.call("fill", {"pageId": self._page, "uid": field, "value": "Ada"})
        await self._mcp.call("click", {"pageId": self._page, "uid": self._button})
        greeting = tool_text(
            await self._mcp.call(
                "evaluate_script",
                {
                    "pageId": self._page,
                    "function": "() => [document.getElementById('out').textContent, "
                    "document.visibilityState, document.hasFocus()].join('|')",
                },
            )
        )
        screenshot = await self._mcp.call("take_screenshot", {"pageId": self._page})
        images = [item for item in screenshot["content"] if item["type"] == "image"]
        return {
            "ok": True,
            "pages_before": before,
            "opened": opened,
            "greeting": greeting,
            "screenshot_base64_chars": sum(len(item.get("data", "")) for item in images),
        }

    async def click(self) -> dict[str, Any]:
        if self._page is None or self._button is None:
            return {"ok": False, "error": "act first"}
        result = await self._mcp.call_result("click", {"pageId": self._page, "uid": self._button})
        text = tool_text(result)
        # A click under way when the user took over ends on the dialog without an error.
        held = "user_in_control" in text
        return {
            "ok": not result.get("isError") and not held,
            "user_in_control": held,
            "text": text,
        }


async def run(server: str, session_id: str, data_dir: Path, work: Path) -> int:
    manager = BrowserHostManager(BrowserHostSettings(enabled=False, data_dir=work / "hosts"))
    async with httpx.AsyncClient(base_url=server, timeout=60.0) as client:
        service = BrowserDevtoolsService(
            RunnerBrowserResolver(manager, lambda _session, _event: None, client)
        )
        await service.ensure_started()
        log_path = work / "chrome-devtools-mcp.log"
        with _site(work) as form_url, log_path.open("w") as log:
            process = start_chrome_devtools_mcp(
                service.endpoint_for(session_id),
                repo_root=REPO_ROOT,
                data_dir=data_dir,
                stderr=log,
            )
            try:
                mcp = McpClient(process, log_path)
                tools = await mcp.initialize()
                _answer({"ok": True, "ready": True, "tools": len(tools)})
                return await _serve(Agent(mcp, form_url))
            finally:
                terminate_process(process, timeout_s=10)
                await service.stop()


async def _serve(agent: Agent) -> int:
    while True:
        line = await asyncio.to_thread(sys.stdin.readline)
        command = line.strip()
        if not line or command == "quit":
            return 0
        try:
            if command == "act":
                _answer(await agent.act())
            elif command == "click":
                _answer(await agent.click())
            else:
                _answer({"ok": False, "error": f"unknown command {command!r}"})
        except (AssertionError, KeyError) as exc:
            # The UI flow reports the agent's failure with the MCP server's own words.
            _answer({"ok": False, "error": f"{type(exc).__name__}: {str(exc)[-2000:]}"})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--server", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--data-dir", required=True, type=Path)
    parser.add_argument("--work-dir", required=True, type=Path)
    args = parser.parse_args()
    args.work_dir.mkdir(parents=True, exist_ok=True)
    # The proxy's own log, on stderr, for the flow's failure report.
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)
    return asyncio.run(run(args.server, args.session, args.data_dir, args.work_dir))


if __name__ == "__main__":
    sys.exit(main())
