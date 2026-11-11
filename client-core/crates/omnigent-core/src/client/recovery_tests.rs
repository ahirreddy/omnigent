//! Failed-turn recovery requests.

use futures::executor::block_on;
use serde_json::json;

use super::SessionError;
use super::test_support::{
    Reply, RouteTransport, body_json, cache_row, connected, lines_after_connect,
};
use crate::recovery::FailureRecovery;

#[test]
fn continue_posts_the_continuation_and_resume_posts_retry_session() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "POST",
        "/v1/sessions/conv_a/events",
        vec![
            Reply::json(200, r#"{"queued":true,"item_id":"i"}"#),
            Reply::json(200, r#"{"queued":false,"recovered":false}"#),
            Reply::json(200, r#"{"queued":true,"denied":true,"reason":"policy"}"#),
        ],
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.recover_turn("conv_a", FailureRecovery::Continue)),
        Ok(true)
    );
    assert_eq!(
        block_on(core.recover_turn("conv_a", FailureRecovery::Resume)),
        Ok(false)
    );
    assert_eq!(
        block_on(core.recover_turn("conv_a", FailureRecovery::Continue)),
        Err(SessionError::MessageDenied {
            reason: Some("policy".into())
        })
    );
    let bodies: Vec<_> = core.transport().writes().iter().map(body_json).collect();
    assert_eq!(
        bodies[0],
        json!({"type": "message", "data": {"role": "user", "content": [
            {"type": "input_text", "text": "Please continue from where you left off."}]}})
    );
    assert_eq!(bodies[1], json!({"type": "retry_session", "data": {}}));
    assert_eq!(
        lines_after_connect(&core),
        ["POST /v1/sessions/conv_a/events"; 3]
    );
}

#[test]
fn recovery_is_refused_by_a_read_only_cached_row_without_a_request() {
    let core = connected(RouteTransport::local());
    cache_row(
        &core,
        r#"{"id":"conv_a","status":"failed","created_at":1,"permission_level":1}"#,
    );
    for recovery in [FailureRecovery::Continue, FailureRecovery::Resume] {
        assert_eq!(
            block_on(core.recover_turn("conv_a", recovery)),
            Err(SessionError::ReadOnly)
        );
    }
    assert_eq!(lines_after_connect(&core), Vec::<String>::new());
}

#[test]
fn a_refused_recovery_reads_as_the_removed_check_did() {
    for (status, expected) in [
        (403, SessionError::ReadOnly),
        (
            404,
            SessionError::SessionNotFound {
                session_id: "conv_a".into(),
            },
        ),
    ] {
        let transport = RouteTransport::local();
        transport.respond(
            Some("POST"),
            "/v1/sessions/conv_a/events",
            None,
            Reply::json(status, "{}"),
        );
        let core = connected(transport);
        // An editor's cached row does not stand in for the server's answer.
        cache_row(
            &core,
            r#"{"id":"conv_a","status":"failed","created_at":1,"permission_level":2}"#,
        );
        assert_eq!(
            block_on(core.recover_turn("conv_a", FailureRecovery::Resume)),
            Err(expected),
            "{status}"
        );
        assert_eq!(
            lines_after_connect(&core),
            ["POST /v1/sessions/conv_a/events"]
        );
    }
}

#[test]
fn an_unreadable_recovery_acknowledgement_is_uncertain() {
    let transport = RouteTransport::local();
    transport.ok("/v1/sessions/conv_a/events", "5");
    let core = connected(transport);
    assert!(matches!(
        block_on(core.recover_turn("conv_a", FailureRecovery::Resume)),
        Err(SessionError::DeliveryUncertain { detail }) if detail.contains("acknowledgement")
    ));
}
