//! Harness setup over REST: the server's setup steps (`GET /v1/harnesses`), the hosts'
//! readiness, installing a harness and writing its credential on a host
//! (`POST /v1/hosts/{id}/harnesses/{harness}/install` and `.../credential`), and the credentials
//! a host already has (`GET /v1/hosts/{id}/credentials/detected`). Installs and credential
//! writes are never retried.

use std::collections::BTreeMap;

use serde_json::Value;

use super::json::{as_object, opt_array, opt_str};
use super::requests::{rejection_message, validate_identifier};
use super::{ClientCore, SessionError};
use crate::harness_accounts::{
    HarnessStartup, HostSnapshot, InstallOutcome, LoginStart, LoginStartOutcome, LoginStatus,
    StartupRead, account_key, busy_login_id,
};
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

impl<T: HttpTransport> ClientCore<T> {
    /// Installs (or updates) `harness` on `host_id`, keeping the version and accounts the host
    /// reported. Never retried.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request, and the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn install_harness_reporting(
        &self,
        host_id: &str,
        harness: &str,
    ) -> Result<InstallOutcome, SessionError> {
        let result = async {
            validate_identifier(host_id)?;
            validate_identifier(harness)?;
            let path = format!("/v1/hosts/{host_id}/harnesses/{harness}/install");
            let value = self
                .write_json("POST", &path, &Value::Object(serde_json::Map::new()))
                .await?;
            let harnesses = acknowledged(&value, &path)?;
            let object = as_object(&value, &path).map_err(uncertain(&path))?;
            let mut snapshot = HostSnapshot::from_object(object).map_err(uncertain(&path))?;
            snapshot.harnesses = Some(harnesses);
            Ok(InstallOutcome {
                snapshot,
                version: opt_str(object, "version").map_err(uncertain(&path))?,
            })
        }
        .await;
        self.dispatch();
        result
    }

    /// Starts Codex's device-code sign-in on `host_id`; another one in progress is `Busy`.
    /// Never retried.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; [`SessionError::Rejected`] when
    /// the host cannot sign in from the app (`409 login_unsupported`); the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn start_harness_login(
        &self,
        host_id: &str,
        harness: &str,
    ) -> Result<LoginStartOutcome, SessionError> {
        let result = async {
            let path = login_path(host_id, harness, "login", None)?;
            let empty = Value::Object(serde_json::Map::new());
            match self.write_json_or_conflict("POST", &path, &empty).await? {
                Ok(value) => LoginStart::from_value(&value)
                    .map(LoginStartOutcome::Started)
                    .map_err(|detail| SessionError::MalformedResponse {
                        detail: format!("{path}: {detail}"),
                    }),
                Err(body) => busy_login_id(&body).map_or_else(
                    || {
                        Err(SessionError::Rejected {
                            status: 409,
                            message: rejection_message(body.to_string().as_bytes(), 409),
                        })
                    },
                    |login_id| Ok(LoginStartOutcome::Busy { login_id }),
                ),
            }
        }
        .await;
        self.dispatch();
        result
    }

    /// A device sign-in's status.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`], the read errors and `MalformedResponse`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn harness_login_status(
        &self,
        host_id: &str,
        harness: &str,
        login_id: &str,
    ) -> Result<LoginStatus, SessionError> {
        let result = async {
            let path = login_path(host_id, harness, "login", Some(login_id))?;
            let value = self.get_json(&path, &[]).await?;
            LoginStatus::from_value(&value).map_err(|detail| SessionError::MalformedResponse {
                detail: format!("{path}: {detail}"),
            })
        }
        .await;
        self.dispatch();
        result
    }

    /// Cancels a device sign-in.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] and the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn cancel_harness_login(
        &self,
        host_id: &str,
        harness: &str,
        login_id: &str,
    ) -> Result<(), SessionError> {
        let result = async {
            let path = login_path(host_id, harness, "login", Some(login_id))?;
            self.write(self.prepare("DELETE", &path, &[], None)?)
                .await?;
            Ok(())
        }
        .await;
        self.dispatch();
        result
    }

    /// Signs Codex or Claude out on `host_id`; returns the refreshed readiness and accounts.
    /// Never retried.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request, and the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn sign_out_harness(
        &self,
        host_id: &str,
        harness: &str,
    ) -> Result<HostSnapshot, SessionError> {
        let result = async {
            let path = login_path(host_id, harness, "logout", None)?;
            let value = self
                .write_json("POST", &path, &Value::Object(serde_json::Map::new()))
                .await?;
            snapshot(&value, &path)
        }
        .await;
        self.dispatch();
        result
    }

    /// Asks `host_id` to check its harnesses now. When the host or server cannot, answers with
    /// the readiness the host last reported (`GET /v1/hosts/{id}`).
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`], the write errors and the read errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn refresh_harnesses(&self, host_id: &str) -> Result<HostSnapshot, SessionError> {
        let result = async {
            validate_identifier(host_id)?;
            let path = format!("/v1/hosts/{host_id}/harnesses/refresh");
            let empty = Value::Object(serde_json::Map::new());
            match self.write_json_or_conflict("POST", &path, &empty).await {
                Ok(Ok(value)) => snapshot(&value, &path),
                // 409 refresh_unsupported, another refusal, or a host too slow to answer (504).
                Ok(Err(_))
                | Err(SessionError::Rejected { .. } | SessionError::DeliveryUncertain { .. }) => {
                    let host_path = format!("/v1/hosts/{host_id}");
                    let value = self.get_json(&host_path, &[]).await?;
                    snapshot(&value, &host_path)
                }
                Err(error) => Err(error),
            }
        }
        .await;
        self.dispatch();
        result
    }

    /// `harness`'s startup command on `host_id` (named `host_name`), or why the host does not
    /// report it: `404` (not reported) or `501` (an older host).
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`], the read errors and `MalformedResponse`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn harness_startup(
        &self,
        host_id: &str,
        harness: &str,
        host_name: &str,
    ) -> Result<StartupRead, SessionError> {
        let result = async {
            validate_identifier(host_id)?;
            validate_identifier(harness)?;
            let path = format!("/v1/hosts/{host_id}/harnesses/{harness}/startup");
            match self.get_json(&path, &[]).await {
                Ok(value) => HarnessStartup::from_value(&value, harness, host_name)
                    .map(StartupRead::Loaded)
                    .map_err(|detail| SessionError::MalformedResponse {
                        detail: format!("{path}: {detail}"),
                    }),
                Err(SessionError::HttpStatus { status: 404 }) => Ok(StartupRead::NotReported),
                Err(SessionError::HttpStatus { status: 501 }) => Ok(StartupRead::HostOutdated),
                Err(error) => Err(error),
            }
        }
        .await;
        self.dispatch();
        result
    }
}

/// `/v1/hosts/{host}/harnesses/{account key}/{operation}[/{login}]`.
fn login_path(
    host_id: &str,
    harness: &str,
    operation: &str,
    login_id: Option<&str>,
) -> Result<String, SessionError> {
    validate_identifier(host_id)?;
    let key = account_key(harness);
    validate_identifier(&key)?;
    let base = format!("/v1/hosts/{host_id}/harnesses/{key}/{operation}");
    match login_id {
        Some(id) => {
            validate_identifier(id)?;
            Ok(format!("{base}/{id}"))
        }
        None => Ok(base),
    }
}

fn uncertain(path: &str) -> impl Fn(String) -> SessionError + '_ {
    move |detail| SessionError::DeliveryUncertain {
        detail: format!("unreadable acknowledgement from {path}: {detail}"),
    }
}

fn snapshot(value: &Value, path: &str) -> Result<HostSnapshot, SessionError> {
    as_object(value, path)
        .and_then(HostSnapshot::from_object)
        .map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        })
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
