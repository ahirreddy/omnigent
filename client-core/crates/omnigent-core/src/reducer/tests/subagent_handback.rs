//! A Claude sub-agent's `SubagentHandback` call is its answer: the report shows as the agent's
//! final message, and the result that only confirms delivery is hidden.

use omnigent_protocol::{ConversationItem, FromWire};
use serde_json::{Value, json};

use super::{Harness, assistant};
use crate::reconcile::history_rows;
use crate::reducer::{ActivityKind, Row, RowRole};

const SESSION: &str = "child";
const DELIVERED: &str = r#"{"success":true,"message":"Report delivered."}"#;

fn handback(id: &str, call: &str, arguments: &Value) -> Value {
    json!({
        "id": id, "type": "function_call", "name": "SubagentHandback", "call_id": call,
        "arguments": arguments.to_string(), "response_id": "r1", "status": "completed",
    })
}

fn result(id: &str, call: &str) -> Value {
    json!({
        "id": id, "type": "function_call_output", "call_id": call, "output": DELIVERED,
        "response_id": "r1", "status": "completed",
    })
}

fn items(values: &[Value]) -> Vec<ConversationItem> {
    values
        .iter()
        .map(|value| ConversationItem::from_value(value.clone()).expect("item decodes"))
        .collect()
}

fn shown(rows: &[Row]) -> Vec<(RowRole, Option<ActivityKind>, &str)> {
    rows.iter()
        .map(|row| (row.role, row.activity_kind(), row.text.as_str()))
        .collect()
}

#[test]
fn a_handed_back_report_reads_as_the_answer_and_its_receipt_is_hidden() {
    let rows = history_rows(&items(&[
        handback("fc_c2", "c2", &json!({"message": "**Audit** done."})),
        result("out_c2", "c2"),
    ]))
    .expect("projects");
    assert_eq!(
        shown(&rows),
        [(RowRole::Assistant, None, "**Audit** done.")],
        "the report is the answer, with no tool rows"
    );
    assert_eq!(rows[0].call_id.as_deref(), Some("c2"));
    assert!(rows[0].is_handback_report());
}

#[test]
fn a_handback_without_a_report_stays_a_tool_row() {
    for arguments in [json!({"message": "  "}), json!({}), json!({"message": 3})] {
        let rows = history_rows(&items(&[
            handback("fc_c1", "c1", &arguments),
            result("out_c1", "c1"),
        ]))
        .expect("projects");
        let kinds: Vec<_> = rows.iter().map(Row::activity_kind).collect();
        assert_eq!(
            kinds,
            [Some(ActivityKind::ToolCall), Some(ActivityKind::ToolResult)],
            "{arguments}"
        );
    }
    let mut unparsed = handback("fc_c3", "c3", &json!({}));
    unparsed["arguments"] = json!("not json");
    let rows = history_rows(&items(&[unparsed])).expect("projects");
    assert_eq!(rows[0].activity_kind(), Some(ActivityKind::ToolCall));
}

#[test]
fn another_tools_message_argument_is_not_an_answer() {
    let mut call = handback("fc_c4", "c4", &json!({"message": "hello"}));
    call["name"] = json!("SendMessage");
    let rows = history_rows(&items(&[call, result("out_c4", "c4")])).expect("projects");
    assert!(rows.iter().all(|row| row.role == RowRole::Tool));
    assert_eq!(rows.len(), 2);
}

#[test]
fn a_streamed_handback_commits_as_the_answer_and_its_result_never_shows() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "response.in_progress", "response_id": "r1"}));
    harness.send(json!({
        "type": "response.output_item.done", "response_id": "r1",
        "item": handback("fc_c2", "c2", &json!({"message": "All 12 checks pass."})),
    }));
    // A live output for the handback is the delivery receipt too.
    let outcome = harness.send(json!({
        "type": "response.function_call_output.delta", "call_id": "c2", "delta": "Report",
    }));
    assert!(outcome.changes.is_empty());
    let outcome = harness.send(json!({
        "type": "response.output_item.done", "response_id": "r1", "item": result("out_c2", "c2"),
    }));
    assert!(outcome.changes.is_empty());
    assert_eq!(
        shown(&harness.snapshot().rows),
        [(RowRole::Assistant, None, "All 12 checks pass.")]
    );
}

#[test]
fn a_result_that_arrives_before_its_handback_goes_when_the_handback_lands() {
    let mut harness = Harness::new(SESSION);
    harness.send(json!({"type": "response.in_progress", "response_id": "r1"}));
    harness.send(json!({
        "type": "response.function_call_output.delta", "call_id": "c2", "delta": "Report",
    }));
    harness.send(json!({
        "type": "response.output_item.done", "response_id": "r1", "item": result("out_c2", "c2"),
    }));
    harness.send(json!({
        "type": "response.output_item.done", "response_id": "r1",
        "item": handback("fc_c2", "c2", &json!({"message": "Done."})),
    }));
    assert_eq!(
        shown(&harness.snapshot().rows),
        [(RowRole::Assistant, None, "Done.")]
    );
}

#[test]
fn an_older_page_with_the_handback_hides_a_result_already_shown() {
    let receipt = history_rows(&items(&[result("out_c2", "c2")])).expect("projects");
    let mut rows = vec![assistant("a0", "Starting.")];
    rows.extend(receipt);
    let mut harness = Harness::with_rows(SESSION, rows);
    let older = history_rows(&items(&[handback(
        "fc_c2",
        "c2",
        &json!({"message": "Report."}),
    )]))
    .expect("projects");
    let changes = harness.reducer.prepend_history(older);
    harness.check(&changes);
    assert_eq!(
        shown(&harness.snapshot().rows),
        [
            (RowRole::Assistant, None, "Report."),
            (RowRole::Assistant, None, "Starting."),
        ]
    );
}
