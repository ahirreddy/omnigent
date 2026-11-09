//! Skill discovery and the composer's command sends.

use futures::executor::block_on;
use serde_json::json;

use super::SessionError;
use super::events::SendPayload;
use super::test_support::{Reply, RouteTransport, body_json, connected, header, live, query_value};

#[test]
fn session_skills_reads_the_session_catalog() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/skills",
        r#"{"skills":[{"name":"review","description":"Review the diff"}],"warnings":["x"]}"#,
    );
    let core = connected(transport);
    let catalog = block_on(core.session_skills("conv_a")).unwrap();
    assert_eq!(catalog.skills[0].name, "review");
    assert_eq!(catalog.warnings, ["x"]);
    let requests = core.transport().taken();
    let request = requests.last().unwrap();
    assert_eq!(
        query_value(request, "session_id").as_deref(),
        Some("conv_a")
    );
}

#[test]
fn host_skills_reads_the_catalog_for_a_folder_before_a_session_exists() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/skills",
        r#"{"skills":[{"name":"triage","description":"Triage issues"}]}"#,
    );
    let core = connected(transport);
    let catalog =
        block_on(core.host_skills("host_a", "claude-native", "/work/repo", Some("agent_1")))
            .unwrap();
    assert_eq!(catalog.skills[0].name, "triage");
    let requests = core.transport().taken();
    let request = requests.last().unwrap();
    assert_eq!(query_value(request, "host_id").as_deref(), Some("host_a"));
    assert_eq!(
        query_value(request, "harness").as_deref(),
        Some("claude-native")
    );
    assert_eq!(query_value(request, "path").as_deref(), Some("/work/repo"));
    assert_eq!(query_value(request, "agent_id").as_deref(), Some("agent_1"));
    assert!(matches!(
        block_on(core.host_skills("../x", "claude-native", "/work", None)),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}

#[test]
fn session_skills_surfaces_an_unready_host_and_a_malformed_reply() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "GET",
        "/v1/skills",
        vec![
            Reply::json(409, r#"{"detail":"session host is not ready"}"#),
            Reply::json(200, r#"{"warnings":[]}"#),
        ],
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.session_skills("conv_a")),
        Err(SessionError::HttpStatus { status: 409 })
    );
    assert!(matches!(
        block_on(core.session_skills("conv_a")),
        Err(SessionError::MalformedResponse { .. })
    ));
    assert!(matches!(
        block_on(core.session_skills("../x")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}

#[test]
fn skill_and_compact_sends_post_their_events_and_clear_the_draft() {
    let transport = RouteTransport::local();
    transport.writable_session("[]");
    transport.enqueue(
        "POST",
        "/v1/sessions/conv_a/events",
        vec![
            Reply::json(200, r#"{"queued":true,"item_id":"item_9"}"#),
            Reply::json(200, r#"{"queued":false}"#),
        ],
    );
    let core = live(transport);
    let payload = SendPayload::Skill {
        name: "review".into(),
        arguments: "the diff".into(),
    };
    let sent = block_on(core.send_command("conv_a", "/review the diff", payload)).unwrap();
    assert_eq!(sent.submission.item_id.as_deref(), Some("item_9"));
    assert_eq!(sent.draft, "");
    let sent = block_on(core.send_command("conv_a", "/compact", SendPayload::Compact)).unwrap();
    assert!(!sent.submission.queued);
    let bodies: Vec<_> = core.transport().writes().iter().map(body_json).collect();
    assert_eq!(
        bodies,
        [
            json!({"type": "slash_command", "data": {
                "kind": "skill", "name": "review", "arguments": "the diff"}}),
            json!({"type": "compact", "data": {}}),
        ]
    );
    // Only messages ask the server to hold them for an offline host.
    let held: Vec<_> = core
        .transport()
        .writes()
        .iter()
        .map(|request| header(request, "x-omnigent-hold-when-host-offline").map(str::to_owned))
        .collect();
    assert_eq!(held, [None, None]);
}

#[test]
fn mentions_go_ahead_of_the_text_and_the_draft_clears() {
    let transport = RouteTransport::local();
    transport.writable_session("[]");
    transport.ok("/v1/sessions/conv_a/events", r#"{"queued":true}"#);
    let core = live(transport);
    core.update_composer("conv_a", "explain it").unwrap();
    let paths = ["src/lib.rs".to_owned()];
    let sent = block_on(core.send_message_mentioning(
        "conv_a",
        "explain it",
        Some("claude-native"),
        &paths,
    ))
    .unwrap();
    assert_eq!(sent.draft, "");
    let body = core.transport().write_bodies().pop().unwrap();
    assert_eq!(
        body["data"]["content"][0]["text"],
        "[Attached: src/lib.rs]\n\nexplain it"
    );
    // Paths alone are a message.
    block_on(core.send_message_mentioning("conv_a", "", None, &paths)).unwrap();
    assert!(matches!(
        block_on(core.send_message_mentioning("conv_a", " ", None, &[])),
        Err(SessionError::EmptyMessage)
    ));
}

#[test]
fn slash_options_follow_the_servers_event_types() {
    let core = connected(RouteTransport::local());
    // The stubbed `/v1/info` of an older server lists no event types.
    assert!(!block_on(core.slash_options()).unwrap().server_clears);
    core.transport().ok(
        "/v1/info",
        r#"{"single_user":true,"accounts_enabled":false,"session_event_types":["message","clear"]}"#,
    );
    assert!(block_on(core.slash_options()).unwrap().server_clears);
}

#[test]
fn clear_context_posts_the_clear_control() {
    let transport = RouteTransport::local();
    transport.writable_session("[]");
    transport.ok("/v1/sessions/conv_a/events", r#"{"queued":false}"#);
    let core = live(transport);
    block_on(core.clear_context("conv_a")).unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        [json!({"type": "clear", "data": {}})]
    );
}

#[test]
fn messages_ask_to_be_held_and_an_offline_host_refuses_them() {
    let transport = RouteTransport::local();
    transport.writable_session("[]");
    transport.enqueue(
        "POST",
        "/v1/sessions/conv_a/events",
        vec![
            Reply::json(
                503,
                r#"{"error":{"code":"host_offline","message":"The host is offline."}}"#,
            ),
            Reply::json(503, r#"{"error":{"code":"host_offline","message":"x"}}"#),
            Reply::json(
                503,
                r#"{"error":{"code":"runner_unavailable","message":"x"}}"#,
            ),
        ],
    );
    let core = live(transport);
    let error = block_on(core.send_message("conv_a", "hello")).unwrap_err();
    assert_eq!(
        error,
        SessionError::HostOffline {
            message: "The host is offline.".to_owned()
        }
    );
    // A definite refusal: the next send is not blocked for review.
    assert!(!core.is_send_blocked("conv_a").unwrap());
    let request = core.transport().writes().pop().unwrap();
    assert_eq!(
        header(&request, "x-omnigent-hold-when-host-offline"),
        Some("on")
    );
    // The Inbox keeps the reply in its field, so it says so instead.
    let reply = block_on(core.send_reply("conv_a", "hello")).unwrap_err();
    assert!(matches!(reply, SessionError::HostOffline { message } if message.contains("reply")));
    // Any other 503 may still have delivered.
    assert!(matches!(
        block_on(core.send_message("conv_a", "hello")),
        Err(SessionError::DeliveryUncertain { .. })
    ));
}

#[test]
fn turning_titles_off_marks_event_posts() {
    let transport = RouteTransport::local();
    transport.writable_session("[]");
    transport.ok("/v1/sessions/conv_a/events", r#"{"queued":true}"#);
    let core = live(transport);
    block_on(core.send_message("conv_a", "first")).unwrap();
    core.set_background_session_titles(false);
    block_on(core.send_message("conv_a", "second")).unwrap();
    let titles: Vec<_> = core
        .transport()
        .writes()
        .iter()
        .map(|request| header(request, "X-Omnigent-Background-Session-Titles").map(str::to_owned))
        .collect();
    assert_eq!(titles, [None, Some("off".to_owned())]);
}

#[test]
fn unreadable_catalogs_and_info_name_their_route() {
    let core = connected(RouteTransport::local());
    core.transport()
        .ok("/v1/skills", r#"{"warnings":[]}"#)
        .ok("/v1/info", "[]");
    assert!(matches!(
        block_on(core.host_skills("host_a", "claude", "/work", None)),
        Err(SessionError::MalformedResponse { detail }) if detail.starts_with("/v1/skills: ")
    ));
    assert!(matches!(
        block_on(core.slash_options()),
        Err(SessionError::MalformedResponse { detail }) if detail.starts_with("/v1/info: ")
    ));
}
