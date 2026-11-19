//! Workspace files and folders tagged with `@` in the composer.
//!
//! They travel as one marker line each ahead of the message (the web's `buildMentionPreamble`),
//! the format the native executors emit for attachments; the harness reads the file from the
//! workspace, nothing is uploaded.

use crate::config::session::canonical_harness;

/// The marker line for `path`: Codex says "Attached file", the others "Attached".
#[must_use]
pub fn mention_marker(harness: Option<&str>, path: &str) -> String {
    if canonical_harness(harness) == "codex-native" {
        format!("[Attached file: {path}]")
    } else {
        format!("[Attached: {path}]")
    }
}

/// The lines put ahead of a message for `paths`, ending in a blank line; empty without paths.
/// A folder keeps its trailing `/` so the agent opens the directory.
#[must_use]
pub fn mention_preamble(harness: Option<&str>, paths: &[String]) -> String {
    if paths.is_empty() {
        return String::new();
    }
    let lines: Vec<String> = paths
        .iter()
        .map(|path| mention_marker(harness, path))
        .collect();
    format!("{}\n\n", lines.join("\n"))
}

/// A sent message as Edit and resend puts it back in the composer.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RecalledMessage {
    /// The paths its leading marker lines tagged, to show as `@` chips again.
    pub mentions: Vec<String>,
    /// The text after them.
    pub text: String,
}

/// `text`, a sent message, back as the composer takes it to edit (the web's
/// `recallFileMentions`).
///
/// The marker lines [`mention_preamble`] put ahead of it become `@` paths again, in either
/// harness's wording, and the rest is the text. A message without them comes back whole.
#[must_use]
pub fn recall_sent_message(text: &str) -> RecalledMessage {
    let mut mentions = Vec::new();
    let mut rest = text;
    loop {
        let (line, after) = rest.split_once('\n').unwrap_or((rest, ""));
        let Some(path) = marker_path(line.trim_end_matches('\r')) else {
            break;
        };
        if !mentions.iter().any(|known| known == path) {
            mentions.push(path.to_owned());
        }
        rest = after;
        if after.is_empty() {
            break;
        }
    }
    if mentions.is_empty() {
        return RecalledMessage {
            mentions,
            text: text.to_owned(),
        };
    }
    RecalledMessage {
        mentions,
        text: rest.trim_start_matches(['\r', '\n']).to_owned(),
    }
}

/// The path a `[Attached: path]` or `[Attached file: path]` line names.
fn marker_path(line: &str) -> Option<&str> {
    let inner = line.strip_prefix('[')?.strip_suffix(']')?;
    let path = inner
        .strip_prefix("Attached file: ")
        .or_else(|| inner.strip_prefix("Attached: "))?;
    (!path.trim().is_empty() && !path.contains(']')).then_some(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sent_message_gives_back_its_tagged_paths_and_text() {
        let paths = ["src/main.rs".to_owned(), "docs/".to_owned()];
        for harness in ["claude-native", "codex-native"] {
            let sent = format!(
                "{}Explain [Attached: x] here\nand there",
                mention_preamble(Some(harness), &paths)
            );
            assert_eq!(
                recall_sent_message(&sent),
                RecalledMessage {
                    mentions: paths.to_vec(),
                    text: "Explain [Attached: x] here\nand there".to_owned(),
                },
                "{harness}"
            );
        }
        assert_eq!(
            recall_sent_message("Just text\n[Attached: a.rs]"),
            RecalledMessage {
                mentions: Vec::new(),
                text: "Just text\n[Attached: a.rs]".to_owned(),
            }
        );
        assert_eq!(
            recall_sent_message("[Attached: a.rs]"),
            RecalledMessage {
                mentions: vec!["a.rs".to_owned()],
                text: String::new(),
            }
        );
        assert_eq!(
            recall_sent_message("[Attached: ]\nhi").mentions,
            Vec::<String>::new()
        );
    }

    #[test]
    fn markers_follow_the_harness_and_end_in_a_blank_line() {
        let paths = ["src/main.rs".to_owned(), "docs/".to_owned()];
        assert_eq!(
            mention_preamble(Some("claude-native"), &paths),
            "[Attached: src/main.rs]\n[Attached: docs/]\n\n"
        );
        assert_eq!(
            mention_preamble(Some("native-codex"), &paths[..1]),
            "[Attached file: src/main.rs]\n\n"
        );
        assert_eq!(mention_preamble(None, &[]), "");
    }
}
