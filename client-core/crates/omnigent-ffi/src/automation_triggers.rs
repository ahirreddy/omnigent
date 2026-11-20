//! Jira, Slack, GitHub, Linear and PagerDuty trigger automations.
//!
//! The editor's templates, the manager prompt, and the header that reopens a saved trigger in
//! its form. The rules are `omnigent_core::automation_triggers`'.

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
    /// Linear issues.
    Linear,
    /// PagerDuty incidents.
    PagerDuty,
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

/// How the scope matches: one value, any listed value, or names containing some text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TriggerScopeOperator {
    /// One value.
    Is,
    /// Any listed value.
    In,
    /// Names containing the text.
    Contains,
}

/// Where the manager starts each worker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum WorkerPlacement {
    /// Beside the manager, sharing its workspace.
    SameHost,
    /// Each in its own managed sandbox.
    Managed,
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
    TriggerSource,
    core::TriggerSource,
    [Jira, Slack, Github, Linear, PagerDuty]
);
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
mirror_enum!(
    TriggerScopeOperator,
    core::TriggerScopeOperator,
    [Is, In, Contains]
);
mirror_enum!(WorkerPlacement, core::WorkerPlacement, [SameHost, Managed]);

/// One "and <field> <operator> <value>" row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerCondition {
    /// A field id of the template.
    pub field: String,
    /// The comparison.
    pub operator: TriggerOperator,
    /// The value; unused for valueless operators.
    pub value: String,
    /// The field a custom-field row compares, e.g. `ES Component`.
    #[uniffi(default)]
    pub name: Option<String>,
}

/// What the trigger editor holds.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerFields {
    /// One of the template's event ids.
    pub event: String,
    /// Projects, channels or people, repositories, teams or services, comma-separated.
    pub scope: String,
    /// How the scope matches; `None` infers membership from the values.
    #[uniffi(default)]
    pub scope_operator: Option<TriggerScopeOperator>,
    /// The condition rows.
    pub conditions: Vec<TriggerCondition>,
    /// The event's "from"/"to" value, e.g. a review request's reviewer.
    #[uniffi(default)]
    pub target: Option<String>,
    /// What each started session does with its item.
    pub instructions: String,
    /// Post the session link on the item.
    pub link_back: bool,
    /// The owner set link-back, so switching events keeps it.
    #[uniffi(default)]
    pub link_back_touched: Option<bool>,
}

impl From<TriggerFields> for core::TriggerFields {
    fn from(fields: TriggerFields) -> Self {
        Self {
            event: fields.event,
            scope: fields.scope,
            scope_operator: fields.scope_operator.map(Into::into),
            conditions: fields
                .conditions
                .into_iter()
                .map(|row| core::TriggerCondition {
                    field: row.field,
                    operator: row.operator.into(),
                    value: row.value,
                    name: row.name,
                })
                .collect(),
            target: fields.target,
            instructions: fields.instructions,
            link_back: fields.link_back,
            link_back_touched: fields.link_back_touched,
        }
    }
}

impl From<core::TriggerFields> for TriggerFields {
    fn from(fields: core::TriggerFields) -> Self {
        Self {
            event: fields.event,
            scope: fields.scope,
            scope_operator: fields.scope_operator.map(Into::into),
            conditions: fields
                .conditions
                .into_iter()
                .map(|row| TriggerCondition {
                    field: row.field,
                    operator: row.operator.into(),
                    value: row.value,
                    name: row.name,
                })
                .collect(),
            target: fields.target,
            instructions: fields.instructions,
            link_back: fields.link_back,
            link_back_touched: fields.link_back_touched,
        }
    }
}

/// Who each worker session is and where it starts.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerWorker {
    /// Where workers run.
    pub placement: WorkerPlacement,
    /// The workers' agent; `None` keeps the polling session's.
    pub agent_id: Option<String>,
    /// The workers' model; empty is the agent's.
    pub model: String,
    /// The workers' reasoning effort; empty is the agent's.
    pub effort: String,
    /// The workers' permission mode; empty is the agent's.
    pub permission_mode: String,
}

/// Everything the trigger form edits; saved as the prompt's first line.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerConfig {
    /// The service.
    pub source: TriggerSource,
    /// The form's fields.
    pub fields: TriggerFields,
    /// Every match goes to one task session.
    pub task_session: bool,
    /// The workers.
    pub worker: TriggerWorker,
}

impl From<TriggerConfig> for core::TriggerConfig {
    fn from(config: TriggerConfig) -> Self {
        Self {
            source: config.source.into(),
            fields: config.fields.into(),
            task_session: config.task_session,
            worker: core::TriggerWorker {
                placement: config.worker.placement.into(),
                agent_id: config.worker.agent_id,
                model: config.worker.model,
                effort: config.worker.effort,
                permission_mode: config.worker.permission_mode,
            },
        }
    }
}

impl From<core::TriggerConfig> for TriggerConfig {
    fn from(config: core::TriggerConfig) -> Self {
        Self {
            source: config.source.into(),
            fields: config.fields.into(),
            task_session: config.task_session,
            worker: TriggerWorker {
                placement: config.worker.placement.into(),
                agent_id: config.worker.agent_id,
                model: config.worker.model,
                effort: config.worker.effort,
                permission_mode: config.worker.permission_mode,
            },
        }
    }
}

/// What a saved config doesn't hold.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerConfigContext {
    /// A session URL with [`trigger_session_link_placeholder`] as its id.
    pub session_link: String,
    /// The polling interval in minutes.
    pub polling_interval_minutes: Option<u32>,
    /// The task session's title, e.g. the automation's name.
    pub task_session_title: Option<String>,
    /// The longest message to send.
    pub message_max_chars: Option<u32>,
    /// A match's session can start as a run of the saved workflow its instructions run.
    #[uniffi(default)]
    pub workflow_ids: bool,
}

impl From<TriggerConfigContext> for core::TriggerConfigContext {
    fn from(context: TriggerConfigContext) -> Self {
        Self {
            session_link: context.session_link,
            polling_interval_minutes: context.polling_interval_minutes,
            task_session_title: context.task_session_title,
            message_max_chars: context.message_max_chars,
            workflow_ids: context.workflow_ids,
        }
    }
}

/// The value an event names inline, e.g. "Review requested from [me]".
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerEventTarget {
    /// Shown before the input, e.g. "from".
    pub word: String,
    /// Label.
    pub label: String,
    /// Placeholder.
    pub placeholder: String,
    /// Shown when a required value is missing or invalid.
    pub hint: Option<String>,
    /// An empty value can't render a prompt; otherwise empty means anyone.
    pub required: bool,
}

/// An event a template can fire on.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerEvent {
    /// Id.
    pub id: String,
    /// Label, e.g. "Ticket created".
    pub label: String,
    /// Who can write what it watches, e.g. "create a ticket in this project".
    pub author_action: String,
    /// The scope's label for this event, e.g. "sender".
    #[uniffi(default)]
    pub scope_label: String,
    /// The scope's placeholder for this event.
    #[uniffi(default)]
    pub scope_placeholder: String,
    /// Shown before the scope and stripped from entries: `#`, `@` or empty.
    #[uniffi(default)]
    pub scope_prefix: String,
    /// The scope lists every member of one group.
    #[uniffi(default)]
    pub scope_is_group: bool,
    /// Condition fields this event doesn't offer.
    #[uniffi(default)]
    pub hidden_fields: Vec<String>,
    /// The inline value the event names.
    #[uniffi(default)]
    pub target: Option<TriggerEventTarget>,
    /// The help text above the builder.
    #[uniffi(default)]
    pub description: String,
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

/// A scope operator a template offers.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerScopeOperatorChoice {
    /// The operator.
    pub operator: TriggerScopeOperator,
    /// Its label, e.g. "equals".
    pub label: String,
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
    /// Set when the row also names the field it compares.
    #[uniffi(default)]
    pub name_placeholder: Option<String>,
}

/// A source's editor template.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerTemplate {
    /// The source.
    pub source: TriggerSource,
    /// The gallery card's title.
    pub title: String,
    /// The gallery card's description.
    #[uniffi(default)]
    pub description: String,
    /// The prefilled automation name.
    pub name: String,
    /// Events, the default first.
    pub events: Vec<TriggerEvent>,
    /// The scope's field, e.g. "project".
    pub scope_label: String,
    /// The scope's placeholder.
    pub scope_placeholder: String,
    /// The scope operators offered, in order.
    #[uniffi(default)]
    pub scope_operators: Vec<TriggerScopeOperatorChoice>,
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

/// How long trigger messages and instructions may be.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerMessageBudget {
    /// The longest worker or task message the prompt asks for.
    pub message_max_chars: u32,
    /// The longest instructions.
    pub instructions_max_chars: u32,
    /// What to update for the full budget; `None` when it applies.
    pub upgrade_hint: Option<String>,
}

/// Where the polling session runs.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TriggerPollingTarget {
    /// No host picked yet.
    Unknown,
    /// A new managed sandbox.
    ManagedSandbox,
    /// A connected host.
    Host {
        /// Its name.
        name: String,
        /// It reports `long_session_messages_supported`.
        long_messages: bool,
    },
}

/// A saved template prompt split into the owner's instructions and the generated text.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerPromptParts {
    /// The owner's instructions, or the whole prompt when it doesn't split.
    pub user_prompt: String,
    /// The generated text around them; `None` when the prompt doesn't split.
    pub system_prompt: Option<String>,
}

/// What an automation's page shows of its prompt.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TriggerPromptDisplay {
    /// The text.
    pub text: String,
    /// It is a trigger's instructions, so the page calls it "Instructions".
    pub instructions_only: bool,
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

fn event_record(source: core::TriggerSource, event: &core::TriggerEvent) -> TriggerEvent {
    let scope = core::trigger_scope(source, event.id);
    TriggerEvent {
        id: event.id.to_owned(),
        label: event.label.to_owned(),
        author_action: event.author_action.to_owned(),
        scope_label: scope.label.to_owned(),
        scope_placeholder: scope.placeholder.to_owned(),
        scope_prefix: scope.prefix.to_owned(),
        scope_is_group: scope.is_group,
        hidden_fields: event
            .hidden_fields
            .iter()
            .map(|field| (*field).to_owned())
            .collect(),
        target: event.target.as_ref().map(|target| TriggerEventTarget {
            word: target.word.to_owned(),
            label: target.label.to_owned(),
            placeholder: target.placeholder.to_owned(),
            hint: target.hint.map(str::to_owned),
            required: target.required,
        }),
        description: core::trigger_event_description(source, event.id),
    }
}

/// `source`'s editor template.
#[must_use]
#[uniffi::export]
pub fn trigger_template(source: TriggerSource) -> TriggerTemplate {
    let core_source = core::TriggerSource::from(source);
    let template = core::trigger_template(core_source);
    TriggerTemplate {
        source,
        title: template.title.to_owned(),
        description: template.description.to_owned(),
        name: template.name.to_owned(),
        events: template
            .events
            .iter()
            .map(|event| event_record(core_source, event))
            .collect(),
        scope_label: template.scope_label.to_owned(),
        scope_placeholder: template.scope_placeholder.to_owned(),
        scope_operators: template
            .scope_operators
            .iter()
            .map(|&operator| TriggerScopeOperatorChoice {
                operator: operator.into(),
                label: operator.label().to_owned(),
            })
            .collect(),
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
                name_placeholder: field.name_placeholder.map(str::to_owned),
            })
            .collect(),
        instructions_placeholder: template.instructions_placeholder.to_owned(),
        link_back_label: template.link_back_label.to_owned(),
        item_plural: template.item_plural.to_owned(),
        tools_example: template.tools_example.to_owned(),
        service_name: core_source.service_name().to_owned(),
    }
}

/// The fields a new trigger starts with.
#[must_use]
#[uniffi::export]
pub fn empty_trigger_fields(source: TriggerSource) -> TriggerFields {
    core::empty_trigger_fields(source.into()).into()
}

/// `fields` switched to the event `event_id`, clearing what that event reads differently.
#[must_use]
#[uniffi::export]
pub fn trigger_fields_for_event(
    source: TriggerSource,
    fields: TriggerFields,
    event_id: String,
) -> TriggerFields {
    core::with_trigger_event(source.into(), &fields.into(), &event_id).into()
}

/// Whether `fields` can render a prompt with instructions up to `instructions_max_chars`.
#[must_use]
#[uniffi::export]
pub fn trigger_fields_complete(
    source: TriggerSource,
    fields: TriggerFields,
    instructions_max_chars: u32,
) -> bool {
    core::trigger_fields_complete(source.into(), &fields.into(), instructions_max_chars)
}

/// How long trigger messages may be for this server (`server_max_chars`, 0 when it doesn't
/// say), polling target and saved limit.
#[must_use]
#[uniffi::export]
pub fn trigger_message_budget(
    server_max_chars: u32,
    target: TriggerPollingTarget,
    saved_max_chars: Option<u32>,
) -> TriggerMessageBudget {
    let target = match target {
        TriggerPollingTarget::Unknown => core::TriggerPollingTarget::Unknown,
        TriggerPollingTarget::ManagedSandbox => core::TriggerPollingTarget::ManagedSandbox,
        TriggerPollingTarget::Host {
            name,
            long_messages,
        } => core::TriggerPollingTarget::Host {
            name,
            long_messages,
        },
    };
    let budget = core::trigger_message_budget(server_max_chars, &target, saved_max_chars);
    TriggerMessageBudget {
        message_max_chars: budget.message_max_chars,
        instructions_max_chars: budget.instructions_max_chars,
        upgrade_hint: budget.upgrade_hint,
    }
}

/// The message limit a saved trigger prompt asks for, e.g. 32000.
#[must_use]
#[uniffi::export]
pub fn read_trigger_message_max_chars(prompt: String) -> Option<u32> {
    core::read_trigger_message_max_chars(&prompt)
}

/// The id placeholder a trigger's session link carries.
#[must_use]
#[uniffi::export]
pub fn trigger_session_link_placeholder() -> String {
    core::SESSION_LINK_ID_PLACEHOLDER.to_owned()
}

/// The manager prompt `config` sends every run, without the header line.
#[must_use]
#[uniffi::export]
pub fn render_trigger_config_prompt(
    config: TriggerConfig,
    context: TriggerConfigContext,
) -> String {
    core::render_trigger_config_prompt(&config.into(), &context.into())
}

/// The saved prompt for `config`: the header the form reopens from, then the manager prompt.
#[must_use]
#[uniffi::export]
pub fn encode_trigger_prompt(config: TriggerConfig, context: TriggerConfigContext) -> String {
    core::encode_trigger_prompt(&config.into(), &context.into())
}

/// The form state a saved prompt's header holds, or `None` when it has none, can't be read,
/// or was edited outside the form.
#[must_use]
#[uniffi::export]
pub fn decode_trigger_prompt(prompt: String) -> Option<TriggerConfig> {
    core::decode_trigger_prompt(&prompt).map(Into::into)
}

/// Whether `prompt` was rendered from a trigger template.
#[must_use]
#[uniffi::export]
pub fn is_trigger_prompt(prompt: String) -> bool {
    core::is_trigger_prompt(&prompt)
}

/// `prompt` without its header line.
#[must_use]
#[uniffi::export]
pub fn strip_trigger_header(prompt: String) -> String {
    core::strip_trigger_header(&prompt).to_owned()
}

/// A saved template prompt's instructions and the generated text around them.
#[must_use]
#[uniffi::export]
pub fn split_trigger_prompt(prompt: String) -> TriggerPromptParts {
    let parts = core::split_trigger_prompt(&prompt);
    TriggerPromptParts {
        user_prompt: parts.user_prompt,
        system_prompt: parts.system_prompt,
    }
}

/// Instructions put back into a saved template's text.
#[must_use]
#[uniffi::export]
pub fn combine_trigger_prompt(user_prompt: String, system_prompt: Option<String>) -> String {
    core::combine_trigger_prompt(&user_prompt, system_prompt.as_deref())
}

/// How an automation's page shows `prompt`.
#[must_use]
#[uniffi::export]
pub fn trigger_prompt_display(prompt: String, is_trigger: bool) -> TriggerPromptDisplay {
    let display = core::trigger_prompt_display(&prompt, is_trigger);
    TriggerPromptDisplay {
        text: display.text,
        instructions_only: display.instructions_only,
    }
}
