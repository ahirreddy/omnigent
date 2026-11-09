//! The remote browser attach state machine.
//!
//! [`RemoteBrowserAttach`] drives one attach to one remote tab over the host's
//! [`crate::realtime::WebSocketTransport`], like [`crate::terminal::TerminalAttach`]: it is pure
//! and time-injected, the driver feeds it [`AttachInput`]s tagged with `now_ms` and executes the
//! [`AttachOutput`]s in order. Attempt ids and timer tokens follow the rules in the
//! [realtime module docs](crate::realtime). The protocol is section 5 of
//! `apps/apple/docs/remote-browser-design.md`.
//!
//! - **Setup.** On open the machine sends the client `hello`. The attach is
//!   [`ConnectionState::Attached`] once the host's `hello` arrives with protocol 1; another
//!   version closes with 4426.
//! - **Acks.** Every binary frame whose `seq` can be read is acked on receipt, before any
//!   conversion, so a slow renderer never stalls the host's window.
//! - **Video.** H.264 access units become AVCC [`VideoFrame`]s through a [`VideoTrack`], which
//!   asks for a keyframe (once per gap) when a delta cannot be decoded.
//! - **Liveness.** A `ping` goes out every 10 s; 30 s without any inbound frame closes the socket
//!   and reconnects.
//! - **Control.** Holder-gated input is sent only while this connection holds control, and is
//!   otherwise reported as [`DropReason::NotInControl`]. The user's wish to control survives a
//!   reconnect: during the host's grace period the machine sends `take` again.
//! - **Viewport (v1.1).** The client states the viewport it wants with
//!   [`AttachInput::SetViewport`]; the machine sends it (scoped to this connection's control)
//!   whenever this connection holds control and the host's viewport differs, and restores the
//!   agent's viewport for `None`. A v1 host gets plain `resize`s, and the machine restores the
//!   agent's viewport itself before `release` (design doc section 16.7).
//! - **Close codes** follow section 5.8: transport-shaped codes and 1013 reconnect with the
//!   terminal backoff, 4404 ends the tab, 4400 redials once without the slice key, and the rest
//!   fail or close.

use omnigent_protocol::remote_browser::{
    AttachMode, ClientHello, ClientMessage, ControlOp, ControlReason, DialogReply, EditCommand,
    EditOp, HeaderError, Holder, HostError, HostMessage, ImeEvent, KeyEvent, KeyframeReason,
    MediaKind, MessageError, MobileEmulation, MouseEvent, MouseKind, NavCommand, Owner,
    PROTOCOL_VERSION, ResizeRequest, SettingsUpdate, StillKind, TabClosedReason, TouchEvent,
    Viewport, ViewportScope, decode_frame, features,
};

use super::codec::{VideoDrop, VideoFrame, VideoOutcome, VideoTrack};
use super::input::{
    DEFAULT_INTERVAL_MS, InputCoalescer, InputError, validate_edit, validate_ime, validate_key,
    validate_mouse, validate_nav, validate_touch, validate_viewport,
};
use super::state::TabState;
use crate::http::TransportError;
use crate::realtime::backoff::{BackoffConfig, JitterSource, Retry, RetryConfig, RetryDecision};
use crate::realtime::link::{AttemptId, LinkError};
use crate::realtime::{ConnectionFailure, SocketEnd, SocketMessage};
use crate::terminal::is_transport_close;

/// Close code for a normal close (detach, or a deliberate end).
pub const CLOSE_NORMAL: u16 = 1000;
/// Protocol violation.
pub const CLOSE_PROTOCOL_ERROR: u16 = 1002;
/// Unauthenticated or not authorized.
pub const CLOSE_POLICY_VIOLATION: u16 = 1008;
/// Frame too large.
pub const CLOSE_TOO_BIG: u16 = 1009;
/// The viewer stalled (try again later).
pub const CLOSE_TRY_AGAIN_LATER: u16 = 1013;
/// Wrong replica for the slice key.
pub const CLOSE_WRONG_REPLICA: u16 = 4400;
/// `mode=control` not permitted.
pub const CLOSE_CONTROL_NOT_PERMITTED: u16 = 4403;
/// Tab or session gone.
pub const CLOSE_TAB_GONE: u16 = 4404;
/// Protocol version unsupported.
pub const CLOSE_PROTOCOL_UNSUPPORTED: u16 = 4426;
/// Server-side relay failure.
pub const CLOSE_SERVER_ERROR: u16 = 4500;

/// Options for one attach.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachOptions {
    /// `view` or `control` (`?mode=`).
    pub mode: AttachMode,
    /// The session's host id, sent as `omnigent_slice_key`. Dropped after a 4400 close.
    pub slice_key: Option<String>,
}

/// Tunables for [`RemoteBrowserAttach`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachConfig {
    /// Reconnect policy.
    pub retry: RetryConfig,
    /// Consecutive failed reconnects before the attach gives up.
    pub max_reconnects: u32,
    /// How often to ping.
    pub ping_interval_ms: u64,
    /// Inbound silence that ends the connection.
    pub silence_timeout_ms: u64,
    /// Mouse move and wheel coalescing interval.
    pub input_interval_ms: u64,
    /// The `client` string of the client `hello`.
    pub client_name: String,
}

impl Default for AttachConfig {
    /// The terminal attach schedule (0.5 s doubling to 30 s, 15 attempts), 10 s pings, a 30 s
    /// watchdog and 16 ms input coalescing.
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
            ping_interval_ms: 10_000,
            silence_timeout_ms: 30_000,
            input_interval_ms: DEFAULT_INTERVAL_MS,
            client_name: concat!("omnigent-core/", env!("CARGO_PKG_VERSION")).to_owned(),
        }
    }
}

/// What a timer is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TimerKind {
    /// The wait before the next connection attempt.
    Reconnect,
    /// The next `ping`.
    Ping,
    /// The silence check.
    Watchdog,
    /// The coalesced mouse flush.
    InputFlush,
}

/// Identifies one scheduled timer. A fired token the machine no longer expects is dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TimerToken {
    /// What it is for.
    pub kind: TimerKind,
    /// Unique per machine.
    pub id: u64,
}

/// Why the attach closed without an error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClosedReason {
    /// 4404: the tab is gone.
    TabEnded {
        /// What `tab_closed` said, when it came first.
        reason: Option<TabClosedReason>,
        /// The close reason.
        detail: String,
    },
    /// The server or host closed the attach on purpose with another code.
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
    /// Sign in again (401, an auth challenge, or 1008 "authentication required").
    #[error("sign in again to view this browser tab: {detail}")]
    AuthenticationRequired {
        /// What the server or platform said.
        detail: String,
    },
    /// Not allowed to attach this way (403, 1008, or 4403 for a control attach).
    #[error("not allowed to attach to this browser tab in {mode} mode: {detail}")]
    AccessDenied {
        /// What the server said.
        detail: String,
        /// The mode that was denied; a `view` attach may still work after a denied `control`.
        mode: AttachMode,
    },
    /// 4500: the server's relay failed.
    #[error("the server could not attach the browser tab: {reason}")]
    ServerError {
        /// The close reason.
        reason: String,
    },
    /// 4400 again after redialling without the slice key.
    #[error("no server replica could reach this browser tab's host")]
    WrongReplica,
    /// 4426, or a host `hello` with another protocol version.
    #[error("the browser host speaks an unsupported protocol: {detail}")]
    ProtocolUnsupported {
        /// Detail.
        detail: String,
    },
    /// 1002 or 1009: one side broke the protocol.
    #[error("the browser connection broke the protocol (close {code}): {reason}")]
    ProtocolViolation {
        /// The close code.
        code: u16,
        /// The close reason.
        reason: String,
    },
    /// The reconnect budget ran out.
    #[error("lost the browser connection after {attempts} reconnect attempts: {last}")]
    ReconnectBudgetExhausted {
        /// Why the last attempt ended.
        last: LinkError,
        /// Attempts made.
        attempts: u32,
    },
    /// A failure retrying cannot fix.
    #[error("{0}")]
    Unrecoverable(LinkError),
}

impl AttachFailure {
    /// Whether the user must sign in again.
    #[must_use]
    pub const fn requires_sign_in(&self) -> bool {
        matches!(self, Self::AuthenticationRequired { .. })
            || matches!(self, Self::Unrecoverable(error) if error.requires_sign_in())
    }
}

/// The connection's user-visible state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionState {
    /// Never started.
    Idle,
    /// The first attempt since `Start` is in flight.
    Connecting,
    /// The host's `hello` arrived.
    Attached {
        /// The authoritative mode.
        mode: AttachMode,
    },
    /// The connection was lost; another attempt is pending or in flight.
    Reconnecting {
        /// Why the last attempt ended.
        reason: LinkError,
        /// Consecutive failed attempts.
        failures: u32,
        /// The wait before the next attempt, in ms.
        delay_ms: u64,
    },
    /// Ended on purpose; nothing reconnects until the caller starts again.
    Closed {
        /// Why.
        reason: ClosedReason,
    },
    /// The caller detached.
    Stopped,
    /// A failure.
    Failed {
        /// The failure.
        error: AttachFailure,
    },
}

/// Which input was dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum InputKind {
    /// A mouse button or leave event.
    Mouse,
    /// A key event.
    Key,
    /// An IME event.
    Ime,
    /// A navigation command.
    Nav,
    /// A resize.
    Resize,
    /// A dialog reply.
    DialogReply,
    /// Take or release control.
    Control,
    /// Settings.
    Settings,
    /// A still request.
    Still,
    /// An edit command (v1.1).
    Edit,
    /// A touch event (v1.1).
    Touch,
    /// Mobile emulation (v1.1).
    MobileEmulation,
}

/// Why input was not sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DropReason {
    /// Not attached; input is never buffered for a later connection.
    NotAttached,
    /// A view-mode attach.
    ReadOnly,
    /// Another connection, or the agent, holds control.
    NotInControl,
    /// The host does not announce the protocol v1.1 feature this needs.
    Unsupported,
}

/// The viewport the client wants while it holds control (v1.1).
#[derive(Debug, Clone, PartialEq)]
pub struct ViewportRequest {
    /// The viewport.
    pub viewport: Viewport,
    /// Mobile emulation.
    pub mobile: MobileEmulation,
}

/// Something worth showing or logging that does not change the connection.
#[derive(Debug, Clone, PartialEq)]
pub enum Notice {
    /// A message type this client does not know.
    UnknownMessage {
        /// Its `type`.
        message_type: String,
    },
    /// A text frame that could not be decoded.
    MalformedMessage(MessageError),
    /// A binary frame that could not be decoded.
    MalformedFrame(HeaderError),
    /// A binary kind this client does not know (acked and ignored).
    UnknownMediaKind {
        /// The kind.
        kind: u8,
    },
    /// A video frame that was not delivered.
    VideoDropped(VideoDrop),
    /// The host reported an error.
    HostError(HostError),
    /// Input that was not sent.
    InputDropped {
        /// What.
        input: InputKind,
        /// Why.
        reason: DropReason,
    },
    /// Input that breaks the protocol, rejected before sending.
    InvalidInput(InputError),
}

/// Inputs to [`RemoteBrowserAttach::handle`].
#[derive(Debug, Clone, PartialEq)]
pub enum AttachInput {
    /// Attach, or reattach after `Closed`, `Stopped` or `Failed`, with a fresh reconnect budget.
    Start,
    /// Detach and close the socket.
    Stop,
    /// The app became visible: a pending reconnect dials now, an exhausted budget starts over.
    Foreground,
    /// The local tab was shown or hidden.
    SetVisible {
        /// Shown.
        visible: bool,
    },
    /// The renderer needs an IDR.
    RequestKeyframe {
        /// Why.
        reason: KeyframeReason,
    },
    /// Ask for one JPEG.
    RequestStill {
        /// Which.
        kind: StillKind,
    },
    /// Mouse input.
    Mouse(MouseEvent),
    /// Key input (already resolved to DOM `code` and `key`).
    Key(KeyEvent),
    /// IME input.
    Ime(ImeEvent),
    /// Navigation.
    Nav(NavCommand),
    /// "Fit to window": a v1, tab-scoped resize.
    Resize(Viewport),
    /// The viewport this client wants while it holds control; `None` is the agent's (v1.1).
    SetViewport(Option<ViewportRequest>),
    /// An edit command (v1.1).
    Edit(EditCommand),
    /// A touch point (v1.1).
    Touch(TouchEvent),
    /// Answer a JS dialog.
    DialogReply(DialogReply),
    /// Take control.
    TakeControl,
    /// Hand control back to the agent.
    ReleaseControl,
    /// Change settings.
    UpdateSettings(SettingsUpdate),
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
        /// The attempt.
        attempt: AttemptId,
        /// The host's error.
        error: TransportError,
    },
    /// A timer fired.
    TimerFired {
        /// Its token.
        token: TimerToken,
    },
}

/// Work for the driver, in execution order.
#[derive(Debug, Clone, PartialEq)]
pub enum AttachOutput {
    /// Build the upgrade request with these options (fresh credentials) and connect it.
    Connect {
        /// The new attempt.
        attempt: AttemptId,
        /// The options; the slice key is dropped after a 4400 close.
        options: AttachOptions,
    },
    /// Send `message` on `attempt`'s socket. Report a failure with [`AttachInput::SendFailed`].
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
    /// Deliver [`AttachInput::TimerFired`] after `delay_ms`.
    ScheduleTimer {
        /// The token.
        token: TimerToken,
        /// Delay from the current `now_ms`.
        delay_ms: u64,
    },
    /// The timer is no longer needed.
    CancelTimer {
        /// The token.
        token: TimerToken,
    },
    /// The connection state changed ([`RemoteBrowserAttach::connection`]).
    ConnectionChanged {
        /// The new state.
        state: ConnectionState,
    },
    /// The tab state changed ([`RemoteBrowserAttach::tab`]).
    TabChanged,
    /// A video frame for the decoder.
    Video(VideoFrame),
    /// A JPEG.
    Still {
        /// Still or thumbnail.
        kind: StillKind,
        /// Host capture time, µs.
        pts_us: u64,
        /// The JPEG.
        jpeg: Vec<u8>,
    },
    /// Text the page copied or cut (v1.1), for the local pasteboard.
    Clipboard {
        /// `Copy` or `Cut`.
        op: EditOp,
        /// The text.
        text: String,
    },
    /// The tab ended (4404). Sent once, after `ConnectionChanged` to `Closed`.
    TabEnded {
        /// What `tab_closed` said, when it came first.
        reason: Option<TabClosedReason>,
    },
    /// Something to show or log.
    Notice(Notice),
}

#[derive(Debug, Clone)]
struct Attempt {
    id: AttemptId,
    opened_at_ms: Option<u64>,
    hello: bool,
    last_inbound_ms: u64,
}

enum Loss {
    Retry(LinkError),
    Fail(AttachFailure),
    Close(ClosedReason),
    Keyless(LinkError),
}

/// Pure state machine for one remote browser attach. See the [module docs](self).
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent connection flags, each with its own transitions"
)]
#[derive(Debug, Clone)]
pub struct RemoteBrowserAttach<J> {
    config: AttachConfig,
    options: AttachOptions,
    keyless: bool,
    jitter: J,
    next_attempt: u64,
    next_timer: u64,
    retry: Retry,
    state: ConnectionState,
    attempt: Option<Attempt>,
    reconnect_timer: Option<TimerToken>,
    ping_timer: Option<TimerToken>,
    watchdog_timer: Option<TimerToken>,
    input_timer: Option<TimerToken>,
    next_nonce: u64,
    tab: TabState,
    video: VideoTrack,
    coalescer: InputCoalescer,
    visible: bool,
    wants_control: bool,
    /// The user asked for control before the host's `hello`; it is sent once the hello arrives.
    take_awaiting_hello: bool,
    stats_wanted: bool,
    desired_viewport: Option<ViewportRequest>,
    /// The last viewport `resize` sent on this connection, until the host answers.
    sent_viewport: Option<ResizeRequest>,
    /// v1 host: the agent's viewport, restored before `release`.
    restore_viewport: Option<Viewport>,
    mobile_unsupported_reported: bool,
}

impl<J: JitterSource> RemoteBrowserAttach<J> {
    /// An idle machine for an attach with `options`.
    pub fn new(config: AttachConfig, options: AttachOptions, jitter: J) -> Self {
        Self {
            retry: Retry::new(config.retry),
            coalescer: InputCoalescer::new(config.input_interval_ms),
            config,
            options,
            keyless: false,
            jitter,
            next_attempt: 0,
            next_timer: 0,
            state: ConnectionState::Idle,
            attempt: None,
            reconnect_timer: None,
            ping_timer: None,
            watchdog_timer: None,
            input_timer: None,
            next_nonce: 0,
            tab: TabState::default(),
            video: VideoTrack::new(),
            visible: true,
            wants_control: false,
            take_awaiting_hello: false,
            stats_wanted: false,
            desired_viewport: None,
            sent_viewport: None,
            restore_viewport: None,
            mobile_unsupported_reported: false,
        }
    }

    /// The connection state.
    pub const fn connection(&self) -> &ConnectionState {
        &self.state
    }

    /// The tab state.
    pub const fn tab(&self) -> &TabState {
        &self.tab
    }

    /// The attempt in flight, if any.
    pub fn current_attempt(&self) -> Option<AttemptId> {
        self.attempt.as_ref().map(|attempt| attempt.id)
    }

    /// Whether the user asked for control and has not handed it back.
    pub const fn wants_control(&self) -> bool {
        self.wants_control
    }

    /// Applies one input at `now_ms` and returns the work it causes, in order.
    pub fn handle(&mut self, now_ms: u64, input: AttachInput) -> Vec<AttachOutput> {
        let mut out = Vec::new();
        match input {
            AttachInput::Start => self.start(&mut out),
            AttachInput::Stop => self.stop(&mut out),
            AttachInput::Foreground => self.foreground(&mut out),
            AttachInput::SetVisible { visible } => {
                self.visible = visible;
                self.send_if_attached(&ClientMessage::Visibility { visible }, &mut out);
            }
            AttachInput::RequestKeyframe { reason } => {
                self.send_if_attached(&ClientMessage::KeyframeRequest { reason }, &mut out);
            }
            AttachInput::RequestStill { kind } => match self.gate(false) {
                Ok(_) | Err(DropReason::ReadOnly | DropReason::NotInControl) => {
                    self.send_if_attached(&ClientMessage::StillRequest { kind }, &mut out);
                }
                Err(reason) => out.push(dropped(InputKind::Still, reason)),
            },
            AttachInput::Mouse(event) => self.mouse(now_ms, event, &mut out),
            input @ (AttachInput::Key(_)
            | AttachInput::Ime(_)
            | AttachInput::Nav(_)
            | AttachInput::Resize(_)
            | AttachInput::DialogReply(_)
            | AttachInput::Edit(_)
            | AttachInput::Touch(_)) => self.discrete_input(now_ms, input, &mut out),
            AttachInput::SetViewport(request) => {
                if let Some(Err(error)) = request
                    .as_ref()
                    .map(|request| validate_viewport(&request.viewport))
                {
                    out.push(AttachOutput::Notice(Notice::InvalidInput(error)));
                } else {
                    self.desired_viewport = request;
                    self.sync_viewport(now_ms, &mut out);
                }
            }
            AttachInput::TakeControl => self.take_control(&mut out),
            AttachInput::ReleaseControl => self.release_control(now_ms, &mut out),
            AttachInput::UpdateSettings(update) => self.update_settings(update, &mut out),
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
                    self.lose(
                        now_ms,
                        Loss::Retry(LinkError::SendFailed(error)),
                        true,
                        &mut out,
                    );
                }
            }
            AttachInput::TimerFired { token } => self.timer(now_ms, token, &mut out),
        }
        out
    }

    fn is_current(&self, attempt: AttemptId) -> bool {
        self.current_attempt() == Some(attempt)
    }

    const fn is_running(&self) -> bool {
        matches!(
            self.state,
            ConnectionState::Connecting
                | ConnectionState::Attached { .. }
                | ConnectionState::Reconnecting { .. }
        )
    }

    fn mode(&self) -> AttachMode {
        self.tab
            .mode
            .clone()
            .unwrap_or_else(|| self.options.mode.clone())
    }

    const fn timer_token(&mut self, kind: TimerKind) -> TimerToken {
        self.next_timer += 1;
        TimerToken {
            kind,
            id: self.next_timer,
        }
    }

    fn schedule(
        &mut self,
        kind: TimerKind,
        delay_ms: u64,
        out: &mut Vec<AttachOutput>,
    ) -> TimerToken {
        let token = self.timer_token(kind);
        out.push(AttachOutput::ScheduleTimer { token, delay_ms });
        token
    }

    fn start(&mut self, out: &mut Vec<AttachOutput>) {
        if self.is_running() {
            return;
        }
        self.retry.reset();
        self.keyless = false;
        self.set_state(ConnectionState::Connecting, out);
        self.connect(out);
    }

    fn stop(&mut self, out: &mut Vec<AttachOutput>) {
        self.take_awaiting_hello = false;
        self.end_attempt(Some("client detached"), out);
        if let Some(token) = self.reconnect_timer.take() {
            out.push(AttachOutput::CancelTimer { token });
        }
        self.set_state(ConnectionState::Stopped, out);
    }

    fn foreground(&mut self, out: &mut Vec<AttachOutput>) {
        match &self.state {
            ConnectionState::Reconnecting { .. } => {
                if let Some(token) = self.reconnect_timer.take() {
                    out.push(AttachOutput::CancelTimer { token });
                    self.connect(out);
                }
            }
            ConnectionState::Failed {
                error: AttachFailure::ReconnectBudgetExhausted { .. },
            } => self.start(out),
            _ => {}
        }
    }

    fn connect(&mut self, out: &mut Vec<AttachOutput>) {
        self.next_attempt += 1;
        let id = AttemptId(self.next_attempt);
        self.attempt = Some(Attempt {
            id,
            opened_at_ms: None,
            hello: false,
            last_inbound_ms: 0,
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

    /// The open attempt, if the socket is open.
    fn open_attempt(&self) -> Option<AttemptId> {
        self.attempt
            .as_ref()
            .filter(|attempt| attempt.opened_at_ms.is_some())
            .map(|attempt| attempt.id)
    }

    /// The attempt that may carry input, or why not.
    fn gate(&self, needs_holder: bool) -> Result<AttemptId, DropReason> {
        let attempt = self
            .attempt
            .as_ref()
            .filter(|attempt| attempt.hello)
            .ok_or(DropReason::NotAttached)?;
        if self.mode() == AttachMode::View {
            return Err(DropReason::ReadOnly);
        }
        if needs_holder && !self.tab.holds_control() {
            return Err(DropReason::NotInControl);
        }
        Ok(attempt.id)
    }

    fn send_if_attached(&self, message: &ClientMessage, out: &mut Vec<AttachOutput>) {
        if let Some(attempt) = self.attempt.as_ref().filter(|attempt| attempt.hello) {
            send(attempt.id, message, out);
        }
    }

    fn flush_input(&mut self, now_ms: u64, attempt: AttemptId, out: &mut Vec<AttachOutput>) {
        if let Some(pending) = self.coalescer.flush(now_ms) {
            send(attempt, &ClientMessage::Mouse(pending), out);
        }
    }

    fn mouse(&mut self, now_ms: u64, event: MouseEvent, out: &mut Vec<AttachOutput>) {
        if let Err(error) = validate_mouse(&event) {
            out.push(AttachOutput::Notice(Notice::InvalidInput(error)));
            return;
        }
        let attempt = match self.gate(true) {
            Ok(attempt) => attempt,
            Err(reason) => {
                // Moves and wheel ticks arrive by the hundred; only discrete events are reported.
                if !matches!(event.kind, MouseKind::Move | MouseKind::Wheel) {
                    out.push(dropped(InputKind::Mouse, reason));
                }
                return;
            }
        };
        let coalesced = self.coalescer.mouse(now_ms, event);
        for event in coalesced.send {
            send(attempt, &ClientMessage::Mouse(event), out);
        }
        if let Some(delay_ms) = coalesced.arm_timer_ms {
            self.input_timer = Some(self.schedule(TimerKind::InputFlush, delay_ms, out));
        }
    }

    /// Key, IME, navigation, resize and dialog input: validated, holder-gated, and sent after
    /// any pending mouse move.
    fn discrete_input(&mut self, now_ms: u64, input: AttachInput, out: &mut Vec<AttachOutput>) {
        let (kind, valid, message) = match input {
            AttachInput::Key(event) => (
                InputKind::Key,
                validate_key(&event),
                ClientMessage::Key(event),
            ),
            AttachInput::Ime(event) => (
                InputKind::Ime,
                validate_ime(&event),
                ClientMessage::Ime(event),
            ),
            AttachInput::Nav(command) => (
                InputKind::Nav,
                validate_nav(&command),
                ClientMessage::Nav(command),
            ),
            AttachInput::Resize(viewport) => (
                InputKind::Resize,
                validate_viewport(&viewport),
                ClientMessage::Resize(ResizeRequest {
                    viewport,
                    scope: None,
                    mobile: None,
                }),
            ),
            AttachInput::Edit(command) => {
                if !self.feature_or_drop(features::EDIT, InputKind::Edit, out) {
                    return;
                }
                (
                    InputKind::Edit,
                    validate_edit(&command),
                    ClientMessage::Edit(command),
                )
            }
            AttachInput::Touch(event) => {
                if !self.feature_or_drop(features::TOUCH, InputKind::Touch, out) {
                    return;
                }
                (
                    InputKind::Touch,
                    validate_touch(&event),
                    ClientMessage::Touch(event),
                )
            }
            AttachInput::DialogReply(reply) => (
                InputKind::DialogReply,
                Ok(()),
                ClientMessage::DialogReply(reply),
            ),
            _ => return,
        };
        if let Err(error) = valid {
            out.push(AttachOutput::Notice(Notice::InvalidInput(error)));
            return;
        }
        match self.gate(true) {
            Ok(attempt) => {
                self.flush_input(now_ms, attempt, out);
                send(attempt, &message, out);
            }
            Err(reason) => out.push(dropped(kind, reason)),
        }
    }

    /// Whether the attached host announced `feature`; otherwise reports the input as dropped.
    fn feature_or_drop(
        &self,
        feature: &str,
        input: InputKind,
        out: &mut Vec<AttachOutput>,
    ) -> bool {
        let attached = self.attempt.as_ref().is_some_and(|attempt| attempt.hello);
        if attached && !self.tab.has_feature(feature) {
            out.push(dropped(input, DropReason::Unsupported));
            return false;
        }
        true
    }

    /// Sends the `resize` that makes the host's viewport the one this client wants, when this
    /// connection holds control and it differs (design doc section 16.2).
    fn sync_viewport(&mut self, now_ms: u64, out: &mut Vec<AttachOutput>) {
        // After a release the host restores the agent's viewport before its `control` update
        // arrives; that is not a change to undo.
        if !self.wants_control {
            return;
        }
        let Ok(attempt) = self.gate(true) else {
            return;
        };
        let scoped = self.tab.has_feature(features::VIEWPORT_SCOPE);
        let current = self.tab.viewport;
        let desired = self.desired_viewport.clone();
        let request = match (&desired, scoped) {
            (Some(wanted), true) => {
                let mobile = if self.tab.has_feature(features::MOBILE_EMULATION) {
                    wanted.mobile.clone()
                } else {
                    self.report_mobile_unsupported(&wanted.mobile, out);
                    MobileEmulation::Off
                };
                let applied = current == Some(wanted.viewport)
                    && self.tab.viewport_scope == ViewportScope::Control
                    && self.tab.mobile == mobile;
                (!applied).then(|| ResizeRequest {
                    viewport: wanted.viewport,
                    scope: Some(ViewportScope::Control),
                    mobile: (mobile != MobileEmulation::Off).then_some(mobile),
                })
            }
            (Some(wanted), false) => {
                self.report_mobile_unsupported(&wanted.mobile, out);
                if self.restore_viewport.is_none() {
                    self.restore_viewport = current;
                }
                (current != Some(wanted.viewport)).then(|| plain_resize(wanted.viewport))
            }
            (None, true) => (self.tab.viewport_scope == ViewportScope::Control)
                .then_some(self.tab.agent_viewport)
                .flatten()
                .map(|agent| ResizeRequest {
                    viewport: agent,
                    scope: Some(ViewportScope::Control),
                    mobile: Some(MobileEmulation::Off),
                }),
            (None, false) => self
                .restore_viewport
                .take()
                .filter(|agent| current != Some(*agent))
                .map(plain_resize),
        };
        let Some(request) = request else {
            return;
        };
        if self.sent_viewport.as_ref() == Some(&request) {
            return; // Already on its way.
        }
        self.flush_input(now_ms, attempt, out);
        send(attempt, &ClientMessage::Resize(request.clone()), out);
        self.sent_viewport = Some(request);
    }

    fn report_mobile_unsupported(&mut self, mobile: &MobileEmulation, out: &mut Vec<AttachOutput>) {
        if *mobile != MobileEmulation::Off && !self.mobile_unsupported_reported {
            self.mobile_unsupported_reported = true;
            out.push(dropped(InputKind::MobileEmulation, DropReason::Unsupported));
        }
    }

    fn take_control(&mut self, out: &mut Vec<AttachOutput>) {
        if self.options.mode == AttachMode::View {
            out.push(dropped(InputKind::Control, DropReason::ReadOnly));
            return;
        }
        self.wants_control = true;
        match self.gate(false) {
            Ok(attempt) => send(
                attempt,
                &ClientMessage::Control {
                    op: ControlOp::Take,
                },
                out,
            ),
            // Sent after the next host `hello`.
            Err(DropReason::NotAttached) => self.take_awaiting_hello = true,
            Err(reason) => {
                self.wants_control = false;
                out.push(dropped(InputKind::Control, reason));
            }
        }
    }

    fn release_control(&mut self, now_ms: u64, out: &mut Vec<AttachOutput>) {
        self.wants_control = false;
        self.take_awaiting_hello = false;
        if let Ok(attempt) = self.gate(true) {
            self.flush_input(now_ms, attempt, out);
            // A v1 host keeps any size; give the agent its own back before handing over.
            if let Some(agent) = self.restore_viewport.take()
                && self.tab.viewport != Some(agent)
            {
                send(attempt, &ClientMessage::Resize(plain_resize(agent)), out);
            }
            send(
                attempt,
                &ClientMessage::Control {
                    op: ControlOp::Release,
                },
                out,
            );
        }
    }

    fn update_settings(&mut self, mut update: SettingsUpdate, out: &mut Vec<AttachOutput>) {
        if let Some(stats) = update.stats {
            self.stats_wanted = stats;
            if !stats && self.tab.stats.take().is_some() {
                out.push(AttachOutput::TabChanged);
            }
        }
        let controls = update.max_fps.is_some()
            || update.quality.is_some()
            || update.scale.is_some()
            || update.codec.is_some();
        if controls && self.mode() == AttachMode::View {
            out.push(dropped(InputKind::Settings, DropReason::ReadOnly));
            update = SettingsUpdate {
                stats: update.stats,
                ..SettingsUpdate::default()
            };
        }
        if update != SettingsUpdate::default() {
            self.send_if_attached(&ClientMessage::Settings(update), out);
        }
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
        attempt.last_inbound_ms = now_ms;
        let id = attempt.id;
        self.video.reset();
        self.coalescer.reset();
        self.tab.reset_connection();
        self.sent_viewport = None;
        let hello = ClientMessage::Hello(ClientHello {
            protocol: PROTOCOL_VERSION,
            client: self.config.client_name.clone(),
            decoders: vec!["h264".to_owned(), "jpeg".to_owned()],
            mode: self.options.mode.clone(),
            visible: self.visible,
            // The v1.1 reports this client shows (design doc section 16.6).
            features: vec![
                features::SELECTION.to_owned(),
                features::SCROLL_METRICS.to_owned(),
            ],
        });
        send(id, &hello, out);
        self.watchdog_timer =
            Some(self.schedule(TimerKind::Watchdog, self.config.silence_timeout_ms, out));
        self.ping_timer = Some(self.schedule(TimerKind::Ping, self.config.ping_interval_ms, out));
    }

    fn message(&mut self, now_ms: u64, message: SocketMessage, out: &mut Vec<AttachOutput>) {
        let Some(attempt) = self.attempt.as_mut() else {
            return;
        };
        if attempt.opened_at_ms.is_none() {
            let loss = Loss::Fail(AttachFailure::Unrecoverable(LinkError::HostContract {
                message: "a message arrived before the socket opened".to_owned(),
            }));
            self.lose(now_ms, loss, true, out);
            return;
        }
        attempt.last_inbound_ms = now_ms;
        let id = attempt.id;
        match message {
            SocketMessage::Text(text) => match HostMessage::decode(&text) {
                Ok(message) => self.host_message(now_ms, id, message, out),
                Err(error) => out.push(AttachOutput::Notice(Notice::MalformedMessage(error))),
            },
            SocketMessage::Binary(bytes) => self.binary(id, &bytes, out),
        }
    }

    fn host_message(
        &mut self,
        now_ms: u64,
        attempt: AttemptId,
        message: HostMessage,
        out: &mut Vec<AttachOutput>,
    ) {
        match &message {
            HostMessage::Hello(hello) if hello.protocol != PROTOCOL_VERSION => {
                return self.reject_protocol(attempt, hello.protocol, out);
            }
            HostMessage::Error(error) => {
                out.push(AttachOutput::Notice(Notice::HostError(error.clone())));
            }
            HostMessage::Unknown { message_type, .. } => {
                out.push(AttachOutput::Notice(Notice::UnknownMessage {
                    message_type: message_type.clone(),
                }));
            }
            _ => {}
        }
        if self.tab.apply(&message) {
            out.push(AttachOutput::TabChanged);
        }
        match message {
            HostMessage::Hello(hello) => self.on_hello(attempt, hello.mode, out),
            HostMessage::Clipboard(clipboard) => out.push(AttachOutput::Clipboard {
                op: clipboard.op,
                text: clipboard.text,
            }),
            HostMessage::Viewport(_) => {
                // The host answered; re-assert the wanted viewport if something else changed it.
                self.sent_viewport = None;
                self.sync_viewport(now_ms, out);
            }
            HostMessage::Control(update) => {
                let lost = update.state.holder == Some(Holder::Other)
                    || (update.state.owner == Owner::Agent
                        && matches!(
                            update.reason,
                            Some(
                                ControlReason::Release
                                    | ControlReason::GraceExpired
                                    | ControlReason::Agent
                            )
                        ));
                if lost {
                    self.wants_control = false;
                }
                if self.tab.holds_control() {
                    self.sync_viewport(now_ms, out);
                } else {
                    self.coalescer.reset();
                    self.sent_viewport = None;
                }
            }
            _ => {}
        }
    }

    fn reject_protocol(&mut self, attempt: AttemptId, version: u32, out: &mut Vec<AttachOutput>) {
        out.push(AttachOutput::Close {
            attempt,
            code: CLOSE_PROTOCOL_UNSUPPORTED,
            reason: "protocol unsupported".to_owned(),
        });
        self.attempt = None;
        self.cancel_connection_timers(out);
        let detail =
            format!("the host offered protocol {version}, this client speaks {PROTOCOL_VERSION}");
        self.set_state(
            ConnectionState::Failed {
                error: AttachFailure::ProtocolUnsupported { detail },
            },
            out,
        );
    }

    fn on_hello(&mut self, attempt: AttemptId, mode: AttachMode, out: &mut Vec<AttachOutput>) {
        if let Some(current) = self.attempt.as_mut() {
            current.hello = true;
        }
        self.retry.on_live();
        let asked = std::mem::take(&mut self.take_awaiting_hello);
        let reclaim = self.wants_control
            && mode == AttachMode::Control
            && (asked || self.tab.in_grace_period());
        self.set_state(ConnectionState::Attached { mode }, out);
        if reclaim {
            send(
                attempt,
                &ClientMessage::Control {
                    op: ControlOp::Take,
                },
                out,
            );
        } else {
            if asked {
                out.push(dropped(InputKind::Control, DropReason::ReadOnly));
            }
            self.wants_control = false;
        }
        if self.stats_wanted {
            let update = SettingsUpdate {
                stats: Some(true),
                ..SettingsUpdate::default()
            };
            send(attempt, &ClientMessage::Settings(update), out);
        }
    }

    fn binary(&mut self, attempt: AttemptId, bytes: &[u8], out: &mut Vec<AttachOutput>) {
        let frame = match decode_frame(bytes) {
            Ok(frame) => frame,
            Err(error) => {
                if let Some(seq) = error.seq() {
                    send(attempt, &ClientMessage::Ack { seq }, out);
                }
                out.push(AttachOutput::Notice(Notice::MalformedFrame(error)));
                if let Some(reason) = self.video.gap() {
                    send(attempt, &ClientMessage::KeyframeRequest { reason }, out);
                }
                return;
            }
        };
        send(
            attempt,
            &ClientMessage::Ack {
                seq: frame.header.seq,
            },
            out,
        );
        match frame.header.kind {
            MediaKind::H264 => match self.video.accept(&frame.header, frame.payload) {
                VideoOutcome::Frame(video) => out.push(AttachOutput::Video(video)),
                VideoOutcome::Dropped { reason, request } => {
                    out.push(AttachOutput::Notice(Notice::VideoDropped(reason)));
                    if let Some(reason) = request {
                        send(attempt, &ClientMessage::KeyframeRequest { reason }, out);
                    }
                }
            },
            MediaKind::JpegStill | MediaKind::JpegThumbnail => out.push(AttachOutput::Still {
                kind: if frame.header.kind == MediaKind::JpegStill {
                    StillKind::Still
                } else {
                    StillKind::Thumbnail
                },
                pts_us: frame.header.pts_us,
                jpeg: frame.payload.to_vec(),
            }),
            MediaKind::Unknown(kind) => {
                out.push(AttachOutput::Notice(Notice::UnknownMediaKind { kind }));
            }
        }
    }

    fn timer(&mut self, now_ms: u64, token: TimerToken, out: &mut Vec<AttachOutput>) {
        match token.kind {
            TimerKind::Reconnect if self.reconnect_timer == Some(token) => {
                self.reconnect_timer = None;
                self.connect(out);
            }
            TimerKind::Ping if self.ping_timer == Some(token) => {
                self.ping_timer = None;
                if let Some(attempt) = self.open_attempt() {
                    self.next_nonce += 1;
                    let nonce = format!("p{}", self.next_nonce);
                    send(attempt, &ClientMessage::Ping { nonce }, out);
                    self.ping_timer =
                        Some(self.schedule(TimerKind::Ping, self.config.ping_interval_ms, out));
                }
            }
            TimerKind::Watchdog if self.watchdog_timer == Some(token) => {
                self.watchdog_timer = None;
                let Some(last) = self
                    .attempt
                    .as_ref()
                    .filter(|attempt| attempt.opened_at_ms.is_some())
                    .map(|attempt| attempt.last_inbound_ms)
                else {
                    return;
                };
                let silent_ms = now_ms.saturating_sub(last);
                if silent_ms >= self.config.silence_timeout_ms {
                    self.lose(
                        now_ms,
                        Loss::Retry(LinkError::Stalled { silent_ms }),
                        true,
                        out,
                    );
                } else {
                    let remaining = self.config.silence_timeout_ms - silent_ms;
                    self.watchdog_timer = Some(self.schedule(TimerKind::Watchdog, remaining, out));
                }
            }
            TimerKind::InputFlush if self.input_timer == Some(token) => {
                self.input_timer = None;
                let pending = self.coalescer.timer_fired(now_ms);
                if let (Some(event), Ok(attempt)) = (pending, self.gate(true)) {
                    send(attempt, &ClientMessage::Mouse(event), out);
                }
            }
            _ => {}
        }
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
                    mode: self.options.mode.clone(),
                }),
                status => Loss::Retry(LinkError::HttpStatus { status }),
            },
            SocketEnd::Failed(failure) => connection_loss(failure),
        }
    }

    fn classify_close(&self, code: u16, reason: String) -> Loss {
        match code {
            CLOSE_TAB_GONE => Loss::Close(ClosedReason::TabEnded {
                reason: self.tab.closed.clone(),
                detail: reason,
            }),
            CLOSE_SERVER_ERROR => Loss::Fail(AttachFailure::ServerError { reason }),
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
                        mode: self.options.mode.clone(),
                    })
                }
            }
            CLOSE_CONTROL_NOT_PERMITTED => Loss::Fail(AttachFailure::AccessDenied {
                detail: reason,
                mode: AttachMode::Control,
            }),
            CLOSE_PROTOCOL_UNSUPPORTED => {
                Loss::Fail(AttachFailure::ProtocolUnsupported { detail: reason })
            }
            CLOSE_PROTOCOL_ERROR | CLOSE_TOO_BIG => {
                Loss::Fail(AttachFailure::ProtocolViolation { code, reason })
            }
            code if is_transport_close(code) || code == CLOSE_TRY_AGAIN_LATER => {
                Loss::Retry(LinkError::SocketClosed { code, reason })
            }
            code => Loss::Close(ClosedReason::ServerClosed { code, reason }),
        }
    }

    fn cancel_connection_timers(&mut self, out: &mut Vec<AttachOutput>) {
        for token in [
            self.ping_timer.take(),
            self.watchdog_timer.take(),
            self.input_timer.take(),
        ]
        .into_iter()
        .flatten()
        {
            out.push(AttachOutput::CancelTimer { token });
        }
        self.coalescer.reset();
    }

    /// Drops the current attempt, closing its socket if `close_reason` is given. Returns when it
    /// opened, if it did.
    fn end_attempt(
        &mut self,
        close_reason: Option<&str>,
        out: &mut Vec<AttachOutput>,
    ) -> Option<u64> {
        let attempt = self.attempt.take()?;
        if let Some(reason) = close_reason {
            out.push(AttachOutput::Close {
                attempt: attempt.id,
                code: CLOSE_NORMAL,
                reason: reason.to_owned(),
            });
        }
        self.cancel_connection_timers(out);
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
            Loss::Fail(error) => return self.set_state(ConnectionState::Failed { error }, out),
            Loss::Close(reason) => {
                let ended = match &reason {
                    ClosedReason::TabEnded { reason, .. } => Some(reason.clone()),
                    ClosedReason::ServerClosed { .. } => None,
                };
                self.set_state(ConnectionState::Closed { reason }, out);
                if let Some(reason) = ended {
                    out.push(AttachOutput::TabEnded { reason });
                }
                return;
            }
            Loss::Keyless(reason) => {
                self.keyless = true;
                self.set_state(
                    ConnectionState::Reconnecting {
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
                ConnectionState::Failed {
                    error: AttachFailure::Unrecoverable(error),
                },
                out,
            ),
            RetryDecision::Reconnect { failures, .. } if failures > self.config.max_reconnects => {
                self.set_state(
                    ConnectionState::Failed {
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
                    ConnectionState::Reconnecting {
                        reason: error,
                        failures,
                        delay_ms,
                    },
                    out,
                );
                if delay_ms == 0 {
                    self.connect(out);
                } else {
                    self.reconnect_timer = Some(self.schedule(TimerKind::Reconnect, delay_ms, out));
                }
            }
        }
    }

    fn set_state(&mut self, state: ConnectionState, out: &mut Vec<AttachOutput>) {
        if self.state != state {
            self.state = state.clone();
            out.push(AttachOutput::ConnectionChanged { state });
        }
    }
}

/// A v1 (tab-scoped) `resize`.
const fn plain_resize(viewport: Viewport) -> ResizeRequest {
    ResizeRequest {
        viewport,
        scope: None,
        mobile: None,
    }
}

/// Queues `message` for `attempt`'s socket.
fn send(attempt: AttemptId, message: &ClientMessage, out: &mut Vec<AttachOutput>) {
    queue_encoded(attempt, message.encode(), out);
}

/// Queues an encoded message, or reports why it could not be encoded.
fn queue_encoded(
    attempt: AttemptId,
    encoded: Result<String, MessageError>,
    out: &mut Vec<AttachOutput>,
) {
    match encoded {
        Ok(text) => out.push(AttachOutput::Send {
            attempt,
            message: SocketMessage::Text(text),
        }),
        Err(error) => out.push(AttachOutput::Notice(Notice::MalformedMessage(error))),
    }
}

const fn dropped(input: InputKind, reason: DropReason) -> AttachOutput {
    AttachOutput::Notice(Notice::InputDropped { input, reason })
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
