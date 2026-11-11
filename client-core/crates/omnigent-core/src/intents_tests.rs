use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::task::{Wake, Waker};

use super::*;

const SCOPE: &str = "https://omni.example|user_a";

/// Counts how often a waiting caller was woken.
#[derive(Default)]
struct Wakes(AtomicUsize);

impl Wake for Wakes {
    fn wake(self: Arc<Self>) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

fn waker() -> (Arc<Wakes>, Waker) {
    let wakes = Arc::new(Wakes::default());
    (Arc::clone(&wakes), Waker::from(wakes))
}

fn woken(wakes: &Wakes) -> usize {
    wakes.0.load(Ordering::SeqCst)
}

fn row(id: &str) -> SessionSummary {
    SessionSummary::new(id, "Old", "")
}

fn title(text: &str) -> SessionPatch {
    SessionPatch::Title(text.to_owned())
}

fn pin(stamp: &str) -> SessionPatch {
    SessionPatch::Pin(Some(stamp.to_owned()))
}

/// Session `a`'s row as the server answers a write of `patch` that it took as asked.
fn agreed(patch: &SessionPatch) -> SessionSummary {
    let mut answered = row("a");
    patch.apply(&mut answered);
    answered
}

/// Records `patch` for session `a` and returns its id.
fn recorded(ledger: &mut IntentLedger, patch: SessionPatch) -> IntentId {
    match ledger.begin(SCOPE, "a", patch, Some(&row("a"))) {
        Begun::Recorded(id) => id,
        Begun::Unneeded(row) => panic!("unneeded: {row:?}"),
    }
}

/// Records `patch` for session `a` and takes its turn at once.
fn in_flight(ledger: &mut IntentLedger, patch: SessionPatch) -> IntentId {
    let id = recorded(ledger, patch);
    assert_eq!(ledger.turn(SCOPE, "a", id, Waker::noop()), Turn::Go);
    id
}

#[test]
fn each_patch_writes_its_field_and_knows_a_row_that_agrees() {
    let base = row("a");
    let mut pinned = base.clone();
    pin("7").apply(&mut pinned);
    assert!(pinned.is_pinned);
    assert_eq!(pinned.pin_stamp.as_deref(), Some("7"));
    assert!(pin("7").agrees_with(&pinned));
    assert!(!pin("7").agrees_with(&base));

    let mut unpinned = pinned.clone();
    SessionPatch::Pin(None).apply(&mut unpinned);
    assert_eq!(unpinned, base);
    assert!(SessionPatch::Pin(None).agrees_with(&base));

    // Archiving unpins, as the server does; restoring leaves the pin alone.
    let mut archived = pinned.clone();
    SessionPatch::Archived(true).apply(&mut archived);
    assert!(archived.is_archived && !archived.is_pinned && archived.pin_stamp.is_none());
    assert!(SessionPatch::Archived(true).agrees_with(&archived));
    // A row archived with its pin still on has not caught up with the archive.
    let mut half = pinned.clone();
    half.is_archived = true;
    assert!(!SessionPatch::Archived(true).agrees_with(&half));
    assert!(!SessionPatch::Archived(false).agrees_with(&half));
    let mut restored = archived;
    SessionPatch::Archived(false).apply(&mut restored);
    assert_eq!(restored, base);

    let filed = SessionPatch::Project(Some("proj_1".to_owned()));
    let mut moved = base.clone();
    moved.project_label = Some("Old folder".to_owned());
    filed.apply(&mut moved);
    assert_eq!(moved.project_id.as_deref(), Some("proj_1"));
    assert_eq!(moved.project_label, None);
    assert!(filed.agrees_with(&moved));
    // A row still carrying the legacy label has not caught up with the move.
    moved.project_label = Some("Old folder".to_owned());
    assert!(!filed.agrees_with(&moved));

    let mut renamed = base.clone();
    title("New").apply(&mut renamed);
    assert_eq!(renamed.title, "New");
    assert!(title("New").agrees_with(&renamed));

    let mut removed = base.clone();
    SessionPatch::Removed.apply(&mut removed);
    assert_eq!(removed, base);
    assert!(!SessionPatch::Removed.agrees_with(&base));
}

#[test]
fn a_recorded_intent_shows_on_the_row_before_anything_is_sent() {
    let mut ledger = IntentLedger::new();
    assert!(ledger.is_empty());
    let first = recorded(&mut ledger, title("New"));
    let second = recorded(&mut ledger, pin("7"));
    assert_ne!(first.get(), second.get());
    assert!(!ledger.is_empty());
    assert_eq!(ledger.state(SCOPE, "a", first), Some(IntentState::Queued));

    let shown = ledger.project(SCOPE, &row("a")).unwrap();
    assert_eq!(shown.title, "New");
    assert_eq!(shown.pin_stamp.as_deref(), Some("7"));
    assert_eq!(ledger.overlay(SCOPE, &row("a")), shown);
    // Another session, and the same session under another account, show the server's row.
    assert_eq!(ledger.project(SCOPE, &row("b")), Some(row("b")));
    assert_eq!(ledger.project("other", &row("a")), Some(row("a")));
    assert_eq!(ledger.overlay("other", &row("a")), row("a"));
    assert_eq!(ledger.state("other", "a", first), None);
}

#[test]
fn intents_of_one_session_take_their_turn_in_the_order_made() {
    let mut ledger = IntentLedger::new();
    let first = recorded(&mut ledger, title("New"));
    let second = recorded(&mut ledger, pin("7"));
    let (counter, waker) = waker();

    assert_eq!(ledger.turn(SCOPE, "a", second, &waker), Turn::Wait);
    assert_eq!(ledger.turn(SCOPE, "a", first, Waker::noop()), Turn::Go);
    assert_eq!(ledger.state(SCOPE, "a", first), Some(IntentState::InFlight));
    // Asking again while in flight is still a go: the retry after a lost write.
    assert_eq!(ledger.turn(SCOPE, "a", first, Waker::noop()), Turn::Go);
    assert_eq!(ledger.turn(SCOPE, "a", second, &waker), Turn::Wait);
    assert_eq!(woken(&counter), 0);

    assert!(ledger.confirm(SCOPE, "a", first, &agreed(&title("New"))));
    assert_eq!(woken(&counter), 1);
    assert_eq!(ledger.state(SCOPE, "a", first), Some(IntentState::Held));
    assert_eq!(ledger.turn(SCOPE, "a", second, &waker), Turn::Go);
    // Another session's lane does not wait for this one.
    let Begun::Recorded(other) = ledger.begin(SCOPE, "b", title("B"), Some(&row("b"))) else {
        panic!("recorded");
    };
    assert_eq!(ledger.turn(SCOPE, "b", other, Waker::noop()), Turn::Go);
}

#[test]
fn a_queued_intent_is_replaced_by_a_later_one_for_its_field() {
    let mut ledger = IntentLedger::new();
    in_flight(&mut ledger, title("New"));
    let earlier = recorded(&mut ledger, pin("7"));
    let (counter, waker) = waker();
    assert_eq!(ledger.turn(SCOPE, "a", earlier, &waker), Turn::Wait);

    let later = recorded(&mut ledger, pin("9"));

    assert_eq!(woken(&counter), 1);
    let mut shown = row("a");
    title("New").apply(&mut shown);
    pin("9").apply(&mut shown);
    assert_eq!(
        ledger.turn(SCOPE, "a", earlier, &waker),
        Turn::Left(Departure::Superseded(Box::new(shown.clone())))
    );
    assert_eq!(ledger.state(SCOPE, "a", later), Some(IntentState::Queued));
    assert_eq!(ledger.project(SCOPE, &row("a")), Some(shown));
    // The replaced intent's reason is read once.
    assert_eq!(
        ledger.turn(SCOPE, "a", earlier, &waker),
        Turn::Left(Departure::Gone)
    );
}

#[test]
fn putting_a_field_back_before_its_edit_left_drops_both() {
    let mut ledger = IntentLedger::new();
    let rename = in_flight(&mut ledger, title("New"));
    let archive = recorded(&mut ledger, SessionPatch::Archived(true));

    let undone = ledger.begin(SCOPE, "a", SessionPatch::Archived(false), Some(&row("a")));

    let mut shown = row("a");
    title("New").apply(&mut shown);
    assert_eq!(undone, Begun::Unneeded(Box::new(shown.clone())));
    assert_eq!(
        ledger.turn(SCOPE, "a", archive, Waker::noop()),
        Turn::Left(Departure::Superseded(Box::new(shown)))
    );
    // Only the rename is left, and the ledger empties once it goes.
    assert!(ledger.abandon(SCOPE, "a", rename));
    assert!(ledger.is_empty());
}

#[test]
fn an_edit_and_its_undo_alone_on_a_lane_leave_nothing_behind() {
    let mut ledger = IntentLedger::new();
    recorded(&mut ledger, SessionPatch::Archived(true));
    let undone = ledger.begin(SCOPE, "a", SessionPatch::Archived(false), Some(&row("a")));
    assert_eq!(undone, Begun::Unneeded(Box::new(row("a"))));
    assert!(ledger.is_empty());
}

#[test]
fn an_intent_for_a_row_that_is_not_cached_replaces_nothing() {
    let mut ledger = IntentLedger::new();
    let Begun::Recorded(first) = ledger.begin(SCOPE, "a", title("One"), None) else {
        panic!("recorded");
    };
    let Begun::Recorded(second) = ledger.begin(SCOPE, "a", title("Two"), None) else {
        panic!("recorded");
    };
    assert_eq!(ledger.state(SCOPE, "a", first), Some(IntentState::Queued));
    assert_eq!(ledger.state(SCOPE, "a", second), Some(IntentState::Queued));
}

#[test]
fn a_write_lost_with_the_link_waits_for_the_link_to_return() {
    let mut ledger = IntentLedger::new();
    let queued = recorded(&mut ledger, title("New"));
    // Only a write that left can be lost.
    assert!(!ledger.mark_unclear(SCOPE, "a", queued));
    assert!(!ledger.mark_unclear(SCOPE, "b", queued));
    assert_eq!(ledger.turn(SCOPE, "a", queued, Waker::noop()), Turn::Go);
    let behind = recorded(&mut ledger, pin("7"));

    assert!(ledger.mark_unclear(SCOPE, "a", queued));
    let (counter, waker) = waker();
    assert_eq!(ledger.turn(SCOPE, "a", queued, &waker), Turn::Wait);
    // The lane stays taken while the outcome is unknown.
    assert_eq!(ledger.turn(SCOPE, "a", behind, Waker::noop()), Turn::Wait);

    ledger.link_returned();
    assert_eq!(woken(&counter), 1);
    assert_eq!(ledger.turn(SCOPE, "a", queued, &waker), Turn::Go);
}

#[test]
fn an_accepted_intent_is_held_ahead_of_the_ones_still_owed_a_write() {
    let mut ledger = IntentLedger::new();
    let first = in_flight(&mut ledger, title("One"));
    assert!(ledger.confirm(SCOPE, "a", first, &agreed(&title("One"))));
    let second = in_flight(&mut ledger, title("Two"));
    let third = recorded(&mut ledger, pin("7"));

    assert!(ledger.confirm(SCOPE, "a", second, &agreed(&title("Two"))));

    // The newer accepted title replaces the older held one; the queued pin still applies.
    assert_eq!(ledger.state(SCOPE, "a", first), None);
    assert_eq!(ledger.state(SCOPE, "a", second), Some(IntentState::Held));
    let shown = ledger.project(SCOPE, &row("a")).unwrap();
    assert_eq!(shown.title, "Two");
    assert_eq!(shown.pin_stamp.as_deref(), Some("7"));
    assert_eq!(ledger.turn(SCOPE, "a", third, Waker::noop()), Turn::Go);
    // A held intent has no turn left to wait for, and neither it nor an unknown one confirms.
    assert_eq!(ledger.turn(SCOPE, "a", second, Waker::noop()), Turn::Wait);
    assert!(!ledger.confirm(SCOPE, "a", first, &row("a")));
    assert!(!ledger.confirm(SCOPE, "b", first, &row("a")));
}

#[test]
fn an_answer_that_says_something_else_is_shown_instead_of_held() {
    let mut ledger = IntentLedger::new();
    let older = in_flight(&mut ledger, title("One"));
    assert!(ledger.confirm(SCOPE, "a", older, &agreed(&title("One"))));
    let renamed = in_flight(&mut ledger, title("Two"));
    let behind = recorded(&mut ledger, pin("7"));
    let (counter, waker) = waker();
    assert_eq!(ledger.turn(SCOPE, "a", behind, &waker), Turn::Wait);

    // The server kept its own title: nothing masks it, the older hold included.
    assert!(!ledger.confirm(SCOPE, "a", renamed, &row("a")));

    assert_eq!(woken(&counter), 1);
    assert_eq!(ledger.state(SCOPE, "a", older), None);
    assert_eq!(ledger.state(SCOPE, "a", renamed), None);
    assert_eq!(ledger.project(SCOPE, &row("a")).unwrap().title, "Old");
    assert_eq!(ledger.turn(SCOPE, "a", behind, &waker), Turn::Go);
    assert!(ledger.abandon(SCOPE, "a", behind));
    assert!(ledger.is_empty());
}

#[test]
fn an_abandoned_intent_frees_the_lane_and_a_held_one_stays() {
    let mut ledger = IntentLedger::new();
    let held = in_flight(&mut ledger, title("One"));
    assert!(ledger.confirm(SCOPE, "a", held, &agreed(&title("One"))));
    let refused = in_flight(&mut ledger, pin("7"));
    let behind = recorded(&mut ledger, SessionPatch::Archived(true));
    let (counter, waker) = waker();
    assert_eq!(ledger.turn(SCOPE, "a", behind, &waker), Turn::Wait);

    assert!(ledger.abandon(SCOPE, "a", refused));

    assert_eq!(woken(&counter), 1);
    assert_eq!(ledger.turn(SCOPE, "a", behind, &waker), Turn::Go);
    assert!(!ledger.abandon(SCOPE, "a", held));
    assert!(!ledger.abandon(SCOPE, "a", refused));
    assert!(!ledger.abandon(SCOPE, "b", refused));
    assert_eq!(ledger.project(SCOPE, &row("a")).unwrap().title, "One");
}

#[test]
fn a_caller_that_went_away_leaves_no_reason_behind() {
    let mut ledger = IntentLedger::new();
    in_flight(&mut ledger, title("New"));
    let replaced = recorded(&mut ledger, pin("7"));
    recorded(&mut ledger, pin("9"));

    // The replaced caller never read why; giving its place up forgets the reason.
    assert!(!ledger.abandon(SCOPE, "a", replaced));
    assert_eq!(
        ledger.turn(SCOPE, "a", replaced, Waker::noop()),
        Turn::Left(Departure::Gone)
    );
}

#[test]
fn a_server_row_that_agrees_ends_the_hold() {
    let mut ledger = IntentLedger::new();
    let renamed = in_flight(&mut ledger, title("New"));
    assert!(ledger.confirm(SCOPE, "a", renamed, &agreed(&title("New"))));
    let pinned = in_flight(&mut ledger, pin("7"));

    // An older row still carries the old title: the hold masks it.
    ledger.settle(SCOPE, &row("a"));
    assert_eq!(ledger.project(SCOPE, &row("a")).unwrap().title, "New");
    // A row for a session without intents changes nothing.
    ledger.settle(SCOPE, &row("b"));

    let mut caught_up = row("a");
    title("New").apply(&mut caught_up);
    pin("7").apply(&mut caught_up);
    ledger.settle(SCOPE, &caught_up);

    assert_eq!(ledger.state(SCOPE, "a", renamed), None);
    // The pin is still owed its write, so a row that agrees does not retire it.
    assert_eq!(
        ledger.state(SCOPE, "a", pinned),
        Some(IntentState::InFlight)
    );
    assert!(ledger.confirm(SCOPE, "a", pinned, &agreed(&pin("7"))));
    ledger.settle(SCOPE, &caught_up);
    assert!(ledger.is_empty());
}

#[test]
fn a_removed_session_takes_its_intents_and_tells_the_waiting_callers() {
    let mut ledger = IntentLedger::new();
    let sent = in_flight(&mut ledger, title("New"));
    let queued = recorded(&mut ledger, pin("7"));
    let (counter, waker) = waker();
    assert_eq!(ledger.turn(SCOPE, "a", queued, &waker), Turn::Wait);

    ledger.drop_session(SCOPE, "b");
    ledger.drop_session(SCOPE, "a");

    assert!(ledger.is_empty());
    assert_eq!(woken(&counter), 1);
    assert_eq!(
        ledger.turn(SCOPE, "a", queued, &waker),
        Turn::Left(Departure::Gone)
    );
    // The one whose write is out learns from the write's own answer.
    assert_eq!(
        ledger.turn(SCOPE, "a", sent, Waker::noop()),
        Turn::Left(Departure::Gone)
    );
    assert!(!ledger.confirm(SCOPE, "a", sent, &row("a")));
}

#[test]
fn a_caller_whose_intent_is_missing_from_a_live_lane_is_told_it_is_gone() {
    let mut ledger = IntentLedger::new();
    let first = in_flight(&mut ledger, title("New"));
    recorded(&mut ledger, pin("7"));
    assert!(ledger.abandon(SCOPE, "a", first));
    assert_eq!(
        ledger.turn(SCOPE, "a", first, Waker::noop()),
        Turn::Left(Departure::Gone)
    );
}

#[test]
fn the_hold_timer_ends_a_hold_that_is_still_running() {
    let mut ledger = IntentLedger::new();
    let renamed = in_flight(&mut ledger, title("New"));
    let hold = IntentTimer {
        intent: renamed,
        kind: IntentTimerKind::Hold,
    };
    assert_eq!(hold.delay_ms(), INTENT_HOLD_MS);
    // Not held yet: the timer has nothing to end.
    assert_eq!(ledger.timer_elapsed(hold), None);
    assert!(ledger.confirm(SCOPE, "a", renamed, &agreed(&title("New"))));
    let behind = recorded(&mut ledger, pin("7"));

    assert_eq!(
        ledger.timer_elapsed(hold),
        Some((SCOPE.to_owned(), "a".to_owned()))
    );

    assert_eq!(ledger.project(SCOPE, &row("a")).unwrap().title, "Old");
    assert_eq!(ledger.state(SCOPE, "a", behind), Some(IntentState::Queued));
    assert_eq!(ledger.timer_elapsed(hold), None);
}

#[test]
fn the_unclear_timer_gives_up_on_a_link_that_did_not_return() {
    let mut ledger = IntentLedger::new();
    let lost = in_flight(&mut ledger, title("New"));
    let unclear = IntentTimer {
        intent: lost,
        kind: IntentTimerKind::Unclear,
    };
    assert_eq!(unclear.delay_ms(), UNCLEAR_INTENT_LIMIT_MS);
    assert!(ledger.mark_unclear(SCOPE, "a", lost));
    let (counter, waker) = waker();
    assert_eq!(ledger.turn(SCOPE, "a", lost, &waker), Turn::Wait);

    assert_eq!(
        ledger.timer_elapsed(unclear),
        Some((SCOPE.to_owned(), "a".to_owned()))
    );

    assert_eq!(woken(&counter), 1);
    assert!(ledger.is_empty());
    assert_eq!(
        ledger.turn(SCOPE, "a", lost, &waker),
        Turn::Left(Departure::GaveUp)
    );
}

#[test]
fn a_pending_removal_hides_the_row() {
    let mut ledger = IntentLedger::new();
    recorded(&mut ledger, title("New"));
    recorded(&mut ledger, SessionPatch::Removed);
    assert_eq!(ledger.project(SCOPE, &row("a")), None);
    // The caller of an edit still gets its row back.
    assert_eq!(ledger.overlay(SCOPE, &row("a")).title, "New");
}
