//! Session terminals.
//!
//! Records mirroring `omnigent_core::terminal`, the REST calls (list, create, delete), the
//! session's terminal inventory as [`CoreEvent::TerminalsChanged`], and
//! [`TerminalAttachDriver`], which runs the core's `TerminalAttach` machine over the host's
//! WebSocket and timer traits.

use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;

use futures::StreamExt;
use futures::channel::mpsc::{self, UnboundedReceiver, UnboundedSender};
use futures::future::AbortHandle;
use omnigent_core::realtime::{AttemptId, SplitMix64};
use omnigent_core::terminal as core;

use crate::client::ClientCore;
use crate::errors::CoreError;
use crate::events::CoreEvent;
use crate::host::{MessageSink, SocketEvent, WebSocketHandle, WebSocketTransport};
use crate::runtime::{Host, Sessions, post};

/// [`core::TerminalError`]'s variants.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
#[allow(
    missing_docs,
    reason = "each variant mirrors the TerminalError variant of the same name"
)]
pub enum TerminalErrorKind {
    NotConnected,
    InvalidIdentifier,
    InvalidRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    RunnerUnavailable,
    Rejected,
    Redirected,
    HttpStatus,
    Transport,
    MalformedResponse,
}

pub(crate) fn terminal_error(error: core::TerminalError) -> CoreError {
    use core::TerminalError as E;
    let kind = match &error {
        E::NotConnected => TerminalErrorKind::NotConnected,
        E::InvalidIdentifier { .. } => TerminalErrorKind::InvalidIdentifier,
        E::InvalidRequest { .. } => TerminalErrorKind::InvalidRequest,
        E::Unauthorized { .. } => TerminalErrorKind::Unauthorized,
        E::Forbidden { .. } => TerminalErrorKind::Forbidden,
        E::NotFound { .. } => TerminalErrorKind::NotFound,
        E::RunnerUnavailable { .. } => TerminalErrorKind::RunnerUnavailable,
        E::Rejected { .. } => TerminalErrorKind::Rejected,
        E::Redirected { .. } => TerminalErrorKind::Redirected,
        E::HttpStatus { .. } => TerminalErrorKind::HttpStatus,
        E::Transport(_) => TerminalErrorKind::Transport,
        E::MalformedResponse { .. } => TerminalErrorKind::MalformedResponse,
    };
    CoreError::Terminal {
        kind,
        requires_sign_in: error.requires_sign_in(),
        message: error.to_string(),
    }
}

/// One terminal resource of a session.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TerminalResource {
    /// Opaque id used in every terminal route, for example `terminal_bash_s1`.
    pub id: String,
    /// The owning session, when the payload names one.
    pub session_id: Option<String>,
    /// The declared terminal name, for example `bash`.
    pub terminal_name: String,
    /// The session key, for example `s1` or `main`; empty when absent.
    pub session_key: String,
    /// Whether the tmux session is running; `None` when the runner did not say.
    pub running: Option<bool>,
    /// The environment the terminal runs in, if reported.
    pub environment: Option<String>,
    /// A validated loopback attach URL (owner-only, same machine).
    pub direct_attach_url: Option<String>,
    /// The agent's own terminal rather than a user shell.
    pub is_agent_terminal: bool,
    /// `bash · s1`, or the name alone.
    pub display_label: String,
}

impl From<core::TerminalResource> for TerminalResource {
    fn from(resource: core::TerminalResource) -> Self {
        Self {
            is_agent_terminal: resource.is_agent_terminal(),
            display_label: resource.display_label(),
            id: resource.id,
            session_id: resource.session_id,
            terminal_name: resource.terminal_name,
            session_key: resource.session_key,
            running: resource.running,
            environment: resource.environment,
            direct_attach_url: resource.direct_attach_url,
        }
    }
}

/// The badge a terminal row shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TerminalStatus {
    /// Running, with recent output.
    Active,
    /// Running and quiet.
    Idle,
    /// The tmux session is not running.
    Exited,
    /// The runner did not say whether it is running.
    Unknown,
}

impl From<core::TerminalStatus> for TerminalStatus {
    fn from(status: core::TerminalStatus) -> Self {
        match status {
            core::TerminalStatus::Active => Self::Active,
            core::TerminalStatus::Idle => Self::Idle,
            core::TerminalStatus::Exited => Self::Exited,
            core::TerminalStatus::Unknown => Self::Unknown,
        }
    }
}

/// One row of a session's terminal list.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TerminalRow {
    /// The terminal.
    pub terminal: TerminalResource,
    /// Its badge.
    pub status: TerminalStatus,
}

impl From<core::TerminalRow> for TerminalRow {
    fn from(row: core::TerminalRow) -> Self {
        Self {
            terminal: row.resource.into(),
            status: row.status.into(),
        }
    }
}

/// What the session's Terminal view can show.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum HarnessTerminal {
    /// Not a terminal-first session: there is no Terminal view.
    NotTerminalFirst,
    /// Terminal-first, and the runner is creating the pane.
    StartingUp,
    /// Terminal-first, and the pane is not there: show the stopped state with Resume.
    Unavailable,
    /// The pane to attach to.
    Ready {
        /// The agent terminal.
        terminal: TerminalResource,
    },
}

impl From<core::HarnessTerminal> for HarnessTerminal {
    fn from(harness: core::HarnessTerminal) -> Self {
        match harness {
            core::HarnessTerminal::NotTerminalFirst => Self::NotTerminalFirst,
            core::HarnessTerminal::StartingUp => Self::StartingUp,
            core::HarnessTerminal::Unavailable => Self::Unavailable,
            core::HarnessTerminal::Ready { terminal } => Self::Ready {
                terminal: terminal.into(),
            },
        }
    }
}

/// The labels map that marks a terminal-first session, for [`core::TerminalInventory`].
fn terminal_first_labels(terminal_first: bool) -> std::collections::BTreeMap<String, String> {
    let mut labels = std::collections::BTreeMap::new();
    if terminal_first {
        labels.insert(
            core::TERMINAL_UI_LABEL.to_owned(),
            core::TERMINAL_UI_VALUE.to_owned(),
        );
    }
    labels
}

/// What an inventory shows for a session (`terminal_first` from its summary, `terminal_pending`
/// from its snapshot or stream).
pub(crate) fn harness_of(
    inventory: &core::TerminalInventory,
    terminal_first: bool,
    terminal_pending: bool,
) -> HarnessTerminal {
    inventory
        .harness_terminal(&terminal_first_labels(terminal_first), terminal_pending)
        .into()
}

/// Whether session `labels` mark a terminal-first session (`omnigent.ui = terminal`).
#[must_use]
#[uniffi::export]
#[allow(
    clippy::implicit_hasher,
    reason = "UniFFI maps records to HashMap with the default hasher"
)]
pub fn is_terminal_first(labels: HashMap<String, String>) -> bool {
    core::is_terminal_first(&labels.into_iter().collect())
}

/// Whether a caller with `permission_level` may type into a terminal (owner, or permissions
/// disabled); anyone else attaches read-only.
#[must_use]
#[uniffi::export]
pub const fn terminal_can_type(permission_level: Option<i64>) -> bool {
    core::can_type(permission_level)
}

/// Why a terminal attach closed without an error.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TerminalClosedReason {
    /// The terminal is gone or not running.
    TerminalEnded {
        /// The server's reason.
        reason: String,
    },
    /// This attach was detached; the terminal still runs and can be reattached.
    Detached {
        /// The server's reason.
        reason: String,
    },
    /// The server closed the attach on purpose.
    ServerClosed {
        /// The close code.
        code: u16,
        /// The reason.
        reason: String,
    },
}

/// A failure that stops the attach until it is started again.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TerminalAttachFailure {
    /// Sign in again.
    AuthenticationRequired {
        /// What the server or platform said.
        detail: String,
    },
    /// Not allowed to attach this way (typing needs owner access).
    AccessDenied {
        /// What the server said.
        detail: String,
        /// The denied attach was already read-only.
        read_only: bool,
    },
    /// The server's bridge failed.
    ServerError {
        /// The reason.
        reason: String,
    },
    /// No server replica could reach the terminal's host.
    WrongReplica,
    /// The reconnect budget ran out; foreground or start again to retry.
    ReconnectBudgetExhausted {
        /// Why the last attempt ended.
        last: CoreError,
        /// Attempts made.
        attempts: u32,
    },
    /// A failure retrying cannot fix.
    Unrecoverable {
        /// Why.
        error: CoreError,
    },
}

/// The user-visible attach state.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TerminalAttachState {
    /// Never started.
    Idle,
    /// The first attempt is in flight.
    Connecting,
    /// Streaming.
    Attached {
        /// Input is disabled.
        read_only: bool,
    },
    /// The connection was lost; another attempt is pending or in flight.
    Reconnecting {
        /// Why the last attempt ended.
        reason: CoreError,
        /// Consecutive failed attempts.
        failures: u32,
        /// The wait before the next attempt, in ms.
        delay_ms: u64,
    },
    /// The server ended the attach deliberately.
    Closed {
        /// Why.
        reason: TerminalClosedReason,
    },
    /// Stopped by the app.
    Stopped,
    /// A failure.
    Failed {
        /// The failure.
        failure: TerminalAttachFailure,
        /// For display.
        message: String,
        /// The user must sign in again.
        requires_sign_in: bool,
    },
}

impl From<core::AttachState> for TerminalAttachState {
    fn from(state: core::AttachState) -> Self {
        match state {
            core::AttachState::Idle => Self::Idle,
            core::AttachState::Connecting => Self::Connecting,
            core::AttachState::Attached { read_only } => Self::Attached { read_only },
            core::AttachState::Reconnecting {
                reason,
                failures,
                delay_ms,
            } => Self::Reconnecting {
                reason: reason.into(),
                failures,
                delay_ms,
            },
            core::AttachState::Closed { reason } => Self::Closed {
                reason: match reason {
                    core::ClosedReason::TerminalEnded { reason } => {
                        TerminalClosedReason::TerminalEnded { reason }
                    }
                    core::ClosedReason::Detached { reason } => {
                        TerminalClosedReason::Detached { reason }
                    }
                    core::ClosedReason::ServerClosed { code, reason } => {
                        TerminalClosedReason::ServerClosed { code, reason }
                    }
                },
            },
            core::AttachState::Stopped => Self::Stopped,
            core::AttachState::Failed { error } => Self::Failed {
                message: error.to_string(),
                requires_sign_in: error.requires_sign_in(),
                failure: match error {
                    core::AttachFailure::AuthenticationRequired { detail } => {
                        TerminalAttachFailure::AuthenticationRequired { detail }
                    }
                    core::AttachFailure::AccessDenied { detail, read_only } => {
                        TerminalAttachFailure::AccessDenied { detail, read_only }
                    }
                    core::AttachFailure::ServerError { reason } => {
                        TerminalAttachFailure::ServerError { reason }
                    }
                    core::AttachFailure::WrongReplica => TerminalAttachFailure::WrongReplica,
                    core::AttachFailure::ReconnectBudgetExhausted { last, attempts } => {
                        TerminalAttachFailure::ReconnectBudgetExhausted {
                            last: last.into(),
                            attempts,
                        }
                    }
                    core::AttachFailure::Unrecoverable(error) => {
                        TerminalAttachFailure::Unrecoverable {
                            error: error.into(),
                        }
                    }
                },
            },
        }
    }
}

/// Why typed input was not sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TerminalInputDropReason {
    /// The socket is not open. Input is never buffered for a later attach.
    NotAttached,
    /// The attach is read-only.
    ReadOnly,
}

/// Receives one attach's output, on a background thread, in order. Implementations must
/// return quickly and hop to their own executor, keeping the order.
#[uniffi::export(with_foreign)]
pub trait TerminalAttachListener: Send + Sync {
    /// The attach state changed.
    fn on_state(&self, state: TerminalAttachState);
    /// Pane output for the emulator.
    fn on_output(&self, bytes: Vec<u8>);
    /// A reattach is starting: clear the screen before the next output (the server reseeds it).
    fn on_reset_screen(&self);
    /// tmux copied a selection: offer it to the local clipboard.
    fn on_clipboard_write(&self, text: String);
    /// Input was not sent.
    fn on_input_dropped(&self, byte_count: u64, reason: TerminalInputDropReason);
    /// A frame the client could not use (unknown, malformed, or a clipboard write that is not
    /// UTF-8). The attach continues; show or log it.
    fn on_notice(&self, message: String);
}

/// One input for an attach driver's loop.
enum AttachMsg {
    Input(core::AttachInput),
    Shutdown,
}

/// The socket of one attempt and its write queue.
struct AttachSocket {
    handle: Arc<dyn WebSocketHandle>,
    outbox: UnboundedSender<omnigent_core::realtime::SocketMessage>,
}

/// The loop's state; only the loop task touches it.
struct AttachLoop {
    machine: core::TerminalAttach<SplitMix64>,
    sessions: Arc<Sessions>,
    host: Host,
    transport: Option<Arc<dyn WebSocketTransport>>,
    listener: Arc<dyn TerminalAttachListener>,
    session_id: String,
    terminal_id: String,
    tx: UnboundedSender<AttachMsg>,
    sockets: HashMap<AttemptId, AttachSocket>,
    timers: HashMap<u64, AbortHandle>,
}

impl AttachLoop {
    async fn run(mut self, mut rx: UnboundedReceiver<AttachMsg>) {
        while let Some(message) = rx.next().await {
            match message {
                AttachMsg::Input(input) => self.handle(input),
                AttachMsg::Shutdown => {
                    self.handle(core::AttachInput::Stop);
                    for timer in self.timers.values() {
                        timer.abort();
                    }
                    return;
                }
            }
        }
    }

    fn handle(&mut self, input: core::AttachInput) {
        // An ended socket and a fired timer have nothing left to close or cancel.
        match &input {
            core::AttachInput::Ended { attempt, .. } => {
                self.sockets.remove(attempt);
            }
            core::AttachInput::TimerFired { token } => {
                self.timers.remove(&token.id);
            }
            _ => {}
        }
        let outputs = self.machine.handle(self.host.now_ms(), input);
        for output in outputs {
            self.output(output);
        }
    }

    fn output(&mut self, output: core::AttachOutput) {
        use core::AttachOutput as O;
        match output {
            O::Connect { attempt, options } => self.connect(attempt, &options),
            O::Send { attempt, message } => {
                if let Some(socket) = self.sockets.get(&attempt) {
                    post(&socket.outbox, message);
                }
            }
            O::Close {
                attempt,
                code,
                reason,
            } => {
                if let Some(socket) = self.sockets.remove(&attempt) {
                    socket.handle.close(code, reason);
                }
            }
            O::ScheduleTimer { token, delay_ms } => {
                let tx = self.tx.clone();
                let timer = self.host.after(delay_ms, move || {
                    post(
                        &tx,
                        AttachMsg::Input(core::AttachInput::TimerFired { token }),
                    );
                });
                self.timers.insert(token.id, timer);
            }
            O::CancelTimer { token } => {
                if let Some(timer) = self.timers.remove(&token.id) {
                    timer.abort();
                }
            }
            O::StateChanged { state } => self.listener.on_state(state.into()),
            O::ResetScreen => self.listener.on_reset_screen(),
            O::Output { bytes } => self.listener.on_output(bytes),
            // tmux answers these terminal queries itself; nothing for the renderer to do.
            O::TmuxReplies { .. } => {}
            O::ClipboardWrite { data } => match String::from_utf8(data) {
                Ok(text) => self.listener.on_clipboard_write(text),
                Err(error) => self
                    .listener
                    .on_notice(format!("a clipboard write was not UTF-8 text: {error}")),
            },
            O::UnknownFrame { frame_type, .. } => self
                .listener
                .on_notice(format!("unknown terminal frame {frame_type:?}")),
            O::FrameRejected { error } => self
                .listener
                .on_notice(format!("unreadable terminal frame: {error}")),
            O::InputDropped { len, reason } => self.listener.on_input_dropped(
                u64::try_from(len).unwrap_or(u64::MAX),
                match reason {
                    core::DropReason::NotAttached => TerminalInputDropReason::NotAttached,
                    core::DropReason::ReadOnly => TerminalInputDropReason::ReadOnly,
                },
            ),
        }
    }

    fn connect(&mut self, attempt: AttemptId, options: &core::AttachOptions) {
        let failed = |message: String| core::AttachInput::ConnectFailed {
            attempt,
            error: omnigent_core::http::TransportError::Other { message },
        };
        let Some(transport) = self.transport.clone() else {
            self.handle(failed(
                "terminals are not available in the offline demo".into(),
            ));
            return;
        };
        let request = match self.sessions.terminal_attach_request(
            &self.session_id,
            &self.terminal_id,
            options,
        ) {
            Ok(request) => request,
            Err(error) => {
                self.handle(failed(error.to_string()));
                return;
            }
        };
        let tx = self.tx.clone();
        let sink = MessageSink::new(move |event| {
            let input = match event {
                SocketEvent::Opened => core::AttachInput::Opened { attempt },
                SocketEvent::Message(message) => core::AttachInput::Message { attempt, message },
                SocketEvent::Ended(end) => core::AttachInput::Ended { attempt, end },
            };
            post(&tx, AttachMsg::Input(input));
        });
        let handle = match transport.open_socket(request.into(), sink) {
            Ok(handle) => handle,
            Err(error) => {
                self.handle(core::AttachInput::ConnectFailed {
                    attempt,
                    error: error.into(),
                });
                return;
            }
        };
        let (outbox, mut queued) = mpsc::unbounded::<omnigent_core::realtime::SocketMessage>();
        self.sockets.insert(
            attempt,
            AttachSocket {
                handle: Arc::clone(&handle),
                outbox,
            },
        );
        let tx = self.tx.clone();
        self.host.spawn(async move {
            while let Some(message) = queued.next().await {
                let sent = match message {
                    omnigent_core::realtime::SocketMessage::Text(text) => {
                        handle.send_text(text).await
                    }
                    omnigent_core::realtime::SocketMessage::Binary(bytes) => {
                        handle.send_binary(bytes).await
                    }
                };
                if let Err(error) = sent {
                    post(
                        &tx,
                        AttachMsg::Input(core::AttachInput::SendFailed {
                            attempt,
                            error: error.into(),
                        }),
                    );
                    break;
                }
            }
        });
    }
}

/// One terminal attach.
///
/// The core's `TerminalAttach` machine, run over the host's WebSocket and timers, with requests
/// carrying the connection's current bearer and org header. Output goes to its
/// [`TerminalAttachListener`]. Dropping it detaches.
#[derive(uniffi::Object)]
pub struct TerminalAttachDriver {
    tx: UnboundedSender<AttachMsg>,
}

impl fmt::Debug for TerminalAttachDriver {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TerminalAttachDriver")
    }
}

impl Drop for TerminalAttachDriver {
    fn drop(&mut self) {
        post(&self.tx, AttachMsg::Shutdown);
    }
}

#[uniffi::export]
impl TerminalAttachDriver {
    /// Attaches (or reattaches after closing, stopping or failing) with a fresh reconnect budget.
    pub fn start(&self) {
        post(&self.tx, AttachMsg::Input(core::AttachInput::Start));
    }

    /// Detaches and closes the socket.
    pub fn stop(&self) {
        post(&self.tx, AttachMsg::Input(core::AttachInput::Stop));
    }

    /// The app or window became visible: a pending reconnect dials now, and an exhausted budget
    /// starts over.
    pub fn foreground(&self) {
        post(&self.tx, AttachMsg::Input(core::AttachInput::Foreground));
    }

    /// Bytes the user typed, pasted or produced with the mouse, encoded by the renderer. Input
    /// while not attached or on a read-only attach is reported with `on_input_dropped`.
    pub fn send_input(&self, bytes: Vec<u8>) {
        post(
            &self.tx,
            AttachMsg::Input(core::AttachInput::Input { bytes }),
        );
    }

    /// The renderer's grid size changed; sent once per change and first on every attach.
    ///
    /// # Errors
    ///
    /// [`CoreError::InvalidState`] for a zero or oversized dimension.
    pub fn resize(&self, cols: u16, rows: u16) -> Result<(), CoreError> {
        let size = core::GridSize::new(cols, rows).ok_or_else(|| {
            CoreError::invalid_state(format!("{cols}x{rows} is not a usable terminal size"))
        })?;
        post(
            &self.tx,
            AttachMsg::Input(core::AttachInput::Resize { size }),
        );
        Ok(())
    }
}

#[uniffi::export]
impl ClientCore {
    /// Every terminal of `session_id`, oldest first. An open session's inventory is replaced
    /// and published as `TerminalsChanged`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Terminal`].
    pub async fn list_terminals(
        &self,
        session_id: String,
    ) -> Result<Vec<TerminalResource>, CoreError> {
        let terminals = self
            .sessions()
            .list_terminals(&session_id)
            .await
            .map_err(terminal_error)?;
        self.post(crate::engine::Msg::TerminalsLoaded {
            session_id,
            terminals: terminals.clone(),
        });
        Ok(terminals.into_iter().map(Into::into).collect())
    }

    /// The terminal names `session_id`'s agent declares, in declaration order: the only names
    /// `create_terminal` accepts (for a native harness, the host's shells with `$SHELL` first).
    /// Empty when the agent declares none, so no terminal can be created; `None` when the
    /// server does not report them.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`].
    pub async fn declared_terminal_names(
        &self,
        session_id: String,
    ) -> Result<Option<Vec<String>>, CoreError> {
        self.sessions()
            .declared_terminal_names(&session_id)
            .await
            .map_err(CoreError::from)
    }

    /// Re-reads `session_id`'s terminals in the background; the result arrives as
    /// `TerminalsChanged`, a failure as an `Error` event for the session.
    pub fn refresh_terminals(&self, session_id: String) {
        self.post(crate::engine::Msg::RefreshTerminals { session_id });
    }

    /// Launches the declared terminal `terminal_name` (for example a host shell such as `zsh`)
    /// with a fresh session key.
    ///
    /// # Errors
    ///
    /// [`CoreError::Terminal`], [`CoreError::Entropy`].
    pub async fn create_terminal(
        &self,
        session_id: String,
        terminal_name: String,
    ) -> Result<TerminalResource, CoreError> {
        let entropy = self.inner.entropy()?;
        let bytes = omnigent_core::auth::EntropySource::random_bytes(entropy, 8)
            .map_err(CoreError::from)?;
        let mut seed = [0_u8; 8];
        for (slot, byte) in seed.iter_mut().zip(bytes) {
            *slot = byte;
        }
        let create = core::CreateTerminal::new_shell(terminal_name, u64::from_le_bytes(seed));
        let resource = self
            .sessions()
            .create_terminal(&session_id, &create)
            .await
            .map_err(terminal_error)?;
        self.post(crate::engine::Msg::TerminalUpserted {
            session_id,
            terminal: resource.clone(),
        });
        Ok(resource.into())
    }

    /// Closes a terminal. Returns `false` when it was already gone.
    ///
    /// # Errors
    ///
    /// [`CoreError::Terminal`].
    pub async fn delete_terminal(
        &self,
        session_id: String,
        terminal_id: String,
    ) -> Result<bool, CoreError> {
        let outcome = self
            .sessions()
            .delete_terminal(&session_id, &terminal_id)
            .await
            .map_err(terminal_error)?;
        self.post(crate::engine::Msg::TerminalRemoved {
            session_id,
            terminal_id,
        });
        Ok(outcome == core::DeleteOutcome::Deleted)
    }

    /// An attach driver for `terminal_id` of `session_id`, idle until `start`. A caller below
    /// owner `permission_level` attaches read-only; `host_id` routes the socket on sharded
    /// deployments.
    pub fn terminal_attach(
        &self,
        session_id: String,
        terminal_id: String,
        permission_level: Option<i64>,
        host_id: Option<String>,
        listener: Arc<dyn TerminalAttachListener>,
    ) -> Arc<TerminalAttachDriver> {
        let (tx, rx) = mpsc::unbounded();
        let host = self.inner.host.clone();
        let seed = self.unix_ms();
        let attach = AttachLoop {
            machine: core::TerminalAttach::new(
                core::AttachConfig::default(),
                core::attach_options(permission_level, host_id.as_deref()),
                SplitMix64::new(seed),
            ),
            sessions: Arc::clone(&self.inner.sessions),
            host: host.clone(),
            transport: self.inner.sockets.clone(),
            listener,
            session_id,
            terminal_id,
            tx: tx.clone(),
            sockets: HashMap::new(),
            timers: HashMap::new(),
        };
        host.spawn(attach.run(rx));
        Arc::new(TerminalAttachDriver { tx })
    }
}

/// The `TerminalsChanged` event for an inventory's rows and harness view.
pub(crate) fn terminals_event(
    session_id: &str,
    rows: Vec<core::TerminalRow>,
    harness: HarnessTerminal,
) -> CoreEvent {
    CoreEvent::TerminalsChanged {
        session_id: session_id.to_owned(),
        terminals: rows.into_iter().map(Into::into).collect(),
        harness,
    }
}

#[cfg(test)]
#[path = "terminal_tests.rs"]
mod tests;
