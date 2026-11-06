//! History-vs-live reconciliation.
//!
//! The session stream is a live tail with no replay (wire contract §5), so every (re)connect is
//! "subscribe, then read history, then replay what was buffered meanwhile". This module holds the
//! pure pieces of that handoff, ported from `NativeLab`'s `LocalServerStreaming`
//! (`finishHydration`, `rehydrateAfterMutation`, `recordConfigurationSummary`) and
//! `ConversationState`:
//!
//! - [`header_from_snapshot`], [`header_from_list_item`] and [`history_snapshot`] project REST
//!   reads into reducer state. List rows are sparse: absent fields keep what is known, explicit
//!   nulls clear (divergence D10).
//! - [`MetadataLedger`] stamps every metadata observation so a slow read can never roll back
//!   newer metadata, and a configuration read that crossed a change is rejected.
//! - [`ConversationSync`] owns the live reducer of the watched conversation: it buffers events
//!   while history loads, merges the history into the live state (dedupe by item id, previews
//!   kept in their slot, consumed inputs not repeated) and starts a fresh reducer on every real
//!   reconnect so an in-flight replay cannot double a prefix.
//! - [`ConversationState`] accepts only newer revisions of the same session.

use std::collections::BTreeMap;

use omnigent_protocol::events::SessionTodosEvent;
use omnigent_protocol::sessions::{DEFAULT_FAILURE_MESSAGE, McpStartupStatus};
use omnigent_protocol::{
    ConversationItem, Field, ServerStreamEvent, SessionListItem, SessionSnapshot, SessionStatus,
};
use serde_json::Value;

mod older;

pub use older::{HistoryPaging, OlderHistoryRequest};

use crate::reducer::{
    ChangeSet, ConversationSnapshot, Decision, Effects, LiveReducer, ProjectionError, ReducerError,
    ReportedValue, Row, SessionEventState, SessionHeader, SessionSettings, TurnStatus,
    decode_event, diff_rows, interrupted_reply, project_item, sections,
};

/// Browser action ids remembered for de-duplication across replays and reconnects.
pub const MAX_REMEMBERED_BROWSER_ACTIONS: usize = 512;
/// Events buffered at most while a history read is in flight.
pub const MAX_BUFFERED_EVENTS: usize = 1_024;
/// Title of a session that has none.
pub const UNTITLED_SESSION: &str = "Untitled session";
/// Title of a conversation whose metadata has not loaded yet.
pub const PLACEHOLDER_TITLE: &str = "Conversation";

const WRAPPER_LABEL: &str = "omnigent.wrapper";
const COLLABORATION_LABEL: &str = "omnigent.codex_native.collaboration_mode";
/// Setting events a stable configuration read supersedes.
const SETTING_EVENTS: &[&str] = &[
    "session.model",
    "session.reasoning_effort",
    "session.model_options",
    "session.agent_changed",
];
/// Events that may change a session's configuration or status.
const METADATA_EVENTS: &[&str] = &[
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

/// Accepts snapshots of one session in increasing revision order.
#[derive(Debug, Clone, PartialEq)]
pub struct ConversationState {
    snapshot: ConversationSnapshot,
}

impl ConversationState {
    /// Starts from `snapshot`.
    #[must_use]
    pub const fn new(snapshot: ConversationSnapshot) -> Self {
        Self { snapshot }
    }

    /// The accepted snapshot.
    #[must_use]
    pub const fn snapshot(&self) -> &ConversationSnapshot {
        &self.snapshot
    }

    /// Replaces the snapshot when `incoming` is the same session with a higher revision. Older and
    /// equal revisions are rejected, so a resolved decision cannot come back.
    pub fn apply(&mut self, incoming: ConversationSnapshot) -> bool {
        if incoming.id() != self.snapshot.id() || incoming.revision <= self.snapshot.revision {
            return false;
        }
        self.snapshot = incoming;
        true
    }
}

/// The sparse settings fields one read reported. Absent keeps, `null` clears.
#[derive(Debug, Clone, Default)]
struct SettingsPatch {
    agent_id: Field<String>,
    harness: Field<String>,
    labels: Field<BTreeMap<String, String>>,
    model_override: Field<String>,
    base_model: Field<String>,
    reasoning_effort: Field<String>,
    model_options: Field<Vec<omnigent_protocol::sessions::NativeModelOption>>,
    host_id: Field<String>,
    host_online: Field<bool>,
    runner_online: Field<bool>,
    runner_id: Field<String>,
    host_resumable: Field<bool>,
    parent_id: Field<String>,
    routing_mode: Field<String>,
}

fn same_as<T: PartialEq>(field: &Field<T>, known: Option<&T>) -> bool {
    match field {
        Field::Absent => true,
        Field::Null => known.is_none(),
        Field::Present(value) => known == Some(value),
    }
}

fn reported(field: &Field<String>, target: &mut ReportedValue) {
    match field {
        Field::Absent => {}
        Field::Null => *target = ReportedValue::HarnessDefault,
        Field::Present(value) => {
            *target = ReportedValue::Value {
                value: value.clone(),
            };
        }
    }
}

impl SettingsPatch {
    /// Merges onto `prior`. A different agent or harness starts from scratch, except the
    /// execution metadata, which belongs to the session.
    fn merge(self, prior: Option<&SessionSettings>) -> SessionSettings {
        let same_agent = same_as(&self.agent_id, prior.and_then(|p| p.agent_id.as_ref()))
            && same_as(&self.harness, prior.and_then(|p| p.harness.as_ref()));
        let mut settings = if same_agent {
            prior.cloned().unwrap_or_default()
        } else {
            SessionSettings::default()
        };
        if let Some(prior) = prior {
            settings.host_id.clone_from(&prior.host_id);
            settings.host_online = prior.host_online;
            settings.runner_online = prior.runner_online;
            settings.runner_bound = prior.runner_bound;
            settings.host_resumable = prior.host_resumable;
        }
        self.agent_id.apply_to(&mut settings.agent_id);
        self.harness.apply_to(&mut settings.harness);
        if self.labels.is_reported() {
            let labels = self.labels.value();
            settings.wrapper = labels.and_then(|labels| labels.get(WRAPPER_LABEL).cloned());
            settings.side_chat_source_id = labels
                .and_then(crate::session_tools::side_chat_source_id)
                .map(str::to_owned);
        }
        reported(&self.model_override, &mut settings.model_override);
        self.base_model.apply_to(&mut settings.base_model);
        reported(&self.reasoning_effort, &mut settings.reasoning_effort);
        if self.model_options.is_reported() {
            settings.model_options = self.model_options.into_value().unwrap_or_default();
        }
        if self.host_id.is_reported() {
            let host = self.host_id.value().cloned();
            if settings.host_id != host {
                settings.host_online = None;
                settings.runner_online = None;
                settings.runner_bound = None;
                settings.host_resumable = None;
            }
            settings.host_id = host;
        }
        self.host_online.apply_to(&mut settings.host_online);
        self.runner_online.apply_to(&mut settings.runner_online);
        if self.runner_id.is_reported() {
            settings.runner_bound = Some(self.runner_id.value().is_some_and(|id| !id.is_empty()));
        }
        self.host_resumable.apply_to(&mut settings.host_resumable);
        self.parent_id.apply_to(&mut settings.parent_id);
        self.routing_mode.apply_to(&mut settings.routing_mode);
        settings
    }
}

/// The header fields common to list rows and snapshots.
struct HeaderPatch<'a> {
    id: &'a str,
    status: &'a SessionStatus,
    pending: bool,
    title: &'a Field<String>,
    permission_level: &'a Field<i64>,
    archived: &'a Field<bool>,
    failure_message: Option<String>,
    settings: SettingsPatch,
}

impl HeaderPatch<'_> {
    fn merge(self, previous: Option<&SessionHeader>) -> Result<SessionHeader, ProjectionError> {
        let status = match self.status {
            _ if self.pending => TurnStatus::NeedsResponse,
            SessionStatus::Idle | SessionStatus::Failed => TurnStatus::Idle,
            SessionStatus::Running | SessionStatus::Waiting | SessionStatus::Launching => {
                TurnStatus::Running
            }
            SessionStatus::Unknown { value } => {
                return Err(ProjectionError::UnknownStatus {
                    session_id: self.id.to_owned(),
                    status: value.clone(),
                });
            }
        };
        let title = match self.title {
            Field::Present(title) if !title.is_empty() => title.clone(),
            Field::Present(_) | Field::Null => UNTITLED_SESSION.to_owned(),
            Field::Absent => {
                previous.map_or_else(|| UNTITLED_SESSION.to_owned(), |p| p.title.clone())
            }
        };
        let permission_level = match self.permission_level {
            Field::Present(level) => Some(*level),
            Field::Null => None,
            Field::Absent => previous.and_then(|p| p.permission_level),
        };
        let read_only = match self.permission_level {
            Field::Present(level) => *level < 2,
            Field::Null => true,
            Field::Absent => previous.is_none_or(|p| p.read_only),
        };
        let archived = match self.archived {
            Field::Present(archived) => *archived,
            Field::Null => false,
            Field::Absent => previous.is_some_and(|p| p.archived),
        };
        let prior_settings = previous.and_then(|p| p.settings.as_ref());
        Ok(SessionHeader {
            id: self.id.to_owned(),
            title,
            status,
            read_only,
            archived,
            permission_level,
            failure_message: self.failure_message,
            settings: Some(self.settings.merge(prior_settings)),
            metadata_revision: previous.and_then(|p| p.metadata_revision),
        })
    }
}

/// The header of a full session read, merged onto what is known.
///
/// # Errors
///
/// The session status is one this client does not know.
pub fn header_from_snapshot(
    session: &SessionSnapshot,
    previous: Option<&SessionHeader>,
) -> Result<SessionHeader, ProjectionError> {
    let previous = previous.filter(|header| header.id == session.id);
    HeaderPatch {
        id: &session.id,
        status: &session.status,
        pending: !session.pending_elicitations.is_empty(),
        title: &session.title,
        permission_level: &session.permission_level,
        archived: &session.archived,
        failure_message: session.failure_message().map(str::to_owned),
        settings: SettingsPatch {
            agent_id: session.agent_id.clone(),
            harness: session.harness.clone(),
            labels: session.labels.clone(),
            model_override: session.model_override.clone(),
            base_model: session.llm_model.clone(),
            reasoning_effort: session.reasoning_effort.clone(),
            model_options: session.model_options.clone(),
            host_id: session.host_id.clone(),
            host_online: session.host_online.clone(),
            runner_online: session.runner_online.clone(),
            runner_id: session.runner_id.clone(),
            host_resumable: session.host_resumable.clone(),
            parent_id: session.parent_session_id.clone(),
            routing_mode: session.cost_control_mode_override.clone(),
        },
    }
    .merge(previous)
}

/// The header of a session list row (REST page or WebSocket frame), merged onto what is known.
///
/// List rows never carry snapshot-only fields (model override, base model, model options,
/// resumability, routing), so those always keep their known values.
///
/// # Errors
///
/// The session status is one this client does not know.
pub fn header_from_list_item(
    row: &SessionListItem,
    previous: Option<&SessionHeader>,
) -> Result<SessionHeader, ProjectionError> {
    let previous = previous.filter(|header| header.id == row.id);
    let failure_message = (row.status == SessionStatus::Failed).then(|| {
        previous
            .and_then(|p| p.failure_message.clone())
            .unwrap_or_else(|| DEFAULT_FAILURE_MESSAGE.to_owned())
    });
    HeaderPatch {
        id: &row.id,
        status: &row.status,
        pending: row
            .pending_elicitations_count
            .value()
            .is_some_and(|count| *count > 0),
        title: &row.title,
        permission_level: &row.permission_level,
        archived: &row.archived,
        failure_message,
        settings: SettingsPatch {
            agent_id: row.agent_id.clone(),
            harness: row.harness.clone(),
            labels: row.labels.clone(),
            reasoning_effort: row.reasoning_effort.clone(),
            host_id: row.host_id.clone(),
            host_online: row.host_online.clone(),
            runner_online: row.runner_online.clone(),
            runner_id: row.runner_id.clone(),
            parent_id: row.parent_session_id.clone(),
            ..SettingsPatch::default()
        },
    }
    .merge(previous)
}

/// The sparse session metadata a snapshot reports.
#[must_use]
pub fn event_state_from_snapshot(session: &SessionSnapshot) -> SessionEventState {
    let todos = session.todos.value().map(|todos| {
        SessionTodosEvent {
            conversation_id: None,
            todos: todos.clone(),
        }
        .valid_todos()
    });
    let mcp_startup = session.mcp_startup.value().map(|servers| {
        let mut servers = servers.clone();
        servers.retain(|_, server| !matches!(server.status, McpStartupStatus::Unknown { .. }));
        servers
    });
    let collaboration_mode = session
        .labels
        .value()
        .and_then(|labels| labels.get(COLLABORATION_LABEL).cloned());
    SessionEventState {
        status: Some(session.status.as_str().to_owned()),
        background_task_count: session.background_task_count.value().copied(),
        background_tasks: session.background_task_count.value().is_some().then(|| {
            session
                .background_tasks
                .value()
                .cloned()
                .unwrap_or_default()
        }),
        context_tokens: session.last_total_tokens.value().copied(),
        context_window: session
            .context_window
            .value()
            .copied()
            .filter(|window| *window > 0),
        total_cost_usd: session
            .total_cost_usd
            .value()
            .copied()
            .filter(|cost| cost.is_finite() && *cost >= 0.0),
        usage_by_model: session.usage_by_model.value().cloned(),
        todos,
        mcp_startup,
        terminal_pending: session.terminal_pending.value().copied(),
        sandbox: session.sandbox_status.value().cloned(),
        collaboration_mode,
        ..SessionEventState::default()
    }
}

/// Rows for history items in chronological order, de-duplicated by item id.
///
/// A repeated id keeps its first position and its latest content. Hidden context is skipped; an
/// interrupt marker among it marks the reply it cut off as interrupted (see
/// [`interrupted_reply`]).
///
/// # Errors
///
/// An item cannot be shown (see [`project_item`]).
pub fn history_rows(items: &[ConversationItem]) -> Result<Vec<Row>, ProjectionError> {
    let mut rows: Vec<Row> = Vec::with_capacity(items.len());
    let mut positions: BTreeMap<String, usize> = BTreeMap::new();
    for item in items {
        let Some(row) = project_item(item)? else {
            if item.is_interrupt_marker()
                && let Some(reply) = interrupted_reply(&rows).and_then(|at| rows.get_mut(at))
            {
                reply.interrupted = true;
            }
            continue;
        };
        if let Some(slot) = positions.get(&row.id).and_then(|at| rows.get_mut(*at)) {
            *slot = row;
        } else {
            positions.insert(row.id.clone(), rows.len());
            rows.push(row);
        }
    }
    Ok(rows)
}

/// The authoritative conversation for a session read plus its history (chronological).
///
/// # Errors
///
/// An item cannot be shown (see [`project_item`]).
pub fn history_snapshot(
    session: &SessionSnapshot,
    items: &[ConversationItem],
    header: SessionHeader,
) -> Result<ConversationSnapshot, ProjectionError> {
    let decisions = session
        .pending_elicitations
        .iter()
        .map(|request| Decision::pending(request.clone(), &session.id))
        .collect();
    Ok(ConversationSnapshot {
        revision: 0,
        header,
        rows: history_rows(items)?,
        decisions,
        event_state: event_state_from_snapshot(session),
    })
}

/// Per-session metadata epochs and the latest known headers.
///
/// Every observation that may change a session's configuration or status bumps its epoch. A read
/// that started at an older epoch must not replace newer metadata: it keeps the cached header (or,
/// for a configuration read, is rejected as changed elsewhere).
#[derive(Debug, Clone, Default)]
pub struct MetadataLedger {
    epochs: BTreeMap<String, u64>,
    headers: BTreeMap<String, SessionHeader>,
    revision: u64,
}

impl MetadataLedger {
    /// The session's current epoch.
    #[must_use]
    pub fn epoch(&self, session_id: &str) -> u64 {
        self.epochs.get(session_id).copied().unwrap_or_default()
    }

    /// Every session's epoch.
    #[must_use]
    pub fn epochs(&self) -> BTreeMap<String, u64> {
        self.epochs.clone()
    }

    /// The latest known header.
    #[must_use]
    pub fn header(&self, session_id: &str) -> Option<&SessionHeader> {
        self.headers.get(session_id)
    }

    fn bump(&mut self, session_id: &str) {
        let epoch = self.epochs.entry(session_id.to_owned()).or_default();
        *epoch = epoch.wrapping_add(1);
    }

    /// Notes a stream event on `session_id`'s stream.
    pub fn record_event(&mut self, session_id: &str, event: &ServerStreamEvent) {
        if METADATA_EVENTS.contains(&event.event_type()) {
            self.bump(session_id);
        }
    }

    /// Stamps a freshly read header with the next metadata revision. A configuration, status,
    /// permission or archive change (or a first observation) bumps the session's epoch.
    pub fn record(&mut self, mut header: SessionHeader) -> SessionHeader {
        let changed = self.headers.get(&header.id).is_none_or(|known| {
            known.settings != header.settings
                || known.status != header.status
                || known.read_only != header.read_only
                || known.archived != header.archived
        });
        if changed {
            self.bump(&header.id);
        }
        self.revision = self.revision.wrapping_add(1);
        header.metadata_revision = Some(self.revision);
        header
    }

    /// Caches `header` as the latest known.
    pub fn cache(&mut self, header: SessionHeader) {
        self.headers.insert(header.id.clone(), header);
    }

    /// Forgets sessions the caller lost access to.
    pub fn remove(&mut self, session_ids: &[String]) {
        for id in session_ids {
            self.bump(id);
            self.headers.remove(id);
        }
    }

    /// The cached header when the session changed since `epoch` (a read that started then must
    /// not roll it back).
    #[must_use]
    pub fn newer_than(&self, session_id: &str, epoch: u64) -> Option<&SessionHeader> {
        (self.epoch(session_id) != epoch)
            .then(|| self.header(session_id))
            .flatten()
    }
}

/// A history read the host must perform: `GET /v1/sessions/{id}?include_items=false` plus the
/// newest `/items` pages, then [`ConversationSync::finish_hydration`] with this request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HydrationRequest {
    /// The session.
    pub session_id: String,
    generation: u64,
    ticket: u64,
    epoch: u64,
}

/// A configuration read in flight (see [`ConversationSync::begin_configuration_read`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigurationRead {
    /// The session.
    pub session_id: String,
    generation: u64,
    epoch: u64,
}

/// A session list read in flight (see [`ConversationSync::begin_list_read`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListRead {
    epochs: BTreeMap<String, u64>,
}

/// Why the conversation sync could not apply an input.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SyncError {
    /// An event could not be decoded or applied.
    #[error(transparent)]
    Reducer(#[from] ReducerError),
    /// A history read could not be shown.
    #[error(transparent)]
    Projection(#[from] ProjectionError),
    /// More events arrived during one history read than can be buffered; reconnect.
    #[error("more than {limit} events arrived while history was loading")]
    BufferOverflow {
        /// The buffer limit.
        limit: usize,
    },
}

/// Why a configuration read was not accepted.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ConfigurationReadError {
    /// The configuration changed while the read was in flight; review the current settings.
    #[error("settings changed elsewhere while they were being read")]
    ChangedElsewhere,
    /// The stream was stopped or restarted while the read was in flight.
    #[error("the conversation stream changed while settings were being read")]
    StreamChanged,
    /// The server answered for a different session.
    #[error("asked for session `{expected}` but the server answered for `{received}`")]
    WrongSession {
        /// The requested session.
        expected: String,
        /// The answered session.
        received: String,
    },
    /// The read could not be shown.
    #[error(transparent)]
    Projection(#[from] ProjectionError),
}

/// What a sync input changed and asks for.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SyncUpdate {
    /// UI changes to the watched conversation.
    pub changes: ChangeSet,
    /// Host effects of the applied event.
    pub effects: Effects,
    /// A history read to start.
    pub hydrate: Option<HydrationRequest>,
    /// Headers learned from a list read or frame, in row order.
    pub headers: Vec<SessionHeader>,
    /// The conversation's revision after this update.
    pub revision: u64,
}

/// Whether the conversation is watched and its stream attached.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Link {
    /// Watching stopped; every input is dropped.
    Stopped,
    /// Watched, no stream attached.
    Watching,
    /// Watched with a stream attached.
    Streaming,
}

/// The history read state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Hydration {
    /// No read in flight.
    Idle,
    /// A read is in flight; `again` asks for another once it lands.
    InFlight { ticket: u64, again: bool },
}

/// The live state of the watched conversation and the hydration handoff around it.
#[derive(Debug, Clone)]
pub struct ConversationSync {
    session_id: String,
    generation: u64,
    link: Link,
    reducer: Option<LiveReducer>,
    displaced: Option<ConversationSnapshot>,
    hydration: Hydration,
    next_ticket: u64,
    baseline: Option<LiveReducer>,
    buffered: Vec<ServerStreamEvent>,
    ledger: MetadataLedger,
    revision: u64,
    /// Browser actions already handed to the host, oldest first; survives reconnects.
    browser_actions: std::collections::VecDeque<String>,
    /// History loaded above the newest page; survives rehydrations and reconnects.
    older: older::OlderHistory,
}

impl ConversationSync {
    /// Starts watching `session_id` (no stream yet).
    #[must_use]
    pub fn new(session_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            generation: 0,
            link: Link::Watching,
            reducer: None,
            displaced: None,
            hydration: Hydration::Idle,
            next_ticket: 0,
            baseline: None,
            buffered: Vec::new(),
            ledger: MetadataLedger::default(),
            revision: 0,
            browser_actions: std::collections::VecDeque::new(),
            older: older::OlderHistory::default(),
        }
    }

    /// The watched session.
    #[must_use]
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// The live reducer, once there is one.
    #[must_use]
    pub const fn reducer(&self) -> Option<&LiveReducer> {
        self.reducer.as_ref()
    }

    /// The conversation as last published: the live state, or the state shown before a reconnect.
    #[must_use]
    pub fn published(&self) -> Option<&ConversationSnapshot> {
        self.reducer
            .as_ref()
            .map(LiveReducer::snapshot)
            .or(self.displaced.as_ref())
    }

    /// The metadata ledger.
    #[must_use]
    pub const fn ledger(&self) -> &MetadataLedger {
        &self.ledger
    }

    /// A history read is in flight.
    #[must_use]
    pub const fn is_hydrating(&self) -> bool {
        matches!(self.hydration, Hydration::InFlight { .. })
    }

    /// Another history read was requested while one was in flight.
    #[must_use]
    pub const fn hydration_requested_again(&self) -> bool {
        matches!(self.hydration, Hydration::InFlight { again: true, .. })
    }

    /// The types of the events buffered for the in-flight history read.
    #[must_use]
    pub fn buffered_event_types(&self) -> Vec<&str> {
        self.buffered
            .iter()
            .map(ServerStreamEvent::event_type)
            .collect()
    }

    fn publish(&mut self, changes: ChangeSet) -> SyncUpdate {
        if !changes.is_empty() {
            self.revision += 1;
        }
        SyncUpdate {
            changes,
            revision: self.revision,
            ..SyncUpdate::default()
        }
    }

    /// Installs a conversation loaded before the stream (for example a cached first page).
    pub fn adopt(&mut self, snapshot: ConversationSnapshot) -> SyncUpdate {
        let changes = self.replace_reducer(LiveReducer::new(snapshot));
        self.publish(changes)
    }

    /// Replaces the reducer, reporting the changes against what was published.
    fn replace_reducer(&mut self, next: LiveReducer) -> ChangeSet {
        let next_snapshot = next.snapshot();
        let mut changes = ChangeSet {
            rows: diff_rows(&[], &next_snapshot.rows),
            header: Some(next_snapshot.header.clone()),
            decisions: Some(next_snapshot.decisions.clone()),
            sections: Some(next.sections().to_vec()),
        };
        if let Some(old) = self.published() {
            changes.rows = diff_rows(&old.rows, &next_snapshot.rows);
            changes.header =
                (old.header != next_snapshot.header).then(|| next_snapshot.header.clone());
            changes.decisions =
                (old.decisions != next_snapshot.decisions).then(|| next_snapshot.decisions.clone());
            changes.sections =
                (sections(&old.event_state) != next.sections()).then(|| next.sections().to_vec());
        }
        self.reducer = Some(next);
        self.displaced = None;
        changes
    }

    /// A reducer for a live event when none exists: the committed part of what was shown, or an
    /// empty read-only conversation until metadata loads.
    fn ensure_reducer(&mut self) -> ChangeSet {
        if self.reducer.is_some() {
            return ChangeSet::default();
        }
        let snapshot = match &self.displaced {
            Some(old) => {
                let mut old = old.clone();
                old.rows.retain(|row| !row.is_ephemeral());
                old
            }
            None => ConversationSnapshot::new(
                self.ledger
                    .header(&self.session_id)
                    .cloned()
                    .unwrap_or_else(|| {
                        let mut header =
                            SessionHeader::new(self.session_id.clone(), PLACEHOLDER_TITLE);
                        header.read_only = true;
                        header
                    }),
            ),
        };
        self.replace_reducer(LiveReducer::new(snapshot))
    }

    /// The stream (re)connected: start a fresh reducer and read history. Events that arrive before
    /// the read finishes are shown at once and replayed onto the history when it lands.
    pub fn open_stream(&mut self) -> HydrationRequest {
        self.link = Link::Streaming;
        if let Some(reducer) = self.reducer.take() {
            self.displaced = Some(reducer.into_snapshot());
        }
        self.buffered.clear();
        self.baseline = None;
        self.new_request()
    }

    /// The stream ended or failed; the in-flight history read is abandoned.
    pub fn close_stream(&mut self) {
        if self.link == Link::Streaming {
            self.link = Link::Watching;
        }
        self.hydration = Hydration::Idle;
        self.baseline = None;
        self.buffered.clear();
    }

    /// Stops watching: later events, hydrations and reads for this generation are dropped.
    pub fn stop(&mut self) {
        self.close_stream();
        self.link = Link::Stopped;
        self.generation += 1;
        self.reducer = None;
        self.displaced = None;
        self.older.clear();
    }

    fn new_request(&mut self) -> HydrationRequest {
        self.next_ticket += 1;
        self.hydration = Hydration::InFlight {
            ticket: self.next_ticket,
            again: false,
        };
        HydrationRequest {
            session_id: self.session_id.clone(),
            generation: self.generation,
            ticket: self.next_ticket,
            epoch: self.ledger.epoch(&self.session_id),
        }
    }

    /// Asks for a history read (after a mutation, a reconcile effect or a sparse list change).
    /// While one is in flight another is queued instead, and `None` is returned.
    pub fn request_hydration(&mut self) -> Option<HydrationRequest> {
        if self.link == Link::Stopped {
            return None;
        }
        if let Hydration::InFlight { again, .. } = &mut self.hydration {
            *again = true;
            return None;
        }
        self.buffered.clear();
        self.baseline.clone_from(&self.reducer);
        Some(self.new_request())
    }

    fn is_current(&self, request: &HydrationRequest) -> bool {
        self.link != Link::Stopped
            && request.generation == self.generation
            && request.session_id == self.session_id
            && matches!(self.hydration, Hydration::InFlight { ticket, .. } if ticket == request.ticket)
    }

    /// The history read for `request` failed. Returns whether it was the current read; the host
    /// should reconnect the stream (which starts a new read).
    pub fn hydration_failed(&mut self, request: &HydrationRequest) -> bool {
        if !self.is_current(request) {
            return false;
        }
        self.close_stream();
        true
    }

    /// Applies one stream event payload (the SSE `data:` JSON).
    ///
    /// # Errors
    ///
    /// The event does not decode or apply ([`SyncError::Reducer`]), or too many events arrived
    /// during one history read ([`SyncError::BufferOverflow`]). Nothing changes on error.
    pub fn handle_event(&mut self, value: Value) -> Result<SyncUpdate, SyncError> {
        if self.link == Link::Stopped {
            return Ok(SyncUpdate::default());
        }
        let Some(event) = decode_event(value, &self.session_id).map_err(ReducerError::from)? else {
            return Ok(SyncUpdate::default());
        };
        if self.is_hydrating() && self.buffered.len() >= MAX_BUFFERED_EVENTS {
            return Err(SyncError::BufferOverflow {
                limit: MAX_BUFFERED_EVENTS,
            });
        }
        let mut changes = self.ensure_reducer();
        let Some(reducer) = self.reducer.as_mut() else {
            return Ok(self.publish(changes));
        };
        let mut outcome = reducer.apply(&event)?;
        self.ledger.record_event(&self.session_id, &event);
        if let Some(request) = &outcome.effects.browser_action {
            if self.browser_actions.contains(&request.action_id) {
                outcome.effects.browser_action = None;
            } else {
                if self.browser_actions.len() >= MAX_REMEMBERED_BROWSER_ACTIONS {
                    self.browser_actions.pop_front();
                }
                self.browser_actions.push_back(request.action_id.clone());
            }
        }
        changes.extend(outcome.changes);
        if self.is_hydrating() {
            self.buffered.push(event);
        }
        let hydrate = if outcome.effects.reconcile {
            self.request_hydration()
        } else {
            None
        };
        let mut update = self.publish(changes);
        update.effects = outcome.effects;
        update.hydrate = hydrate;
        Ok(update)
    }

    /// [`Self::finish_hydration_page`] for a read that holds the whole history.
    ///
    /// # Errors
    ///
    /// As [`Self::finish_hydration_page`].
    pub fn finish_hydration(
        &mut self,
        request: &HydrationRequest,
        session: &SessionSnapshot,
        items: &[ConversationItem],
    ) -> Result<SyncUpdate, SyncError> {
        self.finish_hydration_page(request, session, items, None)
    }

    /// The history read for `request` finished with `session`, its newest `items`
    /// (chronological) and the cursor for older items. Older pages loaded earlier are shown above
    /// the items while the page still reaches them.
    ///
    /// The read is merged into the live state: committed rows replace their previews, previews not
    /// in history yet keep their slot, buffered events are replayed onto the history (so a
    /// consumed input is not repeated), and a newer header learned meanwhile is kept. A stale
    /// request (superseded, or from a stopped stream) changes nothing.
    ///
    /// # Errors
    ///
    /// The read cannot be shown or a buffered event no longer applies. The sync is unchanged;
    /// call [`ConversationSync::hydration_failed`] and reconnect.
    pub fn finish_hydration_page(
        &mut self,
        request: &HydrationRequest,
        session: &SessionSnapshot,
        items: &[ConversationItem],
        older_cursor: Option<&str>,
    ) -> Result<SyncUpdate, SyncError> {
        if !self.is_current(request) || session.id != self.session_id {
            return Ok(SyncUpdate::default());
        }
        let header = match self.ledger.newer_than(&session.id, request.epoch) {
            Some(newer) => newer.clone(),
            None => header_from_snapshot(session, self.ledger.header(&session.id))?,
        };
        // Composed on a copy so a read that cannot be shown leaves paging as it was.
        let mut older = self.older.clone();
        let inherited_before = crate::session_tools::side_chat_inherited_before(
            session.labels.value(),
            session.harness.value().map(String::as_str),
            session.created_at,
        );
        let (own, older_cursor) = older::own_items(items, older_cursor, inherited_before);
        let items = older.compose(&own, older_cursor);
        older.inherited_before = inherited_before;
        let authoritative = history_snapshot(session, &items, header)?;
        let mut current = self.baseline.clone().map_or_else(
            || LiveReducer::new(authoritative.clone()),
            |mut baseline| {
                baseline.reconcile(authoritative.clone());
                baseline
            },
        );
        let mut again = self.hydration_requested_again();
        for event in &self.buffered {
            again |= current.apply(event)?.effects.reconcile;
        }
        let header = self.ledger.record(authoritative.header);
        self.ledger.cache(header.clone());
        current.set_header(header);
        self.buffered.clear();
        self.baseline = None;
        self.hydration = Hydration::Idle;
        self.older = older;
        let changes = match self.reducer.as_mut() {
            Some(live) => {
                let mut reconciled = current.into_snapshot();
                reconciled.rows.retain(|row| !row.is_ephemeral());
                live.reconcile(reconciled)
            }
            None => self.replace_reducer(current),
        };
        let hydrate = if again {
            self.request_hydration()
        } else {
            None
        };
        let mut update = self.publish(changes);
        update.hydrate = hydrate;
        Ok(update)
    }

    /// Records the result of a changed-files fetch for `environment` of the watched session.
    pub fn set_changed_files(
        &mut self,
        environment: &str,
        files: crate::reducer::ChangedFiles,
    ) -> SyncUpdate {
        let changes = self
            .reducer
            .as_mut()
            .map(|reducer| reducer.set_changed_files(environment, files))
            .unwrap_or_default();
        self.publish(changes)
    }

    /// Starts a configuration read of `session_id` (`GET /v1/sessions/{id}`).
    #[must_use]
    pub fn begin_configuration_read(&self, session_id: &str) -> ConfigurationRead {
        ConfigurationRead {
            session_id: session_id.to_owned(),
            generation: self.generation,
            epoch: self.ledger.epoch(session_id),
        }
    }

    /// Accepts a configuration read unless anything that could change the configuration was
    /// observed while it was in flight. An accepted read supersedes buffered setting events.
    ///
    /// # Errors
    ///
    /// [`ConfigurationReadError::ChangedElsewhere`] when the configuration may have changed during
    /// the read; nothing is cached. Also a wrong session, a restarted stream, or an unknown status.
    pub fn finish_configuration_read(
        &mut self,
        read: &ConfigurationRead,
        session: &SessionSnapshot,
    ) -> Result<(SessionHeader, SyncUpdate), ConfigurationReadError> {
        if session.id != read.session_id {
            return Err(ConfigurationReadError::WrongSession {
                expected: read.session_id.clone(),
                received: session.id.clone(),
            });
        }
        if read.epoch != self.ledger.epoch(&read.session_id) {
            return Err(ConfigurationReadError::ChangedElsewhere);
        }
        if read.generation != self.generation {
            return Err(ConfigurationReadError::StreamChanged);
        }
        let header = header_from_snapshot(session, self.ledger.header(&session.id))?;
        let header = self.ledger.record(header);
        if read.session_id == self.session_id {
            self.buffered
                .retain(|event| !SETTING_EVENTS.contains(&event.event_type()));
        }
        let update = self.accept_header(header.clone());
        Ok((header, update))
    }

    fn accept_header(&mut self, header: SessionHeader) -> SyncUpdate {
        self.ledger.cache(header.clone());
        let changes = if header.id == self.session_id {
            self.reducer
                .as_mut()
                .map(|reducer| reducer.set_header(header))
                .unwrap_or_default()
        } else {
            ChangeSet::default()
        };
        self.publish(changes)
    }

    /// Starts a session list read (`GET /v1/sessions`, one or more pages).
    #[must_use]
    pub fn begin_list_read(&self) -> ListRead {
        ListRead {
            epochs: self.ledger.epochs(),
        }
    }

    /// The headers of a finished list read. A row whose session changed while the read was in
    /// flight keeps the newer known header.
    ///
    /// # Errors
    ///
    /// A row has a status this client does not know.
    pub fn finish_list_read(
        &mut self,
        read: &ListRead,
        rows: &[SessionListItem],
    ) -> Result<SyncUpdate, ProjectionError> {
        let mut update = SyncUpdate::default();
        for row in rows {
            let started = read.epochs.get(&row.id).copied().unwrap_or_default();
            let header = match self.ledger.newer_than(&row.id, started) {
                Some(newer) => newer.clone(),
                None => header_from_list_item(row, self.ledger.header(&row.id))?,
            };
            let header = self.ledger.record(header);
            let accepted = self.accept_header(header.clone());
            update.changes.extend(accepted.changes);
            update.headers.push(header);
        }
        update.revision = self.revision;
        Ok(update)
    }

    /// A `snapshot` or `changed` frame from `WS /v1/sessions/updates`. Rows for the watched session
    /// are sparse (they never carry the model override), so one re-reads its history while the
    /// stream is attached.
    ///
    /// # Errors
    ///
    /// A row has a status this client does not know.
    pub fn handle_list_rows(
        &mut self,
        rows: &[SessionListItem],
    ) -> Result<SyncUpdate, ProjectionError> {
        let mut update = SyncUpdate::default();
        let mut hydrate_selected = false;
        for row in rows {
            let header = header_from_list_item(row, self.ledger.header(&row.id))?;
            let header = self.ledger.record(header);
            let accepted = self.accept_header(header.clone());
            update.changes.extend(accepted.changes);
            update.headers.push(header);
            hydrate_selected |= row.id == self.session_id;
        }
        if hydrate_selected && self.link == Link::Streaming {
            update.hydrate = self.request_hydration();
        }
        update.revision = self.revision;
        Ok(update)
    }

    /// A `removed` frame: the caller lost access to these sessions. Watching stops when the watched
    /// session is among them; returns whether it was.
    pub fn handle_removed(&mut self, session_ids: &[String]) -> bool {
        self.ledger.remove(session_ids);
        let watched = session_ids.contains(&self.session_id);
        if watched {
            self.stop();
        }
        watched
    }
}

#[cfg(test)]
#[path = "reducer/tests/reconcile_tests.rs"]
mod tests;
