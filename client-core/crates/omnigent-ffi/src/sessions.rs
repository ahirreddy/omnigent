//! Session-list records and queries. The summaries come from the core's REST session client
//! and the `/v1/sessions/updates` socket; ordering and filtering are the core's
//! (`omnigent_core::session_query`).

use futures::channel::oneshot;
use omnigent_core::projects::{self, ProjectSummary as CoreProject};
use omnigent_core::session_families::{
    self as families, SessionFamily as CoreFamily, SiblingDestinations as CoreDestinations,
};
use omnigent_core::session_query::{self, SessionFilter as CoreFilter};
use omnigent_core::session_search::SearchScope;
use omnigent_core::sessions::{
    SessionChange as CoreChange, SessionSummary as CoreSummary, SummaryStatus,
};

use crate::client::ClientCore;
use crate::configuration::SessionConfiguration;
use crate::engine::Msg;
use crate::errors::CoreError;

/// The status a session list shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SessionListStatus {
    /// Idle, including failed (see `failure_message`).
    Idle,
    /// A turn or background work is in progress.
    Running,
    /// A decision is pending, here or at a prompt in the agent's terminal.
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
    /// Whether the caller may pin it. A nested family member never may: it shows its family's
    /// pin, which its representative carries.
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
    /// The session that started this independent worker, when one did.
    #[uniffi(default)]
    pub created_by_session_id: Option<String>,
    /// The token of the nested create that made it, which its provisional row carries.
    #[uniffi(default)]
    pub client_create_token: Option<String>,
    /// The session family it belongs to; `None` for a standalone session or a shared one.
    #[uniffi(default)]
    pub family: Option<SessionFamily>,
    /// A family member nested under another representative: it is never pinned or moved on its
    /// own, and the sidebar indents it under its family.
    #[uniffi(default)]
    pub is_nested_member: bool,
    /// Work outlives its ended turn: a background shell, or a goal between turns.
    #[uniffi(default)]
    pub background_work_running: bool,
    /// What its agent is parked on in its terminal, e.g. `permission prompt`.
    #[uniffi(default)]
    pub blocked_on: Option<String>,
}

/// The session family ("nested agents") a session belongs to: independent root sessions grouped
/// under one representative. Only the caller's own sessions carry one.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SessionFamily {
    /// The family id (the original source session's id); it never changes.
    pub id: String,
    /// The representative: the oldest active member, else the oldest kept one.
    pub representative_id: Option<String>,
    /// The representative's title.
    pub representative_title: Option<String>,
    /// The caller pinned the family.
    pub pinned: bool,
    /// The family pin's sort key, when pinned.
    pub pinned_at: Option<String>,
}

/// Where "Add nested agent" may start the new member (`sibling_session_destinations`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SiblingSessionDestinations {
    /// Only the source session's host.
    CurrentHost,
    /// The source session's host, or a new managed sandbox.
    CurrentHostOrNewSandbox,
    /// Any host.
    AnyHost,
}

/// How many sessions one project folder page reads, as the web's folder.
const PROJECT_PAGE_LIMIT: u32 = 20;

/// One page of a project folder's sessions.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ProjectSessionPage {
    /// The project's sessions, most recently updated first.
    pub sessions: Vec<SessionSummary>,
    /// The cursor of the next page, if any.
    pub next_cursor: Option<String>,
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
        /// With `archived`, also remove its git worktree (`ServerPages::archive_worktree_cleanup`).
        delete_worktree: bool,
    },
    /// File into a first-class project, or `None` to remove it from its project (owner).
    Project {
        /// The project id.
        project_id: Option<String>,
    },
}

/// One session's edit in [`ClientCore::edit_sessions`].
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SessionEdit {
    /// The session.
    pub session_id: String,
    /// What to change.
    pub change: SessionChange,
}

/// An edit of [`ClientCore::edit_sessions`] that was not saved.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SessionEditFailure {
    /// The session, whose row shows what it did before the edit.
    pub session_id: String,
    /// Why, as `edit_session` reports it.
    pub error: CoreError,
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

impl From<CoreFamily> for SessionFamily {
    fn from(family: CoreFamily) -> Self {
        Self {
            id: family.id,
            representative_id: family.representative_id,
            representative_title: family.representative_title,
            pinned: family.pinned,
            pinned_at: family.pinned_at,
        }
    }
}

impl From<SessionFamily> for CoreFamily {
    fn from(family: SessionFamily) -> Self {
        Self {
            id: family.id,
            representative_id: family.representative_id,
            representative_title: family.representative_title,
            pinned: family.pinned,
            pinned_at: family.pinned_at,
        }
    }
}

impl From<CoreDestinations> for SiblingSessionDestinations {
    fn from(destinations: CoreDestinations) -> Self {
        match destinations {
            CoreDestinations::CurrentHost => Self::CurrentHost,
            CoreDestinations::CurrentHostOrNewSandbox => Self::CurrentHostOrNewSandbox,
            CoreDestinations::AnyHost => Self::AnyHost,
        }
    }
}

impl From<SiblingSessionDestinations> for CoreDestinations {
    fn from(destinations: SiblingSessionDestinations) -> Self {
        match destinations {
            SiblingSessionDestinations::CurrentHost => Self::CurrentHost,
            SiblingSessionDestinations::CurrentHostOrNewSandbox => Self::CurrentHostOrNewSandbox,
            SiblingSessionDestinations::AnyHost => Self::AnyHost,
        }
    }
}

impl From<CoreSummary> for SessionSummary {
    fn from(summary: CoreSummary) -> Self {
        Self {
            can_rename: summary.can_rename(),
            can_pin: summary.can_pin() && !summary.is_nested_member(),
            is_nested_member: summary.is_nested_member(),
            can_archive: summary.can_archive(),
            can_stop: summary.is_stoppable(),
            id: summary.id,
            title: summary.title,
            preview: summary.preview,
            status: summary.status.into(),
            pending_requests: summary.pending_requests,
            background_work_running: summary.background_work_running,
            blocked_on: summary.blocked_on,
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
            created_by_session_id: summary.created_by_session_id,
            client_create_token: summary.client_create_token,
            family: summary.family.map(Into::into),
        }
    }
}

impl From<&SessionSummary> for CoreSummary {
    fn from(summary: &SessionSummary) -> Self {
        Self {
            status: summary.status.into(),
            pending_requests: summary.pending_requests,
            background_work_running: summary.background_work_running,
            blocked_on: summary.blocked_on.clone(),
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
            created_by_session_id: summary.created_by_session_id.clone(),
            client_create_token: summary.client_create_token.clone(),
            family: summary.family.clone().map(Into::into),
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

/// Whether `session` is a family member nested under another representative: it cannot be
/// pinned or moved on its own, and the sidebar indents it under its family.
#[must_use]
#[uniffi::export]
pub fn session_is_nested_member(session: SessionSummary) -> bool {
    CoreSummary::from(&session).is_nested_member()
}

/// Whether `session` shows pinned: a nested member shows its family's pin (its loaded
/// `representative`'s row, else the family's `pinned`); any other row shows its own pin.
#[must_use]
#[uniffi::export]
pub fn session_shows_pinned(
    session: SessionSummary,
    representative: Option<SessionSummary>,
) -> bool {
    families::shows_pinned(
        &CoreSummary::from(&session),
        representative.as_ref().map(CoreSummary::from).as_ref(),
    )
}

/// Whether `session` takes a pin slot when pinned: a standalone session or its family's
/// representative. The pin limit counts these, and pin order moves them.
#[must_use]
#[uniffi::export]
pub fn session_is_pin_unit(session: SessionSummary) -> bool {
    families::is_pin_unit(&CoreSummary::from(&session))
}

/// Whether `sessions` can move to a project together.
///
/// Every nested family member among them needs its representative selected too: only
/// representatives are written, and each moves its family. `edit_sessions` refuses every move of
/// a selection that cannot.
#[must_use]
#[uniffi::export]
pub fn sessions_can_move_together(sessions: Vec<SessionSummary>) -> bool {
    let core: Vec<CoreSummary> = sessions.iter().map(Into::into).collect();
    families::can_move_together(&core)
}

/// How many pin slots `sessions` use: their pinned, unarchived standalone sessions and family
/// representatives. Nested members never use a slot.
#[must_use]
#[uniffi::export]
pub fn pinned_unit_count(sessions: Vec<SessionSummary>) -> u32 {
    let core: Vec<CoreSummary> = sessions.iter().map(Into::into).collect();
    u32::try_from(families::pinned_units(&core).len()).unwrap_or(u32::MAX)
}

/// The display title of a list filter.
#[must_use]
#[uniffi::export]
pub fn session_filter_title(filter: SessionFilter) -> String {
    CoreFilter::from(filter).title().to_owned()
}

impl ClientCore {
    /// The core's form of `change`, a pin stamped with the host clock.
    fn core_change(&self, change: SessionChange) -> CoreChange {
        match change {
            SessionChange::Title { title } => CoreChange::Title(title),
            SessionChange::Pinned { pinned } => CoreChange::Pinned {
                pinned,
                at_ms: self.unix_ms(),
            },
            SessionChange::Archived {
                archived,
                delete_worktree,
            } => CoreChange::Archived {
                archived,
                delete_worktree,
            },
            SessionChange::Project { project_id } => CoreChange::Project(project_id),
        }
    }

    /// Returns once the engine has published what the calls so far caused. A row edit and a
    /// connect answer through this, so the host holds the changed rows, or the phases passed
    /// through, before it reads the answer.
    pub(crate) async fn events_published(&self) {
        let (reply, published) = oneshot::channel();
        self.post(Msg::EventsPublished(reply));
        // The engine drops the reply only once it has shut down and publishes nothing more.
        published.await.unwrap_or(());
    }
}

#[uniffi::export]
impl ClientCore {
    /// Renames, pins or archives `session_id` after a fresh permission check. The updated
    /// summary is returned and also published as a `SessionListChanged` upsert.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` and `InvalidTitle` before any write;
    /// `ReadOnly` without the permission; `InvalidInput` for a pin or move of a nested family
    /// member (its representative carries the family); `DeliveryUncertain` for an unreadable
    /// acknowledgement; the read and write errors.
    pub async fn edit_session(
        &self,
        session_id: String,
        change: SessionChange,
    ) -> Result<SessionSummary, CoreError> {
        let edited = self
            .sessions()
            .edit_session(&session_id, self.core_change(change))
            .await;
        self.events_published().await;
        edited.map(Into::into).map_err(CoreError::from)
    }

    /// Edits several sessions at once (archiving a selection): every row changes in one
    /// `SessionListChanged` upsert before any request, then the writes run side by side.
    /// Returns the edits that were not saved, in the order given; each put its own row back.
    /// A nested family member moves with its representative's move (no write of its own); a
    /// selection where one is moved without its representative has every move refused (see
    /// `sessions_can_move_together`).
    pub async fn edit_sessions(&self, edits: Vec<SessionEdit>) -> Vec<SessionEditFailure> {
        let (ids, edits): (Vec<String>, Vec<_>) = edits
            .into_iter()
            .map(|edit| {
                let change = self.core_change(edit.change);
                (edit.session_id.clone(), (edit.session_id, change))
            })
            .unzip();
        let results = self.sessions().edit_sessions(edits).await;
        self.events_published().await;
        ids.into_iter()
            .zip(results)
            .filter_map(|(session_id, result)| {
                result.err().map(|error| SessionEditFailure {
                    session_id,
                    error: CoreError::from(error),
                })
            })
            .collect()
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
        let deleted = self.sessions().delete_session(&session_id).await;
        self.events_published().await;
        deleted.map_err(CoreError::from)
    }

    /// Deletes the session and, with `delete_branch`, its worktree and local git branch
    /// (irreversible).
    ///
    /// # Errors
    ///
    /// As `delete_session`.
    pub async fn delete_session_with_branch(
        &self,
        session_id: String,
        delete_branch: bool,
    ) -> Result<(), CoreError> {
        let deleted = self
            .sessions()
            .delete_session_with_branch(&session_id, delete_branch)
            .await;
        self.events_published().await;
        deleted.map_err(CoreError::from)
    }

    /// Leaves a session shared with the caller; it leaves the list.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the write errors.
    pub async fn leave_session(&self, session_id: String) -> Result<(), CoreError> {
        let left = self.sessions().leave_session(&session_id).await;
        self.events_published().await;
        left.map_err(CoreError::from)
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

    /// One page of the caller's unarchived sessions in `project`, most recently updated first
    /// (a sidebar folder's Show more). The sessions also reach the list as a
    /// `SessionListChanged` upsert.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidPagination`; the read errors.
    pub async fn project_sessions(
        &self,
        project: ProjectSummary,
        after: Option<String>,
    ) -> Result<ProjectSessionPage, CoreError> {
        self.sessions()
            .project_session_page(&project.name, after.as_deref(), PROJECT_PAGE_LIMIT)
            .await
            .map(|page| ProjectSessionPage {
                sessions: page.sessions.into_iter().map(Into::into).collect(),
                next_cursor: page.next_cursor,
            })
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
