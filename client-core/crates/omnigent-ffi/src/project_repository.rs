//! A new project from a repository (cloned onto a host, or saved for a sandbox) or from a folder
//! on a host. The rules are `omnigent_core::project_repository`.

use omnigent_core::project_repository::{
    self as core, FolderProject, ProjectTarget, RepositoryProject,
};

use crate::client::ClientCore;
use crate::errors::CoreError;
use crate::sessions::ProjectSummary;

/// Where a new project's sessions run.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ProjectRunTarget {
    /// One of the caller's hosts.
    Host {
        /// The host.
        host_id: String,
    },
    /// A new sandbox for each session.
    Sandbox {
        /// Its provider; `None` for the server's default.
        provider: Option<String>,
    },
}

/// A project to make from a repository.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RepositoryProjectRequest {
    /// The project's name.
    pub name: String,
    /// Its emoji icon.
    pub icon: Option<String>,
    /// Where its sessions run.
    pub target: ProjectRunTarget,
    /// The repository's HTTPS or SSH URL.
    pub url: String,
    /// The branch; blank for the default.
    pub branch: String,
    /// Where a host clones it; unused for a sandbox.
    pub destination: String,
}

/// A project whose sessions start in a folder on a host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct FolderProjectRequest {
    /// The project's name.
    pub name: String,
    /// Its emoji icon.
    pub icon: Option<String>,
    /// The host its sessions run on; `None` leaves the host to each session.
    pub host_id: Option<String>,
    /// The sessions' working directory on that host.
    pub workspace: Option<String>,
}

/// Why a repository and branch can't start a project, as the web words it; `None` when they can.
#[must_use]
#[uniffi::export]
pub fn project_repository_problem(url: String, branch: String) -> Option<String> {
    core::project_repository_problem(&url, &branch)
}

/// Where a host clones `url` unless the user says otherwise: `~/<repository name>`.
#[must_use]
#[uniffi::export]
pub fn default_clone_destination(url: String) -> Option<String> {
    core::default_clone_destination(&url)
}

#[uniffi::export]
impl ClientCore {
    /// Makes a project from a repository: clones it onto a host first (a sandbox prepares it
    /// per session), then creates the project with the repository in its config.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: kind `InvalidInput` with the words to show for a bad input, a
    /// failed clone or a refused create.
    pub async fn create_repository_project(
        &self,
        request: RepositoryProjectRequest,
    ) -> Result<ProjectSummary, CoreError> {
        let target = match request.target {
            ProjectRunTarget::Host { host_id } => ProjectTarget::Host(host_id),
            ProjectRunTarget::Sandbox { provider } => ProjectTarget::Sandbox(provider),
        };
        let project = RepositoryProject {
            name: request.name,
            icon: request.icon,
            target,
            url: request.url,
            branch: request.branch,
            destination: request.destination,
        };
        let created = self
            .sessions()
            .create_repository_project(&project)
            .await
            .map(Into::into)
            .map_err(CoreError::from);
        self.events_published().await;
        created
    }

    /// Creates the folder `~/<name>` on `host_id` for a new project and returns its path.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: kind `InvalidInput` with the words to show.
    pub async fn create_project_folder(
        &self,
        host_id: String,
        name: String,
    ) -> Result<String, CoreError> {
        self.sessions()
            .create_project_folder(&host_id, &name)
            .await
            .map_err(CoreError::from)
    }

    /// Makes a project whose sessions start on a host, in a working directory when given.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: kind `InvalidInput` with the words to show.
    pub async fn create_folder_project(
        &self,
        request: FolderProjectRequest,
    ) -> Result<ProjectSummary, CoreError> {
        let project = FolderProject {
            name: request.name,
            icon: request.icon,
            host_id: request.host_id,
            workspace: request.workspace,
        };
        let created = self
            .sessions()
            .create_folder_project(&project)
            .await
            .map(Into::into)
            .map_err(CoreError::from);
        self.events_published().await;
        created
    }
}
