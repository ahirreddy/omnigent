//! The Agents panel's records and the tree read over the fake host.

use omnigent_core::agent_tree as core;

use crate::agent_tree::{AgentActivity, AgentNode, AgentRole, AgentTree};
use crate::test_support::{connected, json};

#[test]
fn every_activity_and_role_maps() {
    for (on_core, on_ffi) in [
        (core::AgentActivity::Launching, AgentActivity::Launching),
        (core::AgentActivity::Working, AgentActivity::Working),
        (core::AgentActivity::NeedsYou, AgentActivity::NeedsYou),
        (core::AgentActivity::Done, AgentActivity::Done),
        (core::AgentActivity::Failed, AgentActivity::Failed),
        (
            core::AgentActivity::Disconnected,
            AgentActivity::Disconnected,
        ),
        (core::AgentActivity::Idle, AgentActivity::Idle),
        (core::AgentActivity::Other, AgentActivity::Other),
    ] {
        assert_eq!(AgentActivity::from(on_core), on_ffi);
    }
    for (on_core, on_ffi) in [
        (core::AgentRole::Explore, AgentRole::Explore),
        (core::AgentRole::Research, AgentRole::Research),
        (core::AgentRole::Plan, AgentRole::Plan),
        (core::AgentRole::Review, AgentRole::Review),
        (core::AgentRole::Test, AgentRole::Test),
        (core::AgentRole::Docs, AgentRole::Docs),
        (core::AgentRole::Code, AgentRole::Code),
        (core::AgentRole::Generic, AgentRole::Generic),
    ] {
        assert_eq!(AgentRole::from(on_core), on_ffi);
    }
}

#[test]
fn a_tree_is_read_from_its_root_with_every_field() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions/conv_b",
        json(
            200,
            r#"{"id":"conv_b","status":"idle","created_at":1,
                "parent_session_id":"conv_root","root_conversation_id":"conv_root"}"#,
        ),
    );
    harness.http.route(
        "/v1/sessions/conv_root",
        json(
            200,
            r#"{"id":"conv_root","status":"running","created_at":1,
                "harness":"claude-native","agent_name":"x"}"#,
        ),
    );
    harness.http.route(
        "/v1/sessions/conv_root/items",
        json(200, r#"{"object":"list","has_more":false,"data":[]}"#),
    );
    harness.http.route(
        "/v1/sessions/conv_root/child_sessions",
        json(
            200,
            r#"{"object":"list","data":[
              {"id":"conv_b","title":"tester:b","tool":"tester","busy":false,
               "current_task_status":"completed","last_message_preview":"All green",
               "routed_model":"claude-sonnet"},
              {"id":"conv_c","title":"researcher:c","tool":"researcher","busy":false,
               "last_task_error":{"code":"tool_error","message":"boom"}}
            ]}"#,
        ),
    );
    for leaf in ["conv_b", "conv_c"] {
        harness.http.route(
            &format!("/v1/sessions/{leaf}/child_sessions"),
            json(200, r#"{"object":"list","data":[]}"#),
        );
    }
    let tree: AgentTree = harness
        .call(|core| async move { core.agent_tree("conv_b".into()).await })
        .unwrap();
    assert_eq!(tree.root_id, "conv_root");
    assert_eq!(tree.nodes.len(), 3);
    assert_eq!(tree.nodes[0].session_id, "conv_root");
    assert_eq!(tree.nodes[0].parent_id, None);
    assert_eq!(tree.nodes[0].child_count, 2);
    assert_eq!(
        tree.nodes[1],
        AgentNode {
            session_id: "conv_b".into(),
            parent_id: Some("conv_root".into()),
            depth: 1,
            name: "b".into(),
            role: AgentRole::Test,
            activity: AgentActivity::Done,
            status_label: "Done".into(),
            status_detail: None,
            is_settled: true,
            preview: Some("All green".into()),
            routed_model: Some("claude-sonnet".into()),
            child_count: 0,
        }
    );
    assert_eq!(tree.nodes[2].activity, AgentActivity::Failed);
    assert_eq!(tree.nodes[2].status_detail.as_deref(), Some("boom"));
    assert!(!tree.nodes[2].is_settled);
    assert_eq!(tree.nodes[2].role, AgentRole::Research);

    let missing = harness.call(|core| async move { core.agent_tree("conv_gone".into()).await });
    assert!(missing.is_err());
}
