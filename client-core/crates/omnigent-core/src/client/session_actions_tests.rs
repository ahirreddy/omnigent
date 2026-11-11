//! Stop, delete and leave: the requests each sends, what refuses it, and the list change.

use futures::executor::block_on;
use serde_json::json;

use super::super::test_support::{
    Reply, RouteTransport, cache_row, connected, lines_after_connect, query_value, record,
};
use super::super::{ClientEvent, SessionError};

const OWNED_HOST_SPAWNED: &str = r#"{"id":"conv_a","status":"running","created_at":1,"permission_level":4,"host_id":"host-1","runner_id":"runner-1"}"#;

fn stop_route(transport: &RouteTransport, status: u16) {
    transport.respond(
        Some("POST"),
        "/v1/sessions/conv_a/events",
        None,
        Reply::json(status, "{}"),
    );
}

fn delete_route(transport: &RouteTransport, status: u16) {
    transport.respond(
        Some("DELETE"),
        "/v1/sessions/conv_a",
        None,
        Reply::json(status, "{}"),
    );
}

#[test]
fn stop_is_one_stop_session_post_with_or_without_a_cached_row() {
    for cached in [None, Some(OWNED_HOST_SPAWNED)] {
        let transport = RouteTransport::local();
        stop_route(&transport, 202);
        let core = connected(transport);
        if let Some(row) = cached {
            cache_row(&core, row);
        }
        block_on(core.stop_session("conv_a")).unwrap();
        assert_eq!(
            lines_after_connect(&core),
            ["POST /v1/sessions/conv_a/events"],
            "{cached:?}"
        );
        assert_eq!(
            core.transport().write_bodies(),
            vec![json!({"type": "stop_session", "data": {}})]
        );
    }
}

#[test]
fn stop_is_refused_by_a_read_only_cached_row_without_a_request() {
    let core = connected(RouteTransport::local());
    cache_row(
        &core,
        r#"{"id":"conv_a","status":"running","created_at":1,"permission_level":1}"#,
    );
    assert_eq!(
        block_on(core.stop_session("conv_a")),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(lines_after_connect(&core), Vec::<String>::new());
}

#[test]
fn a_refused_stop_reads_as_the_removed_check_did() {
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
        stop_route(&transport, status);
        let core = connected(transport);
        assert_eq!(
            block_on(core.stop_session("conv_a")),
            Err(expected),
            "{status}"
        );
    }
}

#[test]
fn delete_stops_a_session_its_cached_row_shows_stoppable_then_removes_it() {
    let transport = RouteTransport::local();
    // A failed stop does not block the delete.
    transport.respond(
        Some("POST"),
        "/v1/sessions/conv_a/events",
        None,
        Reply::json(409, r#"{"error":{"message":"runner offline"}}"#),
    );
    delete_route(&transport, 204);
    let core = connected(transport);
    cache_row(&core, OWNED_HOST_SPAWNED);
    let recorder = record(&core);
    block_on(core.delete_session("conv_a")).unwrap();
    assert_eq!(
        lines_after_connect(&core),
        [
            "POST /v1/sessions/conv_a/events",
            "DELETE /v1/sessions/conv_a"
        ]
    );
    assert!(recorder.take().iter().any(|event| matches!(
        event,
        ClientEvent::SessionsRemoved { ids } if ids == &["conv_a".to_owned()]
    )));
    assert_eq!(core.cached_summary("conv_a"), None);
}

#[test]
fn delete_is_one_request_for_a_local_runner_or_a_session_without_a_cached_row() {
    let idle = r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#;
    for cached in [None, Some(idle)] {
        let transport = RouteTransport::local();
        delete_route(&transport, 200);
        let core = connected(transport);
        if let Some(row) = cached {
            cache_row(&core, row);
        }
        block_on(core.delete_session("conv_a")).unwrap();
        assert_eq!(
            lines_after_connect(&core),
            ["DELETE /v1/sessions/conv_a"],
            "{cached:?}"
        );
        assert_eq!(
            query_value(&core.transport().writes()[0], "delete_branch"),
            None
        );
        block_on(core.delete_session_with_branch("conv_a", true)).unwrap();
        assert_eq!(
            query_value(&core.transport().writes()[1], "delete_branch").as_deref(),
            Some("true")
        );
    }
}

#[test]
fn delete_is_refused_below_owner_by_the_cached_row_without_a_request() {
    let core = connected(RouteTransport::local());
    cache_row(
        &core,
        r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":2}"#,
    );
    assert_eq!(
        block_on(core.delete_session("conv_a")),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(lines_after_connect(&core), Vec::<String>::new());
}

#[test]
fn a_refused_delete_reads_as_the_removed_check_did_and_keeps_the_session() {
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
        delete_route(&transport, status);
        let core = connected(transport);
        let recorder = record(&core);
        assert_eq!(
            block_on(core.delete_session("conv_a")),
            Err(expected),
            "{status}"
        );
        assert_eq!(recorder.take(), [], "{status}");
    }
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
