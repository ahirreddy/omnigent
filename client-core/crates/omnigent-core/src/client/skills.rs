//! Skill discovery for an existing session's composer (`GET /v1/skills?session_id=`).

use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;
use crate::slash::SkillCatalog;

impl<T: HttpTransport> ClientCore<T> {
    /// The skills `session_id`'s host offers it, for the composer's `/` menu.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; the read errors (409 while the
    /// session's host is not ready, 503 while it is offline); [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn session_skills(&self, session_id: &str) -> Result<SkillCatalog, SessionError> {
        validate_identifier(session_id)?;
        let path = "/v1/skills";
        let value = self
            .get_json(path, &[("session_id", session_id.to_owned())])
            .await;
        self.dispatch();
        SkillCatalog::from_value(&value?).map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        })
    }
}
