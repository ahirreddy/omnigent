//! Transcript records: rows, activities, the session header and sections, and the row operations
//! a store applies in order (see `omnigent_core::reducer::apply_row_ops`).

use omnigent_core::reducer as core;

/// Who a row belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum RowRole {
    /// The person using the app.
    User,
    /// The agent's reply text.
    Assistant,
    /// Tool, lifecycle and other activity rows.
    Tool,
}

/// What an activity row shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
#[allow(
    missing_docs,
    reason = "each variant mirrors the core ActivityKind of the same name"
)]
pub enum ActivityKind {
    ToolCall,
    ToolResult,
    NativeTool,
    Reasoning,
    Compaction,
    Command,
    Terminal,
    Routing,
    Resource,
    Error,
    /// Content or an event this client does not know, shown through safe display text.
    Unknown,
    Retry,
    File,
    Policy,
    ClientTask,
    Browser,
    Sidechat,
}

/// One titled block of detail text.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
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

/// What an attachment holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
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

/// A display-only attachment. Views must not fetch `reference` automatically.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
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
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct Activity {
    /// What the row shows.
    pub kind: ActivityKind,
    /// Headline, for example `Using fixture-model`.
    pub title: String,
    /// One bounded line or paragraph.
    pub summary: String,
    /// Status as reported or derived (`in_progress`, `completed`, `failed`, ...).
    pub status: Option<String>,
    /// Detail blocks.
    pub details: Vec<DetailSection>,
    /// An error, or a failed, error or denied status.
    pub is_failure: bool,
}

/// One transcript or activity row, keyed by a stable id.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct Row {
    /// Stable id: the server item id, or `live:...` / `event:...` for previews.
    pub id: String,
    /// Who the row belongs to.
    pub role: RowRole,
    /// The plain text.
    pub text: String,
    /// Still receiving deltas.
    pub is_streaming: bool,
    /// The typed presentation of a non-text row.
    pub activity: Option<Activity>,
    /// Attachment descriptors.
    pub attachments: Vec<Attachment>,
    /// The tool call the row belongs to.
    pub call_id: Option<String>,
    /// The response (turn) the row belongs to.
    pub response_id: Option<String>,
    /// Cut off by a stop or interrupt.
    pub interrupted: bool,
    /// The human author.
    pub author: Option<String>,
    /// The agent that wrote it.
    pub agent: Option<String>,
    /// A live preview or event row that a persisted item may replace.
    pub is_ephemeral: bool,
    /// Routine bookkeeping that belongs in an activity drawer, not the transcript.
    pub is_activity_only: bool,
}

/// One edit to the row list. Apply in order; indexes are positions after every earlier op.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RowOp {
    /// Insert `row` at `index`.
    Insert {
        /// Position.
        index: u32,
        /// The new row.
        row: Row,
    },
    /// Replace the row at `index`, which has the same id.
    Update {
        /// Position.
        index: u32,
        /// The new content.
        row: Row,
    },
    /// Remove the row with `id`.
    Remove {
        /// The row id.
        id: String,
    },
}

/// The session's turn status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TurnStatus {
    /// Nothing is running.
    Idle,
    /// A turn or background work is in progress.
    Running,
    /// A decision is pending.
    NeedsResponse,
}

/// A configuration value that tells "not reported" from an explicit harness default.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ReportedValue {
    /// The server has not said.
    NotReported,
    /// The server reported `null`: the harness default applies.
    HarnessDefault,
    /// The server reported a value.
    Value {
        /// The value as sent.
        value: String,
    },
}

/// One native model-picker row.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ModelOption {
    /// Model id.
    pub id: String,
    /// Provider model name.
    pub model: Option<String>,
    /// Display name; fall back to `id`.
    pub display_name: Option<String>,
    /// Default reasoning effort.
    pub default_reasoning_effort: Option<String>,
    /// Supported reasoning efforts.
    pub supported_reasoning_efforts: Vec<String>,
    /// The default model.
    pub is_default: bool,
    /// Hidden from the picker.
    pub hidden: bool,
}

/// The session's harness, model and execution settings, as last reported.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SessionSettings {
    /// The agent.
    pub agent_id: Option<String>,
    /// The harness, for example `codex-native`.
    pub harness: Option<String>,
    /// The `omnigent.wrapper` label.
    pub wrapper: Option<String>,
    /// The model override.
    pub model_override: ReportedValue,
    /// The agent's base model.
    pub base_model: Option<String>,
    /// The reasoning effort.
    pub reasoning_effort: ReportedValue,
    /// Native model-picker rows.
    pub model_options: Vec<ModelOption>,
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
    /// `cost_control_mode_override`.
    pub routing_mode: Option<String>,
}

/// Session metadata shown with the conversation.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
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
    /// Settings, once reported.
    pub settings: Option<SessionSettings>,
}

/// One session-metadata section (usage, plan, children, changed files, ...).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EventSection {
    /// Stable id, for example `usage`.
    pub id: String,
    /// Heading.
    pub title: String,
    /// One line.
    pub summary: String,
    /// Detail blocks.
    pub details: Vec<DetailSection>,
    /// A session the section links to.
    pub session_id: Option<String>,
}

/// What changed in one conversation's transcript. Absent parts did not change.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TranscriptChange {
    /// Row edits, in order.
    pub rows: Vec<RowOp>,
    /// The new header.
    pub header: Option<SessionHeader>,
    /// The new sections.
    pub sections: Option<Vec<EventSection>>,
}

impl From<core::RowRole> for RowRole {
    fn from(role: core::RowRole) -> Self {
        match role {
            core::RowRole::User => Self::User,
            core::RowRole::Assistant => Self::Assistant,
            core::RowRole::Tool => Self::Tool,
        }
    }
}

impl From<core::ActivityKind> for ActivityKind {
    fn from(kind: core::ActivityKind) -> Self {
        use core::ActivityKind as K;
        match kind {
            K::ToolCall => Self::ToolCall,
            K::ToolResult => Self::ToolResult,
            K::NativeTool => Self::NativeTool,
            K::Reasoning => Self::Reasoning,
            K::Compaction => Self::Compaction,
            K::Command => Self::Command,
            K::Terminal => Self::Terminal,
            K::Routing => Self::Routing,
            K::Resource => Self::Resource,
            K::Error => Self::Error,
            K::Unknown => Self::Unknown,
            K::Retry => Self::Retry,
            K::File => Self::File,
            K::Policy => Self::Policy,
            K::ClientTask => Self::ClientTask,
            K::Browser => Self::Browser,
            K::Sidechat => Self::Sidechat,
        }
    }
}

impl From<core::DetailSection> for DetailSection {
    fn from(section: core::DetailSection) -> Self {
        Self {
            id: section.id,
            title: section.title,
            text: section.text,
            is_code: section.is_code,
        }
    }
}

impl From<core::AttachmentKind> for AttachmentKind {
    fn from(kind: core::AttachmentKind) -> Self {
        match kind {
            core::AttachmentKind::Image => Self::Image,
            core::AttachmentKind::File => Self::File,
            core::AttachmentKind::Audio => Self::Audio,
            core::AttachmentKind::Video => Self::Video,
        }
    }
}

impl From<core::Attachment> for Attachment {
    fn from(attachment: core::Attachment) -> Self {
        Self {
            id: attachment.id,
            kind: attachment.kind.into(),
            title: attachment.title,
            reference: attachment.reference,
            mime_type: attachment.mime_type,
            is_embedded: attachment.is_embedded,
        }
    }
}

impl From<core::Activity> for Activity {
    fn from(activity: core::Activity) -> Self {
        Self {
            is_failure: activity.is_failure(),
            kind: activity.kind.into(),
            title: activity.title,
            summary: activity.summary,
            status: activity.status,
            details: activity.details.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<core::Row> for Row {
    fn from(row: core::Row) -> Self {
        Self {
            is_ephemeral: row.is_ephemeral(),
            is_activity_only: row.is_activity_only(),
            id: row.id,
            role: row.role.into(),
            text: row.text,
            is_streaming: row.is_streaming,
            activity: row.activity.map(Into::into),
            attachments: row.attachments.into_iter().map(Into::into).collect(),
            call_id: row.call_id,
            response_id: row.response_id,
            interrupted: row.interrupted,
            author: row.author,
            agent: row.agent,
        }
    }
}

impl From<core::RowOp> for RowOp {
    fn from(op: core::RowOp) -> Self {
        match op {
            core::RowOp::Insert { index, row } => Self::Insert {
                index,
                row: row.into(),
            },
            core::RowOp::Update { index, row } => Self::Update {
                index,
                row: row.into(),
            },
            core::RowOp::Remove { id } => Self::Remove { id },
        }
    }
}

impl From<core::TurnStatus> for TurnStatus {
    fn from(status: core::TurnStatus) -> Self {
        match status {
            core::TurnStatus::Idle => Self::Idle,
            core::TurnStatus::Running => Self::Running,
            core::TurnStatus::NeedsResponse => Self::NeedsResponse,
        }
    }
}

impl From<core::ReportedValue> for ReportedValue {
    fn from(value: core::ReportedValue) -> Self {
        match value {
            core::ReportedValue::NotReported => Self::NotReported,
            core::ReportedValue::HarnessDefault => Self::HarnessDefault,
            core::ReportedValue::Value { value } => Self::Value { value },
        }
    }
}

impl From<omnigent_protocol::sessions::NativeModelOption> for ModelOption {
    fn from(option: omnigent_protocol::sessions::NativeModelOption) -> Self {
        Self {
            id: option.id,
            model: option.model,
            display_name: option.display_name,
            default_reasoning_effort: option.default_reasoning_effort,
            supported_reasoning_efforts: option
                .supported_reasoning_efforts
                .into_iter()
                .map(|effort| effort.reasoning_effort)
                .collect(),
            is_default: option.is_default.unwrap_or(false),
            hidden: option.hidden.unwrap_or(false),
        }
    }
}

impl From<core::SessionSettings> for SessionSettings {
    fn from(settings: core::SessionSettings) -> Self {
        Self {
            agent_id: settings.agent_id,
            harness: settings.harness,
            wrapper: settings.wrapper,
            model_override: settings.model_override.into(),
            base_model: settings.base_model,
            reasoning_effort: settings.reasoning_effort.into(),
            model_options: settings.model_options.into_iter().map(Into::into).collect(),
            host_id: settings.host_id,
            host_online: settings.host_online,
            runner_online: settings.runner_online,
            runner_bound: settings.runner_bound,
            host_resumable: settings.host_resumable,
            parent_id: settings.parent_id,
            routing_mode: settings.routing_mode,
        }
    }
}

impl From<core::SessionHeader> for SessionHeader {
    fn from(header: core::SessionHeader) -> Self {
        Self {
            id: header.id,
            title: header.title,
            status: header.status.into(),
            read_only: header.read_only,
            archived: header.archived,
            permission_level: header.permission_level,
            failure_message: header.failure_message,
            settings: header.settings.map(Into::into),
        }
    }
}

impl From<core::EventSection> for EventSection {
    fn from(section: core::EventSection) -> Self {
        Self {
            id: section.id,
            title: section.title,
            summary: section.summary,
            details: section.details.into_iter().map(Into::into).collect(),
            session_id: section.session_id,
        }
    }
}

impl TranscriptChange {
    /// The transcript part of a core change set; decisions are reported separately.
    pub(crate) fn from_changes(changes: &core::ChangeSet) -> Option<Self> {
        if changes.rows.is_empty() && changes.header.is_none() && changes.sections.is_none() {
            return None;
        }
        Some(Self {
            rows: changes.rows.iter().cloned().map(Into::into).collect(),
            header: changes.header.clone().map(Into::into),
            sections: changes
                .sections
                .clone()
                .map(|sections| sections.into_iter().map(Into::into).collect()),
        })
    }
}

/// Applies `ops` to `rows` in order, with the core's reference semantics. Stores that keep their
/// own arrays follow the same rules; this is for tests and previews.
///
/// # Errors
///
/// [`crate::errors::CoreError::RowOps`] for an op that does not fit; `rows` keeps the ops
/// applied before it.
#[uniffi::export]
pub fn apply_row_ops(
    rows: Vec<Row>,
    ops: Vec<RowOp>,
) -> Result<Vec<Row>, crate::errors::CoreError> {
    let mut rows = rows;
    for op in ops {
        match op {
            RowOp::Insert { index, row } => {
                let at = usize::try_from(index).unwrap_or(usize::MAX);
                if at > rows.len() {
                    return Err(crate::errors::core_error(core::RowOpError::OutOfBounds {
                        index,
                        len: rows.len(),
                    }));
                }
                rows.insert(at, row);
            }
            RowOp::Update { index, row } => {
                let len = rows.len();
                let at = usize::try_from(index).unwrap_or(usize::MAX);
                let slot = rows.get_mut(at).ok_or_else(|| {
                    crate::errors::core_error(core::RowOpError::OutOfBounds { index, len })
                })?;
                if slot.id != row.id {
                    return Err(crate::errors::core_error(core::RowOpError::IdMismatch {
                        index,
                        expected: row.id,
                        found: slot.id.clone(),
                    }));
                }
                *slot = row;
            }
            RowOp::Remove { id } => {
                let at = rows.iter().position(|row| row.id == id).ok_or_else(|| {
                    crate::errors::core_error(core::RowOpError::MissingRow { id: id.clone() })
                })?;
                rows.remove(at);
            }
        }
    }
    Ok(rows)
}
