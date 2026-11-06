//! Side chats, plan mode and the session goal (web `createSideChat`, `setCodexPlanMode`,
//! `codexGoalApi`).

use futures::executor::block_on;
use serde_json::{Value, json};

use std::collections::BTreeMap;

use super::*;
use crate::client::ClientEvent;
use crate::client::test_support::{Reply, RouteTransport, body_json, connected, path_of, record};

const SESSION: &str = "/v1/sessions/conv_a";

fn session(fields: &Value) -> String {
    let mut session = json!({"id": "conv_a", "status": "idle", "created_at": 1,
        "permission_level": 4, "harness": "claude-native"});
    if let (Some(session), Some(fields)) = (session.as_object_mut(), fields.as_object()) {
        session.extend(fields.clone());
    }
    session.to_string()
}

fn side_chat_transport(source: &Value) -> RouteTransport {
    let transport = RouteTransport::local();
    transport.respond(
        Some("GET"),
        SESSION,
        None,
        Reply::json(200, session(source)),
    );
    let side = r#"{"id":"conv_side","status":"idle","created_at":2,"permission_level":4,
        "runner_id":"run_1","labels":{"omnigent.side_chat":"1"}}"#;
    transport.respond(
        Some("POST"),
        "/v1/sessions/conv_a/fork",
        None,
        Reply::json(200, side),
    );
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/conv_side",
        None,
        Reply::json(200, side),
    );
    transport.respond(
        Some("GET"),
        "/v1/sessions/conv_side",
        None,
        Reply::json(200, side),
    );
    transport.respond(
        Some("POST"),
        "/v1/sessions/conv_side/events",
        None,
        Reply::json(202, r#"{"queued":true,"item_id":"item_1"}"#),
    );
    transport
}

#[test]
fn a_side_chat_forks_on_its_first_message_and_binds_the_parents_runner() {
    let core = connected(side_chat_transport(
        &json!({"runner_id": "run_1", "runner_online": true, "host_id": "host_1"}),
    ));
    let created = block_on(core.create_side_chat("conv_a", "Why?")).unwrap();
    assert_eq!(created.session_id, "conv_side");
    let FirstMessage::Sent(sent) = created.first_message else {
        panic!("first message not sent");
    };
    assert_eq!(sent.submission.item_id.as_deref(), Some("item_1"));
    let writes = core.transport().writes();
    let paths: Vec<String> = writes.iter().map(path_of).collect();
    assert_eq!(
        paths,
        [
            "/v1/sessions/conv_a/fork",
            "/v1/sessions/conv_side",
            "/v1/sessions/conv_side/events"
        ]
    );
    assert_eq!(
        body_json(&writes[0]),
        json!({"title": "Side chat", "side_chat": true})
    );
    assert_eq!(body_json(&writes[1]), json!({"runner_id": "run_1"}));
    assert_eq!(body_json(&writes[2])["data"]["content"][0]["text"], "Why?");
}

#[test]
fn a_blank_first_message_creates_nothing() {
    let core = connected(side_chat_transport(
        &json!({"runner_id": "run_1", "runner_online": true, "host_id": "host_1"}),
    ));
    assert_eq!(
        block_on(core.create_side_chat("conv_a", "  \n")),
        Err(SessionError::EmptyMessage)
    );
    assert_eq!(core.transport().writes(), []);
}

#[test]
fn a_failed_first_message_still_returns_the_side_chat() {
    let transport = side_chat_transport(
        &json!({"runner_id": "run_1", "runner_online": true, "host_id": "host_1"}),
    );
    transport.respond(
        Some("POST"),
        "/v1/sessions/conv_side/events",
        None,
        Reply::json(500, "{}"),
    );
    let core = connected(transport);
    let created = block_on(core.create_side_chat("conv_a", "Why?")).unwrap();
    assert_eq!(created.session_id, "conv_side");
    assert!(matches!(created.first_message, FirstMessage::Failed(_)));
}

#[test]
fn a_stopped_runner_is_relaunched_and_a_lost_one_refuses() {
    let core = connected(side_chat_transport(
        &json!({"runner_online": false, "host_id": "host_1", "host_online": true}),
    ));
    core.transport().respond(
        Some("POST"),
        "/v1/sessions/conv_a/events",
        None,
        Reply::json(200, r#"{"recovered":true}"#),
    );
    // The relaunch did not bring the runner back: nothing is forked.
    assert!(matches!(
        block_on(core.create_side_chat("conv_a", "Why?")),
        Err(SessionError::ExecutionUnavailable { .. })
    ));
    let writes = core.transport().writes();
    assert_eq!(writes.len(), 1);
    assert_eq!(
        body_json(&writes[0]),
        json!({"type": "retry_session", "data": {}})
    );
}

#[test]
fn side_chats_start_as_drafts_and_codex_native_ones_from_the_command() {
    assert_eq!(
        side_chat_start(Some("claude-native"), None),
        SideChatStart::Draft {
            draft: String::new()
        }
    );
    assert_eq!(
        side_chat_start(Some("codex-native"), None),
        SideChatStart::Command {
            prefix: SIDE_CHAT_COMMAND_PREFIX.into()
        }
    );
}

#[test]
fn a_side_chat_names_its_source_from_its_labels() {
    let labels = |pairs: &[(&str, &str)]| -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    };
    assert_eq!(
        side_chat_source_id(&labels(&[(SIDE_CHAT_SOURCE_LABEL, "conv_a")])),
        Some("conv_a")
    );
    let forked = labels(&[
        (SIDE_CHAT_LABEL, "1"),
        ("omnigent.fork.source_id", "conv_b"),
    ]);
    assert_eq!(side_chat_source_id(&forked), Some("conv_b"));
    // An ordinary fork is not a side chat.
    assert_eq!(
        side_chat_source_id(&labels(&[("omnigent.fork.source_id", "conv_b")])),
        None
    );
    assert_eq!(
        side_chat_inherited_before(Some(&forked), Some("claude-native"), 7),
        Some(7)
    );
    assert_eq!(
        side_chat_inherited_before(Some(&forked), Some("codex-native"), 7),
        None
    );
    assert_eq!(side_chat_inherited_before(None, None, 7), None);
}

#[test]
fn a_side_chat_from_the_updates_stream_stays_out_of_the_list() {
    let core = connected(RouteTransport::local());
    let row = |id: &str, labels: Value| {
        json!({"id": id, "agent_id": "agent", "status": "idle", "created_at": 1,
            "updated_at": 2, "title": "Side chat", "labels": labels})
    };
    let recorder = record(&core);
    core.apply_session_rows(vec![
        row(
            "conv_side",
            json!({SIDE_CHAT_LABEL: "1", SIDE_CHAT_SOURCE_LABEL: "conv_a"}),
        ),
        row("conv_fork", json!({"omnigent.fork.source_id": "conv_a"})),
    ])
    .unwrap();
    // A later row without its labels (a status update) still stays out.
    core.apply_session_rows(vec![row("conv_side", Value::Null)])
        .unwrap();
    let listed: Vec<String> = recorder
        .take()
        .into_iter()
        .filter_map(|event| match event {
            ClientEvent::SessionsChanged { sessions } => Some(sessions),
            _ => None,
        })
        .flatten()
        .map(|summary| summary.id)
        .collect();
    assert_eq!(listed, ["conv_fork"]);
}

#[test]
fn plan_mode_applies_to_codex_native_and_reports_where_it_landed() {
    assert_eq!(
        codex_plan_mode(Some("codex-native-ui"), Some("Plan")),
        Some(true)
    );
    assert_eq!(codex_plan_mode(Some("codex-native-ui"), None), Some(false));
    assert_eq!(
        codex_plan_mode(Some("claude-native-ui"), Some("plan")),
        None
    );

    let transport = RouteTransport::local();
    let labels = json!({"labels": {"omnigent.codex_native.collaboration_mode": "plan"}});
    transport.respond(
        Some("PATCH"),
        SESSION,
        None,
        Reply::json(200, session(&labels)),
    );
    let core = connected(transport);
    assert_eq!(block_on(core.set_plan_mode("conv_a", true)), Ok(true));
    let writes = core.transport().writes();
    assert_eq!(body_json(&writes[0]), json!({"collaboration_mode": "plan"}));
}

#[test]
fn goal_control_follows_the_harness() {
    assert_eq!(
        goal_control(Some("codex-native-ui"), Some("codex-native"), None, None),
        Some(GoalControl::Managed)
    );
    assert_eq!(
        goal_control(None, Some("claude-sdk"), Some("Polly"), None),
        Some(GoalControl::Command {
            backend: "Claude".into()
        })
    );
    assert_eq!(
        goal_control(None, Some("codex"), Some("polly"), Some("conv_parent")),
        None
    );
    assert_eq!(
        goal_control(None, Some("claude-sdk"), Some("other"), None),
        None
    );
    assert_eq!(goal_command(" ship it "), Some("/goal ship it".into()));
    assert_eq!(goal_command("  "), None);
}

#[test]
fn the_goal_reads_sets_pauses_and_clears() {
    let transport = RouteTransport::local();
    let goal = r#"{"goal":{"thread_id":"t","objective":"Ship it","status":"active",
        "token_budget":40000,"tokens_used":1200,"time_used_seconds":180}}"#;
    transport.respond(
        Some("GET"),
        "/v1/sessions/conv_a/codex_goal",
        None,
        Reply::json(200, goal),
    );
    transport.respond(
        Some("PUT"),
        "/v1/sessions/conv_a/codex_goal",
        None,
        Reply::json(200, goal),
    );
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/conv_a/codex_goal/status",
        None,
        Reply::json(200, goal.replace("active", "paused")),
    );
    transport.respond(
        Some("DELETE"),
        "/v1/sessions/conv_a/codex_goal",
        None,
        Reply::json(200, r#"{"cleared":true}"#),
    );
    let core = connected(transport);
    let read = block_on(core.session_goal("conv_a")).unwrap().unwrap();
    assert_eq!(
        read,
        SessionGoal {
            objective: "Ship it".into(),
            status: "active".into(),
            token_budget: Some(40_000),
            tokens_used: 1_200,
            time_used_seconds: 180,
        }
    );
    assert!(read.can_pause() && !read.can_resume());
    assert_eq!(
        block_on(core.set_session_goal("conv_a", "  ", None, None)),
        Err(SessionError::EmptyMessage)
    );
    block_on(core.set_session_goal("conv_a", " Ship it ", None, Some(true))).unwrap();
    let paused = block_on(core.set_session_goal_active("conv_a", false))
        .unwrap()
        .unwrap();
    assert!(paused.can_resume());
    assert_eq!(block_on(core.clear_session_goal("conv_a")), Ok(true));
    let writes = core.transport().writes();
    assert_eq!(
        body_json(&writes[0]),
        json!({"objective": "Ship it", "token_budget": null, "status": "active"})
    );
    assert_eq!(body_json(&writes[1]), json!({"status": "paused"}));
    assert_eq!(writes[2].method, "DELETE");
}

#[test]
fn no_goal_reads_as_none() {
    let transport = RouteTransport::local();
    transport.ok("/v1/sessions/conv_a/codex_goal", r#"{"goal":null}"#);
    let core = connected(transport);
    assert_eq!(block_on(core.session_goal("conv_a")), Ok(None));
}

#[test]
fn a_reply_quote_follows_the_draft_after_a_blank_line() {
    assert_eq!(reply_quote("", "one\r\ntwo\n"), "> one\n> two\n\n");
    assert_eq!(reply_quote("Look:", "x"), "Look:\n\n> x\n\n");
    assert_eq!(reply_quote("Look:\n", "x"), "Look:\n\n> x\n\n");
    assert_eq!(reply_quote("> a\n\n", "b"), "> a\n\n> b\n\n");
    assert_eq!(reply_quote("keep", "  \n "), "keep");
}

#[test]
fn a_quoted_side_chat_starts_with_the_quote_as_its_draft() {
    assert_eq!(
        side_chat_start(Some("claude-native"), Some("why this?")),
        SideChatStart::Draft {
            draft: "> why this?\n\n".into()
        }
    );
    assert_eq!(
        side_chat_start(Some("codex-native"), Some("why this?")),
        SideChatStart::Command {
            prefix: "/side > why this?\n\n".into()
        }
    );
}
