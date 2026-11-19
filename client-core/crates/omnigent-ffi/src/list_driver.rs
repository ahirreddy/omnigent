//! The session list: its first page on connect, reloads that keep every page already loaded, and
//! "Load more" pages after them (the sidebar's and the Inbox's). Each reload also reads the pinned
//! sessions at the same time, so the Pinned section is whole before the pages that hold them load.
//! The pages hold unarchived sessions, as the web's sidebar reads them, until the sidebar shows
//! the archived ones.

use std::collections::BTreeSet;
use std::sync::Arc;

use futures::future::AbortHandle;
use omnigent_core::SessionError;
use omnigent_core::project_settings::ProjectSortMode as CoreSortMode;
use omnigent_core::projects::ProjectSummary as CoreProject;
use omnigent_core::sessions::{
    CANVAS_PAGE_LIMIT, DEFAULT_PAGE_LIMIT, ListedSessions, SessionPage, SessionSummary,
};

use crate::engine::{Engine, Msg};
use crate::project_driver::{FolderRead, Folders};
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
    /// Whether the sidebar shows archived sessions, which its pages then hold too.
    ShowArchived(bool),
    /// A "Load more" read finished.
    MoreLoaded {
        generation: u64,
        result: Result<SessionPage, SessionError>,
    },
    /// A reload's pinned read finished; `None` from a server without the filter.
    PinsLoaded {
        generation: u64,
        result: Result<Option<SessionPage>, SessionError>,
    },
    /// The projects and their sort order were read.
    ProjectsLoaded {
        read: u64,
        result: Result<(Vec<CoreProject>, CoreSortMode), SessionError>,
    },
    /// The sidebar shows these folders open.
    OpenFolders(BTreeSet<String>),
    /// Read a folder's first page, or (`true`) its next.
    LoadFolder(CoreProject, bool),
    /// A folder read finished.
    FolderLoaded {
        folder: String,
        token: u64,
        read: FolderRead,
        result: Result<SessionPage, SessionError>,
    },
}

/// How often the list is read again while connected. The updates socket announces a new session
/// only to sockets on the server process that made it, so one started from another app can
/// reach this client by no other way. The web re-reads at the same pace.
pub(crate) const LIST_RECONCILE_INTERVAL_MS: u64 = 60_000;

/// Which pages of the list are loaded.
#[derive(Default)]
pub(crate) struct ListWindow {
    /// Bumped by each reload; reads from an older one are dropped.
    pub(crate) generation: u64,
    /// A pending delayed reload.
    pub(crate) refresh: Option<AbortHandle>,
    /// The next periodic re-read.
    pub(crate) reconcile: Option<AbortHandle>,
    /// Rows the loaded pages selected (family members appended to them not counted); a reload
    /// asks for as many, so pages stay loaded.
    rows: u32,
    /// The cursor after the loaded rows; `None` once every session is loaded.
    next_cursor: Option<String>,
    /// A "Load more" read is in flight.
    loading_more: bool,
    /// The paging state the app was last told.
    reported: Option<(bool, bool)>,
    /// The pinned sessions last read. A reload's page keeps showing them until its own pinned
    /// read lands, so a pin outside the page never blinks out.
    pins: Vec<SessionSummary>,
    /// This reload's page is shown.
    page_shown: bool,
    /// This reload's pinned read, when it landed before the page.
    early_pins: Option<SessionPage>,
    /// The projects and their open folders' pages.
    pub(crate) folders: Folders,
    /// Which sessions the pages hold; kept across connections, as the sidebar keeps it.
    pub(crate) listed: ListedSessions,
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
            ListMsg::ShowArchived(shown) => self.show_archived(shown),
            ListMsg::MoreLoaded { generation, result } => self.more_loaded(generation, result),
            ListMsg::PinsLoaded { generation, result } => self.pins_loaded(generation, result),
            ListMsg::ProjectsLoaded { read, result } => self.projects_loaded(read, result),
            ListMsg::OpenFolders(open) => self.set_open_folders(open),
            ListMsg::LoadFolder(project, next) => self.load_folder(project, next),
            ListMsg::FolderLoaded {
                folder,
                token,
                read,
                result,
            } => self.folder_loaded(&folder, token, read, result),
        }
    }

    /// A new connection starts again from the first page.
    pub(crate) fn reset_list_window(&mut self) {
        self.cancel_list_timers();
        let generation = self.list.generation;
        let folders = self.list.folders.for_new_connection();
        let listed = self.list.listed;
        self.list = ListWindow {
            generation,
            folders,
            listed,
            ..ListWindow::default()
        };
        self.report_folders();
    }

    /// Drops the delayed reload and the periodic re-read, as a reload or a disconnect does.
    pub(crate) fn cancel_list_timers(&mut self) {
        for timer in [self.list.refresh.take(), self.list.reconcile.take()]
            .into_iter()
            .flatten()
        {
            timer.abort();
        }
    }

    /// Arms the next periodic re-read; each answer, good or bad, arms the one after it.
    fn schedule_list_reconcile(&mut self) {
        if let Some(timer) = self.list.reconcile.take() {
            timer.abort();
        }
        // The demo's sessions are made here; no other app adds to them.
        if self.is_demo() {
            return;
        }
        let tx = self.sender();
        self.list.reconcile = Some(self.host.after(LIST_RECONCILE_INTERVAL_MS, move || {
            post(&tx, Msg::List(ListMsg::Refresh));
        }));
    }

    pub(crate) fn refresh_list(&mut self) {
        self.cancel_list_timers();
        if !self.is_connected() {
            return;
        }
        self.list.generation = self.list.generation.wrapping_add(1);
        // The reload covers the page a "Load more" was reading; that read is dropped.
        self.list.loading_more = false;
        self.list.page_shown = false;
        self.list.early_pins = None;
        let generation = self.list.generation;
        let limit = self.list.reload_limit();
        let listed = self.list.listed;
        let sessions = Arc::clone(&self.sessions);
        let tx = self.sender();
        self.host.spawn(async move {
            let result = sessions.listed_page(None, limit, listed).await;
            post(&tx, Msg::List(ListMsg::Loaded { generation, result }));
        });
        // The demo's few sessions are all on its one page.
        if self.is_demo() {
            return;
        }
        let sessions = Arc::clone(&self.sessions);
        let tx = self.sender();
        self.host.spawn(async move {
            let result = sessions.pinned_session_page().await;
            post(&tx, Msg::List(ListMsg::PinsLoaded { generation, result }));
        });
        self.refresh_folders();
    }

    fn list_loaded(&mut self, generation: u64, result: Result<SessionPage, SessionError>) {
        if generation != self.list.generation || !self.is_connected() {
            return;
        }
        self.schedule_list_reconcile();
        match result {
            Ok(page) => {
                self.list.rows = u32::try_from(page.selected_rows).unwrap_or(u32::MAX);
                self.list.next_cursor = page.next_cursor;
                self.list.page_shown = true;
                let mut shown = page.sessions;
                let listed: BTreeSet<String> = shown.iter().map(|row| row.id.clone()).collect();
                let early = self.list.early_pins.take();
                let pins = early.as_ref().map_or(&self.list.pins, |early| &early.sessions);
                // Pins and open folders past the page keep showing while their reads run, as
                // the rows stand now: an edit since their read shows.
                let mut kept = listed;
                let others: Vec<String> = pins
                    .iter()
                    .chain(self.list.folders.rows())
                    .filter(|row| kept.insert(row.id.clone()))
                    .map(|row| row.id.clone())
                    .collect();
                shown.extend(self.sessions.shown_summaries(&others));
                self.emit(CoreEvent::SessionListChanged {
                    change: SessionListChange::Reset {
                        sessions: shown.iter().cloned().map(Into::into).collect(),
                    },
                });
                self.read_observe(&shown);
                self.emit(CoreEvent::SessionListLoaded);
                self.emit_list_paging();
                self.update_watch();
                self.saved_list_reset(page.rows);
                if let Some(early) = early {
                    self.list.pins = early.sessions;
                    self.saved_list_more(&early.rows);
                }
            }
            Err(error) => self.list_failed(error),
        }
    }

    /// A reload's pinned sessions: shown with its page, or after it when the page came first.
    fn pins_loaded(&mut self, generation: u64, result: Result<Option<SessionPage>, SessionError>) {
        if generation != self.list.generation || !self.is_connected() {
            return;
        }
        let page = match result {
            Ok(Some(page)) => page,
            // A server without the filter: its pins arrive with their pages.
            Ok(None) => {
                self.list.pins.clear();
                return;
            }
            // The rows already shown stay; the next reload reads the pins again.
            Err(error) => return self.list_failed(error),
        };
        if !self.list.page_shown {
            self.list.early_pins = Some(page);
            return;
        }
        if !page.sessions.is_empty() {
            self.emit(CoreEvent::SessionListChanged {
                change: SessionListChange::Upsert {
                    sessions: page.sessions.iter().cloned().map(Into::into).collect(),
                },
            });
            self.read_observe(&page.sessions);
            self.update_watch();
            self.saved_list_more(&page.rows);
        }
        self.list.pins = page.sessions;
    }

    /// Shows the saved list while the server cannot be reached: no more pages load.
    pub(crate) fn show_saved_list(&mut self, summaries: &[SessionSummary]) {
        self.reset_list_window();
        self.emit(CoreEvent::SessionListChanged {
            change: SessionListChange::Reset {
                sessions: summaries.iter().cloned().map(Into::into).collect(),
            },
        });
        self.read_observe(summaries);
        self.emit(CoreEvent::SessionListLoaded);
        self.emit_list_paging();
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
        let listed = self.list.listed;
        let sessions = Arc::clone(&self.sessions);
        let tx = self.sender();
        self.host.spawn(async move {
            let result = sessions
                .listed_page(Some(&cursor), DEFAULT_PAGE_LIMIT, listed)
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
                let added = u32::try_from(page.selected_rows).unwrap_or(u32::MAX);
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
                self.saved_list_more(&page.rows);
            }
            Err(error) => {
                self.emit_list_paging();
                self.list_failed(error);
            }
        }
    }

    /// The sidebar started or stopped showing archived sessions: the list reads its first page
    /// again with or without them.
    fn show_archived(&mut self, shown: bool) {
        let listed = if shown {
            ListedSessions::WithArchived
        } else {
            ListedSessions::Active
        };
        if listed == self.list.listed {
            return;
        }
        self.list.listed = listed;
        // The loaded pages were the other list's; this one starts at its first.
        self.list.rows = 0;
        self.list.next_cursor = None;
        self.refresh_list();
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
