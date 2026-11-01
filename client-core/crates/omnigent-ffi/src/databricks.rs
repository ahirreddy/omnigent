//! Databricks workspace sign-in.
//!
//! The host side of `omnigent_core::auth::databricks`: the core's machines decide, and this
//! module performs their effects through the host traits:
//!
//! - [`LoginManager`] runs one interactive login at a time. The host presents the authorize URL
//!   and passes the callback to [`ClientCore::complete_databricks_sign_in`]; the code is
//!   exchanged ([`OAuthClient::exchange`]), the tokens are persisted, and the connection is
//!   established with the access token as its bearer.
//! - [`TokenManager`] owns the saved grant per credential scope: lookups load it from the secure
//!   store, refresh it single-flight in a task that outlives its caller (a rotated refresh token
//!   is always saved), and persist every change before any caller sees it.
//! - Before the access token expires it is refreshed and rotated into the live connection
//!   without a reconnect.

#![allow(
    clippy::significant_drop_tightening,
    reason = "each critical section applies one machine step and answers its waiters atomically"
)]

use std::collections::HashMap;
use std::fmt;
use std::sync::{Arc, Mutex};

use futures::channel::oneshot;
use omnigent_core::auth::SecureStore as _;
use omnigent_core::auth::databricks::login::{BrowserOutcome, LoginId};
use omnigent_core::auth::databricks::token_manager::{
    LookupMode, LookupStep, RefreshStep, RefreshTicket, StoreWrite, WaiterCompletion, WaiterId,
    refresh_due_in_ms,
};
use omnigent_core::auth::databricks::{
    CredentialScope, DatabricksError, DatabricksTokens, LoginManager, OAuthClient,
    OAuthConfiguration, TokenManager,
};
use url::Url;

use crate::client::{ClientCore, Inner};
use crate::connection::{DatabricksOAuthSettings, Resolved};
use crate::engine::{Msg, lock};
use crate::errors::{CoreError, DatabricksErrorKind};
use crate::events::{ConnectedServer, ConnectionPhase, CoreEvent, DatabricksChallenge, ErrorScope};

/// How long a failed background refresh waits before the next attempt.
const RENEWAL_RETRY_MS: u64 = 60_000;

type Answer = Result<Option<DatabricksTokens>, DatabricksError>;

/// The login and token machines, and the callers waiting for a shared refresh.
#[derive(Default)]
struct DatabricksState {
    tokens: TokenManager,
    login: LoginManager,
    attempts: HashMap<u64, LoginId>,
    next_attempt: u64,
    waiters: HashMap<WaiterId, oneshot::Sender<Answer>>,
}

/// The build's Databricks OAuth client and the per-core sign-in state.
pub(crate) struct DatabricksAuth {
    /// The validated client, or why the build settings are unusable (reported when a Databricks
    /// server is used, never hidden).
    configuration: Result<OAuthConfiguration, DatabricksError>,
    state: Mutex<DatabricksState>,
}

impl fmt::Debug for DatabricksAuth {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DatabricksAuth")
            .field("configured", &self.configuration.is_ok())
            .finish_non_exhaustive()
    }
}

/// The next effect of a token lookup.
enum Next {
    Write(StoreWrite),
    Load(omnigent_core::auth::databricks::token_manager::LoadTicket),
    Ready(Option<DatabricksTokens>),
    Refresh(RefreshTicket, oneshot::Receiver<Answer>),
    Wait(oneshot::Receiver<Answer>),
}

impl DatabricksState {
    /// Registers the caller of a refresh step in the same critical section that produced it, so
    /// its answer cannot arrive unheard.
    fn settle(&mut self, step: LookupStep) -> Next {
        match step {
            LookupStep::Write(write) => Next::Write(write),
            LookupStep::Load(ticket) => Next::Load(ticket),
            LookupStep::Ready(tokens) => Next::Ready(tokens),
            LookupStep::StartRefresh { refresh, waiter } => {
                let (sender, receiver) = oneshot::channel();
                self.waiters.insert(waiter, sender);
                Next::Refresh(refresh, receiver)
            }
            LookupStep::Wait { waiter } => {
                let (sender, receiver) = oneshot::channel();
                self.waiters.insert(waiter, sender);
                Next::Wait(receiver)
            }
        }
    }

    fn deliver(&mut self, completions: Vec<WaiterCompletion>) {
        for completion in completions {
            if let Some(sender) = self.waiters.remove(&completion.waiter) {
                // A dropped receiver is a caller that went away; the result is persisted anyway.
                if let Err(unheard) = sender.send(completion.result) {
                    drop(unheard);
                }
            }
        }
    }

    fn cancel_login(&mut self) {
        self.attempts.clear();
        let Self { login, tokens, .. } = self;
        login.cancel(tokens);
    }
}

impl DatabricksAuth {
    /// The sign-in state for the build's client `settings`.
    pub(crate) fn new(settings: &DatabricksOAuthSettings) -> Self {
        Self {
            configuration: OAuthConfiguration::new(&settings.client_id, &settings.redirect_url),
            state: Mutex::new(DatabricksState::default()),
        }
    }

    fn configuration(&self) -> Result<&OAuthConfiguration, CoreError> {
        self.configuration
            .as_ref()
            .map_err(|error| CoreError::from(error.clone()))
    }

    /// Abandons the interactive login, if any (a new connection generation began).
    pub(crate) fn reset_login(&self) {
        lock(&self.state).cancel_login();
    }
}

fn not_configured() -> CoreError {
    CoreError::Databricks {
        kind: DatabricksErrorKind::NotConfigured,
        message: "This build has no Databricks OAuth client, so it cannot sign in to a Databricks workspace.".to_owned(),
        requires_sign_in: false,
    }
}

fn not_databricks() -> CoreError {
    CoreError::invalid_state("Connect to a Databricks workspace server before signing in.")
}

impl Inner {
    fn databricks_auth(&self) -> Result<&DatabricksAuth, CoreError> {
        self.databricks.as_ref().ok_or_else(not_configured)
    }

    fn databricks_scope(&self, resolved: &Resolved) -> Result<CredentialScope, CoreError> {
        let workspace = resolved
            .databricks_workspace
            .as_ref()
            .ok_or_else(not_databricks)?;
        let configuration = self.databricks_auth()?.configuration()?;
        CredentialScope::new(workspace, configuration).map_err(CoreError::from)
    }

    async fn perform_write(
        &self,
        write: &StoreWrite,
    ) -> Result<(), omnigent_core::auth::SecureStoreError> {
        let store = self
            .store()
            .map_err(|error| omnigent_core::auth::SecureStoreError::Other {
                message: error.to_string(),
            })?;
        match &write.value {
            Some(bytes) => store.set(write.key.clone(), bytes.clone()).await,
            None => store.delete(write.key.clone()).await,
        }
    }

    /// Performs a store write the token manager issued and answers the waiters it settles.
    async fn persist(
        &self,
        auth: &DatabricksAuth,
        write: &StoreWrite,
    ) -> Result<(), DatabricksError> {
        let result = self.perform_write(write).await;
        let mut state = lock(&auth.state);
        let outcome = state.tokens.write_finished(write.id, result);
        state.deliver(outcome.completions);
        outcome.result
    }

    /// The usable saved tokens for `scope` (refreshed when due or `Rejected`), or `None` when
    /// there is no reusable grant.
    async fn databricks_tokens(
        self: &Arc<Self>,
        scope: &CredentialScope,
        mode: &LookupMode,
    ) -> Answer {
        let auth = self
            .databricks
            .as_ref()
            .ok_or(DatabricksError::InvalidClientId)?;
        let mut next = {
            let mut state = lock(&auth.state);
            let step = state.tokens.lookup(scope, mode.clone());
            state.settle(step)
        };
        loop {
            next = match next {
                Next::Write(write) => {
                    self.persist(auth, &write).await?;
                    let mut state = lock(&auth.state);
                    let step = state.tokens.lookup(scope, mode.clone());
                    state.settle(step)
                }
                Next::Load(ticket) => {
                    let loaded = match self.store() {
                        Ok(store) => store.get(ticket.key()).await,
                        Err(error) => Err(omnigent_core::auth::SecureStoreError::Other {
                            message: error.to_string(),
                        }),
                    };
                    let now = self.host.unix_ms();
                    let mut state = lock(&auth.state);
                    let step = state.tokens.loaded(ticket, loaded, now)?;
                    state.settle(step)
                }
                Next::Ready(tokens) => return Ok(tokens),
                Next::Refresh(refresh, answer) => {
                    let inner = Arc::clone(self);
                    self.host
                        .spawn(async move { inner.run_refresh(refresh).await });
                    return answer.await.unwrap_or(Err(DatabricksError::Cancelled));
                }
                Next::Wait(answer) => {
                    return answer.await.unwrap_or(Err(DatabricksError::Cancelled));
                }
            };
        }
    }

    /// Sends one refresh and persists its outcome. Runs on its own task so a cancelled caller
    /// cannot lose a rotated grant.
    async fn run_refresh(self: Arc<Self>, refresh: RefreshTicket) {
        let Some(auth) = self.databricks.as_ref() else {
            return;
        };
        let now = self.host.unix_ms();
        let result = OAuthClient::new(&self.transport)
            .refresh(
                &refresh.scope,
                &refresh.refresh_token,
                refresh.issuer.as_ref(),
                now,
            )
            .await;
        let step = lock(&auth.state)
            .tokens
            .refresh_finished(refresh.id, result);
        match step {
            RefreshStep::Persist(write) => {
                // The outcome reaches every waiter through the write's completions.
                if let Err(error) = self.persist(auth, &write).await {
                    self.post(Msg::Emit(CoreEvent::Error {
                        scope: ErrorScope::Connection,
                        error: error.into(),
                    }));
                }
            }
            RefreshStep::Completed(completions) => lock(&auth.state).deliver(completions),
            RefreshStep::Discarded => {}
        }
    }

    /// Connects with the saved grant for the workspace, refreshing it when due; otherwise asks
    /// for the Databricks sign-in.
    pub(crate) async fn connect_databricks(
        self: &Arc<Self>,
        generation: u64,
        resolved: &Resolved,
        expected_user_id: Option<String>,
    ) -> Result<ConnectionPhase, CoreError> {
        let base_url = resolved.endpoint.base_url().to_owned();
        let scope = match self.databricks_scope(resolved) {
            Ok(scope) => scope,
            Err(error) => return Err(self.fail(&base_url, error)),
        };
        let tokens = self.databricks_tokens(&scope, &LookupMode::Cached).await;
        self.check_generation(generation)?;
        match tokens {
            Ok(Some(tokens)) => {
                let server = self
                    .establish(
                        generation,
                        resolved,
                        Some(tokens.access_token.clone()),
                        expected_user_id,
                    )
                    .await?;
                self.schedule_databricks_renewal(generation, resolved, &scope, &tokens);
                Ok(ConnectionPhase::Connected { server })
            }
            Ok(None) => Ok(self.sign_in_required(resolved, None)),
            Err(error) => Ok(self.sign_in_required(resolved, Some(error.into()))),
        }
    }

    fn schedule_databricks_renewal(
        self: &Arc<Self>,
        generation: u64,
        resolved: &Resolved,
        scope: &CredentialScope,
        tokens: &DatabricksTokens,
    ) {
        let delay = refresh_due_in_ms(tokens, self.host.unix_ms());
        self.schedule_databricks_retry(generation, resolved, scope, delay);
    }

    fn schedule_databricks_retry(
        self: &Arc<Self>,
        generation: u64,
        resolved: &Resolved,
        scope: &CredentialScope,
        delay_ms: u64,
    ) {
        let inner = Arc::clone(self);
        let resolved = resolved.clone();
        let scope = scope.clone();
        let timer = self.host.after(delay_ms, move || {
            let host = inner.host.clone();
            host.spawn(async move { inner.renew_databricks(generation, resolved, scope).await });
        });
        let mut auth = lock(&self.auth);
        if auth.generation == generation {
            if let Some(previous) = auth.renewal.replace(timer) {
                previous.abort();
            }
        } else {
            timer.abort();
        }
    }

    async fn renew_databricks(
        self: Arc<Self>,
        generation: u64,
        resolved: Resolved,
        scope: CredentialScope,
    ) {
        if self.check_generation(generation).is_err() {
            return;
        }
        let tokens = self.databricks_tokens(&scope, &LookupMode::Cached).await;
        if self.check_generation(generation).is_err() {
            return;
        }
        match tokens {
            Ok(Some(tokens)) => {
                if self
                    .rotate_credential(
                        generation,
                        &resolved,
                        tokens.access_token.clone(),
                        Some(tokens.expires_at_ms),
                    )
                    .await
                {
                    self.schedule_databricks_renewal(generation, &resolved, &scope, &tokens);
                }
            }
            Ok(None) => {
                self.databricks_grant_lost(&resolved, DatabricksError::ReauthenticationRequired);
            }
            Err(error) if error.is_cancelled() => {}
            Err(error) => {
                let error = CoreError::from(error);
                if error.requires_sign_in() {
                    self.databricks_grant_lost_with(&resolved, error);
                } else {
                    self.post(Msg::Emit(CoreEvent::Error {
                        scope: ErrorScope::Connection,
                        error,
                    }));
                    self.schedule_databricks_retry(generation, &resolved, &scope, RENEWAL_RETRY_MS);
                }
            }
        }
    }

    fn databricks_grant_lost(&self, resolved: &Resolved, error: DatabricksError) {
        self.databricks_grant_lost_with(resolved, error.into());
    }

    fn databricks_grant_lost_with(&self, resolved: &Resolved, error: CoreError) {
        self.sessions.disconnect();
        self.post(Msg::Disconnected {
            phase: ConnectionPhase::Disconnected,
        });
        self.sign_in_required(resolved, Some(error));
    }

    /// Deletes the saved grant for the workspace (sign-out).
    pub(crate) async fn forget_databricks_grant(
        &self,
        resolved: &Resolved,
    ) -> Result<(), CoreError> {
        let auth = self.databricks_auth()?;
        let scope = self.databricks_scope(resolved)?;
        let mutation = {
            let mut state = lock(&auth.state);
            state.cancel_login();
            state.tokens.clear(&scope)
        };
        lock(&auth.state).deliver(mutation.cancelled);
        self.persist(auth, &mutation.write)
            .await
            .map_err(CoreError::from)
    }
}

#[uniffi::export]
impl ClientCore {
    /// Starts a Databricks workspace sign-in for the connected-to server. Present
    /// `authorize_url` in the sign-in sheet, intercepting the HTTPS callback, and pass the
    /// callback to [`Self::complete_databricks_sign_in`]. A login still in progress is
    /// abandoned.
    ///
    /// # Errors
    ///
    /// [`CoreError::InvalidState`] before connecting to a Databricks workspace server;
    /// [`CoreError::Databricks`] for an unusable build client or workspace URL, or a failed RNG.
    pub fn begin_databricks_sign_in(&self) -> Result<DatabricksChallenge, CoreError> {
        let inner = &self.inner;
        let resolved = inner.resolved()?;
        let workspace = resolved
            .databricks_workspace
            .clone()
            .ok_or_else(not_databricks)?;
        let auth = inner.databricks_auth()?;
        let configuration = auth.configuration()?;
        let entropy = inner.entropy()?;
        let mut state = lock(&auth.state);
        state.cancel_login();
        let DatabricksState {
            login,
            tokens,
            attempts,
            next_attempt,
            ..
        } = &mut *state;
        let start = login
            .start(tokens, &workspace, configuration, entropy)
            .map_err(CoreError::from)?;
        *next_attempt = next_attempt.wrapping_add(1);
        let attempt_id = *next_attempt;
        attempts.insert(attempt_id, start.id);
        drop(state);
        inner.post(Msg::Phase(ConnectionPhase::SigningIn {
            base_url: resolved.endpoint.base_url().to_owned(),
        }));
        Ok(DatabricksChallenge {
            attempt_id,
            authorize_url: start.authorization_url,
            callback_host: start.callback_host,
            callback_path: start.callback_path,
        })
    }

    /// Finishes a Databricks sign-in with the callback URL the sheet intercepted: the code is
    /// exchanged at the workspace's verified issuer, the grant is saved, and the server is
    /// connected with the access token. It is refreshed and rotated in place before it
    /// expires.
    ///
    /// # Errors
    ///
    /// [`CoreError::InvalidState`] for an unknown attempt; [`CoreError::Databricks`] for an
    /// invalid callback, a refusal, a failed exchange or a failed save (the phase returns to
    /// `SignInRequired`); then connect failures.
    pub async fn complete_databricks_sign_in(
        &self,
        attempt_id: u64,
        callback_url: String,
    ) -> Result<ConnectedServer, CoreError> {
        let inner = &self.inner;
        let generation = lock(&inner.auth).generation;
        let resolved = inner.resolved()?;
        let auth = inner.databricks_auth()?;
        let login_id = lock(&auth.state)
            .attempts
            .remove(&attempt_id)
            .ok_or_else(|| CoreError::invalid_state("This sign-in is no longer in progress."))?;
        let fail = |error: DatabricksError| {
            let error = CoreError::from(error);
            inner.sign_in_required(&resolved, Some(error.clone()));
            error
        };
        let outcome = Url::parse(&callback_url)
            .map_or(BrowserOutcome::MissingCallback, BrowserOutcome::Callback);
        let pending = {
            let mut state = lock(&auth.state);
            let DatabricksState { login, tokens, .. } = &mut *state;
            login.browser_finished(tokens, login_id, outcome)
        }
        .map_err(fail)?;
        let exchanged = OAuthClient::new(&inner.transport)
            .exchange(
                &pending.attempt,
                &pending.authorization,
                inner.host.unix_ms(),
            )
            .await;
        inner.check_generation(generation)?;
        let commit = {
            let mut state = lock(&auth.state);
            let DatabricksState { login, tokens, .. } = &mut *state;
            login.exchange_finished(tokens, login_id, exchanged)
        }
        .map_err(fail)?;
        lock(&auth.state).deliver(commit.mutation.cancelled.clone());
        let written = inner.persist(auth, &commit.mutation.write).await;
        let signed_in = {
            let mut state = lock(&auth.state);
            let DatabricksState { login, tokens, .. } = &mut *state;
            login.commit_finished(tokens, login_id, written)
        }
        .map_err(fail)?;
        inner.check_generation(generation)?;
        let scope = inner.databricks_scope(&resolved)?;
        let server = inner
            .establish(
                generation,
                &resolved,
                Some(signed_in.access_token.clone()),
                None,
            )
            .await?;
        inner.schedule_databricks_renewal(generation, &resolved, &scope, &signed_in);
        Ok(server)
    }

    /// Abandons a Databricks sign-in (the user closed the sheet, or it could not be presented).
    /// The phase returns to `SignInRequired`; saved credentials are untouched.
    pub fn cancel_databricks_sign_in(&self, attempt_id: u64) {
        let inner = &self.inner;
        let Some(auth) = inner.databricks.as_ref() else {
            return;
        };
        let removed = {
            let mut state = lock(&auth.state);
            let removed = state.attempts.remove(&attempt_id).is_some();
            if removed {
                let DatabricksState { login, tokens, .. } = &mut *state;
                login.cancel(tokens);
            }
            removed
        };
        if let (true, Ok(resolved)) = (removed, inner.resolved()) {
            inner.sign_in_required(&resolved, None);
        }
    }
}
