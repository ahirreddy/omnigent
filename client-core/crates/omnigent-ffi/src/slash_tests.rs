//! The `/` menu and command sends over the fake host: every action arm, and the conversions.

use omnigent_core::slash as core;
use serde_json::json;

use crate::slash::{
    Skill, SlashAction, SlashCommand, SlashOptions, context_report, mcp_report, mention_preamble,
    offers_smart_routing, skill_commands, slash_action, slash_commands,
};
use crate::test_support::{configuration_on, connected, json as reply};

fn skill(name: &str) -> Skill {
    Skill {
        name: name.into(),
        description: format!("{name} description"),
        display_name: Some(format!("{name} label")),
    }
}

const BACKGROUND_TITLES_HEADER: &str = "X-Omnigent-Background-Session-Titles";

const NO_OPTIONS: SlashOptions = SlashOptions {
    server_clears: false,
    smart_routing: false,
    routes_native_panes: false,
};

#[test]
fn options_and_skills_round_trip_each_field() {
    for options in [
        SlashOptions {
            server_clears: true,
            ..NO_OPTIONS
        },
        SlashOptions {
            smart_routing: true,
            ..NO_OPTIONS
        },
        SlashOptions {
            routes_native_panes: true,
            ..NO_OPTIONS
        },
    ] {
        assert_eq!(
            SlashOptions::from(core::SlashOptions::from(options)),
            options
        );
    }
    let original = skill("review");
    assert_eq!(Skill::from(core::Skill::from(original.clone())), original);
    assert_eq!(
        SlashCommand::from(core::SlashCommand {
            name: "n".into(),
            prefix: "$".into(),
            description: "d".into(),
            is_skill: true,
        }),
        SlashCommand {
            name: "n".into(),
            prefix: "$".into(),
            description: "d".into(),
            is_skill: true,
        }
    );
}

#[test]
fn every_core_action_maps_to_its_own_arm() {
    for (from, to) in [
        (core::SlashAction::SendText, SlashAction::SendText),
        (
            core::SlashAction::RunSkill {
                name: "n".into(),
                arguments: "a".into(),
            },
            SlashAction::RunSkill {
                name: "n".into(),
                arguments: "a".into(),
            },
        ),
        (core::SlashAction::Compact, SlashAction::Compact),
        (
            core::SlashAction::SetModel {
                model: Some("m".into()),
            },
            SlashAction::SetModel {
                model: Some("m".into()),
            },
        ),
        (
            core::SlashAction::SetEffort {
                effort: Some("e".into()),
            },
            SlashAction::SetEffort {
                effort: Some("e".into()),
            },
        ),
        (core::SlashAction::NewSession, SlashAction::NewSession),
        (core::SlashAction::Clear, SlashAction::Clear),
        (
            core::SlashAction::SideChat {
                question: "q".into(),
            },
            SlashAction::SideChat {
                question: "q".into(),
            },
        ),
        (core::SlashAction::Context, SlashAction::Context),
        (core::SlashAction::Mcp, SlashAction::Mcp),
        (core::SlashAction::Permissions, SlashAction::Permissions),
        (
            core::SlashAction::Show { text: "t".into() },
            SlashAction::Show { text: "t".into() },
        ),
    ] {
        assert_eq!(SlashAction::from(from), to);
    }
}

#[test]
fn the_menu_and_actions_read_the_configuration_skills_and_options() {
    let configuration = configuration_on("claude-sdk");
    let options = SlashOptions {
        server_clears: true,
        ..NO_OPTIONS
    };
    let native = configuration_on("claude-native");
    let commands = slash_commands(native.clone(), vec![skill("review")], options);
    let review = commands.iter().find(|command| command.is_skill).unwrap();
    assert_eq!(review.name, "review");
    assert_eq!(review.prefix, "/");
    assert_eq!(
        review.description,
        "review label \u{2014} review description"
    );
    assert!(commands.iter().any(|command| command.name == "clear"));
    assert!(
        !slash_commands(native.clone(), vec![], NO_OPTIONS)
            .iter()
            .any(|command| command.name == "clear"),
        "the option reaches the core"
    );

    let codex = skill_commands(Some("codex-native".into()), vec![skill("fix")]);
    assert_eq!(codex[0].prefix, "$");
    assert_eq!(skill_commands(None, vec![skill("fix")])[0].prefix, "/");

    assert_eq!(
        slash_action(
            "/review the diff".into(),
            false,
            configuration.clone(),
            vec![skill("review")],
            NO_OPTIONS,
        ),
        Some(SlashAction::RunSkill {
            name: "review".into(),
            arguments: "the diff".into(),
        })
    );
    assert_eq!(
        slash_action("/clear".into(), false, native, vec![], options),
        Some(SlashAction::Clear)
    );
    assert_eq!(
        slash_action(
            "/review".into(),
            true,
            configuration,
            vec![skill("review")],
            NO_OPTIONS
        ),
        None,
        "attachments make it a message"
    );
}

#[test]
fn smart_routing_needs_the_option_and_the_reports_read_their_inputs() {
    let mut configuration = configuration_on("claude-sdk");
    configuration.agent_id = Some("a1".into());
    let on = SlashOptions {
        smart_routing: true,
        ..NO_OPTIONS
    };
    assert!(offers_smart_routing(configuration.clone(), on));
    assert!(!offers_smart_routing(configuration.clone(), NO_OPTIONS));

    configuration.base_model = Some("sonnet".into());
    let report = context_report(Some(configuration), Some(1_000), Some(2_000), 7);
    assert!(report.contains("sonnet"), "{report}");
    assert!(report.contains("1,000"), "{report}");
    assert!(report.contains("2,000"), "{report}");
    assert!(report.contains('7'), "{report}");
    assert!(context_report(None, Some(u64::MAX), None, 0).contains("18,446,744,073,709,551,615"));

    assert!(mcp_report(None).contains("not loaded"));
    assert!(mcp_report(Some(vec!["docs".into()])).contains("docs"));
    assert_eq!(
        mention_preamble(None, vec!["src/lib.rs".into()]),
        "[Attached: src/lib.rs]\n\n"
    );
}

#[test]
fn skills_are_read_for_a_session_and_a_host() {
    let mut harness = connected();
    harness.http.route(
        "/v1/skills",
        reply(
            200,
            r#"{"skills":[{"name":"review","description":"D","display_name":"Review"}],"warnings":["w"]}"#,
        ),
    );
    let catalog = harness
        .call(|core| async move { core.session_skills("conv_a".into()).await })
        .unwrap();
    assert_eq!(harness.last_query("session_id").as_deref(), Some("conv_a"));
    assert_eq!(catalog.warnings, ["w"]);
    assert_eq!(
        catalog.skills,
        [Skill {
            name: "review".into(),
            description: "D".into(),
            display_name: Some("Review".into()),
        }]
    );
    let catalog = harness
        .call(|core| async move {
            core.host_skills(
                "host_a".into(),
                "claude-native".into(),
                "/work".into(),
                Some("agent_1".into()),
            )
            .await
        })
        .unwrap();
    assert_eq!(catalog.skills[0].name, "review");
    assert_eq!(catalog.warnings, ["w"]);
    assert_eq!(harness.last_query("host_id").as_deref(), Some("host_a"));
    assert_eq!(
        harness.last_query("harness").as_deref(),
        Some("claude-native")
    );
    assert_eq!(harness.last_query("path").as_deref(), Some("/work"));
    assert_eq!(harness.last_query("agent_id").as_deref(), Some("agent_1"));
}

#[test]
fn server_options_and_commands_send_the_expected_events() {
    let mut harness = connected();
    harness.http.route(
        "/v1/info",
        reply(
            200,
            r#"{"single_user":true,"session_event_types":["clear"]}"#,
        ),
    );
    assert!(
        harness
            .call(|core| async move { core.slash_options().await })
            .unwrap()
            .server_clears
    );

    harness.writable_session("conv_a");
    let sent = harness
        .call(|core| async move {
            core.run_skill(
                "conv_a".into(),
                "/review the diff".into(),
                "review".into(),
                "the diff".into(),
            )
            .await
        })
        .unwrap();
    assert!(sent.queued);
    assert_eq!(sent.item_id.as_deref(), Some("i1"));
    assert_eq!(sent.pending_id.as_deref(), Some("p1"));
    assert_eq!(sent.draft, "");
    assert_eq!(
        harness.last_request(),
        (
            "POST /v1/sessions/conv_a/events".into(),
            json!({"type": "slash_command", "data": {
                "kind": "skill", "name": "review", "arguments": "the diff"}})
        )
    );

    harness
        .call(|core| async move { core.compact("conv_a".into(), "/compact".into()).await })
        .unwrap();
    assert_eq!(
        harness.last_request().1,
        json!({"type": "compact", "data": {}})
    );
    harness
        .call(|core| async move { core.clear_context("conv_a".into()).await })
        .unwrap();
    assert_eq!(
        harness.last_request().1,
        json!({"type": "clear", "data": {}})
    );
}

#[test]
fn smart_routing_patches_the_session_and_background_titles_change_the_header() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions/conv_a",
        reply(
            200,
            r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,
                "harness":"claude-sdk","host_online":true,"cost_control_mode_override":"on"}"#,
        ),
    );
    harness.core.sessions().set_live_session("conv_a", true);
    let summary = harness
        .call(|core| async move { core.set_smart_routing("conv_a".into(), true).await })
        .unwrap();
    assert_eq!(summary.id, "conv_a");
    assert_eq!(
        harness.last_request(),
        (
            "PATCH /v1/sessions/conv_a".into(),
            json!({"cost_control_mode_override": "on"})
        )
    );

    harness.core.set_background_session_titles(false);
    harness.http.route(
        "/v1/sessions/conv_a/events",
        reply(200, r#"{"queued":true}"#),
    );
    harness.http.route(
        "/v1/sessions/conv_a/items",
        reply(200, r#"{"data":[],"has_more":false}"#),
    );
    harness
        .call(|core| async move { core.send_reply("conv_a".into(), "x".into()).await })
        .unwrap();
    let header = {
        let requests = crate::engine::lock(&harness.http.requests);
        requests
            .last()
            .unwrap()
            .headers
            .iter()
            .find(|header| header.name.eq_ignore_ascii_case(BACKGROUND_TITLES_HEADER))
            .map(|header| header.value.clone())
    };
    assert_eq!(header.as_deref(), Some("off"));
}
