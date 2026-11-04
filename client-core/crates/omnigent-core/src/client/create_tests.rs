//! Session creation REST tests, ported from `NativeLab`'s `SessionCreationTests`.

use futures::executor::block_on;
use serde_json::json;

use super::create::FirstMessage;
use super::test_support::{
    Reply, RouteTransport, body_json, connected, envelopes, header, path_of, query_value,
};
use super::{ClientEvent, SessionError};
use crate::creation::{CreationError, CreationGit, CreationSelection};

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
fn a_sandbox_session_posts_the_managed_contract_without_a_host() {
    let core = connected(stub());
    let receipt = block_on(core.create_sandbox_session(
        "ag_codex",
        " Scratch ",
        &["https://github.com/example/repo#main".to_owned()],
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
        "the server mints the sandbox host: {body}"
    );
    assert!(body.get("workspace").is_none(), "{body}");

    let unknown = block_on(core.create_sandbox_session("ag_missing", "", &[]));
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
