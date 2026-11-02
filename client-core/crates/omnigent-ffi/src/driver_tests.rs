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
use crate::test_support::{Harness, envelope_response, fixture, json};
use crate::transcript::{Row, RowRole, apply_row_ops};

const SESSION: &str = "facbcc05b00f4321b98b1929d217abc5";

fn connected() -> Harness {
    let mut harness = Harness::new(UrlPolicy::Development);
    harness.local_server();
    let core = Arc::clone(&harness.core);
    let phase = harness
        .run(async move { core.connect("http://127.0.0.1:6767".into(), None).await })
        .unwrap();
    assert!(
        matches!(phase, ConnectionPhase::Connected { .. }),
        "{phase:?}"
    );
    harness
}

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
    assert!(events.contains(&CoreEvent::SessionHydrated {
        session_id: SESSION.into()
    }));
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
