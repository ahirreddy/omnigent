//! Saved workflows: reusable plans an agent runs step by step, the sessions that ran them, and
//! what the Workflows pages say about them.
//!
//! The server keeps them (`omnigent/server/workflows.py`) and serves them while `/v1/info` says
//! `features.workflows` and `workflows`. Ground truth for how they read:
//! `web/src/hooks/useSavedWorkflows.ts`, `web/src/hooks/useWorkflow.ts`,
//! `web/src/lib/workflow.ts`, `web/src/lib/workflowRuns.ts`, `web/src/lib/savedWorkflowRun.ts`,
//! `web/src/lib/workflowGraphLayout.ts` and `web/src/pages/WorkflowDetailPage.tsx`.

use serde_json::{Map, Value, json};

use crate::automation_triggers::{
    decode_trigger_prompt, split_trigger_prompt, strip_trigger_header,
};
use crate::client::json::{as_object, opt_array, opt_bool, opt_object, opt_str, req_str};
use crate::session_journal::{GraphRevision, JournalEntry, PlanStep, plan_steps};

pub mod graph;
pub mod proposal;
pub mod runs;

/// The framework skill that plans and runs a workflow (`/workflow <description>`).
pub const WORKFLOW_SKILL: &str = "workflow";
/// The framework skill that saves a session's plan as a reusable workflow.
pub const SAVE_WORKFLOW_SKILL: &str = "save-workflow";
/// Added when the user reviews the plan before work starts.
pub const REVIEW_PLAN_FIRST: &str = "Let me review the plan before you start the work.";
/// The server's limit on a workflow's name, in characters.
pub const NAME_MAX_CHARS: usize = 80;
/// The server's limit on a workflow's description, in characters.
pub const DESCRIPTION_MAX_CHARS: usize = 2_000;

/// One of the caller's saved workflows, or one someone shared with them, as a list shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
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
    /// `false` when the server can't keep its grants, e.g. one saved before sharing existed.
    pub shareable: bool,
    /// When it was saved, in epoch seconds; 0 when the server didn't say.
    pub created_at: i64,
    /// Its last write, in epoch seconds; 0 when the server didn't say.
    pub updated_at: i64,
}

/// A saved workflow with its steps, as its page shows it (`GET /v1/workflows/{id}`).
#[derive(Debug, Clone, PartialEq, Eq)]
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

/// One page of workflows, and the cursor for the next.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowPage {
    /// The page's workflows.
    pub workflows: Vec<SavedWorkflow>,
    /// Pass as `after` for the next page; `None` on the last.
    pub next_cursor: Option<String>,
}

/// A run's session status, including its active direct sub-agents.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RunSessionStatus {
    /// Not working.
    Idle,
    /// Working.
    Running,
    /// Failed.
    Failed,
}

/// Where a run's latest plan stands, counted by each step's newest status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunStarter {
    /// Its id.
    pub session_id: String,
    /// Its title; empty when it has none yet.
    pub title: String,
}

/// One run of a saved workflow: a session that started it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts of the server's record, mirrored one to one"
)]
pub struct WorkflowRun {
    /// The id of the plan entry that started the run.
    pub id: String,
    /// The saved workflow the run follows; empty on servers that don't say.
    pub workflow_id: String,
    /// The graph's id or legacy position; `None` on older servers.
    pub plan_graph_revision: Option<GraphRevision>,
    /// The run's session.
    pub session_id: String,
    /// The session's title; empty when it has none yet.
    pub title: String,
    /// When the run's plan was written, in epoch seconds.
    pub started_at: i64,
    /// Only the session's current run can use its activity and take actions.
    pub is_current: bool,
    /// The session's status.
    pub session_status: RunSessionStatus,
    /// Work outlives the session's turn, such as background shells or an active goal.
    pub background_work_running: bool,
    /// The session's sandbox is still launching, so the run is starting.
    pub sandbox_launching: bool,
    /// The session is archived.
    pub archived: bool,
    /// The run's steps, counted by their current status.
    pub progress: RunProgress,
    /// The latest plan's steps within this invocation.
    pub steps: Vec<PlanStep>,
    /// Each of those steps' newest status entry.
    pub statuses: Vec<JournalEntry>,
    /// Its workflow's name when the workflow is the caller's; `None` for someone else's or a
    /// deleted one.
    pub workflow_name: Option<String>,
    /// The session that started it, when another session did and the caller can read it.
    pub started_by: Option<RunStarter>,
    /// The first page of the workflow runs below this one, each right after its starter.
    pub descendant_runs: Vec<Self>,
    /// How many workflow runs are below this one, on every page.
    pub descendant_run_count: u32,
    /// Continues `descendant_runs`; `None` when they are all here.
    pub descendant_runs_cursor: Option<String>,
    /// Some run below this one, on any page, is working or waiting for input.
    pub descendant_runs_active: bool,
}

/// One page of runs, newest first, and the cursor for the next.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowRunPage {
    /// The page's runs.
    pub runs: Vec<WorkflowRun>,
    /// Pass as `before` (runs) or `after` (descendant runs) for the next page.
    pub next_cursor: Option<String>,
}

fn opt_i64(object: &Map<String, Value>, key: &str) -> Result<Option<i64>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_i64()
            .map(Some)
            .ok_or_else(|| format!("`{key}` is not an integer")),
    }
}

fn count(object: &Map<String, Value>, key: &str) -> Result<u32, String> {
    let value = opt_i64(object, key)?.unwrap_or(0).max(0);
    Ok(u32::try_from(value).unwrap_or(u32::MAX))
}

impl SavedWorkflow {
    /// Decodes a workflow of `GET /v1/workflows`, `/v1/workflows/shared` or `/v1/workflows/{id}`.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "workflow")?;
        Ok(Self {
            id: req_str(object, "id")?,
            name: req_str(object, "name")?,
            description: opt_str(object, "description")?.unwrap_or_default(),
            is_draft: opt_bool(object, "is_draft")?.unwrap_or(false),
            shared_with_me: opt_str(object, "viewer_role")?.as_deref() == Some("viewer"),
            owner_display_name: opt_str(object, "owner_display_name")?
                .filter(|name| !name.trim().is_empty()),
            shareable: opt_bool(object, "shareable")?.unwrap_or(true),
            created_at: opt_i64(object, "created_at")?.unwrap_or(0),
            updated_at: opt_i64(object, "updated_at")?.unwrap_or(0),
        })
    }

    /// Who shared it, for "Shared by …": the owner's name, else "someone else".
    #[must_use]
    pub fn shared_by(&self) -> Option<String> {
        self.shared_with_me.then(|| {
            self.owner_display_name
                .clone()
                .unwrap_or_else(|| "someone else".to_owned())
        })
    }
}

impl WorkflowDetail {
    /// Decodes `GET /v1/workflows/{id}` and the answers of its writes.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "workflow")?;
        let mut workflow = SavedWorkflow::from_value(value)?;
        let steps = plan_steps(object);
        // An older server leaves the draft flag out; a workflow with no steps has no plan.
        if object.get("is_draft").is_none() {
            workflow.is_draft = steps.is_empty();
        }
        Ok(Self {
            workflow,
            steps,
            planning_session_id: opt_str(object, "planning_session_id")?,
            description_source: opt_str(object, "description_source")?,
        })
    }
}

fn workflows_of(object: &Map<String, Value>) -> Result<Vec<SavedWorkflow>, String> {
    opt_array(object, "data")?
        .map(|rows| rows.iter().map(SavedWorkflow::from_value).collect())
        .transpose()
        .map(Option::unwrap_or_default)
}

impl WorkflowPage {
    /// Decodes a page of the caller's own workflows (`GET /v1/workflows`): `next_cursor`, else
    /// (older servers) `last_id`, while `has_more`.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_owned_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "workflow list")?;
        let has_more = opt_bool(object, "has_more")?.unwrap_or(false);
        let cursor = opt_str(object, "next_cursor")?.or(opt_str(object, "last_id")?);
        Ok(Self {
            workflows: workflows_of(object)?,
            next_cursor: if has_more { cursor } else { None },
        })
    }

    /// Decodes a page of the workflows shared with the caller (`GET /v1/workflows/shared`); each
    /// is someone else's, whatever an older row says.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_shared_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "shared workflow list")?;
        let workflows = workflows_of(object)?
            .into_iter()
            .map(|workflow| SavedWorkflow {
                shared_with_me: true,
                ..workflow
            })
            .collect();
        Ok(Self {
            workflows,
            next_cursor: opt_str(object, "next_cursor")?,
        })
    }
}

fn graph_revision(value: Option<&Value>) -> Option<GraphRevision> {
    match value? {
        Value::String(text) => Some(GraphRevision::Text(text.clone())),
        Value::Number(number) => number.as_i64().map(GraphRevision::Number),
        _ => None,
    }
}

impl WorkflowRun {
    /// Decodes a run of `GET /v1/workflows/{id}/runs` or its descendant pages.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "workflow run")?;
        let progress = opt_object(object, "progress")?
            .map(|progress| -> Result<RunProgress, String> {
                Ok(RunProgress {
                    total: count(progress, "total")?,
                    started: count(progress, "started")?,
                    done: count(progress, "done")?,
                    needs_input: count(progress, "needs_input")?,
                    failed: count(progress, "failed")?,
                })
            })
            .transpose()?
            .unwrap_or_default();
        let session_status = match opt_str(object, "session_status")?.as_deref() {
            Some("running") => RunSessionStatus::Running,
            Some("failed") => RunSessionStatus::Failed,
            _ => RunSessionStatus::Idle,
        };
        let started_by = opt_object(object, "started_by")?
            .map(|starter| -> Result<RunStarter, String> {
                Ok(RunStarter {
                    session_id: req_str(starter, "session_id")?,
                    title: opt_str(starter, "title")?.unwrap_or_default(),
                })
            })
            .transpose()?;
        let statuses = opt_array(object, "statuses")?
            .map(|rows| rows.iter().map(JournalEntry::from_value).collect())
            .transpose()?
            .unwrap_or_default();
        let descendant_runs = opt_array(object, "descendant_runs")?
            .map(|rows| rows.iter().map(Self::from_value).collect())
            .transpose()?
            .unwrap_or_default();
        Ok(Self {
            id: req_str(object, "id")?,
            workflow_id: opt_str(object, "workflow_id")?.unwrap_or_default(),
            plan_graph_revision: graph_revision(object.get("plan_graph_revision")),
            session_id: req_str(object, "session_id")?,
            title: opt_str(object, "title")?.unwrap_or_default(),
            started_at: opt_i64(object, "started_at")?.unwrap_or(0),
            is_current: opt_bool(object, "is_current")?.unwrap_or(false),
            session_status,
            background_work_running: opt_bool(object, "background_work_running")?.unwrap_or(false),
            sandbox_launching: opt_bool(object, "sandbox_launching")?.unwrap_or(false),
            archived: opt_bool(object, "archived")?.unwrap_or(false),
            progress,
            steps: plan_steps(object),
            statuses,
            workflow_name: opt_str(object, "workflow_name")?,
            started_by,
            descendant_runs,
            descendant_run_count: count(object, "descendant_run_count")?,
            descendant_runs_cursor: opt_str(object, "descendant_runs_cursor")?,
            descendant_runs_active: opt_bool(object, "descendant_runs_active")?.unwrap_or(false),
        })
    }
}

impl WorkflowRunPage {
    /// Decodes a page of runs.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "workflow run list")?;
        Ok(Self {
            runs: opt_array(object, "data")?
                .map(|rows| rows.iter().map(WorkflowRun::from_value).collect())
                .transpose()?
                .unwrap_or_default(),
            next_cursor: opt_str(object, "next_cursor")?,
        })
    }
}

/// `steps` as the server takes them.
#[must_use]
pub fn steps_json(steps: &[PlanStep]) -> Value {
    Value::Array(
        steps
            .iter()
            .map(|step| {
                json!({
                    "id": step.id,
                    "name": step.name,
                    "goal": step.goal,
                    "depends_on": step.depends_on,
                })
            })
            .collect(),
    )
}

// MARK: Lists

/// The workflows whose name or description contains `query`, ignoring case (the Workflows
/// page's search).
#[must_use]
pub fn matching_workflows(workflows: &[SavedWorkflow], query: &str) -> Vec<SavedWorkflow> {
    let query = query.trim().to_lowercase();
    workflows
        .iter()
        .filter(|workflow| {
            query.is_empty()
                || workflow.name.to_lowercase().contains(&query)
                || workflow.description.to_lowercase().contains(&query)
        })
        .cloned()
        .collect()
}

/// The workflows Run a workflow offers: those with a saved plan whose name contains `query`,
/// ignoring case (`WorkflowPicker`).
#[must_use]
pub fn runnable_workflows(workflows: &[SavedWorkflow], query: &str) -> Vec<SavedWorkflow> {
    let query = query.trim().to_lowercase();
    workflows
        .iter()
        .filter(|workflow| !workflow.is_draft && workflow.name.to_lowercase().contains(&query))
        .cloned()
        .collect()
}

/// Whether `name`, trimmed, is already one of `taken` (New workflow refuses it).
#[must_use]
pub fn workflow_name_taken(taken: &[String], name: &str) -> bool {
    let name = name.trim();
    !name.is_empty() && taken.iter().any(|taken| taken == name)
}

/// The name of a workflow's `copy`th clone: "Name (copy)", then "Name (copy 2)", …, cut to fit
/// the name limit.
#[must_use]
pub fn clone_name(name: &str, copy: u32) -> String {
    let suffix = if copy <= 1 {
        " (copy)".to_owned()
    } else {
        format!(" (copy {copy})")
    };
    let room = NAME_MAX_CHARS.saturating_sub(suffix.chars().count());
    let kept: String = name.chars().take(room).collect();
    format!("{}{suffix}", kept.trim_end())
}

// MARK: Messages

/// The message that runs the workflow skill for `description`.
#[must_use]
pub fn workflow_message(skill_prefix: &str, description: &str, review_plan_first: bool) -> String {
    let command = format!("{skill_prefix}{WORKFLOW_SKILL} {}", description.trim());
    if review_plan_first {
        format!("{command}\n\n{REVIEW_PLAN_FIRST}")
    } else {
        command
    }
}

/// The message that runs one of the caller's saved workflows, which the skill loads by id.
#[must_use]
pub fn saved_workflow_message(
    skill_prefix: &str,
    workflow_id: &str,
    workflow_name: &str,
    details: &str,
    review_plan_first: bool,
) -> String {
    let mut paragraphs = vec![format!(
        "Run the saved workflow \"{workflow_name}\" (ID {workflow_id})."
    )];
    if !details.trim().is_empty() {
        paragraphs.push(details.trim().to_owned());
    }
    if review_plan_first {
        paragraphs.push(REVIEW_PLAN_FIRST.to_owned());
    }
    format!("{skill_prefix}{WORKFLOW_SKILL} {}", paragraphs.join("\n\n"))
}

/// The message that saves the session's plan as a workflow named `name`.
#[must_use]
pub fn save_workflow_message(skill_prefix: &str, name: &str) -> String {
    format!(
        "{skill_prefix}{SAVE_WORKFLOW_SKILL} Save this session's plan as a workflow named \"{}\".",
        name.trim()
    )
}

/// The first message of a session that runs a saved workflow. It names the skill rather than
/// invoking it, since the agent can change after it is written.
#[must_use]
pub fn run_saved_workflow_prompt(
    workflow_id: &str,
    workflow_name: &str,
    details: &str,
    review_plan_first: bool,
) -> String {
    let mut paragraphs = vec![
        format!(
            "Use the {WORKFLOW_SKILL} skill to run the saved workflow \"{workflow_name}\" (ID {workflow_id})."
        ),
        "If the session journal already contains this workflow's plan, continue that run without writing a second starting plan.".to_owned(),
    ];
    if !details.trim().is_empty() {
        paragraphs.push(details.trim().to_owned());
    }
    if review_plan_first {
        paragraphs.push(REVIEW_PLAN_FIRST.to_owned());
    }
    paragraphs.join("\n\n")
}

/// The planning chat's first message: propose a graph and its description, which Save plan on
/// the workflow's page applies (`editWorkflowPlanPrompt`).
#[must_use]
pub fn edit_workflow_plan_prompt(workflow: &WorkflowDetail) -> String {
    let has_saved_plan = !workflow.steps.is_empty();
    [
        format!(
            "Help me {} the reusable workflow \"{}\" (ID {}).",
            if has_saved_plan { "edit" } else { "design" },
            workflow.workflow.name,
            workflow.workflow.id
        ),
        format!("Workflow description: {}", workflow.workflow.description),
        "This is a planning conversation. Load the existing workflow with sys_workflow_load. Explore context if useful, but do not execute the workflow or make changes to the project.".to_owned(),
        "Use sys_journal_write_plan to publish the proposed steps, and write a new plan whenever I ask for revisions. Keep step IDs stable. Do not set workflow_id on this journal plan: this conversation is for planning, not an execution run.".to_owned(),
        "Write each step's goal for me first, in plain language and short Markdown bullets, as the save-workflow skill's Step descriptions section shows: **Inputs:** (what it reads and from where, such as a Slack channel, a PR or another MCP server), **What it does:** (a few bullets) and **Outputs:** (what it produces, such as a PR link or a report). Put the exact commands, paths and flags a run needs after them, under **Details:**. A run works from the same goal, so keep those details.".to_owned(),
        "Set description on every plan you publish. Keep the current description's wording: change only what the proposed steps make inaccurate, add only what a run needs that it leaves out, and repeat it unchanged when it still fits. I review a changed description before Save plan applies it.".to_owned(),
        "The workflow already exists. Do not call sys_workflow_save or create another workflow. I will use Save plan on the workflow page to apply the proposal.".to_owned(),
        if has_saved_plan {
            "Read the saved plan and use it as the starting point. Ask what edits I want and wait for my answer before proposing or publishing changes. Preserve steps I haven't asked to change, and iterate with me on my requested edits.".to_owned()
        } else {
            "Draft a useful first proposal now, explain assumptions briefly, and iterate with me here.".to_owned()
        },
    ]
    .join("\n\n")
}

/// A saved workflow's run, read back from a message or an automation's instructions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedWorkflowRun {
    /// The workflow's id.
    pub id: String,
    /// Its name when the message was written.
    pub name: String,
    /// The run's details; empty when there are none.
    pub details: String,
}

fn is_workflow_id(id: &str) -> bool {
    id.len() == 32
        && id
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// The saved workflow `instructions` run, such as an automation's prompt
/// (`parseSavedWorkflowRun`; keep in step with `_SAVED_WORKFLOW_RUN` in
/// `omnigent/server/scheduled/workflow_automations.py`).
#[must_use]
pub fn parse_saved_workflow_run(instructions: &str) -> Option<SavedWorkflowRun> {
    let text = instructions.trim();
    let (line, rest) = text
        .split_once('\n')
        .map_or((text, None), |(line, rest)| (line, Some(rest)));
    let body = line
        .strip_prefix('/')
        .or_else(|| line.strip_prefix('$'))?
        .strip_prefix("workflow Run the saved workflow \"")?
        .strip_suffix(").")?;
    let (name, id) = body.rsplit_once("\" (ID ")?;
    if name.is_empty() || name.contains('\r') || !is_workflow_id(id) {
        return None;
    }
    let details = match rest {
        None => String::new(),
        // The details follow a blank line.
        Some(rest) => rest.strip_prefix('\n')?.trim().to_owned(),
    };
    Some(SavedWorkflowRun {
        id: id.to_owned(),
        name: name.to_owned(),
        details,
    })
}

/// The saved workflow a message runs, directly or inside a trigger's prompt
/// (`parseSavedWorkflowMessage`).
#[must_use]
pub fn parse_saved_workflow_message(text: &str) -> Option<SavedWorkflowRun> {
    let instructions = decode_trigger_prompt(text).map_or_else(
        || split_trigger_prompt(strip_trigger_header(text)).user_prompt,
        |config| config.fields.instructions,
    );
    parse_saved_workflow_run(&instructions)
}

/// Whether an automation whose prompt is `prompt` runs the saved workflow `workflow_id`
/// (`automationsUsingWorkflow`).
#[must_use]
pub fn prompt_runs_workflow(prompt: &str, workflow_id: &str) -> bool {
    parse_saved_workflow_message(prompt).is_some_and(|run| run.id == workflow_id)
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
