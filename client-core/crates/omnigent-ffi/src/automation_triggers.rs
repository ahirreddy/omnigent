//! Jira, Slack and GitHub trigger automations: the editor's templates and the manager prompt.
//! The rules are `omnigent_core::automation_triggers`'.

use omnigent_core::automation_triggers as core;

/// The service a trigger watches.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TriggerSource {
    /// Jira tickets.
    Jira,
    /// Slack messages.
    Slack,
    /// GitHub issues and pull requests.
    Github,
}

/// How a condition row compares its field with its value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TriggerOperator {
    /// Equals.
    Is,
    /// Doesn't equal.
    IsNot,
    /// Contains.
    Contains,
    /// Doesn't contain.
    NotContains,
    /// Is about.
    About,
    /// Matches a raw query.
    Matches,
    /// Is empty.
    Empty,
    /// Is set.
    NotEmpty,
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

mirror_enum!(TriggerSource, core::TriggerSource, [Jira, Slack, Github]);
mirror_enum!(
    TriggerOperator,
    core::TriggerOperator,
    [
        Is,
        IsNot,
        Contains,
        NotContains,
        About,
        Matches,
        Empty,
        NotEmpty
    ]
);

/// One "and <field> <operator> <value>" row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerCondition {
    /// A field id of the template.
    pub field: String,
    /// The comparison.
    pub operator: TriggerOperator,
    /// The value; unused for valueless operators.
    pub value: String,
}

/// What the trigger editor holds.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerFields {
    /// One of the template's event ids.
    pub event: String,
    /// Project keys, channels or `owner/repo`s, comma-separated.
    pub scope: String,
    /// The condition rows.
    pub conditions: Vec<TriggerCondition>,
    /// What each started session does with its item.
    pub instructions: String,
    /// Post the session link on the item.
    pub link_back: bool,
}

impl From<TriggerFields> for core::TriggerFields {
    fn from(fields: TriggerFields) -> Self {
        Self {
            event: fields.event,
            scope: fields.scope,
            conditions: fields
                .conditions
                .into_iter()
                .map(|row| core::TriggerCondition {
                    field: row.field,
                    operator: row.operator.into(),
                    value: row.value,
                })
                .collect(),
            instructions: fields.instructions,
            link_back: fields.link_back,
        }
    }
}

impl From<core::TriggerFields> for TriggerFields {
    fn from(fields: core::TriggerFields) -> Self {
        Self {
            event: fields.event,
            scope: fields.scope,
            conditions: fields
                .conditions
                .into_iter()
                .map(|row| TriggerCondition {
                    field: row.field,
                    operator: row.operator.into(),
                    value: row.value,
                })
                .collect(),
            instructions: fields.instructions,
            link_back: fields.link_back,
        }
    }
}

/// A creation event a template can fire on.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerEvent {
    /// Id.
    pub id: String,
    /// Label, e.g. "Ticket created".
    pub label: String,
    /// Who can write what it watches, e.g. "create a ticket in this project".
    pub author_action: String,
}

/// An operator a condition field offers, with its wording for that field.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerOperatorChoice {
    /// The operator.
    pub operator: TriggerOperator,
    /// Its label, e.g. "is unassigned".
    pub label: String,
    /// It compares against nothing, so the row has no value.
    pub is_valueless: bool,
}

/// A field a condition row can test.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerConditionField {
    /// Id.
    pub id: String,
    /// Label.
    pub label: String,
    /// Its operators, the default first.
    pub operators: Vec<TriggerOperatorChoice>,
    /// Placeholder.
    pub placeholder: String,
}

/// A source's editor template.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerTemplate {
    /// The source.
    pub source: TriggerSource,
    /// The chip label.
    pub title: String,
    /// The prefilled automation name.
    pub name: String,
    /// Events, the default first.
    pub events: Vec<TriggerEvent>,
    /// Words between the event and the scope, e.g. "in project".
    pub scope_label: String,
    /// The scope's placeholder.
    pub scope_placeholder: String,
    /// Condition fields.
    pub fields: Vec<TriggerConditionField>,
    /// The instructions' placeholder.
    pub instructions_placeholder: String,
    /// The link-back toggle's label.
    pub link_back_label: String,
    /// What it watches, plural.
    pub item_plural: String,
    /// What the agent needs where it runs to reach the service.
    pub tools_example: String,
    /// The service's name, e.g. "Jira".
    pub service_name: String,
}

/// The trigger sources, in the page's order.
#[must_use]
#[uniffi::export]
pub fn trigger_sources() -> Vec<TriggerSource> {
    core::TriggerSource::ALL
        .into_iter()
        .map(Into::into)
        .collect()
}

/// `source`'s editor template.
#[must_use]
#[uniffi::export]
pub fn trigger_template(source: TriggerSource) -> TriggerTemplate {
    let template = core::trigger_template(source.into());
    TriggerTemplate {
        source,
        title: template.title.to_owned(),
        name: template.name.to_owned(),
        events: template
            .events
            .iter()
            .map(|event| TriggerEvent {
                id: event.id.to_owned(),
                label: event.label.to_owned(),
                author_action: event.author_action.to_owned(),
            })
            .collect(),
        scope_label: template.scope_label.to_owned(),
        scope_placeholder: template.scope_placeholder.to_owned(),
        fields: template
            .fields
            .iter()
            .map(|field| TriggerConditionField {
                id: field.id.to_owned(),
                label: field.label.to_owned(),
                operators: field
                    .operators
                    .iter()
                    .map(|&operator| TriggerOperatorChoice {
                        operator: operator.into(),
                        label: field.operator_label(operator).to_owned(),
                        is_valueless: operator.is_valueless(),
                    })
                    .collect(),
                placeholder: field.placeholder.to_owned(),
            })
            .collect(),
        instructions_placeholder: template.instructions_placeholder.to_owned(),
        link_back_label: template.link_back_label.to_owned(),
        item_plural: template.item_plural.to_owned(),
        tools_example: template.tools_example.to_owned(),
        service_name: template.source.service_name().to_owned(),
    }
}

/// The fields a new trigger starts with.
#[must_use]
#[uniffi::export]
pub fn empty_trigger_fields(source: TriggerSource) -> TriggerFields {
    core::empty_trigger_fields(source.into()).into()
}

/// Whether `fields` can render a prompt.
#[must_use]
#[uniffi::export]
pub fn trigger_fields_complete(fields: TriggerFields) -> bool {
    core::trigger_fields_complete(&fields.into())
}

/// The longest per-session instructions, in characters.
#[must_use]
#[uniffi::export]
pub fn max_trigger_instructions_chars() -> u32 {
    u32::try_from(core::MAX_INSTRUCTIONS_CHARS).unwrap_or(u32::MAX)
}

/// The id placeholder a trigger's session link carries.
#[must_use]
#[uniffi::export]
pub fn trigger_session_link_placeholder() -> String {
    core::SESSION_LINK_ID_PLACEHOLDER.to_owned()
}

/// The manager prompt a trigger automation sends every run.
///
/// Workers run in their own sandboxes
/// when `in_sandboxes`, else beside the manager; `session_link` is a session URL with
/// [`trigger_session_link_placeholder`] as its id.
#[must_use]
#[uniffi::export]
pub fn render_trigger_prompt(
    source: TriggerSource,
    fields: TriggerFields,
    in_sandboxes: bool,
    session_link: String,
    model: Option<String>,
    effort: Option<String>,
) -> String {
    let context = core::TriggerPromptContext {
        placement: if in_sandboxes {
            core::WorkerPlacement::Managed
        } else {
            core::WorkerPlacement::SameHost
        },
        session_link,
        model,
        effort,
    };
    core::render_trigger_prompt(source.into(), &fields.into(), &context)
}
