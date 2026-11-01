//! Session stream and session-updates realtime state machines.
//!
//! There are two long-lived connections, and each is a pure, time-injected state machine:
//!
//! - [`stream::SessionStream`] for `GET /v1/sessions/{id}/stream` (SSE);
//! - [`updates::SessionUpdates`] for `WS /v1/sessions/updates`.
//!
//! Neither machine performs I/O, reads a clock, or owns a timer. A driver (the FFI layer or a
//! future `ClientCore` method) feeds each machine *inputs*, each tagged with `now_ms` from the
//! host [`Clock`]. It then carries out the *outputs* the machine returns: open or cancel a
//! connection, send a frame, schedule or cancel a timer, publish a state change or an event.
//! Because of this split, all reconnect, watchdog and framing behaviour is tested here with
//! synthetic time, and the same code runs under Swift, the web, and plain unit tests.
//!
//! # Driver loop
//!
//! ```text
//!   host callback ──► machine.handle(clock.now_ms(), input) ──► Vec<output>
//!        ▲                                                          │
//!        └──── sink / timer / open-future results ◄── driver executes each output
//! ```
//!
//! - Every connection attempt has an [`AttemptId`]. The driver tags each sink callback with the
//!   attempt that opened it. Inputs for an attempt that is no longer current are expected races,
//!   such as late bytes after a cancel, and the machine drops them. This is the generation-token
//!   rule from `docs/wire-contract.md` §5.8.
//! - Every timer has a [`TimerToken`]. `ScheduleTimer { token, delay_ms }` means "deliver
//!   `TimerFired { token }` after `delay_ms`". A token the machine no longer expects is dropped,
//!   so the driver may skip `CancelTimer` as an optimisation without changing behaviour.
//! - Outputs must be executed in order. All delays are relative to the `now_ms` of the call that
//!   returned them.
//!
//! # Host contract
//!
//! The traits in [`host`] are the I/O surface. Like [`crate::http::HttpTransport`] they return
//! `impl Future` with no `Send` bound, so a WASM host can use `!Send` JS handles. Their
//! contract:
//!
//! - **[`EventStreamTransport::open`]** starts the request and resolves once it is in flight,
//!   with a [`StreamHandle`]. It resolves `Err` only when the request could not be started at
//!   all. After that the host reports everything through the [`ByteSink`], in order:
//!   - [`ByteSink::response`] once, with the status and headers. Every status counts, and
//!     redirects are not followed, the same as for HTTP;
//!   - [`ByteSink::chunk`] zero or more times, with body bytes exactly as received. Chunks are
//!     never coalesced to line boundaries or re-encoded;
//!   - [`ByteSink::finish`] exactly once, last: `Ok(())` at EOF, `Err` when the connection
//!     failed. A failure before any response comes with no `response` call at all.
//!
//!   After [`StreamHandle::cancel`], the host stops delivering chunks as soon as it can. It may
//!   call `finish(Err(Cancelled))` or nothing at all, and the core ignores either.
//! - **[`WebSocketTransport::connect`]** behaves the same way, with a [`MessageSink`]:
//!   [`MessageSink::opened`] once after the 101 handshake, then [`MessageSink::message`] for
//!   each text or binary frame, then [`MessageSink::ended`] exactly once. A handshake answered
//!   with any other HTTP status is reported as [`SocketEnd::HandshakeRejected`] with that
//!   status.
//! - **[`Clock::now_ms`]** is monotonic milliseconds, such as `ProcessInfo.systemUptime` or
//!   `performance.now()`. It is never wall-clock time.
//! - **[`Scheduler::sleep`]** resolves after at least `delay_ms`. Dropping the future cancels
//!   it.
//! - The host applies no timeouts of its own to these long-lived requests. The core's
//!   watchdogs own liveness. The SSE stall is 45 s and the WS silence is 70 s.
//!
//! Wave 1 builds two things on this API: typed event dispatch (a `StreamEvent` into WP1's
//! typed `ServerStreamEvent`) and the hydration-and-stream handoff. The handoff starts on
//! [`stream::StreamOutput::Ready`], tags its REST work with the ready attempt's
//! [`AttemptId`], and reports a failed snapshot with [`stream::StreamInput::HydrationFailed`].

pub mod backoff;
pub mod host;
pub mod link;
pub mod stream;
pub mod updates;

#[cfg(test)]
pub mod test_support;

pub use backoff::{BackoffConfig, JitterSource, RetryConfig, SplitMix64};
pub use host::{
    ByteSink, Clock, ConnectionFailure, EventStreamTransport, MessageSink, Scheduler, SocketEnd,
    SocketMessage, StreamHandle, StreamResponseHead, WebSocketHandle, WebSocketTransport,
};
pub use link::{AttemptId, ConnectionState, HydrationFailure, LinkError, TimerKind, TimerToken};
pub use stream::{SessionStream, StreamConfig, StreamEvent, StreamInput, StreamOutput};
pub use updates::{
    MAX_WATCHED_SESSIONS, SessionRow, SessionUpdates, UpdatesConfig, UpdatesError, UpdatesFrame,
    UpdatesInput, UpdatesOutput, WatchError, WatchSet,
};
