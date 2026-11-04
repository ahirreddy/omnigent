//! Skill discovery and the composer's command sends.

use futures::executor::block_on;
use serde_json::json;

use super::SessionError;
use super::events::SendPayload;
use super::test_support::{Reply, RouteTransport, body_json, connected, live, query_value};

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
}
