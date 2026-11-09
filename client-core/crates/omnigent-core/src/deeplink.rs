//! `omnigent://` deep links and the server-origin grammar they share with managed preferences.
//!
//! Port of the macOS desktop parser (`apps/apple/Packages/OmnigentDesktop/Sources/OmnigentDesktop/
//! Routing/{DeepLink,ServerOrigin}.swift`), which was itself ported from
//! `web/electron/src/deepLink.js`, plus the iOS parser in `web/ios/Omnigent/DeepLink.swift`.
//!
//! A link names a server by `host[:port]` and carries no http/https. The scheme is inferred the way
//! the connect screen infers it: `http` for loopback, `https` for anything else. Workspace mounts
//! such as `/omnigent` are not part of the link; they are discovered from the server.
//!
//! # Desktop, iOS and Electron
//!
//! The two native shells accept different links. [`DeepLinkPolicy`] selects one:
//!
//! | | [`DeepLinkPolicy::Desktop`] | [`DeepLinkPolicy::Ios`] |
//! |---|---|---|
//! | `omnigent://host` and `omnigent://host/` | [`DeepLinkRoute::Home`] | rejected |
//! | session id characters (after percent-decoding) | rejects `?`, `#`, `/`, `.`, `%`, C0 and DEL | same |
//! | stray `%` (`%zz`) in a session id | rejected | rejected |
//! | `desktop_ack` query | parsed and validated | ignored |
//!
//! Both policies share the strict origin grammar from the desktop parser: credentials, numeric
//! hosts other than canonical dotted quads (`0x7f000001`, `2130706433`, `1.2.3`, `127.0.0.01`),
//! percent-encoded and non-ASCII hosts are rejected. This is stricter than the iOS Swift parser,
//! which took `URL.host` from Foundation and so accepted `omnigent://trusted@evil/c/x` as `evil`.
//! The tightening is deliberate.
//!
//! Electron (`parseOmnigentDeepLink`) differs from both: it returns `null` instead of a typed
//! error, forwards the path still percent-encoded and with its trailing slash, takes the host from
//! WHATWG `URL` (which drops credentials, canonicalizes numeric hosts and applies IDNA), and leaves
//! `desktop_ack` to `acceptCliDeepLink`, which treats a malformed value as "do not handle".

use std::fmt;

use url::Url;

/// The URL scheme the apps register for deep links.
pub const SCHEME: &str = "omnigent";

/// Query parameter carrying the CLI acknowledgment, `<port>:<64 lowercase hex>`.
pub const ACKNOWLEDGMENT_PARAMETER: &str = "desktop_ack";

/// Hosts that run on this machine. They default to `http`, everything else to `https`.
pub const LOOPBACK_HOSTS: [&str; 3] = ["localhost", "127.0.0.1", "[::1]"];

// MARK: - Server origin

/// Why a scheme, host or port does not form a usable server origin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerOriginError {
    /// The scheme is not `http` or `https`. Carries the lowercased scheme (empty when missing).
    UnsupportedScheme(String),
    /// The host is empty.
    MissingHost,
    /// The host contains characters outside a DNS name, canonical IPv4 address or bracketed IPv6
    /// literal, or is an ambiguous numeric host.
    InvalidHost(String),
    /// The port is not a decimal number from 0 to 65535.
    InvalidPort(String),
    /// The origin includes a user name or password.
    CredentialsNotAllowed,
}

impl fmt::Display for ServerOriginError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedScheme(scheme) => write!(f, "unsupported scheme '{scheme}'"),
            Self::MissingHost => f.write_str("missing host"),
            Self::InvalidHost(host) => write!(f, "invalid host '{host}'"),
            Self::InvalidPort(port) => write!(f, "invalid port '{port}'"),
            Self::CredentialsNotAllowed => f.write_str("credentials are not allowed"),
        }
    }
}

impl std::error::Error for ServerOriginError {}

/// An origin scheme.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum OriginScheme {
    /// Plain HTTP, used for loopback servers.
    Http,
    /// TLS.
    Https,
}

impl OriginScheme {
    /// `"http"` or `"https"`.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Http => "http",
            Self::Https => "https",
        }
    }

    /// The port omitted from a serialized origin.
    #[must_use]
    pub const fn default_port(self) -> u16 {
        match self {
            Self::Http => 80,
            Self::Https => 443,
        }
    }

    /// Parses a scheme case-insensitively.
    ///
    /// # Errors
    ///
    /// [`ServerOriginError::UnsupportedScheme`] for anything but http and https.
    pub fn parse(raw: &str) -> Result<Self, ServerOriginError> {
        let lowered = raw.to_lowercase();
        match lowered.as_str() {
            "http" => Ok(Self::Http),
            "https" => Ok(Self::Https),
            _ => Err(ServerOriginError::UnsupportedScheme(lowered)),
        }
    }
}

/// An http(s) origin: scheme, lowercased host and non-default port, as in WHATWG `URL.origin`.
///
/// Windows, deep links, notifications and managed preferences compare servers by origin, so two
/// spellings of one server (`HTTPS://Example.com:443` and `https://example.com`) are equal.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ServerOrigin {
    scheme: OriginScheme,
    host: String,
    port: Option<u16>,
}

impl ServerOrigin {
    /// Validates and normalizes an origin. The scheme's default port is dropped.
    ///
    /// `host` is a DNS name, canonical dotted IPv4 address or bracketed IPv6 literal; ASCII case
    /// is folded.
    ///
    /// # Errors
    ///
    /// [`ServerOriginError`] when the host is invalid.
    pub fn new(
        scheme: OriginScheme,
        host: &str,
        port: Option<u16>,
    ) -> Result<Self, ServerOriginError> {
        Ok(Self {
            scheme,
            host: normalized_host(host)?,
            port: port.filter(|port| *port != scheme.default_port()),
        })
    }

    /// Parses a serialized origin such as `https://example.com:8443`, optionally with one trailing
    /// `/`.
    ///
    /// # Errors
    ///
    /// [`ServerOriginError`] when it is not a bare http(s) origin.
    pub fn parse(serialized: &str) -> Result<Self, ServerOriginError> {
        let Some((raw_scheme, authority)) = serialized.split_once("://") else {
            return Err(ServerOriginError::UnsupportedScheme(serialized.to_owned()));
        };
        let scheme = OriginScheme::parse(raw_scheme)?;
        let authority = authority.strip_suffix('/').unwrap_or(authority);
        let (host, port) = split_authority(authority)?;
        Self::new(scheme, host, port)
    }

    /// The origin of an absolute http(s) URL string. Paths, queries and fragments are ignored.
    ///
    /// The authority is checked with the same grammar as [`ServerOrigin::new`], not reinterpreted
    /// the way WHATWG `URL` would (so `https://0x7f000001` is rejected rather than read as
    /// `127.0.0.1`).
    ///
    /// # Errors
    ///
    /// [`ServerOriginError`] for other schemes, credentials or an invalid host or port.
    pub fn from_url_str(raw: &str) -> Result<Self, ServerOriginError> {
        let parts = UrlParts::split(raw)
            .ok_or_else(|| ServerOriginError::UnsupportedScheme(String::new()))?;
        let scheme = OriginScheme::parse(parts.scheme)?;
        let authority = parts.authority.ok_or(ServerOriginError::MissingHost)?;
        if authority.contains('@') {
            return Err(ServerOriginError::CredentialsNotAllowed);
        }
        let (host, port) = split_authority(authority)?;
        Self::new(scheme, host, port)
    }

    /// The scheme the link-style `host[:port]` gets: `http` for loopback, otherwise `https`.
    ///
    /// `normalized_host` must already be folded by [`ServerOrigin::new`].
    #[must_use]
    pub fn inferred_scheme(normalized_host: &str) -> OriginScheme {
        if LOOPBACK_HOSTS.contains(&normalized_host) {
            OriginScheme::Http
        } else {
            OriginScheme::Https
        }
    }

    /// The scheme.
    #[must_use]
    pub const fn scheme(&self) -> OriginScheme {
        self.scheme
    }

    /// Lowercased host; IPv6 literals keep their brackets, for example `[::1]`.
    #[must_use]
    pub fn host(&self) -> &str {
        &self.host
    }

    /// Explicit port, or `None` when it is the scheme's default.
    #[must_use]
    pub const fn port(&self) -> Option<u16> {
        self.port
    }

    /// Whether the host is this machine.
    #[must_use]
    pub fn is_loopback(&self) -> bool {
        LOOPBACK_HOSTS.contains(&self.host.as_str())
    }

    /// `host[:port]`, the form a deep link carries and a server label shows.
    #[must_use]
    pub fn authority(&self) -> String {
        self.port
            .map_or_else(|| self.host.clone(), |port| format!("{}:{port}", self.host))
    }

    /// `scheme://host[:port]` with no trailing slash, matching WHATWG `URL.origin`.
    #[must_use]
    pub fn serialized(&self) -> String {
        format!("{}://{}", self.scheme.as_str(), self.authority())
    }
}

impl fmt::Display for ServerOrigin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.serialized())
    }
}

/// Splits `host[:port]`. An empty port (`host:`) means the default, as in WHATWG URL.
pub(crate) fn split_authority(authority: &str) -> Result<(&str, Option<u16>), ServerOriginError> {
    if authority.is_empty() {
        return Err(ServerOriginError::MissingHost);
    }
    if authority.contains('@') {
        return Err(ServerOriginError::CredentialsNotAllowed);
    }
    let (host, port_text) = if authority.starts_with('[') {
        let close = authority
            .find(']')
            .ok_or_else(|| ServerOriginError::InvalidHost(authority.to_owned()))?;
        // `]` is one byte, so `close + 1` is a char boundary.
        let (host, rest) = authority.split_at(close + 1);
        if rest.is_empty() {
            (host, None)
        } else if let Some(port) = rest.strip_prefix(':') {
            (host, Some(port))
        } else {
            return Err(ServerOriginError::InvalidHost(authority.to_owned()));
        }
    } else if let Some((host, port)) = authority.split_once(':') {
        (host, Some(port))
    } else {
        (authority, None)
    };
    Ok((host, parse_port(port_text)?))
}

fn parse_port(text: Option<&str>) -> Result<Option<u16>, ServerOriginError> {
    let Some(text) = text.filter(|text| !text.is_empty()) else {
        return Ok(None);
    };
    if text.len() > 5 || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(ServerOriginError::InvalidPort(text.to_owned()));
    }
    text.parse::<u16>()
        .map(Some)
        .map_err(|_| ServerOriginError::InvalidPort(text.to_owned()))
}

fn normalized_host(raw: &str) -> Result<String, ServerOriginError> {
    if raw.is_empty() {
        return Err(ServerOriginError::MissingHost);
    }
    // Non-ASCII is rejected before case folding: Unicode lowercasing maps some non-ASCII scalars
    // (KELVIN SIGN) to ASCII letters.
    if !raw.is_ascii() {
        return Err(ServerOriginError::InvalidHost(raw.to_owned()));
    }
    let host = raw.to_ascii_lowercase();
    if host.starts_with('[') {
        let valid = host
            .strip_prefix('[')
            .and_then(|rest| rest.strip_suffix(']'))
            .is_some_and(|inner| {
                inner.contains(':')
                    && inner
                        .chars()
                        .all(|c| c.is_ascii_hexdigit() || c == ':' || c == '.')
            });
        return if valid {
            Ok(host)
        } else {
            Err(ServerOriginError::InvalidHost(raw.to_owned()))
        };
    }
    let host_characters = host
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '-' | '.' | '_'));
    if !host_characters || host.starts_with('.') || host.contains("..") {
        return Err(ServerOriginError::InvalidHost(raw.to_owned()));
    }
    reject_ambiguous_numeric_host(&host, raw)?;
    Ok(host)
}

/// WHATWG URL reinterprets a host whose last label is numeric (`0x7f000001`, `2130706433`,
/// `1.2.3`) as an IPv4 address. Only canonical dotted quads are accepted so the host compared is
/// the host the network stack connects to.
fn reject_ambiguous_numeric_host(host: &str, raw: &str) -> Result<(), ServerOriginError> {
    let invalid = || ServerOriginError::InvalidHost(raw.to_owned());
    let labels: Vec<&str> = host.split('.').collect();
    let trimmed = match labels.split_last() {
        Some((&"", rest)) => rest,
        _ => labels.as_slice(),
    };
    let last = trimmed.last().ok_or_else(invalid)?;
    let last_is_numeric = last.bytes().all(|byte| byte.is_ascii_digit())
        || last
            .strip_prefix("0x")
            .is_some_and(|hex| hex.bytes().all(|byte| byte.is_ascii_hexdigit()));
    if !last_is_numeric {
        return Ok(());
    }
    let canonical_quad = trimmed.len() == 4
        && labels.len() == 4
        && trimmed.iter().all(|label| {
            !label.is_empty()
                && label.len() <= 3
                && label.bytes().all(|byte| byte.is_ascii_digit())
                && (*label == "0" || !label.starts_with('0'))
                && label.parse::<u16>().is_ok_and(|value| value <= 255)
        });
    if canonical_quad {
        Ok(())
    } else {
        Err(invalid())
    }
}

/// `scheme:[//authority]path[?query][#fragment]`, split without decoding or normalizing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct UrlParts<'a> {
    pub(crate) scheme: &'a str,
    pub(crate) authority: Option<&'a str>,
    pub(crate) path: &'a str,
    pub(crate) query: Option<&'a str>,
    pub(crate) fragment: Option<&'a str>,
}

impl<'a> UrlParts<'a> {
    /// `None` when `raw` has no RFC 3986 scheme.
    pub(crate) fn split(raw: &'a str) -> Option<Self> {
        let (scheme, rest) = raw.split_once(':')?;
        let mut scheme_chars = scheme.chars();
        let valid_scheme = scheme_chars.next().is_some_and(|c| c.is_ascii_alphabetic())
            && scheme_chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
        if !valid_scheme {
            return None;
        }
        let (before_fragment, fragment) = match rest.split_once('#') {
            Some((before, fragment)) => (before, Some(fragment)),
            None => (rest, None),
        };
        let (hierarchy, query) = match before_fragment.split_once('?') {
            Some((hierarchy, query)) => (hierarchy, Some(query)),
            None => (before_fragment, None),
        };
        let (authority, path) = hierarchy
            .strip_prefix("//")
            .map_or((None, hierarchy), |after| {
                let (authority, path) = after.split_at(after.find('/').unwrap_or(after.len()));
                (Some(authority), path)
            });
        Some(Self {
            scheme,
            authority,
            path,
            query,
            fragment,
        })
    }
}

// MARK: - Deep links

/// Which shell's deep-link rules to apply. See the module docs for the differences.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum DeepLinkPolicy {
    /// The macOS desktop app (and the Electron shell it replaces): home links, the CLI
    /// acknowledgment, and a minimal session-id check.
    #[default]
    Desktop,
    /// The iOS app: conversation links only, a stricter session-id denylist, and no
    /// acknowledgment.
    Ios,
}

/// Why a string is not an `omnigent://` link the app handles.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeepLinkError {
    /// The scheme is missing or is not `omnigent`.
    UnsupportedScheme,
    /// There is no `//host` authority (`omnigent:` or `omnigent:///c/x`).
    MissingHost,
    /// The host or port is invalid.
    InvalidOrigin(ServerOriginError),
    /// The path is not one the policy routes. Carries the raw path.
    UnsupportedPath(String),
    /// The link contains whitespace or control characters.
    InvalidCharacters,
    /// `desktop_ack` is repeated or is not `<port>:<64 lowercase hex>`. Carries the value, or
    /// `"duplicate desktop_ack"`.
    InvalidAcknowledgment(String),
}

impl fmt::Display for DeepLinkError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedScheme => f.write_str("not an omnigent:// link"),
            Self::MissingHost => f.write_str("the link names no server"),
            Self::InvalidOrigin(error) => write!(f, "the link's server is invalid: {error}"),
            Self::UnsupportedPath(path) => write!(f, "unsupported deep link path '{path}'"),
            Self::InvalidCharacters => {
                f.write_str("the link contains whitespace or control characters")
            }
            Self::InvalidAcknowledgment(value) => {
                write!(f, "invalid {ACKNOWLEDGMENT_PARAMETER} '{value}'")
            }
        }
    }
}

impl std::error::Error for DeepLinkError {}

impl From<ServerOriginError> for DeepLinkError {
    fn from(error: ServerOriginError) -> Self {
        Self::InvalidOrigin(error)
    }
}

/// Where inside a server a deep link points.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum DeepLinkRoute {
    /// The server home, `omnigent://host` or `omnigent://host/`.
    Home,
    /// A conversation, `omnigent://host/c/<session_id>`. The id is percent-decoded.
    Conversation {
        /// The decoded session id.
        session_id: String,
    },
}

impl DeepLinkRoute {
    /// The basename-less SPA path, `/` or `/c/<id>`, with the id decoded (as the Swift shells
    /// expose it).
    #[must_use]
    pub fn path(&self) -> String {
        match self {
            Self::Home => "/".to_owned(),
            Self::Conversation { session_id } => format!("/c/{session_id}"),
        }
    }

    /// [`DeepLinkRoute::path`] with the id percent-encoded, safe to put in a URL path: no decoded
    /// `?`, `#`, `/` or `%` from the id can act as URL structure.
    #[must_use]
    pub fn encoded_path(&self) -> String {
        match self {
            Self::Home => "/".to_owned(),
            Self::Conversation { session_id } => format!("/c/{}", encode_segment(session_id)),
        }
    }
}

/// A one-time CLI handshake: `omnigent start --open-in-desktop` waits for
/// `POST http://127.0.0.1:<port>/desktop-open/<nonce>` before deciding not to open a browser.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DeepLinkAcknowledgment {
    port: u16,
    nonce: String,
}

impl DeepLinkAcknowledgment {
    /// Validates `port` (1 to 65535) and `nonce` (64 lowercase hex characters).
    ///
    /// # Errors
    ///
    /// [`DeepLinkError::InvalidAcknowledgment`].
    pub fn new(port: u16, nonce: &str) -> Result<Self, DeepLinkError> {
        Self::parse_value(&format!("{port}:{nonce}"))
    }

    /// IPv4 loopback port the CLI listens on, 1 to 65535.
    #[must_use]
    pub const fn port(&self) -> u16 {
        self.port
    }

    /// 64 lowercase hex characters.
    #[must_use]
    pub fn nonce(&self) -> &str {
        &self.nonce
    }

    /// The path the desktop POSTs to on `127.0.0.1:<port>`. Always loopback, never a URL supplied
    /// by the link.
    #[must_use]
    pub fn callback_path(&self) -> String {
        format!("/desktop-open/{}", self.nonce)
    }

    fn parse_value(value: &str) -> Result<Self, DeepLinkError> {
        let invalid = || DeepLinkError::InvalidAcknowledgment(value.to_owned());
        let mut parts = value.split(':');
        let (Some(port_text), Some(nonce), None) = (parts.next(), parts.next(), parts.next())
        else {
            return Err(invalid());
        };
        let port_ok = (1..=5).contains(&port_text.len())
            && !port_text.starts_with('0')
            && port_text.bytes().all(|byte| byte.is_ascii_digit());
        let nonce_ok = nonce.len() == 64
            && nonce
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte));
        if !port_ok || !nonce_ok {
            return Err(invalid());
        }
        let port = port_text.parse::<u16>().map_err(|_| invalid())?;
        Ok(Self {
            port,
            nonce: nonce.to_owned(),
        })
    }
}

/// Why a deep link could not be built.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeepLinkBuildError {
    /// A link carries no scheme, so an origin whose scheme differs from the inferred one
    /// (`https://localhost`, `http://example.com`) cannot be expressed.
    SchemeNotInferable(ServerOrigin),
    /// The built link would not parse back to the same value under the policy (for example a
    /// home route under [`DeepLinkPolicy::Ios`], or a session id the policy rejects).
    NotRoundTrippable(DeepLinkError),
    /// The built link parsed to a different value.
    Mismatch,
}

impl fmt::Display for DeepLinkBuildError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::SchemeNotInferable(origin) => {
                write!(f, "a deep link cannot carry the scheme of {origin}")
            }
            Self::NotRoundTrippable(error) => write!(f, "the link would be rejected: {error}"),
            Self::Mismatch => f.write_str("the link would parse to a different destination"),
        }
    }
}

impl std::error::Error for DeepLinkBuildError {}

/// A parsed `omnigent://<host>[:port][/c/<session>]` link.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct OmnigentDeepLink {
    /// The server origin with its inferred scheme.
    pub origin: ServerOrigin,
    /// The in-app destination.
    pub route: DeepLinkRoute,
    /// The CLI handshake, when the link came from `omnigent start --open-in-desktop`. Always
    /// `None` under [`DeepLinkPolicy::Ios`].
    pub acknowledgment: Option<DeepLinkAcknowledgment>,
}

impl OmnigentDeepLink {
    /// Parses a link with [`DeepLinkPolicy::Desktop`]. Queries other than `desktop_ack`, and
    /// fragments, are ignored.
    ///
    /// # Errors
    ///
    /// The first problem found, checked in order: characters, scheme, host, origin, path,
    /// acknowledgment.
    pub fn parse(raw: &str) -> Result<Self, DeepLinkError> {
        Self::parse_with(raw, DeepLinkPolicy::Desktop)
    }

    /// Parses a link under `policy`.
    ///
    /// # Errors
    ///
    /// See [`OmnigentDeepLink::parse`].
    pub fn parse_with(raw: &str, policy: DeepLinkPolicy) -> Result<Self, DeepLinkError> {
        // Leading and trailing C0 controls and spaces are stripped, as the WHATWG parser does.
        let trimmed = raw.trim_matches(|c: char| c <= ' ');
        if !trimmed.chars().all(|c| c > ' ' && c != '\u{7F}') {
            return Err(DeepLinkError::InvalidCharacters);
        }
        let Some((scheme, after_scheme)) = trimmed.split_once(':') else {
            return Err(DeepLinkError::UnsupportedScheme);
        };
        if !scheme.eq_ignore_ascii_case(SCHEME) {
            return Err(DeepLinkError::UnsupportedScheme);
        }
        let after_slashes = after_scheme
            .strip_prefix("//")
            .ok_or(DeepLinkError::MissingHost)?;
        let authority_end = after_slashes
            .find(['/', '?', '#'])
            .unwrap_or(after_slashes.len());
        let (authority, rest) = after_slashes.split_at(authority_end);
        if authority.is_empty() {
            return Err(DeepLinkError::MissingHost);
        }
        let path_end = rest.find(['?', '#']).unwrap_or(rest.len());
        let (path, after_path) = rest.split_at(path_end);
        let query = after_path
            .strip_prefix('?')
            .map_or("", |query| query.split_once('#').map_or(query, |(q, _)| q));

        let (host, port) = split_authority(authority)?;
        let host = normalized_host(host)?;
        let origin = ServerOrigin::new(ServerOrigin::inferred_scheme(&host), &host, port)?;
        let route = route(path, policy)?;
        let acknowledgment = match policy {
            DeepLinkPolicy::Desktop => acknowledgment(query)?,
            DeepLinkPolicy::Ios => None,
        };
        Ok(Self {
            origin,
            route,
            acknowledgment,
        })
    }

    /// Builds the `omnigent://` link for this value, checking that it parses back unchanged
    /// under `policy`.
    ///
    /// # Errors
    ///
    /// [`DeepLinkBuildError`] when the link cannot express this value.
    pub fn to_link(&self, policy: DeepLinkPolicy) -> Result<String, DeepLinkBuildError> {
        if ServerOrigin::inferred_scheme(self.origin.host()) != self.origin.scheme() {
            return Err(DeepLinkBuildError::SchemeNotInferable(self.origin.clone()));
        }
        let mut link = format!(
            "{SCHEME}://{}{}",
            self.origin.authority(),
            self.route.encoded_path()
        );
        if let Some(acknowledgment) = &self.acknowledgment {
            link.push('?');
            link.push_str(ACKNOWLEDGMENT_PARAMETER);
            link.push('=');
            link.push_str(&acknowledgment.port.to_string());
            link.push(':');
            link.push_str(&acknowledgment.nonce);
        }
        let parsed =
            Self::parse_with(&link, policy).map_err(DeepLinkBuildError::NotRoundTrippable)?;
        if &parsed == self {
            Ok(link)
        } else {
            Err(DeepLinkBuildError::Mismatch)
        }
    }
}

/// `""` and `/` are home (desktop only); `/c/<id>` and `/c/<id>/` are a conversation.
fn route(path: &str, policy: DeepLinkPolicy) -> Result<DeepLinkRoute, DeepLinkError> {
    let unsupported = || DeepLinkError::UnsupportedPath(path.to_owned());
    if path.is_empty() || path == "/" {
        return match policy {
            DeepLinkPolicy::Desktop => Ok(DeepLinkRoute::Home),
            DeepLinkPolicy::Ios => Err(unsupported()),
        };
    }
    let mut segments: Vec<&str> = path.split('/').collect();
    if segments.last().is_some_and(|segment| segment.is_empty()) {
        segments.pop();
    }
    let ["", "c", encoded] = segments.as_slice() else {
        return Err(unsupported());
    };
    if encoded.is_empty() {
        return Err(unsupported());
    }
    let session_id = percent_decoded(encoded).ok_or_else(unsupported)?;
    // Both policies use one denylist: it rejects characters that smuggle URL structure (`?`, `#`,
    // `/`), enable traversal (`.`), or signal a malformed or residual escape (`%`), plus control
    // characters. The SPA stays the authority on what an id is.
    let valid = !session_id.is_empty()
        && session_id
            .chars()
            .all(|c| !matches!(c, '?' | '#' | '/' | '.' | '%') && c >= ' ' && c != '\u{7F}');
    if valid {
        Ok(DeepLinkRoute::Conversation { session_id })
    } else {
        Err(unsupported())
    }
}

fn acknowledgment(query: &str) -> Result<Option<DeepLinkAcknowledgment>, DeepLinkError> {
    let mut values: Vec<String> = Vec::new();
    for pair in query.split('&').filter(|pair| !pair.is_empty()) {
        let (name, value) = match pair.split_once('=') {
            Some((name, value)) => (name, Some(value)),
            None => (pair, None),
        };
        if form_decoded(name).as_deref() != Some(ACKNOWLEDGMENT_PARAMETER) {
            continue;
        }
        match value {
            None => values.push(String::new()),
            Some(encoded) => values.push(
                form_decoded(encoded)
                    .ok_or_else(|| DeepLinkError::InvalidAcknowledgment(encoded.to_owned()))?,
            ),
        }
    }
    match values.as_slice() {
        [] => Ok(None),
        [value] => DeepLinkAcknowledgment::parse_value(value).map(Some),
        _ => Err(DeepLinkError::InvalidAcknowledgment(format!(
            "duplicate {ACKNOWLEDGMENT_PARAMETER}"
        ))),
    }
}

/// `application/x-www-form-urlencoded` decoding, as `URLSearchParams` does.
fn form_decoded(text: &str) -> Option<String> {
    percent_decoded(&text.replace('+', " "))
}

/// Percent-decodes UTF-8. A stray `%` is kept literally (WHATWG); invalid UTF-8 returns `None`.
pub(crate) fn percent_decoded(text: &str) -> Option<String> {
    let mut bytes = Vec::with_capacity(text.len());
    let mut input = text.bytes();
    while let Some(byte) = input.next() {
        if byte == b'%' {
            let mut lookahead = input.clone();
            if let (Some(high), Some(low)) = (
                lookahead.next().and_then(hex_value),
                lookahead.next().and_then(hex_value),
            ) {
                bytes.push((high << 4) | low);
                input = lookahead;
                continue;
            }
        }
        bytes.push(byte);
    }
    String::from_utf8(bytes).ok()
}

const fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// The upper-case hex digit for the low four bits of `value`.
fn hex_digit(value: u8) -> char {
    char::from(match value & 0x0F {
        digit @ 0..=9 => b'0' + digit,
        digit => b'A' + (digit - 10),
    })
}

/// Percent-encodes everything but RFC 3986 unreserved characters.
fn encode_segment(text: &str) -> String {
    let mut encoded = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            encoded.push(char::from(byte));
        } else {
            encoded.push('%');
            encoded.push(hex_digit(byte >> 4));
            encoded.push(hex_digit(byte));
        }
    }
    encoded
}

// MARK: - Conversation URL

/// Why a server URL cannot take a conversation route.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConversationUrlError {
    /// The server URL has no hierarchical path (`mailto:`, `data:`).
    NotHierarchical(String),
}

impl fmt::Display for ConversationUrlError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotHierarchical(url) => write!(f, "'{url}' cannot hold a conversation path"),
        }
    }
}

impl std::error::Error for ConversationUrlError {}

/// The URL that opens `route` on a server, port of iOS `AppRootView.conversationURL`: the route is
/// appended under the server URL's mount, and the query (`?o=` workspace selector) and fragment
/// are kept.
///
/// # Errors
///
/// [`ConversationUrlError::NotHierarchical`] for a URL without a path.
pub fn conversation_url(
    server_url: &Url,
    route: &DeepLinkRoute,
) -> Result<Url, ConversationUrlError> {
    if server_url.cannot_be_a_base() {
        return Err(ConversationUrlError::NotHierarchical(
            server_url.as_str().to_owned(),
        ));
    }
    let mount = server_url.path().trim_end_matches('/');
    let path = format!("{mount}{}", route.encoded_path());
    let mut url = server_url.clone();
    url.set_path(&path);
    Ok(url)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A real conversation id: a bare 32-char hex uuid, the form the API emits today.
    const HEX: &str = "e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9";
    const DASHED: &str = "e4f5a6b7-c8d9-e0f1-a2b3-c4d5e6f7a8b9";

    #[test]
    fn a_scheme_with_a_bad_first_character_is_not_a_url() {
        assert!(UrlParts::split("1http://example.com").is_none());
        assert!(UrlParts::split("ht tp://example.com").is_none());
        assert!(UrlParts::split("http://example.com").is_some());
    }

    #[test]
    fn every_error_reads_as_a_sentence() {
        for (error, text) in [
            (
                ServerOriginError::UnsupportedScheme("ftp".into()).to_string(),
                "unsupported scheme 'ftp'",
            ),
            (ServerOriginError::MissingHost.to_string(), "missing host"),
            (
                ServerOriginError::InvalidHost("a b".into()).to_string(),
                "invalid host 'a b'",
            ),
            (
                ServerOriginError::InvalidPort("x".into()).to_string(),
                "invalid port 'x'",
            ),
            (
                ServerOriginError::CredentialsNotAllowed.to_string(),
                "credentials are not allowed",
            ),
            (
                DeepLinkError::UnsupportedScheme.to_string(),
                "not an omnigent:// link",
            ),
            (
                DeepLinkError::MissingHost.to_string(),
                "the link names no server",
            ),
            (
                DeepLinkError::InvalidOrigin(ServerOriginError::MissingHost).to_string(),
                "the link's server is invalid: missing host",
            ),
            (
                DeepLinkError::UnsupportedPath("/x".into()).to_string(),
                "unsupported deep link path '/x'",
            ),
            (
                DeepLinkError::InvalidCharacters.to_string(),
                "the link contains whitespace or control characters",
            ),
            (
                DeepLinkBuildError::Mismatch.to_string(),
                "the link would parse to a different destination",
            ),
            (
                DeepLinkBuildError::NotRoundTrippable(DeepLinkError::MissingHost).to_string(),
                "the link would be rejected: the link names no server",
            ),
            (
                ConversationUrlError::NotHierarchical("mailto:a".into()).to_string(),
                "'mailto:a' cannot hold a conversation path",
            ),
        ] {
            assert_eq!(error, text);
        }
        assert!(
            DeepLinkError::InvalidAcknowledgment("x".into())
                .to_string()
                .ends_with(" 'x'")
        );
        assert!(
            DeepLinkBuildError::SchemeNotInferable(ServerOrigin::parse("http://a").unwrap())
                .to_string()
                .contains("http://a")
        );
    }

    #[test]
    fn hostile_authorities_and_paths_are_refused() {
        assert_eq!(
            ServerOrigin::parse("http://[::1]x"),
            Err(ServerOriginError::InvalidHost("[::1]x".into()))
        );
        assert_eq!(
            OmnigentDeepLink::parse("1bad:omnigent"),
            Err(DeepLinkError::UnsupportedScheme)
        );
        assert!(matches!(
            OmnigentDeepLink::parse("omnigent://example.com/c///"),
            Err(DeepLinkError::UnsupportedPath(_))
        ));
    }

    fn ios(raw: &str) -> Result<OmnigentDeepLink, DeepLinkError> {
        OmnigentDeepLink::parse_with(raw, DeepLinkPolicy::Ios)
    }

    fn ios_ok(raw: &str) -> (String, String) {
        let link = ios(raw).unwrap();
        (link.origin.serialized(), link.route.path())
    }

    fn desktop(raw: &str) -> Result<OmnigentDeepLink, DeepLinkError> {
        OmnigentDeepLink::parse(raw)
    }

    fn conversation(id: &str) -> DeepLinkRoute {
        DeepLinkRoute::Conversation {
            session_id: id.to_owned(),
        }
    }

    fn is_unsupported_path(result: &Result<OmnigentDeepLink, DeepLinkError>) -> bool {
        matches!(result, Err(DeepLinkError::UnsupportedPath(_)))
    }

    // MARK: web/ios DeepLinkTests.swift

    #[test]
    fn deeplink_loopback_host_maps_to_http() {
        let path = format!("/c/{HEX}");
        assert_eq!(
            ios_ok(&format!("omnigent://localhost:8000/c/{HEX}")),
            ("http://localhost:8000".to_owned(), path.clone())
        );
        assert_eq!(
            ios_ok(&format!("omnigent://127.0.0.1:8000/c/{HEX}")),
            ("http://127.0.0.1:8000".to_owned(), path)
        );
    }

    #[test]
    fn deeplink_remote_host_maps_to_https() {
        assert_eq!(
            ios_ok(&format!(
                "omnigent://my-workspace.cloud.databricks.com/c/{HEX}"
            )),
            (
                "https://my-workspace.cloud.databricks.com".to_owned(),
                format!("/c/{HEX}")
            )
        );
    }

    #[test]
    fn deeplink_keeps_non_default_port_remote() {
        assert_eq!(
            ios_ok(&format!("omnigent://example.com:8443/c/{HEX}")),
            ("https://example.com:8443".to_owned(), format!("/c/{HEX}"))
        );
    }

    #[test]
    fn deeplink_ipv6_loopback_maps_to_http() {
        assert_eq!(
            ios_ok(&format!("omnigent://[::1]:8000/c/{HEX}")),
            ("http://[::1]:8000".to_owned(), format!("/c/{HEX}"))
        );
    }

    #[test]
    fn deeplink_strips_trailing_slash() {
        assert_eq!(
            ios_ok(&format!("omnigent://localhost:8000/c/{HEX}/")).1,
            format!("/c/{HEX}")
        );
    }

    #[test]
    fn deeplink_accepts_dashed_uuid() {
        assert_eq!(
            ios_ok(&format!("omnigent://localhost:8000/c/{DASHED}")),
            ("http://localhost:8000".to_owned(), format!("/c/{DASHED}"))
        );
    }

    #[test]
    fn deeplink_accepts_conv_prefix() {
        assert_eq!(
            ios_ok(&format!("omnigent://localhost:8000/c/conv_{HEX}")).1,
            format!("/c/conv_{HEX}")
        );
    }

    #[test]
    fn deeplink_accepts_ag_prefix() {
        assert_eq!(
            ios_ok(&format!("omnigent://localhost:8000/c/ag_{HEX}")).1,
            format!("/c/ag_{HEX}")
        );
    }

    #[test]
    fn deeplink_accepts_uppercase_hex() {
        let upper = HEX.to_uppercase();
        assert_eq!(
            ios_ok(&format!("omnigent://localhost:8000/c/{upper}")).1,
            format!("/c/{upper}")
        );
    }

    #[test]
    fn deeplink_rejects_non_omnigent_scheme() {
        for raw in [
            format!("https://localhost:8000/c/{HEX}"),
            format!("vscode://localhost/c/{HEX}"),
        ] {
            assert_eq!(ios(&raw), Err(DeepLinkError::UnsupportedScheme), "{raw}");
        }
    }

    #[test]
    fn deeplink_rejects_missing_host() {
        assert_eq!(ios("omnigent://"), Err(DeepLinkError::MissingHost));
        assert_eq!(
            ios(&format!("omnigent:///c/{HEX}")),
            Err(DeepLinkError::MissingHost)
        );
    }

    #[test]
    fn deeplink_rejects_non_conversation_paths() {
        for raw in [
            "omnigent://localhost:8000/inbox".to_owned(),
            "omnigent://localhost:8000/settings/appearance".to_owned(),
            "omnigent://localhost:8000/c/".to_owned(),
            format!("omnigent://localhost:8000/c/{HEX}/extra"),
            // iOS has no home route.
            "omnigent://localhost:8000/".to_owned(),
            "omnigent://localhost:8000".to_owned(),
        ] {
            assert!(is_unsupported_path(&ios(&raw)), "{raw}");
        }
    }

    #[test]
    fn deeplink_rejects_smuggled_query() {
        let raw = format!("omnigent://localhost:8000/c/{HEX}%3Fview=terminal");
        assert!(is_unsupported_path(&ios(&raw)));
        assert!(is_unsupported_path(&desktop(&raw)));
    }

    #[test]
    fn deeplink_rejects_smuggled_fragment() {
        assert!(is_unsupported_path(&ios(&format!(
            "omnigent://localhost:8000/c/{HEX}%23frag"
        ))));
    }

    #[test]
    fn deeplink_rejects_encoded_separator() {
        let raw = format!("omnigent://localhost:8000/c/{HEX}%2Fextra");
        assert!(is_unsupported_path(&ios(&raw)));
        assert!(is_unsupported_path(&desktop(&raw)));
    }

    #[test]
    fn deeplink_rejects_dot_segments() {
        for raw in [
            format!("omnigent://localhost:8000/c/{HEX}%2E."),
            "omnigent://localhost:8000/c/%2e%2e".to_owned(),
            "omnigent://localhost:8000/c/..".to_owned(),
        ] {
            assert!(is_unsupported_path(&ios(&raw)), "{raw}");
            assert!(is_unsupported_path(&desktop(&raw)), "{raw}");
        }
    }

    #[test]
    fn deeplink_rejects_control_chars() {
        for escape in ["%00", "%0A", "%7F"] {
            let raw = format!("omnigent://localhost:8000/c/{HEX}{escape}x");
            assert!(is_unsupported_path(&ios(&raw)), "{raw}");
        }
        assert!(is_unsupported_path(&desktop(&format!(
            "omnigent://localhost:8000/c/{HEX}%0Ax"
        ))));
        assert!(is_unsupported_path(&desktop(
            "omnigent://localhost:8000/c/a%7Fx"
        )));
    }

    #[test]
    fn deeplink_rejects_malformed_percent() {
        let raw = format!("omnigent://localhost:8000/c/{HEX}%zz");
        assert!(is_unsupported_path(&ios(&raw)));
        assert!(is_unsupported_path(&desktop(&raw)));
    }

    #[test]
    fn deeplink_accepts_benign_non_canonical_ids() {
        let short = HEX.get(..31).unwrap();
        for raw in [
            "omnigent://localhost:8000/c/conv_abc".to_owned(),
            "omnigent://localhost:8000/c/x".to_owned(),
            "omnigent://localhost:8000/c/not-a-uuid".to_owned(),
            format!("omnigent://localhost:8000/c/{short}"),
            format!("omnigent://localhost:8000/c/{HEX}g"),
            format!("omnigent://localhost:8000/c/host_{HEX}"),
            format!("omnigent://localhost:8000/c/conv_{HEX}"),
        ] {
            assert!(ios(&raw).is_ok(), "{raw}");
        }
    }

    #[test]
    fn deeplink_conversation_url_preserves_query_and_fragment() {
        for (base, expected) in [
            (
                "https://workspace.databricks.com/omnigent?o=123",
                "https://workspace.databricks.com/omnigent/c/abc?o=123",
            ),
            (
                "https://workspace.databricks.com/omnigent/?o=123#view",
                "https://workspace.databricks.com/omnigent/c/abc?o=123#view",
            ),
            ("http://localhost:8000/", "http://localhost:8000/c/abc"),
            (
                "https://example.com/custom%20mount?view=chat",
                "https://example.com/custom%20mount/c/abc?view=chat",
            ),
        ] {
            let url = conversation_url(&Url::parse(base).unwrap(), &conversation("abc")).unwrap();
            assert_eq!(url.as_str(), expected, "{base}");
        }
    }

    #[test]
    fn conversation_url_encodes_decoded_structure_and_rejects_opaque_urls() {
        let url = conversation_url(
            &Url::parse("https://h.example.com/m").unwrap(),
            &conversation("a?b#c/d%e f"),
        )
        .unwrap();
        assert_eq!(
            url.as_str(),
            "https://h.example.com/m/c/a%3Fb%23c%2Fd%25e%20f"
        );
        assert!(url.query().is_none() && url.fragment().is_none());
        assert_eq!(
            conversation_url(&Url::parse("mailto:a@b.c").unwrap(), &DeepLinkRoute::Home),
            Err(ConversationUrlError::NotHierarchical(
                "mailto:a@b.c".to_owned()
            ))
        );
    }

    // MARK: OmnigentDesktop DeepLinkTests.swift ("Deep link parsing")

    #[test]
    fn desktop_loopback_is_http() {
        let link = desktop("omnigent://localhost:8000/c/conv_abc").unwrap();
        assert_eq!(link.origin.serialized(), "http://localhost:8000");
        assert_eq!(link.route, conversation("conv_abc"));
        assert_eq!(link.route.path(), "/c/conv_abc");
        assert_eq!(
            desktop("omnigent://127.0.0.1:8000/c/x")
                .unwrap()
                .origin
                .serialized(),
            "http://127.0.0.1:8000"
        );
    }

    #[test]
    fn desktop_remote_is_https() {
        let link = desktop("omnigent://my-workspace.cloud.databricks.com/c/x").unwrap();
        assert_eq!(
            link.origin.serialized(),
            "https://my-workspace.cloud.databricks.com"
        );
        assert_eq!(link.route, conversation("x"));
    }

    #[test]
    fn desktop_remote_port() {
        assert_eq!(
            desktop("omnigent://example.com:8443/c/x")
                .unwrap()
                .origin
                .serialized(),
            "https://example.com:8443"
        );
    }

    #[test]
    fn desktop_ipv6_loopback() {
        let link = desktop("omnigent://[::1]:8000/c/x").unwrap();
        assert_eq!(link.origin.serialized(), "http://[::1]:8000");
        assert!(link.origin.is_loopback());
    }

    #[test]
    fn desktop_trailing_slash() {
        assert_eq!(
            desktop("omnigent://localhost:8000/c/conv_abc/")
                .unwrap()
                .route,
            conversation("conv_abc")
        );
    }

    #[test]
    fn desktop_drops_query_and_hash() {
        let link = desktop("omnigent://localhost:8000/c/conv_abc?reply=1#frag").unwrap();
        assert_eq!(link.route, conversation("conv_abc"));
        assert_eq!(link.origin.serialized(), "http://localhost:8000");
        assert_eq!(link.acknowledgment, None);
    }

    #[test]
    fn desktop_rejects_other_schemes() {
        for raw in ["https://localhost:8000/c/x", "vscode://localhost/c/x"] {
            assert_eq!(desktop(raw), Err(DeepLinkError::UnsupportedScheme), "{raw}");
        }
    }

    #[test]
    fn desktop_rejects_missing_host() {
        for raw in ["omnigent://", "omnigent:///c/x", "omnigent:c/x"] {
            assert_eq!(desktop(raw), Err(DeepLinkError::MissingHost), "{raw}");
        }
    }

    #[test]
    fn desktop_home_route() {
        for raw in ["omnigent://localhost:8000/", "omnigent://localhost:8000"] {
            let link = desktop(raw).unwrap();
            assert_eq!(link.origin.serialized(), "http://localhost:8000");
            assert_eq!(link.route, DeepLinkRoute::Home);
            assert_eq!(link.route.path(), "/");
        }
    }

    #[test]
    fn desktop_rejects_other_paths() {
        for raw in [
            "omnigent://localhost:8000/inbox",
            "omnigent://localhost:8000/settings/appearance",
            "omnigent://localhost:8000/c/",
            "omnigent://localhost:8000/c/a/b",
            "omnigent://localhost:8000//",
        ] {
            assert!(is_unsupported_path(&desktop(raw)), "{raw}");
        }
    }

    #[test]
    fn desktop_rejects_garbage() {
        assert_eq!(desktop("not a url"), Err(DeepLinkError::InvalidCharacters));
        assert_eq!(desktop(""), Err(DeepLinkError::UnsupportedScheme));
        assert_eq!(desktop("123"), Err(DeepLinkError::UnsupportedScheme));
        assert_eq!(
            desktop("omnigent://local host/c/x"),
            Err(DeepLinkError::InvalidCharacters)
        );
    }

    #[test]
    fn desktop_normalization() {
        let origin = |raw: &str| desktop(raw).unwrap().origin.serialized();
        assert_eq!(
            origin("  OMNIGENT://Example.COM:443/c/x\n"),
            "https://example.com"
        );
        assert_eq!(origin("omnigent://LOCALHOST/c/x"), "http://localhost");
        assert_eq!(origin("omnigent://localhost:80/"), "http://localhost");
        assert_eq!(origin("omnigent://localhost:/"), "http://localhost");
    }

    #[test]
    fn desktop_non_loopback_literals() {
        let origin = |raw: &str| desktop(raw).unwrap().origin.serialized();
        assert_eq!(
            origin("omnigent://10.0.0.5:8000/c/x"),
            "https://10.0.0.5:8000"
        );
        assert_eq!(origin("omnigent://[fe80::1]/c/x"), "https://[fe80::1]");
    }

    #[test]
    fn desktop_decodes_session_id() {
        assert_eq!(
            desktop("omnigent://localhost/c/conv%5Fabc").unwrap().route,
            conversation("conv_abc")
        );
        assert!(is_unsupported_path(&desktop(
            "omnigent://localhost/c/a%2Fb"
        )));
        // Invalid UTF-8 after decoding is not a session id.
        assert!(is_unsupported_path(&desktop("omnigent://localhost/c/%FF")));
    }

    #[test]
    fn desktop_rejects_invalid_origins() {
        for (raw, expected) in [
            (
                "omnigent://trusted.example.com@evil.example.com/c/x",
                ServerOriginError::CredentialsNotAllowed,
            ),
            (
                "omnigent://0x7f000001/c/x",
                ServerOriginError::InvalidHost("0x7f000001".into()),
            ),
            (
                "omnigent://2130706433/c/x",
                ServerOriginError::InvalidHost("2130706433".into()),
            ),
            (
                "omnigent://1.2.3/c/x",
                ServerOriginError::InvalidHost("1.2.3".into()),
            ),
            (
                "omnigent://127.0.0.01/c/x",
                ServerOriginError::InvalidHost("127.0.0.01".into()),
            ),
            (
                "omnigent://exa%6Dple.com/c/x",
                ServerOriginError::InvalidHost("exa%6Dple.com".into()),
            ),
            (
                "omnigent://caf\u{E9}.example/c/x",
                ServerOriginError::InvalidHost("caf\u{E9}.example".into()),
            ),
            (
                "omnigent://[::1/c/x",
                ServerOriginError::InvalidHost("[::1".into()),
            ),
            (
                "omnigent://localhost:99999/c/x",
                ServerOriginError::InvalidPort("99999".into()),
            ),
            (
                "omnigent://localhost:80a/c/x",
                ServerOriginError::InvalidPort("80a".into()),
            ),
        ] {
            assert_eq!(
                desktop(raw),
                Err(DeepLinkError::InvalidOrigin(expected.clone())),
                "{raw}"
            );
            // The origin grammar is shared by both policies.
            assert_eq!(
                ios(raw),
                Err(DeepLinkError::InvalidOrigin(expected)),
                "{raw}"
            );
        }
    }

    // MARK: OmnigentDesktop DeepLinkTests.swift ("CLI navigation acknowledgment")

    fn token() -> String {
        "a".repeat(64)
    }

    #[test]
    fn acknowledgment_absent_on_ordinary_links() {
        assert_eq!(
            desktop("omnigent://localhost:6767/")
                .unwrap()
                .acknowledgment,
            None
        );
    }

    #[test]
    fn acknowledgment_parses() {
        let token = token();
        let link = desktop(&format!("omnigent://localhost/?desktop_ack=1234:{token}")).unwrap();
        let acknowledgment = link.acknowledgment.unwrap();
        assert_eq!(
            acknowledgment,
            DeepLinkAcknowledgment::new(1234, &token).unwrap()
        );
        assert_eq!(acknowledgment.port(), 1234);
        assert_eq!(acknowledgment.nonce(), token);
        assert_eq!(
            acknowledgment.callback_path(),
            format!("/desktop-open/{token}")
        );
        assert_eq!(
            desktop(&format!("omnigent://localhost/?desktop_ack=1234%3A{token}"))
                .unwrap()
                .acknowledgment
                .map(|ack| ack.port()),
            Some(1234)
        );
    }

    #[test]
    fn acknowledgment_rejects_malformed() {
        let token = token();
        for value in [
            String::new(),
            format!("0:{token}"),
            format!("65536:{token}"),
            "123:bad".to_owned(),
            "https://example.com".to_owned(),
            format!("1234:{}", token.to_uppercase()),
        ] {
            let result = desktop(&format!("omnigent://localhost/?desktop_ack={value}"));
            assert!(
                matches!(result, Err(DeepLinkError::InvalidAcknowledgment(_))),
                "{value}: {result:?}"
            );
        }
        // A bare `desktop_ack` with no `=` is an empty, invalid value.
        assert_eq!(
            desktop("omnigent://localhost/?desktop_ack"),
            Err(DeepLinkError::InvalidAcknowledgment(String::new()))
        );
        assert!(DeepLinkAcknowledgment::new(0, &token).is_err());
    }

    #[test]
    fn acknowledgment_rejects_duplicates_and_routes() {
        let token = token();
        assert_eq!(
            desktop(&format!(
                "omnigent://localhost/?desktop_ack=123:{token}&desktop_ack=123:{token}"
            )),
            Err(DeepLinkError::InvalidAcknowledgment(
                "duplicate desktop_ack".into()
            ))
        );
        assert_eq!(
            desktop(&format!(
                "omnigent://localhost/settings?desktop_ack=123:{token}"
            )),
            Err(DeepLinkError::UnsupportedPath("/settings".into()))
        );
    }

    #[test]
    fn ios_policy_ignores_acknowledgment() {
        let link = ios(&format!("omnigent://localhost/c/x?desktop_ack=bad#{HEX}")).unwrap();
        assert_eq!(link.acknowledgment, None);
    }

    // MARK: Building

    #[test]
    fn builds_links_that_round_trip() {
        let token = token();
        let link = desktop(&format!(
            "omnigent://LOCALHOST:8000/c/a%20b?desktop_ack=9:{token}"
        ))
        .unwrap();
        let built = link.to_link(DeepLinkPolicy::Desktop).unwrap();
        assert_eq!(
            built,
            format!("omnigent://localhost:8000/c/a%20b?desktop_ack=9:{token}")
        );
        assert_eq!(desktop(&built).unwrap(), link);

        let home = desktop("omnigent://example.com:8443").unwrap();
        assert_eq!(
            home.to_link(DeepLinkPolicy::Desktop).unwrap(),
            "omnigent://example.com:8443/"
        );
        assert!(matches!(
            home.to_link(DeepLinkPolicy::Ios),
            Err(DeepLinkBuildError::NotRoundTrippable(
                DeepLinkError::UnsupportedPath(_)
            ))
        ));
    }

    #[test]
    fn build_rejects_values_a_link_cannot_carry() {
        let https_loopback = OmnigentDeepLink {
            origin: ServerOrigin::new(OriginScheme::Https, "localhost", None).unwrap(),
            route: DeepLinkRoute::Home,
            acknowledgment: None,
        };
        assert!(matches!(
            https_loopback.to_link(DeepLinkPolicy::Desktop),
            Err(DeepLinkBuildError::SchemeNotInferable(_))
        ));
        let slash = OmnigentDeepLink {
            origin: ServerOrigin::new(OriginScheme::Https, "example.com", None).unwrap(),
            route: conversation("a/b"),
            acknowledgment: None,
        };
        assert!(matches!(
            slash.to_link(DeepLinkPolicy::Desktop),
            Err(DeepLinkBuildError::NotRoundTrippable(_))
        ));
        let dotted = OmnigentDeepLink {
            route: conversation("a.b"),
            ..slash
        };
        assert!(dotted.to_link(DeepLinkPolicy::Desktop).is_err());
        assert!(dotted.to_link(DeepLinkPolicy::Ios).is_err());
    }

    // MARK: ServerOrigin

    #[test]
    fn origin_parses_serialized_and_urls() {
        let origin = ServerOrigin::parse("HTTPS://Example.com:443/").unwrap();
        assert_eq!(origin.serialized(), "https://example.com");
        assert_eq!(origin.to_string(), "https://example.com");
        assert_eq!(origin.authority(), "example.com");
        assert_eq!(
            ServerOrigin::parse("ftp://example.com"),
            Err(ServerOriginError::UnsupportedScheme("ftp".into()))
        );
        assert_eq!(
            ServerOrigin::parse("example.com"),
            Err(ServerOriginError::UnsupportedScheme("example.com".into()))
        );
        assert_eq!(
            ServerOrigin::from_url_str("http://[::1]:6767/omnigent/?o=1#x")
                .unwrap()
                .serialized(),
            "http://[::1]:6767"
        );
        assert_eq!(
            ServerOrigin::from_url_str("https://u:p@example.com/"),
            Err(ServerOriginError::CredentialsNotAllowed)
        );
        assert_eq!(
            ServerOrigin::from_url_str("hand-edited-invalid-value"),
            Err(ServerOriginError::UnsupportedScheme(String::new()))
        );
        assert_eq!(
            ServerOrigin::from_url_str("https:/path-only"),
            Err(ServerOriginError::MissingHost)
        );
        assert_eq!(
            ServerOrigin::from_url_str("https://"),
            Err(ServerOriginError::MissingHost)
        );
    }

    #[test]
    fn origin_host_grammar_edges() {
        let host = |raw: &str| ServerOrigin::new(OriginScheme::Https, raw, None);
        assert_eq!(host("A-B_c.Example.").unwrap().host(), "a-b_c.example.");
        assert_eq!(host("1.2.3.4").unwrap().host(), "1.2.3.4");
        assert!(host("1.2.3.4.").is_err());
        assert!(host("256.1.1.1").is_err());
        assert!(host("0x").is_err());
        assert!(host("v1.0x1g").is_ok());
        assert!(host(".example.com").is_err());
        assert!(host("a..b").is_err());
        assert!(host("[]").is_err());
        assert!(host("[1234]").is_err());
        assert!(host("[::G]").is_err());
        assert_eq!(host("").unwrap_err(), ServerOriginError::MissingHost);
        // KELVIN SIGN would lowercase to an ASCII `k`.
        assert!(host("\u{212A}.example").is_err());
        let origin = ServerOrigin::new(OriginScheme::Http, "Example.com", Some(80)).unwrap();
        assert_eq!(origin.port(), None);
        assert_eq!(origin.scheme(), OriginScheme::Http);
        assert!(!origin.is_loopback());
    }

    #[test]
    fn percent_decoding_is_lenient_about_stray_percent() {
        assert_eq!(percent_decoded("a%2"), Some("a%2".to_owned()));
        assert_eq!(percent_decoded("%e2%82%ac"), Some("\u{20AC}".to_owned()));
        assert_eq!(percent_decoded("%e2%82"), None);
        assert_eq!(form_decoded("a+b%2B"), Some("a b+".to_owned()));
    }
}
