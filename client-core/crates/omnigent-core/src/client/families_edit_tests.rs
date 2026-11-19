//! Family writes end to end over a scripted transport: the refused member edits, the
//! representative's pin and move with what the list shows meanwhile, bulk moves, promotion after
//! an archive or delete, pin order, and project rename and delete.

use futures::executor::block_on;
use serde_json::{Value, json};

use super::super::pin_order::PinStamp;
use super::super::projects::{ProjectSummary, REPRESENTATIVE_UNAVAILABLE};
use super::super::sessions::{SessionChange, SessionSummary};
use super::super::test_support::{
    Recorder, Reply, RouteTransport, body_json, connected, lines_after_connect, path_of, record,
};
use super::super::{ClientCore, ClientEvent, SessionError};
use crate::intents::SessionPatch;
use crate::session_families::{NESTED_MEMBER_EDIT_REFUSAL, shows_pinned};

type Core = ClientCore<RouteTransport>;

/// A row of the `lead` family whose representative is `representative`, overlaid with `extra`.
fn family_row(id: &str, representative: &str, extra: &Value) -> Value {
    let mut row = json!({"id": id, "status": "idle", "created_at": 1, "updated_at": 2,
        "permission_level": 4, "project_id": "p_old", "labels": {},
        "family": {"id": "lead", "representative_id": representative, "pinned": false}});
    for (key, value) in extra.as_object().unwrap() {
        row[key] = value.clone();
    }
    row
}

fn solo_row(extra: &Value) -> Value {
    let mut row = json!({"id": "solo", "status": "idle", "created_at": 1, "updated_at": 2,
        "permission_level": 4, "labels": {}});
    for (key, value) in extra.as_object().unwrap() {
        row[key] = value.clone();
    }
    row
}

fn ok(row: &Value) -> Reply {
    Reply::json(200, row.to_string())
}

fn gone() -> Reply {
    Reply::json(404, r#"{"error":{"code":"not_found","message":"gone"}}"#)
}

/// A core holding `lead` (the representative), its member `peer` and the standalone `solo`.
fn family_core(transport: RouteTransport) -> (Core, std::sync::Arc<Recorder>) {
    let core = connected(transport);
    core.apply_session_rows(vec![
        family_row("lead", "lead", &json!({})),
        family_row("peer", "lead", &json!({})),
        solo_row(&json!({})),
    ])
    .unwrap();
    let recorder = record(&core);
    (core, recorder)
}

fn refusal() -> SessionError {
    SessionError::InvalidInput {
        reason: NESTED_MEMBER_EDIT_REFUSAL.to_owned(),
    }
}

fn project(id: &str) -> SessionChange {
    SessionChange::Project(Some(id.to_owned()))
}

/// The rows of every list change, in order.
fn changed_rows(recorder: &Recorder) -> Vec<Vec<SessionSummary>> {
    recorder
        .take()
        .into_iter()
        .filter_map(|event| match event {
            ClientEvent::SessionsChanged { sessions } => Some(sessions),
            _ => None,
        })
        .collect()
}

fn project_of(rows: &[SessionSummary], id: &str) -> Option<String> {
    rows.iter()
        .find(|row| row.id == id)
        .and_then(|row| row.project_id.clone())
}

#[test]
fn a_nested_member_is_never_pinned_or_moved_on_its_own() {
    let (core, _) = family_core(RouteTransport::local());
    for change in [
        SessionChange::Pinned {
            pinned: true,
            at_ms: 5,
        },
        SessionChange::Pinned {
            pinned: false,
            at_ms: 5,
        },
        SessionChange::PinnedAt(PinStamp::new(5.0).unwrap()),
        project("p_new"),
        SessionChange::Project(None),
    ] {
        assert_eq!(block_on(core.edit_session("peer", change)), Err(refusal()));
    }
    assert_eq!(block_on(core.move_pin("peer", "solo", 9)), Err(refusal()));
    assert_eq!(lines_after_connect(&core), Vec::<String>::new());
    // Renaming a member stays its own edit.
    let rename = super::super::sessions::edit_request(
        "peer",
        SessionChange::Title("Renamed".to_owned()),
        core.cached_summary("peer").as_ref(),
    );
    assert!(rename.is_ok());
}

#[test]
fn pinning_a_representative_shows_on_its_family_and_reads_the_members_again() {
    let transport = RouteTransport::local();
    let pinned_family = json!({"id": "lead", "representative_id": "lead", "pinned": true,
                               "pinned_at": "5"});
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/lead",
        None,
        ok(&family_row(
            "lead",
            "lead",
            &json!({"labels": {"omnigent.pinned": "5"}, "family": pinned_family}),
        )),
    );
    transport.respond(
        Some("GET"),
        "/v1/sessions/peer",
        None,
        ok(&family_row(
            "peer",
            "lead",
            &json!({"family": pinned_family}),
        )),
    );
    let (core, recorder) = family_core(transport);
    let peer_before = core.cached_summary("peer").unwrap();
    let lead = block_on(core.edit_session(
        "lead",
        SessionChange::Pinned {
            pinned: true,
            at_ms: 5,
        },
    ))
    .unwrap();
    assert!(lead.is_pinned);
    let changes = changed_rows(&recorder);
    // Before the write: the representative shows pinned, and so does its family.
    let shown = &changes[0][0];
    assert_eq!(shown.id, "lead");
    assert!(shown.is_pinned);
    let family = shown.family.as_ref().unwrap();
    assert!(family.pinned);
    assert_eq!(family.pinned_at.as_deref(), Some("5"));
    // The member shows its representative's pin before its own row says so.
    assert!(!peer_before.family.as_ref().unwrap().pinned);
    assert!(shows_pinned(&peer_before, Some(shown)));
    assert_eq!(
        lines_after_connect(&core),
        ["PATCH /v1/sessions/lead", "GET /v1/sessions/peer"]
    );
    assert_eq!(
        body_json(&core.transport().writes()[0]),
        json!({"labels": {"omnigent.pinned": "5"}})
    );
    let peer = core.cached_summary("peer").unwrap();
    assert!(peer.family.unwrap().pinned && !peer.is_pinned);
}

#[test]
fn moving_a_representative_moves_its_loaded_members_at_once_and_reconciles() {
    let transport = RouteTransport::local();
    let moved = json!({"project_id": "p_new"});
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/lead",
        None,
        ok(&family_row("lead", "lead", &moved)),
    );
    transport.respond(
        Some("GET"),
        "/v1/sessions/peer",
        None,
        ok(&family_row("peer", "lead", &moved)),
    );
    transport.respond(None, "/v1/sessions/gone", None, gone());
    transport.respond(None, "/v1/sessions/broken", None, Reply::json(500, "{}"));
    let (core, recorder) = family_core(transport);
    core.apply_session_rows(vec![
        family_row("gone", "lead", &json!({})),
        family_row("broken", "lead", &json!({})),
    ])
    .unwrap();
    recorder.take();
    block_on(core.edit_session("lead", project("p_new"))).unwrap();
    let changes = changed_rows(&recorder);
    for id in ["lead", "peer", "gone", "broken"] {
        assert_eq!(
            project_of(&changes[0], id).as_deref(),
            Some("p_new"),
            "{id} moves before the write"
        );
    }
    let writes: Vec<String> = core.transport().writes().iter().map(path_of).collect();
    assert_eq!(writes, ["/v1/sessions/lead"]);
    assert_eq!(
        core.cached_summary("peer").unwrap().project_id.as_deref(),
        Some("p_new")
    );
    assert!(core.cached_summary("gone").is_none());
    // An unreadable member keeps showing the move the server made with the write.
    let broken = core.cached_summary("broken").unwrap();
    assert_eq!(broken.project_id.as_deref(), Some("p_old"));
    let last_broken = changes
        .iter()
        .rev()
        .find_map(|rows| project_of(rows, "broken"));
    assert_eq!(last_broken.as_deref(), Some("p_new"));
}

#[test]
fn a_refused_representative_move_puts_its_members_back() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/lead",
        None,
        Reply::json(
            409,
            r#"{"error":{"code":"conflict","message":"Session family changed"}}"#,
        ),
    );
    let (core, recorder) = family_core(transport);
    assert!(block_on(core.edit_session("lead", project("p_new"))).is_err());
    let changes = changed_rows(&recorder);
    assert_eq!(project_of(&changes[0], "peer").as_deref(), Some("p_new"));
    let last_peer = changes
        .iter()
        .rev()
        .find_map(|rows| project_of(rows, "peer"));
    assert_eq!(last_peer.as_deref(), Some("p_old"));
    assert!(!lines_after_connect(&core).contains(&"GET /v1/sessions/peer".to_owned()));
}

#[test]
fn a_bulk_move_writes_representatives_and_refuses_a_member_alone() {
    let transport = RouteTransport::local();
    let moved = json!({"project_id": "p_new"});
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/lead",
        None,
        ok(&family_row("lead", "lead", &moved)),
    );
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/solo",
        None,
        ok(&solo_row(&moved)),
    );
    transport.respond(
        Some("GET"),
        "/v1/sessions/peer",
        None,
        ok(&family_row("peer", "lead", &moved)),
    );
    let (core, _) = family_core(transport);
    let results = block_on(core.edit_sessions(vec![
        ("peer".to_owned(), project("p_new")),
        ("lead".to_owned(), project("p_new")),
        ("solo".to_owned(), project("p_new")),
    ]));
    let projects: Vec<Option<String>> = results
        .iter()
        .map(|result| result.as_ref().unwrap().project_id.clone())
        .collect();
    assert_eq!(projects, vec![Some("p_new".to_owned()); 3]);
    let writes: Vec<String> = core.transport().writes().iter().map(path_of).collect();
    assert_eq!(writes, ["/v1/sessions/lead", "/v1/sessions/solo"]);

    // A member without its representative refuses every move of the selection, sending none.
    let requests = core.transport().taken().len();
    let refused = block_on(core.edit_sessions(vec![
        ("peer".to_owned(), project("p_other")),
        ("solo".to_owned(), project("p_other")),
    ]));
    assert_eq!(refused, [Err(refusal()), Err(refusal())]);
    assert_eq!(core.transport().taken().len(), requests);
}

#[test]
fn a_carried_member_reports_its_representatives_failure_or_its_own_disappearance() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/lead",
        None,
        Reply::json(500, "{}"),
    );
    let (core, _) = family_core(transport);
    let failed = block_on(core.edit_sessions(vec![
        ("peer".to_owned(), project("p_new")),
        ("lead".to_owned(), project("p_new")),
    ]));
    assert!(failed[1].is_err());
    assert_eq!(failed[0], failed[1]);

    let transport = RouteTransport::local();
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/lead",
        None,
        ok(&family_row("lead", "lead", &json!({"project_id": "p_new"}))),
    );
    transport.respond(Some("GET"), "/v1/sessions/peer", None, gone());
    let (core, _) = family_core(transport);
    let vanished = block_on(core.edit_sessions(vec![
        ("peer".to_owned(), project("p_new")),
        ("lead".to_owned(), project("p_new")),
    ]));
    assert!(vanished[1].is_ok());
    assert_eq!(
        vanished[0],
        Err(SessionError::SessionNotFound {
            session_id: "peer".to_owned()
        })
    );
}

#[test]
fn archiving_or_deleting_a_member_reads_the_rest_of_its_family_again() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/lead",
        None,
        ok(&family_row("lead", "peer", &json!({"archived": true}))),
    );
    transport.respond(
        Some("GET"),
        "/v1/sessions/peer",
        None,
        ok(&family_row("peer", "peer", &json!({}))),
    );
    transport.respond(
        Some("DELETE"),
        "/v1/sessions/lead",
        None,
        Reply::json(200, "{}"),
    );
    let (core, _) = family_core(transport);
    let archived = block_on(core.edit_session(
        "lead",
        SessionChange::Archived {
            archived: true,
            delete_worktree: false,
        },
    ))
    .unwrap();
    assert!(archived.is_nested_member());
    assert!(!core.cached_summary("peer").unwrap().is_nested_member());
    assert_eq!(
        lines_after_connect(&core),
        ["PATCH /v1/sessions/lead", "GET /v1/sessions/peer"]
    );

    block_on(core.delete_session("lead")).unwrap();
    assert!(core.cached_summary("lead").is_none());
    assert_eq!(
        lines_after_connect(&core)[2..],
        ["DELETE /v1/sessions/lead", "GET /v1/sessions/peer"]
    );
    // A standalone session's delete reads nothing more.
    core.transport().respond(
        Some("DELETE"),
        "/v1/sessions/solo",
        None,
        Reply::json(200, "{}"),
    );
    block_on(core.delete_session("solo")).unwrap();
    assert_eq!(
        lines_after_connect(&core)[4..],
        ["DELETE /v1/sessions/solo"]
    );
}

#[test]
fn pin_order_moves_a_pinned_family_as_its_representatives_one_pin() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/lead",
        None,
        ok(&family_row(
            "lead",
            "lead",
            &json!({"labels": {"omnigent.pinned": "19"}}),
        )),
    );
    transport.respond(
        Some("GET"),
        "/v1/sessions/peer",
        None,
        ok(&family_row("peer", "lead", &json!({}))),
    );
    let core = connected(transport);
    let pinned_family = json!({"id": "lead", "representative_id": "lead", "pinned": true,
                               "pinned_at": "30"});
    core.apply_session_rows(vec![
        family_row(
            "lead",
            "lead",
            &json!({"labels": {"omnigent.pinned": "30"}, "family": pinned_family}),
        ),
        // A stale personal pin on a member takes no slot.
        family_row(
            "peer",
            "lead",
            &json!({"labels": {"omnigent.pinned": "15"}, "family": pinned_family}),
        ),
        solo_row(&json!({"labels": {"omnigent.pinned": "20"}})),
    ])
    .unwrap();
    block_on(core.set_pin_order(&["lead".to_owned(), "solo".to_owned()], 99)).unwrap();
    assert_eq!(
        lines_after_connect(&core),
        ["PATCH /v1/sessions/lead", "GET /v1/sessions/peer"]
    );
    assert_eq!(
        body_json(&core.transport().writes()[0]),
        json!({"labels": {"omnigent.pinned": "19"}})
    );
}

#[test]
fn a_representatives_pin_intent_shows_on_its_family_and_a_members_does_not() {
    let representative = SessionSummary {
        family: Some(crate::session_families::SessionFamily {
            id: "lead".to_owned(),
            representative_id: Some("lead".to_owned()),
            representative_title: None,
            pinned: false,
            pinned_at: None,
        }),
        ..SessionSummary::new("lead", "Lead", "")
    };
    let mut row = representative.clone();
    SessionPatch::Pin(Some("7".to_owned())).apply(&mut row);
    let family = row.family.clone().unwrap();
    assert!(row.is_pinned && family.pinned);
    assert_eq!(family.pinned_at.as_deref(), Some("7"));
    SessionPatch::Pin(None).apply(&mut row);
    assert!(!row.is_pinned && !row.family.unwrap().pinned);
    let mut member = SessionSummary {
        id: "peer".to_owned(),
        ..representative
    };
    SessionPatch::Pin(Some("7".to_owned())).apply(&mut member);
    assert!(!member.family.unwrap().pinned);
}

fn project_page(rows: &[Value]) -> String {
    json!({"data": rows, "has_more": false}).to_string()
}

#[test]
fn renaming_a_project_refiles_representatives_and_reads_their_families_again() {
    let transport = RouteTransport::local();
    transport.ok("/v1/projects/p_old", r#"{"id":"p_old","name":"Renamed"}"#);
    transport.ok(
        "/v1/sessions",
        project_page(&[
            family_row("lead", "lead", &json!({})),
            family_row("peer", "lead", &json!({})),
            solo_row(&json!({})),
        ]),
    );
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/lead",
        None,
        ok(&family_row("lead", "lead", &json!({}))),
    );
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/solo",
        None,
        ok(&solo_row(&json!({}))),
    );
    transport.respond(
        Some("GET"),
        "/v1/sessions/peer",
        None,
        ok(&family_row("peer", "lead", &json!({}))),
    );
    let (core, _) = family_core(transport);
    let folder = ProjectSummary {
        id: Some("p_old".to_owned()),
        name: "Work".to_owned(),
        icon: None,
    };
    block_on(core.rename_project(&folder, "Renamed")).unwrap();
    let lines: Vec<String> = lines_after_connect(&core)
        .into_iter()
        .filter(|line| line != "GET /v1/sessions")
        .collect();
    assert_eq!(
        lines,
        [
            "PATCH /v1/projects/p_old",
            "PATCH /v1/sessions/lead",
            "GET /v1/sessions/peer",
            "PATCH /v1/sessions/solo",
        ]
    );
}

#[test]
fn deleting_a_project_unfiles_representatives_before_archiving_their_members() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sessions",
        project_page(&[
            family_row("peer", "lead", &json!({})),
            family_row("lead", "lead", &json!({})),
            family_row("orphan", "elsewhere", &json!({})),
            solo_row(&json!({})),
        ]),
    );
    for id in ["lead", "peer"] {
        transport.respond(
            Some("PATCH"),
            &format!("/v1/sessions/{id}"),
            None,
            ok(&family_row(id, "lead", &json!({"archived": true}))),
        );
    }
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/solo",
        None,
        Reply::json(403, "{}"),
    );
    let core = connected(transport);
    let folder = ProjectSummary {
        id: Some("p_old".to_owned()),
        name: "Work".to_owned(),
        icon: None,
    };
    let failure = block_on(core.delete_project(&folder));
    assert!(failure.is_err());
    let writes = core.transport().writes();
    let sent: Vec<(String, Value)> = writes
        .iter()
        .map(|request| (path_of(request), body_json(request)))
        .collect();
    let unfile = json!({"archived": true, "project_id": "", "labels": {"omni_project": ""}});
    assert_eq!(
        sent,
        [
            ("/v1/sessions/lead".to_owned(), unfile.clone()),
            ("/v1/sessions/solo".to_owned(), unfile),
            ("/v1/sessions/peer".to_owned(), json!({"archived": true})),
        ]
    );
    // The orphan's representative is not filed here; the project is kept.
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sessions",
        project_page(&[family_row("orphan", "elsewhere", &json!({}))]),
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.delete_project(&folder)),
        Err(SessionError::InvalidInput {
            reason: REPRESENTATIVE_UNAVAILABLE.to_owned()
        })
    );
    assert_eq!(core.transport().writes().len(), 0);
}

#[test]
fn a_session_joins_a_nest_or_leaves_its_own_and_both_nests_are_read_again() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/solo",
        None,
        ok(&family_row("solo", "lead", &json!({}))),
    );
    transport.respond(
        Some("GET"),
        "/v1/sessions/lead",
        None,
        ok(&family_row("lead", "lead", &json!({}))),
    );
    transport.respond(
        Some("GET"),
        "/v1/sessions/peer",
        None,
        ok(&family_row("peer", "lead", &json!({}))),
    );
    let (core, recorder) = family_core(transport);
    let moved = block_on(core.move_to_nest("solo", Some("lead"))).unwrap();
    assert_eq!(
        moved.family.map(|family| family.id).as_deref(),
        Some("lead")
    );
    assert_eq!(
        body_json(&core.transport().writes()[0]),
        json!({"nest_source_id": "lead"})
    );
    let mut reads = lines_after_connect(&core);
    reads.sort();
    assert_eq!(
        reads,
        [
            "GET /v1/sessions/lead",
            "GET /v1/sessions/peer",
            "PATCH /v1/sessions/solo"
        ]
    );
    assert!(
        changed_rows(&recorder)[0]
            .iter()
            .any(|row| row.id == "solo")
    );

    // Leaving sends a null nest; the nest it left is read again.
    let transport = RouteTransport::local();
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/peer",
        None,
        ok(&solo_row(&json!({"id": "peer", "family": null}))),
    );
    transport.respond(
        Some("GET"),
        "/v1/sessions/lead",
        None,
        ok(&family_row("lead", "lead", &json!({}))),
    );
    let (core, _) = family_core(transport);
    let left = block_on(core.move_to_nest("peer", None)).unwrap();
    assert!(left.family.is_none());
    assert_eq!(
        body_json(&core.transport().writes()[0]),
        json!({"nest_source_id": null})
    );
    assert_eq!(
        lines_after_connect(&core),
        ["PATCH /v1/sessions/peer", "GET /v1/sessions/lead"]
    );
}

#[test]
fn only_the_owner_moves_a_session_between_nests() {
    let core = connected(RouteTransport::local());
    core.apply_session_rows(vec![solo_row(&json!({"permission_level": 1}))])
        .unwrap();
    assert_eq!(
        block_on(core.move_to_nest("solo", Some("lead"))),
        Err(SessionError::ReadOnly)
    );
    assert!(matches!(
        block_on(core.move_to_nest("bad id", None)),
        Err(SessionError::InvalidIdentifier { .. })
    ));
    assert_eq!(core.transport().writes().len(), 0);
}
