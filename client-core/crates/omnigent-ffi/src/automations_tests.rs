//! Automations and trigger templates over the fake host: every mirrored enum both ways, each
//! record's fields and each export's request.

#![allow(
    clippy::too_many_lines,
    reason = "each record's fields are asserted together"
)]

use omnigent_core::automation_triggers as core_triggers;
use omnigent_core::automations as core;
use omnigent_core::schedule as rules;
use serde_json::json;

use crate::automation_triggers::{
    TriggerCondition, TriggerFields, TriggerOperator, TriggerSource, empty_trigger_fields,
    max_trigger_instructions_chars, render_trigger_prompt, trigger_fields_complete,
    trigger_session_link_placeholder, trigger_sources, trigger_template,
};
use crate::automations::{
    Automation, AutomationDraft, AutomationFilter, AutomationRunStatus, AutomationState,
    ScheduleEnd, ScheduleFrequency, ScheduleModel, SchedulePreset, ServerPages, Weekday,
    arrange_automations, build_schedule_rrule, default_schedule_model, describe_schedule,
    format_next_run, parse_schedule_rrule, schedule_needs_anchored_scheduling, validate_schedule,
};
use crate::test_support::{connected, json as reply};

const TASK: &str = r#"{"id":"t1","name":"Standup","prompt":"Summarize",
  "rrule":"FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=8;BYMINUTE=0","agent_id":"a1",
  "timezone":"America/New_York","session_mode":"continue","state":"active",
  "last_run_at":1793800000,"last_run_status":"succeeded","last_run_conversation_id":"c9",
  "next_run_at":"2026-11-05T08:00:00+00:00","updated_at":1793700000.5,
  "model_override":"opus","reasoning_effort":"high","permission_mode":"acceptEdits",
  "session_id":"s9","host_id":"h1","workspace":"/w","project_id":"p1"}"#;

fn saved(id: &str, name: &str, state: AutomationState, next_run_at: Option<i64>) -> Automation {
    Automation {
        id: id.into(),
        name: name.into(),
        prompt: "P".into(),
        rrule: "R".into(),
        schedule_text: "S".into(),
        agent_id: "A".into(),
        timezone: "UTC".into(),
        continues_session: true,
        state,
        next_run_at,
        last_run_at: Some(1),
        last_run_status: Some("ok".into()),
        last_run_session_id: Some("c".into()),
        updated_at: 2,
        model_override: Some("m".into()),
        reasoning_effort: Some("e".into()),
        permission_mode: Some("p".into()),
        session_id: Some("s".into()),
        host_id: Some("h".into()),
        workspace: Some("/w".into()),
        runs_in_sandbox: true,
        project_id: Some("pr".into()),
    }
}

fn draft() -> AutomationDraft {
    AutomationDraft {
        name: " Standup ".into(),
        prompt: "Summarize".into(),
        rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0".into(),
        agent_id: "a1".into(),
        timezone: "UTC".into(),
        continues_session: Some(true),
        host_id: Some("h1".into()),
        workspace: Some(" /src ".into()),
        runs_in_sandbox: false,
        project_id: Some("p1".into()),
        sends_overrides: true,
        model_override: Some("opus".into()),
        reasoning_effort: Some("high".into()),
        permission_mode: Some("plan".into()),
        start_new_session: false,
    }
}

#[test]
fn every_mirrored_schedule_enum_maps_both_ways() {
    for (ffi, core_value) in [
        (Weekday::Monday, rules::Weekday::Monday),
        (Weekday::Tuesday, rules::Weekday::Tuesday),
        (Weekday::Wednesday, rules::Weekday::Wednesday),
        (Weekday::Thursday, rules::Weekday::Thursday),
        (Weekday::Friday, rules::Weekday::Friday),
        (Weekday::Saturday, rules::Weekday::Saturday),
        (Weekday::Sunday, rules::Weekday::Sunday),
    ] {
        assert_eq!(rules::Weekday::from(ffi), core_value);
        assert_eq!(Weekday::from(core_value), ffi);
    }
    for (ffi, core_value) in [
        (SchedulePreset::Hourly, rules::SchedulePreset::Hourly),
        (SchedulePreset::Daily, rules::SchedulePreset::Daily),
        (SchedulePreset::Weekdays, rules::SchedulePreset::Weekdays),
        (SchedulePreset::Weekly, rules::SchedulePreset::Weekly),
        (SchedulePreset::Custom, rules::SchedulePreset::Custom),
    ] {
        assert_eq!(rules::SchedulePreset::from(ffi), core_value);
        assert_eq!(SchedulePreset::from(core_value), ffi);
    }
    for (ffi, core_value) in [
        (ScheduleFrequency::Hourly, rules::ScheduleFrequency::Hourly),
        (ScheduleFrequency::Daily, rules::ScheduleFrequency::Daily),
        (ScheduleFrequency::Weekly, rules::ScheduleFrequency::Weekly),
        (
            ScheduleFrequency::Monthly,
            rules::ScheduleFrequency::Monthly,
        ),
        (ScheduleFrequency::Yearly, rules::ScheduleFrequency::Yearly),
    ] {
        assert_eq!(rules::ScheduleFrequency::from(ffi), core_value);
        assert_eq!(ScheduleFrequency::from(core_value), ffi);
    }
    for (ffi, core_value) in [
        (AutomationFilter::All, core::AutomationFilter::All),
        (AutomationFilter::Active, core::AutomationFilter::Active),
        (AutomationFilter::Paused, core::AutomationFilter::Paused),
    ] {
        assert_eq!(core::AutomationFilter::from(ffi), core_value);
        assert_eq!(AutomationFilter::from(core_value), ffi);
    }
    for (ffi, core_value) in [
        (ScheduleEnd::Never, rules::ScheduleEnd::Never),
        (
            ScheduleEnd::Count { count: 7 },
            rules::ScheduleEnd::Count(7),
        ),
        (ScheduleEnd::Until { at: -9 }, rules::ScheduleEnd::Until(-9)),
    ] {
        assert_eq!(rules::ScheduleEnd::from(ffi), core_value);
        assert_eq!(ScheduleEnd::from(core_value), ffi);
    }
}

#[test]
fn a_schedule_model_round_trips_and_builds_the_same_rule() {
    let model = ScheduleModel {
        preset: SchedulePreset::Custom,
        hour: 23,
        minute: 59,
        weekdays: vec![Weekday::Sunday],
        frequency: ScheduleFrequency::Yearly,
        interval: 3,
        month_days: vec![1, 31],
        month: 12,
        end: ScheduleEnd::Count { count: 5 },
    };
    assert_eq!(
        ScheduleModel::from(rules::ScheduleModel::from(model.clone())),
        model
    );
    let rule = build_schedule_rrule(model);
    assert_eq!(
        rule,
        "FREQ=YEARLY;INTERVAL=3;BYMONTH=12;BYMONTHDAY=1,31;BYHOUR=23;BYMINUTE=59;COUNT=5"
    );
    let parsed = parse_schedule_rrule(rule).unwrap();
    assert_eq!(parsed.frequency, ScheduleFrequency::Yearly);
    assert_eq!(parsed.month_days, [1, 31]);
    assert_eq!(parsed.end, ScheduleEnd::Count { count: 5 });
    assert_eq!(parse_schedule_rrule("not a rule".into()), None);
}

#[test]
fn a_month_day_too_large_for_the_core_is_left_out_not_wrapped() {
    let model = ScheduleModel {
        month_days: vec![256 + 5, 7],
        ..default_schedule_model()
    };
    assert_eq!(rules::ScheduleModel::from(model).month_days, [7]);
}

#[test]
fn the_default_model_validation_and_text_are_the_cores() {
    let model = default_schedule_model();
    assert_eq!(model.preset, SchedulePreset::Daily);
    assert_eq!((model.hour, model.minute), (9, 0));
    assert_eq!(model.end, ScheduleEnd::Never);
    assert_eq!(validate_schedule(model.clone(), 0, false), None);
    assert!(!schedule_needs_anchored_scheduling(model.clone()));

    let past_end = ScheduleModel {
        end: ScheduleEnd::Until { at: 10 },
        ..model.clone()
    };
    assert!(validate_schedule(past_end.clone(), 100, false).is_some());
    assert_eq!(validate_schedule(past_end, 100, true), None);
    assert!(schedule_needs_anchored_scheduling(ScheduleModel {
        end: ScheduleEnd::Count { count: 2 },
        ..model
    }));
    assert_eq!(
        describe_schedule("FREQ=DAILY;BYHOUR=9;BYMINUTE=0".into()),
        "Every day at 9:00 AM"
    );
    assert_eq!(format_next_run(1000, 1000), "soon");
    assert_eq!(format_next_run(i64::MIN, i64::MAX), "soon");
}

#[test]
fn a_saved_automation_round_trips_and_arranges_each_state() {
    let active = saved("a", "A", AutomationState::Active, Some(5));
    let paused = saved("p", "P", AutomationState::Paused, None);
    let odd = saved(
        "u",
        "U",
        AutomationState::Unknown {
            value: "archived".into(),
        },
        None,
    );
    for automation in [&active, &paused, &odd] {
        assert_eq!(
            &Automation::from(core::Automation::from(automation.clone())),
            automation
        );
    }
    let core_record = core::Automation::from(odd.clone());
    assert_eq!(core_record.prompt, "P");
    assert_eq!(core_record.rrule, "R");
    assert_eq!(core_record.schedule_text, "S");
    assert_eq!(core_record.agent_id, "A");
    assert_eq!(core_record.workspace.as_deref(), Some("/w"));
    assert_eq!(core_record.project_id.as_deref(), Some("pr"));
    assert!(core_record.runs_in_sandbox);

    let list = vec![paused.clone(), active.clone(), odd];
    let arranged = arrange_automations(list.clone(), AutomationFilter::All, String::new());
    assert_eq!(arranged[0].id, "a", "active comes first");
    assert_eq!(
        arrange_automations(list.clone(), AutomationFilter::Active, String::new()),
        [active]
    );
    assert_eq!(
        arrange_automations(list, AutomationFilter::Paused, "p".into()),
        [paused]
    );
}

#[test]
fn a_draft_converts_each_field() {
    let converted = core::AutomationDraft::from(AutomationDraft {
        start_new_session: true,
        runs_in_sandbox: true,
        ..draft()
    });
    assert_eq!(converted.name, " Standup ");
    assert_eq!(converted.prompt, "Summarize");
    assert_eq!(converted.rrule, "FREQ=DAILY;BYHOUR=9;BYMINUTE=0");
    assert_eq!(converted.agent_id, "a1");
    assert_eq!(converted.timezone, "UTC");
    assert_eq!(converted.continues_session, Some(true));
    assert_eq!(converted.host_id.as_deref(), Some("h1"));
    assert_eq!(converted.workspace.as_deref(), Some(" /src "));
    assert!(converted.runs_in_sandbox);
    assert_eq!(converted.project_id.as_deref(), Some("p1"));
    assert!(converted.sends_overrides);
    assert_eq!(converted.model_override.as_deref(), Some("opus"));
    assert_eq!(converted.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(converted.permission_mode.as_deref(), Some("plan"));
    assert!(converted.start_new_session);
}

#[test]
fn server_pages_map_each_flag_to_its_own_field() {
    let mut harness = connected();
    let read = |harness: &mut crate::test_support::Harness, body: &str| {
        harness.http.route("/v1/info", reply(200, body));
        harness
            .call(|core| async move { core.server_pages().await })
            .unwrap()
    };
    let none = ServerPages {
        automations: false,
        automation_session_modes: false,
        usage: false,
        archive_worktree_cleanup: false,
        sharing: false,
        sharing_disabled: false,
        canvas: false,
        automations_v2: false,
        automation_projects: false,
        managed_sandboxes: false,
        automation_triggers: false,
    };
    assert_eq!(read(&mut harness, r#"{"single_user":true}"#), none);
    for (body, expected) in [
        (
            r#"{"single_user":true,"automations_enabled":true}"#,
            ServerPages {
                automations: true,
                ..none
            },
        ),
        (
            r#"{"single_user":true,"scheduled_task_session_modes":true}"#,
            ServerPages {
                automation_session_modes: true,
                ..none
            },
        ),
        (
            r#"{"single_user":true,"features":{"usage_page":true}}"#,
            ServerPages {
                usage: true,
                ..none
            },
        ),
        (
            r#"{"single_user":true,"archive_worktree_cleanup":true}"#,
            ServerPages {
                archive_worktree_cleanup: true,
                ..none
            },
        ),
        (
            r#"{"sharing_mode":"on"}"#,
            ServerPages {
                sharing: true,
                ..none
            },
        ),
        (
            r#"{"sharing_mode":"off"}"#,
            ServerPages {
                sharing_disabled: true,
                ..none
            },
        ),
        (
            r#"{"single_user":true,"features":{"canvas":true}}"#,
            ServerPages {
                canvas: true,
                ..none
            },
        ),
        (
            r#"{"single_user":true,"features":{"automations_v2":true}}"#,
            ServerPages {
                automations_v2: true,
                ..none
            },
        ),
        (
            r#"{"single_user":true,"scheduled_task_projects":true}"#,
            ServerPages {
                automation_projects: true,
                ..none
            },
        ),
        (
            r#"{"single_user":true,"managed_sandboxes_enabled":true}"#,
            ServerPages {
                managed_sandboxes: true,
                ..none
            },
        ),
        (
            r#"{"single_user":true,"scheduled_task_session_modes":true,"features":{"session_orchestration":true}}"#,
            ServerPages {
                automation_session_modes: true,
                automation_triggers: true,
                ..none
            },
        ),
    ] {
        assert_eq!(read(&mut harness, body), expected, "{body}");
    }
}

#[test]
fn automations_are_listed_created_edited_paused_run_and_deleted() {
    let mut harness = connected();
    let list = "/v1/scheduled-tasks";
    harness.http.route_method(
        "GET",
        list,
        reply(200, &format!(r#"{{"scheduled_tasks":[{TASK}]}}"#)),
    );
    harness.http.route_method("POST", list, reply(201, TASK));
    harness
        .http
        .route_method("PATCH", "/v1/scheduled-tasks/t1", reply(200, TASK));
    harness.http.route_method(
        "POST",
        "/v1/scheduled-tasks/t1/run",
        reply(202, r#"{"triggered":true,"id":"t1"}"#),
    );
    harness.http.route_method(
        "DELETE",
        "/v1/scheduled-tasks/t1",
        reply(200, r#"{"deleted":true,"id":"t1"}"#),
    );

    let automations = harness
        .call(|core| async move { core.automations().await })
        .unwrap();
    let first = automations[0].clone();
    assert_eq!(first.id, "t1");
    assert_eq!(first.name, "Standup");
    assert_eq!(first.prompt, "Summarize");
    assert_eq!(first.schedule_text, "Weekdays at 8:00 AM");
    assert_eq!(first.agent_id, "a1");
    assert_eq!(first.timezone, "America/New_York");
    assert!(first.continues_session);
    assert_eq!(first.state, AutomationState::Active);
    assert_eq!(first.next_run_at, Some(1_793_865_600));
    assert_eq!(first.last_run_at, Some(1_793_800_000));
    assert_eq!(first.last_run_status.as_deref(), Some("succeeded"));
    assert_eq!(first.last_run_session_id.as_deref(), Some("c9"));
    assert_eq!(first.updated_at, 1_793_700_000);
    assert_eq!(first.model_override.as_deref(), Some("opus"));
    assert_eq!(first.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(first.permission_mode.as_deref(), Some("acceptEdits"));
    assert_eq!(first.session_id.as_deref(), Some("s9"));
    assert_eq!(first.host_id.as_deref(), Some("h1"));
    assert_eq!(first.workspace.as_deref(), Some("/w"));
    assert_eq!(first.project_id.as_deref(), Some("p1"));

    let created = harness
        .call(|core| async move { core.create_automation(draft()).await })
        .unwrap();
    assert_eq!(created.id, "t1");
    assert_eq!(
        harness.last_request(),
        (
            format!("POST {list}"),
            json!({"name": "Standup", "prompt": "Summarize",
                   "rrule": "FREQ=DAILY;BYHOUR=9;BYMINUTE=0", "agent_id": "a1",
                   "timezone": "UTC", "session_mode": "continue", "host_id": "h1",
                   "workspace": "/src", "project_id": "p1", "model_override": "opus",
                   "reasoning_effort": "high", "permission_mode": "plan"})
        )
    );

    let edited = harness
        .call({
            let saved = first.clone();
            |core| async move {
                core.update_automation(
                    saved,
                    AutomationDraft {
                        name: "Renamed".into(),
                        rrule: first.rrule.clone(),
                        prompt: first.prompt.clone(),
                        agent_id: first.agent_id.clone(),
                        timezone: first.timezone.clone(),
                        host_id: first.host_id.clone(),
                        workspace: first.workspace.clone(),
                        project_id: first.project_id.clone(),
                        model_override: first.model_override.clone(),
                        reasoning_effort: first.reasoning_effort.clone(),
                        permission_mode: first.permission_mode.clone(),
                        ..draft()
                    },
                )
                .await
            }
        })
        .unwrap();
    assert_eq!(edited.id, "t1");
    let (line, body) = harness.last_request();
    assert_eq!(line, "PATCH /v1/scheduled-tasks/t1");
    assert_eq!(body["name"], json!("Renamed"));
    assert!(body.get("agent_id").is_none(), "unchanged: {body}");

    let paused = harness
        .call(|core| async move { core.set_automation_paused("t1".into(), true).await })
        .unwrap();
    assert_eq!(paused.id, "t1");
    assert_eq!(
        harness.last_request(),
        (
            "PATCH /v1/scheduled-tasks/t1".into(),
            json!({"state": "paused"})
        )
    );
    harness
        .call(|core| async move { core.set_automation_paused("t1".into(), false).await })
        .unwrap();
    assert_eq!(harness.last_request().1, json!({"state": "active"}));

    harness
        .call(|core| async move { core.run_automation("t1".into()).await })
        .unwrap();
    assert_eq!(harness.last_request().0, "POST /v1/scheduled-tasks/t1/run");
    harness
        .call(|core| async move { core.delete_automation("t1".into()).await })
        .unwrap();
    assert_eq!(harness.last_request().0, "DELETE /v1/scheduled-tasks/t1");
}

#[test]
fn run_history_maps_every_status_and_field() {
    let mut harness = connected();
    harness.http.route(
        "/v1/scheduled-tasks/t1/runs",
        reply(
            200,
            r#"{"runs":[
              {"id":"r0","status":"scheduled","scheduled_at":1},
              {"id":"r1","status":"starting","scheduled_at":1},
              {"id":"r2","status":"running","scheduled_at":100,"fired_at":101,"conversation_id":"c2"},
              {"id":"r3","status":"succeeded","scheduled_at":50,"fired_at":50,"finished_at":152,
               "conversation_id":"c3","conversation_updated_at":160,"conversation_status":"idle","viewer_unread":true},
              {"id":"r4","status":"failed","scheduled_at":10,"error_code":"no_online_host"},
              {"id":"r5","status":"skipped","scheduled_at":5},
              {"id":"r6","status":"incomplete","scheduled_at":5},
              {"id":"r7","status":"brand_new","scheduled_at":5}]}"#,
        ),
    );
    let runs = harness
        .call(|core| async move { core.automation_runs("t1".into()).await })
        .unwrap();
    assert_eq!(
        runs.iter()
            .map(|run| run.status.clone())
            .collect::<Vec<_>>(),
        [
            AutomationRunStatus::Scheduled,
            AutomationRunStatus::Starting,
            AutomationRunStatus::Running,
            AutomationRunStatus::Succeeded,
            AutomationRunStatus::Failed,
            AutomationRunStatus::Skipped,
            AutomationRunStatus::Incomplete,
            AutomationRunStatus::Unknown {
                value: "brand_new".into()
            },
        ]
    );
    assert_eq!(runs[0].in_flight_label.as_deref(), Some("Queued"));
    assert_eq!(runs[1].in_flight_label.as_deref(), Some("Starting"));
    assert_eq!(runs[2].in_flight_label.as_deref(), Some("Running"));
    assert_eq!(runs[2].id, "r2");
    assert_eq!(runs[2].started_at, 101);
    assert_eq!(runs[2].session_id.as_deref(), Some("c2"));
    assert_eq!(runs[3].in_flight_label, None);
    assert_eq!(runs[3].duration.as_deref(), Some("1m 42s"));
    assert!(runs[3].unread);
    assert_eq!(runs[4].failure_stage.as_deref(), Some("Host"));
    assert_eq!(
        runs[4].failure_reason.as_deref(),
        Some("None of your hosts was online.")
    );
}

#[test]
fn trigger_enums_map_both_ways_and_sources_keep_the_pages_order() {
    for (ffi, core_value) in [
        (TriggerSource::Jira, core_triggers::TriggerSource::Jira),
        (TriggerSource::Slack, core_triggers::TriggerSource::Slack),
        (TriggerSource::Github, core_triggers::TriggerSource::Github),
    ] {
        assert_eq!(core_triggers::TriggerSource::from(ffi), core_value);
        assert_eq!(TriggerSource::from(core_value), ffi);
    }
    for (ffi, core_value) in [
        (TriggerOperator::Is, core_triggers::TriggerOperator::Is),
        (
            TriggerOperator::IsNot,
            core_triggers::TriggerOperator::IsNot,
        ),
        (
            TriggerOperator::Contains,
            core_triggers::TriggerOperator::Contains,
        ),
        (
            TriggerOperator::NotContains,
            core_triggers::TriggerOperator::NotContains,
        ),
        (
            TriggerOperator::About,
            core_triggers::TriggerOperator::About,
        ),
        (
            TriggerOperator::Matches,
            core_triggers::TriggerOperator::Matches,
        ),
        (
            TriggerOperator::Empty,
            core_triggers::TriggerOperator::Empty,
        ),
        (
            TriggerOperator::NotEmpty,
            core_triggers::TriggerOperator::NotEmpty,
        ),
    ] {
        assert_eq!(core_triggers::TriggerOperator::from(ffi), core_value);
        assert_eq!(TriggerOperator::from(core_value), ffi);
    }
    assert_eq!(
        trigger_sources(),
        [
            TriggerSource::Jira,
            TriggerSource::Slack,
            TriggerSource::Github
        ]
    );
}

#[test]
fn a_template_carries_each_of_the_cores_fields() {
    for source in trigger_sources() {
        let core_source = core_triggers::TriggerSource::from(source);
        let expected = core_triggers::trigger_template(core_source);
        let template = trigger_template(source);
        assert_eq!(template.source, source);
        assert_eq!(template.title, expected.title);
        assert_eq!(template.name, expected.name);
        assert_eq!(template.scope_label, expected.scope_label);
        assert_eq!(template.scope_placeholder, expected.scope_placeholder);
        assert_eq!(
            template.instructions_placeholder,
            expected.instructions_placeholder
        );
        assert_eq!(template.link_back_label, expected.link_back_label);
        assert_eq!(template.item_plural, expected.item_plural);
        assert_eq!(template.tools_example, expected.tools_example);
        assert_eq!(template.service_name, core_source.service_name());
        assert_eq!(template.events.len(), expected.events.len());
        assert_eq!(template.events[0].id, expected.events[0].id);
        assert_eq!(template.events[0].label, expected.events[0].label);
        assert_eq!(
            template.events[0].author_action,
            expected.events[0].author_action
        );
        assert_eq!(template.fields.len(), expected.fields.len());
        assert_eq!(template.fields[0].id, expected.fields[0].id);
        assert_eq!(template.fields[0].label, expected.fields[0].label);
        assert_eq!(
            template.fields[0].placeholder,
            expected.fields[0].placeholder
        );
        let operator = expected.fields[0].operators[0];
        let choice = &template.fields[0].operators[0];
        assert_eq!(choice.operator, TriggerOperator::from(operator));
        assert_eq!(choice.label, expected.fields[0].operator_label(operator));
        assert_eq!(choice.is_valueless, operator.is_valueless());
    }
}

#[test]
fn fields_round_trip_and_render_with_the_placement_and_overrides() {
    let empty = empty_trigger_fields(TriggerSource::Jira);
    assert!(!trigger_fields_complete(empty.clone()), "no scope yet");
    let fields = TriggerFields {
        event: empty.event,
        scope: "ES".into(),
        conditions: vec![TriggerCondition {
            field: "label".into(),
            operator: TriggerOperator::Is,
            value: "omnigent".into(),
        }],
        instructions: "Investigate the ticket.".into(),
        link_back: true,
    };
    assert_eq!(
        TriggerFields::from(core_triggers::TriggerFields::from(fields.clone())),
        fields
    );
    assert!(trigger_fields_complete(fields.clone()));
    let link = format!("https://x/c/{}", trigger_session_link_placeholder());
    let same_host = render_trigger_prompt(
        TriggerSource::Jira,
        fields.clone(),
        false,
        link.clone(),
        None,
        None,
    );
    let in_sandboxes = render_trigger_prompt(
        TriggerSource::Jira,
        fields,
        true,
        link.clone(),
        Some("opus".into()),
        Some("high".into()),
    );
    assert_ne!(same_host, in_sandboxes);
    assert!(same_host.contains("Investigate the ticket."));
    assert!(same_host.contains(&link));
    assert!(in_sandboxes.contains("opus"));
    assert!(in_sandboxes.contains("high"));
    assert_eq!(
        u64::from(max_trigger_instructions_chars()),
        u64::try_from(core_triggers::MAX_INSTRUCTIONS_CHARS).unwrap()
    );
    assert_eq!(
        trigger_session_link_placeholder(),
        core_triggers::SESSION_LINK_ID_PLACEHOLDER
    );
}
