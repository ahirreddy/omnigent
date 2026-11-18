//! A pull request's changed files, patches and commits, read through the session's host.
//!
//! `GET …/resources/github/changes` lists the changed files and `…/github/diff` answers the whole
//! patch, both pinned to the revision the panel shows (`base_sha`, `head_sha`). `…/github/diff/
//! {path}` answers one file's text before and after, for expanding unchanged context. With
//! `commit_history`, `…/github/commits` lists the commits at the shown head, `…/github/commit-diff`
//! answers one commit's patch and `…/github/compare-diff` the changes after a commit up to the head.

use serde_json::{Map, Value};
use url::Url;

use super::{PullRequestPatch, decode_patch, each_object, github_resource};
use crate::client::json::{as_object, opt_bool, opt_str, opt_u64, req_str};
use crate::client::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// The most commits the server lists for one pull request (GitHub's own limit).
pub const PULL_REQUEST_COMMITS_LIMIT: u64 = 250;

/// What a commit read says when the server or host predates the commit routes.
pub const COMMITS_UNSUPPORTED: &str =
    "This Omnigent server doesn't support pull request commits. Update it to browse commits.";

/// What "Changes since" says when the server or host predates the compare route.
pub const COMPARE_UNSUPPORTED: &str =
    "Showing changes since a commit needs an updated Omnigent server and host.";

/// The revision a read is pinned to: the base and head the panel shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Revision<'a> {
    /// The base commit.
    pub base_sha: &'a str,
    /// The head commit.
    pub head_sha: &'a str,
}

/// How a file changed in the pull request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ChangedFileStatus {
    /// Added.
    Created,
    /// Changed in place.
    Modified,
    /// Removed.
    Deleted,
    /// Moved, possibly with changes.
    Renamed,
}

impl ChangedFileStatus {
    fn parse(value: Option<&str>) -> Self {
        match value {
            Some("created") => Self::Created,
            Some("deleted") => Self::Deleted,
            Some("renamed") => Self::Renamed,
            _ => Self::Modified,
        }
    }
}

/// One file the pull request changes, as the provider lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangedFile {
    /// The current path (the new name of a renamed file).
    pub path: String,
    /// How it changed.
    pub status: ChangedFileStatus,
    /// Added lines; `None` when the provider has no line counts.
    pub lines_added: Option<u64>,
    /// Removed lines; `None` when the provider has no line counts.
    pub lines_removed: Option<u64>,
    /// The old path of a renamed file.
    pub previous_path: Option<String>,
}

/// The pull request's changed files, as the Changes list shows them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PullRequestChanges {
    /// `false` when the session has no workspace to read them from.
    pub available: bool,
    /// The files, in the provider's order.
    pub files: Vec<ChangedFile>,
    /// The provider truncated the list.
    pub has_more: bool,
    /// Why the list may be incomplete.
    pub warning: Option<String>,
    /// The provider's total changed-file count, when known.
    pub total_count: Option<u64>,
    /// The head the list describes, when the read was pinned and verified.
    pub head_sha: Option<String>,
    /// The base the list describes, when the read was pinned and verified.
    pub base_sha: Option<String>,
}

/// One file's full text before and after the pull request, for expanding context.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PullRequestFileContents {
    /// The file.
    pub path: String,
    /// The text at the base; `None` for an added file.
    pub before: Option<String>,
    /// The text at the head; `None` for a deleted file.
    pub after: Option<String>,
}

/// Another pull request whose head is a commit, such as a stacked PR's parent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitHeadOf {
    /// Its number.
    pub number: u64,
    /// Its page.
    pub url: Option<String>,
    /// `OPEN`, `MERGED` or `CLOSED`.
    pub state: Option<String>,
}

/// One commit of the pull request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PullRequestCommit {
    /// The full commit id.
    pub sha: String,
    /// The first line of the message.
    pub title: String,
    /// The git author.
    pub author: Option<String>,
    /// The author date, ISO 8601.
    pub date: Option<String>,
    /// Other pull requests this commit heads.
    pub head_of: Vec<CommitHeadOf>,
}

/// The pull request's commits, oldest first.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PullRequestCommits {
    /// At most [`PULL_REQUEST_COMMITS_LIMIT`].
    pub commits: Vec<PullRequestCommit>,
    /// The pull request has more commits than listed.
    pub has_more: bool,
}

/// `pr_url`, plus the revision when both ends are known, as the web's `pinnedPrQuery`.
fn pinned_query(
    pr_url: Option<&str>,
    revision: Option<Revision<'_>>,
) -> Vec<(&'static str, String)> {
    let Some(url) = pr_url else {
        return Vec::new();
    };
    let mut query = vec![("pr_url", url.to_owned())];
    if let Some(revision) = revision
        && !revision.base_sha.is_empty()
        && !revision.head_sha.is_empty()
    {
        query.push(("base_sha", revision.base_sha.to_owned()));
        query.push(("head_sha", revision.head_sha.to_owned()));
    }
    query
}

fn malformed(path: &str) -> impl Fn(String) -> SessionError + '_ {
    move |detail| SessionError::MalformedResponse {
        detail: format!("{path}: {detail}"),
    }
}

/// Decodes a `/changes` body.
///
/// # Errors
///
/// A description of the first malformed field.
pub fn decode_changes(value: &Value) -> Result<PullRequestChanges, String> {
    let object = as_object(value, "changes")?;
    let files = each_object(object, "data")?
        .into_iter()
        .map(|file| {
            Ok(ChangedFile {
                path: req_str(file, "path")?,
                status: ChangedFileStatus::parse(opt_str(file, "status")?.as_deref()),
                lines_added: opt_u64(file, "lines_added")?,
                lines_removed: opt_u64(file, "lines_removed")?,
                previous_path: opt_str(file, "previous_path")?,
            })
        })
        .collect::<Result<_, String>>()?;
    Ok(PullRequestChanges {
        available: true,
        files,
        has_more: opt_bool(object, "has_more")?.unwrap_or(false),
        warning: opt_str(object, "warning")?.filter(|warning| !warning.is_empty()),
        total_count: opt_u64(object, "total_count")?,
        head_sha: opt_str(object, "head_sha")?,
        base_sha: opt_str(object, "base_sha")?,
    })
}

fn decode_head_of(commit: &Map<String, Value>) -> Result<Vec<CommitHeadOf>, String> {
    each_object(commit, "head_of")?
        .into_iter()
        .map(|pr| {
            Ok(CommitHeadOf {
                number: opt_u64(pr, "number")?.ok_or("`number` is missing")?,
                url: opt_str(pr, "url")?,
                state: opt_str(pr, "state")?,
            })
        })
        .collect()
}

/// Decodes a `/commits` body.
///
/// # Errors
///
/// A description of the first malformed field.
pub fn decode_commits(value: &Value) -> Result<PullRequestCommits, String> {
    let object = as_object(value, "commits")?;
    let commits = each_object(object, "data")?
        .into_iter()
        .map(|commit| {
            Ok(PullRequestCommit {
                sha: req_str(commit, "sha")?,
                title: opt_str(commit, "title")?.unwrap_or_default(),
                author: opt_str(commit, "author")?,
                date: opt_str(commit, "date")?,
                head_of: decode_head_of(commit)?,
            })
        })
        .collect::<Result<_, String>>()?;
    Ok(PullRequestCommits {
        commits,
        has_more: opt_bool(object, "has_more")?.unwrap_or(false),
    })
}

fn decode_file_contents(value: &Value) -> Result<PullRequestFileContents, String> {
    let object = as_object(value, "session.github.file_diff")?;
    Ok(PullRequestFileContents {
        path: req_str(object, "path")?,
        before: opt_str(object, "before")?,
        after: opt_str(object, "after")?,
    })
}

/// `path` as the file route's trailing segments, each escaped on its own so slashes stay
/// structural. An empty segment, `.` or `..` is refused, as the host refuses them.
fn file_segments(path: &str) -> Result<Vec<&str>, SessionError> {
    let segments: Vec<&str> = path.split('/').collect();
    if path.is_empty()
        || segments
            .iter()
            .any(|segment| segment.is_empty() || *segment == "." || *segment == "..")
    {
        return Err(SessionError::InvalidInput {
            reason: "That file path can't be read.".to_owned(),
        });
    }
    Ok(segments)
}

/// A read that the server answers `404` without the route: `Ok(None)`.
fn unless_missing<T>(result: Result<T, SessionError>) -> Result<Option<T>, SessionError> {
    match result {
        Ok(value) => Ok(Some(value)),
        Err(SessionError::Rejected { status: 404, .. }) => Ok(None),
        Err(error) => Err(error),
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// The pull request's changed files, pinned to `revision` when given. A session without a
    /// workspace answers an unavailable list, as the web's `fetchPullRequestChangedFiles`.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; [`SessionError::Rejected`] with
    /// the host's reason (a revision the PR moved past among them); [`SessionError::HostOffline`];
    /// the read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn pull_request_changes(
        &self,
        session_id: &str,
        pr_url: Option<&str>,
        revision: Option<Revision<'_>>,
    ) -> Result<PullRequestChanges, SessionError> {
        let result = async {
            let path = github_resource(session_id, "changes")?;
            match self
                .host_resource_read(&path, &pinned_query(pr_url, revision))
                .await
            {
                Ok(value) => decode_changes(&value).map_err(malformed(&path)),
                Err(SessionError::Rejected { status: 404, .. }) => {
                    Ok(PullRequestChanges::default())
                }
                Err(error) => Err(error),
            }
        }
        .await;
        self.dispatch();
        result
    }

    /// The whole of `pr_url` as one unified-diff patch, pinned to `revision` when given; the
    /// answer names the revision it was read at.
    ///
    /// # Errors
    ///
    /// As [`ClientCore::pull_request_changes`], with a `404` an error.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn pull_request_patch(
        &self,
        session_id: &str,
        pr_url: Option<&str>,
        revision: Option<Revision<'_>>,
    ) -> Result<PullRequestPatch, SessionError> {
        let result = async {
            let path = github_resource(session_id, "diff")?;
            let value = self
                .host_resource_read(&path, &pinned_query(pr_url, revision))
                .await?;
            decode_patch(&value).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }

    /// One file's text before and after the pull request, for expanding unchanged context.
    /// `base` names the base branch of a workspace without a tracked PR.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidInput`] for a path with empty, `.` or `..` segments; otherwise as
    /// [`ClientCore::pull_request_patch`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn pull_request_file_contents(
        &self,
        session_id: &str,
        file: &str,
        base: Option<&str>,
        pr_url: Option<&str>,
        previous_path: Option<&str>,
        revision: Option<Revision<'_>>,
    ) -> Result<PullRequestFileContents, SessionError> {
        let result = async {
            let path = github_resource(session_id, "diff")?;
            let segments = file_segments(file)?;
            let mut query: Vec<(&str, String)> = Vec::new();
            let mut put = |name: &'static str, value: Option<&str>| {
                if let Some(value) = value.filter(|value| !value.is_empty()) {
                    query.push((name, value.to_owned()));
                }
            };
            put("base", base);
            put("pr_url", pr_url);
            put("previous_path", previous_path);
            put("head_sha", revision.map(|revision| revision.head_sha));
            put("base_sha", revision.map(|revision| revision.base_sha));
            let value = self.host_resource_read_at(&path, &segments, &query).await?;
            decode_file_contents(&value).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }

    /// The pull request's commits at `head_sha`, oldest first; `None` when the server or host
    /// predates the commit routes (it answers `404`).
    ///
    /// # Errors
    ///
    /// As [`ClientCore::pull_request_patch`], except a `404`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn pull_request_commits(
        &self,
        session_id: &str,
        pr_url: &str,
        head_sha: &str,
    ) -> Result<Option<PullRequestCommits>, SessionError> {
        let result = async {
            let path = github_resource(session_id, "commits")?;
            let query = [
                ("pr_url", pr_url.to_owned()),
                ("head_sha", head_sha.to_owned()),
            ];
            let Some(value) = unless_missing(self.host_resource_read(&path, &query).await)? else {
                return Ok(None);
            };
            decode_commits(&value).map(Some).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }

    /// One commit's patch, read by its full id; `None` when the server or host predates the
    /// commit routes.
    ///
    /// # Errors
    ///
    /// As [`ClientCore::pull_request_commits`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn pull_request_commit_diff(
        &self,
        session_id: &str,
        pr_url: &str,
        commit_sha: &str,
    ) -> Result<Option<PullRequestPatch>, SessionError> {
        let result = async {
            let path = github_resource(session_id, "commit-diff")?;
            let query = [
                ("pr_url", pr_url.to_owned()),
                ("commit_sha", commit_sha.to_owned()),
            ];
            let Some(value) = unless_missing(self.host_resource_read(&path, &query).await)? else {
                return Ok(None);
            };
            decode_patch(&value).map(Some).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }

    /// The pull request's changes after `from_sha`, one of its commits, up to `head_sha`.
    ///
    /// # Errors
    ///
    /// As [`ClientCore::pull_request_patch`]; a server or host without the route is
    /// [`SessionError::Rejected`] with [`COMPARE_UNSUPPORTED`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn pull_request_compare_diff(
        &self,
        session_id: &str,
        pr_url: &str,
        from_sha: &str,
        head_sha: &str,
    ) -> Result<PullRequestPatch, SessionError> {
        let result = async {
            let path = github_resource(session_id, "compare-diff")?;
            let query = [
                ("pr_url", pr_url.to_owned()),
                ("head_sha", head_sha.to_owned()),
                ("from_sha", from_sha.to_owned()),
            ];
            let value = match self.host_resource_read(&path, &query).await {
                Err(SessionError::Rejected { status: 404, .. }) => {
                    return Err(SessionError::Rejected {
                        status: 404,
                        message: COMPARE_UNSUPPORTED.to_owned(),
                    });
                }
                other => other?,
            };
            decode_patch(&value).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }
}

/// `request`'s URL with `segments` appended, each percent-escaped as one path segment.
pub(super) fn append_segments(url: &str, segments: &[&str]) -> Result<String, SessionError> {
    let mut parsed = Url::parse(url).map_err(|error| SessionError::MalformedResponse {
        detail: format!("the request URL: {error}"),
    })?;
    parsed
        .path_segments_mut()
        .map_err(|()| SessionError::MalformedResponse {
            detail: "the request URL cannot carry a path".to_owned(),
        })?
        .extend(segments);
    Ok(parsed.into())
}
