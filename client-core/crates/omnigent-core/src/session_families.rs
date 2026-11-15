//! Session families ("nested agents"): independent root sessions grouped under one
//! representative, as the server reports them on each owned row (`family`).
//!
//! The rules here are the web's (`web/src/lib/sessionFamilies.ts`, `isPinOrderUnit`): a member
//! nested under another representative cannot be pinned or moved on its own; it shows pinned
//! with its family, and only representatives and standalone sessions take pin slots.

use serde_json::{Map, Value};

use crate::client::sessions::SessionSummary;

pub use omnigent_protocol::sessions::SessionFamily;

/// The server's answer to a nested member pinned or moved on its own; the client refuses the
/// same edits with it before sending them.
pub const NESTED_MEMBER_EDIT_REFUSAL: &str =
    "Only the family representative can move or pin the family";

/// Where "Add nested agent" may start the new member (`sibling_session_destinations`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub enum SiblingDestinations {
    /// Only the source session's host.
    CurrentHost,
    /// The source session's host, or a new managed sandbox.
    CurrentHostOrNewSandbox,
    /// Any host.
    #[default]
    AnyHost,
}

impl SiblingDestinations {
    /// Reads `sibling_session_destinations`: missing (or `null`) and `any_host` allow any host,
    /// `current_host_or_new_sandbox` is itself, and anything else falls back to the current host.
    #[must_use]
    pub fn from_info(info: &Map<String, Value>) -> Self {
        match info.get("sibling_session_destinations") {
            None | Some(Value::Null) => Self::AnyHost,
            Some(Value::String(value)) if value == "any_host" => Self::AnyHost,
            Some(Value::String(value)) if value == "current_host_or_new_sandbox" => {
                Self::CurrentHostOrNewSandbox
            }
            Some(_) => Self::CurrentHost,
        }
    }
}

/// Whether the server lets the caller add nested agents (`sibling_sessions`): only `true` turns
/// it on. Existing families and their pin and move rules apply either way.
#[must_use]
pub fn sibling_sessions_enabled(info: &Map<String, Value>) -> bool {
    info.get("sibling_sessions") == Some(&Value::Bool(true))
}

/// Whether `session` shows pinned.
///
/// A nested member shows its family's pin: its representative's row as the list shows it when
/// `representative` is loaded, else the family's `pinned`. Any other row shows its own pin, so a
/// stale personal pin on a member is ignored.
#[must_use]
pub fn shows_pinned(session: &SessionSummary, representative: Option<&SessionSummary>) -> bool {
    let Some(family) = session
        .family
        .as_ref()
        .filter(|_| session.is_nested_member())
    else {
        return session.is_pinned;
    };
    representative
        .filter(|row| family.representative_id.as_deref() == Some(row.id.as_str()))
        .map_or(family.pinned, |row| row.is_pinned)
}

/// Whether `session` takes a pin slot when pinned (the web's `isPinOrderUnit`): a standalone
/// session, or its family's representative. Members never use a slot.
#[must_use]
pub fn is_pin_unit(session: &SessionSummary) -> bool {
    session
        .family
        .as_ref()
        .is_none_or(|family| family.representative_id.as_deref() == Some(session.id.as_str()))
}

/// Whether `selected` can move to a project together (the web's bulk move): every nested member
/// among them has its representative selected too, which moves the family.
#[must_use]
pub fn can_move_together(selected: &[SessionSummary]) -> bool {
    selected
        .iter()
        .filter(|row| row.is_nested_member())
        .all(|member| {
            let representative = member
                .family
                .as_ref()
                .and_then(|family| family.representative_id.as_deref());
            selected
                .iter()
                .any(|row| Some(row.id.as_str()) == representative)
        })
}

/// The pinned rows that take pin slots: what the pin limit counts and pin order rewrites.
#[must_use]
pub fn pinned_units(sessions: &[SessionSummary]) -> Vec<&SessionSummary> {
    sessions
        .iter()
        .filter(|session| session.is_pinned && !session.is_archived && is_pin_unit(session))
        .collect()
}

#[cfg(test)]
#[path = "session_families_tests.rs"]
mod tests;
