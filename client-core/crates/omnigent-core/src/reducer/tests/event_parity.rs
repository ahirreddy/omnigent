//! Port of `NativeLab` `EventParityTests.swift` (the WP3 rows).

use omnigent_protocol::{ConversationItem, FromWire};
use serde_json::{Value, json};

use super::{Harness, events, fixture, user};
use crate::reducer::{
    ActivityKind, ChangedFiles, ReducerError, RowRole, TurnStatus, display_text, project_item,
};

const SESSION: &str = "fixture-session";

#[test]
fn history_and_live_commit_use_same_presentation_for_every_known_family() {
    let items = fixture(
        "items/EventParity--HistoryAndLiveCommitUseSamePresentationForEveryKnownFamily.json",
    );
    let items = items.as_array().expect("item list");
    assert_eq!(items.len(), 16);
    for payload in items {
        let item = ConversationItem::from_value(payload.clone()).expect("history item decodes");
        let expected = project_item(&item).expect("projects").expect("visible");
        let mut harness = Harness::new(SESSION);
        let event = json!({"type": "response.output_item.done", "item": payload});
        harness.send(event.clone());
        harness.send(event);
        assert_eq!(harness.snapshot().rows, vec![expected], "{payload}");
    }
}

fn lifecycle_type(alias: bool, suffix: &str) -> String {
    if alias {
        format!("response.TaskStatus.{}", suffix.to_uppercase())
    } else {
        format!("response.{suffix}")
    }
}

#[test]
fn lifecycle_aliases_have_same_transitions_and_ignore_stale_terminal_i_ds() {
    for alias in [false, true] {
        for start in ["created", "queued", "in_progress"] {
            for end in ["completed", "failed", "incomplete", "cancelled"] {
                let mut harness = Harness::new(SESSION);
                harness
                    .send(json!({"type": lifecycle_type(alias, start), "response": {"id": "new"}}));
                assert_eq!(
                    harness.snapshot().header.status,
                    TurnStatus::Running,
                    "{alias} {start}"
                );
                harness
                    .send_json(r#"{"type":"response.output_text.delta","delta":"Partial text"}"#);
                harness
                    .send(json!({"type": lifecycle_type(alias, end), "response": {"id": "old"}}));
                assert_eq!(
                    harness.snapshot().header.status,
                    TurnStatus::Running,
                    "{alias} stale {end}"
                );
                harness
                    .send(json!({"type": lifecycle_type(alias, end), "response": {"id": "new"}}));
                assert_eq!(
                    harness.snapshot().header.status,
                    TurnStatus::Idle,
                    "{alias} {end}"
                );
                assert_eq!(harness.assistant_texts(), ["Partial text"]);
                assert!(!harness.snapshot().rows.iter().any(|row| row.is_streaming));
            }
        }
    }
}

#[test]
fn usage_sparse_merge_replacement_and_response_context_tokens() {
    let mut harness = Harness::new(SESSION);
    let lines = events("EventParity--UsageSparseMergeReplacementAndResponseContextTokens.jsonl");
    harness.send(lines[0].clone());
    harness.send(lines[1].clone());
    let state = &harness.snapshot().event_state;
    assert_eq!(state.context_tokens, Some(100));
    assert_eq!(state.context_window, Some(1000));
    assert_eq!(state.total_cost_usd, Some(0.0));
    assert!(
        state
            .usage_by_model
            .as_ref()
            .is_some_and(std::collections::BTreeMap::is_empty)
    );
    harness.send(lines[2].clone());
    assert_eq!(harness.snapshot().event_state.context_tokens, Some(120));
    assert_eq!(harness.snapshot().rows, []);
    assert!(
        harness
            .reducer
            .sections()
            .iter()
            .any(|section| section.id == "usage" && section.summary.contains("120"))
    );
}

#[test]
fn invalid_usage_never_replaces_valid_nonnegative_state() {
    let mut harness = Harness::new(SESSION);
    let lines = events("EventParity--InvalidUsageNeverReplacesValidNonnegativeState.jsonl");
    harness.send(lines[0].clone());
    for line in &lines[1..] {
        // Negative and string counts are decode errors; a zero window and a negative cost are
        // rejected by the reducer; a null window changes nothing. None may replace valid usage.
        match harness.try_send(line.clone()) {
            Ok(_) | Err(ReducerError::Decode(_)) => {}
            Err(error) => panic!("{line}: {error}"),
        }
        let state = &harness.snapshot().event_state;
        assert_eq!(state.context_tokens, Some(100), "{line}");
        assert_eq!(state.context_window, Some(1000), "{line}");
        assert_eq!(state.total_cost_usd, Some(0.5), "{line}");
    }
    assert!(matches!(
        harness.try_send(lines[1].clone()),
        Err(ReducerError::Decode(_))
    ));
    assert!(matches!(
        harness.try_send(lines[4].clone()),
        Err(ReducerError::Decode(_))
    ));
}

#[test]
fn status_background_count_is_sparse_and_explicit_zero_clears() {
    let mut harness = Harness::new(SESSION);
    let lines = events("EventParity--StatusBackgroundCountIsSparseAndExplicitZeroClears.jsonl");
    harness.send(lines[0].clone());
    harness.send(lines[1].clone());
    assert_eq!(
        harness.snapshot().event_state.background_task_count,
        Some(2)
    );
    harness.send(lines[2].clone());
    assert_eq!(
        harness.snapshot().event_state.background_task_count,
        Some(0)
    );
    assert_eq!(
        harness.snapshot().event_state.status.as_deref(),
        Some("idle")
    );
    assert_eq!(harness.snapshot().rows, []);
}

#[test]
fn todos_presence_and_mcp_replacement_lists_clear_old_entries() {
    let lines = events("EventParity--TodosPresenceAndMCPReplacementListsClearOldEntries.jsonl");
    for pair in lines.chunks(2) {
        let mut harness = Harness::new(SESSION);
        for line in pair {
            assert!(harness.send(line.clone()).effects.changed, "{line}");
        }
        let state = &harness.snapshot().event_state;
        match pair[0]["type"].as_str() {
            Some("session.todos") => assert_eq!(state.todos.as_deref(), Some(&[][..])),
            Some("session.presence") => assert_eq!(state.viewers.as_deref(), Some(&[][..])),
            Some("session.mcp_startup") => {
                assert!(
                    state
                        .mcp_startup
                        .as_ref()
                        .is_some_and(std::collections::BTreeMap::is_empty)
                );
            }
            other => panic!("unexpected {other:?}"),
        }
        assert_eq!(harness.snapshot().rows, []);
    }
}

#[test]
fn startup_transitions_retain_failures_and_clear_transient_terminal_state() {
    let mut harness = Harness::new(SESSION);
    let lines =
        events("EventParity--StartupTransitionsRetainFailuresAndClearTransientTerminalState.jsonl");
    let has_section =
        |harness: &Harness, id: &str| harness.reducer.sections().iter().any(|s| s.id == id);
    harness.send(lines[0].clone());
    assert!(has_section(&harness, "terminal-pending"));
    harness.send(lines[1].clone());
    assert!(!has_section(&harness, "terminal-pending"));
    for line in &lines[2..8] {
        harness.send(line.clone());
        let stage = harness
            .snapshot()
            .event_state
            .sandbox
            .as_ref()
            .map(|s| s.stage.as_str().to_owned());
        assert_eq!(stage.as_deref(), line["stage"].as_str());
    }
    assert!(
        harness
            .reducer
            .sections()
            .iter()
            .flat_map(|section| &section.details)
            .any(|detail| detail.text.contains("Fixture startup failed"))
    );
    for line in &lines[8..] {
        harness.send(line.clone());
        let status = harness
            .snapshot()
            .event_state
            .mcp_startup
            .as_ref()
            .and_then(|servers| servers.get("fixture"))
            .map(|server| server.status.as_str().to_owned());
        assert_eq!(
            status.as_deref(),
            line["servers"]["fixture"]["status"].as_str()
        );
    }
}

#[test]
fn startup_line_names_the_sandbox_stage_or_the_starting_mcp_servers() {
    let mut harness = Harness::new(SESSION);
    let line = |harness: &Harness| {
        harness
            .reducer
            .sections()
            .iter()
            .find(|section| section.id == "startup")
            .map(|section| {
                let state = section.details[0].text.clone();
                (section.summary.clone(), state)
            })
    };
    let sandbox = |stage: &str, error: Value| {
        json!({"type": "session.sandbox_status", "conversation_id": SESSION,
               "stage": stage, "error": error})
    };
    let progress = |text: &str| Some((text.to_owned(), "progress".to_owned()));
    harness.send(sandbox("cloning", Value::Null));
    assert_eq!(line(&harness), progress("Cloning repository\u{2026}"));
    harness.send(sandbox("failed", json!("No capacity")));
    assert_eq!(
        line(&harness),
        Some(("Sandbox launch failed".to_owned(), "failed".to_owned()))
    );
    harness.send(sandbox("ready", Value::Null));
    assert_eq!(line(&harness), None);
    harness.send(
        json!({"type": "session.mcp_startup", "conversation_id": SESSION, "servers": {
        "a": {"status": "ready"}, "b": {"status": "starting"}, "c": {"status": "starting"},
        "d": {"status": "starting"}, "e": {"status": "starting"}}}),
    );
    assert_eq!(
        line(&harness),
        progress("Starting MCP servers (1/5): b, c, d, \u{2026}")
    );
    harness.send(
        json!({"type": "session.mcp_startup", "conversation_id": SESSION,
                        "servers": {"solo": {"status": "starting"}}}),
    );
    assert_eq!(
        line(&harness),
        progress("Starting MCP server: solo\u{2026}")
    );
}

#[test]
fn resources_are_scoped_and_deleted_from_active_state() {
    let mut harness = Harness::new(SESSION);
    let lines = events("EventParity--ResourcesAreScopedAndDeletedFromActiveState.jsonl");
    harness.send(lines[0].clone());
    harness.send(lines[1].clone());
    let resources = |harness: &Harness| {
        harness
            .snapshot()
            .event_state
            .resources
            .clone()
            .unwrap_or_default()
    };
    assert_eq!(resources(&harness).len(), 1);
    harness.send(lines[2].clone());
    let active = harness
        .snapshot()
        .event_state
        .terminal_activity
        .clone()
        .unwrap_or_default();
    assert!(active.contains("terminal-1"));
    harness.send(lines[3].clone());
    assert!(resources(&harness).contains_key("terminal-1"));
    harness.send(lines[4].clone());
    assert!(!resources(&harness).contains_key("terminal-1"));
    assert!(
        !harness
            .reducer
            .sections()
            .iter()
            .any(|s| s.id == "resource-terminal-1")
    );
}

#[test]
fn child_sections_classify_the_server_child_summary() {
    let mut harness = Harness::new(SESSION);
    let lines =
        events("EventParity--ChildUpdatesMergeAndSupersessionKeepsSourceConversation.jsonl");
    harness.send(lines[0].clone());
    let summary = |harness: &Harness| {
        harness
            .reducer
            .sections()
            .iter()
            .find(|section| section.id == "child-child-1")
            .map(|section| (section.summary.clone(), section.session_id.clone()))
    };
    assert_eq!(
        summary(&harness),
        Some(("Starting".to_owned(), Some("child-1".to_owned())))
    );
    harness.send(json!({
        "type": "session.child_session.updated",
        "conversation_id": SESSION,
        "child_session_id": "child-1",
        "child": {"title": "researcher:auth", "busy": true, "pending_elicitations_count": 1,
                  "task_summary": "Write the auth tests"},
    }));
    assert_eq!(
        summary(&harness).map(|(text, _)| text).as_deref(),
        Some("Needs you")
    );
    harness.send(json!({
        "type": "session.child_session.updated",
        "conversation_id": SESSION,
        "child_session_id": "child-1",
        "child": {"busy": false, "pending_elicitations_count": 0,
                  "current_task_status": "completed"},
    }));
    assert_eq!(
        summary(&harness).map(|(text, _)| text).as_deref(),
        Some("Ready")
    );
}

#[test]
fn child_updates_merge_and_supersession_keeps_source_conversation() {
    let mut harness = Harness::new(SESSION);
    let lines =
        events("EventParity--ChildUpdatesMergeAndSupersessionKeepsSourceConversation.jsonl");
    harness.send_all(&lines[..3]);
    let child = harness
        .snapshot()
        .event_state
        .children
        .as_ref()
        .and_then(|c| c.get("child-1"))
        .cloned()
        .expect("child");
    assert_eq!(child.get("title"), Some(&json!("Child task")));
    assert_eq!(child.get("status"), Some(&json!("idle")));
    harness.send(lines[3].clone());
    assert_eq!(harness.snapshot().id(), SESSION);
    assert_eq!(
        harness.snapshot().event_state.superseded_by.as_deref(),
        Some("replacement-session")
    );
    assert!(harness.reducer.sections().iter().any(|section| {
        section.id == "superseded" && section.session_id.as_deref() == Some("replacement-session")
    }));
}

#[test]
fn catalog_skills_and_changed_files_invalidate_without_invented_transcript() {
    let mut harness = Harness::new(SESSION);
    let lines = events(
        "EventParity--CatalogSkillsAndChangedFilesInvalidateWithoutInventedTranscript.jsonl",
    );
    for line in &lines[..3] {
        assert!(harness.send(line.clone()).effects.reconcile, "{line}");
        assert!(harness.snapshot().rows.is_empty(), "{line}");
    }
    harness.send(lines[3].clone());
    assert_eq!(
        harness.snapshot().event_state.collaboration_mode.as_deref(),
        Some("plan")
    );
    let files = harness.send(lines[4].clone());
    assert_eq!(
        files.effects.changed_files_environment.as_deref(),
        Some("local")
    );
    let environments = harness
        .snapshot()
        .event_state
        .changed_files
        .clone()
        .unwrap_or_default();
    assert_eq!(environments.get("local"), Some(&ChangedFiles::Loading));
    let default = harness.send(lines[5].clone());
    assert_eq!(
        default.effects.changed_files_environment.as_deref(),
        Some("default")
    );
    assert_eq!(harness.snapshot().rows, []);
}

#[test]
fn session_events_from_other_conversation_cannot_mutate_snapshot() {
    for line in events("EventParity--SessionEventsFromOtherConversationCannotMutateSnapshot.jsonl")
    {
        let mut harness = Harness::new(SESSION);
        let before = harness.snapshot().clone();
        let outcome = harness.send(line.clone());
        assert!(!outcome.effects.changed, "{line}");
        assert!(!outcome.effects.reconcile, "{line}");
        assert!(outcome.changes.is_empty(), "{line}");
        assert_eq!(*harness.snapshot(), before, "{line}");
    }
}

#[test]
fn transport_heartbeats_never_create_transcript_or_end_response() {
    let mut harness = Harness::new(SESSION);
    let lines = events("EventParity--TransportHeartbeatsNeverCreateTranscriptOrEndResponse.jsonl");
    harness.send(lines[0].clone());
    for line in &lines[1..] {
        let outcome = harness.send(line.clone());
        assert!(
            !outcome.effects.changed && !outcome.effects.reconcile,
            "{line}"
        );
        assert!(outcome.changes.is_empty());
        assert_eq!(harness.snapshot().rows, []);
        assert_eq!(harness.snapshot().header.status, TurnStatus::Running);
    }
}

#[test]
fn display_only_events_have_meaningful_typed_activity() {
    let expected = [
        (ActivityKind::File, "fixture.txt"),
        (ActivityKind::Retry, "Fixture retry"),
        (ActivityKind::Error, "Fixture failure"),
        (ActivityKind::ClientTask, "fixture-task"),
        (ActivityKind::Browser, "navigate"),
        (ActivityKind::Policy, "Fixture policy denial"),
    ];
    let lines = events("EventParity--DisplayOnlyEventsHaveMeaningfulTypedActivity.jsonl");
    for (line, (kind, content)) in lines.iter().zip(expected) {
        let mut harness = Harness::new(SESSION);
        harness.send(line.clone());
        let row = harness
            .snapshot()
            .rows
            .iter()
            .find(|row| row.activity_kind() == Some(kind))
            .unwrap_or_else(|| panic!("{line}"));
        assert!(display_text(row).contains(content), "{line}");
        assert!(!row.is_streaming, "{line}");
        assert!(harness.pending_ids().is_empty(), "{line}");
    }
}

fn compaction_case(name: &str) -> Harness {
    let mut harness =
        Harness::with_rows(SESSION, vec![user("before", "Question before compaction")]);
    let lines = events(name);
    harness.send(lines[0].clone());
    assert!(
        harness
            .snapshot()
            .rows
            .iter()
            .any(|row| row.activity_kind() == Some(ActivityKind::Compaction) && row.is_streaming)
    );
    harness.send(lines[1].clone());
    let users: Vec<&str> = harness
        .snapshot()
        .rows
        .iter()
        .filter(|row| row.role == RowRole::User)
        .map(|row| row.text.as_str())
        .collect();
    assert_eq!(users, ["Question before compaction"]);
    let rows: Vec<_> = harness
        .snapshot()
        .rows
        .iter()
        .filter(|row| row.activity_kind() == Some(ActivityKind::Compaction))
        .collect();
    assert_eq!(rows.len(), 1);
    assert!(!rows[0].is_streaming);
    harness
}

#[test]
fn compaction_completes_or_fails_without_changing_transcript_meaning() {
    let completed = compaction_case(
        "EventParity--CompactionCompletesOrFailsWithoutChangingTranscriptMeaning--completed.jsonl",
    );
    assert_eq!(completed.snapshot().event_state.context_tokens, Some(84));
    let failed = compaction_case(
        "EventParity--CompactionCompletesOrFailsWithoutChangingTranscriptMeaning--failed.jsonl",
    );
    assert_eq!(failed.snapshot().event_state.context_tokens, None);
    let row = failed
        .snapshot()
        .rows
        .iter()
        .find(|row| row.activity_kind() == Some(ActivityKind::Compaction))
        .expect("row");
    assert!(display_text(row).to_lowercase().contains("fail"));
}

#[test]
fn tool_output_streams_then_final_commit_replaces_preview_and_replay_does_not_duplicate() {
    let mut harness = Harness::new(SESSION);
    let lines = events(
        "EventParity--ToolOutputStreamsThenFinalCommitReplacesPreviewAndReplayDoesNotDuplicate.jsonl",
    );
    harness.send_all(&lines[..4]);
    let preview = harness
        .snapshot()
        .rows
        .iter()
        .find(|row| row.activity_kind() == Some(ActivityKind::ToolResult))
        .expect("preview");
    assert!(display_text(preview).contains("Partial output"));
    assert!(preview.is_streaming);
    harness.send_all(&lines[4..]);
    let results: Vec<_> = harness
        .snapshot()
        .rows
        .iter()
        .filter(|row| row.activity_kind() == Some(ActivityKind::ToolResult))
        .collect();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].id, "result-1");
    assert!(display_text(results[0]).contains("Partial output completed"));
    assert!(!results[0].is_streaming);
}

#[test]
fn reasoning_summary_interleaves_with_text_and_commit_retires_only_matching_activity() {
    let mut harness = Harness::new(SESSION);
    harness.send_all(&events("EventParity--ReasoningSummaryInterleavesWithTextAndCommitRetiresOnlyMatchingActivity.jsonl"));
    assert_eq!(
        harness.assistant_texts(),
        ["Before reasoning", "After reasoning"]
    );
    let summaries: Vec<_> = harness
        .snapshot()
        .rows
        .iter()
        .filter(|row| row.activity_kind() == Some(ActivityKind::Reasoning))
        .collect();
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].id, "reasoning-1");
    assert!(display_text(summaries[0]).contains("Visible summary"));
    assert!(!harness.all_display().contains("PRIVATE_RAW_REASONING"));
}

#[test]
fn nested_interruption_seals_only_the_matching_live_turn() {
    let mut harness = Harness::new(SESSION);
    let lines = events("EventParity--NestedInterruptionSealsOnlyTheMatchingLiveTurn.jsonl");
    harness.send_all(&lines[..3]);
    assert_eq!(harness.snapshot().header.status, TurnStatus::Running);
    harness.send(lines[3].clone());
    assert_eq!(harness.snapshot().header.status, TurnStatus::Idle);
    assert_eq!(harness.assistant_texts(), ["Partial reply"]);
    assert!(!harness.snapshot().rows.iter().any(|row| row.is_streaming));
}

#[test]
fn unknown_live_events_have_bounded_inspectable_safe_fallback() {
    let mut harness = Harness::new(SESSION);
    let text: String = "visible fixture text ".repeat(20_000);
    harness.send(json!({
        "type": "response.future_activity", "id": "future-event",
        "message": "Useful future activity",
        "payload": {"text": text, "api_key": "PRIVATE_CREDENTIAL", "encrypted_content": "PRIVATE_HIDDEN_DATA"},
    }));
    let row = harness.last();
    assert_eq!(row.activity_kind(), Some(ActivityKind::Unknown));
    let content = display_text(row);
    assert!(content.contains("Useful future activity"));
    assert!(content.chars().count() < 50_000);
    assert!(!content.contains("PRIVATE_"));
}

#[test]
fn pending_decision_is_never_hidden_by_tool_output_or_unrelated_resolution() {
    let mut harness = Harness::new(SESSION);
    let lines = events(
        "EventParity--ElicitationResolutionRequiresExactIDAndToolOutputCannotResolveIt.jsonl",
    );
    harness.send(lines[0].clone());
    let target = harness
        .snapshot()
        .decisions
        .first()
        .map(|d| d.target_session_id.clone());
    assert_eq!(target.as_deref(), Some("child-1"));
    harness.send_all(&lines[1..3]);
    assert_eq!(harness.pending_ids(), ["approval-1"]);
    assert_eq!(harness.snapshot().header.status, TurnStatus::NeedsResponse);
    harness.send(lines[3].clone());
    assert_eq!(harness.pending_ids(), Vec::<&str>::new());
}
