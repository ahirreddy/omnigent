//! How often a reader re-reads a pull request's live info, as the web polls it
//! (`computePullRequestPollInterval`, `computeLinkedPullRequestPollInterval` and
//! `runnerOfflineRetryDelay` in `web/src/hooks`).
//!
//! An interval of `None` rests: nothing changes until a turn ends, the user refreshes, or the
//! reader shows again.

use serde_json::{Map, Value};

use super::PullRequestDetail;
use crate::client::json::{opt_bool, opt_object, opt_str};
use crate::client::pull_requests::{PullRequestStatus, SessionPullRequest};

/// While setup can still change outside the app, or checks run.
pub const PULL_REQUEST_POLL_MS: u64 = 5_000;
/// The open panel's cadence on a host that links PRs per session.
pub const PULL_REQUEST_TRACKING_POLL_MS: u64 = 10_000;
/// List rows and the composer's linked PRs.
pub const PULL_REQUEST_LIST_POLL_MS: u64 = 30_000;
/// The last host-offline retry before the reader rests (about two minutes of backoff).
pub const HOST_OFFLINE_RETRIES: u32 = 12;
/// The longest wait between host-offline retries.
const HOST_OFFLINE_MAX_DELAY_MS: u64 = 15_000;

/// The poll intervals for one `session.github.info`, in milliseconds.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PullRequestPolling {
    /// The open panel showing this PR's detail.
    pub panel_ms: Option<u64>,
    /// A list row watching this PR.
    pub list_ms: Option<u64>,
    /// The composer watching the session's linked PRs (this info's selected PR among them).
    pub linked_ms: Option<u64>,
}

impl PullRequestPolling {
    /// Before any info was read, or after a read failed with nothing shown: the panel keeps
    /// trying and list rows keep their cadence.
    pub const WITHOUT_INFO: Self = Self {
        panel_ms: Some(PULL_REQUEST_POLL_MS),
        list_ms: Some(PULL_REQUEST_LIST_POLL_MS),
        linked_ms: None,
    };

    /// The intervals for a decoded info body.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub(super) fn of(
        object: &Map<String, Value>,
        pull_request: Option<&PullRequestDetail>,
        linked: &[SessionPullRequest],
    ) -> Result<Self, String> {
        let open = pull_request.map(|pr| is_open(pr.status));
        let list_ms = match open {
            Some(false) => None,
            _ => Some(PULL_REQUEST_LIST_POLL_MS),
        };
        let panel_ms = if opt_bool(object, "tracking_available")?.unwrap_or(false) {
            Some(PULL_REQUEST_TRACKING_POLL_MS)
        } else {
            panel_interval(object, pull_request)?
        };
        let selected = pull_request.map(|pr| pr.url.as_str());
        let others = linked
            .iter()
            .filter(|row| Some(row.url.as_str()) != selected)
            .map(|row| row.status);
        let linked_ms = linked_poll_ms(others.chain(pull_request.map(|pr| pr.status)));
        Ok(Self {
            panel_ms,
            list_ms,
            linked_ms,
        })
    }
}

/// The web reads `state === "OPEN"`, which drafts share.
const fn is_open(status: PullRequestStatus) -> bool {
    matches!(status, PullRequestStatus::Open | PullRequestStatus::Draft)
}

/// Setup states resolved outside the app and running checks poll; settled PRs rest.
fn panel_interval(
    object: &Map<String, Value>,
    pull_request: Option<&PullRequestDetail>,
) -> Result<Option<u64>, String> {
    let poll = Some(PULL_REQUEST_POLL_MS);
    let available = opt_bool(object, "available")?.unwrap_or(false);
    // Hosts before `auth` send the legacy GitHub fields; only an explicit false signs out.
    let authenticated = match opt_object(object, "auth")? {
        Some(auth) => opt_bool(auth, "authenticated")?.unwrap_or(false),
        None => {
            opt_bool(object, "authenticated")? != Some(false)
                && opt_bool(object, "gh_available")? != Some(false)
        }
    };
    let repository = opt_object(object, "repo")?
        .map(|repo| opt_str(repo, "name_with_owner"))
        .transpose()?
        .flatten();
    if !available || !authenticated || repository.is_none() {
        return Ok(poll);
    }
    let Some(pr) = pull_request else {
        return Ok(poll);
    };
    let warned = object
        .get("warnings")
        .and_then(Value::as_array)
        .is_some_and(|warnings| !warnings.is_empty());
    if warned || pr.checks.partial || pr.comments_partial {
        return Ok(poll);
    }
    if !is_open(pr.status) {
        return Ok(None);
    }
    Ok((pr.checks.pending > 0 || pr.checks.total == 0).then_some(PULL_REQUEST_POLL_MS))
}

/// The composer's cadence over the session's linked PRs: the list cadence while any of them
/// can still change (an unknown state counts), rest once all are merged or closed.
#[must_use]
pub fn linked_poll_ms(statuses: impl IntoIterator<Item = PullRequestStatus>) -> Option<u64> {
    statuses
        .into_iter()
        .any(|status| {
            !matches!(
                status,
                PullRequestStatus::Merged | PullRequestStatus::Closed
            )
        })
        .then_some(PULL_REQUEST_LIST_POLL_MS)
}

/// The wait before retry `attempt` (0-based) of a read that found the host offline: 1, 2, 4
/// and 8 seconds, then 15; `None` after retry [`HOST_OFFLINE_RETRIES`].
#[must_use]
pub fn host_offline_retry_delay_ms(attempt: u32) -> Option<u64> {
    if attempt > HOST_OFFLINE_RETRIES {
        return None;
    }
    let delay = 1_000_u64.checked_shl(attempt).unwrap_or(u64::MAX);
    Some(delay.min(HOST_OFFLINE_MAX_DELAY_MS))
}
