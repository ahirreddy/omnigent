//! Server extensions: the catalog, bundle assets and session pages an extension page reads, and
//! the host side of its bridge (documents, messages, permissions and method parameters).

use omnigent_core::extensions as core;
use serde_json::Value;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// One page an extension contributes, at `/extensions/<extension id>/<route>`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ExtensionPage {
    /// Id, unique within the extension.
    pub id: String,
    /// Title.
    pub title: String,
    /// The one path segment the page is at.
    pub route: String,
    /// The view its bundle renders.
    pub view: String,
}

/// A sidebar entry an extension contributes.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ExtensionNavigation {
    /// Id.
    pub id: String,
    /// The row's label.
    pub label: String,
    /// The page it opens, by id.
    pub page: String,
    /// The web's icon name, if any.
    pub icon: Option<String>,
    /// Where it sorts among extension entries.
    pub order: i64,
}

/// An extension's browser bundle.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ExtensionBundle {
    /// The content digest.
    pub digest: String,
    /// The script's path on the server.
    pub script_url: String,
    /// The stylesheet's path, when there is one.
    pub style_url: Option<String>,
}

/// An installed, enabled extension.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct Extension {
    /// Id; it always contains a dot.
    pub id: String,
    /// Name to show.
    pub display_name: String,
    /// Version.
    pub version: String,
    /// Declared permissions.
    pub permissions: Vec<String>,
    /// Pages.
    pub pages: Vec<ExtensionPage>,
    /// Sidebar entries, by order then id.
    pub navigation: Vec<ExtensionNavigation>,
    /// The browser bundle; `None` when its pages cannot start.
    pub bundle: Option<ExtensionBundle>,
}

/// A sidebar entry with the page it opens.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ExtensionNavigationEntry {
    /// The extension.
    pub extension_id: String,
    /// The entry.
    pub navigation: ExtensionNavigation,
    /// The page it opens.
    pub page: ExtensionPage,
}

/// Who a bridge message is for: one mount of one page.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ExtensionIdentity {
    /// The extension.
    pub extension_id: String,
    /// The page.
    pub page_id: String,
    /// The view.
    pub view: String,
    /// The mount's nonce, lowercase hex.
    pub nonce: String,
    /// The bridge version.
    pub api_version: u32,
}

/// A bundle asset as read.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ExtensionAsset {
    /// The asset's text.
    Loaded {
        /// The text.
        text: String,
    },
    /// The server no longer has this digest: read the catalog again.
    Stale,
}

/// A message from an extension's page.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ExtensionInbound {
    /// The page activated.
    Ready,
    /// The page's SDK speaks another bridge version.
    Incompatible {
        /// The SDK's version.
        sdk_api_version: f64,
    },
    /// The page failed to activate.
    Failed {
        /// Why.
        message: String,
    },
    /// A host method call.
    Request {
        /// The request's id.
        request_id: String,
        /// The method.
        method: String,
        /// Its parameters as JSON, when it sent any.
        params_json: Option<String>,
    },
    /// The page gave up on a request.
    Cancel {
        /// The request's id.
        request_id: String,
    },
}

/// Why a host method failed, as the extension is told.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum ExtensionHostFault {
    /// The method failed with one of the SDK's codes.
    #[error("{code}: {message}")]
    Failed {
        /// The code (`InvalidParams`, `PermissionDenied`, `HostError`...).
        code: String,
        /// What went wrong.
        message: String,
    },
}

impl From<core::ExtensionHostError> for ExtensionHostFault {
    fn from(error: core::ExtensionHostError) -> Self {
        Self::Failed {
            code: error.code,
            message: error.message,
        }
    }
}

/// One session as an extension sees it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ExtensionSessionRow {
    /// Id.
    pub id: String,
    /// Title; `None` before the server names it.
    pub title: Option<String>,
    /// The title is the app's placeholder.
    pub title_provisional: bool,
    /// `idle`, `running`, `waiting` or `failed`.
    pub status: String,
    /// A finished turn the caller has not seen.
    pub unread: bool,
    /// Workspace.
    pub workspace: Option<String>,
    /// Git branch.
    pub git_branch: Option<String>,
    /// Project id.
    pub project_id: Option<String>,
    /// Created, as the server stamps it.
    pub created_at: f64,
    /// Last changed, as the server stamps it.
    pub updated_at: f64,
}

/// A page of the server's session list.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ExtensionSessionRows {
    /// The sessions; none marked unread yet.
    pub rows: Vec<ExtensionSessionRow>,
    /// More follow.
    pub has_more: bool,
    /// Where the next page starts, when the server says.
    pub last_id: Option<String>,
}

/// Where a session page starts and how many sessions it has.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ExtensionSessionPageRequest {
    /// The cursor of the page before.
    pub after: Option<String>,
    /// 1 to 1,000.
    pub limit: u32,
}

/// A value to store under a key.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ExtensionStorageWrite {
    /// The key.
    pub key: String,
    /// The value as JSON text.
    pub json: String,
    /// Its size in UTF-8 bytes.
    pub size: u64,
}

/// A project as the app lists it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ExtensionProjectRow {
    /// The first-class id; `None` for a label-only project.
    pub id: Option<String>,
    /// Name.
    pub name: String,
    /// Icon.
    pub icon: Option<String>,
}

impl From<core::ExtensionPage> for ExtensionPage {
    fn from(page: core::ExtensionPage) -> Self {
        Self {
            id: page.id,
            title: page.title,
            route: page.route,
            view: page.view,
        }
    }
}

impl From<ExtensionPage> for core::ExtensionPage {
    fn from(page: ExtensionPage) -> Self {
        Self {
            id: page.id,
            title: page.title,
            route: page.route,
            view: page.view,
        }
    }
}

impl From<core::ExtensionNavigation> for ExtensionNavigation {
    fn from(entry: core::ExtensionNavigation) -> Self {
        Self {
            id: entry.id,
            label: entry.label,
            page: entry.page,
            icon: entry.icon,
            order: entry.order,
        }
    }
}

impl From<ExtensionNavigation> for core::ExtensionNavigation {
    fn from(entry: ExtensionNavigation) -> Self {
        Self {
            id: entry.id,
            label: entry.label,
            page: entry.page,
            icon: entry.icon,
            order: entry.order,
        }
    }
}

impl From<core::Extension> for Extension {
    fn from(extension: core::Extension) -> Self {
        Self {
            id: extension.id,
            display_name: extension.display_name,
            version: extension.version,
            permissions: extension.permissions,
            pages: extension.pages.into_iter().map(Into::into).collect(),
            navigation: extension.navigation.into_iter().map(Into::into).collect(),
            bundle: extension.bundle.map(|bundle| ExtensionBundle {
                digest: bundle.digest,
                script_url: bundle.script_url,
                style_url: bundle.style_url,
            }),
        }
    }
}

impl From<Extension> for core::Extension {
    fn from(extension: Extension) -> Self {
        Self {
            id: extension.id,
            display_name: extension.display_name,
            version: extension.version,
            permissions: extension.permissions,
            pages: extension.pages.into_iter().map(Into::into).collect(),
            navigation: extension.navigation.into_iter().map(Into::into).collect(),
            bundle: extension.bundle.map(|bundle| core::ExtensionBundle {
                digest: bundle.digest,
                script_url: bundle.script_url,
                style_url: bundle.style_url,
            }),
        }
    }
}

impl From<ExtensionIdentity> for core::ExtensionIdentity {
    fn from(identity: ExtensionIdentity) -> Self {
        Self {
            extension_id: identity.extension_id,
            page_id: identity.page_id,
            view: identity.view,
            nonce: identity.nonce,
            api_version: identity.api_version,
        }
    }
}

impl From<core::ExtensionSessionRow> for ExtensionSessionRow {
    fn from(row: core::ExtensionSessionRow) -> Self {
        Self {
            id: row.id,
            title: row.title,
            title_provisional: row.title_provisional,
            status: row.status,
            unread: row.unread,
            workspace: row.workspace,
            git_branch: row.git_branch,
            project_id: row.project_id,
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}

impl From<ExtensionSessionRow> for core::ExtensionSessionRow {
    fn from(row: ExtensionSessionRow) -> Self {
        Self {
            id: row.id,
            title: row.title,
            title_provisional: row.title_provisional,
            status: row.status,
            unread: row.unread,
            workspace: row.workspace,
            git_branch: row.git_branch,
            project_id: row.project_id,
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}

/// `params_json` parsed; text that is not JSON is the same as no parameters, which every method
/// refuses as it refuses a missing object.
fn parsed(params_json: Option<&str>) -> Option<Value> {
    params_json.and_then(|text| serde_json::from_str(text).ok())
}

fn result_value(result_json: &str) -> Result<Value, ExtensionHostFault> {
    serde_json::from_str(result_json).map_err(|_| ExtensionHostFault::Failed {
        code: "HostError".to_owned(),
        message: "Host call failed".to_owned(),
    })
}

#[uniffi::export]
impl ClientCore {
    /// The enabled extensions; a server without extensions has none.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn extensions(&self) -> Result<Vec<Extension>, CoreError> {
        self.sessions()
            .extensions()
            .await
            .map(|list| list.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// Reads one of extension `extension_id`'s bundle assets.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidInput` for a URL that is not one of its assets, the read
    /// errors and `MalformedResponse`.
    pub async fn extension_asset(
        &self,
        extension_id: String,
        url: String,
    ) -> Result<ExtensionAsset, CoreError> {
        use omnigent_core::extension_reads::ExtensionAsset as Read;
        match self
            .sessions()
            .extension_asset(&extension_id, &url)
            .await
            .map_err(CoreError::from)?
        {
            Read::Loaded(text) => Ok(ExtensionAsset::Loaded { text }),
            Read::Stale => Ok(ExtensionAsset::Stale),
        }
    }

    /// A page of the caller's top-level, unarchived sessions for `sessions.listPage`.
    ///
    /// # Errors
    ///
    /// [`ExtensionHostFault`]: what the extension is told.
    pub async fn extension_session_rows(
        &self,
        request: ExtensionSessionPageRequest,
    ) -> Result<ExtensionSessionRows, ExtensionHostFault> {
        let request = core::SessionPageRequest {
            after: request.after,
            limit: request.limit,
        };
        let rows = self.sessions().extension_session_rows(&request).await?;
        Ok(ExtensionSessionRows {
            rows: rows.rows.into_iter().map(Into::into).collect(),
            has_more: rows.has_more,
            last_id: rows.last_id,
        })
    }
}

/// Every extension's sidebar entries, by order then id, each with its page.
#[uniffi::export]
pub fn extension_navigation_entries(extensions: Vec<Extension>) -> Vec<ExtensionNavigationEntry> {
    let extensions: Vec<core::Extension> = extensions.into_iter().map(Into::into).collect();
    core::navigation_entries(&extensions)
        .into_iter()
        .map(|entry| ExtensionNavigationEntry {
            extension_id: entry.extension_id,
            navigation: entry.navigation.into(),
            page: entry.page.into(),
        })
        .collect()
}

/// The bundle's sandboxed document for one mount.
#[uniffi::export]
pub fn extension_document(script: String, styles: String, identity: ExtensionIdentity) -> String {
    core::build_extension_document(&script, &styles, &identity.into())
}

/// The native page framing `document`, with the relay to the app.
#[uniffi::export]
pub fn extension_host_page(document: String, title: String, nonce: String) -> String {
    core::build_host_page(&document, &title, &nonce)
}

/// The message in `text` when it is a well-formed message for `identity`.
#[uniffi::export]
pub fn extension_inbound(text: String, identity: ExtensionIdentity) -> Option<ExtensionInbound> {
    let message = core::parse_inbound(&text, &identity.into())?;
    Some(match message {
        core::ExtensionInbound::Ready => ExtensionInbound::Ready,
        core::ExtensionInbound::Incompatible { sdk_api_version } => {
            ExtensionInbound::Incompatible { sdk_api_version }
        }
        core::ExtensionInbound::Failed { message } => ExtensionInbound::Failed { message },
        core::ExtensionInbound::Request {
            request_id,
            method,
            params,
        } => ExtensionInbound::Request {
            request_id,
            method,
            params_json: params.map(|params| params.to_string()),
        },
        core::ExtensionInbound::Cancel { request_id } => ExtensionInbound::Cancel { request_id },
    })
}

/// The host methods `permissions` grant, sorted.
#[uniffi::export]
pub fn extension_granted_methods(permissions: Vec<String>) -> Vec<String> {
    core::granted_host_methods(&permissions)
}

/// `init` for the mount.
#[uniffi::export]
pub fn extension_init_message(identity: ExtensionIdentity, capabilities: Vec<String>) -> String {
    core::init_message(&identity.into(), &capabilities)
}

/// The answer to a request with `result_json`, or `ResponseTooLarge`.
#[uniffi::export]
pub fn extension_response_message(
    identity: ExtensionIdentity,
    request_id: String,
    method: String,
    result_json: String,
) -> String {
    let identity = identity.into();
    match result_value(&result_json) {
        Ok(result) => core::response_message(&identity, &request_id, &method, &result),
        Err(ExtensionHostFault::Failed { code, message }) => {
            core::error_response_message(&identity, &request_id, &code, &message)
        }
    }
}

/// A failed answer to a request.
#[uniffi::export]
pub fn extension_error_message(
    identity: ExtensionIdentity,
    request_id: String,
    code: String,
    message: String,
) -> String {
    core::error_response_message(&identity.into(), &request_id, &code, &message)
}

/// An event for subscribers; `None` when it is over the budget or `value_json` is not JSON.
#[uniffi::export]
pub fn extension_event_message(
    identity: ExtensionIdentity,
    event: String,
    value_json: String,
) -> Option<String> {
    let value: Value = serde_json::from_str(&value_json).ok()?;
    core::event_message(&identity.into(), &event, &value)
}

/// `dispose` for the mount.
#[uniffi::export]
pub fn extension_dispose_message(identity: ExtensionIdentity) -> String {
    core::dispose_message(&identity.into())
}

/// `navigation.openPage`: the route of the page it names among `pages`.
///
/// # Errors
///
/// [`ExtensionHostFault`] for bad parameters or a page the extension does not own.
#[uniffi::export]
pub fn extension_page_route(
    params_json: Option<String>,
    pages: Vec<ExtensionPage>,
) -> Result<String, ExtensionHostFault> {
    let pages: Vec<core::ExtensionPage> = pages.into_iter().map(Into::into).collect();
    Ok(core::page_route_param(
        parsed(params_json.as_deref()).as_ref(),
        &pages,
    )?)
}

/// `navigation.openSession` and `sessions.pullRequest`: the session id.
///
/// # Errors
///
/// [`ExtensionHostFault`] `InvalidParams`.
#[uniffi::export]
pub fn extension_session_id(params_json: Option<String>) -> Result<String, ExtensionHostFault> {
    Ok(core::session_id_param(
        parsed(params_json.as_deref()).as_ref(),
    )?)
}

/// `navigation.openNewSession`: the project to start in, if any.
///
/// # Errors
///
/// [`ExtensionHostFault`] `InvalidParams`.
#[uniffi::export]
pub fn extension_new_session_project(
    params_json: Option<String>,
) -> Result<Option<String>, ExtensionHostFault> {
    Ok(core::new_session_project_param(
        parsed(params_json.as_deref()).as_ref(),
    )?)
}

/// `navigation.openExternal`: the URL, which the host opens only if it handed it out.
///
/// # Errors
///
/// [`ExtensionHostFault`] for parameters without a URL.
#[uniffi::export]
pub fn extension_external_url(params_json: Option<String>) -> Result<String, ExtensionHostFault> {
    Ok(core::external_url_param(
        parsed(params_json.as_deref()).as_ref(),
    )?)
}

/// `projects.create`: the trimmed name.
///
/// # Errors
///
/// [`ExtensionHostFault`] `InvalidParams`.
#[uniffi::export]
pub fn extension_project_name(params_json: Option<String>) -> Result<String, ExtensionHostFault> {
    Ok(core::project_name_param(
        parsed(params_json.as_deref()).as_ref(),
    )?)
}

/// `storage.user.get` and `storage.user.delete`: the key.
///
/// # Errors
///
/// [`ExtensionHostFault`] `InvalidParams` or `InvalidKey`.
#[uniffi::export]
pub fn extension_storage_key(params_json: Option<String>) -> Result<String, ExtensionHostFault> {
    Ok(core::storage_key_param(
        parsed(params_json.as_deref()).as_ref(),
    )?)
}

/// `storage.user.set`: the key and value.
///
/// # Errors
///
/// [`ExtensionHostFault`] `InvalidParams`, `InvalidKey`, `InvalidValue` or `QuotaExceeded`.
#[uniffi::export]
pub fn extension_storage_write(
    params_json: Option<String>,
) -> Result<ExtensionStorageWrite, ExtensionHostFault> {
    let write = core::storage_write_param(parsed(params_json.as_deref()).as_ref())?;
    Ok(ExtensionStorageWrite {
        key: write.key,
        json: write.json,
        size: write.size,
    })
}

/// `sessions.listPage` and `sessions.getCached`: the page asked for.
///
/// # Errors
///
/// [`ExtensionHostFault`] `InvalidParams`.
#[uniffi::export]
pub fn extension_session_page_request(
    params_json: Option<String>,
) -> Result<ExtensionSessionPageRequest, ExtensionHostFault> {
    let request = core::session_page_request(parsed(params_json.as_deref()).as_ref())?;
    Ok(ExtensionSessionPageRequest {
        after: request.after,
        limit: request.limit,
    })
}

/// `sessions.listPage`'s answer as JSON.
///
/// # Errors
///
/// [`ExtensionHostFault`] `HostError` when no session fits or the cursor is missing.
#[uniffi::export]
pub fn extension_session_page_result(
    page: ExtensionSessionRows,
) -> Result<String, ExtensionHostFault> {
    let page = core::SessionRows {
        rows: page.rows.into_iter().map(Into::into).collect(),
        has_more: page.has_more,
        last_id: page.last_id,
    };
    Ok(core::session_page_result(&page)?.to_string())
}

/// `sessions.getCached`'s answer as JSON: the first `limit` rows, or `null`.
#[uniffi::export]
pub fn extension_cached_sessions_result(rows: Vec<ExtensionSessionRow>, limit: u32) -> String {
    let rows: Vec<core::ExtensionSessionRow> = rows.into_iter().map(Into::into).collect();
    core::cached_sessions_result(&rows, limit).to_string()
}

/// `projects.list`'s answer as JSON: the first-class projects.
#[uniffi::export]
pub fn extension_projects_result(projects: Vec<ExtensionProjectRow>) -> String {
    let projects: Vec<(Option<String>, String, Option<String>)> = projects
        .into_iter()
        .map(|project| (project.id, project.name, project.icon))
        .collect();
    core::cached_projects_result(&projects).to_string()
}

/// `projects.create`'s answer as JSON.
///
/// # Errors
///
/// [`ExtensionHostFault`] `HostError` for a project without an id.
#[uniffi::export]
pub fn extension_project_result(
    project: ExtensionProjectRow,
) -> Result<String, ExtensionHostFault> {
    Ok(core::project_result(
        project.id.as_deref(),
        &project.name,
        project.icon.as_deref(),
    )?
    .to_string())
}

/// `sessions.pullRequest`'s answer as JSON; `null` unless the PR page is `https`.
#[uniffi::export]
pub fn extension_pull_request_result(
    number: u64,
    title: String,
    state: String,
    url: String,
) -> String {
    core::pull_request_result(number, &title, &state, &url).to_string()
}

/// `theme.getCurrent`'s answer and the `theme.changed` value as JSON.
#[uniffi::export]
pub fn extension_theme_result(dark: bool) -> String {
    core::theme_result(dark).to_string()
}

#[cfg(test)]
#[path = "extensions_tests.rs"]
mod tests;
