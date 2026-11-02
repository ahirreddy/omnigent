"""Runner routes for remote browser tabs: list, create, delete and WS attach.

The attach route is a byte splice between the tunneled client WebSocket and
the tab's host connection; the client protocol is terminated by the host and
the Rust client core. View attaches drop input here as well as at the server
and the host.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import urllib.parse
from collections.abc import Awaitable, Callable, Mapping
from typing import Literal, cast

from fastapi import FastAPI, Query, Request, WebSocket
from fastapi.responses import JSONResponse
from starlette.websockets import WebSocketDisconnect, WebSocketState

from omnigent.entities.remote_browser import (
    BROWSER_ATTACH_MODES,
    DEFAULT_BROWSER_PROFILE,
    REMOTE_BROWSER_PROTOCOL_VERSION,
    WS_CLOSE_PROTOCOL_UNSUPPORTED,
    WS_CLOSE_TAB_NOT_FOUND,
    BrowserAttachMode,
    browser_tab_resource,
    is_valid_browser_tab_id,
    validate_browser_profile_name,
    view_mode_allows_client_frame,
)
from omnigent.runner.browser_host import (
    BrowserCleanupError,
    BrowserHostError,
    BrowserHostManager,
    HostFrameKind,
    HostFrameTooLargeError,
    HostProtocolError,
    decode_close_payload,
    encode_close_payload,
    encode_host_frame,
    read_host_frame,
)

_logger = logging.getLogger(__name__)

_WS_CLOSE_PROTOCOL_ERROR = 1002
_WS_CLOSE_MESSAGE_TOO_BIG = 1009
_WS_CLOSE_INTERNAL = 1011
_ALLOWED_URL_SCHEMES = frozenset({"http", "https"})

_HTTP_STATUS_FOR_HOST_ERROR: dict[str, int] = {
    "not_found": 404,
    "invalid_input": 400,
    "unavailable": 503,
    "internal": 502,
}


def _error_response(status_code: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(
        status_code=status_code, content={"error": {"code": code, "message": message}}
    )


def _host_error_response(exc: BrowserHostError) -> JSONResponse:
    code = "browser_unavailable" if exc.code == "unavailable" else exc.code
    return _error_response(_HTTP_STATUS_FOR_HOST_ERROR[exc.code], code, exc.message)


def _is_allowed_tab_url(url: str) -> bool:
    if url == "about:blank":
        return True
    parsed = urllib.parse.urlsplit(url)
    return parsed.scheme in _ALLOWED_URL_SCHEMES and bool(parsed.netloc)


def _paginate(
    resources: list[dict[str, object]], *, limit: int, after: str | None, order: str
) -> tuple[list[dict[str, object]], bool]:
    """Apply ``order``/``after``/``limit`` to resources in host (creation) order."""
    ordered = resources if order == "asc" else list(reversed(resources))
    if after is not None:
        ids = [resource["id"] for resource in ordered]
        ordered = ordered[ids.index(after) + 1 :] if after in ids else []
    return ordered[:limit], len(ordered) > limit


def _optional_viewport(body: Mapping[str, object]) -> dict[str, object] | None:
    """Pick ``width``/``height``/``dpr`` from a create body.

    :raises ValueError: When a present field is not a positive number.
    """
    viewport: dict[str, object] = {}
    for key in ("width", "height", "dpr"):
        if key not in body or body[key] is None:
            continue
        value = body[key]
        if isinstance(value, bool) or not isinstance(value, int | float) or value <= 0:
            raise ValueError(f"'{key}' must be a positive number")
        viewport[key] = value
    return viewport or None


def register_browser_routes(
    app: FastAPI,
    *,
    manager: BrowserHostManager,
    publish_event: Callable[[str, Mapping[str, object]], None],
) -> Callable[[str], Awaitable[list[str]]]:
    """Register ``/v1/sessions/{id}/resources/browsers`` routes on the runner app.

    Must run before the generic ``/resources/{resource_id}`` route so
    ``browsers`` is not captured as a resource id.

    :param app: Runner FastAPI app.
    :param manager: Owner of the per-profile host processes.
    :param publish_event: The runner's per-session event emitter.
    :returns: The session-end cleanup that closes a session's tabs.
    """
    app.state.browser_host_manager = manager

    @app.get("/v1/sessions/{session_id}/resources/browser_profiles")
    async def list_browser_profiles(session_id: str) -> JSONResponse:
        del session_id  # profiles are per machine
        availability = await manager.availability()
        return JSONResponse(
            {
                "object": "list",
                "data": await manager.list_profiles(),
                "has_more": False,
                "default_profile": DEFAULT_BROWSER_PROFILE,
                "browser_host": availability.to_dict(),
            }
        )

    @app.get("/v1/sessions/{session_id}/resources/browsers")
    async def list_session_browsers(
        session_id: str,
        limit: int = Query(default=20, ge=1, le=1000),
        after: str | None = Query(default=None),
        order: str = Query(default="desc", pattern="^(asc|desc)$"),
    ) -> JSONResponse:
        availability = await manager.availability()
        tabs: list[dict[str, object]] = []
        if availability.status == "available":
            try:
                tabs = await manager.list_tabs(session_id)
            except BrowserHostError as exc:
                return _host_error_response(exc)
        resources = [browser_tab_resource(session_id, tab) for tab in tabs]
        page, has_more = _paginate(resources, limit=limit, after=after, order=order)
        return JSONResponse(
            {
                "object": "list",
                "data": page,
                "first_id": page[0]["id"] if page else None,
                "last_id": page[-1]["id"] if page else None,
                "has_more": has_more,
                "browser_host": availability.to_dict(),
            }
        )

    @app.post("/v1/sessions/{session_id}/resources/browsers")
    async def create_session_browser(session_id: str, request: Request) -> JSONResponse:
        try:
            raw_body = await request.json()
        except ValueError:
            return _error_response(400, "invalid_input", "request body must be JSON")
        if not isinstance(raw_body, dict):
            return _error_response(400, "invalid_input", "request body must be an object")
        body = cast(dict[str, object], raw_body)
        url = body.get("url")
        profile = body.get("profile") or DEFAULT_BROWSER_PROFILE
        created_by = body.get("created_by") or "user"
        if url is not None and not (isinstance(url, str) and _is_allowed_tab_url(url)):
            return _error_response(
                400, "invalid_input", "'url' must be an http(s) URL or about:blank"
            )
        if not isinstance(profile, str):
            return _error_response(400, "invalid_input", "'profile' must be a string")
        try:
            validate_browser_profile_name(profile)
        except ValueError as exc:
            return _error_response(400, "invalid_input", str(exc))
        if created_by not in ("user", "agent"):
            return _error_response(400, "invalid_input", "'created_by' must be 'user' or 'agent'")
        try:
            viewport = _optional_viewport(body)
        except ValueError as exc:
            return _error_response(400, "invalid_input", str(exc))
        try:
            tab = await manager.create_tab(
                session_id,
                profile=profile,
                url=url,
                created_by=cast(Literal["user", "agent"], created_by),
                viewport=viewport,
            )
        except BrowserHostError as exc:
            return _host_error_response(exc)
        return JSONResponse(browser_tab_resource(session_id, tab))

    @app.get("/v1/sessions/{session_id}/resources/browsers/{tab_id}")
    async def get_session_browser(session_id: str, tab_id: str) -> JSONResponse:
        if not is_valid_browser_tab_id(tab_id):
            return _error_response(404, "not_found", f"Browser tab {tab_id!r} not found")
        try:
            resolved = await manager.resolve_tab(session_id, tab_id)
        except BrowserHostError as exc:
            return _host_error_response(exc)
        if resolved is None:
            return _error_response(404, "not_found", f"Browser tab {tab_id!r} not found")
        _state, tab = resolved
        return JSONResponse(browser_tab_resource(session_id, tab))

    @app.delete("/v1/sessions/{session_id}/resources/browsers/{tab_id}")
    async def delete_session_browser(session_id: str, tab_id: str) -> JSONResponse:
        if not is_valid_browser_tab_id(tab_id):
            return _error_response(404, "not_found", f"Browser tab {tab_id!r} not found")
        try:
            closed = await manager.close_tab(session_id, tab_id)
        except BrowserHostError as exc:
            return _host_error_response(exc)
        if not closed:
            return _error_response(404, "not_found", f"Browser tab {tab_id!r} not found")
        return JSONResponse({"id": tab_id, "object": "session.resource.deleted", "deleted": True})

    @app.websocket("/v1/sessions/{session_id}/resources/browsers/{tab_id}/attach")
    async def browser_attach_ws(
        websocket: WebSocket,
        session_id: str,
        tab_id: str,
        mode: str = Query(default="view"),
        v: int = Query(default=REMOTE_BROWSER_PROTOCOL_VERSION),
    ) -> None:
        await websocket.accept()
        if mode not in BROWSER_ATTACH_MODES:
            await websocket.close(code=_WS_CLOSE_PROTOCOL_ERROR, reason="invalid attach mode")
            return
        if v != REMOTE_BROWSER_PROTOCOL_VERSION:
            await websocket.close(
                code=WS_CLOSE_PROTOCOL_UNSUPPORTED, reason=f"protocol v={v} unsupported"
            )
            return
        attach_mode = cast(BrowserAttachMode, mode)
        try:
            availability = await manager.availability()
            resolved = (
                await manager.resolve_tab(session_id, tab_id)
                if availability.status == "available" and is_valid_browser_tab_id(tab_id)
                else None
            )
            if resolved is None:
                await websocket.close(code=WS_CLOSE_TAB_NOT_FOUND, reason="browser tab not found")
                return
            state, _tab = resolved
            reader, writer = await manager.open_attach(state, tab_id, attach_mode)
        except BrowserHostError as exc:
            # A host that is restarting or wedged is worth a reconnect.
            await websocket.close(code=_WS_CLOSE_INTERNAL, reason=exc.message[:120])
            return
        await splice_websocket_to_host(websocket, reader, writer, mode=attach_mode)

    def publish_deleted(session_id: str, tab_ids: list[str]) -> None:
        for tab_id in tab_ids:
            publish_event(
                session_id,
                {
                    "type": "session.resource.deleted",
                    "resource_id": tab_id,
                    "resource_type": "browser",
                    "session_id": session_id,
                },
            )

    async def close_session_browsers(session_id: str) -> list[str]:
        """Close the session's tabs at session end and publish their deletions.

        :returns: Ids of the closed tabs.
        :raises BrowserCleanupError: When a host failed; tabs closed on the
            other hosts are still announced first.
        """
        if (await manager.availability()).status != "available":
            return []
        try:
            closed = await manager.close_session_tabs(session_id)
        except BrowserCleanupError as exc:
            publish_deleted(session_id, exc.closed_tab_ids)
            raise
        publish_deleted(session_id, closed)
        return closed

    return close_session_browsers


def browser_cleanup_failed_response(
    session_id: str, error: BrowserCleanupError, *, object_name: str
) -> JSONResponse:
    """The 500 a session teardown returns after it finished everything but browser cleanup.

    :param session_id: The torn-down session.
    :param error: The aggregated browser cleanup failure.
    :param object_name: The teardown's normal ``object``, e.g. ``"session.deleted"``.
    """
    _logger.error("%s", error, extra={"session_id": session_id})
    return JSONResponse(
        status_code=500,
        content={
            "session_id": session_id,
            "object": object_name,
            "error": {
                "code": "resource_cleanup_failed",
                "message": str(error),
                "resource_type": "browser",
                "failures": error.failures,
                "closed": error.closed_tab_ids,
            },
        },
    )


async def splice_websocket_to_host(
    websocket: WebSocket,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    *,
    mode: BrowserAttachMode,
) -> None:
    """Pump frames between an accepted WebSocket and a host attach connection.

    WebSocket text, binary and close map to host kinds 1, 2 and 3 in both
    directions; a view attach forwards only the non-input client messages.
    Host end of stream without a close frame closes the WebSocket with 1011.

    :param websocket: Accepted client-side WebSocket.
    :param reader: Host connection reader (preamble already sent).
    :param writer: Host connection writer.
    :param mode: ``view`` or ``control``.
    """
    close_code: int | None = None
    close_reason = ""

    async def client_to_host() -> None:
        while True:
            message = await websocket.receive()
            if message.get("type") == "websocket.disconnect":
                # Mirror the client's close to the host as a kind-3 frame.
                code = message.get("code") or 1000
                reason = message.get("reason") or ""
                writer.write(
                    encode_host_frame(HostFrameKind.CLOSE, encode_close_payload(code, reason))
                )
                await writer.drain()
                return
            text = message.get("text")
            data = message.get("bytes")
            payload: str | bytes | None = text if text is not None else data
            if payload is None:
                continue
            if mode == "view" and not view_mode_allows_client_frame(payload):
                continue
            if isinstance(payload, str):
                writer.write(encode_host_frame(HostFrameKind.TEXT, payload.encode("utf-8")))
            else:
                writer.write(encode_host_frame(HostFrameKind.BINARY, payload))
            await writer.drain()

    async def host_to_client() -> None:
        nonlocal close_code, close_reason
        while True:
            frame = await read_host_frame(reader)
            if frame is None:
                close_code, close_reason = _WS_CLOSE_INTERNAL, "browser host closed the connection"
                return
            if frame.kind is HostFrameKind.TEXT:
                await websocket.send_text(frame.payload.decode("utf-8"))
            elif frame.kind is HostFrameKind.BINARY:
                await websocket.send_bytes(frame.payload)
            else:
                close_code, close_reason = decode_close_payload(frame.payload)
                return

    pumps = {
        asyncio.create_task(client_to_host(), name="browser-attach-client-to-host"),
        asyncio.create_task(host_to_client(), name="browser-attach-host-to-client"),
    }
    try:
        done, pending = await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        for task in done:
            exc = task.exception()
            if exc is None or isinstance(exc, WebSocketDisconnect):
                continue
            if isinstance(exc, HostFrameTooLargeError):
                close_code, close_reason = _WS_CLOSE_MESSAGE_TOO_BIG, "browser frame too large"
            elif isinstance(exc, HostProtocolError | ConnectionError):
                _logger.warning("browser attach splice failed: %r", exc)
                close_code, close_reason = _WS_CLOSE_INTERNAL, "browser host connection failed"
            else:
                raise exc
    finally:
        for task in pumps:
            task.cancel()
        writer.close()
        with contextlib.suppress(ConnectionError):
            # The host may already have reset the socket.
            await writer.wait_closed()
        if (
            close_code is not None
            and websocket.application_state is WebSocketState.CONNECTED
            and websocket.client_state is WebSocketState.CONNECTED
        ):
            await _close_websocket(websocket, close_code, close_reason)


async def _close_websocket(websocket: WebSocket, code: int, reason: str) -> None:
    try:
        await websocket.close(code=code, reason=reason[:120])
    except RuntimeError as exc:
        # The client closed concurrently; there is nobody left to tell.
        _logger.debug("browser attach close after client disconnect: %r", exc)
