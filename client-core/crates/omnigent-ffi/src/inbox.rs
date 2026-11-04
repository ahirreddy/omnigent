//! The Inbox's file comments and inline replies, and the Usage page's report. The rules are
//! `omnigent_core::comments` and `omnigent_core::usage`.

use std::collections::BTreeSet;

use omnigent_core::comments as comments_core;
use omnigent_core::usage as usage_core;

use crate::client::{ClientCore, MessageSent};
use crate::errors::CoreError;

/// A comment someone left on a range of a session's workspace file.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct FileComment {
    /// Id.
    pub id: String,
    /// The session.
    pub session_id: String,
    /// File path relative to the workspace root.
    pub path: String,
    /// The comment.
    pub body: String,
    /// Open, not yet addressed.
    pub is_open: bool,
    /// The commented text when it was left.
    pub anchor: Option<String>,
    /// Who left it; `None` in single-user mode.
    pub author: Option<String>,
    /// Created, Unix seconds.
    pub created_at: i64,
    /// Last change, Unix microseconds.
    pub updated_at_micros: u64,
}

impl From<comments_core::FileComment> for FileComment {
    fn from(comment: comments_core::FileComment) -> Self {
        Self {
            id: comment.id,
            session_id: comment.session_id,
            path: comment.path,
            body: comment.body,
            is_open: comment.is_open,
            anchor: comment.anchor,
            author: comment.author,
            created_at: comment.created_at,
            updated_at_micros: comment.updated_at_micros,
        }
    }
}

impl From<FileComment> for comments_core::FileComment {
    fn from(comment: FileComment) -> Self {
        Self {
            id: comment.id,
            session_id: comment.session_id,
            path: comment.path,
            body: comment.body,
            is_open: comment.is_open,
            anchor: comment.anchor,
            author: comment.author,
            created_at: comment.created_at,
            updated_at_micros: comment.updated_at_micros,
        }
    }
}

/// The comments the Inbox lists: open, by someone other than `viewer_id`, unseen; newest first.
#[must_use]
#[uniffi::export]
pub fn comment_inbox(
    comments: Vec<FileComment>,
    seen_ids: Vec<String>,
    viewer_id: Option<String>,
) -> Vec<FileComment> {
    let comments: Vec<comments_core::FileComment> = comments.into_iter().map(Into::into).collect();
    let seen: BTreeSet<String> = seen_ids.into_iter().collect();
    comments_core::comment_inbox(&comments, &seen, viewer_id.as_deref())
        .into_iter()
        .map(Into::into)
        .collect()
}

/// Spend on one UTC day.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DailyCost {
    /// `YYYY-MM-DD`.
    pub day: String,
    /// US dollars.
    pub cost_usd: f64,
}

/// A model's recorded cost in one session.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ModelCost {
    /// The model id.
    pub model: String,
    /// US dollars.
    pub cost_usd: f64,
}

/// One session's spend.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SessionUsage {
    /// Session id.
    pub id: String,
    /// Title, when it has one.
    pub title: Option<String>,
    /// Created, Unix seconds.
    pub created_at: i64,
    /// Last activity, Unix seconds.
    pub updated_at: i64,
    /// US dollars, sub-agents included.
    pub cost_usd: f64,
    /// Cost per model, highest first.
    pub models: Vec<ModelCost>,
    /// The main harness.
    pub harness: Option<String>,
}

/// The caller's spend report.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct UsageReport {
    /// Spend per day.
    pub daily_costs: Vec<DailyCost>,
    /// Sessions, newest activity first.
    pub sessions: Vec<SessionUsage>,
}

/// A name and its cost.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CostShare {
    /// Harness or model.
    pub name: String,
    /// US dollars.
    pub cost_usd: f64,
}

/// The report narrowed to a window of days.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct UsageWindow {
    /// The window's total.
    pub total_cost_usd: f64,
    /// Days in the window.
    pub daily_costs: Vec<DailyCost>,
    /// Sessions active in the window.
    pub sessions: Vec<SessionUsage>,
    /// Cost by harness, highest first.
    pub by_harness: Vec<CostShare>,
    /// Cost by model, highest first.
    pub by_model: Vec<CostShare>,
}

impl From<usage_core::DailyCost> for DailyCost {
    fn from(cost: usage_core::DailyCost) -> Self {
        Self {
            day: cost.day,
            cost_usd: cost.cost_usd,
        }
    }
}

impl From<DailyCost> for usage_core::DailyCost {
    fn from(cost: DailyCost) -> Self {
        Self {
            day: cost.day,
            cost_usd: cost.cost_usd,
        }
    }
}

impl From<usage_core::SessionUsage> for SessionUsage {
    fn from(session: usage_core::SessionUsage) -> Self {
        Self {
            id: session.id,
            title: session.title,
            created_at: session.created_at,
            updated_at: session.updated_at,
            cost_usd: session.cost_usd,
            models: session
                .models
                .into_iter()
                .map(|(model, cost_usd)| ModelCost { model, cost_usd })
                .collect(),
            harness: session.harness,
        }
    }
}

impl From<SessionUsage> for usage_core::SessionUsage {
    fn from(session: SessionUsage) -> Self {
        Self {
            id: session.id,
            title: session.title,
            created_at: session.created_at,
            updated_at: session.updated_at,
            cost_usd: session.cost_usd,
            models: session
                .models
                .into_iter()
                .map(|cost| (cost.model, cost.cost_usd))
                .collect(),
            harness: session.harness,
        }
    }
}

impl From<usage_core::CostShare> for CostShare {
    fn from(share: usage_core::CostShare) -> Self {
        Self {
            name: share.name,
            cost_usd: share.cost_usd,
        }
    }
}

/// `report` within the inclusive UTC days `since..=until`; `None` is open-ended.
#[must_use]
#[uniffi::export]
pub fn usage_window(
    report: UsageReport,
    since: Option<String>,
    until: Option<String>,
) -> UsageWindow {
    let report = usage_core::UsageReport {
        daily_costs: report.daily_costs.into_iter().map(Into::into).collect(),
        sessions: report.sessions.into_iter().map(Into::into).collect(),
    };
    let window = usage_core::usage_window(&report, since.as_deref(), until.as_deref());
    UsageWindow {
        total_cost_usd: window.total_cost_usd,
        daily_costs: window.daily_costs.into_iter().map(Into::into).collect(),
        sessions: window.sessions.into_iter().map(Into::into).collect(),
        by_harness: window.by_harness.into_iter().map(Into::into).collect(),
        by_model: window.by_model.into_iter().map(Into::into).collect(),
    }
}

/// The first UTC day of a window of `days` days ending on `now`'s day (Unix seconds).
#[must_use]
#[uniffi::export]
pub fn usage_window_start(days: u32, now: i64) -> String {
    usage_core::window_start(days, now)
}

/// The UTC day of `now` (Unix seconds), `YYYY-MM-DD`.
#[must_use]
#[uniffi::export]
pub fn usage_day(now: i64) -> String {
    usage_core::utc_day(now)
}

/// `$1.23`, or `<$0.01` under a cent.
#[must_use]
#[uniffi::export]
pub fn format_cost_usd(cost_usd: f64) -> String {
    usage_core::format_cost_usd(cost_usd)
}

#[uniffi::export]
impl ClientCore {
    /// Every comment on `session_id`'s files.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`; the read errors; `MalformedResponse`.
    pub async fn session_comments(
        &self,
        session_id: String,
    ) -> Result<Vec<FileComment>, CoreError> {
        self.sessions()
            .session_comments(&session_id)
            .await
            .map(|comments| comments.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// Sends `text` alone to a session from outside its conversation (the Inbox's reply): no
    /// open stream needed, and the composer's draft and staged files are left alone.
    ///
    /// # Errors
    ///
    /// As `send_message`, less the stream-not-ready error.
    pub async fn send_reply(
        &self,
        session_id: String,
        text: String,
    ) -> Result<MessageSent, CoreError> {
        let sent = self
            .sessions()
            .send_reply(&session_id, &text)
            .await
            .map_err(CoreError::from)?;
        Ok(MessageSent {
            queued: sent.submission.queued,
            item_id: sent.submission.item_id,
            pending_id: sent.submission.pending_id,
            draft: sent.draft,
        })
    }

    /// The caller's spend.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn usage_report(&self) -> Result<UsageReport, CoreError> {
        let report = self
            .sessions()
            .usage_report()
            .await
            .map_err(CoreError::from)?;
        Ok(UsageReport {
            daily_costs: report.daily_costs.into_iter().map(Into::into).collect(),
            sessions: report.sessions.into_iter().map(Into::into).collect(),
        })
    }
}
