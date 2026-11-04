//! Harness setup: the checklist, installs, credentials and the Settings inventory.
//!
//! The rules are `omnigent_core::harness_setup`'s; the REST calls are the core client's.

use std::collections::BTreeMap;

use omnigent_core::harness_setup as core;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// What a host reports for one harness.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum HarnessAvailability {
    /// Ready.
    Ready,
    /// Installed, not signed in.
    NeedsAuth,
    /// Not installed.
    BinaryMissing,
    /// Installed but outdated.
    VersionTooLow,
    /// Not set up.
    NotConfigured,
    /// Any other value; never ready.
    Other {
        /// The value as JSON text.
        value: String,
    },
}

impl From<core::HarnessAvailability> for HarnessAvailability {
    fn from(value: core::HarnessAvailability) -> Self {
        match value {
            core::HarnessAvailability::Ready => Self::Ready,
            core::HarnessAvailability::NeedsAuth => Self::NeedsAuth,
            core::HarnessAvailability::BinaryMissing => Self::BinaryMissing,
            core::HarnessAvailability::VersionTooLow => Self::VersionTooLow,
            core::HarnessAvailability::NotConfigured => Self::NotConfigured,
            core::HarnessAvailability::Other(value) => Self::Other { value },
        }
    }
}

impl From<HarnessAvailability> for core::HarnessAvailability {
    fn from(value: HarnessAvailability) -> Self {
        match value {
            HarnessAvailability::Ready => Self::Ready,
            HarnessAvailability::NeedsAuth => Self::NeedsAuth,
            HarnessAvailability::BinaryMissing => Self::BinaryMissing,
            HarnessAvailability::VersionTooLow => Self::VersionTooLow,
            HarnessAvailability::NotConfigured => Self::NotConfigured,
            HarnessAvailability::Other { value } => Self::Other(value),
        }
    }
}

/// One harness's availability on a host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessAvailabilityEntry {
    /// The harness id as the host reported it.
    pub harness: String,
    /// Its availability.
    pub availability: HarnessAvailability,
}

fn entries(map: BTreeMap<String, core::HarnessAvailability>) -> Vec<HarnessAvailabilityEntry> {
    map.into_iter()
        .map(|(harness, availability)| HarnessAvailabilityEntry {
            harness,
            availability: availability.into(),
        })
        .collect()
}

/// One server-authored setup step.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SetupStep {
    /// `install`, `auth`, ...
    pub kind: String,
    /// Title.
    pub title: String,
    /// Detail.
    pub detail: String,
    /// `install`, `command`, `setup`, ...
    pub action: String,
    /// The command to run on the host.
    pub command: Option<String>,
    /// What readiness tracks.
    pub status_key: Option<String>,
}

/// One harness and its setup steps.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessDefinition {
    /// Harness id.
    pub id: String,
    /// Display label.
    pub label: String,
    /// Steps, in order.
    pub setup_steps: Vec<SetupStep>,
}

/// A host for setup.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SetupHost {
    /// Host id.
    pub host_id: String,
    /// Display name.
    pub name: String,
    /// `online`, `offline`, ...
    pub status: String,
    /// Set for managed sandbox hosts.
    pub sandbox_provider: Option<String>,
    /// Per-harness availability; `None` when not reported.
    pub harnesses: Option<Vec<HarnessAvailabilityEntry>>,
}

/// The setup features, the harnesses' steps and the hosts (online first).
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessSetupCatalog {
    /// The server installs harnesses and writes credentials.
    pub harness_install: bool,
    /// The ids the install route accepts.
    pub installable_harnesses: Vec<String>,
    /// Harnesses and their steps.
    pub harnesses: Vec<HarnessDefinition>,
    /// Hosts, online first.
    pub hosts: Vec<SetupHost>,
}

impl From<core::HarnessSetupCatalog> for HarnessSetupCatalog {
    fn from(catalog: core::HarnessSetupCatalog) -> Self {
        Self {
            harness_install: catalog.features.harness_install,
            installable_harnesses: catalog.features.installable_harnesses,
            harnesses: catalog
                .harnesses
                .into_iter()
                .map(|definition| HarnessDefinition {
                    id: definition.id,
                    label: definition.label,
                    setup_steps: definition
                        .setup_steps
                        .into_iter()
                        .map(|step| SetupStep {
                            kind: step.kind,
                            title: step.title,
                            detail: step.detail,
                            action: step.action,
                            command: step.command,
                            status_key: step.status_key,
                        })
                        .collect(),
                })
                .collect(),
            hosts: catalog.hosts.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<core::SetupHost> for SetupHost {
    fn from(host: core::SetupHost) -> Self {
        Self {
            host_id: host.host_id,
            name: host.name,
            status: host.status,
            sandbox_provider: host.sandbox_provider,
            harnesses: host.harnesses.map(entries),
        }
    }
}

impl From<SetupHost> for core::SetupHost {
    fn from(host: SetupHost) -> Self {
        Self {
            host_id: host.host_id,
            name: host.name,
            status: host.status,
            sandbox_provider: host.sandbox_provider,
            harnesses: host.harnesses.map(|entries| {
                entries
                    .into_iter()
                    .map(|entry| (entry.harness, entry.availability.into()))
                    .collect()
            }),
        }
    }
}

impl From<HarnessSetupCatalog> for core::HarnessSetupCatalog {
    fn from(catalog: HarnessSetupCatalog) -> Self {
        Self {
            features: core::SetupFeatures {
                harness_install: catalog.harness_install,
                installable_harnesses: catalog.installable_harnesses,
            },
            harnesses: catalog
                .harnesses
                .into_iter()
                .map(|definition| core::HarnessDefinition {
                    id: definition.id,
                    label: definition.label,
                    setup_steps: definition
                        .setup_steps
                        .into_iter()
                        .map(|step| core::SetupStep {
                            kind: step.kind,
                            title: step.title,
                            detail: step.detail,
                            action: step.action,
                            command: step.command,
                            status_key: step.status_key,
                        })
                        .collect(),
                })
                .collect(),
            hosts: catalog.hosts.into_iter().map(Into::into).collect(),
        }
    }
}

/// Whether a step is done.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SetupStepStatus {
    /// Done.
    Done,
    /// To do.
    Todo,
    /// The host cannot tell.
    Unknown,
}

/// What the sheet offers for a step.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SetupStepControl {
    /// Nothing.
    None,
    /// One-click install.
    Install,
    /// The credential form; disabled until installed.
    Credential {
        /// The install step is done.
        enabled: bool,
    },
    /// A command to copy.
    Command {
        /// The command.
        command: String,
    },
}

/// A resolved step.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ResolvedSetupStep {
    /// `install`, `auth`, ...
    pub kind: String,
    /// Title.
    pub title: String,
    /// Detail; past tense once done.
    pub detail: String,
    /// Status.
    pub status: SetupStepStatus,
    /// What the sheet offers.
    pub control: SetupStepControl,
    /// The subscription login command, for the credential form.
    pub command: Option<String>,
}

/// The setup sheet for a harness on a host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessSetupPlan {
    /// The harness id.
    pub harness: String,
    /// The harness display label.
    pub label: String,
    /// The host's name, when known.
    pub host_name: Option<String>,
    /// Steps.
    pub steps: Vec<ResolvedSetupStep>,
    /// Every step is done.
    pub all_done: bool,
    /// Nothing can be done here: say to run `omni setup` on the host.
    pub needs_omni_setup: bool,
}

/// The setup sheet for `harness` on `host_id` from `catalog`.
#[must_use]
#[uniffi::export]
pub fn harness_setup_plan(
    catalog: HarnessSetupCatalog,
    harness: String,
    host_id: String,
) -> HarnessSetupPlan {
    let catalog = core::HarnessSetupCatalog::from(catalog);
    let host = catalog.host(&host_id);
    let definition = catalog.definition(&harness);
    let plan = core::setup_plan(definition, &harness, host, &catalog.features);
    HarnessSetupPlan {
        label: definition.map_or_else(
            || omnigent_core::config::session::harness_label(Some(&harness)),
            |definition| definition.label.clone(),
        ),
        host_name: host.map(|host| host.name.clone()),
        harness: plan.harness,
        all_done: plan.all_done,
        needs_omni_setup: plan.needs_omni_setup,
        steps: plan
            .steps
            .into_iter()
            .map(|step| ResolvedSetupStep {
                kind: step.kind,
                title: step.title,
                detail: step.detail,
                status: match step.status {
                    core::SetupStepStatus::Done => SetupStepStatus::Done,
                    core::SetupStepStatus::Todo => SetupStepStatus::Todo,
                    core::SetupStepStatus::Unknown => SetupStepStatus::Unknown,
                },
                control: match step.control {
                    core::SetupStepControl::None => SetupStepControl::None,
                    core::SetupStepControl::Install => SetupStepControl::Install,
                    core::SetupStepControl::Credential { enabled } => {
                        SetupStepControl::Credential { enabled }
                    }
                    core::SetupStepControl::Command(command) => {
                        SetupStepControl::Command { command }
                    }
                },
                command: step.command,
            })
            .collect(),
    }
}

/// `catalog` with `host_id`'s readiness replaced by an install or credential acknowledgement.
#[must_use]
#[uniffi::export]
pub fn harness_setup_catalog_applying(
    catalog: HarnessSetupCatalog,
    host_id: String,
    harnesses: Vec<HarnessAvailabilityEntry>,
) -> HarnessSetupCatalog {
    let mut catalog = catalog;
    if let Some(host) = catalog
        .hosts
        .iter_mut()
        .find(|host| host.host_id == host_id)
    {
        host.harnesses = Some(harnesses);
    }
    catalog
}

/// One harness row in Settings.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessInventoryRow {
    /// The native harness id.
    pub harness: String,
    /// Display name.
    pub name: String,
    /// One line.
    pub description: String,
    /// Ready on the host.
    pub ready: bool,
    /// Status line; `None` when the host does not report it.
    pub status: Option<String>,
    /// Not ready: offer Set Up.
    pub needs_setup: bool,
}

/// The Settings harness list for `host_id` (every harness; unreported ones neutral).
#[must_use]
#[uniffi::export]
pub fn harness_inventory(
    catalog: HarnessSetupCatalog,
    host_id: String,
) -> Vec<HarnessInventoryRow> {
    let host = catalog
        .hosts
        .into_iter()
        .find(|host| host.host_id == host_id)
        .map(core::SetupHost::from);
    core::inventory(host.as_ref())
        .into_iter()
        .map(|row| HarnessInventoryRow {
            harness: row.harness.harness.to_owned(),
            name: row.harness.name.to_owned(),
            description: row.harness.description.to_owned(),
            ready: row.ready,
            status: row.status,
            needs_setup: row.needs_setup,
        })
        .collect()
}

/// A credential already on a host (non-secret).
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct DetectedCredential {
    /// Provider family.
    pub family: String,
    /// Where it was found.
    pub source: String,
    /// The variable to reference.
    pub env_var: Option<String>,
}

impl From<core::DetectedCredential> for DetectedCredential {
    fn from(credential: core::DetectedCredential) -> Self {
        Self {
            family: credential.family,
            source: credential.source,
            env_var: credential.env_var,
        }
    }
}

/// The detected credential `harness` can adopt, never one of another family.
#[must_use]
#[uniffi::export]
pub fn adoptable_harness_credential(
    harness: String,
    detected: Vec<DetectedCredential>,
) -> Option<DetectedCredential> {
    let detected: Vec<core::DetectedCredential> = detected
        .into_iter()
        .map(|credential| core::DetectedCredential {
            family: credential.family,
            source: credential.source,
            env_var: credential.env_var,
        })
        .collect();
    core::adoptable_credential(&harness, &detected).map(Into::into)
}

/// A credential to write.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum HarnessCredentialInput {
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
    /// A credential already on the host.
    Adopt {
        /// The variable.
        env_var: String,
    },
}

impl From<HarnessCredentialInput> for core::CredentialInput {
    fn from(input: HarnessCredentialInput) -> Self {
        match input {
            HarnessCredentialInput::Key { secret } => Self::Key { secret },
            HarnessCredentialInput::Gateway { base_url, secret } => {
                Self::Gateway { base_url, secret }
            }
            HarnessCredentialInput::Adopt { env_var } => Self::Adopt { env_var },
        }
    }
}

#[uniffi::export]
impl ClientCore {
    /// The setup features, the harnesses' setup steps and the hosts.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn harness_setup_catalog(&self) -> Result<HarnessSetupCatalog, CoreError> {
        self.sessions()
            .harness_setup_catalog()
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Installs `harness` on `host_id`; returns the host's refreshed readiness. Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` before any request, and the write errors.
    pub async fn install_harness(
        &self,
        host_id: String,
        harness: String,
    ) -> Result<Vec<HarnessAvailabilityEntry>, CoreError> {
        self.sessions()
            .install_harness(&host_id, &harness)
            .await
            .map(entries)
            .map_err(CoreError::from)
    }

    /// Writes a credential for `harness` on `host_id`; returns the host's refreshed readiness.
    /// Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` and `InvalidInput` before any request, and
    /// the write errors.
    pub async fn store_harness_credential(
        &self,
        host_id: String,
        harness: String,
        input: HarnessCredentialInput,
    ) -> Result<Vec<HarnessAvailabilityEntry>, CoreError> {
        self.sessions()
            .store_harness_credential(&host_id, &harness, &input.into())
            .await
            .map(entries)
            .map_err(CoreError::from)
    }

    /// The credentials `host_id` already has, for adopting one.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors and `MalformedResponse`.
    pub async fn detected_credentials(
        &self,
        host_id: String,
    ) -> Result<Vec<DetectedCredential>, CoreError> {
        self.sessions()
            .detected_credentials(&host_id)
            .await
            .map(|credentials| credentials.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }
}
