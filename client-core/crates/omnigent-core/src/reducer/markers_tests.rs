//! Ports of `subagentActivity`, `taskActivity` and `planChangeText` cases, with the receipts in
//! the shapes `record_subagent_activity` and `journal_markers` write them.

use serde_json::json;

use super::*;

fn receipt(event_type: &str, resource_type: &str, id: &str, resource: Value) -> ResourceEventData {
    ResourceEventData {
        event_type: event_type.to_owned(),
        resource_id: id.to_owned(),
        resource_type: resource_type.to_owned(),
        resource: match resource {
            Value::Object(fields) => Some(fields),
            _ => None,
        },
    }
}

/// The title, summary and status of the marker `resource` stands for.
fn line(resource: &ResourceEventData) -> Option<(String, String, String)> {
    marker(resource).map(|marker| (marker.title, marker.summary, marker.status))
}

fn owned(title: &str, summary: &str, status: &str) -> (String, String, String) {
    (title.to_owned(), summary.to_owned(), status.to_owned())
}

#[test]
fn sub_agent_markers_name_the_phase_and_title() {
    let delegated = receipt(
        "session.subagent.delegated",
        "session",
        "child-1",
        json!({"title": "Explore auth"}),
    );
    let marker = marker(&delegated).expect("a marker");
    assert_eq!(marker.kind, ActivityKind::SubagentMarker);
    assert_eq!(marker.text, "Started Explore auth");
    assert_eq!(marker.details[0].text, "child-1");
    let cases = [
        (
            json!({"title": "Explore auth", "status": "completed"}),
            "Completed",
        ),
        (
            json!({"title": "Explore auth", "status": "failed"}),
            "Failed",
        ),
        (
            json!({"title": "Explore auth", "status": "killed"}),
            "Stopped",
        ),
        (
            json!({"title": "Explore auth", "status": "cancelled"}),
            "Stopped",
        ),
        (json!({"title": "Explore auth"}), "Completed"),
    ];
    for (resource, label) in cases {
        let returned = receipt("session.subagent.returned", "session", "child-1", resource);
        assert_eq!(
            line(&returned),
            Some(owned(label, "Explore auth", "returned"))
        );
    }
    let untitled = receipt(
        "session.subagent.delegated",
        "session",
        "child-1",
        json!({"title": "  "}),
    );
    assert_eq!(
        line(&untitled),
        Some(owned("Started", "Sub-agent", "delegated"))
    );
    for broken in [
        receipt("session.subagent.delegated", "session", "", json!({})),
        receipt("session.subagent.delegated", "terminal", "t", json!({})),
        receipt("session.resource.created", "session", "child-1", json!({})),
    ] {
        assert_eq!(super::marker(&broken), None, "{broken:?}");
    }
}

#[test]
fn task_markers_lead_with_their_status() {
    let cases = [
        ("started", "Started"),
        ("done", "Completed"),
        ("failed", "Failed"),
        ("needs_input", "Waiting for you on"),
    ];
    for (status, label) in cases {
        let todo = receipt(
            "session.journal.task",
            "journal",
            "task-1",
            json!({"name": "Write the tests", "status": status, "text": null,
                   "entry_id": null, "native": true}),
        );
        assert_eq!(line(&todo), Some(owned(label, "Write the tests", status)));
    }
    let plan_task = receipt(
        "session.journal.task",
        "journal",
        "propose",
        json!({"name": "", "status": "done", "text": "PR merged", "entry_id": "e7",
               "native": false}),
    );
    let plan_task = marker(&plan_task).expect("a plan task's marker");
    assert_eq!(plan_task.summary, "propose");
    assert_eq!(
        plan_task
            .details
            .iter()
            .map(|detail| detail.text.as_str())
            .collect::<Vec<_>>(),
        ["propose", "PR merged", "The plan", "journal-e7"]
    );
    // The agent's own tasks have no entry: the marker answers to the task and its status.
    let todo = receipt(
        "session.journal.task",
        "journal",
        "task-2",
        json!({"name": "Ship", "status": "started", "entry_id": null, "native": true}),
    );
    let todo = marker(&todo).expect("a task's marker");
    assert_eq!(
        todo.details.last().map(|detail| detail.text.as_str()),
        Some("todo-task-2-started")
    );
    for broken in [
        receipt(
            "session.journal.task",
            "journal",
            "t",
            json!({"status": "paused"}),
        ),
        receipt(
            "session.journal.task",
            "journal",
            "",
            json!({"status": "done"}),
        ),
        receipt("session.journal.task", "journal", "t", json!({})),
        receipt(
            "session.journal.checkpoint",
            "journal",
            "e1",
            json!({"entry_id": "e1"}),
        ),
    ] {
        assert_eq!(marker(&broken), None, "{broken:?}");
    }
}

#[test]
fn plan_lines_read_as_the_web_writes_them() {
    let plan = |resource: Value| {
        line(&receipt("session.journal.plan", "journal", "e1", resource)).map(|(title, _, _)| title)
    };
    let cases = [
        (
            json!({"change": "made", "name": "Ship it", "tasks": 5, "added": [], "removed": [],
                   "entry_id": "e1"}),
            Some("Made a plan: Ship it \u{00B7} 5 tasks"),
        ),
        (
            json!({"change": "replaced", "name": "Plan B", "tasks": 1, "entry_id": "e1"}),
            Some("Replaced the plan with Plan B \u{00B7} 1 task"),
        ),
        (
            json!({"change": "renamed", "name": "Ship it now", "tasks": 5, "entry_id": "e1"}),
            Some("Renamed the plan to Ship it now"),
        ),
        (
            json!({"change": "updated", "name": "Ship it", "tasks": 6, "added": ["Docs"],
                   "removed": ["Old step"], "entry_id": "e1"}),
            Some("Updated the plan: added Docs, removed Old step"),
        ),
        (
            json!({"change": "updated", "name": "Ship it", "tasks": 9,
                   "added": ["A", "B", "C", "D"], "removed": [], "entry_id": "e1"}),
            Some("Updated the plan: added 4 tasks"),
        ),
        (
            json!({"change": "updated", "name": "Ship it", "tasks": 5, "entry_id": "e1"}),
            Some("Updated the plan"),
        ),
        (
            json!({"change": "made", "name": "No entry", "tasks": 1}),
            None,
        ),
        (
            json!({"change": "rewritten", "name": "X", "entry_id": "e1"}),
            None,
        ),
    ];
    for (resource, expected) in cases {
        assert_eq!(
            plan(resource.clone()),
            expected.map(str::to_owned),
            "{resource}"
        );
    }
}
