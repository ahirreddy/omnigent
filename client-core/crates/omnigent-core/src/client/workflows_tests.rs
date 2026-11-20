//! The workflow calls against a scripted server: their paths, queries and bodies, the clone's
//! name retries, the older-server description fallback and the grants.

use futures::executor::block_on;
use serde_json::{Value, json};

use super::super::SessionError;
use super::super::test_support::{
    Reply, RouteTransport, body_json, connected, path_of, query_value,
};
use crate::session_journal::PlanStep;
use crate::workflows::proposal::DescriptionWrite;

const ID: &str = "0123456789abcdef0123456789abcdef";
const SESSION: &str = "fedcba9876543210fedcba9876543210";

fn workflow(name: &str) -> Value {
    json!({
        "id": ID, "object": "workflow", "name": name, "description": "Rerun the suite",
        "created_at": 1, "updated_at": 2, "is_draft": false, "viewer_role": "owner",
        "steps": [{"id": "a", "name": "A", "goal": null, "depends_on": []}],
    })
}

fn step() -> PlanStep {
    PlanStep {
        id: "a".to_owned(),
        name: "A".to_owned(),
        goal: Some("Do A".to_owned()),
        depends_on: vec![],
    }
}

#[test]
fn a_runs_message_names_the_run_and_a_denial_is_typed() {
    let core = connected(RouteTransport::local());
    let path = format!("/v1/sessions/{SESSION}/events");
    let run = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    core.transport().enqueue(
        "POST",
        &path,
        vec![
            Reply::json(200, r#"{"queued":false}"#),
            Reply::json(200, r#"{"queued":false,"denied":true,"reason":"policy"}"#),
        ],
    );
    block_on(core.send_workflow_run_message(SESSION, run, "Stop the plan now.")).unwrap();
    let body = core.transport().write_bodies().pop().unwrap();
    assert_eq!(body["workflow_run_id"], run);
    assert_eq!(body["type"], "message");
    assert_eq!(body["data"]["content"][0]["text"], "Stop the plan now.");
    let denied = block_on(core.send_workflow_run_message(SESSION, run, "Go")).unwrap_err();
    assert_eq!(
        denied,
        SessionError::MessageDenied {
            reason: Some("policy".to_owned())
        }
    );
}

#[test]
fn lists_page_with_their_limits_and_cursors() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        "/v1/workflows",
        json!({"data": [workflow("A")], "has_more": true, "next_cursor": "n"}).to_string(),
    );
    core.transport().ok(
        "/v1/workflows/shared",
        json!({"data": [workflow("B")], "next_cursor": null}).to_string(),
    );
    let owned = block_on(core.workflows(Some("c1"))).unwrap();
    assert_eq!(owned.next_cursor.as_deref(), Some("n"));
    let request = core.transport().taken().pop().unwrap();
    assert_eq!(query_value(&request, "limit").as_deref(), Some("200"));
    assert_eq!(query_value(&request, "after").as_deref(), Some("c1"));
    let shared = block_on(core.shared_workflows(None)).unwrap();
    assert!(shared.workflows[0].shared_with_me);
    let request = core.transport().taken().pop().unwrap();
    assert_eq!(query_value(&request, "limit").as_deref(), Some("100"));
    assert_eq!(query_value(&request, "after"), None);
}

#[test]
fn a_missing_workflow_is_a_404() {
    let core = connected(RouteTransport::local());
    let error = block_on(core.workflow(ID)).unwrap_err();
    assert_eq!(error, SessionError::HttpStatus { status: 404 });
    assert!(matches!(
        block_on(core.workflow("../x")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}

#[test]
fn a_draft_is_checked_then_posted_without_steps() {
    let core = connected(RouteTransport::local());
    assert!(matches!(
        block_on(core.create_workflow_draft("  ", "Do it")),
        Err(SessionError::InvalidInput { .. })
    ));
    assert!(matches!(
        block_on(core.create_workflow_draft(&"x".repeat(81), "Do it")),
        Err(SessionError::InvalidInput { .. })
    ));
    assert_eq!(core.transport().writes().len(), 0);
    core.transport()
        .ok("/v1/workflows", workflow("Fix flaky tests").to_string());
    let saved = block_on(core.create_workflow_draft(" Fix flaky tests ", " Rerun ")).unwrap();
    assert_eq!(saved.workflow.name, "Fix flaky tests");
    assert_eq!(
        core.transport().write_bodies(),
        [json!({"name": "Fix flaky tests", "description": "Rerun", "steps": []})]
    );
}

#[test]
fn a_clone_tries_the_next_copy_name_after_a_conflict() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        &format!("/v1/workflows/{ID}"),
        workflow("Triage").to_string(),
    );
    core.transport().enqueue(
        "POST",
        "/v1/workflows",
        vec![
            Reply::json(409, r#"{"detail":"taken"}"#),
            Reply::json(200, workflow("Triage (copy 2)").to_string()),
        ],
    );
    let copy = block_on(core.clone_workflow(ID)).unwrap();
    assert_eq!(copy.workflow.name, "Triage (copy 2)");
    let names: Vec<Value> = core
        .transport()
        .write_bodies()
        .into_iter()
        .map(|body| body["name"].clone())
        .collect();
    assert_eq!(names, [json!("Triage (copy)"), json!("Triage (copy 2)")]);
    let body = &core.transport().write_bodies()[1];
    assert_eq!(body["steps"][0]["id"], "a");
    assert_eq!(body["description"], "Rerun the suite");
}

#[test]
fn save_plan_sends_the_reviewed_description_and_falls_back_on_older_servers() {
    let core = connected(RouteTransport::local());
    let path = format!("/v1/workflows/{ID}");
    let write = DescriptionWrite {
        description: "New".to_owned(),
        expected_description: "Old".to_owned(),
        description_source: "plan-3".to_owned(),
    };
    core.transport().enqueue(
        "PATCH",
        &path,
        vec![
            Reply::json(
                422,
                json!({"detail": [{"type": "extra_forbidden",
                                   "loc": ["body", "expected_description"]}]})
                .to_string(),
            ),
            Reply::json(200, workflow("Triage").to_string()),
        ],
    );
    block_on(core.save_workflow_plan(ID, &[step()], Some(&write))).unwrap();
    let bodies = core.transport().write_bodies();
    assert_eq!(bodies[0]["expected_description"], "Old");
    assert_eq!(bodies[0]["description_source"], "plan-3");
    assert_eq!(bodies[0]["steps"][0]["goal"], "Do A");
    assert_eq!(
        bodies[1],
        json!({"steps": [{"id": "a", "name": "A", "goal": "Do A", "depends_on": []}]})
    );

    core.transport().enqueue(
        "PATCH",
        &path,
        vec![Reply::json(422, r#"{"detail":"Too many steps"}"#)],
    );
    let refused = block_on(core.save_workflow_plan(ID, &[step()], None)).unwrap_err();
    assert!(matches!(
        refused,
        SessionError::Rejected { status: 422, .. }
    ));
}

#[test]
fn the_description_and_planning_chat_patch_one_field_each() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        &format!("/v1/workflows/{ID}"),
        workflow("Triage").to_string(),
    );
    block_on(core.save_workflow_description(ID, " Mine ")).unwrap();
    block_on(core.set_workflow_planning_session(ID, SESSION)).unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        [
            json!({"description": "Mine"}),
            json!({"planning_session_id": SESSION})
        ]
    );
    assert!(matches!(
        block_on(core.save_workflow_description(ID, " ")),
        Err(SessionError::InvalidInput { .. })
    ));
}

#[test]
fn delete_sends_a_delete() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        &format!("/v1/workflows/{ID}"),
        json!({"id": ID, "deleted": true}).to_string(),
    );
    block_on(core.delete_workflow(ID)).unwrap();
    let request = core.transport().writes().pop().unwrap();
    assert_eq!(request.method, "DELETE");
    assert_eq!(path_of(&request), format!("/v1/workflows/{ID}"));
}

#[test]
fn runs_and_descendants_page_with_their_cursors() {
    let core = connected(RouteTransport::local());
    let runs = format!("/v1/workflows/{ID}/runs");
    core.transport().ok(
        &runs,
        json!({"data": [], "next_cursor": "older"}).to_string(),
    );
    let page = block_on(core.workflow_runs(ID, Some("b1"), Some(SESSION))).unwrap();
    assert_eq!(page.next_cursor.as_deref(), Some("older"));
    let request = core.transport().taken().pop().unwrap();
    assert_eq!(query_value(&request, "limit").as_deref(), Some("20"));
    assert_eq!(query_value(&request, "before").as_deref(), Some("b1"));
    assert_eq!(
        query_value(&request, "session_id").as_deref(),
        Some(SESSION)
    );

    let run = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    core.transport().ok(
        &format!("{runs}/{run}/descendant_runs"),
        json!({"data": [], "next_cursor": null}).to_string(),
    );
    block_on(core.workflow_run_descendants(ID, run, SESSION, Some("d1"))).unwrap();
    let request = core.transport().taken().pop().unwrap();
    assert_eq!(query_value(&request, "after").as_deref(), Some("d1"));
    assert_eq!(
        query_value(&request, "session_id").as_deref(),
        Some(SESSION)
    );
}

#[test]
fn an_entry_sits_after_the_one_before_it_or_outside_the_journal() {
    let core = connected(RouteTransport::local());
    let path = format!("/v1/sessions/{SESSION}/journal");
    core.transport().enqueue(
        "GET",
        &path,
        vec![
            Reply::json(
                200,
                json!({"data": [{"id": "e", "position": 4, "created_at": 1, "kind": "note"}]})
                    .to_string(),
            ),
            Reply::json(200, r#"{"data": []}"#),
            Reply::json(400, r#"{"error":{"code":"stale_cursor"}}"#),
        ],
    );
    assert_eq!(
        block_on(core.journal_entry_position(SESSION, "entry")).unwrap(),
        Some(5)
    );
    let request = core.transport().taken().pop().unwrap();
    assert_eq!(query_value(&request, "order").as_deref(), Some("desc"));
    assert_eq!(query_value(&request, "after").as_deref(), Some("entry"));
    assert_eq!(
        block_on(core.journal_entry_position(SESSION, "entry")).unwrap(),
        Some(0)
    );
    assert_eq!(
        block_on(core.journal_entry_position(SESSION, "gone")).unwrap(),
        None
    );
}

#[test]
fn grants_list_add_and_remove_read_access() {
    let core = connected(RouteTransport::local());
    let path = format!("/v1/workflows/{ID}/permissions");
    core.transport().ok(
        &path,
        json!({"permissions": [
            {"user_id": "owner", "level": 4},
            {"user_id": "ada@example.com", "display_name": "Ada", "level": 1}
        ], "next_cursor": null})
        .to_string(),
    );
    let grants = block_on(core.workflow_grants(ID)).unwrap();
    assert_eq!(grants.len(), 1);
    assert_eq!(grants[0].display_name, "Ada");
    block_on(core.grant_workflow_access(ID, " bob@example.com ")).unwrap();
    let put = core.transport().writes().pop().unwrap();
    assert_eq!(put.method, "PUT");
    assert_eq!(
        body_json(&put),
        json!({"user_id": "bob@example.com", "level": 1})
    );
    core.transport()
        .ok(&format!("{path}/bob@example.com"), "{}");
    block_on(core.revoke_workflow_access(ID, "bob@example.com")).unwrap();
    let delete = core.transport().writes().pop().unwrap();
    assert_eq!(path_of(&delete), format!("{path}/bob@example.com"));
}

#[test]
fn an_automations_run_plans_read_two_pages_of_fifty_runs() {
    let core = connected(RouteTransport::local());
    let path = format!("/v1/scheduled-tasks/{ID}/run-steps");
    let run = |id: &str| {
        json!({
            "run_id": id, "plan_id": ID, "is_current": false, "workflow_id": null,
            "steps": [{"id": "a", "name": "A", "depends_on": []}], "statuses": [],
        })
    };
    core.transport().enqueue(
        "GET",
        &path,
        vec![
            Reply::json(
                200,
                json!({"runs": [run("r1")], "next_cursor": "r1"}).to_string(),
            ),
            Reply::json(
                200,
                json!({"runs": [run("r2")], "next_cursor": "r2"}).to_string(),
            ),
        ],
    );
    let runs = block_on(core.automation_run_steps(ID)).unwrap();
    let ids: Vec<&str> = runs.iter().map(|run| run.run_id.as_str()).collect();
    assert_eq!(ids, ["r1", "r2"], "stops after two pages");
    let requests: Vec<_> = core
        .transport()
        .taken()
        .into_iter()
        .filter(|request| path_of(request) == path)
        .collect();
    let [first, second] = requests.as_slice() else {
        panic!("two reads: {requests:?}")
    };
    assert_eq!(query_value(first, "limit").as_deref(), Some("50"));
    assert_eq!(query_value(first, "after"), None);
    assert_eq!(query_value(second, "after").as_deref(), Some("r1"));
    assert!(matches!(
        block_on(core.automation_run_steps("../x")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}
