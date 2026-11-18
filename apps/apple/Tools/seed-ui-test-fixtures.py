#!/usr/bin/env python3
"""Seed the session the iOS UI tests tap through: a short exchange with a tool call and a web
link, bound to the online host and a small workspace (folders for `@` mentions, files to edit,
`notes.md` and `notes.pdf` to preview, and `media/demo.mp4` with its chapters to play).

Stored test data, no model call; the host launches the session's runner so its file APIs work.
Reruns keep the session (fixed id) and restore the workspace files, so a test that edited one
starts from the same text. A session whose history has grown (every terminal a test opens adds
an item) is deleted, with its terminals, and seeded again. Prints the session id and the
workspace path.

Also seeds a second session with a few pages of short history (its id is `fixed_id("ui-test",
"paged")`, which the Mac flows know): enough to page, small enough for UI automation to read.
And a third with the agent's own task list and two of its task markers (`fixed_id("ui-test",
"tasks")`), for the Tasks tab.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

TITLE = "UI test fixture"
PAGED_TITLE = "UI test paged history"
TASKS_TITLE = "UI test tasks"
# The agent's own task list, as a native forwarder reports it (Claude's task ids).
TASK_TODOS = [
    {
        "id": "task-read",
        "content": "Read the workspace",
        "status": "completed",
        "activeForm": "Reading the workspace",
    },
    {
        "id": "task-fix",
        "content": "Fix the greeting",
        "status": "in_progress",
        "activeForm": "Fixing the greeting",
    },
    {
        "id": "task-test",
        "content": "Write a test",
        "status": "pending",
        "activeForm": "Writing a test",
    },
]
# The chapters of `media/demo.mp4`, which its player lists.
DEMO_CHAPTERS = (
    "WEBVTT\n\n00:00.000 --> 00:01.000\nSay hello\n\n00:01.000 --> 00:02.000\nSay goodbye\n"
)
# The server pages history 50 items at a time; a turn here is two items.
PAGED_TURNS = 60
WORKSPACE_FILES = {
    "README.md": "# UI test fixture\n\nA workspace the native UI tests browse and edit.\n",
    "docs/guide.md": "# Guide\n\nSteps the tests read.\n",
    "src/main.swift": 'print("Hello from the UI test fixture")\n',
    "src/model/user.swift": "struct User {\n  let name: String\n}\n",
    "notes.md": "# Notes\n\nOpened in Quick Look and shared by the browser tests.\n",
}
# A one-page PDF with no text: enough for Quick Look.
NOTES_PDF = (
    b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
    b"2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
    b"3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\n"
    b"trailer<</Root 1 0 R>>\n%%EOF\n"
)


def load_large_seeder():
    """The large seeder's API helpers (`fixed_id`, `mock_agent`, `online_host`)."""
    path = Path(__file__).with_name("seed-large-fixtures.py")
    spec = importlib.util.spec_from_file_location("seed_large_fixtures", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"Cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_workspace(root: Path) -> None:
    """Recreates the fixture workspace under `root`."""
    if root.is_symlink():
        raise SystemExit(f"Refusing a symlinked workspace: {root}")
    if root.exists():
        shutil.rmtree(root)
    for relative, text in WORKSPACE_FILES.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    (root / "notes.pdf").write_bytes(NOTES_PDF)
    write_demo_video(root / "media")


def write_demo_video(folder: Path) -> None:
    """A two-second spoken MPEG-4 recording and its chapters, made with macOS's `say`."""
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "demo.mp4.chapters.vtt").write_text(DEMO_CHAPTERS)
    command = [
        "say",
        "-o",
        str(folder / "demo.mp4"),
        "--file-format=mp4f",
        "--data-format=aac",
        "Hello. Goodbye.",
    ]
    try:
        subprocess.run(command, check=True, capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as error:
        # The workspace stays usable without it; the video flow then fails on the missing file.
        print(f"Could not record media/demo.mp4: {error}", file=sys.stderr)


def items(session_id: str, agent: str, fixed_id) -> list[tuple[str, str, dict, str]]:
    """The exchange: a question, one `bash` call with its output, and the answer."""
    response = f"resp_{fixed_id(session_id, 'resp')}"
    call_id = f"call_{fixed_id(session_id, 'call')[:24]}"
    question = "List the workspace and summarize it."
    answer = (
        "The workspace has a **README**, a `docs` folder and Swift sources under `src`. "
        "See [Example Domain](https://example.com) for the format."
    )
    return [
        (
            "message",
            f"turn_{fixed_id(session_id, 'user')}",
            {"role": "user", "content": [{"type": "input_text", "text": question}]},
            fixed_id(session_id, "user"),
        ),
        (
            "function_call",
            response,
            {
                "agent": agent,
                "name": "bash",
                "arguments": json.dumps({"command": "ls -R"}),
                "call_id": call_id,
            },
            fixed_id(session_id, "call"),
        ),
        (
            "function_call_output",
            response,
            {"call_id": call_id, "output": "README.md\ndocs\nsrc\n\n./docs:\nguide.md"},
            fixed_id(session_id, "output"),
        ),
        (
            "message",
            response,
            {
                "role": "assistant",
                "agent": agent,
                "content": [{"type": "output_text", "text": answer}],
            },
            fixed_id(session_id, "assistant"),
        ),
    ]


def seed_paged(large, conversations, permissions, agent: dict) -> None:
    """Seeds the session with several pages of history, once."""
    from omnigent.entities import MessageData, NewConversationItem

    session_id = large.fixed_id("ui-test", "paged")
    existing = conversations.get_conversation(session_id)
    if existing is not None:
        if existing.title != PAGED_TITLE:
            raise SystemExit(f"Refusing to modify an unexpected session: {session_id}")
        return
    conversations.create_conversation(
        conversation_id=session_id, title=PAGED_TITLE, agent_id=agent["id"]
    )
    conversations.append(
        session_id,
        [
            NewConversationItem(
                type=spec.type,
                response_id=spec.response_id,
                data=MessageData(**spec.data),
                stable_id=spec.stable_id,
            )
            for turn in range(1, PAGED_TURNS + 1)
            for spec in large.short_turn_items(session_id, turn, agent["name"])
        ],
    )
    permissions.grant("local", session_id, 4)


def seed_tasks(large, conversations, permissions, agent: dict) -> None:
    """Seeds a session with the agent's own task list and its first two task markers, once."""
    from omnigent.entities import MessageData, NewConversationItem, ResourceEventData

    session_id = large.fixed_id("ui-test", "tasks")
    existing = conversations.get_conversation(session_id)
    if existing is not None:
        if existing.title != TASKS_TITLE:
            raise SystemExit(f"Refusing to modify an unexpected session: {session_id}")
        return
    conversations.create_conversation(
        conversation_id=session_id, title=TASKS_TITLE, agent_id=agent["id"]
    )
    question = "Fix the greeting and test it."
    items = [
        NewConversationItem(
            type="message",
            response_id=f"turn_{large.fixed_id(session_id, 'user')}",
            data=MessageData(role="user", content=[{"type": "input_text", "text": question}]),
            stable_id=large.fixed_id(session_id, "user"),
        )
    ]
    # The markers the server writes as the tasks start and finish (`record_todo_markers`).
    for todo, status in ((TASK_TODOS[0], "done"), (TASK_TODOS[1], "started")):
        key = f"todo:{todo['id']}:{status}:seed"
        stable = hashlib.sha256(f"{session_id}:{key}".encode()).hexdigest()[:32]
        items.append(
            NewConversationItem(
                type="resource_event",
                response_id=f"journal_{stable}",
                stable_id=stable,
                data=ResourceEventData(
                    event_type="session.journal.task",
                    resource_id=todo["id"],
                    resource_type="journal",
                    resource={
                        "name": todo["content"],
                        "status": status,
                        "text": None,
                        "entry_id": None,
                        "native": True,
                    },
                ),
            )
        )
    conversations.append(session_id, items)
    conversations.set_session_todos(session_id, TASK_TODOS)
    permissions.grant("local", session_id, 4)


def has_grown(large, server: str, session_id: str, seeded: int) -> bool:
    """Whether the session's history holds more than its `seeded` items."""
    path = f"/v1/sessions/{session_id}/items?limit={seeded + 1}"
    return len(large.request_json(server, "GET", path)["data"]) > seeded


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    repo = Path(__file__).resolve().parents[3]
    parser.add_argument(
        "--runtime",
        type=Path,
        default=Path(os.environ.get("OMNIGENT_LAB_RUNTIME", repo / ".native-lab-server")),
        help="the local server's runtime directory (default: $OMNIGENT_LAB_RUNTIME or this "
        "checkout's .native-lab-server)",
    )
    parser.add_argument("--server", default="http://127.0.0.1:6767")
    args = parser.parse_args()
    seed(args)


def seed(args: argparse.Namespace) -> None:
    """Writes the workspace and, when missing, the session and its items."""
    runtime = args.runtime.resolve()
    database = runtime / "data" / "chat.db"
    if not database.is_file() or database.is_symlink():
        raise SystemExit(f"No local server database at {database}; pass --runtime.")
    os.environ["OMNIGENT_CONFIG_HOME"] = str(runtime / "config")
    os.environ["OMNIGENT_DATA_DIR"] = str(runtime / "data")
    os.environ["DO_NOT_TRACK"] = "1"

    from omnigent.entities import (
        FunctionCallData,
        FunctionCallOutputData,
        MessageData,
        NewConversationItem,
    )
    from omnigent.stores.conversation_store.sqlalchemy_store import SqlAlchemyConversationStore
    from omnigent.stores.permission_store.sqlalchemy_store import SqlAlchemyPermissionStore

    large = load_large_seeder()
    workspace = runtime / "ui-test-workspace"
    write_workspace(workspace)
    session_id = large.fixed_id("ui-test", "conversation")
    uri = f"sqlite:///{database}"
    conversations = SqlAlchemyConversationStore(uri)
    permissions = SqlAlchemyPermissionStore(uri)
    agent = large.mock_agent(args.server)
    seed_paged(large, conversations, permissions, agent)
    seed_tasks(large, conversations, permissions, agent)
    existing = conversations.get_conversation(session_id)
    if existing is not None:
        if existing.title != TITLE:
            raise SystemExit(f"Refusing to modify an unexpected session: {session_id}")
        seeded = len(items(session_id, agent["name"], large.fixed_id))
        if not has_grown(large, args.server, session_id, seeded):
            if existing.runner_id is None and existing.host_id is not None:
                launch_runner(large, args.server, existing.host_id, session_id, workspace)
            print(session_id, workspace)
            return
        # After a page of added items a new window shows none of the seeded messages. Deleting
        # through the server also ends the session's runner and the terminals tests left.
        large.request_json(args.server, "DELETE", f"/v1/sessions/{session_id}")
        write_workspace(workspace)
    host_id = large.online_host(args.server)
    conversations.create_conversation(
        conversation_id=session_id,
        title=TITLE,
        agent_id=agent["id"],
        host_id=host_id,
        workspace=str(workspace),
    )
    models = {
        "message": MessageData,
        "function_call": FunctionCallData,
        "function_call_output": FunctionCallOutputData,
    }
    conversations.append(
        session_id,
        [
            NewConversationItem(
                type=kind, response_id=response, data=models[kind](**data), stable_id=stable
            )
            for kind, response, data, stable in items(session_id, agent["name"], large.fixed_id)
        ],
    )
    permissions.grant("local", session_id, 4)
    launch_runner(large, args.server, host_id, session_id, workspace)
    print(session_id, workspace)


def launch_runner(large, server: str, host_id: str, session_id: str, workspace: Path) -> None:
    """Has the host launch a runner bound to the session, which the file APIs go through."""
    body = {"session_id": session_id, "workspace": str(workspace)}
    large.request_json(server, "POST", f"/v1/hosts/{host_id}/runners", body)


if __name__ == "__main__":
    main()
