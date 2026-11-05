//! Custom agents over REST: listing (`GET /v1/agents`, `?scope=user`), installing a bundle
//! (multipart `POST /v1/agents`), reading and changing an agent's configuration (`GET
//! /v1/agents/{id}/config` with its `ETag`, `PATCH /v1/agents/{id}` with `If-Match`) and removing
//! one (`DELETE /v1/agents/{id}`). Writes are never retried.

use std::collections::BTreeSet;

use serde_json::{Map, Value};

use super::create::raw_page;
use super::fork::RunnerLaunch;
use super::requests::{Prepared, validate_identifier};
use super::{ClientCore, SessionError};
use crate::creation::{CreationError, CreationHost, CreationSelection, is_branch_name};
use crate::custom_agents::{AgentConfig, AgentDraft, AgentRemoval, BundledSession, ManagedAgent};
use crate::http::{HttpHeader, HttpTransport};

/// The page size of the agent listing (`scope=user` caps it at 50).
const AGENT_PAGE_LIMIT: usize = 50;

/// The most pages Settings reads per list.
const MAX_AGENT_PAGES: usize = 20;

/// The largest bundle sent; the server's own cap is larger.
const MAX_BUNDLE_BYTES: usize = 10 * 1024 * 1024;

fn malformed(path: &str) -> impl Fn(String) -> SessionError + '_ {
    move |detail| SessionError::MalformedResponse {
        detail: format!("{path}: {detail}"),
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// Every agent in a list: the server's (`mine` false) or the caller's own (`mine` true).
    ///
    /// # Errors
    ///
    /// The read errors, [`SessionError::MalformedResponse`] and
    /// [`SessionError::InvalidPagination`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn managed_agents(&self, mine: bool) -> Result<Vec<ManagedAgent>, SessionError> {
        let result = async {
            let mut agents = Vec::new();
            let mut after: Option<String> = None;
            let mut cursors = BTreeSet::new();
            for _ in 0..MAX_AGENT_PAGES {
                let mut query = vec![("limit", AGENT_PAGE_LIMIT.to_string())];
                if mine {
                    query.push(("scope", "user".to_owned()));
                }
                if let Some(cursor) = &after {
                    query.push(("after", cursor.clone()));
                }
                let value = self.get_json("/v1/agents", &query).await?;
                let page = raw_page(&value, "/v1/agents")?;
                let next = page.next_cursor(after.as_deref(), &mut cursors)?;
                for row in &page.data {
                    agents.push(ManagedAgent::from_value(row).map_err(malformed("/v1/agents"))?);
                }
                match next {
                    Some(cursor) => after = Some(cursor),
                    None => break,
                }
            }
            Ok(agents)
        }
        .await;
        self.dispatch();
        result
    }

    /// Installs (or replaces, by name) the caller's agent from a `.tar.gz` bundle, sent as the
    /// multipart `bundle` part with `boundary` (random in production). Never retried.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidInput`] before any request (an empty or oversized bundle, or one
    /// holding the boundary), and the write errors; the server's reason for a bundle it refuses
    /// is in `Rejected`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn install_agent_bundle(
        &self,
        bundle: &[u8],
        filename: &str,
        boundary: &str,
    ) -> Result<ManagedAgent, SessionError> {
        let result = async {
            let invalid = |reason: &str| SessionError::InvalidInput {
                reason: reason.to_owned(),
            };
            if bundle.is_empty() {
                return Err(invalid("The bundle is empty."));
            }
            if bundle.len() > MAX_BUNDLE_BYTES {
                return Err(invalid("The bundle is larger than 10 MB."));
            }
            let parts = [Part::bundle(filename, bundle)];
            let prepared = self.prepare_multipart("/v1/agents", &parts, boundary)?;
            let response = self.write(prepared).await?;
            let value: Value = serde_json::from_slice(&response.body).map_err(|error| {
                SessionError::DeliveryUncertain {
                    detail: format!("unreadable acknowledgement from /v1/agents: {error}"),
                }
            })?;
            ManagedAgent::from_value(&value).map_err(|detail| SessionError::DeliveryUncertain {
                detail: format!("unreadable acknowledgement from /v1/agents: {detail}"),
            })
        }
        .await;
        self.dispatch();
        result
    }

    /// The caller's agent `agent_id`'s configuration and its revision.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request, the read errors (`HttpStatus`
    /// 404 for an agent that is not the caller's, 409 for a bundle that cannot be edited) and
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn agent_config(&self, agent_id: &str) -> Result<AgentConfig, SessionError> {
        let result = async {
            validate_identifier(agent_id)?;
            let path = format!("/v1/agents/{agent_id}/config");
            let response = self.read(self.prepare("GET", &path, &[], None)?).await?;
            decode_config(&response.body, response.header("ETag"), &path)
        }
        .await;
        self.dispatch();
        result
    }

    /// Changes `agent_id`'s configuration with a `PATCH` body from
    /// [`crate::custom_agents::config_patch`], checked against `etag` when given (a changed
    /// agent is `Rejected` 412). Never retried.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request, and the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn update_agent_config(
        &self,
        agent_id: &str,
        etag: Option<&str>,
        patch: &Value,
    ) -> Result<AgentConfig, SessionError> {
        let result = async {
            validate_identifier(agent_id)?;
            let route = format!("/v1/agents/{agent_id}");
            let mut prepared = self.prepare("PATCH", &route, &[], Some(patch))?;
            if let Some(etag) = etag {
                prepared
                    .request
                    .headers
                    .push(HttpHeader::new("If-Match", etag));
            }
            let response = self.write(prepared).await?;
            decode_config(&response.body, response.header("ETag"), &route).map_err(|error| {
                SessionError::DeliveryUncertain {
                    detail: error.to_string(),
                }
            })
        }
        .await;
        self.dispatch();
        result
    }

    /// Removes the caller's agent `agent_id`. Without `force`, an agent sessions still use is
    /// kept and [`AgentRemoval::InUse`] says how many. Never retried.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request, and the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn remove_agent(
        &self,
        agent_id: &str,
        force: bool,
    ) -> Result<AgentRemoval, SessionError> {
        let result = async {
            validate_identifier(agent_id)?;
            let path = format!("/v1/agents/{agent_id}");
            let query = if force {
                vec![("force", "true".to_owned())]
            } else {
                Vec::new()
            };
            match self
                .write(self.prepare("DELETE", &path, &query, None)?)
                .await
            {
                Ok(_) => Ok(AgentRemoval::Removed),
                Err(SessionError::Rejected {
                    status: 409,
                    message,
                }) if !force => Ok(AgentRemoval::InUse { message }),
                Err(error) => Err(error),
            }
        }
        .await;
        self.dispatch();
        result
    }
}

/// One `multipart/form-data` part.
struct Part<'a> {
    name: &'static str,
    filename: Option<String>,
    content_type: &'static str,
    bytes: &'a [u8],
}

impl<'a> Part<'a> {
    fn bundle(filename: &str, bytes: &'a [u8]) -> Self {
        Self {
            name: "bundle",
            filename: Some(filename.replace(['"', '\r', '\n'], "_")),
            content_type: "application/gzip",
            bytes,
        }
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// A multipart `POST` of `parts` with `boundary`, which may not occur in any part.
    fn prepare_multipart(
        &self,
        path: &str,
        parts: &[Part<'_>],
        boundary: &str,
    ) -> Result<Prepared, SessionError> {
        let delimiter = format!("--{boundary}");
        let collides = |bytes: &[u8]| {
            bytes
                .windows(delimiter.len())
                .any(|window| window == delimiter.as_bytes())
        };
        if boundary.is_empty() || parts.iter().any(|part| collides(part.bytes)) {
            return Err(SessionError::InvalidInput {
                reason: "The upload could not be prepared. Try again.".to_owned(),
            });
        }
        let mut body = Vec::new();
        for part in parts {
            let filename = part
                .filename
                .as_ref()
                .map(|name| format!("; filename=\"{name}\""))
                .unwrap_or_default();
            body.extend_from_slice(
                format!(
                    "{delimiter}\r\nContent-Disposition: form-data; name=\"{}\"{filename}\r\nContent-Type: {}\r\n\r\n",
                    part.name, part.content_type
                )
                .as_bytes(),
            );
            body.extend_from_slice(part.bytes);
            body.extend_from_slice(b"\r\n");
        }
        body.extend_from_slice(format!("{delimiter}--\r\n").as_bytes());
        let mut prepared = self.prepare("POST", path, &[], None)?;
        prepared.request.headers.push(HttpHeader::new(
            "Content-Type",
            format!("multipart/form-data; boundary={boundary}"),
        ));
        prepared.request.body = Some(body);
        Ok(prepared)
    }

    /// Creates a session running the unsaved custom agent `draft` (its bundle uploaded with
    /// the session, as the web's Create custom agent does; `agent_install` is not needed), then
    /// starts it on `selection`'s host in its workspace and worktree. Never retried: an unclear
    /// creation is [`CreationError::Uncertain`]; a failed start is [`RunnerLaunch::Failed`].
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidInput`] for a draft that cannot be saved; [`CreationError::Unavailable`]
    /// for a host that is offline or a sandbox, or a workspace or branch it would refuse; the
    /// creation errors of [`Self::create_session`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_session_with_agent(
        &self,
        draft: &AgentDraft,
        selection: &CreationSelection,
        title: &str,
        boundary: &str,
    ) -> Result<BundledSession, SessionError> {
        let result = async {
            if let Some(reason) = draft.problem() {
                return Err(SessionError::InvalidInput { reason });
            }
            validate_identifier(&selection.host_id)?;
            let hosts = self
                .host_rows()
                .await?
                .iter()
                .map(CreationHost::from_value)
                .collect::<Result<Vec<_>, String>>()
                .map_err(|detail| SessionError::MalformedResponse { detail })?;
            let host = hosts.iter().find(|host| host.host_id == selection.host_id);
            if !host.is_some_and(CreationHost::is_available) {
                return Err(CreationError::Unavailable(
                    "Connect this host before starting a session.".into(),
                )
                .into());
            }
            let workspace = selection.workspace.trim();
            if !workspace.starts_with('/') || workspace.contains('\0') {
                return Err(CreationError::Unavailable(
                    "Enter an absolute workspace path beginning with /.".into(),
                )
                .into());
            }
            if let Some(git) = &selection.git
                && !is_branch_name(&git.branch_name)
            {
                return Err(CreationError::Unavailable(
                    "Enter a branch name without spaces, `..` or a leading `-`.".into(),
                )
                .into());
            }
            let mut metadata = Map::new();
            metadata.insert("workspace".into(), Value::String(workspace.to_owned()));
            if let Some(project) = &selection.project_id {
                validate_identifier(project)?;
                metadata.insert("project_id".into(), Value::String(project.clone()));
            }
            let title = title.trim();
            if !title.is_empty() {
                metadata.insert("title".into(), Value::String(title.to_owned()));
            }
            let metadata = Value::Object(metadata).to_string();
            let bundle = draft.bundle();
            let parts = [
                Part {
                    name: "metadata",
                    filename: None,
                    content_type: "application/json",
                    bytes: metadata.as_bytes(),
                },
                Part::bundle(&format!("{}.tar.gz", draft.name.trim()), &bundle),
            ];
            let prepared = self.prepare_multipart("/v1/sessions", &parts, boundary)?;
            let receipt = self.submit_prepared_creation(prepared).await?;
            let launch = match self
                .launch_session_runner(
                    &selection.host_id,
                    &receipt.session_id,
                    workspace,
                    selection.git.as_ref(),
                )
                .await
            {
                Ok(runner_id) => RunnerLaunch::Launched { runner_id },
                Err(error) => RunnerLaunch::Failed(error),
            };
            Ok(BundledSession { receipt, launch })
        }
        .await;
        self.dispatch();
        result
    }
}

fn decode_config(body: &[u8], etag: Option<&str>, path: &str) -> Result<AgentConfig, SessionError> {
    let value: Value =
        serde_json::from_slice(body).map_err(|error| malformed(path)(error.to_string()))?;
    AgentConfig::from_value(&value, etag.map(str::to_owned)).map_err(malformed(path))
}

#[cfg(test)]
#[path = "custom_agents_tests.rs"]
mod tests;
