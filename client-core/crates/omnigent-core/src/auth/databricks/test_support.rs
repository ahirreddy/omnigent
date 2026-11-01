//! Shared fixtures and harnesses for the Databricks tests.

use std::collections::BTreeMap;
use std::rc::Rc;

use futures::executor::block_on;
use url::Url;

use super::attempt::OAuthAttempt;
use super::config::OAuthConfiguration;
use super::error::DatabricksError;
use super::issuer::OAuthIssuer;
use super::query;
use super::scope::CredentialScope;
use super::token_manager::{
    LookupMode, LookupStep, RefreshStep, RefreshTicket, SignIn, StoreWrite, TokenManager,
    WaiterCompletion, WaiterId,
};
use super::tokens::{DatabricksTokens, decode_record, encode_record};
use crate::auth::testing::{MemoryStore, body_text};
use crate::auth::{EntropySource, SecretString, SecureStore as _, SecureStoreError};
use crate::http::HttpRequest;

pub(super) const REDIRECT: &str = "https://login.databricks.com/mobile-redirect";
pub(super) const ACCOUNT_ISSUER: &str =
    "https://accounts.cloud.databricks.com/oidc/accounts/test-account";
pub(super) const TOKEN_BODY: &str = r#"{"access_token":"opaque-access","refresh_token":"opaque-refresh","token_type":"Bearer","expires_in":120}"#;

pub(super) fn url(raw: &str) -> Url {
    Url::parse(raw).unwrap_or_else(|error| panic!("{raw}: {error}"))
}

pub(super) fn config_with(client_id: &str) -> OAuthConfiguration {
    OAuthConfiguration::new(client_id, REDIRECT).unwrap()
}

pub(super) fn config() -> OAuthConfiguration {
    config_with("test-client")
}

pub(super) fn scope(raw: &str) -> CredentialScope {
    CredentialScope::new(&url(raw), &config()).unwrap()
}

pub(super) fn scope_for_client(raw: &str, client_id: &str) -> CredentialScope {
    CredentialScope::new(&url(raw), &config_with(client_id)).unwrap()
}

pub(super) fn attempt_for(raw: &str, entropy: &dyn EntropySource) -> OAuthAttempt {
    OAuthAttempt::new(&url(raw), &config(), entropy).unwrap()
}

pub(super) fn tokens(
    access: &str,
    refresh: &str,
    expires_at_ms: u64,
    issuer: Option<OAuthIssuer>,
) -> DatabricksTokens {
    DatabricksTokens {
        access_token: SecretString::new(access),
        refresh_token: SecretString::new(refresh),
        expires_at_ms,
        issuer,
    }
}

/// A discovery document that confirms `issuer`.
pub(super) fn discovery_body(issuer: &str) -> String {
    serde_json::json!({"issuer": issuer, "token_endpoint": format!("{issuer}/v1/token")})
        .to_string()
}

/// The decoded form fields of a token request.
pub(super) fn form_fields(request: &HttpRequest) -> BTreeMap<String, String> {
    query::items(&body_text(request))
        .unwrap()
        .into_iter()
        .map(|item| (item.name, item.value.unwrap()))
        .collect()
}

/// Where a driven lookup stopped.
#[derive(Debug)]
pub(super) enum Driven {
    Ready(Option<DatabricksTokens>),
    Waiting(WaiterId),
}

/// Drives a [`TokenManager`] the way a host would, against an in-memory store, with refreshes
/// answered explicitly by the test (or automatically from `auto_refresh`).
#[derive(Debug)]
pub(super) struct TokenHarness {
    pub(super) manager: TokenManager,
    pub(super) store: Rc<MemoryStore>,
    pub(super) now_ms: u64,
    pub(super) refreshes: Vec<RefreshTicket>,
    pub(super) auto_refresh: Option<Result<DatabricksTokens, DatabricksError>>,
    completions: BTreeMap<WaiterId, Result<Option<DatabricksTokens>, DatabricksError>>,
}

impl TokenHarness {
    pub(super) fn new(now_ms: u64) -> Self {
        Self::with_store(Rc::new(MemoryStore::default()), now_ms)
    }

    pub(super) fn with_store(store: Rc<MemoryStore>, now_ms: u64) -> Self {
        Self {
            manager: TokenManager::new(),
            store,
            now_ms,
            refreshes: Vec::new(),
            auto_refresh: None,
            completions: BTreeMap::new(),
        }
    }

    /// A fresh manager over the same store, as after an app restart.
    pub(super) fn with_new_manager(&self) -> Self {
        Self::with_store(Rc::clone(&self.store), self.now_ms)
    }

    /// Writes a record directly, bypassing the manager.
    pub(super) fn put(&self, scope: &CredentialScope, tokens: &DatabricksTokens) {
        self.store
            .insert(&scope.store_key(), &encode_record(tokens).unwrap());
    }

    /// The decoded record in the store.
    pub(super) fn stored(&self, scope: &CredentialScope) -> Option<DatabricksTokens> {
        self.store
            .value(&scope.store_key())
            .map(|bytes| decode_record(&bytes).unwrap())
    }

    pub(super) fn perform(&self, write: &StoreWrite) -> Result<(), SecureStoreError> {
        write.value.as_ref().map_or_else(
            || block_on(self.store.delete(write.key.clone())),
            |bytes| block_on(self.store.set(write.key.clone(), bytes.clone())),
        )
    }

    fn record(&mut self, completions: Vec<WaiterCompletion>) {
        for completion in completions {
            assert!(
                self.completions
                    .insert(completion.waiter, completion.result)
                    .is_none(),
                "a waiter is answered once"
            );
        }
    }

    /// Runs a lookup until it has an answer or must wait.
    pub(super) fn drive(
        &mut self,
        scope: &CredentialScope,
        mode: &LookupMode,
    ) -> Result<Driven, DatabricksError> {
        let mut step = self.manager.lookup(scope, mode.clone());
        loop {
            step = match step {
                LookupStep::Write(write) => {
                    let result = self.perform(&write);
                    let outcome = self.manager.write_finished(write.id, result);
                    self.record(outcome.completions);
                    outcome.result?;
                    self.manager.lookup(scope, mode.clone())
                }
                LookupStep::Load(ticket) => {
                    let loaded = block_on(self.store.get(ticket.key()));
                    self.manager.loaded(ticket, loaded, self.now_ms)?
                }
                LookupStep::Ready(tokens) => return Ok(Driven::Ready(tokens)),
                LookupStep::StartRefresh { refresh, waiter } => {
                    self.refreshes.push(refresh);
                    return Ok(Driven::Waiting(waiter));
                }
                LookupStep::Wait { waiter } => return Ok(Driven::Waiting(waiter)),
            };
        }
    }

    /// A lookup that must stop at a shared refresh; returns the caller's waiter.
    pub(super) fn begin(&mut self, scope: &CredentialScope) -> WaiterId {
        match self.drive(scope, &LookupMode::Cached) {
            Ok(Driven::Waiting(waiter)) => waiter,
            other => panic!("expected to wait for a refresh, got {other:?}"),
        }
    }

    fn complete(
        &mut self,
        scope: &CredentialScope,
        mode: &LookupMode,
    ) -> Result<Option<DatabricksTokens>, DatabricksError> {
        let auto = self.auto_refresh.clone();
        self.complete_with(scope, mode, |_| {
            auto.clone()
                .unwrap_or_else(|| panic!("lookup needs a refresh but none is scripted"))
        })
    }

    /// Runs a lookup to its answer, sending any refresh it starts through `refresh`.
    pub(super) fn complete_with(
        &mut self,
        scope: &CredentialScope,
        mode: &LookupMode,
        refresh: impl FnOnce(&RefreshTicket) -> Result<DatabricksTokens, DatabricksError>,
    ) -> Result<Option<DatabricksTokens>, DatabricksError> {
        match self.drive(scope, mode)? {
            Driven::Ready(tokens) => Ok(tokens),
            Driven::Waiting(waiter) => {
                let index = self.refreshes.len() - 1;
                let result = refresh(&self.refreshes[index]);
                self.finish_refresh(index, result);
                self.result(waiter)
                    .unwrap_or_else(|| panic!("waiter {waiter:?} was not answered"))
            }
        }
    }

    /// `tokens(for:)`.
    pub(super) fn tokens(
        &mut self,
        scope: &CredentialScope,
    ) -> Result<Option<DatabricksTokens>, DatabricksError> {
        self.complete(scope, &LookupMode::Cached)
    }

    /// `refresh(rejected:for:)`.
    pub(super) fn refresh_rejected(
        &mut self,
        scope: &CredentialScope,
        rejected: &DatabricksTokens,
    ) -> Result<Option<DatabricksTokens>, DatabricksError> {
        self.complete(scope, &LookupMode::Rejected(rejected.clone()))
    }

    /// Answers the `index`th refresh the harness saw.
    pub(super) fn finish_refresh(
        &mut self,
        index: usize,
        result: Result<DatabricksTokens, DatabricksError>,
    ) {
        let id = self.refreshes[index].id;
        match self.manager.refresh_finished(id, result) {
            RefreshStep::Persist(write) => {
                let result = self.perform(&write);
                let outcome = self.manager.write_finished(write.id, result);
                self.record(outcome.completions);
            }
            RefreshStep::Completed(completions) => self.record(completions),
            RefreshStep::Discarded => {}
        }
    }

    pub(super) fn result(
        &self,
        waiter: WaiterId,
    ) -> Option<Result<Option<DatabricksTokens>, DatabricksError>> {
        self.completions.get(&waiter).cloned()
    }

    fn apply(&mut self, mutation: super::token_manager::Mutation) -> Result<(), DatabricksError> {
        self.record(mutation.cancelled);
        let result = self.perform(&mutation.write);
        let outcome = self.manager.write_finished(mutation.write.id, result);
        self.record(outcome.completions);
        outcome.result
    }

    pub(super) fn save(
        &mut self,
        scope: &CredentialScope,
        tokens: &DatabricksTokens,
    ) -> Result<(), DatabricksError> {
        let mutation = self.manager.save(scope, tokens)?;
        self.apply(mutation)
    }

    pub(super) fn save_signed_in(
        &mut self,
        sign_in: &SignIn,
        tokens: &DatabricksTokens,
    ) -> Result<(), DatabricksError> {
        let mutation = self.manager.save_signed_in(sign_in, tokens)?;
        self.apply(mutation)
    }

    pub(super) fn clear(&mut self, scope: &CredentialScope) -> Result<(), DatabricksError> {
        let mutation = self.manager.clear(scope);
        self.apply(mutation)
    }

    /// `isCurrent(_:for:)`.
    pub(super) fn is_current(
        &self,
        scope: &CredentialScope,
        candidate: &DatabricksTokens,
    ) -> Result<bool, DatabricksError> {
        let stored = block_on(self.store.get(scope.store_key()));
        self.manager.is_current(scope, stored, candidate)
    }
}
