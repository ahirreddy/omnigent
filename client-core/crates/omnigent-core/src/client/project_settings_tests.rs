//! Project settings: reading the stored defaults, saving only this form's keys, the icon, and
//! the project order's sort mode.

use futures::executor::block_on;
use serde_json::{Value, json};

use super::super::SessionError;
use super::super::test_support::{Reply, RouteTransport, connected};
use super::{ProjectSettings, ProjectSortMode, SANDBOX_HOST_CHOICE};
use crate::client::projects::ProjectSummary;

fn project(id: Option<&str>, name: &str) -> ProjectSummary {
    ProjectSummary {
        id: id.map(str::to_owned),
        name: name.to_owned(),
        icon: None,
    }
}

fn stored(transport: &RouteTransport, config: &Value) {
    transport.respond(
        Some("GET"),
        "/v1/projects/p1",
        None,
        Reply::json(
            200,
            json!({"id": "p1", "name": "Alpha", "config": config}).to_string(),
        ),
    );
    transport.respond(
        Some("PATCH"),
        "/v1/projects/p1",
        None,
        Reply::json(200, r#"{"id":"p1","name":"Alpha","config":{}}"#),
    );
}

#[test]
fn reads_the_stored_defaults() {
    let transport = RouteTransport::local();
    stored(
        &transport,
        &json!({"host_id": "h1", "workspace": "/repo", "use_worktree": true,
            "base_branch": "main", "agent_id": "a1", "model": "opus", "effort": 3, "icon": "🔥"}),
    );
    let core = connected(transport);
    let settings = block_on(core.project_settings(&project(Some("p1"), "Alpha"))).unwrap();
    assert_eq!(
        settings,
        ProjectSettings {
            host_id: Some("h1".into()),
            workspace: Some("/repo".into()),
            use_worktree: Some(true),
            base_branch: Some("main".into()),
            agent_id: Some("a1".into()),
            model: Some("opus".into()),
            // A malformed effort is no default.
            effort: None,
        }
    );
    // A label-only project has nothing stored and is not requested.
    let core = connected(RouteTransport::local());
    assert_eq!(
        block_on(core.project_settings(&project(None, "Legacy"))),
        Ok(ProjectSettings::default())
    );

    let malformed = RouteTransport::local();
    stored(&malformed, &json!({"use_worktree": "yes"}));
    let core = connected(malformed);
    assert!(matches!(
        block_on(core.project_settings(&project(Some("p1"), "Alpha"))),
        Err(SessionError::MalformedResponse { .. })
    ));
}

#[test]
fn saving_replaces_only_this_forms_keys() {
    let transport = RouteTransport::local();
    stored(
        &transport,
        &json!({"icon": "🔥", "future_key": 1, "model": "old", "base_branch": "dev"}),
    );
    let core = connected(transport);
    let settings = ProjectSettings {
        host_id: Some("h1".into()),
        workspace: Some(" /repo ".into()),
        use_worktree: Some(false),
        base_branch: Some("main".into()),
        agent_id: Some("a1".into()),
        model: None,
        effort: Some("high".into()),
    };
    block_on(core.save_project_settings(&project(Some("p1"), "Alpha"), &settings, false)).unwrap();
    // The worktree choice matches the global default, so it is not stored, and without a
    // worktree the base branch is dropped.
    assert_eq!(
        core.transport().write_bodies(),
        vec![
            json!({"config": {"icon": "🔥", "future_key": 1, "host_id": "h1",
            "workspace": "/repo", "agent_id": "a1", "effort": "high"}})
        ]
    );
}

#[test]
fn a_sandbox_or_no_host_keeps_no_folder_and_an_override_is_stored() {
    let config = serde_json::Map::new();
    let sandbox = ProjectSettings {
        host_id: Some(SANDBOX_HOST_CHOICE.into()),
        workspace: Some("/repo".into()),
        use_worktree: Some(true),
        base_branch: Some(" ".into()),
        ..ProjectSettings::default()
    };
    assert_eq!(
        sandbox.merged_into(&config, false),
        json!({"host_id": SANDBOX_HOST_CHOICE, "use_worktree": true})
    );
    let none = ProjectSettings {
        workspace: Some("/repo".into()),
        use_worktree: Some(false),
        ..ProjectSettings::default()
    };
    assert_eq!(
        none.merged_into(&config, true),
        json!({"use_worktree": false})
    );
}

#[test]
fn saving_a_label_project_promotes_it_first() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("GET"),
        "/v1/sessions",
        None,
        Reply::json(200, r#"{"data":[],"has_more":false}"#),
    );
    transport.respond(
        Some("POST"),
        "/v1/projects",
        None,
        Reply::json(201, r#"{"id":"p1","name":"Legacy"}"#),
    );
    transport.respond(
        Some("PATCH"),
        "/v1/projects/p1",
        None,
        Reply::json(200, r#"{"id":"p1","name":"Legacy","config":{"icon":"⭐"}}"#),
    );
    let core = connected(transport);
    let saved = block_on(core.set_project_icon(&project(None, "Legacy"), Some("⭐"))).unwrap();
    assert_eq!(saved.id.as_deref(), Some("p1"));
    assert_eq!(saved.icon.as_deref(), Some("⭐"));
    assert_eq!(
        core.transport().write_bodies(),
        vec![json!({"name": "Legacy"}), json!({"config": {"icon": "⭐"}})]
    );
}

#[test]
fn removing_the_icon_keeps_the_rest() {
    let transport = RouteTransport::local();
    stored(&transport, &json!({"icon": "🔥", "agent_id": "a1"}));
    let core = connected(transport);
    block_on(core.set_project_icon(&project(Some("p1"), "Alpha"), None)).unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        vec![json!({"config": {"agent_id": "a1"}})]
    );
}

#[test]
fn sort_mode_reads_and_resets_the_order() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("GET"),
        "/v1/projects/order",
        None,
        Reply::json(
            200,
            r#"{"sort_mode":"manual","ordered_project_ids":["p1"]}"#,
        ),
    );
    transport.respond(
        Some("PUT"),
        "/v1/projects/order",
        None,
        Reply::json(
            200,
            r#"{"sort_mode":"alphabetical","ordered_project_ids":null}"#,
        ),
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.project_sort_mode()),
        Ok(ProjectSortMode::Manual)
    );
    block_on(core.sort_projects_alphabetically()).unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        vec![json!({"ordered_project_ids": null})]
    );
    // A server without an order sorts by name.
    let core = connected(RouteTransport::local());
    assert_eq!(
        block_on(core.project_sort_mode()),
        Ok(ProjectSortMode::Alphabetical)
    );
}

#[test]
fn no_config_is_no_settings_and_an_unknown_sort_mode_is_alphabetical() {
    assert_eq!(
        ProjectSettings::from_config(None),
        Ok(ProjectSettings::default())
    );
    let transport = RouteTransport::local();
    transport.enqueue(
        "GET",
        "/v1/projects/order",
        vec![
            Reply::json(200, r#"{"sort_mode":"newest"}"#),
            Reply::json(200, r#"{"sort_mode":5}"#),
        ],
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.project_sort_mode()),
        Ok(ProjectSortMode::Alphabetical)
    );
    assert!(matches!(
        block_on(core.project_sort_mode()),
        Err(SessionError::MalformedResponse { detail }) if detail.contains("/v1/projects/order")
    ));
}

#[test]
fn a_project_that_cannot_be_read_or_acknowledged_is_reported_by_route() {
    let transport = RouteTransport::local();
    stored(&transport, &json!({}));
    transport.enqueue(
        "PATCH",
        "/v1/projects/p1",
        vec![Reply::json(200, r#"{"id":5}"#)],
    );
    let core = connected(transport);
    assert!(matches!(
        block_on(core.set_project_icon(&project(Some("p1"), "Alpha"), Some("x"))),
        Err(SessionError::DeliveryUncertain { detail }) if detail.contains("acknowledgement")
    ));

    let transport = RouteTransport::local();
    transport.ok("/v1/projects/p1", r#"{"config":5}"#);
    let core = connected(transport);
    assert!(matches!(
        block_on(core.project_settings(&project(Some("p1"), "Alpha"))),
        Err(SessionError::MalformedResponse { detail }) if detail.contains("/v1/projects/p1")
    ));
}

#[test]
fn a_promotion_that_returns_no_id_is_uncertain() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("GET"),
        "/v1/sessions",
        None,
        Reply::json(200, r#"{"data":[],"has_more":false}"#),
    );
    transport.respond(
        Some("POST"),
        "/v1/projects",
        None,
        Reply::json(201, r#"{"name":"Legacy"}"#),
    );
    let core = connected(transport);
    assert!(matches!(
        block_on(core.set_project_icon(&project(None, "Legacy"), Some("x"))),
        Err(SessionError::DeliveryUncertain { detail }) if detail.contains("no id")
    ));
}
