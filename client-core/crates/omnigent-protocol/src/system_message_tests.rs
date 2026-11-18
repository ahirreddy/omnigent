//! Ports of the web client's `systemMessage.test.ts` and `sessionMessageOrigin` cases, with the
//! notices in the shapes the runtime writes them on main.

use super::*;
use crate::content::AttachmentPart;

fn notice(kind: SystemMessageKind, label: &str, body: &str) -> SystemMessage {
    SystemMessage {
        kind,
        label: label.to_owned(),
        body: body.to_owned(),
    }
}

fn text(value: &str) -> Vec<ContentPart> {
    vec![ContentPart::Text {
        kind: TextPartKind::InputText,
        text: value.to_owned(),
    }]
}

fn image() -> ContentPart {
    ContentPart::Attachment(AttachmentPart {
        part_type: "input_image".to_owned(),
        kind: crate::content::AttachmentKind::Image,
        file_id: Some("f1".to_owned()),
        url: None,
        filename: None,
        mime_type: None,
        embedded: false,
    })
}

#[test]
fn plain_text_is_not_a_notice() {
    assert_eq!(parse_system_message("hello world"), None);
    assert_eq!(parse_system_message("[note: not a system message]"), None);
    assert_eq!(
        parse_system_message("can you handle [Request interrupted by user]?"),
        None
    );
    assert_eq!(parse_system_message("[Request interrupted by user?]"), None);
    assert_eq!(parse_system_message("[System: ]"), None);
    assert_eq!(parse_system_message("[System: timer t1 fired]\r"), None);
}

#[test]
fn task_notices_name_their_kind_and_keep_the_body() {
    use SystemMessageKind as K;
    let cases = [
        (
            "[System: task t_abc (sub_agent) completed]\nfinal answer here",
            notice(
                K::TaskCompleted,
                "Sub-agent t_abc completed",
                "final answer here",
            ),
        ),
        (
            "[System: task t_x (tool) completed]\nline one\nline two",
            notice(K::TaskCompleted, "Tool t_x completed", "line one\nline two"),
        ),
        (
            "[System: task t_99 (client_tool) completed]\nresult",
            notice(K::TaskCompleted, "Client tool t_99 completed", "result"),
        ),
        (
            "[System: task t_abc (tool) failed]\nBoom\nTraceback ...",
            notice(K::TaskFailed, "Tool t_abc failed", "Boom\nTraceback ..."),
        ),
        (
            "[System: task t_abc (sub_agent) cancelled]\nignored",
            notice(K::TaskCancelled, "Sub-agent t_abc cancelled", ""),
        ),
        (
            "[System: task t_abc (robot) completed]",
            notice(K::Generic, "task t_abc (robot) completed", ""),
        ),
    ];
    for (text, expected) in cases {
        assert_eq!(parse_system_message(text), Some(expected), "{text}");
    }
}

#[test]
fn timers_terminals_and_background_tasks_read_as_the_web_labels_them() {
    use SystemMessageKind as K;
    let cases = [
        (
            "[System: timer my_timer fired]",
            notice(K::TimerFired, "Timer my_timer fired", ""),
        ),
        (
            "[System: timer my_timer fired]\nnote: 'check on the build'",
            notice(
                K::TimerFired,
                "Timer my_timer fired",
                "note: 'check on the build'",
            ),
        ),
        (
            "[System: terminal shell:session1 is idle]\nignored",
            notice(K::TerminalIdle, "Terminal shell:session1 idle", ""),
        ),
        (
            "[System: background task b3f9 completed]\nBuild done",
            notice(K::TaskCompleted, "Background task completed", "Build done"),
        ),
        (
            "[System: background task b3f9 finished]",
            notice(K::Generic, "Background task finished", ""),
        ),
        // The runner's own async-result wake has no web pattern: a generic notice.
        (
            "[System: background task handle_0123456789ab (sys_os_shell) finished (completed) \
             \u{2014} 1 result waiting in inbox. Call sys_read_inbox to collect.]",
            notice(
                K::Generic,
                "background task handle_0123456789ab (sys_os_shell) finished (completed) \
                 \u{2014} 1 result waiting in inbox. Call sys_read_inbox to collect.",
                "",
            ),
        ),
        (
            "[System: something brand new]",
            notice(K::Generic, "something brand new", ""),
        ),
        (
            "[System: Message from another session]",
            notice(K::Generic, "Message from another session", ""),
        ),
    ];
    for (text, expected) in cases {
        assert_eq!(parse_system_message(text), Some(expected), "{text}");
    }
}

#[test]
fn a_sub_agent_wake_is_classified_apart() {
    for pending in ["1 result", "3 results"] {
        let text = format!(
            "[System: sub-agent claude_code/joke-programming finished (completed) \u{2014} \
             {pending} waiting in inbox. Call sys_read_inbox to collect.]"
        );
        assert_eq!(
            parse_system_message(&text).expect("a notice"),
            notice(
                SystemMessageKind::SubagentWake,
                "Sub-agent result ready",
                ""
            ),
            "{text}"
        );
    }
    let no_count = "[System: sub-agent a/b finished (completed) \u{2014} result waiting in \
                    inbox. Call sys_read_inbox to collect.]";
    assert_eq!(
        parse_system_message(no_count).map(|parsed| parsed.kind),
        Some(SystemMessageKind::Generic)
    );
}

#[test]
fn interrupt_records_are_interrupted_notices() {
    for record in [
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]",
    ] {
        assert_eq!(
            parse_system_message(record).expect("a notice"),
            notice(SystemMessageKind::Interrupted, "Interrupted", "")
        );
    }
    assert_eq!(
        parse_system_message("[System: interrupted]\nThe assistant response may be incomplete.")
            .expect("a notice"),
        notice(
            SystemMessageKind::Interrupted,
            "Interrupted",
            "The assistant response may be incomplete."
        )
    );
}

#[test]
fn attached_markers_are_dropped_before_looking_for_a_header() {
    assert_eq!(
        without_attached_markers("[Attached: foo.txt] [System: timer t1 fired]"),
        "[System: timer t1 fired]"
    );
    assert_eq!(
        without_attached_markers("[Attached file: /tmp/a.png]\n\nhello [Attachedness]"),
        "hello [Attachedness]"
    );
}

const MESSAGE: &str =
    "<teammate-message teammate_id=\"researcher\" color=\"blue\">Report</teammate-message>";
const HANDBACK: &str = "<agent-message from=\"researcher\">Report</agent-message>";
const RESULT: &str =
    "<task-notification><task-id>agent-1</task-id><result>Report</result></task-notification>";

#[test]
fn peer_envelopes_and_agent_results_are_agent_context() {
    let cases = [
        MESSAGE.to_owned(),
        HANDBACK.to_owned(),
        RESULT.to_owned(),
        format!(" \n{MESSAGE}\n{MESSAGE}\n"),
        format!("{MESSAGE}\n{HANDBACK}"),
        "<teammate-message teammate_id=\"researcher\">{\"type\":\"idle_notification\"}</teammate-message>"
            .to_owned(),
        format!("Another Claude session sent a message:\n{MESSAGE}"),
        format!("Another Claude session sent a message:\n{HANDBACK}"),
        format!("Another Claude session sent a message while you were working:\n{MESSAGE}"),
        format!("A peer session sent a message while you were working:\n{MESSAGE}"),
        format!(
            "Another Claude session sent a message:\n{MESSAGE}\n\nThis came from another Claude \
             session \u{2014} not typed by your user, but very likely working on their behalf."
        ),
        format!(
            "Another Claude session sent a message:\n{MESSAGE}\n\nThat \"other Claude session\" \
             is an agent working inside this same session \u{2014} a subagent or teammate."
        ),
        "<task-notification><task-id>task-1</task-id><summary>Agent reviewer finished</summary></task-notification>"
            .to_owned(),
    ];
    for case in cases {
        assert!(is_agent_message_content(&text(&case)), "{case}");
    }
}

#[test]
fn discussion_and_incomplete_envelopes_stay_visible() {
    let cases = [
        "hello".to_owned(),
        format!("Can you explain {MESSAGE}?"),
        format!("```xml\n{MESSAGE}\n```"),
        format!("> {MESSAGE}"),
        format!("{MESSAGE}\nWhat does this message mean?"),
        format!("{HANDBACK}\nWhat does this message mean?"),
        format!("Another Claude session sent a message:\n{MESSAGE}\nWhat does this mean?"),
        "<teammate-message teammate_id=\"researcher\">incomplete".to_owned(),
        "<teammate-message>missing sender</teammate-message>".to_owned(),
        "<agent-message>missing sender</agent-message>".to_owned(),
        "<agent-message from=\"\">empty sender</agent-message>".to_owned(),
        "<agent-message from=\"researcher\">incomplete".to_owned(),
        "<task-notification>missing task id</task-notification>".to_owned(),
        "<task-notification><task-id>task-1</task-id><summary>Background command completed</summary></task-notification>"
            .to_owned(),
        format!("{RESULT}\nWhat does this mean?"),
    ];
    for case in cases {
        assert!(!is_agent_message_content(&text(&case)), "{case}");
    }
    let mut mixed = text(MESSAGE);
    mixed.extend(text("Please explain this."));
    assert!(!is_agent_message_content(&mixed));
    let mut with_image = text(MESSAGE);
    with_image.push(image());
    assert!(!is_agent_message_content(&with_image));
    assert!(!is_agent_message_content(&[]));
}

const NOTIFICATION: &str = "<task-notification>\n<task-id>b3f9a2c1d</task-id>\n\
    <tool-use-id>toolu_01</tool-use-id>\n<output-file>/tmp/claude/tasks/b3f9a2c1d.output</output-file>\n\
    <status>completed</status>\n<summary>Background command \"air run\" completed (exit code 0)</summary>\n\
    </task-notification>";

#[test]
fn a_task_notification_becomes_a_background_task_notice() {
    let marker = task_notification_marker(NOTIFICATION).expect("a notification");
    assert_eq!(
        marker,
        "[System: background task b3f9a2c1d completed]\nBackground command \"air run\" completed \
         (exit code 0)"
    );
    assert_eq!(
        parse_system_message(&marker).expect("a notice"),
        notice(
            SystemMessageKind::TaskCompleted,
            "Background task completed",
            "Background command \"air run\" completed (exit code 0)"
        )
    );
    assert_eq!(
        task_notification_marker_content(&text(NOTIFICATION)).as_deref(),
        Some(marker.as_str())
    );
}

#[test]
fn a_notification_without_a_known_status_or_clean_id_still_reads() {
    let odd = "<task-notification><task-id>two words</task-id><status>Weird</status>\
               </task-notification>";
    assert_eq!(
        task_notification_marker(odd).as_deref(),
        Some("[System: background task unknown finished]")
    );
    assert_eq!(
        task_notification_marker("Explain <task-notification> markup."),
        None
    );
}

#[test]
fn notification_content_with_anything_else_is_no_notice() {
    let mut mixed = text(NOTIFICATION);
    mixed.extend(text("Please explain this."));
    assert_eq!(task_notification_marker_content(&mixed), None);
    let mut with_image = text(NOTIFICATION);
    with_image.push(image());
    assert_eq!(task_notification_marker_content(&with_image), None);
    // An agent's result is agent context, hidden rather than shown as a notice.
    assert_eq!(task_notification_marker_content(&text(RESULT)), None);
}

fn sent_by_automation(prompt: &str, note: &str, run_time: Option<&str>) -> String {
    let opening = AUTOMATION_CONTEXT_OPEN;
    let body = note.strip_prefix(opening).expect("note opens with its tag");
    let run_time = run_time.map(|line| format!("{line}\n")).unwrap_or_default();
    format!("{prompt}\n\n{opening}{run_time}{body}")
}

#[test]
fn the_automation_note_is_stripped_from_the_prompt_it_ends() {
    let run_time = "Run time: 2026-11-18T09:30:00Z (Unix time 1795080600).";
    let current = sent_by_automation(
        "Summarise the open issues.",
        AUTOMATION_CONTEXT_NOTE,
        Some(run_time),
    );
    assert_eq!(
        strip_automation_context(&current),
        "Summarise the open issues."
    );
    let untimed = sent_by_automation("Ship it.", AUTOMATION_CONTEXT_NOTE, None);
    assert_eq!(strip_automation_context(&untimed), "Ship it.");
    let earlier = sent_by_automation(
        "Ship it.",
        EARLIER_AUTOMATION_CONTEXT_NOTES[0],
        Some(run_time),
    );
    assert_eq!(
        strip_automation_context(&format!("{earlier}\n  ")),
        "Ship it."
    );
}

#[test]
fn anything_but_the_canonical_note_stays_visible() {
    let edited = sent_by_automation("Ship it.", AUTOMATION_CONTEXT_NOTE, None)
        .replace("no one is watching", "someone is watching");
    assert_eq!(strip_automation_context(&edited), edited);
    let inline = format!("Ship it. {AUTOMATION_CONTEXT_NOTE}");
    assert_eq!(strip_automation_context(&inline), inline);
    let bad_time = sent_by_automation(
        "Ship it.",
        AUTOMATION_CONTEXT_NOTE,
        Some("Run time: 2026-11-18 09:30 (Unix time 1)."),
    );
    assert_eq!(strip_automation_context(&bad_time), bad_time);
    assert_eq!(strip_automation_context("plain"), "plain");
}

#[test]
fn a_session_message_splits_its_sender_from_its_text() {
    assert_eq!(
        split_session_message_origin("[Message from session 9b8b_x-1]\nhi\nthere"),
        Some(SessionMessageOrigin {
            source_id: "9b8b_x-1",
            body: "hi\nthere"
        })
    );
    assert_eq!(
        split_session_message_origin("[Message from session abc]\r\nhi"),
        Some(SessionMessageOrigin {
            source_id: "abc",
            body: "hi"
        })
    );
    for text in [
        "[Message from session abc] hi",
        "[Message from session ]\nhi",
        "[Message from session a b]\nhi",
        "Re: [Message from session abc]\nhi",
    ] {
        assert_eq!(split_session_message_origin(text), None, "{text}");
    }
}
