//! The Changes tab's reads and local review comments over the fake host: each record's fields
//! and the request each read sends.

use serde_json::json;

use crate::pull_request_detail::changes::{
    PullRequestCommits, PullRequestFileStatus, pull_request_commits_limit,
};
use crate::pull_request_detail::reviews::ReviewSide;
use crate::review_comments::{
    LocalReviewComment, ReviewCommentAnchor, format_local_review_comments,
};
use crate::test_support::{connected, json as reply};

const GITHUB: &str = "/v1/sessions/conv_a/resources/github";
const PR: &str = "https://github.com/o/r/pull/7";

#[test]
fn changes_map_every_field_and_pin_the_revision() {
    let mut harness = connected();
    harness.http.route(
        &format!("{GITHUB}/changes"),
        reply(
            200,
            r#"{"object":"list","data":[
              {"path":"b.rs","name":"b.rs","status":"renamed","lines_added":1,"lines_removed":2,
               "previous_path":"a.rs"},
              {"path":"c.rs","status":"created"},{"path":"d.rs","status":"deleted"},
              {"path":"e.rs","status":"modified"}],
              "has_more":true,"warning":"Cut","total_count":9,"head_sha":"h","base_sha":"b"}"#,
        ),
    );
    let changes = harness
        .call(|core| async move {
            core.pull_request_changes(
                "conv_a".into(),
                Some(PR.into()),
                Some("b".into()),
                Some("h".into()),
            )
            .await
        })
        .unwrap();
    assert_eq!(harness.last_query("base_sha").as_deref(), Some("b"));
    assert_eq!(harness.last_query("head_sha").as_deref(), Some("h"));
    assert!(changes.available && changes.has_more);
    assert_eq!(
        (changes.total_count, changes.warning.as_deref()),
        (Some(9), Some("Cut"))
    );
    assert_eq!(
        (changes.head_sha.as_deref(), changes.base_sha.as_deref()),
        (Some("h"), Some("b"))
    );
    let file = &changes.files[0];
    assert_eq!(file.status, PullRequestFileStatus::Renamed);
    assert_eq!((file.lines_added, file.lines_removed), (Some(1), Some(2)));
    assert_eq!(file.previous_path.as_deref(), Some("a.rs"));
    let statuses: Vec<_> = changes.files.iter().map(|file| file.status).collect();
    assert_eq!(
        statuses[1..],
        [
            PullRequestFileStatus::Created,
            PullRequestFileStatus::Deleted,
            PullRequestFileStatus::Modified
        ]
    );

    harness.http.route(
        &format!("{GITHUB}/diff"),
        reply(
            200,
            r#"{"object":"session.github.pr_diff","patch":"p","head_sha":"h","base_sha":"b"}"#,
        ),
    );
    let patch = harness
        .call(|core| async move {
            core.pull_request_patch("conv_a".into(), Some(PR.into()), None, Some("h".into()))
                .await
        })
        .unwrap();
    assert_eq!(
        harness.last_query("head_sha"),
        None,
        "a half revision is not pinned"
    );
    assert_eq!(
        (patch.head_sha.as_deref(), patch.base_sha.as_deref()),
        (Some("h"), Some("b"))
    );
}

#[test]
fn file_contents_commits_and_compares_map_their_answers() {
    let mut harness = connected();
    harness.http.route(
        &format!("{GITHUB}/diff/dir/a.rs"),
        reply(
            200,
            r#"{"object":"session.github.file_diff","path":"dir/a.rs","before":null,"after":"x"}"#,
        ),
    );
    let contents = harness
        .call(|core| async move {
            core.pull_request_file_contents(
                "conv_a".into(),
                "dir/a.rs".into(),
                None,
                Some(PR.into()),
                None,
                Some("b".into()),
                Some("h".into()),
            )
            .await
        })
        .unwrap();
    assert_eq!(
        (contents.before, contents.after.as_deref()),
        (None, Some("x"))
    );
    assert_eq!(harness.last_query("head_sha").as_deref(), Some("h"));

    harness.http.route(
        &format!("{GITHUB}/commits"),
        reply(
            200,
            r#"{"object":"list","data":[{"sha":"c1","title":"One","author":"Ann",
              "date":"2026-01-01T00:00:00Z","head_of":[{"number":4,"url":null,"state":"OPEN"}]}],
              "has_more":false}"#,
        ),
    );
    let commits = harness
        .call(|core| async move {
            core.pull_request_commits("conv_a".into(), PR.into(), "h".into())
                .await
        })
        .unwrap()
        .unwrap();
    let PullRequestCommits { commits, has_more } = commits;
    assert!(!has_more);
    assert_eq!(commits[0].head_of[0].number, 4);
    assert_eq!(commits[0].author.as_deref(), Some("Ann"));
    assert_eq!(pull_request_commits_limit(), 250);

    harness.http.route(
        &format!("{GITHUB}/commit-diff"),
        reply(404, r#"{"detail":"Not Found"}"#),
    );
    let missing = harness
        .call(|core| async move {
            core.pull_request_commit_diff("conv_a".into(), PR.into(), "c1".into())
                .await
        })
        .unwrap();
    assert_eq!(missing, None);
    harness.http.route(
        &format!("{GITHUB}/compare-diff"),
        reply(200, r#"{"object":"session.github.pr_diff","patch":"q"}"#),
    );
    let since = harness
        .call(|core| async move {
            core.pull_request_compare_diff("conv_a".into(), PR.into(), "c1".into(), "h".into())
                .await
        })
        .unwrap();
    assert_eq!(since.patch, "q");
    assert_eq!(harness.last_query("from_sha").as_deref(), Some("c1"));
}

fn anchor() -> ReviewCommentAnchor {
    ReviewCommentAnchor {
        pr_url: PR.into(),
        side: ReviewSide::Left,
        line: 4,
        start_line: None,
        head_sha: "aa".into(),
        base_sha: "bb".into(),
    }
}

#[test]
fn review_comments_round_trip_their_anchor_and_format_for_the_composer() {
    let mut harness = connected();
    let stored = json!({"id": "c1", "conversation_id": "conv_a", "path": "a.rs",
        "start_index": 0, "end_index": 0, "body": "Why?", "status": "addressed",
        "created_at": 7, "updated_at": 8, "anchor_content": null, "created_by": "ann",
        "anchor_metadata": {"pr_url": PR, "side": "LEFT", "line": 4, "start_line": null,
                            "head_sha": "aa", "base_sha": "bb"}});
    harness.http.route(
        "/v1/sessions/conv_a/comments",
        reply(
            200,
            &json!({"comments": [stored], "next_cursor": null}).to_string(),
        ),
    );
    let comments = harness
        .call(|core| async move { core.session_review_comments("conv_a".into()).await })
        .unwrap();
    let LocalReviewComment {
        status,
        author,
        anchor: listed,
        ..
    } = comments[0].clone();
    assert_eq!(
        (status.as_str(), author.as_deref()),
        ("addressed", Some("ann"))
    );
    assert_eq!(listed, anchor());

    harness.http.route_method(
        "POST",
        "/v1/sessions/conv_a/comments",
        reply(200, &stored.to_string()),
    );
    let added = harness
        .call(|core| async move {
            core.add_review_comment("conv_a".into(), "a.rs".into(), "Why?".into(), anchor())
                .await
        })
        .unwrap();
    assert_eq!(added.id, "c1");
    let (line, body) = harness.last_request();
    assert_eq!(line, "POST /v1/sessions/conv_a/comments");
    assert_eq!(body["anchor_metadata"]["side"], "LEFT");

    let text = format_local_review_comments(vec![added], false);
    assert!(text.starts_with("```local-review-comment\n{\n  \"id\": \"c1\""));
    assert!(text.contains("\"side\": \"LEFT\""));
}
