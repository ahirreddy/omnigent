//! Fork REST tests: the truncated fork `POST`, its status policy, the start pre-flight and
//! runner launch, and the fork sheet's plan.

use futures::executor::block_on;
use serde_json::json;

use super::fork::{
    ForkRequest, ForkStart, RunnerLaunch, agent_root_name, fork_plan, fork_target_carries_history,
    fork_unavailable_reason,
};
use super::sessions::SessionSummary;
use super::test_support::{Reply, RouteTransport, body_json, connected, path_of, record};
use super::{ClientEvent, SessionError};
use crate::config::session::SessionConfiguration;
use crate::creation::{CreationAgent, CreationCatalog, CreationError, CreationHost};

const FORK: &str = "/v1/sessions/conv_src/fork";
const RUNNERS: &str = "/v1/hosts/host_a/runners";
const FORKED: &str = r#"{"id":"conv_fork","status":"idle","created_at":5,"title":"Fork of Plan","permission_level":4}"#;

fn request() -> ForkRequest {
    ForkRequest {
        source_id: "conv_src".into(),
        up_to_response_id: Some("resp_2".into()),
        ..ForkRequest::default()
    }
}

fn start() -> ForkStart {
    ForkStart {
        host_id: "host_a".into(),
        workspace: " /work/project ".into(),
    }
}

fn hosts(status: &str) -> String {
    json!({"hosts": [{"host_id": "host_a", "name": "Mac", "status": status}]}).to_string()
}

fn forking(reply: Reply) -> RouteTransport {
    let transport = RouteTransport::local();
    transport.respond(Some("POST"), FORK, None, reply);
    transport
}

fn posts(transport: &RouteTransport) -> Vec<String> {
    transport.writes().iter().map(path_of).collect()
}

#[test]
fn posts_a_truncated_fork_and_records_its_summary() {
    let core = connected(forking(Reply::json(201, FORKED)));
    let recorder = record(&core);
    let forked = block_on(core.fork_session(&ForkRequest {
        title: Some("  ".into()),
        ..request()
    }))
    .unwrap();
    assert_eq!(forked.receipt.session_id, "conv_fork");
    assert_eq!(
        forked.receipt.summary.map(|summary| summary.title),
        Some("Fork of Plan".to_owned())
    );
    assert_eq!(forked.launch, RunnerLaunch::NotRequested);
    let writes = core.transport().writes();
    assert_eq!(writes.len(), 1);
    assert_eq!(
        body_json(&writes[0]),
        json!({"up_to_response_id": "resp_2"})
    );
    let events = recorder.take();
    assert!(events.iter().any(|event| matches!(
        event,
        ClientEvent::SessionsChanged { sessions } if sessions[0].id == "conv_fork"
    )));
    assert!(events.contains(&ClientEvent::InventoryInvalidated));
}

#[test]
fn sends_a_switched_agent_and_trimmed_title() {
    let core = connected(forking(Reply::json(201, FORKED)));
    block_on(core.fork_session(&ForkRequest {
        agent_id: Some("ag_codex".into()),
        title: Some(" Try again ".into()),
        up_to_response_id: None,
        ..request()
    }))
    .unwrap();
    assert_eq!(
        body_json(&core.transport().writes()[0]),
        json!({"agent_id": "ag_codex", "title": "Try again"})
    );
}

#[test]
fn a_rejection_names_the_server_reason() {
    let core = connected(forking(Reply::json(
        400,
        r#"{"error":{"message":"up_to_response_id names no response"}}"#,
    )));
    assert_eq!(
        block_on(core.fork_session(&request())),
        Err(SessionError::Rejected {
            status: 400,
            message: "up_to_response_id names no response".into()
        })
    );
}

#[test]
fn unclear_outcomes_are_uncertain_and_never_retried() {
    for reply in [
        Reply::json(503, "{}"),
        Reply::json(201, r#"{"status":"idle"}"#),
        Reply::json(201, r#"{"id":"../info"}"#),
    ] {
        let core = connected(forking(reply));
        assert!(matches!(
            block_on(core.fork_session(&request())),
            Err(SessionError::DeliveryUncertain { .. })
        ));
        assert_eq!(posts(core.transport()), [FORK]);
    }
}

#[test]
fn invalid_input_sends_nothing() {
    let cases = [
        (
            ForkRequest {
                source_id: "../x".into(),
                ..request()
            },
            "InvalidIdentifier",
        ),
        (
            ForkRequest {
                up_to_response_id: Some("resp 2".into()),
                ..request()
            },
            "InvalidIdentifier",
        ),
        (
            ForkRequest {
                title: Some("x".repeat(121)),
                ..request()
            },
            "InvalidTitle",
        ),
        (
            ForkRequest {
                start: Some(ForkStart {
                    workspace: "work".into(),
                    ..start()
                }),
                ..request()
            },
            "Creation",
        ),
    ];
    for (input, kind) in cases {
        let core = connected(forking(Reply::json(201, FORKED)));
        let before = core.transport().taken().len();
        let error = block_on(core.fork_session(&input)).unwrap_err();
        let matched = match kind {
            "InvalidIdentifier" => matches!(error, SessionError::InvalidIdentifier { .. }),
            "InvalidTitle" => error == SessionError::InvalidTitle,
            _ => matches!(error, SessionError::Creation(CreationError::Unavailable(_))),
        };
        assert!(matched, "{kind}: {error:?}");
        assert_eq!(core.transport().taken().len(), before, "{kind}");
    }
}

#[test]
fn an_offline_host_blocks_the_fork_before_any_write() {
    let transport = forking(Reply::json(201, FORKED));
    transport.ok("/v1/hosts", hosts("offline"));
    let core = connected(transport);
    assert_eq!(
        block_on(core.fork_session(&ForkRequest {
            start: Some(start()),
            ..request()
        })),
        Err(SessionError::Creation(CreationError::Unavailable(
            "Connect this host before starting the copy.".into()
        )))
    );
    assert_eq!(posts(core.transport()), Vec::<String>::new());
}

#[test]
fn starts_the_fork_on_the_host() {
    let transport = forking(Reply::json(201, FORKED));
    transport.ok("/v1/hosts", hosts("online"));
    transport.respond(
        Some("POST"),
        RUNNERS,
        None,
        Reply::json(200, r#"{"runner_id":"runner_1","status":"launching"}"#),
    );
    let core = connected(transport);
    let forked = block_on(core.fork_session(&ForkRequest {
        start: Some(start()),
        ..request()
    }))
    .unwrap();
    assert_eq!(
        forked.launch,
        RunnerLaunch::Launched {
            runner_id: "runner_1".into()
        }
    );
    let writes = core.transport().writes();
    assert_eq!(posts(core.transport()), [FORK, RUNNERS]);
    assert_eq!(
        body_json(&writes[1]),
        json!({"session_id": "conv_fork", "workspace": "/work/project"})
    );
}

#[test]
fn a_failed_launch_still_returns_the_fork() {
    let transport = forking(Reply::json(201, FORKED));
    transport.ok("/v1/hosts", hosts("online"));
    transport.respond(
        Some("POST"),
        RUNNERS,
        None,
        Reply::json(409, r#"{"detail":"Host is offline"}"#),
    );
    let core = connected(transport);
    let forked = block_on(core.fork_session(&ForkRequest {
        start: Some(start()),
        ..request()
    }))
    .unwrap();
    assert_eq!(forked.receipt.session_id, "conv_fork");
    assert_eq!(
        forked.launch,
        RunnerLaunch::Failed(SessionError::Rejected {
            status: 409,
            message: "Host is offline".into()
        })
    );
    assert_eq!(posts(core.transport()), [FORK, RUNNERS]);
}

#[test]
fn root_names_peel_every_clone_suffix() {
    assert_eq!(
        agent_root_name("claude-native-ui (fork ag_a) (switch ag_b)"),
        "claude-native-ui"
    );
    assert_eq!(agent_root_name("Reviewer (beta)"), "Reviewer (beta)");
    assert_eq!(agent_root_name("Plain"), "Plain");
    assert_eq!(agent_root_name("x (fork )"), "x (fork )");
}

#[test]
fn only_history_carrying_harnesses_are_targets() {
    for harness in [
        "claude-native",
        "native-codex",
        "cursor-native",
        "claude_sdk",
        "openai-agents",
    ] {
        assert!(fork_target_carries_history(Some(harness)), "{harness}");
    }
    for harness in [None, Some(""), Some("goose-native"), Some("kiro-native")] {
        assert!(!fork_target_carries_history(harness), "{harness:?}");
    }
}

fn source() -> SessionSummary {
    SessionSummary {
        workspace: "/work/project".into(),
        agent_name: "codex-native-ui (fork ag_1)".into(),
        is_read_only: false,
        configuration: Some(SessionConfiguration {
            agent_id: Some("ag_clone".into()),
            harness: Some("codex-native".into()),
            host_id: Some("host_a".into()),
            ..SessionConfiguration::default()
        }),
        ..SessionSummary::new("conv_src", "Plan", "")
    }
}

fn agent(id: &str, name: &str, harness: Option<&str>) -> CreationAgent {
    CreationAgent {
        id: id.into(),
        name: name.into(),
        harness: harness.map(str::to_owned),
        description: None,
        ..CreationAgent::default()
    }
}

fn catalog(status: &str, sandbox: Option<&str>) -> CreationCatalog {
    CreationCatalog {
        hosts: vec![CreationHost {
            host_id: "host_a".into(),
            name: "Mac".into(),
            status: status.into(),
            sandbox_provider: sandbox.map(str::to_owned),
            configured_harnesses: None,
        }],
        agents: vec![
            agent("ag_codex", "codex-native-ui", Some("codex-native")),
            agent("ag_claude", "claude-native-ui", Some("claude-native")),
            agent("ag_goose", "goose", Some("goose-native")),
        ],
        ..CreationCatalog::default()
    }
}

#[test]
fn the_plan_offers_the_source_first_then_switch_targets() {
    let plan = fork_plan(&source(), Some(&catalog("online", None)));
    let ids: Vec<_> = plan.agents.iter().map(|agent| agent.id.as_str()).collect();
    assert_eq!(ids, ["ag_clone", "ag_claude"]);
    assert_eq!(plan.agents[0].name, "codex-native-ui (same as original)");
    assert_eq!(plan.agent_id, "ag_clone");
    assert_eq!(plan.directory, "/work/project");
    assert_eq!(plan.host_id.as_deref(), Some("host_a"));
    assert_eq!(plan.start_unavailable_reason, None);
}

#[test]
fn the_plan_says_why_a_start_is_unavailable() {
    let no_host = SessionSummary {
        workspace: "Local server".into(),
        configuration: Some(SessionConfiguration {
            agent_id: Some("ag_clone".into()),
            ..SessionConfiguration::default()
        }),
        ..source()
    };
    let unbound = fork_plan(&no_host, Some(&catalog("online", None)));
    assert_eq!(unbound.directory, "");
    let cases = [
        (unbound.start_unavailable_reason, "no host to start"),
        (
            fork_plan(&source(), None).start_unavailable_reason,
            "not loaded",
        ),
        (
            fork_plan(&source(), Some(&catalog("offline", None))).start_unavailable_reason,
            "Connect this host",
        ),
        (
            fork_plan(&source(), Some(&catalog("online", Some("arclet")))).start_unavailable_reason,
            "managed sandbox",
        ),
    ];
    for (reason, expected) in cases {
        assert!(
            reason
                .as_deref()
                .is_some_and(|text| text.contains(expected)),
            "{reason:?} should mention {expected:?}"
        );
    }
}

#[test]
fn read_only_and_unbound_sessions_cannot_fork() {
    assert_eq!(fork_unavailable_reason(&source()), None);
    let read_only = SessionSummary {
        is_read_only: true,
        ..source()
    };
    assert!(fork_unavailable_reason(&read_only).is_some());
    let no_agent = SessionSummary {
        configuration: None,
        ..source()
    };
    assert!(fork_unavailable_reason(&no_agent).is_some());
}
