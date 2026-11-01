//! `insta` snapshots of the reducer output for the recorded real-server fixtures.

use omnigent_protocol::{ConversationItem, FromWire, SessionSnapshot};

use super::{Harness, fixture, render, sse_data};
use crate::reconcile::{ConversationSync, header_from_snapshot, history_rows, history_snapshot};
use crate::reducer::{Row, TurnStatus};

const SESSION: &str = "facbcc05b00f4321b98b1929d217abc5";

fn recorded_snapshot() -> SessionSnapshot {
    let envelope = fixture("items/recorded-session-snapshot-after-turn.json");
    SessionSnapshot::from_value(envelope["response"].clone()).expect("snapshot decodes")
}

fn recorded_pages() -> Vec<ConversationItem> {
    (1..=3)
        .flat_map(|page| {
            let envelope = fixture(&format!("items/recorded-items-page-{page}.json"));
            envelope["response"]["data"]
                .as_array()
                .expect("page rows")
                .iter()
                .map(|item| ConversationItem::from_value(item.clone()).expect("item decodes"))
                .collect::<Vec<_>>()
        })
        .collect()
}

#[test]
fn recorded_turn_with_tool_call_folds_into_rows() {
    let mut harness = Harness::new(SESSION);
    harness.send_all(&sse_data("recorded-turn-text-tool-completion.jsonl"));
    assert_eq!(harness.snapshot().header.status, TurnStatus::Idle);
    assert!(!harness.snapshot().rows.iter().any(|row| row.is_streaming));
    // The in-progress and completed commits of one call are one row.
    insta::assert_snapshot!(
        "recorded-turn-text-tool-completion",
        render(harness.snapshot())
    );
}

#[test]
fn recorded_reconnect_turn_folds_into_a_fresh_reducer() {
    let mut harness = Harness::new(SESSION);
    harness.send_all(&sse_data("recorded-reconnect-last-event-id-turn2.jsonl"));
    assert_eq!(
        harness.texts().last().copied(),
        Some("Second turn streams its answer in deltas.")
    );
    insta::assert_snapshot!(
        "recorded-reconnect-last-event-id-turn2",
        render(harness.snapshot())
    );
}

#[test]
fn recorded_history_pages_and_snapshot_items_project_identically() {
    let session = recorded_snapshot();
    let from_pages = history_rows(&recorded_pages()).expect("pages project");
    let from_snapshot = history_rows(&session.items).expect("snapshot items project");
    assert_eq!(from_pages, from_snapshot);
    let header = header_from_snapshot(&session, None).expect("header");
    let snapshot = history_snapshot(&session, &session.items, header).expect("history");
    insta::assert_snapshot!("recorded-session-history", render(&snapshot));
}

fn ids(rows: &[Row]) -> Vec<&str> {
    rows.iter().map(|row| row.id.as_str()).collect()
}

#[test]
fn recorded_live_turns_reconcile_with_history_without_duplicates() {
    let session = recorded_snapshot();
    let history = history_rows(&session.items).expect("history");
    let mut sync = ConversationSync::new(SESSION);
    let request = sync.open_stream();
    for event in sse_data("recorded-turn-text-tool-completion.jsonl")
        .into_iter()
        .chain(sse_data("recorded-reconnect-last-event-id-turn2.jsonl"))
    {
        sync.handle_event(event).expect("event applies");
    }
    let live = sync.published().expect("live state").rows.clone();
    assert_eq!(live.len(), history.len(), "{:?}", ids(&live));
    let update = sync
        .finish_hydration(&request, &session, &session.items)
        .expect("hydration");
    let rows = &sync.published().expect("state").rows;
    assert_eq!(ids(rows), ids(&history));
    assert!(!rows.iter().any(|row| row.is_streaming));
    assert!(!update.changes.is_empty());
}
