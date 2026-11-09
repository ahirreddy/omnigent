//! Ports of web/ios `OidcCredentialsTests` and `OidcCredentialStoreTests`.

use futures::executor::block_on;

use super::*;
use crate::auth::testing::{
    FixedEntropy, GatedTransport, MemoryStore, ScriptedTransport, body_text, header, join2,
    poll_once,
};

const NOW: u64 = 1_700_000_000_000;
const SERVER: &str = "http://localhost:6767/omnigent/";
const HOST: &str = "localhost:6767";

fn server() -> OidcServer {
    OidcServer::new(SERVER).unwrap()
}

fn credentials() -> OidcCredentials<ScriptedTransport, MemoryStore> {
    OidcCredentials::new(ScriptedTransport::new(), MemoryStore::default())
}

fn attempt() -> OidcSignInAttempt {
    begin_sign_in(
        &server(),
        IOS_NATIVE_REDIRECT_URI,
        &FixedEntropy::counting(),
    )
    .unwrap()
}

fn query_of(url: &str) -> Vec<(String, String)> {
    Url::parse(url)
        .unwrap()
        .query_pairs()
        .into_owned()
        .collect()
}

fn state_of(attempt: &OidcSignInAttempt) -> String {
    query_of(attempt.authorize_url())
        .into_iter()
        .find(|(name, _)| name == "native_state")
        .map(|(_, value)| value)
        .unwrap()
}

/// `ai.omnigent.ios:/oauth/callback?<pairs>` encoded as the server does (form encoding).
fn callback(items: &[(&str, &str)]) -> String {
    callback_at("/oauth/callback", items)
}

fn callback_at(path: &str, items: &[(&str, &str)]) -> String {
    let mut url = Url::parse(&format!("ai.omnigent.ios:{path}")).unwrap();
    if !items.is_empty() {
        url.query_pairs_mut().extend_pairs(items);
    }
    url.into()
}

fn good_callback(attempt: &OidcSignInAttempt) -> String {
    callback(&[("code", "the-code"), ("state", &state_of(attempt))])
}

fn form(request: &HttpRequest) -> Vec<(String, String)> {
    url::form_urlencoded::parse(body_text(request).as_bytes())
        .into_owned()
        .collect()
}

fn grant(token: &str, user: Option<&str>) -> OidcGrant {
    OidcGrant {
        refresh_token: SecretString::new(token),
        user_id: user.map(str::to_owned),
    }
}

fn stored(credentials: &OidcCredentials<impl HttpTransport, MemoryStore>) -> Option<OidcGrant> {
    credentials
        .store()
        .value(&server().grant_key())
        .map(|bytes| OidcGrant::from_record(&bytes).unwrap())
}

fn store_grant(credentials: &OidcCredentials<impl HttpTransport, MemoryStore>, grant: &OidcGrant) {
    credentials
        .store()
        .insert(&server().grant_key(), &grant.to_record());
}

const UNSAFE_TOKENS: [&str; 11] = [
    "",
    " ",
    "a b",
    "a;b",
    "a,b",
    "a\"b",
    "a\\b",
    "a\u{7}b",
    "a\nb",
    "a\u{7F}b",
    "caf\u{E9}",
];

#[test]
fn oidc_sign_in_builds_login_url_and_exchanges_pkce() {
    let credentials = credentials();
    credentials.transport().json(
        200,
        r#"{"token":"session-1","user_id":"u1","expires_in":3600,"refresh_token":"r1"}"#,
    );
    let attempt = attempt();
    let login = Url::parse(attempt.authorize_url()).unwrap();
    assert_eq!(login.scheme(), "http");
    assert_eq!(login.host_str(), Some("localhost"));
    assert_eq!(login.path(), "/omnigent/auth/login");
    let query = query_of(attempt.authorize_url());
    let names: Vec<&str> = query.iter().map(|(name, _)| name.as_str()).collect();
    assert_eq!(
        names,
        [
            "native_redirect_uri",
            "native_state",
            "code_challenge",
            "code_challenge_method"
        ]
    );
    assert_eq!(query[0].1, "ai.omnigent.ios:/oauth/callback");
    assert_eq!(query[3].1, "S256");
    let state = &query[1].1;
    assert!(
        !state.is_empty()
            && state.len() <= 256
            && state
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._~-".contains(&b))
    );
    let challenge = query[2].1.clone();
    assert_eq!(challenge.len(), 43);
    assert_eq!(attempt.redirect().scheme(), "ai.omnigent.ios");
    assert!(
        attempt
            .redirect()
            .matches(&Url::parse("ai.omnigent.ios:/oauth/callback").unwrap())
    );
    assert!(
        !attempt
            .redirect()
            .matches(&Url::parse("omnigent:/oauth/callback").unwrap())
    );

    let signed_in = block_on(credentials.complete_sign_in(
        &attempt,
        &callback(&[("code", "the-code"), ("state", state)]),
        NOW,
    ))
    .unwrap();
    assert_eq!(
        signed_in.session,
        OidcSession {
            token: SecretString::new("session-1"),
            expires_at_ms: Some(NOW + 3_600_000)
        }
    );
    assert_eq!(signed_in.user_id.as_deref(), Some("u1"));
    assert_eq!(signed_in.stale_grant_error, None);

    let exchange = credentials.transport().take().remove(0);
    assert_eq!(exchange.method, "POST");
    assert_eq!(
        exchange.url,
        "http://localhost:6767/omnigent/auth/native-token"
    );
    assert_eq!(
        header(&exchange, "Content-Type"),
        Some("application/x-www-form-urlencoded")
    );
    let form = form(&exchange);
    assert_eq!(form[0], ("code".into(), "the-code".into()));
    assert_eq!(
        form[2],
        ("redirect_uri".into(), IOS_NATIVE_REDIRECT_URI.into())
    );
    assert_eq!(form[1].0, "code_verifier");
    assert_eq!(pkce::code_challenge_s256(&form[1].1), challenge);
    assert_eq!(stored(&credentials), Some(grant("r1", Some("u1"))));
    assert_eq!(block_on(credentials.has_stored_grant(&server())), Ok(true));
}

#[test]
fn oidc_invalid_callbacks_never_exchange() {
    let credentials = credentials();
    let attempt = attempt();
    let state = state_of(&attempt);
    let invalid = OidcError::InvalidCallback { host: HOST.into() };
    let cases: Vec<(&str, String, OidcError)> = vec![
        (
            "state mismatch",
            callback(&[("code", "c"), ("state", "other")]),
            invalid.clone(),
        ),
        ("missing state", callback(&[("code", "c")]), invalid.clone()),
        (
            "missing code",
            callback(&[("state", &state)]),
            invalid.clone(),
        ),
        (
            "empty code",
            callback(&[("code", ""), ("state", &state)]),
            invalid.clone(),
        ),
        (
            "two codes",
            callback(&[("code", "a"), ("code", "b"), ("state", &state)]),
            invalid.clone(),
        ),
        (
            "wrong path",
            callback_at("/other", &[("code", "c"), ("state", &state)]),
            invalid.clone(),
        ),
        (
            "with host",
            format!("ai.omnigent.ios://evil/oauth/callback?code=c&state={state}"),
            invalid.clone(),
        ),
        (
            "other scheme",
            format!("omnigent:/oauth/callback?code=c&state={state}"),
            invalid.clone(),
        ),
        (
            "server error",
            callback(&[
                ("error", "access_denied"),
                ("error_description", "example.org is not allowed"),
                ("state", &state),
            ]),
            OidcError::SignInRefused {
                host: HOST.into(),
                description: Some("example.org is not allowed".into()),
            },
        ),
        (
            "error without state",
            callback(&[("error", "access_denied")]),
            invalid.clone(),
        ),
        ("not a URL", "::".into(), invalid),
    ];
    for (name, url, expected) in cases {
        assert_eq!(
            block_on(credentials.complete_sign_in(&attempt, &url, NOW)),
            Err(expected),
            "{name}"
        );
    }
    assert_eq!(credentials.transport().take().len(), 0);
    assert_eq!(
        OidcError::SignInRefused {
            host: HOST.into(),
            description: None
        }
        .to_string(),
        "localhost:6767 didn't accept the sign-in. Try again."
    );
}

#[test]
fn oidc_callback_query_decodes_as_form() {
    let server = OidcServer::new("https://omnigent.example.com").unwrap();
    let mut attempt =
        begin_sign_in(&server, IOS_NATIVE_REDIRECT_URI, &FixedEntropy::counting()).unwrap();
    attempt.state = SecretString::new("s-1_.~AbC");
    let raw = |query: &str| format!("ai.omnigent.ios:/oauth/callback?{query}");
    assert_eq!(
        attempt.authorization_code(&raw(
            "error=access_denied&error_description=Email+domain+%27other.test%27+is%20not%2Ballowed&state=s-1_.~AbC"
        )),
        Err(OidcError::SignInRefused {
            host: "omnigent.example.com".into(),
            description: Some("Email domain 'other.test' is not+allowed".into())
        })
    );
    assert_eq!(
        attempt
            .authorization_code(&raw("code=abc-_.~%2Bdef&state=s-1_.~AbC"))
            .unwrap()
            .expose(),
        "abc-_.~+def"
    );
    // A literal '+' in state means a space, so it no longer matches.
    attempt.state = SecretString::new("a+b");
    assert!(
        attempt
            .authorization_code(&raw("code=c&state=a+b"))
            .is_err()
    );
    assert_eq!(
        attempt
            .authorization_code(&raw("code=c&state=a%2Bb"))
            .unwrap()
            .expose(),
        "c"
    );
    attempt.state = SecretString::new("s");
    assert!(
        attempt
            .authorization_code(&raw("code=c&state=s&state=s"))
            .is_err()
    );
    assert_eq!(form_items(Some("code=%zz")), None);
    assert_eq!(form_items(Some("code=%C3")), None, "invalid UTF-8");
    assert_eq!(
        form_items(Some("a=1+2&&b&c=%2B")),
        Some(vec![
            ("a".into(), Some("1 2".into())),
            ("b".into(), None),
            ("c".into(), Some("+".into())),
        ])
    );
    assert_eq!(form_items(None), Some(vec![]));
}

#[test]
fn oidc_exchange_without_refresh_forgets_stale_grant() {
    let credentials = credentials();
    store_grant(&credentials, &grant("stale", None));
    credentials
        .transport()
        .json(200, r#"{"token":"session-1","user_id":"u1"}"#);
    let attempt = attempt();
    let signed_in =
        block_on(credentials.complete_sign_in(&attempt, &good_callback(&attempt), NOW)).unwrap();
    assert_eq!(
        signed_in.session,
        OidcSession {
            token: SecretString::new("session-1"),
            expires_at_ms: None
        }
    );
    assert_eq!(stored(&credentials), None);
    assert_eq!(block_on(credentials.has_stored_grant(&server())), Ok(false));
}

#[test]
fn oidc_expires_in_capped_at_max_lifetime() {
    let credentials = credentials();
    credentials
        .transport()
        .json(200, r#"{"token":"session-1","expires_in":20000000000}"#);
    let attempt = attempt();
    let signed_in =
        block_on(credentials.complete_sign_in(&attempt, &good_callback(&attempt), NOW)).unwrap();
    assert_eq!(
        signed_in.session.expires_at_ms,
        Some(NOW + MAX_SESSION_LIFETIME_MS)
    );
    for ignored in ["0", "-5", "true", "\"3600\"", "null"] {
        credentials.transport().json(
            200,
            &format!(r#"{{"token":"session-1","expires_in":{ignored}}}"#),
        );
        let signed_in =
            block_on(credentials.complete_sign_in(&attempt, &good_callback(&attempt), NOW))
                .unwrap();
        assert_eq!(signed_in.session.expires_at_ms, None, "{ignored}");
    }
}

#[test]
fn oidc_exchange_succeeds_when_stale_grant_delete_fails() {
    let credentials = credentials();
    store_grant(&credentials, &grant("stale", None));
    credentials.store().fail_delete.set(true);
    credentials
        .transport()
        .json(200, r#"{"token":"session-1"}"#);
    let attempt = attempt();
    let signed_in =
        block_on(credentials.complete_sign_in(&attempt, &good_callback(&attempt), NOW)).unwrap();
    assert_eq!(signed_in.session.token.expose(), "session-1");
    assert!(
        signed_in.stale_grant_error.is_some(),
        "the failure is reported, not dropped"
    );
}

#[test]
fn oidc_unsafe_session_tokens_refused() {
    let credentials = credentials();
    let attempt = attempt();
    let kept = grant("r1", None);
    for token in UNSAFE_TOKENS {
        credentials.store().items.borrow_mut().clear();
        let body = json!({"token": token, "refresh_token": "r1"}).to_string();
        credentials.transport().json(200, &body);
        assert_eq!(
            block_on(credentials.complete_sign_in(&attempt, &good_callback(&attempt), NOW)),
            Err(OidcError::ExchangeFailed {
                host: HOST.into(),
                cause: ExchangeFailure::InvalidToken
            }),
            "{token:?}"
        );
        assert_eq!(stored(&credentials), None, "{token:?}");

        store_grant(&credentials, &kept);
        credentials
            .transport()
            .json(200, &json!({"access_token": token}).to_string());
        assert_eq!(
            block_on(credentials.refresh(&server(), NOW)),
            Err(OidcError::Network {
                host: HOST.into(),
                cause: NetworkCause::InvalidToken
            }),
            "{token:?}"
        );
        assert_eq!(stored(&credentials), Some(kept.clone()), "{token:?}");
    }
    assert!(is_header_safe_token(
        "eyJhbGciOiJIUzI1NiJ9.e30.sig-_~!#$%&'()*+-./:<=>?@[]^`{|}"
    ));
}

#[test]
fn oidc_exchange_server_error_is_exchange_failure() {
    let credentials = credentials();
    credentials.transport().json(500, "{}");
    let attempt = attempt();
    let error = block_on(credentials.complete_sign_in(&attempt, &good_callback(&attempt), NOW))
        .unwrap_err();
    assert_eq!(
        error,
        OidcError::ExchangeFailed {
            host: HOST.into(),
            cause: ExchangeFailure::Status {
                status: 500,
                error: None
            }
        }
    );
    assert_eq!(
        error.to_string(),
        "Couldn't finish signing in to localhost:6767. Try again."
    );
}

#[test]
fn oidc_rejected_exchange_keeps_stored_grant() {
    let credentials = credentials();
    let kept = grant("kept", None);
    store_grant(&credentials, &kept);
    credentials
        .transport()
        .json(400, r#"{"error":"invalid_grant"}"#);
    let attempt = attempt();
    assert_eq!(
        block_on(credentials.complete_sign_in(&attempt, &good_callback(&attempt), NOW)),
        Err(OidcError::ExchangeFailed {
            host: HOST.into(),
            cause: ExchangeFailure::Status {
                status: 400,
                error: Some("invalid_grant".into())
            }
        })
    );
    assert_eq!(credentials.transport().take().len(), 1);
    assert_eq!(stored(&credentials), Some(kept));
}

// Swift cancels cooperatively after the exchange; in Rust the exchange and the grant write finish
// within one `complete_sign_in`, so the grant is stored before the host can act on a cancel.
#[test]
fn oidc_cancel_during_exchange_still_stores_grant() {
    let credentials = OidcCredentials::new(
        GatedTransport::new("/auth/native-token"),
        MemoryStore::default(),
    );
    credentials
        .transport()
        .inner
        .json(200, r#"{"token":"session-1","refresh_token":"r1"}"#);
    let attempt = attempt();
    let callback = good_callback(&attempt);
    let gate = std::rc::Rc::clone(&credentials.transport().gate);
    let (result, ()) = block_on(async {
        join2(
            credentials.complete_sign_in(&attempt, &callback, NOW),
            async {
                assert_eq!(
                    stored(&credentials),
                    None,
                    "nothing stored before the answer"
                );
                gate.open();
            },
        )
        .await
    });
    assert!(result.is_ok());
    assert_eq!(stored(&credentials), Some(grant("r1", None)));
}

#[test]
fn oidc_unsavable_grant_is_revoked() {
    let credentials = credentials();
    credentials.store().fail_set.set(true);
    credentials
        .transport()
        .json(200, r#"{"token":"session-1","refresh_token":"r1"}"#)
        .json(200, "{}");
    let attempt = attempt();
    let error = block_on(credentials.complete_sign_in(&attempt, &good_callback(&attempt), NOW))
        .unwrap_err();
    assert!(
        matches!(
            &error,
            OidcError::GrantNotSaved {
                revocation: RevokeOutcome::Revoked,
                ..
            }
        ),
        "{error:?}"
    );
    let requests = credentials.transport().take();
    let revoke = &requests[1];
    assert_eq!(revoke.url, "http://localhost:6767/omnigent/oauth/revoke");
    assert_eq!(
        form(revoke),
        [("refresh_token".to_owned(), "r1".to_owned())]
    );
    assert_eq!(stored(&credentials), None);
}

#[test]
fn oidc_exchange_does_not_follow_redirects() {
    let credentials = credentials();
    credentials.transport().push(Ok(HttpResponse {
        status: 302,
        headers: vec![HttpHeader::new("Location", "/omnigent/leak")],
        body: Vec::new(),
    }));
    credentials
        .transport()
        .json(200, r#"{"token":"leaked","refresh_token":"r9"}"#);
    let attempt = attempt();
    assert_eq!(
        block_on(credentials.complete_sign_in(&attempt, &good_callback(&attempt), NOW)),
        Err(OidcError::ExchangeFailed {
            host: HOST.into(),
            cause: ExchangeFailure::Status {
                status: 302,
                error: None
            }
        })
    );
    let requests = credentials.transport().take();
    assert_eq!(requests.len(), 1, "the leak endpoint is never hit");
    assert_eq!(stored(&credentials), None);
}

#[test]
fn oidc_refresh_does_not_follow_redirects() {
    let credentials = credentials();
    let kept = grant("r1", None);
    store_grant(&credentials, &kept);
    credentials.transport().push(Ok(HttpResponse {
        status: 302,
        headers: vec![HttpHeader::new("Location", "/omnigent/leak")],
        body: Vec::new(),
    }));
    assert_eq!(
        block_on(credentials.refresh(&server(), NOW)),
        Err(OidcError::Network {
            host: HOST.into(),
            cause: NetworkCause::Status(302)
        })
    );
    assert_eq!(credentials.transport().take().len(), 1);
    assert_eq!(stored(&credentials), Some(kept));
}

#[test]
fn oidc_refresh_mints_from_stored_grant() {
    let credentials = credentials();
    let kept = grant("r1", Some("u1"));
    store_grant(&credentials, &kept);
    credentials.transport().json(
        200,
        r#"{"access_token":"session-2","refresh_token":"r1","expires_in":600}"#,
    );
    let session = block_on(credentials.refresh(&server(), NOW)).unwrap();
    assert_eq!(
        session,
        OidcSession {
            token: SecretString::new("session-2"),
            expires_at_ms: Some(NOW + 600_000)
        }
    );
    assert_eq!(session.renewal_delay_ms(NOW), Some(540_000));
    let request = credentials.transport().take().remove(0);
    assert_eq!(request.method, "POST");
    assert_eq!(request.url, "http://localhost:6767/omnigent/oauth/token");
    assert_eq!(
        form(&request),
        [
            ("grant_type".to_owned(), "refresh_token".to_owned()),
            ("refresh_token".to_owned(), "r1".to_owned())
        ]
    );
    assert_eq!(stored(&credentials), Some(kept));
}

#[test]
fn oidc_refresh_stores_a_rotated_grant() {
    let credentials = credentials();
    store_grant(&credentials, &grant("r1", Some("u1")));
    credentials
        .transport()
        .json(200, r#"{"access_token":"session-2","refresh_token":"r2"}"#);
    block_on(credentials.refresh(&server(), NOW)).unwrap();
    assert_eq!(stored(&credentials), Some(grant("r2", Some("u1"))));
}

#[test]
fn oidc_dead_grants_forgotten_with_messages() {
    let credentials = credentials();
    for (status, body, expected) in [
        (
            400,
            r#"{"error":"invalid_grant"}"#,
            OidcError::GrantRejected { host: HOST.into() },
        ),
        (
            400,
            r#"{"error":"expired_token"}"#,
            OidcError::GrantExpired { host: HOST.into() },
        ),
        (
            404,
            r#"{"detail":"Not Found"}"#,
            OidcError::NoStoredGrant { host: HOST.into() },
        ),
    ] {
        store_grant(&credentials, &grant("r1", None));
        credentials.transport().json(status, body);
        assert_eq!(
            block_on(credentials.refresh(&server(), NOW)),
            Err(expected.clone())
        );
        assert_eq!(stored(&credentials), None, "{expected:?}");
    }
    assert_eq!(
        OidcError::GrantExpired { host: HOST.into() }.to_string(),
        "Your sign-in to localhost:6767 has expired. Sign in again to continue."
    );
    assert_eq!(
        OidcError::GrantRejected { host: HOST.into() }.to_string(),
        "localhost:6767 ended your session. Sign in again to continue."
    );
    assert_eq!(
        OidcError::NoStoredGrant { host: HOST.into() }.to_string(),
        "Sign in to localhost:6767 to continue."
    );

    // A dead grant that cannot be deleted was not forgotten: the store failure is reported.
    store_grant(&credentials, &grant("r1", None));
    credentials.store().fail_delete.set(true);
    credentials
        .transport()
        .json(400, r#"{"error":"invalid_grant"}"#);
    assert!(matches!(
        block_on(credentials.refresh(&server(), NOW)),
        Err(OidcError::Store { .. })
    ));
}

#[test]
fn oidc_server_and_transport_failures_keep_grant() {
    let credentials = credentials();
    let kept = grant("r1", None);
    store_grant(&credentials, &kept);
    for (status, body) in [
        (500, r#"{"error":"server_error"}"#),
        (400, r#"{"error":"invalid_request"}"#),
    ] {
        credentials.transport().json(status, body);
        assert_eq!(
            block_on(credentials.refresh(&server(), NOW)),
            Err(OidcError::Network {
                host: HOST.into(),
                cause: NetworkCause::Status(status)
            })
        );
        assert_eq!(stored(&credentials), Some(kept.clone()));
    }
    let offline = TransportError::Offline {
        message: "connection refused".into(),
    };
    credentials.transport().fail(offline.clone());
    let error = block_on(credentials.refresh(&server(), NOW)).unwrap_err();
    assert_eq!(
        error,
        OidcError::Network {
            host: HOST.into(),
            cause: NetworkCause::Transport(offline)
        }
    );
    assert!(!error.to_string().to_lowercase().contains("expired"));
    assert_eq!(stored(&credentials), Some(kept));
}

#[test]
fn oidc_refresh_without_grant_sends_nothing() {
    let credentials = credentials();
    assert_eq!(
        block_on(credentials.refresh(&server(), NOW)),
        Err(OidcError::NoStoredGrant { host: HOST.into() })
    );
    assert_eq!(credentials.transport().take().len(), 0);
    // An unreadable record is forgotten and reads as no grant.
    credentials.store().insert(
        &server().grant_key(),
        br#"{"version":2,"refreshToken":"r"}"#,
    );
    assert_eq!(
        block_on(credentials.refresh(&server(), NOW)),
        Err(OidcError::NoStoredGrant { host: HOST.into() })
    );
    assert_eq!(credentials.store().value(&server().grant_key()), None);
    assert_eq!(credentials.transport().take().len(), 0);
}

#[test]
fn oidc_concurrent_refreshes_share_one_request() {
    let credentials =
        OidcCredentials::new(GatedTransport::new("/oauth/token"), MemoryStore::default());
    store_grant(&credentials, &grant("r1", None));
    credentials
        .transport()
        .inner
        .json(200, r#"{"access_token":"session-2"}"#)
        .json(200, r#"{"access_token":"session-3"}"#);
    let gate = std::rc::Rc::clone(&credentials.transport().gate);
    // A different spelling of the same origin shares the flight.
    let other_spelling = OidcServer::new("http://LOCALHOST:6767/").unwrap();
    let ((first, second), ()) = block_on(join2(
        join2(
            credentials.refresh(&server(), NOW),
            credentials.refresh(&other_spelling, NOW),
        ),
        async { gate.open() },
    ));
    assert_eq!(first.unwrap().token.expose(), "session-2");
    assert_eq!(second.unwrap().token.expose(), "session-2");
    assert_eq!(credentials.transport().inner.take().len(), 1);
    let third = block_on(credentials.refresh(&server(), NOW)).unwrap();
    assert_eq!(third.token.expose(), "session-3");
    assert_eq!(credentials.transport().inner.take().len(), 1);
}

#[test]
fn oidc_abandoned_refresh_hands_over_to_a_joiner() {
    let credentials =
        OidcCredentials::new(GatedTransport::new("/oauth/token"), MemoryStore::default());
    store_grant(&credentials, &grant("r1", None));
    credentials
        .transport()
        .inner
        .json(200, r#"{"access_token":"never-read"}"#)
        .json(200, r#"{"access_token":"session-2"}"#);
    let gate = std::rc::Rc::clone(&credentials.transport().gate);
    let server = server();
    let leader = credentials.refresh(&server, NOW);
    let joiner = credentials.refresh(&server, NOW);
    let result = block_on(async {
        let mut leader = Box::pin(leader);
        // Start the leader, then drop it mid-request.
        assert!(poll_once(leader.as_mut()).await.is_pending());
        let mut joiner = Box::pin(joiner);
        assert!(poll_once(joiner.as_mut()).await.is_pending());
        drop(leader);
        gate.open();
        joiner.await
    });
    assert_eq!(result.unwrap().token.expose(), "session-2");
}

#[test]
fn oidc_sign_out_forgets_grant_before_revoke() {
    let credentials = credentials();
    store_grant(&credentials, &grant("r1", None));
    credentials.transport().json(200, r#"{"revoked":true}"#);
    let forgotten = block_on(credentials.forget_grant(&server()));
    assert_eq!(stored(&credentials), None);
    assert_eq!(credentials.transport().take().len(), 0);
    assert_eq!(forgotten.delete_error, None);
    let pending = forgotten.revocation.unwrap();
    assert_eq!(
        block_on(credentials.revoke(pending)),
        RevokeOutcome::Revoked
    );
    let request = credentials.transport().take().remove(0);
    assert_eq!(request.method, "POST");
    assert_eq!(request.url, "http://localhost:6767/omnigent/oauth/revoke");
    assert_eq!(
        form(&request),
        [("refresh_token".to_owned(), "r1".to_owned())]
    );
}

#[test]
fn oidc_sign_out_drops_in_flight_refresh() {
    let credentials =
        OidcCredentials::new(GatedTransport::new("/oauth/token"), MemoryStore::default());
    store_grant(&credentials, &grant("r1", None));
    credentials
        .transport()
        .inner
        .json(200, r#"{"access_token":"session-2","refresh_token":"r2"}"#)
        .json(200, r#"{"revoked":true}"#);
    let gate = std::rc::Rc::clone(&credentials.transport().gate);
    let (in_flight, (report, after)) = block_on(async {
        join2(credentials.refresh(&server(), NOW), async {
            let report = credentials.sign_out(&server()).await;
            // A refresh after sign-out starts fresh and finds no grant, rather than joining.
            let after = credentials.refresh(&server(), NOW).await;
            gate.open();
            (report, after)
        })
        .await
    });
    assert_eq!(report.revocation, Some(RevokeOutcome::Revoked));
    assert!(report.is_complete());
    assert_eq!(after, Err(OidcError::NoStoredGrant { host: HOST.into() }));
    assert_eq!(in_flight, Err(OidcError::Cancelled));
    assert_eq!(
        stored(&credentials),
        None,
        "the dropped refresh stores nothing"
    );
    let tokens = credentials
        .transport()
        .inner
        .take()
        .iter()
        .filter(|request| request.url.ends_with("/oauth/token"))
        .count();
    assert_eq!(tokens, 1);
}

#[test]
fn oidc_sign_out_survives_revoke_failure() {
    let credentials = credentials();
    store_grant(&credentials, &grant("r1", None));
    credentials.transport().json(500, "{}");
    let report = block_on(credentials.sign_out(&server()));
    assert_eq!(
        report.revocation,
        Some(RevokeOutcome::Failed(NetworkCause::Status(500)))
    );
    assert!(report.is_complete());
    assert_eq!(stored(&credentials), None);

    store_grant(&credentials, &grant("r2", None));
    credentials.transport().fail(TransportError::Offline {
        message: "unreachable".into(),
    });
    let report = block_on(credentials.sign_out(&server()));
    assert!(matches!(
        report.revocation,
        Some(RevokeOutcome::Failed(NetworkCause::Transport(_)))
    ));
    assert_eq!(stored(&credentials), None);

    // Nothing stored: nothing to revoke.
    let report = block_on(credentials.sign_out(&server()));
    assert_eq!(report.revocation, None);
    assert_eq!(credentials.transport().take().len(), 2);

    // A failed delete is reported as an incomplete sign-out.
    store_grant(&credentials, &grant("r3", None));
    credentials.store().fail_delete.set(true);
    credentials.transport().json(200, "{}");
    let report = block_on(credentials.sign_out(&server()));
    assert!(!report.is_complete());
    assert!(matches!(report.delete_error, Some(OidcError::Store { .. })));
}

#[test]
fn oidc_is_accepted_maps_me_status() {
    let credentials = credentials();
    let token = SecretString::new("session-1");
    for (status, accepted) in [(200, true), (401, false), (403, false), (302, false)] {
        credentials.transport().push(Ok(HttpResponse {
            status,
            headers: vec![HttpHeader::new("Location", "https://idp.example.com/login")],
            body: b"{}".to_vec(),
        }));
        assert_eq!(
            block_on(credentials.is_accepted(
                &server(),
                &token,
                SessionPresentation::Cookie("ap_session")
            )),
            Ok(accepted),
            "{status}"
        );
    }
    let requests = credentials.transport().take();
    assert_eq!(requests.len(), 4, "the redirect was not followed");
    assert_eq!(requests[0].method, "GET");
    assert_eq!(requests[0].url, "http://localhost:6767/omnigent/v1/me");
    assert_eq!(header(&requests[0], "Cookie"), Some("ap_session=session-1"));

    credentials.transport().json(500, "{}");
    assert_eq!(
        block_on(credentials.is_accepted(&server(), &token, SessionPresentation::Bearer)),
        Err(OidcError::Network {
            host: HOST.into(),
            cause: NetworkCause::Status(500)
        })
    );
    assert_eq!(
        header(&credentials.transport().take()[0], "Authorization"),
        Some("Bearer session-1")
    );
    let offline = OidcServer::new("http://localhost:1").unwrap();
    credentials.transport().fail(TransportError::Offline {
        message: "refused".into(),
    });
    assert!(matches!(
        block_on(credentials.is_accepted(&offline, &token, SessionPresentation::Bearer)),
        Err(OidcError::Network { host, .. }) if host == "localhost:1"
    ));
}

#[test]
fn oidc_grant_record_rejects_invalid() {
    let original = grant("refresh-1", Some("user-1"));
    let record: Value = serde_json::from_slice(&original.to_record()).unwrap();
    assert_eq!(
        record,
        json!({"version": 1, "refreshToken": "refresh-1", "userID": "user-1"})
    );
    assert_eq!(
        OidcGrant::from_record(&original.to_record()),
        Some(original)
    );
    let without_user = grant("r", None);
    assert!(
        !String::from_utf8(without_user.to_record())
            .unwrap()
            .contains("userID")
    );
    assert_eq!(
        OidcGrant::from_record(br#"{"version":1,"refreshToken":"r","userID":null}"#),
        Some(without_user)
    );
    for bad in [
        &b"not-json"[..],
        br#"{"version":2,"refreshToken":"refresh"}"#,
        br#"{"version":1,"refreshToken":""}"#,
        br#"{"version":1}"#,
        br#"{"version":1,"refreshToken":"r","userID":5}"#,
    ] {
        assert_eq!(OidcGrant::from_record(bad), None);
    }
}

#[test]
fn loopback_redirects_work_for_desktop_sign_in() {
    let redirect = "http://127.0.0.1:53682/callback";
    let attempt = begin_sign_in(&server(), redirect, &FixedEntropy::counting()).unwrap();
    assert_eq!(attempt.redirect().scheme(), "http");
    let state = state_of(&attempt);
    let code = attempt
        .authorization_code(&format!("{redirect}?code=c1&state={state}"))
        .unwrap();
    assert_eq!(code.expose(), "c1");
    assert!(
        attempt
            .authorization_code(&format!(
                "http://127.0.0.1:1/callback?code=c1&state={state}"
            ))
            .is_err(),
        "another port is another redirect"
    );
    for bad in [
        "https://example.com/cb",
        "http://localhost:53682/cb",
        "ai.omnigent.ios:/oauth/callback?x=1",
        "nodots:/cb",
    ] {
        assert_eq!(
            begin_sign_in(&server(), bad, &FixedEntropy::counting()),
            Err(OidcError::RedirectNotAccepted { host: HOST.into() }),
            "{bad}"
        );
    }
    assert_eq!(
        begin_sign_in(&server(), IOS_NATIVE_REDIRECT_URI, &FixedEntropy::failing()),
        Err(OidcError::BrowserUnavailable { host: HOST.into() })
    );
    assert!(!format!("{attempt:?}").contains(&state));
}

#[test]
fn oidc_server_reports_its_parts_and_refuses_other_schemes() {
    let server = server();
    assert_eq!(server.origin(), "http://localhost:6767");
    assert_eq!(server.host(), HOST);
    assert_eq!(attempt().server(), &server);
    assert_eq!(
        OidcServer::from_url(Url::parse("ftp://example.com").unwrap()),
        Err(OidcError::InvalidServerUrl)
    );
}

#[test]
fn oidc_forgetting_an_unreadable_grant_says_so_and_still_deletes() {
    let credentials = credentials();
    credentials
        .store()
        .insert(&server().grant_key(), b"not a grant");
    let forgotten = block_on(credentials.forget_grant(&server()));
    assert_eq!(forgotten.revocation, None);
    assert_eq!(
        forgotten.load_error,
        Some(OidcError::InvalidGrantRecord { host: HOST.into() })
    );
    assert_eq!(credentials.store().value(&server().grant_key()), None);

    credentials.store().fail_get.set(true);
    let forgotten = block_on(credentials.forget_grant(&server()));
    assert!(matches!(
        forgotten.load_error,
        Some(OidcError::Store { .. })
    ));
}

#[test]
fn oidc_a_token_that_cannot_be_a_header_is_rejected_without_a_request() {
    let credentials = credentials();
    let token = SecretString::new("bad token");
    assert_eq!(
        block_on(credentials.is_accepted(&server(), &token, SessionPresentation::Bearer)),
        Err(OidcError::SessionRejected { host: HOST.into() })
    );
    assert_eq!(credentials.transport().take().len(), 0);
}

#[test]
fn oidc_settling_a_finished_flight_wakes_nobody_and_keeps_the_new_state() {
    let flight = Flight {
        id: 1,
        cancelled: AtomicBool::new(false),
        state: Mutex::new(FlightState::Abandoned),
    };
    flight.settle(FlightState::Done(Err(OidcError::Cancelled)));
    assert!(matches!(
        *lock(&flight.state),
        FlightState::Done(Err(OidcError::Cancelled))
    ));
}

#[test]
fn oidc_a_revoke_route_the_server_cannot_serve_fails_without_a_request() {
    let credentials = credentials();
    let outcome = block_on(credentials.revoke_at(
        PendingRevocation {
            server: server(),
            grant: grant("refresh", None),
        },
        "no-leading-slash",
    ));
    assert_eq!(
        outcome,
        RevokeOutcome::Failed(NetworkCause::Transport(TransportError::Other {
            message: "server URL has no revoke endpoint".into(),
        }))
    );
    assert_eq!(credentials.transport.requests.borrow().len(), 0);
}
