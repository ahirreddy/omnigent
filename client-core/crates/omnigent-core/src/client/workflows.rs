//! Saved workflows over REST (`/v1/workflows…`): the caller's and those shared with them, a
//! workflow with its steps, its writes, its runs and who it is shared with. Servers advertise
//! them with `features.workflows` and `workflows` in `/v1/info` ([`super::automations::ServerPages`]).

use serde_json::{Map, Value, json};

use super::automations::AutomationGrant;
use super::requests::{rejection_message, validate_identifier};
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;
use crate::session_journal::{JournalPage, PlanStep};
use crate::workflows::proposal::DescriptionWrite;
use crate::workflows::{
    DESCRIPTION_MAX_CHARS, NAME_MAX_CHARS, WorkflowDetail, WorkflowPage, WorkflowRunPage,
    clone_name, steps_json,
};

/// The caller's workflows per page, as the web reads them.
const OWNED_PAGE_SIZE: u32 = 200;
/// Shared workflows per page.
const SHARED_PAGE_SIZE: u32 = 100;
/// Runs per page.
const RUNS_PAGE_SIZE: u32 = 20;
/// Clone tries "(copy)", "(copy 2)", … up to this many names before giving up.
const MAX_CLONE_NAMES: u32 = 100;

fn malformed(path: &str) -> impl Fn(String) -> SessionError + '_ {
    move |detail| SessionError::MalformedResponse {
        detail: format!("{path}: {detail}"),
    }
}

fn workflow_path(id: &str) -> Result<String, SessionError> {
    validate_identifier(id)?;
    Ok(format!("/v1/workflows/{id}"))
}

fn detail_from(path: &str, value: &Value) -> Result<WorkflowDetail, SessionError> {
    WorkflowDetail::from_value(value).map_err(|detail| SessionError::DeliveryUncertain {
        detail: format!("unreadable acknowledgement from {path}: {detail}"),
    })
}

/// Whether a `422` body is a server from before conditional descriptions refusing their fields.
fn refuses_expected_description(body: &[u8]) -> bool {
    let Ok(value) = serde_json::from_slice::<Value>(body) else {
        return false;
    };
    value
        .get("detail")
        .and_then(Value::as_array)
        .is_some_and(|issues| {
            issues.iter().any(|issue| {
                issue.get("type").and_then(Value::as_str) == Some("extra_forbidden")
                    && issue
                        .get("loc")
                        .and_then(Value::as_array)
                        .and_then(|loc| loc.last())
                        .and_then(Value::as_str)
                        .is_some_and(|field| {
                            field == "expected_description" || field == "description_source"
                        })
            })
        })
}

fn checked_text(value: &str, what: &str, limit: usize) -> Result<String, SessionError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(SessionError::InvalidInput {
            reason: format!("Enter the workflow's {what}."),
        });
    }
    if trimmed.chars().count() > limit {
        return Err(SessionError::InvalidInput {
            reason: format!("Keep the workflow's {what} to {limit} characters."),
        });
    }
    Ok(trimmed.to_owned())
}

impl<T: HttpTransport> ClientCore<T> {
    /// One page of the caller's workflows by name, drafts included (`GET /v1/workflows`).
    ///
    /// # Errors
    ///
    /// The read errors (`404` while the server has workflows off);
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn workflows(&self, after: Option<&str>) -> Result<WorkflowPage, SessionError> {
        let result = self
            .workflow_page("/v1/workflows", OWNED_PAGE_SIZE, after, false)
            .await;
        self.dispatch();
        result
    }

    /// One page of the workflows other people shared with the caller, by id
    /// (`GET /v1/workflows/shared`). A page can be short, even empty, while more follow.
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn shared_workflows(
        &self,
        after: Option<&str>,
    ) -> Result<WorkflowPage, SessionError> {
        let result = self
            .workflow_page("/v1/workflows/shared", SHARED_PAGE_SIZE, after, true)
            .await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn workflow_page(
        &self,
        path: &str,
        limit: u32,
        after: Option<&str>,
        shared: bool,
    ) -> Result<WorkflowPage, SessionError> {
        let mut query = vec![("limit", limit.to_string())];
        if let Some(after) = after {
            query.push(("after", after.to_owned()));
        }
        let value = self.get_json(path, &query).await?;
        let page = if shared {
            WorkflowPage::from_shared_value(&value)
        } else {
            WorkflowPage::from_owned_value(&value)
        };
        page.map_err(malformed(path))
    }

    /// A workflow with its steps (`GET /v1/workflows/{id}`), the caller's or one shared with
    /// them.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the read errors, `HttpStatus` `404` for a workflow that is gone or
    /// not the caller's to read; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn workflow(&self, id: &str) -> Result<WorkflowDetail, SessionError> {
        let result = async {
            let path = workflow_path(id)?;
            let value = self.get_json(&path, &[]).await?;
            WorkflowDetail::from_value(&value).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }

    /// Saves a draft with no steps (`POST /v1/workflows`), before its planning chat starts.
    ///
    /// # Errors
    ///
    /// `InvalidInput` for a blank or too long name or description, before any request; the write
    /// errors (`Rejected` `409` for a name the caller already uses).
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_workflow_draft(
        &self,
        name: &str,
        description: &str,
    ) -> Result<WorkflowDetail, SessionError> {
        let result = async {
            let name = checked_text(name, "name", NAME_MAX_CHARS)?;
            let description = checked_text(description, "description", DESCRIPTION_MAX_CHARS)?;
            let path = "/v1/workflows";
            let body = json!({"name": name, "description": description, "steps": []});
            let value = self.write_json("POST", path, &body).await?;
            detail_from(path, &value)
        }
        .await;
        self.dispatch();
        result
    }

    /// Copies a workflow's saved plan into a new one of the caller's, without its planning chat
    /// or runs, named "Name (copy)" or the next free "(copy N)".
    ///
    /// # Errors
    ///
    /// The read and write errors; `Rejected` `409` once no free name was found.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn clone_workflow(&self, id: &str) -> Result<WorkflowDetail, SessionError> {
        let result = async {
            let path = workflow_path(id)?;
            let value = self.get_json(&path, &[]).await?;
            let source = WorkflowDetail::from_value(&value).map_err(malformed(&path))?;
            for copy in 1..=MAX_CLONE_NAMES {
                let body = json!({
                    "name": clone_name(&source.workflow.name, copy),
                    "description": source.workflow.description,
                    "steps": steps_json(&source.steps),
                });
                // A taken name tries the next one.
                if let Ok(saved) = self
                    .write_json_or_conflict("POST", "/v1/workflows", &body)
                    .await?
                {
                    return detail_from("/v1/workflows", &saved);
                }
            }
            Err(SessionError::Rejected {
                status: 409,
                message: "Every copy name is taken. Rename a copy and try again.".to_owned(),
            })
        }
        .await;
        self.dispatch();
        result
    }

    /// Applies a reviewed proposal: its steps and, when it has one, the description the user
    /// chose (`PATCH /v1/workflows/{id}`). The server keeps a description written meanwhile; a
    /// server too old to check gets the steps alone.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn save_workflow_plan(
        &self,
        id: &str,
        steps: &[PlanStep],
        description: Option<&DescriptionWrite>,
    ) -> Result<WorkflowDetail, SessionError> {
        let result = async {
            let path = workflow_path(id)?;
            let mut body = Map::new();
            body.insert("steps".to_owned(), steps_json(steps));
            if let Some(write) = description {
                body.insert("description".to_owned(), json!(write.description));
                body.insert(
                    "expected_description".to_owned(),
                    json!(write.expected_description),
                );
                body.insert(
                    "description_source".to_owned(),
                    json!(write.description_source),
                );
            }
            let prepared = self.prepare("PATCH", &path, &[], Some(&Value::Object(body)))?;
            let response = self.write_allowing(prepared, Some(422)).await?;
            if response.status == 422 {
                if description.is_some() && refuses_expected_description(&response.body) {
                    let steps_only = json!({"steps": steps_json(steps)});
                    let value = self.write_json("PATCH", &path, &steps_only).await?;
                    return detail_from(&path, &value);
                }
                return Err(SessionError::Rejected {
                    status: 422,
                    message: rejection_message(&response.body, 422),
                });
            }
            let value = super::requests::acknowledgement(&path, &response)?;
            detail_from(&path, &value)
        }
        .await;
        self.dispatch();
        result
    }

    /// Replaces the description with the user's own wording, which clears its source.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` and `InvalidInput` before any request; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn save_workflow_description(
        &self,
        id: &str,
        description: &str,
    ) -> Result<WorkflowDetail, SessionError> {
        let result = async {
            let path = workflow_path(id)?;
            let description = checked_text(description, "description", DESCRIPTION_MAX_CHARS)?;
            let value = self
                .write_json("PATCH", &path, &json!({"description": description}))
                .await?;
            detail_from(&path, &value)
        }
        .await;
        self.dispatch();
        result
    }

    /// Keeps `session_id` as the workflow's planning chat, so it reopens on any device.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn set_workflow_planning_session(
        &self,
        id: &str,
        session_id: &str,
    ) -> Result<WorkflowDetail, SessionError> {
        let result = async {
            let path = workflow_path(id)?;
            validate_identifier(session_id)?;
            let value = self
                .write_json("PATCH", &path, &json!({"planning_session_id": session_id}))
                .await?;
            detail_from(&path, &value)
        }
        .await;
        self.dispatch();
        result
    }

    /// Deletes one of the caller's workflows; its runs' sessions stay.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn delete_workflow(&self, id: &str) -> Result<(), SessionError> {
        let result = async {
            let path = workflow_path(id)?;
            self.write(self.prepare("DELETE", &path, &[], None)?)
                .await
                .map(|_| ())
        }
        .await;
        self.dispatch();
        result
    }

    /// One page of the sessions that ran a workflow, newest first, before `before`; only
    /// `session_id`'s runs when given (`GET /v1/workflows/{id}/runs`).
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn workflow_runs(
        &self,
        id: &str,
        before: Option<&str>,
        session_id: Option<&str>,
    ) -> Result<WorkflowRunPage, SessionError> {
        let result = async {
            let path = format!("{}/runs", workflow_path(id)?);
            let mut query = vec![("limit", RUNS_PAGE_SIZE.to_string())];
            if let Some(before) = before {
                query.push(("before", before.to_owned()));
            }
            if let Some(session_id) = session_id {
                validate_identifier(session_id)?;
                query.push(("session_id", session_id.to_owned()));
            }
            let value = self.get_json(&path, &query).await?;
            WorkflowRunPage::from_value(&value).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }

    /// The workflow runs below run `run_id` of session `session_id`, after `after`
    /// (`GET /v1/workflows/{id}/runs/{run_id}/descendant_runs`).
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn workflow_run_descendants(
        &self,
        workflow_id: &str,
        run_id: &str,
        session_id: &str,
        after: Option<&str>,
    ) -> Result<WorkflowRunPage, SessionError> {
        let result = async {
            validate_identifier(run_id)?;
            validate_identifier(session_id)?;
            let path = format!(
                "{}/runs/{run_id}/descendant_runs",
                workflow_path(workflow_id)?
            );
            let mut query = vec![
                ("session_id", session_id.to_owned()),
                ("limit", RUNS_PAGE_SIZE.to_string()),
            ];
            if let Some(after) = after {
                query.push(("after", after.to_owned()));
            }
            let value = self.get_json(&path, &query).await?;
            WorkflowRunPage::from_value(&value).map_err(malformed(&path))
        }
        .await;
        self.dispatch();
        result
    }

    /// Where journal entry `entry_id` sits in session `session_id`'s journal: just after the
    /// entry before it, or first; `None` when the journal doesn't hold it (the server refuses it
    /// as a cursor).
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the other read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn journal_entry_position(
        &self,
        session_id: &str,
        entry_id: &str,
    ) -> Result<Option<i64>, SessionError> {
        let result = async {
            validate_identifier(session_id)?;
            validate_identifier(entry_id)?;
            let path = format!("/v1/sessions/{session_id}/journal");
            let query = [
                ("order", "desc".to_owned()),
                ("after", entry_id.to_owned()),
                ("limit", "1".to_owned()),
            ];
            let value = match self.get_json(&path, &query).await {
                Err(SessionError::HttpStatus { status: 400 }) => return Ok(None),
                other => other?,
            };
            let page = JournalPage::from_value(&value).map_err(malformed(&path))?;
            Ok(Some(
                page.data
                    .first()
                    .map_or(0, |entry| entry.position.saturating_add(1)),
            ))
        }
        .await;
        self.dispatch();
        result
    }

    /// Everyone a workflow is shared with, at read access; only its owner may list them.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the read errors; `MalformedResponse` and `InvalidPagination`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn workflow_grants(&self, id: &str) -> Result<Vec<AutomationGrant>, SessionError> {
        let result = async {
            let path = format!("{}/permissions", workflow_path(id)?);
            self.read_grants(&path).await
        }
        .await;
        self.dispatch();
        result
    }

    /// Shares a workflow with `user_id`, who may view, run and copy it. Never retried.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; the write errors (`Rejected` with the server's
    /// reason, `Forbidden`).
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn grant_workflow_access(&self, id: &str, user_id: &str) -> Result<(), SessionError> {
        let result = async {
            let path = format!("{}/permissions", workflow_path(id)?);
            self.grant_read_access(&path, user_id).await
        }
        .await;
        self.dispatch();
        result
    }

    /// Stops sharing a workflow with `user_id`. Never retried.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn revoke_workflow_access(
        &self,
        id: &str,
        user_id: &str,
    ) -> Result<(), SessionError> {
        let result = async {
            let path = format!("{}/permissions", workflow_path(id)?);
            self.revoke_access(&path, user_id).await
        }
        .await;
        self.dispatch();
        result
    }
}

#[cfg(test)]
#[path = "workflows_tests.rs"]
mod tests;
