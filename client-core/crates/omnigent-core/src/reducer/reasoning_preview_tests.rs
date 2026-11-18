//! Ports of the header-preview cases in `web/src/components/blocks/ReasoningView.test.tsx`.

use super::*;

#[test]
fn the_preview_is_the_first_prose_line_without_markdown_marks() {
    let cases = [
        (
            "\n  Checking the lockfile first.\nThen the build config.",
            "Checking the lockfile first.",
        ),
        (
            "## **Planning** the `retry` fix\n\nDetails.",
            "Planning the retry fix",
        ),
        (
            "Checking __init__.py and `__main__` first.",
            "Checking __init__.py and __main__ first.",
        ),
        ("---\n```python\nimport os\n```", "import os"),
        ("* * *\n~~~\n> - 1. **Deep** quote", "Deep quote"),
        ("####### seven hashes", "####### seven hashes"),
        ("-not a list", "-not a list"),
        ("2) Second step", "Second step"),
        ("**** stars ``", "**** stars ``"),
        ("\u{1b}[1mBold\u{1b}[0m start", "Bold start"),
        ("\u{1b}]0;title\u{7}Titled", "Titled"),
    ];
    for (text, expected) in cases {
        assert_eq!(reasoning_preview(text), expected, "{text:?}");
    }
}

#[test]
fn a_thought_with_no_prose_has_no_preview() {
    for text in ["", "   \n  ", "```\n```", "---\n***"] {
        assert_eq!(reasoning_preview(text), "", "{text:?}");
    }
}

#[test]
fn terminal_controls_are_removed() {
    assert_eq!(strip_ansi("a\u{1b}[31mred\u{1b}[m b"), "ared b");
    assert_eq!(strip_ansi("\u{9b}2Kcleared"), "cleared");
    assert_eq!(
        strip_ansi("x\u{1b}]8;;https://example.com\u{1b}\\link"),
        "xlink"
    );
    assert_eq!(strip_ansi("stray \u{85}C1"), "stray C1");
    assert_eq!(strip_ansi("lone \u{1b}["), "lone [");
}
