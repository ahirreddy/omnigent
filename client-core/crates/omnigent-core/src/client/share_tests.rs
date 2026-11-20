//! A session's permissions pages: the grants across pages, and the automation that keeps them.

use futures::executor::block_on;
use serde_json::json;

use super::super::test_support::{Reply, RouteTransport, connected};
use super::*;

const SESSION: &str = "fedcba9876543210fedcba9876543210";

#[test]
fn the_first_page_names_the_automation_that_keeps_the_shares() {
    let core = connected(RouteTransport::local());
    let path = format!("/v1/sessions/{SESSION}/permissions");
    core.transport().enqueue(
        "GET",
        &path,
        vec![
            Reply::json(
                200,
                json!({
                    "permissions": [{"user_id": "ada", "level": 4}],
                    "managed_by_automation": {"id": "t1", "name": "Nightly triage"},
                    "next_cursor": "c1",
                })
                .to_string(),
            ),
            Reply::json(
                200,
                json!({"permissions": [{"user_id": "bob", "level": 1}], "next_cursor": null})
                    .to_string(),
            ),
        ],
    );
    let permissions = block_on(core.session_permissions(SESSION)).unwrap();
    let users: Vec<&str> = permissions
        .grants
        .iter()
        .map(|grant| grant.user_id.as_str())
        .collect();
    assert_eq!(users, ["ada", "bob"]);
    assert_eq!(
        permissions.managed_by,
        Some(ManagingAutomation {
            id: "t1".to_owned(),
            name: "Nightly triage".to_owned(),
        })
    );
    core.transport().enqueue(
        "GET",
        &path,
        vec![Reply::json(
            200,
            json!({"permissions": [], "managed_by_automation": null}).to_string(),
        )],
    );
    assert_eq!(
        block_on(core.session_permissions(SESSION))
            .unwrap()
            .managed_by,
        None
    );
}

#[test]
fn workspace_files_read_from_the_session_and_change_with_a_patch() {
    let core = connected(RouteTransport::local());
    let path = format!("/v1/sessions/{SESSION}");
    core.transport().enqueue(
        "GET",
        &path,
        vec![Reply::json(
            200,
            json!({"id": SESSION, "status": "idle", "created_at": 1, "workspace": "/work"})
                .to_string(),
        )],
    );
    let read = block_on(core.workspace_sharing(SESSION)).unwrap();
    assert!(!read.enabled);
    assert_eq!(read.workspace.as_deref(), Some("/work"));
    core.transport().enqueue(
        "PATCH",
        &path,
        vec![Reply::json(
            200,
            json!({
                "id": SESSION, "status": "idle", "created_at": 1, "workspace": "/work",
                "share_workspace_files": true,
            })
            .to_string(),
        )],
    );
    let changed = block_on(core.set_workspace_sharing(SESSION, true)).unwrap();
    assert!(changed.enabled);
    let body = core.transport().write_bodies().pop().unwrap();
    assert_eq!(body, json!({"share_workspace_files": true}));
}
