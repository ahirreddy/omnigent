use futures::executor::block_on;
use serde_json::{Value, json};

use super::test_support::summary_of;
use super::*;
use crate::client::projects::ProjectSummary;
use crate::client::session_search::SearchScope;
use crate::client::test_support::{RouteTransport, connected, fixture_lines, path_of, query_value};

const FAMILY_PAGES: &str =
    "sessions/SessionFamilies--ExpandedPagesAppendMembersAfterTheirBoundary.jsonl";
const UPDATE_ROWS: &str = "sessions/SessionFamilies--UpdatesRowsReportFamilyOrNull.jsonl";

fn ids(sessions: &[SessionSummary]) -> Vec<&str> {
    sessions.iter().map(|session| session.id.as_str()).collect()
}

fn update_row(frame: usize) -> Value {
    fixture_lines(UPDATE_ROWS)[frame]["message"]["items"][0].clone()
}

#[test]
fn appended_members_follow_the_page_and_a_later_page_brings_the_newer_row() {
    let transport = RouteTransport::local();
    transport.load(FAMILY_PAGES);
    let core = connected(transport);
    let first = block_on(core.session_page(None, 2)).unwrap();
    assert_eq!(
        ids(&first.sessions),
        ["conv_solo", "conv_lead", "conv_peer"]
    );
    assert_eq!(first.selected_rows, 2);
    assert_eq!(first.next_cursor.as_deref(), Some("conv_lead"));
    let [solo, lead, peer] = first.sessions.as_slice() else {
        panic!("three rows");
    };
    assert_eq!(solo.family, None);
    assert!(!lead.is_nested_member() && lead.is_pinned);
    assert!(peer.is_nested_member() && !peer.is_pinned);
    assert_eq!(peer.family, lead.family);
    assert_eq!(
        peer.family.as_ref().map(|family| family.id.as_str()),
        Some("conv_lead")
    );

    // The member comes again as a selected row of the next page, newer than before, and the
    // representative is appended again after that page's rows.
    let second = block_on(core.session_page(Some("conv_lead"), 50)).unwrap();
    assert_eq!(
        ids(&second.sessions),
        ["conv_peer", "conv_old", "conv_lead"]
    );
    assert_eq!(second.selected_rows, 2);
    assert_eq!(second.next_cursor, None);
    assert_eq!(second.sessions[0].title, "Implementation v2");
    assert_eq!(
        core.cached_summary("conv_peer").map(|row| row.title),
        Some("Implementation v2".to_owned())
    );

    let reads: Vec<_> = core
        .transport()
        .taken()
        .into_iter()
        .filter(|request| path_of(request) == "/v1/sessions")
        .collect();
    assert_eq!(reads.len(), 2);
    for read in &reads {
        assert_eq!(
            query_value(read, "expand_families").as_deref(),
            Some("true")
        );
    }
}

#[test]
fn sidebar_reads_expand_families_and_search_inventory_and_canvas_do_not() {
    let transport = RouteTransport::local();
    transport.ok("/v1/sessions", r#"{"data":[],"has_more":false}"#);
    transport.ok("/v1/projects/p_1", r#"{"id":"p_1","name":"Renamed"}"#);
    let core = connected(transport);
    let expansion = |core: &ClientCore<RouteTransport>| {
        let request = core
            .transport()
            .taken()
            .into_iter()
            .rfind(|request| path_of(request) == "/v1/sessions")
            .unwrap();
        query_value(&request, "expand_families")
    };
    block_on(core.archived_session_page(None, 10)).unwrap();
    assert_eq!(expansion(&core).as_deref(), Some("true"));
    block_on(core.project_session_page("Work", None, 10)).unwrap();
    assert_eq!(expansion(&core).as_deref(), Some("true"));
    block_on(core.search_sessions("plan", SearchScope::Title, 10)).unwrap();
    assert_eq!(expansion(&core), None);
    block_on(core.session_inventory()).unwrap();
    assert_eq!(expansion(&core), None);
    block_on(core.canvas_sessions(None)).unwrap();
    assert_eq!(expansion(&core), None);
    // Re-filing a project's members reads every member already, archived included.
    let project = ProjectSummary {
        id: Some("p_1".to_owned()),
        name: "Work".to_owned(),
        icon: None,
    };
    block_on(core.rename_project(&project, "Renamed")).unwrap();
    assert_eq!(expansion(&core), None);
}

#[test]
fn an_update_row_with_a_null_family_clears_it_and_a_list_row_without_one_has_none() {
    let core = connected(RouteTransport::local());
    let member = core.apply_session_rows(vec![update_row(0)]).unwrap();
    assert!(member[0].is_nested_member());
    let cleared = core.apply_session_rows(vec![update_row(1)]).unwrap();
    assert_eq!(cleared[0].family, None);

    let listed = core.apply_session_rows(vec![update_row(0)]).unwrap();
    assert!(listed[0].family.is_some());
    // `GET /v1/sessions` leaves `family` out of a row that has none.
    let mut without = update_row(0);
    without.as_object_mut().unwrap().remove("family");
    let standalone = core.apply_session_rows(vec![without]).unwrap();
    assert_eq!(standalone[0].family, None);
}

#[test]
fn a_snapshot_sets_clears_or_keeps_the_family() {
    let family = json!({"id": "lead", "representative_id": "lead", "pinned": true,
                        "pinned_at": "9"});
    let member = summary_of(&json!({"id": "peer", "family": family}), None, true);
    let known = member.family.clone().unwrap();
    assert!(member.is_nested_member());
    assert_eq!(known.pinned_at.as_deref(), Some("9"));
    // A sparse snapshot that does not report the family keeps it; `null` clears it.
    let kept = summary_of(&json!({"id": "peer"}), Some(&member), true);
    assert_eq!(kept.family, Some(known));
    let cleared = summary_of(&json!({"id": "peer", "family": null}), Some(&member), true);
    assert_eq!(cleared.family, None);
}

#[test]
fn the_newer_summary_keeps_its_family_whichever_read_arrives_last() {
    let family = SessionFamily {
        id: "lead".to_owned(),
        representative_id: Some("lead".to_owned()),
        representative_title: None,
        pinned: false,
        pinned_at: None,
    };
    let older = SessionSummary {
        configuration_revision: Some(1),
        ..SessionSummary::new("peer", "Old", "")
    };
    let newer = SessionSummary {
        configuration_revision: Some(2),
        family: Some(family),
        ..SessionSummary::new("peer", "New", "")
    };
    // An older read neither drops the family a newer one reported nor brings back a cleared one.
    assert_eq!(older.preserving_newer_metadata(Some(&newer)), newer);
    let cleared = SessionSummary {
        configuration_revision: Some(3),
        family: None,
        ..newer.clone()
    };
    assert_eq!(newer.preserving_newer_metadata(Some(&cleared)), cleared);
}

#[test]
fn a_list_row_carries_its_stored_pull_request_and_whether_an_automation_ran_it() {
    use crate::client::pull_requests::PullRequestStatus;

    let core = connected(RouteTransport::local());
    let mut row = update_row(0);
    row["pull_request"] = json!({
        "url": "https://example.com/acme/app/pull/212", "provider": "github",
        "repository": "acme/app", "number": 212, "state": "MERGED",
        "state_checked_at": 1_700_000_000.5, "title": "Ship the upload retry",
        "provider_display": {"number_prefix": "!", "request_name": "merge request"},
    });
    row["labels"] = json!({
        "omnigent.scheduled_task_origin": "t1", "omnigent.scheduled_task_initial_run": "r1",
    });
    let listed = core.apply_session_rows(vec![row.clone()]).unwrap();
    let pull_request = listed[0].pull_request.clone().unwrap();
    assert_eq!(pull_request.number, 212);
    assert_eq!(pull_request.status, PullRequestStatus::Merged);
    assert_eq!(pull_request.checked_at, Some(1_700_000_000));
    assert_eq!(pull_request.url, "https://example.com/acme/app/pull/212");
    assert_eq!(pull_request.title.as_deref(), Some("Ship the upload retry"));
    assert_eq!(pull_request.number_prefix, "!");
    assert_eq!(pull_request.request_name.as_deref(), Some("merge request"));
    assert!(listed[0].is_automation_run);

    row["pull_request"] = Value::Null;
    row["labels"] = json!({"omnigent.scheduled_task_origin": "t1"});
    let cleared = core.apply_session_rows(vec![row.clone()]).unwrap();
    assert_eq!(cleared[0].pull_request, None);
    assert!(
        !cleared[0].is_automation_run,
        "a fork keeps the origin but not the run"
    );
    row["labels"] = json!({"omnigent.scheduled_task_launch": "t1"});
    assert!(core.apply_session_rows(vec![row]).unwrap()[0].is_automation_run);
}

#[test]
fn an_archived_row_carries_its_archive_time_label() {
    let core = connected(RouteTransport::local());
    let mut row = update_row(0);
    let archived_at =
        |row: &Value| core.apply_session_rows(vec![row.clone()]).unwrap()[0].archived_at;
    row["labels"] = json!({"omnigent.archived_at": "1700000000"});
    assert_eq!(archived_at(&row), Some(1_700_000_000));
    // A row without labels keeps what was known.
    row.as_object_mut().unwrap().remove("labels");
    assert_eq!(archived_at(&row), Some(1_700_000_000));
    for unusable in ["", "soon", "0", "-5", "1.5"] {
        row["labels"] = json!({"omnigent.archived_at": unusable});
        assert_eq!(archived_at(&row), None, "{unusable:?}");
    }
    row["labels"] = json!({});
    assert_eq!(archived_at(&row), None);
}
