//! The saved session list as the app's first sight of a server: a connect shows what this device
//! saved of it at once (rows, projects and their folders), before the manifest is read, and the
//! server's list replaces it in one step once this connection's first page, pins and open
//! folders are in (`ListWindow::holds_for_saved`). An unreachable server keeps it, as offline.
//! The list file is written through as reads land: pages, pins, folders and the projects.

use std::collections::BTreeSet;

use omnigent_core::message_cache::{
    self as cache, CacheError, CacheScope, SavedProjects, SavedSessionList,
};
use omnigent_core::sessions::SessionSummary;
use omnigent_protocol::SessionListItem;

use crate::engine::Engine;
use crate::events::{ConnectionPhase, CoreEvent, ErrorScope};
use crate::message_cache::{CacheFailureScope, MessageCache};
use crate::sessions::SessionListChange;

impl Engine {
    /// A connect to `server_url` began: the saved list of `expected_user_id` (or of the account
    /// that last connected) shows until the server's replaces it. Offline, the saved copy shows
    /// already and stays until this connect ends.
    pub(crate) fn saved_connecting(&mut self, server_url: &str, expected_user_id: Option<&str>) {
        if self.saved.offline.is_some() {
            return;
        }
        let Some(cache) = self.cache.clone() else {
            return;
        };
        let scope = self.offline_scope(&cache, server_url, expected_user_id);
        if self.saved.early.is_some() {
            if scope.is_some() && self.saved.scope == scope {
                return;
            }
            self.leave_early();
            self.saved.scope = None;
            self.saved.list = None;
        }
        let Some(scope) = scope else {
            return;
        };
        let Some((list, summaries)) = self.read_saved_list(&cache, &scope) else {
            return;
        };
        self.saved.early = Some(server_url.to_owned());
        self.emit(CoreEvent::SavedListShown {
            server_url: Some(server_url.to_owned()),
            viewer_id: list.viewer_id.clone(),
        });
        self.show_saved(scope, list, &summaries);
    }

    /// The saved list of `scope` and its rows as the list shows them; `None` when nothing was
    /// saved, or when the file could not be read (reported) or held a row this app cannot show
    /// (reported and discarded).
    pub(crate) fn read_saved_list(
        &self,
        cache: &MessageCache,
        scope: &CacheScope,
    ) -> Option<(SavedSessionList, Vec<SessionSummary>)> {
        let list = match cache.read_list(scope) {
            Ok(list) => list?,
            Err(error) => {
                self.error(ErrorScope::SessionList, error.into());
                return None;
            }
        };
        let Ok(summaries) = omnigent_core::sessions::saved_summaries(&list.rows) else {
            cache.discard(scope.list_path(), CacheFailureScope::List, cache::LIST_ROLE);
            let error = CacheError::Corrupt {
                what: cache::LIST_ROLE.to_owned(),
                cause: "it holds a row this app cannot show".to_owned(),
            };
            self.error(ErrorScope::SessionList, error.into());
            return None;
        };
        Some((list, summaries))
    }

    /// Shows `list` of `scope`, and each open session's saved copy where it shows nothing yet.
    pub(crate) fn show_saved(
        &mut self,
        scope: CacheScope,
        list: SavedSessionList,
        summaries: &[SessionSummary],
    ) {
        self.saved.scope = Some(scope);
        self.saved.projects.clone_from(&list.projects);
        self.saved.list = Some(list);
        let projects = self.saved.projects.clone();
        self.show_saved_list(summaries, projects.as_ref());
        for id in self.open_ids() {
            if let Some(applied) = self.restore_saved(&id) {
                self.publish(&id, applied);
            }
            self.report_session_offline(&id);
        }
    }

    /// The saved list no longer shows ahead of the server's: the server's replaced it, or the
    /// connect ended without it.
    pub(crate) fn leave_early(&mut self) {
        if self.saved.early.take().is_some() {
            self.emit(CoreEvent::SavedListShown {
                server_url: None,
                viewer_id: None,
            });
        }
    }

    /// The saved list showed for another account than the one that connected: its rows go now,
    /// before this account's first page.
    pub(crate) fn drop_saved_list(&mut self) {
        self.list.holds_for_saved = false;
        self.list.folders.forget_known();
        self.emit(CoreEvent::SessionListChanged {
            change: SessionListChange::Reset {
                sessions: Vec::new(),
            },
        });
        self.leave_early();
    }

    /// A reload's rows replace the saved list; the open folders' rows stay in it, as they stay
    /// shown.
    pub(crate) fn saved_list_reset(&mut self, mut rows: Vec<SessionListItem>) {
        let Some((cache, scope)) = self.cached() else {
            return;
        };
        let mut ids: BTreeSet<String> = rows.iter().map(|row| row.id.clone()).collect();
        let folders: Vec<SessionListItem> = self
            .list
            .folders
            .saved_rows()
            .filter(|row| ids.insert(row.id.clone()))
            .cloned()
            .collect();
        rows.extend(folders);
        let viewer_id = match &self.phase {
            ConnectionPhase::Connected { server } => Some(server.user_id.clone()),
            _ => None,
        };
        let list = SavedSessionList {
            saved_at_ms: self.host.unix_ms(),
            rows,
            projects: self.saved.projects.clone(),
            viewer_id,
        };
        cache.save_list(&scope, list.clone());
        self.saved.list = Some(list);
    }

    /// The projects just read join the saved list.
    pub(crate) fn saved_projects(&mut self, projects: SavedProjects) {
        if self.saved.projects.as_ref() == Some(&projects) {
            return;
        }
        self.saved.projects = Some(projects);
        let Some((cache, scope)) = self.cached() else {
            return;
        };
        let Some(list) = self.saved.list.as_mut() else {
            return;
        };
        list.projects.clone_from(&self.saved.projects);
        cache.save_list(&scope, list.clone());
    }
}

#[cfg(test)]
#[path = "saved_list_tests.rs"]
mod tests;
