//! Session summaries: the list-row model the UI shows, and how REST rows, snapshots and
//! `/v1/sessions/updates` rows become one.
//!
//! Port of `NativeLab`'s `SessionSummary` (`Models.swift`) and `SessionWire.summary(previous:)`
//! (`LocalServerSessionClient.swift`). A list row ([`SessionListItem`]) and a snapshot
//! ([`SessionSnapshot`]) both project onto a [`SessionProjection`]: every field keeps the
//! difference between "not sent" (keep what is known), `null` (clear it) and a value, so a sparse
//! list row never clears detail-only configuration, while an explicit `null` still does.

use std::collections::{BTreeMap, BTreeSet};

use omnigent_protocol::sessions::{
    PullRequestSummary, SandboxStatus, SessionFamily, SessionList, SessionListItem,
    SessionSnapshot, SessionStatus,
};
use omnigent_protocol::{DecodeError, Field, FromWire, ServerStreamEvent};
use serde_json::{Value, json};

use super::pin_order::PinStamp;
use super::requests::{page_query, validate_identifier};
use super::{ClientCore, ClientEvent, SessionError, State, lock};
use crate::config::session::{ModelChoice, SessionConfiguration};
use crate::creation::MAX_TITLE_CHARS;
use crate::http::HttpTransport;
use crate::intents::SessionPatch;
use crate::reconcile::UNTITLED_SESSION;
use crate::sandbox_state::SandboxLaunch;

/// The status a session list shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SummaryStatus {
    /// Idle (including failed; see [`SessionSummary::failure_message`]).
    Idle,
    /// A turn or background work is in progress.
    Running,
    /// A decision is pending, here or at a prompt in the agent's terminal.
    NeedsResponse,
}

/// One session as the list shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts a list row shows; mirrored one to one as an FFI record"
)]
pub struct SessionSummary {
    /// Session id.
    pub id: String,
    /// Title, or "Untitled session".
    pub title: String,
    /// The secondary line: search snippet, pending hint or status.
    pub preview: String,
    /// List status.
    pub status: SummaryStatus,
    /// Pending decisions the server reports: the list row's `pending_elicitations_count`, or the
    /// snapshot's pending requests (which include sub-agent requests it carries).
    pub pending_requests: u32,
    /// Work outlives its ended turn (`background_work_running`): a background shell, or a goal
    /// between turns. The status stays as reported, so the session still takes a message.
    pub background_work_running: bool,
    /// What its agent is parked on in its terminal (`blocked_on`), e.g. `permission prompt`.
    pub blocked_on: Option<String>,
    /// Below edit permission (or unknown permission).
    pub is_read_only: bool,
    /// Last activity, Unix seconds.
    pub updated_at: i64,
    /// Workspace path or label.
    pub workspace: String,
    /// Agent display name.
    pub agent_name: String,
    /// Pinned (`omnigent.pinned` label set).
    pub is_pinned: bool,
    /// The `omnigent.pinned` label: the Pinned section's sort key (epoch milliseconds, or a
    /// value between two neighbours after a drag), `None` when unpinned.
    pub pin_stamp: Option<String>,
    /// Archived.
    pub is_archived: bool,
    /// Its harness TUI is the primary view (`omnigent.ui = terminal`): a Chat/Terminal switcher.
    pub terminal_first: bool,
    /// The caller's permission level, when known.
    pub permission_level: Option<i64>,
    /// For a failed session: the last task error, or a generic message.
    pub failure_message: Option<String>,
    /// How the session runs.
    pub configuration: Option<SessionConfiguration>,
    /// Monotonic stamp of the metadata read this summary came from; higher is newer.
    pub configuration_revision: Option<u64>,
    /// The caller's read state as the server last reported it (`viewer_last_seen`,
    /// `viewer_unread` on list and update rows); `None` until a row reports it.
    pub viewer_read: Option<ViewerRead>,
    /// Created, Unix seconds.
    pub created_at: i64,
    /// The owner's user id; `None` when unreported (single-user servers own everything).
    pub owner: Option<String>,
    /// The first-class project it is filed in (`project_id`).
    pub project_id: Option<String>,
    /// The legacy label project it is filed in (`omni_project` label).
    pub project_label: Option<String>,
    /// File review comments on it (`comments_count`), for the Inbox's comment side.
    pub comments_count: u64,
    /// The session that started this independent worker (`omnigent.created_by_session_id`).
    pub created_by_session_id: Option<String>,
    /// The token of the nested create that made it (`omnigent.client_create_token`), so the
    /// create's provisional row knows it before the create answers.
    pub client_create_token: Option<String>,
    /// The automation that starts each run from a copy of this session
    /// (`omnigent.scheduled_task_source`).
    pub automation_source_id: Option<String>,
    /// The session family it belongs to; `None` for a standalone session or a shared one.
    pub family: Option<SessionFamily>,
    /// The first PR the server stores for it (`pull_request`), for its row's tooltip.
    pub pull_request: Option<RowPullRequest>,
    /// An automation's run made it, or a run's session tree launched it (the
    /// `omnigent.scheduled_task_origin` with `_initial_run` labels, or `_launch`).
    pub is_automation_run: bool,
}

/// The PR a session's list row names, as the server last stored it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RowPullRequest {
    /// Its number.
    pub number: u64,
    /// Where it stood when its host last fetched it; `Unknown` before that.
    pub status: super::pull_requests::PullRequestStatus,
    /// When its host last fetched it, Unix seconds.
    pub checked_at: Option<i64>,
}

impl RowPullRequest {
    /// A list row's `pull_request`.
    #[allow(
        clippy::as_conversions,
        clippy::cast_possible_truncation,
        reason = "float-to-int `as` saturates, and whole seconds are all a tooltip shows"
    )]
    fn from_summary(pull_request: &PullRequestSummary) -> Self {
        Self {
            number: pull_request.number,
            status: super::pull_requests::PullRequestStatus::of(
                pull_request.state.as_deref(),
                pull_request.is_draft,
            ),
            checked_at: pull_request
                .state_checked_at
                .filter(|seconds| seconds.is_finite())
                .map(|seconds| seconds.floor() as i64),
        }
    }
}

/// Labels an automation's run puts on the session it made, and on those its tree launched.
const AUTOMATION_ORIGIN_LABEL: &str = "omnigent.scheduled_task_origin";
const AUTOMATION_INITIAL_RUN_LABEL: &str = "omnigent.scheduled_task_initial_run";
const AUTOMATION_LAUNCH_LABEL: &str = "omnigent.scheduled_task_launch";

/// Whether `labels` mark a session an automation's run made or launched (the web's
/// `isSharedAutomationRun` without its ownership check).
fn is_automation_run(labels: &BTreeMap<String, String>) -> bool {
    let set = |key: &str| labels.get(key).is_some_and(|value| !value.is_empty());
    (set(AUTOMATION_ORIGIN_LABEL) && set(AUTOMATION_INITIAL_RUN_LABEL))
        || set(AUTOMATION_LAUNCH_LABEL)
}

/// The caller's read state for one session, as the server reports it
/// (`PUT /v1/sessions/{id}/read-state` writes it).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ViewerRead {
    /// When the caller last saw the session, Unix seconds; `None` when never.
    pub last_seen: Option<i64>,
    /// The caller explicitly marked it unread.
    pub unread: bool,
}

impl SessionSummary {
    /// A summary with the list defaults for everything but `id`, `title` and `preview`.
    #[must_use]
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        preview: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            preview: preview.into(),
            status: SummaryStatus::Idle,
            pending_requests: 0,
            background_work_running: false,
            blocked_on: None,
            is_read_only: false,
            updated_at: 0,
            workspace: "Omni mobile".to_owned(),
            agent_name: "Omni".to_owned(),
            is_pinned: false,
            pin_stamp: None,
            is_archived: false,
            terminal_first: false,
            permission_level: None,
            failure_message: None,
            configuration: None,
            configuration_revision: None,
            viewer_read: None,
            created_at: 0,
            owner: None,
            project_id: None,
            project_label: None,
            comments_count: 0,
            created_by_session_id: None,
            client_create_token: None,
            automation_source_id: None,
            family: None,
            pull_request: None,
            is_automation_run: false,
        }
    }

    /// Whether its agent waits on a prompt in its terminal (the web's `parkedInTerminal`).
    #[must_use]
    pub const fn is_parked_in_terminal(&self) -> bool {
        matches!(self.status, SummaryStatus::NeedsResponse) && self.blocked_on.is_some()
    }

    /// Whether it is a family member nested under another representative (the web's
    /// `isIndentedSibling`): it cannot be pinned or moved on its own.
    #[must_use]
    pub fn is_nested_member(&self) -> bool {
        self.family
            .as_ref()
            .is_some_and(|family| family.nests(&self.id))
    }

    /// Edit level (2) or above; without a level, the inverse of [`Self::is_read_only`].
    #[must_use]
    pub fn can_rename(&self) -> bool {
        self.permission_level
            .map_or(!self.is_read_only, |level| level >= 2)
    }

    /// View level (1) or above; without a level, the inverse of [`Self::is_read_only`].
    #[must_use]
    pub fn can_pin(&self) -> bool {
        self.permission_level
            .map_or(!self.is_read_only, |level| level >= 1)
    }

    /// Owner level (4) or above; without a level, the inverse of [`Self::is_read_only`].
    #[must_use]
    pub fn can_archive(&self) -> bool {
        self.permission_level
            .map_or(!self.is_read_only, |level| level >= 4)
    }

    /// Whether `viewer_id` owns it. A session without a reported owner counts as owned, as on
    /// the web (`isOwnedByViewer`).
    #[must_use]
    pub fn is_owned_by(&self, viewer_id: Option<&str>) -> bool {
        self.owner
            .as_deref()
            .is_none_or(|owner| Some(owner) == viewer_id)
    }

    /// Whether Stop can end it: a host-spawned runner (the server kills it through the host), or
    /// a wrapper whose runner kills its own harness. A local in-process runner cannot be stopped.
    #[must_use]
    pub fn is_stoppable(&self) -> bool {
        let Some(configuration) = &self.configuration else {
            return false;
        };
        let wrapper_stops = configuration
            .wrapper
            .as_deref()
            .is_some_and(|wrapper| STOPPABLE_WRAPPERS.contains(&wrapper));
        let host_spawned =
            configuration.host_id.is_some() && configuration.runner_bound == Some(true);
        wrapper_stops || host_spawned
    }

    /// `self`, unless `current` is the same session with newer metadata: then `current`. The
    /// caller merges transcript content separately.
    #[must_use]
    pub fn preserving_newer_metadata(self, current: Option<&Self>) -> Self {
        let Some(current) = current.filter(|current| current.id == self.id) else {
            return self;
        };
        let Some(latest) = current.configuration_revision else {
            return self;
        };
        match self.configuration_revision {
            Some(incoming) if incoming >= latest => self,
            _ => current.clone(),
        }
    }
}

/// Wrappers whose runner kills the harness itself (the web's `STOPPABLE_WRAPPERS`).
const STOPPABLE_WRAPPERS: [&str; 2] = ["claude-code-native-ui", "devin-native-ui"];

/// The legacy label a session's project name is stored under.
pub const PROJECT_LABEL: &str = "omni_project";

/// The label a pin is stored under; its value is the Pinned section's sort key.
pub const PINNED_LABEL: &str = "omnigent.pinned";

/// The label naming the session that started an independent worker.
pub const CREATED_BY_SESSION_LABEL: &str = "omnigent.created_by_session_id";

/// The label the server puts on an automation's session copy; its value is the automation's id.
pub const AUTOMATION_SOURCE_LABEL: &str = "omnigent.scheduled_task_source";

/// A change to a session's organisation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionChange {
    /// Rename; the title is trimmed and must be 1 to 120 characters.
    Title(String),
    /// Pin (stamped with `at_ms`, milliseconds since the Unix epoch) or unpin.
    Pinned {
        /// Pin or unpin.
        pinned: bool,
        /// The host's wall-clock time, used as the pin's ordering stamp.
        at_ms: u64,
    },
    /// Re-pin at an explicit sort key (a drag in the Pinned section); see
    /// [`crate::client::pin_order`].
    PinnedAt(PinStamp),
    /// Archive or restore.
    Archived {
        /// Archive or restore.
        archived: bool,
        /// With `archived`, also remove the session's git worktree (servers that report
        /// `archive_worktree_cleanup`; the branch is kept).
        delete_worktree: bool,
    },
    /// File into a first-class project, or `None` to remove it from its project. The legacy
    /// label is cleared either way so the two representations never disagree.
    Project(Option<String>),
}

/// One page of the session list.
#[derive(Debug, Clone, PartialEq)]
pub struct SessionPage {
    /// Summaries in server order, repeated ids dropped.
    pub sessions: Vec<SessionSummary>,
    /// The `after` cursor for the next page.
    pub next_cursor: Option<String>,
    /// How many of the server's rows the page selected itself, before the members of their
    /// session families it appended: what a read of the same window asks for again.
    pub selected_rows: usize,
    /// The server's rows as read, for the device's saved copy of the list.
    pub rows: Vec<SessionListItem>,
}

/// The summaries of session list rows saved on this device, as the list shows them with no other
/// read merged in: repeated ids and side chats dropped.
///
/// # Errors
///
/// [`SessionError::MalformedResponse`] for a row the list cannot show.
pub fn saved_summaries(rows: &[SessionListItem]) -> Result<Vec<SessionSummary>, SessionError> {
    let mut seen = BTreeSet::new();
    let mut summaries = Vec::new();
    for row in rows {
        let projection = SessionProjection::from_list_item(row);
        if !seen.insert(row.id.as_str()) || projection.is_side_chat() {
            continue;
        }
        let summary = projection
            .summary(None)
            .map_err(|detail| SessionError::MalformedResponse { detail })?;
        summaries.push(summary);
    }
    Ok(summaries)
}

/// The fields of a list row or snapshot that a summary is derived from, presence kept.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct SessionProjection {
    pub(crate) id: String,
    status: SessionStatus,
    created_at: i64,
    updated_at: Field<i64>,
    title: Field<String>,
    agent_name: Field<String>,
    workspace: Field<String>,
    labels: Field<BTreeMap<String, String>>,
    archived: Field<bool>,
    pending_count: Field<u64>,
    /// The snapshot's pending requests; `None` for a list row.
    pending_elicitations: Option<usize>,
    /// A list row's background work; a snapshot does not carry it.
    background_work_running: Field<bool>,
    /// A list row's terminal prompt; a snapshot does not carry it.
    blocked_on: Field<String>,
    search_snippet: Field<String>,
    permission_level: Field<i64>,
    last_task_error_message: Option<String>,
    agent_id: Field<String>,
    harness: Field<String>,
    model_override: Field<String>,
    base_model: Field<String>,
    effort: Field<String>,
    model_options: Field<Vec<ModelChoice>>,
    host_id: Field<String>,
    host_online: Field<bool>,
    runner_online: Field<bool>,
    runner_id: Field<String>,
    host_resumable: Field<bool>,
    /// The snapshot's managed-sandbox launch; a list row does not carry it.
    sandbox_status: Field<SandboxStatus>,
    parent_id: Field<String>,
    routing_mode: Field<String>,
    launch_args: Field<Vec<String>>,
    git_branch: Field<String>,
    viewer_last_seen: Field<i64>,
    viewer_unread: Field<bool>,
    owner: Field<String>,
    project_id: Field<String>,
    comments_count: Field<u64>,
    family: Field<SessionFamily>,
    /// A list row's stored PR; a snapshot does not carry it.
    pull_request: Field<PullRequestSummary>,
}

impl SessionProjection {
    /// A side chat, which belongs to its session's tab rather than the list.
    pub(crate) fn is_side_chat(&self) -> bool {
        self.labels
            .value()
            .and_then(|labels| labels.get(super::session_tools::SIDE_CHAT_LABEL))
            .is_some_and(|value| value == "1")
    }

    /// Records the session's host and routing parent for replica routing.
    pub(crate) fn record_routing(&self, routing: &mut super::routing::ReplicaRouting) {
        fn reported(field: &Field<String>) -> super::routing::Reported<'_> {
            match field {
                Field::Absent => super::routing::Reported::Unsaid,
                Field::Null => super::routing::Reported::Cleared,
                Field::Present(value) => super::routing::Reported::Value(value),
            }
        }
        let labels = match &self.labels {
            Field::Present(labels) => Some(labels),
            Field::Absent | Field::Null => None,
        };
        routing.record(
            &self.id,
            reported(&self.host_id),
            reported(&self.parent_id),
            labels,
        );
    }

    /// A `GET /v1/sessions` or `/v1/sessions/updates` row. It has no snapshot-only fields, so
    /// applying it never clears them.
    pub(crate) fn from_list_item(row: &SessionListItem) -> Self {
        Self {
            id: row.id.clone(),
            status: row.status.clone(),
            created_at: row.created_at,
            updated_at: row.updated_at.clone(),
            title: row.title.clone(),
            agent_name: row.agent_name.clone(),
            workspace: row.workspace.clone(),
            labels: row.labels.clone(),
            archived: row.archived.clone(),
            pending_count: row.pending_elicitations_count.clone(),
            pending_elicitations: None,
            // A list row omits them only when unset, or when its server predates them.
            background_work_running: reported_or_null(&row.background_work_running),
            blocked_on: reported_or_null(&row.blocked_on),
            search_snippet: row.search_snippet.clone(),
            permission_level: row.permission_level.clone(),
            last_task_error_message: None,
            agent_id: row.agent_id.clone(),
            harness: row.harness.clone(),
            model_override: Field::Absent,
            base_model: Field::Absent,
            effort: row.reasoning_effort.clone(),
            model_options: Field::Absent,
            host_id: row.host_id.clone(),
            host_online: row.host_online.clone(),
            runner_online: row.runner_online.clone(),
            runner_id: row.runner_id.clone(),
            host_resumable: Field::Absent,
            sandbox_status: Field::Absent,
            parent_id: row.parent_session_id.clone(),
            routing_mode: Field::Absent,
            launch_args: Field::Absent,
            git_branch: row.git_branch.clone(),
            viewer_last_seen: row.viewer_last_seen.clone(),
            viewer_unread: row.viewer_unread.clone(),
            owner: row.owner.clone(),
            project_id: row.project_id.clone(),
            comments_count: row.comments_count.clone(),
            // A list row omits `family` only when it has none (update rows send `null`).
            family: reported_or_null(&row.family),
            pull_request: reported_or_null(&row.pull_request),
        }
    }

    /// A `GET /v1/sessions/{id}` (or `PATCH`, `switch-agent`, create) snapshot. `model_options`
    /// is read from the raw body so "not reported" and `[]` stay distinct.
    pub(crate) fn from_snapshot(
        snapshot: &SessionSnapshot,
        model_options: Field<Vec<ModelChoice>>,
    ) -> Self {
        Self {
            id: snapshot.id.clone(),
            status: snapshot.status.clone(),
            created_at: snapshot.created_at,
            updated_at: snapshot.updated_at.clone(),
            title: snapshot.title.clone(),
            agent_name: snapshot.agent_name.clone(),
            workspace: snapshot.workspace.clone(),
            labels: snapshot.labels.clone(),
            archived: snapshot.archived.clone(),
            pending_count: Field::Absent,
            pending_elicitations: Some(snapshot.pending_elicitations.len()),
            background_work_running: Field::Absent,
            blocked_on: Field::Absent,
            search_snippet: Field::Absent,
            permission_level: snapshot.permission_level.clone(),
            last_task_error_message: snapshot
                .last_task_error
                .value()
                .and_then(|error| error.get("message").cloned()),
            agent_id: snapshot.agent_id.clone(),
            harness: snapshot.harness.clone(),
            model_override: snapshot.model_override.clone(),
            base_model: snapshot.llm_model.clone(),
            effort: snapshot.reasoning_effort.clone(),
            model_options,
            host_id: snapshot.host_id.clone(),
            host_online: snapshot.host_online.clone(),
            runner_online: snapshot.runner_online.clone(),
            runner_id: snapshot.runner_id.clone(),
            host_resumable: snapshot.host_resumable.clone(),
            sandbox_status: snapshot.sandbox_status.clone(),
            parent_id: snapshot.parent_session_id.clone(),
            routing_mode: snapshot.cost_control_mode_override.clone(),
            launch_args: snapshot.terminal_launch_args.clone(),
            git_branch: snapshot.git_branch.clone(),
            viewer_last_seen: Field::Absent,
            viewer_unread: Field::Absent,
            owner: Field::Absent,
            project_id: snapshot.project_id.clone(),
            comments_count: Field::Absent,
            family: snapshot.family.clone(),
            pull_request: Field::Absent,
        }
    }

    /// Whether the row reports the harness and model, so it can replace detail metadata.
    pub(crate) const fn has_configuration_identity(&self) -> bool {
        self.harness.is_reported() && self.model_override.is_reported()
    }

    /// Pending decisions: the reported count or the snapshot's requests, whichever is larger,
    /// so a pending decision is never hidden. A list row without a count reports none.
    fn pending_requests(&self) -> u32 {
        let reported = self.pending_count.value().copied().unwrap_or(0);
        let carried = u64::try_from(self.pending_elicitations.unwrap_or(0)).unwrap_or(u64::MAX);
        // More than four billion pending decisions saturates rather than wrapping.
        u32::try_from(reported.max(carried)).unwrap_or(u32::MAX)
    }

    /// The summary, merged over `previous` (the last summary of the same session, if any).
    ///
    /// # Errors
    ///
    /// A status this client does not know.
    #[allow(
        clippy::too_many_lines,
        reason = "one plain field merge per summary field; splitting it scatters the merge rules"
    )]
    pub(crate) fn summary(
        &self,
        previous: Option<&SessionSummary>,
    ) -> Result<SessionSummary, String> {
        let pending_requests = self.pending_requests();
        let background_work_running = match self.background_work_running {
            Field::Absent => previous.is_some_and(|previous| previous.background_work_running),
            Field::Null => false,
            Field::Present(running) => running,
        };
        let blocked_on = reported_or_previous(
            &self.blocked_on,
            previous.and_then(|previous| previous.blocked_on.as_ref()),
        );
        let (status, status_preview) = match &self.status {
            SessionStatus::Idle => (SummaryStatus::Idle, "Idle"),
            SessionStatus::Running => (SummaryStatus::Running, "Running"),
            SessionStatus::Waiting => (SummaryStatus::Running, "Waiting"),
            SessionStatus::Launching => (SummaryStatus::Running, "Launching"),
            SessionStatus::Failed => (SummaryStatus::Idle, "Failed"),
            SessionStatus::Unknown { value } => {
                return Err(format!("unknown session status {value:?}"));
            }
        };
        let permission_level = match &self.permission_level {
            Field::Absent => previous.and_then(|previous| previous.permission_level),
            Field::Null => None,
            Field::Present(level) => Some(*level),
        };
        let is_read_only = permission_level.map_or_else(
            || self.permission_level.is_reported() || previous.is_none_or(|p| p.is_read_only),
            |level| level < 2,
        );
        // A running agent parked on a prompt in its terminal waits on the user, as a decision does.
        let parked = status == SummaryStatus::Running && blocked_on.is_some();
        let labels = self.labels.value();
        let configuration = self.configuration(previous.and_then(|p| p.configuration.as_ref()));
        Ok(SessionSummary {
            id: self.id.clone(),
            title: self
                .title
                .value()
                .filter(|title| !title.is_empty())
                .cloned()
                .unwrap_or_else(|| UNTITLED_SESSION.to_owned()),
            preview: if pending_requests > 0 {
                "Needs your response".to_owned()
            } else if let Some(reason) = blocked_on.as_deref().filter(|_| parked) {
                terminal_wait_preview(reason)
            } else {
                self.search_snippet
                    .value()
                    .cloned()
                    .unwrap_or_else(|| status_preview.to_owned())
            },
            status: if pending_requests > 0 || parked {
                SummaryStatus::NeedsResponse
            } else {
                status
            },
            pending_requests,
            background_work_running,
            blocked_on,
            is_read_only,
            updated_at: self
                .updated_at
                .value()
                .copied()
                .or_else(|| previous.map(|previous| previous.updated_at))
                .unwrap_or(self.created_at),
            workspace: self
                .workspace
                .value()
                .cloned()
                .unwrap_or_else(|| "Local server".to_owned()),
            agent_name: self
                .agent_name
                .value()
                .cloned()
                .unwrap_or_else(|| "Omnigent".to_owned()),
            is_pinned: labels
                .and_then(|labels| labels.get(PINNED_LABEL))
                .is_some_and(|stamp| !stamp.is_empty()),
            pin_stamp: labels
                .and_then(|labels| labels.get(PINNED_LABEL))
                .filter(|stamp| !stamp.is_empty())
                .cloned(),
            is_archived: self.archived.value().copied().unwrap_or(false),
            terminal_first: match &self.labels {
                Field::Absent => previous.is_some_and(|previous| previous.terminal_first),
                Field::Null => false,
                Field::Present(labels) => crate::terminal::is_terminal_first(labels),
            },
            permission_level,
            failure_message: (self.status == SessionStatus::Failed).then(|| {
                self.last_task_error_message.clone().unwrap_or_else(|| {
                    omnigent_protocol::sessions::DEFAULT_FAILURE_MESSAGE.to_owned()
                })
            }),
            configuration: Some(configuration),
            configuration_revision: None,
            viewer_read: self.viewer_read(previous),
            created_at: self.created_at,
            owner: reported_or_previous(&self.owner, previous.and_then(|p| p.owner.as_ref())),
            project_id: reported_or_previous(
                &self.project_id,
                previous.and_then(|p| p.project_id.as_ref()),
            ),
            project_label: match &self.labels {
                Field::Absent => previous.and_then(|previous| previous.project_label.clone()),
                Field::Null => None,
                Field::Present(labels) => labels
                    .get(PROJECT_LABEL)
                    .filter(|name| !name.is_empty())
                    .cloned(),
            },
            comments_count: match &self.comments_count {
                Field::Absent => previous.map_or(0, |previous| previous.comments_count),
                Field::Null => 0,
                Field::Present(count) => *count,
            },
            created_by_session_id: match &self.labels {
                Field::Absent => {
                    previous.and_then(|previous| previous.created_by_session_id.clone())
                }
                Field::Null => None,
                Field::Present(labels) => labels
                    .get(CREATED_BY_SESSION_LABEL)
                    .filter(|id| !id.is_empty())
                    .cloned(),
            },
            client_create_token: match &self.labels {
                Field::Absent => previous.and_then(|previous| previous.client_create_token.clone()),
                Field::Null => None,
                Field::Present(labels) => labels
                    .get(crate::nested_creation::CLIENT_CREATE_TOKEN_LABEL)
                    .filter(|token| !token.is_empty())
                    .cloned(),
            },
            automation_source_id: match &self.labels {
                Field::Absent => {
                    previous.and_then(|previous| previous.automation_source_id.clone())
                }
                Field::Null => None,
                Field::Present(labels) => labels
                    .get(AUTOMATION_SOURCE_LABEL)
                    .filter(|id| !id.is_empty())
                    .cloned(),
            },
            family: match &self.family {
                Field::Absent => previous.and_then(|previous| previous.family.clone()),
                Field::Null => None,
                Field::Present(family) => Some(family.clone()),
            },
            pull_request: match &self.pull_request {
                Field::Absent => previous.and_then(|previous| previous.pull_request),
                Field::Null => None,
                Field::Present(pull_request) => Some(RowPullRequest::from_summary(pull_request)),
            },
            is_automation_run: match &self.labels {
                Field::Absent => previous.is_some_and(|previous| previous.is_automation_run),
                Field::Null => false,
                Field::Present(labels) => is_automation_run(labels),
            },
        })
    }

    /// The reported read state, else the previous summary's.
    fn viewer_read(&self, previous: Option<&SessionSummary>) -> Option<ViewerRead> {
        if self.viewer_last_seen.is_reported() || self.viewer_unread.is_reported() {
            Some(ViewerRead {
                last_seen: self.viewer_last_seen.value().copied(),
                unread: self.viewer_unread.value().copied().unwrap_or(false),
            })
        } else {
            previous.and_then(|previous| previous.viewer_read)
        }
    }

    /// Where the session runs and whether that is up: its host, runner and sandbox launch.
    fn apply_execution(&self, configuration: &mut SessionConfiguration) {
        if self.host_id.is_reported() {
            let host_id = self.host_id.value().cloned();
            if configuration.host_id != host_id {
                configuration.host_online = None;
                configuration.runner_online = None;
                configuration.runner_bound = None;
                configuration.host_resumable = None;
                // A host arriving ends the launch, whatever the last snapshot said.
                configuration.sandbox_launching = None;
                configuration.sandbox_launch = None;
            }
            configuration.host_id = host_id;
        }
        if self.sandbox_status.is_reported() {
            configuration.sandbox_launching = Some(
                self.sandbox_status
                    .value()
                    .is_some_and(SandboxStatus::is_launching),
            );
            configuration.sandbox_launch = self
                .sandbox_status
                .value()
                .and_then(SandboxLaunch::of)
                .and_then(SandboxLaunch::unfinished);
        }
        self.host_online
            .clone()
            .apply_to(&mut configuration.host_online);
        self.runner_online
            .clone()
            .apply_to(&mut configuration.runner_online);
        if self.runner_id.is_reported() {
            configuration.runner_bound =
                Some(self.runner_id.value().is_some_and(|id| !id.is_empty()));
        }
        self.host_resumable
            .clone()
            .apply_to(&mut configuration.host_resumable);
    }

    fn configuration(&self, prior: Option<&SessionConfiguration>) -> SessionConfiguration {
        let same = |field: &Field<String>, known: Option<&String>| match field {
            Field::Absent => true,
            Field::Null => known.is_none(),
            Field::Present(value) => known == Some(value),
        };
        let same_agent = same(&self.agent_id, prior.and_then(|p| p.agent_id.as_ref()))
            && same(&self.harness, prior.and_then(|p| p.harness.as_ref()));
        // List projections omit detail fields; explicit nulls still clear confirmed values.
        let mut configuration = if same_agent {
            prior.cloned().unwrap_or_default()
        } else {
            SessionConfiguration::default()
        };
        // Execution belongs to the session, even when a sparse update changes its harness.
        configuration.host_id = prior.and_then(|p| p.host_id.clone());
        configuration.host_online = prior.and_then(|p| p.host_online);
        configuration.runner_online = prior.and_then(|p| p.runner_online);
        configuration.runner_bound = prior.and_then(|p| p.runner_bound);
        configuration.host_resumable = prior.and_then(|p| p.host_resumable);
        configuration.sandbox_launching = prior.and_then(|p| p.sandbox_launching);
        configuration.sandbox_launch = prior.and_then(|p| p.sandbox_launch.clone());
        self.agent_id.clone().apply_to(&mut configuration.agent_id);
        self.harness.clone().apply_to(&mut configuration.harness);
        if self.labels.is_reported() {
            configuration.wrapper = self
                .labels
                .value()
                .and_then(|labels| labels.get("omnigent.wrapper").cloned());
        }
        if self.model_override.is_reported() {
            configuration.model_override = self.model_override.value().cloned();
            configuration.model_reported = Some(true);
        }
        self.base_model
            .clone()
            .apply_to(&mut configuration.base_model);
        if self.effort.is_reported() {
            configuration.effort = self.effort.value().cloned();
            configuration.effort_reported = Some(true);
        }
        if self.model_options.is_reported() {
            configuration.models = self.model_options.value().cloned().unwrap_or_default();
        }
        self.apply_execution(&mut configuration);
        self.parent_id
            .clone()
            .apply_to(&mut configuration.parent_id);
        self.routing_mode
            .clone()
            .apply_to(&mut configuration.routing_mode);
        if let Some(mode) = crate::config::approval::reported_approval_mode(
            configuration.wrapper.as_deref(),
            &self.labels,
            &self.launch_args,
        ) {
            configuration.approval_mode = mode;
        }
        self.git_branch
            .clone()
            .apply_to(&mut configuration.git_branch);
        configuration
    }
}

/// A reported non-empty value, `None` for `null` or empty, else `previous`.
fn reported_or_previous(field: &Field<String>, previous: Option<&String>) -> Option<String> {
    match field {
        Field::Absent => previous.cloned(),
        Field::Null => None,
        Field::Present(value) => Some(value.clone()).filter(|value| !value.is_empty()),
    }
}

/// `field`, with "not sent" read as `null`: for a full row that omits what it does not have.
fn reported_or_null<T: Clone>(field: &Field<T>) -> Field<T> {
    match field {
        Field::Absent => Field::Null,
        reported => reported.clone(),
    }
}

/// The runner's `blocked_on` when it only guesses a prompt from the terminal's screen.
const TERMINAL_PROMPT_BLOCKED_ON: &str = "terminal prompt";

/// The web's words for an agent parked on a prompt in its terminal; a guessed prompt stays
/// tentative.
fn terminal_wait_preview(reason: &str) -> String {
    if reason == TERMINAL_PROMPT_BLOCKED_ON {
        "May need your input in the agent's terminal".to_owned()
    } else {
        format!("Waiting for you in the agent's terminal ({reason})")
    }
}

/// A decoded snapshot body: the typed snapshot and its projection.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct DecodedSnapshot {
    pub(crate) snapshot: SessionSnapshot,
    pub(crate) projection: SessionProjection,
}

/// Decodes a `SessionResponse` body.
///
/// # Errors
///
/// A description when the body is not a snapshot (or its `model_options` are malformed).
pub(crate) fn decode_snapshot(body: &[u8]) -> Result<DecodedSnapshot, String> {
    let value: Value = serde_json::from_slice(body).map_err(|error| error.to_string())?;
    decode_snapshot_value(value)
}

/// [`decode_snapshot`] for an already-parsed body.
///
/// # Errors
///
/// As [`decode_snapshot`].
pub(crate) fn decode_snapshot_value(value: Value) -> Result<DecodedSnapshot, String> {
    let model_options = match value.get("model_options") {
        None => Field::Absent,
        Some(Value::Null) => Field::Null,
        Some(Value::Array(options)) => Field::Present(
            options
                .iter()
                .map(ModelChoice::from_value)
                .collect::<Result<Vec<_>, String>>()?,
        ),
        Some(_) => return Err("`model_options` is not an array".to_owned()),
    };
    // `SessionResponse` has no count, but sparse payloads (NativeLab's `SessionWire`) may carry
    // one; it must not be ignored.
    let pending_count = match value.get("pending_elicitations_count") {
        None => Field::Absent,
        Some(Value::Null) => Field::Null,
        Some(count) => Field::Present(
            count
                .as_u64()
                .ok_or("`pending_elicitations_count` is not a count")?,
        ),
    };
    let snapshot =
        SessionSnapshot::from_value(value).map_err(|error: DecodeError| error.to_string())?;
    let mut projection = SessionProjection::from_snapshot(&snapshot, model_options);
    projection.pending_count = pending_count;
    Ok(DecodedSnapshot {
        snapshot,
        projection,
    })
}

/// Decodes one list or updates row.
///
/// # Errors
///
/// A description when the row is not a `SessionListItem`.
pub(crate) fn decode_list_row(value: Value) -> Result<SessionProjection, String> {
    SessionListItem::from_value(value)
        .map(|row| SessionProjection::from_list_item(&row))
        .map_err(|error| error.to_string())
}

/// How many rows one inventory page asks for.
pub const INVENTORY_PAGE_LIMIT: u32 = 500;
/// The default list page size.
pub const DEFAULT_PAGE_LIMIT: u32 = 50;
/// How many items one page of older history asks for. Larger than the page a session opens
/// with, so reading far back takes a quarter of the round trips.
pub const OLDER_HISTORY_PAGE_LIMIT: u32 = 200;
/// How many rows one Canvas page asks for: the server's maximum.
pub const CANVAS_PAGE_LIMIT: u32 = 1_000;
/// How many pinned sessions the list reads beside its first page; the Pinned section rarely
/// holds more.
pub const PINNED_PAGE_LIMIT: u32 = 50;
/// The most sessions the Canvas shows, as the web.
pub const MAX_CANVAS_SESSIONS: usize = 5_000;

/// Event types after which a session's metadata may differ from an in-flight snapshot read.
const METADATA_EVENT_TYPES: [&str; 15] = [
    "session.model",
    "session.reasoning_effort",
    "session.model_options",
    "session.agent_changed",
    "session.status",
    "response.created",
    "response.in_progress",
    "response.queued",
    "response.elicitation_request",
    "response.elicitation_resolved",
    "response.completed",
    "response.failed",
    "response.incomplete",
    "response.cancelled",
    "session.interrupted",
];

impl State {
    /// Puts the rows of sessions created here that no list page has shown yet at the head of
    /// `sessions`, the newest first page, when it does not have them. One whose row is gone
    /// (deleted or left here) is forgotten.
    fn keep_unlisted_creations(&mut self, sessions: &mut Vec<SessionSummary>) {
        let summaries = &self.summaries;
        self.unlisted_creations
            .retain(|id| summaries.contains_key(id));
        let missing: Vec<SessionSummary> = self
            .unlisted_creations
            .iter()
            .filter(|id| !sessions.iter().any(|row| &row.id == *id))
            .filter_map(|id| self.summaries.get(id).cloned())
            .collect();
        if !missing.is_empty() {
            sessions.splice(0..0, self.shown_rows(missing));
        }
    }

    /// The summary for `projection`, unless the session's metadata changed since the read began
    /// (`epoch_at_start`) and a newer summary is cached: then that one. Recorded and cached.
    pub(super) fn accept_projection(
        &mut self,
        projection: &SessionProjection,
        epoch_at_start: u64,
    ) -> Result<SessionSummary, SessionError> {
        if epoch_at_start != self.metadata_epoch(&projection.id)
            && let Some(current) = self.summaries.get(&projection.id)
        {
            return Ok(current.clone());
        }
        let summary = projection
            .summary(self.summaries.get(&projection.id))
            .map_err(|detail| SessionError::MalformedResponse { detail })?;
        projection.record_routing(&mut self.routing);
        if projection.is_side_chat() {
            self.side_chats.insert(projection.id.clone());
        }
        let summary = self.record_summary(summary);
        self.cache_summary(&summary);
        Ok(summary)
    }
}

/// A validated [`SessionChange`]: the field it changes and the `PATCH` body that asks for it.
pub(super) struct EditRequest {
    pub(super) session_id: String,
    pub(super) patch: SessionPatch,
    pub(super) body: Value,
    /// Filing into a project that is gone is also a `404`, so that one keeps the server's text.
    pub(super) names_project: bool,
}

/// Checks `change` against the identifier rules and the cached row. Only a cached row can
/// refuse here; a session without one is the server's to judge. A nested family member is
/// never pinned or moved on its own: its representative carries the family.
pub(super) fn edit_request(
    session_id: &str,
    change: SessionChange,
    cached: Option<&SessionSummary>,
) -> Result<EditRequest, SessionError> {
    validate_identifier(session_id)?;
    let allowed = |tier: fn(&SessionSummary) -> bool| {
        if cached.is_some_and(|summary| !tier(summary)) {
            Err(SessionError::ReadOnly)
        } else {
            Ok(())
        }
    };
    let representative_only = || {
        if cached.is_some_and(SessionSummary::is_nested_member) {
            Err(super::families::nested_member_refusal())
        } else {
            Ok(())
        }
    };
    let names_project = matches!(&change, SessionChange::Project(Some(_)));
    let (patch, body) = match change {
        SessionChange::Title(title) => {
            allowed(SessionSummary::can_rename)?;
            let cleaned = title.trim();
            if cleaned.is_empty() || cleaned.chars().count() > MAX_TITLE_CHARS {
                return Err(SessionError::InvalidTitle);
            }
            (
                SessionPatch::Title(cleaned.to_owned()),
                json!({"title": cleaned}),
            )
        }
        SessionChange::Pinned { pinned, at_ms } => {
            allowed(SessionSummary::can_pin)?;
            representative_only()?;
            let stamp = pinned.then(|| at_ms.to_string());
            let body = json!({"labels": {PINNED_LABEL: stamp.as_deref().unwrap_or_default()}});
            (SessionPatch::Pin(stamp), body)
        }
        SessionChange::PinnedAt(stamp) => {
            allowed(SessionSummary::can_pin)?;
            representative_only()?;
            (
                SessionPatch::Pin(Some(stamp.label().to_owned())),
                json!({"labels": {PINNED_LABEL: stamp.label()}}),
            )
        }
        SessionChange::Archived {
            archived,
            delete_worktree,
        } => {
            allowed(SessionSummary::can_archive)?;
            // The server rejects `delete_worktree` without `archived: true`.
            let body = if archived && delete_worktree {
                json!({"archived": true, "delete_worktree": true})
            } else {
                json!({"archived": archived})
            };
            (SessionPatch::Archived(archived), body)
        }
        SessionChange::Project(project_id) => {
            allowed(SessionSummary::can_archive)?;
            representative_only()?;
            if let Some(id) = &project_id {
                validate_identifier(id)?;
            }
            let body = json!({
                "project_id": project_id.as_deref().unwrap_or_default(),
                "labels": {PROJECT_LABEL: ""},
            });
            (SessionPatch::Project(project_id), body)
        }
    };
    Ok(EditRequest {
        session_id: session_id.to_owned(),
        patch,
        body,
        names_project,
    })
}

fn malformed(context: &str) -> impl FnOnce(String) -> SessionError + '_ {
    move |detail| SessionError::MalformedResponse {
        detail: format!("{context}: {detail}"),
    }
}

/// Which sessions the sidebar's list pages hold.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ListedSessions {
    /// Unarchived sessions, as the web's sidebar lists them.
    #[default]
    Active,
    /// Archived sessions too, while the sidebar shows them.
    WithArchived,
}

/// Which sessions a list read asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ListScope {
    /// The sidebar's sessions, archived included.
    Visible,
    /// The sidebar's unarchived sessions.
    Active,
    /// Every session of every kind, for the attention inventory.
    Inventory,
    /// Archived sessions only.
    Archived,
    /// The caller's own top-level, unarchived sessions, for the Canvas.
    Canvas,
    /// Pinned unarchived sessions and their families, for the Pinned section.
    Pinned,
}

/// Asks a sidebar read for the members of each session family it lists, appended after its
/// rows. Never for a search, which the server does not expand.
pub(super) const EXPAND_FAMILIES: (&str, &str) = ("expand_families", "true");

/// The list query `NativeLab` sent, plus the explicit `visibility` the repo requires.
fn list_query(
    after: Option<&str>,
    limit: u32,
    scope: ListScope,
) -> Result<Vec<(&'static str, String)>, SessionError> {
    let mut query = page_query(after, limit)?;
    query.push(("sort_by", "updated_at".to_owned()));
    if matches!(
        scope,
        ListScope::Visible | ListScope::Active | ListScope::Archived | ListScope::Pinned
    ) {
        query.push((EXPAND_FAMILIES.0, EXPAND_FAMILIES.1.to_owned()));
    }
    if scope == ListScope::Active {
        // The server leaves archived sessions out unless asked, as the web's sidebar reads it.
        query.push(("visibility", "all".to_owned()));
        return Ok(query);
    }
    if scope == ListScope::Pinned {
        // The web's Pinned query; archived pins never show.
        query.push(("visibility", "all".to_owned()));
        query.push(("pinned", "true".to_owned()));
        return Ok(query);
    }
    if scope == ListScope::Canvas {
        // The web Canvas's query; rows an older server returns anyway are filtered after.
        query.push(("order", "desc".to_owned()));
        query.push(("kind", "default".to_owned()));
        query.push(("visibility", "mine".to_owned()));
        query.push(("include_archived", "false".to_owned()));
        return Ok(query);
    }
    // Older servers ignore `visibility=archived`; their rows are filtered after the read.
    query.push(("include_archived", "true".to_owned()));
    let visibility = if scope == ListScope::Archived {
        "archived"
    } else {
        "all"
    };
    query.push(("visibility", visibility.to_owned()));
    if scope == ListScope::Inventory {
        query.push(("kind", "any".to_owned()));
    }
    Ok(query)
}

impl<T: HttpTransport> ClientCore<T> {
    /// The first [`DEFAULT_PAGE_LIMIT`] sessions, most recently updated first.
    ///
    /// # Errors
    ///
    /// As [`Self::session_page`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn sessions(&self) -> Result<Vec<SessionSummary>, SessionError> {
        Ok(self.session_page(None, DEFAULT_PAGE_LIMIT).await?.sessions)
    }

    /// One page of `GET /v1/sessions`, archived sessions included. Repeated ids are dropped.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidPageLimit`] and [`SessionError::InvalidPagination`] before any
    /// request; the read errors; [`SessionError::MalformedResponse`];
    /// [`SessionError::InvalidPagination`] for a page without a usable next cursor.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn session_page(
        &self,
        after: Option<&str>,
        limit: u32,
    ) -> Result<SessionPage, SessionError> {
        self.listed_page(after, limit, ListedSessions::WithArchived)
            .await
    }

    /// One page of the sidebar's list, holding the `listed` sessions; otherwise as
    /// [`Self::session_page`].
    ///
    /// # Errors
    ///
    /// As [`Self::session_page`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn listed_page(
        &self,
        after: Option<&str>,
        limit: u32,
        listed: ListedSessions,
    ) -> Result<SessionPage, SessionError> {
        let scope = match listed {
            ListedSessions::Active => ListScope::Active,
            ListedSessions::WithArchived => ListScope::Visible,
        };
        let result = self.list_page(after, limit, scope).await;
        self.dispatch();
        result.map(|mut page| {
            if after.is_none() {
                lock(&self.state).keep_unlisted_creations(&mut page.sessions);
            }
            page
        })
    }

    /// The caller's pinned sessions with their families (`pinned=true`), wherever they fall in
    /// the list: the Pinned section, before the pages that hold them load. `None` when the
    /// server ignored the filter (an older one lists every session), so nothing is added.
    ///
    /// # Errors
    ///
    /// As [`Self::session_page`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn pinned_session_page(&self) -> Result<Option<SessionPage>, SessionError> {
        let result = self
            .list_page(None, PINNED_PAGE_LIMIT, ListScope::Pinned)
            .await;
        self.dispatch();
        let page = result?;
        let honored = page.sessions.iter().all(|session| {
            session.is_pinned || session.family.as_ref().is_some_and(|family| family.pinned)
        });
        Ok(honored.then_some(page))
    }

    /// One page of archived sessions (`visibility=archived`), most recently updated first, for
    /// Settings > Archived sessions. Rows an older server returns unarchived are dropped.
    ///
    /// # Errors
    ///
    /// As [`Self::session_page`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn archived_session_page(
        &self,
        after: Option<&str>,
        limit: u32,
    ) -> Result<SessionPage, SessionError> {
        let result = self.list_page(after, limit, ListScope::Archived).await;
        self.dispatch();
        result.map(|mut page| {
            page.sessions.retain(|session| session.is_archived);
            page
        })
    }

    /// Every session, following `has_more` pages of [`INVENTORY_PAGE_LIMIT`] (all kinds,
    /// archived included), so a pending decision on a session past the visible page is found.
    ///
    /// # Errors
    ///
    /// As [`Self::session_page`], plus [`SessionError::InvalidPagination`] for a cursor that
    /// repeats across pages.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn session_inventory(&self) -> Result<Vec<SessionSummary>, SessionError> {
        let result = self.inventory().await;
        self.dispatch();
        result
    }

    /// The Canvas's sessions: `viewer_id`'s own top-level, unarchived sessions, newest first,
    /// following pages of [`CANVAS_PAGE_LIMIT`] up to [`MAX_CANVAS_SESSIONS`].
    ///
    /// # Errors
    ///
    /// As [`Self::session_inventory`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn canvas_sessions(
        &self,
        viewer_id: Option<&str>,
    ) -> Result<Vec<SessionSummary>, SessionError> {
        let result = self.canvas_pages(viewer_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn canvas_pages(
        &self,
        viewer_id: Option<&str>,
    ) -> Result<Vec<SessionSummary>, SessionError> {
        let mut result: Vec<SessionSummary> = Vec::new();
        let mut ids = BTreeSet::new();
        let mut cursors = BTreeSet::new();
        let mut after: Option<String> = None;
        loop {
            let SessionPage {
                sessions: page,
                next_cursor: next,
                ..
            } = self
                .list_page(after.as_deref(), CANVAS_PAGE_LIMIT, ListScope::Canvas)
                .await?;
            for summary in page {
                if crate::canvas::is_canvas_session(&summary, viewer_id)
                    && ids.insert(summary.id.clone())
                {
                    result.push(summary);
                }
            }
            match next {
                Some(cursor) if result.len() < MAX_CANVAS_SESSIONS => {
                    if !cursors.insert(cursor.clone()) {
                        return Err(SessionError::InvalidPagination);
                    }
                    after = Some(cursor);
                }
                _ => {
                    result.truncate(MAX_CANVAS_SESSIONS);
                    return Ok(result);
                }
            }
        }
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn inventory(&self) -> Result<Vec<SessionSummary>, SessionError> {
        let mut result: Vec<SessionSummary> = Vec::new();
        let mut ids = BTreeSet::new();
        let mut cursors = BTreeSet::new();
        let mut after: Option<String> = None;
        loop {
            let SessionPage {
                sessions: page,
                next_cursor: next,
                ..
            } = self
                .list_page(after.as_deref(), INVENTORY_PAGE_LIMIT, ListScope::Inventory)
                .await?;
            for summary in page {
                if ids.insert(summary.id.clone()) {
                    result.push(summary);
                }
            }
            match next {
                None => return Ok(result),
                Some(cursor) => {
                    if !cursors.insert(cursor.clone()) {
                        return Err(SessionError::InvalidPagination);
                    }
                    after = Some(cursor);
                }
            }
        }
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn list_page(
        &self,
        after: Option<&str>,
        limit: u32,
        scope: ListScope,
    ) -> Result<SessionPage, SessionError> {
        self.read_list(&list_query(after, limit, scope)?, after)
            .await
    }

    /// Reads one `GET /v1/sessions` page with `query`, recording its rows; `after` is the
    /// cursor the query carries. Returns the rows as the list shows them. A family member
    /// appended to an earlier page may come again; the later read is the newer row.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn read_list(
        &self,
        query: &[(&'static str, String)],
        after: Option<&str>,
    ) -> Result<SessionPage, SessionError> {
        let prepared = self.prepare("GET", "/v1/sessions", query, None)?;
        let epochs = lock(&self.state).metadata_epochs.clone();
        let response = self.read(prepared).await?;
        let page = SessionList::from_json(&response.body)
            .map_err(|error| malformed("/v1/sessions")(error.to_string()))?;
        let next = page
            .next_cursor(after)
            .map_err(|_| SessionError::InvalidPagination)?
            .map(str::to_owned);
        let selected_rows = page.selected_rows(|row| &row.id);
        let mut state = lock(&self.state);
        let mut seen = BTreeSet::new();
        let mut sessions = Vec::new();
        for row in &page.data {
            if !seen.insert(row.id.clone()) {
                continue;
            }
            let projection = SessionProjection::from_list_item(row);
            let epoch = epochs.get(&row.id).copied().unwrap_or(0);
            let summary = state.accept_projection(&projection, epoch)?;
            state.settle_intents(&summary);
            sessions.push(summary);
        }
        // The server lists them now, so from here a page without one means it is gone.
        state.unlisted_creations.retain(|id| !seen.contains(id));
        state.routing.resolve_modal();
        Ok(SessionPage {
            sessions: state.shown_rows(sessions),
            next_cursor: next,
            selected_rows,
            rows: page.data,
        })
    }

    /// `GET /v1/sessions/{id}?include_items=false`, decoded, with the metadata epoch the read
    /// started in.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(crate) async fn fetch_snapshot(
        &self,
        session_id: &str,
    ) -> Result<(DecodedSnapshot, u64), SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}");
        let prepared =
            self.prepare("GET", &path, &[("include_items", "false".to_owned())], None)?;
        let epoch = lock(&self.state).metadata_epoch(session_id);
        let response = match self.read(prepared).await {
            Err(SessionError::HttpStatus { status: 404 }) => {
                return Err(SessionError::SessionNotFound {
                    session_id: session_id.to_owned(),
                });
            }
            other => other?,
        };
        let decoded = decode_snapshot(&response.body).map_err(malformed(&path))?;
        if decoded.snapshot.id != session_id {
            return Err(SessionError::MalformedResponse {
                detail: format!("{path} returned session {:?}", decoded.snapshot.id),
            });
        }
        Ok((decoded, epoch))
    }

    /// The cached row of `session_id`, refusing a session it shows as read-only. A session with
    /// no cached row passes as `None`: the write goes out and the server decides.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] and [`SessionError::ReadOnly`]. No request is made.
    pub(crate) fn cached_editable(
        &self,
        session_id: &str,
    ) -> Result<Option<SessionSummary>, SessionError> {
        validate_identifier(session_id)?;
        let cached = self.cached_summary(session_id);
        if cached.as_ref().is_some_and(|summary| summary.is_read_only) {
            return Err(SessionError::ReadOnly);
        }
        Ok(cached)
    }

    /// Renames, pins or archives a session with one `PATCH /v1/sessions/{id}`: rename needs edit
    /// (2), pin view (1), archive owner (4). The cached row refuses a change it rules out; with
    /// no cached row the server decides.
    ///
    /// The list shows the change before the request leaves and goes back if the server refuses.
    /// Edits of one session leave in the order made; one still waiting is replaced by a later
    /// edit of the same field. Returns the row as the list shows it.
    ///
    /// A session family's representative carries its family: its move shows on the members
    /// this client holds at once, and after its pin or move (or any member's archive or
    /// restore) those members are read again.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] and [`SessionError::InvalidTitle`] before any
    /// write; [`SessionError::ReadOnly`] without the permission, from the cached row or the
    /// server's `403`; [`SessionError::InvalidInput`] for a pin or move of a nested family
    /// member; [`SessionError::Offline`] while the live link is down;
    /// [`SessionError::SessionNotFound`] for its `404`; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn edit_session(
        &self,
        session_id: &str,
        change: SessionChange,
    ) -> Result<SessionSummary, SessionError> {
        let result = self.edit(session_id, change).await;
        self.dispatch();
        result
    }

    /// Writes the caller's read state for one session: `PUT /v1/sessions/{id}/read-state`.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; [`SessionError::NotConnected`];
    /// [`SessionError::Unauthorized`] (the connection ends); [`SessionError::Forbidden`] without
    /// read access; [`SessionError::Rejected`] for another 4xx (an older server without the
    /// route answers 404 or 405); [`SessionError::DeliveryUncertain`] when the outcome is
    /// unknown.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn put_read_state(
        &self,
        mark: &crate::read_state::ReadMark,
    ) -> Result<(), SessionError> {
        validate_identifier(&mark.session_id)?;
        let path = format!("/v1/sessions/{}/read-state", mark.session_id);
        let body = json!({"last_seen": mark.last_seen, "unread": mark.unread});
        let result = self
            .write(self.prepare("PUT", &path, &[], Some(&body))?)
            .await;
        self.dispatch();
        result.map(|_| ())
    }

    /// The terminal names the session's agent declares (`GET /v1/sessions/{id}/agent`,
    /// `terminals`), in declaration order: the only names a terminal can be created with (the
    /// server rejects others). For a native harness these are the host's shells, its `$SHELL`
    /// first. Empty when the agent declares none; `None` when the server does not report them.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request, [`SessionError::SessionNotFound`]
    /// for a 404, the read errors, and [`SessionError::MalformedResponse`] when `terminals` is not
    /// a list of non-empty names.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn declared_terminal_names(
        &self,
        session_id: &str,
    ) -> Result<Option<Vec<String>>, SessionError> {
        let result = self.read_declared_terminals(session_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn read_declared_terminals(
        &self,
        session_id: &str,
    ) -> Result<Option<Vec<String>>, SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}/agent");
        let agent = match self.get_json(&path, &[]).await {
            Err(SessionError::HttpStatus { status: 404 }) => {
                return Err(SessionError::SessionNotFound {
                    session_id: session_id.to_owned(),
                });
            }
            other => other?,
        };
        let Some(terminals) = agent.get("terminals").filter(|value| !value.is_null()) else {
            return Ok(None);
        };
        let malformed = || SessionError::MalformedResponse {
            detail: format!("{path}: `terminals` is not a list of terminal names"),
        };
        terminals
            .as_array()
            .ok_or_else(malformed)?
            .iter()
            .map(|name| {
                name.as_str()
                    .filter(|name| !name.is_empty())
                    .map(str::to_owned)
                    .ok_or_else(malformed)
            })
            .collect::<Result<Vec<_>, _>>()
            .map(Some)
    }

    /// Applies `/v1/sessions/updates` `snapshot` or `changed` rows (see
    /// [`crate::realtime::UpdatesFrame`]): each becomes a summary merged over the cached one.
    /// A sparse row for the live session (no harness and model) asks for re-hydration.
    ///
    /// # Errors
    ///
    /// [`SessionError::MalformedResponse`] for the first row that is not a session row. The
    /// other rows of the frame still apply.
    pub fn apply_session_rows(
        &self,
        rows: Vec<Value>,
    ) -> Result<Vec<SessionSummary>, SessionError> {
        let result = self.apply_rows(rows);
        self.dispatch();
        result
    }

    fn apply_rows(&self, rows: Vec<Value>) -> Result<Vec<SessionSummary>, SessionError> {
        let mut unreadable = None;
        let mut state = lock(&self.state);
        let mut changed = Vec::new();
        let mut hydrate = Vec::new();
        for row in rows {
            let decoded = decode_list_row(row).and_then(|projection| {
                let summary = projection.summary(state.summaries.get(&projection.id))?;
                Ok((projection, summary))
            });
            let (projection, summary) = match decoded {
                Ok(decoded) => decoded,
                Err(error) => {
                    unreadable.get_or_insert_with(|| malformed("session row")(error));
                    continue;
                }
            };
            let summary = state.record_summary(summary);
            state.cache_summary(&summary);
            state.settle_intents(&summary);
            if state.live_sessions.contains(&projection.id)
                && !projection.has_configuration_identity()
            {
                hydrate.push(projection.id.clone());
            }
            if projection.is_side_chat() {
                state.side_chats.insert(projection.id.clone());
            }
            changed.push(summary);
        }
        if !changed.is_empty() || unreadable.is_none() {
            state.events.push(ClientEvent::SessionsChanged {
                sessions: changed.clone(),
            });
            state.events.push(ClientEvent::InventoryInvalidated);
        }
        for session_id in hydrate {
            state
                .events
                .push(ClientEvent::HydrationRequested { session_id });
        }
        unreadable.map_or(Ok(changed), Err)
    }

    /// Applies a `/v1/sessions/updates` `removed` frame: the sessions are forgotten (and a live
    /// one stops being live).
    pub fn remove_sessions(&self, ids: &[String]) {
        {
            let mut state = lock(&self.state);
            for id in ids {
                state.bump_metadata_epoch(id);
                state.summaries.remove(id);
                state.drop_intents(id);
            }
            state.live_sessions.retain(|live| !ids.contains(live));
            state
                .events
                .push(ClientEvent::SessionsRemoved { ids: ids.to_vec() });
            state.events.push(ClientEvent::InventoryInvalidated);
        }
        self.dispatch();
    }

    /// Records a stream event for `session_id`: settings, status, turn and decision events mean
    /// any snapshot read in flight may already be stale, so its configuration is not trusted.
    /// A sub-agent event also records which session the child runs under, for replica routing.
    pub fn record_stream_event(&self, session_id: &str, event: &ServerStreamEvent) {
        if let Some((child, parent)) = child_link(session_id, event) {
            lock(&self.state).routing.record_parent(child, parent);
        }
        if !METADATA_EVENT_TYPES.contains(&event.event_type()) {
            return;
        }
        let conversation = serde_json::to_value(event).ok().and_then(|value| {
            value
                .get("conversation_id")
                .and_then(Value::as_str)
                .map(str::to_owned)
        });
        if conversation.is_some_and(|id| id != session_id) {
            return;
        }
        lock(&self.state).bump_metadata_epoch(session_id);
    }
}

/// The child and parent a sub-agent event on `session_id`'s stream links: the child runs on the
/// parent's runner, so its requests are keyed by the parent's host.
fn child_link<'a>(session_id: &'a str, event: &'a ServerStreamEvent) -> Option<(&'a str, &'a str)> {
    let (child, parent) = match event {
        ServerStreamEvent::SessionCreated(created) => (
            created.child_session_id.as_str(),
            created
                .parent_session_id
                .as_deref()
                .or(created.conversation_id.as_deref()),
        ),
        ServerStreamEvent::SessionChildSessionUpdated(updated) => (
            updated.child_session_id.as_str(),
            updated
                .child
                .get("parent_session_id")
                .and_then(Value::as_str)
                .or(updated.conversation_id.as_deref()),
        ),
        _ => return None,
    };
    let parent = parent.filter(|id| !id.is_empty()).unwrap_or(session_id);
    Some((child, parent))
}

impl State {
    /// After a write: the list may be stale, and an open session the write touched should be
    /// re-hydrated.
    pub(super) fn request_rehydration(&mut self, session_id: &str) {
        self.events.push(ClientEvent::InventoryInvalidated);
        if self.live_sessions.contains(session_id) {
            self.events.push(ClientEvent::HydrationRequested {
                session_id: session_id.to_owned(),
            });
        }
    }
}

#[cfg(test)]
#[allow(
    clippy::redundant_pub_crate,
    reason = "test helpers shared with the configuration tests"
)]
pub(crate) mod test_support {
    use serde_json::{Map, Value, json};

    use super::*;

    /// `{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}` overlaid with
    /// `fields` (an object), as the Swift `wire(_:)` helper builds it.
    pub(crate) fn wire(fields: &Value, include_permission: bool) -> Value {
        let mut base: Map<String, Value> =
            json!({"id": "conv_a", "status": "idle", "created_at": 1})
                .as_object()
                .cloned()
                .unwrap();
        if include_permission {
            base.insert("permission_level".into(), json!(4));
        }
        for (key, value) in fields.as_object().unwrap() {
            base.insert(key.clone(), value.clone());
        }
        Value::Object(base)
    }

    /// The summary of a snapshot built by [`wire`], merged over `previous`.
    pub(crate) fn summary_of(
        fields: &Value,
        previous: Option<&SessionSummary>,
        include_permission: bool,
    ) -> SessionSummary {
        decode_snapshot_value(wire(fields, include_permission))
            .unwrap()
            .projection
            .summary(previous)
            .unwrap()
    }
}

#[cfg(test)]
#[path = "sessions_family_tests.rs"]
mod family_tests;

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::test_support::{summary_of, wire};
    use super::*;

    #[test]
    fn a_session_without_configuration_cannot_be_stopped_and_keeps_its_own_metadata() {
        let bare = SessionSummary::new("conv_a", "t", "");
        assert!(!bare.is_stoppable());
        let newer = SessionSummary {
            title: "fresh".to_owned(),
            ..bare.clone()
        };
        assert_eq!(newer.clone().preserving_newer_metadata(Some(&bare)), newer);
    }

    #[test]
    fn list_rows_derive_status_permissions_and_defaults() {
        let row = decode_list_row(json!({
            "id": "conv_old", "status": "idle", "created_at": 5, "updated_at": 20,
            "title": null, "archived": true, "pending_elicitations_count": 1
        }))
        .unwrap();
        let summary = row.summary(None).unwrap();
        assert_eq!(summary.title, "Untitled session");
        assert_eq!(summary.status, SummaryStatus::NeedsResponse);
        assert_eq!(summary.pending_requests, 1);
        assert_eq!(summary.preview, "Needs your response");
        assert!(summary.is_read_only);
        assert!(summary.is_archived);
        assert_eq!(summary.updated_at, 20);
        assert_eq!(summary.workspace, "Local server");
        assert_eq!(summary.agent_name, "Omnigent");
        let unknown = decode_list_row(json!({"id": "x", "status": "future", "created_at": 1}))
            .unwrap()
            .summary(None);
        assert!(unknown.is_err());
    }

    #[test]
    fn permission_capabilities_and_failure_metadata() {
        let editor = summary_of(
            &json!({"status": "failed", "permission_level": 2,
                    "last_task_error": {"code": "codex_reauth_required", "message": "Sign in again"}}),
            None,
            true,
        );
        assert!(!editor.is_read_only);
        assert!(editor.can_rename());
        assert!(editor.can_pin());
        assert!(!editor.can_archive());
        assert_eq!(editor.failure_message.as_deref(), Some("Sign in again"));
        assert_eq!(editor.status, SummaryStatus::Idle);
        let generic = summary_of(
            &json!({"status": "failed", "last_task_error": null}),
            None,
            true,
        );
        assert_eq!(
            generic.failure_message.as_deref(),
            Some("The last response failed. Check the server or provider sign-in.")
        );
    }

    #[test]
    fn an_automations_session_copy_names_its_automation() {
        let source = summary_of(
            &json!({"labels": {AUTOMATION_SOURCE_LABEL: "task_daily"}}),
            None,
            true,
        );
        assert_eq!(source.automation_source_id.as_deref(), Some("task_daily"));
        let kept = summary_of(&json!({}), Some(&source), true);
        assert_eq!(kept.automation_source_id.as_deref(), Some("task_daily"));
        for labels in [json!({}), json!({AUTOMATION_SOURCE_LABEL: ""})] {
            let cleared = summary_of(&json!({ "labels": labels }), Some(&source), true);
            assert_eq!(cleared.automation_source_id, None);
        }
    }

    #[test]
    fn a_worker_names_the_session_that_created_it_until_labels_say_otherwise() {
        let worker = summary_of(
            &json!({"labels": {CREATED_BY_SESSION_LABEL: "conv_parent"}}),
            None,
            true,
        );
        assert_eq!(worker.created_by_session_id.as_deref(), Some("conv_parent"));
        // A read without labels keeps it; labels without the key or with it empty clear it.
        let kept = summary_of(&json!({}), Some(&worker), true);
        assert_eq!(kept.created_by_session_id.as_deref(), Some("conv_parent"));
        for labels in [json!({}), json!({CREATED_BY_SESSION_LABEL: ""})] {
            let cleared = summary_of(&json!({ "labels": labels }), Some(&worker), true);
            assert_eq!(cleared.created_by_session_id, None);
        }
    }

    #[test]
    fn pending_requests_follow_each_read_and_clear_with_the_count() {
        let row = |count: u64| {
            decode_list_row(json!({
                "id": "conv_wait", "status": "running", "created_at": 1,
                "permission_level": 4, "pending_elicitations_count": count
            }))
            .unwrap()
        };
        let waiting = row(3).summary(None).unwrap();
        assert_eq!(waiting.pending_requests, 3);
        assert_eq!(waiting.status, SummaryStatus::NeedsResponse);
        let answered = row(0).summary(Some(&waiting)).unwrap();
        assert_eq!(answered.pending_requests, 0);
        assert_eq!(answered.status, SummaryStatus::Running);
        let snapshot = summary_of(&json!({ "pending_elicitations_count": 2 }), None, true);
        assert_eq!(snapshot.pending_requests, 2);
        let cleared = summary_of(&json!({}), Some(&snapshot), true);
        assert_eq!(cleared.pending_requests, 0);
    }

    #[test]
    fn list_rows_carry_background_work_and_a_terminal_prompt_and_snapshots_keep_them() {
        let row = |fields: Value| decode_list_row(wire(&fields, true)).unwrap();
        let shell = row(json!({"background_work_running": true}))
            .summary(None)
            .unwrap();
        assert!(shell.background_work_running);
        // The status stays idle, so the session still takes a message.
        assert_eq!(
            (shell.status, shell.preview.as_str()),
            (SummaryStatus::Idle, "Idle")
        );
        // A snapshot does not carry it; a row that omits it (or an older server's) clears it.
        assert!(summary_of(&json!({}), Some(&shell), true).background_work_running);
        let older = row(json!({})).summary(Some(&shell)).unwrap();
        assert!(!older.background_work_running);

        let parked = row(json!({"status": "running", "blocked_on": "permission prompt"}))
            .summary(None)
            .unwrap();
        assert_eq!(parked.status, SummaryStatus::NeedsResponse);
        assert!(parked.is_parked_in_terminal());
        assert_eq!(
            parked.preview,
            "Waiting for you in the agent's terminal (permission prompt)"
        );
        let guessed = row(json!({"status": "running", "blocked_on": "terminal prompt"}))
            .summary(None)
            .unwrap();
        assert_eq!(
            guessed.preview,
            "May need your input in the agent's terminal"
        );
        // Only a running agent is parked. A snapshot keeps the prompt; a row without it clears it.
        let idle = row(json!({"blocked_on": "permission prompt"}))
            .summary(None)
            .unwrap();
        assert!(!idle.is_parked_in_terminal());
        assert_eq!(idle.status, SummaryStatus::Idle);
        let kept = summary_of(&json!({"status": "running"}), Some(&parked), true);
        assert!(kept.is_parked_in_terminal());
        let resumed = row(json!({"status": "running"}))
            .summary(Some(&parked))
            .unwrap();
        assert_eq!(
            (resumed.status, resumed.blocked_on),
            (SummaryStatus::Running, None)
        );
    }

    #[test]
    fn metadata_version_rejects_older_callbacks_without_changing_conversation_identity() {
        let mut older = SessionSummary {
            configuration: Some(crate::demo::demo_configuration()),
            configuration_revision: Some(4),
            ..SessionSummary::new("same", "Old", "")
        };
        let mut newer = older.clone();
        newer.title = "New".into();
        if let Some(configuration) = newer.configuration.as_mut() {
            configuration.model_override = Some("sample-fast".into());
        }
        newer.configuration_revision = Some(5);
        assert_eq!(older.clone().preserving_newer_metadata(Some(&newer)), newer);
        assert_eq!(newer.clone().preserving_newer_metadata(Some(&older)), newer);
        older.configuration_revision = None;
        assert_eq!(older.clone().preserving_newer_metadata(Some(&newer)), newer);
        let other = SessionSummary {
            configuration_revision: Some(100),
            ..SessionSummary::new("other", "Other", "")
        };
        assert_eq!(older.clone().preserving_newer_metadata(Some(&other)), older);
    }

    fn row(id: &str) -> Value {
        json!({"id": id, "status": "idle", "created_at": 1, "updated_at": 2})
    }

    #[test]
    fn a_session_list_cursor_that_comes_back_ends_the_read() {
        use futures::executor::block_on;

        use super::super::test_support::{Reply, RouteTransport, connected};

        let page = |last: &str| {
            Reply::json(
                200,
                json!({"data": [row(last)], "has_more": true, "last_id": last}).to_string(),
            )
        };
        let transport = RouteTransport::local();
        transport.enqueue("GET", "/v1/sessions", vec![page("a"), page("b"), page("a")]);
        let core = connected(transport);
        assert_eq!(
            block_on(core.canvas_sessions(Some("me"))),
            Err(SessionError::InvalidPagination)
        );
        core.transport()
            .enqueue("GET", "/v1/sessions", vec![page("a"), page("b"), page("a")]);
        assert_eq!(
            block_on(core.session_inventory()),
            Err(SessionError::InvalidPagination)
        );
    }

    #[test]
    fn removed_sessions_are_forgotten_and_stop_being_live() {
        use super::super::test_support::{RouteTransport, live, record};

        let transport = RouteTransport::local();
        transport.writable_session("[]");
        let core = live(transport);
        let events = record(&core);
        core.remove_sessions(&["conv_a".to_owned()]);
        assert_eq!(
            events.take(),
            [
                ClientEvent::SessionsRemoved {
                    ids: vec!["conv_a".to_owned()]
                },
                ClientEvent::InventoryInvalidated,
            ]
        );
        assert!(!lock(&core.state).summaries.contains_key("conv_a"));
        assert!(!lock(&core.state).live_sessions.contains("conv_a"));
    }

    #[test]
    fn an_unreadable_snapshot_and_list_name_their_route() {
        use futures::executor::block_on;

        use super::super::test_support::{RouteTransport, connected};

        let transport = RouteTransport::local();
        transport.ok("/v1/sessions/conv_a", "[]");
        let core = connected(transport);
        assert!(matches!(
            block_on(core.fetch_snapshot("conv_a")).map(|_| ()),
            Err(SessionError::MalformedResponse { detail })
                if detail.starts_with("/v1/sessions/conv_a: ")
        ));
    }

    #[test]
    fn a_snapshot_naming_another_session_is_malformed() {
        use futures::executor::block_on;

        use super::super::test_support::{RouteTransport, connected};

        let transport = RouteTransport::local();
        transport.ok("/v1/sessions/conv_a", row("conv_b").to_string());
        let core = connected(transport);
        assert!(matches!(
            block_on(core.fetch_snapshot("conv_a")).map(|_| ()),
            Err(SessionError::MalformedResponse { detail }) if detail.contains("conv_b")
        ));
    }

    #[test]
    fn a_read_only_cached_row_refuses_to_be_pinned_or_filed_without_a_request() {
        use futures::executor::block_on;

        use super::super::test_support::{RouteTransport, connected, lines_after_connect};

        let core = connected(RouteTransport::local());
        let mut wire = row("conv_a");
        wire["permission_level"] = json!(0);
        core.apply_session_rows(vec![wire]).unwrap();
        for change in [
            SessionChange::Pinned {
                pinned: true,
                at_ms: 5,
            },
            SessionChange::PinnedAt(PinStamp::new(5.0).unwrap()),
            SessionChange::Project(Some("p1".to_owned())),
        ] {
            assert_eq!(
                block_on(core.edit_session("conv_a", change)),
                Err(SessionError::ReadOnly)
            );
        }
        assert_eq!(lines_after_connect(&core), Vec::<String>::new());
    }

    #[test]
    fn a_patch_acknowledgement_that_does_not_decode_is_uncertain() {
        use futures::executor::block_on;

        use super::super::test_support::{Reply, RouteTransport, connected};

        let transport = RouteTransport::local();
        transport.respond(
            Some("PATCH"),
            "/v1/sessions/conv_a",
            None,
            Reply::json(200, r#"{"model_options":7}"#),
        );
        let core = connected(transport);
        assert!(matches!(
            block_on(core.edit_session("conv_a", SessionChange::Pinned { pinned: true, at_ms: 5 })),
            Err(SessionError::DeliveryUncertain { detail }) if detail.contains("acknowledgement")
        ));
    }

    #[test]
    fn null_fields_clear_what_a_previous_read_said() {
        let list_row = |fields: Value, previous: Option<&SessionSummary>| {
            let mut wire = row("conv_a");
            for (key, value) in fields.as_object().unwrap() {
                wire[key] = value.clone();
            }
            decode_list_row(wire).unwrap().summary(previous).unwrap()
        };
        let counted = list_row(json!({"comments_count": 4}), None);
        assert_eq!(counted.comments_count, 4);
        assert_eq!(
            list_row(json!({"comments_count": null}), Some(&counted)).comments_count,
            0
        );
        let previous = summary_of(&json!({"permission_level": 3, "agent_id": "a"}), None, true);
        let cleared = summary_of(
            &json!({"permission_level": null, "agent_id": null}),
            Some(&previous),
            false,
        );
        assert_eq!(cleared.permission_level, None);
        assert!(cleared.is_read_only);
        let launching = summary_of(&json!({"status": "launching"}), None, true);
        assert_eq!(launching.status, SummaryStatus::Running);
        assert_eq!(launching.preview, "Launching");
    }

    #[test]
    fn snapshots_read_null_and_wrong_model_options_and_counts() {
        let base = |field: &str, value: Value| {
            let mut wire = row("conv_a");
            wire[field] = value;
            decode_snapshot_value(wire)
        };
        assert!(matches!(
            base("model_options", Value::Null)
                .unwrap()
                .projection
                .model_options,
            Field::Null
        ));
        assert_eq!(
            base("model_options", json!(7)).err().unwrap(),
            "`model_options` is not an array"
        );
        assert_eq!(
            base("pending_elicitations_count", Value::Null)
                .unwrap()
                .projection
                .summary(None)
                .unwrap()
                .pending_requests,
            0
        );
    }

    #[test]
    fn a_stream_event_for_another_conversation_does_not_mark_this_one_stale() {
        use omnigent_protocol::FromWire;

        let core =
            super::super::test_support::core(super::super::test_support::RouteTransport::local());
        let before = lock(&core.state).metadata_epoch("conv_a");
        let event = |conversation: &str| {
            ServerStreamEvent::from_value(json!({
                "type": "session.model", "model": "new", "conversation_id": conversation
            }))
            .unwrap()
        };
        core.record_stream_event("conv_a", &event("conv_b"));
        assert_eq!(lock(&core.state).metadata_epoch("conv_a"), before);
        core.record_stream_event("conv_a", &event("conv_a"));
        assert_ne!(lock(&core.state).metadata_epoch("conv_a"), before);
    }

    #[test]
    fn canvas_sessions_page_through_the_viewers_own_top_level_rows() {
        use futures::executor::block_on;

        use super::super::test_support::{Reply, RouteTransport, connected, query_value};

        let transport = RouteTransport::local();
        transport.ok(
            "/v1/sessions",
            r#"{"data":[
              {"id":"a","status":"idle","created_at":1,"updated_at":9},
              {"id":"b","status":"idle","created_at":1,"updated_at":8,"owner":"someone"},
              {"id":"c","status":"idle","created_at":1,"updated_at":7,"archived":true}
            ],"has_more":true,"last_id":"c"}"#,
        );
        transport.respond(
            None,
            "/v1/sessions",
            Some("c"),
            Reply::json(
                200,
                r#"{"data":[
                  {"id":"d","status":"idle","created_at":1,"updated_at":6,"parent_session_id":"a"},
                  {"id":"e","status":"running","created_at":1,"updated_at":5}
                ],"has_more":false}"#,
            ),
        );
        let core = connected(transport);
        let ids: Vec<String> = block_on(core.canvas_sessions(Some("me")))
            .unwrap()
            .into_iter()
            .map(|session| session.id)
            .collect();
        assert_eq!(ids, ["a", "e"]);
        let reads: Vec<_> = core
            .transport()
            .taken()
            .into_iter()
            .filter(|request| request.url.contains("/v1/sessions?"))
            .collect();
        assert_eq!(reads.len(), 2);
        assert_eq!(
            query_value(&reads[0], "visibility").as_deref(),
            Some("mine")
        );
        assert_eq!(query_value(&reads[0], "kind").as_deref(), Some("default"));
        assert_eq!(
            query_value(&reads[0], "include_archived").as_deref(),
            Some("false")
        );
        assert_eq!(query_value(&reads[0], "limit").as_deref(), Some("1000"));
    }
}
