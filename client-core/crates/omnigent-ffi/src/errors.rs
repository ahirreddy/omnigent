//! The one error type Swift sees. Every core error converts into it without losing its kind;
//! messages are the core's user-facing text and never carry credentials.

use omnigent_core as core;
use omnigent_core::SessionError;
use omnigent_core::auth::databricks::DatabricksError;
use omnigent_core::auth::errors::{AuthFailure as CoreAuthFailure, HostedAuthError, OidcError};
use omnigent_core::realtime::LinkError;

/// Longest server body kept in [`CoreError::HttpStatus`].
const MAX_BODY_CHARS: usize = 1_000;

/// The kind of a transport failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TransportErrorKind {
    /// No network path.
    Offline,
    /// Timed out.
    Timeout,
    /// Cancelled.
    Cancelled,
    /// TLS failed.
    Tls,
    /// Anything else.
    Other,
}

/// What a sign-in failure means for the user.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AuthFailure {
    /// The credential expired; sign in again.
    Expired,
    /// The server ended the session, or the account changed.
    EndedByServer,
    /// Sign-in is required.
    SignInRequired,
    /// The identity provider refused.
    Refused {
        /// The provider's reason, when given.
        reason: Option<String>,
    },
    /// The network failed; retrying may help.
    Transport,
    /// Anything else.
    Failed,
}

/// [`SessionError`]'s variants.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
#[allow(
    missing_docs,
    reason = "each variant mirrors the SessionError variant of the same name"
)]
pub enum SessionErrorKind {
    NotConnected,
    InvalidIdentifier,
    InvalidPageLimit,
    InvalidPagination,
    MalformedResponse,
    RedirectNotAllowed,
    Unauthorized,
    Forbidden,
    SessionNotFound,
    HttpStatus,
    Rejected,
    Transport,
    Cancelled,
    DeliveryUncertain,
    StreamNotReady,
    ExecutionUnavailable,
    MessageDenied,
    ReadOnly,
    EmptyMessage,
    Busy,
    Archived,
    InvalidTitle,
    Decision,
    Configuration,
    Creation,
    Ledger,
    Draft,
    Upload,
    Auth,
    Sync,
}

/// [`HostedAuthError`]'s variants.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
#[allow(
    missing_docs,
    reason = "each variant mirrors the HostedAuthError variant of the same name"
)]
pub enum AuthErrorKind {
    InvalidBaseUrl,
    NotConnected,
    UnsupportedAuthentication,
    IdentityUnavailable,
    IdentityMismatch,
    BrowserLoginExpired,
    BrowserLoginRejected,
    LoginUpgradeRequired,
    MalformedResponse,
    RedirectNotAllowed,
    Unauthorized,
    Forbidden,
    HttpStatus,
    Transport,
    CredentialExpired,
    InvalidCredentialRecord,
    Store,
    Entropy,
}

/// [`OidcError`]'s variants.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
#[allow(
    missing_docs,
    reason = "each variant mirrors the OidcError variant of the same name"
)]
pub enum OidcErrorKind {
    InvalidServerUrl,
    RedirectNotAccepted,
    BrowserUnavailable,
    InvalidCallback,
    SignInRefused,
    ExchangeFailed,
    GrantExpired,
    GrantRejected,
    NoStoredGrant,
    Network,
    SessionRejected,
    Store,
    GrantNotSaved,
    InvalidGrantRecord,
    Cancelled,
}

/// [`LinkError`]'s variants: why a realtime connection ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
#[allow(
    missing_docs,
    reason = "each variant mirrors the LinkError variant of the same name"
)]
pub enum LinkErrorKind {
    HttpStatus,
    UnexpectedContentType,
    Connection,
    EndOfStream,
    Stalled,
    Sse,
    MalformedEvent,
    SocketClosed,
    MalformedFrame,
    SendFailed,
    Hydration,
    HostContract,
}

/// `omnigent_core::auth::databricks::DatabricksError`'s variants.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
#[allow(
    missing_docs,
    reason = "each variant mirrors the DatabricksError variant of the same name"
)]
pub enum DatabricksErrorKind {
    NotConfigured,
    InvalidClientId,
    InvalidRedirectUrl,
    InvalidWorkspace,
    RandomGenerationFailed,
    InvalidCallback,
    InvalidIssuer,
    InvalidDiscovery,
    AuthorizationDenied,
    AuthorizationFailed,
    LoginInProgress,
    BrowserUnavailable,
    AuthenticationFailed,
    NetworkUnavailable,
    TokenExchangeFailed,
    InvalidRefreshGrant,
    InvalidTokenResponse,
    Storage,
    InvalidCredentialData,
    CredentialsChanged,
    InvalidSessionResponse,
    UnsafeRedirect,
    WorkspaceChanged,
    UnsafeCookie,
    MissingCookie,
    UnexpectedLanding,
    Rejected,
    PresentationUnavailable,
    WorkspaceRequired,
    ReauthenticationRequired,
    RecoveryExhausted,
    SignOutIncomplete,
    Cancelled,
}

/// Every failure the core reports to the host, thrown by calls and carried by listener events.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    /// The server URL was rejected before any request.
    #[error("{message}")]
    InvalidUrl {
        /// Why, for display.
        message: String,
    },
    /// The host transport failed.
    #[error("{message}")]
    Transport {
        /// The failure kind.
        kind: TransportErrorKind,
        /// Kind and host detail.
        message: String,
    },
    /// The server answered with an unexpected status.
    #[error("server answered HTTP {status}")]
    HttpStatus {
        /// HTTP status code.
        status: u16,
        /// The start of the response body, decoded lossily.
        body: String,
    },
    /// A response could not be decoded.
    #[error("{message}")]
    Decode {
        /// Decoder detail.
        message: String,
    },
    /// A session operation failed.
    #[error("{message}")]
    Session {
        /// The failure kind.
        kind: SessionErrorKind,
        /// For display.
        message: String,
        /// For logs; never a credential.
        detail: Option<String>,
        /// The connection ended; sign in again.
        requires_sign_in: bool,
        /// A write may have landed; it is never retried automatically.
        delivery_uncertain: bool,
    },
    /// Hosted sign-in or identity confirmation failed.
    #[error("{message}")]
    Auth {
        /// The failure kind.
        kind: AuthErrorKind,
        /// What it means for the user.
        failure: AuthFailure,
        /// For display.
        message: String,
        /// For logs; never a credential.
        detail: Option<String>,
    },
    /// Native OIDC sign-in, refresh or sign-out failed.
    #[error("{message}")]
    Oidc {
        /// The failure kind.
        kind: OidcErrorKind,
        /// What it means for the user.
        failure: AuthFailure,
        /// For display.
        message: String,
    },
    /// A realtime connection failed for good.
    #[error("{message}")]
    Link {
        /// The failure kind.
        kind: LinkErrorKind,
        /// For display.
        message: String,
        /// The credentials were rejected; sign in again.
        requires_sign_in: bool,
    },
    /// The session-updates watch set was refused.
    #[error("{message}")]
    Watch {
        /// For display.
        message: String,
    },
    /// The conversation sync could not apply an event or history read.
    #[error("{message}")]
    Sync {
        /// For display.
        message: String,
    },
    /// A configuration read was not accepted.
    #[error("{message}")]
    ConfigurationRead {
        /// For display.
        message: String,
    },
    /// Row operations did not fit the rows they were applied to.
    #[error("{message}")]
    RowOps {
        /// For display.
        message: String,
    },
    /// Saved settings could not be read or written.
    #[error("{message}")]
    Settings {
        /// For display.
        message: String,
    },
    /// Managed (MDM) preferences are invalid.
    #[error("{message}")]
    ManagedConfig {
        /// For display.
        message: String,
        /// The iOS managed-app-configuration feedback code.
        ios_code: u16,
        /// The preference domain, when known.
        domain: Option<String>,
    },
    /// An `omnigent://` link was rejected.
    #[error("{message}")]
    DeepLink {
        /// For display.
        message: String,
    },
    /// A notification payload or scope was rejected.
    #[error("{message}")]
    Notification {
        /// For display.
        message: String,
    },
    /// The host's secure store failed.
    #[error("{message}")]
    SecureStore {
        /// For display.
        message: String,
        /// The device is locked.
        unavailable: bool,
    },
    /// The host could not supply random bytes.
    #[error("{message}")]
    Entropy {
        /// For display.
        message: String,
    },
    /// A file cannot be attached.
    #[error("{message}")]
    Attachment {
        /// For display.
        message: String,
    },
    /// A workspace file operation failed.
    #[error("{message}")]
    Workspace {
        /// The failure kind.
        kind: crate::workspace::WorkspaceErrorKind,
        /// The core's text, with the server's reason when it gave one.
        message: String,
        /// The connection ended; sign in again.
        requires_sign_in: bool,
    },
    /// A terminal REST call failed.
    #[error("{message}")]
    Terminal {
        /// The failure kind.
        kind: crate::terminal::TerminalErrorKind,
        /// For display.
        message: String,
        /// The connection ended; sign in again.
        requires_sign_in: bool,
    },
    /// A Databricks workspace sign-in, token or refresh failed.
    #[error("{message}")]
    Databricks {
        /// The failure kind.
        kind: DatabricksErrorKind,
        /// For display. Empty for a cancellation, which shows no message.
        message: String,
        /// The saved grant is gone or changed; sign in again.
        requires_sign_in: bool,
    },
    /// A call the core cannot honour in its current state, for example an unknown sign-in
    /// attempt.
    #[error("{message}")]
    InvalidState {
        /// For display.
        message: String,
    },
}

impl CoreError {
    pub(crate) fn invalid_state(message: impl Into<String>) -> Self {
        Self::InvalidState {
            message: message.into(),
        }
    }

    /// Whether the user must sign in again.
    pub(crate) const fn requires_sign_in(&self) -> bool {
        match self {
            Self::Session {
                requires_sign_in, ..
            }
            | Self::Link {
                requires_sign_in, ..
            }
            | Self::Workspace {
                requires_sign_in, ..
            }
            | Self::Terminal {
                requires_sign_in, ..
            }
            | Self::Databricks {
                requires_sign_in, ..
            } => *requires_sign_in,
            Self::Auth { failure, .. } | Self::Oidc { failure, .. } => {
                matches!(failure, AuthFailure::SignInRequired | AuthFailure::Expired)
            }
            _ => false,
        }
    }
}

fn truncated(text: &str) -> String {
    text.chars().take(MAX_BODY_CHARS).collect()
}

impl From<&core::http::TransportError> for TransportErrorKind {
    fn from(error: &core::http::TransportError) -> Self {
        use core::http::TransportError as Core;
        match error {
            Core::Offline { .. } => Self::Offline,
            Core::Timeout { .. } => Self::Timeout,
            Core::Cancelled => Self::Cancelled,
            Core::Tls { .. } => Self::Tls,
            Core::Other { .. } => Self::Other,
        }
    }
}

impl From<core::http::TransportError> for CoreError {
    fn from(error: core::http::TransportError) -> Self {
        Self::Transport {
            kind: (&error).into(),
            message: error.to_string(),
        }
    }
}

impl From<CoreAuthFailure> for AuthFailure {
    fn from(failure: CoreAuthFailure) -> Self {
        match failure {
            CoreAuthFailure::Expired => Self::Expired,
            CoreAuthFailure::EndedByServer => Self::EndedByServer,
            CoreAuthFailure::SignInRequired => Self::SignInRequired,
            CoreAuthFailure::Refused { reason } => Self::Refused { reason },
            CoreAuthFailure::Transport => Self::Transport,
            CoreAuthFailure::Failed => Self::Failed,
        }
    }
}

const fn auth_kind(error: &HostedAuthError) -> AuthErrorKind {
    match error {
        HostedAuthError::InvalidBaseUrl => AuthErrorKind::InvalidBaseUrl,
        HostedAuthError::NotConnected => AuthErrorKind::NotConnected,
        HostedAuthError::UnsupportedAuthentication => AuthErrorKind::UnsupportedAuthentication,
        HostedAuthError::IdentityUnavailable => AuthErrorKind::IdentityUnavailable,
        HostedAuthError::IdentityMismatch => AuthErrorKind::IdentityMismatch,
        HostedAuthError::BrowserLoginExpired { .. } => AuthErrorKind::BrowserLoginExpired,
        HostedAuthError::BrowserLoginRejected { .. } => AuthErrorKind::BrowserLoginRejected,
        HostedAuthError::LoginUpgradeRequired { .. } => AuthErrorKind::LoginUpgradeRequired,
        HostedAuthError::MalformedResponse { .. } => AuthErrorKind::MalformedResponse,
        HostedAuthError::RedirectNotAllowed => AuthErrorKind::RedirectNotAllowed,
        HostedAuthError::Unauthorized { .. } => AuthErrorKind::Unauthorized,
        HostedAuthError::Forbidden => AuthErrorKind::Forbidden,
        HostedAuthError::HttpStatus { .. } => AuthErrorKind::HttpStatus,
        HostedAuthError::Transport(_) => AuthErrorKind::Transport,
        HostedAuthError::CredentialExpired => AuthErrorKind::CredentialExpired,
        HostedAuthError::InvalidCredentialRecord => AuthErrorKind::InvalidCredentialRecord,
        HostedAuthError::Store(_) => AuthErrorKind::Store,
        HostedAuthError::Entropy(_) => AuthErrorKind::Entropy,
    }
}

fn auth_detail(error: &HostedAuthError) -> Option<String> {
    match error {
        HostedAuthError::BrowserLoginExpired { reason }
        | HostedAuthError::BrowserLoginRejected { reason, .. }
        | HostedAuthError::Unauthorized { reason } => reason.clone(),
        HostedAuthError::MalformedResponse { detail } => Some(detail.clone()),
        HostedAuthError::Transport(error) => Some(error.to_string()),
        HostedAuthError::Store(error) => Some(error.to_string()),
        HostedAuthError::Entropy(error) => Some(error.to_string()),
        HostedAuthError::HttpStatus { status } => Some(format!("HTTP {status}")),
        _ => None,
    }
}

impl From<HostedAuthError> for CoreError {
    fn from(error: HostedAuthError) -> Self {
        Self::Auth {
            kind: auth_kind(&error),
            failure: error.failure().into(),
            message: error.to_string(),
            detail: auth_detail(&error),
        }
    }
}

const fn oidc_kind(error: &OidcError) -> OidcErrorKind {
    match error {
        OidcError::InvalidServerUrl => OidcErrorKind::InvalidServerUrl,
        OidcError::RedirectNotAccepted { .. } => OidcErrorKind::RedirectNotAccepted,
        OidcError::BrowserUnavailable { .. } => OidcErrorKind::BrowserUnavailable,
        OidcError::InvalidCallback { .. } => OidcErrorKind::InvalidCallback,
        OidcError::SignInRefused { .. } => OidcErrorKind::SignInRefused,
        OidcError::ExchangeFailed { .. } => OidcErrorKind::ExchangeFailed,
        OidcError::GrantExpired { .. } => OidcErrorKind::GrantExpired,
        OidcError::GrantRejected { .. } => OidcErrorKind::GrantRejected,
        OidcError::NoStoredGrant { .. } => OidcErrorKind::NoStoredGrant,
        OidcError::Network { .. } => OidcErrorKind::Network,
        OidcError::SessionRejected { .. } => OidcErrorKind::SessionRejected,
        OidcError::Store { .. } => OidcErrorKind::Store,
        OidcError::GrantNotSaved { .. } => OidcErrorKind::GrantNotSaved,
        OidcError::InvalidGrantRecord { .. } => OidcErrorKind::InvalidGrantRecord,
        OidcError::Cancelled => OidcErrorKind::Cancelled,
    }
}

impl From<OidcError> for CoreError {
    fn from(error: OidcError) -> Self {
        Self::Oidc {
            kind: oidc_kind(&error),
            failure: error.failure().into(),
            message: error.to_string(),
        }
    }
}

const fn link_kind(error: &LinkError) -> LinkErrorKind {
    match error {
        LinkError::HttpStatus { .. } => LinkErrorKind::HttpStatus,
        LinkError::UnexpectedContentType { .. } => LinkErrorKind::UnexpectedContentType,
        LinkError::Connection(_) => LinkErrorKind::Connection,
        LinkError::EndOfStream => LinkErrorKind::EndOfStream,
        LinkError::Stalled { .. } => LinkErrorKind::Stalled,
        LinkError::Sse(_) => LinkErrorKind::Sse,
        LinkError::MalformedEvent { .. } => LinkErrorKind::MalformedEvent,
        LinkError::SocketClosed { .. } => LinkErrorKind::SocketClosed,
        LinkError::MalformedFrame { .. } => LinkErrorKind::MalformedFrame,
        LinkError::SendFailed(_) => LinkErrorKind::SendFailed,
        LinkError::Hydration(_) => LinkErrorKind::Hydration,
        LinkError::HostContract { .. } => LinkErrorKind::HostContract,
    }
}

impl From<LinkError> for CoreError {
    fn from(error: LinkError) -> Self {
        Self::Link {
            kind: link_kind(&error),
            requires_sign_in: error.requires_sign_in(),
            message: error.to_string(),
        }
    }
}

const fn session_kind(error: &SessionError) -> SessionErrorKind {
    match error {
        SessionError::NotConnected => SessionErrorKind::NotConnected,
        SessionError::InvalidIdentifier { .. } => SessionErrorKind::InvalidIdentifier,
        SessionError::InvalidPageLimit { .. } => SessionErrorKind::InvalidPageLimit,
        SessionError::InvalidPagination => SessionErrorKind::InvalidPagination,
        SessionError::MalformedResponse { .. } => SessionErrorKind::MalformedResponse,
        SessionError::RedirectNotAllowed { .. } => SessionErrorKind::RedirectNotAllowed,
        SessionError::Unauthorized { .. } => SessionErrorKind::Unauthorized,
        SessionError::Forbidden => SessionErrorKind::Forbidden,
        SessionError::SessionNotFound { .. } => SessionErrorKind::SessionNotFound,
        SessionError::HttpStatus { .. } => SessionErrorKind::HttpStatus,
        SessionError::Rejected { .. } => SessionErrorKind::Rejected,
        SessionError::Transport(_) => SessionErrorKind::Transport,
        SessionError::Cancelled => SessionErrorKind::Cancelled,
        SessionError::DeliveryUncertain { .. } => SessionErrorKind::DeliveryUncertain,
        SessionError::StreamNotReady => SessionErrorKind::StreamNotReady,
        SessionError::ExecutionUnavailable { .. } => SessionErrorKind::ExecutionUnavailable,
        SessionError::MessageDenied { .. } => SessionErrorKind::MessageDenied,
        SessionError::ReadOnly => SessionErrorKind::ReadOnly,
        SessionError::EmptyMessage => SessionErrorKind::EmptyMessage,
        SessionError::Busy => SessionErrorKind::Busy,
        SessionError::Archived => SessionErrorKind::Archived,
        SessionError::InvalidTitle => SessionErrorKind::InvalidTitle,
        SessionError::Decision(_) => SessionErrorKind::Decision,
        SessionError::Configuration(_) => SessionErrorKind::Configuration,
        SessionError::Creation(_) => SessionErrorKind::Creation,
        SessionError::Ledger(_) => SessionErrorKind::Ledger,
        SessionError::Draft(_) => SessionErrorKind::Draft,
        SessionError::Upload(_) => SessionErrorKind::Upload,
        SessionError::Auth(_) => SessionErrorKind::Auth,
        SessionError::Sync(_) => SessionErrorKind::Sync,
    }
}

fn session_detail(error: &SessionError) -> Option<String> {
    match error {
        SessionError::InvalidIdentifier { value } => Some(format!("identifier {value:?}")),
        SessionError::InvalidPageLimit { limit } => Some(format!("limit {limit}")),
        SessionError::MalformedResponse { detail } | SessionError::DeliveryUncertain { detail } => {
            Some(detail.clone())
        }
        SessionError::RedirectNotAllowed { status } | SessionError::HttpStatus { status } => {
            Some(format!("HTTP {status}"))
        }
        SessionError::Rejected { status, .. } => Some(format!("HTTP {status}")),
        SessionError::Unauthorized { reason } | SessionError::MessageDenied { reason } => {
            reason.clone()
        }
        SessionError::SessionNotFound { session_id } => Some(format!("session {session_id}")),
        SessionError::Transport(error) => Some(error.to_string()),
        SessionError::Auth(error) => auth_detail(error),
        _ => None,
    }
}

impl From<SessionError> for CoreError {
    fn from(error: SessionError) -> Self {
        Self::Session {
            kind: session_kind(&error),
            message: error.to_string(),
            detail: session_detail(&error),
            requires_sign_in: error.requires_sign_in(),
            delivery_uncertain: matches!(
                error.submission_outcome(),
                core::ledger::SubmissionOutcome::Uncertain
            ),
        }
    }
}

impl From<core::CoreError> for CoreError {
    fn from(error: core::CoreError) -> Self {
        match error {
            core::CoreError::InvalidUrl { message } => Self::InvalidUrl { message },
            core::CoreError::Transport(error) => error.into(),
            core::CoreError::HttpStatus { status, body } => Self::HttpStatus {
                status,
                body: truncated(&body),
            },
            error @ core::CoreError::Decode { .. } => Self::Decode {
                message: error.to_string(),
            },
            core::CoreError::Auth(error) => error.into(),
            core::CoreError::Oidc(error) => error.into(),
            core::CoreError::Link(error) => error.into(),
            core::CoreError::Watch(error) => Self::Watch {
                message: error.to_string(),
            },
            core::CoreError::Sync(error) => Self::Sync {
                message: error.to_string(),
            },
            core::CoreError::ConfigurationRead(error) => Self::ConfigurationRead {
                message: error.to_string(),
            },
            core::CoreError::RowOps(error) => Self::RowOps {
                message: error.to_string(),
            },
            core::CoreError::Settings(error) => Self::Settings {
                message: error.to_string(),
            },
            core::CoreError::ManagedConfig(error) => Self::ManagedConfig {
                message: error.to_string(),
                ios_code: error.ios_code(),
                domain: error.domain().map(str::to_owned),
            },
            core::CoreError::DeepLink(error) => Self::DeepLink {
                message: error.to_string(),
            },
            core::CoreError::Notification(error) => Self::Notification {
                message: error.to_string(),
            },
        }
    }
}

/// Converts any core error that `core::CoreError` absorbs.
pub(crate) fn core_error(error: impl Into<core::CoreError>) -> CoreError {
    error.into().into()
}

impl From<core::auth::SecureStoreError> for CoreError {
    fn from(error: core::auth::SecureStoreError) -> Self {
        Self::SecureStore {
            unavailable: matches!(error, core::auth::SecureStoreError::Unavailable { .. }),
            message: error.to_string(),
        }
    }
}

impl From<core::attachments::AttachmentError> for CoreError {
    fn from(error: core::attachments::AttachmentError) -> Self {
        Self::Attachment {
            message: error.to_string(),
        }
    }
}

impl From<core::auth::EntropyError> for CoreError {
    fn from(error: core::auth::EntropyError) -> Self {
        Self::Entropy {
            message: error.to_string(),
        }
    }
}

const fn databricks_kind(error: &DatabricksError) -> DatabricksErrorKind {
    use DatabricksErrorKind as K;
    match error {
        DatabricksError::InvalidClientId => K::InvalidClientId,
        DatabricksError::InvalidRedirectUrl => K::InvalidRedirectUrl,
        DatabricksError::InvalidWorkspace => K::InvalidWorkspace,
        DatabricksError::RandomGenerationFailed(_) => K::RandomGenerationFailed,
        DatabricksError::InvalidCallback => K::InvalidCallback,
        DatabricksError::InvalidIssuer => K::InvalidIssuer,
        DatabricksError::InvalidDiscovery => K::InvalidDiscovery,
        DatabricksError::AuthorizationDenied => K::AuthorizationDenied,
        DatabricksError::AuthorizationFailed => K::AuthorizationFailed,
        DatabricksError::LoginInProgress => K::LoginInProgress,
        DatabricksError::BrowserUnavailable => K::BrowserUnavailable,
        DatabricksError::AuthenticationFailed => K::AuthenticationFailed,
        DatabricksError::NetworkUnavailable(_) => K::NetworkUnavailable,
        DatabricksError::TokenExchangeFailed { .. } => K::TokenExchangeFailed,
        DatabricksError::InvalidRefreshGrant => K::InvalidRefreshGrant,
        DatabricksError::InvalidTokenResponse => K::InvalidTokenResponse,
        DatabricksError::Storage(_) => K::Storage,
        DatabricksError::InvalidCredentialData => K::InvalidCredentialData,
        DatabricksError::CredentialsChanged => K::CredentialsChanged,
        DatabricksError::InvalidSessionResponse => K::InvalidSessionResponse,
        DatabricksError::UnsafeRedirect => K::UnsafeRedirect,
        DatabricksError::WorkspaceChanged => K::WorkspaceChanged,
        DatabricksError::UnsafeCookie => K::UnsafeCookie,
        DatabricksError::MissingCookie => K::MissingCookie,
        DatabricksError::UnexpectedLanding => K::UnexpectedLanding,
        DatabricksError::Rejected { .. } => K::Rejected,
        DatabricksError::PresentationUnavailable => K::PresentationUnavailable,
        DatabricksError::WorkspaceRequired => K::WorkspaceRequired,
        DatabricksError::ReauthenticationRequired => K::ReauthenticationRequired,
        DatabricksError::RecoveryExhausted => K::RecoveryExhausted,
        DatabricksError::SignOutIncomplete { .. } => K::SignOutIncomplete,
        DatabricksError::Cancelled => K::Cancelled,
    }
}

impl From<DatabricksError> for CoreError {
    fn from(error: DatabricksError) -> Self {
        Self::Databricks {
            kind: databricks_kind(&error),
            requires_sign_in: matches!(
                error,
                DatabricksError::InvalidRefreshGrant
                    | DatabricksError::InvalidCredentialData
                    | DatabricksError::CredentialsChanged
                    | DatabricksError::ReauthenticationRequired
            ),
            message: error.user_message().unwrap_or_default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_errors_keep_kind_and_flags() {
        let error: CoreError = SessionError::DeliveryUncertain {
            detail: "lost".into(),
        }
        .into();
        let CoreError::Session {
            kind,
            delivery_uncertain,
            requires_sign_in,
            detail,
            ..
        } = error
        else {
            panic!("expected a session error");
        };
        assert_eq!(kind, SessionErrorKind::DeliveryUncertain);
        assert!(delivery_uncertain);
        assert!(!requires_sign_in);
        assert_eq!(detail.as_deref(), Some("lost"));

        let unauthorized: CoreError = SessionError::Unauthorized { reason: None }.into();
        assert!(unauthorized.requires_sign_in());
    }

    #[test]
    fn link_errors_classify_sign_in() {
        let error: CoreError = LinkError::HttpStatus { status: 401 }.into();
        assert!(error.requires_sign_in());
        assert!(matches!(
            error,
            CoreError::Link {
                kind: LinkErrorKind::HttpStatus,
                ..
            }
        ));
    }

    #[test]
    fn auth_errors_keep_store_detail_out_of_the_message() {
        let error: CoreError = HostedAuthError::Store(core::auth::SecureStoreError::Unavailable {
            message: "errSecInteractionNotAllowed".into(),
        })
        .into();
        let CoreError::Auth {
            kind,
            message,
            detail,
            ..
        } = error
        else {
            panic!("expected an auth error");
        };
        assert_eq!(kind, AuthErrorKind::Store);
        assert!(message.contains("Keychain"), "{message}");
        assert!(
            detail
                .as_deref()
                .is_some_and(|detail| detail.contains("errSecInteractionNotAllowed"))
        );
    }

    #[test]
    fn http_status_bodies_are_bounded() {
        let error: CoreError = core::CoreError::HttpStatus {
            status: 500,
            body: "x".repeat(5_000),
        }
        .into();
        let CoreError::HttpStatus { body, .. } = error else {
            panic!("expected an HTTP status error");
        };
        assert_eq!(body.chars().count(), MAX_BODY_CHARS);
    }
}
