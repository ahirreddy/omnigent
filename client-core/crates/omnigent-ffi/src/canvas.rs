//! The Canvas page: the caller's sessions as cards on one board per project plus Main. The
//! rules are `omnigent_core::canvas`.

use std::collections::{BTreeMap, HashMap};

use omnigent_core::canvas as core;
use omnigent_core::projects::ProjectSummary as CoreProject;
use omnigent_core::sessions::SessionSummary as CoreSummary;

use crate::client::ClientCore;
use crate::errors::CoreError;
use crate::sessions::{ProjectSummary, SessionSummary};

/// A card's top-left corner on its board, in points.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct CanvasPosition {
    /// Points from the board's origin.
    pub x: i64,
    /// Points from the board's origin.
    pub y: i64,
}

impl From<core::CanvasPosition> for CanvasPosition {
    fn from(position: core::CanvasPosition) -> Self {
        Self {
            x: position.x,
            y: position.y,
        }
    }
}

impl From<CanvasPosition> for core::CanvasPosition {
    fn from(position: CanvasPosition) -> Self {
        Self {
            x: position.x,
            y: position.y,
        }
    }
}

fn core_inputs(
    sessions: &[SessionSummary],
    projects: Vec<ProjectSummary>,
    saved: HashMap<String, CanvasPosition>,
) -> (
    Vec<CoreSummary>,
    Vec<CoreProject>,
    BTreeMap<String, core::CanvasPosition>,
) {
    (
        sessions.iter().map(Into::into).collect(),
        projects.into_iter().map(Into::into).collect(),
        saved
            .into_iter()
            .map(|(id, position)| (id, position.into()))
            .collect(),
    )
}

fn positions(map: BTreeMap<String, core::CanvasPosition>) -> HashMap<String, CanvasPosition> {
    map.into_iter()
        .map(|(id, position)| (id, position.into()))
        .collect()
}

/// The board of sessions outside any project.
#[must_use]
#[uniffi::export]
pub fn main_canvas_id() -> String {
    core::MAIN_CANVAS_ID.to_owned()
}

/// A project's board id.
#[must_use]
#[uniffi::export]
pub fn project_canvas_id(project: ProjectSummary) -> String {
    core::project_canvas_id(&project.into())
}

/// The board `session` is on: its project's, else Main.
#[must_use]
#[uniffi::export]
pub fn canvas_id_for(
    session: SessionSummary,
    projects: Vec<ProjectSummary>,
    viewer_id: Option<String>,
) -> String {
    let projects: Vec<CoreProject> = projects.into_iter().map(Into::into).collect();
    core::canvas_id_for(&(&session).into(), &projects, viewer_id.as_deref())
}

/// Whether the Canvas shows `session`: the viewer's own, top-level and not archived.
#[must_use]
#[uniffi::export]
pub fn is_canvas_session(session: SessionSummary, viewer_id: Option<String>) -> bool {
    core::is_canvas_session(&(&session).into(), viewer_id.as_deref())
}

/// Every card's position: saved spots for live sessions, the rest on each board's grid.
#[allow(
    clippy::implicit_hasher,
    reason = "UniFFI maps records to HashMap with the default hasher"
)]
#[must_use]
#[uniffi::export]
pub fn canvas_positions(
    sessions: Vec<SessionSummary>,
    projects: Vec<ProjectSummary>,
    saved: HashMap<String, CanvasPosition>,
    viewer_id: Option<String>,
) -> HashMap<String, CanvasPosition> {
    let (sessions, projects, saved) = core_inputs(&sessions, projects, saved);
    positions(core::merge_canvas_positions(
        &sessions,
        &projects,
        &saved,
        viewer_id.as_deref(),
    ))
}

/// `saved` with `canvas_id`'s cards laid out afresh ("Reset layout").
#[allow(
    clippy::implicit_hasher,
    reason = "UniFFI maps records to HashMap with the default hasher"
)]
#[must_use]
#[uniffi::export]
pub fn reset_canvas_positions(
    sessions: Vec<SessionSummary>,
    projects: Vec<ProjectSummary>,
    saved: HashMap<String, CanvasPosition>,
    viewer_id: Option<String>,
    canvas_id: String,
) -> HashMap<String, CanvasPosition> {
    let (sessions, projects, saved) = core_inputs(&sessions, projects, saved);
    positions(core::reset_canvas_positions(
        &sessions,
        &projects,
        &saved,
        viewer_id.as_deref(),
        &canvas_id,
    ))
}

/// Where a card dropped at `(x, y)` lands: the nearest grid point, bounded.
#[must_use]
#[uniffi::export]
pub fn snap_canvas_position(x: i64, y: i64) -> CanvasPosition {
    core::snap(x, y).into()
}

#[uniffi::export]
impl ClientCore {
    /// The Canvas's sessions: `viewer_id`'s own top-level, unarchived sessions, newest first.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidPagination`; the read errors; `MalformedResponse`.
    pub async fn canvas_sessions(
        &self,
        viewer_id: Option<String>,
    ) -> Result<Vec<SessionSummary>, CoreError> {
        self.sessions()
            .canvas_sessions(viewer_id.as_deref())
            .await
            .map(|sessions| sessions.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }
}
