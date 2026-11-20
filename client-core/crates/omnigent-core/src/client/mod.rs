//! The client core: one object per server connection that owns the session state and performs
//! every REST call through the host's [`HttpTransport`].
//!
//! Port of `NativeLab`'s `LocalServerSessionClient` actor (REST half). [`ClientCore`] holds:
//!
//! - the [`HostedConnection`] (identity confirmation, `401` ends it);
//! - the cached [`SessionSummary`] of every session it has read, with per-session metadata
//!   epochs so a slow read never rolls back newer metadata from an event or a list row;
//! - the session whose live stream is open and hydrated (sends require it);
//! - the [`SubmissionLedger`] and the [`AttachmentDraftStore`] that gate every message send;
//! - the [`IntentLedger`] of list-row edits that show before the server answers.
//!
//! Every method takes `&self`; state sits behind a mutex that is never held across an `.await`,
//! so a disconnect can land while a request is in flight and the late result is discarded.
//! Changes are reported to [`ClientListener`]s as granular [`ClientEvent`]s, after the lock is
//! released.
//!
//! The operations are grouped by file: [`sessions`] (list, inventory, organisation), [`items`]
//! (history and conversation pages), [`events`] (send, interrupt, resolve, changed files,
//! uploads), [`create`] (catalog and creation), [`fork`] (fork and start) and [`configure`]
//! (model, effort and harness).

#![allow(
    clippy::significant_drop_tightening,
    reason = "each operation applies its state changes under one guard so they land atomically"
)]

pub mod agent_costs;
pub mod agent_info;
pub mod agent_tree;
mod attachment_previews;
pub mod automations;
pub mod branding;
pub mod browser;
pub mod comments;
pub mod configure;
pub mod create;
mod create_nested;
mod custom_agents;
pub mod databricks_session;
mod error;
pub mod events;
pub mod execution_logs;
mod export;
pub mod extension_reads;
mod families;
pub mod fork;
pub mod harness_inventory;
mod harness_setup;
pub mod host_switch;
pub mod html_comments;
mod hydration;
pub mod import_review;
pub mod inbox;
pub mod inbox_items;
mod intent_lanes;
pub mod items;
mod journal;
pub(crate) mod json;
pub mod mcp_tools;
pub mod pdf_comments;
pub mod pin_order;
pub mod policy_registry;
pub mod proactive_agent;
pub mod project_repository;
pub mod project_settings;
pub mod projects;
pub mod pull_request_detail;
pub mod pull_request_edits;
pub mod pull_requests;
mod recovery;
mod remote_browsers;
mod requests;
pub mod rewind;
mod routing;
mod sandbox;
mod sandbox_operations;
pub mod server_admin;
mod session_actions;
pub mod session_mcp;
mod session_mcp_rows;
pub mod session_search;
pub mod session_tools;
pub mod sessions;
pub mod share;
mod skills;
pub mod stream_log;
mod terminals;
pub mod usage;
pub mod user_settings;
mod workflows;

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

pub use error::SessionError;
use events::ChangedFilesUpdate;
pub use routing::{SLICE_KEY_HEADER, SLICE_KEY_QUERY};
use sessions::SessionSummary;

use crate::attachments::{AttachmentDraftStore, FilesystemAttachments};
use crate::auth::SecretString;
use crate::auth::endpoint::ServerEndpoint;
use crate::auth::hosted::{ConnectedServer, HostedConnection};
use crate::auth::mode::ServerInfo;
use crate::discovery::{ServerDiscovery, discovery_from_response, manifest_request};
use crate::error::CoreError;
use crate::http::HttpTransport;
use crate::intents::{IntentLedger, IntentTimer};
use crate::ledger::SubmissionLedger;
use crate::server_url;

/// Host policy for the core.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CoreConfig {
    /// Accept `http://` server URLs. Schemeless loopback input then defaults to http.
    pub allows_insecure_http: bool,
}

/// A change the UI should apply. Events arrive in order, after the operation that caused them
/// has updated the core's state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientEvent {
    /// The connection opened or ended. After `false`, every request fails `NotConnected` until
    /// the next connect.
    ConnectionChanged {
        /// Whether the core is connected now.
        connected: bool,
    },
    /// These summaries are new or changed.
    SessionsChanged {
        /// The summaries, in the order they were read.
        sessions: Vec<SessionSummary>,
    },
    /// These sessions were deleted or lost access.
    SessionsRemoved {
        /// The ids.
        ids: Vec<String>,
    },
    /// The session list may be stale; refetch the inventory when convenient.
    InventoryInvalidated,
    /// A write may have changed this session's transcript or metadata: re-hydrate it if it is
    /// open.
    HydrationRequested {
        /// The session.
        session_id: String,
    },
    /// The changed-files section of the open session has new contents.
    ChangedFiles {
        /// The session.
        session_id: String,
        /// The environment, for example `default`.
        environment_id: String,
        /// The entries, or why they are unavailable.
        update: ChangedFilesUpdate,
    },
    /// For the host, not the UI: call [`ClientCore::intent_timer_elapsed`] with `timer` after
    /// [`IntentTimer::delay_ms`]. Without it an accepted edit masks its field until a server
    /// row agrees, and an edit lost with the link waits for the link without limit.
    IntentTimerRequested {
        /// The timer.
        timer: IntentTimer,
    },
    /// A message to this session is being sent: if it is open and idle, show it working until
    /// the server reports the turn, [`Self::TurnExpectationEnded`] names this expectation, or
    /// [`crate::reconcile::TURN_EXPECTATION_MS`] passes.
    TurnExpected {
        /// The session.
        session_id: String,
        /// Identifies this send's expectation.
        expectation: u64,
    },
    /// The send behind `expectation` was not accepted: stop showing the turn it expected.
    TurnExpectationEnded {
        /// The session.
        session_id: String,
        /// From [`Self::TurnExpected`].
        expectation: u64,
    },
}

/// Receives [`ClientEvent`]s. Called outside the core's lock, on the thread that ran the
/// operation; implementations must not block.
pub trait ClientListener: Send + Sync {
    /// One event.
    fn on_event(&self, event: ClientEvent);
}

/// Identifies one [`ClientCore::subscribe`] registration.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SubscriptionId(u64);

impl SubscriptionId {
    /// The raw id, for FFI mirrors.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

/// Everything the core knows about the connected server. Reset on connect and disconnect.
#[derive(Debug, Default)]
struct State {
    connection: Option<HostedConnection>,
    connected: Option<ConnectedServer>,
    /// Bumped by every connect and disconnect; results from an older epoch are discarded.
    epoch: u64,
    summaries: BTreeMap<String, SessionSummary>,
    /// Bumped whenever a session's metadata may have changed under an in-flight read.
    metadata_epochs: BTreeMap<String, u64>,
    metadata_revision: u64,
    /// Conversation-page revision counter.
    revision: u64,
    /// Sessions whose stream is open and hydrated; a window's tabs keep several open.
    live_sessions: BTreeSet<String>,
    /// Sessions created here whose first message the server has not taken yet. Their machine
    /// may still be starting (a new sandbox), so a message to them is the server's to hold.
    awaiting_first_message: BTreeSet<String>,
    /// Sessions created here that no list page has shown yet. A list read that began before
    /// the create was answered does not have them, and must not take their rows away.
    unlisted_creations: BTreeSet<String>,
    /// What a session created here is called until the server names it: its first message, cut
    /// as the server cuts the title it seeds once the message is stored (the web does the same).
    first_message_titles: BTreeMap<String, String>,
    configuration_mutations: BTreeSet<String>,
    changed_files: BTreeMap<(String, String), ChangedFilesFetch>,
    ledger: SubmissionLedger,
    /// List-row edits that have not settled. They belong to the scope, as the ledger does.
    intents: IntentLedger,
    /// The host reports its live link to the server, so a link that returns will be heard of.
    link_watched: bool,
    /// The host reported its live link to the server down: list-row edits are refused.
    link_down: bool,
    /// How often the live link has returned; a write lost with it goes again after the next.
    link_returns: u64,
    drafts: AttachmentDraftStore,
    /// Which files the server delivers as files, from the last `/v1/info` read; the default
    /// extensions until one is read.
    attachment_policy: FilesystemAttachments,
    composer: BTreeMap<(String, String), String>,
    /// The last [`ClientEvent::TurnExpected`] id handed out.
    turn_expectations: u64,
    events: Vec<ClientEvent>,
    /// Where sessions run, for replica routing on host-sharded servers.
    routing: routing::ReplicaRouting,
    /// Side chats seen so far: they belong to their session's tab, never the session list.
    side_chats: BTreeSet<String>,
    /// Each open session's stream events, for the execution logs' live view.
    stream_logs: BTreeMap<String, stream_log::StreamLog>,
    /// The user turned off automatic session titles (a device preference, kept across connects).
    background_titles_off: bool,
}

#[derive(Debug, Default, Clone, Copy)]
struct ChangedFilesFetch {
    epoch: u64,
    in_flight: bool,
}

impl State {
    /// Forgets everything tied to the previous connection. Delivery state (the ledgers and
    /// drafts) belongs to the scope and session, so it survives a reconnect.
    fn reset_connection_state(&mut self) {
        self.epoch = self.epoch.wrapping_add(1);
        self.connected = None;
        self.link_watched = false;
        self.link_down = false;
        self.summaries.clear();
        self.metadata_epochs.clear();
        self.configuration_mutations.clear();
        self.changed_files.clear();
        self.live_sessions.clear();
        self.awaiting_first_message.clear();
        self.unlisted_creations.clear();
        self.first_message_titles.clear();
        self.routing = routing::ReplicaRouting::default();
        self.side_chats.clear();
        self.attachment_policy = FilesystemAttachments::default();
    }

    /// The send behind `expectation` was not accepted: the conversation stops showing its turn.
    fn end_turn_expectation(&mut self, session_id: &str, expectation: u64) {
        self.events.push(ClientEvent::TurnExpectationEnded {
            session_id: session_id.to_owned(),
            expectation,
        });
    }

    /// The queued events as the UI gets them. List changes carry what the list shows: side
    /// chats are dropped (the server's `GET /v1/sessions` leaves them out, but its updates
    /// stream and per-session reads do not), and every row goes through [`Self::shown_rows`].
    fn take_events(&mut self) -> Vec<ClientEvent> {
        let mut events = std::mem::take(&mut self.events);
        if self.side_chats.is_empty() && self.intents.is_empty() {
            return events;
        }
        for event in &mut events {
            if let ClientEvent::SessionsChanged { sessions } = event {
                sessions.retain(|summary| !self.side_chats.contains(&summary.id));
                *sessions = self.shown_rows(std::mem::take(sessions));
            }
        }
        events.retain(|event| {
            !matches!(event, ClientEvent::SessionsChanged { sessions } if sessions.is_empty())
        });
        events
    }

    /// Whether the connected server shards replicas by host (a Databricks workspace).
    fn routes_by_host(&self) -> bool {
        self.connection
            .as_ref()
            .is_some_and(|connection| connection.endpoint().routes_by_host())
    }

    fn is_connected(&self) -> bool {
        self.connection
            .as_ref()
            .is_some_and(HostedConnection::is_connected)
    }

    fn metadata_epoch(&self, id: &str) -> u64 {
        self.metadata_epochs.get(id).copied().unwrap_or(0)
    }

    fn bump_metadata_epoch(&mut self, id: &str) {
        let epoch = self.metadata_epochs.entry(id.to_owned()).or_insert(0);
        *epoch = epoch.wrapping_add(1);
    }

    /// Stamps `summary` with the next metadata revision, bumping the session's metadata epoch
    /// when anything that gates a write changed.
    fn record_summary(&mut self, mut summary: SessionSummary) -> SessionSummary {
        // A session created here goes by its first message until the server (or the user)
        // names it; every row of it passes through here on its way to the cache.
        if let Some(title) = self.first_message_titles.get(&summary.id) {
            if summary.title == crate::reconcile::UNTITLED_SESSION {
                summary.title.clone_from(title);
            } else if summary.title != *title {
                self.first_message_titles.remove(&summary.id);
            }
        }
        let changed = self.summaries.get(&summary.id).is_none_or(|previous| {
            previous.configuration != summary.configuration
                || previous.status != summary.status
                || previous.is_read_only != summary.is_read_only
                || previous.is_archived != summary.is_archived
        });
        if changed {
            self.bump_metadata_epoch(&summary.id);
        }
        self.metadata_revision = self.metadata_revision.wrapping_add(1);
        summary.configuration_revision = Some(self.metadata_revision);
        summary
    }

    fn cache_summary(&mut self, summary: &SessionSummary) {
        self.summaries.insert(summary.id.clone(), summary.clone());
    }

    /// The delivery scope (server plus account) of the current connection.
    fn scope(&self) -> Result<String, SessionError> {
        self.scope_id().ok_or(SessionError::NotConnected)
    }

    /// [`Self::scope`], `None` when not connected.
    fn scope_id(&self) -> Option<String> {
        self.connected
            .as_ref()
            .map(|server| server.scope.account_id())
    }

    /// A `401` (or an auth-required transport failure) ends the connection.
    fn authentication_failed(&mut self) {
        if let Some(connection) = self.connection.as_mut() {
            connection.disconnect();
        }
        self.reset_connection_state();
        self.events
            .push(ClientEvent::ConnectionChanged { connected: false });
    }
}

/// The client core, generic over the host transport.
#[derive(Debug)]
pub struct ClientCore<T> {
    transport: T,
    config: CoreConfig,
    state: Mutex<State>,
    listeners: Mutex<Listeners>,
    /// The device's IANA time zone, sent with session creates (see [`TIMEZONE_HEADER`]).
    timezone: Mutex<Option<String>>,
}

/// The header a session create carries so schedules the server makes for the caller (Omni
/// Advisor's) follow the caller's time zone, as the web sends it.
const TIMEZONE_HEADER: &str = "X-Omnigent-Timezone";

#[derive(Default)]
struct Listeners {
    next_id: u64,
    entries: Vec<(SubscriptionId, Arc<dyn ClientListener>)>,
}

impl std::fmt::Debug for Listeners {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Listeners")
            .field("next_id", &self.next_id)
            .field("count", &self.entries.len())
            .finish()
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    // A poisoned lock means an earlier panic; the state itself is still consistent because no
    // method leaves it half-updated across a panic point.
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl<T: HttpTransport> ClientCore<T> {
    /// A core that sends through `transport`.
    pub fn new(transport: T, config: CoreConfig) -> Self {
        Self {
            transport,
            config,
            state: Mutex::new(State::default()),
            listeners: Mutex::new(Listeners::default()),
            timezone: Mutex::new(None),
        }
    }

    /// The policy this core was created with.
    pub const fn config(&self) -> CoreConfig {
        self.config
    }

    /// Sets the device's IANA time zone (`Europe/Paris`) that session creates carry; `None`, or a
    /// name with characters no zone has, sends none and the server uses UTC.
    pub fn set_timezone(&self, timezone: Option<&str>) {
        let valid = timezone.filter(|zone| {
            !zone.is_empty()
                && zone.len() <= 64
                && zone
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"/_+-".contains(&byte))
        });
        *lock(&self.timezone) = valid.map(str::to_owned);
    }

    /// The time zone session creates carry, if any.
    pub fn timezone(&self) -> Option<String> {
        lock(&self.timezone).clone()
    }

    /// The host transport.
    pub const fn transport(&self) -> &T {
        &self.transport
    }

    /// Normalizes `server_url` and reads the server's manifest.
    ///
    /// # Errors
    ///
    /// [`CoreError::InvalidUrl`] before any request, [`CoreError::Transport`] when the host fails,
    /// and see [`discovery_from_response`] for the rest.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn discover_server(&self, server_url: &str) -> Result<ServerDiscovery, CoreError> {
        let url = server_url::normalize(server_url, self.config.allows_insecure_http).map_err(
            |error| CoreError::InvalidUrl {
                message: error.to_string(),
            },
        )?;
        let response = self.transport.send(manifest_request(&url)).await?;
        discovery_from_response(&url, &response)
    }

    /// Registers `listener` for every later [`ClientEvent`].
    pub fn subscribe(&self, listener: Arc<dyn ClientListener>) -> SubscriptionId {
        let mut listeners = lock(&self.listeners);
        let id = SubscriptionId(listeners.next_id);
        listeners.next_id = listeners.next_id.wrapping_add(1);
        listeners.entries.push((id, listener));
        id
    }

    /// Removes a registration. Returns whether it existed.
    pub fn unsubscribe(&self, id: SubscriptionId) -> bool {
        let mut listeners = lock(&self.listeners);
        let before = listeners.entries.len();
        listeners.entries.retain(|(entry, _)| *entry != id);
        listeners.entries.len() != before
    }

    /// How many listeners are registered.
    pub fn listener_count(&self) -> usize {
        lock(&self.listeners).entries.len()
    }

    /// Delivers queued events to every listener, outside the state lock.
    fn dispatch(&self) {
        let events = lock(&self.state).take_events();
        if events.is_empty() {
            return;
        }
        let listeners: Vec<Arc<dyn ClientListener>> = lock(&self.listeners)
            .entries
            .iter()
            .map(|(_, listener)| Arc::clone(listener))
            .collect();
        for event in events {
            for listener in &listeners {
                listener.on_event(event.clone());
            }
        }
    }

    /// Runs discovery and identity confirmation for a new connection, replacing any previous
    /// one (credentials and identity are fixed per connection; switch accounts this way).
    ///
    /// # Errors
    ///
    /// [`SessionError::Auth`] with the [`HostedAuthError`](crate::auth::errors::HostedAuthError)
    /// (transport failures map to [`SessionError::Transport`] and
    /// [`SessionError::Cancelled`]); [`SessionError::NotConnected`] when another connect or a
    /// disconnect superseded this one while it ran.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn connect(
        &self,
        endpoint: ServerEndpoint,
        bearer: Option<SecretString>,
        expected_user_id: Option<String>,
    ) -> Result<ConnectedServer, SessionError> {
        self.connect_knowing(endpoint, bearer, expected_user_id, None)
            .await
    }

    /// As [`Self::connect`], with the server's `/v1/info` when the caller read it a moment ago,
    /// which saves the connect that round trip.
    ///
    /// # Errors
    ///
    /// As [`Self::connect`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn connect_knowing(
        &self,
        endpoint: ServerEndpoint,
        bearer: Option<SecretString>,
        expected_user_id: Option<String>,
        info: Option<ServerInfo>,
    ) -> Result<ConnectedServer, SessionError> {
        let connection = HostedConnection::new(endpoint, bearer, expected_user_id)?;
        let result = self.run_connect(connection, info).await;
        self.dispatch();
        result
    }

    /// Reconnects with the current connection's credentials; the identity confirmed earlier
    /// stays pinned.
    ///
    /// # Errors
    ///
    /// [`SessionError::NotConnected`] when there was never a connection, then as
    /// [`Self::connect`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn reconnect(&self) -> Result<ConnectedServer, SessionError> {
        let connection = lock(&self.state)
            .connection
            .take()
            .ok_or(SessionError::NotConnected)?;
        let result = self.run_connect(connection, None).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn run_connect(
        &self,
        mut connection: HostedConnection,
        info: Option<ServerInfo>,
    ) -> Result<ConnectedServer, SessionError> {
        let epoch = {
            let mut state = lock(&self.state);
            let was_connected = state.is_connected();
            state.connection = None;
            state.reset_connection_state();
            if was_connected {
                state
                    .events
                    .push(ClientEvent::ConnectionChanged { connected: false });
            }
            state.epoch
        };
        let result = connection.connect_knowing(&self.transport, info).await;
        let mut state = lock(&self.state);
        if state.epoch != epoch {
            return Err(SessionError::NotConnected);
        }
        state.connection = Some(connection);
        let server = result?;
        state.connected = Some(server.clone());
        state
            .events
            .push(ClientEvent::ConnectionChanged { connected: true });
        Ok(server)
    }

    /// Ends the connection. In-flight reads then fail [`SessionError::NotConnected`] and
    /// in-flight writes [`SessionError::DeliveryUncertain`].
    pub fn disconnect(&self) {
        {
            let mut state = lock(&self.state);
            let was_connected = state.is_connected();
            if let Some(connection) = state.connection.as_mut() {
                connection.disconnect();
            }
            state.reset_connection_state();
            if was_connected {
                state
                    .events
                    .push(ClientEvent::ConnectionChanged { connected: false });
            }
        }
        self.dispatch();
    }

    /// Replaces the connection's bearer with a renewed one for the same identity (an OIDC or
    /// Databricks token refresh), without a reconnect: cached sessions, metadata epochs and the
    /// live session stay, and requests prepared from now on carry `bearer`.
    ///
    /// # Errors
    ///
    /// [`SessionError::NotConnected`] while disconnected; [`SessionError::Auth`] with
    /// [`HostedAuthError::UnsupportedAuthentication`](crate::auth::errors::HostedAuthError) for a
    /// connection without a bearer, or [`HostedAuthError::Unauthorized`](crate::auth::errors::HostedAuthError)
    /// for a bearer that cannot be sent.
    pub fn rotate_bearer(&self, bearer: SecretString) -> Result<(), SessionError> {
        let mut state = lock(&self.state);
        let connection = state
            .connection
            .as_mut()
            .filter(|connection| connection.is_connected())
            .ok_or(SessionError::NotConnected)?;
        connection.rotate_bearer(bearer).map_err(SessionError::Auth)
    }

    /// Whether the core is connected.
    pub fn is_connected(&self) -> bool {
        lock(&self.state).is_connected()
    }

    /// What the last successful connect confirmed, while still connected.
    pub fn connected_server(&self) -> Option<ConnectedServer> {
        lock(&self.state).connected.clone()
    }

    /// Which files the server delivers to the agent as files, from the last `/v1/info` read
    /// (the composer's command options or the new-session catalog); the default extensions
    /// until one is read.
    pub fn attachment_policy(&self) -> FilesystemAttachments {
        lock(&self.state).attachment_policy.clone()
    }

    /// Keeps the filesystem attachment policy of a `/v1/info` body just read on this connection
    /// (a read from an earlier connection fails before it gets here).
    pub(crate) fn record_attachment_policy(&self, info: &serde_json::Value) {
        lock(&self.state).attachment_policy = FilesystemAttachments::from_info(info);
    }

    /// The cached summary of `session_id`.
    pub fn cached_summary(&self, session_id: &str) -> Option<SessionSummary> {
        lock(&self.state).summaries.get(session_id).cloned()
    }

    /// The rows of `ids`, in order, as the list shows them now: their cached summaries with any
    /// pending edit applied. An id without one, or whose row an edit hides, is left out.
    pub fn shown_summaries(&self, ids: &[String]) -> Vec<SessionSummary> {
        let state = lock(&self.state);
        let rows = ids
            .iter()
            .filter_map(|id| state.summaries.get(id).cloned())
            .collect();
        state.shown_rows(rows)
    }

    /// Every cached summary, by id.
    pub fn cached_summaries(&self) -> Vec<SessionSummary> {
        lock(&self.state).summaries.values().cloned().collect()
    }

    /// Marks whether `session_id`'s live stream is open and hydrated. The stream driver marks it
    /// after `Ready` and a successful snapshot, and unmarks it when the stream stops; message
    /// sends and configuration changes require it.
    pub fn set_live_session(&self, session_id: &str, live: bool) {
        let mut state = lock(&self.state);
        if live {
            state.live_sessions.insert(session_id.to_owned());
        } else {
            state.live_sessions.remove(session_id);
        }
    }

    /// Unmarks every session, for example when every stream stops.
    pub fn clear_live_sessions(&self) {
        lock(&self.state).live_sessions.clear();
    }

    /// Whether `session_id`'s live stream is open and hydrated.
    pub fn is_live_session(&self, session_id: &str) -> bool {
        lock(&self.state).live_sessions.contains(session_id)
    }
}

#[cfg(test)]
#[path = "discovery_tests.rs"]
mod discovery_tests;

#[cfg(test)]
#[path = "helpers_tests.rs"]
mod helpers_tests;

#[cfg(test)]
#[path = "client_tests.rs"]
mod client_tests;

#[cfg(test)]
#[path = "create_tests.rs"]
mod create_tests;

#[cfg(test)]
#[path = "configure_tests.rs"]
mod configure_tests;

#[cfg(test)]
#[path = "fork_tests.rs"]
mod fork_tests;

#[cfg(test)]
#[path = "routing_tests.rs"]
mod routing_tests;

#[cfg(test)]
pub(crate) mod test_support;

#[cfg(test)]
#[path = "skills_tests.rs"]
mod skills_tests;

#[cfg(test)]
#[path = "queue_tests.rs"]
mod queue_tests;

#[cfg(test)]
#[path = "export_tests.rs"]
mod export_tests;

#[cfg(test)]
#[path = "attachment_previews_tests.rs"]
mod attachment_previews_tests;

#[cfg(test)]
#[path = "recovery_tests.rs"]
mod recovery_tests;

#[cfg(test)]
#[path = "sandbox_operations_tests.rs"]
mod sandbox_operations_tests;

#[cfg(test)]
#[path = "agent_info_tests.rs"]
mod agent_info_tests;

#[cfg(test)]
#[path = "pull_requests_tests.rs"]
mod pull_requests_tests;

#[cfg(test)]
#[path = "pull_request_detail_tests.rs"]
mod pull_request_detail_tests;

#[cfg(test)]
#[path = "mcp_tools_tests.rs"]
mod mcp_tools_tests;

#[cfg(test)]
#[path = "journal_tests.rs"]
mod journal_tests;
