//! Workspace reads on [`ClientCore`]: the connection, org header and bearer come from the
//! session client; decoding and the status policy are the workspace module's own.
//!
//! The session client's `read` drops the body of an error response, and the workspace routes
//! put the reason there, so these reads send through the host transport directly. They keep
//! the session client's rules: nothing is sent while disconnected, a result that arrives after
//! the connection ended or changed identity is [`SessionError::NotConnected`], a `401` ends the
//! connection, and redirects are never followed.

use super::content::{FileBody, FileContent};
use super::error::WorkspaceError;
use super::model::{
    ChangesList, DirectoryPage, FileDiffContent, FileSave, FileWritten, PathSearchResult,
    SessionFilesPage, WorkspaceEnvironment,
};
use super::path::WorkspacePath;
use super::request::{
    DirectoryQuery, FileWrite, SessionFilesQuery, WorkspaceOperation, WorkspaceRequest,
    WorkspaceResponse, with_segments,
};
use super::search::{ContentSearchQuery, ContentSearchResult, PathSearchQuery};
use crate::client::{ClientCore, SessionError};
use crate::http::{HttpTransport, TransportError};

fn unexpected(response: &WorkspaceResponse) -> WorkspaceError {
    WorkspaceError::malformed("workspace", format!("unexpected response {response:?}"))
}

macro_rules! expect {
    ($response:expr, $variant:ident) => {
        match $response {
            WorkspaceResponse::$variant(value) => Ok(value),
            other => Err(unexpected(&other)),
        }
    };
}

impl<T: HttpTransport> ClientCore<T> {
    /// Sends `request` on the current connection and decodes the answer.
    ///
    /// # Errors
    ///
    /// See [`WorkspaceError`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn workspace(
        &self,
        request: &WorkspaceRequest,
    ) -> Result<WorkspaceResponse, WorkspaceError> {
        let route = request.route()?;
        let prepared =
            self.prepare(route.method, &route.path, &route.query, route.body.as_ref())?;
        let http = with_segments(prepared.request, &route.segments)?;
        let identity = self.connected_server();
        let response = self
            .transport()
            .send(http)
            .await
            .map_err(|error| match error {
                TransportError::Cancelled => SessionError::Cancelled,
                other => SessionError::Transport(other),
            })?;
        if !self.is_connected() || self.connected_server() != identity {
            return Err(SessionError::NotConnected.into());
        }
        let decoded = request.decode(&response);
        if let Err(error) = &decoded
            && error.ends_connection()
        {
            self.disconnect();
        }
        decoded
    }

    /// The session's environments.
    ///
    /// # Errors
    ///
    /// See [`ClientCore::workspace`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport"
    )]
    pub async fn workspace_environments(
        &self,
        session_id: &str,
    ) -> Result<Vec<WorkspaceEnvironment>, WorkspaceError> {
        let request = WorkspaceRequest::new(
            session_id,
            super::DEFAULT_ENVIRONMENT_ID,
            WorkspaceOperation::ListEnvironments,
        )?;
        expect!(self.workspace(&request).await?, Environments)
    }

    /// One environment, including its absolute root when the server reports it.
    ///
    /// # Errors
    ///
    /// See [`ClientCore::workspace`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport"
    )]
    pub async fn workspace_environment(
        &self,
        session_id: &str,
        environment_id: &str,
    ) -> Result<WorkspaceEnvironment, WorkspaceError> {
        let request = WorkspaceRequest::new(
            session_id,
            environment_id,
            WorkspaceOperation::GetEnvironment,
        )?;
        expect!(self.workspace(&request).await?, Environment)
    }

    /// One page of a directory.
    ///
    /// # Errors
    ///
    /// See [`ClientCore::workspace`]; [`WorkspaceError::UnexpectedKind`] when the path is a file.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport"
    )]
    pub async fn list_workspace_directory(
        &self,
        session_id: &str,
        environment_id: &str,
        query: DirectoryQuery,
    ) -> Result<DirectoryPage, WorkspaceError> {
        let request = WorkspaceRequest::new(
            session_id,
            environment_id,
            WorkspaceOperation::ListDirectory(query),
        )?;
        expect!(self.workspace(&request).await?, Directory)
    }

    /// A file's content (capped by the server at 10 MiB).
    ///
    /// # Errors
    ///
    /// See [`ClientCore::workspace`]; [`WorkspaceError::UnexpectedKind`] for a directory.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport"
    )]
    pub async fn read_workspace_file(
        &self,
        session_id: &str,
        environment_id: &str,
        path: WorkspacePath,
    ) -> Result<FileContent, WorkspaceError> {
        let request = WorkspaceRequest::new(
            session_id,
            environment_id,
            WorkspaceOperation::ReadFile(path),
        )?;
        expect!(self.workspace(&request).await?, File)
    }

    /// Replaces the file's content with `content`.
    ///
    /// # Errors
    ///
    /// See [`ClientCore::workspace`]; `Forbidden` without edit access.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport"
    )]
    pub async fn write_workspace_file(
        &self,
        session_id: &str,
        environment_id: &str,
        path: WorkspacePath,
        content: String,
    ) -> Result<FileWritten, WorkspaceError> {
        let request = WorkspaceRequest::new(
            session_id,
            environment_id,
            WorkspaceOperation::WriteFile(FileWrite { path, content }),
        )?;
        expect!(self.workspace(&request).await?, Written)
    }

    /// Saves an edit of a file read as `base`: the file is read again first, and when someone
    /// else changed (or deleted) it since, nothing is written and the latest text is returned.
    /// Without `base` the file is written unconditionally ("Keep mine").
    ///
    /// # Errors
    ///
    /// See [`ClientCore::read_workspace_file`] and [`ClientCore::write_workspace_file`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport"
    )]
    pub async fn save_workspace_file(
        &self,
        session_id: &str,
        environment_id: &str,
        path: WorkspacePath,
        content: String,
        base: Option<&str>,
    ) -> Result<FileSave, WorkspaceError> {
        if let Some(base) = base {
            let latest = match self
                .read_workspace_file(session_id, environment_id, path.clone())
                .await
            {
                Ok(FileContent {
                    body: FileBody::Text(text),
                    truncated: false,
                    ..
                }) => Some(text),
                Ok(_) | Err(WorkspaceError::NotFound { .. }) => None,
                Err(error) => return Err(error),
            };
            let current = latest.as_deref();
            if current != Some(base) && current != Some(content.as_str()) {
                return Ok(FileSave::Conflict { latest });
            }
        }
        let written = self
            .write_workspace_file(session_id, environment_id, path, content)
            .await?;
        Ok(FileSave::Saved(written))
    }

    /// Files whose name or path contains the query.
    ///
    /// # Errors
    ///
    /// See [`ClientCore::workspace`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport"
    )]
    pub async fn search_workspace_paths(
        &self,
        session_id: &str,
        environment_id: &str,
        query: PathSearchQuery,
    ) -> Result<PathSearchResult, WorkspaceError> {
        let request = WorkspaceRequest::new(
            session_id,
            environment_id,
            WorkspaceOperation::SearchPaths(query),
        )?;
        expect!(self.workspace(&request).await?, PathSearch)
    }

    /// Lines whose text matches the query.
    ///
    /// # Errors
    ///
    /// See [`ClientCore::workspace`]; [`WorkspaceError::SearchFailed`] when ripgrep failed and
    /// [`WorkspaceError::ContentSearchDisabled`] when the server has the feature off.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport"
    )]
    pub async fn search_workspace_content(
        &self,
        session_id: &str,
        environment_id: &str,
        query: ContentSearchQuery,
    ) -> Result<ContentSearchResult, WorkspaceError> {
        let request = WorkspaceRequest::new(
            session_id,
            environment_id,
            WorkspaceOperation::SearchContent(query),
        )?;
        expect!(self.workspace(&request).await?, ContentSearch)
    }

    /// Every file changed this session, with line counts where known.
    ///
    /// # Errors
    ///
    /// See [`ClientCore::workspace`]; [`WorkspaceError::ChangesUnavailable`] when git failed.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport"
    )]
    pub async fn workspace_changes(
        &self,
        session_id: &str,
        environment_id: &str,
    ) -> Result<ChangesList, WorkspaceError> {
        let request =
            WorkspaceRequest::new(session_id, environment_id, WorkspaceOperation::ListChanges)?;
        expect!(self.workspace(&request).await?, Changes)
    }

    /// A changed file's before and after text; diff it with [`FileDiffContent::diff`].
    ///
    /// # Errors
    ///
    /// See [`ClientCore::workspace`]; [`WorkspaceError::NotChanged`] for a file with no changes.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport"
    )]
    pub async fn workspace_file_diff(
        &self,
        session_id: &str,
        environment_id: &str,
        path: WorkspacePath,
    ) -> Result<FileDiffContent, WorkspaceError> {
        let request = WorkspaceRequest::new(
            session_id,
            environment_id,
            WorkspaceOperation::FileDiff(path),
        )?;
        expect!(self.workspace(&request).await?, FileDiff)
    }

    /// One page of the files uploaded to the session.
    ///
    /// # Errors
    ///
    /// See [`ClientCore::workspace`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport"
    )]
    pub async fn session_files(
        &self,
        session_id: &str,
        query: SessionFilesQuery,
    ) -> Result<SessionFilesPage, WorkspaceError> {
        let request = WorkspaceRequest::new(
            session_id,
            super::DEFAULT_ENVIRONMENT_ID,
            WorkspaceOperation::ListSessionFiles(query),
        )?;
        expect!(self.workspace(&request).await?, SessionFiles)
    }
}

#[cfg(test)]
mod reply_kind_tests {
    use super::*;

    #[test]
    fn a_reply_for_an_operation_of_another_kind_is_malformed() {
        let answered = WorkspaceResponse::Environments(Vec::new());
        assert!(matches!(
            unexpected(&answered),
            WorkspaceError::MalformedResponse { .. }
        ));
    }
}
