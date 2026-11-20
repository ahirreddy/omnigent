//! Session sharing: a session's grants, granting and revoking. The REST calls are the core
//! client's (`omnigent_core::client::share`).

use omnigent_core::share as core;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// The grantee that means anyone with the link.
#[must_use]
#[uniffi::export]
pub fn public_grantee() -> String {
    core::PUBLIC_GRANTEE.to_owned()
}

/// Whether a `restricted_read_only` server refuses to share a session working in `workspace`:
/// a home or root folder.
#[must_use]
#[uniffi::export]
pub fn workspace_sharing_blocked(workspace: String) -> bool {
    core::workspace_sharing_blocked(&workspace)
}

/// One grant on a session.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SessionGrant {
    /// The grantee: a user id or email, or `public_grantee()`.
    pub user_id: String,
    /// 1 read, 2 edit, 3 manage, 4 owner.
    pub level: u8,
    /// The owner's own grant, which cannot be changed.
    pub is_owner: bool,
}

impl From<core::SessionGrant> for SessionGrant {
    fn from(grant: core::SessionGrant) -> Self {
        Self {
            is_owner: grant.is_owner(),
            user_id: grant.user_id,
            level: grant.level,
        }
    }
}

/// The automation that keeps a session's shares.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ManagingAutomation {
    /// Its id.
    pub id: String,
    /// Its name.
    pub name: String,
}

/// A session's grants and the automation that keeps them, if one does.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SessionPermissions {
    /// Every grant, the owner's included.
    pub grants: Vec<SessionGrant>,
    /// The automation whose runs replace the shares with its own list.
    pub managed_by: Option<ManagingAutomation>,
}

/// Whether people with read access may browse a session's files, and its folder.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct WorkspaceSharing {
    /// Read access includes the session's files and changes.
    pub enabled: bool,
    /// The session's working directory; `nil` when it has none.
    pub workspace: Option<String>,
}

impl From<core::WorkspaceSharing> for WorkspaceSharing {
    fn from(sharing: core::WorkspaceSharing) -> Self {
        Self {
            enabled: sharing.enabled,
            workspace: sharing.workspace,
        }
    }
}

#[uniffi::export]
impl ClientCore {
    /// Whether people with read access may browse `session_id`'s files, and its folder.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors and `MalformedResponse`.
    pub async fn workspace_sharing(
        &self,
        session_id: String,
    ) -> Result<WorkspaceSharing, CoreError> {
        self.sessions()
            .workspace_sharing(&session_id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Lets people with read access browse `session_id`'s files, or stops it. Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the write errors and `MalformedResponse`.
    pub async fn set_workspace_sharing(
        &self,
        session_id: String,
        enabled: bool,
    ) -> Result<WorkspaceSharing, CoreError> {
        self.sessions()
            .set_workspace_sharing(&session_id, enabled)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Every grant on `session_id`, and the automation that keeps them (needs manage access).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: as [`Self::session_grants`].
    pub async fn session_permissions(
        &self,
        session_id: String,
    ) -> Result<SessionPermissions, CoreError> {
        let permissions = self
            .sessions()
            .session_permissions(&session_id)
            .await
            .map_err(CoreError::from)?;
        Ok(SessionPermissions {
            grants: permissions.grants.into_iter().map(Into::into).collect(),
            managed_by: permissions.managed_by.map(|automation| ManagingAutomation {
                id: automation.id,
                name: automation.name,
            }),
        })
    }

    /// Every grant on `session_id` (needs manage access).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors (`Forbidden` below manage
    /// access), `MalformedResponse` and `InvalidPagination`.
    pub async fn session_grants(&self, session_id: String) -> Result<Vec<SessionGrant>, CoreError> {
        self.sessions()
            .session_grants(&session_id)
            .await
            .map(|grants| grants.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// Grants `user_id` `level` (1 read, 2 edit, 3 manage) on `session_id`. Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` before any request, and the write errors
    /// (`Rejected` with the server's reason, `Forbidden`, `DeliveryUncertain`).
    pub async fn grant_session_access(
        &self,
        session_id: String,
        user_id: String,
        level: u8,
    ) -> Result<SessionGrant, CoreError> {
        self.sessions()
            .grant_session_access(&session_id, &user_id, level)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Removes `user_id`'s grant on `session_id`. Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` before any request, and the write errors.
    pub async fn revoke_session_access(
        &self,
        session_id: String,
        user_id: String,
    ) -> Result<(), CoreError> {
        self.sessions()
            .revoke_session_access(&session_id, &user_id)
            .await
            .map_err(CoreError::from)
    }
}
