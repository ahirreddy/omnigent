//! Read state end to end through the real offline demo core: the demo server keeps the viewer's
//! read state like the server does, so unread comes from new activity and opening clears it.

use std::sync::Arc;

use crate::decisions::DecisionResponse;
use crate::engine::DEMO_TICK_MS;
use crate::events::CoreEvent;
use crate::test_support::Harness;

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
