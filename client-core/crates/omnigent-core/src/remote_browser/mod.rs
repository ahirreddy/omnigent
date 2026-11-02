//! Remote agent browser: the client side of protocol v1 (design doc section 5).
//!
//! Everything here is sans-IO:
//!
//! - [`attach`]: [`RemoteBrowserAttach`], the attach state machine (connect, reconnect with
//!   backoff, ping watchdog, acks, close codes, control ownership, keyframe requests).
//! - [`codec`]: Annex-B NAL splitting and access-unit assembly, Annex-B to AVCC with SPS/PPS
//!   extraction, the per-connection [`VideoTrack`] and the latest-wins [`VideoQueue`].
//! - [`state`]: [`TabState`], the tab as host messages describe it.
//! - [`input`]: input validation and mouse coalescing.
//! - [`keymap`]: macOS virtual key codes and USB HID usages to DOM `code` and `key`.
//! - [`viewport`]: letterboxing, point mapping and "Fit to window".
//! - [`rest`]: tab list, create, delete, profiles and the attach upgrade request.
//!
//! The wire models live in [`omnigent_protocol::remote_browser`].

pub mod attach;
pub mod codec;
pub mod input;
pub mod keymap;
pub mod rest;
pub mod state;
pub mod viewport;

#[cfg(test)]
#[allow(clippy::redundant_pub_crate, reason = "shared by sibling test modules")]
mod test_support;

pub use attach::{
    AttachConfig, AttachFailure, AttachInput, AttachOptions, AttachOutput, ClosedReason,
    ConnectionState, DropReason, InputKind, Notice, RemoteBrowserAttach, TimerKind, TimerToken,
};
pub use codec::{
    AccessUnitAssembler, AvccUnit, CodecError, NalSplitter, ParameterSets, QueuePush, VideoDrop,
    VideoFrame, VideoOutcome, VideoQueue, VideoTrack, annex_b_to_avcc, split_nal_units,
};
pub use input::{InputCoalescer, InputError};
pub use rest::{
    BrowserEndpoint, BrowserPage, BrowserProfile, BrowserTab, DeleteOutcome, RemoteBrowserError,
};
pub use state::{CursorImage, TabState};
pub use viewport::{Placement, fit_to_window, place};
