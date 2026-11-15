//! A session's managed sandbox as a view shows it: the launch, whether it is up, and the
//! operations that apply. The rules are `omnigent_core::sandbox_state`'s.

use omnigent_core::sandbox_state as core;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// A stage of a sandbox launch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SandboxLaunchStage {
    /// Creating the sandbox.
    Provisioning,
    /// Creating the sandbox, which waits on the user.
    ActionRequired,
    /// Cloning the repository workspace.
    Cloning,
    /// Starting the host inside the sandbox.
    Starting,
    /// Launching the agent's runner on that host.
    Connecting,
    /// The launch succeeded: the sandbox's host and runner now speak for it.
    Ready,
    /// The launch failed.
    Failed,
}

impl From<core::LaunchStage> for SandboxLaunchStage {
    fn from(stage: core::LaunchStage) -> Self {
        match stage {
            core::LaunchStage::Provisioning => Self::Provisioning,
            core::LaunchStage::ActionRequired => Self::ActionRequired,
            core::LaunchStage::Cloning => Self::Cloning,
            core::LaunchStage::Starting => Self::Starting,
            core::LaunchStage::Connecting => Self::Connecting,
            core::LaunchStage::Ready => Self::Ready,
            core::LaunchStage::Failed => Self::Failed,
        }
    }
}

impl From<SandboxLaunchStage> for core::LaunchStage {
    fn from(stage: SandboxLaunchStage) -> Self {
        match stage {
            SandboxLaunchStage::Provisioning => Self::Provisioning,
            SandboxLaunchStage::ActionRequired => Self::ActionRequired,
            SandboxLaunchStage::Cloning => Self::Cloning,
            SandboxLaunchStage::Starting => Self::Starting,
            SandboxLaunchStage::Connecting => Self::Connecting,
            SandboxLaunchStage::Ready => Self::Ready,
            SandboxLaunchStage::Failed => Self::Failed,
        }
    }
}

/// A sandbox launch as the server last reported it; a ready one still names the provider.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SandboxLaunch {
    /// The stage.
    pub stage: SandboxLaunchStage,
    /// The provider being launched, for example `arclet`.
    pub provider: Option<String>,
    /// What the user must do, while the launch waits on them.
    pub details: Option<String>,
    /// Why it failed.
    pub error: Option<String>,
}

impl From<core::SandboxLaunch> for SandboxLaunch {
    fn from(launch: core::SandboxLaunch) -> Self {
        Self {
            stage: launch.stage.into(),
            provider: launch.provider,
            details: launch.details,
            error: launch.error,
        }
    }
}

impl From<SandboxLaunch> for core::SandboxLaunch {
    fn from(launch: SandboxLaunch) -> Self {
        Self {
            stage: launch.stage.into(),
            provider: launch.provider,
            details: launch.details,
            error: launch.error,
        }
    }
}

/// The profile a sandbox launched with, as the session names it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SandboxProfileName {
    /// The profile's provider.
    pub provider: String,
    /// Its display name.
    pub name: String,
}

impl From<core::SandboxProfileName> for SandboxProfileName {
    fn from(profile: core::SandboxProfileName) -> Self {
        Self {
            provider: profile.provider,
            name: profile.name,
        }
    }
}

impl From<SandboxProfileName> for core::SandboxProfileName {
    fn from(profile: SandboxProfileName) -> Self {
        Self {
            provider: profile.provider,
            name: profile.name,
        }
    }
}

/// What a session reports about its sandbox.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SandboxSignals {
    /// The launch as last reported, a finished one included.
    pub launch: Option<SandboxLaunch>,
    /// The profile it launched with.
    pub profile: Option<SandboxProfileName>,
    /// The bound host's sandbox name in the host list ("Modal Sandbox"); `None` for a machine.
    pub host_sandbox: Option<String>,
    /// The bound host.
    pub host_id: Option<String>,
    /// The host tunnel is up; `None` until reported.
    pub host_online: Option<bool>,
    /// The runner is connected; `None` until reported.
    pub runner_online: Option<bool>,
    /// The server can resume the stopped sandbox in place.
    pub host_resumable: Option<bool>,
    /// A turn is running or waiting to start.
    pub turn_active: bool,
    /// The viewer may send to the session.
    pub can_edit: bool,
    /// The viewer owns the session.
    pub is_owner: bool,
}

impl From<SandboxSignals> for core::SandboxSignals {
    fn from(signals: SandboxSignals) -> Self {
        Self {
            launch: signals.launch.map(Into::into),
            profile: signals.profile.map(Into::into),
            host_sandbox: signals.host_sandbox,
            host_id: signals.host_id,
            host_online: signals.host_online,
            runner_online: signals.runner_online,
            host_resumable: signals.host_resumable,
            turn_active: signals.turn_active,
            can_edit: signals.can_edit,
            is_owner: signals.is_owner,
        }
    }
}

/// Where a sandbox is in its life.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SandboxPhase {
    /// A launch is under way.
    Launching,
    /// A launch waits on the user.
    ActionRequired,
    /// The launch failed.
    Failed,
    /// The agent's runner is connected.
    Running,
    /// A turn is bringing the sandbox or its agent back.
    Waking,
    /// The sandbox is up and its agent is not; the next message starts it.
    AgentAsleep,
    /// The sandbox is stopped and the server resumes it on the next message.
    Asleep,
    /// The sandbox is gone; the server can only launch a new one.
    Offline,
    /// The server has not said.
    Unknown,
}

impl From<core::SandboxPhase> for SandboxPhase {
    fn from(phase: core::SandboxPhase) -> Self {
        match phase {
            core::SandboxPhase::Launching => Self::Launching,
            core::SandboxPhase::ActionRequired => Self::ActionRequired,
            core::SandboxPhase::Failed => Self::Failed,
            core::SandboxPhase::Running => Self::Running,
            core::SandboxPhase::Waking => Self::Waking,
            core::SandboxPhase::AgentAsleep => Self::AgentAsleep,
            core::SandboxPhase::Asleep => Self::Asleep,
            core::SandboxPhase::Offline => Self::Offline,
            core::SandboxPhase::Unknown => Self::Unknown,
        }
    }
}

/// Something a client can ask of a sandbox session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SandboxOperation {
    /// Wake the sandbox, or relaunch it, and start its agent (`retry_session`).
    Wake,
    /// End the agent's process (`stop_session`).
    Stop,
}

impl From<core::SandboxOperation> for SandboxOperation {
    fn from(operation: core::SandboxOperation) -> Self {
        match operation {
            core::SandboxOperation::Wake => Self::Wake,
            core::SandboxOperation::Stop => Self::Stop,
        }
    }
}

impl From<SandboxOperation> for core::SandboxOperation {
    fn from(operation: SandboxOperation) -> Self {
        match operation {
            SandboxOperation::Wake => Self::Wake,
            SandboxOperation::Stop => Self::Stop,
        }
    }
}

/// What the server did with an operation it took.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SandboxOperationOutcome {
    /// It is bringing the sandbox and its agent back.
    Started,
    /// Nothing needed waking: the agent's runner was already connected.
    AlreadyRunning,
    /// It ended the agent's process, or found none running.
    Stopped,
}

impl From<core::SandboxOperationOutcome> for SandboxOperationOutcome {
    fn from(outcome: core::SandboxOperationOutcome) -> Self {
        match outcome {
            core::SandboxOperationOutcome::Started => Self::Started,
            core::SandboxOperationOutcome::AlreadyRunning => Self::AlreadyRunning,
            core::SandboxOperationOutcome::Stopped => Self::Stopped,
        }
    }
}

/// One operation as a button: its title and why it does not apply now.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SandboxOperationState {
    /// The operation.
    pub operation: SandboxOperation,
    /// The button's title in the current phase.
    pub title: String,
    /// What it does.
    pub help: String,
    /// Why it cannot run now; `None` when it can.
    pub unavailable_reason: Option<String>,
    /// It ends running work, so it is confirmed while a turn runs.
    pub is_destructive: bool,
}

/// A session's sandbox, ready to show.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SandboxState {
    /// Where it is in its life.
    pub phase: SandboxPhase,
    /// The launch stage, until the launch is ready.
    pub stage: Option<SandboxLaunchStage>,
    /// The provider's name, for example "Modal Sandbox"; "Sandbox" when unknown.
    pub title: String,
    /// The profile it launched with.
    pub profile: Option<String>,
    /// The state in words.
    pub summary: String,
    /// What happens next without the user, for a sandbox at rest.
    pub hint: Option<String>,
    /// What the user must do, while the launch waits on them.
    pub details: Option<String>,
    /// Why the launch failed.
    pub error: Option<String>,
    /// The host tunnel is up; `None` until reported.
    pub host_online: Option<bool>,
    /// The runner is connected; `None` until reported.
    pub runner_online: Option<bool>,
    /// The supported operations, each with why it does not apply now.
    pub operations: Vec<SandboxOperationState>,
}

impl From<core::SandboxState> for SandboxState {
    fn from(state: core::SandboxState) -> Self {
        Self {
            phase: state.phase.into(),
            stage: state.stage.map(Into::into),
            title: state.title,
            profile: state.profile,
            summary: state.summary,
            hint: state.hint,
            details: state.details,
            error: state.error,
            host_online: state.host_online,
            runner_online: state.runner_online,
            operations: state
                .operations
                .into_iter()
                .map(|operation| SandboxOperationState {
                    operation: operation.operation.into(),
                    title: operation.title,
                    help: operation.help,
                    unavailable_reason: operation.unavailable_reason,
                    is_destructive: operation.is_destructive,
                })
                .collect(),
        }
    }
}

/// The sandbox of a session reporting `signals`; `None` for a session that has none.
#[must_use]
#[uniffi::export]
pub fn sandbox_state(signals: SandboxSignals) -> Option<SandboxState> {
    core::sandbox_state(&signals.into()).map(Into::into)
}

/// A launch stage in words: "Provisioning sandbox", "Cloning repository", "Connecting host",
/// "Starting agent", "Ready" or "Sandbox launch failed".
#[must_use]
#[uniffi::export]
pub fn sandbox_launch_label(stage: SandboxLaunchStage) -> String {
    core::LaunchStage::from(stage).label().to_owned()
}

#[uniffi::export]
impl ClientCore {
    /// Asks the server to wake `session_id`'s sandbox and start its agent, or to stop the
    /// agent: one request, never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the preflight and write errors, the server's refusal with its
    /// reason, and `DeliveryUncertain` when its answer cannot be read.
    pub async fn sandbox_operation(
        &self,
        session_id: String,
        operation: SandboxOperation,
    ) -> Result<SandboxOperationOutcome, CoreError> {
        self.sessions()
            .sandbox_operation(&session_id, operation.into())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}

#[cfg(test)]
#[path = "sandbox_state_tests.rs"]
mod tests;
