use super::markdown_preview_text as preview;

#[test]
fn reads_a_steps_inputs_what_it_does_outputs_and_details_as_one_line() {
    let goal = [
        "**Inputs:** the pull request named in the run's request, and its CI checks.",
        "",
        "**What it does:**",
        "- Reads the logs of each failing check",
        "- Fixes the cause and pushes",
        "",
        "**Outputs:** the PR with passing checks.",
        "",
        "**Details:** list the checks with `gh pr checks <number> --json name,state`.",
    ]
    .join("\n");
    assert_eq!(
        preview(&goal),
        "Inputs: the pull request named in the run's request, and its CI checks. What it does: \
         Reads the logs of each failing check · Fixes the cause and pushes · Outputs: the PR \
         with passing checks. Details: list the checks with gh pr checks <number> --json name,state."
    );
}

#[test]
fn joins_a_paragraphs_lines_with_spaces_and_separates_blocks() {
    let text = [
        "Reads the logs of each",
        "failing check",
        "",
        "- Fixes the cause",
        "  and pushes",
        "- Reports back",
        "",
        "> Quoted on",
        "> two lines",
        "## Next",
        "Then stop",
    ]
    .join("\n");
    assert_eq!(
        preview(&text),
        "Reads the logs of each failing check · Fixes the cause and pushes · Reports back · \
         Quoted on two lines · Next · Then stop"
    );
    // Windows and old Mac line endings split lines too.
    assert_eq!(preview("One\r\ntwo\r\rThree"), "One two · Three");
}

#[test]
fn keeps_code_as_written_without_its_backticks_or_fences() {
    assert_eq!(
        preview("Match `**/*.ts` and `` a`b `` in **`src`** files"),
        "Match **/*.ts and a`b in src files"
    );
    assert_eq!(
        preview("Run:\n\n```sh\npnpm test --filter web\n```\n\nThen push."),
        "Run: pnpm test --filter web · Then push."
    );
    // An escaped backtick is a backtick, not code.
    assert_eq!(preview("Type \\`not code\\` here"), "Type `not code` here");
    // Code, like emphasis, can go on across a paragraph's lines.
    assert_eq!(
        preview("Keep `a\n*b*` as code, **all\nof it**"),
        "Keep a *b* as code, all of it"
    );
    // A fence closes only on as many of its own character; a tilde fence holds backticks.
    assert_eq!(
        preview("~~~~\n```\nx\n~~~\n~~~~\nDone."),
        "``` · x · ~~~ · Done."
    );
}

#[test]
fn shows_a_links_label_and_an_images_alt_text_without_block_markers() {
    let text = [
        "## Inputs",
        "> See [the runbook](https://example.com/runbook_(v2)) first.",
        "1. [x] Read ![the chart](chart.png)",
        "2) Open <https://example.com>",
    ]
    .join("\n");
    assert_eq!(
        preview(&text),
        "Inputs · See the runbook first. Read the chart · Open https://example.com"
    );
    assert_eq!(
        preview("[docs](https://example.com \"The docs\") and [ref][1], ![](x.png)"),
        "docs and ref,"
    );
    // Seven hashes or ten digits are no marker.
    assert_eq!(preview("####### Seven"), "####### Seven");
    assert_eq!(preview("1234567890. Ten"), "1234567890. Ten");
}

#[test]
fn keeps_a_tables_cells_and_leaves_out_its_rules() {
    assert_eq!(
        preview("| Flag | Use |\n| --- | :-: |\n| `--json` | Output |\n\n---\n\nDone."),
        "Flag · Use · --json · Output · Done."
    );
    // An escaped pipe stays in its cell, in code too.
    assert_eq!(preview("| `a\\|b` | c\\|d |"), "a|b · c|d");
}

#[test]
fn leaves_marks_that_mark_nothing_and_escaped_ones_as_written() {
    assert_eq!(
        preview(
            "Multiply 2 * 3 in my_file_name.py, not \\*this\\*, but _this_, *that* and ~~those~~."
        ),
        "Multiply 2 * 3 in my_file_name.py, not *this*, but this, that and those."
    );
    assert_eq!(preview("**a**, **b** _c_ `d` `e`"), "a, b c d e");
}

#[test]
fn keeps_placeholders_such_as_a_date_as_written() {
    assert_eq!(
        preview("Create the release-<date> branch from <base>."),
        "Create the release-<date> branch from <base>."
    );
}

#[test]
fn drops_private_use_characters_that_would_read_as_its_placeholders() {
    assert_eq!(preview("\u{E000}1\u{E000} and `x`"), "1 and x");
}

#[test]
fn reads_only_the_start_of_a_long_source() {
    let text = format!("{}\n\n**Details:** sentinel", "word ".repeat(400));
    let shown = preview(&text);
    assert!(shown.starts_with("word word"));
    assert!(!shown.contains("sentinel"));
}

#[test]
fn is_empty_when_no_text_remains() {
    assert_eq!(preview(""), "");
    assert_eq!(preview("---\n\n  \n-\n"), "");
    assert_eq!(preview("```\n```"), "");
}
