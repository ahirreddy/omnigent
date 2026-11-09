//! Updates handlers called directly, for orders and frames the machine does not produce.

use std::sync::Arc;

use super::*;
use crate::connection::UrlPolicy;
use crate::test_support::{FakeSocket, Harness};

#[test]
fn the_demo_has_no_updates_socket() {
    let harness = Harness::new(UrlPolicy::Development);
    let (mut engine, _queue) = harness.idle_engine();
    engine.transports.sockets = None;
    engine.start_updates();
    assert_eq!(harness.sockets.count(), 0);
    assert_eq!(harness.scheduler.pending_timers(), 0);
}

#[test]
fn a_dial_with_no_connection_opens_nothing() {
    let harness = Harness::new(UrlPolicy::Development);
    let (mut engine, _queue) = harness.idle_engine();
    engine.connect_socket(AttemptId(1));
    assert_eq!(harness.sockets.count(), 0);
}

#[test]
fn closing_another_attempt_leaves_the_current_socket_open() {
    let harness = Harness::new(UrlPolicy::Development);
    let (mut engine, _queue) = harness.idle_engine();
    engine.updates_output(UpdatesOutput::Close {
        attempt: AttemptId(2),
        code: 1000,
        reason: String::new(),
    });
    let handle = Arc::new(FakeSocket::default());
    engine.socket = Some(Socket {
        attempt: AttemptId(2),
        handle: Some(handle.clone()),
        outbox: None,
    });
    engine.updates_output(UpdatesOutput::Close {
        attempt: AttemptId(1),
        code: 1000,
        reason: String::new(),
    });
    assert_eq!(
        engine.socket.as_ref().map(|socket| socket.attempt),
        Some(AttemptId(2))
    );
    assert_eq!(crate::engine::lock(&handle.closes).len(), 0);
    engine.updates_output(UpdatesOutput::Close {
        attempt: AttemptId(2),
        code: 1000,
        reason: String::new(),
    });
    assert!(engine.socket.is_none());
    assert_eq!(crate::engine::lock(&handle.closes).len(), 1);
}

#[test]
fn a_heartbeat_frame_changes_nothing() {
    let harness = Harness::new(UrlPolicy::Development);
    let (mut engine, _queue) = harness.idle_engine();
    engine.updates_frame(UpdatesFrame::Heartbeat);
    assert_eq!(harness.events.all(), []);
}

#[test]
fn a_pushed_session_that_cannot_be_watched_is_reported_on_the_list() {
    let harness = Harness::new(UrlPolicy::Development);
    let (mut engine, _queue) = harness.idle_engine();
    engine.updates_output(UpdatesOutput::DiscoveryNotWatched {
        ids: vec!["conv_new".into()],
        error: omnigent_core::realtime::updates::WatchError::LimitExceeded {
            requested: 501,
            limit: 500,
        },
    });
    let events = harness.events.all();
    assert!(
        matches!(
            events.as_slice(),
            [CoreEvent::Error {
                scope: ErrorScope::SessionList,
                ..
            }]
        ),
        "{events:?}"
    );
}
