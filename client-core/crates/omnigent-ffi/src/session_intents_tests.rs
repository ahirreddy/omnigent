//! List-row edits over the fake host: the list changes before the server answers.

#![allow(clippy::too_many_lines, reason = "one journey per kind of edit")]

use std::cell::RefCell;
use std::rc::Rc;

use omnigent_core::intents::INTENT_HOLD_MS;

use crate::errors::{CoreError, SessionErrorKind};
use crate::events::CoreEvent;
use crate::host::{ConnectionFailure, SocketEnd, SocketMessage};
use crate::sessions::{SessionChange, SessionEdit, SessionListChange, SessionSummary};
use crate::test_support::{Harness, connected, json};

/// Two rows of the recorded list.
const FIRST: &str = "1a96db016a85409ab884278d2ab31dfc";
const SECOND: &str = "e4c1ef06c8b844a6bb414db5efe0df7e";

fn path(session_id: &str) -> String {
    format!("/v1/sessions/{session_id}")
}

/// A server row for `session_id` with `fields` (JSON members) added.
fn row(session_id: &str, fields: &str) -> String {
    format!(
        r#"{{"id":"{session_id}","status":"idle","created_at":1,"permission_level":4,"owner":"local"{fields}}}"#
    )
}

fn answers(harness: &Harness, session_id: &str, fields: &str) {
    harness.http.route_method(
        "PATCH",
        &path(session_id),
        json(200, &row(session_id, fields)),
    );
}

/// The list changes in `events`: the rows of each upsert, or the ids of each removal.
fn list_changes(events: &[CoreEvent]) -> Vec<Result<Vec<SessionSummary>, Vec<String>>> {
    events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::SessionListChanged {
                change: SessionListChange::Upsert { sessions },
            } => Some(Ok(sessions.clone())),
            CoreEvent::SessionListChanged {
                change: SessionListChange::Remove { ids },
            } => Some(Err(ids.clone())),
            _ => None,
        })
        .collect()
}

/// The single list change in `events`, as its upserted rows.
fn shown(events: &[CoreEvent]) -> Vec<SessionSummary> {
    let mut changes = list_changes(events);
    assert_eq!(changes.len(), 1, "{changes:?}");
    changes.remove(0).expect("an upsert")
}

fn kind(error: &CoreError) -> SessionErrorKind {
    match error {
        CoreError::Session { kind, .. } => *kind,
        other => panic!("expected a session error: {other:?}"),
    }
}

fn start_edit(
    harness: &mut Harness,
    session_id: &'static str,
    change: SessionChange,
) -> Rc<RefCell<Option<Result<SessionSummary, CoreError>>>> {
    let core = harness.core.clone();
    harness.start(async move { core.edit_session(session_id.into(), change).await })
}

#[test]
fn each_kind_of_edit_shows_on_its_row_before_the_server_answers() {
    type Check = fn(&SessionSummary) -> bool;
    let cases: [(SessionChange, &str, Check); 4] = [
        (
            SessionChange::Title {
                title: "New".into(),
            },
            r#","title":"New""#,
            |row| row.title == "New",
        ),
        (
            SessionChange::Pinned { pinned: true },
            r#","labels":{"omnigent.pinned":"1800000000000"}"#,
            |row| row.is_pinned,
        ),
        (
            SessionChange::Project {
                project_id: Some("p1".into()),
            },
            r#","project_id":"p1""#,
            |row| row.project_id.as_deref() == Some("p1"),
        ),
        (
            SessionChange::Archived {
                archived: true,
                delete_worktree: false,
            },
            r#","archived":true"#,
            |row| row.is_archived,
        ),
    ];
    let mut harness = connected();
    for (change, answer, changed) in cases {
        answers(&harness, FIRST, answer);
        let release = harness.http.hold(&path(FIRST));
        harness.events.take();
        let saved = start_edit(&mut harness, FIRST, change.clone());

        let rows = shown(&harness.events.take());
        assert_eq!(rows.len(), 1);
        assert!(changed(&rows[0]), "{change:?}: {:?}", rows[0]);
        assert_eq!(
            harness.last_request_line(),
            format!("PATCH {}", path(FIRST))
        );
        assert!(saved.borrow().is_none(), "the request is still held");

        release.send(()).unwrap();
        harness.pump();
        let answered = saved.borrow_mut().take().unwrap().unwrap();
        assert!(changed(&answered), "{change:?}: {answered:?}");
    }
}

#[test]
fn an_accepted_edit_is_held_over_an_older_row_until_the_host_timer_fires() {
    let mut harness = connected();
    let (_, sink, _) = harness.sockets.last();
    sink.opened();
    answers(&harness, FIRST, r#","title":"New""#);
    harness
        .call(|core| async move {
            core.edit_session(
                FIRST.into(),
                SessionChange::Title {
                    title: "New".into(),
                },
            )
            .await
        })
        .unwrap();

    // A frame read before the write landed still carries the old title.
    harness.events.take();
    sink.message(SocketMessage::Text {
        text: format!(
            r#"{{"type":"snapshot","items":[{}]}}"#,
            row(FIRST, r#","title":"Old""#)
        ),
    });
    harness.pump();
    assert_eq!(shown(&harness.events.take())[0].title, "New");

    harness.advance(INTENT_HOLD_MS);
    let titles: Vec<String> = list_changes(&harness.events.take())
        .into_iter()
        .flat_map(|change| change.expect("an upsert"))
        .map(|row| row.title)
        .collect();
    assert_eq!(titles, ["Old"], "the hold ended and the server row shows");
}

#[test]
fn a_refused_edit_puts_the_row_back() {
    let mut harness = connected();
    harness
        .http
        .route_method("PATCH", &path(FIRST), json(403, r#"{"detail":"no"}"#));
    let release = harness.http.hold(&path(FIRST));
    harness.events.take();
    let saved = start_edit(
        &mut harness,
        FIRST,
        SessionChange::Title {
            title: "New".into(),
        },
    );
    assert_eq!(shown(&harness.events.take())[0].title, "New");

    release.send(()).unwrap();
    harness.pump();
    let error = saved.borrow_mut().take().unwrap().unwrap_err();
    assert_eq!(kind(&error), SessionErrorKind::ReadOnly);
    assert_eq!(
        shown(&harness.events.take())[0].title,
        "fixture delete session"
    );
}

#[test]
fn a_delete_and_a_leave_hide_the_row_before_the_server_answers() {
    let mut harness = connected();

    // A refused delete brings the row back.
    harness
        .http
        .route_method("DELETE", &path(FIRST), json(403, r#"{"detail":"no"}"#));
    let release = harness.http.hold(&path(FIRST));
    harness.events.take();
    let core = harness.core.clone();
    let deleted = harness.start(async move { core.delete_session(FIRST.into()).await });
    assert_eq!(
        list_changes(&harness.events.take()),
        [Err(vec![FIRST.to_owned()])]
    );
    assert_eq!(
        harness.last_request_line(),
        format!("DELETE {}", path(FIRST))
    );
    assert!(deleted.borrow().is_none(), "the request is still held");
    release.send(()).unwrap();
    harness.pump();
    assert!(deleted.borrow_mut().take().unwrap().is_err());
    assert_eq!(shown(&harness.events.take())[0].id, FIRST);

    // An accepted leave keeps it gone.
    let grant = format!("{}/permissions/local", path(SECOND));
    harness.http.route_method("DELETE", &grant, json(204, ""));
    let release = harness.http.hold(&grant);
    let core = harness.core.clone();
    let left = harness.start(async move { core.leave_session(SECOND.into()).await });
    assert_eq!(
        list_changes(&harness.events.take()),
        [Err(vec![SECOND.to_owned()])]
    );
    assert!(left.borrow().is_none(), "the request is still held");
    release.send(()).unwrap();
    harness.pump();
    left.borrow_mut().take().unwrap().unwrap();
    assert_eq!(
        list_changes(&harness.events.take()),
        [Err(vec![SECOND.to_owned()])]
    );
}

#[test]
fn a_pin_move_shows_the_new_order_before_the_server_answers() {
    let mut harness = connected();
    for (id, stamp) in [(FIRST, "1000"), (SECOND, "2000")] {
        answers(
            &harness,
            id,
            &format!(r#","labels":{{"omnigent.pinned":"{stamp}"}}"#),
        );
        harness
            .call(|core| async move {
                core.edit_session(id.into(), SessionChange::Pinned { pinned: true })
                    .await
            })
            .unwrap();
    }
    answers(&harness, SECOND, r#","labels":{"omnigent.pinned":"999"}"#);
    let release = harness.http.hold(&path(SECOND));
    harness.events.take();
    let core = harness.core.clone();
    let moved = harness.start(async move { core.move_pin(SECOND.into(), FIRST.into()).await });

    let rows = shown(&harness.events.take());
    assert_eq!(
        rows.iter().map(|row| row.id.as_str()).collect::<Vec<_>>(),
        [SECOND]
    );
    assert!(moved.borrow().is_none(), "the request is still held");
    release.send(()).unwrap();
    harness.pump();
    moved.borrow_mut().take().unwrap().unwrap();
}

#[test]
fn a_batch_shows_every_row_in_one_change_and_reports_the_edits_not_saved() {
    let mut harness = connected();
    answers(&harness, FIRST, r#","archived":true"#);
    harness
        .http
        .route_method("PATCH", &path(SECOND), json(403, r#"{"detail":"no"}"#));
    let first = harness.http.hold(&path(FIRST));
    let second = harness.http.hold(&path(SECOND));
    harness.events.take();
    let archive = |session_id: &str, delete_worktree| SessionEdit {
        session_id: session_id.to_owned(),
        change: SessionChange::Archived {
            archived: true,
            delete_worktree,
        },
    };
    let edits = vec![archive(FIRST, true), archive(SECOND, false)];
    let core = harness.core.clone();
    let failures = harness.start(async move { core.edit_sessions(edits).await });

    let rows = shown(&harness.events.take());
    assert_eq!(
        rows.iter()
            .map(|row| (row.id.as_str(), row.is_archived))
            .collect::<Vec<_>>(),
        [(FIRST, true), (SECOND, true)]
    );
    // Both writes left before either was answered.
    let lines = harness.http.lines();
    assert_eq!(
        lines[lines.len() - 2..],
        [
            format!("PATCH {}", path(FIRST)),
            format!("PATCH {}", path(SECOND))
        ]
    );
    let bodies: Vec<serde_json::Value> = crate::engine::lock(&harness.http.requests)
        .iter()
        .rev()
        .take(2)
        .map(|request| serde_json::from_slice(request.body.as_ref().unwrap()).unwrap())
        .collect();
    assert_eq!(bodies[1]["delete_worktree"], true, "{bodies:?}");
    assert_eq!(bodies[0].get("delete_worktree"), None, "{bodies:?}");
    assert!(failures.borrow().is_none(), "the requests are still held");

    first.send(()).unwrap();
    second.send(()).unwrap();
    harness.pump();
    let failures = failures.borrow_mut().take().unwrap();
    assert_eq!(failures.len(), 1);
    assert_eq!(failures[0].session_id, SECOND);
    assert_eq!(kind(&failures[0].error), SessionErrorKind::ReadOnly);
    let after: Vec<(String, bool)> = list_changes(&harness.events.take())
        .into_iter()
        .flat_map(|change| change.expect("an upsert"))
        .map(|row| (row.id, row.is_archived))
        .collect();
    assert!(after.contains(&(SECOND.to_owned(), false)), "{after:?}");
    assert!(!after.contains(&(FIRST.to_owned(), false)), "{after:?}");
}

/// The rows published by the time `call` answers, as `(id, archived)`; `None` for a removal.
fn published_at_the_answer<T: 'static>(
    harness: &mut Harness,
    call: impl Future<Output = T> + 'static,
) -> Vec<Option<(String, bool)>> {
    harness.events.take();
    let events = std::sync::Arc::clone(&harness.events);
    let answered = harness.run(async move {
        call.await;
        events.all()
    });
    list_changes(&answered)
        .into_iter()
        .flat_map(|change| match change {
            Ok(rows) => rows
                .into_iter()
                .map(|row| Some((row.id, row.is_archived)))
                .collect(),
            Err(ids) => vec![None; ids.len()],
        })
        .collect()
}

#[test]
fn a_row_edit_answers_after_the_rows_it_changed_are_published() {
    let mut harness = connected();
    answers(&harness, FIRST, r#","archived":true"#);
    harness
        .http
        .route_method("PATCH", &path(SECOND), json(403, r#"{"detail":"no"}"#));
    let archive = |session_id: &str| SessionEdit {
        session_id: session_id.to_owned(),
        change: SessionChange::Archived {
            archived: true,
            delete_worktree: false,
        },
    };

    // A batch: the refused row is back before the answer names it.
    let edits = vec![archive(FIRST), archive(SECOND)];
    let core = harness.core.clone();
    let rows =
        published_at_the_answer(&mut harness, async move { core.edit_sessions(edits).await });
    assert_eq!(
        rows.last(),
        Some(&Some((SECOND.to_owned(), false))),
        "{rows:?}"
    );

    // One refused edit: the row is shown changed, then put back, before the error.
    let core = harness.core.clone();
    let change = archive(SECOND).change;
    let rows = published_at_the_answer(&mut harness, async move {
        core.edit_session(SECOND.to_owned(), change).await
    });
    assert_eq!(
        rows,
        [
            Some((SECOND.to_owned(), true)),
            Some((SECOND.to_owned(), false))
        ]
    );

    // A refused delete: the row is hidden, then back, before the error.
    harness
        .http
        .route_method("DELETE", &path(FIRST), json(403, r#"{"detail":"no"}"#));
    let core = harness.core.clone();
    let rows = published_at_the_answer(&mut harness, async move {
        core.delete_session_with_branch(FIRST.to_owned(), false)
            .await
    });
    assert_eq!(rows, [None, Some((FIRST.to_owned(), true))]);

    // An accepted leave: both removals are out before the answer.
    let grant = format!("{}/permissions/local", path(SECOND));
    harness.http.route_method("DELETE", &grant, json(204, ""));
    let core = harness.core.clone();
    let rows = published_at_the_answer(&mut harness, async move {
        core.leave_session(SECOND.to_owned()).await
    });
    assert_eq!(rows, [None, None]);
}

#[test]
fn edits_are_refused_while_the_updates_link_is_down_and_made_again_once_it_is_back() {
    let mut harness = connected();
    answers(&harness, FIRST, r#","title":"New""#);
    let rename = SessionChange::Title {
        title: "New".into(),
    };
    let (_, sink, _) = harness.sockets.last();
    sink.opened();
    harness.pump();

    // The socket drops before it proved healthy: the link is known down.
    sink.ended(SocketEnd::Failed {
        failure: ConnectionFailure::Offline {
            message: "no route".into(),
        },
    });
    harness.pump();
    harness.events.take();
    let requests = harness.http.lines().len();
    let refused = start_edit(&mut harness, FIRST, rename.clone());
    let error = refused.borrow_mut().take().unwrap().unwrap_err();
    assert_eq!(kind(&error), SessionErrorKind::Offline);
    assert_eq!(list_changes(&harness.events.take()), []);
    assert_eq!(harness.http.lines().len(), requests, "nothing was sent");

    // The next redial opens: edits go through again.
    let sockets = harness.sockets.count();
    harness.advance(60_000);
    assert!(
        harness.sockets.count() > sockets,
        "the socket was redialled"
    );
    let (_, sink, _) = harness.sockets.last();
    sink.opened();
    sink.message(SocketMessage::Text {
        text: r#"{"type":"snapshot","items":[]}"#.into(),
    });
    harness.pump();
    let saved = start_edit(&mut harness, FIRST, rename);
    assert_eq!(saved.borrow_mut().take().unwrap().unwrap().title, "New");
}
