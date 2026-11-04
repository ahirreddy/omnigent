//! The header's Agent info: the session agent's MCP servers and the policies the session runs
//! under (`GET /v1/agents/{id}` and `GET /v1/sessions/{id}/policies`).

use serde_json::Value;

use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// What the Agent info popover lists.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AgentInfo {
    /// The agent's name.
    pub name: String,
    /// Its MCP servers, by name.
    pub tools: Vec<String>,
    /// The policies the session runs under (admin, agent and session), by name.
    pub policies: Vec<String>,
}

fn names(value: Option<&Value>, what: &str, path: &str) -> Result<Vec<String>, SessionError> {
    let malformed = |detail: String| SessionError::MalformedResponse {
        detail: format!("{path}: {detail}"),
    };
    let Some(value) = value else {
        return Ok(Vec::new());
    };
    let entries = value
        .as_array()
        .ok_or_else(|| malformed(format!("`{what}` is not an array")))?;
    let mut result: Vec<String> = Vec::new();
    for entry in entries {
        let name = entry
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| malformed(format!("a `{what}` entry has no name")))?;
        if !result.iter().any(|seen| seen == name) {
            result.push(name.to_owned());
        }
    }
    Ok(result)
}

impl<T: HttpTransport> ClientCore<T> {
    /// The Agent info of `session_id`, whose agent is `agent_id`. A server without the session
    /// policies route (HTTP 404 there) lists no policies.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; the read errors;
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn agent_info(
        &self,
        session_id: &str,
        agent_id: &str,
    ) -> Result<AgentInfo, SessionError> {
        let result = self.read_agent_info(session_id, agent_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn read_agent_info(
        &self,
        session_id: &str,
        agent_id: &str,
    ) -> Result<AgentInfo, SessionError> {
        validate_identifier(session_id)?;
        validate_identifier(agent_id)?;
        let agent_path = format!("/v1/agents/{agent_id}");
        let agent = self.get_json(&agent_path, &[]).await?;
        let name = agent
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| SessionError::MalformedResponse {
                detail: format!("{agent_path}: `name` is missing"),
            })?
            .to_owned();
        let tools = names(agent.get("mcp_servers"), "mcp_servers", &agent_path)?;
        let policies_path = format!("/v1/sessions/{session_id}/policies");
        let policies = match self.get_json(&policies_path, &[]).await {
            Ok(list) => names(list.get("data"), "data", &policies_path)?,
            Err(SessionError::HttpStatus { status: 404 }) => Vec::new(),
            Err(error) => return Err(error),
        };
        Ok(AgentInfo {
            name,
            tools,
            policies,
        })
    }
}
