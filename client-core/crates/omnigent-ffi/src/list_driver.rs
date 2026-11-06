//! The session list: its first page on connect, reloads that keep every page already loaded, and
//! "Load more" pages after them (the sidebar's and the Inbox's).

use std::sync::Arc;

use futures::future::AbortHandle;
use omnigent_core::SessionError;
use omnigent_core::sessions::{CANVAS_PAGE_LIMIT, DEFAULT_PAGE_LIMIT, SessionPage};

use crate::engine::{Engine, Msg};
use crate::errors::CoreError;
use crate::events::{CoreEvent, ErrorScope};
use crate::runtime::post;
use crate::sessions::SessionListChange;

/// List messages for the engine.
pub(crate) enum ListMsg {
    /// Reload the loaded pages now.
    Refresh,
    /// A reload finished.
    Loaded {
        generation: u64,
        result: Result<SessionPage, SessionError>,
    },
    /// Read the page after the loaded rows.
    LoadMore,
    /// A "Load more" read finished.
    MoreLoaded {
        generation: u64,
        result: Result<SessionPage, SessionError>,
    },
}

/// Which pages of the list are loaded.
#[derive(Default)]
pub(crate) struct ListWindow {
    /// Bumped by each reload; reads from an older one are dropped.
    pub(crate) generation: u64,
    /// A pending delayed reload.
    pub(crate) refresh: Option<AbortHandle>,
    /// Rows the loaded pages held; a reload asks for as many, so pages stay loaded.
    rows: u32,
    /// The cursor after the loaded rows; `None` once every session is loaded.
    next_cursor: Option<String>,
    /// A "Load more" read is in flight.
    loading_more: bool,
    /// The paging state the app was last told.
    reported: Option<(bool, bool)>,
}

impl ListWindow {
    /// How many rows a reload asks for: every loaded page, at least the first, at most the
    /// server's maximum.
    pub(crate) fn reload_limit(&self) -> u32 {
        self.rows.clamp(DEFAULT_PAGE_LIMIT, CANVAS_PAGE_LIMIT)
    }
}

impl Engine {
    pub(crate) fn list_message(&mut self, message: ListMsg) {
        match message {
            ListMsg::Refresh => self.refresh_list(),
            ListMsg::Loaded { generation, result } => self.list_loaded(generation, result),
            ListMsg::LoadMore => self.load_more_sessions(),
            ListMsg::MoreLoaded { generation, result } => self.more_loaded(generation, result),
        }
    }

    /// A new connection starts again from the first page.
    pub(crate) fn reset_list_window(&mut self) {
        if let Some(timer) = self.list.refresh.take() {
            timer.abort();
        }
        let generation = self.list.generation;
        self.list = ListWindow {
            generation,
            ..ListWindow::default()
        };
    }

    pub(crate) fn refresh_list(&mut self) {
        if let Some(timer) = self.list.refresh.take() {
            timer.abort();
        }
        if !self.is_connected() {
            return;
        }
        self.list.generation = self.list.generation.wrapping_add(1);
        // The reload covers the page a "Load more" was reading; that read is dropped.
        self.list.loading_more = false;
        let generation = self.list.generation;
        let limit = self.list.reload_limit();
        let sessions = Arc::clone(&self.sessions);
        let tx = self.sender();
        self.host.spawn(async move {
            let result = sessions.session_page(None, limit).await;
            post(&tx, Msg::List(ListMsg::Loaded { generation, result }));
        });
    }

    fn list_loaded(&mut self, generation: u64, result: Result<SessionPage, SessionError>) {
        if generation != self.list.generation || !self.is_connected() {
            return;
        }
        match result {
            Ok(page) => {
                self.list.rows = u32::try_from(page.sessions.len()).unwrap_or(u32::MAX);
                self.list.next_cursor = page.next_cursor;
                self.emit(CoreEvent::SessionListChanged {
                    change: SessionListChange::Reset {
                        sessions: page.sessions.iter().cloned().map(Into::into).collect(),
                    },
                });
                self.read_observe(&page.sessions);
                self.emit(CoreEvent::SessionListLoaded);
                self.emit_list_paging();
                self.update_watch();
            }
            Err(error) => self.list_failed(error),
        }
    }

    /// Reads the page after the loaded rows, unless every session is loaded or a page is
    /// already loading.
    fn load_more_sessions(&mut self) {
        if !self.is_connected() || self.list.loading_more {
            return;
        }
        let Some(cursor) = self.list.next_cursor.clone() else {
            return;
        };
        self.list.loading_more = true;
        self.emit_list_paging();
        let generation = self.list.generation;
        let sessions = Arc::clone(&self.sessions);
        let tx = self.sender();
        self.host.spawn(async move {
            let result = sessions
                .session_page(Some(&cursor), DEFAULT_PAGE_LIMIT)
                .await;
            post(&tx, Msg::List(ListMsg::MoreLoaded { generation, result }));
        });
    }

    fn more_loaded(&mut self, generation: u64, result: Result<SessionPage, SessionError>) {
        if generation != self.list.generation || !self.is_connected() {
            return;
        }
        self.list.loading_more = false;
        match result {
            Ok(page) => {
                let added = u32::try_from(page.sessions.len()).unwrap_or(u32::MAX);
                self.list.rows = self.list.rows.saturating_add(added);
                self.list.next_cursor = page.next_cursor;
                if !page.sessions.is_empty() {
                    self.emit(CoreEvent::SessionListChanged {
                        change: SessionListChange::Upsert {
                            sessions: page.sessions.iter().cloned().map(Into::into).collect(),
                        },
                    });
                    self.read_observe(&page.sessions);
                }
                self.emit_list_paging();
                self.update_watch();
            }
            Err(error) => {
                self.emit_list_paging();
                self.list_failed(error);
            }
        }
    }

    fn list_failed(&mut self, error: SessionError) {
        let error = CoreError::from(error);
        if error.requires_sign_in() {
            self.sign_in_lost(error);
        } else {
            self.error(ErrorScope::SessionList, error);
        }
    }

    /// Tells the app whether more sessions can load, when that or the loading state changed.
    fn emit_list_paging(&mut self) {
        let state = (self.list.next_cursor.is_some(), self.list.loading_more);
        if self.list.reported == Some(state) {
            return;
        }
        self.list.reported = Some(state);
        self.emit(CoreEvent::SessionListPagingChanged {
            has_more: state.0,
            is_loading: state.1,
        });
    }
}

#[cfg(test)]
#[path = "list_tests.rs"]
mod tests;
