#!/usr/bin/env python3
"""Create/reuse a dedicated host-bound chat on the isolated loopback server."""

from pathlib import Path

import httpx


def main() -> None:
    repo = Path(__file__).resolve().parents[4]
    workspace = repo / ".native-lab-server" / "chat-workspace"
    if workspace.resolve() != workspace or not workspace.is_dir():
        raise SystemExit("Run bin/local-host.sh first; the workspace must not be a symlink.")
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
            raise SystemExit("Unexpected local server identity.")
        hosts = [host for host in get("/v1/hosts")["hosts"] if host["status"] == "online"]
        if len(hosts) != 1:
            raise SystemExit("Expected exactly one dedicated local host; run bin/local-host.sh.")
        host = hosts[0]
        if host.get("configured_harnesses", {}).get("codex-native") is not True:
            raise SystemExit("The local host does not report a configured Codex native harness.")
        agents = get("/v1/agents?limit=1000")["data"]
        agent = next((value for value in agents if value["name"] == "codex-native-ui"), None)
        if agent is None:
            raise SystemExit("Built-in codex-native-ui agent is missing.")
        sessions = get("/v1/sessions?limit=1000&search_query=Native%20live%20chat")["data"]
        for session in sessions:
            if (
                session.get("title") == "Native live chat"
                and session.get("workspace") == str(workspace)
                and session.get("host_id") == host["host_id"]
                and session.get("agent_id") == agent["id"]
            ):
                print(f"Ready: {session['id']} (Native live chat)")
                return
        response = client.post(
            "/v1/sessions",
            json={
                "agent_id": agent["id"],
                "host_id": host["host_id"],
                "workspace": str(workspace),
                "title": "Native live chat",
            },
        )
        response.raise_for_status()
        print(f"Created: {response.json()['id']} (Native live chat)")
        print("A local runner may start. No prompt was sent by this script.")


if __name__ == "__main__":
    main()
