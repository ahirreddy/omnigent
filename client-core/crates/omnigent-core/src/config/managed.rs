//! Organization-provided (MDM) server lists and feature flags.
//!
//! Ports `web/ios/Omnigent/ManagedConfiguration.swift` (iOS managed app configuration) and
//! `apps/apple/Packages/OmnigentDesktop/Sources/OmnigentDesktop/Preferences/ManagedPreferences.swift`
//! (macOS managed preferences, itself a port of `web/electron/src/managed_preferences.js`).
//!
//! The host reads the raw value from the OS and hands it over as a [`serde_json::Value`]: a
//! dictionary for the iOS `AppConfig` payload or `com.apple.configuration.managed` defaults key,
//! or one key at a time through [`ManagedPreferenceSource`] on macOS. Hosts must map a property
//! list boolean (`CFBoolean`) to [`Value::Bool`] and a number (`NSNumber`) to [`Value::Number`],
//! so that `1` is never read as `true`.
//!
//! A `serverUrls` list is validated as a unit: one bad entry rejects the whole list with a typed
//! [`ManagedConfigError`], never a silently shortened or empty list. Managed servers are merged
//! with the user's recents at read time and never written to settings, so withdrawing a profile
//! removes them.
//!
//! # iOS and desktop
//!
//! [`ManagedDialect`] selects the rules:
//!
//! | | [`ManagedDialect::Ios`] | [`ManagedDialect::Desktop`] |
//! |---|---|---|
//! | entry normalization | [`crate::server_url::normalize`] with insecure http refused; a bare origin keeps no trailing slash (`https://h`) | own grammar; the path defaults to `/` (`https://h/`), the rest kept byte for byte |
//! | hosts | anything the URL parser accepts (numeric hosts are canonicalized) | [`ServerOrigin`] grammar: no credentials, ambiguous numeric or non-ASCII hosts |
//! | `omnigentServerName` query item | kept in the URL | removed and used as the display name |
//! | a non-string entry | [`ManagedConfigError::ServerUrlsNotAnArray`] | [`ManagedConfigError::InvalidServer`] with [`ManagedEntryError::NotAString`] |
//! | a non-boolean `databricksInternalFeaturesEnabled` | fails closed to `false`, keeps the servers, and is recorded in [`ManagedConfiguration::issues`] | [`ManagedConfigError::NotABoolean`] |
//! | channels | declarative wins over the legacy defaults key ([`ManagedConfiguration::resolve`]) | first domain that sets a key wins ([`ManagedPreferences`]) |
//!
//! Electron returns an empty list (and `false`) for every invalid value instead of an error.

use std::collections::HashSet;
use std::fmt;

use serde_json::Value;

use crate::config::origin_identity;
use crate::deeplink::{OriginScheme, ServerOrigin, ServerOriginError, UrlParts, percent_decoded};
use crate::server_url::{self, ServerUrlError};

/// The array of server URL strings.
pub const SERVER_URLS_KEY: &str = "serverUrls";
/// Boolean gating Databricks-internal features. Only an explicit `true` enables them.
pub const DATABRICKS_INTERNAL_FEATURES_KEY: &str = "databricksInternalFeaturesEnabled";
/// Query parameter naming a server inside a desktop `serverUrls` entry.
pub const SERVER_NAME_PARAMETER: &str = "omnigentServerName";
/// Bounds the list so it cannot crowd the user's own servers off the connect screen.
pub const MAX_SERVER_URLS: usize = 10;
/// The iOS defaults key a management service writes for classic managed app configuration.
pub const IOS_LEGACY_DEFAULTS_KEY: &str = "com.apple.configuration.managed";
/// The native macOS app's domain first, then the Electron app's, so existing profiles keep
/// working.
pub const DESKTOP_DEFAULT_DOMAINS: [&str; 2] = ["ai.omnigent.mac", "ai.omnigent.desktop"];

/// Published iOS error code: an entry is not a valid server URL.
pub const IOS_INVALID_URL_CODE: u16 = 100;
/// Published iOS error code: an entry does not use https.
pub const IOS_NOT_HTTPS_CODE: u16 = 101;
/// Published iOS error code: more than [`MAX_SERVER_URLS`] entries.
pub const IOS_TOO_MANY_ENTRIES_CODE: u16 = 102;
/// Published iOS error code: `serverUrls` is not an array of strings.
pub const IOS_WRONG_TYPE_CODE: u16 = 103;

/// Which shell's managed-configuration rules to apply. See the module docs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ManagedDialect {
    /// iOS managed app configuration (`ManagedConfiguration.swift`).
    Ios,
    /// macOS managed preferences (`ManagedPreferences.swift`, Electron's `managed_preferences.js`).
    Desktop,
}

/// Why one `serverUrls` entry was rejected.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ManagedEntryError {
    /// The entry is not a string.
    NotAString,
    /// The entry is empty or whitespace.
    Empty,
    /// The entry does not parse as a URL.
    InvalidUrl,
    /// The entry uses a scheme other than https.
    NotHttps,
    /// The entry contains a user name or password.
    Credentials,
    /// The entry has no host.
    NoHost,
    /// The host or port is invalid.
    InvalidOrigin(ServerOriginError),
}

impl fmt::Display for ManagedEntryError {
    /// The desktop app's human-readable reason, for example `must use https://`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotAString => f.write_str("is not a string"),
            Self::Empty => f.write_str("is empty"),
            Self::InvalidUrl => f.write_str("is not a valid URL"),
            Self::NotHttps => f.write_str("must use https://"),
            Self::Credentials => f.write_str("must not contain credentials"),
            Self::NoHost => f.write_str("has no host"),
            Self::InvalidOrigin(error) => write!(f, "has an invalid host or port ({error})"),
        }
    }
}

impl std::error::Error for ManagedEntryError {}

/// Why a managed configuration was rejected. The whole value is rejected, never applied in part.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ManagedConfigError {
    /// The configuration payload is not a dictionary.
    NotADictionary,
    /// `serverUrls` is not an array (iOS: not an array of strings).
    ServerUrlsNotAnArray {
        /// The preferences domain, when read through [`ManagedPreferences`].
        domain: Option<String>,
    },
    /// `serverUrls` has more than [`MAX_SERVER_URLS`] entries.
    TooManyServers {
        /// The preferences domain, if any.
        domain: Option<String>,
        /// How many entries were configured.
        count: usize,
    },
    /// One entry is invalid.
    InvalidServer {
        /// The preferences domain, if any.
        domain: Option<String>,
        /// Zero-based position in `serverUrls`.
        index: usize,
        /// The entry as configured (JSON text when it is not a string).
        entry: String,
        /// What is wrong with it.
        error: ManagedEntryError,
    },
    /// A boolean key holds another type.
    NotABoolean {
        /// The preferences domain, if any.
        domain: Option<String>,
        /// The key.
        key: String,
    },
}

impl ManagedConfigError {
    /// The published iOS `ManagedAppConfigurationDecodingErrorCode` raw value. The iOS shell
    /// reports it to the management service, so these values are API.
    #[must_use]
    pub const fn ios_code(&self) -> u16 {
        match self {
            Self::NotADictionary | Self::ServerUrlsNotAnArray { .. } | Self::NotABoolean { .. } => {
                IOS_WRONG_TYPE_CODE
            }
            Self::TooManyServers { .. } => IOS_TOO_MANY_ENTRIES_CODE,
            Self::InvalidServer {
                error: ManagedEntryError::NotHttps,
                ..
            } => IOS_NOT_HTTPS_CODE,
            Self::InvalidServer { .. } => IOS_INVALID_URL_CODE,
        }
    }

    /// The preferences domain the value came from, if any.
    #[must_use]
    pub fn domain(&self) -> Option<&str> {
        match self {
            Self::NotADictionary => None,
            Self::ServerUrlsNotAnArray { domain }
            | Self::TooManyServers { domain, .. }
            | Self::InvalidServer { domain, .. }
            | Self::NotABoolean { domain, .. } => domain.as_deref(),
        }
    }
}

impl fmt::Display for ManagedConfigError {
    /// An administrator-facing message.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(domain) = self.domain() {
            write!(f, "[{domain}] ")?;
        }
        match self {
            Self::NotADictionary => f.write_str("The managed configuration must be a dictionary."),
            Self::ServerUrlsNotAnArray { .. } => {
                write!(f, "'{SERVER_URLS_KEY}' must be an array of strings.")
            }
            Self::TooManyServers { count, .. } => write!(
                f,
                "'{SERVER_URLS_KEY}' has {count} entries; at most {MAX_SERVER_URLS} are allowed."
            ),
            Self::InvalidServer {
                index,
                entry,
                error,
                ..
            } => write!(
                f,
                "'{SERVER_URLS_KEY}' entry {index}: server URL '{entry}' {error}."
            ),
            Self::NotABoolean { key, .. } => write!(f, "'{key}' must be a boolean."),
        }
    }
}

impl std::error::Error for ManagedConfigError {}

/// A server offered by the organization.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ManagedServer {
    /// The URL to connect to, mount path and query preserved (desktop: `omnigentServerName`
    /// removed).
    pub url: String,
    /// The administrator's display name (desktop only).
    pub name: Option<String>,
    /// The serialized origin, `scheme://host[:port]`, used for de-duplication.
    pub origin: String,
    /// `host[:port]`, the label shown when the server has no name.
    pub authority: String,
}

impl ManagedServer {
    /// The name, or the host when unnamed.
    #[must_use]
    pub fn display_name(&self) -> &str {
        self.name.as_deref().unwrap_or(&self.authority)
    }
}

/// The decoded configuration from one channel.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ManagedConfiguration {
    /// Organization servers in administrator order, de-duplicated by origin (first kept).
    pub servers: Vec<ManagedServer>,
    /// Whether Databricks-internal features are on.
    pub databricks_internal_features_enabled: bool,
    /// Problems resolved fail-closed instead of rejecting the configuration: an iOS non-boolean
    /// flag read as `false`, or an iOS legacy dictionary ignored as a whole. Hosts log these; the
    /// legacy channel has no way to report them to the administrator.
    pub issues: Vec<ManagedConfigError>,
}

impl ManagedConfiguration {
    /// No servers, features off.
    pub const EMPTY: Self = Self {
        servers: Vec::new(),
        databricks_internal_features_enabled: false,
        issues: Vec::new(),
    };

    /// Decodes a flat configuration dictionary (`serverUrls`, `databricksInternalFeaturesEnabled`).
    /// Unknown keys are ignored. An absent `serverUrls` offers no servers.
    ///
    /// # Errors
    ///
    /// [`ManagedConfigError`] when the dictionary or `serverUrls` is invalid, or (desktop) when the
    /// flag is not a boolean.
    pub fn decode(value: &Value, dialect: ManagedDialect) -> Result<Self, ManagedConfigError> {
        let Value::Object(map) = value else {
            return Err(ManagedConfigError::NotADictionary);
        };
        let mut issues = Vec::new();
        let flag = map.get(DATABRICKS_INTERNAL_FEATURES_KEY);
        let databricks_internal_features_enabled = match (dialect, flag) {
            (_, None) => false,
            (_, Some(Value::Bool(enabled))) => *enabled,
            // Only a boolean true opts in; a malformed flag must not discard valid servers.
            (ManagedDialect::Ios, Some(_)) => {
                issues.push(not_a_boolean(None));
                false
            }
            (ManagedDialect::Desktop, Some(_)) => return Err(not_a_boolean(None)),
        };
        let servers = match map.get(SERVER_URLS_KEY) {
            None => Vec::new(),
            Some(raw) => parse_servers(raw, dialect, None)?,
        };
        Ok(Self {
            servers,
            databricks_internal_features_enabled,
            issues,
        })
    }

    /// Reads the iOS classic channel (`com.apple.configuration.managed`). That channel cannot
    /// report errors to the administrator, so an invalid dictionary yields no servers and no
    /// features, with the error kept in [`ManagedConfiguration::issues`].
    #[must_use]
    pub fn decode_ios_legacy(value: Option<&Value>) -> Self {
        let Some(value) = value else {
            return Self::EMPTY;
        };
        Self::decode(value, ManagedDialect::Ios).unwrap_or_else(|error| Self {
            issues: vec![error],
            ..Self::EMPTY
        })
    }

    /// Combines the iOS channels. The declarative server list wins when it is non-empty; the
    /// flag comes from the declarative configuration whenever one exists, so a legacy `true`
    /// never overrides a declarative omitted or disabled flag. Issues from both are kept.
    #[must_use]
    pub fn resolve(declarative: Option<Self>, legacy: Self) -> Self {
        let Some(declarative) = declarative else {
            return legacy;
        };
        let mut issues = declarative.issues;
        issues.extend(legacy.issues);
        Self {
            servers: resolve_servers(declarative.servers, legacy.servers),
            databricks_internal_features_enabled: declarative.databricks_internal_features_enabled,
            issues,
        }
    }

    /// The server URLs, in order.
    #[must_use]
    pub fn server_urls(&self) -> Vec<&str> {
        self.servers
            .iter()
            .map(|server| server.url.as_str())
            .collect()
    }
}

fn not_a_boolean(domain: Option<&str>) -> ManagedConfigError {
    ManagedConfigError::NotABoolean {
        domain: domain.map(str::to_owned),
        key: DATABRICKS_INTERNAL_FEATURES_KEY.to_owned(),
    }
}

/// Picks between the two iOS channels: the declarative list wins unless it is empty.
#[must_use]
pub fn resolve_servers(
    declarative: Vec<ManagedServer>,
    legacy: Vec<ManagedServer>,
) -> Vec<ManagedServer> {
    if declarative.is_empty() {
        legacy
    } else {
        declarative
    }
}

/// Validates a `serverUrls` value as one configuration.
///
/// # Errors
///
/// [`ManagedConfigError`] for a wrong type, too many entries or any invalid entry.
pub fn parse_servers(
    value: &Value,
    dialect: ManagedDialect,
    domain: Option<&str>,
) -> Result<Vec<ManagedServer>, ManagedConfigError> {
    let owned_domain = || domain.map(str::to_owned);
    let Value::Array(entries) = value else {
        return Err(ManagedConfigError::ServerUrlsNotAnArray {
            domain: owned_domain(),
        });
    };
    // iOS decodes `[String]` before counting, so a non-string entry is a type error there.
    if dialect == ManagedDialect::Ios && !entries.iter().all(Value::is_string) {
        return Err(ManagedConfigError::ServerUrlsNotAnArray {
            domain: owned_domain(),
        });
    }
    if entries.len() > MAX_SERVER_URLS {
        return Err(ManagedConfigError::TooManyServers {
            domain: owned_domain(),
            count: entries.len(),
        });
    }
    let mut origins = HashSet::new();
    let mut servers = Vec::with_capacity(entries.len());
    for (index, entry) in entries.iter().enumerate() {
        let invalid = |error| ManagedConfigError::InvalidServer {
            domain: owned_domain(),
            index,
            entry: entry
                .as_str()
                .map_or_else(|| entry.to_string(), str::to_owned),
            error,
        };
        let text = entry
            .as_str()
            .ok_or_else(|| invalid(ManagedEntryError::NotAString))?;
        let server = parse_server(text, dialect).map_err(invalid)?;
        if origins.insert(server.origin.clone()) {
            servers.push(server);
        }
    }
    Ok(servers)
}

/// Normalizes one entry. A schemeless host becomes https.
///
/// # Errors
///
/// [`ManagedEntryError`] describing the problem.
pub fn parse_server(
    text: &str,
    dialect: ManagedDialect,
) -> Result<ManagedServer, ManagedEntryError> {
    match dialect {
        ManagedDialect::Ios => parse_ios_server(text),
        ManagedDialect::Desktop => parse_desktop_server(text),
    }
}

/// iOS reuses the shell's own URL rules so a preset server and a typed one meet the same
/// standard, with insecure http refused even in debug builds (App Transport Security would block
/// it on a managed device anyway).
fn parse_ios_server(text: &str) -> Result<ManagedServer, ManagedEntryError> {
    let url = server_url::normalize(text, false).map_err(|error| match error {
        ServerUrlError::Empty => ManagedEntryError::Empty,
        ServerUrlError::Invalid(_) => ManagedEntryError::InvalidUrl,
        ServerUrlError::UnsupportedScheme(_) | ServerUrlError::InsecureHttpNotAllowed => {
            ManagedEntryError::NotHttps
        }
    })?;
    let display = server_url::display(&url);
    let origin = origin_identity(&display).ok_or(ManagedEntryError::InvalidUrl)?;
    let host = url.host_str().ok_or(ManagedEntryError::NoHost)?;
    let authority = url
        .port()
        .map_or_else(|| host.to_owned(), |port| format!("{host}:{port}"));
    Ok(ManagedServer {
        url: display,
        name: None,
        origin,
        authority,
    })
}

/// The desktop rules: the path and other query items are kept byte for byte, the host and port
/// are normalized, and `omnigentServerName` becomes the display name.
fn parse_desktop_server(text: &str) -> Result<ManagedServer, ManagedEntryError> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err(ManagedEntryError::Empty);
    }
    let with_scheme = if trimmed.contains("://") {
        trimmed.to_owned()
    } else {
        format!("https://{trimmed}")
    };
    let parts = UrlParts::split(&with_scheme).ok_or(ManagedEntryError::InvalidUrl)?;
    let well_formed = parts
        .authority
        .is_none_or(|a| valid_component(a, Component::Authority))
        && valid_component(parts.path, Component::Path)
        && parts
            .query
            .is_none_or(|q| valid_component(q, Component::Query))
        && parts
            .fragment
            .is_none_or(|f| valid_component(f, Component::Query));
    if !well_formed {
        return Err(ManagedEntryError::InvalidUrl);
    }
    if !parts.scheme.eq_ignore_ascii_case("https") {
        return Err(ManagedEntryError::NotHttps);
    }
    let authority = parts.authority.unwrap_or_default();
    if authority.contains('@') {
        return Err(ManagedEntryError::Credentials);
    }
    if authority.is_empty() {
        return Err(ManagedEntryError::NoHost);
    }
    let (host, port) =
        crate::deeplink::split_authority(authority).map_err(ManagedEntryError::InvalidOrigin)?;
    if host.is_empty() {
        return Err(ManagedEntryError::NoHost);
    }
    let origin = ServerOrigin::new(OriginScheme::Https, host, port)
        .map_err(ManagedEntryError::InvalidOrigin)?;
    let path = if parts.path.is_empty() {
        "/"
    } else {
        parts.path
    };
    let (query, name) = extract_server_name(parts.query);
    let mut url = format!("https://{}{path}", origin.authority());
    if let Some(query) = query {
        url.push('?');
        url.push_str(query.as_ref());
    }
    if let Some(fragment) = parts.fragment {
        url.push('#');
        url.push_str(fragment);
    }
    Ok(ManagedServer {
        url,
        name,
        origin: origin.serialized(),
        authority: origin.authority(),
    })
}

#[derive(Clone, Copy)]
enum Component {
    Authority,
    Path,
    Query,
}

/// RFC 3986 character check, as `URLComponents(string:)` applies: unreserved, sub-delims, the
/// component's own delimiters, and well-formed percent escapes only.
fn valid_component(text: &str, component: Component) -> bool {
    let bytes = text.as_bytes();
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        if byte == b'%' {
            let escape_ok = bytes.get(index + 1).is_some_and(u8::is_ascii_hexdigit)
                && bytes.get(index + 2).is_some_and(u8::is_ascii_hexdigit);
            if !escape_ok {
                return false;
            }
            index += 3;
            continue;
        }
        let common = byte.is_ascii_alphanumeric()
            || matches!(
                byte,
                b'-' | b'.'
                    | b'_'
                    | b'~'
                    | b'!'
                    | b'$'
                    | b'&'
                    | b'\''
                    | b'('
                    | b')'
                    | b'*'
                    | b'+'
                    | b','
                    | b';'
                    | b'='
                    | b':'
            );
        let allowed = common
            || match component {
                Component::Authority => matches!(byte, b'@' | b'[' | b']'),
                Component::Path => matches!(byte, b'@' | b'/'),
                Component::Query => matches!(byte, b'@' | b'/' | b'?'),
            };
        if !allowed {
            return false;
        }
        index += 1;
    }
    true
}

/// Removes every `omnigentServerName` item, leaving the others byte for byte, and returns the
/// first one's trimmed value. The query is only rewritten when the parameter is present.
fn extract_server_name(query: Option<&str>) -> (Option<std::borrow::Cow<'_, str>>, Option<String>) {
    let Some(query) = query else {
        return (None, None);
    };
    let pairs: Vec<&str> = query.split('&').collect();
    let mut kept: Vec<&str> = Vec::with_capacity(pairs.len());
    let mut names: Vec<String> = Vec::new();
    for pair in &pairs {
        let (raw_name, raw_value) = match pair.split_once('=') {
            Some((name, value)) => (name, Some(value)),
            None => (*pair, None),
        };
        if form_decoded(raw_name).as_deref() == Some(SERVER_NAME_PARAMETER) {
            names.push(raw_value.and_then(form_decoded).unwrap_or_default());
        } else {
            kept.push(pair);
        }
    }
    if kept.len() == pairs.len() {
        return (Some(std::borrow::Cow::Borrowed(query)), None);
    }
    let query = (!kept.is_empty()).then(|| std::borrow::Cow::Owned(kept.join("&")));
    let name = names
        .first()
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty());
    (query, name)
}

fn form_decoded(text: &str) -> Option<String> {
    percent_decoded(&text.replace('+', " "))
}

/// The user's recents minus any origin the organization already presets, order preserved.
/// Entries that are not parseable URLs are kept, so a server the user connected to is never
/// silently lost.
#[must_use]
pub fn recents_excluding_managed(
    recents: &[String],
    managed: &[ManagedServer],
    dialect: ManagedDialect,
) -> Vec<String> {
    if managed.is_empty() {
        return recents.to_vec();
    }
    let managed_origins: HashSet<&str> = managed
        .iter()
        .map(|server| server.origin.as_str())
        .collect();
    recents
        .iter()
        .filter(|recent| {
            let origin = match dialect {
                ManagedDialect::Ios => origin_identity(recent),
                ManagedDialect::Desktop => ServerOrigin::from_url_str(recent)
                    .ok()
                    .map(|origin| origin.serialized()),
            };
            origin.is_none_or(|origin| !managed_origins.contains(origin.as_str()))
        })
        .cloned()
        .collect()
}

/// Every server to offer: organization servers first, then the remaining recents.
#[must_use]
pub fn merged_servers(
    managed: &[ManagedServer],
    recents: &[String],
    dialect: ManagedDialect,
) -> Vec<String> {
    managed
        .iter()
        .map(|server| server.url.clone())
        .chain(recents_excluding_managed(recents, managed, dialect))
        .collect()
}

// MARK: - macOS managed preferences

/// Host access to macOS preferences.
///
/// The host backs it with `CFPreferencesCopyAppValue` and `CFPreferencesAppValueIsForced`.
/// Values are read on demand and never copied into settings, so removing a profile takes effect
/// at the next read.
pub trait ManagedPreferenceSource {
    /// The effective value of `key` in `domain`, forced values first; `None` when unset.
    fn value(&self, key: &str, domain: &str) -> Option<Value>;
    /// Whether a configuration profile forces `key` in `domain`.
    fn is_forced(&self, key: &str, domain: &str) -> bool;
}

/// The effective `serverUrls` and where it came from.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ManagedPreferencesSnapshot {
    /// The domain `serverUrls` was read from, or `None` when no domain sets it.
    pub servers_domain: Option<String>,
    /// Whether an MDM profile forces `serverUrls`, as opposed to a plain `defaults write`.
    pub servers_are_forced: bool,
    /// Organization servers, most preferred first.
    pub servers: Vec<ManagedServer>,
}

/// Reads and validates macOS managed preferences across domains with the desktop rules.
///
/// The first domain that sets a key wins; values are never merged across domains, and an invalid
/// value in the winning domain is reported rather than skipped.
#[derive(Debug, Clone)]
pub struct ManagedPreferences<S> {
    domains: Vec<String>,
    source: S,
}

impl<S: ManagedPreferenceSource> ManagedPreferences<S> {
    /// A reader over `domains` in precedence order (see [`desktop_domains`]).
    pub const fn new(domains: Vec<String>, source: S) -> Self {
        Self { domains, source }
    }

    /// The domains, in precedence order.
    #[must_use]
    pub fn domains(&self) -> &[String] {
        &self.domains
    }

    /// Reads `serverUrls`. Empty when no domain sets it.
    ///
    /// # Errors
    ///
    /// [`ManagedConfigError`] when the winning domain's value is invalid. Callers show no
    /// organization servers and surface the error.
    pub fn servers(&self) -> Result<ManagedPreferencesSnapshot, ManagedConfigError> {
        for domain in &self.domains {
            let Some(value) = self.source.value(SERVER_URLS_KEY, domain) else {
                continue;
            };
            return Ok(ManagedPreferencesSnapshot {
                servers_domain: Some(domain.clone()),
                servers_are_forced: self.source.is_forced(SERVER_URLS_KEY, domain),
                servers: parse_servers(&value, ManagedDialect::Desktop, Some(domain))?,
            });
        }
        Ok(ManagedPreferencesSnapshot::default())
    }

    /// Reads `databricksInternalFeaturesEnabled`. Only an explicit boolean `true` enables it.
    ///
    /// # Errors
    ///
    /// [`ManagedConfigError::NotABoolean`] for numbers, strings and other types.
    pub fn databricks_internal_features_enabled(&self) -> Result<bool, ManagedConfigError> {
        for domain in &self.domains {
            let Some(value) = self.source.value(DATABRICKS_INTERNAL_FEATURES_KEY, domain) else {
                continue;
            };
            return match value {
                Value::Bool(enabled) => Ok(enabled),
                _ => Err(not_a_boolean(Some(domain))),
            };
        }
        Ok(false)
    }
}

/// The app's own domain first, then [`DESKTOP_DEFAULT_DOMAINS`], without duplicates. Debug builds
/// pass `ai.omnigent.mac.lab`.
#[must_use]
pub fn desktop_domains(bundle_identifier: Option<&str>) -> Vec<String> {
    let mut domains: Vec<String> = Vec::with_capacity(DESKTOP_DEFAULT_DOMAINS.len() + 1);
    for domain in bundle_identifier.into_iter().chain(DESKTOP_DEFAULT_DOMAINS) {
        if !domains.iter().any(|existing| existing == domain) {
            domains.push(domain.to_owned());
        }
    }
    domains
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::{HashMap, HashSet};

    use serde_json::{Value, json};

    use super::*;

    const IOS: ManagedDialect = ManagedDialect::Ios;
    const DESKTOP: ManagedDialect = ManagedDialect::Desktop;

    fn decode(value: &Value) -> ManagedConfiguration {
        ManagedConfiguration::decode(value, IOS).unwrap()
    }

    fn assert_fails(value: &Value, code: u16) {
        let error = ManagedConfiguration::decode(value, IOS).unwrap_err();
        assert_eq!(error.ios_code(), code, "{error:?}");
        assert!(
            !error.to_string().is_empty(),
            "admins need an actionable message"
        );
    }

    fn server(url: &str, dialect: ManagedDialect) -> ManagedServer {
        parse_server(url, dialect).unwrap()
    }

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    // MARK: web/ios ManagedConfigurationTests.swift: accepted configurations

    #[test]
    fn managed_absent_key_offers_no_servers() {
        assert_eq!(decode(&json!({})), ManagedConfiguration::EMPTY);
    }

    #[test]
    fn managed_empty_list_offers_no_servers() {
        assert_eq!(
            decode(&json!({"serverUrls": []})),
            ManagedConfiguration::EMPTY
        );
    }

    #[test]
    fn managed_preserves_admin_order() {
        let config =
            decode(&json!({"serverUrls": ["https://b.example.com", "https://a.example.com"]}));
        assert_eq!(
            config.server_urls(),
            ["https://b.example.com", "https://a.example.com"]
        );
    }

    #[test]
    fn managed_bare_host_gets_https() {
        let config = decode(&json!({"serverUrls": ["omnigent.corp.example.com"]}));
        assert_eq!(config.server_urls(), ["https://omnigent.corp.example.com"]);
    }

    #[test]
    fn managed_preserves_workspace_mount() {
        let config =
            decode(&json!({"serverUrls": ["https://ws.cloud.databricks.com/ml/omnigents"]}));
        assert_eq!(
            config.server_urls(),
            ["https://ws.cloud.databricks.com/ml/omnigents"]
        );
    }

    #[test]
    fn managed_dedupes_origins_keeping_first() {
        let config = decode(&json!({"serverUrls": [
            "https://a.example.com", "https://A.Example.com/", "https://b.example.com",
        ]}));
        assert_eq!(
            config.server_urls(),
            ["https://a.example.com", "https://b.example.com"]
        );
    }

    #[test]
    fn managed_accepts_max_entries() {
        let entries: Vec<String> = (1..=MAX_SERVER_URLS)
            .map(|n| format!("https://s{n}.example.com"))
            .collect();
        assert_eq!(
            decode(&json!({"serverUrls": entries})).servers.len(),
            MAX_SERVER_URLS
        );
    }

    // MARK: Databricks-internal features

    #[test]
    fn managed_internal_features_default_disabled() {
        assert!(!decode(&json!({})).databricks_internal_features_enabled);
        assert!(
            !decode(&json!({"serverUrls": ["https://corp.example.com"]}))
                .databricks_internal_features_enabled
        );
    }

    #[test]
    fn managed_internal_flag_bool_without_servers() {
        for enabled in [true, false] {
            let config = decode(&json!({"databricksInternalFeaturesEnabled": enabled}));
            assert_eq!(config.databricks_internal_features_enabled, enabled);
            assert_eq!(config.servers, Vec::new());
            assert_eq!(config.issues, Vec::new());
        }
    }

    #[test]
    fn managed_malformed_flag_fails_closed_keeps_servers() {
        for value in [
            json!("true"),
            json!("false"),
            json!("1"),
            json!(1),
            json!(0),
            json!([true]),
            json!({"enabled": true}),
        ] {
            let config = decode(&json!({
                "serverUrls": ["https://corp.example.com"],
                "databricksInternalFeaturesEnabled": value,
            }));
            assert!(
                !config.databricks_internal_features_enabled,
                "unexpected opt-in for {value}"
            );
            assert_eq!(config.servers.len(), 1);
            // Not swallowed: the fail-closed read is reported.
            assert_eq!(config.issues, [not_a_boolean(None)]);
        }
        // The desktop rules reject the same value outright.
        assert_eq!(
            ManagedConfiguration::decode(
                &json!({"databricksInternalFeaturesEnabled": "true"}),
                DESKTOP
            ),
            Err(not_a_boolean(None))
        );
    }

    #[test]
    fn managed_legacy_flag_only_true_bool_enables() {
        for (value, expected) in [
            (json!(true), true),
            (json!(false), false),
            (json!("true"), false),
            (json!(1), false),
        ] {
            let legacy = json!({"databricksInternalFeaturesEnabled": value});
            assert_eq!(
                ManagedConfiguration::decode_ios_legacy(Some(&legacy))
                    .databricks_internal_features_enabled,
                expected,
                "{value}"
            );
        }
        // Removing the key.
        assert!(
            !ManagedConfiguration::decode_ios_legacy(None).databricks_internal_features_enabled
        );
    }

    #[test]
    fn managed_declarative_overrides_legacy_flag() {
        let legacy = decode(&json!({"databricksInternalFeaturesEnabled": true}));
        for declarative in [
            decode(&json!({})),
            decode(&json!({"databricksInternalFeaturesEnabled": false})),
            decode(&json!({"databricksInternalFeaturesEnabled": "true"})),
        ] {
            assert!(
                !ManagedConfiguration::resolve(Some(declarative), legacy.clone())
                    .databricks_internal_features_enabled
            );
        }
    }

    #[test]
    fn managed_flag_only_declarative_keeps_legacy_servers() {
        let declarative = decode(&json!({"databricksInternalFeaturesEnabled": true}));
        let legacy = decode(&json!({"serverUrls": ["https://corp.example.com"]}));
        let resolved = ManagedConfiguration::resolve(Some(declarative), legacy.clone());
        assert!(resolved.databricks_internal_features_enabled);
        assert_eq!(resolved.servers, legacy.servers);
    }

    #[test]
    fn managed_legacy_flag_only_when_declarative_absent() {
        let legacy = decode(&json!({"databricksInternalFeaturesEnabled": true}));
        assert!(ManagedConfiguration::resolve(None, legacy).databricks_internal_features_enabled);
        assert_eq!(
            ManagedConfiguration::resolve(None, ManagedConfiguration::EMPTY),
            ManagedConfiguration::EMPTY
        );
    }

    // MARK: Rejected configurations

    #[test]
    fn managed_rejects_invalid_url() {
        assert_fails(&json!({"serverUrls": ["https://"]}), IOS_INVALID_URL_CODE);
    }

    #[test]
    fn managed_rejects_blank_entry() {
        assert_fails(&json!({"serverUrls": ["   "]}), IOS_INVALID_URL_CODE);
    }

    #[test]
    fn managed_rejects_insecure_http() {
        assert_fails(
            &json!({"serverUrls": ["http://omnigent.corp.example.com"]}),
            IOS_NOT_HTTPS_CODE,
        );
    }

    #[test]
    fn managed_rejects_non_web_scheme() {
        assert_fails(
            &json!({"serverUrls": ["ftp://omnigent.corp.example.com"]}),
            IOS_NOT_HTTPS_CODE,
        );
    }

    #[test]
    fn managed_rejects_too_many_entries() {
        let entries: Vec<String> = (0..=MAX_SERVER_URLS)
            .map(|n| format!("https://s{n}.example.com"))
            .collect();
        assert_fails(&json!({"serverUrls": entries}), IOS_TOO_MANY_ENTRIES_CODE);
    }

    #[test]
    fn managed_rejects_string_instead_of_list() {
        assert_fails(
            &json!({"serverUrls": "https://omnigent.corp.example.com"}),
            IOS_WRONG_TYPE_CODE,
        );
        // A non-string element is a type error on iOS, an entry error on desktop.
        assert_fails(
            &json!({"serverUrls": ["https://a.example.com", 42]}),
            IOS_WRONG_TYPE_CODE,
        );
        assert_fails(&json!(["https://a.example.com"]), IOS_WRONG_TYPE_CODE);
        assert_eq!(
            ManagedConfiguration::decode(&json!([]), IOS),
            Err(ManagedConfigError::NotADictionary)
        );
    }

    #[test]
    fn managed_one_bad_entry_rejects_all() {
        let value = json!({"serverUrls": ["https://good.example.com", "http://bad.example.com"]});
        assert_fails(&value, IOS_NOT_HTTPS_CODE);
        assert_eq!(
            ManagedConfiguration::decode(&value, IOS),
            Err(ManagedConfigError::InvalidServer {
                domain: None,
                index: 1,
                entry: "http://bad.example.com".to_owned(),
                error: ManagedEntryError::NotHttps,
            })
        );
    }

    #[test]
    fn ios_error_codes_are_below_the_system_reserved_range() {
        // `ManagedAppConfigurationDecodingErrorCode.firstReserved` is 10000 in the ManagedApp
        // framework; the Swift suite asserts the same bound.
        for code in [
            IOS_INVALID_URL_CODE,
            IOS_NOT_HTTPS_CODE,
            IOS_TOO_MANY_ENTRIES_CODE,
            IOS_WRONG_TYPE_CODE,
        ] {
            assert!(code < 10_000);
        }
    }

    // MARK: Classic (non-declarative) channel

    #[test]
    fn managed_legacy_dict_parsed() {
        let legacy = json!({"serverUrls": ["https://corp.example.com"]});
        assert_eq!(
            ManagedConfiguration::decode_ios_legacy(Some(&legacy)).server_urls(),
            ["https://corp.example.com"]
        );
    }

    #[test]
    fn managed_absent_legacy_offers_none() {
        assert_eq!(
            ManagedConfiguration::decode_ios_legacy(None),
            ManagedConfiguration::EMPTY
        );
    }

    #[test]
    fn managed_invalid_legacy_ignored_not_thrown() {
        let legacy = json!({"serverUrls": ["http://insecure.example.com"]});
        let config = ManagedConfiguration::decode_ios_legacy(Some(&legacy));
        assert_eq!(config.servers, Vec::new());
        assert!(!config.databricks_internal_features_enabled);
        // Ignored, but still reported to the host.
        assert_eq!(config.issues.len(), 1);
        assert_eq!(
            config.issues.first().map(ManagedConfigError::ios_code),
            Some(IOS_NOT_HTTPS_CODE)
        );
    }

    #[test]
    fn managed_legacy_dict_tolerates_extra_keys() {
        let legacy = json!({"serverUrls": ["https://corp.example.com"], "somethingElse": 42});
        assert_eq!(
            ManagedConfiguration::decode_ios_legacy(Some(&legacy))
                .servers
                .len(),
            1
        );
    }

    // MARK: Channel precedence

    #[test]
    fn managed_declarative_wins_over_legacy() {
        let declarative = vec![server("https://declarative.example.com", IOS)];
        let legacy = vec![server("https://legacy.example.com", IOS)];
        assert_eq!(resolve_servers(declarative.clone(), legacy), declarative);
    }

    #[test]
    fn managed_legacy_used_without_declarative() {
        let legacy = vec![server("https://legacy.example.com", IOS)];
        assert_eq!(resolve_servers(Vec::new(), legacy.clone()), legacy);
    }

    #[test]
    fn managed_neither_channel_offers_nothing() {
        assert_eq!(resolve_servers(Vec::new(), Vec::new()), Vec::new());
    }

    // MARK: web/ios ManagedServersTests

    fn corp() -> Vec<ManagedServer> {
        vec![server("https://corp.example.com", IOS)]
    }

    #[test]
    fn managed_recents_drop_preset_servers() {
        assert_eq!(
            recents_excluding_managed(
                &strings(&["https://corp.example.com", "https://mine.example.com"]),
                &corp(),
                IOS
            ),
            ["https://mine.example.com"]
        );
    }

    #[test]
    fn managed_recents_untouched_without_config() {
        let recents = strings(&["https://mine.example.com", "http://localhost:6767"]);
        assert_eq!(recents_excluding_managed(&recents, &[], IOS), recents);
    }

    #[test]
    fn managed_recents_differing_port_is_distinct() {
        assert_eq!(
            recents_excluding_managed(&strings(&["https://corp.example.com:8443"]), &corp(), IOS),
            ["https://corp.example.com:8443"]
        );
    }

    #[test]
    fn managed_recents_keeps_unparseable() {
        assert_eq!(
            recents_excluding_managed(&strings(&["not a url"]), &corp(), IOS),
            ["not a url"]
        );
    }

    #[test]
    fn managed_merged_presets_first() {
        assert_eq!(
            merged_servers(
                &corp(),
                &strings(&["https://mine.example.com", "https://corp.example.com"]),
                IOS
            ),
            ["https://corp.example.com", "https://mine.example.com"]
        );
    }

    // MARK: OmnigentDesktop ManagedPreferencesTests.swift

    #[derive(Default)]
    struct FakeSource {
        values: HashMap<(String, String), Value>,
        forced: HashSet<(String, String)>,
        calls: RefCell<Vec<String>>,
    }

    impl FakeSource {
        fn with(mut self, domain: &str, key: &str, value: Value) -> Self {
            self.values
                .insert((domain.to_owned(), key.to_owned()), value);
            self
        }

        fn forcing(mut self, domain: &str, key: &str) -> Self {
            self.forced.insert((domain.to_owned(), key.to_owned()));
            self
        }
    }

    impl ManagedPreferenceSource for FakeSource {
        fn value(&self, key: &str, domain: &str) -> Option<Value> {
            self.calls.borrow_mut().push(format!("{domain}:{key}"));
            self.values
                .get(&(domain.to_owned(), key.to_owned()))
                .cloned()
        }

        fn is_forced(&self, key: &str, domain: &str) -> bool {
            self.forced.contains(&(domain.to_owned(), key.to_owned()))
        }
    }

    fn reader(source: FakeSource) -> ManagedPreferences<FakeSource> {
        ManagedPreferences::new(desktop_domains(None), source)
    }

    fn urls(servers: &[ManagedServer]) -> Vec<&str> {
        servers.iter().map(|server| server.url.as_str()).collect()
    }

    fn desktop_servers(value: &Value) -> Result<Vec<ManagedServer>, ManagedConfigError> {
        parse_servers(value, DESKTOP, Some("d"))
    }

    fn invalid_server(index: usize, entry: &str, error: ManagedEntryError) -> ManagedConfigError {
        ManagedConfigError::InvalidServer {
            domain: Some("d".to_owned()),
            index,
            entry: entry.to_owned(),
            error,
        }
    }

    #[test]
    fn desktop_reads_servers_and_preserves_workspace_paths() {
        let preferences = reader(FakeSource::default().with(
            "ai.omnigent.desktop",
            SERVER_URLS_KEY,
            json!([
                "omnigent.example.com",
                "https://workspace.example.com/ml/omnigents?o=123"
            ]),
        ));
        let snapshot = preferences.servers().unwrap();
        assert_eq!(
            urls(&snapshot.servers),
            [
                "https://omnigent.example.com/",
                "https://workspace.example.com/ml/omnigents?o=123"
            ]
        );
        assert_eq!(
            snapshot.servers_domain.as_deref(),
            Some("ai.omnigent.desktop")
        );
        assert!(!snapshot.servers_are_forced);
        assert_eq!(
            *preferences.source.calls.borrow(),
            [
                "ai.omnigent.mac:serverUrls",
                "ai.omnigent.desktop:serverUrls"
            ]
        );
    }

    #[test]
    fn desktop_unset_returns_nothing() {
        let snapshot = reader(FakeSource::default()).servers().unwrap();
        assert_eq!(snapshot.servers, Vec::new());
        assert_eq!(snapshot.servers_domain, None);
    }

    #[test]
    fn desktop_first_domain_wins_without_merging() {
        let preferences = reader(
            FakeSource::default()
                .with(
                    "ai.omnigent.mac",
                    SERVER_URLS_KEY,
                    json!(["https://mac.example.com"]),
                )
                .with(
                    "ai.omnigent.desktop",
                    SERVER_URLS_KEY,
                    json!(["https://desktop.example.com"]),
                )
                .forcing("ai.omnigent.mac", SERVER_URLS_KEY),
        );
        let snapshot = preferences.servers().unwrap();
        assert_eq!(urls(&snapshot.servers), ["https://mac.example.com/"]);
        assert_eq!(snapshot.servers_domain.as_deref(), Some("ai.omnigent.mac"));
        assert!(snapshot.servers_are_forced);
    }

    #[test]
    fn desktop_invalid_first_domain_is_reported() {
        let preferences = reader(
            FakeSource::default()
                .with(
                    "ai.omnigent.mac",
                    SERVER_URLS_KEY,
                    json!("https://mac.example.com"),
                )
                .with(
                    "ai.omnigent.desktop",
                    SERVER_URLS_KEY,
                    json!(["https://desktop.example.com"]),
                ),
        );
        assert_eq!(
            preferences.servers(),
            Err(ManagedConfigError::ServerUrlsNotAnArray {
                domain: Some("ai.omnigent.mac".to_owned())
            })
        );
    }

    #[test]
    fn desktop_deduplicates_by_origin() {
        let servers = desktop_servers(&json!([
            "https://workspace.example.com/ml/omnigents",
            "https://workspace.example.com/another-mount",
            "https://other.example.com",
            "HTTPS://Other.Example.com:443/x",
        ]))
        .unwrap();
        assert_eq!(
            urls(&servers),
            [
                "https://workspace.example.com/ml/omnigents",
                "https://other.example.com/"
            ]
        );
    }

    #[test]
    fn desktop_rejects_whole_configuration() {
        assert_eq!(
            desktop_servers(&json!("https://omnigent.example.com")),
            Err(ManagedConfigError::ServerUrlsNotAnArray {
                domain: Some("d".to_owned())
            })
        );
        let error = desktop_servers(&json!([
            "https://valid.example.com",
            "http://insecure.example.com"
        ]))
        .unwrap_err();
        assert_eq!(
            error,
            invalid_server(
                1,
                "http://insecure.example.com",
                ManagedEntryError::NotHttps
            )
        );
        let ManagedConfigError::InvalidServer { error: reason, .. } = &error else {
            unreachable!("checked above");
        };
        assert_eq!(reason.to_string(), "must use https://");
        let too_many: Vec<String> = (0..=MAX_SERVER_URLS)
            .map(|n| format!("host{n}.com"))
            .collect();
        assert_eq!(
            desktop_servers(&json!(too_many)),
            Err(ManagedConfigError::TooManyServers {
                domain: Some("d".to_owned()),
                count: 11
            })
        );
        let not_string = desktop_servers(&json!([42])).unwrap_err();
        assert_eq!(
            not_string,
            invalid_server(0, "42", ManagedEntryError::NotAString)
        );
        assert_eq!(ManagedEntryError::NotAString.to_string(), "is not a string");
        assert_eq!(
            desktop_servers(&json!(["   "])),
            Err(invalid_server(0, "   ", ManagedEntryError::Empty))
        );
        assert_eq!(ManagedEntryError::Empty.to_string(), "is empty");
    }

    #[test]
    fn desktop_rejects_credentials_bad_hosts_and_ports() {
        for (entry, expected) in [
            (
                "https://user:pass@example.com",
                ManagedEntryError::Credentials,
            ),
            ("https://exa mple.com", ManagedEntryError::InvalidUrl),
            (
                "https://example.com:99999",
                ManagedEntryError::InvalidOrigin(ServerOriginError::InvalidPort("99999".into())),
            ),
            ("ftp://example.com", ManagedEntryError::NotHttps),
            ("https://", ManagedEntryError::NoHost),
            (
                "https://0x7f000001/",
                ManagedEntryError::InvalidOrigin(ServerOriginError::InvalidHost(
                    "0x7f000001".into(),
                )),
            ),
            ("https://example.com/a%zz", ManagedEntryError::InvalidUrl),
            (
                "https://example.com/caf\u{E9}",
                ManagedEntryError::InvalidUrl,
            ),
        ] {
            assert_eq!(parse_server(entry, DESKTOP), Err(expected), "{entry}");
        }
    }

    #[test]
    fn desktop_reads_display_names_and_strips_the_parameter() {
        let servers = desktop_servers(&json!([
            "https://workspace.example.com/?o=123&omnigentServerName=%20Team%20A%20",
            "https://other.example.com/ml?omnigentServerName=",
            "plain.example.com",
            "https://plus.example.com/?omnigentServerName=Team+B&x=a%2Bb",
        ]))
        .unwrap();
        assert_eq!(
            urls(&servers),
            [
                "https://workspace.example.com/?o=123",
                "https://other.example.com/ml",
                "https://plain.example.com/",
                "https://plus.example.com/?x=a%2Bb",
            ]
        );
        let names: Vec<Option<&str>> = servers.iter().map(|s| s.name.as_deref()).collect();
        assert_eq!(names, [Some("Team A"), None, None, Some("Team B")]);
        let display: Vec<&str> = servers.iter().map(ManagedServer::display_name).collect();
        assert_eq!(
            display,
            ["Team A", "other.example.com", "plain.example.com", "Team B"]
        );
    }

    #[test]
    fn desktop_names_only_kept_servers() {
        let servers = desktop_servers(&json!([
            "https://team.example.com/",
            "https://team.example.com/other?omnigentServerName=Dropped",
        ]))
        .unwrap();
        let names: Vec<Option<&str>> = servers.iter().map(|s| s.name.as_deref()).collect();
        assert_eq!(names, [None]);
        assert!(
            desktop_servers(&json!([
                "https://team.example.com/?omnigentServerName=Team",
                "http://bad"
            ]))
            .is_err()
        );
    }

    #[test]
    fn desktop_keeps_fragment_port_and_untouched_query() {
        let server = server("https://Example.com:8443/m/?a=%41&b#frag", DESKTOP);
        assert_eq!(server.url, "https://example.com:8443/m/?a=%41&b#frag");
        assert_eq!(server.origin, "https://example.com:8443");
        assert_eq!(server.display_name(), "example.com:8443");
    }

    #[test]
    fn desktop_excludes_recents_with_a_managed_origin() {
        let managed =
            desktop_servers(&json!(["https://workspace.example.com/ml/omnigents"])).unwrap();
        let recents = strings(&[
            "https://workspace.example.com/old-mount",
            "https://personal.example.com/",
            "hand-edited-invalid-value",
        ]);
        assert_eq!(
            recents_excluding_managed(&recents, &managed, DESKTOP),
            ["https://personal.example.com/", "hand-edited-invalid-value"]
        );
    }

    #[test]
    fn desktop_internal_features_need_an_explicit_true() {
        let key = DATABRICKS_INTERNAL_FEATURES_KEY;
        let enabled = |domain: &str, value: Value| {
            reader(FakeSource::default().with(domain, key, value))
                .databricks_internal_features_enabled()
        };
        assert_eq!(enabled("ai.omnigent.desktop", json!(true)), Ok(true));
        assert_eq!(enabled("ai.omnigent.mac", json!(false)), Ok(false));
        assert_eq!(
            reader(FakeSource::default()).databricks_internal_features_enabled(),
            Ok(false)
        );
        for value in [json!(1), json!("true"), json!([true])] {
            assert_eq!(
                enabled("ai.omnigent.mac", value),
                Err(ManagedConfigError::NotABoolean {
                    domain: Some("ai.omnigent.mac".to_owned()),
                    key: key.to_owned()
                })
            );
        }
    }

    #[test]
    fn desktop_domains_put_the_app_first_without_duplicates() {
        assert_eq!(
            desktop_domains(Some("ai.omnigent.mac.lab")),
            [
                "ai.omnigent.mac.lab",
                "ai.omnigent.mac",
                "ai.omnigent.desktop"
            ]
        );
        assert_eq!(
            desktop_domains(Some("ai.omnigent.mac")),
            ["ai.omnigent.mac", "ai.omnigent.desktop"]
        );
        assert_eq!(desktop_domains(None), DESKTOP_DEFAULT_DOMAINS);
    }

    #[test]
    fn error_messages_name_the_domain_and_entry() {
        let error = invalid_server(2, "http://x", ManagedEntryError::NotHttps);
        assert_eq!(
            error.to_string(),
            "[d] 'serverUrls' entry 2: server URL 'http://x' must use https://."
        );
        assert_eq!(error.domain(), Some("d"));
        assert_eq!(
            ManagedConfigError::TooManyServers {
                domain: None,
                count: 11
            }
            .to_string(),
            "'serverUrls' has 11 entries; at most 10 are allowed."
        );
    }
}
