//! The projects and open folders: read beside the list's first page, kept through reloads.

use std::sync::Arc;

use serde_json::{Value, json};

use super::{ProjectFolderPaging, project_folder_id};
use crate::connection::UrlPolicy;
use crate::engine::lock;
use crate::events::CoreEvent;
use crate::host::SocketMessage;
use crate::sessions::{ProjectSummary, SessionListChange, SessionListStatus};
use crate::sidebar::ProjectSortMode;
use crate::test_support::{Harness, json as respond};

fn row(id: &str) -> Value {
    json!({"id": id, "status": "idle", "created_at": 1, "updated_at": 1, "permission_level": 4})
}

fn list_of(rows: &[Value], has_more: bool) -> String {
    json!({
        "data": rows,
        "last_id": rows.last().map(|row| row["id"].clone()),
        "has_more": has_more,
    })
    .to_string()
}

fn alpha() -> ProjectSummary {
    ProjectSummary {
        id: Some("p1".into()),
        name: "Alpha".into(),
        icon: None,
    }
}

/// A local server with one project, Alpha, whose folder holds `f1` (not on the first page).
fn server() -> Harness {
    let harness = Harness::new(UrlPolicy::Development);
    harness.local_server();
    harness
        .http
        .route("/v1/sessions", respond(200, &list_of(&[row("a")], false)));
    harness.http.route(
        "/v1/sessions/projects",
        respond(200, r#"[{"id":"p1","name":"Alpha"}]"#),
    );
    harness.http.route(
        "/v1/projects/order",
        respond(200, r#"{"sort_mode":"manual","ordered_project_ids":["p1"]}"#),
    );
    harness.http.route_query(
        "/v1/sessions",
        "project",
        "Alpha",
        respond(200, &list_of(&[row("f1")], false)),
    );
    harness
}

fn connect(harness: &mut Harness) {
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.connect("http://127.0.0.1:6767".into(), None).await })
        .unwrap();
}

/// Requests sent so far, as `path` or `path?project=…`.
fn sent(harness: &Harness) -> Vec<String> {
    lock(&harness.http.requests)
        .iter()
        .map(|request| {
            let url = url::Url::parse(&request.url).unwrap();
            let project = url
                .query_pairs()
                .find(|(name, _)| name == "project")
                .map(|(_, value)| format!("?project={value}"))
                .unwrap_or_default();
            format!("{}{project}", url.path())
        })
        .collect()
}

fn folders(events: &[CoreEvent]) -> Option<Vec<ProjectFolderPaging>> {
    events.iter().rev().find_map(|event| match event {
        CoreEvent::ProjectFoldersChanged { folders } => Some(folders.clone()),
        _ => None,
    })
}

fn last_reset(events: &[CoreEvent]) -> Option<Vec<String>> {
    events.iter().rev().find_map(|event| match event {
        CoreEvent::SessionListChanged {
            change: SessionListChange::Reset { sessions },
        } => Some(sessions.iter().map(|row| row.id.clone()).collect()),
        _ => None,
    })
}

fn loaded(folder: &str, has_more_after: bool) -> ProjectFolderPaging {
    ProjectFolderPaging {
        folder_id: folder.into(),
        is_loaded: true,
        has_more_after,
        is_loading: false,
    }
}

#[test]
fn the_projects_and_open_folders_load_beside_the_first_page() {
    let mut harness = server();
    harness.core.set_open_project_folders(vec!["p1".into()]);
    // The page waits; the projects, their order and then the open folder do not wait for it.
    let page = harness.http.hold("/v1/sessions");
    let projects = harness.http.hold("/v1/sessions/projects");
    connect(&mut harness);
    harness.pump();
    let before_projects = sent(&harness);
    assert!(
        before_projects.contains(&"/v1/projects/order".to_owned()),
        "the order is read beside the projects: {before_projects:?}"
    );
    projects.send(()).unwrap();
    harness.pump();
    assert!(sent(&harness).contains(&"/v1/sessions?project=Alpha".to_owned()));
    let events = harness.events.take();
    assert!(events.contains(&CoreEvent::ProjectsLoaded {
        projects: vec![alpha()],
        sort_mode: ProjectSortMode::Manual,
    }));
    assert_eq!(folders(&events), Some(vec![loaded("p1", false)]));
    // The folder's session is in the list before the first page is.
    assert!(events.iter().any(|event| matches!(
        event,
        CoreEvent::SessionListChanged {
            change: SessionListChange::Upsert { sessions }
        } if sessions.iter().any(|row| row.id == "f1")
    )));
    page.send(()).unwrap();
    harness.pump();
    assert_eq!(
        last_reset(&harness.events.take()),
        Some(vec!["a".into(), "f1".into()])
    );
}

#[test]
fn a_reload_keeps_an_open_folders_rows_and_reads_it_again_and_forgets_a_closed_one() {
    let mut harness = server();
    harness.core.set_open_project_folders(vec!["p1".into()]);
    connect(&mut harness);
    harness.pump();
    let folder_reads = |harness: &Harness| {
        sent(harness)
            .iter()
            .filter(|line| line.ends_with("?project=Alpha"))
            .count()
    };
    assert_eq!(folder_reads(&harness), 1);
    harness.events.take();

    let page = harness.http.hold("/v1/sessions");
    harness.core.refresh_sessions();
    harness.pump();
    assert_eq!(folder_reads(&harness), 2, "read again beside the page");
    page.send(()).unwrap();
    harness.pump();
    let events = harness.events.take();
    // Never shown as loading again, and its row never leaves.
    assert_eq!(folders(&events), None);
    assert_eq!(last_reset(&events), Some(vec!["a".into(), "f1".into()]));

    harness.core.set_open_project_folders(Vec::new());
    harness.core.refresh_sessions();
    harness.pump();
    let events = harness.events.take();
    assert_eq!(folder_reads(&harness), 2);
    assert_eq!(last_reset(&events), Some(vec!["a".into()]));
    assert_eq!(folders(&events), Some(Vec::new()));
}

#[test]
fn a_kept_folder_row_shows_as_it_stands_now_not_as_its_read_found_it() {
    let mut harness = server();
    harness.core.set_open_project_folders(vec!["p1".into()]);
    connect(&mut harness);
    harness.pump();
    // The socket says `f1` started a turn after its folder was read.
    let (_, sink, _) = harness.sockets.last();
    sink.opened();
    let mut running = row("f1");
    running["status"] = json!("running");
    running["updated_at"] = json!(5);
    for frame in [
        json!({"type": "snapshot", "items": []}),
        json!({"type": "changed", "items": [running]}),
    ] {
        sink.message(SocketMessage::Text {
            text: frame.to_string(),
        });
    }
    harness.pump();
    harness.events.take();
    // The reload's page lands first; the pins and the folder's own read wait.
    let page = harness.http.hold("/v1/sessions");
    let _pins = harness.http.hold("/v1/sessions");
    let _folder = harness.http.hold("/v1/sessions");
    harness.core.refresh_sessions();
    harness.pump();
    page.send(()).unwrap();
    harness.pump();
    let reset = harness.events.take().into_iter().find_map(|event| match event {
        CoreEvent::SessionListChanged {
            change: SessionListChange::Reset { sessions },
        } => Some(sessions),
        _ => None,
    });
    let kept = reset
        .unwrap()
        .into_iter()
        .find(|session| session.id == "f1")
        .unwrap();
    assert_eq!(kept.status, SessionListStatus::Running);
}

#[test]
fn show_more_reads_the_next_page_after_the_first() {
    let mut harness = server();
    harness.http.route_query(
        "/v1/sessions",
        "project",
        "Alpha",
        respond(200, &list_of(&[row("f1")], true)),
    );
    connect(&mut harness);
    harness.pump();
    harness.events.take();
    harness.core.load_project_folder(alpha());
    harness.pump();
    assert_eq!(
        folders(&harness.events.take()),
        Some(vec![loaded("p1", true)])
    );
    assert_eq!(harness.last_query("after"), None);

    harness.http.route_query(
        "/v1/sessions",
        "project",
        "Alpha",
        respond(200, &list_of(&[row("f2")], false)),
    );
    harness.core.load_project_folder(alpha());
    harness.pump();
    assert_eq!(harness.last_query("after").as_deref(), Some("f1"));
    assert_eq!(
        folders(&harness.events.take()),
        Some(vec![loaded("p1", false)])
    );
    // Every member is loaded: nothing more is read.
    let reads = sent(&harness).len();
    harness.core.load_project_folder(alpha());
    harness.pump();
    assert_eq!(sent(&harness).len(), reads);
}

#[test]
fn a_folder_that_cannot_be_read_says_so_for_that_folder() {
    let mut harness = server();
    harness.http.route_query(
        "/v1/sessions",
        "project",
        "Alpha",
        respond(500, r#"{"detail":"boom"}"#),
    );
    connect(&mut harness);
    harness.pump();
    harness.events.take();
    harness.core.load_project_folder(alpha());
    harness.pump();
    let events = harness.events.take();
    assert!(
        events.iter().any(|event| matches!(
            event,
            CoreEvent::ProjectFolderFailed { folder_id, .. } if folder_id == "p1"
        )),
        "{events:?}"
    );
    let unloaded = ProjectFolderPaging {
        folder_id: "p1".into(),
        is_loaded: false,
        has_more_after: false,
        is_loading: false,
    };
    assert_eq!(folders(&events), Some(vec![unloaded]));
}

#[test]
fn projects_that_cannot_be_read_are_reported() {
    let mut harness = server();
    harness
        .http
        .route("/v1/sessions/projects", respond(500, r#"{"detail":"boom"}"#));
    connect(&mut harness);
    harness.pump();
    assert!(
        harness
            .events
            .take()
            .iter()
            .any(|event| matches!(event, CoreEvent::ProjectsFailed { .. }))
    );
}

#[test]
fn a_label_only_projects_folder_is_named_by_its_label() {
    assert_eq!(project_folder_id(alpha()), "p1");
    let label = ProjectSummary {
        id: None,
        name: "Beta".into(),
        icon: None,
    };
    assert_eq!(project_folder_id(label), "label:Beta");
}
