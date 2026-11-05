//! Older history above the newest page.
//!
//! Hydration reads only the newest page. Pages loaded above it are kept here, with the cursor
//! for the next one, so a rehydration or reconnect shows them again instead of collapsing the
//! transcript to the newest page. They are kept only while the new newest page still reaches the
//! oldest item it had when they were loaded; otherwise the gap cannot be filled and they are
//! dropped (the reader can load them again).

use std::collections::BTreeSet;

use omnigent_protocol::ConversationItem;

use super::{ConversationSync, Link, SyncError, SyncUpdate, history_rows};

/// Whether older history exists and whether a page of it is loading.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct HistoryPaging {
    /// Older items exist above the loaded ones.
    pub has_older: bool,
    /// A page of older items is being read.
    pub is_loading: bool,
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

/// Older pages loaded above the newest page.
#[derive(Debug, Clone, Default)]
pub(super) struct OlderHistory {
    /// Loaded items, oldest first; all older than `boundary`.
    items: Vec<ConversationItem>,
    /// The newest page's oldest item when the first older page loaded.
    boundary: Option<String>,
    /// The cursor for the next older page; `None` when history is complete or not read yet.
    cursor: Option<String>,
    /// The ticket of the read in flight.
    loading: Option<u64>,
    next_ticket: u64,
}

impl OlderHistory {
    /// The newest page landed with `page` (oldest first) and its cursor for older items.
    /// Returns the whole known history, oldest first.
    pub(super) fn compose(
        &mut self,
        page: &[ConversationItem],
        older_cursor: Option<&str>,
    ) -> Vec<ConversationItem> {
        let contiguous = older_cursor.is_some()
            && self
                .boundary
                .as_deref()
                .is_some_and(|boundary| page.iter().any(|item| item.id == boundary));
        if !contiguous {
            // A complete page holds everything; a page that no longer reaches the loaded
            // items leaves a gap. Either way paging restarts from this page.
            self.items.clear();
            self.boundary = None;
            self.cursor = older_cursor.map(str::to_owned);
            self.loading = None;
            return page.to_vec();
        }
        let in_page: BTreeSet<&str> = page.iter().map(|item| item.id.as_str()).collect();
        self.items
            .iter()
            .filter(|item| !in_page.contains(item.id.as_str()))
            .chain(page)
            .cloned()
            .collect()
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
        if self.older.boundary.is_none() {
            self.older.boundary = Some(request.cursor.clone());
        }
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
