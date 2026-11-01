//! Port of `NativeLab` `EventHierarchyTests.swift`.

use omnigent_protocol::{ConversationItem, FromWire};

use super::{Harness, assistant, conversation, events, fixture, swift_snapshot};
use crate::reducer::{
    Activity, ActivityKind, Attachment, AttachmentKind, Row, RowRole, project_item,
};

#[test]
fn routine_receipts_move_to_activity_without_changing_history() {
    let snapshot = swift_snapshot(&fixture("events/EventGallery--lifecycle.json"));
    let original = snapshot.clone();
    let transcript: Vec<&str> = snapshot
        .transcript_rows()
        .map(|row| row.id.as_str())
        .collect();
    assert_eq!(transcript, ["lifecycle-user", "lifecycle-reply"]);
    let lifecycle: Vec<&str> = snapshot
        .lifecycle_rows()
        .map(|row| row.id.as_str())
        .collect();
    assert_eq!(lifecycle, ["lifecycle-created", "lifecycle-deleted"]);
    assert_eq!(snapshot.rows.len(), 4);
    // Classifying rows never edits them: the history is byte-for-byte what it was.
    assert_eq!(snapshot, original);
    let reducer = Harness::from_snapshot(snapshot);
    let lifecycle_again: Vec<&Row> = reducer.snapshot().lifecycle_rows().collect();
    let expected: Vec<&Row> = original.lifecycle_rows().collect();
    assert_eq!(lifecycle_again, expected);
}

fn activity(kind: ActivityKind, title: &str, summary: &str, status: Option<&str>) -> Activity {
    Activity {
        kind,
        title: title.to_owned(),
        summary: summary.to_owned(),
        status: status.map(str::to_owned),
        details: Vec::new(),
    }
}

fn tool_row(id: &str, text: &str, activity: Activity) -> Row {
    let mut row = Row::text(id, RowRole::Tool, text);
    row.activity = Some(activity);
    row
}

#[test]
fn failures_attachments_and_terminal_output_are_never_quieted() {
    let kinds = [
        ActivityKind::Resource,
        ActivityKind::ClientTask,
        ActivityKind::Error,
        ActivityKind::Terminal,
        ActivityKind::Unknown,
    ];
    for kind in kinds {
        for status in ["failed", "error", "denied"] {
            let failure = activity(kind, "Failure", "Details", Some(status));
            assert!(failure.is_failure(), "{kind:?} {status}");
            assert!(
                !tool_row("failure", "", failure).is_activity_only(),
                "{kind:?} {status}"
            );
        }
    }
    let mut resource = tool_row(
        "file",
        "File ready",
        activity(ActivityKind::Resource, "File created", "Notes", None),
    );
    resource.attachments.push(Attachment {
        id: "a".to_owned(),
        kind: AttachmentKind::File,
        title: "notes.txt".to_owned(),
        reference: Some("file-1".to_owned()),
        mime_type: None,
        is_embedded: false,
    });
    assert!(!resource.is_activity_only());
    let output = tool_row(
        "output",
        "Build succeeded",
        activity(
            ActivityKind::Terminal,
            "Terminal output",
            "Build succeeded",
            Some("completed"),
        ),
    );
    assert!(!output.is_activity_only());
}

#[test]
fn only_finished_client_bookkeeping_is_quieted() {
    for status in ["cancelled", "canceled", "completed"] {
        assert!(
            activity(ActivityKind::ClientTask, "Task", "", Some(status)).is_routine_lifecycle()
        );
    }
    for status in ["desktop_required", "running", "failed"] {
        assert!(
            !activity(ActivityKind::ClientTask, "Task", "", Some(status)).is_routine_lifecycle()
        );
    }
}

#[test]
fn history_and_stream_use_same_lifecycle_projection() {
    let event = fixture("events/EventHierarchy--HistoryAndStreamUseSameLifecycleProjection.json");
    let item = ConversationItem::from_value(event["item"].clone()).expect("item decodes");
    let historical = project_item(&item).expect("projects").expect("visible");
    let mut harness = Harness::new("s1");
    harness.send(event);
    let lifecycle: Vec<&Row> = harness.snapshot().lifecycle_rows().collect();
    assert_eq!(lifecycle, vec![&historical]);
    assert_eq!(harness.snapshot().transcript_rows().count(), 0);
    assert_eq!(harness.snapshot().rows, vec![historical]);
}

#[test]
fn stop_marks_only_current_reply_and_completion_is_quiet() {
    for (name, interrupted) in [
        ("response_cancelled", true),
        ("session_interrupted", true),
        ("response_completed", false),
    ] {
        let mut older = assistant("older", "Earlier answer");
        older.response_id = Some("previous".to_owned());
        let mut harness = Harness::from_snapshot(conversation("s1", vec![older]));
        harness.send_all(&events(&format!(
            "EventHierarchy--StopMarksOnlyCurrentReplyAndCompletionIsQuiet--{name}.jsonl"
        )));
        let rows = &harness.snapshot().rows;
        assert_eq!(rows.len(), 2, "{name}");
        assert!(!rows[1].is_streaming, "{name}");
        assert!(!rows[0].interrupted, "{name}");
        assert_eq!(rows[1].interrupted, interrupted, "{name}");
        let transcript: Vec<&str> = harness
            .snapshot()
            .transcript_rows()
            .map(|row| row.text.as_str())
            .collect();
        assert_eq!(transcript[1], "Partial answer", "{name}");
    }
}
