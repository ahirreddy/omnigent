//! JSON control messages (design doc section 5.4).
//!
//! Each direction is one enum. Decoding reads `type` first; an unknown `type` becomes
//! `Unknown { message_type, raw }` and unknown fields and string values are kept or ignored, never
//! errors. Optional fields are omitted on encode.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::wire_enum::wire_enum;

/// The protocol major this crate speaks.
pub const PROTOCOL_VERSION: u32 = 1;

wire_enum! {
    /// The connection's mode.
    pub enum AttachMode {
        /// Read-only viewer (`LEVEL_READ`).
        View = "view",
        /// May take control (`LEVEL_OWNER`).
        Control = "control",
    }
}

wire_enum! {
    /// Who owns a tab.
    pub enum Owner {
        /// The agent.
        Agent = "agent",
        /// The user.
        User = "user",
    }
}

wire_enum! {
    /// Which connection holds the user's control, from this connection's point of view.
    pub enum Holder {
        /// This connection.
        This = "this",
        /// Another connection.
        Other = "other",
    }
}

wire_enum! {
    /// Encode quality preset.
    pub enum Quality {
        /// About half the default bitrate.
        Low = "low",
        /// The default.
        Medium = "medium",
        /// About twice the default bitrate.
        High = "high",
    }
}

wire_enum! {
    /// Stream codec preference.
    pub enum CodecPreference {
        /// The host picks (H.264).
        Auto = "auto",
        /// H.264.
        H264 = "h264",
        /// JPEG frames (low power).
        Jpeg = "jpeg",
    }
}

wire_enum! {
    /// The focused field's virtual keyboard mode.
    pub enum TextInputMode {
        /// No editable field is focused.
        None = "none",
        /// Plain text.
        Text = "text",
        /// Telephone number.
        Tel = "tel",
        /// URL.
        Url = "url",
        /// Email address.
        Email = "email",
        /// Integer.
        Numeric = "numeric",
        /// Decimal number.
        Decimal = "decimal",
        /// Search field.
        Search = "search",
    }
}

wire_enum! {
    /// A JS dialog's kind.
    pub enum DialogKind {
        /// `alert()`.
        Alert = "alert",
        /// `confirm()`.
        Confirm = "confirm",
        /// `prompt()`.
        Prompt = "prompt",
        /// `onbeforeunload`.
        BeforeUnload = "beforeunload",
        /// `<input type=file>`.
        FileChooser = "file_chooser",
    }
}

wire_enum! {
    /// Why a tab ended.
    pub enum TabClosedReason {
        /// Closed by the agent, the user or the session's end.
        Closed = "closed",
        /// The renderer crashed.
        Crashed = "crashed",
        /// The host exited.
        HostExit = "host_exit",
    }
}

wire_enum! {
    /// Why the control state changed.
    pub enum ControlReason {
        /// A connection took control.
        Take = "take",
        /// The holder released control.
        Release = "release",
        /// An agent handoff opened or closed.
        Handoff = "handoff",
        /// The holder's connection ended; the grace period runs.
        HolderLeft = "holder_left",
        /// The grace period ended; the agent owns the tab again.
        GraceExpired = "grace_expired",
        /// The agent took the tab back.
        Agent = "agent",
    }
}

wire_enum! {
    /// Why the client asks for an IDR.
    pub enum KeyframeReason {
        /// The decoder failed.
        DecoderError = "decoder_error",
        /// The renderer flushed (for example after iOS backgrounding or a dropped frame).
        Flush = "flush",
        /// A frame was missing or unreadable.
        Gap = "gap",
        /// The user asked.
        User = "user",
    }
}

wire_enum! {
    /// Which JPEG to send.
    pub enum StillKind {
        /// Full viewport.
        Still = "still",
        /// At most 320 px wide.
        Thumbnail = "thumbnail",
    }
}

wire_enum! {
    /// A mouse event's kind.
    pub enum MouseKind {
        /// Pointer moved.
        Move = "move",
        /// Button pressed.
        Down = "down",
        /// Button released.
        Up = "up",
        /// Wheel or trackpad scroll.
        Wheel = "wheel",
        /// The pointer left the view.
        Leave = "leave",
    }
}

wire_enum! {
    /// A mouse button.
    pub enum MouseButton {
        /// Primary.
        Left = "left",
        /// Middle.
        Middle = "middle",
        /// Secondary.
        Right = "right",
    }
}

wire_enum! {
    /// A key event's kind.
    pub enum KeyKind {
        /// Key down, before text is produced.
        RawKeyDown = "rawkeydown",
        /// Key up.
        KeyUp = "keyup",
        /// Text produced by a key press.
        Char = "char",
    }
}

wire_enum! {
    /// An IME operation.
    pub enum ImeOp {
        /// Replace the marked text.
        SetComposition = "set_composition",
        /// Commit text.
        Commit = "commit",
        /// Finish composing, keeping the marked text.
        Finish = "finish",
        /// Cancel composing.
        Cancel = "cancel",
    }
}

wire_enum! {
    /// A navigation command.
    pub enum NavOp {
        /// Load `url`.
        Navigate = "navigate",
        /// History back.
        Back = "back",
        /// History forward.
        Forward = "forward",
        /// Reload.
        Reload = "reload",
        /// Stop loading.
        Stop = "stop",
    }
}

wire_enum! {
    /// A control request.
    pub enum ControlOp {
        /// Take control.
        Take = "take",
        /// Hand back to the agent.
        Release = "release",
    }
}

wire_enum! {
    /// Who created a tab.
    pub enum CreatedBy {
        /// The agent.
        Agent = "agent",
        /// The user.
        User = "user",
    }
}

/// Modifier and button bits of the `modifiers` field. Defined by the protocol; the host maps
/// them to CEF `EVENTFLAG_*`.
pub mod modifiers {
    /// Shift.
    pub const SHIFT: u32 = 1;
    /// Control.
    pub const CTRL: u32 = 1 << 1;
    /// Alt (option).
    pub const ALT: u32 = 1 << 2;
    /// Meta (command).
    pub const META: u32 = 1 << 3;
    /// Caps lock.
    pub const CAPS_LOCK: u32 = 1 << 4;
    /// Num lock.
    pub const NUM_LOCK: u32 = 1 << 5;
    /// Left mouse button down.
    pub const LEFT_BUTTON: u32 = 1 << 6;
    /// Middle mouse button down.
    pub const MIDDLE_BUTTON: u32 = 1 << 7;
    /// Right mouse button down.
    pub const RIGHT_BUTTON: u32 = 1 << 8;
    /// Every defined bit.
    pub const ALL: u32 = (1 << 9) - 1;
}

/// The tab's viewport in CSS px.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Viewport {
    /// Width.
    pub w: u32,
    /// Height.
    pub h: u32,
    /// Device pixel ratio.
    pub dpr: f64,
}

/// A rectangle in viewport CSS px.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    /// Left.
    pub x: f64,
    /// Top.
    pub y: f64,
    /// Width.
    pub w: f64,
    /// Height.
    pub h: f64,
}

/// A pending agent handoff (`browser_request_human`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Handoff {
    /// The elicitation id.
    pub id: String,
    /// What the agent asks the user to do.
    pub reason: String,
}

/// Control ownership as one connection sees it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlState {
    /// Who owns the tab.
    pub owner: Owner,
    /// Which connection holds the user's control; `None` when the agent owns the tab or during
    /// the grace period.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub holder: Option<Holder>,
    /// The controlling user.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_id: Option<String>,
    /// A pending handoff.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handoff: Option<Handoff>,
}

/// Effective stream settings.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Settings {
    /// Frame-rate cap.
    pub max_fps: u32,
    /// Quality preset.
    pub quality: Quality,
    /// Encode scale, 0.25–1.
    pub scale: f64,
    /// Codec preference.
    pub codec: CodecPreference,
}

/// The ack window.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AckWindow {
    /// Unacked frames allowed.
    pub max_frames: u32,
    /// Unacked bytes allowed.
    pub max_bytes: u64,
}

/// The host's `hello`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HostHello {
    /// Protocol major in use.
    pub protocol: u32,
    /// The tab.
    pub tab_id: String,
    /// The tab's profile.
    pub profile: String,
    /// Host build version.
    pub host_version: String,
    /// The authoritative mode.
    pub mode: AttachMode,
    /// Codecs the host can send.
    #[serde(default)]
    pub codecs: Vec<String>,
    /// The viewport.
    pub viewport: Viewport,
    /// Control state.
    pub control: ControlState,
    /// Effective settings.
    pub settings: Settings,
    /// The ack window.
    pub window: AckWindow,
    /// Optional capabilities.
    #[serde(default)]
    pub features: Vec<String>,
}

/// `nav`: the page's navigation state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NavState {
    /// Current URL.
    pub url: String,
    /// Page title.
    pub title: String,
    /// Loading.
    pub loading: bool,
    /// Load progress, 0–1.
    pub progress: f64,
    /// History back is possible.
    pub can_go_back: bool,
    /// History forward is possible.
    pub can_go_forward: bool,
    /// Favicon.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub favicon_url: Option<String>,
}

/// A custom cursor image.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CustomCursor {
    /// PNG, base64.
    pub png_base64: String,
    /// Hotspot x in image px.
    pub hotspot_x: f64,
    /// Hotspot y in image px.
    pub hotspot_y: f64,
    /// Image scale (device px per CSS px).
    pub scale: f64,
}

/// `cursor`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CursorUpdate {
    /// A CSS `cursor` keyword, or `custom`.
    pub cursor: String,
    /// The image for `custom`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom: Option<CustomCursor>,
}

/// `text_input`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TextInputUpdate {
    /// Virtual keyboard mode.
    pub mode: TextInputMode,
    /// Caret position.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caret_rect: Option<Rect>,
}

/// `control`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlUpdate {
    /// The new state.
    #[serde(flatten)]
    pub state: ControlState,
    /// Why it changed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<ControlReason>,
}

/// `dialog`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DialogOpened {
    /// Id for `dialog_reply`.
    pub id: String,
    /// Kind.
    pub kind: DialogKind,
    /// The page's message.
    pub message: String,
    /// `prompt()`'s default text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_text: Option<String>,
    /// The page origin.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
}

/// `stats`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Stats {
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
    /// Host CPU in cores.
    pub host_cpu: f64,
}

/// `error`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostError {
    /// Machine-readable code, for example `not_in_control`.
    pub code: String,
    /// Detail.
    pub message: String,
    /// A close follows.
    pub fatal: bool,
}

/// A message from the host.
#[derive(Debug, Clone, PartialEq)]
pub enum HostMessage {
    /// `hello`.
    Hello(Box<HostHello>),
    /// `nav`.
    Nav(NavState),
    /// `cursor`.
    Cursor(CursorUpdate),
    /// `text_input`.
    TextInput(TextInputUpdate),
    /// `control`.
    Control(ControlUpdate),
    /// `dialog`.
    Dialog(DialogOpened),
    /// `dialog_closed`.
    DialogClosed {
        /// The dialog.
        id: String,
    },
    /// `viewport`.
    Viewport(Viewport),
    /// `settings`.
    Settings(Settings),
    /// `stats`.
    Stats(Stats),
    /// `pong`.
    Pong {
        /// The ping's nonce.
        nonce: String,
    },
    /// `error`.
    Error(HostError),
    /// `tab_closed`.
    TabClosed {
        /// Why.
        reason: TabClosedReason,
    },
    /// A type this client does not know.
    Unknown {
        /// Its `type`.
        message_type: String,
        /// The message.
        raw: Map<String, Value>,
    },
}

/// The client's `hello`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClientHello {
    /// Protocol major.
    pub protocol: u32,
    /// Client name and platform.
    pub client: String,
    /// Codecs the client decodes.
    pub decoders: Vec<String>,
    /// Requested mode.
    pub mode: AttachMode,
    /// Whether the client shows video now.
    pub visible: bool,
    /// Optional capabilities.
    #[serde(default)]
    pub features: Vec<String>,
}

/// `mouse`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MouseEvent {
    /// Kind.
    pub kind: MouseKind,
    /// X in CSS px.
    pub x: f64,
    /// Y in CSS px.
    pub y: f64,
    /// Button, for `down` and `up`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub button: Option<MouseButton>,
    /// Click count, for `down` and `up`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clicks: Option<u8>,
    /// [`modifiers`] bits.
    pub modifiers: u32,
    /// Wheel x delta, CSS px.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dx: Option<f64>,
    /// Wheel y delta, CSS px; positive scrolls content down.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dy: Option<f64>,
}

/// `key`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyEvent {
    /// Kind.
    pub kind: KeyKind,
    /// DOM `KeyboardEvent.code`.
    pub code: String,
    /// DOM `KeyboardEvent.key`.
    pub key: String,
    /// Characters to insert, for `char`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// [`modifiers`] bits.
    pub modifiers: u32,
    /// Auto-repeat.
    pub repeat: bool,
}

/// A UTF-16 range.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TextRange {
    /// Start offset.
    pub start: u32,
    /// End offset.
    pub end: u32,
}

/// `ime`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImeEvent {
    /// Operation.
    pub op: ImeOp,
    /// Marked or committed text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// Selection within `text`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection: Option<TextRange>,
    /// Range of the field to replace.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replacement: Option<TextRange>,
}

/// `nav` from the client.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NavCommand {
    /// Operation.
    pub op: NavOp,
    /// URL, for `navigate`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

/// `dialog_reply`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DialogReply {
    /// The dialog.
    pub id: String,
    /// OK or Cancel.
    pub accept: bool,
    /// Text for `prompt()`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

/// `settings` from the client: only the fields to change.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SettingsUpdate {
    /// Frame-rate cap.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_fps: Option<u32>,
    /// Quality preset.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quality: Option<Quality>,
    /// Encode scale.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scale: Option<f64>,
    /// Codec preference.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codec: Option<CodecPreference>,
    /// Per-connection stats.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stats: Option<bool>,
}

/// A message from the client.
#[derive(Debug, Clone, PartialEq)]
pub enum ClientMessage {
    /// `hello`.
    Hello(ClientHello),
    /// `ack`.
    Ack {
        /// Highest received `seq`.
        seq: u32,
    },
    /// `keyframe_request`.
    KeyframeRequest {
        /// Why.
        reason: KeyframeReason,
    },
    /// `visibility`.
    Visibility {
        /// Shown.
        visible: bool,
    },
    /// `still_request`.
    StillRequest {
        /// Which JPEG.
        kind: StillKind,
    },
    /// `mouse`.
    Mouse(MouseEvent),
    /// `key`.
    Key(KeyEvent),
    /// `ime`.
    Ime(ImeEvent),
    /// `nav`.
    Nav(NavCommand),
    /// `resize`.
    Resize(Viewport),
    /// `control`.
    Control {
        /// Take or release.
        op: ControlOp,
    },
    /// `dialog_reply`.
    DialogReply(DialogReply),
    /// `settings`.
    Settings(SettingsUpdate),
    /// `ping`.
    Ping {
        /// Echoed in `pong`.
        nonce: String,
    },
    /// A type the host does not know.
    Unknown {
        /// Its `type`.
        message_type: String,
        /// The message.
        raw: Map<String, Value>,
    },
}

/// Why a text frame could not be decoded.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum MessageError {
    /// Not JSON.
    #[error("message is not JSON: {message}")]
    Syntax {
        /// The parser's message.
        message: String,
    },
    /// Not an object with a string `type`.
    #[error("message is not an object with a string type")]
    NoType,
    /// A known type with the wrong shape.
    #[error("message {message_type:?} is malformed: {message}")]
    Invalid {
        /// Its `type`.
        message_type: String,
        /// The decoder's message.
        message: String,
    },
    /// Encoding failed (a non-finite number).
    #[error("message could not be encoded: {message}")]
    Encode {
        /// The serializer's message.
        message: String,
    },
}

fn split(text: &str) -> Result<(String, Map<String, Value>), MessageError> {
    let value: Value = serde_json::from_str(text).map_err(|error| MessageError::Syntax {
        message: error.to_string(),
    })?;
    let Value::Object(map) = value else {
        return Err(MessageError::NoType);
    };
    let message_type = map
        .get("type")
        .and_then(Value::as_str)
        .ok_or(MessageError::NoType)?
        .to_owned();
    Ok((message_type, map))
}

fn body<T: DeserializeOwned>(
    message_type: &str,
    map: &Map<String, Value>,
) -> Result<T, MessageError> {
    serde_json::from_value(Value::Object(map.clone())).map_err(|error| MessageError::Invalid {
        message_type: message_type.to_owned(),
        message: error.to_string(),
    })
}

fn field<T: DeserializeOwned>(
    message_type: &str,
    map: &Map<String, Value>,
    name: &str,
) -> Result<T, MessageError> {
    let value = map.get(name).cloned().unwrap_or(Value::Null);
    serde_json::from_value(value).map_err(|error| MessageError::Invalid {
        message_type: message_type.to_owned(),
        message: format!("field {name}: {error}"),
    })
}

fn encode_with_type(message_type: &str, body: Value) -> Result<String, MessageError> {
    let mut map = match body {
        Value::Object(map) => map,
        Value::Null => Map::new(),
        other => {
            return Err(MessageError::Encode {
                message: format!("{message_type} body is not an object: {other}"),
            });
        }
    };
    map.insert("type".to_owned(), Value::String(message_type.to_owned()));
    Ok(Value::Object(map).to_string())
}

fn to_value(value: &impl Serialize) -> Result<Value, MessageError> {
    serde_json::to_value(value).map_err(|error| MessageError::Encode {
        message: error.to_string(),
    })
}

fn object(pairs: &[(&str, Value)]) -> Value {
    Value::Object(
        pairs
            .iter()
            .map(|(name, value)| ((*name).to_owned(), value.clone()))
            .collect(),
    )
}

impl HostMessage {
    /// Decodes one text frame.
    ///
    /// # Errors
    ///
    /// [`MessageError`] for non-JSON, a missing `type`, or a known type with the wrong shape.
    pub fn decode(text: &str) -> Result<Self, MessageError> {
        let (message_type, map) = split(text)?;
        let kind = message_type.as_str();
        Ok(match kind {
            "hello" => Self::Hello(body(kind, &map)?),
            "nav" => Self::Nav(body(kind, &map)?),
            "cursor" => Self::Cursor(body(kind, &map)?),
            "text_input" => Self::TextInput(body(kind, &map)?),
            "control" => Self::Control(body(kind, &map)?),
            "dialog" => Self::Dialog(body(kind, &map)?),
            "dialog_closed" => Self::DialogClosed {
                id: field(kind, &map, "id")?,
            },
            "viewport" => Self::Viewport(body(kind, &map)?),
            "settings" => Self::Settings(body(kind, &map)?),
            "stats" => Self::Stats(body(kind, &map)?),
            "pong" => Self::Pong {
                nonce: field(kind, &map, "nonce")?,
            },
            "error" => Self::Error(body(kind, &map)?),
            "tab_closed" => Self::TabClosed {
                reason: field(kind, &map, "reason")?,
            },
            _ => Self::Unknown {
                message_type,
                raw: map,
            },
        })
    }

    /// The text frame for this message.
    ///
    /// # Errors
    ///
    /// [`MessageError::Encode`] for a non-finite number.
    pub fn encode(&self) -> Result<String, MessageError> {
        match self {
            Self::Hello(hello) => encode_with_type("hello", to_value(hello)?),
            Self::Nav(nav) => encode_with_type("nav", to_value(nav)?),
            Self::Cursor(cursor) => encode_with_type("cursor", to_value(cursor)?),
            Self::TextInput(input) => encode_with_type("text_input", to_value(input)?),
            Self::Control(control) => encode_with_type("control", to_value(control)?),
            Self::Dialog(dialog) => encode_with_type("dialog", to_value(dialog)?),
            Self::DialogClosed { id } => {
                encode_with_type("dialog_closed", object(&[("id", Value::from(id.as_str()))]))
            }
            Self::Viewport(viewport) => encode_with_type("viewport", to_value(viewport)?),
            Self::Settings(settings) => encode_with_type("settings", to_value(settings)?),
            Self::Stats(stats) => encode_with_type("stats", to_value(stats)?),
            Self::Pong { nonce } => {
                encode_with_type("pong", object(&[("nonce", Value::from(nonce.as_str()))]))
            }
            Self::Error(error) => encode_with_type("error", to_value(error)?),
            Self::TabClosed { reason } => {
                encode_with_type("tab_closed", object(&[("reason", to_value(reason)?)]))
            }
            Self::Unknown { message_type, raw } => {
                encode_with_type(message_type, Value::Object(raw.clone()))
            }
        }
    }
}

impl ClientMessage {
    /// Decodes one text frame.
    ///
    /// # Errors
    ///
    /// [`MessageError`] for non-JSON, a missing `type`, or a known type with the wrong shape.
    pub fn decode(text: &str) -> Result<Self, MessageError> {
        let (message_type, map) = split(text)?;
        let kind = message_type.as_str();
        Ok(match kind {
            "hello" => Self::Hello(body(kind, &map)?),
            "ack" => Self::Ack {
                seq: field(kind, &map, "seq")?,
            },
            "keyframe_request" => Self::KeyframeRequest {
                reason: field(kind, &map, "reason")?,
            },
            "visibility" => Self::Visibility {
                visible: field(kind, &map, "visible")?,
            },
            "still_request" => Self::StillRequest {
                kind: field(kind, &map, "kind")?,
            },
            "mouse" => Self::Mouse(body(kind, &map)?),
            "key" => Self::Key(body(kind, &map)?),
            "ime" => Self::Ime(body(kind, &map)?),
            "nav" => Self::Nav(body(kind, &map)?),
            "resize" => Self::Resize(body(kind, &map)?),
            "control" => Self::Control {
                op: field(kind, &map, "op")?,
            },
            "dialog_reply" => Self::DialogReply(body(kind, &map)?),
            "settings" => Self::Settings(body(kind, &map)?),
            "ping" => Self::Ping {
                nonce: field(kind, &map, "nonce")?,
            },
            _ => Self::Unknown {
                message_type,
                raw: map,
            },
        })
    }

    /// The text frame for this message.
    ///
    /// # Errors
    ///
    /// [`MessageError::Encode`] for a non-finite number.
    pub fn encode(&self) -> Result<String, MessageError> {
        match self {
            Self::Hello(hello) => encode_with_type("hello", to_value(hello)?),
            Self::Ack { seq } => encode_with_type("ack", object(&[("seq", Value::from(*seq))])),
            Self::KeyframeRequest { reason } => {
                encode_with_type("keyframe_request", object(&[("reason", to_value(reason)?)]))
            }
            Self::Visibility { visible } => {
                encode_with_type("visibility", object(&[("visible", Value::from(*visible))]))
            }
            Self::StillRequest { kind } => {
                encode_with_type("still_request", object(&[("kind", to_value(kind)?)]))
            }
            Self::Mouse(mouse) => encode_with_type("mouse", to_value(mouse)?),
            Self::Key(key) => encode_with_type("key", to_value(key)?),
            Self::Ime(ime) => encode_with_type("ime", to_value(ime)?),
            Self::Nav(nav) => encode_with_type("nav", to_value(nav)?),
            Self::Resize(viewport) => encode_with_type("resize", to_value(viewport)?),
            Self::Control { op } => encode_with_type("control", object(&[("op", to_value(op)?)])),
            Self::DialogReply(reply) => encode_with_type("dialog_reply", to_value(reply)?),
            Self::Settings(settings) => encode_with_type("settings", to_value(settings)?),
            Self::Ping { nonce } => {
                encode_with_type("ping", object(&[("nonce", Value::from(nonce.as_str()))]))
            }
            Self::Unknown { message_type, raw } => {
                encode_with_type(message_type, Value::Object(raw.clone()))
            }
        }
    }
}
