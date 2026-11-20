//! Execution logs: a session's items as raw JSON, oldest first.

use crate::client::ClientCore;
use crate::errors::CoreError;

/// One item as the server stores it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RawSessionItem {
    /// Its id, when it has one.
    pub id: Option<String>,
    /// The item on one line.
    pub compact: String,
    /// The item indented two spaces per level.
    pub pretty: String,
}

/// One event from a session's stream, as it arrived.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct StreamLogEvent {
    /// Its place in the session's log, from 0.
    pub index: u64,
    /// When it arrived, Unix milliseconds.
    pub received_at_ms: u64,
    /// The event on one line.
    pub compact: String,
    /// The event indented two spaces per level.
    pub pretty: String,
}

/// A page of items.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RawSessionItemsPage {
    /// The items, oldest first.
    pub items: Vec<RawSessionItem>,
    /// Where the next page starts; `None` on the last page.
    pub next: Option<String>,
}

#[uniffi::export]
impl ClientCore {
    /// A page of `session_id`'s items as raw JSON, oldest first, starting after `after`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors and `MalformedResponse`.
    pub async fn raw_session_items(
        &self,
        session_id: String,
        after: Option<String>,
    ) -> Result<RawSessionItemsPage, CoreError> {
        let page = self
            .sessions()
            .raw_session_items(&session_id, after.as_deref())
            .await
            .map_err(CoreError::from)?;
        Ok(RawSessionItemsPage {
            items: page
                .items
                .into_iter()
                .map(|item| RawSessionItem {
                    id: item.id,
                    compact: item.compact,
                    pretty: item.pretty,
                })
                .collect(),
            next: page.next,
        })
    }

    /// The events kept from `session_id`'s open stream, oldest first: the last 500 since it was
    /// opened, those after the `after` index only. Empty for a session whose stream isn't open.
    #[must_use]
    pub fn session_stream_log(
        &self,
        session_id: String,
        after: Option<u64>,
    ) -> Vec<StreamLogEvent> {
        self.sessions()
            .stream_log(&session_id, after)
            .into_iter()
            .map(|entry| StreamLogEvent {
                index: entry.index,
                received_at_ms: entry.received_at_ms,
                compact: entry.compact,
                pretty: entry.pretty,
            })
            .collect()
    }
}
