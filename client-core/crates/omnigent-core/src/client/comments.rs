//! File review comments, local review comments on pull request diffs, and the Inbox's comment
//! side.
//!
//! `GET /v1/sessions/{id}/comments` lists a session's comments on workspace files; with
//! `include_pr_comments` it pages every comment, those on a pull request's diff carrying
//! `anchor_metadata`. The Inbox shows the open file comments other people left that the caller
//! has not seen, as the web collects them (`collectCommentInboxItems`).

use std::collections::BTreeSet;

use serde_json::{Map, Value, json};

use super::events::MessageSent;
use super::json::{as_object, opt_array, opt_object, opt_str, opt_u64, req_str};
use super::pull_request_detail::reviews::ReviewSide;
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// One comment anchored to a range of a workspace file.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FileComment {
    /// Id.
    pub id: String,
    /// The session it belongs to.
    pub session_id: String,
    /// File path relative to the workspace root.
    pub path: String,
    /// The comment.
    pub body: String,
    /// Open (`draft`), not yet addressed.
    pub is_open: bool,
    /// The commented text when it was left.
    pub anchor: Option<String>,
    /// Where the commented range starts: a 0-based character (code point) offset in the file.
    pub start_index: Option<u64>,
    /// Who left it; `None` in single-user mode and for legacy comments.
    pub author: Option<String>,
    /// Created, Unix seconds.
    pub created_at: i64,
    /// Last change, Unix microseconds; orders comments left in the same second.
    pub updated_at_micros: u64,
}

/// The comments the Inbox lists: open, by someone other than `viewer_id`, unseen; newest first.
///
/// Unauthored comments are never listed, so a single-user server's own comments are not echoed
/// back.
#[must_use]
pub fn comment_inbox(
    comments: &[FileComment],
    seen_ids: &BTreeSet<String>,
    viewer_id: Option<&str>,
) -> Vec<FileComment> {
    let mut items: Vec<FileComment> = comments
        .iter()
        .filter(|comment| comment.is_open && !seen_ids.contains(&comment.id))
        .filter(|comment| {
            comment
                .author
                .as_deref()
                .is_some_and(|author| Some(author) != viewer_id)
        })
        .cloned()
        .collect();
    items.sort_by(|left, right| {
        right
            .created_at
            .cmp(&left.created_at)
            .then(right.updated_at_micros.cmp(&left.updated_at_micros))
    });
    items
}

/// The 1-based line of `text` holding the character (code point) at `offset`, as a comment's
/// `start_index` counts; `None` past the end of `text`.
#[must_use]
pub fn line_at_character(text: &str, offset: u64) -> Option<u64> {
    let mut line = 1_u64;
    let mut characters = text.chars();
    for _ in 0..offset {
        if characters.next()? == '\n' {
            line += 1;
        }
    }
    Some(line)
}

/// The 0-based character (code point) range of `text`'s 1-based `line`, without its line
/// break, as a comment's `start_index` and `end_index` count; `None` past the last line.
#[must_use]
pub fn line_character_range(text: &str, line: u64) -> Option<(u64, u64)> {
    let mut start = 0_u64;
    for (number, segment) in (1_u64..).zip(text.split('\n')) {
        let end = start + segment.chars().fold(0_u64, |count, _| count + 1);
        if number == line {
            return Some((start, end));
        }
        start = end + 1;
    }
    None
}

/// A new comment on a range of a workspace file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewFileComment {
    /// File path relative to the workspace root.
    pub path: String,
    /// The comment.
    pub body: String,
    /// Where the range starts: a 0-based character (code point) offset in the file.
    pub start_index: u64,
    /// Where it ends, exclusive.
    pub end_index: u64,
    /// The commented text.
    pub anchor: Option<String>,
}

/// The comments on `path`, open and sent, in file order, each with the 1-based line it starts on.
///
/// The line is `None` when the comment has no position or its position is past the end of
/// `text`. An open comment whose text moved follows its anchor, as the web remaps it.
#[must_use]
pub fn file_comment_lines(
    comments: &[FileComment],
    path: &str,
    text: &str,
) -> Vec<(Option<u64>, FileComment)> {
    let mut lines: Vec<(Option<u64>, FileComment)> = comments
        .iter()
        .filter(|comment| comment.path == path)
        .map(|comment| {
            let start = if comment.is_open {
                anchored_start(comment, text)
            } else {
                comment.start_index
            };
            let line = start.and_then(|start| line_at_character(text, start));
            (line, comment.clone())
        })
        .collect();
    lines.sort_by_key(|(line, comment)| (line.is_none(), *line, comment.created_at));
    lines
}

/// How far from a comment's stored start its moved anchor is looked for first, in characters.
const ANCHOR_SEARCH_WINDOW: u64 = 200;

/// Where `comment`'s anchor is in `text` now, as the web's `classifyAndRemapComments`: the
/// occurrence nearest the stored start within [`ANCHOR_SEARCH_WINDOW`], else the first one,
/// else the stored start.
#[must_use]
pub fn anchored_start(comment: &FileComment, text: &str) -> Option<u64> {
    let (Some(anchor), Some(stored)) = (comment.anchor.as_deref(), comment.start_index) else {
        return comment.start_index;
    };
    let anchor_length = anchor.chars().fold(0_u64, |count, _| count + 1);
    let window = stored.saturating_sub(ANCHOR_SEARCH_WINDOW)
        ..=stored
            .saturating_add(anchor_length)
            .saturating_add(ANCHOR_SEARCH_WINDOW);
    let mut first = None;
    let mut nearest: Option<u64> = None;
    let mut characters = 0_u64;
    let mut counted_to = 0_usize;
    let mut from = 0_usize;
    while let Some(found) = text.get(from..).and_then(|rest| rest.find(anchor)) {
        let byte = from + found;
        characters += text.get(counted_to..byte).map_or(0, |between| {
            between.chars().fold(0_u64, |count, _| count + 1)
        });
        counted_to = byte;
        first.get_or_insert(characters);
        if window.contains(&characters)
            && nearest.is_none_or(|best| characters.abs_diff(stored) < best.abs_diff(stored))
        {
            nearest = Some(characters);
        }
        // The next occurrence may overlap this one, as the web's `indexOf(anchor, from + 1)`.
        from = byte
            + text
                .get(byte..)
                .and_then(|rest| rest.chars().next())
                .map_or(1, char::len_utf8);
    }
    nearest.or(first).or(Some(stored))
}

fn comment_from(value: &Value) -> Result<FileComment, String> {
    let object = as_object(value, "a comment")?;
    Ok(FileComment {
        id: req_str(object, "id")?,
        session_id: req_str(object, "conversation_id")?,
        path: req_str(object, "path")?,
        body: req_str(object, "body")?,
        is_open: req_str(object, "status")? == "draft",
        anchor: opt_str(object, "anchor_content")?.filter(|anchor| !anchor.trim().is_empty()),
        start_index: opt_u64(object, "start_index")?,
        author: opt_str(object, "created_by")?.filter(|author| !author.is_empty()),
        created_at: object
            .get("created_at")
            .and_then(Value::as_i64)
            .ok_or("`created_at` is not an integer")?,
        updated_at_micros: opt_u64(object, "updated_at")?.unwrap_or_default(),
    })
}

impl<T: HttpTransport> ClientCore<T> {
    /// Every comment on `session_id`'s files.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn session_comments(
        &self,
        session_id: &str,
    ) -> Result<Vec<FileComment>, SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}/comments");
        let result = self.get_json(&path, &[]).await;
        self.dispatch();
        let malformed = |detail: String| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        };
        result?
            .as_array()
            .ok_or_else(|| malformed("not a list".into()))?
            .iter()
            .map(comment_from)
            .collect::<Result<_, _>>()
            .map_err(malformed)
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// Leaves `comment` on `session_id`'s file.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; `InvalidInput` for an empty comment or a reversed range; the write
    /// errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn add_session_comment(
        &self,
        session_id: &str,
        comment: &NewFileComment,
    ) -> Result<FileComment, SessionError> {
        validate_identifier(session_id)?;
        if comment.body.trim().is_empty() || comment.path.is_empty() {
            return Err(SessionError::InvalidInput {
                reason: "Write a comment first.".to_owned(),
            });
        }
        if comment.end_index < comment.start_index {
            return Err(SessionError::InvalidInput {
                reason: "The commented range is invalid.".to_owned(),
            });
        }
        let path = format!("/v1/sessions/{session_id}/comments");
        let body = json!({
            "path": comment.path,
            "body": comment.body.trim(),
            "start_index": comment.start_index,
            "end_index": comment.end_index,
            "anchor_content": comment.anchor,
        });
        let value = self.write_json("POST", &path, &body).await?;
        comment_from(&value).map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        })
    }
}

/// A change to a comment: its text, its state, or both.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CommentUpdate {
    /// The new comment.
    pub body: Option<String>,
    /// Reopen (`true`, `draft`) or resolve (`false`, `addressed`) it.
    pub open: Option<bool>,
}

const HOST_OFFLINE_COMMENTS: &str = "The host for this session is offline, so the comments \
                                     weren\u{2019}t sent. Try again once it reconnects.";

impl<T: HttpTransport> ClientCore<T> {
    /// Edits, resolves or reopens a comment on `session_id`'s files.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; `InvalidInput` for an empty comment or an empty update; the write
    /// errors (the server lets only the author edit a comment's text);
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn update_session_comment(
        &self,
        session_id: &str,
        comment_id: &str,
        update: &CommentUpdate,
    ) -> Result<FileComment, SessionError> {
        validate_identifier(session_id)?;
        validate_identifier(comment_id)?;
        let mut body = Map::new();
        if let Some(text) = &update.body {
            if text.trim().is_empty() {
                return Err(SessionError::InvalidInput {
                    reason: "Write a comment first.".to_owned(),
                });
            }
            body.insert("body".into(), json!(text.trim()));
        }
        if let Some(open) = update.open {
            let status = if open { "draft" } else { "addressed" };
            body.insert("status".into(), json!(status));
        }
        if body.is_empty() {
            return Err(SessionError::InvalidInput {
                reason: "Nothing to change.".to_owned(),
            });
        }
        let path = format!("/v1/sessions/{session_id}/comments/{comment_id}");
        let value = self.write_json("PATCH", &path, &Value::Object(body)).await;
        self.dispatch();
        comment_from(&value?).map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        })
    }

    /// Deletes a comment on `session_id`'s files.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the write errors (the server lets only the author delete it).
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn delete_session_comment(
        &self,
        session_id: &str,
        comment_id: &str,
    ) -> Result<(), SessionError> {
        validate_identifier(session_id)?;
        validate_identifier(comment_id)?;
        let path = format!("/v1/sessions/{session_id}/comments/{comment_id}");
        let result = self.write(self.prepare("DELETE", &path, &[], None)?).await;
        self.dispatch();
        result.map(|_| ())
    }

    /// Sends comments to the agent, as the web's "Address All": the server marks them sent and
    /// formats them into one message, which goes to the session as the user's message. When
    /// the message cannot be sent the comments are reopened, so none reads as sent unsent.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; `InvalidInput` without comments; the write errors;
    /// [`SessionError::MalformedResponse`]; the send's errors (a host offline says the comments
    /// were not sent).
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn send_comments_to_agent(
        &self,
        session_id: &str,
        comment_ids: &[String],
    ) -> Result<MessageSent, SessionError> {
        validate_identifier(session_id)?;
        if comment_ids.is_empty() {
            return Err(SessionError::InvalidInput {
                reason: "There are no open comments to send.".to_owned(),
            });
        }
        for id in comment_ids {
            validate_identifier(id)?;
        }
        let path = format!("/v1/sessions/{session_id}/comments/send");
        let value = self
            .write_json("POST", &path, &json!({ "comment_ids": comment_ids }))
            .await?;
        let message = value
            .get("formatted_message")
            .and_then(Value::as_str)
            .ok_or_else(|| SessionError::MalformedResponse {
                detail: format!("{path}: `formatted_message` is not a string"),
            })?
            .to_owned();
        let error = match self.send_reply(session_id, &message).await {
            Ok(sent) => return Ok(sent),
            Err(error) => error,
        };
        let reopen = CommentUpdate {
            body: None,
            open: Some(true),
        };
        for id in comment_ids {
            // The send's failure is the one to show; a comment left sent can still be reopened.
            if self
                .update_session_comment(session_id, id, &reopen)
                .await
                .is_err()
            {
                break;
            }
        }
        Err(match error {
            SessionError::HostOffline { .. } => SessionError::HostOffline {
                message: HOST_OFFLINE_COMMENTS.to_owned(),
            },
            other => other,
        })
    }
}

/// The immutable diff coordinates of a session-only review comment on a pull request
/// (`anchor_metadata`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ReviewCommentAnchor {
    /// The pull request.
    pub pr_url: String,
    /// The side of the diff.
    pub side: ReviewSide,
    /// The last line.
    pub line: u64,
    /// The first line of a range.
    pub start_line: Option<u64>,
    /// The head the comment was written at.
    pub head_sha: String,
    /// The base the comment was written at.
    pub base_sha: String,
}

impl ReviewCommentAnchor {
    fn to_json(&self) -> Value {
        json!({
            "pr_url": self.pr_url,
            "side": self.side.wire(),
            "line": self.line,
            "start_line": self.start_line,
            "head_sha": self.head_sha,
            "base_sha": self.base_sha,
        })
    }
}

/// A comment for the session's agent on lines of a pull request's diff.
///
/// It keeps every field the server sends, so the composer attaches the snapshot the web's
/// `LocalReviewComment` sends.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct LocalReviewComment {
    /// Id.
    pub id: String,
    /// The session it belongs to.
    pub session_id: String,
    /// The file.
    pub path: String,
    /// The server's character range, unused for diff comments.
    pub start_index: u64,
    /// The end of that range.
    pub end_index: u64,
    /// The comment.
    pub body: String,
    /// `draft` (open) or `addressed`.
    pub status: String,
    /// Created, Unix seconds.
    pub created_at: i64,
    /// Last change, Unix microseconds.
    pub updated_at: u64,
    /// The commented text; unused for diff comments.
    pub anchor_content: Option<String>,
    /// Who left it; `None` in single-user mode.
    pub author: Option<String>,
    /// Where it is on the diff.
    pub anchor: ReviewCommentAnchor,
}

impl LocalReviewComment {
    /// Whether it is open (not yet addressed).
    #[must_use]
    pub fn is_open(&self) -> bool {
        self.status == "draft"
    }
}

fn anchor_from(object: &Map<String, Value>) -> Result<ReviewCommentAnchor, String> {
    let side = opt_str(object, "side")?;
    let side = ReviewSide::parse(side.as_deref()).ok_or("`side` is not LEFT or RIGHT")?;
    let line = opt_u64(object, "line")?
        .filter(|line| *line > 0)
        .ok_or("`line` is not a positive line")?;
    let start_line = opt_u64(object, "start_line")?;
    if start_line.is_some_and(|start| start == 0 || start > line) {
        return Err("`start_line` is not a line before `line`".to_owned());
    }
    Ok(ReviewCommentAnchor {
        pr_url: req_str(object, "pr_url")?,
        side,
        line,
        start_line,
        head_sha: req_str(object, "head_sha")?,
        base_sha: req_str(object, "base_sha")?,
    })
}

/// Decodes a comment that carries a diff anchor; `Ok(None)` for a workspace-file comment.
fn review_comment_from(value: &Value) -> Result<Option<LocalReviewComment>, String> {
    let object = as_object(value, "a comment")?;
    let Some(anchor) = opt_object(object, "anchor_metadata")? else {
        return Ok(None);
    };
    Ok(Some(LocalReviewComment {
        id: req_str(object, "id")?,
        session_id: req_str(object, "conversation_id")?,
        path: req_str(object, "path")?,
        start_index: opt_u64(object, "start_index")?.unwrap_or_default(),
        end_index: opt_u64(object, "end_index")?.unwrap_or_default(),
        body: req_str(object, "body")?,
        status: req_str(object, "status")?,
        created_at: object
            .get("created_at")
            .and_then(Value::as_i64)
            .ok_or("`created_at` is not an integer")?,
        updated_at: opt_u64(object, "updated_at")?.unwrap_or_default(),
        anchor_content: opt_str(object, "anchor_content")?,
        author: opt_str(object, "created_by")?.filter(|author| !author.is_empty()),
        anchor: anchor_from(anchor)?,
    }))
}

/// One comment as the web's `JSON.stringify(comment, null, 2)` writes it, keys in the
/// server's order.
fn snapshot(comment: &LocalReviewComment) -> String {
    let text = |value: &str| Value::String(value.to_owned()).to_string();
    let optional = |value: Option<&str>| value.map_or_else(|| "null".to_owned(), text);
    let anchor = &comment.anchor;
    let start_line = anchor
        .start_line
        .map_or_else(|| "null".to_owned(), |start| start.to_string());
    let fields = [
        ("id", text(&comment.id)),
        ("conversation_id", text(&comment.session_id)),
        ("path", text(&comment.path)),
        ("start_index", comment.start_index.to_string()),
        ("end_index", comment.end_index.to_string()),
        ("body", text(&comment.body)),
        ("status", text(&comment.status)),
        ("created_at", comment.created_at.to_string()),
        ("updated_at", comment.updated_at.to_string()),
        (
            "anchor_content",
            optional(comment.anchor_content.as_deref()),
        ),
        ("created_by", optional(comment.author.as_deref())),
    ];
    let anchor_fields = [
        ("pr_url", text(&anchor.pr_url)),
        ("side", text(anchor.side.wire())),
        ("line", anchor.line.to_string()),
        ("start_line", start_line),
        ("head_sha", text(&anchor.head_sha)),
        ("base_sha", text(&anchor.base_sha)),
    ];
    let mut lines: Vec<String> = fields
        .into_iter()
        .map(|(key, value)| format!("  \"{key}\": {value}"))
        .collect();
    let anchor_lines: Vec<String> = anchor_fields
        .into_iter()
        .map(|(key, value)| format!("    \"{key}\": {value}"))
        .collect();
    lines.push(format!(
        "  \"anchor_metadata\": {{\n{}\n  }}",
        anchor_lines.join(",\n")
    ));
    format!("{{\n{}\n}}", lines.join(",\n"))
}

/// The fence language the web marks attached review comments with.
pub const LOCAL_REVIEW_COMMENT_LANGUAGE: &str = "local-review-comment";

/// The text a message sends for attached review comments (the web's `formatLocalReviewComments`).
///
/// An instruction comes first unless the message has its own text, then each comment's snapshot
/// in a fence, so an agent needs no tool to read them.
#[must_use]
pub fn format_local_review_comments(
    comments: &[LocalReviewComment],
    include_instruction: bool,
) -> String {
    let mut parts = Vec::new();
    if include_instruction {
        parts.push("Please address these local review comments:".to_owned());
    }
    for comment in comments {
        // Keeps quoted attachment markers out of the chat's mention-rewriting pass.
        let body = snapshot(comment).replace("[Attached", "\\u005bAttached");
        parts.push(format!("```{LOCAL_REVIEW_COMMENT_LANGUAGE}\n{body}\n```"));
    }
    parts.join("\n\n")
}

/// The most pages of comments read before the cursor is taken as stuck.
const MAX_COMMENT_PAGES: usize = 200;

/// What creating a review comment says when the server did not keep its place.
const ANCHOR_LOST: &str = "This server did not preserve the review location. Your draft is saved.";

impl<T: HttpTransport> ClientCore<T> {
    /// The session's review comments on pull request diffs, oldest first. A server that
    /// predates them answers its workspace-file list, which holds none.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the read errors; [`SessionError::InvalidPagination`] for a cursor
    /// that does not advance; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn session_review_comments(
        &self,
        session_id: &str,
    ) -> Result<Vec<LocalReviewComment>, SessionError> {
        let result = self.review_comment_pages(session_id).await;
        self.dispatch();
        let mut comments = result?;
        comments.sort_by(|left, right| {
            left.created_at
                .cmp(&right.created_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(comments)
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn review_comment_pages(
        &self,
        session_id: &str,
    ) -> Result<Vec<LocalReviewComment>, SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}/comments");
        let malformed = |detail: String| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        };
        let mut comments = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..MAX_COMMENT_PAGES {
            let mut query = vec![
                ("include_pr_comments", "true".to_owned()),
                ("limit", "100".to_owned()),
            ];
            if let Some(after) = &cursor {
                query.push(("after", after.clone()));
            }
            let value = self.get_json(&path, &query).await?;
            // Older servers ignore the opt-in and answer their workspace-file list.
            if value.is_array() {
                return Ok(comments);
            }
            let object = as_object(&value, "the page").map_err(malformed)?;
            for row in opt_array(object, "comments")
                .map_err(malformed)?
                .into_iter()
                .flatten()
            {
                if let Some(comment) = review_comment_from(row).map_err(malformed)? {
                    comments.push(comment);
                }
            }
            let next = opt_str(object, "next_cursor").map_err(malformed)?;
            if next.is_none() {
                return Ok(comments);
            }
            if next == cursor {
                return Err(SessionError::InvalidPagination);
            }
            cursor = next;
        }
        Err(SessionError::InvalidPagination)
    }

    /// Leaves a comment for the session's agent on lines of a pull request's diff. A server
    /// that answers without the same place (one that predates diff comments keeps it as a
    /// workspace-file comment) has the comment deleted again, and the draft stays.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; `InvalidInput` for an empty comment or path; the write errors;
    /// [`SessionError::Rejected`] when the server lost the place.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn add_review_comment(
        &self,
        session_id: &str,
        path: &str,
        body: &str,
        anchor: &ReviewCommentAnchor,
    ) -> Result<LocalReviewComment, SessionError> {
        validate_identifier(session_id)?;
        if body.trim().is_empty() || path.is_empty() {
            return Err(SessionError::InvalidInput {
                reason: "Write a comment first.".to_owned(),
            });
        }
        let route = format!("/v1/sessions/{session_id}/comments");
        let request = json!({
            "path": path,
            "body": body,
            "start_index": 0,
            "end_index": 0,
            "anchor_metadata": anchor.to_json(),
        });
        let value = self.write_json("POST", &route, &request).await;
        self.dispatch();
        let value = value?;
        let kept = review_comment_from(&value)
            .ok()
            .flatten()
            .filter(|comment| {
                comment.session_id == session_id
                    && comment.path == path
                    && comment.anchor == *anchor
            });
        if let Some(comment) = kept {
            return Ok(comment);
        }
        let id = value.get("id").and_then(Value::as_str).map(str::to_owned);
        let removed = match id {
            Some(id) => self.delete_session_comment(session_id, &id).await,
            None => Err(SessionError::MalformedResponse {
                detail: format!("{route}: the comment has no id"),
            }),
        };
        let message = match removed {
            Ok(()) | Err(SessionError::Rejected { status: 404, .. }) => {
                format!("{ANCHOR_LOST} Update the server before retrying.")
            }
            Err(_) => {
                format!("{ANCHOR_LOST} A comment may remain in Files; remove it before retrying.")
            }
        };
        Err(SessionError::Rejected {
            status: 422,
            message,
        })
    }
}

#[cfg(test)]
#[path = "comments_review_tests.rs"]
mod review_tests;

#[cfg(test)]
mod tests {
    use futures::executor::block_on;

    use super::super::test_support::{
        Reply, RouteTransport, body_json, connected, lines_after_connect,
    };
    use super::*;

    const COMMENTS: &str = r#"[
      {"id":"c1","conversation_id":"s1","path":"a.rs","start_index":0,"end_index":3,"body":"old","status":"draft","created_at":10,"updated_at":10000000,"anchor_content":"fn ","created_by":"bob@x"},
      {"id":"c2","conversation_id":"s1","path":"a.rs","start_index":0,"end_index":3,"body":"new","status":"draft","created_at":20,"updated_at":20000001,"anchor_content":null,"created_by":"bob@x"},
      {"id":"c3","conversation_id":"s1","path":"b.rs","start_index":0,"end_index":1,"body":"done","status":"addressed","created_at":30,"updated_at":30000000,"created_by":"bob@x"},
      {"id":"c4","conversation_id":"s1","path":"b.rs","start_index":0,"end_index":1,"body":"mine","status":"draft","created_at":40,"updated_at":40000000,"created_by":"me@x"},
      {"id":"c5","conversation_id":"s1","path":"b.rs","start_index":0,"end_index":1,"body":"anon","status":"draft","created_at":50,"updated_at":50000000,"created_by":null},
      {"id":"c6","conversation_id":"s1","path":"b.rs","start_index":0,"end_index":1,"body":"same second","status":"draft","created_at":20,"updated_at":20000009,"created_by":"carol@x"}
    ]"#;

    #[test]
    fn an_unreadable_new_comment_is_malformed() {
        let core = connected(RouteTransport::local());
        core.transport()
            .ok("/v1/sessions/conv_a/comments", r#"{"id":5}"#);
        let draft = NewFileComment {
            path: "a.rs".into(),
            body: "why?".into(),
            start_index: 3,
            end_index: 5,
            anchor: None,
        };
        assert!(matches!(
            block_on(core.add_session_comment("conv_a", &draft)),
            Err(SessionError::MalformedResponse { detail })
                if detail.starts_with("/v1/sessions/conv_a/comments: ")
        ));
    }

    #[test]
    fn line_ranges_count_characters_without_the_break() {
        assert_eq!(line_character_range("ab\ncd\n", 1), Some((0, 2)));
        assert_eq!(line_character_range("ab\ncd\n", 2), Some((3, 5)));
        assert_eq!(line_character_range("é\nñx", 2), Some((2, 4)));
        assert_eq!(line_character_range("ab", 1), Some((0, 2)));
        assert_eq!(line_character_range("", 1), Some((0, 0)));
        assert_eq!(line_character_range("ab\ncd", 3), None);
        assert_eq!(line_character_range("ab", 0), None);
    }

    #[test]
    fn file_comments_carry_their_line_in_file_order() {
        let comments: Vec<FileComment> = serde_json::from_str::<Value>(COMMENTS)
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .map(|value| comment_from(value).unwrap())
            .collect();
        let mut moved = comments[1].clone();
        moved.id = "c7".into();
        moved.start_index = Some(5);
        let mut all = comments;
        all.push(moved);
        let lines = file_comment_lines(&all, "a.rs", "fn a\nb");
        let ids: Vec<(Option<u64>, &str)> = lines
            .iter()
            .map(|(line, comment)| (*line, comment.id.as_str()))
            .collect();
        assert_eq!(ids, [(Some(1), "c1"), (Some(1), "c2"), (Some(2), "c7")]);
        let states: Vec<bool> = file_comment_lines(&all, "b.rs", "x")
            .iter()
            .map(|(_, comment)| comment.is_open)
            .collect();
        assert_eq!(
            states.iter().filter(|open| !**open).count(),
            1,
            "sent ones too"
        );
    }

    #[test]
    fn adds_a_comment_and_validates_it_first() {
        let transport = RouteTransport::local();
        transport.ok(
            "/v1/sessions/s1/comments",
            r#"{"id":"c9","conversation_id":"s1","path":"a.rs","start_index":3,"end_index":5,"body":"why?","status":"draft","created_at":10,"updated_at":10,"anchor_content":"cd","created_by":null}"#,
        );
        let core = connected(transport);
        let comment = NewFileComment {
            path: "a.rs".into(),
            body: " why? ".into(),
            start_index: 3,
            end_index: 5,
            anchor: Some("cd".into()),
        };
        let added = block_on(core.add_session_comment("s1", &comment)).unwrap();
        assert_eq!(added.id, "c9");
        assert_eq!(added.start_index, Some(3));
        let blank = NewFileComment {
            body: "  ".into(),
            ..comment.clone()
        };
        assert!(matches!(
            block_on(core.add_session_comment("s1", &blank)),
            Err(SessionError::InvalidInput { .. })
        ));
        let reversed = NewFileComment {
            start_index: 6,
            ..comment
        };
        assert!(matches!(
            block_on(core.add_session_comment("s1", &reversed)),
            Err(SessionError::InvalidInput { .. })
        ));
    }

    fn comment_at(start: u64, anchor: Option<&str>) -> FileComment {
        FileComment {
            id: "c".into(),
            session_id: "s1".into(),
            path: "a.rs".into(),
            body: "b".into(),
            is_open: true,
            anchor: anchor.map(str::to_owned),
            start_index: Some(start),
            author: None,
            created_at: 1,
            updated_at_micros: 1,
        }
    }

    #[test]
    fn open_comments_follow_their_moved_anchor() {
        // Unmoved, moved by an insertion, nearest of two copies, and gone.
        assert_eq!(anchored_start(&comment_at(2, Some("cd")), "abcd"), Some(2));
        assert_eq!(
            anchored_start(&comment_at(2, Some("cd")), "é\nabcd"),
            Some(4)
        );
        let text = format!("x = 1\n{}x = 1\n", "y\n".repeat(150));
        assert_eq!(
            anchored_start(&comment_at(306, Some("x = 1")), &text),
            Some(306)
        );
        assert_eq!(
            anchored_start(&comment_at(3, Some("gone")), "abcd"),
            Some(3)
        );
        assert_eq!(anchored_start(&comment_at(3, None), "abcd"), Some(3));
        // A stored offset at the integer limit falls back to the first occurrence.
        assert_eq!(
            anchored_start(&comment_at(u64::MAX, Some("cd")), "abcd"),
            Some(2)
        );
        // Far away, the first occurrence wins; overlapping copies are found.
        let far = format!("{}aaa", "z".repeat(900));
        assert_eq!(anchored_start(&comment_at(0, Some("aa")), &far), Some(900));
        let mut sent = comment_at(0, Some("cd"));
        sent.is_open = false;
        let lines = file_comment_lines(&[sent], "a.rs", "ab\ncd");
        assert_eq!(lines[0].0, Some(1), "a sent comment keeps its stored place");
    }

    #[test]
    fn edits_resolves_reopens_and_deletes_a_comment() {
        let transport = RouteTransport::local();
        transport.ok(
            "/v1/sessions/s1/comments/c1",
            r#"{"id":"c1","conversation_id":"s1","path":"a.rs","start_index":0,"end_index":1,"body":"new","status":"addressed","created_at":1,"updated_at":2}"#,
        );
        let core = connected(transport);
        let edit = CommentUpdate {
            body: Some(" new ".into()),
            open: Some(false),
        };
        let updated = block_on(core.update_session_comment("s1", "c1", &edit)).unwrap();
        assert!(!updated.is_open);
        let reopen = CommentUpdate {
            body: None,
            open: Some(true),
        };
        block_on(core.update_session_comment("s1", "c1", &reopen)).unwrap();
        block_on(core.delete_session_comment("s1", "c1")).unwrap();
        let writes = core.transport().writes();
        assert_eq!(writes[0].method, "PATCH");
        assert_eq!(
            body_json(&writes[0]),
            json!({"body": "new", "status": "addressed"})
        );
        assert_eq!(body_json(&writes[1]), json!({"status": "draft"}));
        assert_eq!(writes[2].method, "DELETE");
        for empty in [
            CommentUpdate::default(),
            CommentUpdate {
                body: Some(" ".into()),
                open: None,
            },
        ] {
            assert!(matches!(
                block_on(core.update_session_comment("s1", "c1", &empty)),
                Err(SessionError::InvalidInput { .. })
            ));
        }
        assert!(matches!(
            block_on(core.delete_session_comment("s1", "a/b")),
            Err(SessionError::InvalidIdentifier { .. })
        ));
    }

    #[test]
    fn unreadable_replies_about_a_comment_are_malformed() {
        let transport = RouteTransport::local();
        transport.ok("/v1/sessions/conv_a/comments", r#"{"id":5}"#);
        transport.ok("/v1/sessions/conv_a/comments/c1", r#"{"id":5}"#);
        transport.ok(
            "/v1/sessions/conv_a/comments/send",
            r#"{"formatted_message":5}"#,
        );
        let core = connected(transport);
        let ids = ["c1".to_owned()];
        assert!(matches!(
            block_on(core.update_session_comment(
                "conv_a",
                "c1",
                &CommentUpdate { body: None, open: Some(true) }
            )),
            Err(SessionError::MalformedResponse { detail }) if detail.contains("/comments/c1")
        ));
        assert!(matches!(
            block_on(core.send_comments_to_agent("conv_a", &ids)),
            Err(SessionError::MalformedResponse { detail }) if detail.contains("formatted_message")
        ));
    }

    #[test]
    fn a_failed_send_stops_reopening_when_reopening_fails_too_and_keeps_the_first_error() {
        let failing = RouteTransport::local();
        failing.ok(
            "/v1/sessions/conv_a/comments/send",
            r#"{"formatted_message":"m"}"#,
        );
        failing.respond(
            None,
            "/v1/sessions/conv_a/events",
            None,
            Reply::json(400, r#"{"detail":"no"}"#),
        );
        failing.respond(
            None,
            "/v1/sessions/conv_a/comments/c1",
            None,
            Reply::json(500, "{}"),
        );
        let core = connected(failing);
        let ids = ["c1".to_owned(), "c2".to_owned()];
        assert!(matches!(
            block_on(core.send_comments_to_agent("conv_a", &ids)),
            Err(SessionError::Rejected { .. })
        ));
        assert_eq!(
            core.transport()
                .writes()
                .iter()
                .filter(|write| write.method == "PATCH")
                .count(),
            1,
            "the second comment is not attempted"
        );
    }

    #[test]
    fn a_host_offline_failure_explains_the_comments_were_kept() {
        let transport = RouteTransport::local();
        transport.ok(
            "/v1/sessions/conv_a/comments/send",
            r#"{"formatted_message":"m"}"#,
        );
        transport.ok(
            "/v1/sessions/conv_a/comments/c1",
            r#"{"id":"c1","conversation_id":"conv_a","path":"a.rs","body":"b","status":"draft","created_at":1}"#,
        );
        transport.respond(
            None,
            "/v1/sessions/conv_a/events",
            None,
            Reply::json(503, r#"{"error":{"code":"host_offline","message":"Off"}}"#),
        );
        let core = connected(transport);
        let outcome = block_on(core.send_comments_to_agent("conv_a", &["c1".to_owned()]));
        assert!(
            matches!(&outcome, Err(SessionError::HostOffline { message }) if message == HOST_OFFLINE_COMMENTS),
            "{outcome:?}"
        );
    }

    #[test]
    fn sends_comments_as_one_message_and_reopens_them_when_it_fails() {
        let transport = RouteTransport::local();
        transport.ok(
            "/v1/sessions/conv_a/comments/send",
            r#"{"formatted_message":"Please address:\n- a.rs:1 why?","sent_comment_ids":["c1","c2"]}"#,
        );
        transport.ok("/v1/sessions/conv_a/events", r#"{"queued":true}"#);
        let core = connected(transport);
        let ids = ["c1".to_owned(), "c2".to_owned()];
        block_on(core.send_comments_to_agent("conv_a", &ids)).unwrap();
        assert_eq!(
            lines_after_connect(&core),
            [
                "POST /v1/sessions/conv_a/comments/send",
                "POST /v1/sessions/conv_a/events"
            ]
        );
        let writes = core.transport().writes();
        assert_eq!(body_json(&writes[0]), json!({"comment_ids": ["c1", "c2"]}));
        assert_eq!(
            body_json(&writes[1])["data"]["content"][0]["text"],
            "Please address:\n- a.rs:1 why?"
        );
        assert!(matches!(
            block_on(core.send_comments_to_agent("conv_a", &[])),
            Err(SessionError::InvalidInput { .. })
        ));

        let failing = RouteTransport::local();
        failing.ok(
            "/v1/sessions/conv_a/comments/send",
            r#"{"formatted_message":"m","sent_comment_ids":["c1"]}"#,
        );
        failing.respond(
            None,
            "/v1/sessions/conv_a/events",
            None,
            Reply::json(400, r#"{"detail":"no"}"#),
        );
        failing.ok(
            "/v1/sessions/conv_a/comments/c1",
            r#"{"id":"c1","conversation_id":"conv_a","path":"a.rs","body":"b","status":"draft","created_at":1}"#,
        );
        let core = connected(failing);
        assert!(block_on(core.send_comments_to_agent("conv_a", &ids[..1])).is_err());
        let reopened = core.transport().writes().pop().unwrap();
        assert_eq!(reopened.method, "PATCH");
        assert_eq!(body_json(&reopened), json!({"status": "draft"}));
    }

    #[test]
    fn lines_count_characters_not_bytes() {
        assert_eq!(line_at_character("a\nb\nc", 0), Some(1));
        assert_eq!(line_at_character("a\nb\nc", 2), Some(2));
        assert_eq!(line_at_character("é\nñ\nc", 4), Some(3));
        assert_eq!(line_at_character("ab", 2), Some(1));
        assert_eq!(line_at_character("ab", 3), None);
    }

    #[test]
    fn lists_others_open_unseen_comments_newest_first() {
        let transport = RouteTransport::local();
        transport.ok("/v1/sessions/s1/comments", COMMENTS);
        let comments = block_on(connected(transport).session_comments("s1")).unwrap();
        assert_eq!(comments[0].anchor.as_deref(), Some("fn "));
        assert_eq!(comments[0].start_index, Some(0));
        let seen = BTreeSet::from(["c1".to_owned()]);
        let inbox = comment_inbox(&comments, &seen, Some("me@x"));
        let ids: Vec<&str> = inbox.iter().map(|comment| comment.id.as_str()).collect();
        assert_eq!(ids, ["c6", "c2"]);
        assert_eq!(comment_inbox(&comments, &BTreeSet::new(), None).len(), 4);
    }

    #[test]
    fn list_rows_carry_the_comment_count() {
        let transport = RouteTransport::local();
        transport.ok(
            "/v1/sessions",
            r#"{"data":[{"id":"a","status":"idle","created_at":1,"comments_count":3},{"id":"b","status":"idle","created_at":1}],"has_more":false}"#,
        );
        let sessions = block_on(connected(transport).sessions()).unwrap();
        assert_eq!(sessions[0].comments_count, 3);
        assert_eq!(sessions[1].comments_count, 0);
    }

    #[test]
    fn malformed_comments_are_errors() {
        let transport = RouteTransport::local();
        transport.ok("/v1/sessions/s1/comments", r#"[{"id":"c1"}]"#);
        assert!(matches!(
            block_on(connected(transport).session_comments("s1")),
            Err(SessionError::MalformedResponse { .. })
        ));
        let core = connected(RouteTransport::local());
        assert!(matches!(
            block_on(core.session_comments("a/b")),
            Err(SessionError::InvalidIdentifier { .. })
        ));
    }
}
