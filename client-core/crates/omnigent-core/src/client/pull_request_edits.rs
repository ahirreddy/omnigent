//! Changes to a session's pull requests through the server, which forwards them to the session's
//! host: link and unlink (`…/resources/github/prs`), labels, reviewers, merge and comments.
//!
//! Each write names the PR it changes (`pr_url`); the host refuses one the session does not
//! link. A refusal is [`SessionError::Rejected`] with the host's reason, for example
//! "The GitHub account on the host cannot merge this pull request."

use serde_json::{Value, json};

use super::json::{as_object, opt_array, opt_bool, opt_object, opt_str, req_str};
use super::pull_request_detail::{
    PullRequestComment, PullRequestInfo, PullRequestLabel, PullRequestReviewer, ReviewerKind,
    decode_comment, decode_labels, decode_reviewers, pr_query,
};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// How a PR is merged.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MergeMethod {
    /// A merge commit.
    Merge,
    /// One squashed commit.
    Squash,
    /// The commits rebased onto the base.
    Rebase,
}

impl MergeMethod {
    /// The wire name.
    #[must_use]
    pub const fn wire(self) -> &'static str {
        match self {
            Self::Merge => "merge",
            Self::Squash => "squash",
            Self::Rebase => "rebase",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        match value {
            "merge" => Some(Self::Merge),
            "squash" => Some(Self::Squash),
            "rebase" => Some(Self::Rebase),
            _ => None,
        }
    }
}

/// The merge methods the PR's repository allows.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MergeOptions {
    /// Allowed methods, in the provider's order.
    pub methods: Vec<MergeMethod>,
    /// The one to preselect.
    pub default: Option<MergeMethod>,
}

/// Someone a review can be requested from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewCandidate {
    /// Login or team slug.
    pub login: String,
    /// User or team.
    pub kind: ReviewerKind,
    /// The display name.
    pub name: Option<String>,
}

/// A reviewer named in a request or withdrawal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewerTarget {
    /// Login or team slug.
    pub login: String,
    /// User or team.
    pub kind: ReviewerKind,
}

/// A list the host may have cut short.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Capped<Item> {
    /// The items.
    pub items: Vec<Item>,
    /// The repository has more than the host lists.
    pub has_more: bool,
}

fn targets(reviewers: &[ReviewerTarget]) -> Value {
    Value::Array(
        reviewers
            .iter()
            .map(|reviewer| {
                json!({
                    "login": reviewer.login,
                    "kind": match reviewer.kind {
                        ReviewerKind::User => "user",
                        ReviewerKind::Team => "team",
                    },
                })
            })
            .collect(),
    )
}

fn malformed(path: &str) -> impl Fn(String) -> SessionError + '_ {
    move |detail| SessionError::MalformedResponse {
        detail: format!("{path}: {detail}"),
    }
}

fn github_path(session_id: &str, resource: &str) -> Result<String, SessionError> {
    validate_identifier(session_id)?;
    Ok(format!(
        "/v1/sessions/{session_id}/resources/github/{resource}"
    ))
}

impl<T: HttpTransport> ClientCore<T> {
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn update_linked(
        &self,
        session_id: &str,
        url: &str,
        action: &str,
    ) -> Result<PullRequestInfo, SessionError> {
        let path = github_path(session_id, "prs")?;
        let body = json!({ "url": url, "action": action });
        let result = self
            .write_json("POST", &path, &body)
            .await
            .and_then(|value| PullRequestInfo::from_value(&value).map_err(malformed(&path)));
        self.dispatch();
        result
    }

    /// Links the PR at `url` to the session; the host checks that its provider account can read
    /// it. Answers the session's PRs with the linked one selected.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`]; the write errors, with the host's reason in
    /// [`SessionError::Rejected`]; [`SessionError::DeliveryUncertain`] for an unreadable answer.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn link_pull_request(
        &self,
        session_id: &str,
        url: &str,
    ) -> Result<PullRequestInfo, SessionError> {
        if url.trim().is_empty() {
            return Err(SessionError::InvalidInput {
                reason: "Paste the pull request's address.".to_owned(),
            });
        }
        self.update_linked(session_id, url.trim(), "attach").await
    }

    /// Unlinks the PR at `url` from the session. Answers the session's remaining PRs.
    ///
    /// # Errors
    ///
    /// As [`ClientCore::link_pull_request`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn unlink_pull_request(
        &self,
        session_id: &str,
        url: &str,
    ) -> Result<PullRequestInfo, SessionError> {
        self.update_linked(session_id, url, "remove").await
    }

    /// The labels `pr_url`'s repository offers, sorted by name.
    ///
    /// # Errors
    ///
    /// The host read errors (see [`ClientCore::pull_request_info`]).
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn pull_request_repository_labels(
        &self,
        session_id: &str,
        pr_url: &str,
    ) -> Result<Capped<PullRequestLabel>, SessionError> {
        let path = github_path(session_id, "labels")?;
        let result = self
            .host_resource_read(&path, &pr_query(Some(pr_url)))
            .await
            .and_then(|value| {
                let object = as_object(&value, "list").map_err(malformed(&path))?;
                Ok(Capped {
                    items: decode_labels(object, "data").map_err(malformed(&path))?,
                    has_more: opt_bool(object, "has_more")
                        .map_err(malformed(&path))?
                        .unwrap_or(false),
                })
            });
        self.dispatch();
        result
    }

    /// Adds and removes labels on `pr_url`; answers its labels afterwards.
    ///
    /// # Errors
    ///
    /// As [`ClientCore::link_pull_request`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn update_pull_request_labels(
        &self,
        session_id: &str,
        pr_url: &str,
        add: &[String],
        remove: &[String],
    ) -> Result<Vec<PullRequestLabel>, SessionError> {
        let path = github_path(session_id, "labels")?;
        let body = json!({ "pr_url": pr_url, "add": add, "remove": remove });
        let result = self
            .write_json("POST", &path, &body)
            .await
            .and_then(|value| {
                let object = as_object(&value, "labels").map_err(malformed(&path))?;
                decode_labels(object, "labels").map_err(malformed(&path))
            });
        self.dispatch();
        result
    }

    /// The users and teams a review of `pr_url` can be requested from: users, then teams.
    ///
    /// # Errors
    ///
    /// The host read errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn pull_request_review_candidates(
        &self,
        session_id: &str,
        pr_url: &str,
    ) -> Result<Capped<ReviewCandidate>, SessionError> {
        let path = github_path(session_id, "reviewers")?;
        let result = self
            .host_resource_read(&path, &pr_query(Some(pr_url)))
            .await
            .and_then(|value| decode_candidates(&value).map_err(malformed(&path)));
        self.dispatch();
        result
    }

    /// Requests reviews from `add` and withdraws pending requests from `remove`; answers the
    /// PR's reviewers afterwards.
    ///
    /// # Errors
    ///
    /// As [`ClientCore::link_pull_request`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn update_pull_request_reviewers(
        &self,
        session_id: &str,
        pr_url: &str,
        add: &[ReviewerTarget],
        remove: &[ReviewerTarget],
    ) -> Result<Vec<PullRequestReviewer>, SessionError> {
        let path = github_path(session_id, "reviewers")?;
        let body = json!({ "pr_url": pr_url, "add": targets(add), "remove": targets(remove) });
        let result = self
            .write_json("POST", &path, &body)
            .await
            .and_then(|value| {
                let object = as_object(&value, "reviewers").map_err(malformed(&path))?;
                decode_reviewers(object, "reviewers").map_err(malformed(&path))
            });
        self.dispatch();
        result
    }

    /// The merge methods `pr_url`'s repository allows.
    ///
    /// # Errors
    ///
    /// The host read errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn pull_request_merge_options(
        &self,
        session_id: &str,
        pr_url: &str,
    ) -> Result<MergeOptions, SessionError> {
        let path = github_path(session_id, "merge-options")?;
        let result = self
            .host_resource_read(&path, &pr_query(Some(pr_url)))
            .await
            .and_then(|value| {
                let object = as_object(&value, "merge options").map_err(malformed(&path))?;
                let methods = opt_array(object, "methods")
                    .map_err(malformed(&path))?
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .filter_map(MergeMethod::parse)
                    .collect();
                let default = opt_str(object, "default")
                    .map_err(malformed(&path))?
                    .as_deref()
                    .and_then(MergeMethod::parse);
                Ok(MergeOptions { methods, default })
            });
        self.dispatch();
        result
    }

    /// Merges `pr_url` with `method`, only while its head is still `expected_head` (the commit
    /// the user saw). The merge cannot be undone.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidInput`] without a head; as [`ClientCore::link_pull_request`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn merge_pull_request(
        &self,
        session_id: &str,
        pr_url: &str,
        method: MergeMethod,
        expected_head: &str,
    ) -> Result<(), SessionError> {
        if expected_head.is_empty() {
            return Err(SessionError::InvalidInput {
                reason: "Refresh the pull request before merging it.".to_owned(),
            });
        }
        let path = github_path(session_id, "merge")?;
        let body = json!({
            "pr_url": pr_url, "merge_method": method.wire(), "expected_head": expected_head,
        });
        let result = self.write_json("POST", &path, &body).await.map(|_| ());
        self.dispatch();
        result
    }

    /// Turns off `pr_url`'s auto-merge.
    ///
    /// # Errors
    ///
    /// As [`ClientCore::link_pull_request`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn disable_pull_request_auto_merge(
        &self,
        session_id: &str,
        pr_url: &str,
    ) -> Result<(), SessionError> {
        let path = github_path(session_id, "disable-auto-merge")?;
        let result = self
            .write_json("POST", &path, &json!({ "pr_url": pr_url }))
            .await
            .map(|_| ());
        self.dispatch();
        result
    }

    /// Posts a conversation comment on `pr_url`; answers the comment as the provider stored it.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidInput`] for a blank comment; as [`ClientCore::link_pull_request`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn post_pull_request_comment(
        &self,
        session_id: &str,
        pr_url: &str,
        body: &str,
    ) -> Result<PullRequestComment, SessionError> {
        if body.trim().is_empty() {
            return Err(SessionError::InvalidInput {
                reason: "Write a comment before posting it.".to_owned(),
            });
        }
        let path = github_path(session_id, "comments")?;
        let request = json!({ "pr_url": pr_url, "body": body });
        let result = self
            .write_json("POST", &path, &request)
            .await
            .and_then(|value| {
                let object = as_object(&value, "comment").map_err(malformed(&path))?;
                let comment = opt_object(object, "comment")
                    .map_err(malformed(&path))?
                    .ok_or_else(|| malformed(&path)("`comment` is missing".to_owned()))?;
                decode_comment(comment).map_err(malformed(&path))
            });
        self.dispatch();
        result
    }
}

fn decode_candidates(value: &Value) -> Result<Capped<ReviewCandidate>, String> {
    let object = as_object(value, "list")?;
    let mut items = Vec::new();
    for candidate in opt_array(object, "data")?.into_iter().flatten() {
        let candidate = as_object(candidate, "candidate")?;
        items.push(ReviewCandidate {
            login: req_str(candidate, "login")?,
            kind: if opt_str(candidate, "kind")?.as_deref() == Some("team") {
                ReviewerKind::Team
            } else {
                ReviewerKind::User
            },
            name: opt_str(candidate, "name")?,
        });
    }
    Ok(Capped {
        items,
        has_more: opt_bool(object, "has_more")?.unwrap_or(false),
    })
}
