"""``browser_switch``: the agent moves its browser, with the owner's approval for the Mac's."""

from __future__ import annotations

import asyncio
import json
from collections.abc import Iterator, Mapping
from typing import Any

import httpx
import pytest

from omnigent.browser_devtools_availability import BROWSER_TARGET_LABEL
from omnigent.runner import pending_approvals
from omnigent.runner.browser_devtools.choice import OWNER_ONLY, SEPARATE_LOGINS, switch_browser


@pytest.fixture(autouse=True)
def _fresh_approvals() -> Iterator[None]:
    pending_approvals.reset_for_tests()
    yield
    pending_approvals.reset_for_tests()


class _Server:
    """Answers the session's label PATCH and its elicitation POSTs, recording both."""

    def __init__(self, patch_status: int = 200) -> None:
        self.patch_status = patch_status
        self.patches: list[dict[str, Any]] = []
        self.questions: list[dict[str, Any]] = []
        self.published: list[Mapping[str, object]] = []

    def client(self) -> httpx.AsyncClient:
        def handler(request: httpx.Request) -> httpx.Response:
            body = json.loads(request.content)
            if request.method == "PATCH" and request.url.path == "/v1/sessions/conv_a":
                self.patches.append(body)
                return httpx.Response(self.patch_status, json={"detail": "owner only"})
            if request.method == "POST" and request.url.path == "/v1/sessions/conv_a/events":
                self.questions.append(body)
                eid = f"elicit_{len(self.questions)}"
                return httpx.Response(200, json={"queued": False, "elicitation_id": eid})
            raise AssertionError(f"unexpected {request.method} {request.url.path}")

        return httpx.AsyncClient(
            transport=httpx.MockTransport(handler), base_url="http://server.test"
        )

    def publish(self, session_id: str, event: Mapping[str, object]) -> None:
        assert session_id == "conv_a"
        self.published.append(event)

    async def switch(self, target: str, reason: str = "The site needs your account") -> Any:
        async with self.client() as client:
            result = await switch_browser(
                {"target": target, "reason": reason},
                server_client=client,
                session_id="conv_a",
                publish_event=self.publish,
            )
        return json.loads(result)


async def _answer(elicitation_id: str, approved: bool) -> None:
    """Resolve the question once the tool waits on it."""
    for _ in range(500):
        if pending_approvals.resolve(elicitation_id, approved):
            return
        await asyncio.sleep(0.01)
    raise AssertionError(f"{elicitation_id} was never asked")


@pytest.mark.parametrize(("target", "label"), [("remote", "remote"), ("auto", "")])
async def test_the_agent_machine_and_auto_apply_without_asking(target: str, label: str) -> None:
    server = _Server()
    result = await server.switch(target)

    assert server.questions == []
    assert server.patches == [{"labels": {BROWSER_TARGET_LABEL: label}}]
    assert result["switched"] is True and result["target"] == target
    assert SEPARATE_LOGINS in result["detail"]


async def test_the_mac_browser_waits_for_the_owners_approval() -> None:
    server = _Server()
    result, _ = await asyncio.gather(server.switch("local"), _answer("elicit_1", True))

    (question,) = server.questions
    assert question["type"] == "mcp_elicitation"
    assert "The site needs your account" in question["data"]["message"]
    assert server.patches == [{"labels": {BROWSER_TARGET_LABEL: "local"}}]
    assert result["switched"] is True
    # The card closes once answered.
    assert {"type": "response.elicitation_resolved", "elicitation_id": "elicit_1"} in (
        server.published
    )


async def test_a_declined_switch_leaves_the_browser_alone() -> None:
    server = _Server()
    result, _ = await asyncio.gather(server.switch("local"), _answer("elicit_1", False))

    assert server.patches == []
    assert result["switched"] is False
    assert "declined" in result["detail"]


async def test_the_owner_only_rule_reads_as_such() -> None:
    server = _Server(patch_status=403)
    result, _ = await asyncio.gather(server.switch("local"), _answer("elicit_1", True))

    assert result == {"error": OWNER_ONLY}


@pytest.mark.parametrize(
    "args",
    [{"target": "mac", "reason": "x"}, {"target": "remote"}, {"target": "remote", "reason": " "}],
)
async def test_bad_arguments_change_nothing(args: dict[str, str]) -> None:
    server = _Server()
    async with server.client() as client:
        result = json.loads(
            await switch_browser(
                args, server_client=client, session_id="conv_a", publish_event=server.publish
            )
        )

    assert "error" in result
    assert server.patches == [] and server.questions == []


async def test_the_runner_dispatches_browser_switch_for_a_devtools_spec() -> None:
    from omnigent.browser_devtools_availability import with_browser_devtools
    from omnigent.runner.tool_dispatch import execute_tool
    from omnigent.spec.types import AgentSpec

    spec = with_browser_devtools(
        AgentSpec(spec_version=1), "ws://127.0.0.1:1/devtools/browser/conv_a.00"
    )
    server = _Server()
    async with server.client() as client:
        result = json.loads(
            await execute_tool(
                tool_name="browser_switch",
                arguments=json.dumps({"target": "remote", "reason": "Keep going while it sleeps"}),
                server_client=client,
                agent_spec=spec,
                conversation_id="conv_a",
            )
        )

    assert result["switched"] is True
    assert server.patches == [{"labels": {BROWSER_TARGET_LABEL: "remote"}}]
