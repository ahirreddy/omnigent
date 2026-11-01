//! Port of `NativeLab` `LiveEventReconciliationTests.swift` (the WP3 rows).

use super::{Harness, assistant, conversation, events, user};
use crate::reducer::{
    Activity, ActivityKind, DetailSection, ReducerError, Row, RowRole, TurnStatus,
};

const SESSION: &str = "session";

fn reconciliation_events(name: &str) -> Vec<serde_json::Value> {
    events(&format!("LiveEventReconciliation--{name}.jsonl"))
}

#[test]
fn stopped_partial_text_and_file_keep_their_chronology_across_hydration() {
    let question = user("user", "Question");
    let mut harness = Harness::with_rows(SESSION, vec![question.clone()]);
    harness.send_all(&reconciliation_events(
        "StoppedPartialTextAndFileKeepTheirChronologyAcrossHydration",
    ));
    let file = harness
        .snapshot()
        .rows
        .iter()
        .find(|row| row.activity_kind() == Some(ActivityKind::File))
        .cloned()
        .expect("file row");
    let newer = user("newer", "Next question");
    harness.reconcile(conversation(SESSION, vec![question.clone(), newer.clone()]));
    assert_eq!(
        harness.ids(),
        ["user", "live:response:r1:0", file.id.as_str(), "newer"]
    );
    assert!(!harness.snapshot().rows.iter().any(|row| row.is_streaming));
    let reference = harness.snapshot().rows[2]
        .attachments
        .first()
        .and_then(|a| a.reference.clone());
    assert_eq!(reference.as_deref(), Some("file-1"));
    let mut fin = assistant("final", "Partial answer");
    fin.response_id = Some("r1".to_owned());
    harness.reconcile(conversation(SESSION, vec![question, fin, newer]));
    assert_eq!(harness.ids(), ["user", "final", file.id.as_str(), "newer"]);
}

#[test]
fn native_final_seals_preview_and_rejects_late_or_fractional_indices() {
    let mut harness = Harness::new(SESSION);
    let lines = reconciliation_events("NativeFinalSealsPreviewAndRejectsLateOrFractionalIndices");
    harness.send(lines[0].clone());
    // A fractional chunk index does not decode; the state stays as it was.
    assert!(matches!(
        harness.try_send(lines[1].clone()),
        Err(ReducerError::Decode(_))
    ));
    harness.send_all(&lines[2..]);
    assert_eq!(harness.texts(), ["Hello world"]);
    assert!(!harness.snapshot().rows[0].is_streaming);
    harness.reconcile(conversation(SESSION, Vec::new()));
    assert_eq!(harness.texts(), ["Hello world"]);
}

#[test]
fn native_messages_without_optional_indices_keep_every_delta() {
    let mut harness = Harness::new(SESSION);
    harness.send_all(&reconciliation_events(
        "NativeMessagesWithoutOptionalIndicesKeepEveryDelta",
    ));
    assert_eq!(harness.texts(), ["Hello world"]);
}

#[test]
fn old_response_start_status_and_deltas_cannot_interrupt_new_response() {
    let mut harness = Harness::new(SESSION);
    let lines = reconciliation_events("OldResponseStartStatusAndDeltasCannotInterruptNewResponse");
    harness.send_all(&lines[..4]);
    let current = harness.snapshot().clone();
    for stale in &lines[4..9] {
        harness.send(stale.clone());
        assert_eq!(*harness.snapshot(), current, "{stale}");
    }
    assert!(!harness.snapshot().rows[0].is_streaming);
    assert!(harness.snapshot().rows[1].is_streaming);
    harness.send_all(&lines[9..]);
    assert_eq!(harness.ids(), ["old-final", "live:response:new:0"]);
    assert!(harness.last().is_streaming);
}

#[test]
fn repeated_tool_call_i_ds_remain_response_scoped_and_old_commit_does_not_consume_new_preview() {
    let mut harness = Harness::new(SESSION);
    let lines = reconciliation_events(
        "RepeatedToolCallIDsRemainResponseScopedAndOldCommitDoesNotConsumeNewPreview",
    );
    harness.send_all(&lines[..6]);
    assert_eq!(harness.snapshot().rows.len(), 2);
    assert_eq!(harness.last().response_id.as_deref(), Some("r2"));
    let detail = harness
        .last()
        .activity
        .as_ref()
        .and_then(|a| a.details.first())
        .map(|d| d.text.clone());
    assert!(detail.is_some_and(|text| text.contains("New output")));
    harness.send_all(&lines[6..]);
    assert_eq!(harness.ids(), ["old-result", "new-result"]);
}

fn reasoning_row(id: &str, summary: &str) -> Row {
    let mut row = Row::text(id, RowRole::Tool, "Summary");
    row.response_id = Some("r1".to_owned());
    row.activity = Some(Activity {
        kind: ActivityKind::Reasoning,
        title: "Reasoning summary".to_owned(),
        summary: summary.to_owned(),
        status: None,
        details: vec![DetailSection::new("summary", "Summary", summary, false)],
    });
    row
}

#[test]
fn reasoning_commit_replay_and_hydration_retire_only_corresponding_summary() {
    let mut harness = Harness::new(SESSION);
    let lines =
        reconciliation_events("ReasoningCommitReplayAndHydrationRetireOnlyCorrespondingSummary");
    let (before, last) = lines.split_at(lines.len() - 1);
    harness.send_all(before);
    assert_eq!(harness.snapshot().rows.len(), 2);
    assert!(harness.last().is_streaming);
    let first = harness.snapshot().rows[0].clone();
    harness.reconcile(conversation(
        SESSION,
        vec![first, reasoning_row("summary2", "Second summary")],
    ));
    harness.send_all(last);
    assert_eq!(harness.ids(), ["summary1", "summary2"]);
}

#[test]
fn error_live_status_stored_and_replay_become_one_readable_row() {
    let mut harness = Harness::new(SESSION);
    harness.send_all(&reconciliation_events(
        "ErrorLiveStatusStoredAndReplayBecomeOneReadableRow",
    ));
    assert_eq!(harness.ids(), ["error1"]);
    assert_eq!(
        harness.snapshot().header.failure_message.as_deref(),
        Some("Visible failure")
    );
}

#[test]
fn session_idle_seals_all_activity_and_late_deltas_cannot_restart_spinner() {
    let mut harness = Harness::new(SESSION);
    let lines =
        reconciliation_events("SessionIdleSealsAllActivityAndLateDeltasCannotRestartSpinner");
    harness.send_all(&lines[..5]);
    let rows = harness.snapshot().rows.clone();
    harness.send_all(&lines[5..]);
    assert_eq!(harness.snapshot().rows, rows);
    assert!(!rows.iter().any(|row| row.is_streaming));
    assert!(!rows.iter().any(|row| {
        row.activity.as_ref().and_then(|a| a.status.as_deref()) == Some("in_progress")
    }));
    assert_eq!(harness.snapshot().header.status, TurnStatus::Idle);
}

#[test]
fn invalid_session_status_does_not_poison_metadata() {
    let mut harness = Harness::new(SESSION);
    let lines = reconciliation_events("InvalidSessionStatusDoesNotPoisonMetadata");
    harness.send(lines[0].clone());
    let before = harness.snapshot().clone();
    let outcome = harness.send(lines[1].clone());
    assert!(outcome.changes.is_empty());
    assert_eq!(*harness.snapshot(), before);
}

#[test]
fn incomplete_reason_is_visible_after_response_stops() {
    let mut harness = Harness::new(SESSION);
    harness.send_all(&reconciliation_events(
        "IncompleteReasonIsVisibleAfterResponseStops",
    ));
    assert_eq!(harness.snapshot().header.status, TurnStatus::Idle);
    assert_eq!(
        harness.snapshot().header.failure_message.as_deref(),
        Some("max_output_tokens")
    );
    assert_eq!(
        harness.snapshot().rows.first().and_then(Row::activity_kind),
        Some(ActivityKind::Error)
    );
}

#[test]
fn streaming_structured_tool_output_does_not_leak_partial_secrets() {
    let mut harness = Harness::new(SESSION);
    let lines = reconciliation_events("StreamingStructuredToolOutputDoesNotLeakPartialSecrets");
    let detail = |harness: &Harness| {
        harness
            .snapshot()
            .rows
            .first()
            .and_then(|row| row.activity.as_ref())
            .and_then(|a| a.details.first())
            .map(|d| d.text.clone())
            .unwrap_or_default()
    };
    harness.send(lines[0].clone());
    assert!(!detail(&harness).contains("PRIVATE"));
    harness.send(lines[1].clone());
    assert!(detail(&harness).contains("Visible"));
    assert!(!detail(&harness).contains("PRIVATE"));
}

#[test]
fn resolved_elicitation_replay_cannot_reappear_and_unknown_resolution_does_not_stop_response() {
    let mut harness = Harness::new(SESSION);
    let lines = reconciliation_events(
        "ResolvedElicitationReplayCannotReappearAndUnknownResolutionDoesNotStopResponse",
    );
    harness.send_all(&lines[..2]);
    assert_eq!(harness.snapshot().header.status, TurnStatus::Running);
    harness.send(lines[2].clone());
    let stale = harness.snapshot().clone();
    harness.send_all(&lines[3..]);
    harness.reconcile(stale);
    assert_eq!(harness.pending_ids(), Vec::<&str>::new());
    assert!(
        !harness
            .snapshot()
            .decisions
            .iter()
            .any(|decision| decision.id == "ask1")
    );
    assert_eq!(harness.snapshot().header.status, TurnStatus::Running);
}
