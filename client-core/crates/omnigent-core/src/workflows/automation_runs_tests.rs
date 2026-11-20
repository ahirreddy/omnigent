//! An automation run's plan as `run-steps` sends it, and the web's `latestStatusText` cases
//! (`sessionJournal.test.ts`).

use serde_json::{Value, json};

use super::*;
use crate::workflows::runs::{PlanRunControl, run_control, run_step_actions};

const PLAN: &str = "0123456789abcdef0123456789abcdef";
const SESSION: &str = "fedcba9876543210fedcba9876543210";

fn status_entry(position: i64, step: &str, content: &Value) -> Value {
    json!({
        "id": format!("s{position}"), "position": position, "created_at": 100 + position,
        "step": step, "kind": "status", "content": content,
    })
}

fn entries(values: &[Value]) -> Vec<JournalEntry> {
    values
        .iter()
        .map(|value| JournalEntry::from_value(value).unwrap())
        .collect()
}

fn run_steps(is_current: bool, plan_id: Option<&str>) -> AutomationRunSteps {
    AutomationRunSteps::from_value(&json!({
        "run_id": "run-1", "plan_id": plan_id, "plan_graph_revision": "graph-1",
        "is_current": is_current, "workflow_id": PLAN, "plan_name": "Fix the build",
        "steps": [
            {"id": "build", "name": "Build", "goal": null, "depends_on": []},
            {"id": "test", "name": "Test", "goal": null, "depends_on": ["build"]},
        ],
        "statuses": [status_entry(4, "build", &json!({"status": "done", "text": "Built"}))],
    }))
    .unwrap()
}

#[test]
fn a_page_decodes_each_runs_plan_and_its_cursor() {
    let (runs, next) = run_steps_page(&json!({
        "runs": [{
            "run_id": "run-1", "plan_id": PLAN, "plan_graph_revision": 7, "is_current": true,
            "workflow_id": null, "plan_name": "  ",
            "steps": [{"id": "a", "name": "A", "depends_on": []}], "statuses": [],
        }],
        "next_cursor": "run-1",
    }))
    .unwrap();
    assert_eq!(next.as_deref(), Some("run-1"));
    let [run] = runs.as_slice() else {
        panic!("one run: {runs:?}")
    };
    assert_eq!(run.plan_graph_revision, Some(GraphRevision::Number(7)));
    assert_eq!(run.workflow_id, None);
    assert_eq!(run.plan_name, None, "a blank name is no name");
    assert_eq!(run.steps.len(), 1);
    // A viewer's page is empty.
    let (runs, next) = run_steps_page(&json!({"runs": [], "next_cursor": null})).unwrap();
    assert!(runs.is_empty() && next.is_none());
    assert!(run_steps_page(&json!({"runs": [{"plan_id": PLAN}]})).is_err());
}

#[test]
fn only_the_current_plan_with_an_entry_id_takes_actions() {
    assert!(run_steps(true, Some(PLAN)).takes_actions());
    assert!(!run_steps(false, Some(PLAN)).takes_actions());
    assert!(
        !run_steps(true, None).takes_actions(),
        "an older server names no plan"
    );
}

#[test]
fn as_a_workflow_run_it_offers_stop_while_working_and_play_once_stopped() {
    let steps = run_steps(true, Some(PLAN));
    let working = steps.as_workflow_run(SESSION, 50, true);
    assert_eq!(working.id, PLAN, "messages name the plan entry");
    assert_eq!(working.session_id, SESSION);
    assert_eq!(working.workflow_id, PLAN);
    assert_eq!(
        run_control(&working, true, false, true),
        Some(PlanRunControl::Stop)
    );
    let idle = steps.as_workflow_run(SESSION, 50, false);
    assert_eq!(
        run_control(&idle, false, false, true),
        Some(PlanRunControl::Play)
    );
    let actions = run_step_actions(&idle, false, false, true);
    assert_eq!(actions.len(), 2);
    let stale = run_steps(false, Some(PLAN)).as_workflow_run(SESSION, 50, false);
    assert_eq!(run_control(&stale, false, false, true), None);
}

#[test]
fn the_latest_status_text_is_the_words_written_last_on_any_step() {
    let statuses = entries(&[
        status_entry(4, "explore", &json!({"status": "done", "text": "Found it"})),
        status_entry(9, "fix", &json!({"status": "failed", "text": "CI is down"})),
        status_entry(6, "test", &json!({"status": "done", "text": "Tests pass"})),
    ]);
    let found = latest_status_text(&statuses).unwrap();
    assert_eq!(found.status, StepStatus::Failed);
    assert_eq!(found.labeled(), "Failed: CI is down");
}

#[test]
fn a_status_without_words_or_a_known_status_does_not_count() {
    let statuses = entries(&[
        status_entry(
            2,
            "explore",
            &json!({"status": "done", "text": " Found it "}),
        ),
        status_entry(5, "fix", &json!({"status": "started", "text": null})),
        status_entry(7, "test", &json!({"status": "done", "text": "  "})),
        json!({
            "id": "n8", "position": 8, "created_at": 108, "kind": "note",
            "content": {"body": "A note"},
        }),
        status_entry(
            9,
            "ship",
            &json!({"status": "paused", "text": "Unknown status"}),
        ),
    ]);
    let found = latest_status_text(&statuses).unwrap();
    assert_eq!(found.labeled(), "Done: Found it");
    assert_eq!(latest_status_text(statuses.get(1..2).unwrap()), None);
    assert_eq!(latest_status_text(&[]), None);
    let waiting = entries(&[status_entry(
        3,
        "ask",
        &json!({"status": "needs_input", "text": "Which branch?"}),
    )]);
    assert_eq!(
        latest_status_text(&waiting).unwrap().labeled(),
        "Waiting for you: Which branch?"
    );
}
