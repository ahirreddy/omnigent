//! Failed-turn recovery requests.

use futures::executor::block_on;
use serde_json::json;

use super::SessionError;
use super::test_support::{Reply, RouteTransport, body_json, connected};
use crate::recovery::FailureRecovery;

#[test]
fn continue_posts_the_continuation_and_resume_posts_retry_session() {
    let transport = RouteTransport::local();
    transport.writable_session("[]");
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
}

#[test]
fn an_unreadable_recovery_acknowledgement_is_uncertain() {
    let transport = RouteTransport::local();
    transport.writable_session("[]");
    transport.ok("/v1/sessions/conv_a/events", "5");
    let core = connected(transport);
    assert!(matches!(
        block_on(core.recover_turn("conv_a", FailureRecovery::Resume)),
        Err(SessionError::DeliveryUncertain { detail }) if detail.contains("acknowledgement")
    ));
}
