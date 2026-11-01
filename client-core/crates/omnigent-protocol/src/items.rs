//! Persistent conversation item models (`ItemData` union).
//!
//! Ground truth: `ConversationItem`, `ItemData` and the `*Data` models in
//! `omnigent/entities/conversation.py`. Items arrive in two shapes and both decode:
//!
//! - flat (`/items` rows, `response.output_item.done`): the data fields sit beside `id`, `type`,
//!   `status`, `response_id`, `created_at` and `created_by` (`ConversationItem.to_api_dict`);
//! - nested (`SessionResponse.items`, `session.input.consumed`): the data fields are under `data`.
//!
//! An unknown `type` decodes to [`ItemData::Unknown`]. A known type with a broken shape is an
//! error, never a silent fallback. Private reasoning (`content`, `encrypted_content`) and
//! `compacted_messages` are not kept.

use serde::ser::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value};

use crate::content::{self, AttachmentPart, ContentPart};
use crate::display;
use crate::error::{DecodeError, FromWire, decode_as};
use crate::field::{is_false, null_as_default};
use crate::native_tools::{NativeToolItem, NativeToolKind};
use crate::wire_enum::wire_enum;

/// Item types the server's agent loop does not send to the model (`NON_CONTENT_ITEM_TYPES`).
pub const CONTEXT_FREE_ITEM_TYPES: &[&str] = &[
    "compaction",
    "error",
    "resource_event",
    "routing_decision",
    "slash_command",
    "terminal_command",
];

/// Inner provider types that older payloads (and the web client) accept as top-level item types.
/// They decode as [`ItemData::NativeTool`] and serialise back in the `native_tool` wrapper.
pub const BARE_NATIVE_TOOL_TYPES: &[&str] = &[
    "web_search_call",
    "file_search_call",
    "code_interpreter_call",
    "computer_call",
    "image_generation_call",
    "mcp_call",
    "mcp_list_tools",
];

wire_enum! {
    /// `ConversationItem.status`.
    pub enum ItemStatus {
        /// `completed`.
        Completed = "completed",
        /// `in_progress`.
        InProgress = "in_progress",
        /// `incomplete`.
        Incomplete = "incomplete",
        /// `failed`.
        Failed = "failed",
    }
}

wire_enum! {
    /// `MessageData.role`.
    pub enum MessageRole {
        /// `user`.
        User = "user",
        /// `assistant`.
        Assistant = "assistant",
    }
}

wire_enum! {
    /// Where an error came from (`ErrorData.source`, `response.error`, `response.failed`).
    pub enum ErrorSource {
        /// `llm`.
        Llm = "llm",
        /// `execution`.
        Execution = "execution",
        /// `tool`.
        Tool = "tool",
        /// `harness`.
        Harness = "harness",
    }
}

wire_enum! {
    /// `ErrorData.level`.
    pub enum ErrorLevel {
        /// `error`: a failure banner.
        Error = "error",
        /// `info`: a neutral banner.
        Info = "info",
    }
}

wire_enum! {
    /// `RoutingDecisionData.scope`.
    pub enum RoutingScope {
        /// `session`.
        Session = "session",
        /// `turn`.
        Turn = "turn",
        /// `child_session`.
        ChildSession = "child_session",
        /// `native_subagent`.
        NativeSubagent = "native_subagent",
    }
}

wire_enum! {
    /// `SlashCommandData.kind`.
    pub enum SlashCommandKind {
        /// `skill` (the server default).
        Skill = "skill",
        /// `command`.
        Command = "command",
    }
}

wire_enum! {
    /// `TerminalCommandData.kind`.
    pub enum TerminalCommandKind {
        /// `input`: the command text.
        Input = "input",
        /// `output`: captured stdout and stderr.
        Output = "output",
    }
}

/// One persisted conversation item.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationItem {
    /// Store-assigned item id. Never empty.
    pub id: String,
    /// Item status.
    pub status: Option<ItemStatus>,
    /// The turn or response the item belongs to.
    pub response_id: Option<String>,
    /// Unix seconds.
    pub created_at: Option<i64>,
    /// The human author, present only for human-authored items.
    pub created_by: Option<String>,
    /// The typed payload.
    pub data: ItemData,
}

/// The typed payload of an item, by its `type`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ItemData {
    /// `message`.
    Message(MessageData),
    /// `function_call`.
    FunctionCall(FunctionCallData),
    /// `function_call_output`.
    FunctionCallOutput(FunctionCallOutputData),
    /// `error`.
    Error(ErrorData),
    /// `reasoning`.
    Reasoning(ReasoningData),
    /// `compaction`.
    Compaction(CompactionData),
    /// `native_tool` (and the bare provider types in [`BARE_NATIVE_TOOL_TYPES`]).
    NativeTool(NativeToolData),
    /// `resource_event`.
    ResourceEvent(ResourceEventData),
    /// `routing_decision`.
    RoutingDecision(RoutingDecisionData),
    /// `slash_command`.
    SlashCommand(SlashCommandData),
    /// `terminal_command`.
    TerminalCommand(TerminalCommandData),
    /// A type this client does not know. Show it through [`display::safe_display_text`] only.
    Unknown {
        /// The item `type`.
        item_type: String,
        /// The whole item as sent.
        raw: Value,
    },
}

/// `MessageData`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageData {
    /// Who wrote the message.
    pub role: MessageRole,
    /// Content blocks. A bare string `content` becomes one `text` block.
    #[serde(deserialize_with = "content::content_parts")]
    pub content: Vec<ContentPart>,
    /// The agent that wrote an assistant message (wire key `model`).
    #[serde(
        default,
        rename = "model",
        alias = "agent",
        skip_serializing_if = "Option::is_none"
    )]
    pub agent: Option<String>,
    /// Durable context that must never be shown as a transcript message.
    #[serde(
        default,
        deserialize_with = "null_as_default",
        skip_serializing_if = "is_false"
    )]
    pub is_meta: bool,
    /// Confirmed user input.
    #[serde(
        default,
        deserialize_with = "null_as_default",
        skip_serializing_if = "is_false"
    )]
    pub user_authored: bool,
    /// The assistant message was cut off by an interrupt.
    #[serde(
        default,
        deserialize_with = "null_as_default",
        skip_serializing_if = "is_false"
    )]
    pub interrupted: bool,
    /// Native task id of an explicitly completed child.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subagent_return_id: Option<String>,
    /// The native live-preview stream this message finalises.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stream_message_id: Option<String>,
    /// Harness phase label, for example Codex `commentary`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<String>,
    /// Startup options of a durable initial input.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub startup_options: Option<Value>,
}

const CONTINUED_SESSION_PREFIX: &str =
    "This session is being continued from a previous conversation";

/// First line of the user-role marker the runner appends after an interrupted turn
/// (`_CANCELLATION_MARKER_TEXT` in `omnigent/runner/session_history.py`). The model reads it; the
/// person never typed it.
const RUNNER_INTERRUPT_HEADER: &str = "[System: interrupted]";

/// Claude Code's own interrupt records (Escape), mirrored into the transcript as user messages
/// (`_CLAUDE_INTERRUPT_RECORD_RE` in `omnigent/server/routes/_sessions/helpers.py`).
const NATIVE_INTERRUPT_RECORDS: [&str; 2] = [
    "[Request interrupted by user]",
    "[Request interrupted by user for tool use]",
];

impl MessageData {
    /// Text and refusal blocks joined with newlines.
    #[must_use]
    pub fn visible_text(&self) -> String {
        content::visible_text(&self.content)
    }

    /// Attachment descriptors, in order.
    pub fn attachments(&self) -> impl Iterator<Item = &AttachmentPart> {
        self.content.iter().filter_map(|part| match part {
            ContentPart::Attachment(attachment) => Some(attachment),
            _ => None,
        })
    }

    /// True when the message is hidden harness context: `is_meta`, a user message that is a
    /// whole legacy continuation or task notification, or an interrupt marker
    /// ([`MessageData::is_interrupt_marker`]). Text that merely mentions the markers stays
    /// visible.
    #[must_use]
    pub fn is_hidden_context(&self) -> bool {
        self.is_meta
            || (self.role == MessageRole::User
                && self
                    .content
                    .iter()
                    .filter_map(ContentPart::text)
                    .any(is_legacy_context))
            || self.is_interrupt_marker()
    }

    /// True for the user-role record of an interrupt rather than something the person typed:
    /// the runner's `[System: interrupted]` marker, or Claude Code's
    /// `[Request interrupted by user]` (and `... for tool use`) record.
    ///
    /// Matches the web client's `parseSystemMessage`/`isSystemUserContent`: the joined text's
    /// first line must be exactly one of those headers, and a message with attachments is
    /// always the person's own. Clients show the interrupt on the reply it cut off, not as a
    /// user bubble.
    #[must_use]
    pub fn is_interrupt_marker(&self) -> bool {
        if self.role != MessageRole::User || self.attachments().next().is_some() {
            return false;
        }
        let text: String = self.content.iter().filter_map(ContentPart::text).collect();
        let first_line = text.split('\n').next().unwrap_or_default();
        first_line == RUNNER_INTERRUPT_HEADER || NATIVE_INTERRUPT_RECORDS.contains(&first_line)
    }
}

fn is_legacy_context(text: &str) -> bool {
    if text.starts_with(CONTINUED_SESSION_PREFIX) {
        return true;
    }
    let text = text.trim();
    text.starts_with("<task-notification>")
        && text.contains("<task-id>")
        && text.contains("</task-notification>")
}

/// `FunctionCallData`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FunctionCallData {
    /// The calling agent (wire key `model`).
    #[serde(
        default,
        rename = "model",
        alias = "agent",
        skip_serializing_if = "Option::is_none"
    )]
    pub agent: Option<String>,
    /// Tool name.
    pub name: String,
    /// Arguments as sent: usually a JSON string. Display through
    /// [`FunctionCallData::safe_arguments`].
    pub arguments: String,
    /// Call id shared with the output.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
    /// Tool namespace.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub namespace: Option<String>,
}

impl FunctionCallData {
    /// The arguments, parsed when JSON, sanitised and bounded.
    #[must_use]
    pub fn safe_arguments(&self) -> String {
        display::safe_display_str(&self.arguments)
    }
}

/// A tool result: a string on the current server; older and provider items may send blocks.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ToolOutput {
    /// A string result (often JSON).
    Text(String),
    /// Any other JSON result.
    Structured(Value),
}

impl ToolOutput {
    /// The result, parsed when JSON, sanitised and bounded.
    #[must_use]
    pub fn safe_text(&self) -> String {
        match self {
            Self::Text(text) => display::safe_display_str(text),
            Self::Structured(value) => display::safe_display_text(value),
        }
    }
}

/// `FunctionCallOutputData`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FunctionCallOutputData {
    /// Call id shared with the call.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
    /// The result.
    pub output: ToolOutput,
    /// Native task id of an explicitly completed child.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subagent_return_id: Option<String>,
}

/// `ErrorData`: an operator-visible failure. `code` and `message` are never blank.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorData {
    /// Where the error came from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<ErrorSource>,
    /// Stable classifier, for example `runner_failed_to_start`.
    pub code: String,
    /// Human-readable message.
    pub message: String,
    /// Rendering level.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub level: Option<ErrorLevel>,
    /// Short headline.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Why it failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cause: Option<String>,
    /// A concrete next step.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remediation: Option<String>,
}

/// One block of a reasoning `summary`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReasoningSummaryPart {
    /// `summary_text`: public summary text.
    SummaryText {
        /// The summary text.
        text: String,
    },
    /// Any other block. Only its type is kept.
    Other {
        /// The block type.
        part_type: String,
    },
}

/// `ReasoningData`. Only the public summary is kept; raw and encrypted reasoning are dropped.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReasoningData {
    /// The reasoning agent (wire key `model`).
    #[serde(
        default,
        rename = "model",
        alias = "agent",
        skip_serializing_if = "Option::is_none"
    )]
    pub agent: Option<String>,
    /// Summary blocks.
    #[serde(default, deserialize_with = "null_as_default")]
    pub summary: Vec<ReasoningSummaryPart>,
}

impl ReasoningData {
    /// The `summary_text` blocks joined with blank lines, bounded; empty when none was given.
    #[must_use]
    pub fn public_summary(&self) -> String {
        let parts: Vec<String> = self
            .summary
            .iter()
            .take(display::MAX_ENTRIES)
            .filter_map(|part| match part {
                ReasoningSummaryPart::SummaryText { text } => {
                    Some(display::bounded(text, display::MAX_STRING_CHARS))
                }
                ReasoningSummaryPart::Other { .. } => None,
            })
            .collect();
        display::bounded(&parts.join("\n\n"), display::MAX_DISPLAY_CHARS)
    }
}

/// A compaction window id: an integer or a string.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum CompactionWindowId {
    /// Integer id.
    Number(i64),
    /// String id.
    Text(String),
}

/// `CompactionData`. `compacted_messages` (the replaced history) is not kept.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompactionData {
    /// The summary that replaces earlier context.
    pub summary: String,
    /// The last item (inclusive) the summary covers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_item_id: Option<String>,
    /// The summarising model.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Approximate summary token count.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_count: Option<u64>,
    /// Vendor compaction window id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_id: Option<CompactionWindowId>,
}

/// `NativeToolData`: a provider tool item wrapped by the server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct NativeToolData {
    /// The inner provider item.
    pub item: NativeToolItem,
}

/// What a resource receipt records.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ResourceAction {
    /// `*.created`.
    Created,
    /// `*.deleted`.
    Deleted,
    /// Any other event.
    Updated,
}

/// `ResourceEventData`: a durable receipt of a session resource lifecycle event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceEventData {
    /// The SSE event type, for example `session.resource.created`.
    pub event_type: String,
    /// The resource id.
    pub resource_id: String,
    /// The resource kind, for example `terminal`.
    pub resource_type: String,
    /// The full resource for `created`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource: Option<Map<String, Value>>,
}

impl ResourceEventData {
    /// Created, deleted or updated, from the event type's suffix.
    #[must_use]
    pub fn action(&self) -> ResourceAction {
        if self.event_type.ends_with(".deleted") {
            ResourceAction::Deleted
        } else if self.event_type.ends_with(".created") {
            ResourceAction::Created
        } else {
            ResourceAction::Updated
        }
    }

    /// The resource's `name`, `path` or `title`, when the receipt carries the resource.
    #[must_use]
    pub fn resource_name(&self) -> Option<&str> {
        let resource = self.resource.as_ref()?;
        ["name", "path", "title"]
            .iter()
            .find_map(|key| resource.get(*key).and_then(Value::as_str))
    }
}

/// `RoutingDecisionData`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoutingDecisionData {
    /// The model the router chose.
    pub model: String,
    /// True when the model actually ran; false for a suggestion only.
    pub applied: bool,
    /// The router's explanation.
    #[serde(default, deserialize_with = "null_as_default")]
    pub rationale: String,
    /// The agent the decision applies to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    /// The harness the decision applies to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    /// What the decision governs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<RoutingScope>,
    /// Router decision id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decision_id: Option<String>,
    /// The router's pick before resolution.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raw_model: Option<String>,
    /// The model the spawning agent asked for.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attempted_override: Option<String>,
    /// Which router decided.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub router_source: Option<String>,
    /// The task or spawn the decision was for.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_description: Option<String>,
}

const fn default_slash_kind() -> SlashCommandKind {
    SlashCommandKind::Skill
}

/// `SlashCommandData`: a receipt of a slash command or skill invocation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SlashCommandData {
    /// The harness or agent (wire key `model`).
    #[serde(
        default,
        rename = "model",
        alias = "agent",
        skip_serializing_if = "Option::is_none"
    )]
    pub agent: Option<String>,
    /// Skill or command; `skill` when absent.
    #[serde(default = "default_slash_kind")]
    pub kind: SlashCommandKind,
    /// Command name, normally without the leading `/`.
    pub name: String,
    /// Raw arguments; empty when none.
    #[serde(default, deserialize_with = "null_as_default")]
    pub arguments: String,
    /// Command output.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    /// Startup options of a durable initial input.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub startup_options: Option<Value>,
}

impl SlashCommandData {
    /// `/<name> <arguments>`, with the arguments sanitised.
    #[must_use]
    pub fn invocation(&self) -> String {
        let name = self.name.trim_matches('/');
        let arguments = display::safe_display_str(&self.arguments);
        if arguments.is_empty() {
            format!("/{name}")
        } else {
            format!("/{name} {arguments}")
        }
    }
}

/// `TerminalCommandData`: a shell-mode command or its output.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalCommandData {
    /// Input or output.
    pub kind: TerminalCommandKind,
    /// The command text (`input`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<String>,
    /// Captured stdout (`output`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stdout: Option<String>,
    /// Captured stderr (`output`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stderr: Option<String>,
}

impl ItemData {
    /// The wire `type`. Bare provider items report `native_tool`.
    #[must_use]
    pub fn wire_type(&self) -> &str {
        match self {
            Self::Message(_) => "message",
            Self::FunctionCall(_) => "function_call",
            Self::FunctionCallOutput(_) => "function_call_output",
            Self::Error(_) => "error",
            Self::Reasoning(_) => "reasoning",
            Self::Compaction(_) => "compaction",
            Self::NativeTool(_) => "native_tool",
            Self::ResourceEvent(_) => "resource_event",
            Self::RoutingDecision(_) => "routing_decision",
            Self::SlashCommand(_) => "slash_command",
            Self::TerminalCommand(_) => "terminal_command",
            Self::Unknown { item_type, .. } => item_type,
        }
    }

    /// True for types the server keeps out of model context (see [`CONTEXT_FREE_ITEM_TYPES`]).
    #[must_use]
    pub fn is_context_free(&self) -> bool {
        CONTEXT_FREE_ITEM_TYPES.contains(&self.wire_type())
    }

    /// The call id of a function call, its output, or a provider tool call.
    #[must_use]
    pub fn call_id(&self) -> Option<&str> {
        match self {
            Self::FunctionCall(data) => data.call_id.as_deref(),
            Self::FunctionCallOutput(data) => data.call_id.as_deref(),
            Self::NativeTool(data) => data.item.call_id(),
            _ => None,
        }
    }

    fn decode(item_type: &str, payload: Map<String, Value>) -> Result<Self, DecodeError> {
        let context = || format!("item `{item_type}`");
        let value = Value::Object(payload);
        Ok(match item_type {
            "message" => Self::Message(decode_as(value, context)?),
            "function_call" => Self::FunctionCall(decode_as(value, context)?),
            "function_call_output" => Self::FunctionCallOutput(decode_as(value, context)?),
            "error" => Self::Error(validated_error(decode_as(value, context)?)?),
            "reasoning" => Self::Reasoning(decode_as(value, context)?),
            "compaction" => Self::Compaction(decode_as(value, context)?),
            "native_tool" => Self::NativeTool(native_tool_wrapper(value)?),
            "resource_event" => Self::ResourceEvent(decode_as(value, context)?),
            "routing_decision" => Self::RoutingDecision(decode_as(value, context)?),
            "slash_command" => Self::SlashCommand(decode_as(value, context)?),
            "terminal_command" => Self::TerminalCommand(decode_as(value, context)?),
            bare => {
                let Value::Object(mut fields) = value else {
                    return Err(DecodeError::NotAnObject { context: context() });
                };
                fields
                    .entry("type")
                    .or_insert_with(|| Value::String(bare.to_owned()));
                Self::NativeTool(NativeToolData {
                    item: NativeToolItem::from_fields(fields)?,
                })
            }
        })
    }
}

fn is_known_item_type(item_type: &str) -> bool {
    matches!(
        item_type,
        "message"
            | "function_call"
            | "function_call_output"
            | "error"
            | "reasoning"
            | "compaction"
            | "native_tool"
            | "resource_event"
            | "routing_decision"
            | "slash_command"
            | "terminal_command"
    ) || BARE_NATIVE_TOOL_TYPES.contains(&item_type)
}

fn validated_error(data: ErrorData) -> Result<ErrorData, DecodeError> {
    for (field, value) in [("code", &data.code), ("message", &data.message)] {
        if value.trim().is_empty() {
            return Err(DecodeError::missing("item `error`", field));
        }
    }
    Ok(data)
}

fn native_tool_wrapper(value: Value) -> Result<NativeToolData, DecodeError> {
    match value {
        Value::Object(mut fields) => match fields.remove("item") {
            Some(Value::Object(item)) => Ok(NativeToolData {
                item: NativeToolItem::from_fields(item)?,
            }),
            _ => Err(DecodeError::missing("item `native_tool`", "item")),
        },
        _ => Err(DecodeError::NotAnObject {
            context: "item `native_tool`".to_owned(),
        }),
    }
}

impl ConversationItem {
    /// The item's wire type.
    #[must_use]
    pub fn item_type(&self) -> &str {
        self.data.wire_type()
    }

    /// True for a message that is hidden harness context (see [`MessageData::is_hidden_context`]).
    #[must_use]
    pub fn is_hidden_context(&self) -> bool {
        matches!(&self.data, ItemData::Message(message) if message.is_hidden_context())
    }

    /// True for an interrupt marker message (see [`MessageData::is_interrupt_marker`]).
    #[must_use]
    pub fn is_interrupt_marker(&self) -> bool {
        matches!(&self.data, ItemData::Message(message) if message.is_interrupt_marker())
    }

    /// The native tool kind, for a provider tool item.
    #[must_use]
    pub const fn native_tool_kind(&self) -> Option<&NativeToolKind> {
        match &self.data {
            ItemData::NativeTool(data) => Some(&data.item.kind),
            _ => None,
        }
    }

    /// Builds an item from the nested `{item_id, type, data}` triple of `session.input.consumed`.
    ///
    /// # Errors
    ///
    /// As [`FromWire::from_value`].
    pub fn from_parts(
        id: &str,
        item_type: &str,
        data: Map<String, Value>,
        created_by: Option<&str>,
    ) -> Result<Self, DecodeError> {
        let mut fields = Map::new();
        fields.insert("id".to_owned(), Value::String(id.to_owned()));
        fields.insert("type".to_owned(), Value::String(item_type.to_owned()));
        fields.insert("data".to_owned(), Value::Object(data));
        if let Some(created_by) = created_by {
            fields.insert(
                "created_by".to_owned(),
                Value::String(created_by.to_owned()),
            );
        }
        Self::from_value(Value::Object(fields))
    }
}

/// A non-empty string field.
pub(crate) fn required_string(
    fields: &Map<String, Value>,
    key: &str,
    context: &str,
) -> Result<String, DecodeError> {
    match fields.get(key) {
        Some(Value::String(value)) if !value.is_empty() => Ok(value.clone()),
        _ => Err(DecodeError::missing(context, key)),
    }
}

fn optional<T: serde::de::DeserializeOwned>(
    fields: &Map<String, Value>,
    key: &str,
    context: &str,
) -> Result<Option<T>, DecodeError> {
    match fields.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => serde_json::from_value(value.clone())
            .map(Some)
            .map_err(|error| DecodeError::Invalid {
                context: format!("{context} `{key}`"),
                message: error.to_string(),
            }),
    }
}

impl FromWire for ConversationItem {
    fn from_value(value: Value) -> Result<Self, DecodeError> {
        let Value::Object(mut fields) = value else {
            return Err(DecodeError::NotAnObject {
                context: "item".to_owned(),
            });
        };
        let id = required_string(&fields, "id", "item")?;
        let item_type = required_string(&fields, "type", "item")?;
        let context = format!("item `{item_type}`");
        let status = optional(&fields, "status", &context)?;
        let response_id = optional(&fields, "response_id", &context)?;
        let created_at = optional(&fields, "created_at", &context)?;
        let created_by = optional(&fields, "created_by", &context)?;
        let data = if is_known_item_type(&item_type) {
            let payload = match fields.remove("data") {
                Some(Value::Object(nested)) => nested,
                Some(other) => {
                    fields.insert("data".to_owned(), other);
                    fields
                }
                None => fields,
            };
            ItemData::decode(&item_type, payload)?
        } else {
            ItemData::Unknown {
                item_type,
                raw: Value::Object(fields),
            }
        };
        Ok(Self {
            id,
            status,
            response_id,
            created_at,
            created_by,
            data,
        })
    }
}

impl<'de> Deserialize<'de> for ConversationItem {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::from_value(Value::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

/// Serialises the flat (`to_api_dict`) shape. An unknown item serialises as sent.
impl Serialize for ConversationItem {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let data = match &self.data {
            ItemData::Unknown { raw, .. } => return raw.serialize(serializer),
            ItemData::Message(data) => serde_json::to_value(data),
            ItemData::FunctionCall(data) => serde_json::to_value(data),
            ItemData::FunctionCallOutput(data) => serde_json::to_value(data),
            ItemData::Error(data) => serde_json::to_value(data),
            ItemData::Reasoning(data) => serde_json::to_value(data),
            ItemData::Compaction(data) => serde_json::to_value(data),
            ItemData::NativeTool(data) => serde_json::to_value(data),
            ItemData::ResourceEvent(data) => serde_json::to_value(data),
            ItemData::RoutingDecision(data) => serde_json::to_value(data),
            ItemData::SlashCommand(data) => serde_json::to_value(data),
            ItemData::TerminalCommand(data) => serde_json::to_value(data),
        }
        .map_err(S::Error::custom)?;
        let Value::Object(data) = data else {
            return Err(S::Error::custom("item data must serialise as an object"));
        };
        let mut fields = Map::new();
        fields.insert("id".to_owned(), Value::String(self.id.clone()));
        fields.insert(
            "type".to_owned(),
            Value::String(self.item_type().to_owned()),
        );
        let envelope = [
            (
                "status",
                self.status.as_ref().map(|s| s.as_str().to_owned()),
            ),
            ("response_id", self.response_id.clone()),
            ("created_by", self.created_by.clone()),
        ];
        for (key, value) in envelope {
            if let Some(value) = value {
                fields.insert(key.to_owned(), Value::String(value));
            }
        }
        if let Some(created_at) = self.created_at {
            fields.insert("created_at".to_owned(), Value::from(created_at));
        }
        fields.extend(data);
        fields.serialize(serializer)
    }
}

impl Serialize for ReasoningSummaryPart {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut fields = Map::new();
        match self {
            Self::SummaryText { text } => {
                fields.insert("type".to_owned(), Value::String("summary_text".to_owned()));
                fields.insert("text".to_owned(), Value::String(text.clone()));
            }
            Self::Other { part_type } => {
                fields.insert("type".to_owned(), Value::String(part_type.clone()));
            }
        }
        fields.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for ReasoningSummaryPart {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        use serde::de::Error;
        let Value::Object(fields) = Value::deserialize(deserializer)? else {
            return Err(D::Error::custom("reasoning summary block is not an object"));
        };
        let Some(Value::String(part_type)) = fields.get("type") else {
            return Err(D::Error::custom("reasoning summary block has no type"));
        };
        if part_type != "summary_text" {
            return Ok(Self::Other {
                part_type: part_type.clone(),
            });
        }
        match fields.get("text") {
            Some(Value::String(text)) => Ok(Self::SummaryText { text: text.clone() }),
            _ => Err(D::Error::custom("summary_text block has no text")),
        }
    }
}

#[cfg(test)]
#[path = "items_tests.rs"]
mod tests;
