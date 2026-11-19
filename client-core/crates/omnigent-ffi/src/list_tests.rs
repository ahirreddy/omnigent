//! Session list paging: "Load more" and reloads that keep the loaded pages.

use std::sync::Arc;

use serde_json::{Value, json};

use super::ListMsg;
use crate::connection::UrlPolicy;
use crate::engine::{Msg, lock};
use crate::events::{ConnectionPhase, CoreEvent, ErrorScope};
use crate::sessions::SessionListChange;
use crate::test_support::{Harness, envelope_response, json as respond};

/// The recorded list's rows, split into pages: rows before `split`, then the rest.
fn pages(split: usize) -> (String, String) {
    let recorded: Value =
        serde_json::from_str(&envelope_response("sessions/recorded-sessions-list.json")).unwrap();
    let rows = recorded["data"].as_array().unwrap();
    let page = |rows: &[Value], has_more: bool| {
        json!({
            "object": "list",
            "data": rows,
            "first_id": rows.first().map(|row| row["id"].clone()),
            "last_id": rows.last().map(|row| row["id"].clone()),
            "has_more": has_more,
        })
        .to_string()
    };
    (page(&rows[..split], true), page(&rows[split..], false))
}

fn connected_with_first_page() -> (Harness, String) {
    let mut harness = Harness::new(UrlPolicy::Development);
    harness.local_server();
    let (first, _) = pages(2);
    harness.http.route("/v1/sessions", respond(200, &first));
    let core = Arc::clone(&harness.core);
    let phase = harness
        .run(async move { core.connect("http://127.0.0.1:6767".into(), None).await })
        .unwrap();
    assert!(matches!(phase, ConnectionPhase::Connected { .. }));
    let cursor = serde_json::from_str::<Value>(&first).unwrap()["last_id"]
        .as_str()
        .unwrap()
        .to_owned();
    (harness, cursor)
}

fn paging(events: &[CoreEvent]) -> Vec<(bool, bool)> {
    events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::SessionListPagingChanged {
                has_more,
                is_loading,
            } => Some((*has_more, *is_loading)),
            _ => None,
        })
        .collect()
}

/// Whether `url` is the pinned read beside a reload's page.
fn is_pinned_read(url: &url::Url) -> bool {
    url.query_pairs()
        .any(|(key, value)| key == "pinned" && value == "true")
}

/// The `name` query value of every `GET /v1/sessions` page request (the pinned reads apart).
fn list_queries(harness: &Harness, name: &str) -> Vec<Option<String>> {
    lock(&harness.http.requests)
        .iter()
        .filter_map(|request| {
            let url = url::Url::parse(&request.url).unwrap();
            (url.path() == "/v1/sessions" && !is_pinned_read(&url)).then(|| {
                url.query_pairs()
                    .find(|(key, _)| key == name)
                    .map(|(_, value)| value.into_owned())
            })
        })
        .collect()
}

#[test]
fn the_first_page_reports_more_and_load_more_appends_the_next() {
    let (mut harness, cursor) = connected_with_first_page();
    assert_eq!(paging(&harness.events.take()), vec![(true, false)]);

    let (_, second) = pages(2);
    harness.http.route("/v1/sessions", respond(200, &second));
    harness.core.load_more_sessions();
    harness.pump();
    let events = harness.events.take();
    assert_eq!(paging(&events), vec![(true, true), (false, false)]);
    let upserted = events.iter().find_map(|event| match event {
        CoreEvent::SessionListChanged {
            change: SessionListChange::Upsert { sessions },
        } => Some(sessions.len()),
        _ => None,
    });
    assert_eq!(upserted, Some(1));
    assert_eq!(
        list_queries(&harness, "after").last().cloned().flatten(),
        Some(cursor)
    );

    // Every session is loaded: another Load more reads nothing.
    let requests = list_queries(&harness, "after").len();
    harness.core.load_more_sessions();
    harness.pump();
    assert_eq!(list_queries(&harness, "after").len(), requests);
}

#[test]
fn a_reload_keeps_the_loaded_pages() {
    let (mut harness, _) = connected_with_first_page();
    let (_, second) = pages(2);
    harness.http.route("/v1/sessions", respond(200, &second));
    harness.core.load_more_sessions();
    harness.pump();
    harness.events.take();

    harness.core.refresh_sessions();
    harness.pump();
    // Three rows are loaded; a reload asks for at least the first page's size.
    assert_eq!(
        list_queries(&harness, "limit").last().cloned().flatten(),
        Some("50".to_owned())
    );
    assert_eq!(
        list_queries(&harness, "after").last().cloned().flatten(),
        None
    );
}

#[test]
fn a_reload_drops_a_load_more_in_flight() {
    let (mut harness, _) = connected_with_first_page();
    harness.events.take();
    harness.core.load_more_sessions();
    harness.core.refresh_sessions();
    harness.pump();
    let events = harness.events.take();
    // Both reads answer with the first page; only the reload's lands, as a reset.
    assert!(!events.iter().any(|event| matches!(
        event,
        CoreEvent::SessionListChanged {
            change: SessionListChange::Upsert { .. }
        }
    )));
    assert_eq!(paging(&events).last(), Some(&(true, false)));
}

#[test]
fn a_reload_asks_for_every_loaded_row_within_the_server_limit() {
    use crate::list_driver::ListWindow;
    let window = |rows| ListWindow {
        rows,
        ..ListWindow::default()
    };
    assert_eq!(window(0).reload_limit(), 50);
    assert_eq!(window(150).reload_limit(), 150);
    assert_eq!(window(4_000).reload_limit(), 1_000);
}

/// A page of `selected` rows named `prefix0..`, then `appended` family members after its
/// boundary.
fn family_page(prefix: &str, selected: usize, appended: usize, has_more: bool) -> String {
    let row = |id: String, family: Option<&str>| {
        let mut row = json!({"id": id, "status": "idle", "created_at": 1, "updated_at": 1});
        if let Some(family) = family {
            row["family"] = json!({"id": family, "representative_id": family});
        }
        row
    };
    let mut rows: Vec<Value> = (0..selected)
        .map(|index| row(format!("{prefix}{index}"), None))
        .collect();
    let boundary = format!("{prefix}{}", selected - 1);
    rows.extend((0..appended).map(|index| row(format!("{prefix}m{index}"), Some(&boundary))));
    json!({
        "data": rows,
        "last_id": boundary,
        "has_more": has_more,
        "page_boundary": {"id": boundary, "created_at": 1, "updated_at": 1},
    })
    .to_string()
}

#[test]
fn a_reload_counts_the_rows_pages_selected_not_their_appended_family_members() {
    let mut harness = Harness::new(UrlPolicy::Development);
    harness.local_server();
    harness
        .http
        .route("/v1/sessions", respond(200, &family_page("a", 60, 5, true)));
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.connect("http://127.0.0.1:6767".into(), None).await })
        .unwrap();
    assert_eq!(last_reset_rows(&harness.events.take()), Some(65));
    harness
        .http
        .route("/v1/sessions", respond(200, &family_page("b", 3, 2, false)));
    harness.core.load_more_sessions();
    harness.pump();
    harness.core.refresh_sessions();
    harness.pump();
    assert_eq!(
        list_queries(&harness, "limit").last().cloned().flatten(),
        Some("63".to_owned())
    );
    assert!(
        list_queries(&harness, "expand_families")
            .iter()
            .all(|value| value.as_deref() == Some("true"))
    );
}

/// How many rows the last list reset carried.
fn last_reset_rows(events: &[CoreEvent]) -> Option<usize> {
    events.iter().rev().find_map(|event| match event {
        CoreEvent::SessionListChanged {
            change: SessionListChange::Reset { sessions },
        } => Some(sessions.len()),
        _ => None,
    })
}

#[test]
fn a_session_started_elsewhere_shows_at_the_next_periodic_read() {
    use crate::list_driver::LIST_RECONCILE_INTERVAL_MS;
    let (mut harness, _) = connected_with_first_page();
    harness.events.take();
    let reads = harness.http.list_reads();
    // Another app starts a session: the server's list has a row no socket announced here.
    let (_, rest) = pages(0);
    harness.http.route("/v1/sessions", respond(200, &rest));
    harness.advance(LIST_RECONCILE_INTERVAL_MS - 1);
    assert_eq!(harness.http.list_reads(), reads, "not before");
    harness.advance(1);
    harness.pump();
    assert_eq!(harness.http.list_reads(), reads + 1);
    let all = serde_json::from_str::<Value>(&rest).unwrap()["data"]
        .as_array()
        .unwrap()
        .len();
    assert!(
        all > 2,
        "the recorded list has more rows than the first page"
    );
    assert_eq!(last_reset_rows(&harness.events.take()), Some(all));

    // Each answer arms the next read.
    harness.advance(LIST_RECONCILE_INTERVAL_MS);
    harness.pump();
    assert_eq!(harness.http.list_reads(), reads + 2);
}

#[test]
fn the_periodic_read_stops_with_the_connection() {
    use crate::list_driver::LIST_RECONCILE_INTERVAL_MS;
    let (mut harness, _) = connected_with_first_page();
    harness.core.disconnect();
    harness.pump();
    let reads = harness.http.list_reads();
    harness.advance(2 * LIST_RECONCILE_INTERVAL_MS);
    harness.pump();
    assert_eq!(harness.http.list_reads(), reads);
}

#[test]
fn a_new_connection_cancels_a_pending_reload() {
    let harness = Harness::new(UrlPolicy::Development);
    let (mut engine, _queue) = harness.idle_engine();
    let (timer, _registration) = futures::future::AbortHandle::new_pair();
    let (periodic, _registration) = futures::future::AbortHandle::new_pair();
    engine.list.refresh = Some(timer.clone());
    engine.list.reconcile = Some(periodic.clone());
    engine.reset_list_window();
    assert!(timer.is_aborted());
    assert!(periodic.is_aborted());
    assert!(engine.list.refresh.is_none());
    assert!(engine.list.reconcile.is_none());
}

#[test]
fn arming_the_periodic_read_drops_one_still_armed() {
    let harness = Harness::new(UrlPolicy::Development);
    let (mut engine, _queue) = harness.idle_engine();
    let (periodic, _registration) = futures::future::AbortHandle::new_pair();
    engine.list.reconcile = Some(periodic.clone());
    engine.schedule_list_reconcile();
    assert!(periodic.is_aborted());
    assert!(
        engine
            .list
            .reconcile
            .as_ref()
            .is_some_and(|timer| !timer.is_aborted())
    );
}

#[test]
fn nothing_is_read_once_disconnected() {
    let (mut harness, _) = connected_with_first_page();
    harness.core.disconnect();
    harness.pump();
    let before = harness.http.list_reads();
    harness.core.post(Msg::List(ListMsg::Refresh));
    harness.core.load_more_sessions();
    harness.pump();
    assert_eq!(harness.http.list_reads(), before);
}

#[test]
fn a_second_load_more_while_one_is_reading_adds_nothing() {
    let (mut harness, _) = connected_with_first_page();
    let gate = harness.http.hold("/v1/sessions");
    let before = harness.http.list_reads();
    harness.core.load_more_sessions();
    harness.pump();
    harness.core.load_more_sessions();
    harness.pump();
    assert_eq!(harness.http.list_reads(), before + 1);
    gate.send(()).unwrap();
    harness.pump();
}

#[test]
fn a_failed_load_more_reports_it_and_can_be_asked_for_again() {
    let (mut harness, _) = connected_with_first_page();
    harness
        .http
        .route("/v1/sessions", respond(500, r#"{"detail":"boom"}"#));
    harness.events.take();
    harness.core.load_more_sessions();
    harness.pump();
    let events = harness.events.take();
    assert_eq!(paging(&events), [(true, true), (true, false)]);
    assert!(
        events.iter().any(|event| matches!(
            event,
            CoreEvent::Error {
                scope: ErrorScope::SessionList,
                ..
            }
        )),
        "{events:#?}"
    );
    let (_, rest) = pages(2);
    harness.http.route("/v1/sessions", respond(200, &rest));
    harness.core.load_more_sessions();
    harness.pump();
    assert_eq!(
        paging(&harness.events.take()),
        [(true, true), (false, false)]
    );
}

#[test]
fn a_rejected_token_on_a_reload_asks_to_sign_in() {
    let (mut harness, _) = connected_with_first_page();
    harness
        .http
        .route("/v1/sessions", respond(401, r#"{"detail":"expired"}"#));
    harness.events.take();
    harness.core.post(Msg::List(ListMsg::Refresh));
    harness.pump();
    let phases = crate::test_support::phases(&harness.events.take());
    assert_eq!(phases.len(), 1, "{phases:?}");
    assert!(
        matches!(phases[0], ConnectionPhase::SignInRequired { .. }),
        "{phases:?}"
    );
}

#[test]
fn a_rejected_token_on_load_more_asks_to_sign_in() {
    let (mut harness, _) = connected_with_first_page();
    harness
        .http
        .route("/v1/sessions", respond(401, r#"{"detail":"expired"}"#));
    harness.events.take();
    harness.core.load_more_sessions();
    harness.pump();
    let phases = crate::test_support::phases(&harness.events.take());
    assert!(
        matches!(phases.last(), Some(ConnectionPhase::SignInRequired { .. })),
        "{phases:?}"
    );
}

#[test]
fn a_rejected_token_a_list_read_alone_noticed_still_asks_to_sign_in() {
    let (harness, _) = connected_with_first_page();
    let phase = crate::test_support::phases(&harness.events.all())
        .pop()
        .unwrap();
    let (mut engine, _queue) = harness.idle_engine();
    engine.phase = phase;
    engine.sign_in = Some(crate::engine::SignInContext {
        base_url: "http://127.0.0.1:6767".into(),
        server_name: None,
        mode: crate::events::AuthenticationMode::Accounts,
        methods: Vec::new(),
    });
    harness.events.take();
    engine.list_failed(omnigent_core::SessionError::Unauthorized { reason: None });
    let phases = crate::test_support::phases(&harness.events.take());
    assert!(
        matches!(phases.as_slice(), [ConnectionPhase::SignInRequired { .. }]),
        "{phases:?}"
    );
}

#[test]
fn the_pages_hold_archived_sessions_only_while_the_sidebar_shows_them() {
    let (mut harness, cursor) = connected_with_first_page();
    let last =
        |harness: &Harness, name: &str| list_queries(harness, name).last().cloned().flatten();
    // The web's sidebar query: archived sessions are not read to be hidden.
    assert_eq!(last(&harness, "include_archived"), None);
    assert_eq!(last(&harness, "visibility").as_deref(), Some("all"));

    harness.core.set_sidebar_shows_archived(true);
    harness.pump();
    assert_eq!(last(&harness, "include_archived").as_deref(), Some("true"));
    assert_eq!(last(&harness, "after"), None, "the first page again");
    harness.core.load_more_sessions();
    harness.pump();
    assert_eq!(last(&harness, "include_archived").as_deref(), Some("true"));
    assert_eq!(last(&harness, "after"), Some(cursor));

    let reads = harness.http.list_reads();
    harness.core.set_sidebar_shows_archived(true);
    harness.pump();
    assert_eq!(harness.http.list_reads(), reads, "no change, no read");
    harness.core.set_sidebar_shows_archived(false);
    harness.pump();
    assert_eq!(last(&harness, "include_archived"), None);
    assert_eq!(
        last(&harness, "limit").as_deref(),
        Some("50"),
        "from the first page"
    );
}

/// A list row; a pinned one carries the pin label.
fn row(id: &str, pinned: bool) -> Value {
    let mut row = json!({"id": id, "status": "idle", "created_at": 1, "updated_at": 1});
    if pinned {
        row["labels"] = json!({"omnigent.pinned": "1700000000000"});
    }
    row
}

fn list_of(rows: &[Value], has_more: bool) -> String {
    json!({
        "data": rows,
        "last_id": rows.last().map(|row| row["id"].clone()),
        "has_more": has_more,
    })
    .to_string()
}

/// Each list change as `reset a b` or `upsert c`.
fn list_changes(events: &[CoreEvent]) -> Vec<String> {
    let line = |kind: &str, sessions: &[crate::sessions::SessionSummary]| {
        let ids: Vec<&str> = sessions.iter().map(|row| row.id.as_str()).collect();
        format!("{kind} {}", ids.join(" "))
    };
    events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::SessionListChanged { change } => Some(match change {
                SessionListChange::Reset { sessions } => line("reset", sessions),
                SessionListChange::Upsert { sessions } => line("upsert", sessions),
                SessionListChange::Remove { ids } => format!("remove {}", ids.join(" ")),
            }),
            _ => None,
        })
        .collect()
}

/// A local server whose first page is `a`, `b` (pinned) with more after it, and whose pinned
/// read answers `pins`.
fn server_with_pins(pins: &[Value]) -> Harness {
    let harness = Harness::new(UrlPolicy::Development);
    harness.local_server();
    harness.http.route(
        "/v1/sessions",
        respond(200, &list_of(&[row("a", false), row("b", true)], true)),
    );
    harness.http.route_query(
        "/v1/sessions",
        "pinned",
        "true",
        respond(200, &list_of(pins, false)),
    );
    harness
}

fn connect_local(harness: &mut Harness) {
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.connect("http://127.0.0.1:6767".into(), None).await })
        .unwrap();
}

#[test]
fn the_pins_are_read_beside_the_first_page_and_show_with_it() {
    let mut harness = server_with_pins(&[row("b", true), row("old", true)]);
    // The first read out is the page; the pinned read does not wait for it.
    let page = harness.http.hold("/v1/sessions");
    connect_local(&mut harness);
    harness.pump();
    let pinned: Vec<url::Url> = lock(&harness.http.requests)
        .iter()
        .map(|request| url::Url::parse(&request.url).unwrap())
        .filter(|url| url.path() == "/v1/sessions" && is_pinned_read(url))
        .collect();
    assert_eq!(
        (harness.http.list_reads(), pinned.len()),
        (1, 1),
        "both at once"
    );
    // With the pinned families, as the web's Pinned query.
    assert!(
        pinned[0]
            .query_pairs()
            .any(|(name, value)| name == "expand_families" && value == "true")
    );
    assert_eq!(list_changes(&harness.events.take()), Vec::<String>::new());
    page.send(()).unwrap();
    harness.pump();
    // A pin past the first page shows with it.
    assert_eq!(list_changes(&harness.events.take()), ["reset a b old"]);
}

#[test]
fn pins_after_the_page_join_it_and_a_reload_keeps_them_until_its_own_land() {
    let mut harness = server_with_pins(&[row("b", true), row("old", true)]);
    let page = harness.http.hold("/v1/sessions");
    let pins = harness.http.hold("/v1/sessions");
    connect_local(&mut harness);
    page.send(()).unwrap();
    harness.pump();
    assert_eq!(list_changes(&harness.events.take()), ["reset a b"]);
    pins.send(()).unwrap();
    harness.pump();
    assert_eq!(list_changes(&harness.events.take()), ["upsert b old"]);

    // `old` is unpinned elsewhere: the reload's page keeps it until its pins say so.
    harness.http.route_query(
        "/v1/sessions",
        "pinned",
        "true",
        respond(200, &list_of(&[row("b", true)], false)),
    );
    let page = harness.http.hold("/v1/sessions");
    let pins = harness.http.hold("/v1/sessions");
    harness.core.refresh_sessions();
    harness.pump();
    page.send(()).unwrap();
    harness.pump();
    assert_eq!(list_changes(&harness.events.take()), ["reset a b old"]);
    pins.send(()).unwrap();
    harness.pump();
    assert_eq!(list_changes(&harness.events.take()), ["upsert b"]);
    harness.core.refresh_sessions();
    harness.pump();
    assert_eq!(
        list_changes(&harness.events.take()),
        ["reset a b", "upsert b"]
    );
}

#[test]
fn a_server_that_ignores_the_pinned_filter_adds_nothing() {
    // An older server answers the pinned read with its plain list.
    let mut harness = Harness::new(UrlPolicy::Development);
    harness.local_server();
    harness.http.route(
        "/v1/sessions",
        respond(200, &list_of(&[row("a", false), row("b", true)], true)),
    );
    connect_local(&mut harness);
    harness.pump();
    assert_eq!(list_changes(&harness.events.take()), ["reset a b"]);
}

#[test]
fn a_failed_pinned_read_keeps_the_page_and_is_reported() {
    let mut harness = server_with_pins(&[]);
    harness.http.route_query(
        "/v1/sessions",
        "pinned",
        "true",
        respond(500, r#"{"detail":"boom"}"#),
    );
    connect_local(&mut harness);
    harness.pump();
    let events = harness.events.take();
    assert_eq!(list_changes(&events), ["reset a b"]);
    assert!(
        events.iter().any(|event| matches!(
            event,
            CoreEvent::Error {
                scope: ErrorScope::SessionList,
                ..
            }
        )),
        "{events:?}"
    );
}

#[test]
fn a_refused_watch_list_is_reported_on_the_session_list() {
    let harness = Harness::new(UrlPolicy::Development);
    let (mut engine, _queue) = harness.idle_engine();
    engine.apply_watch(Err(omnigent_core::realtime::WatchError::InvalidSessionId {
        id: "../x".to_owned(),
    }));
    let events = harness.events.take();
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
