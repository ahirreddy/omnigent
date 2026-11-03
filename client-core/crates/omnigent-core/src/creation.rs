//! Session creation: the host and agent catalog, readiness, and selection validation.
//!
//! Port of `NativeLab`'s `SessionCreation.swift`. Everything here is pure; the REST calls
//! (`GET /v1/hosts`, `GET /v1/agents`, `GET /v1/hosts/{id}/filesystem`, model options and
//! `POST /v1/sessions`) are [`crate::ClientCore`] methods in `client::create`.
//!
//! The rules:
//!
//! - Only an explicit `true` readiness for the agent's harness allows creation. `false`, an
//!   unknown value, a missing entry and `"needs-auth"` all block it, the last with a sign-in hint.
//! - Offline hosts and managed-sandbox hosts are unavailable here.
//! - The workspace must be an absolute path, without NUL, and is never guessed.
//! - A model must be one the host advertises for the agent's harness, by its wire value, and not
//!   hidden. Leaving the model unset needs no model catalog at all.

use std::collections::BTreeMap;

use serde_json::{Map, Value};

use crate::client::json::{as_object, opt_object, opt_str, req_str};
use crate::client::sessions::SessionSummary;
use crate::config::session::{ModelChoice, canonical_harness, harness_label};

/// What a host reports for one harness in `configured_harnesses`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HarnessReadiness {
    /// `true`.
    Ready,
    /// `false`.
    NotReady,
    /// `"needs-auth"`: the harness needs a sign-in on the host.
    NeedsAuthentication,
    /// Any other value. Never treated as ready.
    Unknown,
}

impl HarnessReadiness {
    /// Maps one `configured_harnesses` value.
    #[must_use]
    pub fn from_value(value: &Value) -> Self {
        match value {
            Value::Bool(true) => Self::Ready,
            Value::Bool(false) => Self::NotReady,
            Value::String(text) if text == "needs-auth" => Self::NeedsAuthentication,
            _ => Self::Unknown,
        }
    }
}

/// Decodes a `configured_harnesses` object. `Ok(None)` when absent or null.
pub(crate) fn configured_harnesses(
    object: &Map<String, Value>,
) -> Result<Option<BTreeMap<String, HarnessReadiness>>, String> {
    Ok(
        opt_object(object, "configured_harnesses")?.map(|harnesses| {
            harnesses
                .iter()
                .map(|(name, value)| (name.clone(), HarnessReadiness::from_value(value)))
                .collect()
        }),
    )
}

/// One `GET /v1/hosts` row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreationHost {
    /// Host id.
    pub host_id: String,
    /// Display name.
    pub name: String,
    /// `online`, `offline`, ...
    pub status: String,
    /// Set for managed sandbox hosts, which this client cannot create sessions on.
    pub sandbox_provider: Option<String>,
    /// Per-harness readiness, when reported.
    pub configured_harnesses: Option<BTreeMap<String, HarnessReadiness>>,
}

impl CreationHost {
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
            sandbox_provider: opt_str(object, "sandbox_provider")?,
            configured_harnesses: configured_harnesses(object)?,
        })
    }

    /// Online and not a managed sandbox.
    #[must_use]
    pub fn is_available(&self) -> bool {
        self.status == "online" && self.sandbox_provider.is_none()
    }

    fn readiness(&self, harness: &str) -> Option<HarnessReadiness> {
        self.configured_harnesses
            .as_ref()
            .and_then(|harnesses| harnesses.get(harness).copied())
    }
}

/// One `GET /v1/agents` row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreationAgent {
    /// Durable agent id.
    pub id: String,
    /// Display name.
    pub name: String,
    /// Harness as sent (aliases included).
    pub harness: Option<String>,
    /// Description.
    pub description: Option<String>,
}

/// Native harnesses whose wrapper carries chat and approvals through the session API.
const WRAPPED_NATIVE: [&str; 5] = [
    "codex-native",
    "cursor-native",
    "kiro-native",
    "pi-native",
    "opencode-native",
];

/// Non-native harnesses the app can create sessions for.
const CREATABLE: [&str; 5] = ["codex", "claude-sdk", "openai-agents", "pi", "antigravity"];

impl CreationAgent {
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
            description: opt_str(object, "description")?,
        })
    }

    /// The canonical harness id.
    #[must_use]
    pub fn harness_id(&self) -> String {
        canonical_harness(self.harness.as_deref())
    }

    /// The harness display label.
    #[must_use]
    pub fn harness_label(&self) -> String {
        harness_label(self.harness.as_deref())
    }

    /// The `omnigent.wrapper` label for native harnesses with a session-API wrapper.
    #[must_use]
    pub fn wrapper(&self) -> Option<String> {
        let harness = self.harness_id();
        if harness == "claude-native" {
            return Some("claude-code-native-ui".to_owned());
        }
        WRAPPED_NATIVE
            .contains(&harness.as_str())
            .then(|| format!("{harness}-ui"))
    }

    /// Whether this app can create a session for the agent's harness.
    #[must_use]
    pub fn supports_creation(&self) -> bool {
        self.wrapper().is_some() || CREATABLE.contains(&self.harness_id().as_str())
    }

    /// Whether the host can preview models for the agent's harness.
    #[must_use]
    pub fn supports_model_preview(&self) -> bool {
        self.wrapper().is_some()
    }
}

/// A directory offered as a session workspace.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreationWorkspace {
    /// Absolute path.
    pub path: String,
    /// Display name.
    pub name: String,
}

/// What the user chose in the new-session form.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CreationSelection {
    /// Host id.
    pub host_id: String,
    /// Agent id.
    pub agent_id: String,
    /// Workspace path, as typed.
    pub workspace: String,
    /// The model's wire value, or `None` for the harness default.
    pub model: Option<String>,
}

/// Why a session cannot be created, or what happened to a creation request.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CreationError {
    /// The selection cannot be created; nothing was sent.
    #[error("{0}")]
    Unavailable(String),
    /// The server rejected the request (400, 415 or 422) and created nothing.
    #[error("{message}")]
    Rejected {
        /// HTTP status.
        status: u16,
        /// The server's explanation, or a generic one.
        message: String,
    },
    /// The server may have created the session, but confirmation was lost. Never retried.
    #[error(
        "The server may have created this session, but confirmation was lost. Close this form and refresh Sessions before starting another. Your first message has not been sent."
    )]
    Uncertain,
}

/// The hosts and agents a session can be created with.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CreationCatalog {
    /// Hosts, de-duplicated by id.
    pub hosts: Vec<CreationHost>,
    /// Agents, de-duplicated by id.
    pub agents: Vec<CreationAgent>,
}

/// The title limit, in characters.
pub const MAX_TITLE_CHARS: usize = 120;

impl CreationCatalog {
    /// The agent with `agent_id`.
    #[must_use]
    pub fn agent(&self, agent_id: &str) -> Option<&CreationAgent> {
        self.agents.iter().find(|agent| agent.id == agent_id)
    }

    /// Why `agent_id` cannot be created on `host_id`, or `None` when it can.
    #[must_use]
    pub fn unavailable_reason(&self, agent_id: &str, host_id: &str) -> Option<String> {
        let reason = |text: &str| Some(text.to_owned());
        let Some(host) = self.hosts.iter().find(|host| host.host_id == host_id) else {
            return reason("Choose an existing host.");
        };
        if host.sandbox_provider.is_some() {
            return reason("Managed sandbox creation is not available here.");
        }
        if host.status != "online" {
            return reason("Connect this host before starting a session.");
        }
        let Some(agent) = self.agent(agent_id) else {
            return reason("Choose a registered agent.");
        };
        if !agent.supports_creation() {
            return reason("This agent's harness is not supported for creation in this app.");
        }
        let readiness = host
            .readiness(&agent.harness_id())
            .or_else(|| agent.harness.as_deref().and_then(|raw| host.readiness(raw)));
        match readiness {
            Some(HarnessReadiness::Ready) => None,
            Some(HarnessReadiness::NeedsAuthentication) => {
                reason("Sign in to this harness on the host first.")
            }
            None => reason("The host has not reported readiness for this harness."),
            Some(HarnessReadiness::NotReady | HarnessReadiness::Unknown) => {
                reason("Configure this harness on the host before starting a session.")
            }
        }
    }

    /// Checks `selection` against this catalog and the host's advertised `models`.
    ///
    /// # Errors
    ///
    /// [`CreationError::Unavailable`] with the reason.
    pub fn validate(
        &self,
        selection: &CreationSelection,
        models: &[ModelChoice],
    ) -> Result<(), CreationError> {
        if let Some(reason) = self.unavailable_reason(&selection.agent_id, &selection.host_id) {
            return Err(CreationError::Unavailable(reason));
        }
        let path = selection.workspace.trim();
        if !path.starts_with('/') || path.contains('\0') {
            return Err(CreationError::Unavailable(
                "Enter an absolute workspace path beginning with /.".to_owned(),
            ));
        }
        if let Some(model) = &selection.model {
            let previewable = self
                .agent(&selection.agent_id)
                .is_some_and(CreationAgent::supports_model_preview);
            let advertised = models
                .iter()
                .any(|choice| choice.value() == model && choice.hidden != Some(true));
            if !previewable || !advertised {
                return Err(CreationError::Unavailable(
                    "This model is not currently advertised by the selected host.".to_owned(),
                ));
            }
        }
        Ok(())
    }
}

/// What a successful `POST /v1/sessions` returned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreationReceipt {
    /// The created session. A usable id is the acknowledgement, whatever else the body holds.
    pub session_id: String,
    /// The created session's summary, when the body is a snapshot this client can read.
    pub summary: Option<SessionSummary>,
}

/// The `POST /v1/sessions` body for an external-host session: no initial prompt, no harness
/// override and no launch args.
pub(crate) fn creation_body(
    selection: &CreationSelection,
    title: &str,
    agent: &CreationAgent,
) -> Value {
    let mut body = Map::new();
    body.insert("agent_id".into(), Value::String(selection.agent_id.clone()));
    body.insert("host_id".into(), Value::String(selection.host_id.clone()));
    body.insert("host_type".into(), Value::String("external".into()));
    body.insert(
        "workspace".into(),
        Value::String(selection.workspace.trim().to_owned()),
    );
    if !title.is_empty() {
        body.insert("title".into(), Value::String(title.to_owned()));
    }
    if let Some(model) = &selection.model {
        body.insert("model_override".into(), Value::String(model.clone()));
    }
    if let Some(wrapper) = agent.wrapper() {
        let mut labels = Map::new();
        labels.insert("omnigent.ui".into(), Value::String("terminal".into()));
        labels.insert("omnigent.wrapper".into(), Value::String(wrapper));
        body.insert("labels".into(), Value::Object(labels));
    }
    Value::Object(body)
}

/// The `POST /v1/sessions` body for a session on a new sandbox the server provisions: the agent,
/// `host_type: "managed"` and the repositories to clone (`[]` for an empty sandbox). The server
/// mints the sandbox host's id.
pub(crate) fn sandbox_creation_body(
    agent_id: &str,
    title: &str,
    workspaces: &[String],
    agent: &CreationAgent,
) -> Value {
    let mut body = Map::new();
    body.insert("agent_id".into(), Value::String(agent_id.to_owned()));
    body.insert("host_type".into(), Value::String("managed".into()));
    body.insert(
        "workspaces".into(),
        Value::Array(workspaces.iter().cloned().map(Value::String).collect()),
    );
    if !title.is_empty() {
        body.insert("title".into(), Value::String(title.to_owned()));
    }
    if let Some(wrapper) = agent.wrapper() {
        let mut labels = Map::new();
        labels.insert("omnigent.ui".into(), Value::String("terminal".into()));
        labels.insert("omnigent.wrapper".into(), Value::String(wrapper));
        body.insert("labels".into(), Value::Object(labels));
    }
    Value::Object(body)
}

/// The server's explanation for a rejected creation: `error.message`, `detail`, or the joined
/// `detail[].msg` of a validation error, at most 1000 characters.
pub(crate) fn creation_rejection(body: &[u8], status: u16) -> String {
    let fallback =
        || format!("The server rejected session creation (HTTP {status}). Review your choices.");
    let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(body) else {
        return fallback();
    };
    let message = object
        .get("error")
        .and_then(|error| error.get("message"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| {
            object
                .get("detail")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .or_else(|| {
            object.get("detail").and_then(Value::as_array).map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.get("msg").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("; ")
            })
        });
    message
        .filter(|text| !text.is_empty())
        .map_or_else(fallback, |text| text.chars().take(1000).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn selection() -> CreationSelection {
        CreationSelection {
            host_id: "host_a".into(),
            agent_id: "ag_codex".into(),
            workspace: "/work/project".into(),
            model: None,
        }
    }

    fn host(status: &str, harnesses: Option<&[(&str, HarnessReadiness)]>) -> CreationHost {
        CreationHost {
            host_id: "host_a".into(),
            name: "Mac".into(),
            status: status.into(),
            sandbox_provider: None,
            configured_harnesses: harnesses.map(|entries| {
                entries
                    .iter()
                    .map(|(name, readiness)| ((*name).to_owned(), *readiness))
                    .collect()
            }),
        }
    }

    fn agent(id: &str, harness: Option<&str>) -> CreationAgent {
        CreationAgent {
            id: id.into(),
            name: "Custom Codex".into(),
            harness: harness.map(str::to_owned),
            description: None,
        }
    }

    fn catalog() -> CreationCatalog {
        CreationCatalog {
            hosts: vec![host(
                "online",
                Some(&[("codex-native", HarnessReadiness::Ready)]),
            )],
            agents: vec![agent("ag_codex", Some("codex-native"))],
        }
    }

    fn model(id: &str, wire: Option<&str>, hidden: Option<bool>) -> ModelChoice {
        ModelChoice {
            id: id.into(),
            model: wire.map(str::to_owned),
            hidden,
            ..ModelChoice::default()
        }
    }

    #[test]
    fn only_explicit_readiness_allows_creation() {
        for readiness in [
            HarnessReadiness::NotReady,
            HarnessReadiness::Unknown,
            HarnessReadiness::NeedsAuthentication,
        ] {
            let catalog = CreationCatalog {
                hosts: vec![host("online", Some(&[("codex-native", readiness)]))],
                agents: vec![agent("ag_codex", Some("codex-native"))],
            };
            assert!(
                catalog.validate(&selection(), &[]).is_err(),
                "{readiness:?}"
            );
            if readiness == HarnessReadiness::NeedsAuthentication {
                assert!(
                    catalog
                        .unavailable_reason("ag_codex", "host_a")
                        .unwrap()
                        .contains("Sign in")
                );
            }
        }
        assert_eq!(catalog().validate(&selection(), &[]), Ok(()));
        for (value, expected) in [
            (serde_json::json!(true), HarnessReadiness::Ready),
            (serde_json::json!(false), HarnessReadiness::NotReady),
            (
                serde_json::json!("needs-auth"),
                HarnessReadiness::NeedsAuthentication,
            ),
            (serde_json::json!("future"), HarnessReadiness::Unknown),
            (serde_json::json!(1), HarnessReadiness::Unknown),
        ] {
            assert_eq!(HarnessReadiness::from_value(&value), expected, "{value}");
        }
    }

    #[test]
    fn offline_managed_unknown_harness_and_missing_readiness_are_unavailable() {
        let ready = [("codex-native", HarnessReadiness::Ready)];
        let mut managed = host("online", Some(&ready));
        managed.sandbox_provider = Some("modal".into());
        for host in [host("offline", Some(&ready)), managed, host("online", None)] {
            let catalog = CreationCatalog {
                hosts: vec![host],
                agents: catalog().agents,
            };
            assert!(catalog.validate(&selection(), &[]).is_err());
        }
        let unknown = CreationCatalog {
            hosts: catalog().hosts,
            agents: vec![CreationAgent {
                name: "codex-native-ui".into(),
                ..agent("ag_codex", None)
            }],
        };
        assert!(unknown.validate(&selection(), &[]).is_err());
        assert!(!agent("ag_future", Some("future-native")).supports_creation());
    }

    #[test]
    fn workspace_and_model_are_validated_without_guessing() {
        for path in ["", "~/project", "relative", "/work\0project"] {
            let value = CreationSelection {
                workspace: path.into(),
                ..selection()
            };
            assert!(catalog().validate(&value, &[]).is_err(), "{path:?}");
        }
        let mut value = CreationSelection {
            model: Some("wire-value".into()),
            ..selection()
        };
        assert!(catalog().validate(&value, &[]).is_err());
        assert!(
            catalog()
                .validate(&value, &[model("id", Some("wire-value"), Some(true))])
                .is_err()
        );
        assert_eq!(
            catalog().validate(&value, &[model("id", Some("wire-value"), None)]),
            Ok(())
        );
        value.model = Some("id".into());
        assert!(
            catalog()
                .validate(&value, &[model("id", Some("wire-value"), None)])
                .is_err()
        );
    }

    #[test]
    fn canonical_native_aliases_preserve_wrapper_contract() {
        for (harness, wrapper) in [
            ("claude-native", "claude-code-native-ui"),
            ("codex-native", "codex-native-ui"),
            ("native-pi", "pi-native-ui"),
            ("native-cursor", "cursor-native-ui"),
            ("native-kiro", "kiro-native-ui"),
            ("native-opencode", "opencode-native-ui"),
        ] {
            assert_eq!(
                agent("a", Some(harness)).wrapper().as_deref(),
                Some(wrapper),
                "{harness}"
            );
        }
    }

    #[test]
    fn rejection_text_prefers_server_explanations() {
        assert_eq!(
            creation_rejection(br#"{"error":{"message":"workspace does not exist"}}"#, 400),
            "workspace does not exist"
        );
        assert_eq!(
            creation_rejection(br#"{"detail":"bad host"}"#, 422),
            "bad host"
        );
        assert_eq!(
            creation_rejection(br#"{"detail":[{"msg":"a"},{"msg":"b"}]}"#, 422),
            "a; b"
        );
        assert_eq!(
            creation_rejection(b"<html>", 415),
            "The server rejected session creation (HTTP 415). Review your choices."
        );
        let long = format!(r#"{{"detail":"{}"}}"#, "x".repeat(2000));
        assert_eq!(
            creation_rejection(long.as_bytes(), 400).chars().count(),
            1000
        );
    }
}
