//! HTTP records shared by every host transport. `Debug` redacts credentials and bodies.

use std::fmt;

use omnigent_core as core;

/// One HTTP header. Names compare case-insensitively.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct HttpHeader {
    /// Header name.
    pub name: String,
    /// Header value.
    pub value: String,
}

impl fmt::Debug for HttpHeader {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let request = core::http::HttpRequest {
            method: String::new(),
            url: String::new(),
            headers: vec![self.clone().into()],
            body: None,
        };
        fmt::Debug::fmt(&request, f)
    }
}

/// A request the core asks the host to send. `Debug` redacts the query, credential headers and
/// the body.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
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

impl fmt::Debug for HttpRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(&core::http::HttpRequest::from(self.clone()), f)
    }
}

/// The final response, whatever its status. Redirects must not be followed. `Debug` redacts
/// credential headers and the body.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct HttpResponse {
    /// HTTP status code.
    pub status: u16,
    /// Response headers, in order.
    pub headers: Vec<HttpHeader>,
    /// Response body.
    pub body: Vec<u8>,
}

impl fmt::Debug for HttpResponse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(&core::http::HttpResponse::from(self.clone()), f)
    }
}

/// Why the host could not produce a response. A 4xx/5xx is a response, not a transport error.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum TransportError {
    /// No network path to the server.
    #[error("offline: {message}")]
    Offline {
        /// Host detail.
        message: String,
    },
    /// The request did not finish in time.
    #[error("timed out: {message}")]
    Timeout {
        /// Host detail.
        message: String,
    },
    /// The request was cancelled.
    #[error("request cancelled")]
    Cancelled,
    /// TLS negotiation or certificate validation failed.
    #[error("TLS error: {message}")]
    Tls {
        /// Host detail.
        message: String,
    },
    /// Any other transport failure.
    #[error("{message}")]
    Other {
        /// Host detail.
        message: String,
    },
}

/// A foreign implementation threw something that is not a `TransportError`.
impl From<uniffi::UnexpectedUniFFICallbackError> for TransportError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Other {
            message: format!("unexpected transport error: {}", error.reason),
        }
    }
}

impl From<core::http::HttpHeader> for HttpHeader {
    fn from(header: core::http::HttpHeader) -> Self {
        Self {
            name: header.name,
            value: header.value,
        }
    }
}

impl From<HttpHeader> for core::http::HttpHeader {
    fn from(header: HttpHeader) -> Self {
        Self {
            name: header.name,
            value: header.value,
        }
    }
}

impl From<core::http::HttpRequest> for HttpRequest {
    fn from(request: core::http::HttpRequest) -> Self {
        Self {
            method: request.method,
            url: request.url,
            headers: request.headers.into_iter().map(Into::into).collect(),
            body: request.body,
        }
    }
}

impl From<HttpRequest> for core::http::HttpRequest {
    fn from(request: HttpRequest) -> Self {
        Self {
            method: request.method,
            url: request.url,
            headers: request.headers.into_iter().map(Into::into).collect(),
            body: request.body,
        }
    }
}

impl From<HttpResponse> for core::http::HttpResponse {
    fn from(response: HttpResponse) -> Self {
        Self {
            status: response.status,
            headers: response.headers.into_iter().map(Into::into).collect(),
            body: response.body,
        }
    }
}

impl From<core::http::HttpResponse> for HttpResponse {
    fn from(response: core::http::HttpResponse) -> Self {
        Self {
            status: response.status,
            headers: response.headers.into_iter().map(Into::into).collect(),
            body: response.body,
        }
    }
}

impl From<TransportError> for core::http::TransportError {
    fn from(error: TransportError) -> Self {
        match error {
            TransportError::Offline { message } => Self::Offline { message },
            TransportError::Timeout { message } => Self::Timeout { message },
            TransportError::Cancelled => Self::Cancelled,
            TransportError::Tls { message } => Self::Tls { message },
            TransportError::Other { message } => Self::Other { message },
        }
    }
}

impl From<core::http::TransportError> for TransportError {
    fn from(error: core::http::TransportError) -> Self {
        use core::http::TransportError as Core;
        match error {
            Core::Offline { message } => Self::Offline { message },
            Core::Timeout { message } => Self::Timeout { message },
            Core::Cancelled => Self::Cancelled,
            Core::Tls { message } => Self::Tls { message },
            Core::Other { message } => Self::Other { message },
        }
    }
}
