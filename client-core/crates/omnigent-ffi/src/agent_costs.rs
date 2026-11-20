//! What each agent of a session's tree cost, as the web's agent cost tags show it. The rules are
//! `omnigent_core::agent_costs`.

use crate::client::ClientCore;
use crate::errors::CoreError;

/// One agent's cost tag.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentCostTag {
    /// The agent's session.
    pub id: String,
    /// `$0.42`, `<$0.01`, or `~$0.10` for an estimate.
    pub label: String,
}

#[uniffi::export]
impl ClientCore {
    /// The cost tags of `session_id` and every agent under it, in tree order; agents with no
    /// known cost are left out. `None` when the server has no agent costs to read.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors and `MalformedResponse`.
    pub async fn agent_cost_tags(
        &self,
        session_id: String,
    ) -> Result<Option<Vec<AgentCostTag>>, CoreError> {
        let costs = self
            .sessions()
            .agent_costs(&session_id)
            .await
            .map_err(CoreError::from)?;
        Ok(costs.map(|costs| {
            costs
                .into_iter()
                .filter_map(|cost| {
                    cost.label()
                        .map(|label| AgentCostTag { id: cost.id, label })
                })
                .collect()
        }))
    }
}
