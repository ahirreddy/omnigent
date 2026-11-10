//! The session index over real summaries.

use omnigent_core::sessions::{SessionSummary as CoreSummary, SummaryStatus};

use crate::attention::{AttentionState, SessionAttention};
use crate::session_index::{SessionAttentionChange, SessionIndex};
use crate::sessions::{SessionFilter, SessionSummary};

fn summary(id: &str, change: impl FnOnce(&mut CoreSummary)) -> SessionSummary {
    let mut summary = CoreSummary::new(id, "Title", "");
    change(&mut summary);
    SessionSummary::from(summary)
}

fn ids(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|id| (*id).to_owned()).collect()
}

#[test]
fn a_change_reports_the_order_and_attention_it_altered() {
    let index = SessionIndex::new();
    let first = index.reset(
        vec![
            summary("old", |session| session.updated_at = 1),
            summary("new", |session| session.updated_at = 2),
        ],
        ids(&["old"]),
    );
    assert_eq!(first.visible, Some(ids(&["new", "old"])));
    assert_eq!(first.totals.unread, 1);

    // A new preview keeps the row where it is, so no order comes back.
    let preview = summary("old", |session| {
        session.updated_at = 1;
        session.preview = "Reading".into();
    });
    let quiet = index.update(vec![preview], Vec::new());
    assert_eq!(quiet.visible, None);
    assert_eq!(quiet.attention, []);

    let waiting = summary("old", |session| {
        session.updated_at = 3;
        session.status = SummaryStatus::NeedsResponse;
        session.pending_requests = 2;
    });
    let moved = index.update(vec![waiting], Vec::new());
    assert_eq!(moved.visible, Some(ids(&["old", "new"])));
    assert_eq!(moved.needs_response, Some(ids(&["old"])));
    assert_eq!(
        moved.attention,
        [SessionAttentionChange {
            session_id: "old".into(),
            attention: Some(SessionAttention {
                state: AttentionState::NeedsYou,
                requests: 2,
            }),
        }]
    );
    assert_eq!(moved.totals.sessions_needing_you, 1);

    let read = index.set_unread(ids(&["new"]));
    assert_eq!(read.attention.len(), 1);
    assert_eq!(read.totals.unread, 1);

    let searched = index.set_query("none".into(), SessionFilter::All);
    assert_eq!(searched.visible, Some(Vec::new()));

    let removed = index.update(Vec::new(), ids(&["old"]));
    assert_eq!(removed.visible, None);
    assert_eq!(
        removed.attention,
        [SessionAttentionChange {
            session_id: "old".into(),
            attention: None,
        }]
    );
}
