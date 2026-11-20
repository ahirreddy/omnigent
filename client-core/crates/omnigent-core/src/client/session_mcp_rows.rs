//! The `/mcp` panel's rows and status from what was read, merged as the web's `ChatPage`
//! merges them.

use super::harness_inventory::HostMcpServer;
use super::server_admin::McpService;
use super::session_mcp::{AgentMcp, AgentMcpServer, LiveMcpRead, LiveMcpServer};

/// A source the panel read, or failed to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceRead<T> {
    /// Read.
    Loaded(T),
    /// Not readable.
    Failed,
}

impl<T> SourceRead<T> {
    const fn loaded(&self) -> Option<&T> {
        match self {
            Self::Loaded(value) => Some(value),
            Self::Failed => None,
        }
    }
}

/// What the panel was built from; `None` for a source the session doesn't ask.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpPanelSources {
    /// The host inventory family the session lists (`claude` for claude-sdk on a host).
    pub host_family: Option<String>,
    /// The session routes to a known host.
    pub has_host: bool,
    /// The session runs claude-sdk.
    pub claude_sdk: bool,
    /// The session agent.
    pub agent: Option<SourceRead<AgentMcp>>,
    /// The host's servers.
    pub host: Option<SourceRead<Vec<HostMcpServer>>>,
    /// The registry, read only while an agent server comes from it.
    pub registry: Option<SourceRead<Vec<McpService>>>,
    /// The CLI's connections, for claude-sdk.
    pub live: Option<SourceRead<LiveMcpRead>>,
}

/// A row's account state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum McpAccount {
    /// Connected.
    Connected,
    /// Signing in is needed.
    SignInRequired,
    /// The account no longer sees this registry service.
    Unavailable,
}

/// How a `SignInRequired` row signs in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpSignIn {
    /// On a page the host named.
    Url(String),
    /// The registry service's own sign-in; `typed` when a token or workspace URL is typed.
    Registry {
        /// The service.
        service_id: String,
        /// It takes a token or workspace URL rather than a browser sign-in.
        typed: bool,
    },
}

/// A row's connection in the running session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpLive {
    /// As [`LiveMcpServer::status`], or `not-loaded` when the CLI's answer omits it.
    pub status: String,
    /// Why it failed.
    pub error: Option<String>,
}

/// One row of the panel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpPanelRow {
    /// Unique among the rows.
    pub key: String,
    /// The server's name.
    pub name: String,
    /// Its plugin and URL host, or what it does.
    pub description: Option<String>,
    /// Its account state.
    pub account: Option<McpAccount>,
    /// How it signs in, while `account` is `SignInRequired`.
    pub sign_in: Option<McpSignIn>,
    /// Its connection in the session, where the harness reports it.
    pub live: Option<McpLive>,
    /// The harness's name for it, for Reconnect.
    pub live_name: Option<String>,
}

/// The `/mcp` panel.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct McpPanel {
    /// Its rows.
    pub rows: Vec<McpPanelRow>,
    /// Why some rows may be missing, or where live status comes from.
    pub status: Option<String>,
    /// Read again after this many milliseconds: a host server awaits sign-in done elsewhere,
    /// or a live connection is still connecting.
    pub poll_after_ms: Option<u32>,
}

const HOST_SIGN_IN_POLL_MS: u32 = 5_000;
const LIVE_PENDING_POLL_MS: u32 = 2_000;

/// The harness's name for a host inventory server; the CLI prefixes plugin servers.
#[must_use]
pub fn live_name_for_host_server(server: &HostMcpServer) -> String {
    server.plugin.as_ref().map_or_else(
        || server.name.clone(),
        |plugin| format!("plugin:{plugin}:{}", server.name),
    )
}

fn live_note(live: &SourceRead<LiveMcpRead>) -> Option<String> {
    match live {
        SourceRead::Failed => {
            Some("Couldn\u{2019}t read this session\u{2019}s live MCP connections.".to_owned())
        }
        SourceRead::Loaded(LiveMcpRead::NotRunning) => Some(
            "Live connection status appears once this session\u{2019}s agent is running; send a \
             message to start it."
                .to_owned(),
        ),
        SourceRead::Loaded(LiveMcpRead::Unavailable(detail)) => Some(detail.as_ref().map_or_else(
            || "Couldn\u{2019}t read this session\u{2019}s live MCP connections.".to_owned(),
            |detail| {
                format!("Couldn\u{2019}t read this session\u{2019}s live MCP connections: {detail}")
            },
        )),
        SourceRead::Loaded(LiveMcpRead::Live(_) | LiveMcpRead::Unsupported) => None,
    }
}

fn status(sources: &McpPanelSources, has_registry: bool) -> Option<String> {
    let agent_note = match &sources.agent {
        Some(SourceRead::Failed) if sources.claude_sdk => Some(
            "Couldn\u{2019}t load this session\u{2019}s agent, so only managed MCP servers are shown.",
        ),
        _ => None,
    };
    let host_note = if sources.host_family.is_none() {
        None
    } else if !sources.has_host {
        Some("Host MCP servers unavailable: this session has no known host.")
    } else if matches!(sources.host, Some(SourceRead::Failed)) {
        Some("Couldn\u{2019}t load MCP servers from this session\u{2019}s host.")
    } else {
        agent_note
    };
    let registry_note = (has_registry && matches!(sources.registry, Some(SourceRead::Failed)))
        .then_some("Couldn\u{2019}t check MCP service connections.");
    let notes: Vec<String> = [
        host_note.map(str::to_owned),
        registry_note.map(str::to_owned),
    ]
    .into_iter()
    .flatten()
    .chain(sources.live.as_ref().and_then(live_note))
    .collect();
    (!notes.is_empty()).then(|| notes.join(" "))
}

fn host_row(server: &HostMcpServer) -> McpPanelRow {
    let detail: Vec<String> = [
        server
            .plugin
            .as_ref()
            .map(|plugin| format!("{plugin} plugin")),
        server.url_host.clone(),
    ]
    .into_iter()
    .flatten()
    .filter(|part| !part.is_empty())
    .collect();
    let live_name = live_name_for_host_server(server);
    let sign_in_url = server.sign_in_url.as_ref().filter(|url| {
        let lower = url.to_ascii_lowercase();
        lower.starts_with("https://") || lower.starts_with("http://")
    });
    McpPanelRow {
        key: format!("host:{live_name}"),
        name: server.name.clone(),
        description: (!detail.is_empty()).then(|| detail.join(" \u{00B7} ")),
        account: match server.auth_status.as_deref() {
            Some("connected") => Some(McpAccount::Connected),
            Some("sign_in_required") => Some(McpAccount::SignInRequired),
            _ => None,
        },
        sign_in: sign_in_url.map(|url| McpSignIn::Url(url.clone())),
        live: None,
        live_name: None,
    }
}

fn live_fields(row: &mut McpPanelRow, server: &LiveMcpServer) {
    row.live = Some(McpLive {
        status: server.status.clone(),
        error: server.error.clone(),
    });
    row.live_name = Some(server.name.clone());
}

/// Applies the registry's account state to an agent row.
fn registry_fields(row: &mut McpPanelRow, services: &[McpService]) {
    let Some(service) = services.iter().find(|service| service.id == row.name) else {
        row.account = Some(McpAccount::Unavailable);
        return;
    };
    if let Some(description) = service.description.as_ref().filter(|text| !text.is_empty()) {
        row.description = Some(description.clone());
    }
    row.account = Some(if service.connected {
        McpAccount::Connected
    } else {
        McpAccount::SignInRequired
    });
    if !service.connected {
        row.sign_in = Some(McpSignIn::Registry {
            service_id: service.id.clone(),
            typed: matches!(service.auth.as_str(), "bearer" | "databricks"),
        });
    }
}

/// Host rows with their live connections, then the servers only the CLI loaded.
fn host_and_live_rows(
    host_servers: &[&HostMcpServer],
    live: Option<&[LiveMcpServer]>,
) -> Vec<McpPanelRow> {
    let mut unclaimed: Vec<&LiveMcpServer> = live.into_iter().flatten().collect();
    let mut rows: Vec<McpPanelRow> = host_servers
        .iter()
        .map(|server| {
            let mut row = host_row(server);
            let live_name = live_name_for_host_server(server);
            if let Some(index) = unclaimed.iter().position(|live| live.name == live_name) {
                live_fields(&mut row, unclaimed.remove(index));
            } else if live.is_some() {
                // An answer that omits a server means the session did not load it.
                row.live = Some(McpLive {
                    status: "not-loaded".to_owned(),
                    error: None,
                });
            }
            row
        })
        .collect();
    // The CLI also loads servers the host inventory doesn't list, such as project ones.
    for server in unclaimed {
        let mut row = McpPanelRow {
            key: format!("live:{}", server.name),
            name: server.name.clone(),
            description: None,
            account: None,
            sign_in: None,
            live: None,
            live_name: None,
        };
        live_fields(&mut row, server);
        rows.push(row);
    }
    rows
}

/// Places the agent's `server`: it takes the first host row with its name and drops the rest.
fn place_agent_row(
    rows: &mut Vec<McpPanelRow>,
    server: &AgentMcpServer,
    services: Option<&[McpService]>,
) {
    // A shared name is not a shared endpoint, so the agent's row takes none of the host's
    // account state: its Sign in could point at the wrong service.
    let host_indices: Vec<usize> = rows
        .iter()
        .enumerate()
        .filter(|(_, row)| row.key.starts_with("host:") && row.name == server.name)
        .map(|(index, _)| index)
        .collect();
    let first = host_indices.first().and_then(|index| rows.get(*index));
    let mut row = McpPanelRow {
        key: first.map_or_else(|| format!("agent:{}", server.name), |row| row.key.clone()),
        name: server.name.clone(),
        description: server
            .description
            .clone()
            .or_else(|| first.and_then(|row| row.description.clone())),
        account: None,
        sign_in: None,
        live: None,
        live_name: None,
    };
    if server.transport == "registry"
        && let Some(services) = services
    {
        registry_fields(&mut row, services);
    }
    for index in host_indices.iter().skip(1).rev() {
        rows.remove(*index);
    }
    match host_indices.first().and_then(|index| rows.get_mut(*index)) {
        Some(slot) => *slot = row,
        None => rows.push(row),
    }
}

/// The panel from `sources`, merged as the web merges it.
///
/// The host's servers for the session's harness come first with their account and live
/// state, then servers only the CLI loaded, then the agent's servers.
#[must_use]
pub fn mcp_panel(sources: &McpPanelSources) -> McpPanel {
    let agent = sources.agent.as_ref().and_then(SourceRead::loaded);
    // A claude-sdk session without user settings loads only managed servers; so does one
    // whose agent could not be read.
    let user_servers_loaded =
        !sources.claude_sdk || agent.is_some_and(|agent| agent.loads_user_settings);
    let host_servers: Vec<&HostMcpServer> = match (&sources.host_family, &sources.host) {
        (Some(family), Some(SourceRead::Loaded(servers))) => servers
            .iter()
            .filter(|server| &server.harness == family && (server.managed || user_servers_loaded))
            .collect(),
        _ => Vec::new(),
    };
    let live = match &sources.live {
        Some(SourceRead::Loaded(LiveMcpRead::Live(servers))) => Some(servers.as_slice()),
        _ => None,
    };
    let mut rows = host_and_live_rows(&host_servers, live);
    let services = sources
        .registry
        .as_ref()
        .and_then(SourceRead::loaded)
        .map(Vec::as_slice);
    let agent_servers = agent
        .map(|agent| agent.servers.as_slice())
        .unwrap_or_default();
    for server in agent_servers {
        place_agent_row(&mut rows, server, services);
    }
    let has_registry = agent_servers
        .iter()
        .any(|server| server.transport == "registry");
    let awaits_sign_in = host_servers
        .iter()
        .any(|server| server.auth_status.as_deref() == Some("sign_in_required"));
    let connecting =
        live.is_some_and(|servers| servers.iter().any(|server| server.status == "pending"));
    McpPanel {
        rows,
        status: status(sources, has_registry),
        poll_after_ms: if connecting {
            Some(LIVE_PENDING_POLL_MS)
        } else {
            awaits_sign_in.then_some(HOST_SIGN_IN_POLL_MS)
        },
    }
}
