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

    #[test]
    fn origin_drops_mount_query_and_fragment() {
        let url = normalize("http://localhost:6767/omnigent/?o=1#chat", true).unwrap();
        assert_eq!(origin(&url), "http://localhost:6767");
        let https = normalize("https://h.example.com:443/a", false).unwrap();
        assert_eq!(origin(&https), "https://h.example.com");
    }
}
