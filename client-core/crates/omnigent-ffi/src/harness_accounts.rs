//! Fixing a harness beyond first setup: accounts, device sign-in, sign-out, updates and the
//! startup command.
//!
//! The rules are `omnigent_core::harness_accounts`'s; the REST calls are the core client's.

use std::collections::BTreeMap;

use omnigent_core::harness_accounts as core;
use omnigent_core::harness_setup as setup;

use crate::client::ClientCore;
use crate::errors::CoreError;
use crate::harness_setup::{HarnessAvailabilityEntry, HarnessSetupCatalog, SetupHost, entries};

/// A provider a harness account uses.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessAccountProvider {
    /// Provider id.
    pub id: String,
    /// Display label.
    pub label: String,
    /// `api_key`, `oauth`, ...
    pub auth_type: String,
}

/// The non-secret account a harness is signed in with on a host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessAccount {
    /// `none`, `chatgpt`, `api_key`, `subscription`, `providers` or `unknown`.
    pub kind: String,
    /// Email.
    pub email: Option<String>,
    /// Organization.
    pub org: Option<String>,
    /// Plan.
    pub plan: Option<String>,
    /// Providers.
    pub providers: Vec<HarnessAccountProvider>,
    /// The sign-in expired.
    pub expired: bool,
    /// `email · plan`, as prompts name the account.
    pub identity: Option<String>,
}

impl From<core::HarnessAccount> for HarnessAccount {
    fn from(account: core::HarnessAccount) -> Self {
        Self {
            identity: account.identity(),
            kind: account.kind,
            email: account.email,
            org: account.org,
            plan: account.plan,
            providers: account
                .providers
                .into_iter()
                .map(|provider| HarnessAccountProvider {
                    id: provider.id,
                    label: provider.label,
                    auth_type: provider.auth_type,
                })
                .collect(),
            expired: account.expired,
        }
    }
}

impl From<HarnessAccount> for core::HarnessAccount {
    fn from(account: HarnessAccount) -> Self {
        Self {
            kind: account.kind,
            email: account.email,
            org: account.org,
            plan: account.plan,
            providers: account
                .providers
                .into_iter()
                .map(|provider| core::AccountProvider {
                    id: provider.id,
                    label: provider.label,
                    auth_type: provider.auth_type,
                })
                .collect(),
            expired: account.expired,
        }
    }
}

/// One account, by account key (`codex`, `claude`, ...).
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessAccountEntry {
    /// The account key.
    pub key: String,
    /// The account.
    pub account: HarnessAccount,
}

/// Whether one harness's inference goes through a gateway.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct GatewayInferenceEntry {
    /// The harness id.
    pub harness: String,
    /// Through a gateway.
    pub enabled: bool,
}

pub(crate) fn account_entries(
    map: BTreeMap<String, core::HarnessAccount>,
) -> Vec<HarnessAccountEntry> {
    map.into_iter()
        .map(|(key, account)| HarnessAccountEntry {
            key,
            account: account.into(),
        })
        .collect()
}

pub(crate) fn account_map(
    entries: Vec<HarnessAccountEntry>,
) -> BTreeMap<String, core::HarnessAccount> {
    entries
        .into_iter()
        .map(|entry| (entry.key, entry.account.into()))
        .collect()
}

pub(crate) fn gateway_entries(map: BTreeMap<String, bool>) -> Vec<GatewayInferenceEntry> {
    map.into_iter()
        .map(|(harness, enabled)| GatewayInferenceEntry { harness, enabled })
        .collect()
}

/// What fixing a harness does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum HarnessFixMode {
    /// Install it.
    Install,
    /// Install the latest version.
    Update,
    /// Sign in or add a credential.
    Reconfigure,
    /// Sign out and sign in with another account.
    Switch,
}

impl From<core::FixMode> for HarnessFixMode {
    fn from(mode: core::FixMode) -> Self {
        match mode {
            core::FixMode::Install => Self::Install,
            core::FixMode::Update => Self::Update,
            core::FixMode::Reconfigure => Self::Reconfigure,
            core::FixMode::Switch => Self::Switch,
        }
    }
}

/// What a harness's credential row offers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum HarnessCredentialAction {
    /// Sign out and sign in with another account.
    SwitchAccount,
    /// The sign-in expired: sign in again.
    SignInAgain,
    /// Add a credential or sign in.
    Reconfigure,
}

/// The banner over a harness's details.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessDetailWarning {
    /// What is wrong.
    pub message: String,
    /// The button.
    pub action_label: String,
    /// What it does.
    pub mode: HarnessFixMode,
}

/// One harness's details on one host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessDetail {
    /// The harness id.
    pub harness: String,
    /// Display name.
    pub name: String,
    /// The host's name.
    pub host_name: String,
    /// Ready.
    pub ready: bool,
    /// `Configured · you@example.com`, `Needs sign-in`, ...; `None` when not reported.
    pub status: Option<String>,
    /// Fixes can run from the app.
    pub can_fix: bool,
    /// The fix for the harness's state.
    pub mode: HarnessFixMode,
    /// The banner.
    pub warning: Option<HarnessDetailWarning>,
    /// The credential row's label.
    pub credential_label: String,
    /// Its description.
    pub credential_description: String,
    /// A credential problem.
    pub credential_warning: bool,
    /// What the row offers.
    pub credential_action: Option<HarnessCredentialAction>,
    /// The account the harness is signed in with.
    pub account: Option<HarnessAccount>,
    /// The app can run the device-code sign-in on the host.
    pub supports_device_login: bool,
    /// The command that signs in with a personal subscription, when there is one.
    pub personal_login_command: Option<String>,
}

fn find_host(catalog: &HarnessSetupCatalog, host_id: &str) -> Option<setup::SetupHost> {
    catalog
        .hosts
        .iter()
        .find(|host| host.host_id == host_id)
        .cloned()
        .map(Into::into)
}

fn configured_login(catalog: &HarnessSetupCatalog, harness: &str) -> Option<String> {
    catalog
        .harnesses
        .iter()
        .find(|definition| definition.id == harness)?
        .setup_steps
        .iter()
        .find(|step| step.kind == "auth")?
        .command
        .clone()
}

/// The details of `harness` (named `name`) on `host_id`; `None` for an unknown host.
#[must_use]
#[uniffi::export]
pub fn harness_detail(
    catalog: HarnessSetupCatalog,
    harness: String,
    name: String,
    host_id: String,
) -> Option<HarnessDetail> {
    let host = find_host(&catalog, &host_id)?;
    let features = setup::SetupFeatures {
        harness_install: catalog.harness_install,
        installable_harnesses: catalog.installable_harnesses.clone(),
    };
    let detail = core::harness_detail(&host, &harness, &name, &features);
    Some(HarnessDetail {
        harness: harness.clone(),
        name,
        host_name: host.name.clone(),
        ready: detail.ready,
        status: detail.status,
        can_fix: detail.can_fix,
        mode: detail.mode.into(),
        warning: detail.warning.map(|warning| HarnessDetailWarning {
            message: warning.message,
            action_label: warning.action_label,
            mode: warning.mode.into(),
        }),
        credential_label: detail.credential.label,
        credential_description: detail.credential.description,
        credential_warning: detail.credential.warning,
        credential_action: detail.credential.action.map(|action| match action {
            core::CredentialAction::SwitchAccount => HarnessCredentialAction::SwitchAccount,
            core::CredentialAction::SignInAgain => HarnessCredentialAction::SignInAgain,
            core::CredentialAction::Reconfigure => HarnessCredentialAction::Reconfigure,
        }),
        account: host.account(&harness).cloned().map(Into::into),
        supports_device_login: core::supports_device_login(&host, &harness),
        personal_login_command: core::personal_login_command(
            &harness,
            configured_login(&catalog, &harness).as_deref(),
            None,
        ),
    })
}

/// The personal-subscription sign-in command for `harness`, signing in as `email` when given
/// (Claude only); `None` for harnesses without one.
#[must_use]
#[uniffi::export]
pub fn harness_personal_login_command(
    catalog: HarnessSetupCatalog,
    harness: String,
    email: Option<String>,
) -> Option<String> {
    core::personal_login_command(
        &harness,
        configured_login(&catalog, &harness).as_deref(),
        email.as_deref(),
    )
}

/// The readiness, accounts and gateway inference a fix reported; `None` fields were not.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessHostSnapshot {
    /// Readiness.
    pub harnesses: Option<Vec<HarnessAvailabilityEntry>>,
    /// Accounts.
    pub accounts: Option<Vec<HarnessAccountEntry>>,
    /// Gateway inference.
    pub gateway_inference: Option<Vec<GatewayInferenceEntry>>,
}

impl From<core::HostSnapshot> for HarnessHostSnapshot {
    fn from(snapshot: core::HostSnapshot) -> Self {
        Self {
            harnesses: snapshot.harnesses.map(entries),
            accounts: snapshot.accounts.map(account_entries),
            gateway_inference: snapshot.gateway_inference.map(gateway_entries),
        }
    }
}

impl From<HarnessHostSnapshot> for core::HostSnapshot {
    fn from(snapshot: HarnessHostSnapshot) -> Self {
        Self {
            harnesses: snapshot.harnesses.map(|entries| {
                entries
                    .into_iter()
                    .map(|entry| (entry.harness, entry.availability.into()))
                    .collect()
            }),
            accounts: snapshot.accounts.map(account_map),
            gateway_inference: snapshot.gateway_inference.map(|entries| {
                entries
                    .into_iter()
                    .map(|entry| (entry.harness, entry.enabled))
                    .collect()
            }),
        }
    }
}

/// Whether `harness` is ready in `snapshot`.
#[must_use]
#[uniffi::export]
pub fn harness_snapshot_is_ready(snapshot: HarnessHostSnapshot, harness: String) -> bool {
    core::HostSnapshot::from(snapshot).is_ready(&harness)
}

/// `catalog` with what `snapshot` reported applied to `host_id`.
#[must_use]
#[uniffi::export]
pub fn harness_setup_catalog_applying_snapshot(
    catalog: HarnessSetupCatalog,
    host_id: String,
    snapshot: HarnessHostSnapshot,
) -> HarnessSetupCatalog {
    let snapshot = core::HostSnapshot::from(snapshot);
    let mut catalog = catalog;
    if let Some(host) = catalog
        .hosts
        .iter_mut()
        .find(|host| host.host_id == host_id)
    {
        let mut updated = setup::SetupHost::from(host.clone());
        snapshot.apply(&mut updated);
        *host = SetupHost::from(updated);
    }
    catalog
}

/// An install's outcome.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessInstallOutcome {
    /// What the host reported.
    pub snapshot: HarnessHostSnapshot,
    /// The installed version.
    pub version: Option<String>,
}

/// A started device-code sign-in.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessLoginStart {
    /// The sign-in id.
    pub login_id: String,
    /// Where to sign in; always `https`.
    pub verification_url: String,
    /// The one-time code.
    pub user_code: String,
    /// When the code expires, Unix seconds.
    pub expires_at: i64,
}

/// What starting a device sign-in did.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum HarnessLoginStartOutcome {
    /// A new sign-in.
    Started {
        /// It.
        login: HarnessLoginStart,
    },
    /// Another sign-in is in progress; wait for it.
    Busy {
        /// Its id.
        login_id: String,
    },
}

/// A device sign-in's state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum HarnessLoginState {
    /// Waiting for the user.
    Pending,
    /// Signed in.
    Succeeded,
    /// Failed.
    Failed,
    /// Cancelled.
    Cancelled,
    /// The code expired.
    Expired,
}

/// A device sign-in's status.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessLoginStatus {
    /// The state.
    pub state: HarnessLoginState,
    /// Why it failed.
    pub error: Option<String>,
    /// The readiness after it finished, when reported.
    pub snapshot: HarnessHostSnapshot,
}

/// A harness's startup command on a host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessStartup {
    /// The command, resolved to its path when found.
    pub command: String,
    /// The executable was found.
    pub found: bool,
    /// Where the command comes from.
    pub source: String,
    /// The arguments; `None` when the host reports only a count.
    pub args: Option<Vec<String>>,
    /// How many arguments are configured.
    pub arg_count: u64,
    /// Environment overrides as `(name, value)`; `None` when the host cannot separate them.
    pub environment: Option<Vec<HarnessStartupVariable>>,
    /// The session inherits the host's environment.
    pub inherits_environment: bool,
    /// Variables removed before the overrides apply.
    pub unset: Vec<String>,
    /// An older host that reports neither environment nor configured arguments.
    pub host_outdated: bool,
}

/// A harness's startup command, or why the host does not report it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum HarnessStartupRead {
    /// The command.
    Loaded {
        /// It.
        startup: HarnessStartup,
    },
    /// The host does not report it.
    NotReported,
    /// The host is too old to report it.
    HostOutdated,
}

/// One environment override.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct HarnessStartupVariable {
    /// Name.
    pub name: String,
    /// Value.
    pub value: String,
}

impl From<core::HarnessStartup> for HarnessStartup {
    fn from(startup: core::HarnessStartup) -> Self {
        Self {
            command: startup.command,
            found: startup.found,
            source: startup.source,
            args: startup.args,
            arg_count: startup.arg_count,
            environment: startup.environment.map(|variables| {
                variables
                    .into_iter()
                    .map(|(name, value)| HarnessStartupVariable { name, value })
                    .collect()
            }),
            inherits_environment: startup.inherits_environment,
            unset: startup.unset,
            host_outdated: startup.host_outdated,
        }
    }
}

/// This machine's host id in the CLI's `config.yaml` text; `None` before one exists.
#[must_use]
#[uniffi::export]
pub fn host_id_from_cli_config(config_yaml: String) -> Option<String> {
    omnigent_core::session_environment::host_id_from_config(&config_yaml)
}

#[uniffi::export]
impl ClientCore {
    /// Installs or updates `harness` on `host_id`, with the version installed. Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` before any request, and the write errors.
    pub async fn install_harness_reporting(
        &self,
        host_id: String,
        harness: String,
    ) -> Result<HarnessInstallOutcome, CoreError> {
        self.sessions()
            .install_harness_reporting(&host_id, &harness)
            .await
            .map(|outcome| HarnessInstallOutcome {
                snapshot: outcome.snapshot.into(),
                version: outcome.version,
            })
            .map_err(CoreError::from)
    }

    /// Starts Codex's device-code sign-in on `host_id`. Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, `Rejected` (409 when the host cannot sign
    /// in from the app) and the write errors.
    pub async fn start_harness_login(
        &self,
        host_id: String,
        harness: String,
    ) -> Result<HarnessLoginStartOutcome, CoreError> {
        self.sessions()
            .start_harness_login(&host_id, &harness)
            .await
            .map(|outcome| match outcome {
                core::LoginStartOutcome::Started(login) => HarnessLoginStartOutcome::Started {
                    login: HarnessLoginStart {
                        login_id: login.login_id,
                        verification_url: login.verification_url,
                        user_code: login.user_code,
                        expires_at: login.expires_at,
                    },
                },
                core::LoginStartOutcome::Busy { login_id } => {
                    HarnessLoginStartOutcome::Busy { login_id }
                }
            })
            .map_err(CoreError::from)
    }

    /// A device sign-in's status.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors and `MalformedResponse`.
    pub async fn harness_login_status(
        &self,
        host_id: String,
        harness: String,
        login_id: String,
    ) -> Result<HarnessLoginStatus, CoreError> {
        self.sessions()
            .harness_login_status(&host_id, &harness, &login_id)
            .await
            .map(|status| HarnessLoginStatus {
                state: match status.state {
                    core::LoginState::Pending => HarnessLoginState::Pending,
                    core::LoginState::Succeeded => HarnessLoginState::Succeeded,
                    core::LoginState::Failed => HarnessLoginState::Failed,
                    core::LoginState::Cancelled => HarnessLoginState::Cancelled,
                    core::LoginState::Expired => HarnessLoginState::Expired,
                },
                error: status.error,
                snapshot: status.snapshot.into(),
            })
            .map_err(CoreError::from)
    }

    /// Cancels a device sign-in.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` and the write errors.
    pub async fn cancel_harness_login(
        &self,
        host_id: String,
        harness: String,
        login_id: String,
    ) -> Result<(), CoreError> {
        self.sessions()
            .cancel_harness_login(&host_id, &harness, &login_id)
            .await
            .map_err(CoreError::from)
    }

    /// Signs Codex or Claude out on `host_id`. Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` and the write errors.
    pub async fn sign_out_harness(
        &self,
        host_id: String,
        harness: String,
    ) -> Result<HarnessHostSnapshot, CoreError> {
        self.sessions()
            .sign_out_harness(&host_id, &harness)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Asks `host_id` to check its harnesses now, or reads what it last reported.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the write and the read errors.
    pub async fn refresh_harnesses(
        &self,
        host_id: String,
    ) -> Result<HarnessHostSnapshot, CoreError> {
        self.sessions()
            .refresh_harnesses(&host_id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// `harness`'s startup command on `host_id`, or why the host does not report it.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors and `MalformedResponse`.
    pub async fn harness_startup(
        &self,
        host_id: String,
        harness: String,
        host_name: String,
    ) -> Result<HarnessStartupRead, CoreError> {
        self.sessions()
            .harness_startup(&host_id, &harness, &host_name)
            .await
            .map(|read| match read {
                core::StartupRead::Loaded(startup) => HarnessStartupRead::Loaded {
                    startup: startup.into(),
                },
                core::StartupRead::NotReported => HarnessStartupRead::NotReported,
                core::StartupRead::HostOutdated => HarnessStartupRead::HostOutdated,
            })
            .map_err(CoreError::from)
    }
}
