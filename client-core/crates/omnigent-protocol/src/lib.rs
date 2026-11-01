//! Omnigent wire models shared by the native and web clients.
//!
//! Pure data and decoding: no I/O and no async runtime, so it builds for `wasm32-unknown-unknown`.

#![forbid(unsafe_code)]

pub mod content;
pub mod display;
pub mod elicitation;
pub mod error;
pub mod events;
pub mod field;
pub mod items;
pub mod manifest;
pub mod native_tools;
pub mod page;
pub mod sessions;
#[cfg(test)]
#[allow(clippy::redundant_pub_crate, reason = "shared by sibling test modules")]
mod test_support;
mod wire_enum;

pub use content::{AttachmentKind, AttachmentPart, ContentPart, TextPartKind};
pub use elicitation::{
    ElicitationAction, ElicitationLookup, ElicitationMode, ElicitationParams, ElicitationRequest,
    ElicitationResolution, ElicitationResolved, ElicitationResult, ElicitationValue,
};
pub use error::{DecodeError, FromWire};
pub use events::ServerStreamEvent;
pub use field::Field;
pub use items::{ConversationItem, ItemData, ItemStatus, MessageRole};
pub use manifest::{AuthMode, ManifestAuth, ManifestUi, ServerManifest};
pub use native_tools::{NativeToolItem, NativeToolKind};
pub use page::{Page, PageCursorError};
pub use sessions::{
    ItemPage, SessionList, SessionListItem, SessionPermissions, SessionSnapshot, SessionStatus,
};
