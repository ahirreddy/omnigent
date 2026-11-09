//! File changes and the separated message, from `fixtures/decisions/FileChanges--*` (hand-built
//! with the server's own preview formulas; see the fixtures README).

use omnigent_protocol::{ElicitationRequest, FromWire};
use serde_json::{Value, json};

use super::changes::format_preview;
use super::*;

const SESSION_RS: &str = "/Users/dev/omnigent/client-core/crates/omnigent-core/src/auth/session.rs";

fn shapes() -> Value {
    let path = format!(
        "{}/../../fixtures/decisions/FileChanges--ServerApprovalShapes.json",
        env!("CARGO_MANIFEST_DIR")
    );
    let text =
        std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("reading {path}: {error}"));
    serde_json::from_str(&text).unwrap()
}

fn card(label: &str) -> Decision {
    let shapes = shapes();
    let value = shapes
        .get(label)
        .unwrap_or_else(|| panic!("no fixture {label}"));
    Decision::from_request(
        &ElicitationRequest::from_value(value.clone()).unwrap(),
        "conv_a",
    )
}

fn change(
    path: &str,
    kind: Option<FileChangeKind>,
    added: Option<u32>,
    removed: Option<u32>,
) -> FileChange {
    FileChange {
        path: path.to_owned(),
        kind,
        lines_added: added,
        lines_removed: removed,
    }
}

use FileChangeKind::{Create, Delete, Modify, Write};

#[test]
fn edit_tools_list_their_file_with_web_line_counts() {
    let cases = [
        (
            "claude-edit",
            change(SESSION_RS, Some(Modify), Some(3), Some(1)),
        ),
        (
            "claude-multiedit",
            change(
                "/Users/dev/omnigent/README.md",
                Some(Modify),
                Some(2),
                Some(1),
            ),
        ),
        (
            "claude-write",
            change(
                "/Users/dev/omnigent/docs/notes.md",
                Some(Write),
                Some(4),
                None,
            ),
        ),
        (
            "claude-notebook",
            change("/Users/dev/analysis.ipynb", Some(Modify), Some(2), Some(0)),
        ),
        (
            "devin-edit",
            change("/repo/app.py", Some(Modify), Some(1), Some(1)),
        ),
        (
            "policy-sys-os-edit",
            change("/repo/src/lib.rs", Some(Modify), Some(1), Some(0)),
        ),
    ];
    for (label, expected) in cases {
        assert_eq!(
            card(label).permissions.file_changes,
            vec![expected],
            "{label}"
        );
    }
}

#[test]
fn a_cut_preview_keeps_whole_paths_and_drops_counts_it_cannot_know() {
    assert_eq!(
        card("claude-edit-cut").permissions.file_changes,
        vec![change(SESSION_RS, Some(Modify), None, None)]
    );
    assert_eq!(
        card("pi-sdk-write-cut").permissions.file_changes,
        vec![change(
            "/repo/generated/schema.json",
            Some(Write),
            None,
            None
        )]
    );
    assert_eq!(
        card("codex-apply-patch-cut").permissions.file_changes,
        vec![
            change("/repo/src/a.rs", Some(Modify), Some(1), Some(1)),
            change("/repo/src/big.rs", Some(Create), None, None),
            change("/repo/src/z.rs", None, None, None),
        ]
    );
}

#[test]
fn codex_patches_list_every_file_in_order() {
    assert_eq!(
        card("policy-apply-patch").permissions.file_changes,
        vec![
            change("/repo/src/new.rs", Some(Create), Some(1), Some(0)),
            change("/repo/src/old.rs", Some(Delete), Some(0), Some(2)),
            change("/repo/src/main.rs", Some(Modify), Some(1), Some(1)),
        ]
    );
    assert_eq!(
        card("codex-apply-patch").permissions.file_changes,
        vec![
            change("/repo/src/main.rs", Some(Modify), Some(2), Some(1)),
            change("/repo/src/new.rs", Some(Create), Some(1), Some(0)),
            change("/repo/src/old.rs", Some(Delete), Some(0), Some(1)),
        ]
    );
}

#[test]
fn requests_that_are_not_edits_list_no_files() {
    for label in ["claude-bash", "codex-file-change"] {
        assert_eq!(card(label).permissions.file_changes, Vec::new(), "{label}");
    }
}

#[test]
fn the_message_and_the_tool_input_come_apart() {
    let edit = card("claude-edit");
    assert_eq!(
        edit.message.as_deref(),
        Some("Claude wants to call **Edit**")
    );
    let input = edit.tool_input.unwrap();
    assert!(
        input.starts_with(&format!(
            "Edit({{\n  \"file_path\": \"{SESSION_RS}\",\n  \"old_string\""
        )),
        "{input}"
    );
    assert!(input.ends_with("\"replace_all\": false\n})"), "{input}");
    // The joined detail is unchanged for surfaces that read it.
    assert!(
        edit.detail
            .starts_with("Claude wants to call **Edit**\n\nEdit({")
    );

    // A cut preview is re-indented verbatim, never completed or reordered.
    let cut = card("claude-edit-cut").tool_input.unwrap();
    assert!(cut.ends_with("let value_2)"), "{cut}");

    // Fields a card shows on its own are not repeated as tool input.
    let command = Decision::from_request(
        &ElicitationRequest::from_value(json!({
            "elicitation_id": "c",
            "params": {"message": "Run tests?", "command": "cargo test", "content_preview": "{\"command\": \"cargo test\"}"}
        }))
        .unwrap(),
        "conv_a",
    );
    assert_eq!(command.message.as_deref(), Some("Run tests?"));
    assert_eq!(command.tool_input, None);
    let blank = Decision::from_request(
        &ElicitationRequest::from_value(
            json!({"elicitation_id": "b", "params": {"message": "  "}}),
        )
        .unwrap(),
        "conv_a",
    );
    assert_eq!((blank.message, blank.tool_input), (None, None));
}

#[test]
fn line_counts_match_the_web_line_diff() {
    let edit = |old: &str, new: &str| {
        let preview = format!(
            "Edit({})",
            json!({"file_path": "/f", "old_string": old, "new_string": new})
        );
        let card = Decision::from_request(
            &ElicitationRequest::from_value(json!({
                "elicitation_id": "e", "params": {"content_preview": preview}
            }))
            .unwrap(),
            "conv_a",
        );
        let file = card.permissions.file_changes.into_iter().next().unwrap();
        (file.lines_added.unwrap(), file.lines_removed.unwrap())
    };
    // Only the final newline changed: one blank line added or removed.
    assert_eq!(edit("a\nb", "a\nb\n"), (1, 0));
    assert_eq!(edit("a\nb\n", "a\nb"), (0, 1));
    // An unchanged pair changes nothing.
    assert_eq!(edit("same", "same"), (0, 0));
    // Shared lines in the middle are kept.
    assert_eq!(edit("a\nx\nb\nc\n", "a\ny\nb\nz\nc\n"), (2, 1));
    // A region past the comparison budget is a whole-block replacement.
    let lines = |mark: &str| {
        (0..600)
            .map(|i| format!("{mark}{i}"))
            .collect::<Vec<_>>()
            .join("\n")
    };
    let (old, new) = (lines("o"), lines("n"));
    assert_eq!(edit(&old, &new), (600, 600));
}

#[test]
fn other_preview_shapes_never_invent_files() {
    let changes = |params: Value| {
        Decision::from_request(
            &ElicitationRequest::from_value(json!({"elicitation_id": "x", "params": params}))
                .unwrap(),
            "conv_a",
        )
        .permissions
        .file_changes
    };
    for preview in [
        "Edit(not json)",
        "Edit([1, 2])",
        "Edit({\"old_string\": \"a\", \"new_string\": \"b\"})",
        "free text (or not)",
        "{\"name\": \"Edit\"}",
        "{\"name\": \"apply_patch\", \"arguments\": {\"changes\": [{\"path\": \"/a\", \"kind\": {\"type\": \"add\"}, \"diff\": \"x\"}, {\"pa",
        "9Edit({\"file_path\": \"/a\", \"old_string\": \"a\", \"new_string\": \"b\"})",
    ] {
        assert_eq!(
            changes(json!({"content_preview": preview})),
            Vec::new(),
            "{preview}"
        );
    }
    // A string `arguments` (Devin's policy body) is read as JSON.
    let arguments = json!({"path": "/a", "content": "x\n"}).to_string();
    assert_eq!(
        changes(
            json!({"content_preview": json!({"name": "write", "arguments": arguments}).to_string()})
        ),
        vec![change("/a", Some(Write), Some(1), None)]
    );
    // Claude's `tool_name` names the tool even when the preview's name differs.
    assert_eq!(
        changes(json!({
            "tool_name": "Write",
            "content_preview": "Tool({\"file_path\": \"/b\", \"content\": \"\"})"
        })),
        vec![change("/b", Some(Write), Some(0), None)]
    );
}

fn request_changes(params: &Value) -> Vec<FileChange> {
    let request =
        ElicitationRequest::from_value(json!({"elicitation_id": "x", "params": params})).unwrap();
    Decision::from_request(&request, "conv_a")
        .permissions
        .file_changes
}

fn tool_changes(preview: &str) -> Vec<FileChange> {
    request_changes(&json!({"content_preview": preview}))
}

fn codex_changes(preview: &str, files: Option<Value>) -> Vec<FileChange> {
    let mut params = json!({"phase": "codex_apply_patch_approval", "content_preview": preview});
    if let Some(files) = files {
        params["files"] = files;
    }
    request_changes(&params)
}

#[test]
fn a_multi_edit_skips_no_ops_and_stops_counting_at_a_cut_edit() {
    let body = json!({"file_path": "/a", "edits": [
        {"old_string": "x", "new_string": "y"},
        {"old_string": "same", "new_string": "same"},
        {"old_string": 7},
    ]});
    assert_eq!(
        tool_changes(&format!("MultiEdit({body})")),
        vec![change("/a", Some(Modify), Some(1), Some(1))]
    );
    let cut = r#"MultiEdit({"file_path": "/a", "edits": [{"old_string": "x", "new_str"#;
    assert_eq!(
        tool_changes(cut),
        vec![change("/a", Some(Modify), None, None)],
        "a cut edit list has no reliable count"
    );
}

#[test]
fn notebook_edits_count_by_mode() {
    let notebook = |fields: Value| {
        let mut input = json!({"notebook_path": "/n.ipynb", "new_source": "a\nb\n"});
        for (key, value) in fields.as_object().unwrap() {
            input[key] = value.clone();
        }
        tool_changes(&format!("NotebookEdit({input})"))
    };
    let counts = |changes: Vec<FileChange>| (changes[0].lines_added, changes[0].lines_removed);
    assert_eq!(
        counts(notebook(json!({}))),
        (Some(2), None),
        "replace is the default"
    );
    assert_eq!(
        counts(notebook(json!({"edit_mode": "replace"}))),
        (Some(2), None)
    );
    assert_eq!(
        counts(notebook(json!({"edit_mode": "insert"}))),
        (Some(2), Some(0))
    );
    assert_eq!(
        counts(notebook(json!({"edit_mode": "delete"}))),
        (Some(0), None)
    );
    assert_eq!(
        counts(notebook(json!({"edit_mode": "other"}))),
        (None, None)
    );
    let cut = r#"NotebookEdit({"notebook_path": "/n.ipynb", "new_source": "a"#;
    assert_eq!(counts(tool_changes(cut)), (None, None));
}

#[test]
fn apply_patch_entries_of_every_shape() {
    let patch = |changes: Value| {
        tool_changes(&json!({"name": "apply_patch", "arguments": {"changes": changes}}).to_string())
    };
    assert_eq!(
        patch(json!([
            {"kind": {"type": "add"}, "diff": "x"},
            {"path": "/mystery", "kind": 7, "diff": "x"},
            {"path": "/odd", "kind": {"type": "brand_new"}, "diff": "x"},
            {"path": "/s", "kind": "add", "diff": "one\n"},
        ])),
        vec![change("/s", Some(Create), Some(1), Some(0))],
    );
    let unchanged = patch(json!([
        {"path": "/same", "kind": {"type": "update"}, "diff": "@@ -1 +1 @@\n unchanged\n"},
        {"path": "/moved", "kind": {"type": "update", "move_path": "/new"}, "diff": "@@ -1 +1 @@\n x\n"},
        {"path": "/stay", "kind": {"type": "update", "move_path": "/stay"}, "diff": "@@ -1 +1 @@\n x\n"},
    ]));
    assert_eq!(
        unchanged
            .iter()
            .map(|file| file.path.as_str())
            .collect::<Vec<_>>(),
        ["/moved"],
        "an unchanged, unrenamed update changes nothing"
    );
}

#[test]
fn legacy_codex_changes_read_each_shape() {
    let entries = json!({"fileChanges": {
        "/add": {"add": {"content": "one\ntwo\n"}},
        "/del": {"delete": {"content": "one\n"}},
        "/upd": {"update": {"unified_diff": "--- a\n+++ b\n+new\n-old\n"}},
        "/typed": {"type": "add", "content": "x\n"},
        "/none": {},
    }})
    .to_string();
    let files = codex_changes(&entries, None);
    let shown: Vec<(&str, Option<u32>, Option<u32>)> = files
        .iter()
        .map(|file| (file.path.as_str(), file.lines_added, file.lines_removed))
        .collect();
    assert_eq!(
        shown,
        [
            ("/add", Some(2), Some(0)),
            ("/del", Some(0), Some(1)),
            ("/none", None, None),
            ("/typed", Some(1), Some(0)),
            ("/upd", Some(1), Some(1)),
        ]
    );
    assert_eq!(
        codex_changes("[1]", None),
        Vec::new(),
        "no files and no map"
    );
    assert_eq!(codex_changes("{}", Some(json!([]))), Vec::new());
    assert_eq!(
        codex_changes("{", None),
        Vec::new(),
        "a cut map may miss files"
    );
    assert_eq!(
        codex_changes("{}", Some(json!(["/listed", "", 7]))),
        vec![change("/listed", None, None, None)]
    );
}

#[test]
fn a_diff_without_a_hunk_header_is_counted_after_its_file_headers() {
    let counts = |diff: &str| {
        let body = json!({"name": "apply_patch", "arguments": {"changes": [
            {"path": "/f", "kind": "update", "diff": diff},
        ]}});
        let files = tool_changes(&body.to_string());
        files
            .first()
            .map(|file| (file.lines_added, file.lines_removed))
    };
    assert_eq!(counts("--- a\n+++ b\n+added\n"), Some((Some(1), Some(0))));
    assert_eq!(counts("+added\n-removed\n"), Some((Some(1), Some(1))));
    assert_eq!(counts("--- a\nnot a header\n"), Some((Some(0), Some(1))));
    assert_eq!(counts(""), None, "an empty update changes nothing");
}

#[test]
fn reindenting_keeps_empty_containers_and_strings_intact() {
    assert_eq!(format_preview("{}").as_deref(), Some("{}"));
    assert_eq!(
        format_preview(r#"{"a": [], "b": {   "c": "x { y"}}"#).as_deref(),
        Some("{\n  \"a\": [],\n  \"b\": {\n    \"c\": \"x { y\"\n  }\n}")
    );
    assert_eq!(
        format_preview(r#"{ "a": "\"}"}"#).as_deref(),
        Some("{\n  \"a\": \"\\\"}\"\n}"),
    );
    assert_eq!(format_preview("   "), None);
    assert_eq!(
        format_preview("plain (text)").as_deref(),
        Some("plain (text)")
    );
    assert_eq!(
        format_preview(r#"Tool({"a": 1}"#).as_deref(),
        Some("Tool({\n  \"a\": 1\n}")
    );
    assert_eq!(format_preview("]]]").as_deref(), Some("]]]"));
}

#[test]
fn deep_nesting_cannot_inflate_a_preview_without_bound() {
    // Each level used to add a line indented by its depth: 50k brackets asked for 2.5 GB.
    let formatted = format_preview(&"[".repeat(50_000)).unwrap();
    assert!(formatted.len() < 50_000 * 200, "{}", formatted.len());
    assert!(formatted.starts_with("[\n  [\n    [\n"));
}
