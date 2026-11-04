//! The right panel's server reads: stored pull requests and the panel features.
//!
//! `GET /v1/sessions/{id}/pull-requests` answers from the server while the host is offline;
//! `GET /v1/info` says which panel features the server offers.

use serde_json::{Map, Value};

use super::json::{as_object, opt_array, opt_bool, opt_object, opt_str, opt_u64, req_str};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// The server's page size cap for this route.
const PAGE_LIMIT: u32 = 100;
/// A session links at most 50 PRs; more pages than this means the cursor is not advancing.
const MAX_PAGES: usize = 20;

/// What `GET /v1/info` says the right panel can offer. Missing fields mean unsupported.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PanelFeatures {
    /// `features.workspace_content_search`: the session workspace can be searched by content.
    pub content_search: bool,
    /// `session_pull_requests`: the server stores each session's linked pull requests.
    pub pull_requests: bool,
}

impl PanelFeatures {
    /// Decodes the panel fields of a `/v1/info` body.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "/v1/info")?;
        let content_search = match opt_object(object, "features")? {
            Some(features) => opt_bool(features, "workspace_content_search")?.unwrap_or(false),
            None => false,
        };
        Ok(Self {
            content_search,
            pull_requests: opt_bool(object, "session_pull_requests")?.unwrap_or(false),
        })
    }
}

/// Where a linked pull request stands, from the state its host last fetched.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PullRequestStatus {
    /// Open and ready for review.
    Open,
    /// Open as a draft.
    Draft,
    /// Merged.
    Merged,
    /// Closed without merging.
    Closed,
    /// The host has not fetched the state yet, or reported one this client does not know.
    Unknown,
}

impl PullRequestStatus {
    /// The status of a PR the provider reports as `state` (`OPEN`, `MERGED`, `CLOSED`).
    #[must_use]
    pub fn of(state: Option<&str>, is_draft: bool) -> Self {
        match state.map(str::to_ascii_uppercase).as_deref() {
            Some("OPEN") if is_draft => Self::Draft,
            Some("OPEN") => Self::Open,
            Some("MERGED") => Self::Merged,
            Some("CLOSED") => Self::Closed,
            _ => Self::Unknown,
        }
    }
}

/// A pull request linked to a session, as the server stores it.
#[derive(Debug, Clone, PartialEq)]
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
    /// The git provider's display name ("GitHub"), when the server knows the provider.
    pub provider_name: Option<String>,
    /// Where it stands.
    pub status: PullRequestStatus,
    /// Epoch seconds of the fetch that read the state.
    pub state_checked_at: Option<f64>,
}

impl SessionPullRequest {
    /// Decodes one row of the list.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "pull request")?;
        let number = opt_u64(object, "number")?.ok_or_else(|| "`number` is missing".to_owned())?;
        let state = opt_str(object, "state")?;
        let is_draft = opt_bool(object, "is_draft")?.unwrap_or(false);
        let provider_name = match opt_object(object, "provider_display")? {
            Some(display) => opt_str(display, "display_name")?,
            None => None,
        };
        Ok(Self {
            url: req_str(object, "url")?,
            host: opt_str(object, "host")?.unwrap_or_default(),
            repository: req_str(object, "repository")?,
            number,
            title: opt_str(object, "title")?.filter(|title| !title.trim().is_empty()),
            relationship: opt_str(object, "relationship")?.unwrap_or_default(),
            provider_name,
            status: PullRequestStatus::of(state.as_deref(), is_draft),
            state_checked_at: opt_f64(object, "state_checked_at")?,
        })
    }
}

/// A session's linked pull requests, in the server's display order.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SessionPullRequests {
    /// The pull requests.
    pub pull_requests: Vec<SessionPullRequest>,
    /// Whether the server has imported the session's PRs from its host. Until it has, an empty
    /// list means "not known yet" rather than "none".
    pub synced: bool,
}

fn opt_f64(object: &Map<String, Value>, key: &str) -> Result<Option<f64>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_f64()
            .map(Some)
            .ok_or_else(|| format!("`{key}` is not a number")),
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// What the server's right panel can offer (`GET /v1/info`).
    ///
    /// # Errors
    ///
    /// The read errors and [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn panel_features(&self) -> Result<PanelFeatures, SessionError> {
        let value = self.get_json("/v1/info", &[]).await;
        self.dispatch();
        PanelFeatures::from_value(&value?)
            .map_err(|detail| SessionError::MalformedResponse { detail })
    }

    /// Every pull request linked to `session_id`, from the server (never the host). Check
    /// [`PanelFeatures::pull_requests`] first: older servers have no such route.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; the read errors;
    /// [`SessionError::InvalidPagination`] for a cursor that does not advance;
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn session_pull_requests(
        &self,
        session_id: &str,
    ) -> Result<SessionPullRequests, SessionError> {
        let result = self.pull_request_pages(session_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn pull_request_pages(
        &self,
        session_id: &str,
    ) -> Result<SessionPullRequests, SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}/pull-requests");
        let malformed = |detail: String| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        };
        let mut result = SessionPullRequests::default();
        let mut after: Option<String> = None;
        for _ in 0..MAX_PAGES {
            let mut query = vec![("limit", PAGE_LIMIT.to_string())];
            if let Some(cursor) = &after {
                query.push(("after", cursor.clone()));
            }
            let value = self.get_json(&path, &query).await?;
            let object = as_object(&value, "the list").map_err(malformed)?;
            for row in opt_array(object, "data")
                .map_err(malformed)?
                .into_iter()
                .flatten()
            {
                result
                    .pull_requests
                    .push(SessionPullRequest::from_value(row).map_err(malformed)?);
            }
            result.synced = opt_bool(object, "synced")
                .map_err(malformed)?
                .unwrap_or(false);
            if !opt_bool(object, "has_more")
                .map_err(malformed)?
                .unwrap_or(false)
            {
                return Ok(result);
            }
            let next = opt_str(object, "last_id").map_err(malformed)?;
            if next.is_none() || next == after {
                return Err(SessionError::InvalidPagination);
            }
            after = next;
        }
        Err(SessionError::InvalidPagination)
    }
}
