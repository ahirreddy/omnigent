//! The attention model (`omnigent_core::session_attention`): one state per session, in the order
//! Needs you > Failed > Working > Unread > Idle, and the counts every surface shows.

use std::collections::HashSet;

use omnigent_core::session_attention::{
    AttentionState as CoreState, AttentionTotals as CoreTotals, SessionAttention as CoreAttention,
};
use omnigent_core::sessions::SessionSummary as CoreSummary;

use crate::sessions::SessionSummary;

/// Why a session needs (or does not need) the user, most urgent first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AttentionState {
    /// Pending decisions the caller can answer.
    NeedsYou,
    /// The last turn failed.
    Failed,
    /// A turn or background work is in progress, including a turn blocked on a decision the
    /// caller cannot answer.
    Working,
    /// Activity the user has not seen.
    Unread,
    /// Nothing to show.
    Idle,
}

impl From<CoreState> for AttentionState {
    fn from(state: CoreState) -> Self {
        match state {
            CoreState::NeedsYou => Self::NeedsYou,
            CoreState::Failed => Self::Failed,
            CoreState::Working => Self::Working,
            CoreState::Unread => Self::Unread,
            CoreState::Idle => Self::Idle,
        }
    }
}

/// One session's attention.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SessionAttention {
    /// The state.
    pub state: AttentionState,
    /// Pending decisions the caller can answer; zero unless `state` is `NeedsYou`.
    pub requests: u32,
}

impl From<CoreAttention> for SessionAttention {
    fn from(attention: CoreAttention) -> Self {
        Self {
            state: attention.state.into(),
            requests: attention.requests,
        }
    }
}

/// Totals across sessions.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AttentionTotals {
    /// Sessions in Needs you, archived or not: the badge number (sidebar Inbox and Needs
    /// response, Dock, menu bar).
    pub sessions_needing_you: u32,
    /// Pending decisions the caller can answer, across those sessions.
    pub requests: u32,
    /// Working sessions that are not archived (the Running filter).
    pub working: u32,
    /// Failed sessions that are not archived.
    pub failed: u32,
    /// Unread sessions that are not archived.
    pub unread: u32,
}

impl From<CoreTotals> for AttentionTotals {
    fn from(totals: CoreTotals) -> Self {
        Self {
            sessions_needing_you: totals.sessions_needing_you,
            requests: totals.requests,
            working: totals.working,
            failed: totals.failed,
            unread: totals.unread,
        }
    }
}

/// The attention of `session`; `is_unread` is the host's read state.
#[uniffi::export]
pub fn session_attention(session: SessionSummary, is_unread: bool) -> SessionAttention {
    CoreAttention::of(&CoreSummary::from(&session), is_unread).into()
}

/// The totals over `sessions`; `unread_ids` are the sessions the host considers unread.
#[uniffi::export]
pub fn attention_totals(sessions: Vec<SessionSummary>, unread_ids: Vec<String>) -> AttentionTotals {
    let unread: HashSet<String> = unread_ids.into_iter().collect();
    let core: Vec<CoreSummary> = sessions.iter().map(Into::into).collect();
    CoreTotals::of(&core, |id| unread.contains(id)).into()
}
