//! A session's terminal list, kept current from REST snapshots and stream events.
//!
//! Two sources feed it, as in `web/src/hooks/useTerminals.ts`:
//!
//! - the authoritative list (`GET …/resources/terminals?order=asc`), applied with
//!   [`TerminalInventory::apply_snapshot`] on open and after a stream reconnect;
//! - live `session.resource.created` / `session.resource.deleted` events for terminal resources
//!   and `session.terminal.activity` pulses, applied with [`TerminalInventory::apply_event`].
//!
//! Activity is a transient pulse (not persisted, not replayed on connect). A terminal counts as
//! active for [`ACTIVITY_WINDOW_MS`] after its last pulse; the caller re-reads
//! [`TerminalInventory::rows`] when that window lapses (see
//! [`TerminalInventory::next_activity_expiry`]).

use std::collections::BTreeMap;

use omnigent_protocol::ServerStreamEvent;

use super::resource::TerminalResource;

/// How long a terminal reads as active after an activity pulse, in ms. The web client's idle
/// inference uses the same 1.5 s.
pub const ACTIVITY_WINDOW_MS: u64 = 1_500;

/// The badge a terminal row shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalStatus {
    /// Running, with output in the last [`ACTIVITY_WINDOW_MS`].
    Active,
    /// Running and quiet.
    Idle,
    /// The runner reports the tmux session is not running.
    Exited,
    /// The runner did not say whether it is running.
    Unknown,
}

/// One row of the list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalRow {
    /// The terminal.
    pub resource: TerminalResource,
    /// Its badge.
    pub status: TerminalStatus,
}

/// Why a stream event could not be applied.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum InventoryError {
    /// A `session.resource.created` event for a terminal whose resource is malformed.
    #[error("terminal resource in session.resource.created is malformed: {message}")]
    MalformedResource {
        /// The decoder's message.
        message: String,
    },
}

/// The terminals of one session. See the [module docs](self).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalInventory {
    session_id: String,
    terminals: Vec<TerminalResource>,
    activity: BTreeMap<String, u64>,
}

impl TerminalInventory {
    /// An empty inventory for `session_id`.
    pub fn new(session_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            terminals: Vec::new(),
            activity: BTreeMap::new(),
        }
    }

    /// The session.
    #[must_use]
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// The terminals, in creation order.
    #[must_use]
    pub fn terminals(&self) -> &[TerminalResource] {
        &self.terminals
    }

    /// The terminal with `id`.
    #[must_use]
    pub fn get(&self, id: &str) -> Option<&TerminalResource> {
        self.terminals.iter().find(|terminal| terminal.id == id)
    }

    /// Replaces the list with an authoritative snapshot, keeping activity pulses for terminals
    /// that are still present.
    pub fn apply_snapshot(&mut self, terminals: Vec<TerminalResource>) {
        self.terminals = Vec::with_capacity(terminals.len());
        for terminal in terminals {
            self.upsert(terminal);
        }
        let ids: Vec<String> = self.terminals.iter().map(|t| t.id.clone()).collect();
        self.activity.retain(|id, _| ids.contains(id));
    }

    /// Adds `terminal`, or replaces the row with the same id in place.
    pub fn upsert(&mut self, terminal: TerminalResource) {
        if let Some(existing) = self.terminals.iter_mut().find(|t| t.id == terminal.id) {
            *existing = terminal;
        } else {
            self.terminals.push(terminal);
        }
    }

    /// Removes the terminal with `id`. Returns whether it was present.
    pub fn remove(&mut self, id: &str) -> bool {
        self.activity.remove(id);
        let before = self.terminals.len();
        self.terminals.retain(|terminal| terminal.id != id);
        before != self.terminals.len()
    }

    /// Applies one stream event at `now_ms`. Returns whether the list or a badge may have
    /// changed. Events for other resource types or other sessions return `Ok(false)`.
    ///
    /// # Errors
    ///
    /// [`InventoryError::MalformedResource`] for a terminal creation whose resource cannot be
    /// decoded. The inventory is unchanged; refetch the list.
    pub fn apply_event(
        &mut self,
        event: &ServerStreamEvent,
        now_ms: u64,
    ) -> Result<bool, InventoryError> {
        match event {
            ServerStreamEvent::SessionResourceCreated(created) => {
                let is_terminal = created
                    .resource
                    .get("type")
                    .and_then(serde_json::Value::as_str)
                    == Some("terminal");
                if !is_terminal || created.session_id().is_some_and(|id| id != self.session_id) {
                    return Ok(false);
                }
                let terminal =
                    TerminalResource::decode(serde_json::Value::Object(created.resource.clone()))
                        .map_err(|message| InventoryError::MalformedResource { message })?;
                self.upsert(terminal);
                Ok(true)
            }
            ServerStreamEvent::SessionResourceDeleted(deleted) => {
                let other_type = deleted
                    .resource_type
                    .as_deref()
                    .is_some_and(|kind| kind != "terminal");
                let other_session = deleted
                    .session_id
                    .as_deref()
                    .is_some_and(|id| id != self.session_id);
                if other_type || other_session {
                    return Ok(false);
                }
                Ok(self.remove(&deleted.resource_id))
            }
            ServerStreamEvent::SessionTerminalActivity(activity) => {
                if activity.terminal_id.is_empty()
                    || activity
                        .session_id
                        .as_deref()
                        .is_some_and(|id| id != self.session_id)
                {
                    return Ok(false);
                }
                self.activity.insert(activity.terminal_id.clone(), now_ms);
                Ok(true)
            }
            _ => Ok(false),
        }
    }

    /// The badge for `terminal` at `now_ms`.
    #[must_use]
    pub fn status(&self, terminal: &TerminalResource, now_ms: u64) -> TerminalStatus {
        match terminal.running {
            Some(false) => TerminalStatus::Exited,
            running => {
                let active = self
                    .activity
                    .get(&terminal.id)
                    .is_some_and(|at| now_ms.saturating_sub(*at) < ACTIVITY_WINDOW_MS);
                match (active, running) {
                    (true, _) => TerminalStatus::Active,
                    (false, Some(true)) => TerminalStatus::Idle,
                    (false, _) => TerminalStatus::Unknown,
                }
            }
        }
    }

    /// Every terminal with its badge at `now_ms`.
    #[must_use]
    pub fn rows(&self, now_ms: u64) -> Vec<TerminalRow> {
        self.terminals
            .iter()
            .map(|resource| TerminalRow {
                resource: resource.clone(),
                status: self.status(resource, now_ms),
            })
            .collect()
    }

    /// The user's shells: every terminal except the agent's own.
    #[must_use]
    pub fn user_shells(&self, now_ms: u64) -> Vec<TerminalRow> {
        self.rows(now_ms)
            .into_iter()
            .filter(|row| !row.resource.is_agent_terminal())
            .collect()
    }

    /// When the earliest active badge lapses, as an absolute `now_ms`, if any is active.
    #[must_use]
    pub fn next_activity_expiry(&self, now_ms: u64) -> Option<u64> {
        self.activity
            .values()
            .map(|at| at.saturating_add(ACTIVITY_WINDOW_MS))
            .filter(|expiry| *expiry > now_ms)
            .min()
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn terminal(id: &str, running: Option<bool>) -> TerminalResource {
        let mut metadata = serde_json::Map::new();
        if let Some(running) = running {
            metadata.insert("running".into(), json!(running));
        }
        TerminalResource::decode(json!({"id": id, "type": "terminal", "session_id": "conv_1",
            "metadata": metadata}))
        .unwrap()
    }

    fn event(value: serde_json::Value) -> ServerStreamEvent {
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn an_inventory_knows_its_session() {
        assert_eq!(TerminalInventory::new("conv_a").session_id(), "conv_a");
    }

    #[test]
    fn events_add_remove_and_pulse_terminals() {
        let mut inventory = TerminalInventory::new("conv_1");
        inventory.apply_snapshot(vec![terminal("terminal_claude_main", Some(true))]);
        let created = event(json!({"type": "session.resource.created", "resource": {
            "id": "terminal_zsh_u-1", "type": "terminal", "session_id": "conv_1",
            "name": "zsh:u-1", "metadata": {"running": true}}}));
        assert_eq!(inventory.apply_event(&created, 0), Ok(true));
        assert_eq!(
            inventory.apply_event(&created, 0),
            Ok(true),
            "idempotent upsert"
        );
        assert_eq!(inventory.terminals().len(), 2);
        assert_eq!(inventory.user_shells(0).len(), 1);

        let pulse = event(
            json!({"type": "session.terminal.activity", "session_id": "conv_1",
            "terminal_id": "terminal_zsh_u-1"}),
        );
        assert_eq!(inventory.apply_event(&pulse, 10_000), Ok(true));
        let shell = inventory.get("terminal_zsh_u-1").unwrap().clone();
        assert_eq!(inventory.status(&shell, 10_000), TerminalStatus::Active);
        assert_eq!(inventory.next_activity_expiry(10_000), Some(11_500));
        assert_eq!(inventory.status(&shell, 11_500), TerminalStatus::Idle);
        assert_eq!(inventory.next_activity_expiry(11_500), None);

        let deleted = event(json!({"type": "session.resource.deleted",
            "resource_id": "terminal_zsh_u-1", "resource_type": "terminal",
            "session_id": "conv_1"}));
        assert_eq!(inventory.apply_event(&deleted, 0), Ok(true));
        assert_eq!(inventory.terminals().len(), 1);
        assert_eq!(inventory.apply_event(&deleted, 0), Ok(false));
    }

    #[test]
    fn other_sessions_and_types_are_ignored() {
        let mut inventory = TerminalInventory::new("conv_1");
        for value in [
            json!({"type": "session.resource.created", "resource": {"id": "f1", "type": "file"}}),
            json!({"type": "session.resource.created", "resource": {"id": "t1", "type": "terminal",
                "session_id": "conv_2"}}),
            json!({"type": "session.resource.deleted", "resource_id": "t1",
                "resource_type": "environment"}),
            json!({"type": "session.terminal.activity", "session_id": "conv_2", "terminal_id": "t1"}),
            json!({"type": "session.heartbeat"}),
        ] {
            assert_eq!(
                inventory.apply_event(&event(value.clone()), 0),
                Ok(false),
                "{value}"
            );
        }
        assert_eq!(inventory.terminals(), []);
        let bad = event(
            json!({"type": "session.resource.created", "resource": {"id": "a/b",
            "type": "terminal"}}),
        );
        assert!(inventory.apply_event(&bad, 0).is_err());
    }

    #[test]
    fn badges_and_snapshots() {
        let mut inventory = TerminalInventory::new("conv_1");
        inventory.apply_snapshot(vec![
            terminal("t1", Some(false)),
            terminal("t2", None),
            terminal("t2", Some(true)),
        ]);
        let rows = inventory.rows(0);
        assert_eq!(rows.len(), 2, "duplicate ids collapse");
        assert_eq!(rows[0].status, TerminalStatus::Exited);
        assert_eq!(rows[1].status, TerminalStatus::Idle);
        let pulse = event(json!({"type": "session.terminal.activity", "terminal_id": "t1"}));
        inventory.apply_event(&pulse, 0).unwrap();
        assert_eq!(
            inventory.rows(0)[0].status,
            TerminalStatus::Exited,
            "exit wins"
        );
        inventory.apply_snapshot(vec![terminal("t2", None)]);
        assert_eq!(inventory.rows(0)[0].status, TerminalStatus::Unknown);
        assert_eq!(
            inventory.next_activity_expiry(0),
            None,
            "pulses for gone rows drop"
        );
    }
}
