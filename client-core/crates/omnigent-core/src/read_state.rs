//! Which sessions have activity the caller has not seen, and the `mark seen` write.
//!
//! The server keeps a per-viewer read state: list and update rows carry `viewer_last_seen` (Unix
//! seconds, `null` when never seen) and `viewer_unread` (an explicit "marked unread"), and
//! `PUT /v1/sessions/{id}/read-state` with `{last_seen, unread}` sets it (`204`). The rules match
//! the web's `useUnseenConversations`:
//! - A session is **unseen** when it is not running and its `updated_at` is past the baseline:
//!   the newest of the server's `viewer_last_seen`, this device's own marks, and, when neither
//!   exists, the `updated_at` it had when this device first saw it ("read as of first sight", so
//!   a server that lost its state never lights up every row).
//! - It is **unread** when unseen or explicitly marked unread.
//! - **Mark seen** applies to an unread session and sets the baseline to the later of now and
//!   `updated_at`. While the user only keeps looking ([`SeenReason::Viewing`]) an explicit unread
//!   stays; opening the session ([`SeenReason::Opened`]) clears it.
//!
//! The write is [`crate::ClientCore::put_read_state`].
//!
//! **The server is authoritative.** Its baseline always counts, and its explicit flag wins once
//! this device's last mark is settled: the server reported it back, or the write succeeded
//! ([`ReadState::mark_written`]) and a later row arrived. Until then (the write is in flight,
//! failed, or the row came from before it) the mark stands. Device-local marks are only a
//! fallback, kept in memory for the connection: for a server that reports no read state (older
//! servers, which also get no write), and for a server that lost its in-memory state. After a
//! relaunch the server's state, or first sight, applies again.

use std::collections::{BTreeMap, BTreeSet};

use crate::client::sessions::{SessionSummary, SummaryStatus};

/// Why a session is being marked seen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeenReason {
    /// The user opened it: reading it clears an explicit unread.
    Opened,
    /// It stays open and focused while it changes, or focus returned to it: an explicit unread
    /// stays.
    Viewing,
}

/// The `PUT /v1/sessions/{id}/read-state` body for one session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadMark {
    /// The session.
    pub session_id: String,
    /// The new baseline, Unix seconds.
    pub last_seen: i64,
    /// The explicit unread flag to store.
    pub unread: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Pending {
    last_seen: i64,
    written: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Entry {
    updated_at: i64,
    running: bool,
    /// The server's report, when a row carried one.
    server_last_seen: Option<i64>,
    server_unread: bool,
    /// This device's newest mark.
    local_mark: Option<i64>,
    /// The last mark until the server settles it.
    pending: Option<Pending>,
    /// `updated_at` at first sight, when no baseline existed anywhere.
    first_sight: Option<i64>,
}

impl Entry {
    fn baseline(&self) -> Option<i64> {
        [self.server_last_seen, self.local_mark, self.first_sight]
            .into_iter()
            .flatten()
            .max()
    }

    /// The server's explicit unread, unless this device's mark is not settled yet.
    const fn explicitly_unread(&self) -> bool {
        self.server_unread && self.pending.is_none()
    }

    fn is_unread(&self) -> bool {
        self.explicitly_unread()
            || (!self.running && self.baseline().is_some_and(|seen| self.updated_at > seen))
    }
}

/// The read state of every known session on one connection.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReadState {
    sessions: BTreeMap<String, Entry>,
    server_tracks_reads: bool,
}

impl ReadState {
    /// An empty state.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Records the latest summary of a session.
    pub fn observe(&mut self, summary: &SessionSummary) {
        let entry = self.sessions.entry(summary.id.clone()).or_default();
        entry.updated_at = summary.updated_at;
        entry.running = summary.status == SummaryStatus::Running;
        if let Some(read) = summary.viewer_read {
            self.server_tracks_reads = true;
            entry.server_last_seen = read.last_seen;
            entry.server_unread = read.unread;
            let settled = entry.pending.is_some_and(|pending| {
                pending.written || (read.last_seen == Some(pending.last_seen) && !read.unread)
            });
            if settled {
                entry.pending = None;
            }
        }
        if entry.baseline().is_none() {
            entry.first_sight = Some(summary.updated_at);
        }
    }

    /// Forgets sessions that were deleted or lost access.
    pub fn remove(&mut self, ids: &[String]) {
        for id in ids {
            self.sessions.remove(id);
        }
    }

    /// Forgets everything (sign-out or another server).
    pub fn clear(&mut self) {
        *self = Self::default();
    }

    /// Whether any row reported the server's read state, so marks should be written to it.
    #[must_use]
    pub const fn server_tracks_reads(&self) -> bool {
        self.server_tracks_reads
    }

    /// Whether `session_id` has activity the caller has not seen (false for an unknown session).
    #[must_use]
    pub fn is_unread(&self, session_id: &str) -> bool {
        self.sessions.get(session_id).is_some_and(Entry::is_unread)
    }

    /// Every unread session.
    #[must_use]
    pub fn unread_ids(&self) -> BTreeSet<String> {
        self.sessions
            .iter()
            .filter(|(_, entry)| entry.is_unread())
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// The server accepted `mark`: the next row it reports for the session is authoritative.
    pub fn mark_written(&mut self, mark: &ReadMark) {
        if let Some(pending) = self
            .sessions
            .get_mut(&mark.session_id)
            .and_then(|entry| entry.pending.as_mut())
            .filter(|pending| pending.last_seen == mark.last_seen)
        {
            pending.written = true;
        }
    }

    /// Marks `session_id` seen at `now_seconds` and returns the write to send, or `None` when
    /// nothing changes: it is not unread, or it is explicitly unread and only being viewed.
    pub fn mark_seen(
        &mut self,
        session_id: &str,
        now_seconds: i64,
        reason: SeenReason,
    ) -> Option<ReadMark> {
        let entry = self.sessions.entry(session_id.to_owned()).or_default();
        let explicit = entry.explicitly_unread();
        if explicit && reason == SeenReason::Viewing {
            return None;
        }
        // Only unread activity needs a write; a running session is marked when its turn ends.
        if !entry.is_unread() {
            return None;
        }
        let target = now_seconds.max(entry.updated_at);
        // Never lower a baseline another device set later.
        let last_seen = entry
            .server_last_seen
            .map_or(target, |seen| seen.max(target));
        entry.local_mark = Some(
            entry
                .local_mark
                .map_or(last_seen, |mark| mark.max(last_seen)),
        );
        entry.pending = Some(Pending {
            last_seen,
            written: false,
        });
        Some(ReadMark {
            session_id: session_id.to_owned(),
            last_seen,
            unread: false,
        })
    }
}

#[cfg(test)]
mod tests;
