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

#[uniffi::export]
impl ClientCore {
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
