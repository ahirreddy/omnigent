//! Live conversation reducer: folds history pages and stream events into presentable state.
//!
//! The reducer is a pure, deterministic state machine ported from `NativeLab`'s
//! `LiveConversationReducer`, `SessionEventState`, `ConversationActivity` and
//! `LiveEventPresentation`, adjusted to the current server contract
//! (`client-core/docs/wire-contract.md`).
//!
//! - [`LiveReducer`] holds a [`ConversationSnapshot`]: rows (messages, in-flight text keyed by
//!   `message_id` and chunk `index`, reasoning summaries, tool calls and outputs, errors and
//!   lifecycle receipts), decisions, the session header and sparse [`SessionEventState`].
//! - [`LiveReducer::apply`] folds one decoded [`ServerStreamEvent`];
//!   [`LiveReducer::apply_value`] decodes the SSE `data:` JSON first (aliases, scope and the
//!   flat/nested item shapes). [`LiveReducer::reconcile`] merges an authoritative history read.
//! - Every call returns a [`ChangeSet`] of [`RowOp`]s keyed by stable row id, plus wholesale
//!   header, decision and section replacements, so a host store can patch in place.
//! - [`project_item`] is the single item presentation used for both history and live commits.
//!   Activity titles such as `Using <model>` and `Terminal output` come from it.
//!
//! History-vs-live reconciliation across hydrations and reconnects lives in
//! [`crate::reconcile`].

mod activity;
mod events;
mod live;
mod merge;
mod ops;
mod presentation;
mod state;

#[cfg(test)]
#[allow(
    clippy::redundant_pub_crate,
    reason = "test helpers are shared with the reconcile tests"
)]
pub(crate) mod tests;

use omnigent_protocol::{DecodeError, FromWire, ServerStreamEvent};
use serde_json::{Map, Value};

use crate::realtime::StreamEvent;

pub use activity::{ProjectionError, project_item};
pub use live::{BrowserActionRequest, Effects, LiveReducer, Outcome};
pub use ops::{ChangeSet, RowOp, RowOpError, apply_row_ops, diff_rows};
pub use presentation::{
    EventSection, capitalized, display_text, effort_label, fingerprint, model_label, sections,
};
pub use state::{
    Activity, ActivityKind, Attachment, AttachmentKind, ChangedFile, ChangedFiles,
    ConversationSnapshot, Decision, DetailSection, EVENT_PREFIX, LIVE_PREFIX, MAX_RECORDS,
    ReportedValue, Row, RowRole, SessionEventState, SessionHeader, SessionSettings, TurnStatus,
};

/// Why an event could not be applied. The reducer state is unchanged.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ReducerError {
    /// The event payload does not decode (a known type with a broken shape).
    #[error("could not decode stream event: {0}")]
    Decode(#[from] DecodeError),
    /// A committed item cannot be shown.
    #[error("could not present committed item: {0}")]
    Projection(#[from] ProjectionError),
}

/// `NativeLab` accepted `response.TaskStatus.<STATUS>` aliases for the response lifecycle.
const TASK_STATUS_ALIAS: &str = ".TaskStatus.";

/// The canonical type of a wire event type: `response.TaskStatus.COMPLETED` becomes
/// `response.completed` and the retired `response.started` becomes `response.in_progress`
/// (wire-contract divergence D3).
#[must_use]
pub fn canonical_event_type(event_type: &str) -> String {
    if event_type.contains(TASK_STATUS_ALIAS) {
        let status = event_type.rsplit('.').next().unwrap_or_default();
        return format!("response.{}", status.to_lowercase());
    }
    if event_type == "response.started" {
        return "response.in_progress".to_owned();
    }
    event_type.to_owned()
}

fn string<'a>(fields: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    fields.get(key).and_then(Value::as_str)
}

/// Fills what older payloads leave implicit on a committed item: a message without a role is the
/// assistant's, and an item without a response id belongs to the event's `response_id`.
fn complete_item(fields: &mut Map<String, Value>) {
    let event_response = string(fields, "response_id").map(str::to_owned);
    let Some(Value::Object(item)) = fields.get_mut("item") else {
        return;
    };
    if string(item, "type") == Some("message") {
        let nested_role = item
            .get("data")
            .and_then(Value::as_object)
            .is_some_and(|data| data.contains_key("role"));
        if !item.contains_key("role") && !nested_role {
            match item.get_mut("data") {
                Some(Value::Object(data)) => {
                    data.insert("role".to_owned(), Value::String("assistant".to_owned()));
                }
                _ => {
                    item.insert("role".to_owned(), Value::String("assistant".to_owned()));
                }
            }
        }
    }
    if let Some(response) = event_response
        && !item.contains_key("response_id")
    {
        item.insert("response_id".to_owned(), Value::String(response));
    }
}

/// Decodes one stream event payload (the SSE `data:` JSON) for the conversation `session_id`.
///
/// Returns `Ok(None)` for an event scoped to another conversation (`conversation_id` or
/// `session_id` naming a different session): it must not touch this conversation.
///
/// # Errors
///
/// The payload is not an object, has no `type`, or is a known type with a broken shape (for
/// example a negative `context_tokens` or a fractional chunk `index`).
pub fn decode_event(
    value: Value,
    session_id: &str,
) -> Result<Option<ServerStreamEvent>, DecodeError> {
    let Value::Object(mut fields) = value else {
        return Err(DecodeError::NotAnObject {
            context: "event".to_owned(),
        });
    };
    let event_type = match string(&fields, "type") {
        Some(event_type) if !event_type.is_empty() => canonical_event_type(event_type),
        _ => {
            return Err(DecodeError::MissingField {
                context: "event".to_owned(),
                field: "type".to_owned(),
            });
        }
    };
    let scope = string(&fields, "conversation_id").or_else(|| string(&fields, "session_id"));
    if scope.is_some_and(|scope| scope != session_id) {
        return Ok(None);
    }
    if event_type == "response.output_item.done" {
        complete_item(&mut fields);
    }
    fields.insert("type".to_owned(), Value::String(event_type));
    ServerStreamEvent::from_value(Value::Object(fields)).map(Some)
}

impl LiveReducer {
    /// Decodes and applies one stream event payload (the SSE `data:` JSON).
    ///
    /// # Errors
    ///
    /// As [`decode_event`] and [`LiveReducer::apply`]. The state is unchanged on error.
    pub fn apply_value(&mut self, value: Value) -> Result<Outcome, ReducerError> {
        let Some(event) = decode_event(value, self.snapshot().id())? else {
            return Ok(Outcome::default());
        };
        self.apply(&event)
    }

    /// Decodes and applies one event from the session stream machine.
    ///
    /// # Errors
    ///
    /// As [`LiveReducer::apply_value`].
    pub fn apply_stream_event(&mut self, event: &StreamEvent) -> Result<Outcome, ReducerError> {
        self.apply_value(Value::Object(event.data.clone()))
    }
}
