//! Pure decisions behind a host's OIDC session lifecycle: which pages are auth routes, which
//! cookies are the server's session cookie, when to renew, and what to tell the user.
//!
//! Port of web/ios `OidcWebSession`, `OidcAuthRoute`, `OidcRenewalGuard`,
//! `OidcSignOutGenerations` and `OidcSessionToken.sessionCookie`. The cookie jar and web view stay
//! in Swift; these functions take plain cookie descriptions.

use std::collections::HashMap;

use url::Url;

use super::errors::OidcError;
use super::oidc::{OidcServer, OidcSession};
use crate::server_url;

/// A background renewal that could not reach the server tries again after this.
pub const RETRY_DELAY_MS: u64 = 30_000;
/// A sign-in request this soon after a renewal means the server rejected the renewed session.
pub const REJECTED_RENEWAL_WINDOW_MS: u64 = 15_000;

/// The server routes a host handles itself instead of loading them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OidcAuthRoute {
    /// `<mount>/auth/login`.
    Login,
    /// `<mount>/auth/logout`.
    Logout,
}

impl OidcAuthRoute {
    /// The route `url` is under `server`'s mount, or `None` for any other page or origin.
    #[must_use]
    pub fn for_url(url: &Url, server: &Url) -> Option<Self> {
        if server_url::origin(url) != server_url::origin(server) {
            return None;
        }
        let mount = server_url::mount_path(server);
        let path = url.path();
        let route = path.strip_prefix(mount)?;
        match route {
            "/auth/login" => Some(Self::Login),
            "/auth/logout" => Some(Self::Logout),
            _ => None,
        }
    }
}

/// Whether `url` is an app page of `server`: same origin, under its mount, not an auth route.
#[must_use]
pub fn is_page(url: &Url, server: &Url) -> bool {
    if server_url::origin(url) != server_url::origin(server)
        || OidcAuthRoute::for_url(url, server).is_some()
    {
        return false;
    }
    let mount = server_url::mount_path(server);
    let path = url.path();
    mount.is_empty()
        || path == mount
        || path
            .strip_prefix(mount)
            .is_some_and(|rest| rest.starts_with('/'))
}

/// `SameSite` policy of a cookie the core asks the host to install.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SameSite {
    /// `Lax`.
    Lax,
}

/// A session cookie for the host to install. `Debug` is redacted.
#[derive(Clone, PartialEq, Eq)]
pub struct SessionCookie {
    /// Cookie name.
    pub name: String,
    /// The session token.
    pub value: super::SecretString,
    /// Host-only domain (no leading dot), lower case.
    pub domain: String,
    /// Always `/`.
    pub path: String,
    /// `Secure`; true exactly for https servers.
    pub secure: bool,
    /// `HttpOnly`; always true.
    pub http_only: bool,
    /// `SameSite`.
    pub same_site: SameSite,
    /// Expiry in ms since the Unix epoch; `None` is a session-only cookie.
    pub expires_at_ms: Option<u64>,
}

impl std::fmt::Debug for SessionCookie {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionCookie")
            .field("name", &self.name)
            .field("domain", &self.domain)
            .field("secure", &self.secure)
            .finish_non_exhaustive()
    }
}

/// The server's session cookie carrying `session`: host-only, `/`, `HttpOnly`, `SameSite=Lax`, and
/// `Secure` on https. `None` when the token is not cookie-safe.
#[must_use]
pub fn session_cookie(
    session: &OidcSession,
    name: &str,
    server: &OidcServer,
) -> Option<SessionCookie> {
    if !super::is_header_safe_token(session.token.expose()) {
        return None;
    }
    let domain = server.url().host_str()?.to_ascii_lowercase();
    Some(SessionCookie {
        name: name.to_owned(),
        value: session.token.clone(),
        domain,
        path: "/".into(),
        secure: server.is_https(),
        http_only: true,
        same_site: SameSite::Lax,
        expires_at_ms: session.expires_at_ms,
    })
}

/// The session cookie the deprecated ticket flow installs: `__Host-ap_session` and `Secure` on
/// https, `ap_session` on http. `None` for a token that is not JWT-shaped.
#[must_use]
pub fn ticket_session_cookie(
    server: &OidcServer,
    token: &super::SecretString,
) -> Option<SessionCookie> {
    if !super::ticket::is_jwt_shaped(token.expose()) {
        return None;
    }
    let name = if server.is_https() {
        "__Host-ap_session"
    } else {
        "ap_session"
    };
    session_cookie(
        &OidcSession {
            token: token.clone(),
            expires_at_ms: None,
        },
        name,
        server,
    )
}

/// A cookie as the host's jar reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredCookie {
    /// Name.
    pub name: String,
    /// Whether the value is non-empty (the value itself never needs to cross into the core).
    pub has_value: bool,
    /// Domain as stored, possibly with a leading dot.
    pub domain: String,
    /// Path; empty means `/`.
    pub path: String,
    /// `Secure`.
    pub secure: bool,
    /// Expiry in ms since the Unix epoch; `None` for a session cookie.
    pub expires_at_ms: Option<u64>,
}

/// Whether a browser would send `cookie` as `server`'s session cookie (RFC 6265): the name, the
/// server's host, `Secure` only to https, a path covering the server's API, and unexpired.
#[must_use]
pub fn is_session_cookie(cookie: &StoredCookie, name: &str, server: &Url, now_ms: u64) -> bool {
    let Some(host) = server.host_str().map(str::to_ascii_lowercase) else {
        return false;
    };
    let Some(request_path) = server_url::endpoint(server, "/v1/me") else {
        return false;
    };
    cookie.name == name
        && cookie.has_value
        && cookie.domain.trim_matches('.').eq_ignore_ascii_case(&host)
        && (!cookie.secure || server.scheme() == "https")
        && path_matches(&cookie.path, request_path.path())
        && cookie.expires_at_ms.is_none_or(|expiry| expiry > now_ms)
}

/// RFC 6265 section 5.1.4 path-match.
#[must_use]
pub fn path_matches(cookie_path: &str, request_path: &str) -> bool {
    let cookie_path = if cookie_path.is_empty() {
        "/"
    } else {
        cookie_path
    };
    if request_path == cookie_path {
        return true;
    }
    request_path
        .strip_prefix(cookie_path)
        .is_some_and(|rest| cookie_path.ends_with('/') || rest.starts_with('/'))
}

/// Indices of the cookies in `cookies` that `server` would receive as its session cookie.
#[must_use]
pub fn session_cookies(
    cookies: &[StoredCookie],
    name: &str,
    server: &Url,
    now_ms: u64,
) -> Vec<usize> {
    cookies
        .iter()
        .enumerate()
        .filter(|(_, cookie)| is_session_cookie(cookie, name, server, now_ms))
        .map(|(index, _)| index)
        .collect()
}

/// The index of the server's live session cookie, if the jar holds one it would receive.
#[must_use]
pub fn live_session_cookie(
    cookies: &[StoredCookie],
    name: &str,
    server: &Url,
    now_ms: u64,
) -> Option<usize> {
    session_cookies(cookies, name, server, now_ms)
        .into_iter()
        .next()
}

/// A renewal failure worth remembering: it deleted the grant, so a later prompt would otherwise
/// only see "no stored grant".
#[must_use]
pub fn remembered_renewal_cause(error: &OidcError) -> Option<OidcError> {
    matches!(
        error,
        OidcError::GrantExpired { .. } | OidcError::GrantRejected { .. }
    )
    .then(|| error.clone())
}

/// Whether a failed connect should keep relaunch from reopening the server: only when the server
/// refused the sign-in, as reopening would show the same refusal again.
#[must_use]
pub const fn stops_auto_opening(error: Option<&OidcError>) -> bool {
    matches!(error, Some(OidcError::SignInRefused { .. }))
}

/// The error to explain at the next prompt: a remembered cause replaces "no stored grant".
#[must_use]
pub fn reauthentication_cause(error: &OidcError, remembered: Option<&OidcError>) -> OidcError {
    match (error, remembered) {
        (OidcError::NoStoredGrant { .. }, Some(remembered)) => remembered.clone(),
        _ => error.clone(),
    }
}

/// The "Sign in again?" message for a session that cannot be renewed. `None` stands for a
/// non-OIDC error (such as a cancelled task), which reads as "sign in to continue".
#[must_use]
pub fn reauthentication_message(error: Option<&OidcError>, host: &str) -> String {
    match error {
        Some(error) if !error.is_network_failure() => error.to_string(),
        _ => OidcError::NoStoredGrant {
            host: host.to_owned(),
        }
        .to_string(),
    }
}

/// The Connect screen message after a sign-out; `complete` is false when the grant survived.
#[must_use]
pub fn signed_out_message(host: &str, complete: bool) -> String {
    if complete {
        format!("You're signed out of {host}.")
    } else {
        format!(
            "Couldn't finish signing out of {host}; its saved sign-in may still be used. Connect, \
             then sign out again."
        )
    }
}

/// The reason to keep when the user closes a sign-in sheet that a failed renewal opened: an
/// expired, ended or refused session. `None` when there was simply no sign-in to renew.
#[must_use]
pub fn cancelled_sign_in_cause(renewal_error: Option<&OidcError>) -> Option<OidcError> {
    match renewal_error {
        Some(
            error @ (OidcError::GrantExpired { .. }
            | OidcError::GrantRejected { .. }
            | OidcError::SessionRejected { .. }),
        ) => Some(error.clone()),
        _ => None,
    }
}

/// Stops renew-and-reload loops: the page asking to sign in again this soon after a renewal means
/// the server rejected the renewed session.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RenewalGuard {
    last_recovery_at_ms: Option<u64>,
}

impl RenewalGuard {
    /// Records a sign-in request and whether to answer it with a renewal. A request that joins a
    /// renewal still in flight is always answered by it, and restarts the window.
    pub const fn should_renew(&mut self, now_ms: u64, renewal_pending: bool) -> bool {
        if !renewal_pending
            && let Some(last) = self.last_recovery_at_ms
            && now_ms.saturating_sub(last) < REJECTED_RENEWAL_WINDOW_MS
        {
            return false;
        }
        self.last_recovery_at_ms = Some(now_ms);
        true
    }
}

/// Per-origin sign-out count, so a renewal or sign-in that started before a sign-out cannot
/// reinstall the session afterwards.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SignOutGenerations {
    generations: HashMap<String, u64>,
}

impl SignOutGenerations {
    /// The generation to capture when work for `origin` starts.
    #[must_use]
    pub fn current(&self, origin: &str) -> u64 {
        self.generations.get(origin).copied().unwrap_or(0)
    }

    /// Records a sign-out of `origin`.
    pub fn sign_out(&mut self, origin: &str) {
        let generation = self.generations.entry(origin.to_owned()).or_insert(0);
        *generation = generation.wrapping_add(1);
    }

    /// Whether work that captured `generation` may still act for `origin`.
    #[must_use]
    pub fn is_current(&self, generation: u64, origin: &str) -> bool {
        self.current(origin) == generation
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::SecretString;

    fn url(raw: &str) -> Url {
        Url::parse(raw).unwrap()
    }

    fn route(address: &str, server: &str) -> Option<OidcAuthRoute> {
        OidcAuthRoute::for_url(&url(address), &url(server))
    }

    #[test]
    fn oidc_auth_route_matches_login_logout_at_root() {
        let server = "https://omnigent.example.com";
        assert_eq!(
            route("https://omnigent.example.com/auth/login", server),
            Some(OidcAuthRoute::Login)
        );
        assert_eq!(
            route(
                "https://omnigent.example.com/auth/login?next=%2Fc%2Fx",
                server
            ),
            Some(OidcAuthRoute::Login)
        );
        assert_eq!(
            route("https://omnigent.example.com/auth/logout", server),
            Some(OidcAuthRoute::Logout)
        );
        assert_eq!(
            route("https://OMNIGENT.example.com/auth/logout", server),
            Some(OidcAuthRoute::Logout)
        );
    }

    #[test]
    fn oidc_auth_route_matches_only_under_mount() {
        let server = "https://example.com/omnigent/";
        assert_eq!(
            route("https://example.com/omnigent/auth/login", server),
            Some(OidcAuthRoute::Login)
        );
        assert_eq!(
            route("https://example.com/omnigent/auth/logout", server),
            Some(OidcAuthRoute::Logout)
        );
        assert_eq!(route("https://example.com/auth/login", server), None);
        assert_eq!(route("https://example.com/other/auth/login", server), None);
    }

    #[test]
    fn oidc_auth_route_ignores_other_pages_and_origins() {
        for other in [
            "https://omnigent.example.com/",
            "https://omnigent.example.com/c/conv_1",
            "https://omnigent.example.com/auth/login/",
            "https://omnigent.example.com/auth/cli-login",
            "https://omnigent.example.com/v1/auth/login",
            "http://omnigent.example.com/auth/login",
            "https://omnigent.example.com:8443/auth/login",
            "https://idp.example.com/auth/login",
        ] {
            assert_eq!(
                route(other, "https://omnigent.example.com"),
                None,
                "{other}"
            );
        }
    }

    #[test]
    fn oidc_is_page_under_mount_excludes_auth_routes() {
        let server = url("https://example.com/omnigent");
        assert!(is_page(&url("https://example.com/omnigent"), &server));
        assert!(is_page(
            &url("https://example.com/omnigent/c/conv_1?x=1"),
            &server
        ));
        assert!(!is_page(&url("https://example.com/other"), &server));
        assert!(!is_page(&url("https://example.com/omnigenty/c/x"), &server));
        assert!(!is_page(
            &url("https://example.com/omnigent/auth/login"),
            &server
        ));
        assert!(!is_page(&url("https://idp.example.com/omnigent"), &server));
    }

    #[test]
    fn oidc_renewal_guard_rejects_within_15s() {
        let mut guard = RenewalGuard::default();
        assert!(guard.should_renew(1_000_000, false));
        assert!(!guard.should_renew(1_014_900, false));
    }

    #[test]
    fn oidc_renewal_guard_allows_after_window() {
        let mut guard = RenewalGuard::default();
        assert!(guard.should_renew(1_000_000, false));
        assert!(guard.should_renew(1_015_000, false));
    }

    #[test]
    fn oidc_renewal_guard_joins_pending_and_restarts_window() {
        let mut guard = RenewalGuard::default();
        assert!(guard.should_renew(1_000_000, false));
        assert!(guard.should_renew(1_001_000, true));
        // The joined request restarts the window.
        assert!(!guard.should_renew(1_015_000, false));
    }

    #[test]
    fn oidc_sign_out_generation_invalidates_prior_work() {
        let mut generations = SignOutGenerations::default();
        let origin = "https://omnigent.example.com";
        let started = generations.current(origin);
        assert!(generations.is_current(started, origin));
        generations.sign_out(origin);
        assert!(!generations.is_current(started, origin));
        assert!(generations.is_current(generations.current(origin), origin));
    }

    #[test]
    fn oidc_sign_out_generation_is_per_origin() {
        let mut generations = SignOutGenerations::default();
        let other = "https://other.example.com";
        let started = generations.current(other);
        generations.sign_out("https://omnigent.example.com");
        assert!(generations.is_current(started, other));
    }

    const NOW: u64 = 1_000_000_000;

    fn cookie(
        name: &str,
        host: &str,
        expires_in_ms: i64,
        secure: bool,
        path: &str,
    ) -> StoredCookie {
        StoredCookie {
            name: name.into(),
            has_value: true,
            domain: host.into(),
            path: path.into(),
            secure,
            expires_at_ms: Some(NOW.saturating_add_signed(expires_in_ms)),
        }
    }

    #[test]
    fn oidc_live_session_cookie_matches_name_host_expiry() {
        let server = url("https://omnigent.example.com/");
        let cookies = [
            cookie(
                "__Host-ap_session",
                "omnigent.example.com",
                -1_000,
                false,
                "/",
            ),
            cookie("__Host-ap_session", "other.example.com", 60_000, false, "/"),
            cookie("ap_session", "omnigent.example.com", 60_000, false, "/"),
            cookie(
                "__Host-ap_session",
                ".omnigent.example.com",
                60_000,
                false,
                "/",
            ),
        ];
        assert_eq!(
            live_session_cookie(&cookies, "__Host-ap_session", &server, NOW),
            Some(3)
        );
        assert_eq!(
            session_cookies(&cookies, "__Host-ap_session", &server, NOW),
            vec![3]
        );
        let empty = StoredCookie {
            has_value: false,
            ..cookies[3].clone()
        };
        assert!(!is_session_cookie(
            &empty,
            "__Host-ap_session",
            &server,
            NOW
        ));
    }

    #[test]
    fn oidc_secure_cookie_not_offered_to_http() {
        let secure = [cookie("ap_session", "localhost", 60_000, true, "/")];
        assert_eq!(
            live_session_cookie(&secure, "ap_session", &url("http://localhost:6767/"), NOW),
            None
        );
        assert_eq!(
            live_session_cookie(&secure, "ap_session", &url("https://localhost:8443/"), NOW),
            Some(0)
        );
    }

    #[test]
    fn oidc_cookie_path_must_cover_mount() {
        let mounted = url("https://omnigent.example.com/omnigent/");
        let cookies = [
            cookie(
                "ap_session",
                "omnigent.example.com",
                60_000,
                false,
                "/other",
            ),
            cookie("ap_session", "omnigent.example.com", 60_000, false, "/omni"),
            cookie(
                "ap_session",
                "omnigent.example.com",
                60_000,
                false,
                "/omnigent",
            ),
        ];
        assert_eq!(
            session_cookies(&cookies, "ap_session", &mounted, NOW),
            vec![2]
        );
        assert_eq!(
            live_session_cookie(
                &cookies[2..],
                "ap_session",
                &url("https://omnigent.example.com/"),
                NOW
            ),
            None
        );
        assert!(path_matches("/", "/v1/me"));
        assert!(path_matches("", "/v1/me"));
        assert!(path_matches("/omnigent/", "/omnigent/v1/me"));
        assert!(!path_matches("/omnigent", "/omnigentx/v1/me"));
    }

    #[test]
    fn oidc_session_cookie_attributes() {
        let secure_server = OidcServer::new("https://Omnigent.Example.com/omnigent/").unwrap();
        let secure = session_cookie(
            &OidcSession {
                token: SecretString::new("session-1"),
                expires_at_ms: Some(NOW + 3_600_000),
            },
            "__Host-ap_session",
            &secure_server,
        )
        .unwrap();
        assert_eq!(secure.name, "__Host-ap_session");
        assert_eq!(secure.value.expose(), "session-1");
        assert_eq!(secure.domain, "omnigent.example.com");
        assert_eq!(secure.path, "/");
        assert!(secure.secure && secure.http_only);
        assert_eq!(secure.same_site, SameSite::Lax);
        assert_eq!(secure.expires_at_ms, Some(NOW + 3_600_000));
        assert!(!format!("{secure:?}").contains("session-1"));

        let plain = session_cookie(
            &OidcSession {
                token: SecretString::new("session-2"),
                expires_at_ms: None,
            },
            "ap_session",
            &OidcServer::new("http://localhost:6767").unwrap(),
        )
        .unwrap();
        assert_eq!(plain.domain, "localhost");
        assert!(!plain.secure && plain.http_only);
        assert_eq!(plain.expires_at_ms, None, "session-only");
        assert_eq!(
            session_cookie(
                &OidcSession {
                    token: SecretString::new("a;b"),
                    expires_at_ms: None
                },
                "ap_session",
                &secure_server
            ),
            None
        );
    }

    #[test]
    fn oidc_https_cookie_host_prefix_and_secure() {
        let server = OidcServer::new("https://example.com").unwrap();
        let cookie = ticket_session_cookie(&server, &SecretString::new("aaa.bbb.ccc")).unwrap();
        assert_eq!(cookie.name, "__Host-ap_session");
        assert_eq!(cookie.domain, "example.com");
        assert_eq!(cookie.path, "/");
        assert!(cookie.secure);
        assert_eq!(
            ticket_session_cookie(&server, &SecretString::new("aaa.bbb.ccc; Domain=x")),
            None
        );
    }

    #[test]
    fn oidc_http_cookie_unprefixed() {
        let server = OidcServer::new("http://localhost:6767").unwrap();
        let cookie = ticket_session_cookie(&server, &SecretString::new("aaa.bbb.ccc")).unwrap();
        assert_eq!(cookie.name, "ap_session");
        assert!(!cookie.secure);
    }

    const HOST: &str = "omnigent.example.com";

    fn all_errors() -> Vec<OidcError> {
        let host = || HOST.to_owned();
        vec![
            OidcError::Cancelled,
            OidcError::Network {
                host: host(),
                cause: crate::auth::errors::NetworkCause::Status(500),
            },
            OidcError::GrantExpired { host: host() },
            OidcError::GrantRejected { host: host() },
            OidcError::NoStoredGrant { host: host() },
            OidcError::SessionRejected { host: host() },
            OidcError::BrowserUnavailable { host: host() },
            OidcError::InvalidCallback { host: host() },
            OidcError::ExchangeFailed {
                host: host(),
                cause: crate::auth::errors::ExchangeFailure::InvalidToken,
            },
            OidcError::InvalidGrantRecord { host: host() },
        ]
    }

    #[test]
    fn oidc_only_refused_sign_in_stops_auto_open() {
        for description in [Some("not permitted".to_owned()), None] {
            assert!(stops_auto_opening(Some(&OidcError::SignInRefused {
                host: HOST.into(),
                description
            })));
        }
        assert!(!stops_auto_opening(None));
        for other in all_errors() {
            assert!(!stops_auto_opening(Some(&other)), "{other:?}");
        }
    }

    #[test]
    fn oidc_renewal_lost_grant_explains_next_prompt() {
        let expired = OidcError::GrantExpired { host: HOST.into() };
        let rejected = OidcError::GrantRejected { host: HOST.into() };
        let no_grant = OidcError::NoStoredGrant { host: HOST.into() };
        assert_eq!(remembered_renewal_cause(&expired), Some(expired.clone()));
        assert_eq!(remembered_renewal_cause(&rejected), Some(rejected));
        assert_eq!(
            remembered_renewal_cause(&OidcError::Network {
                host: HOST.into(),
                cause: crate::auth::errors::NetworkCause::Status(500)
            }),
            None
        );
        assert_eq!(remembered_renewal_cause(&no_grant), None);
        let later = reauthentication_cause(&no_grant, Some(&expired));
        assert_eq!(
            reauthentication_message(Some(&later), HOST),
            "Your sign-in to omnigent.example.com has expired. Sign in again to continue."
        );
        let session_rejected = OidcError::SessionRejected { host: HOST.into() };
        assert_eq!(
            reauthentication_cause(&session_rejected, Some(&expired)),
            session_rejected
        );
        assert_eq!(reauthentication_cause(&no_grant, None), no_grant);
    }

    #[test]
    fn oidc_reauthentication_messages_name_cause() {
        assert_eq!(
            reauthentication_message(Some(&OidcError::GrantExpired { host: HOST.into() }), HOST),
            "Your sign-in to omnigent.example.com has expired. Sign in again to continue."
        );
        assert_eq!(
            reauthentication_message(Some(&OidcError::GrantRejected { host: HOST.into() }), HOST),
            "omnigent.example.com ended your session. Sign in again to continue."
        );
        assert_eq!(
            reauthentication_message(None, HOST),
            "Sign in to omnigent.example.com to continue."
        );
        let network = OidcError::Network {
            host: HOST.into(),
            cause: crate::auth::errors::NetworkCause::Status(502),
        };
        assert!(network.is_network_failure());
        assert_eq!(
            reauthentication_message(Some(&network), HOST),
            "Sign in to omnigent.example.com to continue."
        );
        assert!(!OidcError::GrantExpired { host: HOST.into() }.is_network_failure());
        assert_eq!(
            signed_out_message(HOST, true),
            "You're signed out of omnigent.example.com."
        );
        assert!(signed_out_message(HOST, false).starts_with("Couldn't finish signing out"));
    }

    #[test]
    fn oidc_cancelled_sign_in_keeps_only_ended_reason() {
        for cause in [
            OidcError::GrantExpired { host: HOST.into() },
            OidcError::GrantRejected { host: HOST.into() },
            OidcError::SessionRejected { host: HOST.into() },
        ] {
            assert_eq!(cancelled_sign_in_cause(Some(&cause)), Some(cause.clone()));
        }
        for quiet in [
            Some(OidcError::NoStoredGrant { host: HOST.into() }),
            Some(OidcError::InvalidGrantRecord { host: HOST.into() }),
            Some(OidcError::Cancelled),
            None,
        ] {
            assert_eq!(cancelled_sign_in_cause(quiet.as_ref()), None, "{quiet:?}");
        }
    }

    #[test]
    fn oidc_renewal_delay_leaves_60s_margin() {
        use crate::auth::renewal_delay_ms;
        assert_eq!(
            renewal_delay_ms(NOW + 8 * 3_600_000, NOW),
            8 * 3_600_000 - 60_000
        );
        assert_eq!(renewal_delay_ms(NOW + 100_000, NOW), 80_000);
        assert_eq!(renewal_delay_ms(NOW, NOW), 0);
        assert_eq!(renewal_delay_ms(NOW - 5_000, NOW), 0);
    }

    #[test]
    fn oidc_renewal_delay_bounded_to_max() {
        use crate::auth::{MAX_RENEWAL_DELAY_MS, renewal_delay_ms};
        for expires_at in [NOW + 20_000_000_000_000, u64::MAX] {
            assert_eq!(renewal_delay_ms(expires_at, NOW), MAX_RENEWAL_DELAY_MS);
        }
    }
}
