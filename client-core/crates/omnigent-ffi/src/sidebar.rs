//! The sidebar's ordering and environment line: drag a pin into a slot, save the project
//! order, and name where each session runs.

use omnigent_core::creation as core_creation;
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

#[uniffi::export]
impl ClientCore {
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
