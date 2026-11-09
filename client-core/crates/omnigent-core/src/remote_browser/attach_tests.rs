use omnigent_protocol::remote_browser::{
    ControlOp, KeyKind, MouseButton, NavOp, Quality, TextRange,
};

use super::super::input::InputError;

use super::*;
use crate::realtime::test_support::FixedJitter;
use crate::remote_browser::test_support::{fixture_bytes, fixture_json, message_text};

struct Harness {
    machine: RemoteBrowserAttach<FixedJitter>,
    now: u64,
}

fn options(mode: AttachMode, slice_key: Option<&str>) -> AttachOptions {
    AttachOptions {
        mode,
        slice_key: slice_key.map(str::to_owned),
    }
}

impl Harness {
    fn new(options: AttachOptions) -> Self {
        Self {
            machine: RemoteBrowserAttach::new(AttachConfig::default(), options, FixedJitter(0)),
            now: 1_000,
        }
    }

    fn control() -> Self {
        Self::new(options(AttachMode::Control, None))
    }

    fn run(&mut self, input: AttachInput) -> Vec<AttachOutput> {
        self.machine.handle(self.now, input)
    }

    fn attempt(&self) -> AttemptId {
        self.machine
            .current_attempt()
            .expect("an attempt in flight")
    }

    fn open(&mut self) -> Vec<AttachOutput> {
        let attempt = self.attempt();
        self.run(AttachInput::Opened { attempt })
    }

    fn recv(&mut self, message: SocketMessage) -> Vec<AttachOutput> {
        let attempt = self.attempt();
        self.run(AttachInput::Message { attempt, message })
    }

    fn host(&mut self, name: &str) -> Vec<AttachOutput> {
        self.recv(SocketMessage::Text(message_text(&format!(
            "host_to_client/{name}"
        ))))
    }

    fn frame(&mut self, name: &str) -> Vec<AttachOutput> {
        self.recv(SocketMessage::Binary(fixture_bytes(&format!(
            "binary_frames/{name}.bin"
        ))))
    }

    fn close(&mut self, code: u16, reason: &str) -> Vec<AttachOutput> {
        let attempt = self.attempt();
        self.run(AttachInput::Ended {
            attempt,
            end: SocketEnd::Closed {
                code,
                reason: reason.to_owned(),
            },
        })
    }

    /// Started, opened and past the host `hello` (`hello.json`: control mode, agent owns).
    fn attached() -> Self {
        let mut harness = Self::control();
        harness.run(AttachInput::Start);
        harness.open();
        harness.host("hello");
        harness
    }

    fn holding_control() -> Self {
        let mut harness = Self::attached();
        harness.run(AttachInput::TakeControl);
        harness.host("control_user_this");
        harness
    }

    fn fire(&mut self, outputs: &[AttachOutput], kind: TimerKind) -> Vec<AttachOutput> {
        let (token, delay) = timer(outputs, kind).expect("a timer");
        self.now += delay;
        self.run(AttachInput::TimerFired { token })
    }
}

fn timer(outputs: &[AttachOutput], kind: TimerKind) -> Option<(TimerToken, u64)> {
    outputs.iter().find_map(|output| match output {
        AttachOutput::ScheduleTimer { token, delay_ms } if token.kind == kind => {
            Some((*token, *delay_ms))
        }
        _ => None,
    })
}

fn state(outputs: &[AttachOutput]) -> Option<&ConnectionState> {
    outputs.iter().rev().find_map(|output| match output {
        AttachOutput::ConnectionChanged { state } => Some(state),
        _ => None,
    })
}

fn sent(outputs: &[AttachOutput]) -> Vec<ClientMessage> {
    outputs
        .iter()
        .filter_map(|output| match output {
            AttachOutput::Send {
                message: SocketMessage::Text(text),
                ..
            } => Some(ClientMessage::decode(text).unwrap()),
            _ => None,
        })
        .collect()
}

fn notices(outputs: &[AttachOutput]) -> Vec<&Notice> {
    outputs
        .iter()
        .filter_map(|output| match output {
            AttachOutput::Notice(notice) => Some(notice),
            _ => None,
        })
        .collect()
}

fn mouse(kind: MouseKind, x: f64) -> MouseEvent {
    let discrete = matches!(kind, MouseKind::Down | MouseKind::Up);
    MouseEvent {
        kind,
        x,
        y: 10.0,
        button: discrete.then_some(MouseButton::Left),
        clicks: discrete.then_some(1),
        modifiers: 0,
        dx: None,
        dy: None,
    }
}

fn key(kind: KeyKind) -> KeyEvent {
    let text = (kind == KeyKind::Char).then(|| "a".to_owned());
    KeyEvent {
        kind,
        code: "KeyA".into(),
        key: "a".into(),
        text,
        modifiers: 0,
        repeat: false,
    }
}

#[test]
fn setup_sends_hello_and_attaches_on_the_host_hello() {
    let mut harness = Harness::new(options(AttachMode::Control, Some("host_1")));
    let started = harness.run(AttachInput::Start);
    assert_eq!(state(&started), Some(&ConnectionState::Connecting));
    assert!(matches!(
        &started[1],
        AttachOutput::Connect { options, .. } if options.slice_key.as_deref() == Some("host_1")
    ));
    let opened = harness.open();
    let hello = sent(&opened);
    assert!(matches!(
        &hello[..],
        [ClientMessage::Hello(ClientHello {
            protocol: 1,
            mode: AttachMode::Control,
            visible: true,
            ..
        })]
    ));
    assert!(timer(&opened, TimerKind::Watchdog).is_some());
    assert!(timer(&opened, TimerKind::Ping).is_some());
    assert_eq!(state(&opened), None, "attached only after the host hello");
    let welcomed = harness.host("hello");
    assert_eq!(
        state(&welcomed),
        Some(&ConnectionState::Attached {
            mode: AttachMode::Control
        })
    );
    assert!(welcomed.contains(&AttachOutput::TabChanged));
    for name in ["control_handoff", "viewport", "nav", "cursor", "text_input"] {
        let outputs = harness.host(name);
        assert!(outputs.contains(&AttachOutput::TabChanged), "{name}");
    }
    assert_eq!(
        harness.machine.tab().nav.as_ref().unwrap().url,
        "https://github.com/login"
    );
    let unknown = harness.host("unknown_type");
    assert!(matches!(
        notices(&unknown)[..],
        [Notice::UnknownMessage { .. }]
    ));
    let error = harness.host("error");
    assert!(matches!(notices(&error)[..], [Notice::HostError(_)]));
}

#[test]
fn video_frames_are_acked_converted_and_format_changes_flagged() {
    let mut harness = Harness::attached();
    let idr = harness.frame("h264_idr");
    assert_eq!(sent(&idr), [ClientMessage::Ack { seq: 1 }]);
    let AttachOutput::Video(first) = &idr[1] else {
        panic!("{idr:?}");
    };
    assert!(first.keyframe && first.format_changed && first.params.is_some());
    assert_eq!(first.stream_id, 7);
    let delta = harness.frame("h264_delta");
    assert_eq!(sent(&delta), [ClientMessage::Ack { seq: 2 }]);
    assert!(matches!(&delta[1], AttachOutput::Video(frame) if !frame.keyframe));
    let changed = harness.frame("h264_format_change_idr");
    assert!(
        matches!(&changed[1], AttachOutput::Video(frame) if frame.format_changed && frame.stream_id == 8)
    );
    let extended = harness.frame("extended_header");
    assert!(
        matches!(&extended[1], AttachOutput::Video(frame) if !frame.keyframe && frame.stream_id == 8)
    );
    let still = harness.frame("jpeg_still");
    assert!(
        matches!(&still[1], AttachOutput::Still { kind: StillKind::Still, jpeg, .. } if jpeg.starts_with(&[0xFF, 0xD8]))
    );
    let thumbnail = harness.frame("jpeg_thumbnail");
    assert!(matches!(
        &thumbnail[1],
        AttachOutput::Still {
            kind: StillKind::Thumbnail,
            ..
        }
    ));
    let unknown = harness.frame("unknown_kind");
    assert_eq!(sent(&unknown), [ClientMessage::Ack { seq: 7 }]);
    assert!(matches!(
        notices(&unknown)[..],
        [Notice::UnknownMediaKind { kind: 200 }]
    ));
}

#[test]
fn malformed_frames_are_reported_acked_when_readable_and_trigger_one_keyframe_request() {
    let mut harness = Harness::attached();
    harness.frame("h264_idr");
    let bad_len = harness.frame("invalid_header_len");
    assert_eq!(
        sent(&bad_len),
        [
            ClientMessage::Ack { seq: 9 },
            ClientMessage::KeyframeRequest {
                reason: KeyframeReason::Gap
            }
        ]
    );
    let magic = harness.frame("invalid_bad_magic");
    assert_eq!(
        sent(&magic),
        [],
        "no seq to ack, keyframe already requested"
    );
    assert!(matches!(
        notices(&magic)[..],
        [Notice::MalformedFrame(HeaderError::BadMagic { .. })]
    ));
    let version = harness.frame("invalid_version");
    assert_eq!(sent(&version), [ClientMessage::Ack { seq: 10 }]);
    let truncated = harness.frame("invalid_truncated");
    assert_eq!(sent(&truncated), []);
    let delta = harness.frame("h264_delta");
    assert!(matches!(
        notices(&delta)[..],
        [Notice::VideoDropped(VideoDrop::AwaitingKeyframe {
            stream_id: 7
        })]
    ));
    let recovered = harness.frame("h264_idr");
    assert!(
        matches!(&recovered[1], AttachOutput::Video(frame) if frame.keyframe && !frame.format_changed)
    );
}

#[test]
fn input_needs_control_and_mouse_moves_coalesce() {
    let mut harness = Harness::attached();
    let early = harness.run(AttachInput::Mouse(mouse(MouseKind::Down, 1.0)));
    assert!(matches!(
        notices(&early)[..],
        [Notice::InputDropped {
            input: InputKind::Mouse,
            reason: DropReason::NotInControl
        }]
    ));
    let quiet = harness.run(AttachInput::Mouse(mouse(MouseKind::Move, 1.0)));
    assert_eq!(quiet, [], "moves without control drop silently");
    let take = harness.run(AttachInput::TakeControl);
    assert_eq!(
        sent(&take),
        [ClientMessage::Control {
            op: ControlOp::Take
        }]
    );
    harness.host("control_user_this");
    assert!(harness.machine.tab().holds_control());
    let first = harness.run(AttachInput::Mouse(mouse(MouseKind::Move, 1.0)));
    assert_eq!(sent(&first).len(), 1);
    harness.now += 4;
    let second = harness.run(AttachInput::Mouse(mouse(MouseKind::Move, 2.0)));
    assert_eq!(sent(&second), []);
    harness.now += 2;
    harness.run(AttachInput::Mouse(mouse(MouseKind::Move, 3.0)));
    let typed = harness.run(AttachInput::Key(key(KeyKind::RawKeyDown)));
    let messages = sent(&typed);
    assert!(
        matches!(&messages[0], ClientMessage::Mouse(event) if (event.x - 3.0).abs() < f64::EPSILON)
    );
    assert!(matches!(&messages[1], ClientMessage::Key(_)));
    let flushed = harness.fire(&second, TimerKind::InputFlush);
    assert_eq!(sent(&flushed), [], "the key already flushed the move");
    let invalid = harness.run(AttachInput::Key(KeyEvent {
        text: None,
        ..key(KeyKind::Char)
    }));
    assert!(matches!(
        notices(&invalid)[..],
        [Notice::InvalidInput(InputError::MissingText)]
    ));
    let ime = harness.run(AttachInput::Ime(ImeEvent {
        op: omnigent_protocol::remote_browser::ImeOp::Commit,
        text: Some("日本".into()),
        selection: None,
        replacement: Some(TextRange { start: 0, end: 3 }),
    }));
    assert_eq!(sent(&ime).len(), 1);
    let nav = harness.run(AttachInput::Nav(NavCommand {
        op: NavOp::Navigate,
        url: Some("https://example.com/".into()),
    }));
    assert_eq!(sent(&nav).len(), 1);
    let release = harness.run(AttachInput::ReleaseControl);
    assert_eq!(
        sent(&release),
        [ClientMessage::Control {
            op: ControlOp::Release
        }]
    );
    harness.host("control_agent");
    assert!(!harness.machine.wants_control());
    let after = harness.run(AttachInput::Key(key(KeyKind::RawKeyDown)));
    assert!(matches!(
        notices(&after)[..],
        [Notice::InputDropped {
            input: InputKind::Key,
            reason: DropReason::NotInControl
        }]
    ));
}

#[test]
fn view_mode_never_sends_control_or_input() {
    let mut harness = Harness::new(options(AttachMode::View, None));
    harness.run(AttachInput::Start);
    harness.open();
    harness.host("hello_view_handoff");
    assert_eq!(
        harness
            .machine
            .tab()
            .control
            .as_ref()
            .unwrap()
            .handoff
            .as_ref()
            .unwrap()
            .id,
        "elicit_42"
    );
    let take = harness.run(AttachInput::TakeControl);
    assert_eq!(sent(&take), []);
    assert!(matches!(
        notices(&take)[..],
        [Notice::InputDropped {
            input: InputKind::Control,
            reason: DropReason::ReadOnly
        }]
    ));
    let settings = harness.run(AttachInput::UpdateSettings(SettingsUpdate {
        quality: Some(Quality::High),
        stats: Some(true),
        ..SettingsUpdate::default()
    }));
    assert_eq!(
        sent(&settings),
        [ClientMessage::Settings(SettingsUpdate {
            stats: Some(true),
            ..SettingsUpdate::default()
        })]
    );
    let key_event = harness.run(AttachInput::Key(key(KeyKind::RawKeyDown)));
    assert!(matches!(
        notices(&key_event)[..],
        [Notice::InputDropped {
            reason: DropReason::ReadOnly,
            ..
        }]
    ));
    let still = harness.run(AttachInput::RequestStill {
        kind: StillKind::Thumbnail,
    });
    assert_eq!(sent(&still).len(), 1, "stills are allowed for viewers");
}

#[test]
fn reconnect_reclaims_control_during_the_grace_period_and_re_requests_stats() {
    let mut harness = Harness::holding_control();
    harness.run(AttachInput::UpdateSettings(SettingsUpdate {
        stats: Some(true),
        ..SettingsUpdate::default()
    }));
    let lost = harness.close(1006, "");
    assert!(matches!(
        state(&lost),
        Some(ConnectionState::Reconnecting { failures: 1, .. })
    ));
    let redial = harness.fire(&lost, TimerKind::Reconnect);
    assert!(matches!(redial[0], AttachOutput::Connect { .. }));
    let typed = harness.run(AttachInput::Key(key(KeyKind::RawKeyDown)));
    assert!(matches!(
        notices(&typed)[..],
        [Notice::InputDropped {
            reason: DropReason::NotAttached,
            ..
        }]
    ));
    harness.open();
    let grace = message_text("host_to_client/hello").replace(
        r#""control":{"holder":null,"owner":"agent"}"#,
        r#""control":{"holder":null,"owner":"user","user_id":"user_1"}"#,
    );
    assert!(grace.contains(r#""owner":"user""#), "{grace}");
    let welcomed = harness.recv(SocketMessage::Text(grace));
    assert_eq!(
        sent(&welcomed),
        [
            ClientMessage::Control {
                op: ControlOp::Take
            },
            ClientMessage::Settings(SettingsUpdate {
                stats: Some(true),
                ..SettingsUpdate::default()
            })
        ]
    );
}

#[test]
fn reconnect_after_the_grace_period_leaves_the_agent_in_control() {
    let mut harness = Harness::holding_control();
    let lost = harness.close(1012, "restart");
    harness.fire(&lost, TimerKind::Reconnect);
    harness.open();
    let welcomed = harness.host("hello");
    assert_eq!(sent(&welcomed), []);
    assert!(!harness.machine.wants_control());
}

#[test]
fn another_device_taking_control_clears_the_wish() {
    let mut harness = Harness::holding_control();
    harness.host("control_user_other");
    assert!(!harness.machine.wants_control());
    let typed = harness.run(AttachInput::Key(key(KeyKind::RawKeyDown)));
    assert_eq!(sent(&typed), []);
}

#[test]
fn pings_every_interval_and_the_watchdog_reconnects_after_silence() {
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    let opened = harness.open();
    harness.host("hello");
    let pinged = harness.fire(&opened, TimerKind::Ping);
    assert_eq!(sent(&pinged), [ClientMessage::Ping { nonce: "p1".into() }]);
    let (watchdog, delay) = timer(&opened, TimerKind::Watchdog).unwrap();
    assert_eq!(delay, 30_000);
    // Inbound traffic at t=26 s re-arms the watchdog for the rest of the window.
    harness.now = 1_000 + 30_000 - 5_000;
    harness.host("pong");
    harness.now = 1_000 + 30_000;
    let rearmed = harness.run(AttachInput::TimerFired { token: watchdog });
    let (token, remaining) = timer(&rearmed, TimerKind::Watchdog).unwrap();
    assert_eq!(remaining, 25_000);
    harness.now += remaining;
    let stalled = harness.run(AttachInput::TimerFired { token });
    assert!(matches!(
        state(&stalled),
        Some(ConnectionState::Reconnecting {
            reason: LinkError::Stalled { silent_ms: 30_000 },
            ..
        })
    ));
    assert!(
        stalled
            .iter()
            .any(|output| matches!(output, AttachOutput::Close { code: 1000, .. }))
    );
}

#[test]
fn tab_closed_then_4404_ends_the_tab_once() {
    let mut harness = Harness::attached();
    harness.host("tab_closed");
    let ended = harness.close(4404, "tab closed");
    assert_eq!(
        state(&ended),
        Some(&ConnectionState::Closed {
            reason: ClosedReason::TabEnded {
                reason: Some(TabClosedReason::Crashed),
                detail: "tab closed".into()
            }
        })
    );
    assert_eq!(
        ended.last(),
        Some(&AttachOutput::TabEnded {
            reason: Some(TabClosedReason::Crashed)
        })
    );
    assert!(harness.machine.current_attempt().is_none());
}

#[test]
fn close_codes_classify_per_the_spec() {
    let cases = [
        (1000, "", "Closed { reason: ServerClosed { code: 1000"),
        (
            1008,
            "authentication required",
            "Failed { error: AuthenticationRequired",
        ),
        (1008, "not authorized", "Failed { error: AccessDenied"),
        (
            4403,
            "",
            "Failed { error: AccessDenied { detail: \"\", mode: Control",
        ),
        (4426, "", "Failed { error: ProtocolUnsupported"),
        (1002, "", "Failed { error: ProtocolViolation { code: 1002"),
        (1009, "", "Failed { error: ProtocolViolation { code: 1009"),
        (4500, "", "Failed { error: ServerError"),
        (1013, "", "Reconnecting { reason: SocketClosed { code: 1013"),
        (1006, "", "Reconnecting { reason: SocketClosed { code: 1006"),
        (4999, "", "Closed { reason: ServerClosed { code: 4999"),
    ];
    for (code, reason, expected) in cases {
        let mut harness = Harness::attached();
        let outputs = harness.close(code, reason);
        let reached = format!("{:?}", state(&outputs).unwrap());
        assert!(reached.starts_with(expected), "{code}: {reached}");
    }
}

#[test]
fn wrong_replica_redials_once_without_the_slice_key() {
    let mut harness = Harness::new(options(AttachMode::View, Some("host_1")));
    harness.run(AttachInput::Start);
    harness.open();
    let redial = harness.close(4400, "wrong replica");
    assert!(redial.iter().any(|output| matches!(
        output,
        AttachOutput::Connect { options, .. } if options.slice_key.is_none()
    )));
    harness.open();
    let failed = harness.close(4400, "wrong replica");
    assert_eq!(
        state(&failed),
        Some(&ConnectionState::Failed {
            error: AttachFailure::WrongReplica
        })
    );
}

#[test]
fn handshake_statuses_and_protocol_mismatch_fail() {
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    let attempt = harness.attempt();
    let rejected = harness.run(AttachInput::Ended {
        attempt,
        end: SocketEnd::HandshakeRejected { status: 401 },
    });
    assert!(matches!(
        state(&rejected),
        Some(ConnectionState::Failed { error }) if error.requires_sign_in()
    ));
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    harness.open();
    let future = message_text("host_to_client/hello").replace(r#""protocol":1"#, r#""protocol":2"#);
    let outputs = harness.recv(SocketMessage::Text(future));
    assert!(
        outputs
            .iter()
            .any(|output| matches!(output, AttachOutput::Close { code: 4426, .. }))
    );
    assert!(matches!(
        state(&outputs),
        Some(ConnectionState::Failed {
            error: AttachFailure::ProtocolUnsupported { .. }
        })
    ));
    assert!(
        outputs
            .iter()
            .any(|output| matches!(output, AttachOutput::CancelTimer { .. }))
    );
}

#[test]
fn stale_attempts_and_timers_are_ignored_and_stop_closes() {
    let mut harness = Harness::attached();
    let old = harness.attempt();
    let lost = harness.close(1006, "");
    let stale = harness.run(AttachInput::Message {
        attempt: old,
        message: SocketMessage::Text(message_text("host_to_client/nav")),
    });
    assert_eq!(stale, []);
    harness.fire(&lost, TimerKind::Reconnect);
    let stopped = harness.run(AttachInput::Stop);
    assert_eq!(state(&stopped), Some(&ConnectionState::Stopped));
    assert!(
        stopped
            .iter()
            .any(|output| matches!(output, AttachOutput::Close { code: 1000, .. }))
    );
    let restarted = harness.run(AttachInput::Start);
    assert_eq!(state(&restarted), Some(&ConnectionState::Connecting));
}

#[test]
fn visibility_and_keyframe_requests_go_out_only_when_attached() {
    let mut harness = Harness::control();
    let hidden = harness.run(AttachInput::SetVisible { visible: false });
    assert_eq!(hidden, []);
    harness.run(AttachInput::Start);
    let opened = harness.open();
    assert!(matches!(
        &sent(&opened)[..],
        [ClientMessage::Hello(ClientHello { visible: false, .. })]
    ));
    harness.host("hello");
    let shown = harness.run(AttachInput::SetVisible { visible: true });
    assert_eq!(sent(&shown), [ClientMessage::Visibility { visible: true }]);
    let flush = harness.run(AttachInput::RequestKeyframe {
        reason: KeyframeReason::Flush,
    });
    assert_eq!(
        sent(&flush),
        [ClientMessage::KeyframeRequest {
            reason: KeyframeReason::Flush
        }]
    );
    let resize = harness.run(AttachInput::Resize(Viewport {
        w: 10,
        h: 10,
        dpr: 1.0,
    }));
    assert!(matches!(
        notices(&resize)[..],
        [Notice::InvalidInput(InputError::BadViewport { .. })]
    ));
}

fn v1_1_holding_control() -> Harness {
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    harness.open();
    harness.host("hello_v1_1");
    harness.run(AttachInput::TakeControl);
    harness.host("control_user_this");
    harness
}

fn mobile_request() -> ViewportRequest {
    ViewportRequest {
        viewport: Viewport {
            w: 390,
            h: 664,
            dpr: 3.0,
        },
        mobile: MobileEmulation::Layout,
    }
}

fn resizes(outputs: &[AttachOutput]) -> Vec<ResizeRequest> {
    sent(outputs)
        .into_iter()
        .filter_map(|message| match message {
            ClientMessage::Resize(resize) => Some(resize),
            _ => None,
        })
        .collect()
}

#[test]
fn the_client_hello_asks_for_the_v1_1_reports() {
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    let opened = harness.open();
    let [ClientMessage::Hello(hello)] = &sent(&opened)[..] else {
        panic!("{opened:?}");
    };
    assert_eq!(hello.features, ["selection", "scroll_metrics"]);
}

#[test]
fn the_wanted_viewport_is_sent_on_gaining_control_and_restored_with_none() {
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    harness.open();
    harness.host("hello_v1_1");
    // Not holding control: nothing goes out yet.
    let early = harness.run(AttachInput::SetViewport(Some(mobile_request())));
    assert_eq!(resizes(&early), []);
    harness.run(AttachInput::TakeControl);
    let gained = harness.host("control_user_this");
    assert_eq!(
        resizes(&gained),
        [ResizeRequest {
            viewport: mobile_request().viewport,
            scope: Some(ViewportScope::Control),
            mobile: Some(MobileEmulation::Layout),
        }]
    );
    // Asking again while it is on its way, or once applied, sends nothing.
    assert_eq!(
        resizes(&harness.run(AttachInput::SetViewport(Some(mobile_request())))),
        []
    );
    assert_eq!(resizes(&harness.host("viewport_control_v1_1")), []);
    // Back to the agent's size: a control-scoped resize to the agent's viewport.
    let restore = harness.run(AttachInput::SetViewport(None));
    assert_eq!(
        resizes(&restore),
        [ResizeRequest {
            viewport: Viewport {
                w: 1280,
                h: 800,
                dpr: 1.0
            },
            scope: Some(ViewportScope::Control),
            mobile: Some(MobileEmulation::Off),
        }]
    );
    // Something else resized the tab while this client holds control: re-assert.
    harness.run(AttachInput::SetViewport(Some(mobile_request())));
    let reasserted = harness.host("viewport");
    assert_eq!(resizes(&reasserted).len(), 1);
    // Handing back: the host restores the agent's viewport before its control update, and
    // the client must not fight it.
    harness.run(AttachInput::ReleaseControl);
    assert_eq!(resizes(&harness.host("viewport")), []);
    harness.run(AttachInput::TakeControl);
    harness.host("control_user_this");
    // Invalid sizes are rejected locally.
    let invalid = harness.run(AttachInput::SetViewport(Some(ViewportRequest {
        viewport: Viewport {
            w: 100,
            h: 664,
            dpr: 3.0,
        },
        mobile: MobileEmulation::Off,
    })));
    assert!(matches!(notices(&invalid)[..], [Notice::InvalidInput(_)]));
}

#[test]
fn a_v1_host_gets_plain_resizes_and_its_viewport_back_before_release() {
    let mut harness = Harness::holding_control();
    let wanted = harness.run(AttachInput::SetViewport(Some(mobile_request())));
    assert_eq!(resizes(&wanted), [plain_resize(mobile_request().viewport)]);
    assert!(notices(&wanted).contains(&&Notice::InputDropped {
        input: InputKind::MobileEmulation,
        reason: DropReason::Unsupported,
    }));
    let applied = harness.recv(SocketMessage::Text(
        r#"{"type":"viewport","w":390,"h":664,"dpr":3}"#.to_owned(),
    ));
    assert_eq!(resizes(&applied), [], "the host applied it");
    let released = harness.run(AttachInput::ReleaseControl);
    let messages = sent(&released);
    assert_eq!(
        messages,
        [
            ClientMessage::Resize(plain_resize(Viewport {
                w: 1280,
                h: 800,
                dpr: 1.0
            })),
            ClientMessage::Control {
                op: ControlOp::Release
            },
        ]
    );
}

#[test]
fn edit_and_touch_need_the_host_feature_and_control() {
    let copy = EditCommand {
        op: EditOp::Copy,
        text: None,
    };
    let touch = TouchEvent {
        kind: omnigent_protocol::remote_browser::TouchKind::Start,
        id: 1,
        x: 10.0,
        y: 20.0,
        radius: None,
        pressure: None,
        modifiers: 0,
    };
    let mut v1 = Harness::holding_control();
    for (input, kind) in [
        (AttachInput::Edit(copy.clone()), InputKind::Edit),
        (AttachInput::Touch(touch.clone()), InputKind::Touch),
    ] {
        let outputs = v1.run(input);
        assert_eq!(sent(&outputs), []);
        assert_eq!(
            notices(&outputs),
            [&Notice::InputDropped {
                input: kind,
                reason: DropReason::Unsupported
            }]
        );
    }
    let mut harness = v1_1_holding_control();
    assert_eq!(
        sent(&harness.run(AttachInput::Edit(copy.clone()))),
        [ClientMessage::Edit(copy)]
    );
    assert_eq!(
        sent(&harness.run(AttachInput::Touch(touch.clone()))),
        [ClientMessage::Touch(touch)]
    );
    let paste_without_text = harness.run(AttachInput::Edit(EditCommand {
        op: EditOp::Paste,
        text: None,
    }));
    assert!(matches!(
        notices(&paste_without_text)[..],
        [Notice::InvalidInput(InputError::BadPaste { bytes: 0 })]
    ));
    let clipboard = harness.host("clipboard_v1_1");
    assert!(clipboard.iter().any(|output| matches!(
        output,
        AttachOutput::Clipboard { op: EditOp::Copy, text } if text.ends_with("second line")
    )));
    assert!(
        harness
            .host("selection_v1_1")
            .contains(&AttachOutput::TabChanged)
    );
    assert!(
        harness
            .host("scroll_v1_1")
            .contains(&AttachOutput::TabChanged)
    );
    assert!(harness.machine.tab().scroll.is_some());
}

fn transport_failure() -> TransportError {
    TransportError::Timeout {
        message: "timed out".to_owned(),
    }
}

/// A harness on its first socket attempt, with `max_reconnects` as the budget.
fn budgeted(max_reconnects: u32) -> Harness {
    let config = AttachConfig {
        max_reconnects,
        ..AttachConfig::default()
    };
    let mut harness = Harness {
        machine: RemoteBrowserAttach::new(
            config,
            options(AttachMode::Control, None),
            FixedJitter(0),
        ),
        now: 1_000,
    };
    harness.run(AttachInput::Start);
    harness
}

#[test]
fn only_auth_failures_ask_the_user_to_sign_in() {
    let auth = AttachFailure::AuthenticationRequired {
        detail: "401".to_owned(),
    };
    assert!(auth.requires_sign_in());
    let unauthorized = AttachFailure::Unrecoverable(LinkError::HttpStatus { status: 401 });
    assert!(unauthorized.requires_sign_in());
    let moved = AttachFailure::Unrecoverable(LinkError::HttpStatus { status: 302 });
    assert!(!moved.requires_sign_in());
}

#[test]
fn a_failed_connect_retries_on_a_transport_error_and_fails_on_an_auth_challenge() {
    let mut harness = budgeted(5);
    let attempt = harness.attempt();
    let failed = harness.run(AttachInput::ConnectFailed {
        attempt,
        error: transport_failure(),
    });
    assert!(matches!(
        state(&failed),
        Some(ConnectionState::Reconnecting { failures: 1, .. })
    ));
    assert_eq!(
        harness.run(AttachInput::ConnectFailed {
            attempt,
            error: transport_failure(),
        }),
        [],
        "a late report for a dead attempt changes nothing"
    );
    harness.fire(&failed, TimerKind::Reconnect);
    let attempt = harness.attempt();
    let challenged = harness.run(AttachInput::Ended {
        attempt,
        end: SocketEnd::Failed(ConnectionFailure::AuthenticationRequired {
            message: "challenge".to_owned(),
        }),
    });
    assert_eq!(
        state(&challenged),
        Some(&ConnectionState::Failed {
            error: AttachFailure::AuthenticationRequired {
                detail: "challenge".to_owned()
            }
        })
    );
}

#[test]
fn a_send_failure_closes_the_socket_and_reconnects_and_a_stale_one_is_ignored() {
    let mut harness = Harness::attached();
    let old = harness.attempt();
    let failed = harness.run(AttachInput::SendFailed {
        attempt: old,
        error: transport_failure(),
    });
    assert!(
        failed
            .iter()
            .any(|output| matches!(output, AttachOutput::Close { attempt, .. } if *attempt == old))
    );
    assert!(matches!(
        state(&failed),
        Some(ConnectionState::Reconnecting {
            reason: LinkError::SendFailed(_),
            ..
        })
    ));
    assert_eq!(
        harness.run(AttachInput::SendFailed {
            attempt: old,
            error: transport_failure(),
        }),
        []
    );
}

#[test]
fn starting_twice_keeps_the_running_attempt() {
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    let attempt = harness.attempt();
    assert_eq!(harness.run(AttachInput::Start), []);
    assert_eq!(harness.attempt(), attempt);
}

#[test]
fn stopping_while_waiting_to_reconnect_cancels_the_timer() {
    let mut harness = Harness::attached();
    let lost = harness.close(1006, "");
    let (token, _) = timer(&lost, TimerKind::Reconnect).unwrap();
    let stopped = harness.run(AttachInput::Stop);
    assert!(stopped.contains(&AttachOutput::CancelTimer { token }));
    assert_eq!(state(&stopped), Some(&ConnectionState::Stopped));
    assert_eq!(
        harness.run(AttachInput::TimerFired { token }),
        [],
        "the cancelled timer firing anyway does not reconnect"
    );
}

#[test]
fn returning_to_the_foreground_redials_at_once_but_only_when_waiting() {
    let mut harness = Harness::attached();
    assert_eq!(harness.run(AttachInput::Foreground), [], "attached stays");
    let lost = harness.close(1006, "");
    let (token, _) = timer(&lost, TimerKind::Reconnect).unwrap();
    let foreground = harness.run(AttachInput::Foreground);
    assert!(foreground.contains(&AttachOutput::CancelTimer { token }));
    assert!(
        foreground
            .iter()
            .any(|output| matches!(output, AttachOutput::Connect { .. }))
    );
    // The dial is in flight, with no timer left: a second foreground does not dial twice.
    assert_eq!(harness.run(AttachInput::Foreground), []);
}

#[test]
fn the_budget_runs_out_and_the_foreground_starts_over() {
    let mut harness = budgeted(1);
    let attempt = harness.attempt();
    let failed = harness.run(AttachInput::Ended {
        attempt,
        end: SocketEnd::Failed(ConnectionFailure::Transport(transport_failure())),
    });
    assert!(matches!(
        state(&failed),
        Some(ConnectionState::Reconnecting { failures: 1, .. })
    ));
    harness.fire(&failed, TimerKind::Reconnect);
    let attempt = harness.attempt();
    let exhausted = harness.run(AttachInput::Ended {
        attempt,
        end: SocketEnd::HandshakeRejected { status: 503 },
    });
    assert_eq!(
        state(&exhausted),
        Some(&ConnectionState::Failed {
            error: AttachFailure::ReconnectBudgetExhausted {
                last: LinkError::HttpStatus { status: 503 },
                attempts: 1,
            }
        })
    );
    assert_eq!(harness.machine.current_attempt(), None);
    let restarted = harness.run(AttachInput::Foreground);
    assert_eq!(state(&restarted), Some(&ConnectionState::Connecting));
    let attempt = harness.attempt();
    let fresh = harness.run(AttachInput::Ended {
        attempt,
        end: SocketEnd::HandshakeRejected { status: 503 },
    });
    assert!(
        matches!(
            state(&fresh),
            Some(ConnectionState::Reconnecting { failures: 1, .. })
        ),
        "the restart forgot the old failures"
    );
}

#[test]
fn a_zero_budget_gives_up_on_the_first_failure() {
    let mut harness = budgeted(0);
    let attempt = harness.attempt();
    let exhausted = harness.run(AttachInput::Ended {
        attempt,
        end: SocketEnd::HandshakeRejected { status: 500 },
    });
    assert!(matches!(
        state(&exhausted),
        Some(ConnectionState::Failed {
            error: AttachFailure::ReconnectBudgetExhausted { attempts: 0, .. }
        })
    ));
}

#[test]
fn a_terminal_status_fails_without_a_retry_and_the_foreground_leaves_it_alone() {
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    let attempt = harness.attempt();
    let moved = harness.run(AttachInput::Ended {
        attempt,
        end: SocketEnd::HandshakeRejected { status: 302 },
    });
    assert_eq!(
        state(&moved),
        Some(&ConnectionState::Failed {
            error: AttachFailure::Unrecoverable(LinkError::HttpStatus { status: 302 })
        })
    );
    assert_eq!(harness.run(AttachInput::Foreground), []);
}

#[test]
fn a_403_handshake_reports_the_requested_mode() {
    let mut harness = Harness::new(options(AttachMode::View, None));
    harness.run(AttachInput::Start);
    let attempt = harness.attempt();
    let denied = harness.run(AttachInput::Ended {
        attempt,
        end: SocketEnd::HandshakeRejected { status: 403 },
    });
    assert!(matches!(
        state(&denied),
        Some(ConnectionState::Failed {
            error: AttachFailure::AccessDenied {
                mode: AttachMode::View,
                ..
            }
        })
    ));
}

#[test]
fn opened_twice_and_a_message_before_open_break_the_host_contract() {
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    let early = harness.recv(SocketMessage::Text(message_text("host_to_client/hello")));
    assert!(matches!(
        state(&early),
        Some(ConnectionState::Failed {
            error: AttachFailure::Unrecoverable(LinkError::HostContract { .. })
        })
    ));

    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    harness.open();
    let twice = harness.open();
    assert!(matches!(
        state(&twice),
        Some(ConnectionState::Failed {
            error: AttachFailure::Unrecoverable(LinkError::HostContract { .. })
        })
    ));
    assert!(
        twice
            .iter()
            .any(|output| matches!(output, AttachOutput::Close { .. })),
        "the socket that misbehaved is closed"
    );
}

#[test]
fn malformed_text_is_a_notice_and_keeps_the_connection() {
    let mut harness = Harness::attached();
    for text in ["", "{", "[1,2]", "\"hello\"", "{\"type\":\"hello\"}"] {
        let outputs = harness.recv(SocketMessage::Text(text.to_owned()));
        assert!(
            matches!(notices(&outputs)[..], [Notice::MalformedMessage(_)]),
            "{text}: {outputs:?}"
        );
        assert_eq!(state(&outputs), None);
    }
    assert!(harness.machine.current_attempt().is_some());
}

#[test]
fn a_delta_before_any_keyframe_requests_one_exactly_once() {
    let mut harness = Harness::attached();
    let first = harness.frame("h264_delta");
    assert!(
        sent(&first)
            .iter()
            .any(|message| matches!(message, ClientMessage::KeyframeRequest { .. }))
    );
    let second = harness.frame("h264_delta");
    assert!(
        !sent(&second)
            .iter()
            .any(|message| matches!(message, ClientMessage::KeyframeRequest { .. }))
    );
}

#[test]
fn an_invalid_mouse_event_is_refused_before_the_control_gate() {
    let mut harness = Harness::control();
    let outputs = harness.run(AttachInput::Mouse(mouse(MouseKind::Move, f64::NAN)));
    assert!(matches!(notices(&outputs)[..], [Notice::InvalidInput(_)]));
}

#[test]
fn a_dialog_reply_needs_control_and_goes_out_when_holding_it() {
    let reply = DialogReply {
        id: "dialog_1".to_owned(),
        accept: true,
        text: Some("\u{1F600}".to_owned()),
    };
    let mut watching = Harness::attached();
    let refused = watching.run(AttachInput::DialogReply(reply.clone()));
    assert_eq!(
        notices(&refused),
        [&Notice::InputDropped {
            input: InputKind::DialogReply,
            reason: DropReason::NotInControl,
        }]
    );
    let mut holding = Harness::holding_control();
    let replied = holding.run(AttachInput::DialogReply(reply.clone()));
    assert_eq!(sent(&replied), [ClientMessage::DialogReply(reply)]);
}

#[test]
fn a_still_request_before_the_hello_is_dropped_and_view_mode_may_ask() {
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    let early = harness.run(AttachInput::RequestStill {
        kind: StillKind::Still,
    });
    assert_eq!(
        notices(&early),
        [&Notice::InputDropped {
            input: InputKind::Still,
            reason: DropReason::NotAttached,
        }]
    );
    let mut viewing = Harness::new(options(AttachMode::View, None));
    viewing.run(AttachInput::Start);
    viewing.open();
    viewing.host("hello_view_handoff");
    let asked = viewing.run(AttachInput::RequestStill {
        kind: StillKind::Still,
    });
    assert_eq!(
        sent(&asked),
        [ClientMessage::StillRequest {
            kind: StillKind::Still
        }]
    );
}

#[test]
fn a_viewport_set_while_control_is_on_its_way_waits_for_the_grant() {
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    harness.open();
    harness.host("hello_v1_1");
    harness.run(AttachInput::TakeControl);
    let early = harness.run(AttachInput::SetViewport(Some(mobile_request())));
    assert_eq!(resizes(&early), []);
    assert_eq!(resizes(&harness.host("control_user_this")).len(), 1);
}

#[test]
fn a_scoped_host_without_mobile_emulation_reports_it_once_and_resizes_plainly() {
    let mut hello = fixture_json("messages/host_to_client/hello_v1_1.json");
    hello["features"] = serde_json::json!(["viewport_scope"]);
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    harness.open();
    harness.recv(SocketMessage::Text(hello.to_string()));
    harness.run(AttachInput::TakeControl);
    harness.host("control_user_this");
    let first = harness.run(AttachInput::SetViewport(Some(mobile_request())));
    assert_eq!(
        notices(&first),
        [&Notice::InputDropped {
            input: InputKind::MobileEmulation,
            reason: DropReason::Unsupported,
        }]
    );
    assert_eq!(
        resizes(&first),
        [ResizeRequest {
            viewport: mobile_request().viewport,
            scope: Some(ViewportScope::Control),
            mobile: None,
        }]
    );
    let again = harness.run(AttachInput::SetViewport(Some(mobile_request())));
    assert_eq!(notices(&again), Vec::<&Notice>::new());
}

#[test]
fn taking_control_before_the_hello_is_sent_once_the_hello_arrives() {
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    harness.open();
    assert_eq!(harness.run(AttachInput::TakeControl), []);
    let hello = harness.host("hello");
    assert!(
        sent(&hello).contains(&ClientMessage::Control {
            op: ControlOp::Take
        }),
        "the click is honoured once the host says hello: {hello:?}"
    );
    assert!(harness.machine.wants_control());
}

#[test]
fn a_take_cancelled_or_refused_before_the_hello_is_not_sent() {
    let mut released = Harness::control();
    released.run(AttachInput::Start);
    released.open();
    released.run(AttachInput::TakeControl);
    released.run(AttachInput::ReleaseControl);
    assert_eq!(sent(&released.host("hello")), []);

    let mut stopped = Harness::control();
    stopped.run(AttachInput::Start);
    stopped.run(AttachInput::TakeControl);
    stopped.run(AttachInput::Stop);
    stopped.run(AttachInput::Start);
    stopped.open();
    assert_eq!(sent(&stopped.host("hello")), []);

    let mut viewing = Harness::control();
    viewing.run(AttachInput::Start);
    viewing.open();
    viewing.run(AttachInput::TakeControl);
    let hello = viewing.host("hello_view_handoff");
    assert_eq!(sent(&hello), []);
    assert_eq!(
        notices(&hello),
        [&Notice::InputDropped {
            input: InputKind::Control,
            reason: DropReason::ReadOnly,
        }]
    );
    assert!(!viewing.machine.wants_control());
}

#[test]
fn a_host_that_only_grants_view_refuses_a_take() {
    // The client asked to attach in control mode but the host only granted view.
    let mut downgraded = Harness::control();
    downgraded.run(AttachInput::Start);
    downgraded.open();
    downgraded.host("hello_view_handoff");
    let refused = downgraded.run(AttachInput::TakeControl);
    assert_eq!(
        notices(&refused),
        [&Notice::InputDropped {
            input: InputKind::Control,
            reason: DropReason::ReadOnly,
        }]
    );
    assert!(!downgraded.machine.wants_control());
}

#[test]
fn releasing_control_without_holding_it_sends_nothing() {
    let mut harness = Harness::attached();
    assert_eq!(sent(&harness.run(AttachInput::ReleaseControl)), []);
}

#[test]
fn turning_stats_off_clears_the_shown_stats() {
    let mut harness = Harness::attached();
    harness.run(AttachInput::UpdateSettings(SettingsUpdate {
        stats: Some(true),
        ..SettingsUpdate::default()
    }));
    harness.host("stats");
    assert!(harness.machine.tab().stats.is_some());
    let off = harness.run(AttachInput::UpdateSettings(SettingsUpdate {
        stats: Some(false),
        ..SettingsUpdate::default()
    }));
    assert!(off.contains(&AttachOutput::TabChanged));
    assert_eq!(harness.machine.tab().stats, None);
    let again = harness.run(AttachInput::UpdateSettings(SettingsUpdate {
        stats: Some(false),
        ..SettingsUpdate::default()
    }));
    assert!(!again.contains(&AttachOutput::TabChanged));
}

#[test]
fn a_coalesced_move_flushes_on_its_timer_while_holding_control() {
    let mut harness = Harness::holding_control();
    harness.run(AttachInput::Mouse(mouse(MouseKind::Move, 1.0)));
    let armed = harness.run(AttachInput::Mouse(mouse(MouseKind::Move, 2.0)));
    let flushed = harness.fire(&armed, TimerKind::InputFlush);
    assert_eq!(
        sent(&flushed),
        [ClientMessage::Mouse(mouse(MouseKind::Move, 2.0))]
    );
}

#[test]
fn a_timer_for_a_dead_attempt_is_ignored() {
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    let opened = harness.open();
    let (ping, _) = timer(&opened, TimerKind::Ping).unwrap();
    let (watchdog, _) = timer(&opened, TimerKind::Watchdog).unwrap();
    harness.close(1006, "");
    harness.now += 1_000_000;
    assert_eq!(harness.run(AttachInput::TimerFired { token: ping }), []);
    assert_eq!(harness.run(AttachInput::TimerFired { token: watchdog }), []);
}

#[test]
fn a_clock_that_jumps_backward_rearms_the_watchdog_without_declaring_a_stall() {
    let mut harness = Harness::control();
    harness.run(AttachInput::Start);
    harness.now = 1_000_000;
    let opened = harness.open();
    let (watchdog, _) = timer(&opened, TimerKind::Watchdog).unwrap();
    harness.now = 5;
    let fired = harness.run(AttachInput::TimerFired { token: watchdog });
    assert_eq!(state(&fired), None);
    assert!(timer(&fired, TimerKind::Watchdog).is_some());
}

/// The steps behind `handle`'s current-attempt check do nothing once no attempt is left.
#[test]
fn steps_without_an_attempt_change_nothing() {
    let mut harness = Harness::control();
    let before = harness.machine.connection().clone();
    let mut out = Vec::new();
    harness.machine.opened(1, &mut out);
    harness
        .machine
        .message(1, SocketMessage::Text("{}".to_owned()), &mut out);
    let loss = Loss::Retry(LinkError::Stalled { silent_ms: 1 });
    harness.machine.lose(1, loss, true, &mut out);
    assert_eq!(out, Vec::new());
    assert_eq!(harness.machine.connection(), &before);
}

/// A watchdog firing with no open socket has nothing to judge, so it stops without rearming.
#[test]
fn a_watchdog_with_no_open_socket_stops_without_rearming() {
    let mut harness = Harness::control();
    let token = TimerToken {
        kind: TimerKind::Watchdog,
        id: 77,
    };
    harness.machine.watchdog_timer = Some(token);
    assert_eq!(harness.run(AttachInput::TimerFired { token }), Vec::new());
    assert_eq!(harness.machine.watchdog_timer, None);
}

/// Only the discrete input kinds are sent from there; anything else is ignored.
#[test]
fn discrete_input_ignores_a_lifecycle_input() {
    let mut harness = Harness::attached();
    let mut out = Vec::new();
    harness
        .machine
        .discrete_input(harness.now, AttachInput::Foreground, &mut out);
    assert_eq!(out, Vec::new());
}

/// Settings without a stats choice still send, and leave the shown stats alone.
#[test]
fn a_settings_update_without_stats_keeps_them_and_sends_the_rest() {
    let mut harness = Harness::attached();
    harness.run(AttachInput::UpdateSettings(SettingsUpdate {
        stats: Some(true),
        ..SettingsUpdate::default()
    }));
    harness.host("stats");
    let update = SettingsUpdate {
        max_fps: Some(12),
        ..SettingsUpdate::default()
    };
    let sent_outputs = harness.run(AttachInput::UpdateSettings(update.clone()));
    assert_eq!(sent(&sent_outputs), [ClientMessage::Settings(update)]);
    assert!(harness.machine.tab().stats.is_some());
}

/// A message that can't be encoded is reported instead of being sent or lost silently.
#[test]
fn an_unencodable_message_is_reported_not_sent() {
    let mut out = Vec::new();
    let error = ClientMessage::decode("not json").unwrap_err();
    queue_encoded(AttemptId(1), Err(error.clone()), &mut out);
    assert_eq!(out, [AttachOutput::Notice(Notice::MalformedMessage(error))]);
}
