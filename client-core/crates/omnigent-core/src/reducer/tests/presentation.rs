//! Item presentation: the activity titles and summaries history and live commits share
//! (`NativeLab` `EventParityTests` presentation cases and `ConversationItemPresentationTests`).

use omnigent_protocol::{ConversationItem, FromWire};
use serde_json::{Value, json};

use super::fixture;
use crate::reducer::{ActivityKind, Row, RowRole, capitalized, display_text, project_item};

fn decode(item_type: &str, mut fields: Value) -> Row {
    fields["id"] = json!(format!("item-{item_type}"));
    fields["type"] = json!(item_type);
    fields["response_id"] = json!("fixture-response");
    fields["status"] = json!("completed");
    let item = ConversationItem::from_value(fields).expect("item decodes");
    project_item(&item).expect("projects").expect("visible")
}

type FamilyCase = (&'static str, Option<ActivityKind>, Value, &'static str);

fn transcript_cases() -> Vec<FamilyCase> {
    vec![
        (
            "message",
            None,
            json!({"role":"assistant","content":[{"type":"output_text","text":"Visible reply"}]}),
            "Visible reply",
        ),
        (
            "function_call",
            Some(ActivityKind::ToolCall),
            json!({"name":"lookup","arguments":"{\"query\":\"typed query\"}","call_id":"call"}),
            "typed query",
        ),
        (
            "function_call_output",
            Some(ActivityKind::ToolResult),
            json!({"call_id":"call","output":"Visible tool result"}),
            "Visible tool result",
        ),
        (
            "error",
            Some(ActivityKind::Error),
            json!({"code":"unavailable","source":"execution","message":"Visible failure"}),
            "Visible failure",
        ),
        (
            "reasoning",
            Some(ActivityKind::Reasoning),
            json!({"summary":[{"type":"summary_text","text":"Visible summary"}]}),
            "Visible summary",
        ),
        (
            "compaction",
            Some(ActivityKind::Compaction),
            json!({"summary":"Visible compacted summary","token_count":120,"last_item_id":"anchor"}),
            "Visible compacted summary",
        ),
        (
            "slash_command",
            Some(ActivityKind::Command),
            json!({"name":"example:review","arguments":"current changes","output":"Reviewed changes"}),
            "/example:review current changes",
        ),
        (
            "routing_decision",
            Some(ActivityKind::Routing),
            json!({"model":"fixture-model","applied":true,"rationale":"Suitable for this task"}),
            "fixture-model",
        ),
    ]
}

fn native_cases() -> Vec<FamilyCase> {
    vec![
        (
            "terminal_command",
            Some(ActivityKind::Terminal),
            json!({"kind":"input","input":"echo display-only"}),
            "echo display-only",
        ),
        (
            "web_search_call",
            Some(ActivityKind::NativeTool),
            json!({"action":{"type":"search","query":"fixture search"}}),
            "fixture search",
        ),
        (
            "file_search_call",
            Some(ActivityKind::NativeTool),
            json!({"queries":["fixture document"]}),
            "fixture document",
        ),
        (
            "code_interpreter_call",
            Some(ActivityKind::NativeTool),
            json!({"code":"print('display-only')","outputs":[{"type":"logs","logs":"display-only"}]}),
            "print('display-only')",
        ),
        (
            "computer_call",
            Some(ActivityKind::NativeTool),
            json!({"action":{"type":"screenshot"}}),
            "screenshot",
        ),
        (
            "image_generation_call",
            Some(ActivityKind::NativeTool),
            json!({"revised_prompt":"A fixture landscape","result":"EMBEDDED_IMAGE_BYTES"}),
            "A fixture landscape",
        ),
        (
            "mcp_call",
            Some(ActivityKind::NativeTool),
            json!({"name":"lookup","server_label":"fixture-server","arguments":"{\"query\":\"fixture MCP query\"}","output":"fixture MCP result"}),
            "fixture MCP query",
        ),
        (
            "mcp_list_tools",
            Some(ActivityKind::NativeTool),
            json!({"server_label":"fixture-discovery","tools":[{"name":"fixture_lookup"}]}),
            "fixture-discovery",
        ),
    ]
}

#[test]
fn all_sixteen_persisted_families_have_meaningful_typed_presentation() {
    let cases: Vec<FamilyCase> = transcript_cases()
        .into_iter()
        .chain(native_cases())
        .collect();
    assert_eq!(cases.len(), 16);
    for (item_type, kind, fields, content) in cases {
        let row = decode(item_type, fields);
        assert_eq!(row.id, format!("item-{item_type}"));
        assert_eq!(
            row.response_id.as_deref(),
            Some("fixture-response"),
            "{item_type}"
        );
        assert_eq!(row.activity_kind(), kind, "{item_type}");
        let shown = display_text(&row);
        assert!(
            shown.contains(content),
            "{item_type} lost {content}: {shown}"
        );
        assert!(!shown.contains("EMBEDDED_IMAGE_BYTES"), "{item_type}");
        assert!(!row.is_streaming);
        if kind.is_some() {
            let status = row.activity.as_ref().and_then(|a| a.status.as_deref());
            assert_eq!(
                status,
                Some(if item_type == "error" {
                    "failed"
                } else {
                    "completed"
                }),
                "{item_type}"
            );
        }
    }
}

#[test]
fn routing_distinguishes_applied_from_suggestion() {
    let applied = decode(
        "routing_decision",
        json!({"model":"fixture-model","applied":true,"rationale":"Applied rationale"}),
    );
    let suggestion = decode(
        "routing_decision",
        json!({"model":"fixture-model","applied":false,"rationale":"Suggested rationale","agent":"child-agent"}),
    );
    assert_eq!(
        applied.activity.as_ref().map(|a| a.title.as_str()),
        Some("Using fixture-model")
    );
    assert_eq!(
        suggestion.activity.as_ref().map(|a| a.title.as_str()),
        Some("Would have picked fixture-model")
    );
    assert!(display_text(&suggestion).contains("child-agent"));
    assert!(display_text(&suggestion).contains("Suggested rationale"));
}

#[test]
fn terminal_input_and_output_stay_distinct_and_keep_both_streams() {
    let input = decode(
        "terminal_command",
        json!({"kind":"input","input":"echo fixture"}),
    );
    let output = decode(
        "terminal_command",
        json!({"kind":"output","stdout":"stdout fixture","stderr":"stderr fixture"}),
    );
    assert_eq!(
        input.activity.as_ref().map(|a| a.title.as_str()),
        Some("Terminal command")
    );
    let activity = output.activity.as_ref().expect("activity");
    assert_eq!(activity.title, "Terminal output");
    let titles: Vec<&str> = activity.details.iter().map(|d| d.title.as_str()).collect();
    assert_eq!(titles, ["Standard output", "Standard error"]);
    assert!(
        display_text(&output).contains("stdout fixture")
            && display_text(&output).contains("stderr fixture")
    );
}

#[test]
fn slash_receipt_defaults_to_skill_and_preserves_invocation_and_output() {
    for kind in [None, Some("skill"), Some("command")] {
        let mut fields =
            json!({"name":"/fixture:review","arguments":"two files","output":"Receipt output"});
        if let Some(kind) = kind {
            fields["kind"] = json!(kind);
        }
        let row = decode("slash_command", fields);
        let activity = row.activity.as_ref().expect("activity");
        assert_eq!(activity.kind, ActivityKind::Command);
        assert!(display_text(&row).contains("/fixture:review two files"));
        assert!(display_text(&row).contains("Receipt output"));
        let prefix = if kind == Some("command") {
            "Command"
        } else {
            "Skill"
        };
        assert!(activity.title.starts_with(prefix), "{kind:?}");
    }
}

#[test]
fn resource_receipts_distinguish_create_and_delete_without_losing_identity() {
    let created = decode(
        "resource_event",
        json!({"event_type":"session.resource.created","resource_type":"terminal","resource_id":"term-1","resource":{"name":"Build terminal","id":"term-1","type":"terminal"}}),
    );
    let deleted = decode(
        "resource_event",
        json!({"event_type":"session.resource.deleted","resource_type":"terminal","resource_id":"term-1"}),
    );
    assert_eq!(created.activity_kind(), Some(ActivityKind::Resource));
    assert_eq!(
        created.activity.as_ref().map(|a| a.title.as_str()),
        Some("Terminal created")
    );
    assert_eq!(
        deleted.activity.as_ref().map(|a| a.title.as_str()),
        Some("Terminal deleted")
    );
    assert!(
        display_text(&created).contains("Build terminal")
            && display_text(&created).contains("term-1")
    );
    assert!(display_text(&deleted).contains("term-1"));
}

#[test]
fn hidden_context_and_unknown_roles_are_explicit() {
    let items = fixture(
        "items/EventParity--ContextFilteringMatchesWholeLegacyNotificationNotLooseMarkers.json",
    );
    let shown: Vec<Option<String>> = items
        .as_array()
        .expect("items")
        .iter()
        .map(|item| {
            let item = ConversationItem::from_value(item.clone()).expect("decodes");
            project_item(&item).expect("projects").map(|row| row.text)
        })
        .collect();
    assert_eq!(
        shown.iter().filter(|text| text.is_none()).count(),
        3,
        "{shown:?}"
    );
    let item = ConversationItem::from_value(
        json!({"id":"m","type":"message","role":"system","content":"x"}),
    )
    .expect("decodes");
    assert!(project_item(&item).is_err());
}

#[test]
fn private_blocks_never_reach_a_row_and_unknown_items_are_safe_placeholders() {
    let item = fixture(
        "items/ConversationItemPresentation--NestedUnknownPayloadSanitizesCredentialsAndPrivateReasoning.json",
    );
    let item = ConversationItem::from_value(item).expect("decodes");
    let row = project_item(&item).expect("projects").expect("visible");
    assert_eq!(row.activity_kind(), Some(ActivityKind::Unknown));
    assert_eq!(row.role, RowRole::Tool);
    assert!(!display_text(&row).contains("PRIVATE_"));
    assert_eq!(capitalized("in progress"), "In Progress");
}
