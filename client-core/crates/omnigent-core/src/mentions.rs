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

#[cfg(test)]
mod tests {
    use super::*;

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
