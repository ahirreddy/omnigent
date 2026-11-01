//! The conversation state the reducer folds history and live events into.
//!
//! Everything here is plain data. Rows, activities, decisions and sections are what a view
//! renders; [`SessionEventState`] is the typed, sparse session metadata that the stream reports
//! outside the transcript (usage, plan, startup progress, child sessions and so on). Ported from
//! `NativeLab`'s `ConversationSnapshot`, `ConversationMessage`, `ConversationActivity` and
//! `SessionEventState`.

use std::collections::{BTreeMap, BTreeSet};

use omnigent_protocol::ElicitationRequest;
use omnigent_protocol::events::{PresenceViewer, Todo};
use omnigent_protocol::sessions::{McpServerStartup, ModelUsage, NativeModelOption, SandboxStatus};
use serde_json::{Map, Value};

/// Bound on keyed session records (resources, children, changed-file environments).
pub const MAX_RECORDS: usize = 500;

/// Prefix of live previews that a persisted item replaces.
pub const LIVE_PREFIX: &str = "live:";
/// Prefix of rows synthesised from display-only stream events.
pub const EVENT_PREFIX: &str = "event:";

/// Who a row belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RowRole {
    /// The person using the app.
    User,
    /// The agent's reply text.
    Assistant,
    /// Tool, lifecycle and other activity rows.
    Tool,
}

impl RowRole {
    /// A stable lowercase name.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Assistant => "assistant",
            Self::Tool => "tool",
        }
    }
}

/// What an activity row shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ActivityKind {
    /// A function call.
    ToolCall,
    /// A function call result, streamed or committed.
    ToolResult,
    /// A provider-native tool call (web search, code interpreter, MCP, ...).
    NativeTool,
    /// A public reasoning summary.
    Reasoning,
    /// Context compaction.
    Compaction,
    /// A slash command or skill receipt.
    Command,
    /// A shell-mode terminal command or its output.
    Terminal,
    /// A model routing decision.
    Routing,
    /// A session resource receipt.
    Resource,
    /// A failure.
    Error,
    /// Content or an event this client does not know, shown through safe display text.
    Unknown,
    /// A retried model or tool call.
    Retry,
    /// A generated file.
    File,
    /// A policy denial.
    Policy,
    /// A client-side task the server cancelled.
    ClientTask,
    /// A desktop browser action (display only on mobile).
    Browser,
    /// A side question and its answer (`session.btw_sidechat`).
    Sidechat,
}

impl ActivityKind {
    /// A stable camel-case name (the `NativeLab` raw value).
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ToolCall => "toolCall",
            Self::ToolResult => "toolResult",
            Self::NativeTool => "nativeTool",
            Self::Reasoning => "reasoning",
            Self::Compaction => "compaction",
            Self::Command => "command",
            Self::Terminal => "terminal",
            Self::Routing => "routing",
            Self::Resource => "resource",
            Self::Error => "error",
            Self::Unknown => "unknown",
            Self::Retry => "retry",
            Self::File => "file",
            Self::Policy => "policy",
            Self::ClientTask => "clientTask",
            Self::Browser => "browser",
            Self::Sidechat => "sidechat",
        }
    }
}

/// One titled block of detail text inside an activity or a session section.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DetailSection {
    /// Stable id within its parent.
    pub id: String,
    /// Heading.
    pub title: String,
    /// Sanitised, bounded text.
    pub text: String,
    /// Render monospaced.
    pub is_code: bool,
}

impl DetailSection {
    /// A detail section.
    #[must_use]
    pub fn new(id: &str, title: &str, text: impl Into<String>, is_code: bool) -> Self {
        Self {
            id: id.to_owned(),
            title: title.to_owned(),
            text: text.into(),
            is_code,
        }
    }
}

/// What an attachment holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AttachmentKind {
    /// An image.
    Image,
    /// Any other file.
    File,
    /// Audio.
    Audio,
    /// Video.
    Video,
}

impl AttachmentKind {
    /// A stable lowercase name.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Image => "image",
            Self::File => "file",
            Self::Audio => "audio",
            Self::Video => "video",
        }
    }
}

/// A display-only attachment descriptor. Views must not fetch `reference` automatically.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Attachment {
    /// Stable id within the row.
    pub id: String,
    /// What it holds.
    pub kind: AttachmentKind,
    /// File name or a generic label.
    pub title: String,
    /// A session file id or a non-embedded URL.
    pub reference: Option<String>,
    /// Media type, when sent.
    pub mime_type: Option<String>,
    /// The bytes were inline and have been dropped.
    pub is_embedded: bool,
}

/// The typed presentation of a non-text row.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Activity {
    /// What the row shows.
    pub kind: ActivityKind,
    /// Headline, for example `Using fixture-model` or `Terminal output`.
    pub title: String,
    /// One bounded line or paragraph.
    pub summary: String,
    /// Status as reported or derived, for example `in_progress`, `completed` or `failed`.
    pub status: Option<String>,
    /// Detail blocks.
    pub details: Vec<DetailSection>,
}

impl Activity {
    /// True for errors and failed, error or denied statuses.
    #[must_use]
    pub fn is_failure(&self) -> bool {
        self.kind == ActivityKind::Error || self.status_is(&["failed", "error", "denied"])
    }

    /// True for routine bookkeeping that belongs in an activity drawer rather than the transcript:
    /// resource receipts and finished client tasks. Failures are never routine.
    #[must_use]
    pub fn is_routine_lifecycle(&self) -> bool {
        if self.is_failure() {
            return false;
        }
        self.kind == ActivityKind::Resource
            || (self.kind == ActivityKind::ClientTask
                && self.status_is(&["cancelled", "canceled", "completed"]))
    }

    fn status_is(&self, values: &[&str]) -> bool {
        let status = self.status.as_deref().unwrap_or_default().to_lowercase();
        values.contains(&status.as_str())
    }

    /// The text of the detail section with `id`.
    #[must_use]
    pub fn detail(&self, id: &str) -> Option<&str> {
        self.details
            .iter()
            .find(|detail| detail.id == id)
            .map(|detail| detail.text.as_str())
    }
}

/// One transcript or activity row, keyed by a stable id.
///
/// Persisted rows use the server item id. Live previews use `live:<message_id>`,
/// `live:response:<response_id>:<segment>`, `live:tool:...` or `live:reasoning:...`; rows made from
/// display-only events use `event:...`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Row {
    /// Stable id (see above).
    pub id: String,
    /// Who the row belongs to.
    pub role: RowRole,
    /// The plain text of the row.
    pub text: String,
    /// The row is still receiving deltas.
    pub is_streaming: bool,
    /// The typed presentation of a non-text row.
    pub activity: Option<Activity>,
    /// Attachment descriptors.
    pub attachments: Vec<Attachment>,
    /// The tool call the row belongs to.
    pub call_id: Option<String>,
    /// The response (turn) the row belongs to.
    pub response_id: Option<String>,
    /// The reply was cut off by a stop or interrupt.
    pub interrupted: bool,
    /// The human author.
    pub author: Option<String>,
    /// The agent that wrote it.
    pub agent: Option<String>,
}

impl Row {
    /// A plain row with no activity.
    #[must_use]
    pub fn text(id: impl Into<String>, role: RowRole, text: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            role,
            text: text.into(),
            is_streaming: false,
            activity: None,
            attachments: Vec::new(),
            call_id: None,
            response_id: None,
            interrupted: false,
            author: None,
            agent: None,
        }
    }

    /// True for a live preview or an event row: rows a persisted item may replace.
    #[must_use]
    pub fn is_ephemeral(&self) -> bool {
        self.id.starts_with(LIVE_PREFIX) || self.id.starts_with(EVENT_PREFIX)
    }

    /// True for a routine lifecycle row with no attachments: it belongs in the activity drawer.
    #[must_use]
    pub fn is_activity_only(&self) -> bool {
        self.role == RowRole::Tool
            && self
                .activity
                .as_ref()
                .is_some_and(Activity::is_routine_lifecycle)
            && self.attachments.is_empty()
    }

    /// The kind of the row's activity.
    #[must_use]
    pub fn activity_kind(&self) -> Option<ActivityKind> {
        self.activity.as_ref().map(|activity| activity.kind)
    }
}

/// The session's turn status as the conversation view shows it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum TurnStatus {
    /// Nothing is running.
    #[default]
    Idle,
    /// A turn or background work is in progress.
    Running,
    /// A decision is pending.
    NeedsResponse,
}

impl TurnStatus {
    /// A stable camel-case name.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Running => "running",
            Self::NeedsResponse => "needsResponse",
        }
    }
}

/// A configuration value that distinguishes "not reported" from an explicit harness default.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub enum ReportedValue {
    /// The server has not said.
    #[default]
    NotReported,
    /// The server reported `null`: the harness default applies.
    HarnessDefault,
    /// The server reported a value (unknown values are kept verbatim).
    Value {
        /// The value as sent.
        value: String,
    },
}

impl ReportedValue {
    /// The value, when one was reported.
    #[must_use]
    pub fn value(&self) -> Option<&str> {
        match self {
            Self::Value { value } => Some(value),
            Self::NotReported | Self::HarnessDefault => None,
        }
    }

    /// True once the server reported a value or `null`.
    #[must_use]
    pub const fn is_reported(&self) -> bool {
        !matches!(self, Self::NotReported)
    }

    /// From a reported optional value (`None` is an explicit `null`).
    #[must_use]
    pub fn reported(value: Option<String>) -> Self {
        value.map_or(Self::HarnessDefault, |value| Self::Value { value })
    }
}

/// The session's harness, model and execution settings, as last reported.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SessionSettings {
    /// The agent.
    pub agent_id: Option<String>,
    /// The harness, for example `codex-native`.
    pub harness: Option<String>,
    /// The `omnigent.wrapper` label.
    pub wrapper: Option<String>,
    /// The model override (`model_override`, `session.model`).
    pub model_override: ReportedValue,
    /// The agent's base model (`llm_model`).
    pub base_model: Option<String>,
    /// The reasoning effort (`reasoning_effort`, `session.reasoning_effort`).
    pub reasoning_effort: ReportedValue,
    /// Native model-picker rows.
    pub model_options: Vec<NativeModelOption>,
    /// The bound host.
    pub host_id: Option<String>,
    /// The host is online.
    pub host_online: Option<bool>,
    /// The runner is online.
    pub runner_online: Option<bool>,
    /// A runner is bound.
    pub runner_bound: Option<bool>,
    /// A managed host can be woken.
    pub host_resumable: Option<bool>,
    /// The parent session of a child.
    pub parent_id: Option<String>,
    /// `cost_control_mode_override` (for example `on` for smart routing).
    pub routing_mode: Option<String>,
}

/// Session metadata shown with the conversation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionHeader {
    /// The session id.
    pub id: String,
    /// Title.
    pub title: String,
    /// Turn status.
    pub status: TurnStatus,
    /// The caller cannot write to the session.
    pub read_only: bool,
    /// Archived.
    pub archived: bool,
    /// The caller's permission level.
    pub permission_level: Option<i64>,
    /// A readable failure of the last turn.
    pub failure_message: Option<String>,
    /// Harness, model and execution settings, once reported.
    pub settings: Option<SessionSettings>,
    /// The metadata ledger's stamp; newer stamps win (see `reconcile::MetadataLedger`).
    pub metadata_revision: Option<u64>,
}

impl SessionHeader {
    /// A header with only an id and title, idle and writable.
    #[must_use]
    pub fn new(id: impl Into<String>, title: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            status: TurnStatus::Idle,
            read_only: false,
            archived: false,
            permission_level: None,
            failure_message: None,
            settings: None,
            metadata_revision: None,
        }
    }
}

/// A decision request (elicitation) attached to the conversation. A pending one is never hidden.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Decision {
    /// The elicitation id.
    pub id: String,
    /// The session to resolve on (a child's id for a mirrored card).
    pub target_session_id: String,
    /// The request as sent.
    pub request: ElicitationRequest,
    /// The user answered it locally; the server has not confirmed yet.
    pub answered: bool,
}

impl Decision {
    /// A pending decision from a request carried by `session_id`'s stream or snapshot.
    #[must_use]
    pub fn pending(request: ElicitationRequest, session_id: &str) -> Self {
        Self {
            id: request.elicitation_id.clone(),
            target_session_id: request.target_session(session_id).to_owned(),
            request,
            answered: false,
        }
    }
}

/// The state of one environment's changed-files list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChangedFiles {
    /// Invalidated; the host is refetching it.
    Loading,
    /// Loaded entries.
    Loaded {
        /// `(path, status)` pairs in server order.
        entries: Vec<ChangedFile>,
    },
    /// The fetch failed.
    Failed {
        /// A readable message.
        message: String,
    },
}

/// One changed file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangedFile {
    /// The path.
    pub path: String,
    /// The status, for example `modified`.
    pub status: String,
}

/// Typed, sparse session metadata reported outside the transcript.
///
/// `None` means "never reported". Merging a newer state replaces each field it reports.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SessionEventState {
    /// The last lifecycle status label, for example `running`, `waiting`, `completed`.
    pub status: Option<String>,
    /// Running background shells.
    pub background_task_count: Option<u64>,
    /// Codex collaboration mode.
    pub collaboration_mode: Option<String>,
    /// Permission mode.
    pub permission_mode: Option<String>,
    /// Codex approval mode.
    pub approval_mode: Option<String>,
    /// Tokens in context.
    pub context_tokens: Option<u64>,
    /// Context window.
    pub context_window: Option<u64>,
    /// Cumulative cost.
    pub total_cost_usd: Option<f64>,
    /// Usage per model.
    pub usage_by_model: Option<BTreeMap<String, ModelUsage>>,
    /// The native plan.
    pub todos: Option<Vec<Todo>>,
    /// Current viewers.
    pub viewers: Option<Vec<PresenceViewer>>,
    /// MCP server startup states.
    pub mcp_startup: Option<BTreeMap<String, McpServerStartup>>,
    /// A terminal is being auto-created.
    pub terminal_pending: Option<bool>,
    /// Managed sandbox launch progress.
    pub sandbox: Option<SandboxStatus>,
    /// Live session resources by id.
    pub resources: Option<BTreeMap<String, Map<String, Value>>>,
    /// Terminals that produced output.
    pub terminal_activity: Option<BTreeSet<String>>,
    /// Child sessions by id: the merged fields the stream reported.
    pub children: Option<BTreeMap<String, Map<String, Value>>>,
    /// Changed files by environment.
    pub changed_files: Option<BTreeMap<String, ChangedFiles>>,
    /// The session the conversation continues in.
    pub superseded_by: Option<String>,
}

fn take_newer<T: Clone>(target: &mut Option<T>, newer: Option<&T>) {
    if let Some(value) = newer {
        *target = Some(value.clone());
    }
}

impl SessionEventState {
    /// Replaces every field `newer` reports.
    pub fn merge(&mut self, newer: &Self) {
        take_newer(&mut self.status, newer.status.as_ref());
        take_newer(
            &mut self.background_task_count,
            newer.background_task_count.as_ref(),
        );
        take_newer(
            &mut self.collaboration_mode,
            newer.collaboration_mode.as_ref(),
        );
        take_newer(&mut self.permission_mode, newer.permission_mode.as_ref());
        take_newer(&mut self.approval_mode, newer.approval_mode.as_ref());
        take_newer(&mut self.context_tokens, newer.context_tokens.as_ref());
        take_newer(&mut self.context_window, newer.context_window.as_ref());
        take_newer(&mut self.total_cost_usd, newer.total_cost_usd.as_ref());
        take_newer(&mut self.usage_by_model, newer.usage_by_model.as_ref());
        take_newer(&mut self.todos, newer.todos.as_ref());
        take_newer(&mut self.viewers, newer.viewers.as_ref());
        take_newer(&mut self.mcp_startup, newer.mcp_startup.as_ref());
        take_newer(&mut self.terminal_pending, newer.terminal_pending.as_ref());
        take_newer(&mut self.sandbox, newer.sandbox.as_ref());
        take_newer(&mut self.resources, newer.resources.as_ref());
        take_newer(
            &mut self.terminal_activity,
            newer.terminal_activity.as_ref(),
        );
        take_newer(&mut self.children, newer.children.as_ref());
        take_newer(&mut self.changed_files, newer.changed_files.as_ref());
        take_newer(&mut self.superseded_by, newer.superseded_by.as_ref());
    }
}

/// Inserts or removes one keyed record, keeping at most [`MAX_RECORDS`] (the lexicographically
/// first key is dropped). An empty id is ignored.
pub(super) fn update_record<T>(
    records: &mut Option<BTreeMap<String, T>>,
    id: &str,
    value: Option<T>,
) {
    if id.is_empty() {
        return;
    }
    let records = records.get_or_insert_with(BTreeMap::new);
    match value {
        Some(value) => {
            records.insert(id.to_owned(), value);
        }
        None => {
            records.remove(id);
        }
    }
    if records.len() > MAX_RECORDS {
        records.pop_first();
    }
}

/// The whole presentable state of one conversation.
#[derive(Debug, Clone, PartialEq)]
pub struct ConversationSnapshot {
    /// Increases with every published change.
    pub revision: u64,
    /// Session metadata.
    pub header: SessionHeader,
    /// Rows in chronological order. Ids are unique.
    pub rows: Vec<Row>,
    /// Decision requests, pending or locally answered.
    pub decisions: Vec<Decision>,
    /// Sparse session metadata.
    pub event_state: SessionEventState,
}

impl ConversationSnapshot {
    /// An empty conversation.
    #[must_use]
    pub fn new(header: SessionHeader) -> Self {
        Self {
            revision: 0,
            header,
            rows: Vec::new(),
            decisions: Vec::new(),
            event_state: SessionEventState::default(),
        }
    }

    /// The session id.
    #[must_use]
    pub fn id(&self) -> &str {
        &self.header.id
    }

    /// Decisions the user has not answered.
    pub fn pending_decisions(&self) -> impl Iterator<Item = &Decision> {
        self.decisions.iter().filter(|decision| !decision.answered)
    }

    /// True when any decision is pending.
    #[must_use]
    pub fn has_pending_decisions(&self) -> bool {
        self.pending_decisions().next().is_some()
    }

    /// Rows that belong in the transcript.
    pub fn transcript_rows(&self) -> impl Iterator<Item = &Row> {
        self.rows.iter().filter(|row| !row.is_activity_only())
    }

    /// Routine lifecycle rows that belong in the activity drawer.
    pub fn lifecycle_rows(&self) -> impl Iterator<Item = &Row> {
        self.rows.iter().filter(|row| row.is_activity_only())
    }

    /// The row with `id`.
    #[must_use]
    pub fn row(&self, id: &str) -> Option<&Row> {
        self.rows.iter().find(|row| row.id == id)
    }
}
