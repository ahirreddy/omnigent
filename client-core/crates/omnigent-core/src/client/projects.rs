//! The caller's projects (sidebar folders): `GET /v1/sessions/projects` lists them, and
//! `/v1/projects` creates, renames and deletes first-class ones.
//!
//! Membership is dual-read, as on the web (`sessionBelongsToProject`): a session is in a project
//! when it carries the project's `project_id`, or the legacy `omni_project` label of its name,
//! and the caller owns it. Label-only projects have no id until a rename promotes them.

use std::collections::BTreeSet;

use omnigent_protocol::FromWire;
use omnigent_protocol::sessions::SessionList;
use serde_json::{Value, json};

use super::requests::{page_query, validate_identifier};
use super::sessions::{PROJECT_LABEL, SessionPage, SessionSummary, decode_snapshot_value};
use super::{ClientCore, ClientEvent, SessionError, lock};
use crate::http::HttpTransport;

/// The longest project name the server accepts.
pub const MAX_PROJECT_NAME_CHARS: usize = 120;

/// One of the caller's projects.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ProjectSummary {
    /// The first-class project id; `None` for a legacy label-only project.
    pub id: Option<String>,
    /// The name.
    pub name: String,
    /// An emoji icon (`config.icon`), when set.
    pub icon: Option<String>,
}

impl ProjectSummary {
    /// Whether `session` is filed here and owned by `viewer_id` (filing is owner-only).
    #[must_use]
    pub fn contains(&self, session: &SessionSummary, viewer_id: Option<&str>) -> bool {
        session.is_owned_by(viewer_id)
            && (self
                .id
                .as_ref()
                .is_some_and(|id| session.project_id.as_ref() == Some(id))
                || session.project_label.as_deref() == Some(self.name.as_str()))
    }
}

/// The ids of `projects` grouping `sessions` (in the given order), one list per project.
#[must_use]
pub fn project_members(
    projects: &[ProjectSummary],
    sessions: &[SessionSummary],
    viewer_id: Option<&str>,
) -> Vec<Vec<String>> {
    projects
        .iter()
        .map(|project| {
            sessions
                .iter()
                .filter(|session| project.contains(session, viewer_id))
                .map(|session| session.id.clone())
                .collect()
        })
        .collect()
}

pub(super) fn project_from(value: &Value) -> Result<ProjectSummary, String> {
    let name = value
        .get("name")
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty())
        .ok_or("a project without a name")?
        .to_owned();
    let id = match value.get("id") {
        None | Some(Value::Null) => None,
        Some(Value::String(id)) if !id.is_empty() => Some(id.clone()),
        Some(other) => return Err(format!("project id {other} is not a string")),
    };
    let icon = value
        .get("icon")
        .or_else(|| value.get("config").and_then(|config| config.get("icon")))
        .and_then(Value::as_str)
        .filter(|icon| !icon.is_empty())
        .map(str::to_owned);
    Ok(ProjectSummary { id, name, icon })
}

fn validate_name(name: &str) -> Result<String, SessionError> {
    let cleaned = name.trim();
    if cleaned.is_empty() || cleaned.chars().count() > MAX_PROJECT_NAME_CHARS {
        return Err(SessionError::InvalidTitle);
    }
    Ok(cleaned.to_owned())
}

impl<T: HttpTransport> ClientCore<T> {
    /// One page of the caller's unarchived sessions filed under `name`, most recently updated
    /// first (the web folder's `?project=` read, which matches ids and legacy labels). The rows
    /// are published as a `SessionsChanged`, so the list holds them too.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidPageLimit`] and [`SessionError::InvalidPagination`] before any
    /// request; the read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn project_session_page(
        &self,
        name: &str,
        after: Option<&str>,
        limit: u32,
    ) -> Result<SessionPage, SessionError> {
        let result = async {
            let mut query = page_query(after, limit)?;
            query.push(("sort_by", "updated_at".to_owned()));
            query.push(("visibility", "mine".to_owned()));
            query.push(("project", name.to_owned()));
            self.read_list(&query, after).await
        }
        .await;
        if let Ok((sessions, _)) = &result
            && !sessions.is_empty()
        {
            lock(&self.state).events.push(ClientEvent::SessionsChanged {
                sessions: sessions.clone(),
            });
        }
        self.dispatch();
        result.map(|(sessions, next_cursor)| SessionPage {
            sessions: sessions
                .into_iter()
                .filter(|session| !session.is_archived)
                .collect(),
            next_cursor,
        })
    }

    /// The caller's projects in their display order (`GET /v1/sessions/projects`). A server
    /// without projects (404) has none.
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`] for a body that is not a list of
    /// projects.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn projects(&self) -> Result<Vec<ProjectSummary>, SessionError> {
        let result = self.get_json("/v1/sessions/projects", &[]).await;
        self.dispatch();
        if matches!(result, Err(SessionError::HttpStatus { status: 404 })) {
            return Ok(Vec::new());
        }
        let malformed = |detail: String| SessionError::MalformedResponse {
            detail: format!("/v1/sessions/projects: {detail}"),
        };
        result?
            .as_array()
            .ok_or_else(|| malformed("not a list".into()))?
            .iter()
            .map(project_from)
            .collect::<Result<_, _>>()
            .map_err(malformed)
    }

    /// Creates an empty first-class project (`POST /v1/projects`).
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidTitle`] for an empty or over-long name, before any request;
    /// `Rejected` (409) for a name already in use; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_project(&self, name: &str) -> Result<ProjectSummary, SessionError> {
        let result = self.create_project_row(name).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn create_project_row(&self, name: &str) -> Result<ProjectSummary, SessionError> {
        let name = validate_name(name)?;
        let created = self
            .write_json("POST", "/v1/projects", &json!({"name": name}))
            .await?;
        project_from(&created).map_err(|detail| SessionError::DeliveryUncertain {
            detail: format!("unreadable /v1/projects acknowledgement: {detail}"),
        })
    }

    /// Renames a project. A first-class one is renamed in place; a label-only one is promoted
    /// to a first-class project under the new name. Either way every member is re-filed onto
    /// the project id with its legacy label cleared, as the web's `useRenameProject`.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidTitle`] before any request; the read and write errors. Members
    /// re-filed before a failure stay re-filed.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn rename_project(
        &self,
        project: &ProjectSummary,
        new_name: &str,
    ) -> Result<ProjectSummary, SessionError> {
        let result = self.rename_project_rows(project, new_name).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn rename_project_rows(
        &self,
        project: &ProjectSummary,
        new_name: &str,
    ) -> Result<ProjectSummary, SessionError> {
        let name = validate_name(new_name)?;
        let renamed = if let Some(id) = &project.id {
            validate_identifier(id)?;
            let path = format!("/v1/projects/{id}");
            let acknowledgement = self
                .write_json("PATCH", &path, &json!({"name": name}))
                .await?;
            project_from(&acknowledgement).map_err(|detail| SessionError::DeliveryUncertain {
                detail: format!("unreadable {path} acknowledgement: {detail}"),
            })?
        } else {
            self.create_project_row(&name).await?
        };
        let Some(id) = renamed.id.clone() else {
            return Err(SessionError::DeliveryUncertain {
                detail: "the renamed project has no id".into(),
            });
        };
        for session_id in self.project_member_ids(&project.name).await? {
            self.patch_member(
                &session_id,
                &json!({"project_id": id, "labels": {PROJECT_LABEL: ""}}),
            )
            .await?;
        }
        Ok(renamed)
    }

    /// Deletes a project: every member is archived and removed from it (sessions are never
    /// deleted), then the first-class project itself, as the web's `useDeleteProject`.
    ///
    /// # Errors
    ///
    /// The read and write errors. When a member cannot be changed (for example a shared session
    /// the caller does not own), the others are still changed, the project is kept, and the
    /// first failure is returned.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn delete_project(&self, project: &ProjectSummary) -> Result<(), SessionError> {
        let result = self.delete_project_rows(project).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn delete_project_rows(&self, project: &ProjectSummary) -> Result<(), SessionError> {
        let body = json!({"archived": true, "project_id": "", "labels": {PROJECT_LABEL: ""}});
        let mut first_failure = None;
        for session_id in self.project_member_ids(&project.name).await? {
            if let Err(error) = self.patch_member(&session_id, &body).await {
                first_failure.get_or_insert(error);
            }
        }
        if let Some(error) = first_failure {
            return Err(error);
        }
        if let Some(id) = &project.id {
            validate_identifier(id)?;
            let path = format!("/v1/projects/{id}");
            self.write(self.prepare("DELETE", &path, &[], None)?)
                .await?;
        }
        Ok(())
    }

    /// Saves `projects` as the caller's manual order (`PUT /v1/projects/order`), as the web's
    /// `useSaveProjectOrder`: label-only projects are promoted first so every entry has an id.
    /// Returns the projects with their ids.
    ///
    /// # Errors
    ///
    /// The promotion's errors (see [`Self::rename_project`]); the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn save_project_order(
        &self,
        projects: &[ProjectSummary],
    ) -> Result<Vec<ProjectSummary>, SessionError> {
        let result = self.save_project_order_rows(projects).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn save_project_order_rows(
        &self,
        projects: &[ProjectSummary],
    ) -> Result<Vec<ProjectSummary>, SessionError> {
        let mut ordered = Vec::with_capacity(projects.len());
        for project in projects {
            if project.id.is_some() {
                ordered.push(project.clone());
            } else {
                ordered.push(self.rename_project_rows(project, &project.name).await?);
            }
        }
        let ids: Vec<&str> = ordered
            .iter()
            .filter_map(|project| project.id.as_deref())
            .collect();
        self.write_json(
            "PUT",
            "/v1/projects/order",
            &json!({"ordered_project_ids": ids}),
        )
        .await?;
        Ok(ordered)
    }

    /// Every session filed under `name` (dual-read `?project=`), archived included.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn project_member_ids(&self, name: &str) -> Result<Vec<String>, SessionError> {
        let mut ids = Vec::new();
        let mut cursors = BTreeSet::new();
        let mut after: Option<String> = None;
        loop {
            let mut query = page_query(after.as_deref(), 100)?;
            query.push(("sort_by", "updated_at".to_owned()));
            query.push(("visibility", "all".to_owned()));
            query.push(("include_archived", "true".to_owned()));
            query.push(("project", name.to_owned()));
            let response = self
                .read(self.prepare("GET", "/v1/sessions", &query, None)?)
                .await?;
            let page = SessionList::from_json(&response.body).map_err(|error| {
                SessionError::MalformedResponse {
                    detail: format!("/v1/sessions?project: {error}"),
                }
            })?;
            ids.extend(page.data.iter().map(|row| row.id.clone()));
            let next = page
                .next_cursor(after.as_deref())
                .map_err(|_| SessionError::InvalidPagination)?
                .map(str::to_owned);
            match next {
                None => return Ok(ids),
                Some(cursor) if !cursors.insert(cursor.clone()) => {
                    return Err(SessionError::InvalidPagination);
                }
                Some(cursor) => after = Some(cursor),
            }
        }
    }

    /// `PATCH /v1/sessions/{id}` with `body`, publishing the acknowledged summary.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn patch_member(&self, session_id: &str, body: &Value) -> Result<(), SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}");
        let epoch = lock(&self.state).metadata_epoch(session_id);
        let acknowledgement = self.write_json("PATCH", &path, body).await?;
        let decoded = decode_snapshot_value(acknowledgement).map_err(|detail| {
            SessionError::DeliveryUncertain {
                detail: format!("unreadable {path} acknowledgement: {detail}"),
            }
        })?;
        let mut state = lock(&self.state);
        let updated = state.accept_projection(&decoded.projection, epoch)?;
        state.events.push(ClientEvent::SessionsChanged {
            sessions: vec![updated],
        });
        state.events.push(ClientEvent::InventoryInvalidated);
        Ok(())
    }
}

#[cfg(test)]
#[path = "projects_tests.rs"]
mod tests;
