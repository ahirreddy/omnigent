//! Sub-agent (child session) sections for the parent's live group row.
//!
//! The parent stream reports each child through `session.created` (status `Created`) and
//! `session.child_session.updated`, whose `child` is the server's `ChildSessionSummary`
//! (`title`, `task_summary`, `tool`, `busy`, `current_task_status`, `last_task_error`,
//! `last_message_preview`, `pending_elicitations_count`, `created_at`, ...). [`ChildState::of`]
//! classifies those fields once, so every surface agrees on whether a child is starting, running,
//! blocked on the user, ready or failed.
//!
//! Each child becomes a `child-<id>` section: the summary is the state's title and the details
//! carry stable ids (`state`, `goal`, `activity`, `agent`, `error`, `pending`, `started`, `id`).

use serde_json::{Map, Value};

use super::presentation::{EventSection, SUMMARY_CHARS, bounded};
use super::state::DetailSection;

/// Where a child session stands, most urgent first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ChildState {
    /// Blocked on approvals or input (`pending_elicitations_count > 0`).
    NeedsYou,
    /// The child's loop is live, or its latest task is queued or in progress.
    Running,
    /// The latest task failed.
    Failed,
    /// The latest task finished; the child is ready for review.
    Ready,
    /// Created, with no task reported yet.
    Starting,
}

impl ChildState {
    /// Classifies the merged fields the stream reported for one child.
    #[must_use]
    pub fn of(fields: &Map<String, Value>) -> Self {
        if pending_count(fields) > 0 {
            return Self::NeedsYou;
        }
        let task = string(fields, "current_task_status").map(str::to_ascii_lowercase);
        let status = string(fields, "status").map(str::to_ascii_lowercase);
        let busy = fields.get("busy").and_then(Value::as_bool) == Some(true);
        let running = |value: &str| {
            matches!(
                value,
                "running" | "in_progress" | "queued" | "waiting" | "busy"
            )
        };
        if busy || task.as_deref().is_some_and(running) || status.as_deref().is_some_and(running) {
            return Self::Running;
        }
        let failed = |value: &str| matches!(value, "failed" | "error" | "cancelled" | "canceled");
        if task.as_deref().is_some_and(failed) || status.as_deref().is_some_and(failed) {
            return Self::Failed;
        }
        let finished = |value: &str| matches!(value, "completed" | "idle" | "done" | "ready");
        if task.as_deref().is_some_and(finished) || status.as_deref().is_some_and(finished) {
            return Self::Ready;
        }
        if error_message(fields).is_some() {
            return Self::Failed;
        }
        Self::Starting
    }

    /// The machine value of the `state` detail.
    #[must_use]
    pub const fn key(self) -> &'static str {
        match self {
            Self::NeedsYou => "needs_you",
            Self::Running => "running",
            Self::Failed => "failed",
            Self::Ready => "ready",
            Self::Starting => "starting",
        }
    }

    /// The section summary.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::NeedsYou => "Needs you",
            Self::Running => "Running",
            Self::Failed => "Failed",
            Self::Ready => "Ready",
            Self::Starting => "Starting",
        }
    }
}

/// One `child-<id>` section.
#[must_use]
pub(super) fn child_section(id: &str, fields: &Map<String, Value>) -> EventSection {
    let state = ChildState::of(fields);
    let title = string(fields, "title")
        .or_else(|| string(fields, "session_name"))
        .or_else(|| string(fields, "agent_name"))
        .unwrap_or("Subagent");
    let mut details = vec![DetailSection::new("state", "State", state.key(), false)];
    let mut add = |key: &str, label: &str, value: Option<&str>| {
        if let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) {
            details.push(DetailSection::new(
                key,
                label,
                bounded(value, SUMMARY_CHARS),
                false,
            ));
        }
    };
    add("goal", "Goal", string(fields, "task_summary"));
    add("activity", "Latest", string(fields, "last_message_preview"));
    add(
        "agent",
        "Agent",
        string(fields, "tool").or_else(|| string(fields, "agent_name")),
    );
    add("error", "Error", error_message(fields));
    let pending = pending_count(fields);
    let pending = (pending > 0).then(|| pending.to_string());
    add("pending", "Pending requests", pending.as_deref());
    let started = fields
        .get("created_at")
        .and_then(Value::as_i64)
        .map(|seconds| seconds.to_string());
    add("started", "Started", started.as_deref());
    details.push(DetailSection::new("id", "Session ID", id, false));
    let mut section = EventSection::new(&format!("child-{id}"), title, state.title());
    section.details = details;
    section.session_id = Some(id.to_owned());
    section
}

/// Children in the order they started (then by id), so the group never reshuffles.
pub(super) fn ordered<'a>(
    children: impl IntoIterator<Item = (&'a String, &'a Map<String, Value>)>,
) -> Vec<(&'a String, &'a Map<String, Value>)> {
    let mut children: Vec<_> = children.into_iter().collect();
    children.sort_by_key(|(id, fields)| {
        (
            fields
                .get("created_at")
                .and_then(Value::as_i64)
                .unwrap_or(i64::MAX),
            (*id).clone(),
        )
    });
    children
}

fn string<'a>(fields: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    fields.get(key).and_then(Value::as_str)
}

fn pending_count(fields: &Map<String, Value>) -> u64 {
    fields
        .get("pending_elicitations_count")
        .and_then(Value::as_u64)
        .unwrap_or(0)
}

fn error_message(fields: &Map<String, Value>) -> Option<&str> {
    match fields.get("last_task_error")? {
        Value::Object(error) => error
            .get("message")
            .and_then(Value::as_str)
            .or_else(|| error.get("code").and_then(Value::as_str)),
        Value::String(message) => Some(message),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn fields(value: Value) -> Map<String, Value> {
        match value {
            Value::Object(map) => map,
            _ => Map::new(),
        }
    }

    fn detail<'a>(section: &'a EventSection, id: &str) -> Option<&'a str> {
        section
            .details
            .iter()
            .find(|detail| detail.id == id)
            .map(|detail| detail.text.as_str())
    }

    #[test]
    fn classification_puts_a_pending_request_above_everything() {
        let blocked = fields(json!({"busy": true, "pending_elicitations_count": 2}));
        assert_eq!(ChildState::of(&blocked), ChildState::NeedsYou);
        assert_eq!(
            ChildState::of(&fields(json!({"busy": true}))),
            ChildState::Running
        );
        assert_eq!(
            ChildState::of(&fields(json!({"current_task_status": "in_progress"}))),
            ChildState::Running
        );
        assert_eq!(
            ChildState::of(&fields(json!({"current_task_status": "completed"}))),
            ChildState::Ready
        );
        assert_eq!(
            ChildState::of(&fields(json!({"current_task_status": "failed"}))),
            ChildState::Failed
        );
        // A failure from an earlier run does not hide a live retry.
        let retry = fields(json!({"busy": true, "last_task_error": {"message": "exit 1"}}));
        assert_eq!(ChildState::of(&retry), ChildState::Running);
        let errored = fields(json!({"last_task_error": {"code": "required_terminal_exited"}}));
        assert_eq!(ChildState::of(&errored), ChildState::Failed);
        // `session.created` reports only `Created`; older fixtures report `status`.
        assert_eq!(
            ChildState::of(&fields(json!({"status": "Created"}))),
            ChildState::Starting
        );
        assert_eq!(
            ChildState::of(&fields(json!({"status": "idle"}))),
            ChildState::Ready
        );
        assert!(ChildState::NeedsYou < ChildState::Running);
        assert!(ChildState::Ready < ChildState::Starting);
    }

    #[test]
    fn sections_carry_goal_activity_and_pending_with_stable_ids() {
        let child = fields(json!({
            "title": "researcher:auth",
            "task_summary": "Write the auth tests",
            "tool": "researcher",
            "busy": true,
            "pending_elicitations_count": 1,
            "last_message_preview": "Running cargo test",
            "created_at": 1_700_000_000,
        }));
        let section = child_section("conv_c1", &child);
        assert_eq!(section.id, "child-conv_c1");
        assert_eq!(section.title, "researcher:auth");
        assert_eq!(section.summary, "Needs you");
        assert_eq!(section.session_id.as_deref(), Some("conv_c1"));
        assert_eq!(detail(&section, "state"), Some("needs_you"));
        assert_eq!(detail(&section, "goal"), Some("Write the auth tests"));
        assert_eq!(detail(&section, "activity"), Some("Running cargo test"));
        assert_eq!(detail(&section, "agent"), Some("researcher"));
        assert_eq!(detail(&section, "pending"), Some("1"));
        assert_eq!(detail(&section, "started"), Some("1700000000"));
        assert_eq!(detail(&section, "id"), Some("conv_c1"));
        assert_eq!(detail(&section, "error"), None);

        let created = child_section("conv_c2", &fields(json!({"agent_name": "Codex"})));
        assert_eq!(created.title, "Codex");
        assert_eq!(created.summary, "Starting");
        assert_eq!(detail(&created, "goal"), None);
    }

    #[test]
    fn children_order_by_start_then_id() {
        let early = fields(json!({"created_at": 10}));
        let late = fields(json!({"created_at": 20}));
        let unknown = Map::new();
        let (a, b, c) = ("a".to_owned(), "b".to_owned(), "c".to_owned());
        let order: Vec<&str> = ordered([(&a, &unknown), (&b, &late), (&c, &early)])
            .into_iter()
            .map(|(id, _)| id.as_str())
            .collect();
        assert_eq!(order, ["c", "b", "a"]);
    }
}
