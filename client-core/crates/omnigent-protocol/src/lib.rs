//! Omnigent wire models shared by the native and web clients.
//!
//! Pure data and decoding: no I/O and no async runtime, so it builds for `wasm32-unknown-unknown`.

#![forbid(unsafe_code)]

pub mod display;
pub mod elicitation;
pub mod events;
pub mod items;
pub mod manifest;
pub mod sessions;

pub use manifest::{AuthMode, ManifestAuth, ManifestUi, ServerManifest};
