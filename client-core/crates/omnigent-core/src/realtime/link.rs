//! Connection identity, timers, public connection state and failure classification, shared by
//! the SSE and WebSocket machines.

use thiserror::Error;

use super::host::ConnectionFailure;
use crate::http::TransportError;
use crate::sse::SseError;

/// Identifies one connection attempt. Inputs carrying an older id are dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct AttemptId(pub u64);

/// What a timer is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TimerKind {
    /// The wait before the next connection attempt.
    Reconnect,
    /// The silence check: the SSE stall watchdog or the WS heartbeat watchdog.
    Watchdog,
}

/// Identifies one scheduled timer. A fired token the machine no longer expects is dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TimerToken {
    /// What the timer is for.
    pub kind: TimerKind,
    /// Unique per machine.
    pub id: u64,
}

/// Allocates attempt ids and timer tokens.
#[derive(Debug, Clone, Default)]
pub(crate) struct Ids {
    next_attempt: u64,
    next_timer: u64,
}

impl Ids {
    pub(crate) const fn attempt(&mut self) -> AttemptId {
        self.next_attempt += 1;
        AttemptId(self.next_attempt)
    }

    pub(crate) const fn timer(&mut self, kind: TimerKind) -> TimerToken {
        self.next_timer += 1;
        TimerToken {
            kind,
            id: self.next_timer,
        }
    }
}

/// The user-visible state of one realtime connection. It maps to `NativeLab`'s
/// `LiveConnectionState`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionState {
    /// Never started.
    Idle,
    /// The first attempt since `Start` is in flight.
    Connecting,
    /// The server proved the connection live: the ready heartbeat (SSE) or the first snapshot
    /// (WS).
    Live,
    /// The connection was lost and another attempt is pending or in flight.
    Reconnecting {
        /// Why the last attempt ended.
        reason: LinkError,
        /// Consecutive failed attempts. It is 0 after a healthy connection, which reconnects at
        /// once.
        failures: u32,
        /// The wait before the next attempt, in ms.
        delay_ms: u64,
    },
    /// SSE only: the server closed the stream on purpose with `[DONE]`. Nothing reconnects
    /// until the caller starts again, for example on returning to the foreground.
    Closed,
    /// The caller stopped the connection.
    Stopped,
    /// A failure that retrying cannot fix. The connection stays down until the caller starts it
    /// again. See [`LinkError::requires_sign_in`].
    Failed {
        /// The failure.
        error: LinkError,
    },
}

/// A snapshot (`GET /v1/sessions/{id}`) or history read failed during the hydration handoff.
/// The wave-1 handoff maps its REST error to this.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum HydrationFailure {
    /// The server answered with a non-success status.
    #[error("snapshot request failed with HTTP {status}")]
    HttpStatus {
        /// That status.
        status: u16,
    },
    /// No response.
    #[error("snapshot request failed: {0}")]
    Connection(ConnectionFailure),
    /// The response could not be decoded. Retrying would read the same bytes, so this is
    /// terminal, as in `NativeLab` (`malformedResponse` does not reconnect).
    #[error("snapshot response is malformed: {message}")]
    Malformed {
        /// Decoder detail.
        message: String,
    },
}

/// Why a connection attempt ended.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum LinkError {
    /// The SSE open or the WS upgrade got this HTTP status. 3xx, 401 and 403 are terminal; 404
    /// is retried a bounded number of times; everything else is retried.
    #[error("server answered HTTP {status}")]
    HttpStatus {
        /// That status.
        status: u16,
    },
    /// SSE: a 2xx response that is not `text/event-stream`, for example a login page served by
    /// an auth proxy. It is retried with backoff.
    #[error("stream response has content type {content_type:?}, not text/event-stream")]
    UnexpectedContentType {
        /// The `Content-Type` header, if any.
        content_type: Option<String>,
    },
    /// No response, or the connection broke. TLS failures, cancellation by the platform and auth
    /// challenges are terminal; the rest are retried.
    #[error("connection failed: {0}")]
    Connection(ConnectionFailure),
    /// SSE: the body ended without `[DONE]`. That is a shutdown, a subscriber overflow or a
    /// proxy recycle, so it reconnects.
    #[error("stream ended without [DONE]")]
    EndOfStream,
    /// No bytes (SSE) or frames (WS) arrived within the watchdog window. It reconnects.
    #[error("no data for {silent_ms} ms")]
    Stalled {
        /// How long the connection was silent.
        silent_ms: u64,
    },
    /// SSE: the byte stream could not be framed. It reconnects with backoff.
    #[error("event stream is malformed: {0}")]
    Sse(SseError),
    /// SSE: a frame's `data` was not a JSON object with a string `type`. It reconnects with
    /// backoff.
    #[error("stream event is malformed: {message}")]
    MalformedEvent {
        /// Detail, including the decoder's message.
        message: String,
    },
    /// WS: the server sent a close frame. 1008 (policy violation, sent for an unauthenticated
    /// socket) is terminal; other codes reconnect.
    #[error("socket closed by server with code {code}: {reason}")]
    SocketClosed {
        /// The close code.
        code: u16,
        /// The close reason.
        reason: String,
    },
    /// WS: an inbound frame could not be decoded. It reconnects with backoff.
    #[error("session-updates frame is malformed: {message}")]
    MalformedFrame {
        /// Detail, including the decoder's message.
        message: String,
    },
    /// WS: sending a frame failed. It reconnects.
    #[error("sending on socket failed: {0}")]
    SendFailed(TransportError),
    /// SSE: the hydration handoff failed while the stream was open. Classified by its cause.
    #[error("hydration failed: {0}")]
    Hydration(HydrationFailure),
    /// The host broke the sink contract, for example by finishing without a response head. This
    /// is a bug, so it is terminal.
    #[error("host transport contract violated: {message}")]
    HostContract {
        /// What happened.
        message: String,
    },
}

/// WebSocket close code the server uses for an unauthenticated socket.
pub(crate) const POLICY_VIOLATION: u16 = 1008;

/// How a [`LinkError`] affects reconnecting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Disposition {
    Retry,
    RetryNotFound,
    GiveUp,
}

impl LinkError {
    /// Whether this failure means the credentials were rejected and the user must sign in again:
    /// 401, 403, an auth challenge, or WS close 1008. Each is also terminal.
    #[must_use]
    pub const fn requires_sign_in(&self) -> bool {
        match self {
            Self::HttpStatus { status }
            | Self::Hydration(HydrationFailure::HttpStatus { status }) => {
                matches!(*status, 401 | 403)
            }
            Self::Connection(ConnectionFailure::AuthenticationRequired { .. })
            | Self::Hydration(HydrationFailure::Connection(
                ConnectionFailure::AuthenticationRequired { .. },
            )) => true,
            Self::SocketClosed { code, .. } => *code == POLICY_VIOLATION,
            _ => false,
        }
    }

    /// Whether the machine reconnects after this failure. The exception is a run of 404s that
    /// outlives [`super::RetryConfig::max_not_found_retries`].
    #[must_use]
    pub const fn is_retryable(&self) -> bool {
        !matches!(self.disposition(), Disposition::GiveUp)
    }

    pub(crate) const fn disposition(&self) -> Disposition {
        match self {
            Self::HttpStatus { status }
            | Self::Hydration(HydrationFailure::HttpStatus { status }) => {
                status_disposition(*status)
            }
            Self::Connection(failure) | Self::Hydration(HydrationFailure::Connection(failure)) => {
                connection_disposition(failure)
            }
            Self::SocketClosed { code, .. } => {
                if *code == POLICY_VIOLATION {
                    Disposition::GiveUp
                } else {
                    Disposition::Retry
                }
            }
            Self::Hydration(HydrationFailure::Malformed { .. }) | Self::HostContract { .. } => {
                Disposition::GiveUp
            }
            Self::UnexpectedContentType { .. }
            | Self::EndOfStream
            | Self::Stalled { .. }
            | Self::Sse(_)
            | Self::MalformedEvent { .. }
            | Self::MalformedFrame { .. }
            | Self::SendFailed(_) => Disposition::Retry,
        }
    }
}

const fn status_disposition(status: u16) -> Disposition {
    match status {
        // Hosts never follow redirects. A redirect here is an auth layer bouncing to a login
        // page, and `NativeLab` treats it as `redirectNotAllowed`.
        300..=399 | 401 | 403 => Disposition::GiveUp,
        404 => Disposition::RetryNotFound,
        _ => Disposition::Retry,
    }
}

const fn connection_disposition(failure: &ConnectionFailure) -> Disposition {
    match failure {
        ConnectionFailure::AuthenticationRequired { .. }
        | ConnectionFailure::Transport(TransportError::Tls { .. } | TransportError::Cancelled) => {
            Disposition::GiveUp
        }
        ConnectionFailure::Transport(
            TransportError::Offline { .. }
            | TransportError::Timeout { .. }
            | TransportError::Other { .. },
        ) => Disposition::Retry,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn transport(error: TransportError) -> LinkError {
        LinkError::Connection(ConnectionFailure::Transport(error))
    }

    #[test]
    fn statuses_classify_like_the_contract() {
        for status in [301, 302, 307, 401, 403] {
            let error = LinkError::HttpStatus { status };
            assert!(!error.is_retryable(), "{status}");
            assert_eq!(error.requires_sign_in(), matches!(status, 401 | 403));
        }
        for status in [400, 404, 409, 429, 500, 502, 503] {
            assert!(LinkError::HttpStatus { status }.is_retryable(), "{status}");
        }
    }

    #[test]
    fn transport_failures_keep_their_kind_and_classify() {
        let message = String::from("detail");
        assert!(
            transport(TransportError::Offline {
                message: message.clone()
            })
            .is_retryable()
        );
        assert!(
            transport(TransportError::Timeout {
                message: message.clone()
            })
            .is_retryable()
        );
        assert!(
            transport(TransportError::Other {
                message: message.clone()
            })
            .is_retryable()
        );
        assert!(!transport(TransportError::Tls { message }).is_retryable());
        assert!(!transport(TransportError::Cancelled).is_retryable());
        assert_eq!(
            transport(TransportError::Offline {
                message: "no route".into()
            })
            .to_string(),
            "connection failed: offline: no route"
        );
    }

    #[test]
    fn hydration_failures_classify_by_cause() {
        let unauthorized = LinkError::Hydration(HydrationFailure::HttpStatus { status: 401 });
        assert!(!unauthorized.is_retryable());
        assert!(unauthorized.requires_sign_in());
        let lost = LinkError::Hydration(HydrationFailure::Connection(
            ConnectionFailure::Transport(TransportError::Offline {
                message: "lost".into(),
            }),
        ));
        assert!(lost.is_retryable());
        assert!(!lost.requires_sign_in());
        let malformed = LinkError::Hydration(HydrationFailure::Malformed {
            message: "x".into(),
        });
        assert!(!malformed.is_retryable());
    }

    #[test]
    fn stream_level_failures_reconnect() {
        for error in [
            LinkError::EndOfStream,
            LinkError::Stalled { silent_ms: 45_000 },
            LinkError::UnexpectedContentType {
                content_type: Some("text/html".into()),
            },
            LinkError::Sse(SseError::LineTooLong { line: 1, limit: 1 }),
            LinkError::MalformedEvent {
                message: "x".into(),
            },
            LinkError::MalformedFrame {
                message: "x".into(),
            },
            LinkError::SendFailed(TransportError::Cancelled),
            LinkError::SocketClosed {
                code: 1001,
                reason: String::new(),
            },
        ] {
            assert!(error.is_retryable(), "{error:?}");
            assert!(!error.requires_sign_in(), "{error:?}");
        }
        let policy = LinkError::SocketClosed {
            code: 1008,
            reason: "unauthenticated".into(),
        };
        assert!(!policy.is_retryable());
        assert!(policy.requires_sign_in());
        assert!(
            !LinkError::HostContract {
                message: "x".into()
            }
            .is_retryable()
        );
    }
}
