"""Claude's ``Elicitation`` hook: an MCP server asks the user for input through Claude.

Claude runs the hook before it shows its own dialog (or, under the Agent SDK,
before it declines the request); an answer from the hook replaces it. The
request becomes a standard MCP elicitation card (a form, or a page to open in
URL mode), and the card's answer becomes the hook's output. Kept
dependency-light so harness code can import it.
"""

from __future__ import annotations

from typing import Any

from omnigent.errors import ErrorCode, OmnigentError
from omnigent.server.schemas import ElicitationRequestParams, ElicitationResult

#: Phase of a Claude MCP elicitation card.
CLAUDE_MCP_ELICITATION_PHASE = "claude_mcp_elicitation"
#: Policy names of the card, by harness.
CLAUDE_NATIVE_MCP_ELICITATION_POLICY = "claude_native_mcp_elicitation"
CLAUDE_SDK_MCP_ELICITATION_POLICY = "claude_sdk_mcp_elicitation"


def claude_mcp_elicitation_params(
    payload: dict[str, Any],
    policy_name: str = CLAUDE_NATIVE_MCP_ELICITATION_POLICY,
) -> ElicitationRequestParams:
    """
    The card for one Claude ``Elicitation`` hook payload.

    :param payload: The hook input, e.g. ``{"hook_event_name": "Elicitation",
        "mcp_server_name": "deploy", "message": "Choose where to deploy.",
        "mode": "form", "requested_schema": {"type": "object", ...}}``.
    :param policy_name: The card's policy name, naming the harness.
    :returns: Form-mode params carrying ``requested_schema``, or URL-mode params
        carrying ``url``; ``server_name`` names the asking server.
    :raises OmnigentError: 400 when the payload names no server or message,
        has an unknown mode, a non-object schema, or a URL request without a URL.
    """
    server_name = payload.get("mcp_server_name")
    message = payload.get("message")
    if not isinstance(server_name, str) or not server_name:
        raise OmnigentError(
            "Elicitation hook body must include 'mcp_server_name'.",
            code=ErrorCode.INVALID_INPUT,
        )
    if not isinstance(message, str) or not message:
        raise OmnigentError(
            "Elicitation hook body must include 'message'.",
            code=ErrorCode.INVALID_INPUT,
        )
    mode = payload.get("mode") or "form"
    extras: dict[str, Any] = {"server_name": server_name}
    if mode == "url":
        url = payload.get("url")
        if not isinstance(url, str) or not url:
            raise OmnigentError(
                "A URL-mode Elicitation hook body must include 'url'.",
                code=ErrorCode.INVALID_INPUT,
            )
        mcp_elicitation_id = payload.get("elicitation_id")
        if isinstance(mcp_elicitation_id, str) and mcp_elicitation_id:
            extras["mcp_elicitation_id"] = mcp_elicitation_id
        return ElicitationRequestParams(
            mode="url",
            message=message,
            url=url,
            phase=CLAUDE_MCP_ELICITATION_PHASE,
            policy_name=policy_name,
            **extras,
        )
    if mode != "form":
        raise OmnigentError(
            f"Elicitation hook mode {mode!r} is not 'form' or 'url'.",
            code=ErrorCode.INVALID_INPUT,
        )
    schema = payload.get("requested_schema")
    if schema is not None and not isinstance(schema, dict):
        raise OmnigentError(
            "Elicitation hook 'requested_schema' must be an object when present.",
            code=ErrorCode.INVALID_INPUT,
        )
    return ElicitationRequestParams(
        mode="form",
        message=message,
        requestedSchema=schema,
        phase=CLAUDE_MCP_ELICITATION_PHASE,
        policy_name=policy_name,
        **extras,
    )


def claude_mcp_elicitation_output(result: ElicitationResult) -> dict[str, Any]:
    """
    The ``Elicitation`` hook output for the card's answer.

    :param result: The answer, e.g. ``{"action": "accept", "content": {"notify": true}}``.
    :returns: ``{"hookSpecificOutput": {"hookEventName": "Elicitation", "action": ...}}``,
        with ``content`` when an accepted form carried any.
    """
    output: dict[str, Any] = {"hookEventName": "Elicitation", "action": result.action}
    if result.action == "accept" and result.content:
        output["content"] = result.content
    return {"hookSpecificOutput": output}
