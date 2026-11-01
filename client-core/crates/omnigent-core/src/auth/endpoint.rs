//! The direct API root a native client talks to, and the requests it builds.
//!
//! Port of `NativeLab`'s `ServerEndpoint` (`ServerConnection.swift`). This is the API root including
//! any deployment mount (`https://host/api/2.0/omnigent`), not a web UI URL. Accepted roots are:
//!
//! - `https://` URLs with an optional mount path;
//! - literal loopback `http://127.0.0.1[:port]` or `http://[::1][:port]` roots, which mean
//!   explicit local single-user mode;
//! - on a Databricks workspace host only, exactly one numeric `?o=<workspace-id>` selector, which
//!   becomes the `X-Databricks-Org-Id` header and never a request query parameter.
//!
//! Userinfo, fragments, other queries, encoded or dot path segments, empty segments and
//! backslashes are rejected at construction, before any request.

use url::Url;

use super::SecretString;
use super::errors::HostedAuthError;
use crate::http::{HttpHeader, HttpRequest};

const LOCAL_HOSTS: [&str; 2] = ["127.0.0.1", "[::1]"];
const DATABRICKS_SUFFIXES: [&str; 2] = [".databricks.com", ".azuredatabricks.net"];

/// The org header Databricks routes workspace requests by.
pub const DATABRICKS_ORG_HEADER: &str = "X-Databricks-Org-Id";

/// A validated, canonical API root.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ServerEndpoint {
    base_url: String,
    origin: String,
    mount: String,
    is_local_single_user: bool,
    databricks_org_id: Option<String>,
}

impl ServerEndpoint {
    /// Validates and canonicalizes `raw`: lower-case scheme and host, no default port, no trailing
    /// slash.
    ///
    /// # Errors
    ///
    /// [`HostedAuthError::InvalidBaseUrl`] for anything outside the accepted shapes.
    pub fn new(raw: &str) -> Result<Self, HostedAuthError> {
        let invalid = || HostedAuthError::InvalidBaseUrl;
        if raw.contains('\\') || raw.chars().any(char::is_whitespace) {
            return Err(invalid());
        }
        validate_raw_path(raw_path(raw)).map_err(|()| invalid())?;
        let url = Url::parse(raw).map_err(|_| invalid())?;
        let scheme = url.scheme();
        let host = url
            .host_str()
            .filter(|host| !host.is_empty())
            .ok_or_else(invalid)?;
        if !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
            || url.port() == Some(0)
        {
            return Err(invalid());
        }
        let local = scheme == "http" && LOCAL_HOSTS.contains(&host);
        if scheme != "https" && !local {
            return Err(invalid());
        }
        let databricks_org_id = match url.query() {
            None => None,
            Some(query) => {
                if scheme != "https" || !is_databricks_workspace_host(host) {
                    return Err(invalid());
                }
                Some(org_selector(query).ok_or_else(invalid)?)
            }
        };
        let mount = url.path().trim_end_matches('/').to_owned();
        if local && !mount.is_empty() {
            return Err(invalid());
        }
        let origin = url.origin().ascii_serialization();
        let mut base_url = format!("{origin}{mount}");
        if let Some(org) = &databricks_org_id {
            base_url.push_str("?o=");
            base_url.push_str(org);
        }
        Ok(Self {
            base_url,
            origin,
            mount,
            is_local_single_user: local,
            databricks_org_id,
        })
    }

    /// The canonical API root, `?o=` selector included.
    #[must_use]
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// `scheme://host[:port]`.
    #[must_use]
    pub fn origin(&self) -> &str {
        &self.origin
    }

    /// The mount path without a trailing slash; empty at the origin root.
    #[must_use]
    pub fn mount(&self) -> &str {
        &self.mount
    }

    /// An explicit loopback single-user server: no credentials are ever sent.
    #[must_use]
    pub const fn is_local_single_user(&self) -> bool {
        self.is_local_single_user
    }

    /// The Databricks workspace selected by `?o=`. Never inferred from the hostname.
    #[must_use]
    pub fn databricks_org_id(&self) -> Option<&str> {
        self.databricks_org_id.as_deref()
    }

    /// The absolute URL of `path` under the mount, with `query` and no `o=` selector.
    ///
    /// # Errors
    ///
    /// [`HostedAuthError::InvalidBaseUrl`] for a path that is not a plain absolute route, or a
    /// query that would override the saved workspace selector.
    pub fn url(&self, path: &str, query: &[(&str, &str)]) -> Result<String, HostedAuthError> {
        if !path.starts_with('/')
            || ['?', '#', '%', '\\'].iter().any(|c| path.contains(*c))
            || validate_raw_path(path).is_err()
            || (self.databricks_org_id.is_some() && query.iter().any(|(name, _)| *name == "o"))
        {
            return Err(HostedAuthError::InvalidBaseUrl);
        }
        let mut url = Url::parse(&format!("{}{}{path}", self.origin, self.mount))
            .map_err(|_| HostedAuthError::InvalidBaseUrl)?;
        if !query.is_empty() {
            url.query_pairs_mut().extend_pairs(query);
        }
        Ok(url.into())
    }

    /// The WebSocket URL of `path`: `ws://` for local single-user, `wss://` otherwise.
    ///
    /// # Errors
    ///
    /// See [`ServerEndpoint::url`].
    pub fn websocket_url(
        &self,
        path: &str,
        query: &[(&str, &str)],
    ) -> Result<String, HostedAuthError> {
        let http = self.url(path, query)?;
        let rest = http
            .strip_prefix("https://")
            .map(|rest| format!("wss://{rest}"))
            .or_else(|| {
                http.strip_prefix("http://")
                    .map(|rest| format!("ws://{rest}"))
            });
        rest.ok_or(HostedAuthError::InvalidBaseUrl)
    }

    /// A `GET` of `path` accepting JSON, carrying the org header and, when given, the bearer.
    ///
    /// # Errors
    ///
    /// See [`ServerEndpoint::request_with`].
    pub fn request(
        &self,
        path: &str,
        query: &[(&str, &str)],
        bearer: Option<&SecretString>,
    ) -> Result<HttpRequest, HostedAuthError> {
        self.request_with("GET", path, query, "application/json", bearer)
    }

    /// A request for `path` with explicit method and `Accept`.
    ///
    /// # Errors
    ///
    /// [`HostedAuthError::InvalidBaseUrl`] (see [`ServerEndpoint::url`]),
    /// [`HostedAuthError::Unauthorized`] for a bearer [`validate_bearer`] rejects, and
    /// [`HostedAuthError::UnsupportedAuthentication`] for any bearer on a local single-user
    /// server.
    pub fn request_with(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, &str)],
        accept: &str,
        bearer: Option<&SecretString>,
    ) -> Result<HttpRequest, HostedAuthError> {
        let url = self.url(path, query)?;
        let mut headers = vec![HttpHeader::new("Accept", accept)];
        if let Some(org) = &self.databricks_org_id {
            headers.push(HttpHeader::new(DATABRICKS_ORG_HEADER, org.clone()));
        }
        if let Some(bearer) = bearer {
            validate_bearer(bearer.expose())?;
            if self.is_local_single_user {
                return Err(HostedAuthError::UnsupportedAuthentication);
            }
            headers.push(HttpHeader::new(
                "Authorization",
                format!("Bearer {}", bearer.expose()),
            ));
        }
        Ok(HttpRequest {
            method: method.to_owned(),
            url,
            headers,
            body: None,
        })
    }

    /// The identity scope for `user_id` on this endpoint.
    #[must_use]
    pub fn identity_scope(&self, user_id: &str) -> ServerIdentityScope {
        ServerIdentityScope {
            server_url: self.base_url.clone(),
            user_id: user_id.to_owned(),
        }
    }
}

/// A server account: what per-account state (drafts, notifications, credentials) is keyed by.
/// Two Databricks workspaces on one host are different scopes.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ServerIdentityScope {
    /// The canonical API root.
    pub server_url: String,
    /// The confirmed user id.
    pub user_id: String,
}

impl ServerIdentityScope {
    /// `server_url + "\n" + user_id`: the saved-account id and Keychain account name.
    #[must_use]
    pub fn account_id(&self) -> String {
        format!("{}\n{}", self.server_url, self.user_id)
    }
}

/// A bearer token: non-empty, only `A-Z a-z 0-9 - . _ ~ + / =` (RFC 6750 `b64token`).
///
/// # Errors
///
/// [`HostedAuthError::Unauthorized`] for anything else, so a CR/LF can never inject a header.
pub fn validate_bearer(token: &str) -> Result<(), HostedAuthError> {
    let valid = !token.is_empty()
        && token.bytes().all(|byte| {
            byte.is_ascii_alphanumeric()
                || matches!(byte, b'-' | b'.' | b'_' | b'~' | b'+' | b'/' | b'=')
        });
    if valid {
        Ok(())
    } else {
        Err(HostedAuthError::Unauthorized { reason: None })
    }
}

/// The part of `raw` between the authority and the query or fragment, as typed.
fn raw_path(raw: &str) -> &str {
    let after_scheme = raw.split_once("://").map_or(raw, |(_, rest)| rest);
    let end = after_scheme.find(['?', '#']).unwrap_or(after_scheme.len());
    let (before, _) = after_scheme.split_at(end);
    before
        .find('/')
        .map_or("", |start| before.split_at(start).1)
}

/// No percent escapes, empty segments, or dot segments: the `url` crate would decode or resolve
/// them silently, so they are checked before parsing.
fn validate_raw_path(path: &str) -> Result<(), ()> {
    if path.contains('%') || path.contains("//") {
        return Err(());
    }
    if path
        .split('/')
        .any(|segment| segment == "." || segment == "..")
    {
        return Err(());
    }
    Ok(())
}

fn org_selector(query: &str) -> Option<String> {
    let digits = query.strip_prefix("o=")?;
    (!digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit()))
        .then(|| digits.to_owned())
}

/// A documented Databricks workspace host: a subdomain of `databricks.com` or
/// `azuredatabricks.net` whose labels are LDH and do not start or end with `-`.
#[must_use]
pub fn is_databricks_workspace_host(host: &str) -> bool {
    let host = host.to_ascii_lowercase();
    DATABRICKS_SUFFIXES
        .iter()
        .any(|suffix| host.ends_with(suffix))
        && host.split('.').all(|label| {
            !label.is_empty()
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::testing::header;

    const MOUNT: &str = "/api/2.0/omnigent";

    #[test]
    fn http_requires_literal_loopback_roots() {
        for address in [
            "http://127.0.0.1:6767",
            "http://127.0.0.1:6767/",
            "http://[::1]:6767",
        ] {
            let endpoint = ServerEndpoint::new(address).unwrap();
            assert!(endpoint.is_local_single_user(), "{address}");
        }
        assert_eq!(
            ServerEndpoint::new("http://127.0.0.1:6767/")
                .unwrap()
                .base_url(),
            "http://127.0.0.1:6767"
        );
        for address in [
            "http://localhost:6767",
            "http://192.168.1.2:6767",
            "http://127.0.0.2:6767",
            "http://example.com",
            "http://user:secret@127.0.0.1:6767",
            "http://127.0.0.1:6767/api",
            "http://127.0.0.1:6767?token=secret",
            "http://127.0.0.1:6767#fragment",
            "http://127.0.0.1:0",
            "http://127.0.0.1:65536",
        ] {
            assert_eq!(
                ServerEndpoint::new(address),
                Err(HostedAuthError::InvalidBaseUrl),
                "{address}"
            );
        }
    }

    #[test]
    fn endpoint_rejects_unsafe_ur_ls_and_canonicalizes_mount() {
        let endpoint = ServerEndpoint::new("https://EXAMPLE.invalid:443/api/2.0/").unwrap();
        assert_eq!(endpoint.base_url(), "https://example.invalid/api/2.0");
        assert!(!endpoint.is_local_single_user());
        for address in [
            "http://example.invalid/api",
            "https://user:pass@example.invalid/api",
            "https://example.invalid/api?token=example",
            "https://example.invalid/#fragment",
            "https://example.invalid/api/../other",
            "https://example.invalid/api/%2Fother",
            "https://example.invalid/api//other",
            "https://example.invalid/api\\other",
            "https://example.invalid/./api",
        ] {
            assert_eq!(
                ServerEndpoint::new(address),
                Err(HostedAuthError::InvalidBaseUrl),
                "{address}"
            );
        }
        for token in ["", "a\r\nX-Forwarded-Email: bob", " bearer value "] {
            assert_eq!(
                endpoint.request("/v1/me", &[], Some(&SecretString::new(token))),
                Err(HostedAuthError::Unauthorized { reason: None }),
                "{token:?}"
            );
        }
        let local = ServerEndpoint::new("http://127.0.0.1:6767").unwrap();
        assert_eq!(
            local.request(
                "/v1/me",
                &[],
                Some(&SecretString::new("fixture-token-not-a-real-credential"))
            ),
            Err(HostedAuthError::UnsupportedAuthentication)
        );
    }

    #[test]
    fn bearer_header_and_mount_apply_to_sse_web_socket_upload_configuration_and_notifications() {
        let endpoint = ServerEndpoint::new(&format!("https://127.0.0.1:8443{MOUNT}")).unwrap();
        let token = SecretString::new("fixture-token-not-a-real-credential");
        for path in [
            "/v1/sessions/a/stream",
            "/v1/sessions/a/resources/files",
            "/v1/sessions/a/configuration",
            "/v1/notifications/devices",
        ] {
            let request = endpoint.request(path, &[], Some(&token)).unwrap();
            assert_eq!(request.url, format!("https://127.0.0.1:8443{MOUNT}{path}"));
            assert_eq!(
                header(&request, "Authorization"),
                Some("Bearer fixture-token-not-a-real-credential")
            );
            assert_eq!(header(&request, "Cookie"), None);
        }
        assert_eq!(
            endpoint.websocket_url("/v1/sessions/updates", &[]).unwrap(),
            format!("wss://127.0.0.1:8443{MOUNT}/v1/sessions/updates")
        );
        let local = ServerEndpoint::new("http://127.0.0.1:6767").unwrap();
        assert_eq!(
            local.websocket_url("/v1/sessions/updates", &[]).unwrap(),
            "ws://127.0.0.1:6767/v1/sessions/updates"
        );
    }

    #[test]
    fn selector_canonicalization_and_documented_host_boundaries() {
        for host in [
            "acme.databricks.com",
            "dbc-test.cloud.databricks.com",
            "test.gcp.databricks.com",
            "adb-123.4.azuredatabricks.net",
        ] {
            let raw = format!("https://{}:443{MOUNT}/?o=123", host.to_ascii_uppercase());
            let endpoint = ServerEndpoint::new(&raw).unwrap();
            assert_eq!(endpoint.base_url(), format!("https://{host}{MOUNT}?o=123"));
            assert_eq!(endpoint.databricks_org_id(), Some("123"));
            assert!(!endpoint.is_local_single_user());
        }
        let unscoped = ServerEndpoint::new(&format!("https://acme.databricks.com{MOUNT}")).unwrap();
        assert_eq!(unscoped.databricks_org_id(), None, "never infer an org");
        let request = unscoped.request("/v1/me", &[], None).unwrap();
        assert_eq!(header(&request, DATABRICKS_ORG_HEADER), None);
    }

    #[test]
    fn rejects_malformed_selectors_and_other_hosts_without_making_requests() {
        for query in [
            "",
            "o",
            "o=",
            "o=-1",
            "o=+1",
            "o=1.2",
            "o=1e3",
            "o= 1",
            "o=١",
            "O=123",
            "o=123&o=123",
            "o=123&other=1",
            "o=123&",
            "o=123=4",
            "other=123",
            "%6F=123",
            "o=%31",
            "o=123%0D%0AX-Test:1",
        ] {
            let raw = format!("https://acme.databricks.com{MOUNT}?{query}");
            assert_eq!(
                ServerEndpoint::new(&raw),
                Err(HostedAuthError::InvalidBaseUrl),
                "{query}"
            );
        }
        for root in [
            "http://acme.databricks.com",
            "http://127.0.0.1",
            "https://127.0.0.1",
            "https://example.invalid",
            "https://databricks.com",
            "https://evildatabricks.com",
            "https://acme.databricks.com.evil.invalid",
            "https://evilazuredatabricks.net",
            "https://acme.azuredatabricks.net.evil.invalid",
            "https://app.aws.databricksapps.com",
            "https://a..databricks.com",
        ] {
            assert_eq!(
                ServerEndpoint::new(&format!("{root}?o=123")),
                Err(HostedAuthError::InvalidBaseUrl),
                "{root}"
            );
        }
    }

    #[test]
    fn every_transport_carries_org_header_without_polluting_endpoint_query() {
        let endpoint = ServerEndpoint::new(&format!(
            "https://fixture.cloud.databricks.com:8443{MOUNT}?o=123"
        ))
        .unwrap();
        let token = SecretString::new("fixture-routing-token");
        let query = [("after", "cursor/+?&"), ("limit", "20")];
        for (path, socket) in [
            ("/v1/info", false),
            ("/v1/me", false),
            ("/v1/sessions", false),
            ("/v1/sessions/a/stream", false),
            ("/v1/sessions/updates", true),
            ("/v1/sessions/a/resources/files", false),
            ("/v1/sessions/a/resources/files/f/content", false),
            ("/v1/sessions/a/configuration", false),
            ("/v1/notifications/devices", false),
        ] {
            let request = endpoint.request(path, &query, Some(&token)).unwrap();
            let target = if socket {
                endpoint.websocket_url(path, &query).unwrap()
            } else {
                request.url.clone()
            };
            let url = Url::parse(&target).unwrap();
            assert_eq!(url.scheme(), if socket { "wss" } else { "https" });
            assert_eq!(url.host_str(), Some("fixture.cloud.databricks.com"));
            assert_eq!(url.path(), format!("{MOUNT}{path}"));
            let pairs: Vec<(String, String)> = url.query_pairs().into_owned().collect();
            assert_eq!(
                pairs,
                vec![
                    ("after".to_owned(), "cursor/+?&".to_owned()),
                    ("limit".to_owned(), "20".to_owned())
                ]
            );
            assert_eq!(
                header(&request, "Authorization"),
                Some("Bearer fixture-routing-token")
            );
            assert_eq!(header(&request, DATABRICKS_ORG_HEADER), Some("123"));
            assert_eq!(header(&request, "X-Forwarded-Email"), None);
        }
        assert_eq!(
            endpoint.request("/v1/sessions", &[("o", "456")], Some(&token)),
            Err(HostedAuthError::InvalidBaseUrl),
            "a query must not override the saved workspace"
        );
    }

    #[test]
    fn route_paths_must_be_plain() {
        let endpoint = ServerEndpoint::new("https://h.example.com/api").unwrap();
        for path in [
            "v1/me",
            "/v1//me",
            "/v1/../me",
            "/v1/me?x=1",
            "/v1/me#f",
            "/v1/%2e",
        ] {
            assert_eq!(
                endpoint.url(path, &[]),
                Err(HostedAuthError::InvalidBaseUrl),
                "{path}"
            );
        }
    }

    #[test]
    fn identity_scope_separates_orgs_and_accounts() {
        let first = ServerEndpoint::new("https://h.cloud.databricks.com/api?o=123").unwrap();
        let second = ServerEndpoint::new("https://h.cloud.databricks.com/api?o=456").unwrap();
        assert_ne!(
            first.identity_scope("alice"),
            second.identity_scope("alice")
        );
        assert_ne!(first.identity_scope("alice"), first.identity_scope("bob"));
        assert_eq!(
            ServerEndpoint::new("https://omni.example/api/team-a")
                .unwrap()
                .identity_scope("alice")
                .account_id(),
            "https://omni.example/api/team-a\nalice"
        );
    }
}
