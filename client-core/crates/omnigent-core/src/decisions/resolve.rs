//! Answers: a [`DecisionResponse`] is checked against its [`Decision`] and becomes the MCP
//! `ElicitationResult`, then the resolve request, and the host's result is mapped back.
//!
//! Nothing is sent for an answer the card did not offer: a binary approval of a form or
//! question, a permission choice the request did not advertise, or a form answer that fails
//! validation are all [`DecisionError`]s before any request exists.

use std::collections::BTreeMap;

use omnigent_protocol::{ElicitationAction, ElicitationResult, ElicitationValue};
use serde_json::{Map, Value, json};

use super::form::AnswerError;
use super::{Decision, DecisionKind, PersistMode, UnsupportedReason};
use crate::attachments::policy::is_identifier;
use crate::auth::SecretString;
use crate::auth::endpoint::ServerEndpoint;
use crate::auth::errors::HostedAuthError;
use crate::http::{HttpHeader, HttpRequest, HttpResponse, TransportError};

/// What the user chose.
#[derive(Debug, Clone, PartialEq)]
pub enum DecisionResponse {
    /// Accept a binary approval.
    Approve,
    /// Decline a binary approval.
    Decline,
    /// Dismiss any answerable card without an explicit choice (MCP `cancel`). The way to close a
    /// choice or form without answering it.
    Cancel,
    /// One of a [`DecisionKind::Choice`]'s options.
    Answer(String),
    /// Values for a [`DecisionKind::Form`], keyed by field key.
    Form(BTreeMap<String, ElicitationValue>),
    /// Accept and allow all edits (`allow_all_edits`).
    ApproveAllEdits,
    /// Accept and switch to auto mode (`allow_auto_mode`).
    ApproveAutoMode,
    /// Accept and allow the offered directories (`permission_directories`).
    ApproveDirectories,
    /// Accept and don't ask again for the remember scope.
    ApproveRemembering,
    /// Accept with the offered Codex command policy, which must match exactly.
    ApproveCommandPolicy(Vec<String>),
    /// Accept with Codex or Antigravity persistence.
    ApprovePersist(PersistMode),
    /// Decline with feedback the agent receives, on a card that
    /// [accepts it](Decision::accepts_feedback). Must not be blank.
    DeclineWithFeedback(String),
}

/// Why an answer cannot be sent. Nothing was sent.
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum DecisionError {
    /// The session shows no card with this id.
    #[error("This request is no longer available.")]
    NotFound {
        /// The id asked for.
        decision_id: String,
    },
    /// The card was already answered here, or the server resolved it.
    #[error("This request has already been answered.")]
    AlreadyResolved {
        /// The id.
        decision_id: String,
    },
    /// The session is read-only for this user.
    #[error("You have read-only access to this session.")]
    ReadOnly,
    /// The card cannot be answered natively.
    #[error("{0}")]
    Unsupported(UnsupportedReason),
    /// The answer is not one the card offered.
    #[error("Choose a valid response for this request.")]
    NotOffered,
    /// A form answer that fails validation.
    #[error("{0}")]
    InvalidAnswer(AnswerError),
    /// A session or elicitation id that cannot be a path segment.
    #[error("invalid identifier {value:?}")]
    InvalidIdentifier {
        /// The value.
        value: String,
    },
}

/// Which route carries the answer. Both resolve through the same server helper.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ResolveRoute {
    /// `POST /v1/sessions/{target}/elicitations/{id}/resolve` with the `ElicitationResult`.
    #[default]
    Dedicated,
    /// `POST /v1/sessions/{target}/events` with `{type: "approval", data: {elicitation_id, ...}}`.
    ApprovalEvent,
}

/// A validated answer, ready to send.
#[derive(Debug, Clone, PartialEq)]
pub struct ResolveRequest {
    /// The session to post to: the card's target, which may be a child of the viewed session.
    pub session_id: String,
    /// The elicitation id.
    pub elicitation_id: String,
    /// The MCP result.
    pub result: ElicitationResult,
}

const fn accept(content: BTreeMap<String, ElicitationValue>) -> ElicitationResult {
    ElicitationResult {
        action: ElicitationAction::Accept,
        content: Some(content),
        meta: None,
    }
}

const fn bare(action: ElicitationAction) -> ElicitationResult {
    ElicitationResult {
        action,
        content: None,
        meta: None,
    }
}

fn one(key: &str, value: ElicitationValue) -> BTreeMap<String, ElicitationValue> {
    BTreeMap::from([(key.to_owned(), value)])
}

const fn require(offered: bool) -> Result<(), DecisionError> {
    if offered {
        Ok(())
    } else {
        Err(DecisionError::NotOffered)
    }
}

impl Decision {
    /// The MCP result for `response`, if the card offered it.
    ///
    /// # Errors
    ///
    /// [`DecisionError::Unsupported`] for a card that cannot be answered natively (including a
    /// URL handoff), [`DecisionError::NotOffered`] for a response kind the card did not offer, and
    /// [`DecisionError::InvalidAnswer`] for form values that fail validation.
    pub fn result_for(
        &self,
        response: &DecisionResponse,
    ) -> Result<ElicitationResult, DecisionError> {
        if let DecisionKind::Unsupported { reason, .. } = &self.kind {
            return Err(DecisionError::Unsupported(reason.clone()));
        }
        match response {
            DecisionResponse::Approve => {
                require(self.kind == DecisionKind::Approval)?;
                Ok(bare(ElicitationAction::Accept))
            }
            DecisionResponse::Decline => {
                require(self.kind == DecisionKind::Approval)?;
                Ok(bare(ElicitationAction::Decline))
            }
            DecisionResponse::Cancel => Ok(bare(ElicitationAction::Cancel)),
            DecisionResponse::Answer(answer) => match &self.kind {
                DecisionKind::Choice {
                    answer_key,
                    options,
                } if options.contains(answer) => Ok(accept(one(
                    answer_key,
                    ElicitationValue::Text(answer.clone()),
                ))),
                _ => Err(DecisionError::NotOffered),
            },
            DecisionResponse::Form(values) => {
                let form = self.form().ok_or(DecisionError::NotOffered)?;
                form.validate(values)
                    .map_err(DecisionError::InvalidAnswer)?;
                let answered = values
                    .iter()
                    .filter(|(_, value)| **value != ElicitationValue::Null)
                    .map(|(key, value)| (key.clone(), value.clone()))
                    .collect();
                Ok(accept(answered))
            }
            permission => {
                require(self.kind == DecisionKind::Approval)?;
                self.permission_result(permission)
            }
        }
    }

    /// The result for a permission choice on a binary approval.
    fn permission_result(
        &self,
        response: &DecisionResponse,
    ) -> Result<ElicitationResult, DecisionError> {
        let permissions = &self.permissions;
        let flag = |key: &str| accept(one(key, ElicitationValue::Bool(true)));
        match response {
            DecisionResponse::ApproveAllEdits => {
                require(permissions.allow_all_edits)?;
                Ok(flag("allow_all_edits"))
            }
            DecisionResponse::ApproveAutoMode => {
                require(permissions.allow_auto_mode)?;
                Ok(flag("allow_auto_mode"))
            }
            DecisionResponse::ApproveDirectories => {
                require(!permissions.permission_directories.is_empty())?;
                Ok(flag("allow_directories"))
            }
            DecisionResponse::ApproveRemembering => {
                require(permissions.remember.is_some())?;
                Ok(flag("remember"))
            }
            DecisionResponse::ApproveCommandPolicy(amendment) => {
                require(
                    !amendment.is_empty()
                        && permissions.exec_policy_amendment.as_ref() == Some(amendment),
                )?;
                Ok(accept(one(
                    "execpolicy_amendment",
                    ElicitationValue::TextList(amendment.clone()),
                )))
            }
            DecisionResponse::ApprovePersist(mode) => {
                require(permissions.offers_persist(*mode))?;
                Ok(ElicitationResult {
                    meta: Some(Map::from_iter([(
                        "persist".to_owned(),
                        Value::String(mode.as_str().to_owned()),
                    )])),
                    ..bare(ElicitationAction::Accept)
                })
            }
            DecisionResponse::DeclineWithFeedback(feedback) => {
                let feedback = feedback.trim();
                require(self.accepts_feedback() && !feedback.is_empty())?;
                Ok(ElicitationResult {
                    content: Some(one("feedback", ElicitationValue::Text(feedback.to_owned()))),
                    ..bare(ElicitationAction::Decline)
                })
            }
            DecisionResponse::Approve
            | DecisionResponse::Decline
            | DecisionResponse::Cancel
            | DecisionResponse::Answer(_)
            | DecisionResponse::Form(_) => Err(DecisionError::NotOffered),
        }
    }

    /// The validated request for `response`, posted to the card's target session.
    ///
    /// The caller must still confirm that the target session (when it differs from the viewed
    /// one) is editable, as `NativeLab` did.
    ///
    /// # Errors
    ///
    /// See [`Decision::result_for`], plus [`DecisionError::InvalidIdentifier`] for an id that
    /// cannot be a path segment.
    pub fn resolve_request(
        &self,
        response: &DecisionResponse,
    ) -> Result<ResolveRequest, DecisionError> {
        for value in [&self.id, &self.target_session_id] {
            if !is_identifier(value) {
                return Err(DecisionError::InvalidIdentifier {
                    value: value.clone(),
                });
            }
        }
        Ok(ResolveRequest {
            session_id: self.target_session_id.clone(),
            elicitation_id: self.id.clone(),
            result: self.result_for(response)?,
        })
    }
}

fn encode_failed(error: &serde_json::Error) -> ResolveError {
    ResolveError::Encode {
        message: error.to_string(),
    }
}

/// The `approval` event carrying an encoded result, which must be an object.
fn approval_event_body(result: Value, elicitation_id: &str) -> Result<Value, ResolveError> {
    let Value::Object(mut data) = result else {
        return Err(ResolveError::Encode {
            message: format!("expected an object result, got {result}"),
        });
    };
    data.insert(
        "elicitation_id".to_owned(),
        Value::String(elicitation_id.to_owned()),
    );
    Ok(json!({"type": "approval", "data": data}))
}

impl ResolveRequest {
    /// The JSON body for `route`.
    ///
    /// # Errors
    ///
    /// [`ResolveError::Encode`] when the result cannot be encoded (for example a non-finite
    /// number).
    pub fn body(&self, route: ResolveRoute) -> Result<Value, ResolveError> {
        let result = serde_json::to_value(&self.result).map_err(|error| encode_failed(&error))?;
        match route {
            ResolveRoute::Dedicated => Ok(result),
            ResolveRoute::ApprovalEvent => approval_event_body(result, &self.elicitation_id),
        }
    }

    /// The HTTP request for `route` on `endpoint`, with the org header and, when given, the
    /// bearer.
    ///
    /// # Errors
    ///
    /// [`ResolveError::Endpoint`] for a path or bearer the endpoint rejects;
    /// [`ResolveError::Encode`] as for [`ResolveRequest::body`].
    pub fn http_request(
        &self,
        endpoint: &ServerEndpoint,
        bearer: Option<&SecretString>,
        route: ResolveRoute,
    ) -> Result<HttpRequest, ResolveError> {
        let path = match route {
            ResolveRoute::Dedicated => format!(
                "/v1/sessions/{}/elicitations/{}/resolve",
                self.session_id, self.elicitation_id
            ),
            ResolveRoute::ApprovalEvent => format!("/v1/sessions/{}/events", self.session_id),
        };
        let body = serde_json::to_vec(&self.body(route)?).map_err(|error| encode_failed(&error))?;
        let mut request = endpoint
            .request_with("POST", &path, &[], "application/json", bearer)
            .map_err(ResolveError::Endpoint)?;
        request
            .headers
            .push(HttpHeader::new("Content-Type", "application/json"));
        request.body = Some(body);
        Ok(request)
    }
}

/// The server accepted the answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResolveAcknowledgement {
    /// The 2xx status (202 from both routes).
    pub status: u16,
}

/// Why a resolve did not succeed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ResolveError {
    /// The request could not be built.
    #[error("{0}")]
    Endpoint(HostedAuthError),
    /// The result could not be encoded.
    #[error("could not encode the answer: {message}")]
    Encode {
        /// Encoder detail.
        message: String,
    },
    /// The outcome is unknown (no response, or a 5xx): the answer may have been delivered. Do not
    /// re-send automatically; wait for `response.elicitation_resolved` or a fresh snapshot.
    #[error("the answer may or may not have been delivered: {message}")]
    Uncertain {
        /// What happened.
        message: String,
    },
    /// A redirect, which is never followed.
    #[error("the server redirected the answer (HTTP {status})")]
    Redirect {
        /// The 3xx status.
        status: u16,
    },
    /// HTTP 401: the caller must drop the connection and ask for sign-in again.
    #[error("not signed in")]
    Unauthorized,
    /// HTTP 403: no edit permission on the target session.
    #[error("not allowed to answer requests in this session")]
    Forbidden,
    /// HTTP 404: the target session does not exist.
    #[error("this session is no longer available")]
    SessionNotFound,
    /// Any other 4xx: the server refused the answer.
    #[error("the server rejected the answer with HTTP {status}: {body}")]
    Rejected {
        /// The status.
        status: u16,
        /// Response body, decoded lossily.
        body: String,
    },
}

/// Maps the host's result for [`ResolveRequest::http_request`].
///
/// # Errors
///
/// See [`ResolveError`].
pub fn resolve_response(
    result: Result<HttpResponse, TransportError>,
) -> Result<ResolveAcknowledgement, ResolveError> {
    let response = result.map_err(|error| ResolveError::Uncertain {
        message: error.to_string(),
    })?;
    match response.status {
        status @ 200..=299 => Ok(ResolveAcknowledgement { status }),
        status @ 300..=399 => Err(ResolveError::Redirect { status }),
        401 => Err(ResolveError::Unauthorized),
        403 => Err(ResolveError::Forbidden),
        404 => Err(ResolveError::SessionNotFound),
        status @ 400..=499 => Err(ResolveError::Rejected {
            status,
            body: String::from_utf8_lossy(&response.body).into_owned(),
        }),
        status => Err(ResolveError::Uncertain {
            message: format!("HTTP {status}"),
        }),
    }
}

#[cfg(test)]
mod tests {
    use omnigent_protocol::FromWire;
    use serde_json::{Value, json};

    use super::*;

    #[test]
    fn a_non_permission_response_is_not_a_permission_choice() {
        let request = omnigent_protocol::ElicitationRequest::from_value(
            json!({"elicitation_id": "request", "params": {}}),
        )
        .unwrap();
        let decision = Decision::from_request(&request, "session");
        for response in [
            DecisionResponse::Approve,
            DecisionResponse::Decline,
            DecisionResponse::Cancel,
            DecisionResponse::Answer("a".to_owned()),
            DecisionResponse::Form(BTreeMap::new()),
        ] {
            assert_eq!(
                decision.permission_result(&response),
                Err(DecisionError::NotOffered),
                "{response:?}"
            );
        }
    }

    #[test]
    fn an_encoder_failure_reads_as_an_encode_error() {
        let failure = serde_json::from_str::<Value>("{").unwrap_err();
        let detail = failure.to_string();
        assert_eq!(
            encode_failed(&failure),
            ResolveError::Encode { message: detail }
        );
    }

    #[test]
    fn an_approval_event_needs_an_object_result() {
        assert_eq!(
            approval_event_body(json!({"action": "accept"}), "e1"),
            Ok(json!({"type": "approval", "data": {"action": "accept", "elicitation_id": "e1"}}))
        );
        assert_eq!(
            approval_event_body(json!(7), "e1"),
            Err(ResolveError::Encode {
                message: "expected an object result, got 7".to_owned()
            })
        );
    }
}
