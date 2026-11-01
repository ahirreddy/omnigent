//! Single-flight interactive sign-in policy. Port of
//! `web/ios/Omnigent/DatabricksLoginManager.swift`.
//!
//! The host presents the browser and sends the exchange; this machine decides which results
//! count. Only one login runs at a time, a cancelled login's late browser callback or exchange
//! result is ignored, and a login only commits if no newer login or clear superseded it.
//!
//! # Host flow
//!
//! 1. [`LoginManager::start`] → present `authorization_url` in the sign-in browser, intercepting
//!    the HTTPS callback host and path.
//! 2. [`LoginManager::browser_finished`] with the browser's outcome → a [`PendingExchange`].
//! 3. Send the exchange ([`super::OAuthClient::exchange`]) and pass its result to
//!    [`LoginManager::exchange_finished`] → a [`LoginCommit`].
//! 4. Perform the commit's write, report it to [`super::TokenManager::write_finished`], answer
//!    the invalidated waiters, and pass the write result to [`LoginManager::commit_finished`].
//!
//! [`LoginManager::cancel`] at any point returns the login to tear down (dismiss the browser,
//! cancel the exchange task).

use std::fmt;

use url::Url;

use super::attempt::{AuthorizationResponse, OAuthAttempt};
use super::config::OAuthConfiguration;
use super::error::DatabricksError;
use super::token_manager::{Mutation, SignIn, TokenManager};
use super::tokens::DatabricksTokens;
use crate::auth::EntropySource;

/// One interactive login.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LoginId(u64);

/// What the host needs to present the sign-in browser. `Debug` hides the authorize URL, which
/// carries the attempt's `state`.
#[derive(Clone, PartialEq, Eq)]
pub struct LoginStart {
    /// The login, for the follow-up calls.
    pub id: LoginId,
    /// The `/oidc/v1/authorize` URL to open.
    pub authorization_url: String,
    /// The HTTPS callback host the browser intercepts.
    pub callback_host: String,
    /// The HTTPS callback path the browser intercepts.
    pub callback_path: String,
}

impl fmt::Debug for LoginStart {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LoginStart")
            .field("id", &self.id)
            .field("authorization_url", &"<redacted>")
            .field("callback_host", &self.callback_host)
            .field("callback_path", &self.callback_path)
            .finish()
    }
}

/// How the sign-in browser finished.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BrowserOutcome {
    /// The browser reached the callback URL.
    Callback(Url),
    /// The user (or the host) cancelled.
    Cancelled,
    /// The browser could not be presented.
    Unavailable,
    /// Another browser session was already running.
    InProgress,
    /// The browser failed. Its platform message is deliberately not passed on.
    Failed,
    /// The browser finished without a callback URL.
    MissingCallback,
}

/// A validated callback, ready to exchange.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingExchange {
    /// The login.
    pub id: LoginId,
    /// The attempt (scope, verifier).
    pub attempt: OAuthAttempt,
    /// The code and the issuer that must receive it.
    pub authorization: AuthorizationResponse,
}

/// Tokens to persist before the login succeeds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoginCommit {
    /// The login.
    pub id: LoginId,
    /// The write (and invalidated refresh waiters) to apply through the token manager.
    pub mutation: Mutation,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Phase {
    Browser,
    Exchanging,
    Committing(DatabricksTokens),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Active {
    id: LoginId,
    attempt: OAuthAttempt,
    sign_in: SignIn,
    phase: Phase,
}

/// The single-flight login state.
#[derive(Debug, Default)]
pub struct LoginManager {
    active: Option<Active>,
    next_id: u64,
}

impl LoginManager {
    /// No login in flight.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Whether a login is running.
    #[must_use]
    pub const fn is_in_flight(&self) -> bool {
        self.active.is_some()
    }

    /// Starts a login for `workspace_url` (its `o=` is kept in the authorize URL and the scope).
    ///
    /// # Errors
    ///
    /// [`DatabricksError::LoginInProgress`] while another login runs; otherwise see
    /// [`OAuthAttempt::new`].
    pub fn start(
        &mut self,
        tokens: &mut TokenManager,
        workspace_url: &Url,
        configuration: &OAuthConfiguration,
        entropy: &dyn EntropySource,
    ) -> Result<LoginStart, DatabricksError> {
        if self.is_in_flight() {
            return Err(DatabricksError::LoginInProgress);
        }
        let attempt = OAuthAttempt::new(workspace_url, configuration, entropy)?;
        self.next_id = self.next_id.wrapping_add(1);
        let id = LoginId(self.next_id);
        let start = LoginStart {
            id,
            authorization_url: attempt.authorization_url(),
            callback_host: configuration.callback_host().to_owned(),
            callback_path: configuration.callback_path().to_owned(),
        };
        let sign_in = tokens.begin_sign_in(attempt.scope());
        self.active = Some(Active {
            id,
            attempt,
            sign_in,
            phase: Phase::Browser,
        });
        Ok(start)
    }

    fn active_in(&self, id: LoginId, phase: impl Fn(&Phase) -> bool) -> bool {
        self.active
            .as_ref()
            .is_some_and(|active| active.id == id && phase(&active.phase))
    }

    fn end(&mut self, tokens: &mut TokenManager) -> Option<LoginId> {
        let active = self.active.take()?;
        tokens.end_sign_in(&active.sign_in);
        Some(active.id)
    }

    /// Applies the browser's outcome.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::Cancelled`] for a login that is not waiting for its browser (cancelled,
    /// superseded, or already called back); nothing changes. Otherwise the mapped browser error
    /// or the callback validation error from [`OAuthAttempt::authorization_response`], which end
    /// the login without any token request.
    pub fn browser_finished(
        &mut self,
        tokens: &mut TokenManager,
        id: LoginId,
        outcome: BrowserOutcome,
    ) -> Result<PendingExchange, DatabricksError> {
        if !self.active_in(id, |phase| *phase == Phase::Browser) {
            return Err(DatabricksError::Cancelled);
        }
        let validated = match outcome {
            BrowserOutcome::Callback(url) => self
                .active
                .as_ref()
                .ok_or(DatabricksError::Cancelled)
                .and_then(|active| active.attempt.authorization_response(&url)),
            BrowserOutcome::Cancelled => Err(DatabricksError::Cancelled),
            BrowserOutcome::Unavailable => Err(DatabricksError::BrowserUnavailable),
            BrowserOutcome::InProgress => Err(DatabricksError::LoginInProgress),
            BrowserOutcome::Failed => Err(DatabricksError::AuthenticationFailed),
            BrowserOutcome::MissingCallback => Err(DatabricksError::InvalidCallback),
        };
        match (validated, self.active.as_mut()) {
            (Ok(authorization), Some(active)) => {
                active.phase = Phase::Exchanging;
                Ok(PendingExchange {
                    id,
                    attempt: active.attempt.clone(),
                    authorization,
                })
            }
            (Ok(_), None) => Err(DatabricksError::Cancelled),
            (Err(error), _) => {
                self.end(tokens);
                Err(error)
            }
        }
    }

    /// Applies the exchange result and prepares the commit.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::Cancelled`] for a login that is no longer exchanging (its late result is
    /// discarded and never stored) or whose sign-in a newer login or clear superseded; the
    /// exchange error itself; or [`DatabricksError::InvalidCredentialData`].
    pub fn exchange_finished(
        &mut self,
        tokens: &mut TokenManager,
        id: LoginId,
        result: Result<DatabricksTokens, DatabricksError>,
    ) -> Result<LoginCommit, DatabricksError> {
        if !self.active_in(id, |phase| *phase == Phase::Exchanging) {
            return Err(DatabricksError::Cancelled);
        }
        let committed = result.and_then(|signed_in| {
            let active = self.active.as_ref().ok_or(DatabricksError::Cancelled)?;
            let mutation = tokens.save_signed_in(&active.sign_in, &signed_in)?;
            Ok((signed_in, mutation))
        });
        match (committed, self.active.as_mut()) {
            (Ok((signed_in, mutation)), Some(active)) => {
                active.phase = Phase::Committing(signed_in);
                Ok(LoginCommit { id, mutation })
            }
            (Ok(_), None) => Err(DatabricksError::Cancelled),
            (Err(error), _) => {
                self.end(tokens);
                Err(error)
            }
        }
    }

    /// Finishes the login once the commit's write was reported. The login ends either way.
    ///
    /// # Errors
    ///
    /// The write's error (a persistence failure is never a successful login), or
    /// [`DatabricksError::Cancelled`] when the login was cancelled meanwhile.
    pub fn commit_finished(
        &mut self,
        tokens: &mut TokenManager,
        id: LoginId,
        write: Result<(), DatabricksError>,
    ) -> Result<DatabricksTokens, DatabricksError> {
        let committed = match self.active.as_ref() {
            Some(Active {
                id: active,
                phase: Phase::Committing(committed),
                ..
            }) if *active == id => committed.clone(),
            _ => return Err(DatabricksError::Cancelled),
        };
        self.end(tokens);
        write.map(|()| committed)
    }

    /// Cancels the running login, returning it so the host can dismiss its browser and cancel
    /// its exchange. Saved credentials are untouched.
    pub fn cancel(&mut self, tokens: &mut TokenManager) -> Option<LoginId> {
        self.end(tokens)
    }
}

#[cfg(test)]
mod tests {
    use futures::executor::block_on;

    use super::*;
    use crate::auth::databricks::client::OAuthClient;
    use crate::auth::databricks::issuer::OAuthIssuer;
    use crate::auth::databricks::scope::CredentialScope;
    use crate::auth::databricks::test_support::{
        TOKEN_BODY, TokenHarness, config, discovery_body, scope, tokens, url,
    };
    use crate::auth::testing::{FixedEntropy, ScriptedTransport};

    const WORKSPACE: &str = "https://test-workspace.cloud.databricks.com";

    struct Login {
        harness: TokenHarness,
        manager: LoginManager,
        entropy: FixedEntropy,
        transport: ScriptedTransport,
        configuration: OAuthConfiguration,
    }

    impl Login {
        fn new() -> Self {
            Self::with_config(config())
        }

        fn with_config(configuration: OAuthConfiguration) -> Self {
            Self {
                harness: TokenHarness::new(1_000_000),
                manager: LoginManager::new(),
                entropy: FixedEntropy::counting(),
                transport: ScriptedTransport::new(),
                configuration,
            }
        }

        fn start(&mut self, workspace: &str) -> Result<LoginStart, DatabricksError> {
            self.manager.start(
                &mut self.harness.manager,
                &url(workspace),
                &self.configuration,
                &self.entropy,
            )
        }

        /// The callback the provider would send for `start`.
        fn callback(&self, start: &LoginStart, issuer: Option<&str>) -> BrowserOutcome {
            let authorize = url(&start.authorization_url);
            let state = authorize
                .query_pairs()
                .find(|(name, _)| name == "state")
                .map(|(_, value)| value.into_owned())
                .unwrap();
            let mut callback = format!(
                "{}?state={state}&code=code",
                self.configuration.redirect_uri()
            );
            if let Some(issuer) = issuer {
                callback.push_str("&iss=");
                callback.push_str(issuer);
            }
            BrowserOutcome::Callback(url(&callback))
        }

        fn browser(
            &mut self,
            id: LoginId,
            outcome: BrowserOutcome,
        ) -> Result<PendingExchange, DatabricksError> {
            self.manager
                .browser_finished(&mut self.harness.manager, id, outcome)
        }

        fn exchange(
            &mut self,
            pending: &PendingExchange,
        ) -> Result<DatabricksTokens, DatabricksError> {
            let result = block_on(OAuthClient::new(&self.transport).exchange(
                &pending.attempt,
                &pending.authorization,
                self.harness.now_ms,
            ));
            self.finish(pending.id, result)
        }

        fn finish(
            &mut self,
            id: LoginId,
            result: Result<DatabricksTokens, DatabricksError>,
        ) -> Result<DatabricksTokens, DatabricksError> {
            let commit = self
                .manager
                .exchange_finished(&mut self.harness.manager, id, result)?;
            assert_eq!(commit.mutation.cancelled, Vec::new());
            let written = self.harness.perform(&commit.mutation.write);
            let outcome = self
                .harness
                .manager
                .write_finished(commit.mutation.write.id, written);
            self.manager
                .commit_finished(&mut self.harness.manager, commit.id, outcome.result)
        }

        fn scope(&self, workspace: &str) -> CredentialScope {
            CredentialScope::new(&url(workspace), &self.configuration).unwrap()
        }

        fn script_success(&self, issuer: &str) {
            self.transport
                .json(200, &discovery_body(issuer))
                .json(200, TOKEN_BODY);
        }
    }

    /// `DatabricksLoginManagerTests::testCompletesHTTPSCallbackAndExchangesExactlyOnce`.
    #[test]
    fn databricks_login_completes_callback_and_exchanges_once() {
        let mut login = Login::with_config(
            OAuthConfiguration::new("test-client", "https://auth.example.com/custom/callback")
                .unwrap(),
        );
        login.script_success(&format!("{WORKSPACE}/oidc"));
        let start = login.start(WORKSPACE).unwrap();
        assert!(login.manager.is_in_flight());
        assert_eq!(start.callback_host, "auth.example.com");
        assert_eq!(start.callback_path, "/custom/callback");
        let callback = login.callback(&start, None);
        let pending = login.browser(start.id, callback.clone()).unwrap();
        // A second completion from the browser is stale and changes nothing.
        assert_eq!(
            login.browser(start.id, callback),
            Err(DatabricksError::Cancelled)
        );
        let signed_in = login.exchange(&pending).unwrap();
        assert_eq!(signed_in.access_token.expose(), "opaque-access");
        let token_requests = login
            .transport
            .take()
            .into_iter()
            .filter(|request| request.method == "POST")
            .count();
        assert_eq!(token_requests, 1);
        assert_eq!(
            login.harness.stored(&login.scope(WORKSPACE)),
            Some(signed_in)
        );
        assert!(!login.manager.is_in_flight());
    }

    /// `DatabricksLoginManagerTests::testRejectsConcurrentLogin`.
    #[test]
    fn databricks_login_rejects_concurrent_login() {
        let mut login = Login::new();
        let first = login.start(WORKSPACE).unwrap();
        assert_eq!(
            login.start(WORKSPACE),
            Err(DatabricksError::LoginInProgress)
        );
        assert_eq!(
            login.manager.cancel(&mut login.harness.manager),
            Some(first.id)
        );
        assert_eq!(
            login.browser(first.id, BrowserOutcome::Cancelled),
            Err(DatabricksError::Cancelled)
        );
        assert!(!login.manager.is_in_flight());
    }

    /// `DatabricksLoginManagerTests::testCancellationDoesNotNeedBrowserCompletionAndIgnoresStaleCallback`.
    #[test]
    fn databricks_login_stale_callback_ignored_after_cancel() {
        let mut login = Login::new();
        let first = login.start(WORKSPACE).unwrap();
        assert_eq!(
            login.manager.cancel(&mut login.harness.manager),
            Some(first.id)
        );
        assert!(!login.manager.is_in_flight());
        let second = login.start(WORKSPACE).unwrap();
        let stale = login.callback(&first, None);
        assert_eq!(
            login.browser(first.id, stale),
            Err(DatabricksError::Cancelled)
        );
        assert!(login.manager.is_in_flight(), "the newer login is untouched");
        login.script_success(&format!("{WORKSPACE}/oidc"));
        let current = login.callback(&second, None);
        let pending = login.browser(second.id, current).unwrap();
        assert!(login.exchange(&pending).is_ok());
        assert!(!login.manager.is_in_flight());
    }

    /// `DatabricksLoginManagerTests::testCancelDuringExchangeCancelsNetworkOperation`.
    #[test]
    fn databricks_login_cancel_during_exchange_aborts() {
        let mut login = Login::new();
        let start = login.start(WORKSPACE).unwrap();
        let callback = login.callback(&start, None);
        let pending = login.browser(start.id, callback).unwrap();
        // The host cancels the exchange task for the returned login.
        assert_eq!(
            login.manager.cancel(&mut login.harness.manager),
            Some(start.id)
        );
        assert!(!login.manager.is_in_flight());
        // Whatever the cancelled exchange produced is discarded, success included.
        assert_eq!(
            login.finish(pending.id, Err(DatabricksError::Cancelled)),
            Err(DatabricksError::Cancelled)
        );
        assert_eq!(
            login.finish(pending.id, Ok(tokens("late", "late", 9_000_000, None))),
            Err(DatabricksError::Cancelled)
        );
        assert_eq!(login.harness.stored(&login.scope(WORKSPACE)), None);
    }

    /// `DatabricksLoginManagerTests::testInvalidCallbackAndBrowserFailureNeverExchangeCode`.
    #[test]
    fn databricks_login_invalid_callback_never_exchanges() {
        let mut login = Login::new();
        for (outcome, expected) in [
            (
                BrowserOutcome::Callback(url(
                    "https://login.databricks.com/mobile-redirect?code=value&state=wrong",
                )),
                DatabricksError::InvalidCallback,
            ),
            (
                BrowserOutcome::Failed,
                DatabricksError::AuthenticationFailed,
            ),
            (
                BrowserOutcome::Unavailable,
                DatabricksError::BrowserUnavailable,
            ),
            (
                BrowserOutcome::MissingCallback,
                DatabricksError::InvalidCallback,
            ),
            (BrowserOutcome::InProgress, DatabricksError::LoginInProgress),
            (BrowserOutcome::Cancelled, DatabricksError::Cancelled),
        ] {
            let start = login.start(WORKSPACE).unwrap();
            assert_eq!(login.browser(start.id, outcome), Err(expected));
            assert!(!login.manager.is_in_flight());
        }
        assert_eq!(
            login.transport.take(),
            Vec::new(),
            "no request reached Databricks"
        );
    }

    /// `DatabricksLoginManagerTests::testPersistenceFailureIsNotReportedAsSuccessfulLogin`.
    #[test]
    fn databricks_login_save_failure_is_not_success() {
        let mut login = Login::new();
        login.harness.store.fail_set.set(true);
        login.script_success(&format!("{WORKSPACE}/oidc"));
        let start = login.start(WORKSPACE).unwrap();
        let callback = login.callback(&start, None);
        let pending = login.browser(start.id, callback).unwrap();
        assert!(matches!(
            login.exchange(&pending),
            Err(DatabricksError::Storage(_))
        ));
        assert!(!login.manager.is_in_flight());
    }

    /// `DatabricksLoginManagerTests::testClearOrNewerLoginRejectsOldLoginCommit`.
    #[test]
    fn databricks_login_old_commit_rejected_after_clear_or_newer() {
        for replace_with_login in [false, true] {
            let mut login = Login::new();
            let scope = login.scope(WORKSPACE);
            login.script_success(&format!("{WORKSPACE}/oidc"));
            let start = login.start(WORKSPACE).unwrap();
            let newer = tokens("new-login", "new-login-refresh", 9_000_000, None);
            if replace_with_login {
                let sign_in = login.harness.manager.begin_sign_in(&scope);
                login.harness.save_signed_in(&sign_in, &newer).unwrap();
            } else {
                login.harness.clear(&scope).unwrap();
            }
            let callback = login.callback(&start, None);
            let pending = login.browser(start.id, callback).unwrap();
            assert_eq!(login.exchange(&pending), Err(DatabricksError::Cancelled));
            assert_eq!(
                login.harness.stored(&scope),
                replace_with_login.then_some(newer)
            );
            assert!(!login.manager.is_in_flight());
        }
    }

    /// `DatabricksLoginManagerTests::testCancelledReplacementPreservesSavedCredentials`.
    #[test]
    fn databricks_cancelled_replacement_keeps_saved_tokens() {
        let mut login = Login::new();
        let scope = login.scope(WORKSPACE);
        let original = tokens("test-access", "test-refresh", 3_000_000, None);
        login.harness.save(&scope, &original).unwrap();
        let start = login.start(WORKSPACE).unwrap();
        assert_eq!(
            login.manager.cancel(&mut login.harness.manager),
            Some(start.id)
        );
        assert_eq!(login.harness.stored(&scope), Some(original));
    }

    /// `DatabricksLoginManagerTests::testIssuerDiscoveryKeepsSelectedWorkspaceContext`.
    #[test]
    fn databricks_login_issuer_discovery_keeps_workspace_scope() {
        let mut login = Login::new();
        let authority = "https://authority-workspace.cloud.databricks.com/oidc";
        login.script_success(authority);
        let selected = format!("{WORKSPACE}/omnigent?o=123");
        let start = login.start(&selected).unwrap();
        let authorize = url(&start.authorization_url);
        assert_eq!(
            authorize
                .query_pairs()
                .find(|(name, _)| name == "o")
                .map(|(_, value)| value.into_owned()),
            Some("123".to_owned())
        );
        let callback = login.callback(&start, Some(authority));
        let pending = login.browser(start.id, callback).unwrap();
        let signed_in = login.exchange(&pending).unwrap();
        assert_eq!(
            signed_in.issuer.as_ref().map(OAuthIssuer::as_str),
            Some(authority)
        );
        assert_eq!(
            login.harness.stored(&login.scope(&selected)),
            Some(signed_in)
        );
        assert_eq!(
            login
                .harness
                .stored(&scope("https://authority-workspace.cloud.databricks.com")),
            None
        );
        assert!(
            login
                .transport
                .take()
                .iter()
                .all(|request| request.url.starts_with(authority))
        );
    }

    /// `DatabricksLoginManagerTests::testUnsupportedCallbackIssuerNeverExchangesOrStoresTokens`.
    #[test]
    fn databricks_login_unsupported_issuer_never_stores() {
        let mut login = Login::new();
        let start = login.start(WORKSPACE).unwrap();
        let callback = login.callback(&start, Some("https://example.org/oidc"));
        assert_eq!(
            login.browser(start.id, callback),
            Err(DatabricksError::InvalidIssuer)
        );
        assert_eq!(login.transport.take(), Vec::new());
        assert_eq!(login.harness.stored(&login.scope(WORKSPACE)), None);
        assert!(!login.manager.is_in_flight());
    }
}
