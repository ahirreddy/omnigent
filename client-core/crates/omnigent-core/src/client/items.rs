//! Conversation history: `GET /v1/sessions/{id}/items` pages and the conversation page that
//! combines a fresh snapshot with the newest history.
//!
//! History is paged newest first (`order=desc`) by the opaque item-id cursor and returned oldest
//! first, repeated ids dropped. Items stay typed [`ConversationItem`]s: turning them into
//! transcript rows is the reducer's job.

use std::collections::BTreeSet;

use omnigent_protocol::sessions::{ItemPage, SessionSnapshot};
use omnigent_protocol::{ConversationItem, FromWire};

use super::requests::{page_query, validate_identifier};
use super::sessions::{DEFAULT_PAGE_LIMIT, SessionSummary};
use super::{ClientCore, SessionError, lock};
use crate::decisions::Decision;
use crate::http::HttpTransport;

/// One page of history.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryPage {
    /// Items, oldest first, repeated ids dropped.
    pub items: Vec<ConversationItem>,
    /// The `after` cursor for the next (older) page. A page whose items are all hidden still
    /// yields it.
    pub next_cursor: Option<String>,
}

/// A session's metadata plus its newest history.
#[derive(Debug, Clone, PartialEq)]
pub struct ConversationPage {
    /// Increases with every conversation page this core returns.
    pub revision: u64,
    /// The session's summary.
    pub summary: SessionSummary,
    /// The snapshot as read (`include_items=false`, so its own `items` are empty).
    pub snapshot: SessionSnapshot,
    /// The newest history, oldest first.
    pub items: Vec<ConversationItem>,
    /// The cursor for older history.
    pub next_cursor: Option<String>,
    /// Pending decision cards, carried by this session (a card may target a child).
    pub decisions: Vec<Decision>,
}

impl<T: HttpTransport> ClientCore<T> {
    /// One page of history, newest first on the wire and returned oldest first.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`], [`SessionError::InvalidPageLimit`] and
    /// [`SessionError::InvalidPagination`] before any request; the read errors;
    /// [`SessionError::MalformedResponse`] for an item that does not decode (it is never
    /// reported as an empty page); [`SessionError::InvalidPagination`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn history_page(
        &self,
        session_id: &str,
        after: Option<&str>,
        limit: u32,
    ) -> Result<HistoryPage, SessionError> {
        let result = self.history(session_id, after, limit).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn history(
        &self,
        session_id: &str,
        after: Option<&str>,
        limit: u32,
    ) -> Result<HistoryPage, SessionError> {
        validate_identifier(session_id)?;
        let query = page_query(after, limit)?;
        let path = format!("/v1/sessions/{session_id}/items");
        let response = match self.read(self.prepare("GET", &path, &query, None)?).await {
            Err(SessionError::HttpStatus { status: 404 }) => {
                return Err(SessionError::SessionNotFound {
                    session_id: session_id.to_owned(),
                });
            }
            other => other?,
        };
        let page = ItemPage::from_json(&response.body).map_err(|error| {
            SessionError::MalformedResponse {
                detail: format!("{path}: {error}"),
            }
        })?;
        let next_cursor = page
            .next_cursor(after)
            .map_err(|_| SessionError::InvalidPagination)?
            .map(str::to_owned);
        let mut seen = BTreeSet::new();
        let mut items: Vec<ConversationItem> = page
            .data
            .into_iter()
            .filter(|item| seen.insert(item.id.clone()))
            .collect();
        items.reverse();
        Ok(HistoryPage { items, next_cursor })
    }

    /// The conversation's metadata (`include_items=false`) and its newest `limit` items.
    ///
    /// # Errors
    ///
    /// As [`Self::history_page`], plus the snapshot read's errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn conversation_page(
        &self,
        session_id: &str,
        limit: u32,
    ) -> Result<ConversationPage, SessionError> {
        let result = self.conversation(session_id, limit).await;
        self.dispatch();
        result
    }

    /// [`Self::conversation_page`] with the default page size.
    ///
    /// # Errors
    ///
    /// As [`Self::conversation_page`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn conversation_snapshot(
        &self,
        session_id: &str,
    ) -> Result<ConversationPage, SessionError> {
        self.conversation_page(session_id, DEFAULT_PAGE_LIMIT).await
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(crate) async fn conversation(
        &self,
        session_id: &str,
        limit: u32,
    ) -> Result<ConversationPage, SessionError> {
        validate_identifier(session_id)?;
        page_query(None, limit)?;
        let (decoded, epoch) = self.fetch_snapshot(session_id).await?;
        let history = self.history(session_id, None, limit).await?;
        let decisions = decoded
            .snapshot
            .pending_elicitations
            .iter()
            .map(|request| Decision::from_request(request, session_id))
            .collect();
        let mut state = lock(&self.state);
        let summary = state.accept_projection(&decoded.projection, epoch)?;
        state.revision = state.revision.wrapping_add(1);
        Ok(ConversationPage {
            revision: state.revision,
            summary,
            snapshot: decoded.snapshot,
            items: history.items,
            next_cursor: history.next_cursor,
            decisions,
        })
    }
}
