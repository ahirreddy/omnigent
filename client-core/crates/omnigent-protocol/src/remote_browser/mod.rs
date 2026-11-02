//! Remote agent browser protocol v1: the binary media header, the JSON control messages, and
//! the runner ⇄ host socket framing.
//!
//! The contract is section 5 of `apps/apple/docs/remote-browser-design.md`; the shared
//! fixtures are in `client-core/fixtures/remote_browser/`.

pub mod header;
pub mod messages;
pub mod runner_host;
pub mod unix_frame;

#[cfg(test)]
mod fixture_tests;

pub use header::{
    HEADER_LEN, HEADER_VERSION, HeaderError, MAGIC, MAX_FRAME_BYTES, MediaFrame, MediaHeader,
    MediaKind, decode_frame,
};
pub use messages::{
    AckWindow, AttachMode, ClientHello, ClientMessage, CodecPreference, ControlOp, ControlReason,
    ControlState, ControlUpdate, CreatedBy, CursorUpdate, CustomCursor, DialogKind, DialogOpened,
    DialogReply, Handoff, Holder, HostError, HostHello, HostMessage, ImeEvent, ImeOp, KeyEvent,
    KeyKind, KeyframeReason, MessageError, MouseButton, MouseEvent, MouseKind, NavCommand, NavOp,
    NavState, Owner, PROTOCOL_VERSION, Quality, Rect, Settings, SettingsUpdate, Stats, StillKind,
    TabClosedReason, TextInputMode, TextInputUpdate, TextRange, Viewport, modifiers,
};
pub use runner_host::{
    ControlError, ControlRequest, ControlResponse, EncoderInfo, HostInfo, Preamble, TabRecord,
};
pub use unix_frame::{UnixFrame, UnixFrameDecoder, UnixFrameError};
