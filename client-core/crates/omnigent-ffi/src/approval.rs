//! Approval modes: the records, the menu rule and the switch. The rules are
//! `omnigent_core::config::approval`'s.

use omnigent_core::config::approval as core;
use omnigent_core::config::session::SessionConfiguration as CoreConfiguration;

use crate::client::ClientCore;
use crate::configuration::SessionConfiguration;
use crate::errors::CoreError;
use crate::sessions::SessionSummary;

/// How much a mode lets the agent do without asking, lowest first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ApprovalRisk {
    /// Reads and plans only.
    ReadOnly,
    /// Asks before edits and commands.
    Ask,
    /// Applies edits without asking.
    AutoEdit,
    /// Runs what it judges safe without asking.
    AutoApprove,
    /// Runs everything without asking.
    FullAccess,
}

/// One approval mode.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ApprovalModeOption {
    /// The wire value.
    pub value: String,
    /// The clear name, for example `Ask first`.
    pub title: String,
    /// The harness's own name, for example `Manual`.
    pub harness_title: String,
    /// What it allows.
    pub description: String,
    /// How much it allows.
    pub risk: ApprovalRisk,
    /// A running session can be switched into it.
    pub switchable: bool,
}

/// A session's approval modes and the current one.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ApprovalModeMenu {
    /// The harness display label, for example `Codex`.
    pub harness: String,
    /// The switchable modes in the harness's order, then the current mode when it is not
    /// switchable.
    pub options: Vec<ApprovalModeOption>,
    /// The current wire value; `None` when not reported.
    pub selected: Option<String>,
    /// The switchable mode after the current one (shift+tab); `None` when the current mode is
    /// unknown or not switchable.
    pub next: Option<String>,
}

impl From<core::ApprovalRisk> for ApprovalRisk {
    fn from(risk: core::ApprovalRisk) -> Self {
        match risk {
            core::ApprovalRisk::ReadOnly => Self::ReadOnly,
            core::ApprovalRisk::Ask => Self::Ask,
            core::ApprovalRisk::AutoEdit => Self::AutoEdit,
            core::ApprovalRisk::AutoApprove => Self::AutoApprove,
            core::ApprovalRisk::FullAccess => Self::FullAccess,
        }
    }
}

impl From<core::ApprovalModeOption> for ApprovalModeOption {
    fn from(option: core::ApprovalModeOption) -> Self {
        Self {
            value: option.value,
            title: option.title,
            harness_title: option.harness_title,
            description: option.description,
            risk: option.risk.into(),
            switchable: option.switchable,
        }
    }
}

/// The approval-mode menu for `configuration`, or `None` when its harness has no live switch.
#[must_use]
#[uniffi::export]
pub fn approval_mode_menu(configuration: SessionConfiguration) -> Option<ApprovalModeMenu> {
    let menu = core::approval_mode_menu(&CoreConfiguration::from(configuration))?;
    let next = menu.next().map(|option| option.value.clone());
    Some(ApprovalModeMenu {
        harness: menu.harness,
        options: menu.options.into_iter().map(Into::into).collect(),
        selected: menu.selected,
        next,
    })
}

#[uniffi::export]
impl ClientCore {
    /// Switches `session_id`'s live approval mode to `value`, also while a turn runs. Never
    /// retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Busy` while another change is in flight, `ReadOnly` below owner
    /// level, `Archived`, `StreamNotReady`, `Configuration` when the mode cannot be switched to or
    /// the harness landed on another one (that one is kept), `DeliveryUncertain` when the
    /// acknowledgement shows no mode, and the read and write errors.
    pub async fn set_approval_mode(
        &self,
        session_id: String,
        value: String,
    ) -> Result<SessionSummary, CoreError> {
        self.sessions()
            .set_approval_mode(&value, &session_id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}
