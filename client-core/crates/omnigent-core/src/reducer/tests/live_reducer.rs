//! Port of `NativeLab` `LiveConversationReducerTests.swift` (the WP3 rows).

use omnigent_protocol::sessions::NativeModelOption;
use serde_json::json;

use super::{Harness, assistant, conversation, events, user};
use crate::reducer::{
    ActivityKind, ReducerError, ReportedValue, RowRole, SessionSettings, TurnStatus, effort_label,
    model_label,
};

const SESSION: &str = "session1";

fn reducer_events(name: &str) -> Vec<serde_json::Value> {
    events(&format!("LiveConversationReducer--{name}.jsonl"))
}

#[test]
fn native_replies_stream_after_wrapper_completion_across_consecutive_turns() {
    let mut harness = Harness::new(SESSION);
    let lines = reducer_events("NativeRepliesStreamAfterWrapperCompletionAcrossConsecutiveTurns");
    for (turn, lines) in lines.chunks(7).enumerate() {
        let turn = turn + 1;
        harness.send_all(&lines[..4]);
        assert_eq!(harness.last().text, format!("Hello {turn}"));
        assert!(harness.last().is_streaming);
        assert_eq!(harness.snapshot().header.status, TurnStatus::Running);
        harness.send(lines[4].clone());
        assert_eq!(harness.last().text, format!("Hello {turn} world"));
        harness.send_all(&lines[5..]);
        assert_eq!(harness.snapshot().rows.len(), turn);
        assert_eq!(harness.last().id, format!("saved{turn}"));
    }
}

#[test]
fn wrapper_completion_does_not_seal_native_text_already_streaming() {
    let mut harness = Harness::new(SESSION);
    let lines = reducer_events("WrapperCompletionDoesNotSealNativeTextAlreadyStreaming");
    harness.send_all(&lines[..3]);
    assert!(harness.last().is_streaming);
    assert_eq!(harness.snapshot().header.status, TurnStatus::Running);
    harness.send(lines[3].clone());
    assert_eq!(harness.last().text, "Hello world");
    harness.send(lines[4].clone());
    assert_eq!(harness.ids(), ["saved"]);
}

#[test]
fn native_interruption_rejects_late_text_but_next_turn_still_streams() {
    let mut harness = Harness::new(SESSION);
    let lines = reducer_events("NativeInterruptionRejectsLateTextButNextTurnStillStreams");
    harness.send_all(&lines[..4]);
    assert_eq!(harness.last().text, "Partial");
    assert!(harness.last().interrupted);
    assert!(!harness.last().is_streaming);
    harness.send_all(&lines[4..]);
    assert_eq!(harness.texts(), ["Partial", "Next reply"]);
    assert!(harness.last().is_streaming);
}

#[test]
fn ordinary_response_deltas_remain_blocked_after_completion() {
    let mut harness = Harness::new(SESSION);
    let lines = reducer_events("OrdinaryResponseDeltasRemainBlockedAfterCompletion");
    harness.send_all(&lines[..3]);
    let before = harness.snapshot().clone();
    let outcome = harness.send(lines[3].clone());
    assert!(outcome.changes.is_empty());
    assert_eq!(*harness.snapshot(), before);
}

fn demo_settings() -> SessionSettings {
    let option = |value| serde_json::from_value::<NativeModelOption>(value).expect("option");
    SessionSettings {
        agent_id: Some("demo-codex".to_owned()),
        harness: Some("codex-native".to_owned()),
        wrapper: Some("codex-native-ui".to_owned()),
        model_override: ReportedValue::Value {
            value: "sample-balanced".to_owned(),
        },
        reasoning_effort: ReportedValue::HarnessDefault,
        model_options: vec![
            option(
                json!({"id": "sample-balanced", "displayName": "Sample Balanced", "isDefault": true}),
            ),
            option(json!({"id": "sample-fast", "displayName": "Sample Fast"})),
        ],
        host_id: Some("demo-host".to_owned()),
        host_online: Some(true),
        runner_online: Some(true),
        ..SessionSettings::default()
    }
}

fn settings(harness: &Harness) -> SessionSettings {
    harness
        .snapshot()
        .header
        .settings
        .clone()
        .expect("settings")
}

#[test]
fn configuration_events_retain_unknown_values_and_distinguish_null_from_missing() {
    let mut snapshot = conversation(SESSION, Vec::new());
    snapshot.header.settings = Some(demo_settings());
    let mut harness = Harness::from_snapshot(snapshot);
    let original = settings(&harness);
    let lines =
        reducer_events("ConfigurationEventsRetainUnknownValuesAndDistinguishNullFromMissing");
    // A missing model, a numeric effort (a decode error) and another conversation change nothing.
    for line in &lines[..3] {
        match harness.try_send(line.clone()) {
            Ok(outcome) => assert!(!outcome.effects.changed, "{line}"),
            Err(ReducerError::Decode(_)) => {}
            Err(error) => panic!("{line}: {error}"),
        }
        assert_eq!(settings(&harness), original, "{line}");
    }
    assert!(harness.try_send(lines[1].clone()).is_err());
    let changed = harness.send(lines[3].clone());
    assert!(changed.effects.changed && changed.effects.reconcile);
    assert_eq!(model_label(&settings(&harness)), "unknown-raw-model");
    harness.send(lines[4].clone());
    assert_eq!(effort_label(&settings(&harness)), "High");
    harness.send(lines[5].clone());
    assert_eq!(effort_label(&settings(&harness)), "Harness default");
    harness.send(lines[6].clone());
    assert_eq!(model_label(&settings(&harness)), "Harness default");
}

#[test]
fn persisted_error_item_retains_cause_when_replayed_and_does_not_duplicate() {
    let mut harness = Harness::new(SESSION);
    harness.send_all(&reducer_events(
        "PersistedErrorItemRetainsCauseWhenReplayedAndDoesNotDuplicate",
    ));
    assert_eq!(harness.ids(), ["error_1"]);
    let row = harness.last();
    assert_eq!(row.role, RowRole::Tool);
    assert_eq!(
        row.text,
        "Error (runner_failed_to_start): Runner unavailable. See the host logs."
    );
    assert!(!row.is_streaming);
}

#[test]
fn native_deltas_deduplicate_index_and_commit_retires_preview() {
    let mut harness = Harness::new(SESSION);
    let lines = reducer_events("NativeDeltasDeduplicateIndexAndCommitRetiresPreview");
    harness.send_all(&lines[..3]);
    assert_eq!(harness.texts(), ["Hello"]);
    assert!(harness.last().is_streaming);
    harness.send(lines[3].clone());
    assert_eq!(harness.ids(), ["persisted1"]);
    assert!(!harness.last().is_streaming);
    harness.send(lines[4].clone());
    assert_eq!(harness.snapshot().rows.len(), 1);
}

#[test]
fn duplicate_committed_item_cannot_discard_newer_preview() {
    let mut harness = Harness::with_rows(SESSION, vec![assistant("old", "Old reply")]);
    let lines = reducer_events("DuplicateCommittedItemCannotDiscardNewerPreview");
    harness.send_all(&lines[..2]);
    assert_eq!(harness.ids(), ["old", "live:new"]);
    assert_eq!(harness.last().text, "New streaming reply");
    harness.send(lines[2].clone());
    assert_eq!(harness.last().text, "New streaming reply continues");
}

#[test]
fn ordinary_delta_segments_become_persisted_items_without_duplicates() {
    let mut harness = Harness::new(SESSION);
    harness.send_all(&reducer_events(
        "OrdinaryDeltaSegmentsBecomePersistedItemsWithoutDuplicates",
    ));
    assert_eq!(harness.ids(), ["item1", "item2"]);
    assert_eq!(harness.texts(), ["First", "Second"]);
}

#[test]
fn consumed_input_keeps_stable_id_and_pending_correlation() {
    let mut harness = Harness::new(SESSION);
    let lines = reducer_events("ConsumedInputKeepsStableIDAndPendingCorrelation");
    let first = harness.send(lines[0].clone());
    harness.send(lines[1].clone());
    assert_eq!(harness.ids(), ["user1"]);
    assert_eq!(first.effects.consumed_item_id.as_deref(), Some("user1"));
    assert_eq!(
        first.effects.consumed_pending_id.as_deref(),
        Some("pending1")
    );
}

#[test]
fn hidden_context_never_appears_from_stream() {
    let mut harness = Harness::new(SESSION);
    harness.send_all(&reducer_events("HiddenContextNeverAppearsFromStream"));
    assert_eq!(harness.snapshot().rows, []);
}

#[test]
fn provider_failure_ends_spinner_and_retains_readable_error() {
    let mut harness = Harness::new(SESSION);
    let lines = reducer_events("ProviderFailureEndsSpinnerAndRetainsReadableError");
    harness.send_all(&lines[..2]);
    let outcome = harness.send(lines[2].clone());
    assert_eq!(harness.snapshot().header.status, TurnStatus::Idle);
    assert_eq!(outcome.effects.error.as_deref(), Some("Sign in again"));
    assert_eq!(
        harness.snapshot().header.failure_message.as_deref(),
        Some("Sign in again")
    );
    assert!(outcome.effects.reconcile);
    assert!(!harness.snapshot().rows[0].is_streaming);
}

#[test]
fn stale_response_completion_cannot_stop_newer_reply() {
    let mut harness = Harness::new(SESSION);
    let lines = reducer_events("StaleResponseCompletionCannotStopNewerReply");
    harness.send(lines[0].clone());
    let outcome = harness.send(lines[1].clone());
    assert!(!outcome.effects.changed);
    assert!(!outcome.effects.reconcile);
    assert_eq!(harness.snapshot().header.status, TurnStatus::Running);
}

#[test]
fn catalog_and_harness_events_request_authoritative_reconciliation() {
    let mut snapshot = conversation(SESSION, Vec::new());
    snapshot.header.settings = Some(demo_settings());
    let mut harness = Harness::from_snapshot(snapshot);
    for line in [
        json!({"type": "session.model_options"}),
        json!({"type": "session.agent_changed", "agent_id": "new-clone", "agent_name": "New clone"}),
    ] {
        let outcome = harness.send(line);
        assert!(outcome.effects.reconcile);
        assert!(!outcome.effects.changed);
    }
    let mut authoritative = harness.snapshot().clone();
    let mut next = demo_settings();
    next.agent_id = Some("new-clone".to_owned());
    next.harness = Some("future-harness".to_owned());
    next.model_options = Vec::new();
    authoritative.header.settings = Some(next.clone());
    let changes = harness.reconcile(authoritative);
    assert_eq!(harness.snapshot().header.settings, Some(next));
    assert!(changes.header.is_some());
}

#[test]
fn in_place_hydration_preserves_prefix_and_native_chunk_deduplication() {
    let mut harness = Harness::new(SESSION);
    let lines = reducer_events("InPlaceHydrationPreservesPrefixAndNativeChunkDeduplication");
    harness.send(lines[0].clone());
    let mut metadata = conversation(SESSION, Vec::new());
    metadata.header.title = "Renamed while streaming".to_owned();
    harness.reconcile(metadata);
    assert_eq!(harness.snapshot().header.title, "Renamed while streaming");
    assert_eq!(harness.texts(), ["Hello"]);
    harness.send_all(&lines[1..]);
    assert_eq!(harness.texts(), ["Hello world"]);
}

#[test]
fn older_history_prefix_cannot_retire_newer_streaming_text() {
    let mut harness = Harness::new(SESSION);
    let lines = reducer_events("OlderHistoryPrefixCannotRetireNewerStreamingText");
    harness.send(lines[0].clone());
    harness.reconcile(conversation(SESSION, vec![assistant("saved", "Hello")]));
    assert_eq!(harness.texts(), ["Hello world"]);
    assert!(harness.last().is_streaming);
    harness.send(lines[1].clone());
    assert_eq!(harness.texts(), ["Hello world again"]);
    harness.send(lines[2].clone());
    assert_eq!(harness.ids(), ["saved"]);
    assert!(!harness.last().is_streaming);
}

#[test]
fn in_place_hydration_preserves_ordinary_response_prefix_and_preview_position() {
    let question = user("user", "Question");
    let mut harness = Harness::with_rows(SESSION, vec![question.clone()]);
    let lines = reducer_events("InPlaceHydrationPreservesOrdinaryResponsePrefixAndPreviewPosition");
    harness.send_all(&lines[..3]);
    let tool = harness.last().clone();
    assert_eq!(tool.activity_kind(), Some(ActivityKind::ToolCall));
    harness.reconcile(conversation(SESSION, vec![question, tool]));
    harness.send(lines[3].clone());
    assert_eq!(harness.ids(), ["user", "live:response:response1:0", "tool"]);
    assert_eq!(harness.snapshot().rows[1].text, "Hello world");
}

#[test]
fn hydration_commit_retires_matching_preview_before_buffered_final_item() {
    let mut harness = Harness::new(SESSION);
    let lines = reducer_events("HydrationCommitRetiresMatchingPreviewBeforeBufferedFinalItem");
    harness.send(lines[0].clone());
    let committed = assistant("persisted", "Hello world");
    harness.reconcile(conversation(SESSION, vec![committed.clone()]));
    harness.send_all(&lines[1..]);
    assert_eq!(harness.snapshot().rows, vec![committed]);
}

#[test]
fn real_reconnect_uses_fresh_reducer_so_inflight_replay_does_not_double_prefix() {
    let mut stale = Harness::new(SESSION);
    stale.send_all(&reducer_events(
        "RealReconnectUsesFreshReducerSoInflightReplayDoesNotDoublePrefix--stale-reducer",
    ));
    assert_eq!(stale.texts(), ["stale prefix"]);
    let mut reconnected = Harness::new(SESSION);
    reconnected.send_all(&reducer_events(
        "RealReconnectUsesFreshReducerSoInflightReplayDoesNotDoublePrefix--reconnected",
    ));
    assert_eq!(reconnected.texts(), ["authoritative prefix tail"]);
}

#[test]
fn rehydration_discards_old_previews_and_pending_decisions() {
    let mut old = Harness::new(SESSION);
    old.send_all(&reducer_events(
        "RehydrationDiscardsOldPreviewsAndPendingDecisions",
    ));
    assert_eq!(old.pending_ids(), ["ask1"]);
    let fresh = Harness::from_snapshot(conversation(
        SESSION,
        vec![assistant("committed", "Completed")],
    ));
    assert_eq!(fresh.ids(), ["committed"]);
    assert_eq!(fresh.pending_ids(), Vec::<&str>::new());
}
