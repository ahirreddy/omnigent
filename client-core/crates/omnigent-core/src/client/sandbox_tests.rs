//! Sandbox reads against a fake server: profiles, GitHub listings and a sandbox fork's
//! repositories on their current branches.

use futures::executor::block_on;

use super::super::SessionError;
use super::super::test_support::{Reply, RouteTransport, connected, path_of, query_value};
use crate::sandbox::SandboxRepo;

#[test]
fn profiles_are_read_for_one_provider_with_search() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sandbox-profiles",
        r#"{"profiles":[{"id":"p1","name":"GPU","description":"","provider":"modal",
            "revision":"r1"}],"managed_providers":["modal"],"next_cursor":null}"#,
    );
    let core = connected(transport);
    let page = block_on(core.sandbox_profiles("modal", "  gp ", Some("p1"))).unwrap();
    assert_eq!(page.profiles[0].id, "p1");
    assert!(page.requires_profile("modal") && !page.has_more);
    let request = core.transport().taken().pop().unwrap();
    assert_eq!(path_of(&request), "/v1/sandbox-profiles");
    assert_eq!(query_value(&request, "provider").as_deref(), Some("modal"));
    assert_eq!(query_value(&request, "search").as_deref(), Some("gp"));
    assert_eq!(query_value(&request, "profile_id").as_deref(), Some("p1"));
    assert_eq!(query_value(&request, "limit").as_deref(), Some("20"));
}

#[test]
fn github_branches_need_an_owner_and_name() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/connections/github/repos/org/app/branches",
        r#"{"connected":true,"branches":["main","dev"]}"#,
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.github_branches("org/app")).unwrap(),
        ["main", "dev"]
    );
    for bad in ["org", "org/../x", "../org/app", "org/a/b"] {
        assert!(
            matches!(
                block_on(core.github_branches(bad)),
                Err(SessionError::InvalidIdentifier { .. })
            ),
            "{bad}"
        );
    }
}

fn source(transport: &RouteTransport, repos: &str) {
    transport.ok(
        "/v1/sessions/conv_src",
        format!(
            r#"{{"id":"conv_src","status":"idle","created_at":1,"permission_level":4,
                "labels":{{"omnigent.sandbox.repo":"{repos}"}},
                "sandbox_profile":{{"id":"p1","name":"GPU","provider":"modal","revision":"r1"}}}}"#
        ),
    );
}

#[test]
fn a_sandbox_fork_starts_on_the_sources_pushed_branches() {
    let transport = RouteTransport::local();
    source(
        &transport,
        "https://github.com/o/a#main https://github.com/o/b",
    );
    transport.ok(
        "/v1/info",
        r#"{"single_user":true,"accounts_enabled":false,"session_fork_workspaces":true}"#,
    );
    transport.ok(
        "/v1/sessions/conv_src/resources/repository-branches",
        r#"{"repositories":[{"url":"https://github.com/o/a","branch":"feat","pushed":true},
            {"url":"https://github.com/o/b","branch":"wip","pushed":false}]}"#,
    );
    let core = connected(transport);
    let defaults = block_on(core.fork_sandbox_defaults("conv_src")).unwrap();
    assert_eq!(
        defaults.repos.repos,
        [
            SandboxRepo {
                url: "https://github.com/o/a".into(),
                branch: "feat".into()
            },
            SandboxRepo {
                url: "https://github.com/o/b".into(),
                branch: String::new()
            }
        ]
    );
    assert_eq!(defaults.repos.notes.len(), 1);
    assert_eq!(defaults.profile.unwrap().revision, "r1");
    assert_eq!(defaults.branch_check_error, None);
}

#[test]
fn a_failed_branch_check_keeps_the_original_branches_and_says_why() {
    let transport = RouteTransport::local();
    source(&transport, "https://github.com/o/a#main");
    transport.enqueue(
        "GET",
        "/v1/sessions/conv_src/resources/repository-branches",
        vec![Reply::json(404, r#"{"detail":"no"}"#)],
    );
    let core = connected(transport);
    let defaults = block_on(core.fork_sandbox_defaults("conv_src")).unwrap();
    assert_eq!(defaults.repos.repos[0].branch, "main");
    assert!(defaults.branch_check_error.is_some());
}

#[test]
fn several_repositories_are_not_checked_on_servers_that_cannot_change_them() {
    let transport = RouteTransport::local();
    source(&transport, "https://github.com/o/a https://github.com/o/b");
    transport.ok(
        "/v1/info",
        r#"{"single_user":true,"accounts_enabled":false,"session_fork_workspaces":false}"#,
    );
    let core = connected(transport);
    let defaults = block_on(core.fork_sandbox_defaults("conv_src")).unwrap();
    assert_eq!(defaults.repos.repos.len(), 2);
    assert!(
        core.transport()
            .taken()
            .iter()
            .all(|request| !path_of(request).ends_with("repository-branches"))
    );
}
