//! Agent browser actions.
//!
//! The server's `browser.action_request` events arrive as `CoreEvent::BrowserActionRequested`,
//! once per action id. A host that can act claims the action, runs it only when the claim is
//! granted, and posts the result object; see `omnigent_core::browser`.

use omnigent_core::browser as core;
use serde_json::Value;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// One agent browser action the server asked for.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct BrowserActionRequest {
    /// The session whose stream delivered it; claim and post to this session.
    pub session_id: String,
    /// The server's correlation id, for example `baction_…`.
    pub action_id: String,
    /// The `browser_` tool name without the prefix, for example `navigate`.
    pub action: String,
    /// The tool arguments, a JSON object.
    pub args_json: String,
}

impl From<omnigent_core::reducer::BrowserActionRequest> for BrowserActionRequest {
    fn from(request: omnigent_core::reducer::BrowserActionRequest) -> Self {
        Self {
            args_json: Value::Object(request.args).to_string(),
            session_id: request.session_id,
            action_id: request.action_id,
            action: request.action,
        }
    }
}

/// How a claim went.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum BrowserActionClaim {
    /// This client holds the lease: run the action, then post its result with the token.
    Claimed {
        /// The lease token the result must carry.
        claim_token: String,
    },
    /// Another client won, or the action is unknown or expired. Never run it.
    NotClaimed,
}

/// What posting a result achieved.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum BrowserActionDelivery {
    /// The server handed the result to the waiting tool call.
    Resolved,
    /// The server had already given up on the action; the result was dropped.
    Expired,
}

#[uniffi::export]
impl ClientCore {
    /// Claims `action_id` of `session_id`. The server waits 2 s for a claim.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `DeliveryUncertain` when the outcome is unclear (do not run the
    /// action), `Forbidden` without edit access, and the other write errors.
    pub async fn claim_browser_action(
        &self,
        session_id: String,
        action_id: String,
    ) -> Result<BrowserActionClaim, CoreError> {
        let claim = self
            .sessions()
            .claim_browser_action(&session_id, &action_id)
            .await
            .map_err(CoreError::from)?;
        Ok(match claim {
            core::BrowserActionClaim::Claimed { claim_token } => {
                BrowserActionClaim::Claimed { claim_token }
            }
            core::BrowserActionClaim::NotClaimed => BrowserActionClaim::NotClaimed,
        })
    }

    /// Posts a claimed action's result object (`{ok, error?, data?, data_url?}`, as JSON). The
    /// server waits 30 s for it.
    ///
    /// # Errors
    ///
    /// [`CoreError::Decode`] when `result_json` is not a JSON object (nothing is sent);
    /// [`CoreError::Session`] kind `BrowserAction` for a missing or refused claim token, and the
    /// other write errors.
    pub async fn post_browser_action_result(
        &self,
        session_id: String,
        action_id: String,
        claim_token: String,
        result_json: String,
    ) -> Result<BrowserActionDelivery, CoreError> {
        let result: Value =
            serde_json::from_str(&result_json).map_err(|error| CoreError::Decode {
                message: format!("browser action result: {error}"),
            })?;
        if !result.is_object() {
            return Err(CoreError::Decode {
                message: "browser action result: not a JSON object".to_owned(),
            });
        }
        let delivery = self
            .sessions()
            .post_browser_action_result(&session_id, &action_id, &claim_token, result)
            .await
            .map_err(CoreError::from)?;
        Ok(match delivery {
            core::BrowserActionDelivery::Resolved => BrowserActionDelivery::Resolved,
            core::BrowserActionDelivery::Expired => BrowserActionDelivery::Expired,
        })
    }
}
