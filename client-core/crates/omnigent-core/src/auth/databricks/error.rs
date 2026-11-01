//! Every failure the Databricks flows report.
//!
//! One enum covers the three Swift enums (`DatabricksOAuthError`, `DatabricksCredentialError`,
//! `DatabricksSessionError`) plus cancellation, so a host can map each case to its own message
//! without string matching. `Display` is the user-facing text: it is fixed per variant and never
//! includes provider descriptions, response bodies, or token material.

use thiserror::Error;

use crate::auth::error_text::{PlatformError, connection_error_message};
use crate::auth::{EntropyError, SecureStoreError};
use crate::http::TransportError;

/// A Databricks sign-in, credential, or workspace-session failure.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum DatabricksError {
    /// The build's OAuth client id is missing, blank, or an unexpanded build setting.
    #[error("Configure a Databricks OAuth client ID for this build.")]
    InvalidClientId,
    /// The build's redirect URL is not an unambiguous HTTPS URL with a path.
    #[error("Configure a valid HTTPS OAuth redirect URL for this build.")]
    InvalidRedirectUrl,
    /// The URL is not an HTTPS Databricks workspace URL (or has a malformed `o=` selector).
    #[error("Databricks OAuth requires an HTTPS workspace URL.")]
    InvalidWorkspace,
    /// The host could not supply random bytes for `state` or the PKCE verifier.
    #[error("Could not prepare secure sign-in. Please try again.")]
    RandomGenerationFailed(EntropyError),
    /// The browser returned a callback that does not match this attempt.
    #[error("Databricks returned an invalid sign-in callback.")]
    InvalidCallback,
    /// The callback's `iss` (or a stored issuer) is not a supported Databricks issuer.
    #[error("Databricks returned an unsupported OAuth issuer.")]
    InvalidIssuer,
    /// The issuer's discovery document is missing or does not confirm the issuer and endpoint.
    #[error("Databricks returned inconsistent OAuth provider metadata.")]
    InvalidDiscovery,
    /// The provider answered `error=access_denied`.
    #[error("Databricks sign-in was not authorized.")]
    AuthorizationDenied,
    /// The provider answered any other `error=`.
    #[error("Databricks could not authorize this sign-in.")]
    AuthorizationFailed,
    /// Another sign-in is already running.
    #[error("A Databricks sign-in is already in progress.")]
    LoginInProgress,
    /// The host could not present the sign-in browser.
    #[error("Could not present the sign-in browser.")]
    BrowserUnavailable,
    /// The sign-in browser failed. Its platform message is deliberately not kept.
    #[error("Databricks browser sign-in failed.")]
    AuthenticationFailed,
    /// No response at all from Databricks. The host's transport error is kept for diagnostics.
    #[error("Could not reach Databricks. Please try again.")]
    NetworkUnavailable(TransportError),
    /// The token endpoint answered with a non-200 status (other than a refresh `invalid_grant`).
    #[error("Databricks could not complete sign-in. Please sign in again.")]
    TokenExchangeFailed {
        /// The HTTP status. The body is never kept.
        status: u16,
    },
    /// A refresh answered HTTP 400 `invalid_grant`: the saved grant is gone.
    #[error("The saved Databricks session has expired. Please sign in again.")]
    InvalidRefreshGrant,
    /// The token endpoint answered 200 with a body that is not a usable token bundle.
    #[error("Databricks returned an invalid token response.")]
    InvalidTokenResponse,
    /// The host's secure store failed (for example, the device is locked).
    #[error("Could not access saved Databricks credentials. Unlock the device and try again.")]
    Storage(SecureStoreError),
    /// A saved credential record is malformed, from a future version, or inconsistent.
    #[error("The saved Databricks credentials are invalid. Sign in again.")]
    InvalidCredentialData,
    /// The saved credentials changed (cleared, replaced, or signed out) while an operation ran.
    #[error("Workspace credentials changed. Reconnect to continue.")]
    CredentialsChanged,
    /// Databricks returned an invalid session-creation response.
    #[error("Databricks returned an invalid session response.")]
    InvalidSessionResponse,
    /// Session creation redirected somewhere unsupported.
    #[error("Databricks returned an unsupported session redirect.")]
    UnsafeRedirect,
    /// The page, store, or redirect belongs to a different workspace.
    #[error("The workspace changed. Select the intended workspace and reconnect.")]
    WorkspaceChanged,
    /// A session cookie had an unsupported scope or security attributes.
    #[error(
        "Databricks returned a session cookie with an unsupported scope or security attributes."
    )]
    UnsafeCookie,
    /// No usable `DBAUTH` cookie for the workspace page.
    #[error("Databricks did not create a session cookie for this workspace.")]
    MissingCookie,
    /// Session creation finished somewhere other than the workspace page.
    #[error("Databricks did not finish loading the workspace session.")]
    UnexpectedLanding,
    /// Session creation answered an HTTP error status.
    #[error("Databricks rejected session creation (HTTP {status}).")]
    Rejected {
        /// The HTTP status.
        status: u16,
    },
    /// The host could not present the sign-in browser for a recovery prompt.
    #[error("Could not present the sign-in browser. Please try again.")]
    PresentationUnavailable,
    /// An account-issuer grant needs an `o=` workspace selector.
    #[error("Enter a workspace-specific URL, including its o parameter when required.")]
    WorkspaceRequired,
    /// Silent recovery found no usable grant; the user must sign in again.
    #[error("Your workspace session expired. Sign in again to continue.")]
    ReauthenticationRequired,
    /// Automatic recovery is exhausted for now.
    #[error("The workspace session could not be restored. Reconnect to try again.")]
    RecoveryExhausted,
    /// Sign-out cleanup did not finish; it must be retried before any new sign-in.
    #[error("Sign-out could not finish. Reconnect to retry cleanup before signing in.")]
    SignOutIncomplete {
        /// Why the cleanup failed.
        cause: Box<Self>,
    },
    /// The operation was cancelled or superseded. Hosts show no message for it.
    #[error("Sign-in was cancelled. You can try again.")]
    Cancelled,
}

impl DatabricksError {
    /// The message to show the user, or `None` when the failure should stay silent
    /// (cancellation returns to setup without an error).
    #[must_use]
    pub fn user_message(&self) -> Option<String> {
        match self {
            Self::Cancelled => None,
            other => Some(other.to_string()),
        }
    }

    /// Whether this is [`DatabricksError::Cancelled`].
    #[must_use]
    pub const fn is_cancelled(&self) -> bool {
        matches!(self, Self::Cancelled)
    }

    /// Maps a transport failure: cancellation stays cancellation, everything else is
    /// [`DatabricksError::NetworkUnavailable`] carrying the host's error.
    #[must_use]
    pub fn from_transport(error: TransportError) -> Self {
        match error {
            TransportError::Cancelled => Self::Cancelled,
            other => Self::NetworkUnavailable(other),
        }
    }
}

impl From<SecureStoreError> for DatabricksError {
    fn from(error: SecureStoreError) -> Self {
        Self::Storage(error)
    }
}

/// A failure that ends a workspace connection: one of ours, or a platform error the host saw
/// directly (a page load, or a request outside the core).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkspaceFailure<'a> {
    /// A Databricks sign-in, credential, or session failure.
    Databricks(&'a DatabricksError),
    /// A platform error, classified by domain and code.
    Platform(&'a PlatformError),
}

/// What to show when a workspace connection fails. Port of
/// `OmnigentWebView.Coordinator.workspaceErrorMessage`.
///
/// Nothing after cancellation (the user returns to setup), the shared page-load wording for
/// platform errors (so an unreachable managed host reads the same during native sign-in as during
/// a page load), and the fixed message otherwise.
#[must_use]
pub fn workspace_error_message(
    failure: WorkspaceFailure<'_>,
    databricks_internal_features: bool,
) -> Option<String> {
    match failure {
        WorkspaceFailure::Databricks(error) => error.user_message(),
        WorkspaceFailure::Platform(error) => Some(connection_error_message(
            error,
            databricks_internal_features,
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::error_text::{
        JAMF_COMPLIANCE_MESSAGE, NS_URL_ERROR_CANNOT_FIND_HOST, NS_URL_ERROR_DOMAIN,
    };

    /// `DatabricksWorkspaceBootstrapTests::testCancellationReturnsToSetupWithoutAnErrorMessage`.
    #[test]
    fn error_cancellation_has_no_message() {
        assert_eq!(DatabricksError::Cancelled.user_message(), None);
        assert_eq!(
            DatabricksError::from_transport(TransportError::Cancelled).user_message(),
            None
        );
    }

    /// `DatabricksWorkspaceBootstrapTests::testConfigurationAndSessionFailuresStillHaveMessages`.
    #[test]
    fn error_auth_failures_keep_messages() {
        for error in [
            DatabricksError::InvalidClientId,
            DatabricksError::MissingCookie,
            DatabricksError::NetworkUnavailable(TransportError::Offline {
                message: "offline".into(),
            }),
            DatabricksError::Rejected { status: 403 },
        ] {
            assert_eq!(error.user_message(), Some(error.to_string()), "{error:?}");
        }
        assert_eq!(
            DatabricksError::Rejected { status: 403 }.to_string(),
            "Databricks rejected session creation (HTTP 403)."
        );
    }

    /// `DatabricksWorkspaceBootstrapTests::testUnreachableManagedHostKeepsTheSharedPageLoadGuidance`.
    #[test]
    fn error_unreachable_workspace_matches_page_guidance() {
        let unreachable = PlatformError {
            domain: NS_URL_ERROR_DOMAIN.into(),
            code: NS_URL_ERROR_CANNOT_FIND_HOST,
            localized_description: "A server with the specified hostname could not be found."
                .into(),
        };
        let failure = WorkspaceFailure::Platform(&unreachable);
        assert_eq!(
            workspace_error_message(failure, true),
            Some(connection_error_message(&unreachable, true))
        );
        assert_eq!(
            workspace_error_message(failure, true).as_deref(),
            Some(JAMF_COMPLIANCE_MESSAGE)
        );
        assert_eq!(
            workspace_error_message(failure, false),
            Some(unreachable.localized_description.clone())
        );
        // Cancellation stays silent regardless of the managed flag.
        for flag in [true, false] {
            assert_eq!(
                workspace_error_message(
                    WorkspaceFailure::Databricks(&DatabricksError::Cancelled),
                    flag
                ),
                None
            );
        }
        let rejected = DatabricksError::Rejected { status: 403 };
        assert_eq!(
            workspace_error_message(WorkspaceFailure::Databricks(&rejected), true),
            Some(rejected.to_string())
        );
    }

    #[test]
    fn messages_never_carry_host_details() {
        let error = DatabricksError::Storage(SecureStoreError::Unavailable {
            message: "OSStatus -25308".into(),
        });
        assert!(!error.to_string().contains("-25308"));
        let error = DatabricksError::from_transport(TransportError::Other {
            message: "secret-host-detail".into(),
        });
        assert!(!error.to_string().contains("secret-host-detail"));
    }
}
