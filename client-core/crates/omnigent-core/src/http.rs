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
///
/// `Debug` redacts the query string, credential headers and the body, which can carry tokens.
#[derive(Clone, PartialEq, Eq)]
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
///
/// `Debug` redacts credential headers and the body, which can carry tokens.
#[derive(Clone, PartialEq, Eq)]
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

const SENSITIVE_HEADERS: [&str; 5] = [
    "authorization",
    "cookie",
    "set-cookie",
    "proxy-authorization",
    "x-omnigent-code-verifier",
];

struct RedactedHeaders<'a>(&'a [HttpHeader]);

impl fmt::Debug for RedactedHeaders<'_> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_list()
            .entries(self.0.iter().map(|header| {
                let sensitive = SENSITIVE_HEADERS
                    .iter()
                    .any(|name| header.name.eq_ignore_ascii_case(name));
                let value = if sensitive {
                    "<redacted>"
                } else {
                    header.value.as_str()
                };
                (header.name.as_str(), value)
            }))
            .finish()
    }
}

struct RedactedBody(Option<usize>);

impl fmt::Debug for RedactedBody {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.0 {
            Some(length) => write!(formatter, "<{length} bytes>"),
            None => formatter.write_str("None"),
        }
    }
}

impl fmt::Debug for HttpRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let url = self.url.split_once('?').map_or_else(
            || self.url.clone(),
            |(path, _)| format!("{path}?<redacted>"),
        );
        formatter
            .debug_struct("HttpRequest")
            .field("method", &self.method)
            .field("url", &url)
            .field("headers", &RedactedHeaders(&self.headers))
            .field("body", &RedactedBody(self.body.as_ref().map(Vec::len)))
            .finish()
    }
}

impl fmt::Debug for HttpResponse {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HttpResponse")
            .field("status", &self.status)
            .field("headers", &RedactedHeaders(&self.headers))
            .field("body", &RedactedBody(Some(self.body.len())))
            .finish()
    }
}

/// Why the host could not produce an HTTP response. Any status code, including 4xx/5xx, is a
/// response, not a transport error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransportError {
    /// No connection to the server was made, so nothing was sent: no network path, or the
    /// server refused the connection or could not be found.
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

impl TransportError {
    /// Whether the request never left the host, so a write that failed this way was not
    /// delivered. Every other failure may have reached the server.
    #[must_use]
    pub const fn is_unsent(&self) -> bool {
        matches!(self, Self::Offline { .. })
    }
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

#[cfg(test)]
mod tests {
    use super::{HttpHeader, HttpRequest, HttpResponse, TransportError};

    #[test]
    fn every_transport_failure_reads_as_text() {
        assert_eq!(
            TransportError::Tls {
                message: "bad cert".to_owned()
            }
            .to_string(),
            "TLS error: bad cert"
        );
        assert_eq!(
            TransportError::Other {
                message: "odd".to_owned()
            }
            .to_string(),
            "odd"
        );
    }

    #[test]
    fn only_a_connection_never_made_is_known_unsent() {
        let message = || "detail".to_owned();
        assert!(TransportError::Offline { message: message() }.is_unsent());
        for sent in [
            TransportError::Timeout { message: message() },
            TransportError::Cancelled,
            TransportError::Tls { message: message() },
            TransportError::Other { message: message() },
        ] {
            assert!(!sent.is_unsent(), "{sent}");
        }
    }

    #[test]
    fn debug_redacts_credentials_query_and_body() {
        let request = HttpRequest {
            method: "POST".to_owned(),
            url: "https://example.test/oauth/token?code=secret-code".to_owned(),
            headers: vec![
                HttpHeader::new("Authorization", "Bearer secret-token"),
                HttpHeader::new("Accept", "application/json"),
            ],
            body: Some(b"refresh_token=secret-refresh".to_vec()),
        };
        let rendered = format!("{request:?}");
        assert!(!rendered.contains("secret"), "{rendered}");
        assert!(rendered.contains("application/json"), "{rendered}");
        assert!(rendered.contains("<28 bytes>"), "{rendered}");

        let response = HttpResponse {
            status: 200,
            headers: vec![HttpHeader::new("Set-Cookie", "session=secret-cookie")],
            body: b"{\"access_token\":\"secret-access\"}".to_vec(),
        };
        let rendered = format!("{response:?}");
        assert!(!rendered.contains("secret"), "{rendered}");
    }
}
