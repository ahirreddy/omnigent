//! Moving a session's runner onto another host, or onto a host for a session bound to none.
//!
//! These mirror the web's `SwitchHostDialog` and `ResumeWithDirectoryDialog`; the module also
//! fetches the sign-in link an error card offers from the session's host.
//!
//! A switch is two writes, as the web's: `PATCH /v1/sessions/{id}` releases the runner binding
//! (and the host-bound model override), then `POST /v1/hosts/{host}/runners` binds the new one.
//! When the release lands and the launch does not, the session runs nowhere; that outcome is
//! [`RunnerLaunch::Failed`], not an error, so the caller can say so and offer every host again.

use serde_json::json;

use super::fork::RunnerLaunch;
use super::json::{as_object, opt_bool, opt_str};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError, lock};
use crate::creation::{CreationError, CreationGit, CreationHost, is_branch_name};
use crate::http::HttpTransport;

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
    /// Before any write: [`SessionError::InvalidIdentifier`], [`SessionError::ReadOnly`] (not
    /// the owner), and [`CreationError::Unavailable`] for a path that is not absolute or a host
    /// that is unknown, a sandbox or offline. The release's write errors (nothing moved). A
    /// failed launch after the release is [`RunnerLaunch::Failed`] in `Ok`.
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
        released?;
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

    /// Starts `session_id`, bound to no runner, on `host_id` in `workspace`, in a new worktree
    /// when `git` names a branch. Owner only. Returns the runner id.
    ///
    /// # Errors
    ///
    /// As [`Self::switch_session_host`] before any write, also
    /// [`CreationError::Unavailable`] for an invalid branch; then the launch's write errors.
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

    /// The owner check and the target's checks a launch needs, against a fresh host list.
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
        if !self.editable(session_id).await?.can_archive() {
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
