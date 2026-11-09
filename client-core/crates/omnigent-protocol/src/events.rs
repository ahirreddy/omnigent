//! Live stream event models (`ServerStreamEvent` union with an `Unknown` fallback).
//!
//! Ground truth: the `ServerStreamEvent` union in `omnigent/server/schemas.py`. Every event model
//! ignores unknown fields, as the server's do. Decoding is strict about the type of every field
//! and about the fields that carry an event's meaning (a delta's text, a status, an elicitation
//! id), and lenient about presence of identity fields (`conversation_id`, `session_id`), which
//! older servers and test mocks omit. An unknown `type` decodes to [`ServerStreamEvent::Unknown`];
//! a known type with a broken shape is an error. `sequence_number` is not modelled: it is
//! unreliable (sometimes null) and clients must not depend on it.

use std::collections::BTreeMap;

use serde::ser::{Error as _, SerializeMap};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value};

use crate::display;
use crate::elicitation::{ElicitationRequest, ElicitationResolved};
use crate::error::{DecodeError, FromWire, decode_as, serialized_object};
use crate::field::{Field, null_as_default};
use crate::items::{ConversationItem, ErrorSource};
use crate::sessions::{
    BackgroundTaskInfo, ErrorDetail, McpServerStartup, ModelUsage, SandboxStage, SessionStatus,
};
use crate::wire_enum::wire_enum;

wire_enum! {
    /// `session.codex_approval_mode.approval_mode`.
    pub enum CodexApprovalMode {
        /// `ask-for-approval`.
        AskForApproval = "ask-for-approval",
        /// `approve-for-me`.
        ApproveForMe = "approve-for-me",
        /// `full-access`.
        FullAccess = "full-access",
        /// `read-only`.
        ReadOnly = "read-only",
    }
}

wire_enum! {
    /// `session.superseded.reason`.
    pub enum SupersededReason {
        /// `clear`: the conversation was cleared into a new session.
        Clear = "clear",
    }
}

wire_enum! {
    /// `ResponseObject.status`.
    pub enum ResponseStatus {
        /// `queued`.
        Queued = "queued",
        /// `in_progress`.
        InProgress = "in_progress",
        /// `completed`.
        Completed = "completed",
        /// `failed`.
        Failed = "failed",
        /// `cancelled`.
        Cancelled = "cancelled",
        /// `incomplete`.
        Incomplete = "incomplete",
    }
}

wire_enum! {
    /// A native plan item's status.
    pub enum TodoStatus {
        /// `pending`.
        Pending = "pending",
        /// `in_progress`.
        InProgress = "in_progress",
        /// `completed`.
        Completed = "completed",
    }
}

/// `session.status`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionStatusEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// The new status.
    pub status: SessionStatus,
    /// The turn the status is about.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response_id: Option<String>,
    /// Why the session failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorDetail>,
    /// Running background shells. Absent keeps the known count; an explicit 0 clears it.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub background_task_count: Field<u64>,
    /// Running background shell details.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub background_tasks: Field<Vec<BackgroundTaskInfo>>,
    /// What a `waiting` session is blocked on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked_on: Option<String>,
}

/// `session.usage`. Absent and null values leave the known value unchanged.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionUsageEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// Tokens in context.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_tokens: Option<u64>,
    /// Context window.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_window: Option<u64>,
    /// Cumulative cost in USD.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_cost_usd: Option<f64>,
    /// Per-model usage; replaces the known map.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage_by_model: Option<BTreeMap<String, ModelUsage>>,
}

/// `session.model`. A `null` model clears; an absent one is no change.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionModelEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// The model, as reported (unknown names are kept).
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub model: Field<String>,
}

/// `session.title`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionTitleEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// The new title.
    pub title: String,
}

/// `session.reasoning_effort`. A `null` effort clears; an absent one is no change.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionReasoningEffortEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// The effort.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub reasoning_effort: Field<String>,
}

/// `session.collaboration_mode`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionCollaborationModeEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// The mode, as sent.
    pub mode: String,
}

/// `session.permission_mode`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionPermissionModeEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// The mode, as sent.
    pub permission_mode: String,
}

/// `session.codex_approval_mode`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionCodexApprovalModeEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// The mode.
    pub approval_mode: CodexApprovalMode,
}

/// `session.agent_changed`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionAgentChangedEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// The new agent id.
    pub agent_id: String,
    /// The new agent name.
    pub agent_name: String,
}

/// A native plan item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Todo {
    /// The task text.
    pub content: String,
    /// The task status.
    pub status: TodoStatus,
    /// Present-tense label while in progress.
    pub active_form: Option<String>,
}

/// `session.todos`: replaces the whole plan.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionTodosEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// Plan items as sent (the server does not validate their shape).
    pub todos: Vec<Value>,
}

impl SessionTodosEvent {
    /// The items with a string `content` and a known `status`, in order.
    #[must_use]
    pub fn valid_todos(&self) -> Vec<Todo> {
        self.todos
            .iter()
            .filter_map(|todo| {
                let content = todo.get("content")?.as_str()?.to_owned();
                let status = TodoStatus::parse(todo.get("status")?.as_str()?);
                if status.is_unknown() {
                    return None;
                }
                let active_form = todo
                    .get("activeForm")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                Some(Todo {
                    content,
                    status,
                    active_form,
                })
            })
            .collect()
    }
}

/// `session.terminal_pending`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionTerminalPendingEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// True while the runner auto-creates a terminal.
    pub pending: bool,
}

/// `session.sandbox_status`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionSandboxStatusEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// Launch stage.
    pub stage: SandboxStage,
    /// Failure message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Provider.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    /// Extra detail.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
}

/// `session.mcp_startup`: replaces the whole server map.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionMcpStartupEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// Startup state by server name.
    pub servers: BTreeMap<String, McpServerStartup>,
}

/// `session.model_options`: refetch the model options.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionModelOptionsEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
}

/// The nested payload of `session.input.consumed`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InputConsumed {
    /// The persisted item id (matches a POST acknowledgement's `item_id`).
    pub item_id: String,
    /// The item type.
    #[serde(rename = "type")]
    pub item_type: String,
    /// The item data (nested shape).
    pub data: Map<String, Value>,
    /// The human author.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_by: Option<String>,
    /// Matches a POST acknowledgement's `pending_id`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cleared_pending_id: Option<String>,
}

impl InputConsumed {
    /// The consumed input as an item.
    ///
    /// # Errors
    ///
    /// The nested data does not decode as its item type.
    pub fn item(&self) -> Result<ConversationItem, DecodeError> {
        ConversationItem::from_parts(
            &self.item_id,
            &self.item_type,
            self.data.clone(),
            self.created_by.as_deref(),
        )
    }
}

/// `session.input.consumed`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionInputConsumedEvent {
    /// The consumed input.
    pub data: InputConsumed,
}

/// The nested payload of `session.interrupted`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Interrupted {
    /// When the interrupt was requested (Unix seconds).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requested_at: Option<i64>,
    /// The interrupted turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response_id: Option<String>,
}

/// `session.interrupted`. The server nests the payload under `data`; a flat `response_id` from
/// older payloads is also accepted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionInterruptedEvent {
    /// The nested payload.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Interrupted>,
    /// A flat response id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response_id: Option<String>,
}

impl SessionInterruptedEvent {
    /// The interrupted turn: `data.response_id`, else the flat `response_id`.
    #[must_use]
    pub fn response_id(&self) -> Option<&str> {
        self.data
            .as_ref()
            .and_then(|data| data.response_id.as_deref())
            .or(self.response_id.as_deref())
    }
}

/// `session.created`: a child session started (on the parent's stream).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionCreatedEvent {
    /// The parent session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// The child.
    pub child_session_id: String,
    /// The child's agent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    /// The child's parent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_session_id: Option<String>,
}

/// `session.superseded`: the conversation continues in another session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionSupersededEvent {
    /// The superseded session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// The session to open instead.
    pub target_conversation_id: String,
    /// Why.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<SupersededReason>,
}

/// `session.btw_sidechat`: a side question and its answer (an activity row, not a message).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionBtwSidechatEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// The question.
    pub question: String,
    /// The answer.
    pub answer: String,
    /// The answer was cut.
    #[serde(default, deserialize_with = "null_as_default")]
    pub truncated: bool,
}

/// One viewer of a session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresenceViewer {
    /// The viewer.
    pub user_id: String,
    /// When they joined (ISO 8601).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub joined_at: Option<String>,
    /// Idle.
    #[serde(default, deserialize_with = "null_as_default")]
    pub idle: bool,
}

/// `session.presence`: replaces the viewer list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionPresenceEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// Current viewers.
    pub viewers: Vec<PresenceViewer>,
}

/// `session.resource.created`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionResourceCreatedEvent {
    /// The resource object, as sent.
    pub resource: Map<String, Value>,
}

impl SessionResourceCreatedEvent {
    /// The resource id.
    #[must_use]
    pub fn resource_id(&self) -> Option<&str> {
        self.resource.get("id").and_then(Value::as_str)
    }

    /// The owning session, when the resource names one.
    #[must_use]
    pub fn session_id(&self) -> Option<&str> {
        self.resource.get("session_id").and_then(Value::as_str)
    }
}

/// `session.resource.deleted`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionResourceDeletedEvent {
    /// The resource id.
    pub resource_id: String,
    /// The resource kind.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource_type: Option<String>,
    /// The owning session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

/// `session.child_session.updated`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionChildSessionUpdatedEvent {
    /// The parent session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// The child.
    pub child_session_id: String,
    /// The child's changed fields, as sent.
    pub child: Map<String, Value>,
}

/// `session.changed_files.invalidated`: refetch changed files for an environment.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionChangedFilesInvalidatedEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// The environment; `default` when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment_id: Option<String>,
}

impl SessionChangedFilesInvalidatedEvent {
    /// The environment id, defaulting to `default`.
    #[must_use]
    pub fn environment_id(&self) -> &str {
        self.environment_id.as_deref().unwrap_or("default")
    }
}

/// `session.terminal.activity`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionTerminalActivityEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// The terminal resource.
    pub terminal_id: String,
}

/// `session.heartbeat` (stream ready on connect, then every 15 s).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionHeartbeatEvent {
    /// Server time.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_time: Option<String>,
}

/// `response.output_text.delta`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutputTextDeltaEvent {
    /// The text to append.
    pub delta: String,
    /// The live message (native turns).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    /// Chunk index; a non-negative integer. Repeats are no-ops.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<u64>,
    /// The last chunk of the message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub r#final: Option<bool>,
    /// Not sent by the current server; kept for older mocks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response_id: Option<String>,
}

/// `response.function_call_output.delta`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolOutputDeltaEvent {
    /// The tool call.
    pub call_id: String,
    /// The output to append.
    pub delta: String,
    /// Chunk index, when sent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<u64>,
}

/// `response.reasoning.started`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReasoningStartedEvent {
    /// The reasoning item, when sent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_id: Option<String>,
}

/// `response.reasoning_text.delta` and `response.reasoning_summary_text.delta`.
///
/// Raw reasoning text is private: show only summary deltas.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReasoningDeltaEvent {
    /// The text to append.
    pub delta: String,
    /// The reasoning item, when sent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_id: Option<String>,
    /// Chunk index, when sent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<u64>,
    /// Not sent by the current server; kept for older mocks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response_id: Option<String>,
}

/// `response.output_item.done`: a persisted item, flat shape.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutputItemDoneEvent {
    /// The committed item.
    pub item: ConversationItem,
}

/// `response.output_file.done`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutputFileDoneEvent {
    /// The session file id.
    pub file_id: String,
    /// File name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filename: Option<String>,
    /// Media type.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_type: Option<String>,
}

/// `response.heartbeat`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResponseHeartbeatEvent {
    /// Server time.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_time: Option<String>,
    /// Last event sequence number.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_event_seq: Option<i64>,
}

/// `browser.action_request`: a desktop embedded-browser action (display only on mobile).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BrowserActionRequestEvent {
    /// Action id.
    pub action_id: String,
    /// Action name.
    pub action: String,
    /// Action arguments, as sent.
    #[serde(default, deserialize_with = "null_as_default")]
    pub args: Map<String, Value>,
}

/// `ui.open_file`: an ignorable UI hint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UiOpenFileEvent {
    /// The file path.
    pub path: String,
}

/// `response.policy_denied`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyDeniedEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// Why.
    #[serde(default, deserialize_with = "null_as_default")]
    pub reason: String,
    /// Policy phase.
    #[serde(default, deserialize_with = "null_as_default")]
    pub phase: String,
}

/// Token usage of a response (`Usage`).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Usage {
    /// Input tokens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_tokens: Option<u64>,
    /// Output tokens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_tokens: Option<u64>,
    /// Total tokens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_tokens: Option<u64>,
    /// Tokens in context after the response.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_tokens: Option<u64>,
    /// Cache-read input tokens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read_input_tokens: Option<u64>,
    /// Cache-creation input tokens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_creation_input_tokens: Option<u64>,
    /// The model.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Cost in USD.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
}

/// Why a response stopped early.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IncompleteDetails {
    /// For example `user_interrupt` or `max_output_tokens`.
    pub reason: String,
}

/// A response (`ResponseObject`, or `FailedResponseObject` for failures before allocation).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResponseObject {
    /// Response id; absent only on early failures.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// Status.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<ResponseStatus>,
    /// Model.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Unix seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<i64>,
    /// Unix seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<i64>,
    /// Output items, as sent (shapes vary by item type).
    #[serde(default, deserialize_with = "null_as_default")]
    pub output: Vec<Value>,
    /// Usage.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<Usage>,
    /// The previous response in the conversation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_response_id: Option<String>,
    /// Failure details.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorDetail>,
    /// Why it stopped early.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub incomplete_details: Option<IncompleteDetails>,
}

/// `response.created`, `queued`, `in_progress`, `completed`, `cancelled` and `incomplete`.
///
/// The server always sends `response`; a flat `response_id` from older payloads is also accepted.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResponseLifecycleEvent {
    /// The response.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response: Option<ResponseObject>,
    /// A flat response id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response_id: Option<String>,
}

impl ResponseLifecycleEvent {
    /// `response.id`, else the flat `response_id`.
    #[must_use]
    pub fn response_id(&self) -> Option<&str> {
        self.response
            .as_ref()
            .and_then(|response| response.id.as_deref())
            .or(self.response_id.as_deref())
    }
}

/// `response.failed`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResponseFailedEvent {
    /// Where it failed (the server defaults to `execution`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<ErrorSource>,
    /// The response.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response: Option<ResponseObject>,
    /// A flat response id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response_id: Option<String>,
}

impl ResponseFailedEvent {
    /// `response.id`, else the flat `response_id`.
    #[must_use]
    pub fn response_id(&self) -> Option<&str> {
        self.response
            .as_ref()
            .and_then(|response| response.id.as_deref())
            .or(self.response_id.as_deref())
    }
}

/// The error of `response.retry` and `response.error` (`RetryErrorDetail`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StreamErrorDetail {
    /// Stable classifier.
    pub code: String,
    /// Human-readable message.
    pub message: String,
    /// Extra detail, as sent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<Map<String, Value>>,
}

/// `response.retry`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RetryEvent {
    /// `llm` or `tool`.
    pub source: ErrorSource,
    /// The retried tool.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    /// This attempt (1-based).
    pub attempt: u64,
    /// Attempt limit.
    pub max_attempts: u64,
    /// Delay before the retry.
    pub delay_seconds: f64,
    /// The error being retried.
    pub error: StreamErrorDetail,
}

/// `response.error`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorEvent {
    /// Where it failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<ErrorSource>,
    /// The failing tool.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    /// The error.
    pub error: StreamErrorDetail,
}

/// `response.compaction.in_progress`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompactionInProgressEvent {
    /// Unix seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<i64>,
}

/// `response.compaction.completed`. `compacted_messages` is not kept.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompactionCompletedEvent {
    /// Tokens in context after compaction.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_tokens: Option<u64>,
    /// The summary.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// The summarising model.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary_model: Option<String>,
}

/// `response.compaction.failed` (no fields).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompactionFailedEvent {}

/// `response.client_task.cancel`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClientTaskCancelEvent {
    /// The client task.
    pub task_id: String,
    /// The tool call it served.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
}

/// `turn.started`, `turn.completed` and `turn.cancelled`: lifecycle edges, never transcript items.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

/// `turn.failed`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnFailedEvent {
    /// The session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// The error, as sent.
    #[serde(default, deserialize_with = "null_as_default")]
    pub error: Map<String, Value>,
}

macro_rules! stream_events {
    ( $( $(#[$doc:meta])* $variant:ident($payload:ty) = $wire:literal, )+ ) => {
        /// One live stream event, by its `type`.
        #[derive(Debug, Clone, PartialEq)]
        pub enum ServerStreamEvent {
            $( $(#[$doc])* $variant($payload), )+
            /// A type this client does not know. Show it as a bounded placeholder through
            /// [`ServerStreamEvent::unknown_display_text`]; never drop it silently.
            Unknown {
                /// The event `type`.
                event_type: String,
                /// The whole event as sent.
                raw: Value,
            },
        }

        impl ServerStreamEvent {
            /// Every event type in the server's union.
            pub const KNOWN_TYPES: &'static [&'static str] = &[ $( $wire, )+ ];

            /// The wire `type`.
            #[must_use]
            pub fn event_type(&self) -> &str {
                match self {
                    $( Self::$variant(_) => $wire, )+
                    Self::Unknown { event_type, .. } => event_type,
                }
            }

            /// Decodes a known type; gives the value back for an unknown one.
            fn decode_known(
                event_type: &str,
                value: Value,
            ) -> Result<Result<Self, DecodeError>, Value> {
                let context = || format!("event `{event_type}`");
                Ok(match event_type {
                    $( $wire => decode_as::<$payload>(value, context).map(Self::$variant), )+
                    _ => return Err(value),
                })
            }

            fn serialize_payload<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                let payload = match self {
                    $( Self::$variant(payload) => serde_json::to_value(payload), )+
                    Self::Unknown { raw, .. } => return raw.serialize(serializer),
                }
                .map_err(S::Error::custom)?;
                let fields = serialized_object(payload, "event payload")?;
                let mut map = serializer.serialize_map(Some(fields.len() + 1))?;
                map.serialize_entry("type", self.event_type())?;
                for (key, value) in &fields {
                    map.serialize_entry(key, value)?;
                }
                map.end()
            }
        }
    };
}

stream_events! {
    /// `session.status`.
    SessionStatus(SessionStatusEvent) = "session.status",
    /// `session.usage`.
    SessionUsage(SessionUsageEvent) = "session.usage",
    /// `session.model`.
    SessionModel(SessionModelEvent) = "session.model",
    /// `session.title`.
    SessionTitle(SessionTitleEvent) = "session.title",
    /// `session.reasoning_effort`.
    SessionReasoningEffort(SessionReasoningEffortEvent) = "session.reasoning_effort",
    /// `session.collaboration_mode`.
    SessionCollaborationMode(SessionCollaborationModeEvent) = "session.collaboration_mode",
    /// `session.permission_mode`.
    SessionPermissionMode(SessionPermissionModeEvent) = "session.permission_mode",
    /// `session.codex_approval_mode`.
    SessionCodexApprovalMode(SessionCodexApprovalModeEvent) = "session.codex_approval_mode",
    /// `session.agent_changed`.
    SessionAgentChanged(SessionAgentChangedEvent) = "session.agent_changed",
    /// `session.todos`.
    SessionTodos(SessionTodosEvent) = "session.todos",
    /// `session.terminal_pending`.
    SessionTerminalPending(SessionTerminalPendingEvent) = "session.terminal_pending",
    /// `session.sandbox_status`.
    SessionSandboxStatus(SessionSandboxStatusEvent) = "session.sandbox_status",
    /// `session.mcp_startup`.
    SessionMcpStartup(SessionMcpStartupEvent) = "session.mcp_startup",
    /// `session.model_options`.
    SessionModelOptions(SessionModelOptionsEvent) = "session.model_options",
    /// `session.input.consumed`.
    SessionInputConsumed(SessionInputConsumedEvent) = "session.input.consumed",
    /// `session.interrupted`.
    SessionInterrupted(SessionInterruptedEvent) = "session.interrupted",
    /// `session.created`.
    SessionCreated(SessionCreatedEvent) = "session.created",
    /// `session.superseded`.
    SessionSuperseded(SessionSupersededEvent) = "session.superseded",
    /// `session.btw_sidechat`.
    SessionBtwSidechat(SessionBtwSidechatEvent) = "session.btw_sidechat",
    /// `session.presence`.
    SessionPresence(SessionPresenceEvent) = "session.presence",
    /// `session.resource.created`.
    SessionResourceCreated(SessionResourceCreatedEvent) = "session.resource.created",
    /// `session.resource.deleted`.
    SessionResourceDeleted(SessionResourceDeletedEvent) = "session.resource.deleted",
    /// `session.child_session.updated`.
    SessionChildSessionUpdated(SessionChildSessionUpdatedEvent) = "session.child_session.updated",
    /// `session.changed_files.invalidated`.
    SessionChangedFilesInvalidated(SessionChangedFilesInvalidatedEvent) =
        "session.changed_files.invalidated",
    /// `session.terminal.activity`.
    SessionTerminalActivity(SessionTerminalActivityEvent) = "session.terminal.activity",
    /// `response.output_text.delta`.
    OutputTextDelta(OutputTextDeltaEvent) = "response.output_text.delta",
    /// `response.function_call_output.delta`.
    ToolOutputDelta(ToolOutputDeltaEvent) = "response.function_call_output.delta",
    /// `response.reasoning.started`.
    ReasoningStarted(ReasoningStartedEvent) = "response.reasoning.started",
    /// `response.reasoning_text.delta` (private: never shown).
    ReasoningTextDelta(ReasoningDeltaEvent) = "response.reasoning_text.delta",
    /// `response.reasoning_summary_text.delta`.
    ReasoningSummaryTextDelta(ReasoningDeltaEvent) = "response.reasoning_summary_text.delta",
    /// `response.output_item.done`.
    OutputItemDone(OutputItemDoneEvent) = "response.output_item.done",
    /// `response.output_file.done`.
    OutputFileDone(OutputFileDoneEvent) = "response.output_file.done",
    /// `response.heartbeat`.
    ResponseHeartbeat(ResponseHeartbeatEvent) = "response.heartbeat",
    /// `session.heartbeat`.
    SessionHeartbeat(SessionHeartbeatEvent) = "session.heartbeat",
    /// `response.elicitation_request`: a pending decision.
    ElicitationRequest(ElicitationRequest) = "response.elicitation_request",
    /// `response.elicitation_resolved`.
    ElicitationResolved(ElicitationResolved) = "response.elicitation_resolved",
    /// `browser.action_request`.
    BrowserActionRequest(BrowserActionRequestEvent) = "browser.action_request",
    /// `ui.open_file`.
    UiOpenFile(UiOpenFileEvent) = "ui.open_file",
    /// `response.policy_denied`.
    PolicyDenied(PolicyDeniedEvent) = "response.policy_denied",
    /// `response.created`.
    ResponseCreated(ResponseLifecycleEvent) = "response.created",
    /// `response.queued`.
    ResponseQueued(ResponseLifecycleEvent) = "response.queued",
    /// `response.in_progress`.
    ResponseInProgress(ResponseLifecycleEvent) = "response.in_progress",
    /// `response.completed`.
    ResponseCompleted(ResponseLifecycleEvent) = "response.completed",
    /// `response.failed`.
    ResponseFailed(ResponseFailedEvent) = "response.failed",
    /// `response.cancelled`.
    ResponseCancelled(ResponseLifecycleEvent) = "response.cancelled",
    /// `response.incomplete`.
    ResponseIncomplete(ResponseLifecycleEvent) = "response.incomplete",
    /// `response.retry`.
    Retry(RetryEvent) = "response.retry",
    /// `response.error`.
    Error(ErrorEvent) = "response.error",
    /// `response.compaction.in_progress`.
    CompactionInProgress(CompactionInProgressEvent) = "response.compaction.in_progress",
    /// `response.compaction.completed`.
    CompactionCompleted(CompactionCompletedEvent) = "response.compaction.completed",
    /// `response.compaction.failed`.
    CompactionFailed(CompactionFailedEvent) = "response.compaction.failed",
    /// `response.client_task.cancel`.
    ClientTaskCancel(ClientTaskCancelEvent) = "response.client_task.cancel",
    /// `turn.started`.
    TurnStarted(TurnEvent) = "turn.started",
    /// `turn.completed`.
    TurnCompleted(TurnEvent) = "turn.completed",
    /// `turn.failed`.
    TurnFailed(TurnFailedEvent) = "turn.failed",
    /// `turn.cancelled`.
    TurnCancelled(TurnEvent) = "turn.cancelled",
}

impl ServerStreamEvent {
    /// True for a type this client does not know.
    #[must_use]
    pub const fn is_unknown(&self) -> bool {
        matches!(self, Self::Unknown { .. })
    }

    /// For an unknown event, its sanitised, bounded display text.
    #[must_use]
    pub fn unknown_display_text(&self) -> Option<String> {
        match self {
            Self::Unknown { raw, .. } => Some(display::safe_display_text(raw)),
            _ => None,
        }
    }
}

impl FromWire for ServerStreamEvent {
    fn from_value(value: Value) -> Result<Self, DecodeError> {
        let Value::Object(fields) = &value else {
            return Err(DecodeError::NotAnObject {
                context: "event".to_owned(),
            });
        };
        let event_type = match fields.get("type") {
            Some(Value::String(event_type)) if !event_type.is_empty() => event_type.clone(),
            _ => return Err(DecodeError::missing("event", "type")),
        };
        Self::decode_known(&event_type, value)
            .unwrap_or_else(|raw| Ok(Self::Unknown { event_type, raw }))
    }
}

impl<'de> Deserialize<'de> for ServerStreamEvent {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::from_value(Value::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

/// Serialises the wire shape: the payload fields plus `type`. An unknown event serialises as sent.
impl Serialize for ServerStreamEvent {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.serialize_payload(serializer)
    }
}

#[cfg(test)]
#[path = "events_tests.rs"]
mod tests;
