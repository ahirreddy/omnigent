//! A pull request's inline review threads: read, replied to and started through the session's
//! host. The decoding and checks are `omnigent_core::pull_request_detail::reviews`'.

use omnigent_core::pull_request_detail::reviews as core;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// Which side of the diff a thread anchors to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ReviewSide {
    /// The base: removed lines and the old numbers of unchanged ones.
    Left,
    /// The head: added lines and the new numbers of unchanged ones.
    Right,
}

impl From<core::ReviewSide> for ReviewSide {
    fn from(side: core::ReviewSide) -> Self {
        match side {
            core::ReviewSide::Left => Self::Left,
            core::ReviewSide::Right => Self::Right,
        }
    }
}

impl From<ReviewSide> for core::ReviewSide {
    fn from(side: ReviewSide) -> Self {
        match side {
            ReviewSide::Left => Self::Left,
            ReviewSide::Right => Self::Right,
        }
    }
}

/// One comment of a review thread.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ReviewComment {
    /// Stable id.
    pub id: String,
    /// The author's login.
    pub author: Option<String>,
    /// Markdown.
    pub body: String,
    /// ISO-8601 time.
    pub created_at: Option<String>,
    /// Its page.
    pub url: Option<String>,
    /// The provider hides it.
    pub minimized: bool,
}

impl From<core::ReviewComment> for ReviewComment {
    fn from(comment: core::ReviewComment) -> Self {
        Self {
            id: comment.id,
            author: comment.author,
            body: comment.body,
            created_at: comment.created_at,
            url: comment.url,
            minimized: comment.minimized,
        }
    }
}

/// A page of a thread's comments.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ReviewCommentPage {
    /// Oldest first.
    pub comments: Vec<ReviewComment>,
    /// Older comments remain.
    pub has_more: bool,
    /// Where the next page starts.
    pub next_cursor: Option<String>,
    /// Why some could not be read.
    pub warning: Option<String>,
}

impl From<core::ReviewCommentPage> for ReviewCommentPage {
    fn from(page: core::ReviewCommentPage) -> Self {
        Self {
            comments: page.comments.into_iter().map(Into::into).collect(),
            has_more: page.has_more,
            next_cursor: page.next_cursor,
            warning: page.warning,
        }
    }
}

/// An inline review thread.
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts the host reports about one thread"
)]
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ReviewThread {
    /// Stable id.
    pub id: String,
    /// The file.
    pub path: String,
    /// The side, when known.
    pub side: Option<ReviewSide>,
    /// Its last line now; `None` once outdated.
    pub line: Option<u64>,
    /// Its first line, for a range.
    pub start_line: Option<u64>,
    /// The first line's side.
    pub start_side: Option<ReviewSide>,
    /// Its last line when written.
    pub original_line: Option<u64>,
    /// Its first line when written.
    pub original_start_line: Option<u64>,
    /// About the whole file.
    pub on_file: bool,
    /// Resolved on the provider.
    pub resolved: bool,
    /// Its lines changed since.
    pub outdated: bool,
    /// The account can reply.
    pub can_reply: bool,
    /// The patch lines it was written on.
    pub diff_hunk: String,
    /// Its newest comments.
    pub comments: ReviewCommentPage,
}

impl From<core::ReviewThread> for ReviewThread {
    fn from(thread: core::ReviewThread) -> Self {
        Self {
            id: thread.id,
            path: thread.path,
            side: thread.side.map(Into::into),
            line: thread.line,
            start_line: thread.start_line,
            start_side: thread.start_side.map(Into::into),
            original_line: thread.original_line,
            original_start_line: thread.original_start_line,
            on_file: thread.on_file,
            resolved: thread.resolved,
            outdated: thread.outdated,
            can_reply: thread.can_reply,
            diff_hunk: thread.diff_hunk,
            comments: thread.comments.into(),
        }
    }
}

/// A page of the PR's threads at one revision.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ReviewThreadsPage {
    /// The threads.
    pub threads: Vec<ReviewThread>,
    /// More threads remain.
    pub has_more: bool,
    /// Where the next page starts.
    pub next_cursor: Option<String>,
    /// Why some could not be read.
    pub warning: Option<String>,
    /// The head they were read at.
    pub head_sha: String,
    /// The base they were read at.
    pub base_sha: String,
}

impl From<core::ReviewThreadsPage> for ReviewThreadsPage {
    fn from(page: core::ReviewThreadsPage) -> Self {
        Self {
            threads: page.threads.into_iter().map(Into::into).collect(),
            has_more: page.has_more,
            next_cursor: page.next_cursor,
            warning: page.warning,
            head_sha: page.head_sha,
            base_sha: page.base_sha,
        }
    }
}

/// Where a new thread goes.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
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

impl From<ReviewAnchor> for core::ReviewAnchor {
    fn from(anchor: ReviewAnchor) -> Self {
        Self {
            path: anchor.path,
            side: anchor.side.into(),
            line: anchor.line,
            start_line: anchor.start_line,
            head_sha: anchor.head_sha,
            base_sha: anchor.base_sha,
        }
    }
}

/// Why `body` cannot be posted as a review comment; `None` when it can.
#[uniffi::export]
#[must_use]
pub fn review_comment_problem(body: String) -> Option<String> {
    core::review_comment_problem(&body)
}

#[uniffi::export]
impl ClientCore {
    /// A page of `pr_url`'s review threads: the first, or the one at `after_cursor` at the
    /// revision `head_sha`, `base_sha` the first page reported.
    ///
    /// # Errors
    ///
    /// As `pull_request_info`.
    pub async fn pull_request_review_threads(
        &self,
        session_id: String,
        pr_url: String,
        after_cursor: Option<String>,
        head_sha: String,
        base_sha: String,
    ) -> Result<ReviewThreadsPage, CoreError> {
        let after = after_cursor
            .as_deref()
            .map(|cursor| (cursor, head_sha.as_str(), base_sha.as_str()));
        self.sessions()
            .pull_request_review_threads(&session_id, &pr_url, after)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// The page of `thread_id`'s older comments at `cursor`.
    ///
    /// # Errors
    ///
    /// As `pull_request_info`.
    pub async fn review_thread_comments(
        &self,
        session_id: String,
        pr_url: String,
        thread_id: String,
        cursor: String,
    ) -> Result<ReviewCommentPage, CoreError> {
        self.sessions()
            .review_thread_comments(&session_id, &pr_url, &thread_id, &cursor)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Replies to `thread_id`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidInput` for a blank or too-long reply, and the write
    /// errors.
    pub async fn reply_to_review_thread(
        &self,
        session_id: String,
        pr_url: String,
        thread_id: String,
        body: String,
    ) -> Result<ReviewComment, CoreError> {
        self.sessions()
            .reply_to_review_thread(&session_id, &pr_url, &thread_id, &body)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Starts a review thread at `anchor`.
    ///
    /// # Errors
    ///
    /// As `reply_to_review_thread`.
    pub async fn create_review_thread(
        &self,
        session_id: String,
        pr_url: String,
        body: String,
        anchor: ReviewAnchor,
    ) -> Result<ReviewThread, CoreError> {
        self.sessions()
            .create_review_thread(&session_id, &pr_url, &body, &anchor.into())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}
