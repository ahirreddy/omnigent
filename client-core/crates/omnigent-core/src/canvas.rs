//! The Canvas page's layout: which board (Main or a project) a session's card is on, and where it
//! sits when the user has not placed it. Port of the web's `canvas/canvasLayout.ts`.
//!
//! Cards snap to a [`GRID_STEP`] lattice. Saved spots are kept for live sessions; the rest fill a
//! near-square grid per board, newest first, skipping cells a saved card already holds.

use std::collections::{BTreeMap, BTreeSet};

use crate::projects::ProjectSummary;
use crate::sessions::SessionSummary;

/// The lattice cards snap to.
pub const GRID_STEP: i64 = 32;
/// The board for sessions outside any project (or whose project is gone).
pub const MAIN_CANVAS_ID: &str = "main";
/// A saved coordinate's bound, as the web's storage.
pub const MAX_ABS_COORDINATE: i64 = 1_000_000;
const CELL_WIDTH: i64 = GRID_STEP * 10;
const CELL_HEIGHT: i64 = GRID_STEP * 5;

/// A card's top-left corner on its board.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CanvasPosition {
    /// Points from the board's origin.
    pub x: i64,
    /// Points from the board's origin.
    pub y: i64,
}

impl CanvasPosition {
    /// The position clamped to [`MAX_ABS_COORDINATE`].
    #[must_use]
    pub fn bounded(self) -> Self {
        let clamp = |value: i64| value.clamp(-MAX_ABS_COORDINATE, MAX_ABS_COORDINATE);
        Self {
            x: clamp(self.x),
            y: clamp(self.y),
        }
    }

    const fn cell(self) -> (i64, i64) {
        (
            div_round(self.x, CELL_WIDTH),
            div_round(self.y, CELL_HEIGHT),
        )
    }
}

/// `value / step` rounded half up, as JavaScript's `Math.round`.
const fn div_round(value: i64, step: i64) -> i64 {
    (value.saturating_mul(2).saturating_add(step)).div_euclid(step.saturating_mul(2))
}

/// The grid point nearest to `(x, y)`, where a dropped card lands.
#[must_use]
pub fn snap(x: i64, y: i64) -> CanvasPosition {
    CanvasPosition {
        x: div_round(x, GRID_STEP).saturating_mul(GRID_STEP),
        y: div_round(y, GRID_STEP).saturating_mul(GRID_STEP),
    }
    .bounded()
}

/// A project's board id: its id, or `name:<name>` for a legacy label-only project.
#[must_use]
pub fn project_canvas_id(project: &ProjectSummary) -> String {
    project
        .id
        .clone()
        .unwrap_or_else(|| format!("name:{}", project.name))
}

/// The board `session` is on: its project's (by the sidebar's membership rule), else Main.
#[must_use]
pub fn canvas_id_for(
    session: &SessionSummary,
    projects: &[ProjectSummary],
    viewer_id: Option<&str>,
) -> String {
    projects
        .iter()
        .find(|project| project.contains(session, viewer_id))
        .map_or_else(|| MAIN_CANVAS_ID.to_owned(), project_canvas_id)
}

/// Whether the Canvas shows `session`: the viewer's own, top-level and not archived.
#[must_use]
pub fn is_canvas_session(session: &SessionSummary, viewer_id: Option<&str>) -> bool {
    !session.is_archived
        && session.is_owned_by(viewer_id)
        && session
            .configuration
            .as_ref()
            .is_none_or(|configuration| configuration.parent_id.is_none())
}

/// The `index`th cell of a grid `columns` wide.
#[must_use]
pub fn grid_position(index: usize, columns: usize) -> CanvasPosition {
    let columns = columns.max(1);
    CanvasPosition {
        x: i64::try_from(index % columns)
            .unwrap_or(i64::MAX)
            .saturating_mul(CELL_WIDTH),
        y: i64::try_from(index / columns)
            .unwrap_or(i64::MAX)
            .saturating_mul(CELL_HEIGHT),
    }
}

/// Every saved spot of a live session kept, the rest laid out newest first on a near-square
/// grid that skips cells a saved card fills.
#[must_use]
pub fn merge_session_positions(
    sessions: &[&SessionSummary],
    saved: &BTreeMap<String, CanvasPosition>,
) -> BTreeMap<String, CanvasPosition> {
    let mut ordered: Vec<&SessionSummary> = sessions.to_vec();
    ordered.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.id.cmp(&right.id))
    });
    let mut positions = BTreeMap::new();
    let mut occupied = BTreeSet::new();
    for session in &ordered {
        if let Some(position) = saved.get(&session.id) {
            let position = position.bounded();
            occupied.insert(position.cell());
            positions.insert(session.id.clone(), position);
        }
    }
    let mut columns: usize = 1;
    while columns.saturating_mul(columns) < ordered.len() {
        columns += 1;
    }
    let mut candidate = 0;
    for session in &ordered {
        if positions.contains_key(&session.id) {
            continue;
        }
        let mut position = grid_position(candidate, columns);
        candidate += 1;
        while occupied.contains(&position.cell()) {
            position = grid_position(candidate, columns);
            candidate += 1;
        }
        occupied.insert(position.cell());
        positions.insert(session.id.clone(), position);
    }
    positions
}

/// Positions for every session, each board laid out on its own grid so boards never share
/// slots.
#[must_use]
pub fn merge_canvas_positions(
    sessions: &[SessionSummary],
    projects: &[ProjectSummary],
    saved: &BTreeMap<String, CanvasPosition>,
    viewer_id: Option<&str>,
) -> BTreeMap<String, CanvasPosition> {
    let mut boards: BTreeMap<String, Vec<&SessionSummary>> = BTreeMap::new();
    for session in sessions {
        boards
            .entry(canvas_id_for(session, projects, viewer_id))
            .or_default()
            .push(session);
    }
    boards
        .values()
        .flat_map(|board| merge_session_positions(board, saved))
        .collect()
}

/// `saved` with the cards on `canvas_id` laid out afresh on a grid ("Reset layout"); spots on
/// other boards, and of sessions not loaded yet, are kept.
#[must_use]
pub fn reset_canvas_positions(
    sessions: &[SessionSummary],
    projects: &[ProjectSummary],
    saved: &BTreeMap<String, CanvasPosition>,
    viewer_id: Option<&str>,
    canvas_id: &str,
) -> BTreeMap<String, CanvasPosition> {
    let board: Vec<&SessionSummary> = sessions
        .iter()
        .filter(|session| canvas_id_for(session, projects, viewer_id) == canvas_id)
        .collect();
    let mut positions: BTreeMap<String, CanvasPosition> = saved
        .iter()
        .filter(|(id, _)| !board.iter().any(|session| &session.id == *id))
        .map(|(id, position)| (id.clone(), *position))
        .collect();
    positions.extend(merge_session_positions(&board, &BTreeMap::new()));
    positions
}

#[cfg(test)]
#[path = "canvas_tests.rs"]
mod tests;
