"""Runner remote browser routes against the fake host: REST, attach splice and cleanup."""

from __future__ import annotations

import asyncio
import json
from collections.abc import Iterator, Mapping
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from omnigent.runner.browser_host import (
    BrowserHostManager,
    BrowserHostSettings,
    host_request,
)
from omnigent.runner.browser_routes import register_browser_routes
from tests._helpers.fake_browser_host import install_fake_browser_host, stop_fake_browser_hosts

_FIXTURES = Path(__file__).resolve().parents[2] / "client-core" / "fixtures" / "remote_browser"
_BASE = "/v1/sessions/conv_a/resources"


def _client_message(name: str) -> str:
    return (_FIXTURES / "messages" / "client_to_host" / f"{name}.json").read_text("utf-8")


class _Runner:
    def __init__(self, client: TestClient, manager: BrowserHostManager) -> None:
        self.client = client
        self.manager = manager
        self.events: list[tuple[str, Mapping[str, object]]] = []

    def received(self, tab_id: str) -> list[dict[str, object]]:
        """Client messages the fake host recorded for *tab_id*."""

        async def fetch() -> list[dict[str, object]]:
            resolved = await self.manager.resolve_tab("conv_a", tab_id)
            assert resolved is not None
            result = await host_request(resolved[0].socket, "fake.received", {"tab_id": tab_id})
            messages = result["messages"]
            assert isinstance(messages, list)
            return messages

        return asyncio.run(fetch())


def _settings(tmp_path: Path, *, encoder: bool = True) -> BrowserHostSettings:
    binary, encoder_path = install_fake_browser_host(tmp_path / "bin")
    return BrowserHostSettings(
        enabled=True,
        data_dir=tmp_path / "data",
        binary=binary,
        encoder=encoder_path if encoder else tmp_path / "no-encoder" / "x264",
        extra_args=("--idle-exit-seconds", "60"),
        start_timeout_s=20,
    )


@pytest.fixture
def runner(tmp_path: Path) -> Iterator[_Runner]:
    manager = BrowserHostManager(_settings(tmp_path))
    app = FastAPI()
    events: list[tuple[str, Mapping[str, object]]] = []
    close_session_browsers = register_browser_routes(
        app, manager=manager, publish_event=lambda sid, event: events.append((sid, event))
    )

    @app.delete("/test/sessions/{session_id}/browsers")
    async def end_session(session_id: str) -> list[str]:
        return await close_session_browsers(session_id)

    try:
        with TestClient(app) as client:
            state = _Runner(client, manager)
            state.events = events
            yield state
    finally:
        stop_fake_browser_hosts(manager.settings.browser_dir)


def test_rest_lifecycle_matches_the_fixtures(runner: _Runner) -> None:
    create_fixture = json.loads((_FIXTURES / "rest" / "create.json").read_text("utf-8"))
    created = runner.client.post(f"{_BASE}/browsers", json=create_fixture["request"]["body"])
    assert created.status_code == 200, created.text
    tab = created.json()
    assert set(tab) == set(create_fixture["body"])
    assert tab["type"] == "browser"
    assert tab["metadata"]["url"] == "https://github.com/login"
    assert tab["metadata"]["profile"] == "default"
    assert tab["metadata"]["created_by"] == "user"

    second = runner.client.post(f"{_BASE}/browsers", json={"profile": "work"}).json()
    listed = runner.client.get(f"{_BASE}/browsers", params={"limit": 1000, "order": "asc"})
    assert listed.status_code == 200
    page = listed.json()
    assert [item["id"] for item in page["data"]] == [tab["id"], second["id"]]
    assert page["first_id"] == tab["id"] and page["has_more"] is False
    assert page["browser_host"] == {"status": "available", "encoder": "x264"}
    one = runner.client.get(f"{_BASE}/browsers", params={"limit": 1, "order": "asc"}).json()
    assert [item["id"] for item in one["data"]] == [tab["id"]] and one["has_more"] is True

    profiles = runner.client.get(f"{_BASE}/browser_profiles").json()
    assert profiles["object"] == "list" and profiles["has_more"] is False
    assert [(p["name"], p["running"]) for p in profiles["data"]] == [
        ("default", True),
        ("work", True),
    ]

    assert runner.client.get(f"{_BASE}/browsers/{tab['id']}").json() == {
        **tab,
        "metadata": {**tab["metadata"], "loading": True},
    }
    deleted = runner.client.delete(f"{_BASE}/browsers/{tab['id']}")
    assert deleted.json() == json.loads((_FIXTURES / "rest" / "delete.json").read_text("utf-8"))[
        "body"
    ] | {"id": tab["id"]}
    assert runner.client.delete(f"{_BASE}/browsers/{tab['id']}").status_code == 404
    assert runner.client.get(f"{_BASE}/browsers/{tab['id']}").status_code == 404
    assert runner.client.get(f"{_BASE}/browsers/bad.id").status_code == 404


@pytest.mark.parametrize(
    "body",
    [
        {"profile": "Bad Name"},
        {"url": "javascript:alert(1)"},
        {"url": "file:///etc/passwd"},
        {"width": -5},
        {"created_by": "someone"},
    ],
)
def test_create_rejects_invalid_input(runner: _Runner, body: dict[str, object]) -> None:
    response = runner.client.post(f"{_BASE}/browsers", json=body)
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_input"


def test_create_without_an_encoder_is_unavailable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("PATH", str(tmp_path / "empty"))
    app = FastAPI()
    manager = BrowserHostManager(_settings(tmp_path, encoder=False))
    register_browser_routes(app, manager=manager, publish_event=lambda _sid, _event: None)
    with TestClient(app) as client:
        response = client.post(f"{_BASE}/browsers", json={})
        listed = client.get(f"{_BASE}/browsers").json()
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "browser_unavailable"
    assert "x264" in response.json()["error"]["message"]
    assert listed["data"] == [] and listed["browser_host"]["status"] == "encoder_missing"


def test_control_attach_splices_frames_both_ways(runner: _Runner) -> None:
    tab = runner.client.post(f"{_BASE}/browsers", json={"url": "https://example.com/"}).json()
    with runner.client.websocket_connect(
        f"{_BASE}/browsers/{tab['id']}/attach?mode=control&v=1"
    ) as websocket:
        websocket.send_text(_client_message("hello"))
        hello = websocket.receive_json()
        assert hello["type"] == "hello"
        assert hello["tab_id"] == tab["id"] and hello["mode"] == "control"
        setup = [websocket.receive_json()["type"] for _ in range(5)]
        assert setup == ["control", "viewport", "nav", "cursor", "text_input"]
        idr = websocket.receive_bytes()
        assert idr == (_FIXTURES / "binary_frames" / "h264_idr.bin").read_bytes()
        assert websocket.receive_bytes()[:2] == b"RB"
        for name in ("ack", "mouse_down", "key_down", "control_take"):
            websocket.send_text(_client_message(name))
        websocket.send_text(json.dumps({"type": "ping", "nonce": "n-1"}))
        assert websocket.receive_json() == {"type": "pong", "nonce": "n-1"}
    types = [message["type"] for message in runner.received(tab["id"])]
    assert types == ["hello", "ack", "mouse", "key", "control", "ping"]


def test_view_attach_drops_input_before_the_host(runner: _Runner) -> None:
    tab = runner.client.post(f"{_BASE}/browsers", json={}).json()
    with runner.client.websocket_connect(f"{_BASE}/browsers/{tab['id']}/attach") as websocket:
        websocket.send_text(_client_message("hello"))
        assert websocket.receive_json()["mode"] == "view"
        for name in ("mouse_down", "key_down", "nav_navigate", "control_take", "settings"):
            websocket.send_text(_client_message(name))
        websocket.send_bytes(b"RB-not-from-a-client")
        websocket.send_text(_client_message("ack"))
        websocket.send_text(json.dumps({"type": "ping", "nonce": "n-2"}))
        while (message := websocket.receive()).get("text") is None or json.loads(
            message["text"]
        ).get("type") != "pong":
            continue
    types = [message["type"] for message in runner.received(tab["id"])]
    assert types == ["hello", "ack", "ping"]


def test_tab_close_reaches_the_attached_client_as_4404(runner: _Runner) -> None:
    tab = runner.client.post(f"{_BASE}/browsers", json={}).json()
    with runner.client.websocket_connect(f"{_BASE}/browsers/{tab['id']}/attach") as websocket:
        websocket.send_text(_client_message("hello"))
        assert websocket.receive_json()["type"] == "hello"
        assert runner.client.delete(f"{_BASE}/browsers/{tab['id']}").status_code == 200
        messages: list[dict[str, object]] = []
        while True:
            message = websocket.receive()
            if message["type"] == "websocket.close":
                assert message["code"] == 4404
                break
            if message.get("text") is not None:
                messages.append(json.loads(message["text"]))
        assert messages[-1] == {"type": "tab_closed", "reason": "closed"}


@pytest.mark.parametrize(
    ("path", "code"),
    [
        ("btab_missing/attach", 4404),
        ("bad.id/attach", 4404),
        ("{tab}/attach?v=0", 4426),
        ("{tab}/attach?mode=admin", 1002),
    ],
)
def test_attach_refusals(runner: _Runner, path: str, code: int) -> None:
    tab = runner.client.post(f"{_BASE}/browsers", json={}).json()
    with runner.client.websocket_connect(f"{_BASE}/browsers/{path.format(tab=tab['id'])}") as ws:
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_text()
    assert closed.value.code == code


def test_other_sessions_cannot_reach_a_tab(runner: _Runner) -> None:
    tab = runner.client.post(f"{_BASE}/browsers", json={}).json()
    other = f"/v1/sessions/conv_b/resources/browsers/{tab['id']}"
    assert runner.client.get(other).status_code == 404
    assert runner.client.delete(other).status_code == 404
    with runner.client.websocket_connect(f"{other}/attach") as websocket:
        with pytest.raises(WebSocketDisconnect) as closed:
            websocket.receive_text()
    assert closed.value.code == 4404


def test_session_end_closes_only_that_sessions_tabs(runner: _Runner) -> None:
    first = runner.client.post(f"{_BASE}/browsers", json={}).json()
    second = runner.client.post(f"{_BASE}/browsers", json={"profile": "work"}).json()
    kept = runner.client.post("/v1/sessions/conv_b/resources/browsers", json={}).json()
    closed = runner.client.delete("/test/sessions/conv_a/browsers").json()
    assert sorted(closed) == sorted([first["id"], second["id"]])
    assert runner.client.get(f"{_BASE}/browsers").json()["data"] == []
    remaining = runner.client.get("/v1/sessions/conv_b/resources/browsers").json()["data"]
    assert [item["id"] for item in remaining] == [kept["id"]]
    assert sorted(event["resource_id"] for _sid, event in runner.events) == sorted(closed)
    assert {(sid, event["type"], event["resource_type"]) for sid, event in runner.events} == {
        ("conv_a", "session.resource.deleted", "browser")
    }


@pytest.mark.parametrize(
    ("method_path", "object_name"),
    [
        ("/v1/sessions/conv_a", "session.deleted"),
        ("/v1/sessions/conv_a/resources", "session.resources.cleaned"),
    ],
)
async def test_session_teardown_reports_a_failed_browser_host_after_finishing(
    tmp_path: Path, method_path: str, object_name: str
) -> None:
    """One broken profile host still lets the others close and the teardown finish, then 500s."""
    import httpx

    from omnigent.runner import create_runner_app
    from tests.runner.helpers import NullServerClient

    manager = BrowserHostManager(_settings(tmp_path))
    app = create_runner_app(
        server_client=NullServerClient(),  # type: ignore[arg-type]
        browser_host_manager=manager,
    )
    broken_dir = manager.profile_dir("broken")
    broken_dir.mkdir(parents=True)
    try:
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://runner") as client:
            tab = (await client.post(f"{_BASE}/browsers", json={})).json()
            (broken_dir / "host.json").write_text("{not json")
            response = await client.delete(method_path)
        assert response.status_code == 500
        body = response.json()
        assert body["object"] == object_name
        assert body["error"]["code"] == "resource_cleanup_failed"
        assert body["error"]["resource_type"] == "browser"
        assert list(body["error"]["failures"]) == ["broken"]
        assert body["error"]["closed"] == [tab["id"]]
        state = manager.read_state("default")
        assert state is not None
        assert (await host_request(state.socket, "tabs.list", {"session_id": "conv_a"})) == {
            "tabs": []
        }
    finally:
        (broken_dir / "host.json").unlink(missing_ok=True)
        await asyncio.to_thread(stop_fake_browser_hosts, manager.settings.browser_dir)
