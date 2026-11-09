//! The caller's spend (`GET /v1/usage`) and the Usage page's windows and breakdowns.
//!
//! They follow the web (`web/src/pages/UsagePage.tsx`, `UsageBreakdownCharts.tsx`). Servers
//! advertise the page with the `usage_page` feature in `/v1/info`.

use std::collections::BTreeMap;

use serde_json::{Map, Value};

use super::json::{as_object, opt_array, opt_object, opt_str, req_str};
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;
use crate::schedule::{MAX_DATE_YEAR, days_from_civil, number as number_in};

/// Spend on one UTC day.
#[derive(Debug, Clone, PartialEq)]
pub struct DailyCost {
    /// `YYYY-MM-DD`.
    pub day: String,
    /// US dollars.
    pub cost_usd: f64,
}

/// One session's spend, its sub-agents included.
#[derive(Debug, Clone, PartialEq)]
pub struct SessionUsage {
    /// Session id.
    pub id: String,
    /// Title, when it has one.
    pub title: Option<String>,
    /// Created, Unix seconds.
    pub created_at: i64,
    /// Last activity, Unix seconds.
    pub updated_at: i64,
    /// US dollars.
    pub cost_usd: f64,
    /// Recorded cost per model, highest first; it need not add up to `cost_usd`.
    pub models: Vec<(String, f64)>,
    /// The main harness.
    pub harness: Option<String>,
}

/// The report.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct UsageReport {
    /// Spend per day, oldest first.
    pub daily_costs: Vec<DailyCost>,
    /// Sessions, newest activity first.
    pub sessions: Vec<SessionUsage>,
}

/// A name and its cost, for the breakdowns.
#[derive(Debug, Clone, PartialEq)]
pub struct CostShare {
    /// Harness or model, or "Unknown".
    pub name: String,
    /// US dollars.
    pub cost_usd: f64,
}

/// The report narrowed to a window of days.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct UsageWindow {
    /// The window's total: its daily spend, or its sessions' when no day recorded any.
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

/// The `YYYY-MM-DD` UTC day of Unix second `seconds`.
#[must_use]
pub fn utc_day(seconds: i64) -> String {
    // Howard Hinnant's `civil_from_days`.
    let days = seconds.div_euclid(86_400) + 719_468;
    let era = days.div_euclid(146_097);
    let day_of_era = days - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}

/// The first day of a window of `days` days ending today (UTC), as the web's presets start it.
#[must_use]
pub fn window_start(days: u32, now: i64) -> String {
    utc_day(now.saturating_sub(i64::from(days.saturating_sub(1)) * 86_400))
}

fn day_seconds(day: &str) -> Option<i64> {
    let mut parts = day.splitn(3, '-');
    let year = number_in(parts.next()?, &(0_i64..=MAX_DATE_YEAR))?;
    let month = number_in(parts.next()?, &(1_i64..=12))?;
    let day = number_in(parts.next()?, &(1_i64..=31))?;
    Some(days_from_civil(year, month, day) * 86_400)
}

fn shares(totals: BTreeMap<String, f64>) -> Vec<CostShare> {
    let mut shares: Vec<CostShare> = totals
        .into_iter()
        .map(|(name, cost_usd)| CostShare { name, cost_usd })
        .collect();
    shares.sort_by(|left, right| right.cost_usd.total_cmp(&left.cost_usd));
    shares
}

/// `report` within `since..=until` (inclusive `YYYY-MM-DD` UTC days; `None` is open-ended).
#[must_use]
pub fn usage_window(report: &UsageReport, since: Option<&str>, until: Option<&str>) -> UsageWindow {
    let daily_costs: Vec<DailyCost> = report
        .daily_costs
        .iter()
        .filter(|cost| since.is_none_or(|since| cost.day.as_str() >= since))
        .filter(|cost| until.is_none_or(|until| cost.day.as_str() <= until))
        .cloned()
        .collect();
    let from = since.and_then(day_seconds).unwrap_or(i64::MIN);
    let to = until
        .and_then(day_seconds)
        .map_or(i64::MAX, |start| start + 86_399);
    let sessions: Vec<SessionUsage> = report
        .sessions
        .iter()
        .filter(|session| (from..=to).contains(&session.updated_at))
        .cloned()
        .collect();
    let daily_total: f64 = daily_costs.iter().map(|cost| cost.cost_usd).sum();
    let total_cost_usd = if daily_total > 0.0 {
        daily_total
    } else {
        sessions.iter().map(|session| session.cost_usd).sum()
    };
    let mut by_harness = BTreeMap::new();
    let mut by_model = BTreeMap::new();
    for session in &sessions {
        let harness = session.harness.clone().unwrap_or_else(|| "Unknown".into());
        *by_harness.entry(harness).or_insert(0.0) += session.cost_usd;
        for (model, cost) in &session.models {
            *by_model.entry(model.clone()).or_insert(0.0) += cost;
        }
    }
    UsageWindow {
        total_cost_usd,
        daily_costs,
        sessions,
        by_harness: shares(by_harness),
        by_model: shares(by_model),
    }
}

/// `$1.23`, or `<$0.01` for a positive amount under a cent.
#[must_use]
pub fn format_cost_usd(cost_usd: f64) -> String {
    if cost_usd > 0.0 && cost_usd < 0.01 {
        "<$0.01".to_owned()
    } else {
        format!("${cost_usd:.2}")
    }
}

fn number(object: &Map<String, Value>, key: &str) -> Result<f64, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(0.0),
        Some(value) => value
            .as_f64()
            .ok_or_else(|| format!("`{key}` is not a number")),
    }
}

fn seconds(object: &Map<String, Value>, key: &str) -> Result<i64, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(0),
        Some(value) => value
            .as_i64()
            .ok_or_else(|| format!("`{key}` is not an integer")),
    }
}

fn session_from(value: &Value) -> Result<SessionUsage, String> {
    let object = as_object(value, "a session")?;
    let mut models = Vec::new();
    if let Some(map) = opt_object(object, "models")? {
        for (model, cost) in map {
            let cost = cost
                .as_f64()
                .ok_or_else(|| format!("model `{model}` cost is not a number"))?;
            models.push((model.clone(), cost));
        }
    }
    models.sort_by(|left, right| right.1.total_cmp(&left.1));
    Ok(SessionUsage {
        id: req_str(object, "id")?,
        title: opt_str(object, "title")?.filter(|title| !title.is_empty()),
        created_at: seconds(object, "created_at")?,
        updated_at: seconds(object, "updated_at")?,
        cost_usd: number(object, "cost_usd")?,
        models,
        harness: opt_str(object, "harness")?,
    })
}

fn report_from(value: &Value) -> Result<UsageReport, String> {
    let object = as_object(value, "the usage report")?;
    let daily_costs = opt_array(object, "daily_costs")?
        .map(|days| {
            days.iter()
                .map(|day| {
                    let day = as_object(day, "a daily cost")?;
                    Ok(DailyCost {
                        day: req_str(day, "day")?,
                        cost_usd: number(day, "cost_usd")?,
                    })
                })
                .collect::<Result<Vec<_>, String>>()
        })
        .transpose()?
        .unwrap_or_default();
    let sessions = opt_array(object, "sessions")?
        .map(|sessions| sessions.iter().map(session_from).collect::<Result<_, _>>())
        .transpose()?
        .unwrap_or_default();
    Ok(UsageReport {
        daily_costs,
        sessions,
    })
}

impl<T: HttpTransport> ClientCore<T> {
    /// The caller's spend (`GET /v1/usage`).
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn usage_report(&self) -> Result<UsageReport, SessionError> {
        let path = "/v1/usage";
        let result = self.get_json(path, &[]).await;
        self.dispatch();
        report_from(&result?).map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        })
    }
}

#[cfg(test)]
#[path = "usage_tests.rs"]
mod tests;
