use thiserror::Error;

use crate::http::TransportError;

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
}
