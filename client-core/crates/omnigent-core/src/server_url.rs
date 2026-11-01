//! User-entered server URLs. Port of `web/ios/Omnigent/ServerURL.swift`.

use std::fmt;

use url::Url;

/// Loopback hosts where plain http is the norm. Mirrors `LOCAL_HOSTS` in `web/electron/src/url.js`.
const LOCAL_HOSTS: [&str; 4] = ["localhost", "127.0.0.1", "[::1]", "::1"];

/// Why a user-entered server URL was rejected.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerUrlError {
    /// Nothing but whitespace was entered.
    Empty,
    /// The input (with any default scheme added) does not parse as a URL with a host.
    Invalid(String),
    /// A scheme other than http or https.
    UnsupportedScheme(String),
    /// `http://` while insecure http is not allowed.
    InsecureHttpNotAllowed,
}

impl fmt::Display for ServerUrlError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Empty => f.write_str("Server URL is empty."),
            Self::Invalid(input) => write!(f, "Invalid URL: {input}"),
            Self::UnsupportedScheme(scheme) => {
                write!(f, "Unsupported scheme '{scheme}'. Use https.")
            }
            Self::InsecureHttpNotAllowed => {
                f.write_str("This build requires https:// server URLs.")
            }
        }
    }
}

impl std::error::Error for ServerUrlError {}

/// Trims, adds a default scheme when none is typed, and enforces the http/https policy.
///
/// A schemeless remote host defaults to https even when `allows_insecure_http` is set: that flag
/// lets a debug build reach a local dev server, it must not downgrade a pasted remote host.
///
/// # Errors
///
/// See [`ServerUrlError`].
pub fn normalize(raw: &str, allows_insecure_http: bool) -> Result<Url, ServerUrlError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(ServerUrlError::Empty);
    }
    let with_scheme = if trimmed.contains("://") {
        trimmed.to_owned()
    } else {
        format!(
            "{}://{trimmed}",
            default_scheme(trimmed, allows_insecure_http)
        )
    };
    let url = Url::parse(&with_scheme)
        .map_err(|error| ServerUrlError::Invalid(format!("{with_scheme} ({error})")))?;
    match url.scheme() {
        "https" => {}
        "http" if allows_insecure_http => {}
        "http" => return Err(ServerUrlError::InsecureHttpNotAllowed),
        other => return Err(ServerUrlError::UnsupportedScheme(other.to_owned())),
    }
    if url.host_str().is_none_or(str::is_empty) {
        return Err(ServerUrlError::Invalid(with_scheme));
    }
    Ok(url)
}

/// The URL as users typed it: no trailing slash on a bare origin.
#[must_use]
pub fn display(url: &Url) -> String {
    let serialized = url.as_str();
    if url.path() == "/" && url.query().is_none() && url.fragment().is_none() {
        serialized.trim_end_matches('/').to_owned()
    } else {
        serialized.to_owned()
    }
}

/// `scheme://host[:port]`, dropping any mount path, query and fragment.
#[must_use]
pub fn origin(url: &Url) -> String {
    url.origin().ascii_serialization()
}

/// The server URL's mount: its path without trailing slashes; empty at the origin root.
#[must_use]
pub fn mount_path(url: &Url) -> &str {
    url.path().trim_end_matches('/')
}

/// `route` (absolute, e.g. `/auth/login`) under `server`'s mount, without its query or fragment:
/// `https://h/omnigent/` + `/v1/me` is `https://h/omnigent/v1/me`. Port of `omnigentEndpoint`.
///
/// `None` when `route` is not absolute.
#[must_use]
pub fn endpoint(server: &Url, route: &str) -> Option<Url> {
    if !route.starts_with('/') {
        return None;
    }
    let mut url = server.clone();
    let path = format!("{}{route}", mount_path(server));
    url.set_path(&path);
    url.set_query(None);
    url.set_fragment(None);
    Some(url)
}

/// `host[:port]` for messages; the port only when it is not the scheme's default.
#[must_use]
pub fn host_label(url: &Url) -> String {
    let host = url.host_str().unwrap_or_default();
    url.port()
        .map_or_else(|| host.to_owned(), |port| format!("{host}:{port}"))
}

/// Path the Omnigent SPA is mounted at inside a Databricks workspace (Android and Electron's
/// `WORKSPACE_UI_PATH`).
pub const WORKSPACE_UI_PATH: &str = "/omnigent";

/// The SPA-mount URL for a **bare** Databricks workspace root, or `None` for anything else.
///
/// Anything else is a non-workspace host, a non-web scheme, or a URL that already carries a path
/// (a deliberate deep link). Query and fragment survive because `?o=<org>` selects the
/// workspace.
///
/// Port of `WorkspaceURLExpander.workspaceUIURL(forBareRoot:)`. Unlike Foundation, the `url`
/// crate lowercases the host.
#[must_use]
pub fn workspace_ui_url_for_bare_root(url: &Url) -> Option<Url> {
    if !matches!(url.scheme(), "https" | "http")
        || crate::auth::mode::ServerAuthentication::for_url(url)
            != crate::auth::mode::ServerAuthentication::DatabricksWorkspace
        || !is_bare_root(url)
    {
        return None;
    }
    Some(with_workspace_mount(url))
}

/// Whether `url` has no path beyond `/`.
#[must_use]
pub fn is_bare_root(url: &Url) -> bool {
    url.path().is_empty() || url.path() == "/"
}

/// `url` with its path replaced by [`WORKSPACE_UI_PATH`], keeping scheme, host, port, query and
/// fragment.
#[must_use]
pub fn with_workspace_mount(url: &Url) -> Url {
    let mut mounted = url.clone();
    mounted.set_path(WORKSPACE_UI_PATH);
    mounted
}

fn default_scheme(trimmed: &str, allows_insecure_http: bool) -> &'static str {
    if !allows_insecure_http {
        return "https";
    }
    let host = Url::parse(&format!("https://{trimmed}"))
        .ok()
        .and_then(|url| url.host_str().map(str::to_ascii_lowercase))
        .unwrap_or_default();
    if LOCAL_HOSTS.contains(&host.as_str()) {
        "http"
    } else {
        "https"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn normalized(raw: &str, allows_insecure_http: bool) -> String {
        display(&normalize(raw, allows_insecure_http).unwrap())
    }

    #[test]
    fn release_policy_defaults_bare_host_to_https() {
        assert_eq!(normalized("example.com", false), "https://example.com");
    }

    #[test]
    fn debug_policy_defaults_bare_host_to_http() {
        assert_eq!(normalized("localhost:6767", true), "http://localhost:6767");
    }

    #[test]
    fn debug_policy_still_defaults_remote_host_to_https() {
        assert_eq!(
            normalized("dbc-b7cf3f6a-ac9f.cloud.databricks.com", true),
            "https://dbc-b7cf3f6a-ac9f.cloud.databricks.com"
        );
    }

    #[test]
    fn debug_policy_defaults_loopback_variants_to_http() {
        assert_eq!(normalized("127.0.0.1:6767", true), "http://127.0.0.1:6767");
        assert_eq!(normalized("[::1]:6767", true), "http://[::1]:6767");
        assert_eq!(normalized("LOCALHOST:6767", true), "http://localhost:6767");
    }

    #[test]
    fn release_policy_defaults_loopback_to_https() {
        assert_eq!(
            normalized("localhost:6767", false),
            "https://localhost:6767"
        );
    }

    #[test]
    fn debug_policy_honours_explicit_http_for_remote_host() {
        assert_eq!(normalized("http://example.com", true), "http://example.com");
    }

    #[test]
    fn release_policy_rejects_http() {
        assert_eq!(
            normalize("http://example.com", false),
            Err(ServerUrlError::InsecureHttpNotAllowed)
        );
    }

    #[test]
    fn rejects_non_web_schemes() {
        assert_eq!(
            normalize("ftp://example.com", true),
            Err(ServerUrlError::UnsupportedScheme("ftp".into()))
        );
    }

    #[test]
    fn rejects_empty_and_whitespace() {
        assert_eq!(normalize("", true), Err(ServerUrlError::Empty));
        assert_eq!(normalize(" \n\t", true), Err(ServerUrlError::Empty));
    }

    #[test]
    fn rejects_unparseable_input() {
        assert!(matches!(
            normalize("https://", true),
            Err(ServerUrlError::Invalid(_))
        ));
        assert!(matches!(
            normalize("exa mple.com", true),
            Err(ServerUrlError::Invalid(_))
        ));
    }

    #[test]
    fn trims_and_keeps_mount_query_and_fragment() {
        assert_eq!(
            normalized("  https://h.example.com/omnigent/?o=1#chat\n", false),
            "https://h.example.com/omnigent/?o=1#chat"
        );
        assert_eq!(
            normalized("https://example.com/", false),
            "https://example.com"
        );
    }

    fn url(raw: &str) -> Url {
        Url::parse(raw).unwrap()
    }

    #[test]
    fn endpoint_appends_route_under_mount() {
        for (server, route, expected) in [
            (
                "https://h/omnigent/",
                "/auth/login",
                "https://h/omnigent/auth/login",
            ),
            (
                "https://h/omnigent",
                "/auth/login",
                "https://h/omnigent/auth/login",
            ),
            (
                "https://h/omnigent///",
                "/v1/me",
                "https://h/omnigent/v1/me",
            ),
            ("https://h", "/v1/me", "https://h/v1/me"),
            ("https://h/", "/v1/me", "https://h/v1/me"),
            (
                "http://localhost:6767",
                "/oauth/token",
                "http://localhost:6767/oauth/token",
            ),
            (
                "https://h:8443/a/b?o=1#frag",
                "/auth/logout",
                "https://h:8443/a/b/auth/logout",
            ),
            (
                "https://h/my%20mount/",
                "/v1/me",
                "https://h/my%20mount/v1/me",
            ),
        ] {
            assert_eq!(
                endpoint(&url(server), route).unwrap().as_str(),
                expected,
                "{server}"
            );
        }
    }

    #[test]
    fn endpoint_rejects_relative_route() {
        assert_eq!(endpoint(&url("https://h/omnigent"), "auth/login"), None);
    }

    #[test]
    fn host_label_keeps_explicit_port() {
        assert_eq!(
            host_label(&url("http://localhost:6767/x")),
            "localhost:6767"
        );
        assert_eq!(
            host_label(&url("https://H.example.com:443/")),
            "h.example.com"
        );
        assert_eq!(host_label(&url("http://[::1]:6767")), "[::1]:6767");
    }

    fn mount(raw: &str) -> Option<String> {
        workspace_ui_url_for_bare_root(&url(raw)).map(|url| url.to_string())
    }

    #[test]
    fn workspace_ui_url_rewrites_bare_roots() {
        for (raw, expected) in [
            (
                "https://dbc-1234.cloud.databricks.com",
                "https://dbc-1234.cloud.databricks.com/omnigent",
            ),
            (
                "https://dbc-1234.cloud.databricks.com/",
                "https://dbc-1234.cloud.databricks.com/omnigent",
            ),
            (
                "https://adb-99.azuredatabricks.net/",
                "https://adb-99.azuredatabricks.net/omnigent",
            ),
            ("https://databricks.com/", "https://databricks.com/omnigent"),
            (
                "https://azuredatabricks.net/",
                "https://azuredatabricks.net/omnigent",
            ),
        ] {
            assert_eq!(mount(raw).as_deref(), Some(expected), "{raw}");
        }
    }

    #[test]
    fn workspace_ui_url_preserves_query_fragment() {
        assert_eq!(
            mount("https://dbc-1234.cloud.databricks.com/?o=987654321").as_deref(),
            Some("https://dbc-1234.cloud.databricks.com/omnigent?o=987654321")
        );
        assert_eq!(
            mount("https://dbc-1234.cloud.databricks.com/?o=1#frag").as_deref(),
            Some("https://dbc-1234.cloud.databricks.com/omnigent?o=1#frag")
        );
    }

    // Swift keeps the host's case as typed; the url crate lowercases it on parse.
    #[test]
    fn workspace_ui_url_keeps_port_and_lowercases_host() {
        assert_eq!(
            mount("https://dbc-1234.cloud.databricks.com:8443/").as_deref(),
            Some("https://dbc-1234.cloud.databricks.com:8443/omnigent")
        );
        assert_eq!(
            mount("https://DBC-1234.Cloud.DataBricks.Com/").as_deref(),
            Some("https://dbc-1234.cloud.databricks.com/omnigent")
        );
    }

    #[test]
    fn workspace_ui_url_leaves_non_root_paths() {
        for raw in [
            "https://dbc-1234.cloud.databricks.com/omnigent",
            "https://dbc-1234.cloud.databricks.com/c/abc",
            "https://dbc-1234.cloud.databricks.com/ml/omnigents",
        ] {
            assert_eq!(mount(raw), None, "{raw}");
        }
    }

    #[test]
    fn workspace_ui_url_leaves_apps_and_lookalikes() {
        for raw in [
            "https://my-app.databricksapps.com/",
            "https://databricksapps.com/",
            "https://MY-APP.AWS.DATABRICKSAPPS.COM/",
            "https://example.com/",
            "https://localhost:8000/",
            "https://databricks.com.evil.example/",
            "https://azuredatabricks.net.example.org/",
            "https://notdatabricks.com/",
            "https://notazuredatabricks.net/",
        ] {
            assert_eq!(mount(raw), None, "{raw}");
        }
    }

    #[test]
    fn workspace_ui_url_rejects_non_http_schemes() {
        assert_eq!(mount("omnigent://dbc-1234.cloud.databricks.com/"), None);
        assert_eq!(mount("file:///tmp"), None);
    }

    #[test]
    fn origin_drops_mount_query_and_fragment() {
        let url = normalize("http://localhost:6767/omnigent/?o=1#chat", true).unwrap();
        assert_eq!(origin(&url), "http://localhost:6767");
        let https = normalize("https://h.example.com:443/a", false).unwrap();
        assert_eq!(origin(&https), "https://h.example.com");
    }
}
