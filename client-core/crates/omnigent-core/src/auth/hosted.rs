//! An identity-bound connection to one server: discovery, identity confirmation, and the
//! connected state every later request checks.
//!
//! Port of the connect path of `NativeLab`'s `LocalServerSessionClient`:
//!
//! 1. `GET /v1/info`. A loopback endpoint must be a pure single-user server; a hosted endpoint
//!    needs a bearer, and a single-user-only answer there is rejected (it would be mistaken for
//!    bearer auth).
//! 2. `GET /v1/me`. The `user_id` must be non-blank (`local` for single-user), equal to the
//!    expected account when one is saved, and equal to the identity confirmed by an earlier
//!    connect (reconnect pinning).
//!
//! Credentials and identity are fixed for the connection's lifetime; switch accounts with a new
//! [`HostedConnection`]. A `401` on any request ends the connection, and later requests fail
//! with [`HostedAuthError::NotConnected`] before reaching the network.

use serde_json::Value;

use super::SecretString;
use super::endpoint::{ServerEndpoint, ServerIdentityScope, validate_bearer};
use super::errors::HostedAuthError;
use super::mode::{ServerInfo, error_text};
use crate::http::{HttpRequest, HttpResponse, HttpTransport};

/// The user id a loopback single-user server reports.
pub const LOCAL_USER_ID: &str = "local";

/// What a successful connect confirmed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectedServer {
    /// The canonical API root.
    pub base_url: String,
    /// The confirmed user id.
    pub user_id: String,
    /// The account scope for per-account state.
    pub scope: ServerIdentityScope,
}

/// A connection to one server with fixed credentials.
#[derive(Debug)]
pub struct HostedConnection {
    endpoint: ServerEndpoint,
    bearer: Option<SecretString>,
    expected_user_id: Option<String>,
    confirmed_user_id: Option<String>,
    connected: bool,
    generation: u64,
}

impl HostedConnection {
    /// A disconnected connection.
    ///
    /// # Errors
    ///
    /// [`HostedAuthError::Unauthorized`] for an invalid bearer,
    /// [`HostedAuthError::UnsupportedAuthentication`] for a bearer on a local single-user
    /// endpoint, and [`HostedAuthError::IdentityUnavailable`] for a blank expected user id.
    pub fn new(
        endpoint: ServerEndpoint,
        bearer: Option<SecretString>,
        expected_user_id: Option<String>,
    ) -> Result<Self, HostedAuthError> {
        if let Some(bearer) = &bearer {
            validate_bearer(bearer.expose())?;
            if endpoint.is_local_single_user() {
                return Err(HostedAuthError::UnsupportedAuthentication);
            }
        }
        if expected_user_id
            .as_deref()
            .is_some_and(|id| id.trim().is_empty())
        {
            return Err(HostedAuthError::IdentityUnavailable);
        }
        Ok(Self {
            endpoint,
            bearer,
            expected_user_id,
            confirmed_user_id: None,
            connected: false,
            generation: 0,
        })
    }

    /// The endpoint.
    #[must_use]
    pub const fn endpoint(&self) -> &ServerEndpoint {
        &self.endpoint
    }

    /// Whether `connect` succeeded and no later request ended the connection.
    #[must_use]
    pub const fn is_connected(&self) -> bool {
        self.connected
    }

    /// Bumped by every connect and disconnect; results from an older generation are stale.
    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }

    /// Ends the connection. The confirmed identity stays pinned for the next connect.
    pub const fn disconnect(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.connected = false;
    }

    /// Runs discovery and identity confirmation.
    ///
    /// # Errors
    ///
    /// [`HostedAuthError::UnsupportedAuthentication`], [`HostedAuthError::Unauthorized`] (no
    /// bearer for a hosted server, or a `401`), [`HostedAuthError::IdentityUnavailable`],
    /// [`HostedAuthError::IdentityMismatch`], and the response and transport errors of the two
    /// requests. The connection stays disconnected on any error.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn connect<T: HttpTransport>(
        &mut self,
        transport: &T,
    ) -> Result<ConnectedServer, HostedAuthError> {
        self.disconnect();
        let info_response = transport
            .send(self.build_request("GET", "/v1/info", &[], "application/json")?)
            .await?;
        let info = ServerInfo::from_json(&self.checked(&info_response)?.body)?;
        if self.endpoint.is_local_single_user() {
            if !info.single_user || info.accounts_enabled || info.login_url.is_some() {
                return Err(HostedAuthError::UnsupportedAuthentication);
            }
        } else {
            if self.bearer.is_none() {
                return Err(HostedAuthError::Unauthorized { reason: None });
            }
            if info.single_user && !info.accounts_enabled && info.login_url.is_none() {
                return Err(HostedAuthError::UnsupportedAuthentication);
            }
        }
        let me_response = transport
            .send(self.build_request("GET", "/v1/me", &[], "application/json")?)
            .await?;
        let me: Value =
            serde_json::from_slice(&self.checked(&me_response)?.body).map_err(|error| {
                HostedAuthError::MalformedResponse {
                    detail: format!("/v1/me: {error}"),
                }
            })?;
        let user_id = me
            .get("user_id")
            .and_then(Value::as_str)
            .filter(|id| !id.trim().is_empty())
            .filter(|id| !self.endpoint.is_local_single_user() || *id == LOCAL_USER_ID)
            .ok_or(HostedAuthError::IdentityUnavailable)?
            .to_owned();
        if self
            .expected_user_id
            .as_ref()
            .is_some_and(|expected| *expected != user_id)
            || self
                .confirmed_user_id
                .as_ref()
                .is_some_and(|confirmed| *confirmed != user_id)
        {
            return Err(HostedAuthError::IdentityMismatch);
        }
        self.confirmed_user_id = Some(user_id.clone());
        self.connected = true;
        Ok(ConnectedServer {
            base_url: self.endpoint.base_url().to_owned(),
            scope: self.endpoint.identity_scope(&user_id),
            user_id,
        })
    }

    /// A request for an API route on the connected server.
    ///
    /// # Errors
    ///
    /// [`HostedAuthError::NotConnected`] before `connect` or after the connection ended, then
    /// [`ServerEndpoint::request_with`]'s errors.
    pub fn request(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, &str)],
        accept: &str,
    ) -> Result<HttpRequest, HostedAuthError> {
        if !self.connected {
            return Err(HostedAuthError::NotConnected);
        }
        self.build_request(method, path, query, accept)
    }

    /// The WebSocket URL for a route on the connected server; the bearer goes in the handshake's
    /// `Authorization` header (see [`HostedConnection::authorization`]).
    ///
    /// # Errors
    ///
    /// [`HostedAuthError::NotConnected`], then [`ServerEndpoint::websocket_url`]'s errors.
    pub fn websocket_url(
        &self,
        path: &str,
        query: &[(&str, &str)],
    ) -> Result<String, HostedAuthError> {
        if !self.connected {
            return Err(HostedAuthError::NotConnected);
        }
        self.endpoint.websocket_url(path, query)
    }

    /// The `Authorization` header value, when this connection carries a bearer.
    #[must_use]
    pub fn authorization(&self) -> Option<SecretString> {
        self.bearer
            .as_ref()
            .map(|bearer| SecretString::new(format!("Bearer {}", bearer.expose())))
    }

    /// Applies the auth-relevant status policy to a response for this connection: a `401` ends
    /// the connection.
    ///
    /// # Errors
    ///
    /// [`HostedAuthError::RedirectNotAllowed`] for a 3xx, [`HostedAuthError::Unauthorized`] for a
    /// `401`, [`HostedAuthError::Forbidden`] for a `403`, [`HostedAuthError::HttpStatus`] for
    /// any other non-2xx.
    pub fn check_response<'r>(
        &mut self,
        response: &'r HttpResponse,
    ) -> Result<&'r HttpResponse, HostedAuthError> {
        if response.status == 401 {
            self.disconnect();
        }
        self.checked(response)
    }

    /// `GET path` and decode JSON, with the connected-state and status policy applied.
    ///
    /// # Errors
    ///
    /// See [`HostedConnection::request`] and [`HostedConnection::check_response`];
    /// [`HostedAuthError::MalformedResponse`] for a body that is not JSON.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn get_json<T: HttpTransport>(
        &mut self,
        transport: &T,
        path: &str,
        query: &[(&str, &str)],
    ) -> Result<Value, HostedAuthError> {
        let request = self.request("GET", path, query, "application/json")?;
        let generation = self.generation;
        let response = transport.send(request).await?;
        if generation != self.generation {
            return Err(HostedAuthError::NotConnected);
        }
        let response = self.check_response(&response)?;
        serde_json::from_slice(&response.body).map_err(|error| HostedAuthError::MalformedResponse {
            detail: format!("{path}: {error}"),
        })
    }

    fn build_request(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, &str)],
        accept: &str,
    ) -> Result<HttpRequest, HostedAuthError> {
        self.endpoint
            .request_with(method, path, query, accept, self.bearer.as_ref())
    }

    #[allow(
        clippy::unused_self,
        reason = "kept a method so connect and check_response share one policy"
    )]
    fn checked<'r>(&self, response: &'r HttpResponse) -> Result<&'r HttpResponse, HostedAuthError> {
        match response.status {
            200..=299 => Ok(response),
            300..=399 => Err(HostedAuthError::RedirectNotAllowed),
            401 => Err(HostedAuthError::Unauthorized {
                reason: error_text(&response.body),
            }),
            403 => Err(HostedAuthError::Forbidden),
            status => Err(HostedAuthError::HttpStatus { status }),
        }
    }
}

#[cfg(test)]
mod tests {
    use futures::executor::block_on;

    use super::*;
    use crate::auth::endpoint::DATABRICKS_ORG_HEADER;
    use crate::auth::testing::{ScriptedTransport, fixture, header};

    const MOUNT: &str = "/api/2.0/omnigent";
    const TOKEN: &str = "fixture-token-not-a-real-credential";

    /// `(status, response body)` of each envelope in a `.json` or `.jsonl` fixture, in order.
    fn envelopes(path: &str) -> Vec<(u16, String)> {
        let text = fixture(path);
        let lines = std::path::Path::new(path)
            .extension()
            .is_some_and(|extension| extension.eq_ignore_ascii_case("jsonl"));
        let values: Vec<Value> = if lines {
            text.lines()
                .filter(|line| !line.trim().is_empty())
                .map(|line| serde_json::from_str(line).unwrap())
                .collect()
        } else {
            vec![serde_json::from_str(&text).unwrap()]
        };
        values
            .iter()
            .map(|value| {
                let status = u16::try_from(value["status"].as_u64().unwrap()).unwrap();
                (status, value["response"].to_string())
            })
            .collect()
    }

    fn script(transport: &ScriptedTransport, path: &str) {
        for (status, body) in envelopes(path) {
            transport.json(status, &body);
        }
    }

    fn hosted() -> ServerEndpoint {
        ServerEndpoint::new(&format!("https://127.0.0.1:8443{MOUNT}")).unwrap()
    }

    #[allow(
        clippy::unnecessary_wraps,
        reason = "matches the HostedConnection::new parameter"
    )]
    fn bearer() -> Option<SecretString> {
        Some(SecretString::new(TOKEN))
    }

    fn paths(transport: &ScriptedTransport) -> Vec<String> {
        transport
            .take()
            .iter()
            .map(|request| url::Url::parse(&request.url).unwrap().path().to_owned())
            .collect()
    }

    #[test]
    fn connect_verifies_discovery_and_identity_without_credentials() {
        let transport = ScriptedTransport::new();
        script(
            &transport,
            "sessions/LocalServerSessionClient--_shared--info.json",
        );
        script(
            &transport,
            "sessions/LocalServerSessionClient--_shared--me.json",
        );
        let mut connection = HostedConnection::new(
            ServerEndpoint::new("http://127.0.0.1:6767").unwrap(),
            None,
            None,
        )
        .unwrap();
        let info = block_on(connection.connect(&transport)).unwrap();
        assert_eq!(info.base_url, "http://127.0.0.1:6767");
        assert_eq!(info.user_id, "local");
        let requests = transport.take();
        assert_eq!(
            requests.iter().map(|r| r.url.as_str()).collect::<Vec<_>>(),
            [
                "http://127.0.0.1:6767/v1/info",
                "http://127.0.0.1:6767/v1/me"
            ]
        );
        for request in &requests {
            assert_eq!(request.method, "GET");
            assert_eq!(request.body, None);
            assert_eq!(header(request, "Authorization"), None);
            assert_eq!(header(request, "Cookie"), None);
            assert_eq!(header(request, "Accept"), Some("application/json"));
        }
    }

    #[test]
    fn unsupported_authentication_fails_closed() {
        for (status, body) in envelopes(
            "sessions/LocalServerSessionClient--UnsupportedAuthenticationFailsClosed.jsonl",
        ) {
            let transport = ScriptedTransport::new();
            transport.json(status, &body);
            let mut connection = HostedConnection::new(
                ServerEndpoint::new("http://127.0.0.1:6767").unwrap(),
                None,
                None,
            )
            .unwrap();
            assert_eq!(
                block_on(connection.connect(&transport)),
                Err(HostedAuthError::UnsupportedAuthentication),
                "{body}"
            );
            assert_eq!(
                block_on(connection.get_json(&transport, "/v1/sessions", &[])),
                Err(HostedAuthError::NotConnected)
            );
            assert_eq!(transport.take().len(), 1);
        }
    }

    #[test]
    fn missing_or_different_identity_fails_closed() {
        for (status, body) in envelopes(
            "sessions/LocalServerSessionClient--MissingOrDifferentIdentityFailsClosed.jsonl",
        ) {
            let transport = ScriptedTransport::new();
            script(
                &transport,
                "sessions/LocalServerSessionClient--_shared--info.json",
            );
            transport.json(status, &body);
            let mut connection = HostedConnection::new(
                ServerEndpoint::new("http://127.0.0.1:6767").unwrap(),
                None,
                None,
            )
            .unwrap();
            assert_eq!(
                block_on(connection.connect(&transport)),
                Err(HostedAuthError::IdentityUnavailable),
                "{body}"
            );
            assert_eq!(
                block_on(connection.get_json(&transport, "/v1/sessions", &[])),
                Err(HostedAuthError::NotConnected)
            );
            assert_eq!(transport.take().len(), 2);
        }
    }

    #[test]
    fn public_connection_state_becomes_false_after401() {
        let transport = ScriptedTransport::new();
        for (status, body) in
            envelopes("sessions/HostedServerAuthentication--_shared--hosted-configure.jsonl")
                .into_iter()
                .take(2)
        {
            transport.json(status, &body);
        }
        let mut connection = HostedConnection::new(hosted(), bearer(), None).unwrap();
        assert!(!connection.is_connected());
        block_on(connection.connect(&transport)).unwrap();
        assert!(connection.is_connected());
        script(
            &transport,
            "sessions/HostedServerAuthentication--PublicConnectionStateBecomesFalseAfter401.json",
        );
        assert_eq!(
            block_on(connection.get_json(&transport, "/v1/sessions", &[])),
            Err(HostedAuthError::Unauthorized { reason: None })
        );
        assert!(!connection.is_connected());
        assert_eq!(transport.take().len(), 3);
        assert_eq!(
            block_on(connection.get_json(&transport, "/v1/sessions", &[])),
            Err(HostedAuthError::NotConnected)
        );
        assert_eq!(transport.take().len(), 0, "no request after the 401");
    }

    #[test]
    fn hosted_proxy_confirms_identity_and_scopes_every_request_to_mounted_api() {
        let transport = ScriptedTransport::new();
        script(
            &transport,
            "sessions/HostedServerAuthentication--_shared--hosted-configure.jsonl",
        );
        let mut connection =
            HostedConnection::new(hosted(), bearer(), Some("alice".into())).unwrap();
        let info = block_on(connection.connect(&transport)).unwrap();
        assert_eq!(info.user_id, "alice");
        assert_eq!(info.scope, hosted().identity_scope("alice"));
        block_on(connection.get_json(&transport, "/v1/sessions", &[])).unwrap();
        let requests = transport.take();
        assert_eq!(
            requests
                .iter()
                .map(|r| url::Url::parse(&r.url).unwrap().path().to_owned())
                .collect::<Vec<_>>(),
            ["/v1/info", "/v1/me", "/v1/sessions"].map(|p| format!("{MOUNT}{p}"))
        );
        for request in &requests {
            assert_eq!(
                header(request, "Authorization"),
                Some(format!("Bearer {TOKEN}").as_str())
            );
            assert_eq!(header(request, "Cookie"), None);
            assert_eq!(header(request, "X-Forwarded-Email"), None);
        }
    }

    #[test]
    fn hosted_connections_require_bearer_and_nonempty_confirmed_identity() {
        let transport = ScriptedTransport::new();
        script(
            &transport,
            "sessions/HostedServerAuthentication--_shared--hosted-configure.jsonl",
        );
        let mut missing = HostedConnection::new(hosted(), None, None).unwrap();
        assert_eq!(
            block_on(missing.connect(&transport)),
            Err(HostedAuthError::Unauthorized { reason: None })
        );
        assert!(!paths(&transport).iter().any(|path| path.ends_with("/me")));
        for (status, body) in envelopes(
            "sessions/HostedServerAuthentication--HostedConnectionsRequireBearerAndNonemptyConfirmedIdentity.jsonl",
        ) {
            let transport = ScriptedTransport::new();
            transport.json(200, r#"{"single_user":false,"accounts_enabled":false}"#);
            transport.json(status, &body);
            let mut connection = HostedConnection::new(hosted(), bearer(), None).unwrap();
            assert_eq!(
                block_on(connection.connect(&transport)),
                Err(HostedAuthError::IdentityUnavailable),
                "{body}"
            );
            assert_eq!(
                block_on(connection.get_json(&transport, "/v1/sessions", &[])),
                Err(HostedAuthError::NotConnected)
            );
        }
    }

    #[test]
    fn hosted_single_user_fallback_is_not_mistaken_for_bearer_authentication() {
        let transport = ScriptedTransport::new();
        script(
            &transport,
            "sessions/HostedServerAuthentication--HostedSingleUserFallbackIsNotMistakenForBearerAuthentication.json",
        );
        let mut connection = HostedConnection::new(hosted(), bearer(), None).unwrap();
        assert_eq!(
            block_on(connection.connect(&transport)),
            Err(HostedAuthError::UnsupportedAuthentication)
        );
        assert_eq!(transport.take().len(), 1);
    }

    #[test]
    fn expected_identity_and_reconnect_pinning_reject_different_accounts() {
        let transport = ScriptedTransport::new();
        script(
            &transport,
            "sessions/HostedServerAuthentication--_shared--hosted-configure.jsonl",
        );
        let mut wrong = HostedConnection::new(hosted(), bearer(), Some("bob".into())).unwrap();
        assert_eq!(
            block_on(wrong.connect(&transport)),
            Err(HostedAuthError::IdentityMismatch)
        );
        let info = r#"{"single_user":false,"accounts_enabled":false}"#;
        let transport = ScriptedTransport::new();
        for (status, body) in envelopes(
            "sessions/HostedServerAuthentication--ExpectedIdentityAndReconnectPinningRejectDifferentAccounts.jsonl",
        )
        .into_iter()
        .skip(1)
        {
            transport.json(200, info).json(status, &body);
        }
        let mut client = HostedConnection::new(hosted(), bearer(), None).unwrap();
        block_on(client.connect(&transport)).unwrap();
        assert_eq!(
            block_on(client.connect(&transport)),
            Err(HostedAuthError::IdentityMismatch)
        );
        assert_eq!(
            block_on(client.get_json(&transport, "/v1/sessions", &[])),
            Err(HostedAuthError::NotConnected)
        );
    }

    #[test]
    fn identity_notification_and_draft_scopes_separate_orgs_on_same_host() {
        let first_endpoint = ServerEndpoint::new(&format!(
            "https://fixture.cloud.databricks.com:8443{MOUNT}?o=123"
        ))
        .unwrap();
        let second_endpoint = ServerEndpoint::new(&format!(
            "https://fixture.cloud.databricks.com:8443{MOUNT}?o=456"
        ))
        .unwrap();
        let transport = ScriptedTransport::new();
        script(
            &transport,
            "sessions/DatabricksRouting--_shared--configure.jsonl",
        );
        let mut first = HostedConnection::new(first_endpoint.clone(), bearer(), None).unwrap();
        let first_info = block_on(first.connect(&transport)).unwrap();
        let transport_b = ScriptedTransport::new();
        script(
            &transport_b,
            "sessions/DatabricksRouting--_shared--configure.jsonl",
        );
        let mut second = HostedConnection::new(second_endpoint, bearer(), None).unwrap();
        let second_info = block_on(second.connect(&transport_b)).unwrap();
        assert_eq!(first_info.user_id, second_info.user_id);
        assert_eq!(first_info.base_url, first_endpoint.base_url());
        assert_ne!(first_info.scope, second_info.scope);
        block_on(first.get_json(
            &transport,
            "/v1/sessions",
            &[("after", "cursor"), ("limit", "20")],
        ))
        .unwrap();
        let requests = transport.take();
        for request in &requests {
            assert_eq!(header(request, DATABRICKS_ORG_HEADER), Some("123"));
            let url = url::Url::parse(&request.url).unwrap();
            assert!(
                !url.query_pairs().any(|(name, _)| name == "o"),
                "{}",
                request.url
            );
        }
    }

    #[test]
    fn stale_generation_results_are_dropped() {
        let transport = ScriptedTransport::new();
        transport
            .json(200, r#"{"single_user":false,"accounts_enabled":false}"#)
            .json(200, r#"{"user_id":"alice"}"#);
        let mut connection = HostedConnection::new(hosted(), bearer(), None).unwrap();
        block_on(connection.connect(&transport)).unwrap();
        let before = connection.generation();
        connection.disconnect();
        assert_ne!(before, connection.generation());
        assert_eq!(
            connection.request("GET", "/v1/sessions", &[], "application/json"),
            Err(HostedAuthError::NotConnected)
        );
        assert_eq!(
            connection
                .authorization()
                .map(|value| value.expose().to_owned()),
            Some(format!("Bearer {TOKEN}"))
        );
    }
}
