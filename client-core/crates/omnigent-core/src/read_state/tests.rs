//! Read state: the web's `useUnseenConversations` rules with the server authoritative, the
//! `viewer_*` decoding, and the `PUT /v1/sessions/{id}/read-state` write.

use futures::executor::block_on;
use serde_json::{Value, json};

use super::*;
use crate::client::SessionError;
use crate::client::sessions::ViewerRead;
use crate::client::test_support::{Reply, RouteTransport, connected};

fn row(id: &str, updated_at: i64, read: Option<ViewerRead>) -> SessionSummary {
    SessionSummary {
        updated_at,
        viewer_read: read,
        ..SessionSummary::new(id, id, "")
    }
}

const fn server(last_seen: Option<i64>, unread: bool) -> ViewerRead {
    ViewerRead { last_seen, unread }
}

#[test]
fn new_activity_after_the_baseline_is_unread_until_seen() {
    let mut state = ReadState::new();
    state.observe(&row("a", 100, Some(server(Some(100), false))));
    assert!(!state.is_unread("a"));
    // A turn finishes after the caller last looked.
    state.observe(&row("a", 160, Some(server(Some(100), false))));
    assert!(state.is_unread("a"));
    assert_eq!(
        state.mark_seen("a", 150, SeenReason::Opened),
        Some(ReadMark {
            session_id: "a".into(),
            last_seen: 160,
            unread: false
        }),
        "the baseline is never before the activity being read"
    );
    assert!(!state.is_unread("a"));
    // A stale server report from before the write lands does not bring it back.
    state.observe(&row("a", 160, Some(server(Some(100), false))));
    assert!(!state.is_unread("a"));
    // Marking again changes nothing.
    assert_eq!(state.mark_seen("a", 155, SeenReason::Viewing), None);
}

#[test]
fn a_running_session_is_not_unseen_and_unknown_sessions_are_read() {
    let mut state = ReadState::new();
    let running = SessionSummary {
        status: SummaryStatus::Running,
        ..row("r", 200, Some(server(Some(100), false)))
    };
    state.observe(&running);
    assert!(!state.is_unread("r"));
    state.observe(&row("r", 200, Some(server(Some(100), false))));
    assert!(state.is_unread("r"));
    assert!(!state.is_unread("unknown"));
}

#[test]
fn without_any_baseline_a_session_reads_as_of_first_sight() {
    let mut state = ReadState::new();
    // An older server (no viewer fields) or a server that lost its state.
    state.observe(&row("old", 500, None));
    state.observe(&row("never", 500, Some(server(None, false))));
    assert_eq!(state.unread_ids(), BTreeSet::new());
    assert!(state.server_tracks_reads());
    state.observe(&row("old", 600, None));
    assert_eq!(state.unread_ids(), BTreeSet::from(["old".to_owned()]));
    let mut legacy = ReadState::new();
    legacy.observe(&row("old", 500, None));
    assert!(!legacy.server_tracks_reads(), "nothing to write to");
}

#[test]
fn the_servers_explicit_unread_wins_until_the_session_is_opened() {
    let mut state = ReadState::new();
    state.observe(&row("a", 305, Some(server(Some(300), false))));
    let mark = state.mark_seen("a", 310, SeenReason::Opened).unwrap();
    assert_eq!(mark.last_seen, 310);
    // A row from before the write lands does not undo the mark.
    state.observe(&row("a", 305, Some(server(Some(250), true))));
    assert!(!state.is_unread("a"));
    state.mark_written(&mark);
    // Another device marks it unread later: the server pins the baseline below `updated_at`.
    state.observe(&row("a", 320, Some(server(Some(319), true))));
    assert!(state.is_unread("a"));
    // Keeping it open does not undo that; opening it does.
    assert_eq!(state.mark_seen("a", 330, SeenReason::Viewing), None);
    assert!(state.is_unread("a"));
    assert_eq!(
        state.mark_seen("a", 330, SeenReason::Opened),
        Some(ReadMark {
            session_id: "a".into(),
            last_seen: 330,
            unread: false
        })
    );
    assert!(!state.is_unread("a"));
    // The server reporting the mark back settles it.
    state.observe(&row("a", 320, Some(server(Some(330), false))));
    assert!(!state.is_unread("a"));
    state.observe(&row("a", 320, Some(server(Some(319), true))));
    assert!(state.is_unread("a"), "the server is authoritative again");
}

#[test]
fn a_mark_never_lowers_a_later_baseline_from_another_device() {
    let mut state = ReadState::new();
    state.observe(&row("a", 100, Some(server(Some(400), true))));
    let mark = state.mark_seen("a", 200, SeenReason::Opened).unwrap();
    assert_eq!(mark.last_seen, 400);
    assert!(!state.is_unread("a"));
    // A failed write keeps the local mark as the fallback.
    state.observe(&row("a", 100, Some(server(Some(400), true))));
    assert!(!state.is_unread("a"));
}

#[test]
fn removed_sessions_and_a_cleared_state_are_forgotten() {
    let mut state = ReadState::new();
    state.observe(&row("a", 10, Some(server(Some(1), false))));
    state.observe(&row("b", 10, Some(server(Some(1), false))));
    state.remove(&["a".to_owned()]);
    assert_eq!(state.unread_ids(), BTreeSet::from(["b".to_owned()]));
    state.clear();
    assert_eq!(state, ReadState::new());
}

fn list_row(extra: &Value) -> Value {
    let mut row = json!({
        "id": "conv_a", "agent_id": "agent", "status": "idle",
        "created_at": 1, "updated_at": 50, "title": "A"
    });
    for (key, value) in extra.as_object().unwrap() {
        row[key] = value.clone();
    }
    row
}

#[test]
fn list_and_update_rows_carry_the_viewer_fields_and_sparse_rows_keep_them() {
    let core = connected(RouteTransport::local());
    let summaries = core
        .apply_session_rows(vec![list_row(
            &json!({"viewer_last_seen": 40, "viewer_unread": false}),
        )])
        .unwrap();
    assert_eq!(summaries[0].viewer_read, Some(server(Some(40), false)));
    // A row without the fields keeps the last report; `null` means never seen.
    let sparse = core.apply_session_rows(vec![list_row(&json!({}))]).unwrap();
    assert_eq!(sparse[0].viewer_read, Some(server(Some(40), false)));
    let never = core
        .apply_session_rows(vec![list_row(
            &json!({"viewer_last_seen": null, "viewer_unread": true}),
        )])
        .unwrap();
    assert_eq!(never[0].viewer_read, Some(server(None, true)));
}

#[test]
fn mark_seen_puts_the_read_state_and_reports_failures() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("PUT"),
        "/v1/sessions/conv_a/read-state",
        None,
        Reply::json(204, ""),
    );
    let core = connected(transport);
    let mark = ReadMark {
        session_id: "conv_a".into(),
        last_seen: 1_717_000_000,
        unread: false,
    };
    assert_eq!(block_on(core.put_read_state(&mark)), Ok(()));
    let writes = core.transport().writes();
    assert_eq!(writes.len(), 1);
    assert_eq!(writes[0].method, "PUT");
    assert!(writes[0].url.ends_with("/v1/sessions/conv_a/read-state"));
    let body: Value = serde_json::from_slice(writes[0].body.as_deref().unwrap()).unwrap();
    assert_eq!(body, json!({"last_seen": 1_717_000_000, "unread": false}));

    for (status, expected) in [
        (403, SessionError::Forbidden),
        (
            404,
            SessionError::Rejected {
                status: 404,
                message: "Not Found".into(),
            },
        ),
    ] {
        let transport = RouteTransport::local();
        transport.respond(
            Some("PUT"),
            "/v1/sessions/conv_a/read-state",
            None,
            Reply::json(status, r#"{"detail":"Not Found"}"#),
        );
        let core = connected(transport);
        assert_eq!(
            block_on(core.put_read_state(&mark)),
            Err(expected),
            "{status}"
        );
    }
    let core = connected(RouteTransport::local());
    let bad = ReadMark {
        session_id: "../info".into(),
        ..mark
    };
    assert!(matches!(
        block_on(core.put_read_state(&bad)),
        Err(SessionError::InvalidIdentifier { .. })
    ));
    assert_eq!(core.transport().writes().len(), 0);
}
