//! A pull request's changed files, patches, file texts and commits, read through the session's
//! host. The decoding and pinning are `omnigent_core::pull_request_detail::changes`'.

use omnigent_core::pull_request_detail::changes as core;

use super::PullRequestPatch;
use crate::client::ClientCore;
use crate::errors::CoreError;

/// The most commits the server lists for one pull request.
#[uniffi::export]
#[must_use]
#[allow(
    clippy::missing_const_for_fn,
    reason = "UniFFI exports plain functions"
)]
pub fn pull_request_commits_limit() -> u64 {
    core::PULL_REQUEST_COMMITS_LIMIT
}

/// How a file changed in the pull request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum PullRequestFileStatus {
    /// Added.
    Created,
    /// Changed in place.
    Modified,
    /// Removed.
    Deleted,
    /// Moved.
    Renamed,
}

impl From<core::ChangedFileStatus> for PullRequestFileStatus {
    fn from(status: core::ChangedFileStatus) -> Self {
        match status {
            core::ChangedFileStatus::Created => Self::Created,
            core::ChangedFileStatus::Modified => Self::Modified,
            core::ChangedFileStatus::Deleted => Self::Deleted,
            core::ChangedFileStatus::Renamed => Self::Renamed,
        }
    }
}

/// One file the pull request changes.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PullRequestChangedFile {
    /// The current path.
    pub path: String,
    /// How it changed.
    pub status: PullRequestFileStatus,
    /// Added lines, when the provider counts them.
    pub lines_added: Option<u64>,
    /// Removed lines, when the provider counts them.
    pub lines_removed: Option<u64>,
    /// The old path of a renamed file.
    pub previous_path: Option<String>,
}

/// The pull request's changed files.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PullRequestChanges {
    /// `false` when the session has no workspace to read them from.
    pub available: bool,
    /// The files, in the provider's order.
    pub files: Vec<PullRequestChangedFile>,
    /// The provider truncated the list.
    pub has_more: bool,
    /// Why the list may be incomplete.
    pub warning: Option<String>,
    /// The provider's total, when known.
    pub total_count: Option<u64>,
    /// The head the list describes, when pinned.
    pub head_sha: Option<String>,
    /// The base the list describes, when pinned.
    pub base_sha: Option<String>,
}

impl From<core::PullRequestChanges> for PullRequestChanges {
    fn from(changes: core::PullRequestChanges) -> Self {
        Self {
            available: changes.available,
            files: changes
                .files
                .into_iter()
                .map(|file| PullRequestChangedFile {
                    path: file.path,
                    status: file.status.into(),
                    lines_added: file.lines_added,
                    lines_removed: file.lines_removed,
                    previous_path: file.previous_path,
                })
                .collect(),
            has_more: changes.has_more,
            warning: changes.warning,
            total_count: changes.total_count,
            head_sha: changes.head_sha,
            base_sha: changes.base_sha,
        }
    }
}

/// One file's full text before and after the pull request.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PullRequestFileContents {
    /// The file.
    pub path: String,
    /// The text at the base; `None` for an added file.
    pub before: Option<String>,
    /// The text at the head; `None` for a deleted file.
    pub after: Option<String>,
}

/// Another pull request a commit heads, such as a stacked PR's parent.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct CommitHeadOf {
    /// Its number.
    pub number: u64,
    /// Its page.
    pub url: Option<String>,
    /// `OPEN`, `MERGED` or `CLOSED`.
    pub state: Option<String>,
}

/// One commit of the pull request.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PullRequestCommit {
    /// The full id.
    pub sha: String,
    /// The first line of the message.
    pub title: String,
    /// The git author.
    pub author: Option<String>,
    /// The author date, ISO 8601.
    pub date: Option<String>,
    /// Other pull requests it heads.
    pub head_of: Vec<CommitHeadOf>,
}

/// The pull request's commits, oldest first.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PullRequestCommits {
    /// The commits.
    pub commits: Vec<PullRequestCommit>,
    /// It has more than listed.
    pub has_more: bool,
}

impl From<core::PullRequestCommits> for PullRequestCommits {
    fn from(commits: core::PullRequestCommits) -> Self {
        Self {
            commits: commits
                .commits
                .into_iter()
                .map(|commit| PullRequestCommit {
                    sha: commit.sha,
                    title: commit.title,
                    author: commit.author,
                    date: commit.date,
                    head_of: commit
                        .head_of
                        .into_iter()
                        .map(|pr| CommitHeadOf {
                            number: pr.number,
                            url: pr.url,
                            state: pr.state,
                        })
                        .collect(),
                })
                .collect(),
            has_more: commits.has_more,
        }
    }
}

/// The revision both ends name, or none.
fn revision<'a>(
    base_sha: Option<&'a str>,
    head_sha: Option<&'a str>,
) -> Option<core::Revision<'a>> {
    Some(core::Revision {
        base_sha: base_sha?,
        head_sha: head_sha?,
    })
}

#[uniffi::export]
impl ClientCore {
    /// The pull request's changed files, pinned to `base_sha`..`head_sha` when both are given.
    /// A session without a workspace answers an unavailable list.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, `Rejected` with the host's reason,
    /// `HostOffline`, the read errors and `MalformedResponse`.
    pub async fn pull_request_changes(
        &self,
        session_id: String,
        pr_url: Option<String>,
        base_sha: Option<String>,
        head_sha: Option<String>,
    ) -> Result<PullRequestChanges, CoreError> {
        self.sessions()
            .pull_request_changes(
                &session_id,
                pr_url.as_deref(),
                revision(base_sha.as_deref(), head_sha.as_deref()),
            )
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// The whole of `pr_url` as one unified-diff patch, pinned as `pull_request_changes` is.
    ///
    /// # Errors
    ///
    /// As `pull_request_changes`, with a `404` an error.
    pub async fn pull_request_patch(
        &self,
        session_id: String,
        pr_url: Option<String>,
        base_sha: Option<String>,
        head_sha: Option<String>,
    ) -> Result<PullRequestPatch, CoreError> {
        self.sessions()
            .pull_request_patch(
                &session_id,
                pr_url.as_deref(),
                revision(base_sha.as_deref(), head_sha.as_deref()),
            )
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// One file's full text before and after the pull request, for expanding context.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidInput` for a path with empty, `.` or `..` segments;
    /// otherwise as `pull_request_patch`.
    #[allow(
        clippy::too_many_arguments,
        reason = "the route's query parameters, each optional"
    )]
    pub async fn pull_request_file_contents(
        &self,
        session_id: String,
        path: String,
        base: Option<String>,
        pr_url: Option<String>,
        previous_path: Option<String>,
        base_sha: Option<String>,
        head_sha: Option<String>,
    ) -> Result<PullRequestFileContents, CoreError> {
        let contents = self
            .sessions()
            .pull_request_file_contents(
                &session_id,
                &path,
                base.as_deref(),
                pr_url.as_deref(),
                previous_path.as_deref(),
                revision(base_sha.as_deref(), head_sha.as_deref()),
            )
            .await
            .map_err(CoreError::from)?;
        Ok(PullRequestFileContents {
            path: contents.path,
            before: contents.before,
            after: contents.after,
        })
    }

    /// The pull request's commits at `head_sha`, oldest first; `None` when the server or host
    /// predates the commit routes.
    ///
    /// # Errors
    ///
    /// As `pull_request_patch`, except a `404`.
    pub async fn pull_request_commits(
        &self,
        session_id: String,
        pr_url: String,
        head_sha: String,
    ) -> Result<Option<PullRequestCommits>, CoreError> {
        self.sessions()
            .pull_request_commits(&session_id, &pr_url, &head_sha)
            .await
            .map(|commits| commits.map(Into::into))
            .map_err(CoreError::from)
    }

    /// One commit's patch; `None` when the server or host predates the commit routes.
    ///
    /// # Errors
    ///
    /// As `pull_request_commits`.
    pub async fn pull_request_commit_diff(
        &self,
        session_id: String,
        pr_url: String,
        commit_sha: String,
    ) -> Result<Option<PullRequestPatch>, CoreError> {
        self.sessions()
            .pull_request_commit_diff(&session_id, &pr_url, &commit_sha)
            .await
            .map(|patch| patch.map(Into::into))
            .map_err(CoreError::from)
    }

    /// The pull request's changes after `from_sha` up to `head_sha`.
    ///
    /// # Errors
    ///
    /// As `pull_request_patch`; a server or host without the route is `Rejected` saying so.
    pub async fn pull_request_compare_diff(
        &self,
        session_id: String,
        pr_url: String,
        from_sha: String,
        head_sha: String,
    ) -> Result<PullRequestPatch, CoreError> {
        self.sessions()
            .pull_request_compare_diff(&session_id, &pr_url, &from_sha, &head_sha)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}
