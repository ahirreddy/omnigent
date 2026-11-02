"""Server relay for remote browser attach: auth per mode, view filtering, close codes.

Reuses the terminal-attach stubs: both routes share the runner relay
(``relay_websocket_to_runner``) and differ in auth and frame filtering.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from omnigent.errors import ErrorCode, OmnigentError
from omnigent.runtime import set_runner_ws_factory
from omnigent.server._runner_ws_tunnel import _RUNNER_PATH_RE, WrongReplicaWSError
from omnigent.server.auth import LEVEL_EDIT, LEVEL_OWNER, LEVEL_READ, UnifiedAuthProvider
from omnigent.server.routes.browser_attach import create_browser_attach_router
from tests.server.routes.test_terminal_attach import (
    _FakeRunnerWSConn,
    _FakeRunnerWSFactory,
    _StubConversationStore,
    _StubPermissionStore,
    runner_client_reset,  # noqa: F401 -- fixture
)

pytestmark = pytest.mark.usefixtures("runner_client_reset")

_FIXTURES = Path(__file__).resolve().parents[3] / "client-core" / "fixtures" / "remote_browser"
_ATTACH = "/v1/sessions/conv_alice/resources/browsers/btab_7f3a9c2e/attach"
_RUNNER_PATH = "/v1/sessions/conv_alice/resources/browsers/btab_7f3a9c2e/attach"


def _client_message(name: str) -> str:
    return (_FIXTURES / "messages" / "client_to_host" / f"{name}.json").read_text("utf-8")


def _app(level_by_user: dict[str, int]) -> FastAPI:
    conversations = _StubConversationStore()
    conversations.add("conv_alice")
    permissions = _StubPermissionStore()
    for user, level in level_by_user.items():
        permissions.add_grant(user, "conv_alice", level)
    app = FastAPI()
    app.include_router(
        create_browser_attach_router(
            auth_provider=UnifiedAuthProvider(source="header"),
            permission_store=permissions,  # type: ignore[arg-type]
            conversation_store=conversations,  # type: ignore[arg-type]
        ),
        prefix="/v1",
    )
    return app


def _as(user: str) -> dict[str, str]:
    return {"X-Forwarded-Email": user}


def test_view_attach_relays_media_and_drops_input() -> None:
    """A read-level viewer gets host frames; only non-input messages reach the runner."""
    hello = (_FIXTURES / "messages" / "host_to_client" / "hello.json").read_text("utf-8")
    idr = (_FIXTURES / "binary_frames" / "h264_idr.bin").read_bytes()
    conn = _FakeRunnerWSConn(outgoing=[hello, idr], wait_close_after=2)
    factory = _FakeRunnerWSFactory(conn)
    set_runner_ws_factory(factory)
    app = _app({"alice@example.com": LEVEL_OWNER, "viewer@example.com": LEVEL_READ})
    with TestClient(app).websocket_connect(_ATTACH, headers=_as("viewer@example.com")) as ws:
        assert json.loads(ws.receive_text())["type"] == "hello"
        assert ws.receive_bytes() == idr
        for name in ("hello", "mouse_down", "key_down", "control_take", "settings", "ack"):
            ws.send_text(_client_message(name))
        ws.send_bytes(b"\x00binary input")
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_text()
    assert closed.value.code == 1000
    assert factory.calls == [f"{_RUNNER_PATH}?mode=view&v=1"]
    assert [json.loads(frame)["type"] for frame in conn.received] == ["hello", "ack"]


def test_owner_control_attach_forwards_input() -> None:
    conn = _FakeRunnerWSConn(wait_close_after=2)
    factory = _FakeRunnerWSFactory(conn)
    set_runner_ws_factory(factory)
    app = _app({"alice@example.com": LEVEL_OWNER})
    with TestClient(app).websocket_connect(
        f"{_ATTACH}?mode=control&v=1", headers=_as("alice@example.com")
    ) as ws:
        ws.send_text(_client_message("control_take"))
        ws.send_text(_client_message("mouse_down"))
        with pytest.raises(WebSocketDisconnect):
            ws.receive_text()
    assert factory.calls == [f"{_RUNNER_PATH}?mode=control&v=1"]
    assert [json.loads(frame)["type"] for frame in conn.received] == ["control", "mouse"]


@pytest.mark.parametrize("level", [LEVEL_READ, LEVEL_EDIT])
def test_non_owner_control_attach_is_refused_with_4403(level: int) -> None:
    factory = _FakeRunnerWSFactory(_FakeRunnerWSConn())
    set_runner_ws_factory(factory)
    app = _app({"alice@example.com": LEVEL_OWNER, "bob@example.com": level})
    with TestClient(app).websocket_connect(
        f"{_ATTACH}?mode=control", headers=_as("bob@example.com")
    ) as ws:
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_text()
    assert closed.value.code == 4403
    assert factory.calls == []


@pytest.mark.parametrize("headers", [{}, {"X-Forwarded-Email": "mallory@example.com"}])
def test_attach_without_read_access_is_rejected_before_upgrade(headers: dict[str, str]) -> None:
    factory = _FakeRunnerWSFactory(_FakeRunnerWSConn())
    set_runner_ws_factory(factory)
    app = _app({"alice@example.com": LEVEL_OWNER})
    with pytest.raises(WebSocketDisconnect) as closed:
        with TestClient(app).websocket_connect(_ATTACH, headers=headers):
            pass
    assert closed.value.code == 1008
    assert factory.calls == []


@pytest.mark.parametrize(
    ("url", "code"),
    [
        (f"{_ATTACH}?v=0", 4426),
        (f"{_ATTACH}?mode=admin", 1002),
        ("/v1/sessions/conv_alice/resources/browsers/bad.id/attach", 4404),
    ],
)
def test_attach_refusals_before_the_runner(url: str, code: int) -> None:
    factory = _FakeRunnerWSFactory(_FakeRunnerWSConn())
    set_runner_ws_factory(factory)
    app = _app({"alice@example.com": LEVEL_OWNER})
    with TestClient(app).websocket_connect(url, headers=_as("alice@example.com")) as ws:
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_text()
    assert closed.value.code == code
    assert factory.calls == []


@pytest.mark.parametrize("runner_code", [4404, 4426, 1009, 1011, 1013])
def test_runner_close_codes_pass_through(runner_code: int) -> None:
    set_runner_ws_factory(_FakeRunnerWSFactory(_FakeRunnerWSConn(close_code=runner_code)))
    app = _app({"alice@example.com": LEVEL_OWNER})
    with TestClient(app).websocket_connect(_ATTACH, headers=_as("alice@example.com")) as ws:
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_text()
    assert closed.value.code == runner_code


def test_wrong_replica_closes_with_4400() -> None:
    def factory(path: str) -> object:
        raise WrongReplicaWSError(f"tunnel for {path} is on another replica")

    set_runner_ws_factory(factory)
    app = _app({"alice@example.com": LEVEL_OWNER})
    with TestClient(app).websocket_connect(_ATTACH, headers=_as("alice@example.com")) as ws:
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_text()
    assert closed.value.code == 4400


@pytest.mark.parametrize(
    ("path", "routable"),
    [
        (f"{_RUNNER_PATH}?mode=view&v=1", True),
        ("/v1/sessions/conv_a/resources/terminals/terminal_bash_s1/attach?read_only=true", True),
        ("/v1/sessions/conv_a/resources/browsers/btab_1/cdp", False),
        ("/v1/sessions/conv_a/resources/browsers/btab_1/attach/devtools", False),
        ("/json/version", False),
        ("/devtools/browser/abc", False),
        ("/v1/sessions/conv_a/resources/browsers/btab_1", False),
    ],
)
def test_runner_relay_only_routes_attach_paths(path: str, routable: bool) -> None:
    assert (_RUNNER_PATH_RE.match(path) is not None) is routable


@pytest.mark.parametrize(
    ("owner_check_error", "code", "reason_part"),
    [
        (OmnigentError("Requires owner access", code=ErrorCode.FORBIDDEN), 4403, "owner"),
        (OmnigentError("Session gone", code=ErrorCode.NOT_FOUND), 4404, "Session gone"),
        (OmnigentError("store offline", code=ErrorCode.INTERNAL_ERROR), 4500, "store offline"),
        (RuntimeError("database is locked"), 4500, "database is locked"),
    ],
    ids=["not-owner", "session-missing", "internal", "unexpected"],
)
def test_control_check_failures_surface_their_own_close_code(
    monkeypatch: pytest.MonkeyPatch,
    owner_check_error: Exception,
    code: int,
    reason_part: str,
) -> None:
    """Only "not the owner" is 4403; a failed owner check closes with what went wrong."""
    from omnigent.server.routes import browser_attach

    async def require_access(user_id, session_id, level, permissions, conversations) -> None:
        del user_id, session_id, permissions, conversations
        if level == LEVEL_OWNER:
            raise owner_check_error

    monkeypatch.setattr(browser_attach, "require_access", require_access)
    factory = _FakeRunnerWSFactory(_FakeRunnerWSConn())
    set_runner_ws_factory(factory)
    app = _app({"alice@example.com": LEVEL_OWNER})
    with TestClient(app).websocket_connect(
        f"{_ATTACH}?mode=control", headers=_as("alice@example.com")
    ) as ws:
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_text()
    assert closed.value.code == code
    assert reason_part in closed.value.reason
    assert factory.calls == []
