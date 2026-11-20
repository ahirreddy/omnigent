"""The Mac app's browser as an agent backend, and how a session picks its browser.

The server relay is an ``httpx.MockTransport`` answering as the owner's app
would; the app's DevTools port is a small loopback HTTP server, so the
same-machine check runs against a real socket.
"""

from __future__ import annotations

import contextlib
import http.server
import json
import threading
from collections.abc import Iterator
from typing import Any

import httpx
import pytest

from omnigent.runner.browser_devtools.app_backend import AppTabDirectory, app_backend
from omnigent.runner.browser_devtools.directory import TabDirectoryError
from omnigent.runner.browser_devtools.resolver import (
    BROWSER_TARGET_LABEL,
    RunnerBrowserResolver,
    backend_order,
)
from omnigent.runner.browser_devtools.server import BrowserUnavailableError
from omnigent.runner.browser_host import BrowserHostManager, BrowserHostSettings
from omnigent.stores.conversation_store import SCHEDULED_TASK_RUN_LABEL_KEY


@contextlib.contextmanager
def _devtools_port(browser_path: str) -> Iterator[int]:
    """A loopback ``/json/version`` like a CEF DevTools port."""

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            port = self.server.server_address[1]
            body = json.dumps({"webSocketDebuggerUrl": f"ws://127.0.0.1:{port}{browser_path}"})
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body.encode())

        def log_message(self, *_args: object) -> None:
            return None

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_address[1]
    finally:
        server.shutdown()
        server.server_close()


def _relay(
    answers: dict[str, dict[str, Any]],
    sent: list[dict[str, Any]],
    labels: dict[str, str] | None = None,
) -> httpx.AsyncClient:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/sessions/conv_a/labels":
            return httpx.Response(200, json={"labels": labels or {}})
        assert request.url.path == "/v1/sessions/conv_a/browser/devtools_request"
        body = json.loads(request.content)
        sent.append(body)
        return httpx.Response(200, json=answers[body["op"]])

    return httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="http://server.test")


async def test_the_app_browser_is_used_only_when_its_port_is_on_this_machine() -> None:
    sent: list[dict[str, Any]] = []
    with _devtools_port("/devtools/browser/GUID-1") as port:
        same = {"ok": True, "data": {"port": port, "browser_path": "/devtools/browser/GUID-1"}}
        other = {"ok": True, "data": {"port": port, "browser_path": "/devtools/browser/GUID-2"}}
        async with _relay({"attach": same}, sent) as client:
            backend = await app_backend(client, "conv_a")
        async with _relay({"attach": other}, sent) as client:
            with pytest.raises(BrowserUnavailableError, match="not on this machine"):
                await app_backend(client, "conv_a")

    assert backend.kind == "local"
    assert backend.upstream_url == f"ws://127.0.0.1:{port}/devtools/browser/GUID-1"
    assert sent[0] == {"op": "attach", "args": {}}


async def test_an_app_refusal_or_absence_explains_itself() -> None:
    refused = {"ok": False, "error": "agent_browsing_off", "message": "Turned off in Settings"}
    absent = {"error": "no browser renderer is connected"}
    async with _relay({"attach": refused}, []) as client:
        with pytest.raises(BrowserUnavailableError, match="Turned off in Settings"):
            await app_backend(client, "conv_a")
    async with _relay({"attach": absent}, []) as client:
        with pytest.raises(BrowserUnavailableError, match="no browser renderer"):
            await app_backend(client, "conv_a")


async def test_the_directory_maps_each_operation_to_the_app() -> None:
    sent: list[dict[str, Any]] = []
    tab = {"tab_id": "T1", "target_id": "TARGET1", "url": "https://example.com/", "owner": "user"}
    answers = {
        "tabs.list": {"ok": True, "data": {"tabs": [tab]}},
        "tabs.create": {"ok": True, "data": {**tab, "owner": "agent"}},
        "tabs.close": {"ok": True, "data": {}},
        "tabs.agent_state": {"ok": False, "error": "unknown tab"},
    }
    async with _relay(answers, sent) as client:
        directory = AppTabDirectory(client, "conv_a")
        listed = await directory.list_tabs()
        created = await directory.create_tab("about:blank")
        await directory.close_tab("TARGET1")
        with pytest.raises(TabDirectoryError, match="unknown tab"):
            await directory.report_agent_state("TARGET1", "active")

    assert listed[0].owner == "user" and listed[0].target_id == "TARGET1"
    assert created.owner == "agent"
    assert sent == [
        {"op": "tabs.list", "args": {}},
        {"op": "tabs.create", "args": {"url": "about:blank"}},
        {"op": "tabs.close", "args": {"target_id": "TARGET1"}},
        {"op": "tabs.agent_state", "args": {"target_id": "TARGET1", "state": "active"}},
    ]


async def test_a_session_without_either_browser_hears_both_reasons(tmp_path) -> None:
    manager = BrowserHostManager(BrowserHostSettings(enabled=False, data_dir=tmp_path))
    absent = {"error": "no browser renderer is connected"}
    async with _relay({"attach": absent}, []) as client:
        resolver = RunnerBrowserResolver(manager, lambda _session, _event: None, client)
        with pytest.raises(BrowserUnavailableError) as raised:
            await resolver.resolve("conv_a")

    message = str(raised.value)
    assert "This Mac's browser" in message and "no browser renderer" in message
    assert "agent machine's browser" in message


async def test_the_mac_browser_wins_when_it_shares_the_machine(tmp_path) -> None:
    manager = BrowserHostManager(BrowserHostSettings(enabled=False, data_dir=tmp_path))
    with _devtools_port("/devtools/browser/GUID-1") as port:
        attach = {"ok": True, "data": {"port": port, "browser_path": "/devtools/browser/GUID-1"}}
        async with _relay({"attach": attach}, []) as client:
            resolver = RunnerBrowserResolver(manager, lambda _session, _event: None, client)
            backend = await resolver.resolve("conv_a")

    assert backend.kind == "local"


@pytest.mark.parametrize(
    ("labels", "order"),
    [
        ({}, ("local", "remote")),
        ({BROWSER_TARGET_LABEL: "auto"}, ("local", "remote")),
        ({BROWSER_TARGET_LABEL: "local"}, ("local",)),
        ({BROWSER_TARGET_LABEL: "remote"}, ("remote",)),
        # Nobody watches a scheduled run: the remote browser comes first.
        ({SCHEDULED_TASK_RUN_LABEL_KEY: "run_1"}, ("remote", "local")),
        ({SCHEDULED_TASK_RUN_LABEL_KEY: "run_1", BROWSER_TARGET_LABEL: "local"}, ("local",)),
    ],
)
def test_the_session_label_and_unattended_runs_pick_the_order(
    labels: dict[str, str], order: tuple[str, ...]
) -> None:
    assert backend_order(labels) == order


async def test_choosing_the_remote_browser_never_asks_the_mac(tmp_path) -> None:
    manager = BrowserHostManager(BrowserHostSettings(enabled=False, data_dir=tmp_path))
    sent: list[dict[str, Any]] = []
    async with _relay({}, sent, labels={BROWSER_TARGET_LABEL: "remote"}) as client:
        resolver = RunnerBrowserResolver(manager, lambda _session, _event: None, client)
        with pytest.raises(BrowserUnavailableError) as raised:
            await resolver.resolve("conv_a")
        still_local = await resolver.still_selected("conv_a", "local")
        still_remote = await resolver.still_selected("conv_a", "remote")

    assert sent == []
    assert "This Mac's browser" not in str(raised.value)
    assert (still_local, still_remote) == (False, True)
