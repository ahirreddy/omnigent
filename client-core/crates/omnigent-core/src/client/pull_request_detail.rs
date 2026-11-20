//! One pull request's live detail, read from the session's host through the server.
//!
//! `GET /v1/sessions/{id}/resources/github[?pr_url=]` answers `session.github.info`; its changed
//! files, patches and commits are [`changes`]'. Every git provider answers under the `github` name.
//!
//! The host answers these, so they fail while it is offline: a `503` whose `error.code` is
//! `runner_unavailable` reads as [`SessionError::HostOffline`] with [`HOST_OFFLINE`]. A `404` from
//! the info route means the session has no workspace (or a host older than the route), which
//! [`PullRequestInfo`] reports as [`PullRequestAvailability::Unavailable`] rather than an error.

use serde_json::{Map, Value};

use super::json::{as_object, opt_array, opt_bool, opt_object, opt_str, opt_u64, req_str};
use super::pull_requests::{PullRequestStatus, SessionPullRequest};
use super::requests::{rejection_message, validate_identifier};
use super::{ClientCore, SessionError, lock};
use crate::auth::mode::error_text;
use crate::http::{HttpTransport, TransportError};

#[path = "pull_request_changes.rs"]
pub mod changes;
#[path = "pull_request_polling.rs"]
pub mod polling;
#[path = "pull_request_reviews.rs"]
pub mod reviews;

use polling::PullRequestPolling;

/// What a read that needs the session's host says while the host is offline.
pub const HOST_OFFLINE: &str =
    "The session's host is offline. Send a message to reconnect it, then refresh.";

/// Where a pull request stands, as the web's status chip names it. Merge conflicts and failing
/// checks lead because they need the user.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PullRequestCondition {
    /// GitHub reports merge conflicts.
    Conflict,
    /// A check failed.
    ChecksFailing,
    /// Checks passed and GitHub reports the PR mergeable.
    Ready,
    /// Checks are still running.
    ChecksRunning,
    /// Open, with nothing more known.
    Open,
    /// Open as a draft.
    Draft,
    /// The state is not known.
    Unknown,
    /// Merged.
    Merged,
    /// Closed without merging.
    Closed,
}

impl PullRequestCondition {
    /// Sort order: what needs the user first.
    #[must_use]
    pub const fn priority(self) -> u8 {
        match self {
            Self::Conflict => 0,
            Self::ChecksFailing => 1,
            Self::Ready => 2,
            Self::ChecksRunning => 3,
            Self::Open => 4,
            Self::Draft => 5,
            Self::Unknown => 6,
            Self::Merged => 7,
            Self::Closed => 8,
        }
    }

    /// The condition of a stored PR, which carries no checks or merge state.
    #[must_use]
    pub const fn of_stored(status: PullRequestStatus) -> Self {
        match status {
            PullRequestStatus::Open => Self::Open,
            PullRequestStatus::Draft => Self::Draft,
            PullRequestStatus::Merged => Self::Merged,
            PullRequestStatus::Closed => Self::Closed,
            PullRequestStatus::Unknown => Self::Unknown,
        }
    }
}

/// Which bucket a CI check fell in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CheckBucket {
    /// Passed.
    Passing,
    /// Failed.
    Failing,
    /// Queued or running.
    Pending,
    /// Cancelled.
    Cancelled,
    /// Skipped.
    Skipped,
}

/// One CI check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckRun {
    /// The job name.
    pub name: String,
    /// Its bucket.
    pub bucket: CheckBucket,
    /// Its page, when known.
    pub url: Option<String>,
}

/// The PR's CI checks.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PullRequestChecks {
    /// Passed.
    pub passing: u64,
    /// Failed.
    pub failing: u64,
    /// Running.
    pub pending: u64,
    /// Cancelled.
    pub cancelled: u64,
    /// Skipped.
    pub skipped: u64,
    /// All of them.
    pub total: u64,
    /// Some checks could not be read; the counts cover the rest.
    pub partial: bool,
    /// Each check.
    pub runs: Vec<CheckRun>,
}

/// A top-level conversation comment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PullRequestComment {
    /// The author's login.
    pub author: Option<String>,
    /// Markdown.
    pub body: String,
    /// ISO-8601 creation time.
    pub created_at: Option<String>,
    /// The comment's page.
    pub url: Option<String>,
}

/// What a timeline event records.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TimelineEventKind {
    /// A commit on the PR's branch.
    Commit,
    /// A force push, from the head before it.
    ForcePush {
        /// The head the push replaced.
        previous_sha: Option<String>,
    },
}

/// A commit or force push in the PR's activity.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PullRequestTimelineEvent {
    /// Stable id.
    pub id: String,
    /// Commit or force push.
    pub kind: TimelineEventKind,
    /// Who made it.
    pub author: Option<String>,
    /// ISO-8601: the commit time, or the push time.
    pub created_at: Option<String>,
    /// The commit or push on the provider.
    pub url: Option<String>,
    /// The commit.
    pub sha: Option<String>,
    /// The commit message.
    pub message: Option<String>,
}

/// A user or a team.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ReviewerKind {
    /// A user, by login.
    User,
    /// A team, by slug.
    Team,
}

/// Where a reviewer's review stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ReviewState {
    /// Requested, not reviewed yet.
    Pending,
    /// Approved.
    Approved,
    /// Commented.
    Commented,
    /// Asked for changes.
    ChangesRequested,
    /// The review was dismissed.
    Dismissed,
}

/// A reviewer on the PR.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PullRequestReviewer {
    /// Login or team slug.
    pub login: String,
    /// User or team.
    pub kind: ReviewerKind,
    /// Their review.
    pub state: ReviewState,
}

/// A label on the PR or offered by its repository.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PullRequestLabel {
    /// The name.
    pub name: String,
    /// Six hex digits without `#`.
    pub color: Option<String>,
    /// What it means.
    pub description: Option<String>,
}

/// Auto-merge, when it is on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutoMerge {
    /// The provider's method name, for example `SQUASH`.
    pub merge_method: Option<String>,
    /// Who turned it on.
    pub enabled_by: Option<String>,
}

/// The selected PR as the host read it from its provider.
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts the host reports about one PR"
)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PullRequestDetail {
    /// The number.
    pub number: u64,
    /// The title.
    pub title: String,
    /// The PR page.
    pub url: String,
    /// Open, draft, merged or closed.
    pub status: PullRequestStatus,
    /// The status chip's condition, from the state, checks and merge state.
    pub condition: PullRequestCondition,
    /// The author's login.
    pub author: Option<String>,
    /// The branch merged into.
    pub base_ref: Option<String>,
    /// The PR's branch.
    pub head_ref: Option<String>,
    /// The head commit, which a merge must still match.
    pub head_sha: Option<String>,
    /// The base commit the PR's diff is against.
    pub base_sha: Option<String>,
    /// The web page of the source (possibly fork) repository; `None` when unknown or deleted.
    pub head_repository_url: Option<String>,
    /// Markdown description.
    pub body: Option<String>,
    /// CI.
    pub checks: PullRequestChecks,
    /// `false` when the signed-in account cannot read checks.
    pub checks_supported: bool,
    /// Conversation comments, oldest first.
    pub comments: Vec<PullRequestComment>,
    /// Some comments could not be read.
    pub comments_partial: bool,
    /// Commits and force pushes, oldest first; empty from hosts that do not report them.
    pub timeline_events: Vec<PullRequestTimelineEvent>,
    /// Some commit and push history could not be read.
    pub timeline_partial: bool,
    /// Reviewers; `None` when the host does not report them.
    pub reviewers: Option<Vec<PullRequestReviewer>>,
    /// Labels; `None` when the host does not report them.
    pub labels: Option<Vec<PullRequestLabel>>,
    /// GitHub's `mergeStateStatus` (`CLEAN`, `BLOCKED`, …); `None` when not reported.
    pub merge_state_status: Option<String>,
    /// Whether the host reports a merge state at all (it can merge from the panel).
    pub reports_merge_state: bool,
    /// Auto-merge, when on.
    pub auto_merge: Option<AutoMerge>,
}

/// What the panel can do with the selected PR. A host that predates `capabilities` is GitHub
/// with its account picker, base-remote choice, line counts and linked-PR diff, as on the web.
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent capability flags the host reports"
)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PullRequestCapabilities {
    /// Labels can be added and removed.
    pub label_editing: bool,
    /// The PR can be merged and auto-merge turned off.
    pub merging: bool,
    /// Conversation comments can be posted.
    pub comment_posting: bool,
    /// Reviews can be requested and withdrawn.
    pub reviewer_editing: bool,
    /// The title and description can be edited.
    pub details_editing: bool,
    /// Images and videos can be uploaded into the description.
    pub attachment_uploads: bool,
    /// Inline review threads can be read.
    pub review_threads: bool,
    /// Review threads can be replied to.
    pub review_thread_replies: bool,
    /// Review threads can be started on the diff.
    pub review_thread_creation: bool,
    /// The PR's commits can be listed and read one at a time.
    pub commit_history: bool,
    /// The changed files carry line counts.
    pub line_counts: bool,
    /// A linked PR outside the workspace branch can be diffed.
    pub linked_pr_diff: bool,
    /// The provider account can be switched.
    pub account_switching: bool,
    /// The base remote can be chosen.
    pub base_remote_selection: bool,
    /// A merge can run as a chosen account.
    pub merge_as_account: bool,
}

impl PullRequestCapabilities {
    /// What a host that sends no `capabilities` offers.
    const LEGACY_GITHUB: Self = Self {
        label_editing: false,
        merging: false,
        comment_posting: false,
        reviewer_editing: false,
        details_editing: false,
        attachment_uploads: false,
        review_threads: false,
        review_thread_replies: false,
        review_thread_creation: false,
        commit_history: false,
        line_counts: true,
        linked_pr_diff: true,
        account_switching: true,
        base_remote_selection: true,
        merge_as_account: false,
    };

    fn decode(object: Option<&Map<String, Value>>) -> Result<Self, String> {
        let Some(caps) = object else {
            return Ok(Self::LEGACY_GITHUB);
        };
        let flag = |key: &str| opt_bool(caps, key).map(Option::unwrap_or_default);
        Ok(Self {
            label_editing: flag("label_editing")?,
            merging: flag("merging")?,
            comment_posting: flag("comment_posting")?,
            reviewer_editing: flag("reviewer_editing")?,
            details_editing: flag("details_editing")?,
            attachment_uploads: flag("attachment_uploads")?,
            review_threads: flag("review_threads")?,
            review_thread_replies: flag("review_thread_replies")?,
            review_thread_creation: flag("review_thread_creation")?,
            commit_history: flag("commit_history")?,
            line_counts: flag("line_counts")?,
            linked_pr_diff: flag("linked_pr_diff")?,
            account_switching: flag("account_switching")?,
            base_remote_selection: flag("base_remote_selection")?,
            merge_as_account: flag("merge_as_account")?,
        })
    }
}

/// Why there is no PR to show, or that there is one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PullRequestAvailability {
    /// [`PullRequestInfo::pull_request`] is set.
    Ready,
    /// The workspace branch has no PR yet.
    NoPullRequest,
    /// The workspace is not a git checkout.
    NotAGitRepository,
    /// The host predates the pull request route.
    HostOutdated,
    /// No supported provider serves the workspace's remote.
    UnsupportedRemote {
        /// The remote's host, when known.
        remote_host: Option<String>,
    },
    /// The provider's CLI is missing and nothing is signed in.
    NoCli {
        /// The CLI's name, for example `gh`.
        cli: String,
    },
    /// Not signed in to the provider, or the upstream repository cannot be read.
    RepositoryUnresolved {
        /// Sign-in guidance from the host.
        hint: Option<String>,
    },
    /// Nothing to show (no workspace, or the provider failed; see the warnings).
    Unavailable,
}

/// An account the provider's CLI is signed in as on the host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PullRequestAccount {
    /// The login.
    pub login: String,
    /// The CLI's active account for the host.
    pub active: bool,
}

/// `session.github.info`: the session's linked PRs, the selected one's detail, and what the
/// panel can do with it.
#[derive(Debug, Clone, PartialEq)]
pub struct PullRequestInfo {
    /// Whether there is a PR to show, or why not.
    pub availability: PullRequestAvailability,
    /// The provider's id (`github`, `gitlab`, `azure_devops`); `None` when no provider serves
    /// the workspace. A host that predates the field serves GitHub.
    pub provider: Option<String>,
    /// The provider's name ("GitHub").
    pub provider_name: Option<String>,
    /// What precedes a PR number: `#`, or `!` on Azure DevOps.
    pub number_prefix: String,
    /// The workspace branch, or the PR's head.
    pub branch: Option<String>,
    /// `owner/name`.
    pub repository: Option<String>,
    /// The PR's base branch.
    pub base_ref: Option<String>,
    /// The PR the detail is for.
    pub selected_url: Option<String>,
    /// The host links and unlinks PRs per session.
    pub tracking_available: bool,
    /// The session's linked PRs.
    pub linked: Vec<SessionPullRequest>,
    /// Provider warnings to show above the panel.
    pub warnings: Vec<String>,
    /// What the panel can change.
    pub capabilities: PullRequestCapabilities,
    /// The selected PR.
    pub pull_request: Option<PullRequestDetail>,
    /// How often readers of this info re-read it.
    pub polling: PullRequestPolling,
    /// The accounts the provider's CLI is signed in as; empty when the host lists none.
    pub accounts: Vec<PullRequestAccount>,
    /// The account the host reads and writes this PR as.
    pub selected_account: Option<String>,
    /// What the provider calls a PR ("merge request"); `None` for GitHub's "pull request".
    pub request_name: Option<String>,
}

/// A patch of the selected PR: the whole PR, one commit, or the changes since a commit.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PullRequestPatch {
    /// One unified diff; empty when there are no changes.
    pub patch: String,
    /// Why the host cannot diff it, already worded for the reader.
    pub unavailable: Option<String>,
    /// The head the patch was read at, when the host names it.
    pub head_sha: Option<String>,
    /// The base the patch was read at, when the host names it.
    pub base_sha: Option<String>,
}

fn reviewer_kind(value: Option<&str>) -> ReviewerKind {
    if value == Some("team") {
        ReviewerKind::Team
    } else {
        ReviewerKind::User
    }
}

fn review_state(value: Option<&str>) -> ReviewState {
    match value {
        Some("APPROVED") => ReviewState::Approved,
        Some("COMMENTED") => ReviewState::Commented,
        Some("CHANGES_REQUESTED") => ReviewState::ChangesRequested,
        Some("DISMISSED") => ReviewState::Dismissed,
        _ => ReviewState::Pending,
    }
}

fn check_bucket(value: &str) -> Option<CheckBucket> {
    match value {
        "passing" => Some(CheckBucket::Passing),
        "failing" => Some(CheckBucket::Failing),
        "pending" => Some(CheckBucket::Pending),
        "cancelled" => Some(CheckBucket::Cancelled),
        "skipped" => Some(CheckBucket::Skipped),
        _ => None,
    }
}

fn each_object<'a>(
    object: &'a Map<String, Value>,
    key: &str,
) -> Result<Vec<&'a Map<String, Value>>, String> {
    opt_array(object, key)?
        .into_iter()
        .flatten()
        .map(|value| as_object(value, key))
        .collect()
}

fn decode_checks(object: Option<&Map<String, Value>>) -> Result<PullRequestChecks, String> {
    let Some(object) = object else {
        return Ok(PullRequestChecks::default());
    };
    let count = |key: &str| opt_u64(object, key).map(Option::unwrap_or_default);
    let mut runs = Vec::new();
    for run in each_object(object, "runs")? {
        let bucket = opt_str(run, "bucket")?;
        // A bucket this client does not know stays out of every count's breakdown.
        if let Some(bucket) = bucket.as_deref().and_then(check_bucket) {
            runs.push(CheckRun {
                name: opt_str(run, "name")?.unwrap_or_default(),
                bucket,
                url: opt_str(run, "url")?,
            });
        }
    }
    Ok(PullRequestChecks {
        passing: count("passing")?,
        failing: count("failing")?,
        pending: count("pending")?,
        cancelled: count("cancelled")?,
        skipped: count("skipped")?,
        total: count("total")?,
        partial: opt_bool(object, "partial")?.unwrap_or(false),
        runs,
    })
}

/// Decodes the labels of a PR or a repository.
///
/// # Errors
///
/// A description of the first malformed label.
pub fn decode_labels(
    object: &Map<String, Value>,
    key: &str,
) -> Result<Vec<PullRequestLabel>, String> {
    each_object(object, key)?
        .into_iter()
        .map(|label| {
            Ok(PullRequestLabel {
                name: req_str(label, "name")?,
                color: opt_str(label, "color")?,
                description: opt_str(label, "description")?,
            })
        })
        .collect()
}

/// Decodes a PR's reviewers.
///
/// # Errors
///
/// A description of the first malformed reviewer.
pub fn decode_reviewers(
    object: &Map<String, Value>,
    key: &str,
) -> Result<Vec<PullRequestReviewer>, String> {
    each_object(object, key)?
        .into_iter()
        .map(|reviewer| {
            Ok(PullRequestReviewer {
                login: req_str(reviewer, "login")?,
                kind: reviewer_kind(opt_str(reviewer, "kind")?.as_deref()),
                state: review_state(opt_str(reviewer, "state")?.as_deref()),
            })
        })
        .collect()
}

/// Decodes one conversation comment.
///
/// # Errors
///
/// A description of the first malformed field.
pub fn decode_comment(comment: &Map<String, Value>) -> Result<PullRequestComment, String> {
    Ok(PullRequestComment {
        author: opt_str(comment, "author")?,
        body: opt_str(comment, "body")?.unwrap_or_default(),
        created_at: opt_str(comment, "created_at")?,
        url: opt_str(comment, "url")?,
    })
}

/// Decodes the PR's commits and force pushes; an event of a kind this client does not know is
/// left out.
fn decode_timeline(object: &Map<String, Value>) -> Result<Vec<PullRequestTimelineEvent>, String> {
    let mut events = Vec::new();
    for event in each_object(object, "timeline_events")? {
        let kind = match opt_str(event, "kind")?.as_deref() {
            Some("commit") => TimelineEventKind::Commit,
            Some("force_push") => TimelineEventKind::ForcePush {
                previous_sha: opt_str(event, "previous_sha")?,
            },
            _ => continue,
        };
        events.push(PullRequestTimelineEvent {
            id: req_str(event, "id")?,
            kind,
            author: opt_str(event, "author")?,
            created_at: opt_str(event, "created_at")?,
            url: opt_str(event, "url")?,
            sha: opt_str(event, "sha")?,
            message: opt_str(event, "message")?,
        });
    }
    Ok(events)
}

/// The web's status rule: conflicts, then failing checks, then draft, running checks, and
/// ready only when GitHub reports the PR cleanly mergeable with every check read.
fn condition(detail: &PullRequestDetail) -> PullRequestCondition {
    match detail.status {
        PullRequestStatus::Merged => return PullRequestCondition::Merged,
        PullRequestStatus::Closed => return PullRequestCondition::Closed,
        PullRequestStatus::Unknown => return PullRequestCondition::Unknown,
        PullRequestStatus::Open | PullRequestStatus::Draft => {}
    }
    let merge_state = detail
        .merge_state_status
        .as_deref()
        .map(str::to_ascii_uppercase);
    if merge_state.as_deref() == Some("DIRTY") {
        return PullRequestCondition::Conflict;
    }
    if detail.checks.failing > 0 {
        return PullRequestCondition::ChecksFailing;
    }
    if detail.status == PullRequestStatus::Draft {
        return PullRequestCondition::Draft;
    }
    if detail.checks.pending > 0 {
        return PullRequestCondition::ChecksRunning;
    }
    if merge_state.as_deref() == Some("CLEAN") && !detail.checks.partial && detail.checks_supported
    {
        return PullRequestCondition::Ready;
    }
    PullRequestCondition::Open
}

impl PullRequestDetail {
    /// Decodes the info payload's `pr`.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "pr")?;
        let number = opt_u64(object, "number")?.ok_or_else(|| "`number` is missing".to_owned())?;
        let is_draft = opt_bool(object, "is_draft")?.unwrap_or(false);
        let auto_merge = opt_object(object, "auto_merge")?
            .map(|auto| -> Result<AutoMerge, String> {
                Ok(AutoMerge {
                    merge_method: opt_str(auto, "merge_method")?,
                    enabled_by: opt_str(auto, "enabled_by")?,
                })
            })
            .transpose()?;
        let mut detail = Self {
            number,
            title: opt_str(object, "title")?.unwrap_or_default(),
            url: req_str(object, "url")?,
            status: PullRequestStatus::of(opt_str(object, "state")?.as_deref(), is_draft),
            condition: PullRequestCondition::Unknown,
            author: opt_str(object, "author")?,
            base_ref: opt_str(object, "base_ref")?,
            head_ref: opt_str(object, "head_ref")?,
            head_sha: opt_str(object, "head_sha")?,
            base_sha: opt_str(object, "base_sha")?,
            head_repository_url: opt_str(object, "head_repository_url")?,
            body: opt_str(object, "body")?.filter(|body| !body.trim().is_empty()),
            checks: decode_checks(opt_object(object, "checks")?)?,
            checks_supported: opt_bool(object, "checks_supported")?.unwrap_or(true),
            comments: each_object(object, "comments")?
                .into_iter()
                .map(decode_comment)
                .collect::<Result<_, _>>()?,
            comments_partial: opt_bool(object, "comments_partial")?.unwrap_or(false),
            timeline_events: decode_timeline(object)?,
            timeline_partial: opt_bool(object, "timeline_partial")?.unwrap_or(false),
            reviewers: object
                .contains_key("reviewers")
                .then(|| decode_reviewers(object, "reviewers"))
                .transpose()?,
            labels: object
                .contains_key("labels")
                .then(|| decode_labels(object, "labels"))
                .transpose()?,
            merge_state_status: opt_str(object, "merge_state_status")?,
            reports_merge_state: object.contains_key("merge_state_status"),
            auto_merge,
        };
        detail.condition = condition(&detail);
        Ok(detail)
    }
}

fn availability(
    object: &Map<String, Value>,
    pull_request: Option<&PullRequestDetail>,
    warnings: bool,
) -> Result<PullRequestAvailability, String> {
    if !opt_bool(object, "available")?.unwrap_or(false) {
        return Ok(match opt_str(object, "reason")?.as_deref() {
            Some("not_a_git_repo") => PullRequestAvailability::NotAGitRepository,
            Some("host_outdated") => PullRequestAvailability::HostOutdated,
            Some("unsupported_remote") => PullRequestAvailability::UnsupportedRemote {
                remote_host: opt_str(object, "remote_host")?,
            },
            _ => PullRequestAvailability::Unavailable,
        });
    }
    // Hosts before `auth` send the legacy GitHub fields; only an explicit false signs out.
    let auth = opt_object(object, "auth")?;
    let authenticated = match auth {
        Some(auth) => opt_bool(auth, "authenticated")?.unwrap_or(false),
        None => {
            opt_bool(object, "authenticated")? != Some(false)
                && opt_bool(object, "gh_available")? != Some(false)
        }
    };
    let cli = match auth
        .map(|auth| opt_object(auth, "cli"))
        .transpose()?
        .flatten()
    {
        Some(cli) => Some((
            opt_str(cli, "name")?.unwrap_or_default(),
            opt_bool(cli, "available")?.unwrap_or(true),
        )),
        None => opt_bool(object, "gh_available")?.map(|available| ("gh".to_owned(), available)),
    };
    if let Some((name, false)) = cli
        && !authenticated
    {
        return Ok(PullRequestAvailability::NoCli { cli: name });
    }
    let repository = opt_object(object, "repo")?
        .map(|repo| opt_str(repo, "name_with_owner"))
        .transpose()?
        .flatten();
    if !authenticated || repository.is_none() {
        let hint = auth
            .map(|auth| opt_str(auth, "hint"))
            .transpose()?
            .flatten();
        return Ok(PullRequestAvailability::RepositoryUnresolved { hint });
    }
    Ok(match pull_request {
        Some(_) => PullRequestAvailability::Ready,
        None if warnings => PullRequestAvailability::Unavailable,
        None => PullRequestAvailability::NoPullRequest,
    })
}

/// `auth.accounts`, or a host's legacy top-level `accounts`.
fn decode_accounts(object: &Map<String, Value>) -> Result<Vec<PullRequestAccount>, String> {
    let auth = opt_object(object, "auth")?;
    let source = if auth.is_some_and(|auth| auth.contains_key("accounts")) {
        auth
    } else {
        Some(object)
    };
    let Some(source) = source else {
        return Ok(Vec::new());
    };
    each_object(source, "accounts")?
        .into_iter()
        .map(|account| {
            Ok(PullRequestAccount {
                login: req_str(account, "login")?,
                active: opt_bool(account, "active")?.unwrap_or(false),
            })
        })
        .collect()
}

/// `auth.selected_account`, or a host's legacy top-level `selected_account`.
fn selected_account(object: &Map<String, Value>) -> Result<Option<String>, String> {
    let from_auth = opt_object(object, "auth")?
        .map(|auth| opt_str(auth, "selected_account"))
        .transpose()?
        .flatten();
    Ok(match from_auth {
        Some(login) => Some(login),
        None => opt_str(object, "selected_account")?,
    }
    .filter(|login| !login.is_empty()))
}

fn strings(object: &Map<String, Value>, key: &str) -> Result<Vec<String>, String> {
    opt_array(object, key)?
        .into_iter()
        .flatten()
        .map(|value| {
            value
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| format!("`{key}` holds a non-string"))
        })
        .collect()
}

impl PullRequestInfo {
    /// Decodes a `session.github.info` body.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "session.github.info")?;
        let pull_request = opt_object(object, "pr")?
            .map(|_| PullRequestDetail::from_value(&object["pr"]))
            .transpose()?;
        let warnings = strings(object, "warnings")?;
        let display = opt_object(object, "provider_display")?;
        let capabilities = PullRequestCapabilities::decode(opt_object(object, "capabilities")?)?;
        let mut all_warnings = warnings.clone();
        all_warnings.extend(strings(object, "discovery_warnings")?);
        let linked = opt_array(object, "prs")?
            .into_iter()
            .flatten()
            .map(SessionPullRequest::from_value)
            .collect::<Result<Vec<_>, _>>()?;
        let provider = match object.get("provider") {
            None => Some("github".to_owned()),
            Some(_) => opt_str(object, "provider")?,
        };
        Ok(Self {
            availability: availability(object, pull_request.as_ref(), !warnings.is_empty())?,
            provider,
            provider_name: display
                .map(|display| opt_str(display, "display_name"))
                .transpose()?
                .flatten(),
            number_prefix: display
                .map(|display| opt_str(display, "number_prefix"))
                .transpose()?
                .flatten()
                .unwrap_or_else(|| "#".to_owned()),
            branch: opt_str(object, "branch")?,
            repository: opt_object(object, "repo")?
                .map(|repo| opt_str(repo, "name_with_owner"))
                .transpose()?
                .flatten(),
            base_ref: opt_str(object, "base_ref")?,
            selected_url: opt_str(object, "selected_pr_url")?
                .or_else(|| pull_request.as_ref().map(|pr| pr.url.clone())),
            tracking_available: opt_bool(object, "tracking_available")?.unwrap_or(false),
            polling: PullRequestPolling::of(object, pull_request.as_ref(), &linked)?,
            linked,
            warnings: all_warnings,
            capabilities,
            pull_request,
            accounts: decode_accounts(object)?,
            selected_account: selected_account(object)?,
            request_name: display
                .map(|display| opt_str(display, "request_name"))
                .transpose()?
                .flatten()
                .filter(|name| !name.trim().is_empty()),
        })
    }

    /// What the panel shows for a `404`: no workspace, or a host older than the route.
    #[must_use]
    pub fn not_found(message: &str) -> Self {
        let lowered = message.to_ascii_lowercase();
        let outdated = lowered.contains("resource")
            && lowered.contains("github")
            && lowered.contains("not found");
        Self {
            availability: if outdated {
                PullRequestAvailability::HostOutdated
            } else {
                PullRequestAvailability::Unavailable
            },
            provider: None,
            provider_name: None,
            number_prefix: "#".to_owned(),
            branch: None,
            repository: None,
            base_ref: None,
            selected_url: None,
            tracking_available: false,
            linked: Vec::new(),
            warnings: Vec::new(),
            capabilities: PullRequestCapabilities::default(),
            pull_request: None,
            polling: PullRequestPolling::WITHOUT_INFO,
            accounts: Vec::new(),
            selected_account: None,
            request_name: None,
        }
    }
}

/// The path of one of the session's `…/resources/github/{resource}` routes.
pub(super) fn github_resource(session_id: &str, resource: &str) -> Result<String, SessionError> {
    validate_identifier(session_id)?;
    Ok(format!(
        "/v1/sessions/{session_id}/resources/github/{resource}"
    ))
}

/// The `pr_url` query of a request about one PR.
pub(super) fn pr_query(pr_url: Option<&str>) -> Vec<(&'static str, String)> {
    pr_url
        .map(|url| vec![("pr_url", url.to_owned())])
        .unwrap_or_default()
}

impl<T: HttpTransport> ClientCore<T> {
    /// `GET` a route the session's host answers, keeping the reason of a refusal: a `4xx`
    /// (and a `5xx` that explains itself) is [`SessionError::Rejected`] with the server's text.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn host_resource_read(
        &self,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<Value, SessionError> {
        self.host_resource_read_at(path, &[], query).await
    }

    /// [`Self::host_resource_read`] of `path` with `segments` appended, each escaped as one
    /// path segment.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn host_resource_read_at(
        &self,
        path: &str,
        segments: &[&str],
        query: &[(&str, String)],
    ) -> Result<Value, SessionError> {
        let mut prepared = self.prepare("GET", path, query, None)?;
        if !segments.is_empty() {
            prepared.request.url = changes::append_segments(&prepared.request.url, segments)?;
        }
        let result = self
            .send_routed(prepared.request, prepared.addressing)
            .await;
        let response = {
            let mut state = lock(&self.state);
            if state.epoch != prepared.epoch || !state.is_connected() {
                return Err(SessionError::NotConnected);
            }
            let response = result.map_err(|error| match error {
                TransportError::Cancelled => SessionError::Cancelled,
                other => SessionError::Transport(other),
            })?;
            if response.status == 401 {
                state.authentication_failed();
                return Err(SessionError::Unauthorized {
                    reason: error_text(&response.body),
                });
            }
            response
        };
        let body: Option<Value> = serde_json::from_slice(&response.body).ok();
        match response.status {
            200 | 202 => body.ok_or_else(|| SessionError::MalformedResponse {
                detail: format!("{path}: the body is not JSON"),
            }),
            status @ 300..=399 => Err(SessionError::RedirectNotAllowed { status }),
            403 => Err(SessionError::Forbidden),
            503 if body
                .as_ref()
                .and_then(|body| body.pointer("/error/code"))
                .and_then(Value::as_str)
                == Some("runner_unavailable") =>
            {
                Err(SessionError::HostOffline {
                    message: HOST_OFFLINE.to_owned(),
                })
            }
            status @ 400..=499 => Err(SessionError::Rejected {
                status,
                message: rejection_message(&response.body, status),
            }),
            status if body.is_some() => Err(SessionError::Rejected {
                status,
                message: rejection_message(&response.body, status),
            }),
            status => Err(SessionError::HttpStatus { status }),
        }
    }

    /// The session's linked PRs and the detail of `pr_url` (the host's default PR when `None`),
    /// read live from the session's host.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; [`SessionError::Rejected`] with
    /// the host's reason; [`SessionError::HostOffline`]; the read errors; and
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn pull_request_info(
        &self,
        session_id: &str,
        pr_url: Option<&str>,
    ) -> Result<PullRequestInfo, SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}/resources/github");
        let result = match self.host_resource_read(&path, &pr_query(pr_url)).await {
            Ok(value) => PullRequestInfo::from_value(&value).map_err(|detail| {
                SessionError::MalformedResponse {
                    detail: format!("{path}: {detail}"),
                }
            }),
            Err(SessionError::Rejected {
                status: 404,
                message,
            }) => Ok(PullRequestInfo::not_found(&message)),
            Err(error) => Err(error),
        };
        self.dispatch();
        result
    }
}

fn decode_patch(value: &Value) -> Result<PullRequestPatch, String> {
    let object = as_object(value, "session.github.pr_diff")?;
    let unavailable = match opt_str(object, "unavailable_reason")? {
        None => None,
        Some(reason) => Some(opt_str(object, "message")?.unwrap_or_else(|| {
            if reason == "pr_outside_workspace" {
                "The diff is unavailable for a pull request outside this workspace's repository."
                    .to_owned()
            } else {
                "The diff is unavailable. Refresh, or open the pull request on its provider."
                    .to_owned()
            }
        })),
    };
    Ok(PullRequestPatch {
        patch: opt_str(object, "patch")?.unwrap_or_default(),
        unavailable,
        head_sha: opt_str(object, "head_sha")?,
        base_sha: opt_str(object, "base_sha")?,
    })
}

#[cfg(test)]
#[path = "pull_request_polling_tests.rs"]
mod polling_tests;

#[cfg(test)]
#[path = "pull_request_text_tests.rs"]
mod text_tests;

#[cfg(test)]
#[path = "pull_request_reviews_tests.rs"]
mod reviews_tests;

#[cfg(test)]
#[path = "pull_request_changes_tests.rs"]
mod changes_tests;
