//! Forking a session ("Fork from here", "Clone & start").
//!
//! `POST /v1/sessions/{id}/fork`, optionally truncated after one response, then optionally
//! `POST /v1/hosts/{host_id}/runners` to start the copy in a directory on a host.
//!
//! The fork `POST` is not idempotent: a 4xx is a definite rejection, while a lost connection, a
//! 5xx or an acknowledgement without a usable id is [`SessionError::DeliveryUncertain`] (the
//! fork may exist) and is never retried. Once the fork exists the result is `Ok`; a failed
//! runner launch is reported in [`ForkedSession::launch`], so the caller opens the fork and
//! shows the launch error instead of forking again.
//!
//! [`fork_plan`] derives the fork sheet's choices from the source session and the creation
//! catalog, mirroring the web's `ForkSessionDialog`: the source's own agent first, then the
//! catalog agents whose harness keeps the copied history (`forkTargetCarriesHistory`).

use serde_json::{Map, Value};

use super::json::{as_object, opt_str};
use super::requests::validate_identifier;
use super::sessions::{SessionSummary, decode_snapshot_value};
use super::{ClientCore, ClientEvent, SessionError, lock};
use crate::attachments::policy::is_identifier;
use crate::config::session::canonical_harness;
use crate::creation::{
    CreationAgent, CreationCatalog, CreationError, CreationHost, CreationReceipt, MAX_TITLE_CHARS,
};
use crate::http::HttpTransport;

/// Native harnesses whose runner rebuilds a resumable transcript from the copied items. Mirrors
/// the server's `_FORK_HISTORY_NATIVE_HARNESSES`.
const NATIVE_REBUILD_HARNESSES: [&str; 5] = [
    "claude-native",
    "codex-native",
    "pi-native",
    "hermes-native",
    "qwen-native",
];

/// Native harnesses that replay the copied history as a preamble on the first message.
const PREAMBLE_HARNESSES: [&str; 3] = ["cursor-native", "devin-native", "opencode-native"];

/// Harnesses with a known provider family, which replay the transcript as model context.
const FAMILY_HARNESSES: [&str; 6] = [
    "claude-sdk",
    "codex",
    "openai-agents",
    "antigravity",
    "antigravity-native",
    "claude-native",
];

/// Where to start a fork: a directory on a host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForkStart {
    /// The host.
    pub host_id: String,
    /// Absolute directory on the host.
    pub workspace: String,
}

/// What to fork.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
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
}

/// How starting the fork went.
#[derive(Debug, Clone, PartialEq)]
pub enum RunnerLaunch {
    /// No start was asked for; the fork is unbound.
    NotRequested,
    /// The host accepted the launch.
    Launched {
        /// The runner the host is starting.
        runner_id: String,
    },
    /// The launch failed or its outcome is unknown. The fork exists: open it, never fork again.
    Failed(SessionError),
}

/// A created fork and its launch.
#[derive(Debug, Clone, PartialEq)]
pub struct ForkedSession {
    /// The fork's acknowledgement.
    pub receipt: CreationReceipt,
    /// The runner launch's outcome.
    pub launch: RunnerLaunch,
}

/// The fork sheet's choices for one source session.
#[derive(Debug, Clone, PartialEq, Eq)]
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
}

/// Whether forking into `harness` keeps the source's history. Unknown harnesses do not.
#[must_use]
pub fn fork_target_carries_history(harness: Option<&str>) -> bool {
    if harness.is_none_or(str::is_empty) {
        return false;
    }
    let canonical = canonical_harness(harness);
    NATIVE_REBUILD_HARNESSES.contains(&canonical.as_str())
        || PREAMBLE_HARNESSES.contains(&canonical.as_str())
        || FAMILY_HARNESSES.contains(&canonical.as_str())
}

/// `name` without any chain of ` (fork <id>)` / ` (switch <id>)` clone suffixes.
#[must_use]
pub fn agent_root_name(name: &str) -> &str {
    let mut current = name;
    while let Some((base, inner)) = current
        .strip_suffix(')')
        .and_then(|stripped| stripped.rsplit_once(" ("))
    {
        let is_clone = ["fork ", "switch "].iter().any(|prefix| {
            inner
                .strip_prefix(prefix)
                .is_some_and(|id| !id.is_empty() && !id.contains(')'))
        });
        if !is_clone {
            break;
        }
        current = base;
    }
    current
}

/// Why `source` cannot be forked from this app, or `None` when it can.
#[must_use]
pub fn fork_unavailable_reason(source: &SessionSummary) -> Option<String> {
    if source.is_read_only {
        return Some("You have read-only access to this session.".to_owned());
    }
    let bound = source
        .configuration
        .as_ref()
        .and_then(|configuration| configuration.agent_id.as_deref())
        .is_some_and(|id| !id.is_empty());
    (!bound).then(|| "This session has no agent to fork.".to_owned())
}

/// The fork sheet's choices for `source`, with the `catalog` when it loaded.
#[must_use]
pub fn fork_plan(source: &SessionSummary, catalog: Option<&CreationCatalog>) -> ForkPlan {
    let configuration = source.configuration.as_ref();
    let source_agent_id = configuration
        .and_then(|configuration| configuration.agent_id.clone())
        .unwrap_or_default();
    let root = agent_root_name(&source.agent_name);
    let mut agents = vec![CreationAgent {
        id: source_agent_id.clone(),
        name: format!("{root} (same as original)"),
        harness: configuration.and_then(|configuration| configuration.harness.clone()),
        description: None,
    }];
    if let Some(catalog) = catalog {
        agents.extend(
            catalog
                .agents
                .iter()
                .filter(|agent| {
                    agent.id != source_agent_id
                        && agent_root_name(&agent.name) != root
                        && fork_target_carries_history(agent.harness.as_deref())
                })
                .cloned(),
        );
    }
    let workspace = source.workspace.trim();
    let host_id = configuration.and_then(|configuration| configuration.host_id.clone());
    let start_unavailable_reason = start_unavailable_reason(host_id.as_deref(), catalog);
    ForkPlan {
        agents,
        agent_id: source_agent_id,
        directory: if workspace.starts_with('/') {
            workspace.to_owned()
        } else {
            String::new()
        },
        host_id,
        start_unavailable_reason,
    }
}

fn start_unavailable_reason(
    host_id: Option<&str>,
    catalog: Option<&CreationCatalog>,
) -> Option<String> {
    let Some(host_id) = host_id.filter(|id| !id.is_empty()) else {
        return Some("The original session has no host to start the copy on.".to_owned());
    };
    let Some(catalog) = catalog else {
        return Some("The host list has not loaded.".to_owned());
    };
    host_unavailable_reason(catalog.hosts.iter().find(|host| host.host_id == host_id))
}

fn host_unavailable_reason(host: Option<&CreationHost>) -> Option<String> {
    let reason = |text: &str| Some(text.to_owned());
    let Some(host) = host else {
        return reason("The original session's host is no longer registered.");
    };
    if host.sandbox_provider.is_some() {
        return reason("Starting a copy on a managed sandbox is not available here.");
    }
    if host.status != "online" {
        return reason("Connect this host before starting the copy.");
    }
    None
}

/// The `POST /v1/sessions/{id}/fork` body.
fn fork_body(request: &ForkRequest) -> Value {
    let mut body = Map::new();
    if let Some(title) = request
        .title
        .as_deref()
        .map(str::trim)
        .filter(|t| !t.is_empty())
    {
        body.insert("title".into(), Value::String(title.to_owned()));
    }
    if let Some(agent_id) = &request.agent_id {
        body.insert("agent_id".into(), Value::String(agent_id.clone()));
    }
    if let Some(response_id) = &request.up_to_response_id {
        body.insert(
            "up_to_response_id".into(),
            Value::String(response_id.clone()),
        );
    }
    Value::Object(body)
}

fn validate_request(request: &ForkRequest) -> Result<(), SessionError> {
    validate_identifier(&request.source_id)?;
    for id in [&request.up_to_response_id, &request.agent_id]
        .into_iter()
        .flatten()
    {
        validate_identifier(id)?;
    }
    if request
        .title
        .as_deref()
        .is_some_and(|title| title.trim().chars().count() > MAX_TITLE_CHARS)
    {
        return Err(SessionError::InvalidTitle);
    }
    if let Some(start) = &request.start {
        validate_identifier(&start.host_id)?;
        let path = start.workspace.trim();
        if !path.starts_with('/') || path.contains('\0') {
            return Err(CreationError::Unavailable(
                "Enter an absolute workspace path beginning with /.".to_owned(),
            )
            .into());
        }
    }
    Ok(())
}

impl<T: HttpTransport> ClientCore<T> {
    /// Forks `request.source_id`, then starts the fork when `request.start` is set. A start is
    /// checked against a fresh host list first, so an offline host forks nothing.
    ///
    /// # Errors
    ///
    /// Before any write: [`SessionError::InvalidIdentifier`], [`SessionError::InvalidTitle`],
    /// and [`CreationError::Unavailable`] for a start path that is not absolute or a host that
    /// is unknown, a sandbox or offline (with the host read errors). The fork `POST`:
    /// [`SessionError::Rejected`] (nothing was created), [`SessionError::Forbidden`],
    /// [`SessionError::Unauthorized`] (the connection ends), and
    /// [`SessionError::DeliveryUncertain`] when the fork may exist. A failed launch is
    /// [`RunnerLaunch::Failed`], not an error.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn fork_session(&self, request: &ForkRequest) -> Result<ForkedSession, SessionError> {
        let result = self.fork(request).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn fork(&self, request: &ForkRequest) -> Result<ForkedSession, SessionError> {
        validate_request(request)?;
        if let Some(start) = &request.start {
            let hosts = self
                .host_rows()
                .await?
                .iter()
                .map(CreationHost::from_value)
                .collect::<Result<Vec<_>, String>>()
                .map_err(|detail| SessionError::MalformedResponse { detail })?;
            let host = hosts.iter().find(|host| host.host_id == start.host_id);
            if let Some(reason) = host_unavailable_reason(host) {
                return Err(CreationError::Unavailable(reason).into());
            }
        }
        let path = format!("/v1/sessions/{}/fork", request.source_id);
        let acknowledgement = self.write_json("POST", &path, &fork_body(request)).await?;
        let receipt = self.accept_fork(acknowledgement)?;
        let launch = match &request.start {
            None => RunnerLaunch::NotRequested,
            Some(start) => match self.launch_runner(start, &receipt.session_id).await {
                Ok(runner_id) => RunnerLaunch::Launched { runner_id },
                Err(error) => RunnerLaunch::Failed(error),
            },
        };
        Ok(ForkedSession { receipt, launch })
    }

    /// Records the fork's snapshot. An acknowledgement without a usable id is uncertain.
    fn accept_fork(&self, acknowledgement: Value) -> Result<CreationReceipt, SessionError> {
        let id = acknowledgement
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| is_identifier(id))
            .map(str::to_owned)
            .ok_or_else(|| SessionError::DeliveryUncertain {
                detail: "the fork acknowledgement has no usable session id".into(),
            })?;
        let mut state = lock(&self.state);
        // The id is the acknowledgement; a snapshot this client cannot read only leaves the
        // summary to the next list refresh, as for a created session.
        let summary = decode_snapshot_value(acknowledgement)
            .ok()
            .and_then(|decoded| {
                let epoch = state.metadata_epoch(&id);
                state.accept_projection(&decoded.projection, epoch).ok()
            });
        if let Some(summary) = &summary {
            state.events.push(ClientEvent::SessionsChanged {
                sessions: vec![summary.clone()],
            });
        }
        state.events.push(ClientEvent::InventoryInvalidated);
        Ok(CreationReceipt {
            session_id: id,
            summary,
        })
    }

    /// `POST /v1/hosts/{host_id}/runners` for `session_id`; returns the runner id.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn launch_runner(
        &self,
        start: &ForkStart,
        session_id: &str,
    ) -> Result<String, SessionError> {
        let mut body = Map::new();
        body.insert("session_id".into(), Value::String(session_id.to_owned()));
        body.insert(
            "workspace".into(),
            Value::String(start.workspace.trim().to_owned()),
        );
        let path = format!("/v1/hosts/{}/runners", start.host_id);
        let acknowledgement = self.write_json("POST", &path, &Value::Object(body)).await;
        lock(&self.state).request_rehydration(session_id);
        let acknowledgement = acknowledgement?;
        let object = as_object(&acknowledgement, "runner launch")
            .map_err(|detail| SessionError::DeliveryUncertain { detail })?;
        opt_str(object, "runner_id")
            .map_err(|detail| SessionError::DeliveryUncertain { detail })?
            .filter(|id| !id.is_empty())
            .ok_or_else(|| SessionError::DeliveryUncertain {
                detail: "the runner launch acknowledgement has no runner id".into(),
            })
    }
}
