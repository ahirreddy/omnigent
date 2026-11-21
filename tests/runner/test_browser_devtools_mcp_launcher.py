"""The chrome_devtools launcher: Node lookup, a one-time install, and an explaining stub.

Fake ``node`` and ``npm`` scripts stand in for the real tools, so the install
path runs without a network; the stub server is driven over in-memory stdio.
"""

from __future__ import annotations

import io
import json
from pathlib import Path

import pytest

from omnigent import _platform
from omnigent.runner.browser_devtools import mcp_launcher
from omnigent.runner.browser_devtools.mcp_launcher import (
    LaunchError,
    ensure_installed,
    resolve_node,
    serve_unavailable,
)


def _tools(directory: Path, *, version: str = "v22.13.0", npm_body: str = "") -> Path:
    """A fake ``node`` printing *version* and a fake ``npm`` running *npm_body*."""
    directory.mkdir(parents=True, exist_ok=True)
    node = directory / "node"
    node.write_text(f"#!/bin/sh\necho {version}\n")
    node.chmod(0o755)
    npm = directory / "npm"
    npm.write_text("#!/bin/sh\n" + npm_body)
    npm.chmod(0o755)
    return node


# The fake npm records each call and lays out the package under --prefix.
_INSTALLING_NPM = """
echo "$@" >> "$(dirname "$0")/npm-calls"
prefix="$3"
mkdir -p "$prefix/node_modules/chrome-devtools-mcp/build/src/bin"
echo '// server' > "$prefix/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"
"""


def test_the_pinned_release_installs_once_and_is_reused(tmp_path: Path) -> None:
    node = _tools(tmp_path / "bin", npm_body=_INSTALLING_NPM)
    root = tmp_path / "data" / "browser" / "chrome-devtools-mcp"

    first = ensure_installed(str(node), root=root, version="1.12.0")
    second = ensure_installed(str(node), root=root, version="1.12.0")

    assert (
        first
        == second
        == (root / "1.12.0/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js")
    )
    calls = (tmp_path / "bin" / "npm-calls").read_text().splitlines()
    assert len(calls) == 1 and calls[0].endswith("chrome-devtools-mcp@1.12.0")
    # No staging directory is left behind.
    assert sorted(path.name for path in root.iterdir()) == ["1.12.0", "1.12.0.lock"]


def test_a_failed_fetch_says_what_to_configure(tmp_path: Path) -> None:
    node = _tools(tmp_path / "bin", npm_body='echo "npm error code E403 forbidden" >&2\nexit 1\n')
    root = tmp_path / "root"

    with pytest.raises(LaunchError) as raised:
        ensure_installed(str(node), root=root, version="1.12.0")

    message = str(raised.value)
    assert "E403" in message and "~/.npmrc" in message and "npm_config_registry" in message
    assert not (root / "1.12.0").exists()


def test_a_missing_or_old_node_is_explained(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(_platform, "_cli_fallback_dirs", lambda: ())
    monkeypatch.setattr(mcp_launcher, "node_install_dirs", list)
    monkeypatch.setenv("PATH", str(tmp_path / "empty"))
    monkeypatch.delenv(mcp_launcher.NODE_PATH_ENV, raising=False)
    with pytest.raises(LaunchError, match="none was found"):
        resolve_node()

    old = _tools(tmp_path / "old", version="v18.20.0")
    monkeypatch.setenv(mcp_launcher.NODE_PATH_ENV, str(old))
    with pytest.raises(LaunchError, match=r"version 18\.20\.0"):
        resolve_node()

    current = _tools(tmp_path / "current")
    monkeypatch.setenv(mcp_launcher.NODE_PATH_ENV, str(current))
    assert resolve_node() == str(current)


def test_a_shim_that_does_not_run_gives_way_to_an_installed_version(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # A mise shim outside any configured directory exits 1 without a version.
    shims = tmp_path / "shims"
    shims.mkdir()
    shim = shims / "node"
    shim.write_text("#!/bin/sh\necho 'mise ERROR no version is set' >&2\nexit 1\n")
    shim.chmod(0o755)
    installed = _tools(tmp_path / "installs" / "22.13.0" / "bin")
    monkeypatch.setattr(_platform, "_cli_fallback_dirs", lambda: ())
    monkeypatch.setattr(mcp_launcher, "node_install_dirs", lambda: [installed.parent])
    monkeypatch.setenv("PATH", str(shims))
    monkeypatch.delenv(mcp_launcher.NODE_PATH_ENV, raising=False)

    assert resolve_node() == str(installed)


def test_the_stub_server_offers_one_tool_that_explains(tmp_path: Path) -> None:
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "X"}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": "browser_unavailable"},
        },
        {"jsonrpc": "2.0", "id": 4, "method": "resources/list"},
    ]
    stdin = io.StringIO("".join(json.dumps(request) + "\n" for request in requests))
    stdout = io.StringIO()

    serve_unavailable("Node.js is missing.", stdin, stdout)

    replies = [json.loads(line) for line in stdout.getvalue().splitlines()]
    assert [reply["id"] for reply in replies] == [1, 2, 3, 4]
    assert replies[0]["result"]["protocolVersion"] == "X"
    tool = replies[1]["result"]["tools"][0]
    assert tool["name"] == "browser_unavailable" and "Node.js is missing." in tool["description"]
    assert replies[2]["result"] == {
        "content": [{"type": "text", "text": "Node.js is missing."}],
        "isError": True,
    }
    assert replies[3]["error"]["code"] == -32601
