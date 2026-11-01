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
            is_read_only: false,
            updated_at: 0,
            workspace: "Omni mobile".to_owned(),
            agent_name: "Omni".to_owned(),
            is_pinned: false,
            is_archived: false,
            terminal_first: false,
            permission_level: None,
            failure_message: None,
            configuration: None,
            configuration_revision: None,
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
    /// Archive or restore.
    Archived(bool),
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
    pending_elicitations: usize,
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
}

impl SessionProjection {
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
            pending_elicitations: 0,
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
            pending_elicitations: snapshot.pending_elicitations.len(),
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
        }
    }

    /// Whether the row reports the harness and model, so it can replace detail metadata.
    pub(crate) const fn has_configuration_identity(&self) -> bool {
        self.harness.is_reported() && self.model_override.is_reported()
    }

    /// The summary, merged over `previous` (the last summary of the same session, if any).
    ///
    /// # Errors
    ///
    /// A status this client does not know.
    pub(crate) fn summary(
        &self,
        previous: Option<&SessionSummary>,
    ) -> Result<SessionSummary, String> {
        let has_pending = self.pending_count.value().is_some_and(|count| *count > 0)
            || self.pending_elicitations > 0;
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
        Ok(SessionSummary {
            id: self.id.clone(),
            title: self
                .title
                .value()
                .filter(|title| !title.is_empty())
                .cloned()
                .unwrap_or_else(|| "Untitled session".to_owned()),
            preview: if has_pending {
                "Needs your response".to_owned()
            } else {
                self.search_snippet
                    .value()
                    .cloned()
                    .unwrap_or_else(|| status_preview.to_owned())
            },
            status: if has_pending {
                SummaryStatus::NeedsResponse
            } else {
                status
            },
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
                .and_then(|labels| labels.get("omnigent.pinned"))
                .is_some_and(|stamp| !stamp.is_empty()),
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
            configuration: Some(
                self.configuration(previous.and_then(|p| p.configuration.as_ref())),
            ),
            configuration_revision: None,
        })
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
        configuration
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

/// The list query `NativeLab` sent, plus the explicit `visibility` the repo requires.
fn list_query(
    after: Option<&str>,
    limit: u32,
    inventory: bool,
) -> Result<Vec<(&'static str, String)>, SessionError> {
    let mut query = page_query(after, limit)?;
    query.push(("sort_by", "updated_at".to_owned()));
    query.push(("include_archived", "true".to_owned()));
    query.push(("visibility", "all".to_owned()));
    if inventory {
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
        let result = self.list_page(after, limit, false).await;
        self.dispatch();
        result.map(|(sessions, next_cursor)| SessionPage {
            sessions,
            next_cursor,
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
                .list_page(after.as_deref(), INVENTORY_PAGE_LIMIT, true)
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
        inventory: bool,
    ) -> Result<(Vec<SessionSummary>, Option<String>), SessionError> {
        let query = list_query(after, limit, inventory)?;
        let prepared = self.prepare("GET", "/v1/sessions", &query, None)?;
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
    async fn edit(
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
                json!({"labels": {"omnigent.pinned": stamp}})
            }
            SessionChange::Archived(archived) => {
                if !summary.can_archive() {
                    return Err(SessionError::ReadOnly);
                }
                json!({"archived": archived})
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
        let mut hydrate = None;
        for projection in &projections {
            let summary = projection
                .summary(state.summaries.get(&projection.id))
                .map_err(malformed("session row"))?;
            let summary = state.record_summary(summary);
            state.cache_summary(&summary);
            if state.live_session.as_deref() == Some(projection.id.as_str())
                && !projection.has_configuration_identity()
            {
                hydrate = Some(projection.id.clone());
            }
            changed.push(summary);
        }
        state.events.push(ClientEvent::SessionsChanged {
            sessions: changed.clone(),
        });
        state.events.push(ClientEvent::InventoryInvalidated);
        if let Some(session_id) = hydrate {
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
            if state
                .live_session
                .as_ref()
                .is_some_and(|live| ids.contains(live))
            {
                state.live_session = None;
            }
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
        if self.live_session.as_deref() == Some(session_id) {
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
}
