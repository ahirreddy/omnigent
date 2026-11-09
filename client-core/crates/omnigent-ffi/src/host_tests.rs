//! The host surface's small parts: debug text, errors a foreign host throws, and short reads.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use futures::executor::block_on;
use omnigent_core::demo::DemoTransport;

use super::core;
use super::*;
use crate::connection::UrlPolicy;
use crate::runtime::{CoreTransport, Host};
use crate::test_support::Harness;

#[test]
fn debug_text_names_the_wrapper_and_nothing_inside_it() {
    let harness = Harness::new(UrlPolicy::Development);
    assert_eq!(format!("{:?}", CoreTask::new(async {})), "CoreTask");
    assert_eq!(format!("{:?}", ByteSink::new(|_| {})), "ByteSink");
    assert_eq!(format!("{:?}", MessageSink::new(|_| {})), "MessageSink");
    let http = ForeignHttp(harness.http.clone());
    assert_eq!(format!("{http:?}"), "ForeignHttp");
    assert_eq!(
        format!("{:?}", ForeignStore(harness.store.clone())),
        "ForeignStore"
    );
    assert_eq!(
        format!("{:?}", ForeignEntropy(harness.entropy.clone())),
        "ForeignEntropy"
    );
    let host = Host {
        clock: harness.clock.clone(),
        scheduler: harness.scheduler,
    };
    assert_eq!(format!("{host:?}"), "Host");
    assert_eq!(
        format!("{:?}", CoreTransport::Foreign(http)),
        "CoreTransport::Foreign"
    );
    assert_eq!(
        format!(
            "{:?}",
            CoreTransport::Demo(Arc::new(DemoTransport::sample().unwrap()))
        ),
        "CoreTransport::Demo"
    );
}

#[test]
fn a_task_runs_once_however_often_the_host_calls_it() {
    let runs = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&runs);
    let task = CoreTask::new(async move {
        counted.fetch_add(1, Ordering::SeqCst);
    });
    block_on(task.run());
    block_on(task.run());
    assert_eq!(runs.load(Ordering::SeqCst), 1);
}

#[test]
fn something_a_foreign_host_throws_outside_its_contract_keeps_its_reason() {
    let unexpected = || uniffi::UnexpectedUniFFICallbackError::new("boom");
    assert_eq!(
        SecureStoreError::from(unexpected()),
        SecureStoreError::Other {
            message: "unexpected secure store error: boom".into()
        }
    );
    assert_eq!(
        EntropyError::from(unexpected()).to_string(),
        EntropyError::Unavailable {
            message: "unexpected entropy error: boom".into()
        }
        .to_string()
    );
    assert_eq!(
        SettingsStorageError::from(unexpected()).to_string(),
        SettingsStorageError::Failed {
            message: "unexpected settings storage error: boom".into()
        }
        .to_string()
    );
}

#[test]
fn every_connection_failure_keeps_its_kind() {
    use core::http::TransportError as Transport;
    use core::realtime::ConnectionFailure as Core;
    let message = || "why".to_owned();
    for (from_host, in_core) in [
        (
            ConnectionFailure::Offline { message: message() },
            Core::Transport(Transport::Offline { message: message() }),
        ),
        (
            ConnectionFailure::Timeout { message: message() },
            Core::Transport(Transport::Timeout { message: message() }),
        ),
        (
            ConnectionFailure::Cancelled,
            Core::Transport(Transport::Cancelled),
        ),
        (
            ConnectionFailure::Tls { message: message() },
            Core::Transport(Transport::Tls { message: message() }),
        ),
        (
            ConnectionFailure::Other { message: message() },
            Core::Transport(Transport::Other { message: message() }),
        ),
        (
            ConnectionFailure::AuthenticationRequired { message: message() },
            Core::AuthenticationRequired { message: message() },
        ),
    ] {
        assert_eq!(Core::from(from_host), in_core);
    }
}

#[test]
fn a_store_failure_keeps_its_kind() {
    let message = || "why".to_owned();
    assert_eq!(
        store_error(SecureStoreError::Other { message: message() }),
        core::auth::SecureStoreError::Other { message: message() }
    );
    assert_eq!(
        store_error(SecureStoreError::Unavailable { message: message() }),
        core::auth::SecureStoreError::Unavailable { message: message() }
    );
}

/// A host RNG that hands back one byte too few.
struct ShortEntropy;

impl EntropySource for ShortEntropy {
    fn random_bytes(&self, len: u32) -> Result<Vec<u8>, EntropyError> {
        Ok(vec![0; usize::try_from(len.saturating_sub(1)).unwrap()])
    }
}

#[test]
fn too_few_random_bytes_are_never_used_as_if_they_were_enough() {
    use core::auth::EntropySource as _;
    let entropy = ForeignEntropy(Arc::new(ShortEntropy));
    assert_eq!(
        entropy.random_bytes(4),
        Err(core::auth::EntropyError::ShortRead {
            requested: 4,
            received: 3,
        })
    );
    assert_eq!(
        entropy.random_bytes(usize::MAX),
        Err(core::auth::EntropyError::ShortRead {
            requested: usize::MAX,
            received: 0,
        })
    );
}

/// Every `with_foreign` trait crosses the boundary as a handle: a Rust object must lift back as
/// itself, with the handle's reference released.
fn crosses_the_boundary<T: ?Sized + uniffi::FfiConverterArc<crate::UniFfiTag>>(object: Arc<T>) {
    let lifted = T::try_lift(T::lower(Arc::clone(&object))).unwrap();
    assert!(Arc::ptr_eq(&object, &lifted));
    drop(lifted);
    assert_eq!(Arc::strong_count(&object), 1);

    // Inside a record or a list the handle travels as eight bytes, which a short read refuses.
    let mut buffer = Vec::new();
    T::write(Arc::clone(&object), &mut buffer);
    let read = T::try_read(&mut buffer.as_slice()).unwrap();
    assert!(Arc::ptr_eq(&object, &read));
    drop(read);
    assert_eq!(Arc::strong_count(&object), 1);
    assert!(T::try_read(&mut buffer.get(..2).unwrap()).is_err());
}

struct NoSettings;

impl SettingsStorage for NoSettings {
    fn get(&self, _key: String) -> Result<Option<String>, SettingsStorageError> {
        Ok(None)
    }

    fn set(&self, _key: String, _value: Option<String>) -> Result<(), SettingsStorageError> {
        Ok(())
    }
}

struct NoPreferences;

impl ManagedPreferenceSource for NoPreferences {
    fn value(&self, _key: String, _domain: String) -> Option<String> {
        None
    }

    fn is_forced(&self, _key: String, _domain: String) -> bool {
        false
    }
}

struct DeafTerminal;

impl crate::terminal::TerminalAttachListener for DeafTerminal {
    fn on_state(&self, _state: crate::terminal::TerminalAttachState) {}
    fn on_output(&self, _bytes: Vec<u8>) {}
    fn on_reset_screen(&self) {}
    fn on_clipboard_write(&self, _text: String) {}
    fn on_input_dropped(&self, _count: u64, _reason: crate::terminal::TerminalInputDropReason) {}
    fn on_notice(&self, _message: String) {}
}

struct DeafBrowser;

impl crate::remote_browser::RemoteBrowserListener for DeafBrowser {
    fn on_state(&self, _snapshot: crate::remote_browser::RemoteBrowserSnapshot) {}
    fn on_video(&self, _frame: crate::remote_browser::VideoFrame) {}
    fn on_still(&self, _still: crate::remote_browser::StillImage) {}
    fn on_closed(&self, _reason: Option<crate::remote_browser::RemoteTabClosedReason>) {}
    fn on_notice(&self, _notice: crate::remote_browser::RemoteBrowserNotice) {}
    fn on_clipboard(&self, _op: crate::remote_browser::RemoteEditOp, _text: String) {}
}

#[test]
fn every_host_object_survives_the_trip_across_the_boundary() {
    use crate::test_support::{
        FakeHandle, FakeHttp, FakeSocket, FakeSockets, FakeStreams, FixedEntropy, ManualClock,
        MemoryStore, Recorder, TestScheduler,
    };
    crosses_the_boundary::<dyn HttpTransport>(Arc::new(FakeHttp::default()));
    crosses_the_boundary::<dyn EventStreamTransport>(Arc::new(FakeStreams::default()));
    crosses_the_boundary::<dyn StreamHandle>(Arc::new(FakeHandle::default()));
    crosses_the_boundary::<dyn WebSocketTransport>(Arc::new(FakeSockets::default()));
    crosses_the_boundary::<dyn WebSocketHandle>(Arc::new(FakeSocket::default()));
    let clock = Arc::new(ManualClock::default());
    crosses_the_boundary::<dyn Scheduler>(Arc::new(TestScheduler::new(Arc::clone(&clock))));
    crosses_the_boundary::<dyn Clock>(clock);
    crosses_the_boundary::<dyn SecureStore>(Arc::new(MemoryStore::default()));
    crosses_the_boundary::<dyn EntropySource>(Arc::new(FixedEntropy::default()));
    crosses_the_boundary::<dyn SettingsStorage>(Arc::new(NoSettings));
    crosses_the_boundary::<dyn ManagedPreferenceSource>(Arc::new(NoPreferences));
    crosses_the_boundary::<dyn crate::events::CoreListener>(Arc::new(Recorder::default()));
    crosses_the_boundary::<dyn crate::terminal::TerminalAttachListener>(Arc::new(DeafTerminal));
    crosses_the_boundary::<dyn crate::remote_browser::RemoteBrowserListener>(Arc::new(DeafBrowser));
}
