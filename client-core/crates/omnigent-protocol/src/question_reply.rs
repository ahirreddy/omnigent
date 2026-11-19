//! A reply to a Codex async question, as the web client shows it.
//!
//! Ground truth: `web/src/lib/codexAsyncQuestionReply.ts`. Answering a Codex
//! `request_user_input_async` question sends a user message holding only
//! `<send_user_message_question_reply>[{"answer":"Blue","question":"Color?","questionItemId":…}]</send_user_message_question_reply>`,
//! which the server's codex-native forwarder reads back. The web shows each answered question as
//! the Codex TUI does, `↪ Re: <question>` over the answer; anything malformed stays as written.

use serde_json::{Map, Value};

/// One answered question of a reply.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct QuestionReply {
    /// The question answered, when the entry names a non-empty one.
    pub question: Option<String>,
    /// The answer; never empty.
    pub answer: String,
}

const OPEN: &str = "<send_user_message_question_reply>";
const CLOSE: &str = "</send_user_message_question_reply>";
const ASYNC_QUESTION_TOOL: &str = "request_user_input_async";
/// What the web puts before each answered question.
const QUOTE_PREFIX: &str = "\u{21AA} Re: ";

/// JavaScript's `\s`: its line terminators and white space (`Zs`, tabs and the byte order mark).
const fn is_js_whitespace(character: char) -> bool {
    let line_terminator = matches!(character, '\n' | '\r' | '\u{2028}' | '\u{2029}');
    let space = matches!(
        character,
        '\t' | '\u{B}' | '\u{C}' | ' ' | '\u{A0}' | '\u{1680}'
    );
    let wide = matches!(
        character,
        '\u{2000}'..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    );
    line_terminator || space || wide || character == '\u{FEFF}'
}

/// The answered questions of a user message that is only a well-formed reply
/// (`codexAsyncQuestionReplyText`), in order; `None` for any other text.
///
/// Every entry must be an object whose `questionItemId` names an async question
/// (`'["request_user_input_async","call_abc",0]'`), whose `answer` is text and whose
/// `question`, when present, is text. Entries with an empty answer are skipped; a reply with no
/// answer at all is `None`.
#[must_use]
pub fn parse_question_replies(text: &str) -> Option<Vec<QuestionReply>> {
    let inner = text
        .trim_matches(is_js_whitespace)
        .strip_prefix(OPEN)?
        .strip_suffix(CLOSE)?
        .trim_matches(is_js_whitespace);
    // Malformed JSON is ordinary text, as on the web.
    let Ok(Value::Array(entries)) = serde_json::from_str::<Value>(inner) else {
        return None;
    };
    let mut replies = Vec::new();
    for entry in &entries {
        let Value::Object(entry) = entry else {
            return None;
        };
        let reply = entry_reply(entry)?;
        if !reply.answer.is_empty() {
            replies.push(reply);
        }
    }
    (!replies.is_empty()).then_some(replies)
}

/// One entry's reply, its answer possibly empty; `None` when the entry is malformed.
fn entry_reply(entry: &Map<String, Value>) -> Option<QuestionReply> {
    if !entry
        .get("questionItemId")
        .is_some_and(is_async_question_item_id)
    {
        return None;
    }
    let Some(Value::String(answer)) = entry.get("answer") else {
        return None;
    };
    let question = match entry.get("question") {
        None => None,
        Some(Value::String(question)) => (!question.is_empty()).then(|| question.clone()),
        Some(_) => return None,
    };
    Some(QuestionReply {
        question,
        answer: answer.clone(),
    })
}

/// Whether `id` is a JSON string naming an async question, for example
/// `'["request_user_input_async","call_abc",0]'` (`isAsyncQuestionItemId`).
fn is_async_question_item_id(id: &Value) -> bool {
    let Value::String(id) = id else {
        return false;
    };
    // An id that isn't JSON names no async question.
    let Ok(Value::Array(parts)) = serde_json::from_str::<Value>(id) else {
        return false;
    };
    match parts.as_slice() {
        [
            Value::String(tool),
            Value::String(call_id),
            Value::Number(index),
        ] => tool == ASYNC_QUESTION_TOOL && !call_id.is_empty() && is_integer(index),
        _ => false,
    }
}

/// JavaScript's `Number.isInteger`: `2` and `2.0` are, `2.5` is not.
fn is_integer(number: &serde_json::Number) -> bool {
    number.is_i64()
        || number.is_u64()
        || number
            .as_f64()
            .is_some_and(|value| value.is_finite() && value.fract() == 0.0)
}

/// The replies as the web shows them: `↪ Re: <question>` over each answer, or the answer alone
/// when it names no question, a blank line apart.
#[must_use]
pub fn question_reply_text(replies: &[QuestionReply]) -> String {
    replies
        .iter()
        .map(|reply| {
            reply.question.as_ref().map_or_else(
                || reply.answer.clone(),
                |question| format!("{QUOTE_PREFIX}{question}\n{}", reply.answer),
            )
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

#[cfg(test)]
#[path = "question_reply_tests.rs"]
mod tests;
