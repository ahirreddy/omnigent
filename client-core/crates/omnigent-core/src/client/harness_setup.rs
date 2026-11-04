//! Harness setup over REST: the server's setup steps (`GET /v1/harnesses`), the hosts'
//! readiness, installing a harness and writing its credential on a host
//! (`POST /v1/hosts/{id}/harnesses/{harness}/install` and `.../credential`), and the credentials
//! a host already has (`GET /v1/hosts/{id}/credentials/detected`). Installs and credential
//! writes are never retried.

use std::collections::BTreeMap;

use serde_json::Value;

use super::json::{as_object, opt_array};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::harness_setup::{
    CredentialInput, DetectedCredential, HarnessAvailability, HarnessSetupCatalog, SetupFeatures,
    SetupHost, acknowledged_availability, credential_body, harness_definitions, ordered_hosts,
};
use crate::http::HttpTransport;

fn decode_rows<R>(
    value: &Value,
    path: &str,
    key: &str,
    decode: impl Fn(&Value) -> Result<R, String>,
) -> Result<Vec<R>, SessionError> {
    let malformed = |detail: String| SessionError::MalformedResponse {
        detail: format!("{path}: {detail}"),
    };
    let object = as_object(value, path).map_err(malformed)?;
    opt_array(object, key)
        .map_err(malformed)?
        .ok_or_else(|| malformed(format!("`{key}` is missing")))?
        .iter()
        .map(|row| decode(row).map_err(malformed))
        .collect()
}

impl<T: HttpTransport> ClientCore<T> {
    /// The setup features, the server's harness setup steps and the hosts.
    ///
    /// # Errors
    ///
    /// The read errors and [`SessionError::MalformedResponse`]. A server without
    /// `/v1/harnesses` (`404`) has no steps rather than an error.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn harness_setup_catalog(&self) -> Result<HarnessSetupCatalog, SessionError> {
        let result = async {
            let info = self.get_json("/v1/info", &[]).await?;
            let features = SetupFeatures::from_value(&info)
                .map_err(|detail| SessionError::MalformedResponse { detail })?;
            let harnesses = match self.get_json("/v1/harnesses", &[]).await {
                Ok(value) => harness_definitions(&value).map_err(|detail| {
                    SessionError::MalformedResponse {
                        detail: format!("/v1/harnesses: {detail}"),
                    }
                })?,
                Err(SessionError::HttpStatus { status: 404 }) => Vec::new(),
                Err(error) => return Err(error),
            };
            let hosts = self
                .host_rows()
                .await?
                .iter()
                .map(SetupHost::from_value)
                .collect::<Result<Vec<_>, String>>()
                .map_err(|detail| SessionError::MalformedResponse {
                    detail: format!("/v1/hosts: {detail}"),
                })?;
            Ok(HarnessSetupCatalog {
                features,
                harnesses,
                hosts: ordered_hosts(hosts),
            })
        }
        .await;
        self.dispatch();
        result
    }

    /// Installs `harness` on `host_id`; returns the host's refreshed readiness. Never retried.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request, and the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn install_harness(
        &self,
        host_id: &str,
        harness: &str,
    ) -> Result<BTreeMap<String, HarnessAvailability>, SessionError> {
        let result = async {
            validate_identifier(host_id)?;
            validate_identifier(harness)?;
            let path = format!("/v1/hosts/{host_id}/harnesses/{harness}/install");
            let value = self
                .write_json("POST", &path, &Value::Object(serde_json::Map::new()))
                .await?;
            acknowledged(&value, &path)
        }
        .await;
        self.dispatch();
        result
    }

    /// Writes a credential for `harness` on `host_id`; returns the host's refreshed readiness.
    /// The secret goes only to the server, which forwards it to the host. Never retried.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] and [`SessionError::InvalidInput`] before any
    /// request, and the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn store_harness_credential(
        &self,
        host_id: &str,
        harness: &str,
        input: &CredentialInput,
    ) -> Result<BTreeMap<String, HarnessAvailability>, SessionError> {
        let result = async {
            validate_identifier(host_id)?;
            validate_identifier(harness)?;
            let body =
                credential_body(input).map_err(|reason| SessionError::InvalidInput { reason })?;
            let path = format!("/v1/hosts/{host_id}/harnesses/{harness}/credential");
            let value = self.write_json("POST", &path, &body).await?;
            acknowledged(&value, &path)
        }
        .await;
        self.dispatch();
        result
    }

    /// The credentials `host_id` already has (non-secret descriptors), for adopting one.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request, the read errors and
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn detected_credentials(
        &self,
        host_id: &str,
    ) -> Result<Vec<DetectedCredential>, SessionError> {
        let result = async {
            validate_identifier(host_id)?;
            let path = format!("/v1/hosts/{host_id}/credentials/detected");
            let value = self.get_json(&path, &[]).await?;
            decode_rows(&value, &path, "credentials", DetectedCredential::from_value)
        }
        .await;
        self.dispatch();
        result
    }
}

fn acknowledged(
    value: &Value,
    path: &str,
) -> Result<BTreeMap<String, HarnessAvailability>, SessionError> {
    acknowledged_availability(value).map_err(|detail| SessionError::DeliveryUncertain {
        detail: format!("unreadable acknowledgement from {path}: {detail}"),
    })
}

#[cfg(test)]
#[path = "harness_setup_tests.rs"]
mod tests;
