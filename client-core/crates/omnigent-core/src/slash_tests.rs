use serde_json::json;

use super::*;

fn session(harness: &str) -> SessionConfiguration {
    SessionConfiguration {
        harness: Some(harness.to_owned()),
        ..SessionConfiguration::default()
    }
}

fn skill(name: &str) -> Skill {
    Skill {
        name: name.to_owned(),
        description: format!("{name} description"),
        display_name: None,
    }
}

const NO_OPTIONS: SlashOptions = SlashOptions {
    server_clears: false,
    smart_routing: false,
    routes_native_panes: false,
};

fn act(
    text: &str,
    has_attachments: bool,
    configuration: &SessionConfiguration,
    skills: &[Skill],
) -> Option<SlashAction> {
    slash_action(text, has_attachments, configuration, skills, &NO_OPTIONS)
}

fn codex() -> SessionConfiguration {
    SessionConfiguration {
        wrapper: Some("codex-native-ui".to_owned()),
        ..session("codex-native")
    }
}

fn names(commands: &[SlashCommand]) -> Vec<String> {
    commands
        .iter()
        .map(|command| format!("{}{}", command.prefix, command.name))
        .collect()
}

#[test]
fn catalog_decodes_skills_and_deduplicates_warnings() {
    let catalog = SkillCatalog::from_value(&json!({
        "skills": [
            {"name": "triage", "description": "Triage issues", "display_name": "Triage"},
            {"name": "bare"}
        ],
        "warnings": ["~/.claude unreadable", "~/.claude unreadable", 3]
    }))
    .expect("decodes");
    assert_eq!(catalog.skills.len(), 2);
    assert_eq!(catalog.skills[0].display_name.as_deref(), Some("Triage"));
    assert_eq!(catalog.skills[1].description, "");
    assert_eq!(catalog.warnings, vec!["~/.claude unreadable".to_owned()]);
    assert!(SkillCatalog::from_value(&json!({"warnings": []})).is_err());
    assert!(SkillCatalog::from_value(&json!({"skills": [{"description": "no name"}]})).is_err());
}

#[test]
fn builtins_follow_the_harness_then_skills() {
    let sdk = slash_commands(&session("openai-agents"), &[skill("review")], &NO_OPTIONS);
    assert_eq!(
        names(&sdk),
        ["/context", "/mcp", "/new", "/side", "/help", "/review"]
    );
    let claude = slash_commands(&session("native-claude"), &[skill("review")], &NO_OPTIONS);
    assert_eq!(
        names(&claude),
        [
            "/compact", "/context", "/model", "/mcp", "/new", "/btw", "/side", "/help", "/review"
        ]
    );
    assert_eq!(
        names(&slash_commands(&codex(), &[skill("review")], &NO_OPTIONS)),
        [
            "/compact",
            "/context",
            "/effort",
            "/model",
            "/mcp",
            "/permissions",
            "/new",
            "/side",
            "/help",
            "$review"
        ]
    );
    assert_eq!(
        names(&slash_commands(&session("claude-sdk"), &[], &NO_OPTIONS)),
        ["/compact", "/context", "/mcp", "/new", "/side", "/help"]
    );
    assert_eq!(
        names(&slash_commands(
            &SessionConfiguration::default(),
            &[],
            &NO_OPTIONS
        )),
        ["/context", "/mcp", "/new", "/help"]
    );
}

#[test]
fn display_names_lead_the_description() {
    let named = Skill {
        display_name: Some("Review PR".to_owned()),
        ..skill("review-pr")
    };
    let commands = slash_commands(&session("openai-agents"), &[named], &NO_OPTIONS);
    assert_eq!(
        commands.last().map(|command| command.description.as_str()),
        Some("Review PR \u{2014} review-pr description")
    );
}

#[test]
fn invocations_match_whole_names_and_keep_arguments() {
    let commands = slash_commands(
        &session("openai-agents"),
        &[skill("review"), skill("review-pr")],
        &NO_OPTIONS,
    );
    let (command, arguments) =
        match_invocation("  /review-pr https://github.com/o/r/pull/1 ", &commands).expect("match");
    assert_eq!(command.name, "review-pr");
    assert_eq!(arguments, "https://github.com/o/r/pull/1");
    assert!(match_invocation("/reviewer", &commands).is_none());
    assert!(match_invocation("/etc/hosts", &commands).is_none());
    assert!(match_invocation("please /review", &commands).is_none());
}

#[test]
fn skills_run_on_the_server_except_on_native_harnesses() {
    let skills = [skill("review")];
    assert_eq!(
        act(
            "/review the diff",
            false,
            &session("openai-agents"),
            &skills
        ),
        Some(SlashAction::RunSkill {
            name: "review".to_owned(),
            arguments: "the diff".to_owned()
        })
    );
    assert_eq!(
        act("/review", false, &session("claude-native"), &skills),
        Some(SlashAction::SendText)
    );
    assert_eq!(
        act("$review", false, &session("codex-native"), &skills),
        Some(SlashAction::SendText)
    );
    assert_eq!(
        act("/review", true, &session("openai-agents"), &skills),
        None
    );
    assert_eq!(
        act("hello", false, &session("openai-agents"), &skills),
        None
    );
    assert_eq!(
        act("/unknown", false, &session("openai-agents"), &skills),
        None
    );
}

#[test]
fn builtins_map_to_their_actions() {
    let claude = session("claude-native");
    assert_eq!(
        act("/compact", false, &claude, &[]),
        Some(SlashAction::SendText)
    );
    assert_eq!(
        act("/compact", false, &session("pi-native"), &[]),
        Some(SlashAction::Compact)
    );
    assert_eq!(
        act("/compact now", false, &session("claude-sdk"), &[]),
        Some(SlashAction::Show {
            text: "/compact does not accept arguments".to_owned()
        })
    );
    assert_eq!(
        act("/new", false, &claude, &[]),
        Some(SlashAction::NewSession)
    );
    assert_eq!(
        act("/model opus", false, &claude, &[]),
        Some(SlashAction::SetModel {
            model: Some("opus".to_owned())
        })
    );
    assert_eq!(
        act("/model Default", false, &claude, &[]),
        Some(SlashAction::SetModel { model: None })
    );
    assert!(matches!(
        act("/model", false, &claude, &[]),
        Some(SlashAction::Show { text }) if text.starts_with("Model: agent default")
    ));
    let Some(SlashAction::Show { text }) = act("/help", false, &claude, &[skill("x")]) else {
        panic!("help shows text");
    };
    assert!(text.contains("/compact \u{2014} Compact"));
    assert!(text.ends_with("/x \u{2014} x description"));
}

#[test]
fn clear_needs_the_server_control_and_a_native_terminal() {
    let clears = SlashOptions {
        server_clears: true,
        ..NO_OPTIONS
    };
    let claude = session("claude-native");
    assert!(!names(&slash_commands(&claude, &[], &NO_OPTIONS)).contains(&"/clear".to_owned()));
    assert_eq!(act("/clear", false, &claude, &[]), None);
    assert_eq!(
        slash_action("/clear", false, &claude, &[], &clears),
        Some(SlashAction::Clear)
    );
    assert_eq!(
        slash_action("/clear now", false, &codex(), &[], &clears),
        Some(SlashAction::Show {
            text: "/clear does not accept arguments".to_owned()
        })
    );
    assert_eq!(
        slash_action("/clear", false, &session("claude-sdk"), &[], &clears),
        None
    );
}

#[test]
fn side_forks_on_the_server_except_for_codex() {
    assert_eq!(
        act(
            "/side why is it slow?",
            false,
            &session("claude-native"),
            &[]
        ),
        Some(SlashAction::SideChat {
            question: "why is it slow?".to_owned()
        })
    );
    assert_eq!(
        act("/side", false, &session("openai-agents"), &[]),
        Some(SlashAction::SideChat {
            question: String::new()
        })
    );
    assert_eq!(
        act("/side why?", false, &codex(), &[]),
        Some(SlashAction::SendText)
    );
}

#[test]
fn context_mcp_and_permissions_act_locally() {
    let claude = session("claude-native");
    assert_eq!(
        act("/context", false, &claude, &[]),
        Some(SlashAction::Context)
    );
    assert_eq!(act("/mcp", false, &claude, &[]), Some(SlashAction::Mcp));
    assert_eq!(
        act("/mcp list", false, &claude, &[]),
        Some(SlashAction::Show {
            text: "Usage: /mcp".to_owned()
        })
    );
    assert_eq!(
        act("/permissions", false, &codex(), &[]),
        Some(SlashAction::Permissions)
    );
    assert_eq!(
        act("/permissions full", false, &codex(), &[]),
        Some(SlashAction::Show {
            text: "/permissions does not accept arguments".to_owned()
        })
    );
    // Claude's own /permissions edits tool rules in its terminal.
    assert_eq!(act("/permissions", false, &claude, &[]), None);
}

#[test]
fn context_report_shows_usage_against_the_window() {
    let configuration = SessionConfiguration {
        base_model: Some("gpt-5".to_owned()),
        ..session("codex-native")
    };
    let report = context_report(
        Some(&configuration),
        ContextUsage {
            tokens_used: Some(50_000),
            context_window: Some(200_000),
            items: 12,
        },
    );
    assert_eq!(
        report,
        "Model: gpt-5\n50,000 / 200,000 tokens (25.0%)\n\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\
         \u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\
         \u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\nItems in context: 12"
    );
    let overridden = SessionConfiguration {
        model_override: Some("o3".to_owned()),
        ..configuration
    };
    let unknown_window = context_report(
        Some(&overridden),
        ContextUsage {
            tokens_used: Some(1_234_567),
            context_window: Some(0),
            items: 0,
        },
    );
    assert_eq!(
        unknown_window,
        "Model: o3 (override)\n1,234,567 tokens\n(Context window size unknown)\nItems in context: 0"
    );
    assert_eq!(
        context_report(None, ContextUsage::default()),
        "No usage data yet \u{2014} send a message first.\nItems in context: 0"
    );
}

#[test]
fn mcp_report_lists_the_agents_servers() {
    assert_eq!(
        mcp_report(Some(&["github".to_owned(), "jira".to_owned()])),
        "MCP servers enabled for this session:\n\u{2022} github\n\u{2022} jira"
    );
    assert_eq!(
        mcp_report(Some(&[])),
        "No MCP servers are enabled for this session."
    );
    assert!(mcp_report(None).contains("not loaded yet"));
}

#[test]
fn effort_accepts_the_models_levels_and_default() {
    let codex = codex();
    assert_eq!(
        act("/effort default", false, &codex, &[]),
        Some(SlashAction::SetEffort { effort: None })
    );
    assert!(matches!(
        act("/effort extreme", false, &codex, &[]),
        Some(SlashAction::Show { text }) if text.starts_with("Usage: /effort")
    ));
}

#[test]
fn skill_commands_use_the_harness_prefix_and_no_builtins() {
    let skills = [skill("triage")];
    assert_eq!(
        names(&skill_commands(Some("native-codex"), &skills)),
        ["$triage"]
    );
    let claude = skill_commands(Some("claude-native"), &skills);
    assert_eq!(names(&claude), ["/triage"]);
    assert!(claude[0].is_skill);
    assert_eq!(names(&skill_commands(None, &skills)), ["/triage"]);
}

#[test]
fn info_reports_smart_routing_and_its_routers() {
    let info = |body: Value| SlashOptions::from_info(&body).expect("decodes");
    let off = info(json!({"smart_routing_enabled": false}));
    assert!(!off.smart_routing && !off.routes_native_panes);
    let older = info(json!({"smart_routing_enabled": true}));
    assert!(older.smart_routing && older.routes_native_panes);
    let judge_only = info(json!({
        "smart_routing_enabled": true,
        "smart_routing_sources": {"external": false, "oss": true}
    }));
    assert!(judge_only.routes_native_panes);
    let none = info(json!({
        "smart_routing_enabled": true,
        "smart_routing_sources": {"external": false, "oss": false}
    }));
    assert!(!none.routes_native_panes);
}

#[test]
fn smart_routing_needs_the_server_flag_and_a_top_level_agent_session() {
    let routes = SlashOptions {
        smart_routing: true,
        routes_native_panes: true,
        ..NO_OPTIONS
    };
    let agent = |harness: &str| SessionConfiguration {
        agent_id: Some("agent_1".to_owned()),
        ..session(harness)
    };
    assert!(offers_smart_routing(&agent("openai-agents"), &routes));
    assert!(offers_smart_routing(&agent("native-codex"), &routes));
    assert!(!offers_smart_routing(&agent("openai-agents"), &NO_OPTIONS));
    assert!(!offers_smart_routing(&session("openai-agents"), &routes));
    let child = SessionConfiguration {
        parent_id: Some("parent".to_owned()),
        ..agent("openai-agents")
    };
    assert!(!offers_smart_routing(&child, &routes));
    assert!(!offers_smart_routing(&agent("pi-native"), &routes));
    let no_router = SlashOptions {
        routes_native_panes: false,
        ..routes
    };
    assert!(!offers_smart_routing(&agent("claude-native"), &no_router));
    assert!(offers_smart_routing(&agent("openai-agents"), &no_router));
}

#[test]
fn context_report_near_the_integer_limit_does_not_overflow() {
    let full = context_report(
        None,
        ContextUsage {
            tokens_used: Some(u64::MAX),
            context_window: Some(u64::MAX),
            items: u64::MAX,
        },
    );
    assert!(full.contains("(100.0%)"), "{full}");
    assert_eq!(full.matches('\u{2588}').count(), 20);
    assert_eq!(full.matches('\u{2591}').count(), 0);
    // More tokens than the window still shows a full bar, never a negative remainder.
    let over = context_report(
        None,
        ContextUsage {
            tokens_used: Some(u64::MAX),
            context_window: Some(1),
            items: 0,
        },
    );
    assert!(over.contains("(100.0%)"), "{over}");
    let half = context_report(
        None,
        ContextUsage {
            tokens_used: Some(u64::MAX / 2),
            context_window: Some(u64::MAX),
            items: 0,
        },
    );
    assert!(half.contains("(50.0%)"), "{half}");
    assert_eq!(half.matches('\u{2588}').count(), 10);
}
