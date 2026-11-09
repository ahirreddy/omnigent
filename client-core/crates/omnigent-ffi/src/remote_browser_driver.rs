//! [`RemoteBrowserDriver`]: the core's attach machine run over the host's WebSocket and timers.

use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use futures::StreamExt;
use futures::channel::mpsc::{self, UnboundedReceiver, UnboundedSender};
use futures::future::AbortHandle;
use omnigent_core::realtime::{AttemptId, SocketMessage, SplitMix64};
use omnigent_core::remote_browser as core;
use omnigent_protocol::remote_browser as wire;

use super::{
    ImeInput, ImeOp, ImeRange, KeyInput, KeyKind, KeyframeReason, MouseButton, MouseInput,
    MouseKind, NavOp, RemoteBrowserCapabilities, RemoteBrowserCursor, RemoteBrowserListener,
    RemoteBrowserNotice, RemoteBrowserSettingsUpdate, RemoteBrowserSnapshot, RemoteCursorImage,
    RemoteEditOp, RemoteRect, RemoteScrollMetrics, RemoteSelection, RemoteViewport,
    RemoteViewportRequest, RemoteViewportScope, StillImage, StillKind, TouchInput, TouchKind,
    invalid_input, mode_of,
};
use crate::errors::CoreError;
use crate::host::{MessageSink, SocketEvent, WebSocketHandle, WebSocketTransport};
use crate::runtime::{Host, Sessions, post};

/// Frames the video queue holds before it skips to the next keyframe.
const VIDEO_QUEUE_FRAMES: usize = 4;

/// The tab an attach targets.
pub(super) struct Target {
    pub(super) session_id: String,
    pub(super) tab_id: String,
    pub(super) options: core::AttachOptions,
}

enum Msg {
    Input(core::AttachInput),
    Shutdown,
}

struct Socket {
    handle: Arc<dyn WebSocketHandle>,
    outbox: UnboundedSender<SocketMessage>,
}

/// The latest-wins hand-off from the attach loop to the video task.
struct VideoPipe {
    queue: Mutex<core::VideoQueue>,
    armed: AtomicBool,
    wake: UnboundedSender<()>,
}

impl VideoPipe {
    /// Queues a frame; returns whether the queue overflowed and a keyframe is needed.
    fn push(&self, frame: core::VideoFrame) -> bool {
        let outcome = self
            .queue
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(frame);
        if !self.armed.swap(true, Ordering::AcqRel) {
            post(&self.wake, ());
        }
        matches!(outcome, core::QueuePush::Overflowed { .. })
    }

    fn pop(&self) -> Option<core::VideoFrame> {
        self.queue
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop()
    }

    fn clear(&self) {
        self.queue
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clear();
    }
}

struct Loop {
    machine: core::RemoteBrowserAttach<SplitMix64>,
    sessions: Arc<Sessions>,
    host: Host,
    transport: Option<Arc<dyn WebSocketTransport>>,
    listener: Arc<dyn RemoteBrowserListener>,
    target: Target,
    tx: UnboundedSender<Msg>,
    sockets: HashMap<AttemptId, Socket>,
    timers: HashMap<u64, AbortHandle>,
    video: Arc<VideoPipe>,
    state_dirty: bool,
}

impl Loop {
    async fn run(mut self, mut rx: UnboundedReceiver<Msg>) {
        while let Some(message) = rx.next().await {
            match message {
                Msg::Input(input) => self.handle(input),
                Msg::Shutdown => {
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
        let outputs = self.machine.handle(self.host.now_ms(), input);
        for output in outputs {
            self.output(output);
        }
        self.flush_state();
    }

    /// Sends the snapshot if the state changed since the last one.
    fn flush_state(&mut self) {
        if !std::mem::take(&mut self.state_dirty) {
            return;
        }
        let (snapshot, cursor_error) = snapshot(&self.machine);
        self.listener.on_state(snapshot);
        if let Some(error) = cursor_error {
            self.listener.on_notice(RemoteBrowserNotice {
                message: error,
                user_facing: false,
            });
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
                self.video.clear();
            }
            O::ScheduleTimer { token, delay_ms } => {
                let tx = self.tx.clone();
                let timer = self.host.after(delay_ms, move || {
                    post(&tx, Msg::Input(core::AttachInput::TimerFired { token }));
                });
                self.timers.insert(token.id, timer);
            }
            O::CancelTimer { token } => {
                if let Some(timer) = self.timers.remove(&token.id) {
                    timer.abort();
                }
            }
            O::ConnectionChanged { .. } | O::TabChanged => self.state_dirty = true,
            O::Video(frame) => {
                if self.video.push(frame) {
                    self.handle(core::AttachInput::RequestKeyframe {
                        reason: wire::KeyframeReason::Flush,
                    });
                }
            }
            O::Still { kind, pts_us, jpeg } => {
                self.flush_state();
                self.listener.on_still(StillImage {
                    kind: if kind == wire::StillKind::Thumbnail {
                        StillKind::Thumbnail
                    } else {
                        StillKind::Still
                    },
                    pts_us,
                    jpeg,
                });
            }
            O::Clipboard { op, text } => {
                self.flush_state();
                let op = if op == wire::EditOp::Cut {
                    RemoteEditOp::Cut
                } else {
                    RemoteEditOp::Copy
                };
                self.listener.on_clipboard(op, text);
            }
            O::TabEnded { reason } => {
                self.flush_state();
                self.listener.on_closed(reason.map(Into::into));
            }
            O::Notice(notice) => {
                self.flush_state();
                self.listener.on_notice(describe(&notice));
            }
        }
    }

    fn connect(&mut self, attempt: AttemptId, options: &core::AttachOptions) {
        let failed = |message: String| core::AttachInput::ConnectFailed {
            attempt,
            error: omnigent_core::http::TransportError::Other { message },
        };
        let Some(transport) = self.transport.clone() else {
            self.handle(failed(
                "remote browsers are not available in the offline demo".into(),
            ));
            return;
        };
        let request = match self.sessions.remote_browser_attach_request(
            &self.target.session_id,
            &self.target.tab_id,
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
            post(&tx, Msg::Input(input));
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
        let (outbox, mut queued) = mpsc::unbounded::<SocketMessage>();
        self.sockets.insert(
            attempt,
            Socket {
                handle: Arc::clone(&handle),
                outbox,
            },
        );
        let tx = self.tx.clone();
        self.host.spawn(async move {
            while let Some(message) = queued.next().await {
                let sent = match message {
                    SocketMessage::Text(text) => handle.send_text(text).await,
                    SocketMessage::Binary(bytes) => handle.send_binary(bytes).await,
                };
                if let Err(error) = sent {
                    post(
                        &tx,
                        Msg::Input(core::AttachInput::SendFailed {
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

/// The listener snapshot of `machine`, and why a custom cursor could not be decoded.
fn snapshot(
    machine: &core::RemoteBrowserAttach<SplitMix64>,
) -> (RemoteBrowserSnapshot, Option<String>) {
    let tab = machine.tab();
    let (custom, cursor_error) = match tab.custom_cursor() {
        None => (None, None),
        Some(Ok(image)) => (
            Some(RemoteCursorImage {
                png: image.png,
                hotspot_x: image.hotspot_x,
                hotspot_y: image.hotspot_y,
                scale: image.scale,
            }),
            None,
        ),
        Some(Err(error)) => (None, Some(error)),
    };
    let keyword = if custom.is_none() && tab.cursor_keyword() == "custom" {
        "default".to_owned()
    } else {
        tab.cursor_keyword().to_owned()
    };
    let snapshot = RemoteBrowserSnapshot {
        connection: machine.connection().clone().into(),
        mode: tab.mode.as_ref().map(mode_of),
        profile: tab.profile.clone(),
        host_version: tab.host_version.clone(),
        nav: tab.nav.clone().map(Into::into),
        control: tab.control.clone().map(Into::into),
        wants_control: machine.wants_control(),
        cursor: RemoteBrowserCursor { keyword, custom },
        text_input: tab.text_input.clone().into(),
        viewport: tab.viewport.map(Into::into),
        viewport_scope: if tab.viewport_scope == wire::ViewportScope::Control {
            RemoteViewportScope::Control
        } else {
            RemoteViewportScope::Tab
        },
        mobile: tab.mobile.clone().into(),
        agent_viewport: tab.agent_viewport.map(Into::into),
        selection: tab.selection.map(|selection| RemoteSelection {
            editable: selection.editable,
            collapsed: selection.collapsed,
            length: selection.length,
            rect: selection.rect.map(|rect| RemoteRect {
                x: rect.x,
                y: rect.y,
                width: rect.w,
                height: rect.h,
            }),
        }),
        scroll: tab.scroll.map(|scroll| RemoteScrollMetrics {
            x: scroll.x,
            y: scroll.y,
            content_width: scroll.content_w,
            content_height: scroll.content_h,
            viewport_width: scroll.viewport_w,
            viewport_height: scroll.viewport_h,
        }),
        capabilities: RemoteBrowserCapabilities {
            viewport_scope: tab.has_feature(wire::features::VIEWPORT_SCOPE),
            mobile_emulation: tab.has_feature(wire::features::MOBILE_EMULATION),
            edit: tab.has_feature(wire::features::EDIT),
            selection: tab.has_feature(wire::features::SELECTION),
            scroll_metrics: tab.has_feature(wire::features::SCROLL_METRICS),
            touch: tab.has_feature(wire::features::TOUCH),
        },
        settings: tab.settings.clone().map(Into::into),
        stats: tab.stats.clone().map(Into::into),
        dialogs: tab.dialogs.iter().cloned().map(Into::into).collect(),
    };
    (snapshot, cursor_error)
}

const fn input_name(input: core::InputKind) -> &'static str {
    match input {
        core::InputKind::Mouse => "mouse input",
        core::InputKind::Key => "key input",
        core::InputKind::Ime => "text input",
        core::InputKind::Nav => "navigation",
        core::InputKind::Resize => "resize",
        core::InputKind::DialogReply => "dialog reply",
        core::InputKind::Control => "control request",
        core::InputKind::Settings => "settings change",
        core::InputKind::Still => "still request",
        core::InputKind::Edit => "edit command",
        core::InputKind::Touch => "touch input",
        core::InputKind::MobileEmulation => "mobile emulation",
    }
}

/// The plain-language text of a notice the user can act on; `None` for diagnostics.
fn user_message(notice: &core::Notice) -> Option<String> {
    use core::Notice as N;
    match notice {
        N::HostError(error) => match error.code.as_str() {
            "navigation_failed" => Some(format!("The page could not be loaded: {}", error.message)),
            "unsupported" => Some(sentence(&error.message)),
            "control_not_permitted" => Some("This browser tab is view-only.".to_owned()),
            "not_in_control" => Some("Take over to control the page.".to_owned()),
            _ => None,
        },
        N::InputDropped { reason, input } => match reason {
            core::DropReason::ReadOnly => Some("This browser tab is view-only.".to_owned()),
            core::DropReason::NotInControl => Some(format!(
                "{} not sent: take control first",
                input_name(*input)
            )),
            core::DropReason::Unsupported => Some(format!(
                "The agent's browser is too old for {}; update it on the agent's machine.",
                input_name(*input)
            )),
            core::DropReason::NotAttached => None,
        },
        _ => None,
    }
}

/// `text` with a capital first letter and a final period.
fn sentence(text: &str) -> String {
    let mut chars = text.chars();
    let mut out: String = chars
        .next()
        .map(|first| first.to_uppercase().chain(chars).collect())
        .unwrap_or_default();
    if !out.ends_with('.') {
        out.push('.');
    }
    out
}

/// A notice as display or log text.
fn describe(notice: &core::Notice) -> RemoteBrowserNotice {
    use core::Notice as N;
    if let Some(message) = user_message(notice) {
        return RemoteBrowserNotice {
            message,
            user_facing: true,
        };
    }
    let message = match notice {
        N::UnknownMessage { message_type } => {
            format!("ignored an unknown browser message {message_type:?}")
        }
        N::MalformedMessage(error) => format!("unreadable browser message: {error}"),
        N::MalformedFrame(error) => format!("unreadable browser frame: {error}"),
        N::UnknownMediaKind { kind } => format!("ignored an unknown browser frame kind {kind}"),
        N::VideoDropped(core::VideoDrop::AwaitingKeyframe { stream_id }) => {
            format!("dropped a video frame of stream {stream_id} while waiting for a keyframe")
        }
        N::VideoDropped(core::VideoDrop::Malformed(error)) => {
            format!("dropped an unreadable video frame: {error}")
        }
        N::HostError(error) => format!("browser host error {}: {}", error.code, error.message),
        N::InputDropped { input, reason } => {
            let why = match reason {
                core::DropReason::NotAttached => "the browser is not connected",
                core::DropReason::ReadOnly => "this view is read-only",
                core::DropReason::NotInControl => "take control first",
                core::DropReason::Unsupported => "the browser host is too old for it",
            };
            format!("{} not sent: {why}", input_name(*input))
        }
        N::InvalidInput(error) => format!("invalid browser input: {error}"),
    };
    RemoteBrowserNotice {
        message,
        user_facing: false,
    }
}

/// One remote browser attach.
///
/// The core's `RemoteBrowserAttach` machine, run over the host's WebSocket and timers, with
/// requests carrying the connection's current bearer and org header. Output goes to its
/// [`RemoteBrowserListener`]. Dropping it detaches.
#[derive(uniffi::Object)]
pub struct RemoteBrowserDriver {
    tx: UnboundedSender<Msg>,
}

impl fmt::Debug for RemoteBrowserDriver {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("RemoteBrowserDriver")
    }
}

impl Drop for RemoteBrowserDriver {
    fn drop(&mut self) {
        post(&self.tx, Msg::Shutdown);
    }
}

impl RemoteBrowserDriver {
    fn send(&self, input: core::AttachInput) {
        post(&self.tx, Msg::Input(input));
    }
}

const fn mouse_kind(kind: MouseKind) -> wire::MouseKind {
    match kind {
        MouseKind::Move => wire::MouseKind::Move,
        MouseKind::Down => wire::MouseKind::Down,
        MouseKind::Up => wire::MouseKind::Up,
        MouseKind::Wheel => wire::MouseKind::Wheel,
        MouseKind::Leave => wire::MouseKind::Leave,
    }
}

const fn text_range(range: ImeRange) -> wire::TextRange {
    wire::TextRange {
        start: range.start,
        end: range.end,
    }
}

#[uniffi::export]
impl RemoteBrowserDriver {
    /// Attaches (or reattaches after closing, stopping or failing) with a fresh reconnect budget.
    pub fn start(&self) {
        self.send(core::AttachInput::Start);
    }

    /// Detaches and closes the socket.
    pub fn stop(&self) {
        self.send(core::AttachInput::Stop);
    }

    /// The app or window became visible: a pending reconnect dials now, and an exhausted budget
    /// starts over.
    pub fn foreground(&self) {
        self.send(core::AttachInput::Foreground);
    }

    /// The local tab was shown or hidden; hidden tabs get no video.
    pub fn set_visible(&self, visible: bool) {
        self.send(core::AttachInput::SetVisible { visible });
    }

    /// Asks for an IDR, for example after a decoder failure or flush.
    pub fn request_keyframe(&self, reason: KeyframeReason) {
        let reason = match reason {
            KeyframeReason::DecoderError => wire::KeyframeReason::DecoderError,
            KeyframeReason::Flush => wire::KeyframeReason::Flush,
            KeyframeReason::Gap => wire::KeyframeReason::Gap,
            KeyframeReason::User => wire::KeyframeReason::User,
        };
        self.send(core::AttachInput::RequestKeyframe { reason });
    }

    /// Asks for one JPEG, delivered through `on_still`.
    pub fn request_still(&self, kind: StillKind) {
        let kind = match kind {
            StillKind::Still => wire::StillKind::Still,
            StillKind::Thumbnail => wire::StillKind::Thumbnail,
        };
        self.send(core::AttachInput::RequestStill { kind });
    }

    /// Mouse input. Moves and wheel ticks are coalesced; nothing is sent unless this attach
    /// holds control.
    ///
    /// # Errors
    ///
    /// [`CoreError::RemoteBrowser`] (`InvalidInput`) for a non-finite coordinate, a `Down` or
    /// `Up` without a button or click count, or undefined modifier bits.
    pub fn mouse(&self, input: MouseInput) -> Result<(), CoreError> {
        let discrete = matches!(input.kind, MouseKind::Down | MouseKind::Up);
        let wheel = input.kind == MouseKind::Wheel;
        let event = wire::MouseEvent {
            kind: mouse_kind(input.kind),
            x: input.x,
            y: input.y,
            button: input.button.map(|button| match button {
                MouseButton::Left => wire::MouseButton::Left,
                MouseButton::Middle => wire::MouseButton::Middle,
                MouseButton::Right => wire::MouseButton::Right,
            }),
            clicks: discrete.then_some(input.clicks),
            modifiers: input.modifiers,
            dx: wheel.then_some(input.dx),
            dy: wheel.then_some(input.dy),
        };
        core::input::validate_mouse(&event).map_err(|error| invalid_input(&error))?;
        self.send(core::AttachInput::Mouse(event));
        Ok(())
    }

    /// Key input, resolved to DOM `code` and `key` here.
    ///
    /// # Errors
    ///
    /// [`CoreError::RemoteBrowser`] (`InvalidInput`) for a `Char` without text or undefined
    /// modifier bits.
    pub fn key(&self, input: KeyInput) -> Result<(), CoreError> {
        let (code, key) = core::keymap::resolve(
            input.code.as_deref(),
            input.mac_key_code,
            input.hid_usage,
            &input.key,
        );
        let event = wire::KeyEvent {
            kind: match input.kind {
                KeyKind::RawKeyDown => wire::KeyKind::RawKeyDown,
                KeyKind::KeyUp => wire::KeyKind::KeyUp,
                KeyKind::Char => wire::KeyKind::Char,
            },
            code,
            key,
            text: input.text,
            modifiers: input.modifiers,
            repeat: input.repeat,
        };
        core::input::validate_key(&event).map_err(|error| invalid_input(&error))?;
        self.send(core::AttachInput::Key(event));
        Ok(())
    }

    /// IME composition and commit.
    ///
    /// # Errors
    ///
    /// [`CoreError::RemoteBrowser`] (`InvalidInput`) for a backwards range or missing text.
    pub fn ime(&self, input: ImeInput) -> Result<(), CoreError> {
        let event = wire::ImeEvent {
            op: match input.op {
                ImeOp::SetComposition => wire::ImeOp::SetComposition,
                ImeOp::Commit => wire::ImeOp::Commit,
                ImeOp::Finish => wire::ImeOp::Finish,
                ImeOp::Cancel => wire::ImeOp::Cancel,
            },
            text: input.text,
            selection: input.selection.map(text_range),
            replacement: input.replacement.map(text_range),
        };
        core::input::validate_ime(&event).map_err(|error| invalid_input(&error))?;
        self.send(core::AttachInput::Ime(event));
        Ok(())
    }

    /// Navigation (needs control).
    ///
    /// # Errors
    ///
    /// [`CoreError::RemoteBrowser`] (`InvalidInput`) for `Navigate` without an http(s) or
    /// `about:` URL.
    pub fn nav(&self, op: NavOp, url: Option<String>) -> Result<(), CoreError> {
        let command = wire::NavCommand {
            op: match op {
                NavOp::Navigate => wire::NavOp::Navigate,
                NavOp::Back => wire::NavOp::Back,
                NavOp::Forward => wire::NavOp::Forward,
                NavOp::Reload => wire::NavOp::Reload,
                NavOp::Stop => wire::NavOp::Stop,
            },
            url,
        };
        core::input::validate_nav(&command).map_err(|error| invalid_input(&error))?;
        self.send(core::AttachInput::Nav(command));
        Ok(())
    }

    /// "Fit to window" (needs control). Attaching never resizes.
    ///
    /// # Errors
    ///
    /// [`CoreError::RemoteBrowser`] (`InvalidInput`) outside 200–3840 px or DPR 1–3.
    pub fn resize(&self, viewport: RemoteViewport) -> Result<(), CoreError> {
        let viewport: wire::Viewport = viewport.into();
        core::input::validate_viewport(&viewport).map_err(|error| invalid_input(&error))?;
        self.send(core::AttachInput::Resize(viewport));
        Ok(())
    }

    /// The viewport this client wants while it holds control (protocol v1.1), or `None` for
    /// the agent's. Applied whenever this attach holds control, and re-applied after a
    /// reconnect; a v1 host gets a plain resize that is undone before hand-back.
    ///
    /// # Errors
    ///
    /// [`CoreError::RemoteBrowser`] (`InvalidInput`) outside 200–3840 px or DPR 1–3.
    pub fn set_viewport(&self, request: Option<RemoteViewportRequest>) -> Result<(), CoreError> {
        let request = request.map(|request| core::ViewportRequest {
            viewport: request.viewport.into(),
            mobile: request.mobile.into(),
        });
        if let Some(request) = &request {
            core::input::validate_viewport(&request.viewport)
                .map_err(|error| invalid_input(&error))?;
        }
        self.send(core::AttachInput::SetViewport(request));
        Ok(())
    }

    /// An edit command (needs control and a v1.1 host). Copy and cut answer through
    /// `on_clipboard`; the remote machine's clipboard is never used.
    ///
    /// # Errors
    ///
    /// [`CoreError::RemoteBrowser`] (`InvalidInput`) for a paste without text or over 512 KiB.
    pub fn edit(&self, op: RemoteEditOp, text: Option<String>) -> Result<(), CoreError> {
        let command = wire::EditCommand {
            op: op.into(),
            text,
        };
        core::input::validate_edit(&command).map_err(|error| invalid_input(&error))?;
        self.send(core::AttachInput::Edit(command));
        Ok(())
    }

    /// One touch point (needs control and a v1.1 host).
    ///
    /// # Errors
    ///
    /// [`CoreError::RemoteBrowser`] (`InvalidInput`) for a non-finite point, pressure outside
    /// 0–1, a negative radius or undefined modifier bits.
    pub fn touch(&self, input: TouchInput) -> Result<(), CoreError> {
        let event = wire::TouchEvent {
            kind: match input.kind {
                TouchKind::Start => wire::TouchKind::Start,
                TouchKind::Move => wire::TouchKind::Move,
                TouchKind::End => wire::TouchKind::End,
                TouchKind::Cancel => wire::TouchKind::Cancel,
            },
            id: input.id,
            x: input.x,
            y: input.y,
            radius: input.radius,
            pressure: input.pressure,
            modifiers: input.modifiers,
        };
        core::input::validate_touch(&event).map_err(|error| invalid_input(&error))?;
        self.send(core::AttachInput::Touch(event));
        Ok(())
    }

    /// Takes control (control mode only); kept across reconnects until released.
    pub fn take_control(&self) {
        self.send(core::AttachInput::TakeControl);
    }

    /// Hands control back to the agent.
    pub fn release_control(&self) {
        self.send(core::AttachInput::ReleaseControl);
    }

    /// Answers a JS dialog.
    pub fn reply_dialog(&self, id: String, accept: bool, text: Option<String>) {
        self.send(core::AttachInput::DialogReply(wire::DialogReply {
            id,
            accept,
            text,
        }));
    }

    /// Changes stream settings; fps, quality, scale and codec need control mode.
    pub fn update_settings(&self, update: RemoteBrowserSettingsUpdate) {
        self.send(core::AttachInput::UpdateSettings(update.into()));
    }
}

/// Starts the loop and the video task, and returns the driver.
pub(super) fn spawn(
    host: Host,
    sessions: Arc<Sessions>,
    transport: Option<Arc<dyn WebSocketTransport>>,
    target: Target,
    listener: Arc<dyn RemoteBrowserListener>,
    seed: u64,
) -> Arc<RemoteBrowserDriver> {
    let (tx, rx) = mpsc::unbounded();
    let (wake, mut woken) = mpsc::unbounded::<()>();
    let video = Arc::new(VideoPipe {
        queue: Mutex::new(core::VideoQueue::new(VIDEO_QUEUE_FRAMES)),
        armed: AtomicBool::new(false),
        wake,
    });
    let config = core::AttachConfig {
        client_name: format!("omnigent-native/{}", env!("CARGO_PKG_VERSION")),
        ..core::AttachConfig::default()
    };
    let machine =
        core::RemoteBrowserAttach::new(config, target.options.clone(), SplitMix64::new(seed));
    let pipe = Arc::clone(&video);
    let video_listener = Arc::clone(&listener);
    host.spawn(async move {
        while woken.next().await.is_some() {
            pipe.armed.store(false, Ordering::Release);
            while let Some(frame) = pipe.pop() {
                video_listener.on_video(frame.into());
            }
        }
    });
    let attach = Loop {
        machine,
        sessions,
        host: host.clone(),
        transport,
        listener,
        target,
        tx: tx.clone(),
        sockets: HashMap::new(),
        timers: HashMap::new(),
        video,
        state_dirty: false,
    };
    host.spawn(attach.run(rx));
    Arc::new(RemoteBrowserDriver { tx })
}

#[cfg(test)]
#[path = "remote_browser_driver_tests.rs"]
mod tests;
