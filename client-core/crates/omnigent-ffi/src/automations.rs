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
    [Hourly, Daily, Weekly, Monthly, Yearly]
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
        }
    }
}

/// Why the editor cannot save `model`, or `None`. `now` is Unix seconds; an unchanged schedule
/// may keep an end in the past.
#[must_use]
#[uniffi::export]
pub fn validate_schedule(model: ScheduleModel, now: i64, allow_past_end: bool) -> Option<String> {
    rules::validate_schedule(&model.into(), now, allow_past_end)
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
        })
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
