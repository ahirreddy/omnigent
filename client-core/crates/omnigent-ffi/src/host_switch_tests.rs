//! Switching a session's host, resuming on a host, and the sign-in link, over the fake host.

use serde_json::json as value;

use crate::creation::CreationGit;
use crate::fork::RunnerLaunch;
use crate::host_switch::SessionSignInLink;
use crate::test_support::{Harness, connected, json};

const SESSION: &str = "/v1/sessions/conv_a";
const RUNNERS: &str = "/v1/hosts/host_b/runners";

fn switching() -> Harness {
    let harness = connected();
    let owned =
        r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"host_id":"host_a"}"#;
    harness.http.route_method("GET", SESSION, json(200, owned));
    harness
        .http
        .route_method("PATCH", SESSION, json(200, owned));
    harness.http.route(
        "/v1/hosts",
        json(
            200,
            r#"{"hosts":[{"host_id":"host_a","name":"Old","status":"offline"},
                         {"host_id":"host_b","name":"New","status":"online"}]}"#,
        ),
    );
    harness
        .http
        .route_method("POST", RUNNERS, json(201, r#"{"runner_id":"runner_new"}"#));
    harness
}

#[test]
fn a_switch_releases_the_runner_then_launches_on_the_named_host() {
    let mut harness = switching();
    let launch = harness
        .call(|core| async move {
            core.switch_session_host("conv_a".into(), "host_b".into(), " /work/app ".into())
                .await
        })
        .unwrap();
    assert_eq!(
        launch,
        RunnerLaunch::Launched {
            runner_id: "runner_new".into()
        }
    );
    assert_eq!(
        harness.last_request(),
        (
            format!("POST {RUNNERS}"),
            value!({"session_id": "conv_a", "workspace": "/work/app"})
        )
    );
    assert!(harness.http.lines().contains(&format!("PATCH {SESSION}")));

    let refused = harness.call(|core| async move {
        core.switch_session_host("conv_a".into(), "host_b".into(), "relative".into())
            .await
    });
    assert!(refused.is_err());
}

#[test]
fn resume_sends_the_git_block_and_drops_a_blank_base() {
    let mut harness = switching();
    let runner = harness
        .call(|core| async move {
            core.resume_session_on_host(
                "conv_a".into(),
                "host_b".into(),
                "/work/app".into(),
                Some(CreationGit {
                    branch_name: "fix/login".into(),
                    base_branch: Some("  ".into()),
                    existing_worktree: false,
                }),
            )
            .await
        })
        .unwrap();
    assert_eq!(runner, "runner_new");
    assert_eq!(
        harness.last_request(),
        (
            format!("POST {RUNNERS}"),
            value!({"session_id": "conv_a", "workspace": "/work/app",
                "git": {"branch_name": "fix/login"}})
        )
    );

    harness
        .call(|core| async move {
            core.resume_session_on_host(
                "conv_a".into(),
                "host_b".into(),
                "/work/app".into(),
                Some(CreationGit {
                    branch_name: "fix/login".into(),
                    base_branch: Some("main".into()),
                    existing_worktree: false,
                }),
            )
            .await
        })
        .unwrap();
    let (_, body) = harness.last_request();
    assert_eq!(body["git"]["branch_name"], "fix/login");
    assert_eq!(body["git"]["base_branch"], "main");

    harness
        .call(|core| async move {
            core.resume_session_on_host(
                "conv_a".into(),
                "host_b".into(),
                "/work/app".into(),
                Some(CreationGit {
                    branch_name: "fix/login".into(),
                    base_branch: None,
                    existing_worktree: true,
                }),
            )
            .await
        })
        .unwrap();
    let (_, body) = harness.last_request();
    assert_eq!(body["git"]["existing_worktree"], true, "{body}");

    let no_git = harness.call(|core| async move {
        core.resume_session_on_host("conv_a".into(), "host_b".into(), "rel".into(), None)
            .await
    });
    assert!(no_git.is_err());
}

#[test]
fn the_sign_in_link_reads_its_fields() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions/conv_a/sign-in-link",
        json(
            200,
            r#"{"pending":true,"url":"https://example.cloud/oidc?x=1","code":"ABCD-1234","terminal_id":"t"}"#,
        ),
    );
    let link = harness
        .call(|core| async move { core.session_sign_in_link("conv_a".into()).await })
        .unwrap();
    assert_eq!(
        link,
        SessionSignInLink {
            pending: true,
            url: Some("https://example.cloud/oidc?x=1".into()),
            code: Some("ABCD-1234".into()),
        }
    );
    harness.http.route(
        "/v1/sessions/conv_a/sign-in-link",
        json(503, r#"{"detail":"offline"}"#),
    );
    assert!(
        harness
            .call(|core| async move { core.session_sign_in_link("conv_a".into()).await })
            .is_err()
    );
}
