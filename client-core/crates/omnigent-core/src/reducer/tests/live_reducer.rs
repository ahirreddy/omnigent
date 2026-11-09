//! Port of `NativeLab` `LiveConversationReducerTests.swift` (the WP3 rows).

use omnigent_protocol::sessions::NativeModelOption;
use omnigent_protocol::{ConversationItem, FromWire, ServerStreamEvent};
use serde_json::json;

use super::{Harness, assistant, conversation, events, user};
use crate::reducer::live::{event_response_id, matches_text};
use crate::reducer::{
    ActivityKind, ReducerError, ReportedValue, RowRole, SessionSettings, TurnStatus, effort_label,
    model_label, project_item,
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

#[test]
fn hollow_events_change_nothing() {
    let hollow = [
        json!({"type": "session.sandbox_status", "stage": "brand_new_stage"}),
        json!({"type": "session.superseded", "target_conversation_id": ""}),
        json!({"type": "session.changed_files.invalidated", "environment_id": ""}),
        json!({"type": "session.resource.created", "resource": {"type": "terminal"}}),
        json!({"type": "session.created", "child_session_id": ""}),
        json!({"type": "session.child_session.updated", "child_session_id": "", "child": {}}),
        json!({"type": "response.output_file.done", "file_id": ""}),
        json!({"type": "response.client_task.cancel", "task_id": ""}),
    ];
    let mut harness = Harness::new(SESSION);
    let before = harness.snapshot().clone();
    for event in hollow {
        let outcome = harness.send(event.clone());
        assert!(outcome.changes.is_empty(), "{event}");
    }
    assert_eq!(*harness.snapshot(), before);
}

#[test]
fn a_title_event_renames_the_session() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "session.title", "conversation_id": SESSION, "title": "New"}));
    assert_eq!(harness.snapshot().header.title, "New");
    let other =
        harness.send(json!({"type": "session.title", "conversation_id": "other", "title": "x"}));
    assert!(other.changes.is_empty());
    assert_eq!(harness.snapshot().header.title, "New");
}

#[test]
fn events_for_another_session_or_turn_are_ignored_through_the_typed_entry_point() {
    use omnigent_protocol::{FromWire, ServerStreamEvent};
    let mut harness = Harness::new(SESSION);
    for event in [
        json!({"type": "turn.started", "session_id": "other"}),
        json!({"type": "turn.completed", "session_id": "other"}),
        json!({"type": "turn.cancelled", "session_id": "other"}),
        json!({"type": "turn.failed", "session_id": "other"}),
        json!({"type": "session.title", "conversation_id": "other", "title": "x"}),
        json!({"type": "session.btw_sidechat", "conversation_id": "other", "question": "q", "answer": "a"}),
        json!({"type": "future.event", "conversation_id": "other"}),
        json!({"type": "future.event", "session_id": "other"}),
    ] {
        let typed = ServerStreamEvent::from_value(event.clone()).unwrap();
        let outcome = harness.reducer.apply(&typed).unwrap();
        assert!(outcome.changes.is_empty(), "{event}");
    }
}

#[test]
fn a_side_question_shows_its_answer_and_says_when_it_was_cut() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({
        "type": "session.btw_sidechat", "question": "why?", "answer": "because", "truncated": true,
    }));
    let row = harness.last();
    let activity = row.activity.as_ref().unwrap();
    assert_eq!(activity.kind, ActivityKind::Sidechat);
    assert_eq!(
        activity.detail("answer"),
        Some("because\n[Answer truncated]")
    );
    assert_eq!(activity.detail("question"), Some("why?"));
    harness.send(json!({
        "type": "session.btw_sidechat", "question": "why?", "answer": "again", "truncated": false,
    }));
    assert_eq!(
        harness.snapshot().rows.len(),
        1,
        "the same question updates its row"
    );
}

#[test]
fn unknown_events_keep_a_bounded_number_of_rows() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "future.event", "id": "event0"}));
    let oldest = harness.last().id.clone();
    for index in 1..90 {
        harness.send(json!({"type": "future.event", "id": format!("event{index}")}));
    }
    assert_eq!(harness.snapshot().rows.len(), 80);
    assert!(harness.snapshot().rows.iter().all(|row| row.id != oldest));
}

#[test]
fn an_unknown_event_whose_item_is_already_saved_adds_no_row() {
    let mut harness = Harness::with_rows(SESSION, vec![assistant("saved", "hello")]);
    let outcome = harness.send(json!({"type": "future.event", "item_id": "saved"}));
    assert!(outcome.changes.is_empty());
    assert_eq!(harness.ids(), ["saved"]);
}

#[test]
fn a_retry_with_a_nonsense_delay_or_no_error_text_still_reads_sensibly() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({
        "type": "response.retry",
        "source": "llm",
        "attempt": 2,
        "max_attempts": 5,
        "delay_seconds": -3.5,
        "error": {"code": "", "message": "", "detail": {"hint": "slow down"}},
    }));
    let activity = harness.last().activity.clone().unwrap();
    assert_eq!(activity.summary, "Attempt 2 of 5 · retry in 0.0 seconds");
    assert_eq!(activity.title, "Retrying response");
}

#[test]
fn an_empty_policy_denial_has_a_default_explanation() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "response.policy_denied", "reason": ""}));
    assert_eq!(
        harness.last().activity.as_ref().unwrap().summary,
        "The server declined this action."
    );
}

#[test]
fn a_late_tool_output_cannot_resurrect_a_saved_result() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "response.in_progress", "response_id": "r1"}));
    harness.send(json!({
        "type": "response.output_item.done",
        "response_id": "r1",
        "item": {
            "id": "out1", "type": "function_call_output", "call_id": "c1", "output": "done",
            "response_id": "r1",
        },
    }));
    let saved = harness.ids().len();
    let outcome = harness.send(json!({
        "type": "response.function_call_output.delta", "call_id": "c1", "delta": "late",
    }));
    assert!(outcome.changes.is_empty());
    assert_eq!(harness.ids().len(), saved);
}

#[test]
fn replayed_chunks_are_dropped_by_index() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "response.in_progress", "response_id": "r1"}));
    harness.send(json!({
        "type": "response.output_text.delta", "delta": "one", "index": 3, "response_id": "r1",
    }));
    let replay = harness.send(json!({
        "type": "response.output_text.delta", "delta": "one", "index": 3, "response_id": "r1",
    }));
    assert!(replay.changes.is_empty());
    assert_eq!(harness.last().text, "one");
    harness.send(
        json!({"type": "response.reasoning_text.delta", "delta": "hm", "index": 1, "item_id": "x"}),
    );
    let reasoning = harness.send(json!({
        "type": "response.reasoning_text.delta", "delta": "hm", "index": 1, "item_id": "x",
    }));
    assert!(reasoning.changes.is_empty());
}

#[test]
fn a_final_delta_without_a_message_id_starts_a_new_text_section() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "response.in_progress", "response_id": "r1"}));
    harness.send(json!({
        "type": "response.output_text.delta", "delta": "first", "final": true,
    }));
    assert!(!harness.last().is_streaming);
    harness.send(json!({"type": "response.output_text.delta", "delta": "second"}));
    assert_eq!(harness.snapshot().rows.len(), 2);
    assert_eq!(harness.last().text, "second");
    assert!(harness.last().is_streaming);
}

#[test]
fn a_queued_response_does_not_interrupt_the_running_one() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "response.in_progress", "response_id": "r1"}));
    harness.send(json!({"type": "response.output_text.delta", "delta": "text"}));
    let queued = harness.send(json!({"type": "response.queued", "response_id": "r2"}));
    assert!(queued.changes.is_empty());
    assert_eq!(harness.reducer.response_id(), Some("r1"));
    harness.send(json!({"type": "response.in_progress", "response_id": "r2"}));
    assert_eq!(harness.reducer.response_id(), Some("r2"));
    assert!(!harness.last().is_streaming, "the old response's row ended");
}

#[test]
fn a_response_with_no_id_adopts_text_that_arrived_before_its_id() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "response.in_progress"}));
    harness.send(json!({"type": "response.output_text.delta", "delta": "early"}));
    assert_eq!(harness.last().response_id, None);
    harness.send(json!({"type": "response.in_progress", "response_id": "r1"}));
    assert_eq!(harness.last().response_id.as_deref(), Some("r1"));
}

#[test]
fn a_reasoning_row_closes_when_text_arrives_and_sections_separate() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "response.in_progress", "response_id": "r1"}));
    harness.send(json!({"type": "response.reasoning.started", "item_id": "x"}));
    harness.send(json!({"type": "response.reasoning_summary_text.delta", "delta": "thinking", "item_id": "x"}));
    harness.send(json!({"type": "response.reasoning.started", "item_id": "x"}));
    let reasoning = harness.last().clone();
    assert_eq!(
        reasoning.activity.as_ref().unwrap().detail("summary"),
        Some("thinking\n\n")
    );
    harness.send(json!({"type": "response.output_text.delta", "delta": "answer"}));
    let closed = harness
        .snapshot()
        .rows
        .iter()
        .find(|row| row.id == reasoning.id)
        .unwrap();
    assert!(!closed.is_streaming);
    assert_eq!(
        closed.activity.as_ref().unwrap().status.as_deref(),
        Some("completed")
    );
}

#[test]
fn a_new_response_reported_by_status_ends_the_previous_one() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "response.in_progress", "response_id": "r1"}));
    harness.send(json!({"type": "response.output_text.delta", "delta": "text"}));
    harness.send(json!({"type": "session.status", "status": "running", "response_id": "r2"}));
    assert_eq!(harness.reducer.response_id(), Some("r2"));
    assert!(!harness.last().is_streaming);
    let stale = harness
        .send(json!({"type": "response.output_text.delta", "delta": "late", "response_id": "r1"}));
    assert!(
        stale.changes.is_empty(),
        "the ended response cannot speak again"
    );
}

#[test]
fn a_pending_decision_wins_over_running_and_idle_statuses() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({
        "type": "response.elicitation_request", "elicitation_id": "ask1",
        "params": {"message": "Approve?"},
    }));
    assert_eq!(harness.snapshot().header.status, TurnStatus::NeedsResponse);
    harness.send(json!({"type": "response.output_text.delta", "delta": "text"}));
    assert_eq!(harness.snapshot().header.status, TurnStatus::NeedsResponse);
    harness.send(json!({"type": "session.status", "status": "idle"}));
    assert_eq!(harness.snapshot().header.status, TurnStatus::NeedsResponse);
    harness.send(json!({"type": "response.completed", "response_id": "r9"}));
    assert_eq!(harness.snapshot().header.status, TurnStatus::NeedsResponse);
    harness.send(json!({"type": "response.elicitation_resolved", "elicitation_id": "ask1"}));
    assert_ne!(harness.snapshot().header.status, TurnStatus::NeedsResponse);
}

#[test]
fn a_second_interrupt_marker_changes_nothing() {
    let mut harness = Harness::with_rows(SESSION, vec![assistant("reply", "cut off")]);
    let marker = |id: &str| {
        json!({
            "type": "response.output_item.done",
            "item": {"id": id, "type": "message", "role": "user",
                     "content": [{"type": "input_text", "text": "[System: interrupted]"}]},
        })
    };
    harness.send(marker("m1"));
    assert!(harness.last().interrupted);
    let again = harness.send(marker("m2"));
    assert!(again.changes.is_empty());
}

#[test]
fn stream_events_apply_through_their_data() {
    let mut harness = Harness::new(SESSION);
    let event = crate::reducer::StreamEvent {
        event_type: "session.title".to_owned(),
        data: json!({"type": "session.title", "title": "From the stream"})
            .as_object()
            .unwrap()
            .clone(),
    };
    harness.reducer.apply_stream_event(&event).unwrap();
    assert_eq!(harness.snapshot().header.title, "From the stream");
}

#[test]
fn malformed_payloads_are_decode_errors_and_change_nothing() {
    let mut harness = Harness::new(SESSION);
    for payload in [
        json!(7),
        json!([]),
        json!({}),
        json!({"type": ""}),
        json!({"type": 7}),
    ] {
        assert!(
            matches!(
                harness.try_send(payload.clone()),
                Err(ReducerError::Decode(_))
            ),
            "{payload}"
        );
    }
}

#[test]
fn legacy_lifecycle_names_map_to_the_canonical_ones() {
    use crate::reducer::canonical_event_type;
    assert_eq!(
        canonical_event_type("response.started"),
        "response.in_progress"
    );
    assert_eq!(
        canonical_event_type("response.TaskStatus.COMPLETED"),
        "response.completed"
    );
    assert_eq!(canonical_event_type("x.TaskStatus."), "response.");
    assert_eq!(canonical_event_type("session.title"), "session.title");
}

#[test]
fn an_item_without_a_role_or_response_gets_them_from_its_event() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({
        "type": "response.output_item.done",
        "response_id": "r1",
        "item": {"id": "m1", "type": "message", "content": [{"type": "output_text", "text": "hi"}]},
    }));
    assert_eq!(harness.last().role, RowRole::Assistant);
    assert_eq!(harness.last().response_id.as_deref(), Some("r1"));
    harness.send(json!({
        "type": "response.output_item.done",
        "item": {"id": "m2", "type": "message",
                 "data": {"content": [{"type": "output_text", "text": "nested"}]}},
    }));
    assert_eq!(harness.last().role, RowRole::Assistant);
    assert!(matches!(
        harness.try_send(json!({"type": "response.output_item.done", "item": 7})),
        Err(ReducerError::Decode(_))
    ));
}

#[test]
fn an_error_event_detail_stays_with_its_row() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({
        "type": "response.retry", "source": "tool", "tool_name": "grep", "attempt": 1,
        "max_attempts": 2, "delay_seconds": 1.5,
        "error": {"code": "E", "message": "boom", "detail": {"hint": "slow"}},
    }));
    assert_eq!(
        harness.last().activity.as_ref().unwrap().title,
        "Retrying grep"
    );
    assert!(
        harness
            .last()
            .activity
            .as_ref()
            .unwrap()
            .details
            .iter()
            .any(|detail| detail.text.contains("slow"))
    );
}

#[test]
fn model_and_effort_labels_cover_routing_options_and_silence() {
    let routed = SessionSettings {
        routing_mode: Some("on".to_owned()),
        ..SessionSettings::default()
    };
    assert_eq!(model_label(&routed), "Smart routing");
    assert_eq!(
        model_label(&SessionSettings::default()),
        "Model not reported"
    );
    assert_eq!(effort_label(&SessionSettings::default()), "Not reported");
    let option = |id: &str, display_name: Option<&str>, model: Option<&str>| {
        serde_json::from_value::<NativeModelOption>(json!({
            "id": id, "displayName": display_name, "model": model
        }))
        .unwrap()
    };
    let named = |value: &str, options: Vec<NativeModelOption>| SessionSettings {
        model_override: ReportedValue::Value {
            value: value.to_owned(),
        },
        model_options: options,
        ..SessionSettings::default()
    };
    assert_eq!(
        model_label(&named("a", vec![option("a", Some("Fancy"), None)])),
        "Fancy"
    );
    assert_eq!(
        model_label(&named("a", vec![option("a", None, Some("model-a"))])),
        "model-a"
    );
    assert_eq!(model_label(&named("a", vec![option("a", None, None)])), "a");
    assert_eq!(ReportedValue::reported(None), ReportedValue::HarnessDefault);
    assert_eq!(
        ReportedValue::reported(Some("x".to_owned())),
        ReportedValue::Value {
            value: "x".to_owned()
        }
    );
}

#[test]
fn every_row_vocabulary_has_a_stable_name() {
    assert_eq!(ActivityKind::Error.as_str(), "error");
    assert_eq!(ActivityKind::Unknown.as_str(), "unknown");
    assert_eq!(ActivityKind::Retry.as_str(), "retry");
    assert_eq!(ActivityKind::File.as_str(), "file");
    assert_eq!(ActivityKind::Policy.as_str(), "policy");
    assert_eq!(ActivityKind::ClientTask.as_str(), "clientTask");
    assert_eq!(ActivityKind::Browser.as_str(), "browser");
    assert_eq!(ActivityKind::Sidechat.as_str(), "sidechat");
    assert_eq!(TurnStatus::Running.as_str(), "running");
    assert_eq!(TurnStatus::NeedsResponse.as_str(), "needsResponse");
}

#[test]
fn a_snapshot_finds_a_row_by_id() {
    let harness = Harness::with_rows(SESSION, vec![assistant("m1", "hello")]);
    let snapshot = harness.snapshot();
    assert_eq!(
        snapshot.row("m1").map(|row| row.text.as_str()),
        Some("hello")
    );
    assert_eq!(snapshot.row("missing"), None);
}

#[test]
fn state_sections_cover_todos_servers_resources_and_failed_changes() {
    use std::collections::BTreeMap;

    use omnigent_protocol::events::{Todo, TodoStatus};

    use crate::reducer::{ChangedFiles, SessionEventState, sections};

    let resource = |value: serde_json::Value| value.as_object().unwrap().clone();
    let state = SessionEventState {
        background_task_count: Some(3),
        background_tasks: Some(Vec::new()),
        todos: Some(vec![
            Todo {
                content: "Write".to_owned(),
                status: TodoStatus::Pending,
                active_form: None,
            },
            Todo {
                content: "Ship".to_owned(),
                status: TodoStatus::InProgress,
                active_form: None,
            },
        ]),
        mcp_startup: Some(BTreeMap::from([(
            "docs".to_owned(),
            serde_json::from_value(json!({"status": "failed", "error": "no route"})).unwrap(),
        )])),
        resources: Some(BTreeMap::from([(
            "r1".to_owned(),
            resource(json!({"type": "file", "metadata": {"cwd": "/x", "other": 1}})),
        )])),
        changed_files: Some(BTreeMap::from([(
            "default".to_owned(),
            ChangedFiles::Failed {
                message: "Changed files unavailable".to_owned(),
            },
        )])),
        ..SessionEventState::default()
    };
    let shown = sections(&state);
    let text = format!("{shown:?}");
    assert!(text.contains("Ship"), "{text}");
    assert!(text.contains("no route"), "{text}");
    assert!(text.contains("details unavailable"), "{text}");
    assert!(text.contains("Changed files unavailable"), "{text}");
    assert!(text.contains("/x"), "{text}");
}

#[test]
fn a_repeated_status_and_an_empty_first_delta_add_nothing() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "response.in_progress", "response_id": "r1"}));
    harness.send(json!({"type": "response.output_text.delta", "response_id": "r1", "delta": ""}));
    assert_eq!(harness.ids(), Vec::<String>::new());
    harness.send(json!({"type": "response.output_text.delta", "response_id": "r1", "delta": "hi"}));
    harness.send(json!({"type": "response.in_progress", "response_id": "r1"}));
    assert_eq!(harness.last().text, "hi");
    assert!(harness.last().is_streaming, "the same response keeps going");
}

#[test]
fn resolving_one_of_two_decisions_keeps_the_other_waiting() {
    let mut harness = Harness::new(SESSION);
    let request = |id: &str| {
        json!({"type": "response.elicitation_request", "elicitation_id": id,
            "params": {"message": "May I?"}})
    };
    harness.send(request("e1"));
    harness.send(request("e2"));
    assert_eq!(harness.snapshot().decisions.len(), 2);
    harness.send(json!({"type": "response.elicitation_resolved", "elicitation_id": "e1"}));
    assert_eq!(harness.snapshot().decisions.len(), 1);
    assert_eq!(harness.snapshot().header.status, TurnStatus::NeedsResponse);
}

#[test]
fn a_compaction_preview_is_retired_unless_it_failed() {
    let compaction = json!({"type": "response.output_item.done", "item": {
        "id": "c1", "type": "compaction", "summary": "Shorter"}});
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "response.compaction.in_progress"}));
    assert_eq!(harness.ids().len(), 1);
    harness.send(compaction.clone());
    assert_eq!(harness.ids(), ["c1"]);

    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "response.compaction.failed"}));
    harness.send(compaction);
    assert_eq!(harness.ids().len(), 2, "the failure stays on screen");
}

#[test]
fn previews_match_only_commits_of_their_own_kind_and_response() {
    let mut harness = Harness::new(SESSION);
    harness.send(
        json!({"type": "response.retry", "source": "llm", "attempt": 1, "max_attempts": 3,
        "delay_seconds": 1.0, "error": {"code": "x", "message": "y"}}),
    );
    let preview = harness.last().clone();
    let mut committed = preview.clone();
    committed.id = "committed".to_owned();
    assert!(
        !harness.reducer.matches_activity(&preview, &committed),
        "retries are never persisted as the same row"
    );

    let reasoning = |id: &str, summary: &str, response: &str| {
        let item = ConversationItem::from_value(json!({
            "id": id, "type": "reasoning", "response_id": response,
            "summary": [{"type": "summary_text", "text": summary}]
        }))
        .unwrap();
        project_item(&item).unwrap().unwrap()
    };
    harness.send(json!({"type": "response.in_progress", "response_id": "r1"}));
    harness
        .send(json!({"type": "response.reasoning_summary_text.delta", "delta": "thinking long"}));
    let preview = harness.last().clone();
    let same_response = preview.response_id.clone().unwrap();
    assert!(
        harness
            .reducer
            .matches_activity(&preview, &reasoning("r", "thinking", &same_response))
    );
    assert!(
        !harness
            .reducer
            .matches_activity(&preview, &reasoning("r", "thinking long", "another"))
    );

    let mut text_preview = assistant("live:m", "Hello");
    text_preview.response_id = Some("r1".to_owned());
    let mut committed = assistant("other", "Hello there");
    committed.response_id = Some("r2".to_owned());
    assert!(!matches_text(&text_preview, &committed));
    committed.response_id = Some("r1".to_owned());
    assert!(matches_text(&text_preview, &committed));
    committed.text = String::new();
    assert!(
        !matches_text(&text_preview, &committed),
        "nothing to compare"
    );
}

#[test]
fn every_lifecycle_event_names_its_response() {
    for (kind, fields) in [
        ("response.created", json!({"response": {"id": "r1"}})),
        ("response.queued", json!({"response": {"id": "r1"}})),
        ("response.in_progress", json!({"response": {"id": "r1"}})),
        ("session.interrupted", json!({"response_id": "r1"})),
    ] {
        let mut value = fields;
        value["type"] = json!(kind);
        let event = ServerStreamEvent::from_value(value).unwrap();
        assert_eq!(event_response_id(&event), Some("r1"), "{kind}");
    }
}

#[test]
fn records_ignore_an_empty_id_and_stay_bounded() {
    use std::collections::BTreeMap;

    use crate::reducer::MAX_RECORDS;
    use crate::reducer::state::update_record;

    let mut records: Option<BTreeMap<String, u32>> = None;
    update_record(&mut records, "", Some(1));
    assert_eq!(records, None);
    for index in 0..=MAX_RECORDS {
        update_record(&mut records, &format!("{index:08}"), Some(1));
    }
    let records = records.unwrap();
    assert_eq!(records.len(), MAX_RECORDS);
    assert!(
        !records.contains_key("00000000"),
        "the first key was dropped"
    );
}

#[test]
fn every_attachment_kind_has_a_stable_name() {
    use crate::reducer::AttachmentKind;
    assert_eq!(AttachmentKind::File.as_str(), "file");
    assert_eq!(AttachmentKind::Image.as_str(), "image");
}

#[test]
fn sections_list_fully_described_tasks_and_bare_resources() {
    let mut state = crate::reducer::SessionEventState {
        background_task_count: Some(1),
        background_tasks: serde_json::from_value(
            json!([{"id": "t1", "description": "Watch", "command": "tail -f log"}]),
        )
        .unwrap(),
        resources: serde_json::from_value(json!({"r1": {"type": "terminal", "name": "Shell"}}))
            .unwrap(),
        ..crate::reducer::SessionEventState::default()
    };
    let sections = crate::reducer::sections(&state);
    let tasks = sections
        .iter()
        .find(|section| section.id == "background-tasks")
        .unwrap();
    assert_eq!(tasks.details.len(), 1);
    assert!(format!("{sections:?}").contains("Shell"));
    state.resources = None;
    assert_eq!(crate::reducer::sections(&state).len(), 1);
}

#[test]
fn a_consumed_input_that_does_not_decode_is_an_error_and_changes_nothing() {
    let mut harness = Harness::new(SESSION);
    let outcome = harness.try_send(json!({
        "type": "session.input.consumed",
        "data": {"item_id": "i1", "type": "function_call", "data": {"name": 7}},
    }));
    assert!(
        matches!(outcome, Err(ReducerError::Decode(_))),
        "{outcome:?}"
    );
}

#[test]
fn replacing_a_row_past_the_end_changes_nothing() {
    let mut harness = Harness::with_rows(SESSION, vec![user("u1", "hi")]);
    let before = harness.snapshot().rows.clone();
    harness.reducer.replace_row(5, assistant("a1", "late"));
    assert_eq!(harness.snapshot().rows, before);
}

#[test]
fn closing_a_reasoning_section_whose_row_is_gone_still_ends_the_section() {
    let mut harness = Harness::new(SESSION);
    harness.reducer.active_reasoning = Some("gone".to_owned());
    harness.reducer.close_reasoning_section();
    assert_eq!(harness.reducer.active_reasoning, None);
}

#[test]
fn a_retry_with_nothing_to_show_says_no_details_were_reported() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({
        "type": "response.retry",
        "source": "llm",
        "attempt": 1,
        "max_attempts": 2,
        "delay_seconds": 1.0,
        "error": {"code": "", "message": ""},
    }));
    let activity = harness.last().activity.clone().unwrap();
    assert!(
        activity
            .details
            .iter()
            .any(|detail| detail.text == "No details reported"),
        "{activity:?}"
    );
}

#[test]
fn a_retry_with_only_a_message_shows_no_blank_code() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({
        "type": "response.retry",
        "source": "llm",
        "attempt": 1,
        "max_attempts": 2,
        "delay_seconds": 1.0,
        "error": {"code": "  ", "message": "Overloaded"},
    }));
    let activity = harness.last().activity.clone().unwrap();
    assert_eq!(activity.details[0].text, "message: Overloaded");
}

#[test]
fn a_preview_with_no_earlier_row_is_not_put_back() {
    let mut harness = Harness::new(SESSION);
    let orphan = assistant("orphan", "streaming");
    harness
        .reducer
        .reinsert_previews(&[], vec![orphan], &std::collections::BTreeMap::new());
    assert_eq!(harness.snapshot().rows, []);
}

#[test]
fn a_committed_message_with_an_unknown_role_is_an_error_and_changes_nothing() {
    let mut harness = Harness::new(SESSION);
    let outcome = harness.try_send(json!({
        "type": "response.output_item.done",
        "item": {"id": "m1", "type": "message", "data": {"role": "narrator", "content": []}},
    }));
    assert!(
        matches!(outcome, Err(ReducerError::Projection(_))),
        "{outcome:?}"
    );
}
