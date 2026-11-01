//! Loopback servers sign in by their auth mode, not by their host.
//!
//! `NativeLab` treated every `http://127.0.0.1` root as the single-user runtime, so an accounts
//! server there could log in but never save, restore or use its credential. These tests pin the
//! corrected rule: the single-user runtime still connects without credentials, and an accounts
//! server on loopback goes through login, save, load, restore and sign-out like a hosted one.

use futures::executor::block_on;
use omnigent_protocol::{AuthMode, ManifestAuth};

use super::SecretString;
use super::accounts::{
    AccountLoginOptions, load_credential, login, remove_credential, save_credential,
};
use super::endpoint::ServerEndpoint;
use super::errors::HostedAuthError;
use super::hosted::HostedConnection;
use super::mode::{AuthenticationMode, ServerInfo, mode_from_info, resolve_mode};
use super::testing::{MemoryStore, ScriptedTransport, header};

const LOOPBACK: &str = "http://127.0.0.1:6797";
const TOKEN: &str = "fixture-loopback-token";
const NOW: u64 = 1_700_000_000_000;
const ACCOUNTS_INFO: &str =
    r#"{"single_user":false,"accounts_enabled":true,"login_url":"/login","needs_setup":false}"#;
const SINGLE_USER_INFO: &str = r#"{"single_user":true,"accounts_enabled":false}"#;

fn loopback() -> ServerEndpoint {
    ServerEndpoint::new(LOOPBACK).unwrap()
}

fn info(json: &str) -> ServerInfo {
    ServerInfo::from_json(json.as_bytes()).unwrap()
}

fn manifest(mode: AuthMode) -> ManifestAuth {
    ManifestAuth {
        mode,
        session_cookie: None,
        native_redirect_uris: vec![],
    }
}

#[test]
fn loopback_mode_comes_from_the_server_not_the_host() {
    let endpoint = loopback();
    let accounts = info(ACCOUNTS_INFO);
    let single = info(SINGLE_USER_INFO);
    let oidc = info(r#"{"single_user":false,"accounts_enabled":false,"login_url":"/auth/login"}"#);
    let header_only = info(r#"{"single_user":false,"accounts_enabled":false}"#);
    assert_eq!(
        mode_from_info(&endpoint, &accounts),
        AuthenticationMode::Accounts
    );
    assert_eq!(
        resolve_mode(&endpoint, Some(&manifest(AuthMode::Accounts)), &accounts),
        AuthenticationMode::Accounts
    );
    assert_eq!(
        resolve_mode(&endpoint, Some(&manifest(AuthMode::Oidc)), &oidc),
        AuthenticationMode::Oidc
    );
    // The local runtime reports `none` (no provider) or `header` (header provider with the
    // single-user marker). Both are single-user only when /v1/info says so.
    for mode in [AuthMode::None, AuthMode::Header] {
        assert_eq!(
            resolve_mode(&endpoint, Some(&manifest(mode.clone())), &single),
            AuthenticationMode::LocalSingleUser,
            "{mode:?}"
        );
        assert_eq!(
            resolve_mode(&endpoint, Some(&manifest(mode.clone())), &header_only),
            AuthenticationMode::Proxy,
            "{mode:?} without the single-user marker"
        );
    }
    // A single-user marker next to a sign-in of its own is not the no-credential runtime.
    let marked_accounts = info(r#"{"single_user":true,"accounts_enabled":true}"#);
    assert_eq!(
        resolve_mode(
            &endpoint,
            Some(&manifest(AuthMode::Header)),
            &marked_accounts
        ),
        AuthenticationMode::Proxy
    );
    assert_eq!(
        mode_from_info(&endpoint, &marked_accounts),
        AuthenticationMode::Accounts
    );
    // A hosted single-user marker never means "no credentials".
    let hosted = ServerEndpoint::new("https://omni.example").unwrap();
    assert_eq!(
        resolve_mode(&hosted, Some(&manifest(AuthMode::Header)), &single),
        AuthenticationMode::Proxy
    );
}

#[test]
fn loopback_accounts_login_save_load_restore_and_sign_out() {
    let endpoint = loopback();
    let store = MemoryStore::default();

    // Login: discovery, then the password POST, neither carrying a credential.
    let transport = ScriptedTransport::new();
    transport.json(200, ACCOUNTS_INFO).json(
        200,
        &format!(r#"{{"token":"{TOKEN}","expires_in":3600,"user":{{"id":"alice"}}}}"#),
    );
    let credential = block_on(login(
        &transport,
        &endpoint,
        "alice",
        &SecretString::new("synthetic-password"),
        AccountLoginOptions::default(),
        NOW,
    ))
    .unwrap();
    let requests = transport.take();
    assert_eq!(
        requests.iter().map(|r| r.url.as_str()).collect::<Vec<_>>(),
        [
            "http://127.0.0.1:6797/v1/info",
            "http://127.0.0.1:6797/auth/login"
        ]
    );
    for request in &requests {
        assert_eq!(header(request, "Authorization"), None);
    }

    // Save and load under the loopback account scope.
    let scope = block_on(save_credential(&store, &endpoint, &credential, NOW)).unwrap();
    assert_eq!(scope, endpoint.identity_scope("alice"));
    assert_eq!(scope.account_id(), "http://127.0.0.1:6797\nalice");
    let loaded = block_on(load_credential(&store, &scope, NOW))
        .unwrap()
        .unwrap();
    assert_eq!(loaded.token.expose(), TOKEN);

    // Restore: connect with the saved bearer and the saved account as the expected identity.
    let transport = ScriptedTransport::new();
    transport
        .json(200, ACCOUNTS_INFO)
        .json(200, r#"{"user_id":"alice","is_admin":true}"#);
    let mut connection =
        HostedConnection::new(endpoint, Some(loaded.token), Some("alice".into())).unwrap();
    let server = block_on(connection.connect(&transport)).unwrap();
    assert_eq!(server.user_id, "alice");
    assert_eq!(server.scope, scope);
    assert!(!server.single_user);
    assert!(connection.is_connected());
    assert!(!connection.is_single_user());
    let sessions = connection
        .request("GET", "/v1/sessions", &[], "application/json")
        .unwrap();
    let mut requests = transport.take();
    requests.push(sessions);
    for request in &requests {
        assert_eq!(
            header(request, "Authorization"),
            Some(format!("Bearer {TOKEN}").as_str()),
            "{}",
            request.url
        );
        assert_eq!(header(request, "Cookie"), None);
    }
    assert_eq!(
        connection.websocket_url("/v1/sessions/updates", &[]),
        Ok("ws://127.0.0.1:6797/v1/sessions/updates".to_owned())
    );
    connection
        .rotate_bearer(SecretString::new("fixture-renewed"))
        .unwrap();

    // Sign out: the credential is gone and restore has nothing to load.
    block_on(remove_credential(&store, &scope)).unwrap();
    assert_eq!(block_on(load_credential(&store, &scope, NOW)), Ok(None));
    assert_eq!(store.items.borrow().len(), 0);
}

#[test]
fn loopback_single_user_runtime_still_connects_without_credentials() {
    let transport = ScriptedTransport::new();
    transport
        .json(200, SINGLE_USER_INFO)
        .json(200, r#"{"user_id":"local"}"#);
    let mut connection = HostedConnection::new(loopback(), None, None).unwrap();
    let server = block_on(connection.connect(&transport)).unwrap();
    assert_eq!(server.user_id, "local");
    assert!(server.single_user);
    assert!(connection.is_single_user());
    assert_eq!(connection.authorization(), None);
    for request in transport.take() {
        assert_eq!(header(&request, "Authorization"), None);
    }
    connection.disconnect();
    assert!(!connection.is_single_user(), "only while connected");
}

#[test]
fn loopback_connections_fail_closed_when_the_credential_does_not_match_the_mode() {
    // No credential for an accounts server: the server must not be mistaken for single-user.
    let transport = ScriptedTransport::new();
    transport.json(200, ACCOUNTS_INFO);
    let mut anonymous = HostedConnection::new(loopback(), None, None).unwrap();
    assert_eq!(
        block_on(anonymous.connect(&transport)),
        Err(HostedAuthError::UnsupportedAuthentication)
    );
    assert_eq!(transport.take().len(), 1, "no /v1/me without a credential");

    // A credential for the single-user runtime: it would be mistaken for bearer auth.
    let transport = ScriptedTransport::new();
    transport.json(200, SINGLE_USER_INFO);
    let mut bearer =
        HostedConnection::new(loopback(), Some(SecretString::new(TOKEN)), None).unwrap();
    assert_eq!(
        block_on(bearer.connect(&transport)),
        Err(HostedAuthError::UnsupportedAuthentication)
    );
    assert_eq!(transport.take().len(), 1);

    // Login to the single-user runtime sends no password.
    let transport = ScriptedTransport::new();
    transport.json(200, SINGLE_USER_INFO);
    assert_eq!(
        block_on(login(
            &transport,
            &loopback(),
            "alice",
            &SecretString::new("synthetic-password"),
            AccountLoginOptions::default(),
            NOW,
        )),
        Err(HostedAuthError::UnsupportedAuthentication)
    );
    let requests = transport.take();
    assert_eq!(requests.len(), 1);
    assert!(requests[0].url.ends_with("/v1/info"));
}
