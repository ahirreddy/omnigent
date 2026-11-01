//! Terminal lifecycle REST: request builders and response decoders.
//!
//! Routes (server: `omnigent/server/routes/sessions/routes_resources.py`; runner:
//! `omnigent/runner/resource_routes.py`):
//!
//! | Method | Path | Body | Success |
//! |---|---|---|---|
//! | GET | `/v1/sessions/{id}/resources/terminals` | `limit` (1–1000), `after`, `before`, `order` | 200 `PaginatedList` |
//! | POST | `/v1/sessions/{id}/resources/terminals` | `{"terminal", "session_key"}` | 200 resource |
//! | GET | `/v1/sessions/{id}/resources/terminals/{tid}` | none | 200 resource |
//! | DELETE | `/v1/sessions/{id}/resources/terminals/{tid}` | none | 200 `{id, object:"session.resource.deleted", deleted:true}` |
//!
//! - The list defaults to `order=desc` on the runner. The web client asks for `order=asc&limit=1000`
//!   so the session's own terminal stays first; [`ListTerminals::default`] does the same.
//! - Create is gated on the agent spec's declared `terminals:` names (400 otherwise) and needs
//!   edit access (403). It is idempotent per `(terminal, session_key)`: the runner returns the
//!   running terminal for a repeated pair. So unlike most writes, a create whose outcome is lost
//!   may be retried **with the same session key**, and it never launches a second shell.
//! - Delete returns 404 for an unknown terminal. That is the goal state already, so it decodes to
//!   [`DeleteOutcome::AlreadyGone`] rather than an error.
//! - While the runner is unbound, waking or offline the list and get routes answer 404, 409, 502
//!   or 503. Those become [`TerminalError::RunnerUnavailable`] (or [`TerminalError::NotFound`]),
//!   never an empty list: the caller decides whether to show "starting".
//!
//! Every request carries `Accept: application/json`. Authentication and Databricks scope headers
//! are the caller's job, as for uploads.

use serde_json::{Map, Value};
use url::Url;

use super::resource::{TerminalPage, TerminalResource};
use crate::attachments::policy::is_identifier;
use crate::http::{HttpHeader, HttpRequest, HttpResponse, TransportError};

/// The largest page the list route accepts.
pub const MAX_TERMINAL_PAGE: u32 = 1000;

/// Longest terminal name accepted in a create request.
pub const MAX_TERMINAL_NAME_LEN: usize = 128;

/// Why a terminal REST call failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TerminalError {
    /// A session id, terminal id or session key that cannot be a path segment or key. Nothing
    /// was sent.
    #[error("invalid identifier {value:?}")]
    InvalidIdentifier {
        /// The rejected value.
        value: String,
    },
    /// Request parameters that cannot be sent (an out-of-range limit, an empty cursor or name).
    #[error("invalid terminal request: {detail}")]
    InvalidRequest {
        /// What was wrong.
        detail: String,
    },
    /// The client is not connected to a server; nothing was sent.
    #[error("Connect to the server before using terminals.")]
    NotConnected,
    /// HTTP 401: drop the connection and sign in again.
    #[error("not signed in: {reason}")]
    Unauthorized {
        /// The server's explanation.
        reason: String,
    },
    /// HTTP 403: the caller lacks read (list/get) or edit (create/delete) access.
    #[error("not allowed: {reason}")]
    Forbidden {
        /// The server's explanation.
        reason: String,
    },
    /// HTTP 404: the session, or the terminal on a get, does not exist (or the runner is not yet
    /// bound, which the server cannot tell apart).
    #[error("not found: {reason}")]
    NotFound {
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
    /// Another 4xx: the server refused the request, for example a create for a terminal the agent
    /// does not declare (400) or a validation failure (422).
    #[error("{message}")]
    Rejected {
        /// The status.
        status: u16,
        /// The server's explanation.
        message: String,
    },
    /// A 3xx. Redirects are never followed.
    #[error("the server redirected the terminal request (HTTP {status})")]
    Redirected {
        /// The status.
        status: u16,
    },
    /// A 5xx other than 502/503, or an unexpected 2xx.
    #[error("terminal request failed with HTTP {status}: {reason}")]
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
    #[error("terminal response is malformed: {detail}")]
    MalformedResponse {
        /// What was wrong.
        detail: String,
    },
}

impl TerminalError {
    /// Whether the user must sign in again.
    #[must_use]
    pub const fn requires_sign_in(&self) -> bool {
        matches!(self, Self::Unauthorized { .. } | Self::NotConnected)
    }
}

/// Order of the terminal list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListOrder {
    /// Oldest first: the agent's own terminal, created first, leads.
    Ascending,
    /// Newest first (the runner's default).
    Descending,
}

/// Query for one page of the terminal list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListTerminals {
    /// Rows per page, `1..=1000`.
    pub limit: u32,
    /// Resume after this terminal id.
    pub after: Option<String>,
    /// Sort order.
    pub order: ListOrder,
}

impl Default for ListTerminals {
    /// The web client's seed query: every terminal, oldest first.
    fn default() -> Self {
        Self {
            limit: MAX_TERMINAL_PAGE,
            after: None,
            order: ListOrder::Ascending,
        }
    }
}

/// A terminal to launch: a declared terminal name plus a session key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreateTerminal {
    /// The terminal name the agent declares (or a host shell basename such as `zsh` for native
    /// sessions).
    pub terminal: String,
    /// The per-launch key. A new key launches a new shell; the same key returns the running one.
    pub session_key: String,
}

impl CreateTerminal {
    /// A create for `terminal` with a fresh user key derived from `entropy` (host randomness,
    /// for example `UInt64.random(in:)`): `u-` plus six base-36 digits, the web client's shape.
    #[must_use]
    pub fn new_shell(terminal: impl Into<String>, entropy: u64) -> Self {
        Self {
            terminal: terminal.into(),
            session_key: user_session_key(entropy),
        }
    }
}

/// `u-` plus the low six base-36 digits of `entropy`.
#[must_use]
pub fn user_session_key(entropy: u64) -> String {
    const DIGITS: &[u8; 36] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut value = entropy;
    let mut key = [b'0'; 6];
    for slot in key.iter_mut().rev() {
        let digit = usize::try_from(value % 36).unwrap_or_default();
        *slot = DIGITS.get(digit).copied().unwrap_or(b'0');
        value /= 36;
    }
    format!("u-{}", String::from_utf8_lossy(&key))
}

/// What a delete achieved.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeleteOutcome {
    /// The server closed the terminal.
    Deleted,
    /// The terminal was already gone (404).
    AlreadyGone,
}

/// Options for the attach WebSocket.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AttachOptions {
    /// Attach view-only (`?read_only=true`). Interactive attach needs session owner access.
    pub read_only: bool,
    /// The session's host id, sent as `omnigent_slice_key` so a sharded deployment routes the
    /// socket to the replica holding the runner tunnel. Dropped after a 4400 close.
    pub slice_key: Option<String>,
}

/// The server and session terminal requests go to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalEndpoint {
    /// Server base URL including any mount path, `http` or `https`.
    pub server_url: Url,
    /// The session.
    pub session_id: String,
}

impl TerminalEndpoint {
    /// An endpoint for `session_id` on `server_url`.
    ///
    /// # Errors
    ///
    /// [`TerminalError::InvalidIdentifier`] for a malformed session id, and
    /// [`TerminalError::InvalidRequest`] for a base URL that is not `http(s)`.
    pub fn new(server_url: Url, session_id: impl Into<String>) -> Result<Self, TerminalError> {
        let session_id = session_id.into();
        identifier(&session_id)?;
        if !matches!(server_url.scheme(), "http" | "https") || !server_url.has_host() {
            return Err(TerminalError::InvalidRequest {
                detail: format!("server URL must be http(s) with a host, not {server_url}"),
            });
        }
        Ok(Self {
            server_url,
            session_id,
        })
    }

    fn url(&self, terminal_id: Option<&str>, suffix: Option<&str>) -> Url {
        let mut url = self.server_url.clone();
        let mut path = format!(
            "{}/v1/sessions/{}/resources/terminals",
            self.server_url.path().trim_end_matches('/'),
            self.session_id
        );
        if let Some(terminal_id) = terminal_id {
            path.push('/');
            path.push_str(terminal_id);
        }
        if let Some(suffix) = suffix {
            path.push('/');
            path.push_str(suffix);
        }
        url.set_path(&path);
        url.set_query(None);
        url.set_fragment(None);
        url
    }

    /// `GET …/resources/terminals` for one page.
    ///
    /// # Errors
    ///
    /// [`TerminalError::InvalidRequest`] for a limit outside `1..=1000` or an empty cursor;
    /// [`TerminalError::InvalidIdentifier`] for a malformed cursor.
    pub fn list_request(&self, query: &ListTerminals) -> Result<HttpRequest, TerminalError> {
        if !(1..=MAX_TERMINAL_PAGE).contains(&query.limit) {
            return Err(TerminalError::InvalidRequest {
                detail: format!("limit {} is outside 1..={MAX_TERMINAL_PAGE}", query.limit),
            });
        }
        let mut url = self.url(None, None);
        {
            let mut pairs = url.query_pairs_mut();
            pairs.append_pair("limit", &query.limit.to_string());
            pairs.append_pair(
                "order",
                match query.order {
                    ListOrder::Ascending => "asc",
                    ListOrder::Descending => "desc",
                },
            );
            if let Some(after) = &query.after {
                identifier(after)?;
                pairs.append_pair("after", after);
            }
        }
        Ok(json_request("GET", url, None))
    }

    /// `POST …/resources/terminals`.
    ///
    /// # Errors
    ///
    /// [`TerminalError::InvalidRequest`] for an empty or over-long terminal name;
    /// [`TerminalError::InvalidIdentifier`] for a malformed session key.
    pub fn create_request(&self, create: &CreateTerminal) -> Result<HttpRequest, TerminalError> {
        let name = create.terminal.trim();
        if name.is_empty()
            || name.len() > MAX_TERMINAL_NAME_LEN
            || name.chars().any(char::is_control)
        {
            return Err(TerminalError::InvalidRequest {
                detail: format!(
                    "terminal name {:?} is empty, too long or has controls",
                    create.terminal
                ),
            });
        }
        identifier(&create.session_key)?;
        let mut body = Map::new();
        body.insert("terminal".to_owned(), Value::String(name.to_owned()));
        body.insert(
            "session_key".to_owned(),
            Value::String(create.session_key.clone()),
        );
        Ok(json_request(
            "POST",
            self.url(None, None),
            Some(Value::Object(body).to_string().into_bytes()),
        ))
    }

    /// `GET …/resources/terminals/{terminal_id}`.
    ///
    /// # Errors
    ///
    /// [`TerminalError::InvalidIdentifier`].
    pub fn get_request(&self, terminal_id: &str) -> Result<HttpRequest, TerminalError> {
        identifier(terminal_id)?;
        Ok(json_request("GET", self.url(Some(terminal_id), None), None))
    }

    /// `DELETE …/resources/terminals/{terminal_id}`.
    ///
    /// # Errors
    ///
    /// [`TerminalError::InvalidIdentifier`].
    pub fn delete_request(&self, terminal_id: &str) -> Result<HttpRequest, TerminalError> {
        identifier(terminal_id)?;
        Ok(json_request(
            "DELETE",
            self.url(Some(terminal_id), None),
            None,
        ))
    }

    /// The attach WebSocket upgrade request: `ws(s)://…/resources/terminals/{id}/attach`.
    ///
    /// # Errors
    ///
    /// [`TerminalError::InvalidIdentifier`] for a malformed terminal id or slice key.
    pub fn attach_request(
        &self,
        terminal_id: &str,
        options: &AttachOptions,
    ) -> Result<HttpRequest, TerminalError> {
        identifier(terminal_id)?;
        let mut url = self.url(Some(terminal_id), Some("attach"));
        let scheme = if url.scheme() == "https" { "wss" } else { "ws" };
        url.set_scheme(scheme)
            .map_err(|()| TerminalError::InvalidRequest {
                detail: format!("cannot use the {scheme} scheme for {url}"),
            })?;
        if options.read_only || options.slice_key.is_some() {
            let mut pairs = url.query_pairs_mut();
            if options.read_only {
                pairs.append_pair("read_only", "true");
            }
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

fn identifier(value: &str) -> Result<(), TerminalError> {
    if is_identifier(value) {
        Ok(())
    } else {
        Err(TerminalError::InvalidIdentifier {
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

/// The server's explanation in an error body: `error.message`, `error` (a string), `detail`
/// (a string or `FastAPI`'s validation list), or a generic text. Bounded to 1,000 characters.
#[must_use]
pub fn error_reason(body: &[u8], status: u16) -> String {
    let parsed: Option<Value> = serde_json::from_slice(body).ok();
    let message = parsed.as_ref().and_then(|value| {
        value
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| {
                value
                    .get("error")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .or_else(|| match value.get("detail") {
                Some(Value::String(detail)) => Some(detail.clone()),
                Some(detail @ Value::Array(_)) => Some(detail.to_string()),
                _ => None,
            })
    });
    message
        .filter(|message| !message.trim().is_empty())
        .map_or_else(
            || format!("HTTP {status}"),
            |message| message.chars().take(1000).collect(),
        )
}

/// Maps a non-2xx status, or a transport failure, to a [`TerminalError`].
fn check(
    result: Result<HttpResponse, TransportError>,
    ok: &[u16],
) -> Result<HttpResponse, TerminalError> {
    let response = result.map_err(TerminalError::Transport)?;
    if ok.contains(&response.status) {
        return Ok(response);
    }
    let status = response.status;
    let reason = error_reason(&response.body, status);
    Err(match status {
        300..=399 => TerminalError::Redirected { status },
        401 => TerminalError::Unauthorized { reason },
        403 => TerminalError::Forbidden { reason },
        404 => TerminalError::NotFound { reason },
        409 | 502 | 503 => TerminalError::RunnerUnavailable { status, reason },
        400..=499 => TerminalError::Rejected {
            status,
            message: reason,
        },
        _ => TerminalError::HttpStatus { status, reason },
    })
}

fn body_json(response: &HttpResponse) -> Result<Value, TerminalError> {
    serde_json::from_slice(&response.body).map_err(|error| TerminalError::MalformedResponse {
        detail: error.to_string(),
    })
}

const fn malformed(detail: String) -> TerminalError {
    TerminalError::MalformedResponse { detail }
}

/// Decodes the host's result for [`TerminalEndpoint::list_request`].
///
/// # Errors
///
/// See the [module docs](self).
pub fn list_response(
    result: Result<HttpResponse, TransportError>,
) -> Result<TerminalPage, TerminalError> {
    let response = check(result, &[200])?;
    TerminalPage::decode(body_json(&response)?).map_err(malformed)
}

/// Decodes the host's result for [`TerminalEndpoint::create_request`] or
/// [`TerminalEndpoint::get_request`].
///
/// # Errors
///
/// See the [module docs](self).
pub fn resource_response(
    result: Result<HttpResponse, TransportError>,
) -> Result<TerminalResource, TerminalError> {
    let response = check(result, &[200, 201])?;
    TerminalResource::decode(body_json(&response)?).map_err(malformed)
}

/// Decodes the host's result for [`TerminalEndpoint::delete_request`] of `terminal_id`.
///
/// # Errors
///
/// See the [module docs](self). A 200 whose body names another terminal or says
/// `deleted: false` is malformed.
pub fn delete_response(
    terminal_id: &str,
    result: Result<HttpResponse, TransportError>,
) -> Result<DeleteOutcome, TerminalError> {
    let response = match check(result, &[200]) {
        Ok(response) => response,
        Err(TerminalError::NotFound { .. }) => return Ok(DeleteOutcome::AlreadyGone),
        Err(error) => return Err(error),
    };
    let value = body_json(&response)?;
    if let Some(id) = value.get("id").and_then(Value::as_str)
        && id != terminal_id
    {
        return Err(malformed(format!(
            "delete acknowledged {id:?}, not {terminal_id:?}"
        )));
    }
    match value.get("deleted") {
        Some(Value::Bool(true)) | None => Ok(DeleteOutcome::Deleted),
        Some(other) => Err(malformed(format!("deleted is {other}, not true"))),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn endpoint(base: &str) -> TerminalEndpoint {
        TerminalEndpoint::new(Url::parse(base).unwrap(), "conv_1").unwrap()
    }

    #[allow(
        clippy::unnecessary_wraps,
        reason = "mirrors the host transport result the decoders take"
    )]
    fn response(status: u16, body: &Value) -> Result<HttpResponse, TransportError> {
        Ok(HttpResponse {
            status,
            headers: Vec::new(),
            body: body.to_string().into_bytes(),
        })
    }

    #[test]
    fn builds_routes_under_the_mount_path() {
        let endpoint = endpoint("https://ws.example/api/2.0/omnigent/");
        let list = endpoint.list_request(&ListTerminals::default()).unwrap();
        assert_eq!(list.method, "GET");
        assert_eq!(
            list.url,
            "https://ws.example/api/2.0/omnigent/v1/sessions/conv_1/resources/terminals?limit=1000&order=asc"
        );
        let get = endpoint.get_request("terminal_bash_s1").unwrap();
        assert!(get.url.ends_with("/resources/terminals/terminal_bash_s1"));
        let delete = endpoint.delete_request("terminal_bash_s1").unwrap();
        assert_eq!(delete.method, "DELETE");
        let create = endpoint
            .create_request(&CreateTerminal {
                terminal: " zsh ".into(),
                session_key: "u-abc123".into(),
            })
            .unwrap();
        assert_eq!(create.method, "POST");
        let body: Value = serde_json::from_slice(create.body.as_deref().unwrap()).unwrap();
        assert_eq!(body, json!({"terminal": "zsh", "session_key": "u-abc123"}));
        assert!(
            create
                .headers
                .iter()
                .any(|h| h.name == "Content-Type" && h.value == "application/json")
        );
    }

    #[test]
    fn attach_urls_switch_scheme_and_carry_options() {
        let local = endpoint("http://127.0.0.1:6767");
        assert_eq!(
            local
                .attach_request("terminal_bash_s1", &AttachOptions::default())
                .unwrap()
                .url,
            "ws://127.0.0.1:6767/v1/sessions/conv_1/resources/terminals/terminal_bash_s1/attach"
        );
        let hosted = endpoint("https://example.test/mount");
        let request = hosted
            .attach_request(
                "terminal_bash_s1",
                &AttachOptions {
                    read_only: true,
                    slice_key: Some("host_1".into()),
                },
            )
            .unwrap();
        assert_eq!(
            request.url,
            "wss://example.test/mount/v1/sessions/conv_1/resources/terminals/terminal_bash_s1/attach?read_only=true&omnigent_slice_key=host_1"
        );
    }

    #[test]
    fn invalid_inputs_send_nothing() {
        assert!(TerminalEndpoint::new(Url::parse("http://x").unwrap(), "a/b").is_err());
        assert!(TerminalEndpoint::new(Url::parse("ftp://x").unwrap(), "s").is_err());
        let endpoint = endpoint("http://x");
        assert!(matches!(
            endpoint.list_request(&ListTerminals {
                limit: 0,
                ..ListTerminals::default()
            }),
            Err(TerminalError::InvalidRequest { .. })
        ));
        assert!(endpoint.get_request("../x").is_err());
        assert!(
            endpoint
                .create_request(&CreateTerminal {
                    terminal: String::new(),
                    session_key: "k".into()
                })
                .is_err()
        );
        assert!(
            endpoint
                .create_request(&CreateTerminal {
                    terminal: "zsh".into(),
                    session_key: "a b".into()
                })
                .is_err()
        );
    }

    #[test]
    fn session_keys_look_like_the_web_clients() {
        assert_eq!(user_session_key(0), "u-000000");
        assert_eq!(user_session_key(35), "u-00000z");
        let key = user_session_key(u64::MAX);
        assert_eq!(key.len(), 8);
        assert!(is_identifier(&key));
        assert_eq!(CreateTerminal::new_shell("zsh", 36).session_key, "u-000010");
    }

    #[test]
    fn statuses_map_to_typed_errors() {
        let error_body =
            json!({"error": {"code": "invalid_input", "message": "Terminal 'x' is not declared"}});
        assert_eq!(
            resource_response(response(400, &error_body)),
            Err(TerminalError::Rejected {
                status: 400,
                message: "Terminal 'x' is not declared".into()
            })
        );
        assert!(matches!(
            list_response(response(401, &json!({"error": "unauthorized"}))),
            Err(TerminalError::Unauthorized { .. })
        ));
        assert!(matches!(
            list_response(response(403, &json!({"detail": "no"}))),
            Err(TerminalError::Forbidden { .. })
        ));
        for status in [409, 502, 503] {
            assert!(matches!(
                list_response(response(status, &json!({}))),
                Err(TerminalError::RunnerUnavailable { .. })
            ));
        }
        assert!(matches!(
            list_response(response(302, &json!({}))),
            Err(TerminalError::Redirected { status: 302 })
        ));
        assert!(matches!(
            list_response(response(500, &json!({}))),
            Err(TerminalError::HttpStatus { status: 500, .. })
        ));
        assert_eq!(
            list_response(Err(TransportError::Offline {
                message: "down".into()
            })),
            Err(TerminalError::Transport(TransportError::Offline {
                message: "down".into()
            }))
        );
        assert!(matches!(
            list_response(Ok(HttpResponse {
                status: 200,
                headers: Vec::new(),
                body: b"<html>".to_vec()
            })),
            Err(TerminalError::MalformedResponse { .. })
        ));
    }

    #[test]
    fn delete_treats_404_as_already_gone_and_checks_the_ack() {
        assert_eq!(
            delete_response("t1", response(404, &json!({}))),
            Ok(DeleteOutcome::AlreadyGone)
        );
        assert_eq!(
            delete_response(
                "t1",
                response(
                    200,
                    &json!({"id": "t1", "object": "session.resource.deleted", "deleted": true})
                )
            ),
            Ok(DeleteOutcome::Deleted)
        );
        assert!(
            delete_response("t1", response(200, &json!({"id": "t2", "deleted": true}))).is_err()
        );
        assert!(
            delete_response("t1", response(200, &json!({"id": "t1", "deleted": false}))).is_err()
        );
        assert!(matches!(
            delete_response("t1", response(403, &json!({}))),
            Err(TerminalError::Forbidden { .. })
        ));
    }
}
