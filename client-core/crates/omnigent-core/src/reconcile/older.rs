//! Older history above the newest page.
//!
//! Hydration reads only the newest page. The items known above it are kept here, with the cursor
//! for the next older page, so a rehydration or reconnect shows them again instead of collapsing
//! the transcript to the newest page: the pages a reader loaded, and the items new output pushed
//! out of the newest page. They are kept while the new newest page still shares an item with
//! what was known; otherwise the gap cannot be filled and they are dropped (the reader can load
//! them again).
//!
//! A server-forked side chat shows only its own turns (web `SideChatPane`): the history it copied
//! from its parent, created before the side chat was, is left out and never paged in.

use std::collections::BTreeSet;

use omnigent_protocol::ConversationItem;

use super::{
    ConversationSync, Link, SyncError, SyncUpdate, header_from_snapshot, history_rows,
    history_snapshot,
};
use crate::message_cache::SavedConversation;

/// Whether older history exists and whether a page of it is loading.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct HistoryPaging {
    /// Older items exist above the loaded ones.
    pub has_older: bool,
    /// A page of older items is being read.
    pub is_loading: bool,
}

/// The history a sync holds, for the device's saved copy ([`crate::message_cache`]).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HistoryItems {
    /// Items above the newest page, oldest first.
    pub older: Vec<ConversationItem>,
    /// The newest page as last read, oldest first.
    pub newest: Vec<ConversationItem>,
    /// The cursor for the page above `older`; `None` when history is complete or not read.
    pub cursor: Option<String>,
}

/// A read of older history the host must perform: `GET /v1/sessions/{id}/items` with
/// `after = cursor`, then [`ConversationSync::finish_older_history`] with this request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OlderHistoryRequest {
    /// The session.
    pub session_id: String,
    /// The `after` cursor of the read.
    pub cursor: String,
    generation: u64,
    ticket: u64,
}

/// The history known above the newest page.
#[derive(Debug, Clone, Default)]
pub(super) struct OlderHistory {
    /// Known items older than `newest`, oldest first.
    items: Vec<ConversationItem>,
    /// The newest page as last read, oldest first.
    newest: Vec<ConversationItem>,
    /// The cursor for the next older page; `None` when history is complete or not read yet.
    cursor: Option<String>,
    /// The ticket of the read in flight.
    loading: Option<u64>,
    next_ticket: u64,
    /// A side chat's start: items created before it were copied from its parent.
    pub(super) inherited_before: Option<i64>,
}

/// `items` (oldest first) without those created before `inherited_before`, and the cursor for
/// older items, which is dropped once a page reaches the copied history.
pub(super) fn own_items<'a>(
    items: &[ConversationItem],
    cursor: Option<&'a str>,
    inherited_before: Option<i64>,
) -> (Vec<ConversationItem>, Option<&'a str>) {
    let Some(start) = inherited_before else {
        return (items.to_vec(), cursor);
    };
    let own: Vec<ConversationItem> = items
        .iter()
        .filter(|item| item.created_at.is_none_or(|created| created >= start))
        .cloned()
        .collect();
    let reached_parent = own.len() < items.len();
    (own, if reached_parent { None } else { cursor })
}

impl OlderHistory {
    /// The newest page landed with `page` (oldest first) and its cursor for older items.
    /// Returns the whole known history, oldest first.
    pub(super) fn compose(
        &mut self,
        page: &[ConversationItem],
        older_cursor: Option<&str>,
    ) -> Vec<ConversationItem> {
        let in_page: BTreeSet<&str> = page.iter().map(|item| item.id.as_str()).collect();
        // Everything known before the first known item the page holds is older than the page.
        let reached = older_cursor.and_then(|_| {
            self.items
                .iter()
                .chain(&self.newest)
                .position(|item| in_page.contains(item.id.as_str()))
        });
        let above: Vec<ConversationItem> = self
            .items
            .iter()
            .chain(&self.newest)
            .take(reached.unwrap_or(0))
            .cloned()
            .collect();
        // A complete page holds everything and one that shares no item leaves a gap: paging
        // goes on from this page, and a read from another cursor is no longer wanted.
        if above.is_empty() && self.cursor.as_deref() != older_cursor {
            self.cursor = older_cursor.map(str::to_owned);
            self.loading = None;
        }
        self.newest = page.to_vec();
        self.items = above;
        self.items.iter().chain(page).cloned().collect()
    }

    fn items(&self) -> HistoryItems {
        HistoryItems {
            older: self.items.clone(),
            newest: self.newest.clone(),
            cursor: self.cursor.clone(),
        }
    }

    fn restore(&mut self, history: HistoryItems, inherited_before: Option<i64>) {
        *self = Self {
            items: history.older,
            newest: history.newest,
            cursor: history.cursor,
            loading: None,
            next_ticket: self.next_ticket,
            inherited_before,
        };
    }

    pub(super) fn clear(&mut self) {
        *self = Self {
            next_ticket: self.next_ticket,
            ..Self::default()
        };
    }

    pub(super) const fn paging(&self) -> HistoryPaging {
        HistoryPaging {
            has_older: self.cursor.is_some(),
            is_loading: self.loading.is_some(),
        }
    }
}

impl ConversationSync {
    /// Whether older history exists and whether it is loading.
    #[must_use]
    pub const fn history_paging(&self) -> HistoryPaging {
        self.older.paging()
    }

    /// The history held: the newest page as last read, the pages above it and their cursor.
    #[must_use]
    pub fn history_items(&self) -> HistoryItems {
        self.older.items()
    }

    /// Shows the device's saved copy of the session before its first hydration, as a hydration
    /// would show it: the rows of its items under its saved header, paging on from its cursor.
    /// A saved copy shows no turn as running, since nothing is known to run while it shows. It
    /// changes nothing once rows are shown, or for another session; the next hydration replaces
    /// it with the server's state, keeping the saved older pages while they still join up.
    ///
    /// # Errors
    ///
    /// The saved copy cannot be shown; nothing changes.
    pub fn restore_saved(&mut self, saved: &SavedConversation) -> Result<SyncUpdate, SyncError> {
        if self.link == Link::Stopped
            || self.published().is_some()
            || saved.session.id != self.session_id
        {
            return Ok(SyncUpdate::default());
        }
        let mut session = saved.session.clone();
        if session.status.is_busy() {
            session.status = omnigent_protocol::SessionStatus::Idle;
        }
        let header = header_from_snapshot(&session, None)?;
        let items: Vec<ConversationItem> = saved.items().cloned().collect();
        let snapshot = history_snapshot(&session, &items, header)?;
        let inherited_before = crate::session_tools::side_chat_inherited_before(
            session.labels.value(),
            session.harness.value().map(String::as_str),
            session.created_at,
        );
        self.older.restore(
            HistoryItems {
                older: saved.older.clone(),
                newest: saved.newest.clone(),
                cursor: saved.older_cursor.clone(),
            },
            inherited_before,
        );
        Ok(self.adopt(snapshot))
    }

    /// Starts reading the page of history above the loaded items. `None` while watching
    /// stopped, before the first hydration, once history is complete, or while a read is in
    /// flight.
    pub fn begin_older_history(&mut self) -> Option<OlderHistoryRequest> {
        if self.link == Link::Stopped || self.older.loading.is_some() {
            return None;
        }
        let cursor = self.older.cursor.clone()?;
        self.older.next_ticket += 1;
        self.older.loading = Some(self.older.next_ticket);
        Some(OlderHistoryRequest {
            session_id: self.session_id.clone(),
            cursor,
            generation: self.generation,
            ticket: self.older.next_ticket,
        })
    }

    fn is_current_older(&self, request: &OlderHistoryRequest) -> bool {
        self.link != Link::Stopped
            && request.generation == self.generation
            && request.session_id == self.session_id
            && self.older.loading == Some(request.ticket)
            && self.older.cursor.as_deref() == Some(request.cursor.as_str())
    }

    /// The read for `request` failed. Returns whether it was current; the reader can retry.
    pub fn older_history_failed(&mut self, request: &OlderHistoryRequest) -> bool {
        if !self.is_current_older(request) {
            return false;
        }
        self.older.loading = None;
        true
    }

    /// The read for `request` finished with `items` (oldest first) and the cursor for the next
    /// page. The rows are prepended above the transcript; rows already shown stay as they are.
    /// A stale request (stopped, or a rehydration restarted paging) changes nothing.
    ///
    /// # Errors
    ///
    /// An item cannot be shown. Paging stops loading and the sync is otherwise unchanged.
    pub fn finish_older_history(
        &mut self,
        request: &OlderHistoryRequest,
        items: &[ConversationItem],
        next_cursor: Option<&str>,
    ) -> Result<SyncUpdate, SyncError> {
        if !self.is_current_older(request) {
            return Ok(SyncUpdate::default());
        }
        self.older.loading = None;
        let (items, next_cursor) = own_items(items, next_cursor, self.older.inherited_before);
        let known: BTreeSet<&str> = self
            .older
            .items
            .iter()
            .map(|item| item.id.as_str())
            .collect();
        let mut merged: Vec<ConversationItem> = items
            .iter()
            .filter(|item| !known.contains(item.id.as_str()))
            .cloned()
            .collect();
        merged.extend(self.older.items.iter().cloned());
        let rows = history_rows(&merged)?;
        self.older.items = merged;
        self.older.cursor = next_cursor.map(str::to_owned);
        let changes = self
            .reducer
            .as_mut()
            .map(|reducer| reducer.prepend_history(rows))
            .unwrap_or_default();
        Ok(self.publish(changes))
    }
}
