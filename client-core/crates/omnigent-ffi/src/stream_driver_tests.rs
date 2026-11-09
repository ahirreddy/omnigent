//! Stream handlers called directly, for orders a running engine's queue does not produce.

use std::sync::Arc;
use std::sync::atomic::Ordering;

use futures::future::AbortHandle;
use omnigent_core::auth::endpoint::ServerEndpoint;
use omnigent_core::realtime::{StreamEvent, TimerKind, TimerToken};

use super::*;
use crate::connection::UrlPolicy;
use crate::engine::Link;
use crate::test_support::{FakeHandle, Harness};

#[test]
fn handlers_for_a_session_that_has_closed_do_nothing() {
    let harness = Harness::new(UrlPolicy::Development);
    let (mut engine, _queue) = harness.idle_engine();
    engine.link = Some(Link {
        endpoint: ServerEndpoint::new("http://127.0.0.1:6767").unwrap(),
        bearer: None,
    });
    engine.emit_transcript_reset("gone");
    engine.stream_output(
        "gone",
        StreamOutput::ScheduleTimer {
            token: TimerToken {
                kind: TimerKind::Reconnect,
                id: 1,
            },
            delay_ms: 1,
        },
    );
    engine.stream_output(
        "gone",
        StreamOutput::Ready {
            attempt: AttemptId(1),
            resumed: false,
        },
    );
    engine.open_stream("gone", AttemptId(1));
    engine.stream_event(
        "gone",
        AttemptId(1),
        StreamEvent {
            event_type: "session.heartbeat".into(),
            data: serde_json::Map::new(),
        },
    );
    engine.spawn_hydration(
        "gone",
        None,
        ConversationSync::create("gone").open_stream_raw(),
    );
    engine.terminal_event(
        "gone",
        &serde_json::from_value(serde_json::json!({
            "type": "session.terminal.activity",
            "terminal_id": "terminal_main",
        }))
        .unwrap(),
    );
    engine.publish_terminals("gone");
    engine.emit_paging("gone");
    assert_eq!(harness.events.all(), []);
    assert_eq!(harness.streams.count(), 0);
    assert_eq!(harness.scheduler.pending_timers(), 0);
}

#[test]
fn closing_stops_whatever_the_machine_left_behind() {
    let harness = Harness::new(UrlPolicy::Development);
    let (mut engine, _queue) = harness.idle_engine();
    engine.open_session("conv_a");
    let (timer, _registration) = AbortHandle::new_pair();
    let handle = Arc::new(FakeHandle::default());
    let driver = engine.drivers.get_mut("conv_a").unwrap();
    driver.timers.insert(99, timer.clone());
    driver.handles.insert(AttemptId(99), handle.clone());
    engine.close_session("conv_a");
    assert!(timer.is_aborted());
    assert_eq!(handle.cancels.load(Ordering::SeqCst), 1);
    assert!(engine.drivers.is_empty());
}

#[test]
fn a_stream_opened_for_a_session_that_closed_is_cancelled() {
    let harness = Harness::new(UrlPolicy::Development);
    let (mut engine, _queue) = harness.idle_engine();
    let handle = Arc::new(FakeHandle::default());
    engine.keep_stream_handle("gone", AttemptId(1), handle.clone());
    assert_eq!(handle.cancels.load(Ordering::SeqCst), 1);
}
