//! Server settings for the native Settings window, over the web `SettingsPage`'s routes.
//!
//! What the server lets the caller manage (`/v1/info`, `/v1/me`), members (`/auth/users`),
//! default policies, sharing, the MCP registry, provider connections, password change and local
//! session import.

use serde_json::{Map, Value, json};

use super::json::{as_object, opt_array, opt_bool, opt_str, opt_u64, req_str};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::creation::CreationHost;
use crate::http::HttpTransport;

/// The `enabled_connections` entry that turns on the MCP registry rather than a provider.
const MCP_CONNECTION: &str = "mcp";
/// Providers whose connection status and disconnect this client handles.
const KNOWN_PROVIDERS: [&str; 2] = ["github", "databricks"];
/// The shortest password the server accepts.
pub const MIN_PASSWORD_CHARS: usize = 8;

/// What the server offers and the caller may manage, from `/v1/info` and `/v1/me`. Missing
/// fields mean unsupported.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "one flag per independent server capability"
)]
pub struct ServerSettingsInfo {
    /// The confirmed user id.
    pub user_id: String,
    /// The caller administers the server (Members, Policies, Sharing).
    pub is_admin: bool,
    /// A single-user server: no other members and no sharing.
    pub single_user: bool,
    /// Password accounts: members can be removed and passwords reset or changed.
    pub accounts_enabled: bool,
    /// The MCP registry is configured (`enabled_connections` lists `mcp`).
    pub mcp_registry: bool,
    /// Provider connections this client can show (`github`, `databricks`), in server order.
    pub connections: Vec<String>,
    /// Archiving can remove a session's git worktree (`archive_worktree_cleanup`).
    pub archive_worktree_cleanup: bool,
    /// Sign-in has a session to end (accounts or SSO; `login_url` is set), so Settings shows
    /// the caller's identity and Sign out.
    pub has_login_session: bool,
}

impl ServerSettingsInfo {
    /// Decodes `/v1/info` and `/v1/me` bodies.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_values(info: &Value, me: &Value) -> Result<Self, String> {
        let info = as_object(info, "/v1/info")?;
        let me = as_object(me, "/v1/me")?;
        let enabled: Vec<String> = string_list(info, "enabled_connections")?;
        Ok(Self {
            user_id: req_str(me, "user_id")?,
            is_admin: opt_bool(me, "is_admin")?.unwrap_or(false),
            single_user: opt_bool(info, "single_user")?.unwrap_or(false),
            accounts_enabled: opt_bool(info, "accounts_enabled")?.unwrap_or(false),
            mcp_registry: enabled.iter().any(|name| name == MCP_CONNECTION),
            connections: enabled
                .into_iter()
                .filter(|name| KNOWN_PROVIDERS.contains(&name.as_str()))
                .collect(),
            archive_worktree_cleanup: opt_bool(info, "archive_worktree_cleanup")?.unwrap_or(false),
            has_login_session: opt_str(info, "login_url")?.is_some_and(|url| !url.is_empty()),
        })
    }
}

/// One account on the server (`GET /auth/users`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Member {
    /// User id (a username or email).
    pub id: String,
    /// An administrator.
    pub is_admin: bool,
    /// Created, Unix seconds.
    pub created_at: Option<i64>,
    /// Last sign-in, Unix seconds.
    pub last_login_at: Option<i64>,
    /// Signs in with a password (it can be reset).
    pub has_password: bool,
}

/// A server-wide default policy (`GET /v1/policies`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DefaultPolicy {
    /// Id; `None` for a policy from the server's config file.
    pub id: Option<String>,
    /// Name.
    pub name: String,
    /// The handler path or URL.
    pub handler: String,
    /// Applies to new sessions.
    pub enabled: bool,
    /// From the config file: read-only here.
    pub from_config: bool,
}

/// Server-wide sharing (`GET /v1/sharing`), each setting with whether it is editable here.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "each setting carries its own editable flag"
)]
pub struct SharingSettings {
    /// `on`, `read_only`, `restricted_read_only` or `off`.
    pub mode: String,
    /// The mode can be changed here.
    pub mode_editable: bool,
    /// Modes, most permissive first.
    pub mode_options: Vec<String>,
    /// Anyone with the link may be granted access.
    pub public_sharing: bool,
    /// Public sharing can be changed here.
    pub public_sharing_editable: bool,
    /// The most a public link grants: `read` or `edit`.
    pub public_max_level: Option<String>,
    /// The public level can be changed here.
    pub public_max_level_editable: bool,
    /// Public levels.
    pub public_max_level_options: Vec<String>,
    /// Which new sessions start public: `off`, `sandbox` or `all`.
    pub default_public_sessions: Option<String>,
    /// The default can be changed here.
    pub default_public_sessions_editable: bool,
    /// Defaults.
    pub default_public_sessions_options: Vec<String>,
}

/// A partial `PUT /v1/sharing`; at least one field must be set.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SharingUpdate {
    /// A new mode.
    pub mode: Option<String>,
    /// Allow or disallow public links.
    pub public_sharing: Option<bool>,
    /// A new public level.
    pub public_max_level: Option<String>,
    /// A new default for new sessions.
    pub default_public_sessions: Option<String>,
}

/// One MCP registry service (`GET /v1/mcp-registry/services`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpService {
    /// Id.
    pub id: String,
    /// Title.
    pub title: String,
    /// Description.
    pub description: Option<String>,
    /// `none`, `bearer`, `oauth`, `github` or `databricks`.
    pub auth: String,
    /// The caller has an account connected (always true for `none`).
    pub connected: bool,
    /// Tools the service offers.
    pub tools: Vec<String>,
}

impl McpService {
    /// The caller can connect with a personal token.
    #[must_use]
    pub fn accepts_token(&self) -> bool {
        self.auth == "bearer"
    }

    /// The caller's own account can be disconnected here (provider accounts are in Integrations).
    #[must_use]
    pub fn can_disconnect(&self) -> bool {
        self.connected && matches!(self.auth.as_str(), "bearer" | "oauth")
    }
}

/// A provider account connection (`GET /v1/connections/{provider}/status`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderConnection {
    /// `github` or `databricks`.
    pub provider: String,
    /// Connected.
    pub connected: bool,
    /// The connected account: a GitHub login, or a Databricks user at its workspace.
    pub account: Option<String>,
}

/// A harness whose local sessions a host can import.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImportSource {
    /// The request value; `all` reads every harness.
    pub id: &'static str,
    /// The display name.
    pub title: &'static str,
}

/// The import sources, as the web's Import sessions panel lists them.
pub const IMPORT_SOURCES: [ImportSource; 8] = [
    ImportSource {
        id: "all",
        title: "All harnesses",
    },
    ImportSource {
        id: "claude",
        title: "Claude Code",
    },
    ImportSource {
        id: "codex",
        title: "Codex",
    },
    ImportSource {
        id: "kimi",
        title: "Kimi",
    },
    ImportSource {
        id: "kiro",
        title: "Kiro",
    },
    ImportSource {
        id: "opencode",
        title: "OpenCode",
    },
    ImportSource {
        id: "pi",
        title: "Pi",
    },
    ImportSource {
        id: "qwen",
        title: "Qwen",
    },
];

/// The most recent sessions one import reads.
pub const MAX_IMPORT_LIMIT: u32 = 1000;
/// The longest harness session id an exact import accepts.
pub const MAX_IMPORT_SESSION_ID_CHARS: usize = 128;

/// What `POST /v1/imports/local` imported.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportResult {
    /// Newly imported.
    pub imported: u64,
    /// Skipped: imported before.
    pub already_imported: u64,
    /// Not imported.
    pub failed: u64,
    /// Why each failure happened.
    pub failures: Vec<String>,
}

fn string_list(object: &Map<String, Value>, key: &str) -> Result<Vec<String>, String> {
    opt_array(object, key)?
        .map(|values| {
            values
                .iter()
                .map(|value| {
                    value
                        .as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| format!("`{key}` holds a non-string"))
                })
                .collect()
        })
        .transpose()
        .map(Option::unwrap_or_default)
}

/// `object[key]` as whole Unix seconds; some stores report fractional seconds.
#[allow(
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    reason = "float-to-int `as` saturates, and whole seconds are all a timestamp label shows"
)]
fn opt_seconds(object: &Map<String, Value>, key: &str) -> Result<Option<i64>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(number)) => Ok(number
            .as_i64()
            .or_else(|| number.as_f64().map(|seconds| seconds.floor() as i64))),
        Some(_) => Err(format!("`{key}` is not a number")),
    }
}

fn member_from(value: &Value) -> Result<Member, String> {
    let object = as_object(value, "user")?;
    Ok(Member {
        id: req_str(object, "id")?,
        is_admin: opt_bool(object, "is_admin")?.unwrap_or(false),
        created_at: opt_seconds(object, "created_at")?,
        last_login_at: opt_seconds(object, "last_login_at")?,
        has_password: opt_bool(object, "has_password")?.unwrap_or(false),
    })
}

fn policy_from(value: &Value) -> Result<DefaultPolicy, String> {
    let object = as_object(value, "policy")?;
    Ok(DefaultPolicy {
        id: opt_str(object, "id")?.filter(|id| !id.is_empty()),
        name: req_str(object, "name")?,
        handler: opt_str(object, "handler")?.unwrap_or_default(),
        enabled: opt_bool(object, "enabled")?.unwrap_or(false),
        from_config: opt_str(object, "source")?.as_deref() == Some("config"),
    })
}

/// Decodes a `/v1/sharing` body.
///
/// # Errors
///
/// A description of the first field with the wrong shape.
pub fn sharing_from(value: &Value) -> Result<SharingSettings, String> {
    let object = as_object(value, "/v1/sharing")?;
    Ok(SharingSettings {
        mode: req_str(object, "sharing_mode")?,
        mode_editable: opt_bool(object, "editable")?.unwrap_or(false),
        mode_options: string_list(object, "options")?,
        public_sharing: opt_bool(object, "public_sharing_enabled")?.unwrap_or(false),
        public_sharing_editable: opt_bool(object, "public_sharing_editable")?.unwrap_or(false),
        public_max_level: opt_str(object, "public_sharing_max_level")?,
        public_max_level_editable: opt_bool(object, "public_sharing_max_level_editable")?
            .unwrap_or(false),
        public_max_level_options: string_list(object, "public_sharing_max_level_options")?,
        default_public_sessions: opt_str(object, "default_public_sessions")?,
        default_public_sessions_editable: opt_bool(object, "default_public_sessions_editable")?
            .unwrap_or(false),
        default_public_sessions_options: string_list(object, "default_public_sessions_options")?,
    })
}

fn mcp_service_from(value: &Value) -> Result<McpService, String> {
    let object = as_object(value, "service")?;
    Ok(McpService {
        id: req_str(object, "id")?,
        title: opt_str(object, "title")?.unwrap_or_default(),
        description: opt_str(object, "description")?.filter(|text| !text.is_empty()),
        auth: opt_str(object, "auth")?.unwrap_or_else(|| "none".to_owned()),
        connected: opt_bool(object, "connected")?.unwrap_or(false),
        tools: string_list(object, "tools")?,
    })
}

fn connection_from(provider: &str, value: &Value) -> Result<ProviderConnection, String> {
    let object = as_object(value, "connection status")?;
    let connected = opt_bool(object, "connected")?.unwrap_or(false);
    let account = match provider {
        "github" => opt_str(object, "login")?,
        _ => match (
            opt_str(object, "databricks_user")?,
            opt_str(object, "workspace_host")?,
        ) {
            (Some(user), Some(host)) => Some(format!("{user} at {host}")),
            (user, host) => user.or(host),
        },
    };
    Ok(ProviderConnection {
        provider: provider.to_owned(),
        connected,
        account: account.filter(|_| connected),
    })
}

/// Decodes a `/v1/imports/local` body.
///
/// # Errors
///
/// A description of the first field with the wrong shape.
pub fn import_result_from(value: &Value) -> Result<ImportResult, String> {
    let object = as_object(value, "/v1/imports/local")?;
    let failures = opt_array(object, "failures")?
        .map(|rows| {
            rows.iter()
                .map(|row| {
                    let row = as_object(row, "failure")?;
                    let reason = req_str(row, "reason")?;
                    Ok(match opt_str(row, "external_session_id")? {
                        Some(id) => format!("{id}: {reason}"),
                        None => reason,
                    })
                })
                .collect::<Result<Vec<_>, String>>()
        })
        .transpose()?
        .unwrap_or_default();
    Ok(ImportResult {
        imported: opt_u64(object, "imported")?.unwrap_or(0),
        already_imported: opt_u64(object, "already_imported")?.unwrap_or(0),
        failed: opt_u64(object, "failed")?.unwrap_or(0),
        failures,
    })
}

/// A user id (a username or email) as one path segment: never a dot segment, and nothing the
/// request URL would read as a separator or escape.
fn user_segment(user_id: &str) -> Result<&str, SessionError> {
    let plain = !user_id.is_empty()
        && user_id != "."
        && user_id != ".."
        && !user_id.chars().any(|character| {
            character.is_whitespace()
                || character.is_control()
                || matches!(character, '/' | '?' | '#' | '%' | '\\')
        });
    if plain {
        Ok(user_id)
    } else {
        Err(SessionError::InvalidIdentifier {
            value: user_id.to_owned(),
        })
    }
}

/// A harness session id for an exact import, trimmed: 1 to [`MAX_IMPORT_SESSION_ID_CHARS`]
/// characters, within one harness's namespace (never `all`).
fn import_session_id<'a>(session_id: &'a str, source: &str) -> Result<&'a str, SessionError> {
    let trimmed = session_id.trim();
    if trimmed.is_empty() {
        return Err(invalid_input("Enter a session ID."));
    }
    if trimmed.chars().count() > MAX_IMPORT_SESSION_ID_CHARS {
        return Err(invalid_input(&format!(
            "A session ID has at most {MAX_IMPORT_SESSION_ID_CHARS} characters."
        )));
    }
    if source == "all" {
        return Err(invalid_input("Choose the harness the session belongs to."));
    }
    Ok(trimmed)
}

fn validate_provider(provider: &str) -> Result<(), SessionError> {
    if KNOWN_PROVIDERS.contains(&provider) {
        Ok(())
    } else {
        Err(SessionError::InvalidIdentifier {
            value: provider.to_owned(),
        })
    }
}

fn malformed(path: &str) -> impl FnOnce(String) -> SessionError + '_ {
    move |detail| SessionError::MalformedResponse {
        detail: format!("{path}: {detail}"),
    }
}

fn invalid_input(message: &str) -> SessionError {
    SessionError::Rejected {
        status: 400,
        message: message.to_owned(),
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// What the server offers and the caller may manage (`GET /v1/info`, `GET /v1/me`).
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn server_settings_info(&self) -> Result<ServerSettingsInfo, SessionError> {
        let result = async {
            let info = self.get_json("/v1/info", &[]).await?;
            let me = self.get_json("/v1/me", &[]).await?;
            ServerSettingsInfo::from_values(&info, &me).map_err(malformed("/v1/info"))
        }
        .await;
        self.dispatch();
        result
    }

    /// Every account (`GET /auth/users`, admins only).
    ///
    /// # Errors
    ///
    /// `Forbidden` for a non-admin; the read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn members(&self) -> Result<Vec<Member>, SessionError> {
        let result = self.get_json("/auth/users", &[]).await;
        self.dispatch();
        let value = result?;
        let object = as_object(&value, "/auth/users").map_err(malformed("/auth/users"))?;
        opt_array(object, "users")
            .map_err(malformed("/auth/users"))?
            .ok_or_else(|| malformed("/auth/users")("`users` is missing".into()))?
            .iter()
            .map(member_from)
            .collect::<Result<_, _>>()
            .map_err(malformed("/auth/users"))
    }

    /// Removes an account (`DELETE /auth/users/{id}`); the server refuses the caller's own and
    /// the last admin.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; `Rejected` with the server's reason; the write
    /// errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn remove_member(&self, user_id: &str) -> Result<(), SessionError> {
        let result = async {
            let path = format!("/auth/users/{}", user_segment(user_id)?);
            self.write(self.prepare("DELETE", &path, &[], None)?)
                .await
                .map(drop)
        }
        .await;
        self.dispatch();
        result
    }

    /// Resets an account's password and returns the new one, shown once
    /// (`POST /auth/users/{id}/reset`).
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; the write errors; `DeliveryUncertain` when the
    /// acknowledgement has no password.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn reset_member_password(&self, user_id: &str) -> Result<String, SessionError> {
        let result = async {
            let path = format!("/auth/users/{}/reset", user_segment(user_id)?);
            let reply = self.write_json("POST", &path, &json!({})).await?;
            reply
                .get("new_password")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or_else(|| SessionError::DeliveryUncertain {
                    detail: format!("{path} returned no password"),
                })
        }
        .await;
        self.dispatch();
        result
    }

    /// Changes the caller's own password (`POST /auth/users/me/password`). The server signs out
    /// the account's other sessions.
    ///
    /// # Errors
    ///
    /// `Rejected` (400) before any request for an empty current password or a new one shorter
    /// than [`MIN_PASSWORD_CHARS`]; `Unauthorized` for a wrong current password; the write
    /// errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn change_password(&self, current: &str, new: &str) -> Result<(), SessionError> {
        if current.is_empty() {
            return Err(invalid_input("Enter your current password."));
        }
        if new.chars().count() < MIN_PASSWORD_CHARS {
            return Err(invalid_input(&format!(
                "Use at least {MIN_PASSWORD_CHARS} characters."
            )));
        }
        let body = json!({"old_password": current, "new_password": new});
        let result = async {
            self.write(self.prepare("POST", "/auth/users/me/password", &[], Some(&body))?)
                .await
                .map(drop)
        }
        .await;
        self.dispatch();
        result
    }

    /// Server-wide default policies (`GET /v1/policies`).
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn default_policies(&self) -> Result<Vec<DefaultPolicy>, SessionError> {
        let result = self.get_json("/v1/policies", &[]).await;
        self.dispatch();
        list_data(&result?, "/v1/policies")?
            .iter()
            .map(policy_from)
            .collect::<Result<_, _>>()
            .map_err(malformed("/v1/policies"))
    }

    /// Turns a default policy on or off (`PATCH /v1/policies/{id}`).
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; the write errors; `DeliveryUncertain` for an
    /// unreadable acknowledgement.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn set_default_policy_enabled(
        &self,
        policy_id: &str,
        enabled: bool,
    ) -> Result<DefaultPolicy, SessionError> {
        let result = async {
            validate_identifier(policy_id)?;
            let path = format!("/v1/policies/{policy_id}");
            let reply = self
                .write_json("PATCH", &path, &json!({"enabled": enabled}))
                .await?;
            policy_from(&reply).map_err(|detail| SessionError::DeliveryUncertain {
                detail: format!("unreadable {path} acknowledgement: {detail}"),
            })
        }
        .await;
        self.dispatch();
        result
    }

    /// Deletes a default policy (`DELETE /v1/policies/{id}`).
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn delete_default_policy(&self, policy_id: &str) -> Result<(), SessionError> {
        let result = async {
            validate_identifier(policy_id)?;
            let path = format!("/v1/policies/{policy_id}");
            self.write(self.prepare("DELETE", &path, &[], None)?)
                .await
                .map(drop)
        }
        .await;
        self.dispatch();
        result
    }

    /// Server-wide sharing (`GET /v1/sharing`, admins only).
    ///
    /// # Errors
    ///
    /// `Forbidden` for a non-admin; the read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn sharing_settings(&self) -> Result<SharingSettings, SessionError> {
        let result = self.get_json("/v1/sharing", &[]).await;
        self.dispatch();
        sharing_from(&result?).map_err(malformed("/v1/sharing"))
    }

    /// Changes sharing (`PUT /v1/sharing`) and returns the new settings.
    ///
    /// # Errors
    ///
    /// `Rejected` (400) before any request for an empty update; `Forbidden` for a setting the
    /// deployment manages; the write errors; `DeliveryUncertain` for an unreadable
    /// acknowledgement.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn update_sharing(
        &self,
        update: &SharingUpdate,
    ) -> Result<SharingSettings, SessionError> {
        let mut body = Map::new();
        if let Some(mode) = &update.mode {
            body.insert("sharing_mode".into(), json!(mode));
        }
        if let Some(public) = update.public_sharing {
            body.insert("public_sharing".into(), json!(public));
        }
        if let Some(level) = &update.public_max_level {
            body.insert("public_sharing_max_level".into(), json!(level));
        }
        if let Some(default) = &update.default_public_sessions {
            body.insert("default_public_sessions".into(), json!(default));
        }
        if body.is_empty() {
            return Err(invalid_input("No sharing settings to update."));
        }
        let result = self
            .write_json("PUT", "/v1/sharing", &Value::Object(body))
            .await;
        self.dispatch();
        sharing_from(&result?).map_err(|detail| SessionError::DeliveryUncertain {
            detail: format!("unreadable /v1/sharing acknowledgement: {detail}"),
        })
    }

    /// Every MCP registry service the caller may use, following pages.
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`]; `InvalidPagination` for a cursor
    /// that repeats.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn mcp_services(&self) -> Result<Vec<McpService>, SessionError> {
        let result = self.mcp_service_pages().await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn mcp_service_pages(&self) -> Result<Vec<McpService>, SessionError> {
        const PATH: &str = "/v1/mcp-registry/services";
        let mut services = Vec::new();
        let mut after: Option<String> = None;
        loop {
            let mut query = vec![("limit", "100".to_owned())];
            if let Some(cursor) = &after {
                query.push(("after", cursor.clone()));
            }
            let page = self.get_json(PATH, &query).await?;
            for row in list_data(&page, PATH)? {
                services.push(mcp_service_from(row).map_err(malformed(PATH))?);
            }
            let next = page.get("next_cursor").and_then(Value::as_str);
            match next {
                Some(cursor) if Some(cursor) == after.as_deref() => {
                    return Err(SessionError::InvalidPagination);
                }
                Some(cursor) if !cursor.is_empty() => after = Some(cursor.to_owned()),
                _ => return Ok(services),
            }
        }
    }

    /// Connects an MCP service with a personal bearer token.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` or `Rejected` (400, an empty or spaced token) before any request; the
    /// write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn connect_mcp_service(
        &self,
        service_id: &str,
        token: &str,
    ) -> Result<(), SessionError> {
        let token = token.trim();
        if token.is_empty() || token.chars().any(char::is_whitespace) {
            return Err(invalid_input("Paste a token without spaces."));
        }
        let result = async {
            validate_identifier(service_id)?;
            let path = format!("/v1/mcp-registry/services/{service_id}/connection");
            self.write_json("PUT", &path, &json!({"token": token}))
                .await
                .map(drop)
        }
        .await;
        self.dispatch();
        result
    }

    /// Disconnects the caller's own account from an MCP service.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn disconnect_mcp_service(&self, service_id: &str) -> Result<(), SessionError> {
        let result = async {
            validate_identifier(service_id)?;
            let path = format!("/v1/mcp-registry/services/{service_id}/connection");
            self.write(self.prepare("DELETE", &path, &[], None)?)
                .await
                .map(drop)
        }
        .await;
        self.dispatch();
        result
    }

    /// Lists an MCP service's tools over the caller's account, to check the connection.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; `Rejected` with the server's reason; the write
    /// errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn test_mcp_service(&self, service_id: &str) -> Result<Vec<String>, SessionError> {
        let result = async {
            validate_identifier(service_id)?;
            let path = format!("/v1/mcp-registry/services/{service_id}/test");
            let reply = self.write_json("POST", &path, &json!({})).await?;
            let object = as_object(&reply, &path).map_err(malformed(&path))?;
            string_list(object, "tools").map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }

    /// The caller's account connection to `provider` (`github` or `databricks`).
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` for another provider; the read errors;
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn provider_connection(
        &self,
        provider: &str,
    ) -> Result<ProviderConnection, SessionError> {
        let result = async {
            validate_provider(provider)?;
            let path = format!("/v1/connections/{provider}/status");
            let value = self.get_json(&path, &[]).await?;
            connection_from(provider, &value).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }

    /// Removes the caller's account connection to `provider`.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` for another provider; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn disconnect_provider(&self, provider: &str) -> Result<(), SessionError> {
        let result = async {
            validate_provider(provider)?;
            let path = format!("/v1/connections/{provider}/disconnect");
            self.write_json("POST", &path, &json!({})).await.map(drop)
        }
        .await;
        self.dispatch();
        result
    }

    /// Online hosts that can read their local sessions for import, by name.
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn import_hosts(&self) -> Result<Vec<CreationHost>, SessionError> {
        let result = self.host_rows().await;
        self.dispatch();
        let mut hosts = result?
            .iter()
            .map(CreationHost::from_value)
            .collect::<Result<Vec<_>, _>>()
            .map_err(malformed("/v1/hosts"))?;
        hosts.retain(|host| host.status == "online" && host.sandbox_provider.is_none());
        hosts.sort_by(|left, right| left.name.cmp(&right.name));
        Ok(hosts)
    }

    /// Imports up to `limit` recent local sessions of `source` (an [`IMPORT_SOURCES`] id) from
    /// `host_id`, or with `session_id` that one harness session; sessions imported before are
    /// skipped.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`, `InvalidPageLimit` outside 1 to [`MAX_IMPORT_LIMIT`], or `Rejected`
    /// (400) for a blank or overlong session id or one without a specific harness, before any
    /// request; the write errors; `DeliveryUncertain` for an unreadable tally.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn import_local_sessions(
        &self,
        host_id: &str,
        source: &str,
        limit: u32,
        session_id: Option<&str>,
    ) -> Result<ImportResult, SessionError> {
        let result = async {
            validate_identifier(host_id)?;
            if !IMPORT_SOURCES.iter().any(|known| known.id == source) {
                return Err(SessionError::InvalidIdentifier {
                    value: source.to_owned(),
                });
            }
            if !(1..=MAX_IMPORT_LIMIT).contains(&limit) {
                return Err(SessionError::InvalidPageLimit { limit });
            }
            let body = match session_id {
                Some(session_id) => json!({
                    "host_id": host_id, "source": source, "limit": limit,
                    "session_id": import_session_id(session_id, source)?,
                }),
                None => json!({"host_id": host_id, "source": source, "limit": limit}),
            };
            let reply = self.write_json("POST", "/v1/imports/local", &body).await?;
            import_result_from(&reply).map_err(|detail| SessionError::DeliveryUncertain {
                detail: format!("unreadable /v1/imports/local tally: {detail}"),
            })
        }
        .await;
        self.dispatch();
        result
    }
}

fn list_data<'a>(value: &'a Value, path: &str) -> Result<&'a Vec<Value>, SessionError> {
    let object = as_object(value, path).map_err(malformed(path))?;
    opt_array(object, "data")
        .map_err(malformed(path))?
        .ok_or_else(|| malformed(path)("`data` is missing".into()))
}

#[cfg(test)]
#[path = "server_admin_tests.rs"]
mod server_admin_tests;
