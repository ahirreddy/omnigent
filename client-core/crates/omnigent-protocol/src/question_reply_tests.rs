//! Ports of the web client's `codexAsyncQuestionReply.test.ts`, with the edges its parse
//! decides: whitespace around the tags, entries without a question or answer, and ids that
//! aren't an async question's.

use serde_json::json;

use super::*;

fn item(index: i64) -> String {
    json!(["request_user_input_async", "call_abc", index]).to_string()
}

/// The tagged message the TUI and the question card send.
fn reply(entries: &Value) -> String {
    format!("<send_user_message_question_reply>\n{entries}\n</send_user_message_question_reply>")
}

fn answered(question: Option<&str>, answer: &str) -> QuestionReply {
    QuestionReply {
        question: question.map(str::to_owned),
        answer: answer.to_owned(),
    }
}

/// The web's `codexAsyncQuestionReplyText`: the replies as shown, or the text unchanged.
fn shown(text: &str) -> String {
    parse_question_replies(text)
        .map_or_else(|| text.to_owned(), |replies| question_reply_text(&replies))
}

#[test]
fn a_reply_shows_as_the_codex_tui_shows_it() {
    let text = reply(&json!([{"answer": "Blue", "question": "Color?", "questionItemId": item(0)}]));
    assert_eq!(
        parse_question_replies(&text),
        Some(vec![answered(Some("Color?"), "Blue")])
    );
    assert_eq!(shown(&text), "\u{21AA} Re: Color?\nBlue");
}

#[test]
fn each_answered_question_of_a_reply_shows() {
    let text = reply(&json!([
        {"answer": "Blue", "question": "Color?", "questionItemId": item(0)},
        {"answer": "Large", "questionItemId": item(1)},
    ]));
    assert_eq!(
        parse_question_replies(&text),
        Some(vec![
            answered(Some("Color?"), "Blue"),
            answered(None, "Large")
        ])
    );
    assert_eq!(shown(&text), "\u{21AA} Re: Color?\nBlue\n\nLarge");
}

#[test]
fn anything_but_a_well_formed_reply_stays_as_written() {
    let other_tool = r#"["other","call_abc",0]"#;
    let broken_id = r#"["request_user_input_async",broken"#;
    let cases = [
        ("ordinary text", "Use Blue".to_owned()),
        (
            "a reply quoted inside other text",
            format!(
                "Explain this: {}",
                reply(&json!([{"answer": "Blue", "questionItemId": item(0)}]))
            ),
        ),
        (
            "malformed JSON",
            "<send_user_message_question_reply>\n[{</send_user_message_question_reply>".to_owned(),
        ),
        (
            "an entry for another tool",
            reply(&json!([{"answer": "Blue", "questionItemId": other_tool}])),
        ),
        (
            "a malformed question id",
            reply(&json!([{"answer": "Blue", "questionItemId": broken_id}])),
        ),
        (
            "an entry whose answer is not text",
            reply(&json!([
                {"answer": "Blue", "question": "Color?", "questionItemId": item(0)},
                {"answer": {"text": "Large"}, "question": "Size?", "questionItemId": item(1)},
            ])),
        ),
        (
            "no answers",
            reply(&json!([{"answer": "", "questionItemId": item(0)}])),
        ),
    ];
    for (name, text) in cases {
        assert_eq!(parse_question_replies(&text), None, "{name}");
        assert_eq!(shown(&text), text, "{name}");
    }
}

#[test]
fn white_space_around_the_tags_and_the_json_is_ignored() {
    let entries = json!([{"answer": "Blue", "question": "Color?", "questionItemId": item(0)}]);
    let (open, close) = (OPEN, CLOSE);
    let expected = Some(vec![answered(Some("Color?"), "Blue")]);
    for text in [
        format!("{open}{entries}{close}"),
        format!("  \n{open}\t {entries} \r\n{close}\n\n"),
        // JavaScript's `\s` takes a no-break space, an ideographic space and a byte order mark.
        format!("\u{FEFF}{open}\u{A0}{entries}\u{3000}{close}\u{2028}"),
    ] {
        assert_eq!(parse_question_replies(&text), expected, "{text:?}");
    }
    // Its `\s` does not take U+0085.
    assert_eq!(
        parse_question_replies(&format!("{}\u{85}", reply(&entries))),
        None
    );
}

#[test]
fn answers_and_questions_show_exactly_as_written() {
    let text = reply(&json!([
        {"answer": "", "question": "Skipped?", "questionItemId": item(0)},
        {"answer": "  two\nlines ", "question": " Why? ", "questionItemId": item(1)},
        {"answer": "No question", "question": "", "questionItemId": item(2)},
    ]));
    assert_eq!(
        parse_question_replies(&text),
        Some(vec![
            answered(Some(" Why? "), "  two\nlines "),
            answered(None, "No question"),
        ]),
        "an empty answer is skipped, an empty question names none, white space stays"
    );
    assert_eq!(
        shown(&text),
        "\u{21AA} Re:  Why? \n  two\nlines \n\nNo question"
    );
}

#[test]
fn an_answer_may_hold_the_closing_tag() {
    let text = reply(&json!([{"answer": CLOSE, "questionItemId": item(0)}]));
    assert_eq!(
        parse_question_replies(&text),
        Some(vec![answered(None, CLOSE)])
    );
}

#[test]
fn every_entry_must_be_well_formed() {
    let malformed = [
        ("not an object", json!(["Blue"])),
        ("an array entry", json!([["Blue"]])),
        ("no question id", json!([{"answer": "Blue"}])),
        (
            "a null question",
            json!([{"answer": "Blue", "question": null, "questionItemId": item(0)}]),
        ),
        (
            "a question that isn't text",
            json!([{"answer": "Blue", "question": 3, "questionItemId": item(0)}]),
        ),
        (
            "a missing answer",
            json!([{"question": "Color?", "questionItemId": item(0)}]),
        ),
        (
            "a malformed entry after a good one",
            json!([{"answer": "Blue", "questionItemId": item(0)}, {"answer": "Large"}]),
        ),
        ("no entries", json!([])),
        (
            "an object, not a list",
            json!({"answer": "Blue", "questionItemId": item(0)}),
        ),
    ];
    for (name, entries) in malformed {
        assert_eq!(parse_question_replies(&reply(&entries)), None, "{name}");
    }
}

#[test]
fn an_id_is_json_text_naming_an_async_question() {
    // `Number.isInteger` takes any integer JavaScript reads.
    for id in [
        r#"["request_user_input_async","call_abc",0]"#,
        r#"["request_user_input_async","call_abc",-1]"#,
        r#"["request_user_input_async","call_abc",2.0]"#,
        r#"["request_user_input_async","call_abc",1e2]"#,
    ] {
        assert!(is_async_question_item_id(&json!(id)), "{id}");
    }
    for id in [
        json!(r#"["other","call_abc",0]"#),
        json!(r#"["request_user_input_async",broken"#),
        json!(r#"["request_user_input_async","",0]"#),
        json!(r#"["request_user_input_async","call_abc",0.5]"#),
        json!(r#"["request_user_input_async","call_abc","0"]"#),
        json!(r#"["request_user_input_async","call_abc"]"#),
        json!(r#"["request_user_input_async","call_abc",0,1]"#),
        json!(["request_user_input_async", "call_abc", 0]),
    ] {
        assert!(!is_async_question_item_id(&id), "{id}");
    }
}

#[test]
fn the_reply_the_forwarder_sends_parses() {
    // `_codex_async_question_reply_text` in the codex-native forwarder.
    let entry = json!({
        "answer": "Yes, I clicked Run",
        "question": "Did you click Run after signing in?",
        "questionItemId": r#"["request_user_input_async","call_9",0]"#,
    });
    let text = format!("{OPEN}\n[{entry}]\n{CLOSE}");
    assert_eq!(
        shown(&text),
        "\u{21AA} Re: Did you click Run after signing in?\nYes, I clicked Run"
    );
}
