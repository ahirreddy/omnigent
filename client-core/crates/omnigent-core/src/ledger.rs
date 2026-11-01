//! Submission ledger for sends whose outcome is uncertain.
//!
//! `POST /v1/sessions/{id}/events` has no idempotency key, so a send that fails ambiguously must
//! never be retried automatically. The ledger tracks, per delivery scope (server plus account) and
//! session, the one send in flight and every send whose outcome is uncertain. A session with
//! either cannot start another send. An uncertain send stays blocking until the user has reviewed
//! it and the host calls [`SubmissionLedger::acknowledge_uncertainty`].
//!
//! Delivery state belongs to the scope and session, not to a view or a connection generation:
//! reconnecting to the same scope keeps a pending send blocking, and the same session id on
//! another server or account is independent.

use std::collections::{BTreeMap, BTreeSet};

/// Identifies one [`SubmissionOperation`]. Ids are unique within one ledger.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct OperationId(u64);

impl OperationId {
    /// The raw id, for logging and FFI mirrors.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

/// One send the ledger has admitted. Only [`SubmissionLedger::begin`] creates these.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubmissionOperation {
    id: OperationId,
    scope: String,
    session_id: String,
    draft: String,
}

impl SubmissionOperation {
    /// The operation's id.
    #[must_use]
    pub const fn id(&self) -> OperationId {
        self.id
    }

    /// Delivery scope (server plus account) the send belongs to.
    #[must_use]
    pub fn scope(&self) -> &str {
        &self.scope
    }

    /// Session the send targets.
    #[must_use]
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// The draft text as it was when the send began.
    #[must_use]
    pub fn draft(&self) -> &str {
        &self.draft
    }
}

/// How a send ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SubmissionOutcome {
    /// The server acknowledged the send.
    Accepted,
    /// The server definitely did not take the send (for example a denied acknowledgement or a
    /// 4xx). The draft stays and the user may resend it by hand.
    Rejected,
    /// The outcome is unknown (connection lost, cancelled, malformed acknowledgement). The send may
    /// have been delivered, so it must not be retried automatically.
    Uncertain,
}

/// What the composer should show after [`SubmissionLedger::complete`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubmissionResolution {
    /// The draft to keep in the composer: cleared after an accepted send of an unedited draft,
    /// otherwise the current draft unchanged.
    pub draft: String,
    /// The session is blocked by an uncertain send until the user acknowledges it.
    pub is_uncertain: bool,
}

/// Why the ledger refused a request.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum LedgerError {
    /// A send for this scope and session is already in flight.
    #[error("a message to session {session_id} is already being sent")]
    SendInFlight {
        /// The blocked session.
        session_id: String,
    },
    /// A previous send's outcome is uncertain and has not been reviewed.
    #[error(
        "the last message to session {session_id} may already have been delivered; review it before sending again"
    )]
    DeliveryUncertain {
        /// The blocked session.
        session_id: String,
    },
    /// The completion is for an operation that is no longer the one in flight (a duplicate or
    /// late completion). The ledger is unchanged.
    #[error("operation {} is not the send in flight", operation.get())]
    StaleOperation {
        /// The operation that was completed.
        operation: OperationId,
    },
    /// The ledger has issued every possible operation id.
    #[error("submission ledger operation ids are exhausted")]
    IdsExhausted,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
struct Key {
    scope: String,
    session_id: String,
}

impl Key {
    fn new(scope: &str, session_id: &str) -> Self {
        Self {
            scope: scope.to_owned(),
            session_id: session_id.to_owned(),
        }
    }
}

/// Delivery state for message sends, keyed by scope and session.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SubmissionLedger {
    next_id: u64,
    pending: BTreeMap<Key, SubmissionOperation>,
    uncertain: BTreeSet<Key>,
}

impl SubmissionLedger {
    /// An empty ledger.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Admits a send of `draft` to `session_id` in `scope`.
    ///
    /// # Errors
    ///
    /// [`LedgerError::SendInFlight`] or [`LedgerError::DeliveryUncertain`] when the session is
    /// blocked; [`LedgerError::IdsExhausted`] if no id is left.
    pub fn begin(
        &mut self,
        scope: &str,
        session_id: &str,
        draft: &str,
    ) -> Result<SubmissionOperation, LedgerError> {
        let key = Key::new(scope, session_id);
        if self.pending.contains_key(&key) {
            return Err(LedgerError::SendInFlight {
                session_id: session_id.to_owned(),
            });
        }
        if self.uncertain.contains(&key) {
            return Err(LedgerError::DeliveryUncertain {
                session_id: session_id.to_owned(),
            });
        }
        let id = OperationId(self.next_id);
        self.next_id = self
            .next_id
            .checked_add(1)
            .ok_or(LedgerError::IdsExhausted)?;
        let operation = SubmissionOperation {
            id,
            scope: key.scope.clone(),
            session_id: key.session_id.clone(),
            draft: draft.to_owned(),
        };
        self.pending.insert(key, operation.clone());
        Ok(operation)
    }

    /// Records how `operation` ended. `current_draft` is what the composer holds now; it is
    /// cleared only when the send was accepted and the user has not edited the draft since.
    ///
    /// # Errors
    ///
    /// [`LedgerError::StaleOperation`] when `operation` is not the send in flight for its session
    /// (an old or duplicate completion). Nothing changes in that case.
    pub fn complete(
        &mut self,
        operation: &SubmissionOperation,
        outcome: SubmissionOutcome,
        current_draft: &str,
    ) -> Result<SubmissionResolution, LedgerError> {
        let key = Key::new(&operation.scope, &operation.session_id);
        if self.pending.get(&key) != Some(operation) {
            return Err(LedgerError::StaleOperation {
                operation: operation.id,
            });
        }
        self.pending.remove(&key);
        if outcome == SubmissionOutcome::Uncertain {
            self.uncertain.insert(key.clone());
        }
        let draft = if outcome == SubmissionOutcome::Accepted && current_draft == operation.draft {
            String::new()
        } else {
            current_draft.to_owned()
        };
        Ok(SubmissionResolution {
            draft,
            is_uncertain: self.uncertain.contains(&key),
        })
    }

    /// Sessions in `scope` with a send in flight.
    #[must_use]
    pub fn pending_session_ids(&self, scope: &str) -> BTreeSet<String> {
        self.pending
            .keys()
            .filter(|key| key.scope == scope)
            .map(|key| key.session_id.clone())
            .collect()
    }

    /// Sessions in `scope` blocked by an unreviewed uncertain send.
    #[must_use]
    pub fn uncertain_session_ids(&self, scope: &str) -> BTreeSet<String> {
        self.uncertain
            .iter()
            .filter(|key| key.scope == scope)
            .map(|key| key.session_id.clone())
            .collect()
    }

    /// Whether [`Self::begin`] would refuse a send to `session_id` in `scope`.
    #[must_use]
    pub fn is_blocked(&self, scope: &str, session_id: &str) -> bool {
        let key = Key::new(scope, session_id);
        self.pending.contains_key(&key) || self.uncertain.contains(&key)
    }

    /// Records that the user has reviewed the uncertain send to `session_id` in `scope`, which
    /// unblocks it. Returns whether the session was uncertain.
    pub fn acknowledge_uncertainty(&mut self, scope: &str, session_id: &str) -> bool {
        self.uncertain.remove(&Key::new(scope, session_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCOPE: &str = "http://127.0.0.1:6767|local";

    fn ids(values: &[&str]) -> BTreeSet<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn pending_send_remains_blocked_when_reconnecting_to_same_scope() {
        let mut ledger = SubmissionLedger::new();
        ledger.begin(SCOPE, "session", "Hello").unwrap();
        assert_eq!(ledger.pending_session_ids(SCOPE), ids(&["session"]));
        assert!(ledger.pending_session_ids("offline-demo").is_empty());
        assert_eq!(ledger.pending_session_ids(SCOPE), ids(&["session"]));
        assert!(ledger.is_blocked(SCOPE, "session"));
        assert_eq!(
            ledger.begin(SCOPE, "session", "Hello again"),
            Err(LedgerError::SendInFlight {
                session_id: "session".into()
            })
        );
    }

    #[test]
    fn late_accepted_completion_clears_same_draft_in_reconnected_scope() {
        let mut ledger = SubmissionLedger::new();
        let operation = ledger.begin(SCOPE, "session", "Hello").unwrap();
        let result = ledger
            .complete(&operation, SubmissionOutcome::Accepted, "Hello")
            .unwrap();
        assert_eq!(result.draft, "");
        assert!(!result.is_uncertain);
        assert!(ledger.pending_session_ids(SCOPE).is_empty());
    }

    #[test]
    fn late_accepted_completion_preserves_edited_draft() {
        let mut ledger = SubmissionLedger::new();
        let operation = ledger.begin(SCOPE, "session", "Hello").unwrap();
        let result = ledger
            .complete(&operation, SubmissionOutcome::Accepted, "A new thought")
            .unwrap();
        assert_eq!(result.draft, "A new thought");
    }

    #[test]
    fn uncertain_completion_retains_draft_and_blocks_across_scope_switch_until_review() {
        let mut ledger = SubmissionLedger::new();
        let operation = ledger.begin(SCOPE, "session", "Hello").unwrap();
        let result = ledger
            .complete(&operation, SubmissionOutcome::Uncertain, "Hello")
            .unwrap();
        assert_eq!(result.draft, "Hello");
        assert!(result.is_uncertain);
        assert_eq!(ledger.uncertain_session_ids(SCOPE), ids(&["session"]));
        assert!(ledger.uncertain_session_ids("offline-demo").is_empty());
        assert_eq!(
            ledger.begin(SCOPE, "session", "Changed draft"),
            Err(LedgerError::DeliveryUncertain {
                session_id: "session".into()
            })
        );
        assert!(!ledger.acknowledge_uncertainty("offline-demo", "session"));
        assert!(ledger.acknowledge_uncertainty(SCOPE, "session"));
        assert!(ledger.uncertain_session_ids(SCOPE).is_empty());
        assert!(ledger.begin(SCOPE, "session", "Reviewed retry").is_ok());
    }

    #[test]
    fn rejected_completion_retains_draft_without_forcing_automatic_retry() {
        let mut ledger = SubmissionLedger::new();
        let operation = ledger.begin(SCOPE, "session", "Hello").unwrap();
        let result = ledger
            .complete(&operation, SubmissionOutcome::Rejected, "Hello")
            .unwrap();
        assert_eq!(result.draft, "Hello");
        assert!(!result.is_uncertain);
        assert!(ledger.pending_session_ids(SCOPE).is_empty());
        assert!(!ledger.is_blocked(SCOPE, "session"));
        assert!(ledger.begin(SCOPE, "session", "Manual retry").is_ok());
    }

    #[test]
    fn duplicate_old_completion_cannot_finish_newer_operation() {
        let mut ledger = SubmissionLedger::new();
        let old = ledger.begin(SCOPE, "session", "First").unwrap();
        ledger
            .complete(&old, SubmissionOutcome::Accepted, "First")
            .unwrap();
        let newer = ledger.begin(SCOPE, "session", "Second").unwrap();
        assert_ne!(old.id(), newer.id());
        assert_eq!(
            ledger.complete(&old, SubmissionOutcome::Uncertain, "Second"),
            Err(LedgerError::StaleOperation {
                operation: old.id()
            })
        );
        assert_eq!(ledger.pending_session_ids(SCOPE), ids(&["session"]));
        assert!(ledger.uncertain_session_ids(SCOPE).is_empty());
        assert_eq!(
            ledger
                .complete(&newer, SubmissionOutcome::Accepted, "Second")
                .unwrap()
                .draft,
            ""
        );
    }

    #[test]
    fn same_session_id_on_other_server_or_account_has_independent_delivery_state() {
        let mut ledger = SubmissionLedger::new();
        let old = ledger.begin(SCOPE, "session", "First").unwrap();
        let other_scope = "http://127.0.0.1:7777|other";
        let other = ledger.begin(other_scope, "session", "Second").unwrap();
        ledger
            .complete(&old, SubmissionOutcome::Uncertain, "First")
            .unwrap();
        assert_eq!(ledger.pending_session_ids(other_scope), ids(&["session"]));
        assert!(ledger.uncertain_session_ids(other_scope).is_empty());
        assert_eq!(
            ledger
                .complete(&other, SubmissionOutcome::Accepted, "Second")
                .unwrap()
                .draft,
            ""
        );
        assert_eq!(ledger.uncertain_session_ids(SCOPE), ids(&["session"]));
    }
}
