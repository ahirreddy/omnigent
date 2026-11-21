"""Write a session's browser choice and ask its owner about it.

The choice is the session label ``omnigent.browser_target``. The server lets only
the owner of an unshared session write ``local``; a write the label no longer
allows closes the session's old proxy connection
(:meth:`RunnerBrowserResolver.still_selected`), so the next tool call lands on the
new browser. Questions to the owner are elicitations: the server publishes the card
and the runner waits on :mod:`omnigent.runner.pending_approvals`.
"""

from __future__ import annotations

import json
from collections.abc import Callable, Mapping
from typing import Any, Final

import httpx

from omnigent.browser_devtools_availability import BROWSER_TARGET_LABEL, BROWSER_TARGETS
from omnigent.runner import pending_approvals

# What pending_approvals publishes the card's close with: the runner's session event emitter.
PublishEvent = Callable[[str, dict[str, object]], None]

OWNER_ONLY: Final[str] = "Only the owner of an unshared session can use this Mac's browser."
SEPARATE_LOGINS: Final[str] = (
    "Logins and cookies don't carry over between this Mac's browser and the agent's machine."
)
DESCRIPTIONS: Final[dict[str, str]] = {
    "local": "this Mac's browser",
    "remote": "the agent machine's browser",
    "auto": "whichever browser Omnigent picks",
}
# Long enough for the owner to notice the card; the agent's turn waits on it.
SWITCH_APPROVAL_TIMEOUT_S: Final[float] = 600.0
_POST_TIMEOUT_S: Final[float] = 30.0


class BrowserChoiceError(Exception):
    """The choice could not be written or asked about; the message says why."""


async def write_browser_target(
    server_client: httpx.AsyncClient, session_id: str, target: str
) -> None:
    """Set the session's ``omnigent.browser_target``; ``auto`` clears the label.

    :param target: ``"local"``, ``"remote"`` or ``"auto"``.
    :raises BrowserChoiceError: When the server refuses or cannot be reached; a 403
        is the owner-only rule for ``local``.
    """
    value = "" if target == "auto" else target
    try:
        response = await server_client.patch(
            f"/v1/sessions/{session_id}",
            json={"labels": {BROWSER_TARGET_LABEL: value}},
            timeout=_POST_TIMEOUT_S,
        )
    except httpx.HTTPError as exc:
        raise BrowserChoiceError(f"Could not save the browser choice: {exc}") from exc
    if response.status_code == 403:
        raise BrowserChoiceError(OWNER_ONLY)
    if response.status_code >= 400:
        raise BrowserChoiceError(
            f"The server refused the browser choice (HTTP {response.status_code}): "
            f"{response.text[:200]}"
        )


async def ask_owner(
    server_client: httpx.AsyncClient,
    session_id: str,
    publish_event: PublishEvent,
    *,
    message: str,
    timeout_s: float,
    requested_schema: dict[str, Any] | None = None,
) -> pending_approvals.Verdict:
    """Show the session an elicitation and wait for the answer.

    Only the session's owner can answer for an unshared session. A server reconnect
    asks again under a new id.

    :param message: The question.
    :param timeout_s: How long to wait; an unanswered question returns a timed-out
        verdict.
    :param requested_schema: An MCP form schema, or ``None`` for approve or decline.
    :raises BrowserChoiceError: When the server cannot show the question.
    """
    data: dict[str, Any] = {"message": message}
    if requested_schema is not None:
        data["requestedSchema"] = requested_schema
    while True:
        try:
            response = await server_client.post(
                f"/v1/sessions/{session_id}/events",
                json={"type": "mcp_elicitation", "data": data},
                timeout=_POST_TIMEOUT_S,
            )
            response.raise_for_status()
            elicitation_id = response.json().get("elicitation_id")
        except (httpx.HTTPError, ValueError, AttributeError) as exc:
            raise BrowserChoiceError(f"Could not ask about the browser: {exc}") from exc
        if not isinstance(elicitation_id, str) or not elicitation_id:
            raise BrowserChoiceError("The server did not open the browser question.")
        try:
            return await pending_approvals.wait_for_user_verdict(
                elicitation_id=elicitation_id,
                conversation_id=session_id,
                publish_event=publish_event,
                timeout_seconds=timeout_s,
                retry_on_server_reconnect=True,
            )
        except pending_approvals.ServerReconnected:
            continue


async def switch_browser(
    args: Mapping[str, object],
    *,
    server_client: httpx.AsyncClient | None,
    session_id: str | None,
    publish_event: PublishEvent | None,
) -> str:
    """Run the ``browser_switch`` tool: point the session's agent at another browser.

    ``remote`` and ``auto`` apply at once. ``local`` gives the agent the owner's
    logins, so the owner approves it first.

    :param args: ``{"target": "local" | "remote" | "auto", "reason": str}``.
    :returns: The JSON tool result.
    """
    target = args.get("target")
    reason = args.get("reason")
    if not isinstance(target, str) or target not in BROWSER_TARGETS:
        return json.dumps({"error": f"target must be one of {sorted(BROWSER_TARGETS)}"})
    if not isinstance(reason, str) or not reason.strip():
        return json.dumps({"error": "reason is required: say why the agent needs that browser"})
    if server_client is None or not session_id:
        return json.dumps({"error": "browser_switch requires a server connection and a session"})
    if target == "local":
        publish = publish_event or (lambda _session, _event: None)
        try:
            verdict = await ask_owner(
                server_client,
                session_id,
                publish,
                message=f"The agent asks to use this Mac's browser, with your logins: {reason}",
                timeout_s=SWITCH_APPROVAL_TIMEOUT_S,
            )
        except BrowserChoiceError as exc:
            return json.dumps({"error": str(exc)})
        if not verdict.approved:
            detail = "No answer in time" if verdict.timed_out else "The user declined"
            return json.dumps(
                {
                    "switched": False,
                    "detail": f"{detail}; the browser stays as it was. Don't ask again this turn.",
                }
            )
    try:
        await write_browser_target(server_client, session_id, target)
    except BrowserChoiceError as exc:
        return json.dumps({"error": str(exc)})
    return json.dumps(
        {
            "switched": True,
            "target": target,
            "detail": (
                f"The next browser call uses {DESCRIPTIONS[target]}. Tabs stay open in the "
                f"old browser. {SEPARATE_LOGINS}"
            ),
        }
    )
