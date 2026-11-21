"""Drive a real ``chrome-devtools-mcp`` over stdio JSON-RPC, as an agent's harness would.

Used by the browser-host E2E and by the Mac app's agent browser flow driver
(``apps/apple/Tools/agent-browser-driver.py``).
"""

from __future__ import annotations

import asyncio
import os
import re
import subprocess
from collections.abc import Mapping
from pathlib import Path
from typing import Any, TextIO

from omnigent.browser_devtools_availability import browser_devtools_server
from tests._helpers.stdio_jsonrpc import read_json_line, write_json_line

# The first call waits for npm to fetch the package.
FIRST_CALL_TIMEOUT_S = 240.0
CALL_TIMEOUT_S = 90.0


class McpClient:
    """Newline-delimited JSON-RPC to the MCP server's stdio, off the event loop.

    :param process: The running server, with piped text stdin and stdout.
    :param stderr_path: Where its stderr goes, quoted when it stops answering.
    """

    def __init__(self, process: subprocess.Popen[str], stderr_path: Path) -> None:
        self._process = process
        self._stderr_path = stderr_path
        self._next_id = 1

    async def request(
        self, method: str, params: Mapping[str, object], *, timeout_s: float = CALL_TIMEOUT_S
    ) -> dict[str, Any]:
        """Send one request and return its result; an error answer fails the assertion."""
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
        """Send one notification."""
        assert self._process.stdin is not None
        write_json_line(self._process.stdin, {"jsonrpc": "2.0", "method": method})

    async def initialize(self) -> set[str]:
        """Run the MCP handshake and return the tool names."""
        await self.request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "omnigent-e2e", "version": "0"},
            },
            timeout_s=FIRST_CALL_TIMEOUT_S,
        )
        self.notify("notifications/initialized")
        return {tool["name"] for tool in (await self.request("tools/list", {}))["tools"]}

    async def call_result(self, tool: str, arguments: Mapping[str, object]) -> dict[str, Any]:
        """Call *tool* and return its result, refused or not."""
        return await self.request("tools/call", {"name": tool, "arguments": dict(arguments)})

    async def call(self, tool: str, arguments: Mapping[str, object]) -> dict[str, Any]:
        """Call *tool*; a refusal (``isError``) fails the assertion."""
        result = await self.call_result(tool, arguments)
        assert not result.get("isError"), (tool, result)
        return result


def start_chrome_devtools_mcp(
    endpoint: str, *, repo_root: Path, data_dir: Path, stderr: TextIO
) -> subprocess.Popen[str]:
    """Start the pinned ``chrome-devtools-mcp`` exactly as the runner configures it.

    :param endpoint: The session's proxy URL.
    :param repo_root: The checkout whose launcher runs.
    :param data_dir: ``OMNIGENT_DATA_DIR`` for the launcher, which installs the
        pinned release there once.
    :param stderr: Where the server's stderr goes.
    :returns: The process, with piped text stdin and stdout.
    """
    config = browser_devtools_server(endpoint)
    assert config.command is not None
    # A test venv may install another omnigent copy, so the launcher runs from this
    # checkout: without -I, ``-m`` puts the working directory first on the path.
    return subprocess.Popen(
        [config.command, *(arg for arg in config.args if arg != "-I")],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=stderr,
        text=True,
        cwd=repo_root,
        env={**os.environ, **config.env, "OMNIGENT_DATA_DIR": str(data_dir)},
    )


def tool_text(result: Mapping[str, Any]) -> str:
    """The text items of a tool result, joined by newlines."""
    return "\n".join(item.get("text", "") for item in result["content"] if item["type"] == "text")


def page_ids(listing: str) -> dict[str, int]:
    """Map each listed page's URL to its pageId (``"<id>: <title> (<url>)"`` lines)."""
    pages: dict[str, int] = {}
    for page_id, label in re.findall(r"^(\d+): (.*)$", listing, flags=re.MULTILINE):
        url = label.removesuffix(" [selected]").rsplit(" ", 1)[-1].strip("()")
        pages[url] = int(page_id)
    return pages


def snapshot_uid(snapshot: str, role: str, name: str) -> str:
    """The uid ``take_snapshot`` gave the element with *role* and accessible *name*."""
    match = re.search(rf'uid=(\S+) {role} "{re.escape(name)}"', snapshot)
    assert match, snapshot
    return match.group(1)
