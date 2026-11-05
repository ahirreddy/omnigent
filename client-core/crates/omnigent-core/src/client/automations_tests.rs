//! Automations: decoding, the page order, and the create/edit/pause/run/delete writes.

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::test_support::{Reply, RouteTransport, body_json, connected, path_of};
use super::{
    Automation, AutomationDraft, AutomationFilter, AutomationState, ServerPages,
    arrange_automations,
};

const TASK: &str = r#"{"id":"t1","name":"Standup","prompt":"Summarize","rrule":"FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=8;BYMINUTE=0","agent_id":"a1","timezone":"America/New_York","session_mode":"continue","state":"active","last_run_at":1793800000,"last_run_status":"succeeded","last_run_conversation_id":"c9","next_run_at":"2026-11-05T08:00:00+00:00","updated_at":1793700000.5}"#;

fn automation(id: &str, name: &str, state: AutomationState, next: Option<i64>) -> Automation {
    Automation {
        id: id.into(),
        name: name.into(),
        prompt: String::new(),
        rrule: String::new(),
        schedule_text: String::new(),
        agent_id: String::new(),
        timezone: "UTC".into(),
        continues_session: false,
        state,
        next_run_at: next,
        last_run_at: None,
        last_run_status: None,
        last_run_session_id: None,
        updated_at: 0,
    }
}

#[test]
fn lists_and_decodes_automations() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/scheduled-tasks",
        format!(
            r#"{{"scheduled_tasks":[{TASK},{{"id":"t2","name":"Odd","rrule":"x","state":"archived"}}]}}"#
        ),
    );
    let core = connected(transport);
    let automations = block_on(core.automations()).unwrap();
    let first = &automations[0];
    assert_eq!(first.schedule_text, "Weekdays at 8:00 AM");
    assert_eq!(first.next_run_at, Some(1_793_865_600));
    assert!(first.continues_session);
    assert_eq!(first.last_run_session_id.as_deref(), Some("c9"));
    assert_eq!(first.updated_at, 1_793_700_000);
    assert_eq!(
        automations[1].state,
        AutomationState::Unknown {
            value: "archived".into()
        }
    );
    assert_eq!(automations[1].schedule_text, "x");

    let malformed = RouteTransport::local();
    malformed.ok("/v1/scheduled-tasks", r#"{"tasks":[]}"#);
    assert!(matches!(
        block_on(connected(malformed).automations()),
        Err(SessionError::MalformedResponse { .. })
    ));
}

#[test]
fn arranges_active_soonest_first_then_paused_by_name() {
    let all = vec![
        automation("p2", "Zeta", AutomationState::Paused, None),
        automation("a3", "No next", AutomationState::Active, None),
        automation("a2", "Later", AutomationState::Active, Some(200)),
        automation("p1", "Alpha", AutomationState::Paused, None),
        automation("a1", "Soon", AutomationState::Active, Some(100)),
    ];
    let ids = |list: Vec<Automation>| list.into_iter().map(|a| a.id).collect::<Vec<_>>();
    assert_eq!(
        ids(arrange_automations(&all, AutomationFilter::All, "")),
        ["a1", "a2", "a3", "p1", "p2"]
    );
    assert_eq!(
        ids(arrange_automations(&all, AutomationFilter::Paused, "")),
        ["p1", "p2"]
    );
    assert_eq!(
        ids(arrange_automations(
            &all,
            AutomationFilter::Active,
            " LATER "
        )),
        ["a2"]
    );
}

#[test]
fn creates_edits_pauses_runs_and_deletes() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("POST"),
        "/v1/scheduled-tasks",
        None,
        Reply::json(201, TASK),
    );
    transport.respond(
        Some("PATCH"),
        "/v1/scheduled-tasks/t1",
        None,
        Reply::json(200, TASK),
    );
    transport.respond(
        Some("POST"),
        "/v1/scheduled-tasks/t1/run",
        None,
        Reply::json(202, r#"{"triggered":true,"id":"t1"}"#),
    );
    transport.respond(
        Some("DELETE"),
        "/v1/scheduled-tasks/t1",
        None,
        Reply::json(200, r#"{"deleted":true,"id":"t1"}"#),
    );
    let core = connected(transport);
    let draft = AutomationDraft {
        name: "  Standup ".into(),
        prompt: "Summarize".into(),
        rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0".into(),
        agent_id: "a1".into(),
        timezone: "UTC".into(),
        continues_session: Some(true),
    };
    assert_eq!(block_on(core.create_automation(&draft)).unwrap().id, "t1");
    block_on(core.update_automation("t1", &draft)).unwrap();
    block_on(core.set_automation_paused("t1", true)).unwrap();
    block_on(core.run_automation("t1")).unwrap();
    block_on(core.delete_automation("t1")).unwrap();

    let writes = core.transport().writes();
    let lines: Vec<String> = writes
        .iter()
        .map(|request| format!("{} {}", request.method, path_of(request)))
        .collect();
    assert_eq!(
        lines,
        [
            "POST /v1/scheduled-tasks",
            "PATCH /v1/scheduled-tasks/t1",
            "PATCH /v1/scheduled-tasks/t1",
            "POST /v1/scheduled-tasks/t1/run",
            "DELETE /v1/scheduled-tasks/t1",
        ]
    );
    assert_eq!(
        body_json(&writes[0]),
        json!({"name":"Standup","prompt":"Summarize","rrule":"FREQ=DAILY;BYHOUR=9;BYMINUTE=0","agent_id":"a1","timezone":"UTC","session_mode":"continue"})
    );
    assert_eq!(body_json(&writes[2]), json!({"state":"paused"}));
}

#[test]
fn an_incomplete_draft_or_bad_id_sends_nothing() {
    let core = connected(RouteTransport::local());
    let empty = AutomationDraft {
        agent_id: "a1".into(),
        ..AutomationDraft::default()
    };
    assert!(matches!(
        block_on(core.create_automation(&empty)),
        Err(SessionError::Rejected { status: 400, .. })
    ));
    assert!(matches!(
        block_on(core.delete_automation("../x")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
    assert_eq!(core.transport().writes(), []);
}

#[test]
fn pages_follow_what_the_server_advertises() {
    let current = json!({"automations_enabled": true, "scheduled_task_session_modes": true,
        "features": {"usage_page": true, "canvas": true}, "archive_worktree_cleanup": true,
        "single_user": false, "sharing_mode": "on"});
    assert_eq!(
        ServerPages::from_value(&current),
        Ok(ServerPages {
            automations: true,
            automation_session_modes: true,
            usage: true,
            archive_worktree_cleanup: true,
            sharing: true,
            canvas: true,
        })
    );
    // An older server that names none of them offers none; a single-user one has no sharing.
    assert_eq!(
        ServerPages::from_value(&json!({"single_user": true})),
        Ok(ServerPages::default())
    );
    // Sharing is on unless the server turns it off.
    assert!(ServerPages::from_value(&json!({})).is_ok_and(|pages| pages.sharing));
    assert!(ServerPages::from_value(&json!({"sharing_mode": "off"})).is_ok_and(|p| !p.sharing));
    assert!(ServerPages::from_value(&json!({"features": {"usage_page": "yes"}})).is_err());
    assert!(ServerPages::from_value(&json!({"features": {"canvas": "yes"}})).is_err());
    assert!(ServerPages::from_value(&json!({"sharing_mode": 1})).is_err());
}
