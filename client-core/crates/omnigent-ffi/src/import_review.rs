//! What a newly connected host carries over, for desktop onboarding's review. The rules are
//! `omnigent_core::import_review`.

use crate::client::ClientCore;
use crate::errors::CoreError;

/// One harness's part of the review.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ImportReviewHarness {
    /// The harness (`claude-native`).
    pub harness: String,
    /// What the review calls it ("Claude Code").
    pub label: String,
    /// Where its credential comes from; `None` without one.
    pub credential: Option<String>,
    /// Its MCP servers' names.
    pub mcp_servers: Vec<String>,
    /// Its skills.
    pub skills: Vec<String>,
    /// Its plugins' names.
    pub plugins: Vec<String>,
    /// Why some of it couldn't be read.
    pub notices: Vec<String>,
}

/// A host's review.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ImportReview {
    /// The host's name.
    pub host_name: String,
    /// The host is online.
    pub online: bool,
    /// The harnesses with a credential or anything to carry over.
    pub harnesses: Vec<ImportReviewHarness>,
}

#[uniffi::export]
impl ClientCore {
    /// What `host_id`'s Claude Code, Codex and Cursor carry over: credentials, MCP servers,
    /// skills and plugins.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the reads' errors, and kind `InvalidInput`
    /// for a host the server doesn't list.
    pub async fn import_review(&self, host_id: String) -> Result<ImportReview, CoreError> {
        let review = self
            .sessions()
            .import_review(&host_id)
            .await
            .map_err(CoreError::from)?;
        Ok(ImportReview {
            host_name: review.host_name,
            online: review.online,
            harnesses: review
                .harnesses
                .into_iter()
                .map(|harness| ImportReviewHarness {
                    harness: harness.harness,
                    label: harness.label,
                    credential: harness.credential,
                    mcp_servers: harness.mcp_servers,
                    skills: harness.skills,
                    plugins: harness.plugins,
                    notices: harness.notices,
                })
                .collect(),
        })
    }
}
