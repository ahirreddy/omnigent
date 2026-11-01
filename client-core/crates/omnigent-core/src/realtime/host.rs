//! Host traits for long-lived connections, clocks and timers.
//!
//! The contract is described in the [module docs](super). Implementations live in the host
//! (Swift `OmnigentServices`, later TS). The core implements the sinks.

use std::fmt;
use std::future::Future;

use crate::http::{HttpHeader, HttpRequest, TransportError};

/// Status and headers of an event-stream response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamResponseHead {
    /// HTTP status code. Every status is reported, including 3xx.
    pub status: u16,
    /// Response headers, in order.
    pub headers: Vec<HttpHeader>,
}

impl StreamResponseHead {
    /// First header named `name`, compared case-insensitively.
    #[must_use]
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|header| header.name.eq_ignore_ascii_case(name))
            .map(|header| header.value.as_str())
    }
}

/// A connection that failed with no HTTP response to show for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionFailure {
    /// The transport failed. The kinds and their meaning are the same as for HTTP.
    Transport(TransportError),
    /// The platform demanded credentials the core never supplies, for example an HTTP auth
    /// challenge (`URLError.userAuthenticationRequired` or `.userCancelledAuthentication`).
    AuthenticationRequired {
        /// Host-provided detail.
        message: String,
    },
}

impl fmt::Display for ConnectionFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Transport(error) => error.fmt(f),
            Self::AuthenticationRequired { message } => {
                write!(f, "authentication required: {message}")
            }
        }
    }
}

/// Receives one event-stream response, in order: `response`, then `chunk`*, then `finish`.
pub trait ByteSink {
    /// The response head. Called at most once, before any chunk.
    fn response(&self, head: StreamResponseHead);
    /// Body bytes exactly as received.
    fn chunk(&self, bytes: Vec<u8>);
    /// The end of the stream: `Ok(())` at EOF, `Err` when the connection failed. Called exactly
    /// once, last.
    fn finish(&self, result: Result<(), ConnectionFailure>);
}

/// A running request the core can cancel.
pub trait StreamHandle {
    /// Stops the request. Delivering a late callback after this is harmless.
    fn cancel(&self);
}

/// Opens long-lived HTTP responses whose body is pushed into a [`ByteSink`].
pub trait EventStreamTransport {
    /// The handle used to cancel one stream.
    type Handle: StreamHandle;

    /// Starts `request` and resolves once it is in flight. `Err` means it could not be started;
    /// once this resolves `Ok`, every later outcome arrives through `sink`.
    fn open(
        &self,
        request: HttpRequest,
        sink: Box<dyn ByteSink>,
    ) -> impl Future<Output = Result<Self::Handle, TransportError>>;
}

/// One WebSocket data frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SocketMessage {
    /// A text frame.
    Text(String),
    /// A binary frame.
    Binary(Vec<u8>),
}

/// How a WebSocket connection ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SocketEnd {
    /// The server sent a close frame.
    Closed {
        /// The close code, or 1005 when the frame carried none.
        code: u16,
        /// The close reason, possibly empty.
        reason: String,
    },
    /// The upgrade request got an HTTP response other than 101.
    HandshakeRejected {
        /// That response's status.
        status: u16,
    },
    /// The connection failed before or after the handshake, without a close frame.
    Failed(ConnectionFailure),
}

/// Receives one WebSocket connection's events, in order: `opened`, then `message`*, then
/// `ended`.
pub trait MessageSink {
    /// The 101 handshake completed. Called at most once, before any message.
    fn opened(&self);
    /// One inbound data frame.
    fn message(&self, message: SocketMessage);
    /// The connection is over. Called exactly once, last.
    fn ended(&self, end: SocketEnd);
}

/// An open WebSocket the core can write to or close.
pub trait WebSocketHandle {
    /// Sends one text frame. Resolves once the frame was handed to the network.
    fn send_text(&self, text: String) -> impl Future<Output = Result<(), TransportError>>;
    /// Sends one binary frame (terminal input). Resolves once the frame was handed to the
    /// network.
    fn send_binary(&self, bytes: Vec<u8>) -> impl Future<Output = Result<(), TransportError>>;
    /// Starts the closing handshake with `code` and `reason`. Delivering a late callback after
    /// this is harmless.
    fn close(&self, code: u16, reason: String);
}

/// Opens WebSocket connections whose events are pushed into a [`MessageSink`].
pub trait WebSocketTransport {
    /// The handle for one socket.
    type Socket: WebSocketHandle;

    /// Starts the upgrade `request` (its URL uses `ws` or `wss`) and resolves once it is in
    /// flight. `Err` means it could not be started; once this resolves `Ok`, every later outcome
    /// arrives through `sink`.
    fn connect(
        &self,
        request: HttpRequest,
        sink: Box<dyn MessageSink>,
    ) -> impl Future<Output = Result<Self::Socket, TransportError>>;
}

/// Monotonic time.
pub trait Clock {
    /// Milliseconds since an arbitrary fixed origin. Never decreases, and it is not wall-clock
    /// time.
    fn now_ms(&self) -> u64;
}

/// Timers.
pub trait Scheduler {
    /// Resolves after at least `delay_ms`. Dropping the future cancels the timer.
    fn sleep(&self, delay_ms: u64) -> impl Future<Output = ()>;
}
