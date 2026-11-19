//! Saved workflows: the lists, a workflow's page, its runs and who it is shared with.
//!
//! Records mirror `omnigent_core::workflows`; what a run's row says, the plan's proposal, the
//! messages that run and save workflows and the steps' graph are computed there.

use omnigent_core::session_journal as journal;
use omnigent_core::workflows::{self as core, graph, proposal, runs};

use crate::automations::AutomationGrant;
use crate::client::ClientCore;
use crate::errors::CoreError;
use crate::session_journal::{GraphRevision, JournalEntry, PlanStep, StepState, TaskAction};

/// One of the caller's saved workflows, or one shared with them.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SavedWorkflow {
    /// Bare 32-character hex id.
    pub id: String,
    /// One line, unique among its owner's workflows.
    pub name: String,
    /// What it does and what a run needs.
    pub description: String,
    /// It has no saved plan and cannot run yet.
    pub is_draft: bool,
    /// Someone shared it with the caller, who may view, run and copy it.
    pub shared_with_me: bool,
    /// The owner's name, on one shared with the caller.
    pub owner_display_name: Option<String>,
    /// `false` when the server can't keep its grants.
    pub shareable: bool,
    /// When it was saved, in epoch seconds.
    pub created_at: i64,
    /// Its last write, in epoch seconds.
    pub updated_at: i64,
}

impl From<core::SavedWorkflow> for SavedWorkflow {
    fn from(workflow: core::SavedWorkflow) -> Self {
        Self {
            id: workflow.id,
            name: workflow.name,
            description: workflow.description,
            is_draft: workflow.is_draft,
            shared_with_me: workflow.shared_with_me,
            owner_display_name: workflow.owner_display_name,
            shareable: workflow.shareable,
            created_at: workflow.created_at,
            updated_at: workflow.updated_at,
        }
    }
}

impl From<SavedWorkflow> for core::SavedWorkflow {
    fn from(workflow: SavedWorkflow) -> Self {
        Self {
            id: workflow.id,
            name: workflow.name,
            description: workflow.description,
            is_draft: workflow.is_draft,
            shared_with_me: workflow.shared_with_me,
            owner_display_name: workflow.owner_display_name,
            shareable: workflow.shareable,
            created_at: workflow.created_at,
            updated_at: workflow.updated_at,
        }
    }
}

/// A saved workflow with its steps.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct WorkflowDetail {
    /// What a list shows of it.
    pub workflow: SavedWorkflow,
    /// The saved plan; empty for a draft.
    pub steps: Vec<PlanStep>,
    /// The conversation where its owner revises the plan.
    pub planning_session_id: Option<String>,
    /// The planning chat's proposal the description was saved from or kept over.
    pub description_source: Option<String>,
}

impl From<core::WorkflowDetail> for WorkflowDetail {
    fn from(detail: core::WorkflowDetail) -> Self {
        Self {
            workflow: detail.workflow.into(),
            steps: detail.steps.into_iter().map(Into::into).collect(),
            planning_session_id: detail.planning_session_id,
            description_source: detail.description_source,
        }
    }
}

impl From<WorkflowDetail> for core::WorkflowDetail {
    fn from(detail: WorkflowDetail) -> Self {
        Self {
            workflow: detail.workflow.into(),
            steps: detail.steps.into_iter().map(Into::into).collect(),
            planning_session_id: detail.planning_session_id,
            description_source: detail.description_source,
        }
    }
}

/// One page of workflows.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct WorkflowPage {
    /// The page's workflows.
    pub workflows: Vec<SavedWorkflow>,
    /// The cursor for the next page; `nil` on the last.
    pub next_cursor: Option<String>,
}

impl From<core::WorkflowPage> for WorkflowPage {
    fn from(page: core::WorkflowPage) -> Self {
        Self {
            workflows: page.workflows.into_iter().map(Into::into).collect(),
            next_cursor: page.next_cursor,
        }
    }
}

/// A run's session status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum RunSessionStatus {
    /// Not working.
    Idle,
    /// Working.
    Running,
    /// Failed.
    Failed,
}

/// Where a run's latest plan stands, counted by each step's newest status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RunProgress {
    /// Steps in the plan.
    pub total: u32,
    /// Steps in progress.
    pub started: u32,
    /// Steps done.
    pub done: u32,
    /// Steps waiting for the user.
    pub needs_input: u32,
    /// Steps that failed.
    pub failed: u32,
}

/// The session that started a workflow run.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RunStarter {
    /// Its id.
    pub session_id: String,
    /// Its title; empty when it has none yet.
    pub title: String,
}

/// One run of a saved workflow: a session that started it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts of the server's record, mirrored one to one"
)]
#[allow(
    clippy::use_self,
    reason = "UniFFI names the nested runs' record type from the field as written"
)]
pub struct WorkflowRun {
    /// The id of the plan entry that started the run.
    pub id: String,
    /// The saved workflow it follows; empty when the server didn't say.
    pub workflow_id: String,
    /// The graph's id or legacy position.
    pub plan_graph_revision: Option<GraphRevision>,
    /// The run's session.
    pub session_id: String,
    /// The session's title; empty when it has none yet.
    pub title: String,
    /// When the run's plan was written, in epoch seconds.
    pub started_at: i64,
    /// The session's current run, which can take actions.
    pub is_current: bool,
    /// The session's status.
    pub session_status: RunSessionStatus,
    /// Work outlives the session's turn.
    pub background_work_running: bool,
    /// The session's sandbox is still launching.
    pub sandbox_launching: bool,
    /// The session is archived.
    pub archived: bool,
    /// The steps, counted by their current status.
    pub progress: RunProgress,
    /// The latest plan's steps within this invocation.
    pub steps: Vec<PlanStep>,
    /// Each of those steps' newest status entry.
    pub statuses: Vec<JournalEntry>,
    /// Its workflow's name when the workflow is the caller's.
    pub workflow_name: Option<String>,
    /// The session that started it, when another session did.
    pub started_by: Option<RunStarter>,
    /// The first page of the workflow runs below this one.
    pub descendant_runs: Vec<WorkflowRun>,
    /// How many workflow runs are below this one, on every page.
    pub descendant_run_count: u32,
    /// Continues `descendant_runs`; `nil` when they are all here.
    pub descendant_runs_cursor: Option<String>,
    /// Some run below this one is working or waiting for input.
    pub descendant_runs_active: bool,
}

impl From<core::WorkflowRun> for WorkflowRun {
    fn from(run: core::WorkflowRun) -> Self {
        Self {
            id: run.id,
            workflow_id: run.workflow_id,
            plan_graph_revision: run.plan_graph_revision.map(Into::into),
            session_id: run.session_id,
            title: run.title,
            started_at: run.started_at,
            is_current: run.is_current,
            session_status: match run.session_status {
                core::RunSessionStatus::Idle => RunSessionStatus::Idle,
                core::RunSessionStatus::Running => RunSessionStatus::Running,
                core::RunSessionStatus::Failed => RunSessionStatus::Failed,
            },
            background_work_running: run.background_work_running,
            sandbox_launching: run.sandbox_launching,
            archived: run.archived,
            progress: RunProgress {
                total: run.progress.total,
                started: run.progress.started,
                done: run.progress.done,
                needs_input: run.progress.needs_input,
                failed: run.progress.failed,
            },
            steps: run.steps.into_iter().map(Into::into).collect(),
            statuses: run.statuses.into_iter().map(Into::into).collect(),
            workflow_name: run.workflow_name,
            started_by: run.started_by.map(|starter| RunStarter {
                session_id: starter.session_id,
                title: starter.title,
            }),
            descendant_runs: run.descendant_runs.into_iter().map(Into::into).collect(),
            descendant_run_count: run.descendant_run_count,
            descendant_runs_cursor: run.descendant_runs_cursor,
            descendant_runs_active: run.descendant_runs_active,
        }
    }
}

impl From<WorkflowRun> for core::WorkflowRun {
    fn from(run: WorkflowRun) -> Self {
        Self {
            id: run.id,
            workflow_id: run.workflow_id,
            plan_graph_revision: run.plan_graph_revision.map(Into::into),
            session_id: run.session_id,
            title: run.title,
            started_at: run.started_at,
            is_current: run.is_current,
            session_status: match run.session_status {
                RunSessionStatus::Idle => core::RunSessionStatus::Idle,
                RunSessionStatus::Running => core::RunSessionStatus::Running,
                RunSessionStatus::Failed => core::RunSessionStatus::Failed,
            },
            background_work_running: run.background_work_running,
            sandbox_launching: run.sandbox_launching,
            archived: run.archived,
            progress: core::RunProgress {
                total: run.progress.total,
                started: run.progress.started,
                done: run.progress.done,
                needs_input: run.progress.needs_input,
                failed: run.progress.failed,
            },
            steps: run.steps.into_iter().map(Into::into).collect(),
            statuses: run.statuses.into_iter().map(Into::into).collect(),
            workflow_name: run.workflow_name,
            started_by: run.started_by.map(|starter| core::RunStarter {
                session_id: starter.session_id,
                title: starter.title,
            }),
            descendant_runs: run.descendant_runs.into_iter().map(Into::into).collect(),
            descendant_run_count: run.descendant_run_count,
            descendant_runs_cursor: run.descendant_runs_cursor,
            descendant_runs_active: run.descendant_runs_active,
        }
    }
}

/// One page of runs.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct WorkflowRunPage {
    /// The page's runs, newest first.
    pub runs: Vec<WorkflowRun>,
    /// The cursor for the next page; `nil` on the last.
    pub next_cursor: Option<String>,
}

impl From<core::WorkflowRunPage> for WorkflowRunPage {
    fn from(page: core::WorkflowRunPage) -> Self {
        Self {
            runs: page.runs.into_iter().map(Into::into).collect(),
            next_cursor: page.next_cursor,
        }
    }
}

/// How a run's row looks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum RunStateKind {
    /// A step waits for the user.
    Waiting,
    /// Every step finished.
    Done,
    /// The session works on it.
    Running,
    /// A step or the session failed.
    Failed,
    /// It stopped partway.
    Stopped,
}

impl From<runs::RunStateKind> for RunStateKind {
    fn from(kind: runs::RunStateKind) -> Self {
        match kind {
            runs::RunStateKind::Waiting => Self::Waiting,
            runs::RunStateKind::Done => Self::Done,
            runs::RunStateKind::Running => Self::Running,
            runs::RunStateKind::Failed => Self::Failed,
            runs::RunStateKind::Stopped => Self::Stopped,
        }
    }
}

impl From<RunStateKind> for runs::RunStateKind {
    fn from(kind: RunStateKind) -> Self {
        match kind {
            RunStateKind::Waiting => Self::Waiting,
            RunStateKind::Done => Self::Done,
            RunStateKind::Running => Self::Running,
            RunStateKind::Failed => Self::Failed,
            RunStateKind::Stopped => Self::Stopped,
        }
    }
}

/// A run's state and its one line ("2 of 5 done").
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RunState {
    /// The kind, for its glyph.
    pub kind: RunStateKind,
    /// The line.
    pub label: String,
}

/// What a plan's run button shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum PlanRunControl {
    /// Continue the plan.
    Play,
    /// Stop the plan.
    Stop,
    /// Stop was asked; the run is winding down.
    Stopping,
}

/// One of a run's steps, for its strip and its graph.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RunStep {
    /// The step's id.
    pub id: String,
    /// Its place in the plan, from 1.
    pub number: u32,
    /// Its name.
    pub name: String,
    /// Where it stands.
    pub state: StepState,
    /// Its description in Markdown.
    pub goal: Option<String>,
    /// What its menu offers; `nil` for none.
    pub action: Option<TaskAction>,
}

/// A saved workflow's run read back from a message or an automation's instructions.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SavedWorkflowRun {
    /// The workflow's id.
    pub id: String,
    /// Its name when the message was written.
    pub name: String,
    /// The run's details; empty when there are none.
    pub details: String,
}

/// Where the description's source proposal sits in the planning chat's journal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SourcePosition {
    /// Not placed yet.
    Unknown,
    /// It came from another planning chat.
    Elsewhere,
    /// Its position.
    At {
        /// The position.
        position: i64,
    },
}

/// The planning chat's latest proposal for a workflow.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PlanProposal {
    /// The plan entry.
    pub entry_id: String,
    /// Its steps.
    pub steps: Vec<PlanStep>,
    /// Its description, when newer than the one the workflow's came from.
    pub proposed_description: Option<String>,
    /// A different description Save plan offers to apply.
    pub new_description: Option<String>,
    /// Save plan changes the workflow.
    pub has_changes: bool,
}

impl From<proposal::PlanProposal> for PlanProposal {
    fn from(proposal: proposal::PlanProposal) -> Self {
        Self {
            entry_id: proposal.entry_id,
            steps: proposal.steps.into_iter().map(Into::into).collect(),
            proposed_description: proposal.proposed_description,
            new_description: proposal.new_description,
            has_changes: proposal.has_changes,
        }
    }
}

impl From<PlanProposal> for proposal::PlanProposal {
    fn from(proposal: PlanProposal) -> Self {
        Self {
            entry_id: proposal.entry_id,
            steps: proposal.steps.into_iter().map(Into::into).collect(),
            proposed_description: proposal.proposed_description,
            new_description: proposal.new_description,
            has_changes: proposal.has_changes,
        }
    }
}

/// A description written with a plan, applied only while the stored one is still the expected.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct DescriptionWrite {
    /// The description to store.
    pub description: String,
    /// The description the page showed.
    pub expected_description: String,
    /// The proposal it was saved from or kept over.
    pub description_source: String,
}

/// What Save does with an edited description.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum DescriptionEdit {
    /// It is blank.
    Blank,
    /// The current wording, unedited.
    KeepCurrent,
    /// The proposal's wording, unedited.
    UseProposed,
    /// Store this description.
    Write {
        /// The trimmed description.
        description: String,
    },
}

/// One step's box in the graph.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct StepNode {
    /// The step's id.
    pub id: String,
    /// Its place in the workflow, from 1.
    pub number: u32,
    /// Its row, from 0.
    pub row: u32,
    /// Its left edge in half columns.
    pub half_column: u32,
}

/// An arrow from a step to one that waits for it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct StepEdge {
    /// The step waited for.
    pub from: String,
    /// The step that waits.
    pub to: String,
}

/// The steps laid out top to bottom by dependency.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct StepsLayout {
    /// One per step, in the workflow's order.
    pub nodes: Vec<StepNode>,
    /// The dependencies no other path already implies.
    pub edges: Vec<StepEdge>,
    /// How many rows.
    pub rows: u32,
    /// How many columns the widest row has.
    pub columns: u32,
}

fn core_steps(steps: Vec<PlanStep>) -> Vec<journal::PlanStep> {
    steps.into_iter().map(Into::into).collect()
}

fn core_entries(entries: Vec<JournalEntry>) -> Vec<journal::JournalEntry> {
    entries.into_iter().map(Into::into).collect()
}

/// The message that runs the workflow skill for `description`, `/` or `$` first.
#[uniffi::export]
#[must_use]
pub fn workflow_message(
    skill_prefix: String,
    description: String,
    review_plan_first: bool,
) -> String {
    core::workflow_message(&skill_prefix, &description, review_plan_first)
}

/// The message that runs one of the caller's saved workflows by id.
#[uniffi::export]
#[must_use]
pub fn saved_workflow_message(
    skill_prefix: String,
    workflow_id: String,
    workflow_name: String,
    details: String,
    review_plan_first: bool,
) -> String {
    core::saved_workflow_message(
        &skill_prefix,
        &workflow_id,
        &workflow_name,
        &details,
        review_plan_first,
    )
}

/// The message that saves the session's plan as a workflow named `name`.
#[uniffi::export]
#[must_use]
pub fn save_workflow_message(skill_prefix: String, name: String) -> String {
    core::save_workflow_message(&skill_prefix, &name)
}

/// The first message of a session that runs a saved workflow.
#[uniffi::export]
#[must_use]
pub fn run_saved_workflow_prompt(
    workflow_id: String,
    workflow_name: String,
    details: String,
    review_plan_first: bool,
) -> String {
    core::run_saved_workflow_prompt(&workflow_id, &workflow_name, &details, review_plan_first)
}

/// The planning chat's first message for `workflow`.
#[uniffi::export]
#[must_use]
pub fn edit_workflow_plan_prompt(workflow: WorkflowDetail) -> String {
    core::edit_workflow_plan_prompt(&workflow.into())
}

/// The saved workflow a message runs, directly or inside a trigger's prompt.
#[uniffi::export]
#[must_use]
pub fn parse_saved_workflow_message(text: String) -> Option<SavedWorkflowRun> {
    core::parse_saved_workflow_message(&text).map(|run| SavedWorkflowRun {
        id: run.id,
        name: run.name,
        details: run.details,
    })
}

/// Whether an automation with `prompt` runs the saved workflow `workflow_id`.
#[uniffi::export]
#[must_use]
pub fn prompt_runs_workflow(prompt: String, workflow_id: String) -> bool {
    core::prompt_runs_workflow(&prompt, &workflow_id)
}

/// The workflows whose name or description contains `query`.
#[uniffi::export]
#[must_use]
pub fn matching_workflows(workflows: Vec<SavedWorkflow>, query: String) -> Vec<SavedWorkflow> {
    let workflows: Vec<core::SavedWorkflow> = workflows.into_iter().map(Into::into).collect();
    core::matching_workflows(&workflows, &query)
        .into_iter()
        .map(Into::into)
        .collect()
}

/// The workflows Run a workflow offers: saved plans whose name contains `query`.
#[uniffi::export]
#[must_use]
pub fn runnable_workflows(workflows: Vec<SavedWorkflow>, query: String) -> Vec<SavedWorkflow> {
    let workflows: Vec<core::SavedWorkflow> = workflows.into_iter().map(Into::into).collect();
    core::runnable_workflows(&workflows, &query)
        .into_iter()
        .map(Into::into)
        .collect()
}

/// Whether `name` is already one of the caller's workflows' names.
#[uniffi::export]
#[must_use]
pub fn workflow_name_taken(taken: Vec<String>, name: String) -> bool {
    core::workflow_name_taken(&taken, &name)
}

/// The session's turn, delegated work, background work, or its sandbox launch.
#[uniffi::export]
#[must_use]
pub fn is_workflow_run_working(run: WorkflowRun) -> bool {
    runs::is_run_working(&run.into())
}

/// Where a run stands, for its row.
#[uniffi::export]
#[must_use]
pub fn describe_workflow_run(run: WorkflowRun, session_working: bool) -> RunState {
    let state = runs::describe_run(&run.into(), session_working);
    RunState {
        kind: state.kind.into(),
        label: state.label,
    }
}

/// Each of the run's steps, where it stands and what its menu offers.
#[uniffi::export]
#[must_use]
pub fn workflow_run_steps(
    run: WorkflowRun,
    session_working: bool,
    stopping: bool,
    owned: bool,
) -> Vec<RunStep> {
    runs::run_step_actions(&run.into(), session_working, stopping, owned)
        .into_iter()
        .zip(1_u32..)
        .map(|((item, action), number)| RunStep {
            id: item.step.id,
            number,
            name: item.step.name,
            state: item.state.into(),
            goal: item.step.goal,
            action: action.map(Into::into),
        })
        .collect()
}

const fn control(control: runs::PlanRunControl) -> PlanRunControl {
    match control {
        runs::PlanRunControl::Play => PlanRunControl::Play,
        runs::PlanRunControl::Stop => PlanRunControl::Stop,
        runs::PlanRunControl::Stopping => PlanRunControl::Stopping,
    }
}

/// The run button a run's row shows; `nil` for none.
#[uniffi::export]
#[must_use]
pub fn workflow_run_control(
    run: WorkflowRun,
    session_working: bool,
    stopping: bool,
    owned: bool,
) -> Option<PlanRunControl> {
    runs::run_control(&run.into(), session_working, stopping, owned).map(control)
}

/// The session a run names under "Started by"; none below the session that started it.
#[uniffi::export]
#[must_use]
pub fn workflow_run_starter_shown(
    run: WorkflowRun,
    parent_session_id: Option<String>,
) -> Option<RunStarter> {
    runs::run_starter_shown(&run.into(), parent_session_id.as_deref()).map(|starter| RunStarter {
        session_id: starter.session_id,
        title: starter.title,
    })
}

/// A run's descendants from its first page and later pages, each run once.
#[uniffi::export]
#[must_use]
pub fn merge_descendant_runs(run: WorkflowRun, more: Vec<WorkflowRun>) -> Vec<WorkflowRun> {
    let more: Vec<core::WorkflowRun> = more.into_iter().map(Into::into).collect();
    runs::merge_descendant_runs(&run.into(), &more)
        .into_iter()
        .map(Into::into)
        .collect()
}

/// Whether "Ran N workflows" starts open.
#[uniffi::export]
#[must_use]
pub fn descendant_runs_active(run: WorkflowRun, descendants: Vec<WorkflowRun>) -> bool {
    let descendants: Vec<core::WorkflowRun> = descendants.into_iter().map(Into::into).collect();
    runs::descendants_active(&run.into(), &descendants)
}

/// "Ran 3 workflows".
#[uniffi::export]
#[must_use]
pub fn ran_workflows_label(count: u32) -> String {
    runs::ran_workflows_label(count)
}

/// The step state a run's glyph borrows from the Tasks tab.
#[uniffi::export]
#[must_use]
pub fn workflow_run_glyph_state(kind: RunStateKind) -> StepState {
    runs::run_glyph_state(kind.into()).into()
}

/// The control the Tasks tab's plan shows over `entries`, the journal read.
#[uniffi::export]
#[must_use]
pub fn plan_run_control(
    entries: Vec<JournalEntry>,
    session_working: bool,
    awaiting_user: bool,
    stopping: bool,
) -> Option<PlanRunControl> {
    let entries = core_entries(entries);
    let plan = journal::current_plan(&entries)?;
    let progress =
        journal::tasks::step_progress(&plan.steps, &entries, session_working, awaiting_user);
    let revision = journal::plan_graph_revision(&entries);
    runs::plan_run_control(
        &progress,
        &entries,
        session_working,
        revision.as_ref(),
        stopping,
    )
    .map(control)
}

/// The current plan's steps among `entries`; empty without a plan.
#[uniffi::export]
#[must_use]
pub fn journal_plan_steps(entries: Vec<JournalEntry>) -> Vec<PlanStep> {
    let entries = core_entries(entries);
    journal::current_plan(&entries)
        .map(|plan| plan.steps.iter().cloned().map(Into::into).collect())
        .unwrap_or_default()
}

/// The planning chat's current proposal for `workflow`; `nil` without one.
#[uniffi::export]
#[must_use]
pub fn workflow_plan_proposal(
    workflow: WorkflowDetail,
    entries: Vec<JournalEntry>,
    source_position: SourcePosition,
) -> Option<PlanProposal> {
    let position = match source_position {
        SourcePosition::Unknown => proposal::SourcePosition::Unknown,
        SourcePosition::Elsewhere => proposal::SourcePosition::Elsewhere,
        SourcePosition::At { position } => proposal::SourcePosition::At(position),
    };
    proposal::plan_proposal(&workflow.into(), &core_entries(entries), position).map(Into::into)
}

/// The entry to place with [`SourcePosition`], when the read journal doesn't hold it.
#[uniffi::export]
#[must_use]
pub fn description_source_to_place(
    workflow: WorkflowDetail,
    entries: Vec<JournalEntry>,
) -> Option<String> {
    proposal::description_source_to_place(&workflow.into(), &core_entries(entries))
}

/// What Save plan writes with the proposal's description; `nil` when it offers none.
#[uniffi::export]
#[must_use]
pub fn plan_save_description(
    workflow: WorkflowDetail,
    proposal: PlanProposal,
    use_proposed: bool,
) -> Option<DescriptionWrite> {
    proposal::plan_save_description(&workflow.into(), &proposal.into(), use_proposed).map(|write| {
        DescriptionWrite {
            description: write.description,
            expected_description: write.expected_description,
            description_source: write.description_source,
        }
    })
}

/// What saving an edited description does.
#[uniffi::export]
#[must_use]
pub fn workflow_description_edit(
    draft: String,
    current: String,
    proposed: Option<String>,
) -> DescriptionEdit {
    match proposal::description_edit(&draft, &current, proposed.as_deref()) {
        proposal::DescriptionEdit::Blank => DescriptionEdit::Blank,
        proposal::DescriptionEdit::KeepCurrent => DescriptionEdit::KeepCurrent,
        proposal::DescriptionEdit::UseProposed => DescriptionEdit::UseProposed,
        proposal::DescriptionEdit::Write(description) => DescriptionEdit::Write { description },
    }
}

/// The steps laid out as a graph.
#[uniffi::export]
#[must_use]
pub fn layout_workflow_steps(steps: Vec<PlanStep>) -> StepsLayout {
    let layout = graph::layout_steps(&core_steps(steps));
    StepsLayout {
        nodes: layout
            .nodes
            .into_iter()
            .map(|node| StepNode {
                id: node.id,
                number: node.number,
                row: node.row,
                half_column: node.half_column,
            })
            .collect(),
        edges: layout
            .edges
            .into_iter()
            .map(|edge| StepEdge {
                from: edge.from,
                to: edge.to,
            })
            .collect(),
        rows: layout.rows,
        columns: layout.columns,
    }
}

fn grants(grants: Vec<omnigent_core::automations::AutomationGrant>) -> Vec<AutomationGrant> {
    grants
        .into_iter()
        .map(|grant| AutomationGrant {
            user_id: grant.user_id,
            display_name: grant.display_name,
        })
        .collect()
}

#[uniffi::export]
impl ClientCore {
    /// One page of the caller's workflows, drafts included.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn workflows(&self, after: Option<String>) -> Result<WorkflowPage, CoreError> {
        self.sessions()
            .workflows(after.as_deref())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// One page of the workflows shared with the caller.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn shared_workflows(&self, after: Option<String>) -> Result<WorkflowPage, CoreError> {
        self.sessions()
            .shared_workflows(after.as_deref())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// A workflow with its steps.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors (`HttpStatus` 404 for one
    /// that is gone) and `MalformedResponse`.
    pub async fn workflow(&self, id: String) -> Result<WorkflowDetail, CoreError> {
        self.sessions()
            .workflow(&id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Saves a draft with no steps.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidInput`, and the write errors (`Rejected` 409 for a
    /// name in use).
    pub async fn create_workflow_draft(
        &self,
        name: String,
        description: String,
    ) -> Result<WorkflowDetail, CoreError> {
        self.sessions()
            .create_workflow_draft(&name, &description)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Copies a workflow's saved plan into a new one of the caller's.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read and write errors.
    pub async fn clone_workflow(&self, id: String) -> Result<WorkflowDetail, CoreError> {
        self.sessions()
            .clone_workflow(&id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Applies a reviewed proposal's steps and, when given, its description.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` and the write errors.
    pub async fn save_workflow_plan(
        &self,
        id: String,
        steps: Vec<PlanStep>,
        description: Option<DescriptionWrite>,
    ) -> Result<WorkflowDetail, CoreError> {
        let description = description.map(|write| proposal::DescriptionWrite {
            description: write.description,
            expected_description: write.expected_description,
            description_source: write.description_source,
        });
        self.sessions()
            .save_workflow_plan(&id, &core_steps(steps), description.as_ref())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Replaces the description with the user's own wording.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, `InvalidInput` and the write errors.
    pub async fn save_workflow_description(
        &self,
        id: String,
        description: String,
    ) -> Result<WorkflowDetail, CoreError> {
        self.sessions()
            .save_workflow_description(&id, &description)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Keeps `session_id` as the workflow's planning chat.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` and the write errors.
    pub async fn set_workflow_planning_session(
        &self,
        id: String,
        session_id: String,
    ) -> Result<WorkflowDetail, CoreError> {
        self.sessions()
            .set_workflow_planning_session(&id, &session_id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Deletes one of the caller's workflows.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` and the write errors.
    pub async fn delete_workflow(&self, id: String) -> Result<(), CoreError> {
        self.sessions()
            .delete_workflow(&id)
            .await
            .map_err(CoreError::from)
    }

    /// One page of a workflow's runs, newest first; only `session_id`'s when given.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors and `MalformedResponse`.
    pub async fn workflow_runs(
        &self,
        id: String,
        before: Option<String>,
        session_id: Option<String>,
    ) -> Result<WorkflowRunPage, CoreError> {
        self.sessions()
            .workflow_runs(&id, before.as_deref(), session_id.as_deref())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// The workflow runs below a run, after `after`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors and `MalformedResponse`.
    pub async fn workflow_run_descendants(
        &self,
        workflow_id: String,
        run_id: String,
        session_id: String,
        after: Option<String>,
    ) -> Result<WorkflowRunPage, CoreError> {
        self.sessions()
            .workflow_run_descendants(&workflow_id, &run_id, &session_id, after.as_deref())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Where a journal entry sits in a session's journal; `nil` when it doesn't hold it.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors and `MalformedResponse`.
    pub async fn journal_entry_position(
        &self,
        session_id: String,
        entry_id: String,
    ) -> Result<Option<i64>, CoreError> {
        self.sessions()
            .journal_entry_position(&session_id, &entry_id)
            .await
            .map_err(CoreError::from)
    }

    /// Everyone a workflow is shared with; only its owner may list them.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors, `MalformedResponse` and
    /// `InvalidPagination`.
    pub async fn workflow_grants(&self, id: String) -> Result<Vec<AutomationGrant>, CoreError> {
        self.sessions()
            .workflow_grants(&id)
            .await
            .map(grants)
            .map_err(CoreError::from)
    }

    /// Shares a workflow with `user_id`, who may view, run and copy it. Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` and the write errors.
    pub async fn grant_workflow_access(
        &self,
        id: String,
        user_id: String,
    ) -> Result<(), CoreError> {
        self.sessions()
            .grant_workflow_access(&id, &user_id)
            .await
            .map_err(CoreError::from)
    }

    /// Sends `text` to a workflow run's session, limited to that run (Stop and Continue on its
    /// row). Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the write errors and `MessageDenied`.
    pub async fn send_workflow_run_message(
        &self,
        session_id: String,
        workflow_run_id: String,
        text: String,
    ) -> Result<(), CoreError> {
        self.sessions()
            .send_workflow_run_message(&session_id, &workflow_run_id, &text)
            .await
            .map(|_| ())
            .map_err(CoreError::from)
    }

    /// Stops sharing a workflow with `user_id`. Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` and the write errors.
    pub async fn revoke_workflow_access(
        &self,
        id: String,
        user_id: String,
    ) -> Result<(), CoreError> {
        self.sessions()
            .revoke_workflow_access(&id, &user_id)
            .await
            .map_err(CoreError::from)
    }
}

#[cfg(test)]
#[path = "workflows_tests.rs"]
mod tests;
