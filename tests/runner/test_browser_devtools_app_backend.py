"""The Mac app's browser as an agent backend, and how a session picks its browser.

The server relay is an ``httpx.MockTransport`` answering as the owner's app
would; the app's DevTools gate is a loopback WebSocket server that accepts only
its secret path, so the same-machine check runs against a real socket.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import socket
from collections.abc import AsyncIterator, Iterator
from typing import Any, cast

import httpx
import pytest
from websockets.asyncio.server import ServerConnection, serve
from websockets.http11 import Request, Response

from omnigent.runner import pending_approvals
from omnigent.runner.browser_devtools import resolver as resolver_module
from omnigent.runner.browser_devtools.app_backend import AppTabDirectory, app_backend
from omnigent.runner.browser_devtools.directory import TabDirectoryError
from omnigent.runner.browser_devtools.resolver import (
    ASK_MESSAGE,
    ASK_SCHEMA,
    BROWSER_TARGET_LABEL,
    RunnerBrowserResolver,
    backend_order,
)
from omnigent.runner.browser_devtools.server import BrowserBackend, BrowserUnavailableError
from omnigent.runner.browser_host import (
    BrowserHostAvailability,
    BrowserHostManager,
    BrowserHostSettings,
)
from omnigent.stores.conversation_store import SCHEDULED_TASK_RUN_LABEL_KEY

SECRET = "a1" * 32
OTHER_SECRET = "b2" * 32


@contextlib.asynccontextmanager
async def _gate(secret: str) -> AsyncIterator[int]:
    """A loopback WebSocket gate that opens only ``/devtools/browser/<secret>``."""

    def authorize(connection: ServerConnection, request: Request) -> Response | None:
        if request.path != f"/devtools/browser/{secret}":
            return connection.respond(403, "Forbidden\n")
        return None

    async def hold(connection: ServerConnection) -> None:
        await connection.wait_closed()

    async with serve(hold, "127.0.0.1", 0, process_request=authorize) as server:
        yield next(iter(server.sockets)).getsockname()[1]


def _free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def _attach(port: int, secret: str) -> dict[str, Any]:
    return {"ok": True, "data": {"port": port, "path": f"/devtools/browser/{secret}"}}


def _relay(
    answers: dict[str, dict[str, Any]],
    sent: list[dict[str, Any]],
    labels: dict[str, str] | None = None,
    writes: list[dict[str, Any]] | None = None,
) -> httpx.AsyncClient:
    """The server: *answers* by devtools op, *labels*, and with *writes* the session's
    label PATCHes and elicitation POSTs (``elicit_<n>``), which are refused otherwise."""

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/sessions/conv_a/labels":
            return httpx.Response(200, json={"labels": labels or {}})
        if writes is not None and request.url.path in (
            "/v1/sessions/conv_a",
            "/v1/sessions/conv_a/events",
        ):
            writes.append({"method": request.method, **json.loads(request.content)})
            return httpx.Response(200, json={"elicitation_id": f"elicit_{len(writes)}"})
        assert request.url.path == "/v1/sessions/conv_a/browser/devtools_request"
        body = json.loads(request.content)
        sent.append(body)
        return httpx.Response(200, json=answers[body["op"]])

    return httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="http://server.test")


async def test_the_app_browser_is_used_only_when_its_gate_answers_here() -> None:
    sent: list[dict[str, Any]] = []
    async with _gate(SECRET) as port:
        async with _relay({"attach": _attach(port, SECRET)}, sent) as client:
            backend = await app_backend(client, "conv_a")
        assert backend.upstream is not None
        await backend.upstream.close()
        # Another listener on this port (the app runs on another machine) refuses the secret.
        async with _relay({"attach": _attach(port, OTHER_SECRET)}, sent) as client:
            with pytest.raises(BrowserUnavailableError, match="HTTP 403") as refused:
                await app_backend(client, "conv_a")
    async with _relay({"attach": _attach(_free_port(), SECRET)}, sent) as client:
        with pytest.raises(BrowserUnavailableError, match="nothing here answered") as absent:
            await app_backend(client, "conv_a")

    assert backend.kind == "local"
    assert backend.upstream_url == f"ws://127.0.0.1:{port}/devtools/browser/{SECRET}"
    assert sent[0] == {"op": "attach", "args": {}}
    # The secret never reaches an error message or a repr.
    assert SECRET not in repr(backend)
    assert OTHER_SECRET not in str(refused.value) and SECRET not in str(absent.value)


@pytest.mark.parametrize(
    "data",
    [
        {"port": 9222, "path": "/devtools/browser/not-a-secret"},
        {"port": 9222},
        {"port": True, "path": f"/devtools/browser/{SECRET}"},
        {"port": 70000, "path": f"/devtools/browser/{SECRET}"},
    ],
)
async def test_an_attach_without_a_gate_address_is_refused(data: dict[str, Any]) -> None:
    async with _relay({"attach": {"ok": True, "data": data}}, []) as client:
        with pytest.raises(BrowserUnavailableError, match="did not report"):
            await app_backend(client, "conv_a")


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
    async with _gate(SECRET) as port:
        async with _relay({"attach": _attach(port, SECRET)}, []) as client:
            resolver = RunnerBrowserResolver(manager, lambda _session, _event: None, client)
            backend = await resolver.resolve("conv_a")
        assert backend.upstream is not None
        await backend.upstream.close()

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


class _HostsRunHere:
    """A browser host manager whose hosts can run on this machine."""

    async def availability(self) -> BrowserHostAvailability:
        return BrowserHostAvailability(status="available", message="")


@pytest.fixture
def remote_backend(monkeypatch: pytest.MonkeyPatch) -> Iterator[list[str]]:
    """Stands in for a started browser host; records the sessions it served."""
    served: list[str] = []

    async def fake_host_backend(
        _manager: object, session_id: str, *_args: object, **_kwargs: object
    ) -> BrowserBackend:
        served.append(session_id)
        return BrowserBackend(
            upstream_url="ws://127.0.0.1:1/remote", directory=cast(Any, None), kind="remote"
        )

    monkeypatch.setattr(resolver_module, "host_backend", fake_host_backend)
    pending_approvals.reset_for_tests()
    yield served
    pending_approvals.reset_for_tests()


async def _answer(elicitation_id: str, approved: bool, content: dict[str, Any] | None) -> None:
    for _ in range(500):
        if pending_approvals.resolve(elicitation_id, approved, content):
            return
        await asyncio.sleep(0.01)
    raise AssertionError(f"{elicitation_id} was never asked")


@pytest.mark.parametrize("choice", ["local", "remote"])
async def test_with_both_browsers_the_owner_is_asked_once_and_the_answer_kept(
    remote_backend: list[str], choice: str
) -> None:
    writes: list[dict[str, Any]] = []
    async with _gate(SECRET) as port:
        async with _relay({"attach": _attach(port, SECRET)}, [], writes=writes) as client:
            resolver = RunnerBrowserResolver(
                cast(BrowserHostManager, _HostsRunHere()), lambda _s, _e: None, client
            )
            backend, _ = await asyncio.gather(
                resolver.resolve("conv_a"), _answer("elicit_1", True, {"browser": choice})
            )
            again = await resolver.resolve("conv_a")
        for each in (backend, again):
            if each.upstream is not None:
                await each.upstream.close()

    question, saved = writes
    assert question["type"] == "mcp_elicitation"
    assert question["data"] == {"message": ASK_MESSAGE, "requestedSchema": ASK_SCHEMA}
    assert saved == {"method": "PATCH", "labels": {BROWSER_TARGET_LABEL: choice}}
    assert backend.kind == choice
    assert remote_backend == (["conv_a"] if choice == "remote" else [])
    # The server here keeps no labels, so only the runner's memory stops a second question.
    assert len(writes) == 2 and again.kind == "local"


async def test_a_declined_question_keeps_the_mac_browser_and_is_not_asked_again(
    remote_backend: list[str],
) -> None:
    writes: list[dict[str, Any]] = []
    async with _gate(SECRET) as port:
        async with _relay({"attach": _attach(port, SECRET)}, [], writes=writes) as client:
            resolver = RunnerBrowserResolver(
                cast(BrowserHostManager, _HostsRunHere()), lambda _s, _e: None, client
            )
            backend, _ = await asyncio.gather(
                resolver.resolve("conv_a"), _answer("elicit_1", False, None)
            )
            again = await resolver.resolve("conv_a")
        for each in (backend, again):
            assert each.upstream is not None
            await each.upstream.close()

    assert [write["method"] for write in writes] == ["POST"]
    assert (backend.kind, again.kind) == ("local", "local")
    assert remote_backend == []


async def test_a_scheduled_run_takes_the_remote_browser_without_asking(
    remote_backend: list[str],
) -> None:
    sent: list[dict[str, Any]] = []
    labels = {SCHEDULED_TASK_RUN_LABEL_KEY: "run_1"}
    async with _relay({}, sent, labels=labels) as client:
        resolver = RunnerBrowserResolver(
            cast(BrowserHostManager, _HostsRunHere()), lambda _s, _e: None, client
        )
        backend = await resolver.resolve("conv_a")

    assert backend.kind == "remote" and remote_backend == ["conv_a"]
    assert sent == []
