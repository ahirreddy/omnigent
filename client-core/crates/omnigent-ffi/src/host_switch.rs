//! Moving a session's runner to another host, starting a host-less session on a host, and the
//! live sign-in link of a session's terminal. The REST calls are the core client's.

use omnigent_core::host_switch as core;

use crate::client::ClientCore;
use crate::creation::CreationGit;
use crate::errors::CoreError;
use crate::fork::RunnerLaunch;

/// The sign-in prompt the session's terminal shows now.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SessionSignInLink {
    /// A sign-in is waiting in the terminal.
    pub pending: bool,
    /// The page to open (http or https only), while one is pending.
    pub url: Option<String>,
    /// The one-time code the page asks for, when there is one.
    pub code: Option<String>,
}

#[uniffi::export]
impl ClientCore {
    /// Moves `session_id` (owned) to the online `host_id`, starting its runner in `workspace`:
    /// releases the current runner and its host-bound model override, then launches. A launch
    /// that fails after the release is `Ok(RunnerLaunch::Failed)`: the session runs nowhere
    /// until a launch on any host, the old one included, succeeds.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, `ReadOnly` (not the owner) and kind
    /// `Creation` (path not absolute, host unknown, a sandbox or offline) before any write; the
    /// release's write errors, after which nothing moved.
    pub async fn switch_session_host(
        &self,
        session_id: String,
        host_id: String,
        workspace: String,
    ) -> Result<RunnerLaunch, CoreError> {
        self.sessions()
            .switch_session_host(&session_id, &host_id, &workspace)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Starts `session_id` (owned, bound to no runner) on the online `host_id` in `workspace`,
    /// in a new worktree when `git` names a branch. Returns the runner id.
    ///
    /// # Errors
    ///
    /// As [`Self::switch_session_host`] before any write, also kind `Creation` for an invalid
    /// branch; then the launch's write errors.
    pub async fn resume_session_on_host(
        &self,
        session_id: String,
        host_id: String,
        workspace: String,
        git: Option<CreationGit>,
    ) -> Result<String, CoreError> {
        let git = git.map(|git| omnigent_core::creation::CreationGit {
            branch_name: git.branch_name,
            base_branch: git.base_branch.filter(|base| !base.trim().is_empty()),
            existing_worktree: git.existing_worktree,
        });
        self.sessions()
            .resume_session_on_host(&session_id, &host_id, &workspace, git.as_ref())
            .await
            .map_err(CoreError::from)
    }

    /// The sign-in the session's terminal waits on now, asked of its host at click time.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors (an offline runner
    /// included) and `MalformedResponse`.
    pub async fn session_sign_in_link(
        &self,
        session_id: String,
    ) -> Result<SessionSignInLink, CoreError> {
        self.sessions()
            .session_sign_in_link(&session_id)
            .await
            .map(|link: core::SignInLink| SessionSignInLink {
                pending: link.pending,
                url: link.url,
                code: link.code,
            })
            .map_err(CoreError::from)
    }
}
