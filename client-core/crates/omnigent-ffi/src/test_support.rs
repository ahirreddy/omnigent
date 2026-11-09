//! Fake host traits and a deterministic executor for driver tests.

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use futures::channel::mpsc::UnboundedReceiver;
use futures::channel::oneshot;
use futures::executor::LocalPool;
use futures::task::LocalSpawnExt;

use crate::client::ClientCore;
use crate::connection::{HostConfig, OidcRedirect, UrlPolicy};
use crate::engine::{Engine, Listeners, Msg, Transports, lock};
use crate::events::{ConnectionPhase, CoreEvent, CoreListener};
use crate::host::{
    ByteSink, Clock, CoreTask, EntropyError, EntropySource, EventStreamTransport, ForeignHttp,
    HttpTransport, MessageSink, Scheduler, SecureStore, SecureStoreError, SecureStoreKey,
    StreamHandle, WebSocketHandle, WebSocketTransport,
};
use crate::http::{HttpHeader, HttpRequest, HttpResponse, TransportError};
use crate::runtime::{CoreTransport, Host, Sessions};

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

/// Answers by method and URL path, then by path alone; unknown paths are 404.
#[derive(Default)]
pub(crate) struct FakeHttp {
    routes: Mutex<HashMap<String, HttpResponse>>,
    method_routes: Mutex<HashMap<(String, String), HttpResponse>>,
    gates: Mutex<HashMap<String, VecDeque<oneshot::Receiver<()>>>>,
    failures: Mutex<HashMap<String, VecDeque<TransportError>>>,
    pub(crate) requests: Mutex<Vec<HttpRequest>>,
}

impl FakeHttp {
    pub(crate) fn route(&self, path: &str, response: HttpResponse) {
        lock(&self.routes).insert(path.to_owned(), response);
    }

    pub(crate) fn route_method(&self, method: &str, path: &str, response: HttpResponse) {
        lock(&self.method_routes).insert((method.to_owned(), path.to_owned()), response);
    }

    /// The next request to `path` waits for the returned sender (a dropped sender also frees it).
    pub(crate) fn hold(&self, path: &str) -> oneshot::Sender<()> {
        let (release, gate) = oneshot::channel();
        lock(&self.gates)
            .entry(path.to_owned())
            .or_default()
            .push_back(gate);
        release
    }

    /// The next request to `path` fails with `error` instead of answering.
    pub(crate) fn fail_next(&self, path: &str, error: TransportError) {
        lock(&self.failures)
            .entry(path.to_owned())
            .or_default()
            .push_back(error);
    }

    /// How many requests went to `path`.
    pub(crate) fn count(&self, path: &str) -> usize {
        self.paths()
            .iter()
            .filter(|sent| sent.as_str() == path)
            .count()
    }

    /// Requests sent as `METHOD path`.
    pub(crate) fn lines(&self) -> Vec<String> {
        lock(&self.requests)
            .iter()
            .map(|request| {
                format!(
                    "{} {}",
                    request.method,
                    url::Url::parse(&request.url).unwrap().path()
                )
            })
            .collect()
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
        let method = request.method.clone();
        lock(&self.requests).push(request);
        let gate = lock(&self.gates)
            .get_mut(&path)
            .and_then(VecDeque::pop_front);
        if let Some(gate) = gate {
            // A dropped sender frees the request too.
            gate.await.unwrap_or(());
        }
        let failure = lock(&self.failures)
            .get_mut(&path)
            .and_then(VecDeque::pop_front);
        if let Some(error) = failure {
            return Err(error);
        }
        if let Some(response) = lock(&self.method_routes).get(&(method, path.clone())) {
            return Ok(response.clone());
        }
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
    /// The next open fails with this.
    pub(crate) refuse: Mutex<Option<TransportError>>,
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
        let failure = lock(&self.refuse).take();
        if let Some(error) = failure {
            return Err(error);
        }
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
    pub(crate) sent_binary: Mutex<Vec<Vec<u8>>>,
    pub(crate) closes: Mutex<Vec<u16>>,
    /// Sends fail with this while set.
    pub(crate) send_failure: Mutex<Option<TransportError>>,
}

#[async_trait::async_trait]
impl WebSocketHandle for FakeSocket {
    async fn send_text(&self, text: String) -> Result<(), TransportError> {
        let failure = lock(&self.send_failure).clone();
        if let Some(error) = failure {
            return Err(error);
        }
        lock(&self.sent).push(text);
        Ok(())
    }

    async fn send_binary(&self, bytes: Vec<u8>) -> Result<(), TransportError> {
        let failure = lock(&self.send_failure).clone();
        if let Some(error) = failure {
            return Err(error);
        }
        lock(&self.sent_binary).push(bytes);
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
    /// The next open fails with this.
    pub(crate) refuse: Mutex<Option<TransportError>>,
}

impl FakeSockets {
    pub(crate) fn last(&self) -> OpenedSocket {
        lock(&self.opened)
            .last()
            .map(|(request, sink, socket)| (request.clone(), Arc::clone(sink), Arc::clone(socket)))
            .expect("no socket opened")
    }

    pub(crate) fn count(&self) -> usize {
        lock(&self.opened).len()
    }
}

impl WebSocketTransport for FakeSockets {
    fn open_socket(
        &self,
        request: HttpRequest,
        sink: Arc<MessageSink>,
    ) -> Result<Arc<dyn WebSocketHandle>, TransportError> {
        let failure = lock(&self.refuse).take();
        if let Some(error) = failure {
            return Err(error);
        }
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
    /// Reads fail with this while set.
    pub(crate) get_failure: Mutex<Option<SecureStoreError>>,
    /// Writes fail with this while set.
    pub(crate) set_failure: Mutex<Option<SecureStoreError>>,
    /// Deletes fail with this while set.
    pub(crate) delete_failure: Mutex<Option<SecureStoreError>>,
    set_gate: Mutex<Option<oneshot::Receiver<()>>>,
}

impl MemoryStore {
    /// The next write waits for the returned sender.
    pub(crate) fn hold_set(&self) -> oneshot::Sender<()> {
        let (release, gate) = oneshot::channel();
        *lock(&self.set_gate) = Some(gate);
        release
    }
}

#[async_trait::async_trait]
impl SecureStore for MemoryStore {
    async fn get(&self, key: SecureStoreKey) -> Result<Option<Vec<u8>>, SecureStoreError> {
        let failure = lock(&self.get_failure).clone();
        if let Some(error) = failure {
            return Err(error);
        }
        Ok(lock(&self.items)
            .get(&(key.namespace, key.account))
            .cloned())
    }

    async fn set(&self, key: SecureStoreKey, value: Vec<u8>) -> Result<(), SecureStoreError> {
        let gate = lock(&self.set_gate).take();
        if let Some(gate) = gate {
            // A dropped sender frees the write too.
            gate.await.unwrap_or(());
        }
        let failure = lock(&self.set_failure).clone();
        if let Some(error) = failure {
            return Err(error);
        }
        lock(&self.items).insert((key.namespace, key.account), value);
        Ok(())
    }

    async fn delete(&self, key: SecureStoreKey) -> Result<(), SecureStoreError> {
        let failure = lock(&self.delete_failure).clone();
        if let Some(error) = failure {
            return Err(error);
        }
        lock(&self.items).remove(&(key.namespace, key.account));
        Ok(())
    }
}

#[derive(Default)]
pub(crate) struct FixedEntropy {
    /// The RNG fails while set.
    pub(crate) failing: AtomicBool,
}

impl EntropySource for FixedEntropy {
    fn random_bytes(&self, len: u32) -> Result<Vec<u8>, EntropyError> {
        if self.failing.load(Ordering::SeqCst) {
            return Err(EntropyError::Unavailable {
                message: "no randomness".into(),
            });
        }
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

/// A configuration that reports nothing, with `harness`.
pub(crate) fn configuration_on(harness: &str) -> crate::configuration::SessionConfiguration {
    crate::configuration::SessionConfiguration {
        harness: Some(harness.to_owned()),
        ..omnigent_core::config::session::SessionConfiguration::default().into()
    }
}

/// The `ConnectionChanged` phases in `events`, in order.
pub(crate) fn phases(events: &[CoreEvent]) -> Vec<ConnectionPhase> {
    events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::ConnectionChanged { phase } => Some(phase.clone()),
            _ => None,
        })
        .collect()
}

/// A core connected to a routed loopback single-user server.
pub(crate) fn connected() -> Harness {
    let mut harness = Harness::new(UrlPolicy::Development);
    harness.local_server();
    let phase = harness
        .call(|core| async move { core.connect("http://127.0.0.1:6767".into(), None).await })
        .unwrap();
    assert!(
        matches!(phase, ConnectionPhase::Connected { .. }),
        "{phase:?}"
    );
    harness
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
    pub(crate) store: Arc<MemoryStore>,
    pub(crate) entropy: Arc<FixedEntropy>,
    pool: LocalPool,
}

impl Harness {
    pub(crate) fn new(policy: UrlPolicy) -> Self {
        Self::with_databricks(policy, None)
    }

    pub(crate) fn with_databricks(
        policy: UrlPolicy,
        databricks: Option<crate::connection::DatabricksOAuthSettings>,
    ) -> Self {
        Self::with_config(HostConfig {
            url_policy: policy,
            oidc_redirect: OidcRedirect::Loopback {
                path: "/oauth/callback".into(),
            },
            databricks,
        })
    }

    pub(crate) fn with_redirect(policy: UrlPolicy, oidc_redirect: OidcRedirect) -> Self {
        Self::with_config(HostConfig {
            url_policy: policy,
            oidc_redirect,
            databricks: None,
        })
    }

    pub(crate) fn with_config(config: HostConfig) -> Self {
        Self::with_transports(config, None)
    }

    /// A harness whose event streams go to `streams` instead of [`FakeStreams`].
    pub(crate) fn with_streams(policy: UrlPolicy, streams: Arc<dyn EventStreamTransport>) -> Self {
        Self::with_transports(
            HostConfig {
                url_policy: policy,
                oidc_redirect: OidcRedirect::None,
                databricks: None,
            },
            Some(streams),
        )
    }

    fn with_transports(
        config: HostConfig,
        custom_streams: Option<Arc<dyn EventStreamTransport>>,
    ) -> Self {
        let http = Arc::new(FakeHttp::default());
        let streams = Arc::new(FakeStreams::default());
        let sockets = Arc::new(FakeSockets::default());
        let clock = Arc::new(ManualClock::default());
        let scheduler = Arc::new(TestScheduler::new(Arc::clone(&clock)));
        let store = Arc::new(MemoryStore::default());
        let entropy = Arc::new(FixedEntropy::default());
        let core = ClientCore::new(
            http.clone(),
            custom_streams.unwrap_or_else(|| streams.clone()),
            sockets.clone(),
            clock.clone(),
            scheduler.clone(),
            store.clone(),
            entropy.clone(),
            config,
        )
        .unwrap();
        Self::assemble(
            core, http, streams, sockets, clock, scheduler, store, entropy,
        )
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
            Arc::new(MemoryStore::default()),
            Arc::new(FixedEntropy::default()),
        )
    }

    #[allow(clippy::too_many_arguments, reason = "one argument per fake")]
    fn assemble(
        core: Arc<ClientCore>,
        http: Arc<FakeHttp>,
        streams: Arc<FakeStreams>,
        sockets: Arc<FakeSockets>,
        clock: Arc<ManualClock>,
        scheduler: Arc<TestScheduler>,
        store: Arc<MemoryStore>,
        entropy: Arc<FixedEntropy>,
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
            store,
            entropy,
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

    /// Starts `future` (a core call) and returns its slot, empty until it finishes under `pump`.
    pub(crate) fn start<T: 'static>(
        &mut self,
        future: impl Future<Output = T> + 'static,
    ) -> Rc<RefCell<Option<T>>> {
        let result = Rc::new(RefCell::new(None));
        let slot = Rc::clone(&result);
        self.pool
            .spawner()
            .spawn_local(async move {
                *slot.borrow_mut() = Some(future.await);
            })
            .unwrap();
        self.pump();
        result
    }

    /// Runs the core call `call` builds to completion.
    pub(crate) fn call<T: 'static, F: Future<Output = T> + 'static>(
        &mut self,
        call: impl FnOnce(Arc<ClientCore>) -> F,
    ) -> T {
        let future = call(Arc::clone(&self.core));
        self.run(future)
    }

    /// The last request as `METHOD path`.
    pub(crate) fn last_request_line(&self) -> String {
        self.http.lines().pop().expect("no request was sent")
    }

    /// The last request as `METHOD path` and its JSON body (`null` when it has none).
    pub(crate) fn last_request(&self) -> (String, serde_json::Value) {
        let request = lock(&self.http.requests)
            .last()
            .expect("no request was sent")
            .clone();
        let path = url::Url::parse(&request.url).unwrap().path().to_owned();
        let body = request
            .body
            .as_ref()
            .map_or(serde_json::Value::Null, |body| {
                serde_json::from_slice(body).unwrap()
            });
        (format!("{} {path}", request.method), body)
    }

    /// A query parameter of the last request.
    pub(crate) fn last_query(&self, name: &str) -> Option<String> {
        let request = lock(&self.http.requests)
            .last()
            .expect("no request was sent")
            .clone();
        url::Url::parse(&request.url)
            .unwrap()
            .query_pairs()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.into_owned())
    }

    /// Routes what sending to the writable `session_id` reads and writes.
    pub(crate) fn writable_session(&self, session_id: &str) {
        self.http.route(
            &format!("/v1/sessions/{session_id}"),
            json(
                200,
                &format!(
                    r#"{{"id":"{session_id}","status":"idle","created_at":1,"permission_level":4,"pending_elicitations":[]}}"#
                ),
            ),
        );
        self.http.route(
            &format!("/v1/sessions/{session_id}/items"),
            json(200, r#"{"data":[],"has_more":false}"#),
        );
        self.http.route(
            &format!("/v1/sessions/{session_id}/events"),
            json(200, r#"{"queued":true,"item_id":"i1","pending_id":"p1"}"#),
        );
        self.core.sessions().set_live_session(session_id, true);
    }

    /// An engine over this harness's fakes that nothing runs: a test calls its handlers itself,
    /// for orders a running engine's queue does not produce.
    pub(crate) fn idle_engine(&self) -> (Engine, UnboundedReceiver<Msg>) {
        let listeners = Arc::new(Listeners::default());
        listeners.add(self.events.clone());
        let sessions = Arc::new(Sessions::new(
            CoreTransport::Foreign(ForeignHttp(self.http.clone())),
            omnigent_core::CoreConfig {
                allows_insecure_http: true,
            },
        ));
        Engine::new(
            Host {
                clock: self.clock.clone(),
                scheduler: self.scheduler.clone(),
            },
            Transports {
                streams: Some(self.streams.clone()),
                sockets: Some(self.sockets.clone()),
                demo: None,
            },
            sessions,
            listeners,
            1,
        )
    }

    /// Moves time forward and fires due timers, leaving the work they spawned queued, so a test
    /// can act between a timer firing and its work running.
    pub(crate) fn advance_stopping_before_spawned_work(&mut self, ms: u64) {
        self.clock.now.fetch_add(ms, Ordering::SeqCst);
        self.scheduler.fire_due();
        self.pool.run_until_stalled();
    }

    /// Moves time back, as a host clock that is not monotonic would.
    pub(crate) fn rewind(&mut self, ms: u64) {
        self.clock.now.fetch_sub(ms, Ordering::SeqCst);
        self.pump();
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
