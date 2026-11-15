//! A sandbox session's operations: the request each sends and what each answer means.

use futures::executor::block_on;
use serde_json::json;

use super::SessionError;
use super::test_support::{
    Reply, RouteTransport, body_json, cache_row, connected, lines_after_connect,
};
use crate::sandbox_state::{SandboxOperation, SandboxOperationOutcome};

const EVENTS: &str = "/v1/sessions/conv_a/events";

#[test]
fn wake_posts_retry_session_and_stop_posts_stop_session_once_each() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "POST",
        EVENTS,
        vec![
            Reply::json(
                202,
                r#"{"queued":false,"recovered":true,"recovery":"runner_relaunched"}"#,
            ),
            Reply::json(
                202,
                r#"{"queued":false,"recovered":false,"recovery":"already_connected"}"#,
            ),
            Reply::json(202, r#"{"queued":false}"#),
        ],
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.sandbox_operation("conv_a", SandboxOperation::Wake)),
        Ok(SandboxOperationOutcome::Started)
    );
    assert_eq!(
        block_on(core.sandbox_operation("conv_a", SandboxOperation::Wake)),
        Ok(SandboxOperationOutcome::AlreadyRunning)
    );
    assert_eq!(
        block_on(core.sandbox_operation("conv_a", SandboxOperation::Stop)),
        Ok(SandboxOperationOutcome::Stopped)
    );
    let bodies: Vec<_> = core.transport().writes().iter().map(body_json).collect();
    assert_eq!(
        bodies,
        [
            json!({"type": "retry_session", "data": {}}),
            json!({"type": "retry_session", "data": {}}),
            json!({"type": "stop_session", "data": {}}),
        ]
    );
    assert_eq!(
        lines_after_connect(&core),
        ["POST /v1/sessions/conv_a/events"; 3]
    );
}

#[test]
fn an_operation_is_refused_by_a_bad_id_or_a_read_only_row_without_a_request() {
    let core = connected(RouteTransport::local());
    assert!(matches!(
        block_on(core.sandbox_operation("", SandboxOperation::Wake)),
        Err(SessionError::InvalidIdentifier { .. })
    ));
    cache_row(
        &core,
        r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":1}"#,
    );
    for operation in [SandboxOperation::Wake, SandboxOperation::Stop] {
        assert_eq!(
            block_on(core.sandbox_operation("conv_a", operation)),
            Err(SessionError::ReadOnly)
        );
    }
    assert_eq!(lines_after_connect(&core), Vec::<String>::new());
}

#[test]
fn the_servers_refusals_keep_their_reason_and_are_not_asked_again() {
    let unavailable = r#"{"error":{"code":"runner_unavailable","message":"No runner is available to recover this session."}}"#;
    let cases = [
        (403, "{}", SessionError::ReadOnly),
        (
            404,
            "{}",
            SessionError::SessionNotFound {
                session_id: "conv_a".into(),
            },
        ),
        (
            409,
            r#"{"detail":"This side chat ended."}"#,
            SessionError::Rejected {
                status: 409,
                message: "This side chat ended.".into(),
            },
        ),
        // The runner could not be brought back or reached: a refusal, not a lost write.
        (
            503,
            unavailable,
            SessionError::Rejected {
                status: 503,
                message: "No runner is available to recover this session.".into(),
            },
        ),
    ];
    for operation in [SandboxOperation::Wake, SandboxOperation::Stop] {
        for (status, body, expected) in &cases {
            let transport = RouteTransport::local();
            transport.respond(Some("POST"), EVENTS, None, Reply::json(*status, *body));
            let core = connected(transport);
            // An editor's cached row does not stand in for the server's answer.
            cache_row(
                &core,
                r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":2}"#,
            );
            assert_eq!(
                block_on(core.sandbox_operation("conv_a", operation)).as_ref(),
                Err(expected),
                "{operation:?} {status}"
            );
            assert_eq!(
                lines_after_connect(&core),
                ["POST /v1/sessions/conv_a/events"]
            );
        }
    }
}

#[test]
fn an_answer_that_says_nothing_readable_is_uncertain() {
    for (status, body, expected) in [
        // A proxy's 503 carries no reason: the event may have reached the server.
        (503, "<html>busy</html>", "answered HTTP 503"),
        (200, "5", "acknowledgement"),
        (200, "not json", "acknowledgement"),
        (200, r#"{"queued":false}"#, "`recovered` is missing"),
        (200, r#"{"recovered":"yes"}"#, "acknowledgement"),
    ] {
        let transport = RouteTransport::local();
        transport.respond(Some("POST"), EVENTS, None, Reply::json(status, body));
        let core = connected(transport);
        let result = block_on(core.sandbox_operation("conv_a", SandboxOperation::Wake));
        assert!(
            matches!(&result, Err(SessionError::DeliveryUncertain { detail })
                if detail.contains(expected)),
            "{body}: {result:?}"
        );
    }
    // A stop's answer has nothing to read: any 2xx is the stop.
    let transport = RouteTransport::local();
    transport.respond(Some("POST"), EVENTS, None, Reply::json(204, ""));
    let core = connected(transport);
    assert_eq!(
        block_on(core.sandbox_operation("conv_a", SandboxOperation::Stop)),
        Ok(SandboxOperationOutcome::Stopped)
    );
}

#[test]
fn a_conversation_read_tells_the_list_when_the_launch_moved_and_only_then() {
    use super::ClientEvent;
    use super::test_support::record;
    use crate::sandbox_state::LaunchStage;

    let session = |status: &str| {
        format!(
            r#"{{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,
                "harness":"codex-native","runner_id":null,"runner_online":false,"host_id":null,
                "sandbox_status":{status}}}"#
        )
    };
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sessions/conv_a/items",
        r#"{"data":[],"has_more":false}"#,
    );
    transport.ok(
        "/v1/sessions/conv_a",
        session(r#"{"stage":"provisioning","provider":"example"}"#),
    );
    let core = connected(transport);
    let recorder = record(&core);
    let announced = |events: Vec<ClientEvent>| -> Vec<Option<LaunchStage>> {
        events
            .into_iter()
            .filter_map(|event| match event {
                ClientEvent::SessionsChanged { sessions } => Some(
                    sessions[0]
                        .configuration
                        .as_ref()
                        .and_then(|configuration| configuration.sandbox_launch.as_ref())
                        .map(|launch| launch.stage),
                ),
                _ => None,
            })
            .collect()
    };
    block_on(core.conversation_snapshot("conv_a")).unwrap();
    assert_eq!(
        announced(recorder.take()),
        [Some(LaunchStage::Provisioning)]
    );
    // The same stage again is no news for the row.
    block_on(core.conversation_snapshot("conv_a")).unwrap();
    assert_eq!(announced(recorder.take()), []);
    core.transport()
        .ok("/v1/sessions/conv_a", session(r#"{"stage":"cloning"}"#));
    block_on(core.conversation_snapshot("conv_a")).unwrap();
    assert_eq!(announced(recorder.take()), [Some(LaunchStage::Cloning)]);
    // The launch ending is news too.
    core.transport().ok("/v1/sessions/conv_a", session("null"));
    block_on(core.conversation_snapshot("conv_a")).unwrap();
    assert_eq!(announced(recorder.take()), [None]);
}
