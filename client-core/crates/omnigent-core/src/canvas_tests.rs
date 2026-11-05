//! Ported from the web's `canvas/canvasLayout.test.ts`.

use std::collections::BTreeMap;

use super::*;
use crate::config::session::SessionConfiguration;

fn session(id: &str, updated_at: i64) -> SessionSummary {
    SessionSummary {
        updated_at,
        ..SessionSummary::new(id.to_owned(), id.to_owned(), String::new())
    }
}

fn at(x: i64, y: i64) -> CanvasPosition {
    CanvasPosition { x, y }
}

fn project(id: Option<&str>, name: &str) -> ProjectSummary {
    ProjectSummary {
        id: id.map(str::to_owned),
        name: name.to_owned(),
        icon: None,
    }
}

#[test]
fn unplaced_cards_fill_a_near_square_grid_newest_first() {
    let sessions = [session("a", 1), session("b", 3), session("c", 2)];
    let refs: Vec<&SessionSummary> = sessions.iter().collect();
    let positions = merge_session_positions(&refs, &BTreeMap::new());
    assert_eq!(positions.get("b"), Some(&at(0, 0)));
    assert_eq!(positions.get("c"), Some(&at(320, 0)));
    assert_eq!(positions.get("a"), Some(&at(0, 160)));
}

#[test]
fn saved_spots_stay_and_their_cells_are_skipped() {
    let sessions = [session("a", 2), session("b", 1)];
    let refs: Vec<&SessionSummary> = sessions.iter().collect();
    let saved = BTreeMap::from([
        ("b".to_owned(), at(0, 0)),
        ("gone".to_owned(), at(640, 0)),
        ("far".to_owned(), at(5_000_000, 0)),
    ]);
    let positions = merge_session_positions(&refs, &saved);
    assert_eq!(positions.get("b"), Some(&at(0, 0)));
    assert_eq!(positions.get("a"), Some(&at(320, 0)));
    // A spot for a session that is not live is not returned.
    assert_eq!(positions.len(), 2);
}

#[test]
fn boards_follow_project_membership_and_lay_out_separately() {
    let mut filed = session("filed", 2);
    filed.project_id = Some("p1".to_owned());
    let mut labelled = session("labelled", 1);
    labelled.project_label = Some("Legacy".to_owned());
    let mut shared = session("shared", 3);
    shared.project_id = Some("p1".to_owned());
    shared.owner = Some("someone-else".to_owned());
    let projects = [project(Some("p1"), "Docs"), project(None, "Legacy")];
    let viewer = Some("me");
    assert_eq!(canvas_id_for(&filed, &projects, viewer), "p1");
    assert_eq!(canvas_id_for(&labelled, &projects, viewer), "name:Legacy");
    // Filing is owner-only, as in the sidebar.
    assert_eq!(canvas_id_for(&shared, &projects, viewer), MAIN_CANVAS_ID);
    let sessions = [filed, labelled, shared];
    let positions = merge_canvas_positions(&sessions, &projects, &BTreeMap::new(), viewer);
    // Each board starts at its own origin.
    assert!(positions.values().all(|position| *position == at(0, 0)));
    assert_eq!(positions.len(), 3);
}

#[test]
fn reset_regrids_one_board_and_keeps_the_others() {
    let mut filed = session("filed", 2);
    filed.project_id = Some("p1".to_owned());
    let main = session("main", 1);
    let projects = [project(Some("p1"), "Docs")];
    let saved = BTreeMap::from([
        ("filed".to_owned(), at(96, 96)),
        ("main".to_owned(), at(640, 640)),
        ("unloaded".to_owned(), at(32, 32)),
    ]);
    let sessions = [filed, main];
    let reset = reset_canvas_positions(&sessions, &projects, &saved, None, MAIN_CANVAS_ID);
    assert_eq!(reset.get("main"), Some(&at(0, 0)));
    assert_eq!(reset.get("filed"), Some(&at(96, 96)));
    assert_eq!(reset.get("unloaded"), Some(&at(32, 32)));
}

#[test]
fn canvas_sessions_are_the_viewers_own_top_level_live_ones() {
    let mine = session("mine", 1);
    assert!(is_canvas_session(&mine, Some("me")));
    let mut archived = session("archived", 1);
    archived.is_archived = true;
    assert!(!is_canvas_session(&archived, Some("me")));
    let mut theirs = session("theirs", 1);
    theirs.owner = Some("them".to_owned());
    assert!(!is_canvas_session(&theirs, Some("me")));
    let mut child = session("child", 1);
    child.configuration = Some(SessionConfiguration {
        parent_id: Some("mine".to_owned()),
        ..SessionConfiguration::default()
    });
    assert!(!is_canvas_session(&child, Some("me")));
}

#[test]
fn drops_snap_to_the_grid_and_stay_bounded() {
    assert_eq!(snap(47, 48), at(32, 64));
    assert_eq!(snap(-16, -17), at(0, -32));
    assert_eq!(snap(9_000_000, 0), at(MAX_ABS_COORDINATE, 0));
}
