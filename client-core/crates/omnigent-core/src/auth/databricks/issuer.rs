//! OAuth issuers and discovery. Port of `web/ios/Omnigent/DatabricksOAuthIssuer.swift`.
//!
//! The issuer (provider authority) is distinct from the page the user entered: an account issuer
//! lives on the accounts host while the page stays on the workspace host.

use std::fmt;

use url::Url;

use super::error::DatabricksError;
use crate::auth::mode::ServerAuthentication;
use crate::http::{HttpHeader, HttpRequest, HttpResponse};

const ACCOUNT_PREFIX: &str = "/oidc/accounts/";

/// A supported Databricks issuer: `https://<workspace host>/oidc` or
/// `https://<workspace host>/oidc/accounts/<account-id>`.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct OAuthIssuer {
    url: Url,
}

impl OAuthIssuer {
    /// Validates an issuer string.
    ///
    /// Only the canonical spelling is accepted (the string must equal its parsed serialization),
    /// so dot segments, an explicit `:443`, or upper-case hosts cannot alias an issuer.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::InvalidIssuer`] for anything but an https Databricks workspace-domain
    /// issuer without userinfo, port, query or fragment, whose path is `/oidc` or
    /// `/oidc/accounts/<[A-Za-z0-9_-]+>`.
    pub fn parse(raw: &str) -> Result<Self, DatabricksError> {
        let url = Url::parse(raw).map_err(|_| DatabricksError::InvalidIssuer)?;
        if url.as_str() != raw {
            return Err(DatabricksError::InvalidIssuer);
        }
        Self::from_url(url)
    }

    /// The workspace issuer `https://<host>/oidc` for a workspace origin.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::InvalidIssuer`] when the origin is not a supported workspace.
    pub fn workspace(workspace_origin: &Url) -> Result<Self, DatabricksError> {
        let mut url = workspace_origin.clone();
        url.set_path("/oidc");
        url.set_query(None);
        url.set_fragment(None);
        Self::from_url(url)
    }

    fn from_url(url: Url) -> Result<Self, DatabricksError> {
        let supported = url.scheme() == "https"
            && ServerAuthentication::for_url(&url) == ServerAuthentication::DatabricksWorkspace
            && url.username().is_empty()
            && url.password().is_none()
            && url.port().is_none()
            && url.query().is_none()
            && url.fragment().is_none()
            && is_supported_path(url.path());
        if supported {
            Ok(Self { url })
        } else {
            Err(DatabricksError::InvalidIssuer)
        }
    }

    /// The issuer URL.
    #[must_use]
    pub const fn url(&self) -> &Url {
        &self.url
    }

    /// The issuer string, exactly as discovery must report it.
    #[must_use]
    pub fn as_str(&self) -> &str {
        self.url.as_str()
    }

    /// Whether this is an account issuer (`/oidc/accounts/...`).
    #[must_use]
    pub fn is_account(&self) -> bool {
        self.url.path().starts_with(ACCOUNT_PREFIX)
    }

    /// `<issuer>/.well-known/openid-configuration`.
    #[must_use]
    pub fn discovery_url(&self) -> String {
        format!("{}/.well-known/openid-configuration", self.url)
    }

    /// `<issuer>/v1/token`.
    #[must_use]
    pub fn token_endpoint(&self) -> String {
        format!("{}/v1/token", self.url)
    }

    /// The discovery request: a credential-free `GET` (hosts must not follow redirects).
    #[must_use]
    pub fn discovery_request(&self) -> HttpRequest {
        HttpRequest {
            method: "GET".into(),
            url: self.discovery_url(),
            headers: vec![HttpHeader::new("Accept", "application/json")],
            body: None,
        }
    }

    /// Checks the discovery response: HTTP 200 whose JSON `issuer` equals this issuer exactly
    /// and whose `token_endpoint` equals [`OAuthIssuer::token_endpoint`].
    ///
    /// # Errors
    ///
    /// [`DatabricksError::InvalidDiscovery`] for any other status or document. The client never
    /// falls back to an origin-only endpoint after this fails.
    pub fn validate_discovery(&self, response: &HttpResponse) -> Result<(), DatabricksError> {
        if response.status != 200 {
            return Err(DatabricksError::InvalidDiscovery);
        }
        self.validate_discovery_document(&response.body)
    }

    /// Checks a discovery document body (see [`OAuthIssuer::validate_discovery`]).
    ///
    /// # Errors
    ///
    /// [`DatabricksError::InvalidDiscovery`].
    pub fn validate_discovery_document(&self, body: &[u8]) -> Result<(), DatabricksError> {
        let document: serde_json::Value =
            serde_json::from_slice(body).map_err(|_| DatabricksError::InvalidDiscovery)?;
        let issuer = document.get("issuer").and_then(serde_json::Value::as_str);
        let token_endpoint = document
            .get("token_endpoint")
            .and_then(serde_json::Value::as_str);
        if issuer == Some(self.as_str()) && token_endpoint == Some(self.token_endpoint().as_str()) {
            Ok(())
        } else {
            Err(DatabricksError::InvalidDiscovery)
        }
    }
}

impl fmt::Debug for OAuthIssuer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("OAuthIssuer")
            .field(&self.url.as_str())
            .finish()
    }
}

fn is_supported_path(path: &str) -> bool {
    if path == "/oidc" {
        return true;
    }
    path.strip_prefix(ACCOUNT_PREFIX).is_some_and(|account| {
        !account.is_empty()
            && account
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::testing::response;

    /// `DatabricksOAuthIssuerTests::testPreservesWorkspaceAndAccountIssuerPaths`.
    #[test]
    fn databricks_issuer_preserves_paths_and_derives_endpoints() {
        for raw in [
            "https://workspace.cloud.databricks.com/oidc",
            "https://accounts.cloud.databricks.com/oidc/accounts/test-account",
            "https://accounts.azuredatabricks.net/oidc/accounts/test-account",
        ] {
            let issuer = OAuthIssuer::parse(raw).unwrap();
            assert_eq!(issuer.as_str(), raw);
            assert_eq!(
                issuer.discovery_url(),
                format!("{raw}/.well-known/openid-configuration")
            );
            assert_eq!(issuer.token_endpoint(), format!("{raw}/v1/token"));
            // The record codec stores the issuer as this string; it must round-trip.
            assert_eq!(OAuthIssuer::parse(issuer.as_str()).unwrap(), issuer);
        }
        let workspace =
            OAuthIssuer::workspace(&Url::parse("https://workspace.cloud.databricks.com").unwrap())
                .unwrap();
        assert_eq!(
            workspace.as_str(),
            "https://workspace.cloud.databricks.com/oidc"
        );
        assert!(!workspace.is_account());
    }

    /// `DatabricksOAuthIssuerTests::testRejectsUnsupportedIssuerAuthoritiesAndPaths`.
    #[test]
    fn databricks_issuer_rejects_unsupported_authorities() {
        for raw in [
            "http://workspace.cloud.databricks.com/oidc",
            "https://example.com/oidc",
            "https://databricks.com.example.org/oidc",
            "https://my-app.databricksapps.com/oidc",
            "https://user@workspace.cloud.databricks.com/oidc",
            "https://workspace.cloud.databricks.com:8443/oidc",
            "https://workspace.cloud.databricks.com/oidc?next=foo",
            "https://workspace.cloud.databricks.com/oidc#fragment",
            "https://workspace.cloud.databricks.com",
            "https://workspace.cloud.databricks.com/other",
            "https://accounts.cloud.databricks.com/oidc/accounts/",
            "https://accounts.cloud.databricks.com/oidc/accounts/a/b",
            "https://accounts.cloud.databricks.com/oidc/accounts/a%2Fb",
            "https://accounts.cloud.databricks.com/oidc/accounts/..",
            // Non-canonical spellings that would otherwise alias a supported issuer.
            "https://accounts.cloud.databricks.com/x/../oidc",
            "https://WORKSPACE.cloud.databricks.com/oidc",
            "",
        ] {
            assert_eq!(
                OAuthIssuer::parse(raw),
                Err(DatabricksError::InvalidIssuer),
                "{raw}"
            );
        }
    }

    /// `DatabricksOAuthIssuerTests::testDiscoveryMustConfirmExactIssuerAndTokenEndpoint`.
    #[test]
    fn databricks_discovery_must_confirm_issuer_and_token_endpoint() {
        let issuer =
            OAuthIssuer::parse("https://accounts.cloud.databricks.com/oidc/accounts/test-account")
                .unwrap();
        let valid = serde_json::json!({
            "issuer": issuer.as_str(),
            "token_endpoint": issuer.token_endpoint(),
        });
        assert_eq!(
            issuer.validate_discovery(&response(200, "application/json", &valid.to_string())),
            Ok(())
        );
        for invalid in [
            serde_json::json!({"issuer": "https://example.com/oidc", "token_endpoint": issuer.token_endpoint()}),
            serde_json::json!({"issuer": issuer.as_str(), "token_endpoint": "https://accounts.cloud.databricks.com/oidc/v1/token"}),
            serde_json::json!({"issuer": issuer.as_str(), "token_endpoint": "https://example.com/token"}),
            serde_json::json!({"issuer": issuer.as_str()}),
        ] {
            assert_eq!(
                issuer.validate_discovery_document(invalid.to_string().as_bytes()),
                Err(DatabricksError::InvalidDiscovery),
                "{invalid}"
            );
        }
        assert_eq!(
            issuer.validate_discovery_document(b"not json"),
            Err(DatabricksError::InvalidDiscovery)
        );
        for status in [302, 500] {
            assert_eq!(
                issuer.validate_discovery(&response(
                    status,
                    "application/json",
                    &valid.to_string()
                )),
                Err(DatabricksError::InvalidDiscovery)
            );
        }
        let request = issuer.discovery_request();
        assert_eq!(request.method, "GET");
        assert_eq!(request.body, None);
        assert!(
            request
                .headers
                .iter()
                .all(|h| !h.name.eq_ignore_ascii_case("authorization"))
        );
    }
}
