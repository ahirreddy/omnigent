use thiserror::Error;

use crate::auth::errors::{HostedAuthError, OidcError};
use crate::config::managed::ManagedConfigError;
use crate::config::settings::SettingsError;
use crate::deeplink::DeepLinkError;
use crate::http::TransportError;
use crate::notifications::route::NotificationError;
use crate::realtime::{LinkError, WatchError};
use crate::reconcile::{ConfigurationReadError, SyncError};
use crate::reducer::RowOpError;

/// Every failure the core reports to its host.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CoreError {
    /// The user-entered server URL was rejected before any request.
    #[error("{message}")]
    InvalidUrl {
        /// Why the URL was rejected.
        message: String,
    },
    /// The host transport failed.
    #[error("{0}")]
    Transport(#[from] TransportError),
    /// The server answered with an unexpected status.
    #[error("server answered HTTP {status}")]
    HttpStatus {
        /// HTTP status code.
        status: u16,
        /// Response body, decoded lossily as UTF-8.
        body: String,
    },
    /// The response body could not be decoded.
    #[error("could not decode server response: {message}")]
    Decode {
        /// Decoder detail.
        message: String,
    },
    /// Hosted sign-in, identity confirmation or an auth endpoint failed.
    #[error("{0}")]
    Auth(#[from] HostedAuthError),
    /// Native OIDC sign-in, refresh or sign-out failed.
    #[error("{0}")]
    Oidc(#[from] OidcError),
    /// A realtime connection failed for good.
    #[error("{0}")]
    Link(#[from] LinkError),
    /// The session-updates watch set was refused.
    #[error("{0}")]
    Watch(#[from] WatchError),
    /// The conversation sync could not apply an input.
    #[error("{0}")]
    Sync(#[from] SyncError),
    /// A configuration read was not accepted.
    #[error("{0}")]
    ConfigurationRead(#[from] ConfigurationReadError),
    /// Row operations did not fit the rows they were applied to.
    #[error("{0}")]
    RowOps(#[from] RowOpError),
    /// Saved settings could not be read or written.
    #[error("{0}")]
    Settings(#[from] SettingsError),
    /// Managed (MDM) preferences are invalid.
    #[error("{0}")]
    ManagedConfig(#[from] ManagedConfigError),
    /// An `omnigent://` link was rejected.
    #[error("{0}")]
    DeepLink(#[from] DeepLinkError),
    /// A notification payload or scope was rejected.
    #[error("{0}")]
    Notification(#[from] NotificationError),
}
