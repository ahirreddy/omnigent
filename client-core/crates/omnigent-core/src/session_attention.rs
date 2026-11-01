//! One attention model for every surface that says what needs the user: the session row, the
//! Inbox, the sidebar counts, the Dock badge, the menu bar and notifications.
//!
//! A session has exactly one [`AttentionState`], in precedence order
//! **Needs you > Failed > Working > Unread > Idle**:
//! - **Needs you:** it has pending decisions the caller can answer (edit permission or above). A
//!   read-only viewer cannot answer, so for them the session is blocked on someone else and reads
//!   as Working.
//! - **Failed:** the last turn failed.
//! - **Working:** a turn or background work is in progress.
//! - **Unread:** the host says it has activity the user has not seen.
//! - **Idle:** none of the above.
//!
//! Counts, as every surface uses them:
//! - [`SessionAttention::requests`]: the session's pending decisions the caller can answer, as the
//!   server reports them (`pending_elicitations_count`, or the snapshot's pending requests).
//! - [`AttentionTotals::sessions_needing_you`]: sessions in Needs you, archived or not, so a
//!   pending decision is never hidden. This is the badge number (sidebar Inbox and Needs
//!   response, Dock, menu bar).
//! - [`AttentionTotals::requests`]: the sum of [`SessionAttention::requests`] over those sessions.
//! - [`AttentionTotals::working`], [`AttentionTotals::failed`], [`AttentionTotals::unread`]:
//!   sessions in that state that are not archived.

use crate::client::sessions::{SessionSummary, SummaryStatus};

/// Why a session needs (or does not need) the user, most urgent first. The derived order is the
/// precedence: a smaller value wins.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum AttentionState {
    /// Pending decisions the caller can answer.
    NeedsYou,
    /// The last turn failed.
    Failed,
    /// A turn or background work is in progress (including a turn blocked on a decision the
    /// caller cannot answer).
    Working,
    /// Activity the user has not seen.
    Unread,
    /// Nothing to show.
    Idle,
}

/// One session's attention.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SessionAttention {
    /// The state.
    pub state: AttentionState,
    /// Pending decisions the caller can answer; zero unless `state` is
    /// [`AttentionState::NeedsYou`].
    pub requests: u32,
}

impl SessionAttention {
    /// The attention of `summary`. `is_unread` is the host's read state.
    #[must_use]
    pub const fn of(summary: &SessionSummary, is_unread: bool) -> Self {
        let requests = if summary.is_read_only {
            0
        } else {
            summary.pending_requests
        };
        let state = if requests > 0 {
            AttentionState::NeedsYou
        } else if summary.failure_message.is_some() {
            AttentionState::Failed
        } else if matches!(
            summary.status,
            SummaryStatus::Running | SummaryStatus::NeedsResponse
        ) {
            AttentionState::Working
        } else if is_unread {
            AttentionState::Unread
        } else {
            AttentionState::Idle
        };
        Self { state, requests }
    }
}

/// Totals across sessions (see the module docs for what each counts).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct AttentionTotals {
    /// Sessions in Needs you, archived or not.
    pub sessions_needing_you: u32,
    /// Pending decisions the caller can answer, across those sessions.
    pub requests: u32,
    /// Working sessions that are not archived.
    pub working: u32,
    /// Failed sessions that are not archived.
    pub failed: u32,
    /// Unread sessions that are not archived.
    pub unread: u32,
}

impl AttentionTotals {
    /// The totals over `sessions`; `is_unread` is the host's read state for a session id.
    #[must_use]
    pub fn of<'a>(
        sessions: impl IntoIterator<Item = &'a SessionSummary>,
        is_unread: impl Fn(&str) -> bool,
    ) -> Self {
        let mut totals = Self::default();
        for session in sessions {
            let attention = SessionAttention::of(session, is_unread(&session.id));
            match attention.state {
                AttentionState::NeedsYou => {
                    totals.sessions_needing_you += 1;
                    totals.requests = totals.requests.saturating_add(attention.requests);
                }
                _ if session.is_archived => {}
                AttentionState::Failed => totals.failed += 1,
                AttentionState::Working => totals.working += 1,
                AttentionState::Unread => totals.unread += 1,
                AttentionState::Idle => {}
            }
        }
        totals
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(id: &str) -> SessionSummary {
        SessionSummary::new(id, id, "")
    }

    fn waiting(id: &str, requests: u32) -> SessionSummary {
        SessionSummary {
            status: SummaryStatus::NeedsResponse,
            pending_requests: requests,
            ..session(id)
        }
    }

    #[test]
    fn precedence_is_needs_you_failed_working_unread_idle() {
        assert!(AttentionState::NeedsYou < AttentionState::Failed);
        assert!(AttentionState::Failed < AttentionState::Working);
        assert!(AttentionState::Working < AttentionState::Unread);
        assert!(AttentionState::Unread < AttentionState::Idle);

        let needs = SessionAttention::of(&waiting("a", 3), true);
        assert_eq!(
            needs,
            SessionAttention {
                state: AttentionState::NeedsYou,
                requests: 3
            }
        );
        let failed = SessionSummary {
            failure_message: Some("Invalid API key".into()),
            ..session("b")
        };
        assert_eq!(
            SessionAttention::of(&failed, true).state,
            AttentionState::Failed
        );
        let running = SessionSummary {
            status: SummaryStatus::Running,
            ..session("c")
        };
        assert_eq!(
            SessionAttention::of(&running, true).state,
            AttentionState::Working
        );
        assert_eq!(
            SessionAttention::of(&session("d"), true).state,
            AttentionState::Unread
        );
        assert_eq!(
            SessionAttention::of(&session("e"), false).state,
            AttentionState::Idle
        );
    }

    #[test]
    fn a_blocked_session_never_reads_as_working_for_someone_who_can_answer() {
        // The server may still say `running` while a decision is pending.
        let blocked = SessionSummary {
            status: SummaryStatus::Running,
            pending_requests: 2,
            ..session("blocked")
        };
        assert_eq!(
            SessionAttention::of(&blocked, false).state,
            AttentionState::NeedsYou
        );
    }

    #[test]
    fn read_only_viewers_see_a_blocked_session_as_working_with_no_requests() {
        let shared = SessionSummary {
            is_read_only: true,
            ..waiting("shared", 4)
        };
        assert_eq!(
            SessionAttention::of(&shared, false),
            SessionAttention {
                state: AttentionState::Working,
                requests: 0
            }
        );
    }

    #[test]
    fn totals_count_sessions_and_requests_and_keep_archived_decisions() {
        let sessions = [
            waiting("current", 7),
            waiting("other", 2),
            SessionSummary {
                is_archived: true,
                ..waiting("archived", 1)
            },
            SessionSummary {
                status: SummaryStatus::Running,
                ..session("running")
            },
            SessionSummary {
                status: SummaryStatus::Running,
                is_archived: true,
                ..session("archived-running")
            },
            SessionSummary {
                failure_message: Some("boom".into()),
                ..session("failed")
            },
            session("unread"),
            session("idle"),
        ];
        let totals = AttentionTotals::of(&sessions, |id| id == "unread" || id == "current");
        assert_eq!(
            totals,
            AttentionTotals {
                sessions_needing_you: 3,
                requests: 10,
                working: 1,
                failed: 1,
                unread: 1,
            }
        );
    }
}
