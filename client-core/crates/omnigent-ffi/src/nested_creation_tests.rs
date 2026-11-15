//! Add nested agent across the FFI: the policy, the composer's hosts, validation and the
//! REST calls.

use omnigent_core::creation as creation_core;

use crate::creation::{
    CreationCatalog, CreationHost, CreationSelection, FirstMessage, SandboxTarget,
};
use crate::nested_creation::{
    NestedRequest, client_create_token_label, nested_creation_validation_error,
    nested_host_choices, nested_unavailable_reason,
};
use crate::sessions::SiblingSessionDestinations;
use crate::test_support::{connected, json};

const TOKEN: &str = "0123456789abcdef0123456789abcdef";

fn host(id: &str, sandbox: Option<&str>) -> CreationHost {
    CreationHost::from(creation_core::CreationHost {
        host_id: id.into(),
        name: id.into(),
        status: "online".into(),
        sandbox_provider: sandbox.map(str::to_owned),
        configured_harnesses: Some(
            std::iter::once((
                "codex-native".to_owned(),
                creation_core::HarnessReadiness::Ready,
            ))
            .collect(),
        ),
    })
}

fn catalog(policy: Option<SiblingSessionDestinations>) -> CreationCatalog {
    CreationCatalog {
        hosts: vec![
            host("mac", None),
            host("box", None),
            host("sbx", Some("modal")),
        ],
        agents: vec![crate::creation::CreationAgent::from(
            creation_core::CreationAgent {
                id: "ag_codex".into(),
                name: "Codex".into(),
                harness: Some("codex-native".into()),
                ..creation_core::CreationAgent::default()
            },
        )],
        managed_sandboxes: true,
        default_sandbox_provider: Some("modal".into()),
        sibling_sessions: true,
        sibling_session_destinations: policy,
        ..CreationCatalog::from(creation_core::CreationCatalog::default())
    }
}

fn selection(host_id: &str) -> CreationSelection {
    CreationSelection {
        host_id: host_id.into(),
        agent_id: "ag_codex".into(),
        workspace: "/work/app".into(),
        ..CreationSelection::default()
    }
}

fn request() -> NestedRequest {
    NestedRequest {
        source_id: "conv_source".into(),
        source_host_id: Some("mac".into()),
        client_token: TOKEN.into(),
    }
}

#[test]
fn the_token_label_is_the_webs() {
    assert_eq!(client_create_token_label(), "omnigent.client_create_token");
}

#[test]
fn the_composer_hosts_follow_the_policy_and_a_missing_one_reads_as_any_host() {
    let any = nested_host_choices(catalog(None), Some("sbx".into()));
    assert_eq!(any.host_ids, ["mac", "box", "sbx"]);
    assert!(any.offers_new_sandbox && any.offers_connect_host);
    let current = nested_host_choices(
        catalog(Some(SiblingSessionDestinations::CurrentHost)),
        Some("mac".into()),
    );
    assert_eq!(current.host_ids, ["mac"]);
    assert!(!current.offers_new_sandbox && !current.offers_connect_host);
}

#[test]
fn validation_reuses_only_the_source_sandbox_and_follows_the_policy() {
    assert_eq!(
        nested_unavailable_reason(
            catalog(None),
            "ag_codex".into(),
            "sbx".into(),
            Some("sbx".into())
        ),
        None
    );
    assert!(
        nested_unavailable_reason(catalog(None), "ag_codex".into(), "sbx".into(), None).is_some()
    );
    assert_eq!(
        nested_creation_validation_error(catalog(None), selection("box"), vec![], None),
        None
    );
    assert!(
        nested_creation_validation_error(
            catalog(Some(SiblingSessionDestinations::CurrentHostOrNewSandbox)),
            selection("box"),
            vec![],
            Some("mac".into())
        )
        .is_some_and(|reason| reason.contains("new managed sandbox"))
    );
}

/// A connected harness whose server offers nested agents, Codex on `mac` and a 201 create.
fn nested_server() -> crate::test_support::Harness {
    let harness = connected();
    harness.http.route(
        "/v1/info",
        json(
            200,
            r#"{"single_user":true,"accounts_enabled":false,"sibling_sessions":true,
                "managed_sandboxes_enabled":true,"sandbox_provider":"modal",
                "request_managed_sandbox_host_id":true}"#,
        ),
    );
    harness.http.route(
        "/v1/hosts",
        json(
            200,
            r#"{"hosts":[{"host_id":"mac","name":"Mac","status":"online",
                "configured_harnesses":{"codex-native":true}}]}"#,
        ),
    );
    harness.http.route(
        "/v1/agents",
        json(
            200,
            r#"{"data":[{"id":"ag_codex","name":"Codex","harness":"codex-native"}],"has_more":false}"#,
        ),
    );
    harness.http.route_method(
        "POST",
        "/v1/sessions",
        json(
            201,
            r#"{"id":"conv_new","status":"idle","created_at":1,"permission_level":4}"#,
        ),
    );
    harness.http.route(
        "/v1/sessions/conv_source",
        json(
            200,
            r#"{"id":"conv_source","status":"idle","created_at":1,"title":"Coordinator",
                "host_id":"mac","workspace":"/work/app","permission_level":4}"#,
        ),
    );
    harness.http.route_method(
        "POST",
        "/v1/sessions/conv_new/events",
        json(202, r#"{"queued":false,"item_id":"item_1"}"#),
    );
    harness
}

#[test]
fn the_core_reads_the_source_and_creates_beside_it() {
    let mut harness = nested_server();
    let source = harness
        .call(|core| async move { core.nested_source("conv_source".into()).await })
        .unwrap();
    assert_eq!(source.title, "Coordinator");
    assert_eq!(
        source
            .configuration
            .and_then(|configuration| configuration.host_id)
            .as_deref(),
        Some("mac")
    );

    let receipt = harness
        .call(|core| async move {
            core.create_nested_session(selection("mac"), request(), String::new(), None)
                .await
        })
        .unwrap();
    assert_eq!(receipt.session_id, "conv_new");
    let (line, body) = harness.last_request();
    assert_eq!(line, "POST /v1/sessions");
    assert_eq!(body["sibling_source_id"], "conv_source");
    assert_eq!(body["labels"]["omnigent.client_create_token"], TOKEN);

    let created = harness
        .call(|core| async move {
            core.create_nested_session_and_send(
                selection("mac"),
                request(),
                String::new(),
                "Write the tests".into(),
            )
            .await
        })
        .unwrap();
    assert!(matches!(created.first_message, FirstMessage::Sent { .. }));

    harness
        .call(|core| async move {
            core.create_nested_sandbox_session(
                selection("mac"),
                SandboxTarget::default(),
                NestedRequest {
                    source_host_id: None,
                    ..request()
                },
                String::new(),
            )
            .await
        })
        .unwrap();
    let (_, managed) = harness.last_request();
    assert_eq!(managed["host_type"], "managed");
    assert_eq!(managed["sibling_source_id"], "conv_source");
    assert_eq!(managed["host_id"].as_str().map(str::len), Some(32));
}

#[test]
fn the_core_refuses_what_it_cannot_create() {
    let mut harness = nested_server();
    let missing = harness.call(|core| async move { core.nested_source("conv_gone".into()).await });
    assert!(missing.is_err());
    let refused = harness.call(|core| async move {
        core.create_nested_session(
            selection("mac"),
            NestedRequest {
                client_token: String::new(),
                ..request()
            },
            String::new(),
            None,
        )
        .await
    });
    assert!(refused.is_err());
    let refused_send = harness.call(|core| async move {
        core.create_nested_session_and_send(
            selection("nowhere"),
            request(),
            String::new(),
            "x".into(),
        )
        .await
    });
    assert!(refused_send.is_err());
    let refused_sandbox = harness.call(|core| async move {
        core.create_nested_sandbox_session(
            selection("mac"),
            SandboxTarget {
                provider: Some("docker".into()),
                ..SandboxTarget::default()
            },
            request(),
            String::new(),
        )
        .await
    });
    assert!(refused_sandbox.is_err());
}
