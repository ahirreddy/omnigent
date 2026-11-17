//! This device's saved copy in the engine ([`crate::message_cache`]). Opening a session shows its
//! saved rows at once, and the first hydration replaces them with the server's. A connect that
//! cannot reach the server shows the saved list and sessions as offline until a connection, a
//! sign-in screen or a disconnect ends it. What the server returns is written through as it
//! arrives: hydrations, older pages, items the stream commits, and session list pages.

use std::sync::Arc;

use futures::future::AbortHandle;
use omnigent_core::message_cache::{
    self as cache, CacheError, CacheScope, SavedConversation, SavedSessionList,
};
use omnigent_core::realtime::ConnectionState;
use omnigent_protocol::{ConversationItem, ServerStreamEvent, SessionListItem, SessionSnapshot};

use crate::engine::{Engine, Msg};
use crate::events::{ConnectedServer, ConnectionPhase, CoreEvent, ErrorScope};
use crate::message_cache::{CacheFailureScope, MessageCache};
use crate::runtime::post;
use crate::stream_driver::DriverInstance;
use crate::sync::{Applied, ConversationSync};

/// How long items the stream committed wait to be saved, so a turn's burst is one write.
pub(crate) const STREAM_SAVE_DELAY_MS: u64 = 1_000;

/// The engine's saved-copy state.
#[derive(Debug, Default)]
pub(crate) struct SavedState {
    /// The account whose copy is read and written: the connected one, or the one shown offline.
    pub(crate) scope: Option<CacheScope>,
    /// The URL the app connected with, while its saved copy shows offline.
    pub(crate) offline: Option<String>,
    /// The rows of every list page loaded, as saved.
    pub(crate) list: Option<SavedSessionList>,
}

/// One open session's saved-copy state.
#[derive(Debug, Default)]
pub(crate) struct DriverSaved {
    /// The session as last read: by the last hydration, or in the saved copy shown.
    pub(crate) session: Option<SessionSnapshot>,
    /// Items the stream committed since the last hydration.
    pub(crate) streamed: Vec<ConversationItem>,
    /// The rows shown are the saved copy; the next hydration replaces them.
    pub(crate) showing_saved: bool,
    /// The stream is reconnecting or has failed.
    pub(crate) link_down: bool,
    /// What the app was last told of this session's offline state.
    pub(crate) offline_reported: bool,
    /// A save of streamed items waits on this.
    pub(crate) save_timer: Option<AbortHandle>,
}

/// Saved-copy messages for the engine.
pub(crate) enum SavedMsg {
    /// A connect could not reach `server_url`: show what this device saved of it.
    Unreachable {
        server_url: String,
        expected_user_id: Option<String>,
    },
    /// Save an open session's copy now: the stream committed items a moment ago.
    Save {
        session_id: String,
        driver: DriverInstance,
    },
    /// Signing out: delete the account's saved copy.
    ForgetAccount,
    /// The app removed a server: delete its saved copy.
    ForgetServer(String),
    /// The saved copy could not be read or written.
    Failed {
        failure: CacheFailureScope,
        error: CacheError,
    },
}

fn corrupt_conversation() -> CacheError {
    CacheError::Corrupt {
        what: cache::CONVERSATION_ROLE.to_owned(),
        cause: "it holds an item this app cannot show".to_owned(),
    }
}

impl Engine {
    pub(crate) fn saved_message(&mut self, message: SavedMsg) {
        match message {
            SavedMsg::Unreachable {
                server_url,
                expected_user_id,
            } => self.server_unreachable(&server_url, expected_user_id.as_deref()),
            SavedMsg::Save { session_id, driver } => {
                if self.is_current_driver(&session_id, driver) {
                    self.save_conversation(&session_id);
                }
            }
            SavedMsg::ForgetAccount => self.forget_saved_account(),
            SavedMsg::ForgetServer(server_url) => self.forget_saved_server(&server_url),
            SavedMsg::Failed { failure, error } => self.cache_failed(failure, error),
        }
    }

    /// The saved copy and the account it is read and written for, when both are known.
    fn cached(&self) -> Option<(Arc<MessageCache>, CacheScope)> {
        Some((Arc::clone(self.cache.as_ref()?), self.saved.scope.clone()?))
    }

    /// A background read or write failed: shown on its session, the list or the connection.
    fn cache_failed(&self, failure: CacheFailureScope, error: CacheError) {
        let scope = match failure {
            CacheFailureScope::Session(session_id) => ErrorScope::Session { session_id },
            CacheFailureScope::List => ErrorScope::SessionList,
            CacheFailureScope::Connection => ErrorScope::Connection,
        };
        self.error(scope, error.into());
    }

    /// Keeps the offline state in step with the phase just set. A sign-in screen, a failure the
    /// server answered, or a disconnect ends it; a disconnect also stops saving.
    pub(crate) fn saved_follows_phase(&mut self) {
        let ends = match &self.phase {
            ConnectionPhase::Discovering { .. }
            | ConnectionPhase::Connecting { .. }
            | ConnectionPhase::Connected { .. } => false,
            ConnectionPhase::Failed { error, .. } => !error.is_unreachable(),
            ConnectionPhase::Disconnected
            | ConnectionPhase::SignInRequired { .. }
            | ConnectionPhase::SigningIn { .. }
            | ConnectionPhase::AwaitingBrowserLogin { .. } => true,
        };
        if ends {
            self.leave_offline();
        }
        if matches!(self.phase, ConnectionPhase::Disconnected) {
            self.flush_saves();
            self.saved.scope = None;
            self.saved.list = None;
        }
    }

    /// A connect could not reach `server_url`: shows what this device saved of it, for
    /// `expected_user_id` or the account that last connected, as offline.
    pub(crate) fn server_unreachable(&mut self, server_url: &str, expected_user_id: Option<&str>) {
        let Some(cache) = self.cache.clone() else {
            return;
        };
        let Some(server) = cache::server_key(server_url) else {
            return;
        };
        let account = match expected_user_id {
            Some(user_id) => cache::account_key(user_id),
            None => match cache.read_last_account(&server) {
                Ok(Some(account)) => account,
                Ok(None) => return,
                Err(error) => {
                    self.error(ErrorScope::Connection, error.into());
                    return;
                }
            },
        };
        let scope = CacheScope::from_keys(server, account);
        if self.saved.offline.is_some() && self.saved.scope.as_ref() == Some(&scope) {
            return;
        }
        let list = match cache.read_list(&scope) {
            Ok(Some(list)) => list,
            Ok(None) => return,
            Err(error) => {
                self.error(ErrorScope::SessionList, error.into());
                return;
            }
        };
        let Ok(summaries) = omnigent_core::sessions::saved_summaries(&list.rows) else {
            cache.discard(scope.list_path(), CacheFailureScope::List, cache::LIST_ROLE);
            let error = CacheError::Corrupt {
                what: cache::LIST_ROLE.to_owned(),
                cause: "it holds a row this app cannot show".to_owned(),
            };
            self.error(ErrorScope::SessionList, error.into());
            return;
        };
        self.leave_offline();
        self.saved.scope = Some(scope);
        self.saved.offline = Some(server_url.to_owned());
        self.saved.list = Some(list);
        self.emit(CoreEvent::OfflineChanged {
            server_url: Some(server_url.to_owned()),
        });
        self.show_saved_list(&summaries);
        for id in self.open_ids() {
            if let Some(applied) = self.restore_saved(&id) {
                self.publish(&id, applied);
            }
            self.report_session_offline(&id);
        }
    }

    fn open_ids(&self) -> Vec<String> {
        self.drivers.keys().cloned().collect()
    }

    /// The saved copy no longer shows as offline; open sessions follow.
    pub(crate) fn leave_offline(&mut self) {
        if self.saved.offline.take().is_none() {
            return;
        }
        self.emit(CoreEvent::OfflineChanged { server_url: None });
        for id in self.open_ids() {
            self.report_session_offline(&id);
        }
    }

    /// The connection is up: the connected account's copy is read and written from now on,
    /// and open sessions that show nothing yet show theirs until they hydrate.
    pub(crate) fn saved_connected(&mut self, server: &ConnectedServer) {
        let shown = self
            .saved
            .offline
            .is_some()
            .then(|| self.saved.scope.clone());
        self.leave_offline();
        self.saved.list = None;
        let Some(cache) = self.cache.clone() else {
            return;
        };
        self.saved.scope = CacheScope::new(&server.base_url, &server.user_id);
        let Some(scope) = self.saved.scope.clone() else {
            return;
        };
        if shown.flatten().is_some_and(|shown| shown != scope) {
            self.drop_saved_rows();
        }
        cache.save_last_account(&scope, self.host.unix_ms());
        for id in self.open_ids() {
            if let Some(applied) = self.restore_saved(&id) {
                self.publish(&id, applied);
            }
        }
    }

    /// Clears the saved rows of another account from the open sessions.
    fn drop_saved_rows(&mut self) {
        for id in self.open_ids() {
            let Some(driver) = self.drivers.get_mut(&id) else {
                continue;
            };
            if !driver.saved.showing_saved {
                continue;
            }
            driver.sync.stop_raw();
            driver.sync = ConversationSync::create(&id);
            driver.saved = DriverSaved::default();
            driver.paging = None;
            self.emit_transcript_reset(&id);
            self.emit_paging(&id);
        }
    }

    /// Shows `session_id`'s saved copy when it shows nothing yet. Returns the changes, for the
    /// caller to publish or to send as part of a reset.
    pub(crate) fn restore_saved(&mut self, session_id: &str) -> Option<Applied> {
        let (cache, scope) = self.cached()?;
        let driver = self.drivers.get(session_id)?;
        if driver.sync.has_published_raw() {
            return None;
        }
        let scope_of_errors = ErrorScope::Session {
            session_id: session_id.to_owned(),
        };
        let saved = match cache.read_conversation(&scope, session_id) {
            Ok(saved) => saved?,
            Err(error) => {
                self.error(scope_of_errors, error.into());
                return None;
            }
        };
        let Ok(applied) = driver.sync.restore_saved_raw(&saved) else {
            cache.discard(
                scope.conversation_path(session_id),
                CacheFailureScope::Session(session_id.to_owned()),
                cache::CONVERSATION_ROLE,
            );
            self.error(scope_of_errors, corrupt_conversation().into());
            return None;
        };
        cache.touch_conversation(&scope, session_id, self.host.unix_ms());
        if let Some(driver) = self.drivers.get_mut(session_id) {
            driver.saved.session = Some(saved.session);
            driver.saved.showing_saved = true;
        }
        Some(applied)
    }

    /// Tells the app when whether `session_id` is offline changed: it is while the whole
    /// connection is, and while it shows its saved copy with its stream down.
    pub(crate) fn report_session_offline(&mut self, session_id: &str) {
        let connection_offline = self.saved.offline.is_some();
        let Some(driver) = self.drivers.get_mut(session_id) else {
            return;
        };
        let offline = connection_offline || (driver.saved.showing_saved && driver.saved.link_down);
        if offline == driver.saved.offline_reported {
            return;
        }
        driver.saved.offline_reported = offline;
        self.emit(CoreEvent::SessionOfflineChanged {
            session_id: session_id.to_owned(),
            offline,
        });
    }

    /// A session's stream changed state.
    pub(crate) fn saved_link(&mut self, session_id: &str, state: &ConnectionState) {
        let down = matches!(
            state,
            ConnectionState::Reconnecting { .. }
                | ConnectionState::Failed { .. }
                | ConnectionState::Closed
        );
        if let Some(driver) = self.drivers.get_mut(session_id) {
            driver.saved.link_down = down;
        }
        self.report_session_offline(session_id);
    }

    /// A hydration landed: the server's answer replaces the saved copy, on screen and on disk.
    pub(crate) fn saved_hydrated(&mut self, session_id: &str, snapshot: SessionSnapshot) {
        if let Some(driver) = self.drivers.get_mut(session_id) {
            driver.saved.session = Some(snapshot);
            driver.saved.streamed.clear();
            driver.saved.showing_saved = false;
        }
        self.save_conversation(session_id);
        self.report_session_offline(session_id);
    }

    /// Saves `session_id`'s copy: its last read snapshot, the history the sync holds and the
    /// items the stream committed since.
    pub(crate) fn save_conversation(&mut self, session_id: &str) {
        let Some((cache, scope)) = self.cached() else {
            return;
        };
        let now = self.host.unix_ms();
        let Some(driver) = self.drivers.get_mut(session_id) else {
            return;
        };
        if let Some(timer) = driver.saved.save_timer.take() {
            timer.abort();
        }
        let Some(session) = driver.saved.session.clone() else {
            return;
        };
        let saved = SavedConversation::new(
            now,
            session,
            driver.sync.history_items_raw(),
            &driver.saved.streamed,
        );
        cache.save_conversation(&scope, session_id, saved);
    }

    /// The stream committed `event`'s item (an output or a consumed input): it is saved shortly.
    pub(crate) fn saved_streamed(&mut self, session_id: &str, event: &ServerStreamEvent) {
        let item = match event {
            ServerStreamEvent::OutputItemDone(done) => done.item.clone(),
            ServerStreamEvent::SessionInputConsumed(consumed) => match consumed.data.item() {
                Ok(item) => item,
                // The sync reports an input it cannot show; there is nothing of it to save.
                Err(_) => return,
            },
            _ => return,
        };
        if self.cached().is_none() {
            return;
        }
        let tx = self.sender();
        let host = self.host.clone();
        let Some(driver) = self.drivers.get_mut(session_id) else {
            return;
        };
        match driver
            .saved
            .streamed
            .iter_mut()
            .find(|known| known.id == item.id)
        {
            Some(slot) => *slot = item,
            None => driver.saved.streamed.push(item),
        }
        if driver.saved.save_timer.is_some() {
            return;
        }
        let instance = driver.instance;
        let id = session_id.to_owned();
        driver.saved.save_timer = Some(host.after(STREAM_SAVE_DELAY_MS, move || {
            post(
                &tx,
                Msg::Saved(SavedMsg::Save {
                    session_id: id,
                    driver: instance,
                }),
            );
        }));
    }

    /// Saves `session_id`'s copy now when a save waits on a timer (the session closes).
    pub(crate) fn save_pending(&mut self, session_id: &str) {
        let pending = self
            .drivers
            .get(session_id)
            .is_some_and(|driver| driver.saved.save_timer.is_some());
        if pending {
            self.save_conversation(session_id);
        }
    }

    /// Saves every copy waiting on a timer now (the connection ends).
    fn flush_saves(&mut self) {
        for id in self.open_ids() {
            self.save_pending(&id);
        }
    }

    /// Drops every save waiting on a timer (signing out, removing the server).
    fn cancel_saves(&mut self) {
        for driver in self.drivers.values_mut() {
            if let Some(timer) = driver.saved.save_timer.take() {
                timer.abort();
            }
            driver.saved.streamed.clear();
        }
    }

    /// A reload's rows replace the saved list.
    pub(crate) fn saved_list_reset(&mut self, rows: Vec<SessionListItem>) {
        let Some((cache, scope)) = self.cached() else {
            return;
        };
        let list = SavedSessionList {
            saved_at_ms: self.host.unix_ms(),
            rows,
        };
        cache.save_list(&scope, list.clone());
        self.saved.list = Some(list);
    }

    /// A later page's rows join the saved list.
    pub(crate) fn saved_list_more(&mut self, rows: &[SessionListItem]) {
        let Some((cache, scope)) = self.cached() else {
            return;
        };
        let now = self.host.unix_ms();
        let Some(list) = self.saved.list.as_mut() else {
            return;
        };
        list.upsert(rows);
        list.saved_at_ms = now;
        cache.save_list(&scope, list.clone());
    }

    /// Sessions were deleted or access to them lost: their rows and saved copies go.
    pub(crate) fn saved_list_removed(&mut self, ids: &[String]) {
        let Some((cache, scope)) = self.cached() else {
            return;
        };
        if let Some(list) = self.saved.list.as_mut()
            && list.remove(ids)
        {
            cache.save_list(&scope, list.clone());
        }
        for id in ids {
            cache.discard(
                scope.conversation_path(id),
                CacheFailureScope::Session(id.clone()),
                cache::CONVERSATION_ROLE,
            );
        }
    }

    /// Signing out: the account's saved copy is deleted, and nothing more is saved for it.
    pub(crate) fn forget_saved_account(&mut self) {
        self.cancel_saves();
        let scope = self.saved.scope.take();
        self.saved.list = None;
        self.leave_offline();
        if let (Some(cache), Some(scope)) = (self.cache.clone(), scope) {
            cache.forget_account(&scope);
        }
    }

    /// The app removed a server: every account's saved copy of it is deleted.
    pub(crate) fn forget_saved_server(&mut self, server_url: &str) {
        let Some(cache) = self.cache.clone() else {
            return;
        };
        // A URL that does not normalize never named a saved copy.
        let Some(server) = cache::server_key(server_url) else {
            return;
        };
        if self
            .saved
            .scope
            .as_ref()
            .is_some_and(|scope| scope.server_key() == server)
        {
            self.cancel_saves();
            self.saved.scope = None;
            self.saved.list = None;
            self.leave_offline();
        }
        cache.forget_server(server);
    }
}

#[cfg(test)]
#[path = "cache_driver_tests.rs"]
mod tests;
