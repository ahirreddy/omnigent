//! The files an edit approval would change, read from the gated tool call, and the tool input
//! formatted for display.
//!
//! Where the server puts the tool call:
//! - **Native permission hooks** (Claude, Kimi, Devin through `PermissionRequest`) and **SDK
//!   harnesses**: `content_preview` is `ToolName(<json.dumps(tool_input)>)`, the JSON capped at
//!   1024 (hooks) or 300 (SDK) characters. Claude's hook also stamps `tool_name`.
//! - **Policy evaluation** for native harnesses: `content_preview` is
//!   `{"name": ..., "arguments": ...}`, capped at 1024 characters.
//! - **Codex `applyPatchApproval`** (`phase = codex_apply_patch_approval`): `content_preview` is
//!   the request params with `fileChanges: {path: FileChange}`, capped at 1024 characters, and
//!   `files` lists every path, sorted.
//! - **Codex `item/fileChange/requestApproval`** carries no changes (they arrive on the
//!   `fileChange` item after the turn), so it lists no files.
//!
//! The tool shapes follow the web's `toolEditDiff.ts`: Claude `Edit`/`MultiEdit`, Omnigent
//! `sys_os_edit`, Pi and `OpenCode` `edit` (old/new pairs); `Write`, `sys_os_write`, `write` (whole
//! content); Codex `apply_patch` (`changes: [{path, kind, diff}]`); plus Claude `NotebookEdit`.
//! Counts follow the web's line diff: a batch adds up each edit's own change, and a replace-all
//! edit counts one match.
//!
//! A preview cut off by the cap still lists a file whose path arrived whole, with counts only
//! when every input they need arrived whole. A cut list of files whose full set is unknown lists
//! nothing rather than some of them. File contents never leave this module.

use serde_json::{Map, Value};

use super::partial_json::{self, Json};

/// What happens to a file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FileChangeKind {
    /// The file is created.
    Create,
    /// Parts of the file change.
    Modify,
    /// The file is deleted.
    Delete,
    /// The whole file is written: created, or replaced without its old content being known.
    Write,
}

/// One file an edit approval would change.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FileChange {
    /// The path as the agent reported it.
    pub path: String,
    /// What happens to it; `None` when the request does not say.
    pub kind: Option<FileChangeKind>,
    /// Lines added; `None` when unknown.
    pub lines_added: Option<u32>,
    /// Lines removed; `None` when unknown.
    pub lines_removed: Option<u32>,
}

const CODEX_APPLY_PATCH_PHASE: &str = "codex_apply_patch_approval";
const OMNIGENT_TOOL_PREFIX: &str = "mcp__omnigent__";
const EDIT_PAIR_TOOLS: [&str; 4] = ["Edit", "MultiEdit", "sys_os_edit", "edit"];
const WRITE_TOOLS: [&str; 3] = ["Write", "sys_os_write", "write"];
const PATH_KEYS: [&str; 3] = ["file_path", "path", "filePath"];
/// Line comparison steps one call's edits may use; a changed region past what is left counts as
/// a whole-block replacement (the web's `MAX_LINE_DIFF_CELLS`).
const MAX_LINE_DIFF_CELLS: usize = 250_000;

/// The files the request's gated tool call would change, in the order the request lists them.
pub(super) fn file_changes(
    phase: Option<&str>,
    preview: Option<&str>,
    extra: &Map<String, Value>,
) -> Vec<FileChange> {
    let Some(preview) = preview.map(str::trim).filter(|preview| !preview.is_empty()) else {
        return Vec::new();
    };
    if phase == Some(CODEX_APPLY_PATCH_PHASE) {
        return partial_json::parse(preview)
            .map(|params| codex_patch_changes(&params, extra.get("files")))
            .unwrap_or_default();
    }
    let Some((name, input)) = tool_call(preview, extra) else {
        return Vec::new();
    };
    let tool = name.strip_prefix(OMNIGENT_TOOL_PREFIX).unwrap_or(&name);
    if EDIT_PAIR_TOOLS.contains(&tool) {
        edit_change(&input).into_iter().collect()
    } else if WRITE_TOOLS.contains(&tool) {
        write_change(&input).into_iter().collect()
    } else if tool == "NotebookEdit" {
        notebook_change(&input).into_iter().collect()
    } else if tool == "apply_patch" {
        input.get("changes").map(patch_changes).unwrap_or_default()
    } else {
        Vec::new()
    }
}

/// `ToolName({...})` or `{"name": ..., "arguments": {...}}`: the tool name (Claude's `tool_name`
/// extra wins) and its input object.
fn tool_call(preview: &str, extra: &Map<String, Value>) -> Option<(String, Json)> {
    let stamped = extra
        .get("tool_name")
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty());
    let (name, input) = if preview.starts_with('{') {
        let envelope = partial_json::parse(preview).ok()?;
        let name = envelope.text(&["name"])?.to_owned();
        let input = match envelope.get("arguments")? {
            Json::String(arguments) => partial_json::parse(arguments).ok()?,
            arguments => arguments.clone(),
        };
        (name, input)
    } else {
        let (name, body) = preview.split_once('(')?;
        if !is_tool_name(name) {
            return None;
        }
        // The server appends `)` even after cutting the JSON.
        let body = body.strip_suffix(')').unwrap_or(body);
        (name.to_owned(), partial_json::parse(body).ok()?)
    };
    matches!(input, Json::Object(..)).then(|| (stamped.map_or(name, str::to_owned), input))
}

/// `[A-Za-z_][A-Za-z0-9_.-]*`, as the web's preview formatter matches it.
fn is_tool_name(name: &str) -> bool {
    name.chars()
        .next()
        .is_some_and(|first| first.is_ascii_alphabetic() || first == '_')
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
}

fn path_of(input: &Json, keys: &[&str]) -> Option<String> {
    input
        .text(keys)
        .filter(|path| !path.is_empty())
        .map(str::to_owned)
}

struct Budget {
    cells: usize,
}

fn edit_change(input: &Json) -> Option<FileChange> {
    let path = path_of(input, &PATH_KEYS)?;
    let mut budget = Budget {
        cells: MAX_LINE_DIFF_CELLS,
    };
    let counts = match input.get("edits") {
        Some(Json::Array(edits, cut)) => {
            let mut totals = (0_usize, 0_usize);
            let mut known = !cut;
            for edit in edits {
                match pair(edit) {
                    Pair::Change(old, new) => {
                        let (added, removed) = pair_counts(old, new, &mut budget);
                        totals = (totals.0 + added, totals.1 + removed);
                    }
                    Pair::Unchanged => {}
                    Pair::Cut => known = false,
                }
            }
            known.then_some(totals)
        }
        _ => match pair(input) {
            Pair::Change(old, new) => Some(pair_counts(old, new, &mut budget)),
            Pair::Unchanged => Some((0, 0)),
            Pair::Cut => None,
        },
    };
    Some(FileChange {
        path,
        kind: Some(FileChangeKind::Modify),
        lines_added: counts.map(|(added, _)| clamp(added)),
        lines_removed: counts.map(|(_, removed)| clamp(removed)),
    })
}

/// One old/new pair, in any harness's key style.
enum Pair<'a> {
    /// `old` becomes `new`.
    Change(&'a str, &'a str),
    /// Nothing changes: equal texts, or a complete object without a pair (as on the web).
    Unchanged,
    /// The pair did not arrive whole.
    Cut,
}

fn pair(value: &Json) -> Pair<'_> {
    let old = value.text(&["old_string", "oldText", "oldString"]);
    let new = value.text(&["new_string", "newText", "newString"]);
    match (old, new) {
        (Some(old), Some(new)) if old != new => Pair::Change(old, new),
        (Some(_), Some(_)) => Pair::Unchanged,
        _ if value.is_cut() => Pair::Cut,
        _ => Pair::Unchanged,
    }
}

fn write_change(input: &Json) -> Option<FileChange> {
    let path = path_of(input, &PATH_KEYS)?;
    Some(FileChange {
        path,
        kind: Some(FileChangeKind::Write),
        lines_added: input
            .text(&["content"])
            .map(|content| clamp(split_lines(content).len())),
        lines_removed: None,
    })
}

/// Claude `NotebookEdit`: `{notebook_path, cell_id?, new_source, cell_type?, edit_mode?}`, where
/// `edit_mode` is `replace` (the default), `insert` or `delete`.
fn notebook_change(input: &Json) -> Option<FileChange> {
    let path = path_of(input, &["notebook_path"])?;
    let mode = match input.text(&["edit_mode"]) {
        Some(mode) => Some(mode),
        None if input.is_cut() => None,
        None => Some("replace"),
    };
    let source = input
        .text(&["new_source"])
        .map(|source| clamp(split_lines(source).len()));
    let (added, removed) = match mode {
        Some("insert") => (source, Some(0)),
        Some("delete") => (Some(0), None),
        Some("replace") => (source, None),
        _ => (None, None),
    };
    Some(FileChange {
        path,
        kind: Some(FileChangeKind::Modify),
        lines_added: added,
        lines_removed: removed,
    })
}

/// Codex `fileChange` entries, `[{path, kind: {type, move_path?}, diff}]`: `diff` is the new
/// content for `add`, the old content for `delete`, and a unified diff for `update`.
fn patch_changes(changes: &Json) -> Vec<FileChange> {
    let Json::Array(changes, false) = changes else {
        // A cut list may be missing files.
        return Vec::new();
    };
    let mut files = Vec::new();
    for change in changes {
        let Some(path) = path_of(change, &["path"]) else {
            continue;
        };
        let (kind, moved) = match change.get("kind") {
            Some(Json::String(kind)) => (Some(kind.as_str()), false),
            Some(kind @ Json::Object(..)) => (
                kind.text(&["type"]),
                kind.text(&["move_path", "movePath"])
                    .is_some_and(|target| !target.is_empty() && target != path),
            ),
            _ => (None, false),
        };
        let diff = change.text(&["diff"]);
        let whole = !change.is_cut();
        let Some(file) = counted_change(path, kind, diff, whole) else {
            continue;
        };
        // An unchanged, unrenamed update changes nothing.
        if file.kind == Some(FileChangeKind::Modify)
            && file.lines_added == Some(0)
            && file.lines_removed == Some(0)
            && !moved
        {
            continue;
        }
        files.push(file);
    }
    files
}

/// Legacy Codex `applyPatchApproval` params: `fileChanges: {path: FileChange}`, a change being
/// `{"type": "add"|"delete", "content"}` or `{"type": "update", "unified_diff", "move_path"}`
/// (or the same externally tagged, `{"add": {"content"}}`). `files` is the server's full, sorted
/// path list.
fn codex_patch_changes(params: &Json, files: Option<&Value>) -> Vec<FileChange> {
    let entries = params.get("fileChanges");
    let listed: Option<Vec<String>> = files.and_then(Value::as_array).map(|files| {
        files
            .iter()
            .filter_map(Value::as_str)
            .filter(|path| !path.is_empty())
            .map(str::to_owned)
            .collect()
    });
    let paths = match (listed, entries) {
        (Some(paths), _) if !paths.is_empty() => paths,
        (_, Some(Json::Object(members, false))) => {
            members.iter().map(|(path, _)| path.clone()).collect()
        }
        _ => return Vec::new(),
    };
    paths
        .into_iter()
        .map(|path| {
            let entry = entries.and_then(|entries| entries.get(&path));
            let (kind, body, whole) = entry.map_or((None, None, false), legacy_change);
            counted_change(path.clone(), kind, body, whole).unwrap_or(FileChange {
                path,
                kind: None,
                lines_added: None,
                lines_removed: None,
            })
        })
        .collect()
}

/// A legacy change's kind, its content or diff, and whether it arrived whole.
fn legacy_change(change: &Json) -> (Option<&str>, Option<&str>, bool) {
    if let Some(kind) = change.text(&["type"]) {
        return (
            Some(kind),
            change.text(&["content", "unified_diff"]),
            !change.is_cut(),
        );
    }
    for kind in ["add", "delete", "update"] {
        if let Some(inner) = change.get(kind) {
            return (
                Some(kind),
                inner.text(&["content", "unified_diff"]),
                !inner.is_cut(),
            );
        }
    }
    (None, None, !change.is_cut())
}

/// A change of `kind` (`add`, `delete` or `update`) with its body; counts only when `whole`.
fn counted_change(
    path: String,
    kind: Option<&str>,
    body: Option<&str>,
    whole: bool,
) -> Option<FileChange> {
    let body = body.filter(|_| whole);
    let (kind, counts) = match kind {
        Some("add") => (
            FileChangeKind::Create,
            body.map(|body| (split_lines(body).len(), 0)),
        ),
        Some("delete") => (
            FileChangeKind::Delete,
            body.map(|body| (0, split_lines(body).len())),
        ),
        Some("update") => (FileChangeKind::Modify, body.map(unified_counts)),
        _ => return None,
    };
    Some(FileChange {
        path,
        kind: Some(kind),
        lines_added: counts.map(|(added, _)| clamp(added)),
        lines_removed: counts.map(|(_, removed)| clamp(removed)),
    })
}

/// Added and removed lines of a unified diff, ignoring `---`/`+++` file headers before the first
/// hunk.
fn unified_counts(diff: &str) -> (usize, usize) {
    let lines = split_lines(diff);
    let start = lines
        .iter()
        .position(|line| line.starts_with("@@"))
        .unwrap_or_else(|| {
            let headers = lines.first().is_some_and(|line| line.starts_with("--- "))
                && lines.get(1).is_some_and(|line| line.starts_with("+++ "));
            if headers { 2 } else { 0 }
        });
    let body = lines.get(start..).unwrap_or_default();
    let count = |prefix: char| body.iter().filter(|line| line.starts_with(prefix)).count();
    (count('+'), count('-'))
}

/// Lines of `text`; a trailing newline ends the last line rather than starting another.
fn split_lines(text: &str) -> Vec<&str> {
    if text.is_empty() {
        return Vec::new();
    }
    let mut lines: Vec<&str> = text.split('\n').collect();
    if lines.last() == Some(&"") {
        lines.pop();
    }
    lines
}

/// Added and removed lines when `old` becomes `new` (the web's `lineDiff`, counted).
fn pair_counts(old: &str, new: &str, budget: &mut Budget) -> (usize, usize) {
    let mut old_lines = split_lines(old);
    let mut new_lines = split_lines(new);
    // Only a final newline changed: an added or removed blank line.
    if old_lines == new_lines {
        if old.ends_with('\n') {
            old_lines.push("");
        } else {
            new_lines.push("");
        }
    }
    let prefix = old_lines
        .iter()
        .zip(&new_lines)
        .take_while(|(old, new)| old == new)
        .count();
    let suffix = old_lines
        .iter()
        .skip(prefix)
        .rev()
        .zip(new_lines.iter().skip(prefix).rev())
        .take_while(|(old, new)| old == new)
        .count();
    let old_middle = middle(&old_lines, prefix, suffix);
    let new_middle = middle(&new_lines, prefix, suffix);
    let cells = old_middle.len().saturating_mul(new_middle.len());
    if cells > budget.cells {
        return (new_middle.len(), old_middle.len());
    }
    budget.cells -= cells;
    let common = common_lines(&old_middle, &new_middle);
    (new_middle.len() - common, old_middle.len() - common)
}

/// `lines` without its first `prefix` and last `suffix` lines.
fn middle<'a>(lines: &[&'a str], prefix: usize, suffix: usize) -> Vec<&'a str> {
    lines
        .iter()
        .skip(prefix)
        .take(lines.len().saturating_sub(prefix + suffix))
        .copied()
        .collect()
}

/// Longest common subsequence length, one row at a time.
fn common_lines(old: &[&str], new: &[&str]) -> usize {
    let mut row = vec![0_usize; new.len()];
    for old_line in old {
        let (mut diagonal, mut left) = (0, 0);
        for (cell, new_line) in row.iter_mut().zip(new) {
            let above = *cell;
            *cell = if old_line == new_line {
                diagonal + 1
            } else {
                above.max(left)
            };
            diagonal = above;
            left = *cell;
        }
    }
    row.last().copied().unwrap_or(0)
}

fn clamp(count: usize) -> u32 {
    u32::try_from(count).unwrap_or(u32::MAX)
}

/// `content_preview` for display, as the web's `formatPreview`: JSON and `ToolName({...})` are
/// re-indented without reordering or dropping anything (so a cut preview stays verbatim), and
/// anything else is unchanged. `None` when blank.
pub(super) fn format_preview(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with('{') || trimmed.starts_with('[') {
        return Some(reindent(trimmed));
    }
    if let Some((name, body)) = trimmed.split_once('(')
        && is_tool_name(name)
        && (body.starts_with('{') || body.starts_with('['))
    {
        let (body, close) = body
            .strip_suffix(')')
            .map_or((body, ""), |body| (body, ")"));
        return Some(format!("{name}({}{close}", reindent(body)));
    }
    Some(raw.to_owned())
}

/// Line breaks and two-space indents around JSON structure, leaving strings untouched.
fn reindent(text: &str) -> String {
    const INDENT: &str = "  ";
    // Past this depth the indent stops growing: a `[[[[...` preview must not inflate quadratically.
    const MAX_INDENT_LEVELS: usize = 64;
    let mut out = String::with_capacity(text.len() * 2);
    let mut depth = 0_usize;
    let mut in_string = false;
    let mut escaped = false;
    let mut chars = text.chars().peekable();
    let newline = |out: &mut String, depth: usize| {
        out.push('\n');
        for _ in 0..depth.min(MAX_INDENT_LEVELS) {
            out.push_str(INDENT);
        }
    };
    while let Some(c) = chars.next() {
        if in_string {
            out.push(c);
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                in_string = false;
            }
            continue;
        }
        match c {
            '"' => {
                in_string = true;
                out.push(c);
            }
            '{' | '[' => {
                let closer = if c == '{' { '}' } else { ']' };
                if chars.peek() == Some(&closer) {
                    chars.next();
                    out.push(c);
                    out.push(closer);
                    continue;
                }
                depth += 1;
                out.push(c);
                newline(&mut out, depth);
                while chars.peek() == Some(&' ') {
                    chars.next();
                }
            }
            '}' | ']' => {
                depth = depth.saturating_sub(1);
                newline(&mut out, depth);
                out.push(c);
            }
            ',' => {
                out.push(',');
                newline(&mut out, depth);
                while chars.peek() == Some(&' ') {
                    chars.next();
                }
            }
            _ => out.push(c),
        }
    }
    out
}
