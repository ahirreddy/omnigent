//! The listener callback and the granular events the core reports through it.

use omnigent_core as core;

use crate::decisions::DecisionCard;
use crate::errors::CoreError;
use crate::sessions::SessionListChange;
use crate::transcript::{EventSection, Row, SessionHeader, TranscriptChange};

/// Receives every [`CoreEvent`], in order, on a background thread. Implementations must return
/// quickly and hop to their own executor (the main actor on Apple) to apply the event, keeping
/// the order.
#[uniffi::export(with_foreign)]
pub trait CoreListener: Send + Sync {
    /// One event.
    fn on_event(&self, event: CoreEvent);
}

/// The state of one realtime connection (a session stream or the session-updates socket).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LinkState {
    /// Never started.
    Idle,
    /// The first attempt is in flight.
    Connecting,
    /// The server proved the connection live.
    Live,
    /// The connection was lost and another attempt is pending.
    Reconnecting {
        /// Why the last attempt ended.
        reason: CoreError,
        /// Consecutive failed attempts.
        failures: u32,
        /// The wait before the next attempt, in ms.
        delay_ms: u64,
    },
    /// The server closed the stream on purpose; it reopens on foreground.
    Closed,
    /// Stopped by the app.
    Stopped,
    /// A failure retrying cannot fix.
    Failed {
        /// The failure.
        error: CoreError,
    },
}

/// How the app may sign in to a server.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SignInMethod {
    /// Username and password (accounts mode).
    Password,
    /// Native OIDC through the system sign-in sheet, redirecting to the app's registered
    /// `redirect_uri`.
    Browser {
        /// The redirect the server lists for this app.
        redirect_uri: String,
    },
    /// Native OIDC with an RFC 8252 loopback redirect (macOS): the host starts a listener on an
    /// ephemeral `127.0.0.1` port and passes `http://127.0.0.1:<port><path>` to
    /// `begin_oidc_sign_in`.
    LoopbackBrowser {
        /// The callback path.
        path: String,
    },
    /// The OIDC browser-ticket fallback: open a page, the core polls until it is approved.
    BrowserTicket,
    /// Databricks workspace OAuth: present the authorize URL from
    /// `begin_databricks_sign_in` in the sign-in sheet, intercepting the HTTPS callback at
    /// `callback_host` and `callback_path`.
    DatabricksWorkspace {
        /// The HTTPS callback host the sheet intercepts.
        callback_host: String,
        /// The HTTPS callback path the sheet intercepts.
        callback_path: String,
    },
}

/// A Databricks workspace sign-in the host must present.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DatabricksChallenge {
    /// Identifies the attempt in `complete_databricks_sign_in`.
    pub attempt_id: u64,
    /// The workspace's `/oidc/v1/authorize` URL to open.
    pub authorize_url: String,
    /// The HTTPS callback host the sheet intercepts.
    pub callback_host: String,
    /// The HTTPS callback path the sheet intercepts.
    pub callback_path: String,
}

/// One changed file of a session environment, as the changed-files section lists it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ChangedFileSummary {
    /// Workspace-relative path.
    pub path: String,
    /// `modified`, `added`, `deleted`, ...
    pub status: String,
}

/// The changed files of a session environment, or why they are unavailable.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ChangedFilesUpdate {
    /// The environment's changes.
    Loaded {
        /// The files.
        files: Vec<ChangedFileSummary>,
    },
    /// The read failed.
    Unavailable {
        /// Why, for display.
        message: String,
    },
}

impl From<core::events::ChangedFilesUpdate> for ChangedFilesUpdate {
    fn from(update: core::events::ChangedFilesUpdate) -> Self {
        match update {
            core::events::ChangedFilesUpdate::Loaded(files) => Self::Loaded {
                files: files
                    .into_iter()
                    .map(|file| ChangedFileSummary {
                        path: file.path,
                        status: file.status,
                    })
                    .collect(),
            },
            core::events::ChangedFilesUpdate::Unavailable(message) => Self::Unavailable { message },
        }
    }
}

/// What a server needs before it can be used.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AuthenticationMode {
    /// The single-user local runtime on a loopback root, as the server reports it: no sign-in.
    /// A loopback server in accounts or OIDC mode reports that mode instead.
    LocalSingleUser,
    /// Built-in accounts.
    Accounts,
    /// OIDC.
    Oidc,
    /// Identity from a trusted proxy; not supported natively yet.
    Proxy,
    /// A mode this client does not know.
    Unsupported {
        /// The mode as sent.
        mode: String,
    },
}

/// A browser-ticket sign-in waiting for approval.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BrowserLoginInfo {
    /// The page the user opens to approve the sign-in.
    pub login_url: String,
    /// The code the page shows, when the server sent one.
    pub user_code: Option<String>,
    /// When the ticket expires, in ms since the Unix epoch.
    pub expires_at_ms: u64,
}

/// A native OIDC sign-in the host must present.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OidcChallenge {
    /// Identifies the attempt in [`crate::client::ClientCore::complete_oidc_sign_in`].
    pub attempt_id: u64,
    /// The page to open in the sign-in sheet.
    pub authorize_url: String,
    /// The callback scheme to hand `ASWebAuthenticationSession` (`http` for loopback).
    pub callback_scheme: String,
    /// The redirect URI the callback arrives at.
    pub redirect_uri: String,
}

/// The server the core is connected to.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConnectedServer {
    /// The canonical API root.
    pub base_url: String,
    /// Operator display name, from the manifest.
    pub server_name: Option<String>,
    /// The confirmed user id (`local` on a single-user server).
    pub user_id: String,
    /// The per-account scope key (server plus user).
    pub account_id: String,
    /// How the server authenticates.
    pub mode: AuthenticationMode,
}

/// Where the connection to a server stands.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionPhase {
    /// Not connected.
    Disconnected,
    /// Reading the manifest and `/v1/info`.
    Discovering {
        /// The server as typed.
        server_url: String,
    },
    /// The server needs a sign-in the core cannot complete on its own.
    SignInRequired {
        /// The canonical API root.
        base_url: String,
        /// The server's display name.
        server_name: Option<String>,
        /// How it authenticates.
        mode: AuthenticationMode,
        /// What the app can offer, best first. Empty when none works natively.
        methods: Vec<SignInMethod>,
        /// Why a saved sign-in no longer works, when that is the reason.
        reason: Option<CoreError>,
    },
    /// A sign-in is in progress.
    SigningIn {
        /// The canonical API root.
        base_url: String,
    },
    /// A browser-ticket sign-in waits for approval.
    AwaitingBrowserLogin {
        /// The canonical API root.
        base_url: String,
        /// The page and code to show.
        login: BrowserLoginInfo,
    },
    /// Confirming identity with the credential.
    Connecting {
        /// The canonical API root.
        base_url: String,
    },
    /// Connected; sessions load and stream.
    Connected {
        /// What the connect confirmed.
        server: ConnectedServer,
    },
    /// Connecting failed.
    Failed {
        /// The server as typed.
        server_url: String,
        /// Why.
        error: CoreError,
    },
}

/// What happened, for a user notification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NotificationKind {
    /// A decision was requested.
    Approval,
    /// A turn finished.
    Completed,
    /// A turn failed.
    Failed,
}

/// A notification to show now.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AttentionNotification {
    /// The session to open on tap.
    pub session_id: String,
    /// What happened.
    pub kind: NotificationKind,
    /// The session title, when known.
    pub title: Option<String>,
    /// The default body text.
    pub body: String,
}

/// Where an error came from.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ErrorScope {
    /// The connection or sign-in.
    Connection,
    /// The session list or the session-updates socket.
    SessionList,
    /// One session.
    Session {
        /// The session.
        session_id: String,
    },
    /// Notifications.
    Notifications,
}

/// A change the app should apply. Events arrive in order.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreEvent {
    /// The connection or sign-in moved on.
    ConnectionChanged {
        /// The new phase.
        phase: ConnectionPhase,
    },
    /// The session-updates socket changed state.
    UpdatesLinkChanged {
        /// The new state.
        state: LinkState,
    },
    /// The session list changed.
    SessionListChanged {
        /// How.
        change: SessionListChange,
    },
    /// The session list finished loading (or reloading).
    SessionListLoaded,
    /// An open session's stream changed state.
    SessionLinkChanged {
        /// The session.
        session_id: String,
        /// The new state.
        state: LinkState,
    },
    /// An open session finished loading its history; sends are possible from now on.
    SessionHydrated {
        /// The session.
        session_id: String,
    },
    /// An opened session's whole published state. Replace what the store holds; later
    /// `TranscriptChanged` events apply on top of it.
    TranscriptReset {
        /// The session.
        session_id: String,
        /// The revision of this state.
        revision: u64,
        /// Every row, in order.
        rows: Vec<Row>,
        /// The header, once known.
        header: Option<SessionHeader>,
        /// The sections.
        sections: Vec<EventSection>,
        /// Every decision card.
        decisions: Vec<DecisionCard>,
    },
    /// An open session's transcript changed.
    TranscriptChanged {
        /// The session.
        session_id: String,
        /// Increases with every change.
        revision: u64,
        /// The change.
        change: TranscriptChange,
    },
    /// An open session's decision cards changed.
    DecisionsChanged {
        /// The session.
        session_id: String,
        /// Every card, pending or locally answered.
        decisions: Vec<DecisionCard>,
    },
    /// A turn failed with a readable message.
    SessionFailure {
        /// The session.
        session_id: String,
        /// The message.
        message: String,
    },
    /// An open session was closed because it was removed or access was lost.
    SessionClosed {
        /// The session.
        session_id: String,
    },
    /// The conversation continues in another session.
    SessionSuperseded {
        /// The old session.
        session_id: String,
        /// The new session.
        target_session_id: String,
    },
    /// A notification to show.
    Notification {
        /// The notification.
        notification: AttentionNotification,
    },
    /// The sessions counting toward the app badge.
    BadgeChanged {
        /// Their ids.
        session_ids: Vec<String>,
    },
    /// A session's changed files were re-read after the server invalidated them
    /// (`session.changed_files.invalidated`). Workspace views showing changes should reload.
    ChangedFiles {
        /// The session.
        session_id: String,
        /// The environment, for example `default`.
        environment_id: String,
        /// The files, or why they are unavailable.
        update: ChangedFilesUpdate,
    },
    /// The connection's bearer was renewed in place; streams and the session list were not
    /// interrupted.
    CredentialRotated {
        /// When the new credential expires, in ms since the Unix epoch, when known.
        expires_at_ms: Option<u64>,
    },
    /// An open session's terminals changed (a list read, `session.resource.*`,
    /// `session.terminal.activity`, or the runner's `terminal_pending`), or an activity badge
    /// lapsed.
    TerminalsChanged {
        /// The session.
        session_id: String,
        /// Every terminal with its badge, oldest first.
        terminals: Vec<crate::terminal::TerminalRow>,
        /// What the session's Terminal view can show.
        harness: crate::terminal::HarnessTerminal,
    },
    /// The server asked a desktop client to perform an agent browser action (once per action
    /// id). Claim it with `claim_browser_action` before running it; post the result with
    /// `post_browser_action_result`.
    BrowserActionRequested {
        /// The session whose stream delivered it; claim and post to this session.
        session_id: String,
        /// The server's correlation id.
        action_id: String,
        /// The `browser_` tool name without the prefix, for example `navigate`.
        action: String,
        /// The tool arguments, a JSON object.
        args_json: String,
    },
    /// The server's host inventory changed.
    HostsChanged,
    /// The server's project list changed.
    ProjectsChanged,
    /// The session-updates socket sent a frame type this client does not know. Its payload is
    /// not forwarded.
    UnknownUpdate {
        /// The frame type.
        frame_type: String,
    },
    /// A failure with no caller to throw to. Never dropped.
    Error {
        /// Where it happened.
        scope: ErrorScope,
        /// The failure.
        error: CoreError,
    },
}

impl From<core::realtime::ConnectionState> for LinkState {
    fn from(state: core::realtime::ConnectionState) -> Self {
        use core::realtime::ConnectionState as S;
        match state {
            S::Idle => Self::Idle,
            S::Connecting => Self::Connecting,
            S::Live => Self::Live,
            S::Reconnecting {
                reason,
                failures,
                delay_ms,
            } => Self::Reconnecting {
                reason: reason.into(),
                failures,
                delay_ms,
            },
            S::Closed => Self::Closed,
            S::Stopped => Self::Stopped,
            S::Failed { error } => Self::Failed {
                error: error.into(),
            },
        }
    }
}

impl From<core::auth::mode::AuthenticationMode> for AuthenticationMode {
    fn from(mode: core::auth::mode::AuthenticationMode) -> Self {
        use core::auth::mode::AuthenticationMode as M;
        match mode {
            M::LocalSingleUser => Self::LocalSingleUser,
            M::Accounts => Self::Accounts,
            M::Oidc => Self::Oidc,
            M::Proxy => Self::Proxy,
            M::Unsupported { mode } => Self::Unsupported { mode },
        }
    }
}

impl From<core::notifications::route::NotificationKind> for NotificationKind {
    fn from(kind: core::notifications::route::NotificationKind) -> Self {
        use core::notifications::route::NotificationKind as K;
        match kind {
            K::Approval => Self::Approval,
            K::Completed => Self::Completed,
            K::Failed => Self::Failed,
        }
    }
}

impl From<core::notifications::attention::AttentionNotification> for AttentionNotification {
    fn from(notification: core::notifications::attention::AttentionNotification) -> Self {
        Self {
            body: notification.default_body().to_owned(),
            session_id: notification.session_id,
            kind: notification.kind.into(),
            title: notification.title,
        }
    }
}
