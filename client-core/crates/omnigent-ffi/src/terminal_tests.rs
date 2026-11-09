//! Terminal attach through the real core: every state a host can see, and hostile ordering.
#![allow(
    clippy::too_many_lines,
    reason = "one journey per state a host can see"
)]

use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use omnigent_core::realtime::{ConnectionFailure as CoreFailure, LinkError};

use super::core;
use super::*;
use crate::events::{CoreEvent, ErrorScope};
use crate::host::{ConnectionFailure, SocketEnd, SocketMessage};
use crate::http::TransportError;
use crate::test_support::{Harness, connected, json};

#[derive(Default)]
struct Recorder {
    states: Mutex<Vec<TerminalAttachState>>,
    output: Mutex<Vec<u8>>,
    clipboard: Mutex<Vec<String>>,
    notices: Mutex<Vec<String>>,
    dropped: Mutex<Vec<(u64, TerminalInputDropReason)>>,
    resets: AtomicUsize,
}

impl TerminalAttachListener for Recorder {
    fn on_state(&self, state: TerminalAttachState) {
        crate::engine::lock(&self.states).push(state);
    }
    fn on_output(&self, bytes: Vec<u8>) {
        crate::engine::lock(&self.output).extend(bytes);
    }
    fn on_reset_screen(&self) {
        self.resets.fetch_add(1, Ordering::SeqCst);
    }
    fn on_clipboard_write(&self, text: String) {
        crate::engine::lock(&self.clipboard).push(text);
    }
    fn on_input_dropped(&self, byte_count: u64, reason: TerminalInputDropReason) {
        crate::engine::lock(&self.dropped).push((byte_count, reason));
    }
    fn on_notice(&self, message: String) {
        crate::engine::lock(&self.notices).push(message);
    }
}

impl Recorder {
    fn last(&self) -> TerminalAttachState {
        crate::engine::lock(&self.states).last().cloned().unwrap()
    }
}

/// An attach on a connected harness, started and its socket opened.
fn attached(permission_level: Option<i64>) -> (Harness, Arc<Recorder>, Arc<TerminalAttachDriver>) {
    let mut harness = connected();
    let recorder = Arc::new(Recorder::default());
    let driver = harness.core.terminal_attach(
        "conv_a".into(),
        "terminal_codex_main".into(),
        permission_level,
        None,
        recorder.clone(),
    );
    driver.start();
    harness.pump();
    let (_, sink, _) = harness.sockets.last();
    sink.opened();
    harness.pump();
    (harness, recorder, driver)
}

fn text(body: &serde_json::Value) -> SocketMessage {
    SocketMessage::Text {
        text: body.to_string(),
    }
}

#[test]
fn terminal_errors_keep_their_kind_and_only_lost_credentials_ask_to_sign_in() {
    use core::TerminalError as E;
    let reason = || "why".to_owned();
    for (error, kind, sign_in) in [
        (E::NotConnected, TerminalErrorKind::NotConnected, true),
        (
            E::InvalidIdentifier { value: reason() },
            TerminalErrorKind::InvalidIdentifier,
            false,
        ),
        (
            E::InvalidRequest { detail: reason() },
            TerminalErrorKind::InvalidRequest,
            false,
        ),
        (
            E::Unauthorized { reason: reason() },
            TerminalErrorKind::Unauthorized,
            true,
        ),
        (
            E::Forbidden { reason: reason() },
            TerminalErrorKind::Forbidden,
            false,
        ),
        (
            E::NotFound { reason: reason() },
            TerminalErrorKind::NotFound,
            false,
        ),
        (
            E::RunnerUnavailable {
                status: 503,
                reason: reason(),
            },
            TerminalErrorKind::RunnerUnavailable,
            false,
        ),
        (
            E::Rejected {
                status: 422,
                message: reason(),
            },
            TerminalErrorKind::Rejected,
            false,
        ),
        (
            E::Redirected { status: 302 },
            TerminalErrorKind::Redirected,
            false,
        ),
        (
            E::HttpStatus {
                status: 500,
                reason: reason(),
            },
            TerminalErrorKind::HttpStatus,
            false,
        ),
        (
            E::Transport(omnigent_core::http::TransportError::Cancelled),
            TerminalErrorKind::Transport,
            false,
        ),
        (
            E::MalformedResponse { detail: reason() },
            TerminalErrorKind::MalformedResponse,
            false,
        ),
    ] {
        let message = error.to_string();
        assert_eq!(
            terminal_error(error),
            CoreError::Terminal {
                kind,
                requires_sign_in: sign_in,
                message,
            }
        );
    }
}

#[test]
fn every_status_harness_view_and_attach_state_converts() {
    for (status, expected) in [
        (core::TerminalStatus::Active, TerminalStatus::Active),
        (core::TerminalStatus::Idle, TerminalStatus::Idle),
        (core::TerminalStatus::Exited, TerminalStatus::Exited),
        (core::TerminalStatus::Unknown, TerminalStatus::Unknown),
    ] {
        assert_eq!(TerminalStatus::from(status), expected);
    }
    assert_eq!(
        HarnessTerminal::from(core::HarnessTerminal::NotTerminalFirst),
        HarnessTerminal::NotTerminalFirst
    );
    assert_eq!(
        HarnessTerminal::from(core::HarnessTerminal::Unavailable),
        HarnessTerminal::Unavailable
    );

    let lost = LinkError::Connection(CoreFailure::Transport(
        omnigent_core::http::TransportError::Cancelled,
    ));
    assert_eq!(
        TerminalAttachState::from(core::AttachState::Idle),
        TerminalAttachState::Idle
    );
    assert_eq!(
        TerminalAttachState::from(core::AttachState::Stopped),
        TerminalAttachState::Stopped
    );
    assert!(matches!(
        TerminalAttachState::from(core::AttachState::Reconnecting {
            reason: lost.clone(),
            failures: 2,
            delay_ms: 500,
        }),
        TerminalAttachState::Reconnecting {
            failures: 2,
            delay_ms: 500,
            ..
        }
    ));
    for (reason, expected) in [
        (
            core::ClosedReason::Detached { reason: "d".into() },
            TerminalClosedReason::Detached { reason: "d".into() },
        ),
        (
            core::ClosedReason::ServerClosed {
                code: 4000,
                reason: "s".into(),
            },
            TerminalClosedReason::ServerClosed {
                code: 4000,
                reason: "s".into(),
            },
        ),
    ] {
        assert_eq!(
            TerminalAttachState::from(core::AttachState::Closed { reason }),
            TerminalAttachState::Closed { reason: expected }
        );
    }
    let failed = |error: core::AttachFailure| {
        let sign_in = error.requires_sign_in();
        let TerminalAttachState::Failed {
            failure,
            requires_sign_in,
            message,
        } = TerminalAttachState::from(core::AttachState::Failed { error })
        else {
            panic!("not failed");
        };
        assert_eq!(requires_sign_in, sign_in);
        assert_ne!(message, "");
        failure
    };
    assert!(matches!(
        failed(core::AttachFailure::AuthenticationRequired { detail: "x".into() }),
        TerminalAttachFailure::AuthenticationRequired { .. }
    ));
    assert!(matches!(
        failed(core::AttachFailure::AccessDenied {
            detail: "x".into(),
            read_only: true,
        }),
        TerminalAttachFailure::AccessDenied {
            read_only: true,
            ..
        }
    ));
    assert!(matches!(
        failed(core::AttachFailure::ServerError { reason: "x".into() }),
        TerminalAttachFailure::ServerError { .. }
    ));
    assert_eq!(
        failed(core::AttachFailure::WrongReplica),
        TerminalAttachFailure::WrongReplica
    );
    assert!(matches!(
        failed(core::AttachFailure::ReconnectBudgetExhausted {
            last: lost.clone(),
            attempts: 9,
        }),
        TerminalAttachFailure::ReconnectBudgetExhausted { attempts: 9, .. }
    ));
    assert!(matches!(
        failed(core::AttachFailure::Unrecoverable(lost)),
        TerminalAttachFailure::Unrecoverable { .. }
    ));
}

#[test]
fn who_may_type_follows_the_permission_and_terminal_first_follows_the_label() {
    assert!(terminal_can_type(None));
    assert!(terminal_can_type(Some(4)));
    assert!(!terminal_can_type(Some(1)));
    let labels = |value: &str| HashMap::from([("omnigent.ui".to_owned(), value.to_owned())]);
    assert!(is_terminal_first(labels("terminal")));
    assert!(!is_terminal_first(labels("chat")));
}

#[test]
fn a_read_only_attach_drops_input_and_says_why() {
    let (mut harness, recorder, driver) = attached(Some(1));
    let (request, _, socket) = harness.sockets.last();
    assert!(request.url.contains("read_only"), "{}", request.url);
    assert_eq!(
        recorder.last(),
        TerminalAttachState::Attached { read_only: true }
    );
    driver.send_input(b"rm -rf".to_vec());
    harness.pump();
    assert_eq!(
        crate::engine::lock(&recorder.dropped).as_slice(),
        &[(6, TerminalInputDropReason::ReadOnly)]
    );
    assert_eq!(crate::engine::lock(&socket.sent_binary).len(), 0);
}

#[test]
fn control_frames_reach_the_listener_and_bad_ones_become_notices() {
    let (mut harness, recorder, _driver) = attached(Some(4));
    let (_, sink, _) = harness.sockets.last();
    sink.message(text(&serde_json::json!({
        "type": "tmux-replies",
        "queries": ["da1"],
    })));
    sink.message(text(&serde_json::json!({
        "type": "clipboard-write",
        "encoding": "base64",
        "data": "aGVsbG8=",
    })));
    harness.pump();
    assert_eq!(
        crate::engine::lock(&recorder.clipboard).as_slice(),
        ["hello"]
    );
    assert_eq!(crate::engine::lock(&recorder.notices).len(), 0);

    sink.message(text(&serde_json::json!({
        "type": "clipboard-write",
        "encoding": "base64",
        "data": "/w==",
    })));
    sink.message(text(&serde_json::json!({"type": "from-the-future"})));
    sink.message(SocketMessage::Text {
        text: "not json".into(),
    });
    harness.pump();
    let notices = crate::engine::lock(&recorder.notices).clone();
    assert_eq!(notices.len(), 3, "{notices:?}");
    assert!(notices[0].contains("not UTF-8"), "{notices:?}");
    assert!(notices[1].contains("from-the-future"), "{notices:?}");
    assert!(notices[2].contains("unreadable"), "{notices:?}");
}

#[test]
fn a_socket_lost_mid_attach_reconnects_clears_the_screen_and_ignores_the_old_socket() {
    let (mut harness, recorder, driver) = attached(Some(4));
    let before = harness.sockets.count();
    let (_, old_sink, old_socket) = harness.sockets.last();
    old_sink.ended(SocketEnd::Failed {
        failure: ConnectionFailure::Offline {
            message: "gone".into(),
        },
    });
    harness.pump();
    assert!(matches!(
        recorder.last(),
        TerminalAttachState::Reconnecting { .. }
    ));
    // Input is never buffered for a later attach.
    driver.send_input(b"x".to_vec());
    harness.pump();
    assert_eq!(
        crate::engine::lock(&recorder.dropped).as_slice(),
        &[(1, TerminalInputDropReason::NotAttached)]
    );
    driver.foreground();
    harness.pump();
    assert_eq!(harness.sockets.count(), before + 1);
    let (_, new_sink, _) = harness.sockets.last();
    new_sink.opened();
    harness.pump();
    assert_eq!(recorder.resets.load(Ordering::SeqCst), 1);

    // The old socket's stragglers: its output, a second end, a second open.
    old_sink.message(SocketMessage::Binary {
        bytes: b"late".to_vec(),
    });
    old_sink.opened();
    old_sink.ended(SocketEnd::Failed {
        failure: ConnectionFailure::Cancelled,
    });
    harness.pump();
    assert_eq!(crate::engine::lock(&recorder.output).len(), 0);
    assert_eq!(
        recorder.last(),
        TerminalAttachState::Attached { read_only: false }
    );
    assert_eq!(crate::engine::lock(&old_socket.closes).len(), 0);
}

/// A terminal left attached for days through network changes must not keep a socket per drop.
#[test]
fn an_ended_socket_is_released_while_the_attach_goes_on() {
    let (mut harness, _recorder, driver) = attached(Some(4));
    let (_, sink, socket) = harness.sockets.last();
    let before = Arc::strong_count(&socket);
    sink.ended(SocketEnd::Failed {
        failure: ConnectionFailure::Offline {
            message: "gone".into(),
        },
    });
    harness.pump();
    assert!(
        Arc::strong_count(&socket) < before,
        "the loop and its writer task let go of the socket"
    );
    drop(driver);
    harness.pump();
}

#[test]
fn stopping_twice_timers_after_stop_and_a_late_socket_do_nothing() {
    let (mut harness, recorder, driver) = attached(Some(4));
    let (_, sink, socket) = harness.sockets.last();
    driver.stop();
    driver.stop();
    harness.pump();
    assert_eq!(crate::engine::lock(&socket.closes).len(), 1);
    assert_eq!(recorder.last(), TerminalAttachState::Stopped);
    let states = crate::engine::lock(&recorder.states).len();
    sink.message(SocketMessage::Binary {
        bytes: b"late".to_vec(),
    });
    sink.ended(SocketEnd::Failed {
        failure: ConnectionFailure::Cancelled,
    });
    harness.pump();
    harness.advance(120_000);
    assert_eq!(crate::engine::lock(&recorder.states).len(), states);
    assert_eq!(crate::engine::lock(&recorder.output).len(), 0);
}

#[test]
fn a_reconnect_timer_pending_at_drop_never_dials() {
    let (mut harness, _recorder, driver) = attached(Some(4));
    let before = harness.sockets.count();
    let (_, sink, _) = harness.sockets.last();
    sink.ended(SocketEnd::Failed {
        failure: ConnectionFailure::Offline {
            message: "gone".into(),
        },
    });
    harness.pump();
    assert!(harness.scheduler.pending_timers() > 0);
    assert_eq!(format!("{driver:?}"), "TerminalAttachDriver");
    drop(driver);
    harness.pump();
    harness.advance(120_000);
    assert_eq!(harness.sockets.count(), before);
}

#[test]
fn a_socket_that_cannot_open_or_write_reconnects() {
    let mut harness = connected();
    let recorder = Arc::new(Recorder::default());
    let driver = harness.core.terminal_attach(
        "conv_a".into(),
        "terminal_codex_main".into(),
        Some(4),
        None,
        recorder.clone(),
    );
    *crate::engine::lock(&harness.sockets.refuse) = Some(TransportError::Offline {
        message: "no route".into(),
    });
    let before = harness.sockets.count();
    driver.start();
    harness.pump();
    assert_eq!(harness.sockets.count(), before);
    assert!(matches!(
        recorder.last(),
        TerminalAttachState::Reconnecting { .. }
    ));

    driver.foreground();
    harness.pump();
    let (_, sink, socket) = harness.sockets.last();
    sink.opened();
    harness.pump();
    *crate::engine::lock(&socket.send_failure) = Some(TransportError::Offline {
        message: "broken pipe".into(),
    });
    driver.send_input(b"x".to_vec());
    driver.send_input(b"y".to_vec());
    harness.pump();
    assert!(matches!(
        recorder.last(),
        TerminalAttachState::Reconnecting { .. }
    ));
    assert_eq!(crate::engine::lock(&socket.closes).len(), 1);
}

#[test]
fn identifiers_that_cannot_address_a_terminal_fail_before_the_socket() {
    let mut harness = connected();
    let recorder = Arc::new(Recorder::default());
    let before = harness.sockets.count();
    let driver = harness.core.terminal_attach(
        "conv_a".into(),
        "not a terminal id!".into(),
        Some(4),
        None,
        recorder.clone(),
    );
    driver.start();
    harness.pump();
    assert_eq!(harness.sockets.count(), before);
    assert_ne!(crate::engine::lock(&recorder.states).len(), 0);
}

#[test]
fn the_demo_has_no_terminals() {
    let mut harness = Harness::demo();
    let recorder = Arc::new(Recorder::default());
    let driver = harness.core.terminal_attach(
        "demo-design".into(),
        "terminal_main".into(),
        None,
        None,
        recorder.clone(),
    );
    driver.start();
    harness.pump();
    let states = crate::engine::lock(&recorder.states).clone();
    assert!(
        states
            .iter()
            .any(|state| !matches!(state, TerminalAttachState::Connecting)),
        "{states:?}"
    );
}

#[test]
fn rest_calls_report_their_typed_errors_and_publish_to_an_open_session() {
    let mut harness = connected();
    let list = "/v1/sessions/conv_a/resources/terminals";
    let delete = "/v1/sessions/conv_a/resources/terminals/terminal_main";
    harness.http.route(list, json(403, r#"{"detail":"no"}"#));
    let core = Arc::clone(&harness.core);
    let error = harness
        .run(async move { core.list_terminals("conv_a".into()).await })
        .unwrap_err();
    assert!(
        matches!(
            error,
            CoreError::Terminal {
                kind: TerminalErrorKind::Forbidden,
                ..
            }
        ),
        "{error:?}"
    );

    harness.http.route_method(
        "POST",
        list,
        json(
            200,
            r#"{"id":"terminal_main","type":"terminal","metadata":{"running":true}}"#,
        ),
    );
    let core = Arc::clone(&harness.core);
    let created = harness
        .run(async move { core.create_terminal("conv_a".into(), "zsh".into()).await })
        .unwrap();
    assert_eq!(created.id, "terminal_main");

    harness
        .http
        .route_method("DELETE", delete, json(200, r#"{"id":"terminal_main"}"#));
    let core = Arc::clone(&harness.core);
    assert!(
        harness
            .run(async move {
                core.delete_terminal("conv_a".into(), "terminal_main".into())
                    .await
            })
            .unwrap()
    );
    harness
        .http
        .route_method("DELETE", delete, json(404, r#"{"detail":"gone"}"#));
    let core = Arc::clone(&harness.core);
    assert!(
        !harness
            .run(async move {
                core.delete_terminal("conv_a".into(), "terminal_main".into())
                    .await
            })
            .unwrap()
    );

    harness
        .http
        .route_method("DELETE", delete, json(500, r#"{"detail":"boom"}"#));
    let core = Arc::clone(&harness.core);
    assert!(
        harness
            .run(async move {
                core.delete_terminal("conv_a".into(), "terminal_main".into())
                    .await
            })
            .is_err()
    );
    harness
        .http
        .route_method("POST", list, json(500, r#"{"detail":"boom"}"#));
    let core = Arc::clone(&harness.core);
    assert!(
        harness
            .run(async move { core.create_terminal("conv_a".into(), "zsh".into()).await })
            .is_err()
    );
}

#[test]
fn creating_a_terminal_needs_entropy() {
    let mut harness = connected();
    harness.entropy.failing.store(true, Ordering::SeqCst);
    let core = Arc::clone(&harness.core);
    let error = harness
        .run(async move { core.create_terminal("conv_a".into(), "zsh".into()).await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Entropy { .. }), "{error:?}");
}

#[test]
fn declared_names_report_a_failed_read() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions/conv_a/agent",
        json(200, r#"{"terminal_names":["zsh","bash"]}"#),
    );
    let core = Arc::clone(&harness.core);
    let result = harness.run(async move { core.declared_terminal_names("conv_a".into()).await });
    assert!(result.is_ok(), "{result:?}");
    harness
        .http
        .route("/v1/sessions/conv_a/agent", json(500, r#"{"detail":"x"}"#));
    let core = Arc::clone(&harness.core);
    assert!(matches!(
        harness.run(async move { core.declared_terminal_names("conv_a".into()).await }),
        Err(CoreError::Session { .. })
    ));
}

#[test]
fn a_background_refresh_reports_its_failure_on_the_session() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions/conv_a/resources/terminals",
        json(500, r#"{"detail":"boom"}"#),
    );
    harness.events.take();
    harness.core.refresh_terminals("conv_a".into());
    harness.pump();
    let events = harness.events.take();
    assert!(
        events.iter().any(|event| matches!(
            event,
            CoreEvent::Error {
                scope: ErrorScope::Session { session_id },
                error: CoreError::Terminal { .. },
            } if session_id == "conv_a"
        )),
        "{events:#?}"
    );

    // Disconnected, and in the demo, nothing is read.
    let before = harness
        .http
        .count("/v1/sessions/conv_a/resources/terminals");
    harness.core.disconnect();
    harness.pump();
    harness.core.refresh_terminals("conv_a".into());
    harness.pump();
    assert_eq!(
        harness
            .http
            .count("/v1/sessions/conv_a/resources/terminals"),
        before
    );
}

const TERMINALS: &str = "/v1/sessions/conv_a/resources/terminals";
const TERMINAL_MAIN: &str =
    r#"{"id":"terminal_main","type":"terminal","metadata":{"running":true}}"#;

/// A connected harness with `conv_a` open and hydrated, and its stream's sink.
fn opened_session() -> (Harness, Arc<crate::host::ByteSink>) {
    let mut harness = connected();
    harness.writable_session("conv_a");
    harness.http.route(
        TERMINALS,
        json(
            200,
            &format!(r#"{{"object":"list","data":[{TERMINAL_MAIN}],"has_more":false}}"#),
        ),
    );
    harness.core.open_session("conv_a".into());
    harness.pump();
    let (sink, _, _) = harness.streams.last();
    sink.response(
        200,
        vec![crate::http::HttpHeader {
            name: "Content-Type".into(),
            value: "text/event-stream".into(),
        }],
    );
    sink.chunk(b"event: session.heartbeat\ndata: {\"type\":\"session.heartbeat\"}\n\n".to_vec());
    harness.pump();
    (harness, sink)
}

fn stream_frame(body: &serde_json::Value) -> Vec<u8> {
    format!(
        "event: {}\ndata: {body}\n\n",
        body["type"].as_str().unwrap()
    )
    .into_bytes()
}

/// The badges of the last `TerminalsChanged` in `events`.
fn last_badges(events: &[CoreEvent]) -> Option<Vec<(String, TerminalStatus)>> {
    events.iter().rev().find_map(|event| match event {
        CoreEvent::TerminalsChanged { terminals, .. } => Some(
            terminals
                .iter()
                .map(|row| (row.terminal.id.clone(), row.status))
                .collect(),
        ),
        _ => None,
    })
}

#[test]
fn a_terminal_listed_created_or_deleted_reaches_the_open_session() {
    let (mut harness, _sink) = opened_session();
    harness.events.take();
    let core = Arc::clone(&harness.core);
    let listed = harness
        .run(async move { core.list_terminals("conv_a".into()).await })
        .unwrap();
    assert_eq!(listed[0].id, "terminal_main");
    assert_eq!(
        last_badges(&harness.events.take()),
        Some(vec![("terminal_main".to_owned(), TerminalStatus::Idle)])
    );

    let created = r#"{"id":"terminal_two","type":"terminal","metadata":{"running":true}}"#;
    harness
        .http
        .route_method("POST", TERMINALS, json(200, created));
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.create_terminal("conv_a".into(), "zsh".into()).await })
        .unwrap();
    let badges = last_badges(&harness.events.take()).unwrap();
    assert_eq!(badges.len(), 2, "{badges:?}");

    harness.http.route_method(
        "DELETE",
        &format!("{TERMINALS}/terminal_two"),
        json(200, r#"{"id":"terminal_two"}"#),
    );
    let core = Arc::clone(&harness.core);
    harness
        .run(async move {
            core.delete_terminal("conv_a".into(), "terminal_two".into())
                .await
        })
        .unwrap();
    assert_eq!(
        last_badges(&harness.events.take()),
        Some(vec![("terminal_main".to_owned(), TerminalStatus::Idle)])
    );
}

#[test]
fn a_terminal_event_that_cannot_be_read_is_reported_and_the_list_read_again() {
    let (mut harness, sink) = opened_session();
    harness.events.take();
    let reads = harness.http.count(TERMINALS);
    sink.chunk(stream_frame(&serde_json::json!({
        "type": "session.resource.created",
        "resource": {"type": "terminal"},
    })));
    harness.pump();
    let events = harness.events.take();
    assert!(
        events.iter().any(|event| matches!(
            event,
            CoreEvent::Error {
                scope: ErrorScope::Session { .. },
                error: CoreError::Sync { .. },
            }
        )),
        "{events:#?}"
    );
    assert_eq!(harness.http.count(TERMINALS), reads + 1);
}

#[test]
fn an_activity_badge_lapses_after_the_last_pulse_and_stops_with_the_session() {
    let (mut harness, sink) = opened_session();
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.list_terminals("conv_a".into()).await })
        .unwrap();
    let pulse = stream_frame(&serde_json::json!({
        "type": "session.terminal.activity",
        "terminal_id": "terminal_main",
    }));
    harness.events.take();
    sink.chunk(pulse.clone());
    harness.pump();
    assert_eq!(
        last_badges(&harness.events.take()),
        Some(vec![("terminal_main".to_owned(), TerminalStatus::Active)])
    );

    // A second pulse moves the deadline; the first one's timer must not end the badge.
    harness.advance(1_000);
    sink.chunk(pulse.clone());
    harness.pump();
    harness.events.take();
    harness.advance(1_000);
    assert_eq!(last_badges(&harness.events.take()), None);
    harness.advance(500);
    assert_eq!(
        last_badges(&harness.events.take()),
        Some(vec![("terminal_main".to_owned(), TerminalStatus::Idle)])
    );

    sink.chunk(pulse);
    harness.pump();
    harness.core.close_session("conv_a".into());
    harness.pump();
    harness.events.take();
    harness.advance(10_000);
    assert_eq!(last_badges(&harness.events.take()), None);
}

#[test]
fn the_reconnect_timer_dials_the_next_socket() {
    let (mut harness, recorder, _driver) = attached(Some(4));
    let before = harness.sockets.count();
    let (_, sink, _) = harness.sockets.last();
    sink.ended(SocketEnd::Failed {
        failure: ConnectionFailure::Offline {
            message: "gone".into(),
        },
    });
    harness.pump();
    assert!(matches!(
        recorder.last(),
        TerminalAttachState::Reconnecting { .. }
    ));
    harness.advance(120_000);
    assert_eq!(harness.sockets.count(), before + 1);
}

/// A loop nothing runs yet, over `harness`'s fakes.
fn idle_loop(
    harness: &Harness,
    listener: Arc<Recorder>,
) -> (AttachLoop, UnboundedReceiver<AttachMsg>) {
    let (tx, rx) = mpsc::unbounded();
    let attach = AttachLoop {
        machine: core::TerminalAttach::new(
            core::AttachConfig::default(),
            core::attach_options(Some(4), None),
            SplitMix64::new(1),
        ),
        sessions: Arc::clone(&harness.core.inner.sessions),
        host: harness.core.inner.host.clone(),
        transport: Some(harness.sockets.clone()),
        listener,
        session_id: "conv_a".into(),
        terminal_id: "terminal_main".into(),
        tx,
        sockets: HashMap::new(),
        timers: HashMap::new(),
    };
    (attach, rx)
}

#[test]
fn a_clipboard_write_that_is_not_text_becomes_a_notice() {
    let harness = connected();
    let recorder = Arc::new(Recorder::default());
    let (mut attach, _queue) = idle_loop(&harness, recorder.clone());
    attach.output(core::AttachOutput::ClipboardWrite { data: vec![0xff] });
    assert_eq!(crate::engine::lock(&recorder.clipboard).len(), 0);
    let notices = crate::engine::lock(&recorder.notices).clone();
    assert!(notices[0].contains("not UTF-8"), "{notices:?}");
}

#[test]
fn shutting_down_stops_a_timer_the_machine_left_behind() {
    let harness = connected();
    let (mut attach, queue) = idle_loop(&harness, Arc::new(Recorder::default()));
    let (timer, _registration) = AbortHandle::new_pair();
    attach.timers.insert(99, timer.clone());
    attach.tx.unbounded_send(AttachMsg::Shutdown).unwrap();
    futures::executor::block_on(attach.run(queue));
    assert!(timer.is_aborted());
}
