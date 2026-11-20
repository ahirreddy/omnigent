//! A leading `!` that sends a draft to a native Claude Code or Codex session as a shell command
//! (web `composerHighlight`): which drafts it marks, and why a send of one is refused.

/// The permission level of a session's owner (`LEVEL_OWNER` on the server).
const OWNER_LEVEL: i64 = 4;

/// Why a Codex shell command from someone other than the owner is refused.
pub const SHELL_OWNER_REFUSAL: &str =
    "Only the session's owner can run shell commands here; drop the leading `!` to ask the agent.";
/// Why a shell command with `@` mentions is refused: they become arguments.
pub const SHELL_MENTION_REFUSAL: &str =
    "Shell commands can't include @mentions; remove them or drop the leading `!`.";
/// Why a shell command with a reply quote is refused: the shell would run the quote.
pub const SHELL_QUOTE_REFUSAL: &str =
    "Shell commands can't carry a reply quote; remove it or drop the leading `!`.";
/// Why a shell command with review comments is refused.
pub const SHELL_REVIEW_COMMENT_REFUSAL: &str =
    "Shell commands can't carry review comments; remove them or drop the leading `!`.";

/// Whether `harness` runs a draft's leading `!` as a shell command.
#[must_use]
pub fn supports_native_shell_input(harness: &str) -> bool {
    harness == "claude-native" || harness == "codex-native"
}

/// Python's `str.isspace` set, which the server's `strip()`s use.
const fn is_python_space(character: char) -> bool {
    matches!(
        character,
        '\t' | '\n'
            | '\u{b}'
            | '\u{c}'
            | '\r'
            | '\u{1c}'..='\u{20}'
            | '\u{85}'
            | '\u{a0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200a}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202f}'
            | '\u{205f}'
            | '\u{3000}'
    )
}

/// Controls the claude-native paste encoder drops before Claude Code's terminal sees the text;
/// it keeps tab, newline, carriage return, DEL and C1.
const fn is_dropped_by_claude(character: char) -> bool {
    matches!(character, '\u{0}'..='\u{8}' | '\u{b}' | '\u{c}' | '\u{e}'..='\u{1f}')
}

/// The byte offset of the `!` that makes `text` a shell command for `harness`, or `None`.
///
/// Claude Code takes a `!` first in what its terminal receives, with something after it; Codex
/// takes one after leading whitespace, not `!!`, with something after it.
#[must_use]
pub fn native_shell_offset(text: &str, harness: &str) -> Option<usize> {
    match harness {
        "claude-native" => {
            let delivered: String = text
                .chars()
                .filter(|character| !is_dropped_by_claude(*character))
                .collect();
            let rest = delivered.strip_prefix('!')?;
            if rest.trim().is_empty() {
                return None;
            }
            text.find('!')
        }
        "codex-native" => {
            let rest = text.trim_start_matches(is_python_space);
            let start = text.len() - rest.len();
            let rest = rest.strip_prefix('!')?;
            if rest.starts_with('!') || rest.chars().all(is_python_space) {
                return None;
            }
            Some(start)
        }
        _ => None,
    }
}

/// What a draft's send carries besides its text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent parts of one send, each refusing a shell command"
)]
pub struct ShellSendContext {
    /// Workspace paths tagged with `@`.
    pub mentions: bool,
    /// Reply quotes.
    pub quotes: bool,
    /// Local review comments.
    pub review_comments: bool,
}

/// A draft the session would run as a shell command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellInput {
    /// The byte offset of its `!`.
    pub offset: usize,
    /// Why sending it is refused; `None` when it can go out.
    pub refusal: Option<&'static str>,
}

/// Whether `text` is a shell command in a session of `harness` that the viewer at
/// `permission_level` (`None` when unknown, read as the owner, as the web does) sends with
/// `context`, and why such a send is refused.
#[must_use]
pub fn shell_input(
    text: &str,
    harness: Option<&str>,
    permission_level: Option<i64>,
    context: ShellSendContext,
) -> Option<ShellInput> {
    let harness = harness.filter(|harness| supports_native_shell_input(harness))?;
    let offset = native_shell_offset(text, harness)?;
    let owner = permission_level.is_none_or(|level| level >= OWNER_LEVEL);
    let refusal = if harness == "codex-native" && !owner {
        Some(SHELL_OWNER_REFUSAL)
    } else if context.mentions {
        Some(SHELL_MENTION_REFUSAL)
    } else if context.quotes {
        Some(SHELL_QUOTE_REFUSAL)
    } else if context.review_comments {
        Some(SHELL_REVIEW_COMMENT_REFUSAL)
    } else {
        None
    };
    Some(ShellInput { offset, refusal })
}

#[cfg(test)]
#[path = "shell_input_tests.rs"]
mod tests;
