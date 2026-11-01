//! Host HTTP transport contract.

use std::fmt;
use std::future::Future;

/// One HTTP header. Names compare case-insensitively.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpHeader {
    /// Header name as sent or received.
    pub name: String,
    /// Header value.
    pub value: String,
}

impl HttpHeader {
    /// A header from a name and value.
    pub fn new(name: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            value: value.into(),
        }
    }
}

/// A request the core asks the host to send.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpRequest {
    /// HTTP method, upper case.
    pub method: String,
    /// Absolute URL.
    pub url: String,
    /// Headers to send, in order.
    pub headers: Vec<HttpHeader>,
    /// Request body, if any.
    pub body: Option<Vec<u8>>,
}

/// The final response to an [`HttpRequest`], whatever its status.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpResponse {
    /// HTTP status code.
    pub status: u16,
    /// Response headers, in order.
    pub headers: Vec<HttpHeader>,
    /// Response body.
    pub body: Vec<u8>,
}

impl HttpResponse {
    /// First header named `name`, compared case-insensitively.
    #[must_use]
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|header| header.name.eq_ignore_ascii_case(name))
            .map(|header| header.value.as_str())
    }
}

/// Why the host could not produce an HTTP response. Any status code, including 4xx/5xx, is a
/// response, not a transport error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransportError {
    /// No network path to the server.
    Offline {
        /// Host-provided detail.
        message: String,
    },
    /// The request did not finish in time.
    Timeout {
        /// Host-provided detail.
        message: String,
    },
    /// The request was cancelled.
    Cancelled,
    /// TLS negotiation or certificate validation failed.
    Tls {
        /// Host-provided detail.
        message: String,
    },
    /// Any other transport failure.
    Other {
        /// Host-provided detail.
        message: String,
    },
}

impl fmt::Display for TransportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Offline { message } => write!(f, "offline: {message}"),
            Self::Timeout { message } => write!(f, "timed out: {message}"),
            Self::Cancelled => f.write_str("request cancelled"),
            Self::Tls { message } => write!(f, "TLS error: {message}"),
            Self::Other { message } => f.write_str(message),
        }
    }
}

impl std::error::Error for TransportError {}

/// Sends one request and returns the final response.
///
/// Hosts must not follow redirects (a 3xx is returned as-is), must not add cookies or caching the
/// request did not ask for, and must report cancellation as [`TransportError::Cancelled`].
pub trait HttpTransport {
    /// Sends `request`.
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, TransportError>>;
}
