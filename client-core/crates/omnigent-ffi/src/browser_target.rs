//! Which browser a session's agent drives, for the session header's browser menu.

use omnigent_core::browser_target as core;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// The browser a session's agent uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum BrowserTarget {
    /// The runner decides at each connection.
    Auto,
    /// The owner's Mac app browser, with their logins.
    Local,
    /// The runner's browser host, which works while the Mac sleeps.
    Remote,
}

impl From<core::BrowserTarget> for BrowserTarget {
    fn from(target: core::BrowserTarget) -> Self {
        match target {
            core::BrowserTarget::Auto => Self::Auto,
            core::BrowserTarget::Local => Self::Local,
            core::BrowserTarget::Remote => Self::Remote,
        }
    }
}

impl From<BrowserTarget> for core::BrowserTarget {
    fn from(target: BrowserTarget) -> Self {
        match target {
            BrowserTarget::Auto => Self::Auto,
            BrowserTarget::Local => Self::Local,
            BrowserTarget::Remote => Self::Remote,
        }
    }
}

#[uniffi::export]
impl ClientCore {
    /// The browser `session_id`'s agent uses, from its `omnigent.browser_target` label.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`].
    pub async fn browser_target(&self, session_id: String) -> Result<BrowserTarget, CoreError> {
        self.sessions()
            .browser_target(&session_id)
            .await
            .map(BrowserTarget::from)
            .map_err(CoreError::from)
    }

    /// Points `session_id`'s agent at `target`; its next browser call lands there. Only the
    /// owner of an unshared session may choose `Local`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`], a forbidden one when the caller may not choose `target`.
    pub async fn set_browser_target(
        &self,
        session_id: String,
        target: BrowserTarget,
    ) -> Result<(), CoreError> {
        self.sessions()
            .set_browser_target(&session_id, target.into())
            .await
            .map_err(CoreError::from)
    }
}

#[cfg(test)]
#[path = "browser_target_tests.rs"]
mod tests;
