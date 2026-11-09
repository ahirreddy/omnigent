//! Side chats, plan mode and the session goal over the fake host.

use omnigent_core::session_tools as core;
use serde_json::json;

use crate::creation::FirstMessage;
use crate::session_tools::{
    GoalControl, SessionGoal, SideChatStart, codex_plan_mode, goal_command, goal_control,
    reply_quote, side_chat_start,
};
use crate::test_support::{connected, json as reply};

const GOAL: &str = r#"{"goal":{"objective":"Ship it","status":"active","token_budget":18446744073709551615,
    "tokens_used":1200,"time_used_seconds":180}}"#;

#[test]
fn starts_goal_controls_and_goals_map_each_arm() {
    assert_eq!(
        SideChatStart::from(core::SideChatStart::Command { prefix: "p".into() }),
        SideChatStart::Command { prefix: "p".into() }
    );
    assert_eq!(
        SideChatStart::from(core::SideChatStart::Draft { draft: "d".into() }),
        SideChatStart::Draft { draft: "d".into() }
    );
    assert_eq!(
        GoalControl::from(core::GoalControl::Managed),
        GoalControl::Managed
    );
    assert_eq!(
        GoalControl::from(core::GoalControl::Command {
            backend: "Codex".into()
        }),
        GoalControl::Command {
            backend: "Codex".into()
        }
    );
    let paused = SessionGoal::from(core::SessionGoal {
        objective: "o".into(),
        status: "paused".into(),
        token_budget: Some(u64::MAX),
        tokens_used: 3,
        time_used_seconds: 4,
    });
    assert_eq!(
        paused,
        SessionGoal {
            objective: "o".into(),
            status: "paused".into(),
            token_budget: Some(u64::MAX),
            tokens_used: 3,
            time_used_seconds: 4,
            can_pause: false,
            can_resume: true,
        }
    );
}

#[test]
fn the_pure_rules_are_the_cores() {
    assert!(matches!(
        side_chat_start(Some("codex-native".into()), None),
        SideChatStart::Command { .. }
    ));
    assert_eq!(
        side_chat_start(None, Some("a line".into())),
        SideChatStart::Draft {
            draft: core::reply_quote("", "a line")
        }
    );
    assert_eq!(
        codex_plan_mode(Some("codex-native-ui".into()), Some("Plan".into())),
        Some(true)
    );
    assert_eq!(codex_plan_mode(None, Some("plan".into())), None);
    assert_eq!(
        goal_control(Some("codex-native-ui".into()), None, None, None),
        Some(GoalControl::Managed)
    );
    assert_eq!(
        goal_control(None, Some("codex".into()), Some("Polly".into()), None),
        Some(GoalControl::Command {
            backend: "Codex".into()
        })
    );
    assert_eq!(
        goal_control(
            None,
            Some("codex".into()),
            Some("Polly".into()),
            Some("parent".into())
        ),
        None,
        "the parent reaches the rule"
    );
    assert_eq!(goal_command("  ".into()), None);
    assert_eq!(goal_command(" win ".into()), core::goal_command("win"));
    assert_eq!(
        reply_quote("d".into(), "s".into()),
        core::reply_quote("d", "s")
    );
}

#[test]
fn a_side_chat_forks_binds_and_sends_its_first_message() {
    let mut harness = connected();
    harness.http.route_method(
        "GET",
        "/v1/sessions/conv_a",
        reply(
            200,
            r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"harness":"claude-native",
                "runner_id":"run_1","runner_online":true,"host_id":"host_1"}"#,
        ),
    );
    let side = r#"{"id":"conv_side","status":"idle","created_at":2,"permission_level":4,
        "runner_id":"run_1","labels":{"omnigent.side_chat":"1"}}"#;
    harness
        .http
        .route_method("POST", "/v1/sessions/conv_a/fork", reply(200, side));
    harness.writable_session("conv_side");
    harness
        .http
        .route_method("PATCH", "/v1/sessions/conv_side", reply(200, side));
    let created = harness
        .call(|core| async move { core.create_side_chat("conv_a".into(), "Why?".into()).await })
        .unwrap();
    assert_eq!(created.session_id, "conv_side");
    let FirstMessage::Sent { sent } = created.first_message else {
        panic!("first message not sent: {:?}", created.first_message);
    };
    assert_eq!(sent.item_id.as_deref(), Some("i1"));
    assert_eq!(
        harness.last_request().1["data"]["content"][0]["text"],
        json!("Why?")
    );
}

#[test]
fn plan_mode_patches_the_collaboration_mode_and_reports_where_it_landed() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions/conv_a",
        reply(
            200,
            r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,
                "labels":{"omnigent.codex_native.collaboration_mode":"plan"}}"#,
        ),
    );
    assert!(
        harness
            .call(|core| async move { core.set_plan_mode("conv_a".into(), true).await })
            .unwrap()
    );
    assert_eq!(
        harness.last_request(),
        (
            "PATCH /v1/sessions/conv_a".into(),
            json!({"collaboration_mode": "plan"})
        )
    );
}

#[test]
fn the_goal_reads_sets_pauses_and_clears() {
    let mut harness = connected();
    let path = "/v1/sessions/conv_a/codex_goal";
    harness.http.route_method("GET", path, reply(200, GOAL));
    harness.http.route_method("PUT", path, reply(200, GOAL));
    harness.http.route_method(
        "PATCH",
        "/v1/sessions/conv_a/codex_goal/status",
        reply(200, &GOAL.replace("active", "paused")),
    );
    harness
        .http
        .route_method("DELETE", path, reply(200, r#"{"cleared":true}"#));
    let read = harness
        .call(|core| async move { core.session_goal("conv_a".into()).await })
        .unwrap()
        .unwrap();
    assert_eq!(
        read,
        SessionGoal {
            objective: "Ship it".into(),
            status: "active".into(),
            token_budget: Some(u64::MAX),
            tokens_used: 1200,
            time_used_seconds: 180,
            can_pause: true,
            can_resume: false,
        }
    );
    let set = harness
        .call(|core| async move {
            core.set_session_goal("conv_a".into(), " Ship it ".into(), Some(5), Some(true))
                .await
        })
        .unwrap();
    assert_eq!(set.unwrap().objective, "Ship it");
    assert_eq!(
        harness.last_request(),
        (
            format!("PUT {path}"),
            json!({"objective": "Ship it", "token_budget": 5, "status": "active"})
        )
    );
    let paused = harness
        .call(|core| async move { core.set_session_goal_active("conv_a".into(), false).await })
        .unwrap()
        .unwrap();
    assert!(paused.can_resume);
    assert_eq!(
        harness.last_request(),
        (format!("PATCH {path}/status"), json!({"status": "paused"}))
    );
    assert!(
        harness
            .call(|core| async move { core.clear_session_goal("conv_a".into()).await })
            .unwrap()
    );
    assert_eq!(harness.last_request().0, format!("DELETE {path}"));

    harness
        .http
        .route_method("GET", path, reply(200, r#"{"goal":null}"#));
    assert_eq!(
        harness
            .call(|core| async move { core.session_goal("conv_a".into()).await })
            .unwrap(),
        None
    );
}
