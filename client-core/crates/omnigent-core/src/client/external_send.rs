//! Messages sent from outside a session's composer with files of their own, such as the Browser
//! design tools' requests (the web's `external` send). Their files upload straight to the
//! session and the message posts outside the submission ledger, so the composer's draft, staged
//! files and send state are left as they are.

use super::events::{
    MessageSubmission, SendPayload, add_connection_headers, upload_failure,
    upload_outlived_connection,
};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError, lock};
use crate::attachments::{UploadError, UploadFile, UploadedAttachment};
use crate::http::HttpTransport;

impl<T: HttpTransport> ClientCore<T> {
    /// Sends `text` with `files` to `session_id` from outside its composer: each file uploads to
    /// the session, then the message posts. Nothing is retried, and nothing posts when an upload
    /// fails. No open stream is needed.
    ///
    /// # Errors
    ///
    /// [`SessionError::EmptyMessage`] and [`SessionError::InvalidIdentifier`] before any
    /// request; the cached-row errors; an upload's errors as
    /// [`Self::upload_attachment`]'s; then the message's as [`Self::send_message`]'s, of which
    /// [`SessionError::HostOffline`] and [`SessionError::MessageDenied`] were refused and only
    /// [`SessionError::DeliveryUncertain`] may have delivered.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn send_external_message(
        &self,
        session_id: &str,
        text: &str,
        files: &[UploadFile],
        boundary: &str,
    ) -> Result<MessageSubmission, SessionError> {
        let result = self.send_external(session_id, text, files, boundary).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn send_external(
        &self,
        session_id: &str,
        text: &str,
        files: &[UploadFile],
        boundary: &str,
    ) -> Result<MessageSubmission, SessionError> {
        validate_identifier(session_id)?;
        if text.trim().is_empty() && files.is_empty() {
            return Err(SessionError::EmptyMessage);
        }
        self.require_sendable(session_id, false)?;
        let mut uploaded = Vec::with_capacity(files.len());
        for file in files {
            uploaded.push(self.upload_external(session_id, file, boundary).await?);
        }
        let (target, local) = self.upload_target(session_id)?;
        target.validate_message_attachments(&uploaded, local)?;
        self.post_message(session_id, text, &SendPayload::Message, &uploaded, false)
            .await
    }

    /// Uploads one file to `session_id` outside any draft.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn upload_external(
        &self,
        session_id: &str,
        file: &UploadFile,
        boundary: &str,
    ) -> Result<UploadedAttachment, SessionError> {
        let (target, _) = self.upload_target(session_id)?;
        let mut request = target.request(file, boundary)?;
        let epoch = {
            let state = lock(&self.state);
            add_connection_headers(state.connection.as_ref(), &mut request);
            state.epoch
        };
        let result = self.transport.send(request).await;
        let mut state = lock(&self.state);
        let mapped = if state.epoch == epoch {
            target.response(file, result)
        } else {
            Err(upload_outlived_connection())
        };
        if mapped == Err(UploadError::Unauthorized) {
            state.authentication_failed();
        }
        mapped.map_err(|error| upload_failure(session_id, error))
    }
}
