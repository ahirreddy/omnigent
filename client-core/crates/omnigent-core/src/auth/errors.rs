//! Auth error taxonomy.
//!
//! Two detailed error types mirror the Swift oracles:
//!
//! - [`HostedAuthError`]: endpoint validation, `/v1/info` discovery, accounts login, the OIDC
//!   ticket flow and identity confirmation (`NativeLab` `LocalServerClientError`).
//! - [`OidcError`]: the native OIDC sign-in, refresh and session checks (web/ios
//!   `OidcSignInError`). Every variant names the server's host label for its message.
//!
//! [`AuthFailure`] folds both into the five outcomes a UI distinguishes: expired, ended by the
//! server, sign-in required, refused (with the server's reason), and transport.

use std::fmt;

use super::{EntropyError, SecureStoreError};
use crate::http::TransportError;

/// What a UI needs to know about an auth failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthFailure {
    /// The credential or grant outlived its lifetime; signing in again fixes it.
    Expired,
    /// The server revoked or rejected the session or grant.
    EndedByServer,
    /// There is no usable credential; the user must sign in.
    SignInRequired,
    /// The server or identity provider declined the sign-in.
    Refused {
        /// The server's reason, verbatim, when it gave one.
        reason: Option<String>,
    },
    /// The server could not be reached or answered unexpectedly; credentials are kept.
    Transport,
    /// Anything else (invalid input, malformed response, storage failure).
    Failed,
}

/// Endpoint, discovery, accounts, ticket and identity failures.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostedAuthError {
    /// The API root is not an https URL (or literal loopback http root) the client accepts.
    InvalidBaseUrl,
    /// A request was attempted before `connect` succeeded, or after the connection ended.
    NotConnected,
    /// The server's auth mode does not support this sign-in method.
    UnsupportedAuthentication,
    /// `/v1/me` did not confirm a non-empty identity.
    IdentityUnavailable,
    /// `/v1/me` confirmed a different account than the saved or pinned one.
    IdentityMismatch,
    /// The browser ticket expired, was denied, or is unknown (`410`).
    BrowserLoginExpired {
        /// The server's `error` text, when present.
        reason: Option<String>,
    },
    /// The ticket poll's PKCE proof was rejected (`400` missing/invalid, `403` mismatch).
    BrowserLoginRejected {
        /// HTTP status.
        status: u16,
        /// The server's `error` text, when present.
        reason: Option<String>,
    },
    /// `POST /auth/cli-login` answered the legacy `upgrade-required` sentinel.
    LoginUpgradeRequired {
        /// The server's instruction text.
        message: Option<String>,
    },
    /// The response body is not what the contract promises.
    MalformedResponse {
        /// What was wrong, for logs. Never contains a credential.
        detail: String,
    },
    /// A 3xx, or a login URL pointing somewhere the client must not go.
    RedirectNotAllowed,
    /// `401`: the credential is missing, invalid or ended.
    Unauthorized {
        /// The server's `error` text, when present (e.g. "invalid username or password").
        reason: Option<String>,
    },
    /// `403`.
    Forbidden,
    /// Creating an account was refused (`400` or `409`): the name is taken, the invite is invalid,
    /// or setup already happened.
    AccountRefused {
        /// HTTP status.
        status: u16,
        /// The server's `error` text, when present.
        reason: Option<String>,
    },
    /// Any other non-success status.
    HttpStatus {
        /// HTTP status.
        status: u16,
    },
    /// The host transport failed.
    Transport(TransportError),
    /// The saved credential is past its expiry.
    CredentialExpired,
    /// A saved credential record could not be decoded.
    InvalidCredentialRecord,
    /// The secure store failed.
    Store(SecureStoreError),
    /// The host could not supply randomness.
    Entropy(EntropyError),
}

impl HostedAuthError {
    /// The UI-level classification.
    #[must_use]
    pub fn failure(&self) -> AuthFailure {
        match self {
            Self::CredentialExpired | Self::BrowserLoginExpired { .. } => AuthFailure::Expired,
            Self::Unauthorized { .. } | Self::NotConnected => AuthFailure::SignInRequired,
            Self::IdentityMismatch => AuthFailure::EndedByServer,
            Self::BrowserLoginRejected { reason, .. } | Self::AccountRefused { reason, .. } => {
                AuthFailure::Refused {
                    reason: reason.clone(),
                }
            }
            Self::Transport(_) | Self::HttpStatus { .. } => AuthFailure::Transport,
            Self::InvalidBaseUrl
            | Self::UnsupportedAuthentication
            | Self::IdentityUnavailable
            | Self::LoginUpgradeRequired { .. }
            | Self::MalformedResponse { .. }
            | Self::RedirectNotAllowed
            | Self::Forbidden
            | Self::InvalidCredentialRecord
            | Self::Store(_)
            | Self::Entropy(_) => AuthFailure::Failed,
        }
    }
}

impl fmt::Display for HostedAuthError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidBaseUrl => f.write_str(
                "Use an HTTPS API URL including its mount path, or an HTTP loopback root for local \
                 mode. Databricks workspace hosts allow one numeric ?o=workspace-id selector. Omit \
                 credentials, fragments, and other query parameters.",
            ),
            Self::NotConnected => f.write_str("Connect to the server before loading sessions."),
            Self::UnsupportedAuthentication => f.write_str(
                "This authentication method is unavailable for this deployment. Use hosted bearer \
                 authentication or explicit local single-user mode.",
            ),
            Self::IdentityUnavailable => {
                f.write_str("The server did not confirm an authenticated identity.")
            }
            Self::IdentityMismatch => f.write_str(
                "The authenticated account differs from the saved account. Sign out and reconnect.",
            ),
            Self::BrowserLoginExpired { .. } => {
                f.write_str("Browser login expired. Start a new sign-in.")
            }
            Self::BrowserLoginRejected { reason, .. } => match reason {
                Some(reason) if !reason.is_empty() => write!(f, "Browser login failed: {reason}"),
                _ => f.write_str("Browser login failed. Start a new sign-in."),
            },
            Self::LoginUpgradeRequired { message } => match message {
                Some(message) if !message.is_empty() => f.write_str(message),
                _ => f.write_str("This server needs a newer sign-in method. Update the app."),
            },
            Self::MalformedResponse { .. } => f.write_str(
                "The server returned data this app could not read. Check the server version.",
            ),
            Self::RedirectNotAllowed => {
                f.write_str("The server redirected this request. Use the direct API address.")
            }
            Self::Unauthorized { .. } => {
                f.write_str("Sign in again or provide a valid bearer token for this server.")
            }
            Self::Forbidden => f.write_str("The server denied access to this resource."),
            Self::AccountRefused { .. } => f.write_str("The server did not create the account."),
            Self::HttpStatus { status } => write!(
                f,
                "The server returned HTTP {status}. Check that it is running and try again."
            ),
            Self::Transport(error) => write!(
                f,
                "Could not reach the server ({error}). Check the address and network connection."
            ),
            Self::CredentialExpired => {
                f.write_str("Your saved sign-in has expired. Sign in again to reconnect.")
            }
            Self::InvalidCredentialRecord => {
                f.write_str("The saved sign-in could not be read. Sign in again.")
            }
            Self::Store(_) => f.write_str(
                "The sign-in could not be saved in Keychain. Unlock this device and try again.",
            ),
            Self::Entropy(_) => f.write_str("Could not start a secure sign-in. Try again."),
        }
    }
}

impl std::error::Error for HostedAuthError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Transport(error) => Some(error),
            Self::Store(error) => Some(error),
            Self::Entropy(error) => Some(error),
            _ => None,
        }
    }
}

impl From<TransportError> for HostedAuthError {
    fn from(error: TransportError) -> Self {
        Self::Transport(error)
    }
}

impl From<SecureStoreError> for HostedAuthError {
    fn from(error: SecureStoreError) -> Self {
        Self::Store(error)
    }
}

impl From<EntropyError> for HostedAuthError {
    fn from(error: EntropyError) -> Self {
        Self::Entropy(error)
    }
}

/// Why an OIDC request counted as a network failure. Kept for logs; the message stays fixed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NetworkCause {
    /// The host transport failed.
    Transport(TransportError),
    /// An unexpected status (including a 3xx, which is never followed).
    Status(u16),
    /// A 200 whose token is missing or unsafe for a header.
    InvalidToken,
}

/// Why the native-token exchange failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExchangeFailure {
    /// A non-200 answer, with the OAuth `error` code when the body had one.
    Status {
        /// HTTP status.
        status: u16,
        /// RFC 6749 `error`.
        error: Option<String>,
    },
    /// A 200 whose token is missing or unsafe for a header.
    InvalidToken,
}

/// How a best-effort `POST /oauth/revoke` went.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RevokeOutcome {
    /// The server answered 200; the grant is dead (or was already).
    Revoked,
    /// The revoke did not go through; the grant may stay live until it expires.
    Failed(NetworkCause),
}

/// Why an OIDC sign-in, renewal or session check failed. Port of web/ios `OidcSignInError`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OidcError {
    /// The server URL has no http(s) origin to sign in to.
    InvalidServerUrl,
    /// The redirect URI is not one this server accepts for native sign-in.
    RedirectNotAccepted {
        /// The server's host label.
        host: String,
    },
    /// The system sign-in sheet (or the RNG behind it) could not start.
    BrowserUnavailable {
        /// The server's host label.
        host: String,
    },
    /// The callback is not this sign-in's (wrong URI or state, no code).
    InvalidCallback {
        /// The server's host label.
        host: String,
    },
    /// The server or `IdP` declined the sign-in on the callback.
    SignInRefused {
        /// The server's host label.
        host: String,
        /// The callback's `error_description`.
        description: Option<String>,
    },
    /// The code exchange failed; retrying may work.
    ExchangeFailed {
        /// The server's host label.
        host: String,
        /// What failed.
        cause: ExchangeFailure,
    },
    /// The stored grant is past its lifetime (`expired_token`); it has been forgotten.
    GrantExpired {
        /// The server's host label.
        host: String,
    },
    /// The server revoked or rejected the stored grant (`invalid_grant`); it has been forgotten.
    GrantRejected {
        /// The server's host label.
        host: String,
    },
    /// No usable grant is stored, or the server cannot refresh one (404).
    NoStoredGrant {
        /// The server's host label.
        host: String,
    },
    /// The server could not be reached or answered unexpectedly; any stored grant is kept.
    Network {
        /// The server's host label.
        host: String,
        /// What failed.
        cause: NetworkCause,
    },
    /// The server refused a freshly minted session.
    SessionRejected {
        /// The server's host label.
        host: String,
    },
    /// The secure store failed.
    Store {
        /// The server's host label.
        host: String,
        /// The host's error.
        error: SecureStoreError,
    },
    /// The server issued a refresh grant that could not be saved; it was revoked so it does not
    /// stay live on the server.
    GrantNotSaved {
        /// The server's host label.
        host: String,
        /// The host store's error.
        error: SecureStoreError,
        /// How the compensating revoke went.
        revocation: RevokeOutcome,
    },
    /// The saved grant record could not be decoded.
    InvalidGrantRecord {
        /// The server's host label.
        host: String,
    },
    /// The work was superseded by a sign-out for the same origin.
    Cancelled,
}

impl OidcError {
    /// The UI-level classification.
    #[must_use]
    pub fn failure(&self) -> AuthFailure {
        match self {
            Self::GrantExpired { .. } => AuthFailure::Expired,
            Self::GrantRejected { .. } | Self::SessionRejected { .. } => AuthFailure::EndedByServer,
            Self::NoStoredGrant { .. } => AuthFailure::SignInRequired,
            Self::SignInRefused { description, .. } => AuthFailure::Refused {
                reason: description.clone().filter(|text| !text.is_empty()),
            },
            Self::Network { .. } => AuthFailure::Transport,
            Self::InvalidServerUrl
            | Self::RedirectNotAccepted { .. }
            | Self::BrowserUnavailable { .. }
            | Self::InvalidCallback { .. }
            | Self::ExchangeFailed { .. }
            | Self::Store { .. }
            | Self::GrantNotSaved { .. }
            | Self::InvalidGrantRecord { .. }
            | Self::Cancelled => AuthFailure::Failed,
        }
    }

    /// Whether this is a connection error, never a reason to sign in again.
    #[must_use]
    pub const fn is_network_failure(&self) -> bool {
        matches!(self, Self::Network { .. })
    }
}

impl fmt::Display for OidcError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidServerUrl => f.write_str("Enter a valid server URL."),
            Self::RedirectNotAccepted { host } => write!(
                f,
                "{host} doesn't support signing in from this app. Update the server and try again."
            ),
            Self::BrowserUnavailable { host } => {
                write!(f, "Couldn't open the sign-in page for {host}. Try again.")
            }
            Self::InvalidCallback { host } => {
                write!(f, "Sign-in to {host} didn't complete. Try again.")
            }
            Self::SignInRefused { host, description } => match description {
                Some(description) if !description.is_empty() => f.write_str(description),
                _ => write!(f, "{host} didn't accept the sign-in. Try again."),
            },
            Self::ExchangeFailed { host, .. } => {
                write!(f, "Couldn't finish signing in to {host}. Try again.")
            }
            Self::GrantExpired { host } => write!(
                f,
                "Your sign-in to {host} has expired. Sign in again to continue."
            ),
            Self::GrantRejected { host } => {
                write!(f, "{host} ended your session. Sign in again to continue.")
            }
            Self::NoStoredGrant { host } => write!(f, "Sign in to {host} to continue."),
            Self::Network { host, .. } => write!(
                f,
                "Couldn't reach {host}. Check your connection and try again."
            ),
            Self::SessionRejected { host } => write!(
                f,
                "{host} didn't accept the session. Sign in again to continue."
            ),
            Self::Store { .. } | Self::GrantNotSaved { .. } => {
                f.write_str("Could not access the saved sign-in. Unlock the device and try again.")
            }
            Self::InvalidGrantRecord { .. } => {
                f.write_str("The saved sign-in is invalid. Sign in again.")
            }
            Self::Cancelled => f.write_str("Sign-in was cancelled."),
        }
    }
}

impl std::error::Error for OidcError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Network {
                cause: NetworkCause::Transport(error),
                ..
            } => Some(error),
            Self::Store { error, .. } | Self::GrantNotSaved { error, .. } => Some(error),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::TransportError;
    use std::error::Error as _;

    #[test]
    fn hosted_errors_tell_the_user_what_to_do() {
        let cases = [
            (HostedAuthError::InvalidBaseUrl, "Use an HTTPS API URL"),
            (HostedAuthError::NotConnected, "Connect to the server"),
            (HostedAuthError::IdentityUnavailable, "did not confirm"),
            (HostedAuthError::IdentityMismatch, "differs from the saved"),
            (
                HostedAuthError::BrowserLoginExpired { reason: None },
                "Browser login expired",
            ),
            (
                HostedAuthError::BrowserLoginRejected {
                    status: 403,
                    reason: Some("no access".into()),
                },
                "Browser login failed: no access",
            ),
            (
                HostedAuthError::BrowserLoginRejected {
                    status: 403,
                    reason: Some(String::new()),
                },
                "Browser login failed. Start a new sign-in.",
            ),
            (
                HostedAuthError::LoginUpgradeRequired {
                    message: Some("Update to 2.0".into()),
                },
                "Update to 2.0",
            ),
            (
                HostedAuthError::LoginUpgradeRequired { message: None },
                "needs a newer sign-in",
            ),
            (
                HostedAuthError::MalformedResponse {
                    detail: "hidden".into(),
                },
                "could not read",
            ),
            (HostedAuthError::RedirectNotAllowed, "redirected"),
            (
                HostedAuthError::Unauthorized { reason: None },
                "Sign in again",
            ),
            (HostedAuthError::Forbidden, "denied access"),
            (
                HostedAuthError::HttpStatus { status: 500 },
                "returned HTTP 500",
            ),
            (HostedAuthError::CredentialExpired, "has expired"),
            (
                HostedAuthError::InvalidCredentialRecord,
                "could not be read",
            ),
            (
                HostedAuthError::Entropy(EntropyError::Unavailable {
                    message: "rng".into(),
                }),
                "secure sign-in",
            ),
        ];
        for (error, expected) in cases {
            let text = error.to_string();
            assert!(text.contains(expected), "{error:?}: {text}");
        }
        assert!(
            !HostedAuthError::MalformedResponse {
                detail: "hidden".into()
            }
            .to_string()
            .contains("hidden"),
            "decoder detail stays out of the message"
        );
    }

    #[test]
    fn a_mismatched_identity_counts_as_ended_by_the_server() {
        assert_eq!(
            HostedAuthError::IdentityMismatch.failure(),
            AuthFailure::EndedByServer
        );
    }

    #[test]
    fn hosted_errors_keep_their_source() {
        let transport = TransportError::Cancelled;
        assert_eq!(
            HostedAuthError::Transport(transport.clone())
                .source()
                .map(ToString::to_string),
            Some(transport.to_string())
        );
        let store = SecureStoreError::Unavailable {
            message: "locked".into(),
        };
        assert_eq!(
            HostedAuthError::Store(store.clone())
                .source()
                .map(ToString::to_string),
            Some(store.to_string())
        );
        let entropy = EntropyError::Unavailable {
            message: "rng".into(),
        };
        let from: HostedAuthError = entropy.clone().into();
        assert_eq!(from, HostedAuthError::Entropy(entropy.clone()));
        assert_eq!(
            from.source().map(ToString::to_string),
            Some(entropy.to_string())
        );
        assert!(HostedAuthError::Forbidden.source().is_none());
    }

    #[test]
    fn oidc_errors_tell_the_user_what_to_do() {
        let host = || "h.example".to_owned();
        let store = SecureStoreError::Unavailable {
            message: "locked".into(),
        };
        let cases = [
            (OidcError::InvalidServerUrl, "valid server URL"),
            (
                OidcError::RedirectNotAccepted { host: host() },
                "h.example doesn't support signing in",
            ),
            (
                OidcError::BrowserUnavailable { host: host() },
                "Couldn't open the sign-in page for h.example",
            ),
            (
                OidcError::InvalidCallback { host: host() },
                "Sign-in to h.example didn't complete",
            ),
            (
                OidcError::SignInRefused {
                    host: host(),
                    description: Some("domain not allowed".into()),
                },
                "domain not allowed",
            ),
            (
                OidcError::SignInRefused {
                    host: host(),
                    description: Some(String::new()),
                },
                "h.example didn't accept the sign-in",
            ),
            (
                OidcError::SessionRejected { host: host() },
                "h.example didn't accept the session",
            ),
            (
                OidcError::Store {
                    host: host(),
                    error: store,
                },
                "Could not access the saved sign-in",
            ),
            (
                OidcError::InvalidGrantRecord { host: host() },
                "saved sign-in is invalid",
            ),
            (OidcError::Cancelled, "cancelled"),
        ];
        for (error, expected) in cases {
            let text = error.to_string();
            assert!(text.contains(expected), "{error:?}: {text}");
        }
        assert_eq!(OidcError::Cancelled.failure(), AuthFailure::Failed);
    }

    #[test]
    fn oidc_errors_keep_their_source() {
        let transport = TransportError::Cancelled;
        let network = OidcError::Network {
            host: "h".into(),
            cause: NetworkCause::Transport(transport.clone()),
        };
        assert_eq!(
            network.source().map(ToString::to_string),
            Some(transport.to_string())
        );
        let store = SecureStoreError::Unavailable {
            message: "locked".into(),
        };
        let saved = OidcError::GrantNotSaved {
            host: "h".into(),
            error: store.clone(),
            revocation: RevokeOutcome::Revoked,
        };
        assert_eq!(
            saved.source().map(ToString::to_string),
            Some(store.to_string())
        );
        assert!(OidcError::Cancelled.source().is_none());
    }

    #[test]
    fn taxonomy_maps_each_cause() {
        let host = "h".to_owned();
        assert_eq!(
            OidcError::GrantExpired { host: host.clone() }.failure(),
            AuthFailure::Expired
        );
        assert_eq!(
            OidcError::GrantRejected { host: host.clone() }.failure(),
            AuthFailure::EndedByServer
        );
        assert_eq!(
            OidcError::NoStoredGrant { host: host.clone() }.failure(),
            AuthFailure::SignInRequired
        );
        assert_eq!(
            OidcError::SignInRefused {
                host: host.clone(),
                description: Some("domain not allowed".into())
            }
            .failure(),
            AuthFailure::Refused {
                reason: Some("domain not allowed".into())
            }
        );
        assert_eq!(
            OidcError::Network {
                host,
                cause: NetworkCause::Status(500)
            }
            .failure(),
            AuthFailure::Transport
        );
        assert_eq!(
            HostedAuthError::Unauthorized { reason: None }.failure(),
            AuthFailure::SignInRequired
        );
        assert_eq!(
            HostedAuthError::CredentialExpired.failure(),
            AuthFailure::Expired
        );
        assert_eq!(
            HostedAuthError::Transport(TransportError::Cancelled).failure(),
            AuthFailure::Transport
        );
    }

    #[test]
    fn messages_never_include_transport_secrets_beyond_host_detail() {
        let error = HostedAuthError::Transport(TransportError::Offline {
            message: "no route".into(),
        });
        assert_eq!(
            error.to_string(),
            "Could not reach the server (offline: no route). Check the address and network \
             connection."
        );
    }
}
