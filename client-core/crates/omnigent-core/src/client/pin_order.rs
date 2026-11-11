//! The Pinned section's order (the web's `orderByPinnedTimestamp` and `pinOrderWrites`).
//!
//! Each pin's `omnigent.pinned` label is its sort key: the epoch milliseconds it was pinned, or a
//! value between two neighbours once the user drags it. Ascending, so a new pin lands last.

use std::cmp::Ordering;

use super::sessions::{SessionChange, SessionSummary};
use super::{ClientCore, SessionError, lock};
use crate::http::HttpTransport;

/// The largest integer a JavaScript number holds exactly (`Number.MAX_SAFE_INTEGER`), so the
/// web reads every key written here.
const MAX_SAFE_INTEGER: f64 = 9_007_199_254_740_991.0;

/// A finite pin sort key, written as the label value.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PinStamp(String);

impl PinStamp {
    /// The key for `value`; `None` when it is not finite.
    #[must_use]
    pub fn new(value: f64) -> Option<Self> {
        value.is_finite().then(|| Self(value.to_string()))
    }

    /// The label value.
    #[must_use]
    pub fn label(&self) -> &str {
        &self.0
    }
}

/// The stamp for a computed pin key; a key that isn't finite stops the reorder partway.
fn pin_stamp(key: f64) -> Result<PinStamp, SessionError> {
    PinStamp::new(key).ok_or_else(|| SessionError::DeliveryUncertain {
        detail: format!("pin key {key} is not finite"),
    })
}

/// A session's pin key, `NaN` when unpinned or unreadable (the web's `Number(label)`).
fn key(session: &SessionSummary) -> f64 {
    session
        .pin_stamp
        .as_deref()
        .and_then(|raw| raw.trim().parse::<f64>().ok())
        .unwrap_or(f64::NAN)
}

/// Orders two pinned sessions by key; a missing or unreadable key sorts last.
#[must_use]
pub fn compare(left: &SessionSummary, right: &SessionSummary) -> Ordering {
    let sortable = |value: f64| if value.is_finite() { value } else { f64::MAX };
    sortable(key(left)).total_cmp(&sortable(key(right)))
}

/// One label rewrite: the new sort key of a session.
#[derive(Debug, Clone, PartialEq)]
pub struct PinOrderWrite {
    /// The session.
    pub session_id: String,
    /// Its new key.
    pub key: f64,
}

/// The writes that move `from_id` into `to_id`'s slot of `pinned` (already in pin order).
///
/// An unpinned `from_id` is inserted at that slot. Normally only the moved session is rewritten,
/// to a key between its new neighbours; when there is no room every pin is renumbered from the
/// lowest key (or from just below `now_ms` when that is too large to count up from), skipping
/// sessions already at their new key. Empty for a no-op.
#[must_use]
pub fn pin_order_writes(
    pinned: &[SessionSummary],
    from_id: &str,
    to_id: &str,
    now_ms: u64,
) -> Vec<PinOrderWrite> {
    let from = pinned.iter().position(|session| session.id == from_id);
    let Some(to) = pinned.iter().position(|session| session.id == to_id) else {
        return Vec::new();
    };
    if from == Some(to) {
        return Vec::new();
    }
    let mut moved: Vec<(String, f64)> = pinned
        .iter()
        .map(|session| (session.id.clone(), key(session)))
        .collect();
    let row = from.map_or_else(
        || (from_id.to_owned(), f64::NAN),
        |index| moved.remove(index),
    );
    moved.insert(to, row);
    let last = moved.len() - 1;
    let previous = to
        .checked_sub(1)
        .and_then(|index| moved.get(index))
        .map_or(f64::NAN, |row| row.1);
    let next = moved.get(to + 1).map_or(f64::NAN, |row| row.1);
    let between = if to == 0 {
        next - 1.0
    } else if to == last {
        previous + 1.0
    } else {
        previous + (next - previous) / 2.0
    };
    if between.is_finite() && (to == 0 || between > previous) && (to == last || between < next) {
        return vec![PinOrderWrite {
            session_id: from_id.to_owned(),
            key: between,
        }];
    }
    let lowest = pinned
        .iter()
        .map(key)
        .filter(|value| value.is_finite())
        .reduce(f64::min)
        .unwrap_or(f64::NAN);
    let count = exact_count(moved.len());
    let base = if lowest.abs() + count <= MAX_SAFE_INTEGER {
        lowest
    } else {
        exact(now_ms) - count
    };
    moved
        .into_iter()
        .enumerate()
        .filter_map(|(index, (session_id, current))| {
            let key = base + exact_count(index);
            #[allow(
                clippy::float_cmp,
                reason = "skips a key that is already exactly right"
            )]
            let unchanged = current == key;
            (!unchanged).then_some(PinOrderWrite { session_id, key })
        })
        .collect()
}

/// `value` as a float; list lengths and epoch milliseconds are far below 2^53, so it is exact.
#[allow(
    clippy::as_conversions,
    clippy::cast_precision_loss,
    reason = "list lengths and epoch milliseconds are far below 2^53, so the conversion is exact"
)]
const fn exact(value: u64) -> f64 {
    value as f64
}

/// `count` as a float (see [`exact`]).
fn exact_count(count: usize) -> f64 {
    exact(u64::try_from(count).unwrap_or(u64::MAX))
}

impl<T: HttpTransport> ClientCore<T> {
    /// Moves `session_id` into `target_id`'s slot of the Pinned section, pinning it there when
    /// it is not pinned yet (the web's drag onto a pinned row). The moved session is written
    /// first, so a refused pin changes nothing else.
    ///
    /// # Errors
    ///
    /// [`SessionError::ReadOnly`] without view permission; the write errors. Writes made
    /// before a failure stay.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn move_pin(
        &self,
        session_id: &str,
        target_id: &str,
        now_ms: u64,
    ) -> Result<(), SessionError> {
        let result = self.move_pin_rows(session_id, target_id, now_ms).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn move_pin_rows(
        &self,
        session_id: &str,
        target_id: &str,
        now_ms: u64,
    ) -> Result<(), SessionError> {
        // The order the list shows, edits that have not settled included.
        let mut pinned: Vec<SessionSummary> = {
            let state = lock(&self.state);
            state.shown_rows(state.summaries.values().cloned().collect())
        };
        pinned.retain(|session| session.is_pinned && !session.is_archived);
        pinned.sort_by(compare);
        let mut writes = pin_order_writes(&pinned, session_id, target_id, now_ms);
        if let Some(index) = writes
            .iter()
            .position(|write| write.session_id == session_id)
        {
            let moved = writes.remove(index);
            writes.insert(0, moved);
        }
        // The whole new order shows at once; the writes then leave one after another, and a
        // failure puts back the rows whose writes had not left.
        let edits = writes
            .into_iter()
            .map(|write| {
                Ok((
                    write.session_id,
                    SessionChange::PinnedAt(pin_stamp(write.key)?),
                ))
            })
            .collect::<Result<Vec<_>, SessionError>>()?;
        for planned in self.plan_edits(edits) {
            self.run_edit(planned?).await?;
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "pin_order_tests.rs"]
mod tests;
