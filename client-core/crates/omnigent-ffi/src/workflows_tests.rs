//! The workflow records and rules across the FFI, over the fake host.

use super::*;
use crate::session_journal::TaskAction;
use crate::test_support::{connected, json as reply};

const ID: &str = "0123456789abcdef0123456789abcdef";

fn detail_body(steps: &str) -> String {
    format!(
        r#"{{"id":"{ID}","name":"Triage","description":"Rerun the suite","created_at":1,
            "updated_at":10,"is_draft":false,"viewer_role":"owner","steps":{steps},
            "planning_session_id":null}}"#
    )
}

fn step(id: &str, depends_on: &[&str]) -> PlanStep {
    PlanStep {
        id: id.to_owned(),
        name: id.to_uppercase(),
        goal: None,
        depends_on: depends_on.iter().map(|id| (*id).to_owned()).collect(),
    }
}

fn status(position: i64, step: &str, status: crate::session_journal::StepStatus) -> JournalEntry {
    JournalEntry {
        id: format!("s{position}"),
        position,
        created_at: 100 + position,
        scheduled_task_run_id: None,
        step: Some(step.to_owned()),
        kind: "status".to_owned(),
        workflow_id: None,
        status: Some(status),
        text: None,
        name: None,
        steps: vec![],
        version: None,
        graph_revision: Some(GraphRevision::Text {
            value: "g".to_owned(),
        }),
        description: None,
    }
}

fn run() -> WorkflowRun {
    WorkflowRun {
        id: "r".repeat(32),
        workflow_id: ID.to_owned(),
        plan_graph_revision: Some(GraphRevision::Text {
            value: "g".to_owned(),
        }),
        session_id: "s".repeat(32),
        title: "Triage uploads".to_owned(),
        started_at: 1,
        is_current: true,
        session_status: RunSessionStatus::Running,
        background_work_running: false,
        sandbox_launching: false,
        archived: false,
        progress: RunProgress {
            total: 2,
            started: 1,
            done: 1,
            needs_input: 0,
            failed: 0,
        },
        steps: vec![step("a", &[]), step("b", &["a"])],
        statuses: vec![
            status(1, "a", crate::session_journal::StepStatus::Done),
            status(2, "b", crate::session_journal::StepStatus::Started),
        ],
        workflow_name: Some("Triage".to_owned()),
        started_by: None,
        descendant_runs: vec![],
        descendant_run_count: 0,
        descendant_runs_cursor: None,
        descendant_runs_active: false,
    }
}

#[test]
fn a_workflow_and_its_runs_cross_with_their_steps_and_statuses() {
    let mut harness = connected();
    harness.http.route(
        &format!("/v1/workflows/{ID}"),
        reply(
            200,
            &detail_body(r#"[{"id":"a","name":"A","goal":"Do A","depends_on":[]}]"#),
        ),
    );
    let detail = harness
        .call(|core| async move { core.workflow(ID.to_owned()).await })
        .unwrap();
    assert_eq!(detail.workflow.name, "Triage");
    assert_eq!(detail.steps[0].goal.as_deref(), Some("Do A"));
    let runs_body = format!(
        r#"{{"data":[{{"id":"{run}","workflow_id":"{ID}","session_id":"{session}",
            "title":"T","started_at":5,"session_status":"running","is_current":true,
            "progress":{{"total":1,"done":0}},
            "statuses":[{{"id":"x","position":1,"created_at":2,"step":"a","kind":"status",
                         "content":{{"status":"started"}}}}],
            "steps":[{{"id":"a","name":"A","depends_on":[]}}]}}],"next_cursor":null}}"#,
        run = "r".repeat(32),
        session = "s".repeat(32)
    );
    harness
        .http
        .route(&format!("/v1/workflows/{ID}/runs"), reply(200, &runs_body));
    let page = harness
        .call(|core| async move { core.workflow_runs(ID.to_owned(), None, None).await })
        .unwrap();
    let run = &page.runs[0];
    assert_eq!(run.session_status, RunSessionStatus::Running);
    assert_eq!(
        run.statuses[0].status,
        Some(crate::session_journal::StepStatus::Started)
    );
    assert!(is_workflow_run_working(run.clone()));
    let steps = workflow_run_steps(run.clone(), true, false, true);
    assert_eq!(steps[0].state, StepState::Running);
    assert_eq!(steps[0].number, 1);
    assert_eq!(steps[0].action, Some(TaskAction::Stop));
    let stopping = workflow_run_steps(run.clone(), true, true, true);
    assert_eq!(
        stopping[0].action, None,
        "a stopping run offers no second Stop"
    );
    let theirs = workflow_run_steps(run.clone(), true, false, false);
    assert_eq!(theirs[0].action, None, "only the owner acts");
}

#[test]
fn a_runs_row_says_where_it_stands_and_what_its_button_does() {
    let working = run();
    assert_eq!(
        describe_workflow_run(working.clone(), true),
        RunState {
            kind: RunStateKind::Running,
            label: "1 of 2 done".to_owned()
        }
    );
    assert_eq!(
        workflow_run_control(working.clone(), true, false, true),
        Some(PlanRunControl::Stop)
    );
    assert_eq!(
        workflow_run_control(working.clone(), true, true, true),
        Some(PlanRunControl::Stopping)
    );
    assert_eq!(
        workflow_run_control(working.clone(), false, false, true),
        Some(PlanRunControl::Play)
    );
    assert_eq!(
        workflow_run_glyph_state(RunStateKind::Stopped),
        StepState::Stopped
    );
    assert_eq!(ran_workflows_label(2), "Ran 2 workflows");
    let mut nested = working.clone();
    nested.started_by = Some(RunStarter {
        session_id: "p".repeat(32),
        title: "Parent".to_owned(),
    });
    assert!(workflow_run_starter_shown(nested.clone(), Some("p".repeat(32))).is_none());
    assert!(workflow_run_starter_shown(nested, None).is_some());
    assert!(!descendant_runs_active(
        WorkflowRun {
            session_status: RunSessionStatus::Idle,
            ..working.clone()
        },
        vec![]
    ));
    assert_eq!(
        merge_descendant_runs(working.clone(), vec![working]).len(),
        1
    );
}

#[test]
fn the_tasks_tabs_control_reads_the_journal_plan() {
    let plan = JournalEntry {
        id: "p".to_owned(),
        position: 0,
        created_at: 100,
        scheduled_task_run_id: None,
        step: None,
        kind: "plan".to_owned(),
        workflow_id: None,
        status: None,
        text: None,
        name: Some("Ship".to_owned()),
        steps: vec![step("a", &[]), step("b", &["a"])],
        version: Some(1),
        graph_revision: None,
        description: None,
    };
    let started = status(1, "a", crate::session_journal::StepStatus::Started);
    let entries = vec![plan, started];
    assert_eq!(
        plan_run_control(entries.clone(), true, false, false),
        Some(PlanRunControl::Stop)
    );
    assert_eq!(
        plan_run_control(entries.clone(), false, false, false),
        Some(PlanRunControl::Play)
    );
    assert_eq!(plan_run_control(vec![], true, false, false), None);
    let steps = journal_plan_steps(entries);
    assert_eq!(steps.len(), 2);
    let layout = layout_workflow_steps(steps);
    assert_eq!((layout.rows, layout.columns), (2, 1));
    assert_eq!(layout.edges[0].from, "a");
    assert_eq!(journal_plan_steps(vec![]).len(), 0);
}

#[test]
fn a_proposal_offers_its_description_and_save_plan_writes_the_choice() {
    let workflow = WorkflowDetail {
        workflow: SavedWorkflow {
            id: ID.to_owned(),
            name: "Triage".to_owned(),
            description: "Old".to_owned(),
            is_draft: false,
            shared_with_me: false,
            owner_display_name: None,
            shareable: true,
            created_at: 1,
            updated_at: 10,
        },
        steps: vec![step("a", &[])],
        planning_session_id: None,
        description_source: None,
    };
    let plan = JournalEntry {
        id: "plan".to_owned(),
        position: 3,
        created_at: 20,
        scheduled_task_run_id: None,
        step: None,
        kind: "plan".to_owned(),
        workflow_id: None,
        status: None,
        text: None,
        name: None,
        steps: vec![step("a", &[]), step("b", &["a"])],
        version: Some(2),
        graph_revision: None,
        description: Some("New".to_owned()),
    };
    let proposal = workflow_plan_proposal(
        workflow.clone(),
        vec![plan.clone()],
        SourcePosition::Unknown,
    )
    .unwrap();
    assert!(proposal.has_changes);
    assert_eq!(proposal.new_description.as_deref(), Some("New"));
    let write = plan_save_description(workflow.clone(), proposal, true).unwrap();
    assert_eq!(write.description, "New");
    assert_eq!(write.description_source, "plan");
    assert_eq!(
        description_source_to_place(workflow, vec![plan]),
        None,
        "no source to place"
    );
    assert_eq!(
        workflow_description_edit(" Mine ".to_owned(), "Old".to_owned(), None),
        DescriptionEdit::Write {
            description: "Mine".to_owned()
        }
    );
}

#[test]
fn messages_and_lists_cross_unchanged() {
    let message = saved_workflow_message(
        "/".to_owned(),
        ID.to_owned(),
        "Triage".to_owned(),
        "Uploads".to_owned(),
        false,
    );
    let parsed = parse_saved_workflow_message(message.clone()).unwrap();
    assert_eq!(
        (parsed.id.as_str(), parsed.details.as_str()),
        (ID, "Uploads")
    );
    assert!(prompt_runs_workflow(message, ID.to_owned()));
    assert_eq!(
        save_workflow_message("$".to_owned(), "Triage".to_owned()),
        "$save-workflow Save this session's plan as a workflow named \"Triage\"."
    );
    assert!(workflow_message("/".to_owned(), "Do".to_owned(), true).contains("review the plan"));
    assert!(
        run_saved_workflow_prompt(ID.to_owned(), "T".to_owned(), String::new(), false)
            .starts_with("Use the workflow skill")
    );
    let saved = SavedWorkflow {
        id: ID.to_owned(),
        name: "Triage".to_owned(),
        description: "Rerun".to_owned(),
        is_draft: true,
        shared_with_me: false,
        owner_display_name: None,
        shareable: true,
        created_at: 0,
        updated_at: 0,
    };
    assert_eq!(
        matching_workflows(vec![saved.clone()], "rerun".to_owned()).len(),
        1
    );
    assert_eq!(runnable_workflows(vec![saved], String::new()).len(), 0);
    assert!(workflow_name_taken(
        vec!["Triage".to_owned()],
        "Triage".to_owned()
    ));
}

#[test]
fn writes_and_grants_reach_their_routes() {
    let mut harness = connected();
    harness
        .http
        .route("/v1/workflows", reply(200, &detail_body("[]")));
    harness
        .call(|core| async move {
            core.create_workflow_draft("Triage".to_owned(), "Rerun".to_owned())
                .await
        })
        .unwrap();
    harness.http.route(
        &format!("/v1/workflows/{ID}/permissions"),
        reply(
            200,
            r#"{"permissions":[{"user_id":"ada","display_name":"Ada","level":1}],"next_cursor":null}"#,
        ),
    );
    let grants = harness
        .call(|core| async move { core.workflow_grants(ID.to_owned()).await })
        .unwrap();
    assert_eq!(grants[0].display_name, "Ada");
    let lines = harness.http.lines();
    assert!(lines.contains(&"POST /v1/workflows".to_owned()));
    assert!(lines.contains(&format!("GET /v1/workflows/{ID}/permissions")));
}
