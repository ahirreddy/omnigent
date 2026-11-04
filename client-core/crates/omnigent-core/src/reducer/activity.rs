//! Projection of persisted items into rows: the single presentation used for history pages and
//! for live commits (`response.output_item.done`, `session.input.consumed`).
//!
//! Ported from `NativeLab`'s `ConversationItemPresentation` and `ConversationContentPresentation`.
//! Every visible string goes through the protocol crate's safe display, so credentials, private
//! reasoning and embedded bytes never reach a row.

use omnigent_protocol::content::{self, ContentPart};
use omnigent_protocol::display;
use omnigent_protocol::items::{
    CompactionData, ErrorData, FunctionCallData, FunctionCallOutputData, MessageData,
    ReasoningData, ResourceAction, ResourceEventData, RoutingDecisionData, SlashCommandData,
    SlashCommandKind, TerminalCommandData, TerminalCommandKind,
};
use omnigent_protocol::native_tools::{NativeToolItem, NativeToolKind};
use omnigent_protocol::{ConversationItem, ItemData, MessageRole};
use serde_json::Value;

use super::presentation::{SUMMARY_CHARS, TITLE_CHARS, bounded, capitalized, type_title};
use super::state::{
    Activity, ActivityKind, Attachment, AttachmentKind, DetailSection, Row, RowRole,
};

/// Bound of an error message detail.
const MESSAGE_DETAIL_CHARS: usize = 16_000;
/// Bound of an attachment reference.
const REFERENCE_CHARS: usize = 2_000;

/// A persisted item that cannot be shown without inventing meaning.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ProjectionError {
    /// A message whose role this client does not know.
    #[error("message `{item_id}` has unknown role `{role}`")]
    UnknownRole {
        /// The item.
        item_id: String,
        /// The role as sent.
        role: String,
    },
    /// A session whose status this client does not know.
    #[error("session `{session_id}` has unknown status `{status}`")]
    UnknownStatus {
        /// The session.
        session_id: String,
        /// The status as sent.
        status: String,
    },
}

/// The reply an interrupt marker refers to: the last message row, when it is the agent's.
///
/// An interrupt marker ([`ConversationItem::is_interrupt_marker`]) is hidden context, so the
/// interrupt shows as [`Row::interrupted`] on the reply it cut off, as the web client's
/// "Interrupted" indicator does. A turn interrupted before any reply text has nothing to mark.
#[must_use]
pub fn interrupted_reply(rows: &[Row]) -> Option<usize> {
    let at = rows
        .iter()
        .rposition(|row| matches!(row.role, RowRole::User | RowRole::Assistant))?;
    (rows.get(at)?.role == RowRole::Assistant).then_some(at)
}

/// The row for one persisted item, or `None` for hidden context.
///
/// # Errors
///
/// A message with an unknown role.
pub fn project_item(item: &ConversationItem) -> Result<Option<Row>, ProjectionError> {
    let projector = Projector { item };
    Ok(Some(match &item.data {
        ItemData::Message(message) => return projector.message(message),
        ItemData::FunctionCall(call) => projector.function_call(call),
        ItemData::FunctionCallOutput(output) => projector.function_call_output(output),
        ItemData::Error(error) => projector.error(error),
        ItemData::Reasoning(reasoning) => projector.reasoning(reasoning),
        ItemData::Compaction(compaction) => projector.compaction(compaction),
        ItemData::SlashCommand(command) => projector.slash_command(command),
        ItemData::TerminalCommand(command) => projector.terminal_command(command),
        ItemData::RoutingDecision(routing) => projector.routing(routing),
        ItemData::ResourceEvent(resource) => projector.resource(resource),
        ItemData::NativeTool(native) => projector.native_tool(&native.item),
        ItemData::Unknown { item_type, raw } => {
            if raw.get("is_meta") == Some(&Value::Bool(true)) {
                return Ok(None);
            }
            projector.unknown(item_type, raw)
        }
    }))
}

/// Builds detail sections, dropping empty texts and bounding the rest.
fn sections(values: &[(&str, &str, &str, bool)]) -> Vec<DetailSection> {
    values
        .iter()
        .filter(|(_, _, text, _)| !text.is_empty())
        .map(|(id, title, text, code)| {
            DetailSection::new(id, title, bounded(text, display::MAX_DISPLAY_CHARS), *code)
        })
        .collect()
}

struct Projector<'a> {
    item: &'a ConversationItem,
}

impl Projector<'_> {
    fn agent(&self) -> Option<String> {
        match &self.item.data {
            ItemData::Message(data) => data.agent.clone(),
            ItemData::FunctionCall(data) => data.agent.clone(),
            ItemData::Reasoning(data) => data.agent.clone(),
            ItemData::SlashCommand(data) => data.agent.clone(),
            ItemData::RoutingDecision(data) => data.agent.clone(),
            _ => None,
        }
    }

    fn row(&self, role: RowRole, text: String) -> Row {
        let mut row = Row::text(self.item.id.clone(), role, text);
        row.call_id = self.item.data.call_id().map(str::to_owned);
        row.response_id.clone_from(&self.item.response_id);
        row.author.clone_from(&self.item.created_by);
        row.agent = self.agent();
        row.created_at = self.item.created_at;
        row
    }

    fn activity(
        &self,
        kind: ActivityKind,
        title: &str,
        summary: &str,
        status: Option<&str>,
        details: Vec<DetailSection>,
        text: Option<String>,
    ) -> Row {
        let title = bounded(title, TITLE_CHARS);
        let summary = bounded(summary, SUMMARY_CHARS);
        let text = text.unwrap_or_else(|| {
            [title.as_str(), summary.as_str()]
                .iter()
                .filter(|part| !part.is_empty())
                .copied()
                .collect::<Vec<_>>()
                .join("\n")
        });
        let status = status.map(str::to_owned).or_else(|| {
            self.item
                .status
                .as_ref()
                .map(|status| status.as_str().to_owned())
        });
        let mut row = self.row(RowRole::Tool, text);
        row.activity = Some(Activity {
            kind,
            title,
            summary,
            status,
            details,
        });
        row
    }

    fn message(&self, message: &MessageData) -> Result<Option<Row>, ProjectionError> {
        if message.is_hidden_context() {
            return Ok(None);
        }
        let role = match &message.role {
            MessageRole::User => RowRole::User,
            MessageRole::Assistant => RowRole::Assistant,
            MessageRole::Unknown { value } => {
                return Err(ProjectionError::UnknownRole {
                    item_id: self.item.id.clone(),
                    role: value.clone(),
                });
            }
        };
        let text = content::visible_text(&message.content);
        let mut attachments = Vec::new();
        let mut details = Vec::new();
        for (index, part) in message.content.iter().enumerate() {
            match part {
                ContentPart::Attachment(part) => {
                    attachments.push(self.attachment(index, part));
                }
                ContentPart::Unknown { part_type, detail } if !detail.is_empty() => {
                    details.push(DetailSection::new(
                        &format!("content-{index}"),
                        &part_type.replace('_', " "),
                        detail.clone(),
                        true,
                    ));
                }
                ContentPart::Text { .. }
                | ContentPart::Private { .. }
                | ContentPart::Unknown { .. } => {}
            }
        }
        let mut row = self.row(role, text.clone());
        row.attachments = attachments;
        row.interrupted = message.interrupted;
        if !details.is_empty() {
            row.activity = Some(Activity {
                kind: ActivityKind::Unknown,
                title: "Message content".to_owned(),
                summary: bounded(&text, SUMMARY_CHARS),
                status: self
                    .item
                    .status
                    .as_ref()
                    .map(|status| status.as_str().to_owned()),
                details,
            });
        }
        Ok(Some(row))
    }

    fn attachment(&self, index: usize, part: &content::AttachmentPart) -> Attachment {
        let kind = match part.kind {
            content::AttachmentKind::Image => AttachmentKind::Image,
            content::AttachmentKind::File => AttachmentKind::File,
            content::AttachmentKind::Audio => AttachmentKind::Audio,
            content::AttachmentKind::Video => AttachmentKind::Video,
        };
        let title = part
            .filename
            .clone()
            .unwrap_or_else(|| format!("{} attachment", capitalized(kind.as_str())));
        Attachment {
            id: format!("{}-attachment-{index}", self.item.id),
            kind,
            title: bounded(&title, TITLE_CHARS),
            reference: part
                .reference()
                .map(|reference| bounded(reference, REFERENCE_CHARS)),
            mime_type: part
                .mime_type
                .as_deref()
                .map(|mime| bounded(mime, TITLE_CHARS)),
            is_embedded: part.embedded,
        }
    }

    fn function_call(&self, call: &FunctionCallData) -> Row {
        let arguments = call.safe_arguments();
        let name = bounded(&call.name, 160);
        let text = if arguments.is_empty() {
            format!("Tool call: {}", call.name)
        } else {
            format!("Tool call: {}\n{arguments}", call.name)
        };
        self.activity(
            ActivityKind::ToolCall,
            &name,
            &arguments,
            None,
            sections(&[("arguments", "Arguments", &arguments, true)]),
            Some(text),
        )
    }

    fn function_call_output(&self, output: &FunctionCallOutputData) -> Row {
        let text = output.output.safe_text();
        self.activity(
            ActivityKind::ToolResult,
            "Tool result",
            &text,
            None,
            sections(&[("output", "Output", &text, true)]),
            Some(text.clone()),
        )
    }

    fn error(&self, error: &ErrorData) -> Row {
        let message = bounded(&error.message, MESSAGE_DETAIL_CHARS);
        let source = error.source.as_ref().map_or("", |source| source.as_str());
        self.activity(
            ActivityKind::Error,
            "Response error",
            &error.message,
            Some("failed"),
            sections(&[
                ("message", "Error", &message, false),
                ("code", "Code", &error.code, true),
                ("source", "Source", source, false),
            ]),
            Some(format!("Error ({}): {}", error.code, error.message)),
        )
    }

    fn reasoning(&self, reasoning: &ReasoningData) -> Row {
        let summary = reasoning.public_summary();
        let shown = if summary.is_empty() {
            "No public reasoning summary was provided."
        } else {
            &summary
        };
        self.activity(
            ActivityKind::Reasoning,
            "Reasoning summary",
            shown,
            None,
            sections(&[("summary", "Summary", &summary, false)]),
            None,
        )
    }

    fn compaction(&self, compaction: &CompactionData) -> Row {
        let summary = display::safe_display_str(&compaction.summary);
        let shown = if summary.is_empty() {
            "Earlier context was summarized for this session."
        } else {
            &summary
        };
        let tokens = compaction
            .token_count
            .map(|count| count.to_string())
            .unwrap_or_default();
        self.activity(
            ActivityKind::Compaction,
            "Context compacted",
            shown,
            None,
            sections(&[
                ("summary", "Summary", &summary, false),
                (
                    "model",
                    "Model",
                    compaction.model.as_deref().unwrap_or_default(),
                    false,
                ),
                ("tokens", "Summary tokens", &tokens, false),
                (
                    "through",
                    "Through item",
                    compaction.last_item_id.as_deref().unwrap_or_default(),
                    true,
                ),
            ]),
            None,
        )
    }

    fn slash_command(&self, command: &SlashCommandData) -> Row {
        let name = command.name.trim_matches('/');
        let invocation = command.invocation();
        let output = command
            .output
            .as_deref()
            .map(display::safe_display_str)
            .unwrap_or_default();
        let title = if command.kind == SlashCommandKind::Command {
            format!("Command /{name}")
        } else {
            format!("Skill /{name}")
        };
        self.activity(
            ActivityKind::Command,
            &title,
            &invocation,
            None,
            sections(&[
                ("invocation", "Invocation", &invocation, true),
                ("output", "Output", &output, true),
            ]),
            None,
        )
    }

    fn terminal_command(&self, command: &TerminalCommandData) -> Row {
        let safe = |value: &Option<String>| {
            value
                .as_deref()
                .map(display::safe_display_str)
                .unwrap_or_default()
        };
        let input = safe(&command.input);
        let stdout = safe(&command.stdout);
        let stderr = safe(&command.stderr);
        let is_input = command.kind == TerminalCommandKind::Input;
        let summary = if is_input {
            input.clone()
        } else {
            [stdout.as_str(), stderr.as_str()]
                .iter()
                .filter(|part| !part.is_empty())
                .copied()
                .collect::<Vec<_>>()
                .join("\n")
        };
        self.activity(
            ActivityKind::Terminal,
            if is_input {
                "Terminal command"
            } else {
                "Terminal output"
            },
            &summary,
            None,
            sections(&[
                ("input", "Command", &input, true),
                ("stdout", "Standard output", &stdout, true),
                ("stderr", "Standard error", &stderr, true),
            ]),
            None,
        )
    }

    fn routing(&self, routing: &RoutingDecisionData) -> Row {
        let title = if routing.applied {
            format!("Using {}", routing.model)
        } else {
            format!("Would have picked {}", routing.model)
        };
        let rationale = display::safe_display_str(&routing.rationale);
        self.activity(
            ActivityKind::Routing,
            &title,
            &rationale,
            None,
            sections(&[
                ("rationale", "Rationale", &rationale, false),
                (
                    "agent",
                    "Agent",
                    routing.agent.as_deref().unwrap_or_default(),
                    false,
                ),
            ]),
            None,
        )
    }

    fn resource(&self, resource: &ResourceEventData) -> Row {
        let verb = match resource.action() {
            ResourceAction::Created => "created",
            ResourceAction::Deleted => "deleted",
            ResourceAction::Updated => "updated",
        };
        let name = resource
            .resource_name()
            .unwrap_or(resource.resource_id.as_str());
        let detail = resource
            .resource
            .as_ref()
            .map(|fields| display::safe_display_text(&Value::Object(fields.clone())))
            .unwrap_or_default();
        self.activity(
            ActivityKind::Resource,
            &format!("{} {verb}", capitalized(&resource.resource_type)),
            name,
            None,
            sections(&[
                ("event", "Event", &resource.event_type, true),
                ("id", "Resource ID", &resource.resource_id, true),
                ("resource", "Resource", &detail, true),
            ]),
            None,
        )
    }

    fn native_tool(&self, native: &NativeToolItem) -> Row {
        let (title, fallback) = match &native.kind {
            NativeToolKind::WebSearchCall => {
                let opens_page = native
                    .fields
                    .get("action")
                    .and_then(|action| action.get("type"))
                    .and_then(Value::as_str)
                    == Some("open_page");
                let title = if opens_page {
                    "Open web page"
                } else {
                    "Web search"
                };
                (title.to_owned(), "Provider web activity")
            }
            NativeToolKind::FileSearchCall => ("File search".to_owned(), "Search session files"),
            NativeToolKind::CodeInterpreterCall => {
                ("Code interpreter".to_owned(), "Provider code execution")
            }
            NativeToolKind::ComputerCall => {
                ("Computer action".to_owned(), "Provider computer activity")
            }
            NativeToolKind::ImageGenerationCall => {
                ("Image generation".to_owned(), "Generated image output")
            }
            NativeToolKind::McpCall => (
                format!("MCP: {}", native.name().unwrap_or("tool")),
                "Provider tool call",
            ),
            NativeToolKind::McpListTools => {
                ("Available MCP tools".to_owned(), "Provider tool discovery")
            }
            NativeToolKind::Unknown { value } => (type_title(value), "Provider tool activity"),
        };
        let summary = native.safe_summary().unwrap_or_else(|| fallback.to_owned());
        let detail = native.safe_detail();
        let mut row = self.activity(
            ActivityKind::NativeTool,
            &title,
            &summary,
            native.status(),
            sections(&[("provider", "Provider details", &detail, true)]),
            None,
        );
        row.call_id = native.call_id().map(str::to_owned);
        if native.has_generated_image() {
            row.attachments = vec![Attachment {
                id: format!("{}-image", self.item.id),
                kind: AttachmentKind::Image,
                title: "Generated image".to_owned(),
                reference: None,
                mime_type: None,
                is_embedded: true,
            }];
        }
        row
    }

    fn unknown(&self, item_type: &str, raw: &Value) -> Row {
        let details = display::safe_display_text(raw);
        let summary = raw
            .get("message")
            .or_else(|| raw.get("summary"))
            .map_or_else(
                || "Additional session activity".to_owned(),
                display::safe_display_text,
            );
        self.activity(
            ActivityKind::Unknown,
            &type_title(item_type),
            &summary,
            None,
            sections(&[("payload", "Event details", &details, true)]),
            None,
        )
    }
}
