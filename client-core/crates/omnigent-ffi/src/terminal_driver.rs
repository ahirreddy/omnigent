//! The open sessions' terminal inventories: fed by list reads and `session.resource.*`,
//! `session.terminal.activity` and `session.terminal_pending` events, published as
//! `TerminalsChanged` when the rows or the harness view change.

use std::sync::Arc;

use omnigent_core::terminal::{TerminalResource, TerminalRow};
use omnigent_protocol::ServerStreamEvent;

use crate::engine::{Engine, Msg};
use crate::errors::CoreError;
use crate::events::ErrorScope;
use crate::runtime::post;
use crate::terminal::{HarnessTerminal, harness_of, terminal_error, terminals_event};

/// Stream events that may change a session's terminals or its harness view.
const TERMINAL_EVENTS: [&str; 4] = [
    "session.resource.created",
    "session.resource.deleted",
    "session.terminal.activity",
    "session.terminal_pending",
];

/// What was last published for a session's terminals.
pub(crate) type TerminalView = (Vec<TerminalRow>, HarnessTerminal);

impl Engine {
    /// A decoded stream event for an open session.
    pub(crate) fn terminal_event(&mut self, session_id: &str, event: &ServerStreamEvent) {
        if !TERMINAL_EVENTS.contains(&event.event_type()) {
            return;
        }
        let now = self.host.now_ms();
        let Some(driver) = self.drivers.get_mut(session_id) else {
            return;
        };
        match driver.terminals.apply_event(event, now) {
            Ok(_) => self.publish_terminals(session_id),
            Err(error) => {
                self.error(
                    ErrorScope::Session {
                        session_id: session_id.to_owned(),
                    },
                    CoreError::Sync {
                        message: error.to_string(),
                    },
                );
                self.refresh_terminals(session_id);
            }
        }
    }

    /// Publishes the session's terminals when they or the harness view changed, and schedules
    /// the next activity-badge lapse.
    pub(crate) fn publish_terminals(&mut self, session_id: &str) {
        let now = self.host.now_ms();
        let terminal_first = self
            .sessions
            .cached_summary(session_id)
            .is_some_and(|summary| summary.terminal_first);
        let Some(driver) = self.drivers.get_mut(session_id) else {
            return;
        };
        let rows = driver.terminals.rows(now);
        let harness = harness_of(
            &driver.terminals,
            terminal_first,
            driver.sync.terminal_pending_raw(),
        );
        if let Some(tick) = driver.terminal_tick.take() {
            tick.abort();
        }
        if let Some(expiry) = driver.terminals.next_activity_expiry(now) {
            let tx = self.tx.clone();
            let id = session_id.to_owned();
            driver.terminal_tick = Some(self.host.after(expiry.saturating_sub(now), move || {
                post(&tx, Msg::TerminalTick { session_id: id });
            }));
        }
        let view = (rows, harness);
        if driver.terminal_view.as_ref() == Some(&view) {
            return;
        }
        driver.terminal_view = Some(view.clone());
        let (rows, harness) = view;
        self.emit(terminals_event(session_id, rows, harness));
    }

    /// Reads the session's terminals in the background.
    pub(crate) fn refresh_terminals(&self, session_id: &str) {
        if !self.is_connected() || self.is_demo() {
            return;
        }
        let sessions = Arc::clone(&self.sessions);
        let tx = self.sender();
        let id = session_id.to_owned();
        self.host.spawn(async move {
            let result = sessions.list_terminals(&id).await;
            post(
                &tx,
                Msg::TerminalsListed {
                    session_id: id,
                    result,
                },
            );
        });
    }

    /// A list read finished.
    pub(crate) fn terminals_listed(
        &mut self,
        session_id: &str,
        result: Result<Vec<TerminalResource>, omnigent_core::terminal::TerminalError>,
    ) {
        match result {
            Ok(terminals) => self.terminals_loaded(session_id, terminals),
            Err(error) => self.error(
                ErrorScope::Session {
                    session_id: session_id.to_owned(),
                },
                terminal_error(error),
            ),
        }
    }

    /// Replaces an open session's inventory with an authoritative list.
    pub(crate) fn terminals_loaded(&mut self, session_id: &str, terminals: Vec<TerminalResource>) {
        if let Some(driver) = self.drivers.get_mut(session_id) {
            driver.terminals.apply_snapshot(terminals);
            self.publish_terminals(session_id);
        }
    }

    /// A terminal this client created or learned about.
    pub(crate) fn terminal_upserted(&mut self, session_id: &str, terminal: TerminalResource) {
        if let Some(driver) = self.drivers.get_mut(session_id) {
            driver.terminals.upsert(terminal);
            self.publish_terminals(session_id);
        }
    }

    /// A terminal this client deleted.
    pub(crate) fn terminal_removed(&mut self, session_id: &str, terminal_id: &str) {
        if let Some(driver) = self.drivers.get_mut(session_id) {
            driver.terminals.remove(terminal_id);
            self.publish_terminals(session_id);
        }
    }

    /// After a successful history read: publish the harness view, and read the terminals of a
    /// terminal-first session.
    pub(crate) fn terminals_after_hydration(&mut self, session_id: &str) {
        self.publish_terminals(session_id);
        let terminal_first = self
            .sessions
            .cached_summary(session_id)
            .is_some_and(|summary| summary.terminal_first);
        if terminal_first {
            self.refresh_terminals(session_id);
        }
    }
}
