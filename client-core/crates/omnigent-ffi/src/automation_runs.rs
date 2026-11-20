//! The plans an automation's runs follow, for the run history's tasks, status line, plan
//! control and graph. Records mirror `omnigent_core::workflows::automation_runs`.

use omnigent_core::workflows::automation_runs as core;

use crate::client::ClientCore;
use crate::errors::CoreError;
use crate::session_journal::{GraphRevision, JournalEntry, PlanStep, StepStatus};
use crate::workflows::WorkflowRun;

/// The latest plan one automation run wrote, with each step's newest status.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AutomationRunSteps {
    /// The automation run.
    pub run_id: String,
    /// The plan entry that started the run; `nil` on older servers.
    pub plan_id: Option<String>,
    /// The graph's id or legacy position.
    pub plan_graph_revision: Option<GraphRevision>,
    /// The plan is its session's current run.
    pub is_current: bool,
    /// The saved workflow the plan runs.
    pub workflow_id: Option<String>,
    /// The plan's name.
    pub plan_name: Option<String>,
    /// The latest plan's steps.
    pub steps: Vec<PlanStep>,
    /// Each step's newest status entry.
    pub statuses: Vec<JournalEntry>,
}

impl From<core::AutomationRunSteps> for AutomationRunSteps {
    fn from(run: core::AutomationRunSteps) -> Self {
        Self {
            run_id: run.run_id,
            plan_id: run.plan_id,
            plan_graph_revision: run.plan_graph_revision.map(Into::into),
            is_current: run.is_current,
            workflow_id: run.workflow_id,
            plan_name: run.plan_name,
            steps: run.steps.into_iter().map(Into::into).collect(),
            statuses: run.statuses.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<AutomationRunSteps> for core::AutomationRunSteps {
    fn from(run: AutomationRunSteps) -> Self {
        Self {
            run_id: run.run_id,
            plan_id: run.plan_id,
            plan_graph_revision: run.plan_graph_revision.map(Into::into),
            is_current: run.is_current,
            workflow_id: run.workflow_id,
            plan_name: run.plan_name,
            steps: run.steps.into_iter().map(Into::into).collect(),
            statuses: run.statuses.into_iter().map(Into::into).collect(),
        }
    }
}

/// What a run's agent last wrote about its work.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RunStatusText {
    /// The status it wrote.
    pub status: StepStatus,
    /// The status's label: "Done", "Waiting for you".
    pub label: String,
    /// Its words, e.g. "Opened 2 PRs".
    pub text: String,
}

/// The newest status words a run's agent wrote; `nil` when none gave any.
#[uniffi::export]
#[must_use]
pub fn automation_run_status_text(steps: AutomationRunSteps) -> Option<RunStatusText> {
    let steps: core::AutomationRunSteps = steps.into();
    core::latest_status_text(&steps.statuses).map(|found| RunStatusText {
        status: found.status.into(),
        label: found.status.label().to_owned(),
        text: found.text,
    })
}

/// Whether the run stops, continues or acts on its tasks: its session's current plan, with a
/// known plan entry.
#[uniffi::export]
#[must_use]
pub fn automation_run_takes_actions(steps: AutomationRunSteps) -> bool {
    core::AutomationRunSteps::from(steps).takes_actions()
}

/// The run as a workflow run of `session_id`, for its strip, graph and plan control.
#[uniffi::export]
#[must_use]
pub fn automation_run_workflow_run(
    steps: AutomationRunSteps,
    session_id: String,
    started_at: i64,
    session_working: bool,
) -> WorkflowRun {
    core::AutomationRunSteps::from(steps)
        .as_workflow_run(&session_id, started_at, session_working)
        .into()
}

#[uniffi::export]
impl ClientCore {
    /// The plans the newest runs of automation `id` follow; a viewer gets none.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`; the read errors and `MalformedResponse`.
    pub async fn automation_run_steps(
        &self,
        id: String,
    ) -> Result<Vec<AutomationRunSteps>, CoreError> {
        self.sessions()
            .automation_run_steps(&id)
            .await
            .map(|runs| runs.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }
}
