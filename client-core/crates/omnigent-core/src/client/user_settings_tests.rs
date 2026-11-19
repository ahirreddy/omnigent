//! The caller's title instructions: reads, saves trimmed, clears, and the server's limit.

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::test_support::{Reply, RouteTransport, connected};
use super::{DEFAULT_TITLE_INSTRUCTIONS_MAX_CHARS, SessionTitleInstructions};

const PATH: &str = "/v1/settings/session-title-instructions";

#[test]
fn reads_saved_instructions_and_the_servers_limit() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        PATH,
        r#"{"instructions":"Start with the ticket id.","max_chars":4000}"#,
    );
    assert_eq!(
        block_on(core.session_title_instructions()).unwrap(),
        SessionTitleInstructions {
            instructions: Some("Start with the ticket id.".into()),
            max_chars: 4000,
        }
    );

    // Nothing saved; an answer without a limit keeps the default.
    core.transport().ok(PATH, r#"{"instructions":null}"#);
    assert_eq!(
        block_on(core.session_title_instructions()).unwrap(),
        SessionTitleInstructions {
            instructions: None,
            max_chars: DEFAULT_TITLE_INSTRUCTIONS_MAX_CHARS,
        }
    );

    core.transport()
        .ok(PATH, r#"{"instructions":7,"max_chars":4000}"#);
    assert!(matches!(
        block_on(core.session_title_instructions()),
        Err(SessionError::MalformedResponse { detail }) if detail.contains(PATH)
    ));
}

#[test]
fn saves_trimmed_and_clears_with_null() {
    let core = connected(RouteTransport::local());
    core.transport()
        .ok(PATH, r#"{"instructions":"Use French.","max_chars":4000}"#);
    let saved = block_on(core.save_session_title_instructions(Some("  Use French.\n"))).unwrap();
    assert_eq!(saved.instructions.as_deref(), Some("Use French."));

    core.transport()
        .ok(PATH, r#"{"instructions":null,"max_chars":4000}"#);
    let cleared = block_on(core.save_session_title_instructions(Some("   "))).unwrap();
    assert_eq!(cleared.instructions, None);
    block_on(core.save_session_title_instructions(None)).unwrap();

    let writes = core.transport().writes();
    assert!(writes.iter().all(|request| request.method == "PUT"));
    assert_eq!(
        core.transport().write_bodies(),
        [
            json!({"instructions": "Use French."}),
            json!({"instructions": null}),
            json!({"instructions": null}),
        ]
    );
}

#[test]
fn a_rejected_save_and_an_unreadable_answer_are_errors() {
    let core = connected(RouteTransport::local());
    core.transport().respond(
        Some("PUT"),
        PATH,
        None,
        Reply::json(
            400,
            r#"{"error":{"code":"invalid_input","message":"Title instructions must be at most 4000 characters"}}"#,
        ),
    );
    assert!(matches!(
        block_on(core.save_session_title_instructions(Some("long"))),
        Err(SessionError::Rejected { status: 400, .. })
    ));

    core.transport()
        .respond(Some("PUT"), PATH, None, Reply::json(200, "not json"));
    assert!(matches!(
        block_on(core.save_session_title_instructions(Some("ok"))),
        Err(SessionError::DeliveryUncertain { .. })
    ));
}
