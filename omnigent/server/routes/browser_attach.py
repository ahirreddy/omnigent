"""WebSocket endpoint relaying a remote agent browser tab to a client.

``WS /sessions/{session_id}/resources/browsers/{tab_id}/attach?mode=view|control&v=1``
splices the client to the runner's matching route over the runner tunnel,
which splices it to the tab's browser host. The server never parses media;
it only enforces access:

- ``mode=view`` needs read access. Input messages are dropped here, at the
  runner and at the host.
- ``mode=control`` needs owner access, as for terminal write attach: input
  carries no per-user attribution and acts in the owner's logged-in browser.
  A caller with read but not owner access is refused with close 4403.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from urllib.parse import urlencode

from fastapi import APIRouter, Query, WebSocket, WebSocketException
from starlette import status

from omnigent.debug_logging import debug_event, set_current_user_id
from omnigent.entities.remote_browser import (
    BROWSER_ATTACH_MODES,
    REMOTE_BROWSER_PROTOCOL_VERSION,
    WS_CLOSE_CONTROL_NOT_PERMITTED,
    WS_CLOSE_PROTOCOL_UNSUPPORTED,
    WS_CLOSE_TAB_NOT_FOUND,
    is_valid_browser_tab_id,
    view_mode_allows_client_frame,
)
from omnigent.errors import ErrorCode, OmnigentError
from omnigent.runtime import get_runner_ws_factory
from omnigent.server.auth import LEVEL_OWNER, LEVEL_READ, AuthProvider
from omnigent.server.routes._auth_helpers import require_access
from omnigent.server.routes.terminal_attach import relay_websocket_to_runner
from omnigent.stores import ConversationStore
from omnigent.stores.permission_store import PermissionStore
from omnigent.terminals.ws_common import WS_CLOSE_INTERNAL_ERROR

_logger = logging.getLogger(__name__)

_WS_CLOSE_PROTOCOL_ERROR = 1002


def create_browser_attach_router(
    *,
    auth_provider: AuthProvider | None = None,
    permission_store: PermissionStore | None = None,
    conversation_store: ConversationStore | None = None,
) -> APIRouter:
    """
    Build the router exposing the remote browser attach WebSocket route.

    Mounted under ``/v1``. The tab list/create/delete routes live with the
    other session resources in ``routes/sessions/routes_resources.py``.

    :param auth_provider: Resolves the caller from the handshake.
    :param permission_store: Session permission store; ``None`` disables
        checks (single-user/dev mode, where the caller is the owner).
    :param conversation_store: Conversation store used by permission checks.
    :returns: An :class:`APIRouter` carrying the attach route.
    """
    router = APIRouter()

    @router.websocket("/sessions/{session_id}/resources/browsers/{tab_id}/attach")
    async def attach_browser_tab(
        websocket: WebSocket,
        session_id: str,
        tab_id: str,
        mode: str = Query(default="view"),
        v: int = Query(default=REMOTE_BROWSER_PROTOCOL_VERSION),
    ) -> None:
        """
        Attach to a remote browser tab.

        :param websocket: The client WebSocket.
        :param session_id: Session/conversation id, e.g. ``"conv_abc123"``.
        :param tab_id: Opaque tab id, e.g. ``"btab_7f3a9c2e"``.
        :param mode: ``view`` (default) or ``control``.
        :param v: Highest protocol major the client speaks.
        """
        user_id, control_refusal = await _authorize_browser_attach(
            websocket,
            session_id=session_id,
            wants_control=mode == "control",
            auth_provider=auth_provider,
            permission_store=permission_store,
            conversation_store=conversation_store,
        )
        set_current_user_id(user_id)
        await websocket.accept()
        if mode not in BROWSER_ATTACH_MODES:
            await websocket.close(code=_WS_CLOSE_PROTOCOL_ERROR, reason="invalid attach mode")
            return
        if v < REMOTE_BROWSER_PROTOCOL_VERSION:
            await websocket.close(
                code=WS_CLOSE_PROTOCOL_UNSUPPORTED, reason=f"protocol v={v} unsupported"
            )
            return
        if control_refusal is not None:
            await websocket.close(code=control_refusal.code, reason=control_refusal.reason)
            return
        if not is_valid_browser_tab_id(tab_id):
            await websocket.close(code=WS_CLOSE_TAB_NOT_FOUND, reason="browser tab not found")
            return
        _logger.info(
            "browser attach connected for session %s tab %s",
            session_id,
            tab_id,
            extra=debug_event(
                "attach_browser_tab",
                session_id=session_id,
                phase="connected",
                tab_id=tab_id,
                mode=mode,
            ),
        )
        ws_factory = get_runner_ws_factory()
        if ws_factory is None:
            await websocket.close(
                code=WS_CLOSE_INTERNAL_ERROR, reason="remote browser needs a runner tunnel"
            )
            return
        query = urlencode({"mode": mode, "v": v})
        await relay_websocket_to_runner(
            websocket,
            ws_factory,
            f"/v1/sessions/{session_id}/resources/browsers/{tab_id}/attach?{query}",
            span_name="browser.attach",
            span_attributes={
                "session.id": session_id,
                "browser.tab_id": tab_id,
                "browser.mode": mode,
            },
            client_frame_filter=view_mode_allows_client_frame if mode == "view" else None,
        )

    return router


@dataclass(frozen=True)
class _AttachRefusal:
    """A close sent right after the upgrade instead of relaying."""

    code: int
    reason: str


# Close codes for owner-check failures other than "not the owner".
_OWNER_CHECK_CLOSE_CODES: dict[str, int] = {
    ErrorCode.NOT_FOUND: WS_CLOSE_TAB_NOT_FOUND,
    ErrorCode.UNAUTHORIZED: status.WS_1008_POLICY_VIOLATION,
}


def _close_reason(text: str) -> str:
    """Trim *text* to the 123-byte limit of a WebSocket close reason."""
    return text.encode("utf-8")[:123].decode("utf-8", errors="ignore")


async def _authorize_browser_attach(
    websocket: WebSocket,
    *,
    session_id: str,
    wants_control: bool,
    auth_provider: AuthProvider | None,
    permission_store: PermissionStore | None,
    conversation_store: ConversationStore | None,
) -> tuple[str | None, _AttachRefusal | None]:
    """
    Require read access before the upgrade and check owner access for control.

    :param websocket: The incoming WebSocket.
    :param session_id: Session the attach targets.
    :param wants_control: Whether the caller asked for ``mode=control``;
        the owner check runs only then.
    :param auth_provider: Resolves the caller's user id.
    :param permission_store: ``None`` disables checks (the caller may control).
    :param conversation_store: Conversation store for the access check.
    :returns: ``(user_id, refusal)``. ``refusal`` is ``None`` when the attach
        may proceed; otherwise 4403 for a caller who is not the owner, or the
        failure's own code (4404, 1008, else 4500) when the owner check itself
        failed.
    :raises WebSocketException: ``1008`` when auth is misconfigured, the
        caller is unauthenticated, or lacks read access.
    """
    if permission_store is None:
        user_id = auth_provider.get_user_id(websocket) if auth_provider is not None else None
        return user_id, None
    if auth_provider is None or conversation_store is None:
        raise WebSocketException(
            code=status.WS_1008_POLICY_VIOLATION,
            reason="browser attach authorization is not configured",
        )
    user_id = auth_provider.get_user_id(websocket)
    if user_id is None:
        raise WebSocketException(
            code=status.WS_1008_POLICY_VIOLATION, reason="authentication required"
        )
    try:
        await require_access(user_id, session_id, LEVEL_READ, permission_store, conversation_store)
    except OmnigentError as exc:
        _logger.info(
            "Rejected browser attach for session %s as user %s: %s",
            session_id,
            user_id,
            exc,
            extra=debug_event("attach_browser_tab", session_id=session_id, phase="rejected"),
        )
        raise WebSocketException(
            code=status.WS_1008_POLICY_VIOLATION, reason="not authorized"
        ) from exc
    if not wants_control:
        return user_id, None
    try:
        await require_access(
            user_id, session_id, LEVEL_OWNER, permission_store, conversation_store
        )
    except OmnigentError as exc:
        if exc.code == ErrorCode.FORBIDDEN:
            return user_id, _AttachRefusal(
                WS_CLOSE_CONTROL_NOT_PERMITTED, "only the session owner can control this browser"
            )
        _logger.error(
            "browser control check failed for session %s as user %s: %s",
            session_id,
            user_id,
            exc,
            extra=debug_event("attach_browser_tab", session_id=session_id, phase="check_failed"),
        )
        code = _OWNER_CHECK_CLOSE_CODES.get(exc.code, WS_CLOSE_INTERNAL_ERROR)
        return user_id, _AttachRefusal(code, _close_reason(f"control check failed: {exc}"))
    except Exception as exc:
        # Anything else (a store failure, say) is logged and closed as 4500.
        _logger.exception(
            "browser control check crashed for session %s as user %s",
            session_id,
            user_id,
            extra=debug_event("attach_browser_tab", session_id=session_id, phase="check_failed"),
        )
        return user_id, _AttachRefusal(
            WS_CLOSE_INTERNAL_ERROR, _close_reason(f"control check failed: {exc!r}")
        )
    return user_id, None
