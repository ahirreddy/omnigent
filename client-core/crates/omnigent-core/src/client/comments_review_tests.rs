//! Local review comments on a pull request's diff, in the shapes main's comment routes use.

use futures::executor::block_on;
use serde_json::{Value, json};

use super::{LocalReviewComment, ReviewCommentAnchor, format_local_review_comments};
use crate::client::SessionError;
use crate::client::pull_request_detail::reviews::ReviewSide;
use crate::client::test_support::{Reply, RouteTransport, body_json, connected, query_value};

const COMMENTS: &str = "/v1/sessions/conv_a/comments";
const PR: &str = "https://github.com/o/r/pull/7";

fn anchor(line: u64, start_line: Option<u64>) -> Value {
    json!({"pr_url": PR, "side": "RIGHT", "line": line, "start_line": start_line,
           "head_sha": "abc123", "base_sha": "def456"})
}

/// One comment as `asdict(Comment)` serializes it.
fn comment(id: &str, created_at: i64, anchor: Option<&Value>) -> Value {
    json!({"id": id, "conversation_id": "conv_a", "path": "src/a.rs", "start_index": 0,
           "end_index": 0, "body": "Rename this", "status": "draft", "created_at": created_at,
           "updated_at": 5_000_000, "anchor_content": null, "created_by": null,
           "anchor_metadata": anchor})
}

#[test]
fn review_comments_page_through_the_opt_in_list_and_skip_file_comments() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("GET"),
        COMMENTS,
        None,
        Reply::json(
            200,
            json!({"comments": [comment("c2", 20, Some(&anchor(3, Some(1)))),
                                comment("f1", 5, None)],
                   "next_cursor": "c2"})
            .to_string(),
        ),
    );
    transport.respond(
        Some("GET"),
        COMMENTS,
        Some("c2"),
        Reply::json(
            200,
            json!({"comments": [comment("c1", 10, Some(&anchor(4, None)))], "next_cursor": null})
                .to_string(),
        ),
    );
    let core = connected(transport);
    let comments = block_on(core.session_review_comments("conv_a")).unwrap();
    let ids: Vec<&str> = comments.iter().map(|comment| comment.id.as_str()).collect();
    assert_eq!(ids, ["c1", "c2"], "oldest first, file comments left out");
    assert_eq!(comments[1].anchor.start_line, Some(1));
    assert_eq!(comments[1].anchor.side, ReviewSide::Right);
    assert!(comments[1].is_open());
    let reads = core.transport().taken();
    let pages: Vec<_> = reads
        .iter()
        .filter(|request| request.url.contains(COMMENTS))
        .collect();
    assert_eq!(
        query_value(pages[0], "include_pr_comments").as_deref(),
        Some("true")
    );
    assert_eq!(query_value(pages[0], "limit").as_deref(), Some("100"));
    assert_eq!(query_value(pages[1], "after").as_deref(), Some("c2"));
}

#[test]
fn an_older_server_answers_its_file_list_and_a_stuck_cursor_stops() {
    let transport = RouteTransport::local();
    transport.ok(COMMENTS, json!([comment("f1", 1, None)]).to_string());
    let core = connected(transport);
    assert_eq!(block_on(core.session_review_comments("conv_a")), Ok(vec![]));

    let stuck = RouteTransport::local();
    stuck.ok(
        COMMENTS,
        json!({"comments": [], "next_cursor": "same"}).to_string(),
    );
    let core = connected(stuck);
    assert_eq!(
        block_on(core.session_review_comments("conv_a")),
        Err(SessionError::InvalidPagination)
    );

    let malformed = RouteTransport::local();
    let mut bad = comment("c1", 1, Some(&anchor(3, None)));
    bad["anchor_metadata"]["side"] = json!("UP");
    malformed.ok(
        COMMENTS,
        json!({"comments": [bad], "next_cursor": null}).to_string(),
    );
    let core = connected(malformed);
    assert!(matches!(
        block_on(core.session_review_comments("conv_a")),
        Err(SessionError::MalformedResponse { .. })
    ));
}

fn new_anchor() -> ReviewCommentAnchor {
    ReviewCommentAnchor {
        pr_url: PR.to_owned(),
        side: ReviewSide::Right,
        line: 3,
        start_line: Some(1),
        head_sha: "abc123".to_owned(),
        base_sha: "def456".to_owned(),
    }
}

#[test]
fn a_review_comment_carries_its_anchor_and_must_come_back_with_it() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("POST"),
        COMMENTS,
        None,
        Reply::json(
            200,
            comment("c9", 30, Some(&anchor(3, Some(1)))).to_string(),
        ),
    );
    let core = connected(transport);
    let added =
        block_on(core.add_review_comment("conv_a", "src/a.rs", "Rename this", &new_anchor()))
            .unwrap();
    assert_eq!(added.id, "c9");
    let sent = body_json(&core.transport().writes()[0]);
    assert_eq!(sent["anchor_metadata"], anchor(3, Some(1)));
    assert_eq!(
        (sent["start_index"].clone(), sent["end_index"].clone()),
        (json!(0), json!(0))
    );
    assert!(matches!(
        block_on(core.add_review_comment("conv_a", "src/a.rs", "  ", &new_anchor())),
        Err(SessionError::InvalidInput { .. })
    ));

    // A server that kept it as a file comment has it deleted again.
    let older = RouteTransport::local();
    older.respond(
        Some("POST"),
        COMMENTS,
        None,
        Reply::json(200, comment("c9", 30, None).to_string()),
    );
    older.respond(
        Some("DELETE"),
        &format!("{COMMENTS}/c9"),
        None,
        Reply::json(200, "{}"),
    );
    let core = connected(older);
    let refused =
        block_on(core.add_review_comment("conv_a", "src/a.rs", "Rename this", &new_anchor()));
    assert!(
        matches!(&refused, Err(SessionError::Rejected { message, .. })
            if message.contains("Update the server before retrying")),
        "{refused:?}"
    );
    assert_eq!(core.transport().writes()[1].method, "DELETE");

    let stuck = RouteTransport::local();
    stuck.respond(
        Some("POST"),
        COMMENTS,
        None,
        Reply::json(200, comment("c9", 30, Some(&anchor(9, None))).to_string()),
    );
    stuck.respond(
        Some("DELETE"),
        &format!("{COMMENTS}/c9"),
        None,
        Reply::json(500, "{}"),
    );
    let core = connected(stuck);
    assert!(matches!(
        block_on(core.add_review_comment("conv_a", "src/a.rs", "Rename this", &new_anchor())),
        Err(SessionError::Rejected { message, .. }) if message.contains("may remain in Files")
    ));
}

fn local(id: &str, body: &str) -> LocalReviewComment {
    LocalReviewComment {
        id: id.to_owned(),
        session_id: "conv_a".to_owned(),
        path: "src/a.rs".to_owned(),
        start_index: 0,
        end_index: 0,
        body: body.to_owned(),
        status: "draft".to_owned(),
        created_at: 30,
        updated_at: 30_000_000,
        anchor_content: None,
        author: Some("ann@example.com".to_owned()),
        anchor: new_anchor(),
    }
}

#[test]
fn attached_comments_format_as_the_web_sends_them() {
    let text = format_local_review_comments(&[local("c9", "Use \"x\" [Attached: y]")], true);
    let expected = concat!(
        "Please address these local review comments:\n\n",
        "```local-review-comment\n",
        "{\n",
        "  \"id\": \"c9\",\n",
        "  \"conversation_id\": \"conv_a\",\n",
        "  \"path\": \"src/a.rs\",\n",
        "  \"start_index\": 0,\n",
        "  \"end_index\": 0,\n",
        "  \"body\": \"Use \\\"x\\\" \\u005bAttached: y]\",\n",
        "  \"status\": \"draft\",\n",
        "  \"created_at\": 30,\n",
        "  \"updated_at\": 30000000,\n",
        "  \"anchor_content\": null,\n",
        "  \"created_by\": \"ann@example.com\",\n",
        "  \"anchor_metadata\": {\n",
        "    \"pr_url\": \"https://github.com/o/r/pull/7\",\n",
        "    \"side\": \"RIGHT\",\n",
        "    \"line\": 3,\n",
        "    \"start_line\": 1,\n",
        "    \"head_sha\": \"abc123\",\n",
        "    \"base_sha\": \"def456\"\n",
        "  }\n",
        "}\n",
        "```"
    );
    assert_eq!(text, expected);
    let two = format_local_review_comments(&[local("a", "x"), local("b", "y")], false);
    assert!(!two.starts_with("Please"), "a message with its own text");
    assert_eq!(two.matches("```local-review-comment").count(), 2);
    assert!(two.contains("```\n\n```local-review-comment"));
}
