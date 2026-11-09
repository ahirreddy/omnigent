//! Every core error reaches the host with its kind, details and flags.

#![allow(clippy::too_many_lines, reason = "tables with one case per variant")]

use omnigent_core as core;
use omnigent_core::SessionError;
use omnigent_core::attachments::{AttachmentError, DraftError, PreviewError, UploadError};
use omnigent_core::auth::databricks::DatabricksError;
use omnigent_core::auth::errors::{
    AuthFailure as CoreAuthFailure, ExchangeFailure, HostedAuthError, NetworkCause, OidcError,
    RevokeOutcome,
};
use omnigent_core::auth::{EntropyError, SecureStoreError};
use omnigent_core::config::managed::ManagedConfigError;
use omnigent_core::config::session::ConfigurationError;
use omnigent_core::config::settings::SettingsError;
use omnigent_core::creation::CreationError;
use omnigent_core::decisions::DecisionError;
use omnigent_core::deeplink::DeepLinkError;
use omnigent_core::http::TransportError;
use omnigent_core::ledger::LedgerError;
use omnigent_core::notifications::NotificationError;
use omnigent_core::realtime::{ConnectionFailure, HydrationFailure, LinkError, WatchError};
use omnigent_core::reconcile::{ConfigurationReadError, SyncError};
use omnigent_core::reducer::RowOpError;
use omnigent_core::sse::SseError;

use crate::errors::{
    AuthErrorKind, AuthFailure, CoreError, DatabricksErrorKind, LinkErrorKind, OidcErrorKind,
    SessionErrorKind, TransportErrorKind, core_error,
};
use crate::remote_browser::RemoteBrowserErrorKind;
use crate::terminal::TerminalErrorKind;
use crate::workspace::WorkspaceErrorKind;

fn offline() -> TransportError {
    TransportError::Offline {
        message: "no route".into(),
    }
}

fn store_error() -> SecureStoreError {
    SecureStoreError::Other {
        message: "locked".into(),
    }
}

#[test]
fn every_transport_failure_keeps_its_kind() {
    for (error, kind) in [
        (offline(), TransportErrorKind::Offline),
        (
            TransportError::Timeout {
                message: "slow".into(),
            },
            TransportErrorKind::Timeout,
        ),
        (TransportError::Cancelled, TransportErrorKind::Cancelled),
        (
            TransportError::Tls {
                message: "cert".into(),
            },
            TransportErrorKind::Tls,
        ),
        (
            TransportError::Other {
                message: "odd".into(),
            },
            TransportErrorKind::Other,
        ),
    ] {
        let message = error.to_string();
        assert_eq!(
            CoreError::from(error),
            CoreError::Transport { kind, message }
        );
    }
}

#[test]
fn every_auth_failure_maps() {
    for (on_core, on_ffi) in [
        (CoreAuthFailure::Expired, AuthFailure::Expired),
        (CoreAuthFailure::EndedByServer, AuthFailure::EndedByServer),
        (CoreAuthFailure::SignInRequired, AuthFailure::SignInRequired),
        (
            CoreAuthFailure::Refused {
                reason: Some("no".into()),
            },
            AuthFailure::Refused {
                reason: Some("no".into()),
            },
        ),
        (CoreAuthFailure::Transport, AuthFailure::Transport),
        (CoreAuthFailure::Failed, AuthFailure::Failed),
    ] {
        assert_eq!(AuthFailure::from(on_core), on_ffi);
    }
}

#[test]
fn every_hosted_auth_error_keeps_its_kind_failure_and_detail() {
    let reason = || Some("why".to_owned());
    let cases: Vec<(HostedAuthError, AuthErrorKind, AuthFailure, Option<&str>)> = vec![
        (
            HostedAuthError::InvalidBaseUrl,
            AuthErrorKind::InvalidBaseUrl,
            AuthFailure::Failed,
            None,
        ),
        (
            HostedAuthError::NotConnected,
            AuthErrorKind::NotConnected,
            AuthFailure::SignInRequired,
            None,
        ),
        (
            HostedAuthError::UnsupportedAuthentication,
            AuthErrorKind::UnsupportedAuthentication,
            AuthFailure::Failed,
            None,
        ),
        (
            HostedAuthError::IdentityUnavailable,
            AuthErrorKind::IdentityUnavailable,
            AuthFailure::Failed,
            None,
        ),
        (
            HostedAuthError::IdentityMismatch,
            AuthErrorKind::IdentityMismatch,
            AuthFailure::EndedByServer,
            None,
        ),
        (
            HostedAuthError::BrowserLoginExpired { reason: reason() },
            AuthErrorKind::BrowserLoginExpired,
            AuthFailure::Expired,
            Some("why"),
        ),
        (
            HostedAuthError::BrowserLoginRejected {
                status: 400,
                reason: reason(),
            },
            AuthErrorKind::BrowserLoginRejected,
            AuthFailure::Refused { reason: reason() },
            Some("why"),
        ),
        (
            HostedAuthError::LoginUpgradeRequired { message: None },
            AuthErrorKind::LoginUpgradeRequired,
            AuthFailure::Failed,
            None,
        ),
        (
            HostedAuthError::MalformedResponse {
                detail: "shape".into(),
            },
            AuthErrorKind::MalformedResponse,
            AuthFailure::Failed,
            Some("shape"),
        ),
        (
            HostedAuthError::RedirectNotAllowed,
            AuthErrorKind::RedirectNotAllowed,
            AuthFailure::Failed,
            None,
        ),
        (
            HostedAuthError::Unauthorized { reason: reason() },
            AuthErrorKind::Unauthorized,
            AuthFailure::SignInRequired,
            Some("why"),
        ),
        (
            HostedAuthError::Forbidden,
            AuthErrorKind::Forbidden,
            AuthFailure::Failed,
            None,
        ),
        (
            HostedAuthError::AccountRefused {
                status: 409,
                reason: reason(),
            },
            AuthErrorKind::AccountRefused,
            AuthFailure::Refused { reason: reason() },
            Some("why"),
        ),
        (
            HostedAuthError::HttpStatus { status: 502 },
            AuthErrorKind::HttpStatus,
            AuthFailure::Transport,
            Some("HTTP 502"),
        ),
        (
            HostedAuthError::CredentialExpired,
            AuthErrorKind::CredentialExpired,
            AuthFailure::Expired,
            None,
        ),
        (
            HostedAuthError::InvalidCredentialRecord,
            AuthErrorKind::InvalidCredentialRecord,
            AuthFailure::Failed,
            None,
        ),
    ];
    for (error, kind, failure, detail) in cases {
        let message = error.to_string();
        assert_eq!(
            CoreError::from(error),
            CoreError::Auth {
                kind,
                failure,
                message,
                detail: detail.map(str::to_owned),
            }
        );
    }
    let carrying_an_error = [
        (
            HostedAuthError::Transport(offline()),
            AuthErrorKind::Transport,
            offline().to_string(),
        ),
        (
            HostedAuthError::Store(store_error()),
            AuthErrorKind::Store,
            store_error().to_string(),
        ),
        (
            HostedAuthError::Entropy(EntropyError::ShortRead {
                requested: 2,
                received: 1,
            }),
            AuthErrorKind::Entropy,
            EntropyError::ShortRead {
                requested: 2,
                received: 1,
            }
            .to_string(),
        ),
    ];
    for (error, expected_kind, expected_detail) in carrying_an_error {
        let CoreError::Auth { kind, detail, .. } = CoreError::from(error) else {
            panic!("not an auth error");
        };
        assert_eq!(kind, expected_kind);
        assert_eq!(detail, Some(expected_detail));
    }
}

#[test]
fn every_oidc_error_keeps_its_kind_and_failure() {
    let host = || "h.example.com".to_owned();
    for (error, kind, failure) in [
        (
            OidcError::InvalidServerUrl,
            OidcErrorKind::InvalidServerUrl,
            AuthFailure::Failed,
        ),
        (
            OidcError::RedirectNotAccepted { host: host() },
            OidcErrorKind::RedirectNotAccepted,
            AuthFailure::Failed,
        ),
        (
            OidcError::BrowserUnavailable { host: host() },
            OidcErrorKind::BrowserUnavailable,
            AuthFailure::Failed,
        ),
        (
            OidcError::InvalidCallback { host: host() },
            OidcErrorKind::InvalidCallback,
            AuthFailure::Failed,
        ),
        (
            OidcError::SignInRefused {
                host: host(),
                description: Some("nope".into()),
            },
            OidcErrorKind::SignInRefused,
            AuthFailure::Refused {
                reason: Some("nope".into()),
            },
        ),
        (
            OidcError::ExchangeFailed {
                host: host(),
                cause: ExchangeFailure::InvalidToken,
            },
            OidcErrorKind::ExchangeFailed,
            AuthFailure::Failed,
        ),
        (
            OidcError::GrantExpired { host: host() },
            OidcErrorKind::GrantExpired,
            AuthFailure::Expired,
        ),
        (
            OidcError::GrantRejected { host: host() },
            OidcErrorKind::GrantRejected,
            AuthFailure::EndedByServer,
        ),
        (
            OidcError::NoStoredGrant { host: host() },
            OidcErrorKind::NoStoredGrant,
            AuthFailure::SignInRequired,
        ),
        (
            OidcError::Network {
                host: host(),
                cause: NetworkCause::Status(500),
            },
            OidcErrorKind::Network,
            AuthFailure::Transport,
        ),
        (
            OidcError::SessionRejected { host: host() },
            OidcErrorKind::SessionRejected,
            AuthFailure::EndedByServer,
        ),
        (
            OidcError::Store {
                host: host(),
                error: store_error(),
            },
            OidcErrorKind::Store,
            AuthFailure::Failed,
        ),
        (
            OidcError::GrantNotSaved {
                host: host(),
                error: store_error(),
                revocation: RevokeOutcome::Revoked,
            },
            OidcErrorKind::GrantNotSaved,
            AuthFailure::Failed,
        ),
        (
            OidcError::InvalidGrantRecord { host: host() },
            OidcErrorKind::InvalidGrantRecord,
            AuthFailure::Failed,
        ),
        (
            OidcError::Cancelled,
            OidcErrorKind::Cancelled,
            AuthFailure::Failed,
        ),
    ] {
        let message = error.to_string();
        assert_eq!(
            CoreError::from(error),
            CoreError::Oidc {
                kind,
                failure,
                message,
            }
        );
    }
}

#[test]
fn every_link_error_keeps_its_kind_and_sign_in_flag() {
    let challenge = || ConnectionFailure::AuthenticationRequired {
        message: "again".into(),
    };
    for (error, kind, requires_sign_in) in [
        (
            LinkError::HttpStatus { status: 404 },
            LinkErrorKind::NotFound,
            false,
        ),
        (
            LinkError::Hydration(HydrationFailure::HttpStatus { status: 404 }),
            LinkErrorKind::NotFound,
            false,
        ),
        (
            LinkError::HttpStatus { status: 401 },
            LinkErrorKind::HttpStatus,
            true,
        ),
        (
            LinkError::UnexpectedContentType { content_type: None },
            LinkErrorKind::UnexpectedContentType,
            false,
        ),
        (
            LinkError::Connection(challenge()),
            LinkErrorKind::Connection,
            true,
        ),
        (LinkError::EndOfStream, LinkErrorKind::EndOfStream, false),
        (
            LinkError::Stalled { silent_ms: 5 },
            LinkErrorKind::Stalled,
            false,
        ),
        (
            LinkError::Sse(SseError::LineTooLong { line: 1, limit: 2 }),
            LinkErrorKind::Sse,
            false,
        ),
        (
            LinkError::MalformedEvent {
                message: "x".into(),
            },
            LinkErrorKind::MalformedEvent,
            false,
        ),
        (
            LinkError::SocketClosed {
                code: 1000,
                reason: "bye".into(),
            },
            LinkErrorKind::SocketClosed,
            false,
        ),
        (
            LinkError::MalformedFrame {
                message: "x".into(),
            },
            LinkErrorKind::MalformedFrame,
            false,
        ),
        (
            LinkError::SendFailed(offline()),
            LinkErrorKind::SendFailed,
            false,
        ),
        (
            LinkError::Hydration(HydrationFailure::Malformed {
                message: "x".into(),
            }),
            LinkErrorKind::Hydration,
            false,
        ),
        (
            LinkError::Hydration(HydrationFailure::Connection(challenge())),
            LinkErrorKind::Hydration,
            true,
        ),
        (
            LinkError::HostContract {
                message: "x".into(),
            },
            LinkErrorKind::HostContract,
            false,
        ),
    ] {
        let message = error.to_string();
        assert_eq!(
            CoreError::from(error),
            CoreError::Link {
                kind,
                requires_sign_in,
                message,
            }
        );
    }
}

#[test]
fn every_session_error_keeps_its_kind_detail_and_flags() {
    use SessionErrorKind as K;
    let cases: Vec<(SessionError, SessionErrorKind, Option<&str>)> = vec![
        (SessionError::NotConnected, K::NotConnected, None),
        (
            SessionError::InvalidIdentifier { value: "x".into() },
            K::InvalidIdentifier,
            Some("identifier \"x\""),
        ),
        (
            SessionError::InvalidPageLimit { limit: 9 },
            K::InvalidPageLimit,
            Some("limit 9"),
        ),
        (SessionError::InvalidPagination, K::InvalidPagination, None),
        (
            SessionError::MalformedResponse { detail: "d".into() },
            K::MalformedResponse,
            Some("d"),
        ),
        (
            SessionError::RedirectNotAllowed { status: 302 },
            K::RedirectNotAllowed,
            Some("HTTP 302"),
        ),
        (
            SessionError::Unauthorized {
                reason: Some("r".into()),
            },
            K::Unauthorized,
            Some("r"),
        ),
        (SessionError::Forbidden, K::Forbidden, None),
        (
            SessionError::SessionNotFound {
                session_id: "s".into(),
            },
            K::SessionNotFound,
            Some("session s"),
        ),
        (
            SessionError::HttpStatus { status: 500 },
            K::HttpStatus,
            Some("HTTP 500"),
        ),
        (
            SessionError::Rejected {
                status: 409,
                message: "m".into(),
            },
            K::Rejected,
            Some("HTTP 409"),
        ),
        (SessionError::Cancelled, K::Cancelled, None),
        (
            SessionError::DeliveryUncertain { detail: "d".into() },
            K::DeliveryUncertain,
            Some("d"),
        ),
        (
            SessionError::HostOffline {
                message: "m".into(),
            },
            K::HostOffline,
            None,
        ),
        (SessionError::StreamNotReady, K::StreamNotReady, None),
        (
            SessionError::ExecutionUnavailable { reason: "r".into() },
            K::ExecutionUnavailable,
            None,
        ),
        (
            SessionError::MessageDenied {
                reason: Some("r".into()),
            },
            K::MessageDenied,
            Some("r"),
        ),
        (SessionError::ReadOnly, K::ReadOnly, None),
        (SessionError::EmptyMessage, K::EmptyMessage, None),
        (SessionError::Busy, K::Busy, None),
        (SessionError::Archived, K::Archived, None),
        (
            SessionError::InvalidInput { reason: "r".into() },
            K::InvalidInput,
            None,
        ),
        (SessionError::InvalidTitle, K::InvalidTitle, None),
        (
            SessionError::Decision(DecisionError::ReadOnly),
            K::Decision,
            None,
        ),
        (
            SessionError::Configuration(ConfigurationError::ChangedElsewhere),
            K::Configuration,
            None,
        ),
        (
            SessionError::Creation(CreationError::Unavailable("x".into())),
            K::Creation,
            None,
        ),
        (
            SessionError::Ledger(LedgerError::SendInFlight {
                session_id: "s".into(),
            }),
            K::Ledger,
            None,
        ),
        (SessionError::Draft(DraftError::UnknownItem), K::Draft, None),
        (
            SessionError::Upload(UploadError::BoundaryInBody),
            K::Upload,
            None,
        ),
        (
            SessionError::Sync(SyncError::BufferOverflow { limit: 1 }),
            K::Sync,
            None,
        ),
        (
            SessionError::BrowserAction(core::browser::BrowserActionError::ClaimRejected),
            K::BrowserAction,
            None,
        ),
        (
            SessionError::Preview(PreviewError::NotASessionFile),
            K::Preview,
            None,
        ),
    ];
    for (error, expected_kind, expected_detail) in cases {
        let shown = error.to_string();
        let sign_in = error.requires_sign_in();
        let CoreError::Session {
            kind,
            message,
            detail,
            requires_sign_in,
            ..
        } = CoreError::from(error)
        else {
            panic!("not a session error");
        };
        assert_eq!(kind, expected_kind);
        assert_eq!(message, shown);
        assert_eq!(detail.as_deref(), expected_detail, "{shown}");
        assert_eq!(requires_sign_in, sign_in);
    }

    let CoreError::Session {
        kind,
        detail,
        requires_sign_in,
        ..
    } = CoreError::from(SessionError::Transport(offline()))
    else {
        panic!("not a session error");
    };
    assert_eq!(kind, K::Transport);
    assert_eq!(detail, Some(offline().to_string()));
    assert!(!requires_sign_in);

    let CoreError::Session {
        kind,
        detail,
        requires_sign_in,
        ..
    } = CoreError::from(SessionError::Auth(HostedAuthError::Unauthorized {
        reason: Some("expired".into()),
    }))
    else {
        panic!("not a session error");
    };
    assert_eq!(kind, K::Auth);
    assert_eq!(detail.as_deref(), Some("expired"));
    assert!(requires_sign_in);
}

#[test]
fn an_unclear_creation_or_upload_is_flagged_as_uncertain() {
    let flag = |error: SessionError| {
        let CoreError::Session {
            delivery_uncertain, ..
        } = CoreError::from(error)
        else {
            panic!("not a session error");
        };
        delivery_uncertain
    };
    assert!(flag(SessionError::Creation(CreationError::Uncertain)));
    assert!(!flag(SessionError::Creation(CreationError::Unavailable(
        "x".into()
    ))));
    assert!(!flag(SessionError::Forbidden));
}

#[test]
fn every_absorbed_core_error_keeps_its_variant() {
    assert_eq!(
        CoreError::from(core::CoreError::InvalidUrl {
            message: "bad".into()
        }),
        CoreError::InvalidUrl {
            message: "bad".into()
        }
    );
    assert!(matches!(
        CoreError::from(core::CoreError::Transport(TransportError::Cancelled)),
        CoreError::Transport {
            kind: TransportErrorKind::Cancelled,
            ..
        }
    ));
    let long = "é".repeat(1_500);
    let CoreError::HttpStatus { status, body } = CoreError::from(core::CoreError::HttpStatus {
        status: 503,
        body: long,
    }) else {
        panic!("not an HTTP error");
    };
    assert_eq!(status, 503);
    assert_eq!(body.chars().count(), 1_000, "cut on a character boundary");

    let decode = core::CoreError::Decode {
        message: "bad".into(),
    };
    let shown = decode.to_string();
    assert_eq!(
        CoreError::from(decode),
        CoreError::Decode { message: shown }
    );
    assert!(matches!(
        core_error(HostedAuthError::Forbidden),
        CoreError::Auth {
            kind: AuthErrorKind::Forbidden,
            ..
        }
    ));
    assert!(matches!(
        core_error(OidcError::Cancelled),
        CoreError::Oidc {
            kind: OidcErrorKind::Cancelled,
            ..
        }
    ));
    assert!(matches!(
        core_error(LinkError::EndOfStream),
        CoreError::Link {
            kind: LinkErrorKind::EndOfStream,
            ..
        }
    ));
    let watch = WatchError::LimitExceeded {
        requested: 2,
        limit: 1,
    };
    assert_eq!(
        core_error(watch.clone()),
        CoreError::Watch {
            message: watch.to_string()
        }
    );
    let sync = SyncError::BufferOverflow { limit: 3 };
    assert_eq!(
        core_error(sync.clone()),
        CoreError::Sync {
            message: sync.to_string()
        }
    );
    let read = ConfigurationReadError::ChangedElsewhere;
    assert_eq!(
        core_error(read.clone()),
        CoreError::ConfigurationRead {
            message: read.to_string()
        }
    );
    let row = RowOpError::OutOfBounds { index: 2, len: 1 };
    assert_eq!(
        core_error(row.clone()),
        CoreError::RowOps {
            message: row.to_string()
        }
    );
    let settings = SettingsError::ImportNotAnObject;
    let settings_text = settings.to_string();
    assert_eq!(
        core_error(settings),
        CoreError::Settings {
            message: settings_text
        }
    );
    let managed = ManagedConfigError::TooManyServers {
        domain: Some("ai.omnigent.mac".into()),
        count: 99,
    };
    let managed_text = managed.to_string();
    let ios_code = managed.ios_code();
    assert_eq!(
        core_error(managed),
        CoreError::ManagedConfig {
            message: managed_text,
            ios_code,
            domain: Some("ai.omnigent.mac".into()),
        }
    );
    let deep = DeepLinkError::UnsupportedScheme;
    let deep_text = deep.to_string();
    assert_eq!(core_error(deep), CoreError::DeepLink { message: deep_text });
    let notification = NotificationError::MissingPayload;
    let notification_text = notification.to_string();
    assert_eq!(
        core_error(notification),
        CoreError::Notification {
            message: notification_text
        }
    );
}

#[test]
fn store_attachment_and_entropy_errors_keep_their_text() {
    let unavailable = SecureStoreError::Unavailable {
        message: "locked".into(),
    };
    let text = unavailable.to_string();
    assert_eq!(
        CoreError::from(unavailable),
        CoreError::SecureStore {
            message: text,
            unavailable: true,
        }
    );
    let other = store_error();
    let text = other.to_string();
    assert_eq!(
        CoreError::from(other),
        CoreError::SecureStore {
            message: text,
            unavailable: false,
        }
    );
    let attachment = AttachmentError::TooLarge { limit: 5 };
    let text = attachment.to_string();
    assert_eq!(
        CoreError::from(attachment),
        CoreError::Attachment { message: text }
    );
    let entropy = EntropyError::Unavailable {
        message: "none".into(),
    };
    let text = entropy.to_string();
    assert_eq!(
        CoreError::from(entropy),
        CoreError::Entropy { message: text }
    );
}

#[test]
fn every_databricks_error_keeps_its_kind_and_sign_in_flag() {
    use DatabricksErrorKind as K;
    let cases = [
        (DatabricksError::InvalidClientId, K::InvalidClientId, false),
        (
            DatabricksError::InvalidRedirectUrl,
            K::InvalidRedirectUrl,
            false,
        ),
        (
            DatabricksError::InvalidWorkspace,
            K::InvalidWorkspace,
            false,
        ),
        (
            DatabricksError::RandomGenerationFailed(EntropyError::Unavailable {
                message: "x".into(),
            }),
            K::RandomGenerationFailed,
            false,
        ),
        (DatabricksError::InvalidCallback, K::InvalidCallback, false),
        (DatabricksError::InvalidIssuer, K::InvalidIssuer, false),
        (
            DatabricksError::InvalidDiscovery,
            K::InvalidDiscovery,
            false,
        ),
        (
            DatabricksError::AuthorizationDenied,
            K::AuthorizationDenied,
            false,
        ),
        (
            DatabricksError::AuthorizationFailed,
            K::AuthorizationFailed,
            false,
        ),
        (DatabricksError::LoginInProgress, K::LoginInProgress, false),
        (
            DatabricksError::BrowserUnavailable,
            K::BrowserUnavailable,
            false,
        ),
        (
            DatabricksError::AuthenticationFailed,
            K::AuthenticationFailed,
            false,
        ),
        (
            DatabricksError::NetworkUnavailable(offline()),
            K::NetworkUnavailable,
            false,
        ),
        (
            DatabricksError::TokenExchangeFailed { status: 500 },
            K::TokenExchangeFailed,
            false,
        ),
        (
            DatabricksError::InvalidRefreshGrant,
            K::InvalidRefreshGrant,
            true,
        ),
        (
            DatabricksError::InvalidTokenResponse,
            K::InvalidTokenResponse,
            false,
        ),
        (DatabricksError::Storage(store_error()), K::Storage, false),
        (
            DatabricksError::InvalidCredentialData,
            K::InvalidCredentialData,
            true,
        ),
        (
            DatabricksError::CredentialsChanged,
            K::CredentialsChanged,
            true,
        ),
        (
            DatabricksError::InvalidSessionResponse,
            K::InvalidSessionResponse,
            false,
        ),
        (DatabricksError::UnsafeRedirect, K::UnsafeRedirect, false),
        (
            DatabricksError::WorkspaceChanged,
            K::WorkspaceChanged,
            false,
        ),
        (DatabricksError::UnsafeCookie, K::UnsafeCookie, false),
        (DatabricksError::MissingCookie, K::MissingCookie, false),
        (
            DatabricksError::UnexpectedLanding,
            K::UnexpectedLanding,
            false,
        ),
        (
            DatabricksError::Rejected { status: 403 },
            K::Rejected,
            false,
        ),
        (
            DatabricksError::PresentationUnavailable,
            K::PresentationUnavailable,
            false,
        ),
        (
            DatabricksError::WorkspaceRequired,
            K::WorkspaceRequired,
            false,
        ),
        (
            DatabricksError::ReauthenticationRequired,
            K::ReauthenticationRequired,
            true,
        ),
        (
            DatabricksError::RecoveryExhausted,
            K::RecoveryExhausted,
            false,
        ),
        (
            DatabricksError::SignOutIncomplete {
                cause: Box::new(DatabricksError::Cancelled),
            },
            K::SignOutIncomplete,
            false,
        ),
    ];
    for (error, kind, requires_sign_in) in cases {
        let message = error.user_message().unwrap();
        assert_eq!(
            CoreError::from(error),
            CoreError::Databricks {
                kind,
                message,
                requires_sign_in,
            }
        );
    }
    assert_eq!(
        CoreError::from(DatabricksError::Cancelled),
        CoreError::Databricks {
            kind: K::Cancelled,
            message: String::new(),
            requires_sign_in: false,
        },
        "a cancellation shows no message"
    );
}

#[test]
fn the_sign_in_flag_reads_every_variant_that_carries_it() {
    let message = String::new;
    assert!(CoreError::from(SessionError::NotConnected).requires_sign_in());
    assert!(!CoreError::from(SessionError::Busy).requires_sign_in());
    assert!(CoreError::from(LinkError::HttpStatus { status: 403 }).requires_sign_in());
    assert!(
        CoreError::Workspace {
            kind: WorkspaceErrorKind::NotConnected,
            message: message(),
            requires_sign_in: true,
        }
        .requires_sign_in()
    );
    assert!(
        CoreError::Terminal {
            kind: TerminalErrorKind::NotConnected,
            message: message(),
            requires_sign_in: true,
        }
        .requires_sign_in()
    );
    assert!(
        CoreError::RemoteBrowser {
            kind: RemoteBrowserErrorKind::InvalidIdentifier,
            message: message(),
            requires_sign_in: true,
        }
        .requires_sign_in()
    );
    assert!(CoreError::from(DatabricksError::CredentialsChanged).requires_sign_in());
    assert!(!CoreError::from(DatabricksError::UnsafeCookie).requires_sign_in());
    assert!(CoreError::from(HostedAuthError::CredentialExpired).requires_sign_in());
    assert!(CoreError::from(HostedAuthError::NotConnected).requires_sign_in());
    assert!(!CoreError::from(HostedAuthError::Forbidden).requires_sign_in());
    assert!(CoreError::from(OidcError::NoStoredGrant { host: "h".into() }).requires_sign_in());
    assert!(CoreError::from(OidcError::GrantExpired { host: "h".into() }).requires_sign_in());
    assert!(!CoreError::from(OidcError::Cancelled).requires_sign_in());
    assert!(!CoreError::invalid_state("x").requires_sign_in());
}
