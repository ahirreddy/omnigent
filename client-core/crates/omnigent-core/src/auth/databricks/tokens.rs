//! The Databricks token bundle, token-endpoint response decoding, and the versioned credential
//! record the host keeps in its secure store.
//!
//! Ports `DatabricksOAuthTokens` and `DatabricksOAuthClient.tokens(from:)` from
//! `web/ios/Omnigent/DatabricksOAuthClient.swift`, and the Keychain record from
//! `DatabricksCredentialStore.swift`.
//!
//! # Record format
//!
//! The record is JSON, byte-compatible with what the Swift app already stored:
//!
//! ```json
//! {"version": 2, "tokens": {"accessToken": "...", "refreshToken": "...",
//!   "expiresAt": 1000.0, "issuer": "https://accounts.cloud.databricks.com/oidc/accounts/a"}}
//! ```
//!
//! `expiresAt` is Foundation's default `Date` encoding: seconds (a double) since
//! 2001-01-01T00:00:00Z. Version 1 records have no issuer and keep their legacy
//! `<workspace>/oidc/v1/token` refresh route. Issuer-aware records are version 2 so builds that
//! predate issuers reject them instead of silently dropping the routing context. Anything else,
//! including a version 2 record without an issuer or a version 1 record with one, is invalid and
//! is reported, never deleted.

use serde_json::{Map, Value, json};

use super::error::DatabricksError;
use super::issuer::OAuthIssuer;
use crate::auth::{SecretString, TokenSet};

/// Milliseconds from the Unix epoch to Foundation's reference date, 2001-01-01T00:00:00Z.
pub const APPLE_REFERENCE_DATE_UNIX_MS: u64 = 978_307_200_000;

/// The credential record version for bundles without an issuer.
pub const RECORD_VERSION_LEGACY: u64 = 1;
/// The credential record version for issuer-aware bundles.
pub const RECORD_VERSION_ISSUER: u64 = 2;

/// An opaque Databricks token bundle. `Debug` redacts both tokens.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DatabricksTokens {
    /// The bearer for `auth/session/create` and API calls.
    pub access_token: SecretString,
    /// The rotating refresh grant.
    pub refresh_token: SecretString,
    /// When `access_token` expires, in ms since the Unix epoch.
    pub expires_at_ms: u64,
    /// The verified issuer, or `None` for legacy bundles that refresh at the workspace.
    pub issuer: Option<OAuthIssuer>,
}

impl DatabricksTokens {
    /// Whether both tokens are non-empty and free of whitespace and control characters.
    #[must_use]
    pub fn is_valid(&self) -> bool {
        is_opaque_token(self.access_token.expose()) && is_opaque_token(self.refresh_token.expose())
    }

    /// The bundle as the shared [`TokenSet`] (no user id: Databricks tokens are opaque).
    #[must_use]
    pub fn to_token_set(&self) -> TokenSet {
        TokenSet {
            access_token: self.access_token.clone(),
            refresh_token: Some(self.refresh_token.clone()),
            expires_at_ms: Some(self.expires_at_ms),
            user_id: None,
        }
    }

    /// The record version this bundle is stored as.
    #[must_use]
    pub const fn record_version(&self) -> u64 {
        if self.issuer.is_some() {
            RECORD_VERSION_ISSUER
        } else {
            RECORD_VERSION_LEGACY
        }
    }
}

fn is_opaque_token(token: &str) -> bool {
    !token.is_empty() && !token.chars().any(|c| c.is_whitespace() || c.is_control())
}

/// Decodes a token-endpoint body.
///
/// `requested_at_ms` is when the request was sent; the expiry is that plus `expires_in`. On a
/// refresh, pass the grant that was used as `previous_refresh_token`: a response that omits
/// `refresh_token` keeps it, but a present `refresh_token` must be a usable string.
///
/// # Errors
///
/// [`DatabricksError::InvalidTokenResponse`] unless the body is a JSON object with string
/// `access_token`, `token_type` `Bearer` (any case), a positive finite numeric `expires_in`, and
/// valid tokens.
pub fn tokens_from_response(
    body: &[u8],
    requested_at_ms: u64,
    previous_refresh_token: Option<&SecretString>,
    issuer: Option<OAuthIssuer>,
) -> Result<DatabricksTokens, DatabricksError> {
    let invalid = || DatabricksError::InvalidTokenResponse;
    let value: Value = serde_json::from_slice(body).map_err(|_| invalid())?;
    let object = value.as_object().ok_or_else(invalid)?;
    let access_token = string_field(object, "access_token").ok_or_else(invalid)?;
    let token_type = string_field(object, "token_type").ok_or_else(invalid)?;
    let expires_in = object
        .get("expires_in")
        .and_then(Value::as_f64)
        .ok_or_else(invalid)?;
    let refresh_token = match object.get("refresh_token") {
        Some(value) => SecretString::new(value.as_str().ok_or_else(invalid)?),
        None => previous_refresh_token.cloned().ok_or_else(invalid)?,
    };
    if !token_type.eq_ignore_ascii_case("bearer") || !expires_in.is_finite() || expires_in <= 0.0 {
        return Err(invalid());
    }
    let lifetime_ms = ms_from_f64(expires_in * 1000.0).ok_or_else(invalid)?;
    let tokens = DatabricksTokens {
        access_token: SecretString::new(access_token),
        refresh_token,
        expires_at_ms: requested_at_ms.saturating_add(lifetime_ms),
        issuer,
    };
    if tokens.is_valid() {
        Ok(tokens)
    } else {
        Err(invalid())
    }
}

/// Encodes `tokens` as a credential record (version 1 without an issuer, 2 with one).
///
/// # Errors
///
/// [`DatabricksError::InvalidCredentialData`] when the tokens are not valid; such a bundle is
/// never persisted.
pub fn encode_record(tokens: &DatabricksTokens) -> Result<Vec<u8>, DatabricksError> {
    if !tokens.is_valid() {
        return Err(DatabricksError::InvalidCredentialData);
    }
    let mut inner = Map::new();
    inner.insert(
        "accessToken".into(),
        Value::String(tokens.access_token.expose().to_owned()),
    );
    inner.insert(
        "refreshToken".into(),
        Value::String(tokens.refresh_token.expose().to_owned()),
    );
    inner.insert(
        "expiresAt".into(),
        json!(seconds_since_reference_date(tokens.expires_at_ms)),
    );
    if let Some(issuer) = &tokens.issuer {
        inner.insert("issuer".into(), Value::String(issuer.as_str().to_owned()));
    }
    let record = json!({"version": tokens.record_version(), "tokens": Value::Object(inner)});
    serde_json::to_vec(&record).map_err(|_| DatabricksError::InvalidCredentialData)
}

/// Decodes a credential record written by this core or by the Swift app.
///
/// # Errors
///
/// [`DatabricksError::InvalidCredentialData`] for malformed JSON, an unknown version, a version
/// that disagrees with the issuer's presence, an unsupported issuer, or invalid tokens.
pub fn decode_record(bytes: &[u8]) -> Result<DatabricksTokens, DatabricksError> {
    let invalid = || DatabricksError::InvalidCredentialData;
    let value: Value = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    let version = value
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(invalid)?;
    let inner = value
        .get("tokens")
        .and_then(Value::as_object)
        .ok_or_else(invalid)?;
    let access_token = string_field(inner, "accessToken").ok_or_else(invalid)?;
    let refresh_token = string_field(inner, "refreshToken").ok_or_else(invalid)?;
    let expires_at = inner
        .get("expiresAt")
        .and_then(Value::as_f64)
        .ok_or_else(invalid)?;
    // Foundation decodes an optional property with `decodeIfPresent`, so `null` means absent.
    let issuer = match inner.get("issuer") {
        None | Some(Value::Null) => None,
        Some(Value::String(raw)) => Some(OAuthIssuer::parse(raw).map_err(|_| invalid())?),
        Some(_) => return Err(invalid()),
    };
    let tokens = DatabricksTokens {
        access_token: SecretString::new(access_token),
        refresh_token: SecretString::new(refresh_token),
        expires_at_ms: unix_ms_from_reference_seconds(expires_at).ok_or_else(invalid)?,
        issuer,
    };
    if version != tokens.record_version() || !tokens.is_valid() {
        return Err(invalid());
    }
    Ok(tokens)
}

fn string_field<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

/// Foundation's `Date` encoding of `unix_ms`.
fn seconds_since_reference_date(unix_ms: u64) -> f64 {
    (f64_from_ms(unix_ms) - f64_from_ms(APPLE_REFERENCE_DATE_UNIX_MS)) / 1000.0
}

/// The Unix-ms instant for Foundation seconds since the reference date. Instants before the Unix
/// epoch (Swift's `Date.distantPast`, which debug fault injection stores) clamp to 0: still
/// expired, which is all the token manager needs to know.
fn unix_ms_from_reference_seconds(seconds: f64) -> Option<u64> {
    if !seconds.is_finite() {
        return None;
    }
    ms_from_f64(seconds.mul_add(1000.0, f64_from_ms(APPLE_REFERENCE_DATE_UNIX_MS)))
}

#[allow(
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "range-checked float to integer conversion; `as` saturates and NaN is rejected first"
)]
fn ms_from_f64(ms: f64) -> Option<u64> {
    if ms.is_nan() {
        None
    } else if ms <= 0.0 {
        Some(0)
    } else {
        Some(ms.round() as u64)
    }
}

#[allow(
    clippy::as_conversions,
    clippy::cast_precision_loss,
    reason = "millisecond instants are far below 2^53, so the conversion is exact"
)]
const fn f64_from_ms(ms: u64) -> f64 {
    ms as f64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::databricks::test_support::{ACCOUNT_ISSUER, TOKEN_BODY, tokens};

    /// `DatabricksOAuthClientTests::testDecodesOpaqueTokensAndUsesResponseExpiry`.
    #[test]
    fn databricks_token_response_decodes_opaque_tokens() {
        let decoded = tokens_from_response(TOKEN_BODY.as_bytes(), 1_000_000, None, None).unwrap();
        assert_eq!(decoded.access_token.expose(), "opaque-access");
        assert_eq!(decoded.refresh_token.expose(), "opaque-refresh");
        assert_eq!(decoded.expires_at_ms, 1_000_000 + 120_000);
        assert_eq!(decoded.issuer, None);
        let debug = format!("{decoded:?}");
        assert!(!debug.contains("opaque-access") && !debug.contains("opaque-refresh"));
    }

    /// `DatabricksOAuthClientTests::testRejectsIncompleteOrInvalidTokenResponses`.
    #[test]
    fn databricks_token_response_rejects_invalid() {
        let valid = json!({
            "access_token": "access", "refresh_token": "refresh", "token_type": "Bearer",
            "expires_in": 120,
        });
        let assert_invalid = |body: &[u8]| {
            assert_eq!(
                tokens_from_response(body, 0, None, None),
                Err(DatabricksError::InvalidTokenResponse),
                "{}",
                String::from_utf8_lossy(body)
            );
        };
        for key in ["access_token", "refresh_token", "token_type", "expires_in"] {
            let mut incomplete = valid.clone();
            incomplete.as_object_mut().unwrap().remove(key);
            assert_invalid(incomplete.to_string().as_bytes());
        }
        for (key, value) in [
            ("access_token", ""),
            ("refresh_token", " "),
            ("access_token", "line\nbreak"),
            ("token_type", "Basic"),
        ] {
            let mut invalid = valid.clone();
            invalid[key] = json!(value);
            assert_invalid(invalid.to_string().as_bytes());
        }
        for expiry in [0, -1] {
            let mut invalid = valid.clone();
            invalid["expires_in"] = json!(expiry);
            assert_invalid(invalid.to_string().as_bytes());
        }
        let mut stringly = valid;
        stringly["expires_in"] = json!("120");
        assert_invalid(stringly.to_string().as_bytes());
        assert_invalid(b"not json");
        assert_invalid(b"[]");
    }

    /// `DatabricksOAuthClientTests::testRefreshRetainsOmittedTokenButRejectsMalformedReplacement`.
    #[test]
    fn databricks_refresh_retains_omitted_refresh_token() {
        let body = br#"{"access_token":"new-access","token_type":"Bearer","expires_in":120}"#;
        let previous = SecretString::new("old-refresh");
        let refreshed = tokens_from_response(body, 0, Some(&previous), None).unwrap();
        assert_eq!(refreshed.refresh_token.expose(), "old-refresh");
        assert_eq!(
            tokens_from_response(body, 0, None, None),
            Err(DatabricksError::InvalidTokenResponse)
        );
        for invalid in [json!(""), json!(" "), Value::Null, json!(42)] {
            let body = json!({
                "access_token": "new-access", "token_type": "Bearer", "expires_in": 120,
                "refresh_token": invalid,
            });
            assert_eq!(
                tokens_from_response(body.to_string().as_bytes(), 0, Some(&previous), None),
                Err(DatabricksError::InvalidTokenResponse),
                "{body}"
            );
        }
    }

    /// `DatabricksCredentialStoreTests::testIssuerAwareRecordsUpgradeToVersionTwo` (codec half;
    /// the Keychain round-trip stays Swift).
    #[test]
    fn databricks_credential_record_v1_v2_codec() {
        let legacy = tokens("test-access", "test-refresh", 3_000_000, None);
        let encoded = encode_record(&legacy).unwrap();
        let value: Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(value["version"], json!(1));
        assert!(value["tokens"].get("issuer").is_none());
        assert_eq!(decode_record(&encoded).unwrap(), legacy);

        let issuer = OAuthIssuer::parse(ACCOUNT_ISSUER).unwrap();
        let aware = tokens("test-access", "test-refresh", 3_000_000, Some(issuer));
        let encoded = encode_record(&aware).unwrap();
        let value: Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(value["version"], json!(2));
        assert_eq!(value["tokens"]["issuer"], json!(ACCOUNT_ISSUER));
        assert_eq!(decode_record(&encoded).unwrap(), aware);

        // A record the Swift app wrote: `expiresAt` is seconds since 2001-01-01.
        let swift_v1 =
            br#"{"version":1,"tokens":{"accessToken":"a","refreshToken":"r","expiresAt":1000}}"#;
        let decoded = decode_record(swift_v1).unwrap();
        assert_eq!(
            decoded.expires_at_ms,
            APPLE_REFERENCE_DATE_UNIX_MS + 1_000_000
        );
        assert_eq!(decoded.issuer, None);
        let swift_v2 = format!(
            r#"{{"tokens":{{"issuer":"{ACCOUNT_ISSUER}","expiresAt":12.5,"refreshToken":"r","accessToken":"a"}},"version":2}}"#
        );
        let decoded = decode_record(swift_v2.as_bytes()).unwrap();
        assert_eq!(decoded.expires_at_ms, APPLE_REFERENCE_DATE_UNIX_MS + 12_500);
        assert_eq!(decoded.issuer.unwrap().as_str(), ACCOUNT_ISSUER);
        let null_issuer =
            br#"{"version":1,"tokens":{"accessToken":"a","refreshToken":"r","expiresAt":1000,"issuer":null}}"#;
        assert!(decode_record(null_issuer).is_ok());
        // `Date.distantPast` (stored by debug fault injection) is simply expired.
        let distant_past = br#"{"version":1,"tokens":{"accessToken":"a","refreshToken":"r","expiresAt":-63114076800}}"#;
        assert_eq!(decode_record(distant_past).unwrap().expires_at_ms, 0);
        assert_eq!(
            encode_record(&tokens("bad token", "r", 0, None)),
            Err(DatabricksError::InvalidCredentialData)
        );
    }

    /// `DatabricksCredentialStoreTests::testRejectsMalformedAndFutureRecordsWithoutDeletingThem`
    /// (decoder half; not deleting the item is the store's behavior, covered by the token manager).
    #[test]
    fn databricks_credential_record_rejects_malformed_and_future() {
        for record in [
            "not-json".to_owned(),
            r#"{"version":99,"tokens":{"accessToken":"a","refreshToken":"r","expiresAt":1000}}"#
                .to_owned(),
            r#"{"version":2,"tokens":{"accessToken":"a","refreshToken":"r","expiresAt":1000}}"#
                .to_owned(),
            r#"{"version":2,"tokens":{"accessToken":"a","refreshToken":"r","expiresAt":1000,"issuer":"https://example.com/oidc"}}"#
                .to_owned(),
            format!(
                r#"{{"version":1,"tokens":{{"accessToken":"a","refreshToken":"r","expiresAt":1000,"issuer":"{ACCOUNT_ISSUER}"}}}}"#
            ),
            r#"{"version":1,"tokens":{"accessToken":"","refreshToken":"r","expiresAt":1000}}"#
                .to_owned(),
            r#"{"version":1,"tokens":{"accessToken":"a","refreshToken":"r"}}"#.to_owned(),
            r#"{"version":"1","tokens":{"accessToken":"a","refreshToken":"r","expiresAt":1}}"#
                .to_owned(),
        ] {
            assert_eq!(
                decode_record(record.as_bytes()),
                Err(DatabricksError::InvalidCredentialData),
                "{record}"
            );
        }
    }
}
