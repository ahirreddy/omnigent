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
    /// The Canvas page.
    #[uniffi(default)]
    pub canvas: bool,
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
}

/// What the automation editor saves.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
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
        }
    }
}

impl From<core::Automation> for Automation {
    fn from(automation: core::Automation) -> Self {
        Self {
            id: automation.id,
            name: automation.name,
            prompt: automation.prompt,
            rrule: automation.rrule,
            schedule_text: automation.schedule_text,
            agent_id: automation.agent_id,
            timezone: automation.timezone,
            continues_session: automation.continues_session,
            state: match automation.state {
                core::AutomationState::Active => AutomationState::Active,
                core::AutomationState::Paused => AutomationState::Paused,
                core::AutomationState::Unknown { value } => AutomationState::Unknown { value },
            },
            next_run_at: automation.next_run_at,
            last_run_at: automation.last_run_at,
            last_run_status: automation.last_run_status,
            last_run_session_id: automation.last_run_session_id,
            updated_at: automation.updated_at,
        }
    }
}

impl From<Automation> for core::Automation {
    fn from(automation: Automation) -> Self {
        Self {
            id: automation.id,
            name: automation.name,
            prompt: automation.prompt,
            rrule: automation.rrule,
            schedule_text: automation.schedule_text,
            agent_id: automation.agent_id,
            timezone: automation.timezone,
            continues_session: automation.continues_session,
            state: match automation.state {
                AutomationState::Active => core::AutomationState::Active,
                AutomationState::Paused => core::AutomationState::Paused,
                AutomationState::Unknown { value } => core::AutomationState::Unknown { value },
            },
            next_run_at: automation.next_run_at,
            last_run_at: automation.last_run_at,
            last_run_status: automation.last_run_status,
            last_run_session_id: automation.last_run_session_id,
            updated_at: automation.updated_at,
        }
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
        }
    }
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
            canvas: pages.canvas,
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

    /// Saves an edited automation.
    ///
    /// # Errors
    ///
    /// As `create_automation`, plus `InvalidIdentifier`.
    pub async fn update_automation(
        &self,
        id: String,
        draft: AutomationDraft,
    ) -> Result<Automation, CoreError> {
        self.sessions()
            .update_automation(&id, &draft.into())
            .await
            .map(Into::into)
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
