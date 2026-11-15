//! Sub-agent (child session) sections for the parent's composer tally and Agents tab.
//!
//! The parent stream reports each child through `session.created` and
//! `session.child_session.updated`, whose `child` is the server's `ChildSessionSummary`
//! (`title`, `task_summary`, `tool`, `busy`, `current_task_status`, `last_task_error`,
//! `last_message_preview`, `pending_elicitations_count`, `created_at`, ...). The merged fields
//! are classified by [`ChildSessionRow::status`], the web's `childStatus`, so the stream and the
//! Agents tab agree on whether a child is launching, working, waiting on the user, done, failed,
//! disconnected or idle.
//!
//! Each child becomes a `child-<id>` section: the status label is its summary and the details
//! carry stable ids (`state`, `goal`, `activity`, `agent`, `error`, `pending`, `started`, `id`).

use serde_json::{Map, Value};

use super::presentation::{EventSection, SUMMARY_CHARS, bounded};
use super::state::DetailSection;
use crate::agent_tree::{AgentStatus, ChildSessionRow};

/// Where the child stands, from the fields the stream merged for it. A child the stream only
/// announced (`session.created`) has no summary yet and reads idle, as the web's list does.
#[must_use]
fn child_status(id: &str, fields: &Map<String, Value>) -> AgentStatus {
    ChildSessionRow {
        id: id.to_owned(),
        current_task_status: string(fields, "current_task_status").map(str::to_owned),
        last_task_error: task_error(fields),
        busy: fields.get("busy").and_then(Value::as_bool) == Some(true),
        pending_elicitations_count: pending_count(fields),
        ..ChildSessionRow::default()
    }
    .status()
}

/// One `child-<id>` section.
#[must_use]
pub(super) fn child_section(id: &str, fields: &Map<String, Value>) -> EventSection {
    let status = child_status(id, fields);
    let title = string(fields, "title")
        .or_else(|| string(fields, "session_name"))
        .or_else(|| string(fields, "agent_name"))
        .unwrap_or("Subagent");
    let mut details = vec![DetailSection::new(
        "state",
        "State",
        status.activity.key(),
        false,
    )];
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
    let mut section = EventSection::new(&format!("child-{id}"), title, status.label);
    section.details = details;
    section.session_id = Some(id.to_owned());
    section
}

/// Children in the order they started (then by id), so the list never reshuffles.
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

/// The latest failure as `(code, message)`; a bare text error has no code.
fn task_error(fields: &Map<String, Value>) -> Option<(String, String)> {
    let message = error_message(fields)?;
    let code = match fields.get("last_task_error") {
        Some(Value::Object(error)) => error.get("code").and_then(Value::as_str),
        _ => None,
    };
    Some((code.unwrap_or_default().to_owned(), message.to_owned()))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::agent_tree::AgentActivity;

    fn fields(value: Value) -> Map<String, Value> {
        match value {
            Value::Object(map) => map,
            _ => Map::new(),
        }
    }

    fn activity(value: Value) -> AgentActivity {
        child_status("conv_c", &fields(value)).activity
    }

    fn detail<'a>(section: &'a EventSection, id: &str) -> Option<&'a str> {
        section
            .details
            .iter()
            .find(|detail| detail.id == id)
            .map(|detail| detail.text.as_str())
    }

    #[test]
    fn a_failed_child_reports_it_from_a_text_error_and_ignores_other_shapes() {
        let failed = child_status("conv_c", &fields(json!({"last_task_error": "boom"})));
        assert_eq!(failed.activity, AgentActivity::Failed);
        assert_eq!(failed.label, "Failed");
        assert_eq!(failed.detail.as_deref(), Some("boom"));
        assert_eq!(
            error_message(&fields(json!({"last_task_error": "boom"}))),
            Some("boom")
        );
        assert_eq!(error_message(&fields(json!({"last_task_error": 5}))), None);
        assert_eq!(task_error(&fields(json!({"last_task_error": 5}))), None);
        assert_eq!(
            activity(json!({"last_task_error": {"code": "required_terminal_exited"}})),
            AgentActivity::Failed
        );
    }

    #[test]
    fn classification_follows_the_web() {
        let blocked = json!({"busy": true, "pending_elicitations_count": 2});
        assert_eq!(activity(blocked), AgentActivity::NeedsYou);
        let launching = json!({"busy": false, "current_task_status": "launching"});
        assert_eq!(activity(launching), AgentActivity::Launching);
        assert_eq!(activity(json!({"busy": true})), AgentActivity::Working);
        let completed = json!({"busy": false, "current_task_status": "completed"});
        assert_eq!(activity(completed), AgentActivity::Done);
        let failed = json!({"current_task_status": "failed"});
        assert_eq!(activity(failed), AgentActivity::Failed);
        // A failure from an earlier run does not hide a live retry.
        let retry = json!({"busy": true, "last_task_error": {"message": "exit 1"}});
        assert_eq!(activity(retry), AgentActivity::Working);
        let gone = json!({"last_task_error": {"code": "runner_disconnected", "message": "gone"}});
        assert_eq!(activity(gone), AgentActivity::Disconnected);
        let cancelled = child_status("c", &fields(json!({"current_task_status": "cancelled"})));
        assert_eq!(
            (cancelled.activity, cancelled.label.as_str()),
            (AgentActivity::Other, "cancelled")
        );
        // No task reported, or only announced: idle, never starting.
        let settled = json!({"busy": false, "current_task_status": null});
        assert_eq!(activity(settled), AgentActivity::Idle);
        assert_eq!(activity(json!({"agent_name": "Codex"})), AgentActivity::Idle);
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
        assert_eq!(created.summary, "Idle");
        assert_eq!(detail(&created, "state"), Some("idle"));
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
