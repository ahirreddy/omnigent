//! What the Tasks tab shows, row by row (`web/src/shell/TasksPanel.tsx`).
//!
//! The header's plan name and summary, each task's line, its menu action and its history. Times
//! stay epoch seconds; the app formats them, as the web does with the viewer's clock and locale.

use std::collections::BTreeSet;

use super::tasks::{
    NativeTask, PausedLabel, StepProgress, StepState, failed_upstream, finished_task_count,
    is_plan_complete, is_restart, paused_label, session_task_list, tally, task_marker_target,
};
use super::{JournalEntry, JournalEntryKind, StepStatus, plan_graph_revision, plan_workflow_id};
use crate::markdown_preview::markdown_preview_text;

/// What a task's menu asks for (`taskMenuAction`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TaskAction {
    /// Run a ready task.
    Run,
    /// Continue a stopped task.
    Continue,
    /// Go ahead with a task waiting for the user.
    Proceed,
    /// Retry a failed task.
    Retry,
    /// Stop the workflow and its workers while a task runs.
    Stop,
}

impl TaskAction {
    /// The menu item's title.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::Run => "Run",
            Self::Continue | Self::Proceed => "Continue",
            Self::Retry => "Retry",
            Self::Stop => "Stop",
        }
    }
}

/// The line under a task's name (`stepDetail`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskDetail {
    /// Plain text: the start of the goal, the newest status text, or what the agent says it is
    /// doing.
    Text(String),
    /// "Can't start · A and B failed".
    CantStart {
        /// The failed tasks it waits on, joined ("A and B").
        failed: String,
    },
    /// "Ready · goal".
    Ready {
        /// The start of the goal, as plain text.
        goal: Option<String>,
    },
    /// "Waiting for you · text".
    WaitingForYou {
        /// The status text, else "Respond in the chat".
        text: String,
    },
    /// "Started 3m ago · text", for a stopped task.
    Started {
        /// When it started, in epoch seconds.
        at: i64,
        /// The status text.
        text: Option<String>,
    },
}

/// One status in a task's history.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskHistoryEntry {
    /// The entry.
    pub id: String,
    /// The status.
    pub status: StepStatus,
    /// The text the agent gave.
    pub text: Option<String>,
    /// When, in epoch seconds.
    pub created_at: i64,
    /// A start after the task was done or failed: a line marks the new attempt.
    pub restarted: bool,
}

/// One task's row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskRow {
    /// The step or task id.
    pub id: String,
    /// Its place, from 1.
    pub number: u32,
    /// Its name.
    pub name: String,
    /// Where it stands.
    pub state: StepState,
    /// An item of the agent's own list, which has no history.
    pub native: bool,
    /// The line under its name; `None` for none.
    pub detail: Option<TaskDetail>,
    /// Its whole goal, in Markdown, for its history.
    pub goal: Option<String>,
    /// When a done or failed task ended, in epoch seconds.
    pub ended_at: Option<i64>,
    /// When its current attempt started, in epoch seconds.
    pub started_at: Option<i64>,
    /// A running task's time counts up from `started_at`.
    pub counts_up: bool,
    /// What its menu offers; `None` for no menu.
    pub action: Option<TaskAction>,
    /// The chat marker it links to; `None` when there is none to show.
    pub marker_id: Option<String>,
    /// The failed tasks it waits on, by name, when that is why it cannot start.
    pub failed_names: Vec<String>,
    /// The tasks it waits on, by name.
    pub depends_on_names: Vec<String>,
    /// The tasks it waits on that are not done, by name.
    pub pending_names: Vec<String>,
    /// Its statuses, oldest first.
    pub history: Vec<TaskHistoryEntry>,
}

/// What the viewer can do from the tab.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts the app knows about the session"
)]
pub struct TasksContext {
    /// The session's work is in flight: its turn, a background task or a worker agent.
    pub session_working: bool,
    /// A question or permission prompt waits for the user (not a workflow question).
    pub awaiting_user: bool,
    /// The viewer can send to the session, so the menus and plan controls show.
    pub can_send: bool,
    /// The journal could be read; without it only the agent's own list shows.
    pub journal_read: bool,
    /// The user's Stop was taken and the session hasn't stopped yet.
    pub stopping: bool,
}

/// The Tasks tab.
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts the tab shows; mirrored one to one as an FFI record"
)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TasksView {
    /// The plan's name, the tab's heading.
    pub plan_name: Option<String>,
    /// The saved workflow the plan came from.
    pub workflow_id: Option<String>,
    /// The tasks come from a plan, the only tasks that say what they wait on.
    pub from_plan: bool,
    /// The tasks are the agent's own list.
    pub native: bool,
    /// When the plan or a status last changed, in epoch seconds.
    pub updated_at: Option<i64>,
    /// "2 of 5 finished", "All 5 tasks done".
    pub summary: String,
    /// Counts after the summary: "1 waiting for you", "2 running", "1 failed".
    pub counts: Vec<(StepState, String)>,
    /// What an idle list says: "Stopped" or "Run ended".
    pub paused: Option<String>,
    /// The plan's stop control shows: the session works, the plan is not complete and the
    /// run isn't already stopping.
    pub can_stop: bool,
    /// A disabled "Stopping…" shows in the stop control's place, from Stop until the session
    /// stops.
    pub stopping: bool,
    /// The plan's play control shows: the list is paused, the viewer can send and the run
    /// isn't stopping.
    pub can_continue: bool,
    /// The tasks, in order.
    pub rows: Vec<TaskRow>,
}

/// "A", "A and B", "A, B and C" (`listNames`).
#[must_use]
pub fn list_names(names: &[String]) -> String {
    match names {
        [] => String::new(),
        [only] => only.clone(),
        [head @ .., last] => format!("{} and {last}", head.join(", ")),
    }
}

/// The start of a step's Markdown goal as one line of plain text, for a row that shows only
/// that; `None` without a goal or when no text remains.
fn goal_preview(item: &StepProgress) -> Option<String> {
    let preview = markdown_preview_text(item.step.goal.as_deref()?);
    (!preview.is_empty()).then_some(preview)
}

fn detail(item: &StepProgress, failed: &[String]) -> Option<TaskDetail> {
    let text = item.status.as_ref().and_then(|status| status.text.clone());
    Some(match item.state {
        StepState::Waiting if failed.is_empty() => TaskDetail::Text(goal_preview(item)?),
        StepState::Waiting => TaskDetail::CantStart {
            failed: list_names(failed),
        },
        StepState::Ready => TaskDetail::Ready {
            goal: goal_preview(item),
        },
        StepState::NeedsInput => TaskDetail::WaitingForYou {
            text: text.unwrap_or_else(|| "Respond in the chat".to_owned()),
        },
        StepState::Stopped => match &item.status {
            None => TaskDetail::Text(item.active_form.clone()?),
            Some(status) => TaskDetail::Started {
                at: status.created_at,
                text: text.filter(|text| !text.is_empty()),
            },
        },
        _ => TaskDetail::Text(text.or_else(|| item.active_form.clone())?),
    })
}

fn history(item: &StepProgress, entries: &[JournalEntry]) -> Vec<TaskHistoryEntry> {
    if item.native {
        return vec![];
    }
    let recorded: Vec<&JournalEntry> = entries
        .iter()
        .filter(|entry| {
            entry.step.as_deref() == Some(item.step.id.as_str())
                && entry.kind == JournalEntryKind::Status
                && entry.status.is_some()
        })
        .collect();
    recorded
        .iter()
        .enumerate()
        .filter_map(|(index, entry)| {
            Some(TaskHistoryEntry {
                id: entry.id.clone(),
                status: entry.status?,
                text: entry.text.clone().filter(|text| !text.is_empty()),
                created_at: entry.created_at,
                restarted: is_restart(entry, recorded.get(..index).unwrap_or_default()),
            })
        })
        .collect()
}

/// The menu action a task's state offers the viewer (`taskMenuAction`).
pub(crate) fn task_action(item: &StepProgress, context: TasksContext) -> Option<TaskAction> {
    if !context.can_send {
        return None;
    }
    match item.state {
        // A run already stopping offers no Stop, so its stop message isn't sent twice.
        StepState::Running => {
            (context.session_working && !context.stopping).then_some(TaskAction::Stop)
        }
        StepState::Ready => Some(TaskAction::Run),
        StepState::Stopped => Some(TaskAction::Continue),
        StepState::NeedsInput => Some(TaskAction::Proceed),
        StepState::Failed => Some(TaskAction::Retry),
        StepState::Waiting | StepState::Done => None,
    }
}

/// The Tasks tab for a session.
///
/// `native_markers` are the agent's own task markers in the chat: a task of its own list links
/// to the chat only where its marker is there.
#[must_use]
pub fn tasks_view(
    entries: &[JournalEntry],
    native_tasks: &[NativeTask],
    native_markers: &BTreeSet<String>,
    context: TasksContext,
) -> TasksView {
    let entries = if context.journal_read { entries } else { &[] };
    let list = session_task_list(
        entries,
        native_tasks,
        context.session_working,
        context.awaiting_user,
    );
    let progress = &list.progress;
    let name_of = |id: &String| {
        progress
            .iter()
            .find(|item| item.step.id == *id)
            .map_or_else(|| id.clone(), |item| item.step.name.clone())
    };
    let blocked = failed_upstream(progress);
    let done: BTreeSet<&str> = progress
        .iter()
        .filter(|item| item.state == StepState::Done)
        .map(|item| item.step.id.as_str())
        .collect();
    let rows = progress
        .iter()
        .zip(1_u32..)
        .map(|(item, number)| {
            let failed_names: Vec<String> = blocked
                .get(&item.step.id)
                .map(|ids| ids.iter().map(name_of).collect())
                .unwrap_or_default();
            let target = task_marker_target(item);
            let marker_id = target.filter(|target| !item.native || native_markers.contains(target));
            let ended = matches!(item.state, StepState::Done | StepState::Failed);
            let started = item.status.as_ref().and_then(|status| status.status);
            TaskRow {
                id: item.step.id.clone(),
                number,
                name: item.step.name.clone(),
                state: item.state,
                native: item.native,
                detail: detail(item, &failed_names),
                goal: item.step.goal.clone(),
                ended_at: ended
                    .then(|| item.status.as_ref().map(|status| status.created_at))
                    .flatten(),
                started_at: item.started_at,
                counts_up: item.started_at.is_some()
                    && (item.state == StepState::Running
                        || (item.state == StepState::NeedsInput
                            && started == Some(StepStatus::Started))),
                action: task_action(item, context),
                marker_id,
                failed_names,
                depends_on_names: item.step.depends_on.iter().map(name_of).collect(),
                pending_names: item
                    .step
                    .depends_on
                    .iter()
                    .filter(|id| !done.contains(id.as_str()))
                    .map(name_of)
                    .collect(),
                history: history(item, entries),
            }
        })
        .collect();
    header(&list, entries, context, rows)
}

fn header(
    list: &super::tasks::SessionTaskList,
    entries: &[JournalEntry],
    context: TasksContext,
    rows: Vec<TaskRow>,
) -> TasksView {
    let progress = &list.progress;
    let total = progress.len();
    let finished = finished_task_count(progress);
    let summary = if tally(progress, StepState::Done) == total {
        format!("All {total} tasks done")
    } else if finished == total {
        format!("All {total} tasks finished")
    } else {
        format!("{finished} of {total} finished")
    };
    let counts = [StepState::NeedsInput, StepState::Running, StepState::Failed]
        .into_iter()
        .filter_map(|state| {
            let count = tally(progress, state);
            (count > 0).then(|| (state, format!("{count} {}", state.label().to_lowercase())))
        })
        .collect();
    let updated_at = list
        .plan
        .iter()
        .map(|plan| plan.created_at)
        .chain(
            progress
                .iter()
                .filter_map(|item| item.status.as_ref().map(|s| s.created_at)),
        )
        .max()
        .filter(|updated| *updated > 0);
    let paused = paused_label(progress, entries, context.session_working);
    let complete =
        list.plan.is_some() && is_plan_complete(progress, plan_graph_revision(entries).as_ref());
    let stopping = context.can_send && context.stopping && !complete;
    TasksView {
        plan_name: list
            .plan
            .as_ref()
            .and_then(|plan| plan.plan_name().map(str::to_owned)),
        workflow_id: plan_workflow_id(entries),
        from_plan: list.plan.is_some(),
        native: list.native,
        updated_at,
        summary,
        counts,
        paused: paused.map(|label| PausedLabel::text(label).to_owned()),
        can_stop: context.can_send && context.session_working && !complete && !stopping,
        stopping,
        can_continue: context.can_send && paused.is_some() && !stopping,
        rows,
    }
}
