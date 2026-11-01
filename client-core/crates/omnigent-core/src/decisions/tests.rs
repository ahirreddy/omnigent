//! Ported `NativeLab` decision tests (`DecisionFormTests`, `EventParityTests`,
//! `LiveConversationReducerTests`, `LiveEventReconciliationTests`,
//! `LocalServerSessionClientTests`, `DemoSessionClientTests`) plus the web permission variants.

use std::collections::BTreeMap;

use omnigent_protocol::{
    ElicitationAction, ElicitationRequest, ElicitationResolution, ElicitationValue, FromWire,
    ServerStreamEvent,
};
use serde_json::{Value, json};

use super::*;
use crate::auth::SecretString;
use crate::auth::endpoint::ServerEndpoint;
use crate::http::{HttpResponse, TransportError};

fn fixture_text(path: &str) -> String {
    let path = format!("{}/../../fixtures/{path}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("reading {path}: {error}"))
}

fn fixture_json(path: &str) -> Value {
    serde_json::from_str(&fixture_text(path)).unwrap()
}

fn fixture_lines(path: &str) -> Vec<Value> {
    fixture_text(path)
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

fn request(value: Value) -> ElicitationRequest {
    ElicitationRequest::from_value(value).unwrap()
}

fn decision(value: Value) -> Decision {
    Decision::from_request(&request(value), "session")
}

fn params(params: &Value) -> Decision {
    decision(json!({"elicitation_id": "request", "params": params}))
}

fn values(value: Value) -> BTreeMap<String, ElicitationValue> {
    serde_json::from_value(value).unwrap()
}

fn event(value: Value) -> ServerStreamEvent {
    ServerStreamEvent::from_value(value).unwrap()
}

fn pending_ids(decisions: &SessionDecisions) -> Vec<&str> {
    decisions
        .pending()
        .map(|decision| decision.id.as_str())
        .collect()
}

// --- DecisionFormTests ------------------------------------------------------------------------

#[test]
fn typed_schema_has_native_fields_and_validates_without_coercion() {
    let card = decision(fixture_json(
        "decisions/DecisionForm--TypedSchemaHasNativeFieldsAndValidatesWithoutCoercion.json",
    ));
    assert_eq!(card.unsupported_reason(), None);
    let form = card.form().unwrap();
    let kinds: Vec<FieldKind> = form.fields.iter().map(|field| field.kind).collect();
    assert_eq!(
        kinds,
        [FieldKind::Integer, FieldKind::Text, FieldKind::Boolean]
    );
    assert!(form.validate(&BTreeMap::new()).is_err());
    assert_eq!(
        form.validate(&values(json!({"name": "Omni", "count": 2, "ready": false}))),
        Ok(())
    );
    assert!(matches!(
        form.validate(&values(json!({"name": "O", "count": 2, "ready": false}))),
        Err(AnswerError::TooShort { min: 2, .. })
    ));
    assert!(matches!(
        form.validate(&values(
            json!({"name": "Omni", "count": 2.5, "ready": false})
        )),
        Err(AnswerError::NotAWholeNumber { .. })
    ));
    assert!(matches!(
        form.validate(&values(
            json!({"name": "Omni", "count": "2", "ready": false})
        )),
        Err(AnswerError::WrongType { .. })
    ));
    assert!(matches!(
        form.validate(&values(json!({"name": "Omni", "count": 6, "ready": false}))),
        Err(AnswerError::AboveMaximum { .. })
    ));
}

#[test]
fn unsupported_nested_schema_never_becomes_approval() {
    let card = decision(fixture_json(
        "decisions/DecisionForm--UnsupportedNestedSchemaNeverBecomesApproval.json",
    ));
    assert!(matches!(
        card.unsupported_reason(),
        Some(UnsupportedReason::Schema(
            FormError::UnsupportedKeyword { .. }
        ))
    ));
    assert_eq!(card.form(), None);
    assert_eq!(
        card.result_for(&DecisionResponse::Approve),
        Err(DecisionError::Unsupported(
            card.unsupported_reason().unwrap().clone()
        ))
    );
}

#[test]
fn unsupported_pattern_never_silently_disappears() {
    let card = decision(fixture_json(
        "decisions/DecisionForm--UnsupportedPatternNeverSilentlyDisappears.json",
    ));
    assert_eq!(
        card.unsupported_reason(),
        Some(&UnsupportedReason::Schema(FormError::UnsupportedKeyword {
            field: "name".to_owned(),
            keyword: "pattern".to_owned(),
        }))
    );
}

#[test]
fn schema_without_properties_and_missing_url_never_become_approval() {
    let lines = fixture_lines(
        "decisions/DecisionForm--SchemaWithoutPropertiesAndMissingURLNeverBecomeApproval.jsonl",
    );
    assert_eq!(lines.len(), 4);
    for line in lines {
        let card = decision(line.clone());
        assert!(card.unsupported_reason().is_some(), "{line}");
        assert!(
            card.result_for(&DecisionResponse::Approve).is_err(),
            "{line}"
        );
    }
}

#[test]
fn malformed_constraints_fail_closed() {
    let lines = fixture_lines("decisions/DecisionForm--MalformedConstraintsFailClosed.jsonl");
    assert_eq!(lines.len(), 5);
    let expected = [
        FormError::MalformedSchemaKeyword {
            keyword: "required".to_owned(),
        },
        FormError::MalformedConstraint {
            field: "name".to_owned(),
            keyword: "minLength".to_owned(),
        },
        FormError::MalformedConstraint {
            field: "name".to_owned(),
            keyword: "minLength".to_owned(),
        },
        FormError::MalformedConstraint {
            field: "count".to_owned(),
            keyword: "minimum".to_owned(),
        },
        FormError::MalformedConstraint {
            field: "count".to_owned(),
            keyword: "minimum".to_owned(),
        },
    ];
    for (line, expected) in lines.into_iter().zip(expected) {
        assert_eq!(
            decision(line).unsupported_reason(),
            Some(&UnsupportedReason::Schema(expected))
        );
    }
}

#[test]
fn command_policy_and_metadata_remain_explicit() {
    let card = decision(fixture_json(
        "decisions/DecisionForm--CommandPolicyAndMetadataRemainExplicit.json",
    ));
    assert_eq!(card.kind, DecisionKind::Approval);
    assert_eq!(
        card.permissions.exec_policy_amendment,
        Some(vec!["swift".to_owned(), "test".to_owned()])
    );
    assert!(card.detail.contains("Working directory: /workspace"));
    assert!(card.detail.contains("Reason: Verify the change"));
    assert!(card.detail.contains("Suggested command policy: swift test"));
    assert_eq!(
        card.permissions
            .command
            .as_ref()
            .map(|command| command.command.as_str()),
        Some("swift test")
    );
}

#[test]
fn array_choices_validate_count_and_membership() {
    let card = decision(fixture_json(
        "decisions/DecisionForm--ArrayChoicesValidateCountAndMembership.json",
    ));
    let form = card.form().unwrap();
    assert_eq!(
        form.validate(&values(json!({"tags": ["One", "Two"]}))),
        Ok(())
    );
    assert!(matches!(
        form.validate(&values(json!({"tags": ["Other"]}))),
        Err(AnswerError::ChoicesNotOffered { .. })
    ));
    assert!(matches!(
        form.validate(&values(json!({"tags": ["One", "Two", "Three"]}))),
        Err(AnswerError::TooManyChoices { max: 2, .. })
    ));
    assert!(matches!(
        form.validate(&values(json!({"tags": ["One", "One"]}))),
        Err(AnswerError::DuplicateOrEmptyChoices { .. })
    ));
    assert!(matches!(
        form.validate(&values(json!({"tags": []}))),
        Err(AnswerError::TooFewChoices { .. })
    ));
}

#[test]
fn ask_user_question_preserves_i_ds_and_supports_custom_and_multi_answers() {
    let card = decision(fixture_json(
        "decisions/DecisionForm--AskUserQuestionPreservesIDsAndSupportsCustomAndMultiAnswers.json",
    ));
    let form = card.form().unwrap();
    let keys: Vec<&str> = form.fields.iter().map(|field| field.key.as_str()).collect();
    assert_eq!(keys, ["scope", "What next?"]);
    assert_eq!(form.fields[0].options[0].detail, "Phone UI");
    assert_eq!(form.fields[0].kind, FieldKind::SingleChoice);
    assert_eq!(form.fields[1].kind, FieldKind::MultipleChoice);
    assert_eq!(
        form.validate(&values(
            json!({"scope": "Custom answer", "What next?": ["Tests", "Accessibility"]})
        )),
        Ok(())
    );
    assert!(matches!(
        form.validate(&values(json!({"scope": "Native"}))),
        Err(AnswerError::Missing { .. })
    ));
    assert_eq!(card.title, "Response requested");
}

#[test]
fn question_preview_fallback_produces_form() {
    let card = decision(fixture_json(
        "decisions/DecisionForm--QuestionPreviewFallbackProducesForm.json",
    ));
    assert_eq!(card.form().unwrap().fields[0].key, "Continue?");
    // The preview is not repeated in the detail of a form.
    assert!(!card.detail.contains("AskUserQuestion"));
    // A truncated preview fails closed instead of becoming a binary approval.
    let truncated = params(&json!({"content_preview": "AskUserQuestion({\"questions\":[{\"quest"}));
    assert!(matches!(
        truncated.unsupported_reason(),
        Some(UnsupportedReason::Question(
            FormError::MalformedPreview { .. }
        ))
    ));
}

#[test]
fn malformed_question_cannot_become_approval() {
    let card = decision(fixture_json(
        "decisions/DecisionForm--MalformedQuestionCannotBecomeApproval.json",
    ));
    assert!(matches!(
        card.unsupported_reason(),
        Some(UnsupportedReason::Question(
            FormError::MalformedOptions { .. }
        ))
    ));
    assert_eq!(card.form(), None);
}

#[test]
fn external_request_only_exposes_safe_explicit_handoff() {
    let lines = fixture_lines(
        "decisions/DecisionForm--ExternalRequestOnlyExposesSafeExplicitHandoff.jsonl",
    );
    let safe = decision(lines[0].clone());
    assert_eq!(safe.external_url(), Some("https://example.invalid/confirm"));
    assert_eq!(
        safe.unsupported_reason(),
        Some(&UnsupportedReason::ExternalConfirmation)
    );
    assert!(safe.result_for(&DecisionResponse::Approve).is_err());
    let unsafe_link = decision(lines[1].clone());
    assert_eq!(unsafe_link.external_url(), None);
    assert_eq!(
        unsafe_link.unsupported_reason(),
        Some(&UnsupportedReason::UnsafeConfirmationUrl)
    );
    for url in [
        "https://user:pass@example.invalid/",
        "file:///etc/passwd",
        "https://",
    ] {
        assert_eq!(
            params(&json!({"mode": "url", "url": url})).external_url(),
            None,
            "{url}"
        );
    }
    // The server's own approve path is answered inline.
    assert_eq!(
        params(&json!({"mode": "url", "url": "/approve/abc"})).kind,
        DecisionKind::Approval
    );
}

#[test]
fn plan_and_remember_capabilities_are_explicit() {
    let lines =
        fixture_lines("decisions/DecisionForm--PlanAndRememberCapabilitiesAreExplicit.jsonl");
    let plan = decision(lines[0].clone());
    assert!(plan.is_plan_review());
    assert!(plan.permissions.allow_all_edits);
    assert_eq!(plan.title, "Review the plan");
    assert!(plan.detail.contains("Review this plan"));
    let remember = decision(lines[1].clone());
    assert_eq!(remember.remember_label(), Some("example.invalid"));
    assert!(!remember.is_plan_review());
    assert!(!remember.permissions.allow_all_edits);
}

#[test]
fn decision_values_encode_as_flat_mcp_scalars() {
    let fixture = fixture_json("decisions/DecisionForm--DecisionValuesEncodeAsFlatMCPScalars.json");
    let decoded = values(fixture.clone());
    assert_eq!(
        decoded,
        BTreeMap::from([
            ("name".to_owned(), ElicitationValue::Text("Omni".to_owned())),
            ("count".to_owned(), ElicitationValue::Integer(2)),
            ("ready".to_owned(), ElicitationValue::Bool(false)),
            (
                "tags".to_owned(),
                ElicitationValue::TextList(vec!["Native".to_owned()])
            ),
        ])
    );
    assert_eq!(serde_json::to_value(&decoded).unwrap(), fixture);
}

#[test]
fn unknown_response_field_is_rejected() {
    let form = DecisionForm {
        fields: vec![FormField::new("name", "Name", FieldKind::Text)],
    };
    assert_eq!(
        form.validate(&values(json!({"name": "Omni", "extra": true}))),
        Err(AnswerError::UnknownField {
            key: "extra".to_owned()
        })
    );
    assert_eq!(form.validate(&values(json!({"name": "Omni"}))), Ok(()));
}

// --- EventParityTests, LiveConversationReducerTests, LiveEventReconciliationTests --------------

#[test]
fn unsupported_schema_and_incomplete_url_mode_cannot_become_binary_approval() {
    let lines = fixture_lines(
        "decisions/EventParity--UnsupportedSchemaAndIncompleteURLModeCannotBecomeBinaryApproval.jsonl",
    );
    let reasons: Vec<UnsupportedReason> = lines
        .into_iter()
        .map(|line| decision(line).unsupported_reason().cloned().unwrap())
        .collect();
    assert_eq!(
        reasons,
        [
            UnsupportedReason::Schema(FormError::NotAnObjectSchema),
            UnsupportedReason::Schema(FormError::NotAnObjectSchema),
            UnsupportedReason::MissingConfirmationUrl,
        ]
    );
}

#[test]
fn multi_field_forms_use_typed_fields_instead_of_binary_approvals() {
    let card = decision(fixture_json(
        "decisions/LiveConversationReducer--MultiFieldFormsUseTypedFieldsInsteadOfBinaryApprovals.json",
    ));
    assert_eq!(card.unsupported_reason(), None);
    let form = card.form().unwrap();
    let fields: Vec<(&str, FieldKind)> = form
        .fields
        .iter()
        .map(|field| (field.key.as_str(), field.kind))
        .collect();
    assert_eq!(
        fields,
        [("count", FieldKind::Integer), ("name", FieldKind::Text)]
    );
    assert_eq!(
        card.result_for(&DecisionResponse::Approve),
        Err(DecisionError::NotOffered)
    );
}

#[test]
fn elicitation_resolution_requires_exact_id_and_tool_output_cannot_resolve_it() {
    let lines = fixture_lines(
        "events/EventParity--ElicitationResolutionRequiresExactIDAndToolOutputCannotResolveIt.jsonl",
    );
    let mut decisions = SessionDecisions::new("fixture-session");
    let outcomes: Vec<Option<DecisionEventOutcome>> = lines
        .into_iter()
        .map(|line| {
            let outcome = decisions.apply_event(&event(line));
            if decisions.entries().len() == 1 {
                assert_eq!(pending_ids(&decisions), ["approval-1"]);
                assert!(decisions.needs_response());
            }
            outcome
        })
        .collect();
    assert_eq!(
        outcomes,
        [
            Some(DecisionEventOutcome::Request(RequestOutcome::Added)),
            None,
            Some(DecisionEventOutcome::Resolved(ResolvedOutcome::Unknown)),
            Some(DecisionEventOutcome::Resolved(ResolvedOutcome::Retired(
                ElicitationResolution::AnsweredElsewhere
            ))),
        ]
    );
    assert!(!decisions.needs_response());
}

#[test]
fn approval_and_single_field_question_use_originating_session() {
    let lines = fixture_lines(
        "events/LiveConversationReducer--ApprovalAndSingleFieldQuestionUseOriginatingSession.jsonl",
    );
    let mut decisions = SessionDecisions::new("parent");
    decisions.apply_event(&event(lines[0].clone()));
    let card = decisions.pending().next().unwrap().clone();
    assert_eq!(card.target_session_id, "child1");
    assert!(card.targets_other_session());
    assert_eq!(
        card.kind,
        DecisionKind::Choice {
            answer_key: "answer".to_owned(),
            options: vec!["Yes".to_owned(), "No".to_owned()],
        }
    );
    assert!(decisions.needs_response());
    let resolve = decisions
        .prepare_resolve("ask1", &DecisionResponse::Answer("Yes".to_owned()), false)
        .unwrap();
    assert_eq!(resolve.session_id, "child1");
    let endpoint = ServerEndpoint::new("http://127.0.0.1:6767").unwrap();
    let http = resolve
        .http_request(&endpoint, None, ResolveRoute::Dedicated)
        .unwrap();
    assert_eq!(
        http.url,
        "http://127.0.0.1:6767/v1/sessions/child1/elicitations/ask1/resolve"
    );
    decisions.apply_event(&event(lines[1].clone()));
    assert_eq!(decisions.pending().count(), 0);
}

#[test]
fn resolved_elicitation_replay_cannot_reappear_and_unknown_resolution_does_not_stop_response() {
    let lines = fixture_lines(
        "events/LiveEventReconciliation--ResolvedElicitationReplayCannotReappearAndUnknownResolutionDoesNotStopResponse.jsonl",
    );
    let mut decisions = SessionDecisions::new("fixture-session");
    let outcomes: Vec<Option<DecisionEventOutcome>> = lines
        .iter()
        .map(|line| decisions.apply_event(&event(line.clone())))
        .collect();
    assert_eq!(
        outcomes,
        [
            None,
            Some(DecisionEventOutcome::Resolved(ResolvedOutcome::Unknown)),
            Some(DecisionEventOutcome::Request(RequestOutcome::Added)),
            Some(DecisionEventOutcome::Resolved(ResolvedOutcome::Retired(
                ElicitationResolution::AnsweredElsewhere
            ))),
            Some(DecisionEventOutcome::Request(RequestOutcome::Stale)),
        ]
    );
    assert_eq!(decisions.entries(), []);
    // A stale snapshot that still lists ask1 cannot bring it back.
    decisions.reconcile(&[request(lines[4].clone())]);
    assert_eq!(decisions.entries(), []);
    assert_eq!(
        decisions.prepare_resolve("ask1", &DecisionResponse::Approve, false),
        Err(DecisionError::AlreadyResolved {
            decision_id: "ask1".to_owned()
        })
    );
}

#[test]
fn reconcile_retires_cards_missing_from_the_snapshot() {
    let mut decisions = SessionDecisions::new("conv_a");
    let ask = request(json!({"elicitation_id": "ask1", "params": {"message": "Approve?"}}));
    let other = request(json!({"elicitation_id": "ask2", "params": {"message": "Approve?"}}));
    assert_eq!(decisions.apply_request(&ask), RequestOutcome::Added);
    assert_eq!(decisions.apply_request(&ask), RequestOutcome::Replaced);
    decisions.reconcile(std::slice::from_ref(&other));
    assert_eq!(pending_ids(&decisions), ["ask2"]);
    assert!(decisions.is_retired("ask1"));
    assert_eq!(decisions.apply_request(&ask), RequestOutcome::Stale);
    decisions.reconcile(&[]);
    assert!(!decisions.needs_response());
}

// --- LocalServerSessionClientTests --------------------------------------------------------------

/// Builds the card from the fixture's snapshot, answers it, and returns the request body (or
/// error) plus the expected POST from the fixture, when it has one.
fn answer_fixture(
    name: &str,
    response: &DecisionResponse,
) -> (Result<(String, Value), DecisionError>, Option<Value>) {
    let lines = fixture_lines(&format!("decisions/{name}"));
    let snapshot = &lines[0]["response"];
    let pending: Vec<ElicitationRequest> =
        serde_json::from_value(snapshot["pending_elicitations"].clone()).unwrap();
    let mut decisions = SessionDecisions::new(snapshot["id"].as_str().unwrap());
    decisions.reconcile(&pending);
    let id = pending[0].elicitation_id.clone();
    let endpoint = ServerEndpoint::new("http://127.0.0.1:6767").unwrap();
    let result = decisions
        .prepare_resolve(&id, response, false)
        .map(|resolve| {
            let http = resolve
                .http_request(&endpoint, None, ResolveRoute::Dedicated)
                .unwrap();
            assert_eq!(http.method, "POST");
            let body: Value = serde_json::from_slice(http.body.as_deref().unwrap()).unwrap();
            let path = http
                .url
                .trim_start_matches("http://127.0.0.1:6767")
                .to_owned();
            (path, body)
        });
    (result, lines.get(1).map(|line| line["request"].clone()))
}

fn assert_posts(name: &str, response: &DecisionResponse) {
    let (result, expected) = answer_fixture(name, response);
    let (path, body) = result.unwrap();
    let expected = expected.unwrap();
    assert_eq!(path, expected["path"].as_str().unwrap(), "{name}");
    assert_eq!(body, expected["body"], "{name}");
}

#[test]
fn structured_form_posts_typed_content_without_coercion() {
    assert_posts(
        "LocalServerSessionClient--StructuredFormPostsTypedContentWithoutCoercion.jsonl",
        &DecisionResponse::Form(values(
            json!({"name": "Exact answer", "count": 2, "enabled": false, "scope": ["A", "B"]}),
        )),
    );
}

#[test]
fn invalid_structured_form_does_not_post_or_become_approval() {
    let name = "LocalServerSessionClient--InvalidStructuredFormDoesNotPostOrBecomeApproval.jsonl";
    for response in [
        DecisionResponse::Form(values(json!({"count": 0}))),
        DecisionResponse::Form(values(json!({"count": "2"}))),
        DecisionResponse::Form(BTreeMap::new()),
        DecisionResponse::Approve,
    ] {
        let (result, expected) = answer_fixture(name, &response);
        assert!(
            matches!(
                result,
                Err(DecisionError::InvalidAnswer(_) | DecisionError::NotOffered)
            ),
            "{response:?}: {result:?}"
        );
        assert_eq!(expected, None);
    }
}

#[test]
fn explicit_permission_responses_match_main_app_wire() {
    let cases = [
        ("allow-all-edits", DecisionResponse::ApproveAllEdits),
        ("remember-scope", DecisionResponse::ApproveRemembering),
        (
            "exit-plan-mode",
            DecisionResponse::DeclineWithFeedback("Use a smaller change".to_owned()),
        ),
        (
            "command-policy",
            DecisionResponse::ApproveCommandPolicy(vec!["swift".to_owned(), "test".to_owned()]),
        ),
    ];
    for (label, response) in cases {
        assert_posts(
            &format!(
                "LocalServerSessionClient--ExplicitPermissionResponsesMatchMainAppWire--{label}.jsonl"
            ),
            &response,
        );
    }
}

#[test]
fn unadvertised_permission_options_never_post() {
    let name = "LocalServerSessionClient--UnadvertisedPermissionOptionsNeverPost.jsonl";
    for response in [
        DecisionResponse::ApproveAllEdits,
        DecisionResponse::ApproveRemembering,
        DecisionResponse::ApproveCommandPolicy(vec!["swift".to_owned()]),
        DecisionResponse::DeclineWithFeedback("feedback".to_owned()),
        DecisionResponse::ApproveAutoMode,
        DecisionResponse::ApproveDirectories,
        DecisionResponse::ApprovePersist(PersistMode::Session),
        DecisionResponse::ApprovePersist(PersistMode::Always),
    ] {
        let (result, expected) = answer_fixture(name, &response);
        assert_eq!(result, Err(DecisionError::NotOffered), "{response:?}");
        assert_eq!(expected, None);
    }
    // The empty schema is still a plain approval.
    let (result, _) = answer_fixture(name, &DecisionResponse::Approve);
    assert_eq!(result.unwrap().1, json!({"action": "accept"}));
}

#[test]
fn question_resolution_uses_requested_answer_key() {
    let name = "LocalServerSessionClient--QuestionResolutionUsesRequestedAnswerKey.jsonl";
    assert_posts(name, &DecisionResponse::Answer("B".to_owned()));
    let (result, _) = answer_fixture(name, &DecisionResponse::Answer("C".to_owned()));
    assert_eq!(result, Err(DecisionError::NotOffered));
}

#[test]
fn typed_question_never_posts_binary_approval() {
    let name = "LocalServerSessionClient--TypedQuestionNeverPostsBinaryApproval.jsonl";
    for response in [DecisionResponse::Approve, DecisionResponse::Decline] {
        let (result, expected) = answer_fixture(name, &response);
        assert_eq!(result, Err(DecisionError::NotOffered));
        assert_eq!(expected, None);
    }
    // Cancel is the explicit way to dismiss a form.
    let (result, _) = answer_fixture(name, &DecisionResponse::Cancel);
    assert_eq!(result.unwrap().1, json!({"action": "cancel"}));
}

// --- DemoSessionClientTests ---------------------------------------------------------------------

fn demo_decisions() -> (SessionDecisions, SessionDecisions) {
    let mut design = SessionDecisions::new("demo-design");
    design.apply_request(&request(json!({
        "elicitation_id": "decision-design",
        "params": {"message": "Apply the sample design?"}
    })));
    let mut question = SessionDecisions::new("demo-question");
    question.apply_request(&request(json!({
        "elicitation_id": "decision-question",
        "params": {"message": "What should we build first?", "requestedSchema": {
            "properties": {"answer": {"enum": ["Sessions and chat", "Approvals first"]}}}}
    })));
    (design, question)
}

#[test]
fn binary_decisions_resolve_once_and_publish() {
    for (response, action) in [
        (DecisionResponse::Approve, ElicitationAction::Accept),
        (DecisionResponse::Decline, ElicitationAction::Decline),
    ] {
        let (mut design, _) = demo_decisions();
        let resolve = design
            .prepare_resolve("decision-design", &response, false)
            .unwrap();
        assert_eq!(resolve.result.action, action);
        assert_eq!(resolve.result.content, None);
        design
            .record_answered("decision-design", response.clone())
            .unwrap();
        assert_eq!(
            design.entries()[0].state,
            DecisionState::Answered(response.clone())
        );
        assert!(!design.needs_response());
        let before = design.clone();
        let already = Err(DecisionError::AlreadyResolved {
            decision_id: "decision-design".to_owned(),
        });
        assert_eq!(
            design
                .prepare_resolve("decision-design", &DecisionResponse::Approve, false)
                .map(|_| ()),
            already
        );
        assert_eq!(
            design.record_answered("decision-design", DecisionResponse::Approve),
            already
        );
        assert_eq!(design, before);
    }
}

#[test]
fn question_rejects_unknown_answer_and_binary_responses_then_accepts_an_option() {
    let (_, mut question) = demo_decisions();
    let before = question.clone();
    for response in [
        DecisionResponse::Answer("Everything".to_owned()),
        DecisionResponse::Approve,
        DecisionResponse::Decline,
    ] {
        assert_eq!(
            question.prepare_resolve("decision-question", &response, false),
            Err(DecisionError::NotOffered)
        );
    }
    assert_eq!(question, before);
    let answer = DecisionResponse::Answer("Approvals first".to_owned());
    let resolve = question
        .prepare_resolve("decision-question", &answer, false)
        .unwrap();
    assert_eq!(
        serde_json::to_value(&resolve.result).unwrap(),
        json!({"action": "accept", "content": {"answer": "Approvals first"}})
    );
    question
        .record_answered("decision-question", answer)
        .unwrap();
    assert!(!question.needs_response());
    assert!(matches!(
        question.prepare_resolve(
            "decision-question",
            &DecisionResponse::Answer("Sessions and chat".to_owned()),
            false
        ),
        Err(DecisionError::AlreadyResolved { .. })
    ));
}

#[test]
fn decision_cannot_be_answered_through_another_session_or_with_wrong_kind() {
    let (design, question) = demo_decisions();
    assert_eq!(
        question.prepare_resolve("decision-design", &DecisionResponse::Approve, false),
        Err(DecisionError::NotFound {
            decision_id: "decision-design".to_owned()
        })
    );
    assert_eq!(
        design.prepare_resolve(
            "decision-design",
            &DecisionResponse::Answer("Yes".to_owned()),
            false
        ),
        Err(DecisionError::NotOffered)
    );
    assert_eq!(
        design.prepare_resolve("decision-design", &DecisionResponse::Approve, true),
        Err(DecisionError::ReadOnly)
    );
}

// --- Permission variants and transport mapping --------------------------------------------------

#[test]
fn codex_and_antigravity_persistence_is_offered_only_when_advertised() {
    let codex = params(&json!({
        "_meta": {"codex_approval_kind": "mcp_tool_call", "persist": ["session", "always", "bogus"]}
    }));
    assert_eq!(
        codex.permissions.persist_modes,
        [PersistMode::Session, PersistMode::Always]
    );
    assert_eq!(
        serde_json::to_value(
            codex
                .result_for(&DecisionResponse::ApprovePersist(PersistMode::Always))
                .unwrap()
        )
        .unwrap(),
        json!({"action": "accept", "_meta": {"persist": "always"}})
    );
    let other_kind =
        params(&json!({"_meta": {"codex_approval_kind": "exec", "persist": "session"}}));
    assert_eq!(other_kind.permissions.persist_modes, []);
    let single =
        params(&json!({"_meta": {"codex_approval_kind": "mcp_tool_call", "persist": "session"}}));
    assert_eq!(single.permissions.persist_modes, [PersistMode::Session]);
    assert_eq!(
        single.result_for(&DecisionResponse::ApprovePersist(PersistMode::Always)),
        Err(DecisionError::NotOffered)
    );

    let agy = params(&json!({
        "phase": "agy_permission", "action_description": "Running pwd command",
        "always_allow_pattern": "pwd"
    }));
    let details = agy.permissions.antigravity.clone().unwrap();
    assert_eq!(
        details.action_description.as_deref(),
        Some("Running pwd command")
    );
    assert!(agy.detail.contains("Running pwd command"));
    assert!(
        agy.result_for(&DecisionResponse::ApprovePersist(PersistMode::Session))
            .is_ok()
    );
    let agy_without_pattern = params(&json!({"phase": "agy_permission"}));
    assert_eq!(
        agy_without_pattern.result_for(&DecisionResponse::ApprovePersist(PersistMode::Session)),
        Err(DecisionError::NotOffered)
    );
}

#[test]
fn auto_mode_and_directory_scope_post_their_flags() {
    let card = params(&json!({
        "allow_auto_mode": true, "permission_directories": ["/workspace", "/tmp/build"]
    }));
    assert_eq!(
        card.permissions.permission_directories,
        ["/workspace", "/tmp/build"]
    );
    let body = |response| serde_json::to_value(card.result_for(&response).unwrap()).unwrap();
    assert_eq!(
        body(DecisionResponse::ApproveAutoMode),
        json!({"action": "accept", "content": {"allow_auto_mode": true}})
    );
    assert_eq!(
        body(DecisionResponse::ApproveDirectories),
        json!({"action": "accept", "content": {"allow_directories": true}})
    );
    let bad_directories = params(&json!({"permission_directories": ["/workspace", ""]}));
    assert_eq!(
        bad_directories.permissions.permission_directories,
        Vec::<String>::new()
    );
    // Plan feedback must not be blank; plain decline stays available.
    let plan = params(&json!({"exit_plan_mode": {"plan": "Do it"}}));
    assert_eq!(
        plan.result_for(&DecisionResponse::DeclineWithFeedback("  ".to_owned())),
        Err(DecisionError::NotOffered)
    );
    assert!(plan.result_for(&DecisionResponse::Decline).is_ok());
}

#[test]
fn approval_event_route_carries_the_id_and_mounted_headers() {
    let card = Decision::from_request(
        &request(json!({"elicitation_id": "elicit_1", "params": {"target_session_id": "child"}})),
        "parent",
    );
    let resolve = card.resolve_request(&DecisionResponse::Approve).unwrap();
    let endpoint =
        ServerEndpoint::new("https://example.cloud.databricks.com/api/2.0/omnigent?o=123").unwrap();
    let bearer = SecretString::new("fixture-token");
    let http = resolve
        .http_request(&endpoint, Some(&bearer), ResolveRoute::ApprovalEvent)
        .unwrap();
    assert_eq!(
        http.url,
        "https://example.cloud.databricks.com/api/2.0/omnigent/v1/sessions/child/events"
    );
    let header = |name: &str| {
        http.headers
            .iter()
            .find(|header| header.name == name)
            .map(|header| header.value.as_str())
    };
    assert_eq!(header("X-Databricks-Org-Id"), Some("123"));
    assert_eq!(header("Authorization"), Some("Bearer fixture-token"));
    assert_eq!(header("Content-Type"), Some("application/json"));
    let body: Value = serde_json::from_slice(http.body.as_deref().unwrap()).unwrap();
    assert_eq!(
        body,
        json!({"type": "approval", "data": {"elicitation_id": "elicit_1", "action": "accept"}})
    );
    let bad = Decision::from_request(
        &request(json!({"elicitation_id": "../x", "params": {}})),
        "parent",
    );
    assert!(matches!(
        bad.resolve_request(&DecisionResponse::Approve),
        Err(DecisionError::InvalidIdentifier { .. })
    ));
}

#[test]
fn resolve_responses_map_every_outcome_explicitly() {
    let status = |status: u16| {
        resolve_response(Ok(HttpResponse {
            status,
            headers: Vec::new(),
            body: b"nope".to_vec(),
        }))
    };
    assert_eq!(status(202), Ok(ResolveAcknowledgement { status: 202 }));
    assert_eq!(status(302), Err(ResolveError::Redirect { status: 302 }));
    assert_eq!(status(401), Err(ResolveError::Unauthorized));
    assert_eq!(status(403), Err(ResolveError::Forbidden));
    assert_eq!(status(404), Err(ResolveError::SessionNotFound));
    assert_eq!(
        status(422),
        Err(ResolveError::Rejected {
            status: 422,
            body: "nope".to_owned()
        })
    );
    assert!(matches!(status(500), Err(ResolveError::Uncertain { .. })));
    assert!(matches!(
        resolve_response(Err(TransportError::Timeout {
            message: "slow".to_owned()
        })),
        Err(ResolveError::Uncertain { message }) if message.contains("slow")
    ));
}

#[test]
fn unknown_mode_and_non_object_schema_fail_closed() {
    assert_eq!(
        params(&json!({"mode": "telepathy"})).unsupported_reason(),
        Some(&UnsupportedReason::UnknownMode {
            mode: "telepathy".to_owned()
        })
    );
    assert_eq!(
        params(&json!({"requestedSchema": "not a schema"})).unsupported_reason(),
        Some(&UnsupportedReason::NonObjectSchema)
    );
    assert_eq!(params(&json!({})).kind, DecisionKind::Approval);
    assert_eq!(
        params(&json!({})).detail,
        "The server is waiting for your response."
    );
    assert_eq!(
        params(&json!({"requestedSchema": {"required": ["x"]}})).unsupported_reason(),
        Some(&UnsupportedReason::Schema(FormError::NotAnObjectSchema))
    );
}
