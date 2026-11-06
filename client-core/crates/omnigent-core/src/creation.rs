//! Session creation: the host and agent catalog, readiness, and selection validation.
//!
//! Port of `NativeLab`'s `SessionCreation.swift`. Everything here is pure; the REST calls
//! (`GET /v1/hosts`, `GET /v1/agents`, `GET /v1/hosts/{id}/filesystem`, model options and
//! `POST /v1/sessions`) are [`crate::ClientCore`] methods in `client::create`.
//!
//! The rules:
//!
//! - Only an explicit `true` readiness for the agent's harness allows creation. `false`, an
//!   unknown value, a missing entry and `"needs-auth"` all block it, the last with a sign-in hint.
//! - Offline hosts and managed-sandbox hosts are unavailable here.
//! - The workspace must be an absolute path, without NUL, and is never guessed.
//! - A model must be one the host advertises for the agent's harness, by its wire value, and not
//!   hidden. Leaving the model unset needs no model catalog at all.

use std::collections::BTreeMap;

use serde_json::{Map, Value};

use crate::client::fork::agent_root_name;
use crate::client::json::{as_object, opt_array, opt_bool, opt_object, opt_str, opt_u64, req_str};
use crate::client::sessions::SessionSummary;
use crate::config::approval::{
    CODEX_BYPASS_LABEL, is_codex_bypass, launch_approval_args, launch_approval_mode_menu,
};
use crate::config::session::{ModelChoice, canonical_harness, harness_label};

/// What a host reports for one harness in `configured_harnesses`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HarnessReadiness {
    /// `true`.
    Ready,
    /// `false`.
    NotReady,
    /// `"needs-auth"`: the harness needs a sign-in on the host.
    NeedsAuthentication,
    /// Any other value. Never treated as ready.
    Unknown,
}

impl HarnessReadiness {
    /// Maps one `configured_harnesses` value.
    #[must_use]
    pub fn from_value(value: &Value) -> Self {
        match value {
            Value::Bool(true) => Self::Ready,
            Value::Bool(false) => Self::NotReady,
            Value::String(text) if text == "needs-auth" => Self::NeedsAuthentication,
            _ => Self::Unknown,
        }
    }
}

/// Decodes a `configured_harnesses` object. `Ok(None)` when absent or null.
pub(crate) fn configured_harnesses(
    object: &Map<String, Value>,
) -> Result<Option<BTreeMap<String, HarnessReadiness>>, String> {
    Ok(
        opt_object(object, "configured_harnesses")?.map(|harnesses| {
            harnesses
                .iter()
                .map(|(name, value)| (name.clone(), HarnessReadiness::from_value(value)))
                .collect()
        }),
    )
}

/// One `GET /v1/hosts` row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreationHost {
    /// Host id.
    pub host_id: String,
    /// Display name.
    pub name: String,
    /// `online`, `offline`, ...
    pub status: String,
    /// Set for managed sandbox hosts, which this client cannot create sessions on.
    pub sandbox_provider: Option<String>,
    /// Per-harness readiness, when reported.
    pub configured_harnesses: Option<BTreeMap<String, HarnessReadiness>>,
}

impl CreationHost {
    /// Decodes one host row.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "host")?;
        Ok(Self {
            host_id: req_str(object, "host_id")?,
            name: req_str(object, "name")?,
            status: req_str(object, "status")?,
            sandbox_provider: opt_str(object, "sandbox_provider")?,
            configured_harnesses: configured_harnesses(object)?,
        })
    }

    /// Online and not a managed sandbox.
    #[must_use]
    pub fn is_available(&self) -> bool {
        self.status == "online" && self.sandbox_provider.is_none()
    }

    fn readiness(&self, harness: &str) -> Option<HarnessReadiness> {
        self.configured_harnesses
            .as_ref()
            .and_then(|harnesses| harnesses.get(harness).copied())
    }
}

/// One `GET /v1/agents` row.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CreationAgent {
    /// Durable agent id.
    pub id: String,
    /// Display name.
    pub name: String,
    /// Harness as sent (aliases included).
    pub harness: Option<String>,
    /// Description.
    pub description: Option<String>,
    /// The server's `builtin` flag; `None` from servers that predate it.
    pub builtin: Option<bool>,
    /// One of the caller's own agents (`GET /v1/agents?scope=user`).
    pub mine: bool,
    /// Last change, in seconds: `updated_at`, else `created_at`.
    pub changed_at: Option<u64>,
}

/// Where the new-session picker lists an agent, as the web groups it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum AgentPickerSection {
    /// A native coding CLI or an ACP harness ("Harnesses"), never one of the caller's own agents.
    Harness,
    /// A built-in composed agent such as Polly ("Agents").
    Agent,
    /// A user-registered or uploaded agent ("Agents", under "Other…").
    Custom,
}

/// Built-in agents by name, for servers that do not send `builtin` (the web's `BUILTIN_AGENTS`).
const BUILTIN_AGENT_NAMES: [&str; 13] = [
    "claude-native-ui",
    "codex-native-ui",
    "opencode-native-ui",
    "pi-native-ui",
    "cursor-native-ui",
    "kiro-native-ui",
    "antigravity-native-ui",
    "goose-native-ui",
    "qwen-native-ui",
    "kimi-native-ui",
    "devin-native-ui",
    "polly",
    "debby",
];

/// Harnesses listed inline in the picker, in order; the rest fold into "Other…".
const PRIMARY_HARNESSES: [&str; 3] = ["claude-native", "cursor-native", "codex-native"];

/// ACP CLI harnesses from before the `acp:` prefix.
const LEGACY_ACP_HARNESSES: [&str; 2] = ["devin", "grok"];

/// Native harnesses whose wrapper carries chat and approvals through the session API.
const WRAPPED_NATIVE: [&str; 5] = [
    "codex-native",
    "cursor-native",
    "kiro-native",
    "pi-native",
    "opencode-native",
];

/// Non-native harnesses the app can create sessions for.
const CREATABLE: [&str; 5] = ["codex", "claude-sdk", "openai-agents", "pi", "antigravity"];

impl CreationAgent {
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
            harness: opt_str(object, "harness")?,
            description: opt_str(object, "description")?,
            builtin: opt_bool(object, "builtin")?,
            mine: false,
            changed_at: opt_u64(object, "updated_at")?.or(opt_u64(object, "created_at")?),
        })
    }

    /// The picker section: harness-backed rows unless the agent is the caller's own, then
    /// built-ins (the server's flag, else the known names), then everything else.
    #[must_use]
    pub fn picker_section(&self) -> AgentPickerSection {
        let harness = self.harness_id();
        let harness_backed = harness.ends_with("-native")
            || harness.starts_with("acp:")
            || LEGACY_ACP_HARNESSES.contains(&harness.as_str());
        if harness_backed && !self.mine {
            return AgentPickerSection::Harness;
        }
        let builtin = !self.mine
            && self
                .builtin
                .unwrap_or_else(|| BUILTIN_AGENT_NAMES.contains(&self.name.as_str()));
        if builtin {
            AgentPickerSection::Agent
        } else {
            AgentPickerSection::Custom
        }
    }

    /// A harness listed inline rather than under "Other…" (Claude Code, Cursor, Codex).
    #[must_use]
    pub fn is_primary_harness(&self) -> bool {
        self.picker_section() == AgentPickerSection::Harness
            && PRIMARY_HARNESSES.contains(&self.harness_id().as_str())
    }

    /// The picker's order within a section: primary harnesses first in their order, then the
    /// rest as listed.
    #[must_use]
    pub fn picker_rank(&self) -> usize {
        let harness = self.harness_id();
        PRIMARY_HARNESSES
            .iter()
            .position(|primary| *primary == harness)
            .unwrap_or(PRIMARY_HARNESSES.len())
    }

    /// The canonical harness id.
    #[must_use]
    pub fn harness_id(&self) -> String {
        canonical_harness(self.harness.as_deref())
    }

    /// The harness display label.
    #[must_use]
    pub fn harness_label(&self) -> String {
        harness_label(self.harness.as_deref())
    }

    /// The `omnigent.wrapper` label for native harnesses with a session-API wrapper.
    #[must_use]
    pub fn wrapper(&self) -> Option<String> {
        let harness = self.harness_id();
        if harness == "claude-native" {
            return Some("claude-code-native-ui".to_owned());
        }
        WRAPPED_NATIVE
            .contains(&harness.as_str())
            .then(|| format!("{harness}-ui"))
    }

    /// Whether this app can create a session for the agent's harness.
    #[must_use]
    pub fn supports_creation(&self) -> bool {
        self.wrapper().is_some() || CREATABLE.contains(&self.harness_id().as_str())
    }

    /// Whether the host can preview models for the agent's harness.
    #[must_use]
    pub fn supports_model_preview(&self) -> bool {
        self.wrapper().is_some()
    }
}

/// A directory offered as a session workspace.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreationWorkspace {
    /// Absolute path.
    pub path: String,
    /// Display name.
    pub name: String,
}

/// What the user chose in the new-session form.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CreationSelection {
    /// Host id.
    pub host_id: String,
    /// Agent id.
    pub agent_id: String,
    /// Workspace path, as typed.
    pub workspace: String,
    /// The model's wire value, or `None` for the harness default.
    pub model: Option<String>,
    /// The reasoning effort, or `None` for the model default.
    pub reasoning_effort: Option<String>,
    /// The approval mode to launch in (a value of [`launch_approval_mode_menu`]), or `None` for
    /// the harness default.
    pub approval_mode: Option<String>,
    /// A git worktree to create or start in, or `None` to start in the workspace itself.
    pub git: Option<CreationGit>,
    /// Start a Codex session in Plan mode (see [`CreationCatalog::starts_in_plan_mode`]).
    pub plan_mode: bool,
    /// The first-class project the session is filed in from its creation (`project_id`).
    pub project_id: Option<String>,
    /// Smart Routing picks the model and effort each turn (see
    /// [`CreationCatalog::offers_smart_routing`]); no model or effort is pinned with it.
    pub smart_routing: bool,
}

/// The `git` block of a new external-host session.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CreationGit {
    /// The branch: a new worktree's, or an existing worktree's.
    pub branch_name: String,
    /// What a new worktree branches from; `None` for the repository default.
    pub base_branch: Option<String>,
    /// Start in an existing worktree (records its branch) instead of creating one.
    pub existing_worktree: bool,
}

/// A new sandbox the server provisions for a session (`host_type: "managed"`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SandboxTarget {
    /// The provider; `None` takes the server's default.
    pub provider: Option<String>,
    /// The profile to launch with, by id and the revision the user chose.
    pub profile: Option<(String, String)>,
    /// `<url>[#<branch>]` repositories to clone; empty for an empty sandbox.
    pub workspaces: Vec<String>,
    /// A fresh 32-hex id for the sandbox host, sent when the server asks clients to name it
    /// (`request_managed_sandbox_host_id`).
    pub host_id: Option<String>,
}

/// One git worktree of a repository on a host (`GET /v1/hosts/{id}/worktrees`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HostWorktree {
    /// Absolute path.
    pub path: String,
    /// Checked-out branch; `None` when detached.
    pub branch: Option<String>,
    /// The repository's main worktree.
    pub is_main: bool,
}

impl HostWorktree {
    /// Decodes one worktree row.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "worktree")?;
        Ok(Self {
            path: req_str(object, "path")?,
            branch: opt_str(object, "branch")?,
            is_main: opt_bool(object, "is_main")?.unwrap_or(false),
        })
    }
}

/// A file or folder on a host, for the new-session `@` menu.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostEntry {
    /// Absolute path.
    pub path: String,
    /// Display name.
    pub name: String,
    /// A folder rather than a file.
    pub is_directory: bool,
}

/// A directory on a host and the directories in it, for the folder browser.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HostDirectoryListing {
    /// The listed directory; `None` when the host's home was listed and it held nothing.
    pub path: Option<String>,
    /// Its parent; `None` at `/`.
    pub parent: Option<String>,
    /// Directories in it, by name.
    pub directories: Vec<CreationWorkspace>,
}

/// The parent of an absolute `path`; `None` at `/`.
#[must_use]
pub fn parent_directory(path: &str) -> Option<String> {
    let trimmed = path.trim_end_matches('/');
    let (parent, _) = trimmed.rsplit_once('/')?;
    Some(if parent.is_empty() {
        "/".to_owned()
    } else {
        parent.to_owned()
    })
}

/// Why a session cannot be created, or what happened to a creation request.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CreationError {
    /// The selection cannot be created; nothing was sent.
    #[error("{0}")]
    Unavailable(String),
    /// The server rejected the request (400, 415 or 422) and created nothing.
    #[error("{message}")]
    Rejected {
        /// HTTP status.
        status: u16,
        /// The server's explanation, or a generic one.
        message: String,
    },
    /// The server may have created the session, but confirmation was lost. Never retried.
    #[error(
        "The server may have created this session, but confirmation was lost. Close this form and refresh Sessions before starting another. Your first message has not been sent."
    )]
    Uncertain,
}

/// What `GET /v1/info` says the server offers for session creation. Missing fields mean
/// unsupported.
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent server capability flags, mirrored one to one from /v1/info"
)]
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CreationCapabilities {
    /// `agent_install`: the caller's own agents are listed with `GET /v1/agents?scope=user`.
    pub agent_install: bool,
    /// `managed_sandboxes_enabled`: sessions can start on a new sandbox the server provisions.
    pub managed_sandboxes: bool,
    /// `sandbox_providers`: the configured sandbox providers, the default first.
    pub sandbox_providers: Vec<String>,
    /// `features.codex_plan_at_launch`: a Codex session can start in Plan mode.
    pub codex_plan_at_launch: bool,
    /// `sandbox_provider`: the default sandbox provider; `None` when the server names none.
    pub default_sandbox_provider: Option<String>,
    /// Providers whose `sandbox_provider_capabilities` report `multi_repo`.
    pub multi_repo_providers: Vec<String>,
    /// `features.sandbox_profiles`: sandboxes launch with a server-defined profile.
    pub sandbox_profiles: bool,
    /// `request_managed_sandbox_host_id`: a sandbox create names its new host's id.
    pub mints_sandbox_host_id: bool,
    /// `enabled_connections` has `github`: the repository picker lists the caller's repos.
    pub github_connection: bool,
    /// `session_fork_workspaces`: a sandbox fork can change several repositories.
    pub fork_workspaces: bool,
    /// `features.custom_agents_settings_ui`: Settings lists and edits custom agents.
    pub custom_agents_settings: bool,
    /// `agent_detail`: an agent's configuration can be read.
    pub agent_detail: bool,
    /// `smart_routing_enabled`, with a router that answers for native Claude Code and Codex
    /// panes (`smart_routing_sources`).
    pub smart_routing: bool,
}

impl CreationCapabilities {
    /// The sandbox rows the new-session host menu offers, the default first: each configured
    /// provider, else the one default (`None` for the generic "New Sandbox"). Empty when the
    /// server provisions no sandboxes.
    #[must_use]
    pub fn sandbox_provider_options(&self) -> Vec<Option<String>> {
        if !self.managed_sandboxes {
            Vec::new()
        } else if self.sandbox_providers.is_empty() {
            vec![self.default_sandbox_provider.clone()]
        } else {
            self.sandbox_providers.iter().cloned().map(Some).collect()
        }
    }

    /// How many repositories a sandbox of `provider` (`None` for the default) clones.
    #[must_use]
    pub fn max_sandbox_repos(&self, provider: Option<&str>) -> usize {
        let provider = provider.or(self.default_sandbox_provider.as_deref());
        if provider.is_some_and(|name| self.multi_repo_providers.iter().any(|p| p == name)) {
            crate::sandbox::MAX_SANDBOX_REPOS
        } else {
            1
        }
    }

    /// Whether sandboxes launch with a server-defined profile.
    #[must_use]
    pub const fn sandbox_profiles_enabled(&self) -> bool {
        self.sandbox_profiles && self.managed_sandboxes
    }

    /// Whether Settings lists and edits custom agents (the web's `customAgentsSettingsEnabled`).
    #[must_use]
    pub const fn custom_agents_settings_enabled(&self) -> bool {
        self.custom_agents_settings && self.agent_install
    }

    /// Decodes the creation fields of a `/v1/info` body.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "/v1/info")?;
        let sandbox_providers = opt_array(object, "sandbox_providers")?
            .map(|providers| {
                providers
                    .iter()
                    .map(|provider| {
                        provider
                            .as_str()
                            .map(str::to_owned)
                            .ok_or_else(|| "`sandbox_providers` holds a non-string".to_owned())
                    })
                    .collect::<Result<Vec<_>, String>>()
            })
            .transpose()?
            .unwrap_or_default();
        let features = opt_object(object, "features")?;
        let feature = |name: &str| {
            features
                .and_then(|features| features.get(name))
                .and_then(Value::as_bool)
                .unwrap_or(false)
        };
        let multi_repo_providers = opt_object(object, "sandbox_provider_capabilities")?
            .map(|providers| {
                providers
                    .iter()
                    .filter(|(_, flags)| {
                        flags.get("multi_repo").and_then(Value::as_bool) == Some(true)
                    })
                    .map(|(provider, _)| provider.clone())
                    .collect()
            })
            .unwrap_or_default();
        let github_connection = opt_array(object, "enabled_connections")?
            .is_some_and(|names| names.iter().any(|name| name.as_str() == Some("github")));
        Ok(Self {
            agent_install: opt_bool(object, "agent_install")?.unwrap_or(false),
            managed_sandboxes: opt_bool(object, "managed_sandboxes_enabled")?.unwrap_or(false),
            sandbox_providers,
            codex_plan_at_launch: feature("codex_plan_at_launch"),
            default_sandbox_provider: opt_str(object, "sandbox_provider")?
                .filter(|provider| !provider.is_empty()),
            multi_repo_providers,
            sandbox_profiles: feature("sandbox_profiles"),
            mints_sandbox_host_id: opt_bool(object, "request_managed_sandbox_host_id")?
                .unwrap_or(false),
            github_connection,
            fork_workspaces: opt_bool(object, "session_fork_workspaces")?.unwrap_or(false),
            custom_agents_settings: feature("custom_agents_settings_ui"),
            agent_detail: opt_bool(object, "agent_detail")?.unwrap_or(false),
            smart_routing: {
                let options = crate::slash::SlashOptions::from_info(value)?;
                options.smart_routing && options.routes_native_panes
            },
        })
    }
}

/// The native Codex harness, which can start in Plan mode.
const CODEX_NATIVE: &str = "codex-native";

/// The label that starts a Codex session in Plan mode (the web's
/// `CODEX_NATIVE_COLLABORATION_MODE_LABEL_KEY`).
const CODEX_COLLABORATION_MODE_LABEL: &str = "omnigent.codex_native.collaboration_mode";

/// The hosts and agents a session can be created with.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CreationCatalog {
    /// Hosts, de-duplicated by id.
    pub hosts: Vec<CreationHost>,
    /// Agents, de-duplicated by id: the server's catalog, then the caller's own.
    pub agents: Vec<CreationAgent>,
    /// What the server offers.
    pub capabilities: CreationCapabilities,
}

/// The caller's own agents to list after `catalog`: one per root name, the one changed last,
/// skipping names and ids the catalog already has (the web's `mergeAvailableAgents`).
#[must_use]
pub fn merge_user_agents(
    catalog: &[CreationAgent],
    user: Vec<CreationAgent>,
) -> Vec<CreationAgent> {
    let taken_names: std::collections::BTreeSet<&str> = catalog
        .iter()
        .filter(|agent| agent.builtin != Some(false))
        .map(|agent| agent_root_name(&agent.name))
        .collect();
    let taken_ids: std::collections::BTreeSet<&str> =
        catalog.iter().map(|agent| agent.id.as_str()).collect();
    let mut by_name: BTreeMap<String, CreationAgent> = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();
    for mut agent in user {
        let root = agent_root_name(&agent.name).to_owned();
        if taken_ids.contains(agent.id.as_str()) || taken_names.contains(root.as_str()) {
            continue;
        }
        agent.mine = true;
        match by_name.get(&root) {
            Some(existing) if existing.changed_at.unwrap_or(0) > agent.changed_at.unwrap_or(0) => {}
            Some(_) => {
                by_name.insert(root, agent);
            }
            None => {
                order.push(root.clone());
                by_name.insert(root, agent);
            }
        }
    }
    order
        .into_iter()
        .filter_map(|root| by_name.remove(&root))
        .collect()
}

/// The title limit, in characters.
pub const MAX_TITLE_CHARS: usize = 120;

impl CreationCatalog {
    /// Whether a session of `agent_id` can start in Plan mode through
    /// [`CreationSelection::plan_mode`]: a native Codex agent on a server that supports it.
    /// (Claude Code starts in Plan mode through its `plan` approval mode instead.)
    #[must_use]
    pub fn starts_in_plan_mode(&self, agent_id: &str) -> bool {
        self.capabilities.codex_plan_at_launch
            && self
                .agent(agent_id)
                .is_some_and(|agent| agent.harness_id() == CODEX_NATIVE)
    }

    /// Whether a new session of `agent_id` can turn Smart Routing on (the web's per-harness
    /// `smartRoutingEligible`): the server routes native panes and the agent runs Claude Code or
    /// Codex natively.
    #[must_use]
    pub fn offers_smart_routing(&self, agent_id: &str) -> bool {
        self.capabilities.smart_routing
            && self.agent(agent_id).is_some_and(|agent| {
                crate::slash::ROUTED_NATIVE_HARNESSES.contains(&agent.harness_id().as_str())
            })
    }

    /// The agent with `agent_id`.
    #[must_use]
    pub fn agent(&self, agent_id: &str) -> Option<&CreationAgent> {
        self.agents.iter().find(|agent| agent.id == agent_id)
    }

    /// Why `agent_id` cannot be created on `host_id`, or `None` when it can.
    #[must_use]
    pub fn unavailable_reason(&self, agent_id: &str, host_id: &str) -> Option<String> {
        let reason = |text: &str| Some(text.to_owned());
        let Some(host) = self.hosts.iter().find(|host| host.host_id == host_id) else {
            return reason("Choose an existing host.");
        };
        if host.sandbox_provider.is_some() {
            return reason("Managed sandbox creation is not available here.");
        }
        if host.status != "online" {
            return reason("Connect this host before starting a session.");
        }
        let Some(agent) = self.agent(agent_id) else {
            return reason("Choose a registered agent.");
        };
        if !agent.supports_creation() {
            return reason("This agent's harness is not supported for creation in this app.");
        }
        let readiness = host
            .readiness(&agent.harness_id())
            .or_else(|| agent.harness.as_deref().and_then(|raw| host.readiness(raw)));
        match readiness {
            Some(HarnessReadiness::Ready) => None,
            Some(HarnessReadiness::NeedsAuthentication) => {
                reason("Sign in to this harness on the host first.")
            }
            None => reason("The host has not reported readiness for this harness."),
            Some(HarnessReadiness::NotReady | HarnessReadiness::Unknown) => {
                reason("Configure this harness on the host before starting a session.")
            }
        }
    }

    /// Checks `selection` against this catalog and the host's advertised `models`.
    ///
    /// # Errors
    ///
    /// [`CreationError::Unavailable`] with the reason.
    pub fn validate(
        &self,
        selection: &CreationSelection,
        models: &[ModelChoice],
    ) -> Result<(), CreationError> {
        if let Some(reason) = self.unavailable_reason(&selection.agent_id, &selection.host_id) {
            return Err(CreationError::Unavailable(reason));
        }
        let path = selection.workspace.trim();
        if !path.starts_with('/') || path.contains('\0') {
            return Err(CreationError::Unavailable(
                "Enter an absolute workspace path beginning with /.".to_owned(),
            ));
        }
        if let Some(git) = &selection.git
            && !is_branch_name(&git.branch_name)
        {
            return Err(CreationError::Unavailable(
                "Enter a branch name without spaces, `..` or a leading `-`.".to_owned(),
            ));
        }
        self.approval_mode_offered(selection)?;
        if selection.smart_routing && !self.offers_smart_routing(&selection.agent_id) {
            return Err(CreationError::Unavailable(
                "Smart Routing is not available for this agent.".to_owned(),
            ));
        }
        if let Some(model) = selection
            .model
            .as_ref()
            .filter(|_| !selection.smart_routing)
        {
            let previewable = self
                .agent(&selection.agent_id)
                .is_some_and(CreationAgent::supports_model_preview);
            let advertised = models
                .iter()
                .any(|choice| choice.value() == model && choice.hidden != Some(true));
            if !previewable || !advertised {
                return Err(CreationError::Unavailable(
                    "This model is not currently advertised by the selected host.".to_owned(),
                ));
            }
        }
        Ok(())
    }

    /// Checks a session on a new sandbox: the server provisions them (and `target`'s provider),
    /// the agent is registered and its approval mode offered, and the repositories fit the
    /// provider. The host, workspace and model of `selection` are not used.
    ///
    /// # Errors
    ///
    /// [`CreationError::Unavailable`] with the reason.
    pub fn validate_sandbox(
        &self,
        selection: &CreationSelection,
        target: &SandboxTarget,
    ) -> Result<(), CreationError> {
        let unavailable = |text: String| Err(CreationError::Unavailable(text));
        let offered = self.capabilities.sandbox_provider_options();
        if offered.is_empty()
            || target
                .provider
                .as_ref()
                .is_some_and(|provider| !offered.contains(&Some(provider.clone())))
        {
            return unavailable("This server does not offer that sandbox.".into());
        }
        if self.agent(&selection.agent_id).is_none() {
            return unavailable("Choose a registered agent.".into());
        }
        self.approval_mode_offered(selection)?;
        let repos: Vec<_> = target
            .workspaces
            .iter()
            .map(|workspace| crate::sandbox::split_sandbox_workspace(workspace))
            .collect();
        let max = self
            .capabilities
            .max_sandbox_repos(target.provider.as_deref());
        if let Some(problem) = crate::sandbox::sandbox_repos_problem(&repos, max) {
            return unavailable(problem);
        }
        Ok(())
    }

    fn approval_mode_offered(&self, selection: &CreationSelection) -> Result<(), CreationError> {
        let Some(mode) = &selection.approval_mode else {
            return Ok(());
        };
        let wrapper = self
            .agent(&selection.agent_id)
            .and_then(CreationAgent::wrapper);
        let offered = launch_approval_mode_menu(wrapper.as_deref())
            .is_some_and(|menu| menu.options.iter().any(|option| &option.value == mode));
        if offered {
            Ok(())
        } else {
            Err(CreationError::Unavailable(
                "This agent cannot start in that approval mode.".to_owned(),
            ))
        }
    }
}

/// What a successful `POST /v1/sessions` returned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreationReceipt {
    /// The created session. A usable id is the acknowledgement, whatever else the body holds.
    pub session_id: String,
    /// The created session's summary, when the body is a snapshot this client can read.
    pub summary: Option<SessionSummary>,
}

/// The `POST /v1/sessions` body for an external-host session: no initial prompt, no harness
/// override and no launch args.
pub(crate) fn creation_body(
    selection: &CreationSelection,
    title: &str,
    agent: &CreationAgent,
    first_message: Option<&str>,
) -> Value {
    let mut body = Map::new();
    body.insert("agent_id".into(), Value::String(selection.agent_id.clone()));
    body.insert("host_id".into(), Value::String(selection.host_id.clone()));
    body.insert("host_type".into(), Value::String("external".into()));
    body.insert(
        "workspace".into(),
        Value::String(selection.workspace.trim().to_owned()),
    );
    if !title.is_empty() {
        body.insert("title".into(), Value::String(title.to_owned()));
    }
    insert_run_configuration(&mut body, selection, agent);
    // A native pane launches with the row, so Smart Routing picks its model from the first
    // message at creation or not at all.
    if let Some(message) =
        first_message.filter(|text| selection.smart_routing && !text.trim().is_empty())
    {
        body.insert(
            "smart_routing_message".into(),
            Value::String(message.to_owned()),
        );
    }
    if let Some(git) = &selection.git {
        let mut block = Map::new();
        block.insert(
            "branch_name".into(),
            Value::String(git.branch_name.trim().to_owned()),
        );
        if git.existing_worktree {
            block.insert("existing_worktree".into(), Value::Bool(true));
        } else if let Some(base) = git.base_branch.as_deref().map(str::trim)
            && !base.is_empty()
        {
            block.insert("base_branch".into(), Value::String(base.to_owned()));
        }
        body.insert("git".into(), Value::Object(block));
    }
    Value::Object(body)
}

/// The project, model, effort, approval launch flags and the native wrapper's labels of a new
/// session. Codex's launch-only bypass rides a label instead of flags.
pub(crate) fn insert_run_configuration(
    body: &mut Map<String, Value>,
    selection: &CreationSelection,
    agent: &CreationAgent,
) {
    if let Some(project) = &selection.project_id {
        body.insert("project_id".into(), Value::String(project.clone()));
    }
    if selection.smart_routing {
        // The router owns the model: a pinned one would turn routing off for the session.
        body.insert(
            "cost_control_mode_override".into(),
            Value::String("on".into()),
        );
    } else {
        if let Some(model) = &selection.model {
            body.insert("model_override".into(), Value::String(model.clone()));
        }
        if let Some(effort) = &selection.reasoning_effort {
            body.insert("reasoning_effort".into(), Value::String(effort.clone()));
        }
    }
    let wrapper = agent.wrapper();
    if let Some(args) = selection
        .approval_mode
        .as_deref()
        .and_then(|mode| launch_approval_args(wrapper.as_deref(), mode))
    {
        body.insert(
            "terminal_launch_args".into(),
            Value::Array(args.into_iter().map(Value::String).collect()),
        );
    }
    if let Some(wrapper) = wrapper {
        let mut labels = Map::new();
        labels.insert("omnigent.ui".into(), Value::String("terminal".into()));
        if is_codex_bypass(Some(&wrapper), selection.approval_mode.as_deref()) {
            labels.insert(CODEX_BYPASS_LABEL.into(), Value::String("1".into()));
        }
        labels.insert("omnigent.wrapper".into(), Value::String(wrapper));
        if selection.plan_mode && agent.harness_id() == CODEX_NATIVE {
            labels.insert(
                CODEX_COLLABORATION_MODE_LABEL.into(),
                Value::String("plan".into()),
            );
        }
        body.insert("labels".into(), Value::Object(labels));
    }
}

/// The `POST /v1/sessions` body for a session on a new sandbox the server provisions: the
/// agent and its run configuration, `host_type: "managed"`, the repositories to clone (`[]` for
/// an empty sandbox), and the provider, profile and host id when chosen.
pub(crate) fn sandbox_creation_body(
    selection: &CreationSelection,
    target: &SandboxTarget,
    title: &str,
    agent: &CreationAgent,
) -> Value {
    let mut body = Map::new();
    body.insert("agent_id".into(), Value::String(selection.agent_id.clone()));
    body.insert("host_type".into(), Value::String("managed".into()));
    body.insert(
        "workspaces".into(),
        Value::Array(
            target
                .workspaces
                .iter()
                .cloned()
                .map(Value::String)
                .collect(),
        ),
    );
    if let Some(provider) = &target.provider {
        body.insert("sandbox_provider".into(), Value::String(provider.clone()));
    }
    if let Some((id, revision)) = &target.profile {
        body.insert("sandbox_profile_id".into(), Value::String(id.clone()));
        body.insert(
            "sandbox_profile_revision".into(),
            Value::String(revision.clone()),
        );
    }
    if let Some(host_id) = &target.host_id {
        body.insert("host_id".into(), Value::String(host_id.clone()));
    }
    if !title.is_empty() {
        body.insert("title".into(), Value::String(title.to_owned()));
    }
    if selection.project_id.is_some() {
        // A project's configured path workspace or git block would be filled in otherwise, and
        // a managed create refuses both.
        body.insert("workspace".into(), Value::Null);
        body.insert("git".into(), Value::Null);
    }
    insert_run_configuration(&mut body, selection, agent);
    Value::Object(body)
}

/// A git branch name the server accepts: non-empty, no whitespace, control characters, `..`,
/// `~^:?*[\\`, no leading `-` or `/`, no trailing `/`, `.` or `.lock`.
#[must_use]
pub fn is_branch_name(name: &str) -> bool {
    let name = name.trim();
    !name.is_empty()
        && !name.starts_with(['-', '/'])
        && !name.ends_with(['/', '.'])
        && !name.to_ascii_lowercase().ends_with(".lock")
        && !name.contains("..")
        && !name.contains("//")
        && !name.contains("@{")
        && !name
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || "~^:?*[\\".contains(c))
}

/// The server's explanation for a rejected creation: `error.message`, `detail`, or the joined
/// `detail[].msg` of a validation error, at most 1000 characters.
pub(crate) fn creation_rejection(body: &[u8], status: u16) -> String {
    let fallback =
        || format!("The server rejected session creation (HTTP {status}). Review your choices.");
    let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(body) else {
        return fallback();
    };
    let message = object
        .get("error")
        .and_then(|error| error.get("message"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| {
            object
                .get("detail")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .or_else(|| {
            object.get("detail").and_then(Value::as_array).map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.get("msg").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("; ")
            })
        });
    message
        .filter(|text| !text.is_empty())
        .map_or_else(fallback, |text| text.chars().take(1000).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn selection() -> CreationSelection {
        CreationSelection {
            host_id: "host_a".into(),
            agent_id: "ag_codex".into(),
            workspace: "/work/project".into(),
            model: None,
            ..CreationSelection::default()
        }
    }

    fn host(status: &str, harnesses: Option<&[(&str, HarnessReadiness)]>) -> CreationHost {
        CreationHost {
            host_id: "host_a".into(),
            name: "Mac".into(),
            status: status.into(),
            sandbox_provider: None,
            configured_harnesses: harnesses.map(|entries| {
                entries
                    .iter()
                    .map(|(name, readiness)| ((*name).to_owned(), *readiness))
                    .collect()
            }),
        }
    }

    fn agent(id: &str, harness: Option<&str>) -> CreationAgent {
        CreationAgent {
            id: id.into(),
            name: "Custom Codex".into(),
            harness: harness.map(str::to_owned),
            description: None,
            ..CreationAgent::default()
        }
    }

    fn catalog() -> CreationCatalog {
        CreationCatalog {
            hosts: vec![host(
                "online",
                Some(&[("codex-native", HarnessReadiness::Ready)]),
            )],
            agents: vec![agent("ag_codex", Some("codex-native"))],
            ..CreationCatalog::default()
        }
    }

    fn model(id: &str, wire: Option<&str>, hidden: Option<bool>) -> ModelChoice {
        ModelChoice {
            id: id.into(),
            model: wire.map(str::to_owned),
            hidden,
            ..ModelChoice::default()
        }
    }

    #[test]
    fn codex_starts_in_plan_mode_only_when_the_server_supports_it() {
        let mut catalog = catalog();
        assert!(!catalog.starts_in_plan_mode("ag_codex"));
        catalog.capabilities = CreationCapabilities::from_value(&serde_json::json!({
            "features": {"codex_plan_at_launch": true}
        }))
        .unwrap();
        assert!(catalog.starts_in_plan_mode("ag_codex"));
        let planned = CreationSelection {
            plan_mode: true,
            ..selection()
        };
        let codex = agent("ag_codex", Some("codex-native"));
        let body = creation_body(&planned, "", &codex, None);
        assert_eq!(
            body["labels"][CODEX_COLLABORATION_MODE_LABEL],
            Value::String("plan".into())
        );
        let claude = agent("ag_claude", Some("claude-native"));
        assert!(
            creation_body(&planned, "", &claude, None)["labels"]
                .get(CODEX_COLLABORATION_MODE_LABEL)
                .is_none()
        );
    }

    #[test]
    fn smart_routing_is_offered_for_native_panes_and_owns_the_model() {
        let mut catalog = catalog();
        catalog
            .agents
            .push(agent("ag_claude", Some("claude-native")));
        catalog.agents.push(agent("ag_sdk", Some("claude-sdk")));
        assert!(!catalog.offers_smart_routing("ag_codex"));
        catalog.capabilities = CreationCapabilities::from_value(&serde_json::json!({
            "smart_routing_enabled": true,
            "smart_routing_sources": {"external": false, "oss": false}
        }))
        .unwrap();
        assert!(
            !catalog.offers_smart_routing("ag_codex"),
            "no router answers"
        );
        catalog.capabilities = CreationCapabilities::from_value(&serde_json::json!({
            "smart_routing_enabled": true
        }))
        .unwrap();
        assert!(catalog.offers_smart_routing("ag_codex"));
        assert!(catalog.offers_smart_routing("ag_claude"));
        assert!(!catalog.offers_smart_routing("ag_sdk"));
        let routed = CreationSelection {
            smart_routing: true,
            model: Some("gpt-5".into()),
            reasoning_effort: Some("high".into()),
            ..selection()
        };
        // A routed session pins no model, so a stale one is not checked.
        assert_eq!(catalog.validate(&routed, &[]), Ok(()));
        let mut unrouted = catalog.clone();
        unrouted.capabilities = CreationCapabilities::from_value(&serde_json::json!({})).unwrap();
        assert_eq!(
            unrouted.validate(&routed, &[]),
            Err(CreationError::Unavailable(
                "Smart Routing is not available for this agent.".into()
            ))
        );
        let codex = agent("ag_codex", Some("codex-native"));
        let body = creation_body(&routed, "", &codex, Some("Fix the build"));
        assert_eq!(body["cost_control_mode_override"], "on");
        assert_eq!(body["smart_routing_message"], "Fix the build");
        assert!(body.get("model_override").is_none());
        assert!(body.get("reasoning_effort").is_none());
        let blank = creation_body(&routed, "", &codex, Some("  "));
        assert!(blank.get("smart_routing_message").is_none());
        let pinned = creation_body(&selection(), "", &codex, Some("Fix the build"));
        assert!(pinned.get("cost_control_mode_override").is_none());
        assert!(pinned.get("smart_routing_message").is_none());
    }

    #[test]
    fn only_explicit_readiness_allows_creation() {
        for readiness in [
            HarnessReadiness::NotReady,
            HarnessReadiness::Unknown,
            HarnessReadiness::NeedsAuthentication,
        ] {
            let catalog = CreationCatalog {
                hosts: vec![host("online", Some(&[("codex-native", readiness)]))],
                agents: vec![agent("ag_codex", Some("codex-native"))],
                ..CreationCatalog::default()
            };
            assert!(
                catalog.validate(&selection(), &[]).is_err(),
                "{readiness:?}"
            );
            if readiness == HarnessReadiness::NeedsAuthentication {
                assert!(
                    catalog
                        .unavailable_reason("ag_codex", "host_a")
                        .unwrap()
                        .contains("Sign in")
                );
            }
        }
        assert_eq!(catalog().validate(&selection(), &[]), Ok(()));
        for (value, expected) in [
            (serde_json::json!(true), HarnessReadiness::Ready),
            (serde_json::json!(false), HarnessReadiness::NotReady),
            (
                serde_json::json!("needs-auth"),
                HarnessReadiness::NeedsAuthentication,
            ),
            (serde_json::json!("future"), HarnessReadiness::Unknown),
            (serde_json::json!(1), HarnessReadiness::Unknown),
        ] {
            assert_eq!(HarnessReadiness::from_value(&value), expected, "{value}");
        }
    }

    #[test]
    fn offline_managed_unknown_harness_and_missing_readiness_are_unavailable() {
        let ready = [("codex-native", HarnessReadiness::Ready)];
        let mut managed = host("online", Some(&ready));
        managed.sandbox_provider = Some("modal".into());
        for host in [host("offline", Some(&ready)), managed, host("online", None)] {
            let catalog = CreationCatalog {
                hosts: vec![host],
                agents: catalog().agents,
                ..CreationCatalog::default()
            };
            assert!(catalog.validate(&selection(), &[]).is_err());
        }
        let unknown = CreationCatalog {
            hosts: catalog().hosts,
            agents: vec![CreationAgent {
                name: "codex-native-ui".into(),
                ..agent("ag_codex", None)
            }],
            ..CreationCatalog::default()
        };
        assert!(unknown.validate(&selection(), &[]).is_err());
        assert!(!agent("ag_future", Some("future-native")).supports_creation());
    }

    #[test]
    fn workspace_and_model_are_validated_without_guessing() {
        for path in ["", "~/project", "relative", "/work\0project"] {
            let value = CreationSelection {
                workspace: path.into(),
                ..selection()
            };
            assert!(catalog().validate(&value, &[]).is_err(), "{path:?}");
        }
        let mut value = CreationSelection {
            model: Some("wire-value".into()),
            ..selection()
        };
        assert!(catalog().validate(&value, &[]).is_err());
        assert!(
            catalog()
                .validate(&value, &[model("id", Some("wire-value"), Some(true))])
                .is_err()
        );
        assert_eq!(
            catalog().validate(&value, &[model("id", Some("wire-value"), None)]),
            Ok(())
        );
        value.model = Some("id".into());
        assert!(
            catalog()
                .validate(&value, &[model("id", Some("wire-value"), None)])
                .is_err()
        );
    }

    #[test]
    fn canonical_native_aliases_preserve_wrapper_contract() {
        for (harness, wrapper) in [
            ("claude-native", "claude-code-native-ui"),
            ("codex-native", "codex-native-ui"),
            ("native-pi", "pi-native-ui"),
            ("native-cursor", "cursor-native-ui"),
            ("native-kiro", "kiro-native-ui"),
            ("native-opencode", "opencode-native-ui"),
        ] {
            assert_eq!(
                agent("a", Some(harness)).wrapper().as_deref(),
                Some(wrapper),
                "{harness}"
            );
        }
    }

    #[test]
    fn rejection_text_prefers_server_explanations() {
        assert_eq!(
            creation_rejection(br#"{"error":{"message":"workspace does not exist"}}"#, 400),
            "workspace does not exist"
        );
        assert_eq!(
            creation_rejection(br#"{"detail":"bad host"}"#, 422),
            "bad host"
        );
        assert_eq!(
            creation_rejection(br#"{"detail":[{"msg":"a"},{"msg":"b"}]}"#, 422),
            "a; b"
        );
        assert_eq!(
            creation_rejection(b"<html>", 415),
            "The server rejected session creation (HTTP 415). Review your choices."
        );
        let long = format!(r#"{{"detail":"{}"}}"#, "x".repeat(2000));
        assert_eq!(
            creation_rejection(long.as_bytes(), 400).chars().count(),
            1000
        );
    }

    #[test]
    fn picker_sections_follow_the_web_grouping() {
        use AgentPickerSection::{Agent, Custom, Harness};
        let row = |name: &str, harness: &str, builtin: Option<bool>, mine: bool| CreationAgent {
            name: name.into(),
            harness: Some(harness.into()),
            builtin,
            mine,
            ..agent("a", None)
        };
        for (agent, section, primary) in [
            (
                row("claude-native-ui", "claude-native", Some(true), false),
                Harness,
                true,
            ),
            (
                row("pi-native-ui", "native-pi", None, false),
                Harness,
                false,
            ),
            (
                row("kilocode", "acp:kilocode", Some(true), false),
                Harness,
                false,
            ),
            (row("grok", "grok", Some(true), false), Harness, false),
            (row("polly", "claude-sdk", Some(true), false), Agent, false),
            (row("debby", "claude-sdk", None, false), Agent, false),
            (
                row("mock-model", "openai-agents", Some(false), false),
                Custom,
                false,
            ),
            (
                row("reviewer", "claude-native", Some(false), true),
                Custom,
                false,
            ),
            (row("bundle", "openai-agents", None, false), Custom, false),
        ] {
            assert_eq!(agent.picker_section(), section, "{}", agent.name);
            assert_eq!(agent.is_primary_harness(), primary, "{}", agent.name);
        }
        assert!(
            row("c", "claude-native", None, false).picker_rank()
                < row("x", "codex-native", None, false).picker_rank()
        );
    }

    #[test]
    fn user_agents_merge_newest_per_root_name_after_the_catalog() {
        let user = |id: &str, name: &str, changed: u64| CreationAgent {
            name: name.into(),
            changed_at: Some(changed),
            ..agent(id, Some("openai-agents"))
        };
        let catalog = vec![CreationAgent {
            name: "polly".into(),
            builtin: Some(true),
            ..agent("ag_polly", Some("claude-sdk"))
        }];
        let merged = merge_user_agents(
            &catalog,
            vec![
                user("ag_old", "mock", 1),
                user("ag_new", "mock (fork ag_1)", 5),
                user("ag_polly_copy", "polly", 9),
                user("ag_polly", "polly-renamed", 9),
            ],
        );
        let ids: Vec<_> = merged.iter().map(|agent| agent.id.as_str()).collect();
        assert_eq!(ids, ["ag_new"]);
        assert!(merged[0].mine);
    }

    #[test]
    fn capabilities_default_to_unsupported() {
        let value = serde_json::json!({"single_user": true});
        assert_eq!(
            CreationCapabilities::from_value(&value),
            Ok(CreationCapabilities::default())
        );
        let bad = serde_json::json!({"sandbox_providers": [1]});
        assert!(CreationCapabilities::from_value(&bad).is_err());
    }
}
