//! Driver tests of the remote browser surface: the real core over fake host traits, fed the
//! shared protocol fixtures.

#![allow(
    clippy::too_many_lines,
    reason = "each test walks one user journey end to end"
)]

use std::sync::{Arc, Mutex};

use crate::connection::UrlPolicy;
use crate::engine::lock;
use crate::errors::CoreError;
use crate::events::ConnectionPhase;
use crate::host::{SocketEnd, SocketMessage};
use crate::remote_browser::{
    ControlHolder, KeyInput, KeyKind, MouseButton, MouseInput, MouseKind,
    RemoteBrowserClosedReason, RemoteBrowserConnection, RemoteBrowserErrorKind,
    RemoteBrowserListener, RemoteBrowserMode, RemoteBrowserNotice, RemoteBrowserSnapshot,
    RemoteEditOp, RemoteMobileEmulation, RemoteTabClosedReason, RemoteViewport,
    RemoteViewportRequest, RemoteViewportScope, StillImage, TouchInput, TouchKind, VideoFrame,
    remote_viewport_mobile,
};
use crate::test_support::{Harness, json};

fn fixture_bytes(path: &str) -> Vec<u8> {
    let full = format!(
        "{}/../../fixtures/remote_browser/{path}",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read(&full).unwrap_or_else(|error| panic!("reading {full}: {error}"))
}

fn message(path: &str) -> SocketMessage {
    let bytes = fixture_bytes(&format!("messages/host_to_client/{path}.json"));
    let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    SocketMessage::Text {
        text: value.to_string(),
    }
}

fn binary(name: &str) -> SocketMessage {
    SocketMessage::Binary {
        bytes: fixture_bytes(&format!("binary_frames/{name}.bin")),
    }
}

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

#[derive(Default)]
struct Recorder {
    states: Mutex<Vec<RemoteBrowserSnapshot>>,
    video: Mutex<Vec<VideoFrame>>,
    stills: Mutex<Vec<StillImage>>,
    closed: Mutex<Vec<Option<RemoteTabClosedReason>>>,
    notices: Mutex<Vec<String>>,
    user_notices: Mutex<Vec<String>>,
    clipboard: Mutex<Vec<(RemoteEditOp, String)>>,
}

impl RemoteBrowserListener for Recorder {
    fn on_state(&self, snapshot: RemoteBrowserSnapshot) {
        lock(&self.states).push(snapshot);
    }
    fn on_video(&self, frame: VideoFrame) {
        lock(&self.video).push(frame);
    }
    fn on_still(&self, still: StillImage) {
        lock(&self.stills).push(still);
    }
    fn on_closed(&self, reason: Option<RemoteTabClosedReason>) {
        lock(&self.closed).push(reason);
    }
    fn on_notice(&self, notice: RemoteBrowserNotice) {
        lock(&self.notices).push(notice.message.clone());
        if notice.user_facing {
            lock(&self.user_notices).push(notice.message);
        }
    }
    fn on_clipboard(&self, op: RemoteEditOp, text: String) {
        lock(&self.clipboard).push((op, text));
    }
}

impl Recorder {
    fn last(&self) -> RemoteBrowserSnapshot {
        lock(&self.states).last().cloned().expect("a snapshot")
    }
}

fn mouse(kind: MouseKind) -> MouseInput {
    MouseInput {
        kind,
        x: 640.0,
        y: 400.0,
        button: Some(MouseButton::Left),
        clicks: 1,
        modifiers: 0,
        dx: 0.0,
        dy: 0.0,
    }
}

#[test]
fn an_attach_streams_video_takes_control_and_ends_with_the_tab() {
    let mut harness = connected();
    let recorder = Arc::new(Recorder::default());
    let driver = harness.core.remote_browser_attach(
        "conv_a".into(),
        "btab_7f3a9c2e".into(),
        RemoteBrowserMode::Control,
        Some("host_1".into()),
        recorder.clone(),
    );
    driver.start();
    harness.pump();
    let (request, sink, socket) = harness.sockets.last();
    assert!(
        request.url.starts_with(
            "ws://127.0.0.1:6767/v1/sessions/conv_a/resources/browsers/btab_7f3a9c2e/attach?mode=control&v=1"
        ),
        "{}",
        request.url
    );
    assert!(request.url.contains("omnigent_slice_key=host_1"));
    sink.opened();
    harness.pump();
    assert!(lock(&socket.sent)[0].contains(r#""type":"hello""#));
    sink.message(message("hello"));
    sink.message(message("nav"));
    sink.message(binary("h264_idr"));
    sink.message(binary("h264_delta"));
    sink.message(binary("jpeg_thumbnail"));
    harness.pump();
    let snapshot = recorder.last();
    assert_eq!(
        snapshot.connection,
        RemoteBrowserConnection::Attached {
            mode: RemoteBrowserMode::Control
        }
    );
    assert_eq!(snapshot.nav.unwrap().title, "Sign in to GitHub");
    assert_eq!(
        snapshot.viewport,
        Some(RemoteViewport {
            width: 1280,
            height: 800,
            dpr: 1.0
        })
    );
    {
        let video = lock(&recorder.video).clone();
        assert_eq!(video.len(), 2);
        assert!(video[0].keyframe && video[0].format_changed && video[0].params.is_some());
        assert!(!video[1].keyframe);
    }
    assert_eq!(lock(&recorder.stills).len(), 1);
    let acks: Vec<String> = lock(&socket.sent)
        .iter()
        .filter(|frame| frame.contains(r#""type":"ack""#))
        .cloned()
        .collect();
    assert_eq!(acks.len(), 3, "{acks:?}");

    driver.mouse(mouse(MouseKind::Down)).unwrap();
    harness.pump();
    assert!(
        lock(&recorder.notices)
            .iter()
            .any(|notice| notice.contains("take control first")),
        "{:?}",
        lock(&recorder.notices)
    );
    driver.take_control();
    harness.pump();
    sink.message(message("control_user_this"));
    harness.pump();
    assert_eq!(recorder.last().control.unwrap().holder, ControlHolder::This);
    driver.mouse(mouse(MouseKind::Down)).unwrap();
    driver
        .key(KeyInput {
            kind: KeyKind::RawKeyDown,
            mac_key_code: Some(0x7E),
            hid_usage: None,
            code: None,
            key: "\u{F700}".into(),
            text: None,
            modifiers: 0,
            repeat: false,
        })
        .unwrap();
    harness.pump();
    let sent = lock(&socket.sent).clone();
    assert!(sent.iter().any(|frame| frame.contains(r#""op":"take""#)));
    assert!(sent.iter().any(|frame| frame.contains(r#""type":"mouse""#)));
    assert!(
        sent.iter()
            .any(|frame| frame.contains(r#""code":"ArrowUp""#)
                && frame.contains(r#""key":"ArrowUp""#)),
        "{sent:?}"
    );

    let rejected = driver.mouse(MouseInput {
        button: None,
        ..mouse(MouseKind::Up)
    });
    assert!(matches!(
        rejected,
        Err(CoreError::RemoteBrowser {
            kind: RemoteBrowserErrorKind::InvalidInput,
            ..
        })
    ));
    assert!(
        driver
            .resize(RemoteViewport {
                width: 10,
                height: 10,
                dpr: 1.0
            })
            .is_err()
    );

    sink.message(message("tab_closed"));
    sink.ended(SocketEnd::Closed {
        code: 4404,
        reason: "tab closed".into(),
    });
    harness.pump();
    assert!(matches!(
        recorder.last().connection,
        RemoteBrowserConnection::Closed {
            reason: RemoteBrowserClosedReason::TabEnded {
                reason: Some(RemoteTabClosedReason::Crashed),
                ..
            }
        }
    ));
    assert_eq!(
        lock(&recorder.closed).as_slice(),
        &[Some(RemoteTabClosedReason::Crashed)]
    );
}

#[test]
fn rest_calls_decode_tabs_and_typed_errors() {
    let mut harness = connected();
    let list = String::from_utf8(fixture_bytes("rest/list.json")).unwrap();
    let list: serde_json::Value = serde_json::from_str(&list).unwrap();
    harness.http.route(
        "/v1/sessions/conv_a/resources/browsers",
        json(200, &list["body"].to_string()),
    );
    let core = Arc::clone(&harness.core);
    let tabs = harness
        .run(async move { core.list_remote_browsers("conv_a".into()).await })
        .unwrap();
    assert_eq!(tabs.len(), 2);
    assert!(tabs[0].needs_attention);
    let unavailable = String::from_utf8(fixture_bytes("rest/create_unavailable.json")).unwrap();
    let unavailable: serde_json::Value = serde_json::from_str(&unavailable).unwrap();
    harness.http.route_method(
        "POST",
        "/v1/sessions/conv_a/resources/browsers",
        json(503, &unavailable["body"].to_string()),
    );
    let core = Arc::clone(&harness.core);
    let error = harness
        .run(async move {
            core.create_remote_browser("conv_a".into(), None, Some("default".into()))
                .await
        })
        .unwrap_err();
    assert!(
        matches!(
            error,
            CoreError::RemoteBrowser {
                kind: RemoteBrowserErrorKind::BrowserUnavailable,
                ..
            }
        ),
        "{error:?}"
    );
    let core = Arc::clone(&harness.core);
    let invalid = harness
        .run(async move {
            core.create_remote_browser("conv_a".into(), None, Some("Bad Name".into()))
                .await
        })
        .unwrap_err();
    assert!(matches!(
        invalid,
        CoreError::RemoteBrowser {
            kind: RemoteBrowserErrorKind::InvalidProfile,
            ..
        }
    ));
}

#[test]
fn a_v1_1_attach_sizes_the_viewport_edits_and_reports_scroll_and_selection() {
    let mut harness = connected();
    let recorder = Arc::new(Recorder::default());
    let driver = harness.core.remote_browser_attach(
        "conv_a".into(),
        "btab_7f3a9c2e".into(),
        RemoteBrowserMode::Control,
        None,
        recorder.clone(),
    );
    let phone = remote_viewport_mobile(390.0, 664.0, 3.0).unwrap();
    driver
        .set_viewport(Some(RemoteViewportRequest {
            viewport: phone,
            mobile: RemoteMobileEmulation::Layout,
        }))
        .unwrap();
    assert!(
        driver
            .set_viewport(Some(RemoteViewportRequest {
                viewport: RemoteViewport {
                    width: 10,
                    height: 10,
                    dpr: 1.0
                },
                mobile: RemoteMobileEmulation::Off,
            }))
            .is_err()
    );
    assert!(driver.edit(RemoteEditOp::Paste, None).is_err());
    driver.start();
    harness.pump();
    let (_, sink, socket) = harness.sockets.last();
    sink.opened();
    harness.pump();
    assert!(lock(&socket.sent)[0].contains(r#""features":["selection","scroll_metrics"]"#));
    sink.message(message("hello_v1_1"));
    harness.pump();
    let capabilities = recorder.last().capabilities;
    assert!(capabilities.edit && capabilities.viewport_scope && capabilities.touch);
    driver.take_control();
    harness.pump();
    sink.message(message("control_user_this"));
    harness.pump();
    let resize = lock(&socket.sent)
        .iter()
        .find(|frame| frame.contains(r#""type":"resize""#))
        .cloned()
        .expect("the wanted viewport goes out on gaining control");
    assert!(resize.contains(r#""scope":"control""#) && resize.contains(r#""mobile":"layout""#));
    sink.message(message("viewport_control_v1_1"));
    sink.message(message("scroll_v1_1"));
    sink.message(message("selection_v1_1"));
    harness.pump();
    let snapshot = recorder.last();
    assert_eq!(snapshot.viewport_scope, RemoteViewportScope::Control);
    assert_eq!(snapshot.mobile, RemoteMobileEmulation::Layout);
    assert_eq!(snapshot.agent_viewport.unwrap().width, 1280);
    assert!((snapshot.scroll.unwrap().y - 1240.5).abs() < f64::EPSILON);
    assert_eq!(snapshot.selection.unwrap().length, 11);

    driver.edit(RemoteEditOp::Copy, None).unwrap();
    driver
        .touch(TouchInput {
            kind: TouchKind::Start,
            id: 1,
            x: 10.0,
            y: 10.0,
            radius: None,
            pressure: Some(0.5),
            modifiers: 0,
        })
        .unwrap();
    harness.pump();
    let sent = lock(&socket.sent).clone();
    assert!(sent.iter().any(|frame| frame.contains(r#""type":"edit""#)));
    assert!(sent.iter().any(|frame| frame.contains(r#""type":"touch""#)));
    sink.message(message("clipboard_v1_1"));
    harness.pump();
    let clipboard = lock(&recorder.clipboard).clone();
    assert_eq!(clipboard.len(), 1);
    assert_eq!(clipboard[0].0, RemoteEditOp::Copy);
    assert!(clipboard[0].1.starts_with("hello "));
    // Internal host errors stay in the log; actionable ones reach the user in plain words.
    sink.message(SocketMessage::Text {
        text: r#"{"type":"error","code":"internal","message":"encoder: x264 ignored a qpfile IDR request","fatal":false}"#.into(),
    });
    sink.message(SocketMessage::Text {
        text: r#"{"type":"error","code":"unsupported","message":"file uploads are not supported yet","fatal":false}"#.into(),
    });
    harness.pump();
    assert_eq!(
        lock(&recorder.user_notices).clone(),
        ["File uploads are not supported yet."]
    );
    assert!(
        lock(&recorder.notices)
            .iter()
            .any(|notice| notice.contains("qpfile"))
    );
    driver.stop();
    harness.pump();
}

/// An attach that has said hello, holding control when `control` is set.
fn attached(
    mode: RemoteBrowserMode,
    hello: &str,
    control: bool,
) -> (
    Harness,
    Arc<Recorder>,
    Arc<crate::remote_browser::RemoteBrowserDriver>,
) {
    let mut harness = connected();
    let recorder = Arc::new(Recorder::default());
    let driver = harness.core.remote_browser_attach(
        "conv_a".into(),
        "btab_7f3a9c2e".into(),
        mode,
        None,
        recorder.clone(),
    );
    driver.start();
    harness.pump();
    let (_, sink, _) = harness.sockets.last();
    sink.opened();
    sink.message(message(hello));
    harness.pump();
    if control {
        driver.take_control();
        harness.pump();
        sink.message(message("control_user_this"));
        harness.pump();
    }
    (harness, recorder, driver)
}

fn host_text(body: &serde_json::Value) -> SocketMessage {
    SocketMessage::Text {
        text: body.to_string(),
    }
}

#[test]
fn every_browser_error_keeps_its_kind_and_only_lost_credentials_ask_to_sign_in() {
    use omnigent_core::remote_browser::RemoteBrowserError as E;
    let reason = || "why".to_owned();
    for (error, kind, sign_in) in [
        (
            E::InvalidIdentifier { value: reason() },
            RemoteBrowserErrorKind::InvalidIdentifier,
            false,
        ),
        (
            E::InvalidProfile { name: reason() },
            RemoteBrowserErrorKind::InvalidProfile,
            false,
        ),
        (
            E::InvalidUrl { url: reason() },
            RemoteBrowserErrorKind::InvalidUrl,
            false,
        ),
        (
            E::InvalidRequest { detail: reason() },
            RemoteBrowserErrorKind::InvalidRequest,
            false,
        ),
        (E::NotConnected, RemoteBrowserErrorKind::NotConnected, true),
        (
            E::Unauthorized { reason: reason() },
            RemoteBrowserErrorKind::Unauthorized,
            true,
        ),
        (
            E::Forbidden { reason: reason() },
            RemoteBrowserErrorKind::Forbidden,
            false,
        ),
        (
            E::NotFound { reason: reason() },
            RemoteBrowserErrorKind::NotFound,
            false,
        ),
        (
            E::BrowserUnavailable { reason: reason() },
            RemoteBrowserErrorKind::BrowserUnavailable,
            false,
        ),
        (
            E::RunnerUnavailable {
                status: 503,
                reason: reason(),
            },
            RemoteBrowserErrorKind::RunnerUnavailable,
            false,
        ),
        (
            E::Rejected {
                status: 422,
                message: reason(),
            },
            RemoteBrowserErrorKind::Rejected,
            false,
        ),
        (
            E::Redirected { status: 302 },
            RemoteBrowserErrorKind::Redirected,
            false,
        ),
        (
            E::HttpStatus {
                status: 500,
                reason: reason(),
            },
            RemoteBrowserErrorKind::HttpStatus,
            false,
        ),
        (
            E::Transport(omnigent_core::http::TransportError::Cancelled),
            RemoteBrowserErrorKind::Transport,
            false,
        ),
        (
            E::MalformedResponse { detail: reason() },
            RemoteBrowserErrorKind::MalformedResponse,
            false,
        ),
    ] {
        let message = error.to_string();
        assert_eq!(
            crate::remote_browser::remote_browser_error(error),
            CoreError::RemoteBrowser {
                kind,
                requires_sign_in: sign_in,
                message,
            }
        );
    }
}

#[test]
fn every_failure_a_host_can_show_converts() {
    use omnigent_core::realtime::{ConnectionFailure, LinkError};
    use omnigent_core::remote_browser::{AttachFailure as F, ClosedReason, ConnectionState as S};
    use omnigent_protocol::remote_browser::AttachMode;

    use crate::remote_browser::RemoteBrowserFailure as R;
    let lost = LinkError::Connection(ConnectionFailure::Transport(
        omnigent_core::http::TransportError::Cancelled,
    ));
    let failed = |error: F| {
        let sign_in = error.requires_sign_in();
        let RemoteBrowserConnection::Failed {
            failure,
            requires_sign_in,
            message,
        } = RemoteBrowserConnection::from(S::Failed { error })
        else {
            panic!("not failed");
        };
        assert_eq!(requires_sign_in, sign_in);
        assert_ne!(message, "");
        failure
    };
    assert!(matches!(
        failed(F::AuthenticationRequired { detail: "x".into() }),
        R::AuthenticationRequired { .. }
    ));
    assert_eq!(
        failed(F::AccessDenied {
            detail: "x".into(),
            mode: AttachMode::Control,
        }),
        R::AccessDenied {
            detail: "x".into(),
            mode: RemoteBrowserMode::Control,
        }
    );
    assert!(matches!(
        failed(F::ServerError { reason: "x".into() }),
        R::ServerError { .. }
    ));
    assert_eq!(failed(F::WrongReplica), R::WrongReplica);
    assert!(matches!(
        failed(F::ProtocolUnsupported { detail: "x".into() }),
        R::ProtocolUnsupported { .. }
    ));
    assert!(matches!(
        failed(F::ProtocolViolation {
            code: 4400,
            reason: "x".into(),
        }),
        R::ProtocolViolation { code: 4400, .. }
    ));
    assert!(matches!(
        failed(F::ReconnectBudgetExhausted {
            last: lost.clone(),
            attempts: 9,
        }),
        R::ReconnectBudgetExhausted { attempts: 9, .. }
    ));
    assert!(matches!(
        failed(F::Unrecoverable(lost.clone())),
        R::Unrecoverable { .. }
    ));
    assert_eq!(
        RemoteBrowserConnection::from(S::Idle),
        RemoteBrowserConnection::Idle
    );
    assert_eq!(
        RemoteBrowserConnection::from(S::Stopped),
        RemoteBrowserConnection::Stopped
    );
    assert!(matches!(
        RemoteBrowserConnection::from(S::Reconnecting {
            reason: lost,
            failures: 1,
            delay_ms: 2,
        }),
        RemoteBrowserConnection::Reconnecting {
            failures: 1,
            delay_ms: 2,
            ..
        }
    ));
    assert_eq!(
        RemoteBrowserConnection::from(S::Closed {
            reason: ClosedReason::ServerClosed {
                code: 4000,
                reason: "x".into(),
            },
        }),
        RemoteBrowserConnection::Closed {
            reason: RemoteBrowserClosedReason::ServerClosed {
                code: 4000,
                reason: "x".into(),
            },
        }
    );
    assert_eq!(
        crate::remote_browser::remote_browser_mode(Some(1)),
        RemoteBrowserMode::View
    );
    assert_eq!(
        crate::remote_browser::remote_browser_mode(None),
        RemoteBrowserMode::Control
    );
}

#[test]
fn host_state_messages_reach_the_snapshot() {
    use crate::remote_browser::{RemoteDialogKind, StreamCodec, StreamQuality, TextInputKind};
    let (mut harness, recorder, _driver) = attached(RemoteBrowserMode::Control, "hello", false);
    let (_, sink, _) = harness.sockets.last();
    for (mode, kind) in [
        ("none", TextInputKind::None),
        ("text", TextInputKind::Text),
        ("tel", TextInputKind::Tel),
        ("url", TextInputKind::Url),
        ("email", TextInputKind::Email),
        ("numeric", TextInputKind::Numeric),
        ("decimal", TextInputKind::Decimal),
        ("search", TextInputKind::Search),
        ("from-the-future", TextInputKind::Text),
    ] {
        sink.message(host_text(
            &serde_json::json!({"type": "text_input", "mode": mode}),
        ));
        harness.pump();
        assert_eq!(recorder.last().text_input.mode, kind, "{mode}");
    }
    sink.message(message("text_input"));
    harness.pump();
    let caret = recorder.last().text_input.caret.unwrap();
    assert!((caret.height - 18.0).abs() < f64::EPSILON);

    for (quality, ours) in [
        ("low", StreamQuality::Low),
        ("medium", StreamQuality::Medium),
        ("high", StreamQuality::High),
        ("from-the-future", StreamQuality::Medium),
    ] {
        sink.message(host_text(&serde_json::json!({
            "type": "settings",
            "max_fps": 30,
            "quality": quality,
            "scale": 1,
            "codec": "auto",
        })));
        harness.pump();
        assert_eq!(recorder.last().settings.unwrap().quality, ours, "{quality}");
    }
    for (codec, ours) in [
        ("auto", StreamCodec::Auto),
        ("h264", StreamCodec::H264),
        ("jpeg", StreamCodec::Jpeg),
        ("from-the-future", StreamCodec::Auto),
    ] {
        sink.message(host_text(&serde_json::json!({
            "type": "settings",
            "max_fps": 30,
            "quality": "low",
            "scale": 1,
            "codec": codec,
        })));
        harness.pump();
        assert_eq!(recorder.last().settings.unwrap().codec, ours, "{codec}");
    }

    sink.message(message("stats"));
    harness.pump();
    let stats = recorder.last().stats.unwrap();
    assert_eq!(stats.in_flight_frames, 1);
    assert_eq!(stats.in_flight_bytes, 18_234);
    assert!((stats.fps - 14.8).abs() < 1e-9);
    assert!((stats.kbps - 812.5).abs() < 1e-9);
    assert!((stats.encode_ms_p50 - 4.2).abs() < 1e-9);
    assert!((stats.encode_ms_p95 - 9.7).abs() < 1e-9);
    assert!((stats.host_cpu - 0.12).abs() < 1e-9);

    for (index, (kind, ours)) in [
        ("alert", RemoteDialogKind::Alert),
        ("confirm", RemoteDialogKind::Confirm),
        ("prompt", RemoteDialogKind::Prompt),
        ("beforeunload", RemoteDialogKind::BeforeUnload),
        ("file_chooser", RemoteDialogKind::FileChooser),
        (
            "from-the-future",
            RemoteDialogKind::Unknown {
                value: "from-the-future".into(),
            },
        ),
    ]
    .into_iter()
    .enumerate()
    {
        sink.message(host_text(&serde_json::json!({
            "type": "dialog",
            "id": format!("dlg_{index}"),
            "kind": kind,
            "message": "Sure?",
        })));
        harness.pump();
        assert_eq!(recorder.last().dialogs[index].kind, ours, "{kind}");
    }
}

#[test]
fn tab_close_reasons_and_owners_convert() {
    for (reason, ours) in [
        ("closed", RemoteTabClosedReason::Closed),
        ("crashed", RemoteTabClosedReason::Crashed),
        ("host_exit", RemoteTabClosedReason::HostExit),
        (
            "from-the-future",
            RemoteTabClosedReason::Unknown {
                value: "from-the-future".into(),
            },
        ),
    ] {
        let (mut harness, recorder, _driver) = attached(RemoteBrowserMode::Control, "hello", false);
        let (_, sink, _) = harness.sockets.last();
        sink.message(host_text(
            &serde_json::json!({"type": "tab_closed", "reason": reason}),
        ));
        sink.ended(SocketEnd::Closed {
            code: 4404,
            reason: "tab closed".into(),
        });
        harness.pump();
        assert_eq!(lock(&recorder.closed).as_slice(), &[Some(ours)], "{reason}");
    }
    let (mut harness, recorder, _driver) = attached(RemoteBrowserMode::Control, "hello", false);
    let (_, sink, _) = harness.sockets.last();
    sink.message(host_text(&serde_json::json!({
        "type": "control",
        "owner": "from-the-future",
        "holder": "from-the-future",
    })));
    harness.pump();
    let control = recorder.last().control.unwrap();
    assert_eq!(control.holder, ControlHolder::Other);
}

/// Everything a host could send that this client cannot use is a notice; the attach goes on.
#[test]
fn unusable_frames_become_log_notices_and_the_attach_goes_on() {
    let (mut harness, recorder, _driver) = attached(RemoteBrowserMode::Control, "hello", false);
    let (_, sink, socket) = harness.sockets.last();
    sink.message(message("unknown_type"));
    sink.message(SocketMessage::Text {
        text: "not json".into(),
    });
    sink.message(binary("invalid_bad_magic"));
    sink.message(binary("unknown_kind"));
    sink.message(binary("h264_delta"));
    sink.message(message("error_fatal"));
    harness.pump();
    let notices = lock(&recorder.notices).clone();
    for expected in [
        "ignored an unknown browser message",
        "unreadable browser message",
        "unreadable browser frame",
        "ignored an unknown browser frame kind",
        "waiting for a keyframe",
        "browser host error internal",
    ] {
        assert!(
            notices.iter().any(|notice| notice.contains(expected)),
            "{expected}: {notices:?}"
        );
    }
    assert_eq!(lock(&recorder.user_notices).len(), 0, "{notices:?}");
    assert!(
        lock(&socket.sent)
            .iter()
            .any(|frame| frame.contains("hello"))
    );
}

#[test]
fn a_custom_cursor_that_is_not_an_image_falls_back_and_is_logged() {
    let (mut harness, recorder, _driver) = attached(RemoteBrowserMode::Control, "hello", false);
    let (_, sink, _) = harness.sockets.last();
    sink.message(host_text(&serde_json::json!({
        "type": "cursor",
        "cursor": "custom",
        "custom": {"png_base64": "!!!", "hotspot_x": 0, "hotspot_y": 0, "scale": 1},
    })));
    harness.pump();
    assert_eq!(recorder.last().cursor.keyword, "default");
    assert!(
        lock(&recorder.notices)
            .iter()
            .any(|notice| notice.contains("not base64")),
        "{:?}",
        lock(&recorder.notices)
    );
    sink.message(message("cursor_custom"));
    harness.pump();
    assert_eq!(recorder.last().cursor.custom.unwrap().hotspot_x, 0.0);
}

#[test]
fn a_viewer_cannot_send_input_and_is_told_why() {
    let (mut harness, recorder, driver) =
        attached(RemoteBrowserMode::View, "hello_view_handoff", false);
    driver.mouse(mouse(MouseKind::Down)).unwrap();
    driver.take_control();
    harness.pump();
    assert!(
        lock(&recorder.user_notices)
            .iter()
            .any(|notice| notice == "This browser tab is view-only."),
        "{:?}",
        lock(&recorder.notices)
    );
}

#[test]
fn input_of_every_kind_reaches_a_controlling_attach() {
    use crate::remote_browser::{
        ImeInput, ImeOp, ImeRange, KeyframeReason, NavOp, RemoteBrowserSettingsUpdate, StillKind,
        StreamCodec, StreamQuality,
    };
    let (mut harness, _recorder, driver) = attached(RemoteBrowserMode::Control, "hello_v1_1", true);
    let (_, _, socket) = harness.sockets.last();
    for kind in [
        MouseKind::Move,
        MouseKind::Down,
        MouseKind::Up,
        MouseKind::Wheel,
        MouseKind::Leave,
    ] {
        driver.mouse(mouse(kind)).unwrap();
    }
    for button in [MouseButton::Middle, MouseButton::Right] {
        driver
            .mouse(MouseInput {
                button: Some(button),
                ..mouse(MouseKind::Down)
            })
            .unwrap();
    }
    let key = |kind| KeyInput {
        kind,
        mac_key_code: None,
        hid_usage: None,
        code: Some("KeyA".into()),
        key: "a".into(),
        text: Some("a".into()),
        modifiers: 0,
        repeat: false,
    };
    for kind in [KeyKind::RawKeyDown, KeyKind::KeyUp, KeyKind::Char] {
        driver.key(key(kind)).unwrap();
    }
    assert!(
        driver
            .key(KeyInput {
                modifiers: u32::MAX,
                ..key(KeyKind::Char)
            })
            .is_err()
    );
    for (op, text) in [
        (ImeOp::SetComposition, Some("か".to_owned())),
        (ImeOp::Commit, Some("か".to_owned())),
        (ImeOp::Finish, None),
        (ImeOp::Cancel, None),
    ] {
        driver
            .ime(ImeInput {
                op,
                text,
                selection: Some(ImeRange { start: 0, end: 1 }),
                replacement: None,
            })
            .unwrap();
    }
    assert!(
        driver
            .ime(ImeInput {
                op: ImeOp::Commit,
                text: None,
                selection: None,
                replacement: None,
            })
            .is_err()
    );
    for op in [NavOp::Back, NavOp::Forward, NavOp::Reload, NavOp::Stop] {
        driver.nav(op, None).unwrap();
    }
    driver
        .nav(NavOp::Navigate, Some("https://example.com".into()))
        .unwrap();
    assert!(
        driver
            .nav(NavOp::Navigate, Some("file:///etc".into()))
            .is_err()
    );
    let bad_viewport = RemoteViewport {
        width: 1,
        height: 1,
        dpr: 1.0,
    };
    assert!(driver.resize(bad_viewport).is_err());
    assert!(
        driver
            .set_viewport(Some(RemoteViewportRequest {
                viewport: bad_viewport,
                mobile: RemoteMobileEmulation::Off,
            }))
            .is_err()
    );
    driver.set_viewport(None).unwrap();
    for op in [
        RemoteEditOp::Copy,
        RemoteEditOp::Cut,
        RemoteEditOp::SelectAll,
        RemoteEditOp::Undo,
        RemoteEditOp::Redo,
        RemoteEditOp::Delete,
    ] {
        driver.edit(op, None).unwrap();
    }
    driver.edit(RemoteEditOp::Paste, Some("x".into())).unwrap();
    assert!(driver.edit(RemoteEditOp::Paste, None).is_err());
    for kind in [
        TouchKind::Start,
        TouchKind::Move,
        TouchKind::End,
        TouchKind::Cancel,
    ] {
        driver
            .touch(TouchInput {
                kind,
                id: 1,
                x: 1.0,
                y: 1.0,
                radius: Some(1.0),
                pressure: Some(0.5),
                modifiers: 0,
            })
            .unwrap();
    }
    assert!(
        driver
            .touch(TouchInput {
                kind: TouchKind::Start,
                id: 1,
                x: f64::NAN,
                y: 1.0,
                radius: Some(1.0),
                pressure: Some(0.5),
                modifiers: 0,
            })
            .is_err()
    );
    for reason in [
        KeyframeReason::DecoderError,
        KeyframeReason::Flush,
        KeyframeReason::Gap,
        KeyframeReason::User,
    ] {
        driver.request_keyframe(reason);
    }
    driver.request_still(StillKind::Still);
    driver.request_still(StillKind::Thumbnail);
    driver.set_visible(false);
    driver.set_visible(true);
    driver.foreground();
    driver.reply_dialog("dlg_1".into(), true, Some("Ada".into()));
    for (quality, codec) in [
        (StreamQuality::Low, StreamCodec::Auto),
        (StreamQuality::Medium, StreamCodec::H264),
        (StreamQuality::High, StreamCodec::Jpeg),
    ] {
        driver.update_settings(RemoteBrowserSettingsUpdate {
            max_fps: Some(30),
            quality: Some(quality),
            scale: Some(1.0),
            codec: Some(codec),
            stats: Some(true),
        });
    }
    driver.release_control();
    harness.pump();
    let sent = lock(&socket.sent).join("\n");
    for expected in [
        r#""button":"middle""#,
        r#""button":"right""#,
        r#""kind":"keyup""#,
        r#""op":"select_all""#,
        r#""op":"delete""#,
        r#""op":"stop""#,
        r#""quality":"high""#,
        r#""codec":"jpeg""#,
        r#""type":"dialog_reply""#,
    ] {
        assert!(sent.contains(expected), "{expected}: {sent}");
    }
}

#[test]
fn a_clipboard_answer_and_stills_reach_the_listener() {
    let (mut harness, recorder, _driver) = attached(RemoteBrowserMode::Control, "hello_v1_1", true);
    let (_, sink, _) = harness.sockets.last();
    sink.message(message("clipboard_v1_1"));
    sink.message(host_text(
        &serde_json::json!({"type": "clipboard", "op": "cut", "text": "gone"}),
    ));
    sink.message(binary("jpeg_still"));
    harness.pump();
    let clipboard = lock(&recorder.clipboard).clone();
    assert_eq!(clipboard.len(), 2, "{clipboard:?}");
    assert_eq!(clipboard[0].0, RemoteEditOp::Copy);
    assert_eq!(clipboard[1], (RemoteEditOp::Cut, "gone".to_owned()));
    let stills = lock(&recorder.stills).clone();
    assert_eq!(stills[0].kind, crate::remote_browser::StillKind::Still);
}

/// More frames than the queue holds before the decoder runs: the oldest go, a keyframe is asked for.
#[test]
fn a_burst_of_video_overflows_the_queue_and_asks_for_a_keyframe() {
    let (mut harness, recorder, _driver) = attached(RemoteBrowserMode::Control, "hello", false);
    let (_, sink, socket) = harness.sockets.last();
    sink.message(binary("h264_idr"));
    for _ in 0..16 {
        sink.message(binary("h264_delta"));
    }
    harness.pump();
    assert!(
        lock(&recorder.video).len() <= 5,
        "{}",
        lock(&recorder.video).len()
    );
    assert!(
        lock(&socket.sent)
            .iter()
            .any(|frame| frame.contains(r#""reason":"flush""#)),
        "{:?}",
        lock(&socket.sent)
    );
}

#[test]
fn a_socket_that_cannot_open_or_write_reconnects() {
    let mut harness = connected();
    let recorder = Arc::new(Recorder::default());
    let driver = harness.core.remote_browser_attach(
        "conv_a".into(),
        "btab_7f3a9c2e".into(),
        RemoteBrowserMode::Control,
        None,
        recorder.clone(),
    );
    *lock(&harness.sockets.refuse) = Some(crate::http::TransportError::Offline {
        message: "no route".into(),
    });
    driver.start();
    harness.pump();
    assert!(matches!(
        recorder.last().connection,
        RemoteBrowserConnection::Reconnecting { .. }
    ));
    driver.foreground();
    harness.pump();
    let (_, sink, socket) = harness.sockets.last();
    *lock(&socket.send_failure) = Some(crate::http::TransportError::Offline {
        message: "broken pipe".into(),
    });
    sink.opened();
    harness.pump();
    assert!(matches!(
        recorder.last().connection,
        RemoteBrowserConnection::Reconnecting { .. }
    ));
}

#[test]
fn an_id_that_cannot_address_a_tab_fails_before_the_socket() {
    let mut harness = connected();
    let recorder = Arc::new(Recorder::default());
    let before = harness.sockets.count();
    let driver = harness.core.remote_browser_attach(
        "conv_a".into(),
        "not a tab id!".into(),
        RemoteBrowserMode::Control,
        None,
        recorder.clone(),
    );
    driver.start();
    harness.pump();
    assert_eq!(harness.sockets.count(), before);
    assert_ne!(lock(&recorder.states).len(), 0);
}

#[test]
fn the_demo_has_no_remote_browsers() {
    let mut harness = Harness::demo();
    let recorder = Arc::new(Recorder::default());
    let driver = harness.core.remote_browser_attach(
        "demo-design".into(),
        "btab_1".into(),
        RemoteBrowserMode::Control,
        None,
        recorder.clone(),
    );
    driver.start();
    harness.pump();
    assert_ne!(lock(&recorder.states).len(), 0);
}

#[test]
fn deleting_tabs_and_listing_profiles_report_their_typed_errors() {
    let mut harness = connected();
    let tab = "/v1/sessions/conv_a/resources/browsers/btab_1";
    let profiles = "/v1/sessions/conv_a/resources/browser_profiles";
    harness.http.route_method(
        "DELETE",
        tab,
        json(200, r#"{"id":"btab_1","deleted":true}"#),
    );
    let core = Arc::clone(&harness.core);
    assert!(
        harness
            .run(async move {
                core.delete_remote_browser("conv_a".into(), "btab_1".into())
                    .await
            })
            .unwrap()
    );
    harness
        .http
        .route_method("DELETE", tab, json(404, r#"{"detail":"gone"}"#));
    let core = Arc::clone(&harness.core);
    assert!(
        !harness
            .run(async move {
                core.delete_remote_browser("conv_a".into(), "btab_1".into())
                    .await
            })
            .unwrap()
    );
    harness
        .http
        .route_method("DELETE", tab, json(500, r#"{"detail":"boom"}"#));
    let core = Arc::clone(&harness.core);
    assert!(matches!(
        harness.run(async move {
            core.delete_remote_browser("conv_a".into(), "btab_1".into())
                .await
        }),
        Err(CoreError::RemoteBrowser { .. })
    ));

    harness.http.route(
        profiles,
        json(200, r#"{"data":[{"name":"work","running":true}]}"#),
    );
    let core = Arc::clone(&harness.core);
    let listed = harness
        .run(async move { core.list_remote_browser_profiles("conv_a".into()).await })
        .unwrap();
    assert_eq!(listed[0].name, "work");
    assert_eq!(listed[0].running, Some(true));
    harness
        .http
        .route(profiles, json(500, r#"{"detail":"boom"}"#));
    let core = Arc::clone(&harness.core);
    assert!(matches!(
        harness.run(async move { core.list_remote_browser_profiles("conv_a".into()).await }),
        Err(CoreError::RemoteBrowser { .. })
    ));
}

#[test]
fn viewport_helpers_place_and_fit() {
    use crate::remote_browser::{
        dom_code_for_hid_usage, dom_code_for_mac_key_code, remote_viewport_fit,
        remote_viewport_placement,
    };
    let viewport = RemoteViewport {
        width: 1000,
        height: 500,
        dpr: 1.0,
    };
    let placed = remote_viewport_placement(viewport, 500.0, 500.0).unwrap();
    assert!((placed.width - 500.0).abs() < 1e-9);
    assert!((placed.height - 250.0).abs() < 1e-9);
    assert!((placed.y - 125.0).abs() < 1e-9);
    assert!((placed.x).abs() < 1e-9);
    assert!((placed.scale - 0.5).abs() < 1e-9);
    assert_eq!(remote_viewport_placement(viewport, 0.0, 0.0), None);
    assert!(remote_viewport_fit(1000.0, 800.0, true).is_some());
    assert_eq!(remote_viewport_fit(0.0, 0.0, true), None);
    assert_eq!(dom_code_for_mac_key_code(0x00).as_deref(), Some("KeyA"));
    assert_eq!(dom_code_for_mac_key_code(u16::MAX), None);
    assert_eq!(dom_code_for_hid_usage(0x04).as_deref(), Some("KeyA"));
    assert_eq!(dom_code_for_hid_usage(u32::MAX), None);
}
