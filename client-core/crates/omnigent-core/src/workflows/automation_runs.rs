//! The plans an automation's runs follow (`GET /v1/scheduled-tasks/{id}/run-steps`).
//!
//! The run history shows each: a segment per task, what the agent last wrote, the plan's control
//! and its graph (`web/src/pages/TaskDetailPage.tsx` `RunRow`, `useScheduledTaskRunSteps`).

use serde_json::Value;

use super::{RunProgress, RunSessionStatus, WorkflowRun, graph_revision};
use crate::client::json::{as_object, opt_array, opt_bool, opt_str, req_str};
use crate::session_journal::{
    GraphRevision, JournalEntry, JournalEntryKind, PlanStep, StepStatus, plan_steps,
};

/// The latest plan one automation run wrote within its invocation, with each step's newest
/// status.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutomationRunSteps {
    /// The automation run.
    pub run_id: String,
    /// The plan entry that started the run; `None` on older servers, which take no actions.
    pub plan_id: Option<String>,
    /// The graph's id or legacy position; `None` on older servers.
    pub plan_graph_revision: Option<GraphRevision>,
    /// The plan is its session's current run, so it shows the session's activity and acts.
    pub is_current: bool,
    /// The saved workflow the plan runs, when it named one.
    pub workflow_id: Option<String>,
    /// The plan's name.
    pub plan_name: Option<String>,
    /// The latest plan's steps.
    pub steps: Vec<PlanStep>,
    /// Each step's newest status entry.
    pub statuses: Vec<JournalEntry>,
}

impl AutomationRunSteps {
    /// Decodes one run of a `run-steps` page.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "run steps")?;
        let statuses = opt_array(object, "statuses")?
            .map(|rows| rows.iter().map(JournalEntry::from_value).collect())
            .transpose()?
            .unwrap_or_default();
        Ok(Self {
            run_id: req_str(object, "run_id")?,
            plan_id: opt_str(object, "plan_id")?,
            plan_graph_revision: graph_revision(object.get("plan_graph_revision")),
            is_current: opt_bool(object, "is_current")?.unwrap_or(false),
            workflow_id: opt_str(object, "workflow_id")?.filter(|id| !id.is_empty()),
            plan_name: opt_str(object, "plan_name")?.filter(|name| !name.trim().is_empty()),
            steps: plan_steps(object),
            statuses,
        })
    }

    /// Only the session's current run with a known plan entry stops, continues or acts on a
    /// task (`canAct`).
    #[must_use]
    pub const fn takes_actions(&self) -> bool {
        self.is_current && self.plan_id.is_some()
    }

    /// The run as a workflow run of `session_id`, for its timeline, graph and plan control;
    /// `session_working` is the session's live activity.
    #[must_use]
    pub fn as_workflow_run(
        &self,
        session_id: &str,
        started_at: i64,
        session_working: bool,
    ) -> WorkflowRun {
        WorkflowRun {
            id: self.plan_id.clone().unwrap_or_else(|| self.run_id.clone()),
            workflow_id: self.workflow_id.clone().unwrap_or_default(),
            plan_graph_revision: self.plan_graph_revision.clone(),
            session_id: session_id.to_owned(),
            title: self.plan_name.clone().unwrap_or_default(),
            started_at,
            is_current: self.is_current,
            session_status: if session_working {
                RunSessionStatus::Running
            } else {
                RunSessionStatus::Idle
            },
            background_work_running: false,
            sandbox_launching: false,
            // The server counts an archived session's plan as not current.
            archived: false,
            progress: RunProgress::default(),
            steps: self.steps.clone(),
            statuses: self.statuses.clone(),
            workflow_name: None,
            started_by: None,
            descendant_runs: vec![],
            descendant_run_count: 0,
            descendant_runs_cursor: None,
            descendant_runs_active: false,
        }
    }
}

/// What a run's agent last wrote about its work: the status and the few words it gave.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusText {
    /// The status it wrote.
    pub status: StepStatus,
    /// Its words, e.g. "Opened 2 PRs".
    pub text: String,
}

impl StatusText {
    /// The words with the status's label before them: "Done: Opened 2 PRs".
    #[must_use]
    pub fn labeled(&self) -> String {
        format!("{}: {}", self.status.label(), self.text)
    }
}

/// The newest status among `statuses` that gave some words (`latestStatusText`); a status
/// without text, such as a bare `started`, doesn't count.
#[must_use]
pub fn latest_status_text(statuses: &[JournalEntry]) -> Option<StatusText> {
    statuses
        .iter()
        .filter(|entry| entry.kind == JournalEntryKind::Status)
        .filter_map(|entry| {
            let text = entry.text.as_deref()?.trim();
            let status = entry.status?;
            (!text.is_empty()).then_some((entry.position, status, text))
        })
        .fold(
            None::<(i64, StepStatus, &str)>,
            |newest, candidate| match newest {
                Some(found) if found.0 >= candidate.0 => Some(found),
                _ => Some(candidate),
            },
        )
        .map(|(_, status, text)| StatusText {
            status,
            text: text.to_owned(),
        })
}

/// Decodes a `run-steps` page: its runs and the next page's cursor.
///
/// # Errors
///
/// A description of the first field with the wrong shape.
pub fn run_steps_page(value: &Value) -> Result<(Vec<AutomationRunSteps>, Option<String>), String> {
    let object = as_object(value, "run steps page")?;
    let runs = opt_array(object, "runs")?
        .into_iter()
        .flatten()
        .map(AutomationRunSteps::from_value)
        .collect::<Result<_, _>>()?;
    Ok((runs, opt_str(object, "next_cursor")?))
}

#[cfg(test)]
#[path = "automation_runs_tests.rs"]
mod tests;
