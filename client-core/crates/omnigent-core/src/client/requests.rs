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
//! one, and the bearer when the connection has one; never a cookie.

#![allow(
    clippy::redundant_pub_crate,
    reason = "crate-internal helpers of a private module; `pub` would trip rustc's unreachable_pub"
)]

use serde_json::Value;

use super::{ClientCore, SessionError, lock};
use crate::attachments::policy::is_identifier;
use crate::auth::mode::error_text;
use crate::http::{HttpHeader, HttpRequest, HttpResponse, HttpTransport, TransportError};

/// The largest page any list route accepts.
pub(crate) const MAX_PAGE_LIMIT: u32 = 1000;

/// A request bound to the connection epoch it was built in.
#[derive(Debug)]
pub(crate) struct Prepared {
    pub(crate) request: HttpRequest,
    pub(crate) epoch: u64,
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
        })
    }

    /// Sends a read and applies the read status policy. A result from an older connection is
    /// [`SessionError::NotConnected`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(crate) async fn read(&self, prepared: Prepared) -> Result<HttpResponse, SessionError> {
        let result = self.transport.send(prepared.request).await;
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
        let result = self.transport.send(prepared.request).await;
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
