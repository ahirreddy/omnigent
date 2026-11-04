//! Session-list records and queries. The summaries come from the core's REST session client
//! and the `/v1/sessions/updates` socket; ordering and filtering are the core's
//! (`omnigent_core::session_query`).

use omnigent_core::projects::{self, ProjectSummary as CoreProject};
use omnigent_core::session_query::{self, SessionFilter as CoreFilter};
use omnigent_core::session_search::SearchScope;
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
    /// Created, Unix seconds.
    #[uniffi(default)]
    pub created_at: i64,
    /// The owner's user id; `None` when unreported (the caller then owns it).
    #[uniffi(default)]
    pub owner: Option<String>,
    /// The first-class project it is filed in.
    #[uniffi(default)]
    pub project_id: Option<String>,
    /// The legacy label project it is filed in (`omni_project`).
    #[uniffi(default)]
    pub project_label: Option<String>,
    /// File review comments on it, for the Inbox.
    #[uniffi(default)]
    pub comments_count: u64,
    /// Stop can end its live process (host-spawned, or a wrapper that kills its own harness).
    #[uniffi(default)]
    pub can_stop: bool,
    /// The Pinned section's sort key (the `omnigent.pinned` label); `None` when unpinned.
    #[uniffi(default)]
    pub pin_stamp: Option<String>,
}

/// One of the caller's projects (a sidebar folder).
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ProjectSummary {
    /// The first-class id; `None` for a legacy label-only project.
    pub id: Option<String>,
    /// The name.
    pub name: String,
    /// An emoji icon, when set.
    pub icon: Option<String>,
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
    /// File into a first-class project, or `None` to remove it from its project (owner).
    Project {
        /// The project id.
        project_id: Option<String>,
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
            can_stop: summary.is_stoppable(),
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
            pin_stamp: summary.pin_stamp,
            is_archived: summary.is_archived,
            permission_level: summary.permission_level,
            failure_message: summary.failure_message,
            configuration: summary.configuration.map(Into::into),
            terminal_first: summary.terminal_first,
            created_at: summary.created_at,
            owner: summary.owner,
            project_id: summary.project_id,
            project_label: summary.project_label,
            comments_count: summary.comments_count,
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
            pin_stamp: summary.pin_stamp.clone(),
            is_archived: summary.is_archived,
            permission_level: summary.permission_level,
            failure_message: summary.failure_message.clone(),
            configuration: summary.configuration.clone().map(Into::into),
            terminal_first: summary.terminal_first,
            created_at: summary.created_at,
            owner: summary.owner.clone(),
            project_id: summary.project_id.clone(),
            project_label: summary.project_label.clone(),
            comments_count: summary.comments_count,
            ..Self::new(
                summary.id.clone(),
                summary.title.clone(),
                summary.preview.clone(),
            )
        }
    }
}

impl From<CoreProject> for ProjectSummary {
    fn from(project: CoreProject) -> Self {
        Self {
            id: project.id,
            name: project.name,
            icon: project.icon,
        }
    }
}

impl From<ProjectSummary> for CoreProject {
    fn from(project: ProjectSummary) -> Self {
        Self {
            id: project.id,
            name: project.name,
            icon: project.icon,
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

/// The session ids in each of `projects`, in `sessions`' order: sessions the viewer owns that
/// carry the project's id or its legacy label (the web's `sessionBelongsToProject`).
#[must_use]
#[uniffi::export]
pub fn project_members(
    projects: Vec<ProjectSummary>,
    sessions: Vec<SessionSummary>,
    viewer_id: Option<String>,
) -> Vec<Vec<String>> {
    let projects: Vec<CoreProject> = projects.into_iter().map(Into::into).collect();
    let sessions: Vec<CoreSummary> = sessions.iter().map(Into::into).collect();
    projects::project_members(&projects, &sessions, viewer_id.as_deref())
}

/// Whether `viewer_id` owns `session`; an unreported owner counts as the viewer's (the web's
/// `isOwnedByViewer`).
#[must_use]
#[uniffi::export]
pub fn session_is_owned_by(session: SessionSummary, viewer_id: Option<String>) -> bool {
    CoreSummary::from(&session).is_owned_by(viewer_id.as_deref())
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
            SessionChange::Project { project_id } => CoreChange::Project(project_id),
        };
        self.sessions()
            .edit_session(&session_id, change)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Ends the session's live process (`stop_session`); the transcript stays.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `ReadOnly` below edit permission; the read and write errors.
    pub async fn stop_session(&self, session_id: String) -> Result<(), CoreError> {
        self.sessions()
            .stop_session(&session_id)
            .await
            .map_err(CoreError::from)
    }

    /// Deletes the session and its history (owner); it leaves the list.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `ReadOnly` without owner permission; the read and write errors.
    pub async fn delete_session(&self, session_id: String) -> Result<(), CoreError> {
        self.sessions()
            .delete_session(&session_id)
            .await
            .map_err(CoreError::from)
    }

    /// Leaves a session shared with the caller; it leaves the list.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the write errors.
    pub async fn leave_session(&self, session_id: String) -> Result<(), CoreError> {
        self.sessions()
            .leave_session(&session_id)
            .await
            .map_err(CoreError::from)
    }

    /// The caller's projects in display order.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors (`HttpStatus` 404 on a server without projects).
    pub async fn projects(&self) -> Result<Vec<ProjectSummary>, CoreError> {
        self.sessions()
            .projects()
            .await
            .map(|projects| projects.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// Creates an empty project.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidTitle` for an empty or long name; `Rejected` for a name
    /// in use; the write errors.
    pub async fn create_project(&self, name: String) -> Result<ProjectSummary, CoreError> {
        self.sessions()
            .create_project(&name)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Renames a project (promoting a label-only one) and re-files its members.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidTitle`; the read and write errors.
    pub async fn rename_project(
        &self,
        project: ProjectSummary,
        name: String,
    ) -> Result<ProjectSummary, CoreError> {
        self.sessions()
            .rename_project(&project.into(), &name)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Deletes a project after archiving and unfiling its members (never deleting them).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read and write errors; the first member failure, with the
    /// project kept.
    pub async fn delete_project(&self, project: ProjectSummary) -> Result<(), CoreError> {
        self.sessions()
            .delete_project(&project.into())
            .await
            .map_err(CoreError::from)
    }

    /// Up to `limit` sessions whose title (or, with `in_messages`, message content) matches
    /// `query`, archived included. Content matches carry the snippet as their preview.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors.
    pub async fn search_sessions(
        &self,
        query: String,
        in_messages: bool,
        limit: u32,
    ) -> Result<Vec<SessionSummary>, CoreError> {
        let scope = if in_messages {
            SearchScope::Content
        } else {
            SearchScope::Title
        };
        self.sessions()
            .search_sessions(&query, scope, limit)
            .await
            .map(|found| found.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }
}
