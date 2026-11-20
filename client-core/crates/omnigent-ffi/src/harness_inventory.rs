//! A harness's MCP servers, skills and plugins on a host, for its Settings page. The rules are
//! `omnigent_core::harness_inventory`.

use omnigent_core::harness_inventory::{
    self as core, InventoryRead, McpRow, McpSwitch, PluginRow, SkillContent, SkillRow,
};

use omnigent_core::mcp_tools as mcp;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// How one of the inventory's reads went.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum InventoryReadState {
    /// It answered.
    Loaded,
    /// It failed.
    Failed,
    /// The host is too old to answer.
    Unsupported,
}

impl From<InventoryRead> for InventoryReadState {
    fn from(read: InventoryRead) -> Self {
        match read {
            InventoryRead::Loaded => Self::Loaded,
            InventoryRead::Failed => Self::Failed,
            InventoryRead::Unsupported => Self::Unsupported,
        }
    }
}

/// An MCP server row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct InventoryMcpServer {
    /// A stable id.
    pub id: String,
    /// The name as the web shows it.
    pub title: String,
    /// Its plugin and URL host.
    pub detail: Option<String>,
    /// Turned off for Omnigent sessions.
    pub is_off: bool,
    /// Its configured name, which the tool probe asks for.
    #[uniffi(default)]
    pub name: String,
    /// The plugin that ships it.
    #[uniffi(default)]
    pub plugin: Option<String>,
    /// The plugin server's id.
    #[uniffi(default)]
    pub source_id: Option<String>,
    /// The harness its Omnigent on/off switch belongs to; `nil` without a switch.
    #[uniffi(default)]
    pub switch_harness: Option<String>,
    /// An organization pins the switch, so it can't change here.
    #[uniffi(default)]
    pub switch_locked: bool,
}

impl From<McpRow> for InventoryMcpServer {
    fn from(row: McpRow) -> Self {
        Self {
            switch_harness: row.switch.as_ref().map(|switch| switch.harness.clone()),
            switch_locked: row.switch.as_ref().is_some_and(|switch| switch.locked),
            id: row.id,
            title: row.title,
            detail: row.detail,
            is_off: row.is_off,
            name: row.name,
            plugin: row.plugin,
            source_id: row.source_id,
        }
    }
}

impl From<InventoryMcpServer> for McpRow {
    fn from(server: InventoryMcpServer) -> Self {
        Self {
            switch: server.switch_harness.map(|harness| McpSwitch {
                harness,
                enabled: !server.is_off,
                locked: server.switch_locked,
            }),
            id: server.id,
            title: server.title,
            detail: server.detail,
            plugin: server.plugin,
            is_off: server.is_off,
            name: server.name,
            source_id: server.source_id,
        }
    }
}

/// How the host's connection to an MCP server went.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum McpConnection {
    /// It answered with its tools.
    Connected,
    /// It needs a sign-in the harness's credentials can't stand in for.
    NeedsAuth,
    /// It couldn't be reached.
    Unreachable,
    /// It didn't answer in time.
    Timeout,
    /// Its configuration can't be probed.
    Unsupported,
}

/// One tool an MCP server offers.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct McpTool {
    /// Its name.
    pub name: String,
    /// What it does.
    pub description: Option<String>,
}

/// An MCP tool probe's outcome, or why the host couldn't probe.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum McpToolsRead {
    /// The host probed the server.
    Probed {
        /// The tools.
        tools: Vec<McpTool>,
        /// How the connection went.
        connection: McpConnection,
        /// Only the first 500 are listed.
        truncated: bool,
    },
    /// The server has no probe route.
    RouteMissing,
    /// The host predates the probe.
    HostOutdated,
    /// The host is busy probing other servers.
    Busy,
}

impl From<mcp::McpToolsRead> for McpToolsRead {
    fn from(read: mcp::McpToolsRead) -> Self {
        match read {
            mcp::McpToolsRead::Probed(found) => Self::Probed {
                tools: found
                    .tools
                    .into_iter()
                    .map(|tool| McpTool {
                        name: tool.name,
                        description: tool.description,
                    })
                    .collect(),
                connection: match found.connection {
                    mcp::McpConnection::Connected => McpConnection::Connected,
                    mcp::McpConnection::NeedsAuth => McpConnection::NeedsAuth,
                    mcp::McpConnection::Unreachable => McpConnection::Unreachable,
                    mcp::McpConnection::Timeout => McpConnection::Timeout,
                    mcp::McpConnection::Unsupported => McpConnection::Unsupported,
                },
                truncated: found.truncated,
            },
            mcp::McpToolsRead::RouteMissing => Self::RouteMissing,
            mcp::McpToolsRead::HostOutdated => Self::HostOutdated,
            mcp::McpToolsRead::Busy => Self::Busy,
        }
    }
}

/// A skill row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct InventorySkill {
    /// The name its page asks for.
    pub name: String,
    /// The name it shows.
    pub title: String,
    /// What it does.
    pub description: String,
    /// A plugin skill's id, for its page.
    pub source_id: Option<String>,
}

impl From<SkillRow> for InventorySkill {
    fn from(row: SkillRow) -> Self {
        Self {
            name: row.name,
            title: row.title,
            description: row.description,
            source_id: row.source_id,
        }
    }
}

/// A plugin row, with its page's lists.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct InventoryPlugin {
    /// A stable id.
    pub id: String,
    /// Its name.
    pub name: String,
    /// Version, marketplace, state and counts.
    pub detail: String,
    /// What it does.
    pub description: Option<String>,
    /// Its skills.
    pub skills: Vec<InventorySkill>,
    /// Its MCP servers.
    pub mcp_servers: Vec<InventoryMcpServer>,
    /// Why its skills can't be read; `{host}` stands for the host's name.
    pub skills_notice: Option<String>,
    /// Why its MCP servers can't be inspected; `{host}` stands for the host's name.
    pub mcp_notice: Option<String>,
}

impl From<PluginRow> for InventoryPlugin {
    fn from(row: PluginRow) -> Self {
        Self {
            id: row.id,
            name: row.name,
            detail: row.detail,
            description: row.description,
            skills: row.skills.into_iter().map(Into::into).collect(),
            mcp_servers: row.mcp_servers.into_iter().map(Into::into).collect(),
            skills_notice: row.skills_notice,
            mcp_notice: row.mcp_notice,
        }
    }
}

/// A harness's inventory on a host and how each read went.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessInventoryRecord {
    /// MCP servers.
    pub mcp_servers: Vec<InventoryMcpServer>,
    /// Skills no plugin ships.
    pub skills: Vec<InventorySkill>,
    /// Plugins.
    pub plugins: Vec<InventoryPlugin>,
    /// The MCP servers' read.
    pub mcp_read: InventoryReadState,
    /// The skills' read.
    pub skills_read: InventoryReadState,
    /// The plugins' read.
    pub plugins_read: InventoryReadState,
}

/// A skill's contents.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SkillContentRecord {
    /// The name asked for.
    pub name: String,
    /// What it does.
    pub description: String,
    /// `SKILL.md` without its frontmatter, as Markdown.
    pub content: String,
    /// Cut at the host's 256 KiB limit.
    pub truncated: bool,
}

impl From<SkillContent> for SkillContentRecord {
    fn from(content: SkillContent) -> Self {
        Self {
            name: content.name,
            description: content.description,
            content: content.content,
            truncated: content.truncated,
        }
    }
}

/// The inventory family of a native harness (`claude`, `codex`, `cursor`, `pi`), or `None`
/// for a harness whose page lists none.
#[must_use]
#[uniffi::export]
pub fn harness_inventory_family(harness: String) -> Option<String> {
    core::inventory_family(&harness).map(str::to_owned)
}

/// Whether a family's skills open a page with their contents.
#[must_use]
#[uniffi::export]
pub fn harness_skill_pages_open(family: String) -> bool {
    core::skill_pages_open(&family)
}

#[uniffi::export]
impl ClientCore {
    /// `harness`'s MCP servers, skills and plugins on `host_id`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: kind `InvalidInput` for a harness whose page lists none.
    pub async fn harness_catalog(
        &self,
        host_id: String,
        harness: String,
    ) -> Result<HarnessInventoryRecord, CoreError> {
        let read = self
            .sessions()
            .host_harness_inventory(&host_id, &harness)
            .await
            .map_err(CoreError::from)?;
        Ok(HarnessInventoryRecord {
            mcp_servers: read
                .inventory
                .mcp_servers
                .into_iter()
                .map(Into::into)
                .collect(),
            skills: read.inventory.skills.into_iter().map(Into::into).collect(),
            plugins: read.inventory.plugins.into_iter().map(Into::into).collect(),
            mcp_read: read.mcp_servers.into(),
            skills_read: read.skills.into(),
            plugins_read: read.plugins.into(),
        })
    }

    /// Asks `host_id` to connect to `harness`'s MCP server `server` and list its tools.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors and `MalformedResponse`.
    pub async fn mcp_server_tools(
        &self,
        host_id: String,
        harness: String,
        server: String,
        plugin: Option<String>,
        source_id: Option<String>,
    ) -> Result<McpToolsRead, CoreError> {
        self.sessions()
            .mcp_server_tools(
                &host_id,
                &harness,
                &server,
                plugin.as_deref(),
                source_id.as_deref(),
            )
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Turns `server` on or off for Omnigent sessions on `host_id`; whether it is on now.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` for a server without a free switch,
    /// `Rejected` for one the host refuses, and the write errors.
    pub async fn set_mcp_server_enabled(
        &self,
        host_id: String,
        server: InventoryMcpServer,
        enabled: bool,
    ) -> Result<bool, CoreError> {
        self.sessions()
            .set_host_mcp_server_enabled(&host_id, &server.into(), enabled)
            .await
            .map(|server| server.enabled != Some(false))
            .map_err(CoreError::from)
    }

    /// A skill's contents on `host_id` for `harness`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors (404 where the harness shows none, 501 from an
    /// older host).
    pub async fn harness_skill_content(
        &self,
        host_id: String,
        harness: String,
        name: String,
        source_id: Option<String>,
    ) -> Result<SkillContentRecord, CoreError> {
        self.sessions()
            .host_skill_content(&host_id, &harness, &name, source_id.as_deref())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}
