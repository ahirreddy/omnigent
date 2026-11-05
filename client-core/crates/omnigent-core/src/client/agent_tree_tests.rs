//! The Agents panel's spawn tree (web `useChildSessions`, `childStatus`, `childPrimaryLabel`,
//! `SubagentsPanel`).

use futures::executor::block_on;
use serde_json::{Value, json};

use super::*;
use crate::client::test_support::{Reply, RouteTransport, connected};

fn row(fields: &Value) -> ChildSessionRow {
    let mut value = json!({"id": "conv_c", "busy": false});
    if let (Some(value), Some(fields)) = (value.as_object_mut(), fields.as_object()) {
        value.extend(fields.clone());
    }
    decode_child(&value).expect("a child row")
}

fn snapshot(id: &str, fields: &Value) -> String {
    let mut session = json!({"id": id, "status": "idle", "created_at": 1});
    if let (Some(session), Some(fields)) = (session.as_object_mut(), fields.as_object()) {
        session.extend(fields.clone());
    }
    session.to_string()
}

fn children(rows: &Value) -> Reply {
    Reply::json(200, json!({"object": "list", "data": rows}).to_string())
}

fn respond(transport: &RouteTransport, path: &str, reply: Reply) {
    transport.respond(Some("GET"), path, None, reply);
}

#[test]
fn a_pending_request_outranks_busy_and_a_disconnect_is_not_a_failure() {
    let waiting = row(&json!({"busy": true, "pending_elicitations_count": 2}));
    assert_eq!(waiting.status().activity, AgentActivity::NeedsYou);
    assert_eq!(waiting.status().label, "Needs you");
    assert_eq!(
        row(&json!({"busy": true, "current_task_status": "launching"}))
            .status()
            .activity,
        AgentActivity::Launching
    );
    assert_eq!(
        row(&json!({"busy": true})).status().activity,
        AgentActivity::Working
    );
    let gone = row(&json!({"current_task_status": "failed", "last_task_error":
        {"code": "runner_disconnected", "message": "\n  tunnel closed\nretrying"}}));
    assert_eq!(
        gone.status(),
        AgentStatus {
            activity: AgentActivity::Disconnected,
            label: "Disconnected".into(),
            detail: Some("tunnel closed".into()),
        }
    );
    let failed = row(&json!({"last_task_error": {"code": "tool_error", "message": "boom"}}));
    assert_eq!(failed.status().activity, AgentActivity::Failed);
    assert_eq!(failed.status().detail.as_deref(), Some("boom"));
    let statuses = [
        ("completed", AgentActivity::Done, "Done"),
        ("failed", AgentActivity::Failed, "Failed"),
        ("cancelled", AgentActivity::Other, "cancelled"),
    ];
    for (task, activity, label) in statuses {
        let status = row(&json!({"current_task_status": task})).status();
        assert_eq!((status.activity, status.label.as_str()), (activity, label));
    }
    assert_eq!(row(&json!({})).status().activity, AgentActivity::Idle);
    assert!(AgentActivity::Done.is_settled() && !AgentActivity::Failed.is_settled());
}

#[test]
fn names_prefer_the_task_and_native_sub_agents_use_their_type() {
    let spawned = row(&json!({"title": "researcher:auth", "tool": "researcher",
        "session_name": "auth", "task_summary": "Investigate auth flow"}));
    assert_eq!(spawned.display_name(), "Investigate auth flow");
    assert_eq!(
        row(&json!({"title": "researcher:a:b"})).display_name(),
        "a:b"
    );
    assert_eq!(row(&json!({"title": "plain"})).display_name(), "plain");
    assert_eq!(row(&json!({})).display_name(), "conv_c");
    let codex = row(
        &json!({"title": "codex-native-ui-subagent:0f9a", "tool": "Archimedes",
        "labels": {"omnigent.wrapper": "codex-native-ui-subagent",
            "omnigent.codex_native.agent_role": "explorer"}}),
    );
    assert_eq!(codex.display_name(), "Archimedes");
    assert_eq!(codex.role(), AgentRole::Explore);
    // A user-added agent keeps its given name even under a native wrapper.
    let added = row(&json!({"title": "ui:codex:helper", "tool": "codex",
        "session_name": "helper", "labels": {"omnigent.wrapper": "codex-native-ui-subagent"}}));
    assert_eq!(added.display_name(), "helper");
}

#[test]
fn roles_follow_the_agent_type() {
    let roles = [
        ("Explore", AgentRole::Explore),
        ("deep-researcher", AgentRole::Research),
        ("architect", AgentRole::Plan),
        ("code-reviewer", AgentRole::Review),
        ("tester", AgentRole::Test),
        ("doc_writer", AgentRole::Docs),
        ("frontend", AgentRole::Code),
        ("polly", AgentRole::Generic),
    ];
    for (kind, role) in roles {
        assert_eq!(AgentRole::of(Some(kind)), role, "{kind}");
    }
    assert_eq!(AgentRole::of(None), AgentRole::Generic);
}

#[test]
fn malformed_child_lists_are_errors_not_empty_trees() {
    assert!(decode_child_sessions(&json!({"object": "list"})).is_err());
    assert!(decode_child_sessions(&json!({"data": [{"title": "x"}]})).is_err());
    assert!(decode_child_sessions(&json!({"data": [{"id": "c", "title": 3}]})).is_err());
    let rows = decode_child_sessions(&json!({"data": [{"id": "c", "busy": true,
        "last_task_error": {"code": "", "message": "x"}, "routed_model": ""}]}))
    .expect("rows");
    assert_eq!(rows[0].last_task_error, None);
    assert_eq!(rows[0].routed_model, None);
}

/// A root with a researcher (which has one sub-agent) and a tester, read from the tester.
fn two_level_tree() -> RouteTransport {
    let transport = RouteTransport::local();
    respond(
        &transport,
        "/v1/sessions/conv_b",
        Reply::json(
            200,
            snapshot(
                "conv_b",
                &json!({"parent_session_id": "conv_root", "root_conversation_id": "conv_root"}),
            ),
        ),
    );
    respond(
        &transport,
        "/v1/sessions/conv_root",
        Reply::json(
            200,
            snapshot(
                "conv_root",
                &json!({"status": "running", "harness": "claude-native", "agent_name": "x"}),
            ),
        ),
    );
    respond(
        &transport,
        "/v1/sessions/conv_root/items",
        Reply::json(
            200,
            json!({"object": "list", "has_more": false, "data": [
                {"id": "i2", "type": "message", "role": "assistant",
                    "content": [{"type": "output_text", "text": "  Done with it  "}]},
                {"id": "i1", "type": "message", "role": "user",
                    "content": [{"type": "input_text", "text": "go"}]}]})
            .to_string(),
        ),
    );
    respond(
        &transport,
        "/v1/sessions/conv_root/child_sessions",
        children(&json!([
            {"id": "conv_a", "title": "researcher:a", "tool": "researcher", "busy": true},
            {"id": "conv_b", "title": "tester:b", "tool": "tester", "busy": false,
                "current_task_status": "completed", "last_message_preview": "All green",
                "routed_model": "claude-sonnet"}])),
    );
    respond(
        &transport,
        "/v1/sessions/conv_a/child_sessions",
        children(
            &json!([{"id": "conv_a1", "title": "Explore:x", "tool": "Explore", "busy": false,
            "pending_elicitations_count": 1}]),
        ),
    );
    for leaf in ["conv_b", "conv_a1"] {
        respond(
            &transport,
            &format!("/v1/sessions/{leaf}/child_sessions"),
            children(&json!([])),
        );
    }
    transport
}

#[test]
fn a_sub_agents_tree_is_read_from_its_root_depth_first() {
    let core = connected(two_level_tree());
    let tree = block_on(core.agent_tree("conv_b")).expect("tree");
    assert_eq!(tree.root_id, "conv_root");
    assert_eq!(tree.subagent_count(), 3);
    let shape: Vec<(&str, Option<&str>, u32, u32)> = tree
        .nodes
        .iter()
        .map(|node| {
            (
                node.session_id.as_str(),
                node.parent_id.as_deref(),
                node.depth,
                node.child_count,
            )
        })
        .collect();
    assert_eq!(
        shape,
        [
            ("conv_root", None, 0, 2),
            ("conv_a", Some("conv_root"), 1, 1),
            ("conv_a1", Some("conv_a"), 2, 0),
            ("conv_b", Some("conv_root"), 1, 0),
        ]
    );
    let root = &tree.nodes[0];
    assert_eq!(root.name, "Claude Code");
    assert_eq!(root.status.activity, AgentActivity::Working);
    assert_eq!(root.preview.as_deref(), Some("Done with it"));
    assert_eq!(tree.nodes[2].status.activity, AgentActivity::NeedsYou);
    assert_eq!(tree.nodes[2].role, AgentRole::Explore);
    assert_eq!(tree.nodes[3].routed_model.as_deref(), Some("claude-sonnet"));
}

#[test]
fn an_older_server_without_a_root_id_walks_the_parent_chain() {
    let transport = RouteTransport::local();
    respond(
        &transport,
        "/v1/sessions/conv_c",
        Reply::json(
            200,
            snapshot("conv_c", &json!({"parent_session_id": "conv_p"})),
        ),
    );
    respond(
        &transport,
        "/v1/sessions/conv_p",
        Reply::json(
            200,
            snapshot(
                "conv_p",
                &json!({"agent_name": "polly", "status": "failed",
                "last_task_error": {"code": "runner_process_crash", "message": "exited"}}),
            ),
        ),
    );
    respond(
        &transport,
        "/v1/sessions/conv_p/items",
        Reply::json(200, r#"{"object":"list","data":[],"has_more":false}"#),
    );
    respond(
        &transport,
        "/v1/sessions/conv_p/child_sessions",
        children(&json!([])),
    );
    let tree = block_on(connected(transport).agent_tree("conv_c")).expect("tree");
    assert_eq!(tree.root_id, "conv_p");
    assert_eq!(tree.nodes[0].name, "polly");
    assert_eq!(tree.nodes[0].status.activity, AgentActivity::Disconnected);
    assert_eq!(tree.nodes[0].preview, None);
}
