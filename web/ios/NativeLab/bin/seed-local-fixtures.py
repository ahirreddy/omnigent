#!/usr/bin/env python3
"""Seed UI fixtures in this checkout's dedicated development database."""

import os
from pathlib import Path


def main() -> None:
    repo = Path(__file__).resolve().parents[4]
    runtime = repo / ".native-lab-server"
    database = runtime / "data" / "chat.db"
    if database.resolve() != database or not database.is_file():
        raise SystemExit("Start bin/local-server.sh first; the fixture DB must not be a symlink.")

    os.environ["OMNIGENT_CONFIG_HOME"] = str(runtime / "config")
    os.environ["OMNIGENT_DATA_DIR"] = str(runtime / "data")
    os.environ["DO_NOT_TRACK"] = "1"

    from sqlalchemy import update

    from omnigent.db.db_models import SqlConversation
    from omnigent.db.utils import get_or_create_engine
    from omnigent.entities import MessageData, NewConversationItem
    from omnigent.stores.agent_store.sqlalchemy_store import SqlAlchemyAgentStore
    from omnigent.stores.conversation_store.sqlalchemy_store import SqlAlchemyConversationStore
    from omnigent.stores.permission_store.sqlalchemy_store import SqlAlchemyPermissionStore

    uri = f"sqlite:///{database}"
    agent = SqlAlchemyAgentStore(uri).get_by_name("codex-native-ui")
    if agent is None:
        raise SystemExit("The local server must have registered its built-in agent catalog first.")
    conversations = SqlAlchemyConversationStore(uri)
    permissions = SqlAlchemyPermissionStore(uri)
    permissions.ensure_user("local")
    fixtures = [
        ("a1000000000000000000000000000001", "Local fixture A", 1),
        ("a1000000000000000000000000000002", "Local fixture B", 1),
        ("f1000000000000000000000000000001", "Local API validation", 60),
        ("f2000000000000000000000000000001", "Live stream validation", 0),
    ]
    for session_id, title, count in fixtures:
        existing = conversations.get_conversation(session_id)
        if existing is not None and (
            existing.title != title
            or existing.workspace != str(runtime)
            or existing.agent_id not in (None, agent.id)
            or existing.runner_id
            or existing.host_id
        ):
            raise SystemExit(f"Refusing to modify an unexpected existing session: {session_id}")
        if existing is None:
            conversations.create_conversation(
                conversation_id=session_id, title=title, workspace=str(runtime), agent_id=agent.id
            )
        elif existing.agent_id is None:
            with get_or_create_engine(uri).begin() as connection:
                connection.execute(
                    update(SqlConversation)
                    .where(SqlConversation.workspace_id == 0, SqlConversation.id == session_id)
                    .values(agent_id=agent.id)
                )
        items = conversations.list_items(session_id, limit=1000, order="asc")
        if not items.data:
            conversations.append(
                session_id,
                [
                    NewConversationItem(
                        type="message",
                        response_id=session_id,
                        data=MessageData(
                            role="user" if index % 2 else "assistant",
                            agent=None if index % 2 else "Local fixture",
                            content=[
                                {
                                    "type": "input_text" if index % 2 else "output_text",
                                    "text": f"Local API fixture message {index:02d}.",
                                }
                            ],
                        ),
                    )
                    for index in range(1, count + 1)
                ],
            )
        elif session_id != "f2000000000000000000000000000001" and (
            len(items.data) != count or items.has_more
        ):
            raise SystemExit(f"Existing fixture differs; left it untouched: {session_id}")
        permissions.grant("local", session_id, 4)
        print(f"Ready: {session_id} ({count} stored fixture messages)")
    print("Fixtures are stored test data. No host, runner or model was started.")


if __name__ == "__main__":
    main()
