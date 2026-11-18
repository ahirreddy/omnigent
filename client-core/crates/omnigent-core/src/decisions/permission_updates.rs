//! Permission updates a request offers to apply with an approval: Claude's
//! `permission_suggestions` (rules, a mode switch, directories), and the modes a plan approval
//! may switch to (`plan_modes`).
//!
//! The card offers the suggestions as one "always allow" choice, as Claude's own prompt does. The
//! server applies the list it holds, never one the app sends, so the app only needs to describe
//! it exactly: a list with any entry it cannot describe is not offered at all.

use serde_json::{Map, Value};

/// A permission mode Claude can run in (`PermissionMode` in the Agent SDK).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum PermissionMode {
    /// `default`: asks before edits and commands.
    Default,
    /// `acceptEdits`: edits run without asking.
    AcceptEdits,
    /// `plan`: plans without changing anything.
    Plan,
    /// `bypassPermissions`: nothing asks.
    BypassPermissions,
    /// `dontAsk`: denies what would ask.
    DontAsk,
    /// `auto`: a classifier decides.
    Auto,
}

impl PermissionMode {
    /// The wire value.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::AcceptEdits => "acceptEdits",
            Self::Plan => "plan",
            Self::BypassPermissions => "bypassPermissions",
            Self::DontAsk => "dontAsk",
            Self::Auto => "auto",
        }
    }

    /// The mode named by `value`, if it is one.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "default" => Self::Default,
            "acceptEdits" => Self::AcceptEdits,
            "plan" => Self::Plan,
            "bypassPermissions" => Self::BypassPermissions,
            "dontAsk" => Self::DontAsk,
            "auto" => Self::Auto,
            _ => return None,
        })
    }

    /// How a label names the mode.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Default => "default mode",
            Self::AcceptEdits => "accept-edits mode",
            Self::Plan => "plan mode",
            Self::BypassPermissions => "bypass-permissions mode",
            Self::DontAsk => "don't-ask mode",
            Self::Auto => "auto mode",
        }
    }
}

/// Where an update applies and is kept.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UpdateDestination {
    /// `session`: until the session ends.
    Session,
    /// `localSettings`: this project, for this user.
    LocalSettings,
    /// `projectSettings`: this project, shared with everyone who uses it.
    ProjectSettings,
    /// `userSettings`: every project of this user.
    UserSettings,
    /// `cliArg`: this launch of Claude.
    CliArg,
}

impl UpdateDestination {
    fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "session" => Self::Session,
            "localSettings" => Self::LocalSettings,
            "projectSettings" => Self::ProjectSettings,
            "userSettings" => Self::UserSettings,
            "cliArg" => Self::CliArg,
            _ => return None,
        })
    }

    /// Whether the update outlives this session.
    #[must_use]
    pub const fn persists(self) -> bool {
        matches!(
            self,
            Self::LocalSettings | Self::ProjectSettings | Self::UserSettings
        )
    }

    const fn label(self) -> &'static str {
        match self {
            Self::Session => "for this session",
            Self::LocalSettings => "in this project",
            Self::ProjectSettings => "in this project, for everyone",
            Self::UserSettings => "in all your projects",
            Self::CliArg => "until Claude restarts",
        }
    }
}

/// What a rule does to a matching call.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RuleBehavior {
    /// Runs without asking.
    Allow,
    /// Refused.
    Deny,
    /// Always asks.
    Ask,
}

impl RuleBehavior {
    fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "allow" => Self::Allow,
            "deny" => Self::Deny,
            "ask" => Self::Ask,
            _ => return None,
        })
    }

    const fn noun(self) -> &'static str {
        match self {
            Self::Allow => "allow",
            Self::Deny => "deny",
            Self::Ask => "ask",
        }
    }
}

/// One rule: a tool, and what of it the rule covers (`None`: every use).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PermissionRule {
    /// The tool, as Claude names it (`Bash`, `mcp__server__tool`).
    pub tool_name: String,
    /// What the rule matches within the tool (`npm test:*`, `domain:example.com`).
    pub rule_content: Option<String>,
}

impl PermissionRule {
    /// `Tool(content)`, or `Tool` for a rule covering every use.
    #[must_use]
    pub fn label(&self) -> String {
        self.rule_content.as_ref().map_or_else(
            || self.tool_name.clone(),
            |content| format!("{}({content})", self.tool_name),
        )
    }
}

/// What one update changes.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum UpdateChange {
    /// `addRules`.
    AddRules {
        /// The rules.
        rules: Vec<PermissionRule>,
        /// What they do.
        behavior: RuleBehavior,
    },
    /// `replaceRules`: the destination's rules of this behavior become these.
    ReplaceRules {
        /// The rules.
        rules: Vec<PermissionRule>,
        /// Which rules are replaced.
        behavior: RuleBehavior,
    },
    /// `removeRules`.
    RemoveRules {
        /// The rules.
        rules: Vec<PermissionRule>,
        /// Which rules they are.
        behavior: RuleBehavior,
    },
    /// `setMode`.
    SetMode {
        /// The new mode.
        mode: PermissionMode,
    },
    /// `addDirectories`: the directories become readable and writable.
    AddDirectories {
        /// The directories, as Claude spelled them.
        directories: Vec<String>,
    },
    /// `removeDirectories`.
    RemoveDirectories {
        /// The directories.
        directories: Vec<String>,
    },
}

/// One update Claude offers (`PermissionUpdate` in the Agent SDK).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PermissionUpdate {
    /// What it changes.
    pub change: UpdateChange,
    /// Where it applies.
    pub destination: UpdateDestination,
}

impl PermissionUpdate {
    /// What the update does, in one sentence: "Allow Bash(npm test:*) in this project".
    #[must_use]
    pub fn label(&self) -> String {
        let place = self.destination.label();
        match &self.change {
            UpdateChange::AddRules { rules, behavior } => {
                let verb = match behavior {
                    RuleBehavior::Allow => "Allow",
                    RuleBehavior::Deny => "Deny",
                    RuleBehavior::Ask => "Always ask before",
                };
                format!("{verb} {} {place}", rule_list(rules))
            }
            UpdateChange::ReplaceRules { rules, behavior } => format!(
                "Replace the {} rules with {} {place}",
                behavior.noun(),
                rule_list(rules)
            ),
            UpdateChange::RemoveRules { rules, behavior } => format!(
                "Remove the {} rules for {} {place}",
                behavior.noun(),
                rule_list(rules)
            ),
            UpdateChange::SetMode { mode } => format!("Switch to {} {place}", mode.label()),
            UpdateChange::AddDirectories { directories } => {
                format!("Allow access to {} {place}", directories.join(", "))
            }
            UpdateChange::RemoveDirectories { directories } => {
                format!("Remove access to {} {place}", directories.join(", "))
            }
        }
    }

    fn parse(value: &Value) -> Option<Self> {
        let update = value.as_object()?;
        let destination = UpdateDestination::parse(update.get("destination")?.as_str()?)?;
        let behavior = || RuleBehavior::parse(update.get("behavior")?.as_str()?);
        let change = match update.get("type")?.as_str()? {
            "addRules" => UpdateChange::AddRules {
                rules: rules(update)?,
                behavior: behavior()?,
            },
            "replaceRules" => UpdateChange::ReplaceRules {
                rules: rules(update)?,
                behavior: behavior()?,
            },
            "removeRules" => UpdateChange::RemoveRules {
                rules: rules(update)?,
                behavior: behavior()?,
            },
            "setMode" => UpdateChange::SetMode {
                mode: PermissionMode::parse(update.get("mode")?.as_str()?)?,
            },
            "addDirectories" => UpdateChange::AddDirectories {
                directories: directories(update)?,
            },
            "removeDirectories" => UpdateChange::RemoveDirectories {
                directories: directories(update)?,
            },
            _ => return None,
        };
        Some(Self {
            change,
            destination,
        })
    }
}

fn rule_list(rules: &[PermissionRule]) -> String {
    rules
        .iter()
        .map(PermissionRule::label)
        .collect::<Vec<_>>()
        .join(", ")
}

/// A non-empty list of rules, each with a tool name; `None` for anything else.
fn rules(update: &Map<String, Value>) -> Option<Vec<PermissionRule>> {
    let rules = update
        .get("rules")?
        .as_array()
        .filter(|rules| !rules.is_empty())?;
    rules
        .iter()
        .map(|rule| {
            let rule = rule.as_object()?;
            let tool_name = rule
                .get("toolName")?
                .as_str()
                .filter(|name| !name.is_empty())?;
            // Empty content, like none, covers every use of the tool.
            let rule_content = match rule.get("ruleContent") {
                None => None,
                Some(Value::String(content)) => (!content.is_empty()).then(|| content.clone()),
                Some(_) => return None,
            };
            Some(PermissionRule {
                tool_name: tool_name.to_owned(),
                rule_content,
            })
        })
        .collect()
}

/// A non-empty list of non-blank directories; `None` for anything else.
fn directories(update: &Map<String, Value>) -> Option<Vec<String>> {
    let directories = update
        .get("directories")?
        .as_array()
        .filter(|directories| !directories.is_empty())?;
    directories
        .iter()
        .map(|directory| {
            directory
                .as_str()
                .filter(|directory| !directory.trim().is_empty())
                .map(str::to_owned)
        })
        .collect()
}

/// `permission_suggestions`: every entry, or none when any entry is not one the card can
/// describe exactly.
pub(super) fn permission_updates(value: Option<&Value>) -> Vec<PermissionUpdate> {
    value
        .and_then(Value::as_array)
        .and_then(|updates| updates.iter().map(PermissionUpdate::parse).collect())
        .unwrap_or_default()
}

/// `plan_modes`: the modes a plan approval may switch to, in order, without repeats. Entries that
/// name no mode are left out; each is a choice of its own.
pub(super) fn plan_modes(value: Option<&Value>) -> Vec<PermissionMode> {
    let mut modes: Vec<PermissionMode> = Vec::new();
    for mode in value
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|mode| PermissionMode::parse(mode.as_str()?))
    {
        if !modes.contains(&mode) {
            modes.push(mode);
        }
    }
    modes
}
