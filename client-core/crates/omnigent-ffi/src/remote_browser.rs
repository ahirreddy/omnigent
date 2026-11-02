//! Remote agent browser.
//!
//! Records mirroring `omnigent_core::remote_browser`, the tab REST calls, the key and viewport
//! helpers, and [`RemoteBrowserDriver`], which runs the core's `RemoteBrowserAttach` machine
//! over the host's WebSocket and timer traits. Video goes to the listener through a bounded,
//! latest-wins queue, so a slow renderer skips to the next keyframe instead of growing a
//! backlog.

use std::sync::Arc;

use omnigent_core::remote_browser as core;
use omnigent_protocol::remote_browser as wire;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// [`core::RemoteBrowserError`]'s variants, plus `InvalidInput` for input rejected before
/// sending.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
#[allow(
    missing_docs,
    reason = "each variant mirrors the RemoteBrowserError variant of the same name"
)]
pub enum RemoteBrowserErrorKind {
    InvalidIdentifier,
    InvalidProfile,
    InvalidUrl,
    InvalidRequest,
    InvalidInput,
    NotConnected,
    Unauthorized,
    Forbidden,
    NotFound,
    BrowserUnavailable,
    RunnerUnavailable,
    Rejected,
    Redirected,
    HttpStatus,
    Transport,
    MalformedResponse,
}

pub(crate) fn remote_browser_error(error: core::RemoteBrowserError) -> CoreError {
    use core::RemoteBrowserError as E;
    let kind = match &error {
        E::InvalidIdentifier { .. } => RemoteBrowserErrorKind::InvalidIdentifier,
        E::InvalidProfile { .. } => RemoteBrowserErrorKind::InvalidProfile,
        E::InvalidUrl { .. } => RemoteBrowserErrorKind::InvalidUrl,
        E::InvalidRequest { .. } => RemoteBrowserErrorKind::InvalidRequest,
        E::NotConnected => RemoteBrowserErrorKind::NotConnected,
        E::Unauthorized { .. } => RemoteBrowserErrorKind::Unauthorized,
        E::Forbidden { .. } => RemoteBrowserErrorKind::Forbidden,
        E::NotFound { .. } => RemoteBrowserErrorKind::NotFound,
        E::BrowserUnavailable { .. } => RemoteBrowserErrorKind::BrowserUnavailable,
        E::RunnerUnavailable { .. } => RemoteBrowserErrorKind::RunnerUnavailable,
        E::Rejected { .. } => RemoteBrowserErrorKind::Rejected,
        E::Redirected { .. } => RemoteBrowserErrorKind::Redirected,
        E::HttpStatus { .. } => RemoteBrowserErrorKind::HttpStatus,
        E::Transport(_) => RemoteBrowserErrorKind::Transport,
        E::MalformedResponse { .. } => RemoteBrowserErrorKind::MalformedResponse,
    };
    CoreError::RemoteBrowser {
        kind,
        requires_sign_in: error.requires_sign_in(),
        message: error.to_string(),
    }
}

fn invalid_input(error: &core::InputError) -> CoreError {
    CoreError::RemoteBrowser {
        kind: RemoteBrowserErrorKind::InvalidInput,
        requires_sign_in: false,
        message: error.to_string(),
    }
}

/// How an attach connects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum RemoteBrowserMode {
    /// Watch only (read access).
    View,
    /// May take control (session owner).
    Control,
}

impl From<RemoteBrowserMode> for wire::AttachMode {
    fn from(mode: RemoteBrowserMode) -> Self {
        match mode {
            RemoteBrowserMode::View => Self::View,
            RemoteBrowserMode::Control => Self::Control,
        }
    }
}

fn mode_of(mode: &wire::AttachMode) -> RemoteBrowserMode {
    if *mode == wire::AttachMode::Control {
        RemoteBrowserMode::Control
    } else {
        RemoteBrowserMode::View
    }
}

/// The mode a caller with `permission_level` attaches with: `Control` for the owner (or with
/// permissions disabled), `View` otherwise.
#[must_use]
#[uniffi::export]
pub const fn remote_browser_mode(permission_level: Option<i64>) -> RemoteBrowserMode {
    if omnigent_core::terminal::can_type(permission_level) {
        RemoteBrowserMode::Control
    } else {
        RemoteBrowserMode::View
    }
}

/// Who owns a tab.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ControlOwner {
    /// The agent.
    Agent,
    /// The user.
    User,
    /// A value newer than this client.
    Unknown {
        /// The value as sent.
        value: String,
    },
}

impl From<wire::Owner> for ControlOwner {
    fn from(owner: wire::Owner) -> Self {
        match owner {
            wire::Owner::Agent => Self::Agent,
            wire::Owner::User => Self::User,
            wire::Owner::Unknown { value } => Self::Unknown { value },
        }
    }
}

/// Which connection holds the user's control, from this attach's point of view.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ControlHolder {
    /// No connection (the agent owns the tab, or the grace period after the holder left).
    Nobody,
    /// This attach: input is accepted.
    This,
    /// Another connection (for example the same user on another device).
    Other,
}

/// Who created a tab.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TabCreator {
    /// The agent.
    Agent,
    /// The user.
    User,
    /// A value newer than this client.
    Unknown {
        /// The value as sent.
        value: String,
    },
}

impl From<wire::CreatedBy> for TabCreator {
    fn from(creator: wire::CreatedBy) -> Self {
        match creator {
            wire::CreatedBy::Agent => Self::Agent,
            wire::CreatedBy::User => Self::User,
            wire::CreatedBy::Unknown { value } => Self::Unknown { value },
        }
    }
}

/// One remote browser tab of a session.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RemoteBrowserTab {
    /// Tab id, used in every browser route.
    pub id: String,
    /// The owning session, when the payload names one.
    pub session_id: Option<String>,
    /// Display name.
    pub name: String,
    /// URL.
    pub url: String,
    /// Title.
    pub title: String,
    /// Loading.
    pub loading: bool,
    /// Owner.
    pub owner: ControlOwner,
    /// The agent asked the user to take over.
    pub needs_attention: bool,
    /// Browser profile.
    pub profile: String,
    /// Creator.
    pub created_by: TabCreator,
    /// History back possible.
    pub can_go_back: bool,
    /// History forward possible.
    pub can_go_forward: bool,
    /// A thumbnail to show before attaching.
    pub thumbnail_url: Option<String>,
}

impl From<core::BrowserTab> for RemoteBrowserTab {
    fn from(tab: core::BrowserTab) -> Self {
        Self {
            id: tab.id,
            session_id: tab.session_id,
            name: tab.name,
            url: tab.url,
            title: tab.title,
            loading: tab.loading,
            owner: tab.owner.into(),
            needs_attention: tab.needs_attention,
            profile: tab.profile,
            created_by: tab.created_by.into(),
            can_go_back: tab.can_go_back,
            can_go_forward: tab.can_go_forward,
            thumbnail_url: tab.thumbnail_url,
        }
    }
}

/// A browser profile on the session's machine.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RemoteBrowserProfile {
    /// Name.
    pub name: String,
    /// Whether its host runs; `None` when unknown.
    pub running: Option<bool>,
}

/// A pending agent handoff.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RemoteBrowserHandoff {
    /// The elicitation id.
    pub id: String,
    /// What the agent asks the user to do.
    pub reason: String,
}

/// Control ownership.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RemoteBrowserControl {
    /// Who owns the tab.
    pub owner: ControlOwner,
    /// Which connection holds the user's control.
    pub holder: ControlHolder,
    /// The controlling user.
    pub user_id: Option<String>,
    /// A pending handoff.
    pub handoff: Option<RemoteBrowserHandoff>,
}

impl From<wire::ControlState> for RemoteBrowserControl {
    fn from(control: wire::ControlState) -> Self {
        Self {
            owner: control.owner.into(),
            holder: match control.holder {
                None => ControlHolder::Nobody,
                Some(wire::Holder::This) => ControlHolder::This,
                // An unknown holder is never this connection.
                Some(wire::Holder::Other | wire::Holder::Unknown { .. }) => ControlHolder::Other,
            },
            user_id: control.user_id,
            handoff: control.handoff.map(|handoff| RemoteBrowserHandoff {
                id: handoff.id,
                reason: handoff.reason,
            }),
        }
    }
}

/// Navigation state.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RemoteBrowserNav {
    /// URL.
    pub url: String,
    /// Title.
    pub title: String,
    /// Loading.
    pub loading: bool,
    /// Load progress, 0–1.
    pub progress: f64,
    /// History back possible.
    pub can_go_back: bool,
    /// History forward possible.
    pub can_go_forward: bool,
    /// Favicon.
    pub favicon_url: Option<String>,
}

impl From<wire::NavState> for RemoteBrowserNav {
    fn from(nav: wire::NavState) -> Self {
        Self {
            url: nav.url,
            title: nav.title,
            loading: nav.loading,
            progress: nav.progress,
            can_go_back: nav.can_go_back,
            can_go_forward: nav.can_go_forward,
            favicon_url: nav.favicon_url,
        }
    }
}

/// A decoded custom cursor.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RemoteCursorImage {
    /// PNG bytes.
    pub png: Vec<u8>,
    /// Hotspot x in image px.
    pub hotspot_x: f64,
    /// Hotspot y in image px.
    pub hotspot_y: f64,
    /// Image px per CSS px.
    pub scale: f64,
}

/// The cursor to draw locally.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RemoteBrowserCursor {
    /// A CSS `cursor` keyword; unknown ones are already mapped to `default`.
    pub keyword: String,
    /// The image when `keyword` is `custom`.
    pub custom: Option<RemoteCursorImage>,
}

/// The focused field's keyboard mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TextInputKind {
    /// Nothing editable is focused.
    None,
    /// Plain text (also any mode newer than this client).
    Text,
    /// Telephone number.
    Tel,
    /// URL.
    Url,
    /// Email.
    Email,
    /// Integer.
    Numeric,
    /// Decimal.
    Decimal,
    /// Search.
    Search,
}

/// A rectangle in viewport CSS px.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RemoteRect {
    /// Left.
    pub x: f64,
    /// Top.
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

/// Text input state.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RemoteBrowserTextInput {
    /// Keyboard mode.
    pub mode: TextInputKind,
    /// Caret position.
    pub caret: Option<RemoteRect>,
}

impl From<wire::TextInputUpdate> for RemoteBrowserTextInput {
    fn from(input: wire::TextInputUpdate) -> Self {
        use wire::TextInputMode as M;
        Self {
            mode: match input.mode {
                M::None => TextInputKind::None,
                M::Text | M::Unknown { .. } => TextInputKind::Text,
                M::Tel => TextInputKind::Tel,
                M::Url => TextInputKind::Url,
                M::Email => TextInputKind::Email,
                M::Numeric => TextInputKind::Numeric,
                M::Decimal => TextInputKind::Decimal,
                M::Search => TextInputKind::Search,
            },
            caret: input.caret_rect.map(|rect| RemoteRect {
                x: rect.x,
                y: rect.y,
                width: rect.w,
                height: rect.h,
            }),
        }
    }
}

/// The tab's viewport.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RemoteViewport {
    /// Width, CSS px.
    pub width: u32,
    /// Height, CSS px.
    pub height: u32,
    /// Device pixel ratio.
    pub dpr: f64,
}

impl From<wire::Viewport> for RemoteViewport {
    fn from(viewport: wire::Viewport) -> Self {
        Self {
            width: viewport.w,
            height: viewport.h,
            dpr: viewport.dpr,
        }
    }
}

impl From<RemoteViewport> for wire::Viewport {
    fn from(viewport: RemoteViewport) -> Self {
        Self {
            w: viewport.width,
            h: viewport.height,
            dpr: viewport.dpr,
        }
    }
}

/// Whose viewport is applied (protocol v1.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum RemoteViewportScope {
    /// The tab's own, the agent's (also any value newer than this client).
    Tab,
    /// The controlling user's; the agent's comes back when control does.
    Control,
}

/// Mobile emulation (protocol v1.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum RemoteMobileEmulation {
    /// A desktop page (also any value newer than this client).
    Off,
    /// Mobile layout: the meta viewport, overlay scroll bars and touch support.
    Layout,
    /// Mobile layout and a mobile user agent ("Request Mobile Website").
    Site,
}

impl From<RemoteMobileEmulation> for wire::MobileEmulation {
    fn from(mobile: RemoteMobileEmulation) -> Self {
        match mobile {
            RemoteMobileEmulation::Off => Self::Off,
            RemoteMobileEmulation::Layout => Self::Layout,
            RemoteMobileEmulation::Site => Self::Site,
        }
    }
}

impl From<wire::MobileEmulation> for RemoteMobileEmulation {
    fn from(mobile: wire::MobileEmulation) -> Self {
        match mobile {
            wire::MobileEmulation::Layout => Self::Layout,
            wire::MobileEmulation::Site => Self::Site,
            wire::MobileEmulation::Off | wire::MobileEmulation::Unknown { .. } => Self::Off,
        }
    }
}

/// The viewport this client wants while it holds control (protocol v1.1).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RemoteViewportRequest {
    /// The viewport.
    pub viewport: RemoteViewport,
    /// Mobile emulation.
    pub mobile: RemoteMobileEmulation,
}

/// The page's selection or caret (protocol v1.1).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RemoteSelection {
    /// The focus is an editable field.
    pub editable: bool,
    /// Nothing is selected.
    pub collapsed: bool,
    /// Selected UTF-16 code units.
    pub length: u32,
    /// The selection (or focused field) in viewport CSS px.
    pub rect: Option<RemoteRect>,
}

/// The main frame's scroll position and sizes in CSS px (protocol v1.1).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RemoteScrollMetrics {
    /// Horizontal offset.
    pub x: f64,
    /// Vertical offset.
    pub y: f64,
    /// Content width.
    pub content_width: f64,
    /// Content height.
    pub content_height: f64,
    /// Layout viewport width.
    pub viewport_width: f64,
    /// Layout viewport height.
    pub viewport_height: f64,
}

/// The protocol v1.1 features the host announced.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "one flag per independent protocol feature"
)]
pub struct RemoteBrowserCapabilities {
    /// Control-scoped viewports that the agent gets back.
    pub viewport_scope: bool,
    /// Mobile layout and user agent.
    pub mobile_emulation: bool,
    /// Copy, cut, paste and the other edit commands.
    pub edit: bool,
    /// Selection reports.
    pub selection: bool,
    /// Scroll reports.
    pub scroll_metrics: bool,
    /// Touch events.
    pub touch: bool,
}

/// An edit command (protocol v1.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum RemoteEditOp {
    /// Copy; the text arrives through `on_clipboard`.
    Copy,
    /// Cut; the text arrives through `on_clipboard`.
    Cut,
    /// Paste `text`.
    Paste,
    /// Select all.
    SelectAll,
    /// Undo.
    Undo,
    /// Redo.
    Redo,
    /// Delete the selection.
    Delete,
}

impl From<RemoteEditOp> for wire::EditOp {
    fn from(op: RemoteEditOp) -> Self {
        match op {
            RemoteEditOp::Copy => Self::Copy,
            RemoteEditOp::Cut => Self::Cut,
            RemoteEditOp::Paste => Self::Paste,
            RemoteEditOp::SelectAll => Self::SelectAll,
            RemoteEditOp::Undo => Self::Undo,
            RemoteEditOp::Redo => Self::Redo,
            RemoteEditOp::Delete => Self::Delete,
        }
    }
}

/// A touch point's phase (protocol v1.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TouchKind {
    /// Down.
    Start,
    /// Moved.
    Move,
    /// Up.
    End,
    /// Cancelled.
    Cancel,
}

/// One touch point in viewport CSS px (protocol v1.1).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct TouchInput {
    /// Phase.
    pub kind: TouchKind,
    /// Stable per finger.
    pub id: u32,
    /// X.
    pub x: f64,
    /// Y.
    pub y: f64,
    /// Contact radius, CSS px.
    pub radius: Option<f64>,
    /// Pressure, 0–1.
    pub pressure: Option<f64>,
    /// Modifier bits.
    pub modifiers: u32,
}

/// Encode quality.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum StreamQuality {
    /// Half the default bitrate.
    Low,
    /// The default (also any value newer than this client).
    Medium,
    /// Twice the default bitrate.
    High,
}

/// Stream codec preference.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum StreamCodec {
    /// The host picks (also any value newer than this client).
    Auto,
    /// H.264.
    H264,
    /// JPEG frames (low power).
    Jpeg,
}

/// Effective stream settings.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RemoteBrowserSettings {
    /// Frame-rate cap.
    pub max_fps: u32,
    /// Quality.
    pub quality: StreamQuality,
    /// Encode scale, 0.25–1.
    pub scale: f64,
    /// Codec.
    pub codec: StreamCodec,
}

impl From<wire::Settings> for RemoteBrowserSettings {
    fn from(settings: wire::Settings) -> Self {
        Self {
            max_fps: settings.max_fps,
            quality: match settings.quality {
                wire::Quality::Low => StreamQuality::Low,
                wire::Quality::High => StreamQuality::High,
                wire::Quality::Medium | wire::Quality::Unknown { .. } => StreamQuality::Medium,
            },
            scale: settings.scale,
            codec: match settings.codec {
                wire::CodecPreference::H264 => StreamCodec::H264,
                wire::CodecPreference::Jpeg => StreamCodec::Jpeg,
                wire::CodecPreference::Auto | wire::CodecPreference::Unknown { .. } => {
                    StreamCodec::Auto
                }
            },
        }
    }
}

/// Settings to change; `None` fields stay as they are.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RemoteBrowserSettingsUpdate {
    /// Frame-rate cap (control mode).
    pub max_fps: Option<u32>,
    /// Quality (control mode).
    pub quality: Option<StreamQuality>,
    /// Encode scale (control mode).
    pub scale: Option<f64>,
    /// Codec (control mode).
    pub codec: Option<StreamCodec>,
    /// Per-connection stats for a debug HUD (any mode).
    pub stats: Option<bool>,
}

impl From<RemoteBrowserSettingsUpdate> for wire::SettingsUpdate {
    fn from(update: RemoteBrowserSettingsUpdate) -> Self {
        Self {
            max_fps: update.max_fps,
            quality: update.quality.map(|quality| match quality {
                StreamQuality::Low => wire::Quality::Low,
                StreamQuality::Medium => wire::Quality::Medium,
                StreamQuality::High => wire::Quality::High,
            }),
            scale: update.scale,
            codec: update.codec.map(|codec| match codec {
                StreamCodec::Auto => wire::CodecPreference::Auto,
                StreamCodec::H264 => wire::CodecPreference::H264,
                StreamCodec::Jpeg => wire::CodecPreference::Jpeg,
            }),
            stats: update.stats,
        }
    }
}

/// Stream statistics.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RemoteBrowserStats {
    /// Frames per second sent.
    pub fps: f64,
    /// Kilobits per second sent.
    pub kbps: f64,
    /// Median encode time.
    pub encode_ms_p50: f64,
    /// 95th percentile encode time.
    pub encode_ms_p95: f64,
    /// Unacked frames.
    pub in_flight_frames: u32,
    /// Unacked bytes.
    pub in_flight_bytes: u64,
    /// Host CPU, in cores.
    pub host_cpu: f64,
}

impl From<wire::Stats> for RemoteBrowserStats {
    fn from(stats: wire::Stats) -> Self {
        Self {
            fps: stats.fps,
            kbps: stats.kbps,
            encode_ms_p50: stats.encode_ms_p50,
            encode_ms_p95: stats.encode_ms_p95,
            in_flight_frames: stats.in_flight_frames,
            in_flight_bytes: stats.in_flight_bytes,
            host_cpu: stats.host_cpu,
        }
    }
}

/// A JS dialog's kind.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum RemoteDialogKind {
    /// `alert()`.
    Alert,
    /// `confirm()`.
    Confirm,
    /// `prompt()`.
    Prompt,
    /// Leave-page confirmation.
    BeforeUnload,
    /// File picker.
    FileChooser,
    /// A kind newer than this client.
    Unknown {
        /// The value as sent.
        value: String,
    },
}

/// An open JS dialog.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RemoteBrowserDialog {
    /// Id for `reply_dialog`.
    pub id: String,
    /// Kind.
    pub kind: RemoteDialogKind,
    /// The page's message.
    pub message: String,
    /// `prompt()`'s default text.
    pub default_text: Option<String>,
    /// The page origin.
    pub origin: Option<String>,
}

impl From<wire::DialogOpened> for RemoteBrowserDialog {
    fn from(dialog: wire::DialogOpened) -> Self {
        use wire::DialogKind as K;
        Self {
            id: dialog.id,
            kind: match dialog.kind {
                K::Alert => RemoteDialogKind::Alert,
                K::Confirm => RemoteDialogKind::Confirm,
                K::Prompt => RemoteDialogKind::Prompt,
                K::BeforeUnload => RemoteDialogKind::BeforeUnload,
                K::FileChooser => RemoteDialogKind::FileChooser,
                K::Unknown { value } => RemoteDialogKind::Unknown { value },
            },
            message: dialog.message,
            default_text: dialog.default_text,
            origin: dialog.origin,
        }
    }
}

/// Why a tab ended.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum RemoteTabClosedReason {
    /// Closed by the agent, the user or the session's end.
    Closed,
    /// The renderer crashed.
    Crashed,
    /// The browser host exited.
    HostExit,
    /// A reason newer than this client.
    Unknown {
        /// The value as sent.
        value: String,
    },
}

impl From<wire::TabClosedReason> for RemoteTabClosedReason {
    fn from(reason: wire::TabClosedReason) -> Self {
        match reason {
            wire::TabClosedReason::Closed => Self::Closed,
            wire::TabClosedReason::Crashed => Self::Crashed,
            wire::TabClosedReason::HostExit => Self::HostExit,
            wire::TabClosedReason::Unknown { value } => Self::Unknown { value },
        }
    }
}

/// Why an attach closed without an error.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RemoteBrowserClosedReason {
    /// The tab is gone: show "This remote tab ended · Reopen".
    TabEnded {
        /// What the host said, when it said it first.
        reason: Option<RemoteTabClosedReason>,
        /// The close reason.
        detail: String,
    },
    /// The server or host closed the attach on purpose.
    ServerClosed {
        /// The close code.
        code: u16,
        /// The reason.
        reason: String,
    },
}

/// A failure that stops the attach until it is started again.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RemoteBrowserFailure {
    /// Sign in again.
    AuthenticationRequired {
        /// Detail.
        detail: String,
    },
    /// Not allowed to attach in `mode`; after a denied `Control`, a `View` attach may work.
    AccessDenied {
        /// Detail.
        detail: String,
        /// The denied mode.
        mode: RemoteBrowserMode,
    },
    /// The server's relay failed.
    ServerError {
        /// The reason.
        reason: String,
    },
    /// No server replica could reach the tab's host.
    WrongReplica,
    /// The host speaks another protocol version: update the app or the host.
    ProtocolUnsupported {
        /// Detail.
        detail: String,
    },
    /// One side broke the protocol.
    ProtocolViolation {
        /// The close code.
        code: u16,
        /// The reason.
        reason: String,
    },
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

/// The attach connection state.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RemoteBrowserConnection {
    /// Never started.
    Idle,
    /// The first attempt is in flight.
    Connecting,
    /// Streaming.
    Attached {
        /// The mode the host granted.
        mode: RemoteBrowserMode,
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
    /// Ended on purpose.
    Closed {
        /// Why.
        reason: RemoteBrowserClosedReason,
    },
    /// Stopped by the app.
    Stopped,
    /// A failure.
    Failed {
        /// The failure.
        failure: RemoteBrowserFailure,
        /// For display.
        message: String,
        /// The user must sign in again.
        requires_sign_in: bool,
    },
}

impl From<core::ConnectionState> for RemoteBrowserConnection {
    fn from(state: core::ConnectionState) -> Self {
        use core::ConnectionState as S;
        match state {
            S::Idle => Self::Idle,
            S::Connecting => Self::Connecting,
            S::Attached { mode } => Self::Attached {
                mode: mode_of(&mode),
            },
            S::Reconnecting {
                reason,
                failures,
                delay_ms,
            } => Self::Reconnecting {
                reason: reason.into(),
                failures,
                delay_ms,
            },
            S::Closed { reason } => Self::Closed {
                reason: match reason {
                    core::ClosedReason::TabEnded { reason, detail } => {
                        RemoteBrowserClosedReason::TabEnded {
                            reason: reason.map(Into::into),
                            detail,
                        }
                    }
                    core::ClosedReason::ServerClosed { code, reason } => {
                        RemoteBrowserClosedReason::ServerClosed { code, reason }
                    }
                },
            },
            S::Stopped => Self::Stopped,
            S::Failed { error } => Self::Failed {
                message: error.to_string(),
                requires_sign_in: error.requires_sign_in(),
                failure: failure(error),
            },
        }
    }
}

fn failure(error: core::AttachFailure) -> RemoteBrowserFailure {
    use core::AttachFailure as F;
    match error {
        F::AuthenticationRequired { detail } => {
            RemoteBrowserFailure::AuthenticationRequired { detail }
        }
        F::AccessDenied { detail, mode } => RemoteBrowserFailure::AccessDenied {
            detail,
            mode: mode_of(&mode),
        },
        F::ServerError { reason } => RemoteBrowserFailure::ServerError { reason },
        F::WrongReplica => RemoteBrowserFailure::WrongReplica,
        F::ProtocolUnsupported { detail } => RemoteBrowserFailure::ProtocolUnsupported { detail },
        F::ProtocolViolation { code, reason } => {
            RemoteBrowserFailure::ProtocolViolation { code, reason }
        }
        F::ReconnectBudgetExhausted { last, attempts } => {
            RemoteBrowserFailure::ReconnectBudgetExhausted {
                last: last.into(),
                attempts,
            }
        }
        F::Unrecoverable(error) => RemoteBrowserFailure::Unrecoverable {
            error: error.into(),
        },
    }
}

/// Everything the tab view shows, sent whole on every change.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RemoteBrowserSnapshot {
    /// The connection.
    pub connection: RemoteBrowserConnection,
    /// The mode the host granted, once attached.
    pub mode: Option<RemoteBrowserMode>,
    /// The tab's profile.
    pub profile: Option<String>,
    /// The host build.
    pub host_version: Option<String>,
    /// Navigation.
    pub nav: Option<RemoteBrowserNav>,
    /// Control ownership.
    pub control: Option<RemoteBrowserControl>,
    /// The user asked for control and has not handed it back (it is re-taken after a
    /// reconnect during the host's grace period).
    pub wants_control: bool,
    /// The cursor.
    pub cursor: RemoteBrowserCursor,
    /// Text input.
    pub text_input: RemoteBrowserTextInput,
    /// The viewport.
    pub viewport: Option<RemoteViewport>,
    /// Whose viewport is applied.
    pub viewport_scope: RemoteViewportScope,
    /// Mobile emulation.
    pub mobile: RemoteMobileEmulation,
    /// The agent's viewport while the controlling user's is applied.
    pub agent_viewport: Option<RemoteViewport>,
    /// The page's selection or caret, while reported.
    pub selection: Option<RemoteSelection>,
    /// The page's scroll metrics, while reported.
    pub scroll: Option<RemoteScrollMetrics>,
    /// The protocol v1.1 features the host announced.
    pub capabilities: RemoteBrowserCapabilities,
    /// Effective settings.
    pub settings: Option<RemoteBrowserSettings>,
    /// The latest stats, while requested.
    pub stats: Option<RemoteBrowserStats>,
    /// Open JS dialogs, oldest first.
    pub dialogs: Vec<RemoteBrowserDialog>,
}

/// One SPS and one PPS, without start codes.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct H264ParameterSets {
    /// Sequence parameter set.
    pub sps: Vec<u8>,
    /// Picture parameter set.
    pub pps: Vec<u8>,
}

/// One H.264 access unit for the hardware decoder.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VideoFrame {
    /// The stream; a new one starts at every keyframe.
    pub stream_id: u32,
    /// An IDR: decoding can start here.
    pub keyframe: bool,
    /// Host capture time, µs.
    pub pts_us: u64,
    /// SPS and PPS, on every keyframe.
    pub params: Option<H264ParameterSets>,
    /// The parameter sets changed: rebuild the format description first.
    pub format_changed: bool,
    /// Slice NAL units with 4-byte big-endian lengths (`CMSampleBuffer` data).
    pub avcc: Vec<u8>,
}

impl From<core::VideoFrame> for VideoFrame {
    fn from(frame: core::VideoFrame) -> Self {
        Self {
            stream_id: frame.stream_id,
            keyframe: frame.keyframe,
            pts_us: frame.pts_us,
            params: frame.params.map(|params| H264ParameterSets {
                sps: params.sps,
                pps: params.pps,
            }),
            format_changed: frame.format_changed,
            avcc: frame.avcc,
        }
    }
}

/// Which JPEG.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum StillKind {
    /// Full viewport.
    Still,
    /// At most 320 px wide.
    Thumbnail,
}

/// A JPEG from the host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StillImage {
    /// Still or thumbnail.
    pub kind: StillKind,
    /// Host capture time, µs.
    pub pts_us: u64,
    /// The JPEG.
    pub jpeg: Vec<u8>,
}

/// Why the renderer asks for a keyframe.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum KeyframeReason {
    /// The decoder failed.
    DecoderError,
    /// The renderer flushed (iOS background, a dropped frame).
    Flush,
    /// A frame was missing.
    Gap,
    /// The user asked.
    User,
}

/// A mouse event's kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum MouseKind {
    /// Pointer moved (coalesced).
    Move,
    /// Button pressed.
    Down,
    /// Button released.
    Up,
    /// Scroll (coalesced, deltas summed).
    Wheel,
    /// The pointer left the view.
    Leave,
}

/// A mouse button.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum MouseButton {
    /// Primary.
    Left,
    /// Middle.
    Middle,
    /// Secondary.
    Right,
}

/// Mouse input in viewport CSS px. `modifiers` uses the protocol bits: 1 shift, 2 ctrl, 4 alt,
/// 8 meta, 16 caps lock, 32 num lock, 64/128/256 left/middle/right button down.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct MouseInput {
    /// Kind.
    pub kind: MouseKind,
    /// X.
    pub x: f64,
    /// Y.
    pub y: f64,
    /// Button, required for `Down` and `Up`.
    pub button: Option<MouseButton>,
    /// Click count 1–3 for `Down` and `Up`; ignored otherwise.
    pub clicks: u8,
    /// Modifier and button bits.
    pub modifiers: u32,
    /// Wheel x delta, CSS px.
    pub dx: f64,
    /// Wheel y delta, CSS px; positive scrolls the content down.
    pub dy: f64,
}

/// A key event's kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum KeyKind {
    /// Key down.
    RawKeyDown,
    /// Key up.
    KeyUp,
    /// Text produced by a key press.
    Char,
}

/// Key input. Rust resolves the DOM `code` from `code`, else `mac_key_code`, else `hid_usage`,
/// and replaces an unusable `key` (empty, a control or function-key character) with the named
/// key.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeyInput {
    /// Kind.
    pub kind: KeyKind,
    /// `NSEvent.keyCode` (macOS).
    pub mac_key_code: Option<u16>,
    /// `UIKey.keyCode` HID usage (iOS hardware keyboards).
    pub hid_usage: Option<u32>,
    /// A DOM `code`, when already known.
    pub code: Option<String>,
    /// DOM `key` (for example `charactersIgnoringModifiers`).
    pub key: String,
    /// Text to insert, required for `Char`.
    pub text: Option<String>,
    /// Modifier bits.
    pub modifiers: u32,
    /// Auto-repeat.
    pub repeat: bool,
}

/// An IME operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ImeOp {
    /// Replace the marked text.
    SetComposition,
    /// Commit text.
    Commit,
    /// Finish composing, keeping the marked text.
    Finish,
    /// Cancel composing.
    Cancel,
}

/// A UTF-16 range.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ImeRange {
    /// Start.
    pub start: u32,
    /// End.
    pub end: u32,
}

/// IME input.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImeInput {
    /// Operation.
    pub op: ImeOp,
    /// Marked or committed text (required for `SetComposition` and `Commit`).
    pub text: Option<String>,
    /// Selection within `text`.
    pub selection: Option<ImeRange>,
    /// Range of the field to replace.
    pub replacement: Option<ImeRange>,
}

/// A navigation command.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum NavOp {
    /// Load a URL.
    Navigate,
    /// Back.
    Back,
    /// Forward.
    Forward,
    /// Reload.
    Reload,
    /// Stop.
    Stop,
}

/// Where the video sits in a local view.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RemotePlacement {
    /// Left, view points.
    pub x: f64,
    /// Top, view points.
    pub y: f64,
    /// Width, view points.
    pub width: f64,
    /// Height, view points.
    pub height: f64,
    /// View points per CSS px.
    pub scale: f64,
}

/// Aspect-fits `viewport` into a view; `None` for an empty view.
#[must_use]
#[uniffi::export]
pub fn remote_viewport_placement(
    viewport: RemoteViewport,
    view_width: f64,
    view_height: f64,
) -> Option<RemotePlacement> {
    core::place(&viewport.into(), view_width, view_height).map(|placement| RemotePlacement {
        x: placement.x,
        y: placement.y,
        width: placement.width,
        height: placement.height,
        scale: placement.scale,
    })
}

/// The viewport "Fit to window" requests for a view of this size (DPR 2 for sharp text).
#[must_use]
#[uniffi::export]
pub fn remote_viewport_fit(
    view_width: f64,
    view_height: f64,
    sharp_text: bool,
) -> Option<RemoteViewport> {
    core::fit_to_window(view_width, view_height, sharp_text).map(Into::into)
}

/// The DOM `code` of a macOS virtual key code.
#[must_use]
#[uniffi::export]
pub fn dom_code_for_mac_key_code(key_code: u16) -> Option<String> {
    core::keymap::dom_code_for_mac(key_code).map(str::to_owned)
}

/// The DOM `code` of a USB HID keyboard usage (bare id or `0x0007_xxxx`).
#[must_use]
#[uniffi::export]
pub fn dom_code_for_hid_usage(usage: u32) -> Option<String> {
    core::keymap::dom_code_for_hid(usage).map(str::to_owned)
}

/// A notice from an attach.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RemoteBrowserNotice {
    /// Plain-language text when `user_facing`, else a diagnostic for the log.
    pub message: String,
    /// Something the user can act on (a page that failed to load, a read-only view, an
    /// unsupported action); everything else belongs in the log only.
    pub user_facing: bool,
}

/// Receives one attach's output on background threads. `on_state`, `on_still`, `on_closed`
/// and `on_notice` arrive in order; `on_video` runs on its own task, in order among video
/// frames. Implementations must return quickly and hop to their own executor.
#[uniffi::export(with_foreign)]
pub trait RemoteBrowserListener: Send + Sync {
    /// The connection or tab state changed.
    fn on_state(&self, snapshot: RemoteBrowserSnapshot);
    /// A video frame to decode.
    fn on_video(&self, frame: VideoFrame);
    /// A JPEG still or thumbnail.
    fn on_still(&self, still: StillImage);
    /// The tab ended (after `on_state` reports `Closed`).
    fn on_closed(&self, reason: Option<RemoteTabClosedReason>);
    /// Something to show or log: unknown or malformed frames, host errors, dropped input.
    fn on_notice(&self, notice: RemoteBrowserNotice);
    /// Text the page copied or cut, for the local pasteboard (protocol v1.1).
    fn on_clipboard(&self, op: RemoteEditOp, text: String);
}

#[path = "remote_browser_driver.rs"]
mod driver;

pub use driver::RemoteBrowserDriver;

/// The viewport "Mobile size" asks for: the view in points at the screen's scale (DPR 1–3),
/// or `None` when the view is smaller than the protocol's 200 px minimum.
#[must_use]
#[uniffi::export]
pub fn remote_viewport_mobile(
    view_width: f64,
    view_height: f64,
    screen_scale: f64,
) -> Option<RemoteViewport> {
    core::viewport::match_view(view_width, view_height, screen_scale).map(Into::into)
}

#[uniffi::export]
impl ClientCore {
    /// Every remote browser tab of `session_id`, oldest first.
    ///
    /// # Errors
    ///
    /// [`CoreError::RemoteBrowser`].
    pub async fn list_remote_browsers(
        &self,
        session_id: String,
    ) -> Result<Vec<RemoteBrowserTab>, CoreError> {
        self.sessions()
            .list_remote_browsers(&session_id)
            .await
            .map(|tabs| tabs.into_iter().map(Into::into).collect())
            .map_err(remote_browser_error)
    }

    /// Opens a remote browser tab at `url` (or a blank page) in `profile` (or `default`).
    ///
    /// # Errors
    ///
    /// [`CoreError::RemoteBrowser`]; kind `BrowserUnavailable` when the machine has no host.
    pub async fn create_remote_browser(
        &self,
        session_id: String,
        url: Option<String>,
        profile: Option<String>,
    ) -> Result<RemoteBrowserTab, CoreError> {
        self.sessions()
            .create_remote_browser(&session_id, url.as_deref(), profile.as_deref())
            .await
            .map(Into::into)
            .map_err(remote_browser_error)
    }

    /// Closes a remote browser tab. Returns `false` when it was already gone.
    ///
    /// # Errors
    ///
    /// [`CoreError::RemoteBrowser`].
    pub async fn delete_remote_browser(
        &self,
        session_id: String,
        tab_id: String,
    ) -> Result<bool, CoreError> {
        self.sessions()
            .delete_remote_browser(&session_id, &tab_id)
            .await
            .map(|outcome| outcome == core::DeleteOutcome::Deleted)
            .map_err(remote_browser_error)
    }

    /// The browser profiles on `session_id`'s machine (`default` only on older servers).
    ///
    /// # Errors
    ///
    /// [`CoreError::RemoteBrowser`].
    pub async fn list_remote_browser_profiles(
        &self,
        session_id: String,
    ) -> Result<Vec<RemoteBrowserProfile>, CoreError> {
        self.sessions()
            .list_remote_browser_profiles(&session_id)
            .await
            .map(|profiles| {
                profiles
                    .into_iter()
                    .map(|profile| RemoteBrowserProfile {
                        name: profile.name,
                        running: profile.running,
                    })
                    .collect()
            })
            .map_err(remote_browser_error)
    }

    /// An attach driver for `tab_id` of `session_id`, idle until `start`. `host_id` routes the
    /// socket on sharded deployments.
    pub fn remote_browser_attach(
        &self,
        session_id: String,
        tab_id: String,
        mode: RemoteBrowserMode,
        host_id: Option<String>,
        listener: Arc<dyn RemoteBrowserListener>,
    ) -> Arc<RemoteBrowserDriver> {
        driver::spawn(
            self.inner.host.clone(),
            Arc::clone(&self.inner.sessions),
            self.inner.sockets.clone(),
            driver::Target {
                session_id,
                tab_id,
                options: core::AttachOptions {
                    mode: mode.into(),
                    slice_key: host_id,
                },
            },
            listener,
            self.unix_ms(),
        )
    }
}
