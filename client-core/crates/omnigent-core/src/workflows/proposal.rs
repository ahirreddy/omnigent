//! The planning chat's proposal on a workflow's page: its steps, a description to review, and
//! what Save plan and an edited description write (`web/src/pages/WorkflowDetailPage.tsx`).

use super::WorkflowDetail;
use crate::session_journal::{JournalEntry, PlanStep, current_plan};

/// Where the description's source proposal sits in the planning chat's journal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SourcePosition {
    /// The server hasn't placed it yet; no description is offered meanwhile.
    Unknown,
    /// It came from another planning chat.
    Elsewhere,
    /// Its position.
    At(i64),
}

/// The entry id to place with [`SourcePosition`], when the description has a source the read
/// journal doesn't hold.
#[must_use]
pub fn description_source_to_place(
    workflow: &WorkflowDetail,
    entries: &[JournalEntry],
) -> Option<String> {
    let source = workflow.description_source.as_ref()?;
    (!entries.iter().any(|entry| &entry.id == source)).then(|| source.clone())
}

/// The planning chat's latest proposal for a workflow.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanProposal {
    /// The plan entry.
    pub entry_id: String,
    /// Its steps.
    pub steps: Vec<PlanStep>,
    /// Its description, when it is newer than the one the workflow's description came from.
    pub proposed_description: Option<String>,
    /// A different description that Save plan offers to apply; `None` keeps the current one.
    pub new_description: Option<String>,
    /// Save plan changes the workflow.
    pub has_changes: bool,
}

fn step_signature(steps: &[PlanStep]) -> Vec<(&str, &str, Option<&str>, &[String])> {
    steps
        .iter()
        .map(|step| {
            (
                step.id.as_str(),
                step.name.as_str(),
                step.goal.as_deref(),
                step.depends_on.as_slice(),
            )
        })
        .collect()
}

/// The planning chat's current proposal for `workflow`, from its journal `entries`.
///
/// `None` without one. Only a proposal newer than the description's source (or, without one,
/// than the workflow's last write) offers its description, so an edit made since stands.
#[must_use]
pub fn plan_proposal(
    workflow: &WorkflowDetail,
    entries: &[JournalEntry],
    source_position: SourcePosition,
) -> Option<PlanProposal> {
    let proposal = current_plan(entries)?;
    let source = workflow.description_source.as_deref();
    let source_at = source.map(|source| {
        entries
            .iter()
            .find(|entry| entry.id == source)
            .map_or(source_position, |entry| SourcePosition::At(entry.position))
    });
    let is_newer = match source_at {
        None | Some(SourcePosition::Elsewhere) => {
            proposal.created_at > workflow.workflow.updated_at
        }
        Some(SourcePosition::Unknown) => false,
        Some(SourcePosition::At(position)) => proposal.position > position,
    };
    let proposed_description = is_newer
        .then(|| proposal.plan_description().map(str::to_owned))
        .flatten();
    let has_steps = !proposal.steps.is_empty();
    let new_description = proposed_description
        .clone()
        .filter(|description| has_steps && *description != workflow.workflow.description);
    let has_changes = has_steps
        && (step_signature(&proposal.steps) != step_signature(&workflow.steps)
            || new_description.is_some());
    Some(PlanProposal {
        entry_id: proposal.id.clone(),
        steps: proposal.steps.clone(),
        proposed_description,
        new_description,
        has_changes,
    })
}

/// A description written with a plan, applied only while the stored one is still `expected`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DescriptionWrite {
    /// The description to store.
    pub description: String,
    /// The description the page showed.
    pub expected_description: String,
    /// The proposal it was saved from or kept over.
    pub description_source: String,
}

/// What Save plan writes: the proposal's steps and, with a proposed description, the one the user
/// chose. Keeping the current description still records the proposal, so it isn't offered again.
#[must_use]
pub fn plan_save_description(
    workflow: &WorkflowDetail,
    proposal: &PlanProposal,
    use_proposed: bool,
) -> Option<DescriptionWrite> {
    let proposed = proposal.proposed_description.as_ref()?;
    let kept = proposal.new_description.is_some() && !use_proposed;
    Some(DescriptionWrite {
        description: if kept {
            workflow.workflow.description.clone()
        } else {
            proposed.clone()
        },
        expected_description: workflow.workflow.description.clone(),
        description_source: proposal.entry_id.clone(),
    })
}

/// What Save does with an edited description.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DescriptionEdit {
    /// It is blank; a workflow needs a description.
    Blank,
    /// It is the current wording, unedited: keep it, and keep it for Save plan.
    KeepCurrent,
    /// It is the proposal's wording, unedited: Save plan applies it.
    UseProposed,
    /// Store this description.
    Write(String),
}

/// What saving `draft` does while the workflow says `current` and a proposal offers `proposed`.
#[must_use]
pub fn description_edit(draft: &str, current: &str, proposed: Option<&str>) -> DescriptionEdit {
    let next = draft.trim();
    if next.is_empty() {
        DescriptionEdit::Blank
    } else if next == current {
        DescriptionEdit::KeepCurrent
    } else if proposed == Some(next) {
        DescriptionEdit::UseProposed
    } else {
        DescriptionEdit::Write(next.to_owned())
    }
}
