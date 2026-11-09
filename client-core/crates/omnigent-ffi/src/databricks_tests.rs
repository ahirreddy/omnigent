//! Databricks sign-in and renewal through the real core: a host error or a user action at each
//! await.

use std::sync::Arc;

use futures::FutureExt as _;

use super::*;
use crate::api_tests::{WORKSPACE_HOST, databricks, route_databricks};
use crate::connection::UrlPolicy;
use crate::engine::lock;
use crate::errors::DatabricksErrorKind;
use crate::test_support::{Harness, json, phases};

const TOKEN: &str = "/oidc/v1/token";

fn offline() -> crate::http::TransportError {
    crate::http::TransportError::Offline {
        message: "no route".into(),
    }
}

fn locked() -> crate::host::SecureStoreError {
    crate::host::SecureStoreError::Unavailable {
        message: "device locked".into(),
    }
}

fn connect(harness: &mut Harness) -> Result<ConnectionPhase, CoreError> {
    let core = Arc::clone(&harness.core);
    harness.run(async move { core.connect(format!("{WORKSPACE_HOST}/?o=42"), None).await })
}

fn callback_for(challenge: &DatabricksChallenge) -> String {
    let state = Url::parse(&challenge.authorize_url)
        .unwrap()
        .query_pairs()
        .find(|(name, _)| name == "state")
        .map(|(_, value)| value.into_owned())
        .unwrap();
    format!("https://login.databricks.com/mobile-redirect?state={state}&code=abc")
}

/// A harness on the sign-in screen of a workspace, the login started.
fn signing_in() -> (Harness, DatabricksChallenge) {
    let mut harness = databricks();
    route_databricks(&harness, "access-1", 3_600);
    connect(&mut harness).unwrap();
    let challenge = harness.core.begin_databricks_sign_in(None).unwrap();
    (harness, challenge)
}

fn complete(
    harness: &mut Harness,
    challenge: &DatabricksChallenge,
) -> Result<ConnectedServer, CoreError> {
    let core = Arc::clone(&harness.core);
    let attempt = challenge.attempt_id;
    let callback = callback_for(challenge);
    harness.run(async move { core.complete_databricks_sign_in(attempt, callback).await })
}

fn signed_in() -> Harness {
    let (mut harness, challenge) = signing_in();
    complete(&mut harness, &challenge).unwrap();
    harness.events.take();
    harness
}

fn last_phase(harness: &Harness) -> ConnectionPhase {
    phases(&harness.events.all()).pop().unwrap()
}

fn connection_errors(events: &[CoreEvent]) -> Vec<CoreError> {
    events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::Error {
                scope: ErrorScope::Connection,
                error,
            } => Some(error.clone()),
            _ => None,
        })
        .collect()
}

fn token_error(status: u16, code: &str) -> crate::http::HttpResponse {
    json(status, &serde_json::json!({ "error": code }).to_string())
}

#[test]
fn the_build_client_is_checked_when_a_workspace_is_used() {
    let mut harness = Harness::with_databricks(
        UrlPolicy::Release,
        Some(DatabricksOAuthSettings {
            client_id: "not a client id!".into(),
            redirect_url: "https://login.databricks.com/mobile-redirect".into(),
        }),
    );
    let error = connect(&mut harness).unwrap_err();
    assert!(matches!(error, CoreError::Databricks { .. }), "{error:?}");
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::Failed { .. }
    ));
    assert_eq!(
        format!(
            "{:?}",
            DatabricksAuth::new(&DatabricksOAuthSettings {
                client_id: "omnigent-app".into(),
                redirect_url: "https://login.databricks.com/mobile-redirect".into(),
            })
        ),
        "DatabricksAuth { configured: true, .. }"
    );
}

#[test]
fn signing_in_needs_a_workspace_and_the_right_redirect_kind() {
    let mut harness = Harness::with_databricks(
        UrlPolicy::Development,
        Some(DatabricksOAuthSettings {
            client_id: "omnigent-app".into(),
            redirect_url: "https://login.databricks.com/mobile-redirect".into(),
        }),
    );
    assert!(matches!(
        harness.core.begin_databricks_sign_in(None),
        Err(CoreError::InvalidState { .. })
    ));
    harness.local_server();
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.connect("http://127.0.0.1:6767".into(), None).await })
        .unwrap();
    assert!(matches!(
        harness.core.begin_databricks_sign_in(None),
        Err(CoreError::InvalidState { .. })
    ));

    let mut harness = databricks();
    connect(&mut harness).unwrap();
    let error = harness
        .core
        .begin_databricks_sign_in(Some(5_000))
        .unwrap_err();
    assert!(matches!(error, CoreError::InvalidState { .. }), "{error:?}");
}

#[test]
fn a_failing_rng_stops_the_login_before_it_starts() {
    let mut harness = databricks();
    connect(&mut harness).unwrap();
    harness
        .entropy
        .failing
        .store(true, std::sync::atomic::Ordering::SeqCst);
    let error = harness.core.begin_databricks_sign_in(None).unwrap_err();
    assert!(matches!(error, CoreError::Databricks { .. }), "{error:?}");
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired { .. }
    ));
}

#[test]
fn cancelling_a_login_returns_to_sign_in_once() {
    let (mut harness, challenge) = signing_in();
    harness.pump();
    harness.core.cancel_databricks_sign_in(challenge.attempt_id);
    harness.pump();
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired { reason: None, .. }
    ));
    harness.events.take();
    // The same attempt again, or one that never existed, changes nothing.
    harness.core.cancel_databricks_sign_in(challenge.attempt_id);
    harness.core.cancel_databricks_sign_in(999);
    harness.pump();
    assert_eq!(harness.events.take(), []);
    let error = complete(&mut harness, &challenge).unwrap_err();
    assert!(matches!(error, CoreError::InvalidState { .. }), "{error:?}");

    // A core with no build client has nothing to cancel.
    let mut plain = Harness::new(UrlPolicy::Development);
    plain.core.cancel_databricks_sign_in(1);
    plain.pump();
    assert_eq!(plain.events.take(), []);
}

/// A sign-in the user replaced with a newer one must not knock the sheet back to the sign-in page.
#[test]
fn a_login_replaced_during_its_code_exchange_leaves_the_new_one_in_charge() {
    let (mut harness, first) = signing_in();
    let gate = harness.http.hold(TOKEN);
    let core = Arc::clone(&harness.core);
    let (attempt, callback) = (first.attempt_id, callback_for(&first));
    let pending =
        harness.start(async move { core.complete_databricks_sign_in(attempt, callback).await });
    harness.pump();
    harness.core.begin_databricks_sign_in(None).unwrap();
    harness.pump();
    gate.send(()).unwrap();
    harness.pump();
    let result = pending.borrow_mut().take().unwrap();
    assert!(
        matches!(result, Err(CoreError::Databricks { .. })),
        "{result:?}"
    );
    assert!(
        matches!(last_phase(&harness), ConnectionPhase::SigningIn { .. }),
        "{:?}",
        last_phase(&harness)
    );
}

/// A disconnect during the slow Keychain write of a new grant wins over the sign-in.
#[test]
fn a_disconnect_while_the_grant_saves_stays_disconnected() {
    let (mut harness, challenge) = signing_in();
    let gate = harness.store.hold_set();
    let core = Arc::clone(&harness.core);
    let (attempt, callback) = (challenge.attempt_id, callback_for(&challenge));
    let pending =
        harness.start(async move { core.complete_databricks_sign_in(attempt, callback).await });
    harness.pump();
    harness.core.disconnect();
    harness.pump();
    gate.send(()).unwrap();
    harness.pump();
    assert!(pending.borrow_mut().take().unwrap().is_err());
    assert_eq!(last_phase(&harness), ConnectionPhase::Disconnected);
}

#[test]
fn a_disconnect_during_the_code_exchange_wins() {
    let (mut harness, challenge) = signing_in();
    let gate = harness.http.hold(TOKEN);
    let core = Arc::clone(&harness.core);
    let (attempt, callback) = (challenge.attempt_id, callback_for(&challenge));
    let pending =
        harness.start(async move { core.complete_databricks_sign_in(attempt, callback).await });
    harness.pump();
    harness.core.disconnect();
    harness.pump();
    gate.send(()).unwrap();
    harness.pump();
    assert!(pending.borrow_mut().take().unwrap().is_err());
    assert_eq!(last_phase(&harness), ConnectionPhase::Disconnected);
}

#[test]
fn a_refused_exchange_or_a_failed_save_returns_to_sign_in_with_the_reason() {
    let (mut harness, challenge) = signing_in();
    harness.http.route(TOKEN, token_error(400, "invalid_grant"));
    let error = complete(&mut harness, &challenge).unwrap_err();
    assert!(matches!(error, CoreError::Databricks { .. }), "{error:?}");
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired {
            reason: Some(_),
            ..
        }
    ));

    let (mut harness, challenge) = signing_in();
    *lock(&harness.store.set_failure) = Some(locked());
    let error = complete(&mut harness, &challenge).unwrap_err();
    assert!(matches!(error, CoreError::Databricks { .. }), "{error:?}");
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired {
            reason: Some(_),
            ..
        }
    ));
}

/// Offline at launch with a good grant: the app must offer Retry, not throw the user at a browser.
#[test]
fn a_network_failure_refreshing_the_saved_grant_is_not_a_sign_in_prompt() {
    let mut harness = signed_in();
    harness.core.disconnect();
    harness.pump();
    harness.advance(4_000_000);
    harness.http.fail_next(TOKEN, offline());
    let error = connect(&mut harness).unwrap_err();
    assert!(!error.requires_sign_in(), "{error:?}");
    assert!(
        matches!(last_phase(&harness), ConnectionPhase::Failed { .. }),
        "{:?}",
        last_phase(&harness)
    );
    // The grant is still there.
    route_databricks(&harness, "access-2", 3_600);
    assert!(matches!(
        connect(&mut harness),
        Ok(ConnectionPhase::Connected { .. })
    ));
}

#[test]
fn a_store_that_cannot_be_read_at_connect_reports_the_reason() {
    let mut harness = databricks();
    route_databricks(&harness, "access-1", 3_600);
    *lock(&harness.store.get_failure) = Some(locked());
    let result = connect(&mut harness);
    assert!(result.is_err(), "{result:?}");
    assert!(
        matches!(last_phase(&harness), ConnectionPhase::Failed { .. }),
        "{:?}",
        last_phase(&harness)
    );
}

#[test]
fn a_connect_replaced_during_its_refresh_reports_nothing() {
    let mut harness = signed_in();
    harness.core.disconnect();
    harness.pump();
    harness.advance(4_000_000);
    let gate = harness.http.hold(TOKEN);
    let core = Arc::clone(&harness.core);
    let first =
        harness.start(async move { core.connect(format!("{WORKSPACE_HOST}/?o=42"), None).await });
    harness.pump();
    harness.core.disconnect();
    harness.pump();
    gate.send(()).unwrap();
    harness.pump();
    assert!(first.borrow_mut().take().unwrap().is_err());
    assert_eq!(last_phase(&harness), ConnectionPhase::Disconnected);
}

#[test]
fn a_network_failure_at_renewal_keeps_the_connection_and_retries() {
    let mut harness = signed_in();
    harness.http.fail_next(TOKEN, offline());
    harness.advance(3_600_000);
    let events = harness.events.take();
    assert_eq!(connection_errors(&events).len(), 1, "{events:#?}");
    assert_eq!(phases(&events), []);

    route_databricks(&harness, "access-2", 3_600);
    harness.advance(RENEWAL_RETRY_MS);
    let events = harness.events.take();
    assert!(
        events
            .iter()
            .any(|event| matches!(event, CoreEvent::CredentialRotated { .. })),
        "{events:#?}"
    );
}

#[test]
fn a_rejected_grant_at_renewal_ends_the_connection_and_asks_to_sign_in() {
    let mut harness = signed_in();
    harness.http.route(TOKEN, token_error(400, "invalid_grant"));
    harness.advance(3_600_000);
    let phases = phases(&harness.events.take());
    assert_eq!(phases[0], ConnectionPhase::Disconnected, "{phases:?}");
    assert!(
        matches!(phases[1], ConnectionPhase::SignInRequired { .. }),
        "{phases:?}"
    );
    assert_eq!(phases.len(), 2, "{phases:?}");
}

#[test]
fn a_rotated_grant_that_cannot_be_saved_is_reported() {
    let mut harness = signed_in();
    route_databricks(&harness, "access-2", 3_600);
    *lock(&harness.store.set_failure) = Some(locked());
    harness.advance(3_600_000);
    let events = harness.events.take();
    assert!(!connection_errors(&events).is_empty(), "{events:#?}");
}

#[test]
fn a_disconnect_during_a_renewal_refresh_rotates_nothing() {
    let mut harness = signed_in();
    let gate = harness.http.hold(TOKEN);
    route_databricks(&harness, "access-2", 3_600);
    harness.advance(3_600_000);
    harness.core.disconnect();
    harness.pump();
    harness.events.take();
    gate.send(()).unwrap();
    harness.pump();
    assert!(
        !harness
            .events
            .take()
            .iter()
            .any(|event| matches!(event, CoreEvent::CredentialRotated { .. }))
    );
}

/// Signing out while a refresh is out: the rotated grant must not come back.
#[test]
fn signing_out_during_a_refresh_discards_its_result() {
    let mut harness = signed_in();
    let gate = harness.http.hold(TOKEN);
    route_databricks(&harness, "access-2", 3_600);
    harness.advance(3_600_000);
    let core = Arc::clone(&harness.core);
    harness.run(async move { core.sign_out().await }).unwrap();
    assert!(lock(&harness.store.items).is_empty());
    gate.send(()).unwrap();
    harness.pump();
    assert!(lock(&harness.store.items).is_empty(), "no grant comes back");
}

#[test]
fn signing_out_reports_a_grant_that_could_not_be_deleted() {
    let mut harness = signed_in();
    *lock(&harness.store.delete_failure) = Some(locked());
    let core = Arc::clone(&harness.core);
    let result = harness.run(async move { core.sign_out().await });
    assert!(
        matches!(result, Err(CoreError::Databricks { .. })),
        "{result:?}"
    );
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::SignInRequired { .. }
    ));
}

#[test]
fn a_kind_of_refusal_is_named() {
    let (mut harness, challenge) = signing_in();
    let core = Arc::clone(&harness.core);
    let attempt = challenge.attempt_id;
    let error = harness
        .run(async move {
            core.complete_databricks_sign_in(attempt, "not a url".into())
                .await
        })
        .unwrap_err();
    assert!(
        matches!(
            error,
            CoreError::Databricks {
                kind: DatabricksErrorKind::InvalidCallback | DatabricksErrorKind::Cancelled,
                ..
            }
        ),
        "{error:?}"
    );
}

/// Overwrites every saved grant with bytes that are not a grant.
fn corrupt_saved_grants(harness: &Harness) {
    for value in lock(&harness.store.items).values_mut() {
        *value = b"not a grant".to_vec();
    }
}

#[test]
fn a_connect_during_a_renewal_refresh_shares_its_answer() {
    let mut harness = signed_in();
    let gate = harness.http.hold(TOKEN);
    harness.advance(3_600_000);
    let refreshes = harness.http.count(TOKEN);
    let core = Arc::clone(&harness.core);
    let joined =
        harness.start(async move { core.connect(format!("{WORKSPACE_HOST}/?o=42"), None).await });
    assert!(joined.borrow().is_none(), "it waits for the same refresh");
    gate.send(()).unwrap();
    harness.pump();
    assert!(matches!(
        joined.borrow_mut().take().unwrap(),
        Ok(ConnectionPhase::Connected { .. })
    ));
    assert_eq!(harness.http.count(TOKEN), refreshes, "one refresh only");
}

#[test]
fn a_connect_while_a_rotated_grant_saves_writes_it_first() {
    let mut harness = signed_in();
    let saved_before = lock(&harness.store.items).clone();
    let gate = harness.store.hold_set();
    harness.advance(3_600_000);
    assert_eq!(*lock(&harness.store.items), saved_before);
    let phase = connect(&mut harness).unwrap();
    assert!(
        matches!(phase, ConnectionPhase::Connected { .. }),
        "{phase:?}"
    );
    assert_ne!(
        *lock(&harness.store.items),
        saved_before,
        "the second caller saved the rotated grant before using it"
    );
    gate.send(()).unwrap();
    harness.pump();
    assert!(matches!(
        last_phase(&harness),
        ConnectionPhase::Connected { .. }
    ));
}

#[test]
fn a_connect_abandoned_during_its_refresh_still_saves_the_rotated_grant() {
    let mut harness = signed_in();
    harness.core.disconnect();
    harness.pump();
    harness.advance(4_000_000);
    let saved_before = lock(&harness.store.items).clone();
    let refreshes = harness.http.count(TOKEN);
    let gate = harness.http.hold(TOKEN);
    let core = Arc::clone(&harness.core);
    let mut call =
        Box::pin(async move { core.connect(format!("{WORKSPACE_HOST}/?o=42"), None).await });
    for _ in 0..20 {
        assert!(call.as_mut().now_or_never().is_none());
        harness.pump();
        if harness.http.count(TOKEN) > refreshes {
            break;
        }
    }
    assert_eq!(harness.http.count(TOKEN), refreshes + 1);
    drop(call);
    gate.send(()).unwrap();
    harness.pump();
    assert_ne!(*lock(&harness.store.items), saved_before);
}

#[test]
fn a_saved_grant_that_cannot_be_read_asks_to_sign_in_at_connect() {
    let mut harness = signed_in();
    harness.core.disconnect();
    harness.pump();
    corrupt_saved_grants(&harness);
    let phase = connect(&mut harness).unwrap();
    let ConnectionPhase::SignInRequired { reason, .. } = phase else {
        panic!("{phase:?}");
    };
    assert!(reason.is_some());
}

#[test]
fn a_saved_grant_that_cannot_be_read_at_renewal_ends_the_connection() {
    let mut harness = signed_in();
    corrupt_saved_grants(&harness);
    harness.advance(3_600_000);
    let phases = phases(&harness.events.take());
    assert_eq!(phases[0], ConnectionPhase::Disconnected, "{phases:?}");
    assert!(
        matches!(phases[1], ConnectionPhase::SignInRequired { .. }),
        "{phases:?}"
    );
}

#[test]
fn a_renewal_that_fires_as_the_user_disconnects_sends_nothing() {
    let mut harness = signed_in();
    let refreshes = harness.http.count(TOKEN);
    harness.advance_stopping_before_spawned_work(3_600_000);
    harness.core.disconnect();
    harness.pump();
    assert_eq!(harness.http.count(TOKEN), refreshes);
    assert_eq!(last_phase(&harness), ConnectionPhase::Disconnected);
}

#[test]
fn a_session_on_a_known_host_and_the_updates_socket_carry_the_routing_key() {
    let (mut harness, challenge) = signing_in();
    harness.http.route(
        "/api/2.0/omnigent/v1/sessions",
        json(
            200,
            r#"{"object":"list","data":[{"id":"conv_a","status":"idle","title":"A","created_at":1,"updated_at":1,"permission_level":4,"host_id":"host_a"}],"has_more":false}"#,
        ),
    );
    complete(&mut harness, &challenge).unwrap();
    harness.pump();
    // The first socket opens before the first list names any host; the next one knows.
    let (_, first_socket, _) = harness.sockets.last();
    first_socket.ended(crate::host::SocketEnd::Failed {
        failure: crate::host::ConnectionFailure::Offline {
            message: "gone".into(),
        },
    });
    harness.pump();
    harness.advance(60_000);
    let (socket_request, _, _) = harness.sockets.last();
    assert!(
        socket_request.url.contains("omnigent_slice_key=host_a"),
        "{}",
        socket_request.url
    );
    harness.core.open_session("conv_a".into());
    harness.pump();
    let (_, _, stream_request) = harness.streams.last();
    assert!(
        stream_request.headers.iter().any(
            |header| header.name == omnigent_core::SLICE_KEY_HEADER && header.value == "host_a"
        ),
        "{stream_request:?}"
    );
}
