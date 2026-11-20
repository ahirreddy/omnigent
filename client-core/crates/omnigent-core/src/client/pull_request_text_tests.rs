//! A PR's commit activity and capabilities, and editing its title, description and
//! attachments, in the shapes main's host sends.

use futures::executor::block_on;
use serde_json::{Value, json};

use super::{PullRequestCapabilities, PullRequestInfo, TimelineEventKind};
use crate::client::SessionError;
use crate::client::pull_request_edits::{PullRequestAttachment, attachment_problem};
use crate::client::test_support::{Reply, RouteTransport, body_json, connected};

const INFO: &str = "/v1/sessions/conv_a/resources/github";
const PR: &str = "https://github.com/o/r/pull/7";

fn info(body: &Value) -> PullRequestInfo {
    PullRequestInfo::from_value(body).unwrap()
}

/// An open PR with a commit, a force push, an event of an unknown kind, and a partial history.
fn with_timeline() -> Value {
    json!({
        "object": "session.github.info", "available": true,
        "repo": {"name_with_owner": "o/r"}, "auth": {"authenticated": true},
        "pr": {
            "number": 7, "title": "Fix", "state": "OPEN", "url": PR, "head_sha": "def",
            "base_sha": "abc",
            "timeline_events": [
                {"id": "c1", "kind": "commit", "author": "ann",
                 "created_at": "2026-01-01T00:00:00Z", "url": "https://github.com/o/r/commit/1",
                 "sha": "1111111aaaa", "message": "Add the sidebar"},
                {"id": "f1", "kind": "force_push", "author": null, "created_at": null,
                 "url": null, "sha": null, "previous_sha": "2222222bbbb"},
                {"id": "x1", "kind": "renamed"}
            ],
            "timeline_partial": true
        }
    })
}

#[test]
fn commits_and_force_pushes_decode_and_unknown_kinds_are_left_out() {
    let pr = info(&with_timeline()).pull_request.unwrap();
    assert_eq!(pr.base_sha.as_deref(), Some("abc"));
    assert!(pr.timeline_partial);
    assert_eq!(pr.timeline_events.len(), 2);
    let commit = &pr.timeline_events[0];
    assert_eq!(commit.kind, TimelineEventKind::Commit);
    assert_eq!(commit.message.as_deref(), Some("Add the sidebar"));
    assert_eq!(
        pr.timeline_events[1].kind,
        TimelineEventKind::ForcePush {
            previous_sha: Some("2222222bbbb".to_owned())
        }
    );
    let mut older = with_timeline();
    older["pr"]
        .as_object_mut()
        .unwrap()
        .retain(|key, _| !key.starts_with("timeline"));
    let pr = info(&older).pull_request.unwrap();
    assert!(pr.timeline_events.is_empty() && !pr.timeline_partial);
}

#[test]
fn capabilities_decode_and_an_older_host_is_github() {
    let mut body = with_timeline();
    body["capabilities"] = json!({
        "details_editing": true, "attachment_uploads": true, "review_threads": true,
        "review_thread_replies": true, "review_thread_creation": false,
        "commit_history": true, "line_counts": false, "linked_pr_diff": true,
        "account_switching": false, "base_remote_selection": false, "merge_as_account": true
    });
    let caps = info(&body).capabilities;
    assert!(caps.details_editing && caps.attachment_uploads && caps.review_threads);
    assert!(caps.review_thread_replies && !caps.review_thread_creation);
    assert!(caps.commit_history && !caps.line_counts && caps.linked_pr_diff);
    assert!(caps.merge_as_account && !caps.account_switching && !caps.label_editing);

    let legacy = info(&with_timeline()).capabilities;
    assert_eq!(
        legacy,
        PullRequestCapabilities {
            line_counts: true,
            linked_pr_diff: true,
            account_switching: true,
            base_remote_selection: true,
            ..PullRequestCapabilities::default()
        }
    );
}

#[test]
fn editing_the_details_sends_only_what_changed_and_answers_the_stored_text() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "POST",
        &format!("{INFO}/details"),
        vec![
            Reply::json(
                200,
                r#"{"object":"session.github.pr_details","title":"New","body":"Body"}"#,
            ),
            Reply::json(
                200,
                r#"{"object":"session.github.pr_details","title":"New","body":" "}"#,
            ),
            Reply::json(422, r#"{"detail":"Cannot update the pull request"}"#),
        ],
    );
    let core = connected(transport);
    let text =
        block_on(core.update_pull_request_details("conv_a", PR, Some(" New "), None)).unwrap();
    assert_eq!(text.title, "New");
    assert_eq!(text.body.as_deref(), Some("Body"));
    let cleared = block_on(core.update_pull_request_details("conv_a", PR, None, Some(""))).unwrap();
    assert_eq!(cleared.body, None, "a blank description is none");
    assert_eq!(
        block_on(core.update_pull_request_details("conv_a", PR, None, Some("x"))),
        Err(SessionError::Rejected {
            status: 422,
            message: "Cannot update the pull request".to_owned()
        })
    );
    let bodies: Vec<Value> = core.transport().writes().iter().map(body_json).collect();
    assert_eq!(bodies[0], json!({"pr_url": PR, "title": "New"}));
    assert_eq!(bodies[1], json!({"pr_url": PR, "body": ""}));
    for (title, body) in [(Some("  "), None), (None, None)] {
        assert!(matches!(
            block_on(core.update_pull_request_details("conv_a", PR, title, body)),
            Err(SessionError::InvalidInput { .. })
        ));
    }
}

#[test]
fn an_attachment_uploads_as_multipart_and_answers_where_it_lives() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("POST"),
        &format!("{INFO}/attachments"),
        None,
        Reply::json(
            200,
            r#"{"object":"session.github.pr_attachment","url":"https://example.test/a.png",
                "name":"a.png","content_type":"image/png"}"#,
        ),
    );
    let core = connected(transport);
    let attachment = block_on(core.upload_pull_request_attachment(
        "conv_a",
        PR,
        "shot \"1\".png",
        "image/png",
        b"PNGDATA",
        "Bound",
    ))
    .unwrap();
    assert_eq!(attachment.url, "https://example.test/a.png");
    let writes = core.transport().writes();
    let request = &writes[0];
    let content_type = request
        .headers
        .iter()
        .find(|header| header.name == "Content-Type")
        .map(|header| header.value.clone());
    assert_eq!(
        content_type.as_deref(),
        Some("multipart/form-data; boundary=Bound")
    );
    let body = String::from_utf8(request.body.clone().unwrap()).unwrap();
    assert!(body.contains("name=\"pr_url\""));
    assert!(body.contains(PR));
    assert!(body.contains("name=\"file\"; filename=\"shot _1_.png\""));
    assert!(body.contains("Content-Type: image/png\r\n\r\nPNGDATA\r\n"));
    assert!(body.ends_with("--Bound--\r\n"));

    let too_big = vec![0_u8; 11 * 1024 * 1024];
    assert!(matches!(
        block_on(core.upload_pull_request_attachment(
            "conv_a",
            PR,
            "big.png",
            "image/png",
            &too_big,
            "Bound"
        )),
        Err(SessionError::InvalidInput { .. })
    ));
}

#[test]
fn attachments_are_checked_and_embedded_as_the_web_does() {
    assert_eq!(
        attachment_problem("a.pdf", "application/pdf", 1).as_deref(),
        Some("Only images and videos can be attached.")
    );
    assert_eq!(
        attachment_problem("", "image/png", 10 * 1024 * 1024 + 1).as_deref(),
        Some("Couldn\u{2019}t attach the file: an image can be at most 10 MB.")
    );
    assert!(attachment_problem("clip.mov", "video/quicktime", 70 * 1024 * 1024).is_none());
    let image = PullRequestAttachment {
        url: "https://example.test/i".to_owned(),
        name: "i.png".to_owned(),
        content_type: "image/png".to_owned(),
    };
    assert_eq!(
        image.markdown("Screen [shot].png"),
        "![Screen shot](https://example.test/i)"
    );
    assert_eq!(image.markdown(".png"), "![image](https://example.test/i)");
    let video = PullRequestAttachment {
        content_type: "video/mp4".to_owned(),
        ..image
    };
    assert_eq!(video.markdown("clip.mp4"), "https://example.test/i");
}

#[test]
fn accounts_and_the_providers_request_name_decode_from_auth_or_the_legacy_fields() {
    let mut body = with_timeline();
    body["auth"] = json!({
        "authenticated": true,
        "selected_account": "ann",
        "accounts": [{"login": "ann", "active": false}, {"login": "bot", "active": true}],
    });
    body["provider_display"] = json!({"display_name": "GitLab", "request_name": "merge request"});
    let decoded = info(&body);
    let logins: Vec<_> = decoded
        .accounts
        .iter()
        .map(|account| account.login.as_str())
        .collect();
    assert_eq!(logins, ["ann", "bot"]);
    assert!(
        decoded
            .accounts
            .iter()
            .any(|account| account.active && account.login == "bot")
    );
    assert_eq!(decoded.selected_account.as_deref(), Some("ann"));
    assert_eq!(decoded.request_name.as_deref(), Some("merge request"));

    let mut legacy = with_timeline();
    legacy["auth"] = Value::Null;
    legacy["accounts"] = json!([{"login": "old", "active": true}]);
    legacy["selected_account"] = json!("old");
    let decoded = info(&legacy);
    assert_eq!(decoded.accounts.len(), 1);
    assert_eq!(decoded.selected_account.as_deref(), Some("old"));
    assert_eq!(decoded.request_name, None);

    let bare = info(&with_timeline());
    assert!(bare.accounts.is_empty() && bare.selected_account.is_none());
}

#[test]
fn merging_as_an_account_takes_the_merge_as_route_and_says_when_it_is_missing() {
    use crate::client::pull_request_edits::{MERGE_AS_UNSUPPORTED, MergeMethod};
    let transport = RouteTransport::local();
    transport.enqueue(
        "POST",
        &format!("{INFO}/merge-as"),
        vec![
            Reply::json(200, "{}"),
            Reply::json(404, r#"{"detail":"Not Found"}"#),
            Reply::json(400, r#"{"detail":"unknown fs write op: github_merge_as"}"#),
            Reply::json(422, r#"{"detail":"bot can't merge"}"#),
        ],
    );
    let core = connected(transport);
    let merge = |account| {
        block_on(core.merge_pull_request_as("conv_a", PR, MergeMethod::Squash, "abc", account))
    };
    merge(Some("bot")).unwrap();
    for _ in 0..2 {
        assert!(matches!(
            merge(Some("bot")),
            Err(SessionError::Rejected { message, .. }) if message == MERGE_AS_UNSUPPORTED
        ));
    }
    assert!(
        matches!(
            merge(Some("bot")),
            Err(SessionError::Rejected { message, .. }) if message != MERGE_AS_UNSUPPORTED
        ),
        "a host's refusal keeps its reason"
    );
    let writes = core.transport().writes();
    assert!(writes[0].url.ends_with("/merge-as"));
    assert_eq!(
        body_json(&writes[0]),
        json!({"pr_url": PR, "merge_method": "squash", "expected_head": "abc", "account": "bot"})
    );
}

#[test]
fn choosing_an_account_saves_it_for_the_pr_and_answers_the_info_read_as_it() {
    let transport = RouteTransport::local();
    let mut answer = with_timeline();
    answer["auth"]["selected_account"] = json!("bot");
    transport.respond(
        Some("POST"),
        &format!("{INFO}/preferences"),
        None,
        Reply::json(200, answer.to_string()),
    );
    let core = connected(transport);
    let info = block_on(core.set_pull_request_account("conv_a", Some(PR), "bot")).unwrap();
    assert_eq!(info.selected_account.as_deref(), Some("bot"));
    block_on(core.set_pull_request_account("conv_a", None, "")).unwrap();
    let bodies: Vec<Value> = core.transport().writes().iter().map(body_json).collect();
    assert_eq!(bodies[0], json!({"account": "bot", "pr_url": PR}));
    assert_eq!(bodies[1], json!({"account": ""}));
}
