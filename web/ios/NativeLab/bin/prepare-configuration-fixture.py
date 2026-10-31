#!/usr/bin/env python3
"""Prepare a separate host-bound configuration fixture; never submit a model prompt."""

from pathlib import Path

import httpx


def main() -> None:
    workspace = Path(__file__).resolve().parents[4] / ".native-lab-server" / "chat-workspace"
    title = "Native configuration validation"
    marker = "Stored configuration fixture. No model response was generated."
    if workspace.resolve() != workspace or not workspace.is_dir():
        raise SystemExit("Start the isolated local host first; workspace must not be a symlink.")
    with httpx.Client(
        base_url="http://127.0.0.1:6767", timeout=60, trust_env=False, follow_redirects=False
    ) as client:

        def get(path: str) -> dict:
            response = client.get(path)
            response.raise_for_status()
            return response.json()

        info = get("/v1/info")
        if not info.get("single_user") or info.get("accounts_enabled"):
            raise SystemExit("Expected the dedicated single-user local server.")
        if get("/v1/me").get("user_id") != "local":
            raise SystemExit("Unexpected local identity.")
        hosts = [host for host in get("/v1/hosts")["hosts"] if host["status"] == "online"]
        if (
            len(hosts) != 1
            or hosts[0].get("configured_harnesses", {}).get("codex-native") is not True
        ):
            raise SystemExit("Expected exactly one online local host with Codex configured.")
        host = hosts[0]
        agents = get("/v1/agents?limit=1000")["data"]
        agent = next(value for value in agents if value["name"] == "codex-native-ui")
        matches = get("/v1/sessions?limit=1000&search_query=Native%20configuration%20validation")[
            "data"
        ]
        matches = [session for session in matches if session.get("title") == title]
        if len(matches) > 1:
            raise SystemExit("Multiple configuration fixtures exist; refusing to choose one.")
        if matches:
            session_id = matches[0]["id"]
            session = get(f"/v1/sessions/{session_id}?include_items=false")
            if (
                session.get("workspace") != str(workspace)
                or session.get("host_id") != host["host_id"]
            ):
                raise SystemExit(
                    "Existing fixture has an unexpected workspace or host; left untouched."
                )
            if session.get("status") not in ("idle", "failed"):
                raise SystemExit("Existing fixture is busy; left untouched.")
        else:
            response = client.post(
                "/v1/sessions",
                json={
                    "title": title,
                    "workspace": str(workspace),
                    "host_id": host["host_id"],
                    "agent_id": agent["id"],
                },
            )
            response.raise_for_status()
            session_id = response.json()["id"]
        items = get(f"/v1/sessions/{session_id}/items?limit=1000")["data"]
        if not any(marker in str(item.get("content", [])) for item in items):
            response = client.post(
                f"/v1/sessions/{session_id}/events",
                json={
                    "type": "external_conversation_item",
                    "data": {
                        "item_type": "message",
                        "response_id": "native-configuration-fixture",
                        "item_data": {
                            "role": "user",
                            "content": [{"type": "input_text", "text": marker}],
                        },
                    },
                },
            )
            response.raise_for_status()
        print(f"Ready: {session_id} ({title})")
        print("Stored test data only. No model prompt was submitted. A local runner may start.")


if __name__ == "__main__":
    main()
