//! A started session's `/mcp` panel, reconnecting one of its live MCP servers, and closing a
//! `/btw` answer.

use omnigent_core::session_mcp as core;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// A `/mcp` row's account state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum McpAccount {
    /// Connected.
    Connected,
    /// Signing in is needed.
    SignInRequired,
    /// The account no longer sees this registry service.
    Unavailable,
}

/// How a `/mcp` row signs in.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum McpSignIn {
    /// On a page the host named.
    Url {
        /// The page.
        url: String,
    },
    /// The registry service's own sign-in; `typed` when a token or workspace URL is typed.
    Registry {
        /// The service.
        service_id: String,
        /// It takes a token or workspace URL.
        typed: bool,
    },
}

/// A `/mcp` row's connection in the running session.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct McpLiveState {
    /// `connected`, `failed`, `needs-auth`, `pending`, `disabled`, `not-loaded`, or another
    /// status as the harness says it.
    pub status: String,
    /// Why it failed.
    pub error: Option<String>,
}

/// One `/mcp` row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct McpPanelRow {
    /// Unique among the rows.
    pub key: String,
    /// The server's name.
    pub name: String,
    /// Its plugin and URL host, or what it does.
    pub description: Option<String>,
    /// Its account state.
    pub account: Option<McpAccount>,
    /// How it signs in.
    pub sign_in: Option<McpSignIn>,
    /// Its connection in the session.
    pub live: Option<McpLiveState>,
    /// The harness's name for it, for Reconnect.
    pub live_name: Option<String>,
}

/// The `/mcp` panel.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct McpPanel {
    /// Its rows.
    pub rows: Vec<McpPanelRow>,
    /// Why rows may be missing, or where live status comes from.
    pub status: Option<String>,
    /// Read again after this many milliseconds.
    pub poll_after_ms: Option<u32>,
    /// The harness whose settings "Go to Settings" opens; `None` opens the harness list.
    #[uniffi(default)]
    pub settings_harness: Option<String>,
    /// The host those settings show.
    #[uniffi(default)]
    pub settings_host_id: Option<String>,
}

impl From<core::McpPanelRow> for McpPanelRow {
    fn from(row: core::McpPanelRow) -> Self {
        Self {
            key: row.key,
            name: row.name,
            description: row.description,
            account: row.account.map(|account| match account {
                core::McpAccount::Connected => McpAccount::Connected,
                core::McpAccount::SignInRequired => McpAccount::SignInRequired,
                core::McpAccount::Unavailable => McpAccount::Unavailable,
            }),
            sign_in: row.sign_in.map(|sign_in| match sign_in {
                core::McpSignIn::Url(url) => McpSignIn::Url { url },
                core::McpSignIn::Registry { service_id, typed } => {
                    McpSignIn::Registry { service_id, typed }
                }
            }),
            live: row.live.map(|live| McpLiveState {
                status: live.status,
                error: live.error,
            }),
            live_name: row.live_name,
        }
    }
}

#[uniffi::export]
impl ClientCore {
    /// The `/mcp` panel for `session_id`, whose agent, harness and routing host are as given;
    /// sources that can't be read become its status.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` before any request.
    pub async fn session_mcp_panel(
        &self,
        session_id: String,
        agent_id: Option<String>,
        harness: Option<String>,
        host_id: Option<String>,
    ) -> Result<McpPanel, CoreError> {
        let panel = self
            .sessions()
            .session_mcp_panel(core::McpPanelSession {
                session_id: &session_id,
                agent_id: agent_id.as_deref(),
                harness: harness.as_deref(),
                host_id: host_id.as_deref(),
            })
            .await
            .map_err(CoreError::from)?;
        Ok(McpPanel {
            rows: panel.rows.into_iter().map(Into::into).collect(),
            status: panel.status,
            poll_after_ms: panel.poll_after_ms,
            settings_harness: panel.settings_harness,
            settings_host_id: panel.settings_host_id,
        })
    }

    /// Tells `session_id`'s terminal that its `/btw` answer was closed here.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` and the write errors.
    pub async fn dismiss_quick_answer(&self, session_id: String) -> Result<(), CoreError> {
        self.sessions()
            .dismiss_quick_answer(&session_id)
            .await
            .map_err(CoreError::from)
    }

    /// Reconnects `session_id`'s live MCP server `name`; the harness's reason when it refused.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` and the write errors (`Rejected` carries the
    /// server's message).
    pub async fn reconnect_live_mcp_server(
        &self,
        session_id: String,
        name: String,
    ) -> Result<Option<String>, CoreError> {
        self.sessions()
            .reconnect_live_mcp_server(&session_id, &name)
            .await
            .map_err(CoreError::from)
    }
}
