//! Which sessions to notify about, and when. Port of the web `useIdleNotifications` hook and
//! `idleTransitions.ts`, with time injected.
//!
//! - **Turn end:** a session going `running` → `idle`/`failed` is deferred by
//!   [`IDLE_SETTLE_MS`]. Agents that work in steps go idle between steps; going back to `running`
//!   within the window cancels the cue, so a multi-step task notifies once at the end. After a
//!   turn-end notification, further turn ends stay silent until the user views the session.
//! - **Elicitation:** a rise in `pending_elicitations_count` notifies immediately and cancels any
//!   deferred turn end for that session.
//! - **Runner offline:** a session whose `runner_online` is `false` never notifies. With no live
//!   runner the only status flips are the server reconciling a dead session, not real work.
//! - **Viewed session:** nothing notifies for the session the user is looking at (window focused
//!   and that session open), checked again when a deferred cue comes due.
//! - Archived sessions never notify. The first observation only seeds state.
//!
//! The host calls [`AttentionTracker::observe`] with every list or `/v1/sessions/updates`
//! snapshot, schedules a wake-up at [`AttentionTracker::next_deadline_ms`], and then calls
//! [`AttentionTracker::due`]. Use one tracker per [`super::NotificationScope`].

use std::collections::{BTreeMap, BTreeSet};

use omnigent_protocol::{Field, SessionListItem, SessionStatus};

use super::route::NotificationKind;

/// How long a session must stay idle after a turn ends before it is notified.
pub const IDLE_SETTLE_MS: u64 = 10_000;
/// Body for a finished turn when the host has no final assistant text to show.
pub const IDLE_BODY: &str = "Agent finished and is ready for your input.";
/// Body for a new elicitation.
pub const ELICITATION_BODY: &str = "Agent is asking for your input.";

/// What the user is looking at.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ViewContext {
    /// The open session, if a session is open.
    pub active_session_id: Option<String>,
    /// The app window has focus (and, on mobile, the app is in the foreground).
    pub window_focused: bool,
}

impl ViewContext {
    /// Whether `session_id` is actively viewed: the window is focused and it is the open session.
    #[must_use]
    pub fn is_viewing(&self, session_id: &str) -> bool {
        self.window_focused && self.active_session_id.as_deref() == Some(session_id)
    }
}

/// A notification to show now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttentionNotification {
    /// The session to open on tap.
    pub session_id: String,
    /// What happened: `Approval`, `Completed` or `Failed`.
    pub kind: NotificationKind,
    /// The session title, when known; the host falls back to its own label.
    pub title: Option<String>,
}

impl AttentionNotification {
    /// The default body. For a turn end the host may replace it with the final assistant text.
    #[must_use]
    pub const fn default_body(&self) -> &'static str {
        match self.kind {
            NotificationKind::Approval => ELICITATION_BODY,
            NotificationKind::Completed | NotificationKind::Failed => IDLE_BODY,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct DeferredTurnEnd {
    due_ms: u64,
    notification: AttentionNotification,
}

/// Turn-end and elicitation transitions across session-list snapshots.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AttentionTracker {
    statuses: BTreeMap<String, SessionStatus>,
    elicitations: BTreeMap<String, u64>,
    deferred: BTreeMap<String, DeferredTurnEnd>,
    notified: BTreeSet<String>,
    runner_offline: BTreeSet<String>,
}

fn is_archived(row: &SessionListItem) -> bool {
    row.archived.value() == Some(&true)
}

fn elicitation_count(row: &SessionListItem) -> u64 {
    row.pending_elicitations_count.value().copied().unwrap_or(0)
}

fn notification(row: &SessionListItem, kind: NotificationKind) -> AttentionNotification {
    AttentionNotification {
        session_id: row.id.clone(),
        kind,
        title: row.title.value().cloned(),
    }
}

impl AttentionTracker {
    /// A tracker with no history: the first [`AttentionTracker::observe`] only seeds it.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Applies a full session-list snapshot at `now_ms`. Returns the notifications to show now
    /// (new elicitations); turn ends are deferred until [`AttentionTracker::due`].
    ///
    /// `can_notify` is false while notification permission is missing: history still advances,
    /// so granting permission later does not replay old transitions.
    pub fn observe(
        &mut self,
        rows: &[SessionListItem],
        view: &ViewContext,
        now_ms: u64,
        can_notify: bool,
    ) -> Vec<AttentionNotification> {
        let turn_ends: Vec<AttentionNotification> = rows
            .iter()
            .filter(|row| !is_archived(row))
            .filter(|row| self.statuses.get(&row.id) == Some(&SessionStatus::Running))
            .filter_map(|row| match row.status {
                SessionStatus::Idle => Some(notification(row, NotificationKind::Completed)),
                SessionStatus::Failed => Some(notification(row, NotificationKind::Failed)),
                _ => None,
            })
            .collect();
        let mut asks: Vec<AttentionNotification> = rows
            .iter()
            .filter(|row| !is_archived(row))
            .filter(|row| {
                self.elicitations
                    .get(&row.id)
                    .is_some_and(|prior| elicitation_count(row) > *prior)
            })
            .map(|row| notification(row, NotificationKind::Approval))
            .collect();
        self.record(rows, view);
        if !can_notify {
            return Vec::new();
        }
        for turn_end in turn_ends {
            let id = &turn_end.session_id;
            if view.is_viewing(id) || self.runner_offline.contains(id) || self.notified.contains(id)
            {
                continue;
            }
            // Re-arm: a later turn end restarts the settle window.
            self.deferred.insert(
                id.clone(),
                DeferredTurnEnd {
                    due_ms: now_ms.saturating_add(IDLE_SETTLE_MS),
                    notification: turn_end,
                },
            );
        }
        asks.retain(|ask| {
            !view.is_viewing(&ask.session_id) && !self.runner_offline.contains(&ask.session_id)
        });
        // Awaiting input, not quietly finishing: drop any deferred turn end.
        for ask in &asks {
            self.deferred.remove(&ask.session_id);
        }
        asks
    }

    /// Updates history from `rows` and drops state for sessions that left the list, resumed, or
    /// are being viewed.
    fn record(&mut self, rows: &[SessionListItem], view: &ViewContext) {
        self.statuses = rows
            .iter()
            .map(|row| (row.id.clone(), row.status.clone()))
            .collect();
        self.elicitations = rows
            .iter()
            .map(|row| (row.id.clone(), elicitation_count(row)))
            .collect();
        self.runner_offline = rows
            .iter()
            .filter(|row| matches!(row.runner_online, Field::Present(false)))
            .map(|row| row.id.clone())
            .collect();
        let present: BTreeSet<&str> = rows.iter().map(|row| row.id.as_str()).collect();
        // A session that left the list must not deliver a queued cue; a resumed one was between
        // steps, not finished.
        self.deferred.retain(|id, _| present.contains(id.as_str()));
        for row in rows
            .iter()
            .filter(|row| row.status == SessionStatus::Running)
        {
            self.deferred.remove(&row.id);
        }
        // Viewing a session (or it leaving the list) allows its next turn end to notify again.
        self.notified
            .retain(|id| present.contains(id.as_str()) && !view.is_viewing(id));
    }

    /// The earliest time a deferred turn end comes due, for the host's wake-up timer.
    #[must_use]
    pub fn next_deadline_ms(&self) -> Option<u64> {
        self.deferred.values().map(|deferred| deferred.due_ms).min()
    }

    /// Turn ends whose settle window has passed at `now_ms`, unless the session is now viewed or
    /// its runner went offline meanwhile.
    pub fn due(&mut self, view: &ViewContext, now_ms: u64) -> Vec<AttentionNotification> {
        let (due, waiting): (BTreeMap<_, _>, BTreeMap<_, _>) = std::mem::take(&mut self.deferred)
            .into_iter()
            .partition(|(_, deferred)| deferred.due_ms <= now_ms);
        self.deferred = waiting;
        let mut fired = Vec::new();
        for (id, deferred) in due {
            if view.is_viewing(&id) || self.runner_offline.contains(&id) {
                continue;
            }
            self.notified.insert(id);
            fired.push(deferred.notification);
        }
        fired
    }

    /// Forgets everything (for example after switching account).
    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

/// Sessions that count toward the app badge.
///
/// A session counts when it is not archived, not actively viewed, and either waiting for input or
/// unseen (`is_unseen` is the host's last-seen check). Recomputed from the full list, so it
/// survives restarts.
pub fn unread_badge_ids(
    rows: &[SessionListItem],
    view: &ViewContext,
    is_unseen: impl Fn(&SessionListItem) -> bool,
) -> BTreeSet<String> {
    rows.iter()
        .filter(|row| !is_archived(row) && !view.is_viewing(&row.id))
        .filter(|row| elicitation_count(row) > 0 || is_unseen(row))
        .map(|row| row.id.clone())
        .collect()
}
