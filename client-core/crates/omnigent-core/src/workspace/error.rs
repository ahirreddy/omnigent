//! The workspace API's error taxonomy and the status policy that produces it.
//!
//! The filesystem routes give statuses meanings beyond the session client's read policy, and
//! the server's own explanation is worth showing (`git status timed out after 5.0s`, `regex
//! parse error`), so responses are decoded here rather than through `ClientCore::read`:
//!
//! | Status | Meaning |
//! |---|---|
//! | 200 | Success, except content search, which answers 200 `{"error": "..."}` when ripgrep fails |
//! | 3xx | Never followed: [`SessionError::RedirectNotAllowed`] |
//! | 400, 422 | The server refused the path or query (`invalid_path`, `invalid_input`, validation) |
//! | 401 | [`SessionError::Unauthorized`]; the caller ends the connection |
//! | 403 | No access; with `reachable_roots` when the path is outside the environment's reach |
//! | 404 | Per operation: a missing path, a file with no session changes (diff), content search turned off, or no filesystem for the session |
//! | 500 `git_status_failed` | The change list could not be computed |
//! | 503 `runner_unavailable` | The session's runner is offline and its host cannot serve the read |
//!
//! Error bodies come in three shapes: `{"error": {"code", "message"}}`, `{"error": "<text>"}`
//! and `FastAPI`'s `{"detail": "<text>"}`. All three are read.

use serde_json::Value;

use super::path::PathError;
use crate::client::SessionError;
use crate::http::HttpResponse;

/// The longest server message kept, in characters.
const MAX_MESSAGE_CHARS: usize = 1000;

/// Why a workspace operation failed.
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum WorkspaceError {
    /// A path that cannot be sent. Nothing was sent.
    #[error("{0}")]
    InvalidPath(PathError),
    /// A session or environment id that cannot be a path segment. Nothing was sent.
    #[error("The session or environment identifier is invalid.")]
    InvalidIdentifier {
        /// The rejected value.
        value: String,
    },
    /// A query, limit or glob the server would refuse. Nothing was sent.
    #[error("{reason}")]
    InvalidQuery {
        /// What to fix.
        reason: String,
    },
    /// Connection, transport, redirect and authentication failures, with the session client's
    /// meaning.
    #[error("{0}")]
    Session(SessionError),
    /// The server refused the path or query (400 or 422).
    #[error("{message}")]
    Rejected {
        /// The status.
        status: u16,
        /// The server's machine code, when it sent one.
        code: Option<String>,
        /// The server's explanation.
        message: String,
    },
    /// HTTP 403 without reachable roots.
    #[error("{message}")]
    Forbidden {
        /// The server's explanation.
        message: String,
    },
    /// HTTP 403 for a path outside everything the environment can reach.
    #[error("{message}")]
    PathUnreachable {
        /// The server's explanation.
        message: String,
        /// Absolute roots the environment can reach.
        reachable_roots: Vec<String>,
    },
    /// HTTP 404 for a file or directory.
    #[error("{message}")]
    NotFound {
        /// The path asked for.
        path: String,
        /// The server's explanation.
        message: String,
    },
    /// HTTP 404 from the diff route: the file has no changes this session.
    #[error("This file has no changes in this session.")]
    NotChanged {
        /// The path asked for.
        path: String,
    },
    /// HTTP 404 meaning the session has no filesystem (no `os_env`), or the session is gone.
    #[error("{message}")]
    Unavailable {
        /// The server's explanation.
        message: String,
    },
    /// The server has content search turned off (`workspace_content_search`).
    #[error("Content search is not enabled on this server.")]
    ContentSearchDisabled,
    /// Content search ran but failed, for example an invalid regular expression.
    #[error("{message}")]
    SearchFailed {
        /// The server's explanation.
        message: String,
    },
    /// The change list could not be computed (500 `git_status_failed`).
    #[error("{message}")]
    ChangesUnavailable {
        /// The server's explanation.
        message: String,
    },
    /// HTTP 503 `runner_unavailable`: reconnect the session's runner.
    #[error("{message}")]
    RunnerOffline {
        /// The server's explanation.
        message: String,
    },
    /// Any other status.
    #[error("{message}")]
    Server {
        /// The status.
        status: u16,
        /// The server's machine code, when it sent one.
        code: Option<String>,
        /// The server's explanation, or a generic one.
        message: String,
    },
    /// A directory came back where a file was asked for, or the reverse.
    #[error("{path} is a {actual}, not a {expected}.")]
    UnexpectedKind {
        /// The path asked for.
        path: String,
        /// What the operation needs.
        expected: &'static str,
        /// What the server returned.
        actual: &'static str,
    },
    /// The body is not the shape the contract promises.
    #[error(
        "The server returned workspace data this app could not read. Check the server version."
    )]
    MalformedResponse {
        /// What was wrong, for logs.
        detail: String,
    },
}

impl From<PathError> for WorkspaceError {
    fn from(error: PathError) -> Self {
        Self::InvalidPath(error)
    }
}

impl From<SessionError> for WorkspaceError {
    fn from(error: SessionError) -> Self {
        Self::Session(error)
    }
}

impl WorkspaceError {
    /// A [`WorkspaceError::MalformedResponse`] for `context`.
    pub(super) fn malformed(context: &str, detail: impl std::fmt::Display) -> Self {
        Self::MalformedResponse {
            detail: format!("{context}: {detail}"),
        }
    }

    /// Whether this error ended the connection (a `401`), so the caller must disconnect.
    #[must_use]
    pub const fn ends_connection(&self) -> bool {
        matches!(self, Self::Session(SessionError::Unauthorized { .. }))
    }
}

/// What the server said about a failure.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(super) struct ServerFailure {
    pub(super) code: Option<String>,
    pub(super) message: Option<String>,
    pub(super) reachable_roots: Vec<String>,
}

impl ServerFailure {
    /// Reads `{"error": {"code", "message", "reachable_roots"}}`, `{"error": "<text>"}` or
    /// `{"detail": "<text>"}`. A body that is none of these (HTML from a proxy) yields nothing.
    pub(super) fn from_body(body: &[u8]) -> Self {
        let Ok(value) = serde_json::from_slice::<Value>(body) else {
            return Self::default();
        };
        Self::from_value(&value)
    }

    pub(super) fn from_value(value: &Value) -> Self {
        let text = |value: Option<&Value>| {
            value
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|text| !text.is_empty())
                .map(|text| text.chars().take(MAX_MESSAGE_CHARS).collect::<String>())
        };
        match value.get("error") {
            Some(Value::Object(error)) => Self {
                code: text(error.get("code")),
                message: text(error.get("message")),
                reachable_roots: error
                    .get("reachable_roots")
                    .and_then(Value::as_array)
                    .map(|roots| {
                        roots
                            .iter()
                            .filter_map(Value::as_str)
                            .map(str::to_owned)
                            .collect()
                    })
                    .unwrap_or_default(),
            },
            Some(error @ Value::String(_)) => Self {
                message: text(Some(error)),
                ..Self::default()
            },
            _ => Self {
                message: text(value.get("detail")),
                ..Self::default()
            },
        }
    }

    fn message_or(&self, fallback: impl FnOnce() -> String) -> String {
        self.message.clone().unwrap_or_else(fallback)
    }
}

/// How a 404 reads for one operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum NotFoundMeaning {
    /// A path route: `not_found` is the path, anything else is the session or its filesystem.
    Path,
    /// The diff route: the file has no changes.
    Diff,
    /// Content search: the feature flag, or the session's filesystem.
    ContentSearch,
    /// A listing with no path of its own: the session or its filesystem.
    Session,
}

/// Applies the workspace status policy and parses a successful body as JSON.
///
/// # Errors
///
/// See the module documentation.
pub(super) fn check(
    response: &HttpResponse,
    meaning: NotFoundMeaning,
    path: &str,
    context: &str,
) -> Result<Value, WorkspaceError> {
    let status = response.status;
    if status == 200 {
        return serde_json::from_slice(&response.body)
            .map_err(|error| WorkspaceError::malformed(context, error));
    }
    if (300..=399).contains(&status) {
        return Err(SessionError::RedirectNotAllowed { status }.into());
    }
    let failure = ServerFailure::from_body(&response.body);
    let generic = || format!("The server returned HTTP {status} for {context}.");
    Err(match status {
        401 => SessionError::Unauthorized {
            reason: failure.message,
        }
        .into(),
        403 if !failure.reachable_roots.is_empty() => WorkspaceError::PathUnreachable {
            message: failure.message_or(|| "This path is outside the session's reach.".into()),
            reachable_roots: failure.reachable_roots,
        },
        403 => WorkspaceError::Forbidden {
            message: failure
                .message_or(|| "The server denied access to this session's files.".into()),
        },
        400 | 422 => WorkspaceError::Rejected {
            status,
            message: failure.message_or(generic),
            code: failure.code,
        },
        404 => not_found(meaning, path, &failure),
        500 if failure.code.as_deref() == Some("git_status_failed") => {
            WorkspaceError::ChangesUnavailable {
                message: failure.message_or(generic),
            }
        }
        503 if failure.code.as_deref() == Some("runner_unavailable") => {
            WorkspaceError::RunnerOffline {
                message: failure.message_or(|| {
                    "The session's runner is offline. Reconnect it and try again.".into()
                }),
            }
        }
        _ => WorkspaceError::Server {
            status,
            message: failure.message_or(generic),
            code: failure.code,
        },
    })
}

fn not_found(meaning: NotFoundMeaning, path: &str, failure: &ServerFailure) -> WorkspaceError {
    let path_missing = failure.code.as_deref() == Some("not_found");
    match meaning {
        NotFoundMeaning::Diff if path_missing => WorkspaceError::NotChanged {
            path: path.to_owned(),
        },
        NotFoundMeaning::Path if path_missing => WorkspaceError::NotFound {
            path: path.to_owned(),
            message: failure.message_or(|| format!("{path} was not found.")),
        },
        NotFoundMeaning::ContentSearch
            if failure
                .message
                .as_deref()
                .is_some_and(|message| message.contains("content search is disabled")) =>
        {
            WorkspaceError::ContentSearchDisabled
        }
        _ => WorkspaceError::Unavailable {
            message: failure.message_or(|| "This session has no workspace files.".into()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::HttpHeader;

    fn response(status: u16, body: &str) -> HttpResponse {
        HttpResponse {
            status,
            headers: vec![HttpHeader::new("Content-Type", "application/json")],
            body: body.as_bytes().to_vec(),
        }
    }

    fn fail(status: u16, body: &str, meaning: NotFoundMeaning) -> WorkspaceError {
        check(&response(status, body), meaning, "src/a.rs", "test").unwrap_err()
    }

    #[test]
    fn an_offline_runner_explains_itself_with_or_without_a_server_message() {
        assert_eq!(
            fail(
                503,
                r#"{"error":{"code":"runner_unavailable"}}"#,
                NotFoundMeaning::Path
            ),
            WorkspaceError::RunnerOffline {
                message: "The session's runner is offline. Reconnect it and try again.".to_owned()
            }
        );
    }

    #[test]
    fn reads_all_three_error_shapes() {
        assert_eq!(
            ServerFailure::from_body(br#"{"error":{"code":"not_found","message":"gone"}}"#),
            ServerFailure {
                code: Some("not_found".into()),
                message: Some("gone".into()),
                reachable_roots: vec![],
            }
        );
        assert_eq!(
            ServerFailure::from_body(br#"{"error":"regex parse error"}"#).message,
            Some("regex parse error".into())
        );
        assert_eq!(
            ServerFailure::from_body(br#"{"detail":"nope"}"#).message,
            Some("nope".into())
        );
        assert_eq!(
            ServerFailure::from_body(b"<html>"),
            ServerFailure::default()
        );
        let long = format!(r#"{{"detail":"{}"}}"#, "x".repeat(5000));
        assert_eq!(
            ServerFailure::from_body(long.as_bytes())
                .message
                .unwrap()
                .chars()
                .count(),
            MAX_MESSAGE_CHARS
        );
    }

    #[test]
    #[allow(clippy::too_many_lines, reason = "one table of status cases")]
    fn status_policy_keeps_the_server_reason() {
        use NotFoundMeaning as M;
        assert_eq!(
            fail(302, "", M::Path),
            WorkspaceError::Session(SessionError::RedirectNotAllowed { status: 302 })
        );
        let unauthorized = fail(401, r#"{"error":"expired"}"#, M::Path);
        assert!(unauthorized.ends_connection());
        assert_eq!(
            fail(
                403,
                r#"{"error":{"message":"no","reachable_roots":["/w"]}}"#,
                M::Path
            ),
            WorkspaceError::PathUnreachable {
                message: "no".into(),
                reachable_roots: vec!["/w".into()],
            }
        );
        assert!(matches!(
            fail(403, "{}", M::Path),
            WorkspaceError::Forbidden { .. }
        ));
        assert_eq!(
            fail(
                400,
                r#"{"error":{"code":"invalid_input","message":"Parent path segments are not permitted"}}"#,
                M::Path
            ),
            WorkspaceError::Rejected {
                status: 400,
                code: Some("invalid_input".into()),
                message: "Parent path segments are not permitted".into(),
            }
        );
        assert_eq!(
            fail(
                404,
                r#"{"error":{"code":"not_found","message":"x"}}"#,
                M::Diff
            ),
            WorkspaceError::NotChanged {
                path: "src/a.rs".into()
            }
        );
        assert_eq!(
            fail(
                404,
                r#"{"detail":"Workspace content search is disabled"}"#,
                M::ContentSearch
            ),
            WorkspaceError::ContentSearchDisabled
        );
        assert_eq!(
            fail(
                404,
                r#"{"detail":"Session agent has no os_env configured; filesystem API unavailable."}"#,
                M::Path
            ),
            WorkspaceError::Unavailable {
                message: "Session agent has no os_env configured; filesystem API unavailable."
                    .into()
            }
        );
        assert_eq!(
            fail(
                500,
                r#"{"error":{"code":"git_status_failed","message":"git status timed out after 5.0s"}}"#,
                M::Session
            ),
            WorkspaceError::ChangesUnavailable {
                message: "git status timed out after 5.0s".into()
            }
        );
        assert!(matches!(
            fail(
                503,
                r#"{"error":{"code":"runner_unavailable","message":"offline"}}"#,
                M::Session
            ),
            WorkspaceError::RunnerOffline { .. }
        ));
        assert_eq!(
            fail(503, "<html>", M::Session),
            WorkspaceError::Server {
                status: 503,
                code: None,
                message: "The server returned HTTP 503 for test.".into(),
            }
        );
        assert!(matches!(
            check(&response(200, "not json"), M::Path, "p", "test"),
            Err(WorkspaceError::MalformedResponse { .. })
        ));
    }
}
