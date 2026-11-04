//! The right panel's server reads: stored pull requests and the panel features.
//!
//! The decoding and status rules are `omnigent_core::pull_requests`'s.

use omnigent_core::pull_requests as core;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// What the server's right panel can offer. Missing fields mean unsupported.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PanelFeatures {
    /// The session workspace can be searched by content.
    pub content_search: bool,
    /// The server stores each session's linked pull requests.
    pub pull_requests: bool,
}

impl From<core::PanelFeatures> for PanelFeatures {
    fn from(features: core::PanelFeatures) -> Self {
        Self {
            content_search: features.content_search,
            pull_requests: features.pull_requests,
        }
    }
}

/// Where a linked pull request stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum PullRequestStatus {
    /// Open and ready for review.
    Open,
    /// Open as a draft.
    Draft,
    /// Merged.
    Merged,
    /// Closed without merging.
    Closed,
    /// Not fetched yet, or a state this client does not know.
    Unknown,
}

impl From<core::PullRequestStatus> for PullRequestStatus {
    fn from(status: core::PullRequestStatus) -> Self {
        match status {
            core::PullRequestStatus::Open => Self::Open,
            core::PullRequestStatus::Draft => Self::Draft,
            core::PullRequestStatus::Merged => Self::Merged,
            core::PullRequestStatus::Closed => Self::Closed,
            core::PullRequestStatus::Unknown => Self::Unknown,
        }
    }
}

/// A pull request linked to a session, as the server stores it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SessionPullRequest {
    /// The PR page; unique within the session.
    pub url: String,
    /// The forge host, for example `github.com`.
    pub host: String,
    /// The base repository, `owner/name`.
    pub repository: String,
    /// The PR number.
    pub number: u64,
    /// The title the host last looked up.
    pub title: Option<String>,
    /// How the PR joined the session: `created`, `worked_on`, `attached` or `inferred`.
    pub relationship: String,
    /// The git provider's display name ("GitHub"), when known.
    pub provider_name: Option<String>,
    /// Where it stands.
    pub status: PullRequestStatus,
    /// Epoch seconds of the fetch that read the state.
    pub state_checked_at: Option<f64>,
}

impl From<core::SessionPullRequest> for SessionPullRequest {
    fn from(pr: core::SessionPullRequest) -> Self {
        Self {
            url: pr.url,
            host: pr.host,
            repository: pr.repository,
            number: pr.number,
            title: pr.title,
            relationship: pr.relationship,
            provider_name: pr.provider_name,
            status: pr.status.into(),
            state_checked_at: pr.state_checked_at,
        }
    }
}

/// A session's linked pull requests, in the server's display order.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SessionPullRequests {
    /// The pull requests.
    pub pull_requests: Vec<SessionPullRequest>,
    /// Whether the server has imported the session's PRs from its host; until then an empty
    /// list means "not known yet".
    pub synced: bool,
}

#[uniffi::export]
impl ClientCore {
    /// What the server's right panel can offer (`GET /v1/info`).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn panel_features(&self) -> Result<PanelFeatures, CoreError> {
        self.sessions()
            .panel_features()
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Every pull request linked to `session_id`, from the server; it answers while the host is
    /// offline. Check `PanelFeatures::pull_requests` first.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors, `InvalidPagination` and
    /// `MalformedResponse`.
    pub async fn session_pull_requests(
        &self,
        session_id: String,
    ) -> Result<SessionPullRequests, CoreError> {
        let list = self
            .sessions()
            .session_pull_requests(&session_id)
            .await
            .map_err(CoreError::from)?;
        Ok(SessionPullRequests {
            pull_requests: list.pull_requests.into_iter().map(Into::into).collect(),
            synced: list.synced,
        })
    }
}
