"""E2E: a client attaches to a remote browser tab through the real server relay.

Covers the process and transport boundaries the lower-layer tests stub out:
client WebSocket -> server route -> runner WS tunnel channel -> runner route ->
a host process the runner spawned (the fake host, which replays the protocol
fixtures). The client must receive the host's frames, and its input must reach
the host. Deleting the session must close the session's tabs.

The second test runs the same path against the real ``omnigent-browser-host``
with a real page, H.264 frames and click/navigation input. It runs only when
``OMNIGENT_TEST_BROWSER_HOST_BIN`` names the host binary and ``x264`` (or ffmpeg
with libx264) is on PATH.

Usage::

    pytest tests/e2e/test_remote_browser_relay_e2e.py -v
    OMNIGENT_TEST_BROWSER_HOST_BIN=browser-host/build/mac/host/omnigent-browser-host \
        pytest tests/e2e/test_remote_browser_relay_e2e.py -v -s
"""

from __future__ import annotations

import asyncio
import contextlib
import http.server
import json
import os
import threading
import time
from collections.abc import Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path

import httpx
import pytest
from websockets.sync.client import ClientConnection, connect

from omnigent.runner.browser_host import BrowserHostSettings, detect_encoder, host_request
from tests._helpers.fake_browser_host import install_fake_browser_host, stop_fake_browser_hosts
from tests._helpers.server_runner import server_runner
from tests._helpers.session import bind_session_runner, bundle_files, post_session_bundle
from tests.e2e.helpers import HEALTH_TIMEOUT_S, POLL_INTERVAL_S

_FIXTURES = Path(__file__).resolve().parents[2] / "client-core" / "fixtures" / "remote_browser"
_AGENT_CONFIG = (
    "spec_version: 1\nname: browser_fixture_agent\nprompt: Fixture agent.\n"
    "executor:\n  model: mock-model\n  config:\n    harness: openai-agents\n"
)

pytestmark = pytest.mark.skipif(os.name != "posix", reason="browser hosts use Unix sockets")


def _client_message(name: str) -> str:
    return (_FIXTURES / "messages" / "client_to_host" / f"{name}.json").read_text("utf-8")


def _host_messages(browser_dir: Path, tab_id: str) -> list[dict[str, object]]:
    state = json.loads((browser_dir / "profiles" / "default" / "host.json").read_text("utf-8"))
    result = asyncio.run(host_request(Path(state["socket"]), "fake.received", {"tab_id": tab_id}))
    messages = result["messages"]
    assert isinstance(messages, list)
    return messages


def _host_tabs(browser_dir: Path, session_id: str) -> list[dict[str, object]]:
    state = json.loads((browser_dir / "profiles" / "default" / "host.json").read_text("utf-8"))
    result = asyncio.run(
        host_request(Path(state["socket"]), "tabs.list", {"session_id": session_id})
    )
    tabs = result["tabs"]
    assert isinstance(tabs, list)
    return tabs


@dataclass
class _BrowserStack:
    client: httpx.Client
    session_id: str
    resources: str
    attach_base: str
    browser_dir: Path


@contextlib.contextmanager
def _browser_stack(tmp_path: Path, browser_env: Mapping[str, str]) -> Iterator[_BrowserStack]:
    """A real server and runner (remote browser on) with one bound session."""
    env = {"OPENAI_API_KEY": "mock-key", "OMNIGENT_NO_UPDATE_CHECK": "1"}
    with server_runner(
        tmp_path / "stack",
        server_env=env,
        health_timeout=HEALTH_TIMEOUT_S,
        poll_interval=POLL_INTERVAL_S,
    ) as stack:
        browser_dir = stack.runner_home / ".omnigent" / "browser"
        try:
            stack.start_runner(
                env={**env, "OMNIGENT_REMOTE_BROWSER": "1", **browser_env}, python_args=["-P"]
            )
            with httpx.Client(base_url=stack.base_url, trust_env=False, timeout=120) as client:
                created = post_session_bundle(
                    client.post,
                    "/v1/sessions",
                    bundle_files({"config.yaml": _AGENT_CONFIG.encode()}),
                    metadata={"title": "Remote browser relay"},
                )
                assert created.status_code == 201, created.text
                session_id = created.json()["session_id"]
                bind_session_runner(client.patch, "", session_id, stack.runner_id)
                resources = f"/v1/sessions/{session_id}/resources"
                yield _BrowserStack(
                    client=client,
                    session_id=session_id,
                    resources=resources,
                    attach_base=f"{stack.base_url.replace('http://', 'ws://')}{resources}/browsers",
                    browser_dir=browser_dir,
                )
        finally:
            stop_fake_browser_hosts(browser_dir, timeout_s=15.0)


def test_client_attaches_through_server_relay_to_runner_spawned_host(tmp_path: Path) -> None:
    binary, encoder = install_fake_browser_host(tmp_path / "bin")
    browser_env = {
        "OMNIGENT_BROWSER_HOST_BIN": str(binary),
        "OMNIGENT_BROWSER_ENCODER": str(encoder),
        "OMNIGENT_BROWSER_HOST_ARGS": "--idle-exit-seconds 60",
    }
    with _browser_stack(tmp_path, browser_env) as browser:
        client, base = browser.client, browser.resources
        tab = client.post(f"{base}/browsers", json={"url": "https://example.com/"})
        assert tab.status_code == 200, tab.text
        tab_id = tab.json()["id"]
        assert tab.json()["type"] == "browser"
        listed = client.get(f"{base}/browsers").json()
        assert [item["id"] for item in listed["data"]] == [tab_id]
        profiles = client.get(f"{base}/browser_profiles").json()
        assert {"name": "default", "default": True, "running": True} in profiles["data"]

        attach = f"{browser.attach_base}/{tab_id}/attach"
        with connect(f"{attach}?mode=control&v=1") as websocket:
            websocket.send(_client_message("hello"))
            hello = json.loads(websocket.recv(timeout=30))
            assert hello["type"] == "hello" and hello["tab_id"] == tab_id
            assert hello["mode"] == "control"
            setup = [json.loads(websocket.recv(timeout=10))["type"] for _ in range(5)]
            assert setup == ["control", "viewport", "nav", "cursor", "text_input"]
            idr = websocket.recv(timeout=10)
            assert idr == (_FIXTURES / "binary_frames" / "h264_idr.bin").read_bytes()
            assert isinstance(websocket.recv(timeout=10), bytes)
            websocket.send(_client_message("mouse_down"))
            websocket.send(json.dumps({"type": "ping", "nonce": "e2e"}))
            assert json.loads(websocket.recv(timeout=10)) == {"type": "pong", "nonce": "e2e"}
        with connect(attach) as viewer:
            viewer.send(_client_message("hello"))
            assert json.loads(viewer.recv(timeout=30))["mode"] == "view"
            viewer.send(_client_message("key_down"))
            viewer.send(json.dumps({"type": "ping", "nonce": "view"}))
            while (frame := viewer.recv(timeout=10)) and (
                isinstance(frame, bytes) or json.loads(frame).get("type") != "pong"
            ):
                continue
        received = [message["type"] for message in _host_messages(browser.browser_dir, tab_id)]
        assert received == ["hello", "mouse", "ping", "hello", "ping"]

        deleted = client.delete(f"/v1/sessions/{browser.session_id}")
        assert deleted.status_code in (200, 204), deleted.text
        assert _host_tabs(browser.browser_dir, browser.session_id) == []


_PAGES = {
    "/one.html": (
        "<title>One</title><body style='margin:0'><button style='position:absolute;left:0;"
        "top:0;width:600px;height:400px' onclick=\"document.title='Clicked'\">go</button>"
    ),
    "/two.html": "<title>Two</title><body>second page</body>",
}


class _PageHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        page = _PAGES.get(self.path)
        self.send_response(200 if page else 404)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write((page or "missing").encode())

    def log_message(self, format: str, *args: object) -> None:
        del format, args


def _until(
    websocket: ClientConnection, predicate: object, *, timeout: float
) -> tuple[dict[str, object], int]:
    """Read (acking media) until a text message satisfies *predicate*; count media frames."""
    assert callable(predicate)
    deadline = time.monotonic() + timeout
    media = 0
    while True:
        frame = websocket.recv(timeout=max(0.1, deadline - time.monotonic()))
        if isinstance(frame, bytes):
            media += 1
            websocket.send(
                json.dumps({"type": "ack", "seq": int.from_bytes(frame[8:12], "little")})
            )
            continue
        message = json.loads(frame)
        if predicate(message):
            return message, media


def _click(websocket: ClientConnection, x: int, y: int) -> None:
    """Move, press (left-button modifier bit 6) and release at viewport CSS px."""
    for kind, modifiers in (("move", 0), ("down", 64), ("up", 0)):
        message: dict[str, object] = {"type": "mouse", "kind": kind, "x": x, "y": y}
        if kind != "move":
            message |= {"button": "left", "clicks": 1}
        websocket.send(json.dumps({**message, "modifiers": modifiers}))


def _is_idr(frame: bytes) -> bool:
    flags = int.from_bytes(frame[4:6], "little")
    payload = frame[int.from_bytes(frame[6:8], "little") :]
    return (
        frame[:2] == b"RB"
        and frame[3] == 1
        and flags & 3 == 3
        and b"\x00\x00\x01\x67" in (payload.replace(b"\x00\x00\x00\x01", b"\x00\x00\x01"))
    )


def test_real_host_streams_h264_and_takes_input_through_the_relay(tmp_path: Path) -> None:
    host_bin = os.environ.get("OMNIGENT_TEST_BROWSER_HOST_BIN")
    if not host_bin:
        pytest.skip("set OMNIGENT_TEST_BROWSER_HOST_BIN to the real omnigent-browser-host")
    encoder = detect_encoder(BrowserHostSettings(enabled=True, data_dir=tmp_path))
    if encoder is None:
        pytest.skip("the real host needs x264 or ffmpeg with libx264 on PATH")
    binary = Path(host_bin).resolve()
    pages = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _PageHandler)
    threading.Thread(target=pages.serve_forever, daemon=True).start()
    origin = f"http://127.0.0.1:{pages.server_address[1]}"
    browser_env = {
        "OMNIGENT_BROWSER_HOST_BIN": str(binary),
        "OMNIGENT_BROWSER_ENCODER": str(encoder.path),
        "OMNIGENT_BROWSER_HOST_ARGS": os.environ.get(
            "OMNIGENT_TEST_BROWSER_HOST_ARGS", "--idle-exit-seconds 120"
        ),
    }
    try:
        with _browser_stack(tmp_path, browser_env) as browser:
            client, base = browser.client, browser.resources
            started = time.monotonic()
            tab = client.post(f"{base}/browsers", json={"url": f"{origin}/one.html"})
            assert tab.status_code == 200, tab.text
            tab_id = tab.json()["id"]
            create_s = time.monotonic() - started
            attach = f"{browser.attach_base}/{tab_id}/attach"
            with connect(f"{attach}?mode=control&v=1", max_size=16 * 1024 * 1024) as websocket:
                attached = time.monotonic()
                websocket.send(_client_message("hello"))
                setup: list[dict[str, object]] = []
                while not isinstance(frame := websocket.recv(timeout=30), bytes):
                    setup.append(json.loads(frame))
                first_frame_s = time.monotonic() - attached
                assert [message["type"] for message in setup[:6]] == [
                    "hello",
                    "control",
                    "viewport",
                    "nav",
                    "cursor",
                    "text_input",
                ]
                assert _is_idr(frame), frame[:24].hex()
                websocket.send(json.dumps({"type": "ack", "seq": 1}))

                def loaded(message: dict[str, object]) -> bool:
                    return message.get("title") == "One" and message.get("loading") is False

                # A fast page can finish loading before the first IDR goes out.
                if not any(loaded(message) for message in setup):
                    _until(websocket, loaded, timeout=20)
                websocket.send(json.dumps({"type": "control", "op": "take"}))
                _until(websocket, lambda m: m.get("holder") == "this", timeout=10)
                # A click right after first paint is sometimes lost by the host, so
                # repeat it until the page reacts and report how many it took.
                click_attempts = 0
                while True:
                    click_attempts += 1
                    clicked = time.monotonic()
                    _click(websocket, 100, 100)
                    try:
                        _until(websocket, lambda m: m.get("title") == "Clicked", timeout=1.0)
                        break
                    except TimeoutError:
                        assert click_attempts < 10, "the page never saw a click"
                click_to_title_ms = (time.monotonic() - clicked) * 1000
                websocket.send(
                    json.dumps({"type": "nav", "op": "navigate", "url": f"{origin}/two.html"})
                )
                _message, media = _until(websocket, lambda m: m.get("title") == "Two", timeout=15)
            with connect(attach, max_size=16 * 1024 * 1024) as viewer:
                viewer.send(json.dumps({**json.loads(_client_message("hello")), "mode": "view"}))
                hello = json.loads(viewer.recv(timeout=30))
                assert hello["mode"] == "view"
                while not isinstance(frame := viewer.recv(timeout=30), bytes):
                    continue
                assert _is_idr(frame)
            print(
                f"real host: tab create {create_s:.2f}s (includes host start), "
                f"first IDR {first_frame_s * 1000:.0f} ms after attach, "
                f"click -> title {click_to_title_ms:.0f} ms ({click_attempts} click(s)), "
                f"{media} frames during navigation"
            )
            deleted = client.delete(f"/v1/sessions/{browser.session_id}")
            assert deleted.status_code in (200, 204), deleted.text
            assert _host_tabs(browser.browser_dir, browser.session_id) == []
    finally:
        pages.shutdown()
