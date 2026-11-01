//! Background work and timers on the host's executor, and the HTTP transport the core's REST
//! client runs on (the host's, or the offline demo server).

use std::fmt;
use std::future::Future;
use std::sync::Arc;

use futures::channel::mpsc::UnboundedSender;
use futures::future::{AbortHandle, Abortable};
use omnigent_core as core;
use omnigent_core::demo::DemoTransport;

use crate::host::{Clock, CoreTask, ForeignHttp, Scheduler};

/// The clock and scheduler every driver shares.
#[derive(Clone)]
pub(crate) struct Host {
    pub(crate) clock: Arc<dyn Clock>,
    pub(crate) scheduler: Arc<dyn Scheduler>,
}

impl fmt::Debug for Host {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Host")
    }
}

impl Host {
    /// Runs `future` in the background on the host's executor.
    pub(crate) fn spawn(&self, future: impl Future<Output = ()> + Send + 'static) {
        self.scheduler.spawn(CoreTask::new(future));
    }

    /// Calls `fire` after `delay_ms` unless the returned handle is aborted first. Aborting drops
    /// the host's sleep, which cancels it.
    pub(crate) fn after(&self, delay_ms: u64, fire: impl FnOnce() + Send + 'static) -> AbortHandle {
        let (handle, registration) = AbortHandle::new_pair();
        let scheduler = Arc::clone(&self.scheduler);
        self.spawn(async move {
            let timer = Abortable::new(
                async move {
                    scheduler.sleep(delay_ms).await;
                    fire();
                },
                registration,
            );
            // `Err(Aborted)` means the timer was cancelled on purpose; there is nothing to report.
            timer.await.unwrap_or(());
        });
        handle
    }

    /// Monotonic milliseconds, for the realtime machines.
    pub(crate) fn now_ms(&self) -> u64 {
        self.clock.monotonic_ms()
    }

    /// Unix milliseconds, for token expiry and notifications.
    pub(crate) fn unix_ms(&self) -> u64 {
        self.clock.unix_time_ms()
    }
}

/// Posts `message` to a driver's queue. A closed queue means the core shut down, and the message
/// is meaningless then, so it is dropped.
pub(crate) fn post<T>(sender: &UnboundedSender<T>, message: T) {
    if let Err(error) = sender.unbounded_send(message) {
        drop(error.into_inner());
    }
}

/// The transport the REST client runs on.
#[derive(Clone)]
pub(crate) enum CoreTransport {
    /// The host's `URLSession`.
    Foreign(ForeignHttp),
    /// The offline sample server.
    Demo(Arc<DemoTransport>),
}

impl fmt::Debug for CoreTransport {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Foreign(_) => f.write_str("CoreTransport::Foreign"),
            Self::Demo(_) => f.write_str("CoreTransport::Demo"),
        }
    }
}

impl core::http::HttpTransport for CoreTransport {
    fn send(
        &self,
        request: core::http::HttpRequest,
    ) -> impl Future<Output = Result<core::http::HttpResponse, core::http::TransportError>> {
        let transport = self.clone();
        async move {
            match transport {
                Self::Foreign(http) => core::http::HttpTransport::send(&http, request).await,
                Self::Demo(demo) => core::http::HttpTransport::send(&*demo, request).await,
            }
        }
    }
}

/// The REST session client.
pub(crate) type Sessions = core::ClientCore<CoreTransport>;
