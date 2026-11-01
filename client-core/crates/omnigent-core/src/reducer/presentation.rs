//! Presentation helpers: bounded display text, session sections and configuration labels.
//!
//! Ported from `NativeLab`'s `SessionEventState.sections`, `String.boundedDisplay`,
//! `SessionConfiguration.modelLabel`/`effortLabel` and the reducer's stable fingerprints.

use omnigent_protocol::display;
use serde_json::{Map, Value};

use super::state::{
    ChangedFiles, DetailSection, ReportedValue, Row, SessionEventState, SessionSettings,
};

/// Default bound of an activity summary.
pub(super) const SUMMARY_CHARS: usize = 320;
/// Bound of an activity title.
pub(super) const TITLE_CHARS: usize = 200;
/// Bound of one session-section detail.
pub(super) const SECTION_DETAIL_CHARS: usize = 16_384;
/// Rows shown at most per session-section list.
pub(super) const SECTION_ENTRIES: usize = 500;

/// One block of the session activity surface (status, usage, plan, resources, children...).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct EventSection {
    /// Stable id, for example `usage` or `child-<id>`.
    pub id: String,
    /// Heading.
    pub title: String,
    /// One line.
    pub summary: String,
    /// Detail blocks.
    pub details: Vec<DetailSection>,
    /// A session the section links to (a child, or the superseding session).
    pub session_id: Option<String>,
}

impl EventSection {
    fn new(id: &str, title: &str, summary: impl Into<String>) -> Self {
        Self {
            id: id.to_owned(),
            title: title.to_owned(),
            summary: summary.into(),
            details: Vec::new(),
            session_id: None,
        }
    }

    fn with_details(mut self, details: Vec<DetailSection>) -> Self {
        self.details = details;
        self
    }
}

/// Cuts `text` to `limit` characters with a truncation marker.
#[must_use]
pub(super) fn bounded(text: &str, limit: usize) -> String {
    display::bounded(text, limit)
}

/// The first `limit` characters of `text`, without a marker.
#[must_use]
pub(super) fn prefix_chars(text: &str, limit: usize) -> String {
    text.chars().take(limit).collect()
}

/// Foundation's `String.capitalized`: the first letter of each word upper-cased, the rest lower.
#[must_use]
pub fn capitalized(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut at_word_start = true;
    for character in text.chars() {
        if at_word_start {
            out.extend(character.to_uppercase());
        } else {
            out.extend(character.to_lowercase());
        }
        at_word_start = character.is_whitespace();
    }
    out
}

/// A type name for display: underscores become spaces, words are capitalised.
#[must_use]
pub(super) fn type_title(item_type: &str) -> String {
    capitalized(&item_type.replace('_', " "))
}

/// 64-bit FNV-1a of the UTF-8 bytes: stable ids for event rows.
#[must_use]
pub fn fingerprint(text: &str) -> u64 {
    text.bytes()
        .fold(14_695_981_039_346_656_037_u64, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(1_099_511_628_211)
        })
}

/// Formats a number the way Swift's `"\(double)"` does for the values the stream sends.
#[must_use]
pub(super) fn swift_number(value: f64) -> String {
    if value.is_finite() && value.fract() == 0.0 {
        format!("{value:.1}")
    } else {
        format!("{value}")
    }
}

/// Everything a row shows, joined: text, activity title and summary, and detail texts.
#[must_use]
pub fn display_text(row: &Row) -> String {
    let mut parts = vec![row.text.clone()];
    if let Some(activity) = &row.activity {
        parts.push(activity.title.clone());
        parts.push(activity.summary.clone());
        parts.extend(activity.details.iter().map(|detail| detail.text.clone()));
    } else {
        parts.push(String::new());
        parts.push(String::new());
    }
    parts.join("\n")
}

/// The model label of a configuration: smart routing, a known option title, the raw value, or
/// whether the harness default applies.
#[must_use]
pub fn model_label(settings: &SessionSettings) -> String {
    if settings.routing_mode.as_deref() == Some("on") {
        return "Smart routing".to_owned();
    }
    let effective = settings
        .model_override
        .value()
        .or(settings.base_model.as_deref());
    let Some(value) = effective else {
        return if settings.model_override.is_reported() {
            "Harness default".to_owned()
        } else {
            "Model not reported".to_owned()
        };
    };
    settings
        .model_options
        .iter()
        .find(|option| option.id == value || option.model.as_deref() == Some(value))
        .map_or_else(
            || value.to_owned(),
            |option| {
                option
                    .display_name
                    .clone()
                    .or_else(|| option.model.clone())
                    .unwrap_or_else(|| option.id.clone())
            },
        )
}

/// The reasoning-effort label of a configuration.
#[must_use]
pub fn effort_label(settings: &SessionSettings) -> String {
    match &settings.reasoning_effort {
        ReportedValue::Value { value } => capitalized(value),
        ReportedValue::HarnessDefault => "Harness default".to_owned(),
        ReportedValue::NotReported => "Not reported".to_owned(),
    }
}

fn detail(id: &str, title: &str, text: &str) -> DetailSection {
    DetailSection::new(id, title, prefix_chars(text, SECTION_DETAIL_CHARS), false)
}

fn string_field<'a>(fields: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    fields.get(key).and_then(Value::as_str)
}

/// The session activity sections derived from the event state, in display order.
#[must_use]
pub fn sections(state: &SessionEventState) -> Vec<EventSection> {
    let mut result = Vec::new();
    status_sections(state, &mut result);
    usage_section(state, &mut result);
    todo_section(state, &mut result);
    startup_sections(state, &mut result);
    presence_section(state, &mut result);
    resource_sections(state, &mut result);
    child_sections(state, &mut result);
    changed_file_sections(state, &mut result);
    if let Some(target) = &state.superseded_by {
        let mut section = EventSection::new(
            "superseded",
            "Session continued elsewhere",
            "Open the new session. Your draft stays in this conversation.",
        );
        section.session_id = Some(target.clone());
        result.push(section);
    }
    result
}

fn status_sections(state: &SessionEventState, result: &mut Vec<EventSection>) {
    if let Some(status) = &state.status {
        let details = state
            .background_task_count
            .map(|count| vec![detail("background", "Background tasks", &count.to_string())])
            .unwrap_or_default();
        result.push(
            EventSection::new("status", "Session", capitalized(status)).with_details(details),
        );
    }
    if let Some(mode) = &state.collaboration_mode {
        result.push(EventSection::new(
            "collaboration",
            "Collaboration mode",
            capitalized(mode),
        ));
    }
    if let Some(mode) = &state.permission_mode {
        result.push(EventSection::new(
            "permission",
            "Permission mode",
            capitalized(mode),
        ));
    }
    if let Some(mode) = &state.approval_mode {
        result.push(EventSection::new("approval", "Approval mode", mode.clone()));
    }
}

fn usage_section(state: &SessionEventState, result: &mut Vec<EventSection>) {
    let mut details = Vec::new();
    if let Some(tokens) = state.context_tokens {
        details.push(detail(
            "context_tokens",
            "Context tokens",
            &tokens.to_string(),
        ));
    }
    if let Some(window) = state.context_window {
        details.push(detail(
            "context_window",
            "Context window",
            &window.to_string(),
        ));
    }
    if let Some(cost) = state.total_cost_usd {
        details.push(detail(
            "total_cost_usd",
            "Total cost (USD)",
            &swift_number(cost),
        ));
    }
    if let Some(models) = &state.usage_by_model {
        let lines: Vec<String> = models
            .iter()
            .map(|(model, usage)| {
                let mut counts = Vec::new();
                let fields = [
                    ("input_tokens", usage.input_tokens),
                    ("output_tokens", usage.output_tokens),
                    ("total_tokens", usage.total_tokens),
                    ("cache_read_input_tokens", usage.cache_read_input_tokens),
                    (
                        "cache_creation_input_tokens",
                        usage.cache_creation_input_tokens,
                    ),
                ];
                for (key, value) in fields {
                    if let Some(value) = value {
                        counts.push(format!("{key}: {value}"));
                    }
                }
                if let Some(cost) = usage.total_cost_usd {
                    counts.push(format!("total_cost_usd: {}", swift_number(cost)));
                }
                format!("{model}: {}", counts.join(", "))
            })
            .collect();
        details.push(detail(
            "usage_by_model",
            "Usage by model",
            &lines.join("\n"),
        ));
    }
    if details.is_empty() {
        return;
    }
    let summary = state.context_tokens.map_or_else(
        || "Reported usage".to_owned(),
        |tokens| format!("{tokens} context tokens"),
    );
    result.push(EventSection::new("usage", "Usage", summary).with_details(details));
}

fn todo_section(state: &SessionEventState, result: &mut Vec<EventSection>) {
    let Some(todos) = &state.todos else { return };
    let completed = todos
        .iter()
        .filter(|todo| todo.status.as_str() == "completed")
        .count();
    let details = todos
        .iter()
        .take(SECTION_ENTRIES)
        .enumerate()
        .map(|(index, todo)| {
            let status = todo.status.as_str();
            let heading = format!("{}: {}", type_title(status), todo.content);
            let text = if status == "in_progress" {
                todo.active_form.as_deref().unwrap_or(&todo.content)
            } else {
                &todo.content
            };
            detail(&format!("todo-{index}"), &heading, text)
        })
        .collect();
    let summary = format!("{completed} of {} complete", todos.len());
    result.push(EventSection::new("todos", "Tasks", summary).with_details(details));
}

fn startup_sections(state: &SessionEventState, result: &mut Vec<EventSection>) {
    if state.terminal_pending == Some(true) {
        result.push(EventSection::new(
            "terminal-pending",
            "Terminal",
            "Starting terminal…",
        ));
    }
    if let Some(sandbox) = &state.sandbox {
        let details = sandbox
            .error
            .as_deref()
            .map(|error| vec![detail("error", "Error", error)])
            .unwrap_or_default();
        result.push(
            EventSection::new(
                "sandbox",
                "Environment startup",
                capitalized(sandbox.stage.as_str()),
            )
            .with_details(details),
        );
    }
    if let Some(servers) = state
        .mcp_startup
        .as_ref()
        .filter(|servers| !servers.is_empty())
    {
        let details = servers
            .iter()
            .take(SECTION_ENTRIES)
            .map(|(name, server)| {
                let mut text = server.status.as_str().to_owned();
                if let Some(error) = &server.error {
                    text.push('\n');
                    text.push_str(error);
                }
                detail(name, name, &text)
            })
            .collect();
        let summary = format!("{} servers", servers.len());
        result.push(EventSection::new("mcp", "MCP servers", summary).with_details(details));
    }
}

fn presence_section(state: &SessionEventState, result: &mut Vec<EventSection>) {
    let Some(viewers) = &state.viewers else {
        return;
    };
    let details = viewers
        .iter()
        .take(SECTION_ENTRIES)
        .enumerate()
        .map(|(index, viewer)| {
            let text = if viewer.idle { "Idle" } else { "Active" };
            detail(&format!("viewer-{index}"), &viewer.user_id, text)
        })
        .collect();
    let summary = format!("{} connected", viewers.len());
    result.push(EventSection::new("presence", "Viewers", summary).with_details(details));
}

fn resource_sections(state: &SessionEventState, result: &mut Vec<EventSection>) {
    let Some(resources) = &state.resources else {
        return;
    };
    for (id, resource) in resources {
        let kind = string_field(resource, "type").unwrap_or("Resource");
        let active = state
            .terminal_activity
            .as_ref()
            .is_some_and(|terminals| terminals.contains(id));
        let mut details = vec![detail("id", "Resource ID", id)];
        if let Some(metadata) = resource.get("metadata").and_then(Value::as_object) {
            for key in ["cwd", "command", "path", "description", "environment"] {
                if let Some(value) = metadata.get(key) {
                    let text = display::safe_display_text(value);
                    details.push(detail(key, &capitalized(key), &text));
                }
            }
        }
        let title = string_field(resource, "name").map_or_else(|| capitalized(kind), str::to_owned);
        let summary = if active {
            "Terminal output received".to_owned()
        } else {
            capitalized(kind)
        };
        result.push(
            EventSection::new(&format!("resource-{id}"), &title, summary).with_details(details),
        );
    }
}

fn child_sections(state: &SessionEventState, result: &mut Vec<EventSection>) {
    let Some(children) = &state.children else {
        return;
    };
    for (id, child) in children {
        let title = string_field(child, "title")
            .or_else(|| string_field(child, "agent_name"))
            .unwrap_or("Subagent");
        let summary = string_field(child, "status").unwrap_or("Created");
        let mut section = EventSection::new(&format!("child-{id}"), title, summary)
            .with_details(vec![detail("id", "Session ID", id)]);
        section.session_id = Some(id.clone());
        result.push(section);
    }
}

fn changed_file_sections(state: &SessionEventState, result: &mut Vec<EventSection>) {
    let Some(environments) = &state.changed_files else {
        return;
    };
    for (id, files) in environments {
        let (summary, details) = match files {
            ChangedFiles::Loading => ("Loading changed files…".to_owned(), Vec::new()),
            ChangedFiles::Failed { message } => (message.clone(), Vec::new()),
            ChangedFiles::Loaded { entries } => (
                format!("{} files in {id}", entries.len()),
                entries
                    .iter()
                    .take(SECTION_ENTRIES)
                    .enumerate()
                    .map(|(index, file)| detail(&format!("file-{index}"), &file.path, &file.status))
                    .collect(),
            ),
        };
        result.push(
            EventSection::new(&format!("files-{id}"), "Changed files", summary)
                .with_details(details),
        );
    }
}
