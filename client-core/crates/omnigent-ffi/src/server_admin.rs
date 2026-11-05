//! Server settings for the Settings window (`omnigent_core::server_admin`).
//!
//! Capabilities, members, default policies, sharing, archived sessions, the MCP registry,
//! provider connections, password change and local session import.

use omnigent_core::server_admin::{
    self as core, DefaultPolicy as CorePolicy, McpService as CoreMcpService,
    SharingSettings as CoreSharing,
};

use crate::client::ClientCore;
use crate::errors::CoreError;
use crate::sessions::SessionSummary;

/// What the server offers and the caller may manage. Missing fields mean unsupported.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ServerSettingsInfo {
    /// The confirmed user id.
    pub user_id: String,
    /// The caller administers the server (Members, Policies, Sharing).
    pub is_admin: bool,
    /// A single-user server: no other members and no sharing.
    pub single_user: bool,
    /// Password accounts: members can be removed and passwords reset or changed.
    pub accounts_enabled: bool,
    /// The MCP registry is configured.
    pub mcp_registry: bool,
    /// Provider connections to show (`github`, `databricks`).
    pub connections: Vec<String>,
    /// Archiving can remove a session's git worktree.
    pub archive_worktree_cleanup: bool,
    /// Sign-in has a session to end (accounts or SSO): Settings shows the identity and Sign out.
    #[uniffi(default)]
    pub has_login_session: bool,
}

impl From<core::ServerSettingsInfo> for ServerSettingsInfo {
    fn from(info: core::ServerSettingsInfo) -> Self {
        Self {
            user_id: info.user_id,
            is_admin: info.is_admin,
            single_user: info.single_user,
            accounts_enabled: info.accounts_enabled,
            mcp_registry: info.mcp_registry,
            connections: info.connections,
            archive_worktree_cleanup: info.archive_worktree_cleanup,
            has_login_session: info.has_login_session,
        }
    }
}

/// One account on the server.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ServerMemberRecord {
    /// User id.
    pub id: String,
    /// An administrator.
    pub is_admin: bool,
    /// Created, Unix seconds.
    pub created_at: Option<i64>,
    /// Last sign-in, Unix seconds.
    pub last_login_at: Option<i64>,
    /// Signs in with a password.
    pub has_password: bool,
}

impl From<core::Member> for ServerMemberRecord {
    fn from(member: core::Member) -> Self {
        Self {
            id: member.id,
            is_admin: member.is_admin,
            created_at: member.created_at,
            last_login_at: member.last_login_at,
            has_password: member.has_password,
        }
    }
}

/// A server-wide default policy.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct DefaultPolicyRecord {
    /// Id; `None` for a config-file policy.
    pub id: Option<String>,
    /// Name.
    pub name: String,
    /// Handler path or URL.
    pub handler: String,
    /// Applies to new sessions.
    pub enabled: bool,
    /// From the config file: read-only.
    pub from_config: bool,
}

impl From<CorePolicy> for DefaultPolicyRecord {
    fn from(policy: CorePolicy) -> Self {
        Self {
            id: policy.id,
            name: policy.name,
            handler: policy.handler,
            enabled: policy.enabled,
            from_config: policy.from_config,
        }
    }
}

/// Server-wide sharing, each setting with whether it is editable here.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SharingSettingsRecord {
    /// `on`, `read_only`, `restricted_read_only` or `off`.
    pub mode: String,
    /// The mode can be changed here.
    pub mode_editable: bool,
    /// Modes, most permissive first.
    pub mode_options: Vec<String>,
    /// Public links may be granted.
    pub public_sharing: bool,
    /// Public sharing can be changed here.
    pub public_sharing_editable: bool,
    /// The most a public link grants.
    pub public_max_level: Option<String>,
    /// The public level can be changed here.
    pub public_max_level_editable: bool,
    /// Public levels.
    pub public_max_level_options: Vec<String>,
    /// Which new sessions start public.
    pub default_public_sessions: Option<String>,
    /// The default can be changed here.
    pub default_public_sessions_editable: bool,
    /// Defaults.
    pub default_public_sessions_options: Vec<String>,
}

impl From<CoreSharing> for SharingSettingsRecord {
    fn from(sharing: CoreSharing) -> Self {
        Self {
            mode: sharing.mode,
            mode_editable: sharing.mode_editable,
            mode_options: sharing.mode_options,
            public_sharing: sharing.public_sharing,
            public_sharing_editable: sharing.public_sharing_editable,
            public_max_level: sharing.public_max_level,
            public_max_level_editable: sharing.public_max_level_editable,
            public_max_level_options: sharing.public_max_level_options,
            default_public_sessions: sharing.default_public_sessions,
            default_public_sessions_editable: sharing.default_public_sessions_editable,
            default_public_sessions_options: sharing.default_public_sessions_options,
        }
    }
}

/// A partial sharing change; at least one field must be set.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct SharingUpdateRecord {
    /// A new mode.
    #[uniffi(default)]
    pub mode: Option<String>,
    /// Allow or disallow public links.
    #[uniffi(default)]
    pub public_sharing: Option<bool>,
    /// A new public level.
    #[uniffi(default)]
    pub public_max_level: Option<String>,
    /// A new default for new sessions.
    #[uniffi(default)]
    pub default_public_sessions: Option<String>,
}

/// One MCP registry service.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct McpServiceRecord {
    /// Id.
    pub id: String,
    /// Title.
    pub title: String,
    /// Description.
    pub description: Option<String>,
    /// The caller has an account connected.
    pub connected: bool,
    /// Tools the service offers.
    pub tools: Vec<String>,
    /// Connects with a personal token.
    pub accepts_token: bool,
    /// The caller's own account can be disconnected here.
    pub can_disconnect: bool,
    /// Connects through the browser (OAuth or a provider account in Integrations).
    pub connects_in_browser: bool,
}

impl From<CoreMcpService> for McpServiceRecord {
    fn from(service: CoreMcpService) -> Self {
        let accepts_token = service.accepts_token();
        let can_disconnect = service.can_disconnect();
        let connects_in_browser = !service.connected && !accepts_token && service.auth != "none";
        Self {
            id: service.id,
            title: service.title,
            description: service.description,
            connected: service.connected,
            tools: service.tools,
            accepts_token,
            can_disconnect,
            connects_in_browser,
        }
    }
}

/// A provider account connection.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ProviderConnectionRecord {
    /// `github` or `databricks`.
    pub provider: String,
    /// Connected.
    pub connected: bool,
    /// The connected account.
    pub account: Option<String>,
}

impl From<core::ProviderConnection> for ProviderConnectionRecord {
    fn from(connection: core::ProviderConnection) -> Self {
        Self {
            provider: connection.provider,
            connected: connection.connected,
            account: connection.account,
        }
    }
}

/// A host that can import its local sessions.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ImportHostRecord {
    /// Host id.
    pub host_id: String,
    /// Name.
    pub name: String,
}

/// A harness whose local sessions can be imported.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ImportSourceRecord {
    /// The request value; `all` reads every harness.
    pub id: String,
    /// The display name.
    pub title: String,
}

/// What an import did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImportResultRecord {
    /// Newly imported.
    pub imported: u64,
    /// Skipped: imported before.
    pub already_imported: u64,
    /// Not imported.
    pub failed: u64,
    /// Why each failure happened.
    pub failures: Vec<String>,
}

/// One page of archived sessions.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ArchivedSessionPage {
    /// Archived sessions, most recently updated first.
    pub sessions: Vec<SessionSummary>,
    /// The cursor of the next page, if any.
    pub next_cursor: Option<String>,
}

/// The import sources, in menu order.
#[must_use]
#[uniffi::export]
pub fn import_sources() -> Vec<ImportSourceRecord> {
    core::IMPORT_SOURCES
        .iter()
        .map(|source| ImportSourceRecord {
            id: source.id.to_owned(),
            title: source.title.to_owned(),
        })
        .collect()
}

/// The most recent sessions one import reads.
#[must_use]
#[uniffi::export]
pub const fn max_import_limit() -> u32 {
    core::MAX_IMPORT_LIMIT
}

/// The shortest password the server accepts.
#[must_use]
#[uniffi::export]
pub fn min_password_length() -> u32 {
    u32::try_from(core::MIN_PASSWORD_CHARS).unwrap_or(u32::MAX)
}

#[uniffi::export]
impl ClientCore {
    /// What the server offers and the caller may manage.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors.
    pub async fn server_settings_info(&self) -> Result<ServerSettingsInfo, CoreError> {
        self.sessions()
            .server_settings_info()
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Every account (admins only).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Forbidden` for a non-admin; the read errors.
    pub async fn server_members(&self) -> Result<Vec<ServerMemberRecord>, CoreError> {
        self.sessions()
            .members()
            .await
            .map(|members| members.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// Removes an account.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Rejected` with the server's reason; the write errors.
    pub async fn remove_server_member(&self, user_id: String) -> Result<(), CoreError> {
        self.sessions()
            .remove_member(&user_id)
            .await
            .map_err(CoreError::from)
    }

    /// Resets an account's password; returns the new one, shown once.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the write errors.
    pub async fn reset_server_member_password(&self, user_id: String) -> Result<String, CoreError> {
        self.sessions()
            .reset_member_password(&user_id)
            .await
            .map_err(CoreError::from)
    }

    /// Changes the caller's password.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Rejected` for a short or empty password; `Unauthorized` for a
    /// wrong current password; the write errors.
    pub async fn change_password(&self, current: String, new: String) -> Result<(), CoreError> {
        self.sessions()
            .change_password(&current, &new)
            .await
            .map_err(CoreError::from)
    }

    /// Server-wide default policies.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors.
    pub async fn default_policies(&self) -> Result<Vec<DefaultPolicyRecord>, CoreError> {
        self.sessions()
            .default_policies()
            .await
            .map(|policies| policies.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// Turns a default policy on or off.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the write errors.
    pub async fn set_default_policy_enabled(
        &self,
        policy_id: String,
        enabled: bool,
    ) -> Result<DefaultPolicyRecord, CoreError> {
        self.sessions()
            .set_default_policy_enabled(&policy_id, enabled)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Deletes a default policy.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the write errors.
    pub async fn delete_default_policy(&self, policy_id: String) -> Result<(), CoreError> {
        self.sessions()
            .delete_default_policy(&policy_id)
            .await
            .map_err(CoreError::from)
    }

    /// Server-wide sharing (admins only).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Forbidden` for a non-admin; the read errors.
    pub async fn sharing_settings(&self) -> Result<SharingSettingsRecord, CoreError> {
        self.sessions()
            .sharing_settings()
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Changes sharing and returns the new settings.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Rejected` for an empty update; `Forbidden` for a setting the
    /// deployment manages; the write errors.
    pub async fn update_sharing(
        &self,
        update: SharingUpdateRecord,
    ) -> Result<SharingSettingsRecord, CoreError> {
        let update = core::SharingUpdate {
            mode: update.mode,
            public_sharing: update.public_sharing,
            public_max_level: update.public_max_level,
            default_public_sessions: update.default_public_sessions,
        };
        self.sessions()
            .update_sharing(&update)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// One page of archived sessions.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidPageLimit`, `InvalidPagination`; the read errors.
    pub async fn archived_sessions(
        &self,
        after: Option<String>,
        limit: u32,
    ) -> Result<ArchivedSessionPage, CoreError> {
        self.sessions()
            .archived_session_page(after.as_deref(), limit)
            .await
            .map(|page| ArchivedSessionPage {
                sessions: page.sessions.into_iter().map(Into::into).collect(),
                next_cursor: page.next_cursor,
            })
            .map_err(CoreError::from)
    }

    /// Every MCP registry service the caller may use.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors.
    pub async fn mcp_services(&self) -> Result<Vec<McpServiceRecord>, CoreError> {
        self.sessions()
            .mcp_services()
            .await
            .map(|services| services.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// Connects an MCP service with a personal token.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Rejected` for an empty or spaced token; the write errors.
    pub async fn connect_mcp_service(
        &self,
        service_id: String,
        token: String,
    ) -> Result<(), CoreError> {
        self.sessions()
            .connect_mcp_service(&service_id, &token)
            .await
            .map_err(CoreError::from)
    }

    /// Disconnects the caller's account from an MCP service.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the write errors.
    pub async fn disconnect_mcp_service(&self, service_id: String) -> Result<(), CoreError> {
        self.sessions()
            .disconnect_mcp_service(&service_id)
            .await
            .map_err(CoreError::from)
    }

    /// Lists an MCP service's tools over the caller's account.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Rejected` with the server's reason; the write errors.
    pub async fn test_mcp_service(&self, service_id: String) -> Result<Vec<String>, CoreError> {
        self.sessions()
            .test_mcp_service(&service_id)
            .await
            .map_err(CoreError::from)
    }

    /// The caller's account connection to `provider`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier` for an unknown provider; the read errors.
    pub async fn provider_connection(
        &self,
        provider: String,
    ) -> Result<ProviderConnectionRecord, CoreError> {
        self.sessions()
            .provider_connection(&provider)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Removes the caller's account connection to `provider`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the write errors.
    pub async fn disconnect_provider(&self, provider: String) -> Result<(), CoreError> {
        self.sessions()
            .disconnect_provider(&provider)
            .await
            .map_err(CoreError::from)
    }

    /// Online hosts that can import their local sessions.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors.
    pub async fn import_hosts(&self) -> Result<Vec<ImportHostRecord>, CoreError> {
        self.sessions()
            .import_hosts()
            .await
            .map(|hosts| {
                hosts
                    .into_iter()
                    .map(|host| ImportHostRecord {
                        host_id: host.host_id,
                        name: host.name,
                    })
                    .collect()
            })
            .map_err(CoreError::from)
    }

    /// Imports up to `limit` recent local sessions of `source` from `host_id`, or with
    /// `session_id` that one harness session (`source` must then name one harness).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, `InvalidPageLimit`, `Rejected` for a bad
    /// session id; the write errors.
    pub async fn import_local_sessions(
        &self,
        host_id: String,
        source: String,
        limit: u32,
        session_id: Option<String>,
    ) -> Result<ImportResultRecord, CoreError> {
        self.sessions()
            .import_local_sessions(&host_id, &source, limit, session_id.as_deref())
            .await
            .map(|result| ImportResultRecord {
                imported: result.imported,
                already_imported: result.already_imported,
                failed: result.failed,
                failures: result.failures,
            })
            .map_err(CoreError::from)
    }
}
