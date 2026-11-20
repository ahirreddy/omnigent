//! A started session's `/mcp` panel, as the web's composer builds it.
//!
//! It reads the agent's servers (`GET /v1/agents/{id}`), the host's servers for the session's
//! harness (`GET /v1/hosts/{id}/mcp-servers`), the registry's account state
//! (`GET /v1/mcp-registry/services`) and, for claude-sdk, the connections its CLI holds
//! (`GET /v1/sessions/{id}/live-mcp-servers`, reconnected with `POST …/reconnect`).

use serde_json::{Value, json};

use super::harness_inventory::inventory_family;
use super::json::{as_object, opt_array, opt_bool, opt_str, req_str};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

pub use super::session_mcp_rows::{
    McpAccount, McpLive, McpPanel, McpPanelRow, McpPanelSources, McpSignIn, SourceRead,
    live_name_for_host_server, mcp_panel,
};

/// One MCP server the session's agent declares.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentMcpServer {
    /// Its name.
    pub name: String,
    /// What it does.
    pub description: Option<String>,
    /// `stdio`, `http` or `registry`.
    pub transport: String,
}

/// The session agent's MCP servers and whether a claude-sdk session loads user settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentMcp {
    /// Its servers.
    pub servers: Vec<AgentMcpServer>,
    /// `false` for an agent with `skills: none`, whose claude-sdk sessions load only managed
    /// servers.
    pub loads_user_settings: bool,
}

/// One MCP server as the session's running harness reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveMcpServer {
    /// The harness's name; plugin servers read `plugin:<plugin>:<server>`.
    pub name: String,
    /// `connected`, `failed`, `needs-auth`, `pending` or `disabled`; others pass through.
    pub status: String,
    /// Why it failed.
    pub error: Option<String>,
}

/// What the session's harness said about its MCP connections.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveMcpRead {
    /// It answered with these.
    Live(Vec<LiveMcpServer>),
    /// It has not started.
    NotRunning,
    /// It can't report them, or the server predates the route.
    Unsupported,
    /// It could not be asked, with the server's reason.
    Unavailable(Option<String>),
}

/// The session a panel describes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct McpPanelSession<'a> {
    /// The session.
    pub session_id: &'a str,
    /// Its agent, when known.
    pub agent_id: Option<&'a str>,
    /// Its harness, when known.
    pub harness: Option<&'a str>,
    /// The host it routes to, when known.
    pub host_id: Option<&'a str>,
}

fn read<T>(answer: Result<T, SessionError>) -> SourceRead<T> {
    answer.map_or(SourceRead::Failed, SourceRead::Loaded)
}

fn malformed(path: &str) -> impl Fn(String) -> SessionError + '_ {
    move |detail| SessionError::MalformedResponse {
        detail: format!("{path}: {detail}"),
    }
}

fn agent_mcp_from(value: &Value) -> Result<AgentMcp, String> {
    let object = as_object(value, "agent")?;
    let servers = opt_array(object, "mcp_servers")?
        .into_iter()
        .flatten()
        .map(|entry| {
            let entry = as_object(entry, "MCP server")?;
            Ok(AgentMcpServer {
                name: req_str(entry, "name")?,
                description: opt_str(entry, "description")?.filter(|text| !text.is_empty()),
                transport: opt_str(entry, "transport")?.unwrap_or_default(),
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok(AgentMcp {
        servers,
        loads_user_settings: opt_bool(object, "loads_user_settings")?.unwrap_or(true),
    })
}

/// Decodes a live read's answer.
///
/// # Errors
///
/// A description of the first field with the wrong shape.
pub fn live_mcp_read_from(value: &Value) -> Result<LiveMcpRead, String> {
    let object = as_object(value, "live MCP servers")?;
    if opt_bool(object, "live")? != Some(true) {
        return Ok(match opt_str(object, "reason")?.as_deref() {
            Some("not_running") => LiveMcpRead::NotRunning,
            Some("unavailable") => {
                LiveMcpRead::Unavailable(opt_str(object, "detail")?.filter(|text| !text.is_empty()))
            }
            _ => LiveMcpRead::Unsupported,
        });
    }
    let servers = opt_array(object, "servers")?
        .into_iter()
        .flatten()
        .map(|entry| {
            let entry = as_object(entry, "server")?;
            Ok(LiveMcpServer {
                name: req_str(entry, "name")?,
                status: req_str(entry, "status")?,
                error: opt_str(entry, "error")?.filter(|text| !text.is_empty()),
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok(LiveMcpRead::Live(servers))
}

impl<T: HttpTransport> ClientCore<T> {
    /// The `/mcp` panel for `session`. A source that can't be read becomes the panel's status,
    /// as on the web.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn session_mcp_panel(
        &self,
        session: McpPanelSession<'_>,
    ) -> Result<McpPanel, SessionError> {
        validate_identifier(session.session_id)?;
        let claude_sdk = session.harness == Some("claude-sdk");
        // claude-sdk runs the Claude Code CLI, so on a host it lists the host's Claude servers.
        let host_family = if claude_sdk {
            session.host_id.map(|_| "claude")
        } else {
            session.harness.and_then(inventory_family)
        };
        let agent = match session.agent_id {
            Some(agent_id) => Some(read(self.agent_mcp(agent_id).await)),
            None => None,
        };
        let host = match (host_family, session.host_id) {
            (Some(_), Some(host_id)) => Some(read(self.host_mcp_servers(host_id).await)),
            _ => None,
        };
        let has_registry = matches!(&agent, Some(SourceRead::Loaded(agent))
            if agent.servers.iter().any(|server| server.transport == "registry"));
        let registry = if has_registry {
            match self.mcp_services().await {
                // A server without the registry has no account state to show.
                Err(SessionError::HttpStatus { status: 404 }) => None,
                answer => Some(read(answer)),
            }
        } else {
            None
        };
        let live = if claude_sdk {
            Some(read(self.live_mcp_servers(session.session_id).await))
        } else {
            None
        };
        Ok(mcp_panel(&McpPanelSources {
            host_family: host_family.map(str::to_owned),
            has_host: session.host_id.is_some(),
            claude_sdk,
            agent,
            host,
            registry,
            live,
        }))
    }

    /// Reconnects the session harness's MCP server `name`; `Ok(Some(reason))` when the harness
    /// refused.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`]; the write errors (`Rejected` carries the server's
    /// message: not running, unknown server, or a harness that can't reconnect).
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn reconnect_live_mcp_server(
        &self,
        session_id: &str,
        name: &str,
    ) -> Result<Option<String>, SessionError> {
        let result = async {
            validate_identifier(session_id)?;
            let path = format!("/v1/sessions/{session_id}/live-mcp-servers/reconnect");
            let answer = self
                .write_json("POST", &path, &json!({ "name": name }))
                .await?;
            Ok(answer
                .get("reconnect_error")
                .and_then(Value::as_str)
                .filter(|text| !text.is_empty())
                .map(str::to_owned))
        }
        .await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn agent_mcp(&self, agent_id: &str) -> Result<AgentMcp, SessionError> {
        validate_identifier(agent_id)?;
        let path = format!("/v1/agents/{agent_id}");
        let value = self.get_json(&path, &[]).await?;
        agent_mcp_from(&value).map_err(malformed(&path))
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn live_mcp_servers(&self, session_id: &str) -> Result<LiveMcpRead, SessionError> {
        let path = format!("/v1/sessions/{session_id}/live-mcp-servers");
        match self.get_json(&path, &[]).await {
            Ok(value) => live_mcp_read_from(&value).map_err(malformed(&path)),
            // A server without the route keeps the inventory-only view.
            Err(SessionError::HttpStatus { status: 404 }) => Ok(LiveMcpRead::Unsupported),
            Err(error) => Err(error),
        }
    }
}

#[cfg(test)]
#[path = "session_mcp_tests.rs"]
mod tests;
