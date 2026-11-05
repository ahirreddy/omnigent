//! Test doubles for the session client: a transport that answers by method and path (the Rust
//! counterpart of `NativeLab`'s `TransportHarness`), fixture envelope loading, gates for
//! in-flight races, and an event recorder.

#![allow(
    clippy::redundant_pub_crate,
    reason = "test-only helpers; `pub` would trip rustc's unreachable_pub instead"
)]
#![allow(
    clippy::future_not_send,
    reason = "test executors are single-threaded; the doubles are deliberately !Send"
)]

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

use futures::executor::block_on;
use serde_json::Value;
use url::Url;

use super::{ClientCore, ClientEvent, ClientListener, CoreConfig};
use crate::auth::SecretString;
use crate::auth::endpoint::ServerEndpoint;
use crate::http::{HttpHeader, HttpRequest, HttpResponse, HttpTransport, TransportError};

/// The loopback root the local tests connect to.
pub(crate) const LOCAL: &str = "http://127.0.0.1:6767";
/// The hosted mount.
pub(crate) const MOUNT: &str = "/api/2.0/omnigent";
/// A bearer that is obviously not a credential.
pub(crate) const TOKEN: &str = "fixture-token-not-a-real-credential";

/// One scripted reply.
#[derive(Debug, Clone)]
pub(crate) enum Reply {
    /// A JSON (or other) response.
    Response {
        /// Status.
        status: u16,
        /// Body.
        body: String,
    },
    /// A response with another media type, such as file content.
    Typed {
        /// Status.
        status: u16,
        /// The `Content-Type` header.
        content_type: String,
        /// Body.
        body: Vec<u8>,
    },
    /// A transport failure.
    Fail(TransportError),
}

impl Reply {
    pub(crate) fn json(status: u16, body: impl Into<String>) -> Self {
        Self::Response {
            status,
            body: body.into(),
        }
    }
}

#[derive(Debug, Clone)]
struct Route {
    method: Option<String>,
    path: String,
    after: Option<String>,
    reply: Reply,
}

/// Replies queued for one (method, path).
type Queue = ((String, String), VecDeque<Reply>);

/// A one-shot latch for replies that must wait.
#[derive(Debug, Default)]
pub(crate) struct Gate {
    open: Cell<bool>,
    wakers: RefCell<Vec<Waker>>,
}

impl Gate {
    pub(crate) fn open(&self) {
        self.open.set(true);
        for waker in self.wakers.borrow_mut().drain(..) {
            waker.wake();
        }
    }
}

/// Answers each request from, in order: the queue for its method and path; a stub for its
/// method, path and `after`; a stub for its path and `after`; then the same without `after`;
/// else 404 `{}`.
#[derive(Debug, Default)]
pub(crate) struct RouteTransport {
    routes: RefCell<Vec<Route>>,
    queues: RefCell<Vec<Queue>>,
    gates: RefCell<Vec<(String, String, Rc<Gate>)>>,
    pub(crate) requests: RefCell<Vec<HttpRequest>>,
}

impl RouteTransport {
    /// A transport with the local single-user `/v1/info` and `/v1/me` stubs under `prefix`.
    pub(crate) fn with_prefix(prefix: &str, single_user: bool) -> Self {
        let transport = Self::default();
        let info = if single_user {
            r#"{"single_user":true,"accounts_enabled":false}"#
        } else {
            r#"{"single_user":false,"accounts_enabled":false,"login_url":"/auth/login"}"#
        };
        let user = if single_user { "local" } else { "user-1" };
        transport.respond(
            None,
            &format!("{prefix}/v1/info"),
            None,
            Reply::json(200, info),
        );
        transport.respond(
            None,
            &format!("{prefix}/v1/me"),
            None,
            Reply::json(200, format!(r#"{{"user_id":"{user}","is_admin":true}}"#)),
        );
        transport
    }

    /// The local transport.
    pub(crate) fn local() -> Self {
        Self::with_prefix("", true)
    }

    /// Replaces the stub for (`method`, `path`, `after`).
    pub(crate) fn respond(
        &self,
        method: Option<&str>,
        path: &str,
        after: Option<&str>,
        reply: Reply,
    ) -> &Self {
        let mut routes = self.routes.borrow_mut();
        routes.retain(|route| {
            !(route.method.as_deref() == method
                && route.path == path
                && route.after.as_deref() == after)
        });
        routes.push(Route {
            method: method.map(str::to_owned),
            path: path.to_owned(),
            after: after.map(str::to_owned),
            reply,
        });
        self
    }

    /// Stubs any method on `path` with a 200 JSON body.
    pub(crate) fn ok(&self, path: &str, body: impl Into<String>) -> &Self {
        self.respond(None, path, None, Reply::json(200, body))
    }

    /// Queues `replies` for `method path`, served before any stub.
    pub(crate) fn enqueue(&self, method: &str, path: &str, replies: Vec<Reply>) -> &Self {
        self.queues
            .borrow_mut()
            .push(((method.to_owned(), path.to_owned()), replies.into()));
        self
    }

    /// Makes replies to `method path` wait until the returned gate opens.
    pub(crate) fn gate(&self, method: &str, path: &str) -> Rc<Gate> {
        let gate = Rc::new(Gate::default());
        self.gates
            .borrow_mut()
            .push((method.to_owned(), path.to_owned(), Rc::clone(&gate)));
        gate
    }

    /// The `id=conv_a` writable session and its empty history, as the Swift harness stubs them.
    pub(crate) fn writable_session(&self, pending: &str) -> &Self {
        self.ok(
            "/v1/sessions/conv_a",
            format!(
                r#"{{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"pending_elicitations":{pending}}}"#
            ),
        );
        self.ok(
            "/v1/sessions/conv_a/items",
            r#"{"data":[],"has_more":false}"#,
        )
    }

    /// Registers every envelope of a fixture as a stub (`.json`) or queue entry (`.jsonl`).
    pub(crate) fn load(&self, fixture: &str) -> &Self {
        let queue = is_script(fixture);
        for envelope in envelopes(fixture) {
            if queue {
                self.enqueue(&envelope.method, &envelope.path, vec![envelope.reply]);
            } else {
                self.respond(
                    Some(&envelope.method),
                    &envelope.path,
                    envelope.after.as_deref(),
                    envelope.reply,
                );
            }
        }
        self
    }

    /// Queues every envelope of a `.jsonl` script and also stubs the last one of each method
    /// and path, as the Swift tests' `respond` plus `enqueue` did.
    pub(crate) fn script(&self, fixture: &str) -> &Self {
        let all = envelopes(fixture);
        for envelope in &all {
            self.enqueue(
                &envelope.method,
                &envelope.path,
                vec![envelope.reply.clone()],
            );
        }
        for envelope in all.iter().rev() {
            let exists = self.routes.borrow().iter().any(|route| {
                route.method.as_deref() == Some(envelope.method.as_str())
                    && route.path == envelope.path
            });
            if !exists {
                self.respond(
                    Some(&envelope.method),
                    &envelope.path,
                    None,
                    envelope.reply.clone(),
                );
            }
        }
        self
    }

    /// The recorded requests.
    pub(crate) fn taken(&self) -> Vec<HttpRequest> {
        self.requests.borrow().clone()
    }

    /// `METHOD path` of every recorded request.
    pub(crate) fn lines(&self) -> Vec<String> {
        self.requests
            .borrow()
            .iter()
            .map(|request| format!("{} {}", request.method, path_of(request)))
            .collect()
    }

    /// Requests with a method other than GET.
    pub(crate) fn writes(&self) -> Vec<HttpRequest> {
        self.requests
            .borrow()
            .iter()
            .filter(|request| request.method != "GET")
            .cloned()
            .collect()
    }

    /// The JSON bodies of every PATCH and POST.
    pub(crate) fn write_bodies(&self) -> Vec<Value> {
        self.writes().iter().map(body_json).collect()
    }

    fn reply_for(&self, request: &HttpRequest) -> Reply {
        let path = path_of(request);
        let method = request.method.clone();
        if let Some((_, queue)) = self
            .queues
            .borrow_mut()
            .iter_mut()
            .find(|((m, p), queue)| *m == method && *p == path && !queue.is_empty())
            && let Some(reply) = queue.pop_front()
        {
            return reply;
        }
        let after = query_value(request, "after");
        let routes = self.routes.borrow();
        let find = |method: Option<&str>, after: Option<&str>| {
            routes
                .iter()
                .find(|route| {
                    route.method.as_deref() == method
                        && route.path == path
                        && route.after.as_deref() == after
                })
                .map(|route| route.reply.clone())
        };
        let candidates = [
            (Some(method.as_str()), after.as_deref()),
            (None, after.as_deref()),
            (Some(method.as_str()), None),
            (None, None),
        ];
        candidates
            .iter()
            .find_map(|(method, after)| {
                if after.is_none() && query_value(request, "after").is_some() {
                    // A stub without `after` answers any cursor.
                    find(*method, None)
                } else {
                    find(*method, *after)
                }
            })
            .unwrap_or_else(|| Reply::json(404, "{}"))
    }
}

struct Pending {
    gate: Option<Rc<Gate>>,
    reply: Option<Result<HttpResponse, TransportError>>,
}

impl Future for Pending {
    type Output = Result<HttpResponse, TransportError>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        if let Some(gate) = &self.gate
            && !gate.open.get()
        {
            gate.wakers.borrow_mut().push(cx.waker().clone());
            return Poll::Pending;
        }
        Poll::Ready(self.reply.take().unwrap_or_else(|| {
            Err(TransportError::Other {
                message: "polled after completion".into(),
            })
        }))
    }
}

impl HttpTransport for RouteTransport {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, TransportError>> {
        let path = path_of(&request);
        let gate = self
            .gates
            .borrow()
            .iter()
            .find(|(method, gated, gate)| {
                *method == request.method && *gated == path && !gate.open.get()
            })
            .map(|(_, _, gate)| Rc::clone(gate));
        let reply = self.reply_for(&request);
        self.requests.borrow_mut().push(request);
        let result = match reply {
            Reply::Response { status, body } => Ok(HttpResponse {
                status,
                headers: vec![HttpHeader::new("Content-Type", "application/json")],
                body: body.into_bytes(),
            }),
            Reply::Typed {
                status,
                content_type,
                body,
            } => Ok(HttpResponse {
                status,
                headers: vec![HttpHeader::new("Content-Type", content_type)],
                body,
            }),
            Reply::Fail(error) => Err(error),
        };
        Pending {
            gate,
            reply: Some(result),
        }
    }
}

/// The URL path of `request`.
pub(crate) fn path_of(request: &HttpRequest) -> String {
    Url::parse(&request.url)
        .map(|url| url.path().to_owned())
        .unwrap_or_default()
}

/// The first value of query parameter `name`.
pub(crate) fn query_value(request: &HttpRequest, name: &str) -> Option<String> {
    Url::parse(&request.url).ok().and_then(|url| {
        url.query_pairs()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.into_owned())
    })
}

/// The JSON body of `request` (`null` when it has none).
pub(crate) fn body_json(request: &HttpRequest) -> Value {
    request
        .body
        .as_deref()
        .map_or(Value::Null, |body| serde_json::from_slice(body).unwrap())
}

/// The first header named `name`.
pub(crate) fn header<'a>(request: &'a HttpRequest, name: &str) -> Option<&'a str> {
    request
        .headers
        .iter()
        .find(|header| header.name.eq_ignore_ascii_case(name))
        .map(|header| header.value.as_str())
}

/// One fixture HTTP envelope.
#[derive(Debug, Clone)]
pub(crate) struct Envelope {
    pub(crate) method: String,
    pub(crate) path: String,
    pub(crate) after: Option<String>,
    pub(crate) reply: Reply,
    pub(crate) body: Option<Value>,
}

fn transport_error(name: &str) -> TransportError {
    match name {
        "timedOut" => TransportError::Timeout {
            message: name.to_owned(),
        },
        "cancelled" => TransportError::Cancelled,
        "networkConnectionLost" | "cannotConnectToHost" | "notConnectedToInternet" => {
            TransportError::Offline {
                message: name.to_owned(),
            }
        }
        other => TransportError::Other {
            message: other.to_owned(),
        },
    }
}

/// Reads `client-core/fixtures/<path>`.
pub(crate) fn fixture_text(path: &str) -> String {
    let full = format!("{}/../../fixtures/{path}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(&full).unwrap_or_else(|error| panic!("reading {full}: {error}"))
}

/// A `.json` fixture.
pub(crate) fn fixture_json(path: &str) -> Value {
    serde_json::from_str(&fixture_text(path)).unwrap()
}

/// Every line of a `.jsonl` fixture.
pub(crate) fn fixture_lines(path: &str) -> Vec<Value> {
    fixture_text(path)
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

fn is_script(path: &str) -> bool {
    std::path::Path::new(path)
        .extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("jsonl"))
}

/// The envelopes of a `.json` or `.jsonl` fixture, in order.
pub(crate) fn envelopes(path: &str) -> Vec<Envelope> {
    let values = if is_script(path) {
        fixture_lines(path)
    } else {
        vec![fixture_json(path)]
    };
    values
        .iter()
        .map(|value| {
            let request = &value["request"];
            let reply = value.get("error").and_then(Value::as_str).map_or_else(
                || {
                    let status = u16::try_from(value["status"].as_u64().unwrap()).unwrap();
                    let body = match &value["response"] {
                        Value::String(text) => text.clone(),
                        other => other.to_string(),
                    };
                    Reply::json(status, body)
                },
                |error| Reply::Fail(transport_error(error)),
            );
            Envelope {
                method: request["method"].as_str().unwrap_or("GET").to_owned(),
                path: request["path"].as_str().unwrap().to_owned(),
                after: request
                    .get("query")
                    .and_then(|query| query.get("after"))
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                reply,
                body: request.get("body").cloned(),
            }
        })
        .collect()
}

/// Debug policy: loopback http allowed.
pub(crate) const DEBUG: CoreConfig = CoreConfig {
    allows_insecure_http: true,
};

/// A disconnected core over `transport`.
pub(crate) fn core(transport: RouteTransport) -> ClientCore<RouteTransport> {
    ClientCore::new(transport, DEBUG)
}

/// A core over `transport`, connected to the local root.
pub(crate) fn connected(transport: RouteTransport) -> ClientCore<RouteTransport> {
    let core = core(transport);
    block_on(core.connect(ServerEndpoint::new(LOCAL).unwrap(), None, None)).unwrap();
    core
}

/// A core over `transport`, connected to the hosted mount with [`TOKEN`].
pub(crate) fn connected_hosted(transport: RouteTransport) -> ClientCore<RouteTransport> {
    let core = core(transport);
    block_on(core.connect(
        ServerEndpoint::new(&format!("https://127.0.0.1:8443{MOUNT}")).unwrap(),
        Some(SecretString::new(TOKEN)),
        None,
    ))
    .unwrap();
    core
}

/// A connected core with `conv_a` live, as `primeStreamForTesting` set it up.
pub(crate) fn live(transport: RouteTransport) -> ClientCore<RouteTransport> {
    let core = connected(transport);
    core.set_live_session("conv_a", true);
    core
}

/// Records every event.
#[derive(Debug, Default)]
pub(crate) struct Recorder {
    pub(crate) events: Mutex<Vec<ClientEvent>>,
}

impl Recorder {
    pub(crate) fn take(&self) -> Vec<ClientEvent> {
        std::mem::take(&mut self.events.lock().unwrap())
    }
}

impl ClientListener for Recorder {
    fn on_event(&self, event: ClientEvent) {
        self.events.lock().unwrap().push(event);
    }
}

/// Subscribes a fresh [`Recorder`].
pub(crate) fn record<T: HttpTransport>(core: &ClientCore<T>) -> Arc<Recorder> {
    let recorder = Arc::new(Recorder::default());
    let listener: Arc<dyn ClientListener> = recorder.clone();
    core.subscribe(listener);
    recorder
}

/// Polls `future` once; `true` when it is still pending.
pub(crate) fn still_pending<F: Future>(future: Pin<&mut F>) -> bool {
    let waker = Waker::noop();
    let mut context = Context::from_waker(waker);
    future.poll(&mut context).is_pending()
}
