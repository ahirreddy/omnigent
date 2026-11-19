//! Ported from the web's `projectHome/projectKanban.test.ts` and `leadingSentences`' tests.

use std::collections::{BTreeMap, BTreeSet};

use super::*;
use crate::client::sessions::SummaryStatus;
use crate::session_families::SessionFamily;

fn row(id: &str, created_at: i64) -> SessionSummary {
    SessionSummary {
        created_at,
        updated_at: created_at,
        ..SessionSummary::new(id, id, "")
    }
}

fn in_family(id: &str, created_at: i64) -> SessionSummary {
    SessionSummary {
        family: Some(SessionFamily {
            id: "family".into(),
            representative_id: Some("parent".into()),
            representative_title: None,
            pinned: false,
            pinned_at: None,
        }),
        ..row(id, created_at)
    }
}

fn project(id: Option<&str>, name: &str) -> ProjectSummary {
    ProjectSummary {
        id: id.map(str::to_owned),
        name: name.to_owned(),
        icon: None,
    }
}

fn member_ids(columns: &[BoardColumn], lane: BoardLane) -> Vec<Vec<String>> {
    columns
        .iter()
        .find(|column| column.lane == lane)
        .map(|column| {
            column
                .cards
                .iter()
                .map(|card| card.member_ids.clone())
                .collect()
        })
        .unwrap_or_default()
}

#[test]
fn one_card_per_family_sits_in_its_most_urgent_members_lane_in_row_order() {
    let rows = [
        row("done_a", 1),
        in_family("parent", 2),
        row("unread", 3),
        in_family("nested", 4),
        row("done_b", 5),
    ];
    let refs: Vec<&SessionSummary> = rows.iter().collect();
    let lanes = BTreeMap::from([
        ("done_a", BoardLane::Done),
        ("parent", BoardLane::Done),
        ("unread", BoardLane::Unread),
        ("nested", BoardLane::NeedsAttention),
        ("done_b", BoardLane::Done),
    ]);
    let columns = board_columns(&refs, |session| lanes[session.id.as_str()]);

    let order: Vec<BoardLane> = columns.iter().map(|column| column.lane).collect();
    assert_eq!(order, BoardLane::ALL);
    assert_eq!(
        member_ids(&columns, BoardLane::NeedsAttention),
        [["parent", "nested"]]
    );
    let card = &columns[1].cards[0];
    assert_eq!(card.session_id, "parent");
    assert_eq!(card.lane, BoardLane::NeedsAttention);
    assert_eq!(member_ids(&columns, BoardLane::Unread), [["unread"]]);
    assert_eq!(
        member_ids(&columns, BoardLane::Working),
        Vec::<Vec<String>>::new()
    );
    assert_eq!(
        member_ids(&columns, BoardLane::Done),
        [["done_a"], ["done_b"]]
    );
}

#[test]
fn a_family_leads_with_its_representative_then_lists_the_rest_newest_first() {
    let rows = [
        in_family("old", 1),
        in_family("new", 9),
        in_family("parent", 5),
    ];
    let refs: Vec<&SessionSummary> = rows.iter().collect();
    let columns = board_columns(&refs, |_| BoardLane::Done);
    assert_eq!(
        member_ids(&columns, BoardLane::Done),
        [["parent", "new", "old"]]
    );
}

#[test]
fn lanes_follow_the_sidebars_status_buckets() {
    let idle = row("a", 1);
    assert_eq!(lane_of(&idle, false, false), BoardLane::Done);
    assert_eq!(lane_of(&idle, false, true), BoardLane::Draft);
    assert_eq!(lane_of(&idle, true, true), BoardLane::Unread);
    let running = SessionSummary {
        status: SummaryStatus::Running,
        ..row("b", 1)
    };
    assert_eq!(lane_of(&running, true, true), BoardLane::Working);
    let background = SessionSummary {
        background_work_running: true,
        ..row("c", 1)
    };
    assert_eq!(lane_of(&background, false, false), BoardLane::Working);
    let waiting = SessionSummary {
        status: SummaryStatus::NeedsResponse,
        pending_requests: 1,
        ..row("d", 1)
    };
    assert_eq!(lane_of(&waiting, true, false), BoardLane::NeedsAttention);
    let failed = SessionSummary {
        failure_message: Some("boom".into()),
        ..row("e", 1)
    };
    assert_eq!(lane_of(&failed, false, false), BoardLane::NeedsAttention);
    let parked = SessionSummary {
        status: SummaryStatus::NeedsResponse,
        blocked_on: Some("permission prompt".into()),
        ..row("f", 1)
    };
    assert_eq!(lane_of(&parked, false, false), BoardLane::NeedsAttention);
}

#[test]
fn cards_move_only_between_unread_and_done() {
    use BoardLane::{Done, Draft, NeedsAttention, Unread, Working};
    assert_eq!(drop_action(Unread, Done), Some(BoardDropAction::MarkRead));
    assert_eq!(drop_action(Done, Unread), Some(BoardDropAction::MarkUnread));
    assert_eq!(drop_action(Unread, Working), None);
    assert_eq!(drop_action(Done, Draft), None);
    assert_eq!(drop_action(NeedsAttention, Done), None);
    assert_eq!(drop_action(Done, Done), None);
}

#[test]
fn marking_read_clears_each_unread_member_and_unread_flags_the_head() {
    let card = BoardCard {
        session_id: "parent".into(),
        member_ids: vec!["parent".into(), "nested".into(), "other".into()],
        lane: BoardLane::Unread,
    };
    let unread = |id: &str| id != "parent";
    assert_eq!(
        read_marks(&card, BoardDropAction::MarkRead, unread),
        ["nested", "other"]
    );
    assert_eq!(
        read_marks(&card, BoardDropAction::MarkUnread, unread),
        ["parent"]
    );
}

#[test]
fn the_filter_keeps_cards_with_any_matching_member_ignoring_case_and_padding() {
    let titled = |id: &str, title: &str| SessionSummary::new(id, title, "");
    let sessions = BTreeMap::from([
        ("a", titled("a", "Fix login bug")),
        ("b", titled("b", "Refactor")),
        ("c", titled("c", "Add LOGIN test")),
        ("d", titled("d", "Update docs")),
        ("conv_9", titled("conv_9", "Untitled session")),
    ]);
    let card = |ids: &[&str]| BoardCard {
        session_id: ids[0].to_owned(),
        member_ids: ids.iter().map(|id| (*id).to_owned()).collect(),
        lane: BoardLane::Done,
    };
    let columns = || {
        vec![BoardColumn {
            lane: BoardLane::Done,
            cards: vec![
                card(&["a"]),
                card(&["b", "c"]),
                card(&["d"]),
                card(&["conv_9"]),
            ],
        }]
    };
    let lookup = |id: &str| sessions.get(id).cloned();
    let heads = |columns: Vec<BoardColumn>| -> Vec<String> {
        columns[0]
            .cards
            .iter()
            .map(|card| card.session_id.clone())
            .collect()
    };
    assert_eq!(
        heads(filter_columns(columns(), "  login ", lookup)),
        ["a", "b"]
    );
    assert_eq!(
        heads(filter_columns(columns(), "missing", lookup)),
        Vec::<String>::new()
    );
    assert_eq!(
        heads(filter_columns(columns(), " ", lookup)),
        ["a", "b", "d", "conv_9"]
    );
    // The id matches too.
    assert_eq!(
        heads(filter_columns(columns(), "CONV_", lookup)),
        ["conv_9"]
    );
}

#[test]
fn the_board_holds_the_projects_own_unarchived_sessions_newest_first() {
    let filed = |id: &str, updated_at: i64| SessionSummary {
        project_id: Some("p1".into()),
        owner: Some("viewer".into()),
        updated_at,
        ..SessionSummary::new(id, id, "")
    };
    let labelled = SessionSummary {
        project_label: Some("Docs".into()),
        project_id: None,
        ..filed("labelled", 5)
    };
    let archived = SessionSummary {
        is_archived: true,
        ..filed("archived", 9)
    };
    let teammates = SessionSummary {
        owner: Some("teammate".into()),
        ..filed("teammates", 8)
    };
    let elsewhere = SessionSummary {
        project_id: Some("p2".into()),
        ..filed("elsewhere", 7)
    };
    let sessions = [
        filed("older", 1),
        labelled,
        archived,
        teammates,
        elsewhere,
        filed("newer", 3),
        filed("older", 1),
    ];
    let ids = |rows: Vec<&SessionSummary>| -> Vec<String> {
        rows.iter().map(|row| row.id.clone()).collect()
    };
    assert_eq!(
        ids(board_sessions(
            &project(Some("p1"), "Docs"),
            &sessions,
            Some("viewer")
        )),
        ["labelled", "newer", "older"]
    );
    let other = board_sessions(&project(Some("p3"), "Other"), &sessions, Some("viewer"));
    assert_eq!(ids(other), Vec::<String>::new());
}

#[test]
fn a_phone_opens_on_the_first_lane_with_cards() {
    let rows = [row("a", 1)];
    let refs: Vec<&SessionSummary> = rows.iter().collect();
    let columns = board_columns(&refs, |_| BoardLane::Unread);
    assert_eq!(opening_lane(&columns), BoardLane::Unread);
    assert_eq!(
        opening_lane(&board_columns(&[], |_| BoardLane::Done)),
        BoardLane::Draft
    );
}

#[test]
fn only_newly_created_sessions_arrive() {
    let known = BTreeSet::from(["seen".to_owned()]);
    let rows = [row("seen", 990), row("new", 990), row("paged_in", 100)];
    assert_eq!(arrivals(&rows, &known, 1_000), ["new"]);
    assert_eq!(arrivals(&rows, &known, 1_100), Vec::<String>::new());
}

#[test]
fn a_preview_keeps_the_leading_sentences_without_markdown() {
    let text = [
        "## Summary",
        "I reviewed **three** subscriptions. Netflix renews on `May 2`! Spotify is unused.",
        "```ts",
        "const ignored = true.",
        "```",
    ]
    .join("\n");
    assert_eq!(
        leading_sentences(&text, 2),
        "I reviewed three subscriptions. Netflix renews on May 2!"
    );
    assert_eq!(
        leading_sentences("- Fixed the badge\n- Added a test", 2),
        "Fixed the badge Added a test"
    );
    assert_eq!(leading_sentences("Only one.", 2), "Only one.");
    assert_eq!(leading_sentences("```\ncode only\n```", 2), "");
    assert_eq!(
        leading_sentences("> Quoted. 1) Numbered e.g. like this. Third.", 2),
        "Quoted. 1) Numbered e.g. like this."
    );
    assert_eq!(
        leading_sentences("Version 3.5 shipped (finally). Next up.", 1),
        "Version 3.5 shipped (finally)."
    );
    assert_eq!(leading_sentences("完了。次へ", 1), "完了。");
}
