//! What a newly connected host brings with it (the web's `ImportContextModal`).
//!
//! Desktop onboarding shows it once it connects a host (`import_review`): for Claude Code, Codex
//! and Cursor, the credential the host has and the MCP servers, skills and plugins it carries
//! over.

use super::harness_inventory::InventoryRead;
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::harness_setup::{HarnessAvailability, SetupHost};
use crate::http::HttpTransport;

/// The harnesses the review covers, with the names it shows: the web's brand harnesses.
pub const REVIEW_HARNESSES: [(&str, &str); 3] = [
    ("claude-native", "Claude Code"),
    ("codex-native", "Codex"),
    ("cursor-native", "Cursor"),
];

/// One harness's part of the review.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportReviewHarness {
    /// The harness (`claude-native`).
    pub harness: String,
    /// What the review calls it ("Claude Code").
    pub label: String,
    /// Where its credential comes from ("Signed in", "Databricks Unity Gateway"); `None`
    /// without one.
    pub credential: Option<String>,
    /// Its MCP servers' names.
    pub mcp_servers: Vec<String>,
    /// Its skills, as the composer names them.
    pub skills: Vec<String>,
    /// Its plugins' names.
    pub plugins: Vec<String>,
    /// Why some of it couldn't be read.
    pub notices: Vec<String>,
}

/// A host's review.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportReview {
    /// The host's name.
    pub host_name: String,
    /// The host is online; offline, nothing can be read.
    pub online: bool,
    /// The harnesses with a credential or anything to carry over.
    pub harnesses: Vec<ImportReviewHarness>,
}

fn notice(read: InventoryRead, what: &str) -> Option<String> {
    match read {
        InventoryRead::Loaded => None,
        InventoryRead::Unsupported => Some("Please update this host to list MCP servers.".into()),
        InventoryRead::Failed => Some(format!("Couldn't read {what} from this machine.")),
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// The review of `host_id`'s harnesses. A harness the host lacks is left out, and so is one
    /// with neither a credential nor anything to carry over.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; the host list's read errors;
    /// [`SessionError::InvalidInput`] for a host the server doesn't list.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn import_review(&self, host_id: &str) -> Result<ImportReview, SessionError> {
        let result = self.read_import_review(host_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn read_import_review(&self, host_id: &str) -> Result<ImportReview, SessionError> {
        validate_identifier(host_id)?;
        let host = self
            .host_rows()
            .await?
            .iter()
            .map(SetupHost::from_value)
            .collect::<Result<Vec<_>, String>>()
            .map_err(|detail| SessionError::MalformedResponse { detail })?
            .into_iter()
            .find(|host| host.host_id == host_id)
            .ok_or_else(|| SessionError::InvalidInput {
                reason: "The server doesn't list this machine.".into(),
            })?;
        let mut review = ImportReview {
            host_name: host.name.clone(),
            online: host.status == "online",
            harnesses: Vec::new(),
        };
        if !review.online {
            return Ok(review);
        }
        for (harness, label) in REVIEW_HARNESSES {
            if let Some(entry) = self.review_harness(&host, harness, label).await? {
                review.harnesses.push(entry);
            }
        }
        Ok(review)
    }

    /// One harness's part of `host`'s review; `None` when it isn't installed, or has neither a
    /// credential nor anything to carry over.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn review_harness(
        &self,
        host: &SetupHost,
        harness: &str,
        label: &str,
    ) -> Result<Option<ImportReviewHarness>, SessionError> {
        let readiness = host
            .harnesses
            .as_ref()
            .and_then(|harnesses| harnesses.get(harness));
        if readiness == Some(&HarnessAvailability::BinaryMissing) {
            return Ok(None);
        }
        let gateway = host
            .gateway_inference
            .as_ref()
            .and_then(|gateways| gateways.get(harness))
            .copied()
            .unwrap_or(false);
        let read = self.host_harness_inventory(&host.host_id, harness).await?;
        let entry = ImportReviewHarness {
            harness: harness.to_owned(),
            label: label.to_owned(),
            credential: (readiness == Some(&HarnessAvailability::Ready)).then(|| {
                if gateway {
                    "Databricks Unity Gateway".to_owned()
                } else {
                    "Signed in".to_owned()
                }
            }),
            mcp_servers: read
                .inventory
                .mcp_servers
                .iter()
                .map(|row| row.title.clone())
                .collect(),
            skills: read
                .inventory
                .skills
                .iter()
                .map(|row| row.title.clone())
                .collect(),
            plugins: read
                .inventory
                .plugins
                .iter()
                .map(|row| row.name.clone())
                .collect(),
            notices: [
                notice(read.mcp_servers, "MCP servers"),
                notice(read.skills, "skills and plugins"),
                notice(read.plugins, "plugins"),
            ]
            .into_iter()
            .flatten()
            .collect(),
        };
        let carries =
            !entry.mcp_servers.is_empty() || !entry.skills.is_empty() || !entry.plugins.is_empty();
        Ok((entry.credential.is_some() || carries).then_some(entry))
    }
}

#[cfg(test)]
#[path = "import_review_tests.rs"]
mod tests;
