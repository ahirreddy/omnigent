//! Web-context identity and workspace-session navigation policy.
//!
//! Ports `DatabricksWebContext` (`web/ios/Omnigent/DatabricksWebContext.swift`) and the URL policy
//! of `DatabricksWebSession` (`DatabricksSessionClient.swift`).
//!
//! A [`WebContext`] binds a page to one credential scope and one isolated web-data store. The
//! store identifier is derived from the scope, so it is stable across equivalent URLs and differs
//! by workspace and client; hosts open their persistent web store (a `WKWebsiteDataStore`) with
//! it, and it matches what the Swift app already created.

use std::collections::BTreeSet;
use std::fmt;

use sha2::{Digest as _, Sha256};
use url::Url;

use super::config::OAuthConfiguration;
use super::error::DatabricksError;
use super::query;
use super::scope::CredentialScope;
use crate::auth::mode::ServerAuthentication;
use crate::server_url;

/// The name of the workspace session cookie.
pub const SESSION_COOKIE_NAME: &str = "DBAUTH";

/// The path as Foundation's `URL.path` reports it: percent-decoded, without a trailing slash
/// (except for the root).
fn decoded_path(url: &Url) -> String {
    let raw = url.path();
    let path = query::percent_decode(raw).unwrap_or_else(|| raw.to_owned());
    match path.strip_suffix('/') {
        Some(trimmed) if !trimmed.is_empty() => trimmed.to_owned(),
        _ => path,
    }
}

/// Whether `path` is a Databricks login or OAuth path, which is never a workspace page.
#[must_use]
pub fn is_login_path(path: &str) -> bool {
    path == "/login"
        || path == "/login.html"
        || path.starts_with("/login/")
        || path.starts_with("/oidc/")
        || path == "/auth/login"
        || path == "/auth/callback"
        || path == "/auth/session/create"
}

/// The 16-byte identifier of a context's isolated web-data store, shaped as an RFC 9562
/// version 8 UUID.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct StoreIdentifier([u8; 16]);

impl StoreIdentifier {
    /// The raw bytes (for `UUID(uuid:)`).
    #[must_use]
    pub const fn bytes(&self) -> [u8; 16] {
        self.0
    }
}

impl fmt::Display for StoreIdentifier {
    /// Upper-case hyphenated form, as Foundation's `UUID.uuidString`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (index, byte) in self.0.iter().enumerate() {
            if matches!(index, 4 | 6 | 8 | 10) {
                f.write_str("-")?;
            }
            write!(f, "{byte:02X}")?;
        }
        Ok(())
    }
}

/// A workspace page bound to its credential scope and web-data store.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WebContext {
    configuration: OAuthConfiguration,
    scope: CredentialScope,
    page_url: Url,
}

impl WebContext {
    /// The context for a workspace `url`. A bare workspace root becomes the SPA mount.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::InvalidWorkspace`] for the OAuth redirect page, a login or OAuth path,
    /// or a URL [`CredentialScope::new`] rejects.
    pub fn new(url: &Url, configuration: &OAuthConfiguration) -> Result<Self, DatabricksError> {
        if configuration.is_redirect_page(url) || is_login_path(&decoded_path(url)) {
            return Err(DatabricksError::InvalidWorkspace);
        }
        Ok(Self {
            configuration: configuration.clone(),
            scope: CredentialScope::new(url, configuration)?,
            page_url: server_url::workspace_ui_url_for_bare_root(url)
                .unwrap_or_else(|| url.clone()),
        })
    }

    /// The context for `url` when it is on a Databricks workspace domain; `Ok(None)` for apps and
    /// generic servers, which keep their own sign-in strategy. `configuration` is only loaded for
    /// workspace hosts, so a build without a client id still opens other servers.
    ///
    /// # Errors
    ///
    /// The configuration error, or see [`WebContext::new`].
    pub fn resolve(
        url: &Url,
        configuration: impl FnOnce() -> Result<OAuthConfiguration, DatabricksError>,
    ) -> Result<Option<Self>, DatabricksError> {
        if ServerAuthentication::for_url(url) != ServerAuthentication::DatabricksWorkspace {
            return Ok(None);
        }
        Self::new(url, &configuration()?).map(Some)
    }

    /// The same scope and store, showing `url` (recovery and in-app navigation never switch
    /// workspaces).
    ///
    /// # Errors
    ///
    /// [`DatabricksError::WorkspaceChanged`] when both URLs name different `o=` workspaces, or
    /// see [`WebContext::new`] for `url` itself.
    pub fn navigating(&self, url: &Url) -> Result<Self, DatabricksError> {
        let target = Self::new(url, &self.configuration)?;
        if let (Some(current), Some(next)) =
            (self.scope.workspace_id(), target.scope.workspace_id())
            && current != next
        {
            return Err(DatabricksError::WorkspaceChanged);
        }
        Ok(Self {
            configuration: self.configuration.clone(),
            scope: self.scope.clone(),
            page_url: target.page_url,
        })
    }

    /// The client configuration.
    #[must_use]
    pub const fn configuration(&self) -> &OAuthConfiguration {
        &self.configuration
    }

    /// The credential scope.
    #[must_use]
    pub const fn scope(&self) -> &CredentialScope {
        &self.scope
    }

    /// The page to load.
    #[must_use]
    pub const fn page_url(&self) -> &Url {
        &self.page_url
    }

    /// `SHA-256("omnigent.databricks.web.v1:" + account)`, truncated to 16 bytes with the UUID
    /// version (8) and variant bits set.
    #[must_use]
    pub fn store_identifier(&self) -> StoreIdentifier {
        let digest = Sha256::digest(format!(
            "omnigent.databricks.web.v1:{}",
            self.scope.account()
        ));
        let mut bytes = [0_u8; 16];
        for (slot, byte) in bytes.iter_mut().zip(digest.iter()) {
            *slot = *byte;
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x80;
        bytes[8] = (bytes[8] & 0x3F) | 0x80;
        StoreIdentifier(bytes)
    }
}

/// Lower-case hex SHA-256 of the URL's serialization.
fn fingerprint(url: &Url) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut hex = String::with_capacity(64);
    for byte in Sha256::digest(url.as_str()) {
        for nibble in [byte >> 4, byte & 0x0F] {
            if let Some(digit) = HEX.get(usize::from(nibble)) {
                hex.push(char::from(*digit));
            }
        }
    }
    hex
}

/// Which web-data strategy a URL uses.
///
/// `generic` for non-workspace servers, the store identifier for a workspace, and
/// `invalid-workspace:<fingerprint>` when the workspace URL was rejected (so a failed context is
/// never confused with a valid one).
#[must_use]
pub fn context_identity(
    url: &Url,
    resolved: &Result<Option<WebContext>, DatabricksError>,
) -> String {
    match resolved {
        Ok(Some(context)) => context.store_identifier().to_string(),
        Ok(None) => "generic".to_owned(),
        Err(_) => format!("invalid-workspace:{}", fingerprint(url)),
    }
}

/// A view identity that changes whenever the page or its web-data strategy does.
#[must_use]
pub fn view_identity(url: &Url, resolved: &Result<Option<WebContext>, DatabricksError>) -> String {
    let context = context_identity(url, resolved);
    if context == "generic" {
        context
    } else {
        format!("{context}:{}", fingerprint(url))
    }
}

/// `host[:port]`, plus ` · <o>` for a workspace context with an `o=` selector.
#[must_use]
pub fn server_label(url: &Url, context: Option<&WebContext>) -> String {
    let host = server_url::host_label(url);
    match context.and_then(|context| context.scope().workspace_id()) {
        Some(id) => format!("{host} · {id}"),
        None => host,
    }
}

/// A session cookie as the host's cookie store reports it.
#[derive(Clone, PartialEq, Eq)]
pub struct SessionCookie {
    /// Cookie name.
    pub name: String,
    /// Cookie value (a credential: `Debug` redacts it).
    pub value: String,
    /// Domain attribute; a leading `.` allows subdomains.
    pub domain: String,
    /// Path attribute.
    pub path: String,
    /// `Secure`.
    pub secure: bool,
    /// `HttpOnly`.
    pub http_only: bool,
    /// Expiry in ms since the Unix epoch; `None` for a session cookie.
    pub expires_at_ms: Option<u64>,
}

impl fmt::Debug for SessionCookie {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SessionCookie")
            .field("name", &self.name)
            .field("value", &"<redacted>")
            .field("domain", &self.domain)
            .field("path", &self.path)
            .field("secure", &self.secure)
            .field("http_only", &self.http_only)
            .field("expires_at_ms", &self.expires_at_ms)
            .finish()
    }
}

impl SessionCookie {
    fn bare_domain(&self) -> String {
        let domain = self.domain.to_ascii_lowercase();
        domain
            .strip_prefix('.')
            .map_or_else(|| domain.clone(), str::to_owned)
    }

    /// Whether the cookie would be sent to `url` at `now_ms`: domain (exact, or a subdomain for
    /// a leading-dot domain), path on a segment boundary, `Secure` only over https, unexpired.
    #[must_use]
    pub fn applies_to(&self, url: &Url, now_ms: u64) -> bool {
        let Some(host) = url.host_str().map(str::to_ascii_lowercase) else {
            return false;
        };
        let domain = self.bare_domain();
        let matches_host = host == domain
            || (self.domain.starts_with('.') && host.ends_with(&format!(".{domain}")));
        let path = if url.path().is_empty() {
            "/"
        } else {
            url.path()
        };
        let prefix = if self.path.ends_with('/') {
            self.path.clone()
        } else {
            format!("{}/", self.path)
        };
        let matches_path = path == self.path || path.starts_with(&prefix);
        matches_host
            && matches_path
            && (!self.secure || url.scheme() == "https")
            && self.expires_at_ms.is_none_or(|expiry| expiry > now_ms)
    }

    /// Whether this is the same cookie slot (name, domain, path) as `other`.
    #[must_use]
    pub fn same_slot(&self, other: &Self) -> bool {
        self.name == other.name && self.domain == other.domain && self.path == other.path
    }
}

/// A created workspace session: the page to load, the cookies to install, and the origins the
/// web view may stay on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceSession {
    /// The page to load after installing the cookies.
    pub page_url: Url,
    /// Cookie updates to install in the context's store.
    pub cookies: Vec<SessionCookie>,
    /// Workspace origins (`https://host`) this session may navigate within.
    pub allowed_origins: BTreeSet<String>,
    /// The client configuration.
    pub configuration: OAuthConfiguration,
    /// The `o=` workspace the session is bound to, when known.
    pub workspace_id: Option<String>,
}

impl WorkspaceSession {
    /// A session for `context` with `cookies`, allowing only the context's own origin.
    #[must_use]
    pub fn for_context(context: &WebContext, cookies: Vec<SessionCookie>) -> Self {
        Self {
            page_url: context.page_url().clone(),
            cookies,
            allowed_origins: BTreeSet::from([context.scope().workspace_origin().to_owned()]),
            configuration: context.configuration().clone(),
            workspace_id: context.scope().workspace_id().map(str::to_owned),
        }
    }

    fn page_scope(&self, url: &Url) -> Option<CredentialScope> {
        let scope = CredentialScope::new(url, &self.configuration).ok()?;
        let compatible = self.allowed_origins.contains(scope.workspace_origin())
            && match (scope.workspace_id(), self.workspace_id.as_deref()) {
                (Some(page), Some(session)) => page == session,
                _ => true,
            };
        compatible.then_some(scope)
    }

    /// Whether `url` is this session's login page (an expired session, not a sign-out).
    #[must_use]
    pub fn is_authentication_url(&self, url: &Url) -> bool {
        self.page_scope(url).is_some() && is_login_path(&decoded_path(url))
    }

    /// Whether `url` is this session's logout navigation (`/auth/logout`, `/logout`, or
    /// `/login.html?logout=1`), handled as local sign-out.
    #[must_use]
    pub fn is_sign_out_url(&self, url: &Url) -> bool {
        if self.page_scope(url).is_none() {
            return false;
        }
        let path = decoded_path(url);
        if path == "/auth/logout" || path == "/logout" {
            return true;
        }
        path == "/login.html"
            && url
                .query()
                .and_then(query::items)
                .is_some_and(|items| query::values(&items, "logout").contains(&Some("1")))
    }

    /// `url` normalized onto the bound workspace (https, canonical host, default port, and this
    /// session's `o=` when the page omits it), or `None` for other workspaces, login paths, and
    /// insecure URLs.
    #[must_use]
    pub fn navigation_url(&self, url: &Url) -> Option<Url> {
        let scope = self.page_scope(url)?;
        if is_login_path(&decoded_path(url)) {
            return None;
        }
        let mut normalized = url.clone();
        normalized.set_host(Some(scope.host())).ok()?;
        normalized.set_port(None).ok()?;
        let same_origin_as_page = Some(scope.workspace_origin()) == self.page_origin().as_deref();
        if same_origin_as_page
            && scope.workspace_id().is_none()
            && let Some(id) = &self.workspace_id
        {
            normalized.query_pairs_mut().append_pair("o", id);
        }
        Some(normalized)
    }

    fn page_origin(&self) -> Option<String> {
        self.page_url
            .host_str()
            .map(|host| format!("https://{}", host.to_ascii_lowercase()))
    }

    /// Whether `installed` (the store's cookies after installation) holds a live, `Secure`,
    /// `HttpOnly` [`SESSION_COOKIE_NAME`] cookie for the page that is one this session issued.
    #[must_use]
    pub fn has_installed_session_cookie(&self, installed: &[SessionCookie], now_ms: u64) -> bool {
        installed.iter().any(|cookie| {
            cookie.name == SESSION_COOKIE_NAME
                && cookie.secure
                && cookie.http_only
                && cookie.applies_to(&self.page_url, now_ms)
                && self
                    .cookies
                    .iter()
                    .any(|issued| issued.same_slot(cookie) && issued.value == cookie.value)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::databricks::test_support::{config, config_with, url};

    fn web_context(raw: &str) -> WebContext {
        WebContext::new(&url(raw), &config()).unwrap()
    }

    /// `DatabricksWebContextTests::testStableStoreIdentitySeparatesWorkspacesAndClients`.
    #[test]
    fn a_store_identifier_exposes_its_bytes_and_cookies_refuse_hostless_urls() {
        let context = web_context("https://workspace.databricks.com/omnigent?o=123");
        assert_eq!(
            context.store_identifier().bytes(),
            context.store_identifier().0
        );
        let cookie = SessionCookie {
            name: "n".to_owned(),
            value: "v".to_owned(),
            domain: "workspace.databricks.com".to_owned(),
            path: "/".to_owned(),
            secure: false,
            http_only: false,
            expires_at_ms: None,
        };
        assert!(!cookie.applies_to(&url("data:text/plain,x"), 0));
        assert!(cookie.applies_to(&url("http://workspace.databricks.com/any"), 0));
    }

    #[test]
    fn web_context_store_identity_separates_workspace_and_client() {
        let first = web_context("https://workspace.databricks.com/omnigent?o=123");
        let same = web_context(
            "https://WORKSPACE.DATABRICKS.COM:443/omnigent/c/abc?o=123&view=chat#message",
        );
        assert_eq!(first.store_identifier(), same.store_identifier());
        // Byte-compatible with the identifier the Swift app gave its persistent WebKit store.
        assert_eq!(
            first.store_identifier().to_string(),
            "ED857FEF-C66B-808E-B645-B9F8DF423552"
        );
        assert_ne!(
            first.store_identifier(),
            web_context("https://workspace.databricks.com/omnigent?o=456").store_identifier()
        );
        let other_client = WebContext::new(
            &url("https://workspace.databricks.com/omnigent?o=123"),
            &config_with("another-client"),
        )
        .unwrap();
        assert_ne!(first.store_identifier(), other_client.store_identifier());
        assert_eq!(
            web_context("https://workspace.databricks.com?o=123")
                .page_url()
                .as_str(),
            "https://workspace.databricks.com/omnigent?o=123"
        );
    }

    /// `DatabricksWebContextTests::testAppsAndGenericServersKeepTheirExistingStrategy`.
    #[test]
    fn web_context_apps_and_generic_have_no_databricks_context() {
        let never_loaded = || -> Result<OAuthConfiguration, DatabricksError> {
            Err(DatabricksError::InvalidClientId)
        };
        for raw in ["https://app.databricksapps.com", "https://example.com"] {
            assert_eq!(
                WebContext::resolve(&url(raw), never_loaded),
                Ok(None),
                "{raw}"
            );
        }
        let generic = url("https://example.com");
        assert_eq!(view_identity(&generic, &Ok(None)), "generic");
        assert_eq!(
            WebContext::new(
                &url("https://login.databricks.com/mobile-redirect?code=synthetic"),
                &config()
            ),
            Err(DatabricksError::InvalidWorkspace)
        );
        assert_eq!(
            WebContext::new(
                &url("https://workspace.databricks.com/oidc/v1/authorize"),
                &config()
            ),
            Err(DatabricksError::InvalidWorkspace)
        );
        // A workspace host needs the configuration, and its failure is reported.
        let workspace = url("https://workspace.databricks.com/omnigent");
        let resolved = WebContext::resolve(&workspace, never_loaded);
        assert_eq!(resolved, Err(DatabricksError::InvalidClientId));
        assert!(context_identity(&workspace, &resolved).starts_with("invalid-workspace:"));
        let resolved = WebContext::resolve(&workspace, || Ok(config()));
        let context = resolved.clone().unwrap().unwrap();
        assert_eq!(
            view_identity(&workspace, &resolved),
            format!("{}:{}", context.store_identifier(), fingerprint(&workspace))
        );
        let selected = url("https://workspace.databricks.com/omnigent?o=123");
        assert_eq!(
            server_label(&selected, Some(&web_context(selected.as_str()))),
            "workspace.databricks.com · 123"
        );
        assert_eq!(server_label(&generic, None), "example.com");
    }

    /// `DatabricksWebContextTests::testNavigationBindingRejectsOtherWorkspacesAndLoginDestinations`.
    #[test]
    fn web_session_navigation_binds_to_workspace() {
        let context = web_context("https://workspace.databricks.com/omnigent?o=123");
        let session = WorkspaceSession::for_context(&context, Vec::new());
        assert_eq!(
            session
                .navigation_url(&url("https://workspace.databricks.com/omnigent/c/abc"))
                .map(|u| u.to_string()),
            Some("https://workspace.databricks.com/omnigent/c/abc?o=123".to_owned())
        );
        for raw in [
            "https://workspace.databricks.com/omnigent?o=456",
            "https://different.databricks.com/omnigent?o=123",
            "https://workspace.databricks.com/login",
            "http://workspace.databricks.com/omnigent?o=123",
        ] {
            assert_eq!(session.navigation_url(&url(raw)), None, "{raw}");
        }
    }

    /// `DatabricksLifecycleTests::testRecoveryPageKeepsStoreIdentityAndRejectsAnotherWorkspace`.
    #[test]
    fn web_context_navigating_keeps_store_rejects_other_workspace() {
        let context = web_context("https://workspace.cloud.databricks.com/omnigent?o=123");
        let target = url("https://workspace.databricks.com/omnigent/c/abc?o=123#message");
        let navigation = context.navigating(&target).unwrap();
        assert_eq!(navigation.scope(), context.scope());
        assert_eq!(navigation.store_identifier(), context.store_identifier());
        assert_eq!(navigation.page_url(), &target);
        assert_eq!(
            context.navigating(&url("https://workspace.databricks.com/omnigent?o=456")),
            Err(DatabricksError::WorkspaceChanged)
        );
    }

    /// `DatabricksLifecycleTests::testLogoutURLsAreDistinctFromExpiredLoginAndOtherContexts`.
    #[test]
    fn logout_urls_distinct_from_login_and_other_contexts() {
        let context = web_context("https://workspace.databricks.com/omnigent?o=123");
        let session = WorkspaceSession::for_context(&context, Vec::new());
        for path in ["/auth/logout", "/logout", "/login.html?logout=1"] {
            let target = url(&format!("{}{path}", context.scope().workspace_origin()));
            assert!(session.is_sign_out_url(&target), "{path}");
        }
        assert!(
            !session.is_sign_out_url(&url("https://workspace.databricks.com/auth/logout?o=456"))
        );
        assert!(!session.is_sign_out_url(&url("https://other.databricks.com/auth/logout")));
        assert!(!session.is_sign_out_url(&url("https://workspace.databricks.com/login.html")));
        assert!(session.is_authentication_url(&url("https://workspace.databricks.com/login.html")));
        assert!(!session.is_authentication_url(&url("https://workspace.databricks.com/omnigent")));
    }

    #[test]
    fn cookie_matching_respects_domain_path_and_security() {
        let page = url("https://workspace.databricks.com/omnigent/c/abc");
        let cookie = SessionCookie {
            name: SESSION_COOKIE_NAME.into(),
            value: "secret-session".into(),
            domain: "workspace.databricks.com".into(),
            path: "/omnigent".into(),
            secure: true,
            http_only: true,
            expires_at_ms: Some(2_000),
        };
        assert!(cookie.applies_to(&page, 1_000));
        assert!(!cookie.applies_to(&page, 2_000), "expired");
        assert!(!cookie.applies_to(&url("https://workspace.databricks.com/omnigents"), 0));
        assert!(!cookie.applies_to(&url("http://workspace.databricks.com/omnigent"), 0));
        assert!(!cookie.applies_to(&url("https://sub.workspace.databricks.com/omnigent"), 0));
        let wide = SessionCookie {
            domain: ".databricks.com".into(),
            ..cookie.clone()
        };
        assert!(wide.applies_to(&page, 0));
        assert!(!format!("{cookie:?}").contains("secret-session"));
    }

    #[test]
    fn an_empty_url_path_counts_as_the_root() {
        let cookie = SessionCookie {
            name: "n".to_owned(),
            value: "v".to_owned(),
            domain: "workspace.databricks.com".to_owned(),
            path: "/".to_owned(),
            secure: false,
            http_only: false,
            expires_at_ms: None,
        };
        assert!(cookie.applies_to(&url("custom://workspace.databricks.com"), 0));
    }
}
