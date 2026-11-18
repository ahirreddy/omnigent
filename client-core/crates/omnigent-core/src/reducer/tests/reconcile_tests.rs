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

use super::*;
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
    incoming.header.status = TurnStatus::Idle;
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
    resolved.header.status = TurnStatus::Idle;
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
    let state = event_state_from_snapshot(&counted);
    assert_eq!(state.background_task_count, Some(2));
    assert_eq!(state.background_tasks.map(|tasks| tasks.len()), Some(1));
    let silent = session(json!({"id": SESSION, "status": "idle", "created_at": 1,
        "background_tasks": [{"command": "make watch"}]}));
    let state = event_state_from_snapshot(&silent);
    assert_eq!(
        (state.background_task_count, state.background_tasks),
        (None, None)
    );
}

fn minimal_session(extra: &Value) -> SessionSnapshot {
    let mut base = serde_json::json!({"id": SESSION, "status": "idle", "created_at": 1});
    for (key, value) in extra.as_object().unwrap() {
        base[key] = value.clone();
    }
    session(base)
}

#[test]
fn an_unknown_status_cannot_become_a_header() {
    let error = header_from_snapshot(
        &minimal_session(&serde_json::json!({"status": "odd"})),
        None,
    )
    .unwrap_err();
    assert_eq!(
        error,
        ProjectionError::UnknownStatus {
            session_id: SESSION.to_owned(),
            status: "odd".to_owned(),
        }
    );
}

#[test]
fn the_servers_side_chat_answer_stands_until_a_read_gives_another() {
    let allowed = |header: &SessionHeader| header.settings.as_ref().unwrap().side_chat_allowed;
    let unknown = header_from_snapshot(
        &minimal_session(&serde_json::json!({"harness": "claude-native"})),
        None,
    )
    .unwrap();
    assert_eq!(allowed(&unknown), None);
    let refused = header_from_snapshot(
        &minimal_session(
            &serde_json::json!({"harness": "claude-native", "side_chat_allowed": false}),
        ),
        Some(&unknown),
    )
    .unwrap();
    assert_eq!(allowed(&refused), Some(false));
    // A response that did not compute it sends `null`; a switched harness is the same viewer.
    let kept = header_from_snapshot(
        &minimal_session(
            &serde_json::json!({"harness": "codex-native", "side_chat_allowed": null}),
        ),
        Some(&refused),
    )
    .unwrap();
    assert_eq!(allowed(&kept), Some(false));
    let granted = header_from_snapshot(
        &minimal_session(&serde_json::json!({"side_chat_allowed": true})),
        Some(&kept),
    )
    .unwrap();
    assert_eq!(allowed(&granted), Some(true));
}

#[test]
fn a_side_chat_that_ended_is_closed_by_its_labels() {
    let settings = |header: &SessionHeader| header.settings.clone().unwrap();
    let live = header_from_snapshot(
        &minimal_session(&serde_json::json!({"labels": {
            "omnigent.wrapper": "codex-native-ui-subagent",
            "omnigent.codex_native.agent_nickname": "Side chat",
        }})),
        None,
    )
    .unwrap();
    assert!(settings(&live).is_side_chat && !settings(&live).closed);
    let ended = header_from_snapshot(
        &minimal_session(&serde_json::json!({"labels": {
            "omnigent.codex_native.agent_nickname": "Side chat", "omnigent.closed": "true",
        }})),
        Some(&live),
    )
    .unwrap();
    assert!(settings(&ended).is_side_chat && settings(&ended).closed);
    // A read that reports no labels keeps what is known.
    let kept =
        header_from_snapshot(&minimal_session(&serde_json::json!({})), Some(&ended)).unwrap();
    assert!(settings(&kept).closed);
    let sub_agent = header_from_snapshot(
        &minimal_session(&serde_json::json!({"labels": {"omnigent.closed": "true"}})),
        None,
    )
    .unwrap();
    assert!(settings(&sub_agent).closed && !settings(&sub_agent).is_side_chat);
}

/// Web `readOnlyReasonForSessionLabels`: only a closed Codex `/side` chat whose runner can
/// restore it (`side_chat_resume` is `"true"`) keeps taking messages.
#[test]
fn a_closed_codex_side_chat_the_server_can_resume_takes_messages() {
    let closed = |labels: serde_json::Value| {
        header_from_snapshot(&minimal_session(&serde_json::json!({"labels": labels})), None)
            .unwrap()
            .settings
            .unwrap()
            .closed
    };
    let side_chat = |resume: Option<&str>| {
        let mut labels = serde_json::json!({
            "omnigent.closed": "true",
            "omnigent.wrapper": "codex-native-ui-subagent",
            "omnigent.codex_native.agent_nickname": "Side chat",
        });
        if let Some(resume) = resume {
            labels["omnigent.codex_native.side_chat_resume"] = resume.into();
        }
        labels
    };
    assert!(!closed(side_chat(Some("true"))));
    assert!(closed(side_chat(Some("false"))));
    assert!(closed(side_chat(None)));
    // Another Codex sub-agent, or a server fork, stays closed whatever the label says.
    let mut reviewer = side_chat(Some("true"));
    reviewer["omnigent.codex_native.agent_nickname"] = "reviewer".into();
    assert!(closed(reviewer));
    let mut fork = side_chat(Some("true"));
    fork.as_object_mut().unwrap().remove("omnigent.wrapper");
    assert!(closed(fork));
}

#[test]
fn null_fields_clear_to_safe_defaults_and_absent_ones_keep_the_previous_value() {
    let earlier = header_from_snapshot(
        &minimal_session(&serde_json::json!({
            "title": "Named", "permission_level": 4, "archived": true,
        })),
        None,
    )
    .unwrap();
    assert_eq!(earlier.title, "Named");
    assert_eq!(earlier.permission_level, Some(4));
    let absent =
        header_from_snapshot(&minimal_session(&serde_json::json!({})), Some(&earlier)).unwrap();
    assert_eq!(absent.title, "Named");
    assert_eq!(absent.permission_level, Some(4));
    assert!(absent.archived);
    assert!(!absent.read_only);
    let cleared = header_from_snapshot(
        &minimal_session(&serde_json::json!({
            "title": null, "permission_level": null, "archived": null,
        })),
        Some(&earlier),
    )
    .unwrap();
    assert_eq!(cleared.title, UNTITLED_SESSION);
    assert_eq!(cleared.permission_level, None);
    assert!(cleared.read_only, "an unknown permission is read only");
    assert!(!cleared.archived);
    let blank =
        header_from_snapshot(&minimal_session(&serde_json::json!({"title": ""})), None).unwrap();
    assert_eq!(blank.title, UNTITLED_SESSION);
}

#[test]
fn a_failed_list_row_keeps_the_known_failure_or_says_something_generic() {
    let row = |status: &str| -> SessionListItem {
        serde_json::from_value(
            serde_json::json!({"id": SESSION, "status": status, "created_at": 1}),
        )
        .unwrap()
    };
    let generic = header_from_list_item(&row("failed"), None).unwrap();
    assert_eq!(
        generic.failure_message.as_deref(),
        Some(DEFAULT_FAILURE_MESSAGE)
    );
    let mut known = generic;
    known.failure_message = Some("It broke".to_owned());
    let kept = header_from_list_item(&row("failed"), Some(&known)).unwrap();
    assert_eq!(kept.failure_message.as_deref(), Some("It broke"));
    let fine = header_from_list_item(&row("idle"), Some(&known)).unwrap();
    assert_eq!(fine.failure_message, None);
}

#[test]
fn mcp_servers_in_an_unknown_state_are_not_shown() {
    let state = event_state_from_snapshot(&minimal_session(&serde_json::json!({
        "mcp_startup": {"good": {"status": "ready"}, "odd": {"status": "brand_new"}},
    })));
    let servers = state.mcp_startup.unwrap();
    assert_eq!(servers.keys().collect::<Vec<_>>(), ["good"]);
}

#[test]
fn a_repeated_history_item_keeps_its_place_and_its_latest_content() {
    let items: Vec<ConversationItem> = serde_json::from_value(serde_json::json!([
        {"id": "a", "type": "message", "role": "user", "content": "first"},
        {"id": "b", "type": "message", "role": "assistant", "content": "second"},
        {"id": "a", "type": "message", "role": "user", "content": "edited"},
    ]))
    .unwrap();
    let rows = history_rows(&items).unwrap();
    let shown: Vec<(&str, &str)> = rows
        .iter()
        .map(|row| (row.id.as_str(), row.text.as_str()))
        .collect();
    assert_eq!(shown, [("a", "edited"), ("b", "second")]);
}

#[test]
fn the_ledger_forgets_removed_sessions_and_stops_watching_a_lost_one() {
    let mut sync = seeded_sync();
    sync.open_stream();
    let mut ledger = MetadataLedger::default();
    ledger.cache(header_from_snapshot(&writable_session(), None).unwrap());
    let before = ledger.epoch(SESSION);
    ledger.remove(&[SESSION.to_owned()]);
    assert_eq!(ledger.header(SESSION), None);
    assert_eq!(ledger.epoch(SESSION), before + 1);

    assert!(!sync.handle_removed(&["other".to_owned()]));
    assert!(sync.handle_removed(&[SESSION.to_owned()]));
    assert_eq!(
        sync.request_hydration(),
        None,
        "a stopped sync reads nothing"
    );
    let ignored = sync
        .handle_event(serde_json::json!({"type": "session.title", "title": "x"}))
        .unwrap();
    assert_eq!(ignored, SyncUpdate::default());
}

#[test]
fn too_many_events_during_one_read_overflow_and_nothing_changes() {
    let mut sync = seeded_sync();
    let _request = sync.open_stream();
    for _ in 0..MAX_BUFFERED_EVENTS {
        sync.handle_event(serde_json::json!({"type": "session.title", "title": "x"}))
            .unwrap();
    }
    assert_eq!(
        sync.handle_event(serde_json::json!({"type": "session.title", "title": "y"})),
        Err(SyncError::BufferOverflow {
            limit: MAX_BUFFERED_EVENTS
        })
    );
    assert_eq!(sync.buffered_event_types().len(), MAX_BUFFERED_EVENTS);
}

#[test]
fn old_browser_actions_are_forgotten_and_a_replay_of_a_recent_one_is_silenced() {
    let mut sync = seeded_sync();
    let action = |index: usize| {
        serde_json::json!({
            "type": "browser.action_request", "action_id": format!("a{index}"), "action": "open",
        })
    };
    assert!(
        sync.handle_event(action(0))
            .unwrap()
            .effects
            .browser_action
            .is_some()
    );
    assert!(
        sync.handle_event(action(0))
            .unwrap()
            .effects
            .browser_action
            .is_none(),
        "the replay is not run again"
    );
    for index in 1..=MAX_REMEMBERED_BROWSER_ACTIONS {
        sync.handle_event(action(index)).unwrap();
    }
    assert!(
        sync.handle_event(action(0))
            .unwrap()
            .effects
            .browser_action
            .is_some(),
        "the memory is bounded, so the oldest was forgotten"
    );
}

#[test]
fn a_configuration_read_is_refused_for_another_session_or_after_watching_stopped() {
    let mut sync = seeded_sync();
    let read = sync.begin_configuration_read("other");
    assert!(matches!(
        sync.finish_configuration_read(&read, &writable_session()),
        Err(ConfigurationReadError::WrongSession { .. })
    ));
    let read = sync.begin_configuration_read(SESSION);
    sync.stop();
    assert_eq!(
        sync.finish_configuration_read(&read, &writable_session())
            .map(|_| ()),
        Err(ConfigurationReadError::StreamChanged)
    );
}

#[test]
fn a_configuration_read_of_another_session_keeps_this_sessions_buffered_settings() {
    let mut sync = seeded_sync();
    sync.open_stream();
    sync.handle_event(serde_json::json!({"type": "session.model", "model": "m"}))
        .unwrap();
    assert_eq!(sync.buffered_event_types().len(), 1);
    let other = serde_json::json!({"id": "other", "status": "idle", "created_at": 1});
    let read = sync.begin_configuration_read("other");
    sync.finish_configuration_read(&read, &session(other))
        .unwrap();
    assert_eq!(sync.buffered_event_types().len(), 1);
    let read = sync.begin_configuration_read(SESSION);
    sync.finish_configuration_read(&read, &writable_session())
        .unwrap();
    assert_eq!(
        sync.buffered_event_types().len(),
        0,
        "the read of this session supersedes its buffered settings"
    );
}

#[test]
fn an_explicit_null_agrees_only_with_nothing_known() {
    let known = 5;
    assert!(same_as(&Field::<i32>::Null, None));
    assert!(!same_as(&Field::<i32>::Null, Some(&known)));
}

fn sandbox_session(fields: &Value) -> SessionSnapshot {
    let mut value =
        json!({"id": SESSION, "status": "idle", "created_at": 1, "permission_level": 4});
    for (key, field) in fields.as_object().expect("fields") {
        value[key] = field.clone();
    }
    session(value)
}

#[test]
fn a_session_read_reports_the_sandbox_profile_and_whether_a_launch_is_under_way() {
    let launching = sandbox_session(&json!({
        "sandbox_status": {"stage": "cloning", "provider": "example"},
        "sandbox_profile": {"id": "gpu", "name": "GPU box", "provider": "modal", "revision": "r1"}
    }));
    let state = event_state_from_snapshot(&launching);
    assert_eq!(
        state.sandbox.map(|status| status.stage.as_str().to_owned()),
        Some("cloning".to_owned())
    );
    assert_eq!(state.sandbox_settled, None);
    let header = header_from_snapshot(&launching, None).expect("header");
    // The launch reaches a header through the reducer's event state only.
    assert_eq!(header.sandbox_launch, None);
    let profile = |header: &SessionHeader| {
        header
            .settings
            .as_ref()
            .and_then(|settings| settings.sandbox_profile.clone())
            .map(|profile| (profile.provider, profile.name))
    };
    assert_eq!(
        profile(&header),
        Some(("modal".to_owned(), "GPU box".to_owned()))
    );
    // A read that says nothing keeps the profile, also across an agent change.
    let silent = sandbox_session(&json!({}));
    assert_eq!(event_state_from_snapshot(&silent).sandbox_settled, None);
    let kept = header_from_snapshot(&silent, Some(&header)).expect("header");
    assert!(profile(&kept).is_some());
    let switched = sandbox_session(&json!({"agent_id": "other", "harness": "pi-native"}));
    let moved = header_from_snapshot(&switched, Some(&header)).expect("header");
    assert!(profile(&moved).is_some());
    // An explicit null ends the launch and clears the profile.
    let settled = sandbox_session(&json!({"sandbox_status": null, "sandbox_profile": null}));
    let state = event_state_from_snapshot(&settled);
    assert_eq!((state.sandbox, state.sandbox_settled), (None, Some(true)));
    let cleared = header_from_snapshot(&settled, Some(&header)).expect("header");
    assert_eq!(profile(&cleared), None);
}

#[test]
fn hydration_shows_the_launch_follows_its_events_and_readies_it_when_a_read_says_so() {
    use crate::sandbox_state::LaunchStage;
    let stage = |sync: &ConversationSync| {
        reducer_header(sync)
            .and_then(|header| header.sandbox_launch.as_ref())
            .map(|launch| launch.stage)
    };
    let mut sync = ConversationSync::new(SESSION);
    let request = sync.request_hydration().expect("hydration starts");
    let launching = sandbox_session(&json!({"sandbox_status": {"stage": "cloning"}}));
    sync.finish_hydration(&request, &launching, &[])
        .expect("hydration");
    assert_eq!(stage(&sync), Some(LaunchStage::Cloning));
    let update = sync
        .handle_event(json!({
            "type": "session.sandbox_status", "conversation_id": SESSION, "stage": "connecting"
        }))
        .expect("event applies");
    let published = update
        .changes
        .header
        .and_then(|header| header.sandbox_launch);
    assert_eq!(
        published.map(|launch| launch.stage),
        Some(LaunchStage::Connecting)
    );
    // The stage asks for a read; this one was taken after a `ready` the stream never delivered.
    let request = update.hydrate.expect("the stage asks for a read");
    let settled = sandbox_session(&json!({"sandbox_status": null}));
    sync.finish_hydration(&request, &settled, &[])
        .expect("hydration");
    assert_eq!(stage(&sync), Some(LaunchStage::Ready));
}

/// What a native Codex send streamed on a local stack: the runner's running edge, the wrapper
/// response that typed the prompt, then the harness's running edge for its own turn.
fn native_turn_start() -> Vec<Value> {
    vec![
        json!({"type": "session.status", "conversation_id": SESSION, "status": "running"}),
        json!({"type": "response.in_progress", "response": {"id": "resp_wrapper"}}),
        json!({"type": "response.completed", "response": {"id": "resp_wrapper"}}),
        json!({
            "type": "session.status", "conversation_id": SESSION, "status": "running",
            "response_id": "codex_turn"
        }),
    ]
}

fn status(sync: &ConversationSync) -> Option<TurnStatus> {
    reducer_header(sync).map(|header| header.status)
}

#[test]
fn a_turn_that_starts_during_a_read_stays_working_whatever_the_read_says() {
    for read_status in ["idle", "running"] {
        let mut sync = ConversationSync::new(SESSION);
        let first = sync.open_stream();
        sync.finish_hydration(&first, &minimal_session(&json!({})), &[])
            .expect("first read");
        assert_eq!(status(&sync), Some(TurnStatus::Idle));
        // A send asks for a read, and the turn starts while it is in flight.
        let request = sync.request_hydration().expect("hydration starts");
        send(&mut sync, &native_turn_start());
        assert_eq!(status(&sync), Some(TurnStatus::Running));
        let read = minimal_session(&json!({ "status": read_status }));
        let update = sync
            .finish_hydration(&request, &read, &[])
            .expect("hydration");
        assert_eq!(
            status(&sync),
            Some(TurnStatus::Running),
            "a read that answered {read_status} ended a turn the stream started"
        );
        if let Some(again) = update.hydrate {
            let running = minimal_session(&json!({"status": "running"}));
            sync.finish_hydration(&again, &running, &[])
                .expect("follow-up read");
            assert_eq!(status(&sync), Some(TurnStatus::Running));
        }
    }
}

#[test]
fn a_turn_that_ends_during_a_read_stays_ended_and_settings_still_come_from_the_read() {
    let mut sync = ConversationSync::new(SESSION);
    let first = sync.open_stream();
    sync.finish_hydration(&first, &minimal_session(&json!({"status": "running"})), &[])
        .expect("first read");
    let request = sync.request_hydration().expect("hydration starts");
    send(
        &mut sync,
        &[json!({"type": "session.status", "conversation_id": SESSION, "status": "idle"})],
    );
    let read = minimal_session(&json!({"status": "running", "harness": "codex-native"}));
    let update = sync
        .finish_hydration(&request, &read, &[])
        .expect("hydration");
    assert_eq!(status(&sync), Some(TurnStatus::Idle));
    // A read crossed only by settings keeps its own status.
    let request = update
        .hydrate
        .expect("the turn's end asks for another read");
    send(
        &mut sync,
        &[json!({"type": "session.model", "conversation_id": SESSION, "model": "other"})],
    );
    sync.finish_hydration(
        &request,
        &minimal_session(&json!({"status": "running"})),
        &[],
    )
    .expect("hydration");
    assert_eq!(status(&sync), Some(TurnStatus::Running));
}

/// A watched, idle session running `harness`.
fn idle_sync(harness: &str) -> ConversationSync {
    let mut sync = ConversationSync::new(SESSION);
    let first = sync.open_stream();
    sync.finish_hydration(
        &first,
        &minimal_session(&json!({ "harness": harness })),
        &[],
    )
    .expect("first read");
    sync
}

fn shown(sync: &ConversationSync) -> Option<TurnStatus> {
    sync.shown_header().map(|header| header.status)
}

/// The status an update publishes, when it publishes a header.
fn published(update: &SyncUpdate) -> Option<TurnStatus> {
    update.changes.header.as_ref().map(|header| header.status)
}

fn session_status(status: &str) -> Value {
    json!({"type": "session.status", "conversation_id": SESSION, "status": status})
}

#[test]
fn a_sent_message_shows_working_until_the_server_reports_its_turn() {
    let mut sync = idle_sync("codex-native");
    assert_eq!(published(&sync.expect_turn(1)), Some(TurnStatus::Running));
    assert_eq!(
        status(&sync),
        Some(TurnStatus::Idle),
        "the server has not said so"
    );
    // A read taken before the turn started, and the wrapper that typed the prompt, keep it.
    let request = sync.request_hydration().expect("hydration starts");
    sync.finish_hydration(
        &request,
        &minimal_session(&json!({"harness": "codex-native"})),
        &[],
    )
    .expect("hydration");
    assert_eq!(shown(&sync), Some(TurnStatus::Running));
    send(
        &mut sync,
        &[
            json!({"type": "response.in_progress", "response": {"id": "resp_wrapper"}}),
            json!({"type": "response.completed", "response": {"id": "resp_wrapper"}}),
        ],
    );
    assert_eq!(shown(&sync), Some(TurnStatus::Running));
    // Once the server reports the turn, its word stands and the turn ends with it.
    send(&mut sync, &[session_status("running")]);
    let ended = sync
        .handle_event(session_status("idle"))
        .expect("idle applies");
    assert_eq!(published(&ended), Some(TurnStatus::Idle));
    assert_eq!(shown(&sync), Some(TurnStatus::Idle));
    assert!(sync.end_turn_expectation(1).changes.is_empty());
}

#[test]
fn the_shown_turn_ends_with_a_refusal_its_time_or_any_server_answer() {
    // Refused, or out of time: the same call. A newer send's expectation outlives an older one.
    let mut sync = idle_sync("codex-native");
    sync.expect_turn(1);
    sync.expect_turn(2);
    assert!(sync.end_turn_expectation(1).changes.is_empty());
    assert_eq!(
        published(&sync.end_turn_expectation(2)),
        Some(TurnStatus::Idle)
    );
    // The server saying the session is idle or failed ends it, published although its own
    // status did not change.
    for answer in ["idle", "failed"] {
        let mut sync = idle_sync("codex-native");
        sync.expect_turn(1);
        let update = sync
            .handle_event(session_status(answer))
            .expect("status applies");
        assert_eq!(published(&update), Some(TurnStatus::Idle), "{answer}");
    }
    // An ordinary harness's turn ends with its response.
    let mut sync = idle_sync("openai-agents");
    sync.expect_turn(1);
    let update = sync
        .handle_event(json!({"type": "response.completed", "response": {"id": "resp_1"}}))
        .expect("completion applies");
    assert_eq!(published(&update), Some(TurnStatus::Idle));
    // A read that shows the turn under way hands it to the server.
    let mut sync = idle_sync("openai-agents");
    sync.expect_turn(1);
    let request = sync.request_hydration().expect("hydration starts");
    sync.finish_hydration(
        &request,
        &minimal_session(&json!({"status": "running"})),
        &[],
    )
    .expect("hydration");
    let update = sync
        .handle_event(json!({"type": "response.completed", "response": {"id": "resp_1"}}))
        .expect("completion applies");
    assert_eq!(shown(&sync), Some(TurnStatus::Idle), "{update:?}");
}

#[test]
fn only_an_idle_watched_session_shows_an_expected_turn() {
    let mut sync = ConversationSync::new(SESSION);
    assert_eq!(sync.expect_turn(1), SyncUpdate::default(), "nothing loaded");
    let mut sync = idle_sync("codex-native");
    send(&mut sync, &[session_status("running")]);
    assert_eq!(
        sync.expect_turn(1),
        SyncUpdate::default(),
        "already running"
    );
    let mut sync = idle_sync("codex-native");
    sync.stop();
    assert_eq!(
        sync.expect_turn(1),
        SyncUpdate::default(),
        "no longer watched"
    );
}
