//! What the runtime writes into a transcript that is not the person's own words, shown as the
//! web client shows it on main.
//!
//! - `[System: …]` notices (task, timer and terminal events, Claude's task notifications) are
//!   muted markers; a sub-agent's wake and peer envelopes never show
//!   (`web/src/lib/systemMessage.ts`, `itemsToBlocks.ts`).
//! - An automation's note is stripped from the prompt it ends (`stripAutomationContext`).
//! - Another session's message keeps its sender apart from its text (`sessionMessageOrigin`).
//! - A reply to Codex async questions shows each answer under its question
//!   (`codexAsyncQuestionReply`).
//! - Sub-agent and task receipts are markers, plan changes one line each; journal checkpoints
//!   never show (`subagentActivity.ts`, `taskActivity.ts`).
//! - `session.background_tasks` updates the background tasks and `session.journal.appended`
//!   adds no row (`chatStore.ts`).

use omnigent_protocol::question_reply::QuestionReply;
use omnigent_protocol::{ConversationItem, FromWire as _};

use super::{Harness, events, fixture};
use crate::reconcile::history_rows;
use crate::reducer::{ActivityKind, Row, RowRole};

const HISTORY: &str = "items/TranscriptParity--RuntimeContextAndMarkers.json";
const STREAM: &str = "TranscriptParity--LiveNoticesMarkersAndBackgroundTasks.jsonl";
const REPLIES: &str = "items/TranscriptParity--CodexAsyncQuestionReplies.json";

fn history() -> Vec<Row> {
    let items: Vec<ConversationItem> = fixture(HISTORY)
        .as_array()
        .expect("items")
        .iter()
        .map(|item| ConversationItem::from_value(item.clone()).expect("decodes"))
        .collect();
    history_rows(&items).expect("projects")
}

/// Each row as `id role kind: title | summary`, `-` for a row with no activity.
fn shown(rows: &[Row]) -> Vec<String> {
    rows.iter()
        .map(|row| {
            let (kind, title, summary) = row.activity.as_ref().map_or_else(
                || ("-", row.text.as_str(), ""),
                |activity| {
                    (
                        activity.kind.as_str(),
                        activity.title.as_str(),
                        activity.summary.as_str(),
                    )
                },
            );
            format!(
                "{} {} {kind}: {title} | {summary}",
                row.id,
                row.role.as_str()
            )
        })
        .collect()
}

#[test]
fn runtime_context_is_never_the_persons_bubble() {
    assert_eq!(
        shown(&history()),
        [
            "automation user -: Summarise the open issues. | ",
            "a1 assistant -: Three issues are open. | ",
            "delegated tool subagentMarker: Started | Explore auth",
            "returned tool subagentMarker: Failed | Explore auth",
            "timer tool systemNotice: Timer t1 fired | note: 'check the build'",
            "task tool systemNotice: Sub-agent t_abc completed | final answer",
            "terminal tool systemNotice: Terminal shell:s1 idle | ",
            "notification tool systemNotice: Background task completed | Background command \
             \"make test\" completed (exit code 0)",
            "origin user -: Can you review PR 12?\nIt is small. | ",
            "typed-notice tool systemNotice: something brand new | ",
            "typed-continued user -: This session is being continued from a previous \
             conversation, I said. | ",
            "todo-started tool taskMarker: Started | Write the tests",
            "plan tool taskMarker: Made a plan: Ship it \u{00B7} 2 tasks | ",
            "todo-done tool taskMarker: Completed | Write the tests",
            "terminal-receipt tool resource: Terminal created | Build terminal",
        ]
    );
}

#[test]
fn markers_link_their_session_and_never_read_as_failures() {
    let rows = history();
    let origin = rows.iter().find(|row| row.id == "origin").expect("origin");
    assert_eq!(origin.origin_session_id.as_deref(), Some("sess_peer-1"));
    // Markers and notices show in the transcript; a routine receipt stays in the drawer.
    let in_drawer: Vec<&str> = rows
        .iter()
        .filter(|row| row.is_activity_only())
        .map(|row| row.id.as_str())
        .collect();
    assert_eq!(in_drawer, ["terminal-receipt"]);
    let returned = rows
        .iter()
        .find(|row| row.id == "returned")
        .and_then(|row| row.activity.as_ref())
        .expect("returned");
    assert!(!returned.is_failure());
    assert_eq!(returned.detail("session"), Some("child-1"));
    assert!(
        rows.iter()
            .all(|row| !row.text.contains("omnigent-automation-context")),
        "the automation note never reaches a row"
    );
}

#[test]
fn live_notices_markers_and_background_tasks() {
    let mut harness = Harness::new("session1");
    let lines = events(STREAM);
    harness.send_all(&lines[..2]);
    let state = &harness.snapshot().event_state;
    assert_eq!(state.background_task_count, Some(1));
    assert_eq!(
        state.background_tasks.as_ref().expect("tasks")[0]
            .command
            .as_deref(),
        Some("gh run watch")
    );
    assert_eq!(
        harness.snapshot().rows,
        Vec::<Row>::new(),
        "no Session event row"
    );
    let journal = harness.send(lines[2].clone());
    assert!(
        journal.changes.is_empty(),
        "the journal entry changes nothing"
    );
    assert_eq!(harness.snapshot().rows, Vec::<Row>::new());
    harness.send_all(&lines[3..6]);
    let kinds: Vec<(&str, RowRole, Option<ActivityKind>)> = harness
        .snapshot()
        .rows
        .iter()
        .map(|row| (row.id.as_str(), row.role, row.activity_kind()))
        .collect();
    assert_eq!(
        kinds,
        [
            (
                "delegated",
                RowRole::Tool,
                Some(ActivityKind::SubagentMarker)
            ),
            ("timer", RowRole::Tool, Some(ActivityKind::SystemNotice)),
            ("origin", RowRole::User, None),
        ]
    );
    assert_eq!(harness.last().text, "Can you review PR 12?");
    assert_eq!(
        harness.last().origin_session_id.as_deref(),
        Some("sess_peer-1")
    );
    harness.send(lines[6].clone());
    assert_eq!(
        harness.snapshot().event_state.background_task_count,
        Some(0)
    );
}

fn answered(question: Option<&str>, answer: &str) -> QuestionReply {
    QuestionReply {
        question: question.map(str::to_owned),
        answer: answer.to_owned(),
    }
}

#[test]
fn a_codex_question_reply_shows_its_answers() {
    let items: Vec<ConversationItem> = fixture(REPLIES)
        .as_array()
        .expect("items")
        .iter()
        .map(|item| ConversationItem::from_value(item.clone()).expect("decodes"))
        .collect();
    let rows = history_rows(&items).expect("projects");
    let shown: Vec<(&str, RowRole, &str, &[QuestionReply])> = rows
        .iter()
        .map(|row| {
            (
                row.id.as_str(),
                row.role,
                row.text.as_str(),
                row.question_replies.as_slice(),
            )
        })
        .collect();
    let quoted = "Explain this: <send_user_message_question_reply>[{\"answer\":\"Blue\",\
                  \"questionItemId\":\"[\\\"request_user_input_async\\\",\\\"call_abc\\\",0]\"}]\
                  </send_user_message_question_reply>";
    assert_eq!(
        shown,
        [
            (
                "reply",
                RowRole::User,
                "\u{21AA} Re: Did you click Run after signing in?\nYes, I clicked Run",
                [answered(
                    Some("Did you click Run after signing in?"),
                    "Yes, I clicked Run"
                )]
                .as_slice(),
            ),
            (
                "several",
                RowRole::User,
                "\u{21AA} Re: Color?\nBlue\n\nLarge",
                [answered(Some("Color?"), "Blue"), answered(None, "Large")].as_slice(),
            ),
            (
                "from-session",
                RowRole::User,
                "\u{21AA} Re: Which branch?\nMain",
                [answered(Some("Which branch?"), "Main")].as_slice(),
            ),
            ("quoted", RowRole::User, quoted, [].as_slice()),
            (
                "malformed",
                RowRole::User,
                "<send_user_message_question_reply>\n[{</send_user_message_question_reply>",
                [].as_slice(),
            ),
        ]
    );
    let from_session = rows.iter().find(|row| row.id == "from-session");
    assert_eq!(
        from_session.and_then(|row| row.origin_session_id.as_deref()),
        Some("sess_peer-1"),
        "a reply another session sent keeps its sender"
    );
}
