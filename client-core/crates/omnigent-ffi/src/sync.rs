//! `ConversationSync` as an object.
//!
//! It holds the live reducer of one watched conversation and the history-vs-live handoff around
//! it (`omnigent_core::reconcile`). [`crate::client::ClientCore`]
//! drives one per open session; hosts and tests may also drive one directly with JSON.
//!
//! [`HydrationRequest`], [`ConfigurationRead`] and [`ListRead`] are opaque tokens: pass them back
//! unchanged.

use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use omnigent_core::reconcile as core;
use omnigent_core::reducer::{self, ChangeSet};
use omnigent_protocol::{ConversationItem, FromWire, SessionListItem, SessionSnapshot};
use serde_json::Value;

use crate::decisions::DecisionCard;
use crate::errors::{CoreError, core_error};
use crate::transcript::{EventSection, Row, SessionHeader, TranscriptChange};

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn decode_error(context: &str, error: &impl fmt::Display) -> CoreError {
    CoreError::Decode {
        message: format!("{context}: {error}"),
    }
}

/// A history read to perform: `GET /v1/sessions/{id}?include_items=false` plus the newest
/// `/items` page, then [`ConversationSync::finish_hydration`] with this token.
#[derive(uniffi::Object)]
pub struct HydrationRequest {
    pub(crate) inner: core::HydrationRequest,
}

impl fmt::Debug for HydrationRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HydrationRequest")
            .field("session_id", &self.inner.session_id)
            .finish_non_exhaustive()
    }
}

#[uniffi::export]
impl HydrationRequest {
    /// The session to read.
    pub fn session_id(&self) -> String {
        self.inner.session_id.clone()
    }
}

/// A configuration read in flight.
#[derive(uniffi::Object)]
pub struct ConfigurationRead {
    inner: core::ConfigurationRead,
}

impl fmt::Debug for ConfigurationRead {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConfigurationRead")
            .field("session_id", &self.inner.session_id)
            .finish_non_exhaustive()
    }
}

/// A session-list read in flight.
#[derive(uniffi::Object)]
pub struct ListRead {
    inner: core::ListRead,
}

impl fmt::Debug for ListRead {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ListRead")
    }
}

/// Host effects of an applied event.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncEffects {
    /// The conversation changed.
    pub changed: bool,
    /// Authoritative state should be re-read.
    pub reconcile: bool,
    /// `session.input.consumed`: the persisted item id.
    pub consumed_item_id: Option<String>,
    /// `session.input.consumed`: the cleared pending id.
    pub consumed_pending_id: Option<String>,
    /// A readable failure to surface.
    pub error: Option<String>,
    /// Refetch changed files for this environment.
    pub changed_files_environment: Option<String>,
    /// An agent browser action to claim and run (once per action id).
    #[uniffi(default)]
    pub browser_action: Option<crate::browser::BrowserActionRequest>,
}

/// What one sync input changed and asks for.
#[derive(Debug, uniffi::Record)]
pub struct SyncUpdate {
    /// Transcript changes, when any.
    pub change: Option<TranscriptChange>,
    /// The new decision cards, when they changed.
    pub decisions: Option<Vec<DecisionCard>>,
    /// Host effects.
    pub effects: SyncEffects,
    /// A history read to start.
    pub hydrate: Option<Arc<HydrationRequest>>,
    /// Headers learned from a list read or frame, in row order.
    pub headers: Vec<SessionHeader>,
    /// The conversation's revision after this update.
    pub revision: u64,
}

/// What the engine needs from one update: the FFI parts plus the raw hydration token.
pub(crate) struct Applied {
    pub(crate) change: Option<TranscriptChange>,
    pub(crate) decisions: Option<Vec<DecisionCard>>,
    pub(crate) effects: reducer::Effects,
    pub(crate) hydrate: Option<core::HydrationRequest>,
    pub(crate) revision: u64,
}

pub(crate) fn decisions_of(changes: &ChangeSet, session_id: &str) -> Option<Vec<DecisionCard>> {
    changes.decisions.as_ref().map(|decisions| {
        decisions
            .iter()
            .map(|decision| DecisionCard::from_reducer(decision, session_id))
            .collect()
    })
}

impl Applied {
    fn new(update: core::SyncUpdate, session_id: &str) -> Self {
        Self {
            change: TranscriptChange::from_changes(&update.changes),
            decisions: decisions_of(&update.changes, session_id),
            effects: update.effects,
            hydrate: update.hydrate,
            revision: update.revision,
        }
    }
}

impl SyncUpdate {
    fn new(update: core::SyncUpdate, session_id: &str) -> Self {
        let headers = update.headers.clone().into_iter().map(Into::into).collect();
        let applied = Applied::new(update, session_id);
        Self {
            change: applied.change,
            decisions: applied.decisions,
            effects: SyncEffects {
                changed: applied.effects.changed,
                reconcile: applied.effects.reconcile,
                consumed_item_id: applied.effects.consumed_item_id,
                consumed_pending_id: applied.effects.consumed_pending_id,
                error: applied.effects.error,
                changed_files_environment: applied.effects.changed_files_environment,
                browser_action: applied.effects.browser_action.map(Into::into),
            },
            hydrate: applied
                .hydrate
                .map(|inner| Arc::new(HydrationRequest { inner })),
            headers,
            revision: applied.revision,
        }
    }
}

/// The live state of one watched conversation.
#[derive(uniffi::Object)]
pub struct ConversationSync {
    session_id: String,
    inner: Mutex<core::ConversationSync>,
}

impl fmt::Debug for ConversationSync {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationSync")
            .field("session_id", &self.session_id)
            .finish_non_exhaustive()
    }
}

fn decode_items(items_json: &str) -> Result<Vec<ConversationItem>, CoreError> {
    let value: Value =
        serde_json::from_str(items_json).map_err(|error| decode_error("items", &error))?;
    let Value::Array(items) = value else {
        return Err(CoreError::Decode {
            message: "items: not a JSON array".to_owned(),
        });
    };
    items
        .into_iter()
        .map(|item| {
            ConversationItem::from_value(item).map_err(|error| decode_error("item", &error))
        })
        .collect()
}

fn decode_rows(rows_json: &str) -> Result<Vec<SessionListItem>, CoreError> {
    let value: Value =
        serde_json::from_str(rows_json).map_err(|error| decode_error("session rows", &error))?;
    let Value::Array(rows) = value else {
        return Err(CoreError::Decode {
            message: "session rows: not a JSON array".to_owned(),
        });
    };
    rows.into_iter()
        .map(|row| {
            SessionListItem::from_value(row).map_err(|error| decode_error("session row", &error))
        })
        .collect()
}

impl ConversationSync {
    pub(crate) fn create(session_id: &str) -> Arc<Self> {
        Arc::new(Self {
            session_id: session_id.to_owned(),
            inner: Mutex::new(core::ConversationSync::new(session_id)),
        })
    }

    pub(crate) fn open_stream_raw(&self) -> core::HydrationRequest {
        lock(&self.inner).open_stream()
    }

    pub(crate) fn request_hydration_raw(&self) -> Option<core::HydrationRequest> {
        lock(&self.inner).request_hydration()
    }

    pub(crate) fn hydration_failed_raw(&self, request: &core::HydrationRequest) -> bool {
        lock(&self.inner).hydration_failed(request)
    }

    pub(crate) fn handle_event_raw(&self, value: Value) -> Result<Applied, core::SyncError> {
        let update = lock(&self.inner).handle_event(value)?;
        Ok(Applied::new(update, &self.session_id))
    }

    pub(crate) fn close_stream_raw(&self) {
        lock(&self.inner).close_stream();
    }

    pub(crate) fn stop_raw(&self) {
        lock(&self.inner).stop();
    }

    pub(crate) fn handle_removed_raw(&self, ids: &[String]) -> bool {
        lock(&self.inner).handle_removed(ids)
    }

    pub(crate) fn finish_hydration_raw(
        &self,
        request: &core::HydrationRequest,
        session: &SessionSnapshot,
        items: &[ConversationItem],
    ) -> Result<Applied, CoreError> {
        let update = lock(&self.inner)
            .finish_hydration(request, session, items)
            .map_err(core_error)?;
        Ok(Applied::new(update, &self.session_id))
    }

    pub(crate) fn handle_list_rows_raw(
        &self,
        rows: &[SessionListItem],
    ) -> Result<Applied, CoreError> {
        let update = lock(&self.inner)
            .handle_list_rows(rows)
            .map_err(|error| core_error(core::SyncError::from(error)))?;
        Ok(Applied::new(update, &self.session_id))
    }

    /// Whether the runner reported that it is creating the session's terminal pane.
    pub(crate) fn terminal_pending_raw(&self) -> bool {
        lock(&self.inner)
            .published()
            .and_then(|snapshot| snapshot.event_state.terminal_pending)
            .unwrap_or(false)
    }

    pub(crate) fn set_changed_files_raw(
        &self,
        environment: &str,
        files: reducer::ChangedFiles,
    ) -> Applied {
        let update = lock(&self.inner).set_changed_files(environment, files);
        Applied::new(update, &self.session_id)
    }
}

#[uniffi::export]
impl ConversationSync {
    /// Starts watching `session_id` (no stream yet).
    #[uniffi::constructor]
    pub fn new(session_id: String) -> Arc<Self> {
        Self::create(&session_id)
    }

    /// The watched session.
    pub fn session_id(&self) -> String {
        self.session_id.clone()
    }

    /// The stream (re)connected: a fresh reducer, and a history read to perform.
    pub fn open_stream(&self) -> Arc<HydrationRequest> {
        Arc::new(HydrationRequest {
            inner: self.open_stream_raw(),
        })
    }

    /// The stream ended or failed; the in-flight history read is abandoned.
    pub fn close_stream(&self) {
        lock(&self.inner).close_stream();
    }

    /// Stops watching; later inputs for this generation are dropped.
    pub fn stop(&self) {
        lock(&self.inner).stop();
    }

    /// Asks for a history read; `None` while one is in flight (it is queued instead).
    pub fn request_hydration(&self) -> Option<Arc<HydrationRequest>> {
        self.request_hydration_raw()
            .map(|inner| Arc::new(HydrationRequest { inner }))
    }

    /// The read for `request` failed. Returns whether it was current; reconnect the stream if so.
    pub fn hydration_failed(&self, request: Arc<HydrationRequest>) -> bool {
        self.hydration_failed_raw(&request.inner)
    }

    /// Applies one stream event payload (the SSE `data:` JSON).
    ///
    /// # Errors
    ///
    /// [`CoreError::Decode`] for text that is not JSON, [`CoreError::Sync`] when the event does
    /// not decode or apply. Nothing changes on error.
    pub fn handle_event(&self, json: String) -> Result<SyncUpdate, CoreError> {
        let value: Value =
            serde_json::from_str(&json).map_err(|error| decode_error("event", &error))?;
        let update = lock(&self.inner).handle_event(value).map_err(core_error)?;
        Ok(SyncUpdate::new(update, &self.session_id))
    }

    /// The history read for `request` finished: the session snapshot JSON and its items as a
    /// JSON array, oldest first.
    ///
    /// # Errors
    ///
    /// [`CoreError::Decode`] for undecodable JSON, [`CoreError::Sync`] when the read cannot be
    /// shown. The sync is unchanged; call [`Self::hydration_failed`] and reconnect.
    pub fn finish_hydration(
        &self,
        request: Arc<HydrationRequest>,
        session_json: String,
        items_json: String,
    ) -> Result<SyncUpdate, CoreError> {
        let session = SessionSnapshot::from_json(session_json.as_bytes())
            .map_err(|error| decode_error("session", &error))?;
        let items = decode_items(&items_json)?;
        let update = lock(&self.inner)
            .finish_hydration(&request.inner, &session, &items)
            .map_err(core_error)?;
        Ok(SyncUpdate::new(update, &self.session_id))
    }

    /// Starts a configuration read of `session_id`.
    pub fn begin_configuration_read(&self, session_id: String) -> Arc<ConfigurationRead> {
        Arc::new(ConfigurationRead {
            inner: lock(&self.inner).begin_configuration_read(&session_id),
        })
    }

    /// Accepts a configuration read (session snapshot JSON) unless the configuration changed
    /// while it was in flight.
    ///
    /// # Errors
    ///
    /// [`CoreError::ConfigurationRead`] when it changed elsewhere, the stream restarted or the
    /// session differs; [`CoreError::Decode`] for undecodable JSON.
    pub fn finish_configuration_read(
        &self,
        read: Arc<ConfigurationRead>,
        session_json: String,
    ) -> Result<SyncUpdate, CoreError> {
        let session = SessionSnapshot::from_json(session_json.as_bytes())
            .map_err(|error| decode_error("session", &error))?;
        let (_, update) = lock(&self.inner)
            .finish_configuration_read(&read.inner, &session)
            .map_err(core_error)?;
        Ok(SyncUpdate::new(update, &self.session_id))
    }

    /// Starts a session-list read.
    pub fn begin_list_read(&self) -> Arc<ListRead> {
        Arc::new(ListRead {
            inner: lock(&self.inner).begin_list_read(),
        })
    }

    /// The rows (JSON array of list items) of a finished list read.
    ///
    /// # Errors
    ///
    /// [`CoreError::Decode`] for undecodable rows, [`CoreError::Sync`] for an unknown status.
    pub fn finish_list_read(
        &self,
        read: Arc<ListRead>,
        rows_json: String,
    ) -> Result<SyncUpdate, CoreError> {
        let rows = decode_rows(&rows_json)?;
        let update = lock(&self.inner)
            .finish_list_read(&read.inner, &rows)
            .map_err(|error| core_error(core::SyncError::from(error)))?;
        Ok(SyncUpdate::new(update, &self.session_id))
    }

    /// A `snapshot` or `changed` frame's rows (JSON array).
    ///
    /// # Errors
    ///
    /// As [`Self::finish_list_read`].
    pub fn handle_list_rows(&self, rows_json: String) -> Result<SyncUpdate, CoreError> {
        let rows = decode_rows(&rows_json)?;
        let update = lock(&self.inner)
            .handle_list_rows(&rows)
            .map_err(|error| core_error(core::SyncError::from(error)))?;
        Ok(SyncUpdate::new(update, &self.session_id))
    }

    /// A `removed` frame. Returns whether the watched session was among `ids` (watching stops).
    pub fn handle_removed(&self, ids: Vec<String>) -> bool {
        lock(&self.inner).handle_removed(&ids)
    }

    /// Whether a history read is in flight.
    pub fn is_hydrating(&self) -> bool {
        lock(&self.inner).is_hydrating()
    }

    /// The published rows.
    pub fn rows(&self) -> Vec<Row> {
        lock(&self.inner)
            .published()
            .map(|snapshot| snapshot.rows.iter().cloned().map(Into::into).collect())
            .unwrap_or_default()
    }

    /// The published header.
    pub fn header(&self) -> Option<SessionHeader> {
        lock(&self.inner)
            .published()
            .map(|snapshot| snapshot.header.clone().into())
    }

    /// The published decision cards.
    pub fn decisions(&self) -> Vec<DecisionCard> {
        lock(&self.inner)
            .published()
            .map(|snapshot| {
                snapshot
                    .decisions
                    .iter()
                    .map(|decision| DecisionCard::from_reducer(decision, &self.session_id))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The published session sections.
    pub fn sections(&self) -> Vec<EventSection> {
        lock(&self.inner)
            .reducer()
            .map(|live| live.sections().iter().cloned().map(Into::into).collect())
            .unwrap_or_default()
    }
}
