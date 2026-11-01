//! Build-time OAuth client configuration. Port of
//! `web/ios/Omnigent/DatabricksOAuthConfiguration.swift`.
//!
//! The client id and redirect URL are public build settings (the host reads them from its bundle);
//! there is never a client secret.

use url::Url;

use super::error::DatabricksError;

/// A validated public OAuth client: its id and its HTTPS redirect (callback) URL.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct OAuthConfiguration {
    client_id: String,
    /// The redirect URL exactly as configured; sent verbatim as `redirect_uri`.
    redirect_uri: String,
    redirect: Url,
}

impl OAuthConfiguration {
    /// Validates the build settings.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::InvalidClientId`] for an empty, blank, whitespace/control-containing,
    /// or unexpanded (`$(...)`) client id; [`DatabricksError::InvalidRedirectUrl`] unless the
    /// redirect is `https` with a host, a path, no userinfo, no port other than 443, no query and
    /// no fragment.
    pub fn new(client_id: &str, redirect_url: &str) -> Result<Self, DatabricksError> {
        if client_id.is_empty() || client_id.contains("$(") || has_space_or_control(client_id) {
            return Err(DatabricksError::InvalidClientId);
        }
        let redirect = parse_redirect(redirect_url).ok_or(DatabricksError::InvalidRedirectUrl)?;
        Ok(Self {
            client_id: client_id.to_owned(),
            redirect_uri: redirect_url.to_owned(),
            redirect,
        })
    }

    /// The public client id.
    #[must_use]
    pub fn client_id(&self) -> &str {
        &self.client_id
    }

    /// The redirect URL as configured, for `redirect_uri` parameters.
    #[must_use]
    pub fn redirect_uri(&self) -> &str {
        &self.redirect_uri
    }

    /// The parsed redirect URL.
    #[must_use]
    pub const fn redirect_url(&self) -> &Url {
        &self.redirect
    }

    /// The callback host the sign-in browser should intercept (`ASWebAuthenticationSession`'s
    /// `.https(host:path:)`).
    #[must_use]
    pub fn callback_host(&self) -> &str {
        self.redirect.host_str().unwrap_or_default()
    }

    /// The callback path the sign-in browser should intercept.
    #[must_use]
    pub fn callback_path(&self) -> &str {
        self.redirect.path()
    }

    /// Whether `url` is this client's callback: `https`, same host (case-insensitive), same
    /// effective port, identical path, and no userinfo or fragment. The query is not compared;
    /// it carries the response.
    #[must_use]
    pub fn matches_callback(&self, url: &Url) -> bool {
        url.scheme() == "https"
            && url
                .host_str()
                .zip(self.redirect.host_str())
                .is_some_and(|(actual, expected)| actual.eq_ignore_ascii_case(expected))
            && url.port_or_known_default() == self.redirect.port_or_known_default()
            && url.path() == self.redirect.path()
            && url.username().is_empty()
            && url.password().is_none()
            && url.fragment().is_none()
    }

    /// Whether `url` is the redirect page itself (same origin and path), which must never be
    /// treated as a workspace page.
    #[must_use]
    pub fn is_redirect_page(&self, url: &Url) -> bool {
        url.origin() == self.redirect.origin() && url.path() == self.redirect.path()
    }
}

fn has_space_or_control(value: &str) -> bool {
    value.chars().any(|c| c.is_whitespace() || c.is_control())
}

fn parse_redirect(raw: &str) -> Option<Url> {
    if raw.contains("$(") || has_space_or_control(raw) {
        return None;
    }
    // `Url` gives every https URL a path of at least "/", so require one in the input itself:
    // `https://example.com` has no path and is ambiguous as a callback.
    let (scheme, rest) = raw.split_once("://")?;
    if !scheme.eq_ignore_ascii_case("https") || !rest.contains('/') {
        return None;
    }
    let url = Url::parse(raw).ok()?;
    let valid = url.scheme() == "https"
        && url.host_str().is_some_and(|host| !host.is_empty())
        && url.username().is_empty()
        && url.password().is_none()
        && url.port().is_none_or(|port| port == 443)
        && url.query().is_none()
        && url.fragment().is_none();
    valid.then_some(url)
}

#[cfg(test)]
mod tests {
    use super::*;

    const REDIRECT: &str = "https://login.databricks.com/mobile-redirect";

    /// `DatabricksOAuthTests::testAcceptsBuildConfigurationOverrides`.
    #[test]
    fn databricks_oauth_config_accepts_overrides() {
        let config =
            OAuthConfiguration::new("custom-client", "https://auth.example.com/mobile/callback")
                .unwrap();
        assert_eq!(config.client_id(), "custom-client");
        assert_eq!(
            config.redirect_uri(),
            "https://auth.example.com/mobile/callback"
        );
        assert_eq!(config.callback_host(), "auth.example.com");
        assert_eq!(config.callback_path(), "/mobile/callback");
    }

    /// `DatabricksOAuthTests::testRejectsMissingOrUnexpandedClientID`.
    #[test]
    fn databricks_oauth_config_rejects_bad_client_id() {
        for client_id in ["", " ", "client\nvalue", "$(DATABRICKS_OAUTH_CLIENT_ID)"] {
            assert_eq!(
                OAuthConfiguration::new(client_id, REDIRECT),
                Err(DatabricksError::InvalidClientId),
                "{client_id:?}"
            );
        }
    }

    /// `DatabricksOAuthTests::testRequiresUnambiguousHTTPSCallback`.
    #[test]
    fn databricks_oauth_config_requires_unambiguous_https_redirect() {
        for redirect in [
            "",
            "$(DATABRICKS_OAUTH_REDIRECT_URL)",
            "http://example.com/callback",
            "omnigent://auth/callback",
            "https://example.com",
            "https://user@example.com/callback",
            "https://example.com:8443/callback",
            "https://example.com/callback?next=foo",
            "https://example.com/callback#fragment",
            "https://example.com/call back",
        ] {
            assert_eq!(
                OAuthConfiguration::new("client", redirect),
                Err(DatabricksError::InvalidRedirectUrl),
                "{redirect:?}"
            );
        }
        assert!(OAuthConfiguration::new("client", "https://example.com:443/callback").is_ok());
    }

    #[test]
    fn callback_matching_ignores_query_and_host_case() {
        let config = OAuthConfiguration::new("client", REDIRECT).unwrap();
        let matching =
            Url::parse("https://LOGIN.databricks.com:443/mobile-redirect?code=1").unwrap();
        assert!(config.matches_callback(&matching));
        let other = Url::parse("https://other.example.com/mobile-redirect").unwrap();
        assert!(!config.matches_callback(&other));
    }
}
