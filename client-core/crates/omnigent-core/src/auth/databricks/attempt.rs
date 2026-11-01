//! One authorization-code + PKCE attempt. Port of
//! `web/ios/Omnigent/DatabricksOAuthAttempt.swift`.
//!
//! The attempt's `state` and verifier are transient: never persisted, logged, or handed to page
//! JavaScript. `Debug` redacts both.

use std::fmt;

use url::Url;

use super::config::OAuthConfiguration;
use super::error::DatabricksError;
use super::issuer::OAuthIssuer;
use super::query;
use super::scope::CredentialScope;
use crate::auth::pkce::{self, CODE_CHALLENGE_METHOD};
use crate::auth::{EntropySource, SecretString};
use crate::http::{HttpHeader, HttpRequest};

/// The scopes every Databricks sign-in requests.
pub const OAUTH_SCOPE: &str = "all-apis offline_access";

/// A validated browser callback: the code to exchange and the issuer that must receive it.
#[derive(Clone, PartialEq, Eq)]
pub struct AuthorizationResponse {
    /// The authorization code (percent-decoded).
    pub code: SecretString,
    /// The callback's `iss`, or the workspace's own `/oidc` issuer when the callback has none.
    pub issuer: OAuthIssuer,
}

impl fmt::Debug for AuthorizationResponse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AuthorizationResponse")
            .field("code", &self.code)
            .field("issuer", &self.issuer)
            .finish()
    }
}

/// Transient material for one sign-in.
#[derive(Clone, PartialEq, Eq)]
pub struct OAuthAttempt {
    configuration: OAuthConfiguration,
    scope: CredentialScope,
    state: SecretString,
    verifier: SecretString,
}

impl fmt::Debug for OAuthAttempt {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OAuthAttempt")
            .field("scope", &self.scope)
            .field("state", &self.state)
            .field("verifier", &self.verifier)
            .finish_non_exhaustive()
    }
}

impl OAuthAttempt {
    /// A fresh attempt for `workspace_url` with a new `state` and verifier from `entropy`.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::InvalidWorkspace`] for a URL that is not an https Databricks workspace
    /// (see [`CredentialScope::new`]); [`DatabricksError::RandomGenerationFailed`] when the host
    /// RNG fails.
    pub fn new(
        workspace_url: &Url,
        configuration: &OAuthConfiguration,
        entropy: &dyn EntropySource,
    ) -> Result<Self, DatabricksError> {
        let scope = CredentialScope::new(workspace_url, configuration)?;
        let state = pkce::random_value(entropy).map_err(DatabricksError::RandomGenerationFailed)?;
        let verifier =
            pkce::random_value(entropy).map_err(DatabricksError::RandomGenerationFailed)?;
        Ok(Self {
            configuration: configuration.clone(),
            scope,
            state: SecretString::new(state),
            verifier: SecretString::new(verifier),
        })
    }

    /// The client configuration.
    #[must_use]
    pub const fn configuration(&self) -> &OAuthConfiguration {
        &self.configuration
    }

    /// The credential scope this attempt signs in to.
    #[must_use]
    pub const fn scope(&self) -> &CredentialScope {
        &self.scope
    }

    /// The CSRF `state` value.
    #[must_use]
    pub const fn state(&self) -> &SecretString {
        &self.state
    }

    /// The PKCE verifier.
    #[must_use]
    pub const fn verifier(&self) -> &SecretString {
        &self.verifier
    }

    /// `<workspace>/oidc/v1/authorize` with the public-client PKCE (S256) parameters and the
    /// selected `o=`. Values are percent-encoded so a literal `+` never reads as a space.
    #[must_use]
    pub fn authorization_url(&self) -> String {
        let challenge = pkce::code_challenge_s256(self.verifier.expose());
        let mut fields = vec![
            ("client_id", self.configuration.client_id()),
            ("redirect_uri", self.configuration.redirect_uri()),
            ("response_type", "code"),
            ("scope", OAUTH_SCOPE),
            ("state", self.state.expose()),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", CODE_CHALLENGE_METHOD),
        ];
        if let Some(id) = self.scope.workspace_id() {
            fields.push(("o", id));
        }
        let query = String::from_utf8(pkce::form_body(&fields)).unwrap_or_default();
        format!(
            "{}/oidc/v1/authorize?{query}",
            self.scope.workspace_origin()
        )
    }

    /// Validates the browser callback: the configured redirect, exactly one matching `state`,
    /// then either one non-empty `error` (mapped to a fixed error, description discarded) or one
    /// non-empty `code`, and at most one `iss`.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::InvalidCallback`], [`DatabricksError::AuthorizationDenied`],
    /// [`DatabricksError::AuthorizationFailed`] or [`DatabricksError::InvalidIssuer`].
    pub fn authorization_response(
        &self,
        callback: &Url,
    ) -> Result<AuthorizationResponse, DatabricksError> {
        if !self.configuration.matches_callback(callback) {
            return Err(DatabricksError::InvalidCallback);
        }
        let items = query::items(callback.query().unwrap_or_default())
            .ok_or(DatabricksError::InvalidCallback)?;
        match query::values(&items, "state").as_slice() {
            [Some(state)] if *state == self.state.expose() => {}
            _ => return Err(DatabricksError::InvalidCallback),
        }
        let codes = query::values(&items, "code");
        let errors = query::values(&items, "error");
        if !errors.is_empty() {
            return match errors.as_slice() {
                [Some("access_denied")] if codes.is_empty() => {
                    Err(DatabricksError::AuthorizationDenied)
                }
                [Some(error)] if codes.is_empty() && !error.is_empty() => {
                    Err(DatabricksError::AuthorizationFailed)
                }
                _ => Err(DatabricksError::InvalidCallback),
            };
        }
        let code = match codes.as_slice() {
            [Some(code)] if !code.is_empty() => SecretString::new(*code),
            _ => return Err(DatabricksError::InvalidCallback),
        };
        let issuer = match query::values(&items, "iss").as_slice() {
            [] => OAuthIssuer::workspace(self.scope.workspace_origin_url())?,
            [Some(raw)] if !raw.is_empty() => OAuthIssuer::parse(raw)?,
            _ => return Err(DatabricksError::InvalidIssuer),
        };
        Ok(AuthorizationResponse { code, issuer })
    }

    /// The authorization-code token request. No client secret; every value is form-encoded.
    #[must_use]
    pub fn token_request(&self, code: &SecretString, issuer: Option<&OAuthIssuer>) -> HttpRequest {
        token_request(
            &self.scope,
            &[
                ("grant_type", "authorization_code"),
                ("redirect_uri", self.configuration.redirect_uri()),
                ("scope", OAUTH_SCOPE),
                ("code_verifier", self.verifier.expose()),
                ("code", code.expose()),
            ],
            issuer,
        )
    }
}

/// A token-endpoint `POST`: `<issuer>/v1/token`, or the legacy `<workspace>/oidc/v1/token` when
/// there is no issuer. The body is `client_id` followed by `fields`.
#[must_use]
pub fn token_request(
    scope: &CredentialScope,
    fields: &[(&str, &str)],
    issuer: Option<&OAuthIssuer>,
) -> HttpRequest {
    let url = issuer.map_or_else(
        || format!("{}/oidc/v1/token", scope.workspace_origin()),
        OAuthIssuer::token_endpoint,
    );
    let mut form = vec![("client_id", scope.client_id())];
    form.extend_from_slice(fields);
    HttpRequest {
        method: "POST".into(),
        url,
        headers: vec![
            HttpHeader::new("Content-Type", "application/x-www-form-urlencoded"),
            HttpHeader::new("Accept", "application/json"),
        ],
        body: Some(pkce::form_body(&form)),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use crate::auth::databricks::test_support::{
        ACCOUNT_ISSUER, REDIRECT, attempt_for, config, config_with, form_fields, url,
    };
    use crate::auth::testing::{FixedEntropy, header};

    fn query_map(raw: &str) -> BTreeMap<String, String> {
        let parsed = Url::parse(raw).unwrap();
        query::items(parsed.query().unwrap())
            .unwrap()
            .into_iter()
            .map(|item| (item.name, item.value.unwrap()))
            .collect()
    }

    fn callback(query: &str) -> Url {
        url(&format!("{REDIRECT}?{query}"))
    }

    /// `DatabricksOAuthAttemptTests::testUsesWorkspaceIssuerAndPublicClientPKCE`.
    #[test]
    fn databricks_authorize_url_uses_workspace_and_pkce() {
        let config = config_with("client+&value");
        let attempt = OAuthAttempt::new(
            &url("https://DBC-123.cloud.databricks.com/omnigent/c/abc?o=123&view=chat#view"),
            &config,
            &FixedEntropy::counting(),
        )
        .unwrap();
        let authorize = attempt.authorization_url();
        let parsed = Url::parse(&authorize).unwrap();
        assert_eq!(parsed.host_str(), Some("dbc-123.cloud.databricks.com"));
        assert_eq!(parsed.path(), "/oidc/v1/authorize");
        let query = query_map(&authorize);
        assert_eq!(query["client_id"], "client+&value");
        assert_eq!(query["redirect_uri"], REDIRECT);
        assert_eq!(query["response_type"], "code");
        assert_eq!(query["scope"], "all-apis offline_access");
        assert_eq!(query["state"], attempt.state().expose());
        assert_eq!(
            query["code_challenge"],
            pkce::code_challenge_s256(attempt.verifier().expose())
        );
        assert_eq!(query["code_challenge_method"], "S256");
        assert!(!query.contains_key("code_verifier"));
        assert_eq!(query["o"], "123");
        assert!(!query.contains_key("view"));
        assert!(!parsed.query().unwrap().contains('+'));
    }

    /// `DatabricksOAuthAttemptTests::testPKCEMatchesRFC7636Vector` (the helper is the shared
    /// `auth::pkce`; this pins the Databricks flow to it).
    #[test]
    fn pkce_s256_matches_rfc7636_vector() {
        assert_eq!(
            pkce::code_challenge_s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }

    /// `DatabricksOAuthAttemptTests::testEachAttemptHasFreshIndependentStateAndVerifier`.
    #[test]
    fn databricks_attempt_state_and_verifier_are_fresh() {
        let entropy = FixedEntropy::counting();
        let first = attempt_for("https://dbc-123.cloud.databricks.com", &entropy);
        let second = attempt_for("https://dbc-123.cloud.databricks.com", &entropy);
        assert_ne!(first.state(), second.state());
        assert_ne!(first.verifier(), second.verifier());
        assert_ne!(first.state(), first.verifier());
        for value in [
            first.state(),
            first.verifier(),
            second.state(),
            second.verifier(),
        ] {
            assert_eq!(value.expose().len(), 43);
            assert!(
                value
                    .expose()
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            );
        }
        let debug = format!("{first:?}");
        assert!(!debug.contains(first.state().expose()));
        assert!(!debug.contains(first.verifier().expose()));
        assert!(matches!(
            OAuthAttempt::new(
                &url("https://dbc-123.cloud.databricks.com"),
                &config(),
                &FixedEntropy::failing()
            ),
            Err(DatabricksError::RandomGenerationFailed(_))
        ));
    }

    /// `DatabricksOAuthAttemptTests::testRejectsNonWorkspaceAndInsecureIssuers`.
    #[test]
    fn databricks_attempt_rejects_non_workspace_issuers() {
        for raw in [
            "http://dbc-123.cloud.databricks.com",
            "https://my-app.databricksapps.com",
            "https://example.com",
            "https://databricks.com.example.org",
            "https://user@dbc-123.cloud.databricks.com",
            "https://dbc-123.cloud.databricks.com:8443",
        ] {
            assert_eq!(
                OAuthAttempt::new(&url(raw), &config(), &FixedEntropy::counting()),
                Err(DatabricksError::InvalidWorkspace),
                "{raw}"
            );
        }
    }

    /// `DatabricksOAuthAttemptTests::testValidatesConfiguredCallbackAndState`.
    #[test]
    fn databricks_callback_validates_redirect_and_state() {
        let attempt = attempt_for(
            "https://dbc-123.cloud.databricks.com",
            &FixedEntropy::counting(),
        );
        let state = attempt.state().expose().to_owned();
        let response = attempt
            .authorization_response(&callback(&format!("state={state}&code=code%2Bvalue")))
            .unwrap();
        assert_eq!(response.code.expose(), "code+value");
        for raw in [
            format!("https://example.org/mobile-redirect?state={state}&code=value"),
            format!("http://login.databricks.com/mobile-redirect?state={state}&code=value"),
            format!("https://login.databricks.com:8443/mobile-redirect?state={state}&code=value"),
            format!("https://user@login.databricks.com/mobile-redirect?state={state}&code=value"),
            format!("https://login.databricks.com/mobile-redirect/extra?state={state}&code=value"),
            "https://login.databricks.com/mobile-redirect?state=wrong&code=value".to_owned(),
            format!(
                "https://login.databricks.com/mobile-redirect?state={state}&code=value#fragment"
            ),
        ] {
            assert_eq!(
                attempt.authorization_response(&url(&raw)),
                Err(DatabricksError::InvalidCallback),
                "{raw}"
            );
        }
    }

    /// `DatabricksOAuthAttemptTests::testRejectsMissingDuplicateAndMixedCallbackParameters`.
    #[test]
    fn databricks_callback_rejects_missing_duplicate_mixed_params() {
        let attempt = attempt_for(
            "https://dbc-123.cloud.databricks.com",
            &FixedEntropy::counting(),
        );
        let state = attempt.state().expose().to_owned();
        for query in [
            "code=value".to_owned(),
            format!("state={state}"),
            format!("state={state}&code="),
            format!("state={state}&state={state}&code=value"),
            format!("state={state}&code=one&code=two"),
            format!("state={state}&code=value&error=access_denied"),
            format!("state={state}&error="),
            format!("state={state}&error=one&error=two"),
            format!("state={state}&code"),
        ] {
            assert_eq!(
                attempt.authorization_response(&callback(&query)),
                Err(DatabricksError::InvalidCallback),
                "{query}"
            );
        }
    }

    /// `DatabricksOAuthAttemptTests::testProviderErrorsAreSanitizedAndStillRequireState`.
    #[test]
    fn databricks_provider_errors_sanitized_and_need_state() {
        let attempt = attempt_for(
            "https://dbc-123.cloud.databricks.com",
            &FixedEntropy::counting(),
        );
        let state = attempt.state().expose().to_owned();
        for (error, expected) in [
            ("access_denied", DatabricksError::AuthorizationDenied),
            ("server_error", DatabricksError::AuthorizationFailed),
        ] {
            let result = attempt.authorization_response(&callback(&format!(
                "state={state}&error={error}&error_description=sensitive-value"
            )));
            assert_eq!(result, Err(expected));
            assert!(!result.unwrap_err().to_string().contains("sensitive-value"));
        }
        assert_eq!(
            attempt.authorization_response(&callback("error=access_denied")),
            Err(DatabricksError::InvalidCallback)
        );
    }

    /// `DatabricksOAuthIssuerTests::testCallbackIssuerIsValidatedAlongsideState`.
    #[test]
    fn databricks_callback_issuer_validated_with_state() {
        let attempt = attempt_for(
            "https://dbc-123.cloud.databricks.com",
            &FixedEntropy::counting(),
        );
        let state = attempt.state().expose().to_owned();
        let with_issuer = |issuer: &str| {
            callback(&format!(
                "code=test-code&state={state}&iss={}",
                pkce::percent_encode(issuer)
            ))
        };
        let response = attempt
            .authorization_response(&with_issuer(ACCOUNT_ISSUER))
            .unwrap();
        assert_eq!(response.code.expose(), "test-code");
        assert_eq!(response.issuer.as_str(), ACCOUNT_ISSUER);
        assert_eq!(
            attempt.scope().workspace_origin(),
            "https://dbc-123.cloud.databricks.com"
        );
        let fallback = attempt
            .authorization_response(&callback(&format!("code=test-code&state={state}")))
            .unwrap();
        assert_eq!(
            fallback.issuer.as_str(),
            "https://dbc-123.cloud.databricks.com/oidc"
        );
        for issuer in [
            "",
            "https://example.com/oidc",
            "http://accounts.cloud.databricks.com/oidc",
        ] {
            assert_eq!(
                attempt.authorization_response(&with_issuer(issuer)),
                Err(DatabricksError::InvalidIssuer),
                "{issuer}"
            );
        }
        let duplicate = url(&format!(
            "{}&iss={ACCOUNT_ISSUER}",
            with_issuer(ACCOUNT_ISSUER)
        ));
        assert_eq!(
            attempt.authorization_response(&duplicate),
            Err(DatabricksError::InvalidIssuer)
        );
        let wrong_state = callback(&format!("code=test-code&iss={ACCOUNT_ISSUER}&state=wrong"));
        assert_eq!(
            attempt.authorization_response(&wrong_state),
            Err(DatabricksError::InvalidCallback)
        );
    }

    /// `DatabricksOAuthAttemptTests::testExchangeFormEncodesOpaqueValuesWithoutSecretsInURL`.
    #[test]
    fn databricks_token_form_percent_encodes_opaque_values() {
        let attempt = OAuthAttempt::new(
            &url("https://adb-123.azuredatabricks.net/omnigent"),
            &config_with("client+&value"),
            &FixedEntropy::counting(),
        )
        .unwrap();
        let request = attempt.token_request(&SecretString::new("code+/=& value"), None);
        assert_eq!(
            request.url,
            "https://adb-123.azuredatabricks.net/oidc/v1/token"
        );
        assert_eq!(request.method, "POST");
        assert_eq!(
            header(&request, "Content-Type"),
            Some("application/x-www-form-urlencoded")
        );
        assert_eq!(header(&request, "Authorization"), None);
        assert_eq!(header(&request, "Cookie"), None);
        let fields = form_fields(&request);
        assert_eq!(fields["code"], "code+/=& value");
        assert_eq!(fields["code_verifier"], attempt.verifier().expose());
        assert_eq!(fields["client_id"], "client+&value");
        assert_eq!(fields["redirect_uri"], REDIRECT);
        assert_eq!(fields["scope"], "all-apis offline_access");
        assert_eq!(fields["grant_type"], "authorization_code");
        assert!(!fields.contains_key("client_secret"));
        assert!(!crate::auth::testing::body_text(&request).contains('+'));
        assert!(!request.url.contains('?'));
    }
}
