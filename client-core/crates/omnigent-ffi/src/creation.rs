//! Session creation.
//!
//! The host and agent catalog, the workspace picker, the host's model preview, and
//! `POST /v1/sessions` with an optional first message. The rules are `omnigent_core::creation`'s;
//! the REST calls are the core client's.

use omnigent_core::create as core_create;
use omnigent_core::creation as core;

use crate::approval::ApprovalModeMenu;
use crate::client::{ClientCore, MessageSent};
use crate::configuration::{HarnessStatus, ModelChoice, harness_map, harness_statuses};
use crate::engine::Msg;
use crate::errors::CoreError;
use crate::sessions::SessionSummary;

/// One `GET /v1/hosts` row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
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
    pub configured_harnesses: Option<Vec<HarnessStatus>>,
    /// Online and not a managed sandbox.
    #[uniffi(default)]
    pub is_available: bool,
}

/// One `GET /v1/agents` row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct CreationAgent {
    /// Durable agent id.
    pub id: String,
    /// Display name.
    pub name: String,
    /// Harness as sent (aliases included).
    pub harness: Option<String>,
    /// Description.
    pub description: Option<String>,
    /// The canonical harness id.
    #[uniffi(default)]
    pub harness_id: String,
    /// The harness display label.
    #[uniffi(default)]
    pub harness_label: String,
    /// This app can create a session for the agent's harness.
    #[uniffi(default)]
    pub supports_creation: bool,
    /// The host can preview models for the agent's harness.
    #[uniffi(default)]
    pub supports_model_preview: bool,
    /// The server's `builtin` flag; `None` from servers that predate it.
    #[uniffi(default)]
    pub builtin: Option<bool>,
    /// One of the caller's own agents.
    #[uniffi(default)]
    pub mine: bool,
    /// Last change, in seconds since 1970.
    #[uniffi(default)]
    pub changed_at: Option<u64>,
    /// Where the new-session picker lists it.
    pub picker_section: AgentPickerSection,
    /// A harness listed inline rather than under "Other…".
    #[uniffi(default)]
    pub is_primary_harness: bool,
    /// The order within its section, lowest first.
    #[uniffi(default)]
    pub picker_rank: u32,
}

/// Where the new-session picker lists an agent, as the web groups it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentPickerSection {
    /// A native coding CLI or an ACP harness ("Harnesses").
    Harness,
    /// A built-in composed agent such as Polly ("Agents").
    Agent,
    /// A user-registered or uploaded agent ("Agents", under "Other…").
    #[default]
    Custom,
}

impl From<core::AgentPickerSection> for AgentPickerSection {
    fn from(section: core::AgentPickerSection) -> Self {
        match section {
            core::AgentPickerSection::Harness => Self::Harness,
            core::AgentPickerSection::Agent => Self::Agent,
            core::AgentPickerSection::Custom => Self::Custom,
        }
    }
}

/// The hosts and agents a session can be created with.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct CreationCatalog {
    /// Hosts, de-duplicated by id.
    pub hosts: Vec<CreationHost>,
    /// Agents, de-duplicated by id: the server's catalog, then the caller's own.
    pub agents: Vec<CreationAgent>,
    /// `/v1/info.agent_install`: the caller's own agents are listed.
    #[uniffi(default)]
    pub agent_install: bool,
    /// `/v1/info.managed_sandboxes_enabled`: sessions can start on a new sandbox.
    #[uniffi(default)]
    pub managed_sandboxes: bool,
    /// `/v1/info.sandbox_providers`, the default first.
    #[uniffi(default)]
    pub sandbox_providers: Vec<String>,
    /// `/v1/info.features.codex_plan_at_launch`: a Codex session can start in Plan mode.
    #[uniffi(default)]
    pub codex_plan_at_launch: bool,
    /// `/v1/info.sandbox_provider`: the default sandbox provider.
    #[uniffi(default)]
    pub default_sandbox_provider: Option<String>,
    /// Providers that clone several repositories.
    #[uniffi(default)]
    pub multi_repo_providers: Vec<String>,
    /// `features.sandbox_profiles`.
    #[uniffi(default)]
    pub sandbox_profiles: bool,
    /// `request_managed_sandbox_host_id`.
    #[uniffi(default)]
    pub mints_sandbox_host_id: bool,
    /// GitHub is an enabled connection: the repository picker lists the caller's repos.
    #[uniffi(default)]
    pub github_connection: bool,
    /// `session_fork_workspaces`.
    #[uniffi(default)]
    pub fork_workspaces: bool,
    /// Settings lists and edits custom agents (`custom_agents_settings_ui` and
    /// `agent_install`).
    #[uniffi(default)]
    pub custom_agents_settings: bool,
    /// `agent_detail`: an agent's configuration can be read.
    #[uniffi(default)]
    pub agent_detail: bool,
    /// `smart_routing_enabled` with a router for native Claude Code and Codex panes.
    #[uniffi(default)]
    pub smart_routing: bool,
}

/// A new sandbox for a session.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SandboxTarget {
    /// The provider; `None` takes the server's default.
    pub provider: Option<String>,
    /// The profile to launch with.
    pub profile: Option<crate::sandbox::SandboxProfile>,
    /// `<url>[#<branch>]` repositories; empty for an empty sandbox.
    pub workspaces: Vec<String>,
}

/// A directory offered as a session workspace.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct CreationWorkspace {
    /// Absolute path.
    pub path: String,
    /// Display name.
    pub name: String,
}

/// What the user chose in the new-session form.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, uniffi::Record)]
pub struct CreationSelection {
    /// Host id.
    pub host_id: String,
    /// Agent id.
    pub agent_id: String,
    /// Workspace path, as typed.
    pub workspace: String,
    /// The model's wire value (`ModelChoice::value`), or `None` for the harness default.
    pub model: Option<String>,
    /// The reasoning effort, or `None` for the model default.
    #[uniffi(default)]
    pub reasoning_effort: Option<String>,
    /// The approval mode to launch in (from `launch_approval_mode_menu`), or `None` for the
    /// harness default.
    #[uniffi(default)]
    pub approval_mode: Option<String>,
    /// A git worktree to create or start in; `None` starts in the workspace itself.
    #[uniffi(default)]
    pub git: Option<CreationGit>,
    /// Start a Codex session in Plan mode (see `creation_starts_in_plan_mode`).
    #[uniffi(default)]
    pub plan_mode: bool,
    /// The first-class project the session is filed in from its creation.
    #[uniffi(default)]
    pub project_id: Option<String>,
    /// Smart Routing picks the model and effort each turn (see
    /// `creation_offers_smart_routing`); the model and effort are not sent with it.
    #[uniffi(default)]
    pub smart_routing: bool,
}

/// The `git` block of a new external-host session.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, uniffi::Record)]
pub struct CreationGit {
    /// The branch: a new worktree's, or an existing worktree's.
    pub branch_name: String,
    /// What a new worktree branches from; `None` for the repository default.
    #[uniffi(default)]
    pub base_branch: Option<String>,
    /// Start in an existing worktree instead of creating one.
    #[uniffi(default)]
    pub existing_worktree: bool,
}

/// One git worktree of a repository on a host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HostWorktree {
    /// Absolute path.
    pub path: String,
    /// Checked-out branch; `None` when detached.
    pub branch: Option<String>,
    /// The repository's main worktree.
    pub is_main: bool,
}

/// A directory on a host and the directories in it, for the folder browser.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HostDirectoryListing {
    /// The listed directory; `None` when the home was listed and held nothing.
    pub path: Option<String>,
    /// Its parent; `None` at `/`.
    pub parent: Option<String>,
    /// Directories in it.
    pub directories: Vec<CreationWorkspace>,
}

/// A file or folder on a host, for the new-session `@` menu.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HostEntry {
    /// Absolute path.
    pub path: String,
    /// Display name.
    pub name: String,
    /// A folder rather than a file.
    pub is_directory: bool,
}

/// What a successful `POST /v1/sessions` returned.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CreationReceipt {
    /// The created session.
    pub session_id: String,
    /// Its summary, when the body is a snapshot this client can read.
    pub summary: Option<SessionSummary>,
}

/// How the first message of a newly created session went.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FirstMessage {
    /// Sent.
    Sent {
        /// The acknowledgement and the composer text.
        sent: MessageSent,
    },
    /// Not sent, or its outcome is unknown (`delivery_uncertain`). The session exists: retry the
    /// send to it, never the creation.
    Failed {
        /// Why.
        error: CoreError,
    },
}

/// A created session and its first message.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CreatedSession {
    /// The creation acknowledgement.
    pub receipt: CreationReceipt,
    /// The first message's outcome.
    pub first_message: FirstMessage,
}

impl From<core::CreationHost> for CreationHost {
    fn from(host: core::CreationHost) -> Self {
        Self {
            is_available: host.is_available(),
            host_id: host.host_id,
            name: host.name,
            status: host.status,
            sandbox_provider: host.sandbox_provider,
            configured_harnesses: host.configured_harnesses.map(harness_statuses),
        }
    }
}

impl From<CreationHost> for core::CreationHost {
    fn from(host: CreationHost) -> Self {
        Self {
            host_id: host.host_id,
            name: host.name,
            status: host.status,
            sandbox_provider: host.sandbox_provider,
            configured_harnesses: host.configured_harnesses.map(harness_map),
        }
    }
}

impl From<core::CreationAgent> for CreationAgent {
    fn from(agent: core::CreationAgent) -> Self {
        Self {
            harness_id: agent.harness_id(),
            harness_label: agent.harness_label(),
            supports_creation: agent.supports_creation(),
            supports_model_preview: agent.supports_model_preview(),
            picker_section: agent.picker_section().into(),
            is_primary_harness: agent.is_primary_harness(),
            picker_rank: u32::try_from(agent.picker_rank()).unwrap_or(u32::MAX),
            id: agent.id,
            name: agent.name,
            harness: agent.harness,
            description: agent.description,
            builtin: agent.builtin,
            mine: agent.mine,
            changed_at: agent.changed_at,
        }
    }
}

impl From<CreationAgent> for core::CreationAgent {
    fn from(agent: CreationAgent) -> Self {
        Self {
            id: agent.id,
            name: agent.name,
            harness: agent.harness,
            description: agent.description,
            builtin: agent.builtin,
            mine: agent.mine,
            changed_at: agent.changed_at,
        }
    }
}

impl From<core::CreationCatalog> for CreationCatalog {
    fn from(catalog: core::CreationCatalog) -> Self {
        Self {
            hosts: catalog.hosts.into_iter().map(Into::into).collect(),
            agents: catalog.agents.into_iter().map(Into::into).collect(),
            agent_install: catalog.capabilities.agent_install,
            managed_sandboxes: catalog.capabilities.managed_sandboxes,
            codex_plan_at_launch: catalog.capabilities.codex_plan_at_launch,
            custom_agents_settings: catalog.capabilities.custom_agents_settings_enabled(),
            sandbox_providers: catalog.capabilities.sandbox_providers,
            default_sandbox_provider: catalog.capabilities.default_sandbox_provider,
            multi_repo_providers: catalog.capabilities.multi_repo_providers,
            sandbox_profiles: catalog.capabilities.sandbox_profiles,
            mints_sandbox_host_id: catalog.capabilities.mints_sandbox_host_id,
            github_connection: catalog.capabilities.github_connection,
            fork_workspaces: catalog.capabilities.fork_workspaces,
            agent_detail: catalog.capabilities.agent_detail,
            smart_routing: catalog.capabilities.smart_routing,
        }
    }
}

impl From<CreationCatalog> for core::CreationCatalog {
    fn from(catalog: CreationCatalog) -> Self {
        Self {
            hosts: catalog.hosts.into_iter().map(Into::into).collect(),
            agents: catalog.agents.into_iter().map(Into::into).collect(),
            capabilities: core::CreationCapabilities {
                agent_install: catalog.agent_install,
                managed_sandboxes: catalog.managed_sandboxes,
                sandbox_providers: catalog.sandbox_providers,
                codex_plan_at_launch: catalog.codex_plan_at_launch,
                default_sandbox_provider: catalog.default_sandbox_provider,
                multi_repo_providers: catalog.multi_repo_providers,
                sandbox_profiles: catalog.sandbox_profiles,
                mints_sandbox_host_id: catalog.mints_sandbox_host_id,
                github_connection: catalog.github_connection,
                fork_workspaces: catalog.fork_workspaces,
                // Already combined with `agent_install` on the way out.
                custom_agents_settings: catalog.custom_agents_settings,
                agent_detail: catalog.agent_detail,
                smart_routing: catalog.smart_routing,
            },
        }
    }
}

impl From<CreationSelection> for core::CreationSelection {
    fn from(selection: CreationSelection) -> Self {
        Self {
            host_id: selection.host_id,
            agent_id: selection.agent_id,
            workspace: selection.workspace,
            model: selection.model,
            reasoning_effort: selection.reasoning_effort,
            approval_mode: selection.approval_mode,
            git: selection.git.map(|git| core::CreationGit {
                branch_name: git.branch_name,
                base_branch: git.base_branch,
                existing_worktree: git.existing_worktree,
            }),
            plan_mode: selection.plan_mode,
            project_id: selection.project_id,
            smart_routing: selection.smart_routing,
        }
    }
}

impl From<core::CreationReceipt> for CreationReceipt {
    fn from(receipt: core::CreationReceipt) -> Self {
        Self {
            session_id: receipt.session_id,
            summary: receipt.summary.map(Into::into),
        }
    }
}

impl From<omnigent_core::events::MessageSent> for MessageSent {
    fn from(sent: omnigent_core::events::MessageSent) -> Self {
        Self {
            queued: sent.submission.queued,
            item_id: sent.submission.item_id,
            pending_id: sent.submission.pending_id,
            draft: sent.draft,
        }
    }
}

impl From<core_create::FirstMessage> for FirstMessage {
    fn from(first: core_create::FirstMessage) -> Self {
        match first {
            core_create::FirstMessage::Sent(sent) => Self::Sent { sent: sent.into() },
            core_create::FirstMessage::Failed(error) => Self::Failed {
                error: error.into(),
            },
        }
    }
}

impl From<core_create::CreatedSession> for CreatedSession {
    fn from(created: core_create::CreatedSession) -> Self {
        Self {
            receipt: created.receipt.into(),
            first_message: created.first_message.into(),
        }
    }
}

/// Why `agent_id` cannot be created on `host_id` in `catalog`, or `None` when it can.
#[must_use]
#[uniffi::export]
pub fn creation_unavailable_reason(
    catalog: CreationCatalog,
    agent_id: String,
    host_id: String,
) -> Option<String> {
    core::CreationCatalog::from(catalog).unavailable_reason(&agent_id, &host_id)
}

/// Why `selection` cannot be created with the host's advertised `models`, or `None` when it can:
/// readiness, an absolute workspace path, and an advertised, visible model.
#[must_use]
#[uniffi::export]
pub fn creation_validation_error(
    catalog: CreationCatalog,
    selection: CreationSelection,
    models: Vec<ModelChoice>,
) -> Option<String> {
    let models: Vec<omnigent_core::config::session::ModelChoice> =
        models.into_iter().map(Into::into).collect();
    core::CreationCatalog::from(catalog)
        .validate(&selection.into(), &models)
        .err()
        .map(|error| error.to_string())
}

/// The approval modes a new session of `agent` can launch in, its default selected; `None` when
/// its harness takes no launch mode.
#[must_use]
#[uniffi::export]
pub fn creation_approval_mode_menu(agent: CreationAgent) -> Option<ApprovalModeMenu> {
    crate::approval::launch_approval_mode_menu(core::CreationAgent::from(agent).wrapper())
}

/// Whether a session of `agent_id` can start in Plan mode through `plan_mode`: a native Codex
/// agent on a server that supports it. Claude Code uses its `plan` approval mode instead.
#[must_use]
#[uniffi::export]
pub fn creation_starts_in_plan_mode(catalog: CreationCatalog, agent_id: String) -> bool {
    core::CreationCatalog::from(catalog).starts_in_plan_mode(&agent_id)
}

/// Whether a new session of `agent_id` can turn Smart Routing on: the server routes native
/// panes and the agent runs Claude Code or Codex natively.
#[must_use]
#[uniffi::export]
pub fn creation_offers_smart_routing(catalog: CreationCatalog, agent_id: String) -> bool {
    core::CreationCatalog::from(catalog).offers_smart_routing(&agent_id)
}

/// Whether `name` is a branch name a new worktree can use.
#[must_use]
#[uniffi::export]
pub fn is_valid_branch_name(name: String) -> bool {
    core::is_branch_name(&name)
}

/// The longest session title, in characters.
#[must_use]
#[uniffi::export]
pub fn max_session_title_chars() -> u32 {
    u32::try_from(core::MAX_TITLE_CHARS).unwrap_or(u32::MAX)
}

#[uniffi::export]
impl ClientCore {
    /// The hosts and agents a session can be created with.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors, `MalformedResponse` and `InvalidPagination`.
    pub async fn creation_catalog(&self) -> Result<CreationCatalog, CoreError> {
        self.sessions()
            .creation_catalog()
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Directories on `host_id` to offer as workspaces. Files and relative paths are never
    /// offered; any other absolute path may be typed.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` before any request, the read errors and
    /// `InvalidPagination`.
    pub async fn creation_workspaces(
        &self,
        host_id: String,
    ) -> Result<Vec<CreationWorkspace>, CoreError> {
        self.sessions()
            .creation_workspaces(&host_id)
            .await
            .map(|workspaces| {
                workspaces
                    .into_iter()
                    .map(|workspace| CreationWorkspace {
                        path: workspace.path,
                        name: workspace.name,
                    })
                    .collect()
            })
            .map_err(CoreError::from)
    }

    /// The directories in `path` on `host_id` (its home when `None`), for the folder browser.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` before any request (also for a path that is
    /// not absolute), the read errors and `InvalidPagination`.
    pub async fn host_directory(
        &self,
        host_id: String,
        path: Option<String>,
    ) -> Result<HostDirectoryListing, CoreError> {
        self.sessions()
            .host_directory(&host_id, path.as_deref())
            .await
            .map(|listing| HostDirectoryListing {
                path: listing.path,
                parent: listing.parent,
                directories: listing
                    .directories
                    .into_iter()
                    .map(|workspace| CreationWorkspace {
                        path: workspace.path,
                        name: workspace.name,
                    })
                    .collect(),
            })
            .map_err(CoreError::from)
    }

    /// The files and folders in the absolute `path` on `host_id`, for the new-session `@` menu.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` before any request (also for a path that is
    /// not absolute), the read errors and `InvalidPagination`.
    pub async fn host_entries(
        &self,
        host_id: String,
        path: String,
    ) -> Result<Vec<HostEntry>, CoreError> {
        self.sessions()
            .host_entries(&host_id, &path)
            .await
            .map(|entries| {
                entries
                    .into_iter()
                    .map(|entry| HostEntry {
                        path: entry.path,
                        name: entry.name,
                        is_directory: entry.is_directory,
                    })
                    .collect()
            })
            .map_err(CoreError::from)
    }

    /// The git worktrees of the repository at `path` on `host_id`, main first; empty when it is
    /// not a git repository.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` before any request and the read errors.
    pub async fn host_worktrees(
        &self,
        host_id: String,
        path: String,
    ) -> Result<Vec<HostWorktree>, CoreError> {
        self.sessions()
            .host_worktrees(&host_id, &path)
            .await
            .map(|worktrees| {
                worktrees
                    .into_iter()
                    .map(|worktree| HostWorktree {
                        path: worktree.path,
                        branch: worktree.branch,
                        is_main: worktree.is_main,
                    })
                    .collect()
            })
            .map_err(CoreError::from)
    }

    /// The models `host_id` advertises for `agent_id`'s harness; empty for harnesses without a
    /// preview.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`] kind `Creation` when the agent cannot be created on the host, and
    /// the read errors.
    pub async fn creation_models(
        &self,
        agent_id: String,
        host_id: String,
    ) -> Result<Vec<ModelChoice>, CoreError> {
        self.sessions()
            .creation_models(&agent_id, &host_id)
            .await
            .map(|models| models.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// Creates a session for `selection` without a first message, re-validating readiness and
    /// the model against a fresh catalog first. Never retried: an unclear outcome is
    /// `delivery_uncertain`, and the session may exist.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`; kind `Creation` for an unavailable selection
    /// (nothing sent), a rejection, or an uncertain outcome (`delivery_uncertain`); `Unauthorized`
    /// (the connection ends); the catalog read errors.
    pub async fn create_session(
        &self,
        selection: CreationSelection,
        title: String,
    ) -> Result<CreationReceipt, CoreError> {
        self.sessions()
            .create_session(&selection.into(), &title)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Creates a session for `selection`'s agent and run configuration on a new sandbox the
    /// server provisions, as `target` describes (provider, profile, repositories). Returns once
    /// the session exists; its host binds when the sandbox registers. Never retried.
    ///
    /// # Errors
    ///
    /// As [`Self::create_session`].
    pub async fn create_sandbox_session(
        &self,
        selection: CreationSelection,
        target: SandboxTarget,
        title: String,
    ) -> Result<CreationReceipt, CoreError> {
        let target = core::SandboxTarget {
            provider: target.provider,
            profile: target.profile.map(|profile| (profile.id, profile.revision)),
            workspaces: target.workspaces,
            // Sent only to servers that ask clients to name a new sandbox's host.
            host_id: Some(self.random_host_id()?),
        };
        self.sessions()
            .create_sandbox_session(&selection.into(), &target, &title)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Creates a session whose first message, `text`, the caller sends next with
    /// `send_first_message` (after uploading attachments to it). Smart Routing picks a native
    /// pane's model from `text` at creation.
    ///
    /// # Errors
    ///
    /// As [`Self::create_session`].
    pub async fn create_session_for_message(
        &self,
        selection: CreationSelection,
        title: String,
        text: String,
    ) -> Result<CreationReceipt, CoreError> {
        self.sessions()
            .create_session_for_message(&selection.into(), &title, &text)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Creates a session, then sends `text` to it. Once the session exists this returns `Ok`: a
    /// failed first message is [`FirstMessage::Failed`], to be retried with `send_message` to the
    /// new session, never by creating again.
    ///
    /// # Errors
    ///
    /// As [`Self::create_session`].
    pub async fn create_session_and_send(
        &self,
        selection: CreationSelection,
        title: String,
        text: String,
    ) -> Result<CreatedSession, CoreError> {
        let created = self
            .sessions()
            .create_session_and_send(&selection.into(), &title, &text)
            .await
            .map_err(CoreError::from)?;
        if self.is_demo() && matches!(created.first_message, core_create::FirstMessage::Sent(_)) {
            self.post(Msg::DemoKick);
        }
        Ok(created.into())
    }

    /// Sends the first message of a session just created with `create_session`, with the
    /// attachments staged and uploaded to it, without waiting for its live stream. Never
    /// retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`] as `send_message`.
    pub async fn send_first_message(
        &self,
        session_id: String,
        text: String,
    ) -> Result<MessageSent, CoreError> {
        self.sessions()
            .send_first_message(&session_id, &text)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}
