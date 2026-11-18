//! A new project from a repository, as the web's `NewProjectButton` makes one under the
//! `project_repository_creation` feature: cloned onto a host first
//! (`POST /v1/hosts/{id}/repositories/clone`), or saved for a sandbox to prepare, then created
//! with the repository in its config (`POST /v1/projects`).

use serde_json::{Map, Value, json};

use super::json::{as_object, req_str};
use super::projects::{ProjectSummary, project_from};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;
use crate::sandbox::{
    derive_repo_name, fits_sandbox_workspace, is_valid_sandbox_branch, is_valid_sandbox_repo_url,
};

/// The host id a project names when its sessions start in a new sandbox.
const SANDBOX_HOST: &str = "__sandbox__";

/// Where a new project's sessions run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProjectTarget {
    /// One of the caller's hosts, by id.
    Host(String),
    /// A new sandbox of this provider (`None` for the server's default) for each session.
    Sandbox(Option<String>),
}

/// What a project from a repository is made of.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepositoryProject {
    /// The project's name.
    pub name: String,
    /// Its emoji icon.
    pub icon: Option<String>,
    /// Where it runs.
    pub target: ProjectTarget,
    /// The repository's HTTPS or SSH URL.
    pub url: String,
    /// The branch; blank for the default.
    pub branch: String,
    /// Where a host clones it, `~/`-relative or absolute; unused for a sandbox.
    pub destination: String,
}

/// Why a repository and branch can't be used, as the web words it (`sandboxRepoProblem`), or
/// `None` when they can.
#[must_use]
pub fn project_repository_problem(url: &str, branch: &str) -> Option<String> {
    if url.trim().is_empty() {
        return (!branch.trim().is_empty())
            .then(|| "Add the repository this branch belongs to.".to_owned());
    }
    if !is_valid_sandbox_repo_url(url) {
        return Some("Enter a repository URL like https://github.com/org/repo.".to_owned());
    }
    if !fits_sandbox_workspace(url, branch) {
        return Some("Repository URL and branch must be at most 256 characters together.".into());
    }
    if !is_valid_sandbox_branch(branch) {
        return Some(
            "Enter a valid branch name or leave it blank for the default branch.".to_owned(),
        );
    }
    None
}

/// Where a host clones `url` unless the user says otherwise: `~/<repository name>`.
#[must_use]
pub fn default_clone_destination(url: &str) -> Option<String> {
    derive_repo_name(url).map(|name| format!("~/{name}"))
}

/// What a failed clone tells the user, from the server's reason (`friendlyCloneError`).
#[must_use]
pub fn clone_failure_message(reason: &str) -> &'static str {
    let reason = reason.to_lowercase();
    if reason.contains("update this host") {
        "This host is too old to clone repositories. Update omnigent on it and try again."
    } else if reason.contains("already exists") {
        "That destination already exists. It may be a checkout from an earlier attempt: create \
         a folder project from it, or choose a different folder name."
    } else if reason.contains("lost contact") {
        "The host stopped responding during the clone. The clone may have finished, so check \
         the destination before retrying."
    } else if reason.contains("did not finish") {
        "The host didn\u{2019}t finish the clone in time. It may still finish, so check the \
         destination before retrying."
    } else if reason.contains("took too long") {
        "The clone took too long and was stopped. Delete the partial folder, then try again."
    } else if reason.contains("doesn't exist or isn't writable") {
        "The parent folder doesn\u{2019}t exist or can\u{2019}t be written to. Choose another \
         location."
    } else if reason.contains("could not clone") {
        "Git couldn\u{2019}t clone the repository. Check the URL, the branch, and the host\
         \u{2019}s Git access."
    } else if reason.contains("host not found")
        || reason.contains("host is offline")
        || reason.contains("disconnected")
    {
        "The host is offline. Reconnect it and try again."
    } else {
        "The repository couldn\u{2019}t be cloned. Check the details and try again."
    }
}

/// What a refused project create tells the user (`friendlyProjectError`).
fn project_failure_message(error: &SessionError) -> &'static str {
    match error {
        SessionError::Rejected { status: 409, .. } => {
            "A project with this name already exists. Use a different name."
        }
        SessionError::Rejected { status: 422, .. } | SessionError::InvalidTitle => {
            "The project name is too long. Use a shorter name."
        }
        SessionError::Unauthorized { .. } => "Your session expired. Sign in and try again.",
        SessionError::Transport(_) => {
            "The project couldn\u{2019}t be created. Check your connection and try again."
        }
        _ => "The project couldn\u{2019}t be created. Try again.",
    }
}

fn rejected(message: impl Into<String>) -> SessionError {
    SessionError::InvalidInput {
        reason: message.into(),
    }
}

/// The server's reason for a refusal, or the error's own words.
fn reason_of(error: &SessionError) -> String {
    match error {
        SessionError::Rejected { message, .. } => message.clone(),
        other => other.to_string(),
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// Clones `url` (at `branch`, else its default) onto `host_id` at `path`; returns the
    /// checkout's absolute path. The server waits for the clone, which can take minutes.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; the write errors; `DeliveryUncertain` for an
    /// unreadable acknowledgement.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn clone_host_repository(
        &self,
        host_id: &str,
        url: &str,
        branch: Option<&str>,
        path: &str,
    ) -> Result<String, SessionError> {
        let result = self.clone_repository(host_id, url, branch, path).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn clone_repository(
        &self,
        host_id: &str,
        url: &str,
        branch: Option<&str>,
        path: &str,
    ) -> Result<String, SessionError> {
        validate_identifier(host_id)?;
        let route = format!("/v1/hosts/{host_id}/repositories/clone");
        let branch = branch.map(str::trim).filter(|branch| !branch.is_empty());
        let body = json!({"url": url.trim(), "branch": branch, "path": path.trim()});
        let answer = self.write_json("POST", &route, &body).await?;
        as_object(&answer, &route)
            .and_then(|object| req_str(object, "path"))
            .map_err(|detail| SessionError::DeliveryUncertain {
                detail: format!("unreadable {route} acknowledgement: {detail}"),
            })
    }

    /// Makes a project from a repository as the web does: checks the inputs, clones onto the
    /// host (a sandbox prepares it per session instead), then creates the project with the
    /// host, the checkout and the repository in its config.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidInput`] with the web's words for a bad name, repository or
    /// destination, a failed clone, or a refused create (which names a checkout that already
    /// finished).
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_repository_project(
        &self,
        project: &RepositoryProject,
    ) -> Result<ProjectSummary, SessionError> {
        let result = self.create_repository_project_rows(project).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn create_repository_project_rows(
        &self,
        project: &RepositoryProject,
    ) -> Result<ProjectSummary, SessionError> {
        let name = project.name.trim();
        if name.is_empty() {
            return Err(rejected("Enter a project name."));
        }
        if project.url.trim().is_empty() {
            return Err(rejected("Add the repository this project starts from."));
        }
        if let Some(problem) = project_repository_problem(&project.url, &project.branch) {
            return Err(rejected(problem));
        }
        let branch = project.branch.trim();
        let mut repository = Map::new();
        repository.insert("url".into(), json!(project.url.trim()));
        if !branch.is_empty() {
            repository.insert("branch".into(), json!(branch));
        }
        let mut config = Map::new();
        if let Some(icon) = project.icon.as_deref().filter(|icon| !icon.is_empty()) {
            config.insert("icon".into(), json!(icon));
        }
        let mut checkout = None;
        match &project.target {
            ProjectTarget::Sandbox(provider) => {
                config.insert("host_id".into(), json!(SANDBOX_HOST));
                if let Some(provider) = provider {
                    config.insert("sandbox_provider".into(), json!(provider));
                }
            }
            ProjectTarget::Host(host_id) => {
                let destination = project.destination.trim();
                if destination.is_empty() {
                    return Err(rejected("Choose where to clone the repository."));
                }
                let path = self
                    .clone_repository(host_id, &project.url, Some(branch), destination)
                    .await
                    .map_err(|error| rejected(clone_failure_message(&reason_of(&error))))?;
                config.insert("host_id".into(), json!(host_id));
                config.insert("workspace".into(), json!(path));
                checkout = Some(path);
            }
        }
        config.insert("repository".into(), Value::Object(repository));
        let body = json!({"name": name, "config": config});
        let created = match self.write_json("POST", "/v1/projects", &body).await {
            Ok(created) => created,
            Err(error) => {
                let mut message = project_failure_message(&error).to_owned();
                if let Some(path) = checkout {
                    message.push_str(&format!(" The repository is already checked out at {path}."));
                }
                return Err(rejected(message));
            }
        };
        project_from(&created).map_err(|detail| SessionError::DeliveryUncertain {
            detail: format!("unreadable /v1/projects acknowledgement: {detail}"),
        })
    }
}

#[cfg(test)]
#[path = "project_repository_tests.rs"]
mod tests;
