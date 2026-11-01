//! Which sign-in a server needs: host classification, `/v1/info` discovery, and the manifest.

use omnigent_protocol::{AuthMode, ManifestAuth};
use serde_json::Value;
use url::Url;

use super::endpoint::ServerEndpoint;
use super::errors::HostedAuthError;
use crate::http::{HttpRequest, HttpResponse};

/// Host-based classification, independent of mount discovery. Port of web/ios
/// `ServerAuthentication`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ServerAuthentication {
    /// A Databricks workspace (`databricks.com`, `azuredatabricks.net`): native Databricks OAuth.
    DatabricksWorkspace,
    /// A Databricks App (`databricksapps.com`): keeps the platform's inline SSO.
    DatabricksApp,
    /// Anything else: the server's own sign-in.
    Oidc,
}

const WORKSPACE_DOMAINS: [&str; 2] = ["databricks.com", "azuredatabricks.net"];
const APPS_DOMAIN: &str = "databricksapps.com";

impl ServerAuthentication {
    /// Classifies a host name; `None` or empty is [`ServerAuthentication::Oidc`].
    #[must_use]
    pub fn for_host(host: Option<&str>) -> Self {
        let Some(host) = host
            .map(str::to_ascii_lowercase)
            .filter(|host| !host.is_empty())
        else {
            return Self::Oidc;
        };
        if WORKSPACE_DOMAINS
            .iter()
            .any(|domain| matches_domain(&host, domain))
        {
            Self::DatabricksWorkspace
        } else if matches_domain(&host, APPS_DOMAIN) {
            Self::DatabricksApp
        } else {
            Self::Oidc
        }
    }

    /// Classifies a URL by its host alone.
    #[must_use]
    pub fn for_url(url: &Url) -> Self {
        Self::for_host(url.host_str())
    }

    /// Classifies an origin or URL string; unparseable input is [`ServerAuthentication::Oidc`].
    #[must_use]
    pub fn for_origin(origin: Option<&str>) -> Self {
        origin
            .and_then(|origin| Url::parse(origin).ok())
            .map_or(Self::Oidc, |url| Self::for_url(&url))
    }

    /// Only Databricks Apps keep their sign-in inside the web view.
    #[must_use]
    pub const fn uses_in_web_view_auth(self) -> bool {
        matches!(self, Self::DatabricksApp)
    }
}

fn matches_domain(host: &str, domain: &str) -> bool {
    host == domain
        || host
            .strip_suffix(domain)
            .is_some_and(|prefix| prefix.ends_with('.'))
}

/// The auth-relevant part of `GET /v1/info` (`ServerInfoResponse` in `omnigent/server/app.py`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerInfo {
    /// The explicit single-user local runtime.
    pub single_user: bool,
    /// Built-in username/password accounts.
    pub accounts_enabled: bool,
    /// `"/auth/login"` for OIDC, `"/login"` for accounts, `None` for header mode.
    pub login_url: Option<String>,
    /// Accounts mode with no admin yet.
    pub needs_setup: bool,
}

impl ServerInfo {
    /// Decodes a `/v1/info` body. `single_user` and `accounts_enabled` are required booleans.
    ///
    /// # Errors
    ///
    /// [`HostedAuthError::MalformedResponse`] when the body is not such an object.
    pub fn from_json(body: &[u8]) -> Result<Self, HostedAuthError> {
        let value: Value = serde_json::from_slice(body).map_err(|error| malformed(&error))?;
        let object = value
            .as_object()
            .ok_or_else(|| malformed(&"/v1/info is not an object"))?;
        let flag = |name: &str| {
            object
                .get(name)
                .and_then(Value::as_bool)
                .ok_or_else(|| malformed(&format!("/v1/info.{name} is not a boolean")))
        };
        let login_url = match object.get("login_url") {
            None | Some(Value::Null) => None,
            Some(Value::String(url)) => Some(url.clone()),
            Some(_) => return Err(malformed(&"/v1/info.login_url is not a string")),
        };
        let needs_setup = match object.get("needs_setup") {
            None | Some(Value::Null) => false,
            Some(Value::Bool(value)) => *value,
            Some(_) => return Err(malformed(&"/v1/info.needs_setup is not a boolean")),
        };
        Ok(Self {
            single_user: flag("single_user")?,
            accounts_enabled: flag("accounts_enabled")?,
            login_url,
            needs_setup,
        })
    }
}

fn malformed(detail: &impl ToString) -> HostedAuthError {
    HostedAuthError::MalformedResponse {
        detail: detail.to_string(),
    }
}

/// How a native client signs in to a server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthenticationMode {
    /// An explicit single-user server on a loopback `http://` root: no credentials.
    ///
    /// Only the server says so (`/v1/info.single_user` with no sign-in of its own). Loopback
    /// alone never implies it: an accounts or OIDC server on `127.0.0.1` signs in normally.
    LocalSingleUser,
    /// Username/password accounts.
    Accounts,
    /// The server's OIDC sign-in in the system browser.
    Oidc,
    /// Identity comes from in front of the server (a proxy, Databricks, an embedding app); the
    /// client brings its own bearer.
    Proxy,
    /// A manifest mode newer than this client. Never mapped onto a known mode.
    Unsupported {
        /// The mode string as sent.
        mode: String,
    },
}

/// The result of discovery.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthenticationDiscovery {
    /// How to sign in.
    pub mode: AuthenticationMode,
    /// The canonical API root.
    pub base_url: String,
    /// Accounts mode with no admin yet: the user must run first-time setup in the web app.
    pub needs_setup: bool,
}

/// `GET /v1/info` for `endpoint`, unauthenticated.
///
/// # Errors
///
/// See [`ServerEndpoint::request`].
pub fn info_request(endpoint: &ServerEndpoint) -> Result<HttpRequest, HostedAuthError> {
    endpoint.request("/v1/info", &[], None)
}

/// `NativeLab`'s mode derivation from `/v1/info` alone, for servers without a manifest `auth`
/// block. Databricks-org endpoints are always [`AuthenticationMode::Proxy`].
#[must_use]
pub fn mode_from_info(endpoint: &ServerEndpoint, info: &ServerInfo) -> AuthenticationMode {
    if endpoint.databricks_org_id().is_some() {
        AuthenticationMode::Proxy
    } else if info.accounts_enabled {
        AuthenticationMode::Accounts
    } else if info.login_url.as_deref() == Some("/auth/login") {
        AuthenticationMode::Oidc
    } else if is_local_single_user(endpoint, info) {
        AuthenticationMode::LocalSingleUser
    } else {
        AuthenticationMode::Proxy
    }
}

/// Whether `info` describes the explicit single-user runtime on a loopback `http://` root: the
/// server reports `single_user` and has no sign-in of its own (no accounts, no login URL).
///
/// This is the only single-user rule. Host locality is necessary (the server's marker means
/// "this machine's own server") but never sufficient.
#[must_use]
pub fn is_local_single_user(endpoint: &ServerEndpoint, info: &ServerInfo) -> bool {
    endpoint.is_loopback_http()
        && endpoint.databricks_org_id().is_none()
        && info.is_pure_single_user()
}

impl ServerInfo {
    /// `single_user` with no accounts and no login URL: nothing to sign in to.
    #[must_use]
    pub const fn is_pure_single_user(&self) -> bool {
        self.single_user && !self.accounts_enabled && self.login_url.is_none()
    }
}

/// The mode from the manifest's `auth` block when the server sent one, otherwise from
/// `/v1/info`.
///
/// The server derives both from one helper, so the manifest wins; `/v1/info` still decides
/// single-user. The local runtime reports `none` or `header` there (identity comes from the
/// single-user marker, not a proxy), so either is [`AuthenticationMode::LocalSingleUser`] when
/// [`is_local_single_user`] holds. `accounts` and `oidc` sign in wherever the server runs.
#[must_use]
pub fn resolve_mode(
    endpoint: &ServerEndpoint,
    manifest_auth: Option<&ManifestAuth>,
    info: &ServerInfo,
) -> AuthenticationMode {
    if endpoint.databricks_org_id().is_some() {
        return AuthenticationMode::Proxy;
    }
    let Some(auth) = manifest_auth else {
        return mode_from_info(endpoint, info);
    };
    match &auth.mode {
        AuthMode::Oidc => AuthenticationMode::Oidc,
        AuthMode::Accounts => AuthenticationMode::Accounts,
        AuthMode::None | AuthMode::Header if is_local_single_user(endpoint, info) => {
            AuthenticationMode::LocalSingleUser
        }
        AuthMode::Header | AuthMode::Custom | AuthMode::None => AuthenticationMode::Proxy,
        AuthMode::Unknown { value } => AuthenticationMode::Unsupported {
            mode: value.clone(),
        },
    }
}

/// Maps the `/v1/info` response into a discovery result.
///
/// # Errors
///
/// The status checks of [`check_json_response`], then [`ServerInfo::from_json`].
pub fn discovery_from_info_response(
    endpoint: &ServerEndpoint,
    manifest_auth: Option<&ManifestAuth>,
    response: &HttpResponse,
) -> Result<AuthenticationDiscovery, HostedAuthError> {
    check_json_response(response, false)?;
    let info = ServerInfo::from_json(&response.body)?;
    Ok(AuthenticationDiscovery {
        mode: resolve_mode(endpoint, manifest_auth, &info),
        base_url: endpoint.base_url().to_owned(),
        needs_setup: info.needs_setup,
    })
}

/// `NativeLab`'s response policy for auth endpoints: 200 (and 202 when `allow_pending`) with a JSON
/// body; a 3xx is never followed; 401 and 403 are typed.
///
/// # Errors
///
/// [`HostedAuthError::RedirectNotAllowed`], [`HostedAuthError::Unauthorized`],
/// [`HostedAuthError::Forbidden`], [`HostedAuthError::HttpStatus`], or
/// [`HostedAuthError::MalformedResponse`] for a non-JSON body.
pub fn check_json_response(
    response: &HttpResponse,
    allow_pending: bool,
) -> Result<(), HostedAuthError> {
    match response.status {
        200 => {}
        202 if allow_pending => {}
        300..=399 => return Err(HostedAuthError::RedirectNotAllowed),
        401 => {
            return Err(HostedAuthError::Unauthorized {
                reason: error_text(&response.body),
            });
        }
        403 => return Err(HostedAuthError::Forbidden),
        status => return Err(HostedAuthError::HttpStatus { status }),
    }
    let content_type = response
        .header("Content-Type")
        .unwrap_or_default()
        .to_ascii_lowercase();
    let mime = content_type.split(';').next().unwrap_or_default().trim();
    if mime != "application/json" {
        return Err(malformed(&format!(
            "expected application/json, got {mime:?}"
        )));
    }
    Ok(())
}

/// The `error` string of a JSON error body, if any.
#[must_use]
pub fn error_text(body: &[u8]) -> Option<String> {
    serde_json::from_slice::<Value>(body)
        .ok()?
        .get("error")?
        .as_str()
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::testing::response;

    #[test]
    fn auth_classifies_workspace_hosts() {
        for origin in [
            "https://databricks.com",
            "https://dbc-123.cloud.databricks.com",
            "https://azuredatabricks.net",
            "https://adb-123.azuredatabricks.net",
            "https://DBC-123.CLOUD.DATABRICKS.COM",
            "https://ADB-123.AZUREDATABRICKS.NET",
        ] {
            assert_eq!(
                ServerAuthentication::for_origin(Some(origin)),
                ServerAuthentication::DatabricksWorkspace,
                "{origin}"
            );
        }
    }

    #[test]
    fn auth_classifies_apps_separately() {
        for origin in [
            "https://databricksapps.com",
            "https://my-app.aws.databricksapps.com",
            "https://MY-APP.AZURE.DATABRICKSAPPS.COM",
        ] {
            assert_eq!(
                ServerAuthentication::for_origin(Some(origin)),
                ServerAuthentication::DatabricksApp,
                "{origin}"
            );
        }
    }

    #[test]
    fn auth_other_and_lookalike_hosts_use_oidc() {
        for origin in [
            "https://example.com",
            "https://localhost:6767",
            "https://notdatabricks.com",
            "https://notazuredatabricks.net",
            "https://notdatabricksapps.com",
            "https://databricks.com.example.org",
            "https://azuredatabricks.net.example.org",
            "https://databricksapps.com.example.org",
            "https://databricks.com@example.org",
            "https://example.org/databricks.com",
            "not a URL",
            "",
        ] {
            assert_eq!(
                ServerAuthentication::for_origin(Some(origin)),
                ServerAuthentication::Oidc,
                "{origin}"
            );
        }
        assert_eq!(
            ServerAuthentication::for_origin(None),
            ServerAuthentication::Oidc
        );
        assert_eq!(
            ServerAuthentication::for_host(None),
            ServerAuthentication::Oidc
        );
        assert_eq!(
            ServerAuthentication::for_host(Some("")),
            ServerAuthentication::Oidc
        );
    }

    #[test]
    fn auth_classification_depends_only_on_host() {
        for origin in [
            "http://dbc-123.cloud.databricks.com",
            "https://dbc-123.cloud.databricks.com:8443/omnigent?o=123#conversation",
        ] {
            assert_eq!(
                ServerAuthentication::for_origin(Some(origin)),
                ServerAuthentication::DatabricksWorkspace
            );
        }
        assert_eq!(
            ServerAuthentication::for_origin(Some("https://my-app.databricksapps.com:8443/c/abc")),
            ServerAuthentication::DatabricksApp
        );
    }

    #[test]
    fn auth_host_and_origin_classification_agree() {
        for host in [
            "databricks.com",
            "DBC-123.CLOUD.DATABRICKS.COM",
            "adb-123.azuredatabricks.net",
            "databricksapps.com",
            "MY-APP.AWS.DATABRICKSAPPS.COM",
            "example.org",
            "notdatabricks.com",
            "azuredatabricks.net.example.org",
            "databricksapps.com.example.org",
        ] {
            assert_eq!(
                ServerAuthentication::for_host(Some(host)),
                ServerAuthentication::for_origin(Some(&format!("https://{host}"))),
                "{host}"
            );
        }
    }

    #[test]
    fn auth_only_apps_uses_inline_webview() {
        assert!(!ServerAuthentication::DatabricksWorkspace.uses_in_web_view_auth());
        assert!(ServerAuthentication::DatabricksApp.uses_in_web_view_auth());
        assert!(!ServerAuthentication::Oidc.uses_in_web_view_auth());
    }

    fn endpoint(raw: &str) -> ServerEndpoint {
        ServerEndpoint::new(raw).unwrap()
    }

    fn info(json: &str) -> ServerInfo {
        ServerInfo::from_json(json.as_bytes()).unwrap()
    }

    #[test]
    fn mode_from_info_follows_native_lab_rules() {
        let hosted = endpoint("https://h.example.com/api");
        let local = endpoint("http://127.0.0.1:6767");
        let org = endpoint("https://acme.cloud.databricks.com/api?o=1");
        let accounts =
            info(r#"{"single_user":false,"accounts_enabled":true,"login_url":"/login"}"#);
        let oidc =
            info(r#"{"single_user":false,"accounts_enabled":false,"login_url":"/auth/login"}"#);
        let single = info(r#"{"single_user":true,"accounts_enabled":false}"#);
        let header = info(r#"{"single_user":false,"accounts_enabled":false,"login_url":null}"#);
        assert_eq!(
            mode_from_info(&hosted, &accounts),
            AuthenticationMode::Accounts
        );
        assert_eq!(mode_from_info(&hosted, &oidc), AuthenticationMode::Oidc);
        assert_eq!(mode_from_info(&org, &oidc), AuthenticationMode::Proxy);
        assert_eq!(
            mode_from_info(&local, &single),
            AuthenticationMode::LocalSingleUser
        );
        assert_eq!(mode_from_info(&hosted, &single), AuthenticationMode::Proxy);
        assert_eq!(mode_from_info(&hosted, &header), AuthenticationMode::Proxy);
    }

    #[test]
    fn manifest_mode_wins_and_unknown_modes_stay_unsupported() {
        let hosted = endpoint("https://h.example.com/api");
        let local = endpoint("http://127.0.0.1:6767");
        let single = info(r#"{"single_user":true,"accounts_enabled":false}"#);
        let auth = |mode: AuthMode| ManifestAuth {
            mode,
            session_cookie: None,
            native_redirect_uris: vec![],
        };
        assert_eq!(
            resolve_mode(&hosted, Some(&auth(AuthMode::Oidc)), &single),
            AuthenticationMode::Oidc
        );
        assert_eq!(
            resolve_mode(&local, Some(&auth(AuthMode::None)), &single),
            AuthenticationMode::LocalSingleUser
        );
        assert_eq!(
            resolve_mode(&hosted, Some(&auth(AuthMode::None)), &single),
            AuthenticationMode::Proxy
        );
        assert_eq!(
            resolve_mode(&hosted, Some(&auth(AuthMode::Header)), &single),
            AuthenticationMode::Proxy
        );
        assert_eq!(
            resolve_mode(
                &hosted,
                Some(&auth(AuthMode::Unknown {
                    value: "saml".into()
                })),
                &single
            ),
            AuthenticationMode::Unsupported {
                mode: "saml".into()
            }
        );
        assert_eq!(
            resolve_mode(&hosted, None, &single),
            mode_from_info(&hosted, &single)
        );
    }

    #[test]
    fn info_decoding_requires_the_flags() {
        assert!(matches!(
            ServerInfo::from_json(b"{}"),
            Err(HostedAuthError::MalformedResponse { .. })
        ));
        assert!(matches!(
            ServerInfo::from_json(br#"{"single_user":"yes","accounts_enabled":false}"#),
            Err(HostedAuthError::MalformedResponse { .. })
        ));
        assert_eq!(
            info(r#"{"single_user":false,"accounts_enabled":true,"needs_setup":true,"x":1}"#),
            ServerInfo {
                single_user: false,
                accounts_enabled: true,
                login_url: None,
                needs_setup: true
            }
        );
    }

    #[test]
    fn json_response_policy() {
        let ok = response(200, "application/json; charset=utf-8", "{}");
        assert_eq!(check_json_response(&ok, false), Ok(()));
        assert_eq!(
            check_json_response(&response(202, "application/json", "{}"), false),
            Err(HostedAuthError::HttpStatus { status: 202 })
        );
        assert_eq!(
            check_json_response(&response(202, "application/json", "{}"), true),
            Ok(())
        );
        assert_eq!(
            check_json_response(&response(302, "text/html", ""), false),
            Err(HostedAuthError::RedirectNotAllowed)
        );
        assert_eq!(
            check_json_response(
                &response(401, "application/json", r#"{"error":"nope"}"#),
                false
            ),
            Err(HostedAuthError::Unauthorized {
                reason: Some("nope".into())
            })
        );
        assert!(matches!(
            check_json_response(&response(200, "text/html", "<html>"), false),
            Err(HostedAuthError::MalformedResponse { .. })
        ));
    }
}
