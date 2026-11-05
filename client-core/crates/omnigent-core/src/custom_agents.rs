//! Custom agents: the create form's bundle, and the rows and configuration Settings edits.
//!
//! Port of the web's `lib/agentBundle.ts` (a `.tar.gz` with `config.yaml` and an optional
//! `AGENTS.md`), `shell/CreateAgentDialog.tsx` (validation) and `lib/agentsApi.ts` (the
//! configuration and its partial update). The REST calls (`POST /v1/agents`, `GET
//! /v1/agents/{id}/config`, `PATCH` and `DELETE /v1/agents/{id}`) are [`crate::ClientCore`]
//! methods in `client::custom_agents`.
//!
//! The bundle is gzip with stored (uncompressed) deflate blocks: it holds a few kilobytes of
//! text, and this keeps the core free of a compression dependency.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use crate::client::json::{as_object, opt_array, opt_bool, opt_object, opt_str, opt_u64, req_str};

/// The harnesses a custom agent can run on, in menu order (the web's `BRAIN_HARNESS_LABELS`).
pub const AGENT_HARNESSES: [(&str, &str); 6] = [
    ("claude-sdk", "Claude SDK"),
    ("codex", "Codex"),
    ("cursor", "Cursor"),
    ("pi", "Pi"),
    ("antigravity", "Antigravity"),
    ("copilot", "Copilot"),
];

/// An MCP server in the create form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpServerDraft {
    /// A local subprocess.
    Stdio {
        /// Tool name.
        name: String,
        /// Executable.
        command: String,
        /// Arguments.
        args: Vec<String>,
        /// Environment.
        env: BTreeMap<String, String>,
    },
    /// An HTTP (SSE) endpoint.
    Http {
        /// Tool name.
        name: String,
        /// Endpoint.
        url: String,
        /// Headers.
        headers: BTreeMap<String, String>,
    },
}

/// The create form.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AgentDraft {
    /// `^[a-zA-Z0-9_-]+$`.
    pub name: String,
    /// Optional.
    pub description: String,
    /// Optional; written as `AGENTS.md`.
    pub instructions: String,
    /// One of [`AGENT_HARNESSES`].
    pub harness: String,
    /// Required by the omnigent executor.
    pub model: String,
    /// MCP servers; rows without a name and a command or URL are left out.
    pub mcp_servers: Vec<McpServerDraft>,
}

/// The server's rule for agent names (`omnigent/spec/validator.py`).
#[must_use]
pub fn is_agent_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '_' | '-'))
}

impl AgentDraft {
    /// Why the draft cannot be saved, or `None` when it can.
    #[must_use]
    pub fn problem(&self) -> Option<String> {
        let name = self.name.trim();
        if name.is_empty() {
            return Some("Name the agent.".to_owned());
        }
        if !is_agent_name(name) {
            return Some("Use only letters, numbers, hyphens and underscores in the name.".into());
        }
        if self.model.trim().is_empty() {
            return Some("Enter a model.".to_owned());
        }
        if self.harness.trim().is_empty() {
            return Some("Choose a harness.".to_owned());
        }
        None
    }

    /// The bundle's `config.yaml`.
    #[must_use]
    pub fn config_yaml(&self) -> String {
        let mut lines = vec![
            "spec_version: 1".to_owned(),
            String::new(),
            format!("name: {}", self.name.trim()),
        ];
        let description = self.description.trim();
        if !description.is_empty() {
            lines.push(format!("description: {}", yaml_quote(description)));
        }
        lines.extend([
            String::new(),
            "executor:".into(),
            "  type: omnigent".into(),
            format!("  model: {}", yaml_quote(self.model.trim())),
            "  config:".into(),
            format!("    harness: {}", yaml_quote(self.harness.trim())),
            String::new(),
            "tools:".into(),
            "  builtins:".into(),
            "    - web_search".into(),
            "    - web_fetch".into(),
        ]);
        for server in &self.mcp_servers {
            server.push_yaml(&mut lines);
        }
        lines.push(String::new());
        if !self.instructions.trim().is_empty() {
            lines.push("instructions: AGENTS.md".into());
            lines.push(String::new());
        }
        lines.join("\n")
    }

    /// The `.tar.gz` bundle `POST /v1/agents` installs.
    #[must_use]
    pub fn bundle(&self) -> Vec<u8> {
        let mut files = vec![("config.yaml", self.config_yaml().into_bytes())];
        let instructions = self.instructions.trim();
        if !instructions.is_empty() {
            files.push(("AGENTS.md", instructions.as_bytes().to_vec()));
        }
        gzip_stored(&tar(&files))
    }
}

impl McpServerDraft {
    fn push_yaml(&self, lines: &mut Vec<String>) {
        match self {
            Self::Stdio {
                name,
                command,
                args,
                env,
            } => {
                if name.trim().is_empty() || command.trim().is_empty() {
                    return;
                }
                lines.push(format!("  {}:", name.trim()));
                lines.push("    type: mcp".into());
                lines.push(format!("    command: {}", yaml_quote(command.trim())));
                if !args.is_empty() {
                    let quoted: Vec<String> = args.iter().map(|arg| yaml_quote(arg)).collect();
                    lines.push(format!("    args: [{}]", quoted.join(", ")));
                }
                push_map(lines, "env", env);
            }
            Self::Http { name, url, headers } => {
                if name.trim().is_empty() || url.trim().is_empty() {
                    return;
                }
                lines.push(format!("  {}:", name.trim()));
                lines.push("    type: mcp".into());
                lines.push(format!("    url: {}", yaml_quote(url.trim())));
                push_map(lines, "headers", headers);
            }
        }
    }
}

fn push_map(lines: &mut Vec<String>, key: &str, map: &BTreeMap<String, String>) {
    if map.is_empty() {
        return;
    }
    lines.push(format!("    {key}:"));
    for (name, value) in map {
        lines.push(format!("      {name}: {}", yaml_quote(value)));
    }
}

/// Quotes a YAML scalar when it has special characters or surrounding space.
fn yaml_quote(value: &str) -> String {
    let special = value
        .chars()
        .any(|character| ":\n\"'#{}[],&*?|>!%@`".contains(character));
    if special || value.trim() != value || value.is_empty() {
        Value::String(value.to_owned()).to_string()
    } else {
        value.to_owned()
    }
}

/// Parses `KEY=VALUE` or `KEY: VALUE` lines (env vars or headers), skipping blank lines.
#[must_use]
pub fn key_value_lines(text: &str) -> BTreeMap<String, String> {
    text.lines()
        .filter_map(|line| {
            let line = line.trim();
            let (separator, _) = line
                .char_indices()
                .find(|(_, character)| matches!(character, '=' | ':'))
                .filter(|(index, _)| *index > 0)?;
            Some((
                line.get(..separator)?.trim().to_owned(),
                line.get(separator + 1..)?.trim().to_owned(),
            ))
        })
        .collect()
}

/// `value` padded with NULs to `width` bytes (callers keep it shorter).
fn padded(value: &[u8], width: usize) -> Vec<u8> {
    let mut field = value.to_vec();
    field.resize(width, 0);
    field
}

/// `value` as zero-padded octal and a NUL, `width` bytes.
fn octal(value: u64, width: usize) -> Vec<u8> {
    let digits = width.saturating_sub(1);
    let mut field = format!("{value:0digits$o}").into_bytes();
    field.push(0);
    field
}

/// One ustar header; `checksum` is the 8-byte checksum field.
fn tar_header(name: &str, size: usize, checksum: &[u8]) -> Vec<u8> {
    [
        padded(name.as_bytes(), 100),
        octal(0o644, 8),
        octal(0, 8),
        octal(0, 8),
        octal(u64::try_from(size).unwrap_or_default(), 12),
        octal(0, 12),
        checksum.to_vec(),
        b"0".to_vec(),
        padded(b"", 100),
        b"ustar\0".to_vec(),
        b"00".to_vec(),
        padded(b"", 247),
    ]
    .concat()
}

/// A POSIX (ustar) archive of regular files.
fn tar(files: &[(&str, Vec<u8>)]) -> Vec<u8> {
    let mut archive = Vec::new();
    for (name, content) in files {
        let unsigned = tar_header(name, content.len(), b"        ");
        let sum: u64 = unsigned.iter().map(|byte| u64::from(*byte)).sum();
        let checksum = [octal(sum, 7), b" ".to_vec()].concat();
        archive.extend(tar_header(name, content.len(), &checksum));
        archive.extend_from_slice(content);
        archive.resize(archive.len().next_multiple_of(512), 0);
    }
    archive.resize(archive.len() + 1024, 0);
    archive
}

/// Gzip (RFC 1952) of `data` in stored deflate blocks (RFC 1951 3.2.4).
fn gzip_stored(data: &[u8]) -> Vec<u8> {
    let mut output = vec![0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff];
    let mut chunks = data.chunks(usize::from(u16::MAX)).peekable();
    if chunks.peek().is_none() {
        output.extend_from_slice(&[1, 0, 0, 0xff, 0xff]);
    }
    while let Some(chunk) = chunks.next() {
        output.push(u8::from(chunks.peek().is_none()));
        let length = u16::try_from(chunk.len()).unwrap_or(u16::MAX);
        output.extend_from_slice(&length.to_le_bytes());
        output.extend_from_slice(&(!length).to_le_bytes());
        output.extend_from_slice(chunk);
    }
    output.extend_from_slice(&crc32(data).to_le_bytes());
    let size = u64::try_from(data.len()).unwrap_or_default() & u64::from(u32::MAX);
    output.extend_from_slice(&u32::try_from(size).unwrap_or_default().to_le_bytes());
    output
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for byte in data {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = if crc & 1 == 1 {
                (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

/// One `GET /v1/agents` row in Settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManagedAgent {
    /// Agent id.
    pub id: String,
    /// Name.
    pub name: String,
    /// Description.
    pub description: Option<String>,
    /// Harness.
    pub harness: Option<String>,
    /// Created, in seconds.
    pub created_at: Option<u64>,
    /// Last edited, in seconds.
    pub updated_at: Option<u64>,
    /// A server built-in.
    pub builtin: bool,
}

impl ManagedAgent {
    /// Decodes one agent row.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "agent")?;
        Ok(Self {
            id: req_str(object, "id")?,
            name: opt_str(object, "name")?.unwrap_or_default(),
            description: opt_str(object, "description")?,
            harness: opt_str(object, "harness")?,
            created_at: opt_u64(object, "created_at")?,
            updated_at: opt_u64(object, "updated_at")?,
            builtin: opt_bool(object, "builtin")?.unwrap_or(false),
        })
    }

    /// The harness display label.
    #[must_use]
    pub fn harness_label(&self) -> String {
        let harness = self.harness.as_deref().unwrap_or_default();
        AGENT_HARNESSES
            .iter()
            .find(|(id, _)| *id == harness)
            .map_or_else(
                || crate::config::session::harness_label(self.harness.as_deref()),
                |(_, label)| (*label).to_owned(),
            )
    }
}

/// An MCP server in an agent's configuration; credential values are never returned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentMcpServer {
    /// Tool name.
    pub name: String,
    /// `http` or `stdio`.
    pub transport: String,
    /// Endpoint, for `http`.
    pub url: Option<String>,
    /// Executable, for `stdio`.
    pub command: Option<String>,
    /// Arguments.
    pub args: Vec<String>,
    /// Can be changed here.
    pub editable: bool,
    /// Description; may be empty.
    pub description: String,
    /// The names of its stored headers (`http`) or environment variables (`stdio`).
    pub credential_names: Vec<String>,
}

/// What an edit does to one stored credential of an MCP server.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub enum CredentialAction {
    /// Leave the stored value.
    #[default]
    Keep,
    /// Store a new value.
    Replace,
    /// Remove it.
    Remove,
}

/// A header or environment variable in the MCP server editor.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct CredentialEdit {
    /// Name.
    pub name: String,
    /// The new value, for [`CredentialAction::Replace`].
    pub value: String,
    /// What to do.
    pub action: CredentialAction,
    /// The server already stores it.
    pub existing: bool,
}

/// An added or changed MCP server in the agent editor (the web's `MCPDraft`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct McpServerEdit {
    /// Tool name.
    pub name: String,
    /// `http` or `stdio`.
    pub transport: String,
    /// Description; blank clears it.
    pub description: String,
    /// Endpoint, for `http`.
    pub url: String,
    /// Executable, for `stdio`.
    pub command: String,
    /// Arguments, for `stdio`.
    pub args: Vec<String>,
    /// Headers (`http`) or environment variables (`stdio`).
    pub credentials: Vec<CredentialEdit>,
}

/// `GET /v1/agents/{id}/config` and its `ETag`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentConfig {
    /// Agent id.
    pub id: String,
    /// Name.
    pub name: String,
    /// Bumped on each change.
    pub version: u64,
    /// Description.
    pub description: Option<String>,
    /// Instructions.
    pub instructions: Option<String>,
    /// Model.
    pub model: Option<String>,
    /// Harness.
    pub harness: Option<String>,
    /// MCP servers, by name.
    pub mcp_servers: Vec<AgentMcpServer>,
    /// The revision to send with a change, when the server gave one.
    pub etag: Option<String>,
}

impl AgentConfig {
    /// Decodes a configuration body with its `ETag`.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value, etag: Option<String>) -> Result<Self, String> {
        let object = as_object(value, "agent config")?;
        let mut mcp_servers = Vec::new();
        for (name, server) in opt_object(object, "mcp_servers")?.into_iter().flatten() {
            let server = as_object(server, "mcp server")?;
            let names = |key: &str| -> Result<Vec<String>, String> {
                Ok(opt_array(server, key)?
                    .map(|items| {
                        items
                            .iter()
                            .filter_map(Value::as_str)
                            .map(str::to_owned)
                            .collect()
                    })
                    .unwrap_or_default())
            };
            let transport = opt_str(server, "transport")?.unwrap_or_default();
            let credential_names = if transport == "http" {
                names("configured_header_names")?
            } else {
                names("configured_env_names")?
            };
            mcp_servers.push(AgentMcpServer {
                name: name.clone(),
                url: opt_str(server, "url")?,
                command: opt_str(server, "command")?,
                args: names("args")?,
                editable: opt_bool(server, "editable")?.unwrap_or(false)
                    && matches!(transport.as_str(), "http" | "stdio"),
                description: opt_str(server, "description")?.unwrap_or_default(),
                credential_names,
                transport,
            });
        }
        Ok(Self {
            id: req_str(object, "id")?,
            name: opt_str(object, "name")?.unwrap_or_default(),
            version: opt_u64(object, "version")?.unwrap_or(0),
            description: opt_str(object, "description")?,
            instructions: opt_str(object, "instructions")?,
            model: opt_str(object, "model")?,
            harness: opt_str(object, "harness")?,
            mcp_servers,
            etag,
        })
    }
}

/// The editable fields of an agent's configuration.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
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
    /// MCP servers to add, or editable ones to change (matched by name).
    pub mcp_servers: Vec<McpServerEdit>,
}

/// The server's MCP server name rule.
fn is_mcp_server_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|first| first.is_ascii_alphanumeric() || matches!(first, '_' | '-'))
        && name.chars().count() <= 128
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
}

/// One server's patch: only what differs from `original` (`None` for a new server), with
/// credentials replaced or removed and the rest left as stored.
fn mcp_server_patch(
    edit: &McpServerEdit,
    original: Option<&AgentMcpServer>,
) -> Result<Map<String, Value>, String> {
    let name = edit.name.as_str();
    let http = edit.transport == "http";
    if !http && edit.transport != "stdio" {
        return Err(format!("{name}: choose HTTP or a command."));
    }
    let mut change = Map::new();
    if original.is_none() {
        change.insert("transport".into(), json!(edit.transport));
    }
    let description = edit.description.trim();
    if description != original.map_or("", |server| server.description.as_str()) {
        change.insert(
            "description".into(),
            if description.is_empty() {
                Value::Null
            } else {
                json!(description)
            },
        );
    }
    let (field, value, now) = if http {
        (
            "url",
            edit.url.trim(),
            original.and_then(|s| s.url.as_deref()),
        )
    } else {
        (
            "command",
            edit.command.trim(),
            original.and_then(|s| s.command.as_deref()),
        )
    };
    if original.is_none() || Some(value) != now {
        if value.is_empty() {
            return Err(format!("{name}: {field} is required."));
        }
        if http && !(value.starts_with("http://") || value.starts_with("https://")) {
            return Err(format!("{name}: use an HTTP or HTTPS URL."));
        }
        change.insert(field.into(), json!(value));
    }
    if !http && edit.args != original.map(|s| s.args.clone()).unwrap_or_default() {
        change.insert("args".into(), json!(edit.args));
    }
    let mut seen = std::collections::BTreeSet::new();
    let mut credentials = Map::new();
    for credential in &edit.credentials {
        let key = credential.name.trim();
        if key.is_empty() {
            return Err(format!("{name}: enter a credential name."));
        }
        if !seen.insert(key) {
            return Err(format!("{name}: credential names must be unique."));
        }
        match credential.action {
            CredentialAction::Replace if credential.value == "[REDACTED]" => {
                return Err("Enter a credential value, not a redaction placeholder.".into());
            }
            CredentialAction::Replace => {
                credentials.insert(key.into(), json!(credential.value));
            }
            CredentialAction::Remove if credential.existing => {
                credentials.insert(key.into(), Value::Null);
            }
            CredentialAction::Remove | CredentialAction::Keep => {}
        }
    }
    if !credentials.is_empty() {
        change.insert(
            if http { "headers" } else { "env" }.into(),
            Value::Object(credentials),
        );
    }
    Ok(change)
}

/// The `PATCH /v1/agents/{id}` body: only the fields that differ from `current`. `Err` with
/// the reason when the model or harness is blank.
///
/// # Errors
///
/// A user-facing reason; nothing should be sent.
pub fn config_patch(current: &AgentConfig, edit: &AgentConfigEdit) -> Result<Value, String> {
    let mut patch = Map::new();
    let description = edit.description.trim();
    if description != current.description.as_deref().unwrap_or_default().trim() {
        patch.insert(
            "description".into(),
            if description.is_empty() {
                Value::Null
            } else {
                json!(description)
            },
        );
    }
    if edit.instructions != current.instructions.clone().unwrap_or_default() {
        patch.insert("instructions".into(), json!(edit.instructions));
    }
    for (key, value, now) in [
        ("model", edit.model.trim(), current.model.as_deref()),
        ("harness", edit.harness.trim(), current.harness.as_deref()),
    ] {
        if value.is_empty() {
            return Err(format!("Enter a {key}."));
        }
        if Some(value) != now {
            patch.insert(key.into(), json!(value));
        }
    }
    let mut servers: Map<String, Value> = edit
        .removed_mcp_servers
        .iter()
        .map(|name| (name.clone(), Value::Null))
        .collect();
    for server in &edit.mcp_servers {
        let name = server.name.trim();
        if !is_mcp_server_name(name) {
            return Err("Enter a valid MCP server name (letters, numbers, _, - or .).".into());
        }
        if servers.contains_key(name) {
            return Err("MCP server names must be unique.".into());
        }
        let original = current.mcp_servers.iter().find(|s| s.name == name);
        if original.is_some_and(|s| !s.editable) {
            return Err(format!("{name} cannot be changed here."));
        }
        let change = mcp_server_patch(server, original)?;
        if !change.is_empty() {
            servers.insert(name.to_owned(), Value::Object(change));
        }
    }
    if !servers.is_empty() {
        patch.insert("mcp_servers".into(), Value::Object(servers));
    }
    Ok(Value::Object(patch))
}

/// A session created with an uploaded agent, and its runner launch.
#[derive(Debug, Clone, PartialEq)]
pub struct BundledSession {
    /// The creation acknowledgement.
    pub receipt: crate::creation::CreationReceipt,
    /// The runner launch on the chosen host. A failure leaves the session created: open it,
    /// never create again.
    pub launch: crate::fork::RunnerLaunch,
}

/// What removing an agent did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentRemoval {
    /// Removed.
    Removed,
    /// Sessions still use it; nothing was removed. Retry with `force` to remove it anyway.
    InUse {
        /// The server's explanation, with the session count.
        message: String,
    },
}

#[cfg(test)]
#[path = "custom_agents_tests.rs"]
mod tests;
