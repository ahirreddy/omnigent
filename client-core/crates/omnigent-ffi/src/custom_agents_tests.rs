//! Custom agents over the fake host: the draft and edit conversions and each export's request.

use omnigent_core::custom_agents as core;
use serde_json::json;

use crate::creation::{CreationGit, CreationSelection};
use crate::custom_agents::{
    AgentConfig, AgentConfigEdit, AgentDraft, AgentMcpServer, AgentRemoval, CredentialAction,
    CredentialEdit, McpServerEdit, McpServerForm, McpTransport, agent_draft_problem,
    agent_harness_choices,
};
use crate::engine::lock;
use crate::errors::CoreError;
use crate::fork::RunnerLaunch;
use crate::test_support::{Harness, connected, json as reply};

fn draft() -> AgentDraft {
    AgentDraft {
        name: "reviewer".into(),
        description: "Reviews".into(),
        instructions: "Be kind".into(),
        harness: "claude-sdk".into(),
        model: "sonnet".into(),
        mcp_servers: vec![
            McpServerForm {
                name: "local".into(),
                transport: McpTransport::Stdio,
                command: "tool".into(),
                arguments: "  --a   b ".into(),
                environment: "KEY=VALUE\n".into(),
                url: "ignored".into(),
                headers: "Ignored: yes".into(),
            },
            McpServerForm {
                name: "remote".into(),
                transport: McpTransport::Http,
                command: "ignored".into(),
                arguments: "ignored".into(),
                environment: "IGNORED=1".into(),
                url: "https://mcp.example".into(),
                headers: "Authorization: token\n".into(),
            },
        ],
    }
}

fn config() -> AgentConfig {
    AgentConfig {
        id: "a1".into(),
        name: "r".into(),
        version: u64::MAX,
        description: Some("old".into()),
        instructions: Some("do".into()),
        model: Some("m".into()),
        harness: Some("codex".into()),
        mcp_servers: vec![AgentMcpServer {
            name: "docs".into(),
            transport: "http".into(),
            url: Some("https://docs".into()),
            command: Some("cmd".into()),
            args: vec!["x".into()],
            editable: true,
            description: "Docs".into(),
            credential_names: vec!["Authorization".into()],
        }],
        etag: Some("\"v2\"".into()),
    }
}

fn unchanged() -> AgentConfigEdit {
    AgentConfigEdit {
        description: "old".into(),
        instructions: "do".into(),
        model: "m".into(),
        harness: "codex".into(),
        removed_mcp_servers: vec![],
        mcp_servers: vec![],
    }
}

fn agent_body(harness: &Harness) -> String {
    let request = lock(&harness.http.requests).last().unwrap().clone();
    String::from_utf8_lossy(request.body.as_deref().unwrap()).into_owned()
}

fn request_header(harness: &Harness, name: &str) -> Option<String> {
    let requests = lock(&harness.http.requests);
    requests
        .last()
        .unwrap()
        .headers
        .iter()
        .find(|header| header.name.eq_ignore_ascii_case(name))
        .map(|header| header.value.clone())
}

#[test]
fn the_harness_menu_is_the_cores() {
    let choices = agent_harness_choices();
    assert_eq!(choices.len(), core::AGENT_HARNESSES.len());
    assert_eq!(choices[0].id, "claude-sdk");
    assert_eq!(choices[0].label, "Claude SDK");
}

#[test]
fn a_draft_converts_each_transport_with_only_its_own_fields() {
    let converted = core::AgentDraft::from(draft());
    assert_eq!(converted.name, "reviewer");
    assert_eq!(converted.description, "Reviews");
    assert_eq!(converted.instructions, "Be kind");
    assert_eq!(converted.harness, "claude-sdk");
    assert_eq!(converted.model, "sonnet");
    let core::McpServerDraft::Stdio {
        name,
        command,
        args,
        env,
    } = &converted.mcp_servers[0]
    else {
        panic!("expected stdio: {:?}", converted.mcp_servers[0]);
    };
    assert_eq!(name, "local");
    assert_eq!(command, "tool");
    assert_eq!(args, &["--a", "b"]);
    assert_eq!(env, &core::key_value_lines("KEY=VALUE"));
    let core::McpServerDraft::Http { name, url, headers } = &converted.mcp_servers[1] else {
        panic!("expected http: {:?}", converted.mcp_servers[1]);
    };
    assert_eq!(name, "remote");
    assert_eq!(url, "https://mcp.example");
    assert_eq!(headers, &core::key_value_lines("Authorization: token"));
}

#[test]
fn a_draft_problem_is_the_cores_reason() {
    assert_eq!(agent_draft_problem(draft()), None);
    let nameless = AgentDraft {
        name: String::new(),
        ..draft()
    };
    assert!(agent_draft_problem(nameless).is_some());
}

#[test]
fn a_config_round_trips_every_field_and_edits_keep_each_credential_action() {
    let original = config();
    let core_config = core::AgentConfig::from(original.clone());
    assert_eq!(core_config.version, u64::MAX);
    assert_eq!(
        core_config.mcp_servers[0].credential_names,
        ["Authorization"]
    );
    assert_eq!(AgentConfig::from(core_config), original);

    let edit = AgentConfigEdit {
        removed_mcp_servers: vec!["gone".into()],
        mcp_servers: vec![McpServerEdit {
            name: "docs".into(),
            transport: "http".into(),
            description: "D".into(),
            url: "https://u".into(),
            command: "c".into(),
            args: vec!["a".into()],
            credentials: vec![
                CredentialEdit {
                    name: "K".into(),
                    value: String::new(),
                    action: CredentialAction::Keep,
                    existing: true,
                },
                CredentialEdit {
                    name: "R".into(),
                    value: "new".into(),
                    action: CredentialAction::Replace,
                    existing: false,
                },
                CredentialEdit {
                    name: "X".into(),
                    value: String::new(),
                    action: CredentialAction::Remove,
                    existing: true,
                },
            ],
        }],
        ..unchanged()
    };
    let converted = core::AgentConfigEdit::from(edit);
    assert_eq!(converted.description, "old");
    assert_eq!(converted.instructions, "do");
    assert_eq!(converted.model, "m");
    assert_eq!(converted.harness, "codex");
    assert_eq!(converted.removed_mcp_servers, ["gone"]);
    let server = &converted.mcp_servers[0];
    assert_eq!(server.name, "docs");
    assert_eq!(server.transport, "http");
    assert_eq!(server.description, "D");
    assert_eq!(server.url, "https://u");
    assert_eq!(server.command, "c");
    assert_eq!(server.args, ["a"]);
    assert_eq!(
        server
            .credentials
            .iter()
            .map(|credential| (
                credential.name.as_str(),
                credential.action,
                credential.existing
            ))
            .collect::<Vec<_>>(),
        [
            ("K", core::CredentialAction::Keep, true),
            ("R", core::CredentialAction::Replace, false),
            ("X", core::CredentialAction::Remove, true),
        ]
    );
    assert_eq!(server.credentials[1].value, "new");
}

#[test]
fn removal_arms_map() {
    assert_eq!(
        AgentRemoval::from(core::AgentRemoval::Removed),
        AgentRemoval::Removed
    );
    assert_eq!(
        AgentRemoval::from(core::AgentRemoval::InUse {
            message: "2".into()
        }),
        AgentRemoval::InUse {
            message: "2".into()
        }
    );
}

#[test]
fn the_list_maps_each_field_and_mine_asks_for_the_callers() {
    let mut harness = connected();
    harness.http.route(
        "/v1/agents",
        reply(
            200,
            r#"{"data":[{"id":"a1","name":"one","description":"D","harness":"codex",
                "created_at":18446744073709551615,"updated_at":2,"builtin":true}],"has_more":false}"#,
        ),
    );
    let agents = harness
        .call(|core| async move { core.managed_agents(true).await })
        .unwrap();
    assert_eq!(harness.last_query("scope").as_deref(), Some("user"));
    let agent = &agents[0];
    assert_eq!(agent.id, "a1");
    assert_eq!(agent.name, "one");
    assert_eq!(agent.description.as_deref(), Some("D"));
    assert_eq!(agent.harness.as_deref(), Some("codex"));
    assert_eq!(agent.harness_label, "Codex");
    assert_eq!(agent.created_at, Some(u64::MAX));
    assert_eq!(agent.updated_at, Some(2));
    assert!(agent.builtin);
    harness
        .call(|core| async move { core.managed_agents(false).await })
        .unwrap();
    assert_eq!(harness.last_query("scope"), None);
}

#[test]
fn installing_sends_a_multipart_bundle_with_a_generated_boundary() {
    let mut harness = connected();
    harness
        .http
        .route("/v1/agents", reply(200, r#"{"id":"a1","name":"reviewer"}"#));
    let agent = harness
        .call(|core| async move {
            core.install_agent_bundle(b"tar".to_vec(), "x.tar.gz".into())
                .await
        })
        .unwrap();
    assert_eq!(agent.name, "reviewer");
    let content_type = request_header(&harness, "Content-Type").unwrap();
    let boundary = content_type
        .strip_prefix("multipart/form-data; boundary=omnigent-")
        .unwrap();
    assert_eq!(boundary.len(), 22, "16 random bytes, base64url");
    assert!(agent_body(&harness).contains("filename=\"x.tar.gz\""));
    assert_eq!(harness.last_request_line(), "POST /v1/agents");

    let agent = harness
        .call(|core| async move { core.install_agent(draft()).await })
        .unwrap();
    assert_eq!(agent.id, "a1");
    assert!(agent_body(&harness).contains("filename=\"agent.tar.gz\""));

    let sent = harness.http.lines().len();
    let error = harness
        .call(|core| async move {
            core.install_agent(AgentDraft {
                name: String::new(),
                ..draft()
            })
            .await
        })
        .unwrap_err();
    assert!(matches!(error, CoreError::Session { .. }), "{error:?}");
    assert_eq!(
        harness.http.lines().len(),
        sent,
        "an invalid draft sends nothing"
    );
}

#[test]
fn an_unsaved_agent_is_uploaded_with_its_session_and_started_on_the_host() {
    let mut harness = connected();
    harness.http.route(
        "/v1/hosts",
        reply(
            200,
            r#"{"hosts":[{"host_id":"host_a","name":"Mac","status":"online"}]}"#,
        ),
    );
    harness.http.route_method(
        "POST",
        "/v1/sessions",
        reply(201, r#"{"session_id":"conv_new","agent_id":"ag_new"}"#),
    );
    harness.http.route_method(
        "POST",
        "/v1/hosts/host_a/runners",
        reply(201, r#"{"runner_id":"run_1"}"#),
    );
    let selection = CreationSelection {
        host_id: "host_a".into(),
        workspace: "/work/app".into(),
        git: Some(CreationGit {
            branch_name: "feat".into(),
            base_branch: Some("main".into()),
            existing_worktree: false,
        }),
        ..CreationSelection::default()
    };
    let created = harness
        .call(|core| async move {
            core.create_session_with_agent(draft(), selection, "Title".into())
                .await
        })
        .unwrap();
    assert_eq!(created.receipt.session_id, "conv_new");
    assert_eq!(
        created.launch,
        RunnerLaunch::Launched {
            runner_id: "run_1".into()
        }
    );
    assert_eq!(
        harness.last_request(),
        (
            "POST /v1/hosts/host_a/runners".into(),
            json!({"session_id": "conv_new", "workspace": "/work/app",
                   "git": {"branch_name": "feat", "base_branch": "main"}})
        )
    );
}

#[test]
fn a_config_is_read_and_saved_with_only_what_changed_and_its_revision() {
    let mut harness = connected();
    let body = r#"{"id":"a1","name":"r","version":3,"description":"D","instructions":"I","model":"m2",
        "harness":"codex","mcp_servers":{"docs":{"transport":"http","url":"https://docs",
        "editable":true,"description":"Docs","configured_header_names":["Authorization"]},
        "tool":{"transport":"stdio","command":"cmd","args":["x"],"editable":false,
        "configured_env_names":["KEY"]}}}"#;
    harness
        .http
        .route_method("GET", "/v1/agents/a1/config", reply(200, body));
    harness
        .http
        .route_method("PATCH", "/v1/agents/a1", reply(200, body));
    let loaded = harness
        .call(|core| async move { core.agent_config("a1".into()).await })
        .unwrap();
    assert_eq!(loaded.id, "a1");
    assert_eq!(loaded.version, 3);
    assert_eq!(loaded.model.as_deref(), Some("m2"));
    let docs = &loaded.mcp_servers[0];
    assert_eq!(docs.name, "docs");
    assert_eq!(docs.transport, "http");
    assert_eq!(docs.url.as_deref(), Some("https://docs"));
    assert!(docs.editable);
    assert_eq!(docs.description, "Docs");
    assert_eq!(docs.credential_names, ["Authorization"]);
    let tool = &loaded.mcp_servers[1];
    assert_eq!(tool.command.as_deref(), Some("cmd"));
    assert_eq!(tool.args, ["x"]);
    assert!(!tool.editable);
    assert_eq!(tool.credential_names, ["KEY"]);

    let sent = harness.http.lines().len();
    let same = harness
        .call(|core| async move { core.update_agent_config(config(), unchanged()).await })
        .unwrap();
    assert_eq!(same, config());
    assert_eq!(
        harness.http.lines().len(),
        sent,
        "nothing changed, nothing sent"
    );

    let saved = harness
        .call(|core| async move {
            core.update_agent_config(
                config(),
                AgentConfigEdit {
                    model: "m2".into(),
                    ..unchanged()
                },
            )
            .await
        })
        .unwrap();
    assert_eq!(saved.version, 3);
    assert_eq!(
        harness.last_request(),
        ("PATCH /v1/agents/a1".into(), json!({"model": "m2"}))
    );
    assert_eq!(
        request_header(&harness, "If-Match").as_deref(),
        Some("\"v2\"")
    );

    let error = harness
        .call(|core| async move {
            core.update_agent_config(
                config(),
                AgentConfigEdit {
                    model: "  ".into(),
                    ..unchanged()
                },
            )
            .await
        })
        .unwrap_err();
    assert!(matches!(error, CoreError::Session { .. }), "{error:?}");
}

#[test]
fn removal_reports_agents_in_use_and_force_is_sent() {
    let mut harness = connected();
    harness.http.route_method(
        "DELETE",
        "/v1/agents/a1",
        reply(
            409,
            r#"{"error":{"code":"agent_in_use","message":"2 session(s) still use 'r'"}}"#,
        ),
    );
    assert_eq!(
        harness
            .call(|core| async move { core.remove_agent("a1".into(), false).await })
            .unwrap(),
        AgentRemoval::InUse {
            message: "2 session(s) still use 'r'".into()
        }
    );
    harness.http.route_method(
        "DELETE",
        "/v1/agents/a1",
        reply(200, r#"{"id":"a1","deleted":true}"#),
    );
    assert_eq!(
        harness
            .call(|core| async move { core.remove_agent("a1".into(), true).await })
            .unwrap(),
        AgentRemoval::Removed
    );
    assert_eq!(harness.last_query("force").as_deref(), Some("true"));
}
