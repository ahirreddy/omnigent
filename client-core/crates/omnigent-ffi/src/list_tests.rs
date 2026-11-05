//! Session list paging: "Load more" and reloads that keep the loaded pages.

use std::sync::Arc;

use serde_json::{Value, json};

use crate::connection::UrlPolicy;
use crate::engine::lock;
use crate::events::{ConnectionPhase, CoreEvent};
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

/// The `name` query value of every `GET /v1/sessions` request.
fn list_queries(harness: &Harness, name: &str) -> Vec<Option<String>> {
    lock(&harness.http.requests)
        .iter()
        .filter_map(|request| {
            let url = url::Url::parse(&request.url).unwrap();
            (url.path() == "/v1/sessions").then(|| {
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
