//! Push device registration: `/v1/notifications/{capabilities,devices}`.
//!
//! These routes came from `NativeLab`'s own server patch and are not on the current server
//! (wire-contract divergence D7). A 404 therefore means [`PushSupport::Unsupported`], a typed
//! result the app must handle (the app works without push), not an error to retry or swallow.
//!
//! Requests are built on a [`ServerEndpoint`], so they carry the Databricks org header and never
//! the `?o=` query, and a bearer when given. Identity comes from authentication: the body never
//! carries a user id. Redirects are never followed.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::route::is_valid_identifier;
use crate::auth::SecretString;
use crate::auth::endpoint::ServerEndpoint;
use crate::auth::errors::HostedAuthError;
use crate::http::{HttpHeader, HttpRequest, HttpResponse, TransportError};

/// Whether the server has the push routes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PushSupport<T> {
    /// The route answered.
    Supported(T),
    /// HTTP 404: this server has no push registration routes.
    Unsupported,
}

/// Why a push registration call failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PushError {
    /// The request could not be built (bad path, bad bearer, or a bearer for a local server).
    #[error("{0}")]
    Endpoint(HostedAuthError),
    /// An installation or session id that is not a plain identifier. Nothing was sent.
    #[error("invalid push identifier {value:?}")]
    InvalidIdentifier {
        /// The value.
        value: String,
    },
    /// An empty device token, environment or topic. Nothing was sent.
    #[error("the push registration has an empty {field}")]
    EmptyField {
        /// The field.
        field: &'static str,
    },
    /// The host got no response.
    #[error("{0}")]
    Transport(TransportError),
    /// A redirect, which is never followed.
    #[error("the server redirected the push request (HTTP {status})")]
    Redirect {
        /// The 3xx status.
        status: u16,
    },
    /// HTTP 401: the caller must drop the connection and ask for sign-in again.
    #[error("not signed in")]
    Unauthorized,
    /// HTTP 403.
    #[error("not allowed to manage push notifications")]
    Forbidden,
    /// Any other non-2xx status.
    #[error("push request failed with HTTP {status}: {body}")]
    HttpStatus {
        /// The status.
        status: u16,
        /// Response body, decoded lossily.
        body: String,
    },
    /// A capabilities body that does not decode.
    #[error("malformed push capabilities: {message}")]
    Decode {
        /// What was wrong.
        message: String,
    },
}

/// `GET /v1/notifications/capabilities`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushCapabilities {
    /// Push is configured.
    pub available: bool,
    /// What the server lacks when it is not.
    pub missing_configuration: Vec<String>,
    /// The server's own idea of its URL.
    pub server_url: Option<String>,
    /// APNs environment (`sandbox` or `production`).
    pub environment: Option<String>,
    /// APNs topic.
    pub topic: Option<String>,
    /// Workspace notifications are scoped to.
    pub workspace_id: String,
    /// The server says it is a local development server.
    pub local_development: Option<bool>,
}

impl PushCapabilities {
    /// Decodes the capabilities body.
    ///
    /// # Errors
    ///
    /// [`PushError::Decode`] for a missing `available` or `workspace_id`, or wrongly typed fields.
    pub fn from_json(value: &Value) -> Result<Self, PushError> {
        let object = value
            .as_object()
            .ok_or_else(|| decode("expected an object"))?;
        let optional_string = |key: &str| -> Result<Option<String>, PushError> {
            match object.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(value)) => Ok(Some(value.clone())),
                Some(_) => Err(decode(&format!("{key} is not a string"))),
            }
        };
        let missing_configuration = match object.get("missing_configuration") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(values)) => values
                .iter()
                .map(|value| {
                    value
                        .as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| decode("missing_configuration has a non-string entry"))
                })
                .collect::<Result<_, _>>()?,
            Some(_) => return Err(decode("missing_configuration is not an array")),
        };
        Ok(Self {
            available: object
                .get("available")
                .and_then(Value::as_bool)
                .ok_or_else(|| decode("available is not a boolean"))?,
            missing_configuration,
            server_url: optional_string("server_url")?,
            environment: optional_string("environment")?,
            topic: optional_string("topic")?,
            workspace_id: optional_string("workspace_id")?
                .ok_or_else(|| decode("workspace_id is missing"))?,
            local_development: match object.get("local_development") {
                None | Some(Value::Null) => None,
                Some(Value::Bool(value)) => Some(*value),
                Some(_) => return Err(decode("local_development is not a boolean")),
            },
        })
    }
}

fn decode(message: &str) -> PushError {
    PushError::Decode {
        message: message.to_owned(),
    }
}

/// `PUT /v1/notifications/devices`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushRegistration {
    installation_id: String,
    device_token: String,
    environment: String,
    topic: String,
    session_ids: Vec<String>,
}

impl PushRegistration {
    /// A registration for the watched `session_ids`, kept sorted and unique.
    ///
    /// # Errors
    ///
    /// [`PushError::InvalidIdentifier`] for a bad installation or session id and
    /// [`PushError::EmptyField`] for an empty token, environment or topic.
    pub fn new(
        installation_id: &str,
        device_token: &str,
        environment: &str,
        topic: &str,
        session_ids: impl IntoIterator<Item = String>,
    ) -> Result<Self, PushError> {
        let identifier = |value: &str| {
            if is_valid_identifier(value) {
                Ok(())
            } else {
                Err(PushError::InvalidIdentifier {
                    value: value.to_owned(),
                })
            }
        };
        identifier(installation_id)?;
        for (field, value) in [
            ("device_token", device_token),
            ("environment", environment),
            ("topic", topic),
        ] {
            if value.is_empty() {
                return Err(PushError::EmptyField { field });
            }
        }
        let session_ids: BTreeSet<String> = session_ids.into_iter().collect();
        session_ids.iter().try_for_each(|id| identifier(id))?;
        Ok(Self {
            installation_id: installation_id.to_owned(),
            device_token: device_token.to_owned(),
            environment: environment.to_owned(),
            topic: topic.to_owned(),
            session_ids: session_ids.into_iter().collect(),
        })
    }

    /// The installation id.
    #[must_use]
    pub fn installation_id(&self) -> &str {
        &self.installation_id
    }

    /// The sorted, unique session ids.
    #[must_use]
    pub fn session_ids(&self) -> &[String] {
        &self.session_ids
    }

    /// The request body. It never carries a user id.
    #[must_use]
    pub fn body(&self) -> Value {
        json!({
            "installation_id": self.installation_id,
            "device_token": self.device_token,
            "environment": self.environment,
            "topic": self.topic,
            "session_ids": self.session_ids,
        })
    }
}

fn request(
    endpoint: &ServerEndpoint,
    bearer: Option<&SecretString>,
    method: &str,
    path: &str,
    body: Option<&Value>,
) -> Result<HttpRequest, PushError> {
    let mut request = endpoint
        .request_with(method, path, &[], "application/json", bearer)
        .map_err(PushError::Endpoint)?;
    if let Some(body) = body {
        request
            .headers
            .push(HttpHeader::new("Content-Type", "application/json"));
        request.body = Some(body.to_string().into_bytes());
    }
    Ok(request)
}

/// `GET /v1/notifications/capabilities`.
///
/// # Errors
///
/// [`PushError::Endpoint`].
pub fn capabilities_request(
    endpoint: &ServerEndpoint,
    bearer: Option<&SecretString>,
) -> Result<HttpRequest, PushError> {
    request(
        endpoint,
        bearer,
        "GET",
        "/v1/notifications/capabilities",
        None,
    )
}

/// `PUT /v1/notifications/devices`.
///
/// # Errors
///
/// [`PushError::Endpoint`].
pub fn register_request(
    endpoint: &ServerEndpoint,
    bearer: Option<&SecretString>,
    registration: &PushRegistration,
) -> Result<HttpRequest, PushError> {
    request(
        endpoint,
        bearer,
        "PUT",
        "/v1/notifications/devices",
        Some(&registration.body()),
    )
}

/// `DELETE /v1/notifications/devices/{installation_id}`.
///
/// # Errors
///
/// [`PushError::InvalidIdentifier`] or [`PushError::Endpoint`].
pub fn unregister_request(
    endpoint: &ServerEndpoint,
    bearer: Option<&SecretString>,
    installation_id: &str,
) -> Result<HttpRequest, PushError> {
    if !is_valid_identifier(installation_id) {
        return Err(PushError::InvalidIdentifier {
            value: installation_id.to_owned(),
        });
    }
    request(
        endpoint,
        bearer,
        "DELETE",
        &format!("/v1/notifications/devices/{installation_id}"),
        None,
    )
}

/// The 2xx response, `Unsupported` for 404, or the error for anything else.
fn supported(
    result: Result<HttpResponse, TransportError>,
) -> Result<PushSupport<HttpResponse>, PushError> {
    let response = result.map_err(PushError::Transport)?;
    match response.status {
        200..=299 => Ok(PushSupport::Supported(response)),
        404 => Ok(PushSupport::Unsupported),
        status @ 300..=399 => Err(PushError::Redirect { status }),
        401 => Err(PushError::Unauthorized),
        403 => Err(PushError::Forbidden),
        status => Err(PushError::HttpStatus {
            status,
            body: String::from_utf8_lossy(&response.body).into_owned(),
        }),
    }
}

/// Maps the result of [`capabilities_request`].
///
/// # Errors
///
/// See [`PushError`].
pub fn capabilities_response(
    result: Result<HttpResponse, TransportError>,
) -> Result<PushSupport<PushCapabilities>, PushError> {
    match supported(result)? {
        PushSupport::Unsupported => Ok(PushSupport::Unsupported),
        PushSupport::Supported(response) => {
            let value: Value =
                serde_json::from_slice(&response.body).map_err(|error| PushError::Decode {
                    message: error.to_string(),
                })?;
            PushCapabilities::from_json(&value).map(PushSupport::Supported)
        }
    }
}

/// Maps the result of [`register_request`] or [`unregister_request`].
///
/// # Errors
///
/// See [`PushError`]. A 401 is [`PushError::Unauthorized`]: drop the connection.
pub fn mutation_response(
    result: Result<HttpResponse, TransportError>,
) -> Result<PushSupport<()>, PushError> {
    Ok(match supported(result)? {
        PushSupport::Supported(_) => PushSupport::Supported(()),
        PushSupport::Unsupported => PushSupport::Unsupported,
    })
}
