//! Approval modes: each native harness's own permission vocabulary, under one set of clear names.
//!
//! The server switches a running session's mode through the harness's own TUI, so the values and
//! which ones a running session may switch to are per wrapper (`omnigent.wrapper`):
//!
//! - Claude Code (`claude-code-native-ui`): `permission_mode`, the shift+tab-reachable modes
//!   (`omnigent/server/routes/_sessions/common.py`, `web/src/lib/claudePermissionMode.ts`).
//! - Codex (`codex-native-ui`): `approval_mode`, the `/permissions` presets
//!   (`omnigent/codex_approval_modes.py`, `web/src/lib/codexApprovalMode.ts`).
//! - Devin (`devin-native-ui`): `permission_mode`, Devin's own rungs
//!   (`omnigent/harnesses/devin_native/bridge.py`, `web/src/lib/nativeHarnessModes.ts`).
//!
//! Other harnesses have no live switch, so they get no menu. A mode a session reports but cannot
//! be switched into (launch-only) is listed so the chip shows it, and is never a cycle target.

use std::collections::BTreeMap;

use omnigent_protocol::Field;

use super::session::SessionConfiguration;

/// How much a mode lets the agent do without asking, lowest first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
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

/// The `PATCH /v1/sessions/{id}` field that switches the mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ApprovalModeField {
    /// `permission_mode` (Claude Code, Devin).
    PermissionMode,
    /// `approval_mode` (Codex).
    ApprovalMode,
}

impl ApprovalModeField {
    /// The wire name.
    #[must_use]
    pub const fn wire_name(self) -> &'static str {
        match self {
            Self::PermissionMode => "permission_mode",
            Self::ApprovalMode => "approval_mode",
        }
    }
}

/// One mode.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
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
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ApprovalModeMenu {
    /// The harness display label, for example `Codex`.
    pub harness: String,
    /// The field that switches it.
    pub field: ApprovalModeField,
    /// The switchable modes in the harness's order, then the current mode when it is not
    /// switchable.
    pub options: Vec<ApprovalModeOption>,
    /// The current wire value; `None` when the session has not reported it.
    pub selected: Option<String>,
}

impl ApprovalModeMenu {
    /// The selected option.
    #[must_use]
    pub fn selected_option(&self) -> Option<&ApprovalModeOption> {
        let selected = self.selected.as_deref()?;
        self.options.iter().find(|option| option.value == selected)
    }

    /// The switchable mode after the current one, wrapping (shift+tab). `None` when the current
    /// mode is unknown or not switchable: leaving it stays a menu choice, as on the web.
    #[must_use]
    pub fn next(&self) -> Option<&ApprovalModeOption> {
        let current = self.selected_option().filter(|option| option.switchable)?;
        let switchable: Vec<&ApprovalModeOption> = self
            .options
            .iter()
            .filter(|option| option.switchable)
            .collect();
        let index = switchable
            .iter()
            .position(|option| option.value == current.value)?;
        let next = *switchable.get((index + 1) % switchable.len())?;
        (next.value != current.value).then_some(next)
    }
}

/// `omnigent.wrapper` values with a live switch.
const CLAUDE_WRAPPER: &str = "claude-code-native-ui";
const CODEX_WRAPPER: &str = "codex-native-ui";
const DEVIN_WRAPPER: &str = "devin-native-ui";

/// The labels the server writes after a confirmed switch.
pub(crate) const PERMISSION_MODE_LABEL: &str = "omnigent.claude_native.permission_mode";
pub(crate) const APPROVAL_MODE_LABEL: &str = "omnigent.codex_native.approval_mode";
/// The launch flag a Claude Code or Devin session restores its mode from.
const PERMISSION_MODE_FLAG: &str = "--permission-mode";

struct Mode {
    value: &'static str,
    title: &'static str,
    harness_title: &'static str,
    description: &'static str,
    risk: ApprovalRisk,
    switchable: bool,
}

const fn mode(
    value: &'static str,
    title: &'static str,
    harness_title: &'static str,
    description: &'static str,
    risk: ApprovalRisk,
    switchable: bool,
) -> Mode {
    Mode {
        value,
        title,
        harness_title,
        description,
        risk,
        switchable,
    }
}

use ApprovalRisk::{Ask, AutoApprove, AutoEdit, FullAccess, ReadOnly};

/// Claude Code's shift+tab order; `dontAsk` and `bypassPermissions` are launch-only.
const CLAUDE_MODES: [Mode; 6] = [
    mode(
        "default",
        "Ask first",
        "Manual",
        "Asks before edits and commands",
        Ask,
        true,
    ),
    mode(
        "acceptEdits",
        "Auto-edit",
        "Accept edits",
        "Applies file edits without asking; commands still ask",
        AutoEdit,
        true,
    ),
    mode(
        "plan",
        "Plan only",
        "Plan",
        "Plans and reads; makes no edits",
        ReadOnly,
        true,
    ),
    mode(
        "auto",
        "Auto-approve",
        "Auto",
        "Runs without asking; a classifier blocks risky actions",
        AutoApprove,
        true,
    ),
    mode(
        "dontAsk",
        "Pre-approved only",
        "Don't ask",
        "Declines anything not pre-approved",
        Ask,
        false,
    ),
    mode(
        "bypassPermissions",
        "Full access",
        "Bypass permissions",
        "Runs everything without asking or safety checks",
        FullAccess,
        false,
    ),
];

/// Codex's `/permissions` popup; Read Only is not offered on a running session.
const CODEX_MODES: [Mode; 4] = [
    mode(
        "ask-for-approval",
        "Auto-edit",
        "Ask for approval",
        "Edits and runs in the workspace; asks before network access or outside edits",
        AutoEdit,
        true,
    ),
    mode(
        "approve-for-me",
        "Auto-approve",
        "Approve for me",
        "Asks only for actions it detects as unsafe",
        AutoApprove,
        true,
    ),
    mode(
        "full-access",
        "Full access",
        "Full Access",
        "Edits any file and uses the internet without asking",
        FullAccess,
        true,
    ),
    mode(
        "read-only",
        "Read only",
        "Read Only",
        "Reads files; asks before edits, commands or network access",
        ReadOnly,
        false,
    ),
];

/// Devin's rungs, by their canonical names; `auto` and `bypass` are aliases it may report.
const DEVIN_MODES: [Mode; 6] = [
    mode(
        "normal",
        "Ask first",
        "Normal",
        "Runs read-only tools; asks for anything else",
        Ask,
        true,
    ),
    mode(
        "accept-edits",
        "Auto-edit",
        "Accept edits",
        "Also applies edits in the workspace without asking",
        AutoEdit,
        true,
    ),
    mode(
        "smart",
        "Auto-approve",
        "Smart",
        "Also runs actions a fast model judges safe",
        AutoApprove,
        true,
    ),
    mode(
        "dangerous",
        "Full access",
        "Dangerous",
        "Runs every tool without asking",
        FullAccess,
        true,
    ),
    mode(
        "auto",
        "Ask first",
        "Normal",
        "Runs read-only tools; asks for anything else",
        Ask,
        false,
    ),
    mode(
        "bypass",
        "Full access",
        "Dangerous",
        "Runs every tool without asking",
        FullAccess,
        false,
    ),
];

struct Vocabulary {
    harness: &'static str,
    field: ApprovalModeField,
    label: &'static str,
    launch_flag: Option<&'static str>,
    modes: &'static [Mode],
}

fn vocabulary(wrapper: Option<&str>) -> Option<Vocabulary> {
    Some(match wrapper? {
        CLAUDE_WRAPPER => Vocabulary {
            harness: "Claude Code",
            field: ApprovalModeField::PermissionMode,
            label: PERMISSION_MODE_LABEL,
            launch_flag: Some(PERMISSION_MODE_FLAG),
            modes: &CLAUDE_MODES,
        },
        CODEX_WRAPPER => Vocabulary {
            harness: "Codex",
            field: ApprovalModeField::ApprovalMode,
            label: APPROVAL_MODE_LABEL,
            launch_flag: None,
            modes: &CODEX_MODES,
        },
        DEVIN_WRAPPER => Vocabulary {
            harness: "Devin",
            field: ApprovalModeField::PermissionMode,
            label: PERMISSION_MODE_LABEL,
            launch_flag: Some(PERMISSION_MODE_FLAG),
            modes: &DEVIN_MODES,
        },
        _ => return None,
    })
}

fn option(mode: &Mode) -> ApprovalModeOption {
    ApprovalModeOption {
        value: mode.value.to_owned(),
        title: mode.title.to_owned(),
        harness_title: mode.harness_title.to_owned(),
        description: mode.description.to_owned(),
        risk: mode.risk,
        switchable: mode.switchable,
    }
}

/// The approval-mode menu for `configuration`, or `None` when its harness has no live switch.
/// A reported value outside the vocabulary is listed under its raw value, never dropped.
#[must_use]
pub fn approval_mode_menu(configuration: &SessionConfiguration) -> Option<ApprovalModeMenu> {
    let vocabulary = vocabulary(configuration.wrapper.as_deref())?;
    let selected = configuration.approval_mode.clone();
    let mut options: Vec<ApprovalModeOption> = vocabulary
        .modes
        .iter()
        .filter(|mode| mode.switchable)
        .map(option)
        .collect();
    if let Some(value) = selected.as_deref()
        && !options.iter().any(|option| option.value == value)
    {
        options.push(
            vocabulary
                .modes
                .iter()
                .find(|mode| mode.value == value)
                .map_or_else(
                    || ApprovalModeOption {
                        value: value.to_owned(),
                        title: value.to_owned(),
                        harness_title: value.to_owned(),
                        description: format!("{} reports this mode", vocabulary.harness),
                        risk: Ask,
                        switchable: false,
                    },
                    option,
                ),
        );
    }
    Some(ApprovalModeMenu {
        harness: vocabulary.harness.to_owned(),
        field: vocabulary.field,
        options,
        selected,
    })
}

/// The mode a session reports through its labels and launch arguments, for `wrapper`.
///
/// `None`: the fields say nothing new, keep what is known. `Some(None)`: the session reports no
/// mode (or has no live switch). The confirmed-switch label wins over the launch flag; a list row
/// (labels without launch arguments) that lacks the label keeps a mode read from the flag.
#[must_use]
pub fn reported_approval_mode(
    wrapper: Option<&str>,
    labels: &Field<BTreeMap<String, String>>,
    launch_args: &Field<Vec<String>>,
) -> Option<Option<String>> {
    let Some(vocabulary) = vocabulary(wrapper) else {
        return Some(None);
    };
    if let Some(value) = labels
        .value()
        .and_then(|labels| labels.get(vocabulary.label))
        .filter(|value| !value.is_empty())
    {
        return Some(Some(value.clone()));
    }
    match launch_args {
        Field::Present(args) => Some(vocabulary.launch_flag.and_then(|flag| {
            args.iter()
                .position(|arg| arg == flag)
                .and_then(|index| args.get(index + 1))
                .cloned()
        })),
        Field::Null => Some(None),
        Field::Absent => match labels {
            Field::Null => Some(None),
            Field::Absent | Field::Present(_) => None,
        },
    }
}

/// The approval modes a new session can launch in for `wrapper`, the default selected; `None`
/// when the harness takes no launch mode. Launch-only modes are offered here.
#[must_use]
pub fn launch_approval_mode_menu(wrapper: Option<&str>) -> Option<ApprovalModeMenu> {
    let vocabulary = vocabulary(wrapper)?;
    let options: Vec<ApprovalModeOption> = match wrapper? {
        // Codex launches from its `/permissions` presets, which only some live modes match.
        // Bypass is a launch flag, not a preset, so it is offered only here.
        CODEX_WRAPPER => CODEX_LAUNCH_PRESETS
            .iter()
            .filter_map(|(value, _)| vocabulary.modes.iter().find(|mode| mode.value == *value))
            .chain(std::iter::once(&CODEX_BYPASS_MODE))
            .map(option)
            .collect(),
        _ => vocabulary.modes.iter().map(option).collect(),
    };
    let selected = options.first().map(|option| option.value.clone());
    Some(ApprovalModeMenu {
        harness: vocabulary.harness.to_owned(),
        field: vocabulary.field,
        options: options
            .into_iter()
            .map(|option| ApprovalModeOption {
                switchable: true,
                ..option
            })
            .collect(),
        selected,
    })
}

/// Codex's launch-only "Bypass approvals & sandbox": no approval prompts and no command sandbox.
pub const CODEX_BYPASS_MODE_VALUE: &str = "bypass";

/// The label that launches Codex with `--dangerously-bypass-approvals-and-sandbox`.
pub const CODEX_BYPASS_LABEL: &str = "omnigent.codex_native.bypass_sandbox";

const CODEX_BYPASS_MODE: Mode = mode(
    CODEX_BYPASS_MODE_VALUE,
    "Bypass approvals & sandbox",
    "Bypass approvals & sandbox",
    "Runs Codex with no approval prompts and no command sandbox",
    FullAccess,
    false,
);

/// Whether `mode` is Codex's bypass for a session of `wrapper`, which a launch sends as
/// [`CODEX_BYPASS_LABEL`] instead of flags.
#[must_use]
pub fn is_codex_bypass(wrapper: Option<&str>, mode: Option<&str>) -> bool {
    wrapper == Some(CODEX_WRAPPER) && mode == Some(CODEX_BYPASS_MODE_VALUE)
}

/// Codex launch presets (`web/src/lib/nativeHarnessModes.ts`), the default first.
const CODEX_LAUNCH_PRESETS: [(&str, &[&str]); 3] = [
    ("ask-for-approval", &[]),
    (
        "read-only",
        &["--sandbox", "read-only", "--ask-for-approval", "on-request"],
    ),
    (
        "full-access",
        &[
            "--sandbox",
            "danger-full-access",
            "--ask-for-approval",
            "never",
        ],
    ),
];

/// The `terminal_launch_args` that start `wrapper` in `mode`; `None` for the harness default, a
/// harness without launch modes, or a mode it does not offer at launch.
#[must_use]
pub fn launch_approval_args(wrapper: Option<&str>, mode: &str) -> Option<Vec<String>> {
    let menu = launch_approval_mode_menu(wrapper)?;
    if menu.selected.as_deref() == Some(mode) || !menu.options.iter().any(|o| o.value == mode) {
        return None;
    }
    let args: Vec<String> = match wrapper? {
        CODEX_WRAPPER => CODEX_LAUNCH_PRESETS
            .iter()
            .find(|(value, _)| *value == mode)?
            .1
            .iter()
            .map(|arg| (*arg).to_owned())
            .collect(),
        _ => vec![PERMISSION_MODE_FLAG.to_owned(), mode.to_owned()],
    };
    Some(args)
}

#[cfg(test)]
#[path = "approval_tests.rs"]
mod tests;
