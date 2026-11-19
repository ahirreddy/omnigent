//! Local review comments: comments for the session's agent on lines of a pull request's diff.
//!
//! Also the text a message carries for the ones the composer attaches. The decoding and checks
//! are `omnigent_core::comments`'.

use omnigent_core::comments as core;

use crate::client::ClientCore;
use crate::errors::CoreError;
use crate::pull_request_detail::reviews::ReviewSide;

/// Where a local review comment sits on the diff, and the revision it was written at.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ReviewCommentAnchor {
    /// The pull request.
    pub pr_url: String,
    /// The side of the diff.
    pub side: ReviewSide,
    /// The last line.
    pub line: u64,
    /// The first line of a range.
    pub start_line: Option<u64>,
    /// The head it was written at.
    pub head_sha: String,
    /// The base it was written at.
    pub base_sha: String,
}

impl From<core::ReviewCommentAnchor> for ReviewCommentAnchor {
    fn from(anchor: core::ReviewCommentAnchor) -> Self {
        Self {
            pr_url: anchor.pr_url,
            side: anchor.side.into(),
            line: anchor.line,
            start_line: anchor.start_line,
            head_sha: anchor.head_sha,
            base_sha: anchor.base_sha,
        }
    }
}

impl From<ReviewCommentAnchor> for core::ReviewCommentAnchor {
    fn from(anchor: ReviewCommentAnchor) -> Self {
        Self {
            pr_url: anchor.pr_url,
            side: anchor.side.into(),
            line: anchor.line,
            start_line: anchor.start_line,
            head_sha: anchor.head_sha,
            base_sha: anchor.base_sha,
        }
    }
}

/// A comment for the session's agent on lines of a pull request's diff.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct LocalReviewComment {
    /// Id.
    pub id: String,
    /// The session.
    pub session_id: String,
    /// The file.
    pub path: String,
    /// The server's character range start, unused for diff comments.
    pub start_index: u64,
    /// Its end.
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

impl From<core::LocalReviewComment> for LocalReviewComment {
    fn from(comment: core::LocalReviewComment) -> Self {
        Self {
            id: comment.id,
            session_id: comment.session_id,
            path: comment.path,
            start_index: comment.start_index,
            end_index: comment.end_index,
            body: comment.body,
            status: comment.status,
            created_at: comment.created_at,
            updated_at: comment.updated_at,
            anchor_content: comment.anchor_content,
            author: comment.author,
            anchor: comment.anchor.into(),
        }
    }
}

impl From<LocalReviewComment> for core::LocalReviewComment {
    fn from(comment: LocalReviewComment) -> Self {
        Self {
            id: comment.id,
            session_id: comment.session_id,
            path: comment.path,
            start_index: comment.start_index,
            end_index: comment.end_index,
            body: comment.body,
            status: comment.status,
            created_at: comment.created_at,
            updated_at: comment.updated_at,
            anchor_content: comment.anchor_content,
            author: comment.author,
            anchor: comment.anchor.into(),
        }
    }
}

/// The text a message sends for `comments`, as the web's `formatLocalReviewComments`: an
/// instruction unless the message has its own text, then each comment's snapshot in a fence.
#[uniffi::export]
#[must_use]
pub fn format_local_review_comments(
    comments: Vec<LocalReviewComment>,
    include_instruction: bool,
) -> String {
    let comments: Vec<core::LocalReviewComment> = comments.into_iter().map(Into::into).collect();
    core::format_local_review_comments(&comments, include_instruction)
}

#[uniffi::export]
impl ClientCore {
    /// The session's review comments on pull request diffs, oldest first.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors, `InvalidPagination` and
    /// `MalformedResponse`.
    pub async fn session_review_comments(
        &self,
        session_id: String,
    ) -> Result<Vec<LocalReviewComment>, CoreError> {
        self.sessions()
            .session_review_comments(&session_id)
            .await
            .map(|comments| comments.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// Leaves a comment for the session's agent at `anchor`; a server that loses the place has
    /// the comment deleted again.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, `InvalidInput` for an empty comment, the
    /// write errors, and `Rejected` when the server did not keep the place.
    pub async fn add_review_comment(
        &self,
        session_id: String,
        path: String,
        body: String,
        anchor: ReviewCommentAnchor,
    ) -> Result<LocalReviewComment, CoreError> {
        self.sessions()
            .add_review_comment(&session_id, &path, &body, &anchor.into())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}
