//! Every request kind Codex asks the user, from `fixtures/decisions/Codex--*.json`: the card for
//! the elicitation the server publishes, and the exact answer the app posts for it. The server
//! side of each fixture (Codex request in, Codex result out) is
//! `tests/server/routes/test_codex_elicitation.py`.

use std::collections::BTreeMap;

use omnigent_protocol::{ElicitationRequest, ElicitationValue, FromWire};
use serde_json::{Value, json};

use super::*;
use crate::client::test_support::fixture_json;

/// The server's `content_preview` cap (`_json_preview`).
const PREVIEW_LIMIT: usize = 1024;

/// The card for `Codex--{name}.json` (with the preview the server adds) and the answer the app
/// posts.
fn codex(name: &str) -> (Decision, Value) {
    let fixture = fixture_json(&format!("decisions/Codex--{name}.json"));
    let mut elicitation = fixture["elicitation"].clone();
    let preview: String = fixture["codex"]["params"]
        .to_string()
        .chars()
        .take(PREVIEW_LIMIT)
        .collect();
    elicitation["params"]["content_preview"] = Value::String(preview);
    let request = ElicitationRequest::from_value(elicitation).unwrap();
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

fn field<'form>(form: &'form DecisionForm, key: &str) -> &'form FormField {
    form.fields
        .iter()
        .find(|field| field.key == key)
        .unwrap_or_else(|| panic!("no field {key}"))
}

fn labels(field: &FormField) -> Vec<&str> {
    field
        .options
        .iter()
        .map(|option| option.label.as_str())
        .collect()
}

// --- item/tool/requestUserInput ---------------------------------------------------------------

#[test]
fn request_user_input_options_take_a_choice_or_a_typed_answer() {
    let (card, answer) = codex("ToolRequestUserInput--OptionsWithOther");
    assert_eq!(card.title, "Response requested");
    let form = card.form().unwrap();
    let question = field(form, "ui_framework");
    assert_eq!(question.kind, FieldKind::SingleChoice);
    assert!(question.allows_custom, "isOther offers a typed answer");
    assert_eq!(question.detail, "Framework");
    assert_eq!(labels(question), ["SwiftUI (Recommended)", "UIKit"]);
    assert_eq!(question.options[1].detail, "More control, more code.");
    assert_eq!(
        form.validate(&answers(json!({"ui_framework": "UIKit"}))),
        Ok(())
    );
    assert_eq!(posted(&card, &form_response(&answer)), answer);
}

#[test]
fn request_user_input_without_other_takes_only_its_options() {
    let (card, answer) = codex("ToolRequestUserInput--OptionsOnly");
    let form = card.form().unwrap();
    let question = &form.fields[0];
    assert!(
        !question.allows_custom,
        "isOther: false has no typed answer"
    );
    assert_eq!(
        labels(question),
        ["Allow", "Allow for this session", "Cancel"]
    );
    let custom = DecisionResponse::Form(answers(json!({
        "mcp_tool_call_approval_call_fixture": "Allow everything",
    })));
    assert_eq!(
        card.result_for(&custom),
        Err(DecisionError::InvalidAnswer(AnswerError::NotAnOption {
            field: question.title.clone()
        }))
    );
    assert_eq!(posted(&card, &form_response(&answer)), answer);
}

#[test]
fn request_user_input_without_options_is_a_required_text_answer() {
    let (card, answer) = codex("ToolRequestUserInput--FreeText");
    assert_eq!(card.unsupported_reason(), None);
    let form = card.form().unwrap();
    let question = &form.fields[0];
    assert_eq!(
        (question.key.as_str(), question.kind, question.required),
        ("release_name", FieldKind::Text, true)
    );
    assert_eq!(question.options, Vec::<FormOption>::new());
    assert_eq!(
        form.problem(&answers(json!({"release_name": " "})))
            .map(|problem| problem.field_key),
        Some(Some("release_name".to_owned()))
    );
    assert_eq!(posted(&card, &form_response(&answer)), answer);
}

#[test]
fn request_user_input_secret_and_several_questions_form_one_card() {
    let (card, answer) = codex("ToolRequestUserInput--SecretAndMultipleQuestions");
    let form = card.form().unwrap();
    let shapes: Vec<(&str, FieldKind, bool)> = form
        .fields
        .iter()
        .map(|field| (field.key.as_str(), field.kind, field.is_secret))
        .collect();
    assert_eq!(
        shapes,
        [
            ("environment", FieldKind::SingleChoice, false),
            ("api_token", FieldKind::Text, true),
            ("notes", FieldKind::Text, false),
        ]
    );
    let mut missing = answers(answer["content"].clone());
    missing.remove("api_token");
    assert_eq!(
        form.problem(&missing).and_then(|problem| problem.field_key),
        Some("api_token".to_owned())
    );
    assert_eq!(posted(&card, &form_response(&answer)), answer);
}

#[test]
fn async_question_without_options_is_a_text_answer() {
    let (card, answer) = codex("RequestUserInputAsync--FreeText");
    let form = card.form().unwrap();
    assert_eq!(form.fields[0].kind, FieldKind::Text);
    assert_eq!(posted(&card, &form_response(&answer)), answer);
}

// --- mcpServer/elicitation/request ------------------------------------------------------------

#[test]
#[allow(clippy::too_many_lines, reason = "one assertion per MCP field shape")]
fn mcp_form_renders_every_field_shape_with_its_constraints_and_defaults() {
    let (card, answer) = codex("McpServerElicitationRequest--FormEveryField");
    assert_eq!(card.unsupported_reason(), None);
    assert_eq!(card.detail, "Schedule the review meeting.");
    assert_eq!(card.tool_input, None);
    let form = card.form().unwrap();
    let keys: Vec<&str> = form.fields.iter().map(|field| field.key.as_str()).collect();
    assert_eq!(
        keys,
        [
            "approver_email",
            "attendees",
            "confirm",
            "count",
            "docs_url",
            "priority",
            "ratio",
            "room",
            "start",
            "tags",
            "timezone",
            "topic",
            "when"
        ]
    );
    let formats: Vec<(&str, Option<TextFormat>)> = form
        .fields
        .iter()
        .filter(|field| field.kind == FieldKind::Text)
        .map(|field| (field.key.as_str(), field.format))
        .collect();
    assert_eq!(
        formats,
        [
            ("approver_email", Some(TextFormat::Email)),
            ("docs_url", Some(TextFormat::Uri)),
            ("start", Some(TextFormat::DateTime)),
            ("topic", None),
            ("when", Some(TextFormat::Date)),
        ]
    );

    let attendees = field(form, "attendees");
    assert_eq!(attendees.kind, FieldKind::MultipleChoice);
    assert_eq!(labels(attendees), ["Ana Lima", "Bo Chen", "Cy Park"]);
    assert_eq!(
        (attendees.min_items, attendees.max_items),
        (Some(1), Some(2))
    );
    assert_eq!(
        attendees.default_value,
        Some(ElicitationValue::TextList(vec!["ana".to_owned()]))
    );
    let room = field(form, "room");
    assert_eq!(room.kind, FieldKind::SingleChoice);
    assert_eq!(labels(room), ["North room", "South room"]);
    assert_eq!(
        room.default_value,
        Some(ElicitationValue::Text("south".to_owned()))
    );
    assert_eq!(labels(field(form, "priority")), ["Urgent", "Normal"]);
    assert_eq!(labels(field(form, "timezone")), ["UTC", "PST"]);
    assert_eq!(labels(field(form, "tags")), ["design", "review"]);
    let count = field(form, "count");
    assert_eq!(count.kind, FieldKind::Integer);
    assert_eq!((count.minimum, count.maximum), (Some(1.0), Some(10.0)));
    assert_eq!(count.default_value, Some(ElicitationValue::Integer(3)));
    assert_eq!(
        field(form, "ratio").default_value,
        Some(ElicitationValue::Number(0.5))
    );
    assert_eq!(
        field(form, "confirm").default_value,
        Some(ElicitationValue::Bool(true))
    );
    let topic = field(form, "topic");
    assert_eq!((topic.min_length, topic.max_length), (Some(3), Some(40)));
    assert_eq!(
        topic.default_value,
        Some(ElicitationValue::Text("Weekly sync".to_owned()))
    );
    let required: Vec<&str> = form
        .fields
        .iter()
        .filter(|field| field.required)
        .map(|field| field.key.as_str())
        .collect();
    assert_eq!(
        required,
        [
            "approver_email",
            "attendees",
            "count",
            "room",
            "start",
            "topic",
            "when"
        ]
    );

    assert_eq!(posted(&card, &form_response(&answer)), answer);
    let valid = answers(answer["content"].clone());
    let with = |key: &str, value: Value| {
        let mut values = valid.clone();
        values.insert(key.to_owned(), serde_json::from_value(value).unwrap());
        form.validate(&values)
    };
    let wrong_format = |field: &str, format| {
        Err(AnswerError::WrongFormat {
            field: field.to_owned(),
            format,
        })
    };
    assert_eq!(
        with("approver_email", json!("lead")),
        wrong_format("Approver email", TextFormat::Email)
    );
    assert_eq!(
        with("docs_url", json!("example.com/agenda")),
        wrong_format("Agenda link", TextFormat::Uri)
    );
    assert_eq!(
        with("start", json!("tomorrow at nine")),
        wrong_format("Starts", TextFormat::DateTime)
    );
    assert_eq!(
        with("when", json!("2026-02-30")),
        wrong_format("Day", TextFormat::Date)
    );
    assert_eq!(
        with("attendees", json!(["ana", "bo", "cy"])),
        Err(AnswerError::TooManyChoices {
            field: "Attendees".to_owned(),
            max: 2
        })
    );
    assert_eq!(
        with("attendees", json!(["Ana Lima"])),
        Err(AnswerError::ChoicesNotOffered {
            field: "Attendees".to_owned()
        }),
        "titles are labels, the const is the answer"
    );
    assert_eq!(
        with("room", json!("east")),
        Err(AnswerError::NotAnOption {
            field: "Room".to_owned()
        })
    );
    assert_eq!(
        with("count", json!(11)),
        Err(AnswerError::AboveMaximum {
            field: "Guests".to_owned(),
            max: 10.0
        })
    );
}

#[test]
fn mcp_single_enum_is_a_choice_card() {
    let (card, answer) = codex("McpServerElicitationRequest--SingleSelect");
    assert_eq!(
        card.kind,
        DecisionKind::Choice {
            answer_key: "next".to_owned(),
            options: vec!["Retry".to_owned(), "Skip".to_owned(), "Stop".to_owned()],
        }
    );
    assert_eq!(
        posted(&card, &DecisionResponse::Answer("Retry".to_owned())),
        answer
    );
    assert_eq!(
        card.result_for(&DecisionResponse::Answer("Later".to_owned())),
        Err(DecisionError::NotOffered)
    );
}

#[test]
fn mcp_tool_call_approval_offers_the_advertised_persistence() {
    let (card, answer) = codex("McpServerElicitationRequest--ToolCallApproval");
    assert_eq!(card.kind, DecisionKind::Approval);
    assert_eq!(
        card.permissions.persist_modes,
        [PersistMode::Session, PersistMode::Always]
    );
    assert_eq!(
        posted(
            &card,
            &DecisionResponse::ApprovePersist(PersistMode::Session)
        ),
        answer
    );
}

#[test]
fn mcp_url_mode_is_a_page_to_complete_then_done_or_decline() {
    let (card, answer) = codex("McpServerElicitationRequest--Url");
    assert_eq!(
        card.kind,
        DecisionKind::ExternalPage {
            url: "https://payments.example.com/checkout/123".to_owned()
        }
    );
    assert_eq!(card.title, "Action required");
    assert_eq!(card.detail, "Review the payment details to continue.");
    assert_eq!(card.tool_input, None, "the raw request is not shown");
    assert_eq!(posted(&card, &DecisionResponse::Approve), answer);
    assert_eq!(
        posted(&card, &DecisionResponse::Decline),
        json!({"action": "decline"})
    );
    assert_eq!(
        card.result_for(&DecisionResponse::Form(BTreeMap::new())),
        Err(DecisionError::NotOffered)
    );
}

// --- command, file change and permission approvals ---------------------------------------------

#[test]
fn command_approval_offers_the_command_policy_codex_advertised() {
    let (card, answer) = codex("CommandExecutionRequestApproval--CommandPolicy");
    assert_eq!(card.kind, DecisionKind::Approval);
    let command = card.permissions.command.as_ref().unwrap();
    assert_eq!(command.command, "cargo test -p demo");
    assert_eq!(command.cwd.as_deref(), Some("/workspace/demo"));
    let policy = vec!["cargo".to_owned(), "test".to_owned()];
    assert_eq!(
        card.permissions.exec_policy_amendment.as_ref(),
        Some(&policy)
    );
    assert_eq!(
        posted(&card, &DecisionResponse::ApproveCommandPolicy(policy)),
        answer
    );
}

#[test]
fn network_approval_names_the_host() {
    let (card, answer) = codex("CommandExecutionRequestApproval--NetworkAccess");
    assert_eq!(card.kind, DecisionKind::Approval);
    assert_eq!(
        card.message.as_deref(),
        Some("Codex wants network access to **registry.example.com**")
    );
    assert_eq!(posted(&card, &DecisionResponse::Decline), answer);
}

#[test]
fn file_change_permission_and_legacy_approvals_are_binary() {
    for (name, response) in [
        ("FileChangeRequestApproval", DecisionResponse::Approve),
        ("PermissionsRequestApproval", DecisionResponse::Approve),
        ("ExecCommandApproval", DecisionResponse::Decline),
        ("ApplyPatchApproval", DecisionResponse::Approve),
    ] {
        let (card, answer) = codex(name);
        assert_eq!(card.kind, DecisionKind::Approval, "{name}");
        assert_eq!(posted(&card, &response), answer, "{name}");
    }
    let (legacy, _) = codex("ExecCommandApproval");
    assert_eq!(
        legacy.permissions.command.map(|command| command.command),
        Some("git status --short".to_owned())
    );
    let (patch, _) = codex("ApplyPatchApproval");
    let files: Vec<(&str, Option<FileChangeKind>)> = patch
        .permissions
        .file_changes
        .iter()
        .map(|change| (change.path.as_str(), change.kind))
        .collect();
    assert_eq!(
        files,
        [("/workspace/demo/src/lib.rs", Some(FileChangeKind::Modify))]
    );
}
