//! Workspace session creation tests, ported from web/ios `DatabricksSessionClientTests`.

use std::cell::RefCell;
use std::future::{Future, ready};

use futures::executor::block_on;
use url::Url;

use super::*;
use crate::auth::SecretString;
use crate::auth::databricks::config::OAuthConfiguration;
use crate::auth::databricks::issuer::OAuthIssuer;

const NOW: u64 = 1_700_000_000_000;
const WORKSPACE: &str = "https://workspace.cloud.databricks.com";
const SHARED: &str = "https://shared.cloud.databricks.com";

type Handler = Box<dyn Fn(&HttpRequest) -> HttpResponse>;

/// Answers every request with `handler` and records it.
struct Server {
    handler: Handler,
    requests: RefCell<Vec<HttpRequest>>,
}

impl Server {
    fn new(handler: impl Fn(&HttpRequest) -> HttpResponse + 'static) -> Self {
        Self {
            handler: Box::new(handler),
            requests: RefCell::new(Vec::new()),
        }
    }
}

impl HttpTransport for Server {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, TransportError>> {
        let response = (self.handler)(&request);
        self.requests.borrow_mut().push(request);
        ready(Ok(response))
    }
}

fn response(status: u16, headers: &[(&str, &str)]) -> HttpResponse {
    HttpResponse {
        status,
        headers: headers
            .iter()
            .map(|(name, value)| HttpHeader::new(*name, *value))
            .collect(),
        body: Vec::new(),
    }
}

fn session_cookie(domain: Option<&str>, path: &str, value: &str) -> String {
    let mut header =
        format!("DBAUTH={value}; Path={path}; Secure; HttpOnly; SameSite=Lax; Max-Age=3600");
    if let Some(domain) = domain {
        header.push_str("; Domain=");
        header.push_str(domain);
    }
    header
}

fn default_cookie() -> String {
    session_cookie(None, "/", "synthetic-session")
}

fn configuration() -> OAuthConfiguration {
    OAuthConfiguration::new(
        "test-client",
        "https://login.databricks.com/mobile-redirect",
    )
    .unwrap()
}

fn context(raw: &str) -> WebContext {
    WebContext::new(&Url::parse(raw).unwrap(), &configuration()).unwrap()
}

fn tokens(issuer: Option<&str>) -> DatabricksTokens {
    DatabricksTokens {
        access_token: SecretString::new("test-access"),
        refresh_token: SecretString::new("test-refresh"),
        expires_at_ms: NOW + 3_600_000,
        issuer: issuer.map(|raw| OAuthIssuer::parse(raw).unwrap()),
    }
}

fn url_of(request: &HttpRequest) -> Url {
    Url::parse(&request.url).unwrap()
}

fn header<'a>(request: &'a HttpRequest, name: &str) -> Option<&'a str> {
    request
        .headers
        .iter()
        .find(|header| header.name.eq_ignore_ascii_case(name))
        .map(|header| header.value.as_str())
}

fn create(
    server: &Server,
    context: &WebContext,
    tokens: &DatabricksTokens,
) -> Result<WorkspaceSession, DatabricksError> {
    block_on(create_workspace_session(server, context, tokens, NOW))
}

#[test]
fn session_create_sends_bearer_then_cookie_only() {
    let server = Server::new(|request| {
        let url = url_of(request);
        if url.path() == "/auth/session/create" {
            assert_eq!(header(request, "Authorization"), Some("Bearer test-access"));
            assert_eq!(header(request, "Cookie"), None);
            let next = url
                .query_pairs()
                .find(|(key, _)| key == "next_url")
                .unwrap()
                .1;
            assert_eq!(next, "/omnigent/c/abc?o=123");
            return response(
                302,
                &[
                    ("Location", "/omnigent/c/abc?o=123"),
                    ("Set-Cookie", &default_cookie()),
                ],
            );
        }
        assert_eq!(url.path(), "/omnigent/c/abc");
        assert_eq!(header(request, "Authorization"), None);
        assert_eq!(header(request, "Cookie"), Some("DBAUTH=synthetic-session"));
        response(200, &[])
    });
    let context = context(&format!("{WORKSPACE}/omnigent/c/abc?o=123#message"));
    let session = create(&server, &context, &tokens(None)).unwrap();
    assert_eq!(&session.page_url, context.page_url());
    let cookie = &session.cookies[0];
    assert!(cookie.http_only);
    assert!(cookie.secure);
    assert_eq!(cookie.expires_at_ms, Some(NOW + 3_600_000));
    assert_eq!(server.requests.borrow().len(), 2);
}

#[test]
fn session_redirect_canonical_to_shared_host_keeps_context() {
    let server = Server::new(|request| {
        let url = url_of(request);
        if url.host_str() == Some("workspace.cloud.databricks.com") {
            assert_eq!(url.path(), "/auth/session/create");
            assert_eq!(header(request, "Authorization"), Some("Bearer test-access"));
            return response(302, &[("Location", &format!("{SHARED}/omnigent?o=123"))]);
        }
        assert_eq!(header(request, "Authorization"), None);
        assert_eq!(header(request, "Cookie"), None);
        response(
            200,
            &[(
                "Set-Cookie",
                &session_cookie(
                    Some("shared.cloud.databricks.com"),
                    "/",
                    "synthetic-session",
                ),
            )],
        )
    });
    let context = context(&format!("{WORKSPACE}/omnigent/c/abc#message"));
    let session = create(
        &server,
        &context,
        &tokens(Some(&format!("{WORKSPACE}/oidc"))),
    )
    .unwrap();
    assert_eq!(
        session.page_url.as_str(),
        format!("{SHARED}/omnigent/c/abc?o=123#message")
    );
    assert_eq!(session.workspace_id.as_deref(), Some("123"));
    assert_eq!(session.cookies[0].domain, ".shared.cloud.databricks.com");
    assert_eq!(context.scope().workspace_origin(), WORKSPACE);
    assert!(session.navigation_url(context.page_url()).is_some());
}

#[test]
fn session_issuer_origin_choice_workspace_vs_account() {
    let server = Server::new(|request| {
        let url = url_of(request);
        if url.host_str() == Some("issuer.cloud.databricks.com") {
            assert_eq!(url.path(), "/auth/session/create");
            return response(302, &[("Location", &format!("{SHARED}/omnigent?o=123"))]);
        }
        response(200, &[("Set-Cookie", &default_cookie())])
    });
    let context = context(&format!("{SHARED}/omnigent?o=123"));
    let workspace = create(
        &server,
        &context,
        &tokens(Some("https://issuer.cloud.databricks.com/oidc")),
    )
    .unwrap();
    assert_eq!(&workspace.page_url, context.page_url());
    assert_eq!(
        url_of(&server.requests.borrow()[0]).host_str(),
        Some("issuer.cloud.databricks.com")
    );
    server.requests.borrow_mut().clear();
    let account = create(
        &server,
        &context,
        &tokens(Some(
            "https://issuer.cloud.databricks.com/oidc/accounts/test-account",
        )),
    )
    .unwrap();
    assert_eq!(&account.page_url, context.page_url());
    assert_eq!(
        url_of(&server.requests.borrow()[0]).host_str(),
        Some("shared.cloud.databricks.com")
    );
}

#[test]
fn session_account_grant_requires_workspace_context() {
    let server = Server::new(|_| panic!("no session request without workspace context"));
    assert_eq!(
        create(
            &server,
            &context(WORKSPACE),
            &tokens(Some(
                "https://accounts.cloud.databricks.com/oidc/accounts/test-account"
            )),
        ),
        Err(DatabricksError::WorkspaceRequired)
    );
}

#[test]
fn session_blocks_unsafe_redirects_and_workspace_changes() {
    for (location, expected) in [
        (
            "https://example.org/omnigent",
            DatabricksError::UnsafeRedirect,
        ),
        (
            "http://workspace.databricks.com/omnigent",
            DatabricksError::UnsafeRedirect,
        ),
        ("/omnigent?o=456", DatabricksError::WorkspaceChanged),
        (
            "//user@workspace.databricks.com/omnigent",
            DatabricksError::UnsafeRedirect,
        ),
    ] {
        let server = Server::new(move |_| response(302, &[("Location", location)]));
        assert_eq!(
            create(
                &server,
                &context(&format!("{WORKSPACE}/omnigent?o=123")),
                &tokens(None)
            ),
            Err(expected),
            "{location}"
        );
    }
}

#[test]
fn session_redirect_loop_bounded_at_nine_requests() {
    let server = Server::new(|_| response(302, &[("Location", "/again")]));
    assert_eq!(
        create(&server, &context(WORKSPACE), &tokens(None)),
        Err(DatabricksError::UnsafeRedirect)
    );
    assert_eq!(server.requests.borrow().len(), 9);
}

#[test]
fn session_missing_expired_insecure_cookie_fails_closed() {
    for cookie in [
        None,
        Some("DBAUTH=; Path=/; Secure; HttpOnly"),
        Some("DBAUTH=expired; Path=/; Secure; HttpOnly; Max-Age=0"),
        Some("DBAUTH=expired; Path=/; Secure; HttpOnly; Expires=Wed, 21 Oct 2015 07:28:00 GMT"),
        Some("DBAUTH=insecure; Path=/; HttpOnly"),
        Some("DBAUTH=readable; Path=/; Secure"),
    ] {
        let server = Server::new(move |request| {
            if url_of(request).path() == "/auth/session/create" {
                return response(302, &[("Location", "/omnigent")]);
            }
            cookie.map_or_else(
                || response(200, &[]),
                |cookie| response(200, &[("Set-Cookie", cookie)]),
            )
        });
        let result = create(&server, &context(WORKSPACE), &tokens(None));
        assert!(
            matches!(
                result,
                Err(DatabricksError::MissingCookie | DatabricksError::UnsafeCookie)
            ),
            "{cookie:?}: {result:?}"
        );
    }
}

#[test]
fn session_expired_deletion_cookie_precedes_fresh() {
    let server = Server::new(|request| {
        if url_of(request).path() == "/auth/session/create" {
            return response(
                302,
                &[
                    ("Location", "/omnigent"),
                    ("Set-Cookie", "DBAUTH=; Path=/; Max-Age=0"),
                ],
            );
        }
        response(200, &[("Set-Cookie", &default_cookie())])
    });
    let session = create(&server, &context(WORKSPACE), &tokens(None)).unwrap();
    let values: Vec<&str> = session
        .cookies
        .iter()
        .filter(|cookie| cookie.name == "DBAUTH")
        .map(|cookie| cookie.value.as_str())
        .collect();
    assert_eq!(values, ["synthetic-session"]);
}

#[test]
fn session_cookie_domain_widening_rejected_and_path_match() {
    let url = Url::parse(&format!("{WORKSPACE}/omnigent")).unwrap();
    for domain in [
        "example.org",
        "sibling.cloud.databricks.com",
        ".com",
        "databricks.com.example.org",
    ] {
        let reply = response(
            200,
            &[("Set-Cookie", &session_cookie(Some(domain), "/", "v"))],
        );
        assert_eq!(
            response_cookies(&reply, &url, NOW),
            Err(DatabricksError::UnsafeCookie),
            "{domain}"
        );
    }
    let reply = response(
        200,
        &[("Set-Cookie", &session_cookie(None, "/omnigent", "v"))],
    );
    let cookie = response_cookies(&reply, &url, NOW).unwrap().remove(0);
    let at = |raw: &str| Url::parse(raw).unwrap();
    assert!(cookie.applies_to(&at(&format!("{WORKSPACE}/omnigent/c/abc")), NOW));
    assert!(!cookie.applies_to(&at(&format!("{WORKSPACE}/omnigent-other")), NOW));
    assert!(!cookie.applies_to(&at("https://sibling.cloud.databricks.com/omnigent"), NOW));
    let http = Url::parse("http://workspace.cloud.databricks.com/omnigent").unwrap();
    assert_eq!(
        response_cookies(&reply, &http, NOW),
        Err(DatabricksError::InvalidSessionResponse)
    );
}

#[test]
fn session_error_status_and_login_landing_not_success() {
    for status in [401, 403, 500] {
        let server = Server::new(move |_| response(status, &[]));
        assert_eq!(
            create(&server, &context(WORKSPACE), &tokens(None)),
            Err(DatabricksError::Rejected { status })
        );
    }
    let server = Server::new(|request| {
        if url_of(request).path() == "/auth/session/create" {
            return response(302, &[("Location", "/login")]);
        }
        response(200, &[("Set-Cookie", &default_cookie())])
    });
    assert_eq!(
        create(&server, &context(WORKSPACE), &tokens(None)),
        Err(DatabricksError::UnexpectedLanding)
    );
}

/// Fails every request with its error.
struct Failing(TransportError);

impl HttpTransport for Failing {
    fn send(&self, _: HttpRequest) -> impl Future<Output = Result<HttpResponse, TransportError>> {
        ready(Err(self.0.clone()))
    }
}

#[test]
fn http_dates_parse_and_transport_failures_keep_their_kind() {
    assert_eq!(
        parse_http_date("Wed, 21 Oct 2015 07:28:00 GMT"),
        Some(1_445_412_480_000)
    );
    assert_eq!(parse_http_date("not a date"), None);
    let offline = TransportError::Offline {
        message: "down".into(),
    };
    assert_eq!(
        block_on(create_workspace_session(
            &Failing(offline.clone()),
            &context(WORKSPACE),
            &tokens(None),
            NOW
        )),
        Err(DatabricksError::NetworkUnavailable(offline))
    );
    assert_eq!(
        block_on(create_workspace_session(
            &Failing(TransportError::Cancelled),
            &context(WORKSPACE),
            &tokens(None),
            NOW
        )),
        Err(DatabricksError::Cancelled)
    );
}

#[test]
fn cookie_dates_out_of_range_are_rejected_instead_of_overflowing() {
    assert_eq!(parse_http_date("Thu, 01 Jan 1970 00:00:01 GMT"), Some(1000));
    assert_eq!(
        parse_http_date("Fri, 31 Dec 9999 23:59:60 GMT"),
        Some(253_402_300_800_000)
    );
    for bad in [
        "Thu, 01 Jan 18446744073709551615 00:00:00 GMT",
        "Thu, 01 Feb 10000 00:00:00 GMT",
        "Thu, 01 Jan 1969 00:00:00 GMT",
        "Thu, 01 Jan 2026 18446744073709551615:00:00 GMT",
        "Thu, 01 Jan 2026 00:18446744073709551615:00 GMT",
        "Thu, 01 Jan 2026 00:00:18446744073709551615 GMT",
        "Thu, 18446744073709551615 Jan 2026 00:00:00 GMT",
        "Thu, 00 Jan 2026 00:00:00 GMT",
        "Thu, 32 Jan 2026 00:00:00 GMT",
        "Thu, 01 Foo 2026 00:00:00 GMT",
        "Thu, 01 Jan 2026 24:00:00 GMT",
        "Thu, 01 Jan 2026 00:60:00 GMT",
        "Thu, 01 Jan 2026 00:00:61 GMT",
        "Thu, 01 Jan 2026 00:00:00 PST",
        "Thu, 01 Jan 2026 00:00:00",
        "Thu, 01 Jan 2026",
        "01 Jan 2026 00:00:00 GMT",
        "",
    ] {
        assert_eq!(parse_http_date(bad), None, "{bad}");
    }
}
