//! Where a session's tasks stand: a plan's steps, or the agent's own task list when the session
//! has no plan (`web/src/lib/sessionJournal.ts`).

use std::collections::{BTreeMap, BTreeSet};

use super::{
    GraphRevision, JournalEntry, JournalEntryKind, PlanStep, StepStatus, current_plan,
    plan_graph_revision,
};

/// Where a task stands. A started step runs only while the session works; a step with no status
/// is ready once every step it depends on is done.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StepState {
    /// Waits for the steps it depends on.
    Waiting,
    /// Can start.
    Ready,
    /// Started while the session works.
    Running,
    /// Started, but the session stopped.
    Stopped,
    /// Waits for the user.
    NeedsInput,
    /// Done.
    Done,
    /// Failed.
    Failed,
}

impl StepState {
    /// The web's `STATE_LABELS`.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Waiting => "Not started",
            Self::Ready => "Ready",
            Self::Running => "Running",
            Self::Stopped => "Stopped",
            Self::NeedsInput => super::WAITING_FOR_YOU,
            Self::Done => "Done",
            Self::Failed => "Failed",
        }
    }
}

/// An item of the agent's own task list, as its harness reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeTask {
    /// The task's id (Claude's task ids), else `task-<n>` by its place in the list.
    pub id: String,
    /// What it is.
    pub content: String,
    /// Where it stands.
    pub status: NativeTaskStatus,
    /// What the agent says it is doing while in progress.
    pub active_form: Option<String>,
}

/// Where an item of the agent's own list stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NativeTaskStatus {
    /// Not started.
    Pending,
    /// In progress.
    InProgress,
    /// Completed.
    Completed,
}

/// One task and where it stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StepProgress {
    /// The step, or the agent's task as one.
    pub step: PlanStep,
    /// Where it stands.
    pub state: StepState,
    /// Its newest status; `None` until it has one.
    pub status: Option<JournalEntry>,
    /// When its current attempt started, in epoch seconds, if it wrote a start.
    pub started_at: Option<i64>,
    /// An item of the agent's own list, which has no history.
    pub native: bool,
    /// What the agent says it is doing while an item of its own list is in progress.
    pub active_form: Option<String>,
}

/// The start of the attempt that wrote a step's newest status, if it wrote one.
fn attempt_start<'a>(statuses: &[&'a JournalEntry]) -> Option<&'a JournalEntry> {
    let last = statuses.len().checked_sub(1)?;
    for (index, entry) in statuses.iter().enumerate().rev() {
        match entry.status {
            Some(StepStatus::Started) => return Some(entry),
            // An earlier attempt finished, so the newest one wrote no start.
            Some(StepStatus::Done | StepStatus::Failed) if index < last => return None,
            _ => {}
        }
    }
    None
}

/// Whether `entry` restarts its step: a start after the step was done or failed (`isRestart`).
#[must_use]
pub fn is_restart(entry: &JournalEntry, earlier: &[&JournalEntry]) -> bool {
    if entry.status != Some(StepStatus::Started) {
        return false;
    }
    earlier
        .iter()
        .rev()
        .find(|other| other.step == entry.step && other.status.is_some())
        .is_some_and(|previous| {
            matches!(previous.status, Some(StepStatus::Done | StepStatus::Failed))
        })
}

/// The status entries of each step, oldest first, since the last run boundary.
fn statuses_by_step(entries: &[JournalEntry]) -> BTreeMap<&str, Vec<&JournalEntry>> {
    let mut statuses: BTreeMap<&str, Vec<&JournalEntry>> = BTreeMap::new();
    for entry in entries {
        if entry.kind == JournalEntryKind::PlanStatus {
            statuses.clear();
            continue;
        }
        let Some(step) = entry.step.as_deref() else {
            continue;
        };
        if entry.kind == JournalEntryKind::Status && entry.status.is_some() {
            statuses.entry(step).or_default().push(entry);
        }
    }
    statuses
}

/// Where each step stands, in the given order (`stepProgress`).
#[must_use]
pub fn step_progress(
    steps: &[PlanStep],
    entries: &[JournalEntry],
    session_working: bool,
    awaiting_user: bool,
) -> Vec<StepProgress> {
    let statuses = statuses_by_step(entries);
    let mut progress: Vec<StepProgress> = steps
        .iter()
        .map(|step| {
            let history = statuses
                .get(step.id.as_str())
                .map_or(&[][..], Vec::as_slice);
            let status = history.last().copied();
            let state = match status.and_then(|entry| entry.status) {
                Some(StepStatus::Started) if awaiting_user => StepState::NeedsInput,
                Some(StepStatus::Started) if session_working => StepState::Running,
                Some(StepStatus::Started) => StepState::Stopped,
                Some(StepStatus::Done) => StepState::Done,
                Some(StepStatus::NeedsInput) => StepState::NeedsInput,
                Some(StepStatus::Failed) => StepState::Failed,
                None => StepState::Waiting,
            };
            StepProgress {
                step: step.clone(),
                state,
                status: status.cloned(),
                started_at: attempt_start(history).map(|entry| entry.created_at),
                native: false,
                active_form: None,
            }
        })
        .collect();
    let done: BTreeSet<String> = progress
        .iter()
        .filter(|item| item.state == StepState::Done)
        .map(|item| item.step.id.clone())
        .collect();
    for item in &mut progress {
        if item.state == StepState::Waiting
            && item.step.depends_on.iter().all(|id| done.contains(id))
        {
            item.state = StepState::Ready;
        }
    }
    progress
}

/// The steps to show when the agent wrote statuses but no plan: one per step it named
/// (`stepsWithoutPlan`).
#[must_use]
pub fn steps_without_plan(entries: &[JournalEntry]) -> Vec<PlanStep> {
    let mut ids: Vec<&str> = Vec::new();
    for entry in entries {
        if entry.kind == JournalEntryKind::Status
            && let Some(step) = entry.step.as_deref()
            && !ids.contains(&step)
        {
            ids.push(step);
        }
    }
    ids.into_iter()
        .map(|id| PlanStep {
            id: id.to_owned(),
            name: id.to_owned(),
            goal: None,
            depends_on: vec![],
        })
        .collect()
}

/// The tasks that cannot start because a task they wait on failed, directly or through tasks
/// that have not started either: each one's failed tasks by id, nearest first
/// (`failedUpstream`).
#[must_use]
pub fn failed_upstream(progress: &[StepProgress]) -> BTreeMap<String, Vec<String>> {
    let by_id: BTreeMap<&str, &StepProgress> = progress
        .iter()
        .map(|item| (item.step.id.as_str(), item))
        .collect();
    let mut blocked = BTreeMap::new();
    for item in progress {
        if item.state != StepState::Waiting {
            continue;
        }
        let mut failed = Vec::new();
        let mut seen = BTreeSet::new();
        let mut pending: std::collections::VecDeque<&str> =
            item.step.depends_on.iter().map(String::as_str).collect();
        while let Some(id) = pending.pop_front() {
            if !seen.insert(id) {
                continue;
            }
            match by_id.get(id) {
                Some(upstream) if upstream.state == StepState::Failed => failed.push(id.to_owned()),
                // A task that has not started passes on whatever keeps it from starting.
                Some(upstream) if upstream.state == StepState::Waiting => {
                    pending.extend(upstream.step.depends_on.iter().map(String::as_str));
                }
                _ => {}
            }
        }
        if !failed.is_empty() {
            blocked.insert(item.step.id.clone(), failed);
        }
    }
    blocked
}

/// How many tasks are in `state`.
#[must_use]
pub fn tally(progress: &[StepProgress], state: StepState) -> usize {
    progress.iter().filter(|item| item.state == state).count()
}

/// How many tasks are finished: done or failed, since a failed task's work is over too.
#[must_use]
pub fn finished_task_count(progress: &[StepProgress]) -> usize {
    tally(progress, StepState::Done) + tally(progress, StepState::Failed)
}

/// Whether the plan is complete: its final steps are done, and no newer plan or status added
/// unfinished work before them (`isPlanComplete`).
#[must_use]
pub fn is_plan_complete(progress: &[StepProgress], revision: Option<&GraphRevision>) -> bool {
    let dependencies: BTreeSet<&str> = progress
        .iter()
        .flat_map(|item| item.step.depends_on.iter().map(String::as_str))
        .collect();
    let by_id: BTreeMap<&str, &StepProgress> = progress
        .iter()
        .map(|item| (item.step.id.as_str(), item))
        .collect();
    let mut finals = progress
        .iter()
        .filter(|item| !dependencies.contains(item.step.id.as_str()))
        .peekable();
    finals.peek().is_some() && finals.all(|item| final_step_complete(item, &by_id, revision))
}

fn final_step_complete(
    item: &StepProgress,
    by_id: &BTreeMap<&str, &StepProgress>,
    revision: Option<&GraphRevision>,
) -> bool {
    if item.state != StepState::Done {
        return false;
    }
    let status = item.status.as_ref();
    let graph_changed = status.is_some_and(|status| match revision {
        Some(GraphRevision::Number(position)) => *position > status.position,
        Some(text @ GraphRevision::Text(_)) => status.graph_revision.as_ref() != Some(text),
        None => false,
    });
    let mut pending: Vec<&str> = item.step.depends_on.iter().map(String::as_str).collect();
    let mut seen = BTreeSet::new();
    while let Some(id) = pending.pop() {
        if !seen.insert(id) {
            continue;
        }
        let Some(upstream) = by_id.get(id) else {
            continue;
        };
        let newer = upstream
            .status
            .as_ref()
            .zip(status)
            .is_some_and(|(upstream, last)| upstream.position > last.position);
        if upstream.state != StepState::Done && (graph_changed || newer) {
            return false;
        }
        pending.extend(upstream.step.depends_on.iter().map(String::as_str));
    }
    true
}

/// Where each item of the agent's own list stands (`nativeTaskProgress`): an item in progress
/// runs only while the session works.
#[must_use]
pub fn native_task_progress(
    tasks: &[NativeTask],
    session_working: bool,
    awaiting_user: bool,
) -> Vec<StepProgress> {
    tasks
        .iter()
        .map(|task| {
            let state = match task.status {
                NativeTaskStatus::Completed => StepState::Done,
                NativeTaskStatus::InProgress if awaiting_user => StepState::NeedsInput,
                NativeTaskStatus::InProgress if session_working => StepState::Running,
                NativeTaskStatus::InProgress => StepState::Stopped,
                NativeTaskStatus::Pending => StepState::Waiting,
            };
            let active_form = task
                .active_form
                .as_ref()
                .filter(|form| {
                    task.status == NativeTaskStatus::InProgress
                        && !form.is_empty()
                        && **form != task.content
                })
                .cloned();
            StepProgress {
                step: PlanStep {
                    id: task.id.clone(),
                    name: task.content.clone(),
                    goal: None,
                    depends_on: vec![],
                },
                state,
                status: None,
                started_at: None,
                native: true,
                active_form,
            }
        })
        .collect()
}

/// A session's tasks: its plan's steps when it has a plan, otherwise the agent's own list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionTaskList {
    /// The plan the tasks come from; `None` for the agent's own list.
    pub plan: Option<JournalEntry>,
    /// The tasks.
    pub progress: Vec<StepProgress>,
    /// The tasks are the agent's own list.
    pub native: bool,
}

/// The tasks to show (`sessionTaskList`). A plan, or statuses written without one, win over the
/// agent's own list, so a workflow never shows two lists.
#[must_use]
pub fn session_task_list(
    entries: &[JournalEntry],
    native_tasks: &[NativeTask],
    session_working: bool,
    awaiting_user: bool,
) -> SessionTaskList {
    let plan = current_plan(entries);
    let steps = plan.map_or_else(|| steps_without_plan(entries), |plan| plan.steps.clone());
    if steps.is_empty() {
        return SessionTaskList {
            plan: None,
            progress: native_task_progress(native_tasks, session_working, awaiting_user),
            native: true,
        };
    }
    SessionTaskList {
        plan: plan.cloned(),
        progress: step_progress(&steps, entries, session_working, awaiting_user),
        native: false,
    }
}

/// Why an idle list is not moving.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PausedLabel {
    /// The agent stopped with tasks left.
    Stopped,
    /// An automation run wrote the newest entry and ended.
    RunEnded,
}

impl PausedLabel {
    /// What the list says.
    #[must_use]
    pub const fn text(self) -> &'static str {
        match self {
            Self::Stopped => "Stopped",
            Self::RunEnded => "Run ended",
        }
    }
}

/// What an idle list says when it has tasks the agent could run and none waits for the user
/// (`pausedLabel`); `None` while the session works.
#[must_use]
pub fn paused_label(
    progress: &[StepProgress],
    entries: &[JournalEntry],
    session_working: bool,
) -> Option<PausedLabel> {
    paused_label_at(
        progress,
        entries,
        session_working,
        plan_graph_revision(entries).as_ref(),
    )
}

/// [`paused_label`] for a plan whose graph revision is known apart from `entries`, such as a
/// workflow run's, whose entries are only its steps' statuses.
#[must_use]
pub fn paused_label_at(
    progress: &[StepProgress],
    entries: &[JournalEntry],
    session_working: bool,
    revision: Option<&GraphRevision>,
) -> Option<PausedLabel> {
    let complete = revision.is_some_and(|revision| is_plan_complete(progress, Some(revision)));
    if session_working
        || complete
        || progress
            .iter()
            .any(|item| item.state == StepState::NeedsInput)
    {
        return None;
    }
    let runnable = progress.iter().any(|item| {
        matches!(item.state, StepState::Ready | StepState::Stopped)
            || (item.native && item.state == StepState::Waiting)
    });
    if !runnable {
        return None;
    }
    let by_run = entries
        .last()
        .is_some_and(|entry| entry.scheduled_task_run_id.is_some());
    Some(if by_run {
        PausedLabel::RunEnded
    } else {
        PausedLabel::Stopped
    })
}

/// The chat marker id for a journal entry: a plan task's status or a plan change.
#[must_use]
pub fn journal_marker_id(entry_id: &str) -> String {
    format!("journal-{entry_id}")
}

/// The chat marker id for one of the agent's own tasks reaching `status`.
#[must_use]
pub fn todo_marker_id(task_id: &str, status: &str) -> String {
    format!("todo-{task_id}-{status}")
}

/// The chat marker a task links to (`taskMarkerTarget`): its newest start while it runs or is
/// stopped, else where it ended; `None` before it starts.
#[must_use]
pub fn task_marker_target(item: &StepProgress) -> Option<String> {
    if !item.native {
        return item
            .status
            .as_ref()
            .map(|status| journal_marker_id(&status.id));
    }
    match item.state {
        StepState::Done => Some(todo_marker_id(&item.step.id, "done")),
        StepState::Running | StepState::Stopped | StepState::NeedsInput => {
            Some(todo_marker_id(&item.step.id, "started"))
        }
        _ => None,
    }
}
