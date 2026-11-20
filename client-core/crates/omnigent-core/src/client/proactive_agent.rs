//! Omni Advisor, the server's proactive agent (`/v1/proactive-agent`).
//!
//! The caller's switch, the workspace switch, and the admin's prompt and Run now, as the web's
//! `useProactiveAgentSettings` and `ProactiveAgentAdminControls`. Servers offer it with
//! `/v1/info.proactive_agent_available`; its suggestions are Inbox items posted by its agent.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::json::{as_object, opt_array, opt_bool, opt_str, req_str};
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

const SETTINGS_PATH: &str = "/v1/proactive-agent/settings";
const PROMPT_PATH: &str = "/v1/proactive-agent/prompt";
const RUNS_PATH: &str = "/v1/proactive-agent/runs";

/// The advisor's name wherever it shows.
pub const ADVISOR_NAME: &str = "Omni Advisor";

/// Whose switch a change flips.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AdvisorScope {
    /// The caller's own (`…/settings/me`); any user may change it.
    Me,
    /// Everyone's (`…/settings/workspace`); admins, or a single-user owner.
    Workspace,
}

impl AdvisorScope {
    const fn path(self) -> &'static str {
        match self {
            Self::Me => "/v1/proactive-agent/settings/me",
            Self::Workspace => "/v1/proactive-agent/settings/workspace",
        }
    }
}

/// Whether the advisor runs for the caller, and who may change that.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "the server's settings, mirrored one to one"
)]
pub struct AdvisorSettings {
    /// The workspace lets it run.
    pub workspace_enabled: bool,
    /// The caller has it on.
    pub user_enabled: bool,
    /// It runs for the caller: both of the above.
    pub enabled: bool,
    /// The caller may change the workspace switch. An unreported value counts as allowed, as
    /// the web hides the admin group only on an explicit `false`.
    pub can_manage_workspace: bool,
    /// The agent whose Inbox items are the advisor's.
    pub agent_id: Option<String>,
}

impl AdvisorSettings {
    /// Decodes a settings answer.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, SETTINGS_PATH)?;
        let workspace_enabled = opt_bool(object, "workspace_enabled")?.unwrap_or(true);
        let user_enabled = opt_bool(object, "user_enabled")?.unwrap_or(true);
        Ok(Self {
            workspace_enabled,
            user_enabled,
            enabled: opt_bool(object, "enabled")?.unwrap_or(workspace_enabled && user_enabled),
            can_manage_workspace: opt_bool(object, "can_manage_workspace")?.unwrap_or(true),
            agent_id: opt_str(object, "agent_id")?.filter(|id| !id.is_empty()),
        })
    }

    /// The caller's switch reads on only while the workspace lets it run, as on the web.
    #[must_use]
    pub const fn shows_on(&self) -> bool {
        self.user_enabled && self.workspace_enabled
    }

    /// Whether an Inbox item from `agent_id` is the advisor's.
    #[must_use]
    pub fn posted(&self, agent_id: &str) -> bool {
        self.agent_id.as_deref() == Some(agent_id)
    }
}

/// The advisor's instructions for every user (admins).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AdvisorPrompt {
    /// The prompt in use: the override, else the built-in one.
    pub prompt: String,
    /// The built-in prompt.
    pub default_prompt: String,
    /// An admin replaced the built-in prompt.
    pub overridden: bool,
}

impl AdvisorPrompt {
    /// Decodes a prompt answer.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, PROMPT_PATH)?;
        Ok(Self {
            prompt: req_str(object, "prompt")?,
            default_prompt: opt_str(object, "default_prompt")?.unwrap_or_default(),
            overridden: opt_bool(object, "overridden")?.unwrap_or(false),
        })
    }
}

/// A run Run now started.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AdvisorRunStarted {
    /// For whom.
    pub user_id: String,
    /// Their advisor task.
    pub task_id: String,
    /// The run, when the scheduler reported it.
    pub run_id: Option<String>,
}

/// A user Run now started nothing for, and why (`no_task`, `turned_off`, `already_running`,
/// `unavailable`, or a newer reason as sent).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AdvisorRunSkipped {
    /// For whom.
    pub user_id: String,
    /// The server's reason code.
    pub reason: String,
}

/// What Run now did.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AdvisorRuns {
    /// Runs started.
    pub started: Vec<AdvisorRunStarted>,
    /// Users skipped.
    pub skipped: Vec<AdvisorRunSkipped>,
    /// `*` matched more tasks than one request starts.
    pub truncated: bool,
}

impl AdvisorRuns {
    /// Decodes a Run now answer.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, RUNS_PATH)?;
        let mut started = Vec::new();
        for row in opt_array(object, "started")?.into_iter().flatten() {
            let row = as_object(row, "started run")?;
            started.push(AdvisorRunStarted {
                user_id: req_str(row, "user_id")?,
                task_id: req_str(row, "task_id")?,
                run_id: opt_str(row, "run_id")?,
            });
        }
        let mut skipped = Vec::new();
        for row in opt_array(object, "skipped")?.into_iter().flatten() {
            let row = as_object(row, "skipped user")?;
            skipped.push(AdvisorRunSkipped {
                user_id: req_str(row, "user_id")?,
                reason: req_str(row, "reason")?,
            });
        }
        Ok(Self {
            started,
            skipped,
            truncated: opt_bool(object, "truncated")?.unwrap_or(false),
        })
    }

    /// The web's result line: "Started 2 runs. Skipped: user@example.com (turned off)."
    #[must_use]
    pub fn summary(&self) -> String {
        let count = self.started.len();
        let noun = if count == 1 { "run" } else { "runs" };
        let cap = if self.truncated {
            ", the most one request starts"
        } else {
            ""
        };
        let started = format!("Started {count} {noun}{cap}.");
        if self.skipped.is_empty() {
            return started;
        }
        let skipped: Vec<String> = self
            .skipped
            .iter()
            .map(|skip| format!("{} ({})", skip.user_id, skip_reason(&skip.reason)))
            .collect();
        format!("{started} Skipped: {}.", skipped.join(", "))
    }
}

/// The web's words for a skip reason; a newer code shows as sent.
#[must_use]
pub fn skip_reason(reason: &str) -> &str {
    match reason {
        "no_task" => "no task yet",
        "turned_off" => "turned off",
        "already_running" => "already running",
        "unavailable" => "scheduler unavailable",
        other => other,
    }
}

/// The Run now field's users: split on commas and white space, each once, in order. A lone `*`
/// means everyone with the advisor on.
#[must_use]
pub fn parse_run_users(text: &str) -> Vec<String> {
    let mut seen = BTreeSet::new();
    text.split(|character: char| character == ',' || character.is_whitespace())
        .filter(|user| !user.is_empty() && seen.insert(*user))
        .map(str::to_owned)
        .collect()
}

impl<T: HttpTransport> ClientCore<T> {
    /// The caller's advisor settings (`GET /v1/proactive-agent/settings`).
    ///
    /// # Errors
    ///
    /// The read errors (`404` where the server doesn't offer it);
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn advisor_settings(&self) -> Result<AdvisorSettings, SessionError> {
        let result = self.get_json(SETTINGS_PATH, &[]).await;
        self.dispatch();
        AdvisorSettings::from_value(&result?).map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{SETTINGS_PATH}: {detail}"),
        })
    }

    /// Turns the advisor on or off for the caller or, for an admin, the workspace.
    ///
    /// # Errors
    ///
    /// `Forbidden` (403) when the caller may not change the workspace; the write errors;
    /// `DeliveryUncertain` for an unreadable acknowledgement.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn set_advisor_enabled(
        &self,
        scope: AdvisorScope,
        enabled: bool,
    ) -> Result<AdvisorSettings, SessionError> {
        let path = scope.path();
        let result = self
            .write_json("PUT", path, &json!({ "enabled": enabled }))
            .await;
        self.dispatch();
        AdvisorSettings::from_value(&result?).map_err(|detail| SessionError::DeliveryUncertain {
            detail: format!("unreadable {path} acknowledgement: {detail}"),
        })
    }

    /// The advisor's prompt (admins; `GET /v1/proactive-agent/prompt`).
    ///
    /// # Errors
    ///
    /// `Forbidden` for a non-admin; the read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn advisor_prompt(&self) -> Result<AdvisorPrompt, SessionError> {
        let result = self.get_json(PROMPT_PATH, &[]).await;
        self.dispatch();
        AdvisorPrompt::from_value(&result?).map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{PROMPT_PATH}: {detail}"),
        })
    }

    /// Replaces the advisor's prompt for every user; `None` or blank restores the built-in one.
    ///
    /// # Errors
    ///
    /// `Rejected` (400) for a prompt over the server's limit; `Forbidden` for a non-admin; the
    /// write errors; `DeliveryUncertain` for an unreadable acknowledgement.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn save_advisor_prompt(
        &self,
        prompt: Option<&str>,
    ) -> Result<AdvisorPrompt, SessionError> {
        let prompt = prompt.filter(|text| !text.trim().is_empty());
        let result = self
            .write_json("PUT", PROMPT_PATH, &json!({ "prompt": prompt }))
            .await;
        self.dispatch();
        AdvisorPrompt::from_value(&result?).map_err(|detail| SessionError::DeliveryUncertain {
            detail: format!("unreadable {PROMPT_PATH} acknowledgement: {detail}"),
        })
    }

    /// Starts advisor runs now for `users` (see [`parse_run_users`]; `["*"]` is everyone).
    ///
    /// # Errors
    ///
    /// `Rejected` (400) for an empty list, too many users or `*` among others; `Forbidden` for a
    /// non-admin; the write errors; `DeliveryUncertain` for an unreadable acknowledgement.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn run_advisor(&self, users: &[String]) -> Result<AdvisorRuns, SessionError> {
        let result = self
            .write_json("POST", RUNS_PATH, &json!({ "users": users }))
            .await;
        self.dispatch();
        AdvisorRuns::from_value(&result?).map_err(|detail| SessionError::DeliveryUncertain {
            detail: format!("unreadable {RUNS_PATH} acknowledgement: {detail}"),
        })
    }
}

#[cfg(test)]
#[path = "proactive_agent_tests.rs"]
mod tests;
