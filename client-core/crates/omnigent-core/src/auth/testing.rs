//! Test doubles for the auth host traits: deterministic entropy, an in-memory secure store, and a
//! scripted HTTP transport. Shared with `auth::databricks` tests.

#![allow(
    clippy::redundant_pub_crate,
    reason = "test-only helpers; `pub` would trip rustc's unreachable_pub instead"
)]
#![allow(
    clippy::future_not_send,
    reason = "test executors are single-threaded; the doubles are deliberately !Send"
)]

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, VecDeque};
use std::future::{Future, ready};

use super::{EntropyError, EntropySource, SecureStore, SecureStoreError, SecureStoreKey};
use crate::http::{HttpHeader, HttpRequest, HttpResponse, HttpTransport, TransportError};

/// Entropy that returns predictable bytes.
#[derive(Debug)]
pub(crate) struct FixedEntropy {
    mode: EntropyMode,
    counter: Cell<u8>,
}

#[derive(Debug)]
enum EntropyMode {
    Counting,
    Short(usize),
    Failing,
}

impl FixedEntropy {
    /// Each call returns bytes `n, n+1, ...` starting where the last call stopped.
    pub(crate) const fn counting() -> Self {
        Self {
            mode: EntropyMode::Counting,
            counter: Cell::new(0),
        }
    }

    /// Always returns `len` bytes no matter how many were asked for.
    pub(crate) const fn short(len: usize) -> Self {
        Self {
            mode: EntropyMode::Short(len),
            counter: Cell::new(0),
        }
    }

    /// Always fails.
    pub(crate) const fn failing() -> Self {
        Self {
            mode: EntropyMode::Failing,
            counter: Cell::new(0),
        }
    }
}

impl EntropySource for FixedEntropy {
    fn random_bytes(&self, len: usize) -> Result<Vec<u8>, EntropyError> {
        let len = match self.mode {
            EntropyMode::Counting => len,
            EntropyMode::Short(short) => short,
            EntropyMode::Failing => {
                return Err(EntropyError::Unavailable {
                    message: "rng down".into(),
                });
            }
        };
        Ok((0..len)
            .map(|_| {
                let value = self.counter.get();
                self.counter.set(value.wrapping_add(1));
                value
            })
            .collect())
    }
}

/// An in-memory [`SecureStore`] that records operations and can be told to fail.
#[derive(Debug, Default)]
pub(crate) struct MemoryStore {
    pub(crate) items: RefCell<BTreeMap<(String, String), Vec<u8>>>,
    pub(crate) log: RefCell<Vec<String>>,
    pub(crate) fail_get: Cell<bool>,
    pub(crate) fail_set: Cell<bool>,
    pub(crate) fail_delete: Cell<bool>,
}

impl MemoryStore {
    pub(crate) fn insert(&self, key: &SecureStoreKey, value: &[u8]) {
        self.items
            .borrow_mut()
            .insert((key.namespace.clone(), key.account.clone()), value.to_vec());
    }

    pub(crate) fn value(&self, key: &SecureStoreKey) -> Option<Vec<u8>> {
        self.items
            .borrow()
            .get(&(key.namespace.clone(), key.account.clone()))
            .cloned()
    }

    fn failure(op: &str) -> SecureStoreError {
        SecureStoreError::Other {
            message: format!("{op} failed (-25308)"),
        }
    }
}

impl SecureStore for MemoryStore {
    fn get(
        &self,
        key: SecureStoreKey,
    ) -> impl Future<Output = Result<Option<Vec<u8>>, SecureStoreError>> {
        self.log
            .borrow_mut()
            .push(format!("get {}/{}", key.namespace, key.account));
        ready(if self.fail_get.get() {
            Err(Self::failure("get"))
        } else {
            Ok(self.value(&key))
        })
    }

    fn set(
        &self,
        key: SecureStoreKey,
        value: Vec<u8>,
    ) -> impl Future<Output = Result<(), SecureStoreError>> {
        self.log
            .borrow_mut()
            .push(format!("set {}/{}", key.namespace, key.account));
        ready(if self.fail_set.get() {
            Err(Self::failure("set"))
        } else {
            self.insert(&key, &value);
            Ok(())
        })
    }

    fn delete(&self, key: SecureStoreKey) -> impl Future<Output = Result<(), SecureStoreError>> {
        self.log
            .borrow_mut()
            .push(format!("delete {}/{}", key.namespace, key.account));
        ready(if self.fail_delete.get() {
            Err(Self::failure("delete"))
        } else {
            self.items
                .borrow_mut()
                .remove(&(key.namespace, key.account));
            Ok(())
        })
    }
}

/// A transport that answers from a queue of scripted replies and records every request.
#[derive(Debug, Default)]
pub(crate) struct ScriptedTransport {
    replies: RefCell<VecDeque<Result<HttpResponse, TransportError>>>,
    pub(crate) requests: RefCell<Vec<HttpRequest>>,
}

impl ScriptedTransport {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// Queues a reply.
    pub(crate) fn push(&self, reply: Result<HttpResponse, TransportError>) -> &Self {
        self.replies.borrow_mut().push_back(reply);
        self
    }

    /// Queues a JSON reply.
    pub(crate) fn json(&self, status: u16, body: &str) -> &Self {
        self.push(Ok(response(status, "application/json", body)))
    }

    /// Queues a reply with an arbitrary content type.
    pub(crate) fn reply(&self, status: u16, content_type: &str, body: &str) -> &Self {
        self.push(Ok(response(status, content_type, body)))
    }

    /// Queues a transport failure.
    pub(crate) fn fail(&self, error: TransportError) -> &Self {
        self.push(Err(error))
    }

    /// Takes the recorded requests.
    pub(crate) fn take(&self) -> Vec<HttpRequest> {
        self.requests.take()
    }

    pub(crate) fn remaining(&self) -> usize {
        self.replies.borrow().len()
    }
}

impl ScriptedTransport {
    /// Records `request` and pops the next scripted reply.
    pub(crate) fn next_reply(&self, request: HttpRequest) -> Result<HttpResponse, TransportError> {
        let summary = format!("{} {}", request.method, request.url);
        self.requests.borrow_mut().push(request);
        self.replies.borrow_mut().pop_front().unwrap_or_else(|| {
            Err(TransportError::Other {
                message: format!("unscripted request {summary}"),
            })
        })
    }
}

impl HttpTransport for ScriptedTransport {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, TransportError>> {
        ready(self.next_reply(request))
    }
}

/// A [`ScriptedTransport`] whose replies to URLs containing `gated` wait until [`Gate::open`].
#[derive(Debug)]
pub(crate) struct GatedTransport {
    pub(crate) inner: ScriptedTransport,
    pub(crate) gate: std::rc::Rc<Gate>,
    gated: String,
}

/// A one-shot latch that wakes every waiting reply.
#[derive(Debug, Default)]
pub(crate) struct Gate {
    open: Cell<bool>,
    wakers: RefCell<Vec<std::task::Waker>>,
}

impl Gate {
    pub(crate) fn open(&self) {
        self.open.set(true);
        for waker in self.wakers.borrow_mut().drain(..) {
            waker.wake();
        }
    }
}

impl GatedTransport {
    pub(crate) fn new(gated: &str) -> Self {
        Self {
            inner: ScriptedTransport::new(),
            gate: std::rc::Rc::default(),
            gated: gated.to_owned(),
        }
    }
}

struct GatedReply {
    gate: std::rc::Rc<Gate>,
    reply: Option<Result<HttpResponse, TransportError>>,
}

impl Future for GatedReply {
    type Output = Result<HttpResponse, TransportError>;

    fn poll(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Self::Output> {
        if !self.gate.open.get() {
            self.gate.wakers.borrow_mut().push(cx.waker().clone());
            return std::task::Poll::Pending;
        }
        std::task::Poll::Ready(self.reply.take().unwrap_or_else(|| {
            Err(TransportError::Other {
                message: "polled after completion".into(),
            })
        }))
    }
}

impl HttpTransport for GatedTransport {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, TransportError>> {
        let gated = request.url.contains(&self.gated);
        let reply = self.inner.next_reply(request);
        GatedReply {
            gate: if gated {
                std::rc::Rc::clone(&self.gate)
            } else {
                std::rc::Rc::new(Gate {
                    open: Cell::new(true),
                    wakers: RefCell::default(),
                })
            },
            reply: Some(reply),
        }
    }
}

/// A response with one `Content-Type` header.
pub(crate) fn response(status: u16, content_type: &str, body: &str) -> HttpResponse {
    HttpResponse {
        status,
        headers: vec![HttpHeader::new("Content-Type", content_type)],
        body: body.as_bytes().to_vec(),
    }
}

/// The body of `request` as UTF-8.
pub(crate) fn body_text(request: &HttpRequest) -> String {
    String::from_utf8(request.body.clone().unwrap_or_default()).unwrap_or_default()
}

/// The first header named `name`, case-insensitively.
pub(crate) fn header<'a>(request: &'a HttpRequest, name: &str) -> Option<&'a str> {
    request
        .headers
        .iter()
        .find(|h| h.name.eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str())
}

/// Reads `client-core/fixtures/<path>`.
pub(crate) fn fixture(path: &str) -> String {
    let full = format!("{}/../../fixtures/{path}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(&full).unwrap_or_else(|error| panic!("reading {full}: {error}"))
}

/// Polls `a` and `b` (in that order) until both finish, like `futures::join!` (whose macro needs
/// a feature the workspace does not enable).
pub(crate) async fn join2<A: Future, B: Future>(a: A, b: B) -> (A::Output, B::Output) {
    let mut a = Box::pin(a);
    let mut b = Box::pin(b);
    let mut a_out = None;
    let mut b_out = None;
    std::future::poll_fn(|cx| {
        if a_out.is_none()
            && let std::task::Poll::Ready(value) = a.as_mut().poll(cx)
        {
            a_out = Some(value);
        }
        if b_out.is_none()
            && let std::task::Poll::Ready(value) = b.as_mut().poll(cx)
        {
            b_out = Some(value);
        }
        if a_out.is_some() && b_out.is_some() {
            std::task::Poll::Ready(())
        } else {
            std::task::Poll::Pending
        }
    })
    .await;
    match (a_out, b_out) {
        (Some(a), Some(b)) => (a, b),
        _ => unreachable!("poll_fn finished only with both outputs"),
    }
}

/// Polls `future` once.
pub(crate) async fn poll_once<F: Future + ?Sized>(
    future: std::pin::Pin<&mut F>,
) -> std::task::Poll<F::Output> {
    let mut future = Some(future);
    std::future::poll_fn(|cx| {
        let poll = future
            .take()
            .map_or(std::task::Poll::Pending, |f| f.poll(cx));
        std::task::Poll::Ready(poll)
    })
    .await
}
