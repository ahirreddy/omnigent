//! Session creation REST tests, ported from `NativeLab`'s `SessionCreationTests`.

use futures::executor::block_on;
use serde_json::json;

use super::create::FirstMessage;
use super::test_support::{
    Reply, RouteTransport, body_json, connected, envelopes, header, path_of, query_value,
};
use super::{ClientEvent, SessionError};
use crate::creation::{CreationError, CreationGit, CreationSelection, SandboxTarget};

const CREATION: &str = "sessions/SessionCreation--";

fn selection() -> CreationSelection {
    CreationSelection {
        host_id: "host_a".into(),
        agent_id: "ag_codex".into(),
        workspace: "/work/project".into(),
        model: None,
        ..CreationSelection::default()
    }
}

/// The suite's default stubs: one online host, one Codex agent, its model options and a 201.
fn stub() -> RouteTransport {
    let transport = RouteTransport::local();
    for shared in ["hosts", "agents", "model-options"] {
        transport.load(&format!("{CREATION}_shared--{shared}.json"));
    }
    transport.load(&format!(
        "{CREATION}201PostsExactExternalHostContractWithoutInitialPrompt.json"
    ));
    transport
}

fn posts(transport: &RouteTransport) -> usize {
    transport
        .taken()
        .iter()
        .filter(|request| request.method == "POST")
        .count()
}

#[test]
fn catalog_paginates_and_deduplicates_durable_agent_i_ds() {
    let transport = stub();
    transport.load(&format!(
        "{CREATION}CatalogPaginatesAndDeduplicatesDurableAgentIDs.jsonl"
    ));
    let core = connected(transport);
    let catalog = block_on(core.creation_catalog()).unwrap();
    assert_eq!(
        catalog
            .agents
            .iter()
            .map(|a| a.id.as_str())
            .collect::<Vec<_>>(),
        ["ag_first", "ag_codex"]
    );
    let requests = core.transport().taken();
    assert!(requests.iter().all(|request| request.method == "GET"));
    let agent_pages: Vec<_> = requests
        .iter()
        .filter(|request| path_of(request) == "/v1/agents")
        .collect();
    assert_eq!(agent_pages.len(), 2);
    assert_eq!(
        query_value(agent_pages[1], "after").as_deref(),
        Some("ag_first")
    );
}

#[test]
fn directory_pagination_uses_path_and_does_not_offer_files() {
    let transport = stub();
    transport.load(&format!(
        "{CREATION}DirectoryPaginationUsesPathAndDoesNotOfferFiles.jsonl"
    ));
    let core = connected(transport);
    let workspaces = block_on(core.creation_workspaces("host_a")).unwrap();
    assert_eq!(
        workspaces
            .iter()
            .map(|w| w.path.as_str())
            .collect::<Vec<_>>(),
        ["/home/alpha", "/home/project"]
    );
    let requests = core.transport().taken();
    assert!(requests.iter().all(|request| request.method == "GET"));
    assert_eq!(
        query_value(requests.last().unwrap(), "after").as_deref(),
        Some("/home/notes.txt")
    );
}

#[test]
fn repeated_directory_cursor_stops_instead_of_looping() {
    let transport = stub();
    transport.load(&format!(
        "{CREATION}RepeatedDirectoryCursorStopsInsteadOfLooping.json"
    ));
    let core = connected(transport);
    assert_eq!(
        block_on(core.creation_workspaces("host_a")),
        Err(SessionError::InvalidPagination)
    );
}

#[test]
fn posts_201_exact_external_host_contract_without_initial_prompt() {
    let core = connected(stub());
    let recorder = super::test_support::record(&core);
    let value = CreationSelection {
        model: Some("provider-model".into()),
        workspace: " /work/project ".into(),
        ..selection()
    };
    let receipt = block_on(core.create_session(&value, " Review ")).unwrap();
    assert_eq!(receipt.session_id, "conv_created");
    assert_eq!(
        receipt.summary.as_ref().map(|s| s.id.as_str()),
        Some("conv_created")
    );
    let writes = core.transport().writes();
    assert_eq!(writes.len(), 1);
    let expected = envelopes(&format!(
        "{CREATION}201PostsExactExternalHostContractWithoutInitialPrompt.json"
    ))[0]
        .body
        .clone();
    assert_eq!(Some(body_json(&writes[0])), expected);
    assert_eq!(header(&writes[0], "Content-Type"), Some("application/json"));
    assert_eq!(header(&writes[0], "Authorization"), None);
    assert_eq!(header(&writes[0], "Cookie"), None);
    assert!(
        !core
            .transport()
            .lines()
            .iter()
            .any(|line| line.ends_with("/events"))
    );
    assert!(recorder.take().iter().any(|event| matches!(
        event,
        ClientEvent::SessionsChanged { sessions } if sessions[0].id == "conv_created"
    )));
}

#[test]
fn defaults_omit_model_and_blank_title() {
    let transport = stub();
    transport.load(&format!("{CREATION}DefaultsOmitModelAndBlankTitle.json"));
    let core = connected(transport);
    block_on(core.create_session(&selection(), " \n ")).unwrap();
    let writes = core.transport().writes();
    let body = body_json(&writes[0]);
    for key in [
        "model_override",
        "title",
        "initial_items",
        "harness_override",
        "terminal_launch_args",
    ] {
        assert!(body.get(key).is_none(), "{key}");
    }
    assert_eq!(
        Some(body),
        envelopes(&format!("{CREATION}DefaultsOmitModelAndBlankTitle.json"))[0]
            .body
            .clone()
    );
    assert!(
        !core
            .transport()
            .lines()
            .iter()
            .any(|line| line.ends_with("model-options"))
    );
}

#[test]
fn readiness_and_model_are_revalidated_immediately_before_post() {
    let core = connected(stub());
    block_on(core.creation_catalog()).unwrap();
    core.transport().load(&format!(
        "{CREATION}ReadinessAndModelAreRevalidatedImmediatelyBeforePost.json"
    ));
    assert!(matches!(
        block_on(core.create_session(&selection(), "")),
        Err(SessionError::Creation(CreationError::Unavailable(_)))
    ));
    assert_eq!(posts(core.transport()), 0);
}

#[test]
fn unadvertised_model_blocks_post_but_default_needs_no_model_catalog() {
    let transport = stub();
    transport.load(&format!(
        "{CREATION}UnadvertisedModelBlocksPostButDefaultNeedsNoModelCatalog.json"
    ));
    let core = connected(transport);
    let hidden = CreationSelection {
        model: Some("provider-model".into()),
        ..selection()
    };
    assert!(matches!(
        block_on(core.create_session(&hidden, "")),
        Err(SessionError::Creation(CreationError::Unavailable(_)))
    ));
    assert_eq!(posts(core.transport()), 0);
    block_on(core.create_session(&selection(), "")).unwrap();
    assert_eq!(posts(core.transport()), 1);
}

#[test]
fn accepted_id_survives_unknown_snapshot_shape_and_failed_hydration() {
    let transport = stub();
    transport.load(&format!(
        "{CREATION}AcceptedIDSurvivesUnknownSnapshotShapeAndFailedHydration.json"
    ));
    let core = connected(transport);
    let receipt = block_on(core.create_session(&selection(), "")).unwrap();
    assert_eq!(receipt.session_id, "conv_created");
    assert_eq!(receipt.summary, None);
    assert!(block_on(core.conversation_snapshot(&receipt.session_id)).is_err());
    assert_eq!(posts(core.transport()), 1);
    assert!(
        !core
            .transport()
            .lines()
            .iter()
            .any(|line| line.ends_with("/events"))
    );
}

#[test]
fn uncertain_writes_are_never_automatically_retried() {
    let cases = envelopes(&format!(
        "{CREATION}UncertainWritesAreNeverAutomaticallyRetried.jsonl"
    ));
    assert_eq!(cases.len(), 11);
    for case in cases {
        let transport = stub();
        transport.enqueue("POST", "/v1/sessions", vec![case.reply.clone()]);
        let core = connected(transport);
        assert_eq!(
            block_on(core.create_session(&selection(), "")),
            Err(SessionError::Creation(CreationError::Uncertain)),
            "{case:?}"
        );
        assert_eq!(posts(core.transport()), 1, "{case:?}");
    }
}

#[test]
fn validation_rejection_provides_server_explanation() {
    let transport = stub();
    transport.load(&format!(
        "{CREATION}ValidationRejectionProvidesServerExplanation.json"
    ));
    let core = connected(transport);
    assert_eq!(
        block_on(core.create_session(&selection(), "")),
        Err(SessionError::Creation(CreationError::Rejected {
            status: 400,
            message: "workspace does not exist".into()
        }))
    );
    assert_eq!(posts(core.transport()), 1);
}

#[test]
fn unauthorized_creation_ends_the_connection() {
    let transport = stub();
    transport.respond(Some("POST"), "/v1/sessions", None, Reply::json(401, "{}"));
    let core = connected(transport);
    assert_eq!(
        block_on(core.create_session(&selection(), "")),
        Err(SessionError::Unauthorized { reason: None })
    );
    assert!(!core.is_connected());
}

#[test]
fn create_success_then_send_failure_never_creates_a_second_session() {
    let transport = stub();
    transport.ok(
        "/v1/sessions/conv_created",
        r#"{"id":"conv_created","status":"idle","created_at":1,"permission_level":4,"host_id":"host_a","host_online":true}"#,
    );
    transport.respond(
        Some("POST"),
        "/v1/sessions/conv_created/events",
        None,
        Reply::json(500, "{}"),
    );
    let core = connected(transport);
    let created = block_on(core.create_session_and_send(&selection(), "", "First")).unwrap();
    assert_eq!(created.receipt.session_id, "conv_created");
    assert!(matches!(
        created.first_message,
        FirstMessage::Failed(SessionError::DeliveryUncertain { .. })
    ));
    let lines = core.transport().lines();
    assert_eq!(
        lines
            .iter()
            .filter(|line| *line == "POST /v1/sessions")
            .count(),
        1
    );
    assert_eq!(
        lines
            .iter()
            .filter(|line| *line == "POST /v1/sessions/conv_created/events")
            .count(),
        1
    );
    // The retry goes to the created session, after the user reviews the uncertain send.
    assert_eq!(core.acknowledge_uncertain_send("conv_created"), Ok(true));
    core.transport().respond(
        Some("POST"),
        "/v1/sessions/conv_created/events",
        None,
        Reply::json(202, r#"{"queued":true,"item_id":"item_1"}"#),
    );
    core.set_live_session("conv_created", true);
    let sent = block_on(core.send_message("conv_created", "First")).unwrap();
    assert_eq!(sent.submission.item_id.as_deref(), Some("item_1"));
    assert_eq!(
        core.transport()
            .lines()
            .iter()
            .filter(|line| *line == "POST /v1/sessions")
            .count(),
        1
    );
    let bodies = core.transport().write_bodies();
    assert_eq!(
        bodies.last().unwrap(),
        &json!({"type": "message", "data": {"role": "user", "content": [
            {"type": "input_text", "text": "First"}
        ]}})
    );
}

#[test]
fn create_and_send_reports_the_first_message() {
    let transport = stub();
    transport.ok(
        "/v1/sessions/conv_created",
        r#"{"id":"conv_created","status":"idle","created_at":1,"permission_level":4}"#,
    );
    transport.respond(
        Some("POST"),
        "/v1/sessions/conv_created/events",
        None,
        Reply::json(202, r#"{"queued":true,"item_id":"item_1"}"#),
    );
    let core = connected(transport);
    let created = block_on(core.create_session_and_send(&selection(), "", "First")).unwrap();
    let FirstMessage::Sent(sent) = created.first_message else {
        panic!("first message not sent");
    };
    assert_eq!(sent.submission.item_id.as_deref(), Some("item_1"));
}

#[test]
fn a_session_in_a_project_is_filed_from_its_creation() {
    let transport = stub();
    with_agent_install(&transport);
    let core = connected(transport);
    let filed = CreationSelection {
        project_id: Some("proj_1".into()),
        ..selection()
    };
    block_on(core.create_session(&filed, "")).unwrap();
    block_on(core.create_sandbox_session(&filed, &sandbox(&[]), "")).unwrap();
    let bodies = core.transport().write_bodies();
    assert_eq!(bodies[0]["project_id"], "proj_1");
    assert_eq!(bodies[0]["workspace"], "/work/project");
    assert_eq!(bodies[1]["project_id"], "proj_1");
    assert_eq!(bodies[1]["workspace"], serde_json::Value::Null);
    assert_eq!(bodies[1]["git"], serde_json::Value::Null);
    let bad = CreationSelection {
        project_id: Some("../x".into()),
        ..selection()
    };
    assert!(matches!(
        block_on(core.create_session(&bad, "")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}

fn sandbox(workspaces: &[&str]) -> SandboxTarget {
    SandboxTarget {
        workspaces: workspaces.iter().map(|w| (*w).to_owned()).collect(),
        host_id: Some("0123456789abcdef0123456789abcdef".into()),
        ..SandboxTarget::default()
    }
}

#[test]
fn a_sandbox_session_posts_the_managed_contract_without_a_host() {
    let transport = stub();
    with_agent_install(&transport);
    let core = connected(transport);
    let receipt = block_on(core.create_sandbox_session(
        &selection(),
        &sandbox(&["https://github.com/example/repo#main"]),
        " Scratch ",
    ))
    .unwrap();
    assert_eq!(receipt.session_id, "conv_created");
    let writes = core.transport().writes();
    assert_eq!(writes.len(), 1);
    let body = body_json(&writes[0]);
    assert_eq!(body["agent_id"], "ag_codex");
    assert_eq!(body["host_type"], "managed");
    assert_eq!(
        body["workspaces"],
        json!(["https://github.com/example/repo#main"])
    );
    assert_eq!(body["title"], "Scratch");
    assert!(
        body.get("host_id").is_none(),
        "the server mints the sandbox host unless it asks: {body}"
    );
    assert!(body.get("workspace").is_none(), "{body}");
    assert!(body.get("sandbox_provider").is_none(), "{body}");

    let unknown = block_on(core.create_sandbox_session(
        &CreationSelection {
            agent_id: "ag_missing".into(),
            ..selection()
        },
        &sandbox(&[]),
        "",
    ));
    assert!(
        matches!(
            unknown,
            Err(SessionError::Creation(CreationError::Unavailable(_)))
        ),
        "{unknown:?}"
    );
    assert_eq!(
        posts(core.transport()),
        1,
        "nothing posted for an unknown agent"
    );
}

#[test]
fn a_sandbox_session_sends_its_provider_profile_host_id_and_run_configuration() {
    let transport = stub();
    transport.ok(
        "/v1/info",
        r#"{"single_user":true,"accounts_enabled":false,"managed_sandboxes_enabled":true,
            "sandbox_provider":"modal","sandbox_providers":["modal","agent_sandbox"],
            "sandbox_provider_capabilities":{"agent_sandbox":{"multi_repo":true}},
            "request_managed_sandbox_host_id":true}"#,
    );
    let core = connected(transport);
    let target = SandboxTarget {
        provider: Some("agent_sandbox".into()),
        profile: Some(("prof_1".into(), "rev_2".into())),
        ..sandbox(&["https://github.com/o/a", "git@github.com:o/b.git#dev"])
    };
    let codex = CreationSelection {
        reasoning_effort: Some("high".into()),
        approval_mode: Some("bypass".into()),
        ..selection()
    };
    block_on(core.create_sandbox_session(&codex, &target, "")).unwrap();
    let body = body_json(&core.transport().writes()[0]);
    assert_eq!(body["sandbox_provider"], "agent_sandbox");
    assert_eq!(body["sandbox_profile_id"], "prof_1");
    assert_eq!(body["sandbox_profile_revision"], "rev_2");
    assert_eq!(body["host_id"], "0123456789abcdef0123456789abcdef");
    assert_eq!(body["reasoning_effort"], "high");
    assert_eq!(body["labels"]["omnigent.codex_native.bypass_sandbox"], "1");
    assert!(body.get("terminal_launch_args").is_none(), "{body}");

    // The default provider clones one repository; an unknown provider is refused.
    for refused in [
        SandboxTarget {
            provider: None,
            ..target.clone()
        },
        SandboxTarget {
            provider: Some("docker".into()),
            ..target
        },
        sandbox(&["https://user@github.com/o/a"]),
    ] {
        let result = block_on(core.create_sandbox_session(&selection(), &refused, ""));
        assert!(
            matches!(
                result,
                Err(SessionError::Creation(CreationError::Unavailable(_)))
            ),
            "{refused:?}: {result:?}"
        );
    }
    assert_eq!(posts(core.transport()), 1);
}

/// `/v1/info` advertising the caller's own agents.
fn with_agent_install(transport: &RouteTransport) {
    transport.ok(
        "/v1/info",
        r#"{"single_user":true,"accounts_enabled":false,"agent_install":true,
            "managed_sandboxes_enabled":true,"sandbox_providers":["modal","docker"]}"#,
    );
}

#[test]
fn catalog_lists_the_callers_own_agents_when_the_server_installs_them() {
    let transport = stub();
    with_agent_install(&transport);
    transport.enqueue(
        "GET",
        "/v1/agents",
        vec![
            Reply::json(
                200,
                r#"{"data":[{"id":"ag_codex","name":"codex-native-ui","harness":"codex-native",
                    "builtin":true}],"has_more":false}"#,
            ),
            Reply::json(
                200,
                r#"{"data":[
                    {"id":"ag_mock_new","name":"mock-model","harness":"openai-agents",
                     "builtin":false,"updated_at":20},
                    {"id":"ag_mock_old","name":"mock-model (fork ag_x)","harness":"openai-agents",
                     "builtin":false,"created_at":10},
                    {"id":"ag_shadow","name":"codex-native-ui","harness":"codex-native"}
                   ],"has_more":true,"last_id":"ag_shadow"}"#,
            ),
            Reply::json(
                200,
                r#"{"data":[{"id":"ag_mine_claude","name":"reviewer","harness":"claude-native"}],
                    "has_more":false}"#,
            ),
        ],
    );
    let core = connected(transport);
    let catalog = block_on(core.creation_catalog()).unwrap();
    let ids: Vec<_> = catalog.agents.iter().map(|a| a.id.as_str()).collect();
    assert_eq!(ids, ["ag_codex", "ag_mock_new", "ag_mine_claude"]);
    assert!(catalog.capabilities.agent_install);
    assert!(catalog.capabilities.managed_sandboxes);
    assert_eq!(catalog.capabilities.sandbox_providers, ["modal", "docker"]);
    let requests = core.transport().taken();
    let user_pages: Vec<_> = requests
        .iter()
        .filter(|request| query_value(request, "scope").as_deref() == Some("user"))
        .collect();
    assert_eq!(user_pages.len(), 2);
    assert_eq!(query_value(user_pages[0], "limit").as_deref(), Some("50"));
    assert_eq!(
        query_value(user_pages[1], "after").as_deref(),
        Some("ag_shadow")
    );
}

#[test]
fn catalog_skips_user_agents_on_servers_without_agent_install() {
    let core = connected(stub());
    let catalog = block_on(core.creation_catalog()).unwrap();
    assert!(!catalog.capabilities.agent_install);
    assert!(!catalog.capabilities.managed_sandboxes);
    assert!(
        !core
            .transport()
            .taken()
            .iter()
            .any(|request| query_value(request, "scope").is_some())
    );
}

#[test]
fn creation_body_carries_effort_launch_mode_and_worktree() {
    let core = connected(stub());
    let value = CreationSelection {
        reasoning_effort: Some("high".into()),
        approval_mode: Some("full-access".into()),
        git: Some(CreationGit {
            branch_name: " feature/x ".into(),
            base_branch: Some("main".into()),
            existing_worktree: false,
        }),
        ..selection()
    };
    block_on(core.create_session(&value, "")).unwrap();
    let body = body_json(&core.transport().writes()[0]);
    assert_eq!(body["reasoning_effort"], json!("high"));
    assert_eq!(
        body["terminal_launch_args"],
        json!([
            "--sandbox",
            "danger-full-access",
            "--ask-for-approval",
            "never"
        ])
    );
    assert_eq!(
        body["git"],
        json!({"branch_name": "feature/x", "base_branch": "main"})
    );
}

#[test]
fn default_launch_mode_sends_no_args_and_unknown_modes_or_branches_block() {
    let core = connected(stub());
    let value = CreationSelection {
        approval_mode: Some("ask-for-approval".into()),
        git: Some(CreationGit {
            branch_name: "wt".into(),
            base_branch: Some("ignored".into()),
            existing_worktree: true,
        }),
        ..selection()
    };
    block_on(core.create_session(&value, "")).unwrap();
    let body = body_json(&core.transport().writes()[0]);
    assert!(body.get("terminal_launch_args").is_none());
    assert_eq!(
        body["git"],
        json!({"branch_name": "wt", "existing_worktree": true})
    );
    for value in [
        CreationSelection {
            approval_mode: Some("bypassPermissions".into()),
            ..selection()
        },
        CreationSelection {
            git: Some(CreationGit {
                branch_name: "bad name".into(),
                ..CreationGit::default()
            }),
            ..selection()
        },
    ] {
        assert!(matches!(
            block_on(core.create_session(&value, "")),
            Err(SessionError::Creation(CreationError::Unavailable(_)))
        ));
    }
    assert_eq!(posts(core.transport()), 1);
}

#[test]
fn host_directory_lists_home_then_absolute_paths_with_parents() {
    let transport = stub();
    transport.ok(
        "/v1/hosts/host_a/filesystem",
        r#"{"data":[{"name":".zshrc","path":"/Users/me/.zshrc","type":"file"},
            {"name":"src","path":"/Users/me/src","type":"directory"}],"has_more":false}"#,
    );
    transport.ok(
        "/v1/hosts/host_a/filesystem/Users/me/my%20repo",
        r#"{"data":[{"name":"app","path":"/Users/me/my repo/app","type":"directory"}],
            "has_more":false}"#,
    );
    let core = connected(transport);
    let home = block_on(core.host_directory("host_a", None)).unwrap();
    assert_eq!(home.path.as_deref(), Some("/Users/me"));
    assert_eq!(home.parent.as_deref(), Some("/Users"));
    assert_eq!(home.directories.len(), 1);
    let nested = block_on(core.host_directory("host_a", Some("/Users/me/my repo/"))).unwrap();
    assert_eq!(nested.path.as_deref(), Some("/Users/me/my repo"));
    assert_eq!(nested.directories[0].name, "app");
    for path in ["relative", "/a?b", "/a%20b"] {
        assert!(matches!(
            block_on(core.host_directory("host_a", Some(path))),
            Err(SessionError::InvalidIdentifier { .. })
        ));
    }
}

#[test]
fn host_entries_list_files_and_folders_of_an_absolute_directory() {
    let transport = stub();
    transport.ok(
        "/v1/hosts/host_a/filesystem/work/repo",
        r#"{"data":[{"name":"README.md","path":"/work/repo/README.md","type":"file"},
            {"name":"src","path":"/work/repo/src","type":"directory"}],"has_more":false}"#,
    );
    let core = connected(transport);
    let entries = block_on(core.host_entries("host_a", "/work/repo/")).unwrap();
    assert_eq!(entries.len(), 2);
    assert!(!entries[0].is_directory);
    assert!(entries[1].is_directory);
    assert_eq!(entries[1].path, "/work/repo/src");
    assert!(matches!(
        block_on(core.host_entries("host_a", "relative")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}

#[test]
fn host_worktrees_read_rows_and_treat_non_git_as_empty() {
    let transport = stub();
    transport.enqueue(
        "GET",
        "/v1/hosts/host_a/worktrees",
        vec![
            Reply::json(
                200,
                r#"{"object":"list","data":[
                    {"path":"/r","branch":"main","is_main":true,"detached":false},
                    {"path":"/r-wt","branch":null,"is_main":false,"detached":true}]}"#,
            ),
            Reply::json(400, r#"{"detail":"not a git repository"}"#),
        ],
    );
    let core = connected(transport);
    let worktrees = block_on(core.host_worktrees("host_a", "/r")).unwrap();
    assert_eq!(worktrees.len(), 2);
    assert!(worktrees[0].is_main);
    assert_eq!(worktrees[1].branch, None);
    let requests = core.transport().taken();
    let listed = requests
        .iter()
        .find(|request| path_of(request) == "/v1/hosts/host_a/worktrees")
        .unwrap();
    assert_eq!(query_value(listed, "path").as_deref(), Some("/r"));
    assert_eq!(
        block_on(core.host_worktrees("host_a", "/tmp")),
        Ok(Vec::new())
    );
}

fn malformed<T>(result: &Result<T, SessionError>) -> bool {
    matches!(result, Err(SessionError::MalformedResponse { .. }))
}

#[test]
fn a_repeated_agent_cursor_stops_the_catalog_instead_of_looping() {
    let transport = stub();
    let page = Reply::json(
        200,
        r#"{"data":[{"id":"ag_codex","name":"n","harness":"codex-native"}],
            "has_more":true,"last_id":"ag_same"}"#,
    );
    transport.enqueue("GET", "/v1/agents", vec![page.clone(), page.clone(), page]);
    let core = connected(transport);
    assert_eq!(
        block_on(core.creation_catalog()).unwrap_err(),
        SessionError::InvalidPagination
    );
}

#[test]
fn the_callers_agents_stop_at_fifty_root_names_and_keep_only_known_ones_after() {
    let transport = stub();
    with_agent_install(&transport);
    let rows: Vec<serde_json::Value> = (0..50)
        .map(|index| json!({"id": format!("ag_{index}"), "name": format!("n{index}"), "harness": "codex-native"}))
        .chain([
            json!({"id": "ag_fork", "name": "n0", "harness": "codex-native"}),
            json!({"id": "ag_over", "name": "over-the-limit", "harness": "codex-native"}),
        ])
        .collect();
    transport.enqueue(
        "GET",
        "/v1/agents",
        vec![
            Reply::json(200, r#"{"data":[],"has_more":false}"#),
            Reply::json(
                200,
                json!({"data": rows, "has_more": true, "last_id": "ag_over"}).to_string(),
            ),
        ],
    );
    let core = connected(transport);
    let catalog = block_on(core.creation_catalog()).unwrap();
    let ids: Vec<&str> = catalog
        .agents
        .iter()
        .map(|agent| agent.id.as_str())
        .collect();
    assert!(!ids.contains(&"ag_over"), "{ids:?}");
    let scoped = core
        .transport()
        .taken()
        .iter()
        .filter(|request| query_value(request, "scope").as_deref() == Some("user"))
        .count();
    assert_eq!(scoped, 1, "the limit ends the paging");
}

#[test]
fn malformed_catalog_pages_are_reported() {
    let transport = RouteTransport::local();
    transport.ok("/v1/hosts", r#"{"nope":[]}"#);
    transport.ok("/v1/hosts/host_a/harnesses/h/model-options", "[]");
    transport.ok(
        "/v1/hosts/host_a/harnesses/empty/model-options",
        r#"{"models":7}"#,
    );
    transport.ok("/v1/hosts/host_a/worktrees", r#"{"nope":[]}"#);
    transport.ok("/v1/hosts/host_a/filesystem", "[]");
    transport.ok("/v1/agents", "7");
    let core = connected(transport);
    assert!(malformed(&block_on(core.hosts())));
    assert!(malformed(&block_on(
        core.host_model_options("host_a", "h", true)
    )));
    assert!(malformed(&block_on(
        core.host_model_options("host_a", "empty", true)
    )));
    assert!(malformed(&block_on(core.host_worktrees("host_a", "/repo"))));
    assert!(malformed(&block_on(core.host_directory("host_a", None))));
    assert!(malformed(&block_on(core.agent_rows())));
}

#[test]
fn hosts_are_deduplicated_and_rows_without_an_id_skipped() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/hosts",
        r#"{"hosts":[{"host_id":"host_a","name":"A","status":"online"},
            {"host_id":"host_a","name":"Again","status":"offline"},
            {"host_id":"","name":"Blank","status":"online"}]}"#,
    );
    let core = connected(transport);
    let hosts = block_on(core.hosts()).unwrap();
    assert_eq!(
        hosts
            .iter()
            .map(|host| host.name.as_str())
            .collect::<Vec<_>>(),
        ["A"]
    );
    core.transport().ok("/v1/hosts", r#"{"hosts":[7]}"#);
    assert!(malformed(&block_on(core.hosts())));
}

#[test]
fn the_root_directory_is_its_own_path() {
    let transport = stub();
    transport.ok(
        "/v1/hosts/host_a/filesystem/",
        r#"{"data":[{"name":"etc","path":"/etc","type":"directory"}],"has_more":false}"#,
    );
    let core = connected(transport);
    let root = block_on(core.host_directory("host_a", Some("/"))).unwrap();
    assert_eq!(root.path.as_deref(), Some("/"));
    assert_eq!(root.directories[0].name, "etc");
    assert_eq!(root.parent, None);
}

#[test]
fn slashes_alone_are_no_directory() {
    let core = connected(stub());
    assert!(matches!(
        block_on(core.host_directory("host_a", Some("  "))),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}

#[test]
fn a_title_over_the_limit_is_refused_before_any_request() {
    let core = connected(stub());
    let long = "\u{1F600}".repeat(121);
    assert!(matches!(
        block_on(core.create_session(&selection(), &long)),
        Err(SessionError::Creation(CreationError::Unavailable(_)))
    ));
    assert_eq!(posts(core.transport()), 0);
    let sandboxed = sandbox(&["/work"]);
    assert!(matches!(
        block_on(core.create_sandbox_session(&selection(), &sandboxed, &long)),
        Err(SessionError::Creation(CreationError::Unavailable(_)))
    ));
    // Exactly at the limit counts characters, not bytes.
    let exact = "\u{1F600}".repeat(120);
    assert!(block_on(core.create_session(&selection(), &exact)).is_ok());
}

#[test]
fn models_for_an_unavailable_agent_or_one_without_a_preview_are_empty_or_refused() {
    let transport = stub();
    let core = connected(transport);
    assert!(matches!(
        block_on(core.creation_models("ag_missing", "host_a")),
        Err(SessionError::Creation(CreationError::Unavailable(_)))
    ));
    let plain = RouteTransport::local();
    plain.ok(
        "/v1/hosts",
        r#"{"hosts":[{"host_id":"host_a","name":"A","status":"online",
            "configured_harnesses":{"openai-agents":true}}]}"#,
    );
    plain.ok(
        "/v1/agents",
        r#"{"data":[{"id":"ag_plain","name":"n","harness":"openai-agents"}],"has_more":false}"#,
    );
    let core = connected(plain);
    assert_eq!(
        block_on(core.creation_models("ag_plain", "host_a")).unwrap(),
        [],
        "a harness without a model preview has no models to offer"
    );
}

#[test]
fn create_for_message_posts_and_the_first_message_can_follow_separately() {
    let transport = stub();
    transport.writable_session("[]");
    let core = connected(transport);
    let receipt =
        block_on(core.create_session_for_message(&selection(), "", "first words")).unwrap();
    assert_eq!(posts(core.transport()), 1);
    let session = receipt.session_id;
    core.transport().ok(
        &format!("/v1/sessions/{session}"),
        format!(r#"{{"id":"{session}","status":"idle","created_at":1,"permission_level":4}}"#),
    );
    core.transport().ok(
        &format!("/v1/sessions/{session}/items"),
        r#"{"data":[],"has_more":false}"#,
    );
    core.transport().ok(
        &format!("/v1/sessions/{session}/events"),
        r#"{"queued":true}"#,
    );
    let sent = block_on(core.send_first_message(&session, "first words")).unwrap();
    assert!(sent.submission.queued);
}

#[test]
fn a_create_answered_after_a_disconnect_is_uncertain() {
    let transport = stub();
    let gate = transport.gate("POST", "/v1/sessions");
    let core = connected(transport);
    let chosen = selection();
    let mut creating = std::pin::pin!(core.create_session(&chosen, ""));
    assert!(super::test_support::still_pending(creating.as_mut()));
    core.disconnect();
    gate.open();
    assert_eq!(
        block_on(creating).unwrap_err(),
        SessionError::Creation(CreationError::Uncertain)
    );
}

#[test]
fn agent_pages_that_cycle_stop_the_catalog() {
    let transport = stub();
    let page = |last: &str| {
        Reply::json(
            200,
            format!(
                r#"{{"data":[{{"id":"ag_codex","name":"n","harness":"codex-native"}}],"has_more":true,"last_id":"{last}"}}"#
            ),
        )
    };
    transport.enqueue(
        "GET",
        "/v1/agents",
        vec![page("ag_one"), page("ag_two"), page("ag_one")],
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.creation_catalog()).unwrap_err(),
        SessionError::InvalidPagination
    );
}
