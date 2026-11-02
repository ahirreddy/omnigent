//! Runner ⇄ host connection messages (design doc section 5.7). The Rust client never speaks
//! these; the models pin the fixtures that the runner and host test against.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::messages::{AttachMode, CreatedBy, Owner};

/// The first frame of a host socket connection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Preamble {
    /// A media attach; the client protocol follows.
    Attach {
        /// Protocol major.
        protocol: u32,
        /// The tab.
        tab_id: String,
        /// The mode the server authorized.
        mode: AttachMode,
    },
    /// Control requests and responses follow.
    Control,
}

/// A control request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlRequest {
    /// Always `request`.
    #[serde(rename = "type")]
    pub message_type: String,
    /// Correlates the response.
    pub id: String,
    /// The operation, for example `tabs.create`.
    pub op: String,
    /// Its arguments.
    pub args: Value,
}

/// A control error.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlError {
    /// `not_found`, `invalid_input`, `unavailable` or `internal`.
    pub code: String,
    /// Detail.
    pub message: String,
}

/// A control response.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlResponse {
    /// Always `response`.
    #[serde(rename = "type")]
    pub message_type: String,
    /// The request's id.
    pub id: String,
    /// Success.
    pub ok: bool,
    /// The result, when `ok`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    /// The error, when not `ok`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<ControlError>,
}

/// A host tab.
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts of the wire record, mirrored one to one"
)]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TabRecord {
    /// Tab id.
    pub id: String,
    /// Owning session.
    pub session_id: String,
    /// URL.
    pub url: String,
    /// Title.
    pub title: String,
    /// Loading.
    pub loading: bool,
    /// Owner.
    pub owner: Owner,
    /// A handoff is pending.
    pub needs_attention: bool,
    /// Profile.
    pub profile: String,
    /// Creator.
    pub created_by: CreatedBy,
    /// CDP target id.
    pub target_id: String,
    /// History back possible.
    pub can_go_back: bool,
    /// History forward possible.
    pub can_go_forward: bool,
}

/// The encoder a host runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EncoderInfo {
    /// Executable path.
    pub path: String,
    /// `x264` or `ffmpeg`.
    pub kind: String,
}

/// `host.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostInfo {
    /// Process id.
    pub pid: u32,
    /// Socket path.
    pub socket: String,
    /// Loopback CDP port.
    pub cdp_port: u16,
    /// Host version.
    pub version: String,
    /// Profile.
    pub profile: String,
    /// RFC 3339 UTC start time.
    pub started_at: String,
    /// The encoder.
    pub encoder: EncoderInfo,
}
