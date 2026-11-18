//! A pull request's inline review threads, read and written through the session's host.
//!
//! `GET …/resources/github/review-threads` pages the PR's threads at one revision
//! (`head_sha`, `base_sha`); `GET …/review-threads/{id}/comments` pages a thread's older
//! comments; `POST …/review-threads/{id}/replies` replies and `POST …/review-threads` starts a
//! thread on a line or a range of one side of the diff.

use serde_json::{Map, Value, json};

use super::{each_object, github_resource, pr_query};
use crate::client::json::{as_object, opt_bool, opt_object, opt_str, opt_u64, req_str};
use crate::client::requests::validate_identifier;
use crate::client::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// The provider's longest comment, in Unicode scalar values (the web's
/// `MAX_PULL_REQUEST_COMMENT_CHARACTERS`).
pub const MAX_REVIEW_COMMENT_CHARACTERS: usize = 65_536;

/// Which side of the diff a thread anchors to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ReviewSide {
    /// The base: removed lines and the old numbers of unchanged ones.
    Left,
    /// The head: added lines and the new numbers of unchanged ones.
    Right,
}

impl ReviewSide {
    const fn wire(self) -> &'static str {
        match self {
            Self::Left => "LEFT",
            Self::Right => "RIGHT",
        }
    }

    fn parse(value: Option<&str>) -> Option<Self> {
        match value {
            Some("LEFT") => Some(Self::Left),
            Some("RIGHT") => Some(Self::Right),
            _ => None,
        }
    }
}

/// One comment of a review thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewComment {
    /// Stable id.
    pub id: String,
    /// The author's login.
    pub author: Option<String>,
    /// Markdown.
    pub body: String,
    /// ISO-8601 creation time.
    pub created_at: Option<String>,
    /// Its page.
    pub url: Option<String>,
    /// The provider hides it.
    pub minimized: bool,
}

/// A page of a thread's comments.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReviewCommentPage {
    /// The comments, oldest first.
    pub comments: Vec<ReviewComment>,
    /// Older comments remain.
    pub has_more: bool,
    /// Where the next page starts.
    pub next_cursor: Option<String>,
    /// Why some could not be read.
    pub warning: Option<String>,
}

/// An inline review thread.
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts the host reports about one thread"
)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewThread {
    /// Stable id.
    pub id: String,
    /// The file.
    pub path: String,
    /// The side it anchors to; `None` for one this client does not know.
    pub side: Option<ReviewSide>,
    /// Its last line at the current revision; `None` once outdated.
    pub line: Option<u64>,
    /// Its first line, for a range.
    pub start_line: Option<u64>,
    /// The first line's side, when it differs.
    pub start_side: Option<ReviewSide>,
    /// Its last line when it was written.
    pub original_line: Option<u64>,
    /// Its first line when it was written.
    pub original_start_line: Option<u64>,
    /// About the whole file rather than lines.
    pub on_file: bool,
    /// Resolved on the provider.
    pub resolved: bool,
    /// The lines changed since it was written.
    pub outdated: bool,
    /// The account can reply.
    pub can_reply: bool,
    /// The patch lines it was written on.
    pub diff_hunk: String,
    /// Its newest comments.
    pub comments: ReviewCommentPage,
}

/// A page of the PR's threads at one revision.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReviewThreadsPage {
    /// The threads.
    pub threads: Vec<ReviewThread>,
    /// More threads remain.
    pub has_more: bool,
    /// Where the next page starts.
    pub next_cursor: Option<String>,
    /// Why some could not be read.
    pub warning: Option<String>,
    /// The head the threads were read at.
    pub head_sha: String,
    /// The base the threads were read at.
    pub base_sha: String,
}

/// Where a new thread goes: a line, or a range of one side, at the revision on screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewAnchor {
    /// The file.
    pub path: String,
    /// The side.
    pub side: ReviewSide,
    /// The last line.
    pub line: u64,
    /// The first line of a range.
    pub start_line: Option<u64>,
    /// The head on screen.
    pub head_sha: String,
    /// The base on screen.
    pub base_sha: String,
}

/// Why `body` cannot be posted as a review comment, or `None` when it can.
#[must_use]
pub fn review_comment_problem(body: &str) -> Option<String> {
    if body.trim().is_empty() {
        return Some("Write a comment before posting it.".to_owned());
    }
    (body.chars().count() > MAX_REVIEW_COMMENT_CHARACTERS)
        .then(|| format!("A comment can be at most {MAX_REVIEW_COMMENT_CHARACTERS} characters."))
}

fn decode_comment(object: &Map<String, Value>) -> Result<ReviewComment, String> {
    Ok(ReviewComment {
        id: req_str(object, "id")?,
        author: opt_str(object, "author")?,
        body: opt_str(object, "body")?.unwrap_or_default(),
        created_at: opt_str(object, "created_at")?,
        url: opt_str(object, "url")?,
        minimized: opt_bool(object, "minimized")?.unwrap_or(false),
    })
}

fn decode_comment_page(object: &Map<String, Value>) -> Result<ReviewCommentPage, String> {
    Ok(ReviewCommentPage {
        comments: each_object(object, "data")?
            .into_iter()
            .map(decode_comment)
            .collect::<Result<_, _>>()?,
        has_more: opt_bool(object, "has_more")?.unwrap_or(false),
        next_cursor: opt_str(object, "next_cursor")?,
        warning: opt_str(object, "warning")?,
    })
}

fn decode_thread(object: &Map<String, Value>) -> Result<ReviewThread, String> {
    let comments = match opt_object(object, "comments")? {
        Some(page) => decode_comment_page(page)?,
        None => ReviewCommentPage::default(),
    };
    Ok(ReviewThread {
        id: req_str(object, "id")?,
        path: req_str(object, "path")?,
        side: ReviewSide::parse(opt_str(object, "side")?.as_deref()),
        line: opt_u64(object, "line")?,
        start_line: opt_u64(object, "start_line")?,
        start_side: ReviewSide::parse(opt_str(object, "start_side")?.as_deref()),
        original_line: opt_u64(object, "original_line")?,
        original_start_line: opt_u64(object, "original_start_line")?,
        on_file: opt_str(object, "subject_type")?.as_deref() == Some("FILE"),
        resolved: opt_bool(object, "resolved")?.unwrap_or(false),
        outdated: opt_bool(object, "outdated")?.unwrap_or(false),
        can_reply: opt_bool(object, "can_reply")?.unwrap_or(false),
        diff_hunk: opt_str(object, "diff_hunk")?.unwrap_or_default(),
        comments,
    })
}

/// Decodes a page of threads.
///
/// # Errors
///
/// A description of the first malformed field.
pub fn decode_threads_page(value: &Value) -> Result<ReviewThreadsPage, String> {
    let object = as_object(value, "review threads")?;
    Ok(ReviewThreadsPage {
        threads: each_object(object, "data")?
            .into_iter()
            .map(decode_thread)
            .collect::<Result<_, _>>()?,
        has_more: opt_bool(object, "has_more")?.unwrap_or(false),
        next_cursor: opt_str(object, "next_cursor")?,
        warning: opt_str(object, "warning")?,
        head_sha: opt_str(object, "head_sha")?.unwrap_or_default(),
        base_sha: opt_str(object, "base_sha")?.unwrap_or_default(),
    })
}

/// A thread id as one path segment. Providers' ids are letters, digits, `_` and `-`; a path
/// may not carry anything that needs escaping.
fn thread_segment(thread_id: &str) -> Result<&str, SessionError> {
    validate_identifier(thread_id)?;
    Ok(thread_id)
}

fn malformed(path: &str) -> impl Fn(String) -> SessionError + '_ {
    move |detail| SessionError::MalformedResponse {
        detail: format!("{path}: {detail}"),
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// A page of `pr_url`'s review threads: the first, or the one after `after`'s cursor at
    /// its revision (`after` = cursor, head, base).
    ///
    /// # Errors
    ///
    /// The host read errors (see [`ClientCore::pull_request_info`]) and
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn pull_request_review_threads(
        &self,
        session_id: &str,
        pr_url: &str,
        after: Option<(&str, &str, &str)>,
    ) -> Result<ReviewThreadsPage, SessionError> {
        let result = async {
            let path = github_resource(session_id, "review-threads")?;
            let mut query = pr_query(Some(pr_url));
            if let Some((cursor, head, base)) = after {
                query.push(("after", cursor.to_owned()));
                query.push(("head_sha", head.to_owned()));
                query.push(("base_sha", base.to_owned()));
            }
            let value = self.host_resource_read(&path, &query).await?;
            decode_threads_page(&value).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }

    /// The page of `thread_id`'s comments after `cursor`.
    ///
    /// # Errors
    ///
    /// As [`ClientCore::pull_request_review_threads`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn review_thread_comments(
        &self,
        session_id: &str,
        pr_url: &str,
        thread_id: &str,
        cursor: &str,
    ) -> Result<ReviewCommentPage, SessionError> {
        let result = async {
            let thread = thread_segment(thread_id)?;
            let path = github_resource(session_id, &format!("review-threads/{thread}/comments"))?;
            let mut query = pr_query(Some(pr_url));
            query.push(("after", cursor.to_owned()));
            let value = self.host_resource_read(&path, &query).await?;
            let object = as_object(&value, "comments").map_err(malformed(&path))?;
            decode_comment_page(object).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }

    /// Replies to `thread_id`; answers the reply as the provider stored it.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidInput`] for a blank or too-long reply; the write errors, with the
    /// host's reason in [`SessionError::Rejected`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn reply_to_review_thread(
        &self,
        session_id: &str,
        pr_url: &str,
        thread_id: &str,
        body: &str,
    ) -> Result<ReviewComment, SessionError> {
        let result = async {
            if let Some(reason) = review_comment_problem(body) {
                return Err(SessionError::InvalidInput { reason });
            }
            let thread = thread_segment(thread_id)?;
            let path = github_resource(session_id, &format!("review-threads/{thread}/replies"))?;
            let value = self
                .write_json("POST", &path, &json!({ "pr_url": pr_url, "body": body }))
                .await?;
            let object = as_object(&value, "reply").map_err(malformed(&path))?;
            let comment = opt_object(object, "comment")
                .map_err(malformed(&path))?
                .ok_or_else(|| malformed(&path)("`comment` is missing".to_owned()))?;
            decode_comment(comment).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }

    /// Starts a review thread at `anchor`; answers the thread as the provider stored it.
    ///
    /// # Errors
    ///
    /// As [`ClientCore::reply_to_review_thread`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_review_thread(
        &self,
        session_id: &str,
        pr_url: &str,
        body: &str,
        anchor: &ReviewAnchor,
    ) -> Result<ReviewThread, SessionError> {
        let result = async {
            if let Some(reason) = review_comment_problem(body) {
                return Err(SessionError::InvalidInput { reason });
            }
            let path = github_resource(session_id, "review-threads")?;
            let request = json!({
                "pr_url": pr_url,
                "body": body,
                "anchor": {
                    "path": anchor.path,
                    "side": anchor.side.wire(),
                    "line": anchor.line,
                    "start_line": anchor.start_line,
                    "head_sha": anchor.head_sha,
                    "base_sha": anchor.base_sha,
                },
            });
            let value = self.write_json("POST", &path, &request).await?;
            let object = as_object(&value, "thread").map_err(malformed(&path))?;
            let thread = opt_object(object, "thread")
                .map_err(malformed(&path))?
                .ok_or_else(|| malformed(&path)("`thread` is missing".to_owned()))?;
            decode_thread(thread).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }
}
