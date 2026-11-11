//! Row actions beyond organisation edits: stop, delete and leave a session (the web sidebar's
//! row menu, `useStopSession`, `useStopAndDeleteConversation` and `useLeaveSession`).

use serde_json::json;

use super::requests::{refused_write, validate_identifier};
use super::{ClientCore, ClientEvent, SessionError, lock};
use crate::auth::pkce::percent_encode;
use crate::http::HttpTransport;

impl<T: HttpTransport> ClientCore<T> {
    /// Ends the session's live process with one `stop_session` event. The transcript stays.
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
    pub async fn stop_session(&self, session_id: &str) -> Result<(), SessionError> {
        let result = self.stop(session_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn stop(&self, session_id: &str) -> Result<(), SessionError> {
        self.cached_editable(session_id)?;
        let path = format!("/v1/sessions/{session_id}/events");
        let body = json!({"type": "stop_session", "data": {}});
        self.write(self.prepare("POST", &path, &[], Some(&body))?)
            .await
            .map_err(refused_write(session_id))?;
        lock(&self.state).request_rehydration(session_id);
        Ok(())
    }

    /// Deletes the session and its history (owner permission): stops it first when its cached
    /// row shows it can be stopped, as the web does, then `DELETE /v1/sessions/{id}`. The session
    /// leaves the list.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; [`SessionError::ReadOnly`]
    /// without owner permission, from the cached row or the server's `403`;
    /// [`SessionError::SessionNotFound`] for its `404`; the write errors of the delete. A failed
    /// stop does not block the delete.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn delete_session(&self, session_id: &str) -> Result<(), SessionError> {
        let result = self.delete(session_id, false).await;
        self.dispatch();
        result
    }

    /// As [`Self::delete_session`], also removing the session's worktree and its local git
    /// branch when `delete_branch` (`?delete_branch=true`; the server ignores it for a session
    /// without one). Branch removal cannot be undone.
    ///
    /// # Errors
    ///
    /// As [`Self::delete_session`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn delete_session_with_branch(
        &self,
        session_id: &str,
        delete_branch: bool,
    ) -> Result<(), SessionError> {
        let result = self.delete(session_id, delete_branch).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn delete(&self, session_id: &str, delete_branch: bool) -> Result<(), SessionError> {
        validate_identifier(session_id)?;
        let cached = self.cached_summary(session_id);
        if cached
            .as_ref()
            .is_some_and(|summary| !summary.can_archive())
        {
            return Err(SessionError::ReadOnly);
        }
        if cached.is_some_and(|summary| summary.is_stoppable()) {
            let path = format!("/v1/sessions/{session_id}/events");
            let body = json!({"type": "stop_session", "data": {}});
            // Best effort, as the web's: a wedged or already stopped runner must not block the
            // delete, whose own outcome is the one reported.
            let stopped = self
                .write(self.prepare("POST", &path, &[], Some(&body))?)
                .await;
            drop(stopped);
        }
        let path = format!("/v1/sessions/{session_id}");
        let query = if delete_branch {
            vec![("delete_branch", "true".to_owned())]
        } else {
            Vec::new()
        };
        self.write(self.prepare("DELETE", &path, &query, None)?)
            .await
            .map_err(refused_write(session_id))?;
        self.forget(session_id);
        Ok(())
    }

    /// Leaves a session shared with the caller by revoking the caller's own grant
    /// (`DELETE /v1/sessions/{id}/permissions/{user}`). The session leaves the list; the owner
    /// sharing it again brings it back.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; [`SessionError::NotConnected`];
    /// the write errors (the server refuses to remove the owner's own grant).
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn leave_session(&self, session_id: &str) -> Result<(), SessionError> {
        let result = self.leave(session_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn leave(&self, session_id: &str) -> Result<(), SessionError> {
        validate_identifier(session_id)?;
        let user_id = lock(&self.state)
            .connected
            .as_ref()
            .map(|server| server.user_id.clone())
            .ok_or(SessionError::NotConnected)?;
        let path = format!(
            "/v1/sessions/{session_id}/permissions/{}",
            percent_encode(&user_id)
        );
        self.write(self.prepare("DELETE", &path, &[], None)?)
            .await?;
        self.forget(session_id);
        Ok(())
    }

    /// Drops a session the caller can no longer see and reports it removed.
    fn forget(&self, session_id: &str) {
        let mut state = lock(&self.state);
        state.bump_metadata_epoch(session_id);
        state.summaries.remove(session_id);
        state.live_sessions.remove(session_id);
        state.events.push(ClientEvent::SessionsRemoved {
            ids: vec![session_id.to_owned()],
        });
        state.events.push(ClientEvent::InventoryInvalidated);
    }
}

#[cfg(test)]
#[path = "session_actions_tests.rs"]
mod tests;
