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

/// What the server offers beyond the session's configuration ([`ClientCore::slash_options`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Record)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent server capability flags, mirrored one to one from /v1/info"
)]
pub struct SlashOptions {
    /// The server takes the `clear` control.
    pub server_clears: bool,
    /// Sessions may turn Smart Routing on.
    #[uniffi(default = false)]
    pub smart_routing: bool,
    /// A router can answer for a native Claude Code or Codex pane.
    #[uniffi(default = false)]
    pub routes_native_panes: bool,
}

impl From<SlashOptions> for core::SlashOptions {
    fn from(options: SlashOptions) -> Self {
        Self {
            server_clears: options.server_clears,
            smart_routing: options.smart_routing,
            routes_native_panes: options.routes_native_panes,
        }
    }
}

impl From<core::SlashOptions> for SlashOptions {
    fn from(options: core::SlashOptions) -> Self {
        Self {
            server_clears: options.server_clears,
            smart_routing: options.smart_routing,
            routes_native_panes: options.routes_native_panes,
        }
    }
}

/// Whether the model picker offers Smart Routing for the session.
#[must_use]
#[uniffi::export]
pub fn offers_smart_routing(configuration: SessionConfiguration, options: SlashOptions) -> bool {
    core::offers_smart_routing(&configuration.into(), &options.into())
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
    /// Run the harness's own `/clear` ([`ClientCore::clear_context`]).
    Clear,
    /// Fork a side chat and open it with `question` as its draft.
    SideChat {
        /// Everything after `/side`; may be empty.
        question: String,
    },
    /// Show the context usage ([`context_report`]).
    Context,
    /// Show the session's MCP servers ([`mcp_report`]).
    Mcp,
    /// Open the approval-mode picker.
    Permissions,
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
            core::SlashAction::Clear => Self::Clear,
            core::SlashAction::SideChat { question } => Self::SideChat { question },
            core::SlashAction::Context => Self::Context,
            core::SlashAction::Mcp => Self::Mcp,
            core::SlashAction::Permissions => Self::Permissions,
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
    options: SlashOptions,
) -> Vec<SlashCommand> {
    core::slash_commands(&configuration.into(), &core_skills(skills), &options.into())
        .into_iter()
        .map(Into::into)
        .collect()
}

/// `skills` as `/` menu rows for `harness` (`$` for Codex), for a composer with no session yet.
#[must_use]
#[uniffi::export]
pub fn skill_commands(harness: Option<String>, skills: Vec<Skill>) -> Vec<SlashCommand> {
    core::skill_commands(harness.as_deref(), &core_skills(skills))
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
    options: SlashOptions,
) -> Option<SlashAction> {
    core::slash_action(
        &text,
        has_attachments,
        &configuration.into(),
        &core_skills(skills),
        &options.into(),
    )
    .map(Into::into)
}

/// The `/context` text: the model, tokens used against the window, and the item count.
#[must_use]
#[uniffi::export]
pub fn context_report(
    configuration: Option<SessionConfiguration>,
    tokens_used: Option<u64>,
    context_window: Option<u64>,
    items: u64,
) -> String {
    let configuration = configuration.map(Into::into);
    core::context_report(
        configuration.as_ref(),
        core::ContextUsage {
            tokens_used,
            context_window,
            items,
        },
    )
}

/// The marker lines `@`-tagged workspace `paths` put ahead of a message, worded for `harness`.
#[must_use]
#[uniffi::export]
pub fn mention_preamble(harness: Option<String>, paths: Vec<String>) -> String {
    omnigent_core::mentions::mention_preamble(harness.as_deref(), &paths)
}

/// The `/mcp` text for the agent's MCP servers; `None` while they are unknown.
#[must_use]
#[uniffi::export]
pub fn mcp_report(servers: Option<Vec<String>>) -> String {
    core::mcp_report(servers.as_deref())
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

    /// The skills `harness` would see in `path` on `host_id`, before a session exists (the
    /// new-session composer's `/` menu).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors (503 while the host is
    /// offline) and `MalformedResponse`.
    pub async fn host_skills(
        &self,
        host_id: String,
        harness: String,
        path: String,
        agent_id: Option<String>,
    ) -> Result<SkillCatalog, CoreError> {
        let catalog = self
            .sessions()
            .host_skills(&host_id, &harness, &path, agent_id.as_deref())
            .await
            .map_err(CoreError::from)?;
        Ok(SkillCatalog {
            skills: catalog.skills.into_iter().map(Into::into).collect(),
            warnings: catalog.warnings,
        })
    }

    /// Which server-backed commands the composer may offer.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn slash_options(&self) -> Result<SlashOptions, CoreError> {
        self.sessions()
            .slash_options()
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Turns Smart Routing on or off for `session_id`; the router then picks the model and
    /// effort each turn.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Busy`, the configuration guards, `DeliveryUncertain` when the
    /// acknowledgement does not show the mode, and the read and write errors.
    pub async fn set_smart_routing(
        &self,
        session_id: String,
        enabled: bool,
    ) -> Result<crate::sessions::SessionSummary, CoreError> {
        self.sessions()
            .set_smart_routing(enabled, &session_id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Runs the harness's own `/clear`; the view follows the session that supersedes this one.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `ReadOnly` and the read and write errors.
    pub async fn clear_context(&self, session_id: String) -> Result<(), CoreError> {
        self.sessions()
            .clear_context(&session_id)
            .await
            .map_err(CoreError::from)
    }

    /// Turns the server's automatic session titles on or off for this device's requests.
    pub fn set_background_session_titles(&self, enabled: bool) {
        self.sessions().set_background_session_titles(enabled);
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
