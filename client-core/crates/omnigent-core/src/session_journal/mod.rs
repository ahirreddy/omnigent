//! A session's journal and the tasks it shows: the plan its agent follows and each step's
//! statuses, as the web's Tasks tab reads them.
//!
//! The server keeps the journal (`omnigent/server/session_journal.py`): `GET
//! /v1/sessions/{id}/journal` pages it by position, and the session stream pushes each new entry
//! (`session.journal.appended`). It is served only when `/v1/info` says `session_journal` and
//! `features.workflows`. Ground truth for how tasks read: `web/src/lib/sessionJournal.ts`,
//! `web/src/lib/taskActivity.ts` and `web/src/shell/TasksPanel.tsx`.
//!
//! - [`JournalEntry`] and [`JournalPage`]: the decoded records, keeping the content fields the
//!   Tasks tab reads.
//! - [`tasks`]: where each task stands ([`tasks::session_tasks`]), from the plan's steps or, without
//!   one, the agent's own task list.
//! - [`view`]: the tab row by row ([`view::tasks_view`]).
//! - [`messages`]: what a task's menu and the plan's controls ask the agent.

pub mod messages;
pub mod tasks;
pub mod view;

use serde_json::{Map, Value};

use crate::client::json::{as_object, opt_array, opt_bool, opt_str, req_str};

/// What a task waiting for the user says.
pub const WAITING_FOR_YOU: &str = "Waiting for you";

/// The kind of a journal entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JournalEntryKind {
    /// A step's status.
    Status,
    /// A note.
    Note,
    /// Work handed to another session.
    Dispatch,
    /// What handed-off work returned.
    DispatchResult,
    /// A plan: the steps and what each depends on.
    Plan,
    /// The start of a workflow run, which resets the steps' statuses.
    PlanStatus,
    /// A kind newer than this client.
    Unknown(String),
}

impl JournalEntryKind {
    /// The kind named `kind`, keeping one newer than this client.
    #[must_use]
    pub fn of(kind: &str) -> Self {
        match kind {
            "status" => Self::Status,
            "note" => Self::Note,
            "dispatch" => Self::Dispatch,
            "dispatch_result" => Self::DispatchResult,
            "plan" => Self::Plan,
            "plan_status" => Self::PlanStatus,
            other => Self::Unknown(other.to_owned()),
        }
    }
}

/// A step status the agent writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StepStatus {
    /// The step started, or resumed.
    Started,
    /// The step is done.
    Done,
    /// The step waits for the user.
    NeedsInput,
    /// The step failed.
    Failed,
}

impl StepStatus {
    /// The status named `value`, when it is one.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "started" => Self::Started,
            "done" => Self::Done,
            "needs_input" => Self::NeedsInput,
            "failed" => Self::Failed,
            _ => return None,
        })
    }

    /// How a step's history names it (`ENTRY_LABELS`).
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Started => "Started",
            Self::Done => "Done",
            Self::NeedsInput => WAITING_FOR_YOU,
            Self::Failed => "Failed",
        }
    }

    /// The name the server writes.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Started => "started",
            Self::Done => "done",
            Self::NeedsInput => "needs_input",
            Self::Failed => "failed",
        }
    }
}

/// One step of a plan.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanStep {
    /// Stable id, for example `build`.
    pub id: String,
    /// One line, for example `Build`.
    pub name: String,
    /// What it achieves.
    pub goal: Option<String>,
    /// The steps that must be done first.
    pub depends_on: Vec<String>,
}

/// The revision of a plan's graph: the server's id, or (from older servers) a position.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GraphRevision {
    /// `content.graph_revision` as a string.
    Text(String),
    /// A number: `content.graph_revision`, or the position of the plan that set the graph.
    Number(i64),
}

impl GraphRevision {
    fn of(value: &Value) -> Option<Self> {
        match value {
            Value::String(text) => Some(Self::Text(text.clone())),
            Value::Number(number) => number.as_i64().map(Self::Number),
            _ => None,
        }
    }
}

/// One entry of a session's journal, with the content fields the Tasks tab reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JournalEntry {
    /// Entry id.
    pub id: String,
    /// Its place in the journal: 0, 1, 2, ...
    pub position: i64,
    /// When it was appended, in epoch seconds.
    pub created_at: i64,
    /// The automation run the session was serving.
    pub scheduled_task_run_id: Option<String>,
    /// The plan step it is about.
    pub step: Option<String>,
    /// The kind.
    pub kind: JournalEntryKind,
    /// The saved workflow it was written under.
    pub workflow_id: Option<String>,
    /// `content.status`, when it is a step status.
    pub status: Option<StepStatus>,
    /// `content.text`.
    pub text: Option<String>,
    /// `content.name`: a plan's name.
    pub name: Option<String>,
    /// `content.steps`: a plan's steps.
    pub steps: Vec<PlanStep>,
    /// `content.version`: 1 for the session's first plan.
    pub version: Option<i64>,
    /// `content.graph_revision`.
    pub graph_revision: Option<GraphRevision>,
    /// `content.description`: the workflow description a planning chat proposed with its plan.
    pub description: Option<String>,
}

pub(crate) fn plan_steps(content: &Map<String, Value>) -> Vec<PlanStep> {
    let Some(Value::Array(steps)) = content.get("steps") else {
        return vec![];
    };
    steps
        .iter()
        .filter_map(Value::as_object)
        .filter_map(|step| {
            let id = step.get("id")?.as_str()?.to_owned();
            let name = step
                .get("name")
                .and_then(Value::as_str)
                .map_or_else(|| id.clone(), str::to_owned);
            let depends_on = step
                .get("depends_on")
                .and_then(Value::as_array)
                .map(|ids| {
                    ids.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default();
            Some(PlanStep {
                id,
                name,
                goal: step.get("goal").and_then(Value::as_str).map(str::to_owned),
                depends_on,
            })
        })
        .collect()
}

impl JournalEntry {
    /// Decodes one entry of `GET /v1/sessions/{id}/journal` or `session.journal.appended`.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "journal entry")?;
        let integer = |key: &str| -> Result<i64, String> {
            object
                .get(key)
                .and_then(Value::as_i64)
                .ok_or_else(|| format!("`{key}` is not an integer"))
        };
        let empty = Map::new();
        let content = match object.get("content") {
            Some(Value::Object(content)) => content,
            None | Some(Value::Null) => &empty,
            Some(_) => return Err("`content` is not an object".to_owned()),
        };
        let string = |key: &str| content.get(key).and_then(Value::as_str).map(str::to_owned);
        Ok(Self {
            id: req_str(object, "id")?,
            position: integer("position")?,
            created_at: integer("created_at")?,
            scheduled_task_run_id: opt_str(object, "scheduled_task_run_id")?,
            step: opt_str(object, "step")?,
            kind: JournalEntryKind::of(&req_str(object, "kind")?),
            workflow_id: opt_str(object, "workflow_id")?,
            status: content
                .get("status")
                .and_then(Value::as_str)
                .and_then(StepStatus::parse),
            text: string("text"),
            name: string("name"),
            steps: plan_steps(content),
            version: content.get("version").and_then(Value::as_i64),
            graph_revision: content.get("graph_revision").and_then(GraphRevision::of),
            description: string("description"),
        })
    }

    /// The workflow description a planning chat proposed with this plan, when it is not blank
    /// (`planDescription`).
    #[must_use]
    pub fn plan_description(&self) -> Option<&str> {
        self.description
            .as_deref()
            .filter(|description| !description.trim().is_empty())
    }

    /// A plan's name, when it has a non-blank one (`planName`).
    #[must_use]
    pub fn plan_name(&self) -> Option<&str> {
        self.name.as_deref().filter(|name| !name.trim().is_empty())
    }
}

/// One page of a session's journal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JournalPage {
    /// The entries, in the order asked for.
    pub data: Vec<JournalEntry>,
    /// The last entry's id, the cursor for the next page.
    pub last_id: Option<String>,
    /// More entries follow in the order asked for.
    pub has_more: bool,
}

impl JournalPage {
    /// Decodes a `GET /v1/sessions/{id}/journal` body.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "journal page")?;
        let data = opt_array(object, "data")?
            .map(|entries| {
                entries
                    .iter()
                    .map(JournalEntry::from_value)
                    .collect::<Result<Vec<_>, _>>()
            })
            .transpose()?
            .unwrap_or_default();
        Ok(Self {
            data,
            last_id: opt_str(object, "last_id")?,
            has_more: opt_bool(object, "has_more")?.unwrap_or(false),
        })
    }
}

/// Entries in position order without repeats; a later copy of an entry wins
/// (`mergeJournalEntries`).
#[must_use]
pub fn merge_journal_entries(lists: &[&[JournalEntry]]) -> Vec<JournalEntry> {
    let mut merged: Vec<JournalEntry> = Vec::new();
    for entry in lists.iter().flat_map(|list| list.iter()) {
        match merged.iter_mut().find(|known| known.id == entry.id) {
            Some(known) => known.clone_from(entry),
            None => merged.push(entry.clone()),
        }
    }
    merged.sort_by_key(|entry| entry.position);
    merged
}

/// The newest plan among `entries`, which are in position order (`currentPlan`).
#[must_use]
pub fn current_plan(entries: &[JournalEntry]) -> Option<&JournalEntry> {
    entries
        .iter()
        .rev()
        .find(|entry| entry.kind == JournalEntryKind::Plan)
}

/// The current graph's revision, kept across plans that change only its names
/// (`planGraphRevision`).
#[must_use]
pub fn plan_graph_revision(entries: &[JournalEntry]) -> Option<GraphRevision> {
    let plan_index = entries
        .iter()
        .rposition(|entry| entry.kind == JournalEntryKind::Plan)?;
    let plan = entries.get(plan_index)?;
    if let Some(recorded) = &plan.graph_revision {
        return Some(recorded.clone());
    }
    let graph = |entry: &JournalEntry| {
        let mut steps: Vec<(String, Vec<String>)> = entry
            .steps
            .iter()
            .map(|step| {
                let mut depends_on = step.depends_on.clone();
                depends_on.sort();
                (step.id.clone(), depends_on)
            })
            .collect();
        steps.sort_by(|left, right| left.0.cmp(&right.0));
        steps
    };
    let key = graph(plan);
    let mut position = plan.position;
    let mut previous = plan.position;
    for entry in entries.iter().take(plan_index).rev() {
        if entry.position != previous - 1 {
            break;
        }
        previous = entry.position;
        if entry.kind == JournalEntryKind::PlanStatus {
            break;
        }
        if entry.kind != JournalEntryKind::Plan {
            continue;
        }
        if graph(entry) != key {
            break;
        }
        position = entry.position;
    }
    Some(GraphRevision::Number(position))
}

/// The saved workflow the current plan came from (`planWorkflowId`): the plan that started the
/// run names it, and a later plan keeping one of its steps came from it too.
#[must_use]
pub fn plan_workflow_id(entries: &[JournalEntry]) -> Option<String> {
    let boundary = entries
        .iter()
        .rposition(|entry| entry.kind == JournalEntryKind::PlanStatus)
        .map_or(0, |index| index + 1);
    let invocation = entries.get(boundary..).unwrap_or_default();
    let plan = current_plan(invocation)?;
    if let Some(workflow) = &plan.workflow_id {
        return Some(workflow.clone());
    }
    let start = invocation
        .iter()
        .rev()
        .find(|entry| entry.kind == JournalEntryKind::Plan && entry.workflow_id.is_some())?;
    let shared = plan
        .steps
        .iter()
        .any(|step| start.steps.iter().any(|origin| origin.id == step.id));
    shared.then(|| start.workflow_id.clone()).flatten()
}

#[cfg(test)]
mod tests;
