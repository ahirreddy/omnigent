//! Native OIDC sign-in: PKCE against the server's `/auth/login` native parameters, the
//! `POST /auth/native-token` exchange, and the per-origin refresh grant behind
//! `POST /oauth/token` and `POST /oauth/revoke`.
//!
//! Port of web/ios `OidcCredentials` against the current server (`omnigent/server/routes/auth.py`
//! `native_token`, `routes/device_auth.py` token/revoke):
//!
//! 1. [`begin_sign_in`] builds the authorize URL (`native_redirect_uri`, `native_state`,
//!    `code_challenge`, `code_challenge_method=S256`) under the server's mount. The host presents
//!    it with `ASWebAuthenticationSession` and hands back the callback URL.
//! 2. [`OidcSignInAttempt::authorization_code`] validates the callback: this redirect URI, the
//!    exact `state` once, then either the server's refusal or exactly one non-empty `code`.
//! 3. [`OidcCredentials::complete_sign_in`] exchanges the code with the verifier, stores the
//!    refresh grant (versioned record, keyed by origin) or forgets a stale one, and returns the
//!    session token with its absolute expiry.
//! 4. [`OidcCredentials::refresh`] mints a new session from the stored grant, one request per
//!    origin however many callers ask; [`renewal_delay_ms`](super::renewal_delay_ms) says when.
//! 5. [`OidcCredentials::sign_out`] forgets the grant locally first, then revokes it.
//!
//! No request follows a redirect: the host transport returns every 3xx as the final response.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::task::{Context, Poll, Waker};

use serde_json::{Map, Value, json};
use url::Url;

use super::errors::{ExchangeFailure, NetworkCause, OidcError, RevokeOutcome};
use super::oidc_session::SignOutGenerations;
use super::pkce::{self, CODE_CHALLENGE_METHOD, PkcePair};
use super::{
    EntropySource, SecretString, SecureStore, SecureStoreError, SecureStoreKey,
    is_header_safe_token,
};
use crate::http::{HttpHeader, HttpRequest, HttpResponse, HttpTransport, TransportError};
use crate::server_url;

pub use omnigent_protocol::manifest::IOS_NATIVE_REDIRECT_URI;

/// Longest session lifetime accepted from the server: the 400-day cookie cap of RFC 6265bis.
pub const MAX_SESSION_LIFETIME_MS: u64 = 400 * 24 * 3_600_000;
/// Version of the stored grant record.
pub const GRANT_RECORD_VERSION: u64 = 1;

/// A server URL resolved to its credential origin, host label and mount-aware endpoints.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OidcServer {
    url: Url,
    origin: String,
    host: String,
}

impl OidcServer {
    /// Parses a normalized server URL (see [`server_url::normalize`]).
    ///
    /// # Errors
    ///
    /// [`OidcError::InvalidServerUrl`] for anything but an http(s) URL with a host.
    pub fn new(server_url: &str) -> Result<Self, OidcError> {
        Self::from_url(Url::parse(server_url).map_err(|_| OidcError::InvalidServerUrl)?)
    }

    /// See [`OidcServer::new`].
    ///
    /// # Errors
    ///
    /// [`OidcError::InvalidServerUrl`].
    pub fn from_url(url: Url) -> Result<Self, OidcError> {
        if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none_or(str::is_empty) {
            return Err(OidcError::InvalidServerUrl);
        }
        Ok(Self {
            origin: server_url::origin(&url),
            host: server_url::host_label(&url),
            url,
        })
    }

    /// The server URL as given.
    #[must_use]
    pub const fn url(&self) -> &Url {
        &self.url
    }

    /// `scheme://host[:port]`, lower-cased: the key for grants and refresh flights.
    #[must_use]
    pub fn origin(&self) -> &str {
        &self.origin
    }

    /// `host[:port]`, for messages.
    #[must_use]
    pub fn host(&self) -> &str {
        &self.host
    }

    /// Whether the server is https (its session cookie is `__Host-` and `Secure`).
    #[must_use]
    pub fn is_https(&self) -> bool {
        self.url.scheme() == "https"
    }

    /// `route` under the server's mount.
    ///
    /// # Errors
    ///
    /// [`OidcError::InvalidServerUrl`] for a relative route.
    pub fn endpoint(&self, route: &str) -> Result<Url, OidcError> {
        server_url::endpoint(&self.url, route).ok_or(OidcError::InvalidServerUrl)
    }

    /// Where this server's refresh grant is stored.
    #[must_use]
    pub fn grant_key(&self) -> SecureStoreKey {
        SecureStoreKey::new(SecureStoreKey::OIDC_NAMESPACE, self.origin.clone())
    }
}

/// A redirect URI the native sign-in delivers its code to: a private-use scheme
/// (`ai.omnigent.ios:/oauth/callback`) or an RFC 8252 loopback URI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeRedirect {
    uri: String,
    url: Url,
}

impl NativeRedirect {
    /// Validates `uri`'s shape. Whether the server accepts it is the manifest's
    /// `native_redirect_uris` (see `ManifestAuth::accepts_native_redirect`).
    ///
    /// `None` for anything else.
    #[must_use]
    pub fn parse(uri: &str) -> Option<Self> {
        let url = Url::parse(uri).ok()?;
        let loopback = omnigent_protocol::manifest::is_loopback_redirect_uri(uri);
        let private_use = !matches!(url.scheme(), "http" | "https")
            && url.scheme().contains('.')
            && url.host().is_none()
            && url.path().starts_with('/');
        if !(loopback || private_use)
            || url.query().is_some()
            || url.fragment().is_some()
            || !url.username().is_empty()
        {
            return None;
        }
        Some(Self {
            uri: uri.to_owned(),
            url,
        })
    }

    /// The URI exactly as registered.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.uri
    }

    /// The callback scheme to hand `ASWebAuthenticationSession` (`ai.omnigent.ios`), or `http`.
    #[must_use]
    pub fn scheme(&self) -> &str {
        self.url.scheme()
    }

    /// Whether `callback` was delivered to this redirect: same scheme, host, port and path, no
    /// userinfo.
    #[must_use]
    pub fn matches(&self, callback: &Url) -> bool {
        callback.scheme() == self.url.scheme()
            && callback.host() == self.url.host()
            && callback.port() == self.url.port()
            && callback.path() == self.url.path()
            && callback.username().is_empty()
            && callback.password().is_none()
    }
}

/// One sign-in in progress. `Debug` is redacted: the state and verifier are secrets.
#[derive(Clone, PartialEq, Eq)]
pub struct OidcSignInAttempt {
    server: OidcServer,
    redirect: NativeRedirect,
    state: SecretString,
    pkce: PkcePair,
    authorize_url: String,
}

impl std::fmt::Debug for OidcSignInAttempt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OidcSignInAttempt")
            .field("origin", &self.server.origin)
            .field("redirect", &self.redirect.uri)
            .finish_non_exhaustive()
    }
}

/// Starts a sign-in to `server` that delivers its code to `redirect_uri`.
///
/// # Errors
///
/// [`OidcError::RedirectNotAccepted`] for a malformed redirect URI, and
/// [`OidcError::BrowserUnavailable`] when the host cannot supply randomness.
pub fn begin_sign_in(
    server: &OidcServer,
    redirect_uri: &str,
    entropy: &dyn EntropySource,
) -> Result<OidcSignInAttempt, OidcError> {
    let redirect =
        NativeRedirect::parse(redirect_uri).ok_or_else(|| OidcError::RedirectNotAccepted {
            host: server.host.clone(),
        })?;
    let unavailable = |_| OidcError::BrowserUnavailable {
        host: server.host.clone(),
    };
    let pkce = PkcePair::generate(entropy).map_err(unavailable)?;
    let state = SecretString::new(pkce::random_value(entropy).map_err(unavailable)?);
    let mut login = server.endpoint("/auth/login")?;
    login
        .query_pairs_mut()
        .append_pair("native_redirect_uri", redirect.as_str())
        .append_pair("native_state", state.expose())
        .append_pair("code_challenge", &pkce.challenge)
        .append_pair("code_challenge_method", CODE_CHALLENGE_METHOD);
    Ok(OidcSignInAttempt {
        server: server.clone(),
        redirect,
        state,
        pkce,
        authorize_url: login.into(),
    })
}

impl OidcSignInAttempt {
    /// The page to open in the sign-in sheet.
    #[must_use]
    pub fn authorize_url(&self) -> &str {
        &self.authorize_url
    }

    /// The server.
    #[must_use]
    pub const fn server(&self) -> &OidcServer {
        &self.server
    }

    /// The redirect the sheet must capture.
    #[must_use]
    pub const fn redirect(&self) -> &NativeRedirect {
        &self.redirect
    }

    /// The code in a callback for this sign-in's redirect URI and exact `state`.
    ///
    /// # Errors
    ///
    /// [`OidcError::InvalidCallback`] for another URI, a missing, repeated or different `state`,
    /// a malformed query, or no single non-empty `code`; [`OidcError::SignInRefused`] with the
    /// server's `error_description` when the callback carries `error`.
    pub fn authorization_code(&self, callback: &str) -> Result<SecretString, OidcError> {
        let invalid = || OidcError::InvalidCallback {
            host: self.server.host.clone(),
        };
        let url = Url::parse(callback).map_err(|_| invalid())?;
        if !self.redirect.matches(&url) || url.fragment().is_some() {
            return Err(invalid());
        }
        let items = form_items(url.query()).ok_or_else(invalid)?;
        let states: Vec<_> = items.iter().filter(|(name, _)| name == "state").collect();
        if states.len() != 1
            || states.first().and_then(|(_, value)| value.as_deref()) != Some(self.state.expose())
        {
            return Err(invalid());
        }
        if items.iter().any(|(name, _)| name == "error") {
            let description = items
                .iter()
                .find(|(name, _)| name == "error_description")
                .and_then(|(_, value)| value.clone());
            return Err(OidcError::SignInRefused {
                host: self.server.host.clone(),
                description,
            });
        }
        let codes: Vec<_> = items.iter().filter(|(name, _)| name == "code").collect();
        match codes.as_slice() {
            [(_, Some(code))] if !code.is_empty() => Ok(SecretString::new(code.clone())),
            _ => Err(invalid()),
        }
    }

    /// `POST /auth/native-token` with the code, verifier and redirect URI.
    ///
    /// # Errors
    ///
    /// [`OidcError::InvalidServerUrl`].
    pub fn exchange_request(&self, code: &SecretString) -> Result<HttpRequest, OidcError> {
        form_post(
            &self.server,
            "/auth/native-token",
            &[
                ("code", code.expose()),
                ("code_verifier", self.pkce.verifier.expose()),
                ("redirect_uri", self.redirect.as_str()),
            ],
        )
    }
}

/// A query decoded as `application/x-www-form-urlencoded`.
///
/// RFC 6749 section 4.1.2 responses are built that way: `+` is a space, then percent-escapes
/// decode. `None` when an escape is malformed or decodes to invalid UTF-8. Empty pairs are
/// skipped; a pair without `=` has no value.
#[must_use]
pub fn form_items(query: Option<&str>) -> Option<Vec<(String, Option<String>)>> {
    let Some(query) = query.filter(|query| !query.is_empty()) else {
        return Some(Vec::new());
    };
    let mut items = Vec::new();
    for pair in query.split('&').filter(|pair| !pair.is_empty()) {
        let (name, value) = match pair.split_once('=') {
            Some((name, value)) => (name, Some(value)),
            None => (pair, None),
        };
        let name = form_decode(name)?;
        let value = match value {
            Some(value) => Some(form_decode(value)?),
            None => None,
        };
        items.push((name, value));
    }
    Some(items)
}

fn form_decode(raw: &str) -> Option<String> {
    let mut bytes = Vec::with_capacity(raw.len());
    let mut input = raw.bytes();
    while let Some(byte) = input.next() {
        match byte {
            b'+' => bytes.push(b' '),
            b'%' => {
                let high = hex_value(input.next()?)?;
                let low = hex_value(input.next()?)?;
                bytes.push((high << 4) | low);
            }
            other => bytes.push(other),
        }
    }
    String::from_utf8(bytes).ok()
}

const fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn form_post(
    server: &OidcServer,
    route: &str,
    fields: &[(&str, &str)],
) -> Result<HttpRequest, OidcError> {
    Ok(HttpRequest {
        method: "POST".into(),
        url: server.endpoint(route)?.into(),
        headers: vec![
            HttpHeader::new("Content-Type", "application/x-www-form-urlencoded"),
            HttpHeader::new("Accept", "application/json"),
        ],
        body: Some(pkce::form_body(fields)),
    })
}

/// A session token minted by sign-in or refresh. `Debug` is redacted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OidcSession {
    /// The session JWT: `Authorization: Bearer` or the session cookie value.
    pub token: SecretString,
    /// When the server said it expires, measured from the request time; `None` when unsaid.
    pub expires_at_ms: Option<u64>,
}

impl OidcSession {
    /// When to renew: see [`super::renewal_delay_ms`]. `None` without a known expiry.
    #[must_use]
    pub fn renewal_delay_ms(&self, now_ms: u64) -> Option<u64> {
        self.expires_at_ms
            .map(|expires_at| super::renewal_delay_ms(expires_at, now_ms))
    }
}

/// A stored refresh grant.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OidcGrant {
    /// The refresh token.
    pub refresh_token: SecretString,
    /// The server's user id at sign-in, when it said.
    pub user_id: Option<String>,
}

impl OidcGrant {
    /// The versioned record, byte-compatible with the web shell's Keychain item:
    /// `{"version":1,"refreshToken":"…","userID":"…"?}`.
    #[must_use]
    pub fn to_record(&self) -> Vec<u8> {
        let mut record = Map::new();
        record.insert("version".into(), json!(GRANT_RECORD_VERSION));
        record.insert("refreshToken".into(), json!(self.refresh_token.expose()));
        if let Some(user_id) = &self.user_id {
            record.insert("userID".into(), json!(user_id));
        }
        Value::Object(record).to_string().into_bytes()
    }

    /// Decodes a record.
    ///
    /// `None` for invalid JSON, another version, or a missing or empty refresh token.
    #[must_use]
    pub fn from_record(bytes: &[u8]) -> Option<Self> {
        let value: Value = serde_json::from_slice(bytes).ok()?;
        if value.get("version").and_then(Value::as_u64) != Some(GRANT_RECORD_VERSION) {
            return None;
        }
        let refresh_token = value
            .get("refreshToken")
            .and_then(Value::as_str)
            .filter(|token| !token.is_empty())?;
        let user_id = match value.get("userID") {
            None | Some(Value::Null) => None,
            Some(Value::String(id)) => Some(id.clone()),
            Some(_) => return None,
        };
        Some(Self {
            refresh_token: SecretString::new(refresh_token),
            user_id,
        })
    }
}

/// A completed sign-in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignedIn {
    /// The new session.
    pub session: OidcSession,
    /// The server's user id.
    pub user_id: Option<String>,
    /// The server issued no refresh grant, and forgetting an older one for this origin failed.
    /// The session works either way; the stale grant stays until the next sign-out.
    pub stale_grant_error: Option<SecureStoreError>,
}

/// A grant forgotten locally and still to be revoked on the server. `Debug` is redacted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingRevocation {
    server: OidcServer,
    grant: OidcGrant,
}

/// The local half of a sign-out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForgottenGrant {
    /// The grant to revoke, when one was stored and readable.
    pub revocation: Option<PendingRevocation>,
    /// Reading the stored grant failed, so it cannot be revoked (it is still deleted).
    pub load_error: Option<OidcError>,
    /// Deleting the stored grant failed: it may still be used. The sign-out is incomplete.
    pub delete_error: Option<OidcError>,
}

/// What a whole sign-out did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignOutReport {
    /// `None` when there was nothing to revoke.
    pub revocation: Option<RevokeOutcome>,
    /// See [`ForgottenGrant::load_error`].
    pub load_error: Option<OidcError>,
    /// See [`ForgottenGrant::delete_error`].
    pub delete_error: Option<OidcError>,
}

impl SignOutReport {
    /// Whether the grant is gone locally (the revoke is best effort).
    #[must_use]
    pub const fn is_complete(&self) -> bool {
        self.delete_error.is_none()
    }
}

/// How a session check presents the token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionPresentation<'a> {
    /// As the named session cookie (the web shell).
    Cookie(&'a str),
    /// As `Authorization: Bearer` (native API clients).
    Bearer,
}

/// The OIDC credential manager for every server, over the host transport and secure store.
#[derive(Debug)]
pub struct OidcCredentials<T, S> {
    transport: T,
    store: S,
    flights: Mutex<HashMap<String, Arc<Flight>>>,
    next_flight: AtomicU64,
    sign_outs: Mutex<SignOutGenerations>,
}

#[derive(Debug)]
struct Flight {
    id: u64,
    cancelled: AtomicBool,
    state: Mutex<FlightState>,
}

#[derive(Debug)]
enum FlightState {
    Running(Vec<Waker>),
    Done(Result<OidcSession, OidcError>),
    Abandoned,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    // Poisoning only follows a panic in another holder; the maps stay structurally valid.
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Flight {
    fn settle(&self, state: FlightState) {
        let previous = std::mem::replace(&mut *lock(&self.state), state);
        let wakers = match previous {
            FlightState::Running(wakers) => wakers,
            FlightState::Done(_) | FlightState::Abandoned => Vec::new(),
        };
        for waker in wakers {
            waker.wake();
        }
    }
}

/// Waits for another caller's refresh; `None` when that caller gave up before finishing.
struct JoinFlight(Arc<Flight>);

impl Future for JoinFlight {
    type Output = Option<Result<OidcSession, OidcError>>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut state = lock(&self.0.state);
        match &mut *state {
            FlightState::Running(wakers) => {
                if !wakers.iter().any(|waker| waker.will_wake(cx.waker())) {
                    wakers.push(cx.waker().clone());
                }
                Poll::Pending
            }
            FlightState::Done(result) => Poll::Ready(Some(result.clone())),
            FlightState::Abandoned => Poll::Ready(None),
        }
    }
}

/// Settles the leader's flight however its future ends, so joiners never hang.
struct Leader<'a> {
    flights: &'a Mutex<HashMap<String, Arc<Flight>>>,
    origin: String,
    flight: Arc<Flight>,
    finished: bool,
}

impl Leader<'_> {
    fn release(&self) {
        let mut flights = lock(self.flights);
        if flights
            .get(&self.origin)
            .is_some_and(|current| current.id == self.flight.id)
        {
            flights.remove(&self.origin);
        }
    }

    fn finish(mut self, result: &Result<OidcSession, OidcError>) {
        self.finished = true;
        self.release();
        self.flight.settle(FlightState::Done(result.clone()));
    }
}

impl Drop for Leader<'_> {
    fn drop(&mut self) {
        if !self.finished {
            self.release();
            self.flight.settle(FlightState::Abandoned);
        }
    }
}

fn network(server: &OidcServer, cause: NetworkCause) -> OidcError {
    OidcError::Network {
        host: server.host.clone(),
        cause,
    }
}

fn store_error(server: &OidcServer, error: SecureStoreError) -> OidcError {
    OidcError::Store {
        host: server.host.clone(),
        error,
    }
}

fn json_body(response: &HttpResponse) -> Option<Map<String, Value>> {
    match serde_json::from_slice(&response.body) {
        Ok(Value::Object(object)) => Some(object),
        _ => None,
    }
}

/// The session token under `key` in a 200 body, if it is safe for a header.
fn session_from(
    body: Option<&Map<String, Value>>,
    key: &str,
    requested_at_ms: u64,
) -> Option<OidcSession> {
    let body = body?;
    let token = body
        .get(key)
        .and_then(Value::as_str)
        .filter(|token| is_header_safe_token(token))?;
    let expires_at_ms = body
        .get("expires_in")
        .and_then(Value::as_f64)
        .filter(|seconds| seconds.is_finite() && *seconds > 0.0)
        .map(|seconds| {
            let lifetime = super::accounts::seconds_to_ms(seconds).min(MAX_SESSION_LIFETIME_MS);
            requested_at_ms.saturating_add(lifetime)
        });
    Some(OidcSession {
        token: SecretString::new(token),
        expires_at_ms,
    })
}

fn string_field(body: Option<&Map<String, Value>>, key: &str) -> Option<String> {
    body?
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

#[allow(
    clippy::future_not_send,
    reason = "Send-ness follows the host transport and store; WASM hosts are !Send by design"
)]
impl<T: HttpTransport, S: SecureStore> OidcCredentials<T, S> {
    /// A manager over the host's transport and secure store.
    pub fn new(transport: T, store: S) -> Self {
        Self {
            transport,
            store,
            flights: Mutex::new(HashMap::new()),
            sign_outs: Mutex::new(SignOutGenerations::default()),
            next_flight: AtomicU64::new(0),
        }
    }

    /// The transport.
    pub const fn transport(&self) -> &T {
        &self.transport
    }

    /// The store.
    pub const fn store(&self) -> &S {
        &self.store
    }

    async fn send(
        &self,
        server: &OidcServer,
        request: HttpRequest,
    ) -> Result<HttpResponse, OidcError> {
        self.transport
            .send(request)
            .await
            .map_err(|error| network(server, NetworkCause::Transport(error)))
    }

    /// Exchanges the callback's code and stores the server's refresh grant, or forgets an older
    /// one when the server issues none. `now_ms` is the request time the expiry is measured from.
    ///
    /// Drive this to completion once the callback arrives: the server burns the code on the first
    /// attempt, and the grant it returns is saved before this returns.
    ///
    /// # Errors
    ///
    /// The callback errors of [`OidcSignInAttempt::authorization_code`] (no request is sent);
    /// [`OidcError::Network`] when the server cannot be reached; [`OidcError::ExchangeFailed`]
    /// for any non-200 (a 3xx is never followed) or an unsafe token; and
    /// [`OidcError::GrantNotSaved`] when the store refuses the grant (it is then revoked);
    /// [`OidcError::Cancelled`] when a sign-out for the origin overtook the exchange (the grant
    /// is revoked, not kept).
    pub async fn complete_sign_in(
        &self,
        attempt: &OidcSignInAttempt,
        callback_url: &str,
        now_ms: u64,
    ) -> Result<SignedIn, OidcError> {
        let server = &attempt.server;
        let code = attempt.authorization_code(callback_url)?;
        let started = lock(&self.sign_outs).current(&server.origin);
        let signed_out_since = || !lock(&self.sign_outs).is_current(started, &server.origin);
        let response = self.send(server, attempt.exchange_request(&code)?).await?;
        let body = json_body(&response);
        let exchange_failed = |cause| OidcError::ExchangeFailed {
            host: server.host.clone(),
            cause,
        };
        if response.status != 200 {
            return Err(exchange_failed(ExchangeFailure::Status {
                status: response.status,
                error: string_field(body.as_ref(), "error"),
            }));
        }
        let session = session_from(body.as_ref(), "token", now_ms)
            .ok_or_else(|| exchange_failed(ExchangeFailure::InvalidToken))?;
        let user_id = string_field(body.as_ref(), "user_id");
        let mut stale_grant_error = None;
        if let Some(refresh_token) = string_field(body.as_ref(), "refresh_token") {
            let grant = OidcGrant {
                refresh_token: SecretString::new(refresh_token),
                user_id: user_id.clone(),
            };
            // The user signed out while the server was answering: this grant stays unsaved.
            // Revoking is best effort; nobody is left to tell how it went.
            if signed_out_since() {
                self.revoke(PendingRevocation {
                    server: server.clone(),
                    grant,
                })
                .await;
                return Err(OidcError::Cancelled);
            }
            if let Err(error) = self.store.set(server.grant_key(), grant.to_record()).await {
                // A grant that cannot be kept must not stay live on the server.
                let revocation = self
                    .revoke(PendingRevocation {
                        server: server.clone(),
                        grant,
                    })
                    .await;
                return Err(OidcError::GrantNotSaved {
                    host: server.host.clone(),
                    error,
                    revocation,
                });
            }
            if signed_out_since() {
                return Err(self.undo_save_after_sign_out(server, grant).await);
            }
        } else if let Err(error) = self.store.delete(server.grant_key()).await {
            stale_grant_error = Some(error);
        }
        Ok(SignedIn {
            session,
            user_id,
            stale_grant_error,
        })
    }

    /// Mints a session from the stored grant, with one request in flight per origin: callers
    /// that arrive while one is running share its result.
    ///
    /// # Errors
    ///
    /// [`OidcError::NoStoredGrant`] without a usable grant (no request is sent), or on a `404`;
    /// [`OidcError::GrantRejected`] (`invalid_grant`) and [`OidcError::GrantExpired`]
    /// (`expired_token`), after which the grant is forgotten; [`OidcError::Network`] for every
    /// other failure, which keeps the grant; [`OidcError::Store`]; and
    /// [`OidcError::Cancelled`] when a sign-out for the origin superseded the refresh.
    pub async fn refresh(
        &self,
        server: &OidcServer,
        now_ms: u64,
    ) -> Result<OidcSession, OidcError> {
        loop {
            let (flight, leads) = self.claim_flight(&server.origin);
            if leads {
                let leader = Leader {
                    flights: &self.flights,
                    origin: server.origin.clone(),
                    flight: Arc::clone(&flight),
                    finished: false,
                };
                let result = self.perform_refresh(server, now_ms, &flight).await;
                leader.finish(&result);
                return result;
            }
            if let Some(result) = JoinFlight(flight).await {
                return result;
            }
        }
    }

    /// The running flight for `origin` to join, or a new one this caller leads.
    fn claim_flight(&self, origin: &str) -> (Arc<Flight>, bool) {
        let mut flights = lock(&self.flights);
        if let Some(flight) = flights.get(origin) {
            let flight = Arc::clone(flight);
            drop(flights);
            return (flight, false);
        }
        let flight = Arc::new(Flight {
            id: self.next_flight.fetch_add(1, Ordering::Relaxed),
            cancelled: AtomicBool::new(false),
            state: Mutex::new(FlightState::Running(Vec::new())),
        });
        flights.insert(origin.to_owned(), Arc::clone(&flight));
        drop(flights);
        (flight, true)
    }

    async fn perform_refresh(
        &self,
        server: &OidcServer,
        now_ms: u64,
        flight: &Flight,
    ) -> Result<OidcSession, OidcError> {
        let no_grant = || OidcError::NoStoredGrant {
            host: server.host.clone(),
        };
        let stored = self
            .store
            .get(server.grant_key())
            .await
            .map_err(|error| store_error(server, error))?
            .ok_or_else(no_grant)?;
        let Some(grant) = OidcGrant::from_record(&stored) else {
            self.forget(server).await?;
            return Err(no_grant());
        };
        let request = form_post(
            server,
            "/oauth/token",
            &[
                ("grant_type", "refresh_token"),
                ("refresh_token", grant.refresh_token.expose()),
            ],
        )?;
        let response = self.send(server, request).await?;
        if flight.cancelled.load(Ordering::Acquire) {
            return Err(OidcError::Cancelled);
        }
        let body = json_body(&response);
        if response.status == 200 {
            let session = session_from(body.as_ref(), "access_token", now_ms)
                .ok_or_else(|| network(server, NetworkCause::InvalidToken))?;
            if let Some(rotated) = string_field(body.as_ref(), "refresh_token")
                .filter(|token| token != grant.refresh_token.expose())
            {
                let rotated = OidcGrant {
                    refresh_token: SecretString::new(rotated),
                    user_id: grant.user_id,
                };
                self.store
                    .set(server.grant_key(), rotated.to_record())
                    .await
                    .map_err(|error| store_error(server, error))?;
                if flight.cancelled.load(Ordering::Acquire) {
                    return Err(self.undo_save_after_sign_out(server, rotated).await);
                }
            }
            return Ok(session);
        }
        let dead = match (
            string_field(body.as_ref(), "error").as_deref(),
            response.status,
        ) {
            (Some("invalid_grant"), _) => OidcError::GrantRejected {
                host: server.host.clone(),
            },
            (Some("expired_token"), _) => OidcError::GrantExpired {
                host: server.host.clone(),
            },
            (_, 404) => no_grant(),
            (_, status) => return Err(network(server, NetworkCause::Status(status))),
        };
        // A dead grant: forget it so the next connect signs in through the sheet. If that fails
        // the grant was not forgotten, so report the store failure instead.
        self.forget(server).await?;
        Err(dead)
    }

    /// A sign-out's delete may have run before this grant's save landed, which would sign the
    /// user back in on the next launch. Returns why the sign-in or refresh ended.
    async fn undo_save_after_sign_out(&self, server: &OidcServer, grant: OidcGrant) -> OidcError {
        let forgotten = self.forget(server).await;
        self.revoke(PendingRevocation {
            server: server.clone(),
            grant,
        })
        .await;
        forgotten.err().unwrap_or(OidcError::Cancelled)
    }

    async fn forget(&self, server: &OidcServer) -> Result<(), OidcError> {
        self.store
            .delete(server.grant_key())
            .await
            .map_err(|error| store_error(server, error))
    }

    /// Whether a readable refresh grant is stored for the server's origin.
    ///
    /// # Errors
    ///
    /// [`OidcError::Store`] when the store cannot be read.
    pub async fn has_stored_grant(&self, server: &OidcServer) -> Result<bool, OidcError> {
        let stored = self
            .store
            .get(server.grant_key())
            .await
            .map_err(|error| store_error(server, error))?;
        Ok(stored.is_some_and(|bytes| OidcGrant::from_record(&bytes).is_some()))
    }

    /// The local half of a sign-out: drops any refresh or code exchange in flight for the origin
    /// (their callers get [`OidcError::Cancelled`]), then deletes the stored grant before any
    /// network call.
    pub async fn forget_grant(&self, server: &OidcServer) -> ForgottenGrant {
        lock(&self.sign_outs).sign_out(&server.origin);
        let removed = lock(&self.flights).remove(&server.origin);
        if let Some(flight) = removed {
            flight.cancelled.store(true, Ordering::Release);
        }
        let (grant, load_error) = match self.store.get(server.grant_key()).await {
            Ok(Some(bytes)) => OidcGrant::from_record(&bytes).map_or_else(
                || {
                    let invalid = OidcError::InvalidGrantRecord {
                        host: server.host.clone(),
                    };
                    (None, Some(invalid))
                },
                |grant| (Some(grant), None),
            ),
            Ok(None) => (None, None),
            Err(error) => (None, Some(store_error(server, error))),
        };
        let delete_error = self.forget(server).await.err();
        ForgottenGrant {
            revocation: grant.map(|grant| PendingRevocation {
                server: server.clone(),
                grant,
            }),
            load_error,
            delete_error,
        }
    }

    /// Best-effort `POST /oauth/revoke` of a forgotten grant.
    pub async fn revoke(&self, pending: PendingRevocation) -> RevokeOutcome {
        let Ok(request) = form_post(
            &pending.server,
            "/oauth/revoke",
            &[("refresh_token", pending.grant.refresh_token.expose())],
        ) else {
            return RevokeOutcome::Failed(NetworkCause::Transport(TransportError::Other {
                message: "server URL has no revoke endpoint".into(),
            }));
        };
        match self.transport.send(request).await {
            Ok(response) if response.status == 200 => RevokeOutcome::Revoked,
            Ok(response) => RevokeOutcome::Failed(NetworkCause::Status(response.status)),
            Err(error) => RevokeOutcome::Failed(NetworkCause::Transport(error)),
        }
    }

    /// [`OidcCredentials::forget_grant`], then [`OidcCredentials::revoke`].
    pub async fn sign_out(&self, server: &OidcServer) -> SignOutReport {
        let forgotten = self.forget_grant(server).await;
        let revocation = match forgotten.revocation {
            Some(pending) => Some(self.revoke(pending).await),
            None => None,
        };
        SignOutReport {
            revocation,
            load_error: forgotten.load_error,
            delete_error: forgotten.delete_error,
        }
    }

    /// Whether the server accepts `token`: `GET /v1/me` answers 200. A `401`, `403` or 3xx is a
    /// rejection.
    ///
    /// # Errors
    ///
    /// [`OidcError::Network`] for any other status or a transport failure;
    /// [`OidcError::SessionRejected`] for a token that is not header-safe (no request).
    pub async fn is_accepted(
        &self,
        server: &OidcServer,
        token: &SecretString,
        presentation: SessionPresentation<'_>,
    ) -> Result<bool, OidcError> {
        if !is_header_safe_token(token.expose()) {
            return Err(OidcError::SessionRejected {
                host: server.host.clone(),
            });
        }
        let credential = match presentation {
            SessionPresentation::Cookie(name) => {
                HttpHeader::new("Cookie", format!("{name}={}", token.expose()))
            }
            SessionPresentation::Bearer => {
                HttpHeader::new("Authorization", format!("Bearer {}", token.expose()))
            }
        };
        let request = HttpRequest {
            method: "GET".into(),
            url: server.endpoint("/v1/me")?.into(),
            headers: vec![credential, HttpHeader::new("Accept", "application/json")],
            body: None,
        };
        let response = self.send(server, request).await?;
        match response.status {
            200 => Ok(true),
            401 | 403 | 300..=399 => Ok(false),
            status => Err(network(server, NetworkCause::Status(status))),
        }
    }
}

#[cfg(test)]
mod tests;
