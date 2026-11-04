//! Custom agents over REST: listing (`GET /v1/agents`, `?scope=user`), installing a bundle
//! (multipart `POST /v1/agents`), reading and changing an agent's configuration (`GET
//! /v1/agents/{id}/config` with its `ETag`, `PATCH /v1/agents/{id}` with `If-Match`) and removing
//! one (`DELETE /v1/agents/{id}`). Writes are never retried.

use std::collections::BTreeSet;

use serde_json::Value;

use super::create::raw_page;
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::custom_agents::{AgentConfig, AgentRemoval, ManagedAgent};
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
            let delimiter = format!("--{boundary}");
            if boundary.is_empty()
                || bundle
                    .windows(delimiter.len())
                    .any(|window| window == delimiter.as_bytes())
            {
                return Err(invalid("The bundle could not be prepared. Try again."));
            }
            let name = filename.replace(['"', '\r', '\n'], "_");
            let mut body = format!(
                "{delimiter}\r\nContent-Disposition: form-data; name=\"bundle\"; filename=\"{name}\"\r\nContent-Type: application/gzip\r\n\r\n"
            )
            .into_bytes();
            body.extend_from_slice(bundle);
            body.extend_from_slice(format!("\r\n{delimiter}--\r\n").as_bytes());
            let mut prepared = self.prepare("POST", "/v1/agents", &[], None)?;
            prepared.request.headers.push(HttpHeader::new(
                "Content-Type",
                format!("multipart/form-data; boundary={boundary}"),
            ));
            prepared.request.body = Some(body);
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

fn decode_config(body: &[u8], etag: Option<&str>, path: &str) -> Result<AgentConfig, SessionError> {
    let value: Value =
        serde_json::from_slice(body).map_err(|error| malformed(path)(error.to_string()))?;
    AgentConfig::from_value(&value, etag.map(str::to_owned)).map_err(malformed(path))
}

#[cfg(test)]
#[path = "custom_agents_tests.rs"]
mod tests;
