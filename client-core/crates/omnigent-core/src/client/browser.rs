//! Agent browser actions: claiming a `browser.action_request` and posting its result.
//!
//! The server (`omnigent/server/routes/sessions/routes_browser.py`) fans one request out to
//! every client subscribed to the session's stream, grants exactly one claim, and waits 2 s for
//! the claim and 30 s for the result. Only the claimant may act:
//!
//! - `POST /v1/sessions/{id}/browser/action_claim/{action_id}` answers
//!   `{"claimed": true, "claim_token"}` to the winner and `{"claimed": false}` to everyone else
//!   (also for an unknown or expired action).
//! - `POST /v1/sessions/{id}/browser/action_result/{action_id}` with `{result, claim_token}`
//!   answers 202 `{"resolved": bool}`; a missing or mismatched token (or another session's
//!   action) is 403.
//!
//! A claim whose outcome is unclear is [`SessionError::DeliveryUncertain`]: the action must not
//! run, because this client may or may not hold the lease. Neither call is ever retried.

use serde_json::{Map, Value, json};

use super::json::{as_object, opt_bool, opt_str};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// How a claim went.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BrowserActionClaim {
    /// This client holds the lease: run the action, then post its result with the token.
    Claimed {
        /// The lease token the result must carry.
        claim_token: String,
    },
    /// Another client won, or the action is unknown or expired. Do not run it.
    NotClaimed,
}

/// Why a browser-action call failed beyond the session client's own errors.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum BrowserActionError {
    /// The claim token is empty; nothing was sent.
    #[error("The browser action has no claim token. Claim it before posting a result.")]
    MissingClaimToken,
    /// The result was refused (HTTP 403): the lease is not this client's, the action belongs to
    /// another session, or it already timed out on the server.
    #[error(
        "The server refused the browser action result: the claim expired or belongs to another client."
    )]
    ClaimRejected,
}

/// What a result post achieved.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BrowserActionDelivery {
    /// The server handed the result to the waiting tool call.
    Resolved,
    /// The server had already given up on the action (it timed out), so the result was dropped.
    Expired,
}

fn claim_from(value: &Value) -> Result<BrowserActionClaim, String> {
    let object = as_object(value, "browser action claim")?;
    let claimed = opt_bool(object, "claimed")?.ok_or("`claimed` is missing")?;
    if !claimed {
        return Ok(BrowserActionClaim::NotClaimed);
    }
    let claim_token = opt_str(object, "claim_token")?
        .filter(|token| !token.is_empty())
        .ok_or("a granted claim has no `claim_token`")?;
    Ok(BrowserActionClaim::Claimed { claim_token })
}

impl<T: HttpTransport> ClientCore<T> {
    /// Claims `action_id` of `session_id` (the session whose stream delivered the request).
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; [`SessionError::DeliveryUncertain`]
    /// when the outcome is unclear (do not run the action); [`SessionError::Forbidden`] without
    /// edit access; the other write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn claim_browser_action(
        &self,
        session_id: &str,
        action_id: &str,
    ) -> Result<BrowserActionClaim, SessionError> {
        validate_identifier(session_id)?;
        validate_identifier(action_id)?;
        let path = format!("/v1/sessions/{session_id}/browser/action_claim/{action_id}");
        let acknowledgement = self
            .write_json("POST", &path, &Value::Object(Map::new()))
            .await;
        self.dispatch();
        claim_from(&acknowledgement?).map_err(|detail| SessionError::DeliveryUncertain {
            detail: format!("unreadable claim acknowledgement: {detail}"),
        })
    }

    /// Posts the `result` object (`{ok, error?, data?, data_url?}`) of a claimed action.
    ///
    /// # Errors
    ///
    /// [`SessionError::BrowserAction`] with [`BrowserActionError::MissingClaimToken`] before any
    /// request, or [`BrowserActionError::ClaimRejected`] for a 403;
    /// [`SessionError::InvalidIdentifier`]; [`SessionError::DeliveryUncertain`] when the post may
    /// or may not have landed; the other write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn post_browser_action_result(
        &self,
        session_id: &str,
        action_id: &str,
        claim_token: &str,
        result: Value,
    ) -> Result<BrowserActionDelivery, SessionError> {
        validate_identifier(session_id)?;
        validate_identifier(action_id)?;
        if claim_token.is_empty() {
            return Err(BrowserActionError::MissingClaimToken.into());
        }
        let path = format!("/v1/sessions/{session_id}/browser/action_result/{action_id}");
        let body = json!({"result": result, "claim_token": claim_token});
        let acknowledgement = self.write_json("POST", &path, &body).await;
        self.dispatch();
        let acknowledgement = match acknowledgement {
            Err(SessionError::Forbidden) => return Err(BrowserActionError::ClaimRejected.into()),
            other => other?,
        };
        let resolved = as_object(&acknowledgement, "browser action result")
            .and_then(|object| opt_bool(object, "resolved"))
            .map_err(|detail| SessionError::DeliveryUncertain {
                detail: format!("unreadable result acknowledgement: {detail}"),
            })?;
        Ok(if resolved == Some(false) {
            BrowserActionDelivery::Expired
        } else {
            BrowserActionDelivery::Resolved
        })
    }
}

#[cfg(test)]
mod tests {
    use futures::executor::block_on;
    use serde_json::json;

    use super::*;
    use crate::client::test_support::{Reply, RouteTransport, body_json, connected};

    const CLAIM: &str = "/v1/sessions/conv_a/browser/action_claim/baction_1";
    const RESULT: &str = "/v1/sessions/conv_a/browser/action_result/baction_1";

    #[test]
    fn one_claim_wins_and_its_token_carries_the_result() {
        let transport = RouteTransport::local();
        transport.respond(
            Some("POST"),
            CLAIM,
            None,
            Reply::json(200, r#"{"claimed":true,"claim_token":"tok_1"}"#),
        );
        transport.respond(
            Some("POST"),
            RESULT,
            None,
            Reply::json(202, r#"{"resolved":true}"#),
        );
        let core = connected(transport);
        assert_eq!(
            block_on(core.claim_browser_action("conv_a", "baction_1")),
            Ok(BrowserActionClaim::Claimed {
                claim_token: "tok_1".into()
            })
        );
        assert_eq!(
            block_on(core.post_browser_action_result(
                "conv_a",
                "baction_1",
                "tok_1",
                json!({"ok": true, "data": {"final_url": "https://example.com/"}})
            )),
            Ok(BrowserActionDelivery::Resolved)
        );
        let bodies = core.transport().write_bodies();
        assert_eq!(bodies[0], json!({}));
        assert_eq!(
            bodies[1],
            json!({"result": {"ok": true, "data": {"final_url": "https://example.com/"}}, "claim_token": "tok_1"})
        );
        let writes = core.transport().writes();
        assert_eq!(body_json(&writes[1])["claim_token"], "tok_1");
    }

    #[test]
    fn losing_unclear_and_rejected_outcomes_are_typed() {
        let transport = RouteTransport::local();
        transport.enqueue(
            "POST",
            CLAIM,
            vec![
                Reply::json(200, r#"{"claimed":false}"#),
                Reply::json(200, r#"{"claimed":true}"#),
                Reply::json(200, "<html>"),
                Reply::json(404, r#"{"detail":"Session not found"}"#),
            ],
        );
        transport.enqueue(
            "POST",
            RESULT,
            vec![
                Reply::json(403, r#"{"error":{"message":"browser action result requires a matching claim_token"}}"#),
                Reply::json(202, r#"{"resolved":false}"#),
            ],
        );
        let core = connected(transport);
        assert_eq!(
            block_on(core.claim_browser_action("conv_a", "baction_1")),
            Ok(BrowserActionClaim::NotClaimed)
        );
        for _ in 0..2 {
            assert!(matches!(
                block_on(core.claim_browser_action("conv_a", "baction_1")),
                Err(SessionError::DeliveryUncertain { .. })
            ));
        }
        assert!(matches!(
            block_on(core.claim_browser_action("conv_a", "baction_1")),
            Err(SessionError::Rejected { status: 404, .. })
        ));
        assert_eq!(
            block_on(core.post_browser_action_result(
                "conv_a",
                "baction_1",
                "x",
                json!({"ok": true})
            )),
            Err(SessionError::BrowserAction(
                BrowserActionError::ClaimRejected
            ))
        );
        assert_eq!(
            block_on(core.post_browser_action_result(
                "conv_a",
                "baction_1",
                "x",
                json!({"ok": true})
            )),
            Ok(BrowserActionDelivery::Expired)
        );
        let writes = core.transport().writes().len();
        assert_eq!(
            block_on(core.post_browser_action_result("conv_a", "baction_1", "", json!({}))),
            Err(SessionError::BrowserAction(
                BrowserActionError::MissingClaimToken
            ))
        );
        assert!(matches!(
            block_on(core.claim_browser_action("conv_a", "../x")),
            Err(SessionError::InvalidIdentifier { .. })
        ));
        assert_eq!(core.transport().writes().len(), writes, "nothing sent");
    }
}
