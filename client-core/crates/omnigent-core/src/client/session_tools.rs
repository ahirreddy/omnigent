//! The composer's session tools, as the web's Add (+) menu has them: side chats, Codex plan
//! mode and the session goal.
//!
//! - A side chat opens as a draft and forks the conversation into its own session (`POST …/fork`
//!   with `side_chat: true`) only when its first message is sent, bound to the parent's live
//!   runner, relaunching the parent first when its runner stopped. Codex forks natively from a
//!   typed `/side`, so for it the composer is prefilled instead (web `createSideChat`,
//!   `usesNativeSideChatFork`).
//! - Plan mode is Codex-native's collaboration mode (`PATCH` `collaboration_mode`).
//! - The goal is Codex-native's `…/codex_goal`; top-level Polly sessions on the Claude SDK or
//!   Codex take a `/goal <condition>` command instead (web `shouldShow*GoalControl`).

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use super::create::FirstMessage;
use super::json::{as_object, opt_str};
use super::requests::validate_identifier;
use super::sessions::decode_snapshot_value;
use super::{ClientCore, SessionError, lock};
use crate::http::HttpTransport;

/// What the composer puts before a side question for harnesses that fork natively.
pub const SIDE_CHAT_COMMAND_PREFIX: &str = "/side ";
/// What the composer sends to start a goal on harnesses that take it as a command.
pub const GOAL_COMMAND_PREFIX: &str = "/goal ";
/// The title of a side chat session.
pub const SIDE_CHAT_TITLE: &str = "Side chat";
const SIDE_CHAT_DISCONNECTED: &str =
    "This session is disconnected. Reconnect it before starting a side chat.";
const CODEX_NATIVE_HARNESS: &str = "codex-native";
/// Marks a session forked as a side chat (`"1"`); the server hides it from the session list.
pub const SIDE_CHAT_LABEL: &str = "omnigent.side_chat";
/// The session a side chat was forked from.
pub const SIDE_CHAT_SOURCE_LABEL: &str = "omnigent.side_chat.source_id";
const FORK_SOURCE_LABEL: &str = "omnigent.fork.source_id";
const CODEX_NATIVE_WRAPPER: &str = "codex-native-ui";
const COLLABORATION_LABEL: &str = "omnigent.codex_native.collaboration_mode";
const PLAN: &str = "plan";

/// How a side chat starts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SideChatStart {
    /// The harness forks from a typed command: put `prefix` in the composer for the question.
    Command {
        /// The command prefix, [`SIDE_CHAT_COMMAND_PREFIX`].
        prefix: String,
    },
    /// Open an empty side chat with `draft` in its composer; its session is created when the
    /// first message is sent ([`ClientCore::create_side_chat`]).
    Draft {
        /// The composer's starting text, empty or a quote.
        draft: String,
    },
}

/// A side chat created by its first message.
#[derive(Debug, Clone, PartialEq)]
pub struct CreatedSideChat {
    /// The side chat session.
    pub session_id: String,
    /// The first message's outcome. The session exists either way: retry the send to it.
    pub first_message: FirstMessage,
}

/// How a side chat of a session on `harness` starts, with a `quote` (text selected in the
/// transcript) quoted in its composer. Makes no request.
#[must_use]
pub fn side_chat_start(harness: Option<&str>, quote: Option<&str>) -> SideChatStart {
    let draft = quote
        .map(|quote| reply_quote("", quote))
        .unwrap_or_default();
    if harness == Some(CODEX_NATIVE_HARNESS) {
        SideChatStart::Command {
            prefix: format!("{SIDE_CHAT_COMMAND_PREFIX}{draft}"),
        }
    } else {
        SideChatStart::Draft { draft }
    }
}

/// The session a side chat was forked from, from its labels; `None` for any other session.
#[must_use]
pub fn side_chat_source_id(labels: &BTreeMap<String, String>) -> Option<&str> {
    labels
        .get(SIDE_CHAT_SOURCE_LABEL)
        .or_else(|| {
            (labels.get(SIDE_CHAT_LABEL).map(String::as_str) == Some("1"))
                .then(|| labels.get(FORK_SOURCE_LABEL))
                .flatten()
        })
        .map(String::as_str)
        .filter(|id| !id.is_empty())
}

/// When a server-forked side chat began: the history it copied from its parent was created
/// before it. `None` for other sessions, and for Codex's native fork, which copies nothing.
#[must_use]
pub fn side_chat_inherited_before(
    labels: Option<&BTreeMap<String, String>>,
    harness: Option<&str>,
    created_at: i64,
) -> Option<i64> {
    let forked =
        labels.is_some_and(|labels| labels.get(SIDE_CHAT_LABEL).map(String::as_str) == Some("1"));
    (forked && harness != Some(CODEX_NATIVE_HARNESS)).then_some(created_at)
}

/// How a session takes a goal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GoalControl {
    /// Through the goal endpoints, with progress and pause.
    Managed,
    /// As a `/goal <condition>` message to `backend` ("Claude", "Codex").
    Command {
        /// The agent that runs the goal.
        backend: String,
    },
}

/// A session goal as the harness reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionGoal {
    /// What the agent works toward.
    pub objective: String,
    /// The harness's status, for example `active`, `paused` or `budgetLimited`.
    pub status: String,
    /// The token cap, when set.
    pub token_budget: Option<u64>,
    /// Tokens spent on the goal.
    pub tokens_used: u64,
    /// Seconds spent on the goal.
    pub time_used_seconds: u64,
}

impl SessionGoal {
    /// The user can pause it.
    #[must_use]
    pub fn can_pause(&self) -> bool {
        self.status == "active"
    }

    /// The user can resume it.
    #[must_use]
    pub fn can_resume(&self) -> bool {
        matches!(self.status.as_str(), "paused" | "blocked" | "usageLimited")
    }
}

/// Whether Codex plan mode applies to a session (`None` when it does not) and whether it is on.
/// `collaboration_mode` is the mode as reported, in any case.
#[must_use]
pub fn codex_plan_mode(wrapper: Option<&str>, collaboration_mode: Option<&str>) -> Option<bool> {
    (wrapper == Some(CODEX_NATIVE_WRAPPER))
        .then(|| collaboration_mode.is_some_and(|mode| mode.eq_ignore_ascii_case(PLAN)))
}

/// How a session takes a goal, or `None` when it has no goal control.
#[must_use]
pub fn goal_control(
    wrapper: Option<&str>,
    harness: Option<&str>,
    agent_name: Option<&str>,
    parent_id: Option<&str>,
) -> Option<GoalControl> {
    if wrapper == Some(CODEX_NATIVE_WRAPPER) {
        return Some(GoalControl::Managed);
    }
    let polly = parent_id.is_none_or(str::is_empty)
        && agent_name.is_some_and(|name| name.eq_ignore_ascii_case("polly"));
    let backend = match harness {
        Some("claude-sdk") => "Claude",
        Some("codex") => "Codex",
        _ => return None,
    };
    polly.then(|| GoalControl::Command {
        backend: backend.to_owned(),
    })
}

/// The message that starts a goal on a [`GoalControl::Command`] session; `None` when blank.
#[must_use]
pub fn goal_command(condition: &str) -> Option<String> {
    let condition = condition.trim();
    (!condition.is_empty()).then(|| format!("{GOAL_COMMAND_PREFIX}{condition}"))
}

/// `draft` with `selection` quoted after it as a Markdown block quote, then an empty paragraph
/// to type the reply in (web `appendReplyQuote`, serialized). A blank selection changes nothing.
#[must_use]
pub fn reply_quote(draft: &str, selection: &str) -> String {
    let selection = selection.replace("\r\n", "\n").replace('\r', "\n");
    let selection = selection.trim_matches('\n');
    if selection.trim().is_empty() {
        return draft.to_owned();
    }
    let quote: Vec<String> = selection.lines().map(|line| format!("> {line}")).collect();
    let quote = quote.join("\n");
    // A blank line between the draft and the quote, counting the newlines it already ends with.
    let trailing = draft.len() - draft.trim_end_matches('\n').len();
    let separator = if draft.is_empty() {
        ""
    } else {
        "\n\n".get(trailing.min(2)..).unwrap_or_default()
    };
    format!("{draft}{separator}{quote}\n\n")
}

fn goal_path(session_id: &str) -> String {
    format!("/v1/sessions/{session_id}/codex_goal")
}

/// The `goal` of a goal response; `None` when there is none.
fn decode_goal(value: &Value) -> Result<Option<SessionGoal>, String> {
    let object = as_object(value, "goal response")?;
    let Some(goal) = object.get("goal").filter(|goal| !goal.is_null()) else {
        return Ok(None);
    };
    let goal = as_object(goal, "goal")?;
    let count = |key: &str| -> Result<Option<u64>, String> {
        match goal.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(value) => value
                .as_u64()
                .map(Some)
                .ok_or_else(|| format!("`{key}` is not a count")),
        }
    };
    Ok(Some(SessionGoal {
        objective: opt_str(goal, "objective")?.ok_or("`objective` is missing")?,
        status: opt_str(goal, "status")?.ok_or("`status` is missing")?,
        token_budget: count("token_budget")?,
        tokens_used: count("tokens_used")?.unwrap_or_default(),
        time_used_seconds: count("time_used_seconds")?.unwrap_or_default(),
    }))
}

impl<T: HttpTransport> ClientCore<T> {
    /// Creates a side chat of `source_id` and sends `text` as its first message (web
    /// `startPendingSideChat`). Once the side chat exists the result is `Ok`: a failed first
    /// message is reported in [`CreatedSideChat::first_message`], to be sent again to the side
    /// chat, never by creating another.
    ///
    /// # Errors
    ///
    /// [`SessionError::EmptyMessage`] and [`SessionError::InvalidIdentifier`] before any request;
    /// the read and write errors; [`SessionError::ExecutionUnavailable`] when the session's runner
    /// is gone and cannot be relaunched; [`SessionError::DeliveryUncertain`] when the fork may
    /// exist or the binding's acknowledgement is unreadable. A failed runner binding is returned
    /// as its write error: the side chat exists but is unbound.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_side_chat(
        &self,
        source_id: &str,
        text: &str,
    ) -> Result<CreatedSideChat, SessionError> {
        let result = async {
            if text.trim().is_empty() {
                return Err(SessionError::EmptyMessage);
            }
            validate_identifier(source_id)?;
            let session_id = self.fork_side_chat(source_id).await?;
            let first_message = match self.send(&session_id, text, false).await {
                Ok(sent) => FirstMessage::Sent(sent),
                Err(error) => FirstMessage::Failed(error),
            };
            Ok(CreatedSideChat {
                session_id,
                first_message,
            })
        }
        .await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn fork_side_chat(&self, source_id: &str) -> Result<String, SessionError> {
        let (mut decoded, _) = self.fetch_snapshot(source_id).await?;
        let source = &decoded.snapshot;
        let has_host = source.host_id.value().is_some_and(|id| !id.is_empty());
        let relaunchable = source.host_online.value() != Some(&false)
            || source.host_resumable.value() == Some(&true);
        if source.runner_online.value() == Some(&false) && has_host && relaunchable {
            let events = format!("/v1/sessions/{source_id}/events");
            self.write_json(
                "POST",
                &events,
                &json!({"type": "retry_session", "data": {}}),
            )
            .await?;
            decoded = self.fetch_snapshot(source_id).await?.0;
        }
        let source = &decoded.snapshot;
        let runner_id = source
            .runner_id
            .value()
            .filter(|id| !id.is_empty())
            .cloned();
        let runner_online = source.runner_online.value().copied();
        if runner_online == Some(false) || (runner_id.is_none() && runner_online != Some(true)) {
            return Err(SessionError::ExecutionUnavailable {
                reason: SIDE_CHAT_DISCONNECTED.to_owned(),
            });
        }
        let fork = format!("/v1/sessions/{source_id}/fork");
        let body = json!({"title": SIDE_CHAT_TITLE, "side_chat": true});
        let acknowledgement = self.write_json("POST", &fork, &body).await?;
        let receipt = self.accept_fork(acknowledgement)?;
        lock(&self.state)
            .side_chats
            .insert(receipt.session_id.clone());
        if let Some(runner_id) = runner_id {
            let path = format!("/v1/sessions/{}", receipt.session_id);
            let epoch = lock(&self.state).metadata_epoch(&receipt.session_id);
            let binding = self
                .write_json("PATCH", &path, &json!({"runner_id": runner_id}))
                .await?;
            // The first message is checked against the side chat's cached row, which the fork
            // left without a runner: the binding's acknowledgement replaces it.
            let bound = decode_snapshot_value(binding).map_err(|detail| {
                SessionError::DeliveryUncertain {
                    detail: format!("unreadable {path} acknowledgement: {detail}"),
                }
            })?;
            lock(&self.state).accept_projection(&bound.projection, epoch)?;
        }
        Ok(receipt.session_id)
    }

    /// Turns Codex plan mode on or off for `session_id`. Returns whether it is on afterwards.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; the write errors;
    /// [`SessionError::DeliveryUncertain`] for an unreadable acknowledgement.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn set_plan_mode(&self, session_id: &str, on: bool) -> Result<bool, SessionError> {
        let result = self.patch_plan_mode(session_id, on).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn patch_plan_mode(&self, session_id: &str, on: bool) -> Result<bool, SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}");
        let mode = if on { PLAN } else { "default" };
        let acknowledgement = self
            .write_json("PATCH", &path, &json!({"collaboration_mode": mode}))
            .await?;
        let decoded = decode_snapshot_value(acknowledgement).map_err(|detail| {
            SessionError::DeliveryUncertain {
                detail: format!("unreadable {path} acknowledgement: {detail}"),
            }
        })?;
        lock(&self.state).request_rehydration(session_id);
        Ok(decoded
            .snapshot
            .labels
            .value()
            .and_then(|labels| labels.get(COLLABORATION_LABEL))
            .is_some_and(|mode| mode == PLAN))
    }

    /// The session's goal, or `None` when it has none.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; the read errors;
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn session_goal(
        &self,
        session_id: &str,
    ) -> Result<Option<SessionGoal>, SessionError> {
        let result = self.read_goal(session_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn read_goal(&self, session_id: &str) -> Result<Option<SessionGoal>, SessionError> {
        validate_identifier(session_id)?;
        let path = goal_path(session_id);
        let value = self.get_json(&path, &[]).await?;
        decode_goal(&value).map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        })
    }

    /// Sets the session's goal: `objective`, the token cap (`None` clears it) and, when given,
    /// whether it runs (`Some(true)`) or waits paused.
    ///
    /// # Errors
    ///
    /// [`SessionError::EmptyMessage`] for a blank objective; [`SessionError::InvalidIdentifier`];
    /// the write errors; [`SessionError::DeliveryUncertain`] for an unreadable acknowledgement.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn set_session_goal(
        &self,
        session_id: &str,
        objective: &str,
        token_budget: Option<u64>,
        active: Option<bool>,
    ) -> Result<Option<SessionGoal>, SessionError> {
        let objective = objective.trim();
        if objective.is_empty() {
            return Err(SessionError::EmptyMessage);
        }
        let mut body = Map::new();
        body.insert("objective".into(), Value::String(objective.to_owned()));
        body.insert(
            "token_budget".into(),
            token_budget.map_or(Value::Null, Value::from),
        );
        if let Some(active) = active {
            body.insert("status".into(), Value::String(status_word(active).into()));
        }
        let result = self
            .write_goal(
                "PUT",
                &goal_path(session_id),
                session_id,
                Value::Object(body),
            )
            .await;
        self.dispatch();
        result
    }

    /// Pauses (`false`) or resumes (`true`) the session's goal.
    ///
    /// # Errors
    ///
    /// As [`Self::set_session_goal`], without the objective check.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn set_session_goal_active(
        &self,
        session_id: &str,
        active: bool,
    ) -> Result<Option<SessionGoal>, SessionError> {
        let path = format!("{}/status", goal_path(session_id));
        let body = json!({"status": status_word(active)});
        let result = self.write_goal("PATCH", &path, session_id, body).await;
        self.dispatch();
        result
    }

    /// Clears the session's goal. Returns whether there was one.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`]; the write errors;
    /// [`SessionError::DeliveryUncertain`] for an unreadable acknowledgement.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn clear_session_goal(&self, session_id: &str) -> Result<bool, SessionError> {
        let result = async {
            validate_identifier(session_id)?;
            let path = goal_path(session_id);
            let response = self
                .write(self.prepare("DELETE", &path, &[], None)?)
                .await?;
            serde_json::from_slice::<Value>(&response.body)
                .ok()
                .and_then(|value| value.get("cleared").and_then(Value::as_bool))
                .ok_or_else(|| SessionError::DeliveryUncertain {
                    detail: format!("{path}: `cleared` is missing"),
                })
        }
        .await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn write_goal(
        &self,
        method: &str,
        path: &str,
        session_id: &str,
        body: Value,
    ) -> Result<Option<SessionGoal>, SessionError> {
        validate_identifier(session_id)?;
        let value = self.write_json(method, path, &body).await?;
        decode_goal(&value).map_err(|detail| SessionError::DeliveryUncertain {
            detail: format!("unreadable {path} acknowledgement: {detail}"),
        })
    }
}

const fn status_word(active: bool) -> &'static str {
    if active { "active" } else { "paused" }
}

#[cfg(test)]
#[path = "session_tools_tests.rs"]
mod tests;
