//! Omni Advisor: settings, both switches, the admin prompt, Run now and its summary.

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::test_support::{Reply, RouteTransport, connected};
use super::{
    AdvisorPrompt, AdvisorRunSkipped, AdvisorRunStarted, AdvisorRuns, AdvisorScope,
    AdvisorSettings, parse_run_users,
};

const SETTINGS: &str = "/v1/proactive-agent/settings";
const PROMPT: &str = "/v1/proactive-agent/prompt";
const RUNS: &str = "/v1/proactive-agent/runs";

#[test]
fn reads_the_settings_and_which_items_are_the_advisors() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        SETTINGS,
        r#"{"workspace_enabled":false,"user_enabled":true,"enabled":false,
            "can_manage_workspace":false,"agent_id":"agent-advisor"}"#,
    );
    let settings = block_on(core.advisor_settings()).unwrap();
    assert_eq!(
        settings,
        AdvisorSettings {
            workspace_enabled: false,
            user_enabled: true,
            enabled: false,
            can_manage_workspace: false,
            agent_id: Some("agent-advisor".into()),
        }
    );
    // An admin turned it off for everyone: the caller's switch reads off.
    assert!(!settings.shows_on());
    assert!(settings.posted("agent-advisor"));
    assert!(!settings.posted("agent-other"));

    // Missing values are on, as the server's store defaults them, and managing is allowed.
    core.transport().ok(SETTINGS, "{}");
    let defaults = block_on(core.advisor_settings()).unwrap();
    assert!(defaults.enabled && defaults.shows_on() && defaults.can_manage_workspace);
    assert!(!defaults.posted(""));

    core.transport()
        .ok(SETTINGS, r#"{"workspace_enabled":"yes"}"#);
    assert!(matches!(
        block_on(core.advisor_settings()),
        Err(SessionError::MalformedResponse { detail }) if detail.contains(SETTINGS)
    ));
}

#[test]
fn an_unoffered_advisor_is_a_not_found_read() {
    let core = connected(RouteTransport::local());
    core.transport().respond(
        None,
        SETTINGS,
        None,
        Reply::json(404, r#"{"detail":"not found"}"#),
    );
    assert!(matches!(
        block_on(core.advisor_settings()),
        Err(SessionError::HttpStatus { status: 404 })
    ));
}

#[test]
fn flips_the_callers_and_the_workspaces_switch() {
    let core = connected(RouteTransport::local());
    let answer = r#"{"workspace_enabled":true,"user_enabled":false,"enabled":false,
                     "can_manage_workspace":true,"agent_id":"a"}"#;
    core.transport()
        .ok("/v1/proactive-agent/settings/me", answer);
    core.transport()
        .ok("/v1/proactive-agent/settings/workspace", answer);
    let saved = block_on(core.set_advisor_enabled(AdvisorScope::Me, false)).unwrap();
    assert!(!saved.user_enabled);
    block_on(core.set_advisor_enabled(AdvisorScope::Workspace, true)).unwrap();

    let writes = core.transport().writes();
    assert!(writes.iter().all(|request| request.method == "PUT"));
    assert!(writes[0].url.ends_with("/settings/me"));
    assert!(writes[1].url.ends_with("/settings/workspace"));
    assert_eq!(
        core.transport().write_bodies(),
        [json!({"enabled": false}), json!({"enabled": true})]
    );

    core.transport().respond(
        Some("PUT"),
        "/v1/proactive-agent/settings/workspace",
        None,
        Reply::json(
            403,
            r#"{"error":{"code":"forbidden","message":"Admin privileges required to change the workspace setting"}}"#,
        ),
    );
    assert!(matches!(
        block_on(core.set_advisor_enabled(AdvisorScope::Workspace, false)),
        Err(SessionError::Forbidden)
    ));
}

#[test]
fn saves_and_restores_the_prompt() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        PROMPT,
        r#"{"prompt":"Be brief.","default_prompt":"Built in.","overridden":true}"#,
    );
    assert_eq!(
        block_on(core.advisor_prompt()).unwrap(),
        AdvisorPrompt {
            prompt: "Be brief.".into(),
            default_prompt: "Built in.".into(),
            overridden: true,
        }
    );
    block_on(core.save_advisor_prompt(Some("Be brief."))).unwrap();
    // Blank and `None` both restore the built-in prompt.
    block_on(core.save_advisor_prompt(Some("  \n"))).unwrap();
    block_on(core.save_advisor_prompt(None)).unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        [
            json!({"prompt": "Be brief."}),
            json!({"prompt": null}),
            json!({"prompt": null}),
        ]
    );

    core.transport()
        .ok(PROMPT, r#"{"default_prompt":"Built in."}"#);
    assert!(matches!(
        block_on(core.advisor_prompt()),
        Err(SessionError::MalformedResponse { .. })
    ));
}

#[test]
fn runs_now_and_summarizes_as_the_web() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        RUNS,
        r#"{"started":[{"user_id":"ann@example.com","task_id":"t1","run_id":"r1"}],
            "skipped":[{"user_id":"bo@example.com","reason":"turned_off"},
                       {"user_id":"cy@example.com","reason":"brand_new"}],
            "truncated":false}"#,
    );
    let users = parse_run_users("ann@example.com bo@example.com, cy@example.com");
    let runs = block_on(core.run_advisor(&users)).unwrap();
    assert_eq!(
        runs.started,
        [AdvisorRunStarted {
            user_id: "ann@example.com".into(),
            task_id: "t1".into(),
            run_id: Some("r1".into()),
        }]
    );
    assert_eq!(
        runs.summary(),
        "Started 1 run. Skipped: bo@example.com (turned off), cy@example.com (brand_new)."
    );
    assert_eq!(
        core.transport().write_bodies(),
        [json!({"users": ["ann@example.com", "bo@example.com", "cy@example.com"]})]
    );

    core.transport().respond(
        Some("POST"),
        RUNS,
        None,
        Reply::json(
            400,
            r#"{"error":{"code":"invalid_input","message":"Use \"*\" alone to run for every user"}}"#,
        ),
    );
    assert!(matches!(
        block_on(core.run_advisor(&["*".into(), "ann@example.com".into()])),
        Err(SessionError::Rejected { status: 400, message }) if message.contains("alone")
    ));
}

#[test]
fn summaries_count_runs_and_say_when_one_request_capped_them() {
    let none = AdvisorRuns {
        started: Vec::new(),
        skipped: vec![AdvisorRunSkipped {
            user_id: "ann@example.com".into(),
            reason: "no_task".into(),
        }],
        truncated: false,
    };
    assert_eq!(
        none.summary(),
        "Started 0 runs. Skipped: ann@example.com (no task yet)."
    );
    let capped = AdvisorRuns {
        started: vec![
            AdvisorRunStarted {
                user_id: "a".into(),
                task_id: "t".into(),
                run_id: None,
            };
            2
        ],
        skipped: Vec::new(),
        truncated: true,
    };
    assert_eq!(
        capped.summary(),
        "Started 2 runs, the most one request starts."
    );
}

#[test]
fn run_users_split_on_commas_and_spaces_once_each() {
    assert_eq!(
        parse_run_users(" ann@example.com,bo@example.com\n ann@example.com ,, "),
        ["ann@example.com", "bo@example.com"]
    );
    assert_eq!(parse_run_users("*"), ["*"]);
    assert_eq!(parse_run_users(" , "), Vec::<String>::new());
}
