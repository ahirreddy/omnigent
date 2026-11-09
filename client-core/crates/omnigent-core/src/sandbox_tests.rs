//! Sandbox repository, profile and listing rules, ported from the web's
//! `sandboxRepositories.test.ts`, `SandboxProfilePicker.test.tsx` and the fork dialog tests.

use serde_json::json;

use super::*;

fn repo(url: &str, branch: &str) -> SandboxRepo {
    SandboxRepo {
        url: url.into(),
        branch: branch.into(),
    }
}

#[test]
fn repository_urls_take_https_or_ssh_without_credentials() {
    for good in [
        "https://github.com/org/repo",
        "https://github.com/org/repo.git",
        "https://gitlab.example.com//group/sub/repo",
        "git@github.com:org/repo.git",
        "  https://github.com/org/repo  ",
    ] {
        assert!(is_valid_sandbox_repo_url(good), "{good}");
    }
    for bad in [
        "",
        "http://github.com/org/repo",
        "https://user:token@github.com/org/repo",
        "https://github.com",
        "https://github.com/org/repo#main",
        "git@github.com/org/repo",
        "https://github.com/org/..",
        "https://github.com/org/re po",
    ] {
        assert!(!is_valid_sandbox_repo_url(bad), "{bad}");
    }
}

#[test]
fn branches_follow_the_servers_rules_and_blank_is_the_default() {
    assert!(is_valid_sandbox_branch(""));
    assert!(is_valid_sandbox_branch("feature/one"));
    for bad in [
        "-x",
        "/x",
        "x/",
        "x.",
        "a..b",
        "a@{b",
        "a b",
        "a#b",
        "a:b",
        "0123456789abcdef0123456789abcdef01234567",
    ] {
        assert!(!is_valid_sandbox_branch(bad), "{bad}");
    }
}

#[test]
fn workspaces_compose_split_and_measure() {
    assert_eq!(
        compose_sandbox_workspace(" https://g.com/o/r ", " main "),
        Some("https://g.com/o/r#main".into())
    );
    assert_eq!(compose_sandbox_workspace("  ", "main"), None);
    assert_eq!(
        split_sandbox_workspace("https://g.com/o/r#a#b"),
        repo("https://g.com/o/r", "a#b")
    );
    assert_eq!(
        compose_sandbox_workspaces(&[repo("https://g.com/o/a", ""), repo(" ", "x")]),
        ["https://g.com/o/a"]
    );
    let long = format!("https://g.com/o/{}", "r".repeat(240));
    assert!(fits_sandbox_workspace(&long, ""));
    assert!(!fits_sandbox_workspace(&long, "branch-name"));
    assert_eq!(
        sandbox_branch_problem(&long, "branch-name").as_deref(),
        Some(WORKSPACE_LENGTH_MESSAGE)
    );
}

#[test]
fn names_and_identities_match_the_clone_directory() {
    assert_eq!(
        derive_repo_name("https://github.com/org/repo.git/").as_deref(),
        Some("repo")
    );
    assert_eq!(
        derive_repo_name("git@github.com:org/tool").as_deref(),
        Some("tool")
    );
    assert_eq!(
        repo_identity("git@github.com:Org/Repo.git"),
        repo_identity("https://github.com/org/repo/")
    );
    let selected = [repo("https://github.com/org/repo", "")];
    assert!(
        sandbox_url_problem("git@github.com:ORG/repo.git", &selected)
            .unwrap()
            .contains("already selected")
    );
    assert_eq!(sandbox_url_problem("", &selected), None);
    assert!(sandbox_url_problem("ftp://x/y", &selected).is_some());
    assert_eq!(
        sandbox_url_problem("https://github.com/org/other", &selected),
        None
    );
}

#[test]
fn repository_lists_respect_the_providers_cap() {
    let two = [
        repo("https://g.com/o/a", ""),
        repo("https://g.com/o/b", "dev"),
    ];
    assert_eq!(sandbox_repos_problem(&two, MAX_SANDBOX_REPOS), None);
    assert!(
        sandbox_repos_problem(&two, 1)
            .unwrap()
            .contains("at most 1 repository.")
    );
    assert_eq!(
        sandbox_repos_problem(&[repo("https://g.com/o/a", "a b")], 1).as_deref(),
        Some(INVALID_BRANCH_MESSAGE)
    );
}

#[test]
fn providers_are_labelled_by_name() {
    assert_eq!(sandbox_option_label(None), "New Sandbox");
    assert_eq!(sandbox_option_label(Some("")), "New Sandbox");
    assert_eq!(sandbox_option_label(Some("lakebox")), "Databricks Sandbox");
    assert_eq!(sandbox_option_label(Some("modal")), "Modal Sandbox");
    assert_eq!(sandbox_option_label(Some("docker")), "Docker Sandbox");
}

#[test]
fn profile_pages_keep_the_providers_profiles_and_require_one_when_managed() {
    let page = SandboxProfilePage::from_value(
        &json!({
            "profiles": [
                {"id": "p1", "name": "GPU", "description": "A100", "provider": "modal",
                 "revision": "r1"},
                {"id": "p2", "name": "Other", "provider": "e2b", "revision": "r9"}
            ],
            "managed_providers": ["modal"],
            "next_cursor": "c2"
        }),
        "modal",
    )
    .unwrap();
    assert_eq!(page.profiles.len(), 1);
    assert_eq!(page.profiles[0].description, "A100");
    assert!(page.has_more);
    assert!(page.requires_profile("modal"));
    assert_eq!(
        sandbox_profile_problem(&page, "modal", None).as_deref(),
        Some("Choose a sandbox profile to continue.")
    );
    assert_eq!(
        sandbox_profile_problem(&page, "modal", Some(&page.profiles[0])),
        None
    );
    assert_eq!(sandbox_profile_problem(&page, "e2b", None), None);
    let empty = SandboxProfilePage {
        managed_providers: vec!["modal".into()],
        ..SandboxProfilePage::default()
    };
    assert_eq!(
        sandbox_profile_problem(&empty, "modal", None).as_deref(),
        Some("No sandbox profiles available for this provider.")
    );
    assert!(SandboxProfilePage::from_value(&json!({"profiles": [{"id": 1}]}), "modal").is_err());
}

#[test]
fn github_listings_decode_and_hide_repos_when_disconnected() {
    let list = GithubRepoList::from_value(&json!({
        "connected": true, "truncated": true,
        "repos": [
            {"full_name": "org/app", "clone_url": null, "default_branch": "main",
             "private": true, "pushed_at": null}
        ]
    }))
    .unwrap();
    assert_eq!(list.repos[0].clone_url, "https://github.com/org/app.git");
    assert!(list.truncated && list.repos[0].private);
    let disconnected =
        GithubRepoList::from_value(&json!({"connected": false, "repos": [{"full_name": "x/y"}]}))
            .unwrap();
    assert!(!disconnected.connected && disconnected.repos.is_empty());
    assert_eq!(
        github_branches(&json!({"connected": true, "branches": ["main", "dev"]})).unwrap(),
        ["main", "dev"]
    );
    assert_eq!(
        github_branches(&json!({"connected": false, "branches": ["main"]}))
            .unwrap()
            .len(),
        0
    );
}

#[test]
fn fork_repositories_move_to_pushed_branches_and_note_unpushed_ones() {
    let original = [
        repo("https://g.com/o/a", "main"),
        repo("https://g.com/o/b", ""),
        repo("https://g.com/o/c", "dev"),
        repo("https://g.com/o/d", ""),
    ];
    let live = repository_branches(&json!({"repositories": [
        {"url": "https://g.com/o/a", "branch": "feature", "pushed": true},
        {"url": "https://g.com/o/b", "branch": "local-only", "pushed": false},
        {"url": "https://g.com/o/c", "branch": null, "pushed": null},
        {"url": "https://g.com/o/d", "branch": "bad name", "pushed": true}
    ]}))
    .unwrap();
    let forked = fork_sandbox_repos(&original, &live);
    let branches: Vec<_> = forked.repos.iter().map(|r| r.branch.as_str()).collect();
    assert_eq!(branches, ["feature", "", "dev", ""]);
    assert_eq!(
        forked.notes,
        [(
            "https://g.com/o/b".to_owned(),
            "\u{201c}local-only\u{201d} isn\u{2019}t pushed. Using the default branch.".to_owned()
        )]
    );
}

#[test]
fn a_repository_listed_twice_keeps_its_original_branch() {
    let original = [
        repo("https://g.com/o/a", "main"),
        repo("https://g.com/o/a", "x"),
    ];
    let live = [RepositoryBranch {
        url: "https://g.com/o/a".into(),
        branch: Some("feature".into()),
        pushed: Some(true),
    }];
    let forked = fork_sandbox_repos(&original, &live);
    assert_eq!(forked.repos, original);
}

#[test]
fn an_overly_long_url_and_too_many_repositories_are_explained() {
    let long = format!("https://github.com/o/{}.git", "x".repeat(4096));
    assert_eq!(
        sandbox_url_problem(&long, &[]).as_deref(),
        Some(WORKSPACE_LENGTH_MESSAGE)
    );
    let problem = sandbox_repos_problem(
        &[
            repo("https://github.com/o/a.git", "main"),
            repo("https://github.com/o/b.git", "main"),
            repo("https://github.com/o/c.git", "main"),
        ],
        2,
    )
    .unwrap();
    assert!(problem.contains("repositories"), "{problem}");
}

#[test]
fn an_unpushed_branch_falls_back_to_the_repository_branch_the_session_named() {
    let original = [repo("https://g.com/o/b", "main")];
    let live = repository_branches(&json!({"repositories": [
        {"url": "https://g.com/o/b", "branch": "local-only", "pushed": false},
    ]}))
    .unwrap();
    let forked = fork_sandbox_repos(&original, &live);
    assert_eq!(forked.repos[0].branch, "main");
    assert!(
        forked.notes[0].1.ends_with("Using main."),
        "{:?}",
        forked.notes
    );
}
