//! An older page finishing after its session has gone.

use super::*;
use crate::connection::UrlPolicy;
use crate::sync::ConversationSync;
use crate::test_support::Harness;

#[test]
fn an_older_page_for_a_session_that_has_closed_does_nothing() {
    let harness = Harness::new(UrlPolicy::Development);
    let (mut engine, _queue) = harness.idle_engine();
    let sync = ConversationSync::create("gone");
    let reading = sync.open_stream_raw();
    let snapshot = serde_json::json!({"id": "gone", "status": "idle", "created_at": 1});
    sync.finish_hydration_raw(
        &reading,
        &serde_json::from_value(snapshot).unwrap(),
        &[],
        Some("cursor_1"),
    )
    .unwrap();
    let request = sync.begin_older_history_raw().unwrap();
    engine.older_loaded("gone", &request, Err(SessionError::NotConnected));
    assert_eq!(harness.events.all(), []);
}
