//! The Inbox's server-side feeds: items agents post for their owner and automation failures
//! that made no session. The rules are `omnigent_core::inbox_items`.

use omnigent_core::inbox_items::{
    self as core, AgentInboxItem, AgentInboxPage, AgentInboxUpdate, AutomationFailurePage,
    InboxChart, InboxLinkTarget, InboxResolution,
};

use crate::client::ClientCore;
use crate::errors::CoreError;

/// A link an agent attached: a session on this server or a plain web page.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct InboxLinkRecord {
    /// The text it shows: the agent's label, else "Open session" or the reference.
    pub title: String,
    /// The session it opens.
    pub session_id: Option<String>,
    /// The web page it opens.
    pub web_url: Option<String>,
}

/// A button that opens a new session with `prompt` as the draft.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct InboxActionRecord {
    /// The label.
    pub label: String,
    /// The new session's draft.
    pub prompt: String,
}

/// One series of a chart.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct InboxChartSeriesRecord {
    /// The legend's name.
    pub name: String,
    /// One value per label; `nil` is a gap.
    pub values: Vec<Option<f64>>,
    /// Drawn heavier.
    pub emphasis: bool,
}

/// A labelled vertical line.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct InboxChartMarkerRecord {
    /// The x label it sits at.
    pub at: String,
    /// Its label.
    pub label: String,
}

/// A line or bar chart an agent attached.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct InboxChartRecord {
    /// Bars rather than lines.
    pub is_bar: bool,
    /// The caption.
    pub title: String,
    /// The values' unit.
    pub unit: Option<String>,
    /// The x labels.
    pub labels: Vec<String>,
    /// The series.
    pub series: Vec<InboxChartSeriesRecord>,
    /// A shaded band's first label.
    pub highlight_from: Option<String>,
    /// A shaded band's last label.
    pub highlight_to: Option<String>,
    /// Labelled vertical lines.
    pub markers: Vec<InboxChartMarkerRecord>,
    /// Where the numbers come from.
    pub source_label: Option<String>,
    /// A safe web link for the source.
    pub source_url: Option<String>,
}

impl From<InboxChart> for InboxChartRecord {
    fn from(chart: InboxChart) -> Self {
        let (highlight_from, highlight_to) = chart.highlight.unzip();
        let (source_label, source_url) = chart
            .source
            .map_or((None, None), |(label, url)| (Some(label), url));
        Self {
            is_bar: chart.is_bar,
            title: chart.title,
            unit: chart.unit,
            labels: chart.labels,
            series: chart
                .series
                .into_iter()
                .map(|series| InboxChartSeriesRecord {
                    name: series.name,
                    values: series.values,
                    emphasis: series.emphasis,
                })
                .collect(),
            highlight_from,
            highlight_to,
            markers: chart
                .markers
                .into_iter()
                .map(|(at, label)| InboxChartMarkerRecord { at, label })
                .collect(),
            source_label,
            source_url,
        }
    }
}

/// An item an agent posted to its owner's Inbox.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AgentInboxItemRecord {
    /// Id.
    pub id: String,
    /// The session whose agent posted it.
    pub source_session_id: String,
    /// That session's agent.
    pub agent_id: String,
    /// `followup`, `info` or `reminder`.
    pub kind: String,
    /// The kind's label: "Suggested follow-up", "Reminder" or "For your information".
    pub kind_label: String,
    /// Title.
    pub title: String,
    /// The body, as Markdown.
    pub body_md: String,
    /// The body's first line, for the collapsed row.
    pub preview: String,
    /// Openable links, each target once.
    pub links: Vec<InboxLinkRecord>,
    /// Actions, the first the primary one.
    pub actions: Vec<InboxActionRecord>,
    /// Charts to draw.
    pub charts: Vec<InboxChartRecord>,
    /// Not read yet.
    pub is_unread: bool,
    /// Neither done nor dismissed.
    pub is_open: bool,
    /// Posted, Unix seconds.
    pub created_at: i64,
}

impl From<AgentInboxItem> for AgentInboxItemRecord {
    fn from(item: AgentInboxItem) -> Self {
        let is_unread = item.is_unread();
        let is_open = item.is_open();
        Self {
            preview: core::inbox_item_preview(&item.body_md),
            kind_label: core::inbox_item_kind_label(&item.kind).to_owned(),
            links: item
                .links
                .into_iter()
                .map(|link| {
                    let title = link.title();
                    let (session_id, web_url) = match link.target {
                        Some(InboxLinkTarget::Session(id)) => (Some(id), None),
                        Some(InboxLinkTarget::Web(url)) => (None, Some(url)),
                        None => (None, None),
                    };
                    InboxLinkRecord {
                        title,
                        session_id,
                        web_url,
                    }
                })
                .collect(),
            actions: item
                .actions
                .into_iter()
                .map(|action| InboxActionRecord {
                    label: action.label,
                    prompt: action.prompt,
                })
                .collect(),
            charts: item.charts.into_iter().map(Into::into).collect(),
            id: item.id,
            source_session_id: item.source_session_id,
            agent_id: item.agent_id,
            kind: item.kind,
            title: item.title,
            body_md: item.body_md,
            is_unread,
            is_open,
            created_at: item.created_at,
        }
    }
}

/// One page of items, with the server's unread total.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AgentInboxPageRecord {
    /// Items, newest first.
    pub items: Vec<AgentInboxItemRecord>,
    /// The next page's cursor.
    pub next_cursor: Option<String>,
    /// Every unread item, up to the server's cap.
    pub unread_count: u64,
    /// The server stopped counting: show "N+".
    pub unread_count_capped: bool,
}

impl From<AgentInboxPage> for AgentInboxPageRecord {
    fn from(page: AgentInboxPage) -> Self {
        Self {
            items: page.items.into_iter().map(Into::into).collect(),
            next_cursor: page.next_cursor,
            unread_count: page.unread_count,
            unread_count_capped: page.unread_count_capped,
        }
    }
}

/// An item after a change, with the new unread total.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AgentInboxUpdateRecord {
    /// The item as the server now has it.
    pub item: AgentInboxItemRecord,
    /// Every unread item, up to the server's cap.
    pub unread_count: u64,
    /// The server stopped counting.
    pub unread_count_capped: bool,
}

impl From<AgentInboxUpdate> for AgentInboxUpdateRecord {
    fn from(update: AgentInboxUpdate) -> Self {
        Self {
            item: update.item.into(),
            unread_count: update.unread_count,
            unread_count_capped: update.unread_count_capped,
        }
    }
}

/// Why an item is dismissed: the Dismiss menu's reasons.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum InboxDismissReason {
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

impl From<InboxDismissReason> for InboxResolution {
    fn from(reason: InboxDismissReason) -> Self {
        match reason {
            InboxDismissReason::AlreadyDone => Self::AlreadyDone,
            InboxDismissReason::Useful => Self::Useful,
            InboxDismissReason::NotRelevant => Self::NotRelevant,
            InboxDismissReason::Incorrect => Self::Incorrect,
            InboxDismissReason::NotNow => Self::NotNow,
        }
    }
}

/// A Dismiss menu entry.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct InboxDismissOption {
    /// The reason sent.
    pub reason: InboxDismissReason,
    /// The menu's label.
    pub label: String,
}

/// The Dismiss menu, in the web's order.
#[must_use]
#[uniffi::export]
pub fn inbox_dismiss_options() -> Vec<InboxDismissOption> {
    [
        InboxDismissReason::AlreadyDone,
        InboxDismissReason::Useful,
        InboxDismissReason::NotRelevant,
        InboxDismissReason::Incorrect,
        InboxDismissReason::NotNow,
    ]
    .into_iter()
    .map(|reason| InboxDismissOption {
        reason,
        label: InboxResolution::from(reason).label().to_owned(),
    })
    .collect()
}

/// The latest run of an automation that failed before it made a session.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AutomationFailureRecord {
    /// The automation.
    pub task_id: String,
    /// Its name.
    pub task_name: String,
    /// The failed run.
    pub run_id: String,
    /// Where it stopped and why: "Host · The host was offline.".
    pub reason: String,
    /// When it ended, else when it was due, Unix seconds.
    pub at: i64,
}

/// One page of automation failures; it can be empty and still continue.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AutomationFailurePageRecord {
    /// One failure per automation.
    pub failures: Vec<AutomationFailureRecord>,
    /// The next page's cursor.
    pub next_cursor: Option<String>,
}

impl From<AutomationFailurePage> for AutomationFailurePageRecord {
    fn from(page: AutomationFailurePage) -> Self {
        Self {
            failures: page
                .failures
                .into_iter()
                .map(|failure| AutomationFailureRecord {
                    reason: failure.reason(),
                    at: failure.at(),
                    task_id: failure.task_id,
                    task_name: failure.task_name,
                    run_id: failure.run_id,
                })
                .collect(),
            next_cursor: page.next_cursor,
        }
    }
}

#[uniffi::export]
impl ClientCore {
    /// A page of the caller's open agent-posted items.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors.
    pub async fn agent_inbox_items(
        &self,
        after: Option<String>,
    ) -> Result<AgentInboxPageRecord, CoreError> {
        self.sessions()
            .agent_inbox_items(after.as_deref())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Marks an open item read or unread.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the write errors.
    pub async fn mark_agent_inbox_item(
        &self,
        item_id: String,
        read: bool,
    ) -> Result<AgentInboxUpdateRecord, CoreError> {
        self.sessions()
            .mark_agent_inbox_item(&item_id, read)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Records that the item's action at `index` was taken, which marks it done.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the write errors.
    pub async fn take_agent_inbox_action(
        &self,
        item_id: String,
        index: u32,
    ) -> Result<AgentInboxUpdateRecord, CoreError> {
        self.sessions()
            .resolve_agent_inbox_item(&item_id, InboxResolution::ActionTaken(index))
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Dismisses an item for a reason ("Already done" marks it done).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the write errors.
    pub async fn dismiss_agent_inbox_item(
        &self,
        item_id: String,
        reason: InboxDismissReason,
    ) -> Result<AgentInboxUpdateRecord, CoreError> {
        self.sessions()
            .resolve_agent_inbox_item(&item_id, reason.into())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// A page of automation failures that made no session.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors.
    pub async fn automation_failures(
        &self,
        after: Option<String>,
    ) -> Result<AutomationFailurePageRecord, CoreError> {
        self.sessions()
            .automation_failures(after.as_deref())
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}
