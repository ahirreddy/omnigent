//! Intent ledger for edits to a session's list row that show before the server answers.
//!
//! The server owns every list row. An intent is one user action on a row (rename, pin, archive,
//! move to a project, remove) that has not settled yet. The ledger keeps them per delivery scope
//! (server plus account) and session, as [`crate::ledger::SubmissionLedger`] keeps sends, and
//! answers one question: what should the list show for this row now ([`IntentLedger::project`]).
//!
//! Each session has one lane. Its intents leave in the order they were made, one at a time. An
//! intent still waiting for its turn is replaced by a later one for the same field, and the pair
//! is dropped without a request when the later one puts the field back. An accepted intent is
//! held for a short time so an older list row arriving late cannot undo it on screen.
//!
//! The ledger does no I/O and reads no clock: the client asks its host for the two timers
//! ([`IntentTimer`]) and reports when the link returns.

use std::collections::BTreeMap;
use std::mem::discriminant;
use std::task::Waker;

use crate::sessions::SessionSummary;

/// How long an accepted intent keeps masking its field: three of the list socket's 4 s rescans.
pub const INTENT_HOLD_MS: u64 = 12_000;

/// How long an intent whose write was lost with the link waits for the link to return.
pub const UNCLEAR_INTENT_LIMIT_MS: u64 = 30_000;

/// Identifies one intent. Ids are unique within one ledger.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct IntentId(u64);

impl IntentId {
    /// The raw id, for logging and FFI mirrors.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

/// A change to one field of a session's list row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionPatch {
    /// The title.
    Title(String),
    /// The pin's sort key, or `None` for unpinned.
    Pin(Option<String>),
    /// Archived or restored. Archiving also unpins, as the server does.
    Archived(bool),
    /// The project it is filed in, or `None` for no project.
    Project(Option<String>),
    /// The row leaves the list (deleted, or left by the caller).
    Removed,
}

impl SessionPatch {
    fn same_field(&self, other: &Self) -> bool {
        discriminant(self) == discriminant(other)
    }

    /// Writes the change onto `row`. [`Self::Removed`] changes no field: a removed row is
    /// hidden, see [`IntentLedger::project`].
    pub fn apply(&self, row: &mut SessionSummary) {
        match self {
            Self::Title(title) => row.title.clone_from(title),
            Self::Pin(stamp) => {
                row.is_pinned = stamp.is_some();
                row.pin_stamp.clone_from(stamp);
            }
            Self::Archived(archived) => {
                row.is_archived = *archived;
                if *archived {
                    row.is_pinned = false;
                    row.pin_stamp = None;
                }
            }
            Self::Project(project_id) => {
                row.project_id.clone_from(project_id);
                row.project_label = None;
            }
            Self::Removed => {}
        }
    }

    /// Whether `row` already says what this change asks for, so applying it changes nothing.
    /// A removed row never does.
    #[must_use]
    pub fn agrees_with(&self, row: &SessionSummary) -> bool {
        match self {
            Self::Title(title) => row.title == *title,
            Self::Pin(stamp) => row.pin_stamp == *stamp,
            Self::Archived(archived) => {
                row.is_archived == *archived && !(*archived && row.is_pinned)
            }
            Self::Project(project_id) => {
                row.project_id == *project_id && row.project_label.is_none()
            }
            Self::Removed => false,
        }
    }
}

/// Whether a write may be sent a second time.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WritePolicy {
    /// Sending it twice ends in the same state (a metadata `PATCH`, or a `DELETE` whose `404`
    /// means done): it is sent once more after the link returns.
    Replayable,
    /// Never sent again.
    AtMostOnce,
}

/// Where an intent is in its life.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum IntentState {
    /// Waiting for the intents ahead of it on the session's lane.
    Queued,
    /// Its write is with the server.
    InFlight,
    /// Its write was lost with the link; it goes again when the link returns.
    Unclear,
    /// The server accepted it; it masks its field until a server row agrees or the hold ends.
    Held,
}

/// Why an intent left the ledger before its caller sent it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Departure {
    /// A later intent for the same field replaced it; the row as the later one left it.
    Superseded(Box<SessionSummary>),
    /// The session was removed.
    Gone,
    /// The link did not return in time.
    GaveUp,
}

/// What [`IntentLedger::turn`] tells the caller of an intent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Turn {
    /// Send the write now.
    Go,
    /// Not yet; the waker fires when that may have changed.
    Wait,
    /// The intent is no longer in the ledger.
    Left(Departure),
}

/// What [`IntentLedger::begin`] did with a new intent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Begun {
    /// Recorded; the caller sends its write when [`IntentLedger::turn`] says so.
    Recorded(IntentId),
    /// It put the field back to what the row said before a queued intent, so both were dropped
    /// and there is nothing to send. Carries the row as it now shows.
    Unneeded(Box<SessionSummary>),
}

/// Which of the host's two timers an intent needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum IntentTimerKind {
    /// The hold after an accepted write.
    Hold,
    /// The wait for the link to return after a lost write.
    Unclear,
}

/// A timer the host runs for one intent; when it fires the host reports it back.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct IntentTimer {
    /// The intent.
    pub intent: IntentId,
    /// Which wait it bounds.
    pub kind: IntentTimerKind,
}

impl IntentTimer {
    /// How long to wait before reporting the timer back.
    #[must_use]
    pub const fn delay_ms(self) -> u64 {
        match self.kind {
            IntentTimerKind::Hold => INTENT_HOLD_MS,
            IntentTimerKind::Unclear => UNCLEAR_INTENT_LIMIT_MS,
        }
    }
}

#[derive(Debug)]
struct SessionIntent {
    id: IntentId,
    patch: SessionPatch,
    state: IntentState,
    /// Wakes the caller waiting for its turn.
    waker: Option<Waker>,
}

impl SessionIntent {
    /// Still owed a write: a later intent for the same session waits behind it.
    fn is_active(&self) -> bool {
        self.state != IntentState::Held
    }

    fn wake(&mut self) {
        if let Some(waker) = self.waker.take() {
            waker.wake();
        }
    }
}

type Lane = Vec<SessionIntent>;

/// Pending list-row intents, keyed by scope and then session.
#[derive(Debug, Default)]
pub struct IntentLedger {
    next_id: u64,
    lanes: BTreeMap<String, BTreeMap<String, Lane>>,
    /// Intents that left while their caller was waiting, until the caller reads why.
    departed: BTreeMap<IntentId, Departure>,
}

fn wake_all(lane: &mut Lane) {
    for intent in lane {
        intent.wake();
    }
}

fn overlay(lane: &[SessionIntent], base: &SessionSummary) -> SessionSummary {
    let mut row = base.clone();
    for intent in lane {
        intent.patch.apply(&mut row);
    }
    row
}

impl IntentLedger {
    /// An empty ledger.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Whether no intent is pending or held.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.lanes.is_empty()
    }

    fn lane(&self, scope: &str, session_id: &str) -> Option<&Lane> {
        self.lanes.get(scope)?.get(session_id)
    }

    fn lane_mut(&mut self, scope: &str, session_id: &str) -> Option<&mut Lane> {
        self.lanes.get_mut(scope)?.get_mut(session_id)
    }

    /// Drops the lanes and scopes left empty, so [`Self::is_empty`] stays cheap.
    fn prune(&mut self) {
        self.lanes.retain(|_, sessions| {
            sessions.retain(|_, lane| !lane.is_empty());
            !sessions.is_empty()
        });
    }

    /// Records the intent to apply `patch` to the session whose server row is `base`.
    ///
    /// A queued intent for the same field is replaced: its caller is told
    /// [`Departure::Superseded`]. When `patch` only puts the field back to what the row said
    /// before that queued intent, both are dropped ([`Begun::Unneeded`]).
    pub fn begin(
        &mut self,
        scope: &str,
        session_id: &str,
        patch: SessionPatch,
        base: Option<&SessionSummary>,
    ) -> Begun {
        let lane = self
            .lanes
            .entry(scope.to_owned())
            .or_default()
            .entry(session_id.to_owned())
            .or_default();
        let queued = lane.iter().position(|intent| {
            intent.state == IntentState::Queued && intent.patch.same_field(&patch)
        });
        let mut unneeded = None;
        if let (Some(index), Some(base)) = (queued, base) {
            let mut replaced = lane.remove(index);
            replaced.wake();
            let restores = patch.agrees_with(&overlay(lane.get(..index).unwrap_or_default(), base));
            let id = replaced.id;
            if restores {
                let row = Box::new(overlay(lane, base));
                unneeded = Some(row.clone());
                self.departed.insert(id, Departure::Superseded(row));
            } else {
                let mut row = overlay(lane, base);
                patch.apply(&mut row);
                self.departed
                    .insert(id, Departure::Superseded(Box::new(row)));
            }
        }
        if let Some(row) = unneeded {
            self.prune();
            return Begun::Unneeded(row);
        }
        let id = IntentId(self.next_id);
        self.next_id = self.next_id.wrapping_add(1);
        if let Some(lane) = self.lane_mut(scope, session_id) {
            lane.push(SessionIntent {
                id,
                patch,
                state: IntentState::Queued,
                waker: None,
            });
        }
        Begun::Recorded(id)
    }

    /// Whether the caller of `id` may send its write: it is first among the session's intents
    /// still owed one, or the link returned after its write was lost. Otherwise `waker` is kept
    /// and fired when that may have changed.
    pub fn turn(&mut self, scope: &str, session_id: &str, id: IntentId, waker: &Waker) -> Turn {
        if let Some(departure) = self.departed.remove(&id) {
            return Turn::Left(departure);
        }
        let Some(lane) = self.lane_mut(scope, session_id) else {
            return Turn::Left(Departure::Gone);
        };
        let first = lane
            .iter()
            .find(|intent| intent.is_active())
            .map(|intent| intent.id);
        let Some(intent) = lane.iter_mut().find(|intent| intent.id == id) else {
            return Turn::Left(Departure::Gone);
        };
        match intent.state {
            IntentState::Queued if first == Some(id) => {
                intent.state = IntentState::InFlight;
                Turn::Go
            }
            IntentState::InFlight => Turn::Go,
            IntentState::Queued | IntentState::Unclear | IntentState::Held => {
                intent.waker = Some(waker.clone());
                Turn::Wait
            }
        }
    }

    /// The state of `id`, while it is in the ledger.
    #[must_use]
    pub fn state(&self, scope: &str, session_id: &str, id: IntentId) -> Option<IntentState> {
        self.lane(scope, session_id)?
            .iter()
            .find(|intent| intent.id == id)
            .map(|intent| intent.state)
    }

    /// Marks the in-flight `id` as lost with the link. Returns whether it was still in flight.
    pub fn mark_unclear(&mut self, scope: &str, session_id: &str, id: IntentId) -> bool {
        let Some(intent) = self
            .lane_mut(scope, session_id)
            .and_then(|lane| lane.iter_mut().find(|intent| intent.id == id))
            .filter(|intent| intent.state == IntentState::InFlight)
        else {
            return false;
        };
        intent.state = IntentState::Unclear;
        true
    }

    /// The link returned: every intent whose write was lost goes again.
    pub fn link_returned(&mut self) {
        for intent in self
            .lanes
            .values_mut()
            .flat_map(BTreeMap::values_mut)
            .flatten()
            .filter(|intent| intent.state == IntentState::Unclear)
        {
            intent.state = IntentState::InFlight;
            intent.wake();
        }
    }

    /// The server accepted `id` and answered with the row `answered`: the next intent on the
    /// lane may go, and any older held intent for its field is done. When the answer says what
    /// was asked the intent is held; when the server chose another value, the server's shows.
    /// Returns whether the intent is now held.
    pub fn confirm(
        &mut self,
        scope: &str,
        session_id: &str,
        id: IntentId,
        answered: &SessionSummary,
    ) -> bool {
        let Some(lane) = self.lane_mut(scope, session_id) else {
            return false;
        };
        let Some(index) = lane.iter().position(|intent| intent.id == id) else {
            return false;
        };
        let mut confirmed = lane.remove(index);
        lane.retain(|intent| intent.is_active() || !intent.patch.same_field(&confirmed.patch));
        let held = confirmed.patch.agrees_with(answered);
        if held {
            confirmed.state = IntentState::Held;
            confirmed.waker = None;
            // Held intents sit ahead of the ones still owed a write, in the order they settled.
            let ahead = lane.iter().take_while(|intent| !intent.is_active()).count();
            lane.insert(ahead, confirmed);
        }
        wake_all(lane);
        self.prune();
        held
    }

    /// Drops `id` because its write was refused or its caller went away. Returns whether the
    /// row it changed may show differently now.
    pub fn abandon(&mut self, scope: &str, session_id: &str, id: IntentId) -> bool {
        self.departed.remove(&id);
        let Some(lane) = self.lane_mut(scope, session_id) else {
            return false;
        };
        let Some(index) = lane
            .iter()
            .position(|intent| intent.id == id && intent.is_active())
        else {
            return false;
        };
        lane.remove(index);
        wake_all(lane);
        self.prune();
        true
    }

    /// A server row for the session arrived: held intents it agrees with are done.
    pub fn settle(&mut self, scope: &str, row: &SessionSummary) {
        let Some(lane) = self.lane_mut(scope, &row.id) else {
            return;
        };
        lane.retain(|intent| intent.is_active() || !intent.patch.agrees_with(row));
        self.prune();
    }

    /// The session left the server: its intents are dropped and their waiting callers told
    /// [`Departure::Gone`].
    pub fn drop_session(&mut self, scope: &str, session_id: &str) {
        let Some(lane) = self
            .lanes
            .get_mut(scope)
            .and_then(|sessions| sessions.remove(session_id))
        else {
            return;
        };
        for mut intent in lane {
            if matches!(intent.state, IntentState::Queued | IntentState::Unclear) {
                self.departed.insert(intent.id, Departure::Gone);
                intent.wake();
            }
        }
        self.prune();
    }

    /// The host's `timer` fired. A hold that is still running ends; an intent still waiting for
    /// the link gives up, and its caller is told [`Departure::GaveUp`]. Returns the scope and
    /// session whose row may show differently now.
    pub fn timer_elapsed(&mut self, timer: IntentTimer) -> Option<(String, String)> {
        let waits_in = match timer.kind {
            IntentTimerKind::Hold => IntentState::Held,
            IntentTimerKind::Unclear => IntentState::Unclear,
        };
        let (scope, session_id) = self.lanes.iter().find_map(|(scope, sessions)| {
            sessions
                .iter()
                .find(|(_, lane)| {
                    lane.iter()
                        .any(|intent| intent.id == timer.intent && intent.state == waits_in)
                })
                .map(|(session_id, _)| (scope.clone(), session_id.clone()))
        })?;
        let lane = self.lane_mut(&scope, &session_id)?;
        let index = lane.iter().position(|intent| intent.id == timer.intent)?;
        let mut ended = lane.remove(index);
        if timer.kind == IntentTimerKind::Unclear {
            self.departed.insert(ended.id, Departure::GaveUp);
            ended.wake();
        }
        if let Some(lane) = self.lane_mut(&scope, &session_id) {
            wake_all(lane);
        }
        self.prune();
        Some((scope, session_id))
    }

    /// `base` with the session's intents applied in order, whether or not one removes it. The
    /// row a caller of an edit gets back.
    #[must_use]
    pub fn overlay(&self, scope: &str, base: &SessionSummary) -> SessionSummary {
        self.lane(scope, &base.id)
            .map_or_else(|| base.clone(), |lane| overlay(lane, base))
    }

    /// What the list shows for the server row `base`: the row with the session's intents
    /// applied in order, or `None` while an intent removes it.
    #[must_use]
    pub fn project(&self, scope: &str, base: &SessionSummary) -> Option<SessionSummary> {
        let Some(lane) = self.lane(scope, &base.id) else {
            return Some(base.clone());
        };
        if lane
            .iter()
            .any(|intent| intent.patch == SessionPatch::Removed)
        {
            return None;
        }
        Some(overlay(lane, base))
    }
}

#[cfg(test)]
#[path = "intents_tests.rs"]
mod tests;
