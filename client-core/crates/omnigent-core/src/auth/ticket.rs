//! The OIDC browser-ticket sign-in (`/auth/cli-login` + `/auth/cli-poll`): the fallback for OIDC
//! servers whose manifest does not list this app's native redirect.
//!
//! The current server requires PKCE (see `omnigent/server/routes/auth.py`):
//!
//! - `POST /auth/cli-login` with JSON `{code_challenge, code_challenge_method: "S256"}` answers
//!   `{ticket, login_url: "/auth/login?ticket=<t>&reauth=1", user_code, expires_in}`. An empty
//!   body gets the legacy `upgrade-required` sentinel, never a usable ticket.
//! - `GET /auth/cli-poll?ticket=<t>` with `X-Omnigent-Code-Verifier: <verifier>` answers 202
//!   while pending, 200 `{token, user_id, expires_in, refresh_token?}` once approved, 400 for a
//!   missing or malformed verifier, 403 for a mismatched one, and 410 for an expired, denied or
//!   unknown ticket.
//!
//! The host opens [`BrowserLogin::login_url`] and calls [`poll_browser_login`] every
//! [`POLL_INTERVAL_MS`] until it returns a credential, fails with an error for which
//! [`should_keep_polling`] is false, or the login expires.

use serde_json::{Value, json};
use url::Url;

use super::accounts::{AccountCredential, credential_from_login};
use super::endpoint::ServerEndpoint;
use super::errors::HostedAuthError;
use super::mode::{
    AuthenticationMode, check_json_response, discovery_from_info_response, error_text, info_request,
};
use super::pkce::{CODE_CHALLENGE_METHOD, PkcePair};
use super::{EntropySource, SecretString};
use crate::http::{HttpHeader, HttpRequest, HttpResponse, HttpTransport};

/// The header carrying the PKCE verifier on a poll (kept out of access logs, unlike the query).
pub const CODE_VERIFIER_HEADER: &str = "X-Omnigent-Code-Verifier";
/// How often the host polls.
pub const POLL_INTERVAL_MS: u64 = 2_000;
/// How long a ticket lives when the server does not say (`_CLI_TICKET_TTL_SECONDS`).
pub const DEFAULT_TICKET_LIFETIME_MS: u64 = 300_000;
/// The legacy sentinel ticket an empty `cli-login` body gets.
pub const UPGRADE_REQUIRED_TICKET: &str = "upgrade-required";
const MAX_TICKET_LEN: usize = 512;
const LOGIN_PATHS: [&str; 2] = ["/auth/login", "/auth/cli-consent"];

/// The query a trusted login path carries.
type LoginQuery = Vec<(&'static str, String)>;

/// A started browser login. `Debug` is redacted: the ticket and verifier are secrets.
#[derive(Clone, PartialEq, Eq)]
pub struct BrowserLogin {
    /// The page to open in the system browser, mapped through the API mount.
    pub login_url: String,
    /// The code the browser's consent page shows, when the server sent one.
    pub user_code: Option<String>,
    /// When the ticket stops working, in ms since the Unix epoch.
    pub expires_at_ms: u64,
    started_at_ms: u64,
    ticket: SecretString,
    verifier: SecretString,
    base_url: String,
}

impl std::fmt::Debug for BrowserLogin {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("BrowserLogin(redacted)")
    }
}

/// The outcome of one poll.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PollStatus {
    /// The user has not finished in the browser yet.
    Pending,
    /// Signed in.
    Complete(AccountCredential),
}

/// Discovers the mode and, only for OIDC, starts a browser ticket with a fresh PKCE pair.
///
/// # Errors
///
/// [`HostedAuthError::UnsupportedAuthentication`] for local single-user and Databricks-org
/// endpoints (before any request) and for non-OIDC servers; [`HostedAuthError::Entropy`];
/// [`HostedAuthError::LoginUpgradeRequired`] for the legacy sentinel;
/// [`HostedAuthError::RedirectNotAllowed`] for a ticket or login URL outside the contract; and
/// the response and transport errors.
#[allow(
    clippy::future_not_send,
    reason = "Send-ness follows the host transport; WASM transports are !Send by design"
)]
pub async fn begin_browser_login<T: HttpTransport>(
    transport: &T,
    endpoint: &ServerEndpoint,
    entropy: &dyn EntropySource,
    now_ms: u64,
) -> Result<BrowserLogin, HostedAuthError> {
    // Standalone OIDC callbacks do not establish Databricks workspace routing.
    if endpoint.is_local_single_user() || endpoint.databricks_org_id().is_some() {
        return Err(HostedAuthError::UnsupportedAuthentication);
    }
    let response = transport.send(info_request(endpoint)?).await?;
    if discovery_from_info_response(endpoint, None, &response)?.mode != AuthenticationMode::Oidc {
        return Err(HostedAuthError::UnsupportedAuthentication);
    }
    let pkce = PkcePair::generate(entropy)?;
    let response = transport
        .send(ticket_request(endpoint, &pkce.challenge)?)
        .await?;
    browser_login_from_response(endpoint, &response, pkce.verifier, now_ms)
}

/// `POST /auth/cli-login` with the S256 challenge.
///
/// # Errors
///
/// See [`ServerEndpoint::request_with`].
pub fn ticket_request(
    endpoint: &ServerEndpoint,
    challenge: &str,
) -> Result<HttpRequest, HostedAuthError> {
    let mut request =
        endpoint.request_with("POST", "/auth/cli-login", &[], "application/json", None)?;
    request
        .headers
        .push(HttpHeader::new("Content-Type", "application/json"));
    let body = json!({"code_challenge": challenge, "code_challenge_method": CODE_CHALLENGE_METHOD});
    request.body = Some(body.to_string().into_bytes());
    Ok(request)
}

/// Validates the `cli-login` answer and maps its login path through the mount.
///
/// # Errors
///
/// See [`begin_browser_login`].
pub fn browser_login_from_response(
    endpoint: &ServerEndpoint,
    response: &HttpResponse,
    verifier: SecretString,
    now_ms: u64,
) -> Result<BrowserLogin, HostedAuthError> {
    check_json_response(response, false)?;
    let body: Value = serde_json::from_slice(&response.body).map_err(|error| {
        HostedAuthError::MalformedResponse {
            detail: format!("/auth/cli-login: {error}"),
        }
    })?;
    let ticket = body.get("ticket").and_then(Value::as_str).ok_or_else(|| {
        HostedAuthError::MalformedResponse {
            detail: "/auth/cli-login has no ticket".into(),
        }
    })?;
    let login_url = body
        .get("login_url")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if ticket == UPGRADE_REQUIRED_TICKET || login_url == "/auth/cli-upgrade" {
        return Err(HostedAuthError::LoginUpgradeRequired {
            message: body.get("error").and_then(Value::as_str).map(str::to_owned),
        });
    }
    if !is_valid_ticket(ticket) {
        return Err(HostedAuthError::RedirectNotAllowed);
    }
    let (path, query) = trusted_login_path(login_url, ticket)?;
    let query: Vec<(&str, &str)> = query.iter().map(|(k, v)| (*k, v.as_str())).collect();
    let mapped = endpoint.url(path, &query)?;
    let lifetime_ms = body
        .get("expires_in")
        .and_then(Value::as_f64)
        .filter(|seconds| seconds.is_finite() && *seconds > 0.0)
        .map_or(DEFAULT_TICKET_LIFETIME_MS, super::accounts::seconds_to_ms);
    Ok(BrowserLogin {
        login_url: mapped,
        user_code: body
            .get("user_code")
            .and_then(Value::as_str)
            .map(str::to_owned),
        expires_at_ms: now_ms.saturating_add(lifetime_ms),
        started_at_ms: now_ms,
        ticket: SecretString::new(ticket),
        verifier,
        base_url: endpoint.base_url().to_owned(),
    })
}

fn is_valid_ticket(ticket: &str) -> bool {
    !ticket.is_empty()
        && ticket.len() <= MAX_TICKET_LEN
        && ticket
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

/// The server's root-relative login path, accepted only when it is one of the known login pages
/// and its query is exactly `ticket=<this ticket>` plus the server's optional `reauth=1`.
fn trusted_login_path<'a>(
    login_url: &'a str,
    ticket: &str,
) -> Result<(&'a str, LoginQuery), HostedAuthError> {
    let refuse = || HostedAuthError::RedirectNotAllowed;
    if !login_url.starts_with('/') || login_url.starts_with("//") || login_url.contains('#') {
        return Err(refuse());
    }
    let (path, query) = login_url.split_once('?').unwrap_or((login_url, ""));
    if !LOGIN_PATHS.contains(&path) {
        return Err(refuse());
    }
    let base = Url::parse("https://login.invalid/").map_err(|_| refuse())?;
    let parsed = base.join(login_url).map_err(|_| refuse())?;
    let mut tickets = 0;
    let mut out = Vec::new();
    for (name, value) in parsed.query_pairs() {
        match (name.as_ref(), value.as_ref()) {
            ("ticket", value) if value == ticket => tickets += 1,
            ("reauth", "1") if !out.iter().any(|(n, _)| *n == "reauth") => {
                out.push(("reauth", "1".to_owned()));
            }
            _ => return Err(refuse()),
        }
    }
    if tickets != 1 || query.is_empty() {
        return Err(refuse());
    }
    out.insert(0, ("ticket", ticket.to_owned()));
    Ok((path, out))
}

/// One poll of a started browser login.
///
/// # Errors
///
/// [`HostedAuthError::RedirectNotAllowed`] when `login` was started for another server;
/// [`HostedAuthError::BrowserLoginExpired`] once past its expiry (no request) or on a `410`;
/// [`HostedAuthError::BrowserLoginRejected`] on a `400`/`403` (the PKCE proof was refused); the
/// credential errors of the login body; and the response and transport errors.
#[allow(
    clippy::future_not_send,
    reason = "Send-ness follows the host transport; WASM transports are !Send by design"
)]
pub async fn poll_browser_login<T: HttpTransport>(
    transport: &T,
    endpoint: &ServerEndpoint,
    login: &BrowserLogin,
    now_ms: u64,
) -> Result<PollStatus, HostedAuthError> {
    let request = poll_request(endpoint, login, now_ms)?;
    let response = transport.send(request).await?;
    poll_status_from_response(login, &response)
}

/// `GET /auth/cli-poll?ticket=<t>` with the verifier header.
///
/// # Errors
///
/// See [`poll_browser_login`].
pub fn poll_request(
    endpoint: &ServerEndpoint,
    login: &BrowserLogin,
    now_ms: u64,
) -> Result<HttpRequest, HostedAuthError> {
    if login.base_url != endpoint.base_url() {
        return Err(HostedAuthError::RedirectNotAllowed);
    }
    if login.expires_at_ms <= now_ms {
        return Err(HostedAuthError::BrowserLoginExpired { reason: None });
    }
    let mut request =
        endpoint.request("/auth/cli-poll", &[("ticket", login.ticket.expose())], None)?;
    request.headers.push(HttpHeader::new(
        CODE_VERIFIER_HEADER,
        login.verifier.expose(),
    ));
    Ok(request)
}

/// Maps a poll response.
///
/// # Errors
///
/// See [`poll_browser_login`].
pub fn poll_status_from_response(
    login: &BrowserLogin,
    response: &HttpResponse,
) -> Result<PollStatus, HostedAuthError> {
    match response.status {
        202 => return Ok(PollStatus::Pending),
        410 => {
            return Err(HostedAuthError::BrowserLoginExpired {
                reason: error_text(&response.body),
            });
        }
        status @ (400 | 403) => {
            return Err(HostedAuthError::BrowserLoginRejected {
                status,
                reason: error_text(&response.body),
            });
        }
        _ => {}
    }
    check_json_response(response, false)?;
    credential_from_login(&response.body, login.started_at_ms).map(PollStatus::Complete)
}

/// Whether polling should continue after `error`: only for transient failures (the transport,
/// or a 5xx). A refused proof, an expired ticket and a malformed answer end the login.
#[must_use]
pub const fn should_keep_polling(error: &HostedAuthError) -> bool {
    match error {
        HostedAuthError::Transport(_) => true,
        HostedAuthError::HttpStatus { status } => *status >= 500,
        _ => false,
    }
}

/// Whether `token` has a JWT's shape: three non-empty base64url parts. The web shell installs
/// only such tokens as its session cookie, so nothing can smuggle cookie attributes.
#[must_use]
pub fn is_jwt_shaped(token: &str) -> bool {
    let parts: Vec<&str> = token.split('.').collect();
    parts.len() == 3
        && parts.iter().all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
        })
}

#[cfg(test)]
mod tests {
    use futures::executor::block_on;

    use super::*;
    use crate::auth::pkce::code_challenge_s256;
    use crate::auth::testing::{FixedEntropy, ScriptedTransport, body_text, header};

    const MOUNT: &str = "/api/2.0/omnigent";
    const TOKEN: &str = "fixture-token-not-a-real-credential";
    const NOW: u64 = 1_700_000_000_000;
    const OIDC_INFO: &str =
        r#"{"single_user":false,"accounts_enabled":false,"login_url":"/auth/login"}"#;

    fn endpoint() -> ServerEndpoint {
        ServerEndpoint::new(&format!("https://127.0.0.1:8443{MOUNT}")).unwrap()
    }

    fn begin(transport: &ScriptedTransport) -> Result<BrowserLogin, HostedAuthError> {
        block_on(begin_browser_login(
            transport,
            &endpoint(),
            &FixedEntropy::counting(),
            NOW,
        ))
    }

    fn ticket_body(login_url: &str) -> String {
        json!({"ticket": "synthetic-ticket", "login_url": login_url}).to_string()
    }

    #[test]
    fn oidc_browser_ticket_pending_success_expiry_and_server_scope() {
        let transport = ScriptedTransport::new();
        transport.json(200, OIDC_INFO).json(
            200,
            &ticket_body("/auth/login?ticket=synthetic-ticket&reauth=1"),
        );
        let login = begin(&transport).unwrap();
        assert_eq!(
            login.login_url,
            format!("https://127.0.0.1:8443{MOUNT}/auth/login?ticket=synthetic-ticket&reauth=1")
        );
        assert!(!format!("{login:?}").contains("synthetic-ticket"));
        assert_eq!(login.expires_at_ms, NOW + DEFAULT_TICKET_LIFETIME_MS);
        let requests = transport.take();
        let ticket = &requests[1];
        assert_eq!(ticket.method, "POST");
        assert_eq!(
            ticket.url,
            format!("https://127.0.0.1:8443{MOUNT}/auth/cli-login")
        );
        let sent: Value = serde_json::from_str(&body_text(ticket)).unwrap();
        assert_eq!(sent["code_challenge_method"], "S256");
        let challenge = sent["code_challenge"].as_str().unwrap();
        assert_eq!(challenge.len(), 43);

        transport.json(202, r#"{"status":"pending"}"#);
        assert_eq!(
            block_on(poll_browser_login(&transport, &endpoint(), &login, NOW + 1)),
            Ok(PollStatus::Pending)
        );
        let poll = transport.take().remove(0);
        assert_eq!(
            poll.url,
            format!("https://127.0.0.1:8443{MOUNT}/auth/cli-poll?ticket=synthetic-ticket")
        );
        let verifier = header(&poll, CODE_VERIFIER_HEADER).unwrap();
        assert_eq!(code_challenge_s256(verifier), challenge);

        transport.json(
            200,
            &format!(r#"{{"token":"{TOKEN}","user_id":"alice","expires_in":3600}}"#),
        );
        let PollStatus::Complete(credential) =
            block_on(poll_browser_login(&transport, &endpoint(), &login, NOW + 2)).unwrap()
        else {
            panic!("expected a credential");
        };
        assert_eq!(credential.user_id, "alice");
        assert_eq!(credential.token.expose(), TOKEN);
        assert_eq!(credential.expires_at_ms, NOW + 3_600_000);

        let other = ServerEndpoint::new("https://other.invalid").unwrap();
        assert_eq!(
            block_on(poll_browser_login(&transport, &other, &login, NOW)),
            Err(HostedAuthError::RedirectNotAllowed)
        );
        transport.json(410, r#"{"error":"Ticket expired"}"#);
        assert_eq!(
            block_on(poll_browser_login(&transport, &endpoint(), &login, NOW)),
            Err(HostedAuthError::BrowserLoginExpired {
                reason: Some("Ticket expired".into())
            })
        );
        assert_eq!(
            block_on(poll_browser_login(
                &transport,
                &endpoint(),
                &login,
                login.expires_at_ms
            )),
            Err(HostedAuthError::BrowserLoginExpired { reason: None })
        );
        assert_eq!(transport.remaining(), 0);
    }

    #[test]
    fn oidc_rejects_untrusted_browser_ur_ls_and_api_redirects() {
        for target in [
            "https://other.invalid/auth/login?ticket=synthetic-ticket",
            "//other.invalid/auth/login?ticket=synthetic-ticket",
            "/auth/login?ticket=synthetic-ticket&return_to=https://other.invalid",
            "/auth/login?ticket=different-ticket",
            "/auth/login?ticket=synthetic-ticket&ticket=synthetic-ticket",
            "/auth/login?ticket=synthetic-ticket#frag",
            "/other?ticket=synthetic-ticket",
            "auth/login?ticket=synthetic-ticket",
        ] {
            let transport = ScriptedTransport::new();
            transport
                .json(200, OIDC_INFO)
                .json(200, &ticket_body(target));
            assert_eq!(
                begin(&transport),
                Err(HostedAuthError::RedirectNotAllowed),
                "{target}"
            );
        }
        let transport = ScriptedTransport::new();
        transport.reply(302, "text/html", "");
        assert_eq!(begin(&transport), Err(HostedAuthError::RedirectNotAllowed));
    }

    #[test]
    fn proxy_discovery_never_turns_into_password_or_oidc_login() {
        use crate::auth::accounts::{AccountLoginOptions, login};
        use crate::auth::mode::discovery_from_info_response;
        let transport = ScriptedTransport::new();
        let proxy = r#"{"single_user":false,"accounts_enabled":false}"#;
        transport.json(200, proxy);
        let response = block_on(transport.send(info_request(&endpoint()).unwrap())).unwrap();
        assert_eq!(
            discovery_from_info_response(&endpoint(), None, &response)
                .unwrap()
                .mode,
            AuthenticationMode::Proxy
        );
        transport.json(200, proxy).json(200, proxy);
        assert_eq!(
            block_on(login(
                &transport,
                &endpoint(),
                "alice",
                &SecretString::new("synthetic-password"),
                AccountLoginOptions::default(),
                NOW
            )),
            Err(HostedAuthError::UnsupportedAuthentication)
        );
        assert_eq!(
            begin(&transport),
            Err(HostedAuthError::UnsupportedAuthentication)
        );
        assert!(
            transport
                .take()
                .iter()
                .all(|request| request.method == "GET")
        );
        transport.json(401, "{}");
        let response = block_on(transport.send(info_request(&endpoint()).unwrap())).unwrap();
        assert_eq!(
            discovery_from_info_response(&endpoint(), None, &response),
            Err(HostedAuthError::Unauthorized { reason: None })
        );
    }

    #[test]
    fn org_scoped_auth_discovery_uses_header_and_rejects_standalone_login_before_sending_secrets() {
        use crate::auth::accounts::{AccountLoginOptions, login};
        use crate::auth::endpoint::DATABRICKS_ORG_HEADER;
        let org = ServerEndpoint::new(&format!(
            "https://fixture.cloud.databricks.com:8443{MOUNT}?o=123"
        ))
        .unwrap();
        let transport = ScriptedTransport::new();
        transport.json(200, OIDC_INFO);
        let request = info_request(&org).unwrap();
        assert_eq!(header(&request, DATABRICKS_ORG_HEADER), Some("123"));
        assert_eq!(Url::parse(&request.url).unwrap().query(), None);
        let response = block_on(transport.send(request)).unwrap();
        let discovery = discovery_from_info_response(&org, None, &response).unwrap();
        assert_eq!(discovery.mode, AuthenticationMode::Proxy);
        assert_eq!(discovery.base_url, org.base_url());
        assert_eq!(
            block_on(begin_browser_login(
                &transport,
                &org,
                &FixedEntropy::counting(),
                NOW
            )),
            Err(HostedAuthError::UnsupportedAuthentication)
        );
        assert_eq!(
            block_on(login(
                &transport,
                &org,
                "alice",
                &SecretString::new("synthetic-password"),
                AccountLoginOptions::default(),
                NOW
            )),
            Err(HostedAuthError::UnsupportedAuthentication)
        );
        assert_eq!(transport.take().len(), 1, "only the discovery was sent");
    }

    #[test]
    fn oidc_cli_ticket_and_poll_send_pkce_proof() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
        let root = ServerEndpoint::new("https://127.0.0.1:8443").unwrap();
        let request = ticket_request(&root, challenge).unwrap();
        assert_eq!(header(&request, "Content-Type"), Some("application/json"));
        let body: Value = serde_json::from_str(&body_text(&request)).unwrap();
        assert_eq!(
            body,
            json!({"code_challenge": challenge, "code_challenge_method": "S256"})
        );
        let response = crate::auth::testing::response(
            200,
            "application/json",
            r#"{"ticket":"t-1","login_url":"/auth/cli-consent?ticket=t-1","user_code":"ABCD-EFGH","expires_in":60}"#,
        );
        let login = browser_login_from_response(&root, &response, SecretString::new(verifier), NOW)
            .unwrap();
        assert_eq!(login.user_code.as_deref(), Some("ABCD-EFGH"));
        assert_eq!(login.expires_at_ms, NOW + 60_000);
        let poll = poll_request(&root, &login, NOW).unwrap();
        assert_eq!(poll.method, "GET");
        assert_eq!(poll.url, "https://127.0.0.1:8443/auth/cli-poll?ticket=t-1");
        assert_eq!(header(&poll, CODE_VERIFIER_HEADER), Some(verifier));
        assert_eq!(poll.body, None);
        let done = crate::auth::testing::response(
            200,
            "application/json",
            r#"{"token":"aaa.bbb.ccc","user_id":"u1","expires_in":10,"refresh_token":"r1"}"#,
        );
        let PollStatus::Complete(credential) = poll_status_from_response(&login, &done).unwrap()
        else {
            panic!("expected a credential");
        };
        assert_eq!(credential.token.expose(), "aaa.bbb.ccc");
        assert_eq!(credential.refresh_token, Some(SecretString::new("r1")));
    }

    #[test]
    fn oidc_cli_denied_poll_ends_without_token() {
        let root = ServerEndpoint::new("https://127.0.0.1:8443").unwrap();
        let response = crate::auth::testing::response(
            200,
            "application/json",
            r#"{"ticket":"denied","login_url":"/auth/login?ticket=denied"}"#,
        );
        let login =
            browser_login_from_response(&root, &response, SecretString::new("v"), NOW).unwrap();
        for status in [400_u16, 403, 410] {
            let transport = ScriptedTransport::new();
            transport.json(status, r#"{"error":"no"}"#).json(
                200,
                r#"{"token":"aaa.bbb.ccc","user_id":"u","expires_in":1}"#,
            );
            let error = block_on(poll_browser_login(&transport, &root, &login, NOW)).unwrap_err();
            assert!(!should_keep_polling(&error), "{status}: {error:?}");
            assert_eq!(transport.take().len(), 1, "{status}: no retry");
        }
        assert!(should_keep_polling(&HostedAuthError::HttpStatus {
            status: 502
        }));
        assert!(should_keep_polling(&HostedAuthError::Transport(
            crate::http::TransportError::Timeout {
                message: "t".into()
            }
        )));
    }

    #[test]
    fn legacy_upgrade_sentinel_is_typed() {
        let root = ServerEndpoint::new("https://127.0.0.1:8443").unwrap();
        let response = crate::auth::testing::response(
            200,
            "application/json",
            r#"{"ticket":"upgrade-required","login_url":"/auth/cli-upgrade","error":"Update"}"#,
        );
        assert_eq!(
            browser_login_from_response(&root, &response, SecretString::new("v"), NOW),
            Err(HostedAuthError::LoginUpgradeRequired {
                message: Some("Update".into())
            })
        );
    }

    #[test]
    fn oidc_ticket_accepts_rooted_login_path() {
        let root = ServerEndpoint::new("https://example.com").unwrap();
        let response = crate::auth::testing::response(
            200,
            "application/json",
            r#"{"ticket":"abc","login_url":"/auth/login?ticket=abc"}"#,
        );
        let login =
            browser_login_from_response(&root, &response, SecretString::new("v"), NOW).unwrap();
        assert_eq!(login.login_url, "https://example.com/auth/login?ticket=abc");
    }

    #[test]
    fn oidc_ticket_rejects_absolute_and_relative_login_url() {
        let root = ServerEndpoint::new("https://example.com").unwrap();
        for login_url in [
            "https://evil.example/auth",
            "//evil.example/auth",
            "auth/login",
        ] {
            let body = json!({"ticket": "abc", "login_url": login_url}).to_string();
            let response = crate::auth::testing::response(200, "application/json", &body);
            assert_eq!(
                browser_login_from_response(&root, &response, SecretString::new("v"), NOW),
                Err(HostedAuthError::RedirectNotAllowed),
                "{login_url}"
            );
        }
    }

    #[test]
    fn oidc_token_rejects_cookie_injection() {
        assert!(is_jwt_shaped("aaa.bbb.ccc"));
        for token in [
            "aaa.bbb.ccc; Domain=evil.example",
            "aaa.bbb",
            "aaa..ccc",
            "a.b.c.d",
        ] {
            assert!(!is_jwt_shaped(token), "{token}");
        }
    }
}
