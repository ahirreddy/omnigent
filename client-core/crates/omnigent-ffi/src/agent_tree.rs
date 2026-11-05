//! The Agents panel's spawn tree: the top-level session and its sub-agents, each with where it
//! stands.
//!
//! The rules are `omnigent_core::agent_tree`'s.

use omnigent_core::agent_tree as core;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// Where an agent stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentActivity {
    /// Starting up.
    Launching,
    /// Working on a task.
    Working,
    /// Blocked on an approval or a question.
    NeedsYou,
    /// The latest task completed.
    Done,
    /// The latest task failed.
    Failed,
    /// The runner went away; the task did not fail.
    Disconnected,
    /// No task has run, or it is waiting for one.
    Idle,
    /// Another task status, shown as reported.
    Other,
}

impl From<core::AgentActivity> for AgentActivity {
    fn from(activity: core::AgentActivity) -> Self {
        use core::AgentActivity as A;
        match activity {
            A::Launching => Self::Launching,
            A::Working => Self::Working,
            A::NeedsYou => Self::NeedsYou,
            A::Done => Self::Done,
            A::Failed => Self::Failed,
            A::Disconnected => Self::Disconnected,
            A::Idle => Self::Idle,
            A::Other => Self::Other,
        }
    }
}

/// What a sub-agent does, by its type, for its icon.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentRole {
    /// Explores a codebase.
    Explore,
    /// Researches.
    Research,
    /// Plans or designs.
    Plan,
    /// Reviews.
    Review,
    /// Tests.
    Test,
    /// Writes documents.
    Docs,
    /// Writes code.
    Code,
    /// Anything else.
    Generic,
}

impl From<core::AgentRole> for AgentRole {
    fn from(role: core::AgentRole) -> Self {
        use core::AgentRole as R;
        match role {
            R::Explore => Self::Explore,
            R::Research => Self::Research,
            R::Plan => Self::Plan,
            R::Review => Self::Review,
            R::Test => Self::Test,
            R::Docs => Self::Docs,
            R::Code => Self::Code,
            R::Generic => Self::Generic,
        }
    }
}

/// One agent in the tree.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentNode {
    /// Its session.
    pub session_id: String,
    /// The agent it runs under; `None` for the root.
    pub parent_id: Option<String>,
    /// Levels below the root: 0 for the root.
    pub depth: u32,
    /// Its name.
    pub name: String,
    /// What it does, for its icon.
    pub role: AgentRole,
    /// Where it stands.
    pub activity: AgentActivity,
    /// "Working", "Needs you", or a task status as reported.
    pub status_label: String,
    /// The first line of the error behind a failure or disconnect.
    pub status_detail: Option<String>,
    /// Finished or idle: shown dimmed so live agents stand out.
    pub is_settled: bool,
    /// Its latest message, one line.
    pub preview: Option<String>,
    /// The model smart routing picked for it.
    pub routed_model: Option<String>,
    /// Sub-agents listed under it.
    pub child_count: u32,
}

impl From<core::AgentNode> for AgentNode {
    fn from(node: core::AgentNode) -> Self {
        Self {
            session_id: node.session_id,
            parent_id: node.parent_id,
            depth: node.depth,
            name: node.name,
            role: node.role.into(),
            activity: node.status.activity.into(),
            status_label: node.status.label,
            status_detail: node.status.detail,
            is_settled: node.status.activity.is_settled(),
            preview: node.preview,
            routed_model: node.routed_model,
            child_count: node.child_count,
        }
    }
}

/// The spawn tree: the root first, then each agent followed by its own sub-agents.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentTree {
    /// The top-level session.
    pub root_id: String,
    /// Every agent, depth first.
    pub nodes: Vec<AgentNode>,
}

impl From<core::AgentTree> for AgentTree {
    fn from(tree: core::AgentTree) -> Self {
        Self {
            root_id: tree.root_id,
            nodes: tree.nodes.into_iter().map(Into::into).collect(),
        }
    }
}

#[uniffi::export]
impl ClientCore {
    /// The spawn tree `session_id` belongs to, from its top-level session.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn agent_tree(&self, session_id: String) -> Result<AgentTree, CoreError> {
        self.sessions()
            .agent_tree(&session_id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}
