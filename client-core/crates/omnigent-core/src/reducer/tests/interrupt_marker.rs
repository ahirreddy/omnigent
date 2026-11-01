//! The interrupt marker a turn leaves behind is not a user bubble.
//!
//! After an interrupt the runner appends a user-role `[System: interrupted]` message for the model
//! (`omnigent/runner/session_history.py`), and Claude Code mirrors its own
//! `[Request interrupted by user]` record. The server stores and streams both as ordinary user
//! messages. The web client renders them as an "Interrupted" marker, never as the person's message
//! (`web/src/lib/systemMessage.ts`). The reducer hides them as harness context and shows the
//! interrupt on the reply they cut off ([`crate::reducer::Row::interrupted`]).

use omnigent_protocol::{ConversationItem, FromWire as _};

use super::{Harness, events, fixture};
use crate::reconcile::history_rows;
use crate::reducer::{RowRole, project_item};

const HISTORY: &str = "items/InterruptMarker--MarkersAreNotUserBubblesAndMarkTheCutOffReply.json";
const STREAM: &str = "InterruptMarker--RunnerMarkerFromStreamMarksTheCutOffReply.jsonl";

fn history() -> Vec<ConversationItem> {
    fixture(HISTORY)
        .as_array()
        .expect("items")
        .iter()
        .map(|item| ConversationItem::from_value(item.clone()).expect("decodes"))
        .collect()
}

#[test]
fn markers_are_detected_exactly_like_the_web_client() {
    let markers: Vec<(String, bool)> = history()
        .iter()
        .map(|item| (item.id.clone(), item.is_interrupt_marker()))
        .collect();
    assert_eq!(
        markers,
        [
            ("u1", false),
            ("a1", false),
            ("cancel1", true),
            ("u2", false),
            ("a2", false),
            ("native1", true),
            ("mention", false),
            ("lookalike", false),
            ("attached", false),
        ]
        .map(|(id, marker)| (id.to_owned(), marker))
    );
    for item in history().iter().filter(|item| item.is_interrupt_marker()) {
        assert!(item.is_hidden_context(), "{}", item.id);
        assert_eq!(project_item(item), Ok(None), "{}", item.id);
    }
}

#[test]
fn history_hides_markers_and_marks_the_reply_they_cut_off() {
    let rows = history_rows(&history()).expect("projects");
    let shown: Vec<(&str, RowRole, bool)> = rows
        .iter()
        .map(|row| (row.id.as_str(), row.role, row.interrupted))
        .collect();
    assert_eq!(
        shown,
        [
            ("u1", RowRole::User, false),
            ("a1", RowRole::Assistant, true),
            ("u2", RowRole::User, false),
            ("a2", RowRole::Assistant, true),
            ("mention", RowRole::User, false),
            ("lookalike", RowRole::User, false),
            ("attached", RowRole::User, false),
        ]
    );
    assert!(
        rows.iter()
            .all(|row| !row.text.starts_with("[System: interrupted]\nThe user")),
        "the runner's instructions to the model never reach the transcript"
    );
}

#[test]
fn a_marker_after_a_user_message_marks_nothing() {
    // Interrupted before any reply text: there is no reply to mark, and the person's message
    // must not be marked or hidden.
    let items: Vec<ConversationItem> = history()
        .into_iter()
        .filter(|item| ["u1", "cancel1"].contains(&item.id.as_str()))
        .collect();
    let rows = history_rows(&items).expect("projects");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].id, "u1");
    assert!(!rows[0].interrupted);
}

#[test]
fn streamed_marker_marks_the_reply_instead_of_adding_a_user_row() {
    let mut harness = Harness::new("session1");
    let lines = events(STREAM);
    harness.send_all(&lines[..4]);
    assert!(!harness.last().interrupted);
    let outcome = harness.send(lines[4].clone());
    assert!(outcome.effects.changed, "the reply changed");
    assert_eq!(harness.last().id, "a1");
    assert!(harness.last().interrupted);
    harness.send(lines[5].clone());
    let shown: Vec<(&str, RowRole, bool)> = harness
        .snapshot()
        .rows
        .iter()
        .map(|row| (row.id.as_str(), row.role, row.interrupted))
        .collect();
    assert_eq!(
        shown,
        [
            ("u1", RowRole::User, false),
            ("a1", RowRole::Assistant, true),
            ("u2", RowRole::User, false),
        ]
    );
    // A replay of the marker changes nothing.
    let replay = harness.send(lines[4].clone());
    assert!(!replay.effects.changed);
}
