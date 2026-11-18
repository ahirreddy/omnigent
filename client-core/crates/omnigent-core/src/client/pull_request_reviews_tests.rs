//! Review threads in the shapes main's host pages them, replies and new threads.

use futures::executor::block_on;
use serde_json::{Value, json};

use super::reviews::{
    MAX_REVIEW_COMMENT_CHARACTERS, ReviewAnchor, ReviewSide, decode_threads_page,
    review_comment_problem,
};
use crate::client::SessionError;
use crate::client::test_support::{Reply, RouteTransport, body_json, connected, query_value};

const THREADS: &str = "/v1/sessions/conv_a/resources/github/review-threads";
const PR: &str = "https://github.com/o/r/pull/7";

/// One line thread with a page of comments, one outdated range, one file thread.
fn page() -> Value {
    json!({
        "data": [
            {"id": "PRRT_1", "path": "src/a.rs", "side": "RIGHT", "line": 12, "start_line": null,
             "subject_type": "LINE", "resolved": false, "outdated": false, "can_reply": true,
             "diff_hunk": "@@ -10,3 +10,3 @@",
             "comments": {"data": [
                {"id": "c1", "author": "ann", "body": "Why?", "created_at": "2026-01-01T00:00:00Z",
                 "url": "https://github.com/o/r/pull/7#discussion_r1"},
                {"id": "c2", "author": null, "body": "", "created_at": null, "url": null,
                 "minimized": true}],
              "has_more": true, "next_cursor": "older"}},
            {"id": "PRRT_2", "path": "src/a.rs", "side": "LEFT", "line": null,
             "start_line": null, "start_side": "LEFT", "original_line": 4,
             "original_start_line": 2, "subject_type": "LINE", "resolved": true,
             "outdated": true, "can_reply": false, "diff_hunk": "@@ -1,4 +1,4 @@",
             "comments": {"data": [], "has_more": false, "next_cursor": null}},
            {"id": "PRRT_3", "path": "README.md", "side": "RIGHT", "line": null,
             "subject_type": "FILE", "resolved": false, "outdated": false, "can_reply": true,
             "diff_hunk": "", "comments": {"data": [], "has_more": false,
             "next_cursor": null, "warning": "Some replies are unavailable."}}
        ],
        "has_more": true, "next_cursor": "page2", "head_sha": "head1", "base_sha": "base1",
        "warning": null
    })
}

#[test]
fn a_page_of_threads_decodes_lines_ranges_files_and_history() {
    let page = decode_threads_page(&page()).unwrap();
    assert_eq!(
        (page.head_sha.as_str(), page.base_sha.as_str()),
        ("head1", "base1")
    );
    assert!(page.has_more && page.next_cursor.as_deref() == Some("page2"));
    let line = &page.threads[0];
    assert_eq!(line.side, Some(ReviewSide::Right));
    assert_eq!(line.line, Some(12));
    assert!(line.can_reply && !line.resolved && !line.on_file);
    assert_eq!(line.comments.comments.len(), 2);
    assert!(line.comments.comments[1].minimized);
    assert_eq!(line.comments.next_cursor.as_deref(), Some("older"));
    let outdated = &page.threads[1];
    assert!(outdated.outdated && outdated.resolved && outdated.line.is_none());
    assert_eq!(
        (outdated.original_start_line, outdated.original_line),
        (Some(2), Some(4))
    );
    let file = &page.threads[2];
    assert!(file.on_file);
    assert_eq!(
        file.comments.warning.as_deref(),
        Some("Some replies are unavailable.")
    );
    assert!(decode_threads_page(&json!({"data": [{"path": "x"}]})).is_err());
}

#[test]
fn threads_page_at_their_revision_and_older_comments_page_by_thread() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "GET",
        THREADS,
        vec![
            Reply::json(200, page().to_string()),
            Reply::json(
                200,
                r#"{"data":[],"has_more":false,"next_cursor":null,"head_sha":"head1","base_sha":"base1"}"#,
            ),
        ],
    );
    transport.respond(
        Some("GET"),
        &format!("{THREADS}/PRRT_1/comments"),
        Some("older"),
        Reply::json(
            200,
            r#"{"data":[{"id":"c0","author":"bob","body":"First","created_at":null,"url":null}],
                "has_more":false,"next_cursor":null}"#,
        ),
    );
    let core = connected(transport);
    let first = block_on(core.pull_request_review_threads("conv_a", PR, None)).unwrap();
    let cursor = first.next_cursor.clone().unwrap();
    block_on(core.pull_request_review_threads(
        "conv_a",
        PR,
        Some((&cursor, &first.head_sha, &first.base_sha)),
    ))
    .unwrap();
    let older = block_on(core.review_thread_comments("conv_a", PR, "PRRT_1", "older")).unwrap();
    assert_eq!(older.comments[0].body, "First");
    let requests = core.transport().taken();
    let reads: Vec<_> = requests
        .iter()
        .filter(|r| r.url.contains(THREADS))
        .collect();
    assert_eq!(query_value(reads[0], "pr_url").as_deref(), Some(PR));
    assert_eq!(query_value(reads[0], "after"), None);
    assert_eq!(query_value(reads[1], "after").as_deref(), Some("page2"));
    assert_eq!(query_value(reads[1], "head_sha").as_deref(), Some("head1"));
    assert_eq!(query_value(reads[1], "base_sha").as_deref(), Some("base1"));
    assert_eq!(query_value(reads[2], "after").as_deref(), Some("older"));
}

#[test]
fn a_reply_and_a_new_thread_post_their_text_and_anchor() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("POST"),
        &format!("{THREADS}/PRRT_1/replies"),
        None,
        Reply::json(
            200,
            r#"{"comment":{"id":"c9","author":"me","body":"Fixed","created_at":null,"url":null}}"#,
        ),
    );
    transport.respond(
        Some("POST"),
        THREADS,
        None,
        Reply::json(
            200,
            r#"{"thread":{"id":"PRRT_9","path":"src/a.rs","side":"RIGHT","line":14,
                "start_line":12,"subject_type":"LINE","resolved":false,"outdated":false,
                "can_reply":true,"diff_hunk":"","comments":{"data":[{"id":"c10","body":"Nit"}],
                "has_more":false,"next_cursor":null}}}"#,
        ),
    );
    let core = connected(transport);
    let reply = block_on(core.reply_to_review_thread("conv_a", PR, "PRRT_1", "Fixed")).unwrap();
    assert_eq!(reply.id, "c9");
    let anchor = ReviewAnchor {
        path: "src/a.rs".to_owned(),
        side: ReviewSide::Right,
        line: 14,
        start_line: Some(12),
        head_sha: "head1".to_owned(),
        base_sha: "base1".to_owned(),
    };
    let thread = block_on(core.create_review_thread("conv_a", PR, "Nit", &anchor)).unwrap();
    assert_eq!(thread.start_line, Some(12));
    let bodies: Vec<Value> = core.transport().writes().iter().map(body_json).collect();
    assert_eq!(bodies[0], json!({"pr_url": PR, "body": "Fixed"}));
    assert_eq!(
        bodies[1],
        json!({"pr_url": PR, "body": "Nit", "anchor": {"path": "src/a.rs", "side": "RIGHT",
            "line": 14, "start_line": 12, "head_sha": "head1", "base_sha": "base1"}})
    );
}

#[test]
fn blank_and_too_long_comments_never_leave() {
    let core = connected(RouteTransport::local());
    assert!(matches!(
        block_on(core.reply_to_review_thread("conv_a", PR, "PRRT_1", "  ")),
        Err(SessionError::InvalidInput { .. })
    ));
    let long = "é".repeat(MAX_REVIEW_COMMENT_CHARACTERS + 1);
    assert!(review_comment_problem(&long).is_some());
    assert!(review_comment_problem(&"é".repeat(MAX_REVIEW_COMMENT_CHARACTERS)).is_none());
    for id in ["", "PRRT=1", "a/b"] {
        assert!(matches!(
            block_on(core.review_thread_comments("conv_a", PR, id, "x")),
            Err(SessionError::InvalidIdentifier { .. })
        ));
    }
    let sent = core.transport().taken();
    assert_eq!(
        sent.iter()
            .filter(|request| request.url.contains("review-threads"))
            .count(),
        0,
        "nothing was sent"
    );
}
