//! Driver tests: the real core over fake host traits, with manual time.

use std::sync::Arc;
use std::sync::atomic::Ordering;

use crate::connection::UrlPolicy;
use crate::decisions::DecisionResponse;
use crate::engine::lock;
use crate::errors::CoreError;
use crate::events::{ConnectionPhase, CoreEvent, ErrorScope, LinkState};
use crate::host::{ConnectionFailure, SocketMessage};
use crate::http::HttpHeader;
use crate::sessions::SessionListChange;
use crate::test_support::{Harness, connected, envelope_response, fixture, json};
use crate::transcript::{Row, RowRole, apply_row_ops};

const SESSION: &str = "facbcc05b00f4321b98b1929d217abc5";

/// The rows a store holds after applying every transcript event in order.
fn rows_from(events: &[CoreEvent], session_id: &str) -> Vec<Row> {
    let mut rows = Vec::new();
    for event in events {
        match event {
            CoreEvent::TranscriptReset {
                session_id: id,
                rows: reset,
                ..
            } if id == session_id => rows.clone_from(reset),
            CoreEvent::TranscriptChanged {
                session_id: id,
                change,
                ..
            } if id == session_id => {
                rows = apply_row_ops(rows, change.rows.clone()).unwrap();
            }
            _ => {}
        }
    }
    rows
}

/// The recorded frames, each with its SSE text.
fn recorded_frames(path: &str) -> Vec<(serde_json::Value, String)> {
    fixture(path)
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let frame: serde_json::Value = serde_json::from_str(line).unwrap();
            let raw = format!("{}\n\n", frame["raw"].as_str().unwrap());
            (frame["data"].clone(), raw)
        })
        .collect()
}

/// `/items` (newest first) after `frames` were committed: the consumed input and each item's
/// last version (a function call's id changes when it completes, so calls key by `call_id`).
fn items_page(frames: &[serde_json::Value]) -> String {
    let mut items: Vec<serde_json::Value> = Vec::new();
    for data in frames {
        let item = match data["type"].as_str() {
            Some("response.output_item.done") => data["item"].clone(),
            Some("session.input.consumed") => {
                let consumed = &data["data"];
                let mut item = consumed["data"].clone();
                item["id"] = consumed["item_id"].clone();
                item["type"] = consumed["type"].clone();
                item
            }
            _ => continue,
        };
        let key = |value: &serde_json::Value| {
            value
                .get("call_id")
                .filter(|_| value["type"] == "function_call")
                .cloned()
                .unwrap_or_else(|| value["id"].clone())
        };
        items.retain(|existing| key(existing) != key(&item));
        items.push(item);
    }
    items.reverse();
    serde_json::json!({"object": "list", "data": items, "has_more": false}).to_string()
}

fn route_session(harness: &Harness) {
    harness.http.route(
        &format!("/v1/sessions/{SESSION}"),
        json(
            200,
            &envelope_response("sessions/recorded-session-get-no-items.json"),
        ),
    );
    harness.http.route(
        &format!("/v1/sessions/{SESSION}/items"),
        json(200, &items_page(&[])),
    );
    harness.http.route(
        &format!("/v1/sessions/{SESSION}/resources/environments/default/changes"),
        json(200, r#"{"entries":[]}"#),
    );
}

fn event_stream_head() -> Vec<HttpHeader> {
    vec![HttpHeader {
        name: "Content-Type".into(),
        value: "text/event-stream".into(),
    }]
}

#[test]
fn connect_reports_phases_and_loads_the_list() {
    let harness = connected();
    let events = harness.events.all();
    let phases: Vec<&ConnectionPhase> = events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::ConnectionChanged { phase } => Some(phase),
            _ => None,
        })
        .collect();
    assert!(matches!(phases[0], ConnectionPhase::Discovering { .. }));
    assert!(matches!(phases[1], ConnectionPhase::Connecting { .. }));
    let ConnectionPhase::Connected { server } = phases[2] else {
        panic!("{phases:?}");
    };
    assert_eq!(server.user_id, "local");
    let reset = events.iter().find_map(|event| match event {
        CoreEvent::SessionListChanged {
            change: SessionListChange::Reset { sessions },
        } => Some(sessions),
        _ => None,
    });
    assert_eq!(reset.map(Vec::len), Some(3));
    assert!(events.contains(&CoreEvent::SessionListLoaded));
}

#[test]
fn a_recorded_turn_streams_into_rows() {
    let mut harness = connected();
    route_session(&harness);
    harness.core.open_session(SESSION.into());
    harness.pump();
    let (sink, _, request) = harness.streams.last();
    assert!(
        request
            .url
            .ends_with(&format!("/v1/sessions/{SESSION}/stream"))
    );
    assert!(
        request
            .headers
            .iter()
            .any(|header| header.name == "Accept" && header.value == "text/event-stream")
    );
    sink.response(200, event_stream_head());
    let frames = recorded_frames("sse/recorded-turn-text-tool-completion.jsonl");
    for (index, (_, raw)) in frames.iter().enumerate() {
        let committed: Vec<serde_json::Value> = frames[..=index]
            .iter()
            .map(|(data, _)| data.clone())
            .collect();
        harness.http.route(
            &format!("/v1/sessions/{SESSION}/items"),
            json(200, &items_page(&committed)),
        );
        let bytes = raw.as_bytes();
        let middle = bytes.len() / 2;
        sink.chunk(bytes[..middle].to_vec());
        sink.chunk(bytes[middle..].to_vec());
        harness.pump();
    }
    let events = harness.events.all();
    let hydrated = events
        .iter()
        .position(|event| {
            *event
                == CoreEvent::SessionHydrated {
                    session_id: SESSION.into(),
                }
        })
        .expect("the session hydrated");
    // The history lands before "hydrated", so an app never shows the session empty in between.
    let before = events[..hydrated]
        .iter()
        .rev()
        .find(|event| !matches!(event, CoreEvent::DecisionsChanged { .. }));
    assert!(
        matches!(before, Some(CoreEvent::TranscriptChanged { .. })),
        "{:#?}",
        &events[hydrated.saturating_sub(3)..=hydrated]
    );
    let rows = rows_from(&events, SESSION);
    assert!(rows.iter().all(|row| !row.is_ephemeral), "{rows:#?}");
    let summary: Vec<(RowRole, &str)> = rows
        .iter()
        .filter(|row| !row.is_activity_only)
        .map(|row| (row.role, row.text.as_str()))
        .collect();
    assert_eq!(summary.len(), 4, "{summary:#?}");
    assert_eq!(summary[0].0, RowRole::User);
    assert!(summary[0].1.contains("echo fixture-hello"));
    assert!(summary[1].1.starts_with("Tool call: sys_os_shell"));
    assert!(summary[2].1.contains("stdout: fixture-hello"));
    assert_eq!(
        summary[3],
        (RowRole::Assistant, "The command printed fixture-hello.")
    );
    let errors: Vec<&CoreEvent> = events
        .iter()
        .filter(|event| matches!(event, CoreEvent::Error { .. }))
        .collect();
    assert!(errors.is_empty(), "{errors:#?}");
    let paths = harness.http.paths();
    assert!(paths.contains(&format!("/v1/sessions/{SESSION}/items")));
}

#[test]
fn a_stalled_stream_is_cancelled_and_reopened() {
    let mut harness = connected();
    route_session(&harness);
    harness.core.open_session(SESSION.into());
    harness.pump();
    let (sink, handle, _) = harness.streams.last();
    sink.response(200, event_stream_head());
    sink.chunk(b"event: session.heartbeat\ndata: {\"type\":\"session.heartbeat\"}\n\n".to_vec());
    harness.pump();
    assert_eq!(harness.streams.count(), 1);
    harness.advance(45_000);
    assert_eq!(handle.cancels.load(Ordering::SeqCst), 1);
    harness.advance(6_000);
    assert_eq!(harness.streams.count(), 2, "the stream reconnects");
    let states: Vec<LinkState> = harness
        .events
        .all()
        .into_iter()
        .filter_map(|event| match event {
            CoreEvent::SessionLinkChanged { state, .. } => Some(state),
            _ => None,
        })
        .collect();
    assert!(states.iter().any(|state| matches!(
        state,
        LinkState::Reconnecting {
            reason: CoreError::Link { .. },
            ..
        }
    )));
}

#[test]
fn an_unauthorized_stream_asks_for_sign_in() {
    let mut harness = connected();
    route_session(&harness);
    harness.core.open_session(SESSION.into());
    harness.pump();
    let (sink, _, _) = harness.streams.last();
    sink.response(401, Vec::new());
    sink.finish(None);
    harness.pump();
    let events = harness.events.all();
    assert!(events.iter().any(|event| matches!(
        event,
        CoreEvent::SessionLinkChanged {
            state: LinkState::Failed { .. },
            ..
        }
    )));
    assert!(events.iter().any(|event| matches!(
        event,
        CoreEvent::ConnectionChanged {
            phase: ConnectionPhase::SignInRequired {
                reason: Some(_),
                ..
            }
        }
    )));
}

#[test]
fn a_transport_failure_reconnects_with_backoff() {
    let mut harness = connected();
    route_session(&harness);
    harness.core.open_session(SESSION.into());
    harness.pump();
    let (sink, _, _) = harness.streams.last();
    sink.finish(Some(ConnectionFailure::Offline {
        message: "no route".into(),
    }));
    harness.pump();
    assert_eq!(harness.streams.count(), 1);
    assert!(harness.scheduler.pending_timers() > 0);
    harness.advance(5_000);
    assert_eq!(harness.streams.count(), 2);
}

#[test]
fn the_updates_socket_watches_sessions_and_applies_frames() {
    let mut harness = connected();
    let (request, sink, socket) = harness.sockets.last();
    assert!(
        request
            .url
            .starts_with("ws://127.0.0.1:6767/v1/sessions/updates")
    );
    sink.opened();
    harness.pump();
    let sent = lock(&socket.sent).clone();
    let watch: serde_json::Value = serde_json::from_str(sent.last().unwrap()).unwrap();
    assert_eq!(watch["type"], "watch");
    assert_eq!(watch["session_ids"].as_array().unwrap().len(), 3);
    harness.events.take();
    let row = r#"{"id":"e4c1ef06c8b844a6bb414db5efe0df7e","status":"running","title":"renamed","created_at":1,"updated_at":2,"permission_level":4}"#;
    sink.message(SocketMessage::Text {
        text: format!(r#"{{"type":"snapshot","items":[{row}]}}"#),
    });
    sink.message(SocketMessage::Text {
        text: r#"{"type":"mystery","secret":"x"}"#.into(),
    });
    harness.pump();
    let events = harness.events.take();
    let upsert = events.iter().find_map(|event| match event {
        CoreEvent::SessionListChanged {
            change: SessionListChange::Upsert { sessions },
        } => Some(sessions),
        _ => None,
    });
    assert_eq!(upsert.unwrap()[0].title, "renamed");
    assert!(events.contains(&CoreEvent::UnknownUpdate {
        frame_type: "mystery".into()
    }));
    assert!(events.contains(&CoreEvent::UpdatesLinkChanged {
        state: LinkState::Live
    }));
}

#[test]
fn list_failures_are_reported_not_dropped() {
    let mut harness = Harness::new(UrlPolicy::Development);
    harness.local_server();
    harness
        .http
        .route("/v1/sessions", json(500, r#"{"detail":"boom"}"#));
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.connect("http://127.0.0.1:6767".into(), None).await })
        .unwrap();
    assert!(harness.events.all().iter().any(|event| matches!(
        event,
        CoreEvent::Error {
            scope: ErrorScope::SessionList,
            error: CoreError::Session { .. },
        }
    )));
}

#[test]
fn release_builds_refuse_remote_http() {
    let mut harness = Harness::new(UrlPolicy::Release);
    let core = Arc::clone(&harness.core);
    let error = harness
        .run(async move {
            core.connect("http://omnigent.example.com".into(), None)
                .await
        })
        .unwrap_err();
    assert!(matches!(error, CoreError::InvalidUrl { .. }), "{error:?}");
    assert_eq!(harness.http.paths(), Vec::<String>::new());
    assert!(harness.events.all().iter().any(|event| matches!(
        event,
        CoreEvent::ConnectionChanged {
            phase: ConnectionPhase::Failed { .. }
        }
    )));
}

#[test]
fn accounts_servers_need_sign_in_then_connect_with_a_bearer() {
    let mut harness = Harness::new(UrlPolicy::Development);
    harness.http.route(
        "/.well-known/omnigent.json",
        json(200, r#"{"manifest_version":1,"auth":{"mode":"accounts"}}"#),
    );
    harness.http.route(
        "/v1/info",
        json(200, r#"{"single_user":false,"accounts_enabled":true}"#),
    );
    let core = Arc::clone(&harness.core);
    let phase = harness
        .run(async move {
            core.connect("https://omnigent.example.com".into(), None)
                .await
        })
        .unwrap();
    let ConnectionPhase::SignInRequired { methods, .. } = phase else {
        panic!("{phase:?}");
    };
    assert_eq!(methods, vec![crate::events::SignInMethod::Password]);

    harness.http.route(
        "/auth/login",
        json(
            200,
            r#"{"token":"tok-123","expires_in":3600,"user":{"id":"u1"}}"#,
        ),
    );
    harness
        .http
        .route("/v1/me", json(200, r#"{"user_id":"u1"}"#));
    harness.http.route(
        "/v1/sessions",
        json(200, r#"{"object":"list","data":[],"has_more":false}"#),
    );
    let core = Arc::clone(&harness.core);
    let server = harness
        .run(async move { core.sign_in_with_password("ada".into(), "pw".into()).await })
        .unwrap();
    assert_eq!(server.user_id, "u1");
    let me = lock(&harness.http.requests)
        .iter()
        .rev()
        .find(|request| request.url.ends_with("/v1/me"))
        .cloned()
        .unwrap();
    assert!(
        me.headers
            .iter()
            .any(|header| header.name == "Authorization" && header.value == "Bearer tok-123")
    );
    let debug = format!("{me:?}");
    assert!(!debug.contains("tok-123"), "{debug}");
}

/// `Authorization` of the last request to `suffix`.
fn last_authorization(harness: &Harness, suffix: &str) -> Option<String> {
    lock(&harness.http.requests)
        .iter()
        .rev()
        .find(|request| request.url.ends_with(suffix))
        .unwrap_or_else(|| panic!("no request to {suffix}"))
        .headers
        .iter()
        .find(|header| header.name == "Authorization")
        .map(|header| header.value.clone())
}

const LOOPBACK: &str = "http://127.0.0.1:6797";

/// An accounts-mode server on a loopback root, as `omnigent server` with
/// `OMNIGENT_AUTH_PROVIDER=accounts` on 127.0.0.1 answers.
fn loopback_accounts_server() -> Harness {
    let harness = Harness::new(UrlPolicy::Development);
    harness.http.route(
        "/.well-known/omnigent.json",
        json(200, r#"{"manifest_version":1,"auth":{"mode":"accounts"}}"#),
    );
    harness.http.route(
        "/v1/info",
        json(
            200,
            r#"{"single_user":false,"accounts_enabled":true,"login_url":"/login"}"#,
        ),
    );
    harness.http.route(
        "/auth/login",
        json(
            200,
            r#"{"token":"tok-loop","expires_in":3600,"user":{"id":"u1"}}"#,
        ),
    );
    harness
        .http
        .route("/v1/me", json(200, r#"{"user_id":"u1"}"#));
    harness.http.route(
        "/v1/sessions",
        json(200, r#"{"object":"list","data":[],"has_more":false}"#),
    );
    harness
}

#[test]
fn loopback_accounts_servers_sign_in_restore_and_sign_out() {
    let mut harness = loopback_accounts_server();

    // Discovery says accounts, so a loopback root asks for a password like a hosted one.
    let core = Arc::clone(&harness.core);
    let phase = harness
        .run(async move { core.connect(LOOPBACK.into(), None).await })
        .unwrap();
    let ConnectionPhase::SignInRequired { methods, mode, .. } = phase else {
        panic!("{phase:?}");
    };
    assert_eq!(methods, vec![crate::events::SignInMethod::Password]);
    assert_eq!(mode, crate::events::AuthenticationMode::Accounts);
    assert!(
        !harness.http.paths().iter().any(|path| path == "/v1/me"),
        "no identity request before sign-in"
    );

    // Password sign-in saves the credential and connects with it.
    let core = Arc::clone(&harness.core);
    let server = harness
        .run(async move { core.sign_in_with_password("ada".into(), "pw".into()).await })
        .unwrap();
    assert_eq!(server.user_id, "u1");
    assert_eq!(server.account_id, format!("{LOOPBACK}\nu1"));
    assert_eq!(server.mode, crate::events::AuthenticationMode::Accounts);
    assert_eq!(
        lock(&harness.store.items).len(),
        1,
        "the credential was saved"
    );
    assert_eq!(
        last_authorization(&harness, "/v1/me").as_deref(),
        Some("Bearer tok-loop")
    );
    assert!(harness.events.all().iter().any(|event| matches!(
        event,
        CoreEvent::ConnectionChanged {
            phase: ConnectionPhase::Connected { .. }
        }
    )));

    // Restore: a fresh connect for the saved account loads the credential, no password.
    harness.core.disconnect();
    let http = Arc::clone(&harness.http);
    let logins = move || {
        http.paths()
            .iter()
            .filter(|path| *path == "/auth/login")
            .count()
    };
    let before = logins();
    let core = Arc::clone(&harness.core);
    let phase = harness
        .run(async move { core.connect(LOOPBACK.into(), Some("u1".into())).await })
        .unwrap();
    let ConnectionPhase::Connected { server } = phase else {
        panic!("{phase:?}");
    };
    assert_eq!(server.user_id, "u1");
    assert_eq!(logins(), before, "restore never sends the password again");
    assert_eq!(
        last_authorization(&harness, "/v1/me").as_deref(),
        Some("Bearer tok-loop")
    );

    // Sign out deletes the credential; the next restore has to ask again.
    let core = Arc::clone(&harness.core);
    harness.run(async move { core.sign_out().await }).unwrap();
    assert_eq!(lock(&harness.store.items).len(), 0);
    let core = Arc::clone(&harness.core);
    let phase = harness
        .run(async move { core.connect(LOOPBACK.into(), Some("u1".into())).await })
        .unwrap();
    assert!(
        matches!(phase, ConnectionPhase::SignInRequired { reason: None, .. }),
        "{phase:?}"
    );
}

#[test]
fn loopback_single_user_servers_connect_without_credentials() {
    // The recorded local runtime reports manifest mode `header` plus `single_user`.
    let harness = connected();
    let connected = harness
        .events
        .all()
        .into_iter()
        .find_map(|event| match event {
            CoreEvent::ConnectionChanged {
                phase: ConnectionPhase::Connected { server },
            } => Some(server),
            _ => None,
        })
        .unwrap();
    assert_eq!(connected.user_id, "local");
    assert_eq!(
        connected.mode,
        crate::events::AuthenticationMode::LocalSingleUser
    );
    assert_eq!(last_authorization(&harness, "/v1/info"), None);
    assert_eq!(last_authorization(&harness, "/v1/me"), None);
    assert_eq!(lock(&harness.store.items).len(), 0);
    // A password never goes to it.
    let mut harness = harness;
    let core = Arc::clone(&harness.core);
    let error = harness
        .run(async move { core.sign_in_with_password("ada".into(), "pw".into()).await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Auth { .. }), "{error:?}");
    assert!(
        !harness
            .http
            .paths()
            .iter()
            .any(|path| path == "/auth/login"),
        "no password request"
    );
}

#[test]
fn closing_a_session_cancels_its_stream() {
    let mut harness = connected();
    route_session(&harness);
    harness.core.open_session(SESSION.into());
    harness.pump();
    let (_, handle, _) = harness.streams.last();
    harness.core.close_session(SESSION.into());
    harness.pump();
    assert_eq!(handle.cancels.load(Ordering::SeqCst), 1);
}

#[test]
fn the_demo_connects_offline_and_lists_samples() {
    let mut harness = Harness::demo();
    let core = Arc::clone(&harness.core);
    let phase = harness
        .run(async move { core.connect(String::new(), None).await })
        .unwrap();
    assert!(matches!(phase, ConnectionPhase::Connected { .. }));
    let events = harness.events.all();
    let sessions = events
        .iter()
        .find_map(|event| match event {
            CoreEvent::SessionListChanged {
                change: SessionListChange::Reset { sessions },
            } => Some(sessions.clone()),
            _ => None,
        })
        .unwrap();
    assert_ne!(sessions.len(), 0);
    let id = sessions[0].id.clone();
    harness.core.open_session(id.clone());
    harness.pump();
    assert_ne!(rows_from(&harness.events.all(), &id).len(), 0);
}

/// A window's tabs keep several sessions open: answering a request in one that was not opened
/// last still updates its cards, and it can still send.
#[test]
fn every_open_demo_session_stays_live() {
    let mut harness = Harness::demo();
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.connect(String::new(), None).await })
        .unwrap();
    harness.core.open_session("demo-question".into());
    harness.core.open_session("demo-design".into());
    harness.pump();
    harness.events.take();

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
    let events = harness.events.take();
    assert!(
        events.iter().any(|event| matches!(
            event,
            CoreEvent::DecisionsChanged { session_id, decisions }
                if session_id == "demo-question" && decisions.is_empty()
        )),
        "{events:?}"
    );
    let core = Arc::clone(&harness.core);
    harness
        .run(async move {
            core.send_message("demo-question".into(), "Go on".into())
                .await
        })
        .unwrap();
}

/// A newest-first `/items` page of assistant messages.
fn message_page(ids: &[&str], has_more: bool) -> String {
    let data: Vec<serde_json::Value> = ids
        .iter()
        .map(|id| serde_json::json!({"id": id, "type": "message", "role": "assistant", "content": id}))
        .collect();
    serde_json::json!({"data": data, "has_more": has_more, "last_id": ids.last()}).to_string()
}

fn paging_events(events: &[CoreEvent]) -> Vec<(bool, bool)> {
    events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::HistoryPagingChanged {
                has_older,
                is_loading,
                ..
            } => Some((*has_older, *is_loading)),
            _ => None,
        })
        .collect()
}

fn row_ids(harness: &Harness) -> Vec<String> {
    rows_from(&harness.events.all(), SESSION)
        .into_iter()
        .map(|row| row.id)
        .collect()
}

#[test]
fn older_history_loads_above_the_rows_on_request() {
    let mut harness = connected();
    route_session(&harness);
    let items = format!("/v1/sessions/{SESSION}/items");
    harness
        .http
        .route(&items, json(200, &message_page(&["msg_3", "msg_2"], true)));
    harness.core.open_session(SESSION.into());
    harness.pump();
    let (sink, _, _) = harness.streams.last();
    sink.response(200, event_stream_head());
    sink.chunk(b"event: session.heartbeat\ndata: {\"type\":\"session.heartbeat\"}\n\n".to_vec());
    harness.pump();
    assert_eq!(row_ids(&harness), ["msg_2", "msg_3"]);
    assert_eq!(
        paging_events(&harness.events.all()),
        [(false, false), (true, false)]
    );

    harness
        .http
        .route(&items, json(200, &message_page(&["msg_1"], false)));
    harness.core.load_older_history(SESSION.into());
    harness.pump();
    assert_eq!(row_ids(&harness), ["msg_1", "msg_2", "msg_3"]);
    assert_eq!(
        paging_events(&harness.events.all()),
        [(false, false), (true, false), (true, true), (false, false)]
    );
    let older = lock(&harness.http.requests).last().cloned().unwrap();
    assert!(older.url.contains("after=msg_2"), "{}", older.url);
    // Nothing older is left to ask for.
    harness.core.load_older_history(SESSION.into());
    harness.pump();
    assert_eq!(
        lock(&harness.http.requests)
            .last()
            .map(|request| request.url.clone()),
        Some(older.url)
    );
}

const HEARTBEAT: &[u8] = b"event: session.heartbeat\ndata: {\"type\":\"session.heartbeat\"}\n\n";

fn offline() -> crate::http::TransportError {
    crate::http::TransportError::Offline {
        message: "no route".into(),
    }
}

fn delta_frame(item: &str, delta: &str) -> Vec<u8> {
    format!(
        "event: response.output_text.delta\ndata: {}\n\n",
        serde_json::json!({
            "type": "response.output_text.delta",
            "item_id": item,
            "output_index": 0,
            "content_index": 0,
            "delta": delta,
            "sequence_number": 1,
        })
    )
    .into_bytes()
}

/// A connected harness with `SESSION` open and its stream live and hydrated.
fn live_session() -> Harness {
    let mut harness = connected();
    route_session(&harness);
    harness.core.open_session(SESSION.into());
    harness.pump();
    let (sink, _, _) = harness.streams.last();
    sink.response(200, event_stream_head());
    sink.chunk(HEARTBEAT.to_vec());
    harness.pump();
    harness
}

fn link_states(events: &[CoreEvent]) -> Vec<LinkState> {
    events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::SessionLinkChanged { state, .. } => Some(state.clone()),
            _ => None,
        })
        .collect()
}

fn session_errors(events: &[CoreEvent]) -> Vec<CoreError> {
    events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::Error {
                scope: ErrorScope::Session { .. },
                error,
            } => Some(error.clone()),
            _ => None,
        })
        .collect()
}

fn list_errors(events: &[CoreEvent]) -> Vec<CoreError> {
    events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::Error {
                scope: ErrorScope::SessionList,
                error,
            } => Some(error.clone()),
            _ => None,
        })
        .collect()
}

#[test]
fn a_read_for_a_closed_session_is_ignored() {
    let mut harness = connected();
    route_session(&harness);
    let items = format!("/v1/sessions/{SESSION}/items");
    let gate = harness.http.hold(&items);
    harness.core.open_session(SESSION.into());
    harness.pump();
    let (sink, _, _) = harness.streams.last();
    sink.response(200, event_stream_head());
    sink.chunk(HEARTBEAT.to_vec());
    harness.pump();
    harness.core.close_session(SESSION.into());
    harness.pump();
    harness.events.take();
    gate.send(()).unwrap();
    harness.pump();
    assert_eq!(harness.events.take(), []);
}

#[test]
fn a_duplicate_frame_and_a_doubled_sink_change_nothing_twice() {
    let mut harness = live_session();
    let (sink, handle, _) = harness.streams.last();
    let frame = delta_frame("msg_1", "hello");
    sink.chunk(frame.clone());
    sink.chunk(frame);
    harness.pump();
    assert_eq!(session_errors(&harness.events.all()), []);

    // A second response head breaks the host contract: the attempt ends and reconnects.
    harness.events.take();
    sink.response(200, event_stream_head());
    harness.pump();
    let states = link_states(&harness.events.take());
    assert!(
        matches!(states[..], [LinkState::Failed { .. }]),
        "{states:?}"
    );
    assert_eq!(handle.cancels.load(Ordering::SeqCst), 1);

    // The ended attempt finishing, twice, is ignored.
    sink.finish(None);
    sink.finish(Some(ConnectionFailure::Cancelled));
    sink.chunk(HEARTBEAT.to_vec());
    harness.pump();
    assert_eq!(link_states(&harness.events.take()), []);
}

#[test]
fn closing_twice_and_closing_an_unknown_session_are_harmless() {
    let mut harness = live_session();
    let (_, handle, _) = harness.streams.last();
    harness.core.close_session(SESSION.into());
    harness.core.close_session(SESSION.into());
    harness.core.close_session("never-opened".into());
    harness.pump();
    assert_eq!(handle.cancels.load(Ordering::SeqCst), 1);
    assert!(!harness.core.sessions().is_live_session(SESSION));
}

#[test]
fn opening_twice_keeps_one_stream_and_reports_the_state_again() {
    let mut harness = live_session();
    harness.events.take();
    harness.core.open_session(SESSION.into());
    harness.pump();
    assert_eq!(harness.streams.count(), 1);
    let events = harness.events.take();
    assert!(
        events
            .iter()
            .any(|event| matches!(event, CoreEvent::TranscriptReset { .. })),
        "{events:#?}"
    );
}

#[test]
fn a_session_opened_while_disconnected_starts_on_connect_and_stops_on_disconnect() {
    let mut harness = Harness::new(UrlPolicy::Development);
    harness.local_server();
    route_session(&harness);
    harness.core.open_session(SESSION.into());
    harness.pump();
    assert_eq!(harness.streams.count(), 0);
    harness
        .call(|core| async move { core.connect("http://127.0.0.1:6767".into(), None).await })
        .unwrap();
    assert_eq!(harness.streams.count(), 1);
    let (sink, handle, _) = harness.streams.last();
    sink.response(200, event_stream_head());
    sink.chunk(HEARTBEAT.to_vec());
    harness.pump();

    // The disconnect wins over everything the old stream still has to say.
    harness.core.disconnect();
    harness.pump();
    assert_eq!(handle.cancels.load(Ordering::SeqCst), 1);
    harness.events.take();
    sink.chunk(delta_frame("msg_1", "late"));
    sink.finish(Some(ConnectionFailure::Cancelled));
    harness.pump();
    assert_eq!(harness.events.take(), []);
    harness.advance(60_000);
    assert_eq!(
        harness.streams.count(),
        1,
        "no reconnect after a disconnect"
    );
}

#[test]
fn a_timer_for_a_closed_session_or_a_dead_attempt_does_nothing() {
    let mut harness = connected();
    route_session(&harness);
    harness.core.open_session(SESSION.into());
    harness.pump();
    let (sink, _, _) = harness.streams.last();
    sink.finish(Some(ConnectionFailure::Offline {
        message: "no route".into(),
    }));
    harness.pump();
    assert!(harness.scheduler.pending_timers() > 0);

    // The reconnect timer was pending when the tab closed.
    harness.core.close_session(SESSION.into());
    harness.pump();
    harness.advance(60_000);
    assert_eq!(harness.streams.count(), 1);
}

#[test]
fn a_clock_that_moves_backward_neither_panics_nor_loses_the_stream() {
    let mut harness = live_session();
    harness.advance(10_000);
    let (sink, handle, _) = harness.streams.last();
    sink.chunk(HEARTBEAT.to_vec());
    harness.pump();
    harness.events.take();
    harness.rewind(10_000);
    sink.chunk(HEARTBEAT.to_vec());
    harness.pump();
    assert_eq!(link_states(&harness.events.take()), []);
    assert_eq!(handle.cancels.load(Ordering::SeqCst), 0);

    // Losing it now measures a negative lifetime: it still reconnects.
    sink.finish(None);
    harness.pump();
    harness.advance(10_000);
    assert_eq!(harness.streams.count(), 2);
}

#[test]
fn a_stream_the_host_could_not_start_retries_with_backoff() {
    let mut harness = connected();
    route_session(&harness);
    *lock(&harness.streams.refuse) = Some(offline());
    harness.core.open_session(SESSION.into());
    harness.pump();
    assert_eq!(harness.streams.count(), 0);
    let states = link_states(&harness.events.all());
    assert!(
        states
            .iter()
            .any(|state| matches!(state, LinkState::Reconnecting { .. })),
        "{states:?}"
    );
    harness.advance(10_000);
    assert_eq!(harness.streams.count(), 1);
}

#[test]
fn a_foreground_reopens_what_ended_and_ignores_what_is_live() {
    let mut harness = live_session();
    let (sink, _, _) = harness.streams.last();
    sink.chunk(b"data: [DONE]\n\n".to_vec());
    harness.pump();
    assert!(link_states(&harness.events.all()).contains(&LinkState::Closed));
    let sockets = harness.sockets.count();
    harness.core.foreground();
    harness.pump();
    assert_eq!(harness.streams.count(), 2, "a closed stream reopens");
    assert_eq!(harness.sockets.count(), sockets, "the live socket stays");
    harness.core.foreground();
    harness.pump();
    assert_eq!(harness.streams.count(), 2, "a connecting stream stays");

    harness.core.disconnect();
    harness.pump();
    harness.core.foreground();
    harness.pump();
    assert_eq!(harness.streams.count(), 2, "a disconnected core stays down");
}

#[test]
fn a_400_stream_on_a_plain_server_retries_without_routing() {
    let mut harness = connected();
    route_session(&harness);
    harness.core.open_session(SESSION.into());
    harness.pump();
    let (sink, _, request) = harness.streams.last();
    assert!(
        !request
            .headers
            .iter()
            .any(|header| header.name == omnigent_core::SLICE_KEY_HEADER)
    );
    sink.response(400, Vec::new());
    harness.pump();
    harness.advance(10_000);
    assert_eq!(harness.streams.count(), 2);
}

#[test]
fn an_event_that_does_not_apply_is_reported_and_the_stream_goes_on() {
    let mut harness = live_session();
    let (sink, handle, _) = harness.streams.last();
    harness.events.take();
    // `delta` must be a string.
    sink.chunk(
        b"event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"item_id\":7,\"delta\":{}}\n\n"
            .to_vec(),
    );
    harness.pump();
    let events = harness.events.take();
    assert_eq!(session_errors(&events).len(), 1, "{events:#?}");
    assert_eq!(handle.cancels.load(Ordering::SeqCst), 0);
}

#[test]
fn a_frame_that_is_not_an_event_reconnects() {
    let mut harness = live_session();
    let (sink, handle, _) = harness.streams.last();
    harness.events.take();
    sink.chunk(b"data: not json\n\n".to_vec());
    harness.pump();
    let states = link_states(&harness.events.take());
    assert!(
        matches!(
            states[..],
            [LinkState::Reconnecting {
                reason: CoreError::Link { .. },
                ..
            }]
        ),
        "{states:?}"
    );
    assert_eq!(handle.cancels.load(Ordering::SeqCst), 1);
}

#[test]
fn too_many_events_while_history_loads_restarts_the_stream() {
    let mut harness = connected();
    route_session(&harness);
    let gate = harness.http.hold(&format!("/v1/sessions/{SESSION}/items"));
    harness.core.open_session(SESSION.into());
    harness.pump();
    let (sink, _, _) = harness.streams.last();
    sink.response(200, event_stream_head());
    sink.chunk(HEARTBEAT.to_vec());
    harness.pump();
    harness.events.take();
    let frame = delta_frame("msg_1", "x");
    for _ in 0..=omnigent_core::reconcile::MAX_BUFFERED_EVENTS {
        sink.chunk(frame.clone());
    }
    harness.pump();
    let states = link_states(&harness.events.take());
    assert!(
        states
            .iter()
            .any(|state| matches!(state, LinkState::Reconnecting { .. })),
        "{states:?}"
    );
    assert!(!harness.core.sessions().is_live_session(SESSION));
    drop(gate);
    harness.pump();
    harness.advance(10_000);
    assert_eq!(harness.streams.count(), 2);
}

fn hydration_failure_case(response: crate::http::HttpResponse) -> Vec<CoreEvent> {
    let mut harness = connected();
    route_session(&harness);
    harness
        .http
        .route(&format!("/v1/sessions/{SESSION}/items"), response);
    harness.core.open_session(SESSION.into());
    harness.pump();
    let (sink, _, _) = harness.streams.last();
    sink.response(200, event_stream_head());
    harness.events.take();
    sink.chunk(HEARTBEAT.to_vec());
    harness.pump();
    harness.events.take()
}

#[test]
fn a_failed_history_read_reconnects_or_asks_for_sign_in() {
    let reconnects = |states: &[LinkState]| {
        states
            .iter()
            .any(|state| matches!(state, LinkState::Reconnecting { .. }))
    };
    let failed = |states: &[LinkState]| {
        states
            .iter()
            .any(|state| matches!(state, LinkState::Failed { .. }))
    };
    // A server error is transient.
    let events = hydration_failure_case(json(500, r#"{"detail":"boom"}"#));
    assert_eq!(session_errors(&events).len(), 1, "{events:#?}");
    assert!(reconnects(&link_states(&events)), "{events:#?}");
    // A session still being created may appear.
    let events = hydration_failure_case(json(404, r#"{"detail":"no"}"#));
    assert_eq!(session_errors(&events).len(), 1, "{events:#?}");
    assert!(reconnects(&link_states(&events)), "{events:#?}");
    // A page this app cannot read and a redirect will not get better.
    for response in [json(200, "not json"), json(302, "")] {
        let events = hydration_failure_case(response);
        assert_eq!(session_errors(&events).len(), 1, "{events:#?}");
        assert!(failed(&link_states(&events)), "{events:#?}");
    }
    // A 401 and a 403 end the session link; the app signs in again, not an error toast.
    for status in [401, 403] {
        let events = hydration_failure_case(json(status, r#"{"detail":"no"}"#));
        assert!(
            events.iter().any(|event| matches!(
                event,
                CoreEvent::ConnectionChanged {
                    phase: ConnectionPhase::SignInRequired { .. }
                }
            )),
            "{status}: {events:#?}"
        );
    }
}

#[test]
fn a_host_error_at_each_step_of_a_history_read_reconnects() {
    for (error, label, reconnects) in [
        (offline(), "offline", true),
        // The app asked for this: nothing retries a cancelled read.
        (crate::http::TransportError::Cancelled, "cancelled", false),
    ] {
        let mut harness = connected();
        route_session(&harness);
        harness
            .http
            .fail_next(&format!("/v1/sessions/{SESSION}/items"), error);
        harness.core.open_session(SESSION.into());
        harness.pump();
        let (sink, _, _) = harness.streams.last();
        sink.response(200, event_stream_head());
        harness.events.take();
        sink.chunk(HEARTBEAT.to_vec());
        harness.pump();
        let events = harness.events.take();
        assert_eq!(
            link_states(&events)
                .iter()
                .any(|state| matches!(state, LinkState::Reconnecting { .. })),
            reconnects,
            "{label}: {events:#?}"
        );
    }
}

#[test]
fn a_snapshot_the_conversation_cannot_show_reconnects() {
    let mut harness = connected();
    route_session(&harness);
    harness.http.route(
        &format!("/v1/sessions/{SESSION}"),
        json(
            200,
            r#"{"id":"another-session","status":"idle","created_at":1}"#,
        ),
    );
    harness.core.open_session(SESSION.into());
    harness.pump();
    let (sink, _, _) = harness.streams.last();
    sink.response(200, event_stream_head());
    harness.events.take();
    sink.chunk(HEARTBEAT.to_vec());
    harness.pump();
    let events = harness.events.take();
    assert_eq!(session_errors(&events).len(), 1, "{events:#?}");
    assert!(
        link_states(&events)
            .iter()
            .any(|state| matches!(state, LinkState::Failed { .. })),
        "{events:#?}"
    );
}

#[test]
fn a_turn_failure_is_reported_as_a_session_failure() {
    let mut harness = live_session();
    let (sink, _, _) = harness.streams.last();
    harness.events.take();
    sink.chunk(
        b"event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"id\":\"r1\",\"status\":\"failed\",\"error\":{\"code\":\"x\",\"message\":\"the model refused\"}}}\n\n"
            .to_vec(),
    );
    harness.pump();
    let events = harness.events.take();
    assert!(
        events.iter().any(|event| matches!(
            event,
            CoreEvent::SessionFailure { message, .. } if message.contains("refused")
        )),
        "{events:#?}"
    );
}

/// The updates socket of a connected harness, opened and live.
fn live_socket(
    harness: &mut Harness,
) -> (
    Arc<crate::host::MessageSink>,
    Arc<crate::test_support::FakeSocket>,
) {
    let (_, sink, socket) = harness.sockets.last();
    sink.opened();
    sink.message(SocketMessage::Text {
        text: r#"{"type":"snapshot","items":[]}"#.into(),
    });
    harness.pump();
    (sink, socket)
}

fn frame(harness: &mut Harness, sink: &crate::host::MessageSink, text: &serde_json::Value) {
    sink.message(SocketMessage::Text {
        text: text.to_string(),
    });
    harness.pump();
}

fn session_row(id: &str, status: &str, updated_at: i64) -> serde_json::Value {
    serde_json::json!({
        "id": id,
        "status": status,
        "title": id,
        "created_at": 1,
        "updated_at": updated_at,
        "permission_level": 4,
    })
}

#[test]
fn the_socket_reports_each_frame_kind() {
    let mut harness = connected();
    let (sink, _) = live_socket(&mut harness);
    harness.events.take();
    frame(
        &mut harness,
        &sink,
        &serde_json::json!({"type": "hosts_changed"}),
    );
    frame(
        &mut harness,
        &sink,
        &serde_json::json!({"type": "projects_changed"}),
    );
    frame(
        &mut harness,
        &sink,
        &serde_json::json!({"type": "heartbeat"}),
    );
    let events = harness.events.take();
    assert!(events.contains(&CoreEvent::HostsChanged), "{events:#?}");
    assert!(events.contains(&CoreEvent::ProjectsChanged), "{events:#?}");
    assert_eq!(events.len(), 2, "{events:#?}");
}

#[test]
fn a_removed_frame_closes_the_open_session_and_only_it() {
    let mut harness = live_session();
    let (_, handle, _) = harness.streams.last();
    let (sink, _) = live_socket(&mut harness);
    harness.core.open_session("other_session".into());
    harness.pump();
    harness.events.take();
    frame(
        &mut harness,
        &sink,
        &serde_json::json!({"type": "removed", "ids": [SESSION]}),
    );
    let events = harness.events.take();
    assert!(
        events.contains(&CoreEvent::SessionClosed {
            session_id: SESSION.into()
        }),
        "{events:#?}"
    );
    assert!(
        !events.contains(&CoreEvent::SessionClosed {
            session_id: "other_session".into()
        }),
        "{events:#?}"
    );
    assert_eq!(handle.cancels.load(Ordering::SeqCst), 1);
    // Its frames can arrive twice.
    frame(
        &mut harness,
        &sink,
        &serde_json::json!({"type": "removed", "ids": [SESSION]}),
    );
    assert!(!harness.events.take().contains(&CoreEvent::SessionClosed {
        session_id: SESSION.into()
    }));
}

#[test]
fn a_list_row_an_open_session_cannot_apply_is_reported() {
    let mut harness = live_session();
    let (sink, _) = live_socket(&mut harness);
    harness.events.take();
    let mut row = session_row(SESSION, "idle", 3);
    row["status"] = serde_json::json!("a-status-from-the-future");
    frame(
        &mut harness,
        &sink,
        &serde_json::json!({"type": "changed", "items": [row]}),
    );
    let events = harness.events.take();
    assert!(
        !session_errors(&events).is_empty() || !list_errors(&events).is_empty(),
        "{events:#?}"
    );
}

#[test]
fn the_socket_refused_or_failing_reconnects_and_late_callbacks_are_ignored() {
    let mut harness = Harness::new(UrlPolicy::Development);
    harness.local_server();
    *lock(&harness.sockets.refuse) = Some(offline());
    harness
        .call(|core| async move { core.connect("http://127.0.0.1:6767".into(), None).await })
        .unwrap();
    assert_eq!(harness.sockets.count(), 0);
    harness.advance(10_000);
    assert_eq!(harness.sockets.count(), 1);

    // A send fails: the attempt ends and another starts.
    let (_, sink, socket) = harness.sockets.last();
    *lock(&socket.send_failure) = Some(offline());
    sink.opened();
    harness.pump();
    harness.advance(10_000);
    assert_eq!(harness.sockets.count(), 2);

    // The old socket's late events reach nothing.
    harness.events.take();
    sink.message(SocketMessage::Text {
        text: r#"{"type":"hosts_changed"}"#.into(),
    });
    sink.opened();
    sink.ended(crate::host::SocketEnd::Failed {
        failure: ConnectionFailure::Cancelled,
    });
    harness.pump();
    assert!(!harness.events.take().contains(&CoreEvent::HostsChanged));
    assert_eq!(harness.sockets.count(), 2);
}

#[test]
fn a_rejected_socket_asks_for_sign_in_and_stops_retrying() {
    let mut harness = connected();
    let (_, sink, _) = harness.sockets.last();
    sink.ended(crate::host::SocketEnd::HandshakeRejected { status: 401 });
    harness.pump();
    assert!(harness.events.all().iter().any(|event| matches!(
        event,
        CoreEvent::ConnectionChanged {
            phase: ConnectionPhase::SignInRequired { .. }
        }
    )));
    let sockets = harness.sockets.count();
    harness.advance(60_000);
    assert_eq!(harness.sockets.count(), sockets);
}

#[test]
fn a_socket_that_resumes_reloads_the_list() {
    let mut harness = connected();
    let (sink, _) = live_socket(&mut harness);
    sink.ended(crate::host::SocketEnd::Closed {
        code: 1012,
        reason: "restart".into(),
    });
    harness.pump();
    harness.advance(10_000);
    let lists = harness.http.count("/v1/sessions");
    let (_, sink, _) = harness.sockets.last();
    sink.opened();
    sink.message(SocketMessage::Text {
        text: r#"{"type":"snapshot","items":[]}"#.into(),
    });
    harness.pump();
    assert_eq!(harness.http.count("/v1/sessions"), lists + 1);
}

#[test]
fn a_bearer_rotation_with_no_connection_reports_nothing() {
    let mut harness = connected();
    harness.core.disconnect();
    harness.pump();
    harness.events.take();
    harness.core.post(crate::engine::Msg::BearerRotated {
        bearer: omnigent_core::auth::SecretString::new("t"),
        expires_at_ms: None,
    });
    harness.pump();
    assert_eq!(harness.events.take(), []);
}

#[test]
fn listeners_can_leave_and_a_late_id_is_unknown() {
    let mut harness = connected();
    let second = Arc::new(crate::test_support::Recorder::default());
    let id = harness.core.subscribe(second.clone());
    assert!(harness.core.unsubscribe(id));
    assert!(!harness.core.unsubscribe(id));
    harness.core.refresh_sessions();
    harness.pump();
    assert_eq!(second.all(), []);
    assert_eq!(
        format!("{:?}", crate::engine::Listeners::default()),
        "Listeners { count: 0, .. }"
    );
}

/// A listener that calls back into the core from inside `on_event`.
struct Reentrant {
    core: std::sync::Mutex<Option<std::sync::Weak<crate::client::ClientCore>>>,
    own_id: std::sync::atomic::AtomicU64,
    seen: std::sync::atomic::AtomicUsize,
}

impl crate::events::CoreListener for Reentrant {
    fn on_event(&self, _event: CoreEvent) {
        self.seen.fetch_add(1, Ordering::SeqCst);
        let core = lock(&self.core).clone().and_then(|core| core.upgrade());
        if let Some(core) = core {
            // Every synchronous call a host could make from a callback.
            core.unsubscribe(self.own_id.load(Ordering::SeqCst));
            core.subscribe(Arc::new(crate::test_support::Recorder::default()));
            core.set_view(Some(SESSION.into()), true);
            core.close_session(SESSION.into());
            core.refresh_sessions();
            // Each of these answers an error or a value without waiting on the engine.
            assert!(core.composer_text(SESSION.into()).is_ok());
            assert!(core.is_send_blocked(SESSION.into()).is_ok());
            core.disconnect();
            *lock(&self.core) = None;
        }
    }
}

#[test]
fn a_listener_may_call_back_into_the_core_during_delivery() {
    let mut harness = live_session();
    let listener = Arc::new(Reentrant {
        core: std::sync::Mutex::new(Some(Arc::downgrade(&harness.core))),
        own_id: std::sync::atomic::AtomicU64::new(0),
        seen: std::sync::atomic::AtomicUsize::new(0),
    });
    let id = harness.core.subscribe(listener.clone());
    listener.own_id.store(id, Ordering::SeqCst);
    harness.core.refresh_sessions();
    harness.pump();
    assert_eq!(
        listener.seen.load(Ordering::SeqCst),
        1,
        "it left on the first event"
    );
    let last = crate::test_support::phases(&harness.events.all()).pop();
    assert_eq!(last, Some(ConnectionPhase::Disconnected));
}

/// A transport that delivers everything from inside `open_stream`, as the host contract allows.
struct EagerStreams;

impl crate::host::EventStreamTransport for EagerStreams {
    fn open_stream(
        &self,
        _request: crate::http::HttpRequest,
        sink: Arc<crate::host::ByteSink>,
    ) -> Result<Arc<dyn crate::host::StreamHandle>, crate::http::TransportError> {
        sink.response(200, event_stream_head());
        sink.chunk(HEARTBEAT.to_vec());
        sink.finish(None);
        Ok(Arc::new(crate::test_support::FakeHandle::default()))
    }
}

#[test]
fn a_sink_called_before_open_returns_is_handled_in_order() {
    let mut harness = Harness::with_streams(UrlPolicy::Development, Arc::new(EagerStreams));
    harness.local_server();
    route_session(&harness);
    harness
        .call(|core| async move { core.connect("http://127.0.0.1:6767".into(), None).await })
        .unwrap();
    harness.core.open_session(SESSION.into());
    harness.pump();
    let states = link_states(&harness.events.all());
    assert!(
        states.contains(&LinkState::Live),
        "the head and heartbeat count: {states:?}"
    );
    assert!(
        states
            .iter()
            .any(|state| matches!(state, LinkState::Reconnecting { .. })),
        "the end counts too: {states:?}"
    );
}

#[test]
fn shutting_down_stops_the_engine_and_every_stream() {
    let mut harness = live_session();
    let (_, handle, _) = harness.streams.last();
    let (_, _, socket) = harness.sockets.last();
    harness.core.shutdown();
    harness.pump();
    assert_eq!(handle.cancels.load(Ordering::SeqCst), 1);
    assert_eq!(lock(&socket.closes).len(), 1);
    // A second shutdown, or anything else, reaches no engine.
    harness.events.take();
    harness.core.shutdown();
    harness.core.refresh_sessions();
    harness.pump();
    assert_eq!(harness.events.take(), []);
    let core = Arc::clone(&harness.core);
    let result = harness.run(async move { core.mark_session_seen(SESSION.into()).await });
    assert!(
        matches!(result, Err(CoreError::Session { .. })),
        "{result:?}"
    );
    let core = Arc::clone(&harness.core);
    let result = harness.run(async move { core.set_session_unread(SESSION.into(), true).await });
    assert!(
        matches!(result, Err(CoreError::Session { .. })),
        "{result:?}"
    );
}

#[test]
fn inventory_hints_reload_the_list_after_a_delay_unless_the_socket_is_live() {
    let mut harness = connected();
    let (_, sink, _) = harness.sockets.last();
    let lists = harness.http.count("/v1/sessions");
    harness.core.post(crate::engine::Msg::Client(
        omnigent_core::ClientEvent::InventoryInvalidated,
    ));
    harness.core.post(crate::engine::Msg::Client(
        omnigent_core::ClientEvent::InventoryInvalidated,
    ));
    harness.pump();
    harness.advance(3_000);
    assert_eq!(harness.http.count("/v1/sessions"), lists + 1, "one reload");

    sink.opened();
    sink.message(SocketMessage::Text {
        text: r#"{"type":"snapshot","items":[]}"#.into(),
    });
    harness.pump();
    harness.core.post(crate::engine::Msg::Client(
        omnigent_core::ClientEvent::InventoryInvalidated,
    ));
    harness.pump();
    harness.advance(3_000);
    assert_eq!(
        harness.http.count("/v1/sessions"),
        lists + 1,
        "the socket covers it"
    );
}

#[test]
fn a_pending_inventory_reload_dies_with_the_connection() {
    let mut harness = connected();
    let lists = harness.http.count("/v1/sessions");
    harness.core.post(crate::engine::Msg::Client(
        omnigent_core::ClientEvent::InventoryInvalidated,
    ));
    harness.pump();
    harness.core.disconnect();
    harness.pump();
    harness.advance(10_000);
    assert_eq!(harness.http.count("/v1/sessions"), lists);
}

#[test]
fn sessions_removed_through_the_client_leave_the_list_and_the_watch() {
    let mut harness = connected();
    harness.events.take();
    harness.core.post(crate::engine::Msg::Client(
        omnigent_core::ClientEvent::SessionsRemoved {
            ids: vec!["session_a".into()],
        },
    ));
    harness.pump();
    let events = harness.events.take();
    assert!(
        events.iter().any(|event| matches!(
            event,
            CoreEvent::SessionListChanged {
                change: SessionListChange::Remove { ids }
            } if ids == &["session_a".to_owned()]
        )),
        "{events:#?}"
    );
}

#[test]
fn a_turn_end_notifies_after_settling_and_a_viewed_session_does_not() {
    let mut harness = connected();
    let (sink, _) = live_socket(&mut harness);
    harness.core.set_notifications_allowed(true);
    harness.pump();
    let seed = |harness: &mut Harness, status: &str| {
        let row = session_row("notify_me", status, 2);
        frame(
            harness,
            &sink,
            &serde_json::json!({"type": "changed", "items": [row]}),
        );
    };
    let notifications = |events: &[CoreEvent]| {
        events
            .iter()
            .filter_map(|event| match event {
                CoreEvent::Notification { notification } => Some(notification.clone()),
                _ => None,
            })
            .collect::<Vec<_>>()
    };
    seed(&mut harness, "running");
    seed(&mut harness, "idle");
    harness.events.take();
    harness.advance(9_999);
    assert_eq!(notifications(&harness.events.take()).len(), 0);
    harness.advance(1);
    let shown = notifications(&harness.events.take());
    assert_eq!(shown.len(), 1);
    assert_eq!(shown[0].session_id, "notify_me");
    assert_eq!(shown[0].kind, crate::events::NotificationKind::Completed);
    assert_ne!(shown[0].body, "");

    // A failure while viewed stays silent, checked again when due.
    harness.core.set_view(Some("notify_me".into()), true);
    harness.pump();
    seed(&mut harness, "running");
    seed(&mut harness, "failed");
    harness.advance(10_000);
    assert_eq!(notifications(&harness.events.take()).len(), 0);

    // A removed row takes its pending cue with it.
    harness.core.set_view(None, false);
    harness.pump();
    seed(&mut harness, "running");
    seed(&mut harness, "idle");
    frame(
        &mut harness,
        &sink,
        &serde_json::json!({"type": "removed", "ids": ["notify_me"]}),
    );
    harness.events.take();
    harness.advance(10_000);
    assert_eq!(notifications(&harness.events.take()).len(), 0);
}

#[test]
fn an_elicitation_notifies_at_once_and_the_badge_follows() {
    let mut harness = connected();
    let (sink, _) = live_socket(&mut harness);
    harness.core.set_notifications_allowed(true);
    harness.pump();
    let mut row = session_row("asking", "running", 2);
    frame(
        &mut harness,
        &sink,
        &serde_json::json!({"type": "changed", "items": [row.clone()]}),
    );
    harness.events.take();
    row["pending_elicitations_count"] = serde_json::json!(1);
    frame(
        &mut harness,
        &sink,
        &serde_json::json!({"type": "changed", "items": [row.clone()]}),
    );
    let events = harness.events.take();
    assert!(
        events.iter().any(|event| matches!(
            event,
            CoreEvent::Notification { notification }
                if notification.kind == crate::events::NotificationKind::Approval
        )),
        "{events:#?}"
    );
    assert!(
        events.iter().any(|event| matches!(
            event,
            CoreEvent::BadgeChanged { session_ids } if session_ids == &["asking".to_owned()]
        )),
        "{events:#?}"
    );
    // Looking at it clears the badge.
    harness.core.set_view(Some("asking".into()), true);
    harness.pump();
    assert!(harness.events.take().iter().any(|event| matches!(
        event,
        CoreEvent::BadgeChanged { session_ids } if session_ids.is_empty()
    )));
}

#[test]
fn the_demo_reconnects_open_sessions_and_a_stray_tick_does_nothing() {
    let mut harness = Harness::demo();
    harness.core.open_session("demo-design".into());
    harness.pump();
    harness
        .call(|core| async move { core.connect(String::new(), None).await })
        .unwrap();
    assert_ne!(rows_from(&harness.events.all(), "demo-design").len(), 0);

    harness.core.post(crate::engine::Msg::DemoTick);
    harness.core.post(crate::engine::Msg::DemoKick);
    harness.core.post(crate::engine::Msg::DemoKick);
    harness.pump();
    assert_eq!(harness.scheduler.pending_timers(), 1, "one ticker");
    harness.advance(crate::engine::DEMO_TICK_MS);
    assert_eq!(harness.scheduler.pending_timers(), 0);

    let mut real = connected();
    real.events.take();
    real.core.post(crate::engine::Msg::DemoTick);
    real.pump();
    assert_eq!(real.events.take(), []);
}
