//! Custom agents: the create form, installing a bundle, and the Settings list, configuration
//! edits and removal. The rules are `omnigent_core::custom_agents`'s; the REST calls are the
//! core client's.

use omnigent_core::custom_agents as core;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// A harness a custom agent can run on.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentHarnessChoice {
    /// Harness id.
    pub id: String,
    /// Label.
    pub label: String,
}

/// The harnesses a custom agent can run on, in menu order.
#[must_use]
#[uniffi::export]
pub fn agent_harness_choices() -> Vec<AgentHarnessChoice> {
    core::AGENT_HARNESSES
        .iter()
        .map(|(id, label)| AgentHarnessChoice {
            id: (*id).to_owned(),
            label: (*label).to_owned(),
        })
        .collect()
}

/// How an MCP server in the create form runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum McpTransport {
    /// A local subprocess.
    Stdio,
    /// An HTTP endpoint.
    Http,
}

/// An MCP server row in the create form, as typed.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct McpServerForm {
    /// Tool name.
    pub name: String,
    /// Transport.
    pub transport: McpTransport,
    /// Executable (stdio).
    pub command: String,
    /// Space-separated arguments (stdio).
    pub arguments: String,
    /// `KEY=VALUE` lines (stdio).
    pub environment: String,
    /// Endpoint (http).
    pub url: String,
    /// `Name: value` lines (http).
    pub headers: String,
}

/// The create form, as typed.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentDraft {
    /// Name.
    pub name: String,
    /// Description.
    pub description: String,
    /// Instructions.
    pub instructions: String,
    /// Harness id.
    pub harness: String,
    /// Model.
    pub model: String,
    /// MCP servers.
    pub mcp_servers: Vec<McpServerForm>,
}

impl From<AgentDraft> for core::AgentDraft {
    fn from(draft: AgentDraft) -> Self {
        Self {
            name: draft.name,
            description: draft.description,
            instructions: draft.instructions,
            harness: draft.harness,
            model: draft.model,
            mcp_servers: draft
                .mcp_servers
                .into_iter()
                .map(|server| match server.transport {
                    McpTransport::Stdio => core::McpServerDraft::Stdio {
                        name: server.name,
                        command: server.command,
                        args: server
                            .arguments
                            .split_whitespace()
                            .map(str::to_owned)
                            .collect(),
                        env: core::key_value_lines(&server.environment),
                    },
                    McpTransport::Http => core::McpServerDraft::Http {
                        name: server.name,
                        url: server.url,
                        headers: core::key_value_lines(&server.headers),
                    },
                })
                .collect(),
        }
    }
}

/// Why `draft` cannot be saved, or `None` when it can.
#[must_use]
#[uniffi::export]
pub fn agent_draft_problem(draft: AgentDraft) -> Option<String> {
    core::AgentDraft::from(draft).problem()
}

/// An agent in Settings.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ManagedAgent {
    /// Agent id.
    pub id: String,
    /// Name.
    pub name: String,
    /// Description.
    pub description: Option<String>,
    /// Harness id.
    pub harness: Option<String>,
    /// Harness label.
    pub harness_label: String,
    /// Created, in seconds.
    pub created_at: Option<u64>,
    /// Last edited, in seconds.
    pub updated_at: Option<u64>,
    /// A server built-in.
    pub builtin: bool,
}

impl From<core::ManagedAgent> for ManagedAgent {
    fn from(agent: core::ManagedAgent) -> Self {
        Self {
            harness_label: agent.harness_label(),
            id: agent.id,
            name: agent.name,
            description: agent.description,
            harness: agent.harness,
            created_at: agent.created_at,
            updated_at: agent.updated_at,
            builtin: agent.builtin,
        }
    }
}

/// An MCP server in an agent's configuration.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentMcpServer {
    /// Tool name.
    pub name: String,
    /// `http` or `stdio`.
    pub transport: String,
    /// Endpoint.
    pub url: Option<String>,
    /// Executable.
    pub command: Option<String>,
    /// Arguments.
    pub args: Vec<String>,
    /// Can be changed here.
    pub editable: bool,
}

/// An agent's configuration and its revision.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentConfig {
    /// Agent id.
    pub id: String,
    /// Name.
    pub name: String,
    /// Version.
    pub version: u64,
    /// Description.
    pub description: Option<String>,
    /// Instructions.
    pub instructions: Option<String>,
    /// Model.
    pub model: Option<String>,
    /// Harness.
    pub harness: Option<String>,
    /// MCP servers.
    pub mcp_servers: Vec<AgentMcpServer>,
    /// The revision to send with a change.
    pub etag: Option<String>,
}

impl From<core::AgentConfig> for AgentConfig {
    fn from(config: core::AgentConfig) -> Self {
        Self {
            id: config.id,
            name: config.name,
            version: config.version,
            description: config.description,
            instructions: config.instructions,
            model: config.model,
            harness: config.harness,
            mcp_servers: config
                .mcp_servers
                .into_iter()
                .map(|server| AgentMcpServer {
                    name: server.name,
                    transport: server.transport,
                    url: server.url,
                    command: server.command,
                    args: server.args,
                    editable: server.editable,
                })
                .collect(),
            etag: config.etag,
        }
    }
}

impl From<AgentConfig> for core::AgentConfig {
    fn from(config: AgentConfig) -> Self {
        Self {
            id: config.id,
            name: config.name,
            version: config.version,
            description: config.description,
            instructions: config.instructions,
            model: config.model,
            harness: config.harness,
            mcp_servers: config
                .mcp_servers
                .into_iter()
                .map(|server| core::AgentMcpServer {
                    name: server.name,
                    transport: server.transport,
                    url: server.url,
                    command: server.command,
                    args: server.args,
                    editable: server.editable,
                })
                .collect(),
            etag: config.etag,
        }
    }
}

/// The editable fields of an agent's configuration.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentConfigEdit {
    /// Description; blank clears it.
    pub description: String,
    /// Instructions.
    pub instructions: String,
    /// Model.
    pub model: String,
    /// Harness.
    pub harness: String,
    /// MCP servers to remove, by name.
    pub removed_mcp_servers: Vec<String>,
}

impl From<AgentConfigEdit> for core::AgentConfigEdit {
    fn from(edit: AgentConfigEdit) -> Self {
        Self {
            description: edit.description,
            instructions: edit.instructions,
            model: edit.model,
            harness: edit.harness,
            removed_mcp_servers: edit.removed_mcp_servers,
        }
    }
}

/// What removing an agent did.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentRemoval {
    /// Removed.
    Removed,
    /// Sessions still use it; nothing was removed.
    InUse {
        /// The server's explanation.
        message: String,
    },
}

impl From<core::AgentRemoval> for AgentRemoval {
    fn from(removal: core::AgentRemoval) -> Self {
        match removal {
            core::AgentRemoval::Removed => Self::Removed,
            core::AgentRemoval::InUse { message } => Self::InUse { message },
        }
    }
}

impl ClientCore {
    fn multipart_boundary(&self) -> Result<String, CoreError> {
        let bytes = omnigent_core::auth::EntropySource::random_bytes(self.inner.entropy()?, 16)
            .map_err(CoreError::from)?;
        Ok(format!(
            "omnigent-{}",
            omnigent_core::auth::pkce::base64url(&bytes)
        ))
    }
}

#[uniffi::export]
impl ClientCore {
    /// The server's agents (`mine` false) or the caller's own (`mine` true).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors, `MalformedResponse` and `InvalidPagination`.
    pub async fn managed_agents(&self, mine: bool) -> Result<Vec<ManagedAgent>, CoreError> {
        self.sessions()
            .managed_agents(mine)
            .await
            .map(|agents| agents.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// Builds `draft`'s bundle and installs it as the caller's agent (replacing one with the
    /// same name). Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidInput` for a draft that cannot be saved, and the write
    /// errors (`Rejected` with the server's reason).
    pub async fn install_agent(&self, draft: AgentDraft) -> Result<ManagedAgent, CoreError> {
        let draft = core::AgentDraft::from(draft);
        if let Some(reason) = draft.problem() {
            return Err(omnigent_core::SessionError::InvalidInput { reason }.into());
        }
        let boundary = self.multipart_boundary()?;
        self.sessions()
            .install_agent_bundle(&draft.bundle(), "agent.tar.gz", &boundary)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Installs a `.tar.gz` bundle the user picked. Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidInput` before any request, and the write errors.
    pub async fn install_agent_bundle(
        &self,
        bundle: Vec<u8>,
        filename: String,
    ) -> Result<ManagedAgent, CoreError> {
        let boundary = self.multipart_boundary()?;
        self.sessions()
            .install_agent_bundle(&bundle, &filename, &boundary)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// The caller's agent `agent_id`'s configuration.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors and `MalformedResponse`.
    pub async fn agent_config(&self, agent_id: String) -> Result<AgentConfig, CoreError> {
        self.sessions()
            .agent_config(&agent_id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Saves `edit` over `current`, sending only what changed and `current`'s revision. With
    /// nothing changed, returns `current` without a request. Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidInput` for a blank model or harness, and the write errors
    /// (`Rejected` 412 when the agent changed since it was read).
    pub async fn update_agent_config(
        &self,
        current: AgentConfig,
        edit: AgentConfigEdit,
    ) -> Result<AgentConfig, CoreError> {
        let current = core::AgentConfig::from(current);
        let patch = core::config_patch(&current, &edit.into())
            .map_err(|reason| omnigent_core::SessionError::InvalidInput { reason })?;
        if patch.as_object().is_some_and(serde_json::Map::is_empty) {
            return Ok(current.into());
        }
        self.sessions()
            .update_agent_config(&current.id, current.etag.as_deref(), &patch)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Removes the caller's agent `agent_id`; without `force`, one still in use is kept.
    /// Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` before any request, and the write errors.
    pub async fn remove_agent(
        &self,
        agent_id: String,
        force: bool,
    ) -> Result<AgentRemoval, CoreError> {
        self.sessions()
            .remove_agent(&agent_id, force)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}
