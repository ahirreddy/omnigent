//! Sign-in lifecycles through the real core: OIDC, browser tickets, passwords and sign-out, with
//! every await a place a user can cancel, reconnect or lose the network.

#![allow(
    clippy::too_many_lines,
    reason = "each test walks one sign-in journey end to end"
)]

use std::sync::Arc;

use omnigent_core::auth::SecretString;

use super::*;
use crate::connection::{OidcRedirect, UrlPolicy};
use crate::events::{AuthenticationMode, SignInMethod};
use crate::host::{SecureStoreError, SecureStoreKey as HostKey};
use crate::http::TransportError;
use crate::test_support::{Harness, json, phases};

const SERVER: &str = "http://127.0.0.1:6797";
const REDIRECT: &str = "http://127.0.0.1:50000/oauth/callback";

fn offline() -> TransportError {
    TransportError::Offline {
        message: "no route".into(),
    }
}

fn locked() -> SecureStoreError {
    SecureStoreError::Unavailable {
        message: "device locked".into(),
    }
}

/// The token routes of an OIDC server; `expires_in` is the session's lifetime in seconds.
fn route_oidc_tokens(harness: &Harness, access: &str, expires_in: u64) {
    harness.http.route(
        "/auth/native-token",
        json(
            200,
            &serde_json::json!({
                "token": access,
                "refresh_token": "grant-1",
                "user_id": "ada",
                "expires_in": expires_in,
            })
            .to_string(),
        ),
    );
    harness.http.route(
        "/oauth/token",
        json(
            200,
            &serde_json::json!({"access_token": access, "expires_in": expires_in}).to_string(),
        ),
    );
}

fn oidc_server() -> Harness {
    let harness = Harness::new(UrlPolicy::Development);
    harness.http.route(
        "/.well-known/omnigent.json",
        json(
            200,
            r#"{"manifest_version":1,"server_name":"Lab","auth":{"mode":"oidc","native_redirect_uris":["ai.omnigent.ios:/callback"]}}"#,
        ),
    );
    harness.http.route(
        "/v1/info",
        json(
            200,
            r#"{"single_user":false,"accounts_enabled":false,"login_url":"/auth/login"}"#,
        ),
    );
    harness
        .http
        .route("/v1/me", json(200, r#"{"user_id":"ada"}"#));
    harness.http.route(
        "/v1/sessions",
        json(200, r#"{"object":"list","data":[],"has_more":false}"#),
    );
    harness.http.route("/oauth/revoke", json(200, "{}"));
    route_oidc_tokens(&harness, "token-1", 3_600);
    harness
}

fn accounts_server() -> Harness {
    let harness = Harness::new(UrlPolicy::Development);
    harness.http.route(
        "/.well-known/omnigent.json",
        json(200, r#"{"manifest_version":1,"auth":{"mode":"accounts"}}"#),
    );
    harness.http.route(
        "/v1/info",
        json(
            200,
            r#"{"single_user":false,"accounts_enabled":true,"login_url":"/login"}"#,
        ),
    );
    harness.http.route(
        "/auth/login",
        json(
            200,
            r#"{"token":"tok-1","expires_in":3600,"user":{"id":"u1"}}"#,
        ),
    );
    harness
        .http
        .route("/v1/me", json(200, r#"{"user_id":"u1"}"#));
    harness.http.route(
        "/v1/sessions",
        json(200, r#"{"object":"list","data":[],"has_more":false}"#),
    );
    harness
}

fn connect(harness: &mut Harness) -> Result<ConnectionPhase, CoreError> {
    harness.call(|core| async move { core.connect(SERVER.into(), None).await })
}

/// The callback the browser delivers for `challenge`.
fn callback_for(challenge: &OidcChallenge) -> String {
    let state = url::Url::parse(&challenge.authorize_url)
        .unwrap()
        .query_pairs()
        .find(|(name, _)| name == "native_state")
        .map(|(_, value)| value.into_owned())
        .unwrap();
    format!("{}?state={state}&code=abc", challenge.redirect_uri)
}

/// Signs in through the native flow and returns once connected.
fn sign_in_oidc(harness: &mut Harness) -> ConnectedServer {
    connect(harness).unwrap();
    let challenge = harness.core.begin_oidc_sign_in(REDIRECT.into()).unwrap();
    let callback = callback_for(&challenge);
    harness
        .call(|core| async move {
            core.complete_oidc_sign_in(challenge.attempt_id, callback)
                .await
        })
        .unwrap()
}

fn last_phase(harness: &Harness) -> ConnectionPhase {
    phases(&harness.events.all()).pop().expect("a phase")
}

fn connection_errors(harness: &Harness) -> Vec<CoreError> {
    harness
        .events
        .all()
        .into_iter()
        .filter_map(|event| match event {
            CoreEvent::Error {
                scope: ErrorScope::Connection,
                error,
            } => Some(error),
            _ => None,
        })
        .collect()
}

fn store_key(namespace: &str, account: &str) -> (String, String) {
    (namespace.to_owned(), account.to_owned())
}

#[test]
fn an_oidc_server_without_a_grant_offers_its_sign_in_methods() {
    let mut harness = oidc_server();
    let phase = connect(&mut harness).unwrap();
    let ConnectionPhase::SignInRequired {
        methods,
        mode,
        reason,
        server_name,
        ..
    } = phase
    else {
        panic!("{phase:?}");
    };
    assert_eq!(mode, AuthenticationMode::Oidc);
    assert_eq!(reason, None);
    assert_eq!(server_name.as_deref(), Some("Lab"));
    assert_eq!(
        methods,
        vec![
            SignInMethod::LoopbackBrowser {
                path: "/oauth/callback".into()
            },
            SignInMethod::BrowserTicket
        ]
    );
}

#[test]
fn oidc_methods_follow_the_apps_redirect_and_the_servers_list() {
    let methods_for = |redirect: OidcRedirect, manifest: &str| {
        let mut harness = Harness::with_redirect(UrlPolicy::Development, redirect);
        harness
            .http
            .route("/.well-known/omnigent.json", json(200, manifest));
        harness.http.route(
            "/v1/info",
            json(
                200,
                r#"{"single_user":false,"accounts_enabled":false,"login_url":"/auth/login"}"#,
            ),
        );
        match connect(&mut harness).unwrap() {
            ConnectionPhase::SignInRequired { methods, .. } => methods,
            other => panic!("{other:?}"),
        }
    };
    let listed = r#"{"manifest_version":1,"auth":{"mode":"oidc","native_redirect_uris":["ai.omnigent.ios:/callback"]}}"#;
    let unlisted = r#"{"manifest_version":1,"auth":{"mode":"oidc"}}"#;
    let scheme = || OidcRedirect::PrivateScheme {
        redirect_uri: "ai.omnigent.ios:/callback".into(),
    };
    assert_eq!(
        methods_for(scheme(), listed),
        vec![
            SignInMethod::Browser {
                redirect_uri: "ai.omnigent.ios:/callback".into()
            },
            SignInMethod::BrowserTicket
        ]
    );
    // The server does not accept this app's scheme, so only the ticket is left.
    assert_eq!(
        methods_for(scheme(), unlisted),
        vec![SignInMethod::BrowserTicket]
    );
    assert_eq!(
        methods_for(OidcRedirect::None, listed),
        vec![SignInMethod::BrowserTicket]
    );
}

#[test]
fn native_oidc_signs_in_saves_the_grant_and_renews_in_place() {
    let mut harness = oidc_server();
    let server = sign_in_oidc(&mut harness);
    assert_eq!(server.user_id, "ada");
    assert_eq!(server.mode, AuthenticationMode::Oidc);
    assert!(
        phases(&harness.events.all())
            .iter()
            .any(|phase| matches!(phase, ConnectionPhase::SigningIn { .. }))
    );
    assert_eq!(lock(&harness.store.items).len(), 1);

    route_oidc_tokens(&harness, "token-2", 3_600);
    harness.events.take();
    harness.advance(3_600_000);
    let events = harness.events.take();
    assert!(
        events
            .iter()
            .any(|event| matches!(event, CoreEvent::CredentialRotated { .. })),
        "{events:#?}"
    );
    assert_eq!(phases(&events), [], "no reconnect");
    harness.core.refresh_sessions();
    harness.pump();
    let authorization = lock(&harness.http.requests)
        .iter()
        .rev()
        .find(|request| url::Url::parse(&request.url).unwrap().path() == "/v1/sessions")
        .and_then(|request| {
            request
                .headers
                .iter()
                .find(|header| header.name == "Authorization")
                .map(|header| header.value.clone())
        });
    assert_eq!(authorization.as_deref(), Some("Bearer token-2"));
}

#[test]
fn a_session_with_no_expiry_schedules_no_renewal() {
    let mut harness = oidc_server();
    harness.http.route(
        "/auth/native-token",
        json(200, r#"{"token":"forever","refresh_token":"grant-1"}"#),
    );
    sign_in_oidc(&mut harness);
    let refreshes = harness.http.count("/oauth/token");
    harness.advance(86_400_000);
    assert_eq!(harness.http.count("/oauth/token"), refreshes);
}

#[test]
fn a_redirect_the_server_does_not_accept_is_refused_before_anything_starts() {
    let mut harness = oidc_server();
    connect(&mut harness).unwrap();
    let error = harness
        .core
        .begin_oidc_sign_in("ai.other.app:/callback".into())
        .unwrap_err();
    assert!(matches!(error, CoreError::Oidc { .. }), "{error:?}");
    assert!(!matches!(
        last_phase(&harness),
        ConnectionPhase::SigningIn { .. }
    ));
}

#[test]
fn signing_in_before_connecting_is_an_invalid_state() {
    let mut harness = oidc_server();
    let error = harness
        .core
        .begin_oidc_sign_in(REDIRECT.into())
        .unwrap_err();
    assert!(matches!(error, CoreError::InvalidState { .. }), "{error:?}");
    let error = harness
        .call(|core| async move { core.begin_browser_login().await })
        .unwrap_err();
    assert!(matches!(error, CoreError::InvalidState { .. }), "{error:?}");
    let error = harness
        .call(|core| async move { core.sign_out().await })
        .unwrap_err();
    assert!(matches!(error, CoreError::InvalidState { .. }), "{error:?}");
}

#[test]
fn a_failing_rng_stops_a_sign_in_before_it_starts() {
    let mut harness = oidc_server();
    connect(&mut harness).unwrap();
    harness
        .entropy
        .failing
        .store(true, std::sync::atomic::Ordering::SeqCst);
    let error = harness
        .core
        .begin_oidc_sign_in(REDIRECT.into())
        .unwrap_err();
    assert!(matches!(error, CoreError::Oidc { .. }), "{error:?}");
    let error = harness
        .call(|core| async move { core.begin_browser_login().await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Entropy { .. }), "{error:?}");
}

#[test]
fn an_attempt_finishes_once_and_a_cancelled_one_never_finishes() {
    let mut harness = oidc_server();
    connect(&mut harness).unwrap();
    let challenge = harness.core.begin_oidc_sign_in(REDIRECT.into()).unwrap();
    let attempt = challenge.attempt_id;
    let callback = callback_for(&challenge);

    // Closing the sheet returns to the sign-in screen, once.
    harness.core.cancel_oidc_sign_in(attempt);
    harness.pump();
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired { reason: None, .. }
    ));
    harness.events.take();
    harness.core.cancel_oidc_sign_in(attempt);
    harness.core.cancel_oidc_sign_in(9_999);
    harness.pump();
    assert_eq!(phases(&harness.events.take()), []);

    // The callback of the cancelled attempt arrives anyway.
    let error = harness
        .call(|core| async move { core.complete_oidc_sign_in(attempt, callback).await })
        .unwrap_err();
    assert!(matches!(error, CoreError::InvalidState { .. }), "{error:?}");
    assert_eq!(harness.http.count("/auth/native-token"), 0);

    // A second finish of a finished attempt is refused; the code is burnt only once.
    let challenge = harness.core.begin_oidc_sign_in(REDIRECT.into()).unwrap();
    let callback = callback_for(&challenge);
    let again = callback.clone();
    let attempt = challenge.attempt_id;
    harness
        .call(|core| async move { core.complete_oidc_sign_in(attempt, callback).await })
        .unwrap();
    let error = harness
        .call(|core| async move { core.complete_oidc_sign_in(attempt, again).await })
        .unwrap_err();
    assert!(matches!(error, CoreError::InvalidState { .. }), "{error:?}");
    assert_eq!(harness.http.count("/auth/native-token"), 1);
}

#[test]
fn a_new_connect_abandons_the_attempts_of_the_old_one() {
    let mut harness = oidc_server();
    connect(&mut harness).unwrap();
    let challenge = harness.core.begin_oidc_sign_in(REDIRECT.into()).unwrap();
    connect(&mut harness).unwrap();
    let attempt = challenge.attempt_id;
    let callback = callback_for(&challenge);
    let error = harness
        .call(|core| async move { core.complete_oidc_sign_in(attempt, callback).await })
        .unwrap_err();
    assert!(matches!(error, CoreError::InvalidState { .. }), "{error:?}");
}

#[test]
fn a_refused_callback_returns_to_sign_in_with_the_reason() {
    let mut harness = oidc_server();
    connect(&mut harness).unwrap();
    let challenge = harness.core.begin_oidc_sign_in(REDIRECT.into()).unwrap();
    let attempt = challenge.attempt_id;
    let callback = format!(
        "{}&error=access_denied&error_description=Nope",
        callback_for(&challenge)
    );
    let error = harness
        .call(|core| async move { core.complete_oidc_sign_in(attempt, callback).await })
        .unwrap_err();
    let CoreError::Oidc { message, .. } = &error else {
        panic!("{error:?}");
    };
    assert!(message.contains("Nope"), "{message}");
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired {
            reason: Some(CoreError::Oidc { .. }),
            ..
        }
    ));
}

#[test]
fn a_disconnect_during_the_code_exchange_wins() {
    let mut harness = oidc_server();
    connect(&mut harness).unwrap();
    let challenge = harness.core.begin_oidc_sign_in(REDIRECT.into()).unwrap();
    let attempt = challenge.attempt_id;
    let callback = callback_for(&challenge);
    let release = harness.http.hold("/auth/native-token");
    let core = Arc::clone(&harness.core);
    let pending = harness.start(async move { core.complete_oidc_sign_in(attempt, callback).await });
    assert!(pending.borrow().is_none());
    harness.core.disconnect();
    harness.pump();
    release.send(()).unwrap();
    harness.pump();
    let result = pending.borrow_mut().take().expect("the exchange finished");
    assert!(
        matches!(result, Err(CoreError::InvalidState { .. })),
        "{result:?}"
    );
    assert_eq!(last_phase(&harness), ConnectionPhase::Disconnected);
    assert_eq!(harness.http.count("/v1/me"), 0);
}

#[test]
fn an_old_grant_that_cannot_be_deleted_is_reported_and_sign_in_continues() {
    let mut harness = oidc_server();
    harness.http.route(
        "/auth/native-token",
        json(200, r#"{"token":"t","user_id":"ada","expires_in":3600}"#),
    );
    *lock(&harness.store.delete_failure) = Some(locked());
    let server = sign_in_oidc(&mut harness);
    assert_eq!(server.user_id, "ada");
    assert_eq!(connection_errors(&harness).len(), 1);
}

#[test]
fn a_saved_grant_restores_the_connection_and_a_dead_one_asks_to_sign_in() {
    let mut harness = oidc_server();
    sign_in_oidc(&mut harness);
    harness.core.disconnect();
    harness.pump();

    let phase = connect(&mut harness).unwrap();
    assert!(
        matches!(phase, ConnectionPhase::Connected { .. }),
        "{phase:?}"
    );

    harness.core.disconnect();
    harness.pump();
    harness
        .http
        .route("/oauth/token", json(400, r#"{"error":"invalid_grant"}"#));
    let phase = connect(&mut harness).unwrap();
    assert!(
        matches!(
            phase,
            ConnectionPhase::SignInRequired {
                reason: Some(CoreError::Oidc { .. }),
                ..
            }
        ),
        "{phase:?}"
    );
    assert_eq!(
        lock(&harness.store.items).len(),
        0,
        "the dead grant is gone"
    );
}

#[test]
fn an_unreadable_store_asks_to_sign_in_with_the_reason() {
    let mut harness = oidc_server();
    *lock(&harness.store.get_failure) = Some(locked());
    let phase = connect(&mut harness).unwrap();
    assert!(
        matches!(
            phase,
            ConnectionPhase::SignInRequired {
                reason: Some(CoreError::Oidc { .. }),
                ..
            }
        ),
        "{phase:?}"
    );
}

/// The renewal timer fires while the laptop has no network: the session is still valid, so the
/// connection stays and the renewal tries again.
#[test]
fn a_network_failure_during_renewal_keeps_the_connection_and_retries() {
    let mut harness = oidc_server();
    sign_in_oidc(&mut harness);
    harness.events.take();
    harness.http.fail_next("/oauth/token", offline());
    harness.advance(3_600_000);
    let events = harness.events.take();
    assert_eq!(phases(&events), [], "{events:#?}");
    assert!(
        events.iter().any(|event| matches!(
            event,
            CoreEvent::Error {
                scope: ErrorScope::Connection,
                error: CoreError::Oidc { .. }
            }
        )),
        "{events:#?}"
    );

    route_oidc_tokens(&harness, "token-2", 3_600);
    harness.advance(60_000);
    let events = harness.events.take();
    assert!(
        events
            .iter()
            .any(|event| matches!(event, CoreEvent::CredentialRotated { .. })),
        "{events:#?}"
    );
}

/// A locked device cannot read the grant in the background; unlocking it must not need a sign-in.
#[test]
fn a_locked_store_during_renewal_keeps_the_connection_and_retries() {
    let mut harness = oidc_server();
    sign_in_oidc(&mut harness);
    harness.events.take();
    *lock(&harness.store.get_failure) = Some(locked());
    harness.advance(3_600_000);
    assert_eq!(phases(&harness.events.take()), []);
    *lock(&harness.store.get_failure) = None;
    route_oidc_tokens(&harness, "token-2", 3_600);
    harness.advance(60_000);
    assert!(
        harness
            .events
            .take()
            .iter()
            .any(|event| matches!(event, CoreEvent::CredentialRotated { .. }))
    );
}

/// Signing in again after a 401 must leave one renewal running, not two refreshing the same grant.
#[test]
fn signing_in_again_replaces_the_pending_renewal() {
    let mut harness = oidc_server();
    sign_in_oidc(&mut harness);
    harness
        .http
        .route("/v1/sessions", json(401, r#"{"detail":"expired"}"#));
    harness.core.refresh_sessions();
    harness.pump();
    harness.http.route(
        "/v1/sessions",
        json(200, r#"{"object":"list","data":[],"has_more":false}"#),
    );
    harness.advance(1_000);
    let challenge = harness.core.begin_oidc_sign_in(REDIRECT.into()).unwrap();
    let callback = callback_for(&challenge);
    harness
        .call(|core| async move {
            core.complete_oidc_sign_in(challenge.attempt_id, callback)
                .await
        })
        .unwrap();
    let refreshes = harness.http.count("/oauth/token");
    harness.advance(3_600_000);
    assert_eq!(harness.http.count("/oauth/token"), refreshes + 1);
}

#[test]
fn a_rejected_grant_during_renewal_ends_the_connection_and_asks_to_sign_in() {
    let mut harness = oidc_server();
    sign_in_oidc(&mut harness);
    harness
        .http
        .route("/oauth/token", json(400, r#"{"error":"invalid_grant"}"#));
    harness.advance(3_600_000);
    let phase = last_phase(&harness);
    assert!(
        matches!(
            phase,
            ConnectionPhase::SignInRequired {
                reason: Some(CoreError::Oidc { .. }),
                ..
            }
        ),
        "{phase:?}"
    );
    assert!(!harness.core.sessions().is_connected());
    // The only reason the app ever shows is the real one.
    assert!(!phases(&harness.events.all()).iter().any(|phase| matches!(
        phase,
        ConnectionPhase::SignInRequired {
            reason: Some(CoreError::Session { .. }),
            ..
        }
    )));
    let refreshes = harness.http.count("/oauth/token");
    harness.advance(86_400_000);
    assert_eq!(
        harness.http.count("/oauth/token"),
        refreshes,
        "no more tries"
    );
}

#[test]
fn a_disconnect_cancels_the_renewal_and_a_racing_one_is_dropped() {
    let mut harness = oidc_server();
    sign_in_oidc(&mut harness);
    harness.core.disconnect();
    harness.pump();
    let refreshes = harness.http.count("/oauth/token");
    harness.advance(86_400_000);
    assert_eq!(harness.http.count("/oauth/token"), refreshes);

    // The refresh was in flight when the user disconnected.
    connect(&mut harness).unwrap();
    let release = harness.http.hold("/oauth/token");
    harness.advance(3_600_000);
    harness.core.disconnect();
    harness.pump();
    release.send(()).unwrap();
    harness.pump();
    assert_eq!(last_phase(&harness), ConnectionPhase::Disconnected);
}

/// A closed window's core must not go on refreshing a grant the next window shares.
#[test]
fn a_shut_down_core_stops_renewing() {
    let mut harness = oidc_server();
    sign_in_oidc(&mut harness);
    harness.core.shutdown();
    harness.pump();
    let refreshes = harness.http.count("/oauth/token");
    harness.advance(86_400_000);
    assert_eq!(harness.http.count("/oauth/token"), refreshes);
}

#[test]
fn a_dropped_core_stops_renewing_and_is_released() {
    let mut harness = oidc_server();
    sign_in_oidc(&mut harness);
    let inner = Arc::downgrade(&harness.core.inner);
    harness.core = ClientCore::new_demo(harness.clock.clone(), harness.scheduler.clone()).unwrap();
    harness.pump();
    let refreshes = harness.http.count("/oauth/token");
    harness.advance(86_400_000);
    assert_eq!(harness.http.count("/oauth/token"), refreshes);
    assert_eq!(inner.strong_count(), 0, "nothing keeps the old core alive");
}

#[test]
fn a_401_that_races_the_renewal_reconnects_with_the_new_token() {
    let mut harness = oidc_server();
    sign_in_oidc(&mut harness);
    harness
        .http
        .route("/v1/sessions", json(401, r#"{"detail":"expired"}"#));
    harness.core.refresh_sessions();
    harness.pump();
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired { .. }
    ));

    harness.http.route(
        "/v1/sessions",
        json(200, r#"{"object":"list","data":[],"has_more":false}"#),
    );
    route_oidc_tokens(&harness, "token-2", 3_600);
    harness.advance(3_600_000);
    assert!(
        matches!(last_phase(&harness), ConnectionPhase::Connected { .. }),
        "{:?}",
        last_phase(&harness)
    );
}

#[test]
fn a_reconnect_after_a_lost_race_that_fails_is_reported_and_renewal_stops() {
    let mut harness = oidc_server();
    sign_in_oidc(&mut harness);
    harness
        .http
        .route("/v1/sessions", json(401, r#"{"detail":"expired"}"#));
    harness.core.refresh_sessions();
    harness.pump();
    harness.http.route("/v1/me", json(500, "{}"));
    harness.advance(3_600_000);
    assert_eq!(connection_errors(&harness).len(), 1);
    let refreshes = harness.http.count("/oauth/token");
    harness.advance(86_400_000);
    assert_eq!(harness.http.count("/oauth/token"), refreshes);
}

#[test]
fn a_renewed_token_that_cannot_be_used_is_reported_and_not_rotated() {
    let mut harness = oidc_server();
    let inner = Arc::clone(&harness.core.inner);
    sign_in_oidc(&mut harness);
    let resolved = inner.resolved().unwrap();
    let generation = lock(&inner.auth).generation;
    harness.events.take();
    let used = harness.run(async move {
        inner
            .rotate_credential(
                generation,
                &resolved,
                SecretString::new("not a\nheader"),
                None,
            )
            .await
    });
    assert!(!used);
    assert!(
        !harness
            .events
            .all()
            .iter()
            .any(|event| matches!(event, CoreEvent::CredentialRotated { .. }))
    );
    assert_eq!(connection_errors(&harness).len(), 1);
}

#[test]
fn renewal_and_rotation_of_an_old_generation_do_nothing() {
    let mut harness = oidc_server();
    let inner = Arc::clone(&harness.core.inner);
    sign_in_oidc(&mut harness);
    let resolved = inner.resolved().unwrap();
    let generation = lock(&inner.auth).generation;
    harness.core.disconnect();
    harness.pump();
    let old = Arc::clone(&inner);
    let rotating = resolved.clone();
    let used = harness.run(async move {
        old.rotate_credential(generation, &rotating, SecretString::new("t"), None)
            .await
    });
    assert!(!used);
    let refreshes = harness.http.count("/oauth/token");
    let server = OidcServer::new(SERVER).unwrap();
    harness.run(inner.renew(generation, resolved, server));
    assert_eq!(harness.http.count("/oauth/token"), refreshes);
}

#[test]
fn renewal_is_a_no_op_in_the_demo() {
    let mut harness = Harness::demo();
    let inner = Arc::clone(&harness.core.inner);
    harness
        .call(|core| async move { core.connect(String::new(), None).await })
        .unwrap();
    let resolved = inner.resolved().unwrap();
    let generation = lock(&inner.auth).generation;
    let server = OidcServer::new(SERVER).unwrap();
    harness.events.take();
    harness.run(inner.renew(generation, resolved, server));
    assert_eq!(phases(&harness.events.take()), []);
}

#[test]
fn the_demo_offers_no_credential_operations() {
    let mut harness = Harness::demo();
    harness
        .call(|core| async move { core.connect(String::new(), None).await })
        .unwrap();
    let inner = &harness.core.inner;
    assert!(matches!(inner.store(), Err(CoreError::InvalidState { .. })));
    assert!(matches!(
        inner.entropy(),
        Err(CoreError::InvalidState { .. })
    ));
    assert!(matches!(inner.oidc(), Err(CoreError::InvalidState { .. })));
    assert_eq!(format!("{:?}", harness.core), "ClientCore");
    let error = harness
        .call(|core| async move { core.begin_browser_login().await })
        .unwrap_err();
    assert!(matches!(error, CoreError::InvalidState { .. }), "{error:?}");
    let error = harness
        .call(|core| async move {
            core.create_terminal("demo-design".into(), "zsh".into())
                .await
        })
        .unwrap_err();
    assert!(matches!(error, CoreError::InvalidState { .. }), "{error:?}");
}

fn superseded_at(hold_path: &str) {
    let mut harness = oidc_server();
    sign_in_oidc(&mut harness);
    harness.core.disconnect();
    harness.pump();
    harness.events.take();
    let release = harness.http.hold(hold_path);
    let core = Arc::clone(&harness.core);
    let first = harness.start(async move { core.connect(SERVER.into(), None).await });
    assert!(first.borrow().is_none(), "{hold_path}");
    harness.core.disconnect();
    harness.pump();
    // A refresh in flight is shared per origin, so the newer connect may wait on the older's.
    let core = Arc::clone(&harness.core);
    let newer = harness.start(async move { core.connect(SERVER.into(), None).await });
    release.send(()).unwrap();
    harness.pump();
    let newer = newer.borrow_mut().take().expect("the newer connect ended");
    let older = first.borrow_mut().take().expect("the older connect ended");
    assert!(
        matches!(older, Err(CoreError::InvalidState { .. })),
        "{hold_path}: {older:?}"
    );
    assert!(
        matches!(newer, Ok(ConnectionPhase::Connected { .. })),
        "{hold_path}: {newer:?}"
    );
    assert!(
        matches!(last_phase(&harness), ConnectionPhase::Connected { .. }),
        "{hold_path}"
    );
}

#[test]
fn a_newer_connect_wins_at_every_await_of_an_older_one() {
    for path in [
        "/.well-known/omnigent.json",
        "/v1/info",
        "/oauth/token",
        "/v1/me",
    ] {
        superseded_at(path);
    }
}

#[test]
fn a_discovery_failure_that_lost_to_a_newer_connect_reports_nothing() {
    let mut harness = oidc_server();
    let release = harness.http.hold("/.well-known/omnigent.json");
    harness
        .http
        .fail_next("/.well-known/omnigent.json", offline());
    let core = Arc::clone(&harness.core);
    let first = harness.start(async move { core.connect(SERVER.into(), None).await });
    harness.core.disconnect();
    harness.pump();
    release.send(()).unwrap();
    harness.pump();
    let older = first.borrow_mut().take().unwrap();
    assert!(
        matches!(older, Err(CoreError::InvalidState { .. })),
        "{older:?}"
    );
    assert_eq!(last_phase(&harness), ConnectionPhase::Disconnected);
}

#[test]
fn servers_this_client_cannot_sign_in_to_fail_clearly() {
    for (manifest, info) in [
        (
            r#"{"manifest_version":1,"auth":{"mode":"future-mode"}}"#,
            r#"{"single_user":false,"accounts_enabled":false}"#,
        ),
        (
            r#"{"manifest_version":1,"auth":{"mode":"header"}}"#,
            r#"{"single_user":false,"accounts_enabled":false}"#,
        ),
    ] {
        let mut harness = Harness::new(UrlPolicy::Development);
        harness
            .http
            .route("/.well-known/omnigent.json", json(200, manifest));
        harness.http.route("/v1/info", json(200, info));
        let error = connect(&mut harness).unwrap_err();
        assert!(matches!(error, CoreError::Auth { .. }), "{error:?}");
        assert!(matches!(
            last_phase(&harness),
            ConnectionPhase::Failed { .. }
        ));
    }
}

#[test]
fn a_rejected_token_asks_for_sign_in_and_a_broken_server_fails() {
    let mut harness = accounts_server();
    connect(&mut harness).unwrap();
    harness.http.route("/v1/me", json(401, "{}"));
    let error = harness
        .call(|core| async move { core.sign_in_with_password("ada".into(), "pw".into()).await })
        .unwrap_err();
    assert!(error.requires_sign_in(), "{error:?}");
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired {
            reason: Some(_),
            ..
        }
    ));

    harness.http.route("/v1/me", json(500, "{}"));
    let error = harness
        .call(|core| async move { core.sign_in_with_password("ada".into(), "pw".into()).await })
        .unwrap_err();
    assert!(!error.requires_sign_in(), "{error:?}");
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::Failed { .. }
    ));
}

#[test]
fn an_unreadable_account_credential_asks_to_sign_in_with_the_reason() {
    let mut harness = accounts_server();
    let phase = harness
        .call(|core| async move { core.connect(SERVER.into(), Some("u1".into())).await })
        .unwrap();
    assert!(
        matches!(phase, ConnectionPhase::SignInRequired { reason: None, .. }),
        "{phase:?}"
    );
    *lock(&harness.store.get_failure) = Some(locked());
    let phase = harness
        .call(|core| async move { core.connect(SERVER.into(), Some("u1".into())).await })
        .unwrap();
    assert!(
        matches!(
            phase,
            ConnectionPhase::SignInRequired {
                reason: Some(CoreError::Auth { .. }),
                ..
            }
        ),
        "{phase:?}"
    );
}

#[test]
fn a_refused_password_returns_to_sign_in() {
    let mut harness = accounts_server();
    connect(&mut harness).unwrap();
    harness
        .http
        .route("/auth/login", json(401, r#"{"detail":"wrong password"}"#));
    let error = harness
        .call(|core| async move { core.sign_in_with_password("ada".into(), "no".into()).await })
        .unwrap_err();
    assert!(
        matches!(last_phase(&harness), ConnectionPhase::SignInRequired { reason: Some(ref reason), .. } if *reason == error)
    );
    harness.http.fail_next("/auth/login", offline());
    let error = harness
        .call(|core| async move { core.sign_in_with_password("ada".into(), "no".into()).await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Auth { .. }), "{error:?}");
    assert_eq!(lock(&harness.store.items).len(), 0);
}

#[test]
fn a_password_sign_in_whose_credential_cannot_be_saved_says_why() {
    let mut harness = accounts_server();
    connect(&mut harness).unwrap();
    *lock(&harness.store.set_failure) = Some(locked());
    let error = harness
        .call(|core| async move { core.sign_in_with_password("ada".into(), "pw".into()).await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Auth { .. }), "{error:?}");
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired {
            reason: Some(_),
            ..
        }
    ));
    assert_eq!(harness.http.count("/v1/me"), 0);
}

#[test]
fn a_disconnect_during_a_password_sign_in_wins_at_each_await() {
    let mut harness = accounts_server();
    connect(&mut harness).unwrap();
    let release = harness.http.hold("/auth/login");
    let core = Arc::clone(&harness.core);
    let pending =
        harness.start(async move { core.sign_in_with_password("ada".into(), "pw".into()).await });
    harness.core.disconnect();
    harness.pump();
    release.send(()).unwrap();
    harness.pump();
    let result = pending.borrow_mut().take().unwrap();
    assert!(
        matches!(result, Err(CoreError::InvalidState { .. })),
        "{result:?}"
    );
    assert_eq!(last_phase(&harness), ConnectionPhase::Disconnected);
    assert_eq!(lock(&harness.store.items).len(), 0, "nothing was saved");

    // The save fails after a newer disconnect: the sign-in screen does not come back.
    connect(&mut harness).unwrap();
    let release = harness.store.hold_set();
    *lock(&harness.store.set_failure) = Some(locked());
    let core = Arc::clone(&harness.core);
    let pending =
        harness.start(async move { core.sign_in_with_password("ada".into(), "pw".into()).await });
    harness.core.disconnect();
    harness.pump();
    release.send(()).unwrap();
    harness.pump();
    let result = pending.borrow_mut().take().unwrap();
    assert!(matches!(result, Err(CoreError::Auth { .. })), "{result:?}");
    assert_eq!(last_phase(&harness), ConnectionPhase::Disconnected);

    // The save succeeds after a newer disconnect: the connection never starts.
    connect(&mut harness).unwrap();
    *lock(&harness.store.set_failure) = None;
    let release = harness.store.hold_set();
    let core = Arc::clone(&harness.core);
    let pending =
        harness.start(async move { core.sign_in_with_password("ada".into(), "pw".into()).await });
    harness.core.disconnect();
    harness.pump();
    release.send(()).unwrap();
    harness.pump();
    let result = pending.borrow_mut().take().unwrap();
    assert!(
        matches!(result, Err(CoreError::InvalidState { .. })),
        "{result:?}"
    );
    assert_eq!(harness.http.count("/v1/me"), 0);
}

fn ticket_body(expires_in: u64) -> String {
    serde_json::json!({
        "ticket": "t-1",
        "login_url": "/auth/cli-consent?ticket=t-1",
        "user_code": "ABCD-EFGH",
        "expires_in": expires_in,
    })
    .to_string()
}

fn begin_ticket(harness: &mut Harness) -> BrowserLoginInfo {
    harness
        .http
        .route("/auth/cli-login", json(200, &ticket_body(600)));
    harness.http.route("/auth/cli-poll", json(202, "{}"));
    harness
        .call(|core| async move { core.begin_browser_login().await })
        .unwrap()
}

fn approve_ticket(harness: &Harness) {
    harness.http.route(
        "/auth/cli-poll",
        json(
            200,
            r#"{"token":"tok-b","expires_in":3600,"user":{"id":"ada"}}"#,
        ),
    );
}

#[test]
fn a_browser_ticket_polls_until_approved_then_connects() {
    let mut harness = oidc_server();
    connect(&mut harness).unwrap();
    let info = begin_ticket(&mut harness);
    assert_eq!(info.user_code.as_deref(), Some("ABCD-EFGH"));
    assert!(info.login_url.contains("/auth/cli-consent"));
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::AwaitingBrowserLogin { .. }
    ));
    harness.advance(2_000);
    harness.advance(2_000);
    assert_eq!(harness.http.count("/auth/cli-poll"), 2);
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::AwaitingBrowserLogin { .. }
    ));

    approve_ticket(&harness);
    harness.advance(2_000);
    assert!(
        matches!(last_phase(&harness), ConnectionPhase::Connected { .. }),
        "{:?}",
        last_phase(&harness)
    );
    assert_eq!(lock(&harness.store.items).len(), 1);
    let polls = harness.http.count("/auth/cli-poll");
    harness.advance(10_000);
    assert_eq!(
        harness.http.count("/auth/cli-poll"),
        polls,
        "polling stopped"
    );
}

#[test]
fn a_ticket_keeps_polling_through_transient_failures_and_reports_them() {
    let mut harness = oidc_server();
    connect(&mut harness).unwrap();
    begin_ticket(&mut harness);
    harness.http.fail_next("/auth/cli-poll", offline());
    harness.advance(2_000);
    harness.http.route("/auth/cli-poll", json(503, "{}"));
    harness.advance(2_000);
    assert_eq!(connection_errors(&harness).len(), 2);
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::AwaitingBrowserLogin { .. }
    ));
    approve_ticket(&harness);
    harness.advance(2_000);
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::Connected { .. }
    ));
}

#[test]
fn a_ticket_that_expires_or_is_refused_returns_to_sign_in() {
    let mut harness = oidc_server();
    connect(&mut harness).unwrap();
    begin_ticket(&mut harness);
    harness.advance(600_000);
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired {
            reason: Some(CoreError::Auth { .. }),
            ..
        }
    ));
    let polls = harness.http.count("/auth/cli-poll");
    harness.advance(10_000);
    assert_eq!(harness.http.count("/auth/cli-poll"), polls);

    begin_ticket(&mut harness);
    harness
        .http
        .route("/auth/cli-poll", json(403, r#"{"error":"proof refused"}"#));
    harness.advance(2_000);
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired {
            reason: Some(CoreError::Auth { .. }),
            ..
        }
    ));
}

#[test]
fn a_ticket_whose_credential_cannot_be_saved_still_connects_and_reports_it() {
    let mut harness = oidc_server();
    connect(&mut harness).unwrap();
    begin_ticket(&mut harness);
    *lock(&harness.store.set_failure) = Some(locked());
    approve_ticket(&harness);
    harness.advance(2_000);
    assert_eq!(connection_errors(&harness).len(), 1);
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::Connected { .. }
    ));
}

#[test]
fn a_ticket_that_cannot_connect_reports_it() {
    let mut harness = oidc_server();
    connect(&mut harness).unwrap();
    begin_ticket(&mut harness);
    harness.http.route("/v1/me", json(500, "{}"));
    approve_ticket(&harness);
    harness.advance(2_000);
    assert_eq!(connection_errors(&harness).len(), 1);
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::Failed { .. }
    ));
}

#[test]
fn starting_a_ticket_reports_every_refusal() {
    let mut harness = oidc_server();
    connect(&mut harness).unwrap();
    harness.http.fail_next("/auth/cli-login", offline());
    let error = harness
        .call(|core| async move { core.begin_browser_login().await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Transport { .. }), "{error:?}");
    harness.http.route("/auth/cli-login", json(200, "not json"));
    let error = harness
        .call(|core| async move { core.begin_browser_login().await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Auth { .. }), "{error:?}");
}

#[test]
fn a_disconnect_stops_a_ticket_at_each_await() {
    let mut harness = oidc_server();
    connect(&mut harness).unwrap();
    // While the ticket is being issued.
    harness
        .http
        .route("/auth/cli-login", json(200, &ticket_body(600)));
    let release = harness.http.hold("/auth/cli-login");
    let core = Arc::clone(&harness.core);
    let pending = harness.start(async move { core.begin_browser_login().await });
    harness.core.disconnect();
    harness.pump();
    release.send(()).unwrap();
    harness.pump();
    let result = pending.borrow_mut().take().unwrap();
    assert!(
        matches!(result, Err(CoreError::InvalidState { .. })),
        "{result:?}"
    );
    assert_eq!(last_phase(&harness), ConnectionPhase::Disconnected);

    // During the wait between polls.
    connect(&mut harness).unwrap();
    begin_ticket(&mut harness);
    harness.core.disconnect();
    harness.pump();
    let polls = harness.http.count("/auth/cli-poll");
    harness.advance(10_000);
    assert_eq!(harness.http.count("/auth/cli-poll"), polls);

    // While a poll is in flight, even an approved one.
    connect(&mut harness).unwrap();
    begin_ticket(&mut harness);
    approve_ticket(&harness);
    let release = harness.http.hold("/auth/cli-poll");
    harness.advance(2_000);
    harness.core.disconnect();
    harness.pump();
    release.send(()).unwrap();
    harness.pump();
    assert_eq!(last_phase(&harness), ConnectionPhase::Disconnected);
    assert_eq!(lock(&harness.store.items).len(), 0);
}

#[test]
fn signing_out_of_oidc_revokes_and_reports_what_failed() {
    let mut harness = oidc_server();
    sign_in_oidc(&mut harness);
    harness
        .core
        .update_composer("s1".into(), "draft".into())
        .unwrap();
    harness
        .call(|core| async move { core.sign_out().await })
        .unwrap();
    assert_eq!(harness.http.count("/oauth/revoke"), 1);
    assert_eq!(lock(&harness.store.items).len(), 0);
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired { reason: None, .. }
    ));

    // The revoke fails: the local sign-out still holds.
    sign_in_oidc(&mut harness);
    harness.http.route("/oauth/revoke", json(500, "{}"));
    harness.events.take();
    harness
        .call(|core| async move { core.sign_out().await })
        .unwrap();
    assert_eq!(connection_errors(&harness).len(), 1);

    // The store cannot be read or cleared: reported, and the grant's delete failure is returned.
    sign_in_oidc(&mut harness);
    harness.events.take();
    *lock(&harness.store.get_failure) = Some(locked());
    *lock(&harness.store.delete_failure) = Some(locked());
    let error = harness
        .call(|core| async move { core.sign_out().await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Oidc { .. }), "{error:?}");
    assert_eq!(connection_errors(&harness).len(), 1);
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired { .. }
    ));
}

#[test]
fn signing_out_of_accounts_removes_only_the_signed_in_users_credential() {
    let mut harness = accounts_server();
    connect(&mut harness).unwrap();
    harness
        .call(|core| async move { core.sign_in_with_password("ada".into(), "pw".into()).await })
        .unwrap();
    assert_eq!(lock(&harness.store.items).len(), 1);
    lock(&harness.store.items).insert(store_key("accounts", "other"), vec![1]);
    harness
        .call(|core| async move { core.sign_out().await })
        .unwrap();
    let items = lock(&harness.store.items).clone();
    assert_eq!(items.len(), 1);
    assert!(items.contains_key(&store_key("accounts", "other")));

    // Nobody is signed in: nothing to delete, and signing out twice is harmless.
    harness
        .call(|core| async move { core.sign_out().await })
        .unwrap();
    assert_eq!(lock(&harness.store.items).len(), 1);

    // A failed delete is the sign-out's error; the screen still returns to sign-in.
    connect(&mut harness).unwrap();
    harness
        .call(|core| async move { core.sign_in_with_password("ada".into(), "pw".into()).await })
        .unwrap();
    *lock(&harness.store.delete_failure) = Some(locked());
    let error = harness
        .call(|core| async move { core.sign_out().await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Auth { .. }), "{error:?}");
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired { .. }
    ));
}

#[test]
fn signing_out_of_a_local_server_returns_to_the_connect_screen_state() {
    let mut harness = crate::test_support::connected();
    harness
        .call(|core| async move { core.sign_out().await })
        .unwrap();
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired { .. }
    ));
    assert!(!harness.core.sessions().is_connected());
}

#[test]
fn discovery_reports_the_server_and_every_auth_mode() {
    let mut harness = oidc_server();
    let discovery = harness
        .call(|core| async move { core.discover_server(SERVER.into()).await })
        .unwrap();
    assert_eq!(discovery.base_url, SERVER);
    assert_eq!(discovery.server_name.as_deref(), Some("Lab"));
    assert_eq!(discovery.auth_mode, Some(AuthMode::Oidc));
    assert_eq!(
        discovery.native_redirect_uris,
        vec!["ai.omnigent.ios:/callback".to_owned()]
    );
    for (mode, expected) in [
        (core::AuthMode::Oidc, AuthMode::Oidc),
        (core::AuthMode::Accounts, AuthMode::Accounts),
        (core::AuthMode::Header, AuthMode::Header),
        (core::AuthMode::Custom, AuthMode::Custom),
        (core::AuthMode::None, AuthMode::Unauthenticated),
        (
            core::AuthMode::Unknown {
                value: "future".into(),
            },
            AuthMode::Unknown {
                value: "future".into(),
            },
        ),
    ] {
        assert_eq!(AuthMode::from(mode), expected);
    }
    let error = harness
        .call(|core| async move { core.discover_server("::not a url::".into()).await })
        .unwrap_err();
    assert!(matches!(error, CoreError::InvalidUrl { .. }), "{error:?}");
}

#[test]
fn the_store_namespaces_are_the_three_credential_flows() {
    let namespaces = secure_store_namespaces();
    assert_eq!(namespaces.len(), 3);
    for namespace in ["oidc", "accounts", "databricks"] {
        assert!(
            namespaces.iter().any(|known| known == namespace),
            "{namespaces:?}"
        );
    }
    drop(HostKey {
        namespace: String::new(),
        account: String::new(),
    });
}

#[test]
fn the_composer_calls_need_a_connection() {
    let mut harness = Harness::new(UrlPolicy::Development);
    let core = &harness.core;
    assert!(core.composer_text("s1".into()).is_err());
    assert!(core.update_composer("s1".into(), "x".into()).is_err());
    assert!(core.is_send_blocked("s1".into()).is_err());
    assert!(core.acknowledge_uncertain_send("s1".into()).is_err());
    assert!(core.attachment_draft("s1".into()).is_err());
    assert!(core.remove_attachment("s1".into(), 1).is_err());
    let error = harness
        .call(|core| async move { core.interrupt("s1".into()).await })
        .unwrap_err();
    assert!(error.requires_sign_in(), "{error:?}");
    let error = harness
        .call(|core| async move { core.pending_decisions("s1".into()).await })
        .unwrap_err();
    assert!(error.requires_sign_in(), "{error:?}");
    let error = harness
        .call(|core| async move { core.attachment_preview("s1".into(), "file_1".into()).await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Session { .. }), "{error:?}");
}

const SESSION: &str = "session_a";

fn writable() -> Harness {
    let harness = crate::test_support::connected();
    harness.writable_session(SESSION);
    harness
}

#[test]
fn composer_text_survives_a_send_and_the_block_clears() {
    let mut harness = writable();
    let core = &harness.core;
    core.update_composer(SESSION.into(), "hello".into())
        .unwrap();
    assert_eq!(core.composer_text(SESSION.into()).unwrap(), "hello");
    assert!(!core.is_send_blocked(SESSION.into()).unwrap());
    assert!(!core.acknowledge_uncertain_send(SESSION.into()).unwrap());
    let sent = harness
        .call(|core| async move { core.send_message(SESSION.into(), "hello".into()).await })
        .unwrap();
    assert!(sent.queued);
    assert_eq!(sent.item_id.as_deref(), Some("i1"));
    assert_eq!(sent.pending_id.as_deref(), Some("p1"));
    assert_eq!(sent.draft, "");

    let sent = harness
        .call(|core| async move {
            core.send_message_mentioning(
                SESSION.into(),
                "look".into(),
                Some("claude-code".into()),
                vec!["src/a.rs".into()],
            )
            .await
        })
        .unwrap();
    assert!(sent.queued);
    let (line, body) = harness.last_request();
    assert_eq!(line, format!("POST /v1/sessions/{SESSION}/events"));
    assert!(body.to_string().contains("src/a.rs"), "{body}");
}

#[test]
fn an_unclear_send_blocks_the_next_until_it_is_acknowledged() {
    let mut harness = writable();
    let events = format!("/v1/sessions/{SESSION}/events");
    harness.http.fail_next(&events, offline());
    let error = harness
        .call(|core| async move { core.send_message(SESSION.into(), "once".into()).await })
        .unwrap_err();
    assert!(
        matches!(
            error,
            CoreError::Session {
                delivery_uncertain: true,
                ..
            }
        ),
        "{error:?}"
    );
    assert!(harness.core.is_send_blocked(SESSION.into()).unwrap());
    let error = harness
        .call(|core| async move { core.send_message(SESSION.into(), "twice".into()).await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Session { .. }), "{error:?}");
    assert_eq!(harness.http.count(&events), 1, "never sent twice");
    assert!(
        harness
            .core
            .acknowledge_uncertain_send(SESSION.into())
            .unwrap()
    );
    assert!(!harness.core.is_send_blocked(SESSION.into()).unwrap());
}

#[test]
fn the_mentioning_send_reports_failures_and_interrupt_posts_a_cancel() {
    let mut harness = writable();
    let error = harness
        .call(|core| async move {
            core.send_message_mentioning("bad id".into(), "x".into(), None, Vec::new())
                .await
        })
        .unwrap_err();
    assert!(matches!(error, CoreError::Session { .. }), "{error:?}");
    harness
        .call(|core| async move { core.interrupt(SESSION.into()).await })
        .unwrap();
    assert_eq!(
        harness.last_request_line(),
        format!("POST /v1/sessions/{SESSION}/events")
    );
    let decisions = harness
        .call(|core| async move { core.pending_decisions(SESSION.into()).await })
        .unwrap();
    assert_eq!(decisions.len(), 0);
    let error = harness
        .call(|core| async move {
            core.resolve_decision(
                SESSION.into(),
                "missing".into(),
                DecisionResponse::Answer { value: "y".into() },
            )
            .await
        })
        .unwrap_err();
    assert!(matches!(error, CoreError::Session { .. }), "{error:?}");
}

#[test]
fn the_demo_keeps_replying_after_a_mentioning_send() {
    let mut harness = Harness::demo();
    harness
        .call(|core| async move { core.connect(String::new(), None).await })
        .unwrap();
    harness.core.open_session("demo-question".into());
    harness.pump();
    harness
        .call(|core| async move {
            core.resolve_decision(
                "demo-question".into(),
                "decision-question".into(),
                DecisionResponse::Answer {
                    value: "Approvals first".into(),
                },
            )
            .await
        })
        .unwrap();
    harness.events.take();
    harness
        .call(|core| async move {
            core.send_message_mentioning(
                "demo-question".into(),
                "tell me more".into(),
                None,
                vec!["README.md".into()],
            )
            .await
        })
        .unwrap();
    for _ in 0..200 {
        harness.advance(crate::engine::DEMO_TICK_MS);
    }
    let events = harness.events.take();
    assert!(
        events.iter().any(|event| matches!(
            event,
            CoreEvent::TranscriptChanged { session_id, .. } if session_id == "demo-question"
        )),
        "the reply streamed"
    );
}

#[test]
fn staging_uploading_and_removing_attachments() {
    let mut harness = writable();
    let core = Arc::clone(&harness.core);
    let id = core
        .add_attachment(
            SESSION.into(),
            "notes.txt".into(),
            Some("text/plain".into()),
            b"notes".to_vec(),
        )
        .unwrap();
    let draft = core.attachment_draft(SESSION.into()).unwrap();
    assert_eq!(draft.selection_error, None);
    assert_eq!(draft.items[0].filename, "notes.txt");
    assert_eq!(draft.items[0].byte_count, 5);
    assert_eq!(draft.items[0].status, UploadStatus::Staged);
    assert!(!draft.items[0].is_image);

    // An unknown item is refused before any request.
    let error = core.remove_attachment(SESSION.into(), id + 1).unwrap_err();
    assert!(matches!(error, CoreError::Session { .. }), "{error:?}");

    let files = format!("/v1/sessions/{SESSION}/resources/files");
    harness
        .http
        .route(&files, json(400, r#"{"detail":"refused"}"#));
    let upload = Arc::clone(&core);
    let error = harness
        .run(async move { upload.upload_first_attachment(SESSION.into(), id).await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Session { .. }), "{error:?}");
    let draft = core.attachment_draft(SESSION.into()).unwrap();
    assert!(
        matches!(draft.items[0].status, UploadStatus::Failed { .. }),
        "{:?}",
        draft.items[0].status
    );

    // The answer never arrived, so the file may already be stored.
    harness.http.fail_next(&files, offline());
    let upload = Arc::clone(&core);
    harness
        .run(async move { upload.upload_attachment(SESSION.into(), id).await })
        .unwrap_err();
    let draft = core.attachment_draft(SESSION.into()).unwrap();
    assert!(
        matches!(draft.items[0].status, UploadStatus::Uncertain { .. }),
        "{:?}",
        draft.items[0].status
    );
    core.remove_attachment(SESSION.into(), id).unwrap();
    assert_eq!(
        core.attachment_draft(SESSION.into()).unwrap().items.len(),
        0
    );

    let id = core
        .add_attachment(SESSION.into(), "a.txt".into(), None, b"a".to_vec())
        .unwrap();
    harness.http.route(
        &files,
        json(
            201,
            &serde_json::json!({"id": "file_1", "metadata": {"filename": "a.txt"}, "session_id": SESSION, "media_type": "text/plain", "size_bytes": 1}).to_string(),
        ),
    );
    let upload = Arc::clone(&core);
    harness
        .run(async move { upload.upload_attachment(SESSION.into(), id).await })
        .unwrap();
    let draft = core.attachment_draft(SESSION.into()).unwrap();
    assert_eq!(
        draft.items[0].status,
        UploadStatus::Uploaded {
            file_id: "file_1".into()
        }
    );

    // A boundary needs randomness.
    let id = core
        .add_attachment(SESSION.into(), "b.txt".into(), None, b"b".to_vec())
        .unwrap();
    harness
        .entropy
        .failing
        .store(true, std::sync::atomic::Ordering::SeqCst);
    let upload = Arc::clone(&core);
    let error = harness
        .run(async move { upload.upload_attachment(SESSION.into(), id).await })
        .unwrap_err();
    assert!(!matches!(error, CoreError::Session { .. }), "{error:?}");

    let refused = core.add_attachment(SESSION.into(), String::new(), None, Vec::new());
    assert!(refused.is_err(), "{refused:?}");
}

#[test]
fn attachment_previews_fetch_only_this_sessions_files() {
    let mut harness = writable();
    let file = format!("/v1/sessions/{SESSION}/resources/files/file_1/content");
    harness.http.route(
        &file,
        crate::http::HttpResponse {
            status: 200,
            headers: vec![crate::http::HttpHeader {
                name: "Content-Type".into(),
                value: "image/png".into(),
            }],
            body: vec![1, 2, 3],
        },
    );
    let preview = harness
        .call(|core| async move {
            core.attachment_preview(SESSION.into(), "file_1".into())
                .await
        })
        .unwrap();
    assert_eq!(preview.data, vec![1, 2, 3]);
    assert_eq!(preview.file_extension, "png");
    let error = harness
        .call(|core| async move {
            core.attachment_preview(SESSION.into(), "https://evil.example/x.png".into())
                .await
        })
        .unwrap_err();
    assert!(matches!(error, CoreError::Session { .. }), "{error:?}");
}
