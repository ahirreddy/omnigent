//! Fake host traits and a deterministic executor for driver tests.

use std::cell::RefCell;
use std::collections::HashMap;
use std::future::Future;
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use futures::channel::oneshot;
use futures::executor::LocalPool;
use futures::task::LocalSpawnExt;

use crate::client::ClientCore;
use crate::connection::{HostConfig, OidcRedirect, UrlPolicy};
use crate::engine::lock;
use crate::events::{CoreEvent, CoreListener};
use crate::host::{
    ByteSink, Clock, CoreTask, EntropyError, EntropySource, EventStreamTransport, HttpTransport,
    MessageSink, Scheduler, SecureStore, SecureStoreError, SecureStoreKey, StreamHandle,
    WebSocketHandle, WebSocketTransport,
};
use crate::http::{HttpHeader, HttpRequest, HttpResponse, TransportError};

pub(crate) fn fixture(path: &str) -> String {
    let full = format!("{}/../../fixtures/{path}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(&full).unwrap_or_else(|error| panic!("{full}: {error}"))
}

/// The `response` of a recorded `{request, status, response}` envelope, as JSON text.
pub(crate) fn envelope_response(path: &str) -> String {
    let value: serde_json::Value = serde_json::from_str(&fixture(path)).unwrap();
    value["response"].to_string()
}

pub(crate) fn json(status: u16, body: &str) -> HttpResponse {
    HttpResponse {
        status,
        headers: vec![HttpHeader {
            name: "Content-Type".into(),
            value: "application/json".into(),
        }],
        body: body.as_bytes().to_vec(),
    }
}

/// Answers by URL path; unknown paths are 404.
#[derive(Default)]
pub(crate) struct FakeHttp {
    routes: Mutex<HashMap<String, HttpResponse>>,
    pub(crate) requests: Mutex<Vec<HttpRequest>>,
}

impl FakeHttp {
    pub(crate) fn route(&self, path: &str, response: HttpResponse) {
        lock(&self.routes).insert(path.to_owned(), response);
    }

    pub(crate) fn paths(&self) -> Vec<String> {
        lock(&self.requests)
            .iter()
            .map(|request| url::Url::parse(&request.url).unwrap().path().to_owned())
            .collect()
    }
}

#[async_trait::async_trait]
impl HttpTransport for FakeHttp {
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, TransportError> {
        let path = url::Url::parse(&request.url).unwrap().path().to_owned();
        lock(&self.requests).push(request);
        Ok(lock(&self.routes)
            .get(&path)
            .cloned()
            .unwrap_or_else(|| json(404, r#"{"detail":"not found"}"#)))
    }
}

#[derive(Default)]
pub(crate) struct FakeHandle {
    pub(crate) cancels: AtomicUsize,
}

impl StreamHandle for FakeHandle {
    fn cancel(&self) {
        self.cancels.fetch_add(1, Ordering::SeqCst);
    }
}

pub(crate) struct OpenedStream {
    pub(crate) request: HttpRequest,
    pub(crate) sink: Arc<ByteSink>,
    pub(crate) handle: Arc<FakeHandle>,
}

#[derive(Default)]
pub(crate) struct FakeStreams {
    pub(crate) opened: Mutex<Vec<OpenedStream>>,
}

impl FakeStreams {
    pub(crate) fn last(&self) -> (Arc<ByteSink>, Arc<FakeHandle>, HttpRequest) {
        lock(&self.opened)
            .last()
            .map(|last| {
                (
                    Arc::clone(&last.sink),
                    Arc::clone(&last.handle),
                    last.request.clone(),
                )
            })
            .expect("no stream opened")
    }

    pub(crate) fn count(&self) -> usize {
        lock(&self.opened).len()
    }
}

impl EventStreamTransport for FakeStreams {
    fn open_stream(
        &self,
        request: HttpRequest,
        sink: Arc<ByteSink>,
    ) -> Result<Arc<dyn StreamHandle>, TransportError> {
        let handle = Arc::new(FakeHandle::default());
        lock(&self.opened).push(OpenedStream {
            request,
            sink,
            handle: Arc::clone(&handle),
        });
        Ok(handle)
    }
}

#[derive(Default)]
pub(crate) struct FakeSocket {
    pub(crate) sent: Mutex<Vec<String>>,
    pub(crate) closes: Mutex<Vec<u16>>,
}

#[async_trait::async_trait]
impl WebSocketHandle for FakeSocket {
    async fn send_text(&self, text: String) -> Result<(), TransportError> {
        lock(&self.sent).push(text);
        Ok(())
    }

    fn close(&self, code: u16, _reason: String) {
        lock(&self.closes).push(code);
    }
}

pub(crate) type OpenedSocket = (HttpRequest, Arc<MessageSink>, Arc<FakeSocket>);

#[derive(Default)]
pub(crate) struct FakeSockets {
    pub(crate) opened: Mutex<Vec<OpenedSocket>>,
}

impl FakeSockets {
    pub(crate) fn last(&self) -> OpenedSocket {
        lock(&self.opened)
            .last()
            .map(|(request, sink, socket)| (request.clone(), Arc::clone(sink), Arc::clone(socket)))
            .expect("no socket opened")
    }
}

impl WebSocketTransport for FakeSockets {
    fn open_socket(
        &self,
        request: HttpRequest,
        sink: Arc<MessageSink>,
    ) -> Result<Arc<dyn WebSocketHandle>, TransportError> {
        let socket = Arc::new(FakeSocket::default());
        lock(&self.opened).push((request, sink, Arc::clone(&socket)));
        Ok(socket)
    }
}

/// Manual time: both clocks move only with [`TestScheduler::advance`].
#[derive(Default)]
pub(crate) struct ManualClock {
    now: AtomicU64,
}

impl Clock for ManualClock {
    fn monotonic_ms(&self) -> u64 {
        self.now.load(Ordering::SeqCst)
    }

    fn unix_time_ms(&self) -> u64 {
        1_800_000_000_000 + self.now.load(Ordering::SeqCst)
    }
}

/// Queues spawned tasks for the pump and fires sleeps when time is advanced.
pub(crate) struct TestScheduler {
    clock: Arc<ManualClock>,
    tasks: Mutex<Vec<Arc<CoreTask>>>,
    timers: Mutex<Vec<(u64, oneshot::Sender<()>)>>,
}

impl TestScheduler {
    pub(crate) fn new(clock: Arc<ManualClock>) -> Self {
        Self {
            clock,
            tasks: Mutex::new(Vec::new()),
            timers: Mutex::new(Vec::new()),
        }
    }

    fn fire_due(&self) {
        let now = self.clock.monotonic_ms();
        let mut timers = lock(&self.timers);
        let (due, pending): (Vec<_>, Vec<_>) = timers.drain(..).partition(|(at, _)| *at <= now);
        *timers = pending;
        drop(timers);
        for (_, sender) in due {
            // A dropped receiver is a timer the core cancelled; nothing waits for it.
            sender.send(()).unwrap_or(());
        }
    }

    pub(crate) fn pending_timers(&self) -> usize {
        lock(&self.timers)
            .iter()
            .filter(|(_, sender)| !sender.is_canceled())
            .count()
    }
}

#[async_trait::async_trait]
impl Scheduler for TestScheduler {
    async fn sleep(&self, delay_ms: u64) {
        let (sender, receiver) = oneshot::channel();
        lock(&self.timers).push((self.clock.monotonic_ms() + delay_ms, sender));
        // A dropped sender means the scheduler went away; the sleep ends either way.
        receiver.await.unwrap_or(());
    }

    fn spawn(&self, task: Arc<CoreTask>) {
        lock(&self.tasks).push(task);
    }
}

#[derive(Default)]
pub(crate) struct MemoryStore {
    pub(crate) items: Mutex<HashMap<(String, String), Vec<u8>>>,
}

#[async_trait::async_trait]
impl SecureStore for MemoryStore {
    async fn get(&self, key: SecureStoreKey) -> Result<Option<Vec<u8>>, SecureStoreError> {
        Ok(lock(&self.items)
            .get(&(key.namespace, key.account))
            .cloned())
    }

    async fn set(&self, key: SecureStoreKey, value: Vec<u8>) -> Result<(), SecureStoreError> {
        lock(&self.items).insert((key.namespace, key.account), value);
        Ok(())
    }

    async fn delete(&self, key: SecureStoreKey) -> Result<(), SecureStoreError> {
        lock(&self.items).remove(&(key.namespace, key.account));
        Ok(())
    }
}

pub(crate) struct FixedEntropy;

impl EntropySource for FixedEntropy {
    fn random_bytes(&self, len: u32) -> Result<Vec<u8>, EntropyError> {
        Ok((0..len)
            .map(|index| u8::try_from(index % 251).unwrap())
            .collect())
    }
}

#[derive(Default)]
pub(crate) struct Recorder {
    pub(crate) events: Mutex<Vec<CoreEvent>>,
}

impl CoreListener for Recorder {
    fn on_event(&self, event: CoreEvent) {
        lock(&self.events).push(event);
    }
}

impl Recorder {
    pub(crate) fn take(&self) -> Vec<CoreEvent> {
        std::mem::take(&mut *lock(&self.events))
    }

    pub(crate) fn all(&self) -> Vec<CoreEvent> {
        lock(&self.events).clone()
    }
}

/// A core over fakes, and the pump that runs its background work.
pub(crate) struct Harness {
    pub(crate) core: Arc<ClientCore>,
    pub(crate) http: Arc<FakeHttp>,
    pub(crate) streams: Arc<FakeStreams>,
    pub(crate) sockets: Arc<FakeSockets>,
    pub(crate) clock: Arc<ManualClock>,
    pub(crate) scheduler: Arc<TestScheduler>,
    pub(crate) events: Arc<Recorder>,
    pool: LocalPool,
}

impl Harness {
    pub(crate) fn new(policy: UrlPolicy) -> Self {
        let http = Arc::new(FakeHttp::default());
        let streams = Arc::new(FakeStreams::default());
        let sockets = Arc::new(FakeSockets::default());
        let clock = Arc::new(ManualClock::default());
        let scheduler = Arc::new(TestScheduler::new(Arc::clone(&clock)));
        let core = ClientCore::new(
            http.clone(),
            streams.clone(),
            sockets.clone(),
            clock.clone(),
            scheduler.clone(),
            Arc::new(MemoryStore::default()),
            Arc::new(FixedEntropy),
            HostConfig {
                url_policy: policy,
                oidc_redirect: OidcRedirect::Loopback {
                    path: "/oauth/callback".into(),
                },
            },
        )
        .unwrap();
        Self::assemble(core, http, streams, sockets, clock, scheduler)
    }

    pub(crate) fn demo() -> Self {
        let clock = Arc::new(ManualClock::default());
        let scheduler = Arc::new(TestScheduler::new(Arc::clone(&clock)));
        let core = ClientCore::new_demo(clock.clone(), scheduler.clone()).unwrap();
        Self::assemble(
            core,
            Arc::new(FakeHttp::default()),
            Arc::new(FakeStreams::default()),
            Arc::new(FakeSockets::default()),
            clock,
            scheduler,
        )
    }

    fn assemble(
        core: Arc<ClientCore>,
        http: Arc<FakeHttp>,
        streams: Arc<FakeStreams>,
        sockets: Arc<FakeSockets>,
        clock: Arc<ManualClock>,
        scheduler: Arc<TestScheduler>,
    ) -> Self {
        let events = Arc::new(Recorder::default());
        core.subscribe(events.clone());
        let mut harness = Self {
            core,
            http,
            streams,
            sockets,
            clock,
            scheduler,
            events,
            pool: LocalPool::new(),
        };
        harness.pump();
        harness
    }

    /// Runs every spawned task until nothing can make progress.
    pub(crate) fn pump(&mut self) {
        loop {
            self.scheduler.fire_due();
            let tasks = std::mem::take(&mut *lock(&self.scheduler.tasks));
            for task in &tasks {
                let task = Arc::clone(task);
                self.pool
                    .spawner()
                    .spawn_local(async move { task.run().await })
                    .unwrap();
            }
            self.pool.run_until_stalled();
            if lock(&self.scheduler.tasks).is_empty() {
                break;
            }
        }
    }

    /// Runs `future` (a core call) to completion.
    pub(crate) fn run<T: 'static>(&mut self, future: impl Future<Output = T> + 'static) -> T {
        let result = Rc::new(RefCell::new(None));
        let slot = Rc::clone(&result);
        self.pool
            .spawner()
            .spawn_local(async move {
                *slot.borrow_mut() = Some(future.await);
            })
            .unwrap();
        for _ in 0..100 {
            self.pump();
            if result.borrow().is_some() {
                break;
            }
        }
        result.borrow_mut().take().expect("the call did not finish")
    }

    /// Moves time forward and fires due timers.
    pub(crate) fn advance(&mut self, ms: u64) {
        self.clock.now.fetch_add(ms, Ordering::SeqCst);
        self.pump();
    }

    /// Routes a loopback single-user server.
    pub(crate) fn local_server(&self) {
        self.http.route(
            "/.well-known/omnigent.json",
            json(
                200,
                &envelope_response("sessions/recorded-well-known-manifest.json"),
            ),
        );
        self.http.route(
            "/v1/info",
            json(200, r#"{"single_user":true,"accounts_enabled":false}"#),
        );
        self.http
            .route("/v1/me", json(200, r#"{"user_id":"local"}"#));
        self.http.route(
            "/v1/sessions",
            json(
                200,
                &envelope_response("sessions/recorded-sessions-list.json"),
            ),
        );
    }
}
