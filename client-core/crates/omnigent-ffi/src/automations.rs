//! Automations (scheduled tasks) and their schedules. The rules are `omnigent_core::schedule`'s;
//! the REST calls are `omnigent_core::automations`'.

use omnigent_core::automations as core;
use omnigent_core::schedule as rules;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// The top-level pages the server offers. Missing fields mean unsupported.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ServerPages {
    /// The Automations page.
    pub automations: bool,
    /// An automation can continue one session across runs.
    pub automation_session_modes: bool,
    /// The Usage page.
    pub usage: bool,
    /// Archiving can also remove a session's git worktree.
    #[uniffi(default)]
    pub archive_worktree_cleanup: bool,
    /// Sessions can be shared with other users.
    #[uniffi(default)]
    pub sharing: bool,
    /// A multi-user server turned sharing off: Share shows disabled with the reason.
    #[uniffi(default)]
    pub sharing_disabled: bool,
    /// The Canvas page.
    #[uniffi(default)]
    pub canvas: bool,
    /// Custom schedules, run-count endings and the run history page (`automations_v2`).
    #[uniffi(default)]
    pub automations_v2: bool,
    /// An automation can file its sessions into a project.
    #[uniffi(default)]
    pub automation_projects: bool,
    /// An automation can run in a new sandbox each time.
    #[uniffi(default)]
    pub managed_sandboxes: bool,
    /// The Jira, Slack and GitHub trigger templates.
    #[uniffi(default)]
    pub automation_triggers: bool,
    /// The caller can add nested agents to a session family (`sibling_sessions`).
    #[uniffi(default)]
    pub sibling_sessions: bool,
    /// An owned session moves into another nest or out of its own (`session_nest_moves`).
    #[uniffi(default)]
    pub session_nest_moves: bool,
    /// Where a nested agent may start (`sibling_session_destinations`). The core always sets
    /// it; `nil` (a record built without it) reads as `.anyHost`.
    #[uniffi(default)]
    pub sibling_session_destinations: Option<crate::sessions::SiblingSessionDestinations>,
    /// Agents post items to the caller's Inbox (`inbox_items_available`).
    #[uniffi(default)]
    pub inbox_items: bool,
    /// The Inbox lists automation failures that made no session (`scheduled_task_inbox`).
    #[uniffi(default)]
    pub automation_inbox: bool,
    /// A session can be opened to anyone with the link (`public_sharing_enabled`).
    #[uniffi(default = true)]
    pub public_sharing: bool,
    /// Grants are Read only (`sharing_mode` `read_only` or `restricted_read_only`).
    #[uniffi(default)]
    pub sharing_read_only: bool,
    /// Home and root folders are not shared (`sharing_mode` `restricted_read_only`).
    #[uniffi(default)]
    pub sharing_restricted: bool,
    /// New project can start from a repository (`project_repository_creation`).
    #[uniffi(default)]
    pub project_repository_creation: bool,
    /// A project opens its sessions board (`project_kanban`).
    #[uniffi(default)]
    pub project_kanban: bool,
    /// Hosts and continued sessions run schedules under an hour (`scheduled_task_subhour`).
    #[uniffi(default)]
    pub automation_subhour: bool,
    /// Runs drop a trigger prompt's header before dispatch, so triggers save one.
    #[uniffi(default)]
    pub automation_trigger_headers: bool,
    /// How often a trigger checks its service, in minutes.
    #[uniffi(default = 10)]
    pub automation_trigger_poll_minutes: u32,
    /// The longest message the server delivers; 0 on older servers (8,000 characters).
    #[uniffi(default)]
    pub session_message_max_chars: u32,
    /// Runs can start with MCP services.
    #[uniffi(default)]
    pub automation_mcp_services: bool,
    /// An automation can start each run from a copy of a session.
    #[uniffi(default)]
    pub automation_source_sessions: bool,
    /// Automations can be shared.
    #[uniffi(default)]
    pub automation_sharing: bool,
    /// The Shared with me list.
    #[uniffi(default)]
    pub automation_shared_with_me: bool,
    /// The PRs each run created or worked on.
    #[uniffi(default)]
    pub automation_run_pull_requests: bool,
    /// Every native harness takes a permission mode.
    #[uniffi(default)]
    pub automation_harness_settings: bool,
    /// Modes that skip approval are accepted.
    #[uniffi(default)]
    pub automation_approval_skipping_modes: bool,
    /// A trigger's workers can take a permission mode.
    #[uniffi(default)]
    pub session_create_permission_modes: bool,
}

/// Whether an automation fires.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AutomationState {
    /// It fires on schedule.
    Active,
    /// It does not fire.
    Paused,
    /// A state this app does not know; shown as it is.
    Unknown {
        /// The server's value.
        value: String,
    },
}

/// One automation.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
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
    /// Every run continues one session.
    pub continues_session: bool,
    /// Active or paused.
    pub state: AutomationState,
    /// The server's next fire, Unix seconds; `None` when paused.
    pub next_run_at: Option<i64>,
    /// The last fire, Unix seconds.
    pub last_run_at: Option<i64>,
    /// The latest run's status.
    pub last_run_status: Option<String>,
    /// The latest run's session.
    pub last_run_session_id: Option<String>,
    /// Last edit, Unix seconds.
    pub updated_at: i64,
    /// The model each run uses instead of the agent's.
    #[uniffi(default)]
    pub model_override: Option<String>,
    /// The reasoning effort each run uses instead of the agent's.
    #[uniffi(default)]
    pub reasoning_effort: Option<String>,
    /// The permission mode each run launches in instead of the agent's.
    #[uniffi(default)]
    pub permission_mode: Option<String>,
    /// The session a continuing automation sends to.
    #[uniffi(default)]
    pub session_id: Option<String>,
    /// The pinned host; `None` runs on the host used most recently.
    #[uniffi(default)]
    pub host_id: Option<String>,
    /// The pinned folder; `None` is the host's home.
    #[uniffi(default)]
    pub workspace: Option<String>,
    /// Each run starts in a new managed sandbox.
    #[uniffi(default)]
    pub runs_in_sandbox: bool,
    /// The project every run's session is filed into.
    #[uniffi(default)]
    pub project_id: Option<String>,
    /// It runs when new items match a trigger, not on its schedule.
    #[uniffi(default)]
    pub is_trigger: bool,
    /// The MCP services every run starts with.
    #[uniffi(default)]
    pub mcp_services: Vec<String>,
    /// The cost limit per run in USD as decimal text; `None` is no limit.
    #[uniffi(default)]
    pub max_cost_usd: Option<String>,
    /// The session copy every run starts from.
    #[uniffi(default)]
    pub source_session_id: Option<String>,
    /// Someone else shared it with the caller, who may only read it.
    #[uniffi(default)]
    pub shared_with_me: bool,
    /// Whose it is, for a shared one.
    #[uniffi(default)]
    pub owner_name: String,
    /// The server can keep grants for it; `false` for a legacy one.
    #[uniffi(default = true)]
    pub shareable: bool,
}

/// What one run of an automation did.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
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
    /// A status this app does not know.
    Unknown {
        /// The server's value.
        value: String,
    },
}

/// One run in an automation's history.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AutomationRun {
    /// Id.
    pub id: String,
    /// What it did.
    pub status: AutomationRunStatus,
    /// `Queued`, `Starting` or `Running` while it has not finished.
    pub in_flight_label: Option<String>,
    /// When it fired, else when it was due, Unix seconds.
    pub started_at: i64,
    /// How long it ran (`1m 42s`), once it finished.
    pub duration: Option<String>,
    /// The session it started or continued.
    pub session_id: Option<String>,
    /// Where it stopped (`Host`).
    pub failure_stage: Option<String>,
    /// Why it did not succeed.
    pub failure_reason: Option<String>,
    /// Its session has news the caller has not seen.
    pub unread: bool,
    /// "Session cost $1.23".
    #[uniffi(default)]
    pub session_cost: Option<String>,
    /// Its session waits on an approval or a question.
    #[uniffi(default)]
    pub needs_approval: bool,
    /// The server's description of the failure.
    #[uniffi(default)]
    pub error_detail: Option<String>,
    /// It succeeded but its session is still working.
    #[uniffi(default)]
    pub session_running: bool,
}

/// A page of the automations shared with the caller.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SharedAutomationsPage {
    /// The page, each read-only.
    pub automations: Vec<Automation>,
    /// The next page's cursor.
    pub next_cursor: Option<String>,
}

/// A PR's state as its host last fetched it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
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

/// One PR a run created or worked on.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RunPullRequest {
    /// Its page.
    pub url: String,
    /// `owner/repo`.
    pub repository: String,
    /// `#212`.
    pub number: String,
    /// Title, when known.
    pub title: Option<String>,
    /// Its state.
    pub status: RunPullRequestStatus,
    /// "Open", "Closed without merging".
    pub status_label: String,
    /// The run opened it, rather than worked on it.
    pub created_by_run: bool,
}

/// The PRs one run created or worked on.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RunPullRequests {
    /// The run.
    pub run_id: String,
    /// Its PRs.
    pub pull_requests: Vec<RunPullRequest>,
    /// "PR #212 merged", "PRs: 2 merged, 1 closed".
    pub summary: String,
}

impl From<core::RunPullRequests> for RunPullRequests {
    fn from(run: core::RunPullRequests) -> Self {
        use core::RunPullRequestStatus as Status;
        Self {
            summary: core::run_pull_requests_summary(&run.pull_requests),
            run_id: run.run_id,
            pull_requests: run
                .pull_requests
                .into_iter()
                .map(|pr| RunPullRequest {
                    status_label: pr.status.label().to_owned(),
                    status: match pr.status {
                        Status::Open => RunPullRequestStatus::Open,
                        Status::Draft => RunPullRequestStatus::Draft,
                        Status::Merged => RunPullRequestStatus::Merged,
                        Status::Closed => RunPullRequestStatus::Closed,
                        Status::Unknown => RunPullRequestStatus::Unknown,
                    },
                    url: pr.url,
                    repository: pr.repository,
                    number: pr.number,
                    title: pr.title,
                    created_by_run: pr.created_by_run,
                })
                .collect(),
        }
    }
}

/// One person or group an automation is shared with, at read access.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AutomationGrant {
    /// The grantee's id or email.
    pub user_id: String,
    /// Their name.
    pub display_name: String,
}

impl From<core::AutomationRun> for AutomationRun {
    fn from(run: core::AutomationRun) -> Self {
        use core::AutomationRunStatus as Status;
        Self {
            id: run.id,
            in_flight_label: run.status.in_flight_label().map(str::to_owned),
            status: match run.status {
                Status::Scheduled => AutomationRunStatus::Scheduled,
                Status::Starting => AutomationRunStatus::Starting,
                Status::Running => AutomationRunStatus::Running,
                Status::Succeeded => AutomationRunStatus::Succeeded,
                Status::Failed => AutomationRunStatus::Failed,
                Status::Skipped => AutomationRunStatus::Skipped,
                Status::Incomplete => AutomationRunStatus::Incomplete,
                Status::Unknown { value } => AutomationRunStatus::Unknown { value },
            },
            started_at: run.started_at,
            duration: run.duration,
            session_id: run.session_id,
            failure_stage: run.failure_stage,
            failure_reason: run.failure_reason,
            unread: run.unread,
            session_cost: run.session_cost,
            needs_approval: run.needs_approval,
            error_detail: run.error_detail,
            session_running: run.session_running,
        }
    }
}

/// What the automation editor saves. On create, `None` fields are left out; an edit sends what
/// differs from the saved automation.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
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
    /// IANA zone.
    pub timezone: String,
    /// Continue one session across runs; `None` on servers without session modes.
    pub continues_session: Option<bool>,
    /// The pinned host; required on create unless it runs in a sandbox.
    #[uniffi(default)]
    pub host_id: Option<String>,
    /// The pinned folder on the host; `None` or blank is its home.
    #[uniffi(default)]
    pub workspace: Option<String>,
    /// Run each time in a new managed sandbox.
    #[uniffi(default)]
    pub runs_in_sandbox: bool,
    /// The project to file sessions into.
    #[uniffi(default)]
    pub project_id: Option<String>,
    /// The agent takes the model, effort and permission overrides (Claude Code).
    #[uniffi(default)]
    pub sends_overrides: bool,
    /// The model; `None` is the agent's.
    #[uniffi(default)]
    pub model_override: Option<String>,
    /// The reasoning effort; `None` is the agent's.
    #[uniffi(default)]
    pub reasoning_effort: Option<String>,
    /// The permission mode; `None` is the agent's.
    #[uniffi(default)]
    pub permission_mode: Option<String>,
    /// A continuing automation's next run starts a new session.
    #[uniffi(default)]
    pub start_new_session: bool,
    /// The MCP services every run starts with; `None` leaves them as they are.
    #[uniffi(default)]
    pub mcp_services: Option<Vec<String>>,
    /// The cost limit per run in USD as typed; blank is no limit.
    #[uniffi(default)]
    pub max_cost_usd: String,
    /// Create it from this session: each run starts from a copy of it.
    #[uniffi(default)]
    pub source_session_id: Option<String>,
}

/// When a schedule stops firing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ScheduleEnd {
    /// It never ends.
    Never,
    /// After this many runs, 2 or more.
    Count {
        /// Runs.
        count: u32,
    },
    /// At this instant, Unix seconds.
    Until {
        /// Unix seconds.
        at: i64,
    },
}

impl From<ScheduleEnd> for rules::ScheduleEnd {
    fn from(end: ScheduleEnd) -> Self {
        match end {
            ScheduleEnd::Never => Self::Never,
            ScheduleEnd::Count { count } => Self::Count(count),
            ScheduleEnd::Until { at } => Self::Until(at),
        }
    }
}

impl From<rules::ScheduleEnd> for ScheduleEnd {
    fn from(end: rules::ScheduleEnd) -> Self {
        match end {
            rules::ScheduleEnd::Never => Self::Never,
            rules::ScheduleEnd::Count(count) => Self::Count { count },
            rules::ScheduleEnd::Until(at) => Self::Until { at },
        }
    }
}

/// The automations page filter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AutomationFilter {
    /// Every automation.
    All,
    /// Active ones.
    Active,
    /// Paused ones.
    Paused,
}

/// A day of the week.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum Weekday {
    /// Monday.
    Monday,
    /// Tuesday.
    Tuesday,
    /// Wednesday.
    Wednesday,
    /// Thursday.
    Thursday,
    /// Friday.
    Friday,
    /// Saturday.
    Saturday,
    /// Sunday.
    Sunday,
}

/// The schedule picker's choice.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SchedulePreset {
    /// Every hour.
    Hourly,
    /// Every day.
    Daily,
    /// Monday to Friday.
    Weekdays,
    /// Chosen weekdays.
    Weekly,
    /// Any frequency with an interval.
    Custom,
}

/// A custom schedule's unit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ScheduleFrequency {
    /// Minutes: Interval schedules and trigger polling.
    Minutely,
    /// Hours.
    Hourly,
    /// Days.
    Daily,
    /// Weeks.
    Weekly,
    /// Months.
    Monthly,
    /// Years.
    Yearly,
}

/// What the schedule editor holds.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ScheduleModel {
    /// The picker's choice.
    pub preset: SchedulePreset,
    /// Hour, 0-23.
    pub hour: u8,
    /// Minute, 0-59.
    pub minute: u8,
    /// Weekly days.
    pub weekdays: Vec<Weekday>,
    /// A custom schedule's unit.
    pub frequency: ScheduleFrequency,
    /// A custom schedule's interval.
    pub interval: u16,
    /// Monthly and yearly days of the month.
    pub month_days: Vec<u16>,
    /// The yearly month, 1-12.
    pub month: u8,
    /// When it stops.
    pub end: ScheduleEnd,
}

macro_rules! mirror_enum {
    ($ffi:ident, $core:path, [$($case:ident),+]) => {
        impl From<$ffi> for $core {
            fn from(value: $ffi) -> Self {
                match value { $($ffi::$case => Self::$case),+ }
            }
        }
        impl From<$core> for $ffi {
            fn from(value: $core) -> Self {
                match value { $(<$core>::$case => Self::$case),+ }
            }
        }
    };
}

mirror_enum!(
    Weekday,
    rules::Weekday,
    [
        Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday
    ]
);
mirror_enum!(
    SchedulePreset,
    rules::SchedulePreset,
    [Hourly, Daily, Weekdays, Weekly, Custom]
);
mirror_enum!(
    ScheduleFrequency,
    rules::ScheduleFrequency,
    [Minutely, Hourly, Daily, Weekly, Monthly, Yearly]
);
mirror_enum!(
    AutomationFilter,
    core::AutomationFilter,
    [All, Active, Paused]
);

impl From<ScheduleModel> for rules::ScheduleModel {
    fn from(model: ScheduleModel) -> Self {
        Self {
            preset: model.preset.into(),
            hour: model.hour,
            minute: model.minute,
            weekdays: model.weekdays.into_iter().map(Into::into).collect(),
            frequency: model.frequency.into(),
            interval: model.interval,
            month_days: model
                .month_days
                .into_iter()
                .filter_map(|day| u8::try_from(day).ok())
                .collect(),
            month: model.month,
            end: model.end.into(),
        }
    }
}

impl From<rules::ScheduleModel> for ScheduleModel {
    fn from(model: rules::ScheduleModel) -> Self {
        Self {
            preset: model.preset.into(),
            hour: model.hour,
            minute: model.minute,
            weekdays: model.weekdays.into_iter().map(Into::into).collect(),
            frequency: model.frequency.into(),
            interval: model.interval,
            month_days: model.month_days.into_iter().map(u16::from).collect(),
            month: model.month,
            end: model.end.into(),
        }
    }
}

/// Builds `Self` from `$source`, moving the fields both automation records share.
macro_rules! automation_record {
    ($source:ident, $state:expr) => {
        Self {
            state: $state,
            id: $source.id,
            name: $source.name,
            prompt: $source.prompt,
            rrule: $source.rrule,
            schedule_text: $source.schedule_text,
            agent_id: $source.agent_id,
            timezone: $source.timezone,
            continues_session: $source.continues_session,
            next_run_at: $source.next_run_at,
            last_run_at: $source.last_run_at,
            last_run_status: $source.last_run_status,
            last_run_session_id: $source.last_run_session_id,
            updated_at: $source.updated_at,
            model_override: $source.model_override,
            reasoning_effort: $source.reasoning_effort,
            permission_mode: $source.permission_mode,
            session_id: $source.session_id,
            host_id: $source.host_id,
            workspace: $source.workspace,
            runs_in_sandbox: $source.runs_in_sandbox,
            project_id: $source.project_id,
            is_trigger: $source.is_trigger,
            mcp_services: $source.mcp_services,
            max_cost_usd: $source.max_cost_usd,
            source_session_id: $source.source_session_id,
            shared_with_me: $source.shared_with_me,
            owner_name: $source.owner_name,
            shareable: $source.shareable,
        }
    };
}

impl From<core::Automation> for Automation {
    fn from(automation: core::Automation) -> Self {
        let state = match automation.state {
            core::AutomationState::Active => AutomationState::Active,
            core::AutomationState::Paused => AutomationState::Paused,
            core::AutomationState::Unknown { value } => AutomationState::Unknown { value },
        };
        automation_record!(automation, state)
    }
}

impl From<Automation> for core::Automation {
    fn from(automation: Automation) -> Self {
        let state = match automation.state {
            AutomationState::Active => core::AutomationState::Active,
            AutomationState::Paused => core::AutomationState::Paused,
            AutomationState::Unknown { value } => core::AutomationState::Unknown { value },
        };
        automation_record!(automation, state)
    }
}

impl From<AutomationDraft> for core::AutomationDraft {
    fn from(draft: AutomationDraft) -> Self {
        Self {
            name: draft.name,
            prompt: draft.prompt,
            rrule: draft.rrule,
            agent_id: draft.agent_id,
            timezone: draft.timezone,
            continues_session: draft.continues_session,
            host_id: draft.host_id,
            workspace: draft.workspace,
            runs_in_sandbox: draft.runs_in_sandbox,
            project_id: draft.project_id,
            sends_overrides: draft.sends_overrides,
            model_override: draft.model_override,
            reasoning_effort: draft.reasoning_effort,
            permission_mode: draft.permission_mode,
            start_new_session: draft.start_new_session,
            mcp_services: draft.mcp_services,
            max_cost_usd: draft.max_cost_usd,
            source_session_id: draft.source_session_id,
        }
    }
}

/// Why an automation's offered Share shows disabled, or `None` while it works: sharing off
/// wins over a legacy automation the server can't keep grants for.
#[must_use]
#[uniffi::export]
pub fn automation_share_disabled_reason(sharing_disabled: bool, shareable: bool) -> Option<String> {
    core::automation_share_disabled_reason(sharing_disabled, shareable).map(str::to_owned)
}

/// Why the cost limit typed into the editor can't be saved, or `None`.
#[must_use]
#[uniffi::export]
pub fn cost_limit_problem(text: String) -> Option<String> {
    core::parse_cost_limit(&text).err()
}

/// A cost limit as the page shows it: `$5.00`, or "No limit" for `None` or unreadable text.
#[must_use]
#[uniffi::export]
pub fn describe_cost_limit(max_cost_usd: Option<String>) -> String {
    max_cost_usd
        .and_then(|text| text.parse::<f64>().ok())
        .map_or_else(|| "No limit".to_owned(), core::format_cost_usd)
}

/// What decides how short a minute schedule may be.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ScheduleLimits {
    /// The server runs schedules under an hour (`scheduled_task_subhour`).
    pub subhour_supported: bool,
    /// Every run continues one session.
    pub continues_session: bool,
    /// Runs go to a connected host rather than a new sandbox.
    pub on_connected_host: bool,
}

impl From<ScheduleLimits> for rules::ScheduleLimits {
    fn from(limits: ScheduleLimits) -> Self {
        Self {
            subhour_supported: limits.subhour_supported,
            continues_session: limits.continues_session,
            on_connected_host: limits.on_connected_host,
        }
    }
}

/// Why the editor cannot save `model`, or `None`. `now` is Unix seconds; an unchanged schedule
/// may keep an end in the past; `limits` bound minute intervals.
#[must_use]
#[uniffi::export]
pub fn validate_schedule(
    model: ScheduleModel,
    now: i64,
    allow_past_end: bool,
    limits: ScheduleLimits,
) -> Option<String> {
    rules::validate_schedule(&model.into(), now, allow_past_end, limits.into())
}

/// The smallest interval `frequency` allows: 1, or 10 or 60 minutes.
#[must_use]
#[uniffi::export]
pub fn minimum_schedule_interval(frequency: ScheduleFrequency, limits: ScheduleLimits) -> u16 {
    rules::minimum_schedule_interval(frequency.into(), limits.into())
}

/// The largest interval `frequency` allows: 366, or 366 days in minutes.
#[must_use]
#[uniffi::export]
pub fn maximum_schedule_interval(frequency: ScheduleFrequency) -> u16 {
    rules::maximum_schedule_interval(frequency.into())
}

/// Whether `model` needs a server with `automations_v2`: custom schedules and run-count endings.
#[must_use]
#[uniffi::export]
pub fn schedule_needs_anchored_scheduling(model: ScheduleModel) -> bool {
    rules::needs_anchored_scheduling(&model.into())
}

/// `automations` filtered and in the page's order: active soonest first, then paused by name.
#[must_use]
#[uniffi::export]
pub fn arrange_automations(
    automations: Vec<Automation>,
    filter: AutomationFilter,
    search: String,
) -> Vec<Automation> {
    let core: Vec<core::Automation> = automations.into_iter().map(Into::into).collect();
    core::arrange_automations(&core, filter.into(), &search)
        .into_iter()
        .map(Into::into)
        .collect()
}

/// The rule for an editor model.
#[must_use]
#[uniffi::export]
pub fn build_schedule_rrule(model: ScheduleModel) -> String {
    rules::build_rrule(&model.into())
}

/// The editor model for a rule, or `None` when the editor cannot show it (keep the rule as is).
#[must_use]
#[uniffi::export]
pub fn parse_schedule_rrule(rrule: String) -> Option<ScheduleModel> {
    rules::parse_rrule(&rrule).map(Into::into)
}

/// The editor's default schedule: every day at 9:00 AM.
#[must_use]
#[uniffi::export]
pub fn default_schedule_model() -> ScheduleModel {
    rules::ScheduleModel::default().into()
}

/// A rule as text ("Weekdays at 8:00 AM").
#[must_use]
#[uniffi::export]
pub fn describe_schedule(rrule: String) -> String {
    rules::describe_schedule(&rrule)
}

/// The next run's distance from `now` (Unix seconds): `soon`, `in 8 mins`, `in 2 days`.
#[must_use]
#[uniffi::export]
pub fn format_next_run(next_run_at: i64, now: i64) -> String {
    rules::format_next_run(next_run_at, now)
}

#[uniffi::export]
impl ClientCore {
    /// Which top-level pages the server offers.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn server_pages(&self) -> Result<ServerPages, CoreError> {
        let pages = self
            .sessions()
            .server_pages()
            .await
            .map_err(CoreError::from)?;
        Ok(ServerPages {
            automations: pages.automations,
            automation_session_modes: pages.automation_session_modes,
            usage: pages.usage,
            archive_worktree_cleanup: pages.archive_worktree_cleanup,
            sharing: pages.sharing,
            sharing_disabled: pages.sharing_disabled,
            canvas: pages.canvas,
            automations_v2: pages.automations_v2,
            automation_projects: pages.automation_projects,
            managed_sandboxes: pages.managed_sandboxes,
            automation_triggers: pages.automation_triggers,
            sibling_sessions: pages.sibling_sessions,
            session_nest_moves: pages.session_nest_moves,
            sibling_session_destinations: Some(pages.sibling_destinations.into()),
            inbox_items: pages.inbox_items,
            automation_inbox: pages.automation_inbox,
            public_sharing: pages.public_sharing,
            sharing_read_only: pages.sharing_read_only,
            sharing_restricted: pages.sharing_restricted,
            project_repository_creation: pages.project_repository_creation,
            project_kanban: pages.project_kanban,
            automation_subhour: pages.automation_subhour,
            automation_trigger_headers: pages.automation_trigger_headers,
            automation_trigger_poll_minutes: pages.automation_trigger_poll_minutes,
            session_message_max_chars: pages.session_message_max_chars,
            automation_mcp_services: pages.automation_mcp_services,
            automation_source_sessions: pages.automation_source_sessions,
            automation_sharing: pages.automation_sharing,
            automation_shared_with_me: pages.automation_shared_with_me,
            automation_run_pull_requests: pages.automation_run_pull_requests,
            automation_harness_settings: pages.automation_harness_settings,
            automation_approval_skipping_modes: pages.automation_approval_skipping_modes,
            session_create_permission_modes: pages.session_create_permission_modes,
        })
    }

    /// One page of the automations other users shared with the caller, after `after`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn shared_automations(
        &self,
        after: Option<String>,
    ) -> Result<SharedAutomationsPage, CoreError> {
        let page = self
            .sessions()
            .shared_automations(after.as_deref())
            .await
            .map_err(CoreError::from)?;
        Ok(SharedAutomationsPage {
            automations: page.automations.into_iter().map(Into::into).collect(),
            next_cursor: page.next_cursor,
        })
    }

    /// The PRs the newest runs of automation `id` created or worked on.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`; the read errors and `MalformedResponse`.
    pub async fn automation_run_pull_requests(
        &self,
        id: String,
    ) -> Result<Vec<RunPullRequests>, CoreError> {
        self.sessions()
            .automation_run_pull_requests(&id)
            .await
            .map(|runs| runs.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// Everyone automation `id` is shared with; only its owner may list them.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors, `MalformedResponse` and
    /// `InvalidPagination`.
    pub async fn automation_grants(&self, id: String) -> Result<Vec<AutomationGrant>, CoreError> {
        self.sessions()
            .automation_grants(&id)
            .await
            .map(|grants| {
                grants
                    .into_iter()
                    .map(|grant| AutomationGrant {
                        user_id: grant.user_id,
                        display_name: grant.display_name,
                    })
                    .collect()
            })
            .map_err(CoreError::from)
    }

    /// Shares automation `id` with `user_id` at read access. Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` before any request, and the write errors
    /// (`Rejected` with the server's reason, `Forbidden`).
    pub async fn grant_automation_access(
        &self,
        id: String,
        user_id: String,
    ) -> Result<(), CoreError> {
        self.sessions()
            .grant_automation_access(&id, &user_id)
            .await
            .map_err(CoreError::from)
    }

    /// Stops sharing automation `id` with `user_id`. Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` before any request, and the write errors.
    pub async fn revoke_automation_access(
        &self,
        id: String,
        user_id: String,
    ) -> Result<(), CoreError> {
        self.sessions()
            .revoke_automation_access(&id, &user_id)
            .await
            .map_err(CoreError::from)
    }

    /// The hosts that deliver long session messages, for a trigger's message budget.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn long_message_hosts(&self) -> Result<Vec<String>, CoreError> {
        self.sessions()
            .long_message_hosts()
            .await
            .map_err(CoreError::from)
    }

    /// The caller's automations.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn automations(&self) -> Result<Vec<Automation>, CoreError> {
        self.sessions()
            .automations()
            .await
            .map(|list| list.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// Creates an automation.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Rejected` for an incomplete or refused draft; the write errors.
    pub async fn create_automation(&self, draft: AutomationDraft) -> Result<Automation, CoreError> {
        self.sessions()
            .create_automation(&draft.into())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Saves the edits of `saved`, sending only what changed.
    ///
    /// # Errors
    ///
    /// As `create_automation`, plus `InvalidIdentifier`.
    pub async fn update_automation(
        &self,
        saved: Automation,
        draft: AutomationDraft,
    ) -> Result<Automation, CoreError> {
        self.sessions()
            .update_automation(&saved.into(), &draft.into())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// An automation's runs, newest first.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`; the read errors and `MalformedResponse`.
    pub async fn automation_runs(&self, id: String) -> Result<Vec<AutomationRun>, CoreError> {
        self.sessions()
            .automation_runs(&id)
            .await
            .map(|runs| runs.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// Pauses or resumes an automation.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`; the write errors.
    pub async fn set_automation_paused(
        &self,
        id: String,
        paused: bool,
    ) -> Result<Automation, CoreError> {
        self.sessions()
            .set_automation_paused(&id, paused)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Starts a run now.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`; `Rejected` while a run is starting; the write
    /// errors.
    pub async fn run_automation(&self, id: String) -> Result<(), CoreError> {
        self.sessions()
            .run_automation(&id)
            .await
            .map_err(CoreError::from)
    }

    /// Deletes an automation; its sessions stay.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`; the write errors.
    pub async fn delete_automation(&self, id: String) -> Result<(), CoreError> {
        self.sessions()
            .delete_automation(&id)
            .await
            .map_err(CoreError::from)
    }
}
