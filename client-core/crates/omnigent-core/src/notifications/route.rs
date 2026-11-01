//! Notification identity: the account scope, the push payload route, and the dedupe ledger.
//!
//! Port of `NativeLab`'s `NotificationScope`, `NotificationRoute` and `NotificationLedger`
//! (`NativeNotifications.swift`). A push payload is only ever turned into a scoped
//! `(server, user, workspace, session, event)` route; it never carries a URL to navigate.

use std::collections::VecDeque;

use serde_json::{Map, Value};

use super::attention::ViewContext;
use crate::auth::endpoint::ServerEndpoint;
use crate::auth::errors::HostedAuthError;

/// Most identifier bytes a payload may carry.
pub const MAX_IDENTIFIER_BYTES: usize = 256;
/// How many delivered events a [`NotificationLedger`] remembers.
pub const MAX_LEDGER_ENTRIES: usize = 512;
/// The payload version this client understands.
pub const PAYLOAD_VERSION: u64 = 1;
const LEDGER_VERSION: u64 = 1;
const LOCAL_USER: &str = "local";
const DEFAULT_WORKSPACE: &str = "0";

/// A push payload, ledger or scope that cannot be used.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum NotificationError {
    /// The server URL is not an accepted API root.
    #[error("invalid notification server URL: {0}")]
    InvalidServerUrl(HostedAuthError),
    /// An empty user or workspace id.
    #[error("the notification scope has an empty {field}")]
    EmptyIdentity {
        /// `user_id` or `workspace_id`.
        field: &'static str,
    },
    /// No `omnigent` object in the payload: not an Omnigent notification.
    #[error("the notification has no omnigent payload")]
    MissingPayload,
    /// A payload version other than [`PAYLOAD_VERSION`].
    #[error("unsupported notification payload version {version}")]
    UnsupportedVersion {
        /// The version as sent.
        version: String,
    },
    /// A required string field is missing or not a string.
    #[error("the notification payload has no string {field}")]
    MissingField {
        /// The field.
        field: &'static str,
    },
    /// A session, event or installation id that is not a plain identifier.
    #[error("the notification {field} is not a valid identifier")]
    InvalidIdentifier {
        /// The field.
        field: &'static str,
    },
    /// A `kind` this client does not know.
    #[error("unknown notification kind {kind:?}")]
    UnknownKind {
        /// The kind as sent.
        kind: String,
    },
    /// A persisted ledger that does not decode.
    #[error("malformed notification ledger: {message}")]
    MalformedLedger {
        /// What was wrong.
        message: String,
    },
}

/// Whether `value` is a non-empty ASCII `[A-Za-z0-9_-]` identifier of at most
/// [`MAX_IDENTIFIER_BYTES`].
#[must_use]
pub fn is_valid_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_IDENTIFIER_BYTES
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

/// The account a notification belongs to: canonical API root (mount and `?o=` included), user
/// and workspace. Two mounts or two users on one host are different scopes.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct NotificationScope {
    endpoint: ServerEndpoint,
    user_id: String,
    workspace_id: String,
}

impl NotificationScope {
    /// Validates and canonicalizes the scope.
    ///
    /// # Errors
    ///
    /// [`NotificationError::InvalidServerUrl`] for a URL [`ServerEndpoint`] rejects (userinfo,
    /// queries, encoded or dot segments, plain http other than literal loopback), and
    /// [`NotificationError::EmptyIdentity`] for an empty user or workspace.
    pub fn new(
        server_url: &str,
        user_id: &str,
        workspace_id: &str,
    ) -> Result<Self, NotificationError> {
        let endpoint =
            ServerEndpoint::new(server_url).map_err(NotificationError::InvalidServerUrl)?;
        if user_id.is_empty() {
            return Err(NotificationError::EmptyIdentity { field: "user_id" });
        }
        if workspace_id.is_empty() {
            return Err(NotificationError::EmptyIdentity {
                field: "workspace_id",
            });
        }
        Ok(Self {
            endpoint,
            user_id: user_id.to_owned(),
            workspace_id: workspace_id.to_owned(),
        })
    }

    /// The scope for `user_id` in the default workspace (`"0"`).
    ///
    /// # Errors
    ///
    /// See [`NotificationScope::new`].
    pub fn in_default_workspace(
        server_url: &str,
        user_id: &str,
    ) -> Result<Self, NotificationError> {
        Self::new(server_url, user_id, DEFAULT_WORKSPACE)
    }

    /// The canonical API root.
    #[must_use]
    pub fn server_url(&self) -> &str {
        self.endpoint.base_url()
    }

    /// The validated endpoint.
    #[must_use]
    pub const fn endpoint(&self) -> &ServerEndpoint {
        &self.endpoint
    }

    /// The user.
    #[must_use]
    pub fn user_id(&self) -> &str {
        &self.user_id
    }

    /// The workspace.
    #[must_use]
    pub fn workspace_id(&self) -> &str {
        &self.workspace_id
    }

    /// The single-user loopback development server: literal `127.0.0.1` or `[::1]` over http,
    /// user `local`, workspace `0`. `localhost` and look-alike hosts never qualify.
    #[must_use]
    pub fn is_loopback_development(&self) -> bool {
        self.endpoint.is_local_single_user()
            && self.user_id == LOCAL_USER
            && self.workspace_id == DEFAULT_WORKSPACE
    }
}

/// What a notification is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NotificationKind {
    /// `approval`: a session is waiting for a decision.
    Approval,
    /// `completed`: a turn finished.
    Completed,
    /// `failed`: a turn failed.
    Failed,
}

impl NotificationKind {
    /// The wire value.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Approval => "approval",
            Self::Completed => "completed",
            Self::Failed => "failed",
        }
    }

    fn parse(value: &str) -> Result<Self, NotificationError> {
        match value {
            "approval" => Ok(Self::Approval),
            "completed" => Ok(Self::Completed),
            "failed" => Ok(Self::Failed),
            other => Err(NotificationError::UnknownKind {
                kind: other.to_owned(),
            }),
        }
    }
}

/// A scoped push notification: where tapping it leads.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct NotificationRoute {
    /// The account.
    pub scope: NotificationScope,
    /// The session to open.
    pub session_id: String,
    /// The event, for dedupe.
    pub event_id: String,
    /// What happened.
    pub kind: NotificationKind,
}

fn string_field<'a>(
    payload: &'a Map<String, Value>,
    field: &'static str,
) -> Result<&'a str, NotificationError> {
    payload
        .get(field)
        .and_then(Value::as_str)
        .ok_or(NotificationError::MissingField { field })
}

fn identifier_field<'a>(
    payload: &'a Map<String, Value>,
    field: &'static str,
) -> Result<&'a str, NotificationError> {
    let value = string_field(payload, field)?;
    if is_valid_identifier(value) {
        Ok(value)
    } else {
        Err(NotificationError::InvalidIdentifier { field })
    }
}

impl NotificationRoute {
    /// Parses the push `userInfo` (or FCM data) payload: only the versioned
    /// `{"omnigent": {"version": 1, server_url, user_id, workspace_id, session_id, event_id, kind}}`
    /// shape is accepted. Anything else (for example a bare `navigatePath`) is an error, never a
    /// navigation.
    ///
    /// # Errors
    ///
    /// See [`NotificationError`].
    pub fn from_payload(user_info: &Value) -> Result<Self, NotificationError> {
        let payload = user_info
            .get("omnigent")
            .and_then(Value::as_object)
            .ok_or(NotificationError::MissingPayload)?;
        match payload.get("version") {
            Some(version) if version.as_u64() == Some(PAYLOAD_VERSION) => {}
            other => {
                return Err(NotificationError::UnsupportedVersion {
                    version: other.map_or_else(|| "none".to_owned(), Value::to_string),
                });
            }
        }
        let scope = NotificationScope::new(
            string_field(payload, "server_url")?,
            string_field(payload, "user_id")?,
            string_field(payload, "workspace_id")?,
        )?;
        Ok(Self {
            scope,
            session_id: identifier_field(payload, "session_id")?.to_owned(),
            event_id: identifier_field(payload, "event_id")?.to_owned(),
            kind: NotificationKind::parse(string_field(payload, "kind")?)?,
        })
    }

    /// The dedupe key: a JSON array of every identity component, so no delimiter in a server or
    /// account id can make two routes collide.
    #[must_use]
    pub fn deduplication_key(&self) -> String {
        Value::Array(
            [
                self.scope.server_url(),
                self.scope.user_id(),
                self.scope.workspace_id(),
                &self.session_id,
                &self.event_id,
            ]
            .into_iter()
            .map(|part| Value::String(part.to_owned()))
            .collect(),
        )
        .to_string()
    }
}

/// Events already handled, bounded to the most recent [`MAX_LEDGER_ENTRIES`].
///
/// Keep separate ledgers for presentation and activation: showing a banner must not consume its
/// tap.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NotificationLedger {
    keys: VecDeque<String>,
}

impl NotificationLedger {
    /// An empty ledger.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Records `route`; `false` when it was already recorded.
    pub fn insert(&mut self, route: &NotificationRoute) -> bool {
        let key = route.deduplication_key();
        if self.keys.contains(&key) {
            return false;
        }
        self.keys.push_back(key);
        while self.keys.len() > MAX_LEDGER_ENTRIES {
            self.keys.pop_front();
        }
        true
    }

    /// Entries held.
    #[must_use]
    pub fn len(&self) -> usize {
        self.keys.len()
    }

    /// Whether nothing is recorded.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// The persisted form: `{"version": 1, "keys": [...]}`, oldest first.
    #[must_use]
    pub fn to_json(&self) -> Value {
        let mut object = Map::new();
        object.insert("version".to_owned(), Value::from(LEDGER_VERSION));
        object.insert(
            "keys".to_owned(),
            Value::Array(self.keys.iter().cloned().map(Value::String).collect()),
        );
        Value::Object(object)
    }

    /// Restores a ledger saved by [`NotificationLedger::to_json`]. More than
    /// [`MAX_LEDGER_ENTRIES`] keys keeps the most recent.
    ///
    /// # Errors
    ///
    /// [`NotificationError::MalformedLedger`] for any other shape.
    pub fn from_json(value: &Value) -> Result<Self, NotificationError> {
        let malformed = |message: &str| NotificationError::MalformedLedger {
            message: message.to_owned(),
        };
        if value.get("version").and_then(Value::as_u64) != Some(LEDGER_VERSION) {
            return Err(malformed("unsupported version"));
        }
        let keys = value
            .get("keys")
            .and_then(Value::as_array)
            .ok_or_else(|| malformed("no keys array"))?;
        let mut keys: VecDeque<String> = keys
            .iter()
            .map(|key| {
                key.as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| malformed("a key is not a string"))
            })
            .collect::<Result<_, _>>()?;
        while keys.len() > MAX_LEDGER_ENTRIES {
            keys.pop_front();
        }
        Ok(Self { keys })
    }
}

/// What to do with a push that arrived while the app runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushPresentation {
    /// Show the banner.
    Present,
    /// Already shown once.
    Duplicate,
    /// The user is looking at that session in that account right now.
    SuppressViewed,
}

/// Decides whether to show `route` in the foreground, recording it in the presentation ledger.
/// `connected` is the scope of the account the app currently shows, if any.
pub fn foreground_presentation(
    route: &NotificationRoute,
    connected: Option<&NotificationScope>,
    view: &ViewContext,
    presented: &mut NotificationLedger,
) -> PushPresentation {
    if !presented.insert(route) {
        return PushPresentation::Duplicate;
    }
    if connected == Some(&route.scope) && view.is_viewing(&route.session_id) {
        return PushPresentation::SuppressViewed;
    }
    PushPresentation::Present
}
