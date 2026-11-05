//! Sandbox reads over REST: the profiles a provider offers (`GET /v1/sandbox-profiles`), the
//! caller's GitHub repositories and their branches (`GET /v1/connections/github/repos`), and a
//! sandbox fork's repositories on their current branches (the source's launch labels and
//! `GET /v1/sessions/{id}/resources/repository-branches`). All are reads; none is retried
//! beyond the read policy.

use omnigent_protocol::Field;
use serde_json::Value;

use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;
use crate::sandbox::{
    ForkSandboxDefaults, ForkSandboxRepos, GithubRepoList, SANDBOX_PROFILE_LIMIT,
    SANDBOX_REPO_LABEL, SandboxProfile, SandboxProfilePage, fork_sandbox_repos, github_branches,
    repository_branches, split_sandbox_workspace,
};

fn malformed(path: &str) -> impl Fn(String) -> SessionError + '_ {
    move |detail| SessionError::MalformedResponse {
        detail: format!("{path}: {detail}"),
    }
}

/// A GitHub `owner/name`, checked before it becomes a path.
fn github_full_name(full_name: &str) -> Result<(&str, &str), SessionError> {
    let part = |text: &str| {
        !text.is_empty()
            && text != "."
            && text != ".."
            && text
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    };
    full_name
        .split_once('/')
        .filter(|(owner, name)| part(owner) && part(name))
        .ok_or_else(|| SessionError::InvalidIdentifier {
            value: full_name.to_owned(),
        })
}

impl<T: HttpTransport> ClientCore<T> {
    /// The profiles of `provider` matching `search` (all when blank), or only `profile_id`.
    ///
    /// # Errors
    ///
    /// The read errors and [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn sandbox_profiles(
        &self,
        provider: &str,
        search: &str,
        profile_id: Option<&str>,
    ) -> Result<SandboxProfilePage, SessionError> {
        let result = async {
            let path = "/v1/sandbox-profiles";
            let mut query = vec![
                ("limit", SANDBOX_PROFILE_LIMIT.to_string()),
                ("provider", provider.to_owned()),
            ];
            let search = search.trim();
            if !search.is_empty() {
                query.push(("search", search.chars().take(200).collect()));
            }
            if let Some(id) = profile_id {
                query.push(("profile_id", id.to_owned()));
            }
            let value = self.get_json(path, &query).await?;
            SandboxProfilePage::from_value(&value, provider).map_err(malformed(path))
        }
        .await;
        self.dispatch();
        result
    }

    /// The repositories the caller's GitHub connection sees, newest push first.
    ///
    /// # Errors
    ///
    /// The read errors and [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn github_repos(&self) -> Result<GithubRepoList, SessionError> {
        let result = async {
            let path = "/v1/connections/github/repos";
            let value = self.get_json(path, &[]).await?;
            GithubRepoList::from_value(&value).map_err(malformed(path))
        }
        .await;
        self.dispatch();
        result
    }

    /// The branch names of the GitHub repository `full_name` (`owner/name`).
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] for a name that is not `owner/name`, the read errors
    /// and [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn github_branches(&self, full_name: &str) -> Result<Vec<String>, SessionError> {
        let result = async {
            let (owner, name) = github_full_name(full_name)?;
            let path = format!("/v1/connections/github/repos/{owner}/{name}/branches");
            let value = self.get_json(&path, &[]).await?;
            github_branches(&value).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }

    /// The repositories and profile a fork of `source_id` onto a new sandbox starts from. The
    /// current branches are read only when the server can change them (one repository, or
    /// `session_fork_workspaces`); when that read fails the original branches stay and the
    /// failure is in [`ForkSandboxDefaults::branch_check_error`].
    ///
    /// # Errors
    ///
    /// The source's read errors and [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn fork_sandbox_defaults(
        &self,
        source_id: &str,
    ) -> Result<ForkSandboxDefaults, SessionError> {
        let result = async {
            validate_identifier(source_id)?;
            let (decoded, _) = self.fetch_snapshot(source_id).await?;
            let snapshot = &decoded.snapshot;
            let original: Vec<_> = match &snapshot.labels {
                Field::Present(labels) => labels
                    .get(SANDBOX_REPO_LABEL)
                    .map(|joined| {
                        joined
                            .split_whitespace()
                            .map(split_sandbox_workspace)
                            .collect()
                    })
                    .unwrap_or_default(),
                _ => Vec::new(),
            };
            let profile = match &snapshot.sandbox_profile {
                Field::Present(value) => decode_profile(value),
                _ => None,
            };
            let mut defaults = ForkSandboxDefaults {
                repos: ForkSandboxRepos {
                    repos: original.clone(),
                    notes: Vec::new(),
                },
                profile,
                branch_check_error: None,
            };
            let discoverable = !original.is_empty()
                && (original.len() == 1 || self.creation_capabilities().await?.fork_workspaces);
            if discoverable {
                let path = format!("/v1/sessions/{source_id}/resources/repository-branches");
                match self
                    .get_json(&path, &[])
                    .await
                    .and_then(|value| repository_branches(&value).map_err(malformed(&path)))
                {
                    Ok(live) => defaults.repos = fork_sandbox_repos(&original, &live),
                    Err(error) => defaults.branch_check_error = Some(error.to_string()),
                }
            }
            Ok(defaults)
        }
        .await;
        self.dispatch();
        result
    }
}

/// The session's `sandbox_profile` object; a shape this client cannot read is no profile.
fn decode_profile(value: &Value) -> Option<SandboxProfile> {
    let text = |key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
    Some(SandboxProfile {
        id: text("id")?,
        name: text("name").unwrap_or_default(),
        description: text("description").unwrap_or_default(),
        provider: text("provider")?,
        revision: text("revision")?,
    })
}

#[cfg(test)]
#[path = "sandbox_tests.rs"]
mod tests;
