//! Side chats, plan mode and the session goal (web `createSideChat`, `setCodexPlanMode`,
//! `codexGoalApi`).

use futures::executor::block_on;
use serde_json::{Value, json};

use std::collections::BTreeMap;

use super::*;
use crate::client::ClientEvent;
use crate::client::test_support::{
    Reply, RouteTransport, body_json, connected, header, lines_after_connect, live, path_of, record,
};

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
fn a_side_chats_first_message_is_checked_against_the_row_its_binding_returned() {
    let row = |runner_id: &Value, runner_online: bool| {
        let body = json!({"id": "conv_side", "status": "idle", "created_at": 2,
            "permission_level": 4, "runner_id": runner_id, "runner_online": runner_online});
        Reply::json(200, body.to_string())
    };
    let bind = |core: &ClientCore<RouteTransport>, reply: Reply| {
        core.transport()
            .respond(Some("PATCH"), "/v1/sessions/conv_side", None, reply);
    };
    let transport = side_chat_transport(&json!({"runner_id": "run_1", "runner_online": true}));
    // The fork answers before its runner is bound: that row alone would refuse the message.
    transport.respond(
        Some("POST"),
        "/v1/sessions/conv_a/fork",
        None,
        row(&Value::Null, false),
    );
    let core = connected(transport);
    bind(&core, row(&json!("run_1"), true));
    let created = block_on(core.create_side_chat("conv_a", "Why?")).unwrap();
    assert!(matches!(created.first_message, FirstMessage::Sent(_)));
    assert_eq!(
        lines_after_connect(&core),
        [
            "GET /v1/sessions/conv_a",
            "POST /v1/sessions/conv_a/fork",
            "PATCH /v1/sessions/conv_side",
            "POST /v1/sessions/conv_side/events"
        ]
    );

    // A binding the server answers as still unbound refuses the message without sending it.
    bind(&core, row(&Value::Null, false));
    let created = block_on(core.create_side_chat("conv_a", "Why?")).unwrap();
    assert!(matches!(
        created.first_message,
        FirstMessage::Failed(SessionError::ExecutionUnavailable { .. })
    ));
    assert_eq!(lines_after_connect(&core).len(), 7);

    bind(&core, Reply::json(200, r#"{"id":7}"#));
    let outcome = block_on(core.create_side_chat("conv_a", "Why?"));
    assert!(
        matches!(&outcome, Err(SessionError::DeliveryUncertain { detail })
            if detail.contains("acknowledgement")),
        "{outcome:?}"
    );
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
fn every_side_chat_starts_as_a_draft_and_codex_native_delivers_through_the_parent() {
    assert_eq!(
        side_chat_start(Some("claude-native"), None),
        SideChatStart {
            draft: String::new(),
            delivery: SideChatDelivery::ForkThenSend,
        }
    );
    assert_eq!(
        side_chat_start(Some("codex-native"), None),
        SideChatStart {
            draft: String::new(),
            delivery: SideChatDelivery::SendToParent {
                prefix: SIDE_CHAT_COMMAND_PREFIX.into()
            },
        }
    );
    for harness in [Some("claude-sdk"), Some("codex"), Some("pi-native"), None] {
        assert_eq!(
            side_chat_start(harness, None).delivery,
            SideChatDelivery::ForkThenSend,
            "{harness:?}"
        );
    }
}

const PARENT_EVENTS: &str = "/v1/sessions/conv_a/events";

fn codex_parent() -> RouteTransport {
    let transport = RouteTransport::local();
    transport.respond(
        Some("POST"),
        PARENT_EVENTS,
        None,
        Reply::json(202, r#"{"queued":true}"#),
    );
    transport
}

#[test]
fn a_codex_side_chat_asks_the_parents_agent_to_fork_with_the_side_command() {
    let core = live(codex_parent());
    core.update_composer("conv_a", "A draft in the main chat")
        .unwrap();
    let started =
        block_on(core.start_side_chat("conv_a", Some("codex-native"), "Why is it slow?")).unwrap();
    assert_eq!(started, StartedSideChat::AwaitingFork);
    // One message to the parent: no fork route, no read, and nothing sent to another session.
    assert_eq!(
        lines_after_connect(&core),
        [format!("POST {PARENT_EVENTS}")]
    );
    let writes = core.transport().writes();
    assert_eq!(
        body_json(&writes[0]),
        json!({"type": "message", "data": {"role": "user", "content": [
            {"type": "input_text", "text": "/side Why is it slow?"}
        ]}})
    );
    // Refused rather than recorded while the host is offline, like a typed message.
    assert_eq!(
        header(&writes[0], "x-omnigent-hold-when-host-offline"),
        Some("on")
    );
    // It is not the main composer's message: its draft stays and its next send is not held.
    assert_eq!(
        core.composer_text("conv_a").unwrap(),
        "A draft in the main chat"
    );
    assert_eq!(core.is_send_blocked("conv_a"), Ok(false));
}

#[test]
fn a_codex_side_chat_goes_out_while_the_main_composer_has_an_unreviewed_send() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "POST",
        PARENT_EVENTS,
        vec![
            Reply::json(200, "not json"),
            Reply::json(202, r#"{"queued":true}"#),
        ],
    );
    let core = live(transport);
    assert!(matches!(
        block_on(core.send_message("conv_a", "Hello")),
        Err(SessionError::DeliveryUncertain { .. })
    ));
    assert_eq!(core.is_send_blocked("conv_a"), Ok(true));
    assert_eq!(
        block_on(core.start_side_chat("conv_a", Some("codex-native"), "Why?")),
        Ok(StartedSideChat::AwaitingFork)
    );
    assert_eq!(core.is_send_blocked("conv_a"), Ok(true));
}

#[test]
fn a_codex_side_chat_that_cannot_be_asked_for_says_why_and_forks_nothing() {
    // Blank: no request.
    let core = live(codex_parent());
    assert_eq!(
        block_on(core.start_side_chat("conv_a", Some("codex-native"), " \n")),
        Err(SessionError::EmptyMessage)
    );
    assert_eq!(lines_after_connect(&core), Vec::<String>::new());
    // The parent's stream is not live, so its fork could never be seen: no request.
    let core = connected(codex_parent());
    assert_eq!(
        block_on(core.start_side_chat("conv_a", Some("codex-native"), "Why?")),
        Err(SessionError::StreamNotReady)
    );
    assert_eq!(lines_after_connect(&core), Vec::<String>::new());
    // The server refuses a host too old to fork, in its own words.
    let transport = RouteTransport::local();
    transport.respond(
        Some("POST"),
        PARENT_EVENTS,
        None,
        Reply::json(
            400,
            r#"{"error":{"code":"invalid_input","message":"This session's host is too old to open a Codex side chat."}}"#,
        ),
    );
    let core = live(transport);
    let refused = block_on(core.start_side_chat("conv_a", Some("codex-native"), "Why?"));
    let Err(SessionError::Rejected { message, .. }) = &refused else {
        panic!("not refused: {refused:?}");
    };
    assert!(message.contains("too old"), "{message}");
    assert_eq!(core.is_send_blocked("conv_a"), Ok(false));
    // A viewer who is not the owner is refused as read-only.
    let transport = RouteTransport::local();
    transport.respond(Some("POST"), PARENT_EVENTS, None, Reply::json(403, "{}"));
    assert_eq!(
        block_on(live(transport).start_side_chat("conv_a", Some("codex-native"), "Why?")),
        Err(SessionError::ReadOnly)
    );
    // A policy denial is the server's `denied` acknowledgement.
    let transport = RouteTransport::local();
    transport.respond(
        Some("POST"),
        PARENT_EVENTS,
        None,
        Reply::json(200, r#"{"queued":false,"denied":true,"reason":"No."}"#),
    );
    assert_eq!(
        block_on(live(transport).start_side_chat("conv_a", Some("codex-native"), "Why?")),
        Err(SessionError::MessageDenied {
            reason: Some("No.".into())
        })
    );
}

#[test]
fn other_harnesses_start_a_side_chat_by_forking_on_the_server() {
    let core = connected(side_chat_transport(
        &json!({"runner_id": "run_1", "runner_online": true, "host_id": "host_1"}),
    ));
    let started = block_on(core.start_side_chat("conv_a", Some("claude-native"), "Why?")).unwrap();
    let StartedSideChat::Created(created) = started else {
        panic!("not forked on the server: {started:?}");
    };
    assert_eq!(created.session_id, "conv_side");
    let writes = core.transport().writes();
    assert_eq!(path_of(&writes[0]), "/v1/sessions/conv_a/fork");
    assert_eq!(
        body_json(&writes[0]),
        json!({"title": "Side chat", "side_chat": true})
    );
    // The question goes to the fork as typed, never to the parent.
    assert_eq!(path_of(&writes[2]), "/v1/sessions/conv_side/events");
    assert_eq!(
        body_json(&writes[2])["data"]["content"][0]["text"],
        json!("Why?")
    );
}

#[test]
fn only_a_message_the_agent_forks_from_is_a_side_chat_command() {
    let codex = Some("codex-native");
    assert!(message_forks_side_chat(codex, "/side why?"));
    assert!(message_forks_side_chat(codex, "  \n/side   why?\n"));
    // The command needs its space and a question, as the server's parser does.
    assert!(!message_forks_side_chat(codex, "/side"));
    assert!(!message_forks_side_chat(codex, "/side   "));
    assert!(!message_forks_side_chat(codex, "/sidebar why?"));
    assert!(!message_forks_side_chat(codex, "ask /side why?"));
    // Other harnesses take the text as an ordinary message.
    assert!(!message_forks_side_chat(
        Some("claude-native"),
        "/side why?"
    ));
    assert!(!message_forks_side_chat(None, "/side why?"));
}

#[test]
fn side_chats_are_offered_where_the_server_allows_or_else_to_the_owner() {
    let harness = Some("claude-native");
    assert!(offers_side_chat(harness, Some(true), Some(1)));
    assert!(!offers_side_chat(harness, Some(false), Some(4)));
    // A server that does not say leaves it to the viewer's level; no level is single-user.
    assert!(offers_side_chat(harness, None, Some(4)));
    assert!(!offers_side_chat(harness, None, Some(3)));
    assert!(offers_side_chat(harness, None, None));
    // A session whose harness is not known yet offers none.
    assert!(!offers_side_chat(None, Some(true), Some(4)));
    assert!(!offers_side_chat(Some(""), Some(true), Some(4)));
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
fn a_side_chat_is_told_from_a_sub_agent_by_its_labels() {
    let side_chat = |pairs: &[(&str, &str)]| {
        let labels: BTreeMap<&str, &str> = pairs.iter().copied().collect();
        is_side_chat(|key| labels.get(key).copied())
    };
    // Codex lists its `/side` fork as a sub-agent named "Side chat".
    let nickname = "omnigent.codex_native.agent_nickname";
    assert!(side_chat(&[
        ("omnigent.wrapper", "codex-native-ui-subagent"),
        (nickname, "Side chat"),
    ]));
    assert!(side_chat(&[(SIDE_CHAT_SOURCE_LABEL, "conv_a")]));
    assert!(side_chat(&[(SIDE_CHAT_LABEL, "1")]));
    // Other Codex sub-agents, and labels that name no source, are not side chats.
    assert!(!side_chat(&[(nickname, "Euclid")]));
    assert!(!side_chat(&[(SIDE_CHAT_SOURCE_LABEL, "")]));
    assert!(!side_chat(&[(SIDE_CHAT_LABEL, "0")]));
    assert!(!side_chat(&[]));
}

/// One row this client cannot read must not hide the other sessions in the same frame.
#[test]
fn an_unreadable_row_leaves_the_rest_of_its_frame_applied() {
    let core = connected(RouteTransport::local());
    let row = |id: &str, status: &str| {
        json!({"id": id, "agent_id": "agent", "status": status, "created_at": 1,
            "updated_at": 2, "title": id})
    };
    let recorder = record(&core);
    let error = core
        .apply_session_rows(vec![
            row("conv_first", "idle"),
            row("conv_future", "from-the-future"),
            json!({"id": "conv_broken", "created_at": "yesterday"}),
            row("conv_last", "running"),
        ])
        .unwrap_err();
    assert!(
        matches!(&error, SessionError::MalformedResponse { detail }
            if detail.contains("unknown session status")),
        "{error:?}"
    );
    let listed: Vec<String> = recorder
        .take()
        .into_iter()
        .find_map(|event| match event {
            ClientEvent::SessionsChanged { sessions } => Some(sessions),
            _ => None,
        })
        .unwrap()
        .into_iter()
        .map(|session| session.id)
        .collect();
    assert_eq!(listed, ["conv_first", "conv_last"]);

    // A frame of nothing readable reports no change at all.
    assert!(core.apply_session_rows(vec![json!({"id": 7})]).is_err());
    assert_eq!(recorder.take(), []);
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
    assert_eq!(
        goal_control(None, Some("pi-native"), Some("polly"), None),
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
fn a_quoted_side_chat_starts_with_the_quote_as_its_draft_on_every_harness() {
    for harness in ["claude-native", "codex-native"] {
        assert_eq!(
            side_chat_start(Some(harness), Some("why this?")).draft,
            "> why this?\n\n",
            "{harness}"
        );
    }
}

#[test]
fn goal_replies_that_cannot_be_read_are_reported_by_their_route() {
    let transport = RouteTransport::local();
    let path = "/v1/sessions/conv_a/codex_goal";
    let bad =
        r#"{"goal":{"thread_id":"t","objective":"x","status":"active","token_budget":"many"}}"#;
    for (method, reply) in [("GET", bad), ("PUT", bad), ("DELETE", "{}")] {
        transport.respond(Some(method), path, None, Reply::json(200, reply));
    }
    transport.respond(Some("DELETE"), path, None, Reply::json(200, "{}"));
    let core = connected(transport);
    assert!(matches!(
        block_on(core.session_goal("conv_a")),
        Err(SessionError::MalformedResponse { detail }) if detail.contains("codex_goal")
    ));
    assert!(matches!(
        block_on(core.set_session_goal("conv_a", "x", None, None)),
        Err(SessionError::DeliveryUncertain { detail }) if detail.contains("acknowledgement")
    ));
    assert!(matches!(
        block_on(core.clear_session_goal("conv_a")),
        Err(SessionError::DeliveryUncertain { detail }) if detail.contains("`cleared`")
    ));
}

#[test]
fn a_goal_with_null_counts_reads_as_unset() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("GET"),
        "/v1/sessions/conv_a/codex_goal",
        None,
        Reply::json(
            200,
            r#"{"goal":{"thread_id":"t","objective":"x","status":"active","token_budget":null}}"#,
        ),
    );
    let core = connected(transport);
    let goal = block_on(core.session_goal("conv_a")).unwrap().unwrap();
    assert_eq!(goal.token_budget, None);
}

#[test]
fn an_unreadable_plan_mode_acknowledgement_is_uncertain_not_failed() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("PATCH"),
        SESSION,
        None,
        Reply::json(200, r#"{"id": 5}"#),
    );
    let core = connected(transport);
    assert!(matches!(
        block_on(core.set_plan_mode("conv_a", true)),
        Err(SessionError::DeliveryUncertain { detail }) if detail.contains("acknowledgement")
    ));
}

#[test]
fn a_side_chat_without_a_runner_binds_nothing_and_a_resumable_offline_host_relaunches() {
    let core = connected(side_chat_transport(&json!({"runner_online": true})));
    block_on(core.create_side_chat("conv_a", "Why?")).unwrap();
    assert!(
        !core
            .transport()
            .writes()
            .iter()
            .any(|request| request.method == "PATCH"),
        "no runner to bind"
    );

    let core = connected(side_chat_transport(&json!({
        "runner_id": "run_1", "runner_online": false, "host_id": "host_1",
        "host_online": false, "host_resumable": true,
    })));
    core.transport().respond(
        Some("POST"),
        "/v1/sessions/conv_a/events",
        None,
        Reply::json(200, r#"{"recovered":true}"#),
    );
    assert!(block_on(core.create_side_chat("conv_a", "Why?")).is_err());
    assert_eq!(
        core.transport().write_bodies(),
        vec![json!({"type": "retry_session", "data": {}})]
    );
}
