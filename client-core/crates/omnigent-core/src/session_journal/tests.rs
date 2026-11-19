//! The Tasks tab against journal pages in the server's shapes
//! (`client-core/fixtures/journal/`) and the web's `sessionJournal.test.ts` cases.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::messages::{
    continue_plan_message, is_stop_plan_message, stop_plan_message, task_action_message,
};
use super::tasks::{
    NativeTask, NativeTaskStatus, StepState, failed_upstream, is_plan_complete, paused_label,
    session_task_list,
};
use super::view::{TaskAction, TaskDetail, TasksContext, list_names, tasks_view};
use super::*;

fn fixture(name: &str) -> Value {
    let full = format!(
        "{}/../../fixtures/journal/{name}.json",
        env!("CARGO_MANIFEST_DIR")
    );
    let text = std::fs::read_to_string(&full).unwrap_or_else(|error| panic!("{full}: {error}"));
    serde_json::from_str(&text).unwrap()
}

/// The fixture's entries, oldest first, as the tab merges them.
fn recorded() -> Vec<JournalEntry> {
    let page = JournalPage::from_value(&fixture("recorded-journal-newest")).unwrap();
    merge_journal_entries(&[&page.data])
}

#[allow(
    clippy::needless_pass_by_value,
    reason = "the helpers take the JSON literals they are handed"
)]
fn entry(value: Value) -> JournalEntry {
    JournalEntry::from_value(&value).unwrap()
}

fn status(id: &str, position: i64, step: &str, status: &str) -> JournalEntry {
    entry(json!({
        "id": id, "position": position, "created_at": 100 + position, "step": step,
        "author": {"type": "agent"}, "kind": "status", "content": {"status": status},
    }))
}

#[allow(
    clippy::needless_pass_by_value,
    reason = "the helpers take the JSON literals they are handed"
)]
fn plan(id: &str, position: i64, steps: Value) -> JournalEntry {
    entry(json!({
        "id": id, "position": position, "created_at": 100 + position, "step": null,
        "author": {"type": "agent"}, "kind": "plan",
        "content": {"version": 1, "name": "Plan", "steps": steps},
    }))
}

const WORKING: TasksContext = TasksContext {
    session_working: true,
    awaiting_user: false,
    can_send: true,
    journal_read: true,
    stopping: false,
};

const IDLE: TasksContext = TasksContext {
    session_working: false,
    ..WORKING
};

#[test]
fn a_page_decodes_the_fields_the_tab_reads() {
    let page = JournalPage::from_value(&fixture("recorded-journal-newest")).unwrap();
    assert!(!page.has_more);
    assert_eq!(page.data.len(), 6);
    let entries = merge_journal_entries(&[&page.data]);
    let positions: Vec<i64> = entries.iter().map(|entry| entry.position).collect();
    assert_eq!(
        positions,
        [0, 1, 2, 3, 4, 5],
        "position order, oldest first"
    );
    let plan = current_plan(&entries).unwrap();
    assert_eq!(plan.plan_name(), Some("Ship the JSON flag"));
    assert_eq!(plan.version, Some(1));
    assert_eq!(plan.steps.len(), 4);
    assert_eq!(plan.steps[3].depends_on, ["test", "docs"]);
    assert_eq!(plan.steps[1].goal, None);
    let failed = entries.last().unwrap();
    assert_eq!(failed.status, Some(StepStatus::Failed));
    assert_eq!(failed.text.as_deref(), Some("Lint broke"));
    assert_eq!(
        plan_graph_revision(&entries),
        Some(GraphRevision::Text(
            "9a3e1c0b7d6f4e2a8b5c1d0e3f2a4b6c".into()
        ))
    );
    assert!(JournalEntry::from_value(&json!({"id": "x"})).is_err());
    let unknown = entry(
        json!({"id": "u", "position": 9, "created_at": 1, "kind": "audit",
                              "author": {"type": "omnigent"}, "content": {"status": "odd"}}),
    );
    assert_eq!(unknown.kind, JournalEntryKind::Unknown("audit".into()));
    assert_eq!(unknown.status, None);
}

#[test]
fn the_recorded_plan_reads_as_the_web_shows_it() {
    let view = tasks_view(&recorded(), &[], &BTreeSet::new(), WORKING);
    assert_eq!(view.plan_name.as_deref(), Some("Ship the JSON flag"));
    assert!(view.from_plan && !view.native);
    assert_eq!(view.summary, "2 of 4 finished");
    assert_eq!(
        view.counts,
        [
            (StepState::Running, "1 running".to_owned()),
            (StepState::Failed, "1 failed".to_owned())
        ]
    );
    assert_eq!(view.updated_at, Some(1_795_080_900));
    assert!(view.can_stop && !view.can_continue && view.paused.is_none());
    let states: Vec<StepState> = view.rows.iter().map(|row| row.state).collect();
    assert_eq!(
        states,
        [
            StepState::Done,
            StepState::Running,
            StepState::Failed,
            StepState::Waiting
        ]
    );
    let [build, test, docs, ship] = view.rows.as_slice() else {
        panic!("four rows")
    };
    assert_eq!(build.detail, Some(TaskDetail::Text("Compiled".into())));
    assert_eq!(build.ended_at, Some(1_795_080_400));
    assert_eq!(build.action, None);
    assert_eq!(
        build.marker_id.as_deref(),
        Some("journal-5e0c1f6a2b3d4e5f60718293a4b5c6d2")
    );
    assert_eq!(
        test.detail,
        Some(TaskDetail::Text("Running the suite".into()))
    );
    assert_eq!(test.started_at, Some(1_795_080_500));
    assert!(test.counts_up);
    assert_eq!(test.action, Some(TaskAction::Stop));
    assert_eq!(docs.action, Some(TaskAction::Retry));
    assert_eq!(docs.history.len(), 2);
    assert_eq!(docs.history[1].text.as_deref(), Some("Lint broke"));
    // Ship waits on a failed task, so it can't start.
    assert_eq!(
        ship.detail,
        Some(TaskDetail::CantStart {
            failed: "Update the docs".into()
        })
    );
    assert_eq!(ship.failed_names, ["Update the docs"]);
    assert_eq!(ship.depends_on_names, ["Run the tests", "Update the docs"]);
    assert_eq!(ship.pending_names, ["Run the tests", "Update the docs"]);
    assert_eq!(
        ship.marker_id, None,
        "a task that has not started has no marker"
    );
    assert_eq!(ship.number, 4);
}

#[test]
fn an_idle_plan_is_stopped_and_offers_to_continue() {
    let view = tasks_view(&recorded(), &[], &BTreeSet::new(), IDLE);
    assert_eq!(view.rows[1].state, StepState::Stopped);
    assert_eq!(
        view.rows[1].detail,
        Some(TaskDetail::Started {
            at: 1_795_080_500,
            text: Some("Running the suite".into())
        })
    );
    assert_eq!(view.rows[1].action, Some(TaskAction::Continue));
    assert_eq!(view.paused.as_deref(), Some("Stopped"));
    assert!(view.can_continue && !view.can_stop);
    // An automation run that wrote the newest entry ended.
    let mut entries = recorded();
    entries.last_mut().unwrap().scheduled_task_run_id = Some("run_1".into());
    let view = tasks_view(&entries, &[], &BTreeSet::new(), IDLE);
    assert_eq!(view.paused.as_deref(), Some("Run ended"));
    // A viewer who can't send gets no menus or controls.
    let reader = TasksContext {
        can_send: false,
        ..IDLE
    };
    let view = tasks_view(&recorded(), &[], &BTreeSet::new(), reader);
    assert!(view.rows.iter().all(|row| row.action.is_none()));
    assert!(!view.can_continue && !view.can_stop);
}

#[test]
fn a_prompt_waiting_for_the_user_holds_the_started_task() {
    let waiting = TasksContext {
        awaiting_user: true,
        ..WORKING
    };
    let view = tasks_view(&recorded(), &[], &BTreeSet::new(), waiting);
    let test = &view.rows[1];
    assert_eq!(test.state, StepState::NeedsInput);
    assert_eq!(
        test.detail,
        Some(TaskDetail::WaitingForYou {
            text: "Running the suite".into()
        })
    );
    assert!(
        test.counts_up,
        "a started task keeps counting while it waits"
    );
    assert_eq!(test.action, Some(TaskAction::Proceed));
    assert_eq!(
        view.counts[0],
        (StepState::NeedsInput, "1 waiting for you".to_owned())
    );
    assert_eq!(view.paused, None);
}

#[test]
fn a_restart_and_the_run_boundary_reset_a_step() {
    let steps = json!([{"id": "a", "name": "A", "depends_on": []},
                       {"id": "b", "name": "B", "depends_on": ["a"]}]);
    let entries = vec![
        plan("p", 0, steps),
        status("s1", 1, "a", "started"),
        status("s2", 2, "a", "failed"),
        status("s3", 3, "a", "started"),
        status("s4", 4, "a", "done"),
    ];
    let view = tasks_view(&entries, &[], &BTreeSet::new(), IDLE);
    let history = &view.rows[0].history;
    let restarted: Vec<bool> = history.iter().map(|entry| entry.restarted).collect();
    assert_eq!(restarted, [false, false, true, false]);
    assert_eq!(
        view.rows[0].started_at,
        Some(103),
        "the current attempt's start"
    );
    assert_eq!(view.rows[1].state, StepState::Ready);
    assert_eq!(view.rows[1].detail, Some(TaskDetail::Ready { goal: None }));
    assert_eq!(view.rows[1].action, Some(TaskAction::Run));
    let mut reset = entries;
    reset.push(entry(
        json!({"id": "r", "position": 5, "created_at": 200, "kind": "plan_status",
                            "author": {"type": "omnigent"}, "content": {"status": "started"}}),
    ));
    let view = tasks_view(&reset, &[], &BTreeSet::new(), IDLE);
    assert_eq!(
        view.rows[0].state,
        StepState::Ready,
        "a new run starts the steps over"
    );
}

#[test]
fn a_plan_is_complete_when_its_final_steps_are_done_after_their_inputs() {
    let steps = json!([{"id": "a", "name": "A", "depends_on": []},
                       {"id": "b", "name": "B", "depends_on": ["a"]}]);
    let done = vec![
        plan("p", 0, steps.clone()),
        status("s1", 1, "a", "done"),
        status("s2", 2, "b", "done"),
    ];
    let list = session_task_list(&done, &[], false, false);
    assert!(is_plan_complete(
        &list.progress,
        Some(&GraphRevision::Number(0))
    ));
    assert_eq!(paused_label(&list.progress, &done, false), None);
    let view = tasks_view(&done, &[], &BTreeSet::new(), WORKING);
    assert_eq!(view.summary, "All 2 tasks done");
    assert!(!view.can_stop, "a complete plan has nothing to stop");
    // `a` started again after `b` finished, so the plan has work left.
    let reopened = [done, vec![status("s3", 3, "a", "started")]].concat();
    let list = session_task_list(&reopened, &[], false, false);
    assert!(!is_plan_complete(
        &list.progress,
        Some(&GraphRevision::Number(0))
    ));
    // A graph newer than the final step's status adds `a`, which never ran.
    let added = vec![plan("p", 0, steps.clone()), status("s2", 1, "b", "done")];
    let progress = session_task_list(&added, &[], false, false).progress;
    assert!(is_plan_complete(&progress, Some(&GraphRevision::Number(0))));
    assert!(!is_plan_complete(
        &progress,
        Some(&GraphRevision::Number(5))
    ));
    let failed = vec![
        plan("p", 0, steps),
        status("s1", 1, "a", "done"),
        status("s2", 2, "b", "failed"),
    ];
    let view = tasks_view(&failed, &[], &BTreeSet::new(), IDLE);
    assert_eq!(view.summary, "All 2 tasks finished");
}

#[test]
fn failures_pass_down_through_tasks_that_have_not_started() {
    let steps = json!([{"id": "a", "name": "A", "depends_on": []},
                       {"id": "b", "name": "B", "depends_on": ["a"]},
                       {"id": "c", "name": "C", "depends_on": ["b"]}]);
    let entries = vec![plan("p", 0, steps), status("s1", 1, "a", "failed")];
    let list = session_task_list(&entries, &[], false, false);
    let blocked = failed_upstream(&list.progress);
    assert_eq!(
        blocked.get("b").map(Vec::as_slice),
        Some(&["a".to_owned()][..])
    );
    assert_eq!(
        blocked.get("c").map(Vec::as_slice),
        Some(&["a".to_owned()][..])
    );
    assert_eq!(list_names(&["A".into()]), "A");
    assert_eq!(
        list_names(&["A".into(), "B".into(), "C".into()]),
        "A, B and C"
    );
}

#[test]
fn statuses_without_a_plan_name_their_steps() {
    let entries = vec![status("s1", 0, "triage", "started")];
    let view = tasks_view(&entries, &[], &BTreeSet::new(), WORKING);
    assert!(!view.from_plan && !view.native);
    assert_eq!(view.rows[0].name, "triage");
    assert_eq!(view.rows[0].state, StepState::Running);
}

fn native(id: &str, content: &str, status: NativeTaskStatus, active: Option<&str>) -> NativeTask {
    NativeTask {
        id: id.into(),
        content: content.into(),
        status,
        active_form: active.map(str::to_owned),
    }
}

#[test]
fn without_a_journal_the_agents_own_list_shows() {
    let todos = [
        native("task-1", "Read the code", NativeTaskStatus::Completed, None),
        native(
            "task-2",
            "Fix the bug",
            NativeTaskStatus::InProgress,
            Some("Fixing the bug"),
        ),
        native("task-3", "Write a test", NativeTaskStatus::Pending, None),
    ];
    let markers: BTreeSet<String> = ["todo-task-1-done".to_owned()].into();
    let view = tasks_view(&[], &todos, &markers, WORKING);
    assert!(view.native && !view.from_plan && view.plan_name.is_none());
    assert_eq!(view.summary, "1 of 3 finished");
    let [read, fix, write] = view.rows.as_slice() else {
        panic!("three rows")
    };
    assert_eq!(read.marker_id.as_deref(), Some("todo-task-1-done"));
    assert_eq!(fix.marker_id, None, "its start marker is not in the chat");
    assert_eq!(fix.detail, Some(TaskDetail::Text("Fixing the bug".into())));
    assert_eq!(fix.history, Vec::new());
    assert_eq!(write.state, StepState::Waiting);
    assert_eq!(write.detail, None);
    // An idle list with tasks left is stopped.
    let view = tasks_view(&[], &todos, &markers, IDLE);
    assert_eq!(view.paused.as_deref(), Some("Stopped"));
    // A plan, even unread, never shows beside the agent's list: a failed read shows the list.
    let unread = TasksContext {
        journal_read: false,
        ..WORKING
    };
    let view = tasks_view(&recorded(), &todos, &markers, unread);
    assert!(view.native);
    let view = tasks_view(&recorded(), &todos, &markers, WORKING);
    assert!(!view.native, "a plan wins over the agent's list");
}

#[test]
fn task_messages_match_the_web_word_for_word() {
    let resume = "\n\nResume or restart any previously stopped background tasks, subagents, and other Omnigent sessions needed for the remaining work.";
    let run = task_action_message(TaskAction::Run, "Build").unwrap();
    assert!(run.starts_with("Run the task \"Build\", then go on with the rest of the plan."));
    assert!(run.contains(resume));
    assert!(
        task_action_message(TaskAction::Retry, "Build")
            .unwrap()
            .starts_with("Retry the task \"Build\"")
    );
    assert!(
        task_action_message(TaskAction::Proceed, "Build")
            .unwrap()
            .starts_with("It's fine to continue the task \"Build\". Mark it started")
    );
    assert_eq!(task_action_message(TaskAction::Stop, "Build"), None);
    assert!(continue_plan_message(Some("Ship")).starts_with(
        "Continue the plan \"Ship\" from where you left off, and work through the tasks that are left."
    ));
    assert!(continue_plan_message(None).starts_with("Continue the plan from where"));
    assert!(stop_plan_message(None).starts_with("Stop the plan now. Stop all background tasks"));
    assert!(stop_plan_message(None).ends_with("until I explicitly tell you to continue."));
}

#[test]
fn merging_keeps_the_newest_copy_of_each_entry_in_position_order() {
    let first = status("a", 2, "x", "started");
    let mut newer = first.clone();
    newer.text = Some("again".into());
    let merged = merge_journal_entries(&[
        &[first, status("b", 1, "x", "started")],
        std::slice::from_ref(&newer),
    ]);
    let ids: Vec<&str> = merged.iter().map(|entry| entry.id.as_str()).collect();
    assert_eq!(ids, ["b", "a"]);
    assert_eq!(merged[1].text.as_deref(), Some("again"));
}

#[test]
fn a_rename_keeps_the_graph_revision_of_the_plan_that_set_the_graph() {
    let steps = json!([{"id": "a", "name": "A", "depends_on": []}]);
    let renamed = json!([{"id": "a", "name": "A, renamed", "depends_on": []}]);
    let entries = vec![plan("p1", 0, steps.clone()), plan("p2", 1, renamed)];
    assert_eq!(
        plan_graph_revision(&entries),
        Some(GraphRevision::Number(0))
    );
    let rewired = json!([{"id": "b", "name": "B", "depends_on": []}]);
    let entries = vec![plan("p1", 0, steps), plan("p2", 1, rewired)];
    assert_eq!(
        plan_graph_revision(&entries),
        Some(GraphRevision::Number(1))
    );
}

#[test]
fn a_replan_from_a_saved_workflow_keeps_its_workflow() {
    let steps = json!([{"id": "a", "name": "A", "depends_on": []}]);
    let mut start = plan("p1", 0, steps.clone());
    start.workflow_id = Some("wf_1".into());
    let replan = plan("p2", 1, steps);
    assert_eq!(
        plan_workflow_id(&[start.clone(), replan]).as_deref(),
        Some("wf_1")
    );
    let other = plan("p3", 1, json!([{"id": "z", "name": "Z", "depends_on": []}]));
    assert_eq!(plan_workflow_id(&[start, other]), None);
}

#[test]
fn a_rows_line_previews_its_markdown_goal_and_its_history_keeps_all_of_it() {
    let goal = "**Inputs:** the change.\n\n- Fix the tests\n- Send it";
    let steps = json!([{"id": "a", "name": "A", "goal": goal, "depends_on": []},
                       {"id": "b", "name": "B", "goal": "**Waits** on `a`", "depends_on": ["a"]},
                       {"id": "c", "name": "C", "goal": "---", "depends_on": ["a"]}]);
    let view = tasks_view(&[plan("p", 0, steps)], &[], &BTreeSet::new(), IDLE);
    assert_eq!(
        view.rows[0].detail,
        Some(TaskDetail::Ready {
            goal: Some("Inputs: the change. Fix the tests · Send it".into())
        })
    );
    assert_eq!(view.rows[0].goal.as_deref(), Some(goal));
    assert_eq!(
        view.rows[1].detail,
        Some(TaskDetail::Text("Waits on a".into()))
    );
    // A goal with no text left after its syntax shows no line.
    assert_eq!(view.rows[2].detail, None);
}

#[test]
fn a_stopping_run_shows_stopping_in_stops_place_and_offers_no_stop() {
    let stopping = TasksContext {
        stopping: true,
        ..WORKING
    };
    let view = tasks_view(&recorded(), &[], &BTreeSet::new(), stopping);
    assert!(view.stopping && !view.can_stop && !view.can_continue);
    assert!(
        view.rows.iter().all(|row| row.action != Some(TaskAction::Stop)),
        "a running task's menu offers no second Stop"
    );
    let view = tasks_view(&recorded(), &[], &BTreeSet::new(), WORKING);
    assert!(!view.stopping && view.can_stop);
    // A viewer who can't send sees neither.
    let reader = TasksContext {
        can_send: false,
        ..stopping
    };
    assert!(!tasks_view(&recorded(), &[], &BTreeSet::new(), reader).stopping);
}

#[test]
fn a_stop_message_is_known_whatever_plan_it_names() {
    assert!(is_stop_plan_message(&stop_plan_message(None)));
    assert!(is_stop_plan_message(&format!(
        "  {}\n",
        stop_plan_message(Some("Ship \"it\" now"))
    )));
    assert!(is_stop_plan_message(&stop_plan_message(Some(""))));
    assert!(!is_stop_plan_message(&continue_plan_message(None)));
    assert!(!is_stop_plan_message("Stop the plan now."));
    let other = stop_plan_message(None).replace("Stop the plan", "Stop the build");
    assert!(!is_stop_plan_message(&other));
}
