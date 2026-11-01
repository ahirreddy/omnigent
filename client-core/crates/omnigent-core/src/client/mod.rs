use crate::discovery::{ServerDiscovery, discovery_from_response, manifest_request};
use crate::error::CoreError;
use crate::http::HttpTransport;
use crate::server_url;

/// Host policy for the core.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CoreConfig {
    /// Accept `http://` server URLs. Schemeless loopback input then defaults to http.
    pub allows_insecure_http: bool,
}

/// The client core, generic over the host transport.
#[derive(Debug)]
pub struct ClientCore<T> {
    transport: T,
    config: CoreConfig,
}

impl<T: HttpTransport> ClientCore<T> {
    /// A core that sends through `transport`.
    pub const fn new(transport: T, config: CoreConfig) -> Self {
        Self { transport, config }
    }

    /// The policy this core was created with.
    pub const fn config(&self) -> CoreConfig {
        self.config
    }

    /// Normalizes `server_url` and reads the server's manifest.
    ///
    /// # Errors
    ///
    /// [`CoreError::InvalidUrl`] before any request, [`CoreError::Transport`] when the host fails,
    /// and see [`discovery_from_response`] for the rest.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn discover_server(&self, server_url: &str) -> Result<ServerDiscovery, CoreError> {
        let url = server_url::normalize(server_url, self.config.allows_insecure_http).map_err(
            |error| CoreError::InvalidUrl {
                message: error.to_string(),
            },
        )?;
        let response = self.transport.send(manifest_request(&url)).await?;
        discovery_from_response(&url, &response)
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::future::{Future, ready};

    use futures::executor::block_on;

    use super::*;
    use crate::AuthMode;
    use crate::http::{HttpHeader, HttpRequest, HttpResponse, TransportError};

    struct FakeTransport {
        reply: Result<HttpResponse, TransportError>,
        requests: RefCell<Vec<HttpRequest>>,
    }

    impl FakeTransport {
        fn new(reply: Result<HttpResponse, TransportError>) -> Self {
            Self {
                reply,
                requests: RefCell::new(Vec::new()),
            }
        }

        fn responding(status: u16, content_type: &str, body: &[u8]) -> Self {
            Self::new(Ok(HttpResponse {
                status,
                headers: vec![HttpHeader::new("content-type", content_type)],
                body: body.to_vec(),
            }))
        }
    }

    impl HttpTransport for FakeTransport {
        fn send(
            &self,
            request: HttpRequest,
        ) -> impl Future<Output = Result<HttpResponse, TransportError>> {
            self.requests.borrow_mut().push(request);
            ready(self.reply.clone())
        }
    }

    const DEBUG: CoreConfig = CoreConfig {
        allows_insecure_http: true,
    };
    const RELEASE: CoreConfig = CoreConfig {
        allows_insecure_http: false,
    };

    fn fixture(name: &str) -> Vec<u8> {
        let path = format!(
            "{}/../../fixtures/manifest/{name}",
            env!("CARGO_MANIFEST_DIR")
        );
        std::fs::read(&path).unwrap_or_else(|error| panic!("reading {path}: {error}"))
    }

    fn discover(
        transport: FakeTransport,
        config: CoreConfig,
        server_url: &str,
    ) -> (Result<ServerDiscovery, CoreError>, Vec<HttpRequest>) {
        let core = ClientCore::new(transport, config);
        let result = block_on(core.discover_server(server_url));
        (result, core.transport.requests.take())
    }

    #[test]
    fn fetches_manifest_at_the_origin_and_maps_it() {
        let transport = FakeTransport::responding(
            200,
            "application/json; charset=utf-8",
            &fixture("oidc.json"),
        );
        let (result, requests) = discover(transport, DEBUG, "localhost:6767/omnigent/?o=1#chat");

        assert_eq!(
            requests,
            vec![HttpRequest {
                method: "GET".into(),
                url: "http://localhost:6767/.well-known/omnigent.json".into(),
                headers: vec![HttpHeader::new("Accept", "application/json")],
                body: None,
            }]
        );
        assert_eq!(
            result.unwrap(),
            ServerDiscovery {
                base_url: "http://localhost:6767/omnigent/?o=1#chat".into(),
                server_name: Some("Omnigent Dev".into()),
                server_version: Some("0.18.0".into()),
                min_client_version: None,
                auth_mode: Some(AuthMode::Oidc),
                native_redirect_uris: vec![
                    "ai.omnigent.android:/oauth/callback".into(),
                    "ai.omnigent.ios:/oauth/callback".into(),
                ],
            }
        );
    }

    #[test]
    fn accounts_manifest_with_floor_and_null_redirects() {
        let transport =
            FakeTransport::responding(200, "application/json", &fixture("accounts.json"));
        let discovery = discover(transport, RELEASE, "omnigent.example.com")
            .0
            .unwrap();
        assert_eq!(discovery.base_url, "https://omnigent.example.com");
        assert_eq!(discovery.auth_mode, Some(AuthMode::Accounts));
        assert_eq!(discovery.min_client_version.as_deref(), Some("0.9.0"));
        assert_eq!(discovery.server_name, None);
        assert_eq!(discovery.native_redirect_uris, Vec::<String>::new());
    }

    #[test]
    fn manifest_without_auth_block_has_no_auth_mode() {
        let transport =
            FakeTransport::responding(200, "application/json", &fixture("no-auth-block.json"));
        let discovery = discover(transport, RELEASE, "https://h.example.com")
            .0
            .unwrap();
        assert_eq!(discovery.auth_mode, None);
        assert_eq!(discovery.server_version.as_deref(), Some("0.17.2"));
    }

    #[test]
    fn unknown_auth_mode_is_surfaced() {
        let transport =
            FakeTransport::responding(200, "application/json", &fixture("unknown-mode.json"));
        let discovery = discover(transport, RELEASE, "https://h.example.com")
            .0
            .unwrap();
        assert_eq!(
            discovery.auth_mode,
            Some(AuthMode::Unknown {
                value: "saml".into()
            })
        );
        assert_eq!(discovery.server_name.as_deref(), Some("Future Server"));
    }

    #[test]
    fn not_found_is_baseline() {
        let transport = FakeTransport::responding(404, "application/json", br#"{"detail": "x"}"#);
        let discovery = discover(transport, RELEASE, "https://h.example.com/")
            .0
            .unwrap();
        assert_eq!(
            discovery,
            ServerDiscovery {
                base_url: "https://h.example.com".into(),
                server_name: None,
                server_version: None,
                min_client_version: None,
                auth_mode: None,
                native_redirect_uris: vec![],
            }
        );
    }

    #[test]
    fn html_from_spa_catch_all_is_baseline() {
        let transport = FakeTransport::responding(
            200,
            "text/html; charset=utf-8",
            br#"{"manifest_version": 1}"#,
        );
        let discovery = discover(transport, RELEASE, "https://h.example.com")
            .0
            .unwrap();
        assert_eq!(discovery.auth_mode, None);
        assert_eq!(discovery.server_version, None);
    }

    #[test]
    fn other_statuses_are_errors_with_body() {
        for status in [302, 401, 500, 503] {
            let transport = FakeTransport::responding(status, "text/plain", b"upstream down");
            let error = discover(transport, RELEASE, "https://h.example.com")
                .0
                .unwrap_err();
            assert_eq!(
                error,
                CoreError::HttpStatus {
                    status,
                    body: "upstream down".into()
                }
            );
        }
    }

    #[test]
    fn malformed_json_is_a_decode_error() {
        let transport = FakeTransport::responding(
            200,
            "application/json",
            br#"{"manifest_version": 1, "auth": "#,
        );
        let error = discover(transport, RELEASE, "https://h.example.com")
            .0
            .unwrap_err();
        assert!(matches!(error, CoreError::Decode { .. }), "{error:?}");
    }

    #[test]
    fn non_numeric_version_is_a_decode_error() {
        for version in [r#""1""#, "true", "null"] {
            let body = format!(r#"{{"manifest_version": {version}, "auth": {{"mode": "oidc"}}}}"#);
            let transport = FakeTransport::responding(200, "application/json", body.as_bytes());
            let error = discover(transport, RELEASE, "https://h.example.com")
                .0
                .unwrap_err();
            assert!(
                matches!(error, CoreError::Decode { .. }),
                "{version}: {error:?}"
            );
        }
    }

    #[test]
    fn non_json_content_type_is_a_decode_error() {
        for content_type in ["text/plain", ""] {
            let transport =
                FakeTransport::responding(200, content_type, br#"{"manifest_version": 1}"#);
            let error = discover(transport, RELEASE, "https://h.example.com")
                .0
                .unwrap_err();
            assert!(
                matches!(error, CoreError::Decode { .. }),
                "{content_type}: {error:?}"
            );
        }
    }

    #[test]
    fn transport_errors_keep_their_kind() {
        for transport_error in [
            TransportError::Offline {
                message: "no route".into(),
            },
            TransportError::Timeout {
                message: "5s".into(),
            },
            TransportError::Cancelled,
            TransportError::Tls {
                message: "bad cert".into(),
            },
            TransportError::Other {
                message: "boom".into(),
            },
        ] {
            let transport = FakeTransport::new(Err(transport_error.clone()));
            let error = discover(transport, RELEASE, "https://h.example.com")
                .0
                .unwrap_err();
            assert_eq!(error, CoreError::Transport(transport_error));
        }
    }

    #[test]
    fn invalid_url_never_reaches_the_transport() {
        for (input, message) in [
            ("", "Server URL is empty."),
            (
                "http://example.com",
                "This build requires https:// server URLs.",
            ),
            ("ftp://example.com", "Unsupported scheme 'ftp'. Use https."),
        ] {
            let transport = FakeTransport::responding(200, "application/json", b"{}");
            let (result, requests) = discover(transport, RELEASE, input);
            assert_eq!(
                result.unwrap_err(),
                CoreError::InvalidUrl {
                    message: message.into()
                },
                "{input}"
            );
            assert_eq!(requests, vec![]);
        }
    }

    #[test]
    fn header_lookup_is_case_insensitive() {
        let response = HttpResponse {
            status: 200,
            headers: vec![HttpHeader::new("CONTENT-TYPE", "application/json")],
            body: br#"{"manifest_version": 1}"#.to_vec(),
        };
        assert_eq!(response.header("content-type"), Some("application/json"));
    }
}
