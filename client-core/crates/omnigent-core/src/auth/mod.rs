//! Hosted authentication: mode resolution, accounts, OIDC, PKCE, token refresh.
//!
//! # Shared surface
//!
//! The items defined directly in this module are shared by every auth flow, including
//! [`databricks`]. Keep them stable:
//!
//! - [`SecretString`]: a credential string whose `Debug` is redacted.
//! - [`TokenSet`]: the access/refresh token pair a flow produces, with an absolute expiry.
//! - [`SecureStore`], [`SecureStoreKey`], [`SecureStoreError`]: the host's secure storage
//!   (Keychain on Apple), byte values keyed by a namespace and an account.
//! - [`EntropySource`], [`EntropyError`]: host randomness for PKCE verifiers and OAuth state.
//! - [`pkce`]: verifier/challenge generation and form encoding.
//! - [`renewal_delay_ms`]: when to refresh a token before it expires.
//!
//! The core never reads a clock: every time-dependent function takes `now_ms`, milliseconds
//! since the Unix epoch as the host reads it.

use std::fmt;
use std::future::Future;

pub mod accounts;
pub mod databricks;
pub mod endpoint;
pub mod error_text;
pub mod errors;
pub mod hosted;
pub mod mode;
pub mod oidc;
pub mod oidc_session;
pub mod pkce;
pub mod ticket;
pub mod workspace;

#[cfg(test)]
pub(crate) mod testing;

/// A credential (token, password, verifier). `Debug` never prints the value, and there is no
/// `Display`: read it with [`SecretString::expose`] only where it goes on the wire.
#[derive(Clone, PartialEq, Eq, Hash, Default)]
pub struct SecretString(String);

impl SecretString {
    /// Wraps `value`.
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    /// The secret value.
    #[must_use]
    pub fn expose(&self) -> &str {
        &self.0
    }

    /// Whether the secret is the empty string.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// The secret value, consuming the wrapper.
    #[must_use]
    pub fn into_inner(self) -> String {
        self.0
    }
}

impl fmt::Debug for SecretString {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SecretString(<redacted>)")
    }
}

impl From<String> for SecretString {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl From<&str> for SecretString {
    fn from(value: &str) -> Self {
        Self(value.to_owned())
    }
}

/// Tokens a sign-in or refresh produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenSet {
    /// The bearer (or session-cookie) value for API requests.
    pub access_token: SecretString,
    /// The grant to mint the next access token, when the server issued one.
    pub refresh_token: Option<SecretString>,
    /// When `access_token` stops working, in ms since the Unix epoch; `None` when unknown.
    pub expires_at_ms: Option<u64>,
    /// The server's user id for the signed-in account, when it said.
    pub user_id: Option<String>,
}

impl TokenSet {
    /// Whether `access_token` is past its expiry at `now_ms`. Unknown expiry is never expired.
    #[must_use]
    pub fn is_expired(&self, now_ms: u64) -> bool {
        self.expires_at_ms.is_some_and(|expiry| expiry <= now_ms)
    }
}

/// Where a secret lives in the host's secure store.
///
/// On Apple, `namespace` selects the Keychain service and `account` is the item's account
/// attribute. Hosts must keep items device-only (never synced).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SecureStoreKey {
    /// Which flow owns the item, e.g. [`SecureStoreKey::OIDC_NAMESPACE`].
    pub namespace: String,
    /// The item within the namespace, usually a normalized server origin or a scope string.
    pub account: String,
}

impl SecureStoreKey {
    /// OIDC refresh grants, keyed by normalized server origin.
    pub const OIDC_NAMESPACE: &'static str = "oidc";
    /// Accounts-mode bearer credentials, keyed by [`endpoint::ServerIdentityScope::account_id`].
    pub const ACCOUNTS_NAMESPACE: &'static str = "accounts";
    /// Databricks OAuth tokens, keyed by the Databricks credential scope.
    pub const DATABRICKS_NAMESPACE: &'static str = "databricks";

    /// A key from its parts.
    pub fn new(namespace: impl Into<String>, account: impl Into<String>) -> Self {
        Self {
            namespace: namespace.into(),
            account: account.into(),
        }
    }
}

/// Why the host's secure store failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SecureStoreError {
    /// The store cannot be read right now, typically because the device is locked.
    Unavailable {
        /// Host-provided detail (e.g. the `OSStatus`).
        message: String,
    },
    /// Any other storage failure.
    Other {
        /// Host-provided detail.
        message: String,
    },
}

impl fmt::Display for SecureStoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unavailable { message } => write!(f, "secure storage unavailable: {message}"),
            Self::Other { message } => write!(f, "secure storage failed: {message}"),
        }
    }
}

impl std::error::Error for SecureStoreError {}

/// Host secure storage of byte values.
///
/// `get` of an absent key is `Ok(None)` and `delete` of an absent key is `Ok(())`; every other
/// failure is an error, never an empty result.
pub trait SecureStore {
    /// The bytes stored under `key`.
    fn get(
        &self,
        key: SecureStoreKey,
    ) -> impl Future<Output = Result<Option<Vec<u8>>, SecureStoreError>>;

    /// Stores `value` under `key`, replacing any previous value.
    fn set(
        &self,
        key: SecureStoreKey,
        value: Vec<u8>,
    ) -> impl Future<Output = Result<(), SecureStoreError>>;

    /// Removes `key`.
    fn delete(&self, key: SecureStoreKey) -> impl Future<Output = Result<(), SecureStoreError>>;
}

/// Why the host could not supply random bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EntropyError {
    /// The platform RNG failed.
    Unavailable {
        /// Host-provided detail.
        message: String,
    },
    /// The host returned fewer bytes than requested.
    ShortRead {
        /// Bytes asked for.
        requested: usize,
        /// Bytes returned.
        received: usize,
    },
}

impl fmt::Display for EntropyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unavailable { message } => write!(f, "random bytes unavailable: {message}"),
            Self::ShortRead {
                requested,
                received,
            } => write!(f, "asked for {requested} random bytes, got {received}"),
        }
    }
}

impl std::error::Error for EntropyError {}

/// Cryptographically secure random bytes from the host (`SecRandomCopyBytes`,
/// `crypto.getRandomValues`).
pub trait EntropySource {
    /// Exactly `len` random bytes.
    ///
    /// # Errors
    ///
    /// The platform RNG failed.
    fn random_bytes(&self, len: usize) -> Result<Vec<u8>, EntropyError>;
}

/// The renewal margin cap: refresh at most a minute before expiry.
pub const RENEWAL_MARGIN_MS: u64 = 60_000;
/// Never schedule a renewal further out than a day; the host re-plans on wake anyway.
pub const MAX_RENEWAL_DELAY_MS: u64 = 24 * 3_600_000;

/// How long to wait before renewing a token that expires at `expires_at_ms`.
///
/// Renews early by a fifth of the remaining lifetime, at most [`RENEWAL_MARGIN_MS`], and never
/// waits more than [`MAX_RENEWAL_DELAY_MS`]. Zero once the token is at or past expiry.
#[must_use]
pub const fn renewal_delay_ms(expires_at_ms: u64, now_ms: u64) -> u64 {
    let remaining = expires_at_ms.saturating_sub(now_ms);
    let margin = if remaining / 5 < RENEWAL_MARGIN_MS {
        remaining / 5
    } else {
        RENEWAL_MARGIN_MS
    };
    let delay = remaining - margin;
    if delay < MAX_RENEWAL_DELAY_MS {
        delay
    } else {
        MAX_RENEWAL_DELAY_MS
    }
}

/// Whether `token` can go in an `Authorization: Bearer` header or a `Cookie` value unchanged:
/// non-empty, and only RFC 6265 cookie-octets that are also visible ASCII (no space, `"`, `,`,
/// `;`, `\`, or controls).
#[must_use]
pub fn is_header_safe_token(token: &str) -> bool {
    !token.is_empty()
        && token.bytes().all(
            |byte| matches!(byte, 0x21 | 0x23..=0x2B | 0x2D..=0x3A | 0x3C..=0x5B | 0x5D..=0x7E),
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_debug_is_redacted() {
        let secret = SecretString::new("hunter2");
        assert_eq!(format!("{secret:?}"), "SecretString(<redacted>)");
        let tokens = TokenSet {
            access_token: secret.clone(),
            refresh_token: Some(SecretString::new("refresh-me")),
            expires_at_ms: Some(5),
            user_id: Some("u1".into()),
        };
        let debug = format!("{tokens:?}");
        assert!(
            !debug.contains("hunter2") && !debug.contains("refresh-me"),
            "{debug}"
        );
        assert_eq!(secret.expose(), "hunter2");
    }

    #[test]
    fn token_expiry() {
        let tokens = TokenSet {
            access_token: "a".into(),
            refresh_token: None,
            expires_at_ms: Some(1_000),
            user_id: None,
        };
        assert!(!tokens.is_expired(999));
        assert!(tokens.is_expired(1_000));
        assert!(
            !TokenSet {
                expires_at_ms: None,
                ..tokens
            }
            .is_expired(u64::MAX)
        );
    }

    #[test]
    fn header_safe_tokens() {
        assert!(is_header_safe_token("eyJ.abc-_~+/=.sig"));
        for bad in ["", "a b", "a;b", "a,b", "a\"b", "a\\b", "a\nb", "é"] {
            assert!(!is_header_safe_token(bad), "{bad:?}");
        }
    }
}
