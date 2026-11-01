//! Decision cards (elicitations) as typed records, and the responses the user can send.
//!
//! The card is built by `omnigent_core::decisions::Decision::from_request`, which fails
//! closed: anything it cannot render exactly is [`DecisionKind::Unsupported`].

use std::collections::{BTreeMap, HashMap};

use omnigent_core::decisions as core;
use omnigent_protocol::ElicitationValue as CoreValue;

fn count(value: usize) -> u64 {
    u64::try_from(value).unwrap_or(u64::MAX)
}

/// One choice a form field offers.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FormOption {
    /// The value posted when chosen.
    pub value: String,
    /// What to show.
    pub label: String,
    /// Extra description.
    pub detail: String,
}

/// The native control a field needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FieldKind {
    /// Free text.
    Text,
    /// A number.
    Number,
    /// A whole number.
    Integer,
    /// A toggle.
    Boolean,
    /// One option.
    SingleChoice,
    /// Several options.
    MultipleChoice,
}

/// One form field.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FormField {
    /// The `content` key.
    pub key: String,
    /// Label.
    pub title: String,
    /// Help text.
    pub detail: String,
    /// The control.
    pub kind: FieldKind,
    /// Must be answered.
    pub required: bool,
    /// Offered choices.
    pub options: Vec<FormOption>,
    /// A free-text answer is allowed besides the options.
    pub allows_custom: bool,
    /// Render as a secure field.
    pub is_secret: bool,
    /// Lowest number.
    pub minimum: Option<f64>,
    /// Highest number.
    pub maximum: Option<f64>,
    /// Shortest text.
    pub min_length: Option<u64>,
    /// Longest text.
    pub max_length: Option<u64>,
    /// Fewest choices.
    pub min_items: Option<u64>,
    /// Most choices.
    pub max_items: Option<u64>,
}

/// What a card asks for.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum DecisionKind {
    /// Approve or decline, plus the card's permission options.
    Approval,
    /// One answer from `options`, posted under `answer_key`.
    Choice {
        /// The `content` key.
        answer_key: String,
        /// The answers, in schema order.
        options: Vec<String>,
    },
    /// A typed form.
    Form {
        /// The fields, in order.
        fields: Vec<FormField>,
    },
    /// Cannot be answered natively.
    Unsupported {
        /// Why, for display.
        reason: String,
        /// A safe `http(s)` page the user may open explicitly. Never open it automatically.
        external_url: Option<String>,
    },
}

/// Codex and Antigravity persistence scopes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PersistMode {
    /// For the rest of this session.
    Session,
    /// Persistently.
    Always,
}

/// A Codex command approval.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommandApproval {
    /// The command line.
    pub command: String,
    /// Working directory.
    pub cwd: Option<String>,
    /// Why the agent wants to run it.
    pub reason: Option<String>,
}

/// Antigravity permission details.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AntigravityPermission {
    /// What Antigravity wants to do.
    pub action_description: Option<String>,
    /// The command prefix it offers to always allow.
    pub always_allow_pattern: Option<String>,
}

/// Permission choices the request advertises beyond approve and decline. A response that uses
/// one the card does not offer is rejected.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PermissionOptions {
    /// Offer "approve and allow all edits".
    pub allow_all_edits: bool,
    /// Offer "approve and switch to auto mode".
    pub allow_auto_mode: bool,
    /// The directory scope offered for the session.
    pub permission_directories: Vec<String>,
    /// The "don't ask again" scope label.
    pub remember_label: Option<String>,
    /// The plan under review.
    pub plan: Option<String>,
    /// Codex command details.
    pub command: Option<CommandApproval>,
    /// The command policy the user may approve, exactly as offered.
    pub exec_policy_amendment: Option<Vec<String>>,
    /// Offered persistence modes.
    pub persist_modes: Vec<PersistMode>,
    /// Antigravity details.
    pub antigravity: Option<AntigravityPermission>,
}

/// A decision card. A pending card is never hidden.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DecisionCard {
    /// The elicitation id.
    pub id: String,
    /// The session whose stream or snapshot carried the card.
    pub carrying_session_id: String,
    /// The session to resolve on (a child's id for a mirrored card).
    pub target_session_id: String,
    /// Headline.
    pub title: String,
    /// Body text.
    pub detail: String,
    /// What it asks for.
    pub kind: DecisionKind,
    /// Extra approval choices.
    pub permissions: PermissionOptions,
    /// The policy phase, when sent.
    pub phase: Option<String>,
    /// The policy name, when sent.
    pub policy_name: Option<String>,
    /// The user answered locally and the server has not confirmed yet.
    pub answered: bool,
}

/// One form answer.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ElicitationValue {
    /// `null`.
    Null,
    /// A boolean.
    Bool {
        /// The value.
        value: bool,
    },
    /// An integer.
    Integer {
        /// The value.
        value: i64,
    },
    /// A non-integer number.
    Number {
        /// The value.
        value: f64,
    },
    /// Text.
    Text {
        /// The value.
        value: String,
    },
    /// Several choices.
    TextList {
        /// The values.
        values: Vec<String>,
    },
}

/// What the user chose.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum DecisionResponse {
    /// Accept a binary approval.
    Approve,
    /// Decline a binary approval.
    Decline,
    /// Dismiss any answerable card without a choice.
    Cancel,
    /// One of a choice card's options.
    Answer {
        /// The option.
        value: String,
    },
    /// Values for a form, keyed by field key.
    Form {
        /// The answers.
        values: HashMap<String, ElicitationValue>,
    },
    /// Accept and allow all edits.
    ApproveAllEdits,
    /// Accept and switch to auto mode.
    ApproveAutoMode,
    /// Accept and allow the offered directories.
    ApproveDirectories,
    /// Accept and don't ask again.
    ApproveRemembering,
    /// Accept with the offered command policy, exactly as offered.
    ApproveCommandPolicy {
        /// The policy.
        policy: Vec<String>,
    },
    /// Accept with persistence.
    ApprovePersist {
        /// The mode.
        mode: PersistMode,
    },
    /// Decline a plan review with feedback. Must not be blank.
    DeclineWithFeedback {
        /// The feedback.
        feedback: String,
    },
}

impl From<core::FormOption> for FormOption {
    fn from(option: core::FormOption) -> Self {
        Self {
            value: option.value,
            label: option.label,
            detail: option.detail,
        }
    }
}

impl From<core::FieldKind> for FieldKind {
    fn from(kind: core::FieldKind) -> Self {
        match kind {
            core::FieldKind::Text => Self::Text,
            core::FieldKind::Number => Self::Number,
            core::FieldKind::Integer => Self::Integer,
            core::FieldKind::Boolean => Self::Boolean,
            core::FieldKind::SingleChoice => Self::SingleChoice,
            core::FieldKind::MultipleChoice => Self::MultipleChoice,
        }
    }
}

impl From<core::FormField> for FormField {
    fn from(field: core::FormField) -> Self {
        Self {
            key: field.key,
            title: field.title,
            detail: field.detail,
            kind: field.kind.into(),
            required: field.required,
            options: field.options.into_iter().map(Into::into).collect(),
            allows_custom: field.allows_custom,
            is_secret: field.is_secret,
            minimum: field.minimum,
            maximum: field.maximum,
            min_length: field.min_length.map(count),
            max_length: field.max_length.map(count),
            min_items: field.min_items.map(count),
            max_items: field.max_items.map(count),
        }
    }
}

impl From<core::DecisionKind> for DecisionKind {
    fn from(kind: core::DecisionKind) -> Self {
        match kind {
            core::DecisionKind::Approval => Self::Approval,
            core::DecisionKind::Choice {
                answer_key,
                options,
            } => Self::Choice {
                answer_key,
                options,
            },
            core::DecisionKind::Form(form) => Self::Form {
                fields: form.fields.into_iter().map(Into::into).collect(),
            },
            core::DecisionKind::Unsupported {
                reason,
                external_url,
            } => Self::Unsupported {
                reason: reason.to_string(),
                external_url,
            },
        }
    }
}

impl From<core::PersistMode> for PersistMode {
    fn from(mode: core::PersistMode) -> Self {
        match mode {
            core::PersistMode::Session => Self::Session,
            core::PersistMode::Always => Self::Always,
        }
    }
}

impl From<PersistMode> for core::PersistMode {
    fn from(mode: PersistMode) -> Self {
        match mode {
            PersistMode::Session => Self::Session,
            PersistMode::Always => Self::Always,
        }
    }
}

impl From<core::PermissionOptions> for PermissionOptions {
    fn from(options: core::PermissionOptions) -> Self {
        Self {
            allow_all_edits: options.allow_all_edits,
            allow_auto_mode: options.allow_auto_mode,
            permission_directories: options.permission_directories,
            remember_label: options
                .remember
                .as_ref()
                .map(|scope| scope.label().to_owned()),
            plan: options.plan,
            command: options.command.map(|command| CommandApproval {
                command: command.command,
                cwd: command.cwd,
                reason: command.reason,
            }),
            exec_policy_amendment: options.exec_policy_amendment,
            persist_modes: options.persist_modes.into_iter().map(Into::into).collect(),
            antigravity: options.antigravity.map(|agy| AntigravityPermission {
                action_description: agy.action_description,
                always_allow_pattern: agy.always_allow_pattern,
            }),
        }
    }
}

impl DecisionCard {
    /// The card for a reducer decision carried by `session_id`.
    pub(crate) fn from_reducer(
        decision: &omnigent_core::reducer::Decision,
        session_id: &str,
    ) -> Self {
        let card = core::Decision::from_request(&decision.request, session_id);
        Self {
            id: card.id,
            carrying_session_id: card.carrying_session_id,
            target_session_id: card.target_session_id,
            title: card.title,
            detail: card.detail,
            kind: card.kind.into(),
            permissions: card.permissions.into(),
            phase: card.phase,
            policy_name: card.policy_name,
            answered: decision.answered,
        }
    }
}

impl From<ElicitationValue> for CoreValue {
    fn from(value: ElicitationValue) -> Self {
        match value {
            ElicitationValue::Null => Self::Null,
            ElicitationValue::Bool { value } => Self::Bool(value),
            ElicitationValue::Integer { value } => Self::Integer(value),
            ElicitationValue::Number { value } => Self::Number(value),
            ElicitationValue::Text { value } => Self::Text(value),
            ElicitationValue::TextList { values } => Self::TextList(values),
        }
    }
}

impl From<DecisionResponse> for core::DecisionResponse {
    fn from(response: DecisionResponse) -> Self {
        match response {
            DecisionResponse::Approve => Self::Approve,
            DecisionResponse::Decline => Self::Decline,
            DecisionResponse::Cancel => Self::Cancel,
            DecisionResponse::Answer { value } => Self::Answer(value),
            DecisionResponse::Form { values } => Self::Form(
                values
                    .into_iter()
                    .map(|(key, value)| (key, value.into()))
                    .collect::<BTreeMap<_, _>>(),
            ),
            DecisionResponse::ApproveAllEdits => Self::ApproveAllEdits,
            DecisionResponse::ApproveAutoMode => Self::ApproveAutoMode,
            DecisionResponse::ApproveDirectories => Self::ApproveDirectories,
            DecisionResponse::ApproveRemembering => Self::ApproveRemembering,
            DecisionResponse::ApproveCommandPolicy { policy } => Self::ApproveCommandPolicy(policy),
            DecisionResponse::ApprovePersist { mode } => Self::ApprovePersist(mode.into()),
            DecisionResponse::DeclineWithFeedback { feedback } => {
                Self::DeclineWithFeedback(feedback)
            }
        }
    }
}
