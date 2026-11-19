//! The Tasks tab: a session's journal and where its tasks stand.
//!
//! Records mirror `omnigent_core::session_journal`; the reads, the task states and what the
//! tab says are computed there. The app keeps the entries it read, adds the ones the stream
//! pushes (`CoreEvent::SessionJournalAppended`), and asks [`tasks_view`] for the tab.

use std::collections::BTreeSet;

use omnigent_core::session_journal::{self as core, messages, tasks, view};

use crate::client::ClientCore;
use crate::errors::CoreError;

/// A step status the agent writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum StepStatus {
    /// Started, or resumed.
    Started,
    /// Done.
    Done,
    /// Waits for the user.
    NeedsInput,
    /// Failed.
    Failed,
}

impl From<core::StepStatus> for StepStatus {
    fn from(status: core::StepStatus) -> Self {
        match status {
            core::StepStatus::Started => Self::Started,
            core::StepStatus::Done => Self::Done,
            core::StepStatus::NeedsInput => Self::NeedsInput,
            core::StepStatus::Failed => Self::Failed,
        }
    }
}

impl From<StepStatus> for core::StepStatus {
    fn from(status: StepStatus) -> Self {
        match status {
            StepStatus::Started => Self::Started,
            StepStatus::Done => Self::Done,
            StepStatus::NeedsInput => Self::NeedsInput,
            StepStatus::Failed => Self::Failed,
        }
    }
}

/// One step of a plan.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PlanStep {
    /// Stable id.
    pub id: String,
    /// One line.
    pub name: String,
    /// What it achieves.
    pub goal: Option<String>,
    /// The steps that must be done first.
    pub depends_on: Vec<String>,
}

/// The revision of a plan's graph.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum GraphRevision {
    /// The server's id.
    Text {
        /// The id.
        value: String,
    },
    /// A position (older servers).
    Number {
        /// The position.
        value: i64,
    },
}

/// One journal entry, with the content fields the Tasks tab reads.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct JournalEntry {
    /// Entry id.
    pub id: String,
    /// Its place in the journal.
    pub position: i64,
    /// When it was appended, in epoch seconds.
    pub created_at: i64,
    /// The automation run the session was serving.
    pub scheduled_task_run_id: Option<String>,
    /// The plan step it is about.
    pub step: Option<String>,
    /// The kind as sent: `plan`, `status`, `plan_status`, `note`, ...
    pub kind: String,
    /// The saved workflow it was written under.
    pub workflow_id: Option<String>,
    /// A status entry's status.
    pub status: Option<StepStatus>,
    /// The text the agent gave.
    pub text: Option<String>,
    /// A plan's name.
    pub name: Option<String>,
    /// A plan's steps.
    pub steps: Vec<PlanStep>,
    /// A plan's version.
    pub version: Option<i64>,
    /// The graph revision it was written against.
    pub graph_revision: Option<GraphRevision>,
}

fn kind_name(kind: &core::JournalEntryKind) -> String {
    match kind {
        core::JournalEntryKind::Status => "status".to_owned(),
        core::JournalEntryKind::Note => "note".to_owned(),
        core::JournalEntryKind::Dispatch => "dispatch".to_owned(),
        core::JournalEntryKind::DispatchResult => "dispatch_result".to_owned(),
        core::JournalEntryKind::Plan => "plan".to_owned(),
        core::JournalEntryKind::PlanStatus => "plan_status".to_owned(),
        core::JournalEntryKind::Unknown(other) => other.clone(),
    }
}

impl From<core::JournalEntry> for JournalEntry {
    fn from(entry: core::JournalEntry) -> Self {
        Self {
            kind: kind_name(&entry.kind),
            id: entry.id,
            position: entry.position,
            created_at: entry.created_at,
            scheduled_task_run_id: entry.scheduled_task_run_id,
            step: entry.step,
            workflow_id: entry.workflow_id,
            status: entry.status.map(Into::into),
            text: entry.text,
            name: entry.name,
            steps: entry
                .steps
                .into_iter()
                .map(|step| PlanStep {
                    id: step.id,
                    name: step.name,
                    goal: step.goal,
                    depends_on: step.depends_on,
                })
                .collect(),
            version: entry.version,
            graph_revision: entry.graph_revision.map(|revision| match revision {
                core::GraphRevision::Text(value) => GraphRevision::Text { value },
                core::GraphRevision::Number(value) => GraphRevision::Number { value },
            }),
        }
    }
}

impl From<JournalEntry> for core::JournalEntry {
    fn from(entry: JournalEntry) -> Self {
        Self {
            kind: core::JournalEntryKind::of(&entry.kind),
            id: entry.id,
            position: entry.position,
            created_at: entry.created_at,
            scheduled_task_run_id: entry.scheduled_task_run_id,
            step: entry.step,
            workflow_id: entry.workflow_id,
            status: entry.status.map(Into::into),
            text: entry.text,
            name: entry.name,
            steps: entry
                .steps
                .into_iter()
                .map(|step| core::PlanStep {
                    id: step.id,
                    name: step.name,
                    goal: step.goal,
                    depends_on: step.depends_on,
                })
                .collect(),
            version: entry.version,
            graph_revision: entry.graph_revision.map(|revision| match revision {
                GraphRevision::Text { value } => core::GraphRevision::Text(value),
                GraphRevision::Number { value } => core::GraphRevision::Number(value),
            }),
        }
    }
}

/// Where an item of the agent's own list stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum NativeTaskStatus {
    /// Not started.
    Pending,
    /// In progress.
    InProgress,
    /// Completed.
    Completed,
}

/// An item of the agent's own task list.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct NativeTask {
    /// Its key: the harness's id, else `task-<n>` (the `todos` section's detail id).
    pub id: String,
    /// What it is.
    pub content: String,
    /// Where it stands.
    pub status: NativeTaskStatus,
    /// What the agent says it is doing while in progress.
    pub active_form: Option<String>,
}

/// Where a task stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
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

impl From<tasks::StepState> for StepState {
    fn from(state: tasks::StepState) -> Self {
        match state {
            tasks::StepState::Waiting => Self::Waiting,
            tasks::StepState::Ready => Self::Ready,
            tasks::StepState::Running => Self::Running,
            tasks::StepState::Stopped => Self::Stopped,
            tasks::StepState::NeedsInput => Self::NeedsInput,
            tasks::StepState::Done => Self::Done,
            tasks::StepState::Failed => Self::Failed,
        }
    }
}

/// What a task's menu asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TaskAction {
    /// Run a ready task.
    Run,
    /// Continue a stopped task.
    Continue,
    /// Go ahead with a task waiting for the user.
    Proceed,
    /// Retry a failed task.
    Retry,
    /// Stop the workflow while a task runs.
    Stop,
}

impl From<view::TaskAction> for TaskAction {
    fn from(action: view::TaskAction) -> Self {
        match action {
            view::TaskAction::Run => Self::Run,
            view::TaskAction::Continue => Self::Continue,
            view::TaskAction::Proceed => Self::Proceed,
            view::TaskAction::Retry => Self::Retry,
            view::TaskAction::Stop => Self::Stop,
        }
    }
}

impl From<TaskAction> for view::TaskAction {
    fn from(action: TaskAction) -> Self {
        match action {
            TaskAction::Run => Self::Run,
            TaskAction::Continue => Self::Continue,
            TaskAction::Proceed => Self::Proceed,
            TaskAction::Retry => Self::Retry,
            TaskAction::Stop => Self::Stop,
        }
    }
}

/// The line under a task's name.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TaskDetail {
    /// Plain text.
    Text {
        /// The text.
        text: String,
    },
    /// "Can't start · A failed".
    CantStart {
        /// The failed tasks, joined.
        failed: String,
    },
    /// "Ready · goal".
    Ready {
        /// The goal.
        goal: Option<String>,
    },
    /// "Waiting for you · text".
    WaitingForYou {
        /// The text.
        text: String,
    },
    /// "Started 3m ago · text".
    Started {
        /// When, in epoch seconds.
        at: i64,
        /// The text.
        text: Option<String>,
    },
}

impl From<view::TaskDetail> for TaskDetail {
    fn from(detail: view::TaskDetail) -> Self {
        match detail {
            view::TaskDetail::Text(text) => Self::Text { text },
            view::TaskDetail::CantStart { failed } => Self::CantStart { failed },
            view::TaskDetail::Ready { goal } => Self::Ready { goal },
            view::TaskDetail::WaitingForYou { text } => Self::WaitingForYou { text },
            view::TaskDetail::Started { at, text } => Self::Started { at, text },
        }
    }
}

/// One status in a task's history.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TaskHistoryEntry {
    /// The entry.
    pub id: String,
    /// The status.
    pub status: StepStatus,
    /// The label: "Started", "Done", "Waiting for you", "Failed".
    pub label: String,
    /// The text.
    pub text: Option<String>,
    /// When, in epoch seconds.
    pub created_at: i64,
    /// A new attempt starts here.
    pub restarted: bool,
}

/// One task's row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TaskRow {
    /// The step or task id.
    pub id: String,
    /// Its place, from 1.
    pub number: u32,
    /// Its name.
    pub name: String,
    /// Where it stands.
    pub state: StepState,
    /// What its state reads as: "Not started", "Running", ...
    pub state_label: String,
    /// An item of the agent's own list, which has no history.
    pub native: bool,
    /// The line under its name.
    pub detail: Option<TaskDetail>,
    /// Its goal.
    pub goal: Option<String>,
    /// When a done or failed task ended, in epoch seconds.
    pub ended_at: Option<i64>,
    /// When its current attempt started, in epoch seconds.
    pub started_at: Option<i64>,
    /// A running task's time counts up from `started_at`.
    pub counts_up: bool,
    /// What its menu offers.
    pub action: Option<TaskAction>,
    /// The menu item's title.
    pub action_title: Option<String>,
    /// The chat marker it links to.
    pub marker_id: Option<String>,
    /// The failed tasks it waits on, by name.
    pub failed_names: Vec<String>,
    /// The tasks it waits on, by name.
    pub depends_on_names: Vec<String>,
    /// The tasks it waits on that are not done, by name.
    pub pending_names: Vec<String>,
    /// Its statuses, oldest first.
    pub history: Vec<TaskHistoryEntry>,
}

/// A count after the summary.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TaskCount {
    /// The state counted.
    pub state: StepState,
    /// "2 running".
    pub text: String,
}

/// The Tasks tab.
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts the tab shows, as the core's view has them"
)]
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TasksView {
    /// The plan's name.
    pub plan_name: Option<String>,
    /// The saved workflow the plan came from.
    pub workflow_id: Option<String>,
    /// The tasks come from a plan.
    pub from_plan: bool,
    /// The tasks are the agent's own list.
    pub native: bool,
    /// When the plan or a status last changed, in epoch seconds.
    pub updated_at: Option<i64>,
    /// "2 of 5 finished".
    pub summary: String,
    /// Counts after the summary.
    pub counts: Vec<TaskCount>,
    /// "Stopped" or "Run ended".
    pub paused: Option<String>,
    /// The plan's stop control shows.
    pub can_stop: bool,
    /// "Stopping…" shows in the stop control's place, from Stop until the session stops.
    #[uniffi(default)]
    pub stopping: bool,
    /// The plan's play control shows.
    pub can_continue: bool,
    /// The tasks, in order.
    pub rows: Vec<TaskRow>,
}

/// What the app knows about the session for the tab.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts the app knows about the session"
)]
pub struct TasksContext {
    /// Its turn, a background task or a worker agent is running.
    pub session_working: bool,
    /// A question or permission prompt waits for the user.
    pub awaiting_user: bool,
    /// The viewer can send to the session.
    pub can_send: bool,
    /// The journal was read (or the server keeps none).
    pub journal_read: bool,
    /// The user's Stop was taken and the session hasn't stopped yet.
    #[uniffi(default)]
    pub stopping: bool,
}

fn row(row: view::TaskRow) -> TaskRow {
    TaskRow {
        state_label: row.state.label().to_owned(),
        action_title: row.action.map(|action| action.title().to_owned()),
        id: row.id,
        number: row.number,
        name: row.name,
        state: row.state.into(),
        native: row.native,
        detail: row.detail.map(Into::into),
        goal: row.goal,
        ended_at: row.ended_at,
        started_at: row.started_at,
        counts_up: row.counts_up,
        action: row.action.map(Into::into),
        marker_id: row.marker_id,
        failed_names: row.failed_names,
        depends_on_names: row.depends_on_names,
        pending_names: row.pending_names,
        history: row
            .history
            .into_iter()
            .map(|entry| TaskHistoryEntry {
                label: entry.status.label().to_owned(),
                id: entry.id,
                status: entry.status.into(),
                text: entry.text,
                created_at: entry.created_at,
                restarted: entry.restarted,
            })
            .collect(),
    }
}

/// The Tasks tab for a session: its plan's steps, or the agent's own list without a plan.
///
/// `native_markers` are the ids of the agent's own task markers in the chat
/// (`todo-<task>-<status>`), which its tasks link to.
#[uniffi::export]
#[must_use]
pub fn tasks_view(
    entries: Vec<JournalEntry>,
    native_tasks: Vec<NativeTask>,
    native_markers: Vec<String>,
    context: TasksContext,
) -> TasksView {
    let entries: Vec<core::JournalEntry> = entries.into_iter().map(Into::into).collect();
    let native_tasks: Vec<tasks::NativeTask> = native_tasks
        .into_iter()
        .map(|task| tasks::NativeTask {
            id: task.id,
            content: task.content,
            status: match task.status {
                NativeTaskStatus::Pending => tasks::NativeTaskStatus::Pending,
                NativeTaskStatus::InProgress => tasks::NativeTaskStatus::InProgress,
                NativeTaskStatus::Completed => tasks::NativeTaskStatus::Completed,
            },
            active_form: task.active_form,
        })
        .collect();
    let markers: BTreeSet<String> = native_markers.into_iter().collect();
    let shown = view::tasks_view(
        &entries,
        &native_tasks,
        &markers,
        view::TasksContext {
            session_working: context.session_working,
            awaiting_user: context.awaiting_user,
            can_send: context.can_send,
            journal_read: context.journal_read,
            stopping: context.stopping,
        },
    );
    TasksView {
        plan_name: shown.plan_name,
        workflow_id: shown.workflow_id,
        from_plan: shown.from_plan,
        native: shown.native,
        updated_at: shown.updated_at,
        summary: shown.summary,
        counts: shown
            .counts
            .into_iter()
            .map(|(state, text)| TaskCount {
                state: state.into(),
                text,
            })
            .collect(),
        paused: shown.paused,
        can_stop: shown.can_stop,
        stopping: shown.stopping,
        can_continue: shown.can_continue,
        rows: shown.rows.into_iter().map(row).collect(),
    }
}

/// `entries` with `added`, in position order without repeats; a later copy wins.
#[uniffi::export]
#[must_use]
pub fn merge_journal_entries(
    entries: Vec<JournalEntry>,
    added: Vec<JournalEntry>,
) -> Vec<JournalEntry> {
    let entries: Vec<core::JournalEntry> = entries.into_iter().map(Into::into).collect();
    let added: Vec<core::JournalEntry> = added.into_iter().map(Into::into).collect();
    core::merge_journal_entries(&[&entries, &added])
        .into_iter()
        .map(Into::into)
        .collect()
}

/// The message a task's menu sends (web `taskActionMessage`); `None` for Stop, which sends
/// [`stop_plan_message`].
#[uniffi::export]
#[must_use]
pub fn task_action_message(action: TaskAction, task_name: String) -> Option<String> {
    messages::task_action_message(action.into(), &task_name)
}

/// The message the plan's play control sends (web `continuePlanMessage`).
#[uniffi::export]
#[must_use]
pub fn continue_plan_message(plan_name: Option<String>) -> String {
    messages::continue_plan_message(plan_name.as_deref())
}

/// The message the plan's stop control sends (web `stopPlanMessage`).
#[uniffi::export]
#[must_use]
pub fn stop_plan_message(plan_name: Option<String>) -> String {
    messages::stop_plan_message(plan_name.as_deref())
}

/// Whether `text` is the plan's stop message, whatever plan it names (web `isStopPlanMessage`).
#[uniffi::export]
#[must_use]
pub fn is_stop_plan_message(text: String) -> bool {
    messages::is_stop_plan_message(&text)
}

#[uniffi::export]
impl ClientCore {
    /// The session's journal as the Tasks tab reads it, in position order. Check
    /// `PanelFeatures::session_journal` first.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors and `MalformedResponse`.
    pub async fn session_journal(
        &self,
        session_id: String,
    ) -> Result<Vec<JournalEntry>, CoreError> {
        let entries = self
            .sessions()
            .session_journal(&session_id)
            .await
            .map_err(CoreError::from)?;
        Ok(entries.into_iter().map(Into::into).collect())
    }

    /// The entries after `after_id`, oldest first, to catch up after the stream was down;
    /// `None` when too many were missed and the journal should be read again.
    ///
    /// # Errors
    ///
    /// As [`ClientCore::session_journal`].
    pub async fn session_journal_since(
        &self,
        session_id: String,
        after_id: String,
    ) -> Result<Option<Vec<JournalEntry>>, CoreError> {
        let entries = self
            .sessions()
            .session_journal_since(&session_id, &after_id)
            .await
            .map_err(CoreError::from)?;
        Ok(entries.map(|entries| entries.into_iter().map(Into::into).collect()))
    }
}
