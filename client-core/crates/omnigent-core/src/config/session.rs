//! Session configuration: harness, model and reasoning effort, plus execution readiness.
//!
//! Port of `NativeLab`'s `SessionConfiguration.swift`. A [`SessionConfiguration`] is what one
//! session snapshot (or list row, merged over the previous one) reports about how the session
//! runs; a [`ConfigurationEdit`] is the user's pending model and effort choice against a baseline;
//! a [`ConfigurationCatalog`] is what a harness switch may target.
//!
//! The REST side (snapshot reads, `PATCH` and `switch-agent`) is in `client::configure`.
//!
//! Identifiers are never guessed: a missing harness, model or effort reads "not reported"; an
//! explicit `null` reads "Harness default"; unknown ids stay visible as their raw value.

use std::collections::BTreeMap;

use serde_json::{Map, Value};

use crate::client::json::{as_object, opt_array, opt_bool, opt_str, put_opt, req_str};
use crate::creation::HarnessReadiness;

/// A reasoning effort a model supports.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReasoningChoice {
    /// The effort value, for example `high`.
    pub reasoning_effort: String,
    /// Description.
    pub description: Option<String>,
}

/// One model-picker row (`model_options` and the host model-options route share this shape).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
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
    /// Supported efforts. `None` (not reported) differs from `Some([])` (none supported).
    pub supported_reasoning_efforts: Option<Vec<ReasoningChoice>>,
}

impl ModelChoice {
    /// The picker title: display name, else model, else id.
    #[must_use]
    pub fn title(&self) -> &str {
        self.display_name
            .as_deref()
            .or(self.model.as_deref())
            .unwrap_or(&self.id)
    }

    /// The value sent as `model_override`: the model name, else the id.
    #[must_use]
    pub fn value(&self) -> &str {
        self.model.as_deref().unwrap_or(&self.id)
    }

    /// Whether `value` names this option by id or model. `None` never matches.
    #[must_use]
    pub fn matches(&self, value: Option<&str>) -> bool {
        value.is_some_and(|value| value == self.id || Some(value) == self.model.as_deref())
    }

    /// Decodes one option (camelCase keys, as the server and the saved configuration use).
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "model option")?;
        let supported = opt_array(object, "supportedReasoningEfforts")?
            .map(|values| {
                values
                    .iter()
                    .map(|value| {
                        let object = as_object(value, "reasoning effort")?;
                        Ok(ReasoningChoice {
                            reasoning_effort: req_str(object, "reasoningEffort")?,
                            description: opt_str(object, "description")?,
                        })
                    })
                    .collect::<Result<Vec<_>, String>>()
            })
            .transpose()?;
        Ok(Self {
            id: req_str(object, "id")?,
            model: opt_str(object, "model")?,
            display_name: opt_str(object, "displayName")?,
            description: opt_str(object, "description")?,
            hidden: opt_bool(object, "hidden")?,
            is_default: opt_bool(object, "isDefault")?,
            default_reasoning_effort: opt_str(object, "defaultReasoningEffort")?,
            supported_reasoning_efforts: supported,
        })
    }

    /// The camelCase encoding [`Self::from_value`] reads.
    #[must_use]
    pub fn to_value(&self) -> Value {
        let mut object = Map::new();
        object.insert("id".into(), Value::String(self.id.clone()));
        put_opt(&mut object, "model", self.model.clone().map(Value::String));
        put_opt(
            &mut object,
            "displayName",
            self.display_name.clone().map(Value::String),
        );
        put_opt(
            &mut object,
            "description",
            self.description.clone().map(Value::String),
        );
        put_opt(&mut object, "hidden", self.hidden.map(Value::Bool));
        put_opt(&mut object, "isDefault", self.is_default.map(Value::Bool));
        put_opt(
            &mut object,
            "defaultReasoningEffort",
            self.default_reasoning_effort.clone().map(Value::String),
        );
        put_opt(
            &mut object,
            "supportedReasoningEfforts",
            self.supported_reasoning_efforts.as_ref().map(|choices| {
                Value::Array(
                    choices
                        .iter()
                        .map(|choice| {
                            let mut entry = Map::new();
                            entry.insert(
                                "reasoningEffort".into(),
                                Value::String(choice.reasoning_effort.clone()),
                            );
                            put_opt(
                                &mut entry,
                                "description",
                                choice.description.clone().map(Value::String),
                            );
                            Value::Object(entry)
                        })
                        .collect(),
                )
            }),
        );
        Value::Object(object)
    }
}

/// How one session runs, as last reported.
///
/// `Option<bool>` flags are tri-state: `None` is "not reported", which is never treated as proof
/// either way.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
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
}

/// Shown when a session's host is offline and cannot be woken.
pub const HOST_OFFLINE_REASON: &str = "This session's host is offline. Reconnect that host, or create a new session on a connected host from Sessions. Your draft stays here.";
/// Shown when a session has no execution connection at all.
pub const NO_CONNECTION_REASON: &str = "This session has no execution connection. To chat, go to Sessions, tap New session, and choose a connected host. Your draft stays here.";

/// Native harness ids with a runner-owned model picker.
const MODEL_HARNESSES: [&str; 6] = [
    "codex-native",
    "claude-native",
    "cursor-native",
    "kiro-native",
    "pi-native",
    "opencode-native",
];

/// Claude's effort vocabulary (owned by the server's `reasoning_effort.py`).
const CLAUDE_EFFORTS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];

impl SessionConfiguration {
    /// Why a message cannot run now, or `None` when it can.
    ///
    /// A stopped runner can be relaunched by its connected host or woken on a resumable managed
    /// host. Missing liveness is unknown, not proof that the session cannot run; the one exception
    /// is an unbound native session with no host, which legacy liveness reports as online.
    #[must_use]
    pub fn execution_unavailable_reason(&self) -> Option<&'static str> {
        let has_host = self.host_id.as_deref().is_some_and(|id| !id.is_empty());
        let unbound_native = canonical_harness(self.harness.as_deref()).ends_with("-native")
            && self.runner_bound == Some(false)
            && !has_host;
        if self.runner_online == Some(true) && !unbound_native {
            return None;
        }
        if has_host {
            if self.host_online == Some(true) || self.host_resumable == Some(true) {
                return None;
            }
            return (self.host_online == Some(false)).then_some(HOST_OFFLINE_REASON);
        }
        (unbound_native || self.runner_online == Some(false)).then_some(NO_CONNECTION_REASON)
    }

    /// The harness display label.
    #[must_use]
    pub fn harness_label(&self) -> String {
        harness_label(self.harness.as_deref())
    }

    /// The override, else the base model.
    #[must_use]
    pub fn effective_model(&self) -> Option<&str> {
        self.model_override
            .as_deref()
            .or(self.base_model.as_deref())
    }

    /// The model display label.
    #[must_use]
    pub fn model_label(&self) -> String {
        if self.routing_mode.as_deref() == Some("on") {
            return "Smart routing".to_owned();
        }
        let Some(value) = self.effective_model() else {
            return if self.model_reported == Some(true) {
                "Harness default".to_owned()
            } else {
                "Model not reported".to_owned()
            };
        };
        self.models
            .iter()
            .find(|choice| choice.matches(Some(value)))
            .map_or_else(|| value.to_owned(), |choice| choice.title().to_owned())
    }

    /// `"<harness> · <model>"`.
    #[must_use]
    pub fn identity_label(&self) -> String {
        format!("{} · {}", self.harness_label(), self.model_label())
    }

    /// The effort display label.
    #[must_use]
    pub fn effort_label(&self) -> String {
        self.effort.as_deref().map_or_else(
            || {
                if self.effort_reported == Some(true) {
                    "Harness default".to_owned()
                } else {
                    "Not reported".to_owned()
                }
            },
            capitalized,
        )
    }

    /// The harness has a runner-owned model picker.
    #[must_use]
    pub fn supports_models(&self) -> bool {
        MODEL_HARNESSES.contains(&canonical_harness(self.harness.as_deref()).as_str())
    }

    /// The wrapper forwards reasoning-effort changes.
    #[must_use]
    pub fn supports_effort(&self) -> bool {
        matches!(
            self.wrapper.as_deref(),
            Some("codex-native-ui" | "claude-code-native-ui")
        )
    }

    /// The efforts selectable with `model` (`None` = the runner's default model, not the agent
    /// spec's base model).
    #[must_use]
    pub fn efforts(&self, model: Option<&str>) -> Vec<String> {
        if !self.supports_effort() {
            return Vec::new();
        }
        let option = model.map_or_else(
            || {
                self.models
                    .iter()
                    .find(|choice| choice.is_default == Some(true))
            },
            |model| {
                self.models
                    .iter()
                    .find(|choice| choice.matches(Some(model)))
            },
        );
        if let Some(values) = option.and_then(|choice| choice.supported_reasoning_efforts.as_ref())
        {
            let mut efforts: Vec<String> = Vec::new();
            for value in values {
                if !efforts.contains(&value.reasoning_effort) {
                    efforts.push(value.reasoning_effort.clone());
                }
            }
            return efforts;
        }
        if self.wrapper.as_deref() == Some("claude-code-native-ui") {
            return CLAUDE_EFFORTS
                .iter()
                .map(|&effort| effort.to_owned())
                .collect();
        }
        Vec::new()
    }

    /// Whether the selection-relevant fields equal `other`'s (catalogs and liveness excluded).
    #[must_use]
    pub fn same_selection(&self, other: &Self) -> bool {
        self.agent_id == other.agent_id
            && self.harness == other.harness
            && self.wrapper == other.wrapper
            && self.model_override == other.model_override
            && self.base_model == other.base_model
            && self.effort == other.effort
            && self.routing_mode == other.routing_mode
            && self.host_id == other.host_id
    }

    /// The saved (camelCase) encoding, as `NativeLab` persisted it.
    #[must_use]
    pub fn to_value(&self) -> Value {
        let mut object = Map::new();
        let string = |value: &Option<String>| value.clone().map(Value::String);
        put_opt(&mut object, "agentID", string(&self.agent_id));
        put_opt(&mut object, "harness", string(&self.harness));
        put_opt(&mut object, "wrapper", string(&self.wrapper));
        put_opt(&mut object, "modelOverride", string(&self.model_override));
        put_opt(&mut object, "baseModel", string(&self.base_model));
        put_opt(&mut object, "effort", string(&self.effort));
        put_opt(
            &mut object,
            "modelReported",
            self.model_reported.map(Value::Bool),
        );
        put_opt(
            &mut object,
            "effortReported",
            self.effort_reported.map(Value::Bool),
        );
        object.insert(
            "models".into(),
            Value::Array(self.models.iter().map(ModelChoice::to_value).collect()),
        );
        put_opt(&mut object, "hostID", string(&self.host_id));
        put_opt(&mut object, "hostOnline", self.host_online.map(Value::Bool));
        put_opt(
            &mut object,
            "runnerOnline",
            self.runner_online.map(Value::Bool),
        );
        put_opt(
            &mut object,
            "runnerBound",
            self.runner_bound.map(Value::Bool),
        );
        put_opt(
            &mut object,
            "hostResumable",
            self.host_resumable.map(Value::Bool),
        );
        put_opt(&mut object, "parentID", string(&self.parent_id));
        put_opt(&mut object, "routingMode", string(&self.routing_mode));
        Value::Object(object)
    }

    /// Decodes [`Self::to_value`]'s encoding. Every key is optional, so older saved
    /// configurations (without `modelReported`, `effortReported` or `hostResumable`) still load.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "configuration")?;
        Ok(Self {
            agent_id: opt_str(object, "agentID")?,
            harness: opt_str(object, "harness")?,
            wrapper: opt_str(object, "wrapper")?,
            model_override: opt_str(object, "modelOverride")?,
            base_model: opt_str(object, "baseModel")?,
            effort: opt_str(object, "effort")?,
            model_reported: opt_bool(object, "modelReported")?,
            effort_reported: opt_bool(object, "effortReported")?,
            models: opt_array(object, "models")?
                .map(|values| values.iter().map(ModelChoice::from_value).collect())
                .transpose()?
                .unwrap_or_default(),
            host_id: opt_str(object, "hostID")?,
            host_online: opt_bool(object, "hostOnline")?,
            runner_online: opt_bool(object, "runnerOnline")?,
            runner_bound: opt_bool(object, "runnerBound")?,
            host_resumable: opt_bool(object, "hostResumable")?,
            parent_id: opt_str(object, "parentID")?,
            routing_mode: opt_str(object, "routingMode")?,
        })
    }
}

/// Swift `String.capitalized`: the first letter of each word upper case, the rest lower case;
/// any non-alphanumeric character starts a new word.
fn capitalized(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut at_word_start = true;
    for character in value.chars() {
        if at_word_start {
            result.extend(character.to_uppercase());
        } else {
            result.extend(character.to_lowercase());
        }
        at_word_start = !character.is_alphanumeric();
    }
    result
}

/// The canonical harness id for `value` (aliases folded); empty when not reported.
#[must_use]
pub fn canonical_harness(value: Option<&str>) -> String {
    match value {
        Some("native-codex") => "codex-native",
        Some("native-claude") => "claude-native",
        Some("native-hermes") => "hermes-native",
        Some("native-pi") => "pi-native",
        Some("native-qwen") => "qwen-native",
        Some("native-cursor") => "cursor-native",
        Some("native-kiro") => "kiro-native",
        Some("native-opencode") => "opencode-native",
        Some("native-antigravity") => "antigravity-native",
        Some("claude_sdk") => "claude-sdk",
        Some("agents_sdk" | "openai-agents-sdk") => "openai-agents",
        Some(other) => other,
        None => "",
    }
    .to_owned()
}

/// The harness display label; unknown harnesses show their raw id.
#[must_use]
pub fn harness_label(value: Option<&str>) -> String {
    let label = match canonical_harness(value).as_str() {
        "codex-native" => "Codex",
        "claude-native" => "Claude Code",
        "claude-sdk" => "Claude SDK",
        "openai-agents" => "OpenAI Agents",
        "pi-native" => "Pi",
        "hermes-native" => "Hermes",
        "qwen-native" => "Qwen Code",
        "cursor-native" => "Cursor",
        "kiro-native" => "Kiro",
        "opencode-native" => "OpenCode",
        _ => return value.unwrap_or("Harness not reported").to_owned(),
    };
    label.to_owned()
}

/// The provider family whose settings carry across a harness switch (the backend's
/// carry-settings policy), or `None` for harnesses outside every family.
#[must_use]
pub fn provider_family(harness: Option<&str>) -> Option<&'static str> {
    match canonical_harness(harness).as_str() {
        "codex" | "codex-native" | "openai-agents" | "antigravity" | "qwen" | "qwen-native" => {
            Some("openai")
        }
        "claude-native" | "claude-sdk" => Some("anthropic"),
        "antigravity-native" => Some("gemini"),
        _ => None,
    }
}

/// Why a configuration change cannot be applied.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ConfigurationError {
    /// The session's settings changed after the edit started; review them first.
    #[error(
        "Settings changed elsewhere. Review the current settings before applying your choices."
    )]
    ChangedElsewhere,
    /// The choice is not available now.
    #[error("{0}")]
    Unavailable(String),
}

/// A pending model and effort choice against the configuration it started from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigurationEdit {
    /// The configuration the edit started from.
    pub baseline: SessionConfiguration,
    /// The chosen model override; `None` resets to the harness default.
    pub model: Option<String>,
    /// The chosen effort; `None` resets to the harness default.
    pub effort: Option<String>,
}

impl ConfigurationEdit {
    /// An edit with no changes.
    #[must_use]
    pub fn new(baseline: SessionConfiguration) -> Self {
        Self {
            model: baseline.model_override.clone(),
            effort: baseline.effort.clone(),
            baseline,
        }
    }

    /// Whether the edit differs from its baseline.
    #[must_use]
    pub fn has_changes(&self) -> bool {
        self.model != self.baseline.model_override || self.effort != self.baseline.effort
    }

    /// Chooses `model`, clearing the effort only when the new model does not support it.
    pub fn select_model(&mut self, model: Option<String>) {
        if let Some(effort) = &self.effort
            && !self.baseline.efforts(model.as_deref()).contains(effort)
        {
            self.effort = None;
        }
        self.model = model;
    }

    /// Checks the edit against the session's `current` configuration.
    ///
    /// # Errors
    ///
    /// [`ConfigurationError::ChangedElsewhere`] when the selection moved since the baseline;
    /// [`ConfigurationError::Unavailable`] for a model or effort that is not offered now.
    pub fn validate(&self, current: &SessionConfiguration) -> Result<(), ConfigurationError> {
        if !self.baseline.same_selection(current) {
            return Err(ConfigurationError::ChangedElsewhere);
        }
        let model_changed = self.model != self.baseline.model_override;
        if model_changed {
            let offered = current.supports_models()
                && current.routing_mode.as_deref() != Some("on")
                && !current.models.is_empty()
                && self.model.as_deref().is_none_or(|model| {
                    current
                        .models
                        .iter()
                        .any(|choice| choice.matches(Some(model)) && choice.hidden != Some(true))
                });
            if !offered {
                return Err(ConfigurationError::Unavailable(
                    "This model is not currently advertised by the runner.".to_owned(),
                ));
            }
        }
        if self.effort != self.baseline.effort || (model_changed && self.effort.is_some()) {
            let supported = current.supports_effort()
                && self
                    .effort
                    .as_ref()
                    .is_none_or(|effort| current.efforts(self.model.as_deref()).contains(effort));
            if !supported {
                return Err(ConfigurationError::Unavailable(
                    "This reasoning level is not supported by the selected model.".to_owned(),
                ));
            }
        }
        Ok(())
    }
}

/// A built-in agent a session may switch to (`GET /v1/agents` row).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessChoice {
    /// Agent id.
    pub id: String,
    /// Display name.
    pub name: String,
    /// Harness as sent.
    pub harness: Option<String>,
    /// Built-in agent.
    pub builtin: Option<bool>,
}

/// Harnesses that keep the conversation history through an in-place switch.
const HISTORY_HARNESSES: [&str; 9] = [
    "codex-native",
    "claude-native",
    "pi-native",
    "hermes-native",
    "qwen-native",
    "claude-sdk",
    "openai-agents",
    "codex",
    "antigravity",
];

impl HarnessChoice {
    /// Decodes one agent row.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "agent")?;
        Ok(Self {
            id: req_str(object, "id")?,
            name: opt_str(object, "name")?.unwrap_or_default(),
            harness: opt_str(object, "harness")?,
            builtin: opt_bool(object, "builtin")?,
        })
    }

    /// The harness display label.
    #[must_use]
    pub fn title(&self) -> String {
        harness_label(self.harness.as_deref())
    }

    /// Whether the target harness keeps history through an in-place switch.
    #[must_use]
    pub fn preserves_history(&self) -> bool {
        HISTORY_HARNESSES.contains(&canonical_harness(self.harness.as_deref()).as_str())
    }
}

/// The session's host, as `GET /v1/hosts` reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigurationHost {
    /// Host id.
    pub host_id: String,
    /// Display name.
    pub name: String,
    /// `online`, `offline`, ...
    pub status: String,
    /// Per-harness readiness, when reported.
    pub configured_harnesses: Option<BTreeMap<String, HarnessReadiness>>,
}

impl ConfigurationHost {
    /// Decodes one host row.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "host")?;
        Ok(Self {
            host_id: req_str(object, "host_id")?,
            name: req_str(object, "name")?,
            status: req_str(object, "status")?,
            configured_harnesses: crate::creation::configured_harnesses(object)?,
        })
    }
}

/// What a session's settings sheet can offer: switch targets, the host, and the host's model
/// preview when the runner reported none.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
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

impl ConfigurationCatalog {
    /// `current` with the host preview as its models, only when the runner reported none and the
    /// preview was fetched for this same selection.
    #[must_use]
    pub fn configuration_by_adding_model_options(
        &self,
        current: &SessionConfiguration,
    ) -> SessionConfiguration {
        let applies = current.models.is_empty()
            && self
                .model_options_identity
                .as_ref()
                .is_some_and(|identity| identity.same_selection(current));
        let mut enriched = current.clone();
        if applies {
            enriched.models.clone_from(&self.model_options);
        }
        enriched
    }

    /// Why the session cannot switch to `target` in place, or `None` when it can.
    #[must_use]
    pub fn unavailable_reason(
        &self,
        target: &HarnessChoice,
        current: &SessionConfiguration,
    ) -> Option<String> {
        let reason = |text: &str| Some(text.to_owned());
        let same_harness = target.harness.is_some()
            && canonical_harness(target.harness.as_deref())
                == canonical_harness(current.harness.as_deref());
        if current.agent_id.as_deref() == Some(target.id.as_str()) || same_harness {
            return reason("Current harness");
        }
        if current.parent_id.is_some() {
            return reason("Child sessions cannot switch harness.");
        }
        if target.builtin != Some(true) {
            return reason("Only built-in agents can be selected here.");
        }
        if !target.preserves_history() {
            return reason("This target cannot preserve history during an in-place switch.");
        }
        let Some(host) = self.host.as_ref().filter(|host| {
            Some(host.host_id.as_str()) == current.host_id.as_deref() && host.status == "online"
        }) else {
            return reason("The session's host must be online.");
        };
        let readiness = target.harness.as_deref().and_then(|harness| {
            let harnesses = host.configured_harnesses.as_ref()?;
            harnesses
                .get(&canonical_harness(Some(harness)))
                .or_else(|| harnesses.get(harness))
                .copied()
        });
        match readiness {
            None => reason("Host readiness has not been reported."),
            Some(HarnessReadiness::Ready) => None,
            Some(HarnessReadiness::NeedsAuthentication) => {
                reason("Sign in to this harness on the host first.")
            }
            Some(HarnessReadiness::NotReady | HarnessReadiness::Unknown) => {
                reason("This harness is not configured on the host.")
            }
        }
    }
}

#[cfg(test)]
#[path = "session_tests.rs"]
mod tests;
