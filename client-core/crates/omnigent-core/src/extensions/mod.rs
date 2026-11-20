//! Server extensions and the host side of an extension page's bridge.
//!
//! The pages and sidebar entries installed extensions contribute, and the bridge an extension
//! page talks through. Port of the web's `web/src/extensions` (`catalog.ts`, `rpc/*`,
//! `services/*`).
//!
//! An extension page runs its browser bundle in a sandboxed `srcdoc` frame with no network
//! access. Everything it reads or changes goes through host methods, granted by the permissions
//! its manifest declares, over a `MessageChannel` the host opens once the frame loads.

mod catalog;
mod document;
mod messages;
mod params;
mod sessions;

pub(crate) use catalog::asset_path;
pub use catalog::{
    Extension, ExtensionBundle, ExtensionNavigation, ExtensionNavigationEntry, ExtensionPage,
    decode_catalog, navigation_entries, resolve_page,
};
pub use document::{build_extension_document, build_host_page};
pub use messages::{
    ExtensionInbound, dispose_message, error_response_message, event_message, granted_host_methods,
    host_method_permission, init_message, parse_inbound, response_message,
};
pub use params::{
    StorageWrite, cached_projects_result, external_url_param, new_session_project_param,
    page_route_param, project_name_param, project_result, pull_request_result, session_id_param,
    storage_key_param, storage_write_param, theme_result,
};
pub use sessions::{
    ExtensionSessionRow, SessionPageRequest, SessionRows, cached_sessions_result,
    decode_session_rows, session_page_request, session_page_result,
};

/// Marks every bridge message, both ways.
pub const EXTENSION_RPC_SOURCE: &str = "omnigent-extension";
/// The bridge protocol version this host speaks.
pub const EXTENSION_RPC_VERSION: u32 = 1;
/// The largest request, event or response, counted as the web counts it.
pub const MAX_EXTENSION_MESSAGE_BYTES: usize = 64 * 1024;
/// Requests an extension may have in flight at once.
pub const MAX_PENDING_HOST_REQUESTS: u32 = 32;
/// How long a host method may take, and how long a page may take to say it is ready.
pub const HOST_REQUEST_TIMEOUT_SECONDS: u32 = 10;
/// The longest error text sent to an extension or shown for one.
pub const MAX_ERROR_CHARS: usize = 512;

/// Who a bridge message is for: one mount of one page. The nonce is new for every mount.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ExtensionIdentity {
    /// The extension.
    pub extension_id: String,
    /// The page.
    pub page_id: String,
    /// The view the bundle renders for the page.
    pub view: String,
    /// The mount's nonce: lowercase hex.
    pub nonce: String,
    /// The bridge version, [`EXTENSION_RPC_VERSION`].
    pub api_version: u32,
}

/// Why a host method failed, as the extension sees it.
///
/// One of the web's codes (`InvalidParams`, `PermissionDenied`, `Unavailable`, `HostError`,
/// `InvalidKey`, `InvalidValue`, `QuotaExceeded`, `StaleCursor`...) and a message.
#[derive(Debug, Clone, PartialEq, Eq, Hash, thiserror::Error)]
#[error("{code}: {message}")]
pub struct ExtensionHostError {
    /// The code the SDK raises.
    pub code: String,
    /// What went wrong.
    pub message: String,
}

impl ExtensionHostError {
    /// An error with `code` and `message`.
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_owned(),
            message: message.into(),
        }
    }

    /// `InvalidParams`.
    pub fn invalid_params(message: impl Into<String>) -> Self {
        Self::new("InvalidParams", message)
    }

    /// `HostError`.
    pub fn host(message: impl Into<String>) -> Self {
        Self::new("HostError", message)
    }
}

/// `text` cut to `limit` characters.
pub(crate) fn bounded(text: &str, limit: usize) -> String {
    text.chars().take(limit).collect()
}

#[cfg(test)]
mod tests;
