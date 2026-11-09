//! The Canvas page's records and board rules over the fake host.

use std::collections::HashMap;

use omnigent_core::canvas as core;
use omnigent_core::sessions::SessionSummary as CoreSummary;

use crate::canvas::{
    CanvasPosition, canvas_id_for, canvas_positions, is_canvas_session, main_canvas_id,
    project_canvas_id, reset_canvas_positions, snap_canvas_position,
};
use crate::sessions::{ProjectSummary, SessionSummary};
use crate::test_support::{connected, json};

fn summary(id: &str) -> SessionSummary {
    SessionSummary::from(CoreSummary::new(id, "Title", ""))
}

fn project(id: Option<&str>, name: &str) -> ProjectSummary {
    ProjectSummary {
        id: id.map(str::to_owned),
        name: name.to_owned(),
        icon: None,
    }
}

fn filed(id: &str, project_id: &str) -> SessionSummary {
    SessionSummary {
        project_id: Some(project_id.to_owned()),
        ..summary(id)
    }
}

#[test]
fn a_position_keeps_each_axis_both_ways() {
    let position = CanvasPosition { x: 3, y: -7 };
    let on_core = core::CanvasPosition::from(position);
    assert_eq!((on_core.x, on_core.y), (3, -7));
    assert_eq!(CanvasPosition::from(on_core), position);
}

#[test]
fn board_ids_and_membership_read_the_session_and_projects() {
    assert_eq!(main_canvas_id(), "main");
    assert_eq!(project_canvas_id(project(Some("p1"), "App")), "p1");
    assert_eq!(project_canvas_id(project(None, "Old")), "name:Old");
    let projects = vec![project(Some("p1"), "App")];
    assert_eq!(
        canvas_id_for(filed("a", "p1"), projects.clone(), None),
        "p1"
    );
    assert_eq!(canvas_id_for(summary("b"), projects, None), "main");

    assert!(is_canvas_session(summary("a"), None));
    let archived = SessionSummary {
        is_archived: true,
        ..summary("a")
    };
    assert!(!is_canvas_session(archived, None));
    let someone_elses = SessionSummary {
        owner: Some("other".into()),
        ..summary("a")
    };
    assert!(!is_canvas_session(someone_elses.clone(), Some("me".into())));
    assert!(is_canvas_session(someone_elses, Some("other".into())));
}

#[test]
fn saved_spots_stay_and_a_reset_only_moves_its_own_board() {
    let projects = vec![project(Some("p1"), "App")];
    let saved_spot = CanvasPosition { x: 640, y: 320 };
    let saved = HashMap::from([
        ("in_main".to_owned(), saved_spot),
        ("in_project".to_owned(), saved_spot),
    ]);
    let sessions = vec![
        summary("in_main"),
        filed("in_project", "p1"),
        summary("unplaced"),
    ];

    let merged = canvas_positions(sessions.clone(), projects.clone(), saved.clone(), None);
    assert_eq!(merged["in_main"], saved_spot);
    assert_eq!(merged["in_project"], saved_spot);
    assert_eq!(merged["unplaced"], CanvasPosition { x: 0, y: 0 });

    let reset = reset_canvas_positions(sessions, projects, saved, None, "main".into());
    assert_eq!(
        reset["in_project"], saved_spot,
        "another board is untouched"
    );
    assert_ne!(reset["in_main"], saved_spot);
    assert_eq!(reset["in_main"], CanvasPosition { x: 0, y: 0 });
}

#[test]
fn a_dropped_card_snaps_to_the_grid_within_the_bounds() {
    assert_eq!(
        snap_canvas_position(40, 17),
        CanvasPosition { x: 32, y: 32 }
    );
    let far = snap_canvas_position(i64::MAX, i64::MIN);
    assert_eq!(
        (far.x, far.y),
        (core::MAX_ABS_COORDINATE, -core::MAX_ABS_COORDINATE)
    );
}

#[test]
fn canvas_sessions_keep_the_viewers_own_top_level_rows() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions",
        json(
            200,
            r#"{"data":[
              {"id":"a","status":"idle","created_at":1,"updated_at":9},
              {"id":"b","status":"idle","created_at":1,"updated_at":8,"owner":"someone"},
              {"id":"c","status":"idle","created_at":1,"updated_at":7,"archived":true}
            ],"has_more":false}"#,
        ),
    );
    let sessions = harness
        .call(|core| async move { core.canvas_sessions(Some("local".into())).await })
        .unwrap();
    let ids: Vec<&str> = sessions.iter().map(|session| session.id.as_str()).collect();
    assert_eq!(ids, ["a"]);
    assert_eq!(harness.last_request_line(), "GET /v1/sessions");

    harness
        .http
        .route("/v1/sessions", json(500, r#"{"error":{"message":"down"}}"#));
    let failed = harness.call(|core| async move { core.canvas_sessions(None).await });
    assert!(failed.is_err());
}
