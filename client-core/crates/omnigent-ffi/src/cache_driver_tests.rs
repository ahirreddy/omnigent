//! The saved copy in the engine: written through as the server answers, shown when a session
//! opens, shown offline when the server cannot be reached, replaced by the server's state on
//! reconnect, and deleted on sign-out and server removal.

use std::sync::atomic::Ordering;

use omnigent_core::message_cache::{self as cache, CacheScope, SavedConversation};

use crate::errors::CoreError;
use crate::events::{ConnectionPhase, CoreEvent, ErrorScope};
use crate::host::ConnectionFailure;
use crate::http::HttpHeader;
use crate::sessions::SessionListChange;
use crate::test_support::{Harness, TempFolder, envelope_response, json};
use crate::transcript::{Row, apply_row_ops};

const SERVER: &str = "http://127.0.0.1:6767";
const SESSION: &str = "facbcc05b00f4321b98b1929d217abc5";
const HEARTBEAT: &[u8] = b"event: session.heartbeat\ndata: {\"type\":\"session.heartbeat\"}\n\n";

fn scope() -> CacheScope {
    CacheScope::new(SERVER, "local").unwrap()
}

fn items_path() -> String {
    format!("/v1/sessions/{SESSION}/items")
}

/// An `/items` page, newest first: `(id, role, text)`, then the cursor above it.
fn page(items: &[(&str, &str, &str)], older: Option<&str>) -> String {
    let data: Vec<serde_json::Value> = items
        .iter()
        .map(|(id, role, text)| {
            serde_json::json!({"id": id, "type": "message", "role": role, "content": text})
        })
        .collect();
    serde_json::json!({"object": "list", "data": data, "has_more": older.is_some(), "last_id": older})
        .to_string()
}

/// The newest page every first launch reads: a question and its answer, with more above.
fn first_page() -> String {
    page(
        &[
            ("msg_4", "assistant", "Answer"),
            ("msg_3", "user", "Question"),
        ],
        Some("msg_3"),
    )
}

fn route_session(harness: &Harness, items: &str) {
    harness.http.route(
        &format!("/v1/sessions/{SESSION}"),
        json(
            200,
            &envelope_response("sessions/recorded-session-get-no-items.json"),
        ),
    );
    harness.http.route(&items_path(), json(200, items));
    harness.http.route(
        &format!("/v1/sessions/{SESSION}/resources/environments/default/changes"),
        json(200, r#"{"entries":[]}"#),
    );
}

/// A launch that reaches the local server.
fn launch(folder: &TempFolder) -> Harness {
    let mut harness = Harness::with_cache(&folder.0);
    harness.local_server();
    let phase = harness
        .call(|core| async move { core.connect(SERVER.into(), None).await })
        .unwrap();
    assert!(
        matches!(phase, ConnectionPhase::Connected { .. }),
        "{phase:?}"
    );
    harness
}

/// A launch with the network down.
fn launch_offline(folder: &TempFolder) -> Harness {
    let mut harness = Harness::with_cache(&folder.0);
    harness.http.offline.store(true, Ordering::SeqCst);
    let result = harness.call(|core| async move { core.connect(SERVER.into(), None).await });
    assert!(result.is_err(), "{result:?}");
    harness
}

/// Lets the newest stream attempt go live, which starts the hydration.
fn go_live(harness: &mut Harness) {
    let (sink, _, _) = harness.streams.last();
    sink.response(
        200,
        vec![HttpHeader {
            name: "Content-Type".into(),
            value: "text/event-stream".into(),
        }],
    );
    sink.chunk(HEARTBEAT.to_vec());
    harness.pump();
}

/// A first launch that read the session's newest page and the page above it, then quit.
fn saved_on_first_launch(folder: &TempFolder) {
    let mut first = launch(folder);
    route_session(&first, &first_page());
    first.core.open_session(SESSION.into());
    first.pump();
    go_live(&mut first);
    first.http.route(
        &items_path(),
        json(
            200,
            &page(
                &[
                    ("msg_2", "assistant", "Earlier"),
                    ("msg_1", "user", "First"),
                ],
                Some("msg_1"),
            ),
        ),
    );
    first.core.load_older_history(SESSION.into());
    first.pump();
    first.core.flush_message_cache();
    let reported = errors(&first.events.all());
    assert!(reported.is_empty(), "{reported:#?}");
}

fn saved_conversation(folder: &TempFolder) -> Option<SavedConversation> {
    let path = folder.0.join(scope().conversation_path(SESSION));
    let bytes = std::fs::read(path).ok()?;
    Some(cache::decode_conversation(&bytes, SESSION).unwrap())
}

fn rows_from(events: &[CoreEvent]) -> Vec<Row> {
    let mut rows = Vec::new();
    for event in events {
        match event {
            CoreEvent::TranscriptReset {
                session_id,
                rows: reset,
                ..
            } if session_id == SESSION => rows.clone_from(reset),
            CoreEvent::TranscriptChanged {
                session_id, change, ..
            } if session_id == SESSION => {
                rows = apply_row_ops(rows, change.rows.clone()).unwrap();
            }
            _ => {}
        }
    }
    rows
}

fn texts(rows: &[Row]) -> Vec<String> {
    rows.iter().map(|row| row.text.clone()).collect()
}

fn offline_changes(events: &[CoreEvent]) -> Vec<Option<String>> {
    events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::OfflineChanged { server_url } => Some(server_url.clone()),
            _ => None,
        })
        .collect()
}

fn session_offline(events: &[CoreEvent]) -> Vec<bool> {
    events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::SessionOfflineChanged {
                session_id,
                offline,
            } if session_id == SESSION => Some(*offline),
            _ => None,
        })
        .collect()
}

fn errors(events: &[CoreEvent]) -> Vec<(ErrorScope, CoreError)> {
    events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::Error { scope, error } => Some((scope.clone(), error.clone())),
            _ => None,
        })
        .collect()
}

fn list_reset(events: &[CoreEvent]) -> Option<Vec<String>> {
    events.iter().rev().find_map(|event| match event {
        CoreEvent::SessionListChanged {
            change: SessionListChange::Reset { sessions },
        } => Some(sessions.iter().map(|session| session.id.clone()).collect()),
        _ => None,
    })
}

#[test]
fn what_the_server_returns_is_written_through() {
    let folder = TempFolder::new("write-through");
    saved_on_first_launch(&folder);
    let saved = saved_conversation(&folder).expect("the session was saved");
    assert_eq!(saved.session.id, SESSION);
    let ids: Vec<&str> = saved.items().map(|item| item.id.as_str()).collect();
    assert_eq!(ids, ["msg_1", "msg_2", "msg_3", "msg_4"]);
    assert_eq!(saved.older_cursor.as_deref(), Some("msg_1"));
    let list = std::fs::read(folder.0.join(scope().list_path())).unwrap();
    assert_eq!(cache::decode_list(&list).unwrap().rows.len(), 3);
    let account = std::fs::read(
        folder
            .0
            .join(cache::last_account_path(scope().server_key())),
    );
    assert_eq!(
        cache::decode_last_account(&account.unwrap()).unwrap(),
        scope().account_key()
    );
}

#[test]
fn a_relaunch_shows_the_saved_rows_before_the_server_answers() {
    let folder = TempFolder::new("open-from-cache");
    saved_on_first_launch(&folder);
    let mut second = launch(&folder);
    route_session(
        &second,
        &page(
            &[
                ("msg_5", "assistant", "New"),
                ("msg_4", "assistant", "Edited"),
            ],
            Some("msg_4"),
        ),
    );
    second.events.take();
    second.core.open_session(SESSION.into());
    second.pump();
    let opened = second.events.take();
    let reset = opened.iter().find_map(|event| match event {
        CoreEvent::TranscriptReset { rows, .. } => Some(texts(rows)),
        _ => None,
    });
    assert_eq!(reset.unwrap(), ["First", "Earlier", "Question", "Answer"]);
    assert!(session_offline(&opened).is_empty(), "online: {opened:#?}");
    go_live(&mut second);
    let mut events = opened;
    events.extend(second.events.take());
    // The server's newest page wins where it overlaps; the saved pages above it stay.
    assert_eq!(
        texts(&rows_from(&events)),
        ["First", "Earlier", "Question", "Edited", "New"]
    );
    assert!(errors(&events).is_empty(), "{:#?}", errors(&events));
}

#[test]
fn an_offline_launch_shows_the_saved_list_and_session_and_says_so() {
    let folder = TempFolder::new("offline-open");
    saved_on_first_launch(&folder);
    let mut offline = launch_offline(&folder);
    let launched = offline.events.take();
    assert_eq!(offline_changes(&launched), [Some(SERVER.to_owned())]);
    let shown = launched
        .iter()
        .position(|event| matches!(event, CoreEvent::OfflineChanged { .. }))
        .unwrap();
    let failed = launched
        .iter()
        .position(|event| {
            matches!(
                event,
                CoreEvent::ConnectionChanged {
                    phase: ConnectionPhase::Failed { .. }
                }
            )
        })
        .unwrap();
    assert!(shown < failed, "the saved copy shows before the failure");
    assert_eq!(list_reset(&launched).map(|ids| ids.len()), Some(3));
    assert!(launched.contains(&CoreEvent::SessionListLoaded));
    assert!(launched.contains(&CoreEvent::SessionListPagingChanged {
        has_more: false,
        is_loading: false
    }));

    offline.core.open_session(SESSION.into());
    offline.pump();
    let opened = offline.events.take();
    assert_eq!(
        texts(&rows_from(&opened)),
        ["First", "Earlier", "Question", "Answer"]
    );
    assert_eq!(session_offline(&opened), [true]);
    assert!(opened.contains(&CoreEvent::HistoryPagingChanged {
        session_id: SESSION.into(),
        has_older: true,
        is_loading: false
    }));
    // Every saved page is shown; nothing more is read while offline.
    let reads = offline.http.count(&items_path());
    offline.core.load_older_history(SESSION.into());
    offline.pump();
    assert_eq!(offline.http.count(&items_path()), reads);
    let events = offline.events.take();
    assert!(errors(&events).is_empty(), "{:#?}", errors(&events));
}

#[test]
fn reconnecting_after_offline_lets_the_server_state_win() {
    let folder = TempFolder::new("reconnect");
    saved_on_first_launch(&folder);
    let mut harness = launch_offline(&folder);
    harness.core.open_session(SESSION.into());
    harness.pump();
    let mut events = harness.events.take();

    harness.http.offline.store(false, Ordering::SeqCst);
    harness.local_server();
    route_session(
        &harness,
        &page(
            &[
                ("msg_5", "assistant", "New"),
                ("msg_4", "assistant", "Edited"),
            ],
            Some("msg_4"),
        ),
    );
    let phase = harness
        .call(|core| async move { core.connect(SERVER.into(), None).await })
        .unwrap();
    assert!(matches!(phase, ConnectionPhase::Connected { .. }));
    go_live(&mut harness);
    let reconnected = harness.events.take();
    assert_eq!(offline_changes(&reconnected), [None]);
    assert_eq!(session_offline(&reconnected), [false]);
    // The phase comes first, so the app keeps the saved list until the server's replaces it.
    let connected = reconnected
        .iter()
        .position(|event| {
            matches!(
                event,
                CoreEvent::ConnectionChanged {
                    phase: ConnectionPhase::Connected { .. }
                }
            )
        })
        .unwrap();
    let online = reconnected
        .iter()
        .position(|event| *event == CoreEvent::OfflineChanged { server_url: None })
        .unwrap();
    assert!(connected < online);
    assert_eq!(list_reset(&reconnected).map(|ids| ids.len()), Some(3));
    events.extend(reconnected);
    assert_eq!(
        texts(&rows_from(&events)),
        ["First", "Earlier", "Question", "Edited", "New"]
    );
    harness.core.flush_message_cache();
    let saved = saved_conversation(&folder).unwrap();
    let ids: Vec<&str> = saved.newest.iter().map(|item| item.id.as_str()).collect();
    assert_eq!(ids, ["msg_4", "msg_5"]);
}

#[test]
fn a_damaged_saved_session_is_reported_and_loads_from_the_server() {
    let folder = TempFolder::new("damaged");
    saved_on_first_launch(&folder);
    let path = folder.0.join(scope().conversation_path(SESSION));
    std::fs::write(&path, b"{\"version\":1,\"saved_at_ms\":").unwrap();
    let mut second = launch(&folder);
    route_session(&second, &first_page());
    second.core.open_session(SESSION.into());
    second.pump();
    go_live(&mut second);
    let events = second.events.all();
    let reported = errors(&events);
    assert!(
        reported.iter().any(|(scope, error)| {
            *scope
                == ErrorScope::Session {
                    session_id: SESSION.into(),
                }
                && matches!(error, CoreError::MessageCache { message } if message.contains("damaged"))
        }),
        "{reported:#?}"
    );
    assert_eq!(texts(&rows_from(&events)), ["Question", "Answer"]);
    // The server's answer replaced the damaged file.
    second.core.flush_message_cache();
    assert_eq!(saved_conversation(&folder).unwrap().newest.len(), 2);
}

#[test]
fn signing_out_deletes_the_accounts_saved_copy() {
    let folder = TempFolder::new("sign-out");
    saved_on_first_launch(&folder);
    let mut harness = launch(&folder);
    harness
        .call(|core| async move { core.sign_out().await })
        .unwrap();
    harness.core.flush_message_cache();
    assert!(!folder.0.join(scope().account_dir()).exists());
    assert!(
        !folder
            .0
            .join(cache::last_account_path(scope().server_key()))
            .exists()
    );
    // Nothing is left to show offline: the failure shows as before.
    let offline = launch_offline(&folder);
    let changes = offline_changes(&offline.events.all());
    assert!(changes.is_empty(), "{changes:?}");
}

#[test]
fn removing_a_server_deletes_its_saved_copy() {
    let folder = TempFolder::new("forget-server");
    saved_on_first_launch(&folder);
    let mut harness = Harness::with_cache(&folder.0);
    harness.core.forget_saved_server("127.0.0.1:6767/".into());
    harness.pump();
    harness.core.flush_message_cache();
    assert!(!folder.0.join(scope().server_key()).exists());
    let reported = errors(&harness.events.all());
    assert!(reported.is_empty(), "{reported:#?}");
}

#[test]
fn items_the_stream_commits_are_saved_after_a_moment_and_on_close() {
    let folder = TempFolder::new("streamed");
    let mut harness = launch(&folder);
    route_session(&harness, &first_page());
    harness.core.open_session(SESSION.into());
    harness.pump();
    go_live(&mut harness);
    let (sink, _, _) = harness.streams.last();
    let done = |id: &str, text: &str| {
        format!(
            "event: response.output_item.done\ndata: {}\n\n",
            serde_json::json!({
                "type": "response.output_item.done",
                "item": {"id": id, "type": "message", "role": "assistant", "content": text},
            })
        )
        .into_bytes()
    };
    sink.chunk(done("msg_5", "Streamed"));
    harness.pump();
    harness.core.flush_message_cache();
    let newest = |folder: &TempFolder| -> Vec<String> {
        saved_conversation(folder)
            .unwrap()
            .newest
            .iter()
            .map(|item| item.id.clone())
            .collect()
    };
    assert_eq!(newest(&folder), ["msg_3", "msg_4"], "not saved at once");
    harness.advance(crate::cache_driver::STREAM_SAVE_DELAY_MS);
    harness.core.flush_message_cache();
    assert_eq!(newest(&folder), ["msg_3", "msg_4", "msg_5"]);
    sink.chunk(done("msg_6", "Before closing"));
    harness.pump();
    harness.core.close_session(SESSION.into());
    harness.pump();
    harness.core.flush_message_cache();
    assert_eq!(newest(&folder), ["msg_3", "msg_4", "msg_5", "msg_6"]);
}

#[test]
fn a_saved_session_is_offline_while_its_stream_is_down() {
    let folder = TempFolder::new("stream-down");
    saved_on_first_launch(&folder);
    let mut harness = launch(&folder);
    route_session(&harness, &first_page());
    harness.core.open_session(SESSION.into());
    harness.pump();
    let (sink, _, _) = harness.streams.last();
    sink.finish(Some(ConnectionFailure::Offline {
        message: "no route".into(),
    }));
    harness.pump();
    assert_eq!(session_offline(&harness.events.all()), [true]);
    harness.advance(5_000);
    go_live(&mut harness);
    assert_eq!(session_offline(&harness.events.all()), [true, false]);
}
