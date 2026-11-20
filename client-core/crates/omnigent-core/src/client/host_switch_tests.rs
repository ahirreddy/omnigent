//! Switch host, resume on a host, and the live sign-in link: the requests each sends, the
//! checks made before any write, what the server's refusal reads as, and the stranded outcome
//! of a half-finished switch.

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::fork::RunnerLaunch;
use super::super::test_support::{
    Reply, RouteTransport, body_json, cache_row, connected, lines_after_connect, path_of,
};
use super::{SandboxMove, SandboxMoveTarget, SignInLink};
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
        lines_after_connect(&core),
        [
            "GET /v1/hosts",
            "PATCH /v1/sessions/conv_a",
            "POST /v1/hosts/host_b/runners"
        ]
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

    let core = connected(switching(Reply::json(201, r#"{"runner_id":"r"}"#)));
    cache_row(
        &core,
        r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":2}"#,
    );
    assert_eq!(
        block_on(core.switch_session_host("conv_a", "host_b", "/work/app")),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(
        block_on(core.resume_session_on_host("conv_a", "host_b", "/work/app", None)),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(lines_after_connect(&core), Vec::<String>::new());
}

#[test]
fn an_owners_cached_row_lets_the_switch_through() {
    let core = connected(switching(Reply::json(201, r#"{"runner_id":"runner_new"}"#)));
    cache_row(&core, OWNED);
    block_on(core.switch_session_host("conv_a", "host_b", "/work/app")).unwrap();
    assert_eq!(
        writes(core.transport()),
        ["PATCH /v1/sessions/conv_a", "POST /v1/hosts/host_b/runners"]
    );
}

#[test]
fn a_refused_release_reads_as_the_removed_owner_check_did_and_launches_nothing() {
    for (status, expected) in [
        (403, SessionError::ReadOnly),
        (
            404,
            SessionError::SessionNotFound {
                session_id: "conv_a".into(),
            },
        ),
    ] {
        let transport = switching(Reply::json(201, r#"{"runner_id":"r"}"#));
        transport.respond(Some("PATCH"), SESSION, None, Reply::json(status, "{}"));
        let core = connected(transport);
        assert_eq!(
            block_on(core.switch_session_host("conv_a", "host_b", "/work/app")),
            Err(expected),
            "{status}"
        );
        assert_eq!(
            lines_after_connect(&core),
            ["GET /v1/hosts", "PATCH /v1/sessions/conv_a"],
            "{status}"
        );
    }
}

#[test]
fn a_resume_the_server_cannot_find_the_session_for_is_a_missing_session() {
    let core = connected(switching(Reply::json(
        404,
        r#"{"error":{"message":"session not found"}}"#,
    )));
    assert_eq!(
        block_on(core.resume_session_on_host("conv_a", "host_b", "/work/app", None)),
        Err(SessionError::SessionNotFound {
            session_id: "conv_a".into()
        })
    );
    // A host the caller does not own is not a missing session.
    let core = connected(switching(Reply::json(403, "{}")));
    assert_eq!(
        block_on(core.resume_session_on_host("conv_a", "host_b", "/work/app", None)),
        Err(SessionError::Forbidden)
    );
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
    assert_eq!(
        lines_after_connect(&core),
        ["GET /v1/hosts", "POST /v1/hosts/host_b/runners"]
    );
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

const MOVE: &str = "/v1/sessions/conv_a/managed-host";
const HOST_ID: &str = "0123456789abcdef0123456789abcdef";

fn sandbox_info(mints: bool) -> String {
    json!({
        "single_user": true,
        "accounts_enabled": false,
        "managed_sandboxes_enabled": true,
        "move_to_managed_sandbox": true,
        "request_managed_sandbox_host_id": mints,
        "sandbox_provider": "modal",
        "sandbox_providers": ["modal", "docker"],
        "sandbox_provider_capabilities": {
            "modal": {"accepts_session_move": true},
            "docker": {"accepts_session_move": false},
        },
    })
    .to_string()
}

fn moving(mints: bool, answer: Reply) -> RouteTransport {
    let transport = RouteTransport::local();
    transport.ok("/v1/info", sandbox_info(mints));
    transport.respond(Some("PATCH"), SESSION, None, Reply::json(200, OWNED));
    transport.respond(Some("POST"), MOVE, None, answer);
    transport
}

fn target(provider: &str, repository: &str, branch: &str) -> SandboxMoveTarget {
    SandboxMoveTarget {
        provider: Some(provider.into()),
        repository: repository.into(),
        branch: branch.into(),
        host_id: Some(HOST_ID.into()),
    }
}

#[test]
fn a_sandbox_move_releases_the_runner_then_asks_for_the_sandbox() {
    let core = connected(moving(true, Reply::json(202, OWNED)));
    let moved = block_on(core.move_session_to_sandbox(
        "conv_a",
        &target("modal", " https://github.com/org/repo ", " main "),
    ))
    .unwrap();
    assert!(matches!(moved, SandboxMove::Started));
    assert_eq!(
        writes(core.transport()),
        [
            "PATCH /v1/sessions/conv_a",
            "POST /v1/sessions/conv_a/managed-host"
        ]
    );
    assert_eq!(
        core.transport().write_bodies(),
        vec![
            json!({"runner_id": "", "model_override": "default", "silent": true}),
            json!({
                "sandbox_provider": "modal",
                "workspace": "https://github.com/org/repo#main",
                "host_id": HOST_ID,
            }),
        ]
    );
}

#[test]
fn an_empty_sandbox_sends_no_workspace_and_a_server_that_mints_no_ids_gets_none() {
    let core = connected(moving(false, Reply::json(202, OWNED)));
    block_on(core.move_session_to_sandbox("conv_a", &target("modal", "", ""))).unwrap();
    assert_eq!(
        core.transport().write_bodies().last(),
        Some(&json!({"sandbox_provider": "modal"}))
    );
}

#[test]
fn a_sandbox_request_failing_after_the_release_is_unconfirmed() {
    let core = connected(moving(
        true,
        Reply::json(409, r#"{"error":{"message":"host is already in use"}}"#),
    ));
    let moved = block_on(core.move_session_to_sandbox("conv_a", &target("modal", "", ""))).unwrap();
    assert!(matches!(moved, SandboxMove::Unconfirmed(_)));
}

#[test]
fn bad_repositories_and_providers_that_refuse_moves_write_nothing() {
    let core = connected(moving(true, Reply::json(202, OWNED)));
    let cases = [
        (target("modal", "", "main"), "Add the repository"),
        (
            target("modal", "github.com/org/repo", ""),
            "repository URL like",
        ),
        (
            target("modal", "https://github.com/org/repo", "bad..name"),
            "valid branch name",
        ),
        (target("docker", "", ""), "can't move a session"),
    ];
    for (target, wanted) in cases {
        let refused = block_on(core.move_session_to_sandbox("conv_a", &target));
        assert!(
            matches!(&refused, Err(SessionError::Creation(CreationError::Unavailable(reason)))
                if reason.contains(wanted)),
            "{wanted}: {refused:?}"
        );
    }
    assert_eq!(writes(core.transport()), Vec::<String>::new());
}
