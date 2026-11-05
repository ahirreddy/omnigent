//! The live reducer: response lifecycle, streamed text, commits and decisions.
//!
//! Ported from `NativeLab`'s `LiveConversationReducer`. Display-only events, activity previews and
//! session metadata live in the sibling `events` module.

use std::collections::{BTreeMap, BTreeSet};

use omnigent_protocol::elicitation::{ElicitationRequest, ElicitationResolved};
use omnigent_protocol::events::{
    OutputTextDeltaEvent, ResponseLifecycleEvent, ResponseObject, SessionStatusEvent,
};
use omnigent_protocol::items::ErrorSource;
use omnigent_protocol::{ConversationItem, Field, ServerStreamEvent, SessionStatus};
use serde_json::Value;

use super::ReducerError;
use super::activity::{interrupted_reply, project_item};
use super::ops::{ChangeSet, Journal};
use super::presentation::{EventSection, sections};
use super::state::{
    ActivityKind, ConversationSnapshot, Decision, LIVE_PREFIX, ReportedValue, Row, RowRole,
    SessionEventState, SessionHeader, TurnStatus,
};

/// Response id placeholder for text that streams before any response is known.
pub(super) const UNIDENTIFIED: &str = "unidentified";
const LIVE_RESPONSE_PREFIX: &str = "live:response:";

/// What one event asks of the host besides re-rendering.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Effects {
    /// The conversation changed.
    pub changed: bool,
    /// Authoritative state should be re-read (re-hydrate).
    pub reconcile: bool,
    /// `session.input.consumed`: the persisted item id (matches a POST `item_id`).
    pub consumed_item_id: Option<String>,
    /// `session.input.consumed`: the cleared pending id (matches a POST `pending_id`).
    pub consumed_pending_id: Option<String>,
    /// A readable failure to surface.
    pub error: Option<String>,
    /// Refetch changed files for this environment.
    pub changed_files_environment: Option<String>,
    /// `browser.action_request`: an agent browser action a capable host may claim and run.
    pub browser_action: Option<BrowserActionRequest>,
}

/// One agent browser action the server asked a desktop client to perform.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrowserActionRequest {
    /// The session whose stream delivered it; the claim and result go to this session.
    pub session_id: String,
    /// The server's correlation id, for example `baction_…`.
    pub action_id: String,
    /// The `browser_` tool name without the prefix, for example `navigate`.
    pub action: String,
    /// The tool arguments, as sent.
    pub args: serde_json::Map<String, Value>,
}

/// The result of applying one event.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Outcome {
    /// Host effects.
    pub effects: Effects,
    /// UI changes.
    pub changes: ChangeSet,
}

/// How a response ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Ending {
    Completed,
    Failed,
    Incomplete,
    Cancelled,
    Interrupted,
}

impl Ending {
    const fn label(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Incomplete => "incomplete",
            Self::Cancelled => "cancelled",
            Self::Interrupted => "interrupted",
        }
    }
}

/// The parts of the state a change set compares wholesale.
#[derive(Debug, Clone)]
pub(super) struct Checkpoint {
    header: SessionHeader,
    decisions: Vec<Decision>,
}

/// Folds live events and authoritative snapshots into a [`ConversationSnapshot`].
///
/// Pure and deterministic: no clock, no I/O. Every call reports its UI changes as a
/// [`ChangeSet`]. Create a fresh reducer for every new stream connection (a real reconnect) so the
/// server's in-flight replay is not appended to text the old connection already showed.
#[derive(Debug, Clone)]
pub struct LiveReducer {
    pub(super) snap: ConversationSnapshot,
    pub(super) response_id: Option<String>,
    pub(super) segment: u64,
    pub(super) native_indices: BTreeMap<String, u64>,
    pub(super) retired_native: BTreeSet<String>,
    pub(super) activity_sequence: u64,
    pub(super) activity_indices: BTreeMap<String, u64>,
    pub(super) activity_buffers: BTreeMap<String, String>,
    pub(super) active_reasoning: Option<String>,
    pub(super) activity_item_ids: BTreeMap<String, String>,
    pub(super) retired_activity: BTreeSet<String>,
    pub(super) ended_responses: BTreeSet<String>,
    pub(super) accepts_response_deltas: bool,
    pub(super) accepts_native_deltas: bool,
    pub(super) resolved_decisions: BTreeSet<String>,
    pub(super) journal: Journal,
    pub(super) state_dirty: bool,
    pub(super) published_sections: Vec<EventSection>,
}

impl LiveReducer {
    /// A reducer over `snapshot`. Live previews in it are dropped: a new reducer starts from
    /// committed state, and locally answered decisions stay answered.
    #[must_use]
    pub fn new(mut snapshot: ConversationSnapshot) -> Self {
        snapshot.rows.retain(|row| !row.id.starts_with(LIVE_PREFIX));
        let resolved_decisions = snapshot
            .decisions
            .iter()
            .filter(|decision| decision.answered)
            .map(|decision| decision.id.clone())
            .collect();
        let published_sections = sections(&snapshot.event_state);
        Self {
            snap: snapshot,
            response_id: None,
            segment: 0,
            native_indices: BTreeMap::new(),
            retired_native: BTreeSet::new(),
            activity_sequence: 0,
            activity_indices: BTreeMap::new(),
            activity_buffers: BTreeMap::new(),
            active_reasoning: None,
            activity_item_ids: BTreeMap::new(),
            retired_activity: BTreeSet::new(),
            ended_responses: BTreeSet::new(),
            accepts_response_deltas: true,
            accepts_native_deltas: true,
            resolved_decisions,
            journal: Journal::default(),
            state_dirty: false,
            published_sections,
        }
    }

    /// The current state.
    #[must_use]
    pub const fn snapshot(&self) -> &ConversationSnapshot {
        &self.snap
    }

    /// The current state, consuming the reducer.
    #[must_use]
    pub fn into_snapshot(self) -> ConversationSnapshot {
        self.snap
    }

    /// The active response, when one is known.
    #[must_use]
    pub fn response_id(&self) -> Option<&str> {
        self.response_id.as_deref()
    }

    /// The current session sections.
    #[must_use]
    pub fn sections(&self) -> &[EventSection] {
        &self.published_sections
    }

    /// Applies one decoded event.
    ///
    /// # Errors
    ///
    /// A committed item cannot be projected (for example a message with an unknown role) or a
    /// consumed input does not decode. The state is unchanged on error.
    pub fn apply(&mut self, event: &ServerStreamEvent) -> Result<Outcome, ReducerError> {
        let checkpoint = self.checkpoint();
        let result = self.dispatch(event);
        let changes = self.finish(&checkpoint);
        result.map(|effects| Outcome { effects, changes })
    }

    /// Records what the next [`LiveReducer::finish`] compares against.
    pub(super) fn checkpoint(&self) -> Checkpoint {
        Checkpoint {
            header: self.snap.header.clone(),
            decisions: self.snap.decisions.clone(),
        }
    }

    /// The changes made since `checkpoint`; resets the row journal.
    pub(super) fn finish(&mut self, checkpoint: &Checkpoint) -> ChangeSet {
        let rows = self.journal.finish(&self.snap.rows);
        let mut changes = ChangeSet {
            rows,
            ..ChangeSet::default()
        };
        if self.snap.header != checkpoint.header {
            changes.header = Some(self.snap.header.clone());
        }
        if self.snap.decisions != checkpoint.decisions {
            changes.decisions = Some(self.snap.decisions.clone());
        }
        if std::mem::take(&mut self.state_dirty) {
            let current = sections(&self.snap.event_state);
            if current != self.published_sections {
                self.published_sections.clone_from(&current);
                changes.sections = Some(current);
            }
        }
        changes
    }

    /// Replaces the header (a newer metadata read for the same session).
    pub fn set_header(&mut self, header: SessionHeader) -> ChangeSet {
        let checkpoint = self.checkpoint();
        self.snap.header = header;
        self.finish(&checkpoint)
    }

    /// Mutable event state; marks the sections for re-derivation.
    pub(super) const fn state(&mut self) -> &mut SessionEventState {
        self.state_dirty = true;
        &mut self.snap.event_state
    }

    pub(super) fn position(&self, id: &str) -> Option<usize> {
        self.snap.rows.iter().position(|row| row.id == id)
    }

    pub(super) fn push_row(&mut self, row: Row) {
        self.journal.structural(&self.snap.rows);
        self.snap.rows.push(row);
    }

    pub(super) fn remove_row(&mut self, at: usize) {
        if at < self.snap.rows.len() {
            self.journal.structural(&self.snap.rows);
            self.snap.rows.remove(at);
        }
    }

    pub(super) fn row_mut(&mut self, at: usize) -> Option<&mut Row> {
        let id = self.snap.rows.get(at)?.id.clone();
        self.journal.touch(&id);
        self.snap.rows.get_mut(at)
    }

    pub(super) fn replace_row(&mut self, at: usize, row: Row) {
        let Some(current) = self.snap.rows.get(at) else {
            return;
        };
        if current.id == row.id {
            self.journal.touch(&row.id);
        } else {
            self.journal.structural(&self.snap.rows);
        }
        if let Some(slot) = self.snap.rows.get_mut(at) {
            *slot = row;
        }
    }

    pub(super) fn active_status(&self) -> TurnStatus {
        if self.snap.has_pending_decisions() {
            TurnStatus::NeedsResponse
        } else {
            TurnStatus::Running
        }
    }

    pub(super) fn idle_status(&self) -> TurnStatus {
        if self.snap.has_pending_decisions() {
            TurnStatus::NeedsResponse
        } else {
            TurnStatus::Idle
        }
    }

    pub(super) fn scope_id(&self) -> String {
        self.response_id
            .clone()
            .unwrap_or_else(|| self.snap.header.id.clone())
    }

    fn text_section_id(&self) -> String {
        format!(
            "{LIVE_RESPONSE_PREFIX}{}:{}",
            self.response_id.as_deref().unwrap_or(UNIDENTIFIED),
            self.segment
        )
    }

    fn dispatch(&mut self, event: &ServerStreamEvent) -> Result<Effects, ReducerError> {
        use ServerStreamEvent as E;
        if let Some(scope) = event_scope(event)
            && scope != self.snap.header.id
        {
            return Ok(Effects::default());
        }
        if self.is_stale_response_event(event) {
            return Ok(Effects::default());
        }
        let effects = match event {
            E::SessionModel(model) => Ok(self.configuration(&model.model, true)),
            E::SessionReasoningEffort(effort) => {
                Ok(self.configuration(&effort.reasoning_effort, false))
            }
            E::SessionModelOptions(_) | E::SessionAgentChanged(_) => Ok(Effects {
                reconcile: true,
                ..Effects::default()
            }),
            E::ResponseCreated(start) | E::ResponseInProgress(start) => {
                Ok(self.start_response(start, false))
            }
            E::ResponseQueued(start) => Ok(self.start_response(start, true)),
            E::OutputTextDelta(delta) => Ok(self.text_delta(delta)),
            E::OutputItemDone(done) => self.commit_item(done.item.clone()),
            E::SessionInputConsumed(consumed) => {
                let item = consumed.data.item()?;
                let mut effects = self.commit_item(item)?;
                effects.consumed_item_id = Some(consumed.data.item_id.clone());
                effects
                    .consumed_pending_id
                    .clone_from(&consumed.data.cleared_pending_id);
                Ok(effects)
            }
            E::ElicitationRequest(request) => Ok(self.request_decision(request)),
            E::ElicitationResolved(resolved) => Ok(self.resolve_decision(resolved)),
            E::SessionStatus(status) => Ok(self.session_status(status)),
            E::ResponseCompleted(end) => Ok(self.end_lifecycle(Ending::Completed, end)),
            E::ResponseCancelled(end) => Ok(self.end_lifecycle(Ending::Cancelled, end)),
            E::ResponseIncomplete(end) => Ok(self.end_lifecycle(Ending::Incomplete, end)),
            E::ResponseFailed(failed) => Ok(self.end_response(
                Ending::Failed,
                failed.response_id(),
                failed.response.as_ref(),
                failed.source.as_ref(),
            )),
            E::SessionInterrupted(interrupted) => {
                Ok(self.end_response(Ending::Interrupted, interrupted.response_id(), None, None))
            }
            other => Ok(self.apply_presentation_event(other)),
        }?;
        if let Some(error) = &effects.error {
            self.snap.header.failure_message = Some(error.clone());
        }
        Ok(effects)
    }

    /// A response event for a response other than the active one (late, replayed or stale).
    fn is_stale_response_event(&self, event: &ServerStreamEvent) -> bool {
        use ServerStreamEvent as E;
        let exempt = matches!(
            event,
            E::ResponseCreated(_)
                | E::ResponseInProgress(_)
                | E::ResponseQueued(_)
                | E::OutputItemDone(_)
        ) || matches!(event, E::OutputTextDelta(delta) if delta.message_id.is_some());
        if exempt || !event.event_type().starts_with("response.") {
            return false;
        }
        matches!(
            (event_response_id(event), self.response_id.as_deref()),
            (Some(id), Some(current)) if id != current
        )
    }

    fn configuration(&mut self, value: &Field<String>, model: bool) -> Effects {
        let reported = match value {
            Field::Absent => return Effects::default(),
            Field::Null => ReportedValue::HarnessDefault,
            Field::Present(value) => ReportedValue::Value {
                value: value.clone(),
            },
        };
        let mut effects = Effects {
            reconcile: true,
            ..Effects::default()
        };
        if let Some(settings) = &mut self.snap.header.settings {
            if model {
                settings.model_override = reported;
            } else {
                settings.reasoning_effort = reported;
            }
            effects.changed = true;
        }
        effects
    }

    fn start_response(&mut self, start: &ResponseLifecycleEvent, queued: bool) -> Effects {
        if let Some(id) = start.response_id() {
            if self.ended_responses.contains(id) {
                return Effects::default();
            }
            let other = self
                .response_id
                .as_deref()
                .is_some_and(|current| current != id);
            if queued && other && self.snap.header.status == TurnStatus::Running {
                return Effects::default();
            }
            if self.response_id.as_deref() != Some(id) {
                if let Some(previous) = self.response_id.clone() {
                    self.seal_live_content("stopped", true);
                    self.ended_responses.insert(previous);
                } else {
                    self.adopt_unattributed_text(id);
                }
                self.active_reasoning = None;
                self.activity_sequence = 0;
                self.segment = 0;
            }
            self.response_id = Some(id.to_owned());
            let previous = start
                .response
                .as_ref()
                .and_then(|response| response.previous_response_id.as_deref());
            if let Some(previous) = previous.filter(|previous| *previous != id) {
                self.ended_responses.insert(previous.to_owned());
            }
        }
        self.accepts_response_deltas = true;
        self.accepts_native_deltas = true;
        self.snap.header.failure_message = None;
        let label = if queued { "queued" } else { "running" };
        self.state().status = Some(label.to_owned());
        self.snap.header.status = self.active_status();
        Effects {
            changed: true,
            ..Effects::default()
        }
    }

    /// Text that streamed before the response was named belongs to it.
    fn adopt_unattributed_text(&mut self, id: &str) {
        let targets: Vec<usize> = self
            .snap
            .rows
            .iter()
            .enumerate()
            .filter(|(_, row)| {
                row.id.starts_with(LIVE_RESPONSE_PREFIX)
                    && row.is_streaming
                    && row.response_id.is_none()
            })
            .map(|(at, _)| at)
            .collect();
        for at in targets {
            if let Some(row) = self.row_mut(at) {
                row.response_id = Some(id.to_owned());
            }
        }
    }

    fn text_delta(&mut self, delta: &OutputTextDeltaEvent) -> Effects {
        let id = if let Some(message_id) = &delta.message_id {
            // Native message streams outlive the wrapper response that enqueued the turn.
            if !self.accepts_native_deltas
                || delta
                    .response_id
                    .as_ref()
                    .is_some_and(|response| self.ended_responses.contains(response))
                || self.retired_native.contains(message_id)
            {
                return Effects::default();
            }
            if let Some(index) = delta.index {
                if self
                    .native_indices
                    .get(message_id)
                    .is_some_and(|previous| index <= *previous)
                {
                    return Effects::default();
                }
                self.native_indices.insert(message_id.clone(), index);
            }
            format!("{LIVE_PREFIX}{message_id}")
        } else {
            if !self.accepts_response_deltas {
                return Effects::default();
            }
            let id = self.text_section_id();
            if !self.accepts_chunk(delta.index, &id) {
                return Effects::default();
            }
            id
        };
        self.close_reasoning_section();
        let position = self.position(&id);
        if let Some(at) = position {
            if let Some(row) = self.row_mut(at) {
                row.text.push_str(&delta.delta);
                row.is_streaming = true;
            }
        } else if !delta.delta.is_empty() {
            let mut row = Row::text(id.clone(), RowRole::Assistant, delta.delta.clone());
            row.is_streaming = true;
            row.response_id = if delta.message_id.is_some() {
                delta.response_id.clone()
            } else {
                self.response_id.clone()
            };
            self.push_row(row);
        }
        if delta.r#final == Some(true) {
            if let Some(at) = self.position(&id)
                && let Some(row) = self.row_mut(at)
            {
                row.is_streaming = false;
            }
            match &delta.message_id {
                Some(message_id) => {
                    self.retired_native.insert(message_id.clone());
                }
                None => self.segment += 1,
            }
        }
        self.snap.header.status = self.active_status();
        Effects {
            changed: true,
            ..Effects::default()
        }
    }

    /// Accepts a chunk `index` for `key` once; an absent index is always accepted.
    pub(super) fn accepts_chunk(&mut self, index: Option<u64>, key: &str) -> bool {
        let Some(index) = index else { return true };
        if self
            .activity_indices
            .get(key)
            .is_some_and(|previous| index <= *previous)
        {
            return false;
        }
        self.activity_indices.insert(key.to_owned(), index);
        true
    }

    fn commit_item(&mut self, mut item: ConversationItem) -> Result<Effects, ReducerError> {
        if item.response_id.is_none() {
            item.response_id.clone_from(&self.response_id);
        }
        let Some(row) = project_item(&item)? else {
            return Ok(self.mark_interrupted_reply(&item));
        };
        self.commit(row);
        Ok(Effects {
            changed: true,
            ..Effects::default()
        })
    }

    /// Inserts a persisted row: replaces the row with its id, else retires the one matching
    /// preview, else appends. A replayed old commit never consumes a newer preview.
    pub(super) fn commit(&mut self, row: Row) {
        if let Some(at) = self.position(&row.id) {
            self.replace_row(at, row);
            return;
        }
        let matching = self.snap.rows.iter().position(|preview| {
            self.matches_activity(preview, &row) || matches_text(preview, &row)
        });
        if let Some(at) = matching {
            if let Some(preview) = self.snap.rows.get(at).cloned() {
                self.retire_preview(&preview);
            }
            self.replace_row(at, row);
            return;
        }
        // A later commit of a tool call already shown keeps the row (and its id) in place.
        let earlier = self
            .snap
            .rows
            .iter()
            .position(|earlier| same_tool_call(earlier, &row));
        if let Some(at) = earlier {
            let mut row = row;
            if let Some(earlier) = self.snap.rows.get(at) {
                row.id.clone_from(&earlier.id);
            }
            self.replace_row(at, row);
        } else {
            self.push_row(row);
        }
    }

    /// Whether `committed` is the persisted form of the activity preview `preview`.
    pub(super) fn matches_activity(&self, preview: &Row, committed: &Row) -> bool {
        let (Some(first), Some(second)) = (&preview.activity, &committed.activity) else {
            return false;
        };
        if !preview.is_ephemeral() || first.kind != second.kind {
            return false;
        }
        if let (Some(lhs), Some(rhs)) = (&preview.response_id, &committed.response_id)
            && lhs != rhs
        {
            return false;
        }
        if let Some(source) = self.activity_item_ids.get(&preview.id) {
            return *source == committed.id;
        }
        if let Some(call) = &preview.call_id {
            return Some(call) == committed.call_id.as_ref();
        }
        match first.kind {
            ActivityKind::Reasoning => {
                let prefix = first.detail("summary").unwrap_or_default();
                let full = second.detail("summary").unwrap_or_default();
                prefix.is_empty()
                    || full.starts_with(prefix)
                    || (!full.is_empty() && prefix.starts_with(full))
            }
            ActivityKind::Compaction => first.status.as_deref() != Some("failed"),
            ActivityKind::Error => {
                let first_code = first.detail("code");
                let second_code = second.detail("code");
                first.summary == second.summary
                    && (first_code.is_none() || second_code.is_none() || first_code == second_code)
            }
            _ => false,
        }
    }

    /// Stops tracking a preview that a persisted row replaced.
    pub(super) fn retire_preview(&mut self, preview: &Row) {
        if preview.activity.is_some() {
            self.retired_activity.insert(preview.id.clone());
            self.activity_buffers.remove(&preview.id);
            if self.active_reasoning.as_deref() == Some(preview.id.as_str()) {
                self.active_reasoning = None;
                self.activity_sequence += 1;
            }
        } else if !preview.id.starts_with(LIVE_RESPONSE_PREFIX) {
            if let Some(message_id) = preview.id.strip_prefix(LIVE_PREFIX) {
                self.retired_native.insert(message_id.to_owned());
            }
        } else if preview.id == self.text_section_id() {
            self.segment += 1;
        }
    }

    pub(super) fn close_text_section(&mut self) {
        let id = self.text_section_id();
        if let Some(at) = self.position(&id) {
            if let Some(row) = self.row_mut(at) {
                row.is_streaming = false;
            }
            self.segment += 1;
        }
    }

    pub(super) fn close_reasoning_section(&mut self) {
        let Some(id) = self.active_reasoning.take() else {
            return;
        };
        if let Some(at) = self.position(&id)
            && let Some(row) = self.row_mut(at)
        {
            row.is_streaming = false;
            if let Some(activity) = &mut row.activity {
                activity.status = Some("completed".to_owned());
            }
        }
        self.activity_sequence += 1;
    }

    /// Ends every streaming row; activity rows take `status`. Native previews may keep
    /// streaming past a wrapper response's end.
    pub(super) fn seal_live_content(&mut self, status: &str, preserving_native_text: bool) {
        let targets: Vec<usize> = self
            .snap
            .rows
            .iter()
            .enumerate()
            .filter(|(_, row)| {
                row.is_streaming && !(preserving_native_text && is_native_preview(row))
            })
            .map(|(at, _)| at)
            .collect();
        for at in targets {
            if let Some(row) = self.row_mut(at) {
                row.is_streaming = false;
                if let Some(activity) = &mut row.activity {
                    activity.status = Some(status.to_owned());
                }
            }
        }
        if self.active_reasoning.take().is_some() {
            self.activity_sequence += 1;
        }
    }

    fn request_decision(&mut self, request: &ElicitationRequest) -> Effects {
        let decision = Decision::pending(request.clone(), &self.snap.header.id);
        let answered = self
            .snap
            .decisions
            .iter()
            .any(|known| known.id == decision.id && known.answered);
        if self.resolved_decisions.contains(&decision.id) || answered {
            return Effects::default();
        }
        self.snap.decisions.retain(|known| known.id != decision.id);
        self.snap.decisions.push(decision);
        self.snap.header.status = TurnStatus::NeedsResponse;
        Effects {
            changed: true,
            ..Effects::default()
        }
    }

    fn resolve_decision(&mut self, resolved: &ElicitationResolved) -> Effects {
        let id = &resolved.elicitation_id;
        self.resolved_decisions.insert(id.clone());
        if !self.snap.decisions.iter().any(|known| known.id == *id) {
            return Effects::default();
        }
        self.snap.decisions.retain(|known| known.id != *id);
        if !self.snap.has_pending_decisions() {
            self.snap.header.status = if self.accepts_response_deltas && self.response_id.is_some()
            {
                TurnStatus::Running
            } else {
                TurnStatus::Idle
            };
        }
        Effects {
            changed: true,
            reconcile: true,
            ..Effects::default()
        }
    }

    fn session_status(&mut self, event: &SessionStatusEvent) -> Effects {
        let reported = event.response_id.as_deref();
        let ends = matches!(event.status, SessionStatus::Idle | SessionStatus::Failed);
        if ends
            && let (Some(reported), Some(current)) = (reported, self.response_id.as_deref())
            && reported != current
        {
            return Effects::default();
        }
        let mut effects = Effects {
            changed: true,
            ..Effects::default()
        };
        match &event.status {
            SessionStatus::Running | SessionStatus::Waiting | SessionStatus::Launching => {
                if reported.is_some_and(|reported| self.ended_responses.contains(reported)) {
                    return Effects::default();
                }
                if let Some(reported) = reported
                    && self.response_id.as_deref() != Some(reported)
                {
                    self.seal_live_content("stopped", true);
                    if let Some(previous) = self.response_id.take() {
                        self.ended_responses.insert(previous);
                    }
                    self.response_id = Some(reported.to_owned());
                    self.segment = 0;
                    self.activity_sequence = 0;
                }
                if !self.accepts_response_deltas && reported.is_none() {
                    self.response_id = None;
                    self.segment += 1;
                }
                self.accepts_response_deltas = true;
                self.accepts_native_deltas = true;
                self.snap.header.status = TurnStatus::Running;
            }
            SessionStatus::Idle | SessionStatus::Failed => {
                self.snap.header.status = TurnStatus::Idle;
                let failed = event.status == SessionStatus::Failed;
                self.seal_live_content(if failed { "failed" } else { "completed" }, false);
                self.accepts_response_deltas = false;
                if let Some(id) = reported
                    .map(str::to_owned)
                    .or_else(|| self.response_id.clone())
                {
                    self.ended_responses.insert(id);
                }
                effects.reconcile = true;
            }
            SessionStatus::Unknown { .. } => return Effects::default(),
        }
        let state = self.state();
        state.status = Some(event.status.as_str().to_owned());
        // An explicit count is authoritative and carries its detail; a failure clears both,
        // since a dead session may never report the count again (web `chatStore`).
        if let Field::Present(count) = event.background_task_count {
            state.background_task_count = Some(count);
            state.background_tasks =
                Some(event.background_tasks.value().cloned().unwrap_or_default());
        } else if event.status == SessionStatus::Failed {
            state.background_task_count = Some(0);
            state.background_tasks = Some(Vec::new());
        }
        if self.snap.has_pending_decisions() {
            self.snap.header.status = TurnStatus::NeedsResponse;
        }
        if let Some(error) = &event.error {
            effects.error = Some(error.message.clone());
            self.present_error(&error.message, Some(&error.code), Some("execution"));
        }
        effects
    }

    fn end_lifecycle(&mut self, ending: Ending, event: &ResponseLifecycleEvent) -> Effects {
        self.end_response(ending, event.response_id(), event.response.as_ref(), None)
    }

    fn end_response(
        &mut self,
        ending: Ending,
        ended: Option<&str>,
        response: Option<&ResponseObject>,
        source: Option<&ErrorSource>,
    ) -> Effects {
        if let (Some(ended), Some(current)) = (ended, self.response_id.as_deref())
            && ended != current
        {
            return Effects::default();
        }
        self.observe_end(ending, response);
        self.accepts_response_deltas = false;
        if ending != Ending::Completed {
            self.accepts_native_deltas = false;
            let native: Vec<String> = self
                .snap
                .rows
                .iter()
                .filter(|row| is_native_preview(row))
                .filter_map(|row| row.id.strip_prefix(LIVE_PREFIX).map(str::to_owned))
                .collect();
            self.retired_native.extend(native);
        }
        if let Some(id) = ended
            .map(str::to_owned)
            .or_else(|| self.response_id.clone())
        {
            self.ended_responses.insert(id);
        }
        self.snap.header.status = self.idle_status();
        if matches!(ending, Ending::Cancelled | Ending::Interrupted) {
            self.mark_interrupted();
        }
        let completed = ending == Ending::Completed;
        self.seal_live_content(if completed { "completed" } else { "stopped" }, completed);
        if !self.snap.has_pending_decisions() && self.snap.rows.iter().any(|row| row.is_streaming) {
            self.snap.header.status = TurnStatus::Running;
        }
        let error = response.and_then(|response| response.error.as_ref());
        let mut message = error.map(|error| error.message.clone());
        if ending == Ending::Incomplete && message.is_none() {
            message = response
                .and_then(|response| response.incomplete_details.as_ref())
                .map(|details| details.reason.clone());
        }
        if let Some(message) = &message {
            let code = error.map(|error| error.code.as_str());
            self.present_error(message, code, source.map(ErrorSource::as_str));
        }
        Effects {
            changed: true,
            reconcile: true,
            error: message,
            ..Effects::default()
        }
    }

    /// For an interrupt marker, marks the reply it cut off (see [`interrupted_reply`]); any
    /// other hidden item changes nothing.
    fn mark_interrupted_reply(&mut self, item: &ConversationItem) -> Effects {
        if !item.is_interrupt_marker() {
            return Effects::default();
        }
        let Some(at) = interrupted_reply(&self.snap.rows) else {
            return Effects::default();
        };
        if self.snap.rows.get(at).is_some_and(|row| row.interrupted) {
            return Effects::default();
        }
        if let Some(row) = self.row_mut(at) {
            row.interrupted = true;
        }
        Effects {
            changed: true,
            ..Effects::default()
        }
    }

    fn mark_interrupted(&mut self) {
        let response = self.response_id.clone();
        let target = self.snap.rows.iter().rposition(|row| {
            row.role == RowRole::Assistant
                && (row.is_streaming || (response.is_some() && row.response_id == response))
        });
        if let Some(at) = target
            && let Some(row) = self.row_mut(at)
        {
            row.interrupted = true;
        }
    }

    fn observe_end(&mut self, ending: Ending, response: Option<&ResponseObject>) {
        let state = self.state();
        state.status = Some(ending.label().to_owned());
        let tokens = response
            .and_then(|response| response.usage.as_ref())
            .and_then(|usage| usage.context_tokens.or(usage.total_tokens));
        if let Some(tokens) = tokens {
            state.context_tokens = Some(tokens);
        }
    }
}

/// A native text preview (`live:<message_id>`), not a response segment or an activity.
pub(super) fn is_native_preview(row: &Row) -> bool {
    row.id.starts_with(LIVE_PREFIX)
        && !row.id.starts_with(LIVE_RESPONSE_PREFIX)
        && row.activity.is_none()
}

/// Whether `committed` is a later commit of the same tool call as the committed row `earlier`.
///
/// The live stream commits a function call once in progress and again when completed, under
/// provider item ids that differ from each other and from the persisted ids (see
/// `sse/recorded-turn-text-tool-completion.jsonl`); the call id and response identify it.
pub(super) fn same_tool_call(earlier: &Row, committed: &Row) -> bool {
    let tool = |row: &Row| {
        matches!(
            row.activity_kind(),
            Some(ActivityKind::ToolCall | ActivityKind::ToolResult | ActivityKind::NativeTool)
        )
    };
    !earlier.is_ephemeral()
        && tool(earlier)
        && earlier.activity_kind() == committed.activity_kind()
        && earlier.call_id.is_some()
        && earlier.call_id == committed.call_id
        && earlier.response_id.is_some()
        && earlier.response_id == committed.response_id
}

/// Whether `committed` is the persisted form of the text preview `preview`.
pub(super) fn matches_text(preview: &Row, committed: &Row) -> bool {
    if !preview.id.starts_with(LIVE_PREFIX)
        || preview.role != RowRole::Assistant
        || preview.activity.is_some()
        || committed.role != RowRole::Assistant
        || committed.activity.is_some()
    {
        return false;
    }
    if let (Some(first), Some(second)) = (&preview.response_id, &committed.response_id)
        && first != second
    {
        return false;
    }
    if preview.id.strip_prefix(LIVE_PREFIX) == Some(committed.id.as_str()) {
        return true;
    }
    if preview.text.is_empty() || committed.text.is_empty() {
        return false;
    }
    committed.text.starts_with(&preview.text) || preview.text.starts_with(&committed.text)
}

fn value_str<'a>(value: &'a Value, path: &[&str]) -> Option<&'a str> {
    path.iter()
        .try_fold(value, |value, key| value.get(*key))
        .and_then(Value::as_str)
}

/// The session an event is scoped to, when it names one.
pub(super) fn event_scope(event: &ServerStreamEvent) -> Option<&str> {
    use ServerStreamEvent as E;
    match event {
        E::SessionStatus(e) => e.conversation_id.as_deref(),
        E::SessionUsage(e) => e.conversation_id.as_deref(),
        E::SessionModel(e) => e.conversation_id.as_deref(),
        E::SessionTitle(e) => e.conversation_id.as_deref(),
        E::SessionReasoningEffort(e) => e.conversation_id.as_deref(),
        E::SessionCollaborationMode(e) => e.conversation_id.as_deref(),
        E::SessionPermissionMode(e) => e.conversation_id.as_deref(),
        E::SessionCodexApprovalMode(e) => e.conversation_id.as_deref(),
        E::SessionAgentChanged(e) => e.conversation_id.as_deref(),
        E::SessionTodos(e) => e.conversation_id.as_deref(),
        E::SessionTerminalPending(e) => e.conversation_id.as_deref(),
        E::SessionSandboxStatus(e) => e.conversation_id.as_deref(),
        E::SessionMcpStartup(e) => e.conversation_id.as_deref(),
        E::SessionModelOptions(e) => e.conversation_id.as_deref(),
        E::SessionCreated(e) => e.conversation_id.as_deref(),
        E::SessionSuperseded(e) => e.conversation_id.as_deref(),
        E::SessionBtwSidechat(e) => e.conversation_id.as_deref(),
        E::SessionPresence(e) => e.conversation_id.as_deref(),
        E::SessionChildSessionUpdated(e) => e.conversation_id.as_deref(),
        E::PolicyDenied(e) => e.conversation_id.as_deref(),
        E::SessionResourceDeleted(e) => e.session_id.as_deref(),
        E::SessionChangedFilesInvalidated(e) => e.session_id.as_deref(),
        E::SessionTerminalActivity(e) => e.session_id.as_deref(),
        E::TurnStarted(e) | E::TurnCompleted(e) | E::TurnCancelled(e) => e.session_id.as_deref(),
        E::TurnFailed(e) => e.session_id.as_deref(),
        E::Unknown { raw, .. } => {
            value_str(raw, &["conversation_id"]).or_else(|| value_str(raw, &["session_id"]))
        }
        _ => None,
    }
}

/// The response an event names, if any.
pub(super) fn event_response_id(event: &ServerStreamEvent) -> Option<&str> {
    use ServerStreamEvent as E;
    match event {
        E::OutputTextDelta(e) => e.response_id.as_deref(),
        E::ReasoningTextDelta(e) | E::ReasoningSummaryTextDelta(e) => e.response_id.as_deref(),
        E::ResponseCreated(e)
        | E::ResponseQueued(e)
        | E::ResponseInProgress(e)
        | E::ResponseCompleted(e)
        | E::ResponseCancelled(e)
        | E::ResponseIncomplete(e) => e.response_id(),
        E::ResponseFailed(e) => e.response_id(),
        E::SessionInterrupted(e) => e.response_id(),
        E::Unknown { raw, .. } => value_str(raw, &["response_id"])
            .or_else(|| value_str(raw, &["response", "id"]))
            .or_else(|| value_str(raw, &["data", "response_id"])),
        _ => None,
    }
}
