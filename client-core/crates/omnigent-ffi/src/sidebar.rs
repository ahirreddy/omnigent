//! The sidebar's ordering and environment line: drag a pin into a slot, save the project
//! order, and name where each session runs; and a project's settings and icon.

use omnigent_core::creation as core_creation;
use omnigent_core::project_settings::{
    self as core_settings, ProjectSettings as CoreSettings, ProjectSortMode as CoreSortMode,
};
use omnigent_core::session_environment::{self as environment, SessionEnvironment as CoreEnv};

use crate::client::ClientCore;
use crate::creation::CreationHost;
use crate::errors::CoreError;
use crate::sessions::ProjectSummary;

/// Where a session runs, as the sidebar's Environment detail names it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SessionEnvironment {
    /// No host: the server runs it itself ("Local machine").
    LocalMachine,
    /// The host on this device ("This Mac").
    ThisMachine,
    /// Another machine ("Remote").
    Remote,
    /// A managed sandbox.
    Sandbox {
        /// "Modal Sandbox", ...
        label: String,
    },
}

impl From<CoreEnv> for SessionEnvironment {
    fn from(value: CoreEnv) -> Self {
        match value {
            CoreEnv::LocalMachine => Self::LocalMachine,
            CoreEnv::ThisMachine => Self::ThisMachine,
            CoreEnv::Remote => Self::Remote,
            CoreEnv::Sandbox { label } => Self::Sandbox { label },
        }
    }
}

/// One host's environment.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HostEnvironment {
    /// The host id.
    pub host_id: String,
    /// Where a session on it runs.
    pub environment: SessionEnvironment,
}

/// The environment of a session on each of `hosts` of the server at `server_url`.
///
/// A session with no host runs on the local machine, and one on an unlisted host is remote. This
/// device's host is `this_machine_host_id` when known, else the only online machine of a local server.
#[must_use]
#[uniffi::export]
pub fn host_environments(
    hosts: Vec<CreationHost>,
    server_url: String,
    this_machine_host_id: Option<String>,
) -> Vec<HostEnvironment> {
    let hosts: Vec<core_creation::CreationHost> = hosts.into_iter().map(Into::into).collect();
    let this_machine = environment::this_machine_host_id(
        this_machine_host_id.as_deref(),
        environment::server_is_local(&server_url),
        &hosts,
    );
    hosts
        .iter()
        .map(|host| HostEnvironment {
            host_id: host.host_id.clone(),
            environment: environment::session_environment(
                Some(&host.host_id),
                &hosts,
                this_machine,
            )
            .into(),
        })
        .collect()
}

/// A project's new-session defaults; `None` is no default.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ProjectSettings {
    /// The host id, or [`project_sandbox_host_choice`].
    pub host_id: Option<String>,
    /// The working directory on that host.
    pub workspace: Option<String>,
    /// Start in a fresh worktree; `None` follows the user's global default.
    pub use_worktree: Option<bool>,
    /// The branch new worktrees fork from.
    pub base_branch: Option<String>,
    /// The agent id.
    pub agent_id: Option<String>,
    /// The model, for an agent that takes one.
    pub model: Option<String>,
    /// The reasoning effort, for an agent that takes one.
    pub effort: Option<String>,
}

impl From<CoreSettings> for ProjectSettings {
    fn from(settings: CoreSettings) -> Self {
        Self {
            host_id: settings.host_id,
            workspace: settings.workspace,
            use_worktree: settings.use_worktree,
            base_branch: settings.base_branch,
            agent_id: settings.agent_id,
            model: settings.model,
            effort: settings.effort,
        }
    }
}

impl From<ProjectSettings> for CoreSettings {
    fn from(settings: ProjectSettings) -> Self {
        Self {
            host_id: settings.host_id,
            workspace: settings.workspace,
            use_worktree: settings.use_worktree,
            base_branch: settings.base_branch,
            agent_id: settings.agent_id,
            model: settings.model,
            effort: settings.effort,
        }
    }
}

/// How the sidebar orders projects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ProjectSortMode {
    /// By name.
    Alphabetical,
    /// The caller's saved order.
    Manual,
}

/// The host choice that makes a project's sessions start in a managed sandbox.
#[must_use]
#[uniffi::export]
pub fn project_sandbox_host_choice() -> String {
    core_settings::SANDBOX_HOST_CHOICE.to_owned()
}

#[uniffi::export]
impl ClientCore {
    /// The stored new-session defaults of `project` (none for a label-only project).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn project_settings(
        &self,
        project: ProjectSummary,
    ) -> Result<ProjectSettings, CoreError> {
        self.sessions()
            .project_settings(&project.into())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Saves `settings` as `project`'s defaults, keeping other stored keys; the worktree choice
    /// is stored only when it differs from `always_use_worktree`. Returns the project with its
    /// id (a label-only one is promoted).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the promotion's, read and write errors.
    pub async fn save_project_settings(
        &self,
        project: ProjectSummary,
        settings: ProjectSettings,
        always_use_worktree: bool,
    ) -> Result<ProjectSummary, CoreError> {
        self.sessions()
            .save_project_settings(&project.into(), &settings.into(), always_use_worktree)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Sets or clears `project`'s emoji icon.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the promotion's, read and write errors.
    pub async fn set_project_icon(
        &self,
        project: ProjectSummary,
        icon: Option<String>,
    ) -> Result<ProjectSummary, CoreError> {
        self.sessions()
            .set_project_icon(&project.into(), icon.as_deref())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// How projects are sorted.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn project_sort_mode(&self) -> Result<ProjectSortMode, CoreError> {
        let mode = self
            .sessions()
            .project_sort_mode()
            .await
            .map_err(CoreError::from)?;
        Ok(match mode {
            CoreSortMode::Alphabetical => ProjectSortMode::Alphabetical,
            CoreSortMode::Manual => ProjectSortMode::Manual,
        })
    }

    /// Drops the saved project order, so projects sort by name again.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the write errors.
    pub async fn sort_projects_alphabetically(&self) -> Result<(), CoreError> {
        self.sessions()
            .sort_projects_alphabetically()
            .await
            .map_err(CoreError::from)
    }

    /// Moves `session_id` into `target_id`'s slot of the Pinned section, pinning it when it is
    /// not pinned yet (the web's drag onto a pinned row).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `ReadOnly` without view permission; the read and write errors.
    pub async fn move_pin(&self, session_id: String, target_id: String) -> Result<(), CoreError> {
        self.sessions()
            .move_pin(&session_id, &target_id, self.unix_ms())
            .await
            .map_err(CoreError::from)
    }

    /// Saves `projects` as the caller's project order, promoting label-only ones; returns them
    /// with their ids.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the promotion's and the write's errors.
    pub async fn save_project_order(
        &self,
        projects: Vec<ProjectSummary>,
    ) -> Result<Vec<ProjectSummary>, CoreError> {
        let projects: Vec<_> = projects.into_iter().map(Into::into).collect();
        self.sessions()
            .save_project_order(&projects)
            .await
            .map(|saved| saved.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// The server's hosts.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn hosts(&self) -> Result<Vec<CreationHost>, CoreError> {
        self.sessions()
            .hosts()
            .await
            .map(|hosts| hosts.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }
}
