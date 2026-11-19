//! Where a workflow's runs stand, for their rows (`web/src/lib/workflowRuns.ts` and
//! `web/src/shell/PlanRunButton.tsx`).

use super::{RunProgress, RunSessionStatus, RunStarter, WorkflowRun};
use crate::session_journal::tasks::{
    StepProgress, StepState, is_plan_complete, paused_label_at, step_progress,
};
use crate::session_journal::view::{TaskAction, TasksContext, task_action};
use crate::session_journal::{GraphRevision, JournalEntry, plan_graph_revision};

/// The run is starting: its session waits on a sandbox that is still launching.
#[must_use]
pub const fn is_run_launching(run: &WorkflowRun) -> bool {
    run.is_current && run.sandbox_launching
}

/// The session's turn, delegated work, work left running between turns, or its sandbox launch.
#[must_use]
pub fn is_run_working(run: &WorkflowRun) -> bool {
    is_run_launching(run)
        || (run.is_current
            && (run.session_status == RunSessionStatus::Running || run.background_work_running))
}

/// Where each of the run's steps stands, as the Tasks tab works it out.
#[must_use]
pub fn run_step_progress(run: &WorkflowRun, session_working: bool) -> Vec<StepProgress> {
    step_progress(
        &run.steps,
        &run.statuses,
        run.is_current && session_working,
        false,
    )
}

/// Each of a run's steps with the action its menu offers (`useRunTaskMenus`): only the owner's
/// current, unarchived run takes actions, and a run already stopping offers no Stop.
#[must_use]
pub fn run_step_actions(
    run: &WorkflowRun,
    session_working: bool,
    stopping: bool,
    owned: bool,
) -> Vec<(StepProgress, Option<TaskAction>)> {
    let context = TasksContext {
        session_working: run.is_current && session_working,
        awaiting_user: false,
        can_send: owned && run.is_current && !run.archived,
        journal_read: true,
        stopping,
    };
    run_step_progress(run, session_working)
        .into_iter()
        .map(|item| {
            let action = task_action(&item, context);
            (item, action)
        })
        .collect()
}

/// How a run's row looks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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

/// A run's state and its one line ("2 of 5 done").
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunState {
    /// The kind, for its glyph.
    pub kind: RunStateKind,
    /// The line.
    pub label: String,
}

/// Where a run stands, for its row (`describeWorkflowRun`).
///
/// A finished run first, then a question for the user; a working session shows its progress;
/// otherwise a failed step or session says so, and a run that stopped partway shows its count.
#[must_use]
pub fn describe_run(run: &WorkflowRun, session_working: bool) -> RunState {
    let RunProgress {
        total,
        done,
        needs_input,
        failed,
        ..
    } = run.progress;
    let counted = format!("{done} of {total} done");
    let unknown_active_plan =
        run.plan_graph_revision.is_none() && run.is_current && session_working;
    let complete = run.plan_graph_revision.as_ref().is_some_and(|revision| {
        is_plan_complete(&run_step_progress(run, session_working), Some(revision))
    });
    let state = |kind, label: String| RunState { kind, label };
    if complete || (!unknown_active_plan && total > 0 && done == total) {
        let label = if failed > 0 {
            format!("Finished, {failed} failed")
        } else {
            "Done".to_owned()
        };
        return state(RunStateKind::Done, label);
    }
    if needs_input > 0 {
        return state(RunStateKind::Waiting, "Waiting for you".to_owned());
    }
    if run.is_current && session_working {
        return state(RunStateKind::Running, counted);
    }
    if failed > 0 {
        return state(RunStateKind::Failed, format!("Failed \u{b7} {counted}"));
    }
    if run.is_current && run.session_status == RunSessionStatus::Failed {
        return state(
            RunStateKind::Failed,
            format!("Session failed \u{b7} {counted}"),
        );
    }
    state(RunStateKind::Stopped, counted)
}

/// What a plan's run button shows: stop, continue, or "Stopping…" from Stop until the run
/// stops.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PlanRunControl {
    /// Continue the plan: the agent stopped with tasks it could run and none waiting.
    Play,
    /// Stop the plan while its session works.
    Stop,
    /// Stop was asked; the run is winding down.
    Stopping,
}

/// The control a plan shows (`planRunControl` and `planRunButtonState`).
///
/// Stop while its session works, play once the agent stopped with tasks left, none once it is
/// complete.
#[must_use]
pub fn plan_run_control(
    progress: &[StepProgress],
    entries: &[JournalEntry],
    session_working: bool,
    revision: Option<&GraphRevision>,
    stopping: bool,
) -> Option<PlanRunControl> {
    let stop = if stopping {
        PlanRunControl::Stopping
    } else {
        PlanRunControl::Stop
    };
    if session_working && revision.is_none() {
        return Some(stop);
    }
    if revision.is_some_and(|revision| is_plan_complete(progress, Some(revision))) {
        return None;
    }
    if session_working {
        return Some(stop);
    }
    let from_entries = plan_graph_revision(entries);
    paused_label_at(progress, entries, false, revision.or(from_entries.as_ref()))
        .map(|_| PlanRunControl::Play)
}

/// The run button a run's row shows, when the caller owns its workflow and the run is its
/// session's current one, not archived.
#[must_use]
pub fn run_control(
    run: &WorkflowRun,
    session_working: bool,
    stopping: bool,
    owned: bool,
) -> Option<PlanRunControl> {
    if !run.is_current || run.archived || !owned {
        return None;
    }
    plan_run_control(
        &run_step_progress(run, session_working),
        &run.statuses,
        session_working,
        run.plan_graph_revision.as_ref(),
        stopping,
    )
}

/// The session a run names under "Started by": none for a run listed below the session that
/// started it.
#[must_use]
pub fn run_starter_shown(run: &WorkflowRun, parent_session_id: Option<&str>) -> Option<RunStarter> {
    run.started_by
        .as_ref()
        .filter(|starter| Some(starter.session_id.as_str()) != parent_session_id)
        .cloned()
}

/// A run's descendants from its first page and `more` pages, each run once; a later copy of
/// a run wins in its first place.
#[must_use]
pub fn merge_descendant_runs(run: &WorkflowRun, more: &[WorkflowRun]) -> Vec<WorkflowRun> {
    let mut merged: Vec<WorkflowRun> = Vec::new();
    for descendant in run.descendant_runs.iter().chain(more) {
        match merged.iter_mut().find(|known| known.id == descendant.id) {
            Some(known) => known.clone_from(descendant),
            None => merged.push(descendant.clone()),
        }
    }
    merged
}

/// Whether "Ran N workflows" starts open: the run or one below it works or waits for input.
#[must_use]
pub fn descendants_active(run: &WorkflowRun, descendants: &[WorkflowRun]) -> bool {
    is_run_working(run)
        || run.descendant_runs_active
        || descendants
            .iter()
            .any(|descendant| is_run_working(descendant) || descendant.progress.needs_input > 0)
}

/// "Ran 3 workflows".
#[must_use]
pub fn ran_workflows_label(count: u32) -> String {
    format!(
        "Ran {count} {}",
        if count == 1 { "workflow" } else { "workflows" }
    )
}

/// The step state a run's glyph borrows from the Tasks tab.
#[must_use]
pub const fn run_glyph_state(kind: RunStateKind) -> StepState {
    match kind {
        RunStateKind::Running => StepState::Running,
        RunStateKind::Waiting => StepState::NeedsInput,
        RunStateKind::Done => StepState::Done,
        RunStateKind::Failed => StepState::Failed,
        RunStateKind::Stopped => StepState::Stopped,
    }
}
