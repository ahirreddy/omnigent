//! Sandbox rules and reads over the fake host: conversions and each export's request.

use omnigent_core::sandbox as core;

use crate::creation::CreationCatalog;
use crate::sandbox::{
    GithubRepo, SandboxProfile, SandboxProfilePage, SandboxRepo, SandboxRepoNote,
    compose_sandbox_workspaces, is_same_sandbox_repo, sandbox_branch_problem,
    sandbox_profile_problem, sandbox_provider_options, sandbox_repo_name, sandbox_repos_problem,
    sandbox_url_problem,
};
use crate::test_support::{connected, json as reply};

fn repo(url: &str, branch: &str) -> SandboxRepo {
    SandboxRepo {
        url: url.into(),
        branch: branch.into(),
    }
}

fn profile() -> SandboxProfile {
    SandboxProfile {
        id: "p1".into(),
        name: "GPU".into(),
        description: "Fast".into(),
        provider: "modal".into(),
        revision: "r1".into(),
    }
}

fn catalog() -> CreationCatalog {
    CreationCatalog {
        hosts: vec![],
        agents: vec![],
        agent_install: false,
        managed_sandboxes: true,
        sandbox_providers: vec!["modal".into(), "e2b".into()],
        codex_plan_at_launch: false,
        default_sandbox_provider: Some("modal".into()),
        multi_repo_providers: vec!["e2b".into()],
        sandbox_profiles: false,
        mints_sandbox_host_id: false,
        github_connection: false,
        fork_workspaces: false,
        custom_agents_settings: false,
        agent_detail: false,
        smart_routing: false,
    }
}

#[test]
fn records_round_trip_each_field() {
    assert_eq!(
        SandboxProfile::from(core::SandboxProfile::from(profile())),
        profile()
    );
    let original = repo("https://github.com/o/a", "main");
    assert_eq!(
        SandboxRepo::from(core::SandboxRepo::from(original.clone())),
        original
    );
    let page = core::SandboxProfilePage::from(SandboxProfilePage {
        profiles: vec![profile()],
        managed_providers: vec!["modal".into()],
        has_more: true,
    });
    assert_eq!(page.profiles[0].revision, "r1");
    assert_eq!(page.managed_providers, ["modal"]);
    assert!(page.has_more);
}

#[test]
fn the_host_menu_names_each_provider_and_its_repository_limit() {
    let options = sandbox_provider_options(catalog());
    assert_eq!(options.len(), 2);
    assert_eq!(options[0].provider.as_deref(), Some("modal"));
    assert_eq!(options[0].label, core::sandbox_option_label(Some("modal")));
    assert_eq!(options[0].max_repos, 1);
    assert_eq!(options[1].provider.as_deref(), Some("e2b"));
    assert_eq!(
        options[1].max_repos,
        u32::try_from(core::MAX_SANDBOX_REPOS).unwrap()
    );
    let without = CreationCatalog {
        managed_sandboxes: false,
        ..catalog()
    };
    assert_eq!(sandbox_provider_options(without), []);
}

#[test]
fn the_url_branch_repository_and_profile_rules_are_the_cores() {
    let url = "https://github.com/o/a";
    assert_eq!(
        sandbox_url_problem("https://github.com/o/b".into(), vec![repo(url, "")]),
        None
    );
    assert!(
        sandbox_url_problem(url.into(), vec![repo(url, "")]).is_some(),
        "a duplicate"
    );
    assert_eq!(sandbox_branch_problem(url.into(), "main".into()), None);
    assert!(sandbox_branch_problem(url.into(), "bad branch".into()).is_some());
    assert_eq!(sandbox_repos_problem(vec![repo(url, "")], 1), None);
    assert!(
        sandbox_repos_problem(vec![repo(url, ""), repo("https://github.com/o/b", "")], 1).is_some()
    );
    assert_eq!(
        compose_sandbox_workspaces(vec![repo(url, "main"), repo("https://github.com/o/b", "")]),
        ["https://github.com/o/a#main", "https://github.com/o/b"]
    );
    assert_eq!(sandbox_repo_name(url.into()), "a");
    assert_eq!(sandbox_repo_name("not a url".into()), "not a url");
    assert!(is_same_sandbox_repo(url.into(), format!("{url}.git")));
    assert!(!is_same_sandbox_repo(
        url.into(),
        "https://github.com/o/b".into()
    ));

    let page = SandboxProfilePage {
        profiles: vec![profile()],
        managed_providers: vec!["modal".into()],
        has_more: false,
    };
    assert!(sandbox_profile_problem(page.clone(), "modal".into(), None).is_some());
    assert_eq!(
        sandbox_profile_problem(page, "modal".into(), Some(profile())),
        None
    );
}

#[test]
fn profiles_and_github_listings_map_each_field_and_send_their_queries() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sandbox-profiles",
        reply(
            200,
            r#"{"profiles":[{"id":"p1","name":"GPU","description":"Fast","provider":"modal",
                "revision":"r1"}],"managed_providers":["modal"],"next_cursor":"more"}"#,
        ),
    );
    let page = harness
        .call(|core| async move {
            core.sandbox_profiles("modal".into(), " gp ".into(), Some("p1".into()))
                .await
        })
        .unwrap();
    assert_eq!(page.profiles, [profile()]);
    assert_eq!(page.managed_providers, ["modal"]);
    assert!(page.has_more);
    assert_eq!(harness.last_query("provider").as_deref(), Some("modal"));
    assert_eq!(harness.last_query("search").as_deref(), Some("gp"));
    assert_eq!(harness.last_query("profile_id").as_deref(), Some("p1"));

    harness.http.route(
        "/v1/connections/github/repos",
        reply(
            200,
            r#"{"connected":true,"truncated":true,"repos":[{"full_name":"o/a",
                "clone_url":"https://github.com/o/a.git","default_branch":"main","private":true}]}"#,
        ),
    );
    let list = harness
        .call(|core| async move { core.github_repos().await })
        .unwrap();
    assert!(list.connected);
    assert!(list.truncated);
    assert_eq!(
        list.repos,
        [GithubRepo {
            full_name: "o/a".into(),
            clone_url: "https://github.com/o/a.git".into(),
            default_branch: Some("main".into()),
            is_private: true,
        }]
    );

    harness.http.route(
        "/v1/connections/github/repos/o/a/branches",
        reply(200, r#"{"connected":true,"branches":["main","dev"]}"#),
    );
    assert_eq!(
        harness
            .call(|core| async move { core.github_branches("o/a".into()).await })
            .unwrap(),
        ["main", "dev"]
    );
}

#[test]
fn a_sandbox_fork_starts_from_the_pushed_branches_notes_and_profile() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions/conv_src",
        reply(
            200,
            r#"{"id":"conv_src","status":"idle","created_at":1,"permission_level":4,
                "labels":{"omnigent.sandbox.repo":"https://github.com/o/a#main https://github.com/o/b"},
                "sandbox_profile":{"id":"p1","name":"GPU","description":"Fast","provider":"modal","revision":"r1"}}"#,
        ),
    );
    harness.http.route(
        "/v1/info",
        reply(
            200,
            r#"{"single_user":true,"session_fork_workspaces":true}"#,
        ),
    );
    harness.http.route(
        "/v1/sessions/conv_src/resources/repository-branches",
        reply(
            200,
            r#"{"repositories":[{"url":"https://github.com/o/a","branch":"feat","pushed":true},
                {"url":"https://github.com/o/b","branch":"wip","pushed":false}]}"#,
        ),
    );
    let defaults = harness
        .call(|core| async move { core.fork_sandbox_defaults("conv_src".into()).await })
        .unwrap();
    assert_eq!(
        defaults.repos,
        [
            repo("https://github.com/o/a", "feat"),
            repo("https://github.com/o/b", "")
        ]
    );
    let SandboxRepoNote { url, note } = &defaults.notes[0];
    assert_eq!(url, "https://github.com/o/b");
    assert!(note.contains("wip"), "{note}");
    assert_eq!(defaults.profile, Some(profile()));
    assert_eq!(defaults.branch_check_error, None);
}
