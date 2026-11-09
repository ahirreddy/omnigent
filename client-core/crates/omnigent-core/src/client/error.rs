//! The session client's error taxonomy.
//!
//! Port of `NativeLab`'s `LocalServerClientError` and `SessionClientError`, merged: every REST
//! session operation fails with one [`SessionError`]. Messages are the user-facing text the
//! Swift client showed; detail fields are for logs and never carry credentials or bodies that
//! could.

use crate::attachments::{DraftError, UploadError};
use crate::auth::errors::HostedAuthError;
use crate::config::session::ConfigurationError;
use crate::creation::CreationError;
use crate::decisions::resolve::DecisionError;
use crate::http::TransportError;
use crate::ledger::{LedgerError, SubmissionOutcome};
use crate::reconcile::SyncError;

/// Why a session operation failed.
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum SessionError {
    /// No connection, or it ended (sign-out, a `401`, or a disconnect while in flight).
    #[error("Connect to the server before loading sessions.")]
    NotConnected,
    /// A session, host or other id that cannot be a path segment. Nothing was sent.
    #[error("The session identifier is invalid. Refresh the session list.")]
    InvalidIdentifier {
        /// The rejected value.
        value: String,
    },
    /// A page limit outside `1..=1000`. Nothing was sent.
    #[error("Request between 1 and 1,000 items per page.")]
    InvalidPageLimit {
        /// The rejected limit.
        limit: u32,
    },
    /// An empty request cursor, or a page that claims more rows without a usable new cursor.
    #[error("The server returned an invalid page cursor. Refresh and try again.")]
    InvalidPagination,
    /// The body is not the shape the contract promises.
    #[error("The server returned data this app could not read. Check the server version.")]
    MalformedResponse {
        /// What was wrong, for logs.
        detail: String,
    },
    /// A 3xx on a read. Redirects are never followed.
    #[error("The server redirected this request. Use the direct API address.")]
    RedirectNotAllowed {
        /// The 3xx status.
        status: u16,
    },
    /// HTTP 401. The connection has ended; sign in again.
    #[error("Sign in again or provide a valid bearer token for this server.")]
    Unauthorized {
        /// The server's `error` text, when present.
        reason: Option<String>,
    },
    /// HTTP 403.
    #[error("The server denied access to this resource.")]
    Forbidden,
    /// HTTP 404 for a session-scoped read.
    #[error("This session is no longer available.")]
    SessionNotFound {
        /// The session asked for.
        session_id: String,
    },
    /// Any other unexpected status on a read.
    #[error("The server returned HTTP {status}. Check that it is running and try again.")]
    HttpStatus {
        /// The status.
        status: u16,
    },
    /// A write the server definitely refused (a 4xx other than 401 and 403).
    #[error("{message}")]
    Rejected {
        /// The status.
        status: u16,
        /// The server's explanation, or a generic one.
        message: String,
    },
    /// The host transport failed on a read.
    #[error("Could not reach the server ({0}). Check the address and network connection.")]
    Transport(TransportError),
    /// A read was cancelled.
    #[error("The request was cancelled.")]
    Cancelled,
    /// A write whose outcome is unknown. It is never retried automatically.
    #[error(
        "The server may have accepted this action, but confirmation was lost. Check the conversation before trying again."
    )]
    DeliveryUncertain {
        /// What happened, for logs.
        detail: String,
    },
    /// The session's live stream is not open and hydrated yet.
    #[error("Wait for the live connection to finish syncing before sending.")]
    StreamNotReady,
    /// The session's host is offline (HTTP 503 `host_offline`). The server recorded nothing, so
    /// the message is kept to send again once the host reconnects.
    #[error("{message}")]
    HostOffline {
        /// The server's explanation.
        message: String,
    },
    /// The session cannot run a message now.
    #[error("{reason}")]
    ExecutionUnavailable {
        /// What to do about it.
        reason: String,
    },
    /// The server declined the message (a policy denial). The draft is kept.
    #[error("The server declined this message. Your draft has been preserved.")]
    MessageDenied {
        /// The server's reason, when given.
        reason: Option<String>,
    },
    /// The caller cannot edit this session.
    #[error("You have read-only access to this session.")]
    ReadOnly,
    /// Nothing to send.
    #[error("Write a message before sending.")]
    EmptyMessage,
    /// Another configuration change for this session is in flight, or the session is busy.
    #[error("Wait for the reply or stop it before sending another message.")]
    Busy,
    /// The session is archived.
    #[error("Restore this session before sending a message.")]
    Archived,
    /// A field the user entered cannot be sent. Nothing was sent.
    #[error("{reason}")]
    InvalidInput {
        /// What to fix.
        reason: String,
    },
    /// A title that is blank or longer than 120 characters.
    #[error("Use a session name between 1 and 120 characters.")]
    InvalidTitle,
    /// A decision answer that cannot be sent.
    #[error("{0}")]
    Decision(DecisionError),
    /// A configuration change that cannot be applied.
    #[error("{0}")]
    Configuration(ConfigurationError),
    /// A session that cannot be (or may have been) created.
    #[error("{0}")]
    Creation(CreationError),
    /// The submission ledger refused the send.
    #[error("{0}")]
    Ledger(LedgerError),
    /// The attachment draft refused the operation.
    #[error("{0}")]
    Draft(DraftError),
    /// An attachment upload failed or a reference cannot be sent.
    #[error("{0}")]
    Upload(UploadError),
    /// Connecting failed.
    #[error("{0}")]
    Auth(HostedAuthError),
    /// A history read could not be applied to the live conversation; reconnect the stream.
    #[error("{0}")]
    Sync(SyncError),
    /// An agent browser action call failed.
    #[error("{0}")]
    BrowserAction(crate::client::browser::BrowserActionError),
    /// An attachment cannot be previewed.
    #[error("{0}")]
    Preview(crate::attachments::PreviewError),
}

impl SessionError {
    /// How a send that failed with this error ends in the submission ledger: only an unknown
    /// outcome is [`SubmissionOutcome::Uncertain`]; everything else definitely did not deliver.
    #[must_use]
    pub const fn submission_outcome(&self) -> SubmissionOutcome {
        match self {
            Self::DeliveryUncertain { .. } | Self::Creation(CreationError::Uncertain) => {
                SubmissionOutcome::Uncertain
            }
            Self::Upload(error) if error.is_uncertain() => SubmissionOutcome::Uncertain,
            _ => SubmissionOutcome::Rejected,
        }
    }

    /// Whether the connection ended and the user must sign in again.
    #[must_use]
    pub const fn requires_sign_in(&self) -> bool {
        matches!(
            self,
            Self::Unauthorized { .. }
                | Self::NotConnected
                | Self::Upload(UploadError::Unauthorized)
                | Self::Auth(
                    HostedAuthError::Unauthorized { .. } | HostedAuthError::IdentityMismatch
                )
        )
    }
}

impl From<HostedAuthError> for SessionError {
    fn from(error: HostedAuthError) -> Self {
        match error {
            HostedAuthError::NotConnected => Self::NotConnected,
            HostedAuthError::Transport(TransportError::Cancelled) => Self::Cancelled,
            HostedAuthError::Transport(error) => Self::Transport(error),
            other => Self::Auth(other),
        }
    }
}

impl From<ConfigurationError> for SessionError {
    fn from(error: ConfigurationError) -> Self {
        Self::Configuration(error)
    }
}

impl From<CreationError> for SessionError {
    fn from(error: CreationError) -> Self {
        Self::Creation(error)
    }
}

impl From<DecisionError> for SessionError {
    fn from(error: DecisionError) -> Self {
        Self::Decision(error)
    }
}

impl From<LedgerError> for SessionError {
    fn from(error: LedgerError) -> Self {
        Self::Ledger(error)
    }
}

impl From<DraftError> for SessionError {
    fn from(error: DraftError) -> Self {
        Self::Draft(error)
    }
}

impl From<UploadError> for SessionError {
    fn from(error: UploadError) -> Self {
        Self::Upload(error)
    }
}

impl From<crate::client::browser::BrowserActionError> for SessionError {
    fn from(error: crate::client::browser::BrowserActionError) -> Self {
        Self::BrowserAction(error)
    }
}

impl From<SyncError> for SessionError {
    fn from(error: SyncError) -> Self {
        Self::Sync(error)
    }
}
