//! Automations: decoding, the page order, and the create/edit/pause/run/delete writes.

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::test_support::{Reply, RouteTransport, body_json, connected, path_of};
use super::{
    Automation, AutomationDraft, AutomationFilter, AutomationState, ServerPages,
    arrange_automations, draft_body, format_run_duration,
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
        model_override: None,
        reasoning_effort: None,
        permission_mode: None,
        session_id: None,
        host_id: None,
        workspace: None,
        runs_in_sandbox: false,
        project_id: None,
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
        host_id: Some("h1".into()),
        ..AutomationDraft::default()
    };
    let saved = block_on(core.create_automation(&draft)).unwrap();
    assert_eq!(saved.id, "t1");
    block_on(core.update_automation(&saved, &draft)).unwrap();
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
        json!({"name":"Standup","prompt":"Summarize","rrule":"FREQ=DAILY;BYHOUR=9;BYMINUTE=0","agent_id":"a1","timezone":"UTC","session_mode":"continue","host_id":"h1"})
    );
    // The edit leaves out the unchanged agent and session mode.
    assert_eq!(
        body_json(&writes[1]),
        json!({"name":"Standup","prompt":"Summarize","rrule":"FREQ=DAILY;BYHOUR=9;BYMINUTE=0","timezone":"UTC","host_id":"h1"})
    );
    assert_eq!(body_json(&writes[2]), json!({"state":"paused"}));
}

fn draft() -> AutomationDraft {
    AutomationDraft {
        name: "Triage".into(),
        prompt: "Look".into(),
        rrule: "FREQ=HOURLY;BYMINUTE=0".into(),
        agent_id: "claude".into(),
        timezone: "UTC".into(),
        ..AutomationDraft::default()
    }
}

#[test]
fn create_pins_a_host_or_a_sandbox_with_the_picked_settings() {
    let pinned = AutomationDraft {
        host_id: Some("h1".into()),
        workspace: Some(" /src/app ".into()),
        project_id: Some("p1".into()),
        sends_overrides: true,
        model_override: Some("opus".into()),
        permission_mode: Some("acceptEdits".into()),
        ..draft()
    };
    let body = draft_body(&pinned, None).unwrap();
    assert_eq!(body["host_id"], "h1");
    assert_eq!(body["workspace"], "/src/app");
    assert_eq!(body["project_id"], "p1");
    assert_eq!(body["model_override"], "opus");
    assert_eq!(body["permission_mode"], "acceptEdits");
    assert!(body.get("reasoning_effort").is_none());
    assert!(body.get("execution_target").is_none());

    // A sandbox drops the host and folder; overrides the agent can't take are left out.
    let sandbox = AutomationDraft {
        runs_in_sandbox: true,
        sends_overrides: false,
        ..pinned
    };
    let body = draft_body(&sandbox, None).unwrap();
    assert_eq!(body["execution_target"], "managed_sandbox");
    assert!(body.get("host_id").is_none() && body.get("workspace").is_none());
    assert!(body.get("model_override").is_none());

    for (bad, message) in [
        (draft(), "Pick the host this automation runs on."),
        (
            AutomationDraft {
                workspace: Some("/src".into()),
                ..draft()
            },
            "Pick a host before pinning a workspace.",
        ),
    ] {
        assert!(matches!(
            draft_body(&bad, None),
            Err(SessionError::Rejected { message: text, .. }) if text == message
        ));
    }
}

#[test]
fn an_edit_sends_only_what_changed_and_clears_with_null() {
    let mut saved = automation("t1", "Triage", AutomationState::Active, None);
    saved.agent_id = "claude".into();
    saved.continues_session = true;
    saved.session_id = Some("c1".into());
    saved.project_id = Some("p1".into());
    saved.model_override = Some("opus".into());
    let edit = AutomationDraft {
        continues_session: Some(true),
        sends_overrides: true,
        start_new_session: true,
        runs_in_sandbox: true,
        ..draft()
    };
    let body = draft_body(&edit, Some(&saved)).unwrap();
    assert!(body.get("agent_id").is_none() && body.get("session_mode").is_none());
    assert_eq!(body["execution_target"], "managed_sandbox");
    assert_eq!(body["project_id"], json!(null));
    assert_eq!(body["model_override"], json!(null));
    assert_eq!(body["session_id"], json!(null));

    // A sandbox automation can move back to an unpinned host; a new agent is sent.
    saved.runs_in_sandbox = true;
    let other_agent = AutomationDraft {
        agent_id: "polly".into(),
        project_id: Some("p1".into()),
        ..draft()
    };
    let body = draft_body(&other_agent, Some(&saved)).unwrap();
    assert_eq!(body["agent_id"], "polly");
    assert_eq!(body["execution_target"], "connected_host");
    assert!(body.get("project_id").is_none() && body.get("host_id").is_none());
    assert!(body.get("session_id").is_none());
}

#[test]
fn reads_run_history() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/scheduled-tasks/t1/runs",
        r#"{"runs":[
          {"id":"r3","scheduled_task_id":"t1","status":"running","scheduled_at":100,"fired_at":101,"conversation_id":"c3","conversation_updated_at":150,"conversation_status":"running","viewer_last_seen":120,"viewer_unread":false},
          {"id":"r2","scheduled_task_id":"t1","status":"succeeded","scheduled_at":50,"fired_at":50,"finished_at":152,"conversation_id":"c2","conversation_updated_at":160,"conversation_status":"idle","viewer_last_seen":120,"viewer_unread":false},
          {"id":"r1","scheduled_task_id":"t1","status":"failed","scheduled_at":10,"error_code":"no_online_host"},
          {"id":"r0","scheduled_task_id":"t1","status":"skipped","scheduled_at":5,"error_code":"brand_new"}
        ]}"#,
    );
    let core = connected(transport);
    let runs = block_on(core.automation_runs("t1")).unwrap();
    assert_eq!(runs[0].status.in_flight_label(), Some("Running"));
    assert_eq!(runs[0].started_at, 101);
    // A running session's news waits for the turn to end.
    assert!(!runs[0].unread);
    assert!(runs[1].unread);
    assert_eq!(runs[1].duration.as_deref(), Some("1m 42s"));
    assert_eq!(runs[2].failure_stage.as_deref(), Some("Host"));
    assert_eq!(
        runs[2].failure_reason.as_deref(),
        Some("None of your hosts was online.")
    );
    assert_eq!(runs[3].failure_stage, None);
    assert_eq!(runs[3].failure_reason.as_deref(), Some("Run skipped."));
    assert!(matches!(
        block_on(core.automation_runs("../x")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}

#[test]
fn run_durations_read_like_the_web() {
    assert_eq!(format_run_duration(10, 10).as_deref(), Some("1s"));
    assert_eq!(format_run_duration(0, 120).as_deref(), Some("2m"));
    assert_eq!(format_run_duration(0, 7500).as_deref(), Some("2h 5m"));
    assert_eq!(format_run_duration(0, 7200).as_deref(), Some("2h"));
    assert_eq!(format_run_duration(10, 5), None);
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
            ..ServerPages::default()
        })
    );
    let v2 = json!({"scheduled_task_session_modes": true, "scheduled_task_projects": true,
        "managed_sandboxes_enabled": true,
        "features": {"automations_v2": true, "session_orchestration": true}});
    let pages = ServerPages::from_value(&v2).unwrap();
    assert!(pages.automations_v2 && pages.automation_projects && pages.managed_sandboxes);
    assert!(pages.automation_triggers);
    // Triggers need a session that continues across runs.
    let no_modes = json!({"features": {"session_orchestration": true}});
    assert!(
        !ServerPages::from_value(&no_modes)
            .unwrap()
            .automation_triggers
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
