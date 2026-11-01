//! Elicitation (decision request) wire models.
//!
//! Ground truth: `ElicitationRequestEvent`, `ElicitationRequestParams`, `ElicitationResolvedEvent`
//! and `ElicitationResult` in `omnigent/server/schemas.py`, plus the
//! `GET /v1/sessions/{id}/elicitations/{eid}` handler in `routes_elicitations.py`.
//!
//! A pending request decodes whenever it has a non-empty `elicitation_id` and an object `params`:
//! schema and permission extras are kept as sent so the decision-form layer can fail closed on
//! anything it cannot render. It never decodes as an unknown event.

use std::collections::BTreeMap;

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};

use crate::error::{DecodeError, FromWire, decode_as};
use crate::wire_enum::wire_enum;

wire_enum! {
    /// `params.mode`.
    pub enum ElicitationMode {
        /// `form`: answer in the app (the server default).
        Form = "form",
        /// `url`: complete on a confirmation page.
        Url = "url",
    }
}

wire_enum! {
    /// The answer to an elicitation (`ElicitationResult.action`, `response.elicitation_resolved`).
    pub enum ElicitationAction {
        /// `accept`.
        Accept = "accept",
        /// `decline`.
        Decline = "decline",
        /// `cancel`.
        Cancel = "cancel",
    }
}

wire_enum! {
    /// `response.elicitation_resolved.reason`.
    pub enum ResolvedReason {
        /// `unanswered`: the request ended without an answer.
        Unanswered = "unanswered",
    }
}

wire_enum! {
    /// `status` of `GET /v1/sessions/{id}/elicitations/{eid}`.
    pub enum ElicitationLookupStatus {
        /// `pending`.
        Pending = "pending",
        /// `resolved`.
        Resolved = "resolved",
    }
}

wire_enum! {
    /// `resolution` of a resolved native elicitation lookup.
    pub enum NativeResolution {
        /// `unanswered`.
        Unanswered = "unanswered",
        /// `confirmed`.
        Confirmed = "confirmed",
    }
}

const fn default_mode() -> ElicitationMode {
    ElicitationMode::Form
}

/// `ElicitationRequestParams` (extra fields allowed).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ElicitationParams {
    /// `form` when absent.
    #[serde(default = "default_mode")]
    pub mode: ElicitationMode,
    /// The question or approval prompt.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// The JSON schema of the requested answer, as sent (it may not even be an object).
    #[serde(
        default,
        rename = "requestedSchema",
        skip_serializing_if = "Option::is_none"
    )]
    pub requested_schema: Option<Value>,
    /// The confirmation page for `url` mode.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// Policy phase.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<String>,
    /// Policy name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy_name: Option<String>,
    /// A preview of the content under review.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_preview: Option<String>,
    /// For a card mirrored from a child session: the session to resolve on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_session_id: Option<String>,
    /// Every other key, as sent: for example `command`, `cwd`, `reason`, `allow_all_edits`,
    /// `remember_scope`, `exit_plan_mode`, `execpolicy_amendment`, `ask_user_question`.
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

/// A pending decision: `response.elicitation_request`, or one `SessionResponse.pending_elicitations`
/// entry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ElicitationRequest {
    /// Correlation id. Never empty.
    pub elicitation_id: String,
    /// `elicitation/create`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    /// The request.
    pub params: ElicitationParams,
}

impl ElicitationRequest {
    /// The session the answer must be posted to: `params.target_session_id`, else the session
    /// whose stream or snapshot carried the request.
    #[must_use]
    pub fn target_session<'a>(&'a self, carrying_session: &'a str) -> &'a str {
        self.params
            .target_session_id
            .as_deref()
            .filter(|target| !target.is_empty())
            .unwrap_or(carrying_session)
    }
}

#[derive(Deserialize)]
struct RawRequest {
    elicitation_id: String,
    #[serde(default)]
    method: Option<String>,
    params: Value,
}

impl FromWire for ElicitationRequest {
    fn from_value(value: Value) -> Result<Self, DecodeError> {
        const CONTEXT: &str = "elicitation request";
        if !value.is_object() {
            return Err(DecodeError::NotAnObject {
                context: CONTEXT.to_owned(),
            });
        }
        let raw: RawRequest = decode_as(value, || CONTEXT.to_owned())?;
        if raw.elicitation_id.is_empty() {
            return Err(DecodeError::missing(CONTEXT, "elicitation_id"));
        }
        if !raw.params.is_object() {
            return Err(DecodeError::NotAnObject {
                context: format!("{CONTEXT} params"),
            });
        }
        Ok(Self {
            elicitation_id: raw.elicitation_id,
            method: raw.method,
            params: decode_as(raw.params, || format!("{CONTEXT} params"))?,
        })
    }
}

impl<'de> Deserialize<'de> for ElicitationRequest {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::from_value(Value::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

/// `response.elicitation_resolved`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ElicitationResolved {
    /// The exact id of the request this retires.
    pub elicitation_id: String,
    /// The answer, when one was given.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action: Option<ElicitationAction>,
    /// Why it ended without an answer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<ResolvedReason>,
}

/// How a resolved elicitation ended.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ElicitationResolution {
    /// Answered with this action.
    Answered(ElicitationAction),
    /// Ended without an answer (`reason: "unanswered"`).
    Unanswered,
    /// Neither field: answered outside this client, for example in the native terminal.
    AnsweredElsewhere,
    /// A reason this client does not know.
    Other {
        /// The reason as sent.
        reason: String,
    },
}

impl ElicitationResolved {
    /// How the request ended.
    #[must_use]
    pub fn resolution(&self) -> ElicitationResolution {
        match (&self.action, &self.reason) {
            (Some(action), _) => ElicitationResolution::Answered(action.clone()),
            (None, Some(ResolvedReason::Unanswered)) => ElicitationResolution::Unanswered,
            (None, Some(ResolvedReason::Unknown { value })) => ElicitationResolution::Other {
                reason: value.clone(),
            },
            (None, None) => ElicitationResolution::AnsweredElsewhere,
        }
    }
}

/// One answer value: MCP's flat `str | int | float | bool | list[str] | null`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ElicitationValue {
    /// `null`.
    Null,
    /// A boolean.
    Bool(bool),
    /// An integer.
    Integer(i64),
    /// A non-integer number.
    Number(f64),
    /// A string.
    Text(String),
    /// A list of strings (multi-select).
    TextList(Vec<String>),
}

/// The body of `POST /v1/sessions/{id}/elicitations/{eid}/resolve` (`ElicitationResult`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ElicitationResult {
    /// The answer.
    pub action: ElicitationAction,
    /// Flat answers keyed by question or field id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<BTreeMap<String, ElicitationValue>>,
    /// MCP `_meta`.
    #[serde(default, rename = "_meta", skip_serializing_if = "Option::is_none")]
    pub meta: Option<Map<String, Value>>,
}

/// `GET /v1/sessions/{id}/elicitations/{eid}`. It carries no schema: rebuild full cards from the
/// snapshot or the stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ElicitationLookup {
    /// Pending or resolved.
    pub status: ElicitationLookupStatus,
    /// Prompt (pending only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// Policy phase (pending only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<String>,
    /// Policy name (pending only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy_name: Option<String>,
    /// Content preview (pending only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_preview: Option<String>,
    /// How a native request was cleared (resolved only; absence proves nothing).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<NativeResolution>,
    /// Other keys, for example `native_delivery`, `permission_directories`.
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::test_support::{all_fixtures, response};

    #[test]
    fn every_fixture_request_decodes_with_its_extras() {
        let mut count = 0;
        for (path, values) in all_fixtures() {
            for value in values {
                let mut stack = vec![value];
                while let Some(value) = stack.pop() {
                    match value {
                        Value::Object(fields) => {
                            if fields.contains_key("elicitation_id")
                                && fields.contains_key("params")
                            {
                                let request =
                                    ElicitationRequest::from_value(Value::Object(fields.clone()))
                                        .unwrap_or_else(|error| panic!("{path}: {error}"));
                                assert_ne!(request.elicitation_id, "");
                                count += 1;
                            }
                            stack.extend(fields.into_iter().map(|(_, value)| value));
                        }
                        Value::Array(values) => stack.extend(values),
                        _ => {}
                    }
                }
            }
        }
        assert!(count >= 40, "{count}");
    }

    #[test]
    fn permission_extras_and_non_object_schemas_are_kept_verbatim() {
        let request = ElicitationRequest::from_value(json!({
            "elicitation_id": "permission1",
            "params": {"command": "swift test", "phase": "codex_command_approval",
                       "execpolicy_amendment": ["swift", "test"], "requestedSchema": "not a schema",
                       "target_session_id": "child"}
        }))
        .unwrap();
        assert_eq!(request.params.mode, ElicitationMode::Form);
        assert_eq!(request.params.message, None);
        assert_eq!(request.params.requested_schema, Some(json!("not a schema")));
        assert_eq!(
            request.params.extra.get("command"),
            Some(&json!("swift test"))
        );
        assert_eq!(request.target_session("parent"), "child");
    }

    #[test]
    fn a_request_without_id_or_object_params_is_an_error() {
        for value in [
            json!({"elicitation_id": "", "params": {}}),
            json!({"params": {}}),
            json!({"elicitation_id": "e1"}),
            json!({"elicitation_id": "e1", "params": "approve?"}),
            json!({"elicitation_id": "e1", "params": {"message": 3}}),
            json!(["e1"]),
        ] {
            assert!(
                ElicitationRequest::from_value(value.clone()).is_err(),
                "{value}"
            );
        }
    }

    #[test]
    fn snapshot_pending_elicitation_decodes() {
        let line = &crate::test_support::fixture_lines(
            "decisions/LocalServerSessionClient--QuestionResolutionUsesRequestedAnswerKey.jsonl",
        )[0];
        let pending = response(line)["pending_elicitations"][0].clone();
        let request = ElicitationRequest::from_value(pending).unwrap();
        assert_eq!(request.elicitation_id, "ask1");
        assert_eq!(request.params.message.as_deref(), Some("Choose"));
    }

    #[test]
    fn resolutions_cover_answer_unanswered_and_elsewhere() {
        let resolved =
            |value: Value| -> ElicitationResolved { serde_json::from_value(value).unwrap() };
        assert_eq!(
            resolved(json!({"elicitation_id": "e", "action": "cancel"})).resolution(),
            ElicitationResolution::Answered(ElicitationAction::Cancel)
        );
        assert_eq!(
            resolved(json!({"elicitation_id": "e", "reason": "unanswered"})).resolution(),
            ElicitationResolution::Unanswered
        );
        assert_eq!(
            resolved(json!({"elicitation_id": "e"})).resolution(),
            ElicitationResolution::AnsweredElsewhere
        );
    }

    #[test]
    fn resolve_body_encodes_flat_mcp_values() {
        let body = ElicitationResult {
            action: ElicitationAction::Accept,
            content: Some(BTreeMap::from([
                ("name".to_owned(), ElicitationValue::Text("Omni".to_owned())),
                ("count".to_owned(), ElicitationValue::Integer(2)),
                ("ratio".to_owned(), ElicitationValue::Number(0.5)),
                ("ready".to_owned(), ElicitationValue::Bool(false)),
                (
                    "scope".to_owned(),
                    ElicitationValue::TextList(vec!["a".to_owned()]),
                ),
                ("feedback".to_owned(), ElicitationValue::Null),
            ])),
            meta: None,
        };
        let encoded = serde_json::to_value(&body).unwrap();
        assert_eq!(
            encoded,
            json!({"action": "accept", "content": {"name": "Omni", "count": 2, "ratio": 0.5,
                   "ready": false, "scope": ["a"], "feedback": null}})
        );
        assert_eq!(
            serde_json::from_value::<ElicitationResult>(encoded).unwrap(),
            body
        );
    }

    #[test]
    fn lookup_decodes_pending_and_resolved() {
        let pending: ElicitationLookup = serde_json::from_value(json!({
            "status": "pending", "message": "Approve?", "phase": "", "policy_name": "",
            "content_preview": "", "native_delivery": true
        }))
        .unwrap();
        assert_eq!(pending.status, ElicitationLookupStatus::Pending);
        assert_eq!(pending.extra.get("native_delivery"), Some(&json!(true)));
        let resolved: ElicitationLookup =
            serde_json::from_value(json!({"status": "resolved", "resolution": "confirmed"}))
                .unwrap();
        assert_eq!(resolved.resolution, Some(NativeResolution::Confirmed));
    }
}
