//! Host connection policy and server resolution: URL policy, the manifest, `/v1/info`, the
//! authentication mode and the sign-in methods this app can offer for it.

use omnigent_core as core;
use omnigent_core::auth::endpoint::ServerEndpoint;
use omnigent_core::auth::mode::{self, AuthenticationMode};
use omnigent_core::http::HttpTransport as _;
use omnigent_core::server_url;
use omnigent_protocol::manifest::ManifestAuth;
use url::Url;

use crate::errors::CoreError;
use crate::events::SignInMethod;
use crate::runtime::CoreTransport;

/// Which server URLs a build accepts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum UrlPolicy {
    /// Debug builds: `http://` to any host is allowed, and schemeless loopback input means http.
    Development,
    /// Release builds: `https://` only, except loopback servers (`localhost`, `127.0.0.1`,
    /// `[::1]`).
    Release,
}

/// How this app receives the native OIDC callback.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum OidcRedirect {
    /// A private-use scheme registered by the app, for example `ai.omnigent.ios:/oauth/callback`.
    /// Used only when the server's manifest lists it.
    PrivateScheme {
        /// The redirect URI.
        redirect_uri: String,
    },
    /// An RFC 8252 loopback listener the host starts per sign-in (macOS), at `path` on an
    /// ephemeral `127.0.0.1` port. Servers accept any loopback redirect.
    Loopback {
        /// The callback path, for example `/oauth/callback`.
        path: String,
    },
    /// No native redirect: only the browser-ticket fallback.
    None,
}

/// This build's public Databricks OAuth client (there is never a client secret).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DatabricksOAuthSettings {
    /// The OAuth client id registered for the app.
    pub client_id: String,
    /// The exact HTTPS redirect registered with that client, for example
    /// `https://login.databricks.com/mobile-redirect`.
    pub redirect_url: String,
}

/// What the host build allows and supports.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostConfig {
    /// Which server URLs are accepted.
    pub url_policy: UrlPolicy,
    /// How native OIDC sign-in returns to the app.
    pub oidc_redirect: OidcRedirect,
    /// The Databricks OAuth client, for servers in a Databricks workspace. Without it those
    /// servers offer no sign-in method.
    #[uniffi(default)]
    pub databricks: Option<DatabricksOAuthSettings>,
}

const LOOPBACK_HOSTS: [&str; 4] = ["localhost", "127.0.0.1", "[::1]", "::1"];

/// Normalizes a typed server URL under `policy`.
///
/// # Errors
///
/// [`CoreError::InvalidUrl`] with a displayable reason.
pub(crate) fn normalize(raw: &str, policy: UrlPolicy) -> Result<Url, CoreError> {
    let invalid = |message: String| CoreError::InvalidUrl { message };
    let url = server_url::normalize(raw, true).map_err(|error| invalid(error.to_string()))?;
    let loopback = url
        .host_str()
        .is_some_and(|host| LOOPBACK_HOSTS.contains(&host));
    if policy == UrlPolicy::Release && url.scheme() == "http" && !loopback {
        return Err(invalid(
            server_url::ServerUrlError::InsecureHttpNotAllowed.to_string(),
        ));
    }
    Ok(url)
}

/// Normalizes `server_url` the way connecting does, without any request: the canonical text, or
/// why it is rejected.
///
/// # Errors
///
/// [`CoreError::InvalidUrl`].
#[uniffi::export]
pub fn normalize_server_url(server_url: String, policy: UrlPolicy) -> Result<String, CoreError> {
    normalize(&server_url, policy).map(|url| server_url::display(&url))
}

/// A server whose manifest and `/v1/info` were read.
#[derive(Debug, Clone)]
pub(crate) struct Resolved {
    pub(crate) discovery: core::ServerDiscovery,
    pub(crate) endpoint: ServerEndpoint,
    pub(crate) mode: AuthenticationMode,
    pub(crate) manifest_auth: Option<ManifestAuth>,
    /// For a server inside a Databricks workspace: the workspace URL (origin plus `?o=`) its
    /// credential is scoped to.
    pub(crate) databricks_workspace: Option<Url>,
    /// Accounts mode with no administrator yet (`/v1/info` `needs_setup`).
    pub(crate) needs_setup: bool,
}

/// A discovery for a server inside a Databricks workspace. Its routes (the manifest and
/// `/v1/info` included) answer only signed-in requests, so nothing is read before sign-in; the
/// typed workspace or UI URL becomes the API root.
fn databricks_discovery(url: &Url) -> core::ServerDiscovery {
    core::ServerDiscovery {
        base_url: server_url::display(&server_url::databricks_api_root(url)),
        server_name: None,
        server_version: None,
        min_client_version: None,
        auth_mode: None,
        native_redirect_uris: Vec::new(),
    }
}

fn invalid_origin(error: url::ParseError) -> CoreError {
    CoreError::InvalidUrl {
        message: error.to_string(),
    }
}

/// The workspace URL a Databricks credential is scoped to: the endpoint's origin and its `o=`.
fn databricks_workspace(endpoint: &ServerEndpoint) -> Result<Url, CoreError> {
    let mut workspace = Url::parse(endpoint.origin()).map_err(invalid_origin)?;
    if let Some(org) = endpoint.databricks_org_id() {
        workspace.set_query(Some(&format!("o={org}")));
    }
    Ok(workspace)
}

/// The manifest only.
pub(crate) async fn discover(
    transport: &CoreTransport,
    raw: &str,
    policy: UrlPolicy,
) -> Result<(Url, core::ServerDiscovery), CoreError> {
    let url = normalize(raw, policy)?;
    if server_url::is_databricks_workspace(&url) {
        return Ok((url.clone(), databricks_discovery(&url)));
    }
    let response = transport
        .send(core::manifest_request(&url))
        .await
        .map_err(CoreError::from)?;
    let discovery = core::discovery_from_response(&url, &response).map_err(CoreError::from)?;
    Ok((url, discovery))
}

/// The manifest, then `/v1/info`, then the mode.
pub(crate) async fn resolve(
    transport: &CoreTransport,
    raw: &str,
    policy: UrlPolicy,
) -> Result<Resolved, CoreError> {
    let (url, discovery) = discover(transport, raw, policy).await?;
    let endpoint = ServerEndpoint::new(&discovery.base_url).map_err(CoreError::from)?;
    if server_url::is_databricks_workspace(&url) {
        return Ok(Resolved {
            databricks_workspace: Some(databricks_workspace(&endpoint)?),
            discovery,
            endpoint,
            mode: AuthenticationMode::Proxy,
            manifest_auth: None,
            needs_setup: false,
        });
    }
    let manifest_auth = discovery.auth_mode.clone().map(|mode| ManifestAuth {
        mode,
        session_cookie: None,
        native_redirect_uris: discovery.native_redirect_uris.clone(),
    });
    let response = transport
        .send(mode::info_request(&endpoint).map_err(CoreError::from)?)
        .await
        .map_err(CoreError::from)?;
    let info = mode::discovery_from_info_response(&endpoint, manifest_auth.as_ref(), &response)
        .map_err(CoreError::from)?;
    Ok(Resolved {
        discovery,
        endpoint,
        mode: info.mode,
        manifest_auth,
        databricks_workspace: None,
        needs_setup: info.needs_setup,
    })
}

/// The sign-in methods to offer, best first.
pub(crate) fn sign_in_methods(resolved: &Resolved, config: &HostConfig) -> Vec<SignInMethod> {
    let redirect = &config.oidc_redirect;
    if let Some(workspace) = &resolved.databricks_workspace {
        return config
            .databricks
            .as_ref()
            .and_then(|settings| {
                core::auth::databricks::OAuthConfiguration::new(
                    &settings.client_id,
                    &settings.redirect_url,
                )
                .ok()
            })
            .map(|configuration| SignInMethod::DatabricksWorkspace {
                workspace_host: workspace.host_str().unwrap_or_default().to_owned(),
                loopback: configuration.is_loopback(),
                callback_host: configuration.callback_host().to_owned(),
                callback_path: configuration.callback_path().to_owned(),
            })
            .into_iter()
            .collect();
    }
    match &resolved.mode {
        AuthenticationMode::Accounts => vec![SignInMethod::Password],
        AuthenticationMode::Oidc => {
            let mut methods = Vec::new();
            let accepts = |uri: &str| {
                resolved
                    .manifest_auth
                    .as_ref()
                    .is_some_and(|auth| auth.accepts_native_redirect(uri))
            };
            match redirect {
                OidcRedirect::PrivateScheme { redirect_uri } if accepts(redirect_uri) => {
                    methods.push(SignInMethod::Browser {
                        redirect_uri: redirect_uri.clone(),
                    });
                }
                OidcRedirect::Loopback { path } => {
                    if resolved.manifest_auth.is_some() {
                        methods.push(SignInMethod::LoopbackBrowser { path: path.clone() });
                    }
                }
                OidcRedirect::PrivateScheme { .. } | OidcRedirect::None => {}
            }
            methods.push(SignInMethod::BrowserTicket);
            methods
        }
        AuthenticationMode::LocalSingleUser
        | AuthenticationMode::Proxy
        | AuthenticationMode::Unsupported { .. } => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_builds_require_https_except_loopback() {
        assert!(normalize("http://omnigent.example.com", UrlPolicy::Release).is_err());
        assert_eq!(
            normalize_server_url("127.0.0.1:6767".into(), UrlPolicy::Release).unwrap(),
            "http://127.0.0.1:6767"
        );
        assert_eq!(
            normalize_server_url("http://localhost:6767".into(), UrlPolicy::Release).unwrap(),
            "http://localhost:6767"
        );
        assert_eq!(
            normalize_server_url("omnigent.example.com".into(), UrlPolicy::Release).unwrap(),
            "https://omnigent.example.com"
        );
    }

    #[test]
    fn development_builds_allow_http_anywhere() {
        assert_eq!(
            normalize_server_url("http://devbox.lan:8000".into(), UrlPolicy::Development).unwrap(),
            "http://devbox.lan:8000"
        );
        assert!(matches!(
            normalize("ftp://x", UrlPolicy::Development),
            Err(CoreError::InvalidUrl { .. })
        ));
    }
}

#[cfg(test)]
mod databricks_tests {
    use super::*;

    #[test]
    fn databricks_workspaces_skip_unauthenticated_discovery() {
        let url = normalize(
            "https://dbc-1.cloud.databricks.com/?o=42",
            UrlPolicy::Release,
        )
        .unwrap();
        let discovery = databricks_discovery(&url);
        assert_eq!(
            discovery.base_url,
            "https://dbc-1.cloud.databricks.com/api/2.0/omnigent?o=42"
        );
        let endpoint = ServerEndpoint::new(&discovery.base_url).unwrap();
        assert_eq!(endpoint.databricks_org_id(), Some("42"));
        assert_eq!(
            databricks_workspace(&endpoint).unwrap().as_str(),
            "https://dbc-1.cloud.databricks.com/?o=42"
        );
    }

    #[test]
    fn an_origin_that_does_not_parse_is_an_invalid_url() {
        let error = invalid_origin(url::ParseError::EmptyHost);
        assert_eq!(
            error,
            CoreError::InvalidUrl {
                message: url::ParseError::EmptyHost.to_string()
            }
        );
    }
}
