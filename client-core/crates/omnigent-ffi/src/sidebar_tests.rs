//! The sidebar's environments and project settings over the fake host.

use omnigent_core::project_settings as core_settings;
use omnigent_core::session_environment as core_environment;
use serde_json::json;

use crate::creation::CreationHost;
use crate::sessions::ProjectSummary;
use crate::sidebar::{
    ProjectSettings, ProjectSortMode, SessionEnvironment, host_environments,
    project_sandbox_host_choice,
};
use crate::test_support::{connected, json as reply};

fn host(id: &str, status: &str, sandbox: Option<&str>) -> CreationHost {
    CreationHost {
        host_id: id.into(),
        name: format!("{id} name"),
        status: status.into(),
        sandbox_provider: sandbox.map(str::to_owned),
        configured_harnesses: None,
        is_available: false,
    }
}

fn project(id: Option<&str>) -> ProjectSummary {
    ProjectSummary {
        id: id.map(str::to_owned),
        name: "Alpha".into(),
        icon: None,
    }
}

fn stored_project(harness: &crate::test_support::Harness, config: &serde_json::Value) {
    let body = json!({"id": "p1", "name": "Alpha", "config": config}).to_string();
    harness
        .http
        .route_method("GET", "/v1/projects/p1", reply(200, &body));
    harness
        .http
        .route_method("PATCH", "/v1/projects/p1", reply(200, &body));
}

#[test]
fn every_environment_arm_maps() {
    for (from, to) in [
        (
            core_environment::SessionEnvironment::LocalMachine,
            SessionEnvironment::LocalMachine,
        ),
        (
            core_environment::SessionEnvironment::ThisMachine,
            SessionEnvironment::ThisMachine,
        ),
        (
            core_environment::SessionEnvironment::Remote,
            SessionEnvironment::Remote,
        ),
        (
            core_environment::SessionEnvironment::Sandbox {
                label: "Modal Sandbox".into(),
            },
            SessionEnvironment::Sandbox {
                label: "Modal Sandbox".into(),
            },
        ),
    ] {
        assert_eq!(SessionEnvironment::from(from), to);
    }
}

#[test]
fn hosts_name_this_machine_others_and_sandboxes() {
    let environments = host_environments(
        vec![
            host("mine", "online", None),
            host("other", "online", None),
            host("box", "online", Some("modal")),
        ],
        "https://omni.example".into(),
        Some("mine".into()),
    );
    let by_id: Vec<(&str, &SessionEnvironment)> = environments
        .iter()
        .map(|host| (host.host_id.as_str(), &host.environment))
        .collect();
    assert_eq!(by_id[0], ("mine", &SessionEnvironment::ThisMachine));
    assert_eq!(by_id[1], ("other", &SessionEnvironment::Remote));
    assert_eq!(
        by_id[2],
        (
            "box",
            &SessionEnvironment::Sandbox {
                label: "Modal Sandbox".into()
            }
        )
    );
    // A local server's only online machine is this one, without a known id.
    let local = host_environments(
        vec![host("only", "online", None)],
        "http://127.0.0.1:6767".into(),
        None,
    );
    assert_eq!(local[0].environment, SessionEnvironment::ThisMachine);
}

#[test]
fn settings_round_trip_each_field() {
    let original = ProjectSettings {
        host_id: Some("h".into()),
        workspace: Some("/w".into()),
        use_worktree: Some(false),
        base_branch: Some("b".into()),
        agent_id: Some("a".into()),
        model: Some("m".into()),
        effort: Some("e".into()),
    };
    assert_eq!(
        ProjectSettings::from(core_settings::ProjectSettings::from(original.clone())),
        original
    );
    assert_eq!(
        project_sandbox_host_choice(),
        core_settings::SANDBOX_HOST_CHOICE
    );
}

#[test]
fn project_settings_read_save_and_set_the_icon() {
    let mut harness = connected();
    stored_project(
        &harness,
        &json!({"host_id": "h1", "workspace": "/repo", "use_worktree": true,
                "base_branch": "main", "agent_id": "a1", "model": "opus", "effort": "high",
                "future_key": 1}),
    );
    let read = harness
        .call(|core| async move { core.project_settings(project(Some("p1"))).await })
        .unwrap();
    assert_eq!(
        read,
        ProjectSettings {
            host_id: Some("h1".into()),
            workspace: Some("/repo".into()),
            use_worktree: Some(true),
            base_branch: Some("main".into()),
            agent_id: Some("a1".into()),
            model: Some("opus".into()),
            effort: Some("high".into()),
        }
    );
    let saved = harness
        .call(|core| async move {
            core.save_project_settings(project(Some("p1")), read, false)
                .await
        })
        .unwrap();
    assert_eq!(saved.id.as_deref(), Some("p1"));
    let (line, body) = harness.last_request();
    assert_eq!(line, "PATCH /v1/projects/p1");
    assert_eq!(
        body["config"]["future_key"],
        json!(1),
        "other keys are kept"
    );
    assert_eq!(body["config"]["use_worktree"], json!(true));
    assert_eq!(body["config"]["model"], json!("opus"));

    let with_icon = harness
        .call(|core| async move {
            core.set_project_icon(project(Some("p1")), Some("\u{2b50}".into()))
                .await
        })
        .unwrap();
    assert_eq!(with_icon.id.as_deref(), Some("p1"));
    assert_eq!(
        harness.last_request().1["config"]["icon"],
        json!("\u{2b50}")
    );
}

#[test]
fn the_sort_mode_reads_both_arms_and_can_be_dropped() {
    let mut harness = connected();
    harness.http.route_method(
        "GET",
        "/v1/projects/order",
        reply(
            200,
            r#"{"sort_mode":"manual","ordered_project_ids":["p1"]}"#,
        ),
    );
    harness.http.route_method(
        "PUT",
        "/v1/projects/order",
        reply(
            200,
            r#"{"sort_mode":"alphabetical","ordered_project_ids":[]}"#,
        ),
    );
    assert_eq!(
        harness
            .call(|core| async move { core.project_sort_mode().await })
            .unwrap(),
        ProjectSortMode::Manual
    );
    harness.http.route_method(
        "GET",
        "/v1/projects/order",
        reply(200, r#"{"sort_mode":"alphabetical"}"#),
    );
    assert_eq!(
        harness
            .call(|core| async move { core.project_sort_mode().await })
            .unwrap(),
        ProjectSortMode::Alphabetical
    );
    harness
        .call(|core| async move { core.sort_projects_alphabetically().await })
        .unwrap();
    assert_eq!(harness.last_request().0, "PUT /v1/projects/order");
}

#[test]
fn a_pin_move_stamps_the_key_and_the_order_saves_every_id() {
    let mut harness = connected();
    for (id, stamp) in [("p0", "1000"), ("p1", "2000")] {
        harness.http.route(
            &format!("/v1/sessions/{id}"),
            reply(
                200,
                &format!(
                    r#"{{"id":"{id}","status":"idle","created_at":1,"permission_level":4,
                        "labels":{{"omnigent.pinned":"{stamp}"}}}}"#
                ),
            ),
        );
    }
    // Pinning each publishes its summary, which the move orders by.
    for id in ["p0", "p1"] {
        let change = crate::sessions::SessionChange::Pinned { pinned: true };
        harness
            .call(|core| async move { core.edit_session(id.into(), change).await })
            .unwrap();
    }
    harness
        .call(|core| async move { core.move_pin("p1".into(), "p0".into()).await })
        .unwrap();
    let (line, body) = harness.last_request();
    assert_eq!(line, "PATCH /v1/sessions/p1");
    assert_eq!(body, json!({"labels": {"omnigent.pinned": "999"}}));

    harness.http.route_method(
        "PUT",
        "/v1/projects/order",
        reply(
            200,
            r#"{"sort_mode":"manual","ordered_project_ids":["p1"]}"#,
        ),
    );
    let saved = harness
        .call(|core| async move { core.save_project_order(vec![project(Some("p1"))]).await })
        .unwrap();
    assert_eq!(saved, [project(Some("p1"))]);
    assert_eq!(
        harness.last_request(),
        (
            "PUT /v1/projects/order".into(),
            json!({"ordered_project_ids": ["p1"]})
        )
    );
}

#[test]
fn hosts_map_their_fields() {
    let mut harness = connected();
    harness.http.route(
        "/v1/hosts",
        reply(
            200,
            r#"{"hosts":[{"host_id":"h1","name":"Mac","status":"online","sandbox_provider":"modal"}]}"#,
        ),
    );
    let hosts = harness
        .call(|core| async move { core.hosts().await })
        .unwrap();
    assert_eq!(hosts[0].host_id, "h1");
    assert_eq!(hosts[0].name, "Mac");
    assert_eq!(hosts[0].status, "online");
    assert_eq!(hosts[0].sandbox_provider.as_deref(), Some("modal"));
}
