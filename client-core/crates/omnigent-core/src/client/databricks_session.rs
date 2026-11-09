//! Databricks workspace session creation: trade a bearer for the `DBAUTH` cookie a workspace
//! page needs.
//!
//! Port of web/ios `DatabricksSessionClient.create(context:tokens:)` and its cookie checks. This
//! is the [`BootstrapStep::CreateSession`](crate::auth::databricks::bootstrap::BootstrapStep)
//! step of the workspace bootstrap:
//!
//! 1. `GET <origin>/auth/session/create?next_url=<page path and query>` with the bearer. The
//!    origin is the issuer's workspace for a workspace (`/oidc`) issuer, else the page's own; an
//!    account issuer needs an `o=` workspace on the page.
//! 2. Follow up to eight redirects by hand (the transport never follows them), sending only the
//!    cookies collected so far and never the bearer again. Every hop must stay on an https
//!    Databricks workspace host and in the same `o=` workspace.
//! 3. Land on the page, the workspace UI root, the create route, or a known origin's root, with a
//!    live `Secure`, `HttpOnly` `DBAUTH` cookie for the page.
//!
//! Every `Set-Cookie` must be scoped to the responding workspace host (or a parent workspace
//! domain it belongs to); a cookie for any other domain fails the whole creation.

use std::collections::BTreeSet;

use url::Url;

use crate::auth::databricks::error::DatabricksError;
use crate::auth::databricks::scope::CredentialScope;
use crate::auth::databricks::tokens::DatabricksTokens;
use crate::auth::databricks::web_context::{
    SESSION_COOKIE_NAME, SessionCookie, WebContext, WorkspaceSession, is_login_path,
};
use crate::auth::mode::ServerAuthentication;
use crate::http::{HttpHeader, HttpRequest, HttpResponse, HttpTransport, TransportError};
use crate::server_url::WORKSPACE_UI_PATH;

/// Redirects followed after the first request; the ninth response must not redirect.
pub const MAX_SESSION_REDIRECTS: usize = 8;

const REDIRECT_STATUSES: [u16; 5] = [301, 302, 303, 307, 308];

fn origin(url: &Url) -> String {
    url.origin().ascii_serialization()
}

/// The path without a trailing slash (except the root), as Foundation's `URL.path` reports it.
fn plain_path(url: &Url) -> &str {
    let path = url.path();
    match path.strip_suffix('/') {
        Some(trimmed) if !trimmed.is_empty() => trimmed,
        Some(_) => "/",
        None => path,
    }
}

/// Where the bearer is exchanged: the issuer's workspace for a workspace issuer, else the page's.
fn exchange_origin(context: &WebContext, tokens: &DatabricksTokens) -> Url {
    tokens
        .issuer
        .as_ref()
        .filter(|issuer| issuer.url().path() == "/oidc")
        .and_then(|issuer| CredentialScope::new(issuer.url(), context.configuration()).ok())
        .map_or_else(
            || context.scope().workspace_origin_url().clone(),
            |scope| scope.workspace_origin_url().clone(),
        )
}

/// Creates the workspace session for `context` with `tokens`. `now_ms` is the host's wall-clock
/// time, for cookie expiry.
///
/// # Errors
///
/// [`DatabricksError::InvalidSessionResponse`] for unusable tokens or a login page context;
/// [`DatabricksError::WorkspaceRequired`] for an account grant without `o=`;
/// [`DatabricksError::Cancelled`] and [`DatabricksError::NetworkUnavailable`] from the transport;
/// [`DatabricksError::UnsafeCookie`], [`DatabricksError::UnsafeRedirect`],
/// [`DatabricksError::WorkspaceChanged`], [`DatabricksError::Rejected`],
/// [`DatabricksError::UnexpectedLanding`] and [`DatabricksError::MissingCookie`].
#[allow(
    clippy::future_not_send,
    reason = "Send-ness follows the host transport; WASM transports are !Send by design"
)]
pub async fn create_workspace_session<T: HttpTransport>(
    transport: &T,
    context: &WebContext,
    tokens: &DatabricksTokens,
    now_ms: u64,
) -> Result<WorkspaceSession, DatabricksError> {
    let page_url = context.page_url();
    if !tokens.is_valid() || is_login_path(plain_path(page_url)) {
        return Err(DatabricksError::InvalidSessionResponse);
    }
    if tokens
        .issuer
        .as_ref()
        .is_some_and(|issuer| issuer.url().path().starts_with("/oidc/accounts/"))
        && context.scope().workspace_id().is_none()
    {
        return Err(DatabricksError::WorkspaceRequired);
    }
    let start = exchange_origin(context, tokens);
    let next_url = page_url.query().map_or_else(
        || page_url.path().to_owned(),
        |query| format!("{}?{query}", page_url.path()),
    );
    let mut current = start
        .join("/auth/session/create")
        .map_err(|_| DatabricksError::InvalidSessionResponse)?;
    current.query_pairs_mut().append_pair("next_url", &next_url);
    let page_scope = CredentialScope::new(page_url, context.configuration())?;
    let mut workspace_id = context
        .scope()
        .workspace_id()
        .or_else(|| page_scope.workspace_id())
        .map(str::to_owned);
    let mut jar: Vec<SessionCookie> = Vec::new();
    let mut updates: Vec<SessionCookie> = Vec::new();
    for hop in 0..=MAX_SESSION_REDIRECTS {
        let bearer = (hop == 0).then_some(tokens);
        let response = transport
            .send(hop_request(&current, &jar, bearer, now_ms))
            .await
            .map_err(|error| match error {
                TransportError::Cancelled => DatabricksError::Cancelled,
                other => DatabricksError::NetworkUnavailable(other),
            })?;
        absorb(
            &mut jar,
            &mut updates,
            response_cookies(&response, &current, now_ms)?,
            now_ms,
        );
        if REDIRECT_STATUSES.contains(&response.status) {
            if hop >= MAX_SESSION_REDIRECTS {
                return Err(DatabricksError::UnsafeRedirect);
            }
            current = follow(&response, &current, context, &mut workspace_id)?;
            continue;
        }
        if !(200..=299).contains(&response.status) {
            return Err(DatabricksError::Rejected {
                status: response.status,
            });
        }
        return land(
            context,
            &start,
            &current,
            workspace_id,
            updates,
            &jar,
            now_ms,
        );
    }
    Err(DatabricksError::UnsafeRedirect)
}

/// One hop's `GET`: the bearer on the first hop only, then the applicable cookies, longest path
/// first.
fn hop_request(
    url: &Url,
    jar: &[SessionCookie],
    bearer: Option<&DatabricksTokens>,
    now_ms: u64,
) -> HttpRequest {
    let mut headers = vec![HttpHeader::new("Accept", "text/html")];
    if let Some(tokens) = bearer {
        headers.push(HttpHeader::new(
            "Authorization",
            format!("Bearer {}", tokens.access_token.expose()),
        ));
    }
    let mut applicable: Vec<&SessionCookie> = jar
        .iter()
        .filter(|cookie| cookie.applies_to(url, now_ms))
        .collect();
    applicable.sort_by_key(|cookie| std::cmp::Reverse(cookie.path.len()));
    if !applicable.is_empty() {
        let header = applicable
            .iter()
            .map(|cookie| format!("{}={}", cookie.name, cookie.value))
            .collect::<Vec<_>>()
            .join("; ");
        headers.push(HttpHeader::new("Cookie", header));
    }
    HttpRequest {
        method: "GET".into(),
        url: url.to_string(),
        headers,
        body: None,
    }
}

/// Records `cookies`: each replaces its slot in the updates to install, and joins the jar sent
/// on later hops unless it is expired or an empty `DBAUTH`.
fn absorb(
    jar: &mut Vec<SessionCookie>,
    updates: &mut Vec<SessionCookie>,
    cookies: Vec<SessionCookie>,
    now_ms: u64,
) {
    for cookie in cookies {
        updates.retain(|existing| !existing.same_slot(&cookie));
        jar.retain(|existing| !existing.same_slot(&cookie));
        let live = cookie.expires_at_ms.is_none_or(|expiry| expiry > now_ms);
        if live && (cookie.name != SESSION_COOKIE_NAME || !cookie.value.is_empty()) {
            jar.push(cookie.clone());
        }
        updates.push(cookie);
    }
}

/// The next hop of a redirect: on an https workspace host, in the same `o=` workspace, with no
/// fragment, the canonical host and the default port.
fn follow(
    response: &HttpResponse,
    current: &Url,
    context: &WebContext,
    workspace_id: &mut Option<String>,
) -> Result<Url, DatabricksError> {
    let next = response
        .header("Location")
        .and_then(|location| current.join(location).ok())
        .ok_or(DatabricksError::UnsafeRedirect)?;
    let next_scope = CredentialScope::new(&next, context.configuration())
        .map_err(|_| DatabricksError::UnsafeRedirect)?;
    if let Some(id) = next_scope.workspace_id() {
        if workspace_id.as_deref().is_some_and(|known| known != id) {
            return Err(DatabricksError::WorkspaceChanged);
        }
        *workspace_id = Some(id.to_owned());
    }
    let mut normalized = next;
    normalized.set_fragment(None);
    normalized
        .set_host(Some(next_scope.host()))
        .map_err(|_| DatabricksError::UnsafeRedirect)?;
    normalized
        .set_port(None)
        .map_err(|()| DatabricksError::UnsafeRedirect)?;
    Ok(normalized)
}

fn land(
    context: &WebContext,
    start: &Url,
    current: &Url,
    workspace_id: Option<String>,
    updates: Vec<SessionCookie>,
    jar: &[SessionCookie],
    now_ms: u64,
) -> Result<WorkspaceSession, DatabricksError> {
    let page_url = context.page_url();
    let current_origin = origin(current);
    let known_origin =
        current_origin == context.scope().workspace_origin() || current_origin == origin(start);
    let path = plain_path(current);
    let at_app_path =
        path == plain_path(page_url) || path == WORKSPACE_UI_PATH || path == "/auth/session/create";
    if !(at_app_path || (known_origin && (path.is_empty() || path == "/"))) {
        return Err(DatabricksError::UnexpectedLanding);
    }
    let mut page = current.clone();
    page.set_path(page_url.path());
    page.set_query(page_url.query());
    if context.scope().workspace_id().is_none()
        && let Some(id) = &workspace_id
    {
        page.query_pairs_mut().append_pair("o", id);
    }
    page.set_fragment(page_url.fragment());
    let has_session = jar.iter().any(|cookie| {
        cookie.name == SESSION_COOKIE_NAME
            && !cookie.value.is_empty()
            && cookie.applies_to(&page, now_ms)
    });
    if !has_session {
        return Err(DatabricksError::MissingCookie);
    }
    let allowed_origins = BTreeSet::from([
        context.scope().workspace_origin().to_owned(),
        origin(start),
        origin(page_url),
        origin(&page),
    ]);
    Ok(WorkspaceSession {
        page_url: page,
        cookies: updates,
        allowed_origins,
        configuration: context.configuration().clone(),
        workspace_id,
    })
}

/// The cookies `response` (to a request for `url`) sets, validated.
///
/// Each must be scoped to the responding workspace host or a parent workspace domain of it, with
/// a sane name, value and path; a live `DBAUTH` must be `Secure` and `HttpOnly`.
///
/// # Errors
///
/// [`DatabricksError::InvalidSessionResponse`] for a non-https `url`;
/// [`DatabricksError::UnsafeCookie`] for any cookie that breaks the rules.
pub fn response_cookies(
    response: &HttpResponse,
    url: &Url,
    now_ms: u64,
) -> Result<Vec<SessionCookie>, DatabricksError> {
    let host = url
        .host_str()
        .filter(|_| url.scheme() == "https")
        .map(str::to_ascii_lowercase)
        .ok_or(DatabricksError::InvalidSessionResponse)?;
    let mut cookies = Vec::new();
    for header in &response.headers {
        if !header.name.eq_ignore_ascii_case("set-cookie") {
            continue;
        }
        let Some(cookie) = parse_set_cookie(&header.value, url, now_ms) else {
            continue;
        };
        let domain = cookie
            .domain
            .strip_prefix('.')
            .unwrap_or(&cookie.domain)
            .to_ascii_lowercase();
        let scoped = ServerAuthentication::for_host(Some(&domain))
            == ServerAuthentication::DatabricksWorkspace
            && (host == domain
                || (cookie.domain.starts_with('.') && host.ends_with(&format!(".{domain}"))));
        let sane = cookie.path.starts_with('/')
            && !cookie.name.is_empty()
            && !cookie.name.chars().any(char::is_control)
            && !cookie.value.chars().any(char::is_control);
        if !scoped || !sane {
            return Err(DatabricksError::UnsafeCookie);
        }
        let deletion =
            cookie.value.is_empty() || cookie.expires_at_ms.is_some_and(|expiry| expiry <= now_ms);
        if cookie.name == SESSION_COOKIE_NAME && !deletion && !(cookie.secure && cookie.http_only) {
            return Err(DatabricksError::UnsafeCookie);
        }
        cookies.push(cookie);
    }
    Ok(cookies)
}

/// The RFC 6265 default path of `url`: its directory, or `/`.
fn default_path(url: &Url) -> String {
    let path = url.path();
    match path.rfind('/') {
        Some(0) | None => "/".to_owned(),
        Some(index) => path.get(..index).unwrap_or("/").to_owned(),
    }
}

/// Parses one `Set-Cookie` value the way Foundation does for these headers: a `Domain`
/// attribute gains a leading dot; without one the cookie is host-only. `Max-Age` wins over
/// `Expires`. `None` for a header without `name=value`.
fn parse_set_cookie(value: &str, url: &Url, now_ms: u64) -> Option<SessionCookie> {
    let mut parts = value.split(';');
    let (name, cookie_value) = parts.next()?.split_once('=')?;
    let mut cookie = SessionCookie {
        name: name.trim().to_owned(),
        value: cookie_value.trim().to_owned(),
        domain: url.host_str()?.to_ascii_lowercase(),
        path: default_path(url),
        secure: false,
        http_only: false,
        expires_at_ms: None,
    };
    let mut max_age = None;
    let mut expires = None;
    for attribute in parts {
        let (key, argument) = attribute.split_once('=').map_or_else(
            || (attribute.trim(), ""),
            |(key, argument)| (key.trim(), argument.trim()),
        );
        match key.to_ascii_lowercase().as_str() {
            "domain" if !argument.is_empty() => {
                let bare = argument.trim_start_matches('.').to_ascii_lowercase();
                cookie.domain = format!(".{bare}");
            }
            "path" if argument.starts_with('/') => argument.clone_into(&mut cookie.path),
            "secure" => cookie.secure = true,
            "httponly" => cookie.http_only = true,
            "max-age" => max_age = argument.parse::<i64>().ok(),
            "expires" => expires = parse_http_date(argument),
            _ => {}
        }
    }
    cookie.expires_at_ms = match (max_age, expires) {
        (Some(seconds), _) if seconds <= 0 => Some(now_ms),
        (Some(seconds), _) => Some(
            now_ms.saturating_add(
                u64::try_from(seconds)
                    .unwrap_or(u64::MAX)
                    .saturating_mul(1000),
            ),
        ),
        (None, expires) => expires,
    };
    Some(cookie)
}

/// An IMF-fixdate (`Wdy, DD Mon YYYY HH:MM:SS GMT`) as ms since the Unix epoch.
fn parse_http_date(text: &str) -> Option<u64> {
    let (_, rest) = text.split_once(", ")?;
    let mut fields = rest.split(' ');
    let day: u64 = fields.next()?.parse().ok()?;
    let month = match fields.next()? {
        "Jan" => 1,
        "Feb" => 2,
        "Mar" => 3,
        "Apr" => 4,
        "May" => 5,
        "Jun" => 6,
        "Jul" => 7,
        "Aug" => 8,
        "Sep" => 9,
        "Oct" => 10,
        "Nov" => 11,
        "Dec" => 12,
        _ => return None,
    };
    let year: u64 = fields.next()?.parse().ok()?;
    let mut clock = fields.next()?.split(':');
    let hour: u64 = clock.next()?.parse().ok()?;
    let minute: u64 = clock.next()?.parse().ok()?;
    let second: u64 = clock.next()?.parse().ok()?;
    // A cookie date from a server: fields out of range would overflow the arithmetic below.
    if fields.next()? != "GMT"
        || !(1970..=9999).contains(&year)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    // Days from the civil date (Howard Hinnant's algorithm), for years from 1970 on.
    let shifted_year = if month <= 2 { year - 1 } else { year };
    let era = shifted_year / 400;
    let year_of_era = shifted_year - era * 400;
    let month_index = if month > 2 { month - 3 } else { month + 9 };
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = (era * 146_097 + day_of_era).checked_sub(719_468)?;
    let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second;
    seconds.checked_mul(1000)
}

#[cfg(test)]
#[path = "databricks_session_tests.rs"]
mod tests;
