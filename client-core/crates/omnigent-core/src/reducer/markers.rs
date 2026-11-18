//! Chat markers the server writes as `resource_event` items: a sub-agent's start and end
//! (`omnigent/server/subagent_activity.py`), and a task's start or end or a plan change
//! (`omnigent/server/journal_markers.py`). Ground truth for how they read:
//! `web/src/lib/subagentActivity.ts` and `web/src/lib/taskActivity.ts`.

use omnigent_protocol::items::ResourceEventData;
use serde_json::{Map, Value};

use super::presentation::{TITLE_CHARS, bounded};
use super::state::{ActivityKind, DetailSection};

/// The resource type of the journal's receipts: task markers, plan lines and checkpoints.
pub(super) const JOURNAL_RESOURCE: &str = "journal";

/// Past this many names, a plan line counts them instead.
const NAMES_IN_A_LINE: usize = 3;

/// What a marker row shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Marker {
    pub(super) kind: ActivityKind,
    /// How it leads ("Started", "Completed", ...), or a plan line's whole text.
    pub(super) title: String,
    /// The sub-agent's title or the task's name; empty for a plan line.
    pub(super) summary: String,
    /// `delegated` or `returned` for a sub-agent; the task's status, or `plan`.
    pub(super) status: String,
    pub(super) details: Vec<DetailSection>,
    /// The line as one string, for copying and reading aloud.
    pub(super) text: String,
}

/// The marker `resource` stands for, if it is one.
pub(super) fn marker(resource: &ResourceEventData) -> Option<Marker> {
    subagent_marker(resource)
        .or_else(|| task_marker(resource))
        .or_else(|| plan_marker(resource))
}

fn detail(id: &str, title: &str, text: &str, is_code: bool) -> Option<DetailSection> {
    (!text.is_empty()).then(|| DetailSection::new(id, title, bounded(text, TITLE_CHARS), is_code))
}

fn string<'a>(fields: Option<&'a Map<String, Value>>, key: &str) -> Option<&'a str> {
    fields?.get(key).and_then(Value::as_str)
}

/// `session.subagent.delegated` and `.returned` (`readSubagentActivity`): "Started",
/// "Completed", "Failed" or "Stopped", then the sub-agent's title, which opens its session.
fn subagent_marker(resource: &ResourceEventData) -> Option<Marker> {
    let phase = match resource.event_type.as_str() {
        "session.subagent.delegated" => "delegated",
        "session.subagent.returned" => "returned",
        _ => return None,
    };
    if resource.resource_type != "session" || resource.resource_id.is_empty() {
        return None;
    }
    let fields = resource.resource.as_ref();
    let title = string(fields, "title")
        .filter(|title| !title.trim().is_empty())
        .unwrap_or("Sub-agent");
    let status = string(fields, "status");
    let label = match (phase, status) {
        ("delegated", _) => "Started",
        (_, Some("failed")) => "Failed",
        (_, Some("cancelled" | "killed" | "stopped")) => "Stopped",
        _ => "Completed",
    };
    Some(Marker {
        kind: ActivityKind::SubagentMarker,
        title: label.to_owned(),
        summary: title.to_owned(),
        status: phase.to_owned(),
        details: [
            detail("session", "Session", &resource.resource_id, true),
            detail("status", "Status", status.unwrap_or_default(), false),
        ]
        .into_iter()
        .flatten()
        .collect(),
        text: format!("{label} {title}"),
    })
}

/// How a task marker leads (`taskMarkerLabel`).
fn task_label(status: &str) -> Option<&'static str> {
    Some(match status {
        "started" => "Started",
        "done" => "Completed",
        "failed" => "Failed",
        "needs_input" => "Waiting for you on",
        _ => return None,
    })
}

/// `session.journal.task` (`readTaskActivity`): where a task started, finished, failed or began
/// waiting for the person, then its name.
fn task_marker(resource: &ResourceEventData) -> Option<Marker> {
    if resource.resource_type != JOURNAL_RESOURCE
        || resource.event_type != "session.journal.task"
        || resource.resource_id.is_empty()
    {
        return None;
    }
    let fields = resource.resource.as_ref();
    let status = string(fields, "status")?;
    let label = task_label(status)?;
    let name = string(fields, "name")
        .filter(|name| !name.is_empty())
        .unwrap_or(&resource.resource_id);
    let native = fields.and_then(|fields| fields.get("native")) == Some(&Value::Bool(true));
    Some(Marker {
        kind: ActivityKind::TaskMarker,
        title: label.to_owned(),
        summary: name.to_owned(),
        status: status.to_owned(),
        details: [
            detail("task", "Task", &resource.resource_id, true),
            detail(
                "text",
                "Note",
                string(fields, "text").unwrap_or_default(),
                false,
            ),
            detail(
                "list",
                "List",
                if native {
                    "The agent's tasks"
                } else {
                    "The plan"
                },
                false,
            ),
        ]
        .into_iter()
        .flatten()
        .collect(),
        text: format!("{label} {name}"),
    })
}

fn names(fields: Option<&Map<String, Value>>, key: &str) -> Vec<String> {
    fields
        .and_then(|fields| fields.get(key))
        .and_then(Value::as_array)
        .map(|names| {
            names
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

/// "added A, B" or "added 4 tasks" (`changedTasks`); empty without names.
fn changed_tasks(names: &[String], verb: &str) -> String {
    match names.len() {
        0 => String::new(),
        count if count > NAMES_IN_A_LINE => format!("{verb} {count} tasks"),
        _ => format!("{verb} {}", names.join(", ")),
    }
}

/// A plan line's text (`planChangeText`): "Made a plan: Ship it · 5 tasks", "Updated the
/// plan: added A, removed B", ...
fn plan_text(change: &str, fields: Option<&Map<String, Value>>) -> Option<String> {
    let name = string(fields, "name").unwrap_or_default();
    // The server counts the plan's steps; anything but a count reads as none.
    let tasks = fields
        .and_then(|fields| fields.get("tasks"))
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let count = format!("{tasks} {}", if tasks == 1 { "task" } else { "tasks" });
    Some(match change {
        "made" => format!("Made a plan: {name} \u{00B7} {count}"),
        "replaced" => format!("Replaced the plan with {name} \u{00B7} {count}"),
        "renamed" => format!("Renamed the plan to {name}"),
        "updated" => {
            let changes: Vec<String> = [
                changed_tasks(&names(fields, "added"), "added"),
                changed_tasks(&names(fields, "removed"), "removed"),
            ]
            .into_iter()
            .filter(|change| !change.is_empty())
            .collect();
            if changes.is_empty() {
                "Updated the plan".to_owned()
            } else {
                format!("Updated the plan: {}", changes.join(", "))
            }
        }
        _ => return None,
    })
}

/// `session.journal.plan` (`readTaskActivity`): one line for each change to the plan.
fn plan_marker(resource: &ResourceEventData) -> Option<Marker> {
    if resource.resource_type != JOURNAL_RESOURCE || resource.event_type != "session.journal.plan" {
        return None;
    }
    let fields = resource.resource.as_ref();
    let entry = string(fields, "entry_id").filter(|entry| !entry.is_empty())?;
    let text = plan_text(string(fields, "change")?, fields)?;
    Some(Marker {
        kind: ActivityKind::TaskMarker,
        title: text.clone(),
        summary: String::new(),
        status: "plan".to_owned(),
        details: detail("entry", "Plan entry", entry, true)
            .into_iter()
            .collect(),
        text,
    })
}

#[cfg(test)]
#[path = "markers_tests.rs"]
mod tests;
