//! A session's managed sandbox as a client shows it: its launch, then whether it is up, and
//! what can be asked of it (the web's `sandboxStatus.ts`, `useSessionLiveness` and `HostBadge`).
//!
//! The server reports a launch by stage until it is `ready`, then only the host's and the
//! runner's liveness. It has two requests for a sandbox session: `retry_session`, which wakes
//! or relaunches it, and `stop_session`, which ends the agent's process.

use omnigent_protocol::sessions::{SandboxStage, SandboxStatus};
use serde_json::{Map, Value};

use crate::client::json::{as_object, opt_str, put_opt, req_str};
use crate::session_environment::sandbox_label;

/// A stage of a sandbox launch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LaunchStage {
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

impl LaunchStage {
    /// The stage of a wire value; `None` for a stage this client does not know.
    #[must_use]
    pub const fn of(stage: &SandboxStage) -> Option<Self> {
        match stage {
            SandboxStage::Provisioning => Some(Self::Provisioning),
            SandboxStage::ActionRequired => Some(Self::ActionRequired),
            SandboxStage::Cloning => Some(Self::Cloning),
            SandboxStage::Starting => Some(Self::Starting),
            SandboxStage::Connecting => Some(Self::Connecting),
            SandboxStage::Ready => Some(Self::Ready),
            SandboxStage::Failed => Some(Self::Failed),
            SandboxStage::Unknown { .. } => None,
        }
    }

    /// The wire value.
    #[must_use]
    pub const fn wire(self) -> &'static str {
        match self {
            Self::Provisioning => "provisioning",
            Self::ActionRequired => "action_required",
            Self::Cloning => "cloning",
            Self::Starting => "starting",
            Self::Connecting => "connecting",
            Self::Ready => "ready",
            Self::Failed => "failed",
        }
    }

    /// The stage in the web's words. `starting` is the host dialing back ("Connecting host")
    /// and `connecting` the runner being launched on it ("Starting agent").
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Provisioning | Self::ActionRequired => "Provisioning sandbox",
            Self::Cloning => "Cloning repository",
            Self::Starting => "Connecting host",
            Self::Connecting => "Starting agent",
            Self::Ready => "Ready",
            Self::Failed => "Sandbox launch failed",
        }
    }

    /// The launch is making progress: it is not over and does not wait on the user.
    #[must_use]
    pub const fn is_in_progress(self) -> bool {
        !matches!(self, Self::Failed | Self::ActionRequired | Self::Ready)
    }
}

/// A sandbox launch as the server last reported it. One that is [`LaunchStage::Ready`] still
/// says the session runs in a sandbox, and which provider's.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SandboxLaunch {
    /// The stage.
    pub stage: LaunchStage,
    /// The provider being launched, for example `arclet`.
    pub provider: Option<String>,
    /// What the user must do, when the stage is [`LaunchStage::ActionRequired`].
    pub details: Option<String>,
    /// Why it failed, when the stage is [`LaunchStage::Failed`].
    pub error: Option<String>,
}

impl SandboxLaunch {
    /// The launch a status reports; `None` for a stage this client does not know.
    #[must_use]
    pub fn of(status: &SandboxStatus) -> Option<Self> {
        Some(Self {
            stage: LaunchStage::of(&status.stage)?,
            provider: status.provider.clone(),
            details: status.details.clone(),
            error: status.error.clone(),
        })
    }

    /// The launch while it is under way, waits on the user or failed; `None` once it is ready.
    #[must_use]
    pub fn unfinished(self) -> Option<Self> {
        (self.stage != LaunchStage::Ready).then_some(self)
    }

    /// The launch as saved with a session's configuration.
    #[must_use]
    pub fn to_value(&self) -> Value {
        let mut object = Map::new();
        object.insert("stage".into(), Value::String(self.stage.wire().to_owned()));
        let string = |value: &Option<String>| value.clone().map(Value::String);
        put_opt(&mut object, "provider", string(&self.provider));
        put_opt(&mut object, "details", string(&self.details));
        put_opt(&mut object, "error", string(&self.error));
        Value::Object(object)
    }

    /// Decodes [`Self::to_value`]'s encoding; `None` for a stage this client does not know.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Option<Self>, String> {
        let object = as_object(value, "sandbox launch")?;
        let Some(stage) = LaunchStage::of(&SandboxStage::parse(&req_str(object, "stage")?)) else {
            return Ok(None);
        };
        Ok(Some(Self {
            stage,
            provider: opt_str(object, "provider")?,
            details: opt_str(object, "details")?,
            error: opt_str(object, "error")?,
        }))
    }
}

/// The profile a sandbox launched with, as the session names it (`sandbox_profile`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SandboxProfileName {
    /// The profile's provider.
    pub provider: String,
    /// Its display name.
    pub name: String,
}

impl SandboxProfileName {
    /// The session's profile; `None` when it reports none or one without a name.
    #[must_use]
    pub fn of(profile: &Value) -> Option<Self> {
        let text = |key: &str| {
            profile
                .get(key)
                .and_then(Value::as_str)
                .filter(|text| !text.is_empty())
                .map(str::to_owned)
        };
        Some(Self {
            provider: text("provider")?,
            name: text("name")?,
        })
    }
}

/// What a session reports about its sandbox.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
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

/// Where a sandbox is in its life.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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

/// Something a client can ask of a sandbox session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SandboxOperation {
    /// Wake the sandbox, or relaunch it, and start its agent (`retry_session`).
    Wake,
    /// End the agent's process (`stop_session`); the sandbox sleeps on its own when idle.
    Stop,
}

/// One operation as a button: its title and why it does not apply now.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
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
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SandboxState {
    /// Where it is in its life.
    pub phase: SandboxPhase,
    /// The launch stage, until the launch is ready.
    pub stage: Option<LaunchStage>,
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

/// Shown for an operation the viewer may not ask for.
pub const VIEW_ONLY_REASON: &str = "You can view this session but not change it.";
/// Shown for Stop to someone who does not own the session.
pub const OWNER_ONLY_REASON: &str = "Only the session\u{2019}s owner can stop its agent.";

impl SandboxSignals {
    fn has_host(&self) -> bool {
        self.host_id.as_deref().is_some_and(|id| !id.is_empty())
    }

    /// Whether the session runs in a managed sandbox at all.
    fn is_sandboxed(&self) -> bool {
        self.launch.is_some()
            || self.profile.is_some()
            || self.host_sandbox.is_some()
            || (self.has_host() && self.host_resumable == Some(true))
    }

    /// The launch, unless it is ready.
    fn unfinished_launch(&self) -> Option<&SandboxLaunch> {
        self.launch
            .as_ref()
            .filter(|launch| launch.stage != LaunchStage::Ready)
    }

    /// The provider's name: the launch's or the profile's provider, else the host list's name.
    fn title(&self) -> String {
        let named = |text: &&str| !text.is_empty();
        let launched = self
            .launch
            .as_ref()
            .and_then(|launch| launch.provider.as_deref())
            .filter(named);
        let profiled = self
            .profile
            .as_ref()
            .map(|profile| profile.provider.as_str())
            .filter(named);
        if let Some(provider) = launched.or(profiled) {
            return sandbox_label(Some(provider));
        }
        self.host_sandbox
            .as_deref()
            .filter(named)
            .unwrap_or("Sandbox")
            .to_owned()
    }

    fn phase(&self) -> SandboxPhase {
        if let Some(launch) = self.unfinished_launch() {
            return match launch.stage {
                LaunchStage::Failed => SandboxPhase::Failed,
                LaunchStage::ActionRequired => SandboxPhase::ActionRequired,
                _ => SandboxPhase::Launching,
            };
        }
        if self.runner_online == Some(true) {
            return SandboxPhase::Running;
        }
        if !self.has_host() {
            return SandboxPhase::Offline;
        }
        match self.host_online {
            None => SandboxPhase::Unknown,
            Some(_) if self.turn_active => SandboxPhase::Waking,
            Some(true) => SandboxPhase::AgentAsleep,
            Some(false) if self.host_resumable == Some(true) => SandboxPhase::Asleep,
            Some(false) => SandboxPhase::Offline,
        }
    }

    fn wake(&self, phase: SandboxPhase) -> SandboxOperationState {
        let title = match phase {
            SandboxPhase::Failed => "Retry Launch",
            SandboxPhase::Offline => "Launch Again",
            SandboxPhase::AgentAsleep => "Start Agent",
            _ => "Wake",
        };
        let unavailable = match phase {
            _ if !self.can_edit => Some(VIEW_ONLY_REASON),
            SandboxPhase::Launching | SandboxPhase::ActionRequired => {
                Some("The sandbox is already launching.")
            }
            SandboxPhase::Waking => Some("The sandbox is already waking."),
            SandboxPhase::Running => Some("The sandbox is already running."),
            SandboxPhase::Unknown => Some("The server has not reported this sandbox yet."),
            _ if !self.has_host() => {
                Some("This session has no sandbox to start. Create a new session instead.")
            }
            _ => None,
        };
        SandboxOperationState {
            operation: SandboxOperation::Wake,
            title: title.to_owned(),
            help: "Brings the sandbox and its agent back, as the next message would.".to_owned(),
            unavailable_reason: unavailable.map(str::to_owned),
            is_destructive: false,
        }
    }

    fn stop(&self, phase: SandboxPhase) -> SandboxOperationState {
        let unavailable = match phase {
            _ if !self.is_owner => Some(OWNER_ONLY_REASON),
            SandboxPhase::Running => None,
            SandboxPhase::Launching | SandboxPhase::ActionRequired | SandboxPhase::Waking => {
                Some("The agent has not started yet.")
            }
            _ => Some("The agent is not running."),
        };
        SandboxOperationState {
            operation: SandboxOperation::Stop,
            title: "Stop Agent".to_owned(),
            help: "Ends the agent\u{2019}s process. The sandbox sleeps on its own when idle."
                .to_owned(),
            unavailable_reason: unavailable.map(str::to_owned),
            is_destructive: true,
        }
    }
}

/// The sandbox of a session reporting `signals`; `None` for a session that has none.
#[must_use]
pub fn sandbox_state(signals: &SandboxSignals) -> Option<SandboxState> {
    if !signals.is_sandboxed() {
        return None;
    }
    let phase = signals.phase();
    let launch = signals.unfinished_launch();
    let stage = launch.map(|launch| launch.stage);
    let summary = match (phase, stage) {
        (_, Some(stage)) => stage.label(),
        (SandboxPhase::Running, _) => "Running",
        (SandboxPhase::Waking, _) => "Waking",
        (SandboxPhase::AgentAsleep, _) => "Agent asleep",
        (SandboxPhase::Asleep, _) => "Asleep",
        (SandboxPhase::Unknown, _) => "Not reported yet",
        _ => "Offline",
    };
    let hint = match phase {
        SandboxPhase::AgentAsleep => Some("The next message starts the agent."),
        SandboxPhase::Asleep => Some("The next message wakes it."),
        SandboxPhase::Offline if signals.has_host() => {
            Some("The next message launches a new sandbox.")
        }
        _ => None,
    };
    Some(SandboxState {
        phase,
        stage,
        title: signals.title(),
        profile: signals.profile.as_ref().map(|profile| profile.name.clone()),
        summary: summary.to_owned(),
        hint: hint.map(str::to_owned),
        details: launch
            .filter(|launch| launch.stage == LaunchStage::ActionRequired)
            .and_then(|launch| launch.details.clone()),
        error: launch
            .filter(|launch| launch.stage == LaunchStage::Failed)
            .and_then(|launch| launch.error.clone()),
        host_online: signals.host_online,
        runner_online: signals.runner_online,
        operations: vec![signals.wake(phase), signals.stop(phase)],
    })
}

#[cfg(test)]
#[path = "sandbox_state_tests.rs"]
mod tests;
