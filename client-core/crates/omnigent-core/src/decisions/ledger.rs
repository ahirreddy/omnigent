//! The decision cards one session shows.
//!
//! - A card is retired only by `response.elicitation_resolved` with its **exact** id, or by a
//!   snapshot that no longer lists it. Tool output (even with the same call id) never retires one.
//! - Retired ids are remembered (bounded), so a replayed request or a stale snapshot cannot bring
//!   a resolved card back, and answering it is [`DecisionError::AlreadyResolved`].
//! - A resolution for an id the session never showed is reported as
//!   [`ResolvedOutcome::Unknown`]: it must not stop the running response.
//!
//! This is the decisions half of `NativeLab`'s `LiveConversationReducer` elicitation handling; the
//! reducer (WP3) owns turn status and calls in here.

use std::collections::VecDeque;

use omnigent_protocol::{
    ElicitationRequest, ElicitationResolution, ElicitationResolved, ServerStreamEvent,
};

use super::Decision;
use super::resolve::{DecisionError, DecisionResponse, ResolveRequest};

/// How many retired ids a session remembers.
pub const MAX_RETIRED_IDS: usize = 512;

/// Where a card stands.
#[derive(Debug, Clone, PartialEq)]
pub enum DecisionState {
    /// Waiting for an answer.
    Pending,
    /// Answered from this client and accepted by the server; the server's
    /// `response.elicitation_resolved` has not arrived yet.
    Answered(DecisionResponse),
}

/// A card and its state.
#[derive(Debug, Clone, PartialEq)]
pub struct DecisionEntry {
    /// The card.
    pub decision: Decision,
    /// Its state.
    pub state: DecisionState,
}

/// What a `response.elicitation_request` did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestOutcome {
    /// A new card.
    Added,
    /// Replaced the pending card with the same id.
    Replaced,
    /// Ignored: the id was already resolved or answered (a replay or a stale request).
    Stale,
}

/// What a `response.elicitation_resolved` did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolvedOutcome {
    /// Retired the card with this id.
    Retired(ElicitationResolution),
    /// No card had this id. Nothing changed; in particular the running response continues.
    Unknown,
}

/// The cards one session shows.
#[derive(Debug, Clone, PartialEq)]
pub struct SessionDecisions {
    session_id: String,
    entries: Vec<DecisionEntry>,
    retired: VecDeque<String>,
}

impl SessionDecisions {
    /// No cards, for `session_id` (the session whose stream and snapshot carry the cards).
    #[must_use]
    pub fn new(session_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            entries: Vec::new(),
            retired: VecDeque::new(),
        }
    }

    /// The carrying session.
    #[must_use]
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// Every card this session shows, pending or answered, in arrival order.
    #[must_use]
    pub fn entries(&self) -> &[DecisionEntry] {
        &self.entries
    }

    /// Cards waiting for an answer, in arrival order.
    pub fn pending(&self) -> impl Iterator<Item = &Decision> {
        self.entries
            .iter()
            .filter(|entry| entry.state == DecisionState::Pending)
            .map(|entry| &entry.decision)
    }

    /// Whether any card waits for an answer (the session's "needs response" state).
    #[must_use]
    pub fn needs_response(&self) -> bool {
        self.pending().next().is_some()
    }

    /// Whether `id` was retired.
    #[must_use]
    pub fn is_retired(&self, id: &str) -> bool {
        self.retired.iter().any(|retired| retired == id)
    }

    fn retire(&mut self, id: &str) {
        if !self.is_retired(id) {
            self.retired.push_back(id.to_owned());
            while self.retired.len() > MAX_RETIRED_IDS {
                self.retired.pop_front();
            }
        }
    }

    fn position(&self, id: &str) -> Option<usize> {
        self.entries
            .iter()
            .position(|entry| entry.decision.id == id)
    }

    /// Applies a request from the stream or a snapshot.
    pub fn apply_request(&mut self, request: &ElicitationRequest) -> RequestOutcome {
        let decision = Decision::from_request(request, &self.session_id);
        if self.is_retired(&decision.id) {
            return RequestOutcome::Stale;
        }
        let entry = DecisionEntry {
            decision,
            state: DecisionState::Pending,
        };
        match self.position(&entry.decision.id) {
            None => {
                self.entries.push(entry);
                RequestOutcome::Added
            }
            Some(index) => match self.entries.get_mut(index) {
                Some(existing) if existing.state == DecisionState::Pending => {
                    *existing = entry;
                    RequestOutcome::Replaced
                }
                _ => RequestOutcome::Stale,
            },
        }
    }

    /// Applies `response.elicitation_resolved`: only the exact id retires a card.
    pub fn apply_resolved(&mut self, resolved: &ElicitationResolved) -> ResolvedOutcome {
        let id = resolved.elicitation_id.as_str();
        let known = self.position(id);
        // Remember even unknown ids, so a request that arrives late cannot resurrect them.
        self.retire(id);
        match known {
            Some(index) => {
                self.entries.remove(index);
                ResolvedOutcome::Retired(resolved.resolution())
            }
            None => ResolvedOutcome::Unknown,
        }
    }

    /// Applies a stream event. Only the two elicitation events touch decisions; every other event
    /// (tool output included) returns `None`.
    pub fn apply_event(&mut self, event: &ServerStreamEvent) -> Option<DecisionEventOutcome> {
        match event {
            ServerStreamEvent::ElicitationRequest(request) => {
                Some(DecisionEventOutcome::Request(self.apply_request(request)))
            }
            ServerStreamEvent::ElicitationResolved(resolved) => Some(
                DecisionEventOutcome::Resolved(self.apply_resolved(resolved)),
            ),
            _ => None,
        }
    }

    /// Reconciles with a snapshot's `pending_elicitations`: cards the snapshot no longer lists are
    /// retired, and listed cards are added unless already retired. The caller decides whether the
    /// snapshot is newer than the live stream before calling.
    pub fn reconcile(&mut self, snapshot_pending: &[ElicitationRequest]) {
        let listed = |id: &str| {
            snapshot_pending
                .iter()
                .any(|request| request.elicitation_id == id)
        };
        let gone: Vec<String> = self
            .entries
            .iter()
            .filter(|entry| !listed(&entry.decision.id))
            .map(|entry| entry.decision.id.clone())
            .collect();
        for id in &gone {
            self.retire(id);
        }
        self.entries.retain(|entry| listed(&entry.decision.id));
        for request in snapshot_pending {
            self.apply_request(request);
        }
    }

    /// The validated request answering `decision_id` with `response`. Does not change state.
    ///
    /// # Errors
    ///
    /// [`DecisionError::ReadOnly`] when `read_only`; [`DecisionError::AlreadyResolved`] for a
    /// retired or already answered card; [`DecisionError::NotFound`] for an id this session does
    /// not show; otherwise see [`Decision::resolve_request`].
    pub fn prepare_resolve(
        &self,
        decision_id: &str,
        response: &DecisionResponse,
        read_only: bool,
    ) -> Result<ResolveRequest, DecisionError> {
        if read_only {
            return Err(DecisionError::ReadOnly);
        }
        self.pending_entry(decision_id)?
            .decision
            .resolve_request(response)
    }

    fn pending_entry(&self, decision_id: &str) -> Result<&DecisionEntry, DecisionError> {
        let entry = self
            .entries
            .iter()
            .find(|entry| entry.decision.id == decision_id);
        match entry {
            Some(entry) if entry.state == DecisionState::Pending => Ok(entry),
            Some(_) => Err(DecisionError::AlreadyResolved {
                decision_id: decision_id.to_owned(),
            }),
            None if self.is_retired(decision_id) => Err(DecisionError::AlreadyResolved {
                decision_id: decision_id.to_owned(),
            }),
            None => Err(DecisionError::NotFound {
                decision_id: decision_id.to_owned(),
            }),
        }
    }

    /// Records that the server accepted `response` for `decision_id`. The card stays visible as
    /// answered until the server's resolution retires it, and cannot be answered again.
    ///
    /// # Errors
    ///
    /// [`DecisionError::AlreadyResolved`] or [`DecisionError::NotFound`], as for
    /// [`SessionDecisions::prepare_resolve`].
    pub fn record_answered(
        &mut self,
        decision_id: &str,
        response: DecisionResponse,
    ) -> Result<(), DecisionError> {
        self.pending_entry(decision_id)?;
        let entry = self
            .entries
            .iter_mut()
            .find(|entry| entry.decision.id == decision_id)
            .ok_or_else(|| DecisionError::NotFound {
                decision_id: decision_id.to_owned(),
            })?;
        entry.state = DecisionState::Answered(response);
        Ok(())
    }
}

/// What a stream event did to the session's decisions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecisionEventOutcome {
    /// A `response.elicitation_request`.
    Request(RequestOutcome),
    /// A `response.elicitation_resolved`.
    Resolved(ResolvedOutcome),
}
