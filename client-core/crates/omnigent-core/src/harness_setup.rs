//! Harness setup: what a harness needs on a host, and which steps this app can do for the user.
//!
//! Port of the web's `lib/harnessSetup.ts` and the Settings harness inventory
//! (`pages/settings/SettingsHarnessesSection.tsx`). The steps are the server's
//! (`GET /v1/harnesses` → `setup_steps`); each is marked done or to do from the host's
//! `configured_harnesses` value. Installing and writing a credential are flag-gated server
//! features (`features.harness_install`); without them every step is a command to copy. The
//! REST calls are [`crate::ClientCore`] methods in `client::harness_setup`.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use crate::client::json::{as_object, opt_array, opt_bool, opt_object, opt_str, req_str};
use crate::harness_accounts::{HarnessAccount, account_key, account_map, gateway_map};

/// What a host reports for one harness in `configured_harnesses`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum HarnessAvailability {
    /// `true`.
    Ready,
    /// `"needs-auth"`: installed, not signed in.
    NeedsAuth,
    /// `"binary-missing"`: not installed.
    BinaryMissing,
    /// `"version-too-low"`: installed but outdated.
    VersionTooLow,
    /// `false`: not set up.
    NotConfigured,
    /// `"tmux-unavailable"`: otherwise ready, but the host has no usable tmux for its terminal.
    TmuxUnavailable,
    /// Any other value, as JSON text. Never ready.
    Other(String),
}

impl HarnessAvailability {
    /// Maps one `configured_harnesses` value.
    #[must_use]
    pub fn from_value(value: &Value) -> Self {
        match value {
            Value::Bool(true) => Self::Ready,
            Value::Bool(false) => Self::NotConfigured,
            Value::String(text) => match text.as_str() {
                "needs-auth" => Self::NeedsAuth,
                "binary-missing" => Self::BinaryMissing,
                "version-too-low" => Self::VersionTooLow,
                "tmux-unavailable" => Self::TmuxUnavailable,
                other => Self::Other(other.to_owned()),
            },
            other => Self::Other(other.to_string()),
        }
    }

    /// Not installed: the install step is still to do.
    const fn is_not_installed(&self) -> bool {
        matches!(
            self,
            Self::NotConfigured | Self::BinaryMissing | Self::VersionTooLow
        )
    }

    /// A short status for a harness row: `Configured`, `Not installed`, `Needs sign-in`, ...
    #[must_use]
    pub fn label(&self) -> String {
        match self {
            Self::Ready => "Configured",
            Self::NeedsAuth => "Needs sign-in",
            Self::BinaryMissing | Self::NotConfigured => "Not installed",
            Self::VersionTooLow => "Outdated",
            Self::TmuxUnavailable => "Needs tmux",
            Self::Other(_) => "Needs setup",
        }
        .to_owned()
    }
}

/// Decodes a `configured_harnesses` object; `None` when absent or null.
///
/// # Errors
///
/// A description when it is not an object.
pub fn availability_map(
    object: &Map<String, Value>,
) -> Result<Option<BTreeMap<String, HarnessAvailability>>, String> {
    Ok(
        opt_object(object, "configured_harnesses")?.map(|harnesses| {
            harnesses
                .iter()
                .map(|(name, value)| (name.clone(), HarnessAvailability::from_value(value)))
                .collect()
        }),
    )
}

/// One server-authored setup step (`setup_steps[]`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetupStep {
    /// `install`, `auth`, ...
    pub kind: String,
    /// Title.
    pub title: String,
    /// Detail, future tense ("We'll install ...").
    pub detail: String,
    /// `install` (one click), `command` (run on the host) or `setup` (`omni setup`).
    pub action: String,
    /// The command to run on the host, when there is one.
    pub command: Option<String>,
    /// `installed` or `authed`: what readiness tracks; `None` when the host cannot tell.
    pub status_key: Option<String>,
}

/// One `GET /v1/harnesses` row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessDefinition {
    /// Harness id.
    pub id: String,
    /// Display label.
    pub label: String,
    /// Ordered setup steps.
    pub setup_steps: Vec<SetupStep>,
}

impl HarnessDefinition {
    /// Decodes one `/v1/harnesses` row.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "harness")?;
        let id = req_str(object, "id")?;
        let steps = opt_array(object, "setup_steps")?
            .map(|steps| steps.iter().map(decode_step).collect::<Result<Vec<_>, _>>())
            .transpose()?
            .unwrap_or_default();
        Ok(Self {
            label: opt_str(object, "label")?.unwrap_or_else(|| id.clone()),
            id,
            setup_steps: steps,
        })
    }
}

/// The definitions in a `GET /v1/harnesses` body: the `data` rows, with the top-level
/// `setup_steps` map (keyed by every harness spelling) taking precedence over a row's own steps.
///
/// # Errors
///
/// A description of the first field with the wrong shape.
pub fn harness_definitions(value: &Value) -> Result<Vec<HarnessDefinition>, String> {
    let object = as_object(value, "/v1/harnesses")?;
    let mut definitions = opt_array(object, "data")?
        .ok_or("`data` is missing")?
        .iter()
        .map(HarnessDefinition::from_value)
        .collect::<Result<Vec<_>, _>>()?;
    for (id, steps) in opt_object(object, "setup_steps")?.into_iter().flatten() {
        let steps = steps
            .as_array()
            .ok_or_else(|| format!("`setup_steps.{id}` is not a list"))?
            .iter()
            .map(decode_step)
            .collect::<Result<Vec<_>, _>>()?;
        match definitions
            .iter_mut()
            .find(|definition| definition.id == *id)
        {
            Some(definition) => definition.setup_steps = steps,
            None => definitions.push(HarnessDefinition {
                id: id.clone(),
                label: crate::config::session::harness_label(Some(id)),
                setup_steps: steps,
            }),
        }
    }
    Ok(definitions)
}

fn decode_step(value: &Value) -> Result<SetupStep, String> {
    let object = as_object(value, "setup step")?;
    Ok(SetupStep {
        kind: req_str(object, "kind")?,
        title: opt_str(object, "title")?.unwrap_or_default(),
        detail: opt_str(object, "detail")?.unwrap_or_default(),
        action: opt_str(object, "action")?.unwrap_or_default(),
        command: opt_str(object, "command")?,
        status_key: opt_str(object, "status_key")?,
    })
}

/// The setup fields of `GET /v1/info`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SetupFeatures {
    /// `features.harness_install`: the server installs harnesses and writes credentials.
    pub harness_install: bool,
    /// `installable_harnesses`: the ids the install route accepts.
    pub installable_harnesses: Vec<String>,
}

impl SetupFeatures {
    /// Decodes the setup fields of a `/v1/info` body; missing fields mean unsupported.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "/v1/info")?;
        let harness_install = opt_object(object, "features")?
            .and_then(|features| features.get("harness_install"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let installable_harnesses = opt_array(object, "installable_harnesses")?
            .map(|ids| {
                ids.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        Ok(Self {
            harness_install,
            installable_harnesses,
        })
    }
}

/// A host as the setup sheet and the Settings inventory see it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SetupHost {
    /// Host id.
    pub host_id: String,
    /// Display name.
    pub name: String,
    /// `online`, `offline`, ...
    pub status: String,
    /// Set for managed sandbox hosts.
    pub sandbox_provider: Option<String>,
    /// Per-harness readiness; `None` when the host does not report it.
    pub harnesses: Option<BTreeMap<String, HarnessAvailability>>,
    /// The accounts harnesses are signed in with, by account key; `None` when not reported.
    pub accounts: Option<BTreeMap<String, HarnessAccount>>,
    /// Whether each harness's inference goes through a gateway; `None` when not reported.
    pub gateway_inference: Option<BTreeMap<String, bool>>,
    /// The host signs harnesses in and out from the app (`harness_login_supported`).
    pub login_supported: bool,
}

impl SetupHost {
    /// Decodes one `GET /v1/hosts` row.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "host")?;
        Ok(Self {
            host_id: req_str(object, "host_id")?,
            name: opt_str(object, "name")?.unwrap_or_default(),
            status: opt_str(object, "status")?.unwrap_or_default(),
            sandbox_provider: opt_str(object, "sandbox_provider")?,
            harnesses: availability_map(object)?,
            accounts: account_map(object)?,
            gateway_inference: gateway_map(object)?,
            login_supported: opt_bool(object, "harness_login_supported")?.unwrap_or(false),
        })
    }

    /// Online.
    #[must_use]
    pub fn is_online(&self) -> bool {
        self.status == "online"
    }

    /// What the host reports for `harness`.
    #[must_use]
    pub fn availability(&self, harness: &str) -> Option<&HarnessAvailability> {
        self.harnesses.as_ref()?.get(harness)
    }

    /// The account `harness` is signed in with.
    #[must_use]
    pub fn account(&self, harness: &str) -> Option<&HarnessAccount> {
        self.accounts.as_ref()?.get(&account_key(harness))
    }

    /// Whether `harness`'s inference goes through a gateway; `None` when unknown.
    #[must_use]
    pub fn gateway(&self, harness: &str) -> Option<bool> {
        self.gateway_inference.as_ref()?.get(harness).copied()
    }
}

/// Whether a step is done, still to do, or not something the host can tell.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SetupStepStatus {
    /// Done.
    Done,
    /// To do.
    Todo,
    /// The host cannot tell; shown as an instruction.
    Unknown,
}

/// What the sheet offers for a step.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SetupStepControl {
    /// Nothing (done, or nothing this app can do).
    None,
    /// One-click install.
    Install,
    /// The credential form; disabled until the harness is installed.
    Credential {
        /// The install step is done.
        enabled: bool,
    },
    /// A command to copy and run on the host.
    Command(String),
}

/// A step resolved against a host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedSetupStep {
    /// `install`, `auth`, ...
    pub kind: String,
    /// Title.
    pub title: String,
    /// The detail; past tense once done.
    pub detail: String,
    /// Status.
    pub status: SetupStepStatus,
    /// What the sheet offers.
    pub control: SetupStepControl,
    /// The login command for the credential form's "sign in with your subscription" option.
    pub command: Option<String>,
}

/// The setup sheet for one harness on one host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessSetupPlan {
    /// The harness id.
    pub harness: String,
    /// The steps, in order.
    pub steps: Vec<ResolvedSetupStep>,
    /// Every step is done.
    pub all_done: bool,
    /// No step can be done here: show one "run `omni setup` on the host" line instead.
    pub needs_omni_setup: bool,
}

/// The provider family whose credential this app can write for `harness`, or `None` when it
/// cannot authenticate the harness (Claude → anthropic, Codex → openai, Pi → anthropic).
#[must_use]
pub fn credential_family(harness: &str) -> Option<&'static str> {
    match harness {
        "claude" | "claude-native" | "native-claude" | "pi" | "pi-native" | "native-pi" => {
            Some("anthropic")
        }
        "codex" | "codex-native" | "native-codex" => Some("openai"),
        _ => None,
    }
}

/// The families whose detected credentials `harness` can adopt (Pi takes both).
#[must_use]
pub fn credential_adopt_families(harness: &str) -> Vec<&'static str> {
    match (credential_family(harness), harness) {
        (None, _) => Vec::new(),
        (Some(_), "pi" | "pi-native" | "native-pi") => vec!["anthropic", "openai"],
        (Some(family), _) => vec![family],
    }
}

/// The server installs `harness` on `host` from the app.
#[must_use]
pub fn installable(features: &SetupFeatures, harness: &str, host: Option<&SetupHost>) -> bool {
    features.harness_install
        && features
            .installable_harnesses
            .iter()
            .any(|id| id == harness)
        && host.is_some_and(SetupHost::is_online)
}

/// The app can write a credential for `harness` on `host`.
#[must_use]
pub fn authable(features: &SetupFeatures, harness: &str, host: Option<&SetupHost>) -> bool {
    features.harness_install
        && credential_family(harness).is_some()
        && host.is_some_and(SetupHost::is_online)
}

fn step_status(
    status_key: Option<&str>,
    availability: Option<&HarnessAvailability>,
) -> SetupStepStatus {
    let (Some(key), Some(availability)) = (status_key, availability) else {
        return SetupStepStatus::Unknown;
    };
    match key {
        "installed" if availability.is_not_installed() => SetupStepStatus::Todo,
        "installed" => SetupStepStatus::Done,
        "authed"
            if matches!(
                availability,
                HarnessAvailability::Ready | HarnessAvailability::TmuxUnavailable
            ) =>
        {
            SetupStepStatus::Done
        }
        "authed" => SetupStepStatus::Todo,
        _ => SetupStepStatus::Unknown,
    }
}

fn done_detail(kind: &str) -> &'static str {
    match kind {
        "install" => "Installed on the host.",
        "auth" => "Signed in on the host.",
        _ => "Done.",
    }
}

/// Oldest tmux native terminals accept (`MIN_TMUX_VERSION` in `omnigent/util/tmux_compat.py`).
const MIN_TMUX_VERSION: &str = "3.3";

/// Runs on the host when an install step has no button: the server cannot install there.
const HOST_SETUP_COMMAND: &str = "omni setup";

/// tmux is a host prerequisite with no server step, so it joins the list while it's the blocker.
fn tmux_step() -> SetupStep {
    SetupStep {
        kind: "tmux".to_owned(),
        title: format!("Install tmux {MIN_TMUX_VERSION} or newer"),
        detail: "Native terminals run in tmux on the host. On Linux, use your package manager. \
                 If Omnigent still can't find tmux after you install it, quit and reopen the \
                 Omnigent app."
            .to_owned(),
        action: "command".to_owned(),
        command: Some("brew install tmux".to_owned()),
        status_key: None,
    }
}

/// The setup checklist for `harness` on `host` (the web's `HarnessSetupDialog`).
///
/// Steps the host cannot track are dropped when a trackable one exists. The credential form
/// unlocks once the install step is done, so the checklist runs install, then sign-in.
#[must_use]
pub fn setup_plan(
    definition: Option<&HarnessDefinition>,
    harness: &str,
    host: Option<&SetupHost>,
    features: &SetupFeatures,
) -> HarnessSetupPlan {
    let availability = host.and_then(|host| host.availability(harness));
    let mut steps: Vec<(SetupStep, SetupStepStatus)> = definition
        .map(|definition| {
            definition
                .setup_steps
                .iter()
                .map(|step| {
                    let status = step_status(step.status_key.as_deref(), availability);
                    (step.clone(), status)
                })
                .collect()
        })
        .unwrap_or_default();
    if availability == Some(&HarnessAvailability::TmuxUnavailable) {
        steps.push((tmux_step(), SetupStepStatus::Todo));
    }
    if steps
        .iter()
        .any(|(_, status)| *status != SetupStepStatus::Unknown)
    {
        steps.retain(|(_, status)| *status != SetupStepStatus::Unknown);
    }
    let can_install = installable(features, harness, host);
    let can_auth = authable(features, harness, host);
    let installed = steps
        .iter()
        .all(|(step, status)| step.kind != "install" || *status == SetupStepStatus::Done);
    let resolved: Vec<ResolvedSetupStep> = steps
        .into_iter()
        .map(|(mut step, status)| {
            let done = status == SetupStepStatus::Done;
            // The server's detail promises an install it can't run here, so say what to do.
            let installs_by_hand =
                !done && step.action == "install" && !can_install && step.command.is_none();
            if installs_by_hand {
                step.command = Some(HOST_SETUP_COMMAND.to_owned());
                "Run this on the host to install it.".clone_into(&mut step.detail);
            }
            let control = if done {
                SetupStepControl::None
            } else if step.action == "install" && can_install {
                SetupStepControl::Install
            } else if step.kind == "auth" && can_auth {
                SetupStepControl::Credential { enabled: installed }
            } else {
                step.command
                    .clone()
                    .map_or(SetupStepControl::None, SetupStepControl::Command)
            };
            ResolvedSetupStep {
                detail: if done {
                    done_detail(&step.kind).to_owned()
                } else {
                    step.detail
                },
                kind: step.kind,
                title: step.title,
                status,
                control,
                command: step.command,
            }
        })
        .collect();
    let all_done = !resolved.is_empty()
        && resolved
            .iter()
            .all(|step| step.status == SetupStepStatus::Done);
    let actionable = resolved
        .iter()
        .any(|step| step.control != SetupStepControl::None);
    HarnessSetupPlan {
        harness: harness.to_owned(),
        needs_omni_setup: !all_done && !actionable,
        all_done,
        steps: resolved,
    }
}

/// A credential already on a host, offered for one-click adopt (non-secret).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DetectedCredential {
    /// Provider family, e.g. `anthropic`.
    pub family: String,
    /// Where it was found, e.g. `$ANTHROPIC_API_KEY`.
    pub source: String,
    /// The environment variable to reference.
    pub env_var: Option<String>,
}

impl DetectedCredential {
    /// Decodes one `credentials[]` row.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "credential")?;
        Ok(Self {
            family: opt_str(object, "family")?.unwrap_or_default(),
            source: opt_str(object, "source")?.unwrap_or_default(),
            env_var: opt_str(object, "env_var")?,
        })
    }
}

/// The detected credential `harness` can adopt, never one of another family.
#[must_use]
pub fn adoptable_credential(
    harness: &str,
    detected: &[DetectedCredential],
) -> Option<DetectedCredential> {
    let families = credential_adopt_families(harness);
    detected
        .iter()
        .find(|credential| {
            credential.family != "databricks"
                && credential
                    .env_var
                    .as_deref()
                    .is_some_and(|name| !name.is_empty())
                && families.contains(&credential.family.as_str())
        })
        .cloned()
}

/// A credential to write for a harness on a host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CredentialInput {
    /// An API key.
    Key {
        /// The key.
        secret: String,
    },
    /// An OpenAI-compatible gateway.
    Gateway {
        /// Its base URL.
        base_url: String,
        /// Its key.
        secret: String,
    },
    /// A credential already on the host, by environment variable.
    Adopt {
        /// The variable.
        env_var: String,
    },
}

/// The `POST .../credential` body; `Err` with the reason when a field is blank or the gateway
/// URL is not http(s).
///
/// # Errors
///
/// A user-facing reason; nothing should be sent.
pub fn credential_body(input: &CredentialInput) -> Result<Value, String> {
    let required = |value: &str, what: &str| {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            Err(format!("Enter {what}."))
        } else {
            Ok(trimmed.to_owned())
        }
    };
    match input {
        CredentialInput::Key { secret } => {
            Ok(json!({"kind": "key", "secret": required(secret, "an API key")?}))
        }
        CredentialInput::Gateway { base_url, secret } => {
            let url = required(base_url, "the gateway URL")?;
            let parsed = url::Url::parse(&url).map_err(|_| "Enter a valid gateway URL.")?;
            if !matches!(parsed.scheme(), "http" | "https") {
                return Err("The gateway URL must start with http:// or https://.".to_owned());
            }
            Ok(json!({
                "kind": "gateway",
                "base_url": url,
                "secret": required(secret, "the gateway API key")?,
            }))
        }
        CredentialInput::Adopt { env_var } => Ok(json!({
            "kind": "adopt",
            "env_var": required(env_var, "the variable")?,
        })),
    }
}

/// A native coding harness the Settings inventory lists, in the web's order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InventoryHarness {
    /// The native harness id, the readiness key.
    pub harness: &'static str,
    /// Display name.
    pub name: &'static str,
    /// One line.
    pub description: &'static str,
}

/// The harnesses Settings lists (the web's `NATIVE_CODING_AGENTS`, by its sort rank).
pub const INVENTORY: [InventoryHarness; 12] = [
    InventoryHarness {
        harness: "claude-native",
        name: "Claude Code",
        description: "Anthropic's coding agent for understanding codebases, editing files, and running development workflows.",
    },
    InventoryHarness {
        harness: "codex-native",
        name: "Codex",
        description: "OpenAI's coding agent for building features, fixing bugs, and working across repositories.",
    },
    InventoryHarness {
        harness: "opencode-native",
        name: "OpenCode",
        description: "An open-source coding agent for the terminal, IDE, and desktop.",
    },
    InventoryHarness {
        harness: "devin-native",
        name: "Devin",
        description: "Cognition's autonomous coding agent for end-to-end software tasks.",
    },
    InventoryHarness {
        harness: "cursor-native",
        name: "Cursor",
        description: "An AI code editor with agent workflows for navigating, editing, and shipping code.",
    },
    InventoryHarness {
        harness: "pi-native",
        name: "Pi",
        description: "A minimal, extensible coding agent harness built for terminal workflows.",
    },
    InventoryHarness {
        harness: "antigravity-native",
        name: "Antigravity",
        description: "Google's agent-first development platform for planning and executing software tasks.",
    },
    InventoryHarness {
        harness: "kiro-native",
        name: "Kiro",
        description: "An agentic IDE for spec-driven development, hooks, and production-ready software.",
    },
    InventoryHarness {
        harness: "goose-native",
        name: "Goose",
        description: "An open-source local AI agent for coding, automation, and extensible workflows.",
    },
    InventoryHarness {
        harness: "qwen-native",
        name: "Qwen Code",
        description: "An open-source terminal coding agent powered by Qwen models.",
    },
    InventoryHarness {
        harness: "kimi-native",
        name: "Kimi",
        description: "A terminal coding agent for editing code, running commands, and completing development tasks.",
    },
    InventoryHarness {
        harness: "hermes-native",
        name: "Hermes",
        description: "A self-improving AI agent that learns reusable skills from experience.",
    },
];

/// One harness row in Settings for the selected host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InventoryRow {
    /// The harness.
    pub harness: InventoryHarness,
    /// Ready on the host.
    pub ready: bool,
    /// The status line; `None` when the host does not report this harness.
    pub status: Option<String>,
    /// Not ready and something can be fixed: offer Set Up.
    pub needs_setup: bool,
}

/// The Settings inventory for `host` (every harness, unreported ones neutral).
#[must_use]
pub fn inventory(host: Option<&SetupHost>) -> Vec<InventoryRow> {
    INVENTORY
        .iter()
        .map(|harness| {
            let availability = host.and_then(|host| host.availability(harness.harness));
            let ready = availability == Some(&HarnessAvailability::Ready);
            InventoryRow {
                harness: *harness,
                ready,
                status: availability.map(HarnessAvailability::label),
                needs_setup: availability.is_some() && !ready,
            }
        })
        .collect()
}

/// What the setup sheet and the Settings inventory read.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HarnessSetupCatalog {
    /// Whether the server installs harnesses and writes credentials.
    pub features: SetupFeatures,
    /// The server's harnesses and their setup steps; empty on servers without the route.
    pub harnesses: Vec<HarnessDefinition>,
    /// The hosts, online first.
    pub hosts: Vec<SetupHost>,
}

impl HarnessSetupCatalog {
    /// The definition of `harness`.
    #[must_use]
    pub fn definition(&self, harness: &str) -> Option<&HarnessDefinition> {
        self.harnesses
            .iter()
            .find(|definition| definition.id == harness)
    }

    /// The host `host_id`.
    #[must_use]
    pub fn host(&self, host_id: &str) -> Option<&SetupHost> {
        self.hosts.iter().find(|host| host.host_id == host_id)
    }
}

/// The hosts Settings offers: online first, managed sandboxes last, in the server's order.
#[must_use]
pub fn ordered_hosts(mut hosts: Vec<SetupHost>) -> Vec<SetupHost> {
    hosts.sort_by_key(|host| (!host.is_online(), host.sandbox_provider.is_some()));
    hosts
}

/// The readiness map in an install or credential acknowledgement.
///
/// # Errors
///
/// A description when `configured_harnesses` is missing or not an object.
pub fn acknowledged_availability(
    value: &Value,
) -> Result<BTreeMap<String, HarnessAvailability>, String> {
    let object = as_object(value, "acknowledgement")?;
    availability_map(object)?.ok_or_else(|| "`configured_harnesses` is missing".to_owned())
}

#[cfg(test)]
#[path = "harness_setup_tests.rs"]
mod tests;
