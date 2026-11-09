//! Reading a message attachment's bytes back for an inline preview, as the web's `SessionImage`
//! does: only a file of the session on the connected server, within the preview MIME and size
//! limits ([`crate::attachments::preview`]).

use super::requests::{connected_base_url, validate_identifier};
use super::{ClientCore, SessionError, lock};
use crate::attachments::{
    AttachmentPreview, PreviewError, attachment_file_id, preview_from_response,
};
use crate::http::{HttpHeader, HttpTransport, TransportError};

impl<T: HttpTransport> ClientCore<T> {
    /// The bytes of the attachment `reference` names (a file id, or a path or URL of one of
    /// `session_id`'s files on this server).
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] and [`SessionError::NotConnected`] before any request;
    /// [`SessionError::Preview`] with [`PreviewError::NotASessionFile`] for any other reference
    /// (nothing is fetched), or the response's status, media type or size refusal (a `401` also
    /// ends the connection); [`SessionError::Transport`] or [`SessionError::Cancelled`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn attachment_preview(
        &self,
        session_id: &str,
        reference: &str,
    ) -> Result<AttachmentPreview, SessionError> {
        let result = self.read_attachment_preview(session_id, reference).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn read_attachment_preview(
        &self,
        session_id: &str,
        reference: &str,
    ) -> Result<AttachmentPreview, SessionError> {
        validate_identifier(session_id)?;
        let file_id = self.attachment_file(session_id, reference)?;
        let path = format!("/v1/sessions/{session_id}/resources/files/{file_id}/content");
        let mut prepared = self.prepare("GET", &path, &[], None)?;
        prepared
            .request
            .headers
            .retain(|header| !header.name.eq_ignore_ascii_case("Accept"));
        prepared
            .request
            .headers
            .push(HttpHeader::new("Accept", "*/*"));
        let result = self
            .send_routed(prepared.request, prepared.addressing)
            .await;
        let mut state = lock(&self.state);
        if state.epoch != prepared.epoch || !state.is_connected() {
            return Err(SessionError::NotConnected);
        }
        let response = result.map_err(|error| match error {
            TransportError::Cancelled => SessionError::Cancelled,
            other => SessionError::Transport(other),
        })?;
        preview_from_response(response).map_err(|error| {
            if error == PreviewError::Unauthorized {
                state.authentication_failed();
            }
            SessionError::Preview(error)
        })
    }

    /// The file id `reference` names on the connected server.
    fn attachment_file(&self, session_id: &str, reference: &str) -> Result<String, SessionError> {
        let state = lock(&self.state);
        let endpoint = state
            .connection
            .as_ref()
            .filter(|connection| connection.is_connected())
            .ok_or(SessionError::NotConnected)?
            .endpoint();
        let base = connected_base_url(endpoint.base_url())?;
        attachment_file_id(
            &base,
            endpoint.databricks_org_id(),
            Some(reference),
            session_id,
        )
        .ok_or(SessionError::Preview(PreviewError::NotASessionFile))
    }
}
