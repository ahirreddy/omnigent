//! How each notice reads, for the ones a live attach cannot easily be made to produce.

use omnigent_protocol::remote_browser::HostError;

use super::core;
use super::*;
use crate::test_support::Harness;

fn message_of(notice: &core::Notice) -> (String, bool) {
    let described = describe(notice);
    (described.message, described.user_facing)
}

fn host_error(code: &str, text: &str) -> core::Notice {
    core::Notice::HostError(HostError {
        code: code.to_owned(),
        message: text.to_owned(),
        fatal: false,
    })
}

#[test]
fn host_errors_a_user_can_act_on_read_as_sentences() {
    assert_eq!(
        message_of(&host_error("navigation_failed", "dns")),
        ("The page could not be loaded: dns".to_owned(), true)
    );
    assert_eq!(
        message_of(&host_error("unsupported", "not on this host")),
        ("Not on this host.".to_owned(), true)
    );
    assert_eq!(
        message_of(&host_error("unsupported", "Done.")),
        ("Done.".to_owned(), true)
    );
    assert_eq!(
        message_of(&host_error("unsupported", "")),
        (".".to_owned(), true)
    );
    assert_eq!(
        message_of(&host_error("control_not_permitted", "x")),
        ("This browser tab is view-only.".to_owned(), true)
    );
    assert_eq!(
        message_of(&host_error("not_in_control", "x")),
        ("Take over to control the page.".to_owned(), true)
    );
    assert_eq!(
        message_of(&host_error("internal", "boom")),
        ("browser host error internal: boom".to_owned(), false)
    );
}

#[test]
fn dropped_input_says_what_and_why() {
    let dropped = |input, reason| message_of(&core::Notice::InputDropped { input, reason });
    assert_eq!(
        dropped(core::InputKind::Key, core::DropReason::ReadOnly),
        ("This browser tab is view-only.".to_owned(), true)
    );
    assert_eq!(
        dropped(core::InputKind::Mouse, core::DropReason::NotAttached),
        (
            "mouse input not sent: the browser is not connected".to_owned(),
            false
        )
    );
    for (input, name) in [
        (core::InputKind::Mouse, "mouse input"),
        (core::InputKind::Key, "key input"),
        (core::InputKind::Ime, "text input"),
        (core::InputKind::Nav, "navigation"),
        (core::InputKind::Resize, "resize"),
        (core::InputKind::DialogReply, "dialog reply"),
        (core::InputKind::Control, "control request"),
        (core::InputKind::Settings, "settings change"),
        (core::InputKind::Still, "still request"),
        (core::InputKind::Edit, "edit command"),
        (core::InputKind::Touch, "touch input"),
        (core::InputKind::MobileEmulation, "mobile emulation"),
    ] {
        assert_eq!(
            dropped(input, core::DropReason::NotInControl),
            (format!("{name} not sent: take control first"), true)
        );
        assert_eq!(
            dropped(input, core::DropReason::Unsupported),
            (
                format!(
                    "The agent's browser is too old for {name}; update it on the agent's machine."
                ),
                true
            )
        );
    }
}

#[test]
fn diagnostics_stay_out_of_the_users_way() {
    let malformed =
        core::Notice::VideoDropped(core::VideoDrop::Malformed(core::CodecError::NotAnnexB));
    let (message, user_facing) = message_of(&malformed);
    assert!(
        message.starts_with("dropped an unreadable video frame"),
        "{message}"
    );
    assert!(!user_facing);
    let (message, user_facing) = message_of(&core::Notice::InvalidInput(
        core::input::InputError::NotFinite { field: "x" },
    ));
    assert_eq!(message, "invalid browser input: x must be a finite number");
    assert!(!user_facing);
}

/// A loop nothing runs yet, over a connected harness's fakes.
fn idle_loop(harness: &Harness) -> (Loop, UnboundedReceiver<Msg>) {
    let (tx, rx) = mpsc::unbounded();
    let (wake, _woken) = mpsc::unbounded::<()>();
    let target = Target {
        session_id: "conv_a".into(),
        tab_id: "btab_7f3a9c2e".into(),
        options: core::AttachOptions {
            mode: wire::AttachMode::Control,
            slice_key: None,
        },
    };
    let attach = Loop {
        machine: core::RemoteBrowserAttach::new(
            core::AttachConfig::default(),
            target.options.clone(),
            SplitMix64::new(1),
        ),
        sessions: Arc::clone(&harness.core.inner.sessions),
        host: harness.core.inner.host.clone(),
        transport: Some(harness.sockets.clone()),
        listener: Arc::new(crate::remote_browser_tests::Recorder::default()),
        target,
        tx,
        sockets: HashMap::new(),
        timers: HashMap::new(),
        video: Arc::new(VideoPipe {
            queue: Mutex::new(core::VideoQueue::new(VIDEO_QUEUE_FRAMES)),
            armed: AtomicBool::new(false),
            wake,
        }),
        state_dirty: false,
    };
    (attach, rx)
}

#[test]
fn a_binary_frame_goes_out_as_binary() {
    let mut harness = crate::test_support::connected();
    let (mut attach, _queue) = idle_loop(&harness);
    let attempt = AttemptId(1);
    let options = attach.target.options.clone();
    attach.output(core::AttachOutput::Connect { attempt, options });
    attach.output(core::AttachOutput::Send {
        attempt,
        message: SocketMessage::Binary(vec![1, 2]),
    });
    harness.pump();
    let (_, _, socket) = harness.sockets.last();
    assert_eq!(*crate::engine::lock(&socket.sent_binary), [vec![1, 2]]);
}

#[test]
fn shutting_down_stops_a_timer_the_machine_left_behind() {
    let harness = crate::test_support::connected();
    let (mut attach, queue) = idle_loop(&harness);
    let (timer, _registration) = AbortHandle::new_pair();
    attach.timers.insert(99, timer.clone());
    attach.tx.unbounded_send(Msg::Shutdown).unwrap();
    futures::executor::block_on(attach.run(queue));
    assert!(timer.is_aborted());
}
