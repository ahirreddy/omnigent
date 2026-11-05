#!/usr/bin/env python3
"""Seed the session the iOS UI tests tap through: a short exchange with a tool call and a web
link, bound to the online host and a small workspace (folders for `@` mentions, files to edit,
`notes.md` and `notes.pdf` to preview).

Stored test data only: no runner or model call. Reruns keep the session (fixed id) and restore
the workspace files, so a test that edited one starts from the same text. Prints the session id
and the workspace path.
"""

import argparse
import importlib.util
import json
import os
import shutil
from pathlib import Path

TITLE = "UI test fixture"
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
    existing = conversations.get_conversation(session_id)
    if existing is not None:
        if existing.title != TITLE:
            raise SystemExit(f"Refusing to modify an unexpected session: {session_id}")
        print(session_id, workspace)
        return
    agent = large.mock_agent(args.server)
    conversations.create_conversation(
        conversation_id=session_id,
        title=TITLE,
        agent_id=agent["id"],
        host_id=large.online_host(args.server),
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
    SqlAlchemyPermissionStore(uri).grant("local", session_id, 4)
    print(session_id, workspace)


if __name__ == "__main__":
    main()
