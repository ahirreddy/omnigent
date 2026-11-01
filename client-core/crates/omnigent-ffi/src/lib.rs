//! `UniFFI` surface of the Omnigent client core. Thin adapters over `omnigent-core`; no logic
//! lives here. Doc comments on exported items are copied into the generated Swift.

#![allow(
    clippy::multiple_crate_versions,
    reason = "uniffi 0.32 depends on both syn 2 and syn 3; not fixable from this workspace"
)]

use std::future::Future;
use std::sync::Arc;

use omnigent_core as core;

uniffi::setup_scaffolding!();

/// One HTTP header. Names compare case-insensitively.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HttpHeader {
    /// Header name.
    pub name: String,
    /// Header value.
    pub value: String,
}

/// A request the core asks the host to send.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
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

/// The final response, whatever its status. Redirects must not be followed.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HttpResponse {
    /// HTTP status code.
    pub status: u16,
    /// Response headers, in order.
    pub headers: Vec<HttpHeader>,
    /// Response body.
    pub body: Vec<u8>,
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

/// Implemented by the host (`URLSession` on Apple). See `omnigent_core::http::HttpTransport` for the
/// contract: no redirect following, every status is a response.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait HttpTransport: Send + Sync {
    /// Sends `request` and returns the final response.
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, TransportError>;
}

/// How the server signs users in (`auth.mode` in the manifest).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AuthMode {
    /// OIDC, including the native loopback sign-in.
    Oidc,
    /// Built-in username/password accounts.
    Accounts,
    /// Identity from a trusted reverse-proxy header.
    Header,
    /// An embedding app's own provider.
    Custom,
    /// No sign-in.
    None,
    /// A mode newer than this client; never treated as a known one.
    Unknown {
        /// The mode string as sent.
        value: String,
    },
}

/// What the client learned about a server before signing in.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ServerDiscovery {
    /// The normalized server URL, mount path included.
    pub base_url: String,
    /// Operator display name; display only, never for trust decisions.
    pub server_name: Option<String>,
    /// Server package version; informational.
    pub server_version: Option<String>,
    /// Oldest client build the server supports (`min_desktop_version`); none means no floor.
    pub min_client_version: Option<String>,
    /// Absent when the server predates the manifest or its `auth` block: sign in as before.
    pub auth_mode: Option<AuthMode>,
    /// Private-use-scheme redirects the server accepts for native sign-in.
    pub native_redirect_uris: Vec<String>,
}

/// Every failure the core reports to the host.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    /// The server URL was rejected before any request.
    #[error("{message}")]
    InvalidUrl {
        /// Why, suitable for display.
        message: String,
    },
    /// The host transport failed; `message` keeps the transport error kind and detail.
    #[error("{message}")]
    Transport {
        /// Transport kind and detail.
        message: String,
    },
    /// The server answered with an unexpected status.
    #[error("server answered HTTP {status}")]
    HttpStatus {
        /// HTTP status code.
        status: u16,
        /// Response body, decoded lossily as UTF-8.
        body: String,
    },
    /// The response body could not be decoded.
    #[error("{message}")]
    Decode {
        /// Decoder detail.
        message: String,
    },
}

/// The client core. One per server connection; safe to share across threads.
#[derive(Debug, uniffi::Object)]
pub struct ClientCore {
    inner: core::ClientCore<ForeignTransport>,
}

#[uniffi::export]
impl ClientCore {
    /// A core that sends HTTP through `transport`.
    #[uniffi::constructor]
    pub fn new(transport: Arc<dyn HttpTransport>) -> Arc<Self> {
        // TODO(phase 2): take the insecure-http policy from the host (debug vs release builds).
        let config = core::CoreConfig {
            allows_insecure_http: true,
        };
        Arc::new(Self {
            inner: core::ClientCore::new(ForeignTransport(transport), config),
        })
    }

    /// Normalizes `server_url` and reads its `/.well-known/omnigent.json`.
    ///
    /// # Errors
    ///
    /// See [`CoreError`]. A 404 is not an error: it yields a discovery with no auth mode.
    pub async fn discover_server(&self, server_url: String) -> Result<ServerDiscovery, CoreError> {
        self.inner
            .discover_server(&server_url)
            .await
            .map(Into::into)
            .map_err(Into::into)
    }
}

/// The Rust core's crate version.
#[must_use]
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

struct ForeignTransport(Arc<dyn HttpTransport>);

impl std::fmt::Debug for ForeignTransport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ForeignTransport")
    }
}

impl core::http::HttpTransport for ForeignTransport {
    fn send(
        &self,
        request: core::http::HttpRequest,
    ) -> impl Future<Output = Result<core::http::HttpResponse, core::http::TransportError>> {
        let transport = Arc::clone(&self.0);
        async move {
            transport
                .send(request.into())
                .await
                .map(Into::into)
                .map_err(Into::into)
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

impl From<HttpResponse> for core::http::HttpResponse {
    fn from(response: HttpResponse) -> Self {
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

impl From<core::AuthMode> for AuthMode {
    fn from(mode: core::AuthMode) -> Self {
        match mode {
            core::AuthMode::Oidc => Self::Oidc,
            core::AuthMode::Accounts => Self::Accounts,
            core::AuthMode::Header => Self::Header,
            core::AuthMode::Custom => Self::Custom,
            core::AuthMode::None => Self::None,
            core::AuthMode::Unknown { value } => Self::Unknown { value },
        }
    }
}

impl From<core::ServerDiscovery> for ServerDiscovery {
    fn from(discovery: core::ServerDiscovery) -> Self {
        Self {
            base_url: discovery.base_url,
            server_name: discovery.server_name,
            server_version: discovery.server_version,
            min_client_version: discovery.min_client_version,
            auth_mode: discovery.auth_mode.map(Into::into),
            native_redirect_uris: discovery.native_redirect_uris,
        }
    }
}

impl From<core::CoreError> for CoreError {
    fn from(error: core::CoreError) -> Self {
        match error {
            core::CoreError::InvalidUrl { message } => Self::InvalidUrl { message },
            core::CoreError::Transport(error) => Self::Transport {
                message: error.to_string(),
            },
            core::CoreError::HttpStatus { status, body } => Self::HttpStatus { status, body },
            error @ core::CoreError::Decode { .. } => Self::Decode {
                message: error.to_string(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use futures::executor::block_on;

    use super::*;

    struct CannedTransport {
        reply: Result<HttpResponse, TransportError>,
        seen: Mutex<Vec<HttpRequest>>,
    }

    #[async_trait::async_trait]
    impl HttpTransport for CannedTransport {
        async fn send(&self, request: HttpRequest) -> Result<HttpResponse, TransportError> {
            self.seen.lock().expect("lock poisoned").push(request);
            self.reply.clone()
        }
    }

    fn core_with(
        reply: Result<HttpResponse, TransportError>,
    ) -> (Arc<ClientCore>, Arc<CannedTransport>) {
        let transport = Arc::new(CannedTransport {
            reply,
            seen: Mutex::new(Vec::new()),
        });
        (ClientCore::new(transport.clone()), transport)
    }

    #[test]
    fn discovers_through_a_foreign_transport() {
        let (core, transport) = core_with(Ok(HttpResponse {
            status: 200,
            headers: vec![HttpHeader {
                name: "Content-Type".into(),
                value: "application/json".into(),
            }],
            body: br#"{"manifest_version": 1, "server_name": "Dev", "auth": {"mode": "header"}}"#
                .to_vec(),
        }));
        let discovery = block_on(core.discover_server("localhost:6767".into())).unwrap();
        assert_eq!(
            discovery,
            ServerDiscovery {
                base_url: "http://localhost:6767".into(),
                server_name: Some("Dev".into()),
                server_version: None,
                min_client_version: None,
                auth_mode: Some(AuthMode::Header),
                native_redirect_uris: vec![],
            }
        );
        let seen = transport.seen.lock().expect("lock poisoned");
        assert_eq!(seen.len(), 1);
        assert_eq!(
            seen[0].url,
            "http://localhost:6767/.well-known/omnigent.json"
        );
    }

    #[test]
    fn transport_error_detail_survives() {
        let (core, _) = core_with(Err(TransportError::Tls {
            message: "certificate expired".into(),
        }));
        let error = block_on(core.discover_server("https://h.example.com".into())).unwrap_err();
        assert_eq!(
            error,
            CoreError::Transport {
                message: "TLS error: certificate expired".into()
            }
        );
    }

    #[test]
    fn decode_error_names_the_manifest() {
        let (core, _) = core_with(Ok(HttpResponse {
            status: 200,
            headers: vec![HttpHeader {
                name: "content-type".into(),
                value: "application/json".into(),
            }],
            body: b"{}".to_vec(),
        }));
        let CoreError::Decode { message } =
            block_on(core.discover_server("https://h.example.com".into())).unwrap_err()
        else {
            panic!("expected a decode error");
        };
        assert!(message.contains("manifest_version"), "{message}");
    }

    #[test]
    fn version_is_the_crate_version() {
        assert_eq!(core_version(), env!("CARGO_PKG_VERSION"));
    }
}
