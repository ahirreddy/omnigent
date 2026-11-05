//! File review comments and the Inbox's comment side.
//!
//! `GET /v1/sessions/{id}/comments` lists a session's comments; the Inbox shows the open ones
//! other people left that the caller has not seen, as the web collects them
//! (`collectCommentInboxItems`).

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::json::{as_object, opt_str, opt_u64, req_str};
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

/// The open comments on `path`, each with the 1-based line of `text` it starts on (`None` when
/// it has no position or its position is past the end), in file order.
#[must_use]
pub fn file_comment_lines(
    comments: &[FileComment],
    path: &str,
    text: &str,
) -> Vec<(Option<u64>, FileComment)> {
    let mut lines: Vec<(Option<u64>, FileComment)> = comments
        .iter()
        .filter(|comment| comment.is_open && comment.path == path)
        .map(|comment| {
            let line = comment
                .start_index
                .and_then(|start| line_at_character(text, start));
            (line, comment.clone())
        })
        .collect();
    lines.sort_by_key(|(line, comment)| (line.is_none(), *line, comment.created_at));
    lines
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

#[cfg(test)]
mod tests {
    use futures::executor::block_on;

    use super::super::test_support::{RouteTransport, connected};
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
        assert!(
            file_comment_lines(&all, "b.rs", "x")
                .iter()
                .all(|(_, comment)| comment.is_open)
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
