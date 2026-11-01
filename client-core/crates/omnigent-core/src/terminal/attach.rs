//! The attach connection state machine.
//!
//! [`TerminalAttach`] drives one interactive (or read-only) attach to one terminal over the host's
//! [`crate::realtime::WebSocketTransport`]. Like the session-updates machine it is pure and
//! time-injected: the driver feeds it [`AttachInput`]s tagged with `now_ms` and executes the
//! [`AttachOutput`]s it returns, in order. Attempt ids and timer tokens follow the rules in the
//! [realtime module docs](crate::realtime).
//!
//! # Close codes
//!
//! The server ends an attach with an application close code
//! (`omnigent/terminals/ws_common.py`) or a transport-shaped one. The machine classifies them the
//! way the web client does (`isUnexpectedTerminalClose` and `TerminalView.tsx`):
//!
//! | Code | Meaning | Result |
//! |---|---|---|
//! | 1001, 1005, 1006, 1011–1014 | proxy or server restart, dead TCP | [`AttachState::Reconnecting`] with backoff |
//! | 1008 | unauthenticated, or not allowed to type (non-owner) | [`AttachFailure::AuthenticationRequired`] / [`AttachFailure::AccessDenied`] |
//! | 4400 | wrong replica for the slice key | one immediate redial without the key, then [`AttachFailure::WrongReplica`] |
//! | 4404 | terminal gone or not running | [`AttachState::Closed`] with [`ClosedReason::TerminalEnded`] |
//! | 4405 | tmux client detached, terminal still alive | [`AttachState::Closed`] with [`ClosedReason::Detached`] |
//! | 4500 | server-side bridge failure | [`AttachFailure::ServerError`] |
//! | 1000 and anything else | the server ended the attach on purpose | [`AttachState::Closed`] with [`ClosedReason::ServerClosed`] |
//!
//! A handshake answered 401 needs sign-in; 403 is access denied; 3xx, TLS failures and platform
//! cancellation are terminal; 404 retries a bounded number of times; everything else reconnects.
//! Reconnects use the shared [`crate::realtime::backoff`] ramp with the web client's terminal
//! budget: about five minutes of attempts, after which the attach fails with
//! [`AttachFailure::ReconnectBudgetExhausted`] until the user retries or the app returns to the
//! foreground ([`AttachInput::Foreground`]).
//!
//! # Screen state across reconnects
//!
//! The server seeds every attach with `capture-pane` of the visible screen, then streams live
//! output. A reattach therefore starts with [`AttachOutput::ResetScreen`]: the renderer clears its
//! screen (scrollback from the previous attach is not replayed) before applying the new seed.
//!
//! # Input and resize
//!
//! [`AttachInput::Input`] is sent as a binary frame while attached. Input while not attached, or
//! on a read-only attach, is reported with [`AttachOutput::InputDropped`]: keystrokes typed into a
//! dead socket are never buffered and replayed into whatever the terminal shows later.
//! [`AttachInput::Resize`] records the grid size and sends it once per change; every new attach
//! sends the latest size first, before any input, so tmux renders at the right size at once.

use serde_json::{Map, Value};

use super::codec::{ClientFrame, FrameError, GridSize, ServerFrame};
use super::rest::AttachOptions;
use crate::http::TransportError;
use crate::realtime::backoff::{BackoffConfig, JitterSource, Retry, RetryConfig, RetryDecision};
use crate::realtime::link::{AttemptId, Ids, LinkError, TimerKind, TimerToken};
use crate::realtime::{ConnectionFailure, SocketEnd, SocketMessage};

/// Close code the client sends when the user detaches.
pub const CLIENT_DETACH_CODE: u16 = 1000;
/// The server's "terminal not found or session ended" close code.
pub const CLOSE_TERMINAL_NOT_FOUND: u16 = 4404;
/// The server's "control client detached, terminal still alive" close code.
pub const CLOSE_TERMINAL_DETACHED: u16 = 4405;
/// The server's "wrong replica for this slice key" close code.
pub const CLOSE_WRONG_REPLICA: u16 = 4400;
/// The server's internal-error close code.
pub const CLOSE_INTERNAL_ERROR: u16 = 4500;
/// Policy violation: unauthenticated or not authorized.
pub const CLOSE_POLICY_VIOLATION: u16 = 1008;

/// Whether `code` is a transport-shaped close worth reconnecting after.
#[must_use]
pub const fn is_transport_close(code: u16) -> bool {
    matches!(code, 1001 | 1005 | 1006 | 1011 | 1012 | 1013 | 1014)
}

/// Tunables for [`TerminalAttach`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AttachConfig {
    /// Reconnect policy.
    pub retry: RetryConfig,
    /// Consecutive failed reconnects before the attach gives up.
    pub max_reconnects: u32,
}

impl Default for AttachConfig {
    /// The web client's terminal schedule (`RECONNECT_BACKOFF_MS` and `RECONNECT_STABLE_MS` in
    /// `web/src/components/blocks/TerminalView.tsx`), expressed on the shared jittered ramp:
    /// 0.5 s doubling to a 30 s cap, 15 attempts (about five minutes), and a fresh budget after an
    /// attach that stayed up for 30 s.
    fn default() -> Self {
        Self {
            retry: RetryConfig {
                backoff: BackoffConfig {
                    base_ms: 500,
                    max_ms: 30_000,
                },
                healthy_after_ms: 30_000,
                max_not_found_retries: 10,
            },
            max_reconnects: 15,
        }
    }
}

/// Why the terminal attach closed without an error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClosedReason {
    /// 4404: the terminal is gone or not running (its process exited, or it was deleted).
    TerminalEnded {
        /// The server's close reason.
        reason: String,
    },
    /// 4405: this attach was detached; the terminal still runs and can be reattached.
    Detached {
        /// The server's close reason.
        reason: String,
    },
    /// The server closed the attach on purpose with another code.
    ServerClosed {
        /// The close code.
        code: u16,
        /// The close reason.
        reason: String,
    },
}

/// A failure that stops the attach until the caller starts it again.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AttachFailure {
    /// The credentials were missing or rejected (401, an auth challenge, or 1008
    /// "authentication required"). Sign in again.
    #[error("sign in again to attach to this terminal: {detail}")]
    AuthenticationRequired {
        /// What the server or platform said.
        detail: String,
    },
    /// The caller may not attach this way (403, or 1008 "not authorized"). An interactive attach
    /// needs session owner access; a read-only attach needs read access.
    #[error("not allowed to attach to this terminal: {detail}")]
    AccessDenied {
        /// What the server said.
        detail: String,
        /// Whether the denied attach was already read-only. When it was not, a read-only attach
        /// may still be allowed.
        read_only: bool,
    },
    /// 4500: the server's bridge failed.
    #[error("the server could not attach the terminal: {reason}")]
    ServerError {
        /// The close reason.
        reason: String,
    },
    /// 4400 again after redialling without the slice key.
    #[error("no server replica could reach this terminal's host")]
    WrongReplica,
    /// The reconnect budget ran out.
    #[error("lost the terminal connection after {attempts} reconnect attempts: {last}")]
    ReconnectBudgetExhausted {
        /// Why the last attempt ended.
        last: LinkError,
        /// Attempts made.
        attempts: u32,
    },
    /// A failure retrying cannot fix: a redirect, TLS, platform cancellation, a run of 404s, or a
    /// host contract violation.
    #[error("{0}")]
    Unrecoverable(LinkError),
}

impl AttachFailure {
    /// Whether the user must sign in again.
    #[must_use]
    pub const fn requires_sign_in(&self) -> bool {
        matches!(self, Self::AuthenticationRequired { .. })
    }
}

/// The user-visible attach state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttachState {
    /// Never started.
    Idle,
    /// The first attempt since [`AttachInput::Start`] is in flight.
    Connecting,
    /// The socket is open and the terminal is streaming.
    Attached {
        /// Whether input is disabled.
        read_only: bool,
    },
    /// The connection was lost; another attempt is pending or in flight.
    Reconnecting {
        /// Why the last attempt ended.
        reason: LinkError,
        /// Consecutive failed attempts, 0 after a healthy attach (which redials at once).
        failures: u32,
        /// The wait before the next attempt, in ms.
        delay_ms: u64,
    },
    /// The server ended the attach deliberately. Nothing reconnects until the caller starts
    /// again.
    Closed {
        /// Why.
        reason: ClosedReason,
    },
    /// The caller detached.
    Stopped,
    /// A failure. Nothing reconnects until the caller starts again (or, for an exhausted
    /// budget, the app returns to the foreground).
    Failed {
        /// The failure.
        error: AttachFailure,
    },
}

/// Why input was not sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DropReason {
    /// The socket is not open.
    NotAttached,
    /// The attach is read-only.
    ReadOnly,
}

/// Inputs to [`TerminalAttach::handle`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttachInput {
    /// Attach, or reattach after `Closed`, `Stopped` or `Failed`, with a fresh reconnect budget.
    /// Nothing happens while already connecting, attached or reconnecting.
    Start,
    /// Detach and close the socket.
    Stop,
    /// The app (or window) became visible. A pending reconnect dials now, and an exhausted
    /// budget starts over, as the web client does on `visibilitychange`.
    Foreground,
    /// Bytes the user typed, pasted or produced with the mouse, already encoded by the renderer.
    Input {
        /// The bytes.
        bytes: Vec<u8>,
    },
    /// The renderer's grid size changed.
    Resize {
        /// The new size.
        size: GridSize,
    },
    /// [`crate::realtime::WebSocketTransport::connect`] resolved `Err`.
    ConnectFailed {
        /// The attempt.
        attempt: AttemptId,
        /// The host's error.
        error: TransportError,
    },
    /// [`crate::realtime::MessageSink::opened`].
    Opened {
        /// The attempt.
        attempt: AttemptId,
    },
    /// [`crate::realtime::MessageSink::message`].
    Message {
        /// The attempt.
        attempt: AttemptId,
        /// The frame.
        message: SocketMessage,
    },
    /// [`crate::realtime::MessageSink::ended`].
    Ended {
        /// The attempt.
        attempt: AttemptId,
        /// How it ended.
        end: SocketEnd,
    },
    /// Sending an [`AttachOutput::Send`] failed.
    SendFailed {
        /// The attempt it was sent on.
        attempt: AttemptId,
        /// The host's error.
        error: TransportError,
    },
    /// A timer scheduled with [`AttachOutput::ScheduleTimer`] fired.
    TimerFired {
        /// Its token.
        token: TimerToken,
    },
}

/// Work for the driver, in execution order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttachOutput {
    /// Build the upgrade request with [`super::TerminalEndpoint::attach_request`] and these
    /// options (fresh credentials), and connect it with a sink for `attempt`.
    Connect {
        /// The new attempt.
        attempt: AttemptId,
        /// The options for this attempt; the slice key is dropped after a 4400 close.
        options: AttachOptions,
    },
    /// Send `message` (binary input or a text control frame) on `attempt`'s socket. Report a
    /// failure with [`AttachInput::SendFailed`].
    Send {
        /// The attempt.
        attempt: AttemptId,
        /// The frame.
        message: SocketMessage,
    },
    /// Close `attempt`'s socket, or cancel its handshake.
    Close {
        /// The attempt.
        attempt: AttemptId,
        /// The close code.
        code: u16,
        /// The close reason.
        reason: String,
    },
    /// Deliver [`AttachInput::TimerFired`] with `token` after `delay_ms`.
    ScheduleTimer {
        /// The token.
        token: TimerToken,
        /// The delay from the current `now_ms`.
        delay_ms: u64,
    },
    /// The timer `token` is no longer needed.
    CancelTimer {
        /// The token.
        token: TimerToken,
    },
    /// The public state changed.
    StateChanged {
        /// The new state.
        state: AttachState,
    },
    /// A reattach is starting: clear the renderer's screen before the next output (the server's
    /// seed of the current screen).
    ResetScreen,
    /// Pane output for the renderer.
    Output {
        /// The bytes.
        bytes: Vec<u8>,
    },
    /// The queries tmux answers itself on this attach.
    TmuxReplies {
        /// Query identifiers.
        queries: Vec<String>,
    },
    /// tmux copied a selection: offer it to the local clipboard.
    ClipboardWrite {
        /// UTF-8 bytes.
        data: Vec<u8>,
    },
    /// A control frame this client does not know. Log it.
    UnknownFrame {
        /// Its `type`.
        frame_type: String,
        /// The frame.
        raw: Map<String, Value>,
    },
    /// A control frame that could not be decoded. The attach continues; log it.
    FrameRejected {
        /// Why.
        error: FrameError,
    },
    /// Input that was not sent. Show it (for example "Not connected" or "Read-only").
    InputDropped {
        /// How many bytes.
        len: usize,
        /// Why.
        reason: DropReason,
    },
}

#[derive(Debug, Clone)]
struct Attempt {
    id: AttemptId,
    opened_at_ms: Option<u64>,
    sent_size: Option<GridSize>,
}

/// What ended an attempt, after close-code classification.
enum Loss {
    /// Reconnect per the retry policy.
    Retry(LinkError),
    /// Stop with a failure.
    Fail(AttachFailure),
    /// Stop with a deliberate close.
    Close(ClosedReason),
    /// Redial now without the slice key.
    Keyless(LinkError),
}

/// Pure state machine for one terminal attach. See the [module docs](self).
#[derive(Debug, Clone)]
pub struct TerminalAttach<J> {
    config: AttachConfig,
    options: AttachOptions,
    keyless: bool,
    jitter: J,
    ids: Ids,
    retry: Retry,
    state: AttachState,
    attempt: Option<Attempt>,
    reconnect_timer: Option<TimerToken>,
    size: Option<GridSize>,
    ever_attached: bool,
}

impl<J: JitterSource> TerminalAttach<J> {
    /// An idle machine for an attach with `options`.
    pub fn new(config: AttachConfig, options: AttachOptions, jitter: J) -> Self {
        Self {
            retry: Retry::new(config.retry),
            config,
            options,
            keyless: false,
            jitter,
            ids: Ids::default(),
            state: AttachState::Idle,
            attempt: None,
            reconnect_timer: None,
            size: None,
            ever_attached: false,
        }
    }

    /// The current state.
    pub const fn state(&self) -> &AttachState {
        &self.state
    }

    /// The attempt in flight, if any.
    pub fn current_attempt(&self) -> Option<AttemptId> {
        self.attempt.as_ref().map(|attempt| attempt.id)
    }

    /// The last grid size the renderer reported.
    pub const fn grid_size(&self) -> Option<GridSize> {
        self.size
    }

    /// Applies one input at `now_ms` and returns the work it causes, in order.
    pub fn handle(&mut self, now_ms: u64, input: AttachInput) -> Vec<AttachOutput> {
        let mut out = Vec::new();
        match input {
            AttachInput::Start => self.start(now_ms, &mut out),
            AttachInput::Stop => self.stop(&mut out),
            AttachInput::Foreground => self.foreground(now_ms, &mut out),
            AttachInput::Input { bytes } => self.input(bytes, &mut out),
            AttachInput::Resize { size } => {
                self.size = Some(size);
                self.send_size(&mut out);
            }
            AttachInput::ConnectFailed { attempt, error } => {
                if self.is_current(attempt) {
                    let loss = connection_loss(ConnectionFailure::Transport(error));
                    self.lose(now_ms, loss, false, &mut out);
                }
            }
            AttachInput::Opened { attempt } => {
                if self.is_current(attempt) {
                    self.opened(now_ms, &mut out);
                }
            }
            AttachInput::Message { attempt, message } => {
                if self.is_current(attempt) {
                    self.message(now_ms, message, &mut out);
                }
            }
            AttachInput::Ended { attempt, end } => {
                if self.is_current(attempt) {
                    let loss = self.classify_end(end);
                    self.lose(now_ms, loss, false, &mut out);
                }
            }
            AttachInput::SendFailed { attempt, error } => {
                if self.is_current(attempt) {
                    let loss = Loss::Retry(LinkError::SendFailed(error));
                    self.lose(now_ms, loss, true, &mut out);
                }
            }
            AttachInput::TimerFired { token } => {
                if self.reconnect_timer == Some(token) {
                    self.reconnect_timer = None;
                    self.connect(&mut out);
                }
            }
        }
        out
    }

    fn is_current(&self, attempt: AttemptId) -> bool {
        self.current_attempt() == Some(attempt)
    }

    const fn is_running(&self) -> bool {
        matches!(
            self.state,
            AttachState::Connecting
                | AttachState::Attached { .. }
                | AttachState::Reconnecting { .. }
        )
    }

    fn start(&mut self, _now_ms: u64, out: &mut Vec<AttachOutput>) {
        if self.is_running() {
            return;
        }
        self.retry.reset();
        self.keyless = false;
        self.set_state(AttachState::Connecting, out);
        self.connect(out);
    }

    fn stop(&mut self, out: &mut Vec<AttachOutput>) {
        self.end_attempt(Some("client detached"), out);
        if let Some(token) = self.reconnect_timer.take() {
            out.push(AttachOutput::CancelTimer { token });
        }
        self.set_state(AttachState::Stopped, out);
    }

    fn foreground(&mut self, now_ms: u64, out: &mut Vec<AttachOutput>) {
        match &self.state {
            AttachState::Reconnecting { .. } => {
                if let Some(token) = self.reconnect_timer.take() {
                    out.push(AttachOutput::CancelTimer { token });
                    self.connect(out);
                }
            }
            AttachState::Failed {
                error: AttachFailure::ReconnectBudgetExhausted { .. },
            } => self.start(now_ms, out),
            _ => {}
        }
    }

    fn input(&self, bytes: Vec<u8>, out: &mut Vec<AttachOutput>) {
        if bytes.is_empty() {
            return;
        }
        let attempt = self
            .attempt
            .as_ref()
            .filter(|attempt| attempt.opened_at_ms.is_some());
        let reason = match (attempt, self.options.read_only) {
            (Some(attempt), false) => {
                out.push(AttachOutput::Send {
                    attempt: attempt.id,
                    message: ClientFrame::Input(bytes).encode(),
                });
                return;
            }
            (Some(_), true) => DropReason::ReadOnly,
            (None, _) => DropReason::NotAttached,
        };
        out.push(AttachOutput::InputDropped {
            len: bytes.len(),
            reason,
        });
    }

    fn send_size(&mut self, out: &mut Vec<AttachOutput>) {
        let Some(size) = self.size else {
            return;
        };
        let Some(attempt) = self
            .attempt
            .as_mut()
            .filter(|attempt| attempt.opened_at_ms.is_some())
        else {
            return;
        };
        if attempt.sent_size == Some(size) {
            return;
        }
        attempt.sent_size = Some(size);
        out.push(AttachOutput::Send {
            attempt: attempt.id,
            message: ClientFrame::Resize(size).encode(),
        });
    }

    fn opened(&mut self, now_ms: u64, out: &mut Vec<AttachOutput>) {
        let Some(attempt) = self.attempt.as_mut() else {
            return;
        };
        if attempt.opened_at_ms.is_some() {
            let loss = Loss::Fail(AttachFailure::Unrecoverable(LinkError::HostContract {
                message: "opened was reported twice for one socket".to_owned(),
            }));
            self.lose(now_ms, loss, true, out);
            return;
        }
        attempt.opened_at_ms = Some(now_ms);
        self.retry.on_live();
        self.set_state(
            AttachState::Attached {
                read_only: self.options.read_only,
            },
            out,
        );
        if self.ever_attached {
            out.push(AttachOutput::ResetScreen);
        }
        self.ever_attached = true;
        self.send_size(out);
    }

    fn message(&mut self, now_ms: u64, message: SocketMessage, out: &mut Vec<AttachOutput>) {
        if self
            .attempt
            .as_ref()
            .is_some_and(|attempt| attempt.opened_at_ms.is_none())
        {
            let loss = Loss::Fail(AttachFailure::Unrecoverable(LinkError::HostContract {
                message: "a message arrived before the socket opened".to_owned(),
            }));
            self.lose(now_ms, loss, true, out);
            return;
        }
        out.push(match ServerFrame::decode(message) {
            Ok(ServerFrame::Output(bytes)) => AttachOutput::Output { bytes },
            Ok(ServerFrame::TmuxReplies { queries }) => AttachOutput::TmuxReplies { queries },
            Ok(ServerFrame::ClipboardWrite { data }) => AttachOutput::ClipboardWrite { data },
            Ok(ServerFrame::Unknown { frame_type, raw }) => {
                AttachOutput::UnknownFrame { frame_type, raw }
            }
            Err(error) => AttachOutput::FrameRejected { error },
        });
    }

    fn classify_end(&self, end: SocketEnd) -> Loss {
        match end {
            SocketEnd::Closed { code, reason } => self.classify_close(code, reason),
            SocketEnd::HandshakeRejected { status } => match status {
                401 => Loss::Fail(AttachFailure::AuthenticationRequired {
                    detail: "the server answered the attach with HTTP 401".to_owned(),
                }),
                403 => Loss::Fail(AttachFailure::AccessDenied {
                    detail: "the server answered the attach with HTTP 403".to_owned(),
                    read_only: self.options.read_only,
                }),
                status => Loss::Retry(LinkError::HttpStatus { status }),
            },
            SocketEnd::Failed(failure) => connection_loss(failure),
        }
    }

    fn classify_close(&self, code: u16, reason: String) -> Loss {
        match code {
            CLOSE_TERMINAL_NOT_FOUND => Loss::Close(ClosedReason::TerminalEnded { reason }),
            CLOSE_TERMINAL_DETACHED => Loss::Close(ClosedReason::Detached { reason }),
            CLOSE_INTERNAL_ERROR => Loss::Fail(AttachFailure::ServerError { reason }),
            CLOSE_WRONG_REPLICA => {
                if self.options.slice_key.is_some() && !self.keyless {
                    Loss::Keyless(LinkError::SocketClosed { code, reason })
                } else {
                    Loss::Fail(AttachFailure::WrongReplica)
                }
            }
            CLOSE_POLICY_VIOLATION => {
                if reason == "authentication required" {
                    Loss::Fail(AttachFailure::AuthenticationRequired { detail: reason })
                } else {
                    Loss::Fail(AttachFailure::AccessDenied {
                        detail: reason,
                        read_only: self.options.read_only,
                    })
                }
            }
            code if is_transport_close(code) => {
                Loss::Retry(LinkError::SocketClosed { code, reason })
            }
            code => Loss::Close(ClosedReason::ServerClosed { code, reason }),
        }
    }

    fn connect(&mut self, out: &mut Vec<AttachOutput>) {
        let id = self.ids.attempt();
        self.attempt = Some(Attempt {
            id,
            opened_at_ms: None,
            sent_size: None,
        });
        let mut options = self.options.clone();
        if self.keyless {
            options.slice_key = None;
        }
        out.push(AttachOutput::Connect {
            attempt: id,
            options,
        });
    }

    /// Drops the current attempt, closing its socket with `close_reason` if given. Returns when
    /// it opened, if it did.
    fn end_attempt(
        &mut self,
        close_reason: Option<&str>,
        out: &mut Vec<AttachOutput>,
    ) -> Option<u64> {
        let attempt = self.attempt.take()?;
        if let Some(reason) = close_reason {
            out.push(AttachOutput::Close {
                attempt: attempt.id,
                code: CLIENT_DETACH_CODE,
                reason: reason.to_owned(),
            });
        }
        attempt.opened_at_ms
    }

    fn lose(&mut self, now_ms: u64, loss: Loss, close: bool, out: &mut Vec<AttachOutput>) {
        if self.attempt.is_none() {
            return;
        }
        let live_for_ms = self
            .end_attempt(close.then_some("client reconnecting"), out)
            .map(|opened_at| now_ms.saturating_sub(opened_at));
        let error = match loss {
            Loss::Fail(error) => return self.set_state(AttachState::Failed { error }, out),
            Loss::Close(reason) => return self.set_state(AttachState::Closed { reason }, out),
            Loss::Keyless(reason) => {
                self.keyless = true;
                self.set_state(
                    AttachState::Reconnecting {
                        reason,
                        failures: 0,
                        delay_ms: 0,
                    },
                    out,
                );
                return self.connect(out);
            }
            Loss::Retry(error) => error,
        };
        match self.retry.after_loss(&error, live_for_ms, &mut self.jitter) {
            RetryDecision::GiveUp => self.set_state(
                AttachState::Failed {
                    error: AttachFailure::Unrecoverable(error),
                },
                out,
            ),
            RetryDecision::Reconnect { failures, .. } if failures > self.config.max_reconnects => {
                self.set_state(
                    AttachState::Failed {
                        error: AttachFailure::ReconnectBudgetExhausted {
                            last: error,
                            attempts: failures - 1,
                        },
                    },
                    out,
                );
            }
            RetryDecision::Reconnect { delay_ms, failures } => {
                self.set_state(
                    AttachState::Reconnecting {
                        reason: error,
                        failures,
                        delay_ms,
                    },
                    out,
                );
                if delay_ms == 0 {
                    self.connect(out);
                } else {
                    let token = self.ids.timer(TimerKind::Reconnect);
                    self.reconnect_timer = Some(token);
                    out.push(AttachOutput::ScheduleTimer { token, delay_ms });
                }
            }
        }
    }

    fn set_state(&mut self, state: AttachState, out: &mut Vec<AttachOutput>) {
        if self.state != state {
            self.state = state.clone();
            out.push(AttachOutput::StateChanged { state });
        }
    }
}

fn connection_loss(failure: ConnectionFailure) -> Loss {
    match failure {
        ConnectionFailure::AuthenticationRequired { message } => {
            Loss::Fail(AttachFailure::AuthenticationRequired { detail: message })
        }
        failure @ ConnectionFailure::Transport(_) => Loss::Retry(LinkError::Connection(failure)),
    }
}

#[cfg(test)]
#[path = "attach_tests.rs"]
mod tests;
