//! The caller's automations (scheduled tasks): `/v1/scheduled-tasks` lists, creates, edits,
//! pauses, runs and deletes them. Servers advertise them with `automations_enabled` in
//! `/v1/info`.

use serde_json::{Map, Value, json};

use super::json::{as_object, opt_array, opt_bool, opt_object, opt_str, opt_u64, req_str};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::automation_triggers::is_trigger_prompt;
use crate::http::HttpTransport;
use crate::schedule::{describe_schedule_in, parse_iso8601};
use crate::session_families::{SiblingDestinations, sibling_sessions_enabled};

/// The top-level pages `GET /v1/info` advertises. Missing fields mean unsupported.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "one flag per independent /v1/info feature"
)]
pub struct ServerPages {
    /// `automations_enabled`: the Automations page.
    pub automations: bool,
    /// `scheduled_task_session_modes`: an automation can continue one session across runs.
    pub automation_session_modes: bool,
    /// The `usage_page` feature: the Usage page.
    pub usage: bool,
    /// `archive_worktree_cleanup`: archiving can also remove a session's git worktree.
    pub archive_worktree_cleanup: bool,
    /// Sessions can be shared: `single_user` is not `true` and `sharing_mode` is not `off`.
    pub sharing: bool,
    /// A multi-user server whose admin turned sharing off (`sharing_mode` `off`): Share stays
    /// visible but disabled, with the reason.
    pub sharing_disabled: bool,
    /// The `canvas` feature: the Canvas page.
    pub canvas: bool,
    /// The `automations_v2` feature: custom schedules, run-count endings and run history.
    pub automations_v2: bool,
    /// `scheduled_task_projects`: an automation can file its sessions into a project.
    pub automation_projects: bool,
    /// `managed_sandboxes_enabled`: an automation can run in a new sandbox each time.
    pub managed_sandboxes: bool,
    /// Jira, Slack and GitHub trigger templates: session modes plus the
    /// `session_orchestration` feature, since a trigger's session starts the others.
    pub automation_triggers: bool,
    /// `sibling_sessions`: the caller can add nested agents to a session family.
    pub sibling_sessions: bool,
    /// `session_nest_moves`: an owned session moves into another nest or out of its own.
    pub session_nest_moves: bool,
    /// `sibling_session_destinations`: where a nested agent may start.
    pub sibling_destinations: SiblingDestinations,
    /// `inbox_items_available`: agents post items to the caller's Inbox.
    pub inbox_items: bool,
    /// `scheduled_task_inbox`: the Inbox lists automation failures that made no session.
    pub automation_inbox: bool,
    /// `proactive_agent_available`: Omni Advisor can post suggestions to the caller's Inbox.
    pub advisor: bool,
    /// `public_sharing_enabled`: a session can be opened to anyone with the link. Only an
    /// explicit `false` turns it off, as on the web.
    pub public_sharing: bool,
    /// `sharing_mode` is `read_only` or `restricted_read_only`: grants are Read only.
    pub sharing_read_only: bool,
    /// `sharing_mode` is `restricted_read_only`: home and root folders are not shared either.
    pub sharing_restricted: bool,
    /// `public_sharing_max_level` is `edit`: a public link may let anyone with it edit.
    pub public_edit: bool,
    /// The `project_repository_creation` feature: New project can start from a repository.
    pub project_repository_creation: bool,
    /// The `project_kanban` feature: a project opens its sessions board.
    pub project_kanban: bool,
    /// The `session_overview` feature: a cost chip opens the session's overview, and agents
    /// show their costs.
    pub session_overview: bool,
    /// The `import_review` feature: desktop onboarding reviews what a new host carries over.
    pub import_review: bool,
    /// `scheduled_task_subhour`: hosts and continued sessions run schedules under an hour.
    pub automation_subhour: bool,
    /// `scheduled_task_trigger_headers`: runs drop a trigger prompt's header before dispatch.
    pub automation_trigger_headers: bool,
    /// `automation_trigger_poll_minutes`: how often a trigger checks its service (10 when
    /// the server doesn't say).
    pub automation_trigger_poll_minutes: u32,
    /// `session_message_max_chars`: the longest message the server delivers; 0 on older
    /// servers, which deliver 8,000 characters.
    pub session_message_max_chars: u32,
    /// `scheduled_task_mcp_services` and an MCP registry: runs can start with MCP services.
    pub automation_mcp_services: bool,
    /// `scheduled_task_source_sessions`: an automation can start each run from a session copy.
    pub automation_source_sessions: bool,
    /// `scheduled_task_sharing` on a multi-user server: automations can be shared.
    pub automation_sharing: bool,
    /// `scheduled_task_shared_with_me` on a multi-user server: the Shared with me list.
    pub automation_shared_with_me: bool,
    /// `scheduled_task_clone`: an automation can be copied under a new id.
    pub automation_clone: bool,
    /// `scheduled_task_default_timezone`: agent-created automations take the zone the apps
    /// record for the caller.
    pub automation_default_timezone: bool,
    /// `scheduled_task_run_pull_requests`: the PRs each run created or worked on.
    pub automation_run_pull_requests: bool,
    /// `scheduled_task_harness_settings`: every native harness takes a permission mode.
    pub automation_harness_settings: bool,
    /// `scheduled_task_approval_skipping_modes`: modes that skip approval are accepted.
    pub automation_approval_skipping_modes: bool,
    /// `session_create_permission_modes`: a trigger's workers can take a permission mode.
    pub session_create_permission_modes: bool,
    /// The `workflows` feature and `workflows`: saved workflows, their pages and Run a workflow.
    pub workflows: bool,
    /// `workflow_sharing` on a multi-user server with workflows: a workflow can be shared, and
    /// the Workflows page lists those shared with the caller.
    pub workflow_sharing: bool,
    /// `session_create_workflow_id` with workflows on: a trigger's workers can start as runs of
    /// the saved workflow their instructions run.
    pub session_create_workflow_id: bool,
    /// `session_mute`: the server keeps each viewer's mute to themselves, so Mute is offered.
    pub session_mute: bool,
}

impl ServerPages {
    /// Decodes the page fields of a `/v1/info` body.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "/v1/info")?;
        let features = opt_object(object, "features")?;
        let feature = |name: &str| {
            features.map_or(Ok(false), |features| {
                opt_bool(features, name).map(|flag| flag.unwrap_or(false))
            })
        };
        let session_modes = opt_bool(object, "scheduled_task_session_modes")?.unwrap_or(false);
        let single_user = opt_bool(object, "single_user")?.unwrap_or(false);
        let sharing_mode = opt_str(object, "sharing_mode")?;
        let sharing_off = sharing_mode.as_deref() == Some("off");
        let sharing_restricted = sharing_mode.as_deref() == Some("restricted_read_only");
        let flag = |name: &str| opt_bool(object, name).map(|flag| flag.unwrap_or(false));
        let count = |name: &str| {
            opt_u64(object, name)
                .map(|value| value.map(|value| u32::try_from(value).unwrap_or(u32::MAX)))
        };
        let mcp_registry = opt_array(object, "enabled_connections")?.is_some_and(|connections| {
            connections
                .iter()
                .any(|entry| entry.as_str() == Some("mcp"))
        });
        let workflows = feature("workflows")? && flag("workflows")?;
        Ok(Self {
            workflows,
            workflow_sharing: workflows && flag("workflow_sharing")? && !single_user,
            session_create_workflow_id: workflows && flag("session_create_workflow_id")?,
            automation_subhour: flag("scheduled_task_subhour")?,
            automation_trigger_headers: flag("scheduled_task_trigger_headers")?,
            automation_trigger_poll_minutes: count("automation_trigger_poll_minutes")?
                .unwrap_or(10),
            session_message_max_chars: count("session_message_max_chars")?.unwrap_or(0),
            automation_mcp_services: flag("scheduled_task_mcp_services")? && mcp_registry,
            automation_source_sessions: flag("scheduled_task_source_sessions")?,
            automation_sharing: flag("scheduled_task_sharing")? && !single_user,
            automation_shared_with_me: flag("scheduled_task_shared_with_me")? && !single_user,
            automation_clone: flag("scheduled_task_clone")?,
            automation_default_timezone: flag("scheduled_task_default_timezone")?,
            automation_run_pull_requests: flag("scheduled_task_run_pull_requests")?,
            automation_harness_settings: flag("scheduled_task_harness_settings")?,
            automation_approval_skipping_modes: flag("scheduled_task_approval_skipping_modes")?,
            session_create_permission_modes: flag("session_create_permission_modes")?,
            automations: opt_bool(object, "automations_enabled")?.unwrap_or(false),
            automation_session_modes: session_modes,
            usage: feature("usage_page")?,
            automations_v2: feature("automations_v2")?,
            automation_projects: opt_bool(object, "scheduled_task_projects")?.unwrap_or(false),
            managed_sandboxes: opt_bool(object, "managed_sandboxes_enabled")?.unwrap_or(false),
            automation_triggers: session_modes && feature("session_orchestration")?,
            archive_worktree_cleanup: opt_bool(object, "archive_worktree_cleanup")?
                .unwrap_or(false),
            sharing: !single_user && !sharing_off,
            sharing_disabled: !single_user && sharing_off,
            canvas: feature("canvas")?,
            sibling_sessions: sibling_sessions_enabled(object),
            session_nest_moves: flag("session_nest_moves")?,
            sibling_destinations: SiblingDestinations::from_info(object),
            inbox_items: opt_bool(object, "inbox_items_available")?.unwrap_or(false),
            automation_inbox: opt_bool(object, "scheduled_task_inbox")?.unwrap_or(false),
            advisor: opt_bool(object, "proactive_agent_available")?.unwrap_or(false),
            public_sharing: opt_bool(object, "public_sharing_enabled")? != Some(false),
            sharing_read_only: sharing_restricted || sharing_mode.as_deref() == Some("read_only"),
            sharing_restricted,
            public_edit: opt_str(object, "public_sharing_max_level")?.as_deref() == Some("edit"),
            project_repository_creation: feature("project_repository_creation")?,
            project_kanban: feature("project_kanban")?,
            session_overview: feature("session_overview")?,
            import_review: feature("import_review")?,
            session_mute: flag("session_mute")?,
        })
    }
}

/// Whether an automation fires.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum AutomationState {
    /// It fires on schedule.
    Active,
    /// It does not fire.
    Paused,
    /// A state this client does not know; shown as it is.
    Unknown {
        /// The server's value.
        value: String,
    },
}

/// One automation.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts of the server's record, mirrored one to one"
)]
pub struct Automation {
    /// Id.
    pub id: String,
    /// Name.
    pub name: String,
    /// The prompt each run sends.
    pub prompt: String,
    /// The RFC 5545 rule.
    pub rrule: String,
    /// The rule as text ("Weekdays at 8:00 AM").
    pub schedule_text: String,
    /// The agent each run uses.
    pub agent_id: String,
    /// The IANA zone the rule is evaluated in.
    pub timezone: String,
    /// Whether every run continues one session (`continue`) rather than starting one.
    pub continues_session: bool,
    /// Active or paused.
    pub state: AutomationState,
    /// The next fire, Unix seconds, as the server's scheduler computed it; `None` when paused.
    pub next_run_at: Option<i64>,
    /// The last fire, Unix seconds.
    pub last_run_at: Option<i64>,
    /// The latest run's status (`succeeded`, `failed`, `running`...).
    pub last_run_status: Option<String>,
    /// The latest run's session.
    pub last_run_session_id: Option<String>,
    /// Last edit, Unix seconds.
    pub updated_at: i64,
    /// The model each run uses instead of the agent's.
    pub model_override: Option<String>,
    /// The reasoning effort each run uses instead of the agent's.
    pub reasoning_effort: Option<String>,
    /// The permission mode each run launches in instead of the agent's (Claude Code).
    pub permission_mode: Option<String>,
    /// The session a continuing automation sends to; `None` until its first run.
    pub session_id: Option<String>,
    /// The pinned host; `None` runs on the host used most recently.
    pub host_id: Option<String>,
    /// The pinned folder on that host; `None` is the host's home.
    pub workspace: Option<String>,
    /// The ref each run's random worktree branches from (`HEAD`); `None` runs in the folder.
    pub base_branch: Option<String>,
    /// Each run starts in a new managed sandbox (`execution_target` `managed_sandbox`).
    pub runs_in_sandbox: bool,
    /// The project every run's session is filed into.
    pub project_id: Option<String>,
    /// It continues one session whose prompt a trigger template rendered: it runs when new
    /// items match, so it shows no schedule, next run or Run now.
    pub is_trigger: bool,
    /// The MCP services every run's session starts with.
    pub mcp_services: Vec<String>,
    /// The cost limit per run in USD, as decimal text (`2.5`); `None` is no limit.
    pub max_cost_usd: Option<String>,
    /// The session copy every run starts from.
    pub source_session_id: Option<String>,
    /// Someone else shared it with the caller, who may only read it.
    pub shared_with_me: bool,
    /// Whose it is, for a shared one: the owner's name, else their id.
    pub owner_name: String,
    /// The server can keep grants for it; `false` for a legacy one (`shareable`, absent on older
    /// servers, which can share every automation).
    pub shareable: bool,
}

impl Automation {
    /// Whether it is paused.
    #[must_use]
    pub fn is_paused(&self) -> bool {
        self.state == AutomationState::Paused
    }
}

/// What the editor saves. On create, `None` fields are left out (the server's defaults); on edit,
/// only what differs from the saved automation is sent.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent editor switches, as the web's dialog"
)]
pub struct AutomationDraft {
    /// Name.
    pub name: String,
    /// Prompt.
    pub prompt: String,
    /// The RFC 5545 rule.
    pub rrule: String,
    /// The agent.
    pub agent_id: String,
    /// IANA zone, e.g. the device's.
    pub timezone: String,
    /// Continue one session across runs; `None` on servers without session modes.
    pub continues_session: Option<bool>,
    /// The pinned host; required on create unless [`Self::runs_in_sandbox`].
    pub host_id: Option<String>,
    /// The pinned folder on the host; `None` or blank is the host's home.
    pub workspace: Option<String>,
    /// Start in a random worktree branched from this ref (`HEAD`); `None` runs in the folder.
    pub base_branch: Option<String>,
    /// Run each time in a new managed sandbox instead of on a host.
    pub runs_in_sandbox: bool,
    /// The project to file sessions into; `None` for none.
    pub project_id: Option<String>,
    /// Whether the agent takes the model, effort and permission overrides (Claude Code). When
    /// it does not, they are left out and the server keeps or clears them.
    pub sends_overrides: bool,
    /// The model; `None` is the agent's.
    pub model_override: Option<String>,
    /// The reasoning effort; `None` is the agent's.
    pub reasoning_effort: Option<String>,
    /// The permission mode; `None` is the agent's.
    pub permission_mode: Option<String>,
    /// A continuing automation's next run starts a new session.
    pub start_new_session: bool,
    /// The MCP services every run starts with; `None` leaves them as they are.
    pub mcp_services: Option<Vec<String>>,
    /// The cost limit per run in USD as typed; blank is no limit.
    pub max_cost_usd: String,
    /// Create the automation from this session: each run starts from a copy of it.
    pub source_session_id: Option<String>,
}

/// What one run of an automation did.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum AutomationRunStatus {
    /// Waiting to fire.
    Scheduled,
    /// Its host or sandbox is starting.
    Starting,
    /// The agent is working.
    Running,
    /// It finished.
    Succeeded,
    /// It failed.
    Failed,
    /// It did not fire.
    Skipped,
    /// The agent stopped reporting before it finished.
    Incomplete,
    /// A status this client does not know; shown as it is.
    Unknown {
        /// The server's value.
        value: String,
    },
}

impl AutomationRunStatus {
    fn from_wire(value: &str) -> Self {
        match value {
            "scheduled" => Self::Scheduled,
            "starting" => Self::Starting,
            "running" => Self::Running,
            "succeeded" => Self::Succeeded,
            "failed" => Self::Failed,
            "skipped" => Self::Skipped,
            "incomplete" => Self::Incomplete,
            other => Self::Unknown {
                value: other.to_owned(),
            },
        }
    }

    /// The label of a run that has not finished: `Queued`, `Starting`, `Running`.
    #[must_use]
    pub const fn in_flight_label(&self) -> Option<&'static str> {
        match self {
            Self::Scheduled => Some("Queued"),
            Self::Starting => Some("Starting"),
            Self::Running => Some("Running"),
            _ => None,
        }
    }
}

/// One run in an automation's history.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AutomationRun {
    /// Id.
    pub id: String,
    /// What it did.
    pub status: AutomationRunStatus,
    /// When it fired, else when it was due, Unix seconds.
    pub started_at: i64,
    /// How long it ran (`1m 42s`), once it finished.
    pub duration: Option<String>,
    /// The session it started or continued.
    pub session_id: Option<String>,
    /// Where it stopped (`Host`), when it did not succeed and the code names a stage.
    pub failure_stage: Option<String>,
    /// Why it did not succeed.
    pub failure_reason: Option<String>,
    /// Its session has news the caller has not seen.
    pub unread: bool,
    /// "Session cost $1.23": the session's current recorded total.
    pub session_cost: Option<String>,
    /// Its session waits on an approval or a question.
    pub needs_approval: bool,
    /// The server's description of the failure, e.g. a sandbox provider's recovery steps.
    pub error_detail: Option<String>,
    /// It succeeded but its session is still working.
    pub session_running: bool,
}

/// The automations other users shared with the caller, one page at a time.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SharedAutomationsPage {
    /// The page, each read-only.
    pub automations: Vec<Automation>,
    /// The next page's cursor; a short page can still have one.
    pub next_cursor: Option<String>,
}

/// A PR's state as its host last fetched it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RunPullRequestStatus {
    /// Open.
    Open,
    /// An open draft.
    Draft,
    /// Merged.
    Merged,
    /// Closed without merging.
    Closed,
    /// Not fetched yet.
    Unknown,
}

impl RunPullRequestStatus {
    /// The summary's word: `open`, `draft`, `merged`, `closed`, `unknown`.
    #[must_use]
    pub const fn word(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Draft => "draft",
            Self::Merged => "merged",
            Self::Closed => "closed",
            Self::Unknown => "unknown",
        }
    }

    /// The list's label: "Open", "Closed without merging".
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Open => "Open",
            Self::Draft => "Draft",
            Self::Merged => "Merged",
            Self::Closed => "Closed without merging",
            Self::Unknown => "Status unknown",
        }
    }
}

/// One PR a run created or worked on.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RunPullRequest {
    /// Its page.
    pub url: String,
    /// `owner/repo`.
    pub repository: String,
    /// `#212`, with the provider's prefix.
    pub number: String,
    /// Title, when known.
    pub title: Option<String>,
    /// Its state.
    pub status: RunPullRequestStatus,
    /// The run opened it, rather than worked on it.
    pub created_by_run: bool,
}

/// The PRs one run created or worked on.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RunPullRequests {
    /// The run.
    pub run_id: String,
    /// Its PRs.
    pub pull_requests: Vec<RunPullRequest>,
}

/// One line for a run's PRs: `PR #212 merged`, or `PRs: 2 merged, 1 closed`.
#[must_use]
pub fn run_pull_requests_summary(pull_requests: &[RunPullRequest]) -> String {
    if let [only] = pull_requests {
        return if only.status == RunPullRequestStatus::Unknown {
            format!("PR {}", only.number)
        } else {
            format!("PR {} {}", only.number, only.status.word())
        };
    }
    let parts: Vec<String> = [
        RunPullRequestStatus::Open,
        RunPullRequestStatus::Draft,
        RunPullRequestStatus::Merged,
        RunPullRequestStatus::Closed,
        RunPullRequestStatus::Unknown,
    ]
    .into_iter()
    .filter_map(|status| {
        let count = pull_requests
            .iter()
            .filter(|pr| pr.status == status)
            .count();
        (count > 0).then(|| format!("{count} {}", status.word()))
    })
    .collect();
    format!("PRs: {}", parts.join(", "))
}

/// Why Share shows disabled on a server whose admin turned sharing off (web `SHARING_OFF_REASON`).
pub const SHARING_OFF_REASON: &str = "Sharing has been disabled for this Omnigent server.";
/// Why Share shows disabled on an automation the server can't keep grants for, where the server
/// can clone it; the server says the same when it refuses one.
pub const LEGACY_AUTOMATION_SHARE_REASON: &str =
    "This is a legacy automation. Clone it, then share the copy.";
/// The same reason on a server that can't clone automations.
pub const LEGACY_AUTOMATION_RECREATE_REASON: &str =
    "This is a legacy automation. Recreate it to share it.";

/// Why an automation's offered Share shows disabled, or `None` while it works.
///
/// Sharing off wins over a legacy automation, which the server's `can_clone` lets the user copy
/// and share instead (web `automationShareDisabledReason`).
#[must_use]
pub const fn automation_share_disabled_reason(
    sharing_disabled: bool,
    shareable: bool,
    can_clone: bool,
) -> Option<&'static str> {
    if sharing_disabled {
        Some(SHARING_OFF_REASON)
    } else if shareable {
        None
    } else if can_clone {
        Some(LEGACY_AUTOMATION_SHARE_REASON)
    } else {
        Some(LEGACY_AUTOMATION_RECREATE_REASON)
    }
}

/// The note after a clone: what the copy is, and what's left to do (web `cloneCreatedMessage`).
#[must_use]
pub fn automation_clone_message(clone: &Automation) -> &'static str {
    if clone.is_paused() {
        "Automation cloned. The copy is paused like the original."
    } else if clone.next_run_at.is_none() {
        // An active copy is always armed, so no next run means a finite schedule ran out.
        "Automation cloned. Its schedule has no runs left."
    } else {
        "Automation cloned. Pause or delete the original so they don't both run."
    }
}

/// The note when a clone fails, with the server's reason when it refused (web
/// `cloneFailedMessage`).
#[must_use]
pub fn automation_clone_failure(error: &SessionError) -> String {
    match error {
        SessionError::Rejected { status, message } if *status < 500 && !message.is_empty() => {
            format!("Couldn\u{2019}t clone the automation: {message}")
        }
        SessionError::Forbidden => {
            "Couldn\u{2019}t clone the automation: Only the automation\u{2019}s owner can clone it."
                .to_owned()
        }
        _ => "Couldn\u{2019}t clone the automation".to_owned(),
    }
}

/// Session spend as the web writes it: `$x.xx`, or `<$0.01` under a cent.
#[must_use]
pub fn format_cost_usd(cost: f64) -> String {
    if cost > 0.0 && cost < 0.01 {
        "<$0.01".to_owned()
    } else {
        format!("${cost:.2}")
    }
}

/// The cost limit typed into the editor: `Ok(None)` when blank, or the problem.
///
/// # Errors
///
/// The web's message for text that isn't a number greater than zero.
pub fn parse_cost_limit(text: &str) -> Result<Option<f64>, String> {
    let text = text.trim();
    if text.is_empty() {
        return Ok(None);
    }
    text.parse::<f64>()
        .ok()
        .filter(|value| value.is_finite() && *value > 0.0)
        .map(Some)
        .ok_or_else(|| "Enter a cost limit greater than zero, or leave it blank.".to_owned())
}

/// The automations page filter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AutomationFilter {
    /// Every automation.
    All,
    /// Active ones.
    Active,
    /// Paused ones.
    Paused,
}

/// The automations page order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum AutomationSort {
    /// Active first with the soonest next run on top, then paused by name.
    #[default]
    NextRun,
    /// Every automation by name, whatever its state.
    Name,
}

/// `automations` matching `filter` and `search` (name, case-insensitive), in `sort` order.
///
/// By next run: active first with the soonest next run on top (unknown next runs after), then
/// paused by name. By name: alphabetical ignoring case, whatever the state.
#[must_use]
pub fn arrange_automations(
    automations: &[Automation],
    filter: AutomationFilter,
    sort: AutomationSort,
    search: &str,
) -> Vec<Automation> {
    let query = search.trim().to_lowercase();
    let mut matches: Vec<Automation> = automations
        .iter()
        .filter(|automation| match filter {
            AutomationFilter::All => true,
            AutomationFilter::Active => automation.state == AutomationState::Active,
            AutomationFilter::Paused => automation.is_paused(),
        })
        .filter(|automation| query.is_empty() || automation.name.to_lowercase().contains(&query))
        .cloned()
        .collect();
    if sort == AutomationSort::Name {
        matches.sort_by(|left, right| {
            left.name
                .to_lowercase()
                .cmp(&right.name.to_lowercase())
                .then_with(|| left.name.cmp(&right.name))
        });
        return matches;
    }
    matches.sort_by(|left, right| {
        left.is_paused()
            .cmp(&right.is_paused())
            .then_with(|| {
                if left.is_paused() {
                    return std::cmp::Ordering::Equal;
                }
                match (left.next_run_at, right.next_run_at) {
                    (Some(left), Some(right)) => left.cmp(&right),
                    (Some(_), None) => std::cmp::Ordering::Less,
                    (None, Some(_)) => std::cmp::Ordering::Greater,
                    (None, None) => std::cmp::Ordering::Equal,
                }
            })
            .then_with(|| left.name.cmp(&right.name))
    });
    matches
}

fn opt_number(object: &Map<String, Value>, key: &str) -> Result<Option<f64>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(number)) => number
            .as_f64()
            .map(Some)
            .ok_or_else(|| format!("`{key}` is not a number")),
        Some(_) => Err(format!("`{key}` is not a number")),
    }
}

fn opt_i64(object: &Map<String, Value>, key: &str) -> Result<Option<i64>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        // Fractional seconds are truncated.
        Some(Value::Number(number)) => number
            .to_string()
            .split('.')
            .next()
            .and_then(|whole| whole.parse().ok())
            .map(Some)
            .ok_or_else(|| format!("`{key}` is not a whole-second time")),
        Some(_) => Err(format!("`{key}` is not a number")),
    }
}

fn automation_from(value: &Value) -> Result<Automation, String> {
    let object = as_object(value, "an automation")?;
    let rrule = req_str(object, "rrule")?;
    let state = match req_str(object, "state")?.as_str() {
        "active" => AutomationState::Active,
        "paused" => AutomationState::Paused,
        other => AutomationState::Unknown {
            value: other.to_owned(),
        },
    };
    let next_run_at = match opt_str(object, "next_run_at")? {
        None => None,
        Some(text) => Some(
            parse_iso8601(&text).ok_or_else(|| format!("`next_run_at` {text:?} is not a date"))?,
        ),
    };
    let prompt = opt_str(object, "prompt")?.unwrap_or_default();
    let continues_session = opt_str(object, "session_mode")?.as_deref() == Some("continue");
    let mcp_services = opt_array(object, "mcp_services")?
        .map(|services| {
            services
                .iter()
                .map(|service| {
                    service
                        .as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| "`mcp_services` holds a non-string".to_owned())
                })
                .collect::<Result<Vec<_>, _>>()
        })
        .transpose()?
        .unwrap_or_default();
    let owner_name = opt_str(object, "owner_display_name")?
        .filter(|name| !name.is_empty())
        .or(opt_str(object, "owner_user_id")?.filter(|id| !id.is_empty()))
        .unwrap_or_else(|| "another user".to_owned());
    let timezone = opt_str(object, "timezone")?.unwrap_or_else(|| "UTC".to_owned());
    Ok(Automation {
        id: req_str(object, "id")?,
        name: req_str(object, "name")?,
        is_trigger: continues_session && is_trigger_prompt(&prompt),
        prompt,
        schedule_text: describe_schedule_in(&rrule, Some(&timezone)),
        rrule,
        agent_id: opt_str(object, "agent_id")?.unwrap_or_default(),
        timezone,
        continues_session,
        mcp_services,
        max_cost_usd: opt_number(object, "max_cost_usd")?.map(|cost| cost.to_string()),
        source_session_id: opt_str(object, "source_session_id")?,
        shared_with_me: opt_str(object, "viewer_role")?.as_deref() == Some("viewer"),
        owner_name,
        shareable: opt_bool(object, "shareable")?.unwrap_or(true),
        state,
        next_run_at,
        last_run_at: opt_i64(object, "last_run_at")?,
        last_run_status: opt_str(object, "last_run_status")?,
        last_run_session_id: opt_str(object, "last_run_conversation_id")?,
        updated_at: opt_i64(object, "updated_at")?.unwrap_or_default(),
        model_override: opt_str(object, "model_override")?,
        reasoning_effort: opt_str(object, "reasoning_effort")?,
        permission_mode: opt_str(object, "permission_mode")?,
        session_id: opt_str(object, "session_id")?,
        host_id: opt_str(object, "host_id")?,
        workspace: opt_str(object, "workspace")?,
        base_branch: opt_str(object, "base_branch")?,
        runs_in_sandbox: opt_str(object, "execution_target")?.as_deref() == Some(MANAGED_SANDBOX),
        project_id: opt_str(object, "project_id")?,
    })
}

const MANAGED_SANDBOX: &str = "managed_sandbox";

fn rejected(message: &str) -> SessionError {
    SessionError::Rejected {
        status: 400,
        message: message.to_owned(),
    }
}

/// The trimmed text, or `None` when blank.
fn filled(value: Option<&String>) -> Option<&str> {
    value
        .map(|text| text.trim())
        .filter(|text| !text.is_empty())
}

const fn session_mode(continues: bool) -> &'static str {
    if continues { "continue" } else { "new" }
}

/// The request body for `draft`: a create when `saved` is `None`, else the edit of `saved`,
/// carrying only what changed beyond the always-sent name, prompt, rule and zone.
fn draft_body(draft: &AutomationDraft, saved: Option<&Automation>) -> Result<Value, SessionError> {
    let name = draft.name.trim();
    // A session copy carries the work, so its prompt only adds instructions.
    let from_session = draft.source_session_id.is_some()
        || saved.is_some_and(|saved| saved.source_session_id.is_some());
    if name.is_empty()
        || (draft.prompt.trim().is_empty() && !from_session)
        || draft.agent_id.is_empty()
    {
        return Err(rejected(
            "Give the automation a name, a prompt and an agent.",
        ));
    }
    let max_cost = parse_cost_limit(&draft.max_cost_usd).map_err(|message| rejected(&message))?;
    let host = filled(draft.host_id.as_ref()).filter(|_| !draft.runs_in_sandbox);
    let workspace = filled(draft.workspace.as_ref()).filter(|_| !draft.runs_in_sandbox);
    if workspace.is_some() && host.is_none() {
        return Err(rejected("Pick a host before pinning a workspace."));
    }
    if saved.is_none() && host.is_none() && !draft.runs_in_sandbox {
        return Err(rejected("Pick the host this automation runs on."));
    }
    let mut body = Map::new();
    body.insert("name".into(), json!(name));
    // A rendered template prompt is sent as it is; a typed one trimmed. An edit leaves an
    // unchanged prompt out, so the server doesn't re-check one it already holds.
    let prompt = if is_trigger_prompt(&draft.prompt) {
        draft.prompt.as_str()
    } else {
        draft.prompt.trim()
    };
    if saved.is_none_or(|saved| saved.prompt != prompt && saved.prompt.trim() != prompt) {
        body.insert("prompt".into(), json!(prompt));
    }
    body.insert("rrule".into(), json!(draft.rrule));
    body.insert("timezone".into(), json!(draft.timezone));
    let saved_cost = saved
        .and_then(|saved| saved.max_cost_usd.as_deref())
        .and_then(|cost| cost.parse::<f64>().ok());
    if saved.is_none() {
        if let Some(cost) = max_cost {
            body.insert("max_cost_usd".into(), json!(cost));
        }
    } else if max_cost != saved_cost {
        // `null` removes the limit for future runs.
        body.insert("max_cost_usd".into(), json!(max_cost));
    }
    if let Some(services) = &draft.mcp_services {
        let unchanged = saved.is_some_and(|saved| {
            saved.mcp_services.len() == services.len()
                && services
                    .iter()
                    .all(|service| saved.mcp_services.contains(service))
        });
        if !unchanged && (saved.is_some() || !services.is_empty()) {
            body.insert("mcp_services".into(), json!(services));
        }
    }
    // The server rejects clearing a pinned host or folder, so only new pins are sent.
    if let Some(host) = host {
        body.insert("host_id".into(), json!(host));
    }
    if let Some(workspace) = workspace {
        body.insert("workspace".into(), json!(workspace));
    }
    // A worktree needs a repository folder on a host; an edit sends a change, `null` clearing it.
    let base_branch = filled(draft.base_branch.as_ref()).filter(|_| workspace.is_some());
    if base_branch != saved.and_then(|saved| saved.base_branch.as_deref()) {
        body.insert("base_branch".into(), json!(base_branch));
    }
    match saved {
        None => create_fields(draft, &mut body),
        Some(saved) => edit_fields(draft, saved, &mut body),
    }
    Ok(Value::Object(body))
}

fn create_fields(draft: &AutomationDraft, body: &mut Map<String, Value>) {
    body.insert("agent_id".into(), json!(draft.agent_id));
    if let Some(continues) = draft.continues_session {
        body.insert("session_mode".into(), json!(session_mode(continues)));
    }
    if draft.runs_in_sandbox {
        body.insert("execution_target".into(), json!(MANAGED_SANDBOX));
    }
    if let Some(project) = filled(draft.project_id.as_ref()) {
        body.insert("project_id".into(), json!(project));
    }
    if let Some(source) = filled(draft.source_session_id.as_ref()) {
        body.insert("source_session_id".into(), json!(source));
    }
    if draft.sends_overrides {
        for (key, value) in overrides(draft) {
            if let Some(value) = value {
                body.insert(key.into(), json!(value));
            }
        }
    }
}

fn edit_fields(draft: &AutomationDraft, saved: &Automation, body: &mut Map<String, Value>) {
    // Sending the unchanged agent is a server no-op; leaving it out keeps the edit honest.
    if draft.agent_id != saved.agent_id {
        body.insert("agent_id".into(), json!(draft.agent_id));
    }
    if let Some(continues) = draft.continues_session
        && continues != saved.continues_session
    {
        body.insert("session_mode".into(), json!(session_mode(continues)));
    }
    if draft.runs_in_sandbox != saved.runs_in_sandbox {
        let target = if draft.runs_in_sandbox {
            MANAGED_SANDBOX
        } else {
            "connected_host"
        };
        body.insert("execution_target".into(), json!(target));
    }
    let project = filled(draft.project_id.as_ref());
    if project != saved.project_id.as_deref() {
        body.insert("project_id".into(), json!(project));
    }
    // Each override is sent, `null` clearing it, so Default really means the agent's.
    if draft.sends_overrides {
        for (key, value) in overrides(draft) {
            body.insert(key.into(), json!(value));
        }
    }
    let continues = draft.continues_session.unwrap_or(saved.continues_session);
    if continues && draft.start_new_session && saved.session_id.is_some() {
        body.insert("session_id".into(), Value::Null);
    }
}

fn overrides(draft: &AutomationDraft) -> [(&'static str, Option<&str>); 3] {
    [
        ("model_override", filled(draft.model_override.as_ref())),
        ("reasoning_effort", filled(draft.reasoning_effort.as_ref())),
        ("permission_mode", filled(draft.permission_mode.as_ref())),
    ]
}

fn run_from(value: &Value) -> Result<AutomationRun, String> {
    let object = as_object(value, "a run")?;
    let status = AutomationRunStatus::from_wire(&req_str(object, "status")?);
    let fired_at = opt_i64(object, "fired_at")?;
    let finished_at = opt_i64(object, "finished_at")?;
    let session_id = opt_str(object, "conversation_id")?;
    let error_code = opt_str(object, "error_code")?;
    let failure = matches!(
        status,
        AutomationRunStatus::Failed
            | AutomationRunStatus::Skipped
            | AutomationRunStatus::Incomplete
    )
    .then(|| describe_run_failure(error_code.as_deref(), &status));
    // The server's detail explains a failure; on another run it says nothing new.
    let error_detail = opt_str(object, "error_detail")?
        .filter(|detail| failure.is_some() && !detail.trim().is_empty());
    let (failure_stage, failure_reason) = match failure {
        Some((stage, reason)) => (stage.map(str::to_owned), Some(reason.to_owned())),
        None => (None, None),
    };
    let approvals = opt_u64(object, "conversation_pending_approvals")?.unwrap_or(0);
    // As the web's `isConversationUnread` with no local mark: the server's flag, or news since
    // the caller last looked once no turn is running.
    let updated_at = opt_i64(object, "conversation_updated_at")?;
    let last_seen = opt_i64(object, "viewer_last_seen")?;
    let session_status = opt_str(object, "conversation_status")?;
    let unread = session_id.is_some()
        && updated_at.is_some()
        && (opt_bool(object, "viewer_unread")?.unwrap_or(false)
            || (session_status
                .as_deref()
                .is_some_and(|status| status != "running")
                && last_seen
                    .zip(updated_at)
                    .is_some_and(|(seen, updated)| updated > seen)));
    Ok(AutomationRun {
        id: req_str(object, "id")?,
        started_at: fired_at
            .or(opt_i64(object, "scheduled_at")?)
            .unwrap_or_default(),
        duration: fired_at
            .zip(finished_at)
            .and_then(|(fired, finished)| format_run_duration(fired, finished)),
        session_cost: opt_number(object, "session_cost_usd")?
            .map(|cost| format!("Session cost {}", format_cost_usd(cost))),
        needs_approval: approvals > 0 && session_id.is_some(),
        session_running: status == AutomationRunStatus::Succeeded
            && session_id.is_some()
            && session_status.as_deref() == Some("running"),
        error_detail,
        session_id,
        failure_stage,
        failure_reason,
        unread,
        status,
    })
}

/// A run's length as the history shows it: `3s`, `1m 42s`, `2h 5m`; `None` when it ended
/// before it started. Under a second rounds up to `1s`.
#[must_use]
pub fn format_run_duration(fired_at: i64, finished_at: i64) -> Option<String> {
    let seconds = finished_at
        .checked_sub(fired_at)
        .filter(|&span| span >= 0)?;
    let total = seconds.max(1);
    let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60);
    Some(match (hours, minutes, rest) {
        (0, 0, seconds) => format!("{seconds}s"),
        (0, minutes, 0) => format!("{minutes}m"),
        (0, minutes, seconds) => format!("{minutes}m {seconds}s"),
        (hours, 0, _) => format!("{hours}h"),
        (hours, minutes, _) => format!("{hours}h {minutes}m"),
    })
}

/// Where a run stopped and why, from its `error_code` (`web/src/lib/scheduleText.ts`). An
/// unknown code still gets a reason worded from the status.
#[must_use]
pub fn describe_run_failure(
    error_code: Option<&str>,
    status: &AutomationRunStatus,
) -> (Option<&'static str>, &'static str) {
    const FIX: &str = "No host or workspace is set. Edit the automation to fix it.";
    let known = match error_code.unwrap_or_default() {
        "owner_deleted" => ("Owner", "The owner's account was removed."),
        "owner_identity_unavailable" => (
            "Owner",
            "Couldn't act as the owner. A recurring automation tries again at its next run.",
        ),
        "permission_harness_unresolved" => (
            "Permissions",
            "Couldn't load the agent's permission settings. Restore access to the agent and retry.",
        ),
        "permission_mode_unsupported" => (
            "Permissions",
            "The saved permission isn't supported by this agent. Edit the automation to change or clear it.",
        ),
        "reauthorization_required" => (
            "Owner",
            "The owner's authorization for this automation is no longer valid.",
        ),
        "invalid_input" => (
            "Settings",
            "The agent, model or workspace is invalid. Edit the automation to fix it.",
        ),
        "not_found" => (
            "Settings",
            "The agent or workspace no longer exists. Edit the automation to fix it.",
        ),
        "forbidden" => (
            "Settings",
            "You no longer have access to the agent or workspace.",
        ),
        "missing_host_id" | "missing_workspace" | "missing_execution_input" => ("Settings", FIX),
        "unsupported_target" => ("Settings", "This target can't run automatically."),
        "no_online_host" => ("Host", "None of your hosts was online."),
        "host_offline" => ("Host", "The host was offline."),
        "host_not_found" => ("Host", "The host no longer exists."),
        "host_not_owned" => ("Host", "The host isn't yours."),
        "host_authority_revoked" => ("Host", "The host was registered by another account."),
        "host_registry_unavailable" => ("Host", "The server couldn't look up hosts."),
        "existing_sandbox_not_allowed" => (
            "Host",
            "Automations can't use an existing sandbox. Choose a new sandbox for each run.",
        ),
        "default_workspace_unresolved" => ("Host", "Couldn't find the host's home directory."),
        "managed_sandbox_unavailable" => ("Sandbox", "This server has no sandboxes."),
        "session_create_failed" => ("Session", "Couldn't create the session."),
        "owner_grant_failed" => ("Session", "Couldn't give the owner access to the session."),
        "sandbox_create_failed" => ("Sandbox", "Couldn't create the sandbox."),
        "sandbox_registration_timeout" => ("Sandbox", "The sandbox didn't connect in time."),
        "runner_start_failed" => ("Runner", "The agent didn't start."),
        "launch_failed" => ("Launch", "The agent session failed to launch."),
        "startup_expired" => ("Startup", "The run stopped before the agent started."),
        "incomplete" => (
            "Running",
            "The agent stopped reporting before the run finished.",
        ),
        _ => {
            let reason = if *status == AutomationRunStatus::Skipped {
                "Run skipped."
            } else {
                "Run failed."
            };
            return (None, reason);
        }
    };
    (Some(known.0), known.1)
}

/// One person or group an automation or a saved workflow is shared with, at read access.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AutomationGrant {
    /// The grantee's id or email.
    pub user_id: String,
    /// Their name, as the server gives it.
    pub display_name: String,
}

/// The only level an automation or a saved workflow can be shared at: read.
const LEVEL_READ: u8 = 1;

/// The most grant pages read from one automation or workflow.
const MAX_GRANT_PAGES: usize = 10;

fn grant_from(value: &Value) -> Result<AutomationGrant, String> {
    let object = as_object(value, "permission")?;
    let user_id = req_str(object, "user_id")?;
    Ok(AutomationGrant {
        display_name: opt_str(object, "display_name")?
            .filter(|name| !name.trim().is_empty())
            .unwrap_or_else(|| user_id.clone()),
        user_id,
    })
}

/// The web's page of shared automations.
const SHARED_PAGE_SIZE: u32 = 50;

/// Runs read per page of PRs: the server's most.
const RUN_PULL_REQUEST_PAGE_SIZE: u32 = 50;

/// Pages of PRs read: as many runs as the history shows.
const RUN_PULL_REQUEST_PAGES: usize = 2;

fn run_pull_request_from(value: &Value) -> Result<RunPullRequest, String> {
    let object = as_object(value, "a pull request")?;
    let open = opt_str(object, "state")?.map(|state| state.to_uppercase());
    let status = match open.as_deref() {
        Some("MERGED") => RunPullRequestStatus::Merged,
        Some("CLOSED") => RunPullRequestStatus::Closed,
        Some("OPEN") if opt_bool(object, "is_draft")?.unwrap_or(false) => {
            RunPullRequestStatus::Draft
        }
        Some("OPEN") => RunPullRequestStatus::Open,
        _ => RunPullRequestStatus::Unknown,
    };
    let prefix = opt_object(object, "provider_display")?
        .map(|display| opt_str(display, "number_prefix"))
        .transpose()?
        .flatten()
        .unwrap_or_else(|| "#".to_owned());
    let number = opt_u64(object, "number")?.ok_or("`number` is missing")?;
    Ok(RunPullRequest {
        url: req_str(object, "url")?,
        repository: opt_str(object, "repository")?.unwrap_or_default(),
        number: format!("{prefix}{number}"),
        title: opt_str(object, "title")?.filter(|title| !title.trim().is_empty()),
        status,
        created_by_run: opt_str(object, "relationship")?.as_deref() == Some("created"),
    })
}

fn run_pull_requests_from(value: &Value) -> Result<RunPullRequests, String> {
    let object = as_object(value, "a run's pull requests")?;
    Ok(RunPullRequests {
        run_id: req_str(object, "run_id")?,
        pull_requests: opt_array(object, "pull_requests")?
            .into_iter()
            .flatten()
            .map(run_pull_request_from)
            .collect::<Result<_, _>>()?,
    })
}

fn malformed(path: &str) -> impl Fn(String) -> SessionError + '_ {
    move |detail| SessionError::MalformedResponse {
        detail: format!("{path}: {detail}"),
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// Which top-level pages the server offers (`GET /v1/info`).
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn server_pages(&self) -> Result<ServerPages, SessionError> {
        self.server_pages_and_branding()
            .await
            .map(|(pages, _)| pages)
    }

    /// [`Self::server_pages`] with the operator's branding from the same `/v1/info` read.
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn server_pages_and_branding(
        &self,
    ) -> Result<(ServerPages, Option<crate::branding::Branding>), SessionError> {
        let path = "/v1/info";
        let result = self.get_json(path, &[]).await;
        self.dispatch();
        let info = result?;
        let pages = ServerPages::from_value(&info).map_err(malformed(path))?;
        Ok((pages, crate::branding::Branding::from_info(&info)))
    }

    /// The caller's automations (`GET /v1/scheduled-tasks`), in the server's order.
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn automations(&self) -> Result<Vec<Automation>, SessionError> {
        let path = "/v1/scheduled-tasks";
        let result = self.get_json(path, &[]).await;
        self.dispatch();
        result?
            .get("scheduled_tasks")
            .and_then(Value::as_array)
            .ok_or_else(|| malformed(path)("no `scheduled_tasks` list".to_owned()))?
            .iter()
            .map(automation_from)
            .collect::<Result<_, _>>()
            .map_err(malformed(path))
    }

    /// Creates an automation (`POST /v1/scheduled-tasks`).
    ///
    /// # Errors
    ///
    /// `Rejected` for a draft without a name, prompt, agent or host (unless it runs in a
    /// sandbox), or with a folder but no host (no request is made), or one the server refuses (a
    /// bad rule, an unknown agent); the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_automation(
        &self,
        draft: &AutomationDraft,
    ) -> Result<Automation, SessionError> {
        let path = "/v1/scheduled-tasks";
        let result = match draft_body(draft, None) {
            Ok(body) => self.write_json("POST", path, &body).await,
            Err(error) => Err(error),
        };
        self.dispatch();
        automation_from(&result?).map_err(malformed(path))
    }

    /// Saves the edits of `saved` (`PATCH /v1/scheduled-tasks/{id}`), sending only what changed.
    ///
    /// # Errors
    ///
    /// As [`Self::create_automation`] (an unpinned automation may stay unpinned), plus
    /// `InvalidIdentifier`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn update_automation(
        &self,
        saved: &Automation,
        draft: &AutomationDraft,
    ) -> Result<Automation, SessionError> {
        let result = self
            .patch_automation(&saved.id, draft_body(draft, Some(saved)))
            .await;
        self.dispatch();
        result
    }

    /// An automation's runs, newest first (`GET /v1/scheduled-tasks/{id}/runs`).
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn automation_runs(&self, id: &str) -> Result<Vec<AutomationRun>, SessionError> {
        let result = match validate_identifier(id) {
            Ok(()) => {
                let path = format!("/v1/scheduled-tasks/{id}/runs");
                self.get_json(&path, &[]).await.map(|value| (path, value))
            }
            Err(error) => Err(error),
        };
        self.dispatch();
        let (path, value) = result?;
        value
            .get("runs")
            .and_then(Value::as_array)
            .ok_or_else(|| malformed(&path)("no `runs` list".to_owned()))?
            .iter()
            .map(run_from)
            .collect::<Result<_, _>>()
            .map_err(malformed(&path))
    }

    /// Pauses or resumes an automation.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn set_automation_paused(
        &self,
        id: &str,
        paused: bool,
    ) -> Result<Automation, SessionError> {
        let body = json!({"state": if paused { "paused" } else { "active" }});
        let result = self.patch_automation(id, Ok(body)).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn patch_automation(
        &self,
        id: &str,
        body: Result<Value, SessionError>,
    ) -> Result<Automation, SessionError> {
        validate_identifier(id)?;
        let path = format!("/v1/scheduled-tasks/{id}");
        let value = self.write_json("PATCH", &path, &body?).await?;
        automation_from(&value).map_err(malformed(&path))
    }

    /// Starts a run now (`POST /v1/scheduled-tasks/{id}/run`); the session appears in the list.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; `Rejected` (409) while a run is starting; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn run_automation(&self, id: &str) -> Result<(), SessionError> {
        self.start_automation_run(id).await.map(|_| ())
    }

    /// Starts a run now and returns its id (`run_id`), which the history then highlights;
    /// `None` from servers that don't say.
    ///
    /// # Errors
    ///
    /// As [`Self::run_automation`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn start_automation_run(&self, id: &str) -> Result<Option<String>, SessionError> {
        let result = async {
            validate_identifier(id)?;
            let path = format!("/v1/scheduled-tasks/{id}/run");
            let response = self.write(self.prepare("POST", &path, &[], None)?).await?;
            // An empty or unreadable acknowledgement still started the run.
            Ok(serde_json::from_slice::<Value>(&response.body)
                .ok()
                .and_then(|body| {
                    body.get("run_id")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                })
                .filter(|run| !run.is_empty()))
        }
        .await;
        self.dispatch();
        result
    }

    /// Deletes an automation; sessions it started stay.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn delete_automation(&self, id: &str) -> Result<(), SessionError> {
        let result = self.automation_write("DELETE", id, "").await;
        self.dispatch();
        result
    }

    /// Copies `automation` under a new id, named "<name> (copy)", with its settings and schedule
    /// and none of its runs (`POST /v1/scheduled-tasks/{id}/clone`, where `automation_clone`).
    /// The copy is paused when the original is. The original's host routes the request.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; `Rejected` when the caller doesn't own it or it is a reminder; the
    /// write errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn clone_automation(
        &self,
        automation: &Automation,
    ) -> Result<Automation, SessionError> {
        let result = async {
            validate_identifier(&automation.id)?;
            let path = format!("/v1/scheduled-tasks/{}/clone", automation.id);
            let body = filled(automation.host_id.as_ref())
                .map_or_else(|| json!({}), |host| json!({"host_id": host}));
            let value = self.write_json("POST", &path, &body).await?;
            automation_from(&value).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }

    /// Records `timezone` (IANA) as the zone the caller's agent-created automations run in
    /// (`PUT /v1/scheduled-tasks/default-timezone`, where `automation_default_timezone`).
    ///
    /// # Errors
    ///
    /// `Rejected` for an empty zone (no request is made) or one the server refuses (501 where
    /// the store keeps no preference); the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn report_automation_timezone(&self, timezone: &str) -> Result<(), SessionError> {
        let result = async {
            let zone = timezone.trim();
            if zone.is_empty() {
                return Err(SessionError::Rejected {
                    status: 400,
                    message: "This device reports no time zone.".to_owned(),
                });
            }
            let body = json!({"timezone": zone});
            self.write(self.prepare(
                "PUT",
                "/v1/scheduled-tasks/default-timezone",
                &[],
                Some(&body),
            )?)
            .await
            .map(|_| ())
        }
        .await;
        self.dispatch();
        result
    }

    /// Deletes the automation that runs from a session about to be deleted (the web's
    /// `useDeleteSourceAutomations`); one already gone counts as deleted.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the write errors other than 404, which keep the session.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn delete_source_automation(&self, id: &str) -> Result<(), SessionError> {
        let result = match self.automation_write("DELETE", id, "").await {
            Err(SessionError::Rejected { status: 404, .. }) => Ok(()),
            other => other,
        };
        self.dispatch();
        result
    }

    /// One page of the automations other users shared with the caller
    /// (`GET /v1/scheduled-tasks/shared`), after `after`'s cursor.
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn shared_automations(
        &self,
        after: Option<&str>,
    ) -> Result<SharedAutomationsPage, SessionError> {
        let path = "/v1/scheduled-tasks/shared";
        let mut query = vec![("limit", SHARED_PAGE_SIZE.to_string())];
        if let Some(after) = after {
            query.push(("after", after.to_owned()));
        }
        let result = self.get_json(path, &query).await;
        self.dispatch();
        let value = result?;
        let decode = || -> Result<SharedAutomationsPage, String> {
            let object = as_object(&value, path)?;
            let automations = opt_array(object, "scheduled_tasks")?
                .map(|rows| rows.iter().map(automation_from).collect::<Result<Vec<_>, _>>())
                .transpose()?
                .unwrap_or_default()
                .into_iter()
                // The list holds other users' automations, whatever an older row says.
                .map(|automation| Automation {
                    shared_with_me: true,
                    ..automation
                })
                .collect();
            Ok(SharedAutomationsPage {
                automations,
                next_cursor: opt_str(object, "next_cursor")?,
            })
        };
        decode().map_err(malformed(path))
    }

    /// The PRs the newest runs of `id` created or worked on
    /// (`GET /v1/scheduled-tasks/{id}/run-pull-requests`), two pages of 50 runs at most.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn automation_run_pull_requests(
        &self,
        id: &str,
    ) -> Result<Vec<RunPullRequests>, SessionError> {
        let result = async {
            validate_identifier(id)?;
            let path = format!("/v1/scheduled-tasks/{id}/run-pull-requests");
            let mut runs = Vec::new();
            let mut after: Option<String> = None;
            for _ in 0..RUN_PULL_REQUEST_PAGES {
                let mut query = vec![("limit", RUN_PULL_REQUEST_PAGE_SIZE.to_string())];
                if let Some(cursor) = &after {
                    query.push(("after", cursor.clone()));
                }
                let value = self.get_json(&path, &query).await?;
                let object = as_object(&value, &path).map_err(malformed(&path))?;
                for row in opt_array(object, "runs")
                    .map_err(malformed(&path))?
                    .into_iter()
                    .flatten()
                {
                    runs.push(run_pull_requests_from(row).map_err(malformed(&path))?);
                }
                match opt_str(object, "next_cursor").map_err(malformed(&path))? {
                    Some(cursor) if after.as_deref() != Some(cursor.as_str()) => {
                        after = Some(cursor);
                    }
                    _ => break,
                }
            }
            Ok(runs)
        }
        .await;
        self.dispatch();
        result
    }

    /// Everyone automation `id` is shared with (`GET /v1/scheduled-tasks/{id}/permissions`),
    /// following `next_cursor`; only its owner may list them. The owner isn't listed.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the read errors; [`SessionError::MalformedResponse`] and
    /// [`SessionError::InvalidPagination`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn automation_grants(&self, id: &str) -> Result<Vec<AutomationGrant>, SessionError> {
        let result = async {
            validate_identifier(id)?;
            self.read_grants(&format!("/v1/scheduled-tasks/{id}/permissions"))
                .await
        }
        .await;
        self.dispatch();
        result
    }

    /// The read-access grants at `path`, a resource's `permissions`, following `next_cursor`.
    /// The owner's own grant isn't listed.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn read_grants(
        &self,
        path: &str,
    ) -> Result<Vec<AutomationGrant>, SessionError> {
        let mut grants = Vec::new();
        let mut cursors = std::collections::BTreeSet::new();
        let mut after: Option<String> = None;
        for _ in 0..MAX_GRANT_PAGES {
            let query: Vec<(&str, String)> = after
                .iter()
                .map(|cursor| ("after", cursor.clone()))
                .collect();
            let value = self.get_json(path, &query).await?;
            let object = as_object(&value, path).map_err(malformed(path))?;
            for row in opt_array(object, "permissions")
                .map_err(malformed(path))?
                .ok_or_else(|| malformed(path)("`permissions` is missing".into()))?
            {
                let level = as_object(row, "permission")
                    .and_then(|grant| opt_u64(grant, "level"))
                    .map_err(malformed(path))?;
                // The owner's own grant can't be changed here.
                if level.is_some_and(|level| level >= 4) {
                    continue;
                }
                grants.push(grant_from(row).map_err(malformed(path))?);
            }
            match opt_str(object, "next_cursor").map_err(malformed(path))? {
                None => return Ok(grants),
                Some(cursor) if cursors.insert(cursor.clone()) => after = Some(cursor),
                Some(_) => return Err(SessionError::InvalidPagination),
            }
        }
        Ok(grants)
    }

    /// Shares automation `id` with `user_id` at read access, as the web's dialog does; its
    /// runs' sessions follow. Never retried.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request, and the write errors: `Rejected` with the
    /// server's reason (the owner, the public, a sharing policy), `Forbidden`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn grant_automation_access(
        &self,
        id: &str,
        user_id: &str,
    ) -> Result<(), SessionError> {
        let result = async {
            validate_identifier(id)?;
            self.grant_read_access(&format!("/v1/scheduled-tasks/{id}/permissions"), user_id)
                .await
        }
        .await;
        self.dispatch();
        result
    }

    /// Grants `user_id` read access at `path`, a resource's `permissions`. Never retried.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn grant_read_access(
        &self,
        path: &str,
        user_id: &str,
    ) -> Result<(), SessionError> {
        super::share::validate_grantee(user_id)?;
        let body = json!({"user_id": user_id.trim(), "level": LEVEL_READ});
        self.write_json("PUT", path, &body).await.map(|_| ())
    }

    /// Stops sharing automation `id` with `user_id`. Never retried.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request, and the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn revoke_automation_access(
        &self,
        id: &str,
        user_id: &str,
    ) -> Result<(), SessionError> {
        let result = async {
            validate_identifier(id)?;
            self.revoke_access(&format!("/v1/scheduled-tasks/{id}/permissions"), user_id)
                .await
        }
        .await;
        self.dispatch();
        result
    }

    /// Removes `user_id`'s grant at `path`, a resource's `permissions`. Never retried.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn revoke_access(
        &self,
        path: &str,
        user_id: &str,
    ) -> Result<(), SessionError> {
        super::share::validate_grantee(user_id)?;
        let path = format!("{path}/{}", user_id.trim());
        self.write(self.prepare("DELETE", &path, &[], None)?)
            .await
            .map(|_| ())
    }

    /// The hosts that deliver long session messages (`long_session_messages_supported` in
    /// `GET /v1/hosts`), so a trigger polling there gets the full budget.
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn long_message_hosts(&self) -> Result<Vec<String>, SessionError> {
        let path = "/v1/hosts";
        let result = self.host_rows().await;
        self.dispatch();
        let mut hosts = Vec::new();
        for row in &result? {
            let object = as_object(row, "host").map_err(malformed(path))?;
            if opt_bool(object, "long_session_messages_supported")
                .map_err(malformed(path))?
                .unwrap_or(false)
            {
                hosts.push(req_str(object, "host_id").map_err(malformed(path))?);
            }
        }
        Ok(hosts)
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn automation_write(
        &self,
        method: &str,
        id: &str,
        suffix: &str,
    ) -> Result<(), SessionError> {
        validate_identifier(id)?;
        let path = format!("/v1/scheduled-tasks/{id}{suffix}");
        self.write(self.prepare(method, &path, &[], None)?).await?;
        Ok(())
    }
}

#[cfg(test)]
#[path = "automations_tests.rs"]
mod tests;
