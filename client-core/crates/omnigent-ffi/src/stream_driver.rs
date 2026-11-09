//! One open session: its `GET …/stream` machine, executed through the host's event-stream
//! transport, and its `ConversationSync`, hydrated through the REST client.

use std::collections::HashMap;
use std::sync::Arc;

use futures::future::AbortHandle;
use omnigent_core as core;
use omnigent_core::SessionError;
use omnigent_core::items::ConversationPage;
use omnigent_core::realtime::{
    AttemptId, ConnectionFailure, ConnectionState, HydrationFailure, SessionStream, SplitMix64,
    StreamConfig, StreamInput, StreamOutput,
};
use omnigent_core::reconcile::{HydrationRequest, SyncError};
use omnigent_core::reducer;

use crate::engine::{Engine, Msg};
use crate::errors::CoreError;
use crate::events::{CoreEvent, ErrorScope};
use crate::host::{ByteSink, SinkEvent, StreamHandle};
use crate::runtime::post;
use crate::sync::{Applied, ConversationSync};

/// Which opening of a session a late callback belongs to: attempt and read tokens restart when a
/// session is closed and reopened, so they alone cannot tell the two apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct DriverInstance(u64);

#[cfg(test)]
impl DriverInstance {
    /// The instance of the first session an engine opens.
    pub(crate) const fn first() -> Self {
        Self(0)
    }
}

/// The state of one open session.
pub(crate) struct SessionDriver {
    pub(crate) instance: DriverInstance,
    pub(crate) sync: Arc<ConversationSync>,
    /// Absent for the offline demo, which has no stream.
    machine: Option<SessionStream<SplitMix64>>,
    handles: HashMap<AttemptId, Arc<dyn StreamHandle>>,
    timers: HashMap<u64, AbortHandle>,
    live_attempt: Option<AttemptId>,
    revision: u64,
    pub(crate) terminals: omnigent_core::terminal::TerminalInventory,
    pub(crate) terminal_view: Option<crate::terminal_driver::TerminalView>,
    pub(crate) terminal_tick: Option<AbortHandle>,
    /// Whether the open stream attempt carried the replica routing key.
    stream_keyed: bool,
    /// The history paging state last reported.
    pub(crate) paging: Option<omnigent_core::reconcile::HistoryPaging>,
}

/// What a failed history read means for the stream.
fn hydration_failure(error: &SessionError) -> HydrationFailure {
    use core::http::TransportError;
    match error {
        SessionError::Unauthorized { .. } | SessionError::NotConnected => {
            HydrationFailure::HttpStatus { status: 401 }
        }
        SessionError::Forbidden => HydrationFailure::HttpStatus { status: 403 },
        SessionError::SessionNotFound { .. } => HydrationFailure::HttpStatus { status: 404 },
        SessionError::HttpStatus { status } | SessionError::RedirectNotAllowed { status } => {
            HydrationFailure::HttpStatus { status: *status }
        }
        SessionError::Transport(error) => {
            HydrationFailure::Connection(ConnectionFailure::Transport(error.clone()))
        }
        SessionError::Cancelled => {
            HydrationFailure::Connection(ConnectionFailure::Transport(TransportError::Cancelled))
        }
        other => HydrationFailure::Malformed {
            message: other.to_string(),
        },
    }
}

impl Engine {
    pub(crate) fn open_session(&mut self, session_id: &str) {
        if !self.drivers.contains_key(session_id) {
            let machine = (!self.is_demo()).then(|| {
                SessionStream::new(StreamConfig::default(), Self::seeded(&mut self.jitter))
            });
            let instance = DriverInstance(self.next_driver);
            self.next_driver += 1;
            self.drivers.insert(
                session_id.to_owned(),
                SessionDriver {
                    instance,
                    sync: ConversationSync::create(session_id),
                    machine,
                    handles: HashMap::new(),
                    timers: HashMap::new(),
                    live_attempt: None,
                    revision: 0,
                    terminals: omnigent_core::terminal::TerminalInventory::new(session_id),
                    terminal_view: None,
                    terminal_tick: None,
                    stream_keyed: false,
                    paging: None,
                },
            );
        }
        self.emit_reset(session_id);
        if !self.is_connected() {
            return;
        }
        if self.is_demo() {
            if let Some(driver) = self.drivers.get(session_id) {
                let request = driver.sync.open_stream_raw();
                self.spawn_hydration(session_id, None, request);
            }
        } else {
            self.stream_input(session_id, StreamInput::Start);
        }
    }

    fn emit_reset(&mut self, session_id: &str) {
        if let Some(driver) = self.drivers.get_mut(session_id) {
            driver.paging = None;
        }
        self.emit_transcript_reset(session_id);
        self.emit_paging(session_id);
    }

    fn emit_transcript_reset(&self, session_id: &str) {
        let Some(driver) = self.drivers.get(session_id) else {
            return;
        };
        self.emit(CoreEvent::TranscriptReset {
            session_id: session_id.to_owned(),
            revision: driver.revision,
            rows: driver.sync.rows(),
            header: driver.sync.header(),
            sections: driver.sync.sections(),
            decisions: driver.sync.decisions(),
        });
    }

    pub(crate) fn close_session(&mut self, session_id: &str) {
        self.stream_input(session_id, StreamInput::Stop);
        let Some(driver) = self.drivers.remove(session_id) else {
            return;
        };
        for timer in driver.timers.values() {
            timer.abort();
        }
        if let Some(tick) = &driver.terminal_tick {
            tick.abort();
        }
        for handle in driver.handles.values() {
            handle.cancel();
        }
        driver.sync.stop_raw();
        self.sessions.set_live_session(session_id, false);
    }

    /// Whether `session_id` is still open under the opening that `instance` names.
    pub(crate) fn is_current_driver(&self, session_id: &str, instance: DriverInstance) -> bool {
        self.drivers
            .get(session_id)
            .is_some_and(|driver| driver.instance == instance)
    }

    /// A stream input from a sink or timer, dropped when its opening has closed.
    pub(crate) fn stream_message(
        &mut self,
        session_id: &str,
        driver: DriverInstance,
        input: StreamInput,
    ) {
        if self.is_current_driver(session_id, driver) {
            self.stream_input(session_id, input);
        }
    }

    pub(crate) fn stream_input(&mut self, session_id: &str, input: StreamInput) {
        let now = self.host.now_ms();
        // A stream refused with 400 reached the wrong replica: re-address the next attempt.
        if let StreamInput::Response { head, .. } = &input
            && head.status == 400
        {
            let keyed = self
                .drivers
                .get(session_id)
                .is_some_and(|driver| driver.stream_keyed);
            self.sessions
                .stream_refused(&format!("/v1/sessions/{session_id}/stream"), keyed);
        }
        let Some(machine) = self
            .drivers
            .get_mut(session_id)
            .and_then(|driver| driver.machine.as_mut())
        else {
            return;
        };
        let outputs = machine.handle(now, input);
        for output in outputs {
            self.stream_output(session_id, output);
        }
    }

    fn stream_output(&mut self, session_id: &str, output: StreamOutput) {
        match output {
            StreamOutput::Open { attempt } => self.open_stream(session_id, attempt),
            StreamOutput::Cancel { attempt } => {
                if let Some(handle) = self
                    .drivers
                    .get_mut(session_id)
                    .and_then(|driver| driver.handles.remove(&attempt))
                {
                    handle.cancel();
                }
            }
            StreamOutput::ScheduleTimer { token, delay_ms } => {
                let Some(driver) = self.drivers.get(session_id).map(|driver| driver.instance)
                else {
                    return;
                };
                let tx = self.sender();
                let id = session_id.to_owned();
                let timer = self.host.after(delay_ms, move || {
                    post(
                        &tx,
                        Msg::Stream {
                            session_id: id,
                            driver,
                            input: StreamInput::TimerFired { token },
                        },
                    );
                });
                if let Some(driver) = self.drivers.get_mut(session_id) {
                    driver.timers.insert(token.id, timer);
                }
            }
            StreamOutput::CancelTimer { token } => {
                if let Some(timer) = self
                    .drivers
                    .get_mut(session_id)
                    .and_then(|driver| driver.timers.remove(&token.id))
                {
                    timer.abort();
                }
            }
            StreamOutput::StateChanged { state } => self.stream_state(session_id, state),
            StreamOutput::Ready { attempt, .. } => {
                let Some(driver) = self.drivers.get_mut(session_id) else {
                    return;
                };
                driver.live_attempt = Some(attempt);
                let request = driver.sync.open_stream_raw();
                self.spawn_hydration(session_id, Some(attempt), request);
            }
            StreamOutput::Event { attempt, event } => self.stream_event(session_id, attempt, event),
        }
    }

    fn open_stream(&mut self, session_id: &str, attempt: AttemptId) {
        let (Some(link), Some(streams)) = (self.link.clone(), self.transports.streams.clone())
        else {
            return;
        };
        let path = format!("/v1/sessions/{session_id}/stream");
        let slice_key = self.sessions.slice_key(&path);
        let Some(driver) = self.drivers.get_mut(session_id) else {
            return;
        };
        driver.stream_keyed = slice_key.is_some();
        let instance = driver.instance;
        let request = match link.endpoint.request_with(
            "GET",
            &path,
            &[],
            "text/event-stream",
            link.bearer.as_ref(),
        ) {
            Ok(mut request) => {
                if let Some(key) = slice_key {
                    request.headers.push(core::http::HttpHeader::new(
                        omnigent_core::SLICE_KEY_HEADER,
                        key,
                    ));
                }
                request
            }
            Err(error) => {
                self.error(
                    ErrorScope::Session {
                        session_id: session_id.to_owned(),
                    },
                    error.clone().into(),
                );
                self.stream_input(
                    session_id,
                    StreamInput::OpenFailed {
                        attempt,
                        error: core::http::TransportError::Other {
                            message: error.to_string(),
                        },
                    },
                );
                return;
            }
        };
        let tx = self.sender();
        let id = session_id.to_owned();
        let sink = ByteSink::new(move |event| {
            let input = match event {
                SinkEvent::Response(head) => StreamInput::Response { attempt, head },
                SinkEvent::Chunk(bytes) => StreamInput::Chunk { attempt, bytes },
                SinkEvent::Finished(result) => StreamInput::Finished { attempt, result },
            };
            post(
                &tx,
                Msg::Stream {
                    session_id: id.clone(),
                    driver: instance,
                    input,
                },
            );
        });
        match streams.open_stream(request.into(), sink) {
            Ok(handle) => {
                if let Some(driver) = self.drivers.get_mut(session_id) {
                    driver.handles.insert(attempt, handle);
                } else {
                    handle.cancel();
                }
            }
            Err(error) => self.stream_input(
                session_id,
                StreamInput::OpenFailed {
                    attempt,
                    error: error.into(),
                },
            ),
        }
    }

    fn stream_state(&mut self, session_id: &str, state: ConnectionState) {
        let live = matches!(state, ConnectionState::Live);
        if !live && !matches!(state, ConnectionState::Connecting) {
            if let Some(driver) = self.drivers.get_mut(session_id) {
                driver.live_attempt = None;
                driver.sync.close_stream_raw();
            }
            self.sessions.set_live_session(session_id, false);
        }
        let sign_in = match &state {
            ConnectionState::Failed { error } if error.requires_sign_in() => {
                Some(CoreError::from(error.clone()))
            }
            _ => None,
        };
        self.emit(CoreEvent::SessionLinkChanged {
            session_id: session_id.to_owned(),
            state: state.into(),
        });
        if let Some(reason) = sign_in {
            self.sign_in_lost(reason);
        }
    }

    fn stream_event(
        &mut self,
        session_id: &str,
        attempt: AttemptId,
        event: core::realtime::StreamEvent,
    ) {
        let Some(driver) = self.drivers.get(session_id) else {
            return;
        };
        let value = event.into_value();
        let decoded = reducer::decode_event(value.clone(), session_id);
        let sync = Arc::clone(&driver.sync);
        if let Ok(Some(decoded)) = &decoded {
            // An undecodable event is reported by the sync below; this only stamps metadata.
            self.sessions.record_stream_event(session_id, decoded);
        }
        let applied = sync.handle_event_raw(value);
        if let Ok(Some(decoded)) = &decoded {
            self.terminal_event(session_id, decoded);
        }
        match applied {
            Ok(applied) => self.publish(session_id, applied),
            Err(SyncError::BufferOverflow { limit }) => {
                sync.close_stream_raw();
                self.stream_input(
                    session_id,
                    StreamInput::HydrationFailed {
                        attempt,
                        failure: HydrationFailure::Connection(ConnectionFailure::Transport(
                            core::http::TransportError::Other {
                                message: format!(
                                    "more than {limit} events arrived while history loaded"
                                ),
                            },
                        )),
                    },
                );
            }
            Err(error) => self.error(
                ErrorScope::Session {
                    session_id: session_id.to_owned(),
                },
                crate::errors::core_error(error),
            ),
        }
    }

    pub(crate) fn request_hydration(&self, session_id: &str) {
        let Some(driver) = self.drivers.get(session_id) else {
            return;
        };
        if let Some(request) = driver.sync.request_hydration_raw() {
            let attempt = driver.live_attempt;
            self.spawn_hydration(session_id, attempt, request);
        }
    }

    fn spawn_hydration(
        &self,
        session_id: &str,
        attempt: Option<AttemptId>,
        request: HydrationRequest,
    ) {
        let Some(driver) = self.drivers.get(session_id).map(|driver| driver.instance) else {
            return;
        };
        let sessions = Arc::clone(&self.sessions);
        let tx = self.sender();
        let id = session_id.to_owned();
        self.host.spawn(async move {
            let result = sessions.conversation_snapshot(&id).await;
            post(
                &tx,
                Msg::Hydrated {
                    session_id: id,
                    driver,
                    attempt,
                    request,
                    result: Box::new(result),
                },
            );
        });
    }

    pub(crate) fn hydrated(
        &mut self,
        session_id: &str,
        instance: DriverInstance,
        attempt: Option<AttemptId>,
        request: &HydrationRequest,
        result: Result<ConversationPage, SessionError>,
    ) {
        let Some(driver) = self
            .drivers
            .get(session_id)
            .filter(|driver| driver.instance == instance)
        else {
            return;
        };
        let scope = ErrorScope::Session {
            session_id: session_id.to_owned(),
        };
        let failure = match result {
            Ok(page) => match driver.sync.finish_hydration_raw(
                request,
                &page.snapshot,
                &page.items,
                page.next_cursor.as_deref(),
            ) {
                Ok(applied) => {
                    let current = attempt.is_none() || driver.live_attempt == attempt;
                    if current {
                        self.sessions.set_live_session(session_id, true);
                    }
                    // The rows first: an app told "hydrated" before they land shows an empty
                    // session for a moment.
                    self.publish(session_id, applied);
                    if current {
                        self.emit(CoreEvent::SessionHydrated {
                            session_id: session_id.to_owned(),
                        });
                    }
                    self.emit_paging(session_id);
                    self.terminals_after_hydration(session_id);
                    return;
                }
                Err(error) => {
                    let failure = HydrationFailure::Malformed {
                        message: error.to_string(),
                    };
                    self.error(scope, error);
                    failure
                }
            },
            Err(error) => {
                let failure = hydration_failure(&error);
                let error = CoreError::from(error);
                if !error.requires_sign_in() {
                    self.error(scope, error);
                }
                failure
            }
        };
        let current = driver.sync.hydration_failed_raw(request);
        self.sessions.set_live_session(session_id, false);
        if let (true, Some(attempt)) = (current, attempt) {
            self.stream_input(
                session_id,
                StreamInput::HydrationFailed { attempt, failure },
            );
        }
    }

    /// Reports what one sync input changed and starts the work it asks for.
    pub(crate) fn publish(&mut self, session_id: &str, applied: Applied) {
        if let Some(driver) = self.drivers.get_mut(session_id) {
            driver.revision = applied.revision;
        }
        if let Some(change) = applied.change {
            self.emit(CoreEvent::TranscriptChanged {
                session_id: session_id.to_owned(),
                revision: applied.revision,
                change,
            });
        }
        if let Some(decisions) = applied.decisions {
            self.emit(CoreEvent::DecisionsChanged {
                session_id: session_id.to_owned(),
                decisions,
            });
        }
        if let Some(message) = applied.effects.error {
            self.emit(CoreEvent::SessionFailure {
                session_id: session_id.to_owned(),
                message,
            });
        }
        if let Some(request) = applied.effects.browser_action {
            let request = crate::browser::BrowserActionRequest::from(request);
            self.emit(CoreEvent::BrowserActionRequested {
                session_id: request.session_id,
                action_id: request.action_id,
                action: request.action,
                args_json: request.args_json,
            });
        }
        if let Some(environment) = applied.effects.changed_files_environment {
            let sessions = Arc::clone(&self.sessions);
            let id = session_id.to_owned();
            self.host.spawn(async move {
                sessions.invalidate_changed_files(&id, &environment).await;
            });
        }
        if let Some(request) = applied.hydrate {
            let attempt = self
                .drivers
                .get(session_id)
                .and_then(|driver| driver.live_attempt);
            self.spawn_hydration(session_id, attempt, request);
        }
    }

    /// Session-list rows for the open sessions (a `snapshot` or `changed` frame).
    pub(crate) fn sync_list_rows(&mut self, rows: &[omnigent_protocol::SessionListItem]) {
        let ids: Vec<String> = self.drivers.keys().cloned().collect();
        for id in ids {
            let Some(driver) = self.drivers.get(&id) else {
                continue;
            };
            match driver.sync.handle_list_rows_raw(rows) {
                Ok(applied) => {
                    self.publish(&id, applied);
                    self.publish_terminals(&id);
                }
                Err(error) => self.error(
                    ErrorScope::Session {
                        session_id: id.clone(),
                    },
                    error,
                ),
            }
        }
    }

    /// A `removed` frame: open sessions among `ids` close.
    pub(crate) fn sync_removed(&mut self, ids: &[String]) {
        let open: Vec<String> = self.drivers.keys().cloned().collect();
        for id in open {
            let removed = self
                .drivers
                .get(&id)
                .is_some_and(|driver| driver.sync.handle_removed_raw(ids));
            if removed {
                self.close_session(&id);
                self.emit(CoreEvent::SessionClosed { session_id: id });
            }
        }
    }
}
