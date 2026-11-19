//! The saved list as a launch's first sight: shown before any read answers, with its projects and
//! folders, then replaced by the server's list in one step; kept as offline when the server
//! cannot be reached. A launch reads each sidebar list once, the open folders beside the
//! projects.

use std::sync::Arc;
use std::sync::atomic::Ordering;

use serde_json::{Value, json};

use crate::engine::lock;
use crate::events::CoreEvent;
use crate::sessions::{ProjectSummary, SessionListChange};
use crate::test_support::{Harness, TempFolder, json as respond};

const SERVER: &str = "http://127.0.0.1:6767";

fn row(id: &str) -> Value {
    json!({"id": id, "status": "idle", "created_at": 1, "updated_at": 1, "permission_level": 4})
}

fn list_of(rows: &[Value]) -> String {
    json!({"data": rows, "last_id": rows.last().map(|row| row["id"].clone()), "has_more": false})
        .to_string()
}

/// A local server whose first page holds `a`, with one project, `name`, whose open folder holds
/// `member`; this device saves under `folder`.
fn server(folder: &TempFolder, name: &str, member: &str) -> Harness {
    let harness = Harness::with_cache(&folder.0);
    harness.local_server();
    harness
        .http
        .route("/v1/sessions", respond(200, &list_of(&[row("a")])));
    harness.http.route(
        "/v1/sessions/projects",
        respond(200, &json!([{"id": "p1", "name": name}]).to_string()),
    );
    harness.http.route(
        "/v1/projects/order",
        respond(
            200,
            r#"{"sort_mode":"manual","ordered_project_ids":["p1"]}"#,
        ),
    );
    harness.http.route_query(
        "/v1/sessions",
        "project",
        name,
        respond(200, &list_of(&[row(member)])),
    );
    harness.core.set_open_project_folders(vec!["p1".into()]);
    harness
}

fn connect(harness: &mut Harness) {
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.connect(SERVER.into(), None).await })
        .unwrap();
}

/// A first launch that read the page, the folder and the projects, and saved them.
fn saved_on_first_launch(folder: &TempFolder) {
    let mut first = server(folder, "Alpha", "f1");
    connect(&mut first);
    first.core.flush_message_cache();
}

/// Requests sent so far, as `path` or `path?name=value` for the list's scope.
fn sent(harness: &Harness) -> Vec<String> {
    lock(&harness.http.requests)
        .iter()
        .map(|request| {
            let url = url::Url::parse(&request.url).unwrap();
            let scope = url
                .query_pairs()
                .find(|(name, _)| name == "project" || name == "pinned")
                .map(|(name, value)| format!("?{name}={value}"))
                .unwrap_or_default();
            format!("{}{scope}", url.path())
        })
        .collect()
}

fn resets(events: &[CoreEvent]) -> Vec<Vec<String>> {
    events
        .iter()
        .filter_map(|event| match event {
            CoreEvent::SessionListChanged {
                change: SessionListChange::Reset { sessions },
            } => Some(sessions.iter().map(|session| session.id.clone()).collect()),
            _ => None,
        })
        .collect()
}

fn position(events: &[CoreEvent], wanted: impl Fn(&CoreEvent) -> bool) -> usize {
    events
        .iter()
        .position(wanted)
        .unwrap_or_else(|| panic!("{events:#?}"))
}

#[test]
fn a_launch_shows_the_saved_list_and_folders_before_any_read_answers() {
    let folder = TempFolder::new("saved-list-launch");
    saved_on_first_launch(&folder);
    let mut second = server(&folder, "Alpha", "f1");
    let manifest = second.http.hold("/.well-known/omnigent.json");
    let core = Arc::clone(&second.core);
    let connected = second.start(async move { core.connect(SERVER.into(), None).await });
    let shown = second.events.take();
    assert_eq!(sent(&second), ["/.well-known/omnigent.json"]);
    assert!(shown.contains(&CoreEvent::SavedListShown {
        server_url: Some(SERVER.into())
    }));
    let projects = shown.iter().find_map(|event| match event {
        CoreEvent::ProjectsLoaded { projects, .. } => Some(projects.clone()),
        _ => None,
    });
    let alpha = ProjectSummary {
        id: Some("p1".into()),
        name: "Alpha".into(),
        icon: None,
    };
    assert_eq!(projects, Some(vec![alpha]));
    assert_eq!(resets(&shown), [["a", "f1"]]);
    assert!(shown.contains(&CoreEvent::SessionListLoaded));

    drop(manifest);
    second.pump();
    assert!(connected.borrow_mut().take().unwrap().is_ok());
    let events = second.events.take();
    // The server's rows replace the saved ones once, after the folder's read, with no removal
    // or reset between; then the list no longer shows as saved.
    assert_eq!(resets(&events), [["a", "f1"]], "{events:#?}");
    let reset = position(&events, |event| {
        matches!(
            event,
            CoreEvent::SessionListChanged {
                change: SessionListChange::Reset { .. }
            }
        )
    });
    let replaced = position(&events, |event| {
        *event == CoreEvent::SavedListShown { server_url: None }
    });
    assert!(reset < replaced);
    assert!(!events.iter().any(|event| matches!(
        event,
        CoreEvent::SessionListChanged {
            change: SessionListChange::Remove { .. }
        }
    )));
}

#[test]
fn a_launch_reads_each_sidebar_list_once_and_the_open_folder_beside_the_projects() {
    let folder = TempFolder::new("saved-list-reads");
    saved_on_first_launch(&folder);
    let mut second = server(&folder, "Alpha", "f1");
    // The projects never answer: the saved ones name the folder's read.
    let projects = second.http.hold("/v1/sessions/projects");
    let core = Arc::clone(&second.core);
    let connected = second.start(async move { core.connect(SERVER.into(), None).await });
    assert!(connected.borrow_mut().take().unwrap().is_ok());
    let mut reads = sent(&second);
    reads.sort();
    assert_eq!(
        reads,
        [
            "/.well-known/omnigent.json",
            "/v1/info",
            "/v1/me",
            "/v1/projects/order",
            "/v1/sessions",
            "/v1/sessions/projects",
            "/v1/sessions?pinned=true",
            "/v1/sessions?project=Alpha",
        ]
    );
    // The page waits for the projects to replace the saved list in one step, or for the cap.
    assert_eq!(
        resets(&second.events.take()),
        [["a", "f1"]],
        "only the saved list's"
    );
    second.advance(crate::list_driver::HELD_PAGE_MAX_MS);
    assert_eq!(resets(&second.events.take()), [["a", "f1"]]);
    drop(projects);
    second.pump();
    assert_eq!(second.http.count("/v1/sessions/projects"), 1);
}

#[test]
fn a_renamed_project_reads_its_folder_again_by_its_new_name() {
    let folder = TempFolder::new("saved-list-renamed");
    saved_on_first_launch(&folder);
    let mut second = server(&folder, "Beta", "f2");
    connect(&mut second);
    let reads = sent(&second);
    assert!(reads.contains(&"/v1/sessions?project=Alpha".to_owned()));
    assert!(reads.contains(&"/v1/sessions?project=Beta".to_owned()));
    let events = second.events.all();
    let last = resets(&events).pop().unwrap();
    assert!(last.contains(&"f2".to_owned()), "{last:?}");
}

#[test]
fn an_unreachable_server_keeps_the_saved_list_as_offline() {
    let folder = TempFolder::new("saved-list-offline");
    saved_on_first_launch(&folder);
    let mut offline = Harness::with_cache(&folder.0);
    offline.http.offline.store(true, Ordering::SeqCst);
    let result = offline.call(|core| async move { core.connect(SERVER.into(), None).await });
    assert!(result.is_err());
    let events = offline.events.take();
    let shown = position(&events, |event| {
        *event
            == CoreEvent::SavedListShown {
                server_url: Some(SERVER.into()),
            }
    });
    let offline_at = position(&events, |event| {
        *event
            == CoreEvent::OfflineChanged {
                server_url: Some(SERVER.into()),
            }
    });
    let ended = position(&events, |event| {
        *event == CoreEvent::SavedListShown { server_url: None }
    });
    assert!(shown < offline_at && offline_at < ended);
    assert_eq!(resets(&events).len(), 1, "the saved list shows once");
}

#[test]
fn a_disconnect_ends_the_saved_list() {
    let folder = TempFolder::new("saved-list-disconnect");
    saved_on_first_launch(&folder);
    let mut second = server(&folder, "Alpha", "f1");
    let manifest = second.http.hold("/.well-known/omnigent.json");
    let core = Arc::clone(&second.core);
    let _connecting = second.start(async move { core.connect(SERVER.into(), None).await });
    second.events.take();
    second.core.disconnect();
    second.pump();
    assert!(
        second
            .events
            .take()
            .contains(&CoreEvent::SavedListShown { server_url: None })
    );
    drop(manifest);
    second.pump();
}
