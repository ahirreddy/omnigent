//! Ports of `DatabricksWorkspaceBootstrapTests` and `DatabricksLifecycleTests`.

use std::collections::VecDeque;

use futures::executor::block_on;

use super::*;
use crate::auth::databricks::client::OAuthClient;
use crate::auth::databricks::test_support::{TOKEN_BODY, TokenHarness, config, tokens, url};
use crate::auth::databricks::token_manager::{LookupMode, is_usable};
use crate::auth::databricks::tokens::encode_record;
use crate::auth::databricks::web_context::SESSION_COOKIE_NAME;
use crate::auth::testing::ScriptedTransport;

const NOW: u64 = 1_000_000;

fn web_context(raw: &str) -> WebContext {
    WebContext::new(&url(raw), &config()).unwrap()
}

fn saved_tokens() -> DatabricksTokens {
    tokens("test-access", "test-refresh", 3_000_000, None)
}

fn session_cookie(page: &Url, value: &str) -> SessionCookie {
    SessionCookie {
        name: SESSION_COOKIE_NAME.into(),
        value: value.into(),
        domain: page.host_str().unwrap().into(),
        path: "/".into(),
        secure: true,
        http_only: true,
        expires_at_ms: None,
    }
}

/// A host web-data store, recording mutations.
#[derive(Debug)]
struct FakeWebStore {
    identifier: StoreIdentifier,
    cookies: Vec<SessionCookie>,
    events: Vec<String>,
}

impl FakeWebStore {
    const fn new(identifier: StoreIdentifier) -> Self {
        Self {
            identifier,
            cookies: Vec::new(),
            events: Vec::new(),
        }
    }

    fn clear(&mut self) {
        self.events.push("clear".into());
        self.cookies.clear();
    }

    fn install(&mut self, cookies: &[SessionCookie]) {
        for cookie in cookies {
            self.events.push(format!("write-start:{}", cookie.value));
            self.cookies.retain(|existing| !existing.same_slot(cookie));
            self.cookies.push(cookie.clone());
            self.events.push(format!("write-end:{}", cookie.value));
        }
    }

    fn values(&self) -> Vec<String> {
        self.cookies.iter().map(|c| c.value.clone()).collect()
    }
}

/// The host side of a bootstrap: token manager over an in-memory secure store, a fake login and
/// session service, the sign-out tracker, and an OAuth transport for refreshes.
struct Env {
    tokens: TokenHarness,
    sign_outs: SignOutTracker,
    transport: ScriptedTransport,
    login_calls: usize,
    login_requested: Option<Url>,
    session_calls: usize,
    session_failures: VecDeque<DatabricksError>,
    session_failure: Option<DatabricksError>,
}

impl Env {
    fn new() -> Self {
        Self {
            tokens: TokenHarness::new(NOW),
            sign_outs: SignOutTracker::new(),
            transport: ScriptedTransport::new(),
            login_calls: 0,
            login_requested: None,
            session_calls: 0,
            session_failures: VecDeque::new(),
            session_failure: None,
        }
    }

    fn refresh_count(&self) -> usize {
        self.tokens.refreshes.len()
    }

    fn lookup(
        &mut self,
        scope: &CredentialScope,
        mode: &LookupMode,
    ) -> Result<Option<DatabricksTokens>, DatabricksError> {
        let transport = &self.transport;
        let now = self.tokens.now_ms;
        self.tokens.complete_with(scope, mode, |ticket| {
            block_on(OAuthClient::new(transport).refresh(
                &ticket.scope,
                &ticket.refresh_token,
                ticket.issuer.as_ref(),
                now,
            ))
        })
    }

    /// Runs a sign-out of `context` from `web` to completion.
    fn sign_out(
        &mut self,
        context: &WebContext,
        web: &mut FakeWebStore,
    ) -> Result<(), DatabricksError> {
        match self.sign_outs.begin(context, web.identifier)? {
            SignOutStart::AlreadyRunning => Ok(()),
            SignOutStart::Run { scope } => {
                let cleanup = self.tokens.clear(&scope).map(|()| web.clear());
                self.sign_outs.finished(web.identifier, cleanup)
            }
        }
    }

    /// Performs one bootstrap step and feeds its result back.
    fn advance(
        &mut self,
        flow: &mut WorkspaceBootstrap,
        web: &mut FakeWebStore,
        step: BootstrapStep,
    ) -> Result<BootstrapStep, DatabricksError> {
        match step {
            BootstrapStep::FinishPendingSignOut => {
                let result = self.sign_out(&flow.context.clone(), web);
                flow.sign_out_finished(&self.sign_outs, result)
            }
            BootstrapStep::LoadTokens { scope } => {
                let result = self.lookup(&scope, &LookupMode::Cached);
                flow.tokens_loaded(&self.sign_outs, result)
            }
            BootstrapStep::ResetWebStore => {
                flow.check_active(&self.sign_outs)?;
                web.clear();
                flow.web_store_reset(&self.sign_outs, Ok(()))
            }
            BootstrapStep::SignIn {
                workspace_url,
                configuration,
            } => {
                self.login_calls += 1;
                assert_eq!(
                    web.cookies,
                    Vec::new(),
                    "old account data is gone before login"
                );
                let signed_in = saved_tokens();
                let scope = CredentialScope::new(&workspace_url, &configuration).unwrap();
                self.login_requested = Some(workspace_url);
                let result = self.tokens.save(&scope, &signed_in).map(|()| signed_in);
                flow.signed_in(&self.sign_outs, result)
            }
            BootstrapStep::CreateSession { context, tokens } => {
                let result = self.create_session(&context, &tokens);
                flow.session_created(&self.sign_outs, result)
            }
            BootstrapStep::RefreshRejected { scope, tokens } => {
                let result = self.lookup(&scope, &LookupMode::Rejected(tokens));
                flow.refreshed(&self.sign_outs, result)
            }
            BootstrapStep::CheckCredential { scope, tokens } => {
                let current = self.tokens.is_current(&scope, &tokens);
                flow.credential_checked(&self.sign_outs, current)
            }
            BootstrapStep::InstallCookies { cookies, tokens } => {
                let current = self.tokens.is_current(flow.context.scope(), &tokens);
                flow.install_allowed(&self.sign_outs, current)?;
                web.install(&cookies);
                flow.cookies_installed(&self.sign_outs, Ok(web.cookies.clone()), NOW)
            }
            BootstrapStep::Ready(session) => Ok(BootstrapStep::Ready(session)),
        }
    }

    fn create_session(
        &mut self,
        context: &WebContext,
        tokens: &DatabricksTokens,
    ) -> Result<WorkspaceSession, DatabricksError> {
        self.session_calls += 1;
        assert!(tokens.is_valid());
        if let Some(failure) = self.session_failures.pop_front() {
            return Err(failure);
        }
        if let Some(failure) = &self.session_failure {
            return Err(failure.clone());
        }
        Ok(WorkspaceSession::for_context(
            context,
            vec![session_cookie(context.page_url(), "synthetic-session")],
        ))
    }

    fn start(
        &self,
        context: &WebContext,
        web: &FakeWebStore,
        intent: ConnectionIntent,
        page: Option<&Url>,
    ) -> Result<(WorkspaceBootstrap, BootstrapStep), DatabricksError> {
        WorkspaceBootstrap::start(context, web.identifier, intent, page, &self.sign_outs)
    }

    /// `prepare(context:store:intent:pageURL:)` to completion.
    fn prepare(
        &mut self,
        context: &WebContext,
        web: &mut FakeWebStore,
        intent: ConnectionIntent,
        page: Option<&Url>,
    ) -> Result<WorkspaceSession, DatabricksError> {
        let (mut flow, mut step) = self.start(context, web, intent, page)?;
        loop {
            step = match self.advance(&mut flow, web, step)? {
                BootstrapStep::Ready(session) => return Ok(session),
                next => next,
            };
        }
    }

    /// Runs until the flow asks to create a session, without creating it.
    fn until_session(
        &mut self,
        context: &WebContext,
        web: &mut FakeWebStore,
    ) -> (WorkspaceBootstrap, BootstrapStep) {
        let (mut flow, mut step) = self
            .start(context, web, ConnectionIntent::Connect, None)
            .unwrap();
        while !matches!(step, BootstrapStep::CreateSession { .. }) {
            step = self.advance(&mut flow, web, step).unwrap();
        }
        (flow, step)
    }

    /// Finishes a flow from `step`.
    fn resume(
        &mut self,
        flow: &mut WorkspaceBootstrap,
        web: &mut FakeWebStore,
        mut step: BootstrapStep,
    ) -> Result<WorkspaceSession, DatabricksError> {
        loop {
            step = match self.advance(flow, web, step)? {
                BootstrapStep::Ready(session) => return Ok(session),
                next => next,
            };
        }
    }

    /// Injects a debug fault the way the host's debug menu would. False when nothing is saved.
    fn inject(
        &mut self,
        fault: DebugFault,
        context: &WebContext,
        web: &mut FakeWebStore,
    ) -> Result<bool, DatabricksError> {
        if let DebugFaultPlan::Credentials(fault) = fault.plan(context, web.identifier)? {
            let Some(saved) = self.tokens.stored(context.scope()) else {
                return Ok(false);
            };
            let faulted = fault.apply(&saved, self.tokens.now_ms);
            self.tokens.save(context.scope(), &faulted)?;
        } else {
            web.cookies.retain(|c| c.name != SESSION_COOKIE_NAME);
        }
        Ok(true)
    }
}

/// `testCachedGrantSkipsBrowserAndWaitsForCookieInstallation`.
#[test]
fn bootstrap_cached_grant_skips_login() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    env.tokens.put(context.scope(), &saved_tokens());
    let mut web = FakeWebStore::new(context.store_identifier());
    web.cookies = vec![session_cookie(context.page_url(), "old")];
    let (mut flow, mut step) = env
        .start(&context, &web, ConnectionIntent::Connect, None)
        .unwrap();
    let mut installed_before_ready = false;
    let session = loop {
        assert!(!matches!(
            step,
            BootstrapStep::ResetWebStore | BootstrapStep::SignIn { .. }
        ));
        installed_before_ready |= matches!(step, BootstrapStep::InstallCookies { .. });
        step = match env.advance(&mut flow, &mut web, step).unwrap() {
            BootstrapStep::Ready(session) => break session,
            next => next,
        };
    };
    assert_eq!(env.login_calls, 0);
    assert_eq!(env.session_calls, 1);
    assert_eq!(&session.page_url, context.page_url());
    // The page only loads after the cookie write finished and was re-validated.
    assert_eq!(web.values(), vec!["synthetic-session".to_owned()]);
    assert!(!web.events.contains(&"clear".to_owned()));
    assert!(installed_before_ready);
}

/// `testInteractiveLoginClearsOnlySelectedWebStore`.
#[test]
fn bootstrap_interactive_login_clears_only_selected_store() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    let mut web = FakeWebStore::new(context.store_identifier());
    let other_context = web_context("https://workspace.databricks.com/omnigent?o=456");
    let mut other = FakeWebStore::new(other_context.store_identifier());
    other.cookies = vec![session_cookie(context.page_url(), "other-context")];
    env.prepare(&context, &mut web, ConnectionIntent::Connect, None)
        .unwrap();
    assert_eq!(env.login_calls, 1);
    assert_eq!(env.login_requested.as_ref(), Some(context.page_url()));
    assert_eq!(web.events.first().map(String::as_str), Some("clear"));
    assert_eq!(other.values(), vec!["other-context".to_owned()]);
    assert_eq!(other.events, Vec::<String>::new());
}

/// `testFailedCookieBootstrapCannotLeaveOldAccountDataForTheNextAttempt`.
#[test]
fn bootstrap_failed_session_leaves_no_old_store_data() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    env.session_failure = Some(DatabricksError::Rejected { status: 500 });
    let mut web = FakeWebStore::new(context.store_identifier());
    web.cookies = vec![session_cookie(context.page_url(), "old-account")];
    assert_eq!(
        env.prepare(&context, &mut web, ConnectionIntent::Connect, None),
        Err(DatabricksError::Rejected { status: 500 })
    );
    assert!(env.tokens.stored(context.scope()).is_some());
    assert_eq!(web.cookies, Vec::new());
    env.session_failure = None;
    env.prepare(&context, &mut web, ConnectionIntent::Connect, None)
        .unwrap();
    assert_eq!(env.login_calls, 1);
    assert_eq!(web.values(), vec!["synthetic-session".to_owned()]);
}

/// `testStorageAndSessionErrorsDoNotTriggerBrowserFallbackOrInstallCookies`.
#[test]
fn bootstrap_storage_and_session_errors_no_browser_fallback() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    let mut web = FakeWebStore::new(context.store_identifier());
    env.tokens.store.fail_get.set(true);
    assert!(matches!(
        env.prepare(&context, &mut web, ConnectionIntent::Connect, None),
        Err(DatabricksError::Storage(_))
    ));
    assert_eq!((env.login_calls, env.session_calls), (0, 0));
    assert_eq!(web.events, Vec::<String>::new());
    env.tokens.store.fail_get.set(false);
    env.tokens.put(context.scope(), &saved_tokens());
    env.session_failure = Some(DatabricksError::Rejected { status: 403 });
    assert_eq!(
        env.prepare(&context, &mut web, ConnectionIntent::Connect, None),
        Err(DatabricksError::Rejected { status: 403 })
    );
    assert_eq!(env.login_calls, 0);
    assert_eq!(web.events, Vec::<String>::new());
    assert!(env.tokens.stored(context.scope()).is_some());
}

/// `testCancellationDuringSessionRequestDiscardsLateResult`.
#[test]
fn bootstrap_cancel_discards_late_session_result() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    env.tokens.put(context.scope(), &saved_tokens());
    let mut web = FakeWebStore::new(context.store_identifier());
    let (mut flow, step) = env.until_session(&context, &mut web);
    flow.cancel();
    assert_eq!(
        env.resume(&mut flow, &mut web, step),
        Err(DatabricksError::Cancelled)
    );
    assert_eq!(web.events, Vec::<String>::new());
    assert_eq!(DatabricksError::Cancelled.user_message(), None);
}

/// `testWrongStoreCannotReceiveWorkspaceCookies`.
#[test]
fn bootstrap_wrong_store_identifier_rejected() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let other = web_context("https://workspace.databricks.com/omnigent?o=456");
    let mut env = Env::new();
    let mut web = FakeWebStore::new(other.store_identifier());
    assert_eq!(
        env.prepare(&context, &mut web, ConnectionIntent::Connect, None),
        Err(DatabricksError::WorkspaceChanged)
    );
    assert_eq!((env.login_calls, env.session_calls), (0, 0));
}

/// `testClearedGrantCannotInstallACompletedCookieExchange`.
#[test]
fn bootstrap_cleared_grant_rejects_completed_exchange() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    env.tokens.put(context.scope(), &saved_tokens());
    let mut web = FakeWebStore::new(context.store_identifier());
    let (mut flow, step) = env.until_session(&context, &mut web);
    // The grant disappears from the store while the session request is in flight.
    env.tokens.store.items.borrow_mut().clear();
    assert_eq!(
        env.resume(&mut flow, &mut web, step),
        Err(DatabricksError::CredentialsChanged)
    );
    assert_eq!(web.events, Vec::<String>::new());
}

/// `testSilentRecoveryDoesNotPresentBrowserWhenGrantIsMissing`.
#[test]
fn bootstrap_recover_without_grant_requires_reauth() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    let mut web = FakeWebStore::new(context.store_identifier());
    assert_eq!(
        env.prepare(&context, &mut web, ConnectionIntent::Recover, None),
        Err(DatabricksError::ReauthenticationRequired)
    );
    assert_eq!((env.login_calls, env.session_calls), (0, 0));
    assert_eq!(web.events, Vec::<String>::new());
}

/// `testRecoveryPreservesCurrentPageWithoutChangingCredentialContext`.
#[test]
fn bootstrap_recovery_preserves_page_url() {
    let context = web_context("https://workspace.cloud.databricks.com/omnigent");
    let page = url("https://workspace.databricks.com/omnigent/c/abc?o=123#message");
    let mut env = Env::new();
    env.tokens.put(context.scope(), &saved_tokens());
    let mut web = FakeWebStore::new(context.store_identifier());
    let session = env
        .prepare(&context, &mut web, ConnectionIntent::Recover, Some(&page))
        .unwrap();
    assert_eq!(session.page_url, page);
    assert_eq!(env.login_calls, 0);
    assert!(env.tokens.stored(context.scope()).is_some());
    let alias = CredentialScope::new(&page, &config()).unwrap();
    assert_eq!(env.tokens.stored(&alias), None);
}

/// `testSession401RefreshesOnceThenRetriesWithoutBrowser`.
#[test]
fn bootstrap_session_401_refreshes_once_then_retries() {
    let context = web_context("https://test-workspace.cloud.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    env.tokens.put(context.scope(), &saved_tokens());
    env.transport.json(200, TOKEN_BODY);
    env.session_failures
        .push_back(DatabricksError::Rejected { status: 401 });
    let mut web = FakeWebStore::new(context.store_identifier());
    env.prepare(&context, &mut web, ConnectionIntent::Recover, None)
        .unwrap();
    let requests = env.transport.take();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, "POST");
    assert_eq!(env.session_calls, 2);
    assert_eq!(env.login_calls, 0);
    assert_eq!(
        env.tokens
            .stored(context.scope())
            .unwrap()
            .access_token
            .expose(),
        "opaque-access"
    );
}

/// `testRepeated401DoesNotLoopOrEraseAValidRefreshGrant`.
#[test]
fn bootstrap_repeated_401_bounded_keeps_grant() {
    let context = web_context("https://test-workspace.cloud.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    env.tokens.put(context.scope(), &saved_tokens());
    env.transport.json(200, TOKEN_BODY);
    env.session_failure = Some(DatabricksError::Rejected { status: 401 });
    let mut web = FakeWebStore::new(context.store_identifier());
    assert_eq!(
        env.prepare(&context, &mut web, ConnectionIntent::Recover, None),
        Err(DatabricksError::Rejected { status: 401 })
    );
    assert_eq!(env.transport.take().len(), 1, "one refresh");
    assert_eq!(env.refresh_count(), 1);
    assert_eq!(env.session_calls, 2);
    assert_eq!(env.login_calls, 0);
    assert!(env.tokens.stored(context.scope()).is_some());
}

/// `testDebugTokenFaultsKeepTheRefreshGrantUntilItIsTheChosenFault`.
#[test]
fn bootstrap_debug_token_faults_touch_only_chosen_field() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    env.tokens.put(context.scope(), &saved_tokens());
    let mut web = FakeWebStore::new(context.store_identifier());

    assert_eq!(
        env.inject(DebugFault::AccessToken, &context, &mut web),
        Ok(true)
    );
    let stored = env.tokens.stored(context.scope()).unwrap();
    assert_ne!(stored.access_token.expose(), "test-access");
    assert_eq!(stored.refresh_token.expose(), "test-refresh");
    assert!(stored.expires_at_ms < NOW);

    env.tokens.put(context.scope(), &saved_tokens());
    assert_eq!(
        env.inject(DebugFault::RejectedAccessToken, &context, &mut web),
        Ok(true)
    );
    let stored = env.tokens.stored(context.scope()).unwrap();
    assert_ne!(stored.access_token.expose(), "test-access");
    assert_eq!(stored.refresh_token.expose(), "test-refresh");
    // Unexpired, so the workspace rejects it instead of the app refreshing it first.
    assert!(is_usable(&stored, NOW));

    assert_eq!(
        env.inject(DebugFault::RefreshToken, &context, &mut web),
        Ok(true)
    );
    let stored = env.tokens.stored(context.scope()).unwrap();
    assert_ne!(stored.refresh_token.expose(), "test-refresh");
    assert!(stored.expires_at_ms < NOW);
    assert_eq!(web.events, Vec::<String>::new());

    web.cookies = vec![session_cookie(context.page_url(), "live")];
    let mut unrelated = session_cookie(context.page_url(), "dark");
    unrelated.name = "omnigent-theme".into();
    web.cookies.push(unrelated);
    assert_eq!(
        env.inject(DebugFault::SessionCookie, &context, &mut web),
        Ok(true)
    );
    assert_eq!(web.values(), vec!["dark".to_owned()]);
}

/// `testDebugFaultNeedsSavedCredentialsAndTheSelectedStore`.
#[test]
fn bootstrap_debug_fault_needs_credentials_and_store() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    let mut web = FakeWebStore::new(context.store_identifier());
    assert_eq!(
        env.inject(DebugFault::AccessToken, &context, &mut web),
        Ok(false)
    );
    let other = web_context("https://workspace.databricks.com/omnigent?o=456");
    let mut wrong = FakeWebStore::new(other.store_identifier());
    assert_eq!(
        env.inject(DebugFault::SessionCookie, &context, &mut wrong),
        Err(DatabricksError::WorkspaceChanged)
    );
}

/// `testInjectedAccessTokenFaultRecoversWithoutBrowserSignIn`.
#[test]
fn bootstrap_injected_access_fault_recovers_without_login() {
    let context = web_context("https://test-workspace.cloud.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    env.tokens.put(context.scope(), &saved_tokens());
    env.transport.json(200, TOKEN_BODY);
    let mut web = FakeWebStore::new(context.store_identifier());
    assert_eq!(
        env.inject(DebugFault::AccessToken, &context, &mut web),
        Ok(true)
    );
    env.prepare(&context, &mut web, ConnectionIntent::Recover, None)
        .unwrap();
    assert_eq!(env.transport.take().len(), 1, "one refresh");
    assert_eq!(env.login_calls, 0);
    assert_eq!(
        env.tokens
            .stored(context.scope())
            .unwrap()
            .access_token
            .expose(),
        "opaque-access"
    );
}

/// `testInjectedRefreshFaultAsksForSignInInsteadOfOpeningTheBrowser`.
#[test]
fn bootstrap_injected_refresh_fault_requires_reauth() {
    let context = web_context("https://test-workspace.cloud.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    env.tokens.put(context.scope(), &saved_tokens());
    env.transport.json(400, r#"{"error":"invalid_grant"}"#);
    let mut web = FakeWebStore::new(context.store_identifier());
    assert_eq!(
        env.inject(DebugFault::RefreshToken, &context, &mut web),
        Ok(true)
    );
    assert_eq!(
        env.prepare(&context, &mut web, ConnectionIntent::Recover, None),
        Err(DatabricksError::ReauthenticationRequired)
    );
    assert_eq!(env.login_calls, 0);
    assert_eq!(env.tokens.stored(context.scope()), None);
}

/// `DatabricksLifecycleTests::testRecoveryRequiresHealthyPageAndCooldownBeforeAnotherAttempt`.
#[test]
fn recovery_policy_requires_ready_and_cooldown() {
    let mut policy = RecoveryPolicy::new();
    let now = 1_000_000;
    assert!(policy.begin(now));
    assert!(!policy.begin(now + 120_000));
    policy.mark_ready();
    assert!(!policy.begin(now + 59_000));
    assert!(policy.begin(now + 60_000));
    assert!(!policy.begin(now + 180_000));
}

/// `DatabricksLifecycleTests::testSignOutClearsOnlyItsContextAndSuppressesAutoOpen`.
#[test]
fn sign_out_clears_only_its_context_and_suppresses_auto_open() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let other = web_context("https://workspace.databricks.com/omnigent?o=456");
    let mut env = Env::new();
    env.tokens.put(context.scope(), &saved_tokens());
    env.tokens.put(
        other.scope(),
        &tokens("other", "test-refresh", 3_000_000, None),
    );
    let mut web = FakeWebStore::new(context.store_identifier());
    web.cookies = vec![session_cookie(context.page_url(), "live")];
    let SignOutStart::Run { scope } = env.sign_outs.begin(&context, web.identifier).unwrap() else {
        panic!("expected to run the cleanup");
    };
    assert!(env.sign_outs.is_pending(web.identifier));
    assert_eq!(
        env.sign_outs.pending_markers(),
        vec![context.store_identifier().to_string()]
    );
    assert!(stops_auto_opening(context.page_url().as_str(), &context));
    assert_eq!(
        env.sign_outs.begin(&context, web.identifier),
        Ok(SignOutStart::AlreadyRunning)
    );
    let cleanup = env.tokens.clear(&scope).map(|()| web.clear());
    env.sign_outs.finished(web.identifier, cleanup).unwrap();
    assert!(!env.sign_outs.is_pending(web.identifier));
    assert_eq!(env.tokens.stored(context.scope()), None);
    assert_eq!(web.cookies, Vec::new());
    assert_eq!(
        env.tokens
            .stored(other.scope())
            .unwrap()
            .access_token
            .expose(),
        "other"
    );
    assert!(!stops_auto_opening(other.page_url().as_str(), &context));
}

/// `DatabricksLifecycleTests::testFailedSignOutIsRetriedAfterManagerRecreationBeforeNewLogin`.
#[test]
fn sign_out_failed_retried_before_new_login() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    env.tokens.put(context.scope(), &saved_tokens());
    let mut web = FakeWebStore::new(context.store_identifier());
    env.tokens.store.fail_delete.set(true);
    assert!(matches!(
        env.sign_out(&context, &mut web),
        Err(DatabricksError::SignOutIncomplete { cause }) if matches!(*cause, DatabricksError::Storage(_))
    ));
    assert!(env.sign_outs.is_pending(web.identifier));
    env.tokens.store.fail_delete.set(false);
    // The app restarts: a new token manager and a tracker restored from the persisted markers.
    let markers = env.sign_outs.pending_markers();
    env.tokens = env.tokens.with_new_manager();
    env.sign_outs = SignOutTracker::restore(markers);
    assert_eq!(
        env.prepare(&context, &mut web, ConnectionIntent::Recover, None),
        Err(DatabricksError::ReauthenticationRequired)
    );
    assert_eq!(env.login_calls, 0);
    assert_eq!(env.tokens.stored(context.scope()), None);
    assert!(!env.sign_outs.is_pending(web.identifier));
}

/// `DatabricksLifecycleTests::testPendingSignOutRejectsLateCookieBootstrap`.
#[test]
fn sign_out_pending_rejects_late_bootstrap() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    env.tokens.put(context.scope(), &saved_tokens());
    let mut web = FakeWebStore::new(context.store_identifier());
    let (mut flow, step) = env.until_session(&context, &mut web);
    let SignOutStart::Run { scope } = env.sign_outs.begin(&context, web.identifier).unwrap() else {
        panic!("expected to run the cleanup");
    };
    assert_eq!(
        env.resume(&mut flow, &mut web, step),
        Err(DatabricksError::CredentialsChanged)
    );
    let cleanup = env.tokens.clear(&scope).map(|()| web.clear());
    env.sign_outs.finished(web.identifier, cleanup).unwrap();
    assert_eq!(web.cookies, Vec::new());
    assert!(
        !web.events
            .iter()
            .any(|event| event.starts_with("write-start:"))
    );
}

/// `DatabricksLifecycleTests::testCompletedSignOutRejectsLateBootstrapEvenIfCredentialsReappear`.
#[test]
fn sign_out_completed_generation_rejects_late_bootstrap() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    let original = saved_tokens();
    env.tokens.put(context.scope(), &original);
    let mut web = FakeWebStore::new(context.store_identifier());
    let (mut flow, step) = env.until_session(&context, &mut web);
    env.sign_out(&context, &mut web).unwrap();
    env.tokens.put(context.scope(), &original);
    assert_eq!(
        env.resume(&mut flow, &mut web, step),
        Err(DatabricksError::CredentialsChanged)
    );
    assert_eq!(web.cookies, Vec::new());
    assert_eq!(env.tokens.stored(context.scope()), Some(original));
}

/// `DatabricksLifecycleTests::testCoordinatorRecovers401ButDoesNotRetry403` (the decision; the
/// `WebView` coordinator stays Swift).
#[test]
fn workspace_http_status_401_recovers_403_fails() {
    assert_eq!(
        workspace_http_status_action(401),
        Some(WorkspaceStatusAction::Recover)
    );
    let Some(WorkspaceStatusAction::Fail(error)) = workspace_http_status_action(403) else {
        panic!("403 must fail without retrying");
    };
    assert_eq!(error, DatabricksError::Rejected { status: 403 });
    assert_eq!(
        error.user_message().as_deref(),
        Some("Databricks rejected session creation (HTTP 403).")
    );
    for status in [200, 302, 404, 500] {
        assert_eq!(workspace_http_status_action(status), None);
    }
}

#[test]
fn installed_cookie_must_be_the_issued_secure_session_cookie() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    env.tokens.put(context.scope(), &saved_tokens());
    let mut web = FakeWebStore::new(context.store_identifier());
    let (mut flow, mut step) = env.until_session(&context, &mut web);
    step = env.advance(&mut flow, &mut web, step).unwrap();
    step = env.advance(&mut flow, &mut web, step).unwrap();
    let BootstrapStep::InstallCookies { .. } = step else {
        panic!("expected cookie installation, got {step:?}");
    };
    // The host's store dropped the cookie: the page must not load.
    assert_eq!(
        flow.cookies_installed(&env.sign_outs, Ok(Vec::new()), NOW),
        Err(DatabricksError::MissingCookie)
    );
    assert!(encode_record(&saved_tokens()).is_ok());
}

#[test]
fn a_cancelled_flow_refuses_every_later_check() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let mut env = Env::new();
    env.tokens.put(context.scope(), &saved_tokens());
    let mut web = FakeWebStore::new(context.store_identifier());
    let (mut flow, _step) = env.until_session(&context, &mut web);
    assert_eq!(
        flow.install_allowed(&env.sign_outs, Ok(false)),
        Err(DatabricksError::CredentialsChanged)
    );
    flow.cancel();
    assert_eq!(
        flow.check_active(&env.sign_outs),
        Err(DatabricksError::Cancelled)
    );
    assert!(matches!(
        flow.credential_checked(&env.sign_outs, Ok(true)),
        Err(DatabricksError::Cancelled)
    ));
}

#[test]
fn signing_out_of_another_contexts_store_is_refused() {
    let context = web_context("https://workspace.databricks.com/omnigent?o=123");
    let other = web_context("https://workspace.databricks.com/omnigent?o=456");
    let mut env = Env::new();
    assert!(matches!(
        env.sign_outs.begin(&context, other.store_identifier()),
        Err(DatabricksError::WorkspaceChanged)
    ));
}
