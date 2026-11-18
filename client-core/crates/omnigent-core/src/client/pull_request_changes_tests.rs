//! The changed files, patches, file texts and commits in the shapes main's host answers them.

use futures::executor::block_on;
use serde_json::json;

use super::PullRequestInfo;
use super::changes::{
    COMPARE_UNSUPPORTED, ChangedFileStatus, Revision, decode_changes, decode_commits,
};
use crate::client::SessionError;
use crate::client::test_support::{Reply, RouteTransport, connected, path_of, query_value};

const GITHUB: &str = "/v1/sessions/conv_a/resources/github";
const PR: &str = "https://github.com/o/r/pull/7";
const HEAD: &str = "1111111111111111111111111111111111111111";
const BASE: &str = "2222222222222222222222222222222222222222";

/// `_pr_changed_files_at_revision`'s answer: a rename, an addition without counts, a
/// truncated list and the revision it was read at.
fn changes() -> String {
    json!({
        "object": "list",
        "data": [
            {"object": "session.github.changed_file", "path": "src/new.rs", "name": "new.rs",
             "status": "renamed", "lines_added": 2, "lines_removed": 1,
             "previous_path": "src/old.rs"},
            {"object": "session.github.changed_file", "path": "README.md", "name": "README.md",
             "status": "created", "lines_added": null, "lines_removed": null,
             "previous_path": null},
            {"object": "session.github.changed_file", "path": "gone.txt", "name": "gone.txt",
             "status": "deleted", "lines_added": 0, "lines_removed": 4},
            {"object": "session.github.changed_file", "path": "x.py", "name": "x.py",
             "status": "modified", "lines_added": 1, "lines_removed": 1}
        ],
        "has_more": true,
        "warning": "The provider lists at most 4 files; 1 files are not shown.",
        "total_count": 5, "head_sha": HEAD, "base_sha": BASE
    })
    .to_string()
}

#[test]
fn changed_files_decode_statuses_counts_renames_and_the_revision() {
    let decoded = decode_changes(&serde_json::from_str(&changes()).unwrap()).unwrap();
    assert!(decoded.available && decoded.has_more);
    assert_eq!(decoded.total_count, Some(5));
    assert_eq!(decoded.head_sha.as_deref(), Some(HEAD));
    assert_eq!(decoded.base_sha.as_deref(), Some(BASE));
    assert!(decoded.warning.unwrap().contains("not shown"));
    let statuses: Vec<_> = decoded.files.iter().map(|file| file.status).collect();
    assert_eq!(
        statuses,
        [
            ChangedFileStatus::Renamed,
            ChangedFileStatus::Created,
            ChangedFileStatus::Deleted,
            ChangedFileStatus::Modified
        ]
    );
    assert_eq!(
        decoded.files[0].previous_path.as_deref(),
        Some("src/old.rs")
    );
    assert_eq!(
        (decoded.files[0].lines_added, decoded.files[0].lines_removed),
        (Some(2), Some(1))
    );
    assert_eq!(decoded.files[1].lines_added, None, "no line counts");
    assert!(decode_changes(&json!({"data": [{"status": "modified"}]})).is_err());
}

#[test]
fn the_list_and_patch_are_pinned_and_a_missing_workspace_has_no_list() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "GET",
        &format!("{GITHUB}/changes"),
        vec![
            Reply::json(200, changes()),
            Reply::json(404, r#"{"detail":"no fs"}"#),
        ],
    );
    transport.ok(
        &format!("{GITHUB}/diff"),
        json!({"object": "session.github.pr_diff", "patch": "diff --git a/x b/x\n",
               "head_sha": HEAD, "base_sha": BASE})
        .to_string(),
    );
    let core = connected(transport);
    let revision = Revision {
        base_sha: BASE,
        head_sha: HEAD,
    };
    let listed = block_on(core.pull_request_changes("conv_a", Some(PR), Some(revision))).unwrap();
    assert_eq!(listed.files.len(), 4);
    let missing = block_on(core.pull_request_changes("conv_a", Some(PR), Some(revision))).unwrap();
    assert!(!missing.available && missing.files.is_empty());
    let patch = block_on(core.pull_request_patch("conv_a", Some(PR), Some(revision))).unwrap();
    assert_eq!(patch.head_sha.as_deref(), Some(HEAD));
    assert_eq!(patch.base_sha.as_deref(), Some(BASE));
    // An unknown base leaves the read unpinned, as the web's `pinnedPrQuery`.
    let unpinned = Revision {
        base_sha: "",
        head_sha: HEAD,
    };
    block_on(core.pull_request_patch("conv_a", Some(PR), Some(unpinned))).unwrap();

    let requests = core.transport().taken();
    let reads: Vec<_> = requests
        .iter()
        .filter(|request| path_of(request).starts_with(GITHUB))
        .collect();
    for read in &reads[..3] {
        assert_eq!(query_value(read, "pr_url").as_deref(), Some(PR));
        assert_eq!(query_value(read, "head_sha").as_deref(), Some(HEAD));
        assert_eq!(query_value(read, "base_sha").as_deref(), Some(BASE));
    }
    assert_eq!(query_value(reads[3], "head_sha"), None);
    assert_eq!(query_value(reads[3], "pr_url").as_deref(), Some(PR));
}

#[test]
fn a_file_text_is_read_by_escaped_segments_with_its_revision() {
    let transport = RouteTransport::local();
    transport.ok(
        &format!("{GITHUB}/diff/src/a%20b/c%23d.rs"),
        json!({"object": "session.github.file_diff", "path": "src/a b/c#d.rs",
               "before": "one\ntwo\n", "after": null})
        .to_string(),
    );
    let core = connected(transport);
    let revision = Revision {
        base_sha: BASE,
        head_sha: HEAD,
    };
    let contents = block_on(core.pull_request_file_contents(
        "conv_a",
        "src/a b/c#d.rs",
        Some("main"),
        Some(PR),
        Some("src/old.rs"),
        Some(revision),
    ))
    .unwrap();
    assert_eq!(contents.before.as_deref(), Some("one\ntwo\n"));
    assert_eq!(contents.after, None, "deleted at the head");
    let request = core.transport().taken().pop().unwrap();
    assert_eq!(query_value(&request, "base").as_deref(), Some("main"));
    assert_eq!(
        query_value(&request, "previous_path").as_deref(),
        Some("src/old.rs")
    );
    assert_eq!(query_value(&request, "head_sha").as_deref(), Some(HEAD));
    assert_eq!(query_value(&request, "base_sha").as_deref(), Some(BASE));
    for refused in ["", "a/../b", "a//b", "./a"] {
        assert!(matches!(
            block_on(core.pull_request_file_contents("conv_a", refused, None, None, None, None)),
            Err(SessionError::InvalidInput { .. })
        ));
    }
}

/// `_pr_commits`'s answer: two commits, the older one a stacked parent's head.
fn commits() -> String {
    json!({
        "object": "list",
        "data": [
            {"object": "session.github.commit", "sha": BASE, "title": "Add the parser",
             "author": "Ann", "date": "2026-01-01T00:00:00Z",
             "head_of": [{"number": 41, "url": "https://github.com/o/r/pull/41", "state": "OPEN"}]},
            {"object": "session.github.commit", "sha": HEAD, "title": "", "author": null,
             "date": null}
        ],
        "has_more": true
    })
    .to_string()
}

#[test]
fn commits_list_oldest_first_with_the_prs_they_head() {
    let decoded = decode_commits(&serde_json::from_str(&commits()).unwrap()).unwrap();
    assert!(decoded.has_more);
    assert_eq!(decoded.commits[0].title, "Add the parser");
    assert_eq!(decoded.commits[0].head_of[0].number, 41);
    assert_eq!(decoded.commits[0].head_of[0].state.as_deref(), Some("OPEN"));
    assert!(decoded.commits[1].head_of.is_empty() && decoded.commits[1].author.is_none());
    assert!(decode_commits(&json!({"data": [{"title": "no sha"}]})).is_err());
}

#[test]
fn commit_reads_say_when_the_server_lacks_the_routes() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "GET",
        &format!("{GITHUB}/commits"),
        vec![
            Reply::json(200, commits()),
            Reply::json(404, r#"{"detail":"Not Found"}"#),
            Reply::json(
                400,
                r#"{"detail":"Expected head_sha to be a full commit SHA"}"#,
            ),
        ],
    );
    transport.enqueue(
        "GET",
        &format!("{GITHUB}/commit-diff"),
        vec![
            Reply::json(
                200,
                r#"{"object":"session.github.pr_diff","patch":"diff --git a/x b/x\n"}"#,
            ),
            Reply::json(404, r#"{"detail":"Not Found"}"#),
        ],
    );
    transport.enqueue(
        "GET",
        &format!("{GITHUB}/compare-diff"),
        vec![
            Reply::json(
                200,
                r#"{"object":"session.github.pr_diff","patch":"","head_sha":"h"}"#,
            ),
            Reply::json(404, r#"{"detail":"Not Found"}"#),
        ],
    );
    let core = connected(transport);
    let listed = block_on(core.pull_request_commits("conv_a", PR, HEAD)).unwrap();
    assert_eq!(listed.unwrap().commits.len(), 2);
    assert_eq!(
        block_on(core.pull_request_commits("conv_a", PR, HEAD)),
        Ok(None),
        "a server without the routes"
    );
    assert!(matches!(
        block_on(core.pull_request_commits("conv_a", PR, "short")),
        Err(SessionError::Rejected { status: 400, message }) if message.contains("full commit")
    ));
    let commit = block_on(core.pull_request_commit_diff("conv_a", PR, BASE)).unwrap();
    assert!(commit.unwrap().patch.starts_with("diff --git"));
    assert_eq!(
        block_on(core.pull_request_commit_diff("conv_a", PR, BASE)),
        Ok(None)
    );
    let since = block_on(core.pull_request_compare_diff("conv_a", PR, BASE, HEAD)).unwrap();
    assert_eq!(since.head_sha.as_deref(), Some("h"));
    assert!(matches!(
        block_on(core.pull_request_compare_diff("conv_a", PR, BASE, HEAD)),
        Err(SessionError::Rejected { status: 404, message }) if message == COMPARE_UNSUPPORTED
    ));

    let requests = core.transport().taken();
    let find = |route: &str| {
        requests
            .iter()
            .find(|request| path_of(request) == format!("{GITHUB}/{route}"))
            .unwrap()
    };
    assert_eq!(
        query_value(find("commits"), "head_sha").as_deref(),
        Some(HEAD)
    );
    assert_eq!(
        query_value(find("commit-diff"), "commit_sha").as_deref(),
        Some(BASE)
    );
    let compare = find("compare-diff");
    assert_eq!(query_value(compare, "from_sha").as_deref(), Some(BASE));
    assert_eq!(query_value(compare, "head_sha").as_deref(), Some(HEAD));
    assert_eq!(query_value(compare, "pr_url").as_deref(), Some(PR));
}

#[test]
fn info_names_the_provider_and_the_head_repository() {
    let base = json!({"object": "session.github.info", "available": true,
                      "auth": {"authenticated": true}, "repo": {"name_with_owner": "o/r"},
                      "pr": {"number": 7, "url": PR, "state": "OPEN",
                             "head_repository_url": "https://github.com/fork/r"}});
    let legacy = PullRequestInfo::from_value(&base).unwrap();
    assert_eq!(
        legacy.provider.as_deref(),
        Some("github"),
        "a host before providers"
    );
    assert_eq!(
        legacy.pull_request.unwrap().head_repository_url.as_deref(),
        Some("https://github.com/fork/r")
    );
    let mut gitlab = base.clone();
    gitlab["provider"] = json!("gitlab");
    assert_eq!(
        PullRequestInfo::from_value(&gitlab)
            .unwrap()
            .provider
            .as_deref(),
        Some("gitlab")
    );
    let mut none = base;
    none["provider"] = json!(null);
    assert_eq!(PullRequestInfo::from_value(&none).unwrap().provider, None);
}
