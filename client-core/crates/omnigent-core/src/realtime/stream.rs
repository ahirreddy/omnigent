//! `GET /v1/sessions/{id}/stream` connection state machine.
//!
//! [`SessionStream`] owns one session's live tail across reconnects. It parses SSE bytes
//! itself, using [`crate::sse::SseParser`], so chunk boundaries never matter to its callers.
//!
//! Behaviour, from `docs/wire-contract.md` §3 and §5.9:
//!
//! - **Open.** A 2xx `text/event-stream` response is accepted. A 3xx, 401 or 403 fails for good
//!   (401 and 403 ask for sign-in again). A 404 is retried up to
//!   [`super::RetryConfig::max_not_found_retries`] times in a row. Any other status, or a 2xx
//!   with another content type, retries with backoff.
//! - **Ready.** The first decoded event is the server's ready `session.heartbeat` on a current
//!   server, though any event counts. It moves the stream to [`ConnectionState::Live`] and
//!   emits [`StreamOutput::Ready`]. Heartbeats (`session.heartbeat`, `response.heartbeat`) only
//!   prove liveness and are not forwarded. Every other event is forwarded as
//!   [`StreamOutput::Event`].
//! - **`[DONE]` vs EOF.** `data: [DONE]` is an intentional close: the attempt is cancelled and
//!   the stream becomes [`ConnectionState::Closed`] with no reconnect. EOF without `[DONE]` (a
//!   server shutdown, a subscriber overflow, a proxy recycle) reconnects.
//! - **Stall watchdog.** If no byte arrives for [`StreamConfig::stall_timeout_ms`] (45 s, three
//!   missed 15 s heartbeats), the attempt is cancelled and reconnected. The watchdog also
//!   covers an open that never gets a response.
//! - **Backoff.** See [`super::backoff`]: losing a stream that was live for at least 5 s
//!   reconnects immediately. Otherwise the jittered 250 ms to 5 s ramp applies.
//! - **Malformed input.** A framing error or an event whose data is not a JSON object with a
//!   `type` ends the attempt, and a fresh connection resynchronises it. It is never skipped.

use serde_json::{Map, Value};

use super::backoff::{JitterSource, Retry, RetryConfig, RetryDecision};
use super::host::{ConnectionFailure, StreamResponseHead};
use super::link::{
    AttemptId, ConnectionState, HydrationFailure, Ids, LinkError, TimerKind, TimerToken,
};
use crate::http::TransportError;
use crate::sse::{SseEvent, SseLimits, SseParser};

/// Event types that only prove the stream is alive.
pub const HEARTBEAT_EVENT_TYPES: [&str; 2] = ["session.heartbeat", "response.heartbeat"];

/// Tunables for [`SessionStream`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamConfig {
    /// Reconnect policy.
    pub retry: RetryConfig,
    /// Silence, in ms, after which the stream is declared stalled. The default is 45 s
    /// (`SSE_STALL_TIMEOUT_MS` in `web/src/lib/sse.ts`).
    pub stall_timeout_ms: u64,
    /// SSE line and event caps.
    pub limits: SseLimits,
}

impl Default for StreamConfig {
    fn default() -> Self {
        Self {
            retry: RetryConfig::default(),
            stall_timeout_ms: 45_000,
            limits: SseLimits::default(),
        }
    }
}

/// One decoded stream event. `data` is the SSE `data:` JSON object, and it always holds a
/// string `type` equal to `event_type`. When the server omitted `type`, it is filled in from
/// the SSE `event:` name.
///
/// Wave 1 decodes this into WP1's typed `ServerStreamEvent` (unknown types become
/// `Unknown { type, raw }`). Until then consumers read the JSON directly.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamEvent {
    /// The event type, for example `response.output_text.delta`.
    pub event_type: String,
    /// The full payload, including `type`.
    pub data: Map<String, Value>,
}

impl StreamEvent {
    /// Whether this event only proves liveness.
    #[must_use]
    pub fn is_heartbeat(&self) -> bool {
        HEARTBEAT_EVENT_TYPES.contains(&self.event_type.as_str())
    }

    /// The payload as a JSON value.
    #[must_use]
    pub fn into_value(self) -> Value {
        Value::Object(self.data)
    }

    /// Decodes one SSE event.
    ///
    /// # Errors
    ///
    /// Returns a description when `data` is not a JSON object, when its `type` is not a string,
    /// or when the frame has neither a `type` nor an `event:` name.
    pub fn decode(event: SseEvent) -> Result<Self, String> {
        let name = event.event.as_deref().unwrap_or("unnamed");
        let value: Value = serde_json::from_str(&event.data)
            .map_err(|error| format!("{name} frame data is not JSON: {error}"))?;
        let Value::Object(mut data) = value else {
            return Err(format!("{name} frame data is not a JSON object"));
        };
        let event_type = match data.get("type") {
            Some(Value::String(event_type)) => event_type.clone(),
            Some(other) => {
                return Err(format!("{name} frame has a non-string type: {other}"));
            }
            None => {
                let Some(event_type) = event.event else {
                    return Err("frame has neither an event name nor a data type".to_owned());
                };
                data.insert("type".to_owned(), Value::String(event_type.clone()));
                event_type
            }
        };
        Ok(Self { event_type, data })
    }
}

/// Inputs to [`SessionStream::handle`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StreamInput {
    /// Start (or restart after `Stopped`, `Closed` or `Failed`) with a fresh backoff ramp. This
    /// does nothing while already connecting, live or reconnecting.
    Start,
    /// Stop and cancel everything.
    Stop,
    /// [`super::EventStreamTransport::open`] resolved `Err`.
    OpenFailed {
        /// The attempt it was opening.
        attempt: AttemptId,
        /// The host's error.
        error: TransportError,
    },
    /// [`super::ByteSink::response`].
    Response {
        /// The attempt the sink belongs to.
        attempt: AttemptId,
        /// Status and headers.
        head: StreamResponseHead,
    },
    /// [`super::ByteSink::chunk`].
    Chunk {
        /// The attempt the sink belongs to.
        attempt: AttemptId,
        /// Body bytes.
        bytes: Vec<u8>,
    },
    /// [`super::ByteSink::finish`].
    Finished {
        /// The attempt the sink belongs to.
        attempt: AttemptId,
        /// EOF or the failure.
        result: Result<(), ConnectionFailure>,
    },
    /// The hydration handoff for this attempt failed. Transient failures reconnect the stream;
    /// 401 and 403 fail it.
    HydrationFailed {
        /// The attempt whose [`StreamOutput::Ready`] started the hydration.
        attempt: AttemptId,
        /// What went wrong.
        failure: HydrationFailure,
    },
    /// A timer scheduled with [`StreamOutput::ScheduleTimer`] fired.
    TimerFired {
        /// Its token.
        token: TimerToken,
    },
}

/// Work for the driver, returned by [`SessionStream::handle`] in execution order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StreamOutput {
    /// Build the stream request (with fresh credentials) and open it with a sink for `attempt`.
    Open {
        /// The new attempt.
        attempt: AttemptId,
    },
    /// Cancel the stream opened for `attempt`.
    Cancel {
        /// The attempt to cancel.
        attempt: AttemptId,
    },
    /// Deliver [`StreamInput::TimerFired`] with `token` after `delay_ms`.
    ScheduleTimer {
        /// The token to deliver.
        token: TimerToken,
        /// The delay from the current `now_ms`.
        delay_ms: u64,
    },
    /// The timer `token` is no longer needed.
    CancelTimer {
        /// Its token.
        token: TimerToken,
    },
    /// The public connection state changed.
    StateChanged {
        /// The new state.
        state: ConnectionState,
    },
    /// The attempt is live: the server registered the subscriber. This is where the hydration
    /// handoff starts.
    Ready {
        /// The live attempt.
        attempt: AttemptId,
        /// An earlier attempt of this machine was live, so events may have been missed and
        /// history must be reconciled (contract §5.2).
        resumed: bool,
    },
    /// A stream event, in arrival order. Heartbeats are not forwarded.
    Event {
        /// The attempt it arrived on.
        attempt: AttemptId,
        /// The event.
        event: StreamEvent,
    },
}

#[derive(Debug, Clone)]
struct Attempt {
    id: AttemptId,
    parser: SseParser,
    accepted: bool,
    ready_at_ms: Option<u64>,
    last_activity_ms: u64,
    watchdog: Option<TimerToken>,
}

/// Pure state machine for one session's SSE stream. See the [module docs](self).
#[derive(Debug, Clone)]
pub struct SessionStream<J> {
    config: StreamConfig,
    jitter: J,
    ids: Ids,
    retry: Retry,
    state: ConnectionState,
    attempt: Option<Attempt>,
    reconnect_timer: Option<TimerToken>,
    ever_ready: bool,
}

impl<J: JitterSource> SessionStream<J> {
    /// An idle machine. Nothing happens until [`StreamInput::Start`].
    pub fn new(config: StreamConfig, jitter: J) -> Self {
        Self {
            config,
            jitter,
            ids: Ids::default(),
            retry: Retry::new(config.retry),
            state: ConnectionState::Idle,
            attempt: None,
            reconnect_timer: None,
            ever_ready: false,
        }
    }

    /// The current public state.
    pub const fn state(&self) -> &ConnectionState {
        &self.state
    }

    /// The attempt in flight, if any.
    pub fn current_attempt(&self) -> Option<AttemptId> {
        self.attempt.as_ref().map(|attempt| attempt.id)
    }

    /// Applies one input at `now_ms` (from the host [`super::Clock`]) and returns the work it
    /// causes, in order. Inputs for a stale attempt or timer return nothing.
    pub fn handle(&mut self, now_ms: u64, input: StreamInput) -> Vec<StreamOutput> {
        let mut out = Vec::new();
        match input {
            StreamInput::Start => self.start(now_ms, &mut out),
            StreamInput::Stop => self.stop(&mut out),
            StreamInput::OpenFailed { attempt, error } => {
                if self.is_current(attempt) {
                    let error = LinkError::Connection(ConnectionFailure::Transport(error));
                    self.lose(now_ms, error, false, &mut out);
                }
            }
            StreamInput::Response { attempt, head } => {
                if self.is_current(attempt) {
                    self.on_response(now_ms, &head, &mut out);
                }
            }
            StreamInput::Chunk { attempt, bytes } => {
                if self.is_current(attempt) {
                    self.on_chunk(now_ms, &bytes, &mut out);
                }
            }
            StreamInput::Finished { attempt, result } => {
                if self.is_current(attempt) {
                    self.on_finished(now_ms, result, &mut out);
                }
            }
            StreamInput::HydrationFailed { attempt, failure } => {
                if self.is_current(attempt) {
                    self.lose(now_ms, LinkError::Hydration(failure), true, &mut out);
                }
            }
            StreamInput::TimerFired { token } => self.on_timer(now_ms, token, &mut out),
        }
        out
    }

    fn is_current(&self, attempt: AttemptId) -> bool {
        self.current_attempt() == Some(attempt)
    }

    fn start(&mut self, now_ms: u64, out: &mut Vec<StreamOutput>) {
        match self.state {
            ConnectionState::Connecting
            | ConnectionState::Live
            | ConnectionState::Reconnecting { .. } => {}
            ConnectionState::Idle
            | ConnectionState::Closed
            | ConnectionState::Stopped
            | ConnectionState::Failed { .. } => {
                self.retry.reset();
                self.set_state(ConnectionState::Connecting, out);
                self.open_attempt(now_ms, out);
            }
        }
    }

    fn stop(&mut self, out: &mut Vec<StreamOutput>) {
        self.end_attempt(true, out);
        if let Some(token) = self.reconnect_timer.take() {
            out.push(StreamOutput::CancelTimer { token });
        }
        self.set_state(ConnectionState::Stopped, out);
    }

    fn on_response(&mut self, now_ms: u64, head: &StreamResponseHead, out: &mut Vec<StreamOutput>) {
        let Some(attempt) = self.attempt.as_mut() else {
            return;
        };
        attempt.last_activity_ms = now_ms;
        let error = if attempt.accepted {
            Some(LinkError::HostContract {
                message: "a second response head arrived for one stream".to_owned(),
            })
        } else if !(200..=299).contains(&head.status) {
            Some(LinkError::HttpStatus {
                status: head.status,
            })
        } else {
            let content_type = head.header("content-type");
            let is_event_stream = content_type.is_some_and(|value| {
                value
                    .split(';')
                    .next()
                    .is_some_and(|media| media.trim().eq_ignore_ascii_case("text/event-stream"))
            });
            (!is_event_stream).then(|| LinkError::UnexpectedContentType {
                content_type: content_type.map(str::to_owned),
            })
        };
        match error {
            Some(error) => self.lose(now_ms, error, true, out),
            None => attempt.accepted = true,
        }
    }

    fn on_chunk(&mut self, now_ms: u64, bytes: &[u8], out: &mut Vec<StreamOutput>) {
        let Some(attempt) = self.attempt.as_mut() else {
            return;
        };
        if !attempt.accepted {
            let error = LinkError::HostContract {
                message: "body bytes arrived before an accepted response head".to_owned(),
            };
            self.lose(now_ms, error, true, out);
            return;
        }
        if bytes.is_empty() {
            return;
        }
        attempt.last_activity_ms = now_ms;
        let id = attempt.id;
        let mut events = Vec::new();
        let parsed = attempt.parser.push(bytes, &mut events);
        for sse in events {
            if sse.is_done() {
                self.end_attempt(true, out);
                self.set_state(ConnectionState::Closed, out);
                return;
            }
            match StreamEvent::decode(sse) {
                Ok(event) => {
                    self.mark_ready(now_ms, out);
                    if !event.is_heartbeat() {
                        out.push(StreamOutput::Event { attempt: id, event });
                    }
                }
                Err(message) => {
                    self.lose(now_ms, LinkError::MalformedEvent { message }, true, out);
                    return;
                }
            }
        }
        if let Err(error) = parsed {
            self.lose(now_ms, LinkError::Sse(error), true, out);
        }
    }

    fn on_finished(
        &mut self,
        now_ms: u64,
        result: Result<(), ConnectionFailure>,
        out: &mut Vec<StreamOutput>,
    ) {
        let accepted = self
            .attempt
            .as_ref()
            .is_some_and(|attempt| attempt.accepted);
        let error = match result {
            Ok(()) if accepted => LinkError::EndOfStream,
            Ok(()) => LinkError::HostContract {
                message: "stream finished without an accepted response head".to_owned(),
            },
            Err(failure) => LinkError::Connection(failure),
        };
        self.lose(now_ms, error, false, out);
    }

    fn on_timer(&mut self, now_ms: u64, token: TimerToken, out: &mut Vec<StreamOutput>) {
        if self.reconnect_timer == Some(token) {
            self.reconnect_timer = None;
            self.open_attempt(now_ms, out);
            return;
        }
        let Some(attempt) = self.attempt.as_mut() else {
            return;
        };
        if attempt.watchdog != Some(token) {
            return;
        }
        attempt.watchdog = None;
        let silent_ms = now_ms.saturating_sub(attempt.last_activity_ms);
        if silent_ms >= self.config.stall_timeout_ms {
            self.lose(now_ms, LinkError::Stalled { silent_ms }, true, out);
        } else {
            // Fired early relative to the latest activity: wait out the remainder.
            let token = self.ids.timer(TimerKind::Watchdog);
            attempt.watchdog = Some(token);
            out.push(StreamOutput::ScheduleTimer {
                token,
                delay_ms: self.config.stall_timeout_ms - silent_ms,
            });
        }
    }

    fn mark_ready(&mut self, now_ms: u64, out: &mut Vec<StreamOutput>) {
        let Some(attempt) = self.attempt.as_mut() else {
            return;
        };
        if attempt.ready_at_ms.is_some() {
            return;
        }
        attempt.ready_at_ms = Some(now_ms);
        let id = attempt.id;
        self.retry.on_live();
        self.set_state(ConnectionState::Live, out);
        out.push(StreamOutput::Ready {
            attempt: id,
            resumed: self.ever_ready,
        });
        self.ever_ready = true;
    }

    fn open_attempt(&mut self, now_ms: u64, out: &mut Vec<StreamOutput>) {
        let id = self.ids.attempt();
        let watchdog = self.ids.timer(TimerKind::Watchdog);
        self.attempt = Some(Attempt {
            id,
            parser: SseParser::with_limits(self.config.limits),
            accepted: false,
            ready_at_ms: None,
            last_activity_ms: now_ms,
            watchdog: Some(watchdog),
        });
        out.push(StreamOutput::Open { attempt: id });
        out.push(StreamOutput::ScheduleTimer {
            token: watchdog,
            delay_ms: self.config.stall_timeout_ms,
        });
    }

    /// Drops the current attempt. Returns when it went live, if it did.
    fn end_attempt(&mut self, cancel: bool, out: &mut Vec<StreamOutput>) -> Option<u64> {
        let attempt = self.attempt.take()?;
        if cancel {
            out.push(StreamOutput::Cancel {
                attempt: attempt.id,
            });
        }
        if let Some(token) = attempt.watchdog {
            out.push(StreamOutput::CancelTimer { token });
        }
        attempt.ready_at_ms
    }

    /// Ends the current attempt because of `error`, then reconnects or fails.
    fn lose(&mut self, now_ms: u64, error: LinkError, cancel: bool, out: &mut Vec<StreamOutput>) {
        if self.attempt.is_none() {
            return;
        }
        let live_for_ms = self
            .end_attempt(cancel, out)
            .map(|ready_at| now_ms.saturating_sub(ready_at));
        match self.retry.after_loss(&error, live_for_ms, &mut self.jitter) {
            RetryDecision::GiveUp => self.set_state(ConnectionState::Failed { error }, out),
            RetryDecision::Reconnect { delay_ms, failures } => {
                self.set_state(
                    ConnectionState::Reconnecting {
                        reason: error,
                        failures,
                        delay_ms,
                    },
                    out,
                );
                if delay_ms == 0 {
                    self.open_attempt(now_ms, out);
                } else {
                    let token = self.ids.timer(TimerKind::Reconnect);
                    self.reconnect_timer = Some(token);
                    out.push(StreamOutput::ScheduleTimer { token, delay_ms });
                }
            }
        }
    }

    fn set_state(&mut self, state: ConnectionState, out: &mut Vec<StreamOutput>) {
        if self.state != state {
            self.state = state.clone();
            out.push(StreamOutput::StateChanged { state });
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::{Cell, RefCell};
    use std::collections::VecDeque;
    use std::future::{Future, ready};
    use std::rc::Rc;

    use futures::executor::block_on;
    use proptest::prelude::*;

    use super::*;
    use crate::http::{HttpHeader, HttpRequest};
    use crate::realtime::host::{ByteSink, Clock, EventStreamTransport, Scheduler, StreamHandle};
    use crate::realtime::test_support::{FixedJitter, fixture_text, recorded_sse_stream};
    use crate::sse::SseError;

    const HEARTBEAT: &[u8] =
        b"event: session.heartbeat\ndata: {\"type\": \"session.heartbeat\", \"server_time\": null}\n\n";

    struct Harness {
        machine: SessionStream<FixedJitter>,
        now: u64,
    }

    impl Harness {
        fn new() -> Self {
            Self::with_config(StreamConfig::default())
        }

        fn with_config(config: StreamConfig) -> Self {
            Self {
                machine: SessionStream::new(config, FixedJitter(0)),
                now: 1_000,
            }
        }

        fn run(&mut self, input: StreamInput) -> Vec<StreamOutput> {
            self.machine.handle(self.now, input)
        }

        fn advance(&mut self, ms: u64) {
            self.now += ms;
        }

        fn attempt(&self) -> AttemptId {
            self.machine
                .current_attempt()
                .expect("an attempt in flight")
        }

        fn respond(&mut self, status: u16, content_type: &str) -> Vec<StreamOutput> {
            let attempt = self.attempt();
            self.run(StreamInput::Response {
                attempt,
                head: head(status, content_type),
            })
        }

        fn chunk(&mut self, bytes: &[u8]) -> Vec<StreamOutput> {
            let attempt = self.attempt();
            self.run(StreamInput::Chunk {
                attempt,
                bytes: bytes.to_vec(),
            })
        }

        fn finish(&mut self, result: Result<(), ConnectionFailure>) -> Vec<StreamOutput> {
            let attempt = self.attempt();
            self.run(StreamInput::Finished { attempt, result })
        }

        /// Start, accept the response and receive the ready heartbeat.
        fn live(&mut self) -> AttemptId {
            self.run(StreamInput::Start);
            self.accept_and_ready()
        }

        fn accept_and_ready(&mut self) -> AttemptId {
            assert_eq!(self.respond(200, "text/event-stream; charset=utf-8"), []);
            let attempt = self.attempt();
            let outputs = self.chunk(HEARTBEAT);
            assert!(outputs.contains(&StreamOutput::Ready {
                attempt,
                resumed: attempt.0 > 1
            }));
            attempt
        }
    }

    fn head(status: u16, content_type: &str) -> StreamResponseHead {
        StreamResponseHead {
            status,
            headers: vec![HttpHeader::new("Content-Type", content_type)],
        }
    }

    fn events(outputs: &[StreamOutput]) -> Vec<&StreamEvent> {
        outputs
            .iter()
            .filter_map(|output| match output {
                StreamOutput::Event { event, .. } => Some(event),
                _ => None,
            })
            .collect()
    }

    fn scheduled(outputs: &[StreamOutput], kind: TimerKind) -> Vec<(TimerToken, u64)> {
        outputs
            .iter()
            .filter_map(|output| match output {
                StreamOutput::ScheduleTimer { token, delay_ms } if token.kind == kind => {
                    Some((*token, *delay_ms))
                }
                _ => None,
            })
            .collect()
    }

    fn opens(outputs: &[StreamOutput]) -> Vec<AttemptId> {
        outputs
            .iter()
            .filter_map(|output| match output {
                StreamOutput::Open { attempt } => Some(*attempt),
                _ => None,
            })
            .collect()
    }

    fn last_state(outputs: &[StreamOutput]) -> Option<&ConnectionState> {
        outputs.iter().rev().find_map(|output| match output {
            StreamOutput::StateChanged { state } => Some(state),
            _ => None,
        })
    }

    fn offline() -> ConnectionFailure {
        ConnectionFailure::Transport(TransportError::Offline {
            message: "The network connection was lost.".into(),
        })
    }

    #[test]
    fn start_opens_and_arms_the_stall_watchdog() {
        let mut harness = Harness::new();
        let outputs = harness.run(StreamInput::Start);
        let attempt = AttemptId(1);
        assert_eq!(
            outputs,
            [
                StreamOutput::StateChanged {
                    state: ConnectionState::Connecting
                },
                StreamOutput::Open { attempt },
                StreamOutput::ScheduleTimer {
                    token: TimerToken {
                        kind: TimerKind::Watchdog,
                        id: 1
                    },
                    delay_ms: 45_000
                },
            ]
        );
        assert_eq!(harness.run(StreamInput::Start), [], "already running");
    }

    #[test]
    fn recorded_turn_goes_live_and_forwards_every_non_heartbeat_event_in_order() {
        let recorded = recorded_sse_stream("recorded-turn-text-tool-completion.jsonl");
        let mut harness = Harness::new();
        harness.run(StreamInput::Start);
        assert_eq!(harness.respond(200, "text/event-stream"), []);
        let outputs = harness.chunk(&recorded.bytes);
        assert_eq!(
            outputs[..2],
            [
                StreamOutput::StateChanged {
                    state: ConnectionState::Live
                },
                StreamOutput::Ready {
                    attempt: AttemptId(1),
                    resumed: false
                },
            ]
        );
        let forwarded = events(&outputs);
        let expected: Vec<_> = recorded
            .frames
            .iter()
            .filter(|frame| frame.event != "session.heartbeat")
            .collect();
        assert_eq!(forwarded.len(), 18);
        assert_eq!(forwarded.len(), expected.len());
        for (event, frame) in forwarded.iter().zip(expected) {
            assert_eq!(event.event_type, frame.event);
            assert_eq!(Value::Object(event.data.clone()), frame.data);
        }
        assert_eq!(harness.machine.state(), &ConnectionState::Live);
        // The recorded turn ends idle with no [DONE]: the stream stays open.
        assert_eq!(harness.machine.current_attempt(), Some(AttemptId(1)));
    }

    // Port of HostedServerAuthenticationTests.swift::testSSEUnauthorizedStopsAndPublishesSignInAgainWithoutRetry.
    #[test]
    fn sse_unauthorized_stops_and_publishes_sign_in_again_without_retry() {
        let envelope: Value = serde_json::from_str(&fixture_text(
            "sse/HostedServerAuthentication--SSEUnauthorizedStopsAndPublishesSignInAgainWithoutRetry.json",
        ))
        .unwrap();
        assert!(
            envelope["request"]["path"]
                .as_str()
                .unwrap()
                .ends_with("/v1/sessions/a/stream")
        );
        let status = u16::try_from(envelope["status"].as_u64().unwrap()).unwrap();

        let mut harness = Harness::new();
        let start = harness.run(StreamInput::Start);
        let watchdog = scheduled(&start, TimerKind::Watchdog)[0].0;
        let outputs = harness.respond(status, "application/json");
        let error = LinkError::HttpStatus { status: 401 };
        assert_eq!(
            outputs,
            [
                StreamOutput::Cancel {
                    attempt: AttemptId(1)
                },
                StreamOutput::CancelTimer { token: watchdog },
                StreamOutput::StateChanged {
                    state: ConnectionState::Failed {
                        error: error.clone()
                    }
                },
            ]
        );
        assert!(error.requires_sign_in());
        // Nothing reconnects: late callbacks and timers are inert.
        harness.advance(60_000);
        assert_eq!(
            harness.run(StreamInput::Finished {
                attempt: AttemptId(1),
                result: Ok(())
            }),
            []
        );
        assert_eq!(harness.run(StreamInput::TimerFired { token: watchdog }), []);
        assert_eq!(harness.machine.current_attempt(), None);
    }

    #[test]
    fn redirects_and_forbidden_are_terminal() {
        for status in [302, 403] {
            let mut harness = Harness::new();
            harness.run(StreamInput::Start);
            let outputs = harness.respond(status, "text/html");
            assert_eq!(
                last_state(&outputs),
                Some(&ConnectionState::Failed {
                    error: LinkError::HttpStatus { status }
                })
            );
            assert_eq!(opens(&outputs), []);
        }
    }

    #[test]
    fn done_closes_on_purpose_and_restart_reopens() {
        let mut harness = Harness::new();
        let attempt = harness.live();
        let outputs = harness.chunk(
            b"event: session.status\ndata: {\"type\":\"session.status\",\"status\":\"idle\"}\n\n\
              data: [DONE]\n\n\
              event: session.status\ndata: {\"type\":\"session.status\",\"status\":\"running\"}\n\n",
        );
        assert_eq!(
            events(&outputs).len(),
            1,
            "nothing after [DONE] is forwarded"
        );
        assert!(outputs.contains(&StreamOutput::Cancel { attempt }));
        assert_eq!(last_state(&outputs), Some(&ConnectionState::Closed));
        assert_eq!(opens(&outputs), []);
        assert_eq!(scheduled(&outputs, TimerKind::Reconnect), []);
        assert_eq!(
            harness.run(StreamInput::Finished {
                attempt,
                result: Err(ConnectionFailure::Transport(TransportError::Cancelled)),
            }),
            []
        );
        // Contract §5.10: returning to the foreground reopens even after [DONE].
        let outputs = harness.run(StreamInput::Start);
        assert_eq!(opens(&outputs), [AttemptId(2)]);
        assert_eq!(last_state(&outputs), Some(&ConnectionState::Connecting));
    }

    #[test]
    fn eof_after_a_healthy_stream_reconnects_immediately_and_resumes() {
        let mut harness = Harness::new();
        harness.live();
        harness.advance(30_000);
        harness.chunk(HEARTBEAT);
        let outputs = harness.finish(Ok(()));
        assert_eq!(
            last_state(&outputs),
            Some(&ConnectionState::Reconnecting {
                reason: LinkError::EndOfStream,
                failures: 0,
                delay_ms: 0
            })
        );
        assert_eq!(opens(&outputs), [AttemptId(2)]);
        assert_eq!(scheduled(&outputs, TimerKind::Reconnect), []);

        // The reconnect gets a fresh live tail (no replay) and is reported as resumed.
        let recorded = recorded_sse_stream("recorded-reconnect-last-event-id-turn2.jsonl");
        harness.respond(200, "text/event-stream");
        let outputs = harness.chunk(&recorded.bytes);
        assert!(outputs.contains(&StreamOutput::Ready {
            attempt: AttemptId(2),
            resumed: true
        }));
        assert_eq!(events(&outputs).len(), recorded.frames.len() - 1);
    }

    #[test]
    fn unhealthy_losses_back_off_with_jitter_up_to_the_cap() {
        let mut harness = Harness::new();
        harness.run(StreamInput::Start);
        let mut delays = Vec::new();
        for expected_attempt in 2..=8 {
            harness.respond(200, "text/event-stream");
            harness.chunk(HEARTBEAT);
            harness.advance(1_000);
            let outputs = harness.finish(Ok(()));
            let [(token, delay)] = scheduled(&outputs, TimerKind::Reconnect)[..] else {
                panic!("expected one reconnect timer: {outputs:?}");
            };
            assert_eq!(opens(&outputs), []);
            delays.push(delay);
            harness.advance(delay);
            let outputs = harness.run(StreamInput::TimerFired { token });
            assert_eq!(opens(&outputs), [AttemptId(expected_attempt)]);
        }
        // FixedJitter(0) picks the bottom of each [cap/2, cap) window.
        assert_eq!(delays, [125, 250, 500, 1_000, 2_000, 2_500, 2_500]);
        assert_eq!(
            harness.machine.state(),
            &ConnectionState::Reconnecting {
                reason: LinkError::EndOfStream,
                failures: 7,
                delay_ms: 2_500
            }
        );
    }

    #[test]
    fn stall_watchdog_reschedules_on_activity_and_reconnects_after_45_s_of_silence() {
        let mut harness = Harness::new();
        let start = harness.run(StreamInput::Start);
        let first = scheduled(&start, TimerKind::Watchdog)[0].0;
        harness.respond(200, "text/event-stream");
        harness.advance(30_000);
        harness.chunk(HEARTBEAT);
        harness.advance(15_000);
        let outputs = harness.run(StreamInput::TimerFired { token: first });
        let [(second, remaining)] = scheduled(&outputs, TimerKind::Watchdog)[..] else {
            panic!("expected a rescheduled watchdog: {outputs:?}");
        };
        assert_eq!(remaining, 30_000, "45 s from the heartbeat at +30 s");
        assert_eq!(harness.run(StreamInput::TimerFired { token: first }), []);

        harness.advance(30_000);
        let attempt = harness.attempt();
        let outputs = harness.run(StreamInput::TimerFired { token: second });
        assert_eq!(outputs[0], StreamOutput::Cancel { attempt });
        assert!(
            !outputs.contains(&StreamOutput::CancelTimer { token: second }),
            "the fired timer is not cancelled"
        );
        // It was live for 45 s, so it reconnects at once.
        assert_eq!(
            last_state(&outputs),
            Some(&ConnectionState::Reconnecting {
                reason: LinkError::Stalled { silent_ms: 45_000 },
                failures: 0,
                delay_ms: 0
            })
        );
        assert_eq!(opens(&outputs), [AttemptId(2)]);
    }

    #[test]
    fn an_open_that_never_answers_stalls() {
        let mut harness = Harness::new();
        let start = harness.run(StreamInput::Start);
        let watchdog = scheduled(&start, TimerKind::Watchdog)[0].0;
        harness.advance(45_000);
        let outputs = harness.run(StreamInput::TimerFired { token: watchdog });
        assert_eq!(
            last_state(&outputs),
            Some(&ConnectionState::Reconnecting {
                reason: LinkError::Stalled { silent_ms: 45_000 },
                failures: 1,
                delay_ms: 125
            })
        );
    }

    #[test]
    fn not_found_is_retried_ten_times_then_fails() {
        let mut harness = Harness::new();
        harness.run(StreamInput::Start);
        for _ in 0..10 {
            let outputs = harness.respond(404, "application/json");
            let [(token, _)] = scheduled(&outputs, TimerKind::Reconnect)[..] else {
                panic!("404 should retry: {outputs:?}");
            };
            harness.run(StreamInput::TimerFired { token });
        }
        let outputs = harness.respond(404, "application/json");
        assert_eq!(
            last_state(&outputs),
            Some(&ConnectionState::Failed {
                error: LinkError::HttpStatus { status: 404 }
            })
        );
    }

    type RetryCase = (
        &'static str,
        fn(&mut Harness) -> Vec<StreamOutput>,
        LinkError,
    );

    #[test]
    fn server_errors_wrong_content_type_and_network_loss_retry() {
        let cases: [RetryCase; 4] = [
            (
                "503",
                |h| h.respond(503, "text/plain"),
                LinkError::HttpStatus { status: 503 },
            ),
            (
                "html login page",
                |h| h.respond(200, "text/html; charset=utf-8"),
                LinkError::UnexpectedContentType {
                    content_type: Some("text/html; charset=utf-8".into()),
                },
            ),
            (
                "missing content type",
                |h| {
                    let attempt = h.attempt();
                    h.run(StreamInput::Response {
                        attempt,
                        head: StreamResponseHead {
                            status: 200,
                            headers: vec![],
                        },
                    })
                },
                LinkError::UnexpectedContentType { content_type: None },
            ),
            (
                "offline before a response",
                |h| h.finish(Err(offline())),
                LinkError::Connection(offline()),
            ),
        ];
        for (name, act, reason) in cases {
            let mut harness = Harness::new();
            harness.run(StreamInput::Start);
            let outputs = act(&mut harness);
            assert_eq!(
                last_state(&outputs),
                Some(&ConnectionState::Reconnecting {
                    reason,
                    failures: 1,
                    delay_ms: 125
                }),
                "{name}"
            );
        }
    }

    #[test]
    fn tls_cancellation_and_auth_challenges_are_terminal() {
        for failure in [
            ConnectionFailure::Transport(TransportError::Tls {
                message: "untrusted".into(),
            }),
            ConnectionFailure::Transport(TransportError::Cancelled),
            ConnectionFailure::AuthenticationRequired {
                message: "challenge".into(),
            },
        ] {
            let mut harness = Harness::new();
            harness.run(StreamInput::Start);
            let outputs = harness.finish(Err(failure.clone()));
            assert_eq!(
                last_state(&outputs),
                Some(&ConnectionState::Failed {
                    error: LinkError::Connection(failure)
                })
            );
        }
        let mut harness = Harness::new();
        harness.run(StreamInput::Start);
        let outputs = harness.run(StreamInput::OpenFailed {
            attempt: AttemptId(1),
            error: TransportError::Other {
                message: "bad request".into(),
            },
        });
        assert_eq!(scheduled(&outputs, TimerKind::Reconnect).len(), 1);
    }

    #[test]
    fn malformed_events_end_the_attempt_after_delivering_earlier_events() {
        for (bytes, needle) in [
            (&b"data: {not json\n\n"[..], "not JSON"),
            (b"event: x\ndata: [1, 2]\n\n", "not a JSON object"),
            (b"data: {\"type\": 5}\n\n", "non-string type"),
            (b"data: {\"delta\": \"x\"}\n\n", "neither an event name"),
        ] {
            let mut harness = Harness::new();
            let attempt = harness.live();
            let mut stream =
                b"event: response.output_text.delta\ndata: {\"delta\":\"a\"}\n\n".to_vec();
            stream.extend_from_slice(bytes);
            let outputs = harness.chunk(&stream);
            assert_eq!(events(&outputs).len(), 1);
            assert!(outputs.contains(&StreamOutput::Cancel { attempt }));
            let Some(ConnectionState::Reconnecting {
                reason: LinkError::MalformedEvent { message },
                ..
            }) = last_state(&outputs)
            else {
                panic!("expected a malformed-event reconnect: {outputs:?}");
            };
            assert!(message.contains(needle), "{message}");
        }
    }

    #[test]
    fn framing_errors_end_the_attempt() {
        let mut harness = Harness::with_config(StreamConfig {
            limits: SseLimits {
                max_line_bytes: 64,
                max_event_bytes: 128,
            },
            ..StreamConfig::default()
        });
        harness.run(StreamInput::Start);
        harness.respond(200, "text/event-stream");
        let outputs = harness.chunk(&[b'x'; 65]);
        assert!(matches!(
            last_state(&outputs),
            Some(ConnectionState::Reconnecting {
                reason: LinkError::Sse(SseError::LineTooLong { line: 1, limit: 64 }),
                ..
            })
        ));
    }

    #[test]
    fn event_type_falls_back_to_the_sse_event_name() {
        let mut harness = Harness::new();
        harness.run(StreamInput::Start);
        harness.respond(200, "text/event-stream");
        // An event before any heartbeat still proves the stream live (older servers).
        let outputs = harness.chunk(b"event: session.title\ndata: {\"title\": \"T\"}\n\n");
        assert!(outputs.contains(&StreamOutput::Ready {
            attempt: AttemptId(1),
            resumed: false
        }));
        let event = events(&outputs)[0].clone();
        assert_eq!(event.event_type, "session.title");
        assert_eq!(
            event.into_value(),
            serde_json::json!({"type": "session.title", "title": "T"})
        );
    }

    #[test]
    fn heartbeats_prove_liveness_but_are_not_forwarded() {
        let mut harness = Harness::new();
        harness.live();
        let outputs = harness.chunk(
            b"event: response.heartbeat\ndata: {\"type\":\"response.heartbeat\",\"last_event_seq\":3}\n\n: proxy ping\n\n",
        );
        assert_eq!(outputs, []);
    }

    #[test]
    fn a_second_response_head_fails_and_an_empty_chunk_changes_nothing() {
        let mut harness = Harness::new();
        harness.live();
        assert_eq!(harness.chunk(b""), Vec::new());
        let outputs = harness.respond(200, "text/event-stream");
        assert!(matches!(
            last_state(&outputs),
            Some(ConnectionState::Failed {
                error: LinkError::HostContract { .. }
            })
        ));
    }

    #[test]
    fn a_stall_timer_with_a_clock_that_went_backward_only_re_arms() {
        let mut harness = Harness::new();
        let start = harness.run(StreamInput::Start);
        let (watchdog, _) = scheduled(&start, TimerKind::Watchdog)[0];
        harness.now = 0;
        let outputs = harness.run(StreamInput::TimerFired { token: watchdog });
        assert_eq!(last_state(&outputs), None, "nothing stalled: {outputs:?}");
        assert_eq!(
            scheduled(&outputs, TimerKind::Watchdog)[0].1,
            StreamConfig::default().stall_timeout_ms
        );
    }

    #[test]
    fn host_contract_violations_fail_loudly() {
        let mut harness = Harness::new();
        harness.run(StreamInput::Start);
        let outputs = harness.chunk(b"data: early\n\n");
        assert!(matches!(
            last_state(&outputs),
            Some(ConnectionState::Failed {
                error: LinkError::HostContract { .. }
            })
        ));

        let mut harness = Harness::new();
        harness.run(StreamInput::Start);
        let outputs = harness.finish(Ok(()));
        assert!(matches!(
            last_state(&outputs),
            Some(ConnectionState::Failed {
                error: LinkError::HostContract { .. }
            })
        ));
    }

    #[test]
    fn stop_cancels_everything_and_late_inputs_are_inert() {
        let mut harness = Harness::new();
        let start = harness.run(StreamInput::Start);
        let watchdog = scheduled(&start, TimerKind::Watchdog)[0].0;
        harness.respond(200, "text/event-stream");
        harness.chunk(b"event: session.status\ndata: {\"type\":");
        let outputs = harness.run(StreamInput::Stop);
        assert_eq!(
            outputs,
            [
                StreamOutput::Cancel {
                    attempt: AttemptId(1)
                },
                StreamOutput::CancelTimer { token: watchdog },
                StreamOutput::StateChanged {
                    state: ConnectionState::Stopped
                },
            ]
        );
        for late in [
            StreamInput::Chunk {
                attempt: AttemptId(1),
                bytes: b"\"session.status\"}\n\n".to_vec(),
            },
            StreamInput::Finished {
                attempt: AttemptId(1),
                result: Ok(()),
            },
            StreamInput::HydrationFailed {
                attempt: AttemptId(1),
                failure: HydrationFailure::HttpStatus { status: 401 },
            },
            StreamInput::TimerFired { token: watchdog },
            StreamInput::Stop,
        ] {
            assert_eq!(harness.run(late), []);
        }

        // Stopping while waiting to reconnect cancels the reconnect timer.
        let mut harness = Harness::new();
        harness.run(StreamInput::Start);
        let outputs = harness.respond(500, "text/plain");
        let (reconnect, _) = scheduled(&outputs, TimerKind::Reconnect)[0];
        let outputs = harness.run(StreamInput::Stop);
        assert_eq!(
            outputs,
            [
                StreamOutput::CancelTimer { token: reconnect },
                StreamOutput::StateChanged {
                    state: ConnectionState::Stopped
                },
            ]
        );
        assert_eq!(
            harness.run(StreamInput::TimerFired { token: reconnect }),
            []
        );
    }

    #[test]
    fn restart_after_failure_uses_a_fresh_ramp() {
        let mut harness = Harness::new();
        harness.run(StreamInput::Start);
        for _ in 0..3 {
            let outputs = harness.respond(500, "text/plain");
            let (token, _) = scheduled(&outputs, TimerKind::Reconnect)[0];
            harness.run(StreamInput::TimerFired { token });
        }
        harness.respond(401, "text/plain");
        harness.run(StreamInput::Start);
        let outputs = harness.respond(500, "text/plain");
        assert_eq!(scheduled(&outputs, TimerKind::Reconnect)[0].1, 125);
    }

    // Port of LocalServerSessionClientTests.swift::testTransientHydrationFailureReopensSSEAutomatically.
    #[test]
    fn transient_hydration_failure_reopens_sse_automatically() {
        let mut harness = Harness::new();
        let attempt = harness.live();
        let outputs = harness.run(StreamInput::HydrationFailed {
            attempt,
            failure: HydrationFailure::Connection(offline()),
        });
        assert_eq!(outputs[0], StreamOutput::Cancel { attempt });
        assert_eq!(
            last_state(&outputs),
            Some(&ConnectionState::Reconnecting {
                reason: LinkError::Hydration(HydrationFailure::Connection(offline())),
                failures: 1,
                delay_ms: 125
            })
        );
        let [(token, delay)] = scheduled(&outputs, TimerKind::Reconnect)[..] else {
            panic!("expected a reconnect timer: {outputs:?}");
        };
        harness.advance(delay);
        let outputs = harness.run(StreamInput::TimerFired { token });
        assert_eq!(opens(&outputs), [AttemptId(2)], "a fresh /stream request");
    }

    // Port of LocalServerSessionClientTests.swift::testAuthenticationHydrationFailureStopsInsteadOfRetrying.
    #[test]
    fn authentication_hydration_failure_stops_instead_of_retrying() {
        let mut harness = Harness::new();
        let attempt = harness.live();
        let outputs = harness.run(StreamInput::HydrationFailed {
            attempt,
            failure: HydrationFailure::HttpStatus { status: 401 },
        });
        let Some(ConnectionState::Failed { error }) = last_state(&outputs) else {
            panic!("expected a terminal failure: {outputs:?}");
        };
        assert!(error.requires_sign_in());
        assert_eq!(opens(&outputs), []);
        assert_eq!(scheduled(&outputs, TimerKind::Reconnect), []);
        assert_eq!(harness.machine.current_attempt(), None);
    }

    fn split_at_cuts(bytes: &[u8], cuts: &[usize]) -> Vec<Vec<u8>> {
        let mut points: Vec<usize> = cuts.iter().map(|cut| cut % (bytes.len() + 1)).collect();
        points.extend([0, bytes.len()]);
        points.sort_unstable();
        points.dedup();
        points
            .windows(2)
            .map(|pair| bytes[pair[0]..pair[1]].to_vec())
            .collect()
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(128))]

        /// Any split of the recorded stream yields the same machine outputs, `[DONE]` included.
        #[test]
        fn any_split_yields_the_same_outputs(cuts in prop::collection::vec(any::<usize>(), 0..48)) {
            let mut bytes = recorded_sse_stream("recorded-turn-text-tool-completion.jsonl").bytes;
            bytes.extend_from_slice(b"data: [DONE]\n\n");
            let run = |chunks: &[Vec<u8>]| {
                let mut harness = Harness::new();
                harness.run(StreamInput::Start);
                harness.respond(200, "text/event-stream");
                let mut outputs = Vec::new();
                for chunk in chunks {
                    outputs.extend(harness.run(StreamInput::Chunk {
                        attempt: AttemptId(1),
                        bytes: chunk.clone(),
                    }));
                }
                outputs
            };
            let whole = run(std::slice::from_ref(&bytes));
            prop_assert_eq!(last_state(&whole), Some(&ConnectionState::Closed));
            prop_assert_eq!(run(&split_at_cuts(&bytes, &cuts)), whole);
        }
    }

    // A driver built only on the host traits, as the FFI layer will build one. The fake host
    // answers synchronously, which a real host never does; the machine does not care.

    type Queue = Rc<RefCell<VecDeque<StreamInput>>>;

    struct QueueSink {
        attempt: AttemptId,
        queue: Queue,
    }

    impl ByteSink for QueueSink {
        fn response(&self, head: StreamResponseHead) {
            let attempt = self.attempt;
            self.queue
                .borrow_mut()
                .push_back(StreamInput::Response { attempt, head });
        }
        fn chunk(&self, bytes: Vec<u8>) {
            let attempt = self.attempt;
            self.queue
                .borrow_mut()
                .push_back(StreamInput::Chunk { attempt, bytes });
        }
        fn finish(&self, result: Result<(), ConnectionFailure>) {
            let attempt = self.attempt;
            self.queue
                .borrow_mut()
                .push_back(StreamInput::Finished { attempt, result });
        }
    }

    enum Scripted {
        Head(u16),
        Bytes(&'static [u8]),
        End(Result<(), ConnectionFailure>),
    }

    struct FakeHandle(Rc<Cell<bool>>);

    impl StreamHandle for FakeHandle {
        fn cancel(&self) {
            self.0.set(true);
        }
    }

    struct ScriptedTransport {
        scripts: RefCell<VecDeque<Vec<Scripted>>>,
        requests: RefCell<Vec<HttpRequest>>,
        cancelled: Rc<Cell<bool>>,
    }

    impl EventStreamTransport for ScriptedTransport {
        type Handle = FakeHandle;

        #[allow(
            clippy::future_not_send,
            reason = "the fake handle shares an Rc; hosts need not be Send"
        )]
        fn open(
            &self,
            request: HttpRequest,
            sink: Box<dyn ByteSink>,
        ) -> impl Future<Output = Result<FakeHandle, TransportError>> {
            self.requests.borrow_mut().push(request);
            let script = self.scripts.borrow_mut().pop_front().unwrap_or_default();
            for step in script {
                match step {
                    Scripted::Head(status) => sink.response(head(status, "text/event-stream")),
                    Scripted::Bytes(bytes) => sink.chunk(bytes.to_vec()),
                    Scripted::End(result) => sink.finish(result),
                }
            }
            ready(Ok(FakeHandle(Rc::clone(&self.cancelled))))
        }
    }

    struct FakeTime(Rc<Cell<u64>>);

    impl Clock for FakeTime {
        fn now_ms(&self) -> u64 {
            self.0.get()
        }
    }

    impl Scheduler for FakeTime {
        fn sleep(&self, delay_ms: u64) -> impl Future<Output = ()> {
            self.0.set(self.0.get() + delay_ms);
            ready(())
        }
    }

    #[derive(Default)]
    struct Driven {
        states: Vec<ConnectionState>,
        forwarded: Vec<String>,
        timers: Vec<(u64, TimerToken)>,
    }

    fn next_timer(timers: &mut Vec<(u64, TimerToken)>, time: &FakeTime) -> Option<StreamInput> {
        timers.sort_by_key(|(deadline, _)| *deadline);
        if timers.is_empty() {
            return None;
        }
        let (deadline, token) = timers.remove(0);
        block_on(time.sleep(deadline.saturating_sub(time.now_ms())));
        Some(StreamInput::TimerFired { token })
    }

    /// Runs the machine against `transport` until no input or timer is left.
    fn drive(transport: &ScriptedTransport, time: &FakeTime) -> Driven {
        let queue: Queue = Rc::new(RefCell::new(VecDeque::from([StreamInput::Start])));
        let mut machine = SessionStream::new(StreamConfig::default(), FixedJitter(0));
        let mut driven = Driven::default();
        for _ in 0..100 {
            let queued = queue.borrow_mut().pop_front();
            let Some(input) = queued.or_else(|| next_timer(&mut driven.timers, time)) else {
                break;
            };
            for output in machine.handle(time.now_ms(), input) {
                match output {
                    StreamOutput::Open { attempt } => {
                        let request = HttpRequest {
                            method: "GET".into(),
                            url: "http://127.0.0.1:6767/v1/sessions/a/stream".into(),
                            headers: vec![HttpHeader::new("Accept", "text/event-stream")],
                            body: None,
                        };
                        let sink = QueueSink {
                            attempt,
                            queue: Rc::clone(&queue),
                        };
                        block_on(transport.open(request, Box::new(sink))).unwrap();
                    }
                    StreamOutput::Cancel { .. } => transport.cancelled.set(true),
                    StreamOutput::ScheduleTimer { token, delay_ms } => {
                        driven.timers.push((time.now_ms() + delay_ms, token));
                    }
                    StreamOutput::CancelTimer { token } => {
                        driven.timers.retain(|(_, t)| *t != token);
                    }
                    StreamOutput::StateChanged { state } => driven.states.push(state),
                    StreamOutput::Ready { .. } => {}
                    StreamOutput::Event { event, .. } => driven.forwarded.push(event.event_type),
                }
            }
        }
        driven
    }

    #[test]
    fn drives_through_the_host_traits_from_eof_to_done() {
        let transport = ScriptedTransport {
            scripts: RefCell::new(VecDeque::from([
                vec![
                    Scripted::Head(200),
                    Scripted::Bytes(b"event: session.heartbeat\ndata: {\"type\":\"session."),
                    Scripted::Bytes(b"heartbeat\"}\r\n\r\n"),
                    Scripted::End(Ok(())),
                ],
                vec![
                    Scripted::Head(200),
                    Scripted::Bytes(
                        b"event: session.model\ndata: {\"type\":\"session.model\",\"model\":\"m\"}\n\ndata: [DONE]\n\n",
                    ),
                ],
            ])),
            requests: RefCell::new(Vec::new()),
            cancelled: Rc::new(Cell::new(false)),
        };
        let time = FakeTime(Rc::new(Cell::new(0)));
        let driven = drive(&transport, &time);
        assert_eq!(transport.requests.borrow().len(), 2);
        assert!(transport.cancelled.get());
        assert_eq!(driven.forwarded, ["session.model"]);
        assert_eq!(
            time.now_ms(),
            125,
            "one jittered backoff after the unhealthy EOF"
        );
        assert_eq!(
            driven.states,
            [
                ConnectionState::Connecting,
                ConnectionState::Live,
                ConnectionState::Reconnecting {
                    reason: LinkError::EndOfStream,
                    failures: 1,
                    delay_ms: 125
                },
                ConnectionState::Live,
                ConnectionState::Closed,
            ]
        );
        assert!(
            driven.timers.is_empty(),
            "no timer outlives the closed stream"
        );
    }
}
