//! `WS /v1/sessions/updates` codec and connection state machine.
//!
//! The wire protocol (`docs/wire-contract.md` §4):
//!
//! - Client → server: `{"type":"watch","session_ids":[...]}`. Each message replaces the
//!   previous watch set. The server caps the set at 500 and silently drops the excess, so the
//!   client refuses to build a larger set ([`WatchError::LimitExceeded`]) instead of losing
//!   sessions without notice.
//! - Server → client: `snapshot` (once per `watch`), `changed`, `removed`, `hosts_changed`,
//!   `projects_changed` and `heartbeat` (after 30 s without traffic). Any other `type` decodes
//!   to [`UpdatesFrame::Unknown`] and is forwarded, never dropped. Unknown keys such as trace
//!   context are ignored.
//!
//! [`SessionUpdates`] handles connecting, re-sending the watch set on every open, discovery
//! (a `changed` row for an unwatched session joins the watch set, as in `NativeLab`), and
//! the 70 s silence watchdog (two missed heartbeats). Reconnects use the shared backoff. After
//! a reconnect, [`UpdatesOutput::Live`] carries `resumed: true`. The caller must then refetch
//! the session list, because discovery pushes sent while disconnected are not replayed.
//!
//! Session rows are kept as JSON behind [`SessionRow`] until WP1's typed
//! `omnigent_protocol::sessions` list item lands. Only [`SessionRow::decode`] changes then.

use serde_json::{Map, Value};
use thiserror::Error;

use super::backoff::{JitterSource, Retry, RetryConfig, RetryDecision};
use super::host::{ConnectionFailure, SocketEnd, SocketMessage};
use super::link::{AttemptId, ConnectionState, Ids, LinkError, TimerKind, TimerToken};
use crate::http::TransportError;

/// The server's watch-set cap (`_SESSION_UPDATES_MAX_WATCHED`).
pub const MAX_WATCHED_SESSIONS: usize = 500;

/// WebSocket close code the client sends when it stops or abandons a socket ("going away").
pub const CLIENT_CLOSE_CODE: u16 = 1001;

/// Why a watch set was refused.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum WatchError {
    /// More distinct ids than the server would watch.
    #[error("watching {requested} sessions exceeds the server limit of {limit}")]
    LimitExceeded {
        /// Distinct ids requested.
        requested: usize,
        /// [`MAX_WATCHED_SESSIONS`].
        limit: usize,
    },
    /// An id that is empty or not `[A-Za-z0-9_-]+`.
    #[error("invalid session id {id:?}")]
    InvalidSessionId {
        /// The offending id.
        id: String,
    },
}

/// Whether `id` is a well-formed session id: non-empty `[A-Za-z0-9_-]`. This is `NativeLab`'s
/// `validateIdentifier`.
#[must_use]
pub fn is_valid_session_id(id: &str) -> bool {
    !id.is_empty()
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

/// A validated, de-duplicated set of watched session ids, kept in first-seen order.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WatchSet {
    ids: Vec<String>,
}

impl WatchSet {
    /// Validates `ids`. Duplicates collapse to their first occurrence.
    ///
    /// # Errors
    ///
    /// [`WatchError::LimitExceeded`] when more than [`MAX_WATCHED_SESSIONS`] distinct ids
    /// remain. It is checked before the ids themselves. Otherwise
    /// [`WatchError::InvalidSessionId`] for the first malformed id.
    pub fn new<I, S>(ids: I) -> Result<Self, WatchError>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut unique: Vec<String> = Vec::new();
        for id in ids {
            let id = id.into();
            if !unique.contains(&id) {
                unique.push(id);
            }
        }
        if unique.len() > MAX_WATCHED_SESSIONS {
            return Err(WatchError::LimitExceeded {
                requested: unique.len(),
                limit: MAX_WATCHED_SESSIONS,
            });
        }
        if let Some(id) = unique.iter().find(|id| !is_valid_session_id(id)) {
            return Err(WatchError::InvalidSessionId { id: id.clone() });
        }
        Ok(Self { ids: unique })
    }

    /// The ids, in first-seen order.
    #[must_use]
    pub fn ids(&self) -> &[String] {
        &self.ids
    }

    /// The number of ids.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.ids.len()
    }

    /// Whether no session is watched.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    /// Whether `id` is watched.
    #[must_use]
    pub fn contains(&self, id: &str) -> bool {
        self.ids.iter().any(|watched| watched == id)
    }

    /// Whether both sets watch the same sessions, in any order.
    #[must_use]
    pub fn same_sessions(&self, other: &Self) -> bool {
        self.len() == other.len() && self.ids.iter().all(|id| other.contains(id))
    }

    /// The `watch` message text.
    #[must_use]
    pub fn to_message(&self) -> String {
        let mut message = Map::new();
        message.insert("type".to_owned(), Value::String("watch".to_owned()));
        message.insert(
            "session_ids".to_owned(),
            Value::Array(self.ids.iter().cloned().map(Value::String).collect()),
        );
        Value::Object(message).to_string()
    }

    /// Adds `id`. Returns whether it was new.
    fn insert(&mut self, id: &str) -> Result<bool, WatchError> {
        if self.contains(id) {
            return Ok(false);
        }
        if !is_valid_session_id(id) {
            return Err(WatchError::InvalidSessionId { id: id.to_owned() });
        }
        if self.len() >= MAX_WATCHED_SESSIONS {
            return Err(WatchError::LimitExceeded {
                requested: self.len() + 1,
                limit: MAX_WATCHED_SESSIONS,
            });
        }
        self.ids.push(id.to_owned());
        Ok(true)
    }

    fn remove_all(&mut self, ids: &[String]) {
        self.ids.retain(|watched| !ids.contains(watched));
    }
}

/// One session row from a `snapshot` or `changed` frame: a full `SessionListItem` dump with
/// explicit nulls, so a null clears its field.
///
/// This is the seam for WP1's typed rows. Today it keeps the raw JSON object and checks only
/// the `id`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionRow {
    id: String,
    raw: Map<String, Value>,
}

impl SessionRow {
    /// Decodes one row.
    ///
    /// # Errors
    ///
    /// Returns a description when the row is not an object with a non-empty string `id`.
    pub fn decode(value: Value) -> Result<Self, String> {
        let Value::Object(raw) = value else {
            return Err("row is not a JSON object".to_owned());
        };
        let id = match raw.get("id") {
            Some(Value::String(id)) if !id.is_empty() => id.clone(),
            Some(other) => return Err(format!("row id is not a non-empty string: {other}")),
            None => return Err("row has no id".to_owned()),
        };
        Ok(Self { id, raw })
    }

    /// The session id.
    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    /// The row as sent.
    #[must_use]
    pub const fn raw(&self) -> &Map<String, Value> {
        &self.raw
    }

    /// The row as sent, by value.
    #[must_use]
    pub fn into_raw(self) -> Map<String, Value> {
        self.raw
    }
}

/// Why an inbound frame could not be decoded.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum UpdatesError {
    /// A binary frame that is not UTF-8.
    #[error("binary frame is not UTF-8 (valid up to byte {valid_up_to})")]
    NotUtf8 {
        /// Bytes that were valid before the bad sequence.
        valid_up_to: usize,
    },
    /// Not JSON.
    #[error("frame is not JSON: {message}")]
    NotJson {
        /// The decoder's message.
        message: String,
    },
    /// Not a JSON object with a string `type`.
    #[error("frame is not a JSON object with a string type")]
    MissingType,
    /// A known frame without its payload array.
    #[error("{frame_type} frame has no {field} array")]
    MissingField {
        /// The frame type.
        frame_type: String,
        /// The missing key.
        field: &'static str,
    },
    /// One element of a payload array is invalid.
    #[error("{frame_type} frame element {index} is invalid: {message}")]
    InvalidElement {
        /// The frame type.
        frame_type: String,
        /// The 0-based position in the array.
        index: usize,
        /// What is wrong with it.
        message: String,
    },
}

/// One decoded server frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdatesFrame {
    /// The watched rows, sent once per `watch`.
    Snapshot {
        /// The rows.
        rows: Vec<SessionRow>,
    },
    /// Rows that changed, including sessions discovered outside the watch set.
    Changed {
        /// The rows.
        rows: Vec<SessionRow>,
    },
    /// Watched sessions that were deleted or are no longer accessible.
    Removed {
        /// Their ids.
        ids: Vec<String>,
    },
    /// The host inventory changed: refetch `/v1/hosts`.
    HostsChanged,
    /// The project list changed: refetch projects.
    ProjectsChanged,
    /// Keepalive.
    Heartbeat,
    /// A frame type this client does not know.
    Unknown {
        /// Its `type`.
        frame_type: String,
        /// The whole frame.
        raw: Map<String, Value>,
    },
}

impl UpdatesFrame {
    /// Decodes a text frame.
    ///
    /// # Errors
    ///
    /// Returns an [`UpdatesError`] when the text is not a JSON object with a string `type`, or
    /// when a known frame's payload is malformed.
    pub fn decode(text: &str) -> Result<Self, UpdatesError> {
        let value: Value = serde_json::from_str(text).map_err(|error| UpdatesError::NotJson {
            message: error.to_string(),
        })?;
        let Value::Object(mut raw) = value else {
            return Err(UpdatesError::MissingType);
        };
        let frame_type = match raw.get("type") {
            Some(Value::String(frame_type)) => frame_type.clone(),
            _ => return Err(UpdatesError::MissingType),
        };
        Ok(match frame_type.as_str() {
            "snapshot" => Self::Snapshot {
                rows: decode_rows(&frame_type, raw.remove("items"))?,
            },
            "changed" => Self::Changed {
                rows: decode_rows(&frame_type, raw.remove("items"))?,
            },
            "removed" => Self::Removed {
                ids: decode_ids(&frame_type, raw.remove("ids"))?,
            },
            "hosts_changed" => Self::HostsChanged,
            "projects_changed" => Self::ProjectsChanged,
            "heartbeat" => Self::Heartbeat,
            _ => Self::Unknown { frame_type, raw },
        })
    }

    /// Decodes any data frame. Binary frames must hold UTF-8 JSON, as `NativeLab` accepts.
    ///
    /// # Errors
    ///
    /// As for [`Self::decode`], plus [`UpdatesError::NotUtf8`].
    pub fn decode_message(message: &SocketMessage) -> Result<Self, UpdatesError> {
        match message {
            SocketMessage::Text(text) => Self::decode(text),
            SocketMessage::Binary(bytes) => {
                let text = std::str::from_utf8(bytes).map_err(|error| UpdatesError::NotUtf8 {
                    valid_up_to: error.valid_up_to(),
                })?;
                Self::decode(text)
            }
        }
    }
}

fn payload_array(
    frame_type: &str,
    field: &'static str,
    value: Option<Value>,
) -> Result<Vec<Value>, UpdatesError> {
    match value {
        Some(Value::Array(values)) => Ok(values),
        _ => Err(UpdatesError::MissingField {
            frame_type: frame_type.to_owned(),
            field,
        }),
    }
}

fn decode_rows(frame_type: &str, value: Option<Value>) -> Result<Vec<SessionRow>, UpdatesError> {
    payload_array(frame_type, "items", value)?
        .into_iter()
        .enumerate()
        .map(|(index, row)| {
            SessionRow::decode(row).map_err(|message| UpdatesError::InvalidElement {
                frame_type: frame_type.to_owned(),
                index,
                message,
            })
        })
        .collect()
}

fn decode_ids(frame_type: &str, value: Option<Value>) -> Result<Vec<String>, UpdatesError> {
    payload_array(frame_type, "ids", value)?
        .into_iter()
        .enumerate()
        .map(|(index, id)| match id {
            Value::String(id) => Ok(id),
            other => Err(UpdatesError::InvalidElement {
                frame_type: frame_type.to_owned(),
                index,
                message: format!("id is not a string: {other}"),
            }),
        })
        .collect()
}

/// Tunables for [`SessionUpdates`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UpdatesConfig {
    /// Reconnect policy.
    pub retry: RetryConfig,
    /// Silence, in ms, after which the socket is presumed dead. The default is 70 s
    /// (`HEARTBEAT_WATCHDOG_MS` in `web/src/lib/sessionUpdatesSocket.ts`, a little over two
    /// 30 s heartbeats).
    pub silence_timeout_ms: u64,
}

impl Default for UpdatesConfig {
    fn default() -> Self {
        Self {
            retry: RetryConfig::default(),
            silence_timeout_ms: 70_000,
        }
    }
}

/// Inputs to [`SessionUpdates::handle`]. The watch set changes through
/// [`SessionUpdates::set_watch`], which can fail.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdatesInput {
    /// Start (or restart after `Stopped` or `Failed`) with a fresh backoff ramp. This does
    /// nothing while already running.
    Start,
    /// Stop and close the socket.
    Stop,
    /// [`super::WebSocketTransport::connect`] resolved `Err`.
    ConnectFailed {
        /// The attempt it was connecting.
        attempt: AttemptId,
        /// The host's error.
        error: TransportError,
    },
    /// [`super::MessageSink::opened`].
    Opened {
        /// The attempt the sink belongs to.
        attempt: AttemptId,
    },
    /// [`super::MessageSink::message`].
    Message {
        /// The attempt the sink belongs to.
        attempt: AttemptId,
        /// The frame.
        message: SocketMessage,
    },
    /// [`super::MessageSink::ended`].
    Ended {
        /// The attempt the sink belongs to.
        attempt: AttemptId,
        /// How it ended.
        end: SocketEnd,
    },
    /// [`super::WebSocketHandle::send_text`] for a [`UpdatesOutput::Send`] resolved `Err`.
    SendFailed {
        /// The attempt it was sent on.
        attempt: AttemptId,
        /// The host's error.
        error: TransportError,
    },
    /// A timer scheduled with [`UpdatesOutput::ScheduleTimer`] fired.
    TimerFired {
        /// Its token.
        token: TimerToken,
    },
}

/// Work for the driver, returned in execution order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdatesOutput {
    /// Build the upgrade request (with fresh credentials) and connect it with a sink for
    /// `attempt`.
    Connect {
        /// The new attempt.
        attempt: AttemptId,
    },
    /// Send `text` on the socket for `attempt`. Report a failure with
    /// [`UpdatesInput::SendFailed`].
    Send {
        /// The attempt to send on.
        attempt: AttemptId,
        /// The frame text.
        text: String,
    },
    /// Close the socket for `attempt`, or cancel its handshake if it is still pending.
    Close {
        /// The attempt to close.
        attempt: AttemptId,
        /// The close code.
        code: u16,
        /// The close reason.
        reason: String,
    },
    /// Deliver [`UpdatesInput::TimerFired`] with `token` after `delay_ms`.
    ScheduleTimer {
        /// The token to deliver.
        token: TimerToken,
        /// The delay from the current `now_ms`.
        delay_ms: u64,
    },
    /// The timer `token` is no longer needed.
    CancelTimer {
        /// Its token.
        token: TimerToken,
    },
    /// The public connection state changed.
    StateChanged {
        /// The new state.
        state: ConnectionState,
    },
    /// The first snapshot arrived on `attempt`.
    Live {
        /// The live attempt.
        attempt: AttemptId,
        /// An earlier attempt was live: refetch the session list to recover discovery pushes
        /// missed while disconnected.
        resumed: bool,
    },
    /// A server frame. Heartbeats are not forwarded.
    Frame {
        /// The frame.
        frame: UpdatesFrame,
    },
    /// Sessions the server pushed could not join the watch set, so later changes to them will
    /// not arrive. Refetch the list, or narrow the watch set, to keep them visible.
    DiscoveryNotWatched {
        /// The sessions.
        ids: Vec<String>,
        /// Why.
        error: WatchError,
    },
}

#[derive(Debug, Clone)]
struct SocketAttempt {
    id: AttemptId,
    opened: bool,
    live_at_ms: Option<u64>,
    last_activity_ms: u64,
    watchdog: Option<TimerToken>,
}

/// Pure state machine for the session-updates socket. See the [module docs](self).
#[derive(Debug, Clone)]
pub struct SessionUpdates<J> {
    config: UpdatesConfig,
    jitter: J,
    ids: Ids,
    retry: Retry,
    state: ConnectionState,
    watch: WatchSet,
    attempt: Option<SocketAttempt>,
    reconnect_timer: Option<TimerToken>,
    ever_live: bool,
}

impl<J: JitterSource> SessionUpdates<J> {
    /// An idle machine with an empty watch set.
    pub fn new(config: UpdatesConfig, jitter: J) -> Self {
        Self {
            config,
            jitter,
            ids: Ids::default(),
            retry: Retry::new(config.retry),
            state: ConnectionState::Idle,
            watch: WatchSet::default(),
            attempt: None,
            reconnect_timer: None,
            ever_live: false,
        }
    }

    /// The current public state.
    pub const fn state(&self) -> &ConnectionState {
        &self.state
    }

    /// The current watch set, including discovered sessions.
    pub const fn watch(&self) -> &WatchSet {
        &self.watch
    }

    /// The attempt in flight, if any.
    pub fn current_attempt(&self) -> Option<AttemptId> {
        self.attempt.as_ref().map(|attempt| attempt.id)
    }

    /// Replaces the watch set. If the socket is open and the sessions changed, the result holds
    /// the `watch` message to send. Otherwise it is sent on the next open.
    ///
    /// # Errors
    ///
    /// See [`WatchSet::new`]. On error nothing is sent and the current set is kept.
    pub fn set_watch<I, S>(&mut self, ids: I) -> Result<Vec<UpdatesOutput>, WatchError>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let watch = WatchSet::new(ids)?;
        if watch.same_sessions(&self.watch) {
            return Ok(Vec::new());
        }
        self.watch = watch;
        let mut out = Vec::new();
        self.send_watch(&mut out);
        Ok(out)
    }

    /// Applies one input at `now_ms` and returns the work it causes, in order. Inputs for a
    /// stale attempt or timer return nothing.
    pub fn handle(&mut self, now_ms: u64, input: UpdatesInput) -> Vec<UpdatesOutput> {
        let mut out = Vec::new();
        match input {
            UpdatesInput::Start => self.start(now_ms, &mut out),
            UpdatesInput::Stop => self.stop(&mut out),
            UpdatesInput::ConnectFailed { attempt, error } => {
                if self.is_current(attempt) {
                    let error = LinkError::Connection(ConnectionFailure::Transport(error));
                    self.lose(now_ms, error, false, &mut out);
                }
            }
            UpdatesInput::Opened { attempt } => {
                if self.is_current(attempt) {
                    self.on_opened(now_ms, &mut out);
                }
            }
            UpdatesInput::Message { attempt, message } => {
                if self.is_current(attempt) {
                    self.on_message(now_ms, &message, &mut out);
                }
            }
            UpdatesInput::Ended { attempt, end } => {
                if self.is_current(attempt) {
                    let error = match end {
                        SocketEnd::Closed { code, reason } => {
                            LinkError::SocketClosed { code, reason }
                        }
                        SocketEnd::HandshakeRejected { status } => LinkError::HttpStatus { status },
                        SocketEnd::Failed(failure) => LinkError::Connection(failure),
                    };
                    self.lose(now_ms, error, false, &mut out);
                }
            }
            UpdatesInput::SendFailed { attempt, error } => {
                if self.is_current(attempt) {
                    self.lose(now_ms, LinkError::SendFailed(error), true, &mut out);
                }
            }
            UpdatesInput::TimerFired { token } => self.on_timer(now_ms, token, &mut out),
        }
        out
    }

    fn is_current(&self, attempt: AttemptId) -> bool {
        self.current_attempt() == Some(attempt)
    }

    fn start(&mut self, now_ms: u64, out: &mut Vec<UpdatesOutput>) {
        match self.state {
            ConnectionState::Connecting
            | ConnectionState::Live
            | ConnectionState::Reconnecting { .. } => {}
            ConnectionState::Idle
            | ConnectionState::Closed
            | ConnectionState::Stopped
            | ConnectionState::Failed { .. } => {
                self.retry.reset();
                self.set_state(ConnectionState::Connecting, out);
                self.connect(now_ms, out);
            }
        }
    }

    fn stop(&mut self, out: &mut Vec<UpdatesOutput>) {
        self.end_attempt(Some("client stopped"), out);
        if let Some(token) = self.reconnect_timer.take() {
            out.push(UpdatesOutput::CancelTimer { token });
        }
        self.set_state(ConnectionState::Stopped, out);
    }

    fn on_opened(&mut self, now_ms: u64, out: &mut Vec<UpdatesOutput>) {
        let Some(attempt) = self.attempt.as_mut() else {
            return;
        };
        if attempt.opened {
            let error = LinkError::HostContract {
                message: "opened was reported twice for one socket".to_owned(),
            };
            self.lose(now_ms, error, true, out);
            return;
        }
        attempt.opened = true;
        attempt.last_activity_ms = now_ms;
        self.send_watch(out);
    }

    fn on_message(&mut self, now_ms: u64, message: &SocketMessage, out: &mut Vec<UpdatesOutput>) {
        let Some(attempt) = self.attempt.as_mut() else {
            return;
        };
        if !attempt.opened {
            let error = LinkError::HostContract {
                message: "a message arrived before the socket opened".to_owned(),
            };
            self.lose(now_ms, error, true, out);
            return;
        }
        attempt.last_activity_ms = now_ms;
        let frame = match UpdatesFrame::decode_message(message) {
            Ok(frame) => frame,
            Err(error) => {
                let error = LinkError::MalformedFrame {
                    message: error.to_string(),
                };
                self.lose(now_ms, error, true, out);
                return;
            }
        };
        match frame {
            UpdatesFrame::Heartbeat => {}
            UpdatesFrame::Snapshot { rows } => {
                self.mark_live(now_ms, out);
                let discovered = self.discover(&rows, out);
                out.push(UpdatesOutput::Frame {
                    frame: UpdatesFrame::Snapshot { rows },
                });
                if discovered {
                    self.send_watch(out);
                }
            }
            UpdatesFrame::Changed { rows } => {
                let discovered = self.discover(&rows, out);
                out.push(UpdatesOutput::Frame {
                    frame: UpdatesFrame::Changed { rows },
                });
                if discovered {
                    self.send_watch(out);
                }
            }
            UpdatesFrame::Removed { ids } => {
                self.watch.remove_all(&ids);
                out.push(UpdatesOutput::Frame {
                    frame: UpdatesFrame::Removed { ids },
                });
            }
            frame @ (UpdatesFrame::HostsChanged
            | UpdatesFrame::ProjectsChanged
            | UpdatesFrame::Unknown { .. }) => out.push(UpdatesOutput::Frame { frame }),
        }
    }

    /// Adds pushed rows for unwatched sessions to the watch set. Returns whether any joined.
    fn discover(&mut self, rows: &[SessionRow], out: &mut Vec<UpdatesOutput>) -> bool {
        let mut added = false;
        let mut over_limit = Vec::new();
        for row in rows {
            match self.watch.insert(row.id()) {
                Ok(new) => added |= new,
                Err(WatchError::LimitExceeded { .. }) => over_limit.push(row.id().to_owned()),
                Err(error) => out.push(UpdatesOutput::DiscoveryNotWatched {
                    ids: vec![row.id().to_owned()],
                    error,
                }),
            }
        }
        if !over_limit.is_empty() {
            let requested = self.watch.len() + over_limit.len();
            out.push(UpdatesOutput::DiscoveryNotWatched {
                ids: over_limit,
                error: WatchError::LimitExceeded {
                    requested,
                    limit: MAX_WATCHED_SESSIONS,
                },
            });
        }
        added
    }

    fn on_timer(&mut self, now_ms: u64, token: TimerToken, out: &mut Vec<UpdatesOutput>) {
        if self.reconnect_timer == Some(token) {
            self.reconnect_timer = None;
            self.connect(now_ms, out);
            return;
        }
        let Some(attempt) = self.attempt.as_mut() else {
            return;
        };
        if attempt.watchdog != Some(token) {
            return;
        }
        attempt.watchdog = None;
        let silent_ms = now_ms.saturating_sub(attempt.last_activity_ms);
        if silent_ms >= self.config.silence_timeout_ms {
            self.lose(now_ms, LinkError::Stalled { silent_ms }, true, out);
        } else {
            let token = self.ids.timer(TimerKind::Watchdog);
            attempt.watchdog = Some(token);
            out.push(UpdatesOutput::ScheduleTimer {
                token,
                delay_ms: self.config.silence_timeout_ms - silent_ms,
            });
        }
    }

    fn mark_live(&mut self, now_ms: u64, out: &mut Vec<UpdatesOutput>) {
        let Some(attempt) = self.attempt.as_mut() else {
            return;
        };
        if attempt.live_at_ms.is_some() {
            return;
        }
        attempt.live_at_ms = Some(now_ms);
        let id = attempt.id;
        self.retry.on_live();
        self.set_state(ConnectionState::Live, out);
        out.push(UpdatesOutput::Live {
            attempt: id,
            resumed: self.ever_live,
        });
        self.ever_live = true;
    }

    fn send_watch(&self, out: &mut Vec<UpdatesOutput>) {
        if let Some(attempt) = self.attempt.as_ref().filter(|attempt| attempt.opened) {
            out.push(UpdatesOutput::Send {
                attempt: attempt.id,
                text: self.watch.to_message(),
            });
        }
    }

    fn connect(&mut self, now_ms: u64, out: &mut Vec<UpdatesOutput>) {
        let id = self.ids.attempt();
        let watchdog = self.ids.timer(TimerKind::Watchdog);
        self.attempt = Some(SocketAttempt {
            id,
            opened: false,
            live_at_ms: None,
            last_activity_ms: now_ms,
            watchdog: Some(watchdog),
        });
        out.push(UpdatesOutput::Connect { attempt: id });
        out.push(UpdatesOutput::ScheduleTimer {
            token: watchdog,
            delay_ms: self.config.silence_timeout_ms,
        });
    }

    /// Drops the current attempt, closing the socket with `close_reason` if given. Returns when
    /// it went live, if it did.
    fn end_attempt(
        &mut self,
        close_reason: Option<&str>,
        out: &mut Vec<UpdatesOutput>,
    ) -> Option<u64> {
        let attempt = self.attempt.take()?;
        if let Some(reason) = close_reason {
            out.push(UpdatesOutput::Close {
                attempt: attempt.id,
                code: CLIENT_CLOSE_CODE,
                reason: reason.to_owned(),
            });
        }
        if let Some(token) = attempt.watchdog {
            out.push(UpdatesOutput::CancelTimer { token });
        }
        attempt.live_at_ms
    }

    fn lose(&mut self, now_ms: u64, error: LinkError, close: bool, out: &mut Vec<UpdatesOutput>) {
        if self.attempt.is_none() {
            return;
        }
        let live_for_ms = self
            .end_attempt(close.then_some("client reconnecting"), out)
            .map(|live_at| now_ms.saturating_sub(live_at));
        match self.retry.after_loss(&error, live_for_ms, &mut self.jitter) {
            RetryDecision::GiveUp => self.set_state(ConnectionState::Failed { error }, out),
            RetryDecision::Reconnect { delay_ms, failures } => {
                self.set_state(
                    ConnectionState::Reconnecting {
                        reason: error,
                        failures,
                        delay_ms,
                    },
                    out,
                );
                if delay_ms == 0 {
                    self.connect(now_ms, out);
                } else {
                    let token = self.ids.timer(TimerKind::Reconnect);
                    self.reconnect_timer = Some(token);
                    out.push(UpdatesOutput::ScheduleTimer { token, delay_ms });
                }
            }
        }
    }

    fn set_state(&mut self, state: ConnectionState, out: &mut Vec<UpdatesOutput>) {
        if self.state != state {
            self.state = state.clone();
            out.push(UpdatesOutput::StateChanged { state });
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::realtime::test_support::{FixedJitter, WsLine, ws_transcript};

    struct Harness {
        machine: SessionUpdates<FixedJitter>,
        now: u64,
    }

    impl Harness {
        fn new() -> Self {
            Self {
                machine: SessionUpdates::new(UpdatesConfig::default(), FixedJitter(0)),
                now: 1_000,
            }
        }

        fn run(&mut self, input: UpdatesInput) -> Vec<UpdatesOutput> {
            self.machine.handle(self.now, input)
        }

        fn attempt(&self) -> AttemptId {
            self.machine
                .current_attempt()
                .expect("an attempt in flight")
        }

        fn open(&mut self) -> Vec<UpdatesOutput> {
            let attempt = self.attempt();
            self.run(UpdatesInput::Opened { attempt })
        }

        fn recv(&mut self, message: &Value) -> Vec<UpdatesOutput> {
            let attempt = self.attempt();
            self.run(UpdatesInput::Message {
                attempt,
                message: SocketMessage::Text(message.to_string()),
            })
        }

        fn end(&mut self, end: SocketEnd) -> Vec<UpdatesOutput> {
            let attempt = self.attempt();
            self.run(UpdatesInput::Ended { attempt, end })
        }

        /// Start, open and receive an empty snapshot.
        fn live(&mut self) -> AttemptId {
            self.run(UpdatesInput::Start);
            self.open();
            let attempt = self.attempt();
            let outputs = self.recv(&json!({"type": "snapshot", "items": []}));
            assert!(
                outputs
                    .iter()
                    .any(|o| matches!(o, UpdatesOutput::Live { .. }))
            );
            attempt
        }
    }

    fn sent(outputs: &[UpdatesOutput]) -> Vec<Value> {
        outputs
            .iter()
            .filter_map(|output| match output {
                UpdatesOutput::Send { text, .. } => Some(serde_json::from_str(text).unwrap()),
                _ => None,
            })
            .collect()
    }

    fn frames(outputs: &[UpdatesOutput]) -> Vec<&UpdatesFrame> {
        outputs
            .iter()
            .filter_map(|output| match output {
                UpdatesOutput::Frame { frame } => Some(frame),
                _ => None,
            })
            .collect()
    }

    fn last_state(outputs: &[UpdatesOutput]) -> Option<&ConnectionState> {
        outputs.iter().rev().find_map(|output| match output {
            UpdatesOutput::StateChanged { state } => Some(state),
            _ => None,
        })
    }

    fn connects(outputs: &[UpdatesOutput]) -> Vec<AttemptId> {
        outputs
            .iter()
            .filter_map(|output| match output {
                UpdatesOutput::Connect { attempt } => Some(*attempt),
                _ => None,
            })
            .collect()
    }

    fn timer(outputs: &[UpdatesOutput], kind: TimerKind) -> Option<(TimerToken, u64)> {
        outputs.iter().find_map(|output| match output {
            UpdatesOutput::ScheduleTimer { token, delay_ms } if token.kind == kind => {
                Some((*token, *delay_ms))
            }
            _ => None,
        })
    }

    fn ids_of(message: &Value) -> Vec<String> {
        message["session_ids"]
            .as_array()
            .unwrap()
            .iter()
            .map(|id| id.as_str().unwrap().to_owned())
            .collect()
    }

    #[test]
    fn recorded_transcript_round_trips_watch_and_every_frame() {
        let transcript = ws_transcript("recorded-updates-ws.jsonl");
        let WsLine::Send(first_watch) = &transcript[0] else {
            panic!("the transcript starts with a watch");
        };
        let mut harness = Harness::new();
        assert_eq!(harness.machine.set_watch(ids_of(first_watch)).unwrap(), []);
        let outputs = harness.run(UpdatesInput::Start);
        assert_eq!(connects(&outputs), [AttemptId(1)]);
        assert_eq!(
            timer(&outputs, TimerKind::Watchdog).map(|(_, delay)| delay),
            Some(70_000)
        );
        assert_eq!(sent(&harness.open()), std::slice::from_ref(first_watch));

        let mut snapshots = 0;
        for line in &transcript[1..] {
            match line {
                WsLine::Send(watch) => {
                    let outputs = harness.machine.set_watch(ids_of(watch)).unwrap();
                    assert_eq!(sent(&outputs), std::slice::from_ref(watch));
                }
                WsLine::Recv(message) => {
                    let outputs = harness.recv(message);
                    assert_eq!(sent(&outputs), Vec::<Value>::new(), "no discovery");
                    match message["type"].as_str().unwrap() {
                        "heartbeat" => assert_eq!(outputs, []),
                        "snapshot" | "changed" => {
                            let [UpdatesFrame::Snapshot { rows } | UpdatesFrame::Changed { rows }] =
                                frames(&outputs)[..]
                            else {
                                panic!("expected one row frame: {outputs:?}");
                            };
                            let items = message["items"].as_array().unwrap();
                            assert_eq!(rows.len(), items.len());
                            for (row, item) in rows.iter().zip(items) {
                                assert_eq!(row.id(), item["id"].as_str().unwrap());
                                assert_eq!(&Value::Object(row.raw().clone()), item);
                            }
                            if message["type"] == "snapshot" {
                                snapshots += 1;
                                let live = outputs.iter().find_map(|output| match output {
                                    UpdatesOutput::Live { resumed, .. } => Some(*resumed),
                                    _ => None,
                                });
                                assert_eq!(live, (snapshots == 1).then_some(false));
                            }
                        }
                        "removed" => {
                            assert_eq!(
                                frames(&outputs),
                                [&UpdatesFrame::Removed {
                                    ids: vec!["1a96db016a85409ab884278d2ab31dfc".into()]
                                }]
                            );
                        }
                        other => panic!("unexpected frame {other}"),
                    }
                }
            }
        }
        assert_eq!(snapshots, 3);
        assert_eq!(harness.machine.state(), &ConnectionState::Live);
        assert!(
            !harness
                .machine
                .watch()
                .contains("1a96db016a85409ab884278d2ab31dfc")
        );
        assert_eq!(harness.machine.watch().len(), 2);
    }

    // Port of LocalServerSessionClientTests.swift::testListFramesUpdatePermissionsAndRemoveLostAccess.
    // The writable-permission projection (`permission_level` 4 → not read-only) belongs to WP1's
    // typed row. Here the row must arrive intact with that field.
    #[test]
    fn list_frames_update_permissions_and_remove_lost_access() {
        let transcript = ws_transcript(
            "LocalServerSessionClient--ListFramesUpdatePermissionsAndRemoveLostAccess.jsonl",
        );
        let [WsLine::Recv(changed), WsLine::Recv(removed)] = &transcript[..] else {
            panic!("expected two received frames");
        };
        let mut harness = Harness::new();
        harness.live();

        let outputs = harness.recv(changed);
        let [UpdatesFrame::Changed { rows }] = frames(&outputs)[..] else {
            panic!("expected a list delta: {outputs:?}");
        };
        assert_eq!(
            rows.iter().map(SessionRow::id).collect::<Vec<_>>(),
            ["conv_a"]
        );
        assert_eq!(rows[0].raw()["permission_level"], json!(4));
        // conv_a was pushed from outside the watch set, so it joins it.
        assert_eq!(
            sent(&outputs),
            [json!({"type": "watch", "session_ids": ["conv_a"]})]
        );

        let outputs = harness.recv(removed);
        assert_eq!(
            frames(&outputs),
            [&UpdatesFrame::Removed {
                ids: vec!["conv_a".into()]
            }]
        );
        assert!(harness.machine.watch().is_empty());
    }

    // Port of LocalServerSessionClientTests.swift::testWatchLimitFailsExplicitlyInsteadOfSilentlyMissingInboxSessions.
    #[test]
    fn watch_limit_fails_explicitly_instead_of_silently_missing_inbox_sessions() {
        let mut harness = Harness::new();
        harness.live();
        let before = harness.machine.watch().clone();
        let too_many: Vec<String> = (1..=501).map(|n| format!("session_{n}")).collect();
        assert_eq!(
            harness.machine.set_watch(too_many.clone()),
            Err(WatchError::LimitExceeded {
                requested: 501,
                limit: 500
            })
        );
        assert_eq!(
            harness.machine.watch(),
            &before,
            "nothing changed and nothing was sent"
        );

        // Duplicates do not count against the cap, and exactly 500 is allowed.
        let mut with_duplicate = too_many[..500].to_vec();
        with_duplicate.push("session_1".into());
        let outputs = harness.machine.set_watch(with_duplicate).unwrap();
        assert_eq!(ids_of(&sent(&outputs)[0]).len(), 500);
    }

    // Port of HostedServerAuthenticationTests.swift::testSocketHandshakeAuthAndTLSFailuresDoNotReconnect.
    #[test]
    fn socket_handshake_auth_and_tls_failures_do_not_reconnect() {
        let mut ends: Vec<SocketEnd> = [302, 401, 403]
            .into_iter()
            .map(|status| SocketEnd::HandshakeRejected { status })
            .collect();
        ends.extend(
            [
                ConnectionFailure::AuthenticationRequired {
                    message: "userAuthenticationRequired".into(),
                },
                ConnectionFailure::AuthenticationRequired {
                    message: "userCancelledAuthentication".into(),
                },
                ConnectionFailure::Transport(TransportError::Tls {
                    message: "serverCertificateUntrusted".into(),
                }),
                ConnectionFailure::Transport(TransportError::Tls {
                    message: "serverCertificateHasUnknownRoot".into(),
                }),
            ]
            .map(SocketEnd::Failed),
        );
        for end in ends {
            let mut harness = Harness::new();
            harness.run(UpdatesInput::Start);
            let outputs = harness.end(end.clone());
            let Some(ConnectionState::Failed { error }) = last_state(&outputs) else {
                panic!("{end:?} should not reconnect: {outputs:?}");
            };
            assert!(!error.is_retryable());
            if matches!(end, SocketEnd::HandshakeRejected { status: 401 }) {
                assert!(error.requires_sign_in());
            }
            assert_eq!(connects(&outputs), []);
            assert_eq!(timer(&outputs, TimerKind::Reconnect), None);
        }

        // By contrast a gateway error during a restart retries.
        let mut harness = Harness::new();
        harness.run(UpdatesInput::Start);
        let outputs = harness.end(SocketEnd::HandshakeRejected { status: 502 });
        assert_eq!(
            timer(&outputs, TimerKind::Reconnect).map(|(_, d)| d),
            Some(125)
        );
    }

    #[test]
    fn silence_watchdog_reconnects_after_70_s_without_a_frame() {
        let mut harness = Harness::new();
        let start = harness.run(UpdatesInput::Start);
        let (first, _) = timer(&start, TimerKind::Watchdog).unwrap();
        harness.open();
        harness.now += 40_000;
        harness.recv(&json!({"type": "snapshot", "items": []}));
        harness.now += 30_000;
        let outputs = harness.run(UpdatesInput::TimerFired { token: first });
        let (second, remaining) = timer(&outputs, TimerKind::Watchdog).unwrap();
        assert_eq!(remaining, 40_000);
        harness.now += 40_000;
        let attempt = harness.attempt();
        let outputs = harness.run(UpdatesInput::TimerFired { token: second });
        assert_eq!(
            outputs[0],
            UpdatesOutput::Close {
                attempt,
                code: 1001,
                reason: "client reconnecting".into()
            }
        );
        assert_eq!(
            last_state(&outputs),
            Some(&ConnectionState::Reconnecting {
                reason: LinkError::Stalled { silent_ms: 70_000 },
                failures: 0,
                delay_ms: 0
            })
        );
        assert_eq!(connects(&outputs), [AttemptId(2)]);
    }

    #[test]
    fn heartbeats_keep_the_socket_alive_without_being_forwarded() {
        let mut harness = Harness::new();
        harness.live();
        assert_eq!(harness.recv(&json!({"type": "heartbeat"})), []);
    }

    #[test]
    fn policy_violation_close_requires_sign_in_and_other_closes_reconnect() {
        let mut harness = Harness::new();
        harness.live();
        let outputs = harness.end(SocketEnd::Closed {
            code: 1008,
            reason: "unauthenticated".into(),
        });
        let Some(ConnectionState::Failed { error }) = last_state(&outputs) else {
            panic!("1008 is terminal: {outputs:?}");
        };
        assert!(error.requires_sign_in());

        let mut harness = Harness::new();
        harness.live();
        let outputs = harness.end(SocketEnd::Closed {
            code: 1012,
            reason: "service restart".into(),
        });
        assert!(matches!(
            last_state(&outputs),
            Some(ConnectionState::Reconnecting { .. })
        ));
    }

    #[test]
    fn reconnect_resends_the_watch_set_and_reports_resumed() {
        let mut harness = Harness::new();
        harness.machine.set_watch(["a", "b"]).unwrap();
        harness.live();
        harness.now += 10_000;
        let outputs = harness.end(SocketEnd::Failed(ConnectionFailure::Transport(
            TransportError::Offline {
                message: "lost".into(),
            },
        )));
        assert_eq!(connects(&outputs), [AttemptId(2)], "healthy loss: no wait");
        assert_eq!(
            sent(&harness.open()),
            [json!({"type": "watch", "session_ids": ["a", "b"]})]
        );
        let outputs = harness.recv(&json!({"type": "snapshot", "items": []}));
        assert!(outputs.contains(&UpdatesOutput::Live {
            attempt: AttemptId(2),
            resumed: true
        }));
    }

    #[test]
    fn inventory_and_unknown_frames_are_forwarded_and_extra_keys_ignored() {
        let mut harness = Harness::new();
        harness.live();
        let outputs = harness.recv(&json!({"type": "hosts_changed", "traceparent": "00-x"}));
        assert_eq!(frames(&outputs), [&UpdatesFrame::HostsChanged]);
        let outputs = harness.recv(&json!({"type": "projects_changed"}));
        assert_eq!(frames(&outputs), [&UpdatesFrame::ProjectsChanged]);
        let outputs = harness.recv(&json!({"type": "sessions_reordered", "order": [1]}));
        let [UpdatesFrame::Unknown { frame_type, raw }] = frames(&outputs)[..] else {
            panic!("unknown frames are forwarded: {outputs:?}");
        };
        assert_eq!(frame_type, "sessions_reordered");
        assert_eq!(raw["order"], json!([1]));
    }

    #[test]
    fn binary_frames_decode_like_text() {
        let mut harness = Harness::new();
        harness.live();
        let attempt = harness.attempt();
        let outputs = harness.run(UpdatesInput::Message {
            attempt,
            message: SocketMessage::Binary(br#"{"type":"removed","ids":["x"]}"#.to_vec()),
        });
        assert_eq!(
            frames(&outputs),
            [&UpdatesFrame::Removed {
                ids: vec!["x".into()]
            }]
        );
    }

    #[test]
    fn malformed_frames_close_and_reconnect() {
        let cases: [(SocketMessage, UpdatesError); 6] = [
            (
                SocketMessage::Text("not json".into()),
                UpdatesError::NotJson {
                    message: "expected ident at line 1 column 2".into(),
                },
            ),
            (
                SocketMessage::Text(r#"{"items": []}"#.into()),
                UpdatesError::MissingType,
            ),
            (
                SocketMessage::Text(r#"{"type": "snapshot"}"#.into()),
                UpdatesError::MissingField {
                    frame_type: "snapshot".into(),
                    field: "items",
                },
            ),
            (
                SocketMessage::Text(r#"{"type": "changed", "items": [{"status": "idle"}]}"#.into()),
                UpdatesError::InvalidElement {
                    frame_type: "changed".into(),
                    index: 0,
                    message: "row has no id".into(),
                },
            ),
            (
                SocketMessage::Text(r#"{"type": "removed", "ids": ["a", 7]}"#.into()),
                UpdatesError::InvalidElement {
                    frame_type: "removed".into(),
                    index: 1,
                    message: "id is not a string: 7".into(),
                },
            ),
            (
                SocketMessage::Binary(vec![b'{', 0xFF]),
                UpdatesError::NotUtf8 { valid_up_to: 1 },
            ),
        ];
        for (message, expected) in cases {
            assert_eq!(
                UpdatesFrame::decode_message(&message),
                Err(expected.clone())
            );
            let mut harness = Harness::new();
            let attempt = harness.live();
            let outputs = harness.run(UpdatesInput::Message { attempt, message });
            assert!(matches!(outputs[0], UpdatesOutput::Close { .. }));
            assert_eq!(
                last_state(&outputs),
                Some(&ConnectionState::Reconnecting {
                    reason: LinkError::MalformedFrame {
                        message: expected.to_string()
                    },
                    failures: 1,
                    delay_ms: 125
                })
            );
        }
    }

    #[test]
    fn discovery_beyond_the_cap_or_with_bad_ids_is_reported() {
        let mut harness = Harness::new();
        let full: Vec<String> = (1..=500).map(|n| format!("s{n}")).collect();
        harness.machine.set_watch(full).unwrap();
        harness.live();
        let outputs = harness.recv(&json!({"type": "changed", "items": [
            {"id": "s1"}, {"id": "new_1"}, {"id": "bad id"}, {"id": "new_2"}
        ]}));
        assert_eq!(sent(&outputs), Vec::<Value>::new());
        assert!(outputs.contains(&UpdatesOutput::DiscoveryNotWatched {
            ids: vec!["bad id".into()],
            error: WatchError::InvalidSessionId {
                id: "bad id".into()
            },
        }));
        assert!(outputs.contains(&UpdatesOutput::DiscoveryNotWatched {
            ids: vec!["new_1".into(), "new_2".into()],
            error: WatchError::LimitExceeded {
                requested: 502,
                limit: 500
            },
        }));
        assert_eq!(frames(&outputs).len(), 1, "the frame is still forwarded");
    }

    #[test]
    fn watch_changes_wait_for_the_open_and_unchanged_sets_send_nothing() {
        let mut harness = Harness::new();
        harness.run(UpdatesInput::Start);
        assert_eq!(harness.machine.set_watch(["b", "a"]).unwrap(), []);
        assert_eq!(
            sent(&harness.open()),
            [json!({"type": "watch", "session_ids": ["b", "a"]})]
        );
        assert_eq!(harness.machine.set_watch(["a", "b", "a"]).unwrap(), []);
        assert_eq!(
            harness.machine.set_watch(["a/b"]),
            Err(WatchError::InvalidSessionId { id: "a/b".into() })
        );
        assert_eq!(harness.machine.set_watch([""; 0]).unwrap().len(), 1);
    }

    #[test]
    fn stop_closes_and_late_inputs_are_inert() {
        let mut harness = Harness::new();
        let start = harness.run(UpdatesInput::Start);
        let (watchdog, _) = timer(&start, TimerKind::Watchdog).unwrap();
        harness.open();
        let outputs = harness.run(UpdatesInput::Stop);
        assert_eq!(
            outputs,
            [
                UpdatesOutput::Close {
                    attempt: AttemptId(1),
                    code: 1001,
                    reason: "client stopped".into()
                },
                UpdatesOutput::CancelTimer { token: watchdog },
                UpdatesOutput::StateChanged {
                    state: ConnectionState::Stopped
                },
            ]
        );
        for late in [
            UpdatesInput::Message {
                attempt: AttemptId(1),
                message: SocketMessage::Text(r#"{"type":"heartbeat"}"#.into()),
            },
            UpdatesInput::Ended {
                attempt: AttemptId(1),
                end: SocketEnd::Closed {
                    code: 1001,
                    reason: String::new(),
                },
            },
            UpdatesInput::SendFailed {
                attempt: AttemptId(1),
                error: TransportError::Cancelled,
            },
            UpdatesInput::TimerFired { token: watchdog },
        ] {
            assert_eq!(harness.run(late), []);
        }
        assert_eq!(
            harness.machine.set_watch(["x"]).unwrap(),
            [],
            "not connected"
        );
        let outputs = harness.run(UpdatesInput::Start);
        assert_eq!(connects(&outputs), [AttemptId(2)]);
    }

    fn offline() -> TransportError {
        TransportError::Offline {
            message: "no route".into(),
        }
    }

    #[test]
    fn a_failed_connect_retries_and_a_stale_one_is_ignored() {
        let mut harness = Harness::new();
        harness.run(UpdatesInput::Start);
        assert_eq!(
            harness.run(UpdatesInput::Start),
            Vec::new(),
            "already connecting"
        );
        let attempt = harness.attempt();
        let stale = harness.run(UpdatesInput::ConnectFailed {
            attempt: AttemptId(99),
            error: offline(),
        });
        assert_eq!(stale, Vec::new());
        let outputs = harness.run(UpdatesInput::ConnectFailed {
            attempt,
            error: offline(),
        });
        assert!(matches!(
            last_state(&outputs),
            Some(ConnectionState::Reconnecting { .. } | ConnectionState::Connecting)
        ));
    }

    #[test]
    fn a_reconnect_timer_starts_the_next_attempt_and_an_old_watchdog_does_nothing() {
        let mut harness = Harness::new();
        let start = harness.run(UpdatesInput::Start);
        let (old_watchdog, _) = timer(&start, TimerKind::Watchdog).unwrap();
        let attempt = harness.attempt();
        let outputs = harness.run(UpdatesInput::ConnectFailed {
            attempt,
            error: offline(),
        });
        let (token, _) = timer(&outputs, TimerKind::Reconnect).unwrap();
        let next = harness.run(UpdatesInput::TimerFired { token });
        assert_eq!(connects(&next).len(), 1);
        assert_eq!(
            harness.run(UpdatesInput::TimerFired {
                token: old_watchdog
            }),
            Vec::new()
        );
    }

    #[test]
    fn an_open_reported_twice_ends_the_attempt() {
        let mut harness = Harness::new();
        harness.run(UpdatesInput::Start);
        harness.open();
        let outputs = harness.open();
        assert!(matches!(
            last_state(&outputs),
            Some(ConnectionState::Failed {
                error: LinkError::HostContract { .. }
            })
        ));
    }

    #[test]
    fn a_snapshot_with_new_sessions_widens_the_watch() {
        let mut harness = Harness::new();
        harness.run(UpdatesInput::Start);
        harness.open();
        let outputs = harness.recv(&json!({"type": "snapshot", "items": [{"id": "conv_new"}]}));
        assert_eq!(
            sent(&outputs).iter().map(ids_of).collect::<Vec<_>>(),
            [["conv_new".to_owned()]]
        );
    }

    #[test]
    fn frames_of_the_wrong_shape_reconnect() {
        for frame in [
            json!(7),
            json!({"type": "changed", "items": [7]}),
            json!({"type": "changed", "items": [{"id": 7}]}),
        ] {
            let mut harness = Harness::new();
            harness.live();
            let outputs = harness.recv(&frame);
            assert!(
                matches!(outputs[0], UpdatesOutput::Close { .. }),
                "{frame}: {outputs:?}"
            );
        }
    }

    #[test]
    fn a_stall_with_a_clock_that_went_backward_only_re_arms_the_watchdog() {
        let mut harness = Harness::new();
        let start = harness.run(UpdatesInput::Start);
        let (watchdog, _) = timer(&start, TimerKind::Watchdog).unwrap();
        harness.open();
        harness.now = 0;
        let outputs = harness.run(UpdatesInput::TimerFired { token: watchdog });
        let (_, delay) = timer(&outputs, TimerKind::Watchdog).unwrap();
        assert_eq!(delay, UpdatesConfig::default().silence_timeout_ms);
        assert!(last_state(&outputs).is_none());
    }

    #[test]
    fn send_failures_and_host_contract_violations_end_the_attempt() {
        let mut harness = Harness::new();
        let attempt = harness.live();
        let outputs = harness.run(UpdatesInput::SendFailed {
            attempt,
            error: TransportError::Other {
                message: "socket closed".into(),
            },
        });
        assert!(matches!(outputs[0], UpdatesOutput::Close { .. }));
        assert!(matches!(
            last_state(&outputs),
            Some(ConnectionState::Reconnecting {
                reason: LinkError::SendFailed(_),
                ..
            })
        ));

        let mut harness = Harness::new();
        harness.run(UpdatesInput::Start);
        let outputs = harness.recv(&json!({"type": "heartbeat"}));
        assert!(matches!(
            last_state(&outputs),
            Some(ConnectionState::Failed {
                error: LinkError::HostContract { .. }
            })
        ));
    }

    #[test]
    fn watch_set_codec() {
        let watch = WatchSet::new(["b", "a", "b"]).unwrap();
        assert_eq!(watch.ids(), ["b", "a"]);
        assert_eq!(
            serde_json::from_str::<Value>(&watch.to_message()).unwrap(),
            json!({"type": "watch", "session_ids": ["b", "a"]})
        );
        assert!(watch.same_sessions(&WatchSet::new(["a", "b"]).unwrap()));
        assert!(!watch.same_sessions(&WatchSet::new(["a"]).unwrap()));
        assert!(is_valid_session_id("conv_A-1"));
        assert!(!is_valid_session_id(""));
        assert!(!is_valid_session_id("é"));
        assert_eq!(
            WatchSet::new(["ok", ""]),
            Err(WatchError::InvalidSessionId { id: String::new() })
        );
    }
}
