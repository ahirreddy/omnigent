//! The session list kept in display order (`omnigent_core::session_index`).
//!
//! The host hands over the rows that changed and gets back what the change altered, so a list of
//! hundreds does not cross the boundary for one row.

use std::sync::{Arc, Mutex};

use omnigent_core::session_index::{SessionIndex as CoreIndex, SessionIndexChange as CoreChange};
use omnigent_core::sessions::SessionSummary as CoreSummary;

use crate::attention::{AttentionTotals, SessionAttention};
use crate::engine::lock;
use crate::sessions::{SessionFilter, SessionSummary};

/// One session's attention after a change.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SessionAttentionChange {
    /// The session.
    pub session_id: String,
    /// Its attention now; `None` when the session left the list.
    pub attention: Option<SessionAttention>,
}

/// What one change to a [`SessionIndex`] altered.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SessionIndexChange {
    /// The matching sessions' ids in display order, when the order or the membership changed.
    pub visible: Option<Vec<String>>,
    /// The ids of the sessions that need a response, in display order, when that changed.
    pub needs_response: Option<Vec<String>>,
    /// The sessions whose attention changed, by id.
    pub attention: Vec<SessionAttentionChange>,
    /// The totals after the change.
    pub totals: AttentionTotals,
}

impl From<CoreChange> for SessionIndexChange {
    fn from(change: CoreChange) -> Self {
        Self {
            visible: change.visible,
            needs_response: change.needs_response,
            attention: change
                .attention
                .into_iter()
                .map(|(session_id, attention)| SessionAttentionChange {
                    session_id,
                    attention: attention.map(Into::into),
                })
                .collect(),
            totals: change.totals.into(),
        }
    }
}

/// The sessions a list holds, the ones matching its search and filter in display order (pinned
/// first, then most recently updated, then by id), and each one's attention.
#[derive(Debug, Default, uniffi::Object)]
pub struct SessionIndex {
    index: Mutex<CoreIndex>,
}

#[uniffi::export]
impl SessionIndex {
    /// An empty index showing every session that is not archived.
    #[must_use]
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Replaces every session and the unread ids.
    pub fn reset(
        &self,
        sessions: Vec<SessionSummary>,
        unread_ids: Vec<String>,
    ) -> SessionIndexChange {
        let sessions = sessions.iter().map(CoreSummary::from).collect();
        lock(&self.index)
            .reset(sessions, unread_ids.into_iter().collect())
            .into()
    }

    /// Adds or replaces `upserted`, then drops the sessions of `removed`.
    pub fn update(
        &self,
        upserted: Vec<SessionSummary>,
        removed: Vec<String>,
    ) -> SessionIndexChange {
        let upserted = upserted.iter().map(CoreSummary::from).collect();
        lock(&self.index).update(upserted, &removed).into()
    }

    /// Replaces the unread ids. Read state changes attention, never the order.
    pub fn set_unread(&self, unread_ids: Vec<String>) -> SessionIndexChange {
        lock(&self.index)
            .set_unread(unread_ids.into_iter().collect())
            .into()
    }

    /// Searches for `text` among the sessions `filter` includes.
    pub fn set_query(&self, text: String, filter: SessionFilter) -> SessionIndexChange {
        lock(&self.index).set_query(&text, filter.into()).into()
    }
}
