//! The caller's automations (scheduled tasks): `/v1/scheduled-tasks` lists, creates, edits,
//! pauses, runs and deletes them. Servers advertise them with `automations_enabled` in
//! `/v1/info`.

use serde_json::{Map, Value, json};

use super::json::{as_object, opt_bool, opt_object, opt_str, req_str};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;
use crate::schedule::{describe_schedule, parse_iso8601};

/// The top-level pages `GET /v1/info` advertises. Missing fields mean unsupported.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct ServerPages {
    /// `automations_enabled`: the Automations page.
    pub automations: bool,
    /// `scheduled_task_session_modes`: an automation can continue one session across runs.
    pub automation_session_modes: bool,
    /// The `usage_page` feature: the Usage page.
    pub usage: bool,
}

impl ServerPages {
    /// Decodes the page fields of a `/v1/info` body.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "/v1/info")?;
        let usage = match opt_object(object, "features")? {
            Some(features) => opt_bool(features, "usage_page")?.unwrap_or(false),
            None => false,
        };
        Ok(Self {
            automations: opt_bool(object, "automations_enabled")?.unwrap_or(false),
            automation_session_modes: opt_bool(object, "scheduled_task_session_modes")?
                .unwrap_or(false),
            usage,
        })
    }
}

/// Whether an automation fires.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum AutomationState {
    /// It fires on schedule.
    Active,
    /// It does not fire.
    Paused,
    /// A state this client does not know; shown as it is.
    Unknown {
        /// The server's value.
        value: String,
    },
}

/// One automation.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Automation {
    /// Id.
    pub id: String,
    /// Name.
    pub name: String,
    /// The prompt each run sends.
    pub prompt: String,
    /// The RFC 5545 rule.
    pub rrule: String,
    /// The rule as text ("Weekdays at 8:00 AM").
    pub schedule_text: String,
    /// The agent each run uses.
    pub agent_id: String,
    /// The IANA zone the rule is evaluated in.
    pub timezone: String,
    /// Whether every run continues one session (`continue`) rather than starting one.
    pub continues_session: bool,
    /// Active or paused.
    pub state: AutomationState,
    /// The next fire, Unix seconds, as the server's scheduler computed it; `None` when paused.
    pub next_run_at: Option<i64>,
    /// The last fire, Unix seconds.
    pub last_run_at: Option<i64>,
    /// The latest run's status (`succeeded`, `failed`, `running`...).
    pub last_run_status: Option<String>,
    /// The latest run's session.
    pub last_run_session_id: Option<String>,
    /// Last edit, Unix seconds.
    pub updated_at: i64,
}

impl Automation {
    /// Whether it is paused.
    #[must_use]
    pub fn is_paused(&self) -> bool {
        self.state == AutomationState::Paused
    }
}

/// What the editor saves. `None` fields are left out (the server's defaults on create, unchanged
/// on edit).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct AutomationDraft {
    /// Name.
    pub name: String,
    /// Prompt.
    pub prompt: String,
    /// The RFC 5545 rule.
    pub rrule: String,
    /// The agent.
    pub agent_id: String,
    /// IANA zone, e.g. the device's.
    pub timezone: String,
    /// Continue one session across runs; `None` on servers without session modes.
    pub continues_session: Option<bool>,
}

/// The automations page filter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AutomationFilter {
    /// Every automation.
    All,
    /// Active ones.
    Active,
    /// Paused ones.
    Paused,
}

/// `automations` matching `filter` and `search` (name, case-insensitive), in the web's order:
/// active first with the soonest next run on top (unknown next runs after), then paused by name.
#[must_use]
pub fn arrange_automations(
    automations: &[Automation],
    filter: AutomationFilter,
    search: &str,
) -> Vec<Automation> {
    let query = search.trim().to_lowercase();
    let mut matches: Vec<Automation> = automations
        .iter()
        .filter(|automation| match filter {
            AutomationFilter::All => true,
            AutomationFilter::Active => automation.state == AutomationState::Active,
            AutomationFilter::Paused => automation.is_paused(),
        })
        .filter(|automation| query.is_empty() || automation.name.to_lowercase().contains(&query))
        .cloned()
        .collect();
    matches.sort_by(|left, right| {
        left.is_paused()
            .cmp(&right.is_paused())
            .then_with(|| {
                if left.is_paused() {
                    return std::cmp::Ordering::Equal;
                }
                match (left.next_run_at, right.next_run_at) {
                    (Some(left), Some(right)) => left.cmp(&right),
                    (Some(_), None) => std::cmp::Ordering::Less,
                    (None, Some(_)) => std::cmp::Ordering::Greater,
                    (None, None) => std::cmp::Ordering::Equal,
                }
            })
            .then_with(|| left.name.cmp(&right.name))
    });
    matches
}

fn opt_i64(object: &Map<String, Value>, key: &str) -> Result<Option<i64>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        // Fractional seconds are truncated.
        Some(Value::Number(number)) => number
            .to_string()
            .split('.')
            .next()
            .and_then(|whole| whole.parse().ok())
            .map(Some)
            .ok_or_else(|| format!("`{key}` is not a whole-second time")),
        Some(_) => Err(format!("`{key}` is not a number")),
    }
}

fn automation_from(value: &Value) -> Result<Automation, String> {
    let object = as_object(value, "an automation")?;
    let rrule = req_str(object, "rrule")?;
    let state = match req_str(object, "state")?.as_str() {
        "active" => AutomationState::Active,
        "paused" => AutomationState::Paused,
        other => AutomationState::Unknown {
            value: other.to_owned(),
        },
    };
    let next_run_at = match opt_str(object, "next_run_at")? {
        None => None,
        Some(text) => Some(
            parse_iso8601(&text).ok_or_else(|| format!("`next_run_at` {text:?} is not a date"))?,
        ),
    };
    Ok(Automation {
        id: req_str(object, "id")?,
        name: req_str(object, "name")?,
        prompt: opt_str(object, "prompt")?.unwrap_or_default(),
        schedule_text: describe_schedule(&rrule),
        rrule,
        agent_id: opt_str(object, "agent_id")?.unwrap_or_default(),
        timezone: opt_str(object, "timezone")?.unwrap_or_else(|| "UTC".to_owned()),
        continues_session: opt_str(object, "session_mode")?.as_deref() == Some("continue"),
        state,
        next_run_at,
        last_run_at: opt_i64(object, "last_run_at")?,
        last_run_status: opt_str(object, "last_run_status")?,
        last_run_session_id: opt_str(object, "last_run_conversation_id")?,
        updated_at: opt_i64(object, "updated_at")?.unwrap_or_default(),
    })
}

fn draft_body(draft: &AutomationDraft) -> Result<Value, SessionError> {
    let name = draft.name.trim();
    if name.is_empty() || draft.prompt.trim().is_empty() || draft.agent_id.is_empty() {
        return Err(SessionError::Rejected {
            status: 400,
            message: "Give the automation a name, a prompt and an agent.".to_owned(),
        });
    }
    let mut body = Map::new();
    body.insert("name".into(), json!(name));
    body.insert("prompt".into(), json!(draft.prompt));
    body.insert("rrule".into(), json!(draft.rrule));
    body.insert("agent_id".into(), json!(draft.agent_id));
    body.insert("timezone".into(), json!(draft.timezone));
    if let Some(continues) = draft.continues_session {
        let mode = if continues { "continue" } else { "new" };
        body.insert("session_mode".into(), json!(mode));
    }
    Ok(Value::Object(body))
}

fn malformed(path: &str) -> impl Fn(String) -> SessionError + '_ {
    move |detail| SessionError::MalformedResponse {
        detail: format!("{path}: {detail}"),
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// Which top-level pages the server offers (`GET /v1/info`).
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn server_pages(&self) -> Result<ServerPages, SessionError> {
        let path = "/v1/info";
        let result = self.get_json(path, &[]).await;
        self.dispatch();
        ServerPages::from_value(&result?).map_err(malformed(path))
    }

    /// The caller's automations (`GET /v1/scheduled-tasks`), in the server's order.
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn automations(&self) -> Result<Vec<Automation>, SessionError> {
        let path = "/v1/scheduled-tasks";
        let result = self.get_json(path, &[]).await;
        self.dispatch();
        result?
            .get("scheduled_tasks")
            .and_then(Value::as_array)
            .ok_or_else(|| malformed(path)("no `scheduled_tasks` list".to_owned()))?
            .iter()
            .map(automation_from)
            .collect::<Result<_, _>>()
            .map_err(malformed(path))
    }

    /// Creates an automation (`POST /v1/scheduled-tasks`).
    ///
    /// # Errors
    ///
    /// `Rejected` for a draft without a name, prompt or agent (no request is made) or one the
    /// server refuses (a bad rule, an unknown agent); the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_automation(
        &self,
        draft: &AutomationDraft,
    ) -> Result<Automation, SessionError> {
        let path = "/v1/scheduled-tasks";
        let result = match draft_body(draft) {
            Ok(body) => self.write_json("POST", path, &body).await,
            Err(error) => Err(error),
        };
        self.dispatch();
        automation_from(&result?).map_err(malformed(path))
    }

    /// Saves an edited automation (`PATCH /v1/scheduled-tasks/{id}`).
    ///
    /// # Errors
    ///
    /// As [`Self::create_automation`], plus `InvalidIdentifier`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn update_automation(
        &self,
        id: &str,
        draft: &AutomationDraft,
    ) -> Result<Automation, SessionError> {
        let result = self.patch_automation(id, draft_body(draft)).await;
        self.dispatch();
        result
    }

    /// Pauses or resumes an automation.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn set_automation_paused(
        &self,
        id: &str,
        paused: bool,
    ) -> Result<Automation, SessionError> {
        let body = json!({"state": if paused { "paused" } else { "active" }});
        let result = self.patch_automation(id, Ok(body)).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn patch_automation(
        &self,
        id: &str,
        body: Result<Value, SessionError>,
    ) -> Result<Automation, SessionError> {
        validate_identifier(id)?;
        let path = format!("/v1/scheduled-tasks/{id}");
        let value = self.write_json("PATCH", &path, &body?).await?;
        automation_from(&value).map_err(malformed(&path))
    }

    /// Starts a run now (`POST /v1/scheduled-tasks/{id}/run`); the session appears in the list.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; `Rejected` (409) while a run is starting; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn run_automation(&self, id: &str) -> Result<(), SessionError> {
        let result = self.automation_write("POST", id, "/run").await;
        self.dispatch();
        result
    }

    /// Deletes an automation; sessions it started stay.
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier`; the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn delete_automation(&self, id: &str) -> Result<(), SessionError> {
        let result = self.automation_write("DELETE", id, "").await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn automation_write(
        &self,
        method: &str,
        id: &str,
        suffix: &str,
    ) -> Result<(), SessionError> {
        validate_identifier(id)?;
        let path = format!("/v1/scheduled-tasks/{id}{suffix}");
        self.write(self.prepare(method, &path, &[], None)?).await?;
        Ok(())
    }
}

#[cfg(test)]
#[path = "automations_tests.rs"]
mod tests;
