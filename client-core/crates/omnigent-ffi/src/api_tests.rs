//! Driver tests of the creation, configuration, edit, workspace, changed-files and Databricks
//! sign-in surfaces: the real core over fake host traits.

#![allow(
    clippy::too_many_lines,
    reason = "each test walks one user journey end to end"
)]

use std::sync::Arc;

use crate::connection::{DatabricksOAuthSettings, UrlPolicy};
use crate::creation::{CreationSelection, FirstMessage};
use crate::engine::lock;
use crate::errors::CoreError;
use crate::events::{ChangedFilesUpdate, ConnectionPhase, CoreEvent, SignInMethod};
use crate::sessions::{SessionChange, SessionListChange};
use crate::test_support::{Harness, connected, envelope_response, json};
use crate::workspace::{FilePreview, WorkspaceEntryKind, WorkspaceErrorKind};

const WORKSPACE_SESSION: &str = "207c660071e248e198c634aec763bb75";

pub(crate) fn route_creation(harness: &Harness) {
    for (path, fixture) in [
        ("/v1/hosts", "sessions/SessionCreation--_shared--hosts.json"),
        (
            "/v1/agents",
            "sessions/SessionCreation--_shared--agents.json",
        ),
        (
            "/v1/hosts/host_a/harnesses/codex-native/model-options",
            "sessions/SessionCreation--_shared--model-options.json",
        ),
    ] {
        harness
            .http
            .route(path, json(200, &envelope_response(fixture)));
    }
    harness.http.route(
        "/v1/hosts/host_a/filesystem",
        json(
            200,
            r#"{"data":[{"name":"project","path":"/work/project","type":"directory"},{"name":"notes.txt","path":"/work/notes.txt","type":"file"}],"has_more":false}"#,
        ),
    );
    harness.http.route_method(
        "POST",
        "/v1/sessions",
        json(
            201,
            &envelope_response(
                "sessions/SessionCreation--201PostsExactExternalHostContractWithoutInitialPrompt.json",
            ),
        ),
    );
}

#[test]
fn creation_creates_once_and_reports_a_failed_first_message_without_recreating() {
    let mut harness = connected();
    route_creation(&harness);
    let core = Arc::clone(&harness.core);
    let catalog = harness
        .run(async move { core.creation_catalog().await })
        .unwrap();
    assert_eq!(catalog.hosts[0].host_id, "host_a");
    assert!(catalog.hosts[0].is_available);
    assert!(catalog.agents[0].supports_model_preview);
    assert_eq!(
        crate::creation::creation_unavailable_reason(
            catalog.clone(),
            "ag_codex".into(),
            "host_a".into()
        ),
        None
    );
    let core = Arc::clone(&harness.core);
    let workspaces = harness
        .run(async move { core.creation_workspaces("host_a".into()).await })
        .unwrap();
    assert_eq!(workspaces.len(), 1, "files are never offered");
    let core = Arc::clone(&harness.core);
    let models = harness
        .run(async move {
            core.creation_models("ag_codex".into(), "host_a".into())
                .await
        })
        .unwrap();
    assert_eq!(models[0].value, "provider-model");
    let selection = CreationSelection {
        host_id: "host_a".into(),
        agent_id: "ag_codex".into(),
        workspace: "/work/project".into(),
        model: Some("provider-model".into()),
        ..CreationSelection::default()
    };
    assert_eq!(
        crate::creation::creation_validation_error(
            catalog.clone(),
            CreationSelection {
                workspace: "relative".into(),
                ..selection.clone()
            },
            models.clone()
        )
        .as_deref(),
        Some("Enter an absolute workspace path beginning with /.")
    );
    assert_eq!(
        crate::creation::creation_validation_error(catalog, selection.clone(), models),
        None
    );

    let core = Arc::clone(&harness.core);
    let created = harness
        .run(async move {
            core.create_session_and_send(selection, "Review".into(), "Hello".into())
                .await
        })
        .unwrap();
    assert_eq!(created.receipt.session_id, "conv_created");
    let FirstMessage::Failed { error } = created.first_message else {
        panic!(
            "the first message has no route: {:?}",
            created.first_message
        );
    };
    assert!(matches!(error, CoreError::Session { .. }), "{error:?}");
    let creations = harness
        .http
        .lines()
        .into_iter()
        .filter(|line| line == "POST /v1/sessions")
        .count();
    assert_eq!(creations, 1, "a failed first message never recreates");
    assert!(harness.events.all().iter().any(|event| matches!(
        event,
        CoreEvent::SessionListChanged {
            change: SessionListChange::Upsert { sessions }
        } if sessions.iter().any(|session| session.id == "conv_created")
    )));
}

#[test]
fn an_unclear_creation_is_uncertain_and_never_retried() {
    let mut harness = connected();
    route_creation(&harness);
    harness.http.route_method(
        "POST",
        "/v1/sessions",
        json(502, "<html>bad gateway</html>"),
    );
    let core = Arc::clone(&harness.core);
    let error = harness
        .run(async move {
            core.create_session(
                CreationSelection {
                    host_id: "host_a".into(),
                    agent_id: "ag_codex".into(),
                    workspace: "/work/project".into(),
                    model: None,
                    ..CreationSelection::default()
                },
                String::new(),
            )
            .await
        })
        .unwrap_err();
    let CoreError::Session {
        delivery_uncertain, ..
    } = error
    else {
        panic!("{error:?}");
    };
    assert!(delivery_uncertain);
    let posts = harness
        .http
        .lines()
        .into_iter()
        .filter(|line| line == "POST /v1/sessions")
        .count();
    assert_eq!(posts, 1);
}

#[test]
fn edits_publish_list_upserts_and_pins_carry_the_host_clock() {
    let mut harness = connected();
    let snapshot = r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"harness":"codex-native","model_override":null}"#;
    harness
        .http
        .route_method("GET", "/v1/sessions/conv_a", json(200, snapshot));
    harness.http.route_method(
        "PATCH",
        "/v1/sessions/conv_a",
        json(
            200,
            r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"labels":{"omnigent.pinned":"1"}}"#,
        ),
    );
    harness.events.take();
    let core = Arc::clone(&harness.core);
    let pinned = harness
        .run(async move {
            core.edit_session("conv_a".into(), SessionChange::Pinned { pinned: true })
                .await
        })
        .unwrap();
    assert!(pinned.is_pinned);
    let patch = lock(&harness.http.requests)
        .iter()
        .rev()
        .find(|request| request.method == "PATCH")
        .cloned()
        .unwrap();
    let body: serde_json::Value = serde_json::from_slice(&patch.body.unwrap()).unwrap();
    assert_eq!(
        body,
        serde_json::json!({"labels": {"omnigent.pinned": "1800000000000"}})
    );
    assert!(harness.events.all().iter().any(|event| matches!(
        event,
        CoreEvent::SessionListChanged {
            change: SessionListChange::Upsert { sessions }
        } if sessions.iter().any(|session| session.id == "conv_a" && session.is_pinned)
    )));
    let core = Arc::clone(&harness.core);
    let error = harness
        .run(async move {
            core.edit_session(
                "conv_a".into(),
                SessionChange::Title {
                    title: "   ".into(),
                },
            )
            .await
        })
        .unwrap_err();
    assert!(matches!(
        error,
        CoreError::Session {
            kind: crate::errors::SessionErrorKind::InvalidTitle,
            ..
        }
    ));
    let core = Arc::clone(&harness.core);
    let summary = harness
        .run(async move { core.configuration_snapshot("conv_a".into()).await })
        .unwrap();
    let configuration = summary.configuration.expect("a configuration");
    assert_eq!(configuration.harness.as_deref(), Some("codex-native"));
    assert_eq!(configuration.model_reported, Some(true));
    let labels = crate::configuration::configuration_labels(configuration);
    assert_eq!(labels.harness, "Codex");
    assert_eq!(labels.model, "Harness default");
}

fn route_workspace(harness: &Harness) {
    let base = format!("/v1/sessions/{WORKSPACE_SESSION}/resources/environments/default");
    for (path, fixture) in [
        (
            format!("{base}/filesystem"),
            "recorded-filesystem-root.json",
        ),
        (
            format!("{base}/filesystem/src/main.rs"),
            "recorded-file-text.json",
        ),
        (format!("{base}/changes"), "recorded-changes.json"),
        (
            format!("{base}/diff/src/main.rs"),
            "recorded-diff-modified.json",
        ),
        (base, "recorded-environment-default.json"),
    ] {
        harness.http.route(
            &path,
            json(200, &envelope_response(&format!("workspace/{fixture}"))),
        );
    }
}

#[test]
fn workspace_reads_decode_preview_and_diff_in_the_core() {
    let mut harness = connected();
    route_workspace(&harness);
    let core = Arc::clone(&harness.core);
    let page = harness
        .run(async move {
            core.list_workspace_directory(
                WORKSPACE_SESSION.into(),
                "default".into(),
                String::new(),
                None,
                None,
            )
            .await
        })
        .unwrap();
    let first_file = page
        .entries
        .iter()
        .position(|entry| entry.kind != WorkspaceEntryKind::Directory)
        .unwrap_or(page.entries.len());
    assert!(
        page.entries
            .iter()
            .skip(first_file)
            .all(|entry| entry.kind != WorkspaceEntryKind::Directory),
        "directories first: {:?}",
        page.entries
    );
    let core = Arc::clone(&harness.core);
    let file = harness
        .run(async move {
            core.read_workspace_file(
                WORKSPACE_SESSION.into(),
                "default".into(),
                "src/main.rs".into(),
            )
            .await
        })
        .unwrap();
    let FilePreview::Text { preview } = file.preview else {
        panic!("{:?}", file.preview);
    };
    let core = Arc::clone(&harness.core);
    let bytes = harness
        .run(async move {
            core.read_workspace_file_bytes(
                WORKSPACE_SESSION.into(),
                "default".into(),
                "src/main.rs".into(),
            )
            .await
        })
        .unwrap();
    assert_eq!(bytes.path, "src/main.rs");
    assert!(!bytes.truncated);
    assert_eq!(
        String::from_utf8(bytes.bytes).unwrap().trim_end(),
        preview.text.trim_end()
    );
    assert_eq!(
        preview.language,
        Some(crate::workspace::SyntaxLanguage::Rust)
    );
    assert_eq!(preview.line_count, 4);
    let core = Arc::clone(&harness.core);
    let changes = harness
        .run(async move {
            core.workspace_changes(WORKSPACE_SESSION.into(), "default".into())
                .await
        })
        .unwrap();
    let paths: Vec<&str> = changes
        .files
        .iter()
        .map(|file| file.path.as_str())
        .collect();
    let mut sorted = paths.clone();
    sorted.sort_unstable();
    assert_eq!(paths, sorted);
    assert!(changes.totals.created >= 1);
    let core = Arc::clone(&harness.core);
    let diff = harness
        .run(async move {
            core.workspace_file_diff(
                WORKSPACE_SESSION.into(),
                "default".into(),
                "src/main.rs".into(),
            )
            .await
        })
        .unwrap();
    assert_eq!((diff.added, diff.removed), (2, 0));
    let core = Arc::clone(&harness.core);
    let environment = harness
        .run(async move {
            core.workspace_environment(WORKSPACE_SESSION.into(), "default".into())
                .await
        })
        .unwrap();
    assert_eq!(environment.root.as_deref(), Some("/workspace/fixture"));
    let requests_before = lock(&harness.http.requests).len();
    let core = Arc::clone(&harness.core);
    let error = harness
        .run(async move {
            core.read_workspace_file(
                WORKSPACE_SESSION.into(),
                "default".into(),
                "../etc/passwd".into(),
            )
            .await
        })
        .unwrap_err();
    assert!(matches!(
        error,
        CoreError::Workspace {
            kind: WorkspaceErrorKind::InvalidInput,
            ..
        }
    ));
    assert_eq!(lock(&harness.http.requests).len(), requests_before);
    let core = Arc::clone(&harness.core);
    let missing = harness
        .run(async move {
            core.workspace_file_diff(
                WORKSPACE_SESSION.into(),
                "default".into(),
                "missing.rs".into(),
            )
            .await
        })
        .unwrap_err();
    assert!(
        matches!(missing, CoreError::Workspace { .. }),
        "{missing:?}"
    );
}

#[test]
fn changed_files_invalidation_is_reported_as_an_event() {
    let mut harness = connected();
    let session = "facbcc05b00f4321b98b1929d217abc5";
    harness.http.route(
        &format!("/v1/sessions/{session}"),
        json(
            200,
            &envelope_response("sessions/recorded-session-get-no-items.json"),
        ),
    );
    harness.http.route(
        &format!("/v1/sessions/{session}/items"),
        json(200, r#"{"object":"list","data":[],"has_more":false}"#),
    );
    harness.http.route(
        &format!("/v1/sessions/{session}/resources/environments/default/changes"),
        json(
            200,
            r#"{"object":"list","data":[{"path":"src/a.rs","status":"modified"}],"has_more":false}"#,
        ),
    );
    harness.core.open_session(session.into());
    harness.pump();
    let (sink, _, _) = harness.streams.last();
    sink.response(
        200,
        vec![crate::http::HttpHeader {
            name: "Content-Type".into(),
            value: "text/event-stream".into(),
        }],
    );
    sink.chunk(b"event: session.heartbeat\ndata: {\"type\":\"session.heartbeat\"}\n\n".to_vec());
    harness.pump();
    let frame = format!(
        "event: session.changed_files.invalidated\ndata: {{\"type\":\"session.changed_files.invalidated\",\"session_id\":\"{session}\",\"environment_id\":\"default\"}}\n\n"
    );
    sink.chunk(frame.into_bytes());
    harness.pump();
    let update = harness
        .events
        .all()
        .into_iter()
        .find_map(|event| match event {
            CoreEvent::ChangedFiles {
                session_id,
                environment_id,
                update,
            } if session_id == session && environment_id == "default" => Some(update),
            _ => None,
        });
    let Some(ChangedFilesUpdate::Loaded { files }) = update else {
        panic!("{update:?}");
    };
    assert_eq!(files[0].path, "src/a.rs");
}

const WORKSPACE_HOST: &str = "https://dbc-1.cloud.databricks.com";

fn databricks() -> Harness {
    Harness::with_databricks(
        UrlPolicy::Release,
        Some(DatabricksOAuthSettings {
            client_id: "omnigent-app".into(),
            redirect_url: "https://login.databricks.com/mobile-redirect".into(),
        }),
    )
}

fn route_databricks(harness: &Harness, access: &str, expires_in: u64) {
    harness.http.route(
        "/oidc/.well-known/openid-configuration",
        json(
            200,
            &serde_json::json!({
                "issuer": format!("{WORKSPACE_HOST}/oidc"),
                "token_endpoint": format!("{WORKSPACE_HOST}/oidc/v1/token"),
            })
            .to_string(),
        ),
    );
    harness.http.route(
        "/oidc/v1/token",
        json(
            200,
            &serde_json::json!({
                "access_token": access,
                "refresh_token": format!("refresh-{access}"),
                "token_type": "Bearer",
                "expires_in": expires_in,
            })
            .to_string(),
        ),
    );
    harness.http.route(
        "/api/2.0/omnigent/v1/info",
        json(200, r#"{"single_user":false,"accounts_enabled":false}"#),
    );
    harness
        .http
        .route("/api/2.0/omnigent/v1/me", json(200, r#"{"user_id":"ada"}"#));
    harness.http.route(
        "/api/2.0/omnigent/v1/sessions",
        json(200, r#"{"object":"list","data":[],"has_more":false}"#),
    );
}

fn bearer_of(harness: &Harness, path: &str) -> Option<String> {
    lock(&harness.http.requests)
        .iter()
        .rev()
        .find(|request| url::Url::parse(&request.url).unwrap().path() == path)
        .and_then(|request| {
            request
                .headers
                .iter()
                .find(|header| header.name == "Authorization")
                .map(|header| header.value.clone())
        })
}

#[test]
fn databricks_workspaces_sign_in_natively_and_rotate_the_token_in_place() {
    let mut harness = databricks();
    route_databricks(&harness, "access-1", 3_600);
    let core = Arc::clone(&harness.core);
    let phase = harness
        .run(async move { core.connect(format!("{WORKSPACE_HOST}/?o=42"), None).await })
        .unwrap();
    let ConnectionPhase::SignInRequired {
        methods, base_url, ..
    } = phase
    else {
        panic!("{phase:?}");
    };
    assert_eq!(base_url, format!("{WORKSPACE_HOST}/api/2.0/omnigent?o=42"));
    assert_eq!(
        methods,
        vec![SignInMethod::DatabricksWorkspace {
            workspace_host: WORKSPACE_HOST.trim_start_matches("https://").into(),
            loopback: false,
            callback_host: "login.databricks.com".into(),
            callback_path: "/mobile-redirect".into(),
        }]
    );
    assert!(
        harness.http.lines().is_empty(),
        "nothing is read before sign-in: {:?}",
        harness.http.lines()
    );

    let challenge = harness.core.begin_databricks_sign_in(None).unwrap();
    let authorize = url::Url::parse(&challenge.authorize_url).unwrap();
    assert_eq!(authorize.path(), "/oidc/v1/authorize");
    let state = authorize
        .query_pairs()
        .find(|(name, _)| name == "state")
        .map(|(_, value)| value.into_owned())
        .unwrap();
    let callback = format!("https://login.databricks.com/mobile-redirect?state={state}&code=abc");
    let core = Arc::clone(&harness.core);
    let attempt = challenge.attempt_id;
    let server = harness
        .run(async move { core.complete_databricks_sign_in(attempt, callback).await })
        .unwrap();
    assert_eq!(server.user_id, "ada");
    assert_eq!(
        bearer_of(&harness, "/api/2.0/omnigent/v1/me").as_deref(),
        Some("Bearer access-1")
    );
    let org = lock(&harness.http.requests)
        .iter()
        .rev()
        .find(|request| request.url.ends_with("/v1/me"))
        .and_then(|request| {
            request
                .headers
                .iter()
                .find(|header| header.name == "X-Databricks-Org-Id")
                .map(|header| header.value.clone())
        });
    assert_eq!(org.as_deref(), Some("42"));
    assert_eq!(lock(&harness.store.items).len(), 1, "the grant is saved");

    // Renewal refreshes the grant and rotates the bearer without a reconnect.
    route_databricks(&harness, "access-2", 3_600);
    harness.events.take();
    let me_before = harness
        .http
        .lines()
        .iter()
        .filter(|line| line.ends_with("/v1/me"))
        .count();
    harness.advance(3_600_000);
    let events = harness.events.take();
    assert!(
        events
            .iter()
            .any(|event| matches!(event, CoreEvent::CredentialRotated { .. })),
        "{events:#?}"
    );
    assert!(
        !events
            .iter()
            .any(|event| matches!(event, CoreEvent::ConnectionChanged { .. })),
        "no reconnect: {events:#?}"
    );
    let me_after = harness
        .http
        .lines()
        .iter()
        .filter(|line| line.ends_with("/v1/me"))
        .count();
    assert_eq!(me_before, me_after, "identity is not re-confirmed");
    harness.core.refresh_sessions();
    harness.pump();
    assert_eq!(
        bearer_of(&harness, "/api/2.0/omnigent/v1/sessions").as_deref(),
        Some("Bearer access-2")
    );

    // A fresh connect reuses the saved, refreshed grant.
    let core = Arc::clone(&harness.core);
    let phase = harness
        .run(async move { core.connect(format!("{WORKSPACE_HOST}/?o=42"), None).await })
        .unwrap();
    assert!(
        matches!(phase, ConnectionPhase::Connected { .. }),
        "{phase:?}"
    );

    // Sign-out forgets the grant.
    let core = Arc::clone(&harness.core);
    harness.run(async move { core.sign_out().await }).unwrap();
    assert!(lock(&harness.store.items).is_empty());
}

/// The desktop client: the published `omnigent` client's loopback redirect, bound per attempt
/// to the host listener's port (RFC 8252; Databricks matches `http://localhost` ignoring it).
#[test]
fn databricks_loopback_sign_in_binds_the_listeners_port() {
    let mut harness = Harness::with_databricks(
        UrlPolicy::Release,
        Some(DatabricksOAuthSettings {
            client_id: "omnigent".into(),
            redirect_url: "http://localhost".into(),
        }),
    );
    route_databricks(&harness, "access-1", 3_600);
    let core = Arc::clone(&harness.core);
    let phase = harness
        .run(async move { core.connect(format!("{WORKSPACE_HOST}/?o=42"), None).await })
        .unwrap();
    let ConnectionPhase::SignInRequired { methods, .. } = phase else {
        panic!("{phase:?}");
    };
    assert_eq!(
        methods,
        vec![SignInMethod::DatabricksWorkspace {
            workspace_host: "dbc-1.cloud.databricks.com".into(),
            loopback: true,
            callback_host: "localhost".into(),
            callback_path: "/".into(),
        }]
    );
    assert!(
        matches!(
            harness.core.begin_databricks_sign_in(None),
            Err(CoreError::InvalidState { .. })
        ),
        "a loopback client needs its port"
    );

    let challenge = harness.core.begin_databricks_sign_in(Some(49_152)).unwrap();
    let authorize = url::Url::parse(&challenge.authorize_url).unwrap();
    let query: std::collections::HashMap<_, _> = authorize.query_pairs().into_owned().collect();
    assert_eq!(query["client_id"], "omnigent");
    assert_eq!(query["redirect_uri"], "http://localhost:49152");
    let state = query["state"].clone();

    // Another port's callback is refused; this one's completes, exchanging with the same URI.
    let callback = format!("http://localhost:49152/?code=abc&state={state}");
    let core = Arc::clone(&harness.core);
    let attempt = challenge.attempt_id;
    let server = harness
        .run(async move { core.complete_databricks_sign_in(attempt, callback).await })
        .unwrap();
    assert_eq!(server.user_id, "ada");
    let token_body = lock(&harness.http.requests)
        .iter()
        .find(|request| request.url.ends_with("/oidc/v1/token"))
        .and_then(|request| request.body.clone())
        .map(|body| String::from_utf8(body).unwrap())
        .unwrap();
    assert!(
        token_body.contains("redirect_uri=http%3A%2F%2Flocalhost%3A49152"),
        "{token_body}"
    );
    assert_eq!(
        bearer_of(&harness, "/api/2.0/omnigent/v1/me").as_deref(),
        Some("Bearer access-1")
    );
}

#[test]
fn databricks_loopback_callbacks_on_another_port_are_refused() {
    let mut harness = Harness::with_databricks(
        UrlPolicy::Release,
        Some(DatabricksOAuthSettings {
            client_id: "omnigent".into(),
            redirect_url: "http://localhost".into(),
        }),
    );
    route_databricks(&harness, "access-1", 3_600);
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.connect(format!("{WORKSPACE_HOST}/?o=42"), None).await })
        .unwrap();
    let challenge = harness.core.begin_databricks_sign_in(Some(49_152)).unwrap();
    let state = url::Url::parse(&challenge.authorize_url)
        .unwrap()
        .query_pairs()
        .find(|(name, _)| name == "state")
        .map(|(_, value)| value.into_owned())
        .unwrap();
    let callback = format!("http://localhost:49153/?code=abc&state={state}");
    let core = Arc::clone(&harness.core);
    let attempt = challenge.attempt_id;
    let result =
        harness.run(async move { core.complete_databricks_sign_in(attempt, callback).await });
    assert!(
        matches!(result, Err(CoreError::Databricks { .. })),
        "{result:?}"
    );
    assert!(
        !lock(&harness.http.requests)
            .iter()
            .any(|request| request.url.ends_with("/oidc/v1/token")),
        "no token request for a callback on another port"
    );
}

#[test]
fn databricks_callbacks_that_do_not_match_are_refused_without_a_token_request() {
    let mut harness = databricks();
    route_databricks(&harness, "access-1", 3_600);
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.connect(format!("{WORKSPACE_HOST}/?o=42"), None).await })
        .unwrap();
    let challenge = harness.core.begin_databricks_sign_in(None).unwrap();
    let core = Arc::clone(&harness.core);
    let attempt = challenge.attempt_id;
    let error = harness
        .run(async move {
            core.complete_databricks_sign_in(
                attempt,
                "https://login.databricks.com/mobile-redirect?state=forged&code=abc".into(),
            )
            .await
        })
        .unwrap_err();
    assert!(matches!(
        error,
        CoreError::Databricks {
            kind: crate::errors::DatabricksErrorKind::InvalidCallback,
            ..
        }
    ));
    assert!(
        !harness
            .http
            .lines()
            .iter()
            .any(|line| line.ends_with("/oidc/v1/token"))
    );
    assert!(matches!(
        harness.events.all().last(),
        Some(CoreEvent::ConnectionChanged {
            phase: ConnectionPhase::SignInRequired {
                reason: Some(_),
                ..
            }
        })
    ));
}

#[test]
fn databricks_without_a_build_client_offers_no_method_and_fails_clearly() {
    let mut harness = Harness::new(UrlPolicy::Release);
    let core = Arc::clone(&harness.core);
    let error = harness
        .run(async move { core.connect(format!("{WORKSPACE_HOST}/?o=42"), None).await })
        .unwrap_err();
    assert!(matches!(
        error,
        CoreError::Databricks {
            kind: crate::errors::DatabricksErrorKind::NotConfigured,
            ..
        }
    ));
}

#[derive(Default)]
struct AttachRecorder {
    states: std::sync::Mutex<Vec<crate::terminal::TerminalAttachState>>,
    output: std::sync::Mutex<Vec<u8>>,
    dropped: std::sync::Mutex<Vec<u64>>,
    resets: std::sync::atomic::AtomicUsize,
}

impl crate::terminal::TerminalAttachListener for AttachRecorder {
    fn on_state(&self, state: crate::terminal::TerminalAttachState) {
        lock(&self.states).push(state);
    }
    fn on_output(&self, bytes: Vec<u8>) {
        lock(&self.output).extend(bytes);
    }
    fn on_reset_screen(&self) {
        self.resets
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    }
    fn on_clipboard_write(&self, _text: String) {}
    fn on_input_dropped(&self, byte_count: u64, _reason: crate::terminal::TerminalInputDropReason) {
        lock(&self.dropped).push(byte_count);
    }
    fn on_notice(&self, message: String) {
        panic!("unexpected notice: {message}");
    }
}

#[test]
fn a_terminal_attach_streams_binary_both_ways_and_closes_on_4404() {
    use crate::host::{SocketEnd, SocketMessage};
    use crate::terminal::{TerminalAttachState, TerminalClosedReason};
    let mut harness = connected();
    let recorder = Arc::new(AttachRecorder::default());
    let driver = harness.core.terminal_attach(
        "conv_a".into(),
        "terminal_codex_main".into(),
        Some(4),
        Some("host_1".into()),
        recorder.clone(),
    );
    driver.send_input(b"early".to_vec());
    driver.start();
    harness.pump();
    assert_eq!(
        lock(&recorder.dropped).as_slice(),
        &[5],
        "input is never buffered"
    );
    let (request, sink, socket) = harness.sockets.last();
    assert!(
        request.url.starts_with(
            "ws://127.0.0.1:6767/v1/sessions/conv_a/resources/terminals/terminal_codex_main/attach"
        ),
        "{}",
        request.url
    );
    assert!(request.url.contains("omnigent_slice_key=host_1"));
    assert!(!request.url.contains("read_only"));
    sink.opened();
    harness.pump();
    driver.resize(120, 40).unwrap();
    driver.send_input(b"ls\r".to_vec());
    harness.pump();
    assert_eq!(lock(&socket.sent_binary).as_slice(), &[b"ls\r".to_vec()]);
    assert!(
        lock(&socket.sent)
            .iter()
            .any(|frame| frame.contains("resize")),
        "{:?}",
        lock(&socket.sent)
    );
    sink.message(SocketMessage::Binary {
        bytes: b"total 0\r\n".to_vec(),
    });
    harness.pump();
    assert_eq!(lock(&recorder.output).as_slice(), b"total 0\r\n");
    assert!(driver.resize(0, 40).is_err());
    sink.ended(SocketEnd::Closed {
        code: 4404,
        reason: "terminal not found".into(),
    });
    harness.pump();
    let states = lock(&recorder.states).clone();
    assert!(matches!(
        states.first(),
        Some(TerminalAttachState::Connecting)
    ));
    assert!(states.contains(&TerminalAttachState::Attached { read_only: false }));
    assert!(matches!(
        states.last(),
        Some(TerminalAttachState::Closed {
            reason: TerminalClosedReason::TerminalEnded { .. }
        })
    ));
    assert_eq!(recorder.resets.load(std::sync::atomic::Ordering::SeqCst), 0);
}

#[test]
fn terminal_lists_and_resource_events_publish_the_inventory_and_harness_view() {
    use crate::terminal::HarnessTerminal;
    let mut harness = connected();
    let session = "facbcc05b00f4321b98b1929d217abc5";
    let mut snapshot: serde_json::Value = serde_json::from_str(&envelope_response(
        "sessions/recorded-session-get-no-items.json",
    ))
    .unwrap();
    snapshot["labels"] = serde_json::json!({"omnigent.ui": "terminal"});
    snapshot["terminal_pending"] = serde_json::json!(true);
    harness.http.route(
        &format!("/v1/sessions/{session}"),
        json(200, &snapshot.to_string()),
    );
    harness.http.route(
        &format!("/v1/sessions/{session}/items"),
        json(200, r#"{"object":"list","data":[],"has_more":false}"#),
    );
    harness.http.route(
        &format!("/v1/sessions/{session}/resources/terminals"),
        json(200, r#"{"object":"list","data":[],"has_more":false}"#),
    );
    harness.core.open_session(session.into());
    harness.pump();
    let (sink, _, _) = harness.streams.last();
    sink.response(
        200,
        vec![crate::http::HttpHeader {
            name: "Content-Type".into(),
            value: "text/event-stream".into(),
        }],
    );
    sink.chunk(b"event: session.heartbeat\ndata: {\"type\":\"session.heartbeat\"}\n\n".to_vec());
    harness.pump();
    let harness_views = |events: &[CoreEvent]| -> Vec<HarnessTerminal> {
        events
            .iter()
            .filter_map(|event| match event {
                CoreEvent::TerminalsChanged { harness, .. } => Some(harness.clone()),
                _ => None,
            })
            .collect()
    };
    assert_eq!(
        harness_views(&harness.events.all()).last(),
        Some(&HarnessTerminal::StartingUp),
        "{:?}",
        harness.http.lines()
    );
    assert!(
        harness
            .http
            .lines()
            .contains(&format!("GET /v1/sessions/{session}/resources/terminals"))
    );
    let created = format!(
        "event: session.resource.created\ndata: {{\"type\":\"session.resource.created\",\"resource\":{{\"id\":\"terminal_codex_main\",\"type\":\"terminal\",\"session_id\":\"{session}\",\"metadata\":{{\"running\":true}}}}}}\n\n"
    );
    harness.http.route(
        &format!("/v1/sessions/{session}/resources/terminals"),
        json(
            200,
            r#"{"object":"list","data":[{"id":"terminal_codex_main","type":"terminal","metadata":{"running":true}}],"has_more":false}"#,
        ),
    );
    sink.chunk(created.into_bytes());
    harness.pump();
    let views = harness_views(&harness.events.all());
    let Some(HarnessTerminal::Ready { terminal }) = views.last() else {
        panic!("{views:?}");
    };
    assert_eq!(terminal.id, "terminal_codex_main");
    assert!(terminal.is_agent_terminal);
}

#[test]
fn browser_action_requests_are_reported_once_and_claimed_before_posting() {
    use crate::browser::{BrowserActionClaim, BrowserActionDelivery};
    let mut harness = connected();
    let session = "facbcc05b00f4321b98b1929d217abc5";
    harness.http.route(
        &format!("/v1/sessions/{session}"),
        json(
            200,
            &envelope_response("sessions/recorded-session-get-no-items.json"),
        ),
    );
    harness.http.route(
        &format!("/v1/sessions/{session}/items"),
        json(200, r#"{"object":"list","data":[],"has_more":false}"#),
    );
    harness.core.open_session(session.into());
    harness.pump();
    let (sink, _, _) = harness.streams.last();
    sink.response(
        200,
        vec![crate::http::HttpHeader {
            name: "Content-Type".into(),
            value: "text/event-stream".into(),
        }],
    );
    let frame = "event: browser.action_request\ndata: {\"type\":\"browser.action_request\",\"action_id\":\"baction_1\",\"action\":\"navigate\",\"args\":{\"url\":\"https://example.com\"}}\n\n";
    sink.chunk(b"event: session.heartbeat\ndata: {\"type\":\"session.heartbeat\"}\n\n".to_vec());
    sink.chunk(frame.as_bytes().to_vec());
    sink.chunk(frame.as_bytes().to_vec());
    harness.pump();
    let requests: Vec<CoreEvent> = harness
        .events
        .all()
        .into_iter()
        .filter(|event| matches!(event, CoreEvent::BrowserActionRequested { .. }))
        .collect();
    assert_eq!(
        requests,
        vec![CoreEvent::BrowserActionRequested {
            session_id: session.into(),
            action_id: "baction_1".into(),
            action: "navigate".into(),
            args_json: r#"{"url":"https://example.com"}"#.into(),
        }]
    );

    harness.http.route_method(
        "POST",
        &format!("/v1/sessions/{session}/browser/action_claim/baction_1"),
        json(200, r#"{"claimed":true,"claim_token":"tok_1"}"#),
    );
    harness.http.route_method(
        "POST",
        &format!("/v1/sessions/{session}/browser/action_result/baction_1"),
        json(202, r#"{"resolved":true}"#),
    );
    let core = Arc::clone(&harness.core);
    let claim = harness
        .run(async move {
            core.claim_browser_action(session.into(), "baction_1".into())
                .await
        })
        .unwrap();
    assert_eq!(
        claim,
        BrowserActionClaim::Claimed {
            claim_token: "tok_1".into()
        }
    );
    let core = Arc::clone(&harness.core);
    let delivery = harness
        .run(async move {
            core.post_browser_action_result(
                session.into(),
                "baction_1".into(),
                "tok_1".into(),
                r#"{"ok":true}"#.into(),
            )
            .await
        })
        .unwrap();
    assert_eq!(delivery, BrowserActionDelivery::Resolved);
    let posted = lock(&harness.http.requests)
        .iter()
        .rev()
        .find(|request| request.url.contains("action_result"))
        .cloned()
        .unwrap();
    let body: serde_json::Value = serde_json::from_slice(&posted.body.unwrap()).unwrap();
    assert_eq!(
        body,
        serde_json::json!({"result": {"ok": true}, "claim_token": "tok_1"})
    );
    let core = Arc::clone(&harness.core);
    let error = harness
        .run(async move {
            core.post_browser_action_result(
                session.into(),
                "baction_1".into(),
                "tok_1".into(),
                "[1]".into(),
            )
            .await
        })
        .unwrap_err();
    assert!(matches!(error, CoreError::Decode { .. }));
}
