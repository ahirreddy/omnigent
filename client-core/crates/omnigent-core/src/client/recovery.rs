//! Recovering a failed turn: continue it in place, or resume the session's runner
//! (`retry_session`). Neither is retried automatically.

use serde_json::{Value, json};

use super::json::{as_object, opt_bool};
use super::{ClientCore, SessionError, lock};
use crate::http::HttpTransport;
use crate::recovery::{CONTINUE_PROMPT, FailureRecovery};

impl<T: HttpTransport> ClientCore<T> {
    /// Recovers `session_id`'s failed turn as `recovery` says. Returns whether anything was
    /// recovered: a resume of a session whose runner is already connected does nothing.
    ///
    /// # Errors
    ///
    /// The preflight errors ([`SessionError::ReadOnly`] included); [`SessionError::MessageDenied`]
    /// when a policy blocks the continuation; the write errors; and
    /// [`SessionError::DeliveryUncertain`] for an unreadable acknowledgement.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn recover_turn(
        &self,
        session_id: &str,
        recovery: FailureRecovery,
    ) -> Result<bool, SessionError> {
        let result = self.post_recovery(session_id, recovery).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn post_recovery(
        &self,
        session_id: &str,
        recovery: FailureRecovery,
    ) -> Result<bool, SessionError> {
        self.editable(session_id).await?;
        let path = format!("/v1/sessions/{session_id}/events");
        let body = match recovery {
            FailureRecovery::Continue => json!({"type": "message", "data": {"role": "user",
                "content": [{"type": "input_text", "text": CONTINUE_PROMPT}]}}),
            FailureRecovery::Resume => json!({"type": "retry_session", "data": {}}),
        };
        let value = self.write_json("POST", &path, &body).await?;
        let recovered =
            acknowledged(&value, recovery).map_err(|detail| SessionError::DeliveryUncertain {
                detail: format!("unreadable {path} acknowledgement: {detail}"),
            })?;
        lock(&self.state).request_rehydration(session_id);
        recovered
    }
}

fn acknowledged(
    value: &Value,
    recovery: FailureRecovery,
) -> Result<Result<bool, SessionError>, String> {
    let object = as_object(value, "acknowledgement")?;
    if opt_bool(object, "denied")? == Some(true) {
        return Ok(Err(SessionError::MessageDenied {
            reason: super::json::opt_str(object, "reason")?,
        }));
    }
    Ok(Ok(match recovery {
        FailureRecovery::Continue => opt_bool(object, "queued")?.ok_or("`queued` is missing")?,
        FailureRecovery::Resume => {
            opt_bool(object, "recovered")?.ok_or("`recovered` is missing")?
        }
    }))
}
