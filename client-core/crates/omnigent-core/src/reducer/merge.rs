//! In-place reconciliation of the live reducer with an authoritative snapshot.
//!
//! Ported from `NativeLab`'s `LiveConversationReducer.reconcile(with:)`. Each persisted row retires
//! at most one matching preview; previews that history does not contain yet keep their
//! chronological slot; a history read that finished with an older prefix of text still streaming
//! never replaces the newer text.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use super::live::{LiveReducer, matches_text};
use super::ops::{ChangeSet, diff_rows};
use super::state::{ConversationSnapshot, LIVE_PREFIX, Row, TurnStatus};

impl LiveReducer {
    /// Replaces committed state with `authoritative` (a hydration or reconnect read) while keeping
    /// live previews that history does not contain yet.
    pub fn reconcile(&mut self, authoritative: ConversationSnapshot) -> ChangeSet {
        let checkpoint = self.checkpoint();
        let previous_rows = std::mem::take(&mut self.snap.rows);
        let previous_status = self.snap.header.status;
        let previous_committed: HashSet<&str> = previous_rows
            .iter()
            .filter(|row| !row.id.starts_with(LIVE_PREFIX))
            .map(|row| row.id.as_str())
            .collect();
        let mut previews: Vec<Row> = previous_rows
            .iter()
            .filter(|row| row.is_ephemeral())
            .cloned()
            .collect();
        let mut anchors: BTreeMap<String, String> = BTreeMap::new();
        let mut stale_text: BTreeSet<String> = BTreeSet::new();
        for message in &authoritative.rows {
            let matched = previews.iter().position(|preview| {
                preview.id == message.id
                    || self.matches_activity(preview, message)
                    || (!previous_committed.contains(message.id.as_str())
                        && matches_text(preview, message))
            });
            let Some(at) = matched else { continue };
            let Some(preview) = previews.get(at) else {
                continue;
            };
            // A history read can finish with an older prefix while the stream already advanced.
            if preview.is_streaming
                && preview.activity.is_none()
                && preview.text.chars().count() > message.text.chars().count()
                && preview.text.starts_with(&message.text)
            {
                stale_text.insert(message.id.clone());
                continue;
            }
            let preview = previews.remove(at);
            anchors.insert(preview.id.clone(), message.id.clone());
            self.retire_preview(&preview);
        }
        let mut event_state = self.snap.event_state.clone();
        event_state.merge(&authoritative.event_state);
        self.snap = authoritative;
        self.snap.rows.retain(|row| !stale_text.contains(&row.id));
        self.snap.event_state = event_state;
        self.state_dirty = true;
        let resolved = &self.resolved_decisions;
        self.snap
            .decisions
            .retain(|decision| !resolved.contains(&decision.id));
        if !self.snap.has_pending_decisions()
            && self.snap.header.status == TurnStatus::NeedsResponse
            && previous_status != TurnStatus::NeedsResponse
        {
            self.snap.header.status = previous_status;
        }
        let streaming = previews.iter().any(|preview| preview.is_streaming);
        self.reinsert_previews(&previous_rows, previews, &anchors);
        if streaming && !self.snap.has_pending_decisions() {
            self.snap.header.status = TurnStatus::Running;
        }
        let mut changes = self.finish(&checkpoint);
        changes.rows = diff_rows(&previous_rows, &self.snap.rows);
        changes
    }

    /// Puts each surviving preview back next to the rows it streamed between.
    fn reinsert_previews(
        &mut self,
        previous_rows: &[Row],
        previews: Vec<Row>,
        anchors: &BTreeMap<String, String>,
    ) {
        let committed: HashSet<String> = self.snap.rows.iter().map(|row| row.id.clone()).collect();
        let mut inserted: HashSet<String> = HashSet::new();
        for preview in previews {
            let Some(old) = previous_rows.iter().position(|row| row.id == preview.id) else {
                continue;
            };
            let anchor_of = |row: &Row, also: &HashSet<String>| {
                anchors.get(&row.id).cloned().or_else(|| {
                    (committed.contains(&row.id) || also.contains(&row.id)).then(|| row.id.clone())
                })
            };
            let empty = HashSet::new();
            let next = previous_rows
                .iter()
                .skip(old + 1)
                .find_map(|row| anchor_of(row, &empty))
                .and_then(|anchor| self.snap.rows.iter().position(|row| row.id == anchor));
            let at = next.unwrap_or_else(|| {
                previous_rows
                    .iter()
                    .take(old)
                    .rev()
                    .find_map(|row| anchor_of(row, &inserted))
                    .and_then(|anchor| self.snap.rows.iter().position(|row| row.id == anchor))
                    .map_or(self.snap.rows.len(), |at| at + 1)
            });
            inserted.insert(preview.id.clone());
            self.snap.rows.insert(at.min(self.snap.rows.len()), preview);
        }
    }
}
