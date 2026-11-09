use serde_json::json;

use super::*;
use crate::content::AttachmentKind;
use crate::display::safe_display_text;
use crate::page::Page;
use crate::sessions::{ItemPage, SessionSnapshot, SessionStatus};
use crate::test_support::{all_fixtures, fixture, fixture_lines, response};

fn decode(value: Value) -> ConversationItem {
    let text = value.to_string();
    ConversationItem::from_value(value).unwrap_or_else(|error| panic!("{text}: {error}"))
}

fn decode_all(path: &str) -> Vec<ConversationItem> {
    match fixture(path) {
        Value::Array(values) => values.into_iter().map(decode).collect(),
        value => vec![decode(value)],
    }
}

fn page(path: &str) -> ItemPage {
    ItemPage::from_value(response(&fixture(path))).unwrap()
}

fn encoded(item: &ConversationItem) -> String {
    serde_json::to_string(item).unwrap()
}

/// Every piece of public text the typed accessors expose, for "the content is reachable" checks.
fn visible(item: &ConversationItem) -> String {
    let parts: Vec<String> = match &item.data {
        ItemData::Message(message) => vec![message.visible_text()],
        ItemData::FunctionCall(call) => vec![call.name.clone(), call.safe_arguments()],
        ItemData::FunctionCallOutput(output) => vec![output.output.safe_text()],
        ItemData::Error(error) => vec![error.code.clone(), error.message.clone()],
        ItemData::Reasoning(reasoning) => vec![reasoning.public_summary()],
        ItemData::Compaction(compaction) => vec![compaction.summary.clone()],
        ItemData::NativeTool(native) => vec![
            native.item.safe_summary().unwrap_or_default(),
            native.item.safe_detail(),
        ],
        ItemData::ResourceEvent(resource) => vec![
            resource.resource_name().unwrap_or_default().to_owned(),
            resource.resource_id.clone(),
        ],
        ItemData::RoutingDecision(routing) => vec![
            routing.model.clone(),
            routing.rationale.clone(),
            routing.agent.clone().unwrap_or_default(),
        ],
        ItemData::SlashCommand(slash) => {
            vec![slash.invocation(), slash.output.clone().unwrap_or_default()]
        }
        ItemData::TerminalCommand(terminal) => {
            [&terminal.input, &terminal.stdout, &terminal.stderr]
                .into_iter()
                .flatten()
                .cloned()
                .collect()
        }
        ItemData::Unknown { raw, .. } => vec![safe_display_text(raw)],
    };
    parts.join("\n")
}

#[test]
fn all_sixteen_persisted_families_have_meaningful_typed_presentation() {
    let items = decode_all(
        "items/EventParity--AllSixteenPersistedFamiliesHaveMeaningfulTypedPresentation.json",
    );
    let expected = [
        ("message", "Visible reply"),
        ("function_call", "typed query"),
        ("function_call_output", "Visible tool result"),
        ("error", "Visible failure"),
        ("reasoning", "Visible summary"),
        ("compaction", "Visible compacted summary"),
        ("slash_command", "/example:review current changes"),
        ("routing_decision", "fixture-model"),
        ("terminal_command", "echo display-only"),
        ("web_search_call", "fixture search"),
        ("file_search_call", "fixture document"),
        ("code_interpreter_call", "print('display-only')"),
        ("computer_call", "screenshot"),
        ("image_generation_call", "A fixture landscape"),
        ("mcp_call", "fixture MCP query"),
        ("mcp_list_tools", "fixture-discovery"),
    ];
    assert_eq!(items.len(), 16);
    for (item, (family, content)) in items.iter().zip(expected) {
        assert_eq!(item.id, format!("item-{family}"));
        assert_eq!(
            item.response_id.as_deref(),
            Some("fixture-response"),
            "{family}"
        );
        assert_eq!(item.status, Some(ItemStatus::Completed), "{family}");
        assert!(!matches!(item.data, ItemData::Unknown { .. }), "{family}");
        let wire = if BARE_NATIVE_TOOL_TYPES.contains(&family) {
            assert_eq!(
                item.native_tool_kind().map(NativeToolKind::as_str),
                Some(family)
            );
            "native_tool"
        } else {
            family
        };
        assert_eq!(item.item_type(), wire, "{family}");
        let text = visible(item);
        assert!(text.contains(content), "{family} lost {content:?}: {text}");
        assert!(!text.contains("EMBEDDED_IMAGE_BYTES"), "{family}: {text}");
    }
    let image = items.get(13).unwrap();
    let ItemData::NativeTool(native) = &image.data else {
        panic!("{image:?}")
    };
    assert!(native.item.has_generated_image());
}

#[test]
fn every_native_tool_survives_wrapper_without_becoming_unknown() {
    let items =
        decode_all("items/EventParity--EveryNativeToolSurvivesWrapperWithoutBecomingUnknown.json");
    assert_eq!(items.len(), 7);
    for (item, kind) in items.iter().zip(BARE_NATIVE_TOOL_TYPES) {
        let ItemData::NativeTool(native) = &item.data else {
            panic!("{item:?}")
        };
        assert_eq!(native.item.kind.as_str(), *kind);
        assert!(!native.item.kind.is_unknown());
        assert_eq!(native.item.status(), Some("completed"));
        assert_eq!(item.data.call_id(), Some("call"));
        assert_eq!(item.response_id.as_deref(), Some("response"));
        assert!(
            native
                .item
                .safe_detail()
                .contains("Visible provider detail")
        );
    }
}

#[test]
fn tool_calls_and_results_keep_response_and_call_identity() {
    let items =
        decode_all("items/EventParity--ToolCallsAndResultsKeepResponseAndCallIdentity.json");
    for (item, family) in items.iter().zip(["function_call", "function_call_output"]) {
        assert_eq!(item.item_type(), family);
        assert_eq!(item.id, format!("item-{family}"));
        assert_eq!(item.data.call_id(), Some("shared-call"));
        assert_eq!(item.response_id.as_deref(), Some("fixture-response"));
    }
}

#[test]
fn routing_distinguishes_applied_from_suggestion() {
    let items = decode_all("items/EventParity--RoutingDistinguishesAppliedFromSuggestion.json");
    let [applied, suggestion] = items.as_slice() else {
        panic!("{items:?}")
    };
    let (ItemData::RoutingDecision(applied), ItemData::RoutingDecision(suggestion)) =
        (&applied.data, &suggestion.data)
    else {
        panic!("{items:?}")
    };
    assert!(applied.applied);
    assert_eq!(applied.model, "fixture-model");
    assert!(!suggestion.applied);
    assert_eq!(suggestion.model, "fixture-model");
    assert_eq!(suggestion.agent.as_deref(), Some("child-agent"));
    assert_eq!(suggestion.rationale, "Suggested rationale");
}

#[test]
fn slash_receipt_defaults_to_skill_and_preserves_invocation_and_output() {
    let items = decode_all(
        "items/EventParity--SlashReceiptDefaultsToSkillAndPreservesInvocationAndOutput.json",
    );
    let kinds = [
        SlashCommandKind::Skill,
        SlashCommandKind::Skill,
        SlashCommandKind::Command,
    ];
    for (item, kind) in items.iter().zip(kinds) {
        let ItemData::SlashCommand(slash) = &item.data else {
            panic!("{item:?}")
        };
        assert_eq!(slash.kind, kind);
        assert_eq!(slash.invocation(), "/fixture:review two files");
        assert_eq!(slash.output.as_deref(), Some("Receipt output"));
    }
}

#[test]
fn terminal_input_and_output_stay_distinct_and_keep_both_streams() {
    let items =
        decode_all("items/EventParity--TerminalInputAndOutputStayDistinctAndKeepBothStreams.json");
    let [input, output] = items.as_slice() else {
        panic!("{items:?}")
    };
    let (ItemData::TerminalCommand(input), ItemData::TerminalCommand(output)) =
        (&input.data, &output.data)
    else {
        panic!("{items:?}")
    };
    assert_eq!(input.kind, TerminalCommandKind::Input);
    assert_eq!(input.input.as_deref(), Some("echo fixture"));
    assert_eq!(output.kind, TerminalCommandKind::Output);
    assert_eq!(output.stdout.as_deref(), Some("stdout fixture"));
    assert_eq!(output.stderr.as_deref(), Some("stderr fixture"));
}

#[test]
fn resource_receipts_distinguish_create_and_delete_without_losing_identity() {
    let items = decode_all(
        "items/EventParity--ResourceReceiptsDistinguishCreateAndDeleteWithoutLosingIdentity.json",
    );
    let [created, deleted] = items.as_slice() else {
        panic!("{items:?}")
    };
    let (ItemData::ResourceEvent(created), ItemData::ResourceEvent(deleted)) =
        (&created.data, &deleted.data)
    else {
        panic!("{items:?}")
    };
    assert_eq!(created.action(), ResourceAction::Created);
    assert_eq!(created.resource_type, "terminal");
    assert_eq!(created.resource_name(), Some("Build terminal"));
    assert_eq!(created.resource_id, "term-1");
    assert_eq!(deleted.action(), ResourceAction::Deleted);
    assert_eq!(deleted.resource_id, "term-1");
    assert_eq!(deleted.resource_name(), None);
}

#[test]
fn context_filtering_matches_whole_legacy_notification_not_loose_markers() {
    let items = decode_all(
        "items/EventParity--ContextFilteringMatchesWholeLegacyNotificationNotLooseMarkers.json",
    );
    let hidden: Vec<bool> = items
        .iter()
        .map(ConversationItem::is_hidden_context)
        .collect();
    assert_eq!(hidden, [true, true, false, false, false, true]);
    let ItemData::Message(lookalike) = &items.get(2).unwrap().data else {
        panic!()
    };
    assert_eq!(
        lookalike.visible_text(),
        "Explain <task-notification> markup."
    );
}

// The Swift fixture is a NativeLab `ConversationMessage`, a presentation type. The wire-level
// equivalent: an item without any of the newer optional fields decodes with defaults and
// round-trips.
#[test]
fn legacy_conversation_messages_decode_without_new_fields() {
    let legacy = fixture(
        "items/ConversationItemPresentation--LegacyConversationMessagesDecodeWithoutNewFields.json",
    );
    assert_eq!(legacy["text"], "Hello");
    let item = decode(
        json!({"id": legacy["id"], "type": "message", "role": legacy["role"],
                             "content": [{"type": "output_text", "text": legacy["text"]}]}),
    );
    let ItemData::Message(message) = &item.data else {
        panic!("{item:?}")
    };
    assert_eq!(message.visible_text(), "Hello");
    assert_eq!(message.role, MessageRole::Assistant);
    assert_eq!(
        (
            item.status.as_ref(),
            item.response_id.as_deref(),
            item.created_by.as_deref()
        ),
        (None, None, None)
    );
    assert_eq!(message.agent, None);
    assert!(!message.interrupted && !message.is_meta && !message.user_authored);
    assert_eq!(message.attachments().count(), 0);
    let round_trip = decode(serde_json::to_value(&item).unwrap());
    assert_eq!(round_trip, item);
}

#[test]
fn attachment_descriptors_preserve_text_without_embedding_or_fetching_content() {
    let item = decode(fixture(
        "items/ConversationItemPresentation--AttachmentDescriptorsPreserveTextWithoutEmbeddingOrFetchingContent.json",
    ));
    let ItemData::Message(message) = &item.data else {
        panic!("{item:?}")
    };
    assert_eq!(message.visible_text(), "Inspect these");
    assert_eq!(item.response_id.as_deref(), Some("r1"));
    let attachments: Vec<&AttachmentPart> = message.attachments().collect();
    let kinds: Vec<_> = attachments.iter().map(|a| a.kind).collect();
    assert_eq!(
        kinds,
        [
            AttachmentKind::Image,
            AttachmentKind::File,
            AttachmentKind::Image,
            AttachmentKind::Audio
        ]
    );
    assert_eq!(attachments[0].reference(), Some("file1"));
    assert_eq!(attachments[0].filename.as_deref(), Some("diagram.png"));
    assert_eq!(attachments[1].mime_type.as_deref(), Some("application/pdf"));
    assert!(attachments[2].embedded);
    assert_eq!(attachments[2].reference(), None);
    assert!(attachments[3].embedded);
    assert_eq!(attachments[3].mime_type.as_deref(), Some("audio/wav"));
    assert!(!encoded(&item).contains("PRIVATE_"));
}

#[test]
fn refusals_and_interrupted_messages_remain_visible() {
    let item = decode(fixture(
        "items/ConversationItemPresentation--RefusalsAndInterruptedMessagesRemainVisible.json",
    ));
    let ItemData::Message(message) = &item.data else {
        panic!("{item:?}")
    };
    assert_eq!(
        message.visible_text(),
        "Partial response\nI cannot provide that."
    );
    assert!(message.interrupted);
}

#[test]
fn message_attribution_preserves_human_and_agent_identity() {
    let items = decode_all(
        "items/ConversationItemPresentation--MessageAttributionPreservesHumanAndAgentIdentity.json",
    );
    let [user, assistant] = items.as_slice() else {
        panic!("{items:?}")
    };
    let (ItemData::Message(user_message), ItemData::Message(assistant_message)) =
        (&user.data, &assistant.data)
    else {
        panic!("{items:?}")
    };
    assert_eq!(user.created_by.as_deref(), Some("person@example.test"));
    assert_eq!(user_message.agent, None);
    assert_eq!(assistant_message.agent.as_deref(), Some("child-agent"));
    assert_eq!(assistant.created_by, None);
}

#[test]
fn reasoning_never_falls_back_to_raw_or_encrypted_content() {
    let items = decode_all(
        "items/ConversationItemPresentation--ReasoningNeverFallsBackToRawOrEncryptedContent.json",
    );
    let [with_summary, without_summary] = items.as_slice() else {
        panic!("{items:?}")
    };
    let (ItemData::Reasoning(first), ItemData::Reasoning(second)) =
        (&with_summary.data, &without_summary.data)
    else {
        panic!("{items:?}")
    };
    assert_eq!(first.public_summary(), "Checked the available options.");
    assert_eq!(second.public_summary(), "");
    for item in &items {
        let text = encoded(item);
        for secret in ["HIDDEN_", "ENCRYPTED_SECRET", "PRIVATE"] {
            assert!(!text.contains(secret), "{text}");
        }
    }
}

#[test]
fn nested_unknown_payload_sanitizes_credentials_and_private_reasoning() {
    let item = decode(fixture(
        "items/ConversationItemPresentation--NestedUnknownPayloadSanitizesCredentialsAndPrivateReasoning.json",
    ));
    let ItemData::Unknown { item_type, raw } = &item.data else {
        panic!("{item:?}")
    };
    assert_eq!(item_type, "future_result");
    let text = safe_display_text(raw);
    assert!(text.contains("Useful future activity"), "{text}");
    assert!(text.contains("Kept result"), "{text}");
    assert!(text.contains("Public output"), "{text}");
    assert!(!text.contains("PRIVATE_"), "{text}");
    assert!(!text.contains("preview not supported"), "{text}");
}

#[test]
fn json_encoded_tool_arguments_and_output_are_sanitized() {
    let items = decode_all(
        "items/ConversationItemPresentation--JSONEncodedToolArgumentsAndOutputAreSanitized.json",
    );
    let [call, output] = items.as_slice() else {
        panic!("{items:?}")
    };
    let (ItemData::FunctionCall(call_data), ItemData::FunctionCallOutput(output_data)) =
        (&call.data, &output.data)
    else {
        panic!("{items:?}")
    };
    assert_eq!(call.data.call_id(), Some("c1"));
    assert_eq!(call.response_id.as_deref(), Some("r1"));
    assert_eq!(call_data.safe_arguments(), "query: weather");
    let result = output_data.output.safe_text();
    assert!(result.contains("Clear skies"), "{result}");
    assert!(!result.contains("PRIVATE_TOKEN"), "{result}");
}

#[test]
fn incomplete_structured_arguments_never_expose_private_values() {
    let call = decode(
        json!({"id": "c", "type": "function_call", "name": "request",
                             "arguments": "{\"encrypted_content\":\"PRIVATE_PARTIAL"}),
    );
    let ItemData::FunctionCall(call) = &call.data else {
        panic!("{call:?}")
    };
    assert_eq!(call.safe_arguments(), display::INCOMPLETE_PAYLOAD);
    assert_eq!(
        display::safe_display_str("[Tool output unavailable]"),
        "[Tool output unavailable]"
    );
}

#[test]
fn unknown_payloads_are_bounded_by_characters_depth_and_entry_count() {
    let mut nested = json!("UNREACHABLE_DEPTH");
    for _ in 0..20 {
        nested = json!({"next": nested});
    }
    let item = decode(json!({
        "id": "large", "type": "future_item",
        "body": "visible output ".repeat(10_000),
        "nested": nested,
        "items": (0..1_000).map(|index| format!("entry-{index}")).collect::<Vec<_>>(),
    }));
    let ItemData::Unknown { raw, .. } = &item.data else {
        panic!("{item:?}")
    };
    let text = safe_display_text(raw);
    assert!(text.chars().count() <= 16_012, "{}", text.chars().count());
    assert!(text.contains("Truncated"));
    assert!(!text.contains("entry-999"));
    assert!(!text.contains("UNREACHABLE_DEPTH"));
}

#[test]
fn message_private_blocks_do_not_become_unknown_content_cards() {
    let item = decode(fixture(
        "items/ConversationItemPresentation--MessagePrivateBlocksDoNotBecomeUnknownContentCards.json",
    ));
    let ItemData::Message(message) = &item.data else {
        panic!("{item:?}")
    };
    assert_eq!(message.visible_text(), "Visible");
    assert!(
        message
            .content
            .iter()
            .all(|part| !matches!(part, ContentPart::Unknown { .. }))
    );
    assert!(!encoded(&item).contains("PRIVATE"));
}

#[test]
fn new_content_blocks_have_useful_safe_details() {
    let item = decode(fixture(
        "items/ConversationItemPresentation--NewContentBlocksHaveUsefulSafeDetails.json",
    ));
    let ItemData::Message(message) = &item.data else {
        panic!("{item:?}")
    };
    let [ContentPart::Unknown { part_type, detail }] = message.content.as_slice() else {
        panic!("{message:?}")
    };
    assert_eq!(part_type, "future_chart");
    assert!(detail.contains("Quarterly totals"), "{detail}");
    assert!(!encoded(&item).contains("PRIVATE"));
}

#[test]
fn persisted_runner_failure_remains_readable_after_reopening_without_last_task_error() {
    let snapshot = SessionSnapshot::from_value(response(&fixture(
        "sessions/LocalServerSessionClient--PersistedRunnerFailureRemainsReadableAfterReopeningWithoutLastTaskError--session.json",
    )))
    .unwrap();
    assert_eq!(snapshot.status, SessionStatus::Failed);
    assert_eq!(snapshot.last_task_error, crate::field::Field::Null);
    assert_eq!(
        snapshot.failure_message(),
        Some(crate::sessions::DEFAULT_FAILURE_MESSAGE)
    );
    let history = page(
        "items/LocalServerSessionClient--PersistedRunnerFailureRemainsReadableAfterReopeningWithoutLastTaskError--history.json",
    );
    let reopened = page(
        "items/LocalServerSessionClient--PersistedRunnerFailureRemainsReadableAfterReopeningWithoutLastTaskError--history.json",
    );
    assert_eq!(history, reopened);
    let ids: Vec<&str> = history.data.iter().map(|item| item.id.as_str()).collect();
    assert_eq!(ids, ["error_1", "user_1"]);
    let ItemData::Error(error) = &history.data[0].data else {
        panic!("{history:?}")
    };
    assert_eq!(error.code, "runner_failed_to_start");
    assert_eq!(error.source, Some(ErrorSource::Execution));
    assert!(
        error
            .message
            .starts_with("The runner for this session is not available")
    );
}

#[test]
fn malformed_persisted_errors_do_not_hide_missing_cause_behind_unsupported_preview() {
    let exchanges = fixture_lines(
        "items/LocalServerSessionClient--MalformedPersistedErrorsDoNotHideMissingCauseBehindUnsupportedPreview.jsonl",
    );
    assert_eq!(exchanges.len(), 4);
    for exchange in exchanges {
        let body = response(&exchange);
        let error = ItemPage::from_value(body.clone()).unwrap_err();
        assert!(
            matches!(error, DecodeError::Invalid { .. }),
            "{body}: {error:?}"
        );
    }
    for shape in [
        json!({"id": "e", "type": "error", "code": "x", "message": " "}),
        json!({"id": "e", "type": "error", "data": {"code": "", "message": "m"}}),
    ] {
        assert!(ConversationItem::from_value(shape).is_err());
    }
}

#[test]
fn history_pages_use_stored_order_and_preserve_typed_content() {
    let history = page(
        "items/LocalServerSessionClient--HistoryPagesUseStoredOrderAndPreserveTypedContent.json",
    );
    let ids: Vec<&str> = history.data.iter().map(|item| item.id.as_str()).collect();
    assert_eq!(ids, ["msg_z", "msg_a", "msg_a", "tool_1", "reason_1"]);
    assert_eq!(
        history.next_cursor(Some("cursor +&?")),
        Ok(Some("reason_1"))
    );
    let ItemData::Message(assistant) = &history.data[0].data else {
        panic!()
    };
    assert_eq!(assistant.visible_text(), "Hello\nWorld");
    let ItemData::Message(user) = &history.data[1].data else {
        panic!()
    };
    assert_eq!(user.role, MessageRole::User);
    assert_eq!(user.visible_text(), "See picture");
    let image = user.attachments().next().unwrap();
    assert_eq!(image.kind, AttachmentKind::Image);
    assert_eq!(image.reference(), Some("ignored"));
    let ItemData::FunctionCall(call) = &history.data[3].data else {
        panic!()
    };
    assert_eq!(
        (call.name.as_str(), call.safe_arguments().as_str()),
        ("read_file", "file.txt")
    );
    let ItemData::Reasoning(reasoning) = &history.data[4].data else {
        panic!()
    };
    assert_eq!(reasoning.public_summary(), "");
}

#[test]
fn empty_history_and_tool_outputs() {
    let empty = page("items/LocalServerSessionClient--EmptyHistoryAndToolOutputs--empty.json");
    assert_eq!(empty.data, Vec::<ConversationItem>::new());
    assert_eq!(empty.next_cursor(None), Ok(None));
    let output =
        page("items/LocalServerSessionClient--EmptyHistoryAndToolOutputs--tool-output.json");
    let [item] = output.data.as_slice() else {
        panic!("{output:?}")
    };
    let ItemData::FunctionCallOutput(data) = &item.data else {
        panic!("{item:?}")
    };
    assert_eq!(data.output.safe_text(), "Result");
    assert_eq!(data.call_id, None);
}

#[test]
fn hidden_meta_messages_do_not_leak_and_an_all_meta_page_keeps_its_cursor() {
    let hidden = page(
        "items/LocalServerSessionClient--HiddenMetaMessagesDoNotLeakAndAnAllMetaPageKeepsItsCursor--meta-page.json",
    );
    assert!(hidden.data.iter().all(ConversationItem::is_hidden_context));
    assert_eq!(hidden.next_cursor(None), Ok(Some("meta_1")));
    let visible_page = page(
        "items/LocalServerSessionClient--HiddenMetaMessagesDoNotLeakAndAnAllMetaPageKeepsItsCursor--visible-page.json",
    );
    let texts: Vec<String> = visible_page
        .data
        .iter()
        .filter(|item| !item.is_hidden_context())
        .map(visible)
        .collect();
    assert_eq!(texts, ["Visible user text"]);
    assert_eq!(visible_page.next_cursor(Some("meta_1")), Ok(None));
}

// The `/v1/info` half of this Swift test is server discovery (WP6); this ports the history half.
#[test]
fn malformed_responses_and_history_are_not_reported_as_empty_success() {
    let exchanges = fixture_lines(
        "items/LocalServerSessionClient--MalformedResponsesAndHistoryAreNotReportedAsEmptySuccess--items.jsonl",
    );
    assert_eq!(exchanges.len(), 4);
    for exchange in exchanges {
        let body = response(&exchange);
        assert!(ItemPage::from_value(body.clone()).is_err(), "{body}");
    }
    assert!(ItemPage::from_json(b"not json").is_err());
    assert!(ItemPage::from_value(json!({})).is_err());
    assert!(ItemPage::from_value(json!({"data": "x", "has_more": false})).is_err());
}

#[test]
fn flat_and_nested_shapes_decode_to_the_same_item() {
    let flat = decode(
        json!({"id": "e1", "type": "error", "status": "completed", "response_id": "r",
                             "source": "execution", "code": "boom", "message": "Broke"}),
    );
    let nested = decode(
        json!({"id": "e1", "type": "error", "status": "completed", "response_id": "r",
                               "data": {"source": "execution", "code": "boom", "message": "Broke"}}),
    );
    assert_eq!(flat, nested);
    let ItemData::Error(error) = &flat.data else {
        panic!("{flat:?}")
    };
    assert_eq!(
        (error.code.as_str(), error.message.as_str()),
        ("boom", "Broke")
    );
}

#[test]
fn bare_provider_items_normalise_to_the_native_tool_wrapper() {
    let item = decode(
        json!({"id": "w", "type": "web_search_call", "status": "completed",
                             "action": {"type": "search", "query": "q"}}),
    );
    assert_eq!(item.item_type(), "native_tool");
    let value = serde_json::to_value(&item).unwrap();
    assert_eq!(value["item"]["type"], "web_search_call");
    assert_eq!(decode(value), item);
}

#[test]
fn known_types_with_broken_shapes_are_errors_not_unknown() {
    for value in [
        json!({"id": "m", "type": "message", "content": "missing role"}),
        json!({"id": "f", "type": "function_call", "name": 3, "arguments": "{}"}),
        json!({"id": "n", "type": "native_tool"}),
        json!({"id": "n", "type": "native_tool", "item": {"call_id": "untyped"}}),
        json!({"id": "t", "type": "terminal_command"}),
        json!({"id": "s", "type": "message", "status": 7, "role": "user", "content": "x"}),
        json!({"type": "message", "role": "user", "content": "no id"}),
        json!({"id": "x"}),
        json!("message"),
    ] {
        assert!(
            ConversationItem::from_value(value.clone()).is_err(),
            "{value}"
        );
    }
}

#[test]
fn every_item_in_every_fixture_decodes() {
    let malformed = [
        "MalformedPersistedErrorsDoNotHideMissingCauseBehindUnsupportedPreview",
        "MalformedResponsesAndHistoryAreNotReportedAsEmptySuccess",
    ];
    let mut count = 0;
    for (path, values) in all_fixtures() {
        if malformed.iter().any(|name| path.contains(name)) || path.starts_with("manifest/") {
            continue;
        }
        for value in values {
            for page_value in item_pages(&value) {
                let decoded = Page::<ConversationItem>::from_value(page_value.clone())
                    .unwrap_or_else(|error| panic!("{path}: {error}\n{page_value}"));
                count += decoded.data.len();
            }
        }
    }
    assert!(count >= 25, "{count}");
}

/// Item pages inside an HTTP envelope (`/items` responses).
fn item_pages(value: &Value) -> Vec<Value> {
    let is_items_path = value
        .pointer("/request/path")
        .and_then(Value::as_str)
        .is_some_and(|path| path.ends_with("/items"));
    match value.get("response") {
        Some(body @ Value::Object(_)) if is_items_path => vec![body.clone()],
        _ => Vec::new(),
    }
}

#[test]
fn recorded_item_pages_snapshot() {
    for name in [
        "recorded-items-page-1",
        "recorded-items-page-2",
        "recorded-items-page-3",
        "recorded-items-desc-page-1",
    ] {
        let decoded = page(&format!("items/{name}.json"));
        insta::assert_json_snapshot!(name, decoded);
    }
}

#[test]
fn recorded_nested_snapshot_items_match_flat_pages() {
    let snapshot = SessionSnapshot::from_value(response(&fixture(
        "items/recorded-session-snapshot-after-turn.json",
    )))
    .unwrap();
    let flat: Vec<ConversationItem> = (1..=3)
        .flat_map(|index| page(&format!("items/recorded-items-page-{index}.json")).data)
        .collect();
    let nested_ids: Vec<&str> = snapshot.items.iter().map(|item| item.id.as_str()).collect();
    let flat_ids: Vec<&str> = flat.iter().map(|item| item.id.as_str()).collect();
    assert!(flat_ids.starts_with(&nested_ids) || nested_ids.starts_with(&flat_ids));
    for (nested, flat) in snapshot.items.iter().zip(&flat) {
        assert_eq!(nested.data, flat.data, "{}", nested.id);
    }
}

#[test]
fn resource_events_without_a_known_suffix_read_as_updated() {
    let item = decode(
        json!({"id": "i", "type": "resource_event", "event_type": "browser.moved",
        "resource_id": "r", "resource_type": "browser"}),
    );
    let ItemData::ResourceEvent(event) = &item.data else {
        panic!("{item:?}");
    };
    assert_eq!(event.action(), ResourceAction::Updated);
}

#[test]
fn a_slash_command_without_arguments_is_just_its_name() {
    let item = decode(json!({"id": "i", "type": "slash_command", "name": "/compact"}));
    let ItemData::SlashCommand(command) = &item.data else {
        panic!("{item:?}");
    };
    assert_eq!(command.invocation(), "/compact");
}

#[test]
fn unknown_items_round_trip_and_never_count_as_context_free() {
    let item = decode(json!({"id": "i", "type": "brand_new", "extra": 7}));
    assert_eq!(item.data.wire_type(), "brand_new");
    assert!(!item.data.is_context_free());
    assert_eq!(item.native_tool_kind(), None);
    assert_eq!(serde_json::to_value(&item).unwrap()["extra"], 7);
    let compaction = decode(json!({"id": "c", "type": "compaction", "summary": "s"}));
    assert_eq!(compaction.data.wire_type(), "compaction");
}

#[test]
fn every_typed_item_serialises_with_its_type() {
    for raw in [
        json!({"id": "a", "type": "compaction", "summary": "s"}),
        json!({"id": "b", "type": "routing_decision", "model": "m", "applied": true}),
        json!({"id": "c", "type": "slash_command", "name": "x"}),
        json!({"id": "d", "type": "terminal_command", "kind": "input", "input": "ls"}),
    ] {
        let item = decode(raw.clone());
        assert_eq!(serde_json::to_value(&item).unwrap()["type"], raw["type"]);
    }
}

#[test]
fn a_data_field_that_is_not_an_object_stays_with_the_item() {
    let item = decode(json!({"id": "i", "type": "web_search_call", "data": 7}));
    let ItemData::NativeTool(native) = &item.data else {
        panic!("{item:?}");
    };
    assert_eq!(native.item.fields["data"], 7);
}

#[test]
fn a_native_tool_wrapper_needs_an_object_item() {
    assert!(ConversationItem::from_value(json!({"id": "i", "type": "native_tool"})).is_err());
    assert!(
        ConversationItem::from_value(json!({"id": "i", "type": "native_tool", "item": 7})).is_err()
    );
    assert!(
        ItemData::decode(
            "native_tool",
            Value::Null.as_object().cloned().unwrap_or_default()
        )
        .is_err()
    );
}

#[test]
fn reasoning_summaries_of_the_wrong_shape_fail_to_decode() {
    for summary in [
        json!([7]),
        json!([{"text": "no type"}]),
        json!([{"type": "summary_text"}]),
    ] {
        assert!(
            ConversationItem::from_value(json!({
                "id": "i", "type": "reasoning", "summary": summary
            }))
            .is_err(),
            "{summary}"
        );
    }
}

#[test]
fn a_native_tool_wrapper_that_is_not_an_object_is_refused() {
    assert!(matches!(
        native_tool_wrapper(Value::Null),
        Err(DecodeError::NotAnObject { context }) if context == "item `native_tool`"
    ));
}

#[test]
fn a_value_that_must_serialize_as_an_object_says_what_it_was() {
    let refused: Result<Map<String, Value>, serde_json::Error> =
        serialized_object(Value::Null, "item data");
    assert_eq!(
        refused.unwrap_err().to_string(),
        "item data must serialise as an object"
    );
    let fields = Map::from_iter([("a".to_owned(), Value::Bool(true))]);
    let kept: Result<Map<String, Value>, serde_json::Error> =
        serialized_object(Value::Object(fields.clone()), "item data");
    assert_eq!(kept.unwrap(), fields);
}
