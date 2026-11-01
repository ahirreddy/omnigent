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

/// The recorded session read part-way through turn 1: the user message, the persisted tool call
/// and its output, but not the assistant message yet. The persisted tool rows have ids that
/// differ from the ones the live stream committed them under.
fn mid_turn_history() -> (SessionSnapshot, Vec<ConversationItem>) {
    let mut envelope = fixture("items/recorded-session-snapshot-after-turn.json");
    envelope["response"]["status"] = serde_json::json!("running");
    let session = SessionSnapshot::from_value(envelope["response"].clone()).expect("snapshot");
    let items = session.items.iter().take(3).cloned().collect();
    (session, items)
}

/// The row ids of `rows` with each kind: `user`, `tool` (call or result) or `text` (assistant).
fn kinds(rows: &[Row]) -> Vec<&'static str> {
    use crate::reducer::{ActivityKind, RowRole};
    rows.iter()
        .map(|row| match (row.role, row.activity_kind()) {
            (RowRole::User, _) => "user",
            (_, Some(ActivityKind::ToolCall | ActivityKind::ToolResult)) => "tool",
            (RowRole::Assistant, None) => "text",
            _ => "other",
        })
        .collect()
}

/// Regression: a history read that lands mid-turn (after the tool call and its output were
/// committed live, while the answer streams) must keep the streaming answer below the tool rows.
/// The persisted tool rows carry new ids, so the preview's committed neighbours vanish from the
/// merged rows; it used to fall back to the last surviving anchor (the user message) and jump
/// above the tool call and result.
#[test]
fn mid_turn_hydration_keeps_streaming_answer_below_tool_rows() {
    let events = sse_data("recorded-turn-text-tool-completion.jsonl");
    let first_delta = events
        .iter()
        .position(|event| event["type"] == "response.output_text.delta")
        .expect("a text delta");
    let (session, items) = mid_turn_history();

    // The read starts after the first delta and lands before the turn ends.
    let mut sync = ConversationSync::new(SESSION);
    let initial = sync.open_stream();
    sync.finish_hydration(&initial, &session, &[])
        .expect("initial hydration");
    for event in events.iter().take(first_delta + 1) {
        sync.handle_event(event.clone()).expect("event applies");
    }
    let before = kinds(&sync.published().expect("live").rows);
    assert_eq!(before, ["user", "tool", "tool", "text"]);
    let request = sync.request_hydration().expect("a read starts");
    sync.handle_event(events[first_delta + 1].clone())
        .expect("delta during the read");
    sync.finish_hydration(&request, &session, &items)
        .expect("mid-turn hydration");
    let rows = &sync.published().expect("merged").rows;
    assert_eq!(
        kinds(rows),
        ["user", "tool", "tool", "text"],
        "{:?}",
        ids(rows)
    );
    assert_eq!(
        rows.last().map(|row| row.text.as_str()),
        Some("The command ")
    );

    // The rest of the turn lands in place and the final commit retires the preview.
    for event in events.iter().skip(first_delta + 2) {
        sync.handle_event(event.clone()).expect("event applies");
    }
    let rows = &sync.published().expect("final").rows;
    assert_eq!(
        kinds(rows),
        ["user", "tool", "tool", "text"],
        "{:?}",
        ids(rows)
    );
    assert!(!rows.iter().any(|row| row.is_streaming));
}

/// The same read, requested before the answer started: the deltas buffered meanwhile replay onto
/// the history and the answer still lands below the tool rows.
#[test]
fn hydration_requested_before_the_answer_keeps_it_below_tool_rows() {
    let events = sse_data("recorded-turn-text-tool-completion.jsonl");
    let first_delta = events
        .iter()
        .position(|event| event["type"] == "response.output_text.delta")
        .expect("a text delta");
    let (session, items) = mid_turn_history();
    let mut sync = ConversationSync::new(SESSION);
    let initial = sync.open_stream();
    sync.finish_hydration(&initial, &session, &[])
        .expect("initial hydration");
    for event in events.iter().take(first_delta) {
        sync.handle_event(event.clone()).expect("event applies");
    }
    let request = sync.request_hydration().expect("a read starts");
    for event in events.iter().skip(first_delta).take(2) {
        sync.handle_event(event.clone())
            .expect("delta during the read");
    }
    sync.finish_hydration(&request, &session, &items)
        .expect("mid-turn hydration");
    let rows = &sync.published().expect("merged").rows;
    assert_eq!(
        kinds(rows),
        ["user", "tool", "tool", "text"],
        "{:?}",
        ids(rows)
    );
    assert_eq!(
        rows.last().map(|row| row.text.as_str()),
        Some("The command ")
    );
}
