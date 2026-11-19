//! What Omnigent's own agents ask (`fixtures/decisions/Omni--*.json`) and every kind of request a
//! sub-agent's session mirrors into its parent (`Subagent--MirroredRequests.json`): the card, and
//! the exact answer the app posts, to the session that owns the request.

use std::collections::BTreeMap;

use omnigent_protocol::{ElicitationRequest, ElicitationValue, FromWire, ServerStreamEvent};
use serde_json::{Value, json};

use super::*;
use crate::auth::endpoint::ServerEndpoint;
use crate::client::test_support::fixture_json;

/// The card for `{name}.json` carried by `conv_a`, and the answer the app posts.
fn omni(name: &str) -> (Decision, Value) {
    let fixture = fixture_json(&format!("decisions/{name}.json"));
    (
        card(&fixture["elicitation"], "conv_a"),
        fixture["answer"].clone(),
    )
}

fn card(elicitation: &Value, carrying_session: &str) -> Decision {
    Decision::from_request(
        &ElicitationRequest::from_value(elicitation.clone()).unwrap(),
        carrying_session,
    )
}

fn posted(card: &Decision, response: &DecisionResponse) -> Value {
    serde_json::to_value(card.result_for(response).unwrap()).unwrap()
}

fn form_response(answer: &Value) -> DecisionResponse {
    DecisionResponse::Form(serde_json::from_value(answer["content"].clone()).unwrap())
}

// --- Policy ASKs -------------------------------------------------------------------------------

#[test]
fn a_tool_call_policy_ask_is_an_inline_approval_not_a_page() {
    let (card, answer) = omni("Omni--PolicyAsk--ToolCall");
    // The `/approve/` page is the web's own approval route, so the card is answered here.
    assert_eq!(card.kind, DecisionKind::Approval);
    assert_eq!(card.external_url(), None);
    assert_eq!(
        card.policy_name.as_deref(),
        Some("__ask_on_scheduled_task_change")
    );
    assert!(
        card.message
            .as_deref()
            .is_some_and(|message| message.contains("> Check the deploy")),
        "the whole reminder text is shown"
    );
    assert_eq!(posted(&card, &DecisionResponse::Approve), answer);
}

#[test]
fn held_policy_gates_for_tools_and_messages_are_approvals() {
    let fixture = fixture_json("decisions/Omni--PolicyAsk--HeldGate.json");
    for key in ["elicitation", "request_phase"] {
        let card = card(&fixture[key], "conv_a");
        assert_eq!(card.kind, DecisionKind::Approval, "{key}");
        assert_eq!(posted(&card, &DecisionResponse::Decline), fixture["answer"]);
    }
    let gate = card(&fixture["elicitation"], "conv_a");
    assert_eq!(
        gate.tool_input
            .as_deref()
            .map(|input| input.contains("gh pr merge 12")),
        Some(true)
    );
    assert!(!gate.accepts_feedback(), "a policy gate drops feedback");
}

// --- MCP servers -------------------------------------------------------------------------------

#[test]
fn an_mcp_form_request_is_a_typed_form() {
    let (card, answer) = omni("Omni--McpElicitation--Form");
    let form = card.form().unwrap();
    let kinds: Vec<(&str, FieldKind, bool)> = form
        .fields
        .iter()
        .map(|field| (field.key.as_str(), field.kind, field.required))
        .collect();
    assert_eq!(
        kinds,
        [
            ("environment", FieldKind::SingleChoice, true),
            ("notify", FieldKind::Boolean, false)
        ]
    );
    assert_eq!(
        form.fields[1].default_value,
        Some(ElicitationValue::Bool(true))
    );
    assert_eq!(posted(&card, &form_response(&answer)), answer);
}

#[test]
fn a_python_mcp_servers_optional_fields_are_optional_native_fields() {
    let (card, answer) = omni("Omni--McpElicitation--OptionalFields");
    let form = card.form().unwrap_or_else(|| panic!("{:?}", card.kind));
    let shapes: Vec<(&str, FieldKind, bool, Option<ElicitationValue>)> = form
        .fields
        .iter()
        .map(|field| {
            (
                field.key.as_str(),
                field.kind,
                field.required,
                field.default_value.clone(),
            )
        })
        .collect();
    assert_eq!(
        shapes,
        [
            ("attempts", FieldKind::Integer, false, None),
            (
                "channel",
                FieldKind::SingleChoice,
                false,
                Some(ElicitationValue::Text("beta".to_owned()))
            ),
            (
                "hotfix",
                FieldKind::Boolean,
                false,
                Some(ElicitationValue::Bool(false))
            ),
            ("notes", FieldKind::Text, false, None),
            ("version", FieldKind::Text, true, None),
        ]
    );
    let attempts = &form.fields[0];
    assert_eq!(
        (attempts.title.as_str(), attempts.minimum),
        ("Attempts", Some(1.0))
    );
    assert_eq!(
        form.fields[1]
            .options
            .iter()
            .map(|option| option.value.as_str())
            .collect::<Vec<_>>(),
        ["beta"]
    );
    assert_eq!(posted(&card, &form_response(&answer)), answer);
    // The `anyOf` branch's own constraint still holds.
    let below = DecisionResponse::Form(BTreeMap::from([
        (
            "version".to_owned(),
            ElicitationValue::Text("2.4.0".to_owned()),
        ),
        ("attempts".to_owned(), ElicitationValue::Integer(0)),
    ]));
    assert!(matches!(
        card.result_for(&below),
        Err(DecisionError::InvalidAnswer(
            AnswerError::BelowMinimum { .. }
        ))
    ));
}

#[test]
fn an_mcp_url_request_is_a_page_to_complete() {
    let (card, answer) = omni("Omni--McpElicitation--Url");
    assert_eq!(
        card.kind,
        DecisionKind::ExternalPage {
            url: "https://tracker.example.com/oauth/consent?request=42".to_owned()
        }
    );
    assert_eq!(card.title, "Action required");
    assert_eq!(posted(&card, &DecisionResponse::Approve), answer);
}

// --- Workflow questions ------------------------------------------------------------------------

#[test]
fn a_workflow_question_answers_under_its_text_with_the_recommendation_first() {
    let (card, answer) = omni("Omni--WorkflowRequestInput");
    assert_eq!(card.title, "Response requested");
    let form = card.form().unwrap();
    let keys: Vec<&str> = form.fields.iter().map(|field| field.key.as_str()).collect();
    assert_eq!(
        keys,
        [
            "Which profiles should the migration cover?",
            "When should it run?"
        ]
    );
    let first = &form.fields[0];
    assert_eq!(
        (first.kind, first.allows_custom, first.detail.as_str()),
        (FieldKind::SingleChoice, true, "Profiles")
    );
    assert_eq!(first.options[0].label, "Only prod (recommended)");
    assert_eq!(first.options[1].detail, "Run against every profile.");
    // A typed answer is allowed, as the web form allows it.
    assert_eq!(posted(&card, &form_response(&answer)), answer);
}

// --- Sub-agents --------------------------------------------------------------------------------

/// The response that posts `answer` for the mirrored request labelled `label`.
fn mirrored_response(label: &str, answer: &Value) -> DecisionResponse {
    match label {
        "codex-request-user-input" | "pi-editor" => form_response(answer),
        "omni-policy-ask" => DecisionResponse::Decline,
        "mcp-url" | "kiro-unconfirmed" => DecisionResponse::Approve,
        "agy-permission" => DecisionResponse::ApprovePersist(PersistMode::Always),
        other => panic!("no response for {other}"),
    }
}

#[test]
fn every_mirrored_request_is_answered_from_the_parent_on_the_child() {
    let fixture = fixture_json("decisions/Subagent--MirroredRequests.json");
    let endpoint = ServerEndpoint::new("http://127.0.0.1:6767").unwrap();
    let requests = fixture["requests"].as_array().unwrap();
    assert_eq!(requests.len(), 6);
    for entry in requests {
        let label = entry["label"].as_str().unwrap();
        let card = card(&entry["elicitation"], "conv_parent");
        assert_eq!(card.unsupported_reason(), None, "{label}");
        assert_eq!(card.target_session_id, "conv_child", "{label}");
        assert!(card.targets_other_session(), "{label}");
        let request = card
            .resolve_request(&mirrored_response(label, &entry["answer"]))
            .unwrap_or_else(|error| panic!("{label}: {error}"));
        let http = request
            .http_request(&endpoint, None, ResolveRoute::Dedicated)
            .unwrap();
        assert_eq!(
            http.url,
            format!(
                "http://127.0.0.1:6767/v1/sessions/conv_child/elicitations/{}/resolve",
                card.id
            ),
            "{label}"
        );
        let body: Value = serde_json::from_slice(&http.body.unwrap()).unwrap();
        assert_eq!(body, entry["answer"], "{label}");
    }
}

#[test]
fn mirrored_requests_make_the_parent_need_you_until_each_is_resolved() {
    let fixture = fixture_json("decisions/Subagent--MirroredRequests.json");
    let mut parent = SessionDecisions::new("conv_parent");
    let ids: Vec<String> = fixture["requests"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| {
            let request = ElicitationRequest::from_value(entry["elicitation"].clone()).unwrap();
            assert_eq!(parent.apply_request(&request), RequestOutcome::Added);
            request.elicitation_id
        })
        .collect();
    assert_eq!(parent.pending().count(), ids.len());
    for id in &ids {
        assert!(parent.needs_response());
        let resolved = ServerStreamEvent::from_value(json!({
            "type": "response.elicitation_resolved", "elicitation_id": id, "action": "accept",
        }))
        .unwrap();
        parent.apply_event(&resolved);
    }
    assert!(!parent.needs_response());
    let answers: BTreeMap<String, ElicitationValue> = BTreeMap::new();
    assert_eq!(
        parent.prepare_resolve(&ids[0], &DecisionResponse::Form(answers), false),
        Err(DecisionError::AlreadyResolved {
            decision_id: ids[0].clone()
        })
    );
}
