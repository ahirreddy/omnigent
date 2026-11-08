#!/usr/bin/env python3
"""Serve a mock LLM for the local API and install an agent that talks to it.

`serve` runs the integration-test mock LLM on 127.0.0.1:6796 with a streamed, paced fallback
reply, so every turn answers without a provider account. `install-agent` installs the
"mock-model" user agent on the local API (127.0.0.1:6767); its spec names the mock as its
OpenAI-compatible endpoint, so the host needs no extra environment. No real model is called.
"""

from __future__ import annotations

import argparse
import io
import json
import signal
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
MOCK_SERVER = REPO / "tests" / "server" / "integration" / "mock_llm_server.py"
DEFAULT_PORT = 6796
DEFAULT_API = "http://127.0.0.1:6767"
MODEL = "mock-model"
AGENT_NAME = "mock-model"

# Markdown that exercises the transcript renderer: headings, lists, code, a table, links.
REPLY = """\
This reply comes from the **local mock model**, streamed word by word so the transcript shows \
progressive delivery.

## What it covers

- Paragraphs that wrap across several lines in a narrow window, with `inline code` and a \
[link](https://example.com).
- A numbered list:
  1. First item
  2. Second item with **bold** and *italic* text
- A fenced code block:

```swift
struct Greeting {
    let name: String
    func render() -> String { "Hello, \\(name)!" }
}
```

| Column | Value |
| ------ | ----- |
| Rows   | 2     |
| Mock   | yes   |

> Every turn gets this same reply. Queue other replies with POST /mock/configure.
"""


class MockModelError(RuntimeError):
    """A step of serving or installing failed."""


def agent_spec(port: int) -> str:
    """Returns the agent's config.yaml, pointed at the mock on `port`."""
    return (
        "spec_version: 1\n"
        f"name: {AGENT_NAME}\n"
        "description: Streams a canned reply from the local mock LLM; no provider account.\n"
        "prompt: |\n"
        "  You are a deterministic fixture assistant for testing the native apps.\n"
        "executor:\n"
        f"  model: {MODEL}\n"
        "  config:\n"
        "    harness: openai-agents\n"
        "  auth:\n"
        "    type: api_key\n"
        "    api_key: mock-not-a-real-key\n"
        f"    base_url: http://127.0.0.1:{port}/v1\n"
        "os_env:\n"
        "  type: caller_process\n"
        "  cwd: .\n"
        "  sandbox:\n"
        "    type: none\n"
        # A plain shell, so the apps' terminal tabs open in mock sessions.
        "terminals:\n"
        "  shell:\n"
        "    command: bash\n"
        '    args: ["--noprofile", "--norc"]\n'
        "    os_env: inherit\n"
    )


def agent_bundle(port: int) -> bytes:
    """Returns the gzipped tarball `POST /v1/agents` takes."""
    data = agent_spec(port).encode()
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        info = tarfile.TarInfo("config.yaml")
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def multipart(field: str, filename: str, payload: bytes) -> tuple[bytes, str]:
    """Encodes one file part; returns the body and its content type."""
    boundary = uuid.uuid4().hex
    head = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'
        "Content-Type: application/gzip\r\n\r\n"
    ).encode()
    return (
        head + payload + f"\r\n--{boundary}--\r\n".encode(),
        f"multipart/form-data; boundary={boundary}",
    )


def request(url: str, body: bytes | None = None, content_type: str | None = None) -> dict:
    """Sends a request without proxies; raises MockModelError with the server's reply."""
    req = urllib.request.Request(url, data=body, method="POST" if body is not None else "GET")
    if content_type:
        req.add_header("Content-Type", content_type)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=30) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:500]
        raise MockModelError(f"{req.method} {url} -> {error.code}: {detail}") from error
    except urllib.error.URLError as error:
        raise MockModelError(f"{req.method} {url} failed: {error.reason}") from error


def wait_until_ready(port: int, child: subprocess.Popen, timeout: float = 30) -> None:
    """Waits for the mock's /stats; raises if the child exits or the time runs out."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise MockModelError(f"the mock LLM exited with status {child.returncode}")
        try:
            request(f"http://127.0.0.1:{port}/stats")
            return
        except MockModelError:
            time.sleep(0.2)
    raise MockModelError(f"the mock LLM did not answer on port {port} within {timeout:.0f} s")


def serve(port: int, chunk_delay: float) -> int:
    """Runs the mock in the foreground with the fallback reply set; returns its exit status."""
    child = subprocess.Popen([sys.executable, str(MOCK_SERVER), str(port)], cwd=REPO)
    signal.signal(signal.SIGTERM, lambda *_: child.terminate())
    try:
        wait_until_ready(port, child)
        for key in (MODEL, "default"):
            fallback = {"key": key, "text": REPLY, "stream": True, "chunk_delay": chunk_delay}
            request(
                f"http://127.0.0.1:{port}/mock/set_fallback",
                json.dumps(fallback).encode(),
                "application/json",
            )
        print(
            f"mock model on http://127.0.0.1:{port}/v1 (model {MODEL!r}); Ctrl-C stops it",
            flush=True,
        )
        return child.wait()
    except KeyboardInterrupt:
        child.terminate()
        return child.wait()
    except BaseException:
        child.terminate()
        child.wait()
        raise


def install_agent(api: str, port: int) -> dict:
    """Installs (or reinstalls) the mock agent; returns the server's agent object."""
    body, content_type = multipart("bundle", "agent.tar.gz", agent_bundle(port))
    return request(f"{api.rstrip('/')}/v1/agents", body, content_type)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    serve_parser = commands.add_parser("serve", help="run the mock LLM in the foreground")
    serve_parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    serve_parser.add_argument(
        "--chunk-delay", type=float, default=0.03, help="seconds between words"
    )
    install = commands.add_parser("install-agent", help="install the mock-model agent")
    install.add_argument("--api", default=DEFAULT_API)
    install.add_argument("--port", type=int, default=DEFAULT_PORT, help="the mock LLM's port")
    args = parser.parse_args()
    try:
        if args.command == "serve":
            return serve(args.port, args.chunk_delay)
        agent = install_agent(args.api, args.port)
        print(f"installed agent {agent.get('name')!r} ({agent.get('id')}) on {args.api}")
        return 0
    except MockModelError as error:
        print(f"mock-model: error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
