//! Skill discovery for an existing session's composer (`GET /v1/skills?session_id=`), and the
//! server side of its built-in commands: which the server supports (`GET /v1/info`) and `/clear`.

use serde_json::json;

use super::requests::{refused_write, validate_identifier};
use super::{ClientCore, SessionError, lock};
use crate::http::HttpTransport;
use crate::slash::{SkillCatalog, SlashOptions};

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

    /// The skills `harness` would see in `path` on `host_id` (`GET /v1/skills?host_id=`), for
    /// the new-session composer before a session exists.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; the read errors (503 while the
    /// host is offline); [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn host_skills(
        &self,
        host_id: &str,
        harness: &str,
        path: &str,
        agent_id: Option<&str>,
    ) -> Result<SkillCatalog, SessionError> {
        validate_identifier(host_id)?;
        let route = "/v1/skills";
        let mut query = vec![
            ("host_id", host_id.to_owned()),
            ("harness", harness.to_owned()),
            ("path", path.to_owned()),
        ];
        if let Some(agent_id) = agent_id.filter(|id| !id.is_empty()) {
            query.push(("agent_id", agent_id.to_owned()));
        }
        let value = self.get_json(route, &query).await;
        self.dispatch();
        SkillCatalog::from_value(&value?).map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{route}: {detail}"),
        })
    }

    /// Which server-backed commands the composer may offer (`GET /v1/info`). Older servers
    /// reject the `clear` control, so `/clear` stays plain text there.
    ///
    /// # Errors
    ///
    /// The read errors and [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn slash_options(&self) -> Result<SlashOptions, SessionError> {
        let value = self.get_json("/v1/info", &[]).await;
        self.dispatch();
        SlashOptions::from_info(&value?).map_err(|detail| SessionError::MalformedResponse {
            detail: format!("/v1/info: {detail}"),
        })
    }

    /// Runs the harness's own `/clear` in the session terminal (`clear` event). The terminal
    /// moves to a fresh session, announced by `session.superseded`, which the view follows.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; [`SessionError::ReadOnly`] when
    /// the cached row is below edit permission or the server answers `403`;
    /// [`SessionError::SessionNotFound`] for its `404`; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn clear_context(&self, session_id: &str) -> Result<(), SessionError> {
        let result = self.post_clear(session_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn post_clear(&self, session_id: &str) -> Result<(), SessionError> {
        self.cached_editable(session_id)?;
        let path = format!("/v1/sessions/{session_id}/events");
        let body = json!({"type": "clear", "data": {}});
        self.write(self.prepare("POST", &path, &[], Some(&body))?)
            .await
            .map_err(refused_write(session_id))?;
        lock(&self.state).request_rehydration(session_id);
        Ok(())
    }
}
