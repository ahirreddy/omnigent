//! Read state end to end through the real offline demo core: the demo server keeps the viewer's
//! read state like the server does, so unread comes from new activity and opening clears it.

use std::sync::Arc;

use futures::FutureExt as _;

use crate::connection::UrlPolicy;
use crate::decisions::DecisionResponse;
use crate::engine::DEMO_TICK_MS;
use crate::events::{CoreEvent, ErrorScope};
use crate::test_support::{Harness, json};

fn unread_events(events: &[CoreEvent]) -> Vec<Vec<String>> {
    events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::UnreadChanged { session_ids } => Some(session_ids.clone()),
            _ => None,
        })
        .collect()
}

fn connected_demo() -> Harness {
    let mut harness = Harness::demo();
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.connect(String::new(), None).await })
        .unwrap();
    harness
}

/// Opens and views the sample question, answers it, and sends a message whose reply streams on
/// the demo's ticks.
fn start_reply(harness: &mut Harness) {
    harness.core.open_session("demo-question".into());
    harness.core.set_view(Some("demo-question".into()), true);
    harness.pump();
    let core = Arc::clone(&harness.core);
    harness
        .run(async move {
            core.resolve_decision(
                "demo-question".into(),
                "decision-question".into(),
                DecisionResponse::Answer {
                    value: "Approvals first".into(),
                },
            )
            .await
        })
        .unwrap();
    harness.pump();
    let core = Arc::clone(&harness.core);
    harness
        .run(async move {
            core.send_message("demo-question".into(), "Go on".into())
                .await
        })
        .unwrap();
}

#[test]
fn a_demo_session_turns_unread_on_new_activity_and_read_when_opened() {
    let mut harness = connected_demo();
    // Nothing is unread at first sight.
    assert_eq!(
        unread_events(&harness.events.take()),
        Vec::<Vec<String>>::new()
    );

    start_reply(&mut harness);
    // The user moves to another session while the reply streams, and it finishes there.
    harness.core.set_view(Some("demo-design".into()), true);
    harness.pump();
    for _ in 0..400 {
        harness.advance(DEMO_TICK_MS);
    }
    let changes = unread_events(&harness.events.take());
    assert_eq!(
        changes.last(),
        Some(&vec!["demo-question".to_owned()]),
        "{changes:?}"
    );

    // Opening it reads it, and the demo server keeps the mark.
    harness.core.set_view(Some("demo-question".into()), true);
    harness.pump();
    let events = harness.events.take();
    assert_eq!(unread_events(&events), vec![Vec::<String>::new()]);
    assert!(
        !events
            .iter()
            .any(|event| matches!(event, CoreEvent::Error { .. })),
        "{events:?}"
    );
    harness.core.refresh_sessions();
    harness.pump();
    assert_eq!(
        unread_events(&harness.events.take()),
        Vec::<Vec<String>>::new()
    );
}

#[test]
fn an_unfocused_window_does_not_read_the_open_session() {
    let mut harness = connected_demo();
    start_reply(&mut harness);
    // The session stays open, but the window loses focus while the reply finishes.
    harness.core.set_view(Some("demo-question".into()), false);
    for _ in 0..400 {
        harness.advance(DEMO_TICK_MS);
    }
    assert_eq!(
        unread_events(&harness.events.take()).last(),
        Some(&vec!["demo-question".to_owned()])
    );
    // Focus returning reads it.
    harness.core.set_view(Some("demo-question".into()), true);
    harness.pump();
    assert_eq!(
        unread_events(&harness.events.take()),
        vec![Vec::<String>::new()]
    );
}

#[test]
fn mark_session_seen_answers_for_a_session_read_elsewhere() {
    let mut harness = connected_demo();
    start_reply(&mut harness);
    harness.core.set_view(None, true);
    for _ in 0..400 {
        harness.advance(DEMO_TICK_MS);
    }
    harness.events.take();
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.mark_session_seen("demo-question".into()).await })
        .unwrap();
    assert_eq!(
        unread_events(&harness.events.take()),
        vec![Vec::<String>::new()]
    );
    // Nothing unread: no request, still a success.
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.mark_session_seen("demo-question".into()).await })
        .unwrap();
    // An unknown session has nothing unread either.
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.mark_session_seen("conv_unknown".into()).await })
        .unwrap();
}

#[test]
fn pending_decisions_read_fresh_without_opening_and_drop_answered_requests() {
    let mut harness = connected_demo();
    let core = Arc::clone(&harness.core);
    let pending = harness
        .run(async move { core.pending_decisions("demo-design".into()).await })
        .unwrap();
    assert_eq!(
        pending
            .iter()
            .map(|card| card.id.as_str())
            .collect::<Vec<_>>(),
        ["decision-design"]
    );
    assert!(matches!(
        pending[0].kind,
        crate::decisions::DecisionKind::Approval
    ));
    assert!(!pending[0].answered);

    let core = Arc::clone(&harness.core);
    harness
        .run(async move {
            core.resolve_decision(
                "demo-design".into(),
                "decision-design".into(),
                DecisionResponse::Approve,
            )
            .await
        })
        .unwrap();
    let core = Arc::clone(&harness.core);
    let after = harness
        .run(async move { core.pending_decisions("demo-design".into()).await })
        .unwrap();
    assert!(after.is_empty(), "{after:?}");

    let core = Arc::clone(&harness.core);
    let invalid = harness.run(async move { core.pending_decisions("../x".into()).await });
    assert!(invalid.is_err());
}

/// A connected harness whose session list is `row`.
fn connected_listing(row: &str) -> Harness {
    let mut harness = Harness::new(UrlPolicy::Development);
    harness.local_server();
    harness.http.route(
        "/v1/sessions",
        json(
            200,
            &format!(r#"{{"object":"list","data":[{row}],"has_more":false}}"#),
        ),
    );
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.connect("http://127.0.0.1:6767".into(), None).await })
        .unwrap();
    harness
}

const ROW: &str = r#"{"id":"conv_a","status":"idle","title":"A","created_at":1,"updated_at":100,"permission_level":4}"#;

/// A connected harness whose list says the server keeps this viewer's read state.
fn connected_tracking_reads() -> Harness {
    connected_listing(&ROW.replace(
        r#""permission_level":4"#,
        r#""permission_level":4,"viewer_last_seen":100"#,
    ))
}

const READ_STATE: &str = "/v1/sessions/conv_a/read-state";

fn set_unread(harness: &mut Harness, unread: bool) -> Result<(), crate::errors::CoreError> {
    let core = Arc::clone(&harness.core);
    harness.run(async move { core.set_session_unread("conv_a".into(), unread).await })
}

#[test]
fn marking_unread_and_read_writes_to_the_server() {
    let mut harness = connected_tracking_reads();
    harness
        .http
        .route_method("PUT", READ_STATE, json(200, r#"{"ok":true}"#));
    harness.events.take();
    set_unread(&mut harness, true).unwrap();
    assert_eq!(harness.http.count(READ_STATE), 1);
    assert_eq!(unread_events(&harness.events.take()), [["conv_a"]]);
    set_unread(&mut harness, false).unwrap();
    assert_eq!(harness.http.count(READ_STATE), 2);
    assert_eq!(
        unread_events(&harness.events.take()),
        [Vec::<String>::new()]
    );
}

#[test]
fn a_write_the_server_refuses_fails_the_caller_and_keeps_the_mark() {
    let mut harness = connected_tracking_reads();
    harness
        .http
        .route_method("PUT", READ_STATE, json(500, r#"{"detail":"boom"}"#));
    harness.events.take();
    assert!(set_unread(&mut harness, true).is_err());
    assert_eq!(unread_events(&harness.events.take()), [["conv_a"]]);
}

#[test]
fn a_write_nobody_waits_for_reports_its_failure_on_the_session() {
    let mut harness = connected_tracking_reads();
    harness
        .http
        .route_method("PUT", READ_STATE, json(200, r#"{"ok":true}"#));
    set_unread(&mut harness, true).unwrap();
    harness
        .http
        .route_method("PUT", READ_STATE, json(500, r#"{"detail":"boom"}"#));
    harness.events.take();
    harness.core.set_view(Some("conv_a".into()), true);
    harness.pump();
    let events = harness.events.take();
    assert!(
        events.iter().any(|event| matches!(
            event,
            CoreEvent::Error {
                scope: ErrorScope::Session { session_id },
                ..
            } if session_id == "conv_a"
        )),
        "{events:#?}"
    );
}

#[test]
fn a_mark_is_only_written_to_a_connected_server_that_keeps_read_state() {
    let mut harness = connected_listing(ROW);
    set_unread(&mut harness, true).unwrap();
    assert_eq!(harness.http.count(READ_STATE), 0);

    let mut harness = connected_tracking_reads();
    harness.core.disconnect();
    harness.pump();
    set_unread(&mut harness, true).unwrap();
    assert_eq!(harness.http.count(READ_STATE), 0);
}

#[test]
fn a_mark_whose_caller_went_away_is_kept() {
    let mut harness = connected_tracking_reads();
    harness
        .http
        .route_method("PUT", READ_STATE, json(200, r#"{"ok":true}"#));
    harness.events.take();
    let mut call = Box::pin(harness.core.set_session_unread("conv_a".into(), true));
    assert_eq!(call.as_mut().now_or_never(), None);
    drop(call);
    harness.pump();
    assert_eq!(harness.http.count(READ_STATE), 1);
    assert_eq!(unread_events(&harness.events.take()), [["conv_a"]]);
}
