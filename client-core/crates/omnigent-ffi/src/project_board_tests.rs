//! The project board's records and rules over the fake host.

use omnigent_core::sessions::SessionSummary as CoreSummary;

use super::*;
use crate::sessions::{SessionFamily, SessionListStatus};
use crate::test_support::{connected, json as reply};

fn summary(id: &str, updated_at: i64) -> SessionSummary {
    SessionSummary {
        project_id: Some("p1".into()),
        owner: Some("viewer".into()),
        updated_at,
        created_at: updated_at,
        ..SessionSummary::from(CoreSummary::new(id, id, ""))
    }
}

fn project() -> ProjectSummary {
    ProjectSummary {
        id: Some("p1".into()),
        name: "Docs".into(),
        icon: None,
    }
}

fn lanes(columns: &[BoardColumn]) -> Vec<(BoardLane, Vec<String>)> {
    columns
        .iter()
        .map(|column| {
            let heads = column.cards.iter().map(|card| card.session_id.clone());
            (column.lane, heads.collect())
        })
        .collect()
}

#[test]
fn the_board_files_each_session_by_status_read_marks_and_drafts() {
    let running = SessionSummary {
        status: SessionListStatus::Running,
        ..summary("running", 6)
    };
    let family = SessionFamily {
        id: "fam".into(),
        representative_id: Some("head".into()),
        representative_title: None,
        pinned: false,
        pinned_at: None,
    };
    let head = SessionSummary {
        family: Some(family.clone()),
        ..summary("head", 4)
    };
    let nested = SessionSummary {
        family: Some(family),
        is_nested_member: true,
        ..summary("nested", 5)
    };
    let sessions = vec![
        summary("done", 1),
        summary("draft", 2),
        summary("unread", 3),
        head,
        nested,
        running,
    ];
    let columns = project_board(
        project(),
        sessions.clone(),
        vec!["unread".into(), "nested".into()],
        vec!["draft".into()],
        Some("viewer".into()),
        String::new(),
    );
    assert_eq!(
        lanes(&columns),
        [
            (BoardLane::Draft, vec!["draft".to_owned()]),
            (BoardLane::NeedsAttention, vec![]),
            (BoardLane::Working, vec!["running".to_owned()]),
            (
                BoardLane::Unread,
                vec!["head".to_owned(), "unread".to_owned()]
            ),
            (BoardLane::Done, vec!["done".to_owned()]),
        ]
    );
    let family_card = &columns[3].cards[0];
    assert_eq!(family_card.member_ids, ["head", "nested"]);
    assert_eq!(board_opening_lane(columns.clone()), BoardLane::Draft);

    let filtered = project_board(
        project(),
        sessions,
        vec![],
        vec![],
        Some("viewer".into()),
        " NEST ".into(),
    );
    let shown: Vec<_> = lanes(&filtered)
        .into_iter()
        .filter(|(_, heads)| !heads.is_empty())
        .collect();
    assert_eq!(shown, [(BoardLane::Done, vec!["head".to_owned()])]);
}

#[test]
fn drops_mark_read_or_unread_and_name_their_sessions() {
    assert_eq!(
        board_drop_action(BoardLane::Unread, BoardLane::Done),
        Some(BoardDropAction::MarkRead)
    );
    assert_eq!(
        board_drop_action(BoardLane::Done, BoardLane::Unread),
        Some(BoardDropAction::MarkUnread)
    );
    assert_eq!(board_drop_action(BoardLane::Working, BoardLane::Done), None);
    let card = BoardCard {
        session_id: "head".into(),
        member_ids: vec!["head".into(), "nested".into()],
        lane: BoardLane::Unread,
    };
    assert_eq!(
        board_read_marks(
            card.clone(),
            BoardDropAction::MarkRead,
            vec!["nested".into()]
        ),
        ["nested"]
    );
    assert_eq!(
        board_read_marks(card, BoardDropAction::MarkUnread, vec![]),
        ["head"]
    );
    assert_eq!(
        board_lane_title(BoardLane::NeedsAttention),
        "Needs attention"
    );
}

#[test]
fn arrivals_are_new_sessions_the_board_had_not_seen() {
    let sessions = vec![
        summary("seen", 990),
        summary("new", 990),
        summary("old", 10),
    ];
    assert_eq!(
        board_arrivals(sessions, vec!["seen".into()], 1_000),
        ["new"]
    );
}

#[test]
fn a_cards_preview_is_the_last_replys_leading_sentences() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions/s1/items",
        reply(
            200,
            r###"{"data":[
              {"id":"i2","type":"error","code":"x","message":"Runner exited","level":"error"},
              {"id":"i1","type":"message","role":"assistant",
                "content":[{"type":"output_text","text":"## Done\nAll **24** tests pass. Shipped it. Bye."}]}
            ],"has_more":false}"###,
        ),
    );
    let preview = harness
        .call(|core| async move { core.board_reply_preview("s1".into()).await })
        .unwrap();
    assert_eq!(preview.as_deref(), Some("All 24 tests pass. Shipped it."));

    harness.http.route(
        "/v1/sessions/s2/items",
        reply(
            200,
            r#"{"data":[{"id":"c","type":"message","role":"assistant",
                "content":[{"type":"output_text","text":"```\nonly code\n```"}]}],"has_more":false}"#,
        ),
    );
    let none = harness
        .call(|core| async move { core.board_reply_preview("s2".into()).await })
        .unwrap();
    assert_eq!(none, None);
}
