//! Token exchange and refresh over the host transport. Port of the request half of
//! `web/ios/Omnigent/DatabricksOAuthClient.swift`.
//!
//! Every request is credential-free apart from the form body: the host transport must not add
//! cookies, cached credentials or caching, and must not follow redirects (an authorization code
//! or verifier must never be forwarded through a redirect). A 3xx therefore arrives here as a
//! response and fails like any other non-200 status.

use super::attempt::{AuthorizationResponse, OAuthAttempt, token_request};
use super::error::DatabricksError;
use super::issuer::OAuthIssuer;
use super::scope::CredentialScope;
use super::tokens::{DatabricksTokens, tokens_from_response};
use crate::auth::SecretString;
use crate::http::{HttpRequest, HttpResponse, HttpTransport};

/// The refresh-token request for `scope`: `grant_type=refresh_token` to the issuer's token
/// endpoint (or the legacy workspace endpoint when the bundle has no issuer).
#[must_use]
pub fn refresh_request(
    scope: &CredentialScope,
    refresh_token: &SecretString,
    issuer: Option<&OAuthIssuer>,
) -> HttpRequest {
    token_request(
        scope,
        &[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token.expose()),
        ],
        issuer,
    )
}

/// Maps a token-endpoint response.
///
/// For a refresh (`previous_refresh_token` set), only HTTP 400 with a JSON `error` of
/// `invalid_grant` means the grant is gone. Every other non-200 status is
/// [`DatabricksError::TokenExchangeFailed`], with the body discarded.
///
/// # Errors
///
/// [`DatabricksError::InvalidRefreshGrant`], [`DatabricksError::TokenExchangeFailed`], or the
/// decoding errors of [`tokens_from_response`].
pub fn tokens_from_token_response(
    response: &HttpResponse,
    requested_at_ms: u64,
    previous_refresh_token: Option<&SecretString>,
    issuer: Option<OAuthIssuer>,
) -> Result<DatabricksTokens, DatabricksError> {
    if previous_refresh_token.is_some()
        && response.status == 400
        && is_invalid_grant(&response.body)
    {
        return Err(DatabricksError::InvalidRefreshGrant);
    }
    if response.status != 200 {
        return Err(DatabricksError::TokenExchangeFailed {
            status: response.status,
        });
    }
    tokens_from_response(
        &response.body,
        requested_at_ms,
        previous_refresh_token,
        issuer,
    )
}

fn is_invalid_grant(body: &[u8]) -> bool {
    serde_json::from_slice::<serde_json::Value>(body)
        .ok()
        .and_then(|value| {
            value
                .get("error")
                .and_then(serde_json::Value::as_str)
                .map(|error| error == "invalid_grant")
        })
        .unwrap_or(false)
}

/// Sends Databricks token requests through a host transport.
#[derive(Debug)]
pub struct OAuthClient<'a, T> {
    transport: &'a T,
}

impl<'a, T: HttpTransport> OAuthClient<'a, T> {
    /// A client that sends through `transport`.
    pub const fn new(transport: &'a T) -> Self {
        Self { transport }
    }

    /// Confirms the callback's issuer through discovery, then exchanges the code at that issuer's
    /// token endpoint. The returned bundle records the issuer.
    ///
    /// `now_ms` is read before the requests; the expiry counts from it.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::InvalidDiscovery`] (and no token request is made) when discovery does
    /// not confirm the issuer; [`DatabricksError::NetworkUnavailable`] or
    /// [`DatabricksError::Cancelled`] from the transport; then see
    /// [`tokens_from_token_response`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn exchange(
        &self,
        attempt: &OAuthAttempt,
        authorization: &AuthorizationResponse,
        now_ms: u64,
    ) -> Result<DatabricksTokens, DatabricksError> {
        let issuer = &authorization.issuer;
        let discovery = self.send(issuer.discovery_request()).await?;
        issuer.validate_discovery(&discovery)?;
        let response = self
            .send(attempt.token_request(&authorization.code, Some(issuer)))
            .await?;
        tokens_from_token_response(&response, now_ms, None, Some(issuer.clone()))
    }

    /// Refreshes `refresh_token` for `scope` at `issuer` (or the legacy workspace endpoint).
    /// The new bundle keeps `issuer`, and keeps `refresh_token` when the response omits one.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::NetworkUnavailable`] or [`DatabricksError::Cancelled`] from the
    /// transport, then see [`tokens_from_token_response`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn refresh(
        &self,
        scope: &CredentialScope,
        refresh_token: &SecretString,
        issuer: Option<&OAuthIssuer>,
        now_ms: u64,
    ) -> Result<DatabricksTokens, DatabricksError> {
        let response = self
            .send(refresh_request(scope, refresh_token, issuer))
            .await?;
        tokens_from_token_response(&response, now_ms, Some(refresh_token), issuer.cloned())
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, DatabricksError> {
        self.transport
            .send(request)
            .await
            .map_err(DatabricksError::from_transport)
    }
}

#[cfg(test)]
mod tests {
    use futures::executor::block_on;

    use super::*;
    use crate::auth::databricks::test_support::{
        ACCOUNT_ISSUER, TOKEN_BODY, attempt_for, discovery_body, form_fields, url,
    };
    use crate::auth::testing::{FixedEntropy, ScriptedTransport, header};
    use crate::http::TransportError;

    const WORKSPACE: &str = "https://test-workspace.cloud.databricks.com";

    fn exchange(transport: &ScriptedTransport) -> Result<DatabricksTokens, DatabricksError> {
        let attempt = attempt_for(WORKSPACE, &FixedEntropy::counting());
        let authorization = attempt
            .authorization_response(&url(&format!(
                "https://login.databricks.com/mobile-redirect?state={}&code=code",
                attempt.state().expose()
            )))
            .unwrap();
        block_on(OAuthClient::new(transport).exchange(&attempt, &authorization, 1_000))
    }

    fn with_workspace_discovery(transport: &ScriptedTransport) -> &ScriptedTransport {
        transport.json(200, &discovery_body(&format!("{WORKSPACE}/oidc")))
    }

    /// `DatabricksOAuthClientTests::testExchangeUsesIsolatedSession`: the exchange carries no
    /// cookie or authorization header, and goes to the workspace issuer after discovery.
    #[test]
    fn databricks_token_exchange_uses_isolated_client() {
        let transport = ScriptedTransport::new();
        with_workspace_discovery(&transport).json(200, TOKEN_BODY);
        let tokens = exchange(&transport).unwrap();
        assert_eq!(tokens.access_token.expose(), "opaque-access");
        assert_eq!(tokens.expires_at_ms, 121_000);
        assert_eq!(tokens.issuer.unwrap().as_str(), format!("{WORKSPACE}/oidc"));
        let requests = transport.take();
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[0].method, "GET");
        assert_eq!(
            requests[0].url,
            format!("{WORKSPACE}/oidc/.well-known/openid-configuration")
        );
        assert_eq!(requests[1].method, "POST");
        assert_eq!(requests[1].url, format!("{WORKSPACE}/oidc/v1/token"));
        for request in &requests {
            assert_eq!(header(request, "Cookie"), None);
            assert_eq!(header(request, "Authorization"), None);
        }
    }

    /// `DatabricksOAuthClientTests::testHTTPFailuresAndUnexpectedResponseOriginsAreRejected`.
    /// (Response-origin checks belong to the host transport, which never follows redirects.)
    #[test]
    fn databricks_token_exchange_http_failures_sanitized() {
        for status in [302, 400, 401, 403, 500] {
            let transport = ScriptedTransport::new();
            with_workspace_discovery(&transport).json(status, "sensitive response");
            let error = exchange(&transport).unwrap_err();
            assert_eq!(error, DatabricksError::TokenExchangeFailed { status });
            assert!(!error.to_string().contains("sensitive"));
            assert!(!format!("{error:?}").contains("sensitive"));
        }
    }

    /// `DatabricksOAuthClientTests::testNetworkErrorsAreSanitized`.
    #[test]
    fn databricks_token_exchange_network_error_sanitized() {
        let transport = ScriptedTransport::new();
        let offline = TransportError::Offline {
            message: "The Internet connection appears to be offline.".into(),
        };
        with_workspace_discovery(&transport).fail(offline.clone());
        assert_eq!(
            exchange(&transport),
            Err(DatabricksError::NetworkUnavailable(offline))
        );
        let transport = ScriptedTransport::new();
        with_workspace_discovery(&transport).fail(TransportError::Cancelled);
        assert_eq!(exchange(&transport), Err(DatabricksError::Cancelled));
    }

    /// `DatabricksOAuthClientTests::testRefusesRealSameAndCrossOriginRedirects`: a 307 is a final
    /// response for the token client, same-origin or not; nothing is sent to the `Location`.
    #[test]
    fn databricks_token_transport_does_not_follow_redirects() {
        for location in ["/unexpected", "https://example.org/token"] {
            let transport = ScriptedTransport::new();
            with_workspace_discovery(&transport).push(Ok(HttpResponse {
                status: 307,
                headers: vec![crate::http::HttpHeader::new("Location", location)],
                body: Vec::new(),
            }));
            assert_eq!(
                exchange(&transport),
                Err(DatabricksError::TokenExchangeFailed { status: 307 })
            );
            assert_eq!(transport.take().len(), 2, "no request follows the redirect");
        }
        let transport = ScriptedTransport::new();
        transport.reply(302, "text/html", "");
        assert_eq!(exchange(&transport), Err(DatabricksError::InvalidDiscovery));
        assert_eq!(transport.take().len(), 1);
    }

    /// `DatabricksOAuthClientTests::testRefreshFormAndRotatedResponse`.
    #[test]
    fn databricks_refresh_form_and_rotated_response() {
        let transport = ScriptedTransport::new();
        transport.json(200, TOKEN_BODY);
        let scope = attempt_for(WORKSPACE, &FixedEntropy::counting())
            .scope()
            .clone();
        let tokens = block_on(OAuthClient::new(&transport).refresh(
            &scope,
            &SecretString::new("old+/=&refresh"),
            None,
            0,
        ))
        .unwrap();
        assert_eq!(tokens.refresh_token.expose(), "opaque-refresh");
        let request = transport.take().remove(0);
        assert_eq!(request.method, "POST");
        assert_eq!(request.url, format!("{WORKSPACE}/oidc/v1/token"));
        assert_eq!(header(&request, "Authorization"), None);
        let fields = form_fields(&request);
        assert_eq!(fields.len(), 3);
        assert_eq!(fields["grant_type"], "refresh_token");
        assert_eq!(fields["client_id"], "test-client");
        assert_eq!(fields["refresh_token"], "old+/=&refresh");
    }

    /// `DatabricksOAuthClientTests::testOnlyValidatedInvalidGrantResponseInvalidatesRefresh`.
    #[test]
    fn databricks_only_invalid_grant_invalidates_refresh() {
        let scope = attempt_for(WORKSPACE, &FixedEntropy::counting())
            .scope()
            .clone();
        for (status, body, expected) in [
            (
                400,
                r#"{"error":"invalid_grant","error_description":"private"}"#,
                DatabricksError::InvalidRefreshGrant,
            ),
            (
                400,
                r#"{"error":"invalid_client"}"#,
                DatabricksError::TokenExchangeFailed { status: 400 },
            ),
            (
                401,
                r#"{"error":"invalid_client"}"#,
                DatabricksError::TokenExchangeFailed { status: 401 },
            ),
            (
                403,
                "denied",
                DatabricksError::TokenExchangeFailed { status: 403 },
            ),
            (
                429,
                "rate limited",
                DatabricksError::TokenExchangeFailed { status: 429 },
            ),
            (
                500,
                r#"{"error":"invalid_grant"}"#,
                DatabricksError::TokenExchangeFailed { status: 500 },
            ),
            (
                400,
                "not json",
                DatabricksError::TokenExchangeFailed { status: 400 },
            ),
        ] {
            let transport = ScriptedTransport::new();
            transport.json(status, body);
            let error = block_on(OAuthClient::new(&transport).refresh(
                &scope,
                &SecretString::new("old-refresh"),
                None,
                0,
            ))
            .unwrap_err();
            assert_eq!(error, expected, "{status} {body}");
            assert!(!error.to_string().contains("private"));
        }
        // An exchange never treats invalid_grant as a refresh failure.
        let response =
            crate::auth::testing::response(400, "application/json", r#"{"error":"invalid_grant"}"#);
        assert_eq!(
            tokens_from_token_response(&response, 0, None, None),
            Err(DatabricksError::TokenExchangeFailed { status: 400 })
        );
    }

    /// `DatabricksOAuthIssuerTests::testExchangeAndRefreshUseDiscoveredIssuerWithoutChangingDestination`.
    #[test]
    fn databricks_exchange_and_refresh_use_discovered_issuer() {
        let attempt = attempt_for(WORKSPACE, &FixedEntropy::counting());
        let issuer = OAuthIssuer::parse(ACCOUNT_ISSUER).unwrap();
        let authorization = AuthorizationResponse {
            code: SecretString::new("test-code"),
            issuer: issuer.clone(),
        };
        let transport = ScriptedTransport::new();
        transport
            .json(200, &discovery_body(ACCOUNT_ISSUER))
            .json(200, TOKEN_BODY)
            .json(200, TOKEN_BODY);
        let client = OAuthClient::new(&transport);
        let tokens = block_on(client.exchange(&attempt, &authorization, 0)).unwrap();
        assert_eq!(tokens.access_token.expose(), "opaque-access");
        assert_eq!(tokens.issuer.as_ref(), Some(&issuer));
        let refreshed = block_on(client.refresh(
            attempt.scope(),
            &tokens.refresh_token,
            tokens.issuer.as_ref(),
            0,
        ))
        .unwrap();
        assert_eq!(refreshed.issuer.as_ref(), Some(&issuer));
        assert_eq!(attempt.scope().workspace_origin(), WORKSPACE);
        let requests = transport.take();
        let token_url = format!("{ACCOUNT_ISSUER}/v1/token");
        for request in &requests[1..] {
            assert_eq!(request.method, "POST");
            assert_eq!(request.url, token_url);
            assert!(!request.url.contains('?'));
        }
        assert!(requests.iter().all(|r| !r.url.starts_with(WORKSPACE)));
    }

    /// `DatabricksOAuthIssuerTests::testInvalidDiscoveryNeverReceivesAuthorizationCode`.
    #[test]
    fn databricks_invalid_discovery_never_exchanges() {
        let foreign =
            r#"{"issuer":"https://example.org/oidc","token_endpoint":"https://example.org/token"}"#;
        for status in [200, 302, 500] {
            let transport = ScriptedTransport::new();
            transport.json(status, foreign);
            assert_eq!(exchange(&transport), Err(DatabricksError::InvalidDiscovery));
            let requests = transport.take();
            assert_eq!(requests.len(), 1, "no token request after failed discovery");
            assert_eq!(requests[0].method, "GET");
            assert!(
                requests[0]
                    .url
                    .ends_with("/.well-known/openid-configuration")
            );
            assert_eq!(requests[0].body, None);
            assert_eq!(header(&requests[0], "Authorization"), None);
        }
    }
}
