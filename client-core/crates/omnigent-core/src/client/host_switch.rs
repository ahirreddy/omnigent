//! Moving a session's runner onto another host, or onto a host for a session bound to none.
//!
//! These mirror the web's `SwitchHostDialog` and `ResumeWithDirectoryDialog`; the module also
//! fetches the sign-in link an error card offers from the session's host.
//!
//! A switch is two writes, as the web's: `PATCH /v1/sessions/{id}` releases the runner binding
//! (and the host-bound model override), then `POST /v1/hosts/{host}/runners` binds the new one.
//! When the release lands and the launch does not, the session runs nowhere; that outcome is
//! [`RunnerLaunch::Failed`], not an error, so the caller can say so and offer every host again.
//!
//! A move into a new managed sandbox releases the runner the same way, then asks the server to
//! start the sandbox (`POST /v1/sessions/{id}/managed-host`), as the web's sandbox rows do.

use serde_json::json;

use super::fork::RunnerLaunch;
use super::json::{as_object, opt_bool, opt_str};
use super::requests::{missing_session, refused_write, validate_identifier};
use super::{ClientCore, SessionError, lock};
use crate::creation::{CreationError, CreationGit, CreationHost, is_branch_name};
use crate::http::HttpTransport;
use crate::sandbox::{compose_sandbox_workspace, sandbox_move_problem};

/// A move into a new sandbox after the old host let go of the session.
#[derive(Debug)]
pub enum SandboxMove {
    /// The server is starting the sandbox; the session reports its progress.
    Started,
    /// The sandbox request failed or its answer was lost, so the session may run nowhere.
    Unconfirmed(SessionError),
}

/// Where a session moves: a sandbox provider and the repository it clones.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SandboxMoveTarget {
    /// The provider; `None` for the server's default.
    pub provider: Option<String>,
    /// The repository URL; blank starts an empty sandbox.
    pub repository: String,
    /// Its branch; blank for the default branch.
    pub branch: String,
    /// The new sandbox's host id, kept only where the server takes one
    /// (`request_managed_sandbox_host_id`).
    pub host_id: Option<String>,
}

/// The sign-in prompt the session's terminal shows now.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SignInLink {
    /// A sign-in is waiting in the terminal.
    pub pending: bool,
    /// The page to open, while one is pending.
    pub url: Option<String>,
    /// The one-time code the page asks for, when there is one.
    pub code: Option<String>,
}

impl<T: HttpTransport> ClientCore<T> {
    /// Moves `session_id` to `host_id`, starting its runner in `workspace` there: releases the
    /// current runner (clearing the model override, which belongs to the old host's catalog)
    /// and launches on the new host. Owner only.
    ///
    /// # Errors
    ///
    /// Before any write: [`SessionError::InvalidIdentifier`], [`SessionError::ReadOnly`] (the
    /// cached row is not the owner's), and [`CreationError::Unavailable`] for a path that is not
    /// absolute or a host that is unknown, a sandbox or offline. The release's write errors
    /// (nothing moved), its `403` as [`SessionError::ReadOnly`] and its `404` as
    /// [`SessionError::SessionNotFound`]. A failed launch after the release is
    /// [`RunnerLaunch::Failed`] in `Ok`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn switch_session_host(
        &self,
        session_id: &str,
        host_id: &str,
        workspace: &str,
    ) -> Result<RunnerLaunch, SessionError> {
        let result = self.switch_host(session_id, host_id, workspace).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn switch_host(
        &self,
        session_id: &str,
        host_id: &str,
        workspace: &str,
    ) -> Result<RunnerLaunch, SessionError> {
        self.launch_preflight(session_id, host_id, workspace, None)
            .await?;
        let path = format!("/v1/sessions/{session_id}");
        let release = json!({"runner_id": "", "model_override": "default", "silent": true});
        let released = self.write_json("PATCH", &path, &release).await;
        lock(&self.state).request_rehydration(session_id);
        released.map_err(refused_write(session_id))?;
        Ok(
            match self
                .launch_session_runner(host_id, session_id, workspace, None)
                .await
            {
                Ok(runner_id) => RunnerLaunch::Launched { runner_id },
                Err(error) => RunnerLaunch::Failed(error),
            },
        )
    }

    /// Moves `session_id` into a new managed sandbox: releases its runner, as a switch does, then
    /// asks the server to start the sandbox with the repository cloned as the working directory.
    /// Owner only; files don't move.
    ///
    /// # Errors
    ///
    /// Before any write: [`SessionError::InvalidIdentifier`], [`SessionError::ReadOnly`], the
    /// `/v1/info` read errors, and [`CreationError::Unavailable`] for a repository or branch the
    /// server would refuse or a provider that doesn't take moved sessions. The release's errors
    /// as [`Self::switch_session_host`]'s. A failed sandbox request after the release is
    /// [`SandboxMove::Unconfirmed`] in `Ok`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn move_session_to_sandbox(
        &self,
        session_id: &str,
        target: &SandboxMoveTarget,
    ) -> Result<SandboxMove, SessionError> {
        let result = self.move_to_sandbox(session_id, target).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn move_to_sandbox(
        &self,
        session_id: &str,
        target: &SandboxMoveTarget,
    ) -> Result<SandboxMove, SessionError> {
        validate_identifier(session_id)?;
        if let Some(problem) = sandbox_move_problem(&target.repository, &target.branch) {
            return Err(unavailable(&problem.message));
        }
        if self
            .cached_summary(session_id)
            .is_some_and(|summary| !summary.can_archive())
        {
            return Err(SessionError::ReadOnly);
        }
        let capabilities = self.creation_capabilities().await?;
        let options = capabilities.sandbox_move_options();
        let provider = target
            .provider
            .clone()
            .or_else(|| capabilities.default_sandbox_provider.clone());
        if !provider.as_ref().is_some_and(|name| options.contains(name)) {
            return Err(unavailable(
                "This server can't move a session into that sandbox.",
            ));
        }
        let mut body = serde_json::Map::new();
        if let Some(provider) = &target.provider {
            body.insert("sandbox_provider".into(), json!(provider));
        }
        if let Some(workspace) = compose_sandbox_workspace(&target.repository, &target.branch) {
            body.insert("workspace".into(), json!(workspace));
        }
        if let Some(host_id) = target
            .host_id
            .as_ref()
            .filter(|_| capabilities.mints_sandbox_host_id)
        {
            body.insert("host_id".into(), json!(host_id));
        }
        let path = format!("/v1/sessions/{session_id}");
        let release = json!({"runner_id": "", "model_override": "default", "silent": true});
        let released = self.write_json("PATCH", &path, &release).await;
        lock(&self.state).request_rehydration(session_id);
        released.map_err(refused_write(session_id))?;
        let started = self
            .write_json("POST", &format!("{path}/managed-host"), &body.into())
            .await;
        // The snapshot read again carries the sandbox's launch status.
        lock(&self.state).request_rehydration(session_id);
        Ok(match started {
            Ok(_) => SandboxMove::Started,
            Err(error) => SandboxMove::Unconfirmed(error),
        })
    }

    /// The sandbox providers Switch Host offers a move into, as the web's: those that take a
    /// moved session, when the server moves sessions into sandboxes at all.
    ///
    /// # Errors
    ///
    /// The `/v1/info` read errors and [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn sandbox_move_options(&self) -> Result<Vec<String>, SessionError> {
        let result = self
            .creation_capabilities()
            .await
            .map(|capabilities| capabilities.sandbox_move_options());
        self.dispatch();
        result
    }

    /// Starts `session_id`, bound to no runner, on `host_id` in `workspace`, in a new worktree
    /// when `git` names a branch. Owner only. Returns the runner id.
    ///
    /// # Errors
    ///
    /// As [`Self::switch_session_host`] before any write, also
    /// [`CreationError::Unavailable`] for an invalid branch; then the launch's write errors,
    /// its `404` (the session is gone, or is not the caller's) as
    /// [`SessionError::SessionNotFound`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn resume_session_on_host(
        &self,
        session_id: &str,
        host_id: &str,
        workspace: &str,
        git: Option<&CreationGit>,
    ) -> Result<String, SessionError> {
        let result = async {
            self.launch_preflight(session_id, host_id, workspace, git)
                .await?;
            self.launch_session_runner(host_id, session_id, workspace, git)
                .await
                .map_err(missing_session(session_id))
        }
        .await;
        self.dispatch();
        result
    }

    /// Asks the session's host for the sign-in its terminal waits on now. A link saved in an
    /// error card belongs to the launcher process that printed it, so the card asks at click
    /// time.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; the read errors (the runner
    /// being offline included) and [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn session_sign_in_link(&self, session_id: &str) -> Result<SignInLink, SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}/sign-in-link");
        let value = self.get_json(&path, &[]).await?;
        let malformed = |detail: String| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        };
        let object = as_object(&value, "sign-in link").map_err(malformed)?;
        let text = |key: &str| -> Result<Option<String>, SessionError> {
            Ok(opt_str(object, key)
                .map_err(malformed)?
                .filter(|value| !value.trim().is_empty()))
        };
        let url = text("url")?.filter(|url| is_web_page(url));
        Ok(SignInLink {
            pending: opt_bool(object, "pending").map_err(malformed)? == Some(true) && url.is_some(),
            url,
            code: text("code")?,
        })
    }

    /// The owner check a launch needs, against the session's cached row when there is one, and
    /// the target's checks, against a fresh host list.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn launch_preflight(
        &self,
        session_id: &str,
        host_id: &str,
        workspace: &str,
        git: Option<&CreationGit>,
    ) -> Result<(), SessionError> {
        validate_identifier(session_id)?;
        validate_identifier(host_id)?;
        let path = workspace.trim();
        if !path.starts_with('/') || path.contains('\0') {
            return Err(unavailable("Enter an absolute directory beginning with /."));
        }
        if git.is_some_and(|git| !is_branch_name(git.branch_name.trim())) {
            return Err(unavailable("Use a valid git branch name for the worktree."));
        }
        let cached = self.cached_summary(session_id);
        if cached.is_some_and(|summary| !summary.can_archive()) {
            return Err(SessionError::ReadOnly);
        }
        let hosts = self
            .host_rows()
            .await?
            .iter()
            .map(CreationHost::from_value)
            .collect::<Result<Vec<_>, String>>()
            .map_err(|detail| SessionError::MalformedResponse { detail })?;
        match hosts.iter().find(|host| host.host_id == host_id) {
            None => Err(unavailable("That host is no longer registered.")),
            Some(host) if host.sandbox_provider.is_some() => Err(unavailable(
                "Moving a session onto a managed sandbox is not available here.",
            )),
            Some(host) if host.status != "online" => Err(unavailable(
                "That host is offline. Connect it with `omnigent host` and try again.",
            )),
            Some(_) => Ok(()),
        }
    }
}

fn unavailable(reason: &str) -> SessionError {
    CreationError::Unavailable(reason.to_owned()).into()
}

/// Only http(s) pages open from a card; anything else the host reports is dropped.
fn is_web_page(url: &str) -> bool {
    let lower = url.trim().to_ascii_lowercase();
    lower.starts_with("https://") || lower.starts_with("http://")
}

#[cfg(test)]
#[path = "host_switch_tests.rs"]
mod tests;
