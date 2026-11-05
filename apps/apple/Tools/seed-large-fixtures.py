#!/usr/bin/env python3
"""Seed a large data set for profiling the native apps: hundreds of sessions in several
projects and a few very long transcripts (code, tables, Mermaid, math, tool calls).

Stored test data only: no host, runner or model call. Reruns are idempotent (fixed ids) and the
existing fixtures are left alone. The long sessions use the "mock-model" agent on the online host,
so a message sent to one streams a reply into a long transcript.
"""

import argparse
import hashlib
import json
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

PROJECT_NAMES = ["Atlas API", "Billing", "Mobile shell", "Data pipeline", "Docs site", "Infra"]
TOPICS = [
    "flaky login test",
    "cache invalidation",
    "rate limiter",
    "migration rollback",
    "search ranking",
    "upload retries",
    "dark mode colors",
    "release notes",
    "memory leak",
    "websocket reconnect",
    "CSV export",
    "permissions audit",
]
VERBS = ["Fix", "Investigate", "Refactor", "Review", "Document", "Speed up", "Add tests for"]
TOOLS = ["bash", "read_file", "apply_patch", "grep"]
DAY = 86_400


@dataclass(frozen=True)
class SessionPlan:
    """One session to seed: a fixed id, title, project index (or None), age and turn count."""

    session_id: str
    title: str
    project: int | None
    age_seconds: int
    turns: int
    long: bool


@dataclass(frozen=True)
class ItemSpec:
    """One transcript item before it is stored: ``data`` is the item's JSON payload."""

    type: str
    response_id: str
    data: dict
    stable_id: str


def fixed_id(*parts: object) -> str:
    """A 32-hex id derived from ``parts``, so reruns address the same rows."""
    return hashlib.sha256("/".join(map(str, parts)).encode()).hexdigest()[:32]


def plan_sessions(count: int, long_count: int, long_turns: int) -> list[SessionPlan]:
    """The sessions to seed: ``long_count`` long ones first (newest), then short ones spread over
    60 days, filed round-robin into the projects with every fifth left unfiled."""
    plans = []
    for index in range(long_count):
        plans.append(
            SessionPlan(
                session_id=fixed_id("perf-long", index),
                title=f"Perf long transcript {index + 1}",
                project=index % len(PROJECT_NAMES),
                age_seconds=60 * (index + 1),
                turns=long_turns + 150 * index,
                long=True,
            )
        )
    for index in range(count):
        topic = TOPICS[index % len(TOPICS)]
        verb = VERBS[(index // len(TOPICS)) % len(VERBS)]
        plans.append(
            SessionPlan(
                session_id=fixed_id("perf-session", index),
                title=f"{verb} {topic} #{index + 1}",
                project=None if index % 5 == 4 else index % len(PROJECT_NAMES),
                age_seconds=600 + (index * 60 * DAY) // max(count, 1),
                turns=1 + index % 4,
                long=False,
            )
        )
    return plans


def code_block(turn: int, lines: int) -> str:
    """A Swift code block of ``lines`` lines."""
    body = [f"// Generated for turn {turn}", f"struct Model{turn}: Codable, Hashable {{"]
    for line in range(lines - 4):
        body.append(f'  var field{line}: [String: Int] = ["key{line}": {turn * line % 997}]')
    body += ["}", f"let models = (0..<{turn + 3}).map {{ _ in Model{turn}() }}"]
    return "```swift\n" + "\n".join(body) + "\n```"


def table(turn: int, rows: int) -> str:
    """A GFM table of ``rows`` rows and five columns."""
    out = [
        "| Step | Owner | Status | Latency (ms) | Notes |",
        "| --- | :---: | --- | ---: | --- |",
    ]
    for row in range(rows):
        status = ["done", "in progress", "blocked"][(turn + row) % 3]
        out.append(
            f"| {row + 1} | team-{row % 4} | {status} | {(turn * 37 + row * 11) % 900} "
            f"| `item_{turn}_{row}` with **bold** text |"
        )
    return "\n".join(out)


def assistant_text(turn: int) -> str:
    """A long markdown answer; which blocks appear varies with ``turn``."""
    topic = TOPICS[turn % len(TOPICS)]
    parts = [
        f"## Step {turn}: {topic}",
        f"I looked at the {topic} path again. The handler calls `process(batch:)` once per "
        "item, which is quadratic for large batches; batching the writes fixes it. See "
        "[the design note](https://example.com/design) for the background.",
        "- Moved the parsing out of the hot loop\n- Kept the public API unchanged\n"
        "  - nested detail with *emphasis*\n- Added a regression test",
    ]
    if turn % 2 == 0:
        parts.append(code_block(turn, 40 + turn % 60))
    if turn % 3 == 0:
        parts.append(table(turn, 8))
    if turn % 4 == 0:
        parts.append("- [x] reproduce\n- [x] fix\n- [ ] ship the release")
    if turn % 5 == 0:
        parts.append(
            f"The cost is \\(O(n \\log n)\\) for \\(n = {turn}\\) items:\n\n"
            "$$\nT(n) = 2T\\left(\\frac{n}{2}\\right) + \\Theta(n)\n$$"
        )
    if turn % 7 == 0:
        parts.append(
            "```mermaid\ngraph TD\n  A[Request] --> B{Cached?}\n  B -->|Yes| C[Serve]\n"
            "  B -->|No| D[Fetch] --> C\n```"
        )
    parts.append("> Note: this is seeded profiling data, not a real answer.")
    return "\n\n".join(parts)


def tool_output(name: str, turn: int, call: int) -> str:
    """A tool result: a unified diff for ``apply_patch``, else 20-60 lines of output."""
    if name == "apply_patch":
        lines = [
            f"diff --git a/Sources/File{turn}.swift b/Sources/File{turn}.swift",
            f"--- a/Sources/File{turn}.swift",
            f"+++ b/Sources/File{turn}.swift",
            "@@ -1,8 +1,8 @@",
        ]
        for line in range(8):
            lines += [f"-  let old{line} = {line}", f"+  let new{line} = {line * 2}"]
        return "\n".join(lines)
    return "\n".join(
        f"{name} line {line}: turn {turn} call {call} ok" for line in range(20 + turn % 40)
    )


def turn_items(session_id: str, turn: int, agent: str) -> list[ItemSpec]:
    """One turn: the user's message, sometimes reasoning, 0-3 tool calls and the answer."""
    user_response = f"turn_{fixed_id(session_id, 'user', turn)}"
    response = f"resp_{fixed_id(session_id, 'resp', turn)}"
    items = [
        ItemSpec(
            "message",
            user_response,
            {"role": "user", "content": [{"type": "input_text", "text": user_prompt(turn)}]},
            fixed_id(session_id, turn, "user"),
        )
    ]
    if turn % 3 == 0:
        summary = [
            {
                "type": "summary_text",
                "text": f"Checking how the {TOPICS[turn % 12]} code is called.",
            }
        ]
        items.append(
            ItemSpec(
                "reasoning",
                response,
                {"agent": agent, "summary": summary},
                fixed_id(session_id, turn, "reasoning"),
            )
        )
    for call in range(turn % 4):
        name = TOOLS[(turn + call) % len(TOOLS)]
        call_id = f"call_{fixed_id(session_id, turn, call)[:24]}"
        arguments = json.dumps({"path": f"Sources/File{turn}.swift", "command": f"{name} {turn}"})
        items.append(
            ItemSpec(
                "function_call",
                response,
                {"agent": agent, "name": name, "arguments": arguments, "call_id": call_id},
                fixed_id(session_id, turn, call, "call"),
            )
        )
        items.append(
            ItemSpec(
                "function_call_output",
                response,
                {"call_id": call_id, "output": tool_output(name, turn, call)},
                fixed_id(session_id, turn, call, "output"),
            )
        )
    items.append(
        ItemSpec(
            "message",
            response,
            {
                "role": "assistant",
                "agent": agent,
                "content": [{"type": "output_text", "text": assistant_text(turn)}],
            },
            fixed_id(session_id, turn, "assistant"),
        )
    )
    return items


def short_turn_items(session_id: str, turn: int, agent: str) -> list[ItemSpec]:
    """One small turn for the many short sessions: a question and a one-paragraph answer."""
    response = f"resp_{fixed_id(session_id, 'resp', turn)}"
    return [
        ItemSpec(
            "message",
            f"turn_{fixed_id(session_id, 'user', turn)}",
            {"role": "user", "content": [{"type": "input_text", "text": user_prompt(turn)}]},
            fixed_id(session_id, turn, "user"),
        ),
        ItemSpec(
            "message",
            response,
            {
                "role": "assistant",
                "agent": agent,
                "content": [{"type": "output_text", "text": f"Done: step {turn} is **fixed**."}],
            },
            fixed_id(session_id, turn, "assistant"),
        ),
    ]


def user_prompt(turn: int) -> str:
    """The user's message for ``turn``; every eleventh pastes a stack trace."""
    text = f"Next: look at the {TOPICS[turn % len(TOPICS)]} problem (step {turn})."
    if turn % 11 == 0:
        trace = "\n".join(
            f"  at frame{depth} (File{depth}.swift:{depth * 7})" for depth in range(12)
        )
        text += f"\n\n```\nFatal error: index out of range\n{trace}\n```"
    return text


def request_json(server: str, method: str, path: str, body: dict | None = None) -> dict:
    """A JSON request to the local API; raises on an HTTP error."""
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        server + path, data=data, method=method, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def ensure_projects(server: str) -> list[str]:
    """The ids of the seeded projects, created through the API when missing."""
    existing = {p["name"]: p["id"] for p in request_json(server, "GET", "/v1/projects")["data"]}
    ids = []
    for name in PROJECT_NAMES:
        if name not in existing:
            existing[name] = request_json(server, "POST", "/v1/projects", {"name": name})["id"]
        ids.append(existing[name])
    return ids


def mock_agent(server: str) -> dict:
    """The installed mock-model agent, which answers through the mock LLM."""
    agents = request_json(server, "GET", "/v1/agents?scope=user")["data"]
    for agent in agents:
        if agent["name"] == "mock-model":
            return agent
    raise SystemExit("Install the mock-model agent first (just apple-mock-agent).")


def online_host(server: str) -> str:
    """The id of an online host, for the long sessions to send through."""
    hosts = request_json(server, "GET", "/v1/hosts")["hosts"]
    online = [host["host_id"] for host in hosts if host.get("status") == "online"]
    if not online:
        raise SystemExit("No online host: start the local services (just apple-services start).")
    return online[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    repo = Path(__file__).resolve().parents[3]
    parser.add_argument(
        "--runtime",
        type=Path,
        default=repo / ".native-lab-server",
        help="the local server's runtime directory (default: this checkout's)",
    )
    parser.add_argument("--server", default="http://127.0.0.1:6767")
    parser.add_argument("--sessions", type=int, default=320)
    parser.add_argument("--long", type=int, default=3, help="how many long transcripts")
    parser.add_argument("--long-turns", type=int, default=500, help="turns in the first long one")
    args = parser.parse_args()
    seed(args)


def seed(args: argparse.Namespace) -> None:
    """Writes the planned sessions and items into the server's database."""
    import os

    runtime = args.runtime.resolve()
    database = runtime / "data" / "chat.db"
    if not database.is_file() or database.is_symlink():
        raise SystemExit("Start the local server first; the fixture DB must not be a symlink.")
    os.environ["OMNIGENT_CONFIG_HOME"] = str(runtime / "config")
    os.environ["OMNIGENT_DATA_DIR"] = str(runtime / "data")
    os.environ["DO_NOT_TRACK"] = "1"

    from sqlalchemy import update

    from omnigent.db.db_models import SqlConversation
    from omnigent.db.utils import get_or_create_engine
    from omnigent.entities import (
        FunctionCallData,
        FunctionCallOutputData,
        MessageData,
        NewConversationItem,
        ReasoningData,
    )
    from omnigent.stores.conversation_store.sqlalchemy_store import SqlAlchemyConversationStore
    from omnigent.stores.permission_store.sqlalchemy_store import SqlAlchemyPermissionStore

    models = {
        "message": MessageData,
        "reasoning": ReasoningData,
        "function_call": FunctionCallData,
        "function_call_output": FunctionCallOutputData,
    }
    uri = f"sqlite:///{database}"
    agent = mock_agent(args.server)
    projects = ensure_projects(args.server)
    host_id = online_host(args.server)
    conversations = SqlAlchemyConversationStore(uri)
    permissions = SqlAlchemyPermissionStore(uri)
    permissions.ensure_user("local")
    engine = get_or_create_engine(uri)
    now = int(time.time())
    created = 0
    for plan in plan_sessions(args.sessions, args.long, args.long_turns):
        existing = conversations.get_conversation(plan.session_id)
        if existing is not None:
            if existing.title != plan.title:
                raise SystemExit(f"Refusing to modify an unexpected session: {plan.session_id}")
            continue
        conversations.create_conversation(
            conversation_id=plan.session_id,
            title=plan.title,
            agent_id=agent["id"],
            host_id=host_id if plan.long else None,
            workspace=str(runtime / "chat-workspace") if plan.long else None,
            project_id=None if plan.project is None else projects[plan.project],
        )
        build = turn_items if plan.long else short_turn_items
        batch: list[NewConversationItem] = []
        for turn in range(1, plan.turns + 1):
            for spec in build(plan.session_id, turn, agent["name"]):
                data = models[spec.type](**spec.data)
                batch.append(
                    NewConversationItem(
                        type=spec.type,
                        response_id=spec.response_id,
                        data=data,
                        stable_id=spec.stable_id,
                    )
                )
            if len(batch) >= 400:
                conversations.append(plan.session_id, batch)
                batch = []
        if batch:
            conversations.append(plan.session_id, batch)
        stamp = now - plan.age_seconds
        with engine.begin() as connection:
            connection.execute(
                update(SqlConversation)
                .where(SqlConversation.workspace_id == 0, SqlConversation.id == plan.session_id)
                .values(created_at=stamp, updated_at=stamp)
            )
        permissions.grant("local", plan.session_id, 4)
        created += 1
    print(
        f"Seeded {created} new sessions ({args.sessions} short, {args.long} long planned) "
        f"in {len(projects)} projects. No host, runner or model was started."
    )


if __name__ == "__main__":
    main()
