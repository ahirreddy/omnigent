//! Which browser a session's agent drives: the session's `omnigent.browser_target` label.
//!
//! `local` is the owner's Mac app browser (with their logins), `remote` the runner's browser
//! host (works while the Mac sleeps), and no label means `auto`. The server lets only the
//! owner of an unshared session choose `local`.

use serde_json::json;

use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// The session label that holds the choice.
pub const BROWSER_TARGET_LABEL: &str = "omnigent.browser_target";

/// The browser a session's agent uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum BrowserTarget {
    /// The runner decides at each connection (absent label).
    #[default]
    Auto,
    /// The owner's Mac app browser.
    Local,
    /// The runner's browser host.
    Remote,
}

impl BrowserTarget {
    /// Reads a label value; anything unknown is `Auto`, as the runner reads it.
    #[must_use]
    pub fn from_label(value: Option<&str>) -> Self {
        match value {
            Some("local") => Self::Local,
            Some("remote") => Self::Remote,
            _ => Self::Auto,
        }
    }

    /// The label value to write; empty clears the label back to `Auto`.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Auto => "",
            Self::Local => "local",
            Self::Remote => "remote",
        }
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// The browser `session_id`'s agent uses (`GET /v1/sessions/{id}`, its labels).
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request, [`SessionError::SessionNotFound`]
    /// for a 404, and the read errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn browser_target(&self, session_id: &str) -> Result<BrowserTarget, SessionError> {
        let result = self.read_browser_target(session_id).await;
        self.dispatch();
        result
    }

    /// Points `session_id`'s agent at `target` (`PATCH /v1/sessions/{id}` with the label). The
    /// agent's next browser call lands in the new browser; its open tabs stay where they are.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; [`SessionError::Forbidden`] when
    /// the caller may not choose `target` (`Local` needs the owner of an unshared session); the
    /// write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn set_browser_target(
        &self,
        session_id: &str,
        target: BrowserTarget,
    ) -> Result<(), SessionError> {
        let result = self.write_browser_target(session_id, target).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn read_browser_target(&self, session_id: &str) -> Result<BrowserTarget, SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}");
        let session = match self.get_json(&path, &[]).await {
            Err(SessionError::HttpStatus { status: 404 }) => {
                return Err(SessionError::SessionNotFound {
                    session_id: session_id.to_owned(),
                });
            }
            other => other?,
        };
        let value = session
            .get("labels")
            .and_then(|labels| labels.get(BROWSER_TARGET_LABEL))
            .and_then(serde_json::Value::as_str);
        Ok(BrowserTarget::from_label(value))
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn write_browser_target(
        &self,
        session_id: &str,
        target: BrowserTarget,
    ) -> Result<(), SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}");
        let body = json!({"labels": {BROWSER_TARGET_LABEL: target.label()}});
        self.write(self.prepare("PATCH", &path, &[], Some(&body))?)
            .await
            .map(|_| ())
    }
}

#[cfg(test)]
#[path = "browser_target_tests.rs"]
mod tests;
