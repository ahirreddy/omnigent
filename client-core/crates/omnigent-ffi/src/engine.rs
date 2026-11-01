//! The engine: one actor that owns the session-updates machine, a driver per open session, the
//! attention tracker and the listener stream.
//!
//! Everything that changes driver state arrives as a [`Msg`] on one queue and is handled in
//! order, without awaiting. Host callbacks (sinks, timers, finished requests) only post messages,
//! so a host may call back synchronously from inside a call the engine made without
//! re-entering it, and listener events leave in the order their causes happened.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use futures::StreamExt;
use futures::channel::mpsc::{self, UnboundedReceiver, UnboundedSender};
use futures::future::AbortHandle;
use omnigent_core as core;
use omnigent_core::auth::SecretString;
use omnigent_core::auth::endpoint::ServerEndpoint;
use omnigent_core::demo::DemoTransport;
use omnigent_core::items::ConversationPage;
use omnigent_core::notifications::attention::{AttentionTracker, ViewContext, unread_badge_ids};
use omnigent_core::realtime::{
    AttemptId, JitterSource, SessionUpdates, SplitMix64, StreamInput, UpdatesConfig, UpdatesInput,
};
use omnigent_core::{ClientEvent, SessionError};
use omnigent_protocol::SessionListItem;

use crate::errors::CoreError;
use crate::events::{
    AuthenticationMode, ConnectedServer, ConnectionPhase, CoreEvent, CoreListener, ErrorScope,
    SignInMethod,
};
use crate::host::{EventStreamTransport, WebSocketTransport};
use crate::runtime::{Host, Sessions, post};
use crate::sessions::SessionListChange;
use crate::stream_driver::SessionDriver;
use crate::updates_driver::Socket;

/// How long a burst of "inventory may be stale" hints waits before one list refresh.
const INVENTORY_REFRESH_DELAY_MS: u64 = 3_000;
/// How often the offline demo streams its next word.
pub(crate) const DEMO_TICK_MS: u64 = 120;
/// The most sessions the updates socket watches.
const MAX_WATCHED: usize = core::realtime::MAX_WATCHED_SESSIONS;

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Registered listeners.
#[derive(Default)]
pub(crate) struct Listeners {
    next_id: AtomicU64,
    entries: Mutex<Vec<(u64, Arc<dyn CoreListener>)>>,
}

impl fmt::Debug for Listeners {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Listeners")
            .field("count", &lock(&self.entries).len())
            .finish_non_exhaustive()
    }
}

impl Listeners {
    pub(crate) fn add(&self, listener: Arc<dyn CoreListener>) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        lock(&self.entries).push((id, listener));
        id
    }

    pub(crate) fn remove(&self, id: u64) -> bool {
        let mut entries = lock(&self.entries);
        let before = entries.len();
        entries.retain(|(entry, _)| *entry != id);
        entries.len() != before
    }

    fn emit(&self, event: &CoreEvent) {
        let listeners: Vec<Arc<dyn CoreListener>> = lock(&self.entries)
            .iter()
            .map(|(_, listener)| Arc::clone(listener))
            .collect();
        for listener in listeners {
            listener.on_event(event.clone());
        }
    }
}

/// The credentials the realtime connections use.
#[derive(Debug, Clone)]
pub(crate) struct Link {
    pub(crate) endpoint: ServerEndpoint,
    pub(crate) bearer: Option<SecretString>,
}

/// What the app shows when sign-in is needed again.
#[derive(Debug, Clone)]
pub(crate) struct SignInContext {
    pub(crate) base_url: String,
    pub(crate) server_name: Option<String>,
    pub(crate) mode: AuthenticationMode,
    pub(crate) methods: Vec<SignInMethod>,
}

/// The view the user is looking at, for notifications and the badge.
#[derive(Debug, Clone, Default)]
pub(crate) struct View {
    pub(crate) active_session_id: Option<String>,
    pub(crate) focused: bool,
}

/// One input for the engine.
pub(crate) enum Msg {
    /// Report a connection phase.
    Phase(ConnectionPhase),
    /// A connect succeeded: start the realtime connections and load the list.
    Connected {
        link: Link,
        server: ConnectedServer,
        sign_in: SignInContext,
    },
    /// Stop every connection, then report `phase`.
    Disconnected { phase: ConnectionPhase },
    /// The bearer was renewed in place: later stream and socket attempts use it.
    BearerRotated {
        bearer: SecretString,
        expires_at_ms: Option<u64>,
    },
    /// An event from the REST client.
    Client(ClientEvent),
    /// Start watching a session.
    Open(String),
    /// Stop watching a session.
    Close(String),
    /// An input for a session stream machine.
    Stream {
        session_id: String,
        input: StreamInput,
    },
    /// A history read finished.
    Hydrated {
        session_id: String,
        attempt: Option<AttemptId>,
        request: core::reconcile::HydrationRequest,
        result: Box<Result<ConversationPage, SessionError>>,
    },
    /// An input for the updates machine.
    Updates(UpdatesInput),
    /// Reload the session list now.
    RefreshList,
    /// A list read finished.
    ListLoaded {
        generation: u64,
        result: Result<Vec<core::sessions::SessionSummary>, SessionError>,
    },
    /// The view changed.
    View(View),
    /// Whether the app may show notifications.
    NotificationsAllowed(bool),
    /// A deferred notification is due.
    AttentionDue,
    /// The demo should stream its next word.
    DemoTick,
    /// The demo started a reply.
    DemoKick,
    /// The app returned to the foreground.
    Foreground,
    /// Report an event.
    Emit(CoreEvent),
    /// Read an open session's terminals.
    RefreshTerminals { session_id: String },
    /// A terminal list read the engine started finished.
    TerminalsListed {
        session_id: String,
        result: Result<
            Vec<omnigent_core::terminal::TerminalResource>,
            omnigent_core::terminal::TerminalError,
        >,
    },
    /// A caller's terminal list read finished.
    TerminalsLoaded {
        session_id: String,
        terminals: Vec<omnigent_core::terminal::TerminalResource>,
    },
    /// A terminal was created.
    TerminalUpserted {
        session_id: String,
        terminal: omnigent_core::terminal::TerminalResource,
    },
    /// A terminal was deleted.
    TerminalRemoved {
        session_id: String,
        terminal_id: String,
    },
    /// An activity badge lapsed.
    TerminalTick { session_id: String },
    /// Stop everything and end the engine.
    Shutdown,
}

/// The network transports, absent in demo mode.
#[derive(Clone)]
pub(crate) struct Transports {
    pub(crate) streams: Option<Arc<dyn EventStreamTransport>>,
    pub(crate) sockets: Option<Arc<dyn WebSocketTransport>>,
    pub(crate) demo: Option<Arc<DemoTransport>>,
}

/// Forwards REST-client events into the engine.
pub(crate) struct Bridge(pub(crate) UnboundedSender<Msg>);

impl core::ClientListener for Bridge {
    fn on_event(&self, event: ClientEvent) {
        post(&self.0, Msg::Client(event));
    }
}

/// Notification state.
#[derive(Default)]
pub(crate) struct Attention {
    pub(crate) tracker: AttentionTracker,
    pub(crate) rows: BTreeMap<String, SessionListItem>,
    pub(crate) view: View,
    pub(crate) can_notify: bool,
    pub(crate) timer: Option<AbortHandle>,
    pub(crate) badge: BTreeSet<String>,
}

pub(crate) struct Engine {
    pub(crate) host: Host,
    pub(crate) transports: Transports,
    pub(crate) sessions: Arc<Sessions>,
    pub(crate) listeners: Arc<Listeners>,
    pub(crate) tx: UnboundedSender<Msg>,
    pub(crate) link: Option<Link>,
    pub(crate) sign_in: Option<SignInContext>,
    pub(crate) phase: ConnectionPhase,
    pub(crate) jitter: SplitMix64,
    pub(crate) updates: SessionUpdates<SplitMix64>,
    pub(crate) socket: Option<Socket>,
    pub(crate) updates_timers: HashMap<u64, AbortHandle>,
    pub(crate) drivers: HashMap<String, SessionDriver>,
    pub(crate) attention: Attention,
    pub(crate) list_generation: u64,
    pub(crate) list_refresh: Option<AbortHandle>,
    pub(crate) demo_ticker: Option<AbortHandle>,
}

impl Engine {
    pub(crate) fn new(
        host: Host,
        transports: Transports,
        sessions: Arc<Sessions>,
        listeners: Arc<Listeners>,
        seed: u64,
    ) -> (Self, UnboundedReceiver<Msg>) {
        let (tx, rx) = mpsc::unbounded();
        let mut jitter = SplitMix64::new(seed);
        let updates = SessionUpdates::new(UpdatesConfig::default(), Self::seeded(&mut jitter));
        (
            Self {
                host,
                transports,
                sessions,
                listeners,
                tx,
                link: None,
                sign_in: None,
                phase: ConnectionPhase::Disconnected,
                jitter,
                updates,
                socket: None,
                updates_timers: HashMap::new(),
                drivers: HashMap::new(),
                attention: Attention::default(),
                list_generation: 0,
                list_refresh: None,
                demo_ticker: None,
            },
            rx,
        )
    }

    pub(crate) fn seeded(jitter: &mut SplitMix64) -> SplitMix64 {
        let high = u64::from(jitter.next_u32());
        let low = u64::from(jitter.next_u32());
        SplitMix64::new((high << 32) | low)
    }

    pub(crate) fn sender(&self) -> UnboundedSender<Msg> {
        self.tx.clone()
    }

    /// Runs until [`Msg::Shutdown`] or until every sender is gone.
    pub(crate) async fn run(mut self, mut rx: UnboundedReceiver<Msg>) {
        while let Some(message) = rx.next().await {
            if !self.handle(message) {
                break;
            }
        }
    }

    pub(crate) fn emit(&self, event: CoreEvent) {
        self.listeners.emit(&event);
    }

    pub(crate) fn error(&self, scope: ErrorScope, error: CoreError) {
        self.emit(CoreEvent::Error { scope, error });
    }

    pub(crate) const fn is_demo(&self) -> bool {
        self.transports.demo.is_some()
    }

    fn handle(&mut self, message: Msg) -> bool {
        match message {
            Msg::Phase(phase) => self.set_phase(phase),
            Msg::Connected {
                link,
                server,
                sign_in,
            } => {
                self.link = Some(link);
                self.sign_in = Some(sign_in);
                self.set_phase(ConnectionPhase::Connected { server });
                self.start_realtime();
                self.refresh_list();
            }
            Msg::Disconnected { phase } => {
                self.stop_realtime();
                self.link = None;
                self.set_phase(phase);
            }
            Msg::BearerRotated {
                bearer,
                expires_at_ms,
            } => {
                if let Some(link) = self.link.as_mut() {
                    link.bearer = Some(bearer);
                    self.emit(CoreEvent::CredentialRotated { expires_at_ms });
                }
            }
            Msg::Client(event) => self.client_event(event),
            Msg::Open(session_id) => self.open_session(&session_id),
            Msg::Close(session_id) => self.close_session(&session_id),
            Msg::Stream { session_id, input } => self.stream_input(&session_id, input),
            Msg::Hydrated {
                session_id,
                attempt,
                request,
                result,
            } => self.hydrated(&session_id, attempt, &request, *result),
            Msg::Updates(input) => self.updates_input(input),
            Msg::RefreshList => self.refresh_list(),
            Msg::ListLoaded { generation, result } => self.list_loaded(generation, result),
            Msg::View(view) => {
                self.attention.view = view;
                self.observe_attention();
            }
            Msg::NotificationsAllowed(allowed) => self.attention.can_notify = allowed,
            Msg::AttentionDue => self.attention_due(),
            Msg::DemoTick => self.demo_tick(),
            Msg::DemoKick => self.demo_kick(),
            Msg::Foreground => self.foreground(),
            Msg::Emit(event) => self.emit(event),
            Msg::RefreshTerminals { session_id } => self.refresh_terminals(&session_id),
            Msg::TerminalsListed { session_id, result } => {
                self.terminals_listed(&session_id, result);
            }
            Msg::TerminalsLoaded {
                session_id,
                terminals,
            } => self.terminals_loaded(&session_id, terminals),
            Msg::TerminalUpserted {
                session_id,
                terminal,
            } => self.terminal_upserted(&session_id, terminal),
            Msg::TerminalRemoved {
                session_id,
                terminal_id,
            } => self.terminal_removed(&session_id, &terminal_id),
            Msg::TerminalTick { session_id } => self.publish_terminals(&session_id),
            Msg::Shutdown => {
                self.stop_realtime();
                let ids: Vec<String> = self.drivers.keys().cloned().collect();
                for id in ids {
                    self.close_session(&id);
                }
                return false;
            }
        }
        true
    }

    fn set_phase(&mut self, phase: ConnectionPhase) {
        if self.phase == phase {
            return;
        }
        self.phase = phase.clone();
        self.emit(CoreEvent::ConnectionChanged { phase });
    }

    pub(crate) const fn is_connected(&self) -> bool {
        matches!(self.phase, ConnectionPhase::Connected { .. })
    }

    /// The credentials were rejected while connected: stop and ask for sign-in again.
    pub(crate) fn sign_in_lost(&mut self, reason: CoreError) {
        if !self.is_connected() {
            return;
        }
        self.stop_realtime();
        self.link = None;
        self.sessions.disconnect();
        let phase = self.sign_in.clone().map_or_else(
            || ConnectionPhase::Failed {
                server_url: String::new(),
                error: reason.clone(),
            },
            |context| ConnectionPhase::SignInRequired {
                base_url: context.base_url,
                server_name: context.server_name,
                mode: context.mode,
                methods: context.methods,
                reason: Some(reason.clone()),
            },
        );
        self.set_phase(phase);
    }

    fn start_realtime(&mut self) {
        if self.is_demo() {
            let ids: Vec<String> = self.drivers.keys().cloned().collect();
            for id in ids {
                self.request_hydration(&id);
            }
            return;
        }
        self.start_updates();
        let ids: Vec<String> = self.drivers.keys().cloned().collect();
        for id in ids {
            self.stream_input(&id, StreamInput::Start);
        }
    }

    fn stop_realtime(&mut self) {
        if let Some(timer) = self.list_refresh.take() {
            timer.abort();
        }
        if let Some(timer) = self.attention.timer.take() {
            timer.abort();
        }
        self.attention.tracker.reset();
        self.attention.rows.clear();
        self.stop_updates();
        let ids: Vec<String> = self.drivers.keys().cloned().collect();
        for id in ids {
            self.stream_input(&id, StreamInput::Stop);
            if let Some(driver) = self.drivers.get(&id) {
                driver.sync.close_stream();
            }
        }
        self.sessions.set_live_session(None);
    }

    fn foreground(&mut self) {
        if !self.is_connected() {
            return;
        }
        self.start_realtime();
        self.refresh_list();
    }

    fn client_event(&mut self, event: ClientEvent) {
        match event {
            ClientEvent::ConnectionChanged { connected } => {
                if !connected && self.is_connected() {
                    self.sign_in_lost(CoreError::from(SessionError::Unauthorized { reason: None }));
                }
            }
            ClientEvent::SessionsChanged { sessions } => {
                self.emit(CoreEvent::SessionListChanged {
                    change: SessionListChange::Upsert {
                        sessions: sessions.into_iter().map(Into::into).collect(),
                    },
                });
                self.update_watch();
            }
            ClientEvent::SessionsRemoved { ids } => {
                self.emit(CoreEvent::SessionListChanged {
                    change: SessionListChange::Remove { ids },
                });
                self.update_watch();
            }
            ClientEvent::InventoryInvalidated => self.schedule_list_refresh(),
            ClientEvent::HydrationRequested { session_id } => self.request_hydration(&session_id),
            ClientEvent::ChangedFiles {
                session_id,
                environment_id,
                update,
            } => {
                if let Some(driver) = self.drivers.get(&session_id) {
                    let applied = driver
                        .sync
                        .set_changed_files_raw(&environment_id, update.clone().into());
                    self.publish(&session_id, applied);
                }
                self.emit(CoreEvent::ChangedFiles {
                    session_id,
                    environment_id,
                    update: update.into(),
                });
            }
        }
    }

    /// A hint that the list may be stale. While the updates socket is live it already delivers
    /// every watched and discovered row, so only a disconnected socket falls back to a reload.
    fn schedule_list_refresh(&mut self) {
        let socket_live = matches!(self.updates.state(), core::realtime::ConnectionState::Live);
        if self.list_refresh.is_some() || !self.is_connected() || socket_live {
            return;
        }
        let tx = self.sender();
        self.list_refresh = Some(self.host.after(INVENTORY_REFRESH_DELAY_MS, move || {
            post(&tx, Msg::RefreshList);
        }));
    }

    pub(crate) fn refresh_list(&mut self) {
        if let Some(timer) = self.list_refresh.take() {
            timer.abort();
        }
        if !self.is_connected() {
            return;
        }
        self.list_generation = self.list_generation.wrapping_add(1);
        let generation = self.list_generation;
        let sessions = Arc::clone(&self.sessions);
        let tx = self.sender();
        self.host.spawn(async move {
            let result = sessions.sessions().await;
            post(&tx, Msg::ListLoaded { generation, result });
        });
    }

    fn list_loaded(
        &mut self,
        generation: u64,
        result: Result<Vec<core::sessions::SessionSummary>, SessionError>,
    ) {
        if generation != self.list_generation || !self.is_connected() {
            return;
        }
        match result {
            Ok(list) => {
                self.emit(CoreEvent::SessionListChanged {
                    change: SessionListChange::Reset {
                        sessions: list.into_iter().map(Into::into).collect(),
                    },
                });
                self.emit(CoreEvent::SessionListLoaded);
                self.update_watch();
            }
            Err(error) => {
                let error = CoreError::from(error);
                if error.requires_sign_in() {
                    self.sign_in_lost(error);
                } else {
                    self.error(ErrorScope::SessionList, error);
                }
            }
        }
    }

    /// Watches every known session, most recently updated first, up to the server's cap.
    fn update_watch(&mut self) {
        if self.is_demo() || !self.is_connected() {
            return;
        }
        let mut summaries = self.sessions.cached_summaries();
        summaries.sort_by(|left, right| {
            right
                .updated_at
                .cmp(&left.updated_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        let mut ids: Vec<String> = self.drivers.keys().cloned().collect();
        for summary in summaries {
            if ids.len() >= MAX_WATCHED {
                break;
            }
            if !ids.contains(&summary.id) {
                ids.push(summary.id);
            }
        }
        match self.updates.set_watch(ids) {
            Ok(outputs) => self.run_updates_outputs(outputs),
            Err(error) => self.error(ErrorScope::SessionList, crate::errors::core_error(error)),
        }
    }

    fn demo_kick(&mut self) {
        if self.demo_ticker.is_some() {
            return;
        }
        let tx = self.sender();
        self.demo_ticker = Some(
            self.host
                .after(DEMO_TICK_MS, move || post(&tx, Msg::DemoTick)),
        );
    }

    fn demo_tick(&mut self) {
        self.demo_ticker = None;
        let Some(demo) = self.transports.demo.clone() else {
            return;
        };
        let changed = demo.advance_replies();
        for id in &changed {
            self.request_hydration(id);
        }
        if !changed.is_empty() {
            self.refresh_list();
        }
        if demo.is_replying() {
            self.demo_kick();
        }
    }

    fn observe_attention(&mut self) {
        let view = ViewContext {
            active_session_id: self.attention.view.active_session_id.clone(),
            window_focused: self.attention.view.focused,
        };
        let rows: Vec<SessionListItem> = self.attention.rows.values().cloned().collect();
        let now = self.host.unix_ms();
        let notifications =
            self.attention
                .tracker
                .observe(&rows, &view, now, self.attention.can_notify);
        for notification in notifications {
            self.emit(CoreEvent::Notification {
                notification: notification.into(),
            });
        }
        self.schedule_attention(now);
        let badge = unread_badge_ids(&rows, &view, |_| false);
        if badge != self.attention.badge {
            self.attention.badge.clone_from(&badge);
            self.emit(CoreEvent::BadgeChanged {
                session_ids: badge.into_iter().collect(),
            });
        }
    }

    fn schedule_attention(&mut self, now: u64) {
        if let Some(timer) = self.attention.timer.take() {
            timer.abort();
        }
        if let Some(deadline) = self.attention.tracker.next_deadline_ms() {
            let tx = self.sender();
            self.attention.timer = Some(self.host.after(deadline.saturating_sub(now), move || {
                post(&tx, Msg::AttentionDue);
            }));
        }
    }

    fn attention_due(&mut self) {
        self.attention.timer = None;
        let view = ViewContext {
            active_session_id: self.attention.view.active_session_id.clone(),
            window_focused: self.attention.view.focused,
        };
        let now = self.host.unix_ms();
        let notifications = self.attention.tracker.due(&view, now);
        for notification in notifications {
            self.emit(CoreEvent::Notification {
                notification: notification.into(),
            });
        }
        self.schedule_attention(now);
    }

    pub(crate) fn attention_rows(&mut self, rows: Vec<SessionListItem>) {
        for row in rows {
            self.attention.rows.insert(row.id.clone(), row);
        }
        self.observe_attention();
    }

    pub(crate) fn attention_removed(&mut self, ids: &[String]) {
        for id in ids {
            self.attention.rows.remove(id);
        }
        self.observe_attention();
    }
}
