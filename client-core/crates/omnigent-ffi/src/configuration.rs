//! Session configuration: harness, model and reasoning effort.
//!
//! Records, and the pure rules the composer's menus use. The REST calls are
//! [`crate::client::ClientCore`] methods; the rules are `omnigent_core::config::session`'s.

use omnigent_core::config::session as core;

use crate::client::ClientCore;
use crate::errors::CoreError;
use crate::sessions::SessionSummary;

/// A reasoning effort a model supports.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ReasoningChoice {
    /// The effort value, for example `high`.
    pub reasoning_effort: String,
    /// Description.
    pub description: Option<String>,
}

/// One model-picker row (a session's `model_options`, or a host's model preview).
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ModelChoice {
    /// Option id.
    pub id: String,
    /// Provider model name; the wire value when present.
    pub model: Option<String>,
    /// Display name.
    pub display_name: Option<String>,
    /// Description.
    pub description: Option<String>,
    /// Hidden from the picker.
    pub hidden: Option<bool>,
    /// The runner's default model.
    pub is_default: Option<bool>,
    /// Default reasoning effort.
    pub default_reasoning_effort: Option<String>,
    /// Supported efforts. `None` (not reported) differs from `[]` (none supported).
    pub supported_reasoning_efforts: Option<Vec<ReasoningChoice>>,
    /// The picker title: display name, else model, else id.
    #[uniffi(default)]
    pub title: String,
    /// The value sent as `model_override` and in a creation request: the model, else the id.
    #[uniffi(default)]
    pub value: String,
}

/// How one session runs, as last reported. `Option<bool>` flags are tri-state: `None` is "not
/// reported", never proof either way.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SessionConfiguration {
    /// Bound agent id.
    pub agent_id: Option<String>,
    /// Harness as sent.
    pub harness: Option<String>,
    /// `omnigent.wrapper` label.
    pub wrapper: Option<String>,
    /// Per-session model override.
    pub model_override: Option<String>,
    /// The model the session is actually on (`llm_model`).
    pub base_model: Option<String>,
    /// Reasoning effort.
    pub effort: Option<String>,
    /// `model_override` was reported (as a value or `null`).
    pub model_reported: Option<bool>,
    /// `reasoning_effort` was reported (as a value or `null`).
    pub effort_reported: Option<bool>,
    /// Model-picker rows reported by the runner.
    pub models: Vec<ModelChoice>,
    /// Launching host.
    pub host_id: Option<String>,
    /// Host tunnel liveness.
    pub host_online: Option<bool>,
    /// Runner liveness.
    pub runner_online: Option<bool>,
    /// A runner is bound.
    pub runner_bound: Option<bool>,
    /// A dormant host can be woken.
    pub host_resumable: Option<bool>,
    /// Parent of a sub-agent session.
    pub parent_id: Option<String>,
    /// Cost-control (smart routing) mode override.
    pub routing_mode: Option<String>,
    /// The live approval mode's wire value; `None` when not reported.
    #[uniffi(default)]
    pub approval_mode: Option<String>,
    /// The workspace's git branch.
    #[uniffi(default)]
    pub git_branch: Option<String>,
}

/// A pending model and effort choice against the configuration it started from.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConfigurationEdit {
    /// The configuration the edit started from.
    pub baseline: SessionConfiguration,
    /// The chosen model override; `None` resets to the harness default.
    pub model: Option<String>,
    /// The chosen effort; `None` resets to the harness default.
    pub effort: Option<String>,
}

/// A built-in agent a session may switch to.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessChoice {
    /// Agent id.
    pub id: String,
    /// Display name.
    pub name: String,
    /// Harness as sent.
    pub harness: Option<String>,
    /// Built-in agent.
    pub builtin: Option<bool>,
    /// The harness display label.
    #[uniffi(default)]
    pub title: String,
    /// The harness keeps the conversation history through an in-place switch.
    #[uniffi(default)]
    pub preserves_history: bool,
}

/// What a host reports for one harness in `configured_harnesses`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum HarnessReadiness {
    /// Configured.
    Ready,
    /// Not configured.
    NotReady,
    /// Needs a sign-in on the host.
    NeedsAuthentication,
    /// Any other value; never treated as ready.
    Unknown,
}

/// One harness's readiness on a host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessStatus {
    /// The harness id as the host reported it.
    pub harness: String,
    /// Its readiness.
    pub readiness: HarnessReadiness,
}

/// A session's host, as `GET /v1/hosts` reports it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ConfigurationHost {
    /// Host id.
    pub host_id: String,
    /// Display name.
    pub name: String,
    /// `online`, `offline`, ...
    pub status: String,
    /// Per-harness readiness, when reported, by harness id.
    pub configured_harnesses: Option<Vec<HarnessStatus>>,
}

/// What a session's settings can offer: switch targets, the host, and the host's model preview
/// when the runner reported none.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConfigurationCatalog {
    /// Built-in agents, de-duplicated by id.
    pub agents: Vec<HarnessChoice>,
    /// The session's host, when the inventory lists it.
    pub host: Option<ConfigurationHost>,
    /// The host's model preview for the session's harness.
    pub model_options: Vec<ModelChoice>,
    /// Why the host preview failed, when it did; the harness catalog is still usable.
    pub model_options_error: Option<String>,
    /// The configuration the preview was fetched for.
    pub model_options_identity: Option<SessionConfiguration>,
}

/// The display labels of a configuration.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ConfigurationLabels {
    /// The harness, for example `Codex`.
    pub harness: String,
    /// The model, `Harness default`, `Smart routing` or `Model not reported`.
    pub model: String,
    /// The effort, `Harness default` or `Not reported`.
    pub effort: String,
    /// `"<harness> · <model>"`.
    pub identity: String,
}

impl From<core::ReasoningChoice> for ReasoningChoice {
    fn from(choice: core::ReasoningChoice) -> Self {
        Self {
            reasoning_effort: choice.reasoning_effort,
            description: choice.description,
        }
    }
}

impl From<ReasoningChoice> for core::ReasoningChoice {
    fn from(choice: ReasoningChoice) -> Self {
        Self {
            reasoning_effort: choice.reasoning_effort,
            description: choice.description,
        }
    }
}

impl From<core::ModelChoice> for ModelChoice {
    fn from(choice: core::ModelChoice) -> Self {
        Self {
            title: choice.title().to_owned(),
            value: choice.value().to_owned(),
            id: choice.id,
            model: choice.model,
            display_name: choice.display_name,
            description: choice.description,
            hidden: choice.hidden,
            is_default: choice.is_default,
            default_reasoning_effort: choice.default_reasoning_effort,
            supported_reasoning_efforts: choice
                .supported_reasoning_efforts
                .map(|efforts| efforts.into_iter().map(Into::into).collect()),
        }
    }
}

impl From<ModelChoice> for core::ModelChoice {
    fn from(choice: ModelChoice) -> Self {
        Self {
            id: choice.id,
            model: choice.model,
            display_name: choice.display_name,
            description: choice.description,
            hidden: choice.hidden,
            is_default: choice.is_default,
            default_reasoning_effort: choice.default_reasoning_effort,
            supported_reasoning_efforts: choice
                .supported_reasoning_efforts
                .map(|efforts| efforts.into_iter().map(Into::into).collect()),
        }
    }
}

impl From<core::SessionConfiguration> for SessionConfiguration {
    fn from(configuration: core::SessionConfiguration) -> Self {
        Self {
            agent_id: configuration.agent_id,
            harness: configuration.harness,
            wrapper: configuration.wrapper,
            model_override: configuration.model_override,
            base_model: configuration.base_model,
            effort: configuration.effort,
            model_reported: configuration.model_reported,
            effort_reported: configuration.effort_reported,
            models: configuration.models.into_iter().map(Into::into).collect(),
            host_id: configuration.host_id,
            host_online: configuration.host_online,
            runner_online: configuration.runner_online,
            runner_bound: configuration.runner_bound,
            host_resumable: configuration.host_resumable,
            parent_id: configuration.parent_id,
            routing_mode: configuration.routing_mode,
            approval_mode: configuration.approval_mode,
            git_branch: configuration.git_branch,
        }
    }
}

impl From<SessionConfiguration> for core::SessionConfiguration {
    fn from(configuration: SessionConfiguration) -> Self {
        Self {
            agent_id: configuration.agent_id,
            harness: configuration.harness,
            wrapper: configuration.wrapper,
            model_override: configuration.model_override,
            base_model: configuration.base_model,
            effort: configuration.effort,
            model_reported: configuration.model_reported,
            effort_reported: configuration.effort_reported,
            models: configuration.models.into_iter().map(Into::into).collect(),
            host_id: configuration.host_id,
            host_online: configuration.host_online,
            runner_online: configuration.runner_online,
            runner_bound: configuration.runner_bound,
            host_resumable: configuration.host_resumable,
            parent_id: configuration.parent_id,
            routing_mode: configuration.routing_mode,
            approval_mode: configuration.approval_mode,
            git_branch: configuration.git_branch,
        }
    }
}

impl From<core::ConfigurationEdit> for ConfigurationEdit {
    fn from(edit: core::ConfigurationEdit) -> Self {
        Self {
            baseline: edit.baseline.into(),
            model: edit.model,
            effort: edit.effort,
        }
    }
}

impl From<ConfigurationEdit> for core::ConfigurationEdit {
    fn from(edit: ConfigurationEdit) -> Self {
        Self {
            baseline: edit.baseline.into(),
            model: edit.model,
            effort: edit.effort,
        }
    }
}

impl From<core::HarnessChoice> for HarnessChoice {
    fn from(choice: core::HarnessChoice) -> Self {
        Self {
            title: choice.title(),
            preserves_history: choice.preserves_history(),
            id: choice.id,
            name: choice.name,
            harness: choice.harness,
            builtin: choice.builtin,
        }
    }
}

impl From<HarnessChoice> for core::HarnessChoice {
    fn from(choice: HarnessChoice) -> Self {
        Self {
            id: choice.id,
            name: choice.name,
            harness: choice.harness,
            builtin: choice.builtin,
        }
    }
}

impl From<omnigent_core::creation::HarnessReadiness> for HarnessReadiness {
    fn from(readiness: omnigent_core::creation::HarnessReadiness) -> Self {
        use omnigent_core::creation::HarnessReadiness as R;
        match readiness {
            R::Ready => Self::Ready,
            R::NotReady => Self::NotReady,
            R::NeedsAuthentication => Self::NeedsAuthentication,
            R::Unknown => Self::Unknown,
        }
    }
}

impl From<HarnessReadiness> for omnigent_core::creation::HarnessReadiness {
    fn from(readiness: HarnessReadiness) -> Self {
        match readiness {
            HarnessReadiness::Ready => Self::Ready,
            HarnessReadiness::NotReady => Self::NotReady,
            HarnessReadiness::NeedsAuthentication => Self::NeedsAuthentication,
            HarnessReadiness::Unknown => Self::Unknown,
        }
    }
}

type Harnesses = std::collections::BTreeMap<String, omnigent_core::creation::HarnessReadiness>;

pub(crate) fn harness_statuses(harnesses: Harnesses) -> Vec<HarnessStatus> {
    harnesses
        .into_iter()
        .map(|(harness, readiness)| HarnessStatus {
            harness,
            readiness: readiness.into(),
        })
        .collect()
}

pub(crate) fn harness_map(statuses: Vec<HarnessStatus>) -> Harnesses {
    statuses
        .into_iter()
        .map(|status| (status.harness, status.readiness.into()))
        .collect()
}

impl From<core::ConfigurationHost> for ConfigurationHost {
    fn from(host: core::ConfigurationHost) -> Self {
        Self {
            host_id: host.host_id,
            name: host.name,
            status: host.status,
            configured_harnesses: host.configured_harnesses.map(harness_statuses),
        }
    }
}

impl From<ConfigurationHost> for core::ConfigurationHost {
    fn from(host: ConfigurationHost) -> Self {
        Self {
            host_id: host.host_id,
            name: host.name,
            status: host.status,
            configured_harnesses: host.configured_harnesses.map(harness_map),
        }
    }
}

impl From<core::ConfigurationCatalog> for ConfigurationCatalog {
    fn from(catalog: core::ConfigurationCatalog) -> Self {
        Self {
            agents: catalog.agents.into_iter().map(Into::into).collect(),
            host: catalog.host.map(Into::into),
            model_options: catalog.model_options.into_iter().map(Into::into).collect(),
            model_options_error: catalog.model_options_error,
            model_options_identity: catalog.model_options_identity.map(Into::into),
        }
    }
}

impl From<ConfigurationCatalog> for core::ConfigurationCatalog {
    fn from(catalog: ConfigurationCatalog) -> Self {
        Self {
            agents: catalog.agents.into_iter().map(Into::into).collect(),
            host: catalog.host.map(Into::into),
            model_options: catalog.model_options.into_iter().map(Into::into).collect(),
            model_options_error: catalog.model_options_error,
            model_options_identity: catalog.model_options_identity.map(Into::into),
        }
    }
}

/// The display labels of `configuration`.
#[must_use]
#[uniffi::export]
pub fn configuration_labels(configuration: SessionConfiguration) -> ConfigurationLabels {
    let configuration = core::SessionConfiguration::from(configuration);
    ConfigurationLabels {
        harness: configuration.harness_label(),
        model: configuration.model_label(),
        effort: configuration.effort_label(),
        identity: configuration.identity_label(),
    }
}

/// The efforts selectable with `model` (`None`: the runner's default model). Empty when the
/// wrapper does not forward effort changes.
#[must_use]
#[uniffi::export]
pub fn configuration_efforts(
    configuration: SessionConfiguration,
    model: Option<String>,
) -> Vec<String> {
    core::SessionConfiguration::from(configuration).efforts(model.as_deref())
}

/// Whether the harness has a runner-owned model picker.
#[must_use]
#[uniffi::export]
pub fn configuration_supports_models(configuration: SessionConfiguration) -> bool {
    core::SessionConfiguration::from(configuration).supports_models()
}

/// Whether a message sent mid-turn steers the running turn (otherwise it waits for the turn).
#[must_use]
#[uniffi::export]
pub fn configuration_supports_steering(configuration: SessionConfiguration) -> bool {
    core::SessionConfiguration::from(configuration).supports_steering()
}

/// Whether the wrapper forwards reasoning-effort changes.
#[must_use]
#[uniffi::export]
pub fn configuration_supports_effort(configuration: SessionConfiguration) -> bool {
    core::SessionConfiguration::from(configuration).supports_effort()
}

/// Why a message cannot run now, or `None` when it can.
#[must_use]
#[uniffi::export]
pub fn execution_unavailable_reason(configuration: SessionConfiguration) -> Option<String> {
    core::SessionConfiguration::from(configuration)
        .execution_unavailable_reason()
        .map(str::to_owned)
}

/// An edit of `baseline` with no changes yet.
#[must_use]
#[uniffi::export]
pub fn configuration_edit(baseline: SessionConfiguration) -> ConfigurationEdit {
    core::ConfigurationEdit::new(baseline.into()).into()
}

/// `edit` with `model` chosen; the effort is cleared only when the new model does not support it.
#[must_use]
#[uniffi::export]
pub fn configuration_select_model(
    edit: ConfigurationEdit,
    model: Option<String>,
) -> ConfigurationEdit {
    let mut edit = core::ConfigurationEdit::from(edit);
    edit.select_model(model);
    edit.into()
}

/// `current` with the catalog's host model preview as its models, when the runner reported none
/// and the preview was fetched for this same selection.
#[must_use]
#[uniffi::export]
pub fn configuration_with_catalog_models(
    catalog: ConfigurationCatalog,
    current: SessionConfiguration,
) -> SessionConfiguration {
    core::ConfigurationCatalog::from(catalog)
        .configuration_by_adding_model_options(&current.into())
        .into()
}

/// Why the session cannot switch to `target` in place, or `None` when it can.
#[must_use]
#[uniffi::export]
pub fn harness_switch_unavailable_reason(
    catalog: ConfigurationCatalog,
    target: HarnessChoice,
    current: SessionConfiguration,
) -> Option<String> {
    core::ConfigurationCatalog::from(catalog).unavailable_reason(&target.into(), &current.into())
}

#[uniffi::export]
impl ClientCore {
    /// A fresh summary (with its configuration) of `session_id` for the settings menus. Also
    /// published as a `SessionListChanged` upsert.
    ///
    /// # Errors
    ///
    /// The read errors, and [`CoreError::Session`] kind `Configuration` when the session's
    /// metadata changed while the read was in flight (the newer state is kept).
    pub async fn configuration_snapshot(
        &self,
        session_id: String,
    ) -> Result<SessionSummary, CoreError> {
        self.sessions()
            .configuration_snapshot(&session_id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// What `session_id` may switch to, its host, and the host's model preview when the runner
    /// reported no models. A failed preview is in `model_options_error`.
    ///
    /// # Errors
    ///
    /// The snapshot, hosts and agents read errors.
    pub async fn configuration_catalog(
        &self,
        session_id: String,
    ) -> Result<ConfigurationCatalog, CoreError> {
        self.sessions()
            .configuration_catalog(&session_id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Applies `edit` to `session_id`: the model first, then the effort, one `PATCH` each. Never
    /// retried; an unclear outcome is `delivery_uncertain`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Busy` while another change is in flight, the guards (`ReadOnly`,
    /// `Archived`, `Busy`, `StreamNotReady`, `Configuration`), `DeliveryUncertain`, and the read
    /// and write errors.
    pub async fn apply_configuration(
        &self,
        session_id: String,
        edit: ConfigurationEdit,
    ) -> Result<SessionSummary, CoreError> {
        self.sessions()
            .apply_configuration(&edit.into(), &session_id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Switches `session_id` in place to the built-in agent `target_id`, keeping its history.
    /// `baseline` is the configuration the user saw.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Busy`, the guards, `Configuration` when the selection moved or the
    /// target cannot be switched to, `DeliveryUncertain` when the acknowledgement does not show it.
    pub async fn switch_harness(
        &self,
        session_id: String,
        target_id: String,
        baseline: SessionConfiguration,
    ) -> Result<SessionSummary, CoreError> {
        self.sessions()
            .switch_harness(&target_id, &baseline.into(), &session_id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}
