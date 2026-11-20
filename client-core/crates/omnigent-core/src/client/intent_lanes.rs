//! Sends list-row edits through the [`IntentLedger`](crate::intents::IntentLedger): the row
//! shows an edit when it is made, the write leaves on its session's lane, and the row goes back
//! when the server refuses.
//!
//! A [`Lane`] is one caller's place on its session's lane. Dropping it before its write settled
//! takes the edit back, so an early return or a cancelled call cannot leave a row showing
//! something the server never got.

use std::future::poll_fn;
use std::task::Poll;

use futures::future::join_all;

use super::families::{BatchRoute, batch_routes, family_changed_by, nested_member_refusal};
use super::requests::{FailedWrite, acknowledgement, refused_write};
use super::sessions::{EditRequest, SessionChange, decode_snapshot_value, edit_request};
use super::{ClientCore, ClientEvent, SessionError, State, lock};
use crate::http::{HttpResponse, HttpTransport};
use crate::intents::{
    Begun, Departure, IntentId, IntentTimer, IntentTimerKind, SessionPatch, Turn, WritePolicy,
};
use crate::realtime::ConnectionState;
use crate::sessions::SessionSummary;

/// One caller's place on a session's lane.
pub(super) struct Lane<'core, T: HttpTransport> {
    core: &'core ClientCore<T>,
    scope: String,
    session_id: String,
    intent: IntentId,
    policy: WritePolicy,
    /// How long it masks its field once the server accepts it.
    hold: IntentTimerKind,
    /// The intent no longer needs taking back: it was accepted, replaced, or left the ledger.
    settled: bool,
}

/// How a lane's write ended without an error.
pub(super) enum Sent<R> {
    /// The server answered.
    Answered(R),
    /// A later edit of the same field replaced this one before it left; the row as that one
    /// left it. Nothing was sent.
    Superseded(Box<SessionSummary>),
}

/// What recording an intent came to.
pub(super) enum Step<'core, T: HttpTransport> {
    /// Send its write on the lane.
    Send(Lane<'core, T>),
    /// It only undid an edit that had not left yet: nothing to send. The row as it now shows.
    Unneeded(Box<SessionSummary>),
}

/// A validated edit with its intent recorded.
pub(super) struct PlannedEdit<'core, T: HttpTransport> {
    request: EditRequest,
    step: Step<'core, T>,
    /// The session family whose other members the write changes, read again once it is done.
    family: Option<String>,
    /// The same change shown on those members while the write is out (a representative's
    /// move); the server makes it with the write.
    carried: Vec<Lane<'core, T>>,
}

impl<T: HttpTransport> Drop for Lane<'_, T> {
    fn drop(&mut self) {
        if self.settled {
            return;
        }
        {
            let mut state = lock(&self.core.state);
            if state
                .intents
                .abandon(&self.scope, &self.session_id, self.intent)
            {
                state.republish(&self.scope, &self.session_id);
            }
        }
        self.core.dispatch();
    }
}

impl<T: HttpTransport> Lane<'_, T> {
    /// Waits for this intent's turn, then runs `write`; `write` is told whether this is the
    /// second attempt. A [`WritePolicy::Replayable`] write lost with the link runs once more
    /// when the link returns.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn send<R, Write>(
        &mut self,
        write: impl Fn(bool) -> Write,
    ) -> Result<Sent<R>, SessionError>
    where
        Write: Future<Output = Result<R, FailedWrite>>,
    {
        let mut lost: Option<SessionError> = None;
        loop {
            let departure = poll_fn(|context| {
                let turn = lock(&self.core.state).intents.turn(
                    &self.scope,
                    &self.session_id,
                    self.intent,
                    context.waker(),
                );
                match turn {
                    Turn::Go => Poll::Ready(None),
                    Turn::Left(departure) => Poll::Ready(Some(departure)),
                    Turn::Wait => Poll::Pending,
                }
            })
            .await;
            if let Some(departure) = departure {
                self.settled = true;
                return match departure {
                    Departure::Superseded(row) => Ok(Sent::Superseded(row)),
                    Departure::Gone => Err(SessionError::SessionNotFound {
                        session_id: self.session_id.clone(),
                    }),
                    Departure::GaveUp => Err(lost.unwrap_or(SessionError::Offline)),
                };
            }
            let link_returns = {
                let state = lock(&self.core.state);
                if state.scope_id().as_deref() != Some(self.scope.as_str()) {
                    return Err(SessionError::NotConnected);
                }
                state.link_returns
            };
            let failed = match write(lost.is_some()).await {
                Ok(answer) => return Ok(Sent::Answered(answer)),
                Err(failed) => failed,
            };
            let again = failed.link_lost
                && self.policy == WritePolicy::Replayable
                && lost.is_none()
                && self.awaits_link(link_returns);
            if !again {
                return Err(failed.error);
            }
            lost = Some(failed.error);
        }
    }

    /// The write was lost with the link: whether it goes again. It does not when the host
    /// never reported its link, since nothing would say the link is back. Unless the link has
    /// returned since the write began, the intent waits for it, as long as the host's timer
    /// allows.
    fn awaits_link(&self, link_returns_before: u64) -> bool {
        {
            let mut state = lock(&self.core.state);
            if !state.link_watched {
                return false;
            }
            if state.link_returns == link_returns_before
                && state
                    .intents
                    .mark_unclear(&self.scope, &self.session_id, self.intent)
            {
                state.events.push(ClientEvent::IntentTimerRequested {
                    timer: IntentTimer {
                        intent: self.intent,
                        kind: IntentTimerKind::Unclear,
                    },
                });
            }
        }
        self.core.dispatch();
        true
    }

    /// Settles a change carried by another session's accepted write: confirmed with the
    /// member's row read again, else with the row as it shows (the server made the change with
    /// that write). A carried intent never takes a turn, so a departure is cleared here.
    fn settle_carried(&mut self, state: &mut State, read: Option<&SessionSummary>) {
        let shown = read.cloned().or_else(|| {
            state
                .summaries
                .get(&self.session_id)
                .map(|row| state.intents.overlay(&self.scope, row))
        });
        if let Some(row) = shown {
            self.confirm(state, &row);
        }
        self.settled = true;
        state
            .intents
            .abandon(&self.scope, &self.session_id, self.intent);
    }

    /// The server accepted the write and answered with `answered`. When that says what was
    /// asked, the intent masks its field until a later server row agrees or the host's timer
    /// ends the hold.
    fn confirm(&mut self, state: &mut State, answered: &SessionSummary) {
        self.settled = true;
        if state
            .intents
            .confirm(&self.scope, &self.session_id, self.intent, answered)
        {
            state.events.push(ClientEvent::IntentTimerRequested {
                timer: IntentTimer {
                    intent: self.intent,
                    kind: self.hold,
                },
            });
        }
    }
}

impl State {
    /// What the list shows for the server rows `rows`: each with its session's pending edits
    /// applied, without the rows a pending delete or leave hides.
    pub(super) fn shown_rows(&self, rows: Vec<SessionSummary>) -> Vec<SessionSummary> {
        if self.intents.is_empty() {
            return rows;
        }
        let Some(scope) = self.scope_id() else {
            return rows;
        };
        rows.iter()
            .filter_map(|row| self.intents.project(&scope, row))
            .collect()
    }

    /// Queues the list change that shows `session_id`'s row as it stands now, when `scope` is
    /// still the connected one and the row is cached.
    pub(super) fn republish(&mut self, scope: &str, session_id: &str) {
        if self.scope_id().as_deref() != Some(scope) {
            return;
        }
        if let Some(row) = self.summaries.get(session_id).cloned() {
            self.events.push(ClientEvent::SessionsChanged {
                sessions: vec![row],
            });
        }
    }

    /// A server row from a list read or the updates stream: accepted edits it agrees with stop
    /// masking their field.
    pub(super) fn settle_intents(&mut self, row: &SessionSummary) {
        if self.intents.is_empty() {
            return;
        }
        if let Some(scope) = self.scope_id() {
            self.intents.settle(&scope, row);
        }
    }

    /// The session left the server: its pending edits go with it.
    pub(super) fn drop_intents(&mut self, session_id: &str) {
        if self.intents.is_empty() {
            return;
        }
        if let Some(scope) = self.scope_id() {
            self.intents.drop_session(&scope, session_id);
        }
    }

    /// The delivery scope a list-row edit is recorded under, refusing the edit while the host
    /// reports its live link down: nothing is sent or kept for later.
    fn edit_scope(&self) -> Result<String, SessionError> {
        let scope = self.scope()?;
        if self.link_down {
            return Err(SessionError::Offline);
        }
        Ok(scope)
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// The host's live link to the server (the session updates socket) changed state. A link
    /// that dropped before it proved healthy, failed to reconnect, or cannot reconnect refuses
    /// list-row edits until it is live again; a live link sends the edits whose writes were
    /// lost with it once more.
    pub fn updates_link_changed(&self, link: &ConnectionState) {
        {
            let mut state = lock(&self.state);
            state.link_watched = true;
            match link {
                ConnectionState::Live => {
                    state.link_down = false;
                    state.link_returns = state.link_returns.wrapping_add(1);
                    state.intents.link_returned();
                }
                ConnectionState::Reconnecting { failures, .. } if *failures > 0 => {
                    state.link_down = true;
                }
                ConnectionState::Failed { .. } => state.link_down = true,
                ConnectionState::Idle
                | ConnectionState::Connecting
                | ConnectionState::Reconnecting { .. }
                | ConnectionState::Closed
                | ConnectionState::Stopped => {}
            }
        }
        self.dispatch();
    }

    /// A timer asked for with [`ClientEvent::IntentTimerRequested`] fired: the hold on an
    /// accepted edit ends, or an edit still waiting for the link gives up and its row goes
    /// back. A timer whose intent has moved on does nothing.
    pub fn intent_timer_elapsed(&self, timer: IntentTimer) {
        {
            let mut state = lock(&self.state);
            let ended = state.intents.patch(timer.intent).cloned();
            if let Some((scope, session_id)) = state.intents.timer_elapsed(timer) {
                // A mute that outranked disagreeing server rows: the list is read again, since a
                // change made elsewhere meanwhile was masked.
                let masked = timer.kind == IntentTimerKind::ReindexHold
                    && ended
                        .zip(state.summaries.get(&session_id))
                        .is_some_and(|(patch, row)| !patch.agrees_with(row));
                if masked {
                    state.events.push(ClientEvent::InventoryInvalidated);
                }
                state.republish(&scope, &session_id);
            }
        }
        self.dispatch();
    }

    /// Runs `plan` on the locked state, then publishes the server rows it collected as one
    /// list change: the rows show with their new intents applied before any write leaves.
    fn plan<R>(&self, plan: impl FnOnce(&mut State, &mut Vec<SessionSummary>) -> R) -> R {
        let planned;
        {
            let mut state = lock(&self.state);
            let mut shown = Vec::new();
            planned = plan(&mut state, &mut shown);
            if !shown.is_empty() {
                state
                    .events
                    .push(ClientEvent::SessionsChanged { sessions: shown });
            }
        }
        self.dispatch();
        planned
    }

    /// Records the intent to apply `patch` to `session_id`.
    fn begin(
        &self,
        state: &mut State,
        session_id: &str,
        patch: SessionPatch,
        policy: WritePolicy,
    ) -> Result<Step<'_, T>, SessionError> {
        let scope = state.edit_scope()?;
        Ok(self.begin_in(state, scope, session_id, patch, policy))
    }

    /// [`Self::begin`] in a delivery scope already checked.
    fn begin_in(
        &self,
        state: &mut State,
        scope: String,
        session_id: &str,
        patch: SessionPatch,
        policy: WritePolicy,
    ) -> Step<'_, T> {
        let base = state.summaries.get(session_id);
        let hold = patch.hold();
        match state.intents.begin(&scope, session_id, patch, base) {
            Begun::Recorded(intent) => Step::Send(Lane {
                core: self,
                scope,
                session_id: session_id.to_owned(),
                intent,
                policy,
                hold,
                settled: false,
            }),
            Begun::Unneeded(row) => Step::Unneeded(row),
        }
    }

    fn plan_edit(
        &self,
        state: &mut State,
        session_id: &str,
        change: SessionChange,
        shown: &mut Vec<SessionSummary>,
    ) -> Result<PlannedEdit<'_, T>, SessionError> {
        let cached = state.summaries.get(session_id);
        let family = family_changed_by(&change, cached);
        let request = edit_request(session_id, change, cached)?;
        let step = self.begin(
            state,
            session_id,
            request.patch.clone(),
            WritePolicy::Replayable,
        )?;
        shown.extend(state.summaries.get(session_id).cloned());
        let mut carried = Vec::new();
        if let SessionPatch::Project(_) = &request.patch
            && let Some(family_id) = &family
            && let Some(scope) = state.scope_id()
        {
            for member in state.family_members(family_id, session_id) {
                let patch = request.patch.clone();
                let policy = WritePolicy::Replayable;
                let step = self.begin_in(state, scope.clone(), &member, patch, policy);
                if let Step::Send(lane) = step {
                    carried.push(lane);
                }
                shown.extend(state.summaries.get(&member).cloned());
            }
        }
        Ok(PlannedEdit {
            request,
            step,
            family,
            carried,
        })
    }

    /// Validates and records each edit, showing them all in one list change. No request is
    /// made; [`Self::run_edit`] sends one.
    pub(super) fn plan_edits(
        &self,
        edits: Vec<(String, SessionChange)>,
    ) -> Vec<Result<PlannedEdit<'_, T>, SessionError>> {
        self.plan(|state, shown| {
            edits
                .into_iter()
                .map(|(session_id, change)| self.plan_edit(state, &session_id, change, shown))
                .collect()
        })
    }

    /// Validates, records and shows one edit, then sends it.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn edit(
        &self,
        session_id: &str,
        change: SessionChange,
    ) -> Result<SessionSummary, SessionError> {
        let planned = self.plan(|state, shown| self.plan_edit(state, session_id, change, shown))?;
        self.run_edit(planned).await
    }

    /// Sends a planned edit's `PATCH /v1/sessions/{id}` when its session's lane is free and
    /// records the answer. Returns the row as the list shows it.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn run_edit(
        &self,
        planned: PlannedEdit<'_, T>,
    ) -> Result<SessionSummary, SessionError> {
        let PlannedEdit {
            request,
            step,
            family,
            mut carried,
        } = planned;
        let mut lane = match step {
            Step::Send(lane) => lane,
            Step::Unneeded(row) => return Ok(*row),
        };
        let session_id = request.session_id.as_str();
        let path = format!("/v1/sessions/{session_id}");
        let (route, body) = (path.as_str(), &request.body);
        let write = move |_retried: bool| async move {
            let prepared = self.prepare("PATCH", route, &[], Some(body))?;
            let epoch = lock(&self.state).metadata_epoch(session_id);
            let response: HttpResponse = self.write_or_lose(prepared).await?;
            Ok::<_, FailedWrite>((response, epoch))
        };
        let sent = lane.send(write).await.map_err(|error| match error {
            SessionError::Rejected { status: 404, .. } if request.names_project => error,
            other => refused_write(session_id)(other),
        })?;
        let (response, epoch) = match sent {
            Sent::Answered(answer) => answer,
            Sent::Superseded(row) => return Ok(*row),
        };
        let decoded =
            decode_snapshot_value(acknowledgement(&path, &response)?).map_err(|detail| {
                SessionError::DeliveryUncertain {
                    detail: format!("unreadable {path} acknowledgement: {detail}"),
                }
            })?;
        let shown = {
            let mut state = lock(&self.state);
            let updated = state.accept_projection(&decoded.projection, epoch)?;
            lane.confirm(&mut state, &updated);
            state.events.push(ClientEvent::SessionsChanged {
                sessions: vec![updated.clone()],
            });
            state.request_rehydration(session_id);
            state.intents.overlay(&lane.scope, &updated)
        };
        if let Some(family_id) = family {
            let refreshed = self.refresh_family(&family_id, session_id).await;
            let mut state = lock(&self.state);
            for member in &mut carried {
                let read = refreshed.get(&member.session_id);
                member.settle_carried(&mut state, read);
            }
        }
        Ok(shown)
    }

    /// Edits several sessions at once: the rows all change in one list change, then each
    /// session's `PATCH` runs beside the others. One result per edit, in the order given; a
    /// refused edit puts its own row back and leaves the others alone. A nested family member's
    /// move rides on its representative's move in the same batch; when one is moved without its
    /// representative, every move of the batch is refused before any request.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn edit_sessions(
        &self,
        edits: Vec<(String, SessionChange)>,
    ) -> Vec<Result<SessionSummary, SessionError>> {
        let routes = {
            let state = lock(&self.state);
            batch_routes(&edits, |id| state.summaries.get(id).cloned())
        };
        let ids: Vec<String> = edits.iter().map(|(id, _)| id.clone()).collect();
        let sendable = edits
            .into_iter()
            .zip(&routes)
            .filter(|(_, route)| **route == BatchRoute::Send)
            .map(|(edit, _)| edit)
            .collect();
        let planned = self.plan_edits(sendable);
        let mut answers = join_all(planned.into_iter().map(|planned| async move {
            let result = self.run_edit(planned?).await;
            self.dispatch();
            result
        }))
        .await
        .into_iter();
        let sent: Vec<Option<Result<SessionSummary, SessionError>>> = routes
            .iter()
            .map(|route| {
                (*route == BatchRoute::Send)
                    .then(|| answers.next())
                    .flatten()
            })
            .collect();
        routes
            .iter()
            .zip(&ids)
            .zip(&sent)
            .map(|((route, session_id), answer)| match (route, answer) {
                (_, Some(answer)) => answer.clone(),
                // A carried move reports its representative's outcome, with its own row.
                (BatchRoute::CarriedBy(representative), None) => match sent.get(*representative) {
                    Some(Some(Err(error))) => Err(error.clone()),
                    _ => self.shown_row(session_id),
                },
                _ => Err(nested_member_refusal()),
            })
            .collect()
    }

    /// The row of `session_id` as the list shows it, pending edits applied.
    fn shown_row(&self, session_id: &str) -> Result<SessionSummary, SessionError> {
        let state = lock(&self.state);
        state
            .summaries
            .get(session_id)
            .cloned()
            .and_then(|row| state.shown_rows(vec![row]).pop())
            .ok_or_else(|| SessionError::SessionNotFound {
                session_id: session_id.to_owned(),
            })
    }

    /// Hides `session_id`'s row at once, ahead of the `DELETE` that removes it for the caller.
    /// Dropping the result brings the row back.
    pub(super) fn hide_row(&self, session_id: &str) -> Result<Step<'_, T>, SessionError> {
        self.plan(|state, _| {
            let step = self.begin(
                state,
                session_id,
                SessionPatch::Removed,
                WritePolicy::Replayable,
            )?;
            if state.summaries.contains_key(session_id) {
                state.events.push(ClientEvent::SessionsRemoved {
                    ids: vec![session_id.to_owned()],
                });
            }
            Ok(step)
        })
    }

    /// Sends the `DELETE` for a row hidden by [`Self::hide_row`] when its session's lane is
    /// free, and forgets the session once the server has. A `404` to the second attempt means
    /// the first one did it. The row comes back when the server refuses.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn remove_hidden(
        &self,
        hidden: Step<'_, T>,
        path: &str,
        query: &[(&'static str, String)],
    ) -> Result<(), SessionError> {
        let Step::Send(mut lane) = hidden else {
            return Ok(());
        };
        let delete = move |retried: bool| async move {
            let prepared = self.prepare("DELETE", path, query, None)?;
            match self.write_or_lose(prepared).await {
                Err(failed) if retried && failed.is_not_found() => Ok(()),
                other => other.map(|_| ()),
            }
        };
        if matches!(lane.send(delete).await?, Sent::Answered(())) {
            lane.settled = true;
            self.forget(&lane.session_id);
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "intent_lanes_tests.rs"]
mod tests;
