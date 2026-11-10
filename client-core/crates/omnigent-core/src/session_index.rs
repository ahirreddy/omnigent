//! The session list kept in display order while its sessions change.
//!
//! [`session_query::matching`] filters and sorts every session each time it is asked. A list of
//! hundreds changes one row at a time, so a [`SessionIndex`] holds the sessions, places a changed
//! one by binary search and reports what the change altered. Its order and membership are always
//! what `matching` returns for the same sessions, and its attention is
//! [`SessionAttention::of`] for each of them.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

use crate::client::sessions::SessionSummary;
use crate::session_attention::{AttentionTotals, SessionAttention};
use crate::session_query::{self, SessionFilter};

/// What one change to a [`SessionIndex`] altered.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SessionIndexChange {
    /// The matching sessions' ids in display order, when the order or the membership changed.
    pub visible: Option<Vec<String>>,
    /// The ids of the sessions that need a response, in display order, when that changed.
    pub needs_response: Option<Vec<String>>,
    /// Each session whose attention changed, by id, with its attention now; `None` for a session
    /// that left.
    pub attention: Vec<(String, Option<SessionAttention>)>,
    /// The totals after the change.
    pub totals: AttentionTotals,
}

/// The sessions, the ones matching a search and filter in display order, the ones needing a
/// response in display order, and each one's attention.
#[derive(Debug, Default)]
pub struct SessionIndex {
    sessions: HashMap<String, SessionSummary>,
    unread: HashSet<String>,
    /// The search text, trimmed and folded.
    query: String,
    filter: SessionFilter,
    visible: Vec<String>,
    needs_response: Vec<String>,
    attention: HashMap<String, SessionAttention>,
}

impl SessionIndex {
    /// An empty index showing every session that is not archived.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// The matching sessions' ids, in display order.
    #[must_use]
    pub fn visible(&self) -> &[String] {
        &self.visible
    }

    /// The ids of the sessions that need a response, in display order.
    #[must_use]
    pub fn needs_response(&self) -> &[String] {
        &self.needs_response
    }

    /// Replaces every session and the unread ids.
    pub fn reset(
        &mut self,
        sessions: Vec<SessionSummary>,
        unread: HashSet<String>,
    ) -> SessionIndexChange {
        let visible = std::mem::take(&mut self.visible);
        let needs_response = std::mem::take(&mut self.needs_response);
        let attention = std::mem::take(&mut self.attention);
        self.sessions = sessions
            .into_iter()
            .map(|session| (session.id.clone(), session))
            .collect();
        self.unread = unread;
        self.attention = self
            .sessions
            .iter()
            .map(|(id, session)| {
                let attention = SessionAttention::of(session, self.unread.contains(id));
                (id.clone(), attention)
            })
            .collect();
        self.visible = self.matching();
        self.needs_response =
            self.ordered(|session| SessionFilter::NeedsResponse.includes(session));
        // A session in both keeps the attention it had; one that only arrived had none.
        let before = self
            .attention
            .keys()
            .map(|id| (id.clone(), None))
            .chain(attention.into_iter().map(|(id, was)| (id, Some(was))))
            .collect();
        SessionIndexChange {
            visible: (self.visible != visible).then(|| self.visible.clone()),
            needs_response: (self.needs_response != needs_response)
                .then(|| self.needs_response.clone()),
            attention: self.attention_changes(before),
            totals: self.totals(),
        }
    }

    /// Adds or replaces `upserted`, then drops the sessions of `removed`. Each session is placed
    /// by binary search, so the cost follows the sessions changed, not the sessions held.
    pub fn update(
        &mut self,
        upserted: Vec<SessionSummary>,
        removed: &[String],
    ) -> SessionIndexChange {
        let mut visible_moved = false;
        let mut needs_response_moved = false;
        let mut before: HashMap<String, Option<SessionAttention>> = HashMap::new();
        for session in upserted {
            let shown = session_query::matches(&session, &self.query, self.filter);
            let needs = SessionFilter::NeedsResponse.includes(&session);
            visible_moved |= place(&mut self.visible, &self.sessions, &session, shown);
            needs_response_moved |=
                place(&mut self.needs_response, &self.sessions, &session, needs);
            let attention = SessionAttention::of(&session, self.unread.contains(&session.id));
            let previous = self.attention.insert(session.id.clone(), attention);
            before.entry(session.id.clone()).or_insert(previous);
            self.sessions.insert(session.id.clone(), session);
        }
        for id in removed {
            if self.sessions.remove(id).is_none() {
                continue;
            }
            visible_moved |= take(&mut self.visible, id).is_some();
            needs_response_moved |= take(&mut self.needs_response, id).is_some();
            let previous = self.attention.remove(id);
            before.entry(id.clone()).or_insert(previous);
        }
        SessionIndexChange {
            visible: visible_moved.then(|| self.visible.clone()),
            needs_response: needs_response_moved.then(|| self.needs_response.clone()),
            attention: self.attention_changes(before),
            totals: self.totals(),
        }
    }

    /// Replaces the unread ids. Read state changes attention, never the order.
    pub fn set_unread(&mut self, unread: HashSet<String>) -> SessionIndexChange {
        let flipped: Vec<String> = self.unread.symmetric_difference(&unread).cloned().collect();
        self.unread = unread;
        let mut before = HashMap::new();
        for id in flipped {
            let Some(session) = self.sessions.get(&id) else {
                continue;
            };
            let attention = SessionAttention::of(session, self.unread.contains(&id));
            let previous = self.attention.insert(id.clone(), attention);
            before.insert(id, previous);
        }
        SessionIndexChange {
            visible: None,
            needs_response: None,
            attention: self.attention_changes(before),
            totals: self.totals(),
        }
    }

    /// Searches for `text` among the sessions `filter` includes.
    pub fn set_query(&mut self, text: &str, filter: SessionFilter) -> SessionIndexChange {
        self.query = session_query::fold(text.trim());
        self.filter = filter;
        let visible = self.matching();
        let changed = visible != self.visible;
        self.visible = visible;
        SessionIndexChange {
            visible: changed.then(|| self.visible.clone()),
            needs_response: None,
            attention: Vec::new(),
            totals: self.totals(),
        }
    }

    fn matching(&self) -> Vec<String> {
        self.ordered(|session| session_query::matches(session, &self.query, self.filter))
    }

    /// The ids of the sessions `belongs` accepts, in display order.
    fn ordered(&self, belongs: impl Fn(&SessionSummary) -> bool) -> Vec<String> {
        let mut sessions: Vec<&SessionSummary> = self
            .sessions
            .values()
            .filter(|session| belongs(session))
            .collect();
        sessions.sort_by(|left, right| session_query::order(left, right));
        sessions
            .into_iter()
            .map(|session| session.id.clone())
            .collect()
    }

    /// The sessions of `before` whose attention is no longer what `before` holds, by id.
    fn attention_changes(
        &self,
        before: HashMap<String, Option<SessionAttention>>,
    ) -> Vec<(String, Option<SessionAttention>)> {
        let mut changes: Vec<(String, Option<SessionAttention>)> = before
            .into_iter()
            .filter_map(|(id, previous)| {
                let current = self.attention.get(&id).copied();
                (current != previous).then_some((id, current))
            })
            .collect();
        changes.sort_by(|left, right| left.0.cmp(&right.0));
        changes
    }

    /// Counted over every session: a pass with no allocation, exactly [`AttentionTotals::of`].
    fn totals(&self) -> AttentionTotals {
        AttentionTotals::of(self.sessions.values(), |id| self.unread.contains(id))
    }
}

/// Removes `id` from `order` and returns where it was.
fn take(order: &mut Vec<String>, id: &str) -> Option<usize> {
    let index = order.iter().position(|other| other == id)?;
    order.remove(index);
    Some(index)
}

/// Puts `session` where it sorts among `order`, or takes it out when it does not belong. The
/// other ids of `order` are in `sessions`; `session`'s own entry there may be its old row.
/// Returns whether `order` changed.
fn place(
    order: &mut Vec<String>,
    sessions: &HashMap<String, SessionSummary>,
    session: &SessionSummary,
    belongs: bool,
) -> bool {
    let old = take(order, &session.id);
    if !belongs {
        return old.is_some();
    }
    let new = order.partition_point(|id| {
        sessions
            .get(id)
            .is_some_and(|other| session_query::order(other, session) == Ordering::Less)
    });
    order.insert(new, session.id.clone());
    old != Some(new)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::sessions::SummaryStatus;
    use crate::session_attention::AttentionState;

    fn session(id: &str, updated_at: i64) -> SessionSummary {
        SessionSummary {
            updated_at,
            ..SessionSummary::new(id, id, "")
        }
    }

    fn ids(sessions: &[SessionSummary]) -> Vec<String> {
        sessions.iter().map(|session| session.id.clone()).collect()
    }

    fn unread(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|id| (*id).to_owned()).collect()
    }

    /// The index agrees with a filter, sort and count of `sessions` from scratch.
    fn assert_agrees(
        index: &SessionIndex,
        sessions: &HashMap<String, SessionSummary>,
        read: &HashSet<String>,
        text: &str,
        filter: SessionFilter,
    ) {
        let all: Vec<SessionSummary> = sessions.values().cloned().collect();
        assert_eq!(
            index.visible(),
            ids(&session_query::matching(&all, text, filter))
        );
        assert_eq!(
            index.needs_response(),
            ids(&session_query::matching(
                &all,
                "",
                SessionFilter::NeedsResponse
            ))
        );
        assert_eq!(
            index.totals(),
            AttentionTotals::of(&all, |id| read.contains(id))
        );
        for (id, session) in sessions {
            assert_eq!(
                index.attention.get(id),
                Some(&SessionAttention::of(session, read.contains(id)))
            );
        }
        assert_eq!(index.attention.len(), sessions.len());
    }

    /// The next of a fixed pseudo-random sequence, so the walk below is the same every run.
    fn next(seed: &mut u64) -> usize {
        *seed = seed
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        usize::try_from(*seed >> 40).unwrap()
    }

    fn varied(id: &str, seed: &mut u64) -> SessionSummary {
        let roll = next(seed);
        SessionSummary {
            status: [
                SummaryStatus::Idle,
                SummaryStatus::Running,
                SummaryStatus::NeedsResponse,
            ][roll % 3],
            pending_requests: u32::from(roll.is_multiple_of(5)),
            is_pinned: roll.is_multiple_of(7),
            pin_stamp: roll.is_multiple_of(7).then(|| format!("{:04}", roll % 11)),
            is_archived: roll.is_multiple_of(6),
            failure_message: roll.is_multiple_of(13).then(|| "failed".to_owned()),
            updated_at: i64::try_from(roll % 9).unwrap(),
            ..SessionSummary::new(
                id,
                ["Café notes", "Build", "Review"][roll % 3],
                ["keyboard", "", "tests"][(roll / 3) % 3],
            )
        }
    }

    #[test]
    fn every_change_leaves_what_a_filter_from_scratch_gives() {
        let queries = [
            ("", SessionFilter::All),
            (" cafe ", SessionFilter::All),
            ("", SessionFilter::Running),
            ("build", SessionFilter::NeedsResponse),
            ("", SessionFilter::Archived),
        ];
        let mut seed = 7;
        let mut index = SessionIndex::new();
        let mut sessions: HashMap<String, SessionSummary> = HashMap::new();
        let mut read: HashSet<String> = HashSet::new();
        let (mut text, mut filter) = queries[0];
        for step in 0..600 {
            let id = format!("s{}", next(&mut seed) % 24);
            match next(&mut seed) % 10 {
                0 => {
                    sessions.remove(&id);
                    index.update(Vec::new(), std::slice::from_ref(&id));
                }
                1 => {
                    if !read.remove(&id) {
                        read.insert(id);
                    }
                    index.set_unread(read.clone());
                }
                2 => {
                    (text, filter) = queries[next(&mut seed) % queries.len()];
                    index.set_query(text, filter);
                }
                3 if step % 50 == 3 => {
                    let kept: Vec<SessionSummary> = sessions.values().take(5).cloned().collect();
                    sessions = kept
                        .iter()
                        .map(|session| (session.id.clone(), session.clone()))
                        .collect();
                    index.reset(kept, read.clone());
                }
                _ => {
                    let other = format!("s{}", next(&mut seed) % 24);
                    let batch = vec![varied(&id, &mut seed), varied(&other, &mut seed)];
                    for session in &batch {
                        sessions.insert(session.id.clone(), session.clone());
                    }
                    index.update(batch, &[]);
                }
            }
            assert_agrees(&index, &sessions, &read, text, filter);
        }
    }

    #[test]
    fn a_change_that_keeps_a_row_in_place_reports_no_order() {
        let mut index = SessionIndex::new();
        let first = index.reset(
            vec![session("a", 3), session("b", 2), session("c", 1)],
            HashSet::new(),
        );
        assert_eq!(
            first.visible,
            Some(vec!["a".to_owned(), "b".to_owned(), "c".to_owned()])
        );
        assert_eq!(first.needs_response, None);
        assert_eq!(first.attention.len(), 3);

        // A new preview, and a time that still sorts between its neighbours.
        let preview = SessionSummary {
            preview: "Reading the file".into(),
            ..session("b", 2)
        };
        let quiet = index.update(vec![preview, session("a", 5)], &[]);
        assert_eq!(quiet, SessionIndexChange::default());

        let moved = index.update(vec![session("c", 9)], &[]);
        assert_eq!(
            moved.visible,
            Some(vec!["c".to_owned(), "a".to_owned(), "b".to_owned()])
        );
        assert_eq!(moved.attention, []);
    }

    #[test]
    fn attention_is_reported_for_the_sessions_it_changed() {
        let mut index = SessionIndex::new();
        index.reset(vec![session("a", 2), session("b", 1)], HashSet::new());

        let running = SessionSummary {
            status: SummaryStatus::Running,
            ..session("a", 2)
        };
        let change = index.update(vec![running], &[]);
        let working = SessionAttention {
            state: AttentionState::Working,
            requests: 0,
        };
        assert_eq!(change.attention, [("a".to_owned(), Some(working))]);
        assert_eq!(change.visible, None);
        assert_eq!(change.totals.working, 1);

        // A working session stays working when it is unread; an idle one becomes unread, and an
        // id the index does not hold is ignored.
        let change = index.set_unread(unread(&["a", "b", "elsewhere"]));
        let unseen = SessionAttention {
            state: AttentionState::Unread,
            requests: 0,
        };
        assert_eq!(change.attention, [("b".to_owned(), Some(unseen))]);
        assert_eq!(change.totals.unread, 1);
        let change = index.set_unread(HashSet::new());
        assert_eq!(change.attention.len(), 1);
        assert_eq!(change.totals.unread, 0);

        let waiting = SessionSummary {
            status: SummaryStatus::NeedsResponse,
            pending_requests: 2,
            ..session("b", 1)
        };
        let change = index.update(vec![waiting], &[]);
        assert_eq!(change.needs_response, Some(vec!["b".to_owned()]));
        assert_eq!(change.totals.requests, 2);

        let change = index.update(Vec::new(), &["b".to_owned(), "unknown".to_owned()]);
        assert_eq!(change.attention, [("b".to_owned(), None)]);
        assert_eq!(change.visible, Some(vec!["a".to_owned()]));
        assert_eq!(change.needs_response, Some(Vec::new()));
        assert_eq!(change.totals.sessions_needing_you, 0);
    }

    #[test]
    fn a_search_reports_the_rows_that_leave_and_arrive() {
        let mut index = SessionIndex::new();
        let titled = |id: &str, title: &str| SessionSummary {
            title: title.into(),
            ..session(id, 1)
        };
        index.reset(
            vec![titled("a", "Café design"), titled("b", "Build")],
            HashSet::new(),
        );
        let change = index.set_query(" cafe ", SessionFilter::All);
        assert_eq!(change.visible, Some(vec!["a".to_owned()]));
        assert_eq!(index.set_query("CAFE", SessionFilter::All).visible, None);

        // A row that stops matching leaves; one that starts matching arrives.
        let change = index.update(vec![titled("a", "Design"), titled("b", "Cafe")], &[]);
        assert_eq!(change.visible, Some(vec!["b".to_owned()]));
        let change = index.reset(vec![titled("b", "Cafe")], HashSet::new());
        assert_eq!(change.visible, None);
        assert_eq!(change.attention, [("a".to_owned(), None)]);
    }
}
