use serde_json::json;

use super::*;
use crate::elicitation::{ElicitationAction, ElicitationResolution};
use crate::items::ItemData;
use crate::test_support::{all_fixtures, fixture_lines};

fn decode(value: Value) -> ServerStreamEvent {
    let text = value.to_string();
    ServerStreamEvent::from_value(value).unwrap_or_else(|error| panic!("{text}: {error}"))
}

#[test]
fn unknown_live_events_have_bounded_inspectable_safe_fallback() {
    let event = decode(json!({
        "type": "response.future_activity", "id": "future-event",
        "message": "Useful future activity",
        "payload": {
            "text": "visible fixture text ".repeat(20_000),
            "api_key": "PRIVATE_CREDENTIAL",
            "encrypted_content": "PRIVATE_HIDDEN_DATA"
        }
    }));
    assert!(event.is_unknown());
    assert_eq!(event.event_type(), "response.future_activity");
    let text = event.unknown_display_text().unwrap();
    assert!(text.contains("Useful future activity"), "{text}");
    assert!(text.chars().count() < 50_000);
    assert!(!text.contains("PRIVATE_"), "{text}");
}

#[test]
fn the_union_has_every_server_event_type_once() {
    let mut types = ServerStreamEvent::KNOWN_TYPES.to_vec();
    assert_eq!(types.len(), 56);
    types.sort_unstable();
    types.dedup();
    assert_eq!(types.len(), 56);
}

#[test]
fn every_known_type_dispatches_to_its_own_variant() {
    for event_type in ServerStreamEvent::KNOWN_TYPES {
        let Ok(event) = ServerStreamEvent::from_value(json!({"type": event_type})) else {
            continue;
        };
        assert!(!event.is_unknown(), "{event_type}");
        assert_eq!(event.event_type(), *event_type);
    }
}

// Divergence D2: types NativeLab does not handle still decode to typed variants.
#[test]
fn types_missing_from_native_lab_decode_typed() {
    let cases = [
        json!({"type": "session.title", "conversation_id": "c", "title": "Renamed"}),
        json!({"type": "session.permission_mode", "conversation_id": "c", "permission_mode": "plan"}),
        json!({"type": "session.codex_approval_mode", "conversation_id": "c",
               "approval_mode": "full-access"}),
        json!({"type": "session.btw_sidechat", "conversation_id": "c", "question": "Q", "answer": "A"}),
        json!({"type": "ui.open_file", "path": "/workspace/a.txt"}),
        json!({"type": "turn.started", "session_id": "c"}),
        json!({"type": "turn.completed", "session_id": "c"}),
        json!({"type": "turn.failed", "session_id": "c", "error": {"message": "x"}}),
        json!({"type": "turn.cancelled", "session_id": "c"}),
    ];
    for case in cases {
        let event = decode(case.clone());
        assert!(!event.is_unknown(), "{case}");
    }
    let ServerStreamEvent::SessionCodexApprovalMode(mode) =
        decode(json!({"type": "session.codex_approval_mode", "approval_mode": "approve-for-me"}))
    else {
        panic!()
    };
    assert_eq!(mode.approval_mode, CodexApprovalMode::ApproveForMe);
    let ServerStreamEvent::SessionBtwSidechat(sidechat) =
        decode(json!({"type": "session.btw_sidechat", "question": "Q", "answer": "A"}))
    else {
        panic!()
    };
    assert!(!sidechat.truncated);
}

// Divergence D3: NativeLab-only types are not in the server union.
#[test]
fn phantom_native_lab_types_decode_as_unknown() {
    for event_type in ["response.started", "session.skills"] {
        let event = decode(json!({"type": event_type, "conversation_id": "c"}));
        assert!(event.is_unknown(), "{event_type}");
    }
}

#[test]
fn a_pending_decision_is_typed_or_an_error_never_unknown() {
    let ServerStreamEvent::ElicitationRequest(request) = decode(json!({
        "type": "response.elicitation_request", "elicitation_id": "e1",
        "method": "elicitation/create",
        "params": {"message": "Approve?", "requestedSchema": {"type": "object"}}
    })) else {
        panic!()
    };
    assert_eq!(request.elicitation_id, "e1");
    for broken in [
        json!({"type": "response.elicitation_request", "elicitation_id": "e1"}),
        json!({"type": "response.elicitation_request", "elicitation_id": "", "params": {}}),
        json!({"type": "response.elicitation_request", "params": {}}),
        json!({"type": "response.elicitation_request", "elicitation_id": "e1", "params": []}),
    ] {
        assert!(
            ServerStreamEvent::from_value(broken.clone()).is_err(),
            "{broken}"
        );
    }
    let ServerStreamEvent::ElicitationResolved(resolved) = decode(json!({
        "type": "response.elicitation_resolved", "elicitation_id": "e1", "action": "accept"
    })) else {
        panic!()
    };
    assert_eq!(
        resolved.resolution(),
        ElicitationResolution::Answered(ElicitationAction::Accept)
    );
}

#[test]
fn nested_and_flat_payloads_expose_the_same_ids() {
    let ServerStreamEvent::SessionInterrupted(nested) = decode(json!({
        "type": "session.interrupted", "data": {"requested_at": 5, "response_id": "r1"}
    })) else {
        panic!()
    };
    let ServerStreamEvent::SessionInterrupted(flat) =
        decode(json!({"type": "session.interrupted", "response_id": "r1"}))
    else {
        panic!()
    };
    assert_eq!(nested.response_id(), Some("r1"));
    assert_eq!(flat.response_id(), Some("r1"));
    let ServerStreamEvent::ResponseCompleted(completed) =
        decode(json!({"type": "response.completed", "response_id": "r1"}))
    else {
        panic!()
    };
    assert_eq!(completed.response_id(), Some("r1"));
}

#[test]
fn consumed_input_rebuilds_its_item() {
    let ServerStreamEvent::SessionInputConsumed(consumed) = decode(json!({
        "type": "session.input.consumed",
        "data": {"item_id": "i1", "type": "message", "created_by": "alice@example.test",
                 "cleared_pending_id": "p1",
                 "data": {"role": "user", "content": [{"type": "input_text", "text": "hi"}]}}
    })) else {
        panic!()
    };
    assert_eq!(consumed.data.cleared_pending_id.as_deref(), Some("p1"));
    let item = consumed.data.item().unwrap();
    assert_eq!(item.id, "i1");
    assert_eq!(item.created_by.as_deref(), Some("alice@example.test"));
    let ItemData::Message(message) = &item.data else {
        panic!("{item:?}")
    };
    assert_eq!(message.visible_text(), "hi");
}

#[test]
fn output_item_done_with_a_broken_item_is_an_error() {
    let broken = json!({"type": "response.output_item.done",
                        "item": {"id": "m", "type": "message", "content": "no role"}});
    assert!(ServerStreamEvent::from_value(broken).is_err());
    let unknown_item = decode(json!({"type": "response.output_item.done",
                                     "item": {"id": "x", "type": "future_item"}}));
    let ServerStreamEvent::OutputItemDone(done) = unknown_item else {
        panic!()
    };
    assert!(matches!(done.item.data, ItemData::Unknown { .. }));
}

#[test]
fn sparse_fields_distinguish_null_from_missing() {
    let model = |value: Value| match decode(value) {
        ServerStreamEvent::SessionModel(event) => event.model,
        other => panic!("{other:?}"),
    };
    assert_eq!(model(json!({"type": "session.model"})), Field::Absent);
    assert_eq!(
        model(json!({"type": "session.model", "model": null})),
        Field::Null
    );
    assert_eq!(
        model(json!({"type": "session.model", "model": "unknown-raw-model"})),
        Field::Present("unknown-raw-model".to_owned())
    );
    let ServerStreamEvent::SessionStatus(status) = decode(json!({
        "type": "session.status", "status": "idle", "background_task_count": 0
    })) else {
        panic!()
    };
    assert_eq!(status.background_task_count, Field::Present(0));
}

#[test]
fn malformed_frames_are_errors() {
    for value in [
        json!("session.status"),
        json!({"conversation_id": "c"}),
        json!({"type": ""}),
        json!({"type": 7}),
        json!({"type": "session.status"}),
        json!({"type": "response.output_text.delta"}),
        json!({"type": "response.output_text.delta", "delta": "x", "index": 1.5}),
        json!({"type": "response.output_text.delta", "delta": "x", "index": -1}),
        json!({"type": "session.reasoning_effort", "reasoning_effort": 42}),
        json!({"type": "session.usage", "context_tokens": "bad"}),
    ] {
        assert!(
            ServerStreamEvent::from_value(value.clone()).is_err(),
            "{value}"
        );
    }
    assert!(matches!(
        ServerStreamEvent::from_json(b"data: [DONE]"),
        Err(DecodeError::Syntax { .. })
    ));
}

/// Stream events in every fixture: objects whose `type` contains a dot.
fn fixture_events() -> Vec<(String, Value)> {
    let mut events = Vec::new();
    for (path, values) in all_fixtures() {
        if path.contains("EventGallery--") || path.starts_with("manifest/") {
            continue;
        }
        let mut stack = values;
        while let Some(value) = stack.pop() {
            match value {
                Value::Object(fields) => {
                    let is_event = fields
                        .get("type")
                        .and_then(Value::as_str)
                        .is_some_and(|event_type| event_type.contains('.'));
                    if is_event {
                        events.push((path.clone(), Value::Object(fields)));
                    } else {
                        stack.extend(fields.into_iter().map(|(_, value)| value));
                    }
                }
                Value::Array(values) => stack.extend(values),
                _ => {}
            }
        }
    }
    events
}

#[test]
fn every_fixture_event_decodes_except_deliberately_invalid_values() {
    let mut rejected = Vec::new();
    let mut unknown = Vec::new();
    let mut decoded = 0;
    for (path, value) in fixture_events() {
        match ServerStreamEvent::from_value(value.clone()) {
            Ok(event) if event.is_unknown() => unknown.push(event.event_type().to_owned()),
            Ok(event) => {
                let round_trip = serde_json::to_value(&event).unwrap();
                assert_eq!(decode(round_trip), event, "{path}");
                decoded += 1;
            }
            Err(error) => rejected.push(format!("{path}: {value} ({error})")),
        }
    }
    unknown.sort();
    unknown.dedup();
    assert_eq!(unknown, ["session.skills"]);
    // NativeLab feeds these values to prove the reducer ignores them. They are invalid on the wire
    // (a negative or non-numeric count, a fractional index, a non-string effort), so decoding
    // rejects them with a typed error and the consumer decides what to do.
    let expected_rejections = [
        r#""context_tokens":"bad""#,
        r#""context_tokens":-1"#,
        r#""reasoning_effort":42"#,
        r#""index":0.5"#,
    ];
    assert_eq!(rejected.len(), expected_rejections.len(), "{rejected:#?}");
    for needle in expected_rejections {
        assert!(
            rejected.iter().any(|rejection| rejection.contains(needle)),
            "{needle} not rejected: {rejected:#?}"
        );
    }
    assert!(decoded > 250, "{decoded}");
}

#[test]
fn recorded_stream_frames_snapshot() {
    for name in [
        "recorded-turn-text-tool-completion",
        "recorded-reconnect-last-event-id-turn2",
    ] {
        let frames = fixture_lines(&format!("sse/{name}.jsonl"));
        let events: Vec<ServerStreamEvent> = frames
            .into_iter()
            .map(|frame| {
                let data = frame["data"].clone();
                let event = decode(data);
                assert_eq!(frame["event"].as_str(), Some(event.event_type()));
                assert!(!event.is_unknown());
                event
            })
            .collect();
        insta::assert_json_snapshot!(name, events);
    }
}
