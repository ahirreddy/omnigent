//! Fork requests, plans and launches over the fake host.

use omnigent_core::config::session::SessionConfiguration as CoreConfiguration;
use omnigent_core::fork as core;
use omnigent_core::sessions::SessionSummary as CoreSummary;
use serde_json::json as value;

use crate::creation::{AgentPickerSection, CreationAgent, CreationCatalog, CreationHost};
use crate::fork::{
    ForkPlan, ForkRequest, ForkSandbox, ForkStart, ForkedSession, RunnerLaunch, fork_plan,
};
use crate::sandbox::SandboxProfile;
use crate::sessions::SessionSummary;
use crate::test_support::{Harness, connected, json};

const FORK: &str = "/v1/sessions/conv_src/fork";
const FORKED: &str = r#"{"id":"conv_fork","status":"idle","created_at":5,"title":"Fork of Plan","permission_level":4}"#;

fn agent(id: &str, harness: &str) -> CreationAgent {
    CreationAgent {
        id: id.to_owned(),
        name: format!("{id} name"),
        harness: Some(harness.to_owned()),
        description: None,
        harness_id: harness.to_owned(),
        harness_label: harness.to_owned(),
        supports_creation: true,
        supports_model_preview: false,
        builtin: None,
        mine: false,
        changed_at: None,
        picker_section: AgentPickerSection::Harness,
        is_primary_harness: true,
        picker_rank: 0,
    }
}

fn request() -> ForkRequest {
    ForkRequest {
        source_id: "conv_src".into(),
        up_to_response_id: None,
        agent_id: None,
        title: None,
        start: None,
        sandbox: None,
        model: None,
        reasoning_effort: None,
        approval_mode: None,
        agent: None,
    }
}

fn forking() -> Harness {
    let harness = connected();
    harness.http.route_method("POST", FORK, json(201, FORKED));
    harness
}

#[test]
fn a_request_carries_each_field_to_the_core() {
    let on_core = core::ForkRequest::from(ForkRequest {
        up_to_response_id: Some("resp_2".into()),
        agent_id: Some("ag".into()),
        title: Some("Title".into()),
        start: Some(ForkStart {
            host_id: "host_a".into(),
            workspace: "/work".into(),
            branch: Some("  ".into()),
        }),
        sandbox: Some(ForkSandbox {
            provider: Some("modal".into()),
            workspaces: Some(vec!["https://x/r#main".into()]),
            profile: Some(SandboxProfile {
                id: "prof".into(),
                name: "n".into(),
                description: String::new(),
                provider: "modal".into(),
                revision: "rev".into(),
            }),
        }),
        model: Some("m".into()),
        reasoning_effort: Some("high".into()),
        approval_mode: Some("plan".into()),
        agent: Some(agent("ag", "claude-native")),
        ..request()
    });
    assert_eq!(on_core.source_id, "conv_src");
    assert_eq!(on_core.up_to_response_id.as_deref(), Some("resp_2"));
    assert_eq!(on_core.agent_id.as_deref(), Some("ag"));
    assert_eq!(on_core.title.as_deref(), Some("Title"));
    assert_eq!(on_core.model.as_deref(), Some("m"));
    assert_eq!(on_core.reasoning_effort.as_deref(), Some("high"));
    assert!(!on_core.codex_bypass);
    assert_eq!(
        on_core.terminal_launch_args,
        Some(vec!["--permission-mode".to_owned(), "plan".to_owned()])
    );
    let start = on_core.start.unwrap();
    assert_eq!(
        (
            start.host_id.as_str(),
            start.workspace.as_str(),
            start.branch
        ),
        ("host_a", "/work", None),
    );
    let sandbox = on_core.sandbox.unwrap();
    assert_eq!(sandbox.provider.as_deref(), Some("modal"));
    assert_eq!(
        sandbox.workspaces,
        Some(vec!["https://x/r#main".to_owned()])
    );
    assert_eq!(sandbox.profile, Some(("prof".to_owned(), "rev".to_owned())));
    assert_eq!(sandbox.host_id, None);

    let bypass = core::ForkRequest::from(ForkRequest {
        approval_mode: Some("bypass".into()),
        agent: Some(agent("ag", "codex-native")),
        start: Some(ForkStart {
            host_id: "h".into(),
            workspace: "/w".into(),
            branch: Some("topic".into()),
        }),
        ..request()
    });
    assert!(bypass.codex_bypass);
    assert_eq!(bypass.start.unwrap().branch.as_deref(), Some("topic"));
    assert_eq!(
        core::ForkRequest::from(request()).terminal_launch_args,
        None
    );
}

#[test]
fn every_launch_outcome_maps() {
    assert_eq!(
        RunnerLaunch::from(core::RunnerLaunch::NotRequested),
        RunnerLaunch::NotRequested
    );
    assert_eq!(
        RunnerLaunch::from(core::RunnerLaunch::Launched {
            runner_id: "r".into()
        }),
        RunnerLaunch::Launched {
            runner_id: "r".into()
        }
    );
    let forked = ForkedSession::from(core::ForkedSession {
        receipt: omnigent_core::creation::CreationReceipt {
            session_id: "conv_fork".into(),
            summary: None,
        },
        launch: core::RunnerLaunch::NotRequested,
    });
    assert_eq!(forked.receipt.session_id, "conv_fork");
    assert_eq!(forked.launch, RunnerLaunch::NotRequested);
}

#[test]
fn the_plan_reads_the_catalogs_hosts_and_sandbox_offer() {
    let source = SessionSummary::from(CoreSummary {
        workspace: "/work/project".into(),
        agent_name: "codex-native-ui".into(),
        configuration: Some(CoreConfiguration {
            agent_id: Some("ag_clone".into()),
            harness: Some("codex-native".into()),
            host_id: Some("host_a".into()),
            ..CoreConfiguration::default()
        }),
        ..CoreSummary::new("conv_src", "Plan", "")
    });
    let host = |id: &str, status: &str| CreationHost {
        host_id: id.to_owned(),
        name: format!("{id} name"),
        status: status.to_owned(),
        sandbox_provider: None,
        configured_harnesses: None,
        is_available: status == "online",
    };
    let catalog = CreationCatalog {
        hosts: vec![host("host_b", "offline"), host("host_a", "online")],
        agents: vec![agent("ag_claude", "claude-native")],
        managed_sandboxes: true,
        sandbox_providers: vec!["modal".into()],
        fork_workspaces: true,
        ..CreationCatalog::from(omnigent_core::creation::CreationCatalog::default())
    };
    let plan: ForkPlan = fork_plan(source, Some(catalog));
    assert_eq!(plan.agent_id, "ag_clone");
    assert_eq!(plan.directory, "/work/project");
    assert_eq!(plan.host_id.as_deref(), Some("host_a"));
    assert_eq!(plan.start_unavailable_reason, None);
    assert_eq!(plan.hosts[0].host_id, "host_a");
    assert_eq!(plan.hosts[0].name, "host_a name");
    assert_eq!(plan.hosts[0].unavailable_reason, None);
    assert_eq!(plan.hosts[1].host_id, "host_b");
    assert!(plan.hosts[1].unavailable_reason.is_some());
    assert!(plan.offers_sandbox);
    assert_eq!(plan.agents[1].id, "ag_claude");
}

#[test]
fn forking_posts_the_request_and_reports_the_receipt() {
    let mut harness = forking();
    let forked = harness
        .call(|core| async move {
            core.fork_session(ForkRequest {
                up_to_response_id: Some("resp_2".into()),
                title: Some(" Try ".into()),
                model: Some("m1".into()),
                reasoning_effort: Some("low".into()),
                ..request()
            })
            .await
        })
        .unwrap();
    assert_eq!(forked.receipt.session_id, "conv_fork");
    assert_eq!(forked.launch, RunnerLaunch::NotRequested);
    let (line, body) = harness.last_request();
    assert_eq!(line, format!("POST {FORK}"));
    assert_eq!(body["up_to_response_id"], "resp_2");
    assert_eq!(body["title"], "Try");

    harness.http.route_method(
        "POST",
        FORK,
        json(400, r#"{"error":{"message":"no such response"}}"#),
    );
    let refused = harness.call(|core| async move { core.fork_session(request()).await });
    assert!(
        format!("{refused:?}").contains("no such response"),
        "{refused:?}"
    );
}

#[test]
fn a_failed_start_keeps_the_fork_and_names_the_failure() {
    let mut harness = forking();
    harness.http.route(
        "/v1/hosts",
        json(
            200,
            r#"{"hosts":[{"host_id":"host_a","name":"Mac","status":"online"}]}"#,
        ),
    );
    harness.http.route_method(
        "POST",
        "/v1/hosts/host_a/runners",
        json(400, r#"{"error":{"message":"outside the sandbox"}}"#),
    );
    let start = || ForkStart {
        host_id: "host_a".into(),
        workspace: "/work/project".into(),
        branch: None,
    };
    let forked = harness
        .call(|core| async move {
            core.fork_session(ForkRequest {
                start: Some(start()),
                ..request()
            })
            .await
        })
        .unwrap();
    assert_eq!(forked.receipt.session_id, "conv_fork");
    assert!(
        matches!(&forked.launch, RunnerLaunch::Failed { error } if format!("{error:?}").contains("outside the sandbox")),
        "{:?}",
        forked.launch
    );

    harness.http.route_method(
        "POST",
        "/v1/hosts/host_a/runners",
        json(201, r#"{"runner_id":"runner_1"}"#),
    );
    let launched = harness
        .call(|core| async move {
            core.fork_session(ForkRequest {
                start: Some(start()),
                ..request()
            })
            .await
        })
        .unwrap();
    assert_eq!(
        launched.launch,
        RunnerLaunch::Launched {
            runner_id: "runner_1".into()
        }
    );
}

#[test]
fn a_sandbox_fork_names_a_host_only_for_a_server_that_asks() {
    let sandboxed = || ForkRequest {
        sandbox: Some(ForkSandbox {
            provider: Some("modal".into()),
            workspaces: None,
            profile: None,
        }),
        ..request()
    };
    let mut harness = forking();
    harness
        .call(|core| async move { core.fork_session(sandboxed()).await })
        .unwrap();
    let (_, body) = harness.last_request();
    assert_eq!(body["host_type"], "managed");
    assert_eq!(body["sandbox_provider"], "modal");
    assert_eq!(body.get("host_id"), None);

    let mut asks = forking();
    asks.http.route(
        "/v1/info",
        json(
            200,
            r#"{"single_user":true,"accounts_enabled":false,"managed_sandboxes_enabled":true,
                "request_managed_sandbox_host_id":true}"#,
        ),
    );
    asks.call(|core| async move { core.fork_session(sandboxed()).await })
        .unwrap();
    let (_, body) = asks.last_request();
    assert_eq!(body["host_id"], value!("000102030405060708090a0b0c0d0e0f"));
}
