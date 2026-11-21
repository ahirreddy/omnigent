"""Start ``chrome-devtools-mcp`` for one session, installing the pinned release once.

The runner's MCP manager runs this module as the session's ``chrome_devtools``
stdio server. It finds Node.js the way Omnigent finds other CLIs (``PATH``,
Homebrew, mise, nvm, ``~/.local/bin``, or ``OMNIGENT_NODE_PATH``), installs the
pinned package into Omnigent's data dir on first use with the machine's own npm
configuration (``~/.npmrc``, ``npm_config_registry``), and then replaces itself
with the real server. When a step fails it serves a one-tool MCP server whose
tool says what to fix, so the agent can tell the user instead of silently
having no browser.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from pathlib import Path
from typing import Final, TextIO

from omnigent._platform import node_install_dirs, resolve_cli_binary
from omnigent.browser_devtools_availability import (
    CHROME_DEVTOOLS_MCP_NAME,
    CHROME_DEVTOOLS_MCP_VERSION,
)
from omnigent.process_logging import data_dir

NODE_PATH_ENV: Final[str] = "OMNIGENT_NODE_PATH"
# chrome-devtools-mcp's own ``engines`` floor.
MIN_NODE_VERSION: Final[tuple[int, int]] = (20, 19)
_BIN_PATH: Final[tuple[str, ...]] = ("build", "src", "bin", "chrome-devtools-mcp.js")
_INSTALL_TIMEOUT_S: Final[float] = 150.0
_VERSION_TIMEOUT_S: Final[float] = 15.0
_UNAVAILABLE_TOOL: Final[str] = "browser_unavailable"
_ERROR_TAIL_CHARS: Final[int] = 600


class LaunchError(Exception):
    """A step before the real server could start failed; the message is for the agent."""


def node_candidates() -> list[str]:
    """Where node may be, in order: ``OMNIGENT_NODE_PATH``, ``PATH`` and the usual install
    dirs, then the versions mise and nvm installed (their shims fail where no version is
    selected, so each candidate is run before it is trusted)."""
    candidates: list[str] = []
    resolved = resolve_cli_binary("node", env_var=NODE_PATH_ENV)
    if resolved is not None:
        candidates.append(resolved)
    for directory in node_install_dirs():
        node = directory / "node"
        if node.is_file() and os.access(node, os.X_OK) and str(node) not in candidates:
            candidates.append(str(node))
    return candidates


def resolve_node() -> str:
    """Find a Node.js that runs and is new enough for chrome-devtools-mcp.

    :raises LaunchError: When none runs, or every one that runs is too old.
    """
    rejected: list[str] = []
    for node in node_candidates():
        version = node_version(node)
        if version is None:
            rejected.append(f"{node} does not run")
        elif version < MIN_NODE_VERSION:
            rejected.append(f"{node} is version {'.'.join(str(part) for part in version)}")
        else:
            return node
    found = f" ({'; '.join(rejected)})" if rejected else ""
    raise LaunchError(
        "Chrome DevTools needs Node.js 20.19 or newer on the agent's machine, and none was "
        f"found on PATH or in Homebrew, mise, nvm or ~/.local/bin{found}. Install Node.js, or "
        f"set {NODE_PATH_ENV} to its node binary, then start a new session."
    )


def node_version(node: str) -> tuple[int, ...] | None:
    """The version ``node --version`` reports, e.g. ``(22, 13, 0)``; ``None`` when it fails."""
    try:
        completed = subprocess.run(
            [node, "--version"],
            capture_output=True,
            text=True,
            timeout=_VERSION_TIMEOUT_S,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    parts = completed.stdout.strip().lstrip("v").split(".")
    try:
        return tuple(int(part) for part in parts)
    except ValueError:
        return None


def install_root() -> Path:
    """Where pinned releases live: ``<data dir>/browser/chrome-devtools-mcp``."""
    return data_dir() / "browser" / CHROME_DEVTOOLS_MCP_NAME


def ensure_installed(node: str, *, root: Path, version: str = CHROME_DEVTOOLS_MCP_VERSION) -> Path:
    """Install the pinned release under *root* once and return its server script.

    Concurrent sessions wait on one lock; a partial install never becomes visible.

    :raises LaunchError: When npm is missing or cannot fetch the package.
    """
    script = root / version / "node_modules" / CHROME_DEVTOOLS_MCP_NAME / Path(*_BIN_PATH)
    if script.is_file():
        return script
    root.mkdir(parents=True, exist_ok=True)
    with (root / f"{version}.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if script.is_file():
            return script
        staging = Path(tempfile.mkdtemp(prefix=f"{version}-", dir=root))
        try:
            _npm_install(node, staging, f"{CHROME_DEVTOOLS_MCP_NAME}@{version}")
            installed = staging / "node_modules" / CHROME_DEVTOOLS_MCP_NAME / Path(*_BIN_PATH)
            if not installed.is_file():
                raise LaunchError(
                    f"npm installed {CHROME_DEVTOOLS_MCP_NAME}@{version}, but it has no server "
                    "script; the package layout changed."
                )
            target = root / version
            if target.exists():
                shutil.rmtree(target)
            staging.rename(target)
        finally:
            if staging.exists():
                shutil.rmtree(staging, ignore_errors=True)
    return script


def _npm_install(node: str, prefix: Path, package: str) -> None:
    npm = Path(node).with_name("npm")
    npm_path = str(npm) if npm.is_file() else resolve_cli_binary("npm")
    if npm_path is None:
        raise LaunchError(
            f"Chrome DevTools installs {package} with npm, and npm was not found next to "
            f"{node} or on PATH. Install npm, then start a new session."
        )
    # npm runs under node: keep the resolved node first on PATH for it.
    env = {
        **os.environ,
        "PATH": os.pathsep.join([str(Path(node).parent), os.environ.get("PATH", "")]),
    }
    argv = [
        npm_path,
        "install",
        "--prefix",
        str(prefix),
        "--no-audit",
        "--no-fund",
        "--no-save",
        "--ignore-scripts",
        "--loglevel=error",
        package,
    ]
    try:
        completed = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=_INSTALL_TIMEOUT_S,
            env=env,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LaunchError(_npm_failure(package, str(exc))) from exc
    if completed.returncode != 0:
        raise LaunchError(_npm_failure(package, (completed.stderr or completed.stdout).strip()))


def _npm_failure(package: str, detail: str) -> str:
    tail = detail[-_ERROR_TAIL_CHARS:] if detail else "no output"
    return (
        f"Could not install {package} with npm ({tail}). npm takes its registry from "
        "~/.npmrc or the npm_config_registry environment variable: point it at a registry "
        "this machine can reach, then start a new session."
    )


def serve_unavailable(reason: str, stdin: TextIO, stdout: TextIO) -> None:
    """Serve MCP over stdio with one tool that explains why the browser is unavailable."""
    tool = {
        "name": _UNAVAILABLE_TOOL,
        "description": f"Chrome DevTools is unavailable in this session: {reason}",
        "inputSchema": {"type": "object", "properties": {}},
    }
    for line in stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if not isinstance(message, dict) or "id" not in message:
            continue
        method = message.get("method")
        result: object
        if method == "initialize":
            params = message.get("params") or {}
            result = {
                "protocolVersion": params.get("protocolVersion", "2025-06-18"),
                "capabilities": {"tools": {}},
                "serverInfo": {
                    "name": f"{CHROME_DEVTOOLS_MCP_NAME} (unavailable)",
                    "version": "0",
                },
            }
        elif method == "tools/list":
            result = {"tools": [tool]}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": reason}], "isError": True}
        elif method == "ping":
            result = {}
        else:
            reply = {
                "jsonrpc": "2.0",
                "id": message["id"],
                "error": {"code": -32601, "message": f"Method not found: {method}"},
            }
            stdout.write(json.dumps(reply) + "\n")
            stdout.flush()
            continue
        stdout.write(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}) + "\n")
        stdout.flush()


def server_args(ws_endpoint: str) -> list[str]:
    """chrome-devtools-mcp's arguments: the session's proxy, no telemetry, no CrUX lookups."""
    return ["--wsEndpoint", ws_endpoint, "--no-usage-statistics", "--no-performance-crux"]


def main(argv: Sequence[str] | None = None) -> None:
    """Install if needed, then become chrome-devtools-mcp; on failure, explain over MCP."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--ws-endpoint", required=True)
    args = parser.parse_args(argv)
    try:
        node = resolve_node()
        script = ensure_installed(node, root=install_root())
    except (LaunchError, OSError) as exc:
        print(f"chrome_devtools: {exc}", file=sys.stderr, flush=True)
        with contextlib.suppress(BrokenPipeError):
            serve_unavailable(str(exc), sys.stdin, sys.stdout)
        return
    os.execv(node, [node, str(script), *server_args(args.ws_endpoint)])


if __name__ == "__main__":
    main()
