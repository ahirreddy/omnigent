//! `WS /v1/sessions/updates`: the machine's outputs executed through the host's WebSocket
//! transport, and its frames fed to the REST client, the open syncs and the attention tracker.

use std::sync::Arc;

use futures::StreamExt;
use futures::channel::mpsc::{self, UnboundedSender};
use omnigent_core::realtime::{
    AttemptId, ConnectionState, UpdatesFrame, UpdatesInput, UpdatesOutput,
};
use omnigent_protocol::{FromWire, SessionListItem};
use serde_json::Value;

use crate::engine::{Engine, Msg};
use crate::errors::{CoreError, core_error};
use crate::events::{CoreEvent, ErrorScope};
use crate::host::{MessageSink, SocketEvent, WebSocketHandle};
use crate::runtime::post;

/// The socket for the current attempt.
pub(crate) struct Socket {
    attempt: AttemptId,
    handle: Option<Arc<dyn WebSocketHandle>>,
    /// Frames to send, in order; a writer task drains it.
    outbox: Option<UnboundedSender<String>>,
}

impl Engine {
    pub(crate) fn start_updates(&mut self) {
        if self.transports.sockets.is_none() {
            return;
        }
        self.updates_input(UpdatesInput::Start);
        self.update_watch();
    }

    pub(crate) fn stop_updates(&mut self) {
        self.updates_input(UpdatesInput::Stop);
        for timer in self.updates_timers.values() {
            timer.abort();
        }
        self.updates_timers.clear();
    }

    pub(crate) fn updates_input(&mut self, input: UpdatesInput) {
        let now = self.host.now_ms();
        let outputs = self.updates.handle(now, input);
        self.run_updates_outputs(outputs);
    }

    pub(crate) fn run_updates_outputs(&mut self, outputs: Vec<UpdatesOutput>) {
        for output in outputs {
            self.updates_output(output);
        }
    }

    fn updates_output(&mut self, output: UpdatesOutput) {
        match output {
            UpdatesOutput::Connect { attempt } => self.connect_socket(attempt),
            UpdatesOutput::Send { attempt, text } => {
                if let Some(outbox) = self
                    .socket
                    .as_ref()
                    .filter(|socket| socket.attempt == attempt)
                    .and_then(|socket| socket.outbox.as_ref())
                {
                    post(outbox, text);
                }
            }
            UpdatesOutput::Close {
                attempt,
                code,
                reason,
            } => {
                if let Some(socket) = self.socket.take() {
                    if socket.attempt == attempt {
                        if let Some(handle) = &socket.handle {
                            handle.close(code, reason);
                        }
                    } else {
                        self.socket = Some(socket);
                    }
                }
            }
            UpdatesOutput::ScheduleTimer { token, delay_ms } => {
                let tx = self.sender();
                let timer = self.host.after(delay_ms, move || {
                    post(&tx, Msg::Updates(UpdatesInput::TimerFired { token }));
                });
                self.updates_timers.insert(token.id, timer);
            }
            UpdatesOutput::CancelTimer { token } => {
                if let Some(timer) = self.updates_timers.remove(&token.id) {
                    timer.abort();
                }
            }
            UpdatesOutput::StateChanged { state } => {
                let sign_in = match &state {
                    ConnectionState::Failed { error } if error.requires_sign_in() => {
                        Some(CoreError::from(error.clone()))
                    }
                    _ => None,
                };
                self.emit(CoreEvent::UpdatesLinkChanged {
                    state: state.into(),
                });
                if let Some(reason) = sign_in {
                    self.sign_in_lost(reason);
                }
            }
            UpdatesOutput::Live { resumed, .. } => {
                if resumed {
                    self.refresh_list();
                }
            }
            UpdatesOutput::Frame { frame } => self.updates_frame(frame),
            UpdatesOutput::DiscoveryNotWatched { error, .. } => {
                self.error(ErrorScope::SessionList, core_error(error));
                self.refresh_list();
            }
        }
    }

    fn connect_socket(&mut self, attempt: AttemptId) {
        let (Some(link), Some(sockets)) = (self.link.clone(), self.transports.sockets.clone())
        else {
            return;
        };
        let path = "/v1/sessions/updates";
        // On a host-sharded server the socket carries the modal host as its routing key.
        let slice_key = self.sessions.modal_slice_key();
        let query: Vec<(&str, &str)> = slice_key
            .as_deref()
            .map(|key| vec![(omnigent_core::SLICE_KEY_QUERY, key)])
            .unwrap_or_default();
        let request = link
            .endpoint
            .request_with("GET", path, &[], "application/json", link.bearer.as_ref())
            .and_then(|mut request| {
                request.url = link.endpoint.websocket_url(path, &query)?;
                Ok(request)
            });
        let request = match request {
            Ok(request) => request,
            Err(error) => {
                let message = error.to_string();
                self.error(ErrorScope::SessionList, error.into());
                self.updates_input(UpdatesInput::ConnectFailed {
                    attempt,
                    error: omnigent_core::http::TransportError::Other { message },
                });
                return;
            }
        };
        let tx = self.sender();
        let sink = MessageSink::new(move |event| {
            let input = match event {
                SocketEvent::Opened => UpdatesInput::Opened { attempt },
                SocketEvent::Message(message) => UpdatesInput::Message { attempt, message },
                SocketEvent::Ended(end) => UpdatesInput::Ended { attempt, end },
            };
            post(&tx, Msg::Updates(input));
        });
        let handle = match sockets.open_socket(request.into(), sink) {
            Ok(handle) => handle,
            Err(error) => {
                self.updates_input(UpdatesInput::ConnectFailed {
                    attempt,
                    error: error.into(),
                });
                return;
            }
        };
        let (outbox, mut queued) = mpsc::unbounded::<String>();
        self.socket = Some(Socket {
            attempt,
            handle: Some(Arc::clone(&handle)),
            outbox: Some(outbox),
        });
        let tx = self.sender();
        self.host.spawn(async move {
            while let Some(text) = queued.next().await {
                if let Err(error) = handle.send_text(text).await {
                    post(
                        &tx,
                        Msg::Updates(UpdatesInput::SendFailed {
                            attempt,
                            error: error.into(),
                        }),
                    );
                    break;
                }
            }
        });
    }

    fn updates_frame(&mut self, frame: UpdatesFrame) {
        match frame {
            UpdatesFrame::Snapshot { rows } | UpdatesFrame::Changed { rows } => {
                let raw: Vec<Value> = rows
                    .into_iter()
                    .map(|row| Value::Object(row.into_raw()))
                    .collect();
                // An unreadable row is reported once, by the list below.
                let decoded: Vec<SessionListItem> = raw
                    .iter()
                    .filter_map(|row| SessionListItem::from_value(row.clone()).ok())
                    .collect();
                if let Err(error) = self.sessions.apply_session_rows(raw) {
                    self.error(ErrorScope::SessionList, error.into());
                }
                self.sync_list_rows(&decoded);
                self.attention_rows(decoded);
            }
            UpdatesFrame::Removed { ids } => {
                self.sessions.remove_sessions(&ids);
                self.sync_removed(&ids);
                self.attention_removed(&ids);
            }
            UpdatesFrame::HostsChanged => self.emit(CoreEvent::HostsChanged),
            UpdatesFrame::ProjectsChanged => self.emit(CoreEvent::ProjectsChanged),
            UpdatesFrame::Heartbeat => {}
            UpdatesFrame::Unknown { frame_type, .. } => {
                self.emit(CoreEvent::UnknownUpdate { frame_type });
            }
        }
    }
}

#[cfg(test)]
#[path = "updates_driver_tests.rs"]
mod tests;
