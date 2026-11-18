//! The Inbox's server-side feeds beside the sessions: items agents post for their owner
//! (`/v1/inbox/items`, the web's `lib/proactiveInbox.ts`), and the latest failed runs of
//! automations that never made a session (`/v1/scheduled-tasks/inbox`, `useAutomationInbox`).
//! Servers advertise them with `/v1/info.inbox_items_available` and `scheduled_task_inbox`.

use std::collections::BTreeSet;

use serde_json::{Map, Value, json};
use url::Url;

use super::automations::{AutomationRunStatus, describe_run_failure};
use super::json::{as_object, opt_array, opt_bool, opt_str, opt_u64, req_str};
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

const ITEMS_PATH: &str = "/v1/inbox/items";
const AUTOMATION_INBOX_PATH: &str = "/v1/scheduled-tasks/inbox";
/// Items and failures per page, as the web asks.
pub const INBOX_PAGE_SIZE: u32 = 50;
/// The open statuses the Inbox lists.
const OPEN_STATUSES: [&str; 2] = ["unread", "read"];
/// The preview's character budget, the ellipsis included.
const PREVIEW_CHARS: usize = 200;
const MAX_CHART_SERIES: usize = 4;
const MAX_CHART_LABELS: usize = 60;
const MAX_CHART_MARKERS: usize = 3;

/// A reference an agent attached to an item.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InboxLink {
    /// What the link opens; `None` for a reference this client cannot open.
    pub target: Option<InboxLinkTarget>,
    /// The agent's label.
    pub label: Option<String>,
    /// The reference as written.
    pub reference: String,
}

/// Where an item's link goes.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum InboxLinkTarget {
    /// A session on this server, by id.
    Session(String),
    /// A plain web page (`pr` and `url` links).
    Web(String),
}

impl InboxLink {
    /// The text the link shows: its label, else "Open session" or the reference.
    #[must_use]
    pub fn title(&self) -> String {
        match (&self.label, &self.target) {
            (Some(label), _) => label.clone(),
            (None, Some(InboxLinkTarget::Session(_))) => "Open session".to_owned(),
            (None, _) => self.reference.clone(),
        }
    }
}

/// A button an agent offers on its item: it opens a new session with `prompt` as the draft.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InboxAction {
    /// The button's label.
    pub label: String,
    /// The new session's draft.
    pub prompt: String,
}

/// A line or bar chart an agent attached (the server's `InboxChartV1`).
#[derive(Debug, Clone, PartialEq)]
pub struct InboxChart {
    /// Bars rather than lines.
    pub is_bar: bool,
    /// The caption.
    pub title: String,
    /// The values' unit, such as `ms` or `%`.
    pub unit: Option<String>,
    /// The x-axis labels, in order.
    pub labels: Vec<String>,
    /// One to four series, each with one value (or a gap) per label.
    pub series: Vec<InboxChartSeries>,
    /// A shaded band from one label to another.
    pub highlight: Option<(String, String)>,
    /// Labelled vertical lines at a label.
    pub markers: Vec<(String, String)>,
    /// Where the numbers come from: a label and a safe web link.
    pub source: Option<(String, Option<String>)>,
}

/// One series of an [`InboxChart`].
#[derive(Debug, Clone, PartialEq)]
pub struct InboxChartSeries {
    /// The legend's name.
    pub name: String,
    /// One value per label; `None` is a gap.
    pub values: Vec<Option<f64>>,
    /// Drawn heavier than the others.
    pub emphasis: bool,
}

/// An item an agent posted to its owner's Inbox.
#[derive(Debug, Clone, PartialEq)]
pub struct AgentInboxItem {
    /// Id.
    pub id: String,
    /// The session whose agent posted it.
    pub source_session_id: String,
    /// That session's agent.
    pub agent_id: String,
    /// `followup`, `info` or `reminder`.
    pub kind: String,
    /// Title.
    pub title: String,
    /// The body, as Markdown.
    pub body_md: String,
    /// References, de-duplicated by where they go.
    pub links: Vec<InboxLink>,
    /// At most three actions, the first the primary one.
    pub actions: Vec<InboxAction>,
    /// Charts this client can draw.
    pub charts: Vec<InboxChart>,
    /// `unread`, `read`, `done` or `dismissed`.
    pub status: String,
    /// Posted, Unix seconds.
    pub created_at: i64,
}

impl AgentInboxItem {
    /// Not read yet.
    #[must_use]
    pub fn is_unread(&self) -> bool {
        self.status == "unread"
    }

    /// Still open: neither done nor dismissed.
    #[must_use]
    pub fn is_open(&self) -> bool {
        OPEN_STATUSES.contains(&self.status.as_str())
    }
}

/// One page of the caller's items, with the server's unread total.
#[derive(Debug, Clone, PartialEq)]
pub struct AgentInboxPage {
    /// Items, newest first.
    pub items: Vec<AgentInboxItem>,
    /// The next page's cursor.
    pub next_cursor: Option<String>,
    /// Every unread item the caller has, up to the server's cap.
    pub unread_count: u64,
    /// The server stopped counting at its cap: show "N+".
    pub unread_count_capped: bool,
}

/// The item after a change, with the server's new unread total.
#[derive(Debug, Clone, PartialEq)]
pub struct AgentInboxUpdate {
    /// The item as the server now has it.
    pub item: AgentInboxItem,
    /// Every unread item the caller has, up to the server's cap.
    pub unread_count: u64,
    /// The server stopped counting at its cap.
    pub unread_count_capped: bool,
}

/// How an item is resolved: an action taken, or one of the Dismiss menu's reasons.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InboxResolution {
    /// The action at this index was taken.
    ActionTaken(u32),
    /// "Already done".
    AlreadyDone,
    /// "Useful, no action needed".
    Useful,
    /// "Not relevant".
    NotRelevant,
    /// "Incorrect".
    Incorrect,
    /// "Not now".
    NotNow,
}

impl InboxResolution {
    /// The Dismiss menu's reasons, in menu order.
    pub const DISMISS_REASONS: [Self; 5] = [
        Self::AlreadyDone,
        Self::Useful,
        Self::NotRelevant,
        Self::Incorrect,
        Self::NotNow,
    ];

    /// The server's value.
    #[must_use]
    pub const fn wire(self) -> &'static str {
        match self {
            Self::ActionTaken(_) => "action_taken",
            Self::AlreadyDone => "already_done",
            Self::Useful => "useful",
            Self::NotRelevant => "not_relevant",
            Self::Incorrect => "incorrect",
            Self::NotNow => "not_now",
        }
    }

    /// The Dismiss menu's label; an action's own label names it instead.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::ActionTaken(_) => "Action taken",
            Self::AlreadyDone => "Already done",
            Self::Useful => "Useful, no action needed",
            Self::NotRelevant => "Not relevant",
            Self::Incorrect => "Incorrect",
            Self::NotNow => "Not now",
        }
    }
}

/// The latest run of an automation that failed before it made a session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutomationFailure {
    /// The automation.
    pub task_id: String,
    /// Its name.
    pub task_name: String,
    /// The failed run, to mark it read.
    pub run_id: String,
    /// When it was due, Unix seconds.
    pub scheduled_at: i64,
    /// When it ended, Unix seconds.
    pub finished_at: Option<i64>,
    /// Why, from the scheduler.
    pub error_code: Option<String>,
}

impl AutomationFailure {
    /// Where the run stopped and why, as the web words it: "Host · The host was offline.".
    #[must_use]
    pub fn reason(&self) -> String {
        match describe_run_failure(self.error_code.as_deref(), &AutomationRunStatus::Failed) {
            (Some(stage), reason) => format!("{stage} \u{00B7} {reason}"),
            (None, reason) => reason.to_owned(),
        }
    }

    /// When the row sorts: the end, else the due time.
    #[must_use]
    pub fn at(&self) -> i64 {
        self.finished_at.unwrap_or(self.scheduled_at)
    }
}

/// One page of automation failures. A page can be empty and still have a next one: the cursor
/// walks automations, not failures.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutomationFailurePage {
    /// Failures, one per automation.
    pub failures: Vec<AutomationFailure>,
    /// The next page's cursor.
    pub next_cursor: Option<String>,
}

/// An item kind's label (`suggestionKindLabel`).
#[must_use]
pub fn inbox_item_kind_label(kind: &str) -> &'static str {
    match kind {
        "followup" => "Suggested follow-up",
        "reminder" => "Reminder",
        _ => "For your information",
    }
}

/// The body's first non-empty line without its leading Markdown markers (`#`, `>`, `*`, `-`
/// or `1.`), cut to 200 characters with an ellipsis (`suggestionPreview`).
#[must_use]
pub fn inbox_item_preview(body_md: &str) -> String {
    let Some(line) = body_md
        .split('\n')
        .map(strip_markers)
        .find(|line| !line.is_empty())
    else {
        return String::new();
    };
    let chars: Vec<char> = line.chars().collect();
    if chars.len() > PREVIEW_CHARS {
        let mut cut: String = chars[..PREVIEW_CHARS - 1].iter().collect();
        cut.push('\u{2026}');
        cut
    } else {
        line.to_owned()
    }
}

fn strip_markers(line: &str) -> &str {
    let rest = line.trim_start();
    let digits = rest.chars().take_while(char::is_ascii_digit).count();
    let rest = if digits > 0 && rest[digits..].starts_with('.') {
        &rest[digits + 1..]
    } else {
        rest.trim_start_matches(['#', '>', '*', '-'])
    };
    rest.trim()
}

/// A plain web link: an http(s) URL with a host and no user name or password (`safeWebHref`).
#[must_use]
pub fn safe_web_link(reference: &str) -> Option<String> {
    let trimmed = reference.trim();
    let lower = trimmed.get(..8).unwrap_or(trimmed).to_ascii_lowercase();
    if !(lower.starts_with("http://") || lower.starts_with("https://")) {
        return None;
    }
    let url = Url::parse(trimmed).ok()?;
    let plain = matches!(url.scheme(), "http" | "https")
        && url.host_str().is_some_and(|host| !host.is_empty())
        && url.username().is_empty()
        && url.password().is_none();
    plain.then(|| url.to_string())
}

fn link_from(value: &Value) -> Result<InboxLink, String> {
    let object = as_object(value, "link")?;
    let kind = req_str(object, "type")?;
    let reference = req_str(object, "ref")?;
    let trimmed = reference.trim();
    let target = if trimmed.is_empty() {
        None
    } else if kind == "session" {
        Some(InboxLinkTarget::Session(trimmed.to_owned()))
    } else {
        // Agents write these, so only plain web links open.
        safe_web_link(trimmed).map(InboxLinkTarget::Web)
    };
    Ok(InboxLink {
        target,
        label: opt_str(object, "label")?,
        reference,
    })
}

/// Openable links, each target once, in the agent's order.
fn unique_links(links: Vec<InboxLink>) -> Vec<InboxLink> {
    let mut seen = BTreeSet::new();
    links
        .into_iter()
        .filter(|link| {
            link.target
                .as_ref()
                .is_some_and(|target| seen.insert(target.clone()))
        })
        .collect()
}

fn non_empty(object: &Map<String, Value>, key: &str) -> Option<String> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|text| !text.trim().is_empty())
        .map(str::to_owned)
}

/// A chart block this client can draw, else `None` (`parseSuggestionChart`).
fn chart_from(raw: &Value) -> Option<InboxChart> {
    let raw = raw.as_object()?;
    if raw.get("version").and_then(Value::as_u64) != Some(1) {
        return None;
    }
    let is_bar = match raw.get("type").and_then(Value::as_str)? {
        "bar" => true,
        "line" => false,
        _ => return None,
    };
    let title = non_empty(raw, "title")?;
    let labels: Vec<String> = raw
        .get("x")?
        .as_array()?
        .iter()
        .map(|label| label.as_str().map(str::to_owned))
        .collect::<Option<_>>()?;
    if labels.is_empty() || labels.len() > MAX_CHART_LABELS {
        return None;
    }
    let has = |label: &str| labels.iter().any(|known| known == label);
    let series_values = raw.get("series")?.as_array()?;
    if series_values.is_empty() || series_values.len() > MAX_CHART_SERIES {
        return None;
    }
    let series = series_values
        .iter()
        .map(|entry| {
            let entry = entry.as_object()?;
            let values: Vec<Option<f64>> = entry
                .get("values")?
                .as_array()?
                .iter()
                .map(|value| match value {
                    Value::Null => Some(None),
                    other => other.as_f64().filter(|v| v.is_finite()).map(Some),
                })
                .collect::<Option<_>>()?;
            (values.len() == labels.len()).then(|| InboxChartSeries {
                name: non_empty(entry, "name").unwrap_or_default(),
                values,
                emphasis: entry.get("emphasis").and_then(Value::as_bool) == Some(true),
            })
        })
        .collect::<Option<Vec<_>>>()?;
    if series.iter().any(|entry| entry.name.is_empty()) {
        return None;
    }
    let highlight = match raw.get("highlight") {
        None | Some(Value::Null) => None,
        Some(band) => {
            let from = band.get("from")?.as_str()?;
            let to = band.get("to")?.as_str()?;
            if !has(from) || !has(to) {
                return None;
            }
            Some((from.to_owned(), to.to_owned()))
        }
    };
    let marker_values = match raw.get("markers") {
        None | Some(Value::Null) => &Vec::new(),
        Some(markers) => markers.as_array()?,
    };
    if marker_values.len() > MAX_CHART_MARKERS {
        return None;
    }
    let markers = marker_values
        .iter()
        .map(|marker| {
            let marker = marker.as_object()?;
            let at = marker.get("x")?.as_str()?;
            let label = non_empty(marker, "label")?;
            has(at).then(|| (at.to_owned(), label))
        })
        .collect::<Option<Vec<_>>>()?;
    let source = match raw.get("source") {
        None | Some(Value::Null) => None,
        Some(source) => {
            let source = source.as_object()?;
            let label = non_empty(source, "label")?;
            let href = source
                .get("href")
                .and_then(Value::as_str)
                .and_then(safe_web_link);
            Some((label, href))
        }
    };
    let unit = match raw.get("unit") {
        None | Some(Value::Null) => None,
        Some(Value::String(unit)) => (!unit.is_empty()).then(|| unit.clone()),
        Some(_) => return None,
    };
    Some(InboxChart {
        is_bar,
        title,
        unit,
        labels,
        series,
        highlight,
        markers,
        source,
    })
}


fn item_from(value: &Value) -> Result<AgentInboxItem, String> {
    let object = as_object(value, "item")?;
    let links = opt_array(object, "links")?
        .map(|links| links.iter().map(link_from).collect::<Result<Vec<_>, _>>())
        .transpose()?
        .unwrap_or_default();
    // As the web, an action without a string label and prompt is skipped.
    let actions = opt_array(object, "actions")?
        .map(|actions| {
            actions
                .iter()
                .filter_map(|action| {
                    let label = action.get("label")?.as_str()?;
                    let prompt = action.get("prompt")?.as_str()?;
                    Some(InboxAction {
                        label: label.to_owned(),
                        prompt: prompt.to_owned(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let charts = opt_array(object, "media")?
        .map(|media| {
            media
                .iter()
                .filter(|block| block.get("type").and_then(Value::as_str) == Some("chart"))
                .filter_map(|block| block.get("chart").and_then(chart_from))
                .collect()
        })
        .unwrap_or_default();
    Ok(AgentInboxItem {
        id: req_str(object, "id")?,
        source_session_id: req_str(object, "source_session_id")?,
        agent_id: opt_str(object, "agent_id")?.unwrap_or_default(),
        kind: req_str(object, "kind")?,
        title: req_str(object, "title")?,
        body_md: req_str(object, "body_md")?,
        links: unique_links(links),
        actions,
        charts,
        status: req_str(object, "status")?,
        created_at: object
            .get("created_at")
            .and_then(Value::as_i64)
            .ok_or("`created_at` is not an integer")?,
    })
}

fn counts(object: &Map<String, Value>) -> Result<(u64, bool), String> {
    Ok((
        opt_u64(object, "unread_count")?.unwrap_or(0),
        opt_bool(object, "unread_count_capped")?.unwrap_or(false),
    ))
}

impl AgentInboxPage {
    /// Decodes `GET /v1/inbox/items`.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, ITEMS_PATH)?;
        let items = opt_array(object, "data")?
            .ok_or("`data` is missing")?
            .iter()
            .map(item_from)
            .collect::<Result<Vec<_>, _>>()?;
        let (unread_count, unread_count_capped) = counts(object)?;
        Ok(Self {
            items,
            next_cursor: opt_str(object, "next_cursor")?.filter(|cursor| !cursor.is_empty()),
            unread_count,
            unread_count_capped,
        })
    }
}

impl AgentInboxUpdate {
    /// Decodes a `PATCH /v1/inbox/items/{id}` answer: the item's fields with the counts.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, ITEMS_PATH)?;
        let (unread_count, unread_count_capped) = counts(object)?;
        Ok(Self {
            item: item_from(value)?,
            unread_count,
            unread_count_capped,
        })
    }
}

impl AutomationFailurePage {
    /// Decodes `GET /v1/scheduled-tasks/inbox`.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, AUTOMATION_INBOX_PATH)?;
        let failures = opt_array(object, "data")?
            .ok_or("`data` is missing")?
            .iter()
            .map(|row| {
                let row = as_object(row, "failure")?;
                let time = |key: &str| row.get(key).and_then(Value::as_i64);
                Ok(AutomationFailure {
                    task_id: req_str(row, "task_id")?,
                    task_name: req_str(row, "task_name")?,
                    run_id: req_str(row, "run_id")?,
                    scheduled_at: time("scheduled_at").ok_or("`scheduled_at` is missing")?,
                    finished_at: time("finished_at"),
                    error_code: opt_str(row, "error_code")?,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        Ok(Self {
            failures,
            next_cursor: opt_str(object, "next_cursor")?.filter(|cursor| !cursor.is_empty()),
        })
    }
}


fn validate_item_id(item_id: &str) -> Result<(), SessionError> {
    if item_id.len() == 32 && item_id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(SessionError::InvalidIdentifier {
            value: item_id.to_owned(),
        })
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// A page of the caller's open items (`GET /v1/inbox/items`, unread and read).
    ///
    /// # Errors
    ///
    /// The read errors (404 where the server does not offer them);
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn agent_inbox_items(
        &self,
        after: Option<&str>,
    ) -> Result<AgentInboxPage, SessionError> {
        let mut query = vec![("limit", INBOX_PAGE_SIZE.to_string())];
        query.extend(OPEN_STATUSES.iter().map(|status| ("status", (*status).to_owned())));
        if let Some(after) = after {
            query.push(("after", after.to_owned()));
        }
        let result = self.get_json(ITEMS_PATH, &query).await;
        self.dispatch();
        AgentInboxPage::from_value(&result?).map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{ITEMS_PATH}: {detail}"),
        })
    }

    /// Marks an open item read or unread (`PATCH /v1/inbox/items/{id}` with `status`).
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; the write errors; `DeliveryUncertain` for an
    /// unreadable acknowledgement.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn mark_agent_inbox_item(
        &self,
        item_id: &str,
        read: bool,
    ) -> Result<AgentInboxUpdate, SessionError> {
        let body = json!({ "status": if read { "read" } else { "unread" } });
        self.patch_inbox_item(item_id, &body).await
    }

    /// Resolves an item: an action taken, or dismissed for a reason (`PATCH` with
    /// `resolution`).
    ///
    /// # Errors
    ///
    /// `InvalidIdentifier` before any request; the write errors (400 for an action the item
    /// lacks); `DeliveryUncertain` for an unreadable acknowledgement.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn resolve_agent_inbox_item(
        &self,
        item_id: &str,
        resolution: InboxResolution,
    ) -> Result<AgentInboxUpdate, SessionError> {
        let body = match resolution {
            InboxResolution::ActionTaken(index) => {
                json!({ "resolution": resolution.wire(), "resolution_action": index })
            }
            _ => json!({ "resolution": resolution.wire() }),
        };
        self.patch_inbox_item(item_id, &body).await
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn patch_inbox_item(
        &self,
        item_id: &str,
        body: &Value,
    ) -> Result<AgentInboxUpdate, SessionError> {
        validate_item_id(item_id)?;
        let path = format!("{ITEMS_PATH}/{item_id}");
        let result = self.write_json("PATCH", &path, body).await;
        self.dispatch();
        AgentInboxUpdate::from_value(&result?).map_err(|detail| SessionError::DeliveryUncertain {
            detail: format!("unreadable {path} acknowledgement: {detail}"),
        })
    }

    /// A page of the latest failed runs of automations that made no session
    /// (`GET /v1/scheduled-tasks/inbox`).
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn automation_failures(
        &self,
        after: Option<&str>,
    ) -> Result<AutomationFailurePage, SessionError> {
        let mut query = vec![("limit", INBOX_PAGE_SIZE.to_string())];
        if let Some(after) = after {
            query.push(("after", after.to_owned()));
        }
        let result = self.get_json(AUTOMATION_INBOX_PATH, &query).await;
        self.dispatch();
        AutomationFailurePage::from_value(&result?).map_err(|detail| {
            SessionError::MalformedResponse {
                detail: format!("{AUTOMATION_INBOX_PATH}: {detail}"),
            }
        })
    }
}

#[cfg(test)]
#[path = "inbox_items_tests.rs"]
mod tests;
