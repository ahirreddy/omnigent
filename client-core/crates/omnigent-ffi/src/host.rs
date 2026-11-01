//! Host traits implemented in Swift (`OmnigentServices`), and the Rust objects the host calls back
//! into while a long-lived connection runs.
//!
//! The contracts are the core's: see `omnigent_core::http` and `omnigent_core::realtime` (module
//! docs) for the transport rules, `omnigent_core::auth` for secure storage and entropy, and
//! `omnigent_core::config` for settings and managed preferences.

use std::fmt;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, PoisonError};

use omnigent_core as core;

use crate::http::{HttpHeader, HttpRequest, HttpResponse, TransportError};

/// Sends one request and returns the final response. Every status is a response; redirects are
/// never followed; no cookies or caching the request did not ask for.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait HttpTransport: Send + Sync {
    /// Sends `request` and returns the final response.
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, TransportError>;
}

/// Why a stream or socket failed with no HTTP response to show for it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionFailure {
    /// No network path to the server.
    Offline {
        /// Host detail.
        message: String,
    },
    /// The request did not finish in time.
    Timeout {
        /// Host detail.
        message: String,
    },
    /// The request was cancelled by the platform.
    Cancelled,
    /// TLS negotiation or certificate validation failed.
    Tls {
        /// Host detail.
        message: String,
    },
    /// Any other transport failure.
    Other {
        /// Host detail.
        message: String,
    },
    /// The platform demanded credentials the core never supplies (an HTTP auth challenge).
    AuthenticationRequired {
        /// Host detail.
        message: String,
    },
}

/// Opens `GET …/stream` requests whose body is pushed into a [`ByteSink`]. Returns as soon as
/// the request is started; `Err` only when it could not be started. No timeouts of its own: the
/// core's 45 s stall watchdog owns liveness. The host may call `sink` before returning.
#[uniffi::export(with_foreign)]
pub trait EventStreamTransport: Send + Sync {
    /// Starts `request`; every later outcome arrives through `sink`.
    ///
    /// # Errors
    ///
    /// The request could not be started.
    fn open_stream(
        &self,
        request: HttpRequest,
        sink: Arc<ByteSink>,
    ) -> Result<Arc<dyn StreamHandle>, TransportError>;
}

/// A running event stream the core can cancel.
#[uniffi::export(with_foreign)]
pub trait StreamHandle: Send + Sync {
    /// Stops the request. Late sink callbacks after this are harmless.
    fn cancel(&self);
}

/// Opens WebSocket connections whose events are pushed into a [`MessageSink`]. The URL uses `ws`
/// or `wss`. Returns as soon as the upgrade is started; the host may call `sink` before
/// returning.
#[uniffi::export(with_foreign)]
pub trait WebSocketTransport: Send + Sync {
    /// Starts the upgrade `request`; every later outcome arrives through `sink`.
    ///
    /// # Errors
    ///
    /// The upgrade could not be started.
    fn open_socket(
        &self,
        request: HttpRequest,
        sink: Arc<MessageSink>,
    ) -> Result<Arc<dyn WebSocketHandle>, TransportError>;
}

/// An open WebSocket.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait WebSocketHandle: Send + Sync {
    /// Sends one text frame; resolves once it was handed to the network.
    async fn send_text(&self, text: String) -> Result<(), TransportError>;
    /// Starts the closing handshake. Late sink callbacks after this are harmless.
    fn close(&self, code: u16, reason: String);
}

/// Time sources.
#[uniffi::export(with_foreign)]
pub trait Clock: Send + Sync {
    /// Monotonic milliseconds since an arbitrary origin (never wall-clock time).
    fn monotonic_ms(&self) -> u64;
    /// Milliseconds since the Unix epoch, for token expiry.
    fn unix_time_ms(&self) -> u64;
}

/// Timers and background work. The core has no runtime: it runs every background job and timer
/// on the host's executor through this trait.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait Scheduler: Send + Sync {
    /// Resolves after at least `delay_ms`. The core cancels a timer by dropping this call, so
    /// the host must stop waiting when its task is cancelled.
    async fn sleep(&self, delay_ms: u64);
    /// Runs `task` to completion in the background (`Task { await task.run() }` on Apple).
    fn spawn(&self, task: Arc<CoreTask>);
}

/// A unit of background work the core asks the host to run. Run it once.
#[derive(uniffi::Object)]
pub struct CoreTask {
    future: Mutex<Option<Pin<Box<dyn Future<Output = ()> + Send>>>>,
}

impl fmt::Debug for CoreTask {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("CoreTask")
    }
}

impl CoreTask {
    pub(crate) fn new(future: impl Future<Output = ()> + Send + 'static) -> Arc<Self> {
        Arc::new(Self {
            future: Mutex::new(Some(Box::pin(future))),
        })
    }
}

#[uniffi::export]
impl CoreTask {
    /// Runs the work. A second call returns at once.
    pub async fn run(&self) {
        let future = self
            .future
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(future) = future {
            future.await;
        }
    }
}

/// Where a secret lives: on Apple `namespace` selects the Keychain service and `account` the
/// item's account. Items are device-only and readable once the device is unlocked.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SecureStoreKey {
    /// The owning flow: `oidc`, `accounts` or `databricks`.
    pub namespace: String,
    /// The item within the namespace.
    pub account: String,
}

/// Why the host's secure store failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum SecureStoreError {
    /// The store cannot be read now, typically because the device is locked.
    #[error("secure storage unavailable: {message}")]
    Unavailable {
        /// Host detail, for example the `OSStatus`.
        message: String,
    },
    /// Any other failure.
    #[error("secure storage failed: {message}")]
    Other {
        /// Host detail.
        message: String,
    },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for SecureStoreError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Other {
            message: format!("unexpected secure store error: {}", error.reason),
        }
    }
}

/// Host secure storage. `get` of an absent key is `None`, `delete` of an absent key succeeds;
/// every other failure is an error.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait SecureStore: Send + Sync {
    /// The bytes under `key`.
    async fn get(&self, key: SecureStoreKey) -> Result<Option<Vec<u8>>, SecureStoreError>;
    /// Stores `value` under `key`, replacing any previous value.
    async fn set(&self, key: SecureStoreKey, value: Vec<u8>) -> Result<(), SecureStoreError>;
    /// Removes `key`.
    async fn delete(&self, key: SecureStoreKey) -> Result<(), SecureStoreError>;
}

/// Why the host could not supply random bytes.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum EntropyError {
    /// The platform RNG failed.
    #[error("random bytes unavailable: {message}")]
    Unavailable {
        /// Host detail.
        message: String,
    },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for EntropyError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Unavailable {
            message: format!("unexpected entropy error: {}", error.reason),
        }
    }
}

/// Cryptographically secure random bytes (`SecRandomCopyBytes`).
#[uniffi::export(with_foreign)]
pub trait EntropySource: Send + Sync {
    /// Exactly `len` random bytes.
    ///
    /// # Errors
    ///
    /// The platform RNG failed.
    fn random_bytes(&self, len: u32) -> Result<Vec<u8>, EntropyError>;
}

/// Why the host's settings storage failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum SettingsStorageError {
    /// The storage failed.
    #[error("{message}")]
    Failed {
        /// Host detail.
        message: String,
    },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for SettingsStorageError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Failed {
            message: format!("unexpected settings storage error: {}", error.reason),
        }
    }
}

/// Persistent, non-secret preferences (`UserDefaults`). Values are JSON text.
#[uniffi::export(with_foreign)]
pub trait SettingsStorage: Send + Sync {
    /// The JSON value under `key`, if any.
    ///
    /// # Errors
    ///
    /// The storage failed.
    fn get(&self, key: String) -> Result<Option<String>, SettingsStorageError>;
    /// Stores the JSON `value` under `key`; `None` removes it.
    ///
    /// # Errors
    ///
    /// The storage failed.
    fn set(&self, key: String, value: Option<String>) -> Result<(), SettingsStorageError>;
}

/// Organization-managed preferences (MDM `UserDefaults` domains). Values are JSON text; the
/// host encodes property-list dates as ISO 8601 strings and data as base64 strings.
#[uniffi::export(with_foreign)]
pub trait ManagedPreferenceSource: Send + Sync {
    /// The JSON value of `key` in `domain`, if set.
    fn value(&self, key: String, domain: String) -> Option<String>;
    /// Whether an administrator forces `key` in `domain`.
    fn is_forced(&self, key: String, domain: String) -> bool;
}

/// Receives one event-stream response, in order: `response` once, `chunk` zero or more times
/// with bytes exactly as received, then `finish` exactly once.
#[derive(uniffi::Object)]
pub struct ByteSink {
    deliver: Box<dyn Fn(SinkEvent) + Send + Sync>,
}

/// One callback a [`ByteSink`] received.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SinkEvent {
    Response(core::realtime::StreamResponseHead),
    Chunk(Vec<u8>),
    Finished(Result<(), core::realtime::ConnectionFailure>),
}

impl fmt::Debug for ByteSink {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ByteSink")
    }
}

impl ByteSink {
    pub(crate) fn new(deliver: impl Fn(SinkEvent) + Send + Sync + 'static) -> Arc<Self> {
        Arc::new(Self {
            deliver: Box::new(deliver),
        })
    }
}

#[uniffi::export]
impl ByteSink {
    /// The response status and headers. Every status counts; redirects are not followed.
    pub fn response(&self, status: u16, headers: Vec<HttpHeader>) {
        (self.deliver)(SinkEvent::Response(core::realtime::StreamResponseHead {
            status,
            headers: headers.into_iter().map(Into::into).collect(),
        }));
    }

    /// Body bytes exactly as received.
    pub fn chunk(&self, bytes: Vec<u8>) {
        (self.deliver)(SinkEvent::Chunk(bytes));
    }

    /// The end: `None` at EOF, otherwise the failure.
    pub fn finish(&self, failure: Option<ConnectionFailure>) {
        (self.deliver)(SinkEvent::Finished(
            failure.map_or(Ok(()), |f| Err(f.into())),
        ));
    }
}

/// How a WebSocket connection ended.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SocketEnd {
    /// The server sent a close frame (code 1005 when it carried none).
    Closed {
        /// The close code.
        code: u16,
        /// The close reason, possibly empty.
        reason: String,
    },
    /// The upgrade got an HTTP response other than 101.
    HandshakeRejected {
        /// That status.
        status: u16,
    },
    /// The connection failed without a close frame.
    Failed {
        /// Why.
        failure: ConnectionFailure,
    },
}

/// One WebSocket data frame.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SocketMessage {
    /// A text frame.
    Text {
        /// The text.
        text: String,
    },
    /// A binary frame.
    Binary {
        /// The bytes.
        bytes: Vec<u8>,
    },
}

/// One callback a [`MessageSink`] received.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SocketEvent {
    Opened,
    Message(core::realtime::SocketMessage),
    Ended(core::realtime::SocketEnd),
}

/// Receives one WebSocket's events, in order: `opened` once after the 101, `message` per frame,
/// then `ended` exactly once.
#[derive(uniffi::Object)]
pub struct MessageSink {
    deliver: Box<dyn Fn(SocketEvent) + Send + Sync>,
}

impl fmt::Debug for MessageSink {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("MessageSink")
    }
}

impl MessageSink {
    pub(crate) fn new(deliver: impl Fn(SocketEvent) + Send + Sync + 'static) -> Arc<Self> {
        Arc::new(Self {
            deliver: Box::new(deliver),
        })
    }
}

#[uniffi::export]
impl MessageSink {
    /// The 101 handshake completed.
    pub fn opened(&self) {
        (self.deliver)(SocketEvent::Opened);
    }

    /// One inbound data frame.
    pub fn message(&self, message: SocketMessage) {
        (self.deliver)(SocketEvent::Message(message.into()));
    }

    /// The connection is over.
    pub fn ended(&self, end: SocketEnd) {
        (self.deliver)(SocketEvent::Ended(end.into()));
    }
}

impl From<ConnectionFailure> for core::realtime::ConnectionFailure {
    fn from(failure: ConnectionFailure) -> Self {
        use core::http::TransportError as Core;
        match failure {
            ConnectionFailure::Offline { message } => Self::Transport(Core::Offline { message }),
            ConnectionFailure::Timeout { message } => Self::Transport(Core::Timeout { message }),
            ConnectionFailure::Cancelled => Self::Transport(Core::Cancelled),
            ConnectionFailure::Tls { message } => Self::Transport(Core::Tls { message }),
            ConnectionFailure::Other { message } => Self::Transport(Core::Other { message }),
            ConnectionFailure::AuthenticationRequired { message } => {
                Self::AuthenticationRequired { message }
            }
        }
    }
}

impl From<SocketEnd> for core::realtime::SocketEnd {
    fn from(end: SocketEnd) -> Self {
        match end {
            SocketEnd::Closed { code, reason } => Self::Closed { code, reason },
            SocketEnd::HandshakeRejected { status } => Self::HandshakeRejected { status },
            SocketEnd::Failed { failure } => Self::Failed(failure.into()),
        }
    }
}

impl From<SocketMessage> for core::realtime::SocketMessage {
    fn from(message: SocketMessage) -> Self {
        match message {
            SocketMessage::Text { text } => Self::Text(text),
            SocketMessage::Binary { bytes } => Self::Binary(bytes),
        }
    }
}

/// The host transport as the core's `HttpTransport`.
#[derive(Clone)]
pub(crate) struct ForeignHttp(pub(crate) Arc<dyn HttpTransport>);

impl fmt::Debug for ForeignHttp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ForeignHttp")
    }
}

impl core::http::HttpTransport for ForeignHttp {
    fn send(
        &self,
        request: core::http::HttpRequest,
    ) -> impl Future<Output = Result<core::http::HttpResponse, core::http::TransportError>> {
        let transport = Arc::clone(&self.0);
        async move {
            transport
                .send(request.into())
                .await
                .map(Into::into)
                .map_err(Into::into)
        }
    }
}

/// The host secure store as the core's `SecureStore`.
#[derive(Clone)]
pub(crate) struct ForeignStore(pub(crate) Arc<dyn SecureStore>);

impl fmt::Debug for ForeignStore {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ForeignStore")
    }
}

fn store_error(error: SecureStoreError) -> core::auth::SecureStoreError {
    match error {
        SecureStoreError::Unavailable { message } => {
            core::auth::SecureStoreError::Unavailable { message }
        }
        SecureStoreError::Other { message } => core::auth::SecureStoreError::Other { message },
    }
}

fn store_key(key: core::auth::SecureStoreKey) -> SecureStoreKey {
    SecureStoreKey {
        namespace: key.namespace,
        account: key.account,
    }
}

impl core::auth::SecureStore for ForeignStore {
    fn get(
        &self,
        key: core::auth::SecureStoreKey,
    ) -> impl Future<Output = Result<Option<Vec<u8>>, core::auth::SecureStoreError>> {
        let store = Arc::clone(&self.0);
        async move { store.get(store_key(key)).await.map_err(store_error) }
    }

    fn set(
        &self,
        key: core::auth::SecureStoreKey,
        value: Vec<u8>,
    ) -> impl Future<Output = Result<(), core::auth::SecureStoreError>> {
        let store = Arc::clone(&self.0);
        async move { store.set(store_key(key), value).await.map_err(store_error) }
    }

    fn delete(
        &self,
        key: core::auth::SecureStoreKey,
    ) -> impl Future<Output = Result<(), core::auth::SecureStoreError>> {
        let store = Arc::clone(&self.0);
        async move { store.delete(store_key(key)).await.map_err(store_error) }
    }
}

/// The host RNG as the core's `EntropySource`.
#[derive(Clone)]
pub(crate) struct ForeignEntropy(pub(crate) Arc<dyn EntropySource>);

impl fmt::Debug for ForeignEntropy {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ForeignEntropy")
    }
}

impl core::auth::EntropySource for ForeignEntropy {
    fn random_bytes(&self, len: usize) -> Result<Vec<u8>, core::auth::EntropyError> {
        let requested = u32::try_from(len).map_err(|_| core::auth::EntropyError::ShortRead {
            requested: len,
            received: 0,
        })?;
        let bytes = self
            .0
            .random_bytes(requested)
            .map_err(|error| match error {
                EntropyError::Unavailable { message } => {
                    core::auth::EntropyError::Unavailable { message }
                }
            })?;
        if bytes.len() == len {
            Ok(bytes)
        } else {
            Err(core::auth::EntropyError::ShortRead {
                requested: len,
                received: bytes.len(),
            })
        }
    }
}

impl ForeignEntropy {
    /// A seed for reconnect jitter.
    pub(crate) fn seed(&self) -> Result<u64, core::auth::EntropyError> {
        let bytes = core::auth::EntropySource::random_bytes(self, 8)?;
        let mut seed = [0_u8; 8];
        for (slot, byte) in seed.iter_mut().zip(bytes) {
            *slot = byte;
        }
        Ok(u64::from_le_bytes(seed))
    }
}
