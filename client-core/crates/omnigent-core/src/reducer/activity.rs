//! Projection of persisted items into rows: the single presentation used for history pages and
//! for live commits (`response.output_item.done`, `session.input.consumed`).
//!
//! Ported from `NativeLab`'s `ConversationItemPresentation` and `ConversationContentPresentation`.
//! Every visible string goes through the protocol crate's safe display, so credentials, private
//! reasoning and embedded bytes never reach a row.

use std::borrow::Cow;
use std::collections::BTreeSet;

use omnigent_protocol::content::{self, ContentPart};
use omnigent_protocol::display;
use omnigent_protocol::items::{
    CompactionData, ErrorData, ErrorLevel, FunctionCallData, FunctionCallOutputData, MessageData,
    ReasoningData, ResourceAction, ResourceEventData, RoutingDecisionData, SlashCommandData,
    SlashCommandKind, TerminalCommandData, TerminalCommandKind,
};
use omnigent_protocol::native_tools::{NativeToolItem, NativeToolKind};
use omnigent_protocol::question_reply;
use omnigent_protocol::system_message::{self, SystemMessage, SystemMessageKind};
use omnigent_protocol::{ConversationItem, ItemData, MessageRole};
use serde_json::Value;

use crate::failure_copy::{failure_headline, is_neutral_failure};

use super::markers;
use super::presentation::{SUMMARY_CHARS, TITLE_CHARS, bounded, capitalized, type_title};
use super::reasoning_preview::reasoning_preview;
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

/// Claude Code's tool that ends a sub-agent's turn by handing its final report to the caller.
const SUBAGENT_HANDBACK_TOOL: &str = "SubagentHandback";

/// The report a Claude sub-agent handed back, which is its answer. `None` for any other call, and
/// for a handback whose arguments carry no report text (it stays an ordinary tool row).
fn handback_report(call: &FunctionCallData) -> Option<String> {
    if call.name != SUBAGENT_HANDBACK_TOOL {
        return None;
    }
    // Arguments that aren't a JSON object leave the call as a tool row, as on the web.
    let arguments = serde_json::from_str::<Value>(&call.arguments).ok()?;
    let report = arguments.get("message")?.as_str()?;
    (!report.trim().is_empty()).then(|| report.to_owned())
}

/// Drops the results of sub-agent handbacks shown as answers: such a result only confirms that the
/// report was delivered. Returns whether any row went.
pub fn drop_handback_results(rows: &mut Vec<Row>) -> bool {
    let handbacks: BTreeSet<String> = rows
        .iter()
        .filter(|row| row.is_handback_report())
        .filter_map(|row| row.call_id.clone())
        .collect();
    if handbacks.is_empty() {
        return false;
    }
    let before = rows.len();
    rows.retain(|row| !is_result_of(row, &handbacks));
    rows.len() != before
}

/// Whether `row` is a tool result (or its live output) for one of `calls`.
fn is_result_of(row: &Row, calls: &BTreeSet<String>) -> bool {
    row.activity_kind() == Some(ActivityKind::ToolResult)
        && row
            .call_id
            .as_ref()
            .is_some_and(|call| calls.contains(call))
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
        ItemData::FunctionCall(call) => handback_report(call).map_or_else(
            || projector.function_call(call),
            |report| projector.row(RowRole::Assistant, report),
        ),
        ItemData::FunctionCallOutput(output) => projector.function_call_output(output),
        ItemData::Error(error) => projector.error(error),
        ItemData::Reasoning(reasoning) => projector.reasoning(reasoning),
        ItemData::Compaction(compaction) => projector.compaction(compaction),
        ItemData::SlashCommand(command) => projector.slash_command(command),
        ItemData::TerminalCommand(command) => projector.terminal_command(command),
        ItemData::RoutingDecision(routing) => projector.routing(routing),
        ItemData::ResourceEvent(resource) => return Ok(projector.resource(resource)),
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

    /// A user message the person sent (`created_by` or `user_authored`), not harness context.
    const fn is_person_input(&self, message: &MessageData) -> bool {
        !message.is_meta && (self.item.created_by.is_some() || message.user_authored)
    }

    /// Whether a user message is context that never shows, as the web's `itemToBlock` hides
    /// it: `is_meta`, an interrupt marker (shown on the reply it cut off) and, unless the person
    /// sent it, a legacy continuation summary.
    fn is_hidden_user_context(&self, message: &MessageData) -> bool {
        message.is_meta
            || message.is_interrupt_marker()
            || (!self.is_person_input(message) && message.is_continuation_summary())
    }

    fn message(&self, message: &MessageData) -> Result<Option<Row>, ProjectionError> {
        let role = match &message.role {
            MessageRole::User => RowRole::User,
            MessageRole::Assistant => RowRole::Assistant,
            MessageRole::Unknown { value } => {
                if message.is_meta {
                    return Ok(None);
                }
                return Err(ProjectionError::UnknownRole {
                    item_id: self.item.id.clone(),
                    role: value.clone(),
                });
            }
        };
        if role == RowRole::Assistant {
            return Ok((!message.is_meta).then(|| self.message_row(message, role, None)));
        }
        if !self.is_person_input(message) {
            // Claude's peer and team envelopes are agent context; its task notifications stand
            // for a background task's notice.
            if system_message::is_agent_message_content(&message.content) {
                return Ok(None);
            }
            if let Some(marker) = system_message::task_notification_marker_content(&message.content)
            {
                return Ok(system_message::parse_system_message(&marker)
                    .and_then(|notice| self.system_notice(&notice)));
            }
        }
        if self.is_hidden_user_context(message) {
            return Ok(None);
        }
        let joined = content::visible_text(&message.content);
        let text = system_message::strip_automation_context(&joined);
        let origin = system_message::split_session_message_origin(text);
        let body = origin.map_or(text, |origin| origin.body);
        // A reply to Codex async questions shows its answers, as the web's `userMessageBody`.
        let replies = question_reply::parse_question_replies(body).unwrap_or_default();
        let body = if replies.is_empty() {
            Cow::Borrowed(body)
        } else {
            Cow::Owned(question_reply::question_reply_text(&replies))
        };
        // Another session's message keeps its sender; attachments are always the person's own.
        if origin.is_none() && message.attachments().next().is_none() {
            let shown = system_message::without_attached_markers(&body);
            if let Some(notice) = system_message::parse_system_message(&shown) {
                return Ok(self.system_notice(&notice));
            }
        }
        let mut row = self.message_row(message, role, Some(&body));
        row.origin_session_id = origin.map(|origin| origin.source_id.to_owned());
        row.question_replies = replies;
        Ok(Some(row))
    }

    /// The row of a `[System: …]` notice: a muted marker. A sub-agent's wake and a resumed
    /// turn's prompt are control traffic the web never shows, and an interrupt shows on the
    /// reply it cut off.
    fn system_notice(&self, notice: &SystemMessage) -> Option<Row> {
        if matches!(
            notice.kind,
            SystemMessageKind::SubagentWake
                | SystemMessageKind::SessionResumed
                | SystemMessageKind::Interrupted
        ) {
            return None;
        }
        let body = bounded(&notice.body, display::MAX_DISPLAY_CHARS);
        Some(self.activity(
            ActivityKind::SystemNotice,
            &notice.label,
            &body,
            Some(notice.kind.as_str()),
            sections(&[("body", "Details", &body, false)]),
            Some(format!("System: {}", notice.label)),
        ))
    }

    /// A message row: `text` (the message's visible text when `None`), its attachments and the
    /// content this client does not know.
    fn message_row(&self, message: &MessageData, role: RowRole, text: Option<&str>) -> Row {
        let text = text.map_or_else(|| content::visible_text(&message.content), str::to_owned);
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
        row
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
        let is_info = error.level == Some(ErrorLevel::Info);
        let headline = failure_headline(error.title.as_deref(), &error.code, is_info);
        // An informational notice or a spent budget reads neutral, not as a failure.
        let status = if is_info || is_neutral_failure(&error.code) {
            "info"
        } else {
            "failed"
        };
        self.activity(
            ActivityKind::Error,
            &headline,
            &error.message,
            Some(status),
            sections(&[
                ("message", "Error", &message, false),
                (
                    "cause",
                    "Cause",
                    error.cause.as_deref().unwrap_or(""),
                    false,
                ),
                (
                    "remediation",
                    "Next step",
                    error.remediation.as_deref().unwrap_or(""),
                    true,
                ),
                ("code", "Code", &error.code, true),
                ("source", "Source", source, false),
            ]),
            Some(format!("Error ({}): {}", error.code, error.message)),
        )
    }

    /// A settled thought. Its summary is the first prose line its header previews; its whole
    /// text is the `summary` detail.
    fn reasoning(&self, reasoning: &ReasoningData) -> Row {
        let summary = reasoning.public_summary();
        let has_text = !summary.trim().is_empty();
        let shown = if has_text {
            reasoning_preview(&summary)
        } else {
            "No public reasoning summary was provided.".to_owned()
        };
        let full = if has_text { summary.as_str() } else { &shown };
        self.activity(
            ActivityKind::Reasoning,
            "Reasoning summary",
            &shown,
            None,
            sections(&[(
                "summary",
                "Summary",
                if has_text { &summary } else { "" },
                false,
            )]),
            Some(format!(
                "Reasoning summary\n{}",
                bounded(full, SUMMARY_CHARS)
            )),
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
            "Conversation compacted",
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

    /// A resource receipt. Sub-agent and task markers show as markers; the journal's other
    /// receipts (checkpoints) never show, as on the web.
    fn resource(&self, resource: &ResourceEventData) -> Option<Row> {
        if let Some(marker) = markers::marker(resource) {
            return Some(self.activity(
                marker.kind,
                &marker.title,
                &marker.summary,
                Some(marker.status.as_str()),
                marker.details,
                Some(marker.text),
            ));
        }
        if resource.resource_type == markers::JOURNAL_RESOURCE {
            return None;
        }
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
        Some(self.activity(
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
        ))
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
