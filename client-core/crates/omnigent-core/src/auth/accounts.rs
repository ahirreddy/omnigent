//! Accounts-mode bearer sign-in and the saved bearer credential.
//!
//! `POST /auth/login` with `{"username", "password"}` answers `{token, expires_in, user: {id}}`
//! (`omnigent/server/routes/accounts_auth.py`). With `"issue_refresh": true` and a grant store on
//! the server, it also returns a `refresh_token` that renews through `POST /oauth/token`, the
//! same endpoint OIDC grants use.
//!
//! The credential is persisted only through the host [`SecureStore`]; the account list itself
//! (server URL and user id, no secret) is host preferences.

use serde_json::{Map, Value, json};

use super::endpoint::{ServerEndpoint, ServerIdentityScope, validate_bearer};
use super::errors::HostedAuthError;
use super::mode::{
    AuthenticationMode, check_json_response, discovery_from_info_response, info_request,
};
use super::{SecretString, SecureStore, SecureStoreKey};
use crate::http::{HttpHeader, HttpRequest, HttpTransport};

/// A bearer credential for one account on one server. `Debug` is redacted.
#[derive(Clone, PartialEq, Eq)]
pub struct AccountCredential {
    /// The bearer token.
    pub token: SecretString,
    /// The server's user id.
    pub user_id: String,
    /// When the token stops working, in ms since the Unix epoch.
    pub expires_at_ms: u64,
    /// A refresh grant, when the server issued one.
    pub refresh_token: Option<SecretString>,
}

impl std::fmt::Debug for AccountCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("AccountCredential(redacted)")
    }
}

/// Options for [`login`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AccountLoginOptions {
    /// Ask the server for a refresh grant (`issue_refresh`), as unattended clients do.
    pub issue_refresh: bool,
}

/// Discovers the server's mode and, only for accounts mode, signs in with a password.
///
/// No secret is sent unless discovery says accounts mode: Databricks-org endpoints fail before
/// any request, and other modes (the single-user runtime included) fail after the
/// unauthenticated discovery. A loopback root is not refused by itself: an accounts server on
/// `127.0.0.1` signs in like any other.
///
/// # Errors
///
/// [`HostedAuthError::UnsupportedAuthentication`] outside accounts mode, the discovery and
/// response errors of [`check_json_response`], [`HostedAuthError::MalformedResponse`] for a body
/// without a usable token, user id and expiry, and [`HostedAuthError::Transport`].
#[allow(
    clippy::future_not_send,
    reason = "Send-ness follows the host transport; WASM transports are !Send by design"
)]
pub async fn login<T: HttpTransport>(
    transport: &T,
    endpoint: &ServerEndpoint,
    username: &str,
    password: &SecretString,
    options: AccountLoginOptions,
    now_ms: u64,
) -> Result<AccountCredential, HostedAuthError> {
    if endpoint.databricks_org_id().is_some() {
        return Err(HostedAuthError::UnsupportedAuthentication);
    }
    let info = info_request(endpoint)?;
    let response = transport.send(info).await?;
    let discovery = discovery_from_info_response(endpoint, None, &response)?;
    if discovery.mode != AuthenticationMode::Accounts {
        return Err(HostedAuthError::UnsupportedAuthentication);
    }
    let request = login_request(endpoint, username, password, options)?;
    let response = transport.send(request).await?;
    check_json_response(&response, false)?;
    credential_from_login(&response.body, now_ms)
}

/// `POST /auth/login` with the JSON credentials.
///
/// # Errors
///
/// See [`ServerEndpoint::request_with`].
pub fn login_request(
    endpoint: &ServerEndpoint,
    username: &str,
    password: &SecretString,
    options: AccountLoginOptions,
) -> Result<HttpRequest, HostedAuthError> {
    let mut request =
        endpoint.request_with("POST", "/auth/login", &[], "application/json", None)?;
    request
        .headers
        .push(HttpHeader::new("Content-Type", "application/json"));
    let mut body = json!({"username": username, "password": password.expose()});
    if options.issue_refresh
        && let Some(object) = body.as_object_mut()
    {
        object.insert("issue_refresh".into(), Value::Bool(true));
    }
    request.body = Some(body.to_string().into_bytes());
    Ok(request)
}

/// Decodes the login (or ticket poll) body into a credential. `user_id` is read from `user.id`
/// or, for the ticket poll, `user_id`.
///
/// # Errors
///
/// [`HostedAuthError::MalformedResponse`] for a missing field, a blank user id or a
/// non-positive expiry; [`HostedAuthError::Unauthorized`] for a token that is not a valid bearer.
pub fn credential_from_login(
    body: &[u8],
    now_ms: u64,
) -> Result<AccountCredential, HostedAuthError> {
    let value: Value = serde_json::from_slice(body).map_err(|error| malformed(&error))?;
    let token = value
        .get("token")
        .and_then(Value::as_str)
        .ok_or_else(|| malformed(&"login response has no token"))?;
    validate_bearer(token)?;
    let user_id = value
        .get("user")
        .and_then(|user| user.get("id"))
        .or_else(|| value.get("user_id"))
        .and_then(Value::as_str)
        .filter(|id| !id.trim().is_empty())
        .ok_or_else(|| malformed(&"login response has no user id"))?;
    let expires_at_ms = expiry_ms(value.get("expires_in"), now_ms)
        .ok_or_else(|| malformed(&"login response has no positive expires_in"))?;
    let refresh_token = value
        .get("refresh_token")
        .and_then(Value::as_str)
        .filter(|token| !token.is_empty())
        .map(SecretString::new);
    Ok(AccountCredential {
        token: SecretString::new(token),
        user_id: user_id.to_owned(),
        expires_at_ms,
        refresh_token,
    })
}

/// `now_ms + expires_in` seconds for a finite, positive JSON number (booleans excluded).
pub(crate) fn expiry_ms(value: Option<&Value>, now_ms: u64) -> Option<u64> {
    let seconds = value?.as_f64().filter(|s| s.is_finite() && *s > 0.0)?;
    Some(now_ms.saturating_add(seconds_to_ms(seconds)))
}

/// Whole milliseconds in `seconds` (finite and non-negative), saturating at `u64::MAX`.
#[allow(
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "float-to-int `as` saturates, which is the wanted behaviour for huge lifetimes"
)]
pub(crate) fn seconds_to_ms(seconds: f64) -> u64 {
    (seconds * 1000.0).floor() as u64
}

fn malformed(detail: &impl ToString) -> HostedAuthError {
    HostedAuthError::MalformedResponse {
        detail: detail.to_string(),
    }
}

/// Current version of the saved credential record.
pub const ACCOUNT_RECORD_VERSION: u64 = 1;

/// The secure-store key for `scope`.
#[must_use]
pub fn store_key(scope: &ServerIdentityScope) -> SecureStoreKey {
    SecureStoreKey::new(SecureStoreKey::ACCOUNTS_NAMESPACE, scope.account_id())
}

impl AccountCredential {
    /// The versioned record bytes:
    /// `{"version":1,"token","userID","expiresAtMs","refreshToken"?}`.
    #[must_use]
    pub fn to_record(&self) -> Vec<u8> {
        let mut record = Map::new();
        record.insert("version".into(), json!(ACCOUNT_RECORD_VERSION));
        record.insert("token".into(), json!(self.token.expose()));
        record.insert("userID".into(), json!(self.user_id));
        record.insert("expiresAtMs".into(), json!(self.expires_at_ms));
        if let Some(refresh) = &self.refresh_token {
            record.insert("refreshToken".into(), json!(refresh.expose()));
        }
        Value::Object(record).to_string().into_bytes()
    }

    /// Decodes [`AccountCredential::to_record`] output.
    ///
    /// # Errors
    ///
    /// [`HostedAuthError::InvalidCredentialRecord`] for anything else, including another version
    /// or an invalid token.
    pub fn from_record(bytes: &[u8]) -> Result<Self, HostedAuthError> {
        let invalid = || HostedAuthError::InvalidCredentialRecord;
        let value: Value = serde_json::from_slice(bytes).map_err(|_| invalid())?;
        if value.get("version").and_then(Value::as_u64) != Some(ACCOUNT_RECORD_VERSION) {
            return Err(invalid());
        }
        let token = value
            .get("token")
            .and_then(Value::as_str)
            .ok_or_else(invalid)?;
        validate_bearer(token).map_err(|_| invalid())?;
        let user_id = value
            .get("userID")
            .and_then(Value::as_str)
            .filter(|id| !id.trim().is_empty())
            .ok_or_else(invalid)?;
        let expires_at_ms = value
            .get("expiresAtMs")
            .and_then(Value::as_u64)
            .ok_or_else(invalid)?;
        let refresh_token = match value.get("refreshToken") {
            None | Some(Value::Null) => None,
            Some(Value::String(token)) if !token.is_empty() => {
                Some(SecretString::new(token.clone()))
            }
            Some(_) => return Err(invalid()),
        };
        Ok(Self {
            token: SecretString::new(token),
            user_id: user_id.to_owned(),
            expires_at_ms,
            refresh_token,
        })
    }
}

/// Saves `credential` for its account on `endpoint`, after checking it belongs there.
///
/// # Errors
///
/// [`HostedAuthError::InvalidCredentialRecord`] for a blank user id or an already-expired
/// credential; [`HostedAuthError::Unauthorized`] for an invalid token
/// (nothing is written); [`HostedAuthError::Store`] when the host store fails.
#[allow(
    clippy::future_not_send,
    reason = "Send-ness follows the host store; WASM stores are !Send by design"
)]
pub async fn save_credential<S: SecureStore>(
    store: &S,
    endpoint: &ServerEndpoint,
    credential: &AccountCredential,
    now_ms: u64,
) -> Result<ServerIdentityScope, HostedAuthError> {
    if credential.user_id.trim().is_empty() || credential.expires_at_ms <= now_ms {
        return Err(HostedAuthError::InvalidCredentialRecord);
    }
    validate_bearer(credential.token.expose())?;
    let scope = endpoint.identity_scope(&credential.user_id);
    store.set(store_key(&scope), credential.to_record()).await?;
    Ok(scope)
}

/// Loads the credential saved for `scope`; `Ok(None)` when none is saved.
///
/// # Errors
///
/// [`HostedAuthError::Store`], [`HostedAuthError::InvalidCredentialRecord`] for an unreadable
/// record or one saved for another account, and [`HostedAuthError::CredentialExpired`] once it
/// is past its expiry.
#[allow(
    clippy::future_not_send,
    reason = "Send-ness follows the host store; WASM stores are !Send by design"
)]
pub async fn load_credential<S: SecureStore>(
    store: &S,
    scope: &ServerIdentityScope,
    now_ms: u64,
) -> Result<Option<AccountCredential>, HostedAuthError> {
    let Some(bytes) = store.get(store_key(scope)).await? else {
        return Ok(None);
    };
    let credential = AccountCredential::from_record(&bytes)?;
    if credential.user_id != scope.user_id {
        return Err(HostedAuthError::InvalidCredentialRecord);
    }
    if credential.expires_at_ms <= now_ms {
        return Err(HostedAuthError::CredentialExpired);
    }
    Ok(Some(credential))
}

/// Deletes the credential saved for `scope` (absent is fine).
///
/// # Errors
///
/// [`HostedAuthError::Store`].
#[allow(
    clippy::future_not_send,
    reason = "Send-ness follows the host store; WASM stores are !Send by design"
)]
pub async fn remove_credential<S: SecureStore>(
    store: &S,
    scope: &ServerIdentityScope,
) -> Result<(), HostedAuthError> {
    store.delete(store_key(scope)).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use futures::executor::block_on;

    use super::*;
    use crate::auth::testing::{MemoryStore, ScriptedTransport, body_text, header};

    const MOUNT: &str = "/api/2.0/omnigent";
    const TOKEN: &str = "fixture-token-not-a-real-credential";
    const NOW: u64 = 1_700_000_000_000;

    fn endpoint() -> ServerEndpoint {
        ServerEndpoint::new(&format!("https://127.0.0.1:8443{MOUNT}")).unwrap()
    }

    #[test]
    fn an_expired_or_nameless_credential_is_never_saved() {
        let store = MemoryStore::default();
        let endpoint = ServerEndpoint::new("https://omni.example/api/a").unwrap();
        for invalid in [
            credential("fixture-token", "alice", NOW),
            credential("fixture-token", "  ", NOW + 1),
        ] {
            assert_eq!(
                block_on(save_credential(&store, &endpoint, &invalid, NOW)),
                Err(HostedAuthError::InvalidCredentialRecord)
            );
        }
        assert_eq!(store.items.borrow().len(), 0);
    }

    #[test]
    fn account_login_uses_actual_contract_and_does_not_carry_ambient_credentials() {
        let transport = ScriptedTransport::new();
        transport
            .json(
                200,
                r#"{"single_user":false,"accounts_enabled":true,"login_url":"/login"}"#,
            )
            .json(
                200,
                &format!(r#"{{"token":"{TOKEN}","expires_in":3600,"user":{{"id":"alice"}}}}"#),
            );
        let credential = block_on(login(
            &transport,
            &endpoint(),
            "alice",
            &SecretString::new("synthetic-password"),
            AccountLoginOptions::default(),
            NOW,
        ))
        .unwrap();
        assert_eq!(credential.user_id, "alice");
        assert_eq!(credential.token.expose(), TOKEN);
        assert_eq!(credential.expires_at_ms, NOW + 3_600_000);
        assert_eq!(credential.refresh_token, None);
        let requests = transport.take();
        assert_eq!(requests.len(), 2);
        let login = &requests[1];
        assert_eq!(login.method, "POST");
        assert_eq!(
            login.url,
            format!("https://127.0.0.1:8443{MOUNT}/auth/login")
        );
        assert_eq!(header(login, "Content-Type"), Some("application/json"));
        let body: Value = serde_json::from_str(&body_text(login)).unwrap();
        assert_eq!(
            body,
            json!({"username": "alice", "password": "synthetic-password"})
        );
        for request in &requests {
            assert_eq!(header(request, "Authorization"), None);
            assert_eq!(header(request, "Cookie"), None);
        }
        let debug = format!("{credential:?}");
        assert!(!debug.contains(TOKEN), "{debug}");
        assert_eq!(debug, "AccountCredential(redacted)");
    }

    #[test]
    fn issue_refresh_requests_and_keeps_a_grant() {
        let transport = ScriptedTransport::new();
        transport
            .json(200, r#"{"single_user":false,"accounts_enabled":true}"#)
            .json(
                200,
                &format!(
                    r#"{{"token":"{TOKEN}","expires_in":60,"user":{{"id":"alice"}},"refresh_token":"r1"}}"#
                ),
            );
        let credential = block_on(login(
            &transport,
            &endpoint(),
            "alice",
            &SecretString::new("pw"),
            AccountLoginOptions {
                issue_refresh: true,
            },
            NOW,
        ))
        .unwrap();
        assert_eq!(credential.refresh_token, Some(SecretString::new("r1")));
        let body: Value = serde_json::from_str(&body_text(&transport.take()[1])).unwrap();
        assert_eq!(body["issue_refresh"], json!(true));
    }

    #[test]
    fn wrong_password_is_unauthorized_with_reason() {
        let transport = ScriptedTransport::new();
        transport
            .json(200, r#"{"single_user":false,"accounts_enabled":true}"#)
            .json(401, r#"{"error":"invalid username or password"}"#);
        let error = block_on(login(
            &transport,
            &endpoint(),
            "alice",
            &SecretString::new("bad"),
            AccountLoginOptions::default(),
            NOW,
        ))
        .unwrap_err();
        assert_eq!(
            error,
            HostedAuthError::Unauthorized {
                reason: Some("invalid username or password".into())
            }
        );
    }

    #[test]
    fn malformed_login_bodies_are_rejected() {
        for body in [
            r#"{"expires_in":3600,"user":{"id":"alice"}}"#,
            r#"{"token":"t","expires_in":3600,"user":{"id":" "}}"#,
            r#"{"token":"t","expires_in":0,"user":{"id":"alice"}}"#,
            r#"{"token":"t","expires_in":true,"user":{"id":"alice"}}"#,
        ] {
            assert!(
                matches!(
                    credential_from_login(body.as_bytes(), NOW),
                    Err(HostedAuthError::MalformedResponse { .. })
                ),
                "{body}"
            );
        }
        assert_eq!(
            credential_from_login(
                br#"{"token":"a b","expires_in":1,"user":{"id":"alice"}}"#,
                NOW
            ),
            Err(HostedAuthError::Unauthorized { reason: None })
        );
    }

    #[test]
    fn preferences_contain_only_account_metadata() {
        let endpoint = ServerEndpoint::new("https://omni.example/api/team-a").unwrap();
        let scope = endpoint.identity_scope("alice");
        assert_eq!(scope.account_id(), "https://omni.example/api/team-a\nalice");
        let store = MemoryStore::default();
        let invalid = AccountCredential {
            token: SecretString::new("invalid\r\ntoken"),
            user_id: "alice".into(),
            expires_at_ms: NOW + 1,
            refresh_token: None,
        };
        assert_eq!(
            block_on(save_credential(&store, &endpoint, &invalid, NOW)),
            Err(HostedAuthError::Unauthorized { reason: None })
        );
        assert_eq!(store.items.borrow().len(), 0);
        assert_eq!(store.log.borrow().len(), 0, "refused before persisting");
    }

    fn credential(token: &str, user: &str, expires_at_ms: u64) -> AccountCredential {
        AccountCredential {
            token: SecretString::new(token),
            user_id: user.into(),
            expires_at_ms,
            refresh_token: None,
        }
    }

    #[test]
    fn keychain_separates_accounts_and_mounts_and_deletes_only_selected_credential() {
        let store = MemoryStore::default();
        let mount_a = ServerEndpoint::new("https://omni.example/api/a").unwrap();
        let mount_b = ServerEndpoint::new("https://omni.example/api/b").unwrap();
        let expiry = NOW + 60_000;
        let first = block_on(save_credential(
            &store,
            &mount_a,
            &credential("fixture-first", "alice", expiry),
            NOW,
        ))
        .unwrap();
        let second = block_on(save_credential(
            &store,
            &mount_a,
            &credential("fixture-second", "bob", u64::MAX),
            NOW,
        ))
        .unwrap();
        let third = block_on(save_credential(
            &store,
            &mount_b,
            &credential("fixture-third", "alice", u64::MAX),
            NOW,
        ))
        .unwrap();
        let load = |scope| block_on(load_credential(&store, scope, NOW));
        assert_eq!(
            load(&first).unwrap().unwrap().token.expose(),
            "fixture-first"
        );
        assert_eq!(
            load(&second).unwrap().unwrap().token.expose(),
            "fixture-second"
        );
        assert_eq!(
            load(&third).unwrap().unwrap().token.expose(),
            "fixture-third"
        );
        assert_eq!(
            block_on(load_credential(&store, &first, expiry + 1)),
            Err(HostedAuthError::CredentialExpired)
        );
        block_on(save_credential(
            &store,
            &mount_a,
            &credential("fixture-updated", "bob", u64::MAX),
            NOW,
        ))
        .unwrap();
        assert_eq!(store.items.borrow().len(), 3);
        assert_eq!(
            load(&second).unwrap().unwrap().token.expose(),
            "fixture-updated"
        );
        block_on(remove_credential(&store, &first)).unwrap();
        assert_eq!(load(&first), Ok(None));
        assert_eq!(
            load(&second).unwrap().unwrap().token.expose(),
            "fixture-updated"
        );
        assert_eq!(store.items.borrow().len(), 2);
    }

    #[test]
    fn keychain_separates_databricks_workspaces_for_the_same_account() {
        let store = MemoryStore::default();
        let first =
            ServerEndpoint::new("https://example.cloud.databricks.com/api/2.0/omnigent?o=123")
                .unwrap();
        let second =
            ServerEndpoint::new("https://example.cloud.databricks.com/api/2.0/omnigent?o=456")
                .unwrap();
        let a = block_on(save_credential(
            &store,
            &first,
            &credential("fixture-workspace-a", "alice", u64::MAX),
            NOW,
        ))
        .unwrap();
        let b = block_on(save_credential(
            &store,
            &second,
            &credential("fixture-workspace-b", "alice", u64::MAX),
            NOW,
        ))
        .unwrap();
        block_on(remove_credential(&store, &a)).unwrap();
        assert_eq!(block_on(load_credential(&store, &a, NOW)), Ok(None));
        assert_eq!(
            block_on(load_credential(&store, &b, NOW))
                .unwrap()
                .unwrap()
                .token
                .expose(),
            "fixture-workspace-b"
        );
    }

    #[test]
    fn credential_record_round_trips_and_rejects_other_versions() {
        let original = AccountCredential {
            refresh_token: Some(SecretString::new("r1")),
            ..credential("tok", "alice", 42)
        };
        let record = original.to_record();
        assert_eq!(AccountCredential::from_record(&record), Ok(original));
        for bad in [
            &b"not-json"[..],
            br#"{"version":2,"token":"t","userID":"a","expiresAtMs":1}"#,
            br#"{"version":1,"token":"","userID":"a","expiresAtMs":1}"#,
            br#"{"version":1,"token":"t","expiresAtMs":1}"#,
            br#"{"version":1,"token":"t","userID":"a"}"#,
            br#"{"version":1,"token":"t","userID":"a","expiresAtMs":1,"refreshToken":7}"#,
        ] {
            assert_eq!(
                AccountCredential::from_record(bad),
                Err(HostedAuthError::InvalidCredentialRecord)
            );
        }
        let store = MemoryStore::default();
        let scope = ServerEndpoint::new("https://h.example.com")
            .unwrap()
            .identity_scope("bob");
        store.insert(
            &store_key(&scope),
            &credential("t", "alice", u64::MAX).to_record(),
        );
        assert_eq!(
            block_on(load_credential(&store, &scope, NOW)),
            Err(HostedAuthError::InvalidCredentialRecord),
            "a record for another account is never used"
        );
        store.fail_get.set(true);
        assert!(matches!(
            block_on(load_credential(&store, &scope, NOW)),
            Err(HostedAuthError::Store(_))
        ));
    }

    #[test]
    fn expiry_conversion_saturates() {
        assert_eq!(seconds_to_ms(1.5), 1_500);
        assert_eq!(seconds_to_ms(1e30), u64::MAX);
        assert_eq!(expiry_ms(Some(&json!(2)), 10), Some(2_010));
        assert_eq!(expiry_ms(Some(&json!(-1)), 10), None);
        assert_eq!(expiry_ms(Some(&json!("3")), 10), None);
        assert_eq!(expiry_ms(None, 10), None);
    }
}
