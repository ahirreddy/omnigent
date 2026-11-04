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
    let sdk = slash_commands(&session("openai-agents"), &[skill("review")]);
    assert_eq!(names(&sdk), ["/new", "/help", "/review"]);
    let claude = slash_commands(&session("native-claude"), &[skill("review")]);
    assert_eq!(
        names(&claude),
        ["/compact", "/model", "/new", "/btw", "/help", "/review"]
    );
    let codex = SessionConfiguration {
        wrapper: Some("codex-native-ui".to_owned()),
        ..session("codex-native")
    };
    assert_eq!(
        names(&slash_commands(&codex, &[skill("review")])),
        ["/compact", "/effort", "/model", "/new", "/help", "$review"]
    );
    assert_eq!(
        names(&slash_commands(&session("claude-sdk"), &[])),
        ["/compact", "/new", "/help"]
    );
}

#[test]
fn display_names_lead_the_description() {
    let named = Skill {
        display_name: Some("Review PR".to_owned()),
        ..skill("review-pr")
    };
    let commands = slash_commands(&session("openai-agents"), &[named]);
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
        slash_action(
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
        slash_action("/review", false, &session("claude-native"), &skills),
        Some(SlashAction::SendText)
    );
    assert_eq!(
        slash_action("$review", false, &session("codex-native"), &skills),
        Some(SlashAction::SendText)
    );
    assert_eq!(
        slash_action("/review", true, &session("openai-agents"), &skills),
        None
    );
    assert_eq!(
        slash_action("hello", false, &session("openai-agents"), &skills),
        None
    );
    assert_eq!(
        slash_action("/unknown", false, &session("openai-agents"), &skills),
        None
    );
}

#[test]
fn builtins_map_to_their_actions() {
    let claude = session("claude-native");
    assert_eq!(
        slash_action("/compact", false, &claude, &[]),
        Some(SlashAction::SendText)
    );
    assert_eq!(
        slash_action("/compact", false, &session("pi-native"), &[]),
        Some(SlashAction::Compact)
    );
    assert_eq!(
        slash_action("/compact now", false, &session("claude-sdk"), &[]),
        Some(SlashAction::Show {
            text: "/compact does not accept arguments".to_owned()
        })
    );
    assert_eq!(
        slash_action("/new", false, &claude, &[]),
        Some(SlashAction::NewSession)
    );
    assert_eq!(
        slash_action("/model opus", false, &claude, &[]),
        Some(SlashAction::SetModel {
            model: Some("opus".to_owned())
        })
    );
    assert_eq!(
        slash_action("/model Default", false, &claude, &[]),
        Some(SlashAction::SetModel { model: None })
    );
    assert!(matches!(
        slash_action("/model", false, &claude, &[]),
        Some(SlashAction::Show { text }) if text.starts_with("Model: agent default")
    ));
    let Some(SlashAction::Show { text }) = slash_action("/help", false, &claude, &[skill("x")])
    else {
        panic!("help shows text");
    };
    assert!(text.contains("/compact \u{2014} Compact"));
    assert!(text.ends_with("/x \u{2014} x description"));
}

#[test]
fn effort_accepts_the_models_levels_and_default() {
    let codex = SessionConfiguration {
        wrapper: Some("codex-native-ui".to_owned()),
        ..session("codex-native")
    };
    assert_eq!(
        slash_action("/effort default", false, &codex, &[]),
        Some(SlashAction::SetEffort { effort: None })
    );
    assert!(matches!(
        slash_action("/effort extreme", false, &codex, &[]),
        Some(SlashAction::Show { text }) if text.starts_with("Usage: /effort")
    ));
}
