//! The composer's slash commands: the built-ins a session offers, its discovered skills, and what
//! sending a `/command` does (the web composer's `buildSlashCommandMap` and submit routing).
//!
//! Native harnesses (`*-native`) run their own commands, so a typed command or skill reaches
//! them as plain text. Other harnesses run skills through the server's `slash_command` event.

use serde_json::Value;

use crate::client::json::{as_object, opt_array, opt_str, req_str};
use crate::config::session::{SessionConfiguration, canonical_harness};

/// A skill discovered on the session's host (`GET /v1/skills`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Skill {
    /// The invocation name, for example `triage-issues`.
    pub name: String,
    /// One line from the skill's frontmatter.
    pub description: String,
    /// A human-facing label, when the skill has one.
    pub display_name: Option<String>,
}

/// A session's skills, and the sources the host could not read.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SkillCatalog {
    /// User-invocable skills.
    pub skills: Vec<Skill>,
    /// Non-empty means `skills` is incomplete.
    pub warnings: Vec<String>,
}

impl SkillCatalog {
    /// Decodes a `GET /v1/skills` response.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "skills response")?;
        let skills = opt_array(object, "skills")?
            .ok_or("`skills` is missing")?
            .iter()
            .map(|skill| {
                let skill = as_object(skill, "skill")?;
                Ok(Skill {
                    name: req_str(skill, "name")?,
                    description: opt_str(skill, "description")?.unwrap_or_default(),
                    display_name: opt_str(skill, "display_name")?,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        let mut warnings: Vec<String> = Vec::new();
        for warning in opt_array(object, "warnings")?.into_iter().flatten() {
            if let Some(text) = warning.as_str()
                && !warnings.iter().any(|seen| seen == text)
            {
                warnings.push(text.to_owned());
            }
        }
        Ok(Self { skills, warnings })
    }
}

/// One entry of the `/` menu.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SlashCommand {
    /// The name without its prefix.
    pub name: String,
    /// The prefix typed before it: `/`, or `$` for Codex skills.
    pub prefix: String,
    /// One line.
    pub description: String,
    /// A skill rather than a built-in.
    pub is_skill: bool,
}

/// What sending a command does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SlashAction {
    /// Send the text as an ordinary message: the native harness runs it.
    SendText,
    /// Run a skill through the server (`slash_command` event).
    RunSkill {
        /// The skill name.
        name: String,
        /// Everything after the name.
        arguments: String,
    },
    /// Compact the context with the harness's compact control (`compact` event).
    Compact,
    /// Change the model; `None` resets to the default.
    SetModel {
        /// The model.
        model: Option<String>,
    },
    /// Change the reasoning effort; `None` resets to the model default.
    SetEffort {
        /// The effort.
        effort: Option<String>,
    },
    /// Start a blank session in the same project.
    NewSession,
    /// Show `text` to the user and send nothing (help, usage, a refusal).
    Show {
        /// The text.
        text: String,
    },
}

const COMPACT: &str = "Compact conversation context to free up space";
const EFFORT: &str = "Set reasoning effort: /effort low | medium | high | default";
const MODEL: &str = "Switch the model for this session: /model <name>";
const NEW: &str = "Start a blank session in the same project";
const BTW: &str =
    "Ask a side question \u{2014} answered in a dismissable overlay, not saved to the conversation";
const HELP: &str = "Show available slash commands";
const RESET_WORDS: [&str; 3] = ["default", "off", "reset"];

fn is_native(harness: &str) -> bool {
    harness.ends_with("-native")
}

/// The harnesses whose `/compact` is a control event rather than text for the terminal.
fn compacts_by_control(harness: &str) -> bool {
    matches!(harness, "codex-native" | "claude-sdk" | "pi-native")
}

fn offers_compact(harness: &str) -> bool {
    is_native(harness) || harness == "claude-sdk"
}

fn skill_prefix(harness: &str) -> &'static str {
    if harness == "codex-native" { "$" } else { "/" }
}

/// The `/` menu for a session: the built-ins it supports first, then its skills.
#[must_use]
pub fn slash_commands(configuration: &SessionConfiguration, skills: &[Skill]) -> Vec<SlashCommand> {
    let harness = canonical_harness(configuration.harness.as_deref());
    let builtin = |name: &str, description: &str| SlashCommand {
        name: name.to_owned(),
        prefix: "/".to_owned(),
        description: description.to_owned(),
        is_skill: false,
    };
    let mut commands = Vec::new();
    if offers_compact(&harness) {
        commands.push(builtin("compact", COMPACT));
    }
    if configuration.supports_effort() {
        commands.push(builtin("effort", EFFORT));
    }
    if configuration.supports_models() {
        commands.push(builtin("model", MODEL));
    }
    commands.push(builtin("new", NEW));
    if harness == "claude-native" {
        commands.push(builtin("btw", BTW));
    }
    commands.push(builtin("help", HELP));
    let prefix = skill_prefix(&harness);
    for skill in skills {
        commands.push(SlashCommand {
            name: skill.name.clone(),
            prefix: prefix.to_owned(),
            description: skill_description(skill),
            is_skill: true,
        });
    }
    commands
}

fn skill_description(skill: &Skill) -> String {
    match &skill.display_name {
        Some(label) if !label.is_empty() && label != &skill.name => {
            if skill.description.is_empty() {
                label.clone()
            } else {
                format!("{label} \u{2014} {}", skill.description)
            }
        }
        _ => skill.description.clone(),
    }
}

/// The command `text` invokes, split from its arguments: the longest known name that prefixes
/// the trimmed text at a word boundary. `None` for ordinary text and file paths.
#[must_use]
pub fn match_invocation<'a>(
    text: &str,
    commands: &'a [SlashCommand],
) -> Option<(&'a SlashCommand, String)> {
    let trimmed = text.trim();
    commands
        .iter()
        .filter_map(|command| {
            let rest = trimmed
                .strip_prefix(command.prefix.as_str())
                .or_else(|| trimmed.strip_prefix('/'))?
                .strip_prefix(command.name.as_str())?;
            (rest.is_empty() || rest.starts_with(char::is_whitespace))
                .then(|| (command, rest.trim().to_owned()))
        })
        .max_by_key(|(command, _)| command.name.len())
}

/// What sending `text` does in this session; `None` sends it as an ordinary message. A message
/// with attachments is never a command.
#[must_use]
pub fn slash_action(
    text: &str,
    has_attachments: bool,
    configuration: &SessionConfiguration,
    skills: &[Skill],
) -> Option<SlashAction> {
    if has_attachments {
        return None;
    }
    let commands = slash_commands(configuration, skills);
    let (command, arguments) = match_invocation(text, &commands)?;
    let harness = canonical_harness(configuration.harness.as_deref());
    if command.is_skill {
        return Some(if is_native(&harness) {
            SlashAction::SendText
        } else {
            SlashAction::RunSkill {
                name: command.name.clone(),
                arguments,
            }
        });
    }
    let no_arguments = |name: &str, action: SlashAction| {
        if arguments.is_empty() {
            action
        } else {
            SlashAction::Show {
                text: format!("/{name} does not accept arguments"),
            }
        }
    };
    Some(match command.name.as_str() {
        "compact" if compacts_by_control(&harness) => no_arguments("compact", SlashAction::Compact),
        "compact" | "btw" => SlashAction::SendText,
        "new" => no_arguments("new", SlashAction::NewSession),
        "help" => SlashAction::Show {
            text: commands
                .iter()
                .map(|command| {
                    format!(
                        "{}{} \u{2014} {}",
                        command.prefix, command.name, command.description
                    )
                })
                .collect::<Vec<_>>()
                .join("\n"),
        },
        "model" => model_action(&arguments, configuration),
        "effort" => effort_action(&arguments, configuration),
        _ => return None,
    })
}

fn model_action(arguments: &str, configuration: &SessionConfiguration) -> SlashAction {
    if arguments.is_empty() {
        let current = configuration.model_override.as_ref().map_or_else(
            || {
                configuration
                    .base_model
                    .clone()
                    .unwrap_or_else(|| "agent default".to_owned())
            },
            |model| format!("{model} (override)"),
        );
        return SlashAction::Show {
            text: format!("Model: {current}\nUsage: /model <name> | default"),
        };
    }
    let reset = RESET_WORDS.contains(&arguments.to_lowercase().as_str());
    SlashAction::SetModel {
        model: (!reset).then(|| arguments.to_owned()),
    }
}

fn effort_action(arguments: &str, configuration: &SessionConfiguration) -> SlashAction {
    let mut valid = configuration.efforts(configuration.model_override.as_deref());
    valid.push("default".to_owned());
    let level = arguments.to_lowercase();
    if !valid.contains(&level) {
        return SlashAction::Show {
            text: format!("Usage: /effort {}", valid.join(" | ")),
        };
    }
    SlashAction::SetEffort {
        effort: (level != "default").then_some(level),
    }
}

#[cfg(test)]
#[path = "slash_tests.rs"]
mod tests;
