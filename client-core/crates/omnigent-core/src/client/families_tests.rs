use futures::executor::block_on;
use serde_json::{Value, json};

use super::*;
use crate::client::pin_order::PinStamp;
use crate::client::test_support::{Reply, RouteTransport, connected, record};
use crate::session_families::SessionFamily;

fn member(id: &str, representative: &str) -> SessionSummary {
    SessionSummary {
        family: Some(SessionFamily {
            id: "lead".to_owned(),
            representative_id: Some(representative.to_owned()),
            representative_title: None,
            pinned: false,
            pinned_at: None,
        }),
        ..SessionSummary::new(id, id, "")
    }
}

fn project(id: &str) -> SessionChange {
    SessionChange::Project(Some(id.to_owned()))
}

/// A list row of the `lead` family whose representative is `representative`.
fn family_row(id: &str, representative: &str, extra: &Value) -> Value {
    let mut row = json!({"id": id, "status": "idle", "created_at": 1, "updated_at": 2,
        "permission_level": 4,
        "family": {"id": "lead", "representative_id": representative, "pinned": false}});
    for (key, value) in extra.as_object().unwrap() {
        row[key] = value.clone();
    }
    row
}

#[test]
fn a_representatives_pin_or_move_and_any_members_archive_change_the_family() {
    let lead = member("lead", "lead");
    let peer = member("peer", "lead");
    let solo = SessionSummary::new("solo", "solo", "");
    let pin = SessionChange::Pinned {
        pinned: true,
        at_ms: 5,
    };
    let reorder = SessionChange::PinnedAt(PinStamp::new(3.0).unwrap());
    let archive = SessionChange::Archived {
        archived: true,
        delete_worktree: false,
    };
    let rename = SessionChange::Title("New".to_owned());
    for change in [&pin, &reorder, &project("p")] {
        assert_eq!(
            family_changed_by(change, Some(&lead)).as_deref(),
            Some("lead")
        );
        assert_eq!(family_changed_by(change, Some(&peer)), None);
    }
    assert_eq!(
        family_changed_by(&archive, Some(&peer)).as_deref(),
        Some("lead")
    );
    assert_eq!(family_changed_by(&rename, Some(&lead)), None);
    assert_eq!(family_changed_by(&archive, Some(&solo)), None);
    assert_eq!(family_changed_by(&archive, None), None);
}

#[test]
fn a_member_moves_with_its_representative_and_alone_refuses_the_whole_batch() {
    let rows = [
        member("lead", "lead"),
        member("peer", "lead"),
        member("other_peer", "other"),
    ];
    let cached = |id: &str| rows.iter().find(|row| row.id == id).cloned();
    let archive = SessionChange::Archived {
        archived: true,
        delete_worktree: false,
    };
    let carried = batch_routes(
        &[
            ("peer".to_owned(), project("p")),
            ("lead".to_owned(), project("p")),
            ("solo".to_owned(), project("p")),
        ],
        cached,
    );
    assert_eq!(
        carried,
        [BatchRoute::CarriedBy(1), BatchRoute::Send, BatchRoute::Send]
    );
    // A member whose representative is not moved with it refuses every move, not other edits.
    let refused = batch_routes(
        &[
            ("other_peer".to_owned(), project("p")),
            ("solo".to_owned(), project("p")),
            ("lead".to_owned(), archive.clone()),
        ],
        cached,
    );
    assert_eq!(
        refused,
        [BatchRoute::Refused, BatchRoute::Refused, BatchRoute::Send]
    );
    // Archiving a member with its representative needs no carrying.
    let archived = batch_routes(
        &[
            ("peer".to_owned(), archive),
            ("lead".to_owned(), project("p")),
        ],
        cached,
    );
    assert_eq!(archived, [BatchRoute::Send, BatchRoute::Send]);
}

#[test]
fn a_family_refresh_reads_the_other_members_forgets_gone_ones_and_falls_back_on_failure() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sessions/peer",
        family_row("peer", "peer", &json!({"title": "Promoted"})).to_string(),
    );
    transport.respond(
        None,
        "/v1/sessions/gone",
        None,
        Reply::json(404, r#"{"error":{"code":"not_found","message":"gone"}}"#),
    );
    transport.respond(None, "/v1/sessions/broken", None, Reply::json(500, "{}"));
    let core = connected(transport);
    core.apply_session_rows(vec![
        family_row("lead", "lead", &json!({})),
        family_row("peer", "lead", &json!({})),
        family_row("gone", "lead", &json!({})),
        family_row("broken", "lead", &json!({})),
        json!({"id": "solo", "status": "idle", "created_at": 1}),
    ])
    .unwrap();
    let events = record(&core);
    let refreshed = block_on(core.refresh_family("lead", "lead"));
    core.dispatch();
    assert_eq!(refreshed.keys().collect::<Vec<_>>(), ["peer"]);
    assert_eq!(refreshed["peer"].title, "Promoted");
    assert!(!refreshed["peer"].is_nested_member());
    assert!(core.cached_summary("gone").is_none());
    assert!(core.cached_summary("broken").is_some());
    let events = events.take();
    assert!(events.contains(&ClientEvent::SessionsRemoved {
        ids: vec!["gone".to_owned()]
    }));
    assert!(events.contains(&ClientEvent::SessionsChanged {
        sessions: vec![refreshed["peer"].clone()]
    }));
    assert!(events.contains(&ClientEvent::InventoryInvalidated));
    let reads: Vec<String> = core
        .transport()
        .lines()
        .into_iter()
        .filter(|line| line.starts_with("GET /v1/sessions/"))
        .collect();
    assert!(
        !reads
            .iter()
            .any(|line| line.ends_with("/lead") || line.ends_with("/solo"))
    );
}

#[test]
fn a_family_without_other_loaded_members_reads_nothing() {
    let core = connected(RouteTransport::local());
    core.apply_session_rows(vec![family_row("lead", "lead", &json!({}))])
        .unwrap();
    let events = record(&core);
    assert!(block_on(core.refresh_family("lead", "lead")).is_empty());
    core.dispatch();
    assert_eq!(events.take(), []);
    assert_eq!(
        lock(&core.state).family_members("lead", "nobody"),
        ["lead".to_owned()]
    );
}
