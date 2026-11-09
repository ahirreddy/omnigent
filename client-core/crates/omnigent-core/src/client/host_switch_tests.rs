//! Switch host, resume on a host, and the live sign-in link: the requests each sends, the
//! checks made before any write, and the stranded outcome of a half-finished switch.

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::fork::RunnerLaunch;
use super::super::test_support::{Reply, RouteTransport, body_json, connected, path_of};
use super::SignInLink;
use crate::creation::{CreationError, CreationGit};

const SESSION: &str = "/v1/sessions/conv_a";
const RUNNERS: &str = "/v1/hosts/host_b/runners";
const OWNED: &str =
    r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"host_id":"host_a"}"#;

fn hosts(status: &str) -> String {
    json!({"hosts": [
        {"host_id": "host_a", "name": "Old", "status": "offline"},
        {"host_id": "host_b", "name": "New", "status": status},
    ]})
    .to_string()
}

fn switching(launch: Reply) -> RouteTransport {
    let transport = RouteTransport::local();
    transport.respond(Some("GET"), SESSION, None, Reply::json(200, OWNED));
    transport.respond(Some("PATCH"), SESSION, None, Reply::json(200, OWNED));
    transport.ok("/v1/hosts", hosts("online"));
    transport.respond(Some("POST"), RUNNERS, None, launch);
    transport
}

fn writes(transport: &RouteTransport) -> Vec<String> {
    transport
        .writes()
        .iter()
        .map(|request| format!("{} {}", request.method, path_of(request)))
        .collect()
}

#[test]
fn switch_releases_the_runner_and_model_then_launches_on_the_new_host() {
    let core = connected(switching(Reply::json(201, r#"{"runner_id":"runner_new"}"#)));
    let launch = block_on(core.switch_session_host("conv_a", "host_b", " /work/app ")).unwrap();
    assert_eq!(
        launch,
        RunnerLaunch::Launched {
            runner_id: "runner_new".into()
        }
    );
    assert_eq!(
        writes(core.transport()),
        ["PATCH /v1/sessions/conv_a", "POST /v1/hosts/host_b/runners"]
    );
    assert_eq!(
        core.transport().write_bodies(),
        vec![
            json!({"runner_id": "", "model_override": "default", "silent": true}),
            json!({"session_id": "conv_a", "workspace": "/work/app"}),
        ]
    );
}

#[test]
fn a_launch_failing_after_the_release_is_a_stranded_switch_not_an_error() {
    let core = connected(switching(Reply::json(
        400,
        r#"{"error":{"message":"workspace outside the sandbox"}}"#,
    )));
    let launch = block_on(core.switch_session_host("conv_a", "host_b", "/work/app")).unwrap();
    assert!(matches!(
        launch,
        RunnerLaunch::Failed(SessionError::Rejected { status: 400, .. })
    ));
}

#[test]
fn switch_checks_the_path_owner_and_host_before_any_write() {
    let core = connected(switching(Reply::json(201, r#"{"runner_id":"r"}"#)));
    assert!(matches!(
        block_on(core.switch_session_host("conv_a", "host_b", "work/app")),
        Err(SessionError::Creation(CreationError::Unavailable(_)))
    ));

    let offline = switching(Reply::json(201, r#"{"runner_id":"r"}"#));
    offline.ok("/v1/hosts", hosts("offline"));
    let core = connected(offline);
    assert!(matches!(
        block_on(core.switch_session_host("conv_a", "host_b", "/work/app")),
        Err(SessionError::Creation(CreationError::Unavailable(reason))) if reason.contains("offline")
    ));
    assert!(matches!(
        block_on(core.switch_session_host("conv_a", "host_gone", "/work/app")),
        Err(SessionError::Creation(CreationError::Unavailable(_)))
    ));

    let shared = switching(Reply::json(201, r#"{"runner_id":"r"}"#));
    shared.respond(
        Some("GET"),
        SESSION,
        None,
        Reply::json(
            200,
            r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":2}"#,
        ),
    );
    let core = connected(shared);
    assert_eq!(
        block_on(core.switch_session_host("conv_a", "host_b", "/work/app")),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(core.transport().writes().len(), 0);
}

#[test]
fn resume_launches_in_a_new_worktree_without_releasing_anything() {
    let core = connected(switching(Reply::json(201, r#"{"runner_id":"runner_new"}"#)));
    let git = CreationGit {
        branch_name: "fix/login".into(),
        base_branch: Some("main".into()),
        existing_worktree: false,
    };
    let runner =
        block_on(core.resume_session_on_host("conv_a", "host_b", "/work/app", Some(&git))).unwrap();
    assert_eq!(runner, "runner_new");
    assert_eq!(writes(core.transport()), ["POST /v1/hosts/host_b/runners"]);
    assert_eq!(
        body_json(&core.transport().writes()[0]),
        json!({"session_id": "conv_a", "workspace": "/work/app",
            "git": {"branch_name": "fix/login", "base_branch": "main"}})
    );

    let bad_branch = CreationGit {
        branch_name: "no spaces".into(),
        ..git
    };
    assert!(matches!(
        block_on(core.resume_session_on_host("conv_a", "host_b", "/work/app", Some(&bad_branch))),
        Err(SessionError::Creation(CreationError::Unavailable(_)))
    ));
}

#[test]
fn sign_in_link_reads_the_pending_prompt_and_drops_non_web_links() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sessions/conv_a/sign-in-link",
        r#"{"pending":true,"url":"https://example.cloud/oidc?x=1","code":"ABCD-1234","terminal_id":"t"}"#,
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.session_sign_in_link("conv_a")).unwrap(),
        SignInLink {
            pending: true,
            url: Some("https://example.cloud/oidc?x=1".into()),
            code: Some("ABCD-1234".into()),
        }
    );

    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sessions/conv_a/sign-in-link",
        r#"{"pending":true,"url":"file:///etc/passwd","code":null}"#,
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.session_sign_in_link("conv_a")).unwrap(),
        SignInLink::default()
    );

    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sessions/conv_a/sign-in-link",
        r#"{"pending":false,"url":null,"code":null}"#,
    );
    let core = connected(transport);
    assert!(
        !block_on(core.session_sign_in_link("conv_a"))
            .unwrap()
            .pending
    );
}

#[test]
fn an_unreadable_sign_in_link_is_malformed() {
    let transport = RouteTransport::local();
    transport.ok("/v1/sessions/conv_a/sign-in-link", "[]");
    let core = connected(transport);
    assert!(matches!(
        block_on(core.session_sign_in_link("conv_a")),
        Err(SessionError::MalformedResponse { detail })
            if detail.starts_with("/v1/sessions/conv_a/sign-in-link: ")
    ));
}

#[test]
fn a_session_cannot_move_onto_a_managed_sandbox() {
    let transport = switching(Reply::json(200, "{}"));
    transport.ok(
        "/v1/hosts",
        r#"{"hosts":[{"host_id":"host_b","name":"Box","status":"online","sandbox_provider":"modal"}]}"#,
    );
    let core = connected(transport);
    assert!(matches!(
        block_on(core.switch_session_host("conv_a", "host_b", "/work/app")),
        Err(SessionError::Creation(CreationError::Unavailable(reason)))
            if reason.contains("managed sandbox")
    ));
    assert_eq!(writes(core.transport()).len(), 0);
}
