//! Every question kind the other harnesses (Pi, Cursor, Copilot, Antigravity and the native
//! harnesses) ask, from `fixtures/decisions/<Harness>--*.json`: the card for the elicitation the
//! server publishes and the exact answer the app posts for it. The server side of each fixture is
//! tested with the mapping that builds it (see the fixture README).

use std::collections::BTreeMap;

use omnigent_protocol::{ElicitationRequest, ElicitationValue, FromWire};
use serde_json::{Value, json};

use super::*;
use crate::client::test_support::fixture_json;

/// The card for `{name}.json` and the answer the app posts.
fn harness(name: &str) -> (Decision, Value) {
    let fixture = fixture_json(&format!("decisions/{name}.json"));
    let request = ElicitationRequest::from_value(fixture["elicitation"].clone()).unwrap();
    (
        Decision::from_request(&request, "conv_a"),
        fixture["answer"].clone(),
    )
}

/// The JSON the app posts for `response`.
fn posted(card: &Decision, response: &DecisionResponse) -> Value {
    serde_json::to_value(card.result_for(response).unwrap()).unwrap()
}

fn answers(value: Value) -> BTreeMap<String, ElicitationValue> {
    serde_json::from_value(value).unwrap()
}

/// The fixture's answer, as the form response that posts it.
fn form_response(answer: &Value) -> DecisionResponse {
    DecisionResponse::Form(answers(answer["content"].clone()))
}

fn only_field(card: &Decision) -> &FormField {
    let form = card.form().unwrap_or_else(|| panic!("not a form: {:?}", card.kind));
    assert_eq!(form.fields.len(), 1);
    &form.fields[0]
}

// --- Pi extension UI (SDK `pi` and `pi-native`) ------------------------------------------------

#[test]
fn pi_confirm_is_a_binary_approval() {
    let (card, answer) = harness("Pi--Confirm");
    assert_eq!(card.kind, DecisionKind::Approval);
    assert_eq!(
        card.message.as_deref(),
        Some("Clear the session?\n\nAll messages will be lost.")
    );
    assert_eq!(posted(&card, &DecisionResponse::Approve), answer);
    assert_eq!(
        posted(&card, &DecisionResponse::Decline),
        json!({"action": "decline"})
    );
}

#[test]
fn pi_select_takes_only_its_labels() {
    let (card, answer) = harness("Pi--Select");
    let field = only_field(&card);
    assert_eq!(
        (field.key.as_str(), field.kind, field.allows_custom),
        ("0", FieldKind::SingleChoice, false)
    );
    let labels: Vec<&str> = field.options.iter().map(|option| option.label.as_str()).collect();
    assert_eq!(labels, ["Allow", "Allow once", "Block"]);
    assert_eq!(posted(&card, &form_response(&answer)), answer);
    assert_eq!(
        card.result_for(&DecisionResponse::Form(answers(json!({"0": "Allow always"})))),
        Err(DecisionError::InvalidAnswer(AnswerError::NotAnOption {
            field: field.title.clone()
        }))
    );
}

#[test]
fn pi_input_is_a_required_text_field_with_its_placeholder() {
    let (card, answer) = harness("Pi--Input");
    let field = only_field(&card);
    assert_eq!(
        (field.kind, field.required, field.exact_text),
        (FieldKind::Text, true, false)
    );
    assert_eq!(field.detail, "release/x.y");
    assert_eq!(posted(&card, &form_response(&answer)), answer);
    assert_eq!(
        card.result_for(&DecisionResponse::Form(answers(json!({"0": " "})))),
        Err(DecisionError::InvalidAnswer(AnswerError::Missing {
            field: field.title.clone()
        }))
    );
}

#[test]
fn pi_editor_answers_with_its_exact_text_even_when_cleared() {
    let (card, answer) = harness("Pi--Editor");
    let field = only_field(&card);
    assert!(field.exact_text, "an editor keeps its exact text");
    assert_eq!(
        field.default_value,
        Some(ElicitationValue::Text(
            "Fixes\n\n- Keep the cache warm\n".to_owned()
        ))
    );
    // Clearing the editor is an answer, as Pi takes it.
    assert_eq!(posted(&card, &form_response(&answer)), answer);
    let kept = DecisionResponse::Form(answers(json!({"0": "  Fixes\n"})));
    assert_eq!(
        posted(&card, &kept),
        json!({"action": "accept", "content": {"0": "  Fixes\n"}})
    );
    assert_eq!(
        card.result_for(&DecisionResponse::Form(BTreeMap::new())),
        Err(DecisionError::InvalidAnswer(AnswerError::Missing {
            field: field.title.clone()
        })),
        "the editor still needs an answer"
    );
}

#[test]
fn an_empty_editor_prefill_is_kept_as_its_starting_answer() {
    let form = DecisionForm::from_questions(&json!({"questions": [{
        "id": "0", "question": "Notes", "options": [], "isOther": true,
        "textInput": {"default": ""},
    }]}))
    .unwrap();
    assert_eq!(
        form.fields[0].default_value,
        Some(ElicitationValue::Text(String::new()))
    );
    let plain = DecisionForm::from_questions(&json!({"questions": [{
        "question": "Notes", "options": [], "isOther": true, "textInput": "not an editor",
    }]}))
    .unwrap();
    assert!(!plain.fields[0].exact_text, "only a textInput object is an editor");
}
