//! Add nested agent over REST: what the create sends, what the server's refusals read as, and
//! the policy checked before anything is sent.

use futures::executor::block_on;

use crate::client::create::FirstMessage;
use crate::client::test_support::{Reply, RouteTransport, body_json, connected};
use crate::client::{ClientCore, SessionError};
use crate::creation::{CreationError, CreationSelection, SandboxTarget};
use crate::nested_creation::{CLIENT_CREATE_TOKEN_LABEL, NESTED_AGENTS_UNAVAILABLE, NestedRequest};

const TOKEN: &str = "0123456789abcdef0123456789abcdef";

#[test]
fn a_row_carries_its_create_token_until_its_labels_drop_it() {
    use crate::client::sessions::test_support::summary_of;
    let created = summary_of(
        &serde_json::json!({"labels": {CLIENT_CREATE_TOKEN_LABEL: TOKEN}}),
        None,
        true,
    );
    assert_eq!(created.client_create_token.as_deref(), Some(TOKEN));
    let kept = summary_of(&serde_json::json!({}), Some(&created), true);
    assert_eq!(kept.client_create_token.as_deref(), Some(TOKEN));
    for labels in [
        serde_json::json!({}),
        serde_json::json!({CLIENT_CREATE_TOKEN_LABEL: ""}),
        serde_json::Value::Null,
    ] {
        let cleared = summary_of(
            &serde_json::json!({ "labels": labels }),
            Some(&created),
            true,
        );
        assert_eq!(cleared.client_create_token, None);
    }
}

/// A server with two machines and a sandbox host, Codex on each, nested agents under `policy`
/// and a 201 for the create.
fn server(policy: &str) -> RouteTransport {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/info",
        format!(
            r#"{{"single_user":true,"accounts_enabled":false,"sibling_sessions":true,
                "sibling_session_destinations":"{policy}","managed_sandboxes_enabled":true,
                "sandbox_provider":"modal","request_managed_sandbox_host_id":true}}"#
        ),
    );
    let host = |id: &str, sandbox: &str| {
        format!(
            r#"{{"host_id":"{id}","name":"{id}","status":"online"{sandbox},
                "configured_harnesses":{{"codex-native":true}}}}"#
        )
    };
    transport.ok(
        "/v1/hosts",
        format!(
            r#"{{"hosts":[{},{},{}]}}"#,
            host("mac", ""),
            host("box", ""),
            host("sbx", r#","sandbox_provider":"modal""#)
        ),
    );
    transport.ok(
        "/v1/agents",
        r#"{"data":[{"id":"ag_codex","name":"Codex","harness":"codex-native"}],"has_more":false}"#,
    );
    transport.ok(
        "/v1/hosts/mac/harnesses/codex-native/model-options",
        r#"{"models":[{"id":"fast","model":"codex-fast"}]}"#,
    );
    transport.respond(
        Some("POST"),
        "/v1/sessions",
        None,
        Reply::json(
            201,
            r#"{"id":"conv_new","status":"idle","created_at":1,"agent_id":"ag_codex",
                "host_id":"mac","permission_level":4}"#,
        ),
    );
    transport
}

fn selection(host_id: &str) -> CreationSelection {
    CreationSelection {
        host_id: host_id.into(),
        agent_id: "ag_codex".into(),
        workspace: "/work/app".into(),
        project_id: Some("proj_ignored".into()),
        ..CreationSelection::default()
    }
}

fn request(source_host: &str) -> NestedRequest {
    NestedRequest {
        source_id: "conv_source".into(),
        source_host_id: Some(source_host.into()),
        client_token: TOKEN.into(),
    }
}

fn posts(core: &ClientCore<RouteTransport>) -> usize {
    core.transport().writes().len()
}

#[test]
fn the_create_names_the_source_and_token_and_files_no_project() {
    let core = connected(server("current_host"));
    let receipt =
        block_on(core.create_nested_session(&selection("mac"), &request("mac"), " ", None))
            .unwrap();
    assert_eq!(receipt.session_id, "conv_new");
    let body = body_json(&core.transport().writes()[0]);
    assert_eq!(body["sibling_source_id"], "conv_source");
    assert_eq!(body["host_id"], "mac");
    assert_eq!(body["workspace"], "/work/app");
    assert_eq!(body["labels"][CLIENT_CREATE_TOKEN_LABEL], TOKEN);
    for absent in ["project_id", "initial_items", "parent_session_id", "title"] {
        assert!(body.get(absent).is_none(), "{absent}: {body}");
    }
}

#[test]
fn the_source_sandbox_is_reused_and_a_pinned_model_is_checked() {
    let core = connected(server("any_host"));
    block_on(core.create_nested_session(&selection("sbx"), &request("sbx"), "", None)).unwrap();
    let pinned = CreationSelection {
        model: Some("codex-fast".into()),
        ..selection("mac")
    };
    block_on(core.create_nested_session(&pinned, &request("sbx"), "", None)).unwrap();
    let bodies = core.transport().write_bodies();
    assert_eq!(bodies[0]["host_id"], "sbx");
    assert_eq!(bodies[1]["model_override"], "codex-fast");

    let unknown = CreationSelection {
        model: Some("retired".into()),
        ..selection("mac")
    };
    let refused = block_on(core.create_nested_session(&unknown, &request("sbx"), "", None));
    assert!(
        matches!(
            refused,
            Err(SessionError::Creation(CreationError::Unavailable(_)))
        ),
        "{refused:?}"
    );
    // Another session's sandbox is never offered.
    let other = block_on(core.create_nested_session(&selection("sbx"), &request("mac"), "", None));
    assert!(matches!(
        other,
        Err(SessionError::Creation(CreationError::Unavailable(_)))
    ));
    assert_eq!(posts(&core), 2);
}

#[test]
fn the_policy_and_capability_refuse_before_anything_is_sent() {
    let core = connected(server("current_host"));
    let elsewhere =
        block_on(core.create_nested_session(&selection("box"), &request("mac"), "", None));
    assert!(matches!(
        elsewhere,
        Err(SessionError::Creation(CreationError::Unavailable(reason))) if reason.contains("current host")
    ));
    let sandbox = block_on(core.create_nested_sandbox_session(
        &selection("mac"),
        &SandboxTarget::default(),
        &request("mac"),
        "",
    ));
    assert!(matches!(
        sandbox,
        Err(SessionError::Creation(CreationError::Unavailable(_)))
    ));
    core.transport().ok(
        "/v1/info",
        r#"{"single_user":true,"accounts_enabled":false}"#,
    );
    let off = block_on(core.create_nested_session(&selection("mac"), &request("mac"), "", None));
    assert_eq!(
        off,
        Err(SessionError::Creation(CreationError::Unavailable(
            NESTED_AGENTS_UNAVAILABLE.into()
        )))
    );
    for bad in [
        NestedRequest {
            client_token: "not a token".into(),
            ..request("mac")
        },
        NestedRequest {
            source_id: String::new(),
            ..request("mac")
        },
        NestedRequest {
            source_host_id: Some("../x".into()),
            ..request("mac")
        },
    ] {
        let result = block_on(core.create_nested_session(&selection("mac"), &bad, "", None));
        assert!(
            matches!(result, Err(SessionError::InvalidIdentifier { .. })),
            "{result:?}"
        );
    }
    let long = "x".repeat(121);
    assert!(matches!(
        block_on(core.create_nested_session(&selection("mac"), &request("mac"), &long, None)),
        Err(SessionError::Creation(CreationError::Unavailable(_)))
    ));
    assert_eq!(posts(&core), 0);
}

#[test]
fn a_new_sandbox_sends_the_managed_contract_with_the_source() {
    let core = connected(server("current_host_or_new_sandbox"));
    let receipt = block_on(core.create_nested_sandbox_session(
        &selection("mac"),
        &SandboxTarget {
            provider: Some("modal".into()),
            host_id: Some("fedcba9876543210fedcba9876543210".into()),
            ..SandboxTarget::default()
        },
        &request("mac"),
        "Spike",
    ))
    .unwrap();
    assert_eq!(receipt.session_id, "conv_new");
    let body = body_json(&core.transport().writes()[0]);
    assert_eq!(body["host_type"], "managed");
    assert_eq!(body["host_id"], "fedcba9876543210fedcba9876543210");
    assert_eq!(body["sibling_source_id"], "conv_source");
    assert_eq!(body["labels"][CLIENT_CREATE_TOKEN_LABEL], TOKEN);
    assert_eq!(body["title"], "Spike");
    assert!(body.get("project_id").is_none(), "{body}");

    // A server that names sandbox hosts itself gets no host id.
    core.transport().ok(
        "/v1/info",
        r#"{"single_user":true,"accounts_enabled":false,"sibling_sessions":true,
            "managed_sandboxes_enabled":true,"sandbox_provider":"modal"}"#,
    );
    block_on(core.create_nested_sandbox_session(
        &selection("mac"),
        &SandboxTarget {
            host_id: Some("fedcba9876543210fedcba9876543210".into()),
            ..SandboxTarget::default()
        },
        &request("mac"),
        "",
    ))
    .unwrap();
    assert!(core.transport().write_bodies()[1].get("host_id").is_none());
    let unregistered = CreationSelection {
        agent_id: "ag_gone".into(),
        ..selection("mac")
    };
    assert!(matches!(
        block_on(core.create_nested_sandbox_session(
            &unregistered,
            &SandboxTarget::default(),
            &request("mac"),
            ""
        )),
        Err(SessionError::Creation(CreationError::Unavailable(_)))
    ));
}

#[test]
fn the_servers_refusals_are_definite_and_read_clearly() {
    let core = connected(server("any_host"));
    for (status, message, expected) in [
        (403, "Nested agents are disabled", NESTED_AGENTS_UNAVAILABLE),
        (
            409,
            "Sibling source is no longer available",
            "The source session is no longer available. Nothing was created.",
        ),
        (
            400,
            "A family supports up to 100 sessions",
            "A family supports up to 100 sessions",
        ),
    ] {
        core.transport().enqueue(
            "POST",
            "/v1/sessions",
            vec![Reply::json(
                status,
                format!(r#"{{"error":{{"message":"{message}"}}}}"#),
            )],
        );
        let result =
            block_on(core.create_nested_session(&selection("mac"), &request("mac"), "", None));
        assert_eq!(
            result,
            Err(SessionError::Creation(CreationError::Rejected {
                status,
                message: expected.into()
            }))
        );
    }
    core.transport()
        .enqueue("POST", "/v1/sessions", vec![Reply::json(503, "{}")]);
    assert_eq!(
        block_on(core.create_nested_session(&selection("mac"), &request("mac"), "", None)),
        Err(SessionError::Creation(CreationError::Uncertain))
    );
}

#[test]
fn create_and_send_sends_the_first_message_to_the_new_session() {
    let transport = server("any_host");
    transport.respond(
        Some("POST"),
        "/v1/sessions/conv_new/events",
        None,
        Reply::json(202, r#"{"queued":false,"item_id":"item_1"}"#),
    );
    let core = connected(transport);
    let created = block_on(core.create_nested_session_and_send(
        &selection("mac"),
        &request("mac"),
        "",
        "Write the tests",
    ))
    .unwrap();
    assert!(matches!(created.first_message, FirstMessage::Sent(_)));
    let lines = core.transport().lines();
    assert_eq!(
        lines[lines.len() - 2..],
        ["POST /v1/sessions", "POST /v1/sessions/conv_new/events"]
    );

    core.transport().respond(
        Some("POST"),
        "/v1/sessions/conv_new/events",
        None,
        Reply::json(400, r#"{"error":{"message":"no"}}"#),
    );
    let failed = block_on(core.create_nested_session_and_send(
        &selection("mac"),
        &request("mac"),
        "",
        "Again",
    ))
    .unwrap();
    assert!(matches!(failed.first_message, FirstMessage::Failed(_)));
    assert!(
        block_on(core.create_nested_session_and_send(
            &selection("box"),
            &NestedRequest {
                client_token: String::new(),
                ..request("mac")
            },
            "",
            "Never sent",
        ))
        .is_err()
    );
}

#[test]
fn the_source_is_read_fresh() {
    let transport = server("any_host");
    transport.ok(
        "/v1/sessions/conv_source",
        r#"{"id":"conv_source","status":"idle","created_at":1,"title":"Coordinator",
            "host_id":"mac","workspace":"/work/app","permission_level":4}"#,
    );
    let core = connected(transport);
    let source = block_on(core.nested_source("conv_source")).unwrap();
    assert_eq!(source.title, "Coordinator");
    assert_eq!(source.workspace, "/work/app");
    assert!(matches!(
        block_on(core.nested_source("conv_missing")),
        Err(SessionError::SessionNotFound { .. })
    ));
    assert!(matches!(
        block_on(core.nested_source("bad id")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}
