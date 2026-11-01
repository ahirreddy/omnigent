//! Workspace bootstrap, recovery and sign-out policy.
//!
//! Port of `web/ios/Omnigent/DatabricksWorkspaceBootstrap.swift` (`DatabricksWorkspaceBootstrap`,
//! `DatabricksRecoveryPolicy`, `DatabricksSignOutManager`) and the coordinator's HTTP status
//! handling in `OmnigentWebView.swift`.
//!
//! [`WorkspaceBootstrap`] decides each step of turning a saved (or new) grant into a cookie
//! session for one web context; the host performs the steps: token lookups through the
//! [`super::TokenManager`], interactive sign-in through the [`super::login::LoginManager`],
//! session creation (`auth/session/create`), and the serialized cookie-store mutations.
//!
//! The rules it enforces:
//!
//! - A store for another context never receives this workspace's cookies.
//! - An unfinished sign-out is completed before any credential is used or any login starts.
//! - Storage and session errors never fall back to opening the browser; silent recovery never
//!   opens it either ([`DatabricksError::ReauthenticationRequired`] instead).
//! - Before an interactive login, the selected web store (and only it) is reset, so a failed
//!   bootstrap cannot leave the previous account's data behind.
//! - A cached token rejected with HTTP 401 is refreshed once and session creation retried once;
//!   nothing else retries.
//! - Every result is checked against cancellation, a pending or completed sign-out, and whether
//!   the credential is still the saved one, so a late result never installs cookies.

use std::collections::{BTreeMap, BTreeSet};

use url::Url;

use super::config::OAuthConfiguration;
use super::error::DatabricksError;
use super::scope::CredentialScope;
use super::token_manager::CredentialFault;
use super::tokens::DatabricksTokens;
use super::web_context::{SessionCookie, StoreIdentifier, WebContext, WorkspaceSession};

/// Why a bootstrap runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionIntent {
    /// A user-initiated connection: an interactive sign-in is allowed.
    Connect,
    /// Silent recovery: never present the browser.
    Recover,
}

/// The next thing the host must do for a bootstrap.
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(
    clippy::large_enum_variant,
    reason = "one step per bootstrap phase, moved straight to the host; boxing buys nothing"
)]
pub enum BootstrapStep {
    /// Finish this store's pending sign-out (see [`SignOutTracker`]) and report it with
    /// [`WorkspaceBootstrap::sign_out_finished`].
    FinishPendingSignOut,
    /// Look up the saved grant (cached mode) and report it with
    /// [`WorkspaceBootstrap::tokens_loaded`].
    LoadTokens {
        /// The scope to look up.
        scope: CredentialScope,
    },
    /// Reset (clear) the selected web store, calling [`WorkspaceBootstrap::check_active`]
    /// immediately before mutating it, and report with [`WorkspaceBootstrap::web_store_reset`].
    ResetWebStore,
    /// Present interactive sign-in and report with [`WorkspaceBootstrap::signed_in`].
    SignIn {
        /// The page the user selected; its `o=` stays in the sign-in.
        workspace_url: Url,
        /// The client configuration.
        configuration: OAuthConfiguration,
    },
    /// Create a cookie session and report with [`WorkspaceBootstrap::session_created`].
    CreateSession {
        /// The destination context (the recovery page when one was given).
        context: WebContext,
        /// The bearer to use.
        tokens: DatabricksTokens,
    },
    /// Refresh this server-rejected token once (rejected mode) and report with
    /// [`WorkspaceBootstrap::refreshed`].
    RefreshRejected {
        /// The scope.
        scope: CredentialScope,
        /// The rejected bundle.
        tokens: DatabricksTokens,
    },
    /// Read the saved record, ask [`super::TokenManager::is_current`] about `tokens`, and report
    /// with [`WorkspaceBootstrap::credential_checked`].
    CheckCredential {
        /// The scope.
        scope: CredentialScope,
        /// The bundle the session was created with.
        tokens: DatabricksTokens,
    },
    /// Install `cookies` (replacing same-named and `DBAUTH` cookies, without a reset), calling
    /// [`WorkspaceBootstrap::install_allowed`] immediately before mutating the store; then report
    /// the store's cookies with [`WorkspaceBootstrap::cookies_installed`].
    InstallCookies {
        /// The cookie updates.
        cookies: Vec<SessionCookie>,
        /// The bundle the session was created with (for the pre-mutation check).
        tokens: DatabricksTokens,
    },
    /// Done: load the session's page.
    Ready(WorkspaceSession),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    PendingSignOut,
    LoadingTokens,
    ResettingStore,
    SigningIn,
    CreatingSession,
    Refreshing,
    CheckingBeforeInstall,
    Installing,
    CheckingAfterInstall,
    Done,
}

/// One bootstrap of one web context into its store.
#[derive(Debug, Clone)]
pub struct WorkspaceBootstrap {
    context: WebContext,
    destination: WebContext,
    intent: ConnectionIntent,
    store: StoreIdentifier,
    generation: Option<u64>,
    phase: Phase,
    had_saved_grant: bool,
    refreshed_once: bool,
    credential: Option<DatabricksTokens>,
    session: Option<WorkspaceSession>,
    cancelled: bool,
}

impl WorkspaceBootstrap {
    /// Starts a bootstrap of `context` into the store `store`, landing on `page_url` (a recovery
    /// page) when given.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::WorkspaceChanged`] when `store` belongs to another context or
    /// `page_url` is in another workspace; see [`WebContext::navigating`].
    pub fn start(
        context: &WebContext,
        store: StoreIdentifier,
        intent: ConnectionIntent,
        page_url: Option<&Url>,
        sign_outs: &SignOutTracker,
    ) -> Result<(Self, BootstrapStep), DatabricksError> {
        if store != context.store_identifier() {
            return Err(DatabricksError::WorkspaceChanged);
        }
        let destination = match page_url {
            Some(url) => context.navigating(url)?,
            None => context.clone(),
        };
        let mut flow = Self {
            context: context.clone(),
            destination,
            intent,
            store,
            generation: None,
            phase: Phase::PendingSignOut,
            had_saved_grant: false,
            refreshed_once: false,
            credential: None,
            session: None,
            cancelled: false,
        };
        let step = if sign_outs.is_pending(store) {
            BootstrapStep::FinishPendingSignOut
        } else {
            flow.load_tokens(sign_outs)
        };
        Ok((flow, step))
    }

    /// Cancels the bootstrap; every later result is discarded with
    /// [`DatabricksError::Cancelled`].
    pub const fn cancel(&mut self) {
        self.cancelled = true;
    }

    fn expect(&self, phase: Phase) -> Result<(), DatabricksError> {
        if self.cancelled || self.phase != phase {
            Err(DatabricksError::Cancelled)
        } else {
            Ok(())
        }
    }

    /// Fails unless the bootstrap may still mutate state: not cancelled, and no sign-out began
    /// or finished for this store since the bootstrap captured its lifecycle generation.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::Cancelled`] or [`DatabricksError::CredentialsChanged`].
    pub fn check_active(&self, sign_outs: &SignOutTracker) -> Result<(), DatabricksError> {
        if self.cancelled {
            return Err(DatabricksError::Cancelled);
        }
        if sign_outs.is_pending(self.store) || sign_outs.generation(self.store) != self.generation {
            return Err(DatabricksError::CredentialsChanged);
        }
        Ok(())
    }

    /// The check to run immediately before installing cookies: active, and the credential is
    /// still the saved one (`current`, from [`super::TokenManager::is_current`]).
    ///
    /// # Errors
    ///
    /// See [`WorkspaceBootstrap::check_active`]; [`DatabricksError::CredentialsChanged`] when the
    /// credential is no longer current; or the store error behind `current`.
    pub fn install_allowed(
        &self,
        sign_outs: &SignOutTracker,
        current: Result<bool, DatabricksError>,
    ) -> Result<(), DatabricksError> {
        self.check_active(sign_outs)?;
        if current? {
            Ok(())
        } else {
            Err(DatabricksError::CredentialsChanged)
        }
    }

    fn load_tokens(&mut self, sign_outs: &SignOutTracker) -> BootstrapStep {
        self.generation = sign_outs.generation(self.store);
        self.phase = Phase::LoadingTokens;
        BootstrapStep::LoadTokens {
            scope: self.context.scope().clone(),
        }
    }

    /// The pending sign-out finished.
    ///
    /// # Errors
    ///
    /// The cleanup's error ([`DatabricksError::SignOutIncomplete`]): no credential is used and no
    /// login starts until it succeeds.
    pub fn sign_out_finished(
        &mut self,
        sign_outs: &SignOutTracker,
        result: Result<(), DatabricksError>,
    ) -> Result<BootstrapStep, DatabricksError> {
        self.expect(Phase::PendingSignOut)?;
        result?;
        Ok(self.load_tokens(sign_outs))
    }

    /// The token lookup finished.
    ///
    /// # Errors
    ///
    /// The lookup's error (storage errors never fall back to the browser);
    /// [`DatabricksError::ReauthenticationRequired`] when silent recovery finds no grant; or see
    /// [`WorkspaceBootstrap::check_active`].
    pub fn tokens_loaded(
        &mut self,
        sign_outs: &SignOutTracker,
        result: Result<Option<DatabricksTokens>, DatabricksError>,
    ) -> Result<BootstrapStep, DatabricksError> {
        self.expect(Phase::LoadingTokens)?;
        let saved = result?;
        self.check_active(sign_outs)?;
        match saved {
            Some(tokens) => {
                self.had_saved_grant = true;
                Ok(self.create_session(tokens))
            }
            None if self.intent == ConnectionIntent::Recover => {
                Err(DatabricksError::ReauthenticationRequired)
            }
            None => {
                self.phase = Phase::ResettingStore;
                Ok(BootstrapStep::ResetWebStore)
            }
        }
    }

    /// The web store was reset.
    ///
    /// # Errors
    ///
    /// The reset's error, or see [`WorkspaceBootstrap::check_active`].
    pub fn web_store_reset(
        &mut self,
        sign_outs: &SignOutTracker,
        result: Result<(), DatabricksError>,
    ) -> Result<BootstrapStep, DatabricksError> {
        self.expect(Phase::ResettingStore)?;
        result?;
        self.check_active(sign_outs)?;
        self.phase = Phase::SigningIn;
        Ok(BootstrapStep::SignIn {
            workspace_url: self.context.page_url().clone(),
            configuration: self.context.configuration().clone(),
        })
    }

    /// The interactive sign-in finished (and persisted its tokens).
    ///
    /// # Errors
    ///
    /// The sign-in's error, or see [`WorkspaceBootstrap::check_active`].
    pub fn signed_in(
        &mut self,
        sign_outs: &SignOutTracker,
        result: Result<DatabricksTokens, DatabricksError>,
    ) -> Result<BootstrapStep, DatabricksError> {
        self.expect(Phase::SigningIn)?;
        let tokens = result?;
        self.check_active(sign_outs)?;
        Ok(self.create_session(tokens))
    }

    fn create_session(&mut self, tokens: DatabricksTokens) -> BootstrapStep {
        self.credential = Some(tokens.clone());
        self.phase = Phase::CreatingSession;
        BootstrapStep::CreateSession {
            context: self.destination.clone(),
            tokens,
        }
    }

    fn credential(&self) -> Result<DatabricksTokens, DatabricksError> {
        self.credential.clone().ok_or(DatabricksError::Cancelled)
    }

    /// Session creation finished.
    ///
    /// # Errors
    ///
    /// The session error (only a first HTTP 401 for a cached grant leads to a refresh instead),
    /// or see [`WorkspaceBootstrap::check_active`].
    pub fn session_created(
        &mut self,
        sign_outs: &SignOutTracker,
        result: Result<WorkspaceSession, DatabricksError>,
    ) -> Result<BootstrapStep, DatabricksError> {
        self.expect(Phase::CreatingSession)?;
        match result {
            Err(DatabricksError::Rejected { status: 401 })
                if self.had_saved_grant && !self.refreshed_once =>
            {
                self.check_active(sign_outs)?;
                self.refreshed_once = true;
                self.phase = Phase::Refreshing;
                Ok(BootstrapStep::RefreshRejected {
                    scope: self.context.scope().clone(),
                    tokens: self.credential()?,
                })
            }
            Err(error) => Err(error),
            Ok(session) => {
                self.check_active(sign_outs)?;
                self.session = Some(session);
                self.phase = Phase::CheckingBeforeInstall;
                self.check_credential()
            }
        }
    }

    fn check_credential(&self) -> Result<BootstrapStep, DatabricksError> {
        Ok(BootstrapStep::CheckCredential {
            scope: self.context.scope().clone(),
            tokens: self.credential()?,
        })
    }

    /// The forced refresh after a 401 finished.
    ///
    /// # Errors
    ///
    /// The refresh error; [`DatabricksError::ReauthenticationRequired`] when the grant is gone;
    /// or see [`WorkspaceBootstrap::check_active`].
    pub fn refreshed(
        &mut self,
        sign_outs: &SignOutTracker,
        result: Result<Option<DatabricksTokens>, DatabricksError>,
    ) -> Result<BootstrapStep, DatabricksError> {
        self.expect(Phase::Refreshing)?;
        let refreshed = result?.ok_or(DatabricksError::ReauthenticationRequired)?;
        self.check_active(sign_outs)?;
        Ok(self.create_session(refreshed))
    }

    /// The credential check finished (before or after installing cookies).
    ///
    /// # Errors
    ///
    /// The store error; [`DatabricksError::CredentialsChanged`] when the credential was cleared
    /// or replaced, or a sign-out began; or see [`WorkspaceBootstrap::check_active`].
    pub fn credential_checked(
        &mut self,
        sign_outs: &SignOutTracker,
        current: Result<bool, DatabricksError>,
    ) -> Result<BootstrapStep, DatabricksError> {
        let after_install = match self.phase {
            Phase::CheckingBeforeInstall if !self.cancelled => false,
            Phase::CheckingAfterInstall if !self.cancelled => true,
            _ => return Err(DatabricksError::Cancelled),
        };
        if sign_outs.is_pending(self.store) || !current? {
            return Err(DatabricksError::CredentialsChanged);
        }
        self.check_active(sign_outs)?;
        let session = self.session.clone().ok_or(DatabricksError::Cancelled)?;
        if after_install {
            self.phase = Phase::Done;
            Ok(BootstrapStep::Ready(session))
        } else {
            self.phase = Phase::Installing;
            Ok(BootstrapStep::InstallCookies {
                cookies: session.cookies,
                tokens: self.credential()?,
            })
        }
    }

    /// The cookies were installed; `installed` is what the store now holds.
    ///
    /// # Errors
    ///
    /// The installation's error; [`DatabricksError::MissingCookie`] unless the store holds a live
    /// `Secure`, `HttpOnly` session cookie this session issued for the page; or see
    /// [`WorkspaceBootstrap::check_active`].
    pub fn cookies_installed(
        &mut self,
        sign_outs: &SignOutTracker,
        installed: Result<Vec<SessionCookie>, DatabricksError>,
        now_ms: u64,
    ) -> Result<BootstrapStep, DatabricksError> {
        self.expect(Phase::Installing)?;
        let installed = installed?;
        self.check_active(sign_outs)?;
        let session = self.session.as_ref().ok_or(DatabricksError::Cancelled)?;
        if !session.has_installed_session_cookie(&installed, now_ms) {
            return Err(DatabricksError::MissingCookie);
        }
        self.phase = Phase::CheckingAfterInstall;
        self.check_credential()
    }
}

/// What a sign-out request needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignOutStart {
    /// Persist [`SignOutTracker::pending_markers`], clear `scope`'s tokens, reset the store, and
    /// report with [`SignOutTracker::finished`].
    Run {
        /// The credentials to clear.
        scope: CredentialScope,
    },
    /// This store's cleanup is already running; wait for it.
    AlreadyRunning,
}

/// Durable sign-out intent.
///
/// A non-secret pending marker per store is recorded before cleanup starts (the host persists [`SignOutTracker::pending_markers`]), so an interrupted or failed
/// sign-out is finished on the next connection before any credential is reused. A per-store
/// lifecycle generation makes every bootstrap that started before a sign-out stale, even after
/// the cleanup finished.
#[derive(Debug, Clone, Default)]
pub struct SignOutTracker {
    pending: BTreeSet<String>,
    running: BTreeSet<String>,
    generations: BTreeMap<String, u64>,
    next_generation: u64,
}

impl SignOutTracker {
    /// No sign-outs pending.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// A tracker with the markers the host persisted (e.g. after an app restart).
    #[must_use]
    pub fn restore(markers: impl IntoIterator<Item = String>) -> Self {
        Self {
            pending: markers.into_iter().collect(),
            ..Self::default()
        }
    }

    /// The markers to persist, sorted.
    #[must_use]
    pub fn pending_markers(&self) -> Vec<String> {
        self.pending.iter().cloned().collect()
    }

    /// Whether `store` has an unfinished sign-out.
    #[must_use]
    pub fn is_pending(&self, store: StoreIdentifier) -> bool {
        self.pending.contains(&store.to_string())
    }

    /// The store's lifecycle generation; it changes whenever a sign-out begins.
    #[must_use]
    pub fn generation(&self, store: StoreIdentifier) -> Option<u64> {
        self.generations.get(&store.to_string()).copied()
    }

    /// Begins (or joins) signing `context` out of `store`.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::WorkspaceChanged`] when `store` belongs to another context.
    pub fn begin(
        &mut self,
        context: &WebContext,
        store: StoreIdentifier,
    ) -> Result<SignOutStart, DatabricksError> {
        if store != context.store_identifier() {
            return Err(DatabricksError::WorkspaceChanged);
        }
        let key = store.to_string();
        if self.running.contains(&key) {
            return Ok(SignOutStart::AlreadyRunning);
        }
        self.pending.insert(key.clone());
        self.running.insert(key.clone());
        self.next_generation = self.next_generation.wrapping_add(1);
        self.generations.insert(key, self.next_generation);
        Ok(SignOutStart::Run {
            scope: context.scope().clone(),
        })
    }

    /// The cleanup for `store` finished.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::SignOutIncomplete`] carrying the cleanup's error when it failed; the
    /// marker stays so the cleanup is retried before the next sign-in. There is no fallback to
    /// the old credentials.
    pub fn finished(
        &mut self,
        store: StoreIdentifier,
        result: Result<(), DatabricksError>,
    ) -> Result<(), DatabricksError> {
        let key = store.to_string();
        self.running.remove(&key);
        result
            .map(|()| {
                self.pending.remove(&key);
            })
            .map_err(|cause| DatabricksError::SignOutIncomplete {
                cause: Box::new(cause),
            })
    }
}

/// Whether the saved default server URL belongs to `context` (same credential scope), so that
/// signing out of `context` must stop auto-opening it on launch. Other workspaces' defaults stay.
#[must_use]
pub fn stops_auto_opening(saved_server_url: &str, context: &WebContext) -> bool {
    Url::parse(saved_server_url)
        .ok()
        .and_then(|url| CredentialScope::new(&url, context.configuration()).ok())
        .is_some_and(|scope| &scope == context.scope())
}

/// Automatic recovery needs a healthy page since the last attempt and this cooldown.
pub const RECOVERY_COOLDOWN_MS: u64 = 60_000;

/// When an automatic (silent) recovery may run.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RecoveryPolicy {
    last_attempt_ms: Option<u64>,
    page_was_ready: bool,
}

impl RecoveryPolicy {
    /// No attempt yet.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// The page loaded and showed trusted app activity.
    pub const fn mark_ready(&mut self) {
        self.page_was_ready = true;
    }

    /// Whether a recovery may start at `now_ms`; records the attempt when it may.
    pub const fn begin(&mut self, now_ms: u64) -> bool {
        if let Some(last) = self.last_attempt_ms
            && (!self.page_was_ready || now_ms.saturating_sub(last) < RECOVERY_COOLDOWN_MS)
        {
            return false;
        }
        self.last_attempt_ms = Some(now_ms);
        self.page_was_ready = false;
        true
    }
}

/// What to do about a main-frame HTTP status on a workspace page.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkspaceStatusAction {
    /// 401: the session expired; start one silent recovery.
    Recover,
    /// 403: a permission error, not a reason to sign in again. Show it.
    Fail(DatabricksError),
}

/// The action for a main-frame response status, or `None` to let the page load.
#[must_use]
pub const fn workspace_http_status_action(status: u16) -> Option<WorkspaceStatusAction> {
    match status {
        401 => Some(WorkspaceStatusAction::Recover),
        403 => Some(WorkspaceStatusAction::Fail(DatabricksError::Rejected {
            status: 403,
        })),
        _ => None,
    }
}

/// A debug-menu fault for watching recovery against a real workspace.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DebugFault {
    /// Delete the session cookie: expect a silent repair.
    SessionCookie,
    /// Clear the access token: expect a silent refresh and no browser.
    AccessToken,
    /// Keep an unusable, unexpired access token: expect one rejection, one refresh and retry.
    RejectedAccessToken,
    /// Clear both tokens: expect a Sign In prompt instead of a silent retry.
    RefreshToken,
}

/// How to inject a [`DebugFault`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DebugFaultPlan {
    /// Delete the session cookie from the context's store, through the same serialized queue as
    /// cookie installation. Credentials are untouched.
    ClearSessionCookie,
    /// Load the saved bundle (none: report that nothing was injected), apply the fault with
    /// [`CredentialFault::apply`], and save it with [`super::TokenManager::save`].
    Credentials(CredentialFault),
}

impl DebugFault {
    /// The plan for this fault in `context`'s store `store`.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::WorkspaceChanged`] when `store` belongs to another context.
    pub fn plan(
        self,
        context: &WebContext,
        store: StoreIdentifier,
    ) -> Result<DebugFaultPlan, DatabricksError> {
        if store != context.store_identifier() {
            return Err(DatabricksError::WorkspaceChanged);
        }
        Ok(match self {
            Self::SessionCookie => DebugFaultPlan::ClearSessionCookie,
            Self::AccessToken => DebugFaultPlan::Credentials(CredentialFault::ClearedAccessToken),
            Self::RejectedAccessToken => {
                DebugFaultPlan::Credentials(CredentialFault::RejectedAccessToken)
            }
            Self::RefreshToken => DebugFaultPlan::Credentials(CredentialFault::ClearedRefreshToken),
        })
    }
}

#[cfg(test)]
mod tests;
