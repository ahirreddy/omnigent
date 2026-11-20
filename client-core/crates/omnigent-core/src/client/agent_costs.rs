//! What each agent of a session's tree cost, as the web's `useAgentCosts` reads it
//! (`GET /v1/sessions/{id}/agent_costs`) and its `AgentCostTag` shows it.

use serde_json::Value;

use super::json::{as_object, opt_array, opt_bool, opt_str};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// Agents read per page, as the web.
const PAGE_SIZE: &str = "1000";

/// One agent's cost.
#[derive(Debug, Clone, PartialEq)]
pub struct AgentCost {
    /// The agent's session.
    pub id: String,
    /// Its priced subtree's total; `None` when nothing in it is priced.
    pub cost_usd: Option<f64>,
    /// An ancestor's estimate, when the agent reports no cost of its own.
    pub estimated_cost_usd: Option<f64>,
}

impl AgentCost {
    /// Its tag: `$0.42`, `<$0.01`, or `~$0.10` for an estimate; `None` when unknown.
    #[must_use]
    pub fn label(&self) -> Option<String> {
        if let Some(cost) = self.cost_usd {
            return Some(dollars(cost));
        }
        self.estimated_cost_usd
            .map(|cost| format!("~{}", dollars(cost)))
    }
}

/// A cost in cents, or `<$0.01` when rounding would read as free.
fn dollars(cost: f64) -> String {
    if cost > 0.0 && cost < 0.01 {
        "<$0.01".to_owned()
    } else {
        format!("${cost:.2}")
    }
}

fn finite(value: Option<&Value>) -> Option<f64> {
    value
        .and_then(Value::as_f64)
        .filter(|cost| cost.is_finite())
}

fn page_from(value: &Value) -> Result<(Vec<AgentCost>, Option<String>), String> {
    let object = as_object(value, "agent costs")?;
    let costs = opt_array(object, "data")?
        .ok_or("`data` is missing")?
        .iter()
        .map(|entry| {
            let entry = as_object(entry, "agent cost")?;
            Ok(AgentCost {
                id: opt_str(entry, "id")?.ok_or("`id` is missing")?,
                cost_usd: finite(entry.get("cost_usd")),
                estimated_cost_usd: finite(entry.get("estimated_cost_usd")),
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    let next = if opt_bool(object, "has_more")? == Some(true) {
        opt_str(object, "last_id")?.filter(|id| !id.is_empty())
    } else {
        None
    };
    Ok((costs, next))
}

impl<T: HttpTransport> ClientCore<T> {
    /// The costs of `session_id` and every agent under it, in tree order, a thousand a page.
    /// `None` when the server has no such route (its first page is a 404). A page after the
    /// first that fails (the tree grew past a cursor) starts over once.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; the read errors;
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn agent_costs(
        &self,
        session_id: &str,
    ) -> Result<Option<Vec<AgentCost>>, SessionError> {
        let result = async {
            validate_identifier(session_id)?;
            let read = match self.agent_cost_pages(session_id).await {
                Err(AgentCostRead::Failed(_)) => self.agent_cost_pages(session_id).await,
                read => read,
            };
            match read {
                Ok(costs) => Ok(Some(costs)),
                Err(AgentCostRead::Missing) => Ok(None),
                Err(AgentCostRead::First(error) | AgentCostRead::Failed(error)) => Err(error),
            }
        }
        .await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn agent_cost_pages(&self, session_id: &str) -> Result<Vec<AgentCost>, AgentCostRead> {
        let path = format!("/v1/sessions/{session_id}/agent_costs");
        let mut costs = Vec::new();
        let mut after: Option<String> = None;
        loop {
            let mut query = vec![("limit", PAGE_SIZE.to_owned())];
            if let Some(after) = &after {
                query.push(("after", after.clone()));
            }
            let first = after.is_none();
            let value = match self.get_json(&path, &query).await {
                Ok(value) => value,
                Err(SessionError::HttpStatus { status: 404 }) if first => {
                    return Err(AgentCostRead::Missing);
                }
                Err(error) if first => return Err(AgentCostRead::First(error)),
                Err(error) => return Err(AgentCostRead::Failed(error)),
            };
            let (page, next) = page_from(&value).map_err(|detail| {
                AgentCostRead::First(SessionError::MalformedResponse {
                    detail: format!("{path}: {detail}"),
                })
            })?;
            costs.extend(page);
            match next {
                Some(next) if after.as_ref() != Some(&next) => after = Some(next),
                _ => return Ok(costs),
            }
        }
    }
}

/// Why reading the pages stopped.
enum AgentCostRead {
    /// The first page is a 404: the server predates the route.
    Missing,
    /// The first page failed otherwise, or a page was malformed.
    First(SessionError),
    /// A later page failed; reading again from the start may succeed.
    Failed(SessionError),
}

#[cfg(test)]
#[path = "agent_costs_tests.rs"]
mod tests;
