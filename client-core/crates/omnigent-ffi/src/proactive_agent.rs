//! Omni Advisor: the caller's and the workspace's switches, the admin's prompt and Run now. The
//! rules are `omnigent_core::proactive_agent`.

use omnigent_core::proactive_agent::{
    self as core, AdvisorPrompt, AdvisorRuns, AdvisorScope, AdvisorSettings,
};

use crate::client::ClientCore;
use crate::errors::CoreError;

/// Whose switch a change flips.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AdvisorScopeRecord {
    /// The caller's own.
    Me,
    /// Everyone's (admins, or a single-user owner).
    Workspace,
}

impl From<AdvisorScopeRecord> for AdvisorScope {
    fn from(scope: AdvisorScopeRecord) -> Self {
        match scope {
            AdvisorScopeRecord::Me => Self::Me,
            AdvisorScopeRecord::Workspace => Self::Workspace,
        }
    }
}

/// Whether the advisor runs for the caller, and who may change that.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AdvisorSettingsRecord {
    /// The workspace lets it run.
    pub workspace_enabled: bool,
    /// The caller has it on.
    pub user_enabled: bool,
    /// It runs for the caller.
    pub enabled: bool,
    /// The caller may change the workspace switch.
    pub can_manage_workspace: bool,
    /// The agent whose Inbox items are the advisor's.
    pub agent_id: Option<String>,
    /// The caller's switch reads on: theirs and the workspace's are both on.
    pub shows_on: bool,
}

impl From<AdvisorSettings> for AdvisorSettingsRecord {
    fn from(settings: AdvisorSettings) -> Self {
        Self {
            shows_on: settings.shows_on(),
            workspace_enabled: settings.workspace_enabled,
            user_enabled: settings.user_enabled,
            enabled: settings.enabled,
            can_manage_workspace: settings.can_manage_workspace,
            agent_id: settings.agent_id,
        }
    }
}

/// The advisor's prompt for every user.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AdvisorPromptRecord {
    /// The prompt in use.
    pub prompt: String,
    /// The built-in prompt.
    pub default_prompt: String,
    /// An admin replaced the built-in prompt.
    pub overridden: bool,
}

impl From<AdvisorPrompt> for AdvisorPromptRecord {
    fn from(prompt: AdvisorPrompt) -> Self {
        Self {
            prompt: prompt.prompt,
            default_prompt: prompt.default_prompt,
            overridden: prompt.overridden,
        }
    }
}

/// What Run now did.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AdvisorRunsRecord {
    /// Runs started.
    pub started: u32,
    /// The web's result line.
    pub summary: String,
}

impl From<AdvisorRuns> for AdvisorRunsRecord {
    fn from(runs: AdvisorRuns) -> Self {
        Self {
            started: u32::try_from(runs.started.len()).unwrap_or(u32::MAX),
            summary: runs.summary(),
        }
    }
}

/// The advisor's name wherever it shows.
#[must_use]
#[uniffi::export]
pub fn advisor_name() -> String {
    core::ADVISOR_NAME.to_owned()
}

/// The Run now field's users: split on commas and white space, each once, in order.
#[must_use]
#[uniffi::export]
pub fn advisor_run_users(text: String) -> Vec<String> {
    core::parse_run_users(&text)
}

#[uniffi::export]
impl ClientCore {
    /// The caller's advisor settings.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors (`404` where the server doesn't offer it).
    pub async fn advisor_settings(&self) -> Result<AdvisorSettingsRecord, CoreError> {
        self.sessions()
            .advisor_settings()
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Turns the advisor on or off for the caller or the workspace.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Forbidden` for the workspace without admin rights; the write
    /// errors.
    pub async fn set_advisor_enabled(
        &self,
        scope: AdvisorScopeRecord,
        enabled: bool,
    ) -> Result<AdvisorSettingsRecord, CoreError> {
        self.sessions()
            .set_advisor_enabled(scope.into(), enabled)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// The advisor's prompt (admins).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Forbidden` for a non-admin; the read errors.
    pub async fn advisor_prompt(&self) -> Result<AdvisorPromptRecord, CoreError> {
        self.sessions()
            .advisor_prompt()
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Replaces the advisor's prompt; `nil` or blank restores the built-in one.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Rejected` over the server's limit; the write errors.
    pub async fn save_advisor_prompt(
        &self,
        prompt: Option<String>,
    ) -> Result<AdvisorPromptRecord, CoreError> {
        self.sessions()
            .save_advisor_prompt(prompt.as_deref())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Starts advisor runs now for `users` (`["*"]` is everyone with it on).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Rejected` for a list the server refuses; the write errors.
    pub async fn run_advisor(&self, users: Vec<String>) -> Result<AdvisorRunsRecord, CoreError> {
        self.sessions()
            .run_advisor(&users)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}
