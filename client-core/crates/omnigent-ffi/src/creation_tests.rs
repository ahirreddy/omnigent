//! Session creation: records, rules, the host browser and the REST calls.

use omnigent_core::creation as core;

use crate::api_tests::route_creation;
use crate::creation::{
    AgentPickerSection, CreationAgent, CreationCatalog, CreationGit, CreationSelection,
    FirstMessage, HostEntry, HostWorktree, SandboxTarget, creation_approval_mode_menu,
    creation_offers_smart_routing, creation_readiness_warning, creation_starts_in_plan_mode,
    creation_unavailable_reason, is_valid_branch_name, max_session_title_chars,
};
use crate::errors::CoreError;
use crate::sandbox::SandboxProfile;
use crate::test_support::{Harness, connected, json};

fn agent(id: &str, harness: &str) -> CreationAgent {
    CreationAgent::from(core::CreationAgent {
        id: id.to_owned(),
        name: id.to_owned(),
        harness: Some(harness.to_owned()),
        ..core::CreationAgent::default()
    })
}

fn selection() -> CreationSelection {
    CreationSelection {
        host_id: "host_a".into(),
        agent_id: "ag_codex".into(),
        workspace: "/work/project".into(),
        ..CreationSelection::default()
    }
}

fn catalog() -> CreationCatalog {
    CreationCatalog {
        agents: vec![
            agent("ag_codex", "codex-native"),
            agent("ag_goose", "goose"),
        ],
        codex_plan_at_launch: true,
        smart_routing: true,
        ..CreationCatalog::from(core::CreationCatalog::default())
    }
}

#[test]
fn a_catalog_carries_nested_agents_and_reads_a_missing_destination_as_any_host() {
    let on_core = core::CreationCatalog {
        capabilities: core::CreationCapabilities {
            sibling_sessions: true,
            sibling_destinations:
                omnigent_core::session_families::SiblingDestinations::CurrentHostOrNewSandbox,
            mcp_registry: true,
            ..core::CreationCapabilities::default()
        },
        ..core::CreationCatalog::default()
    };
    let mapped = CreationCatalog::from(on_core.clone());
    assert!(mapped.sibling_sessions && mapped.mcp_registry);
    assert_eq!(
        crate::creation::launch_mcp_services(
            vec!["gone".into(), "docs".into(), "docs".into()],
            vec!["docs".into(), "wiki".into()]
        ),
        ["docs"]
    );
    assert_eq!(
        crate::creation::launch_mcp_problem(vec!["docs".into()], true, false).as_deref(),
        Some("Loading MCP services\u{2026}")
    );
    assert_eq!(
        crate::creation::launch_mcp_problem(Vec::new(), true, false),
        None
    );
    assert_eq!(
        mapped.sibling_session_destinations,
        Some(crate::sessions::SiblingSessionDestinations::CurrentHostOrNewSandbox)
    );
    assert_eq!(core::CreationCatalog::from(mapped.clone()), on_core);
    let unset = CreationCatalog {
        sibling_session_destinations: None,
        ..mapped
    };
    assert_eq!(
        core::CreationCatalog::from(unset)
            .capabilities
            .sibling_destinations,
        omnigent_core::session_families::SiblingDestinations::AnyHost
    );
}

#[test]
fn every_picker_section_maps() {
    for (on_core, on_ffi) in [
        (
            core::AgentPickerSection::Harness,
            AgentPickerSection::Harness,
        ),
        (core::AgentPickerSection::Agent, AgentPickerSection::Agent),
        (core::AgentPickerSection::Custom, AgentPickerSection::Custom),
    ] {
        assert_eq!(AgentPickerSection::from(on_core), on_ffi);
    }
}

#[test]
fn a_selection_keeps_every_field() {
    let on_core = core::CreationSelection::from(CreationSelection {
        host_id: "h".into(),
        agent_id: "a".into(),
        workspace: "/w".into(),
        model: Some("m".into()),
        reasoning_effort: Some("high".into()),
        approval_mode: Some("plan".into()),
        git: Some(CreationGit {
            branch_name: "topic".into(),
            base_branch: Some("main".into()),
            existing_worktree: true,
        }),
        plan_mode: true,
        project_id: Some("p".into()),
        smart_routing: true,
        mcp_registry_services: vec!["docs".into()],
    });
    assert_eq!(on_core.mcp_registry_services, ["docs"]);
    assert_eq!(on_core.host_id, "h");
    assert_eq!(on_core.agent_id, "a");
    assert_eq!(on_core.workspace, "/w");
    assert_eq!(on_core.model.as_deref(), Some("m"));
    assert_eq!(on_core.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(on_core.approval_mode.as_deref(), Some("plan"));
    let git = on_core.git.unwrap();
    assert_eq!(git.branch_name, "topic");
    assert_eq!(git.base_branch.as_deref(), Some("main"));
    assert!(git.existing_worktree);
    assert!(on_core.plan_mode);
    assert_eq!(on_core.project_id.as_deref(), Some("p"));
    assert!(on_core.smart_routing);
}

#[test]
fn the_form_rules_read_the_agent_and_catalog() {
    let menu = creation_approval_mode_menu(agent("c", "codex-native")).unwrap();
    assert_eq!(menu.harness, "Codex");
    assert_eq!(creation_approval_mode_menu(agent("g", "goose")), None);

    assert!(creation_starts_in_plan_mode(catalog(), "ag_codex".into()));
    assert!(!creation_starts_in_plan_mode(catalog(), "ag_goose".into()));
    assert!(creation_offers_smart_routing(catalog(), "ag_codex".into()));
    assert!(!creation_offers_smart_routing(catalog(), "ag_goose".into()));

    assert!(is_valid_branch_name("fix/login".into()));
    assert!(!is_valid_branch_name("no spaces".into()));
    assert_eq!(
        usize::try_from(max_session_title_chars()).unwrap(),
        core::MAX_TITLE_CHARS
    );
}

#[test]
fn an_sdk_agent_needing_sign_in_is_choosable_with_a_warning_and_a_cli_one_is_not() {
    let needs_sign_in = core::CreationCatalog {
        hosts: vec![core::CreationHost {
            host_id: "host_a".into(),
            name: "Mac".into(),
            status: "online".into(),
            sandbox_provider: None,
            configured_harnesses: Some(
                ["openai-agents", "codex-native"]
                    .into_iter()
                    .map(|harness| {
                        (
                            harness.to_owned(),
                            core::HarnessReadiness::NeedsAuthentication,
                        )
                    })
                    .collect(),
            ),
        }],
        agents: vec![
            core::CreationAgent::from(agent("ag_mock", "openai-agents")),
            core::CreationAgent::from(agent("ag_codex", "codex-native")),
        ],
        ..core::CreationCatalog::default()
    };
    let catalog = CreationCatalog::from(needs_sign_in);
    let reason =
        |agent: &str| creation_unavailable_reason(catalog.clone(), agent.into(), "host_a".into());
    let warning =
        |agent: &str| creation_readiness_warning(catalog.clone(), agent.into(), "host_a".into());
    assert_eq!(reason("ag_mock"), None);
    assert_eq!(
        warning("ag_mock").as_deref(),
        Some(core::AUTHENTICATION_MAY_BE_REQUIRED)
    );
    assert_eq!(
        reason("ag_codex").as_deref(),
        Some(core::AUTHENTICATION_REQUIRED)
    );
    assert_eq!(warning("ag_codex"), None);
}

#[test]
fn the_folder_browser_reads_each_field_and_refuses_a_relative_path() {
    let mut harness = connected();
    harness.http.route(
        "/v1/hosts/host_a/filesystem/Users/me/repo",
        json(
            200,
            r#"{"data":[{"name":"src","path":"/Users/me/repo/src","type":"directory"},
                        {"name":"a.txt","path":"/Users/me/repo/a.txt","type":"file"}],
                "has_more":false}"#,
        ),
    );
    let listing = harness
        .call(|core| async move {
            core.host_directory("host_a".into(), Some("/Users/me/repo".into()))
                .await
        })
        .unwrap();
    assert_eq!(listing.path.as_deref(), Some("/Users/me/repo"));
    assert_eq!(listing.parent.as_deref(), Some("/Users/me"));
    assert_eq!(listing.directories.len(), 1);
    assert_eq!(listing.directories[0].path, "/Users/me/repo/src");
    assert_eq!(listing.directories[0].name, "src");

    let entries = harness
        .call(|core| async move {
            core.host_entries("host_a".into(), "/Users/me/repo".into())
                .await
        })
        .unwrap();
    assert_eq!(
        entries,
        [
            HostEntry {
                path: "/Users/me/repo/src".into(),
                name: "src".into(),
                is_directory: true,
            },
            HostEntry {
                path: "/Users/me/repo/a.txt".into(),
                name: "a.txt".into(),
                is_directory: false,
            },
        ]
    );

    assert!(
        harness
            .call(|core| async move {
                core.host_directory("host_a".into(), Some("rel".into()))
                    .await
            })
            .is_err()
    );
    assert!(
        harness
            .call(|core| async move { core.host_entries("host_a".into(), "rel".into()).await })
            .is_err()
    );
}

#[test]
fn worktrees_read_each_field_and_report_a_failure() {
    let mut harness = connected();
    harness.http.route(
        "/v1/hosts/host_a/worktrees",
        json(
            200,
            r#"{"object":"list","data":[
              {"path":"/r","branch":"main","is_main":true,"detached":false},
              {"path":"/r-wt","branch":null,"is_main":false,"detached":true}]}"#,
        ),
    );
    let worktrees = harness
        .call(|core| async move { core.host_worktrees("host_a".into(), "/r".into()).await })
        .unwrap();
    assert_eq!(
        worktrees,
        [
            HostWorktree {
                path: "/r".into(),
                branch: Some("main".into()),
                is_main: true,
            },
            HostWorktree {
                path: "/r-wt".into(),
                branch: None,
                is_main: false,
            },
        ]
    );
    assert_eq!(harness.last_query("path").as_deref(), Some("/r"));
    harness
        .http
        .route("/v1/hosts/host_a/worktrees", json(500, "{}"));
    assert!(
        harness
            .call(|core| async move { core.host_worktrees("host_a".into(), "/r".into()).await })
            .is_err()
    );
}

fn creating() -> Harness {
    let harness = connected();
    route_creation(&harness);
    harness
}

#[test]
fn a_new_session_posts_the_selection_and_returns_its_receipt() {
    let mut harness = creating();
    let receipt = harness
        .call(|core| async move {
            core.create_session(
                CreationSelection {
                    project_id: Some("proj_1".into()),
                    git: Some(CreationGit {
                        branch_name: "topic".into(),
                        base_branch: Some("main".into()),
                        existing_worktree: false,
                    }),
                    ..selection()
                },
                " Title ".into(),
            )
            .await
        })
        .unwrap();
    assert_eq!(receipt.session_id, "conv_created");
    assert_eq!(receipt.summary.unwrap().id, "conv_created");
    let (line, body) = harness.last_request();
    assert_eq!(line, "POST /v1/sessions");
    assert_eq!(body["agent_id"], "ag_codex");
    assert_eq!(body["workspace"], "/work/project");
    assert_eq!(body["project_id"], "proj_1");
    assert_eq!(body["title"], "Title");
    assert_eq!(body["git"]["branch_name"], "topic");
    assert_eq!(body["git"]["base_branch"], "main");

    let refused = harness.call(|core| async move {
        core.create_session(
            CreationSelection {
                workspace: "relative".into(),
                ..selection()
            },
            String::new(),
        )
        .await
    });
    assert!(matches!(refused, Err(CoreError::Session { .. })));
}

#[test]
fn a_sandbox_session_sends_the_target_and_a_host_id_when_asked() {
    let mut harness = creating();
    harness.http.route(
        "/v1/info",
        json(
            200,
            r#"{"single_user":true,"accounts_enabled":false,"managed_sandboxes_enabled":true,
                "sandbox_provider":"modal","sandbox_providers":["modal"],
                "request_managed_sandbox_host_id":true}"#,
        ),
    );
    let receipt = harness
        .call(|core| async move {
            core.create_sandbox_session(
                selection(),
                SandboxTarget {
                    provider: Some("modal".into()),
                    profile: Some(SandboxProfile {
                        id: "prof_1".into(),
                        name: "n".into(),
                        description: String::new(),
                        provider: "modal".into(),
                        revision: "rev_2".into(),
                    }),
                    workspaces: vec!["https://github.com/o/a".into()],
                },
                "Scratch".into(),
            )
            .await
        })
        .unwrap();
    assert_eq!(receipt.session_id, "conv_created");
    let (line, body) = harness.last_request();
    assert_eq!(line, "POST /v1/sessions");
    assert_eq!(body["host_type"], "managed");
    assert_eq!(body["sandbox_provider"], "modal");
    assert_eq!(body["sandbox_profile_id"], "prof_1");
    assert_eq!(body["sandbox_profile_revision"], "rev_2");
    assert_eq!(body["workspaces"][0], "https://github.com/o/a");
    assert_eq!(body["host_id"], "000102030405060708090a0b0c0d0e0f");

    let refused = harness.call(|core| async move {
        core.create_sandbox_session(
            selection(),
            SandboxTarget {
                provider: Some("docker".into()),
                ..SandboxTarget::default()
            },
            String::new(),
        )
        .await
    });
    assert!(refused.is_err());
}

#[test]
fn a_session_for_a_message_then_its_first_message_is_sent_separately() {
    let mut harness = creating();
    let receipt = harness
        .call(|core| async move {
            core.create_session_for_message(selection(), String::new(), "words".into())
                .await
        })
        .unwrap();
    assert_eq!(receipt.session_id, "conv_created");
    assert_eq!(harness.last_request_line(), "POST /v1/sessions");

    harness.http.route(
        "/v1/sessions/conv_created",
        json(
            200,
            r#"{"id":"conv_created","status":"idle","created_at":1,"permission_level":4}"#,
        ),
    );
    harness.http.route_method(
        "POST",
        "/v1/sessions/conv_created/events",
        json(
            202,
            r#"{"queued":true,"item_id":"item_1","pending_id":"p1"}"#,
        ),
    );
    let sent = harness
        .call(|core| async move {
            core.send_first_message("conv_created".into(), "words".into())
                .await
        })
        .unwrap();
    assert!(sent.queued);
    assert_eq!(sent.item_id.as_deref(), Some("item_1"));
    assert_eq!(sent.pending_id.as_deref(), Some("p1"));
    let (_, body) = harness.last_request();
    assert_eq!(body["data"]["content"][0]["text"], "words");

    let refused = harness.call(|core| async move {
        core.create_session_for_message(
            CreationSelection {
                workspace: "relative".into(),
                ..selection()
            },
            String::new(),
            "x".into(),
        )
        .await
    });
    assert!(refused.is_err());
    assert!(
        harness
            .call(|core| async move {
                core.send_first_message("conv_created".into(), " ".into())
                    .await
            })
            .is_err()
    );
}

#[test]
fn create_and_send_reports_a_sent_first_message() {
    let mut harness = creating();
    harness.http.route(
        "/v1/sessions/conv_created",
        json(
            200,
            r#"{"id":"conv_created","status":"idle","created_at":1,"permission_level":4}"#,
        ),
    );
    harness.http.route_method(
        "POST",
        "/v1/sessions/conv_created/events",
        json(202, r#"{"queued":true,"item_id":"item_1"}"#),
    );
    let created = harness
        .call(|core| async move {
            core.create_session_and_send(selection(), String::new(), "First".into())
                .await
        })
        .unwrap();
    assert_eq!(created.receipt.session_id, "conv_created");
    let FirstMessage::Sent { sent } = created.first_message else {
        panic!("not sent");
    };
    assert_eq!(sent.item_id.as_deref(), Some("item_1"));

    let refused = harness.call(|core| async move {
        core.create_session_and_send(
            CreationSelection {
                workspace: "relative".into(),
                ..selection()
            },
            String::new(),
            "x".into(),
        )
        .await
    });
    assert!(refused.is_err());
}

#[test]
fn a_demo_session_is_created_and_its_first_message_starts_the_reply() {
    let mut harness = Harness::demo();
    harness
        .call(|core| async move { core.connect(String::new(), None).await })
        .unwrap();
    let catalog = harness
        .call(|core| async move { core.creation_catalog().await })
        .unwrap();
    let chosen = CreationSelection {
        host_id: catalog.hosts[0].host_id.clone(),
        agent_id: catalog.agents[0].id.clone(),
        workspace: "/work/demo".into(),
        ..CreationSelection::default()
    };
    let second = chosen.clone();
    let created = harness
        .call(|core| async move {
            core.create_session_and_send(chosen, String::new(), "Hello".into())
                .await
        })
        .unwrap();
    assert!(
        matches!(created.first_message, FirstMessage::Sent { .. }),
        "{:?}",
        created.first_message
    );
    let next = harness
        .call(|core| async move {
            core.create_session_for_message(second, String::new(), "More".into())
                .await
        })
        .unwrap()
        .session_id;
    harness.core.sessions().set_live_session(&next, true);
    let queued = harness
        .call(move |core| async move {
            core.send_queued_message(next, "More".into(), None, None, vec![])
                .await
        })
        .unwrap();
    assert!(queued.queued);
}
