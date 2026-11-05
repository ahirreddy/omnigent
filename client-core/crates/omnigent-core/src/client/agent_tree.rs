//! The Agents panel's spawn tree (web `SubagentsPanel`, `useChildSessions`).
//!
//! The top-level session and its sub-agents from `GET /v1/sessions/{id}/child_sessions`, down
//! to [`AGENT_TREE_DEPTH`] levels, each with where it stands.
//!
//! The tree always starts at the root, so a sub-agent's chat shows the whole tree with itself
//! in it. The root is the snapshot's `root_conversation_id`, or the parent chain's top on a
//! server that predates it.

use omnigent_protocol::items::ItemData;
use omnigent_protocol::sessions::{SessionSnapshot, SessionStatus};
use serde_json::{Map, Value};

use super::json::{as_object, opt_array, opt_object, opt_str, opt_u64};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::config::session::{canonical_harness, harness_label};
use crate::http::HttpTransport;

/// Levels of sub-agents below the root that are read and shown.
pub const AGENT_TREE_DEPTH: u32 = 3;
/// Parent hops followed when the server reports no `root_conversation_id`.
const MAX_PARENT_HOPS: usize = 8;
/// `child_sessions` lists read at most per tree.
const MAX_LISTS: usize = 64;
/// Newest items read for the root's latest message.
const PREVIEW_ITEMS: u32 = 20;
/// Characters of the root's latest message, like the server's child preview.
const PREVIEW_CHARS: usize = 150;
const WRAPPER_LABEL: &str = "omnigent.wrapper";
const NATIVE_SUBAGENT_WRAPPERS: [&str; 4] = [
    "codex-native-ui-subagent",
    "opencode-native-ui-subagent",
    "antigravity-native-ui-subagent",
    "claude-code-native-ui-subagent",
];
/// Wrappers whose children carry their functional role in a label, and that label.
const ROLE_LABELS: [(&str, &str); 2] = [
    (
        "codex-native-ui-subagent",
        "omnigent.codex_native.agent_role",
    ),
    (
        "antigravity-native-ui-subagent",
        "omnigent.antigravity_native.agent_role",
    ),
];
/// Error codes that mean the runner went away rather than the task failing.
const RUNNER_DISCONNECT_CODES: [&str; 3] = [
    "runner_disconnected",
    "runner_failed_to_start",
    "runner_process_crash",
];
/// Title prefix of an agent the user added under a session (`ui:<agent>:<name>`).
const USER_ADDED_PREFIX: &str = "ui:";

/// Where an agent stands (web `AgentActivity`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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

impl AgentActivity {
    /// Finished or idle: the panel dims these so live agents stand out.
    #[must_use]
    pub const fn is_settled(self) -> bool {
        matches!(self, Self::Done | Self::Idle)
    }
}

/// What a sub-agent does, by its type, for its icon (web `iconForAgentType`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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

impl AgentRole {
    /// The role of an agent type such as `Explore` or `researcher`.
    #[must_use]
    pub fn of(agent_type: Option<&str>) -> Self {
        let kind = agent_type.unwrap_or_default().to_lowercase();
        let has = |part: &str| kind.contains(part);
        if has("explore") {
            Self::Explore
        } else if has("research") {
            Self::Research
        } else if has("plan") || has("architect") {
            Self::Plan
        } else if has("review") {
            Self::Review
        } else if has("test") {
            Self::Test
        } else if has("doc") || has("writ") {
            Self::Docs
        } else if ["code", "eng", "dev", "front", "back"]
            .iter()
            .any(|part| has(part))
        {
            Self::Code
        } else {
            Self::Generic
        }
    }
}

/// An agent's status: its activity, the word for it and, for failures, the first error line.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AgentStatus {
    /// Where it stands.
    pub activity: AgentActivity,
    /// "Working", "Needs you", or a task status as reported.
    pub label: String,
    /// The first line of the error behind a failure or disconnect.
    pub detail: Option<String>,
}

impl AgentStatus {
    fn new(activity: AgentActivity, label: &str) -> Self {
        Self {
            activity,
            label: label.to_owned(),
            detail: None,
        }
    }

    fn with_error(activity: AgentActivity, label: &str, message: &str) -> Self {
        Self {
            detail: first_line(message),
            ..Self::new(activity, label)
        }
    }
}

/// One `ChildSessionSummary` row of `GET /v1/sessions/{id}/child_sessions`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ChildSessionRow {
    /// The child session.
    pub id: String,
    /// `{tool}:{session_name}`.
    pub title: Option<String>,
    /// A label derived from its task.
    pub task_summary: Option<String>,
    /// The sub-agent type.
    pub tool: Option<String>,
    /// The instance name.
    pub session_name: Option<String>,
    /// The child's labels.
    pub labels: Map<String, Value>,
    /// The latest task's status.
    pub current_task_status: Option<String>,
    /// The latest failed run's `(code, message)`.
    pub last_task_error: Option<(String, String)>,
    /// A task is queued or running.
    pub busy: bool,
    /// Its latest message, one line.
    pub last_message_preview: Option<String>,
    /// Requests it waits on.
    pub pending_elicitations_count: u64,
    /// The model smart routing picked for it.
    pub routed_model: Option<String>,
}

impl ChildSessionRow {
    fn label(&self, key: &str) -> Option<&str> {
        self.labels.get(key).and_then(Value::as_str)
    }

    /// Where the child stands (web `childStatus`). A pending request outranks `busy`: the
    /// child is mid-turn but blocked on the user.
    #[must_use]
    pub fn status(&self) -> AgentStatus {
        use AgentActivity as A;
        if self.pending_elicitations_count > 0 {
            return AgentStatus::new(A::NeedsYou, "Needs you");
        }
        let task = self
            .current_task_status
            .as_deref()
            .filter(|s| !s.is_empty());
        if task == Some("launching") {
            return AgentStatus::new(A::Launching, "Launching");
        }
        if self.busy {
            return AgentStatus::new(A::Working, "Working");
        }
        if let Some((code, message)) = &self.last_task_error {
            return if RUNNER_DISCONNECT_CODES.contains(&code.as_str()) {
                AgentStatus::with_error(A::Disconnected, "Disconnected", message)
            } else {
                AgentStatus::with_error(A::Failed, "Failed", message)
            };
        }
        match task {
            Some("failed") => AgentStatus::new(A::Failed, "Failed"),
            Some("completed") => AgentStatus::new(A::Done, "Done"),
            Some(other) => AgentStatus::new(A::Other, other),
            None => AgentStatus::new(A::Idle, "Idle"),
        }
    }

    /// The row's name (web `childPrimaryLabel`): a native sub-agent's type, else its task, its
    /// instance name or its title's name part.
    #[must_use]
    pub fn display_name(&self) -> String {
        let present = |value: &Option<String>| value.clone().filter(|text| !text.is_empty());
        let user_added = self
            .title
            .as_deref()
            .is_some_and(|title| title.starts_with(USER_ADDED_PREFIX));
        let native = self
            .label(WRAPPER_LABEL)
            .is_some_and(|wrapper| NATIVE_SUBAGENT_WRAPPERS.contains(&wrapper));
        if native && !user_added {
            return present(&self.tool)
                .or_else(|| present(&self.title))
                .unwrap_or_else(|| self.id.clone());
        }
        let title_name = self
            .title
            .as_deref()
            .and_then(|title| title.split_once(':'))
            .map(|(_, name)| name.to_owned())
            .filter(|name| !name.is_empty());
        present(&self.task_summary)
            .or_else(|| present(&self.session_name))
            .or(title_name)
            .or_else(|| present(&self.title))
            .or_else(|| present(&self.tool))
            .unwrap_or_else(|| self.id.clone())
    }

    /// The role behind its icon: a native child's role label, else its type.
    #[must_use]
    pub fn role(&self) -> AgentRole {
        let wrapper = self.label(WRAPPER_LABEL);
        let role_label = ROLE_LABELS
            .iter()
            .find(|(owner, _)| Some(*owner) == wrapper)
            .and_then(|(_, key)| self.label(key));
        AgentRole::of(role_label.or(self.tool.as_deref()))
    }
}

/// One agent in the tree.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
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
    pub status: AgentStatus,
    /// Its latest message, one line.
    pub preview: Option<String>,
    /// The model smart routing picked for it.
    pub routed_model: Option<String>,
    /// Sub-agents listed under it.
    pub child_count: u32,
}

/// The spawn tree: the root first, then each agent followed by its own sub-agents.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AgentTree {
    /// The top-level session.
    pub root_id: String,
    /// Every agent, depth first.
    pub nodes: Vec<AgentNode>,
}

impl AgentTree {
    /// Agents below the root.
    #[must_use]
    pub const fn subagent_count(&self) -> usize {
        self.nodes.len().saturating_sub(1)
    }
}

/// Decodes a `child_sessions` response.
///
/// # Errors
///
/// A description when the body is not a list of child sessions.
pub fn decode_child_sessions(value: &Value) -> Result<Vec<ChildSessionRow>, String> {
    let object = as_object(value, "child sessions response")?;
    let rows = opt_array(object, "data")?.ok_or("`data` is missing")?;
    rows.iter().map(decode_child).collect()
}

fn decode_child(value: &Value) -> Result<ChildSessionRow, String> {
    let row = as_object(value, "child session")?;
    let id = opt_str(row, "id")?
        .filter(|id| !id.is_empty())
        .ok_or("`id` is missing")?;
    let last_task_error = opt_object(row, "last_task_error")?.and_then(|error| {
        let text = |key: &str| error.get(key).and_then(Value::as_str).unwrap_or_default();
        let (code, message) = (text("code"), text("message"));
        (!code.is_empty() && !message.is_empty()).then(|| (code.to_owned(), message.to_owned()))
    });
    Ok(ChildSessionRow {
        title: opt_str(row, "title")?,
        task_summary: opt_str(row, "task_summary")?,
        tool: opt_str(row, "tool")?,
        session_name: opt_str(row, "session_name")?,
        labels: opt_object(row, "labels")?.cloned().unwrap_or_default(),
        current_task_status: opt_str(row, "current_task_status")?,
        last_task_error,
        busy: row.get("busy").and_then(Value::as_bool).unwrap_or_default(),
        last_message_preview: opt_str(row, "last_message_preview")?.filter(|s| !s.is_empty()),
        pending_elicitations_count: opt_u64(row, "pending_elicitations_count")?.unwrap_or_default(),
        routed_model: opt_str(row, "routed_model")?.filter(|s| !s.is_empty()),
        id,
    })
}

/// The root's status from its snapshot (web `sessionStatus`).
#[must_use]
pub fn root_status(snapshot: &SessionSnapshot) -> AgentStatus {
    use AgentActivity as A;
    match &snapshot.status {
        SessionStatus::Launching => AgentStatus::new(A::Launching, "Launching"),
        SessionStatus::Running => AgentStatus::new(A::Working, "Working"),
        SessionStatus::Failed => {
            let error = snapshot.last_task_error.value();
            let field = |key: &str| error.and_then(|error| error.get(key)).map(String::as_str);
            let message = field("message").unwrap_or_default();
            if field("code").is_some_and(|code| RUNNER_DISCONNECT_CODES.contains(&code)) {
                AgentStatus::with_error(A::Disconnected, "Disconnected", message)
            } else {
                AgentStatus::new(A::Failed, "Failed")
            }
        }
        _ => AgentStatus::new(A::Idle, "Idle"),
    }
}

/// The root's name: a native harness's product name, else its agent's name, else "main".
#[must_use]
pub fn root_name(snapshot: &SessionSnapshot) -> String {
    let harness = snapshot.harness.value().map(String::as_str);
    if canonical_harness(harness).ends_with("-native") {
        return harness_label(harness);
    }
    snapshot
        .agent_name
        .value()
        .filter(|name| !name.is_empty())
        .cloned()
        .unwrap_or_else(|| "main".to_owned())
}

fn first_line(message: &str) -> Option<String> {
    message
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(str::to_owned)
}

fn preview(text: &str) -> Option<String> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    let mut preview: String = text.chars().take(PREVIEW_CHARS).collect();
    if text.chars().nth(PREVIEW_CHARS).is_some() {
        preview.push('\u{2026}');
    }
    Some(preview)
}

impl<T: HttpTransport> ClientCore<T> {
    /// The spawn tree `session_id` belongs to, from its root.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; the read errors;
    /// [`SessionError::MalformedResponse`] for an unreadable child list.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn agent_tree(&self, session_id: &str) -> Result<AgentTree, SessionError> {
        let result = self.read_agent_tree(session_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn read_agent_tree(&self, session_id: &str) -> Result<AgentTree, SessionError> {
        let root = self.root_snapshot(session_id).await?;
        let mut top = self.child_sessions(&root.id).await?;
        let mut nodes = vec![AgentNode {
            session_id: root.id.clone(),
            parent_id: None,
            depth: 0,
            name: root_name(&root),
            role: AgentRole::Generic,
            status: root_status(&root),
            preview: self.latest_message(&root.id).await?,
            routed_model: None,
            child_count: u32::try_from(top.len()).unwrap_or(u32::MAX),
        }];
        let mut lists = 1;
        // Depth first: `levels` holds the unvisited rows of each open level, reversed.
        top.reverse();
        let mut levels = vec![top];
        let mut parents = vec![root.id.clone()];
        while let Some(level) = levels.last_mut() {
            let Some(child) = level.pop() else {
                levels.pop();
                parents.pop();
                continue;
            };
            let depth = u32::try_from(levels.len()).unwrap_or(u32::MAX);
            let visited = nodes.iter().any(|node| node.session_id == child.id);
            let mut grandchildren = Vec::new();
            if depth < AGENT_TREE_DEPTH && lists < MAX_LISTS && !visited {
                grandchildren = self.child_sessions(&child.id).await?;
                lists += 1;
            }
            nodes.push(AgentNode {
                parent_id: parents.last().cloned(),
                depth,
                name: child.display_name(),
                role: child.role(),
                status: child.status(),
                preview: child.last_message_preview.clone(),
                routed_model: child.routed_model.clone(),
                child_count: u32::try_from(grandchildren.len()).unwrap_or(u32::MAX),
                session_id: child.id.clone(),
            });
            if !grandchildren.is_empty() {
                grandchildren.reverse();
                levels.push(grandchildren);
                parents.push(child.id);
            }
        }
        Ok(AgentTree {
            root_id: root.id,
            nodes,
        })
    }

    /// The snapshot of the tree's top-level session.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn root_snapshot(&self, session_id: &str) -> Result<SessionSnapshot, SessionError> {
        let mut snapshot = self.fetch_snapshot(session_id).await?.0.snapshot;
        if let Some(root) = snapshot
            .root_conversation_id
            .value()
            .filter(|root| !root.is_empty())
            .cloned()
        {
            if root != snapshot.id {
                snapshot = self.fetch_snapshot(&root).await?.0.snapshot;
            }
            return Ok(snapshot);
        }
        for _ in 0..MAX_PARENT_HOPS {
            let Some(parent) = snapshot
                .parent_session_id
                .value()
                .filter(|parent| !parent.is_empty() && **parent != snapshot.id)
                .cloned()
            else {
                break;
            };
            snapshot = self.fetch_snapshot(&parent).await?.0.snapshot;
        }
        Ok(snapshot)
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn child_sessions(&self, session_id: &str) -> Result<Vec<ChildSessionRow>, SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}/child_sessions");
        let value = self.get_json(&path, &[]).await?;
        decode_child_sessions(&value).map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        })
    }

    /// The session's latest visible message, one line.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn latest_message(&self, session_id: &str) -> Result<Option<String>, SessionError> {
        let page = self.history_page(session_id, None, PREVIEW_ITEMS).await?;
        Ok(page.items.iter().rev().find_map(|item| match &item.data {
            ItemData::Message(message) if !message.is_hidden_context() => {
                preview(&message.visible_text())
            }
            _ => None,
        }))
    }
}

#[cfg(test)]
#[path = "agent_tree_tests.rs"]
mod tests;
