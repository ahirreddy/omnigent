//! Typed requests for the session workspace routes, and their decoding.
//!
//! A [`WorkspaceRequest`] is validated when it is made, so nothing invalid is ever sent. It
//! builds an [`HttpRequest`] from a [`HostedConnection`] (or a [`ServerEndpoint`] and bearer)
//! and decodes the matching [`HttpResponse`] with the workspace status policy
//! ([`super::error`]). The host sends it through its own `HttpTransport`.
//!
//! Routes, under `/v1/sessions/{session}/resources`:
//!
//! | Operation | Route |
//! |---|---|
//! | [`WorkspaceOperation::ListEnvironments`] | `GET environments` |
//! | [`WorkspaceOperation::GetEnvironment`] | `GET environments/{env}` |
//! | [`WorkspaceOperation::ListDirectory`] | `GET environments/{env}/filesystem[/{path}]?limit&order=asc[&after]` |
//! | [`WorkspaceOperation::ReadFile`] | `GET environments/{env}/filesystem/{path}` |
//! | [`WorkspaceOperation::SearchPaths`] | `GET environments/{env}/search[/{path}]?q&limit[&include][&exclude]` |
//! | [`WorkspaceOperation::SearchContent`] | `GET environments/{env}/content-search?q&case_sensitive&regex&include&exclude&limit` |
//! | [`WorkspaceOperation::ListChanges`] | `GET environments/{env}/changes` |
//! | [`WorkspaceOperation::FileDiff`] | `GET environments/{env}/diff/{path}` (not in `openapi.json`) |
//! | [`WorkspaceOperation::ListSessionFiles`] | `GET files?limit&order=desc[&after]` |
//!
//! File paths are sent one percent-encoded segment per path segment (`docs/caf%C3%A9%20notes.md`),
//! exactly as the web client's `browseLocationSegment` does, never with a leading `%2F`.

use url::Url;

use super::content::{FileContent, file_content};
use super::error::{NotFoundMeaning, WorkspaceError, check};
use super::model::{
    ChangesList, DirectoryPage, FileDiffContent, PathSearchResult, SessionFilesPage,
    WorkspaceEnvironment, changes, directory_page, environments, file_diff, path_search,
    session_files, single_environment,
};
use super::path::WorkspacePath;
use super::search::{
    ContentSearchQuery, ContentSearchResult, PathSearchQuery, content_search, joined_globs,
};
use crate::attachments::policy::is_identifier;
use crate::auth::SecretString;
use crate::auth::endpoint::ServerEndpoint;
use crate::auth::hosted::HostedConnection;
use crate::client::SessionError;
use crate::http::{HttpRequest, HttpResponse};

/// The environment every session's primary workspace uses.
pub const DEFAULT_ENVIRONMENT_ID: &str = "default";
/// The largest directory page the server returns.
pub const MAX_DIRECTORY_LIMIT: u32 = 1000;

/// One page of a directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirectoryQuery {
    /// The directory; the root lists the environment root.
    pub path: WorkspacePath,
    /// Entries per page, `1..=1000`.
    pub limit: u32,
    /// The previous page's [`DirectoryPage::next_cursor`].
    pub after: Option<String>,
}

impl DirectoryQuery {
    /// The first page of `path`, as large as the server allows.
    #[must_use]
    pub const fn first_page(path: WorkspacePath) -> Self {
        Self {
            path,
            limit: MAX_DIRECTORY_LIMIT,
            after: None,
        }
    }
}

/// One page of session files.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionFilesQuery {
    /// Files per page, `1..=1000`.
    pub limit: u32,
    /// The previous page's [`SessionFilesPage::next_cursor`].
    pub after: Option<String>,
}

/// What to ask for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkspaceOperation {
    /// The session's environments.
    ListEnvironments,
    /// The request's environment.
    GetEnvironment,
    /// A directory page.
    ListDirectory(DirectoryQuery),
    /// A file's content.
    ReadFile(WorkspacePath),
    /// Files by name.
    SearchPaths(PathSearchQuery),
    /// Lines by content.
    SearchContent(ContentSearchQuery),
    /// The session's changed files.
    ListChanges,
    /// A changed file's before and after text.
    FileDiff(WorkspacePath),
    /// Files uploaded to the session. The environment is not used.
    ListSessionFiles(SessionFilesQuery),
}

/// A decoded response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkspaceResponse {
    /// [`WorkspaceOperation::ListEnvironments`].
    Environments(Vec<WorkspaceEnvironment>),
    /// [`WorkspaceOperation::GetEnvironment`].
    Environment(WorkspaceEnvironment),
    /// [`WorkspaceOperation::ListDirectory`].
    Directory(DirectoryPage),
    /// [`WorkspaceOperation::ReadFile`].
    File(FileContent),
    /// [`WorkspaceOperation::SearchPaths`].
    PathSearch(PathSearchResult),
    /// [`WorkspaceOperation::SearchContent`].
    ContentSearch(ContentSearchResult),
    /// [`WorkspaceOperation::ListChanges`].
    Changes(ChangesList),
    /// [`WorkspaceOperation::FileDiff`].
    FileDiff(FileDiffContent),
    /// [`WorkspaceOperation::ListSessionFiles`].
    SessionFiles(SessionFilesPage),
}

/// A validated workspace request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceRequest {
    session_id: String,
    environment_id: String,
    operation: WorkspaceOperation,
}

/// The route of a request: a fixed path, file path segments appended after it, and the query.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Route {
    pub(super) path: String,
    pub(super) segments: Vec<String>,
    pub(super) query: Vec<(&'static str, String)>,
}

fn identifier(value: &str) -> Result<(), WorkspaceError> {
    if is_identifier(value) {
        Ok(())
    } else {
        Err(WorkspaceError::InvalidIdentifier {
            value: value.to_owned(),
        })
    }
}

fn page_limit(limit: u32) -> Result<(), WorkspaceError> {
    if (1..=MAX_DIRECTORY_LIMIT).contains(&limit) {
        Ok(())
    } else {
        Err(WorkspaceError::InvalidQuery {
            reason: "Request between 1 and 1,000 entries per page.".to_owned(),
        })
    }
}

fn cursor(after: Option<&str>) -> Result<(), WorkspaceError> {
    if after.is_some_and(str::is_empty) {
        return Err(WorkspaceError::InvalidQuery {
            reason: "The page cursor is empty.".to_owned(),
        });
    }
    Ok(())
}

impl WorkspaceRequest {
    /// Validates the ids and the operation's inputs.
    ///
    /// # Errors
    ///
    /// [`WorkspaceError::InvalidIdentifier`] for an id that is not one plain path segment,
    /// [`WorkspaceError::InvalidPath`] for the root where a file is required, and
    /// [`WorkspaceError::InvalidQuery`] for a blank or multi-line query, a limit out of range,
    /// an empty cursor or a malformed filter.
    pub fn new(
        session_id: &str,
        environment_id: &str,
        operation: WorkspaceOperation,
    ) -> Result<Self, WorkspaceError> {
        identifier(session_id)?;
        identifier(environment_id)?;
        match &operation {
            WorkspaceOperation::ListDirectory(query) => {
                page_limit(query.limit)?;
                cursor(query.after.as_deref())?;
            }
            WorkspaceOperation::ListSessionFiles(query) => {
                page_limit(query.limit)?;
                cursor(query.after.as_deref())?;
            }
            WorkspaceOperation::ReadFile(path) | WorkspaceOperation::FileDiff(path)
                if path.is_root() =>
            {
                return Err(super::path::PathError::Root.into());
            }
            WorkspaceOperation::SearchPaths(query) => query.validate()?,
            WorkspaceOperation::SearchContent(query) => query.validate()?,
            _ => {}
        }
        Ok(Self {
            session_id: session_id.to_owned(),
            environment_id: environment_id.to_owned(),
            operation,
        })
    }

    /// The session.
    #[must_use]
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// The environment.
    #[must_use]
    pub fn environment_id(&self) -> &str {
        &self.environment_id
    }

    /// The operation.
    #[must_use]
    pub const fn operation(&self) -> &WorkspaceOperation {
        &self.operation
    }

    pub(super) fn route(&self) -> Result<Route, WorkspaceError> {
        let resources = format!("/v1/sessions/{}/resources", self.session_id);
        let environment = format!("{resources}/environments/{}", self.environment_id);
        let segments = |path: &WorkspacePath| path.segments().map(str::to_owned).collect();
        let route = |path: String, segments: Vec<String>, query| Route {
            path,
            segments,
            query,
        };
        Ok(match &self.operation {
            WorkspaceOperation::ListEnvironments => {
                route(format!("{resources}/environments"), vec![], vec![])
            }
            WorkspaceOperation::GetEnvironment => route(environment, vec![], vec![]),
            WorkspaceOperation::ListDirectory(query) => {
                let mut pairs = vec![("limit", query.limit.to_string()), ("order", "asc".into())];
                if let Some(after) = &query.after {
                    pairs.push(("after", after.clone()));
                }
                route(
                    format!("{environment}/filesystem"),
                    segments(&query.path),
                    pairs,
                )
            }
            WorkspaceOperation::ReadFile(path) => {
                route(format!("{environment}/filesystem"), segments(path), vec![])
            }
            WorkspaceOperation::SearchPaths(query) => {
                let mut pairs = vec![
                    ("q", query.query.clone()),
                    ("limit", query.limit.to_string()),
                ];
                let include = joined_globs(&query.include)?;
                let exclude = joined_globs(&query.exclude)?;
                if !include.is_empty() {
                    pairs.push(("include", include));
                }
                if !exclude.is_empty() {
                    pairs.push(("exclude", exclude));
                }
                route(
                    format!("{environment}/search"),
                    segments(&query.under),
                    pairs,
                )
            }
            WorkspaceOperation::SearchContent(query) => route(
                format!("{environment}/content-search"),
                vec![],
                vec![
                    ("q", query.query.clone()),
                    ("case_sensitive", query.case_sensitive.to_string()),
                    ("regex", query.regex.to_string()),
                    ("include", joined_globs(&query.include)?),
                    ("exclude", joined_globs(&query.exclude)?),
                    ("limit", query.limit.to_string()),
                ],
            ),
            WorkspaceOperation::ListChanges => {
                route(format!("{environment}/changes"), vec![], vec![])
            }
            WorkspaceOperation::FileDiff(path) => {
                route(format!("{environment}/diff"), segments(path), vec![])
            }
            WorkspaceOperation::ListSessionFiles(query) => {
                let mut pairs = vec![("limit", query.limit.to_string()), ("order", "desc".into())];
                if let Some(after) = &query.after {
                    pairs.push(("after", after.clone()));
                }
                route(format!("{resources}/files"), vec![], pairs)
            }
        })
    }

    /// The request on `connection`, which must be connected.
    ///
    /// # Errors
    ///
    /// [`SessionError::NotConnected`] (wrapped) before connecting, then the endpoint's URL and
    /// bearer errors.
    pub fn build(&self, connection: &HostedConnection) -> Result<HttpRequest, WorkspaceError> {
        let route = self.route()?;
        let pairs: Vec<(&str, &str)> = route
            .query
            .iter()
            .map(|(name, value)| (*name, value.as_str()))
            .collect();
        let request = connection
            .request("GET", &route.path, &pairs, "application/json")
            .map_err(SessionError::from)?;
        with_segments(request, &route.segments)
    }

    /// The request on `endpoint` with `bearer`, for hosts that manage the connection themselves.
    ///
    /// # Errors
    ///
    /// The endpoint's URL and bearer errors.
    pub fn build_for_endpoint(
        &self,
        endpoint: &ServerEndpoint,
        bearer: Option<&SecretString>,
    ) -> Result<HttpRequest, WorkspaceError> {
        let route = self.route()?;
        let pairs: Vec<(&str, &str)> = route
            .query
            .iter()
            .map(|(name, value)| (*name, value.as_str()))
            .collect();
        let request = endpoint
            .request_with("GET", &route.path, &pairs, "application/json", bearer)
            .map_err(SessionError::from)?;
        with_segments(request, &route.segments)
    }

    const fn not_found_meaning(&self) -> NotFoundMeaning {
        match self.operation {
            WorkspaceOperation::ListDirectory(_)
            | WorkspaceOperation::ReadFile(_)
            | WorkspaceOperation::SearchPaths(_) => NotFoundMeaning::Path,
            WorkspaceOperation::FileDiff(_) => NotFoundMeaning::Diff,
            WorkspaceOperation::SearchContent(_) => NotFoundMeaning::ContentSearch,
            _ => NotFoundMeaning::Session,
        }
    }

    fn subject(&self) -> String {
        match &self.operation {
            WorkspaceOperation::ListDirectory(DirectoryQuery { path, .. })
            | WorkspaceOperation::ReadFile(path)
            | WorkspaceOperation::FileDiff(path)
            | WorkspaceOperation::SearchPaths(PathSearchQuery { under: path, .. }) => {
                path.to_string()
            }
            _ => String::new(),
        }
    }

    /// Decodes `response` to this request.
    ///
    /// # Errors
    ///
    /// See [`WorkspaceError`]. A `401` yields `WorkspaceError::Session(Unauthorized)`; the caller
    /// must end the connection ([`WorkspaceError::ends_connection`]).
    pub fn decode(&self, response: &HttpResponse) -> Result<WorkspaceResponse, WorkspaceError> {
        let subject = self.subject();
        let context = self.context();
        let value = check(response, self.not_found_meaning(), &subject, context)?;
        Ok(match &self.operation {
            WorkspaceOperation::ListEnvironments => {
                WorkspaceResponse::Environments(environments(&value)?)
            }
            WorkspaceOperation::GetEnvironment => {
                WorkspaceResponse::Environment(single_environment(&value)?)
            }
            WorkspaceOperation::ListDirectory(query) => WorkspaceResponse::Directory(
                directory_page(&value, &query.path, query.after.as_deref())?,
            ),
            WorkspaceOperation::ReadFile(path) => {
                WorkspaceResponse::File(file_content(&value, path)?)
            }
            WorkspaceOperation::SearchPaths(query) => {
                WorkspaceResponse::PathSearch(path_search(&value, &query.under)?)
            }
            WorkspaceOperation::SearchContent(_) => {
                WorkspaceResponse::ContentSearch(content_search(&value)?)
            }
            WorkspaceOperation::ListChanges => WorkspaceResponse::Changes(changes(&value)?),
            WorkspaceOperation::FileDiff(path) => {
                WorkspaceResponse::FileDiff(file_diff(&value, path)?)
            }
            WorkspaceOperation::ListSessionFiles(query) => {
                WorkspaceResponse::SessionFiles(session_files(&value, query.after.as_deref())?)
            }
        })
    }

    const fn context(&self) -> &'static str {
        match self.operation {
            WorkspaceOperation::ListEnvironments => "the environment list",
            WorkspaceOperation::GetEnvironment => "the environment",
            WorkspaceOperation::ListDirectory(_) => "the directory listing",
            WorkspaceOperation::ReadFile(_) => "the file",
            WorkspaceOperation::SearchPaths(_) => "the file search",
            WorkspaceOperation::SearchContent(_) => "the content search",
            WorkspaceOperation::ListChanges => "the changed files",
            WorkspaceOperation::FileDiff(_) => "the file diff",
            WorkspaceOperation::ListSessionFiles(_) => "the session files",
        }
    }
}

/// `request` with `segments` appended to its URL path, each percent-encoded as one segment.
pub(super) fn with_segments(
    mut request: HttpRequest,
    segments: &[String],
) -> Result<HttpRequest, WorkspaceError> {
    if segments.is_empty() {
        return Ok(request);
    }
    let mut url = Url::parse(&request.url)
        .map_err(|error| WorkspaceError::malformed("request URL", error))?;
    url.path_segments_mut()
        .map_err(|()| WorkspaceError::malformed("request URL", "cannot carry a path"))?
        .extend(segments);
    request.url = url.into();
    Ok(request)
}
