//! The live view of execution logs: each open session's stream events as raw JSON, newest last,
//! as the web's `sseEventLog` keeps them for its execution logs panel.
//!
//! Each session keeps at most [`MAX_EVENTS`] events and [`MAX_BYTES`] of JSON; the oldest go
//! first. A session's log starts empty when its stream is opened anew, so reconnects keep it.

use std::collections::VecDeque;

use serde_json::Value;

use super::{ClientCore, lock};
use crate::http::HttpTransport;

/// Events kept per session, as the web's ring buffer.
pub const MAX_EVENTS: usize = 500;
/// JSON kept per session, so a run of large tool results stays bounded.
pub const MAX_BYTES: usize = 2 * 1024 * 1024;

/// One stream event as it arrived.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamLogEntry {
    /// Its place in the session's log, from 0; it keeps counting as old events drop.
    pub index: u64,
    /// When it arrived, Unix milliseconds.
    pub received_at_ms: u64,
    /// The event on one line.
    pub compact: String,
    /// The event indented two spaces per level.
    pub pretty: String,
}

/// One session's events, oldest first.
#[derive(Debug, Default)]
pub(crate) struct StreamLog {
    entries: VecDeque<(u64, u64, String)>,
    next_index: u64,
    bytes: usize,
}

impl StreamLog {
    fn push(&mut self, event: &Value, received_at_ms: u64) {
        let compact = event.to_string();
        self.bytes += compact.len();
        self.entries
            .push_back((self.next_index, received_at_ms, compact));
        self.next_index += 1;
        while self.entries.len() > MAX_EVENTS || (self.bytes > MAX_BYTES && self.entries.len() > 1)
        {
            if let Some((_, _, dropped)) = self.entries.pop_front() {
                self.bytes -= dropped.len();
            }
        }
    }

    fn entries(&self, after: Option<u64>) -> Vec<StreamLogEntry> {
        self.entries
            .iter()
            .filter(|(index, _, _)| after.is_none_or(|after| *index > after))
            .map(|(index, received_at_ms, compact)| StreamLogEntry {
                index: *index,
                received_at_ms: *received_at_ms,
                pretty: serde_json::from_str::<Value>(compact)
                    .and_then(|value| serde_json::to_string_pretty(&value))
                    .unwrap_or_else(|_| compact.clone()),
                compact: compact.clone(),
            })
            .collect()
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// Keeps `event` from `session_id`'s stream for its execution logs.
    pub fn record_stream_log(&self, session_id: &str, event: &Value, received_at_ms: u64) {
        lock(&self.state)
            .stream_logs
            .entry(session_id.to_owned())
            .or_default()
            .push(event, received_at_ms);
    }

    /// Starts `session_id`'s log afresh, as a new opening of its stream does.
    pub fn clear_stream_log(&self, session_id: &str) {
        lock(&self.state).stream_logs.remove(session_id);
    }

    /// The events kept from `session_id`'s stream, oldest first, those after the `after` index
    /// only; none when it never streamed.
    #[must_use]
    pub fn stream_log(&self, session_id: &str, after: Option<u64>) -> Vec<StreamLogEntry> {
        lock(&self.state)
            .stream_logs
            .get(session_id)
            .map(|log| log.entries(after))
            .unwrap_or_default()
    }
}

#[cfg(test)]
#[path = "stream_log_tests.rs"]
mod tests;
