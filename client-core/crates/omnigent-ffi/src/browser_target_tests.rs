//! The browser target round-trips through the FFI.

use std::sync::Arc;

use super::BrowserTarget;
use crate::errors::CoreError;
use crate::test_support::{connected, json};

#[test]
fn the_target_reads_from_the_label_and_a_refused_choice_is_an_error() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions/conv_a",
        json(
            200,
            r#"{"id":"conv_a","labels":{"omnigent.browser_target":"remote"}}"#,
        ),
    );
    let core = Arc::clone(&harness.core);
    let target = harness.run(async move { core.browser_target("conv_a".into()).await });
    assert_eq!(target.unwrap(), BrowserTarget::Remote);

    harness.http.route(
        "/v1/sessions/conv_a",
        json(403, r#"{"detail":"owner only"}"#),
    );
    let core = Arc::clone(&harness.core);
    let refused = harness.run(async move {
        core.set_browser_target("conv_a".into(), BrowserTarget::Local)
            .await
    });
    assert!(
        matches!(refused, Err(CoreError::Session { .. })),
        "{refused:?}"
    );
}
