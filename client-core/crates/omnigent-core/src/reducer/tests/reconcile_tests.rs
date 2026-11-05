//! Tests of `crate::reconcile`: ports of `NativeLab` `ConversationStateTests`, the hydration rows
//! of `LocalServerHydrationStreamingTests` and the reconciliation rows of
//! `SessionConfigurationTests`.
//!
//! Wire-contract divergence D10: the current server's session list rows (REST and WebSocket) do
//! not carry `model_override`, so the `NativeLab` fixtures whose list rows deliver a newer model
//! cannot change it here. Those tests deliver the newer metadata through a field list rows do
//! carry (`reasoning_effort: "low"`); the epoch rules under test are the same.

use omnigent_protocol::{ConversationItem, FromWire, SessionListItem, SessionSnapshot};
use serde_json::{Value, json};

use crate::reconcile::{
    ConfigurationReadError, ConversationState, ConversationSync, header_from_snapshot,
};
use crate::reducer::tests::{
    Harness, assistant, fixture, fixture_lines, sse_data, swift_snapshot, user,
};
use crate::reducer::{ConversationSnapshot, ReportedValue, Row, SessionHeader};

const SESSION: &str = "conv_a";

fn response(path: &str) -> Value {
    fixture(path)["response"].clone()
}

fn session(value: Value) -> SessionSnapshot {
    SessionSnapshot::from_value(value).expect("session decodes")
}

/// History items of an `/items` envelope; `NativeLab` pages newest first, so they are reversed.
fn history(path: &str) -> Vec<ConversationItem> {
    let mut items: Vec<ConversationItem> = response(path)["data"]
        .as_array()
        .expect("items")
        .iter()
        .map(|item| ConversationItem::from_value(item.clone()).expect("item decodes"))
        .collect();
    items.reverse();
    items
}

fn rows_of(message: &Value) -> Vec<SessionListItem> {
    message["items"]
        .as_array()
        .or_else(|| message["data"].as_array())
        .expect("rows")
        .iter()
        .map(|row| SessionListItem::from_value(row.clone()).expect("row decodes"))
        .collect()
}

/// The WebSocket frames of a `ws.jsonl` fixture.
fn frames(path: &str) -> Vec<Value> {
    fixture_lines(path)
        .into_iter()
        .map(|line| line["message"].clone())
        .collect()
}

/// A list frame whose rows report `reasoning_effort: "low"` (see the module docs).
fn with_low_effort(mut message: Value) -> Value {
    for key in ["items", "data"] {
        if let Some(rows) = message[key].as_array_mut() {
            for row in rows {
                row["reasoning_effort"] = json!("low");
            }
        }
    }
    message
}

fn effort(header: Option<&SessionHeader>) -> ReportedValue {
    header
        .and_then(|header| header.settings.as_ref())
        .map(|settings| settings.reasoning_effort.clone())
        .unwrap_or_default()
}

fn low() -> ReportedValue {
    ReportedValue::Value {
        value: "low".to_owned(),
    }
}

fn reducer_header(sync: &ConversationSync) -> Option<&SessionHeader> {
    sync.reducer().map(|reducer| &reducer.snapshot().header)
}

fn texts(sync: &ConversationSync) -> Vec<String> {
    sync.published()
        .map(|snapshot| snapshot.rows.iter().map(|row| row.text.clone()).collect())
        .unwrap_or_default()
}

fn ids(sync: &ConversationSync) -> Vec<String> {
    sync.published()
        .map(|snapshot| snapshot.rows.iter().map(|row| row.id.clone()).collect())
        .unwrap_or_default()
}

fn last(sync: &ConversationSync) -> Row {
    sync.published()
        .and_then(|snapshot| snapshot.rows.last().cloned())
        .expect("a row")
}

// ConversationStateTests.swift

fn demo(name: &str) -> ConversationSnapshot {
    swift_snapshot(&fixture(&format!("sessions/DemoFixtures--{name}.json")))
}

#[test]
fn newer_snapshot_replaces_messages_and_decisions_together() {
    let initial = demo("demo-design");
    assert_eq!(initial.pending_decisions().count(), 1);
    let mut state = ConversationState::new(initial.clone());
    let mut incoming = initial;
    incoming.revision += 1;
    incoming.decisions[0].answered = true;
    incoming.header.status = crate::reducer::TurnStatus::Idle;
    incoming
        .rows
        .push(assistant("next-message", "Ready to continue."));
    assert!(state.apply(incoming.clone()));
    assert_eq!(*state.snapshot(), incoming);
    assert_eq!(state.snapshot().pending_decisions().count(), 0);
}

#[test]
fn older_and_equal_revisions_cannot_restore_resolved_decision() {
    let old = demo("demo-design");
    let mut resolved = old.clone();
    resolved.revision += 1;
    resolved.decisions[0].answered = true;
    resolved.header.status = crate::reducer::TurnStatus::Idle;
    let mut state = ConversationState::new(resolved.clone());
    assert!(!state.apply(old.clone()));
    let mut conflicting = old;
    conflicting.revision = resolved.revision;
    assert!(!state.apply(conflicting));
    assert_eq!(*state.snapshot(), resolved);
}

#[test]
fn different_session_is_rejected_even_with_higher_revision() {
    let initial = demo("demo-design");
    let mut state = ConversationState::new(initial.clone());
    let mut another = demo("demo-question");
    another.revision = 100;
    assert!(!state.apply(another));
    assert_eq!(*state.snapshot(), initial);
}

// LocalServerHydrationStreamingTests.swift

fn writable_session() -> SessionSnapshot {
    session(response(
        "sessions/LocalServerSessionClient--_shared--writable-session.json",
    ))
}

/// A sync whose conversation was loaded before the test (`seedHistory: true`).
fn seeded_sync() -> ConversationSync {
    let session = writable_session();
    let header = header_from_snapshot(&session, None).expect("header");
    let mut snapshot = ConversationSnapshot::new(header);
    snapshot.rows = vec![user("question", "Question")];
    let mut sync = ConversationSync::new(SESSION);
    sync.adopt(snapshot);
    sync
}

fn hydration_case(name: &str) -> (Vec<Value>, Vec<Value>, Vec<Value>, Vec<ConversationItem>) {
    let base = format!("LocalServerHydrationStreaming--{name}");
    let optional = |label: &str| {
        let path = format!(
            "{}/../../fixtures/sse/{base}--{label}.jsonl",
            env!("CARGO_MANIFEST_DIR")
        );
        if std::path::Path::new(&path).exists() {
            sse_data(&format!("{base}--{label}.jsonl"))
        } else {
            Vec::new()
        }
    };
    (
        optional("before"),
        optional("during"),
        optional("after"),
        history(&format!("items/{base}--history.json")),
    )
}

fn send(sync: &mut ConversationSync, events: &[Value]) {
    for event in events {
        sync.handle_event(event.clone()).expect("event applies");
    }
}

#[test]
fn rehydration_keeps_growing_text_and_chunk_indices_without_replaying_deltas() {
    let (before, during, after, items) =
        hydration_case("RehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas");
    let mut sync = seeded_sync();
    send(&mut sync, &before);
    let request = sync.request_hydration().expect("hydration starts");
    send(&mut sync, &during);
    assert_eq!(last(&sync).text, "Hello world");
    sync.finish_hydration(&request, &writable_session(), &items)
        .expect("hydration");
    send(&mut sync, &after);
    assert_eq!(texts(&sync), ["Question", "Hello world!"]);
}

#[test]
fn shorter_persisted_prefix_cannot_replace_text_that_grew_during_hydration() {
    let (before, during, after, items) =
        hydration_case("ShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration");
    let mut sync = seeded_sync();
    send(&mut sync, &before);
    let request = sync.request_hydration().expect("hydration starts");
    send(&mut sync, &during);
    sync.finish_hydration(&request, &writable_session(), &items)
        .expect("hydration");
    assert_eq!(texts(&sync), ["Question", "Hello world"]);
    assert!(last(&sync).is_streaming);
    send(&mut sync, &after);
    assert_eq!(last(&sync).text, "Hello world!");
}

#[test]
fn hydrated_commit_replaces_live_preview_without_duplicating_text() {
    let (before, _, after, items) =
        hydration_case("HydratedCommitReplacesLivePreviewWithoutDuplicatingText");
    let mut sync = ConversationSync::new(SESSION);
    let request = sync.request_hydration().expect("hydration starts");
    send(&mut sync, &before);
    sync.finish_hydration(&request, &writable_session(), &items)
        .expect("hydration");
    send(&mut sync, &after);
    assert_eq!(ids(&sync), ["question", "saved"]);
    assert_eq!(last(&sync).text, "Hello world");
}

#[test]
fn consumed_input_is_published_immediately_and_its_effect_is_not_repeated_on_hydration() {
    let base = "LocalServerHydrationStreaming--ConsumedInputIsPublishedImmediatelyAndItsEffectIsNotRepeatedOnHydration";
    let items = history(&format!("items/{base}--history.json"));
    let mut sync = seeded_sync();
    let request = sync.request_hydration().expect("hydration starts");
    let consumed = sse_data(&format!("{base}--live.jsonl"));
    let update = sync
        .handle_event(consumed[0].clone())
        .expect("consumed applies");
    assert_eq!(update.effects.consumed_item_id.as_deref(), Some("next"));
    assert_eq!(
        update.effects.consumed_pending_id.as_deref(),
        Some("pending")
    );
    assert_eq!(last(&sync).text, "Next question");
    let finished = sync
        .finish_hydration(&request, &writable_session(), &items)
        .expect("hydration");
    assert_eq!(finished.effects.consumed_item_id, None);
    assert_eq!(ids(&sync), ["question", "next"]);
}

#[test]
fn stale_or_stopped_hydration_cannot_publish() {
    let mut sync = seeded_sync();
    let request = sync.request_hydration().expect("hydration starts");
    sync.stop();
    let update = sync
        .finish_hydration(&request, &writable_session(), &[])
        .expect("stale read is ignored");
    assert!(update.changes.is_empty());
    let late = sync.handle_event(json!({"type": "response.output_text.delta", "delta": "late"}));
    assert!(late.expect("ignored").changes.is_empty());
    assert!(sync.reducer().is_none());
}

#[test]
fn reconnect_starts_a_fresh_reducer_without_blanking_committed_rows() {
    let mut sync = seeded_sync();
    send(
        &mut sync,
        &[
            json!({"type":"response.output_text.delta","message_id":"native1","index":4,"delta":"stale prefix"}),
        ],
    );
    let request = sync.open_stream();
    let update = sync
        .handle_event(json!({"type":"response.output_text.delta","message_id":"native1","index":4,"delta":"authoritative prefix"}))
        .expect("replay applies");
    assert!(!update.changes.is_empty());
    send(
        &mut sync,
        &[
            json!({"type":"response.output_text.delta","message_id":"native1","index":5,"delta":" tail"}),
        ],
    );
    assert_eq!(texts(&sync), ["Question", "authoritative prefix tail"]);
    sync.finish_hydration(&request, &writable_session(), &history(
        "items/LocalServerHydrationStreaming--RehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas--history.json",
    ))
    .expect("hydration");
    assert_eq!(texts(&sync), ["Question", "authoritative prefix tail"]);
}

// SessionConfigurationTests.swift

const CONFIG: &str = "sessions/SessionConfiguration--";

fn configuration_snapshot() -> SessionSnapshot {
    session(response(&format!(
        "{CONFIG}StreamEventCrossingSnapshotReadRejectsStaleConfiguration--snapshot.json"
    )))
}

#[test]
fn stream_event_crossing_snapshot_read_rejects_stale_configuration() {
    let mut sync = ConversationSync::new(SESSION);
    let read = sync.begin_configuration_read(SESSION);
    let event = sse_data(
        "SessionConfiguration--StreamEventCrossingSnapshotReadRejectsStaleConfiguration--event.jsonl",
    );
    send(&mut sync, &event);
    let result = sync.finish_configuration_read(&read, &configuration_snapshot());
    assert_eq!(
        result.map(|(header, _)| header),
        Err(ConfigurationReadError::ChangedElsewhere)
    );
    assert!(sync.ledger().header(SESSION).is_none());
}

#[test]
fn list_event_crossing_snapshot_read_rejects_stale_configuration() {
    let mut sync = ConversationSync::new(SESSION);
    let snapshot = session(response(&format!(
        "{CONFIG}ListEventCrossingSnapshotReadRejectsStaleConfiguration--snapshot.json"
    )));
    let read = sync.begin_configuration_read(SESSION);
    let frame = with_low_effort(
        frames(&format!(
            "{CONFIG}ListEventCrossingSnapshotReadRejectsStaleConfiguration--ws.jsonl"
        ))[0]
            .clone(),
    );
    sync.handle_list_rows(&rows_of(&frame))
        .expect("list frame applies");
    let result = sync.finish_configuration_read(&read, &snapshot);
    assert_eq!(
        result.map(|(header, _)| header),
        Err(ConfigurationReadError::ChangedElsewhere)
    );
    assert_eq!(effort(sync.ledger().header(SESSION)), low());
}

#[test]
fn slow_history_cannot_rollback_newer_metadata() {
    let mut sync = ConversationSync::new(SESSION);
    let original = session(response(&format!(
        "{CONFIG}SlowHistoryCannotRollbackNewerMetadata--session.json"
    )));
    let items =
        history("items/SessionConfiguration--SlowHistoryCannotRollbackNewerMetadata--items.json");
    let request = sync.open_stream();
    let frame = with_low_effort(
        frames(&format!(
            "{CONFIG}SlowHistoryCannotRollbackNewerMetadata--ws.jsonl"
        ))[0]
            .clone(),
    );
    sync.handle_list_rows(&rows_of(&frame))
        .expect("list frame applies");
    let update = sync
        .finish_hydration(&request, &original, &items)
        .expect("hydration");
    let header = reducer_header(&sync).expect("header");
    assert_eq!(effort(Some(header)), low());
    assert!(header.metadata_revision.is_some());
    assert!(
        update.hydrate.is_some(),
        "the sparse list change asks for one more read"
    );
}

#[test]
fn slow_list_and_inventory_cannot_rollback_newer_metadata() {
    for _inventory in [false, true] {
        let mut sync = ConversationSync::new(SESSION);
        let page = rows_of(&response(&format!(
            "{CONFIG}SlowListAndInventoryCannotRollbackNewerMetadata--list.json"
        )));
        let read = sync.begin_list_read();
        let frame = with_low_effort(
            frames(&format!(
                "{CONFIG}SlowListAndInventoryCannotRollbackNewerMetadata--ws.jsonl"
            ))[0]
                .clone(),
        );
        sync.handle_list_rows(&rows_of(&frame))
            .expect("list frame applies");
        let update = sync.finish_list_read(&read, &page).expect("list read");
        assert_eq!(effort(update.headers.first()), low());
    }
}

#[test]
fn hydration_completion_preserves_acknowledged_configuration_and_schedules_followup() {
    let acknowledged = session(response(&format!(
        "{CONFIG}HydrationCompletionPreservesAcknowledgedConfigurationAndSchedulesFollowup.json"
    )));
    let original = configuration_snapshot();
    let mut sync = ConversationSync::new(SESSION);
    let request = sync.request_hydration().expect("hydration starts");
    let read = sync.begin_configuration_read(SESSION);
    sync.finish_configuration_read(&read, &acknowledged)
        .expect("configuration read");
    sync.finish_hydration(&request, &original, &[])
        .expect("hydration");
    let settings = reducer_header(&sync)
        .and_then(|h| h.settings.clone())
        .expect("settings");
    assert_eq!(settings.model_override.value(), Some("external-model"));
    assert!(sync.request_hydration().is_some());
    assert!(sync.request_hydration().is_none());
    assert!(sync.hydration_requested_again());
}

#[test]
fn stable_configuration_read_supersedes_buffered_settings_but_keeps_text() {
    let snapshot = session(response(&format!(
        "{CONFIG}StableConfigurationReadSupersedesBufferedSettingsButKeepsText.json"
    )));
    let mut sync = ConversationSync::new(SESSION);
    sync.request_hydration().expect("hydration starts");
    send(
        &mut sync,
        &sse_data(
            "SessionConfiguration--StableConfigurationReadSupersedesBufferedSettingsButKeepsText--buffered.jsonl",
        ),
    );
    assert_eq!(
        sync.buffered_event_types(),
        ["session.model", "response.output_text.delta"]
    );
    let read = sync.begin_configuration_read(SESSION);
    sync.finish_configuration_read(&read, &snapshot)
        .expect("configuration read");
    assert_eq!(sync.buffered_event_types(), ["response.output_text.delta"]);
}

#[test]
fn list_read_also_updates_reducer_before_next_stream_publication() {
    let original = header_from_snapshot(&configuration_snapshot(), None).expect("header");
    let mut sync = ConversationSync::new(SESSION);
    sync.adopt(ConversationSnapshot::new(original));
    let page = with_low_effort(response(&format!(
        "{CONFIG}ListReadAlsoUpdatesReducerBeforeNextStreamPublication.json"
    )));
    let read = sync.begin_list_read();
    let update = sync
        .finish_list_read(&read, &rows_of(&page))
        .expect("list read");
    assert_eq!(effort(reducer_header(&sync)), low());
    assert!(update.changes.header.is_some());
}

#[test]
fn sparse_change_hydration_cannot_overwrite_later_complete_metadata() {
    let original = session(response(&format!(
        "{CONFIG}SparseChangeHydrationCannotOverwriteLaterCompleteMetadata--session.json"
    )));
    let ws = frames(&format!(
        "{CONFIG}SparseChangeHydrationCannotOverwriteLaterCompleteMetadata--ws.jsonl"
    ));
    let mut sync = ConversationSync::new(SESSION);
    let initial = sync.open_stream();
    sync.finish_hydration(&initial, &original, &[])
        .expect("initial hydration");
    let sparse = sync
        .handle_list_rows(&rows_of(&ws[1]))
        .expect("sparse frame");
    let request = sparse.hydrate.expect("a sparse change re-reads history");
    sync.handle_list_rows(&rows_of(&with_low_effort(ws[0].clone())))
        .expect("later frame");
    sync.finish_hydration(&request, &original, &[])
        .expect("delayed hydration");
    assert_eq!(effort(reducer_header(&sync)), low());
    assert_eq!(effort(sync.ledger().header(SESSION)), low());
}

#[test]
fn harness_mirror_matches_sync_changes_across_hydration() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "response.output_text.delta", "message_id": "m", "delta": "Hi"}));
    harness.reconcile(crate::reducer::tests::conversation(
        SESSION,
        vec![assistant("m", "Hi")],
    ));
    assert_eq!(harness.ids(), ["m"]);
}

#[test]
fn browser_action_requests_reach_the_host_once_across_replays_and_reconnects() {
    let request = json!({
        "type": "browser.action_request",
        "action_id": "baction_1",
        "action": "navigate",
        "args": {"url": "https://example.com"}
    });
    let mut sync = ConversationSync::new(SESSION);
    let first = sync.open_stream();
    let update = sync.handle_event(request.clone()).expect("applies");
    let action = update
        .effects
        .browser_action
        .expect("an action for the host");
    assert_eq!(action.session_id, SESSION);
    assert_eq!(action.action_id, "baction_1");
    assert_eq!(action.action, "navigate");
    assert_eq!(action.args["url"], "https://example.com");
    // The buffered copy replays onto history without asking again.
    let snapshot = session(json!({"id": SESSION, "status": "running", "created_at": 1}));
    let replayed = sync
        .finish_hydration(&first, &snapshot, &[])
        .expect("hydration");
    assert!(replayed.effects.browser_action.is_none());
    assert!(
        ids(&sync).iter().any(|id| id == "event:browser:baction_1"),
        "{:?}",
        ids(&sync)
    );
    // A reconnect starts a fresh reducer; a repeated delivery is still not repeated.
    sync.open_stream();
    let again = sync.handle_event(request).expect("applies");
    assert!(again.effects.browser_action.is_none());
    let other = sync
        .handle_event(json!({
            "type": "browser.action_request",
            "action_id": "baction_2",
            "action": "snapshot",
            "args": null
        }))
        .expect("applies");
    let action = other.effects.browser_action.expect("a new action");
    assert!(action.args.is_empty());
    // Another session's request never reaches this one.
    let foreign = sync
        .handle_event(json!({
            "type": "browser.action_request",
            "conversation_id": "conv_other",
            "action_id": "baction_3",
            "action": "snapshot",
            "args": {}
        }))
        .expect("applies");
    assert!(foreign.effects.browser_action.is_none());
}

#[test]
fn a_snapshot_seeds_background_tasks_only_with_their_count() {
    let counted = session(json!({"id": SESSION, "status": "waiting", "created_at": 1,
        "background_task_count": 2, "background_tasks": [{"command": "make watch"}]}));
    let state = crate::reconcile::event_state_from_snapshot(&counted);
    assert_eq!(state.background_task_count, Some(2));
    assert_eq!(state.background_tasks.map(|tasks| tasks.len()), Some(1));
    let silent = session(json!({"id": SESSION, "status": "idle", "created_at": 1,
        "background_tasks": [{"command": "make watch"}]}));
    let state = crate::reconcile::event_state_from_snapshot(&silent);
    assert_eq!(
        (state.background_task_count, state.background_tasks),
        (None, None)
    );
}
