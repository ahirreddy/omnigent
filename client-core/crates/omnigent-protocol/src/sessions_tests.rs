use serde_json::json;

use super::*;
use crate::test_support::{fixture, fixture_lines, response};

fn snapshot(value: Value) -> SessionSnapshot {
    let text = value.to_string();
    SessionSnapshot::from_value(value).unwrap_or_else(|error| panic!("{text}: {error}"))
}

#[test]
fn permission_capabilities_and_provider_failure_metadata() {
    let exchanges = fixture_lines(
        "sessions/LocalServerSessionClient--PermissionCapabilitiesAndProviderFailureMetadata.jsonl",
    );
    let session = snapshot(response(&exchanges[0]));
    let permissions = session.permissions();
    assert!(!permissions.is_read_only());
    assert!(permissions.can_rename());
    assert!(permissions.can_pin());
    assert!(!permissions.can_archive());
    assert_eq!(session.status, SessionStatus::Failed);
    assert_eq!(session.failure_message(), Some("Sign in again"));
    let history = ItemPage::from_value(response(&exchanges[1])).unwrap();
    assert_eq!(history.data, Vec::<ConversationItem>::new());

    let unknown = SessionPermissions { level: None };
    assert!(unknown.is_read_only() && !unknown.can_pin() && !unknown.can_archive());
    let owner = SessionPermissions { level: Some(4) };
    assert!(owner.can_archive() && owner.can_rename());
}

#[test]
fn partial_list_projection_preserves_configuration_but_explicit_null_clears_it() {
    let vector = fixture(
        "sessions/SessionConfiguration--PartialListProjectionPreservesConfigurationButExplicitNullClearsIt.json",
    );
    let detailed = snapshot(vector["base_wire"].clone());
    assert_eq!(
        detailed.harness.value().map(String::as_str),
        Some("codex-native")
    );
    assert_eq!(
        detailed.model_override.value().map(String::as_str),
        Some("sample-balanced")
    );
    let models = detailed.model_options.value().unwrap();
    assert_eq!(models.len(), 2);
    assert_eq!(models[0].is_default, Some(true));
    assert_eq!(models[0].supported_reasoning_efforts.len(), 2);

    let minimal = json!({"id": "conv_a", "status": "idle", "created_at": 1});
    let case = |fields: &Value| {
        let mut wire = minimal.clone();
        wire.as_object_mut()
            .unwrap()
            .extend(fields.as_object().unwrap().clone());
        snapshot(wire)
    };
    let cases = vector["cases"].as_array().unwrap();

    // A projection that reports nothing must not clear anything.
    let mut known = Known::from(&detailed);
    let listed = case(&cases[0]["fields"]);
    assert!(listed.model_override.is_absent() && listed.model_options.is_absent());
    assert!(listed.host_online.is_absent() && listed.harness.is_absent());
    known.apply(listed);
    assert_eq!(known, Known::from(&detailed));

    // Explicit nulls and an empty list clear; a host going offline is kept as false.
    let reset = case(&cases[1]["fields"]);
    assert_eq!(reset.model_override, Field::Null);
    assert_eq!(reset.model_options, Field::Present(vec![]));
    known.apply(reset);
    assert_eq!(known.model_override, None);
    assert_eq!(known.effort, None);
    assert_eq!(known.options, Some(vec![]));
    assert_eq!(known.host_online, Some(false));
    assert_eq!(known.runner_online, None);
    assert_eq!(known.harness.as_deref(), Some("codex-native"));
}

/// The configuration a client holds, updated sparsely from snapshots.
#[derive(Debug, PartialEq)]
struct Known {
    model_override: Option<String>,
    effort: Option<String>,
    options: Option<Vec<NativeModelOption>>,
    host_online: Option<bool>,
    runner_online: Option<bool>,
    harness: Option<String>,
}

impl From<&SessionSnapshot> for Known {
    fn from(snapshot: &SessionSnapshot) -> Self {
        Self {
            model_override: snapshot.model_override.value().cloned(),
            effort: snapshot.reasoning_effort.value().cloned(),
            options: snapshot.model_options.value().cloned(),
            host_online: snapshot.host_online.value().copied(),
            runner_online: snapshot.runner_online.value().copied(),
            harness: snapshot.harness.value().cloned(),
        }
    }
}

impl Known {
    fn apply(&mut self, snapshot: SessionSnapshot) {
        snapshot.model_override.apply_to(&mut self.model_override);
        snapshot.reasoning_effort.apply_to(&mut self.effort);
        snapshot.model_options.apply_to(&mut self.options);
        snapshot.host_online.apply_to(&mut self.host_online);
        snapshot.runner_online.apply_to(&mut self.runner_online);
        snapshot.harness.apply_to(&mut self.harness);
    }
}

#[test]
fn list_rows_have_no_snapshot_only_fields() {
    let row = SessionListItem::from_value(json!({
        "id": "conv_a", "status": "running", "created_at": 1, "permission_level": 4,
        "model_override": null, "model_options": [], "last_task_error": null,
        "pending_elicitations": [], "host_resumable": false, "llm_model": null
    }))
    .unwrap();
    let value = serde_json::to_value(&row).unwrap();
    for key in [
        "model_override",
        "model_options",
        "last_task_error",
        "pending_elicitations",
        "host_resumable",
        "llm_model",
    ] {
        assert!(value.get(key).is_none(), "{key}");
    }
    assert!(!row.permissions().is_read_only());
}

#[test]
fn malformed_rows_and_snapshots_are_errors() {
    for value in [
        json!({"status": "idle", "created_at": 1}),
        json!({"id": "", "status": "idle", "created_at": 1}),
        json!({"id": "s", "created_at": 1}),
        json!({"id": "s", "status": "idle"}),
        json!({"id": "s", "status": "idle", "created_at": "1"}),
        json!({"id": "s", "status": "idle", "created_at": 1, "permission_level": "4"}),
        json!(["s"]),
    ] {
        assert!(
            SessionListItem::from_value(value.clone()).is_err(),
            "{value}"
        );
        assert!(
            SessionSnapshot::from_value(value.clone()).is_err(),
            "{value}"
        );
    }
    let bad_pending = json!({"id": "s", "status": "idle", "created_at": 1,
                             "pending_elicitations": [{"elicitation_id": "", "params": {}}]});
    assert!(SessionSnapshot::from_value(bad_pending).is_err());
}

#[test]
fn unknown_status_is_kept_verbatim() {
    let row = SessionListItem::from_value(json!({"id": "s", "status": "paused", "created_at": 1}))
        .unwrap();
    assert_eq!(
        row.status,
        SessionStatus::Unknown {
            value: "paused".to_owned()
        }
    );
    assert!(!row.status.is_busy());
    assert!(SessionStatus::Waiting.is_busy());
}

#[test]
fn snapshot_decodes_pending_elicitations_and_inputs() {
    let session = snapshot(response(&fixture(
        "sessions/LocalServerSessionClient--ConversationPageLoadsMetadataAndLatestHistoryWithIncreasingRevisions--session.json",
    )));
    assert_eq!(session.status, SessionStatus::Waiting);
    let ids: Vec<&str> = session
        .pending_elicitations
        .iter()
        .map(|request| request.elicitation_id.as_str())
        .collect();
    assert_eq!(ids, ["pending_1"]);
    assert!(session.permissions().is_read_only());
    let with_input = snapshot(json!({"id": "s", "status": "running", "created_at": 1,
        "pending_inputs": [{"pending_id": "p1", "content": [{"type": "input_text", "text": "hi"}],
                            "created_by": "alice@example.test"}]}));
    assert_eq!(with_input.pending_inputs[0].pending_id, "p1");
    assert_eq!(
        content::visible_text(&with_input.pending_inputs[0].content),
        "hi"
    );
}

#[test]
fn page_cursor_must_advance() {
    for (body, expected) in [
        (
            json!({"data": [], "has_more": true}),
            Err(PageCursorError::MissingCursor),
        ),
        (
            json!({"data": [], "has_more": true, "last_id": ""}),
            Err(PageCursorError::MissingCursor),
        ),
        (
            json!({"data": [], "has_more": true, "last_id": "same"}),
            Err(PageCursorError::RepeatedCursor {
                cursor: "same".to_owned(),
            }),
        ),
        (
            json!({"data": [], "has_more": false, "last_id": "same"}),
            Ok(None),
        ),
    ] {
        let page = SessionList::from_value(body).unwrap();
        assert_eq!(page.next_cursor(Some("same")), expected);
    }
}

use crate::page::PageCursorError;

#[test]
fn every_session_payload_in_every_fixture_decodes() {
    let mut rows = 0;
    let mut snapshots = 0;
    for (path, values) in crate::test_support::all_fixtures() {
        let deliberately_malformed = [
            "MalformedResponsesAndHistoryAreNotReportedAsEmptySuccess",
            "UnacknowledgedAndMalformedMutationSnapshotsAreUncertain",
        ];
        if deliberately_malformed
            .iter()
            .any(|name| path.contains(name))
            || path.starts_with("manifest/")
        {
            continue;
        }
        for value in values {
            let request_path = value
                .pointer("/request/path")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let method = value
                .pointer("/request/method")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let status = value.get("status").and_then(Value::as_u64).unwrap_or(0);
            let body = value.get("response").cloned().unwrap_or(Value::Null);
            if !(200..300).contains(&status) || !body.is_object() {
                continue;
            }
            let segments: Vec<&str> = request_path.trim_start_matches('/').split('/').collect();
            let session_route = matches!(segments.as_slice(), [.., "v1", "sessions", _]);
            if request_path.ends_with("/v1/sessions") && method == "GET" {
                rows += SessionList::from_value(body)
                    .unwrap_or_else(|error| panic!("{path}: {error}"))
                    .data
                    .len();
            } else if session_route && (method == "GET" || method == "PATCH") {
                SessionSnapshot::from_value(body).unwrap_or_else(|error| panic!("{path}: {error}"));
                snapshots += 1;
            }
            if let Some(Value::Object(message)) = value.get("message")
                && matches!(
                    message.get("type").and_then(Value::as_str),
                    Some("snapshot" | "changed")
                )
            {
                for item in message.get("items").and_then(Value::as_array).unwrap() {
                    SessionListItem::from_value(item.clone())
                        .unwrap_or_else(|error| panic!("{path}: {error}\n{item}"));
                    rows += 1;
                }
            }
        }
    }
    assert!(
        rows > 50 && snapshots > 30,
        "{rows} rows, {snapshots} snapshots"
    );
}

#[test]
fn recorded_sessions_snapshot() {
    let list = SessionList::from_value(response(&fixture("sessions/recorded-sessions-list.json")))
        .unwrap();
    insta::assert_json_snapshot!("recorded-sessions-list", list);
    let session = snapshot(response(&fixture(
        "sessions/recorded-session-get-no-items.json",
    )));
    insta::assert_json_snapshot!("recorded-session-get-no-items", session);
    let after_turn = snapshot(response(&fixture(
        "items/recorded-session-snapshot-after-turn.json",
    )));
    insta::assert_json_snapshot!("recorded-session-snapshot-after-turn", after_turn);
    let rows: Vec<SessionListItem> = fixture_lines("sessions/recorded-updates-ws.jsonl")
        .into_iter()
        .filter(|frame| frame["direction"] == "recv")
        .filter_map(|frame| frame["message"]["items"].as_array().cloned())
        .flatten()
        .map(|row| SessionListItem::from_value(row).unwrap())
        .collect();
    insta::assert_json_snapshot!("recorded-updates-ws-rows", rows);
}

#[test]
fn page_errors_read_as_sentences_and_a_page_decodes_through_serde() {
    use crate::page::{Page, PageCursorError};

    assert_eq!(
        PageCursorError::MissingCursor.to_string(),
        "page has more rows but no cursor"
    );
    assert_eq!(
        PageCursorError::RepeatedCursor {
            cursor: "a".to_owned()
        }
        .to_string(),
        "page repeated cursor \"a\""
    );
    let page: Page<ConversationItem> =
        serde_json::from_value(serde_json::json!({"data": [], "has_more": false})).unwrap();
    assert_eq!(page.data.len(), 0);
}

#[test]
fn a_syntax_error_says_it_is_not_json_and_a_null_field_has_no_value() {
    use crate::error::DecodeError;
    use crate::field::Field;

    assert!(
        DecodeError::Syntax {
            message: "bad".to_owned()
        }
        .to_string()
        .starts_with("not valid JSON")
    );
    assert_eq!(Field::<String>::Null.value(), None);
}
