//! The session's browser target is read from and written to its label.

use futures::executor::block_on;

use super::{BROWSER_TARGET_LABEL, BrowserTarget};
use crate::client::SessionError;
use crate::client::test_support::{Reply, RouteTransport, body_json, connected};

#[test]
fn the_label_reads_as_the_target_and_anything_else_as_auto() {
    let core = connected(RouteTransport::local());
    let session = |labels: &str| format!(r#"{{"id":"conv_a","labels":{labels}}}"#);
    core.transport().ok(
        "/v1/sessions/conv_a",
        session(r#"{"omnigent.browser_target":"local"}"#),
    );
    assert_eq!(
        block_on(core.browser_target("conv_a")).unwrap(),
        BrowserTarget::Local
    );
    core.transport().ok(
        "/v1/sessions/conv_a",
        session(r#"{"omnigent.browser_target":"phone"}"#),
    );
    assert_eq!(
        block_on(core.browser_target("conv_a")).unwrap(),
        BrowserTarget::Auto
    );
    core.transport().ok("/v1/sessions/conv_a", session("{}"));
    assert_eq!(
        block_on(core.browser_target("conv_a")).unwrap(),
        BrowserTarget::Auto
    );
    core.transport()
        .respond(None, "/v1/sessions/conv_a", None, Reply::json(404, "{}"));
    assert!(matches!(
        block_on(core.browser_target("conv_a")),
        Err(SessionError::SessionNotFound { .. })
    ));
}

#[test]
fn choosing_writes_the_label_and_auto_clears_it() {
    let core = connected(RouteTransport::local());
    core.transport().respond(
        Some("PATCH"),
        "/v1/sessions/conv_a",
        None,
        Reply::json(200, "{}"),
    );
    block_on(core.set_browser_target("conv_a", BrowserTarget::Remote)).unwrap();
    block_on(core.set_browser_target("conv_a", BrowserTarget::Auto)).unwrap();

    let bodies: Vec<_> = core
        .transport()
        .taken()
        .iter()
        .filter(|request| request.method == "PATCH")
        .map(|request| body_json(request)["labels"][BROWSER_TARGET_LABEL].clone())
        .collect();
    assert_eq!(bodies, ["remote", ""]);
}

#[test]
fn a_refused_choice_reports_the_refusal() {
    let core = connected(RouteTransport::local());
    core.transport().respond(
        Some("PATCH"),
        "/v1/sessions/conv_a",
        None,
        Reply::json(
            403,
            r#"{"detail":"Only the session owner can give its agent this Mac's browser."}"#,
        ),
    );
    let error = block_on(core.set_browser_target("conv_a", BrowserTarget::Local)).unwrap_err();
    assert!(matches!(error, SessionError::Forbidden), "{error:?}");
    assert!(matches!(
        block_on(core.set_browser_target("bad id", BrowserTarget::Local)),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}
