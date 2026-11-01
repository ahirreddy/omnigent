//! The session's own (harness) terminal: discovery and attach permissions.
//!
//! Native-harness sessions (Claude Code, Codex, Pi, ... launched through `omnigent claude` and
//! friends) and SDK sessions with the embedded Omnigent REPL run their real TUI in a tmux pane
//! on the host. That pane is an ordinary terminal resource with a well-known id
//! ([`super::AGENT_TERMINAL_IDS`], for example `terminal_claude_main`), attached through the same
//! `/resources/terminals/{id}/attach` socket as user shells. The web client derives the
//! Chat/Terminal switcher from exactly these facts (`web/src/shell/AppShell.tsx`):
//!
//! - the session is *terminal-first* when its labels carry `omnigent.ui = terminal`;
//! - the Terminal view targets the first agent terminal in the session's terminal list;
//! - while there is none yet, the view is *starting* if the runner reported
//!   `terminal_pending` (snapshot field, or the `session.terminal_pending` event);
//! - an interactive attach needs owner access (`permission_level` 4, or no permission store);
//!   anyone else attaches read-only.

use std::collections::BTreeMap;

use super::inventory::TerminalInventory;
use super::resource::TerminalResource;
use super::rest::AttachOptions;

/// The session label that marks a terminal-first session.
pub const TERMINAL_UI_LABEL: &str = "omnigent.ui";
/// Its value.
pub const TERMINAL_UI_VALUE: &str = "terminal";
/// The permission level that may type into a shared PTY (`LEVEL_OWNER` in
/// `omnigent/server/auth.py`).
pub const OWNER_LEVEL: i64 = 4;

/// Whether a session with `labels` shows its harness TUI (a Chat/Terminal switcher).
#[must_use]
pub fn is_terminal_first(labels: &BTreeMap<String, String>) -> bool {
    labels.get(TERMINAL_UI_LABEL).map(String::as_str) == Some(TERMINAL_UI_VALUE)
}

/// Whether the caller may attach interactively. `None` means permissions are disabled
/// (single-user), where the caller is the owner.
#[must_use]
pub const fn can_type(permission_level: Option<i64>) -> bool {
    match permission_level {
        None => true,
        Some(level) => level >= OWNER_LEVEL,
    }
}

/// The attach options for a caller with `permission_level` on a session hosted by `host_id`.
#[must_use]
pub fn attach_options(permission_level: Option<i64>, host_id: Option<&str>) -> AttachOptions {
    AttachOptions {
        read_only: !can_type(permission_level),
        slice_key: host_id.filter(|id| !id.is_empty()).map(str::to_owned),
    }
}

/// What the session's Terminal view can show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HarnessTerminal {
    /// Not a terminal-first session: there is no Terminal view.
    NotTerminalFirst,
    /// Terminal-first, and the runner is creating the pane.
    StartingUp,
    /// Terminal-first, and the pane is not there (the runner is stopped or the pane exited).
    /// Show the stopped state with a Resume action.
    Unavailable,
    /// The pane to attach to.
    Ready {
        /// The agent terminal resource.
        terminal: TerminalResource,
    },
}

impl TerminalInventory {
    /// The session's agent terminal, if listed.
    #[must_use]
    pub fn agent_terminal(&self) -> Option<&TerminalResource> {
        self.terminals()
            .iter()
            .find(|terminal| terminal.is_agent_terminal())
    }

    /// What a session with `labels` and the runner's `terminal_pending` flag can show in its
    /// Terminal view.
    #[must_use]
    pub fn harness_terminal(
        &self,
        labels: &BTreeMap<String, String>,
        terminal_pending: bool,
    ) -> HarnessTerminal {
        if !is_terminal_first(labels) {
            return HarnessTerminal::NotTerminalFirst;
        }
        match self.agent_terminal() {
            Some(terminal) => HarnessTerminal::Ready {
                terminal: terminal.clone(),
            },
            None if terminal_pending => HarnessTerminal::StartingUp,
            None => HarnessTerminal::Unavailable,
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn labels(value: Option<&str>) -> BTreeMap<String, String> {
        value
            .map(|value| BTreeMap::from([(TERMINAL_UI_LABEL.to_owned(), value.to_owned())]))
            .unwrap_or_default()
    }

    #[test]
    fn discovers_the_harness_terminal_like_the_web_client() {
        let mut inventory = TerminalInventory::new("conv_1");
        assert_eq!(
            inventory.harness_terminal(&labels(None), true),
            HarnessTerminal::NotTerminalFirst
        );
        assert_eq!(
            inventory.harness_terminal(&labels(Some("chat")), true),
            HarnessTerminal::NotTerminalFirst
        );
        let terminal_first = labels(Some("terminal"));
        assert_eq!(
            inventory.harness_terminal(&terminal_first, true),
            HarnessTerminal::StartingUp
        );
        assert_eq!(
            inventory.harness_terminal(&terminal_first, false),
            HarnessTerminal::Unavailable
        );
        let shell = TerminalResource::decode(json!({"id": "terminal_zsh_u-1"})).unwrap();
        let tui = TerminalResource::decode(json!({"id": "terminal_codex_main"})).unwrap();
        inventory.apply_snapshot(vec![shell, tui.clone()]);
        assert_eq!(
            inventory.harness_terminal(&terminal_first, false),
            HarnessTerminal::Ready { terminal: tui }
        );
    }

    #[test]
    fn only_owners_type() {
        assert!(can_type(None));
        assert!(can_type(Some(4)));
        assert!(!can_type(Some(3)));
        assert!(!can_type(Some(1)));
        assert_eq!(
            attach_options(Some(2), Some("host_1")),
            AttachOptions {
                read_only: true,
                slice_key: Some("host_1".into())
            }
        );
        assert_eq!(attach_options(None, Some("")), AttachOptions::default());
    }
}
