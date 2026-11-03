//! Request building and the status policy shared by every REST call.
//!
//! Reads and writes differ in what an unclear outcome means:
//!
//! - **Reads** accept 200 and 202. A 3xx is [`SessionError::RedirectNotAllowed`], 401 ends the
//!   connection, 403 is [`SessionError::Forbidden`], anything else is
//!   [`SessionError::HttpStatus`]. A transport failure keeps its kind.
//! - **Writes** accept 200, 201, 202 and 204. A transport failure, cancellation, 3xx, 5xx, a result
//!   from an older connection, or an unreadable acknowledgement is
//!   [`SessionError::DeliveryUncertain`]: the write may have landed and is never retried. A 401
//!   ends the connection; 403 and other 4xx definitely did not deliver.
//!
//! Requests carry `Accept: application/json`, the Databricks org header when the endpoint has
//! one, the replica routing key on a host-sharded server (see [`super::routing`]), and the bearer
//! when the connection has one; never a cookie. A `wrong_replica` refusal is re-addressed once.

#![allow(
    clippy::redundant_pub_crate,
    reason = "crate-internal helpers of a private module; `pub` would trip rustc's unreachable_pub"
)]

use std::collections::BTreeSet;

use serde_json::Value;

use super::routing::{self, Addressing, SLICE_KEY_HEADER};
use super::sessions::decode_snapshot;
use super::{ClientCore, SessionError, lock};
use crate::attachments::policy::is_identifier;
use crate::auth::mode::error_text;
use crate::http::{HttpHeader, HttpRequest, HttpResponse, HttpTransport, TransportError};

/// The largest page any list route accepts.
pub(crate) const MAX_PAGE_LIMIT: u32 = 1000;

/// How many snapshots a host lookup reads up a session's parent chain.
const MAX_HOST_CHAIN_READS: usize = 16;

/// A request bound to the connection epoch it was built in.
#[derive(Debug)]
pub(crate) struct Prepared {
    pub(crate) request: HttpRequest,
    pub(crate) epoch: u64,
    /// How it was addressed, on a host-sharded server.
    pub(crate) addressing: Option<Addressing>,
}

/// `value` is usable as one path segment.
pub(crate) fn validate_identifier(value: &str) -> Result<(), SessionError> {
    if is_identifier(value) {
        Ok(())
    } else {
        Err(SessionError::InvalidIdentifier {
            value: value.to_owned(),
        })
    }
}

/// `limit` and `order=desc`, plus `after` when given.
pub(crate) fn page_query(
    after: Option<&str>,
    limit: u32,
) -> Result<Vec<(&'static str, String)>, SessionError> {
    if !(1..=MAX_PAGE_LIMIT).contains(&limit) {
        return Err(SessionError::InvalidPageLimit { limit });
    }
    let mut query = vec![("limit", limit.to_string()), ("order", "desc".to_owned())];
    if let Some(after) = after {
        if after.is_empty() {
            return Err(SessionError::InvalidPagination);
        }
        query.push(("after", after.to_owned()));
    }
    Ok(query)
}

/// The server's explanation for a refused write: `error.message`, `error` (a string),
/// `detail` (a string), or a generic text.
pub(crate) fn rejection_message(body: &[u8], status: u16) -> String {
    let parsed: Option<Value> = serde_json::from_slice(body).ok();
    parsed
        .as_ref()
        .and_then(|value| {
            value
                .get("error")
                .and_then(|error| error.get("message"))
                .and_then(Value::as_str)
                .or_else(|| value.get("error").and_then(Value::as_str))
                .or_else(|| value.get("detail").and_then(Value::as_str))
        })
        .filter(|message| !message.trim().is_empty())
        .map_or_else(
            || format!("The server refused this request (HTTP {status})."),
            |message| message.chars().take(1000).collect(),
        )
}

fn read_transport_error(error: TransportError) -> SessionError {
    match error {
        TransportError::Cancelled => SessionError::Cancelled,
        other => SessionError::Transport(other),
    }
}

/// Addresses `request` (a full URL on the connected server, built outside [`ClientCore::prepare`]:
/// terminals, remote browsers) like `prepare` does, stamping the routing key; `None` when the
/// server does not route by host.
pub(super) fn address_built_request(
    state: &super::State,
    request: &mut HttpRequest,
) -> Option<Addressing> {
    if !state.routes_by_host() {
        return None;
    }
    let endpoint = state.connection.as_ref()?.endpoint();
    let url = url::Url::parse(&request.url).ok()?;
    let path = url
        .path()
        .strip_prefix(endpoint.mount())
        .unwrap_or_else(|| url.path())
        .to_owned();
    let addressing = state.routing.address(&request.method, &path, &[], None);
    if let (Some(host), true) = (&addressing.host, addressing.keyed) {
        request
            .headers
            .push(HttpHeader::new(SLICE_KEY_HEADER, host.as_str()));
    }
    Some(addressing)
}

impl<T: HttpTransport> ClientCore<T> {
    /// Builds a request for `path` on the connected server.
    pub(crate) fn prepare(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, String)],
        body: Option<&Value>,
    ) -> Result<Prepared, SessionError> {
        let state = lock(&self.state);
        let connection = state
            .connection
            .as_ref()
            .filter(|connection| connection.is_connected())
            .ok_or(SessionError::NotConnected)?;
        let pairs: Vec<(&str, &str)> = query
            .iter()
            .map(|(name, value)| (*name, value.as_str()))
            .collect();
        let mut request = connection.request(method, path, &pairs, "application/json")?;
        let addressing = state
            .routes_by_host()
            .then(|| state.routing.address(method, path, query, body));
        if let Some(Addressing {
            host: Some(host),
            keyed: true,
            ..
        }) = &addressing
        {
            request
                .headers
                .push(HttpHeader::new(SLICE_KEY_HEADER, host.as_str()));
        }
        if let Some(body) = body {
            request
                .headers
                .push(HttpHeader::new("Content-Type", "application/json"));
            request.body = Some(serde_json::to_vec(body).map_err(|error| {
                SessionError::MalformedResponse {
                    detail: format!("could not encode the request body: {error}"),
                }
            })?);
        }
        Ok(Prepared {
            request,
            epoch: state.epoch,
            addressing,
        })
    }

    /// Sends `prepared`, re-addressing a `wrong_replica` refusal once: a keyed request without
    /// its key (remembering the host as keyless when that works), or a session request whose host
    /// was unknown with the host its snapshot names.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn send_routed(
        &self,
        request: HttpRequest,
        addressing: Option<Addressing>,
    ) -> Result<HttpResponse, TransportError> {
        let Some(addressing) = addressing else {
            return self.transport.send(request).await;
        };
        let response = self.transport.send(request.clone()).await?;
        if !routing::is_wrong_replica(response.status, &response.body) {
            return Ok(response);
        }
        if addressing.keyed {
            let mut keyless = request;
            keyless
                .headers
                .retain(|header| !header.name.eq_ignore_ascii_case(SLICE_KEY_HEADER));
            let retried = self.transport.send(keyless).await?;
            if (200..300).contains(&retried.status)
                && let Some(host) = &addressing.host
            {
                lock(&self.state).routing.mark_keyless(host);
            }
            return Ok(retried);
        }
        if let Some(host) = &addressing.host {
            // Sent keyless because the host was demoted, yet still the wrong replica: key it
            // again from the next request.
            lock(&self.state).routing.clear_keyless(host);
            return Ok(response);
        }
        let Some(session) = &addressing.unresolved_session else {
            return Ok(response);
        };
        let Some(host) = self.learn_session_host(session).await else {
            return Ok(response);
        };
        let mut keyed = request;
        keyed
            .headers
            .push(HttpHeader::new(SLICE_KEY_HEADER, host.as_str()));
        self.transport.send(keyed).await
    }

    /// The routing key to send on an event stream or WebSocket for `path` (a `GET`), on a
    /// host-sharded server; `None` elsewhere, or when the request should go keyless.
    pub fn slice_key(&self, path: &str) -> Option<String> {
        let state = lock(&self.state);
        if !state.routes_by_host() {
            return None;
        }
        let addressing = state.routing.address("GET", path, &[], None);
        addressing.keyed.then_some(addressing.host).flatten()
    }

    /// The modal host for routes with no host of their own (the session updates socket), once
    /// the first session list froze it, on a host-sharded server.
    pub fn modal_slice_key(&self) -> Option<String> {
        let state = lock(&self.state);
        if !state.routes_by_host() {
            return None;
        }
        state.routing.modal().map(str::to_owned)
    }

    /// An event stream on `path` was refused with HTTP 400 (the wrong replica; a stream's body is
    /// not read). The next attempt flips: keyless after a keyed refusal, keyed again after a
    /// keyless one for a demoted host.
    pub fn stream_refused(&self, path: &str, keyed: bool) {
        let mut state = lock(&self.state);
        if !state.routes_by_host() {
            return;
        }
        let Some(host) = state.routing.address("GET", path, &[], None).host else {
            return;
        };
        if keyed {
            state.routing.mark_keyless(&host);
        } else {
            state.routing.clear_keyless(&host);
        }
    }

    /// Learns a session's routing host from snapshots, which any replica serves: the session's,
    /// then each ancestor's until one names a host (a sub-agent runs on its parent's runner), as
    /// the web client does, reading at most [`MAX_HOST_CHAIN_READS`] snapshots.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn learn_session_host(&self, session_id: &str) -> Option<String> {
        let mut visited = BTreeSet::new();
        let mut current = session_id.to_owned();
        while visited.len() < MAX_HOST_CHAIN_READS && visited.insert(current.clone()) {
            self.read_routing_snapshot(&current).await?;
            let state = lock(&self.state);
            if let Some(host) = state.routing.session_host(session_id) {
                return Some(host.to_owned());
            }
            current = state.routing.parent(&current)?.to_owned();
        }
        None
    }

    /// Reads `session_id`'s snapshot and records its host and parent; `None` when it is
    /// unreadable.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn read_routing_snapshot(&self, session_id: &str) -> Option<()> {
        let path = format!("/v1/sessions/{session_id}");
        let request = {
            let state = lock(&self.state);
            let connection = state.connection.as_ref()?;
            connection
                .request(
                    "GET",
                    &path,
                    &[("include_items", "false")],
                    "application/json",
                )
                .ok()?
        };
        let response = self.transport.send(request).await.ok()?;
        if !(200..300).contains(&response.status) {
            return None;
        }
        let decoded = decode_snapshot(&response.body).ok()?;
        decoded
            .projection
            .record_routing(&mut lock(&self.state).routing);
        Some(())
    }

    /// Sends a read and applies the read status policy. A result from an older connection is
    /// [`SessionError::NotConnected`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(crate) async fn read(&self, prepared: Prepared) -> Result<HttpResponse, SessionError> {
        let result = self
            .send_routed(prepared.request, prepared.addressing)
            .await;
        let mut state = lock(&self.state);
        if state.epoch != prepared.epoch || !state.is_connected() {
            return Err(SessionError::NotConnected);
        }
        let response = result.map_err(read_transport_error)?;
        match response.status {
            200 | 202 => Ok(response),
            status @ 300..=399 => Err(SessionError::RedirectNotAllowed { status }),
            401 => {
                state.authentication_failed();
                Err(SessionError::Unauthorized {
                    reason: error_text(&response.body),
                })
            }
            403 => Err(SessionError::Forbidden),
            status => Err(SessionError::HttpStatus { status }),
        }
    }

    /// `GET path` and parse the body as JSON.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(crate) async fn get_json(
        &self,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<Value, SessionError> {
        let response = self.read(self.prepare("GET", path, query, None)?).await?;
        serde_json::from_slice(&response.body).map_err(|error| SessionError::MalformedResponse {
            detail: format!("{path}: {error}"),
        })
    }

    /// Sends a write and applies the write status policy.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(crate) async fn write(&self, prepared: Prepared) -> Result<HttpResponse, SessionError> {
        let path = prepared.request.url.clone();
        // A `wrong_replica` refusal did not deliver, so re-addressing it cannot duplicate a write.
        let result = self
            .send_routed(prepared.request, prepared.addressing)
            .await;
        let mut state = lock(&self.state);
        let uncertain = |detail: String| SessionError::DeliveryUncertain { detail };
        let response = result.map_err(|error| uncertain(error.to_string()))?;
        if state.epoch != prepared.epoch || !state.is_connected() {
            return Err(uncertain(
                "the connection ended while the write was in flight".into(),
            ));
        }
        match response.status {
            200..=202 | 204 => Ok(response),
            status @ 300..=399 => Err(uncertain(format!(
                "the server redirected the write (HTTP {status})"
            ))),
            401 => {
                state.authentication_failed();
                Err(SessionError::Unauthorized {
                    reason: error_text(&response.body),
                })
            }
            403 => Err(SessionError::Forbidden),
            status @ 400..=499 => Err(SessionError::Rejected {
                status,
                message: rejection_message(&response.body, status),
            }),
            status => Err(uncertain(format!(
                "{} answered HTTP {status}",
                redact_query(&path)
            ))),
        }
    }

    /// Sends a JSON write and parses the acknowledgement; an unreadable one is uncertain.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(crate) async fn write_json(
        &self,
        method: &str,
        path: &str,
        body: &Value,
    ) -> Result<Value, SessionError> {
        let response = self
            .write(self.prepare(method, path, &[], Some(body))?)
            .await?;
        serde_json::from_slice(&response.body).map_err(|error| SessionError::DeliveryUncertain {
            detail: format!("unreadable acknowledgement from {path}: {error}"),
        })
    }
}

fn redact_query(url: &str) -> &str {
    url.split_once('?').map_or(url, |(path, _)| path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn page_query_validates_limit_and_cursor() {
        assert_eq!(
            page_query(None, 0),
            Err(SessionError::InvalidPageLimit { limit: 0 })
        );
        assert_eq!(
            page_query(None, 1001),
            Err(SessionError::InvalidPageLimit { limit: 1001 })
        );
        assert_eq!(
            page_query(Some(""), 5),
            Err(SessionError::InvalidPagination)
        );
        assert_eq!(
            page_query(Some("c"), 1000).unwrap(),
            vec![
                ("limit", "1000".to_owned()),
                ("order", "desc".to_owned()),
                ("after", "c".to_owned())
            ]
        );
    }

    #[test]
    fn identifiers_must_be_plain_segments() {
        for id in ["", "../info", "a/b", "a?token=x", "a#fragment", "a b"] {
            assert!(validate_identifier(id).is_err(), "{id:?}");
        }
        assert_eq!(validate_identifier("conv_A-1"), Ok(()));
    }

    #[test]
    fn rejection_message_prefers_the_server_text() {
        assert_eq!(
            rejection_message(br#"{"error":{"message":"busy"}}"#, 409),
            "busy"
        );
        assert_eq!(rejection_message(br#"{"detail":"nope"}"#, 422), "nope");
        assert_eq!(
            rejection_message(b"<html>", 400),
            "The server refused this request (HTTP 400)."
        );
    }
}
