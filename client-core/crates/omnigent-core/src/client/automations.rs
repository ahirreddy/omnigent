//! The caller's automations (scheduled tasks): `/v1/scheduled-tasks` lists, creates, edits,
//! pauses, runs and deletes them. Servers advertise them with `automations_enabled` in
//! `/v1/info`.

use serde_json::{Map, Value, json};

use super::json::{as_object, opt_bool, opt_object, opt_str, req_str};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;
use crate::schedule::{describe_schedule, parse_iso8601};

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
        Ok(Self {
            automations: opt_bool(object, "automations_enabled")?.unwrap_or(false),
            automation_session_modes: session_modes,
            usage: feature("usage_page")?,
            automations_v2: feature("automations_v2")?,
            automation_projects: opt_bool(object, "scheduled_task_projects")?.unwrap_or(false),
            managed_sandboxes: opt_bool(object, "managed_sandboxes_enabled")?.unwrap_or(false),
            automation_triggers: session_modes && feature("session_orchestration")?,
            archive_worktree_cleanup: opt_bool(object, "archive_worktree_cleanup")?
                .unwrap_or(false),
            sharing: !opt_bool(object, "single_user")?.unwrap_or(false)
                && opt_str(object, "sharing_mode")?.as_deref() != Some("off"),
            canvas: feature("canvas")?,
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
    /// Each run starts in a new managed sandbox (`execution_target` `managed_sandbox`).
    pub runs_in_sandbox: bool,
    /// The project every run's session is filed into.
    pub project_id: Option<String>,
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

/// `automations` matching `filter` and `search` (name, case-insensitive), in the web's order:
/// active first with the soonest next run on top (unknown next runs after), then paused by name.
#[must_use]
pub fn arrange_automations(
    automations: &[Automation],
    filter: AutomationFilter,
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
    Ok(Automation {
        id: req_str(object, "id")?,
        name: req_str(object, "name")?,
        prompt: opt_str(object, "prompt")?.unwrap_or_default(),
        schedule_text: describe_schedule(&rrule),
        rrule,
        agent_id: opt_str(object, "agent_id")?.unwrap_or_default(),
        timezone: opt_str(object, "timezone")?.unwrap_or_else(|| "UTC".to_owned()),
        continues_session: opt_str(object, "session_mode")?.as_deref() == Some("continue"),
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
    if name.is_empty() || draft.prompt.trim().is_empty() || draft.agent_id.is_empty() {
        return Err(rejected(
            "Give the automation a name, a prompt and an agent.",
        ));
    }
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
    body.insert("prompt".into(), json!(draft.prompt.trim()));
    body.insert("rrule".into(), json!(draft.rrule));
    body.insert("timezone".into(), json!(draft.timezone));
    // The server rejects clearing a pinned host or folder, so only new pins are sent.
    if let Some(host) = host {
        body.insert("host_id".into(), json!(host));
    }
    if let Some(workspace) = workspace {
        body.insert("workspace".into(), json!(workspace));
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
    let (failure_stage, failure_reason) = match failure {
        Some((stage, reason)) => (stage.map(str::to_owned), Some(reason.to_owned())),
        None => (None, None),
    };
    // As the web's `isConversationUnread` with no local mark: the server's flag, or news since
    // the caller last looked once no turn is running.
    let updated_at = opt_i64(object, "conversation_updated_at")?;
    let last_seen = opt_i64(object, "viewer_last_seen")?;
    let session_status = opt_str(object, "conversation_status")?;
    let unread = session_id.is_some()
        && updated_at.is_some()
        && (opt_bool(object, "viewer_unread")?.unwrap_or(false)
            || (session_status.is_some_and(|status| status != "running")
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
            "Couldn't act as the owner. The next run tries again.",
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
        let path = "/v1/info";
        let result = self.get_json(path, &[]).await;
        self.dispatch();
        ServerPages::from_value(&result?).map_err(malformed(path))
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
        let result = self.automation_write("POST", id, "/run").await;
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
