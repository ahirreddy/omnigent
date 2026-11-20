//! A harness's MCP servers, skills and plugins on a host, for its Settings page.
//!
//! As the web's `HarnessCatalog` and `useHarnessInventory` read them:
//! `GET /v1/hosts/{id}/mcp-servers`, `GET /v1/skills?host_id&harness&path=~`, Claude's
//! `GET /v1/hosts/{id}/plugins` and a skill's `GET /v1/hosts/{id}/harnesses/{h}/skills/{name}`.

use std::collections::BTreeMap;

use serde_json::Value;

use super::json::{as_object, opt_array, opt_bool, opt_str, req_str};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;
use crate::slash::Skill;

/// The family of a native harness whose inventory the page lists: `claude`, `codex`, `cursor`
/// or `pi`; `None` for any other harness.
#[must_use]
pub fn inventory_family(harness: &str) -> Option<&'static str> {
    match harness {
        "claude-native" => Some("claude"),
        "codex-native" => Some("codex"),
        "cursor-native" => Some("cursor"),
        "pi-native" => Some("pi"),
        _ => None,
    }
}

/// Whether a family's skills open a page with their contents (not Pi's).
#[must_use]
pub fn skill_pages_open(family: &str) -> bool {
    matches!(family, "claude" | "codex" | "cursor")
}

/// An MCP server's name as the web shows it: a known brand's spelling, else lower case.
#[must_use]
pub fn mcp_server_display_name(name: &str) -> String {
    const BRANDS: [&str; 12] = [
        "GitHub",
        "GitLab",
        "Linear",
        "Slack",
        "Jira",
        "Confluence",
        "Notion",
        "Figma",
        "Sentry",
        "PagerDuty",
        "Glean",
        "Databricks",
    ];
    BRANDS
        .iter()
        .find(|brand| brand.eq_ignore_ascii_case(name.trim()))
        .map_or_else(|| name.to_lowercase(), |brand| (*brand).to_owned())
}

/// One MCP server a host's harness has configured (`McpServerSummary`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostMcpServer {
    /// Its configured name.
    pub name: String,
    /// The family it belongs to.
    pub harness: String,
    /// The plugin that ships it, if any.
    pub plugin: Option<String>,
    /// The plugin server's id.
    pub source_id: Option<String>,
    /// The host of an HTTP server's URL.
    pub url_host: Option<String>,
    /// Turned off for Omnigent sessions; `None` where the harness can't say.
    pub enabled: Option<bool>,
    /// Pinned for every user on the host by an organization.
    pub managed: bool,
    /// Its Omnigent switch is fixed by an organization's policy.
    pub locked: bool,
    /// The host's sign-in manager's account state: `connected` or `sign_in_required`.
    pub auth_status: Option<String>,
    /// Where to finish signing in, with `sign_in_required`.
    pub sign_in_url: Option<String>,
}

impl HostMcpServer {
    /// The host reports an Omnigent on/off switch for it: a Claude or Codex server with a known
    /// state. Its organization may still lock it ([`Self::managed`]).
    #[must_use]
    pub fn has_switch(&self) -> bool {
        self.enabled.is_some() && matches!(self.harness.as_str(), "claude" | "codex")
    }
}

/// One plugin installed for Claude (`PluginSummary`).
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts the host reports about one plugin"
)]
pub struct HostPlugin {
    /// Its id; `None` from an older host.
    pub id: Option<String>,
    /// Its name.
    pub name: String,
    /// The marketplace it came from.
    pub marketplace: String,
    /// Its version.
    pub version: Option<String>,
    /// What it does.
    pub description: Option<String>,
    /// Turned on in Claude.
    pub enabled: bool,
    /// Its skills: entry id and name, or names alone from an older host.
    pub skills: Vec<(Option<String>, String)>,
    /// Its MCP servers: entry id and name, or names alone from an older host.
    pub mcp_servers: Vec<(Option<String>, String)>,
    /// The host reported entry ids for its skills.
    pub has_skill_entries: bool,
    /// The host reported entry ids for its MCP servers.
    pub has_mcp_entries: bool,
    /// It has hooks.
    pub has_hooks: bool,
    /// It has commands.
    pub has_commands: bool,
}

/// A row of the MCP servers tab.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpRow {
    /// A stable id.
    pub id: String,
    /// The name as the web shows it.
    pub title: String,
    /// The plugin and the URL's host, joined with " · ".
    pub detail: Option<String>,
    /// The plugin that ships it.
    pub plugin: Option<String>,
    /// Turned off for Omnigent sessions.
    pub is_off: bool,
    /// Its configured name, which the tool probe asks for.
    pub name: String,
    /// The plugin server's id, which the tool probe names.
    pub source_id: Option<String>,
    /// Its Omnigent on/off switch, where the host reports one.
    pub switch: Option<McpSwitch>,
}

/// An MCP server's Omnigent on/off switch, as the web's `McpSwitch`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpSwitch {
    /// The harness it belongs to (`claude` or `codex`), which a change names.
    pub harness: String,
    /// On for Omnigent sessions.
    pub enabled: bool,
    /// An organization pins it, so it can't change here.
    pub locked: bool,
}

/// A row of the Skills tab, or a plugin's skill.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillRow {
    /// The name the skill page asks for: `review`, or `plugin:review`.
    pub name: String,
    /// The name it shows.
    pub title: String,
    /// What it does.
    pub description: String,
    /// The plugin skill's id, for its page.
    pub source_id: Option<String>,
}

/// A row of the Plugins tab, with its own page's lists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PluginRow {
    /// A stable id.
    pub id: String,
    /// Its name.
    pub name: String,
    /// Version, marketplace, state and counts, joined with " · " (`pluginDetail`).
    pub detail: String,
    /// What it does.
    pub description: Option<String>,
    /// Its skills.
    pub skills: Vec<SkillRow>,
    /// Its MCP servers.
    pub mcp_servers: Vec<McpRow>,
    /// Why its skills can't be read here: the host is older.
    pub skills_notice: Option<String>,
    /// Why its MCP servers can't be inspected: off in Claude, or an older host.
    pub mcp_notice: Option<String>,
}

/// A harness's inventory on a host, as its tabs list it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HarnessInventory {
    /// MCP servers.
    pub mcp_servers: Vec<McpRow>,
    /// Skills that no plugin ships.
    pub skills: Vec<SkillRow>,
    /// Plugins.
    pub plugins: Vec<PluginRow>,
}

/// A skill's contents (`SkillContentResponse`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillContent {
    /// The name asked for.
    pub name: String,
    /// What it does.
    pub description: String,
    /// `SKILL.md` without its frontmatter.
    pub content: String,
    /// Cut at the host's 256 KiB limit.
    pub truncated: bool,
}

/// How one of the inventory's reads went.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InventoryRead {
    /// It answered.
    Loaded,
    /// It failed: "Couldn't load … from {host}."
    Failed,
    /// The host is too old to answer (501): "Please update host {host} to list MCP servers."
    Unsupported,
}

/// A harness's inventory on a host and how each of its reads went.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostInventory {
    /// The tabs' rows.
    pub inventory: HarnessInventory,
    /// The MCP servers' read.
    pub mcp_servers: InventoryRead,
    /// The skills' read.
    pub skills: InventoryRead,
    /// The plugins' read: Claude's list, or the names when there is none.
    pub plugins: InventoryRead,
}

const fn read_state<V>(result: &Result<V, SessionError>) -> InventoryRead {
    match result {
        Ok(_) => InventoryRead::Loaded,
        Err(SessionError::HttpStatus { status: 501 }) => InventoryRead::Unsupported,
        Err(_) => InventoryRead::Failed,
    }
}

fn plural(count: usize, one: &str, many: &str) -> String {
    format!("{count} {}", if count == 1 { one } else { many })
}

fn join(parts: impl IntoIterator<Item = Option<String>>) -> Option<String> {
    let parts: Vec<String> = parts.into_iter().flatten().collect();
    (!parts.is_empty()).then(|| parts.join(" \u{00B7} "))
}

fn mcp_row(family: &str, server: &HostMcpServer) -> McpRow {
    let plugin_part = server
        .plugin
        .as_ref()
        .map(|plugin| format!("plugin:{plugin}:"))
        .unwrap_or_default();
    McpRow {
        id: server
            .source_id
            .clone()
            .unwrap_or_else(|| format!("{family}:{plugin_part}{}", server.name)),
        title: mcp_server_display_name(&server.name),
        detail: join([
            server
                .plugin
                .as_ref()
                .map(|plugin| format!("{plugin} plugin")),
            server.url_host.clone(),
        ]),
        plugin: server.plugin.clone(),
        switch: server
            .enabled
            .filter(|_| server.has_switch())
            .map(|enabled| McpSwitch {
                harness: server.harness.clone(),
                enabled,
                locked: server.locked,
            }),
        is_off: server.enabled == Some(false),
        name: server.name.clone(),
        source_id: server.source_id.clone(),
    }
}

/// The inventory's tabs from what the host reported (`buildInventoryContext`).
///
/// `family`'s MCP servers, the skills no plugin ships (a `plugin:skill` name belongs to its
/// plugin) and the plugins, from Claude's plugin list when the host has one, else from the names.
#[must_use]
pub fn harness_inventory(
    family: &str,
    servers: &[HostMcpServer],
    skills: &[Skill],
    plugins: Option<&[HostPlugin]>,
) -> HarnessInventory {
    let servers: Vec<&HostMcpServer> = servers.iter().filter(|s| s.harness == family).collect();
    let mut plugin_skills: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut plain = Vec::new();
    for skill in skills {
        match skill
            .name
            .split_once(':')
            .filter(|(plugin, _)| !plugin.is_empty())
        {
            Some((plugin, name)) => plugin_skills
                .entry(plugin.to_owned())
                .or_default()
                .push(name.to_owned()),
            None => plain.push(SkillRow {
                name: skill.name.clone(),
                title: skill.name.clone(),
                description: skill.description.clone(),
                source_id: None,
            }),
        }
    }
    let plugins = plugins.map_or_else(
        || legacy_plugins(family, &plugin_skills, &servers),
        |plugins| {
            plugins
                .iter()
                .map(|plugin| plugin_row(family, plugin, &servers))
                .collect()
        },
    );
    HarnessInventory {
        mcp_servers: servers
            .iter()
            .map(|server| mcp_row(family, server))
            .collect(),
        skills: plain,
        plugins,
    }
}

fn legacy_plugins(
    family: &str,
    plugin_skills: &BTreeMap<String, Vec<String>>,
    servers: &[&HostMcpServer],
) -> Vec<PluginRow> {
    let mut names: Vec<String> = plugin_skills.keys().cloned().collect();
    for server in servers {
        if let Some(plugin) = &server.plugin
            && !names.contains(plugin)
        {
            names.push(plugin.clone());
        }
    }
    names
        .into_iter()
        .map(|name| {
            let skills: Vec<SkillRow> = plugin_skills
                .get(&name)
                .into_iter()
                .flatten()
                .map(|skill| SkillRow {
                    name: format!("{name}:{skill}"),
                    title: skill.clone(),
                    description: String::new(),
                    source_id: None,
                })
                .collect();
            let mcp_servers: Vec<McpRow> = servers
                .iter()
                .filter(|server| server.plugin.as_deref() == Some(name.as_str()))
                .map(|server| mcp_row(family, server))
                .collect();
            PluginRow {
                id: format!("{family}:{name}"),
                detail: plugin_detail(
                    None,
                    None,
                    None,
                    skills.len(),
                    mcp_servers.len(),
                    false,
                    false,
                ),
                name,
                description: None,
                skills,
                mcp_servers,
                skills_notice: None,
                mcp_notice: None,
            }
        })
        .collect()
}

#[allow(
    clippy::fn_params_excessive_bools,
    reason = "the parts of the web's one-line plugin detail"
)]
fn plugin_detail(
    version: Option<&str>,
    marketplace: Option<&str>,
    enabled: Option<bool>,
    skills: usize,
    mcp_servers: usize,
    hooks: bool,
    commands: bool,
) -> String {
    join([
        version.map(|version| format!("v{version}")),
        marketplace.map(str::to_owned),
        enabled.map(|on| if on { "Enabled" } else { "Disabled" }.to_owned()),
        Some(plural(skills, "skill", "skills")),
        Some(plural(mcp_servers, "MCP", "MCPs")),
        hooks.then(|| "Hooks".to_owned()),
        commands.then(|| "Commands".to_owned()),
    ])
    .unwrap_or_default()
}

fn plugin_row(family: &str, plugin: &HostPlugin, servers: &[&HostMcpServer]) -> PluginRow {
    let id = plugin
        .id
        .clone()
        .unwrap_or_else(|| format!("{family}:{}@{}", plugin.name, plugin.marketplace));
    let mcp_servers: Vec<McpRow> = if plugin.mcp_servers.is_empty() {
        servers
            .iter()
            .filter(|server| server.plugin.as_deref() == Some(plugin.name.as_str()))
            .map(|server| mcp_row(family, server))
            .collect()
    } else {
        plugin
            .mcp_servers
            .iter()
            .map(|(entry, name)| {
                let inventory = servers.iter().find(|server| {
                    server.plugin.as_deref() == Some(plugin.name.as_str())
                        && server.name == *name
                        && entry
                            .as_ref()
                            .is_none_or(|entry| server.source_id.as_ref() == Some(entry))
                });
                McpRow {
                    id: entry.clone().unwrap_or_else(|| format!("{id}:{name}")),
                    title: mcp_server_display_name(name),
                    detail: None,
                    plugin: Some(plugin.name.clone()),
                    is_off: inventory.is_some_and(|server| server.enabled == Some(false)),
                    name: name.clone(),
                    source_id: entry.clone(),
                    switch: None,
                }
            })
            .collect()
    };
    let skills = plugin
        .skills
        .iter()
        .map(|(entry, name)| SkillRow {
            name: format!("{}:{name}", plugin.name),
            title: name.clone(),
            description: String::new(),
            source_id: entry.clone(),
        })
        .collect::<Vec<_>>();
    let mcp_notice = if !plugin.enabled {
        Some("This plugin is disabled. Enable it in Claude Code to inspect MCP tools.".to_owned())
    } else if !plugin.has_mcp_entries {
        Some("Update {host} to inspect installed plugin MCP tools.".to_owned())
    } else {
        None
    };
    PluginRow {
        detail: plugin_detail(
            plugin.version.as_deref(),
            Some(plugin.marketplace.as_str()),
            Some(plugin.enabled),
            skills.len(),
            mcp_servers.len(),
            plugin.has_hooks,
            plugin.has_commands,
        ),
        id,
        name: plugin.name.clone(),
        description: plugin.description.clone().filter(|text| !text.is_empty()),
        skills_notice: (!plugin.has_skill_entries)
            .then(|| "Update {host} to read installed plugin skills.".to_owned()),
        skills,
        mcp_servers,
        mcp_notice,
    }
}

fn mcp_server_from(value: &Value) -> Result<HostMcpServer, String> {
    let object = as_object(value, "MCP server")?;
    // Hosts send the switches as strings; the server passes them on as booleans.
    let enabled = match object.get("enabled") {
        None | Some(Value::Null) => None,
        Some(Value::Bool(on)) => Some(*on),
        Some(Value::String(text)) => Some(text == "true"),
        Some(other) => return Err(format!("`enabled` is not a boolean: {other}")),
    };
    Ok(HostMcpServer {
        name: req_str(object, "name")?,
        harness: req_str(object, "harness")?,
        plugin: opt_str(object, "plugin")?,
        source_id: opt_str(object, "source_id")?,
        url_host: opt_str(object, "url_host")?,
        enabled,
        managed: opt_bool(object, "managed")?.unwrap_or(false),
        locked: opt_bool(object, "locked")?.unwrap_or(false),
        auth_status: opt_str(object, "auth_status")?,
        sign_in_url: opt_str(object, "sign_in_url")?,
    })
}

/// A plugin's entries: entry id and name, or names alone from an older host.
type Entries = Vec<(Option<String>, String)>;

fn entries(
    object: &serde_json::Map<String, Value>,
    key: &str,
    names: &str,
) -> Result<(Entries, bool), String> {
    if let Some(entries) = opt_array(object, key)? {
        let list = entries
            .iter()
            .map(|entry| {
                let entry = as_object(entry, key)?;
                Ok((Some(req_str(entry, "id")?), req_str(entry, "name")?))
            })
            .collect::<Result<Vec<_>, String>>()?;
        return Ok((list, true));
    }
    let list = opt_array(object, names)?
        .into_iter()
        .flatten()
        .map(|name| {
            name.as_str()
                .map(|name| (None, name.to_owned()))
                .ok_or_else(|| format!("`{names}` holds a non-string"))
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok((list, false))
}

fn plugin_from(value: &Value) -> Result<HostPlugin, String> {
    let object = as_object(value, "plugin")?;
    let (skills, has_skill_entries) = entries(object, "skill_entries", "skills")?;
    let (mcp_servers, has_mcp_entries) = entries(object, "mcp_entries", "mcp_servers")?;
    Ok(HostPlugin {
        id: opt_str(object, "id")?,
        name: req_str(object, "name")?,
        marketplace: opt_str(object, "marketplace")?.unwrap_or_default(),
        version: opt_str(object, "version")?,
        description: opt_str(object, "description")?,
        enabled: opt_bool(object, "enabled")?.unwrap_or(false),
        skills,
        mcp_servers,
        has_skill_entries,
        has_mcp_entries,
        has_hooks: opt_bool(object, "has_hooks")?.unwrap_or(false),
        has_commands: opt_bool(object, "has_commands")?.unwrap_or(false),
    })
}

fn list<T>(
    value: &Value,
    path: &str,
    key: &str,
    decode: fn(&Value) -> Result<T, String>,
) -> Result<Vec<T>, SessionError> {
    as_object(value, path)
        .and_then(|object| opt_array(object, key))
        .and_then(|items| items.into_iter().flatten().map(decode).collect())
        .map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        })
}

impl<T: HttpTransport> ClientCore<T> {
    /// `harness`'s MCP servers, skills and plugins on `host_id`, as its Settings page lists
    /// them: each read on its own, so one failing leaves the others.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidInput`] for a harness whose inventory isn't listed;
    /// `InvalidIdentifier` before any request.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn host_harness_inventory(
        &self,
        host_id: &str,
        harness: &str,
    ) -> Result<HostInventory, SessionError> {
        let family = inventory_family(harness).ok_or_else(|| SessionError::InvalidInput {
            reason: format!("{harness} lists no MCP servers, skills or plugins."),
        })?;
        validate_identifier(host_id)?;
        let servers = self.host_mcp_servers(host_id).await;
        let skills = self.host_skills(host_id, harness, "~", None).await;
        let plugins = if family == "claude" {
            self.host_plugins(host_id).await
        } else {
            Ok(None)
        };
        let both_failed = servers.is_err() && skills.is_err();
        let plugins_read = if plugins
            .as_ref()
            .is_ok_and(|found| found.is_some() || !both_failed)
        {
            InventoryRead::Loaded
        } else {
            InventoryRead::Failed
        };
        let inventory = harness_inventory(
            family,
            servers.as_deref().unwrap_or_default(),
            skills
                .as_ref()
                .map(|catalog| catalog.skills.as_slice())
                .unwrap_or_default(),
            plugins.as_ref().ok().and_then(Option::as_deref),
        );
        Ok(HostInventory {
            mcp_servers: read_state(&servers),
            skills: read_state(&skills),
            plugins: plugins_read,
            inventory,
        })
    }

    /// The MCP servers every harness on `host_id` has configured.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; the read errors (409 while the host is
    /// offline, 501 from a host too old to list them); [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn host_mcp_servers(
        &self,
        host_id: &str,
    ) -> Result<Vec<HostMcpServer>, SessionError> {
        validate_identifier(host_id)?;
        let path = format!("/v1/hosts/{host_id}/mcp-servers");
        let value = self.get_json(&path, &[]).await;
        self.dispatch();
        list(&value?, &path, "mcp_servers", mcp_server_from)
    }

    /// Turns a row's server on or off for Omnigent sessions of its harness on `host_id` (`PUT
    /// /v1/hosts/{id}/mcp-servers/enabled`), as the web's switch; the server as it is now. Only
    /// rows with an unlocked [`McpSwitch`] can change.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request, also for a row without a free switch; `Rejected`
    /// for one the host refuses (an organization's, say); the write errors;
    /// `DeliveryUncertain` for an unreadable answer.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn set_host_mcp_server_enabled(
        &self,
        host_id: &str,
        row: &McpRow,
        enabled: bool,
    ) -> Result<HostMcpServer, SessionError> {
        validate_identifier(host_id)?;
        let Some(switch) = row.switch.as_ref().filter(|switch| !switch.locked) else {
            return Err(SessionError::InvalidIdentifier {
                value: row.name.clone(),
            });
        };
        let path = format!("/v1/hosts/{host_id}/mcp-servers/enabled");
        let mut body = serde_json::Map::new();
        body.insert("harness".into(), Value::String(switch.harness.clone()));
        body.insert("server".into(), Value::String(row.name.clone()));
        if let Some(plugin) = &row.plugin {
            body.insert("plugin".into(), Value::String(plugin.clone()));
        }
        if let Some(source_id) = &row.source_id {
            body.insert("source_id".into(), Value::String(source_id.clone()));
        }
        body.insert("enabled".into(), Value::Bool(enabled));
        let result = self.write_json("PUT", &path, &Value::Object(body)).await;
        self.dispatch();
        let value = result?;
        value
            .get("server")
            .ok_or_else(|| "`server` is missing".to_owned())
            .and_then(mcp_server_from)
            .map_err(|detail| SessionError::DeliveryUncertain {
                detail: format!("unreadable {path} answer: {detail}"),
            })
    }

    /// Claude's plugins on `host_id`; `None` from a host or server too old to list them (404
    /// or 501), whose plugins come from the skill and server names instead.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; the other read errors;
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn host_plugins(
        &self,
        host_id: &str,
    ) -> Result<Option<Vec<HostPlugin>>, SessionError> {
        validate_identifier(host_id)?;
        let path = format!("/v1/hosts/{host_id}/plugins");
        let value = self.get_json(&path, &[]).await;
        self.dispatch();
        match value {
            Err(SessionError::HttpStatus { status: 404 | 501 }) => Ok(None),
            Err(error) => Err(error),
            Ok(value) => list(&value, &path, "plugins", plugin_from).map(Some),
        }
    }

    /// A skill's contents on `host_id` for `harness` (`plugin:skill` with its `source_id`
    /// for a plugin's skill).
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; the read errors (404 where the harness shows
    /// none, 501 from an older host); [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn host_skill_content(
        &self,
        host_id: &str,
        harness: &str,
        name: &str,
        source_id: Option<&str>,
    ) -> Result<SkillContent, SessionError> {
        validate_identifier(host_id)?;
        validate_identifier(harness)?;
        // Skill names are folder names, a plugin's prefixed with `plugin:`; anything else is
        // refused rather than sent as a path.
        let plain = !name.is_empty()
            && name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"-_.:".contains(&byte))
            && !name.starts_with('.');
        if !plain {
            return Err(SessionError::InvalidIdentifier {
                value: name.to_owned(),
            });
        }
        let path = format!("/v1/hosts/{host_id}/harnesses/{harness}/skills/{name}");
        let query: Vec<(&str, String)> = source_id
            .map(|id| vec![("source_id", id.to_owned())])
            .unwrap_or_default();
        let value = self.get_json(&path, &query).await;
        self.dispatch();
        let value = value?;
        let decoded = as_object(&value, &path).and_then(|object| {
            Ok(SkillContent {
                name: req_str(object, "name")?,
                description: opt_str(object, "description")?.unwrap_or_default(),
                content: req_str(object, "content")?,
                truncated: opt_bool(object, "truncated")?.unwrap_or(false),
            })
        });
        decoded.map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        })
    }
}

#[cfg(test)]
#[path = "harness_inventory_tests.rs"]
mod tests;
