//! Add nested agent over REST: the source session read fresh, and `POST /v1/sessions` with
//! `sibling_source_id` on an existing host or a new sandbox. The rules are
//! [`crate::nested_creation`]'s.
//!
//! The server checks the source and the destination policy before it creates anything, and
//! discards the row of a sibling it could not join to the family, so a `403` or `409` for a
//! nested create is a definite refusal, unlike for an ordinary one.

use super::create::{CreatedSession, FirstMessage, Refusals};
use super::requests::validate_identifier;
use super::sessions::SessionSummary;
use super::{ClientCore, SessionError, lock};
use crate::creation::{
    CreationError, CreationReceipt, CreationSelection, MAX_TITLE_CHARS, SandboxTarget,
};
use crate::http::HttpTransport;
use crate::nested_creation::{NestedRequest, nested_creation_body, nested_sandbox_creation_body};

impl<T: HttpTransport> ClientCore<T> {
    /// The source of an Add nested agent composer, read fresh (`GET /v1/sessions/{id}`) for its
    /// title, host, folder and branch. The list's row updates with it.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request,
    /// [`SessionError::SessionNotFound`] for its `404`, and the read errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn nested_source(&self, session_id: &str) -> Result<SessionSummary, SessionError> {
        let result = async {
            let (decoded, epoch) = self.fetch_snapshot(session_id).await?;
            lock(&self.state).accept_projection(&decoded.projection, epoch)
        }
        .await;
        self.dispatch();
        result
    }

    /// Creates a nested agent beside `request.source_id` on `selection`'s host (the source's own
    /// sandbox host included), re-validating the capability, the destination policy, readiness
    /// and the model against a fresh catalog first. `first_message` only lets Smart Routing pick
    /// a native pane's model; nothing is sent. Never retried.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`]; [`SessionError::Creation`] with
    /// [`CreationError::Unavailable`] (nothing sent), [`CreationError::Rejected`] (the server's
    /// `400`, `403`, `409`, `415` or `422`) or [`CreationError::Uncertain`];
    /// [`SessionError::Unauthorized`]; the catalog read errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_nested_session(
        &self,
        selection: &CreationSelection,
        request: &NestedRequest,
        title: &str,
        first_message: Option<&str>,
    ) -> Result<CreationReceipt, SessionError> {
        let result = self
            .create_nested(selection, request, title, first_message)
            .await;
        self.dispatch();
        result
    }

    /// Creates a nested agent as [`Self::create_nested_session`], then sends `text` to it. Once
    /// the session exists the result is `Ok`, with a failed first message in
    /// [`CreatedSession::first_message`].
    ///
    /// # Errors
    ///
    /// As [`Self::create_nested_session`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_nested_session_and_send(
        &self,
        selection: &CreationSelection,
        request: &NestedRequest,
        title: &str,
        text: &str,
    ) -> Result<CreatedSession, SessionError> {
        let result = async {
            let receipt = self
                .create_nested(selection, request, title, Some(text))
                .await?;
            let first_message = match self.send_first_message(&receipt.session_id, text).await {
                Ok(sent) => FirstMessage::Sent(sent),
                Err(error) => FirstMessage::Failed(error),
            };
            Ok(CreatedSession {
                receipt,
                first_message,
            })
        }
        .await;
        self.dispatch();
        result
    }

    /// Creates a nested agent beside `request.source_id` on a new sandbox, as `target`
    /// describes, after checking the capability and the destination policy. Sends no message.
    /// Never retried.
    ///
    /// # Errors
    ///
    /// As [`Self::create_nested_session`]; [`CreationError::Unavailable`] for a sandbox the
    /// server does not offer.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_nested_sandbox_session(
        &self,
        selection: &CreationSelection,
        target: &SandboxTarget,
        request: &NestedRequest,
        title: &str,
    ) -> Result<CreationReceipt, SessionError> {
        let result = async {
            validate_identifier(&selection.agent_id)?;
            let name = checked_title(title, request)?;
            let catalog = self.catalog().await?;
            catalog.validate_nested_sandbox(
                selection,
                target,
                request.source_host_id.as_deref(),
            )?;
            let agent = catalog
                .agent(&selection.agent_id)
                .ok_or_else(|| CreationError::Unavailable("Choose a registered agent.".into()))?
                .clone();
            let mut target = target.clone();
            if !catalog.capabilities.mints_sandbox_host_id {
                target.host_id = None;
            }
            let body = nested_sandbox_creation_body(selection, &target, name, &agent, request);
            self.submit_nested_creation(&body).await
        }
        .await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn create_nested(
        &self,
        selection: &CreationSelection,
        request: &NestedRequest,
        title: &str,
        first_message: Option<&str>,
    ) -> Result<CreationReceipt, SessionError> {
        validate_identifier(&selection.host_id)?;
        validate_identifier(&selection.agent_id)?;
        let name = checked_title(title, request)?;
        let catalog = self.catalog().await?;
        let source_host = request.source_host_id.as_deref();
        // Everything but the model first, so a refused host reads no model list.
        let unpinned = CreationSelection {
            model: None,
            ..selection.clone()
        };
        catalog.validate_nested(&unpinned, &[], source_host)?;
        let agent = catalog
            .agent(&selection.agent_id)
            .ok_or_else(|| CreationError::Unavailable("Choose a registered agent.".into()))?
            .clone();
        if selection.model.is_some() && !selection.smart_routing {
            let models = self.models_for(&agent, &selection.host_id).await?;
            catalog.validate_nested(selection, &models, source_host)?;
        }
        let body = nested_creation_body(selection, name, &agent, first_message, request);
        self.submit_nested_creation(&body).await
    }

    /// Sends a nested `POST /v1/sessions`: a `403` or `409` is a refusal like a `400`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn submit_nested_creation(
        &self,
        body: &serde_json::Value,
    ) -> Result<CreationReceipt, SessionError> {
        let prepared = self.prepare("POST", "/v1/sessions", &[], Some(body))?;
        self.submit_creation_refused_as(prepared, Refusals::Nested)
            .await
    }
}

/// The trimmed title, after checking its length and the request's identifiers.
fn checked_title<'a>(title: &'a str, request: &NestedRequest) -> Result<&'a str, SessionError> {
    validate_identifier(&request.source_id)?;
    validate_identifier(&request.client_token)?;
    if let Some(host) = &request.source_host_id {
        validate_identifier(host)?;
    }
    let name = title.trim();
    if name.chars().count() > MAX_TITLE_CHARS {
        return Err(CreationError::Unavailable(
            "Use a session name of 120 characters or fewer.".into(),
        )
        .into());
    }
    Ok(name)
}

#[cfg(test)]
#[path = "create_nested_tests.rs"]
mod tests;
