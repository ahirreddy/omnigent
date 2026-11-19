//! Session-list records, queries and the organising REST calls.

#![allow(clippy::too_many_lines, reason = "one journey per group of calls")]

use omnigent_core::projects::ProjectSummary as CoreProject;
use omnigent_core::session_query::SessionFilter as CoreFilter;
use omnigent_core::sessions::{SessionSummary as CoreSummary, SummaryStatus};
use serde_json::json as value;

use crate::sessions::{
    ProjectSummary, SessionChange, SessionFamily, SessionFilter, SessionListStatus, SessionSummary,
    SiblingSessionDestinations, filter_sessions, pinned_unit_count, project_members,
    session_filter_title, session_is_nested_member, session_is_owned_by, session_is_pin_unit,
    session_shows_pinned, sessions_can_move_together,
};
use crate::test_support::{Harness, connected, json};

const SESSION: &str = "/v1/sessions/conv_a";

fn summary(id: &str, change: impl FnOnce(&mut CoreSummary)) -> SessionSummary {
    let mut summary = CoreSummary::new(id, "Title", "");
    change(&mut summary);
    SessionSummary::from(summary)
}

#[test]
fn every_status_filter_and_project_map() {
    for (on_core, on_ffi) in [
        (SummaryStatus::Idle, SessionListStatus::Idle),
        (SummaryStatus::Running, SessionListStatus::Running),
        (
            SummaryStatus::NeedsResponse,
            SessionListStatus::NeedsResponse,
        ),
    ] {
        assert_eq!(SessionListStatus::from(on_core), on_ffi);
        assert_eq!(SummaryStatus::from(on_ffi), on_core);
    }
    for (on_ffi, on_core) in [
        (SessionFilter::All, CoreFilter::All),
        (SessionFilter::Running, CoreFilter::Running),
        (SessionFilter::NeedsResponse, CoreFilter::NeedsResponse),
        (SessionFilter::Archived, CoreFilter::Archived),
    ] {
        assert_eq!(CoreFilter::from(on_ffi), on_core);
        assert_eq!(session_filter_title(on_ffi), on_core.title());
    }
    let project = ProjectSummary {
        id: Some("p1".into()),
        name: "App".into(),
        icon: Some("x".into()),
    };
    let on_core = CoreProject::from(project.clone());
    assert_eq!(on_core.id.as_deref(), Some("p1"));
    assert_eq!(on_core.name, "App");
    assert_eq!(on_core.icon.as_deref(), Some("x"));
    assert_eq!(ProjectSummary::from(on_core), project);
}

#[test]
fn a_summary_survives_the_round_trip_through_the_core() {
    let mapped = summary("a", |session| {
        session.preview = "Preview".into();
        session.status = SummaryStatus::Running;
        session.pending_requests = 2;
        session.background_work_running = true;
        session.blocked_on = Some("permission prompt".into());
        session.is_read_only = true;
        session.updated_at = 5;
        session.workspace = "/w".into();
        session.agent_name = "Agent".into();
        session.is_pinned = true;
        session.pin_stamp = Some("stamp".into());
        session.is_archived = true;
        session.permission_level = Some(4);
        session.failure_message = Some("boom".into());
        session.terminal_first = true;
        session.created_at = 3;
        session.owner = Some("me".into());
        session.project_id = Some("p".into());
        session.project_label = Some("Label".into());
        session.comments_count = u64::MAX;
        session.created_by_session_id = Some("parent".into());
        session.family = Some(omnigent_core::session_families::SessionFamily {
            id: "lead".into(),
            representative_id: Some("lead".into()),
            representative_title: Some("Coordinator".into()),
            pinned: true,
            pinned_at: Some("7".into()),
        });
    });
    assert_eq!(mapped.preview, "Preview");
    assert_eq!(mapped.status, SessionListStatus::Running);
    assert_eq!(mapped.pending_requests, 2);
    assert!(mapped.background_work_running);
    assert_eq!(mapped.blocked_on.as_deref(), Some("permission prompt"));
    assert!(mapped.is_read_only);
    assert_eq!(mapped.updated_at, 5);
    assert_eq!(mapped.workspace, "/w");
    assert_eq!(mapped.agent_name, "Agent");
    assert!(mapped.is_pinned);
    assert_eq!(mapped.pin_stamp.as_deref(), Some("stamp"));
    assert!(mapped.is_archived);
    assert_eq!(mapped.permission_level, Some(4));
    assert_eq!(mapped.failure_message.as_deref(), Some("boom"));
    assert!(mapped.terminal_first);
    assert_eq!(mapped.created_at, 3);
    assert_eq!(mapped.owner.as_deref(), Some("me"));
    assert_eq!(mapped.project_id.as_deref(), Some("p"));
    assert_eq!(mapped.project_label.as_deref(), Some("Label"));
    assert_eq!(mapped.comments_count, u64::MAX);
    assert_eq!(mapped.created_by_session_id.as_deref(), Some("parent"));
    assert_eq!(
        mapped.family,
        Some(SessionFamily {
            id: "lead".into(),
            representative_id: Some("lead".into()),
            representative_title: Some("Coordinator".into()),
            pinned: true,
            pinned_at: Some("7".into()),
        })
    );
    assert_eq!(SessionSummary::from(CoreSummary::from(&mapped)), mapped);
}

#[test]
fn family_helpers_read_the_nest_the_pin_and_the_slots() {
    use omnigent_core::session_families::SiblingDestinations as Core;

    let family = |pinned: bool| {
        Some(omnigent_core::session_families::SessionFamily {
            id: "lead".into(),
            representative_id: Some("lead".into()),
            representative_title: None,
            pinned,
            pinned_at: None,
        })
    };
    let lead = summary("lead", |session| {
        session.family = family(true);
        session.is_pinned = true;
    });
    let member = summary("peer", |session| session.family = family(false));
    let solo = summary("solo", |session| session.is_pinned = true);
    assert!(session_is_nested_member(member.clone()));
    assert!(!session_is_nested_member(lead.clone()));
    // A nested member is never offered a pin, whatever its permission.
    assert!(member.is_nested_member && !member.can_pin);
    assert!(!lead.is_nested_member && lead.can_pin);
    assert!(sessions_can_move_together(vec![
        member.clone(),
        lead.clone()
    ]));
    assert!(!sessions_can_move_together(vec![
        member.clone(),
        solo.clone()
    ]));
    assert!(session_shows_pinned(member.clone(), Some(lead.clone())));
    assert!(!session_shows_pinned(member.clone(), None));
    assert!(session_shows_pinned(solo.clone(), None));
    assert!(session_is_pin_unit(lead.clone()) && session_is_pin_unit(solo.clone()));
    assert!(!session_is_pin_unit(member.clone()));
    assert_eq!(pinned_unit_count(vec![lead, member, solo]), 2);
    for (on_core, on_ffi) in [
        (Core::CurrentHost, SiblingSessionDestinations::CurrentHost),
        (
            Core::CurrentHostOrNewSandbox,
            SiblingSessionDestinations::CurrentHostOrNewSandbox,
        ),
        (Core::AnyHost, SiblingSessionDestinations::AnyHost),
    ] {
        assert_eq!(SiblingSessionDestinations::from(on_core), on_ffi);
        assert_eq!(Core::from(on_ffi), on_core);
    }
}

#[test]
fn filtering_keeps_the_host_records_in_the_core_order() {
    let sessions = vec![
        summary("old", |session| session.updated_at = 1),
        summary("new", |session| session.updated_at = 2),
        summary("running", |session| {
            session.status = SummaryStatus::Running;
            session.updated_at = 3;
        }),
        summary("archived", |session| session.is_archived = true),
    ];
    let ids = |found: Vec<SessionSummary>| -> Vec<String> {
        found.into_iter().map(|session| session.id).collect()
    };
    assert_eq!(
        ids(filter_sessions(
            sessions.clone(),
            String::new(),
            SessionFilter::All
        )),
        ["running", "new", "old"]
    );
    assert_eq!(
        ids(filter_sessions(
            sessions.clone(),
            String::new(),
            SessionFilter::Running
        )),
        ["running"]
    );
    assert_eq!(
        ids(filter_sessions(
            sessions,
            String::new(),
            SessionFilter::Archived
        )),
        ["archived"]
    );
}

#[test]
fn membership_and_ownership_read_the_viewer() {
    let filed = |id: &str, owner: Option<&str>| {
        let owner = owner.map(str::to_owned);
        summary(id, move |session| {
            session.project_id = Some("p1".into());
            session.owner = owner;
        })
    };
    let projects = vec![ProjectSummary {
        id: Some("p1".into()),
        name: "App".into(),
        icon: None,
    }];
    assert_eq!(
        project_members(
            projects,
            vec![filed("mine", Some("me")), filed("theirs", Some("them"))],
            Some("me".into()),
        ),
        [["mine"]]
    );
    assert!(session_is_owned_by(filed("a", None), Some("me".into())));
    assert!(session_is_owned_by(
        filed("a", Some("me")),
        Some("me".into())
    ));
    assert!(!session_is_owned_by(
        filed("a", Some("them")),
        Some("me".into())
    ));
}

fn owned() -> Harness {
    let harness = connected();
    let owned = r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#;
    harness
        .http
        .route_method("PATCH", SESSION, json(200, owned));
    harness
}

#[test]
fn each_edit_patches_its_field() {
    let mut harness = owned();
    let mut edit = |change: SessionChange| {
        let summary = harness
            .call(|core| async move { core.edit_session("conv_a".into(), change).await })
            .unwrap();
        assert_eq!(summary.id, "conv_a");
        let (line, body) = harness.last_request();
        assert_eq!(line, format!("PATCH {SESSION}"));
        body
    };
    assert_eq!(
        edit(SessionChange::Title {
            title: " New ".into()
        }),
        value!({"title": "New"})
    );
    let pinned = edit(SessionChange::Pinned { pinned: true });
    assert_eq!(
        pinned["labels"]["omnigent.pinned"], "1800000000000",
        "stamped with the host clock: {pinned}"
    );
    let archived = edit(SessionChange::Archived {
        archived: true,
        delete_worktree: true,
    });
    assert_eq!(archived["archived"], true);
    assert_eq!(archived["delete_worktree"], true, "{archived}");
    let filed = edit(SessionChange::Project {
        project_id: Some("p1".into()),
    });
    assert_eq!(filed["project_id"], "p1");
}

#[test]
fn stopping_deleting_and_leaving_send_their_requests_and_report_failures() {
    let mut harness = owned();
    harness.http.route_method(
        "POST",
        &format!("{SESSION}/events"),
        json(200, r#"{"queued":true}"#),
    );
    harness
        .call(|core| async move { core.stop_session("conv_a".into()).await })
        .unwrap();
    assert_eq!(
        harness.last_request(),
        (
            format!("POST {SESSION}/events"),
            value!({"type": "stop_session", "data": {}})
        )
    );

    harness.http.route_method("DELETE", SESSION, json(204, ""));
    harness
        .call(|core| async move { core.delete_session("conv_a".into()).await })
        .unwrap();
    assert_eq!(harness.last_request_line(), format!("DELETE {SESSION}"));
    assert_eq!(harness.last_query("delete_branch"), None);
    harness
        .call(|core| async move { core.delete_session_with_branch("conv_a".into(), true).await })
        .unwrap();
    assert_eq!(harness.last_query("delete_branch").as_deref(), Some("true"));

    harness.http.route_method(
        "DELETE",
        &format!("{SESSION}/permissions/local"),
        json(204, ""),
    );
    harness
        .call(|core| async move { core.leave_session("conv_a".into()).await })
        .unwrap();
    assert_eq!(
        harness.last_request_line(),
        format!("DELETE {SESSION}/permissions/local")
    );

    // Each write is refused by the server itself: nothing reads the session first.
    for (method, path) in [
        ("POST", format!("{SESSION}/events")),
        ("PATCH", SESSION.to_owned()),
        ("DELETE", SESSION.to_owned()),
    ] {
        harness
            .http
            .route_method(method, &path, json(403, r#"{"detail":"no"}"#));
    }
    harness.http.route_method(
        "DELETE",
        &format!("{SESSION}/permissions/local"),
        json(403, r#"{"detail":"no"}"#),
    );
    assert!(
        harness
            .call(|core| async move { core.stop_session("conv_a".into()).await })
            .is_err()
    );
    assert!(
        harness
            .call(|core| async move { core.delete_session("conv_a".into()).await })
            .is_err()
    );
    assert!(
        harness
            .call(|core| async move {
                core.delete_session_with_branch("conv_a".into(), false)
                    .await
            })
            .is_err()
    );
    assert!(
        harness
            .call(|core| async move { core.leave_session("conv_a".into()).await })
            .is_err()
    );
    assert!(
        harness
            .call(|core| async move {
                core.edit_session("conv_a".into(), SessionChange::Pinned { pinned: false })
                    .await
            })
            .is_err()
    );
}

#[test]
fn projects_list_create_rename_and_delete() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions/projects",
        json(
            200,
            r#"[{"id":"p1","name":"Alpha","icon":"x"},{"id":null,"name":"Legacy"}]"#,
        ),
    );
    let projects = harness
        .call(|core| async move { core.projects().await })
        .unwrap();
    assert_eq!(
        projects,
        [
            ProjectSummary {
                id: Some("p1".into()),
                name: "Alpha".into(),
                icon: Some("x".into()),
            },
            ProjectSummary {
                id: None,
                name: "Legacy".into(),
                icon: None,
            },
        ]
    );

    harness.http.route_method(
        "POST",
        "/v1/projects",
        json(201, r#"{"id":"p9","name":"New","config":{"icon":"y"}}"#),
    );
    let created = harness
        .call(|core| async move { core.create_project(" New ".into()).await })
        .unwrap();
    assert_eq!(created.id.as_deref(), Some("p9"));
    assert_eq!(created.icon.as_deref(), Some("y"));
    assert_eq!(
        harness.last_request(),
        ("POST /v1/projects".to_owned(), value!({"name": "New"}))
    );
    assert!(
        harness
            .call(|core| async move { core.create_project("  ".into()).await })
            .is_err()
    );

    harness.http.route_method(
        "PATCH",
        "/v1/projects/p1",
        json(200, r#"{"id":"p1","name":"Renamed"}"#),
    );
    harness
        .http
        .route("/v1/sessions", json(200, r#"{"data":[],"has_more":false}"#));
    let alpha = projects[0].clone();
    let renamed = harness
        .call({
            let alpha = alpha.clone();
            move |core| async move { core.rename_project(alpha, "Renamed".into()).await }
        })
        .unwrap();
    assert_eq!(renamed.name, "Renamed");
    assert!(
        harness
            .call({
                let alpha = alpha.clone();
                move |core| async move { core.rename_project(alpha, "  ".into()).await }
            })
            .is_err()
    );

    harness
        .http
        .route_method("DELETE", "/v1/projects/p1", json(204, ""));
    harness
        .call({
            let alpha = alpha.clone();
            move |core| async move { core.delete_project(alpha).await }
        })
        .unwrap();
    assert_eq!(harness.last_request_line(), "DELETE /v1/projects/p1");

    harness
        .http
        .route_method("DELETE", "/v1/projects/p1", json(500, "{}"));
    assert!(
        harness
            .call(move |core| async move { core.delete_project(alpha).await })
            .is_err()
    );

    harness.http.route("/v1/sessions/projects", json(500, "{}"));
    assert!(
        harness
            .call(|core| async move { core.projects().await })
            .is_err()
    );
}

#[test]
fn a_search_picks_its_scope_and_reads_the_snippet() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions",
        json(
            200,
            r#"{"data":[{"id":"a","status":"idle","created_at":1,"title":"Deploy",
                "search_snippet":"the rollout"}],"has_more":false}"#,
        ),
    );
    let found = harness
        .call(|core| async move { core.search_sessions("roll".into(), true, 3).await })
        .unwrap();
    assert_eq!(found[0].preview, "the rollout");
    assert_eq!(harness.last_query("search_query").as_deref(), Some("roll"));
    assert_eq!(
        harness.last_query("search_scope").as_deref(),
        Some("content")
    );
    assert_eq!(harness.last_query("limit").as_deref(), Some("3"));

    harness
        .call(|core| async move { core.search_sessions("roll".into(), false, 3).await })
        .unwrap();
    assert_eq!(harness.last_query("search_scope").as_deref(), Some("title"));

    harness.http.route("/v1/sessions", json(500, "{}"));
    assert!(
        harness
            .call(|core| async move { core.search_sessions("x".into(), false, 3).await })
            .is_err()
    );
}
