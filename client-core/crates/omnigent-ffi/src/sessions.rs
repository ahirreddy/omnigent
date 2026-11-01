//! Session-list records and queries. The summaries come from the core's REST session client
//! and the `/v1/sessions/updates` socket; ordering and filtering are the core's
//! (`omnigent_core::session_query`).

use omnigent_core::session_query::{self, SessionFilter as CoreFilter};
use omnigent_core::sessions::{
    SessionChange as CoreChange, SessionSummary as CoreSummary, SummaryStatus,
};

use crate::client::ClientCore;
use crate::configuration::SessionConfiguration;
use crate::errors::CoreError;

/// The status a session list shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SessionListStatus {
    /// Idle, including failed (see `failure_message`).
    Idle,
    /// A turn or background work is in progress.
    Running,
    /// A decision is pending.
    NeedsResponse,
}

/// One session as the list shows it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SessionSummary {
    /// Session id.
    pub id: String,
    /// Title, or "Untitled session".
    pub title: String,
    /// The secondary line.
    pub preview: String,
    /// List status.
    pub status: SessionListStatus,
    /// Pending decisions the server reports (see `session_attention` for the ones the caller can
    /// answer).
    #[uniffi(default)]
    pub pending_requests: u32,
    /// Below edit permission, or unknown permission.
    pub is_read_only: bool,
    /// Last activity, Unix seconds.
    pub updated_at: i64,
    /// Workspace path or label.
    pub workspace: String,
    /// Agent display name.
    pub agent_name: String,
    /// Pinned.
    pub is_pinned: bool,
    /// Archived.
    pub is_archived: bool,
    /// The caller's permission level, when known.
    pub permission_level: Option<i64>,
    /// For a failed session: the last error, or a generic message.
    pub failure_message: Option<String>,
    /// Whether the caller may rename it.
    pub can_rename: bool,
    /// Whether the caller may pin it.
    pub can_pin: bool,
    /// Whether the caller may archive it.
    pub can_archive: bool,
    /// How the session runs, when a list row or snapshot reported it.
    #[uniffi(default)]
    pub configuration: Option<SessionConfiguration>,
    /// Its harness TUI is the primary view (`omnigent.ui = terminal`).
    #[uniffi(default)]
    pub terminal_first: bool,
}

/// A change to a session's organisation (`PATCH /v1/sessions/{id}`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SessionChange {
    /// Rename; the title is trimmed and must be 1 to 120 characters (edit permission).
    Title {
        /// The new title.
        title: String,
    },
    /// Pin or unpin (view permission). A pin is stamped with the host clock's time.
    Pinned {
        /// Pin or unpin.
        pinned: bool,
    },
    /// Archive or restore (owner permission).
    Archived {
        /// Archive or restore.
        archived: bool,
    },
}

/// How the session list changed. Apply in order.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SessionListChange {
    /// Replace the whole list (after a connect or a full refresh).
    Reset {
        /// Every known session.
        sessions: Vec<SessionSummary>,
    },
    /// These sessions are new or changed.
    Upsert {
        /// The summaries.
        sessions: Vec<SessionSummary>,
    },
    /// These sessions were deleted or lost access.
    Remove {
        /// Their ids.
        ids: Vec<String>,
    },
}

/// Which sessions a list shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SessionFilter {
    /// Every session that is not archived.
    All,
    /// Running, not archived.
    Running,
    /// A decision is pending, archived or not.
    NeedsResponse,
    /// Archived.
    Archived,
}

impl From<SummaryStatus> for SessionListStatus {
    fn from(status: SummaryStatus) -> Self {
        match status {
            SummaryStatus::Idle => Self::Idle,
            SummaryStatus::Running => Self::Running,
            SummaryStatus::NeedsResponse => Self::NeedsResponse,
        }
    }
}

impl From<SessionListStatus> for SummaryStatus {
    fn from(status: SessionListStatus) -> Self {
        match status {
            SessionListStatus::Idle => Self::Idle,
            SessionListStatus::Running => Self::Running,
            SessionListStatus::NeedsResponse => Self::NeedsResponse,
        }
    }
}

impl From<CoreSummary> for SessionSummary {
    fn from(summary: CoreSummary) -> Self {
        Self {
            can_rename: summary.can_rename(),
            can_pin: summary.can_pin(),
            can_archive: summary.can_archive(),
            id: summary.id,
            title: summary.title,
            preview: summary.preview,
            status: summary.status.into(),
            pending_requests: summary.pending_requests,
            is_read_only: summary.is_read_only,
            updated_at: summary.updated_at,
            workspace: summary.workspace,
            agent_name: summary.agent_name,
            is_pinned: summary.is_pinned,
            is_archived: summary.is_archived,
            permission_level: summary.permission_level,
            failure_message: summary.failure_message,
            configuration: summary.configuration.map(Into::into),
            terminal_first: summary.terminal_first,
        }
    }
}

impl From<&SessionSummary> for CoreSummary {
    fn from(summary: &SessionSummary) -> Self {
        Self {
            status: summary.status.into(),
            pending_requests: summary.pending_requests,
            is_read_only: summary.is_read_only,
            updated_at: summary.updated_at,
            workspace: summary.workspace.clone(),
            agent_name: summary.agent_name.clone(),
            is_pinned: summary.is_pinned,
            is_archived: summary.is_archived,
            permission_level: summary.permission_level,
            failure_message: summary.failure_message.clone(),
            configuration: summary.configuration.clone().map(Into::into),
            terminal_first: summary.terminal_first,
            ..Self::new(
                summary.id.clone(),
                summary.title.clone(),
                summary.preview.clone(),
            )
        }
    }
}

impl From<SessionFilter> for CoreFilter {
    fn from(filter: SessionFilter) -> Self {
        match filter {
            SessionFilter::All => Self::All,
            SessionFilter::Running => Self::Running,
            SessionFilter::NeedsResponse => Self::NeedsResponse,
            SessionFilter::Archived => Self::Archived,
        }
    }
}

/// The sessions matching `text` and `filter`: pinned first, then most recently updated, then by
/// id, so the list never reshuffles.
#[must_use]
#[uniffi::export]
pub fn filter_sessions(
    sessions: Vec<SessionSummary>,
    text: String,
    filter: SessionFilter,
) -> Vec<SessionSummary> {
    let core: Vec<CoreSummary> = sessions.iter().map(Into::into).collect();
    let matched = session_query::matching(&core, &text, filter.into());
    let mut by_id: std::collections::HashMap<String, SessionSummary> = sessions
        .into_iter()
        .map(|summary| (summary.id.clone(), summary))
        .collect();
    matched
        .into_iter()
        .filter_map(|summary| by_id.remove(&summary.id))
        .collect()
}

/// The display title of a list filter.
#[must_use]
#[uniffi::export]
pub fn session_filter_title(filter: SessionFilter) -> String {
    CoreFilter::from(filter).title().to_owned()
}

#[uniffi::export]
impl ClientCore {
    /// Renames, pins or archives `session_id` after a fresh permission check. The updated
    /// summary is returned and also published as a `SessionListChanged` upsert.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` and `InvalidTitle` before any write;
    /// `ReadOnly` without the permission; `DeliveryUncertain` for an unreadable acknowledgement;
    /// the read and write errors.
    pub async fn edit_session(
        &self,
        session_id: String,
        change: SessionChange,
    ) -> Result<SessionSummary, CoreError> {
        let change = match change {
            SessionChange::Title { title } => CoreChange::Title(title),
            SessionChange::Pinned { pinned } => CoreChange::Pinned {
                pinned,
                at_ms: self.unix_ms(),
            },
            SessionChange::Archived { archived } => CoreChange::Archived(archived),
        };
        self.sessions()
            .edit_session(&session_id, change)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}
