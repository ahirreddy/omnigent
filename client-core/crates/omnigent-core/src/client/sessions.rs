//! Session summaries: the list-row model the UI shows, and how REST rows, snapshots and
//! `/v1/sessions/updates` rows become one.
//!
//! Port of `NativeLab`'s `SessionSummary` (`Models.swift`) and `SessionWire.summary(previous:)`
//! (`LocalServerSessionClient.swift`). A list row ([`SessionListItem`]) and a snapshot
//! ([`SessionSnapshot`]) both project onto a [`SessionProjection`]: every field keeps the
//! difference between "not sent" (keep what is known), `null` (clear it) and a value, so a sparse
//! list row never clears detail-only configuration, while an explicit `null` still does.

use std::collections::{BTreeMap, BTreeSet};

use omnigent_protocol::sessions::{SessionList, SessionListItem, SessionSnapshot, SessionStatus};
use omnigent_protocol::{DecodeError, Field, FromWire, ServerStreamEvent};
use serde_json::{Value, json};

use super::pin_order::PinStamp;
use super::requests::{page_query, validate_identifier};
use super::{ClientCore, ClientEvent, SessionError, State, lock};
use crate::config::session::{ModelChoice, SessionConfiguration};
use crate::creation::MAX_TITLE_CHARS;
use crate::http::HttpTransport;

/// The status a session list shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SummaryStatus {
    /// Idle (including failed; see [`SessionSummary::failure_message`]).
    Idle,
    /// A turn or background work is in progress.
    Running,
    /// A decision is pending.
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
        }
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionPage {
    /// Summaries in server order, repeated ids dropped.
    pub sessions: Vec<SessionSummary>,
    /// The `after` cursor for the next page.
    pub next_cursor: Option<String>,
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
    parent_id: Field<String>,
    routing_mode: Field<String>,
    launch_args: Field<Vec<String>>,
    git_branch: Field<String>,
    viewer_last_seen: Field<i64>,
    viewer_unread: Field<bool>,
    owner: Field<String>,
    project_id: Field<String>,
    comments_count: Field<u64>,
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
            parent_id: row.parent_session_id.clone(),
            routing_mode: Field::Absent,
            launch_args: Field::Absent,
            git_branch: row.git_branch.clone(),
            viewer_last_seen: row.viewer_last_seen.clone(),
            viewer_unread: row.viewer_unread.clone(),
            owner: row.owner.clone(),
            project_id: row.project_id.clone(),
            comments_count: row.comments_count.clone(),
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
            parent_id: snapshot.parent_session_id.clone(),
            routing_mode: snapshot.cost_control_mode_override.clone(),
            launch_args: snapshot.terminal_launch_args.clone(),
            git_branch: snapshot.git_branch.clone(),
            viewer_last_seen: Field::Absent,
            viewer_unread: Field::Absent,
            owner: Field::Absent,
            project_id: snapshot.project_id.clone(),
            comments_count: Field::Absent,
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
        let labels = self.labels.value();
        let configuration = self.configuration(previous.and_then(|p| p.configuration.as_ref()));
        Ok(SessionSummary {
            id: self.id.clone(),
            title: self
                .title
                .value()
                .filter(|title| !title.is_empty())
                .cloned()
                .unwrap_or_else(|| "Untitled session".to_owned()),
            preview: if pending_requests > 0 {
                "Needs your response".to_owned()
            } else {
                self.search_snippet
                    .value()
                    .cloned()
                    .unwrap_or_else(|| status_preview.to_owned())
            },
            status: if pending_requests > 0 {
                SummaryStatus::NeedsResponse
            } else {
                status
            },
            pending_requests,
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
        if self.host_id.is_reported() {
            let host_id = self.host_id.value().cloned();
            if configuration.host_id != host_id {
                configuration.host_online = None;
                configuration.runner_online = None;
                configuration.runner_bound = None;
                configuration.host_resumable = None;
            }
            configuration.host_id = host_id;
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
/// How many rows one Canvas page asks for: the server's maximum.
pub const CANVAS_PAGE_LIMIT: u32 = 1_000;
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

fn malformed(context: &str) -> impl FnOnce(String) -> SessionError + '_ {
    move |detail| SessionError::MalformedResponse {
        detail: format!("{context}: {detail}"),
    }
}

/// Which sessions a list read asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ListScope {
    /// The sidebar's sessions, archived included.
    Visible,
    /// Every session of every kind, for the attention inventory.
    Inventory,
    /// Archived sessions only.
    Archived,
    /// The caller's own top-level, unarchived sessions, for the Canvas.
    Canvas,
}

/// The list query `NativeLab` sent, plus the explicit `visibility` the repo requires.
fn list_query(
    after: Option<&str>,
    limit: u32,
    scope: ListScope,
) -> Result<Vec<(&'static str, String)>, SessionError> {
    let mut query = page_query(after, limit)?;
    query.push(("sort_by", "updated_at".to_owned()));
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
        let result = self.list_page(after, limit, ListScope::Visible).await;
        self.dispatch();
        result.map(|(sessions, next_cursor)| SessionPage {
            sessions,
            next_cursor,
        })
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
        result.map(|(mut sessions, next_cursor)| {
            sessions.retain(|session| session.is_archived);
            SessionPage {
                sessions,
                next_cursor,
            }
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
            let (page, next) = self
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
            let (page, next) = self
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
    ) -> Result<(Vec<SessionSummary>, Option<String>), SessionError> {
        self.read_list(&list_query(after, limit, scope)?, after)
            .await
    }

    /// Reads one `GET /v1/sessions` page with `query`, recording its rows; `after` is the
    /// cursor the query carries.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn read_list(
        &self,
        query: &[(&'static str, String)],
        after: Option<&str>,
    ) -> Result<(Vec<SessionSummary>, Option<String>), SessionError> {
        let prepared = self.prepare("GET", "/v1/sessions", query, None)?;
        let epochs = lock(&self.state).metadata_epochs.clone();
        let response = self.read(prepared).await?;
        let page = SessionList::from_json(&response.body)
            .map_err(|error| malformed("/v1/sessions")(error.to_string()))?;
        let next = page
            .next_cursor(after)
            .map_err(|_| SessionError::InvalidPagination)?
            .map(str::to_owned);
        let mut state = lock(&self.state);
        let mut seen = BTreeSet::new();
        let mut sessions = Vec::new();
        for row in &page.data {
            if !seen.insert(row.id.clone()) {
                continue;
            }
            let projection = SessionProjection::from_list_item(row);
            let epoch = epochs.get(&row.id).copied().unwrap_or(0);
            sessions.push(state.accept_projection(&projection, epoch)?);
        }
        state.routing.resolve_modal();
        Ok((sessions, next))
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

    /// The current summary of `session_id`, read fresh, failing unless the caller may edit it.
    /// Every write runs this preflight first.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request, the read errors, and
    /// [`SessionError::ReadOnly`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn editable_session(&self, session_id: &str) -> Result<SessionSummary, SessionError> {
        let result = self.editable(session_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(crate) async fn editable(&self, session_id: &str) -> Result<SessionSummary, SessionError> {
        let (decoded, epoch) = self.fetch_snapshot(session_id).await?;
        let summary = lock(&self.state).accept_projection(&decoded.projection, epoch)?;
        if summary.is_read_only {
            return Err(SessionError::ReadOnly);
        }
        Ok(summary)
    }

    /// Renames, pins or archives a session with `PATCH /v1/sessions/{id}`, after a fresh
    /// permission check: rename needs edit (2), pin view (1), archive owner (4).
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] and [`SessionError::InvalidTitle`] before any
    /// write; [`SessionError::ReadOnly`] without the permission; the read and write errors.
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

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn edit(
        &self,
        session_id: &str,
        change: SessionChange,
    ) -> Result<SessionSummary, SessionError> {
        validate_identifier(session_id)?;
        let (decoded, epoch) = self.fetch_snapshot(session_id).await?;
        let summary = lock(&self.state).accept_projection(&decoded.projection, epoch)?;
        let body = match change {
            SessionChange::Title(title) => {
                if !summary.can_rename() {
                    return Err(SessionError::ReadOnly);
                }
                let cleaned = title.trim();
                if cleaned.is_empty() || cleaned.chars().count() > MAX_TITLE_CHARS {
                    return Err(SessionError::InvalidTitle);
                }
                json!({"title": cleaned})
            }
            SessionChange::Pinned { pinned, at_ms } => {
                if !summary.can_pin() {
                    return Err(SessionError::ReadOnly);
                }
                let stamp = if pinned {
                    at_ms.to_string()
                } else {
                    String::new()
                };
                json!({"labels": {PINNED_LABEL: stamp}})
            }
            SessionChange::PinnedAt(stamp) => {
                if !summary.can_pin() {
                    return Err(SessionError::ReadOnly);
                }
                json!({"labels": {PINNED_LABEL: stamp.label()}})
            }
            SessionChange::Archived {
                archived,
                delete_worktree,
            } => {
                if !summary.can_archive() {
                    return Err(SessionError::ReadOnly);
                }
                // The server rejects `delete_worktree` without `archived: true`.
                if archived && delete_worktree {
                    json!({"archived": true, "delete_worktree": true})
                } else {
                    json!({"archived": archived})
                }
            }
            SessionChange::Project(project_id) => {
                if !summary.can_archive() {
                    return Err(SessionError::ReadOnly);
                }
                if let Some(id) = &project_id {
                    validate_identifier(id)?;
                }
                json!({
                    "project_id": project_id.unwrap_or_default(),
                    "labels": {PROJECT_LABEL: ""},
                })
            }
        };
        let path = format!("/v1/sessions/{session_id}");
        let mutation_epoch = lock(&self.state).metadata_epoch(session_id);
        let acknowledgement = self.write_json("PATCH", &path, &body).await?;
        let decoded = decode_snapshot_value(acknowledgement).map_err(|detail| {
            SessionError::DeliveryUncertain {
                detail: format!("unreadable {path} acknowledgement: {detail}"),
            }
        })?;
        let mut state = lock(&self.state);
        let updated = state.accept_projection(&decoded.projection, mutation_epoch)?;
        state.events.push(ClientEvent::SessionsChanged {
            sessions: vec![updated.clone()],
        });
        state.request_rehydration(session_id);
        Ok(updated)
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
    /// [`SessionError::MalformedResponse`] for a row that is not a session row; nothing is
    /// applied then.
    pub fn apply_session_rows(
        &self,
        rows: Vec<Value>,
    ) -> Result<Vec<SessionSummary>, SessionError> {
        let result = self.apply_rows(rows);
        self.dispatch();
        result
    }

    fn apply_rows(&self, rows: Vec<Value>) -> Result<Vec<SessionSummary>, SessionError> {
        let projections = rows
            .into_iter()
            .map(decode_list_row)
            .collect::<Result<Vec<_>, String>>()
            .map_err(malformed("session row"))?;
        let mut state = lock(&self.state);
        let mut changed = Vec::new();
        let mut hydrate = Vec::new();
        for projection in &projections {
            let summary = projection
                .summary(state.summaries.get(&projection.id))
                .map_err(malformed("session row"))?;
            let summary = state.record_summary(summary);
            state.cache_summary(&summary);
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
        state.events.push(ClientEvent::SessionsChanged {
            sessions: changed.clone(),
        });
        state.events.push(ClientEvent::InventoryInvalidated);
        for session_id in hydrate {
            state
                .events
                .push(ClientEvent::HydrationRequested { session_id });
        }
        Ok(changed)
    }

    /// Applies a `/v1/sessions/updates` `removed` frame: the sessions are forgotten (and a live
    /// one stops being live).
    pub fn remove_sessions(&self, ids: &[String]) {
        {
            let mut state = lock(&self.state);
            for id in ids {
                state.bump_metadata_epoch(id);
                state.summaries.remove(id);
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
    pub fn record_stream_event(&self, session_id: &str, event: &ServerStreamEvent) {
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
mod tests {
    use serde_json::json;

    use super::test_support::summary_of;
    use super::*;

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
