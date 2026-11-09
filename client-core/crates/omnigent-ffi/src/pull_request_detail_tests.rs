//! The pull request panel over the fake host: each record's fields, each conversion's arms and
//! the request every edit sends.

#![allow(
    clippy::too_many_lines,
    reason = "one fixture's decoded fields are asserted in one place"
)]

use omnigent_core::pull_request_detail as core_detail;
use omnigent_core::pull_request_edits as core_edits;
use omnigent_core::pull_requests as core_stored;
use serde_json::json;

use crate::errors::CoreError;
use crate::pull_request_detail::{
    CheckBucket, MergeMethod, PullRequestAvailability, PullRequestCondition, ReviewState,
    ReviewerKind, ReviewerTarget,
};
use crate::pull_requests::{PanelFeatures, PullRequestStatus};
use crate::test_support::{connected, json as reply};

const INFO: &str = "/v1/sessions/conv_a/resources/github";
const PR: &str = "https://github.com/o/r/pull/7";

const FULL_INFO: &str = r#"{"object":"session.github.info","available":true,"branch":"fix",
  "repo":{"name_with_owner":"o/r"},"base_ref":"trunk","selected_pr_url":"https://github.com/o/r/pull/7",
  "provider":"github","provider_display":{"display_name":"GitHub","number_prefix":"!"},
  "auth":{"authenticated":true,"cli":{"name":"gh","available":true}},
  "capabilities":{"label_editing":true,"merging":false,"comment_posting":true,"reviewer_editing":false},
  "tracking_available":true,"warnings":["slow"],
  "prs":[{"url":"https://github.com/o/r/pull/7","host":"github.com","repository":"o/r",
          "number":18446744073709551615,"title":"Fix","relationship":"created","state":"OPEN",
          "provider_display":{"display_name":"GitHub"},"state_checked_at":1700000000.5}],
  "pr":{"number":9007199254740993,"title":"Fix it","state":"OPEN","url":"https://github.com/o/r/pull/7",
        "is_draft":false,"author":"ann","base_ref":"main","head_ref":"topic","head_sha":"abc",
        "body":"Body","checks":{"passing":1,"failing":2,"pending":3,"cancelled":4,"skipped":5,
          "total":15,"partial":true,
          "runs":[{"name":"p","bucket":"passing","url":"https://ci/p"},{"name":"f","bucket":"failing"},
                  {"name":"r","bucket":"pending"},{"name":"c","bucket":"cancelled"},
                  {"name":"s","bucket":"skipped"}]},
        "checks_supported":true,
        "comments":[{"author":"bob","body":"LGTM","created_at":"2026-01-01T00:00:00Z","url":"https://c"}],
        "comments_partial":true,
        "reviewers":[{"login":"core","kind":"team","state":"PENDING"},
                     {"login":"a","kind":"user","state":"APPROVED"},
                     {"login":"b","kind":"user","state":"COMMENTED"},
                     {"login":"c","kind":"user","state":"CHANGES_REQUESTED"},
                     {"login":"d","kind":"user","state":"DISMISSED"}],
        "labels":[{"name":"bug","color":"d73a4a","description":"Broken"}],
        "merge_state_status":"CLEAN","auto_merge":{"merge_method":"SQUASH"}}}"#;

#[test]
fn info_maps_every_field_and_sends_the_selected_url() {
    let mut harness = connected();
    harness.http.route(INFO, reply(200, FULL_INFO));
    let info = harness
        .call(|core| async move {
            core.pull_request_info("conv_a".into(), Some(PR.into()))
                .await
        })
        .unwrap();
    assert_eq!(harness.last_request().0, format!("GET {INFO}"));
    assert_eq!(harness.last_query("pr_url").as_deref(), Some(PR));
    assert_eq!(info.availability, PullRequestAvailability::Ready);
    assert_eq!(info.provider_name.as_deref(), Some("GitHub"));
    assert_eq!(info.number_prefix, "!");
    assert_eq!(info.branch.as_deref(), Some("fix"));
    assert_eq!(info.repository.as_deref(), Some("o/r"));
    assert_eq!(info.base_ref.as_deref(), Some("trunk"));
    assert_eq!(info.selected_url.as_deref(), Some(PR));
    assert!(info.tracking_available);
    assert_eq!(info.warnings, ["slow"]);
    assert!(info.capabilities.label_editing);
    assert!(!info.capabilities.merging);
    assert!(info.capabilities.comment_posting);
    assert!(!info.capabilities.reviewer_editing);

    let linked = &info.linked[0];
    assert_eq!(linked.url, PR);
    assert_eq!(linked.host, "github.com");
    assert_eq!(linked.repository, "o/r");
    assert_eq!(linked.number, u64::MAX, "a PR number survives whole");
    assert_eq!(linked.title.as_deref(), Some("Fix"));
    assert_eq!(linked.relationship, "created");
    assert_eq!(linked.provider_name.as_deref(), Some("GitHub"));
    assert_eq!(linked.status, PullRequestStatus::Open);
    assert_eq!(linked.state_checked_at, Some(1_700_000_000.5));

    let detail = info.pull_request.unwrap();
    assert_eq!(
        detail.number, 9_007_199_254_740_993,
        "above f64's whole range"
    );
    assert_eq!(detail.title, "Fix it");
    assert_eq!(detail.url, PR);
    assert_eq!(detail.status, PullRequestStatus::Open);
    assert_eq!(detail.condition, PullRequestCondition::ChecksFailing);
    assert_eq!(detail.author.as_deref(), Some("ann"));
    assert_eq!(detail.base_ref.as_deref(), Some("main"));
    assert_eq!(detail.head_ref.as_deref(), Some("topic"));
    assert_eq!(detail.head_sha.as_deref(), Some("abc"));
    assert_eq!(detail.body.as_deref(), Some("Body"));
    assert!(detail.checks_supported);
    assert!(detail.comments_partial);
    assert_eq!(detail.merge_state_status.as_deref(), Some("CLEAN"));
    assert!(detail.reports_merge_state);
    assert_eq!(detail.auto_merge_method.as_deref(), Some("SQUASH"));

    let checks = detail.checks;
    assert_eq!(
        (
            checks.passing,
            checks.failing,
            checks.pending,
            checks.cancelled,
            checks.skipped,
            checks.total
        ),
        (1, 2, 3, 4, 5, 15)
    );
    assert!(checks.partial);
    assert_eq!(
        checks.runs.iter().map(|run| run.bucket).collect::<Vec<_>>(),
        [
            CheckBucket::Passing,
            CheckBucket::Failing,
            CheckBucket::Pending,
            CheckBucket::Cancelled,
            CheckBucket::Skipped
        ]
    );
    assert_eq!(checks.runs[0].name, "p");
    assert_eq!(checks.runs[0].url.as_deref(), Some("https://ci/p"));

    let comment = &detail.comments[0];
    assert_eq!(comment.author.as_deref(), Some("bob"));
    assert_eq!(comment.body, "LGTM");
    assert_eq!(comment.created_at.as_deref(), Some("2026-01-01T00:00:00Z"));
    assert_eq!(comment.url.as_deref(), Some("https://c"));

    let reviewers = detail.reviewers.unwrap();
    assert_eq!(reviewers[0].login, "core");
    assert_eq!(reviewers[0].kind, ReviewerKind::Team);
    assert_eq!(
        reviewers
            .iter()
            .map(|reviewer| reviewer.state)
            .collect::<Vec<_>>(),
        [
            ReviewState::Pending,
            ReviewState::Approved,
            ReviewState::Commented,
            ReviewState::ChangesRequested,
            ReviewState::Dismissed
        ]
    );
    let label = &detail.labels.unwrap()[0];
    assert_eq!(label.name, "bug");
    assert_eq!(label.color.as_deref(), Some("d73a4a"));
    assert_eq!(label.description.as_deref(), Some("Broken"));
}

#[test]
fn every_core_condition_availability_and_status_maps_to_its_own_arm() {
    use core_detail::PullRequestCondition as Core;
    for (from, to) in [
        (Core::Conflict, PullRequestCondition::Conflict),
        (Core::ChecksFailing, PullRequestCondition::ChecksFailing),
        (Core::Ready, PullRequestCondition::Ready),
        (Core::ChecksRunning, PullRequestCondition::ChecksRunning),
        (Core::Open, PullRequestCondition::Open),
        (Core::Draft, PullRequestCondition::Draft),
        (Core::Unknown, PullRequestCondition::Unknown),
        (Core::Merged, PullRequestCondition::Merged),
        (Core::Closed, PullRequestCondition::Closed),
    ] {
        assert_eq!(PullRequestCondition::from(from), to);
    }

    for (from, to) in [
        (
            core_detail::PullRequestAvailability::Ready,
            PullRequestAvailability::Ready,
        ),
        (
            core_detail::PullRequestAvailability::NoPullRequest,
            PullRequestAvailability::NoPullRequest,
        ),
        (
            core_detail::PullRequestAvailability::NotAGitRepository,
            PullRequestAvailability::NotAGitRepository,
        ),
        (
            core_detail::PullRequestAvailability::HostOutdated,
            PullRequestAvailability::HostOutdated,
        ),
        (
            core_detail::PullRequestAvailability::UnsupportedRemote {
                remote_host: Some("git.x".into()),
            },
            PullRequestAvailability::UnsupportedRemote {
                remote_host: Some("git.x".into()),
            },
        ),
        (
            core_detail::PullRequestAvailability::NoCli { cli: "gh".into() },
            PullRequestAvailability::NoCli { cli: "gh".into() },
        ),
        (
            core_detail::PullRequestAvailability::RepositoryUnresolved {
                hint: Some("login".into()),
            },
            PullRequestAvailability::RepositoryUnresolved {
                hint: Some("login".into()),
            },
        ),
        (
            core_detail::PullRequestAvailability::Unavailable,
            PullRequestAvailability::Unavailable,
        ),
    ] {
        assert_eq!(PullRequestAvailability::from(from), to);
    }

    for (from, to) in [
        (
            core_stored::PullRequestStatus::Open,
            PullRequestStatus::Open,
        ),
        (
            core_stored::PullRequestStatus::Draft,
            PullRequestStatus::Draft,
        ),
        (
            core_stored::PullRequestStatus::Merged,
            PullRequestStatus::Merged,
        ),
        (
            core_stored::PullRequestStatus::Closed,
            PullRequestStatus::Closed,
        ),
        (
            core_stored::PullRequestStatus::Unknown,
            PullRequestStatus::Unknown,
        ),
    ] {
        assert_eq!(PullRequestStatus::from(from), to);
    }
}

#[test]
fn reviewer_kinds_and_merge_methods_round_trip() {
    for (ffi, core) in [
        (ReviewerKind::User, core_detail::ReviewerKind::User),
        (ReviewerKind::Team, core_detail::ReviewerKind::Team),
    ] {
        assert_eq!(ReviewerKind::from(core), ffi);
        assert_eq!(core_detail::ReviewerKind::from(ffi), core);
    }
    for (ffi, core) in [
        (MergeMethod::Merge, core_edits::MergeMethod::Merge),
        (MergeMethod::Squash, core_edits::MergeMethod::Squash),
        (MergeMethod::Rebase, core_edits::MergeMethod::Rebase),
    ] {
        assert_eq!(MergeMethod::from(core), ffi);
        assert_eq!(core_edits::MergeMethod::from(ffi), core);
    }
}

#[test]
fn a_patch_keeps_its_text_and_why_it_is_unavailable() {
    let mut harness = connected();
    let route = format!("{INFO}/diff");
    harness.http.route(
        &route,
        reply(
            200,
            r#"{"object":"session.github.pr_diff","patch":"diff --git a b"}"#,
        ),
    );
    let patch = harness
        .call(|core| async move { core.pull_request_patch("conv_a".into(), None).await })
        .unwrap();
    assert_eq!(patch.patch, "diff --git a b");
    assert_eq!(patch.unavailable, None);
    assert_eq!(harness.last_request().0, format!("GET {route}"));
    assert_eq!(harness.last_query("pr_url"), None, "the host's default PR");

    harness.http.route(
        &route,
        reply(
            200,
            r#"{"patch":"","unavailable_reason":"pr_outside_workspace"}"#,
        ),
    );
    let patch = harness
        .call(|core| async move {
            core.pull_request_patch("conv_a".into(), Some(PR.into()))
                .await
        })
        .unwrap();
    assert_eq!(patch.patch, "");
    assert!(
        patch
            .unavailable
            .unwrap()
            .contains("outside this workspace")
    );
}

#[test]
fn link_and_unlink_post_their_action_and_answer_the_info() {
    let mut harness = connected();
    let path = format!("{INFO}/prs");
    harness.http.route(&path, reply(200, FULL_INFO));
    let linked = harness
        .call(|core| async move { core.link_pull_request("conv_a".into(), PR.into()).await })
        .unwrap();
    assert_eq!(linked.selected_url.as_deref(), Some(PR));
    assert_eq!(
        harness.last_request(),
        (
            format!("POST {path}"),
            json!({"url": PR, "action": "attach"})
        )
    );
    let unlinked = harness
        .call(|core| async move { core.unlink_pull_request("conv_a".into(), PR.into()).await })
        .unwrap();
    assert_eq!(unlinked.repository.as_deref(), Some("o/r"));
    assert_eq!(
        harness.last_request(),
        (
            format!("POST {path}"),
            json!({"url": PR, "action": "remove"})
        )
    );
}

#[test]
fn labels_are_listed_and_edited() {
    let mut harness = connected();
    let path = format!("{INFO}/labels");
    harness.http.route_method(
        "GET",
        &path,
        reply(
            200,
            r#"{"data":[{"name":"a","color":"fff","description":"d"}],"has_more":true}"#,
        ),
    );
    harness.http.route_method(
        "POST",
        &path,
        reply(200, r#"{"labels":[{"name":"bug","color":"d73a4a"}]}"#),
    );
    let offered = harness
        .call(|core| async move {
            core.pull_request_repository_labels("conv_a".into(), PR.into())
                .await
        })
        .unwrap();
    assert!(offered.has_more);
    assert_eq!(offered.labels[0].name, "a");
    assert_eq!(offered.labels[0].color.as_deref(), Some("fff"));
    assert_eq!(harness.last_query("pr_url").as_deref(), Some(PR));

    let updated = harness
        .call(|core| async move {
            core.update_pull_request_labels(
                "conv_a".into(),
                PR.into(),
                vec!["bug".into()],
                vec!["old".into()],
            )
            .await
        })
        .unwrap();
    assert_eq!(updated[0].name, "bug");
    assert_eq!(
        harness.last_request(),
        (
            format!("POST {path}"),
            json!({"pr_url": PR, "add": ["bug"], "remove": ["old"]})
        )
    );
}

#[test]
fn reviewers_are_listed_and_edited_with_their_kinds_in_the_right_lists() {
    let mut harness = connected();
    let path = format!("{INFO}/reviewers");
    harness.http.route_method(
        "GET",
        &path,
        reply(
            200,
            r#"{"data":[{"login":"ann","kind":"user","name":"Ann"},{"login":"core","kind":"team"}],"has_more":true}"#,
        ),
    );
    harness.http.route_method(
        "POST",
        &path,
        reply(
            200,
            r#"{"reviewers":[{"login":"ann","kind":"user","state":"APPROVED"}]}"#,
        ),
    );
    let candidates = harness
        .call(|core| async move {
            core.pull_request_review_candidates("conv_a".into(), PR.into())
                .await
        })
        .unwrap();
    assert!(candidates.has_more);
    assert_eq!(candidates.candidates[0].login, "ann");
    assert_eq!(candidates.candidates[0].kind, ReviewerKind::User);
    assert_eq!(candidates.candidates[0].name.as_deref(), Some("Ann"));
    assert_eq!(candidates.candidates[1].kind, ReviewerKind::Team);
    assert_eq!(candidates.candidates[1].name, None);

    let reviewers = harness
        .call(|core| async move {
            core.update_pull_request_reviewers(
                "conv_a".into(),
                PR.into(),
                vec![ReviewerTarget {
                    login: "ann".into(),
                    kind: ReviewerKind::User,
                }],
                vec![ReviewerTarget {
                    login: "core".into(),
                    kind: ReviewerKind::Team,
                }],
            )
            .await
        })
        .unwrap();
    assert_eq!(reviewers[0].state, ReviewState::Approved);
    assert_eq!(
        harness.last_request(),
        (
            format!("POST {path}"),
            json!({
                "pr_url": PR,
                "add": [{"login": "ann", "kind": "user"}],
                "remove": [{"login": "core", "kind": "team"}]
            })
        )
    );
}

#[test]
fn merging_reads_the_options_and_sends_the_expected_head() {
    let mut harness = connected();
    harness.http.route(
        &format!("{INFO}/merge-options"),
        reply(200, r#"{"methods":["rebase","merge"],"default":"rebase"}"#),
    );
    harness
        .http
        .route(&format!("{INFO}/merge"), reply(200, "{}"));
    harness
        .http
        .route(&format!("{INFO}/disable-auto-merge"), reply(200, "{}"));
    let options = harness
        .call(|core| async move {
            core.pull_request_merge_options("conv_a".into(), PR.into())
                .await
        })
        .unwrap();
    assert_eq!(options.methods, [MergeMethod::Rebase, MergeMethod::Merge]);
    assert_eq!(options.default_method, Some(MergeMethod::Rebase));

    harness
        .call(|core| async move {
            core.merge_pull_request(
                "conv_a".into(),
                PR.into(),
                MergeMethod::Rebase,
                "abc".into(),
            )
            .await
        })
        .unwrap();
    assert_eq!(
        harness.last_request(),
        (
            format!("POST {INFO}/merge"),
            json!({"pr_url": PR, "merge_method": "rebase", "expected_head": "abc"})
        )
    );
    harness
        .call(|core| async move {
            core.disable_pull_request_auto_merge("conv_a".into(), PR.into())
                .await
        })
        .unwrap();
    assert_eq!(
        harness.last_request(),
        (
            format!("POST {INFO}/disable-auto-merge"),
            json!({"pr_url": PR})
        )
    );
}

#[test]
fn a_posted_comment_comes_back_as_its_record() {
    let mut harness = connected();
    let path = format!("{INFO}/comments");
    harness.http.route(
        &path,
        reply(
            200,
            r#"{"comment":{"author":"me","body":"hi","created_at":"t","url":"c"}}"#,
        ),
    );
    let comment = harness
        .call(|core| async move {
            core.post_pull_request_comment("conv_a".into(), PR.into(), "hi".into())
                .await
        })
        .unwrap();
    assert_eq!(comment.author.as_deref(), Some("me"));
    assert_eq!(comment.body, "hi");
    assert_eq!(comment.created_at.as_deref(), Some("t"));
    assert_eq!(comment.url.as_deref(), Some("c"));
    assert_eq!(
        harness.last_request(),
        (format!("POST {path}"), json!({"pr_url": PR, "body": "hi"}))
    );
}

#[test]
fn stored_pull_requests_and_panel_features_map_every_field() {
    let mut harness = connected();
    harness.http.route(
        "/v1/info",
        reply(
            200,
            r#"{"session_pull_requests":true,"features":{"workspace_content_search":false}}"#,
        ),
    );
    let features = harness
        .call(|core| async move { core.panel_features().await })
        .unwrap();
    assert_eq!(
        features,
        PanelFeatures {
            content_search: false,
            pull_requests: true
        }
    );
    assert_eq!(
        PanelFeatures::from(core_stored::PanelFeatures {
            content_search: true,
            pull_requests: false
        }),
        PanelFeatures {
            content_search: true,
            pull_requests: false
        }
    );

    harness.http.route(
        "/v1/sessions/conv_a/pull-requests",
        reply(
            200,
            r#"{"data":[{"url":"https://x/1","host":"x","repository":"o/r","number":1,"title":"T",
                "relationship":"attached","state":"MERGED","state_checked_at":12.5}],
                "has_more":false,"synced":true}"#,
        ),
    );
    let stored = harness
        .call(|core| async move { core.session_pull_requests("conv_a".into()).await })
        .unwrap();
    assert!(stored.synced);
    assert_eq!(stored.pull_requests[0].url, "https://x/1");
    assert_eq!(stored.pull_requests[0].status, PullRequestStatus::Merged);
    assert_eq!(stored.pull_requests[0].relationship, "attached");
    assert_eq!(stored.pull_requests[0].state_checked_at, Some(12.5));
}

#[test]
fn a_bad_identifier_reaches_the_host_as_an_error_and_sends_nothing() {
    let mut harness = connected();
    let sent = harness.http.lines().len();
    let error = harness
        .call(|core| async move { core.pull_request_info("../x".into(), None).await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Session { .. }), "{error:?}");
    assert_eq!(harness.http.lines().len(), sent);
}
