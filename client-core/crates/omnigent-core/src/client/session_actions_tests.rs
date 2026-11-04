//! Stop, delete and leave: the request each sends, its permission check, and the list change.

use futures::executor::block_on;
use serde_json::json;

use super::super::test_support::{Reply, RouteTransport, connected, path_of, record};
use super::super::{ClientEvent, SessionError};

const OWNED_HOST_SPAWNED: &str = r#"{"id":"conv_a","status":"running","created_at":1,"permission_level":4,"host_id":"host-1","runner_id":"runner-1"}"#;

#[test]
fn stop_posts_stop_session_after_an_edit_check() {
    let transport = RouteTransport::local();
    transport.ok("/v1/sessions/conv_a", OWNED_HOST_SPAWNED);
    transport.respond(
        Some("POST"),
        "/v1/sessions/conv_a/events",
        None,
        Reply::json(202, "{}"),
    );
    let core = connected(transport);
    block_on(core.stop_session("conv_a")).unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        vec![json!({"type": "stop_session", "data": {}})]
    );

    let read_only = RouteTransport::local();
    read_only.ok(
        "/v1/sessions/conv_b",
        r#"{"id":"conv_b","status":"running","created_at":1,"permission_level":1}"#,
    );
    let core = connected(read_only);
    assert_eq!(
        block_on(core.stop_session("conv_b")),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(core.transport().writes(), []);
}

#[test]
fn delete_stops_a_stoppable_session_first_then_removes_it() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("GET"),
        "/v1/sessions/conv_a",
        None,
        Reply::json(200, OWNED_HOST_SPAWNED),
    );
    // A failed stop does not block the delete.
    transport.respond(
        Some("POST"),
        "/v1/sessions/conv_a/events",
        None,
        Reply::json(409, r#"{"error":{"message":"runner offline"}}"#),
    );
    transport.respond(
        Some("DELETE"),
        "/v1/sessions/conv_a",
        None,
        Reply::json(204, ""),
    );
    let core = connected(transport);
    let recorder = record(&core);
    block_on(core.delete_session("conv_a")).unwrap();
    let writes: Vec<String> = core
        .transport()
        .writes()
        .iter()
        .map(|request| format!("{} {}", request.method, path_of(request)))
        .collect();
    assert_eq!(
        writes,
        [
            "POST /v1/sessions/conv_a/events",
            "DELETE /v1/sessions/conv_a"
        ]
    );
    assert!(recorder.take().iter().any(|event| matches!(
        event,
        ClientEvent::SessionsRemoved { ids } if ids == &["conv_a".to_owned()]
    )));
}

#[test]
fn delete_needs_owner_permission_and_skips_stop_for_a_local_runner() {
    let shared = RouteTransport::local();
    shared.ok(
        "/v1/sessions/conv_a",
        r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":2}"#,
    );
    let core = connected(shared);
    assert_eq!(
        block_on(core.delete_session("conv_a")),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(core.transport().writes(), []);

    let local = RouteTransport::local();
    local.respond(
        Some("GET"),
        "/v1/sessions/conv_a",
        None,
        Reply::json(
            200,
            r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#,
        ),
    );
    local.respond(
        Some("DELETE"),
        "/v1/sessions/conv_a",
        None,
        Reply::json(200, "{}"),
    );
    let core = connected(local);
    block_on(core.delete_session("conv_a")).unwrap();
    assert_eq!(core.transport().writes().len(), 1);
}

#[test]
fn leave_revokes_the_callers_own_grant() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("DELETE"),
        "/v1/sessions/conv_a/permissions/local",
        None,
        Reply::json(204, ""),
    );
    let core = connected(transport);
    let recorder = record(&core);
    block_on(core.leave_session("conv_a")).unwrap();
    assert_eq!(core.transport().writes().len(), 1);
    assert!(
        recorder
            .take()
            .iter()
            .any(|event| matches!(event, ClientEvent::SessionsRemoved { .. }))
    );

    let refused = RouteTransport::local();
    refused.respond(
        Some("DELETE"),
        "/v1/sessions/conv_a/permissions/local",
        None,
        Reply::json(403, "{}"),
    );
    let core = connected(refused);
    assert_eq!(
        block_on(core.leave_session("conv_a")),
        Err(SessionError::Forbidden)
    );
}
