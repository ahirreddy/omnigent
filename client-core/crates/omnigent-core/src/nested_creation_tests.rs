//! Add nested agent rules: the destination policy matrix, the composer's hosts, and the
//! request bodies, as the web's sibling composer and `session_families` apply them.

use serde_json::{Value, json};

use crate::session_families::SiblingDestinations;

use super::*;
use crate::creation::{CreationCapabilities, CreationHost, HarnessReadiness};

fn host(id: &str, sandbox: Option<&str>) -> CreationHost {
    CreationHost {
        host_id: id.into(),
        name: id.into(),
        status: "online".into(),
        sandbox_provider: sandbox.map(str::to_owned),
        configured_harnesses: Some(
            std::iter::once(("codex-native".to_owned(), HarnessReadiness::Ready)).collect(),
        ),
    }
}

fn catalog(policy: SiblingDestinations, sandboxes: bool) -> CreationCatalog {
    CreationCatalog {
        hosts: vec![
            host("mac", None),
            host("box", None),
            host("sbx_source", Some("modal")),
            host("sbx_other", Some("modal")),
        ],
        agents: vec![CreationAgent {
            id: "ag_codex".into(),
            name: "Codex".into(),
            harness: Some("codex-native".into()),
            ..CreationAgent::default()
        }],
        capabilities: CreationCapabilities {
            managed_sandboxes: sandboxes,
            default_sandbox_provider: Some("modal".into()),
            sibling_sessions: true,
            sibling_destinations: policy,
            ..CreationCapabilities::default()
        },
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
        client_token: "0123456789abcdef0123456789abcdef".into(),
    }
}

#[test]
fn the_destination_matrix_matches_the_server() {
    use NestedDestination::{Host, NewSandbox};
    use SiblingDestinations::{AnyHost, CurrentHost, CurrentHostOrNewSandbox};
    let source = Some("mac");
    let current_only = "Add nested agent is limited to the current host by server policy.";
    let or_sandbox = "Add nested agent is limited to the current host or a new managed sandbox \
                      by server policy.";
    for (policy, destination, source_host, expected) in [
        (CurrentHost, Host("mac"), source, None),
        (CurrentHost, Host("box"), source, Some(current_only)),
        (CurrentHost, NewSandbox, source, Some(current_only)),
        (CurrentHost, Host("mac"), None, Some(current_only)),
        (CurrentHostOrNewSandbox, Host("mac"), source, None),
        (
            CurrentHostOrNewSandbox,
            Host("box"),
            source,
            Some(or_sandbox),
        ),
        (CurrentHostOrNewSandbox, NewSandbox, source, None),
        (AnyHost, Host("mac"), source, None),
        (AnyHost, Host("box"), source, None),
        (AnyHost, NewSandbox, source, None),
        (AnyHost, Host("box"), None, None),
    ] {
        assert_eq!(
            destination_refusal(policy, source_host, destination).as_deref(),
            expected,
            "{policy:?} {destination:?} {source_host:?}"
        );
    }
}

#[test]
fn the_composer_offers_ordinary_hosts_and_the_source_sandbox_under_each_policy() {
    use SiblingDestinations::{AnyHost, CurrentHost, CurrentHostOrNewSandbox};
    let ids = |choices: &NestedHostChoices| choices.host_ids.clone();
    let any = NestedHostChoices::new(&catalog(AnyHost, true), Some("sbx_source"));
    assert_eq!(ids(&any), ["mac", "box", "sbx_source"]);
    assert!(any.offers_new_sandbox && any.offers_connect_host);
    assert!(any.allows_host("box") && !any.allows_host("sbx_other"));

    let current = NestedHostChoices::new(&catalog(CurrentHost, true), Some("sbx_source"));
    assert_eq!(ids(&current), ["sbx_source"]);
    assert!(!current.offers_new_sandbox && !current.offers_connect_host);

    let sandboxed = NestedHostChoices::new(&catalog(CurrentHostOrNewSandbox, true), Some("mac"));
    assert_eq!(ids(&sandboxed), ["mac"]);
    assert!(sandboxed.offers_new_sandbox && !sandboxed.offers_connect_host);

    // A server without sandboxes offers none, whatever the policy allows.
    let without = NestedHostChoices::new(&catalog(AnyHost, false), Some("mac"));
    assert!(!without.offers_new_sandbox);
    assert_eq!(ids(&without), ["mac", "box"]);
}

#[test]
fn validation_allows_only_the_source_sandbox_and_follows_the_policy() {
    let any = catalog(SiblingDestinations::AnyHost, true);
    assert_eq!(
        any.validate_nested(&selection("sbx_source"), &[], Some("sbx_source")),
        Ok(())
    );
    assert_eq!(
        any.nested_unavailable_reason("ag_codex", "sbx_other", Some("sbx_source"))
            .as_deref(),
        Some("Managed sandbox creation is not available here.")
    );
    assert_eq!(
        any.nested_unavailable_reason("ag_codex", "mac", Some("sbx_source")),
        None
    );
    let current = catalog(SiblingDestinations::CurrentHost, true);
    assert!(matches!(
        current.validate_nested(&selection("box"), &[], Some("mac")),
        Err(CreationError::Unavailable(reason)) if reason.contains("current host")
    ));
    assert!(matches!(
        current.validate_nested_sandbox(&selection("mac"), &SandboxTarget::default(), Some("mac")),
        Err(CreationError::Unavailable(reason)) if reason.contains("current host")
    ));
    let sandboxed = catalog(SiblingDestinations::CurrentHostOrNewSandbox, true);
    assert_eq!(
        sandboxed.validate_nested_sandbox(&selection("mac"), &SandboxTarget::default(), None),
        Ok(())
    );
    let mut off = any;
    off.capabilities.sibling_sessions = false;
    assert_eq!(
        off.validate_nested(&selection("mac"), &[], Some("mac")),
        Err(CreationError::Unavailable(
            NESTED_AGENTS_UNAVAILABLE.to_owned()
        ))
    );
}

#[test]
fn the_body_adds_the_source_and_token_and_never_a_project() {
    let agent = catalog(SiblingDestinations::AnyHost, true).agents[0].clone();
    let filed = CreationSelection {
        project_id: Some("proj_1".into()),
        ..selection("mac")
    };
    let body = nested_creation_body(&filed, "", &agent, None, &request());
    assert_eq!(body["sibling_source_id"], "conv_source");
    assert_eq!(body["host_id"], "mac");
    assert_eq!(body["host_type"], "external");
    assert_eq!(body["workspace"], "/work/app");
    assert_eq!(
        body["labels"][CLIENT_CREATE_TOKEN_LABEL],
        "0123456789abcdef0123456789abcdef"
    );
    assert_eq!(body["labels"]["omnigent.wrapper"], "codex-native-ui");
    for absent in [
        "project_id",
        "initial_items",
        "parent_session_id",
        "git",
        "title",
    ] {
        assert!(body.get(absent).is_none(), "{absent}: {body}");
    }

    let plain = CreationAgent {
        harness: Some("openai-agents".into()),
        ..agent.clone()
    };
    let labels =
        nested_creation_body(&selection("mac"), "", &plain, None, &request())["labels"].clone();
    assert_eq!(
        labels,
        json!({CLIENT_CREATE_TOKEN_LABEL: "0123456789abcdef0123456789abcdef"}),
        "an agent without wrapper labels still carries the token"
    );

    let sandbox = nested_sandbox_creation_body(
        &filed,
        &SandboxTarget {
            provider: Some("modal".into()),
            ..SandboxTarget::default()
        },
        "",
        &agent,
        &request(),
    );
    assert_eq!(sandbox["host_type"], "managed");
    assert_eq!(sandbox["sibling_source_id"], "conv_source");
    assert_eq!(sandbox["sandbox_provider"], "modal");
    assert_eq!(sandbox["workspaces"], json!([]));
    assert_eq!(sandbox["workspace"], Value::Null);
    assert_eq!(sandbox["git"], Value::Null);
    assert!(sandbox.get("project_id").is_none(), "{sandbox}");
    assert_eq!(
        with_sibling_fields(json!("not an object"), &request()),
        json!("not an object")
    );
}

#[test]
fn refusals_read_as_clear_sentences() {
    let error =
        |message: &str| format!(r#"{{"error":{{"code":"forbidden","message":"{message}"}}}}"#);
    for (message, status, expected) in [
        ("Nested agents are disabled", 403, NESTED_AGENTS_UNAVAILABLE),
        (
            "Session is not owned or available",
            403,
            "Only the owner of an active session can add a nested agent to it.",
        ),
        (
            "Sessions shared with edit access cannot send messages, launch independent sessions",
            403,
            "A session shared with edit access can't have nested agents.",
        ),
        (
            "Sibling source is no longer available",
            409,
            "The source session is no longer available. Nothing was created.",
        ),
        (
            "This session ID is still used by another family",
            409,
            "The source session already belongs to another group. Nothing was created.",
        ),
        (
            "Siblings require an owned source and no execution parent",
            400,
            "Only the owner of an active session can add a nested agent to it.",
        ),
        (
            "Add nested agent is limited to the current host by server policy",
            403,
            "Add nested agent is limited to the current host by server policy",
        ),
        (
            "A family supports up to 100 sessions",
            400,
            "A family supports up to 100 sessions",
        ),
    ] {
        assert_eq!(
            nested_rejection(error(message).as_bytes(), status),
            expected,
            "{message}"
        );
    }
    assert_eq!(
        nested_rejection(b"<html>", 409),
        "The server rejected session creation (HTTP 409). Review your choices."
    );
}
