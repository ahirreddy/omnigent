//! A pull request's live detail and the changes the panel makes to it.

use futures::executor::block_on;

use super::SessionError;
use super::pull_request_detail::{
    CheckBucket, HOST_OFFLINE, PullRequestAvailability, PullRequestCondition, PullRequestInfo,
    ReviewState, ReviewerKind,
};
use super::pull_request_edits::{MergeMethod, ReviewerTarget};
use super::pull_requests::PullRequestStatus;
use super::test_support::{Reply, RouteTransport, body_json, connected, query_value};

const INFO: &str = "/v1/sessions/conv_a/resources/github";
const PR: &str = "https://github.com/o/r/pull/7";

fn info(body: &str) -> PullRequestInfo {
    PullRequestInfo::from_value(&serde_json::from_str(body).unwrap()).unwrap()
}

const READY: &str = r##"{"object":"session.github.info","available":true,"branch":"fix",
  "repo":{"name_with_owner":"o/r"},"base_ref":"main","selected_pr_url":"https://github.com/o/r/pull/7",
  "provider":"github","provider_display":{"display_name":"GitHub","number_prefix":"#"},
  "auth":{"authenticated":true,"hint":null,"cli":{"name":"gh","available":true}},
  "capabilities":{"label_editing":true,"merging":true,"comment_posting":false},
  "tracking_available":true,"warnings":["slow"],"discovery_warnings":["gitlab down"],
  "prs":[{"url":"https://github.com/o/r/pull/7","host":"github.com","repository":"o/r",
          "number":7,"title":"Fix","relationship":"created","state":"OPEN"}],
  "pr":{"number":7,"title":"Fix","state":"OPEN","url":"https://github.com/o/r/pull/7",
        "is_draft":false,"author":"ann","base_ref":"main","head_ref":"fix","head_sha":"abc",
        "body":"Body","checks":{"passing":2,"failing":0,"pending":0,"total":2,
          "runs":[{"name":"lint","bucket":"passing","url":null},{"name":"x","bucket":"odd"}]},
        "comments":[{"author":"bob","body":"LGTM","created_at":"2026-01-01T00:00:00Z","url":"u"}],
        "reviewers":[{"login":"core","kind":"team","state":"PENDING"},
                     {"login":"bob","kind":"user","state":"APPROVED"}],
        "labels":[{"name":"bug","color":"d73a4a","description":null}],
        "merge_state_status":"CLEAN","auto_merge":null}}"##;

#[test]
fn info_decodes_the_selected_pull_request_and_what_the_panel_can_do() {
    let info = info(READY);
    assert_eq!(info.availability, PullRequestAvailability::Ready);
    assert_eq!(info.provider_name.as_deref(), Some("GitHub"));
    assert_eq!(info.repository.as_deref(), Some("o/r"));
    assert_eq!(info.warnings, vec!["slow", "gitlab down"]);
    assert!(info.tracking_available && info.capabilities.merging);
    assert!(!info.capabilities.comment_posting && !info.capabilities.reviewer_editing);
    assert_eq!(info.linked.len(), 1);
    let pr = info.pull_request.unwrap();
    assert_eq!(pr.condition, PullRequestCondition::Ready);
    assert_eq!(pr.checks.runs.len(), 1, "an unknown bucket is left out");
    assert_eq!(pr.checks.runs[0].bucket, CheckBucket::Passing);
    assert_eq!(pr.comments[0].author.as_deref(), Some("bob"));
    let reviewers = pr.reviewers.unwrap();
    assert_eq!(reviewers[0].kind, ReviewerKind::Team);
    assert_eq!(reviewers[1].state, ReviewState::Approved);
    assert_eq!(pr.labels.unwrap()[0].color.as_deref(), Some("d73a4a"));
    assert!(pr.reports_merge_state && pr.auto_merge.is_none());
}

#[test]
fn the_condition_follows_the_webs_status_rule() {
    let with = |state: &str, draft: bool, checks: &str, merge: &str| {
        let body = format!(
            r#"{{"number":1,"title":"t","url":"u","state":"{state}","is_draft":{draft},
                "checks":{checks},"merge_state_status":{merge}}}"#
        );
        super::pull_request_detail::PullRequestDetail::from_value(
            &serde_json::from_str(&body).unwrap(),
        )
        .unwrap()
        .condition
    };
    let none = r#"{"failing":0,"pending":0}"#;
    assert_eq!(
        with("MERGED", false, none, "null"),
        PullRequestCondition::Merged
    );
    assert_eq!(
        with("CLOSED", false, none, "null"),
        PullRequestCondition::Closed
    );
    assert_eq!(
        with("OPEN", false, none, r#""DIRTY""#),
        PullRequestCondition::Conflict
    );
    assert_eq!(
        with("OPEN", true, r#"{"failing":1}"#, "null"),
        PullRequestCondition::ChecksFailing,
        "a draft still surfaces a failing check"
    );
    assert_eq!(
        with("OPEN", true, r#"{"pending":1}"#, "null"),
        PullRequestCondition::Draft
    );
    assert_eq!(
        with("OPEN", false, r#"{"pending":1}"#, r#""CLEAN""#),
        PullRequestCondition::ChecksRunning
    );
    assert_eq!(
        with("OPEN", false, r#"{"partial":true}"#, r#""CLEAN""#),
        PullRequestCondition::Open,
        "unread checks never read as ready"
    );
    assert_eq!(
        with("OPEN", false, none, r#""BLOCKED""#),
        PullRequestCondition::Open
    );
    assert_eq!(
        PullRequestCondition::of_stored(PullRequestStatus::Draft),
        PullRequestCondition::Draft
    );
}

#[test]
fn availability_explains_why_there_is_no_pull_request() {
    let base = r#""available":true,"repo":{"name_with_owner":"o/r"}"#;
    assert_eq!(
        info(r#"{"available":false,"reason":"not_a_git_repo"}"#).availability,
        PullRequestAvailability::NotAGitRepository
    );
    assert_eq!(
        info(r#"{"available":false,"reason":"unsupported_remote","remote_host":"git.x"}"#)
            .availability,
        PullRequestAvailability::UnsupportedRemote {
            remote_host: Some("git.x".to_owned())
        }
    );
    assert_eq!(
        info(r#"{"available":true,"auth":{"authenticated":false,"cli":{"name":"gh","available":false}}}"#)
            .availability,
        PullRequestAvailability::NoCli { cli: "gh".to_owned() }
    );
    assert_eq!(
        info(r#"{"available":true,"auth":{"authenticated":false,"hint":"Run gh auth login"}}"#)
            .availability,
        PullRequestAvailability::RepositoryUnresolved {
            hint: Some("Run gh auth login".to_owned())
        }
    );
    assert_eq!(
        info(&format!(r#"{{{base},"branch":"b"}}"#)).availability,
        PullRequestAvailability::NoPullRequest,
        "a legacy host without `auth` is signed in unless it says otherwise"
    );
    assert_eq!(
        info(&format!(r#"{{{base},"warnings":["rate limited"]}}"#)).availability,
        PullRequestAvailability::Unavailable
    );
}

#[test]
fn info_reads_the_selected_pr_and_maps_host_failures() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "GET",
        INFO,
        vec![
            Reply::json(200, READY),
            Reply::json(
                404,
                r#"{"error":{"message":"Resource 'github' not found"}}"#,
            ),
            Reply::json(
                404,
                r#"{"detail":"Session has no filesystem; GitHub API unavailable."}"#,
            ),
            Reply::json(
                503,
                r#"{"error":{"code":"runner_unavailable","message":"x"}}"#,
            ),
            Reply::json(
                400,
                r#"{"detail":"This pull request is not associated with the session"}"#,
            ),
            Reply::json(502, "bad gateway"),
        ],
    );
    let core = connected(transport);
    let read = || block_on(core.pull_request_info("conv_a", Some(PR)));
    assert_eq!(read().unwrap().availability, PullRequestAvailability::Ready);
    assert_eq!(
        read().unwrap().availability,
        PullRequestAvailability::HostOutdated
    );
    assert_eq!(
        read().unwrap().availability,
        PullRequestAvailability::Unavailable
    );
    assert_eq!(
        read(),
        Err(SessionError::Rejected {
            status: 503,
            message: HOST_OFFLINE.to_owned()
        })
    );
    assert_eq!(
        read(),
        Err(SessionError::Rejected {
            status: 400,
            message: "This pull request is not associated with the session".to_owned()
        })
    );
    assert_eq!(read(), Err(SessionError::HttpStatus { status: 502 }));
    let requests = core.transport().taken();
    let first = requests.iter().find(|r| r.url.contains(INFO)).unwrap();
    assert_eq!(query_value(first, "pr_url").as_deref(), Some(PR));
    assert!(matches!(
        block_on(core.pull_request_info("../x", None)),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}

#[test]
fn patch_reads_the_whole_diff_or_why_it_is_unavailable() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "GET",
        &format!("{INFO}/diff"),
        vec![
            Reply::json(200, r#"{"object":"session.github.pr_diff","patch":"diff --git a/x b/x\n"}"#),
            Reply::json(
                200,
                r#"{"object":"session.github.pr_diff","patch":"","unavailable_reason":"pr_outside_workspace"}"#,
            ),
        ],
    );
    let core = connected(transport);
    let patch = block_on(core.pull_request_patch("conv_a", Some(PR))).unwrap();
    assert!(patch.patch.starts_with("diff --git") && patch.unavailable.is_none());
    let outside = block_on(core.pull_request_patch("conv_a", Some(PR))).unwrap();
    assert!(
        outside
            .unavailable
            .unwrap()
            .contains("outside this workspace")
    );
}

#[test]
fn link_and_unlink_post_the_url_and_answer_the_list() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("POST"),
        &format!("{INFO}/prs"),
        None,
        Reply::json(200, READY),
    );
    let core = connected(transport);
    let linked = block_on(core.link_pull_request("conv_a", &format!(" {PR} "))).unwrap();
    assert_eq!(linked.selected_url.as_deref(), Some(PR));
    block_on(core.unlink_pull_request("conv_a", PR)).unwrap();
    let bodies = core.transport().write_bodies();
    assert_eq!(
        bodies[0],
        serde_json::json!({"url": PR, "action": "attach"})
    );
    assert_eq!(
        bodies[1],
        serde_json::json!({"url": PR, "action": "remove"})
    );
    assert!(matches!(
        block_on(core.link_pull_request("conv_a", "  ")),
        Err(SessionError::InvalidInput { .. })
    ));
}

/// Answers for every edit route.
fn edit_routes() -> RouteTransport {
    let transport = RouteTransport::local();
    transport
        .respond(
            Some("POST"),
            &format!("{INFO}/labels"),
            None,
            Reply::json(200, r#"{"labels":[{"name":"bug","color":"d73a4a"}]}"#),
        )
        .respond(
            Some("GET"),
            &format!("{INFO}/labels"),
            None,
            Reply::json(200, r#"{"data":[{"name":"a"},{"name":"b"}],"has_more":true}"#),
        )
        .respond(
            Some("GET"),
            &format!("{INFO}/reviewers"),
            None,
            Reply::json(
                200,
                r#"{"data":[{"login":"ann","kind":"user","name":"Ann"},{"login":"core","kind":"team"}]}"#,
            ),
        )
        .respond(
            Some("POST"),
            &format!("{INFO}/reviewers"),
            None,
            Reply::json(200, r#"{"reviewers":[{"login":"ann","kind":"user","state":"PENDING"}]}"#),
        )
        .respond(
            Some("GET"),
            &format!("{INFO}/merge-options"),
            None,
            Reply::json(200, r#"{"methods":["squash","merge","octopus"],"default":"squash"}"#),
        )
        .respond(Some("POST"), &format!("{INFO}/merge"), None, Reply::json(200, "{}"))
        .respond(
            Some("POST"),
            &format!("{INFO}/comments"),
            None,
            Reply::json(200, r#"{"comment":{"author":"me","body":"hi","url":"c"}}"#),
        );
    transport
}

#[test]
fn edits_send_the_pr_and_decode_the_result() {
    let core = connected(edit_routes());
    let labels =
        block_on(core.update_pull_request_labels("conv_a", PR, &["bug".into()], &[])).unwrap();
    assert_eq!(labels[0].name, "bug");
    let offered = block_on(core.pull_request_repository_labels("conv_a", PR)).unwrap();
    assert!(offered.has_more && offered.items.len() == 2);
    let candidates = block_on(core.pull_request_review_candidates("conv_a", PR)).unwrap();
    assert_eq!(candidates.items[1].kind, ReviewerKind::Team);
    let ann = ReviewerTarget {
        login: "ann".into(),
        kind: ReviewerKind::User,
    };
    let reviewers =
        block_on(core.update_pull_request_reviewers("conv_a", PR, &[ann], &[])).unwrap();
    assert_eq!(reviewers[0].state, ReviewState::Pending);
    let options = block_on(core.pull_request_merge_options("conv_a", PR)).unwrap();
    assert_eq!(
        options.methods,
        vec![MergeMethod::Squash, MergeMethod::Merge]
    );
    assert_eq!(options.default, Some(MergeMethod::Squash));
    block_on(core.merge_pull_request("conv_a", PR, MergeMethod::Squash, "abc")).unwrap();
    let comment = block_on(core.post_pull_request_comment("conv_a", PR, "hi")).unwrap();
    assert_eq!(comment.author.as_deref(), Some("me"));
    let writes = core.transport().writes();
    assert_eq!(
        body_json(&writes[0]),
        serde_json::json!({"pr_url": PR, "add": ["bug"], "remove": []})
    );
    assert_eq!(
        body_json(&writes[1]),
        serde_json::json!({"pr_url": PR, "add": [{"login": "ann", "kind": "user"}], "remove": []})
    );
    assert_eq!(
        body_json(&writes[2]),
        serde_json::json!({"pr_url": PR, "merge_method": "squash", "expected_head": "abc"})
    );
    assert!(matches!(
        block_on(core.merge_pull_request("conv_a", PR, MergeMethod::Merge, "")),
        Err(SessionError::InvalidInput { .. })
    ));
    assert!(matches!(
        block_on(core.post_pull_request_comment("conv_a", PR, " ")),
        Err(SessionError::InvalidInput { .. })
    ));
}

#[test]
fn a_refused_edit_keeps_the_hosts_reason() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("POST"),
        &format!("{INFO}/disable-auto-merge"),
        None,
        Reply::json(
            400,
            r#"{"detail":"The GitHub account on the host cannot disable auto-merge."}"#,
        ),
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.disable_pull_request_auto_merge("conv_a", PR)),
        Err(SessionError::Rejected {
            status: 400,
            message: "The GitHub account on the host cannot disable auto-merge.".to_owned()
        })
    );
}
