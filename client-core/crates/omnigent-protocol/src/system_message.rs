//! Runtime text the server writes into user-role messages, as the web client classifies it.
//!
//! Ground truth: `web/src/lib/systemMessage.ts` and `web/src/lib/sessionMessageOrigin.ts`. The
//! runtime injects `[System: …]` notices (a task, timer or terminal event, a sub-agent's wake) as
//! user messages because chat formats have no mid-conversation system role; automations append a
//! note to the prompt they send; another session's message carries its sender's id; and Claude
//! Code mirrors task notifications and peer envelopes as user entries. None of it is the person's
//! own words.

use crate::content::{ContentPart, TextPartKind};

/// What a `[System: …]` notice reports (`SystemMessageKind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SystemMessageKind {
    /// A task completed.
    TaskCompleted,
    /// A task failed.
    TaskFailed,
    /// A task was cancelled.
    TaskCancelled,
    /// A timer fired.
    TimerFired,
    /// A terminal went idle.
    TerminalIdle,
    /// A sub-agent's result waits in the inbox: control traffic the web never shows.
    SubagentWake,
    /// An interrupt record.
    Interrupted,
    /// Any other `[System: …]` header.
    Generic,
}

impl SystemMessageKind {
    /// The web's `data-system-kind` name.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::TaskCompleted => "task_completed",
            Self::TaskFailed => "task_failed",
            Self::TaskCancelled => "task_cancelled",
            Self::TimerFired => "timer_fired",
            Self::TerminalIdle => "terminal_idle",
            Self::SubagentWake => "subagent_wake",
            Self::Interrupted => "interrupted",
            Self::Generic => "generic",
        }
    }
}

/// A parsed `[System: …]` notice (`ParsedSystemMessage`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SystemMessage {
    /// What it reports.
    pub kind: SystemMessageKind,
    /// A readable label without opaque ids, for example `Sub-agent t1 completed`.
    pub label: String,
    /// Everything after the header line; empty for headers without a body.
    pub body: String,
}

impl SystemMessage {
    fn new(kind: SystemMessageKind, label: impl Into<String>, body: &str) -> Self {
        Self {
            kind,
            label: label.into(),
            body: body.to_owned(),
        }
    }
}

const INTERRUPT_RECORDS: [&str; 2] = [
    "[Request interrupted by user]",
    "[Request interrupted by user for tool use]",
];
const HEADER_OPEN: &str = "[System: ";
const TASK_STATUSES: [&str; 3] = ["completed", "failed", "cancelled"];
const SUBAGENT_WAKE_TAIL: &str = " waiting in inbox. Call sys_read_inbox to collect.";

/// Parses a user message's text as a `[System: …]` notice (`parseSystemMessage`): its first
/// line must be exactly a header, or Claude Code's interrupt record.
#[must_use]
pub fn parse_system_message(text: &str) -> Option<SystemMessage> {
    let (first_line, body) = text.split_once('\n').unwrap_or((text, ""));
    if INTERRUPT_RECORDS.contains(&first_line) {
        return Some(SystemMessage::new(
            SystemMessageKind::Interrupted,
            "Interrupted",
            "",
        ));
    }
    let inner = first_line.strip_prefix(HEADER_OPEN)?.strip_suffix(']')?;
    // The web's `.+` stops at any line terminator.
    if inner.is_empty() || inner.contains(['\r', '\u{2028}', '\u{2029}']) {
        return None;
    }
    if inner == "interrupted" {
        return Some(SystemMessage::new(
            SystemMessageKind::Interrupted,
            "Interrupted",
            body,
        ));
    }
    Some(
        task_notice(inner, body)
            .or_else(|| background_task_notice(inner, body))
            .or_else(|| timer_notice(inner, body))
            .or_else(|| terminal_notice(inner))
            .or_else(|| subagent_wake(inner, body))
            .unwrap_or_else(|| SystemMessage::new(SystemMessageKind::Generic, inner, body)),
    )
}

/// `text` without the `[Attached: …]` markers a native executor adds for uploads, trimmed
/// (`withoutAttachedMarkers`): the text a notice's header is looked for in.
#[must_use]
pub fn without_attached_markers(text: &str) -> String {
    let mut kept = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find("[Attached") {
        let (before, marker) = rest.split_at_checked(at).unwrap_or((rest, ""));
        let label = marker.strip_prefix("[Attached");
        let after_colon = label.and_then(|label| {
            label
                .strip_prefix(':')
                .or_else(|| label.strip_prefix(" file:"))
        });
        let Some(after_marker) =
            after_colon.and_then(|after| after.find(']').and_then(|end| after.get(end + 1..)))
        else {
            kept.push_str(before);
            kept.push_str("[Attached");
            rest = marker.get("[Attached".len()..).unwrap_or_default();
            continue;
        };
        kept.push_str(before);
        rest = after_marker.trim_start();
    }
    kept.push_str(rest);
    kept.trim().to_owned()
}

/// `text` split at its first whitespace: the leading non-whitespace token (never empty) and the
/// rest, which starts at that whitespace.
fn token(text: &str) -> Option<(&str, &str)> {
    let end = text.find(char::is_whitespace).unwrap_or(text.len());
    let (token, rest) = text.split_at_checked(end)?;
    (!token.is_empty()).then_some((token, rest))
}

/// `task <id> (<tool|sub_agent|client_tool>) <completed|failed|cancelled>`.
fn task_notice(inner: &str, body: &str) -> Option<SystemMessage> {
    let (id, rest) = token(inner.strip_prefix("task ")?)?;
    let (kind, status) = rest.strip_prefix(" (")?.split_once(") ")?;
    let kind_label = match kind {
        "tool" => "Tool",
        "sub_agent" => "Sub-agent",
        "client_tool" => "Client tool",
        _ => return None,
    };
    let label = |verb: &str| format!("{kind_label} {id} {verb}");
    Some(match status {
        "completed" => {
            SystemMessage::new(SystemMessageKind::TaskCompleted, label("completed"), body)
        }
        "failed" => SystemMessage::new(SystemMessageKind::TaskFailed, label("failed"), body),
        "cancelled" => SystemMessage::new(SystemMessageKind::TaskCancelled, label("cancelled"), ""),
        _ => return None,
    })
}

/// `background task <id> <completed|failed|cancelled|finished>`, Claude's task notification as
/// [`task_notification_marker`] relabels it.
fn background_task_notice(inner: &str, body: &str) -> Option<SystemMessage> {
    let (_, rest) = token(inner.strip_prefix("background task ")?)?;
    let status = rest.strip_prefix(' ')?;
    let kind = match status {
        "completed" => SystemMessageKind::TaskCompleted,
        "failed" => SystemMessageKind::TaskFailed,
        "cancelled" => SystemMessageKind::TaskCancelled,
        "finished" => SystemMessageKind::Generic,
        _ => return None,
    };
    Some(SystemMessage::new(
        kind,
        format!("Background task {status}"),
        body,
    ))
}

/// `timer <id> fired`.
fn timer_notice(inner: &str, body: &str) -> Option<SystemMessage> {
    let (id, rest) = token(inner.strip_prefix("timer ")?)?;
    (rest == " fired").then(|| {
        SystemMessage::new(
            SystemMessageKind::TimerFired,
            format!("Timer {id} fired"),
            body,
        )
    })
}

/// `terminal <id> is idle`.
fn terminal_notice(inner: &str) -> Option<SystemMessage> {
    let (id, rest) = token(inner.strip_prefix("terminal ")?)?;
    (rest == " is idle").then(|| {
        SystemMessage::new(
            SystemMessageKind::TerminalIdle,
            format!("Terminal {id} idle"),
            "",
        )
    })
}

/// `sub-agent <name> finished (<status>) — <n> result(s) waiting in inbox. Call
/// sys_read_inbox to collect.`
fn subagent_wake(inner: &str, body: &str) -> Option<SystemMessage> {
    let rest = inner.strip_suffix(SUBAGENT_WAKE_TAIL)?;
    let rest = rest
        .strip_suffix("results")
        .or_else(|| rest.strip_suffix("result"))?
        .strip_suffix(' ')?;
    let digits = rest.len() - rest.trim_end_matches(|c: char| c.is_ascii_digit()).len();
    if digits == 0 {
        return None;
    }
    let rest = rest
        .get(..rest.len() - digits)?
        .strip_suffix(" \u{2014} ")?;
    let rest = rest.strip_suffix(')')?;
    let rest = TASK_STATUSES
        .iter()
        .find_map(|status| rest.strip_suffix(status))?
        .strip_suffix(" finished (")?;
    let name = rest.strip_prefix("sub-agent ")?;
    (!name.is_empty()).then(|| {
        SystemMessage::new(
            SystemMessageKind::SubagentWake,
            "Sub-agent result ready",
            body,
        )
    })
}

// Claude Code peer and team envelopes (`TEAMMATE_MESSAGE_RE`, `AGENT_MESSAGE_RE`).
const ENVELOPES: [(&str, &str); 2] = [
    ("teammate-message", "teammate_id"),
    ("agent-message", "from"),
];
const TEAMMATE_MESSAGE_PREFIXES: [&str; 3] = [
    "Another Claude session sent a message:\n",
    "Another Claude session sent a message while you were working:\n",
    "A peer session sent a message while you were working:\n",
];
const TEAMMATE_DELIVERY_GUIDANCE: [&str; 2] = [
    "This came from another Claude session \u{2014} not typed by your user,",
    "That \"other Claude session\" is an agent working inside this same session \u{2014}",
];

const fn is_word_char(character: char) -> bool {
    character.is_ascii_alphanumeric() || character == '_'
}

/// The length of the envelope `<tag … attribute="…" …>…</tag>` that `text` starts with.
fn envelope_len(text: &str, tag: &str, attribute: &str) -> Option<usize> {
    let after_tag = text.strip_prefix('<')?.strip_prefix(tag)?;
    if !after_tag.starts_with(char::is_whitespace) {
        return None;
    }
    let opened = text.len() - after_tag.len();
    let tag_end = after_tag.find('>').unwrap_or(after_tag.len());
    let head = after_tag.get(..tag_end)?;
    let needle = format!("{attribute}=\"");
    // The web's greedy `[^>]*` tries the last candidate first.
    let mut candidates: Vec<usize> = head.match_indices(&needle).map(|(at, _)| at).collect();
    candidates.reverse();
    let close = format!("</{tag}>");
    candidates.into_iter().find_map(|at| {
        let before = head.get(..at)?.chars().next_back()?;
        if is_word_char(before) {
            return None;
        }
        let value_start = at + needle.len();
        let value = after_tag.get(value_start..)?;
        let value_len = value.find('"')?;
        if value_len == 0 {
            return None;
        }
        let after_value = value_start + value_len + 1;
        let open_end = after_value + after_tag.get(after_value..)?.find('>')? + 1;
        let content_end = open_end + after_tag.get(open_end..)?.find(&close)? + close.len();
        Some(opened + content_end)
    })
}

fn leading_envelope_len(text: &str) -> Option<usize> {
    ENVELOPES
        .iter()
        .find_map(|(tag, attribute)| envelope_len(text, tag, attribute))
}

fn is_agent_message_text(text: &str) -> bool {
    if is_task_notification_text(text) {
        return summary_names_agent(text) || has_result(text);
    }
    let prefix = TEAMMATE_MESSAGE_PREFIXES
        .iter()
        .find(|prefix| text.starts_with(*prefix));
    let mut remaining = prefix.map_or(text, |prefix| {
        text.get(prefix.len()..).unwrap_or_default().trim_start()
    });
    let Some(mut length) = leading_envelope_len(remaining) else {
        return false;
    };
    loop {
        remaining = remaining.get(length..).unwrap_or_default().trim_start();
        if remaining.is_empty() {
            return true;
        }
        match leading_envelope_len(remaining) {
            Some(next) => length = next,
            None => break,
        }
    }
    // Peer wrappers can append native delivery instructions after the envelopes.
    prefix.is_some()
        && TEAMMATE_DELIVERY_GUIDANCE
            .iter()
            .any(|guidance| remaining.starts_with(guidance))
}

/// `<summary>\s*Agent\b`.
fn summary_names_agent(text: &str) -> bool {
    text.match_indices("<summary>").any(|(at, open)| {
        let after = text.get(at + open.len()..).unwrap_or_default().trim_start();
        after
            .strip_prefix("Agent")
            .is_some_and(|rest| !rest.starts_with(is_word_char))
    })
}

/// `<result>[\s\S]*</result>`.
fn has_result(text: &str) -> bool {
    text.find("<result>")
        .and_then(|at| text.get(at..))
        .is_some_and(|rest| rest.contains("</result>"))
}

/// The text blocks of a user message, when every block is text (`input_text` or a bare string).
fn input_texts(content: &[ContentPart]) -> Option<Vec<&str>> {
    content
        .iter()
        .map(|part| match part {
            ContentPart::Text {
                kind: TextPartKind::InputText | TextPartKind::Text,
                text,
            } => Some(text.as_str()),
            _ => None,
        })
        .collect()
}

/// True for Claude task or team context persisted without `is_meta`.
///
/// As `isClaudeAgentMessageContent`: every block is text, and each non-blank one is a peer or
/// teammate envelope, or a task notification about an agent's result.
#[must_use]
pub fn is_agent_message_content(content: &[ContentPart]) -> bool {
    let Some(texts) = input_texts(content) else {
        return false;
    };
    let texts: Vec<&str> = texts
        .into_iter()
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .collect();
    !texts.is_empty() && texts.into_iter().all(is_agent_message_text)
}

/// True for the whole `<task-notification>` block Claude Code injects when a background task
/// finishes (`isClaudeTaskNotificationText`).
#[must_use]
pub fn is_task_notification_text(text: &str) -> bool {
    let trimmed = text.trim();
    trimmed.starts_with("<task-notification>")
        && trimmed.ends_with("</task-notification>")
        && trimmed.len() >= "<task-notification></task-notification>".len()
        && trimmed.contains("<task-id>")
}

/// The text of the first `<tag>…</tag>` whose content has no `<`.
fn tagged(text: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    text.match_indices(&open).find_map(|(at, _)| {
        let rest = text.get(at + open.len()..)?;
        let (content, after) = rest.split_at_checked(rest.find('<')?)?;
        after.starts_with(&close).then(|| content.to_owned())
    })
}

/// A Claude task notification relabelled as a `[System: background task …]` notice, its summary
/// as the body (`claudeTaskNotificationMarker`); `None` for any other text.
#[must_use]
pub fn task_notification_marker(text: &str) -> Option<String> {
    if !is_task_notification_text(text) {
        return None;
    }
    let raw_id = tagged(text, "task-id").unwrap_or_default();
    let raw_id = raw_id.trim();
    let task_id = if raw_id.is_empty() || raw_id.contains(char::is_whitespace) {
        "unknown"
    } else {
        raw_id
    };
    let raw_status = tagged(text, "status").map(|status| status.trim().to_lowercase());
    let status = raw_status
        .as_deref()
        .filter(|status| TASK_STATUSES.contains(status))
        .unwrap_or("finished");
    let summary = text
        .find("<summary>")
        .and_then(|at| text.get(at + "<summary>".len()..))
        .and_then(|rest| rest.find("</summary>").and_then(|end| rest.get(..end)))
        .map(str::trim)
        .unwrap_or_default();
    let header = format!("[System: background task {task_id} {status}]");
    Some(if summary.is_empty() {
        header
    } else {
        format!("{header}\n{summary}")
    })
}

/// The notice a user message that is only Claude task notifications stands for
/// (`taskNotificationMarkerContent`); `None` for anything else, peer envelopes included.
#[must_use]
pub fn task_notification_marker_content(content: &[ContentPart]) -> Option<String> {
    let texts = input_texts(content)?;
    if is_agent_message_content(content)
        || !texts.iter().all(|text| is_task_notification_text(text))
    {
        return None;
    }
    texts.into_iter().find_map(task_notification_marker)
}

/// The note the server's automations append to the prompt they send (`UNATTENDED_RUN_NOTE` in
/// `omnigent/server/scheduled/fire.py`).
pub const AUTOMATION_CONTEXT_NOTE: &str = "<omnigent-automation-context>\nNote: an Omnigent automation sent this message, and no one is watching this run. No one can answer questions, approve requests or give input, so work toward the goal above on your own. Don't ask questions, wait for confirmation or stop to request permission. When something is unclear, make a reasonable assumption only if it is easy to reverse and within the user's authorization. Record each assumption, its basis and how easily it can be changed. For decisions that are hard to reverse, involve significant trade-offs or would likely surprise the user, record the options and your recommendation, and defer the affected work. Continue independent work that does not depend on those decisions. If an action is denied or requires unavailable approval, skip that action and explain the blocker. Continue independent work and permitted alternatives. Do not change permission settings to get past the restriction. If you have the sys_journal tools, start by reading your journal with sys_journal_read; if the session has no plan, write one with sys_journal_write_plan (one step is fine); and before your final reply, write a status for each step you worked on with sys_journal_write_status. Lead your final reply with unresolved decisions and assumptions, prioritizing those the user is most likely to want to change, then summarize what you did and anything you couldn't do.\n</omnigent-automation-context>";

/// Notes earlier servers sent, still at the end of the messages that carried them.
pub const EARLIER_AUTOMATION_CONTEXT_NOTES: &[&str] = &[
    "<omnigent-automation-context>\nNote: an Omnigent automation sent this message, and no one is watching this run. No one can answer questions, approve requests or give input, so work toward the goal above on your own. Don't ask questions, wait for confirmation or stop to request permission. When something is unclear, make a reasonable assumption only if it is easy to reverse and within the user's authorization. Record each assumption, its basis and how easily it can be changed. For decisions that are hard to reverse, involve significant trade-offs or would likely surprise the user, record the options and your recommendation, and defer the affected work. Continue independent work that does not depend on those decisions. If an action is denied or requires unavailable approval, skip that action and explain the blocker. Continue independent work and permitted alternatives. Do not change permission settings to get past the restriction. Lead your final reply with unresolved decisions and assumptions, prioritizing those the user is most likely to want to change, then summarize what you did and anything you couldn't do.\n</omnigent-automation-context>",
];

const AUTOMATION_CONTEXT_OPEN: &str = "<omnigent-automation-context>\n";

/// Whether `line` is `Run time: YYYY-MM-DDTHH:MM:SSZ (Unix time N).`, as the note opens.
fn is_run_time_line(line: &str) -> bool {
    let Some(rest) = line.strip_prefix("Run time: ") else {
        return false;
    };
    let Some((stamp, rest)) = rest.split_at_checked("0000-00-00T00:00:00Z".len()) else {
        return false;
    };
    let shape_matches =
        stamp
            .chars()
            .zip("0000-00-00T00:00:00Z".chars())
            .all(|(character, shape)| {
                if shape == '0' {
                    character.is_ascii_digit()
                } else {
                    character == shape
                }
            });
    let seconds = rest
        .strip_prefix(" (Unix time ")
        .and_then(|rest| rest.strip_suffix(")."));
    shape_matches
        && seconds
            .is_some_and(|digits| !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()))
}

/// `head` without the note's opening (`\n\n<omnigent-automation-context>\n`, then the run time
/// line when it has one) at its end; `None` when it does not end with one.
fn without_note_opening(head: &str) -> Option<&str> {
    let marker = format!("\n\n{AUTOMATION_CONTEXT_OPEN}");
    if let Some(prompt) = head.strip_suffix(&marker) {
        return Some(prompt);
    }
    let line = head.strip_suffix('\n')?;
    let at = line.rfind(&marker)?;
    let (prompt, opening) = line.split_at_checked(at)?;
    is_run_time_line(opening.get(marker.len()..)?).then_some(prompt)
}

/// `text` without the automation note at its end (`stripAutomationContext`). Only a canonical
/// note is hidden; anything else inside matching tags stays visible.
#[must_use]
pub fn strip_automation_context(text: &str) -> &str {
    let trimmed = text.trim_end();
    for note in std::iter::once(&AUTOMATION_CONTEXT_NOTE).chain(EARLIER_AUTOMATION_CONTEXT_NOTES) {
        let Some(body) = note.strip_prefix(AUTOMATION_CONTEXT_OPEN) else {
            continue;
        };
        if let Some(prompt) = trimmed.strip_suffix(body).and_then(without_note_opening) {
            return prompt;
        }
    }
    text
}

/// A message another session sent with `sys_session_message`: its sender and its text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionMessageOrigin<'a> {
    /// The sending session's id.
    pub source_id: &'a str,
    /// The message without its sender line.
    pub body: &'a str,
}

/// Splits the `[Message from session <id>]` line the server writes before a message another
/// session sent (`splitSessionMessageOrigin`). The line is a display label, not proof of
/// origin.
#[must_use]
pub fn split_session_message_origin(text: &str) -> Option<SessionMessageOrigin<'_>> {
    let rest = text.strip_prefix("[Message from session ")?;
    let (source_id, rest) = rest.split_once(']')?;
    let valid = !source_id.is_empty()
        && source_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    let body = rest
        .strip_prefix("\r\n")
        .or_else(|| rest.strip_prefix('\n'))?;
    valid.then_some(SessionMessageOrigin { source_id, body })
}

#[cfg(test)]
#[path = "system_message_tests.rs"]
mod tests;
