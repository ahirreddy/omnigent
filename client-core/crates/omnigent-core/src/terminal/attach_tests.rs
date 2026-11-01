use serde_json::{Value, json};

use super::*;
use crate::realtime::test_support::FixedJitter;

struct Harness {
    machine: TerminalAttach<FixedJitter>,
    now: u64,
}

impl Harness {
    fn new(options: AttachOptions) -> Self {
        Self {
            machine: TerminalAttach::new(AttachConfig::default(), options, FixedJitter(0)),
            now: 1_000,
        }
    }

    fn interactive() -> Self {
        Self::new(AttachOptions::default())
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

    fn attached(&mut self) -> AttemptId {
        self.run(AttachInput::Start);
        self.open();
        self.attempt()
    }

    fn fire_reconnect(&mut self, outputs: &[AttachOutput]) -> Vec<AttachOutput> {
        let (token, delay) = timer(outputs).expect("a reconnect timer");
        self.now += delay;
        self.run(AttachInput::TimerFired { token })
    }
}

fn state(outputs: &[AttachOutput]) -> Option<&AttachState> {
    outputs.iter().rev().find_map(|output| match output {
        AttachOutput::StateChanged { state } => Some(state),
        _ => None,
    })
}

fn timer(outputs: &[AttachOutput]) -> Option<(TimerToken, u64)> {
    outputs.iter().find_map(|output| match output {
        AttachOutput::ScheduleTimer { token, delay_ms } => Some((*token, *delay_ms)),
        _ => None,
    })
}

fn connects(outputs: &[AttachOutput]) -> Vec<&AttachOptions> {
    outputs
        .iter()
        .filter_map(|output| match output {
            AttachOutput::Connect { options, .. } => Some(options),
            _ => None,
        })
        .collect()
}

fn sent(outputs: &[AttachOutput]) -> Vec<&SocketMessage> {
    outputs
        .iter()
        .filter_map(|output| match output {
            AttachOutput::Send { message, .. } => Some(message),
            _ => None,
        })
        .collect()
}

fn resize_text(cols: u16, rows: u16) -> SocketMessage {
    ClientFrame::Resize(GridSize::new(cols, rows).unwrap()).encode()
}

#[test]
fn start_connects_and_open_sends_the_latest_size_first() {
    let mut harness = Harness::interactive();
    // A size reported before the socket opens is held, not sent.
    assert_eq!(
        harness.run(AttachInput::Resize {
            size: GridSize::new(100, 30).unwrap()
        }),
        []
    );
    let outputs = harness.run(AttachInput::Start);
    assert_eq!(state(&outputs), Some(&AttachState::Connecting));
    assert_eq!(connects(&outputs), [&AttachOptions::default()]);
    let outputs = harness.open();
    assert_eq!(
        state(&outputs),
        Some(&AttachState::Attached { read_only: false })
    );
    assert!(
        !outputs.contains(&AttachOutput::ResetScreen),
        "first attach keeps the screen"
    );
    assert_eq!(sent(&outputs), [&resize_text(100, 30)]);
    // An unchanged size is not resent; a new one is.
    assert_eq!(
        harness.run(AttachInput::Resize {
            size: GridSize::new(100, 30).unwrap()
        }),
        []
    );
    let outputs = harness.run(AttachInput::Resize {
        size: GridSize::new(120, 40).unwrap(),
    });
    assert_eq!(sent(&outputs), [&resize_text(120, 40)]);
}

#[test]
fn input_is_binary_while_attached_and_dropped_visibly_otherwise() {
    let mut harness = Harness::interactive();
    let outputs = harness.run(AttachInput::Input {
        bytes: b"ls".to_vec(),
    });
    assert_eq!(
        outputs,
        [AttachOutput::InputDropped {
            len: 2,
            reason: DropReason::NotAttached
        }]
    );
    harness.attached();
    let outputs = harness.run(AttachInput::Input {
        bytes: b"ls\r".to_vec(),
    });
    assert_eq!(sent(&outputs), [&SocketMessage::Binary(b"ls\r".to_vec())]);
    assert_eq!(harness.run(AttachInput::Input { bytes: Vec::new() }), []);

    let mut viewer = Harness::new(AttachOptions {
        read_only: true,
        slice_key: None,
    });
    viewer.attached();
    assert_eq!(
        viewer.run(AttachInput::Input {
            bytes: b"x".to_vec()
        }),
        [AttachOutput::InputDropped {
            len: 1,
            reason: DropReason::ReadOnly
        }]
    );
}

#[test]
fn server_frames_become_outputs_and_bad_control_frames_do_not_drop_the_attach() {
    let mut harness = Harness::interactive();
    harness.attached();
    assert_eq!(
        harness.recv(SocketMessage::Binary(b"\x1b[31mhi".to_vec())),
        [AttachOutput::Output {
            bytes: b"\x1b[31mhi".to_vec()
        }]
    );
    assert_eq!(
        harness.recv(SocketMessage::Text(
            json!({"type": "tmux-replies", "queries": ["da1"]}).to_string()
        )),
        [AttachOutput::TmuxReplies {
            queries: vec!["da1".into()]
        }]
    );
    assert_eq!(
        harness.recv(SocketMessage::Text(
            json!({"type": "clipboard-write", "encoding": "base64", "data": "aGk="}).to_string()
        )),
        [AttachOutput::ClipboardWrite {
            data: b"hi".to_vec()
        }]
    );
    let outputs = harness.recv(SocketMessage::Text("{not json".into()));
    assert!(matches!(
        outputs.as_slice(),
        [AttachOutput::FrameRejected { .. }]
    ));
    let outputs = harness.recv(SocketMessage::Text(json!({"type": "later"}).to_string()));
    assert!(
        matches!(outputs.as_slice(), [AttachOutput::UnknownFrame { frame_type, .. }] if frame_type == "later")
    );
    assert_eq!(
        harness.machine.state(),
        &AttachState::Attached { read_only: false }
    );
}

#[test]
fn terminal_closed_is_distinct_from_connection_lost() {
    let mut harness = Harness::interactive();
    harness.attached();
    let outputs = harness.close(4404, "terminal session ended");
    assert_eq!(
        state(&outputs),
        Some(&AttachState::Closed {
            reason: ClosedReason::TerminalEnded {
                reason: "terminal session ended".into()
            }
        })
    );
    assert_eq!(connects(&outputs), Vec::<&AttachOptions>::new());
    assert!(timer(&outputs).is_none());

    let mut harness = Harness::interactive();
    harness.attached();
    let outputs = harness.close(4405, "terminal detached");
    assert!(matches!(
        state(&outputs),
        Some(AttachState::Closed {
            reason: ClosedReason::Detached { .. }
        })
    ));

    for code in [1001, 1005, 1006, 1011, 1012, 1013, 1014] {
        let mut harness = Harness::interactive();
        harness.attached();
        let outputs = harness.close(code, "");
        assert!(
            matches!(state(&outputs), Some(AttachState::Reconnecting { .. })),
            "{code}"
        );
        assert!(timer(&outputs).is_some(), "{code}");
    }

    for code in [1000, 1003, 4000, 4999] {
        let mut harness = Harness::interactive();
        harness.attached();
        let outputs = harness.close(code, "bye");
        assert!(
            matches!(
                state(&outputs),
                Some(AttachState::Closed {
                    reason: ClosedReason::ServerClosed { .. }
                })
            ),
            "{code}"
        );
    }
}

#[test]
fn auth_failures_are_terminal_states() {
    let cases: [(SocketEnd, bool); 5] = [
        (SocketEnd::HandshakeRejected { status: 401 }, true),
        (SocketEnd::HandshakeRejected { status: 403 }, false),
        (
            SocketEnd::Closed {
                code: 1008,
                reason: "authentication required".into(),
            },
            true,
        ),
        (
            SocketEnd::Closed {
                code: 1008,
                reason: "not authorized".into(),
            },
            false,
        ),
        (
            SocketEnd::Failed(ConnectionFailure::AuthenticationRequired {
                message: "challenge".into(),
            }),
            true,
        ),
    ];
    for (end, sign_in) in cases {
        let mut harness = Harness::interactive();
        harness.run(AttachInput::Start);
        let attempt = harness.attempt();
        let outputs = harness.run(AttachInput::Ended {
            attempt,
            end: end.clone(),
        });
        let Some(AttachState::Failed { error }) = state(&outputs) else {
            panic!("{end:?} did not fail: {outputs:?}");
        };
        assert_eq!(error.requires_sign_in(), sign_in, "{end:?}");
        if let AttachFailure::AccessDenied { read_only, .. } = error {
            assert!(!read_only, "the denied attach was interactive");
        }
        assert_eq!(connects(&outputs), Vec::<&AttachOptions>::new());
        assert!(timer(&outputs).is_none());
        // Late callbacks for the dead attempt are ignored.
        assert_eq!(harness.run(AttachInput::Opened { attempt }), []);
    }
}

#[test]
fn server_error_and_unrecoverable_transport_failures_stop() {
    let mut harness = Harness::interactive();
    harness.attached();
    let outputs = harness.close(4500, "runner attach proxy failed");
    assert_eq!(
        state(&outputs),
        Some(&AttachState::Failed {
            error: AttachFailure::ServerError {
                reason: "runner attach proxy failed".into()
            }
        })
    );

    for error in [
        TransportError::Tls {
            message: "bad cert".into(),
        },
        TransportError::Cancelled,
    ] {
        let mut harness = Harness::interactive();
        harness.run(AttachInput::Start);
        let attempt = harness.attempt();
        let outputs = harness.run(AttachInput::ConnectFailed { attempt, error });
        assert!(matches!(
            state(&outputs),
            Some(AttachState::Failed {
                error: AttachFailure::Unrecoverable(_)
            })
        ));
    }
    let mut harness = Harness::interactive();
    harness.run(AttachInput::Start);
    let attempt = harness.attempt();
    let outputs = harness.run(AttachInput::Ended {
        attempt,
        end: SocketEnd::HandshakeRejected { status: 302 },
    });
    assert!(matches!(
        state(&outputs),
        Some(AttachState::Failed {
            error: AttachFailure::Unrecoverable(LinkError::HttpStatus { status: 302 })
        })
    ));
}

#[test]
fn reconnect_backs_off_resets_the_screen_and_resends_the_size() {
    let mut harness = Harness::interactive();
    harness.run(AttachInput::Resize {
        size: GridSize::new(80, 24).unwrap(),
    });
    harness.attached();
    let outputs = harness.close(1006, "");
    assert_eq!(
        state(&outputs),
        Some(&AttachState::Reconnecting {
            reason: LinkError::SocketClosed {
                code: 1006,
                reason: String::new()
            },
            failures: 1,
            delay_ms: 250,
        })
    );
    // Input during the outage is reported, not queued.
    assert!(matches!(
        harness
            .run(AttachInput::Input {
                bytes: b"a".to_vec()
            })
            .as_slice(),
        [AttachOutput::InputDropped {
            reason: DropReason::NotAttached,
            ..
        }]
    ));
    let outputs = harness.fire_reconnect(&outputs);
    assert_eq!(connects(&outputs).len(), 1);
    let outputs = harness.open();
    let reset = outputs
        .iter()
        .position(|output| output == &AttachOutput::ResetScreen)
        .expect("a reattach resets the screen");
    let resize = outputs
        .iter()
        .position(|output| matches!(output, AttachOutput::Send { .. }))
        .expect("the size is resent");
    assert!(reset < resize);
    assert_eq!(sent(&outputs), [&resize_text(80, 24)]);
}

#[test]
fn a_healthy_attach_redials_at_once_and_failures_ramp() {
    let mut harness = Harness::interactive();
    harness.attached();
    harness.now += 30_000;
    let outputs = harness.close(1001, "going away");
    assert!(matches!(
        state(&outputs),
        Some(AttachState::Reconnecting {
            failures: 0,
            delay_ms: 0,
            ..
        })
    ));
    assert_eq!(connects(&outputs).len(), 1, "redials without a timer");

    // Connection refused repeatedly: the cap doubles from 500 ms to 30 s.
    let mut delays = Vec::new();
    for _ in 0..8 {
        let attempt = harness.attempt();
        let outputs = harness.run(AttachInput::ConnectFailed {
            attempt,
            error: TransportError::Offline {
                message: "refused".into(),
            },
        });
        let (token, delay) = timer(&outputs).unwrap();
        delays.push(delay);
        harness.now += delay;
        harness.run(AttachInput::TimerFired { token });
    }
    assert_eq!(
        delays,
        [250, 500, 1_000, 2_000, 4_000, 8_000, 15_000, 15_000]
    );
}

#[test]
fn the_reconnect_budget_runs_out_and_foreground_starts_over() {
    let mut harness = Harness::interactive();
    harness.run(AttachInput::Start);
    let max = AttachConfig::default().max_reconnects;
    let mut last = Vec::new();
    for _ in 0..=max {
        let attempt = harness.attempt();
        last = harness.run(AttachInput::ConnectFailed {
            attempt,
            error: TransportError::Timeout {
                message: "slow".into(),
            },
        });
        if let Some((token, delay)) = timer(&last) {
            harness.now += delay;
            harness.run(AttachInput::TimerFired { token });
        }
    }
    let Some(AttachState::Failed {
        error: AttachFailure::ReconnectBudgetExhausted { attempts, .. },
    }) = state(&last)
    else {
        panic!("budget not exhausted: {last:?}");
    };
    assert_eq!(*attempts, max);
    assert!(harness.machine.current_attempt().is_none());
    let outputs = harness.run(AttachInput::Foreground);
    assert_eq!(state(&outputs), Some(&AttachState::Connecting));
    assert_eq!(connects(&outputs).len(), 1);
}

#[test]
fn foreground_skips_a_pending_backoff() {
    let mut harness = Harness::interactive();
    harness.attached();
    let outputs = harness.close(1006, "");
    let (token, _) = timer(&outputs).unwrap();
    let outputs = harness.run(AttachInput::Foreground);
    assert_eq!(outputs.first(), Some(&AttachOutput::CancelTimer { token }));
    assert_eq!(connects(&outputs).len(), 1);
    // The cancelled timer firing late does nothing.
    assert_eq!(harness.run(AttachInput::TimerFired { token }), []);
}

#[test]
fn wrong_replica_redials_once_without_the_slice_key() {
    let mut harness = Harness::new(AttachOptions {
        read_only: false,
        slice_key: Some("host_1".into()),
    });
    let outputs = harness.run(AttachInput::Start);
    assert_eq!(connects(&outputs)[0].slice_key.as_deref(), Some("host_1"));
    harness.open();
    let outputs = harness.close(4400, "host on another replica");
    let options = connects(&outputs);
    assert_eq!(options.len(), 1, "redials at once");
    assert_eq!(options[0].slice_key, None);
    harness.open();
    let outputs = harness.close(4400, "host on another replica");
    assert_eq!(
        state(&outputs),
        Some(&AttachState::Failed {
            error: AttachFailure::WrongReplica
        })
    );
    // A fresh start uses the key again.
    let outputs = harness.run(AttachInput::Start);
    assert_eq!(connects(&outputs)[0].slice_key.as_deref(), Some("host_1"));
}

#[test]
fn stop_closes_cancels_and_ignores_late_callbacks() {
    let mut harness = Harness::interactive();
    let attempt = harness.attached();
    let outputs = harness.run(AttachInput::Stop);
    assert_eq!(
        outputs,
        [
            AttachOutput::Close {
                attempt,
                code: CLIENT_DETACH_CODE,
                reason: "client detached".into()
            },
            AttachOutput::StateChanged {
                state: AttachState::Stopped
            }
        ]
    );
    assert_eq!(
        harness.run(AttachInput::Message {
            attempt,
            message: SocketMessage::Binary(b"late".to_vec())
        }),
        []
    );

    let mut harness = Harness::interactive();
    harness.attached();
    let outputs = harness.close(1006, "");
    let (token, _) = timer(&outputs).unwrap();
    let outputs = harness.run(AttachInput::Stop);
    assert!(outputs.contains(&AttachOutput::CancelTimer { token }));
    assert_eq!(harness.run(AttachInput::TimerFired { token }), []);
}

#[test]
fn send_failure_closes_and_reconnects() {
    let mut harness = Harness::interactive();
    let attempt = harness.attached();
    let outputs = harness.run(AttachInput::SendFailed {
        attempt,
        error: TransportError::Other {
            message: "broken pipe".into(),
        },
    });
    assert!(matches!(outputs.first(), Some(AttachOutput::Close { .. })));
    assert!(matches!(
        state(&outputs),
        Some(AttachState::Reconnecting {
            reason: LinkError::SendFailed(_),
            ..
        })
    ));
}

#[test]
fn host_contract_violations_fail() {
    let mut harness = Harness::interactive();
    harness.run(AttachInput::Start);
    let outputs = harness.recv(SocketMessage::Binary(b"early".to_vec()));
    assert!(matches!(
        state(&outputs),
        Some(AttachState::Failed {
            error: AttachFailure::Unrecoverable(LinkError::HostContract { .. })
        })
    ));
    let mut harness = Harness::interactive();
    harness.attached();
    let outputs = harness.open();
    assert!(matches!(
        state(&outputs),
        Some(AttachState::Failed {
            error: AttachFailure::Unrecoverable(LinkError::HostContract { .. })
        })
    ));
}

#[test]
fn start_is_idempotent_while_running() {
    let mut harness = Harness::interactive();
    harness.attached();
    assert_eq!(harness.run(AttachInput::Start), []);
    let first = harness.attempt();
    harness.close(1006, "");
    assert_eq!(harness.run(AttachInput::Start), []);
    assert!(harness.machine.current_attempt().is_none() || harness.attempt() != first);
}

/// Replays a recorded attach transcript (see `fixtures/terminal/README.md`) through the
/// machine: every server frame must surface as the matching output, every client frame must be
/// one the machine would send, and the close must classify as recorded.
#[allow(
    clippy::too_many_lines,
    reason = "one table-driven transcript interpreter reads better unsplit"
)]
fn replay(name: &str, expect_output: bool) {
    let path = format!(
        "{}/../../fixtures/terminal/{name}",
        env!("CARGO_MANIFEST_DIR")
    );
    let text = std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("{path}: {error}"));
    let mut harness = Harness::interactive();
    harness.run(AttachInput::Start);
    harness.open();
    let mut saw_output = false;
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        let line: Value = serde_json::from_str(line).unwrap();
        let message = || match line["kind"].as_str() {
            Some("binary") => SocketMessage::Binary(
                base64::engine::general_purpose::STANDARD
                    .decode(line["base64"].as_str().unwrap())
                    .unwrap(),
            ),
            Some("text") => SocketMessage::Text(line["text"].as_str().unwrap().to_owned()),
            other => panic!("{name}: kind {other:?}"),
        };
        match line["direction"].as_str() {
            Some("send") => match message() {
                SocketMessage::Binary(bytes) => {
                    let outputs = harness.run(AttachInput::Input {
                        bytes: bytes.clone(),
                    });
                    assert_eq!(sent(&outputs), [&SocketMessage::Binary(bytes)]);
                }
                SocketMessage::Text(text) => {
                    let value: Value = serde_json::from_str(&text).unwrap();
                    let size = GridSize::new(
                        u16::try_from(value["cols"].as_u64().unwrap()).unwrap(),
                        u16::try_from(value["rows"].as_u64().unwrap()).unwrap(),
                    )
                    .unwrap();
                    let outputs = harness.run(AttachInput::Resize { size });
                    let [SocketMessage::Text(produced)] = sent(&outputs).as_slice() else {
                        panic!("{name}: resize not sent: {outputs:?}");
                    };
                    let produced: Value = serde_json::from_str(produced).unwrap();
                    assert_eq!(produced, value);
                }
            },
            Some("recv") => {
                let message = message();
                let outputs = harness.recv(message.clone());
                match message {
                    SocketMessage::Binary(bytes) => {
                        saw_output = true;
                        assert_eq!(outputs, [AttachOutput::Output { bytes }]);
                    }
                    SocketMessage::Text(_) => assert!(
                        matches!(
                            outputs.as_slice(),
                            [AttachOutput::TmuxReplies { .. }
                                | AttachOutput::ClipboardWrite { .. }]
                        ),
                        "{name}: {outputs:?}"
                    ),
                }
            }
            Some("close") => {
                let code = u16::try_from(line["code"].as_u64().unwrap()).unwrap();
                let outputs = harness.close(code, line["reason"].as_str().unwrap_or_default());
                let expected = line["expect"].as_str().unwrap();
                let actual = match state(&outputs) {
                    Some(AttachState::Closed {
                        reason: ClosedReason::TerminalEnded { .. },
                    }) => "terminal_ended",
                    Some(AttachState::Closed {
                        reason: ClosedReason::Detached { .. },
                    }) => "detached",
                    Some(AttachState::Closed { .. }) => "server_closed",
                    Some(AttachState::Reconnecting { .. }) => "reconnecting",
                    Some(AttachState::Failed { .. }) => "failed",
                    other => panic!("{name}: unexpected state {other:?}"),
                };
                assert_eq!(actual, expected, "{name}");
            }
            other => panic!("{name}: direction {other:?}"),
        }
    }
    assert_eq!(saw_output, expect_output, "{name} pane output");
}

#[test]
fn replays_the_recorded_shell_session() {
    replay("recorded-attach-shell-echo.jsonl", true);
}

#[test]
fn replays_the_recorded_exit_close() {
    replay("recorded-attach-exit.jsonl", true);
}

#[test]
fn replays_the_recorded_repl_tui_session() {
    replay("recorded-attach-repl-tui.jsonl", true);
}

#[test]
fn replays_the_recorded_attach_to_a_deleted_terminal() {
    replay("recorded-attach-missing.jsonl", false);
}

use base64::Engine as _;
