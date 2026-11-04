//! The composer's slash commands: the session's skills, the `/` menu, and what sending a
//! command does. The rules are `omnigent_core::slash`'s.

use omnigent_core::events::SendPayload;
use omnigent_core::slash as core;

use crate::client::{ClientCore, MessageSent};
use crate::configuration::SessionConfiguration;
use crate::errors::CoreError;

/// A skill discovered on the session's host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct Skill {
    /// The invocation name.
    pub name: String,
    /// One line.
    pub description: String,
    /// A human-facing label.
    pub display_name: Option<String>,
}

/// A session's skills, and the sources the host could not read.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SkillCatalog {
    /// User-invocable skills.
    pub skills: Vec<Skill>,
    /// Non-empty means `skills` is incomplete.
    pub warnings: Vec<String>,
}

/// One entry of the `/` menu.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SlashCommand {
    /// The name without its prefix.
    pub name: String,
    /// `/`, or `$` for Codex skills.
    pub prefix: String,
    /// One line.
    pub description: String,
    /// A skill rather than a built-in.
    pub is_skill: bool,
}

/// What sending a command does.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SlashAction {
    /// Send the text as an ordinary message.
    SendText,
    /// Run a skill on the server ([`ClientCore::run_skill`]).
    RunSkill {
        /// The skill.
        name: String,
        /// Everything after the name.
        arguments: String,
    },
    /// The harness's compact control ([`ClientCore::compact`]).
    Compact,
    /// Change the model; `None` resets it.
    SetModel {
        /// The model.
        model: Option<String>,
    },
    /// Change the effort; `None` resets it.
    SetEffort {
        /// The effort.
        effort: Option<String>,
    },
    /// Start a blank session in the same project.
    NewSession,
    /// Show `text` and send nothing.
    Show {
        /// The text.
        text: String,
    },
}

impl From<core::Skill> for Skill {
    fn from(skill: core::Skill) -> Self {
        Self {
            name: skill.name,
            description: skill.description,
            display_name: skill.display_name,
        }
    }
}

impl From<Skill> for core::Skill {
    fn from(skill: Skill) -> Self {
        Self {
            name: skill.name,
            description: skill.description,
            display_name: skill.display_name,
        }
    }
}

impl From<core::SlashCommand> for SlashCommand {
    fn from(command: core::SlashCommand) -> Self {
        Self {
            name: command.name,
            prefix: command.prefix,
            description: command.description,
            is_skill: command.is_skill,
        }
    }
}

impl From<core::SlashAction> for SlashAction {
    fn from(action: core::SlashAction) -> Self {
        match action {
            core::SlashAction::SendText => Self::SendText,
            core::SlashAction::RunSkill { name, arguments } => Self::RunSkill { name, arguments },
            core::SlashAction::Compact => Self::Compact,
            core::SlashAction::SetModel { model } => Self::SetModel { model },
            core::SlashAction::SetEffort { effort } => Self::SetEffort { effort },
            core::SlashAction::NewSession => Self::NewSession,
            core::SlashAction::Show { text } => Self::Show { text },
        }
    }
}

fn core_skills(skills: Vec<Skill>) -> Vec<core::Skill> {
    skills.into_iter().map(Into::into).collect()
}

/// The `/` menu for a session: its built-ins first, then its skills.
#[must_use]
#[uniffi::export]
pub fn slash_commands(
    configuration: SessionConfiguration,
    skills: Vec<Skill>,
) -> Vec<SlashCommand> {
    core::slash_commands(&configuration.into(), &core_skills(skills))
        .into_iter()
        .map(Into::into)
        .collect()
}

/// What sending `text` does; `None` sends it as an ordinary message.
#[must_use]
#[uniffi::export]
pub fn slash_action(
    text: String,
    has_attachments: bool,
    configuration: SessionConfiguration,
    skills: Vec<Skill>,
) -> Option<SlashAction> {
    core::slash_action(
        &text,
        has_attachments,
        &configuration.into(),
        &core_skills(skills),
    )
    .map(Into::into)
}

#[uniffi::export]
impl ClientCore {
    /// The skills `session_id`'s host offers it.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors (HTTP 409 while the host is not ready, 503 while
    /// it is offline) and `MalformedResponse`.
    pub async fn session_skills(&self, session_id: String) -> Result<SkillCatalog, CoreError> {
        let catalog = self
            .sessions()
            .session_skills(&session_id)
            .await
            .map_err(CoreError::from)?;
        Ok(SkillCatalog {
            skills: catalog.skills.into_iter().map(Into::into).collect(),
            warnings: catalog.warnings,
        })
    }

    /// Runs the skill the composer `text` invokes, through the same gate as `send_message`.
    ///
    /// # Errors
    ///
    /// As `send_message`; staged attachments are refused.
    pub async fn run_skill(
        &self,
        session_id: String,
        text: String,
        name: String,
        arguments: String,
    ) -> Result<MessageSent, CoreError> {
        self.send_command(session_id, text, SendPayload::Skill { name, arguments })
            .await
    }

    /// Compacts the context with the harness's compact control; `text` is the typed command.
    ///
    /// # Errors
    ///
    /// As `send_message`; staged attachments are refused.
    pub async fn compact(
        &self,
        session_id: String,
        text: String,
    ) -> Result<MessageSent, CoreError> {
        self.send_command(session_id, text, SendPayload::Compact)
            .await
    }
}

impl ClientCore {
    async fn send_command(
        &self,
        session_id: String,
        text: String,
        payload: SendPayload,
    ) -> Result<MessageSent, CoreError> {
        let sent = self
            .sessions()
            .send_command(&session_id, &text, payload)
            .await
            .map_err(CoreError::from)?;
        Ok(MessageSent {
            queued: sent.submission.queued,
            item_id: sent.submission.item_id,
            pending_id: sent.submission.pending_id,
            draft: sent.draft,
        })
    }
}
