//! A workflow's steps laid out as a graph (`web/src/lib/workflowGraphLayout.ts`).

use std::collections::{BTreeMap, BTreeSet};

use crate::session_journal::PlanStep;

/// One step's box in the graph.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StepNode {
    /// The step's id.
    pub id: String,
    /// Its place in the workflow, from 1.
    pub number: u32,
    /// Its row, from 0: one below the lowest step it waits for.
    pub row: u32,
    /// Its left edge in half columns, so each row is centered under the widest.
    pub half_column: u32,
}

/// An arrow from a step to one that waits for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StepEdge {
    /// The step waited for.
    pub from: String,
    /// The step that waits.
    pub to: String,
}

/// The steps laid out top to bottom by dependency (`layoutWorkflowSteps`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
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

fn row_of<'a>(
    id: &'a str,
    by_id: &BTreeMap<&'a str, &'a PlanStep>,
    rows: &mut BTreeMap<&'a str, u32>,
    visiting: &mut BTreeSet<&'a str>,
) -> u32 {
    if let Some(row) = rows.get(id) {
        return *row;
    }
    // A cycle is ignored; saved workflows have none.
    if !visiting.insert(id) {
        return 0;
    }
    let mut row = 0;
    if let Some(step) = by_id.get(id) {
        for dependency in &step.depends_on {
            if let Some((key, _)) = by_id.get_key_value(dependency.as_str()) {
                row = row.max(row_of(key, by_id, rows, visiting).saturating_add(1));
            }
        }
    }
    visiting.remove(id);
    rows.insert(id, row);
    row
}

/// Lays `steps` out: steps that can run at once share a row, rows keep the workflow's order and
/// are centered, and an edge another path already implies is left out.
#[must_use]
pub fn layout_steps(steps: &[PlanStep]) -> StepsLayout {
    let by_id: BTreeMap<&str, &PlanStep> =
        steps.iter().map(|step| (step.id.as_str(), step)).collect();
    let mut rows: BTreeMap<&str, u32> = BTreeMap::new();
    let mut visiting = BTreeSet::new();
    for step in steps {
        row_of(&step.id, &by_id, &mut rows, &mut visiting);
    }
    let mut members: BTreeMap<u32, Vec<&PlanStep>> = BTreeMap::new();
    for step in steps {
        let row = rows.get(step.id.as_str()).copied().unwrap_or(0);
        members.entry(row).or_default().push(step);
    }
    let widest = members.values().map(Vec::len).max().unwrap_or(0);
    let mut nodes = Vec::new();
    for (row, row_steps) in &members {
        let offset = widest.saturating_sub(row_steps.len());
        for (slot, step) in row_steps.iter().enumerate() {
            let number = steps
                .iter()
                .position(|candidate| candidate.id == step.id)
                .map_or(0, |index| index.saturating_add(1));
            nodes.push(StepNode {
                id: step.id.clone(),
                number: u32::try_from(number).unwrap_or(u32::MAX),
                row: *row,
                half_column: u32::try_from(offset.saturating_add(slot.saturating_mul(2)))
                    .unwrap_or(u32::MAX),
            });
        }
    }
    nodes.sort_by_key(|node| node.number);
    StepsLayout {
        nodes,
        edges: reduced_edges(steps, &by_id),
        rows: u32::try_from(members.len()).unwrap_or(u32::MAX),
        columns: u32::try_from(widest).unwrap_or(u32::MAX),
    }
}

fn reduced_edges(steps: &[PlanStep], by_id: &BTreeMap<&str, &PlanStep>) -> Vec<StepEdge> {
    let mut dependencies: BTreeMap<&str, BTreeSet<&str>> = steps
        .iter()
        .map(|step| {
            let known = step
                .depends_on
                .iter()
                .map(String::as_str)
                .filter(|id| by_id.contains_key(id) && *id != step.id)
                .collect();
            (step.id.as_str(), known)
        })
        .collect();
    let snapshot = dependencies.clone();
    for (id, direct) in &mut dependencies {
        let original: Vec<&str> = direct.iter().copied().collect();
        for dependency in original {
            let mut pending: Vec<&str> = direct
                .iter()
                .copied()
                .filter(|other| *other != dependency)
                .collect();
            let mut visited = BTreeSet::from([*id]);
            while let Some(current) = pending.pop() {
                if current == dependency {
                    direct.remove(dependency);
                    break;
                }
                if !visited.insert(current) {
                    continue;
                }
                if let Some(next) = snapshot.get(current) {
                    pending.extend(next.iter().copied());
                }
            }
        }
    }
    let mut edges = Vec::new();
    for step in steps {
        let Some(kept) = dependencies.get(step.id.as_str()) else {
            continue;
        };
        let mut drawn = BTreeSet::new();
        for dependency in &step.depends_on {
            if kept.contains(dependency.as_str()) && drawn.insert(dependency.as_str()) {
                edges.push(StepEdge {
                    from: dependency.clone(),
                    to: step.id.clone(),
                });
            }
        }
    }
    edges
}
