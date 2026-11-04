//! Projects: the dual-read list and membership, create, rename (with promotion) and delete.

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::sessions::{SessionChange, SessionSummary};
use super::super::test_support::{Reply, RouteTransport, connected, path_of, query_value};
use super::{ProjectSummary, project_members};

fn project(id: Option<&str>, name: &str) -> ProjectSummary {
    ProjectSummary {
        id: id.map(str::to_owned),
        name: name.to_owned(),
        icon: None,
    }
}

#[test]
fn lists_first_class_and_label_projects_with_icons() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sessions/projects",
        r#"[{"id":"p1","name":"Alpha","icon":"🔥"},{"id":null,"name":"Legacy"}]"#,
    );
    let core = connected(transport);
    let projects = block_on(core.projects()).unwrap();
    assert_eq!(
        projects,
        vec![
            ProjectSummary {
                icon: Some("🔥".into()),
                ..project(Some("p1"), "Alpha")
            },
            project(None, "Legacy"),
        ]
    );

    // An older server without projects.
    let core = connected(RouteTransport::local());
    assert_eq!(block_on(core.projects()), Ok(Vec::new()));

    let malformed = RouteTransport::local();
    malformed.ok("/v1/sessions/projects", r#"{"data":[]}"#);
    let core = connected(malformed);
    assert!(matches!(
        block_on(core.projects()),
        Err(SessionError::MalformedResponse { .. })
    ));
}

#[test]
fn membership_is_dual_read_and_owner_only() {
    let by_id = SessionSummary {
        project_id: Some("p1".into()),
        ..SessionSummary::new("a", "A", "")
    };
    let by_label = SessionSummary {
        project_label: Some("Alpha".into()),
        owner: Some("me".into()),
        ..SessionSummary::new("b", "B", "")
    };
    let shared = SessionSummary {
        project_id: Some("p1".into()),
        owner: Some("someone".into()),
        ..SessionSummary::new("c", "C", "")
    };
    let loose = SessionSummary::new("d", "D", "");
    let members = project_members(
        &[project(Some("p1"), "Alpha"), project(None, "Other")],
        &[by_id, by_label, shared, loose],
        Some("me"),
    );
    assert_eq!(members, vec![vec!["a".to_owned(), "b".to_owned()], vec![]]);
}

#[test]
fn summaries_carry_owner_creation_and_project() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sessions",
        r#"{"data":[{"id":"a","status":"idle","created_at":7,"owner":"me","project_id":"p1","labels":{"omni_project":"Old"}}],"has_more":false}"#,
    );
    let core = connected(transport);
    let sessions = block_on(core.sessions()).unwrap();
    assert_eq!(sessions[0].created_at, 7);
    assert_eq!(sessions[0].owner.as_deref(), Some("me"));
    assert_eq!(sessions[0].project_id.as_deref(), Some("p1"));
    assert_eq!(sessions[0].project_label.as_deref(), Some("Old"));
}

#[test]
fn moving_files_by_id_and_clears_the_legacy_label() {
    let transport = RouteTransport::local();
    let snapshot = r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#;
    transport.ok("/v1/sessions/conv_a", snapshot);
    let core = connected(transport);
    block_on(core.edit_session("conv_a", SessionChange::Project(Some("p1".into())))).unwrap();
    block_on(core.edit_session("conv_a", SessionChange::Project(None))).unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        vec![
            json!({"project_id": "p1", "labels": {"omni_project": ""}}),
            json!({"project_id": "", "labels": {"omni_project": ""}}),
        ]
    );
}

#[test]
fn create_validates_the_name() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("POST"),
        "/v1/projects",
        None,
        Reply::json(201, r#"{"id":"p9","name":"New","config":{"icon":"⭐"}}"#),
    );
    let core = connected(transport);
    for name in ["  ".to_owned(), "x".repeat(121)] {
        assert_eq!(
            block_on(core.create_project(&name)),
            Err(SessionError::InvalidTitle)
        );
    }
    let created = block_on(core.create_project(" New ")).unwrap();
    assert_eq!(created.id.as_deref(), Some("p9"));
    assert_eq!(created.icon.as_deref(), Some("⭐"));
    assert_eq!(
        core.transport().write_bodies(),
        vec![json!({"name": "New"})]
    );
}

fn members_page(transport: &RouteTransport) {
    transport.respond(
        Some("GET"),
        "/v1/sessions",
        None,
        Reply::json(
            200,
            r#"{"data":[{"id":"m1","status":"idle","created_at":1}],"has_more":false}"#,
        ),
    );
}

#[test]
fn renaming_a_label_project_promotes_it_and_refiles_members() {
    let transport = RouteTransport::local();
    members_page(&transport);
    transport.respond(
        Some("POST"),
        "/v1/projects",
        None,
        Reply::json(201, r#"{"id":"p2","name":"Renamed"}"#),
    );
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/m1",
        None,
        Reply::json(200, r#"{"id":"m1","status":"idle","created_at":1}"#),
    );
    let core = connected(transport);
    let renamed = block_on(core.rename_project(&project(None, "Legacy"), "Renamed")).unwrap();
    assert_eq!(renamed.id.as_deref(), Some("p2"));
    assert_eq!(
        core.transport().write_bodies(),
        vec![
            json!({"name": "Renamed"}),
            json!({"project_id": "p2", "labels": {"omni_project": ""}}),
        ]
    );
    let list = core
        .transport()
        .taken()
        .into_iter()
        .find(|request| request.method == "GET" && path_of(request) == "/v1/sessions")
        .unwrap();
    assert_eq!(query_value(&list, "project").as_deref(), Some("Legacy"));
}

#[test]
fn deleting_archives_and_unfiles_members_and_keeps_the_project_on_failure() {
    let transport = RouteTransport::local();
    members_page(&transport);
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/m1",
        None,
        Reply::json(200, r#"{"id":"m1","status":"idle","created_at":1}"#),
    );
    transport.respond(
        Some("DELETE"),
        "/v1/projects/p1",
        None,
        Reply::json(200, "{}"),
    );
    let core = connected(transport);
    block_on(core.delete_project(&project(Some("p1"), "Alpha"))).unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        vec![
            json!({"archived": true, "project_id": "", "labels": {"omni_project": ""}}),
            serde_json::Value::Null,
        ],
        "the member, then the project itself"
    );

    let failing = RouteTransport::local();
    members_page(&failing);
    failing.respond(
        Some("PATCH"),
        "/v1/sessions/m1",
        None,
        Reply::json(403, "{}"),
    );
    let core = connected(failing);
    assert_eq!(
        block_on(core.delete_project(&project(Some("p1"), "Alpha"))),
        Err(SessionError::Forbidden)
    );
    assert!(
        core.transport()
            .writes()
            .iter()
            .all(|request| request.method != "DELETE")
    );
}
