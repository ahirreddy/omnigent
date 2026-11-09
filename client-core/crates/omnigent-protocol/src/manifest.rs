//! `GET /.well-known/omnigent.json` (see `well_known_manifest` in `omnigent/server/app.py`).
//!
//! Decoding follows the server contract: unknown fields are ignored, and optional fields with the
//! wrong JSON type read as absent, like the Swift parser in `web/ios/Omnigent/ServerManifest.swift`.
//! Only `manifest_version` is required. Gate on `manifest_version >= N`, never `== N`.

use std::fmt;

use serde::de::{self, DeserializeOwned, Deserializer};
use serde::{Deserialize, Serialize, Serializer};
use serde_json::Value;

/// Fixed path at the server's origin; a mount path is not prepended.
pub const MANIFEST_PATH: &str = "/.well-known/omnigent.json";

const SESSION_COOKIE_NAMES: [&str; 2] = ["__Host-ap_session", "ap_session"];

/// A decoded `/.well-known/omnigent.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ServerManifest {
    /// Envelope version. Required; a finite JSON number.
    #[serde(deserialize_with = "finite_number")]
    pub manifest_version: f64,
    /// Installed server package version. Informational, not for gating.
    #[serde(default, deserialize_with = "lenient")]
    pub server_version: Option<String>,
    /// Oldest desktop build the server supports; null means no floor.
    #[serde(default, deserialize_with = "lenient")]
    pub min_desktop_version: Option<String>,
    /// Operator display name. Self-asserted: display only, never for trust decisions.
    #[serde(default, deserialize_with = "lenient")]
    pub server_name: Option<String>,
    /// Where server-driven chrome lives.
    #[serde(default, deserialize_with = "lenient")]
    pub ui: Option<ManifestUi>,
    /// Absent on servers that predate the block ("sign in as before"), or without a string `mode`.
    #[serde(default, deserialize_with = "lenient")]
    pub auth: Option<ManifestAuth>,
}

impl ServerManifest {
    /// Decodes a manifest response body.
    ///
    /// # Errors
    ///
    /// The body is not JSON, is not an object, or lacks a numeric `manifest_version`.
    pub fn from_json(bytes: &[u8]) -> Result<Self, serde_json::Error> {
        serde_json::from_slice(bytes)
    }
}

/// The manifest's `ui` block.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestUi {
    /// `"sidebar"` or (older servers) `"titlebar"`.
    #[serde(default, deserialize_with = "lenient")]
    pub server_picker: Option<String>,
}

/// The manifest's `auth` block.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestAuth {
    /// How the server signs users in.
    pub mode: AuthMode,
    /// As sent; use [`ManifestAuth::trusted_session_cookie`] before relying on it.
    #[serde(default, deserialize_with = "lenient")]
    pub session_cookie: Option<String>,
    /// Non-string entries are dropped; null or absent is empty.
    #[serde(default, deserialize_with = "string_list")]
    pub native_redirect_uris: Vec<String>,
}

impl ManifestAuth {
    /// The session cookie name only if it is one the server really uses, and the `__Host-`
    /// variant only for an https server.
    #[must_use]
    pub fn trusted_session_cookie(&self, server_is_https: bool) -> Option<&str> {
        let name = self.session_cookie.as_deref()?;
        if !SESSION_COOKIE_NAMES.contains(&name) {
            return None;
        }
        if name.starts_with("__Host-") && !server_is_https {
            return None;
        }
        Some(name)
    }
}

impl ManifestAuth {
    /// Whether the server's native sign-in accepts `redirect_uri`: an OIDC server, and either a
    /// listed private-use-scheme redirect or an RFC 8252 loopback redirect (which `"oidc"`
    /// always promises).
    #[must_use]
    pub fn accepts_native_redirect(&self, redirect_uri: &str) -> bool {
        self.mode == AuthMode::Oidc
            && (self
                .native_redirect_uris
                .iter()
                .any(|uri| uri == redirect_uri)
                || is_loopback_redirect_uri(redirect_uri))
    }

    /// The session cookie to install when the server offers this app's native sign-in with a
    /// listed `redirect_uri`; `None` keeps the legacy in-web-view flow. Port of
    /// `ServerManifest.nativeSignInCookieName`.
    #[must_use]
    pub fn native_sign_in_cookie(&self, redirect_uri: &str, server_is_https: bool) -> Option<&str> {
        if self.mode != AuthMode::Oidc
            || !self
                .native_redirect_uris
                .iter()
                .any(|uri| uri == redirect_uri)
        {
            return None;
        }
        self.trusted_session_cookie(server_is_https)
    }
}

/// The redirect URI the iOS app registers (`NATIVE_APP_REDIRECT_URIS` in
/// `omnigent/server/routes/auth.py`).
pub const IOS_NATIVE_REDIRECT_URI: &str = "ai.omnigent.ios:/oauth/callback";

/// Whether `raw` is an RFC 8252 loopback redirect the server accepts.
///
/// That is `http://127.0.0.1:<port>` or `http://[::1]:<port>` with an explicit non-zero port, an
/// optional path, and no userinfo, query, fragment, backslash or whitespace. Mirrors
/// `_is_loopback_redirect_uri` on the server.
#[must_use]
pub fn is_loopback_redirect_uri(raw: &str) -> bool {
    if raw.is_empty() || raw.contains(['?', '#', '\\']) || raw.chars().any(char::is_whitespace) {
        return false;
    }
    let Some((scheme, rest)) = raw.split_once("://") else {
        return false;
    };
    if !scheme.eq_ignore_ascii_case("http") {
        return false;
    }
    let Some(after_host) = rest
        .strip_prefix("127.0.0.1:")
        .or_else(|| rest.strip_prefix("[::1]:"))
    else {
        return false;
    };
    let port = after_host.split('/').next().unwrap_or_default();
    !port.is_empty()
        && port.len() <= 5
        && port.bytes().all(|byte| byte.is_ascii_digit())
        && port
            .parse::<u32>()
            .is_ok_and(|port| (1..=65_535).contains(&port))
}

/// `auth.mode`. A mode this client does not know is kept verbatim, never mapped to a known one.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum AuthMode {
    /// OIDC, including the native loopback sign-in.
    Oidc,
    /// Built-in username/password accounts.
    Accounts,
    /// Identity from a trusted reverse-proxy header.
    Header,
    /// An embedding app's own provider.
    Custom,
    /// The server's `"none"`: no sign-in.
    None,
    /// A mode newer than this client.
    Unknown {
        /// The mode string as sent.
        value: String,
    },
}

impl AuthMode {
    /// Maps a wire value; anything unrecognized becomes [`AuthMode::Unknown`].
    #[must_use]
    pub fn parse(value: &str) -> Self {
        match value {
            "oidc" => Self::Oidc,
            "accounts" => Self::Accounts,
            "header" => Self::Header,
            "custom" => Self::Custom,
            "none" => Self::None,
            other => Self::Unknown {
                value: other.to_owned(),
            },
        }
    }

    /// The wire value.
    #[must_use]
    pub fn as_str(&self) -> &str {
        match self {
            Self::Oidc => "oidc",
            Self::Accounts => "accounts",
            Self::Header => "header",
            Self::Custom => "custom",
            Self::None => "none",
            Self::Unknown { value } => value,
        }
    }
}

impl fmt::Display for AuthMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl Serialize for AuthMode {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for AuthMode {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        Ok(Self::parse(&value))
    }
}

/// A finite JSON number. Strings, booleans and null are rejected.
fn finite_number<'de, D: Deserializer<'de>>(deserializer: D) -> Result<f64, D::Error> {
    match Value::deserialize(deserializer)? {
        Value::Number(number) => number
            .as_f64()
            .filter(|value| value.is_finite())
            .ok_or_else(|| de::Error::custom(format!("{number} is not a finite number"))),
        other => Err(de::Error::invalid_type(unexpected(&other), &"a number")),
    }
}

/// The value as `T`, or `None` when it is null or has another shape.
fn lenient<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: DeserializeOwned,
{
    let value = Value::deserialize(deserializer)?;
    Ok(T::deserialize(value).ok())
}

fn string_list<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<String>, D::Error> {
    Ok(match Value::deserialize(deserializer)? {
        Value::Array(items) => items
            .into_iter()
            .filter_map(|item| match item {
                Value::String(value) => Some(value),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    })
}

fn unexpected(value: &Value) -> de::Unexpected<'_> {
    match value {
        Value::Null => de::Unexpected::Unit,
        Value::Bool(value) => de::Unexpected::Bool(*value),
        Value::Number(_) => de::Unexpected::Other("number"),
        Value::String(value) => de::Unexpected::Str(value),
        Value::Array(_) => de::Unexpected::Seq,
        Value::Object(_) => de::Unexpected::Map,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(json: &str) -> Result<ServerManifest, serde_json::Error> {
        ServerManifest::from_json(json.as_bytes())
    }

    #[test]
    fn an_auth_mode_prints_as_sent_and_a_wrong_shape_is_named() {
        assert_eq!(AuthMode::Oidc.to_string(), "oidc");
        for wrong in ["1", "[]", "{}"] {
            assert!(
                parse(&format!(r#"{{"auth_mode":{wrong}}}"#)).is_err(),
                "{wrong}"
            );
        }
    }

    fn fixture(name: &str) -> Vec<u8> {
        let path = format!(
            "{}/../../fixtures/manifest/{name}",
            env!("CARGO_MANIFEST_DIR")
        );
        std::fs::read(&path).unwrap_or_else(|error| panic!("reading {path}: {error}"))
    }

    #[test]
    fn current_server_manifest_fixture() {
        let manifest = ServerManifest::from_json(&fixture("oidc.json")).unwrap();
        assert_eq!(
            manifest,
            ServerManifest {
                manifest_version: 1.0,
                server_version: Some("0.18.0".into()),
                min_desktop_version: None,
                server_name: Some("Omnigent Dev".into()),
                ui: Some(ManifestUi {
                    server_picker: Some("sidebar".into())
                }),
                auth: Some(ManifestAuth {
                    mode: AuthMode::Oidc,
                    session_cookie: Some("__Host-ap_session".into()),
                    native_redirect_uris: vec![
                        "ai.omnigent.android:/oauth/callback".into(),
                        "ai.omnigent.ios:/oauth/callback".into(),
                    ],
                }),
            }
        );
    }

    #[test]
    fn oidc_manifest_with_cookie_and_native_redirects_drops_non_string_redirects() {
        let manifest = parse(
            r#"{"manifest_version": 1, "server_version": "0.18.0", "auth": {"mode": "oidc",
                "session_cookie": "ap_session",
                "native_redirect_uris": ["ai.omnigent.ios:/oauth/callback", 7, null]}}"#,
        )
        .unwrap();
        assert_eq!(manifest.manifest_version, 1.0);
        assert_eq!(
            manifest.auth,
            Some(ManifestAuth {
                mode: AuthMode::Oidc,
                session_cookie: Some("ap_session".into()),
                native_redirect_uris: vec!["ai.omnigent.ios:/oauth/callback".into()],
            })
        );
    }

    #[test]
    fn auth_without_native_redirects_has_none() {
        let manifest = parse(r#"{"manifest_version": 1, "auth": {"mode": "accounts"}}"#).unwrap();
        assert_eq!(
            manifest.auth,
            Some(ManifestAuth {
                mode: AuthMode::Accounts,
                session_cookie: None,
                native_redirect_uris: vec![],
            })
        );

        let null_redirects = parse(
            r#"{"manifest_version": 1, "auth": {"mode": "none", "native_redirect_uris": null}}"#,
        )
        .unwrap();
        assert_eq!(
            null_redirects.auth,
            Some(ManifestAuth {
                mode: AuthMode::None,
                session_cookie: None,
                native_redirect_uris: vec![],
            })
        );
    }

    #[test]
    fn every_known_mode_parses() {
        for (name, mode) in [
            ("oidc", AuthMode::Oidc),
            ("accounts", AuthMode::Accounts),
            ("header", AuthMode::Header),
            ("custom", AuthMode::Custom),
            ("none", AuthMode::None),
        ] {
            let json = format!(r#"{{"manifest_version": 1, "auth": {{"mode": "{name}"}}}}"#);
            assert_eq!(parse(&json).unwrap().auth.unwrap().mode, mode, "{name}");
            assert_eq!(mode.as_str(), name);
        }
    }

    // The Swift parser drops the whole auth block for an unknown mode; here the mode is kept
    // verbatim so callers can surface it instead of silently treating it as a known one.
    #[test]
    fn unknown_mode_is_kept_verbatim_with_version() {
        let manifest = parse(
            r#"{"manifest_version": 2, "auth": {"mode": "saml", "session_cookie": "ap_session"}}"#,
        )
        .unwrap();
        assert_eq!(manifest.manifest_version, 2.0);
        assert_eq!(
            manifest.auth.unwrap().mode,
            AuthMode::Unknown {
                value: "saml".into()
            }
        );
    }

    #[test]
    fn mode_case_is_not_folded() {
        let manifest = parse(r#"{"manifest_version": 1, "auth": {"mode": "OIDC"}}"#).unwrap();
        assert_eq!(
            manifest.auth.unwrap().mode,
            AuthMode::Unknown {
                value: "OIDC".into()
            }
        );
    }

    #[test]
    fn auth_without_string_mode_is_absent() {
        for auth in [
            r#""oidc""#,
            "null",
            "{}",
            r#"{"mode": 3}"#,
            r#"{"mode": null}"#,
        ] {
            let json = format!(r#"{{"manifest_version": 1, "auth": {auth}}}"#);
            assert_eq!(parse(&json).unwrap().auth, None, "{auth}");
        }
    }

    #[test]
    fn unknown_session_cookie_is_untrusted() {
        let manifest = parse(
            r#"{"manifest_version": 1, "auth": {"mode": "oidc", "session_cookie": "session"}}"#,
        )
        .unwrap();
        let auth = manifest.auth.unwrap();
        assert_eq!(auth.trusted_session_cookie(true), None);
        assert_eq!(auth.trusted_session_cookie(false), None);
    }

    #[test]
    fn host_prefixed_cookie_only_for_https() {
        let manifest = parse(
            r#"{"manifest_version": 1, "auth": {"mode": "oidc", "session_cookie": "__Host-ap_session"}}"#,
        )
        .unwrap();
        let auth = manifest.auth.unwrap();
        assert_eq!(auth.mode, AuthMode::Oidc);
        assert_eq!(auth.trusted_session_cookie(false), None);
        assert_eq!(auth.trusted_session_cookie(true), Some("__Host-ap_session"));

        let plain = ManifestAuth {
            session_cookie: Some("ap_session".into()),
            ..auth
        };
        assert_eq!(plain.trusted_session_cookie(false), Some("ap_session"));
    }

    const IOS: &str = IOS_NATIVE_REDIRECT_URI;

    #[test]
    fn manifest_native_sign_in_cookie_enabled_when_redirect_matches() {
        let manifest = parse(
            r#"{"manifest_version": 1, "auth": {"mode": "oidc", "session_cookie": "__Host-ap_session",
                "native_redirect_uris": ["ai.omnigent.ios:/oauth/callback"]}}"#,
        )
        .unwrap();
        let auth = manifest.auth.unwrap();
        assert_eq!(
            auth.native_sign_in_cookie(IOS, true),
            Some("__Host-ap_session")
        );
        assert!(auth.accepts_native_redirect(IOS));
    }

    #[test]
    fn manifest_native_sign_in_legacy_when_redirect_or_cookie_missing() {
        for body in [
            r#"{"manifest_version": 1, "auth": {"mode": "oidc", "session_cookie": "__Host-ap_session"}}"#,
            r#"{"manifest_version": 1, "auth": {"mode": "oidc", "session_cookie": "__Host-ap_session",
                "native_redirect_uris": ["http://127.0.0.1/callback", "omnigent:/oauth/callback"]}}"#,
            r#"{"manifest_version": 1, "auth": {"mode": "oidc",
                "native_redirect_uris": ["ai.omnigent.ios:/oauth/callback"]}}"#,
        ] {
            let auth = parse(body).unwrap().auth.unwrap();
            assert_eq!(auth.native_sign_in_cookie(IOS, true), None, "{body}");
        }
    }

    #[test]
    fn manifest_native_sign_in_only_for_oidc_mode() {
        for mode in ["accounts", "header", "custom", "none"] {
            let body = format!(
                r#"{{"manifest_version": 1, "auth": {{"mode": "{mode}", "session_cookie": "__Host-ap_session",
                    "native_redirect_uris": ["ai.omnigent.ios:/oauth/callback"]}}}}"#
            );
            let auth = parse(&body).unwrap().auth.unwrap();
            assert_eq!(auth.native_sign_in_cookie(IOS, true), None, "{mode}");
            assert!(!auth.accepts_native_redirect(IOS), "{mode}");
        }
        assert_eq!(parse(r#"{"manifest_version": 1}"#).unwrap().auth, None);
    }

    #[test]
    fn loopback_redirects_match_the_server_rule() {
        for uri in [
            "http://127.0.0.1:53682/callback",
            "http://[::1]:8080/cb",
            "http://127.0.0.1:1",
            "HTTP://127.0.0.1:65535/x",
        ] {
            assert!(is_loopback_redirect_uri(uri), "{uri}");
        }
        for uri in [
            "",
            "http://127.0.0.1/callback",
            "http://127.0.0.1:0/cb",
            "http://127.0.0.1:65536/cb",
            "http://localhost:8080/cb",
            "https://127.0.0.1:8080/cb",
            "http://user@127.0.0.1:8080/cb",
            "http://127.0.0.1:8080/cb?x=1",
            "http://127.0.0.1:8080/cb#f",
            "http://127.0.0.1:8080/c b",
            "http://127.0.0.1:80a/cb",
            "ai.omnigent.ios:/oauth/callback",
        ] {
            assert!(!is_loopback_redirect_uri(uri), "{uri}");
        }
        let auth = ManifestAuth {
            mode: AuthMode::Oidc,
            session_cookie: None,
            native_redirect_uris: vec![],
        };
        assert!(auth.accepts_native_redirect("http://127.0.0.1:53682/callback"));
        assert!(!auth.accepts_native_redirect(IOS));
    }

    #[test]
    fn malformed_json_is_an_error() {
        assert!(parse(r#"{"manifest_version": 1, "auth": "#).is_err());
        assert!(parse("<!doctype html><html></html>").is_err());
    }

    #[test]
    fn non_numeric_or_missing_version_is_an_error() {
        for version in [r#""1""#, "true", "null"] {
            let json = format!(r#"{{"manifest_version": {version}, "auth": {{"mode": "oidc"}}}}"#);
            assert!(parse(&json).is_err(), "{version}");
        }
        let missing = parse(r#"{"auth": {"mode": "oidc"}}"#).unwrap_err();
        assert!(
            missing.to_string().contains("manifest_version"),
            "{missing}"
        );
    }

    #[test]
    fn fractional_version_is_accepted() {
        assert_eq!(
            parse(r#"{"manifest_version": 1.5}"#)
                .unwrap()
                .manifest_version,
            1.5
        );
    }

    #[test]
    fn unknown_fields_and_wrong_typed_optionals_are_ignored() {
        let manifest = parse(
            r#"{"manifest_version": 3, "server_version": 18, "min_desktop_version": ["1"],
                "server_name": null, "ui": "sidebar", "future_field": {"x": 1}}"#,
        )
        .unwrap();
        assert_eq!(
            manifest,
            ServerManifest {
                manifest_version: 3.0,
                server_version: None,
                min_desktop_version: None,
                server_name: None,
                ui: None,
                auth: None,
            }
        );
    }

    #[test]
    fn auth_mode_round_trips_through_json() {
        let mode = AuthMode::Unknown {
            value: "saml".into(),
        };
        let json = serde_json::to_string(&mode).unwrap();
        assert_eq!(json, r#""saml""#);
        assert_eq!(serde_json::from_str::<AuthMode>(&json).unwrap(), mode);
    }
}
