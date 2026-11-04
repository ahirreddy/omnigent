//! Forking a session ("Fork from here", "Clone", "Clone & start").
//!
//! The rules are `omnigent_core::fork`'s; the REST calls are the core client's.

use omnigent_core::fork as core;
use omnigent_core::sessions::SessionSummary as CoreSummary;

use crate::client::ClientCore;
use crate::creation::{CreationAgent, CreationCatalog, CreationReceipt};
use crate::errors::CoreError;
use crate::sessions::SessionSummary;

/// Where to start a fork: a directory on a host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ForkStart {
    /// The host.
    pub host_id: String,
    /// Absolute directory on the host.
    pub workspace: String,
    /// A new git worktree branch to start in; `None` starts in the directory itself.
    #[uniffi(default)]
    pub branch: Option<String>,
}

/// A fork onto a new sandbox the server provisions.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ForkSandbox {
    /// The sandbox provider; `None` takes the server's default.
    pub provider: Option<String>,
    /// `<url>[#<branch>]` repositories to clone; `None` inherits the source's.
    pub workspaces: Option<Vec<String>>,
}

/// A host the fork sheet offers.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ForkHost {
    /// Host id.
    pub host_id: String,
    /// Display name.
    pub name: String,
    /// Why the copy cannot start there, or `None` when it can.
    pub unavailable_reason: Option<String>,
}

/// What to fork.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ForkRequest {
    /// The session to copy.
    pub source_id: String,
    /// Copy history up to and including this response; `None` copies all of it.
    pub up_to_response_id: Option<String>,
    /// Agent to bind the fork to; `None` (or the source's own agent) keeps the source's.
    pub agent_id: Option<String>,
    /// Title; blank lets the server derive `Fork of <title>`.
    pub title: Option<String>,
    /// Start the fork on a host; `None` leaves it unbound.
    pub start: Option<ForkStart>,
    /// Fork onto a new sandbox instead of a host; never with `start`.
    #[uniffi(default)]
    pub sandbox: Option<ForkSandbox>,
    /// The fork's model; `None` keeps the source's.
    #[uniffi(default)]
    pub model: Option<String>,
    /// The fork's reasoning effort; `None` keeps the source's.
    #[uniffi(default)]
    pub reasoning_effort: Option<String>,
    /// The approval mode to launch in (a `creation_approval_mode_menu` value of the fork's
    /// agent); `None` keeps the harness default.
    #[uniffi(default)]
    pub approval_mode: Option<String>,
    /// The fork's agent, for the approval mode's launch flags.
    #[uniffi(default)]
    pub agent: Option<CreationAgent>,
}

/// How starting the fork went.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RunnerLaunch {
    /// No start was asked for; the fork is unbound.
    NotRequested,
    /// The host accepted the launch.
    Launched {
        /// The runner the host is starting.
        runner_id: String,
    },
    /// The launch failed or its outcome is unknown. The fork exists: open it, never fork again.
    Failed {
        /// Why.
        error: CoreError,
    },
}

/// A created fork and its launch.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ForkedSession {
    /// The fork's acknowledgement.
    pub receipt: CreationReceipt,
    /// The runner launch's outcome.
    pub launch: RunnerLaunch,
}

/// The fork sheet's choices for one source session.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ForkPlan {
    /// The source's agent first (`<name> (same as original)`), then the switch targets.
    pub agents: Vec<CreationAgent>,
    /// The preselected agent: the source's.
    pub agent_id: String,
    /// The preselected directory: the source's workspace when it is a path, else empty.
    pub directory: String,
    /// The host "Clone & start" launches on.
    pub host_id: Option<String>,
    /// Why "Clone & start" is unavailable, or `None` when it is available.
    pub start_unavailable_reason: Option<String>,
    /// The hosts the copy can start on, the source's first.
    #[uniffi(default)]
    pub hosts: Vec<ForkHost>,
    /// The server can fork onto a new managed sandbox.
    #[uniffi(default)]
    pub offers_sandbox: bool,
}

impl From<ForkRequest> for core::ForkRequest {
    fn from(request: ForkRequest) -> Self {
        Self {
            source_id: request.source_id,
            up_to_response_id: request.up_to_response_id,
            agent_id: request.agent_id,
            title: request.title,
            terminal_launch_args: request.approval_mode.as_deref().and_then(|mode| {
                let agent = omnigent_core::creation::CreationAgent::from(request.agent?);
                omnigent_core::config::approval::launch_approval_args(
                    agent.wrapper().as_deref(),
                    mode,
                )
            }),
            start: request.start.map(|start| core::ForkStart {
                host_id: start.host_id,
                workspace: start.workspace,
                branch: start.branch.filter(|branch| !branch.trim().is_empty()),
            }),
            sandbox: request.sandbox.map(|sandbox| core::ForkSandbox {
                provider: sandbox.provider,
                workspaces: sandbox.workspaces,
            }),
            model: request.model,
            reasoning_effort: request.reasoning_effort,
        }
    }
}

impl From<core::ForkedSession> for ForkedSession {
    fn from(forked: core::ForkedSession) -> Self {
        Self {
            receipt: forked.receipt.into(),
            launch: match forked.launch {
                core::RunnerLaunch::NotRequested => RunnerLaunch::NotRequested,
                core::RunnerLaunch::Launched { runner_id } => RunnerLaunch::Launched { runner_id },
                core::RunnerLaunch::Failed(error) => RunnerLaunch::Failed {
                    error: error.into(),
                },
            },
        }
    }
}

impl From<core::ForkPlan> for ForkPlan {
    fn from(plan: core::ForkPlan) -> Self {
        Self {
            agents: plan.agents.into_iter().map(Into::into).collect(),
            agent_id: plan.agent_id,
            directory: plan.directory,
            host_id: plan.host_id,
            start_unavailable_reason: plan.start_unavailable_reason,
            hosts: plan
                .hosts
                .into_iter()
                .map(|host| ForkHost {
                    host_id: host.host_id,
                    name: host.name,
                    unavailable_reason: host.unavailable_reason,
                })
                .collect(),
            offers_sandbox: plan.offers_sandbox,
        }
    }
}

/// Why `source` cannot be forked from this app (read-only, or no agent bound), or `None`.
#[must_use]
#[uniffi::export]
pub fn fork_unavailable_reason(source: SessionSummary) -> Option<String> {
    core::fork_unavailable_reason(&CoreSummary::from(&source))
}

/// The fork sheet's choices for `source`, with the creation `catalog` when it loaded.
#[must_use]
#[uniffi::export]
pub fn fork_plan(source: SessionSummary, catalog: Option<CreationCatalog>) -> ForkPlan {
    let catalog = catalog.map(omnigent_core::creation::CreationCatalog::from);
    core::fork_plan(&CoreSummary::from(&source), catalog.as_ref()).into()
}

#[uniffi::export]
impl ClientCore {
    /// Forks a session, truncated after `up_to_response_id` when set, then starts it on a host
    /// when `start` is set. Never retried: an unclear outcome is `delivery_uncertain`, and the
    /// fork may exist. Once the fork exists this returns `Ok`; a failed start is
    /// [`RunnerLaunch::Failed`].
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` and `InvalidTitle` before any request; kind
    /// `Creation` for a start path or host that cannot be used (nothing sent); `Rejected`,
    /// `Forbidden`, `Unauthorized` and `DeliveryUncertain` from the fork `POST`; the host read
    /// errors.
    pub async fn fork_session(&self, request: ForkRequest) -> Result<ForkedSession, CoreError> {
        self.sessions()
            .fork_session(&request.into())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}

#[cfg(test)]
mod tests {
    use omnigent_core::config::session::SessionConfiguration as CoreConfiguration;

    use super::*;

    fn source(read_only: bool) -> SessionSummary {
        SessionSummary::from(CoreSummary {
            workspace: "/work/project".into(),
            agent_name: "codex-native-ui".into(),
            is_read_only: read_only,
            configuration: Some(CoreConfiguration {
                agent_id: Some("ag_clone".into()),
                harness: Some("codex-native".into()),
                host_id: Some("host_a".into()),
                ..CoreConfiguration::default()
            }),
            ..CoreSummary::new("conv_src", "Plan", "")
        })
    }

    #[test]
    fn plan_and_gate_cross_the_boundary() {
        let plan = fork_plan(source(false), None);
        assert_eq!(plan.agent_id, "ag_clone");
        assert_eq!(plan.agents[0].name, "codex-native-ui (same as original)");
        assert_eq!(plan.agents[0].harness_label, "Codex");
        assert_eq!(plan.directory, "/work/project");
        assert_eq!(
            plan.start_unavailable_reason.as_deref(),
            Some("The host list has not loaded.")
        );
        assert_eq!(fork_unavailable_reason(source(false)), None);
        assert!(fork_unavailable_reason(source(true)).is_some());
    }

    #[test]
    fn a_failed_launch_keeps_its_error() {
        let forked = ForkedSession::from(core::ForkedSession {
            receipt: omnigent_core::creation::CreationReceipt {
                session_id: "conv_fork".into(),
                summary: None,
            },
            launch: core::RunnerLaunch::Failed(omnigent_core::SessionError::Forbidden),
        });
        assert_eq!(forked.receipt.session_id, "conv_fork");
        assert!(matches!(forked.launch, RunnerLaunch::Failed { .. }));
    }
}
