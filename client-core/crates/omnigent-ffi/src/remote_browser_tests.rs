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
