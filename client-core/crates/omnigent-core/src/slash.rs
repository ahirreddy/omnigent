//! The composer's slash commands: the built-ins a session offers, its discovered skills, and what
//! sending a `/command` does (the web composer's `buildSlashCommandMap` and submit routing).
//!
//! Native harnesses (`*-native`) run their own commands, so a typed command or skill reaches
//! them as plain text. Other harnesses run skills through the server's `slash_command` event.
//! `/context` and `/mcp` answer locally from what the client already knows.

use serde_json::Value;

use crate::client::json::{as_object, opt_array, opt_bool, opt_object, opt_str, req_str};
use crate::config::approval::approval_mode_menu;
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

/// What the server offers beyond the session's configuration.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent server capability flags, mirrored one to one from /v1/info"
)]
pub struct SlashOptions {
    /// The server takes the `clear` control (`/v1/info.session_event_types` lists `clear`).
    pub server_clears: bool,
    /// `smart_routing_enabled`: sessions may turn Smart Routing (cost routing) on.
    pub smart_routing: bool,
    /// A router can answer for a native Claude Code or Codex pane (`smart_routing_sources`
    /// reports the external or the built-in router; older servers imply both).
    pub routes_native_panes: bool,
}

impl SlashOptions {
    /// Decodes the command fields of a `/v1/info` body; missing fields mean unsupported.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_info(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "/v1/info")?;
        let server_clears = opt_array(object, "session_event_types")?
            .is_some_and(|kinds| kinds.iter().any(|kind| kind.as_str() == Some("clear")));
        let smart_routing = opt_bool(object, "smart_routing_enabled")?.unwrap_or(false);
        let routes_native_panes =
            opt_object(object, "smart_routing_sources")?.map_or(smart_routing, |sources| {
                ["external", "oss"]
                    .iter()
                    .any(|source| sources.get(*source).and_then(Value::as_bool) == Some(true))
            });
        Ok(Self {
            server_clears,
            smart_routing,
            routes_native_panes,
        })
    }
}

/// The native harnesses Smart Routing picks between.
pub(crate) const ROUTED_NATIVE_HARNESSES: [&str; 2] = ["claude-native", "codex-native"];

/// Whether the model picker offers Smart Routing for the session (the web's
/// `isCostRoutingEligible`).
///
/// The server routes, the session is a top-level agent session, and a native pane is one Smart
/// Routing can drive with a router that answers for it.
#[must_use]
pub fn offers_smart_routing(configuration: &SessionConfiguration, options: &SlashOptions) -> bool {
    if !options.smart_routing || configuration.agent_id.is_none() {
        return false;
    }
    if configuration.parent_id.is_some() {
        return false;
    }
    let harness = canonical_harness(configuration.harness.as_deref());
    if !harness.ends_with("-native") {
        return true;
    }
    ROUTED_NATIVE_HARNESSES.contains(&harness.as_str()) && options.routes_native_panes
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
    /// Run the harness's own `/clear`: the terminal moves to a fresh session the view follows.
    Clear,
    /// Fork a side chat and open it with `question` as its draft.
    SideChat {
        /// Everything after `/side`; may be empty.
        question: String,
    },
    /// Show the context window usage ([`context_report`]).
    Context,
    /// Show the session's MCP servers ([`mcp_report`]).
    Mcp,
    /// Open the approval-mode picker.
    Permissions,
    /// Show `text` to the user and send nothing (help, usage, a refusal).
    Show {
        /// The text.
        text: String,
    },
}

const COMPACT: &str = "Compact conversation context to free up space";
const CLEAR: &str = "Clear the context and continue in a new chat on the same machine";
const CONTEXT: &str = "Show context window usage for this session";
const MCP: &str = "Show MCP servers enabled for this session";
const PERMISSIONS: &str = "Change the approval mode for this session";
const SIDE: &str = "Start a side chat: an ephemeral fork opened as its own sub-agent chat, kept out of this conversation";
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

/// The harnesses whose own `/clear` the server can run in the session terminal.
fn offers_clear(harness: &str) -> bool {
    matches!(harness, "claude-native" | "codex-native")
}

/// Codex forks its side chat in-process from the typed `/side`; others fork on the server.
fn forks_side_chat_natively(harness: &str) -> bool {
    harness == "codex-native"
}

/// Codex's approval mode has a live switch here; Claude's `/permissions` edits tool rules in
/// its terminal instead.
fn offers_permissions(harness: &str, configuration: &SessionConfiguration) -> bool {
    harness == "codex-native" && approval_mode_menu(configuration).is_some()
}

fn skill_prefix(harness: &str) -> &'static str {
    if harness == "codex-native" { "$" } else { "/" }
}

/// The `/` menu for a session: the built-ins it supports first, then its skills.
#[must_use]
pub fn slash_commands(
    configuration: &SessionConfiguration,
    skills: &[Skill],
    options: &SlashOptions,
) -> Vec<SlashCommand> {
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
    if options.server_clears && offers_clear(&harness) {
        commands.push(builtin("clear", CLEAR));
    }
    commands.push(builtin("context", CONTEXT));
    if configuration.supports_effort() {
        commands.push(builtin("effort", EFFORT));
    }
    if configuration.supports_models() {
        commands.push(builtin("model", MODEL));
    }
    commands.push(builtin("mcp", MCP));
    if offers_permissions(&harness, configuration) {
        commands.push(builtin("permissions", PERMISSIONS));
    }
    commands.push(builtin("new", NEW));
    if harness == "claude-native" {
        commands.push(builtin("btw", BTW));
    }
    if !harness.is_empty() {
        commands.push(builtin("side", SIDE));
    }
    commands.push(builtin("help", HELP));
    commands.extend(skill_commands(Some(&harness), skills));
    commands
}

/// `skills` as `/` menu rows for `harness` (`$` for Codex), as the new-session composer offers
/// them before a session exists; built-ins need a live session.
#[must_use]
pub fn skill_commands(harness: Option<&str>, skills: &[Skill]) -> Vec<SlashCommand> {
    let prefix = skill_prefix(&canonical_harness(harness));
    skills
        .iter()
        .map(|skill| SlashCommand {
            name: skill.name.clone(),
            prefix: prefix.to_owned(),
            description: skill_description(skill),
            is_skill: true,
        })
        .collect()
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
    options: &SlashOptions,
) -> Option<SlashAction> {
    if has_attachments {
        return None;
    }
    let commands = slash_commands(configuration, skills, options);
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
    builtin_action(&command.name, arguments, &harness, &commands, configuration)
}

/// What the built-in command `name` does; `None` for a name that isn't one.
fn builtin_action(
    name: &str,
    arguments: String,
    harness: &str,
    commands: &[SlashCommand],
    configuration: &SessionConfiguration,
) -> Option<SlashAction> {
    let no_arguments = |name: &str, action: SlashAction| {
        if arguments.is_empty() {
            action
        } else {
            SlashAction::Show {
                text: format!("/{name} does not accept arguments"),
            }
        }
    };
    Some(match name {
        "compact" if compacts_by_control(harness) => no_arguments("compact", SlashAction::Compact),
        "compact" | "btw" => SlashAction::SendText,
        "new" => no_arguments("new", SlashAction::NewSession),
        "clear" => no_arguments("clear", SlashAction::Clear),
        "permissions" => no_arguments("permissions", SlashAction::Permissions),
        "context" => SlashAction::Context,
        "mcp" if arguments.is_empty() => SlashAction::Mcp,
        "mcp" => SlashAction::Show {
            text: "Usage: /mcp".to_owned(),
        },
        "side" if forks_side_chat_natively(harness) => SlashAction::SendText,
        "side" => SlashAction::SideChat {
            question: arguments,
        },
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

/// How full the context window is, as `/context` shows it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ContextUsage {
    /// Tokens in context, once a turn reported them.
    pub tokens_used: Option<u64>,
    /// The model's context window, when known.
    pub context_window: Option<u64>,
    /// Transcript items in the conversation.
    pub items: u64,
}

const CONTEXT_BAR_WIDTH: u64 = 20;

/// `used / window` of `scale`, rounded, for `used <= window`. Wide so counts near the integer
/// limit cannot overflow.
fn rounded_share(used: u64, window: u64, scale: u64) -> u64 {
    let window = u128::from(window);
    let share = (u128::from(used) * u128::from(scale) + window / 2) / window;
    u64::try_from(share).unwrap_or(scale)
}

/// The `/context` text: the model, the tokens used against the window with a bar, and the
/// item count (the web composer's `/context`).
#[must_use]
pub fn context_report(configuration: Option<&SessionConfiguration>, usage: ContextUsage) -> String {
    let mut lines = Vec::new();
    if let Some(configuration) = configuration {
        if let Some(model) = &configuration.model_override {
            lines.push(format!("Model: {model} (override)"));
        } else if let Some(model) = &configuration.base_model {
            lines.push(format!("Model: {model}"));
        }
    }
    match (usage.tokens_used, usage.context_window) {
        (Some(tokens), Some(window)) if window > 0 => {
            let used = tokens.min(window);
            let filled = rounded_share(used, window, CONTEXT_BAR_WIDTH);
            // Tenths of a percent, rounded.
            let tenths = rounded_share(used, window, 1000);
            lines.push(format!(
                "{} / {} tokens ({}.{}%)",
                grouped(tokens),
                grouped(window),
                tenths / 10,
                tenths % 10
            ));
            lines.push(format!(
                "{}{}",
                "\u{2588}".repeat(usize::try_from(filled).unwrap_or(0)),
                "\u{2591}".repeat(usize::try_from(CONTEXT_BAR_WIDTH - filled).unwrap_or(0))
            ));
        }
        (Some(tokens), _) => {
            lines.push(format!("{} tokens", grouped(tokens)));
            lines.push("(Context window size unknown)".to_owned());
        }
        (None, _) => lines.push("No usage data yet \u{2014} send a message first.".to_owned()),
    }
    lines.push(format!("Items in context: {}", usage.items));
    lines.join("\n")
}

/// The `/mcp` text for the agent's MCP servers; `None` while they are unknown.
#[must_use]
pub fn mcp_report(servers: Option<&[String]>) -> String {
    match servers {
        None => "This session's MCP servers have not loaded yet. Try again in a moment.".to_owned(),
        Some([]) => "No MCP servers are enabled for this session.".to_owned(),
        Some(servers) => {
            let mut lines = vec!["MCP servers enabled for this session:".to_owned()];
            lines.extend(servers.iter().map(|name| format!("\u{2022} {name}")));
            lines.join("\n")
        }
    }
}

/// `1234567` as `1,234,567`.
fn grouped(value: u64) -> String {
    let digits = value.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

#[cfg(test)]
#[path = "slash_tests.rs"]
mod tests;
