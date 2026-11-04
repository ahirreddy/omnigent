//! Session creation over REST: the host and agent catalog, the workspace picker, the host's
//! model preview, and `POST /v1/sessions`.
//!
//! Port of `NativeLab`'s `LocalServerSessionCreation.swift`. Readiness and the model are
//! re-checked against a fresh catalog immediately before the `POST`, so a host that went offline
//! after the form opened blocks creation without a request.
//!
//! The create `POST` has no idempotency key, and the server persists the session row before it
//! waits for the host launch, so only 400, 415 and 422 are definite rejections. Every other
//! unclear outcome (a lost connection, a timeout, a 3xx, 403, 404, 409, 5xx, an HTML or
//! malformed 201, an unusable id) is [`CreationError::Uncertain`] and is never retried. A usable
//! id is the acknowledgement, even when the rest of the body is a snapshot shape this client
//! cannot read.

use std::collections::BTreeSet;

use omnigent_protocol::Page;
use serde_json::Value;

use super::events::MessageSent;
use super::json::{as_object, opt_array, opt_bool, opt_str};
use super::requests::{page_query, validate_identifier};
use super::sessions::decode_snapshot;
use super::{ClientCore, ClientEvent, SessionError, lock};
use crate::attachments::policy::is_identifier;
use crate::auth::mode::error_text;
use crate::config::session::ModelChoice;
use crate::creation::{
    CreationAgent, CreationCapabilities, CreationCatalog, CreationError, CreationHost,
    CreationReceipt, CreationSelection, CreationWorkspace, HostDirectoryListing, HostWorktree,
    MAX_TITLE_CHARS, creation_body, creation_rejection, merge_user_agents, parent_directory,
    sandbox_creation_body,
};
use crate::http::HttpTransport;

/// The largest page the catalog routes are asked for.
const CATALOG_PAGE_LIMIT: u32 = 1000;

/// The page size and the most agent names read from `GET /v1/agents?scope=user`.
const USER_AGENT_LIMIT: usize = 50;

/// The most `?scope=user` pages read: copies and repeats can fill a page without a new name.
const USER_AGENT_PAGES: usize = 5;

/// How the first message of a newly created session went.
#[derive(Debug, Clone, PartialEq)]
pub enum FirstMessage {
    /// Sent.
    Sent(MessageSent),
    /// Not sent, or its outcome is unknown. The session exists: retry the send to it, never the
    /// creation.
    Failed(SessionError),
}

/// A created session and its first message.
#[derive(Debug, Clone, PartialEq)]
pub struct CreatedSession {
    /// The creation acknowledgement.
    pub receipt: CreationReceipt,
    /// The first message's outcome.
    pub first_message: FirstMessage,
}

/// `{data, has_more, last_id}` with untyped rows.
pub(crate) struct RawPage {
    pub(crate) data: Vec<Value>,
    pub(crate) has_more: bool,
    pub(crate) last_id: Option<String>,
}

pub(crate) fn raw_page(value: &Value, context: &str) -> Result<RawPage, SessionError> {
    let malformed = |detail: String| SessionError::MalformedResponse {
        detail: format!("{context}: {detail}"),
    };
    let object = as_object(value, "page").map_err(malformed)?;
    Ok(RawPage {
        data: opt_array(object, "data")
            .map_err(malformed)?
            .ok_or_else(|| malformed("`data` is missing".into()))?
            .clone(),
        has_more: opt_bool(object, "has_more")
            .map_err(malformed)?
            .ok_or_else(|| malformed("`has_more` is missing".into()))?,
        last_id: opt_str(object, "last_id").map_err(malformed)?,
    })
}

impl RawPage {
    /// The next `after` cursor, rejecting a missing or repeated one (also across pages).
    pub(crate) fn next_cursor(
        &self,
        after: Option<&str>,
        seen: &mut BTreeSet<String>,
    ) -> Result<Option<String>, SessionError> {
        let page: Page<()> = Page {
            data: Vec::new(),
            first_id: None,
            last_id: self.last_id.clone(),
            has_more: self.has_more,
        };
        let next = page
            .next_cursor(after)
            .map_err(|_| SessionError::InvalidPagination)?
            .map(str::to_owned);
        if let Some(cursor) = &next
            && !seen.insert(cursor.clone())
        {
            return Err(SessionError::InvalidPagination);
        }
        Ok(next)
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// Every `/v1/agents` row, following the cursor.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(crate) async fn agent_rows(&self) -> Result<Vec<Value>, SessionError> {
        let mut rows = Vec::new();
        let mut after: Option<String> = None;
        let mut cursors = BTreeSet::new();
        loop {
            let query = page_query(after.as_deref(), CATALOG_PAGE_LIMIT)?;
            let value = self.get_json("/v1/agents", &query).await?;
            let page = raw_page(&value, "/v1/agents")?;
            let next = page.next_cursor(after.as_deref(), &mut cursors)?;
            rows.extend(page.data);
            match next {
                Some(cursor) => after = Some(cursor),
                None => return Ok(rows),
            }
        }
    }

    /// The caller's own agents, `GET /v1/agents?scope=user`: pages of 50 until 50 root names,
    /// at most five pages (the web's `fetchUserAgents`).
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(crate) async fn user_agent_rows(&self) -> Result<Vec<Value>, SessionError> {
        let mut rows = Vec::new();
        let mut names = BTreeSet::new();
        let mut after: Option<String> = None;
        let mut cursors = BTreeSet::new();
        for _ in 0..USER_AGENT_PAGES {
            let mut query = vec![
                ("scope", "user".to_owned()),
                ("limit", USER_AGENT_LIMIT.to_string()),
            ];
            if let Some(cursor) = &after {
                query.push(("after", cursor.clone()));
            }
            let value = self.get_json("/v1/agents", &query).await?;
            let page = raw_page(&value, "/v1/agents?scope=user")?;
            let next = page.next_cursor(after.as_deref(), &mut cursors)?;
            for row in page.data {
                let name = row
                    .get("name")
                    .and_then(Value::as_str)
                    .map(|name| super::fork::agent_root_name(name).to_owned())
                    .unwrap_or_default();
                if names.len() >= USER_AGENT_LIMIT && !names.contains(&name) {
                    continue;
                }
                names.insert(name);
                rows.push(row);
            }
            match next {
                Some(cursor) if names.len() < USER_AGENT_LIMIT => after = Some(cursor),
                _ => break,
            }
        }
        Ok(rows)
    }

    /// The creation fields of `GET /v1/info`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(crate) async fn creation_capabilities(&self) -> Result<CreationCapabilities, SessionError> {
        let value = self.get_json("/v1/info", &[]).await?;
        CreationCapabilities::from_value(&value)
            .map_err(|detail| SessionError::MalformedResponse { detail })
    }

    /// Every `/v1/hosts` row.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(crate) async fn host_rows(&self) -> Result<Vec<Value>, SessionError> {
        let value = self.get_json("/v1/hosts", &[]).await?;
        let object = as_object(&value, "/v1/hosts")
            .map_err(|detail| SessionError::MalformedResponse { detail })?;
        opt_array(object, "hosts")
            .map_err(|detail| SessionError::MalformedResponse { detail })?
            .cloned()
            .ok_or_else(|| SessionError::MalformedResponse {
                detail: "/v1/hosts: `hosts` is missing".into(),
            })
    }

    /// The host's model preview for `harness`: rows with an id and a value, not hidden,
    /// de-duplicated by value when `by_value` (creation) or by id (configuration).
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(crate) async fn host_model_options(
        &self,
        host_id: &str,
        harness: &str,
        by_value: bool,
    ) -> Result<Vec<ModelChoice>, SessionError> {
        validate_identifier(host_id)?;
        validate_identifier(harness)?;
        let path = format!("/v1/hosts/{host_id}/harnesses/{harness}/model-options");
        let value = self.get_json(&path, &[]).await?;
        let malformed = |detail: String| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        };
        let object = as_object(&value, "model options").map_err(malformed)?;
        let models = opt_array(object, "models")
            .map_err(malformed)?
            .ok_or_else(|| malformed("`models` is missing".into()))?;
        let mut seen = BTreeSet::new();
        let mut result = Vec::new();
        for model in models {
            let choice = ModelChoice::from_value(model).map_err(malformed)?;
            let usable = !choice.id.is_empty()
                && (!by_value || (!choice.value().is_empty() && choice.hidden != Some(true)));
            let key = if by_value {
                choice.value().to_owned()
            } else {
                choice.id.clone()
            };
            if usable && seen.insert(key) {
                result.push(choice);
            }
        }
        Ok(result)
    }

    /// The hosts and agents a session can be created with, de-duplicated by id.
    ///
    /// # Errors
    ///
    /// The read errors, [`SessionError::MalformedResponse`] and
    /// [`SessionError::InvalidPagination`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn creation_catalog(&self) -> Result<CreationCatalog, SessionError> {
        let result = self.catalog().await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn catalog(&self) -> Result<CreationCatalog, SessionError> {
        let malformed = |detail: String| SessionError::MalformedResponse { detail };
        let capabilities = self.creation_capabilities().await?;
        let hosts = self
            .host_rows()
            .await?
            .iter()
            .map(CreationHost::from_value)
            .collect::<Result<Vec<_>, String>>()
            .map_err(malformed)?;
        let decode = |rows: Vec<Value>| {
            rows.iter()
                .map(CreationAgent::from_value)
                .collect::<Result<Vec<_>, String>>()
                .map_err(malformed)
        };
        let mut seen_hosts = BTreeSet::new();
        let mut seen_agents = BTreeSet::new();
        let mut agents: Vec<CreationAgent> = decode(self.agent_rows().await?)?
            .into_iter()
            .filter(|agent| !agent.id.is_empty() && seen_agents.insert(agent.id.clone()))
            .collect();
        if capabilities.agent_install {
            let user = decode(self.user_agent_rows().await?)?
                .into_iter()
                .filter(|agent| !agent.id.is_empty())
                .collect();
            agents.extend(merge_user_agents(&agents, user));
        }
        Ok(CreationCatalog {
            hosts: hosts
                .into_iter()
                .filter(|host| !host.host_id.is_empty() && seen_hosts.insert(host.host_id.clone()))
                .collect(),
            agents,
            capabilities,
        })
    }

    /// Directories on `host_id` to offer as workspaces (other absolute paths may be typed).
    /// Pages by the last entry's path; files and relative paths are never offered.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; the read errors;
    /// [`SessionError::InvalidPagination`] for a cursor that does not advance.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn creation_workspaces(
        &self,
        host_id: &str,
    ) -> Result<Vec<CreationWorkspace>, SessionError> {
        let result = self.workspaces(host_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn workspaces(&self, host_id: &str) -> Result<Vec<CreationWorkspace>, SessionError> {
        validate_identifier(host_id)?;
        self.directories(&format!("/v1/hosts/{host_id}/filesystem"))
            .await
            .map(|(directories, _)| directories)
    }

    /// The directories in `directory` on `host_id` (the host's home when `None`), for the folder
    /// browser, with the listed path and its parent.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request, also for a path that is not
    /// absolute or cannot be sent; the read errors; [`SessionError::InvalidPagination`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn host_directory(
        &self,
        host_id: &str,
        directory: Option<&str>,
    ) -> Result<HostDirectoryListing, SessionError> {
        let result = async {
            validate_identifier(host_id)?;
            let route = match directory {
                None => format!("/v1/hosts/{host_id}/filesystem"),
                Some(path) => {
                    let trimmed = path.trim();
                    let trimmed = if trimmed.len() > 1 {
                        trimmed.trim_end_matches('/')
                    } else {
                        trimmed
                    };
                    if !trimmed.starts_with('/') || trimmed.contains(['\0', '?', '#', '%']) {
                        return Err(SessionError::InvalidIdentifier {
                            value: path.to_owned(),
                        });
                    }
                    if trimmed == "/" {
                        format!("/v1/hosts/{host_id}/filesystem/")
                    } else {
                        format!("/v1/hosts/{host_id}/filesystem{trimmed}")
                    }
                }
            };
            let (directories, first_entry) = self.directories(&route).await?;
            let path = directory
                .map(|path| {
                    let trimmed = path.trim();
                    if trimmed.len() > 1 {
                        trimmed.trim_end_matches('/').to_owned()
                    } else {
                        trimmed.to_owned()
                    }
                })
                .or_else(|| first_entry.as_deref().and_then(parent_directory));
            Ok(HostDirectoryListing {
                parent: path.as_deref().and_then(parent_directory),
                path,
                directories,
            })
        }
        .await;
        self.dispatch();
        result
    }

    /// The git worktrees of the repository at `path` on `host_id`, main first; empty when `path`
    /// is not in a git repository (the server's 400).
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; the other read errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn host_worktrees(
        &self,
        host_id: &str,
        path: &str,
    ) -> Result<Vec<HostWorktree>, SessionError> {
        let result = async {
            validate_identifier(host_id)?;
            let route = format!("/v1/hosts/{host_id}/worktrees");
            let value = match self
                .get_json(&route, &[("path", path.trim().to_owned())])
                .await
            {
                Err(SessionError::HttpStatus { status: 400 }) => return Ok(Vec::new()),
                other => other?,
            };
            let page = as_object(&value, "worktrees")
                .map_err(|detail| SessionError::MalformedResponse { detail })?;
            opt_array(page, "data")
                .map_err(|detail| SessionError::MalformedResponse { detail })?
                .ok_or_else(|| SessionError::MalformedResponse {
                    detail: format!("{route}: `data` is missing"),
                })?
                .iter()
                .map(HostWorktree::from_value)
                .collect::<Result<Vec<_>, String>>()
                .map_err(|detail| SessionError::MalformedResponse { detail })
        }
        .await;
        self.dispatch();
        result
    }

    /// Every directory under the filesystem route `path`, following the cursor, and the first
    /// entry's path (to find the listed directory of the home route).
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn directories(
        &self,
        path: &str,
    ) -> Result<(Vec<CreationWorkspace>, Option<String>), SessionError> {
        let mut first_entry: Option<String> = None;
        let mut results = Vec::new();
        let mut seen = BTreeSet::new();
        let mut cursors = BTreeSet::new();
        let mut after: Option<String> = None;
        loop {
            let query = page_query(after.as_deref(), CATALOG_PAGE_LIMIT)?;
            let value = self.get_json(path, &query).await?;
            let malformed = |detail: String| SessionError::MalformedResponse {
                detail: format!("{path}: {detail}"),
            };
            let object = as_object(&value, "filesystem page").map_err(malformed)?;
            let entries = opt_array(object, "data")
                .map_err(malformed)?
                .ok_or_else(|| malformed("`data` is missing".into()))?;
            let mut last_path = None;
            for entry in entries {
                let entry = as_object(entry, "filesystem entry").map_err(malformed)?;
                let name = opt_str(entry, "name")
                    .map_err(malformed)?
                    .unwrap_or_default();
                let entry_path = opt_str(entry, "path")
                    .map_err(malformed)?
                    .unwrap_or_default();
                let kind = opt_str(entry, "type").map_err(malformed)?;
                if first_entry.is_none() && entry_path.starts_with('/') {
                    first_entry = Some(entry_path.clone());
                }
                if kind.as_deref() == Some("directory")
                    && entry_path.starts_with('/')
                    && seen.insert(entry_path.clone())
                {
                    results.push(CreationWorkspace {
                        path: entry_path.clone(),
                        name,
                    });
                }
                last_path = Some(entry_path);
            }
            let has_more = opt_bool(object, "has_more")
                .map_err(malformed)?
                .ok_or_else(|| malformed("`has_more` is missing".into()))?;
            if !has_more {
                return Ok((results, first_entry));
            }
            match last_path {
                Some(cursor) if !cursor.is_empty() && cursors.insert(cursor.clone()) => {
                    after = Some(cursor);
                }
                _ => return Err(SessionError::InvalidPagination),
            }
        }
    }

    /// The models the host advertises for `agent_id`'s harness; empty for harnesses without a
    /// preview.
    ///
    /// # Errors
    ///
    /// [`SessionError::Creation`] when the agent cannot be created on the host, and the read
    /// errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn creation_models(
        &self,
        agent_id: &str,
        host_id: &str,
    ) -> Result<Vec<ModelChoice>, SessionError> {
        let result = async {
            let catalog = self.catalog().await?;
            if let Some(reason) = catalog.unavailable_reason(agent_id, host_id) {
                return Err(CreationError::Unavailable(reason).into());
            }
            let agent = catalog
                .agent(agent_id)
                .ok_or_else(|| CreationError::Unavailable("Choose a registered agent.".into()))?;
            self.models_for(agent, host_id).await
        }
        .await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn models_for(
        &self,
        agent: &CreationAgent,
        host_id: &str,
    ) -> Result<Vec<ModelChoice>, SessionError> {
        if !agent.supports_model_preview() {
            return Ok(Vec::new());
        }
        self.host_model_options(host_id, &agent.harness_id(), true)
            .await
    }

    /// Creates an external-host session for `selection`, re-validating readiness and the model
    /// against a fresh catalog first. Sends no first message.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`]; [`SessionError::Creation`] with
    /// [`CreationError::Unavailable`] (nothing sent), [`CreationError::Rejected`] or
    /// [`CreationError::Uncertain`]; [`SessionError::Unauthorized`] (the connection ends); the
    /// catalog read errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_session(
        &self,
        selection: &CreationSelection,
        title: &str,
    ) -> Result<CreationReceipt, SessionError> {
        let result = self.create(selection, title).await;
        self.dispatch();
        result
    }

    /// Creates a session, then sends `text` to it. Once the session exists the result is always
    /// `Ok`: a failed first message is reported in [`CreatedSession::first_message`] so the
    /// caller retries the send, never the creation. The first message does not wait for the new
    /// session's live stream; hydration reconciles its echo.
    ///
    /// # Errors
    ///
    /// As [`Self::create_session`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_session_and_send(
        &self,
        selection: &CreationSelection,
        title: &str,
        text: &str,
    ) -> Result<CreatedSession, SessionError> {
        let result = async {
            let receipt = self.create(selection, title).await?;
            let first_message = match self.send(&receipt.session_id, text, false).await {
                Ok(sent) => FirstMessage::Sent(sent),
                Err(error) => FirstMessage::Failed(error),
            };
            Ok(CreatedSession {
                receipt,
                first_message,
            })
        }
        .await;
        self.dispatch();
        result
    }

    /// Sends the first message of a session this client just created, with the attachments
    /// staged and uploaded to it, without waiting for its live stream (as
    /// [`Self::create_session_and_send`] does). Never retried.
    ///
    /// # Errors
    ///
    /// As [`Self::send_message`] without `StreamNotReady`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn send_first_message(
        &self,
        session_id: &str,
        text: &str,
    ) -> Result<MessageSent, SessionError> {
        let result = self.send(session_id, text, false).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn create(
        &self,
        selection: &CreationSelection,
        title: &str,
    ) -> Result<CreationReceipt, SessionError> {
        validate_identifier(&selection.host_id)?;
        validate_identifier(&selection.agent_id)?;
        let name = title.trim();
        if name.chars().count() > MAX_TITLE_CHARS {
            return Err(CreationError::Unavailable(
                "Use a session name of 120 characters or fewer.".into(),
            )
            .into());
        }
        let catalog = self.catalog().await?;
        if let Some(reason) = catalog.unavailable_reason(&selection.agent_id, &selection.host_id) {
            return Err(CreationError::Unavailable(reason).into());
        }
        let agent = catalog
            .agent(&selection.agent_id)
            .ok_or_else(|| CreationError::Unavailable("Choose a registered agent.".into()))?
            .clone();
        let models = if selection.model.is_some() {
            self.models_for(&agent, &selection.host_id).await?
        } else {
            Vec::new()
        };
        catalog.validate(selection, &models)?;
        let body = creation_body(selection, name, &agent);
        self.submit_creation(&body).await
    }

    /// Creates a session for `agent_id` on a new sandbox the server provisions (`host_type:
    /// "managed"`), cloning `workspaces` (`<url>[#<branch>]` repositories; empty for an empty
    /// sandbox). The call returns once the session row exists; its host binds when the sandbox
    /// registers, and until then requests route by the host it requested. Sends no message.
    ///
    /// # Errors
    ///
    /// As [`Self::create_session`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_sandbox_session(
        &self,
        agent_id: &str,
        title: &str,
        workspaces: &[String],
    ) -> Result<CreationReceipt, SessionError> {
        let result = async {
            validate_identifier(agent_id)?;
            let name = title.trim();
            if name.chars().count() > MAX_TITLE_CHARS {
                return Err(CreationError::Unavailable(
                    "Use a session name of 120 characters or fewer.".into(),
                )
                .into());
            }
            let catalog = self.catalog().await?;
            let agent = catalog
                .agent(agent_id)
                .ok_or_else(|| CreationError::Unavailable("Choose a registered agent.".into()))?
                .clone();
            let body = sandbox_creation_body(agent_id, name, workspaces, &agent);
            self.submit_creation(&body).await
        }
        .await;
        self.dispatch();
        result
    }

    /// Sends a `POST /v1/sessions` body and reads the receipt. Never retried: an unclear outcome
    /// is [`CreationError::Uncertain`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn submit_creation(&self, body: &Value) -> Result<CreationReceipt, SessionError> {
        let prepared = self.prepare("POST", "/v1/sessions", &[], Some(body))?;
        let result = self.transport.send(prepared.request).await;
        let mut state = lock(&self.state);
        let response = result.map_err(|_| CreationError::Uncertain)?;
        if state.epoch != prepared.epoch || !state.is_connected() {
            return Err(CreationError::Uncertain.into());
        }
        match response.status {
            401 => {
                state.authentication_failed();
                return Err(SessionError::Unauthorized {
                    reason: error_text(&response.body),
                });
            }
            status @ (400 | 415 | 422) => {
                return Err(CreationError::Rejected {
                    status,
                    message: creation_rejection(&response.body, status),
                }
                .into());
            }
            200..=202 => {}
            _ => return Err(CreationError::Uncertain.into()),
        }
        let id = serde_json::from_slice::<Value>(&response.body)
            .ok()
            .and_then(|value| value.get("id").and_then(Value::as_str).map(str::to_owned))
            .filter(|id| is_identifier(id))
            .ok_or(CreationError::Uncertain)?;
        let summary = decode_snapshot(&response.body).ok().and_then(|decoded| {
            let epoch = state.metadata_epoch(&id);
            state.accept_projection(&decoded.projection, epoch).ok()
        });
        if let Some(summary) = &summary {
            state.events.push(ClientEvent::SessionsChanged {
                sessions: vec![summary.clone()],
            });
        }
        state.events.push(ClientEvent::InventoryInvalidated);
        Ok(CreationReceipt {
            session_id: id,
            summary,
        })
    }
}
