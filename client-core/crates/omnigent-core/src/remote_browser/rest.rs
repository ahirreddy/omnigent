//! Remote browser tab REST: request builders and response decoders (design doc section 5.10).
//!
//! | Method | Path | Body | Success |
//! |---|---|---|---|
//! | GET | `/v1/sessions/{id}/resources/browsers` | `limit`, `after`, `order` | 200 `PaginatedList` of resources |
//! | POST | `/v1/sessions/{id}/resources/browsers` | `{"url"?, "profile"?}` | 200 resource |
//! | DELETE | `/v1/sessions/{id}/resources/browsers/{tab}` | none | 200 `{id, object, deleted}` |
//! | GET | `/v1/sessions/{id}/resources/browser_profiles` | none | 200 list; 404 means only `default` |
//!
//! Plus the attach upgrade `ws(s)://…/resources/browsers/{tab}/attach?mode=…&v=1`.

use omnigent_protocol::remote_browser::{AttachMode, CreatedBy, Owner, PROTOCOL_VERSION};
use serde_json::{Map, Value};
use url::Url;

use super::attach::AttachOptions;
use crate::attachments::policy::is_identifier;
use crate::http::{HttpHeader, HttpRequest, HttpResponse, TransportError};
use crate::terminal::rest::error_reason;

/// The largest page the list route accepts.
pub const MAX_PAGE: u32 = 1000;
/// The default profile.
pub const DEFAULT_PROFILE: &str = "default";
/// Longest profile name.
pub const MAX_PROFILE_LEN: usize = 32;

/// Why a remote browser REST call failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum RemoteBrowserError {
    /// A session or tab id that cannot be a path segment. Nothing was sent.
    #[error("invalid identifier {value:?}")]
    InvalidIdentifier {
        /// The rejected value.
        value: String,
    },
    /// A profile name outside `[a-z0-9][a-z0-9_-]{0,31}`. Nothing was sent.
    #[error("invalid browser profile name {name:?}")]
    InvalidProfile {
        /// The rejected name.
        name: String,
    },
    /// A URL that is not http(s) or `about:`. Nothing was sent.
    #[error("invalid URL {url:?}: use http, https or about:")]
    InvalidUrl {
        /// The rejected URL.
        url: String,
    },
    /// Request parameters that cannot be sent.
    #[error("invalid browser request: {detail}")]
    InvalidRequest {
        /// What was wrong.
        detail: String,
    },
    /// The client is not connected to a server; nothing was sent.
    #[error("Connect to the server before using remote browsers.")]
    NotConnected,
    /// HTTP 401: sign in again.
    #[error("not signed in: {reason}")]
    Unauthorized {
        /// The server's explanation.
        reason: String,
    },
    /// HTTP 403: the caller lacks read (list) or edit (create, delete) access.
    #[error("not allowed: {reason}")]
    Forbidden {
        /// The server's explanation.
        reason: String,
    },
    /// HTTP 404: the session does not exist (or its runner is not yet bound).
    #[error("not found: {reason}")]
    NotFound {
        /// The server's explanation.
        reason: String,
    },
    /// HTTP 503 with `browser_unavailable`: the machine has no browser host, or it cannot start.
    #[error("the remote browser is unavailable: {reason}")]
    BrowserUnavailable {
        /// The server's explanation.
        reason: String,
    },
    /// HTTP 409, 502 or 503: the session's runner is not reachable right now.
    #[error("the session's runner is unavailable (HTTP {status}): {reason}")]
    RunnerUnavailable {
        /// The status.
        status: u16,
        /// The server's explanation.
        reason: String,
    },
    /// Another 4xx, for example 400 for a profile or URL the server refuses.
    #[error("{message}")]
    Rejected {
        /// The status.
        status: u16,
        /// The server's explanation.
        message: String,
    },
    /// A 3xx. Redirects are never followed.
    #[error("the server redirected the browser request (HTTP {status})")]
    Redirected {
        /// The status.
        status: u16,
    },
    /// Another 5xx, or an unexpected 2xx.
    #[error("browser request failed with HTTP {status}: {reason}")]
    HttpStatus {
        /// The status.
        status: u16,
        /// The server's explanation.
        reason: String,
    },
    /// No response.
    #[error("could not reach the server: {0}")]
    Transport(TransportError),
    /// A success body that is not the documented shape.
    #[error("browser response is malformed: {detail}")]
    MalformedResponse {
        /// What was wrong.
        detail: String,
    },
}

impl RemoteBrowserError {
    /// Whether the user must sign in again.
    #[must_use]
    pub const fn requires_sign_in(&self) -> bool {
        matches!(self, Self::Unauthorized { .. } | Self::NotConnected)
    }
}

/// One remote browser tab, from the resource list.
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts of the wire resource, mirrored one to one as an FFI record"
)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrowserTab {
    /// Tab id.
    pub id: String,
    /// Owning session, when the payload names one.
    pub session_id: Option<String>,
    /// Display name (usually the title).
    pub name: String,
    /// URL.
    pub url: String,
    /// Title.
    pub title: String,
    /// Loading.
    pub loading: bool,
    /// Owner.
    pub owner: Owner,
    /// A handoff waits for the user.
    pub needs_attention: bool,
    /// Profile.
    pub profile: String,
    /// Creator.
    pub created_by: CreatedBy,
    /// History back possible.
    pub can_go_back: bool,
    /// History forward possible.
    pub can_go_forward: bool,
    /// A thumbnail to show before attaching.
    pub thumbnail_url: Option<String>,
}

/// One browser profile on the session's machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrowserProfile {
    /// Name.
    pub name: String,
    /// Whether its host runs; `None` when unknown.
    pub running: Option<bool>,
}

/// A page of the tab list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrowserPage {
    /// The tabs.
    pub tabs: Vec<BrowserTab>,
    /// More pages follow.
    pub has_more: bool,
    /// The cursor for the next page.
    pub last_id: Option<String>,
}

/// What a delete achieved.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeleteOutcome {
    /// The tab was closed.
    Deleted,
    /// It was already gone (404).
    AlreadyGone,
}

/// Whether `name` is a valid profile name.
#[must_use]
pub fn is_profile_name(name: &str) -> bool {
    let mut bytes = name.bytes();
    bytes
        .next()
        .is_some_and(|first| first.is_ascii_lowercase() || first.is_ascii_digit())
        && name.len() <= MAX_PROFILE_LEN
        && bytes.all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_' || byte == b'-'
        })
}

fn is_browsable_url(url: &str) -> bool {
    url.len() <= super::input::MAX_URL_LEN
        && Url::parse(url).is_ok_and(|parsed| matches!(parsed.scheme(), "http" | "https" | "about"))
}

/// The server and session browser requests go to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrowserEndpoint {
    /// Server base URL including any mount path, `http` or `https`.
    pub server_url: Url,
    /// The session.
    pub session_id: String,
}

fn identifier(value: &str) -> Result<(), RemoteBrowserError> {
    if is_identifier(value) {
        Ok(())
    } else {
        Err(RemoteBrowserError::InvalidIdentifier {
            value: value.to_owned(),
        })
    }
}

fn json_request(method: &str, url: Url, body: Option<Vec<u8>>) -> HttpRequest {
    let mut headers = vec![HttpHeader::new("Accept", "application/json")];
    if body.is_some() {
        headers.push(HttpHeader::new("Content-Type", "application/json"));
    }
    HttpRequest {
        method: method.to_owned(),
        url: url.into(),
        headers,
        body,
    }
}

impl BrowserEndpoint {
    /// An endpoint for `session_id` on `server_url`.
    ///
    /// # Errors
    ///
    /// [`RemoteBrowserError::InvalidIdentifier`] for a malformed session id, and
    /// [`RemoteBrowserError::InvalidRequest`] for a base URL that is not `http(s)`.
    pub fn new(server_url: Url, session_id: impl Into<String>) -> Result<Self, RemoteBrowserError> {
        let session_id = session_id.into();
        identifier(&session_id)?;
        if !matches!(server_url.scheme(), "http" | "https") || !server_url.has_host() {
            return Err(RemoteBrowserError::InvalidRequest {
                detail: format!("server URL must be http(s) with a host, not {server_url}"),
            });
        }
        Ok(Self {
            server_url,
            session_id,
        })
    }

    fn url(&self, segments: &[&str]) -> Url {
        let mut url = self.server_url.clone();
        let mut path = format!(
            "{}/v1/sessions/{}/resources",
            self.server_url.path().trim_end_matches('/'),
            self.session_id
        );
        for segment in segments {
            path.push('/');
            path.push_str(segment);
        }
        url.set_path(&path);
        url.set_query(None);
        url.set_fragment(None);
        url
    }

    /// `GET …/resources/browsers`, oldest first.
    ///
    /// # Errors
    ///
    /// [`RemoteBrowserError::InvalidRequest`] for a limit outside `1..=1000`;
    /// [`RemoteBrowserError::InvalidIdentifier`] for a malformed cursor.
    pub fn list_request(
        &self,
        limit: u32,
        after: Option<&str>,
    ) -> Result<HttpRequest, RemoteBrowserError> {
        if !(1..=MAX_PAGE).contains(&limit) {
            return Err(RemoteBrowserError::InvalidRequest {
                detail: format!("limit {limit} is outside 1..={MAX_PAGE}"),
            });
        }
        let mut url = self.url(&["browsers"]);
        {
            let mut pairs = url.query_pairs_mut();
            pairs.append_pair("limit", &limit.to_string());
            pairs.append_pair("order", "asc");
            if let Some(after) = after {
                identifier(after)?;
                pairs.append_pair("after", after);
            }
        }
        Ok(json_request("GET", url, None))
    }

    /// `POST …/resources/browsers`.
    ///
    /// # Errors
    ///
    /// [`RemoteBrowserError::InvalidUrl`] or [`RemoteBrowserError::InvalidProfile`].
    pub fn create_request(
        &self,
        url: Option<&str>,
        profile: Option<&str>,
    ) -> Result<HttpRequest, RemoteBrowserError> {
        let mut body = Map::new();
        if let Some(url) = url {
            if !is_browsable_url(url) {
                return Err(RemoteBrowserError::InvalidUrl {
                    url: url.to_owned(),
                });
            }
            body.insert("url".to_owned(), Value::String(url.to_owned()));
        }
        if let Some(profile) = profile {
            if !is_profile_name(profile) {
                return Err(RemoteBrowserError::InvalidProfile {
                    name: profile.to_owned(),
                });
            }
            body.insert("profile".to_owned(), Value::String(profile.to_owned()));
        }
        Ok(json_request(
            "POST",
            self.url(&["browsers"]),
            Some(Value::Object(body).to_string().into_bytes()),
        ))
    }

    /// `DELETE …/resources/browsers/{tab_id}`.
    ///
    /// # Errors
    ///
    /// [`RemoteBrowserError::InvalidIdentifier`].
    pub fn delete_request(&self, tab_id: &str) -> Result<HttpRequest, RemoteBrowserError> {
        identifier(tab_id)?;
        Ok(json_request(
            "DELETE",
            self.url(&["browsers", tab_id]),
            None,
        ))
    }

    /// `GET …/resources/browser_profiles`.
    #[must_use]
    pub fn profiles_request(&self) -> HttpRequest {
        json_request("GET", self.url(&["browser_profiles"]), None)
    }

    /// The attach upgrade: `ws(s)://…/resources/browsers/{tab_id}/attach?mode=…&v=1`.
    ///
    /// # Errors
    ///
    /// [`RemoteBrowserError::InvalidIdentifier`] for a malformed tab id or slice key.
    pub fn attach_request(
        &self,
        tab_id: &str,
        options: &AttachOptions,
    ) -> Result<HttpRequest, RemoteBrowserError> {
        identifier(tab_id)?;
        let mut url = self.url(&["browsers", tab_id, "attach"]);
        let scheme = if url.scheme() == "https" { "wss" } else { "ws" };
        url.set_scheme(scheme)
            .map_err(|()| RemoteBrowserError::InvalidRequest {
                detail: format!("cannot use the {scheme} scheme for {url}"),
            })?;
        {
            let mut pairs = url.query_pairs_mut();
            pairs.append_pair(
                "mode",
                if options.mode == AttachMode::Control {
                    "control"
                } else {
                    "view"
                },
            );
            pairs.append_pair("v", &PROTOCOL_VERSION.to_string());
            if let Some(key) = &options.slice_key {
                identifier(key)?;
                pairs.append_pair("omnigent_slice_key", key);
            }
        }
        Ok(HttpRequest {
            method: "GET".to_owned(),
            url: url.into(),
            headers: Vec::new(),
            body: None,
        })
    }
}

/// The `error.code` of a JSON error body.
fn error_code(body: &[u8]) -> Option<String> {
    let value: Value = serde_json::from_slice(body).ok()?;
    value
        .get("error")
        .and_then(|error| error.get("code"))
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn check(result: Result<HttpResponse, TransportError>) -> Result<HttpResponse, RemoteBrowserError> {
    let response = result.map_err(RemoteBrowserError::Transport)?;
    if response.status == 200 {
        return Ok(response);
    }
    let status = response.status;
    let reason = error_reason(&response.body, status);
    Err(match status {
        300..=399 => RemoteBrowserError::Redirected { status },
        401 => RemoteBrowserError::Unauthorized { reason },
        403 => RemoteBrowserError::Forbidden { reason },
        404 => RemoteBrowserError::NotFound { reason },
        503 if error_code(&response.body).as_deref() == Some("browser_unavailable") => {
            RemoteBrowserError::BrowserUnavailable { reason }
        }
        409 | 502 | 503 => RemoteBrowserError::RunnerUnavailable { status, reason },
        400..=499 => RemoteBrowserError::Rejected {
            status,
            message: reason,
        },
        _ => RemoteBrowserError::HttpStatus { status, reason },
    })
}

fn body_json(response: &HttpResponse) -> Result<Value, RemoteBrowserError> {
    serde_json::from_slice(&response.body).map_err(|error| RemoteBrowserError::MalformedResponse {
        detail: error.to_string(),
    })
}

fn malformed(detail: impl Into<String>) -> RemoteBrowserError {
    RemoteBrowserError::MalformedResponse {
        detail: detail.into(),
    }
}

fn string(map: &Map<String, Value>, field: &str) -> Result<String, RemoteBrowserError> {
    map.get(field)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| malformed(format!("missing string {field}")))
}

fn flag(map: &Map<String, Value>, field: &str) -> bool {
    map.get(field).and_then(Value::as_bool).unwrap_or(false)
}

/// Decodes one browser resource object.
///
/// # Errors
///
/// [`RemoteBrowserError::MalformedResponse`] for a missing id, a non-browser resource, or a
/// missing metadata URL.
pub fn decode_tab(value: &Value) -> Result<BrowserTab, RemoteBrowserError> {
    let object = value
        .as_object()
        .ok_or_else(|| malformed("a browser resource is not an object"))?;
    let id = string(object, "id")?;
    if object.get("type").and_then(Value::as_str) != Some("browser") {
        return Err(malformed(format!("resource {id} is not a browser")));
    }
    let empty = Map::new();
    let metadata = object
        .get("metadata")
        .and_then(Value::as_object)
        .unwrap_or(&empty);
    let text = |field: &str| {
        metadata
            .get(field)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    Ok(BrowserTab {
        session_id: object
            .get("session_id")
            .and_then(Value::as_str)
            .map(str::to_owned),
        name: object
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        url: string(metadata, "url")?,
        title: text("title"),
        loading: flag(metadata, "loading"),
        owner: Owner::parse(
            metadata
                .get("owner")
                .and_then(Value::as_str)
                .unwrap_or("agent"),
        ),
        needs_attention: flag(metadata, "needs_attention"),
        profile: metadata
            .get("profile")
            .and_then(Value::as_str)
            .unwrap_or(DEFAULT_PROFILE)
            .to_owned(),
        created_by: CreatedBy::parse(
            metadata
                .get("created_by")
                .and_then(Value::as_str)
                .unwrap_or("agent"),
        ),
        can_go_back: flag(metadata, "can_go_back"),
        can_go_forward: flag(metadata, "can_go_forward"),
        thumbnail_url: metadata
            .get("thumbnail_url")
            .and_then(Value::as_str)
            .map(str::to_owned),
        id,
    })
}

/// Decodes the host's result for [`BrowserEndpoint::list_request`].
///
/// # Errors
///
/// [`RemoteBrowserError`].
pub fn list_response(
    result: Result<HttpResponse, TransportError>,
) -> Result<BrowserPage, RemoteBrowserError> {
    let body = body_json(&check(result)?)?;
    let data = body
        .get("data")
        .and_then(Value::as_array)
        .ok_or_else(|| malformed("the browser list has no data array"))?;
    Ok(BrowserPage {
        tabs: data.iter().map(decode_tab).collect::<Result<_, _>>()?,
        has_more: body
            .get("has_more")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        last_id: body
            .get("last_id")
            .and_then(Value::as_str)
            .map(str::to_owned),
    })
}

/// Decodes the host's result for [`BrowserEndpoint::create_request`].
///
/// # Errors
///
/// [`RemoteBrowserError`].
pub fn create_response(
    result: Result<HttpResponse, TransportError>,
) -> Result<BrowserTab, RemoteBrowserError> {
    decode_tab(&body_json(&check(result)?)?)
}

/// Decodes the host's result for [`BrowserEndpoint::delete_request`]: 404 is
/// [`DeleteOutcome::AlreadyGone`].
///
/// # Errors
///
/// [`RemoteBrowserError`]; a 200 that does not confirm the deletion is malformed.
pub fn delete_response(
    tab_id: &str,
    result: Result<HttpResponse, TransportError>,
) -> Result<DeleteOutcome, RemoteBrowserError> {
    match check(result) {
        Ok(response) => {
            let body = body_json(&response)?;
            let confirmed = body.get("deleted").and_then(Value::as_bool) == Some(true)
                && body.get("id").and_then(Value::as_str) == Some(tab_id);
            if confirmed {
                Ok(DeleteOutcome::Deleted)
            } else {
                Err(malformed(format!(
                    "the delete of {tab_id} was not confirmed: {body}"
                )))
            }
        }
        Err(RemoteBrowserError::NotFound { .. }) => Ok(DeleteOutcome::AlreadyGone),
        Err(error) => Err(error),
    }
}

/// Decodes the host's result for [`BrowserEndpoint::profiles_request`]. A 404 is an older
/// server without the route: only `default` exists.
///
/// # Errors
///
/// [`RemoteBrowserError`].
pub fn profiles_response(
    result: Result<HttpResponse, TransportError>,
) -> Result<Vec<BrowserProfile>, RemoteBrowserError> {
    let body = match check(result) {
        Ok(response) => body_json(&response)?,
        Err(RemoteBrowserError::NotFound { .. }) => {
            return Ok(vec![BrowserProfile {
                name: DEFAULT_PROFILE.to_owned(),
                running: None,
            }]);
        }
        Err(error) => return Err(error),
    };
    body.get("data")
        .and_then(Value::as_array)
        .ok_or_else(|| malformed("the profile list has no data array"))?
        .iter()
        .map(|entry| {
            let object = entry
                .as_object()
                .ok_or_else(|| malformed("a profile is not an object"))?;
            Ok(BrowserProfile {
                name: string(object, "name")?,
                running: object.get("running").and_then(Value::as_bool),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote_browser::test_support::fixture_json;

    fn endpoint() -> BrowserEndpoint {
        BrowserEndpoint::new(Url::parse("https://example.com/omni").unwrap(), "conv_a").unwrap()
    }

    #[allow(
        clippy::unnecessary_wraps,
        reason = "mirrors the host transport result the decoders take"
    )]
    fn reply(status: u16, body: &str) -> Result<HttpResponse, TransportError> {
        Ok(HttpResponse {
            status,
            headers: Vec::new(),
            body: body.as_bytes().to_vec(),
        })
    }

    #[test]
    fn a_browser_can_open_in_a_named_profile() {
        let request = endpoint().create_request(None, Some("work")).unwrap();
        let body: Value = serde_json::from_slice(request.body.as_deref().unwrap()).unwrap();
        assert_eq!(body["profile"], "work");
    }

    #[test]
    fn a_base_url_that_is_not_web_is_refused() {
        for bad in ["ftp://example.com", "mailto:a@b.c"] {
            assert!(matches!(
                BrowserEndpoint::new(Url::parse(bad).unwrap(), "conv_a"),
                Err(RemoteBrowserError::InvalidRequest { .. })
            ));
        }
    }

    #[test]
    fn listing_resumes_after_a_valid_cursor_and_refuses_a_bad_one() {
        let listed = endpoint().list_request(10, Some("btab_1")).unwrap();
        assert!(
            listed.url.ends_with("limit=10&order=asc&after=btab_1"),
            "{}",
            listed.url
        );
        assert!(matches!(
            endpoint().list_request(10, Some("../x")),
            Err(RemoteBrowserError::InvalidIdentifier { .. })
        ));
    }

    #[test]
    fn creating_in_a_named_profile_sends_it() {
        let request = endpoint().create_request(None, Some("work")).unwrap();
        assert_eq!(request.body.unwrap(), br#"{"profile":"work"}"#);
    }

    #[test]
    fn every_failure_status_has_its_own_error() {
        let list = |status: u16| list_response(reply(status, r#"{"detail":"why"}"#)).unwrap_err();
        assert!(matches!(list(403), RemoteBrowserError::Forbidden { reason } if reason == "why"));
        for status in [409, 502, 503] {
            assert!(matches!(
                list(status),
                RemoteBrowserError::RunnerUnavailable { status: got, .. } if got == status
            ));
        }
        assert!(matches!(
            list(500),
            RemoteBrowserError::HttpStatus { status: 500, .. }
        ));
    }

    #[test]
    fn bodies_of_the_wrong_shape_are_malformed() {
        let malformed_list = |body: &str| {
            matches!(
                list_response(reply(200, body)),
                Err(RemoteBrowserError::MalformedResponse { .. })
            )
        };
        assert!(malformed_list("not json"));
        assert!(malformed_list("{}"));
        assert!(malformed_list(r#"{"data":[{"id":"t","type":"terminal"}]}"#));
        assert!(malformed_list(r#"{"data":[7]}"#));
        assert!(malformed_list(r#"{"data":[{"type":"browser"}]}"#));
    }

    #[test]
    fn a_delete_must_confirm_the_same_tab() {
        for body in [
            r#"{"id":"other","deleted":true}"#,
            r#"{"id":"btab_1","deleted":false}"#,
            "{}",
        ] {
            assert!(matches!(
                delete_response("btab_1", reply(200, body)),
                Err(RemoteBrowserError::MalformedResponse { detail }) if detail.contains("btab_1")
            ));
        }
        assert!(matches!(
            delete_response("btab_1", reply(403, "{}")),
            Err(RemoteBrowserError::Forbidden { .. })
        ));
    }

    #[test]
    fn profiles_fail_on_anything_but_the_missing_route() {
        assert!(matches!(
            profiles_response(reply(403, "{}")),
            Err(RemoteBrowserError::Forbidden { .. })
        ));
        assert!(matches!(
            profiles_response(reply(200, r#"{"data":[7]}"#)),
            Err(RemoteBrowserError::MalformedResponse { .. })
        ));
    }

    fn recorded(name: &str) -> (Value, Result<HttpResponse, TransportError>) {
        let fixture = fixture_json(&format!("rest/{name}.json"));
        let status = u16::try_from(fixture["status"].as_u64().unwrap()).unwrap();
        let response = HttpResponse {
            status,
            headers: Vec::new(),
            body: fixture["body"].to_string().into_bytes(),
        };
        (fixture["request"].clone(), Ok(response))
    }

    fn path(request: &HttpRequest) -> String {
        let url = Url::parse(&request.url).unwrap();
        let path = url.path().trim_start_matches("/omni").to_owned();
        url.query()
            .map_or_else(|| path.clone(), |query| format!("{path}?{query}"))
    }

    #[test]
    fn requests_match_the_recorded_shapes() {
        let (request, _) = recorded("list");
        assert_eq!(
            path(&endpoint().list_request(MAX_PAGE, None).unwrap()),
            request["path"]
        );
        let (request, _) = recorded("create");
        let create = endpoint()
            .create_request(Some("https://github.com/login"), Some("default"))
            .unwrap();
        assert_eq!(path(&create), request["path"]);
        let body: Value = serde_json::from_slice(create.body.as_ref().unwrap()).unwrap();
        assert_eq!(body, request["body"]);
        let (request, _) = recorded("delete");
        assert_eq!(
            path(&endpoint().delete_request("btab_7f3a9c2e").unwrap()),
            request["path"]
        );
        let (request, _) = recorded("profiles");
        assert_eq!(path(&endpoint().profiles_request()), request["path"]);
        let attach = endpoint()
            .attach_request(
                "btab_7f3a9c2e",
                &AttachOptions {
                    mode: AttachMode::Control,
                    slice_key: Some("host_1".into()),
                },
            )
            .unwrap();
        assert_eq!(
            attach.url,
            "wss://example.com/omni/v1/sessions/conv_a/resources/browsers/btab_7f3a9c2e/attach?mode=control&v=1&omnigent_slice_key=host_1"
        );
    }

    #[test]
    fn rejects_bad_inputs_before_sending() {
        assert!(matches!(
            endpoint().create_request(None, Some("Bad Name")),
            Err(RemoteBrowserError::InvalidProfile { .. })
        ));
        assert!(matches!(
            endpoint().create_request(Some("file:///etc/passwd"), None),
            Err(RemoteBrowserError::InvalidUrl { .. })
        ));
        assert!(matches!(
            endpoint().delete_request("../x"),
            Err(RemoteBrowserError::InvalidIdentifier { .. })
        ));
        assert!(endpoint().list_request(0, None).is_err());
        assert!(is_profile_name("work-2"));
        assert!(!is_profile_name(&"a".repeat(33)));
        assert!(!is_profile_name("_x"));
    }

    #[test]
    fn decodes_the_recorded_responses() {
        let page = list_response(recorded("list").1).unwrap();
        assert_eq!(page.tabs.len(), 2);
        assert!(page.tabs[0].needs_attention);
        assert_eq!(page.tabs[1].profile, "work");
        assert_eq!(page.tabs[1].owner, Owner::User);
        let tab = create_response(recorded("create").1).unwrap();
        assert_eq!(tab.created_by, CreatedBy::User);
        assert!(matches!(
            create_response(recorded("create_unavailable").1),
            Err(RemoteBrowserError::BrowserUnavailable { .. })
        ));
        assert!(matches!(
            create_response(recorded("create_bad_profile").1),
            Err(RemoteBrowserError::Rejected { status: 400, .. })
        ));
        assert_eq!(
            delete_response("btab_7f3a9c2e", recorded("delete").1),
            Ok(DeleteOutcome::Deleted)
        );
        assert_eq!(
            delete_response("btab_missing", recorded("delete_missing").1),
            Ok(DeleteOutcome::AlreadyGone)
        );
        let profiles = profiles_response(recorded("profiles").1).unwrap();
        assert_eq!(profiles.len(), 2);
        let old_server = profiles_response(Ok(HttpResponse {
            status: 404,
            headers: Vec::new(),
            body: Vec::new(),
        }))
        .unwrap();
        assert_eq!(old_server[0].name, "default");
        let unauthorized = list_response(Ok(HttpResponse {
            status: 401,
            headers: Vec::new(),
            body: Vec::new(),
        }))
        .unwrap_err();
        assert!(unauthorized.requires_sign_in());
    }
}
