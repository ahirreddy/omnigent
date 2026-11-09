//! Claiming and answering browser actions over the fake host.

use serde_json::json as value;

use crate::browser::{BrowserActionClaim, BrowserActionDelivery};
use crate::errors::CoreError;
use crate::test_support::{connected, json};

const CLAIM: &str = "/v1/sessions/conv_a/browser/action_claim/baction_1";
const RESULT: &str = "/v1/sessions/conv_a/browser/action_result/baction_1";

#[test]
fn a_claim_is_won_or_lost_and_a_failed_one_is_an_error() {
    let mut harness = connected();
    harness.http.route_method(
        "POST",
        CLAIM,
        json(200, r#"{"claimed":true,"claim_token":"tok_1"}"#),
    );
    assert_eq!(
        harness
            .call(|core| async move {
                core.claim_browser_action("conv_a".into(), "baction_1".into())
                    .await
            })
            .unwrap(),
        BrowserActionClaim::Claimed {
            claim_token: "tok_1".into()
        }
    );
    assert_eq!(harness.last_request_line(), format!("POST {CLAIM}"));

    harness
        .http
        .route_method("POST", CLAIM, json(200, r#"{"claimed":false}"#));
    assert_eq!(
        harness
            .call(|core| async move {
                core.claim_browser_action("conv_a".into(), "baction_1".into())
                    .await
            })
            .unwrap(),
        BrowserActionClaim::NotClaimed
    );

    harness
        .http
        .route_method("POST", CLAIM, json(500, r#"{"detail":"down"}"#));
    assert!(matches!(
        harness.call(|core| async move {
            core.claim_browser_action("conv_a".into(), "baction_1".into())
                .await
        }),
        Err(CoreError::Session { .. })
    ));
}

#[test]
fn a_result_must_be_an_object_and_reports_whether_it_arrived_in_time() {
    let mut harness = connected();
    let post = |result: &str| {
        let result = result.to_owned();
        move |core: std::sync::Arc<crate::client::ClientCore>| async move {
            core.post_browser_action_result(
                "conv_a".into(),
                "baction_1".into(),
                "tok_1".into(),
                result,
            )
            .await
        }
    };
    assert!(matches!(
        harness.call(post("{nope")),
        Err(CoreError::Decode { message }) if message.starts_with("browser action result:")
    ));
    assert!(matches!(
        harness.call(post("[1]")),
        Err(CoreError::Decode { message }) if message.ends_with("not a JSON object")
    ));
    assert_eq!(
        harness
            .http
            .lines()
            .iter()
            .filter(|line| line.contains("action_result"))
            .count(),
        0,
        "nothing is sent"
    );

    harness
        .http
        .route_method("POST", RESULT, json(202, r#"{"resolved":true}"#));
    assert_eq!(
        harness.call(post(r#"{"ok":true}"#)).unwrap(),
        BrowserActionDelivery::Resolved
    );
    assert_eq!(
        harness.last_request(),
        (
            format!("POST {RESULT}"),
            value!({"result": {"ok": true}, "claim_token": "tok_1"})
        )
    );

    harness
        .http
        .route_method("POST", RESULT, json(200, r#"{"resolved":false}"#));
    assert_eq!(
        harness.call(post(r#"{"ok":false}"#)).unwrap(),
        BrowserActionDelivery::Expired
    );

    harness
        .http
        .route_method("POST", RESULT, json(403, r#"{"detail":"no"}"#));
    assert!(harness.call(post(r#"{"ok":false}"#)).is_err());
}
