//! One pull request's live detail and the panel's changes to it, read and written through the
//! session's host.
//!
//! The decoding, status rule and error mapping are `omnigent_core::pull_request_detail`'s and
//! `omnigent_core::pull_request_edits`'.

use omnigent_core::pull_request_detail as core;
use omnigent_core::pull_request_edits as edits;

use crate::client::ClientCore;
use crate::errors::CoreError;
use crate::pull_requests::{PullRequestStatus, SessionPullRequest};

/// Where a pull request stands, as the web's status chip names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum PullRequestCondition {
    /// Merge conflicts.
    Conflict,
    /// A check failed.
    ChecksFailing,
    /// Mergeable with passing checks.
    Ready,
    /// Checks running.
    ChecksRunning,
    /// Open.
    Open,
    /// Draft.
    Draft,
    /// Unknown.
    Unknown,
    /// Merged.
    Merged,
    /// Closed.
    Closed,
}

impl From<core::PullRequestCondition> for PullRequestCondition {
    fn from(condition: core::PullRequestCondition) -> Self {
        use core::PullRequestCondition as C;
        match condition {
            C::Conflict => Self::Conflict,
            C::ChecksFailing => Self::ChecksFailing,
            C::Ready => Self::Ready,
            C::ChecksRunning => Self::ChecksRunning,
            C::Open => Self::Open,
            C::Draft => Self::Draft,
            C::Unknown => Self::Unknown,
            C::Merged => Self::Merged,
            C::Closed => Self::Closed,
        }
    }
}

/// A CI check's bucket.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CheckBucket {
    /// Passed.
    Passing,
    /// Failed.
    Failing,
    /// Running.
    Pending,
    /// Cancelled.
    Cancelled,
    /// Skipped.
    Skipped,
}

/// One CI check.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct CheckRun {
    /// The job name.
    pub name: String,
    /// Its bucket.
    pub bucket: CheckBucket,
    /// Its page.
    pub url: Option<String>,
}

/// The PR's CI checks.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
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
    /// All.
    pub total: u64,
    /// Some could not be read.
    pub partial: bool,
    /// Each check.
    pub runs: Vec<CheckRun>,
}

impl From<core::PullRequestChecks> for PullRequestChecks {
    fn from(checks: core::PullRequestChecks) -> Self {
        Self {
            passing: checks.passing,
            failing: checks.failing,
            pending: checks.pending,
            cancelled: checks.cancelled,
            skipped: checks.skipped,
            total: checks.total,
            partial: checks.partial,
            runs: checks
                .runs
                .into_iter()
                .map(|run| CheckRun {
                    name: run.name,
                    bucket: match run.bucket {
                        core::CheckBucket::Passing => CheckBucket::Passing,
                        core::CheckBucket::Failing => CheckBucket::Failing,
                        core::CheckBucket::Pending => CheckBucket::Pending,
                        core::CheckBucket::Cancelled => CheckBucket::Cancelled,
                        core::CheckBucket::Skipped => CheckBucket::Skipped,
                    },
                    url: run.url,
                })
                .collect(),
        }
    }
}

/// A conversation comment.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PullRequestComment {
    /// The author's login.
    pub author: Option<String>,
    /// Markdown.
    pub body: String,
    /// ISO-8601 time.
    pub created_at: Option<String>,
    /// Its page.
    pub url: Option<String>,
}

impl From<core::PullRequestComment> for PullRequestComment {
    fn from(comment: core::PullRequestComment) -> Self {
        Self {
            author: comment.author,
            body: comment.body,
            created_at: comment.created_at,
            url: comment.url,
        }
    }
}

/// User or team.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ReviewerKind {
    /// A user.
    User,
    /// A team.
    Team,
}

impl From<core::ReviewerKind> for ReviewerKind {
    fn from(kind: core::ReviewerKind) -> Self {
        match kind {
            core::ReviewerKind::User => Self::User,
            core::ReviewerKind::Team => Self::Team,
        }
    }
}

impl From<ReviewerKind> for core::ReviewerKind {
    fn from(kind: ReviewerKind) -> Self {
        match kind {
            ReviewerKind::User => Self::User,
            ReviewerKind::Team => Self::Team,
        }
    }
}

/// Where a review stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ReviewState {
    /// Requested.
    Pending,
    /// Approved.
    Approved,
    /// Commented.
    Commented,
    /// Asked for changes.
    ChangesRequested,
    /// Dismissed.
    Dismissed,
}

/// A reviewer.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PullRequestReviewer {
    /// Login or team slug.
    pub login: String,
    /// User or team.
    pub kind: ReviewerKind,
    /// Their review.
    pub state: ReviewState,
}

impl From<core::PullRequestReviewer> for PullRequestReviewer {
    fn from(reviewer: core::PullRequestReviewer) -> Self {
        Self {
            login: reviewer.login,
            kind: reviewer.kind.into(),
            state: match reviewer.state {
                core::ReviewState::Pending => ReviewState::Pending,
                core::ReviewState::Approved => ReviewState::Approved,
                core::ReviewState::Commented => ReviewState::Commented,
                core::ReviewState::ChangesRequested => ReviewState::ChangesRequested,
                core::ReviewState::Dismissed => ReviewState::Dismissed,
            },
        }
    }
}

/// A label.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PullRequestLabel {
    /// The name.
    pub name: String,
    /// Six hex digits without `#`.
    pub color: Option<String>,
    /// What it means.
    pub description: Option<String>,
}

impl From<core::PullRequestLabel> for PullRequestLabel {
    fn from(label: core::PullRequestLabel) -> Self {
        Self {
            name: label.name,
            color: label.color,
            description: label.description,
        }
    }
}

/// The selected PR as the host read it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PullRequestDetail {
    /// The number.
    pub number: u64,
    /// The title.
    pub title: String,
    /// The page.
    pub url: String,
    /// Open, draft, merged or closed.
    pub status: PullRequestStatus,
    /// The status chip's condition.
    pub condition: PullRequestCondition,
    /// The author's login.
    pub author: Option<String>,
    /// The base branch.
    pub base_ref: Option<String>,
    /// The head branch.
    pub head_ref: Option<String>,
    /// The head commit a merge must match.
    pub head_sha: Option<String>,
    /// Markdown description.
    pub body: Option<String>,
    /// CI.
    pub checks: PullRequestChecks,
    /// `false` when the account cannot read checks.
    pub checks_supported: bool,
    /// Conversation comments.
    pub comments: Vec<PullRequestComment>,
    /// Some comments could not be read.
    pub comments_partial: bool,
    /// Reviewers, when reported.
    pub reviewers: Option<Vec<PullRequestReviewer>>,
    /// Labels, when reported.
    pub labels: Option<Vec<PullRequestLabel>>,
    /// GitHub's `mergeStateStatus`.
    pub merge_state_status: Option<String>,
    /// The host reports a merge state, so the panel can merge.
    pub reports_merge_state: bool,
    /// Auto-merge's method, when it is on (for example `SQUASH`; empty when unknown).
    pub auto_merge_method: Option<String>,
}

impl From<core::PullRequestDetail> for PullRequestDetail {
    fn from(detail: core::PullRequestDetail) -> Self {
        Self {
            number: detail.number,
            title: detail.title,
            url: detail.url,
            status: detail.status.into(),
            condition: detail.condition.into(),
            author: detail.author,
            base_ref: detail.base_ref,
            head_ref: detail.head_ref,
            head_sha: detail.head_sha,
            body: detail.body,
            checks: detail.checks.into(),
            checks_supported: detail.checks_supported,
            comments: detail.comments.into_iter().map(Into::into).collect(),
            comments_partial: detail.comments_partial,
            reviewers: detail
                .reviewers
                .map(|reviewers| reviewers.into_iter().map(Into::into).collect()),
            labels: detail
                .labels
                .map(|labels| labels.into_iter().map(Into::into).collect()),
            merge_state_status: detail.merge_state_status,
            reports_merge_state: detail.reports_merge_state,
            auto_merge_method: detail
                .auto_merge
                .map(|auto| auto.merge_method.unwrap_or_default()),
        }
    }
}

/// What the panel can change.
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent capability flags the host reports"
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PullRequestCapabilities {
    /// Labels.
    pub label_editing: bool,
    /// Merge and auto-merge.
    pub merging: bool,
    /// Comments.
    pub comment_posting: bool,
    /// Reviewers.
    pub reviewer_editing: bool,
}

/// Why there is no PR to show, or that there is one.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum PullRequestAvailability {
    /// The detail is set.
    Ready,
    /// The branch has no PR yet.
    NoPullRequest,
    /// Not a git checkout.
    NotAGitRepository,
    /// The host predates the route.
    HostOutdated,
    /// No supported provider for the remote.
    UnsupportedRemote {
        /// The remote's host.
        remote_host: Option<String>,
    },
    /// The provider CLI is missing.
    NoCli {
        /// Its name.
        cli: String,
    },
    /// Not signed in, or the repository cannot be read.
    RepositoryUnresolved {
        /// Sign-in guidance.
        hint: Option<String>,
    },
    /// Nothing to show.
    Unavailable,
}

impl From<core::PullRequestAvailability> for PullRequestAvailability {
    fn from(availability: core::PullRequestAvailability) -> Self {
        use core::PullRequestAvailability as A;
        match availability {
            A::Ready => Self::Ready,
            A::NoPullRequest => Self::NoPullRequest,
            A::NotAGitRepository => Self::NotAGitRepository,
            A::HostOutdated => Self::HostOutdated,
            A::UnsupportedRemote { remote_host } => Self::UnsupportedRemote { remote_host },
            A::NoCli { cli } => Self::NoCli { cli },
            A::RepositoryUnresolved { hint } => Self::RepositoryUnresolved { hint },
            A::Unavailable => Self::Unavailable,
        }
    }
}

/// The session's linked PRs and the selected one's detail.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PullRequestInfo {
    /// Whether there is a PR to show, or why not.
    pub availability: PullRequestAvailability,
    /// The provider's name.
    pub provider_name: Option<String>,
    /// What precedes a PR number.
    pub number_prefix: String,
    /// The branch.
    pub branch: Option<String>,
    /// `owner/name`.
    pub repository: Option<String>,
    /// The base branch.
    pub base_ref: Option<String>,
    /// The PR the detail is for.
    pub selected_url: Option<String>,
    /// The host links and unlinks PRs.
    pub tracking_available: bool,
    /// The linked PRs.
    pub linked: Vec<SessionPullRequest>,
    /// Provider warnings.
    pub warnings: Vec<String>,
    /// What the panel can change.
    pub capabilities: PullRequestCapabilities,
    /// The selected PR.
    pub pull_request: Option<PullRequestDetail>,
}

impl From<core::PullRequestInfo> for PullRequestInfo {
    fn from(info: core::PullRequestInfo) -> Self {
        let caps = info.capabilities;
        Self {
            availability: info.availability.into(),
            provider_name: info.provider_name,
            number_prefix: info.number_prefix,
            branch: info.branch,
            repository: info.repository,
            base_ref: info.base_ref,
            selected_url: info.selected_url,
            tracking_available: info.tracking_available,
            linked: info.linked.into_iter().map(Into::into).collect(),
            warnings: info.warnings,
            capabilities: PullRequestCapabilities {
                label_editing: caps.label_editing,
                merging: caps.merging,
                comment_posting: caps.comment_posting,
                reviewer_editing: caps.reviewer_editing,
            },
            pull_request: info.pull_request.map(Into::into),
        }
    }
}

/// The PR's patch.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PullRequestPatch {
    /// One unified diff.
    pub patch: String,
    /// Why the host cannot diff it.
    pub unavailable: Option<String>,
}

/// How a PR is merged.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum MergeMethod {
    /// A merge commit.
    Merge,
    /// Squash.
    Squash,
    /// Rebase.
    Rebase,
}

impl From<edits::MergeMethod> for MergeMethod {
    fn from(method: edits::MergeMethod) -> Self {
        match method {
            edits::MergeMethod::Merge => Self::Merge,
            edits::MergeMethod::Squash => Self::Squash,
            edits::MergeMethod::Rebase => Self::Rebase,
        }
    }
}

impl From<MergeMethod> for edits::MergeMethod {
    fn from(method: MergeMethod) -> Self {
        match method {
            MergeMethod::Merge => Self::Merge,
            MergeMethod::Squash => Self::Squash,
            MergeMethod::Rebase => Self::Rebase,
        }
    }
}

/// The merge methods a repository allows.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct MergeOptions {
    /// Allowed methods.
    pub methods: Vec<MergeMethod>,
    /// The one to preselect.
    pub default_method: Option<MergeMethod>,
}

/// Someone a review can be requested from.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ReviewCandidate {
    /// Login or team slug.
    pub login: String,
    /// User or team.
    pub kind: ReviewerKind,
    /// Display name.
    pub name: Option<String>,
}

/// A reviewer named in a request or withdrawal.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ReviewerTarget {
    /// Login or team slug.
    pub login: String,
    /// User or team.
    pub kind: ReviewerKind,
}

impl From<ReviewerTarget> for edits::ReviewerTarget {
    fn from(target: ReviewerTarget) -> Self {
        Self {
            login: target.login,
            kind: target.kind.into(),
        }
    }
}

/// The labels a repository offers.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RepositoryLabels {
    /// The labels.
    pub labels: Vec<PullRequestLabel>,
    /// There are more than the host lists.
    pub has_more: bool,
}

/// The users and teams a review can be requested from.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ReviewCandidates {
    /// Users, then teams.
    pub candidates: Vec<ReviewCandidate>,
    /// There are more than the host lists.
    pub has_more: bool,
}

#[uniffi::export]
impl ClientCore {
    /// The session's linked PRs and the live detail of `pr_url` (the host's default when
    /// `None`), from the session's host.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, `Rejected` with the host's reason (also
    /// while the host is offline), the read errors and `MalformedResponse`.
    pub async fn pull_request_info(
        &self,
        session_id: String,
        pr_url: Option<String>,
    ) -> Result<PullRequestInfo, CoreError> {
        self.sessions()
            .pull_request_info(&session_id, pr_url.as_deref())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// The whole of `pr_url` as one unified-diff patch.
    ///
    /// # Errors
    ///
    /// As `pull_request_info`.
    pub async fn pull_request_patch(
        &self,
        session_id: String,
        pr_url: Option<String>,
    ) -> Result<PullRequestPatch, CoreError> {
        let patch = self
            .sessions()
            .pull_request_patch(&session_id, pr_url.as_deref())
            .await
            .map_err(CoreError::from)?;
        Ok(PullRequestPatch {
            patch: patch.patch,
            unavailable: patch.unavailable,
        })
    }

    /// Links the PR at `url` to the session.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidInput`, `Rejected` with the host's reason, and the write
    /// errors.
    pub async fn link_pull_request(
        &self,
        session_id: String,
        url: String,
    ) -> Result<PullRequestInfo, CoreError> {
        self.sessions()
            .link_pull_request(&session_id, &url)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Unlinks the PR at `url` from the session.
    ///
    /// # Errors
    ///
    /// As `link_pull_request`.
    pub async fn unlink_pull_request(
        &self,
        session_id: String,
        url: String,
    ) -> Result<PullRequestInfo, CoreError> {
        self.sessions()
            .unlink_pull_request(&session_id, &url)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// The labels `pr_url`'s repository offers.
    ///
    /// # Errors
    ///
    /// As `pull_request_info`.
    pub async fn pull_request_repository_labels(
        &self,
        session_id: String,
        pr_url: String,
    ) -> Result<RepositoryLabels, CoreError> {
        let labels = self
            .sessions()
            .pull_request_repository_labels(&session_id, &pr_url)
            .await
            .map_err(CoreError::from)?;
        Ok(RepositoryLabels {
            labels: labels.items.into_iter().map(Into::into).collect(),
            has_more: labels.has_more,
        })
    }

    /// Adds and removes labels on `pr_url`; answers its labels.
    ///
    /// # Errors
    ///
    /// As `link_pull_request`.
    pub async fn update_pull_request_labels(
        &self,
        session_id: String,
        pr_url: String,
        add: Vec<String>,
        remove: Vec<String>,
    ) -> Result<Vec<PullRequestLabel>, CoreError> {
        let labels = self
            .sessions()
            .update_pull_request_labels(&session_id, &pr_url, &add, &remove)
            .await
            .map_err(CoreError::from)?;
        Ok(labels.into_iter().map(Into::into).collect())
    }

    /// The users and teams a review of `pr_url` can be requested from.
    ///
    /// # Errors
    ///
    /// As `pull_request_info`.
    pub async fn pull_request_review_candidates(
        &self,
        session_id: String,
        pr_url: String,
    ) -> Result<ReviewCandidates, CoreError> {
        let candidates = self
            .sessions()
            .pull_request_review_candidates(&session_id, &pr_url)
            .await
            .map_err(CoreError::from)?;
        Ok(ReviewCandidates {
            candidates: candidates
                .items
                .into_iter()
                .map(|candidate| ReviewCandidate {
                    login: candidate.login,
                    kind: candidate.kind.into(),
                    name: candidate.name,
                })
                .collect(),
            has_more: candidates.has_more,
        })
    }

    /// Requests reviews from `add` and withdraws `remove`; answers the reviewers.
    ///
    /// # Errors
    ///
    /// As `link_pull_request`.
    pub async fn update_pull_request_reviewers(
        &self,
        session_id: String,
        pr_url: String,
        add: Vec<ReviewerTarget>,
        remove: Vec<ReviewerTarget>,
    ) -> Result<Vec<PullRequestReviewer>, CoreError> {
        let add: Vec<edits::ReviewerTarget> = add.into_iter().map(Into::into).collect();
        let remove: Vec<edits::ReviewerTarget> = remove.into_iter().map(Into::into).collect();
        let reviewers = self
            .sessions()
            .update_pull_request_reviewers(&session_id, &pr_url, &add, &remove)
            .await
            .map_err(CoreError::from)?;
        Ok(reviewers.into_iter().map(Into::into).collect())
    }

    /// The merge methods `pr_url`'s repository allows.
    ///
    /// # Errors
    ///
    /// As `pull_request_info`.
    pub async fn pull_request_merge_options(
        &self,
        session_id: String,
        pr_url: String,
    ) -> Result<MergeOptions, CoreError> {
        let options = self
            .sessions()
            .pull_request_merge_options(&session_id, &pr_url)
            .await
            .map_err(CoreError::from)?;
        Ok(MergeOptions {
            methods: options.methods.into_iter().map(Into::into).collect(),
            default_method: options.default.map(Into::into),
        })
    }

    /// Merges `pr_url`, only while its head is still `expected_head`.
    ///
    /// # Errors
    ///
    /// As `link_pull_request`.
    pub async fn merge_pull_request(
        &self,
        session_id: String,
        pr_url: String,
        method: MergeMethod,
        expected_head: String,
    ) -> Result<(), CoreError> {
        self.sessions()
            .merge_pull_request(&session_id, &pr_url, method.into(), &expected_head)
            .await
            .map_err(CoreError::from)
    }

    /// Turns off `pr_url`'s auto-merge.
    ///
    /// # Errors
    ///
    /// As `link_pull_request`.
    pub async fn disable_pull_request_auto_merge(
        &self,
        session_id: String,
        pr_url: String,
    ) -> Result<(), CoreError> {
        self.sessions()
            .disable_pull_request_auto_merge(&session_id, &pr_url)
            .await
            .map_err(CoreError::from)
    }

    /// Posts a conversation comment on `pr_url`.
    ///
    /// # Errors
    ///
    /// As `link_pull_request`.
    pub async fn post_pull_request_comment(
        &self,
        session_id: String,
        pr_url: String,
        body: String,
    ) -> Result<PullRequestComment, CoreError> {
        self.sessions()
            .post_pull_request_comment(&session_id, &pr_url, &body)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}
