//! A project's stored new-session defaults and icon, and the project order's sort mode.
//!
//! The defaults are `config` on `/v1/projects/{id}` (host, folder, worktree, base branch,
//! agent, model, effort, icon), as the web's Project settings and Rename dialogs edit them.
//!
//! The server stores `config` whole and never reads it, so a save re-reads it and replaces only
//! the keys these dialogs own, keeping any other client's keys.

use serde_json::{Map, Value, json};

use super::json::{as_object, opt_bool, opt_object, opt_str};
use super::projects::ProjectSummary;
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// The host choice that provisions a managed sandbox (the web's `SANDBOX_HOST_CHOICE`).
pub const SANDBOX_HOST_CHOICE: &str = "__sandbox__";

/// A project's new-session defaults; `None` is no default.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct ProjectSettings {
    /// The host id, or [`SANDBOX_HOST_CHOICE`].
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

impl ProjectSettings {
    /// Reads the settings from a project's `config` object; a missing one has none.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_config(config: Option<&Map<String, Value>>) -> Result<Self, String> {
        let Some(config) = config else {
            return Ok(Self::default());
        };
        let text = |key: &str| -> Result<Option<String>, String> {
            Ok(opt_str(config, key)?.filter(|value| !value.trim().is_empty()))
        };
        Ok(Self {
            host_id: text("host_id")?,
            workspace: text("workspace")?,
            use_worktree: opt_bool(config, "use_worktree")?,
            base_branch: text("base_branch")?,
            agent_id: text("agent_id")?,
            model: text("model")?,
            // The server stores config untyped, so a malformed effort is no default.
            effort: config
                .get("effort")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(str::to_owned),
        })
    }

    /// `config` with this form's keys replaced, as the web's Project settings saves them: a
    /// folder only with a concrete host, the worktree choice only when it differs from the
    /// global default `always_use_worktree`, and a base branch only with a worktree.
    #[must_use]
    pub fn merged_into(&self, config: &Map<String, Value>, always_use_worktree: bool) -> Value {
        let mut merged = config.clone();
        let trimmed = |value: &Option<String>| {
            value
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        };
        let host = trimmed(&self.host_id);
        let concrete_host = host
            .as_deref()
            .is_some_and(|id| !id.starts_with(SANDBOX_HOST_CHOICE));
        let use_worktree = self.use_worktree.unwrap_or(always_use_worktree);
        let mut put = |key: &str, value: Option<Value>| match value {
            Some(value) => {
                merged.insert(key.to_owned(), value);
            }
            None => {
                merged.remove(key);
            }
        };
        put("host_id", host.map(Value::String));
        put(
            "workspace",
            trimmed(&self.workspace)
                .filter(|_| concrete_host)
                .map(Value::String),
        );
        put(
            "use_worktree",
            (use_worktree != always_use_worktree).then_some(Value::Bool(use_worktree)),
        );
        put(
            "base_branch",
            trimmed(&self.base_branch)
                .filter(|_| use_worktree)
                .map(Value::String),
        );
        put("agent_id", trimmed(&self.agent_id).map(Value::String));
        put("model", trimmed(&self.model).map(Value::String));
        put("effort", trimmed(&self.effort).map(Value::String));
        Value::Object(merged)
    }
}

/// How the sidebar orders projects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ProjectSortMode {
    /// By name.
    Alphabetical,
    /// The caller's saved order.
    Manual,
}

impl<T: HttpTransport> ClientCore<T> {
    /// The stored defaults of `project`; a label-only project has none yet.
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`] for a malformed project or config.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn project_settings(
        &self,
        project: &ProjectSummary,
    ) -> Result<ProjectSettings, SessionError> {
        let result = self.project_config(project).await;
        self.dispatch();
        let config = result?;
        ProjectSettings::from_config(Some(&config)).map_err(|detail| {
            SessionError::MalformedResponse {
                detail: format!("project config: {detail}"),
            }
        })
    }

    /// Saves `settings` as `project`'s defaults, promoting a label-only project first, and
    /// returns the project with its id.
    ///
    /// # Errors
    ///
    /// The promotion's errors (see [`Self::rename_project`]); the read and write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn save_project_settings(
        &self,
        project: &ProjectSummary,
        settings: &ProjectSettings,
        always_use_worktree: bool,
    ) -> Result<ProjectSummary, SessionError> {
        let result = self
            .update_project_config(project, |config| {
                settings.merged_into(config, always_use_worktree)
            })
            .await;
        self.dispatch();
        result
    }

    /// Sets or clears `project`'s emoji icon (`config.icon`), promoting a label-only project.
    ///
    /// # Errors
    ///
    /// As [`Self::save_project_settings`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn set_project_icon(
        &self,
        project: &ProjectSummary,
        icon: Option<&str>,
    ) -> Result<ProjectSummary, SessionError> {
        let icon = icon.map(str::trim).filter(|icon| !icon.is_empty());
        let result = self
            .update_project_config(project, |config| {
                let mut config = config.clone();
                match icon {
                    Some(icon) => config.insert("icon".into(), Value::String(icon.to_owned())),
                    None => config.remove("icon"),
                };
                Value::Object(config)
            })
            .await;
        self.dispatch();
        result
    }

    /// How projects are sorted (`GET /v1/projects/order`); a server without an order sorts
    /// them by name.
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`] for a malformed body.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn project_sort_mode(&self) -> Result<ProjectSortMode, SessionError> {
        let result = self.get_json("/v1/projects/order", &[]).await;
        self.dispatch();
        if matches!(result, Err(SessionError::HttpStatus { status: 404 })) {
            return Ok(ProjectSortMode::Alphabetical);
        }
        let body = result?;
        let malformed = |detail: String| SessionError::MalformedResponse {
            detail: format!("/v1/projects/order: {detail}"),
        };
        let object = as_object(&body, "/v1/projects/order").map_err(malformed)?;
        Ok(
            match opt_str(object, "sort_mode").map_err(malformed)?.as_deref() {
                Some("manual") => ProjectSortMode::Manual,
                _ => ProjectSortMode::Alphabetical,
            },
        )
    }

    /// Drops the saved project order, so projects sort by name again.
    ///
    /// # Errors
    ///
    /// The write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn sort_projects_alphabetically(&self) -> Result<(), SessionError> {
        let result = self
            .write_json(
                "PUT",
                "/v1/projects/order",
                &json!({"ordered_project_ids": null}),
            )
            .await;
        self.dispatch();
        result.map(|_| ())
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn project_config(
        &self,
        project: &ProjectSummary,
    ) -> Result<Map<String, Value>, SessionError> {
        let Some(id) = &project.id else {
            return Ok(Map::new());
        };
        validate_identifier(id)?;
        let path = format!("/v1/projects/{id}");
        let body = self.get_json(&path, &[]).await?;
        let malformed = |detail: String| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        };
        let object = as_object(&body, &path).map_err(malformed)?;
        Ok(opt_object(object, "config")
            .map_err(malformed)?
            .cloned()
            .unwrap_or_default())
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn update_project_config(
        &self,
        project: &ProjectSummary,
        update: impl FnOnce(&Map<String, Value>) -> Value,
    ) -> Result<ProjectSummary, SessionError> {
        let config = self.project_config(project).await?;
        let project = if project.id.is_some() {
            project.clone()
        } else {
            self.rename_project_rows(project, &project.name).await?
        };
        let Some(id) = project.id.as_deref() else {
            return Err(SessionError::DeliveryUncertain {
                detail: "the promoted project has no id".into(),
            });
        };
        let path = format!("/v1/projects/{id}");
        let acknowledgement = self
            .write_json("PATCH", &path, &json!({"config": update(&config)}))
            .await?;
        super::projects::project_from(&acknowledgement).map_err(|detail| {
            SessionError::DeliveryUncertain {
                detail: format!("unreadable {path} acknowledgement: {detail}"),
            }
        })
    }
}

#[cfg(test)]
#[path = "project_settings_tests.rs"]
mod tests;
