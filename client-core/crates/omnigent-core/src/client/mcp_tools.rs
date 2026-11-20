//! An MCP server's tools as its host probes them, for the harness page's MCP rows.
//!
//! `POST /v1/hosts/{id}/mcp-servers/tools` asks the host to connect to one configured server
//! and list its tools; the web's `useMcpServerTools`.

use serde_json::{Map, Value, json};

use super::json::{as_object, opt_array, opt_bool, opt_str, req_str};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// How the host's connection to the MCP server went.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum McpConnection {
    /// It answered with its tools.
    Connected,
    /// It needs a sign-in the harness's credentials can't stand in for.
    NeedsAuth,
    /// It couldn't be reached.
    Unreachable,
    /// It didn't answer in time.
    Timeout,
    /// Its configuration can't be probed from the host.
    Unsupported,
}

/// One tool an MCP server offers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpTool {
    /// Its name.
    pub name: String,
    /// What it does.
    pub description: Option<String>,
}

/// What the probe found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpServerTools {
    /// The tools, in the server's order.
    pub tools: Vec<McpTool>,
    /// How the connection went.
    pub connection: McpConnection,
    /// The host listed only the first 500.
    pub truncated: bool,
}

/// The probe's outcome, or why the host couldn't probe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpToolsRead {
    /// The host probed the server.
    Probed(McpServerTools),
    /// The server has no probe route (`404`): rows stay static.
    RouteMissing,
    /// The host predates the probe (`501`).
    HostOutdated,
    /// The host is busy probing other servers (`503`).
    Busy,
}

impl McpServerTools {
    /// Decodes the probe's answer.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "MCP tools")?;
        let connection = match opt_str(object, "connection")?.as_deref() {
            Some("connected") => McpConnection::Connected,
            Some("needs_auth") => McpConnection::NeedsAuth,
            Some("timeout") => McpConnection::Timeout,
            Some("unsupported") => McpConnection::Unsupported,
            _ => McpConnection::Unreachable,
        };
        let tools = opt_array(object, "tools")?
            .into_iter()
            .flatten()
            .map(|tool| {
                let tool = as_object(tool, "tool")?;
                Ok(McpTool {
                    name: req_str(tool, "name")?,
                    description: opt_str(tool, "description")?
                        .filter(|text| !text.trim().is_empty()),
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        Ok(Self {
            tools,
            connection,
            truncated: opt_bool(object, "truncated")?.unwrap_or(false),
        })
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// Asks `host_id` to connect to `harness`'s MCP server `server` (shipped by `plugin`, with
    /// the plugin entry `source_id`) and list its tools.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`], the read errors and `MalformedResponse`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn mcp_server_tools(
        &self,
        host_id: &str,
        harness: &str,
        server: &str,
        plugin: Option<&str>,
        source_id: Option<&str>,
    ) -> Result<McpToolsRead, SessionError> {
        let result = async {
            validate_identifier(host_id)?;
            let path = format!("/v1/hosts/{host_id}/mcp-servers/tools");
            let mut body = Map::new();
            body.insert("harness".to_owned(), json!(harness));
            body.insert("server".to_owned(), json!(server));
            if let Some(plugin) = plugin {
                body.insert("plugin".to_owned(), json!(plugin));
            }
            if let Some(source_id) = source_id {
                body.insert("source_id".to_owned(), json!(source_id));
            }
            let prepared = self.prepare("POST", &path, &[], Some(&Value::Object(body)))?;
            match self.read(prepared).await {
                Ok(response) => serde_json::from_slice::<Value>(&response.body)
                    .map_err(|error| error.to_string())
                    .and_then(|value| McpServerTools::from_value(&value))
                    .map(McpToolsRead::Probed)
                    .map_err(|detail| SessionError::MalformedResponse {
                        detail: format!("{path}: {detail}"),
                    }),
                Err(SessionError::HttpStatus { status: 404 }) => Ok(McpToolsRead::RouteMissing),
                Err(SessionError::HttpStatus { status: 501 }) => Ok(McpToolsRead::HostOutdated),
                Err(SessionError::HttpStatus { status: 503 }) => Ok(McpToolsRead::Busy),
                Err(error) => Err(error),
            }
        }
        .await;
        self.dispatch();
        result
    }
}
