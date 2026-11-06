//! The composer's session tools: side chats, Codex plan mode and the session goal.
//!
//! The rules are `omnigent_core::session_tools`'s.

use omnigent_core::session_tools as core;

use crate::client::ClientCore;
use crate::creation::FirstMessage;
use crate::errors::CoreError;

/// How a side chat starts.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SideChatStart {
    /// The harness forks from a typed command: put `prefix` in the composer for the question.
    Command {
        /// The command prefix.
        prefix: String,
    },
    /// Open an empty side chat with `draft` in its composer; its session is created when the
    /// first message is sent (`create_side_chat`).
    Draft {
        /// The composer's starting text, empty or a quote.
        draft: String,
    },
}

impl From<core::SideChatStart> for SideChatStart {
    fn from(start: core::SideChatStart) -> Self {
        match start {
            core::SideChatStart::Command { prefix } => Self::Command { prefix },
            core::SideChatStart::Draft { draft } => Self::Draft { draft },
        }
    }
}

/// A side chat created by its first message.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CreatedSideChat {
    /// The side chat session.
    pub session_id: String,
    /// The first message's outcome. The session exists either way: retry the send to it.
    pub first_message: FirstMessage,
}

impl From<core::CreatedSideChat> for CreatedSideChat {
    fn from(created: core::CreatedSideChat) -> Self {
        Self {
            session_id: created.session_id,
            first_message: created.first_message.into(),
        }
    }
}

/// How a side chat of a session on `harness` starts, with a `quote` (selected transcript text)
/// quoted in its composer. Makes no request.
#[uniffi::export]
pub fn side_chat_start(harness: Option<String>, quote: Option<String>) -> SideChatStart {
    core::side_chat_start(harness.as_deref(), quote.as_deref()).into()
}

/// How a session takes a goal.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum GoalControl {
    /// Through the goal endpoints, with progress and pause.
    Managed,
    /// As a `/goal <condition>` message to `backend`.
    Command {
        /// The agent that runs the goal ("Claude", "Codex").
        backend: String,
    },
}

impl From<core::GoalControl> for GoalControl {
    fn from(control: core::GoalControl) -> Self {
        match control {
            core::GoalControl::Managed => Self::Managed,
            core::GoalControl::Command { backend } => Self::Command { backend },
        }
    }
}

/// A session goal as the harness reports it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SessionGoal {
    /// What the agent works toward.
    pub objective: String,
    /// The harness's status, for example `active`, `paused` or `budgetLimited`.
    pub status: String,
    /// The token cap, when set.
    pub token_budget: Option<u64>,
    /// Tokens spent on the goal.
    pub tokens_used: u64,
    /// Seconds spent on the goal.
    pub time_used_seconds: u64,
    /// The user can pause it.
    pub can_pause: bool,
    /// The user can resume it.
    pub can_resume: bool,
}

impl From<core::SessionGoal> for SessionGoal {
    fn from(goal: core::SessionGoal) -> Self {
        Self {
            can_pause: goal.can_pause(),
            can_resume: goal.can_resume(),
            objective: goal.objective,
            status: goal.status,
            token_budget: goal.token_budget,
            tokens_used: goal.tokens_used,
            time_used_seconds: goal.time_used_seconds,
        }
    }
}

/// Whether Codex plan mode applies to a session (`None` when it does not) and whether it is on.
/// `collaboration_mode` is the mode as reported, in any case.
#[uniffi::export]
pub fn codex_plan_mode(
    wrapper: Option<String>,
    collaboration_mode: Option<String>,
) -> Option<bool> {
    core::codex_plan_mode(wrapper.as_deref(), collaboration_mode.as_deref())
}

/// How a session takes a goal, or `None` when it has no goal control.
#[uniffi::export]
pub fn goal_control(
    wrapper: Option<String>,
    harness: Option<String>,
    agent_name: Option<String>,
    parent_id: Option<String>,
) -> Option<GoalControl> {
    core::goal_control(
        wrapper.as_deref(),
        harness.as_deref(),
        agent_name.as_deref(),
        parent_id.as_deref(),
    )
    .map(Into::into)
}

/// The message that starts a goal on a command-goal session; `None` when blank.
#[uniffi::export]
pub fn goal_command(condition: String) -> Option<String> {
    core::goal_command(&condition)
}

/// `draft` with `selection` quoted after it, then an empty paragraph for the reply.
#[uniffi::export]
pub fn reply_quote(draft: String, selection: String) -> String {
    core::reply_quote(&draft, &selection)
}

#[uniffi::export]
impl ClientCore {
    /// Creates a side chat of `session_id` and sends `text` as its first message. A failed first
    /// message is reported in the result once the side chat exists.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `EmptyMessage`, the read and write errors,
    /// `ExecutionUnavailable` when the session's runner is gone, `DeliveryUncertain` when the
    /// fork may exist.
    pub async fn create_side_chat(
        &self,
        session_id: String,
        text: String,
    ) -> Result<CreatedSideChat, CoreError> {
        self.sessions()
            .create_side_chat(&session_id, &text)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Turns Codex plan mode on or off. Returns whether it is on afterwards.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the write errors and `DeliveryUncertain`.
    pub async fn set_plan_mode(&self, session_id: String, on: bool) -> Result<bool, CoreError> {
        self.sessions()
            .set_plan_mode(&session_id, on)
            .await
            .map_err(CoreError::from)
    }

    /// The session's goal, or `None` when it has none.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn session_goal(&self, session_id: String) -> Result<Option<SessionGoal>, CoreError> {
        self.sessions()
            .session_goal(&session_id)
            .await
            .map(|goal| goal.map(Into::into))
            .map_err(CoreError::from)
    }

    /// Sets the goal: `objective`, the token cap (`None` clears it) and, when given, whether it
    /// runs or waits paused.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `EmptyMessage` for a blank objective, the write errors.
    pub async fn set_session_goal(
        &self,
        session_id: String,
        objective: String,
        token_budget: Option<u64>,
        active: Option<bool>,
    ) -> Result<Option<SessionGoal>, CoreError> {
        self.sessions()
            .set_session_goal(&session_id, &objective, token_budget, active)
            .await
            .map(|goal| goal.map(Into::into))
            .map_err(CoreError::from)
    }

    /// Pauses (`false`) or resumes (`true`) the goal.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the write errors.
    pub async fn set_session_goal_active(
        &self,
        session_id: String,
        active: bool,
    ) -> Result<Option<SessionGoal>, CoreError> {
        self.sessions()
            .set_session_goal_active(&session_id, active)
            .await
            .map(|goal| goal.map(Into::into))
            .map_err(CoreError::from)
    }

    /// Clears the goal. Returns whether there was one.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the write errors.
    pub async fn clear_session_goal(&self, session_id: String) -> Result<bool, CoreError> {
        self.sessions()
            .clear_session_goal(&session_id)
            .await
            .map_err(CoreError::from)
    }
}
