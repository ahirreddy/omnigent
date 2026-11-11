//! List-row edits end to end over a scripted transport: what the list is told and when, which
//! requests leave and in what order, and how a refusal, a lost link and a removal end.

use std::pin::pin;

use futures::executor::block_on;
use serde_json::json;

use super::super::requests::FailedWrite;
use super::super::sessions::SessionChange;
use super::super::test_support::{
    LOCAL, Recorder, Reply, RouteTransport, cache_row, connected, lines_after_connect, record,
    still_pending,
};
use super::super::{ClientCore, ClientEvent, SessionError, lock};
use super::Step;
use crate::auth::endpoint::ServerEndpoint;
use crate::http::TransportError;
use crate::intents::{IntentTimer, IntentTimerKind, SessionPatch, WritePolicy};
use crate::realtime::{ConnectionState, LinkError};
use crate::sessions::SessionSummary;

const PATH: &str = "/v1/sessions/conv_a";
const PATCH: &str = "PATCH /v1/sessions/conv_a";

/// A list row as the server sends it.
fn wire(id: &str, title: &str, pin: Option<&str>, archived: bool) -> String {
    let labels = pin.map_or_else(|| json!({}), |stamp| json!({"omnigent.pinned": stamp}));
    json!({
        "id": id,
        "title": title,
        "status": "idle",
        "created_at": 1,
        "permission_level": 4,
        "labels": labels,
        "archived": archived,
    })
    .to_string()
}

fn row(id: &str, title: &str) -> String {
    wire(id, title, None, false)
}

fn ok(body: String) -> Reply {
    Reply::json(200, body)
}

fn refusal() -> Reply {
    Reply::json(403, "{}")
}

fn offline() -> TransportError {
    TransportError::Offline {
        message: "Could not connect to the server.".into(),
    }
}

fn rename(title: &str) -> SessionChange {
    SessionChange::Title(title.to_owned())
}

fn archive(archived: bool) -> SessionChange {
    SessionChange::Archived {
        archived,
        delete_worktree: false,
    }
}

fn pin(at_ms: u64) -> SessionChange {
    SessionChange::Pinned {
        pinned: true,
        at_ms,
    }
}

fn reconnecting(failures: u32) -> ConnectionState {
    ConnectionState::Reconnecting {
        reason: LinkError::EndOfStream,
        failures,
        delay_ms: 0,
    }
}

/// A core connected over `transport` with `conv_a` cached as "Old", and its recorder.
fn with_row(transport: RouteTransport) -> (ClientCore<RouteTransport>, std::sync::Arc<Recorder>) {
    let core = connected(transport);
    cache_row(&core, &row("conv_a", "Old"));
    let recorder = record(&core);
    (core, recorder)
}

fn label(row: &SessionSummary) -> String {
    let pin = row
        .pin_stamp
        .as_ref()
        .map_or_else(String::new, |stamp| format!(" pin={stamp}"));
    let archived = if row.is_archived { " archived" } else { "" };
    format!("{}:{}{pin}{archived}", row.id, row.title)
}

/// What the list and the host were told since the last call, in order.
fn told(recorder: &Recorder) -> Vec<String> {
    recorder
        .take()
        .into_iter()
        .filter_map(|event| match event {
            ClientEvent::SessionsChanged { sessions } => {
                Some(sessions.iter().map(label).collect::<Vec<_>>().join(", "))
            }
            ClientEvent::SessionsRemoved { ids } => Some(format!("removed {}", ids.join(", "))),
            ClientEvent::IntentTimerRequested { timer } => Some(format!("{:?} timer", timer.kind)),
            _ => None,
        })
        .collect()
}

/// The timer the host was last asked for; the events stay for [`told`].
fn requested_timer(recorder: &Recorder) -> IntentTimer {
    recorder
        .events
        .lock()
        .unwrap()
        .iter()
        .rev()
        .find_map(|event| match event {
            ClientEvent::IntentTimerRequested { timer } => Some(*timer),
            _ => None,
        })
        .unwrap()
}

fn nothing_pending(core: &ClientCore<RouteTransport>) -> bool {
    lock(&core.state).intents.is_empty()
}

fn no_lines() -> Vec<String> {
    Vec::new()
}

#[test]
fn an_edit_shows_on_its_row_before_any_request_is_made() {
    let (core, recorder) = with_row(RouteTransport::local());

    let planned = core.plan_edits(vec![("conv_a".to_owned(), rename("  New  "))]);

    assert_eq!(told(&recorder), ["conv_a:New"]);
    assert_eq!(lines_after_connect(&core), no_lines());
    // The cache keeps the server's row; only what the list shows carries the edit.
    assert_eq!(core.cached_summary("conv_a").unwrap().title, "Old");

    // A caller that never sends it takes the edit back.
    drop(planned);
    assert_eq!(told(&recorder), ["conv_a:Old"]);
    assert!(nothing_pending(&core));
}

#[test]
fn an_accepted_edit_is_held_over_older_rows_until_the_timer() {
    let transport = RouteTransport::local();
    transport.respond(Some("PATCH"), PATH, None, ok(row("conv_a", "New")));
    transport.ok(
        "/v1/sessions",
        format!(r#"{{"data":[{}],"has_more":false}}"#, row("conv_a", "Old")),
    );
    let gate = transport.gate("PATCH", PATH);
    let (core, recorder) = with_row(transport);

    let mut edit = pin!(core.edit_session("conv_a", rename("New")));
    assert!(still_pending(edit.as_mut()));
    assert_eq!(told(&recorder), ["conv_a:New"]);
    assert_eq!(lines_after_connect(&core), [PATCH]);
    // A full reload while the write is out still shows the edit.
    let reloaded = block_on(core.session_page(None, 50)).unwrap();
    assert_eq!(reloaded.sessions[0].title, "New");

    gate.open();
    assert_eq!(block_on(edit).unwrap().title, "New");
    let hold = requested_timer(&recorder);
    assert_eq!(hold.kind, IntentTimerKind::Hold);
    assert_eq!(told(&recorder), ["Hold timer", "conv_a:New"]);

    // A list row read before the write arrives after its answer: the old title is masked.
    cache_row(&core, &row("conv_a", "Old"));
    assert_eq!(told(&recorder), ["conv_a:New"]);
    assert_eq!(core.cached_summary("conv_a").unwrap().title, "Old");
    // Another field of that row passes through.
    cache_row(&core, &wire("conv_a", "Old", Some("7"), false));
    assert_eq!(told(&recorder), ["conv_a:New pin=7"]);
    let reloaded = block_on(core.session_page(None, 50)).unwrap();
    assert_eq!(reloaded.sessions[0].title, "New");

    // The hold ends with the timer, and the server's row shows again.
    core.intent_timer_elapsed(hold);
    assert_eq!(told(&recorder), ["conv_a:Old"]);
    assert!(nothing_pending(&core));
    core.intent_timer_elapsed(hold);
    assert_eq!(told(&recorder), no_lines());
}

#[test]
fn a_server_row_that_agrees_ends_the_hold_early() {
    let transport = RouteTransport::local();
    transport.respond(Some("PATCH"), PATH, None, ok(row("conv_a", "New")));
    let (core, recorder) = with_row(transport);
    block_on(core.edit_session("conv_a", rename("New"))).unwrap();
    assert!(!nothing_pending(&core));

    cache_row(&core, &row("conv_a", "New"));
    assert!(nothing_pending(&core));
    // From here a different title is someone else's rename, and it shows.
    cache_row(&core, &row("conv_a", "Theirs"));
    assert_eq!(
        told(&recorder),
        [
            "conv_a:New",
            "Hold timer",
            "conv_a:New",
            "conv_a:New",
            "conv_a:Theirs"
        ]
    );
}

#[test]
fn an_answer_that_says_something_else_shows_at_once() {
    let transport = RouteTransport::local();
    transport.respond(Some("PATCH"), PATH, None, ok(row("conv_a", "Server's")));
    let (core, recorder) = with_row(transport);

    let answered = block_on(core.edit_session("conv_a", rename("New"))).unwrap();

    assert_eq!(answered.title, "Server's");
    assert_eq!(told(&recorder), ["conv_a:New", "conv_a:Server's"]);
    assert!(nothing_pending(&core));
}

#[test]
fn a_refused_edit_puts_the_row_back() {
    let transport = RouteTransport::local();
    transport.respond(Some("PATCH"), PATH, None, refusal());
    let (core, recorder) = with_row(transport);

    assert_eq!(
        block_on(core.edit_session("conv_a", rename("New"))),
        Err(SessionError::ReadOnly)
    );

    assert_eq!(told(&recorder), ["conv_a:New", "conv_a:Old"]);
    assert_eq!(lines_after_connect(&core), [PATCH]);
    assert!(nothing_pending(&core));
}

#[test]
fn a_caller_that_goes_away_mid_write_puts_the_row_back() {
    let transport = RouteTransport::local();
    let _gate = transport.gate("PATCH", PATH);
    let (core, recorder) = with_row(transport);
    {
        let mut edit = pin!(core.edit_session("conv_a", rename("New")));
        assert!(still_pending(edit.as_mut()));
    }
    assert_eq!(told(&recorder), ["conv_a:New", "conv_a:Old"]);
    assert!(nothing_pending(&core));
}

#[test]
fn a_write_lost_while_the_link_came_back_is_sent_once_more_at_once() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "PATCH",
        PATH,
        vec![Reply::Fail(offline()), ok(row("conv_a", "New"))],
    );
    let gate = transport.gate("PATCH", PATH);
    let (core, recorder) = with_row(transport);
    core.updates_link_changed(&ConnectionState::Live);

    let mut edit = pin!(core.edit_session("conv_a", rename("New")));
    assert!(still_pending(edit.as_mut()));
    // A healthy link that drops reconnects at once: nothing is refused meanwhile.
    core.updates_link_changed(&reconnecting(0));
    core.updates_link_changed(&ConnectionState::Live);
    gate.open();

    assert_eq!(block_on(edit).unwrap().title, "New");
    assert_eq!(lines_after_connect(&core), [PATCH; 2]);
    assert_eq!(told(&recorder), ["conv_a:New", "Hold timer", "conv_a:New"]);
}

#[test]
fn a_write_lost_with_the_link_waits_for_it_and_is_sent_once_more() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "PATCH",
        PATH,
        vec![
            Reply::Fail(TransportError::Other {
                message: "The network connection was lost.".into(),
            }),
            ok(row("conv_a", "New")),
        ],
    );
    let (core, recorder) = with_row(transport);
    core.updates_link_changed(&ConnectionState::Live);

    let mut edit = pin!(core.edit_session("conv_a", rename("New")));
    assert!(still_pending(edit.as_mut()));
    assert_eq!(requested_timer(&recorder).kind, IntentTimerKind::Unclear);
    assert_eq!(told(&recorder), ["conv_a:New", "Unclear timer"]);
    // A later edit of that session waits behind the one whose outcome is unknown.
    let mut later = pin!(core.edit_session("conv_a", pin(5)));
    assert!(still_pending(later.as_mut()));
    assert_eq!(lines_after_connect(&core), [PATCH]);

    core.updates_link_changed(&ConnectionState::Live);

    assert_eq!(block_on(edit).unwrap().title, "New");
    assert_eq!(lines_after_connect(&core), [PATCH; 2]);
}

#[test]
fn a_write_lost_twice_is_reported_and_the_row_goes_back() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "PATCH",
        PATH,
        vec![Reply::Fail(offline()), Reply::Fail(offline())],
    );
    let (core, recorder) = with_row(transport);
    core.updates_link_changed(&ConnectionState::Live);
    let mut edit = pin!(core.edit_session("conv_a", rename("New")));
    assert!(still_pending(edit.as_mut()));

    core.updates_link_changed(&ConnectionState::Live);

    assert_eq!(block_on(edit), Err(SessionError::Transport(offline())));
    assert_eq!(lines_after_connect(&core), [PATCH; 2]);
    assert_eq!(
        told(&recorder),
        ["conv_a:New", "Unclear timer", "conv_a:Old"]
    );
    assert!(nothing_pending(&core));
}

#[test]
fn a_write_lost_with_a_link_that_stays_down_gives_up_with_the_timer() {
    let transport = RouteTransport::local();
    transport.enqueue("PATCH", PATH, vec![Reply::Fail(offline())]);
    let (core, recorder) = with_row(transport);
    core.updates_link_changed(&ConnectionState::Live);
    let mut edit = pin!(core.edit_session("conv_a", rename("New")));
    assert!(still_pending(edit.as_mut()));
    let unclear = requested_timer(&recorder);

    core.intent_timer_elapsed(unclear);

    assert_eq!(block_on(edit), Err(SessionError::Transport(offline())));
    assert_eq!(lines_after_connect(&core), [PATCH]);
    assert_eq!(
        told(&recorder),
        ["conv_a:New", "Unclear timer", "conv_a:Old"]
    );
    assert!(nothing_pending(&core));
}

#[test]
fn only_a_replayable_write_lost_with_the_link_goes_again() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "PATCH",
        PATH,
        vec![Reply::Fail(TransportError::Timeout {
            message: "The request timed out.".into(),
        })],
    );
    let (core, recorder) = with_row(transport);
    core.updates_link_changed(&ConnectionState::Live);

    // A timeout may have reached the server while the link stayed up: reported, not resent.
    assert!(matches!(
        block_on(core.edit_session("conv_a", rename("New"))),
        Err(SessionError::DeliveryUncertain { .. })
    ));
    assert_eq!(lines_after_connect(&core), [PATCH]);
    assert_eq!(told(&recorder), ["conv_a:New", "conv_a:Old"]);

    // A write that must not repeat is reported even when the link was lost under it.
    let step = {
        let mut state = lock(&core.state);
        core.begin(
            &mut state,
            "conv_a",
            SessionPatch::Title("Once".into()),
            WritePolicy::AtMostOnce,
        )
    };
    let Ok(Step::Send(mut lane)) = step else {
        panic!("recorded");
    };
    let lost = |_retried: bool| async {
        Err::<(), _>(FailedWrite {
            error: SessionError::Offline,
            link_lost: true,
        })
    };
    assert!(matches!(
        block_on(lane.send(lost)),
        Err(SessionError::Offline)
    ));
    drop(lane);
    assert!(nothing_pending(&core));
}

#[test]
fn two_edits_of_one_session_leave_in_the_order_made() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "PATCH",
        PATH,
        vec![
            ok(row("conv_a", "New")),
            ok(wire("conv_a", "New", Some("5"), false)),
        ],
    );
    let gate = transport.gate("PATCH", PATH);
    let (core, recorder) = with_row(transport);

    let mut renamed = pin!(core.edit_session("conv_a", rename("New")));
    let mut pinned = pin!(core.edit_session("conv_a", pin(5)));
    assert!(still_pending(renamed.as_mut()));
    assert!(still_pending(pinned.as_mut()));
    // Both show; only the first has left.
    assert_eq!(told(&recorder), ["conv_a:New", "conv_a:New pin=5"]);
    assert_eq!(lines_after_connect(&core), [PATCH]);

    gate.open();
    assert!(still_pending(pinned.as_mut()));
    assert_eq!(lines_after_connect(&core), [PATCH]);
    block_on(renamed).unwrap();
    assert_eq!(block_on(pinned).unwrap().pin_stamp.as_deref(), Some("5"));
    assert_eq!(
        core.transport().write_bodies(),
        vec![
            json!({"title": "New"}),
            json!({"labels": {"omnigent.pinned": "5"}}),
        ]
    );
}

#[test]
fn a_waiting_edit_is_replaced_by_a_later_one_for_its_field() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "PATCH",
        PATH,
        vec![ok(row("conv_a", "One")), ok(row("conv_a", "Three"))],
    );
    let gate = transport.gate("PATCH", PATH);
    let (core, _recorder) = with_row(transport);
    let mut first = pin!(core.edit_session("conv_a", rename("One")));
    assert!(still_pending(first.as_mut()));
    let mut second = pin!(core.edit_session("conv_a", rename("Two")));
    assert!(still_pending(second.as_mut()));
    let mut third = pin!(core.edit_session("conv_a", rename("Three")));
    assert!(still_pending(third.as_mut()));

    // The replaced edit ends without a request, with the row as the later one left it.
    assert_eq!(block_on(second).unwrap().title, "Three");
    assert_eq!(lines_after_connect(&core), [PATCH]);

    gate.open();
    block_on(first).unwrap();
    assert_eq!(block_on(third).unwrap().title, "Three");
    assert_eq!(
        core.transport().write_bodies(),
        vec![json!({"title": "One"}), json!({"title": "Three"})]
    );
}

#[test]
fn an_archive_undone_before_it_left_makes_no_request() {
    let transport = RouteTransport::local();
    transport.respond(Some("PATCH"), PATH, None, ok(row("conv_a", "New")));
    let gate = transport.gate("PATCH", PATH);
    let (core, recorder) = with_row(transport);
    let mut renamed = pin!(core.edit_session("conv_a", rename("New")));
    assert!(still_pending(renamed.as_mut()));
    let mut archived = pin!(core.edit_session("conv_a", archive(true)));
    assert!(still_pending(archived.as_mut()));
    assert_eq!(told(&recorder), ["conv_a:New", "conv_a:New archived"]);

    let undone = block_on(core.edit_session("conv_a", archive(false))).unwrap();

    assert!(!undone.is_archived);
    assert_eq!(told(&recorder), ["conv_a:New"]);
    assert!(!block_on(archived).unwrap().is_archived);
    gate.open();
    block_on(renamed).unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        vec![json!({"title": "New"})]
    );
}

#[test]
fn a_session_removed_mid_flight_ends_its_edits() {
    let transport = RouteTransport::local();
    let gate = transport.gate("PATCH", PATH);
    let (core, recorder) = with_row(transport);
    let mut renamed = pin!(core.edit_session("conv_a", rename("New")));
    assert!(still_pending(renamed.as_mut()));
    let mut pinned = pin!(core.edit_session("conv_a", pin(5)));
    assert!(still_pending(pinned.as_mut()));

    core.remove_sessions(&["conv_a".to_owned()]);

    let gone = SessionError::SessionNotFound {
        session_id: "conv_a".into(),
    };
    assert_eq!(block_on(pinned), Err(gone.clone()));
    gate.open();
    // The write that was out is answered `404` by the unstubbed route.
    assert_eq!(block_on(renamed), Err(gone));
    assert_eq!(lines_after_connect(&core), [PATCH]);
    assert_eq!(
        told(&recorder),
        ["conv_a:New", "conv_a:New pin=5", "removed conv_a"]
    );
    assert!(nothing_pending(&core));
}

#[test]
fn a_batch_shows_in_one_list_change_and_its_writes_run_side_by_side() {
    let transport = RouteTransport::local();
    let mut gates = Vec::new();
    for (id, reply) in [
        ("a", ok(wire("a", "A", None, true))),
        ("b", refusal()),
        ("c", ok(wire("c", "C", None, true))),
    ] {
        let path = format!("/v1/sessions/{id}");
        transport.respond(Some("PATCH"), &path, None, reply);
        gates.push(transport.gate("PATCH", &path));
    }
    let core = connected(transport);
    for id in ["a", "b", "c"] {
        cache_row(&core, &row(id, &id.to_uppercase()));
    }
    // A row the caller may not archive is refused on its own.
    cache_row(
        &core,
        r#"{"id":"d","title":"D","status":"idle","created_at":1,"permission_level":1}"#,
    );
    let recorder = record(&core);
    let edits = ["a", "b", "c", "d"]
        .map(|id| (id.to_owned(), archive(true)))
        .to_vec();

    let mut batch = pin!(core.edit_sessions(edits));
    assert!(still_pending(batch.as_mut()));

    assert_eq!(
        told(&recorder),
        ["a:A archived, b:B archived, c:C archived"]
    );
    assert_eq!(
        lines_after_connect(&core),
        [
            "PATCH /v1/sessions/a",
            "PATCH /v1/sessions/b",
            "PATCH /v1/sessions/c"
        ]
    );
    for gate in &gates {
        gate.open();
    }
    let results = block_on(batch);
    assert_eq!(
        results
            .iter()
            .map(|result| result.as_ref().map(|row| row.is_archived))
            .collect::<Vec<_>>(),
        [
            Ok(true),
            Err(&SessionError::ReadOnly),
            Ok(true),
            Err(&SessionError::ReadOnly)
        ]
    );
    // Only the refused row goes back.
    assert_eq!(
        told(&recorder),
        [
            "Hold timer",
            "a:A archived",
            "b:B",
            "Hold timer",
            "c:C archived"
        ]
    );
}

#[test]
fn edits_are_refused_while_the_link_is_known_down() {
    let transport = RouteTransport::local();
    transport.respond(Some("PATCH"), PATH, None, ok(row("conv_a", "New")));
    let (core, recorder) = with_row(transport);
    let down = [
        reconnecting(1),
        ConnectionState::Failed {
            error: LinkError::EndOfStream,
        },
    ];
    for state in down {
        core.updates_link_changed(&state);
        assert_eq!(
            block_on(core.edit_session("conv_a", rename("New"))),
            Err(SessionError::Offline),
            "{state:?}"
        );
        assert_eq!(
            block_on(core.edit_sessions(vec![("conv_a".to_owned(), archive(true))])),
            [Err(SessionError::Offline)]
        );
        assert_eq!(
            block_on(core.delete_session("conv_a")),
            Err(SessionError::Offline)
        );
        assert_eq!(
            block_on(core.leave_session("conv_a")),
            Err(SessionError::Offline)
        );
        // The states a link passes through on its way back change nothing.
        for passing in [
            ConnectionState::Idle,
            ConnectionState::Connecting,
            ConnectionState::Closed,
            ConnectionState::Stopped,
            reconnecting(0),
        ] {
            core.updates_link_changed(&passing);
        }
        assert_eq!(
            block_on(core.edit_session("conv_a", rename("New"))),
            Err(SessionError::Offline)
        );
        core.updates_link_changed(&ConnectionState::Live);
        block_on(core.edit_session("conv_a", rename("New"))).unwrap();
        cache_row(&core, &row("conv_a", "Old"));
        core.intent_timer_elapsed(requested_timer(&recorder));
    }
    // Nothing was shown, sent or kept for the refused ones.
    assert_eq!(lines_after_connect(&core), [PATCH; 2]);

    // A new connection starts with its link unreported.
    core.updates_link_changed(&reconnecting(1));
    block_on(core.connect(ServerEndpoint::new(LOCAL).unwrap(), None, None)).unwrap();
    block_on(core.edit_session("conv_a", rename("New"))).unwrap();
}

#[test]
fn an_edit_outlived_by_its_connection_is_not_sent() {
    let transport = RouteTransport::local();
    transport.respond(Some("PATCH"), PATH, None, ok(row("conv_a", "New")));
    let gate = transport.gate("PATCH", PATH);
    let (core, recorder) = with_row(transport);
    let mut renamed = pin!(core.edit_session("conv_a", rename("New")));
    assert!(still_pending(renamed.as_mut()));
    let mut pinned = pin!(core.edit_session("conv_a", pin(5)));
    assert!(still_pending(pinned.as_mut()));
    assert_eq!(told(&recorder), ["conv_a:New", "conv_a:New pin=5"]);

    core.disconnect();
    // Without a connection there is no account whose edits could apply.
    cache_row(&core, &row("conv_a", "Old"));
    assert_eq!(told(&recorder), ["conv_a:Old"]);

    gate.open();
    assert!(matches!(
        block_on(renamed),
        Err(SessionError::DeliveryUncertain { .. })
    ));
    assert_eq!(block_on(pinned), Err(SessionError::NotConnected));
    assert_eq!(core.transport().writes().len(), 1);
    assert_eq!(told(&recorder), no_lines());
    assert!(nothing_pending(&core));
}

#[test]
fn a_delete_hides_the_row_at_once_and_forgets_it_when_the_server_has() {
    let transport = RouteTransport::local();
    transport.respond(Some("DELETE"), PATH, None, Reply::json(204, ""));
    let gate = transport.gate("DELETE", PATH);
    let (core, recorder) = with_row(transport);

    let mut deleted = pin!(core.delete_session("conv_a"));
    assert!(still_pending(deleted.as_mut()));

    assert_eq!(told(&recorder), ["removed conv_a"]);
    // The server's row stays cached until the server answers; a reload leaves it out.
    assert!(core.cached_summary("conv_a").is_some());
    core.transport().ok(
        "/v1/sessions",
        format!(r#"{{"data":[{}],"has_more":false}}"#, row("conv_a", "Old")),
    );
    assert_eq!(block_on(core.session_page(None, 50)).unwrap().sessions, []);
    cache_row(&core, &row("conv_a", "Old"));
    assert_eq!(told(&recorder), no_lines());

    gate.open();
    block_on(deleted).unwrap();
    assert_eq!(core.cached_summary("conv_a"), None);
    assert_eq!(told(&recorder), ["removed conv_a"]);
    assert!(nothing_pending(&core));
}

#[test]
fn a_refused_delete_or_leave_brings_the_row_back() {
    let transport = RouteTransport::local();
    transport.respond(Some("DELETE"), PATH, None, refusal());
    transport.respond(
        Some("DELETE"),
        "/v1/sessions/conv_a/permissions/local",
        None,
        Reply::json(400, r#"{"detail":"The owner cannot leave."}"#),
    );
    let (core, recorder) = with_row(transport);

    assert_eq!(
        block_on(core.delete_session("conv_a")),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(told(&recorder), ["removed conv_a", "conv_a:Old"]);

    assert_eq!(
        block_on(core.leave_session("conv_a")),
        Err(SessionError::Rejected {
            status: 400,
            message: "The owner cannot leave.".into()
        })
    );
    assert_eq!(told(&recorder), ["removed conv_a", "conv_a:Old"]);
    assert!(core.cached_summary("conv_a").is_some());
    assert!(nothing_pending(&core));
}

#[test]
fn a_delete_sent_twice_takes_not_found_the_second_time_as_done() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "DELETE",
        PATH,
        vec![Reply::Fail(offline()), Reply::json(404, "{}")],
    );
    let (core, recorder) = with_row(transport);
    core.updates_link_changed(&ConnectionState::Live);
    let mut deleted = pin!(core.delete_session("conv_a"));
    assert!(still_pending(deleted.as_mut()));
    assert_eq!(told(&recorder), ["removed conv_a", "Unclear timer"]);

    core.updates_link_changed(&ConnectionState::Live);

    block_on(deleted).unwrap();
    assert_eq!(core.cached_summary("conv_a"), None);
    assert_eq!(
        lines_after_connect(&core),
        ["DELETE /v1/sessions/conv_a"; 2]
    );
}

#[test]
fn a_delete_waits_for_the_edit_ahead_of_it_and_a_second_delete_replaces_a_waiting_one() {
    let transport = RouteTransport::local();
    transport.respond(Some("PATCH"), PATH, None, ok(row("conv_a", "New")));
    transport.respond(Some("DELETE"), PATH, None, Reply::json(204, ""));
    let gate = transport.gate("PATCH", PATH);
    let (core, recorder) = with_row(transport);
    let mut renamed = pin!(core.edit_session("conv_a", rename("New")));
    assert!(still_pending(renamed.as_mut()));
    let mut deleted = pin!(core.delete_session("conv_a"));
    assert!(still_pending(deleted.as_mut()));
    let mut again = pin!(core.delete_session("conv_a"));
    assert!(still_pending(again.as_mut()));
    assert_eq!(
        told(&recorder),
        ["conv_a:New", "removed conv_a", "removed conv_a"]
    );
    assert_eq!(lines_after_connect(&core), [PATCH]);

    // The replaced delete ends without a request of its own.
    block_on(deleted).unwrap();
    assert_eq!(lines_after_connect(&core), [PATCH]);

    gate.open();
    block_on(renamed).unwrap();
    // The rename's answer changes a hidden row, so the list hears nothing of it.
    assert_eq!(told(&recorder), ["Hold timer"]);
    block_on(again).unwrap();
    assert_eq!(
        lines_after_connect(&core),
        [PATCH, "DELETE /v1/sessions/conv_a"]
    );
    assert_eq!(core.cached_summary("conv_a"), None);
}

#[test]
fn a_removal_with_nothing_to_send_makes_no_request() {
    let (core, _recorder) = with_row(RouteTransport::local());
    let shown = core.cached_summary("conv_a").unwrap();
    block_on(core.remove_hidden(Step::Unneeded(Box::new(shown)), PATH, &[])).unwrap();
    assert_eq!(lines_after_connect(&core), no_lines());
    assert!(core.cached_summary("conv_a").is_some());
}

#[test]
fn a_pin_move_shows_the_whole_order_at_once_and_a_refusal_puts_back_what_had_not_left() {
    let transport = RouteTransport::local();
    transport.respond(Some("PATCH"), "/v1/sessions/p2", None, refusal());
    let core = connected(transport);
    // Two pins share a key, so moving a third between them renumbers.
    for (id, stamp) in [("p0", "1"), ("p1", "1"), ("p2", "5")] {
        cache_row(&core, &wire(id, id, Some(stamp), false));
    }
    let recorder = record(&core);

    assert_eq!(
        block_on(core.move_pin("p2", "p1", 0)),
        Err(SessionError::ReadOnly)
    );

    assert_eq!(
        told(&recorder),
        ["p2:p2 pin=2, p1:p1 pin=3", "p2:p2 pin=5", "p1:p1 pin=1"]
    );
    // The moved pin's write is the only one that left.
    assert_eq!(lines_after_connect(&core), ["PATCH /v1/sessions/p2"]);
    assert!(nothing_pending(&core));
}

#[test]
fn a_pin_move_builds_on_the_order_the_list_shows() {
    let transport = RouteTransport::local();
    for id in ["p1", "loose"] {
        transport.respond(
            Some("PATCH"),
            &format!("/v1/sessions/{id}"),
            None,
            ok(row(id, id)),
        );
    }
    let gate = transport.gate("PATCH", "/v1/sessions/p1");
    let core = connected(transport);
    cache_row(&core, &wire("p0", "p0", Some("1000"), false));
    cache_row(&core, &wire("p1", "p1", Some("2000"), false));
    cache_row(&core, &row("loose", "loose"));

    let mut first = pin!(core.move_pin("p1", "p0", 0));
    assert!(still_pending(first.as_mut()));
    // The first move is still out: the second lands ahead of where it shows.
    block_on(core.move_pin("loose", "p1", 0)).unwrap();
    gate.open();
    block_on(first).unwrap();

    assert_eq!(
        core.transport().write_bodies(),
        vec![
            json!({"labels": {"omnigent.pinned": "999"}}),
            json!({"labels": {"omnigent.pinned": "998"}}),
        ]
    );
}
