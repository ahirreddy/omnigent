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
    let form = card
        .form()
        .unwrap_or_else(|| panic!("not a form: {:?}", card.kind));
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
    let labels: Vec<&str> = field
        .options
        .iter()
        .map(|option| option.label.as_str())
        .collect();
    assert_eq!(labels, ["Allow", "Allow once", "Block"]);
    assert_eq!(posted(&card, &form_response(&answer)), answer);
    assert_eq!(
        card.result_for(&DecisionResponse::Form(answers(
            json!({"0": "Allow always"})
        ))),
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
    assert!(
        !plain.fields[0].exact_text,
        "only a textInput object is an editor"
    );
}

// --- Questions from native harnesses -----------------------------------------------------------

#[test]
fn devin_questions_answer_under_their_text_with_typed_answers() {
    let (card, answer) = harness("Devin--AskUserQuestion");
    let form = card.form().unwrap();
    let shapes: Vec<(&str, FieldKind, bool)> = form
        .fields
        .iter()
        .map(|field| (field.key.as_str(), field.kind, field.allows_custom))
        .collect();
    assert_eq!(
        shapes,
        [
            (
                "Which color should the demo use?",
                FieldKind::SingleChoice,
                true
            ),
            (
                "Which features should the demo include?",
                FieldKind::MultipleChoice,
                true
            ),
        ]
    );
    assert_eq!(form.fields[0].options[0].detail, "A calm, classic color.");
    assert_eq!(posted(&card, &form_response(&answer)), answer);
}

#[test]
fn cursor_questions_answer_under_their_ids() {
    let (card, answer) = harness("Cursor--AskQuestion");
    assert_eq!(card.message.as_deref(), Some("Pick a stack"));
    let form = card.form().unwrap();
    let keys: Vec<(&str, FieldKind)> = form
        .fields
        .iter()
        .map(|field| (field.key.as_str(), field.kind))
        .collect();
    assert_eq!(
        keys,
        [
            ("lang", FieldKind::SingleChoice),
            ("extras", FieldKind::MultipleChoice)
        ]
    );
    assert_eq!(posted(&card, &form_response(&answer)), answer);
}

#[test]
fn antigravity_questions_take_choices_and_write_ins() {
    let (card, answer) = harness("Antigravity--AskQuestion");
    let form = card.form().unwrap();
    let shapes: Vec<(&str, FieldKind, usize)> = form
        .fields
        .iter()
        .map(|field| (field.key.as_str(), field.kind, field.options.len()))
        .collect();
    assert_eq!(
        shapes,
        [
            ("0", FieldKind::MultipleChoice, 2),
            ("1", FieldKind::Text, 0)
        ]
    );
    assert_eq!(posted(&card, &form_response(&answer)), answer);
}

#[test]
fn antigravity_permission_offers_its_always_allow_pattern() {
    let (card, answer) = harness("Antigravity--Permission");
    assert_eq!(card.kind, DecisionKind::Approval);
    assert_eq!(
        card.permissions
            .command
            .as_ref()
            .map(|command| command.command.as_str()),
        Some("pwd")
    );
    assert!(card.permissions.offers_persist(PersistMode::Always));
    assert_eq!(
        posted(
            &card,
            &DecisionResponse::ApprovePersist(PersistMode::Session)
        ),
        answer
    );
}

// --- SDK harness permissions -------------------------------------------------------------------

#[test]
fn copilot_permission_is_an_approval_showing_the_request() {
    let (card, answer) = harness("Copilot--PermissionRequest--Shell");
    assert_eq!(card.kind, DecisionKind::Approval);
    assert_eq!(
        card.message.as_deref(),
        Some("Copilot wants to use **shell**")
    );
    assert!(
        card.tool_input
            .as_deref()
            .is_some_and(|input| input.contains("ls -la")),
        "{:?}",
        card.tool_input
    );
    assert_eq!(posted(&card, &DecisionResponse::Approve), answer);
}

#[test]
fn acp_permission_options_are_a_choice() {
    let (card, answer) = harness("Acp--RequestPermission--Choice");
    assert_eq!(
        card.kind,
        DecisionKind::Choice {
            answer_key: "answer".to_owned(),
            options: vec![
                "Allow".to_owned(),
                "Yes, allow `ls` commands (this session)".to_owned(),
                "Reject".to_owned(),
            ],
        }
    );
    assert_eq!(
        posted(
            &card,
            &DecisionResponse::Answer("Yes, allow `ls` commands (this session)".to_owned())
        ),
        answer
    );
}

// --- OpenCode forms (`form.created`) -----------------------------------------------------------

#[test]
fn opencode_form_shows_every_field_type_with_its_answers() {
    let (card, answer) = harness("OpenCode--FormEveryField");
    assert_eq!(card.unsupported_reason(), None);
    let form = card.form().unwrap();
    let shapes: Vec<(&str, FieldKind, bool)> = form
        .fields
        .iter()
        .map(|field| (field.key.as_str(), field.kind, field.allows_custom))
        .collect();
    assert_eq!(
        shapes,
        [
            ("channel", FieldKind::SingleChoice, true),
            ("platforms", FieldKind::MultipleChoice, true),
            ("notify", FieldKind::SingleChoice, false),
            ("build", FieldKind::Text, false),
            ("notes", FieldKind::Text, false),
            ("signin", FieldKind::SingleChoice, false),
        ]
    );
    assert_eq!(posted(&card, &form_response(&answer)), answer);
    let mut maybe = answers(answer["content"].clone());
    maybe.insert(
        "notify".to_owned(),
        ElicitationValue::Text("Maybe".to_owned()),
    );
    assert_eq!(
        card.result_for(&DecisionResponse::Form(maybe)),
        Err(DecisionError::InvalidAnswer(AnswerError::NotAnOption {
            field: "Tell the testers?".to_owned()
        })),
        "a yes/no field takes only Yes or No"
    );
}

// --- Kiro native delivery ----------------------------------------------------------------------

#[test]
fn kiro_answers_name_the_delivery_attempt() {
    let (card, answer) = harness("Kiro--NativePermission--Ready");
    assert_eq!(card.kind, DecisionKind::Approval);
    assert_eq!(card.title, "Approval requested");
    assert_eq!(posted(&card, &DecisionResponse::Approve), answer);
    assert_eq!(
        posted(&card, &DecisionResponse::Decline),
        json!({"action": "decline",
               "_meta": {"native_delivery_attempt": "0f9e8d7c6b5a49382716051423324150"}})
    );
}

#[test]
fn kiro_sending_offers_nothing_and_unconfirmed_resends_only_its_verdict() {
    let fixture = fixture_json("decisions/Kiro--NativePermission--Unconfirmed.json");
    let sending = Decision::from_request(
        &ElicitationRequest::from_value(fixture["sending"].clone()).unwrap(),
        "conv_a",
    );
    assert_eq!(sending.title, "Waiting for the agent to confirm");
    for response in [
        DecisionResponse::Approve,
        DecisionResponse::Decline,
        DecisionResponse::Cancel,
    ] {
        assert_eq!(
            sending.result_for(&response),
            Err(DecisionError::NotOffered),
            "{response:?}"
        );
    }
    let (unconfirmed, answer) = harness("Kiro--NativePermission--Unconfirmed");
    assert_eq!(unconfirmed.title, "Approval delivery unconfirmed");
    assert!(unconfirmed.awaits_redelivery());
    assert_eq!(posted(&unconfirmed, &DecisionResponse::Decline), answer);
    assert_eq!(
        unconfirmed.result_for(&DecisionResponse::Approve),
        Err(DecisionError::NotOffered),
        "the verdict cannot change while it is being delivered"
    );
}

#[test]
fn an_unconfirmed_delivery_reopens_an_answered_card_for_a_retry() {
    let fixture = fixture_json("decisions/Kiro--NativePermission--Unconfirmed.json");
    let request = |key: &str| ElicitationRequest::from_value(fixture[key].clone()).unwrap();
    let ready = ElicitationRequest::from_value(
        fixture_json("decisions/Kiro--NativePermission--Ready.json")["elicitation"].clone(),
    )
    .unwrap();
    let mut decisions = SessionDecisions::new("conv_a");
    assert_eq!(decisions.apply_request(&ready), RequestOutcome::Added);
    decisions
        .record_answered(&ready.elicitation_id, DecisionResponse::Decline)
        .unwrap();
    // The answer being delivered keeps the card answered.
    assert_eq!(
        decisions.apply_request(&request("sending")),
        RequestOutcome::Stale
    );
    assert!(!decisions.needs_response());
    assert_eq!(
        decisions.apply_request(&request("elicitation")),
        RequestOutcome::Replaced
    );
    assert!(decisions.needs_response());
}

#[test]
fn a_malformed_native_delivery_is_ignored() {
    for delivery in [
        json!({"state": "ready", "attempt": ""}),
        json!({"state": "paused", "attempt": "a1"}),
        json!({"state": "sending", "attempt": "a1"}),
        json!({"state": "unconfirmed", "attempt": "a1", "action": "later"}),
        json!("ready"),
    ] {
        let request = ElicitationRequest::from_value(json!({
            "elicitation_id": "e1",
            "params": {"message": "Approve?", "native_delivery": delivery},
        }))
        .unwrap();
        let card = Decision::from_request(&request, "conv_a");
        assert_eq!(card.permissions.native_delivery, None, "{delivery}");
        assert_eq!(
            posted(&card, &DecisionResponse::Approve),
            json!({"action": "accept"})
        );
    }
}
