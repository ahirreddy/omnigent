//! The native `!` shell rules, case by case as the web's `composerHighlight` tests them.

use super::{
    SHELL_MENTION_REFUSAL, SHELL_OWNER_REFUSAL, SHELL_QUOTE_REFUSAL, SHELL_REVIEW_COMMENT_REFUSAL,
    ShellSendContext, native_shell_offset, shell_input,
};

#[test]
fn claude_takes_a_leading_bang_after_the_controls_its_terminal_drops() {
    assert_eq!(native_shell_offset("!ls -la", "claude-native"), Some(0));
    assert_eq!(native_shell_offset("\u{1}!ls", "claude-native"), Some(1));
    // Whitespace reaches the terminal, so a `!` after it is text.
    assert_eq!(native_shell_offset(" !ls", "claude-native"), None);
    assert_eq!(native_shell_offset("!", "claude-native"), None);
    assert_eq!(native_shell_offset("!   \n", "claude-native"), None);
    assert_eq!(native_shell_offset("say !hi", "claude-native"), None);
}

#[test]
fn codex_skips_leading_whitespace_and_reads_a_double_bang_as_text() {
    assert_eq!(
        native_shell_offset("  !git status", "codex-native"),
        Some(2)
    );
    assert_eq!(native_shell_offset("\u{a0}!pwd", "codex-native"), Some(2));
    assert_eq!(native_shell_offset("!!git status", "codex-native"), None);
    assert_eq!(native_shell_offset("! \u{3000}", "codex-native"), None);
    assert_eq!(native_shell_offset("hi !there", "codex-native"), None);
}

#[test]
fn other_harnesses_have_no_shell_input() {
    assert_eq!(native_shell_offset("!ls", "claude-sdk"), None);
    assert_eq!(
        shell_input("!ls", Some("codex"), None, ShellSendContext::default()),
        None
    );
    assert_eq!(
        shell_input("!ls", None, None, ShellSendContext::default()),
        None
    );
}

#[test]
fn a_shell_send_is_refused_for_what_would_reach_the_shell() {
    let plain = shell_input(
        "!ls",
        Some("claude-native"),
        Some(2),
        ShellSendContext::default(),
    )
    .unwrap();
    assert_eq!(plain.offset, 0);
    assert_eq!(plain.refusal, None, "Claude takes anyone's shell input");
    let refusal = |context| {
        shell_input("!ls", Some("claude-native"), None, context)
            .unwrap()
            .refusal
    };
    assert_eq!(
        refusal(ShellSendContext {
            mentions: true,
            ..ShellSendContext::default()
        }),
        Some(SHELL_MENTION_REFUSAL)
    );
    assert_eq!(
        refusal(ShellSendContext {
            quotes: true,
            ..ShellSendContext::default()
        }),
        Some(SHELL_QUOTE_REFUSAL)
    );
    assert_eq!(
        refusal(ShellSendContext {
            review_comments: true,
            ..ShellSendContext::default()
        }),
        Some(SHELL_REVIEW_COMMENT_REFUSAL)
    );
}

#[test]
fn codex_runs_only_the_owners_shell_input() {
    let as_level = |level| {
        shell_input(
            "!ls",
            Some("codex-native"),
            level,
            ShellSendContext::default(),
        )
        .unwrap()
        .refusal
    };
    assert_eq!(as_level(Some(4)), None);
    assert_eq!(as_level(None), None, "an unknown level reads as the owner");
    assert_eq!(as_level(Some(3)), Some(SHELL_OWNER_REFUSAL));
}
