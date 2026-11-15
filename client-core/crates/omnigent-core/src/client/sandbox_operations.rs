//! What a client can ask of a sandbox session: wake it (`retry_session`) or stop its agent
//! (`stop_session`). One request each, never retried.

use serde_json::json;

use super::json::{as_object, opt_bool};
use super::requests::{acknowledgement, error_code, refused_write, rejection_message};
use super::{ClientCore, SessionError, lock};
use crate::http::HttpTransport;
use crate::sandbox_state::{SandboxOperation, SandboxOperationOutcome};

impl<T: HttpTransport> ClientCore<T> {
    /// Asks the server for `operation` on `session_id` with one event: `retry_session` wakes the
    /// sandbox (or relaunches it) and starts its agent, `stop_session` ends the agent's process.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; [`SessionError::ReadOnly`] from
    /// the cached row or the server's `403`; [`SessionError::SessionNotFound`] for its `404`;
    /// [`SessionError::Rejected`] with the server's reason when it refused, also for a `503`
    /// that carries one (the runner could not be brought back or reached); the write errors;
    /// and [`SessionError::DeliveryUncertain`] for any other `503` or an unreadable answer.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn sandbox_operation(
        &self,
        session_id: &str,
        operation: SandboxOperation,
    ) -> Result<SandboxOperationOutcome, SessionError> {
        let result = self.post_sandbox_operation(session_id, operation).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn post_sandbox_operation(
        &self,
        session_id: &str,
        operation: SandboxOperation,
    ) -> Result<SandboxOperationOutcome, SessionError> {
        self.cached_editable(session_id)?;
        let path = format!("/v1/sessions/{session_id}/events");
        let event = match operation {
            SandboxOperation::Wake => "retry_session",
            SandboxOperation::Stop => "stop_session",
        };
        let body = json!({"type": event, "data": {}});
        // The server answers both events with `503` and its reason when the runner could not be
        // brought back or reached; that answer is read here instead of passing for a lost write.
        let prepared = self.prepare("POST", &path, &[], Some(&body))?;
        let response = self
            .write_allowing(prepared, Some(503))
            .await
            .map_err(refused_write(session_id))?;
        lock(&self.state).request_rehydration(session_id);
        if response.status == 503 {
            return Err(if error_code(&response.body).is_some() {
                SessionError::Rejected {
                    status: 503,
                    message: rejection_message(&response.body, 503),
                }
            } else {
                SessionError::DeliveryUncertain {
                    detail: format!("{path} answered HTTP 503"),
                }
            });
        }
        if operation == SandboxOperation::Stop {
            return Ok(SandboxOperationOutcome::Stopped);
        }
        let value = acknowledgement(&path, &response)?;
        let recovered = as_object(&value, "acknowledgement")
            .and_then(|object| opt_bool(object, "recovered"))
            .and_then(|recovered| recovered.ok_or_else(|| "`recovered` is missing".to_owned()))
            .map_err(|detail| SessionError::DeliveryUncertain {
                detail: format!("unreadable {path} acknowledgement: {detail}"),
            })?;
        Ok(if recovered {
            SandboxOperationOutcome::Started
        } else {
            SandboxOperationOutcome::AlreadyRunning
        })
    }
}
