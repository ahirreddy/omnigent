//! Saved workflows against the server's shapes (`client-core/fixtures/workflows/`) and the
//! web's `workflow.test.ts`, `workflowRuns.test.ts` and `workflowGraphLayout.test.ts` cases.

use serde_json::{Value, json};

use super::graph::*;
use super::proposal::*;
use super::runs::*;
use super::*;
use crate::automation_triggers::{
    TriggerConfig, TriggerConfigContext, TriggerSource, TriggerWorker, WorkerPlacement,
    empty_trigger_fields, encode_trigger_prompt,
};
use crate::session_journal::tasks::StepState;

fn fixture(name: &str) -> Value {
    let full = format!(
        "{}/../../fixtures/workflows/{name}.json",
        env!("CARGO_MANIFEST_DIR")
    );
    let text = std::fs::read_to_string(&full).unwrap_or_else(|error| panic!("{full}: {error}"));
    serde_json::from_str(&text).unwrap()
}

const WORKFLOW_ID: &str = "0123456789abcdef0123456789abcdef";

fn step(id: &str, depends_on: &[&str]) -> PlanStep {
    PlanStep {
        id: id.to_owned(),
        name: id.to_owned(),
        goal: None,
        depends_on: depends_on.iter().map(|id| (*id).to_owned()).collect(),
    }
}

#[allow(
    clippy::needless_pass_by_value,
    reason = "the helpers take the JSON literals they are handed"
)]
fn entry(value: Value) -> JournalEntry {
    JournalEntry::from_value(&value).unwrap()
}

fn status(position: i64, step: &str, status: &str, revision: Option<&str>) -> JournalEntry {
    let mut content = json!({"status": status});
    if let Some(revision) = revision {
        content["graph_revision"] = json!(revision);
    }
    entry(json!({
        "id": format!("s{position}"), "position": position, "created_at": 100 + position,
        "step": step, "kind": "status", "content": content,
    }))
}

fn run(progress: RunProgress, status: RunSessionStatus) -> WorkflowRun {
    WorkflowRun {
        id: "c".repeat(32),
        workflow_id: WORKFLOW_ID.to_owned(),
        plan_graph_revision: Some(GraphRevision::Text("graph-0".to_owned())),
        session_id: "a".repeat(32),
        title: "Fix the upload test".to_owned(),
        started_at: 1_762_900_000,
        is_current: true,
        session_status: status,
        background_work_running: false,
        sandbox_launching: false,
        archived: false,
        progress,
        steps: vec![],
        statuses: vec![],
        workflow_name: Some("Triage".to_owned()),
        started_by: None,
        descendant_runs: vec![],
        descendant_run_count: 0,
        descendant_runs_cursor: None,
        descendant_runs_active: false,
    }
}

const fn progress(done: u32, needs_input: u32, failed: u32) -> RunProgress {
    RunProgress {
        total: 5,
        started: 0,
        done,
        needs_input,
        failed,
    }
}

fn label(run: &WorkflowRun) -> (RunStateKind, String) {
    let state = describe_run(run, is_run_working(run));
    (state.kind, state.label)
}

#[test]
fn a_workflow_decodes_with_its_steps_planning_chat_and_owner() {
    let detail = WorkflowDetail::from_value(&fixture("workflow")).unwrap();
    assert_eq!(detail.workflow.id, WORKFLOW_ID);
    assert_eq!(detail.workflow.name, "Triage flaky tests");
    assert!(!detail.workflow.is_draft && !detail.workflow.shared_with_me);
    assert!(detail.workflow.shareable);
    assert_eq!(detail.workflow.updated_at, 1_762_900_500);
    let ids: Vec<&str> = detail.steps.iter().map(|step| step.id.as_str()).collect();
    assert_eq!(ids, ["explore", "rerun", "file"]);
    assert_eq!(detail.steps[1].depends_on, ["explore"]);
    assert_eq!(detail.steps[1].goal, None);
    assert_eq!(
        detail.planning_session_id.as_deref(),
        Some("fedcba9876543210fedcba9876543210")
    );
    assert_eq!(detail.workflow.shared_by(), None);
}

#[test]
fn an_older_server_without_the_draft_flag_reads_a_stepless_workflow_as_a_draft() {
    let detail = WorkflowDetail::from_value(&json!({
        "id": WORKFLOW_ID, "name": "New", "description": "Do it", "steps": []
    }))
    .unwrap();
    assert!(detail.workflow.is_draft);
    let shared = SavedWorkflow::from_value(&json!({
        "id": WORKFLOW_ID, "name": "Theirs", "description": "", "viewer_role": "viewer",
        "owner_display_name": "Ada", "shareable": false
    }))
    .unwrap();
    assert_eq!(shared.shared_by().as_deref(), Some("Ada"));
    assert!(!shared.shareable);
    let unnamed = SavedWorkflow {
        owner_display_name: None,
        ..shared
    };
    assert_eq!(unnamed.shared_by().as_deref(), Some("someone else"));
}

#[test]
fn list_pages_follow_next_cursor_else_last_id_while_more_follow() {
    let row = json!({"id": WORKFLOW_ID, "name": "A", "description": "a"});
    let page = WorkflowPage::from_owned_value(&json!({
        "data": [row], "has_more": true, "last_id": "last", "next_cursor": "next"
    }))
    .unwrap();
    assert_eq!(page.next_cursor.as_deref(), Some("next"));
    let older = WorkflowPage::from_owned_value(&json!({
        "data": [row], "has_more": true, "last_id": "last"
    }))
    .unwrap();
    assert_eq!(older.next_cursor.as_deref(), Some("last"));
    let done = WorkflowPage::from_owned_value(&json!({
        "data": [row], "has_more": false, "next_cursor": "next"
    }))
    .unwrap();
    assert_eq!(done.next_cursor, None);
    let shared = WorkflowPage::from_shared_value(&json!({
        "data": [row], "next_cursor": "more"
    }))
    .unwrap();
    assert!(
        shared.workflows[0].shared_with_me,
        "the shared list is others'"
    );
    assert_eq!(shared.next_cursor.as_deref(), Some("more"));
    assert!(WorkflowPage::from_owned_value(&json!({"data": [{"id": 3}]})).is_err());
}

#[test]
fn runs_decode_progress_statuses_starters_and_their_descendants() {
    let page = WorkflowRunPage::from_value(&fixture("runs")).unwrap();
    assert_eq!(page.next_cursor.as_deref(), Some("older-runs"));
    let current = &page.runs[0];
    assert_eq!(current.session_status, RunSessionStatus::Running);
    assert_eq!(
        current.plan_graph_revision,
        Some(GraphRevision::Text("graph-1".to_owned()))
    );
    assert_eq!(current.progress.done, 1);
    assert_eq!(current.statuses.len(), 2);
    assert_eq!(
        current
            .started_by
            .as_ref()
            .map(|starter| starter.title.as_str()),
        Some("Nightly triage")
    );
    assert_eq!(current.descendant_run_count, 3);
    assert_eq!(current.descendant_runs_cursor.as_deref(), Some("cursor-2"));
    let nested = &current.descendant_runs[0];
    assert!(nested.sandbox_launching && nested.workflow_name.is_none());
    assert_eq!(nested.plan_graph_revision, Some(GraphRevision::Number(4)));
    assert_eq!(nested.progress.total, 2);
    let older = &page.runs[1];
    assert!(!older.is_current && older.archived);
    assert_eq!(older.plan_graph_revision, None);
    assert_eq!(older.steps.len(), 0);
}

#[test]
fn a_question_for_the_user_comes_first_and_a_finished_run_is_done() {
    let waiting = run(progress(2, 1, 0), RunSessionStatus::Running);
    assert_eq!(
        label(&waiting),
        (RunStateKind::Waiting, "Waiting for you".to_owned())
    );
    let done = run(progress(5, 0, 0), RunSessionStatus::Idle);
    assert_eq!(label(&done), (RunStateKind::Done, "Done".to_owned()));
    let mut finished = run(
        RunProgress {
            total: 2,
            done: 1,
            failed: 1,
            ..RunProgress::default()
        },
        RunSessionStatus::Idle,
    );
    finished.steps = vec![step("work", &[]), step("report", &["work"])];
    finished.statuses = vec![
        status(1, "work", "failed", Some("graph-0")),
        status(2, "report", "done", Some("graph-0")),
    ];
    assert_eq!(
        label(&finished),
        (RunStateKind::Done, "Finished, 1 failed".to_owned())
    );
    finished.plan_graph_revision = Some(GraphRevision::Number(3));
    assert_eq!(
        label(&finished).0,
        RunStateKind::Failed,
        "a newer graph reopens it"
    );
}

#[test]
fn a_working_run_shows_its_count_and_a_stopped_one_how_far_it_got() {
    let running = run(progress(2, 0, 1), RunSessionStatus::Running);
    assert_eq!(
        label(&running),
        (RunStateKind::Running, "2 of 5 done".to_owned())
    );
    let mut unknown = run(progress(5, 0, 0), RunSessionStatus::Running);
    unknown.plan_graph_revision = None;
    assert_eq!(
        label(&unknown),
        (RunStateKind::Running, "5 of 5 done".to_owned())
    );
    assert_eq!(
        label(&run(progress(2, 0, 1), RunSessionStatus::Idle)),
        (RunStateKind::Failed, "Failed \u{b7} 2 of 5 done".to_owned())
    );
    assert_eq!(
        label(&run(progress(1, 0, 0), RunSessionStatus::Failed)).1,
        "Session failed \u{b7} 1 of 5 done"
    );
    assert_eq!(
        label(&run(progress(3, 0, 0), RunSessionStatus::Idle)),
        (RunStateKind::Stopped, "3 of 5 done".to_owned())
    );
    let mut historical = run(progress(1, 0, 0), RunSessionStatus::Failed);
    historical.is_current = false;
    assert_eq!(
        describe_run(&historical, true).kind,
        RunStateKind::Stopped,
        "a newer run's activity is not this one's"
    );
}

#[test]
fn background_work_and_a_launching_sandbox_count_as_working() {
    let mut active = run(progress(0, 0, 0), RunSessionStatus::Idle);
    active.background_work_running = true;
    assert!(is_run_working(&active));
    assert_eq!(label(&active).0, RunStateKind::Running);
    assert_eq!(describe_run(&active, false).kind, RunStateKind::Stopped);
    let mut launching = run(progress(0, 0, 0), RunSessionStatus::Idle);
    launching.sandbox_launching = true;
    assert!(is_run_launching(&launching) && is_run_working(&launching));
    launching.is_current = false;
    assert!(!is_run_working(&launching));
}

#[test]
fn a_run_offers_stop_while_working_play_once_stopped_and_nothing_when_done() {
    let mut working = run(progress(1, 0, 0), RunSessionStatus::Running);
    working.steps = vec![step("a", &[]), step("b", &["a"])];
    working.statuses = vec![
        status(1, "a", "done", Some("graph-0")),
        status(2, "b", "started", Some("graph-0")),
    ];
    assert_eq!(
        run_control(&working, true, false, true),
        Some(PlanRunControl::Stop)
    );
    assert_eq!(
        run_control(&working, true, true, true),
        Some(PlanRunControl::Stopping)
    );
    assert_eq!(
        run_control(&working, false, false, true),
        Some(PlanRunControl::Play)
    );
    assert_eq!(
        run_control(&working, true, false, false),
        None,
        "only the owner acts"
    );
    let mut archived = working.clone();
    archived.archived = true;
    assert_eq!(run_control(&archived, true, false, true), None);
    working
        .statuses
        .push(status(3, "b", "done", Some("graph-0")));
    assert_eq!(run_control(&working, false, false, true), None);
    let mut legacy = run(progress(0, 0, 0), RunSessionStatus::Running);
    legacy.plan_graph_revision = None;
    assert_eq!(
        run_control(&legacy, true, false, true),
        Some(PlanRunControl::Stop)
    );
}

#[test]
fn started_by_is_left_out_below_the_session_that_started_it() {
    let mut nested = run(progress(0, 0, 0), RunSessionStatus::Idle);
    nested.started_by = Some(RunStarter {
        session_id: "p".repeat(32),
        title: "Parent".to_owned(),
    });
    assert!(run_starter_shown(&nested, None).is_some());
    assert!(run_starter_shown(&nested, Some(&"p".repeat(32))).is_none());
    assert!(run_starter_shown(&nested, Some("other")).is_some());
}

#[test]
fn descendant_pages_merge_once_and_open_while_one_works_or_waits() {
    let mut parent = run(progress(0, 0, 0), RunSessionStatus::Idle);
    let mut first = run(progress(0, 0, 0), RunSessionStatus::Idle);
    first.id = "first".to_owned();
    let mut second = first.clone();
    second.id = "second".to_owned();
    parent.descendant_runs = vec![first.clone()];
    let mut updated = first;
    updated.title = "Renamed".to_owned();
    let merged = merge_descendant_runs(&parent, &[updated, second.clone()]);
    let ids: Vec<&str> = merged.iter().map(|run| run.id.as_str()).collect();
    assert_eq!(ids, ["first", "second"]);
    assert_eq!(merged[0].title, "Renamed");
    assert!(!descendants_active(&parent, &merged));
    second.progress.needs_input = 1;
    assert!(descendants_active(&parent, &[second]));
    parent.descendant_runs_active = true;
    assert!(descendants_active(&parent, &[]));
    assert_eq!(ran_workflows_label(1), "Ran 1 workflow");
    assert_eq!(ran_workflows_label(3), "Ran 3 workflows");
    assert_eq!(
        run_glyph_state(RunStateKind::Waiting),
        StepState::NeedsInput
    );
}

#[test]
fn search_matches_names_and_descriptions_and_run_a_workflow_skips_drafts() {
    let workflow = |name: &str, description: &str, is_draft: bool| SavedWorkflow {
        id: WORKFLOW_ID.to_owned(),
        name: name.to_owned(),
        description: description.to_owned(),
        is_draft,
        shared_with_me: false,
        owner_display_name: None,
        shareable: true,
        created_at: 0,
        updated_at: 0,
    };
    let all = [
        workflow("Triage flaky tests", "Rerun the suite", false),
        workflow("Release notes", "Draft from merged PRs", true),
    ];
    let names = |found: Vec<SavedWorkflow>| -> Vec<String> {
        found.into_iter().map(|workflow| workflow.name).collect()
    };
    assert_eq!(names(matching_workflows(&all, "  ")).len(), 2);
    assert_eq!(
        names(matching_workflows(&all, "RERUN")),
        ["Triage flaky tests"]
    );
    assert_eq!(names(matching_workflows(&all, "merged")), ["Release notes"]);
    assert_eq!(names(runnable_workflows(&all, "")), ["Triage flaky tests"]);
    assert!(
        runnable_workflows(&all, "suite").is_empty(),
        "the picker searches names"
    );
    let taken = ["Triage flaky tests".to_owned()];
    assert!(workflow_name_taken(&taken, " Triage flaky tests "));
    assert!(!workflow_name_taken(&taken, "   "));
}

#[test]
fn clones_take_the_next_copy_name_within_the_limit() {
    assert_eq!(clone_name("Triage", 1), "Triage (copy)");
    assert_eq!(clone_name("Triage", 2), "Triage (copy 2)");
    let long = "x".repeat(80);
    let copy = clone_name(&long, 12);
    assert_eq!(copy.chars().count(), 80);
    assert!(copy.ends_with(" (copy 12)"));
    let spaced = format!("{} y", "x".repeat(72));
    assert_eq!(clone_name(&spaced, 1), format!("{} (copy)", "x".repeat(72)));
}

#[test]
fn messages_name_the_skill_the_workflow_and_the_review() {
    assert_eq!(
        workflow_message("/", "  Add a --json flag ", true),
        format!("/workflow Add a --json flag\n\n{REVIEW_PLAN_FIRST}")
    );
    assert_eq!(workflow_message("$", "Add it", false), "$workflow Add it");
    assert_eq!(
        saved_workflow_message("/", WORKFLOW_ID, "Triage", " The upload tests ", true),
        format!(
            "/workflow Run the saved workflow \"Triage\" (ID {WORKFLOW_ID}).\n\nThe upload tests\n\n{REVIEW_PLAN_FIRST}"
        )
    );
    assert_eq!(
        saved_workflow_message("/", WORKFLOW_ID, "Triage", "  ", false),
        format!("/workflow Run the saved workflow \"Triage\" (ID {WORKFLOW_ID}).")
    );
    assert_eq!(
        save_workflow_message("$", " Triage "),
        "$save-workflow Save this session's plan as a workflow named \"Triage\"."
    );
    let prompt = run_saved_workflow_prompt(WORKFLOW_ID, "Triage", "Only PROJ-12", true);
    assert!(prompt.starts_with(&format!(
        "Use the workflow skill to run the saved workflow \"Triage\" (ID {WORKFLOW_ID})."
    )));
    assert!(prompt.contains("continue that run without writing a second starting plan"));
    assert!(prompt.ends_with(&format!("Only PROJ-12\n\n{REVIEW_PLAN_FIRST}")));
}

#[test]
fn the_planning_prompt_edits_a_saved_plan_or_drafts_a_first_one() {
    let mut detail = WorkflowDetail::from_value(&fixture("workflow")).unwrap();
    let editing = edit_workflow_plan_prompt(&detail);
    assert!(editing.starts_with(&format!(
        "Help me edit the reusable workflow \"Triage flaky tests\" (ID {WORKFLOW_ID})."
    )));
    assert!(editing.contains("sys_workflow_load"));
    assert!(editing.contains("wait for my answer before proposing"));
    detail.steps.clear();
    let drafting = edit_workflow_plan_prompt(&detail);
    assert!(drafting.starts_with("Help me design"));
    assert!(drafting.ends_with("iterate with me here."));
}

#[test]
fn a_saved_workflows_run_reads_back_with_or_without_details() {
    let message =
        saved_workflow_message("$", WORKFLOW_ID, "Triage \"flaky\"", " The upload ", false);
    assert_eq!(
        parse_saved_workflow_run(&message),
        Some(SavedWorkflowRun {
            id: WORKFLOW_ID.to_owned(),
            name: "Triage \"flaky\"".to_owned(),
            details: "The upload".to_owned(),
        })
    );
    let bare = saved_workflow_message("/", WORKFLOW_ID, "Triage", "", false);
    assert_eq!(parse_saved_workflow_run(&bare).unwrap().details, "");
    assert_eq!(
        parse_saved_workflow_run("Summarize overnight activity"),
        None
    );
    assert_eq!(parse_saved_workflow_run("/workflow Add retries"), None);
    let one_line_break = format!("{bare}\nmore");
    assert_eq!(parse_saved_workflow_run(&one_line_break), None);
    let bad_id = bare.replace(WORKFLOW_ID, "XYZ");
    assert_eq!(parse_saved_workflow_run(&bad_id), None);
}

#[test]
fn an_automation_runs_a_workflow_directly_or_through_a_trigger() {
    let message = saved_workflow_message("/", WORKFLOW_ID, "Triage", "Nightly", false);
    assert!(prompt_runs_workflow(&message, WORKFLOW_ID));
    assert!(!prompt_runs_workflow(&message, &"b".repeat(32)));
    assert!(!prompt_runs_workflow(
        "Summarize overnight activity",
        WORKFLOW_ID
    ));
    let mut fields = empty_trigger_fields(TriggerSource::Jira);
    fields.scope = "ES".to_owned();
    fields.instructions = message;
    let config = TriggerConfig {
        source: TriggerSource::Jira,
        fields,
        task_session: false,
        worker: TriggerWorker {
            placement: WorkerPlacement::SameHost,
            agent_id: None,
            model: String::new(),
            effort: String::new(),
            permission_mode: String::new(),
        },
    };
    let context = TriggerConfigContext {
        session_link: "https://example.com/c/session".to_owned(),
        polling_interval_minutes: None,
        task_session_title: None,
        message_max_chars: None,
        workflow_ids: false,
    };
    let saved = encode_trigger_prompt(&config, &context);
    assert!(prompt_runs_workflow(&saved, WORKFLOW_ID));
}

fn proposal_entry(
    position: i64,
    created_at: i64,
    steps: &Value,
    description: &str,
) -> JournalEntry {
    entry(json!({
        "id": format!("plan-{position}"), "position": position, "created_at": created_at,
        "kind": "plan",
        "content": {"version": 2, "name": "Triage", "steps": steps, "description": description},
    }))
}

#[test]
fn a_newer_proposal_offers_its_steps_and_a_changed_description() {
    let workflow = WorkflowDetail::from_value(&fixture("workflow")).unwrap();
    let steps = json!([{"id": "explore", "name": "Explore", "depends_on": []}]);
    let newer = proposal_entry(3, 1_762_900_600, &steps, "Rerun it twice.");
    let proposal = plan_proposal(&workflow, &[newer], SourcePosition::Unknown).unwrap();
    assert!(proposal.has_changes);
    assert_eq!(proposal.new_description.as_deref(), Some("Rerun it twice."));
    let write = plan_save_description(&workflow, &proposal, false).unwrap();
    assert_eq!(
        write.description, workflow.workflow.description,
        "kept unless chosen"
    );
    assert_eq!(write.description_source, "plan-3");
    let chosen = plan_save_description(&workflow, &proposal, true).unwrap();
    assert_eq!(chosen.description, "Rerun it twice.");
    assert_eq!(chosen.expected_description, workflow.workflow.description);

    let older = proposal_entry(3, 1_762_900_100, &steps, "Rerun it twice.");
    let stale = plan_proposal(&workflow, &[older], SourcePosition::Unknown).unwrap();
    assert_eq!(
        stale.proposed_description, None,
        "an edit made since stands"
    );
    assert!(stale.has_changes, "its steps still differ");
    assert_eq!(plan_save_description(&workflow, &stale, true), None);
    assert!(plan_proposal(&workflow, &[], SourcePosition::Unknown).is_none());
}

#[test]
fn the_description_source_decides_which_proposals_are_newer() {
    let mut workflow = WorkflowDetail::from_value(&fixture("workflow")).unwrap();
    workflow.description_source = Some("plan-2".to_owned());
    let steps = json!([{"id": "explore", "name": "Explore", "depends_on": []}]);
    let plan = proposal_entry(5, 1, &steps, "New words.");
    assert_eq!(
        description_source_to_place(&workflow, std::slice::from_ref(&plan)).as_deref(),
        Some("plan-2")
    );
    let unplaced = plan_proposal(
        &workflow,
        std::slice::from_ref(&plan),
        SourcePosition::Unknown,
    );
    assert_eq!(unplaced.unwrap().proposed_description, None);
    let after = plan_proposal(
        &workflow,
        std::slice::from_ref(&plan),
        SourcePosition::At(4),
    );
    assert_eq!(
        after.unwrap().proposed_description.as_deref(),
        Some("New words.")
    );
    let before = plan_proposal(
        &workflow,
        std::slice::from_ref(&plan),
        SourcePosition::At(6),
    );
    assert_eq!(before.unwrap().proposed_description, None);
    let elsewhere = plan_proposal(&workflow, &[plan], SourcePosition::Elsewhere);
    assert_eq!(
        elsewhere.unwrap().proposed_description,
        None,
        "older than the last write"
    );
    let source = proposal_entry(2, 1, &steps, "Old");
    let mut held = source;
    held.id = "plan-2".to_owned();
    assert_eq!(description_source_to_place(&workflow, &[held]), None);
}

#[test]
fn the_same_steps_and_description_are_no_change() {
    let workflow = WorkflowDetail::from_value(&fixture("workflow")).unwrap();
    let steps = steps_json(&workflow.steps);
    let same = proposal_entry(1, 1_762_900_600, &steps, &workflow.workflow.description);
    let proposal = plan_proposal(&workflow, &[same], SourcePosition::Unknown).unwrap();
    assert!(!proposal.has_changes);
    assert_eq!(proposal.new_description, None);
    let empty = proposal_entry(2, 1_762_900_700, &json!([]), "Other");
    let proposal = plan_proposal(&workflow, &[empty], SourcePosition::Unknown).unwrap();
    assert!(!proposal.has_changes, "a plan without steps saves nothing");
}

#[test]
fn saving_an_edited_description_writes_only_new_wording() {
    assert_eq!(description_edit("  ", "Now", None), DescriptionEdit::Blank);
    assert_eq!(
        description_edit(" Now ", "Now", None),
        DescriptionEdit::KeepCurrent
    );
    assert_eq!(
        description_edit("Proposed", "Now", Some("Proposed")),
        DescriptionEdit::UseProposed
    );
    assert_eq!(
        description_edit(" Mine ", "Now", Some("Proposed")),
        DescriptionEdit::Write("Mine".to_owned())
    );
}

#[test]
fn steps_lay_out_by_dependency_with_centered_rows() {
    let steps = [
        step("explore", &[]),
        step("fix", &["explore"]),
        step("docs", &["explore"]),
        step("pr", &["fix", "docs"]),
    ];
    let layout = layout_steps(&steps);
    assert_eq!((layout.rows, layout.columns), (3, 2));
    let place = |id: &str| {
        let node = layout.nodes.iter().find(|node| node.id == id).unwrap();
        (node.number, node.row, node.half_column)
    };
    assert_eq!(place("explore"), (1, 0, 1));
    assert_eq!(place("fix"), (2, 1, 0));
    assert_eq!(place("docs"), (3, 1, 2));
    assert_eq!(place("pr"), (4, 2, 1));
}

#[test]
fn a_missing_dependency_is_ignored_and_a_cycle_survives() {
    let layout = layout_steps(&[step("a", &["ghost"]), step("b", &["a"])]);
    assert_eq!(layout.rows, 2);
    assert_eq!(layout.edges.len(), 1);
    let cycle = layout_steps(&[step("a", &["b"]), step("b", &["a"])]);
    let edges: Vec<String> = cycle
        .edges
        .iter()
        .map(|edge| format!("{}->{}", edge.from, edge.to))
        .collect();
    assert_eq!(edges, ["b->a", "a->b"]);
}

#[test]
fn redundant_arrows_are_left_out() {
    let steps = vec![
        step("explore", &[]),
        step("reproduce", &["explore"]),
        step("fix", &["explore", "reproduce", "reproduce"]),
        step("history", &["explore", "reproduce"]),
        step("pr", &["explore", "reproduce", "fix", "history"]),
    ];
    let mut expected = vec![
        "explore->reproduce",
        "reproduce->fix",
        "reproduce->history",
        "fix->pr",
        "history->pr",
    ];
    expected.sort_unstable();
    for ordered in [steps.clone(), steps.iter().rev().cloned().collect()] {
        let mut edges: Vec<String> = layout_steps(&ordered)
            .edges
            .iter()
            .map(|edge| format!("{}->{}", edge.from, edge.to))
            .collect();
        edges.sort_unstable();
        assert_eq!(edges, expected);
    }
}

#[test]
fn steps_serialize_as_the_server_takes_them() {
    let mut with_goal = step("a", &[]);
    with_goal.goal = Some("Do it".to_owned());
    assert_eq!(
        steps_json(&[with_goal, step("b", &["a"])]),
        json!([
            {"id": "a", "name": "a", "goal": "Do it", "depends_on": []},
            {"id": "b", "name": "b", "goal": null, "depends_on": ["a"]}
        ])
    );
}
