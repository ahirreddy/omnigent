//! The attention records over real summaries.

use omnigent_core::session_attention as core;
use omnigent_core::sessions::{SessionSummary as CoreSummary, SummaryStatus};

use crate::attention::{AttentionState, AttentionTotals, attention_totals, session_attention};
use crate::sessions::SessionSummary;

fn summary(id: &str, change: impl FnOnce(&mut CoreSummary)) -> SessionSummary {
    let mut summary = CoreSummary::new(id, "Title", "");
    change(&mut summary);
    SessionSummary::from(summary)
}

#[test]
fn every_state_maps() {
    for (on_core, on_ffi) in [
        (core::AttentionState::NeedsYou, AttentionState::NeedsYou),
        (core::AttentionState::Failed, AttentionState::Failed),
        (core::AttentionState::Working, AttentionState::Working),
        (core::AttentionState::Unread, AttentionState::Unread),
        (core::AttentionState::Idle, AttentionState::Idle),
    ] {
        assert_eq!(AttentionState::from(on_core), on_ffi);
    }
}

#[test]
fn a_session_reports_the_most_urgent_state_and_its_requests() {
    let needs = summary("a", |session| session.pending_requests = 3);
    let attention = session_attention(needs, false);
    assert_eq!(attention.state, AttentionState::NeedsYou);
    assert_eq!(attention.requests, 3);

    let failed = summary("b", |session| session.failure_message = Some("boom".into()));
    assert_eq!(
        session_attention(failed, true).state,
        AttentionState::Failed
    );
    let running = summary("c", |session| session.status = SummaryStatus::Running);
    assert_eq!(
        session_attention(running, true).state,
        AttentionState::Working
    );
    assert_eq!(
        session_attention(summary("d", |_| {}), true).state,
        AttentionState::Unread
    );
    let idle = session_attention(summary("e", |_| {}), false);
    assert_eq!(idle.state, AttentionState::Idle);
    assert_eq!(idle.requests, 0);
}

#[test]
fn the_totals_count_each_field_and_read_the_unread_ids() {
    let sessions = vec![
        summary("needs", |session| session.pending_requests = 2),
        summary("needs_archived", |session| {
            session.pending_requests = 3;
            session.is_archived = true;
        }),
        summary("run1", |session| session.status = SummaryStatus::Running),
        summary("run2", |session| session.status = SummaryStatus::Running),
        summary("run3", |session| session.status = SummaryStatus::Running),
        summary("fail1", |session| {
            session.failure_message = Some("x".into());
        }),
        summary("fail2", |session| {
            session.failure_message = Some("x".into());
        }),
        summary("unread", |_| {}),
        summary("read", |_| {}),
    ];
    assert_eq!(
        attention_totals(sessions, vec!["unread".into()]),
        AttentionTotals {
            sessions_needing_you: 2,
            requests: 5,
            working: 3,
            failed: 2,
            unread: 1,
        }
    );
}
