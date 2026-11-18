//! Every kind of request Claude asks the user, from `fixtures/decisions/Claude--*.json`: the card
//! for the elicitation the server publishes, and the exact answer the app posts for it. The
//! server side of each fixture (Claude's hook input in, Claude's hook output out) is
//! `test_claude_fixture_round_trip` in
//! `tests/server/integration/test_sessions_permission_request_hook.py`.

use std::collections::BTreeMap;

use omnigent_protocol::{ElicitationRequest, ElicitationValue, FromWire};
use serde_json::{Value, json};

use super::*;
use crate::client::test_support::fixture_json;

/// The card for `Claude--{name}.json` and the answer the app posts.
fn claude(name: &str) -> (Decision, Value) {
    let fixture = fixture_json(&format!("decisions/Claude--{name}.json"));
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

fn answers(value: &Value) -> BTreeMap<String, ElicitationValue> {
    serde_json::from_value(value.clone()).unwrap()
}

fn shape(field: &FormField) -> (&str, FieldKind, bool, bool) {
    (
        field.key.as_str(),
        field.kind,
        field.allows_custom,
        field.accepts_notes,
    )
}

// --- AskUserQuestion --------------------------------------------------------------------------

#[test]
fn a_question_offers_its_options_and_a_typed_answer() {
    let (card, answer) = claude("AskUserQuestion--SingleSelect");
    assert_eq!(card.title, "Response requested");
    let form = card.form().unwrap();
    let [question] = form.fields.as_slice() else {
        panic!("one question: {form:?}");
    };
    assert_eq!(
        shape(question),
        (
            "Which date library should the parser use?",
            FieldKind::SingleChoice,
            true,
            false
        )
    );
    assert_eq!(question.detail, "Library", "the header labels the question");
    let options: Vec<(&str, &str)> = question
        .options
        .iter()
        .map(|option| (option.label.as_str(), option.detail.as_str()))
        .collect();
    assert_eq!(
        options,
        [
            (
                "date-fns (Recommended)",
                "Small functions you import one by one."
            ),
            ("Luxon", "Time zones and formatting built in."),
        ]
    );
    // Claude always offers "Other".
    let typed = DecisionResponse::Form(answers(&json!({
        "Which date library should the parser use?": "Temporal",
    })));
    assert!(card.result_for(&typed).is_ok());
    assert_eq!(
        posted(&card, &DecisionResponse::Form(answers(&answer["content"]))),
        answer
    );
    assert_eq!(
        card.result_for(&DecisionResponse::Approve),
        Err(DecisionError::NotOffered),
        "a question is never a binary approval"
    );
}

#[test]
fn a_multi_select_question_takes_several_choices_and_a_typed_one() {
    let (card, answer) = claude("AskUserQuestion--MultiSelectWithOther");
    let form = card.form().unwrap();
    assert_eq!(
        shape(&form.fields[0]),
        (
            "Which features should the first release include?",
            FieldKind::MultipleChoice,
            true,
            false
        )
    );
    assert_eq!(
        posted(&card, &DecisionResponse::Form(answers(&answer["content"]))),
        answer
    );
    let none = DecisionResponse::Form(answers(&json!({
        "Which features should the first release include?": [],
    })));
    assert!(
        matches!(
            card.result_for(&none),
            Err(DecisionError::InvalidAnswer(
                AnswerError::TooFewChoices { .. }
            ))
        ),
        "an empty selection does not answer a required question"
    );
}

#[test]
fn four_questions_form_one_card_in_order() {
    let (card, answer) = claude("AskUserQuestion--FourQuestions");
    let form = card.form().unwrap();
    let kinds: Vec<(&str, FieldKind)> = form
        .fields
        .iter()
        .map(|field| (field.detail.as_str(), field.kind))
        .collect();
    assert_eq!(
        kinds,
        [
            ("Storage", FieldKind::SingleChoice),
            ("Platforms", FieldKind::MultipleChoice),
            ("Errors", FieldKind::SingleChoice),
            ("Cleanup", FieldKind::SingleChoice),
        ]
    );
    let mut partial = answers(&answer["content"]);
    partial.remove("Should the old settings screen stay?");
    assert_eq!(
        form.problem(&partial).and_then(|problem| problem.field_key),
        Some("Should the old settings screen stay?".to_owned()),
        "every question needs an answer"
    );
    assert_eq!(
        posted(&card, &DecisionResponse::Form(answers(&answer["content"]))),
        answer
    );
}

#[test]
fn previews_show_apart_and_their_question_takes_a_note() {
    let (card, answer) = claude("AskUserQuestion--PreviewWithNotes");
    let form = card.form().unwrap();
    let question = &form.fields[0];
    assert!(question.accepts_notes);
    let sidebar = &question.options[0];
    assert_eq!(sidebar.detail, "Sections listed on the left.");
    assert!(
        sidebar.preview.starts_with("+--------+") && sidebar.preview.contains("| Nav    |"),
        "{:?}",
        sidebar.preview
    );
    let key = "Which layout should the settings screen use?".to_owned();
    let response = DecisionResponse::FormWithNotes {
        values: answers(&answer["content"]),
        notes: BTreeMap::from([(key.clone(), "  Let the sidebar collapse. ".to_owned())]),
    };
    assert_eq!(
        posted(&card, &response),
        answer,
        "notes ride in _meta, trimmed"
    );
    let blank = DecisionResponse::FormWithNotes {
        values: answers(&answer["content"]),
        notes: BTreeMap::from([(key, " ".to_owned())]),
    };
    assert_eq!(
        posted(&card, &blank),
        json!({"action": "accept", "content": answer["content"]}),
        "a blank note sends no _meta"
    );
}

#[test]
fn a_note_on_a_question_without_notes_is_refused() {
    let (card, answer) = claude("AskUserQuestion--SingleSelect");
    let response = DecisionResponse::FormWithNotes {
        values: answers(&answer["content"]),
        notes: BTreeMap::from([(
            "Which date library should the parser use?".to_owned(),
            "Pin the version.".to_owned(),
        )]),
    };
    assert_eq!(card.result_for(&response), Err(DecisionError::NotOffered));
}

// --- Tool permission requests -----------------------------------------------------------------

#[test]
fn claudes_always_allow_suggestion_is_one_choice() {
    let (card, answer) = claude("PermissionRequest--Bash--AlwaysAllowSuggestion");
    assert_eq!(card.kind, DecisionKind::Approval);
    let labels: Vec<String> = card
        .permissions
        .suggestions
        .iter()
        .map(PermissionUpdate::label)
        .collect();
    assert_eq!(labels, ["Allow Bash(npm test:*) in this project"]);
    assert!(card.permissions.suggestions[0].destination.persists());
    assert_eq!(card.remember_label(), Some("Bash"));
    assert!(card.permissions.allow_auto_mode);
    assert_eq!(posted(&card, &DecisionResponse::ApproveSuggestions), answer);
}

#[test]
fn a_denied_command_can_carry_a_reply() {
    let (card, answer) = claude("PermissionRequest--Bash--DenyWithFeedback");
    assert!(card.accepts_feedback());
    assert_eq!(card.permissions.suggestions, Vec::new());
    assert_eq!(
        card.result_for(&DecisionResponse::ApproveSuggestions),
        Err(DecisionError::NotOffered),
        "no suggestion was offered"
    );
    let reply = DecisionResponse::DeclineWithFeedback("Delete only build/cache.".to_owned());
    assert_eq!(posted(&card, &reply), answer);
}

#[test]
fn an_edit_suggestion_the_accept_edits_choice_covers_is_not_offered_twice() {
    let (card, answer) = claude("PermissionRequest--Edit--AcceptEdits");
    assert!(card.permissions.allow_all_edits);
    assert_eq!(
        card.permissions.suggestions,
        Vec::new(),
        "accept-edits mode for the session is already a choice"
    );
    assert_eq!(card.permissions.file_changes.len(), 1);
    assert_eq!(posted(&card, &DecisionResponse::ApproveAllEdits), answer);
}

#[test]
fn a_directory_suggestion_is_the_directory_choice() {
    let (card, answer) = claude("PermissionRequest--Read--AddDirectories");
    assert_eq!(
        card.permissions.permission_directories,
        ["/workspace/shared"]
    );
    assert_eq!(card.permissions.suggestions, Vec::new());
    assert!(!card.permissions.allow_auto_mode);
    assert_eq!(posted(&card, &DecisionResponse::ApproveDirectories), answer);
}

#[test]
fn a_fetch_offers_the_session_domain_and_claudes_project_rule() {
    let (card, answer) = claude("PermissionRequest--WebFetch--RememberDomain");
    assert_eq!(card.remember_label(), Some("docs.example.com"));
    let labels: Vec<String> = card
        .permissions
        .suggestions
        .iter()
        .map(PermissionUpdate::label)
        .collect();
    assert_eq!(
        labels,
        ["Allow WebFetch(domain:docs.example.com) in this project"]
    );
    assert_eq!(posted(&card, &DecisionResponse::ApproveRemembering), answer);
}

// --- ExitPlanMode -----------------------------------------------------------------------------

#[test]
fn a_plan_approves_into_each_offered_mode() {
    for (name, mode) in [
        ("ExitPlanMode--AutoMode", PermissionMode::Auto),
        ("ExitPlanMode--AcceptEdits", PermissionMode::AcceptEdits),
    ] {
        let (card, answer) = claude(name);
        assert!(card.is_plan_review(), "{name}");
        assert_eq!(card.title, "Review the plan");
        assert_eq!(
            card.permissions.plan_modes,
            [PermissionMode::Auto, PermissionMode::AcceptEdits]
        );
        assert_eq!(
            posted(&card, &DecisionResponse::ApprovePlanMode(mode)),
            answer,
            "{name}"
        );
        assert_eq!(
            card.result_for(&DecisionResponse::ApprovePlanMode(
                PermissionMode::BypassPermissions
            )),
            Err(DecisionError::NotOffered),
            "{name}: a mode that was not offered"
        );
    }
}

#[test]
fn a_plan_approved_plainly_keeps_asking_before_edits() {
    let (card, answer) = claude("ExitPlanMode--ManualApproval");
    assert_eq!(posted(&card, &DecisionResponse::Approve), answer);
}

#[test]
fn keep_planning_sends_what_to_change() {
    let (card, answer) = claude("ExitPlanMode--KeepPlanning");
    assert!(card.accepts_feedback());
    let reply = DecisionResponse::DeclineWithFeedback("Split step 2 by time zone.".to_owned());
    assert_eq!(posted(&card, &reply), answer);
}

#[test]
fn plan_modes_are_offered_only_on_a_plan_review() {
    let card = |params: Value| {
        let request =
            ElicitationRequest::from_value(json!({"elicitation_id": "e1", "params": params}))
                .unwrap();
        Decision::from_request(&request, "conv_a")
    };
    let outside_review = card(json!({"message": "m", "plan_modes": ["auto"]}));
    assert_eq!(outside_review.permissions.plan_modes, Vec::new());
    let review = card(json!({
        "message": "m",
        "exit_plan_mode": {"plan": "Ship it."},
        "plan_modes": ["auto", "nope", "auto"],
    }));
    assert_eq!(review.permissions.plan_modes, [PermissionMode::Auto]);
}

// --- MCP elicitations -------------------------------------------------------------------------

#[test]
fn an_mcp_form_is_a_native_form() {
    let (card, answer) = claude("Elicitation--Form");
    let form = card.form().unwrap();
    let fields: Vec<(&str, FieldKind, bool)> = form
        .fields
        .iter()
        .map(|field| (field.key.as_str(), field.kind, field.required))
        .collect();
    assert_eq!(
        fields,
        [
            ("environment", FieldKind::SingleChoice, true),
            ("notify", FieldKind::Boolean, false),
        ]
    );
    assert_eq!(
        form.fields[1].default_value,
        Some(ElicitationValue::Bool(true))
    );
    assert_eq!(
        posted(&card, &DecisionResponse::Form(answers(&answer["content"]))),
        answer
    );
}

#[test]
fn an_mcp_url_request_is_a_page_card() {
    let (card, answer) = claude("Elicitation--Url");
    assert_eq!(
        card.kind,
        DecisionKind::ExternalPage {
            url: "https://accounts.example.com/device?code=FIXTURE".to_owned()
        }
    );
    assert_eq!(posted(&card, &DecisionResponse::Approve), answer);
}

// --- Permission updates -----------------------------------------------------------------------

#[test]
fn every_update_kind_reads_as_one_sentence() {
    let updates = permission_updates::permission_updates(Some(&json!([
        {"type": "addRules", "rules": [{"toolName": "Read"}, {"toolName": "Bash", "ruleContent": "git log:*"}], "behavior": "allow", "destination": "userSettings"},
        {"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": ""}], "behavior": "deny", "destination": "projectSettings"},
        {"type": "addRules", "rules": [{"toolName": "WebFetch"}], "behavior": "ask", "destination": "session"},
        {"type": "replaceRules", "rules": [{"toolName": "Edit"}], "behavior": "allow", "destination": "cliArg"},
        {"type": "removeRules", "rules": [{"toolName": "Write"}], "behavior": "deny", "destination": "localSettings"},
        {"type": "setMode", "mode": "dontAsk", "destination": "session"},
        {"type": "addDirectories", "directories": ["/a", "/b"], "destination": "localSettings"},
        {"type": "removeDirectories", "directories": ["/a"], "destination": "session"},
    ])));
    let labels: Vec<String> = updates.iter().map(PermissionUpdate::label).collect();
    assert_eq!(
        labels,
        [
            "Allow Read, Bash(git log:*) in all your projects",
            "Deny Bash in this project, for everyone",
            "Always ask before WebFetch for this session",
            "Replace the allow rules with Edit until Claude restarts",
            "Remove the deny rules for Write in this project",
            "Switch to don't-ask mode for this session",
            "Allow access to /a, /b in this project",
            "Remove access to /a for this session",
        ]
    );
}

#[test]
fn a_suggestion_list_with_any_unreadable_entry_offers_nothing() {
    let valid = json!({"type": "setMode", "mode": "auto", "destination": "session"});
    for bad in [
        json!({"type": "setMode", "mode": "turbo", "destination": "session"}),
        json!({"type": "addRules", "rules": [], "behavior": "allow", "destination": "session"}),
        json!({"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": null}], "behavior": "allow", "destination": "session"}),
        json!({"type": "addRules", "rules": [{"toolName": "Bash"}], "behavior": "maybe", "destination": "session"}),
        json!({"type": "addDirectories", "directories": [" "], "destination": "session"}),
        json!({"type": "setMode", "mode": "auto", "destination": "elsewhere"}),
        json!({"type": "grantEverything", "destination": "session"}),
        json!("setMode"),
    ] {
        assert_eq!(
            permission_updates::permission_updates(Some(&json!([valid.clone(), bad]))),
            Vec::new(),
            "{bad}"
        );
    }
    assert_eq!(
        permission_updates::permission_updates(Some(&json!({"type": "setMode"}))),
        Vec::new(),
        "not a list"
    );
}

#[test]
fn every_permission_mode_round_trips() {
    for mode in [
        PermissionMode::Default,
        PermissionMode::AcceptEdits,
        PermissionMode::Plan,
        PermissionMode::BypassPermissions,
        PermissionMode::DontAsk,
        PermissionMode::Auto,
    ] {
        assert_eq!(PermissionMode::parse(mode.as_str()), Some(mode));
        assert!(mode.label().ends_with(" mode"), "{mode:?}");
    }
    assert_eq!(PermissionMode::parse("Auto"), None);
}
