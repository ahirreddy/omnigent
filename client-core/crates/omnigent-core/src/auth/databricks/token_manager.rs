//! Token scheduling and single-flight refresh, as a pure state machine. Port of
//! `web/ios/Omnigent/DatabricksTokenManager.swift`.
//!
//! The Swift actor did three things at once: decide, perform Keychain I/O, and run the refresh
//! task. Here the core only decides. The host performs every effect the machine asks for and
//! reports the result; time arrives as `now_ms`.
//!
//! # Host contract
//!
//! - Keep one [`TokenManager`] per process and serialize calls into it (an actor or a mutex), so
//!   callers cannot race a rotating refresh token for the same scope.
//! - Perform each [`StoreWrite`] with the shared [`crate::auth::SecureStore`] (`set` with the
//!   bytes, or `delete` when there are none), in the order the machine issued them, then call
//!   [`TokenManager::write_finished`] with the outcome. Writes are idempotent; repeating one is
//!   harmless.
//! - For a [`LookupStep::Load`], `get` the ticket's key and pass the outcome to
//!   [`TokenManager::loaded`]. A missing item is `Ok(None)`; a locked device is an error, never
//!   `Ok(None)`.
//! - For [`LookupStep::StartRefresh`], send the refresh (for example with
//!   [`super::OAuthClient::refresh`]) in a task that **outlives the caller**: a cancelled caller
//!   must not cancel the refresh, because a rotated grant must still be saved. Report the result
//!   with [`TokenManager::refresh_finished`].
//! - Hold each [`WaiterId`] until a [`WaiterCompletion`] for it arrives (from
//!   [`TokenManager::refresh_finished`], [`TokenManager::write_finished`], a mutation, or
//!   [`TokenManager::cancel_waiter`]).
//!
//! A host lookup loop, in outline:
//!
//! ```text
//! step = manager.lookup(scope, mode)
//! loop:
//!   Write(w)        -> manager.write_finished(w.id, store.perform(w)).result?; step = manager.lookup(scope, mode)
//!   Load(t)         -> step = manager.loaded(t, store.get(t.key()), now_ms)?
//!   Ready(tokens)   -> return tokens
//!   StartRefresh{refresh, waiter} -> spawn { manager.refresh_finished(refresh.id, client.refresh(..)) ... }; await waiter
//!   Wait{waiter}    -> await waiter
//! ```

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use super::error::DatabricksError;
use super::issuer::OAuthIssuer;
use super::scope::CredentialScope;
use super::tokens::{DatabricksTokens, decode_record, encode_record};
use crate::auth::{RENEWAL_MARGIN_MS, SecretString, SecureStoreError, SecureStoreKey};

/// A saved bundle is reused only while it has more than this much life left.
pub const REFRESH_MARGIN_MS: u64 = RENEWAL_MARGIN_MS;

/// Whether `tokens` can be used at `now_ms` without refreshing first.
#[must_use]
pub const fn is_usable(tokens: &DatabricksTokens, now_ms: u64) -> bool {
    tokens.expires_at_ms > now_ms.saturating_add(REFRESH_MARGIN_MS)
}

/// How long until `tokens` should be refreshed: zero once inside the safety margin. There are no
/// background timers; a host that wants to refresh proactively can schedule on this.
#[must_use]
pub const fn refresh_due_in_ms(tokens: &DatabricksTokens, now_ms: u64) -> u64 {
    tokens
        .expires_at_ms
        .saturating_sub(REFRESH_MARGIN_MS)
        .saturating_sub(now_ms)
}

/// One caller waiting for a shared refresh.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct WaiterId(u64);

/// One refresh request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct RefreshId(u64);

/// One store write.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct WriteId(u64);

/// One interactive sign-in; its commit fails once a newer sign-in or a clear supersedes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignIn {
    scope: CredentialScope,
    id: u64,
}

impl SignIn {
    /// The scope being signed in to.
    #[must_use]
    pub const fn scope(&self) -> &CredentialScope {
        &self.scope
    }
}

/// What a lookup is for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LookupMode {
    /// Return the saved bundle while it is usable; refresh it otherwise.
    Cached,
    /// The server rejected this (possibly unexpired) access token: refresh it once, but only if
    /// it is still the saved bundle.
    Rejected(DatabricksTokens),
}

/// A secure-store write the host must perform. `Debug` never shows the record bytes.
#[derive(Clone, PartialEq, Eq)]
pub struct StoreWrite {
    /// Report the outcome to [`TokenManager::write_finished`] with this id.
    pub id: WriteId,
    /// The item to write.
    pub key: SecureStoreKey,
    /// The record bytes to `set`, or `None` to `delete` the item.
    pub value: Option<Vec<u8>>,
}

impl fmt::Debug for StoreWrite {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StoreWrite")
            .field("id", &self.id)
            .field("key", &self.key)
            .field("value", &self.value.as_ref().map(|_| "<redacted record>"))
            .finish()
    }
}

/// A secure-store read the host must perform for a lookup.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoadTicket {
    scope: CredentialScope,
    mode: LookupMode,
    generation: u64,
}

impl LoadTicket {
    /// The item to read.
    #[must_use]
    pub fn key(&self) -> SecureStoreKey {
        self.scope.store_key()
    }

    /// The scope being looked up.
    #[must_use]
    pub const fn scope(&self) -> &CredentialScope {
        &self.scope
    }
}

/// A refresh the host must send.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RefreshTicket {
    /// Report the outcome to [`TokenManager::refresh_finished`] with this id.
    pub id: RefreshId,
    /// The scope being refreshed.
    pub scope: CredentialScope,
    /// The grant to redeem.
    pub refresh_token: SecretString,
    /// The saved issuer; the refreshed bundle must keep it.
    pub issuer: Option<OAuthIssuer>,
}

/// The next thing a lookup needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LookupStep {
    /// Persist this earlier change first (a rotation or deletion whose write failed), report it,
    /// then look up again. Saved tokens are never returned while a change is unpersisted.
    Write(StoreWrite),
    /// Read the saved record and pass it to [`TokenManager::loaded`].
    Load(LoadTicket),
    /// The answer: the usable bundle, or `None` when there is no reusable grant (sign-in needed).
    Ready(Option<DatabricksTokens>),
    /// Send `refresh` in a task that outlives this caller, and wait for `waiter`.
    StartRefresh {
        /// The refresh to send.
        refresh: RefreshTicket,
        /// This caller.
        waiter: WaiterId,
    },
    /// Another caller's refresh is running; wait for `waiter`.
    Wait {
        /// This caller.
        waiter: WaiterId,
    },
}

/// The answer for one waiting caller.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WaiterCompletion {
    /// The caller.
    pub waiter: WaiterId,
    /// Its result: the refreshed bundle, `None` when the grant was rejected and cleared, or the
    /// error ([`DatabricksError::Cancelled`] when the caller was cancelled or superseded).
    pub result: Result<Option<DatabricksTokens>, DatabricksError>,
}

/// What a refresh result needs next.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefreshStep {
    /// Persist the rotation (or the deletion after `invalid_grant`) and report it with
    /// [`TokenManager::write_finished`], which answers the waiters.
    Persist(StoreWrite),
    /// The waiters' answers; nothing to persist (transient failures keep the saved grant).
    Completed(Vec<WaiterCompletion>),
    /// The refresh was superseded by a clear or a newer sign-in; its result is discarded.
    Discarded,
}

/// The outcome of a store write.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WriteOutcome {
    /// Whether the write was durable. A failed write stays pending and is retried before any
    /// lookup can return saved tokens.
    pub result: Result<(), DatabricksError>,
    /// Waiters answered because this write persisted (or failed to persist) a refresh.
    pub completions: Vec<WaiterCompletion>,
}

/// A save or clear: perform `write`, and answer `cancelled` (in-flight refresh waiters).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mutation {
    /// The write to perform; report it with [`TokenManager::write_finished`].
    pub write: StoreWrite,
    /// Waiters of a refresh this mutation invalidated, all answered with
    /// [`DatabricksError::Cancelled`].
    pub cancelled: Vec<WaiterCompletion>,
}

#[derive(Clone, PartialEq, Eq)]
struct PendingWrite {
    id: WriteId,
    value: Option<Vec<u8>>,
    /// The bundle being saved, for answering refresh waiters.
    tokens: Option<DatabricksTokens>,
    /// The refresh whose result this write persists.
    refresh: Option<RefreshId>,
}

impl fmt::Debug for PendingWrite {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PendingWrite")
            .field("id", &self.id)
            .field("save", &self.value.is_some())
            .field("refresh", &self.refresh)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Refresh {
    id: RefreshId,
    saved_issuer: Option<OAuthIssuer>,
    waiters: BTreeSet<WaiterId>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct ScopeState {
    generation: u64,
    refresh: Option<Refresh>,
    pending: Option<PendingWrite>,
    sign_in: Option<u64>,
}

/// Per-process token state for every credential scope.
#[derive(Debug, Default)]
pub struct TokenManager {
    scopes: BTreeMap<CredentialScope, ScopeState>,
    next_id: u64,
}

impl TokenManager {
    /// An empty manager. Saved grants live in the host store, so a new manager sees them.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    const fn next(&mut self) -> u64 {
        self.next_id = self.next_id.wrapping_add(1);
        self.next_id
    }

    fn state(&mut self, scope: &CredentialScope) -> &mut ScopeState {
        self.scopes.entry(scope.clone()).or_default()
    }

    /// Starts (or continues) a lookup for `scope`.
    pub fn lookup(&mut self, scope: &CredentialScope, mode: LookupMode) -> LookupStep {
        if let Some(write) = self.pending_write(scope) {
            return LookupStep::Write(write);
        }
        if mode == LookupMode::Cached
            && let Some(waiter) = self.join_refresh(scope)
        {
            return LookupStep::Wait { waiter };
        }
        let generation = self.state(scope).generation;
        LookupStep::Load(LoadTicket {
            scope: scope.clone(),
            mode,
            generation,
        })
    }

    /// Continues a lookup with the store's answer for `ticket`.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::Storage`] when the store failed (never treated as "no credentials"),
    /// [`DatabricksError::InvalidCredentialData`] for a malformed record (left in place), and for
    /// [`LookupMode::Rejected`], [`DatabricksError::CredentialsChanged`] when the saved bundle is
    /// no longer the rejected one (a newer sign-in must not be refreshed on its behalf).
    pub fn loaded(
        &mut self,
        ticket: LoadTicket,
        loaded: Result<Option<Vec<u8>>, SecureStoreError>,
        now_ms: u64,
    ) -> Result<LookupStep, DatabricksError> {
        let bytes = loaded?;
        let LoadTicket {
            scope,
            mode,
            generation,
        } = ticket;
        let state = self.state(&scope);
        if state.generation != generation || state.pending.is_some() {
            // A save or clear landed while the host was reading; plan again from the new state.
            return Ok(self.lookup(&scope, mode));
        }
        let Some(bytes) = bytes else {
            return Ok(LookupStep::Ready(None));
        };
        let saved = decode_record(&bytes)?;
        match mode {
            LookupMode::Cached => {
                if let Some(waiter) = self.join_refresh(&scope) {
                    return Ok(LookupStep::Wait { waiter });
                }
                if is_usable(&saved, now_ms) {
                    return Ok(LookupStep::Ready(Some(saved)));
                }
            }
            LookupMode::Rejected(rejected) => {
                if saved != rejected {
                    return Err(DatabricksError::CredentialsChanged);
                }
                if let Some(waiter) = self.join_refresh(&scope) {
                    return Ok(LookupStep::Wait { waiter });
                }
            }
        }
        Ok(self.start_refresh(&scope, saved))
    }

    fn join_refresh(&mut self, scope: &CredentialScope) -> Option<WaiterId> {
        let waiter = WaiterId(self.next());
        let refresh = self.state(scope).refresh.as_mut()?;
        refresh.waiters.insert(waiter);
        Some(waiter)
    }

    fn start_refresh(&mut self, scope: &CredentialScope, saved: DatabricksTokens) -> LookupStep {
        let id = RefreshId(self.next());
        let waiter = WaiterId(self.next());
        self.state(scope).refresh = Some(Refresh {
            id,
            saved_issuer: saved.issuer.clone(),
            waiters: BTreeSet::from([waiter]),
        });
        LookupStep::StartRefresh {
            refresh: RefreshTicket {
                id,
                scope: scope.clone(),
                refresh_token: saved.refresh_token,
                issuer: saved.issuer,
            },
            waiter,
        }
    }

    /// Applies a refresh result.
    ///
    /// A success must keep the saved issuer (a response that drops it is
    /// [`DatabricksError::InvalidTokenResponse`]) and is persisted before any waiter sees it.
    /// [`DatabricksError::InvalidRefreshGrant`] deletes the grant and answers `None`. Every other
    /// error keeps the saved grant and is passed to the waiters.
    pub fn refresh_finished(
        &mut self,
        refresh: RefreshId,
        result: Result<DatabricksTokens, DatabricksError>,
    ) -> RefreshStep {
        let Some((scope, saved_issuer)) = self.scopes.iter().find_map(|(scope, state)| {
            state
                .refresh
                .as_ref()
                .filter(|current| current.id == refresh && state.pending.is_none())
                .map(|current| (scope.clone(), current.saved_issuer.clone()))
        }) else {
            return RefreshStep::Discarded;
        };
        let result = result.and_then(|tokens| {
            if tokens.issuer == saved_issuer {
                Ok(tokens)
            } else {
                Err(DatabricksError::InvalidTokenResponse)
            }
        });
        let (value, tokens) = match result {
            Ok(tokens) => match encode_record(&tokens) {
                Ok(bytes) => (Some(bytes), Some(tokens)),
                Err(error) => {
                    return RefreshStep::Completed(self.finish_refresh(&scope, &Err(error)));
                }
            },
            Err(DatabricksError::InvalidRefreshGrant) => (None, None),
            Err(error) => return RefreshStep::Completed(self.finish_refresh(&scope, &Err(error))),
        };
        let id = WriteId(self.next());
        self.state(&scope).pending = Some(PendingWrite {
            id,
            value: value.clone(),
            tokens,
            refresh: Some(refresh),
        });
        RefreshStep::Persist(StoreWrite {
            id,
            key: scope.store_key(),
            value,
        })
    }

    fn finish_refresh(
        &mut self,
        scope: &CredentialScope,
        result: &Result<Option<DatabricksTokens>, DatabricksError>,
    ) -> Vec<WaiterCompletion> {
        self.state(scope)
            .refresh
            .take()
            .map(|refresh| {
                refresh
                    .waiters
                    .into_iter()
                    .map(|waiter| WaiterCompletion {
                        waiter,
                        result: result.clone(),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Records a store write's outcome.
    pub fn write_finished(
        &mut self,
        write: WriteId,
        result: Result<(), SecureStoreError>,
    ) -> WriteOutcome {
        let result = result.map_err(DatabricksError::Storage);
        let Some((scope, pending)) = self.scopes.iter().find_map(|(scope, state)| {
            state
                .pending
                .as_ref()
                .filter(|pending| pending.id == write)
                .map(|pending| (scope.clone(), pending.clone()))
        }) else {
            // Superseded by a newer write (or already reported): nothing else depends on it.
            return WriteOutcome {
                result,
                completions: Vec::new(),
            };
        };
        if result.is_ok() {
            self.state(&scope).pending = None;
        }
        let completions = match pending.refresh {
            Some(refresh)
                if self
                    .state(&scope)
                    .refresh
                    .as_ref()
                    .is_some_and(|current| current.id == refresh) =>
            {
                // On failure the rotation stays pending in memory: the consumed grant is never
                // reused, and the next lookup retries persistence first.
                let answer = result.clone().map(|()| pending.tokens);
                self.finish_refresh(&scope, &answer)
            }
            _ => Vec::new(),
        };
        WriteOutcome {
            result,
            completions,
        }
    }

    /// Cancels one waiter. The refresh keeps running for the others (and is still persisted
    /// when no waiter remains). `None` when the waiter was already answered.
    pub fn cancel_waiter(&mut self, waiter: WaiterId) -> Option<WaiterCompletion> {
        self.scopes
            .values_mut()
            .filter_map(|state| state.refresh.as_mut())
            .any(|refresh| refresh.waiters.remove(&waiter))
            .then_some(WaiterCompletion {
                waiter,
                result: Err(DatabricksError::Cancelled),
            })
    }

    /// Starts an interactive sign-in for `scope`. A newer sign-in or a clear makes this one's
    /// commit fail.
    pub fn begin_sign_in(&mut self, scope: &CredentialScope) -> SignIn {
        let id = self.next();
        self.state(scope).sign_in = Some(id);
        SignIn {
            scope: scope.clone(),
            id,
        }
    }

    /// Ends a sign-in that will not commit (failed or cancelled).
    pub fn end_sign_in(&mut self, sign_in: &SignIn) {
        let state = self.state(&sign_in.scope);
        if state.sign_in == Some(sign_in.id) {
            state.sign_in = None;
        }
    }

    /// Commits a sign-in's tokens.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::Cancelled`] when a newer sign-in or a clear superseded `sign_in`;
    /// otherwise see [`TokenManager::save`].
    pub fn save_signed_in(
        &mut self,
        sign_in: &SignIn,
        tokens: &DatabricksTokens,
    ) -> Result<Mutation, DatabricksError> {
        if self.state(&sign_in.scope).sign_in != Some(sign_in.id) {
            return Err(DatabricksError::Cancelled);
        }
        self.save(&sign_in.scope, tokens)
    }

    /// Replaces the saved bundle for `scope`. Any in-flight refresh is invalidated, so its late
    /// result can never overwrite this bundle.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::InvalidCredentialData`] for invalid tokens, which are never persisted.
    pub fn save(
        &mut self,
        scope: &CredentialScope,
        tokens: &DatabricksTokens,
    ) -> Result<Mutation, DatabricksError> {
        let bytes = encode_record(tokens)?;
        Ok(self.mutate(scope, Some(bytes), Some(tokens.clone())))
    }

    /// Deletes the saved bundle for `scope`, invalidating any in-flight refresh and sign-in.
    pub fn clear(&mut self, scope: &CredentialScope) -> Mutation {
        self.mutate(scope, None, None)
    }

    fn mutate(
        &mut self,
        scope: &CredentialScope,
        value: Option<Vec<u8>>,
        tokens: Option<DatabricksTokens>,
    ) -> Mutation {
        let id = WriteId(self.next());
        let state = self.state(scope);
        state.sign_in = None;
        state.generation = state.generation.wrapping_add(1);
        let cancelled = state
            .refresh
            .take()
            .map(|refresh| {
                refresh
                    .waiters
                    .into_iter()
                    .map(|waiter| WaiterCompletion {
                        waiter,
                        result: Err(DatabricksError::Cancelled),
                    })
                    .collect()
            })
            .unwrap_or_default();
        state.pending = Some(PendingWrite {
            id,
            value: value.clone(),
            tokens,
            refresh: None,
        });
        Mutation {
            write: StoreWrite {
                id,
                key: scope.store_key(),
                value,
            },
            cancelled,
        }
    }

    /// Whether `candidate` is still the durable bundle for `scope`, given the host's fresh read
    /// of the store. Always false while a change is unpersisted.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::Storage`] when the read failed, or
    /// [`DatabricksError::InvalidCredentialData`] for a malformed record.
    pub fn is_current(
        &self,
        scope: &CredentialScope,
        stored: Result<Option<Vec<u8>>, SecureStoreError>,
        candidate: &DatabricksTokens,
    ) -> Result<bool, DatabricksError> {
        let stored = stored?;
        if self
            .scopes
            .get(scope)
            .is_some_and(|state| state.pending.is_some())
        {
            return Ok(false);
        }
        match stored {
            None => Ok(false),
            Some(bytes) => Ok(&decode_record(&bytes)? == candidate),
        }
    }

    /// The write a lookup must flush first, if any.
    fn pending_write(&self, scope: &CredentialScope) -> Option<StoreWrite> {
        let pending = self.scopes.get(scope)?.pending.as_ref()?;
        Some(StoreWrite {
            id: pending.id,
            key: scope.store_key(),
            value: pending.value.clone(),
        })
    }
}

/// A debug-build fault for manual recovery testing against a real workspace.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CredentialFault {
    /// Replace the access token and expire it: expect a silent refresh.
    ClearedAccessToken,
    /// Replace the access token but keep it unexpired: expect one server rejection, then one
    /// refresh and retry.
    RejectedAccessToken,
    /// Replace both tokens and expire them: expect a sign-in prompt, not a silent retry.
    ClearedRefreshToken,
}

/// The value fault injection writes in place of a real token.
pub const DEBUG_CLEARED_TOKEN: &str = "debug-cleared-by-tester";

impl CredentialFault {
    /// `saved` with only this fault's fields changed. Save the result with
    /// [`TokenManager::save`].
    #[must_use]
    pub fn apply(self, saved: &DatabricksTokens, now_ms: u64) -> DatabricksTokens {
        let cleared = SecretString::new(DEBUG_CLEARED_TOKEN);
        match self {
            Self::ClearedAccessToken => DatabricksTokens {
                access_token: cleared,
                expires_at_ms: 0,
                ..saved.clone()
            },
            Self::RejectedAccessToken => DatabricksTokens {
                access_token: cleared,
                expires_at_ms: saved.expires_at_ms.max(now_ms.saturating_add(600_000)),
                ..saved.clone()
            },
            Self::ClearedRefreshToken => DatabricksTokens {
                access_token: cleared.clone(),
                refresh_token: cleared,
                expires_at_ms: 0,
                ..saved.clone()
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::databricks::test_support::{
        ACCOUNT_ISSUER, TokenHarness, scope, scope_for_client, tokens,
    };
    use crate::auth::databricks::tokens::APPLE_REFERENCE_DATE_UNIX_MS;

    const NOW: u64 = 1_000_000;

    fn issuer(raw: &str) -> OAuthIssuer {
        OAuthIssuer::parse(raw).unwrap()
    }

    fn default_scope() -> CredentialScope {
        scope("https://dbc-123.cloud.databricks.com")
    }

    /// `DatabricksTokenManagerTests::testMissingAndUsableCredentialsNeverRefresh`.
    #[test]
    fn token_manager_missing_and_usable_never_refresh() {
        let mut harness = TokenHarness::new(NOW);
        let scope = default_scope();
        assert_eq!(harness.tokens(&scope), Ok(None));
        let valid = tokens("test-access", "test-refresh", 3_000_000, None);
        harness.save(&scope, &valid).unwrap();
        let mut restored = harness.with_new_manager();
        assert_eq!(restored.tokens(&scope), Ok(Some(valid)));
        assert_eq!(restored.refreshes, Vec::new());
    }

    /// `DatabricksTokenManagerTests::testRefreshesAtSafetyBoundaryAndPersistsRotationBeforeReturning`.
    #[test]
    fn token_manager_refresh_at_margin_persists_before_return() {
        let mut harness = TokenHarness::new(NOW);
        let scope = default_scope();
        harness.put(
            &scope,
            &tokens("test-access", "test-refresh", NOW + 60_000, None),
        );
        let rotated = tokens("next-access", "next-refresh", 3_000_000, None);
        harness.auto_refresh = Some(Ok(rotated.clone()));
        assert_eq!(harness.tokens(&scope), Ok(Some(rotated.clone())));
        assert_eq!(harness.stored(&scope), Some(rotated));
        assert_eq!(harness.refreshes.len(), 1);
        assert_eq!(harness.refreshes[0].refresh_token.expose(), "test-refresh");
        assert_eq!(harness.refreshes[0].scope, scope);
        // One millisecond more life than the margin is still usable.
        let mut harness = TokenHarness::new(NOW);
        let fresh = tokens("a", "r", NOW + 60_001, None);
        harness.put(&scope, &fresh);
        assert_eq!(harness.tokens(&scope), Ok(Some(fresh.clone())));
        assert_eq!(refresh_due_in_ms(&fresh, NOW), 1);
        assert_eq!(refresh_due_in_ms(&fresh, NOW + 5), 0);
    }

    /// `DatabricksTokenManagerTests::testConcurrentWaitersShareRefreshAndOneCancellationDoesNotCancelOthers`.
    #[test]
    fn token_manager_waiters_share_refresh_and_survive_cancel() {
        let mut harness = TokenHarness::new(NOW);
        let scope = default_scope();
        harness.put(&scope, &tokens("a", "test-refresh", 900_000, None));
        let first = harness.begin(&scope);
        let second = harness.begin(&scope);
        assert_eq!(harness.refreshes.len(), 1, "one shared refresh");
        assert_eq!(
            harness.manager.cancel_waiter(first).map(|c| c.result),
            Some(Err(DatabricksError::Cancelled))
        );
        let rotated = tokens("next", "rotated", NOW + 3_600_000, None);
        harness.finish_refresh(0, Ok(rotated.clone()));
        assert_eq!(harness.result(second), Some(Ok(Some(rotated.clone()))));
        assert_eq!(
            harness.result(first),
            None,
            "cancelled waiter gets no late answer"
        );
        assert_eq!(harness.stored(&scope), Some(rotated));
        assert_eq!(harness.refreshes.len(), 1);
    }

    /// `DatabricksTokenManagerTests::testRefreshStillPersistsAfterAllOriginalWaitersCancel`.
    #[test]
    fn token_manager_refresh_persists_after_all_waiters_cancel() {
        let mut harness = TokenHarness::new(NOW);
        let scope = default_scope();
        harness.put(&scope, &tokens("a", "test-refresh", 900_000, None));
        let waiter = harness.begin(&scope);
        assert!(harness.manager.cancel_waiter(waiter).is_some());
        let rotated = tokens("test-access", "rotated-refresh", 3_000_000, None);
        harness.finish_refresh(0, Ok(rotated.clone()));
        assert_eq!(harness.stored(&scope), Some(rotated.clone()));
        assert_eq!(harness.tokens(&scope), Ok(Some(rotated)));
        assert_eq!(harness.refreshes.len(), 1);
    }

    /// `DatabricksTokenManagerTests::testDifferentWorkspacesDoNotShareRefreshOperations`.
    #[test]
    fn token_manager_scopes_do_not_share_refresh() {
        let mut harness = TokenHarness::new(NOW);
        let first_scope = default_scope();
        let second_scope = scope("https://adb-123.azuredatabricks.net");
        harness.put(&first_scope, &tokens("a", "first", 900_000, None));
        harness.put(&second_scope, &tokens("a", "second", 900_000, None));
        let first = harness.begin(&first_scope);
        let second = harness.begin(&second_scope);
        assert_eq!(harness.refreshes.len(), 2);
        for index in 0..2 {
            let call = harness.refreshes[index].clone();
            let expected = if call.scope == first_scope {
                "first"
            } else {
                "second"
            };
            assert_eq!(call.refresh_token.expose(), expected);
            let token = call.refresh_token.expose().to_owned();
            harness.finish_refresh(
                index,
                Ok(tokens(&token, &format!("rotated-{token}"), 3_000_000, None)),
            );
        }
        let access = |result: Option<Result<Option<DatabricksTokens>, DatabricksError>>| {
            result
                .unwrap()
                .unwrap()
                .unwrap()
                .access_token
                .expose()
                .to_owned()
        };
        assert_eq!(access(harness.result(first)), "first");
        assert_eq!(access(harness.result(second)), "second");
    }

    /// `DatabricksTokenManagerTests::testInvalidGrantClearsOnlyMatchingScopeAndRequiresReauthentication`.
    #[test]
    fn token_manager_invalid_grant_clears_only_matching_scope() {
        let mut harness = TokenHarness::new(NOW);
        let scope = default_scope();
        let other = scope_for_client("https://dbc-123.cloud.databricks.com", "other-client");
        let saved = tokens("a", "r", 900_000, None);
        harness.put(&scope, &saved);
        harness.put(&other, &saved);
        harness.auto_refresh = Some(Err(DatabricksError::InvalidRefreshGrant));
        assert_eq!(harness.tokens(&scope), Ok(None));
        assert_eq!(harness.stored(&scope), None);
        assert_eq!(harness.stored(&other), Some(saved));
    }

    /// `DatabricksTokenManagerTests::testTransientErrorsAndMalformedResponsesRetainCredentials`.
    #[test]
    fn token_manager_transient_errors_retain_credentials() {
        for error in [
            DatabricksError::NetworkUnavailable(crate::http::TransportError::Offline {
                message: "offline".into(),
            }),
            DatabricksError::TokenExchangeFailed { status: 503 },
            DatabricksError::InvalidTokenResponse,
        ] {
            let mut harness = TokenHarness::new(NOW);
            let scope = default_scope();
            let saved = tokens("a", "r", 900_000, None);
            harness.put(&scope, &saved);
            harness.auto_refresh = Some(Err(error.clone()));
            assert_eq!(harness.tokens(&scope), Err(error));
            assert_eq!(harness.stored(&scope), Some(saved));
        }
    }

    /// `DatabricksTokenManagerTests::testLockedKeychainDoesNotBecomeMissingCredentials`.
    #[test]
    fn token_manager_store_error_is_not_missing() {
        let mut harness = TokenHarness::new(NOW);
        harness.store.fail_get.set(true);
        assert!(matches!(
            harness.tokens(&default_scope()),
            Err(DatabricksError::Storage(_))
        ));
        assert_eq!(harness.refreshes, Vec::new());
        // A malformed record is an error too, and is left in place.
        let mut harness = TokenHarness::new(NOW);
        let scope = default_scope();
        harness.store.insert(&scope.store_key(), b"not-json");
        assert_eq!(
            harness.tokens(&scope),
            Err(DatabricksError::InvalidCredentialData)
        );
        assert_eq!(
            harness.store.value(&scope.store_key()),
            Some(b"not-json".to_vec())
        );
    }

    /// `DatabricksTokenManagerTests::testFailedRotationWriteRetriesPersistenceWithoutReusingOldGrant`.
    #[test]
    fn token_manager_failed_rotation_write_retries_without_reuse() {
        let mut harness = TokenHarness::new(NOW);
        let scope = default_scope();
        let saved = tokens("a", "r", 900_000, Some(issuer(ACCOUNT_ISSUER)));
        harness.put(&scope, &saved);
        harness.store.fail_set.set(true);
        let rotated = tokens(
            "rotated-access",
            "rotated-refresh",
            3_000_000,
            Some(issuer(ACCOUNT_ISSUER)),
        );
        harness.auto_refresh = Some(Ok(rotated.clone()));
        assert!(matches!(
            harness.tokens(&scope),
            Err(DatabricksError::Storage(_))
        ));
        assert_eq!(harness.stored(&scope), Some(saved));
        harness.store.fail_set.set(false);
        assert_eq!(harness.tokens(&scope), Ok(Some(rotated.clone())));
        assert_eq!(harness.stored(&scope), Some(rotated));
        assert_eq!(
            harness.refreshes.len(),
            1,
            "the consumed grant is never reused"
        );
        assert_eq!(harness.refreshes[0].issuer, Some(issuer(ACCOUNT_ISSUER)));
    }

    /// `DatabricksTokenManagerTests::testRejectsRefreshThatDropsIssuerContext`.
    #[test]
    fn token_manager_rejects_refresh_dropping_issuer() {
        let mut harness = TokenHarness::new(NOW);
        let scope = default_scope();
        let saved = tokens(
            "a",
            "r",
            900_000,
            Some(issuer("https://workspace.cloud.databricks.com/oidc")),
        );
        harness.put(&scope, &saved);
        harness.auto_refresh = Some(Ok(tokens("test-access", "test-refresh", 3_000_000, None)));
        assert_eq!(
            harness.tokens(&scope),
            Err(DatabricksError::InvalidTokenResponse)
        );
        assert_eq!(harness.stored(&scope), Some(saved));
    }

    /// `DatabricksTokenManagerTests::testSameOriginWorkspaceContextsKeepTheirOwnTokens`.
    #[test]
    fn token_manager_same_origin_workspaces_keep_own_tokens() {
        let mut harness = TokenHarness::new(NOW);
        let first = scope("https://workspace.databricks.com/omnigent?o=123");
        let second = scope("https://workspace.databricks.com/omnigent?o=456");
        let first_tokens = tokens("first", "r", 3_000_000, None);
        let second_tokens = tokens("second", "r", 3_000_000, None);
        harness.save(&first, &first_tokens).unwrap();
        harness.save(&second, &second_tokens).unwrap();
        assert_eq!(harness.tokens(&first), Ok(Some(first_tokens)));
        assert_eq!(harness.tokens(&second), Ok(Some(second_tokens.clone())));
        harness.clear(&first).unwrap();
        assert_eq!(harness.stored(&first), None);
        assert_eq!(harness.stored(&second), Some(second_tokens));
    }

    /// `DatabricksTokenManagerTests::testFailedClearDoesNotAllowOldCredentialsToReappear`.
    #[test]
    fn token_manager_failed_clear_does_not_resurrect() {
        let mut harness = TokenHarness::new(NOW);
        let scope = default_scope();
        harness.put(&scope, &tokens("a", "r", 3_000_000, None));
        harness.store.fail_delete.set(true);
        assert!(matches!(
            harness.clear(&scope),
            Err(DatabricksError::Storage(_))
        ));
        harness.store.fail_delete.set(false);
        assert_eq!(harness.tokens(&scope), Ok(None));
        assert_eq!(harness.stored(&scope), None);
        assert_eq!(harness.refreshes, Vec::new());
    }

    /// `DatabricksTokenManagerTests::testClearAndNewLoginRejectLateRefreshResults`.
    #[test]
    fn token_manager_late_refresh_rejected_after_clear_or_login() {
        let old_issuer = Some(issuer(
            "https://accounts.cloud.databricks.com/oidc/accounts/old-account",
        ));
        let new_issuer = Some(issuer(
            "https://accounts.cloud.databricks.com/oidc/accounts/new-account",
        ));
        for replace_with_login in [false, true] {
            for remote in [
                Ok(tokens("old-result", "r", 3_000_000, old_issuer.clone())),
                Err(DatabricksError::InvalidRefreshGrant),
            ] {
                let mut harness = TokenHarness::new(NOW);
                let scope = default_scope();
                harness.put(&scope, &tokens("a", "r", 900_000, old_issuer.clone()));
                let waiter = harness.begin(&scope);
                let newer = tokens(
                    "new-login",
                    "new-login-refresh",
                    3_000_000,
                    new_issuer.clone(),
                );
                if replace_with_login {
                    let sign_in = harness.manager.begin_sign_in(&scope);
                    harness.save_signed_in(&sign_in, &newer).unwrap();
                } else {
                    harness.clear(&scope).unwrap();
                }
                assert_eq!(
                    harness.result(waiter),
                    Some(Err(DatabricksError::Cancelled))
                );
                harness.finish_refresh(0, remote);
                let expected = replace_with_login.then(|| newer.clone());
                assert_eq!(harness.tokens(&scope), Ok(expected.clone()));
                assert_eq!(harness.stored(&scope), expected);
            }
        }
    }

    /// `DatabricksTokenManagerTests::testRejectedUnexpiredAccessTokenCanBeRefreshedOnce`.
    #[test]
    fn token_manager_rejected_unexpired_refreshes_once() {
        let mut harness = TokenHarness::new(NOW);
        let scope = default_scope();
        let original = tokens("test-access", "test-refresh", 3_000_000, None);
        let rotated = tokens("rotated", "rotated-refresh", 3_000_000, None);
        harness.put(&scope, &original);
        harness.auto_refresh = Some(Ok(rotated.clone()));
        assert_eq!(
            harness.refresh_rejected(&scope, &original),
            Ok(Some(rotated.clone()))
        );
        assert_eq!(harness.stored(&scope), Some(rotated));
        assert_eq!(harness.refreshes.len(), 1);
    }

    /// `DatabricksTokenManagerTests::testRejectedTokenCannotRefreshANewerLogin`.
    #[test]
    fn token_manager_rejected_stale_token_cannot_refresh_newer() {
        let mut harness = TokenHarness::new(NOW);
        let scope = default_scope();
        let current = tokens("new-login", "test-refresh", 3_000_000, None);
        harness.put(&scope, &current);
        assert_eq!(
            harness.refresh_rejected(
                &scope,
                &tokens("test-access", "test-refresh", 3_000_000, None)
            ),
            Err(DatabricksError::CredentialsChanged)
        );
        assert_eq!(harness.refreshes, Vec::new());
        assert_eq!(harness.stored(&scope), Some(current));
    }

    #[test]
    fn load_racing_a_save_replans() {
        let mut manager = TokenManager::new();
        let scope = default_scope();
        let LookupStep::Load(ticket) = manager.lookup(&scope, LookupMode::Cached) else {
            panic!("expected a load");
        };
        let newer = tokens("newer", "r", 3_000_000, None);
        let mutation = manager.save(&scope, &newer).unwrap();
        // The stale read must not be served; the pending save is flushed first.
        let step = manager.loaded(ticket, Ok(None), NOW).unwrap();
        assert_eq!(step, LookupStep::Write(mutation.write.clone()));
        let debug = format!("{:?}", mutation.write);
        assert!(!debug.contains("newer"), "{debug}");
    }

    #[test]
    fn debug_faults_change_only_their_fields() {
        let saved = tokens(
            "test-access",
            "test-refresh",
            3_000_000,
            Some(issuer(ACCOUNT_ISSUER)),
        );
        let cleared = CredentialFault::ClearedAccessToken.apply(&saved, NOW);
        assert_eq!(cleared.refresh_token, saved.refresh_token);
        assert_eq!(cleared.issuer, saved.issuer);
        assert!(!is_usable(&cleared, NOW));
        let rejected = CredentialFault::RejectedAccessToken.apply(&saved, NOW);
        assert_ne!(rejected.access_token, saved.access_token);
        assert_eq!(rejected.refresh_token, saved.refresh_token);
        assert!(is_usable(&rejected, NOW));
        let refresh = CredentialFault::ClearedRefreshToken.apply(&saved, NOW);
        assert_ne!(refresh.refresh_token, saved.refresh_token);
        assert!(!is_usable(&refresh, NOW));
        // Fault records still encode (Swift stored `distantPast`, which decodes as expired).
        let decoded = decode_record(&encode_record(&refresh).unwrap()).unwrap();
        assert_eq!(decoded, refresh);
        // Foundation's reference date is after the Unix epoch, so `expiresAt` 0 is negative.
        assert_eq!(APPLE_REFERENCE_DATE_UNIX_MS, 978_307_200_000);
    }
}
