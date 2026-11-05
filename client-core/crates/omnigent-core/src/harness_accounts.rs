//! Fixing a harness beyond first setup.
//!
//! Which account a host is signed in with, signing in from the app (Codex's device code),
//! switching accounts, updating an outdated harness, and the host's startup command for a
//! harness.
//!
//! Port of the web's `lib/harnessFix.ts`, `pages/settings/HarnessFixDialog.tsx` and the harness
//! details page in `pages/settings/SettingsHarnessesSection.tsx`. The REST calls are
//! [`crate::ClientCore`] methods in `client::harness_setup`.

use std::collections::BTreeMap;

use serde_json::{Map, Value};

use crate::client::json::{as_object, opt_array, opt_bool, opt_object, opt_str, req_str};
use crate::harness_setup::{HarnessAvailability, SetupFeatures, SetupHost, availability_map};

/// A provider a harness account uses (`harness_accounts[*].providers[]`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountProvider {
    /// Provider id.
    pub id: String,
    /// Display label.
    pub label: String,
    /// `api_key`, `oauth`, ...
    pub auth_type: String,
}

/// The non-secret account a harness is signed in with on a host (`harness_accounts[key]`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HarnessAccount {
    /// `none`, `chatgpt`, `api_key`, `subscription`, `providers` or `unknown`.
    pub kind: String,
    /// Account email.
    pub email: Option<String>,
    /// Organization.
    pub org: Option<String>,
    /// Plan.
    pub plan: Option<String>,
    /// Providers, for `providers` accounts.
    pub providers: Vec<AccountProvider>,
    /// The sign-in expired.
    pub expired: bool,
}

impl HarnessAccount {
    /// Decodes one account.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "harness account")?;
        let providers = opt_array(object, "providers")?
            .map(|rows| {
                rows.iter()
                    .map(|row| {
                        let row = as_object(row, "provider")?;
                        Ok(AccountProvider {
                            id: opt_str(row, "id")?.unwrap_or_default(),
                            label: opt_str(row, "label")?.unwrap_or_default(),
                            auth_type: opt_str(row, "auth_type")?.unwrap_or_default(),
                        })
                    })
                    .collect::<Result<Vec<_>, String>>()
            })
            .transpose()?
            .unwrap_or_default();
        Ok(Self {
            kind: opt_str(object, "kind")?.unwrap_or_else(|| "unknown".to_owned()),
            email: non_empty(opt_str(object, "email")?),
            org: non_empty(opt_str(object, "org")?),
            plan: non_empty(opt_str(object, "plan")?),
            providers,
            expired: opt_bool(object, "expired")?.unwrap_or(false),
        })
    }

    /// `email · org · plan`, or `Signed in` with none of them.
    #[must_use]
    pub fn details(&self) -> String {
        let parts = [&self.email, &self.org, &self.plan];
        joined(&parts).unwrap_or_else(|| "Signed in".to_owned())
    }

    /// `email · plan`, as the sign-in confirmation and the switch prompt name the account.
    #[must_use]
    pub fn identity(&self) -> Option<String> {
        joined(&[&self.email, &self.plan])
    }
}

fn non_empty(value: Option<String>) -> Option<String> {
    value.filter(|text| !text.trim().is_empty())
}

fn joined(parts: &[&Option<String>]) -> Option<String> {
    let parts: Vec<&str> = parts.iter().filter_map(|part| part.as_deref()).collect();
    (!parts.is_empty()).then(|| parts.join(" \u{b7} "))
}

/// A `harness_accounts` object; `None` when absent or null.
///
/// # Errors
///
/// A description when it or an account has the wrong shape.
pub fn account_map(
    object: &Map<String, Value>,
) -> Result<Option<BTreeMap<String, HarnessAccount>>, String> {
    opt_object(object, "harness_accounts")?
        .map(|accounts| {
            accounts
                .iter()
                .map(|(key, value)| Ok((key.clone(), HarnessAccount::from_value(value)?)))
                .collect()
        })
        .transpose()
}

/// A `gateway_inference` object; `None` when absent or null.
///
/// # Errors
///
/// A description when it is not an object.
pub fn gateway_map(object: &Map<String, Value>) -> Result<Option<BTreeMap<String, bool>>, String> {
    Ok(opt_object(object, "gateway_inference")?.map(|map| {
        map.iter()
            .filter_map(|(key, value)| value.as_bool().map(|flag| (key.clone(), flag)))
            .collect()
    }))
}

/// The key a harness's account and its login routes use: `codex-native` → `codex`.
#[must_use]
pub fn account_key(harness: &str) -> String {
    let canonical = match harness {
        "native-claude" => "claude-native",
        "native-codex" => "codex-native",
        "native-pi" => "pi-native",
        "native-cursor" => "cursor-native",
        "native-antigravity" | "agy-native" | "native-agy" => "antigravity-native",
        other => other,
    };
    canonical
        .strip_suffix("-native")
        .or_else(|| canonical.strip_prefix("native-"))
        .unwrap_or(canonical)
        .to_owned()
}

/// What fixing a harness does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FixMode {
    /// Install it.
    Install,
    /// Install the latest version.
    Update,
    /// Sign in or add a credential.
    Reconfigure,
    /// Sign out and sign in with another account.
    Switch,
}

/// The fix for a harness that is not ready (`harnessFixMode`).
#[must_use]
pub const fn fix_mode(availability: Option<&HarnessAvailability>) -> FixMode {
    match availability {
        Some(HarnessAvailability::VersionTooLow) => FixMode::Update,
        Some(HarnessAvailability::BinaryMissing | HarnessAvailability::NotConfigured) => {
            FixMode::Install
        }
        _ => FixMode::Reconfigure,
    }
}

/// Whether the host can sign the harness out and in again from the app: a Codex `ChatGPT` or a
/// Claude subscription account on a host with the login routes.
#[must_use]
pub fn can_switch_account(host: &SetupHost, harness: &str) -> bool {
    if !host.login_supported {
        return false;
    }
    let key = account_key(harness);
    let kind = host.account(harness).map(|account| account.kind.as_str());
    (key == "codex" && kind == Some("chatgpt")) || (key == "claude" && kind == Some("subscription"))
}

/// Whether the app can run Codex's device-code sign-in on the host.
#[must_use]
pub fn supports_device_login(host: &SetupHost, harness: &str) -> bool {
    host.login_supported && account_key(harness) == "codex"
}

/// The command that signs the harness in with a personal subscription, run on the host; `None`
/// for harnesses without one. `email` (Claude only) picks the account to sign in with.
#[must_use]
pub fn personal_login_command(
    harness: &str,
    configured: Option<&str>,
    email: Option<&str>,
) -> Option<String> {
    let command = match account_key(harness).as_str() {
        "codex" => "codex login --device-auth".to_owned(),
        "claude" => configured
            .unwrap_or("claude auth login --claudeai")
            .to_owned(),
        "pi" => return None,
        _ => configured?.to_owned(),
    };
    match email.map(str::trim).filter(|email| !email.is_empty()) {
        Some(email) if account_key(harness) == "claude" => {
            Some(format!("{command} --email {}", shell_argument(email)))
        }
        _ => Some(command),
    }
}

/// `value` as one POSIX shell word: bare when it is safe, otherwise single-quoted.
#[must_use]
pub fn shell_argument(value: &str) -> String {
    let safe = !value.is_empty()
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "@._+-".contains(c));
    if safe {
        value.to_owned()
    } else {
        format!("'{}'", value.replace('\'', r#"'"'"'"#))
    }
}

/// What the credential row of a harness's details offers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CredentialAction {
    /// Sign out and sign in with another account.
    SwitchAccount,
    /// The sign-in expired: sign in again.
    SignInAgain,
    /// Add a credential or sign in.
    Reconfigure,
}

/// The credential row of a harness's details.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CredentialSummary {
    /// `Personal subscription`, `API key`, `Not signed in`, ...
    pub label: String,
    /// One line about it.
    pub description: String,
    /// A credential problem.
    pub warning: bool,
    /// What the row offers.
    pub action: Option<CredentialAction>,
}

/// The banner over a harness's details when it is not set up or out of date.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessWarning {
    /// What is wrong.
    pub message: String,
    /// The button: Install, Update, Reconfigure or Set Up.
    pub action_label: String,
    /// What the button does.
    pub mode: FixMode,
}

/// One harness's details on one host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessDetail {
    /// Ready.
    pub ready: bool,
    /// The status line: `Configured · you@example.com`, `Needs sign-in`, ...
    pub status: Option<String>,
    /// The fix offered from the details: the app can install and write credentials, and the
    /// host is not a managed sandbox.
    pub can_fix: bool,
    /// The fix for the harness's state.
    pub mode: FixMode,
    /// The banner, when not set up or out of date.
    pub warning: Option<HarnessWarning>,
    /// The credential row.
    pub credential: CredentialSummary,
}

/// The details of `harness` (named `name`) on `host`.
#[must_use]
pub fn harness_detail(
    host: &SetupHost,
    harness: &str,
    name: &str,
    features: &SetupFeatures,
) -> HarnessDetail {
    let availability = host.availability(harness);
    let ready = availability == Some(&HarnessAvailability::Ready);
    let needs_auth = availability == Some(&HarnessAvailability::NeedsAuth);
    let mode = fix_mode(availability);
    let can_fix = features.harness_install && host.sandbox_provider.is_none();
    let installable = crate::harness_setup::installable(features, harness, Some(host));
    let account = host.account(harness);
    let expired = needs_auth && account.is_some_and(|account| account.expired);
    let credential = credential_summary(host, harness, name, needs_auth, expired);
    let action = if ready && can_fix && can_switch_account(host, harness) {
        Some(CredentialAction::SwitchAccount)
    } else if expired && can_fix {
        Some(CredentialAction::SignInAgain)
    } else if needs_auth && can_fix {
        Some(CredentialAction::Reconfigure)
    } else {
        None
    };
    let warning = (availability.is_some() && !ready && !needs_auth).then(|| {
        warning(
            availability.unwrap_or(&HarnessAvailability::NotConfigured),
            mode,
            installable,
            name,
            &host.name,
        )
    });
    let status = availability.map(|availability| {
        if ready {
            configured_account_label(host, harness).map_or_else(
                || "Configured".to_owned(),
                |label| format!("Configured \u{b7} {label}"),
            )
        } else {
            availability.label()
        }
    });
    HarnessDetail {
        ready,
        status,
        can_fix,
        mode,
        warning,
        credential: CredentialSummary {
            action,
            ..credential
        },
    }
}

fn warning(
    availability: &HarnessAvailability,
    mode: FixMode,
    installable: bool,
    name: &str,
    host_name: &str,
) -> HarnessWarning {
    let message = match (availability, mode) {
        (HarnessAvailability::Other(_), _) => {
            format!("{name} isn\u{2019}t working on {host_name}. Run setup again to fix it.")
        }
        (_, FixMode::Update) => format!(
            "{name} is out of date on {host_name}. Update it so new sessions can use {name}."
        ),
        _ => format!(
            "{name} isn\u{2019}t set up on {host_name}, so new sessions can\u{2019}t use {name}."
        ),
    };
    let action_label = match mode {
        _ if !installable => "Set Up",
        FixMode::Update => "Update",
        FixMode::Install => "Install",
        FixMode::Reconfigure | FixMode::Switch => "Reconfigure",
    };
    HarnessWarning {
        message,
        action_label: action_label.to_owned(),
        mode,
    }
}

fn credential_summary(
    host: &SetupHost,
    harness: &str,
    name: &str,
    needs_auth: bool,
    expired: bool,
) -> CredentialSummary {
    let account = host.account(harness);
    let (label, description) = if expired {
        (
            "Sign-in expired".to_owned(),
            format!(
                "{} \u{2014} new sessions on {} can\u{2019}t use {name} until you sign in again.",
                account.map(HarnessAccount::details).unwrap_or_default(),
                host.name
            ),
        )
    } else if needs_auth {
        (
            "Not signed in".to_owned(),
            missing_credential_copy(harness, name, &host.name),
        )
    } else {
        presented_credential(host, harness)
    };
    CredentialSummary {
        label,
        description,
        warning: needs_auth,
        action: None,
    }
}

fn presented_credential(host: &SetupHost, harness: &str) -> (String, String) {
    if host.gateway(harness) == Some(true) {
        return (
            "Isaac".to_owned(),
            "Databricks-managed credential via the Unity Gateway".to_owned(),
        );
    }
    match host.account(harness) {
        Some(account) if account.kind == "providers" => {
            ("Providers".to_owned(), provider_details(account))
        }
        Some(account) if account.kind == "api_key" => (
            "API key".to_owned(),
            "Uses an API key configured on this host".to_owned(),
        ),
        Some(account) if account.kind == "chatgpt" || account.kind == "subscription" => {
            ("Personal subscription".to_owned(), account.details())
        }
        _ => (
            "Signed in".to_owned(),
            "Uses the harness\u{2019}s own login on this host".to_owned(),
        ),
    }
}

fn provider_details(account: &HarnessAccount) -> String {
    if account.providers.is_empty() {
        return "No providers configured".to_owned();
    }
    account
        .providers
        .iter()
        .map(|provider| {
            let auth = provider.auth_type.replace('_', " ");
            let auth = if auth == "api key" {
                "API key".to_owned()
            } else {
                auth
            };
            format!("{} ({auth})", provider.label)
        })
        .collect::<Vec<_>>()
        .join(" \u{b7} ")
}

/// The account a ready harness uses, for its status line: `Isaac`, the providers, or
/// `email · plan`.
#[must_use]
pub fn configured_account_label(host: &SetupHost, harness: &str) -> Option<String> {
    if host.gateway(harness) == Some(true) {
        return Some("Isaac".to_owned());
    }
    let account = host.account(harness)?;
    if account.kind == "providers" {
        let labels: Vec<&str> = account
            .providers
            .iter()
            .map(|provider| provider.label.as_str())
            .collect();
        return (!labels.is_empty()).then(|| labels.join(", "));
    }
    account.identity()
}

/// The missing-credential line for `harness` on `host_name`.
#[must_use]
pub fn missing_credential_copy(harness: &str, name: &str, host_name: &str) -> String {
    let credential = match account_key(harness).as_str() {
        "codex" => "ChatGPT account or API key",
        "claude" => "Claude subscription or API key",
        _ if crate::harness_setup::credential_family(harness).is_some() => {
            "API key or gateway credential"
        }
        _ => "credentials",
    };
    format!("No {credential} on {host_name}, so new sessions can\u{2019}t use {name}.")
}

/// An install's outcome: the host's refreshed readiness and the version installed.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct InstallOutcome {
    /// Readiness, accounts and gateway inference as the host reported them.
    pub snapshot: HostSnapshot,
    /// The installed version, when reported.
    pub version: Option<String>,
}

/// A started device-code sign-in (`POST …/harnesses/{key}/login`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoginStart {
    /// The sign-in id, for polling and cancelling.
    pub login_id: String,
    /// Where the user signs in; always `https`.
    pub verification_url: String,
    /// The one-time code to enter there.
    pub user_code: String,
    /// When the code expires, Unix seconds.
    pub expires_at: i64,
}

/// What starting a device sign-in did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoginStartOutcome {
    /// A new sign-in.
    Started(LoginStart),
    /// Another sign-in is in progress on the host (`409 login_busy`); wait for it.
    Busy {
        /// Its id.
        login_id: String,
    },
}

impl LoginStart {
    /// Decodes a start response; the verification link must be `https`.
    ///
    /// # Errors
    ///
    /// A description of the first missing field, or of an unsafe link.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "login")?;
        let verification_url = req_str(object, "verification_url")?;
        if !is_secure_link(&verification_url) {
            return Err("the host returned an invalid sign-in link".to_owned());
        }
        Ok(Self {
            login_id: req_str(object, "login_id")?,
            verification_url,
            user_code: req_str(object, "user_code")?,
            expires_at: object
                .get("expires_at")
                .and_then(Value::as_i64)
                .ok_or("`expires_at` is missing")?,
        })
    }
}

/// The login id in a `409 login_busy` body (`{code, login_id}`, or nested under `error`).
#[must_use]
pub fn busy_login_id(value: &Value) -> Option<String> {
    let nested = value.get("error").filter(|error| error.is_object());
    let field = |key: &str| {
        nested
            .and_then(|error| error.get(key))
            .or_else(|| value.get(key))
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    (field("code").as_deref() == Some("login_busy"))
        .then(|| field("login_id"))
        .flatten()
        .filter(|id| !id.is_empty())
}

fn is_secure_link(value: &str) -> bool {
    value
        .strip_prefix("https://")
        .and_then(|rest| rest.split(['/', '?', '#']).next())
        .is_some_and(|host| !host.is_empty())
}

/// A device sign-in's state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LoginState {
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

/// A device sign-in's status (`GET …/login/{id}`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoginStatus {
    /// The state.
    pub state: LoginState,
    /// Why it failed.
    pub error: Option<String>,
    /// The host's readiness after it finished, when reported.
    pub snapshot: HostSnapshot,
}

impl LoginStatus {
    /// Decodes a status.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "login status")?;
        let state = match req_str(object, "status")?.as_str() {
            "pending" => LoginState::Pending,
            "succeeded" => LoginState::Succeeded,
            "cancelled" => LoginState::Cancelled,
            "expired" => LoginState::Expired,
            _ => LoginState::Failed,
        };
        Ok(Self {
            state,
            error: non_empty(opt_str(object, "error")?),
            snapshot: HostSnapshot::from_object(object)?,
        })
    }
}

/// A host's harness readiness and accounts as a fix reported them (login, logout, refresh).
/// `None` fields were not reported and keep the current value.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HostSnapshot {
    /// Readiness.
    pub harnesses: Option<BTreeMap<String, HarnessAvailability>>,
    /// Accounts.
    pub accounts: Option<BTreeMap<String, HarnessAccount>>,
    /// Gateway inference.
    pub gateway_inference: Option<BTreeMap<String, bool>>,
}

impl HostSnapshot {
    /// Decodes the readiness fields of a response object.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_object(object: &Map<String, Value>) -> Result<Self, String> {
        Ok(Self {
            harnesses: availability_map(object)?,
            accounts: account_map(object)?,
            gateway_inference: gateway_map(object)?,
        })
    }

    /// Applies what was reported to `host`.
    pub fn apply(&self, host: &mut SetupHost) {
        if let Some(harnesses) = &self.harnesses {
            host.harnesses = Some(harnesses.clone());
        }
        if let Some(accounts) = &self.accounts {
            host.accounts = Some(accounts.clone());
        }
        if let Some(gateway) = &self.gateway_inference {
            host.gateway_inference = Some(gateway.clone());
        }
    }

    /// Whether `harness` is ready in this snapshot.
    #[must_use]
    pub fn is_ready(&self, harness: &str) -> bool {
        self.harnesses
            .as_ref()
            .and_then(|map| map.get(harness))
            .is_some_and(|availability| *availability == HarnessAvailability::Ready)
    }
}

/// A harness's startup command, or why the host does not report it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StartupRead {
    /// The command.
    Loaded(HarnessStartup),
    /// The host does not report it (`404`).
    NotReported,
    /// The host is too old to report it (`501`).
    HostOutdated,
}

/// Where a harness's startup command comes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CommandSource {
    /// `OMNIGENT_<HARNESS>_PATH`.
    Environment,
    /// `harness.<id>` in `~/.omnigent/config.yaml`.
    Config,
    /// The default command.
    Default,
}

/// A harness's startup command on a host (`GET …/harnesses/{harness}/startup`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessStartup {
    /// The command, resolved to its path when found.
    pub command: String,
    /// The executable was found.
    pub found: bool,
    /// Where the command comes from, said for the host.
    pub source: String,
    /// The arguments; `None` when an older host reports only `arg_count`.
    pub args: Option<Vec<String>>,
    /// How many arguments are configured.
    pub arg_count: u64,
    /// Environment overrides, in name order; `None` when the host cannot separate them.
    pub environment: Option<Vec<(String, String)>>,
    /// Whether the session inherits the host's environment.
    pub inherits_environment: bool,
    /// Variables removed before the overrides apply.
    pub unset: Vec<String>,
    /// An older host that reports neither environment nor configured arguments.
    pub host_outdated: bool,
}

impl HarnessStartup {
    /// Decodes a startup response for `harness` on `host_name`.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value, harness: &str, host_name: &str) -> Result<Self, String> {
        let object = as_object(value, "startup")?;
        let command = req_str(object, "command")?;
        let resolved = non_empty(opt_str(object, "resolved_path")?);
        let source = match opt_str(object, "command_source")?.as_deref() {
            Some("env") => CommandSource::Environment,
            Some("config") => CommandSource::Config,
            _ => CommandSource::Default,
        };
        let strings = |key: &str| -> Result<Option<Vec<String>>, String> {
            Ok(opt_array(object, key)?.map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            }))
        };
        let environment = opt_object(object, "environment")?;
        let configured_args = strings("configured_args")?;
        Ok(Self {
            found: resolved.is_some(),
            command: resolved.unwrap_or(command),
            source: source_text(source, harness, host_name),
            args: strings("args")?,
            arg_count: object.get("arg_count").and_then(Value::as_u64).unwrap_or(0),
            environment: environment
                .and_then(|env| env.get("variables"))
                .and_then(Value::as_object)
                .map(|vars| {
                    vars.iter()
                        .map(|(name, value)| {
                            (name.clone(), value.as_str().unwrap_or_default().to_owned())
                        })
                        .collect()
                }),
            inherits_environment: environment
                .and_then(|env| env.get("inherit"))
                .and_then(Value::as_bool)
                .unwrap_or(true),
            unset: environment
                .and_then(|env| env.get("unset"))
                .and_then(Value::as_array)
                .map(|names| {
                    names
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default(),
            host_outdated: environment.is_none() && configured_args.is_none(),
        })
    }
}

fn source_text(source: CommandSource, harness: &str, host_name: &str) -> String {
    match source {
        CommandSource::Environment => {
            let name = harness.strip_suffix("-native").unwrap_or(harness);
            format!("From OMNIGENT_{}_PATH on {host_name}.", name.to_uppercase())
        }
        CommandSource::Config => {
            format!("From harness.{harness} in ~/.omnigent/config.yaml on {host_name}.")
        }
        CommandSource::Default => format!("Default command on {host_name}."),
    }
}

#[cfg(test)]
#[path = "harness_accounts_tests.rs"]
mod tests;
