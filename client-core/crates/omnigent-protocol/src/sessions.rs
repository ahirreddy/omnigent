//! Session list rows, snapshots, and pages.
//!
//! Ground truth: `SessionListItem`, `SessionList` and `SessionResponse` in
//! `omnigent/server/schemas.py`. There are two models on purpose (divergence D10): a
//! [`SessionListItem`] (REST list and `/v1/sessions/updates` rows) has no snapshot-only fields, so
//! applying a row can never clear `model_override`, `llm_model`, `model_options`,
//! `last_task_error`, `host_resumable` or `pending_elicitations`.
//!
//! Optional fields are [`Field`]s: REST list rows omit `None` values, WebSocket rows send explicit
//! nulls, and older or sparse payloads omit what they do not report.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::content::{self, ContentPart};
use crate::elicitation::ElicitationRequest;
use crate::error::{DecodeError, FromWire, decode_as};
use crate::field::{Field, null_as_default};
use crate::items::ConversationItem;
use crate::page::Page;
use crate::wire_enum::wire_enum;

wire_enum! {
    /// Session lifecycle status (`SessionResponse.status`, `session.status`).
    pub enum SessionStatus {
        /// `idle`.
        Idle = "idle",
        /// `launching` (stream only; list and snapshot status omit it).
        Launching = "launching",
        /// `running`.
        Running = "running",
        /// `waiting`: background work is still running. Not idle.
        Waiting = "waiting",
        /// `failed`.
        Failed = "failed",
    }
}

impl SessionStatus {
    /// True while a turn or background work is in progress.
    #[must_use]
    pub const fn is_busy(&self) -> bool {
        matches!(self, Self::Launching | Self::Running | Self::Waiting)
    }
}

wire_enum! {
    /// Managed-sandbox launch stage (`SandboxLaunchStage`).
    pub enum SandboxStage {
        /// `provisioning`.
        Provisioning = "provisioning",
        /// `action_required`.
        ActionRequired = "action_required",
        /// `cloning`.
        Cloning = "cloning",
        /// `starting`.
        Starting = "starting",
        /// `connecting`.
        Connecting = "connecting",
        /// `ready`.
        Ready = "ready",
        /// `failed`.
        Failed = "failed",
    }
}

wire_enum! {
    /// Per-MCP-server startup state.
    pub enum McpStartupStatus {
        /// `starting`.
        Starting = "starting",
        /// `ready`.
        Ready = "ready",
        /// `failed`.
        Failed = "failed",
        /// `cancelled`.
        Cancelled = "cancelled",
    }
}

/// Server failure details (`ErrorDetail`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorDetail {
    /// Stable classifier.
    pub code: String,
    /// Human-readable message.
    pub message: String,
    /// Short headline.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Why it failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cause: Option<String>,
    /// A concrete next step.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remediation: Option<String>,
    /// The failed input was not delivered.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub undelivered: Option<bool>,
}

/// Cumulative usage for one model (`ModelUsage`). Every count is optional.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ModelUsage {
    /// Input tokens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_tokens: Option<u64>,
    /// Output tokens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_tokens: Option<u64>,
    /// Total tokens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_tokens: Option<u64>,
    /// Cache-read input tokens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read_input_tokens: Option<u64>,
    /// Cache-creation input tokens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_creation_input_tokens: Option<u64>,
    /// Cost in USD.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_cost_usd: Option<f64>,
}

/// One still-running background shell (`BackgroundTaskInfo`). Every field is best effort.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BackgroundTaskInfo {
    /// Task id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// Task type.
    #[serde(default, rename = "type", skip_serializing_if = "Option::is_none")]
    pub task_type: Option<String>,
    /// Task status.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    /// Description.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Command line.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
}

/// Managed-sandbox launch progress (`SandboxStatus`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SandboxStatus {
    /// Launch stage.
    pub stage: SandboxStage,
    /// Failure message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Sandbox provider.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    /// Extra detail.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
}

/// One MCP server's startup state (`McpServerStartup`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct McpServerStartup {
    /// Startup state.
    pub status: McpStartupStatus,
    /// Failure message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// A reasoning effort a native model supports.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReasoningEffortOption {
    /// The effort value, for example `high`.
    #[serde(rename = "reasoningEffort")]
    pub reasoning_effort: String,
    /// Description.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// One runner-owned native model-picker row (`NativeModelOption`, extra fields allowed).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NativeModelOption {
    /// Model id.
    pub id: String,
    /// Provider model name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Display name; fall back to `id`.
    #[serde(
        default,
        rename = "displayName",
        skip_serializing_if = "Option::is_none"
    )]
    pub display_name: Option<String>,
    /// Default reasoning effort.
    #[serde(
        default,
        rename = "defaultReasoningEffort",
        skip_serializing_if = "Option::is_none"
    )]
    pub default_reasoning_effort: Option<String>,
    /// Supported reasoning efforts.
    #[serde(
        default,
        rename = "supportedReasoningEfforts",
        deserialize_with = "null_as_default"
    )]
    pub supported_reasoning_efforts: Vec<ReasoningEffortOption>,
    /// The default model.
    #[serde(default, rename = "isDefault", skip_serializing_if = "Option::is_none")]
    pub is_default: Option<bool>,
    /// Hidden from the picker.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hidden: Option<bool>,
    /// Other provider fields.
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

/// A linked pull request (`SessionPullRequestSummary`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PullRequestSummary {
    /// PR URL.
    pub url: String,
    /// Provider id, for example `github`.
    pub provider: String,
    /// Repository.
    pub repository: String,
    /// PR number.
    pub number: u64,
    /// Title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// State, for example `open`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    /// Draft PR.
    #[serde(default, deserialize_with = "null_as_default")]
    pub is_draft: bool,
    /// Provider display labels.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_display: Option<BTreeMap<String, String>>,
    /// When the state was last checked (Unix seconds).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state_checked_at: Option<f64>,
}

/// A message accepted but not yet consumed (`pending_inputs`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingInput {
    /// Correlates with the POST acknowledgement and `cleared_pending_id`.
    pub pending_id: String,
    /// Content blocks.
    #[serde(deserialize_with = "content::content_parts")]
    pub content: Vec<ContentPart>,
    /// The sender, when recorded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_by: Option<String>,
}

/// The caller's permission level on a session (`permission_level`): 1 view and pin, 2 edit and
/// rename, 4 owner. Unknown means read-only (fail closed).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SessionPermissions {
    /// The level as sent.
    pub level: Option<i64>,
}

impl SessionPermissions {
    /// Below edit level.
    #[must_use]
    pub const fn is_read_only(self) -> bool {
        !self.can_rename()
    }

    /// Level 1 or above.
    #[must_use]
    pub const fn can_pin(self) -> bool {
        matches!(self.level, Some(level) if level >= 1)
    }

    /// Level 2 or above.
    #[must_use]
    pub const fn can_rename(self) -> bool {
        matches!(self.level, Some(level) if level >= 2)
    }

    /// Owner level (4) or above.
    #[must_use]
    pub const fn can_archive(self) -> bool {
        matches!(self.level, Some(level) if level >= 4)
    }
}

/// The failure text shown when a failed session has no `last_task_error` message.
pub const DEFAULT_FAILURE_MESSAGE: &str =
    "The last response failed. Check the server or provider sign-in.";

/// One row of `GET /v1/sessions` or of a `/v1/sessions/updates` frame (`SessionListItem`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionListItem {
    /// Session id. Never empty.
    pub id: String,
    /// Bound agent id.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub agent_id: Field<String>,
    /// Bound agent name.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub agent_name: Field<String>,
    /// Canonical harness.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub harness: Field<String>,
    /// Lifecycle status.
    pub status: SessionStatus,
    /// Unix seconds.
    pub created_at: i64,
    /// Unix seconds.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub updated_at: Field<i64>,
    /// Title.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub title: Field<String>,
    /// Session labels.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub labels: Field<BTreeMap<String, String>>,
    /// Bound runner.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub runner_id: Field<String>,
    /// Launching host.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub host_id: Field<String>,
    /// Runner liveness.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub runner_online: Field<bool>,
    /// Host tunnel liveness.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub host_online: Field<bool>,
    /// Reasoning-effort hint.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub reasoning_effort: Field<String>,
    /// The caller's permission level.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub permission_level: Field<i64>,
    /// Owner identity.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub owner: Field<String>,
    /// Runtime-native session id.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub external_session_id: Field<String>,
    /// Outstanding approval prompts.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub pending_elicitations_count: Field<u64>,
    /// Workspace path.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub workspace: Field<String>,
    /// Git branch.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub git_branch: Field<String>,
    /// Archived.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub archived: Field<bool>,
    /// Comment count.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub comments_count: Field<u64>,
    /// Last comment time.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub comments_updated_at: Field<i64>,
    /// When the caller last viewed the session.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub viewer_last_seen: Field<i64>,
    /// Unread for the caller.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub viewer_unread: Field<bool>,
    /// Search excerpt (list search only).
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub search_snippet: Field<String>,
    /// Parent of a sub-agent session.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub parent_session_id: Field<String>,
    /// Project.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub project_id: Field<String>,
    /// Linked pull request.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub pull_request: Field<PullRequestSummary>,
    /// PR state synced.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub pull_requests_synced: Field<bool>,
}

/// `GET /v1/sessions` (`SessionList`).
pub type SessionList = Page<SessionListItem>;

/// `GET /v1/sessions/{id}/items`.
pub type ItemPage = Page<ConversationItem>;

/// `GET /v1/sessions/{id}` (`SessionResponse`): the snapshot used for hydration and reconnect.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionSnapshot {
    /// Session id. Never empty.
    pub id: String,
    /// Bound agent id.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub agent_id: Field<String>,
    /// Bound agent name.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub agent_name: Field<String>,
    /// Lifecycle status.
    pub status: SessionStatus,
    /// Running background shells.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub background_task_count: Field<u64>,
    /// Running background shell details.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub background_tasks: Field<Vec<BackgroundTaskInfo>>,
    /// Unix seconds.
    pub created_at: i64,
    /// Unix seconds.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub updated_at: Field<i64>,
    /// Title.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub title: Field<String>,
    /// Session labels.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub labels: Field<BTreeMap<String, String>>,
    /// Bound runner.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub runner_id: Field<String>,
    /// Launching host.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub host_id: Field<String>,
    /// Runner liveness.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub runner_online: Field<bool>,
    /// Host tunnel liveness.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub host_online: Field<bool>,
    /// A dormant host can be woken.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub host_resumable: Field<bool>,
    /// Reasoning-effort hint.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub reasoning_effort: Field<String>,
    /// Committed items, oldest first (empty with `include_items=false`).
    #[serde(default, deserialize_with = "null_as_default")]
    pub items: Vec<ConversationItem>,
    /// The caller's permission level.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub permission_level: Field<i64>,
    /// Sub-agent name.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub sub_agent_name: Field<String>,
    /// `default` or `sub_agent`.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub kind: Field<String>,
    /// Parent of a sub-agent session.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub parent_session_id: Field<String>,
    /// Spawn-tree root.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub root_conversation_id: Field<String>,
    /// The model the session is actually on.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub llm_model: Field<String>,
    /// Canonical harness.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub harness: Field<String>,
    /// Per-session model override.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub model_override: Field<String>,
    /// Cost-control mode override.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub cost_control_mode_override: Field<String>,
    /// Subagent-routing override.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub subagent_routing_override: Field<String>,
    /// Owner shares workspace files.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub share_workspace_files: Field<bool>,
    /// Context window in tokens.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub context_window: Field<u64>,
    /// Last turn's total tokens.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub last_total_tokens: Field<u64>,
    /// Cumulative cost in USD.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub total_cost_usd: Field<f64>,
    /// Per-model usage.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub usage_by_model: Field<BTreeMap<String, ModelUsage>>,
    /// False when usage aggregation was skipped.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub usage_included: Field<bool>,
    /// The most recent task error (`code`, `message`, `title`, `cause`, `remediation`, ...).
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub last_task_error: Field<BTreeMap<String, String>>,
    /// Runtime-native session id.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub external_session_id: Field<String>,
    /// Native terminal launch args.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub terminal_launch_args: Field<Vec<String>>,
    /// Outstanding approval prompts, as the stream would have sent them.
    #[serde(default, deserialize_with = "null_as_default")]
    pub pending_elicitations: Vec<ElicitationRequest>,
    /// Accepted messages awaiting consumption.
    #[serde(default, deserialize_with = "null_as_default")]
    pub pending_inputs: Vec<PendingInput>,
    /// Workspace path.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub workspace: Field<String>,
    /// Git branch.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub git_branch: Field<String>,
    /// Archived.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub archived: Field<bool>,
    /// Native plan items, as sent.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub todos: Field<Vec<Value>>,
    /// Native model-picker rows. Absent keeps the known list; `[]` clears it.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub model_options: Field<Vec<NativeModelOption>>,
    /// Inference is configured.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub inference_configured: Field<bool>,
    /// Inference configuration error.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub inference_error: Field<String>,
    /// The runner is auto-creating a terminal.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub terminal_pending: Field<bool>,
    /// Managed sandbox profile, as sent.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub sandbox_profile: Field<Value>,
    /// Managed sandbox launch progress.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub sandbox_status: Field<SandboxStatus>,
    /// MCP server startup states.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub mcp_startup: Field<BTreeMap<String, McpServerStartup>>,
    /// The in-flight turn's response id.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub active_response_id: Field<String>,
    /// Project.
    #[serde(default, skip_serializing_if = "Field::is_absent")]
    pub project_id: Field<String>,
}

impl SessionListItem {
    /// The caller's capabilities.
    #[must_use]
    pub const fn permissions(&self) -> SessionPermissions {
        SessionPermissions {
            level: self.permission_level.value().copied(),
        }
    }
}

impl SessionSnapshot {
    /// The caller's capabilities.
    #[must_use]
    pub const fn permissions(&self) -> SessionPermissions {
        SessionPermissions {
            level: self.permission_level.value().copied(),
        }
    }

    /// For a failed session, `last_task_error.message` or [`DEFAULT_FAILURE_MESSAGE`].
    #[must_use]
    pub fn failure_message(&self) -> Option<&str> {
        if self.status != SessionStatus::Failed {
            return None;
        }
        Some(
            self.last_task_error
                .value()
                .and_then(|error| error.get("message"))
                .map(String::as_str)
                .filter(|message| !message.trim().is_empty())
                .unwrap_or(DEFAULT_FAILURE_MESSAGE),
        )
    }
}

fn require_id(id: &str, context: &str) -> Result<(), DecodeError> {
    if id.is_empty() {
        return Err(DecodeError::missing(context, "id"));
    }
    Ok(())
}

impl FromWire for SessionListItem {
    fn from_value(value: Value) -> Result<Self, DecodeError> {
        if !value.is_object() {
            return Err(DecodeError::NotAnObject {
                context: "session row".to_owned(),
            });
        }
        let row: Self = decode_as(value, || "session row".to_owned())?;
        require_id(&row.id, "session row")?;
        Ok(row)
    }
}

impl FromWire for SessionSnapshot {
    fn from_value(value: Value) -> Result<Self, DecodeError> {
        if !value.is_object() {
            return Err(DecodeError::NotAnObject {
                context: "session".to_owned(),
            });
        }
        let snapshot: Self = decode_as(value, || "session".to_owned())?;
        require_id(&snapshot.id, "session")?;
        Ok(snapshot)
    }
}

#[cfg(test)]
#[path = "sessions_tests.rs"]
mod tests;
