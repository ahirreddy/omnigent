//! A unified-diff model: computed from the before/after text the server keeps for a changed
//! file, or parsed from a patch (`gh pr diff` output).
//!
//! The diff is line based. Common leading and trailing lines are trimmed first, then the
//! middle is diffed with Myers' O(ND) algorithm. When the edit distance exceeds
//! [`DiffOptions::max_edit_cost`] the middle is shown as one removal followed by one addition
//! and the diff is marked [`FileDiff::approximate`]; when the middle has more than
//! [`DiffOptions::max_lines`] lines on either side, no hunks are produced and the diff is marked
//! [`FileDiff::too_large`]. Either way the viewer says so instead of hanging.
//!
//! A final line without a newline differs from the same text with one, as in `git diff`, and
//! carries [`DiffLine::missing_newline`]. Line text excludes the `\n` but keeps a `\r`.

use std::collections::HashMap;

use super::model::FileDiffContent;
use super::search::TextRange;

/// Limits and presentation for computed diffs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DiffOptions {
    /// Unchanged lines shown around each change.
    pub context_lines: u32,
    /// Above this many differing lines on either side, no hunks are computed.
    pub max_lines: u64,
    /// The largest edit distance computed exactly. Memory grows with its square.
    pub max_edit_cost: u64,
}

impl Default for DiffOptions {
    fn default() -> Self {
        Self {
            context_lines: 3,
            max_lines: 200_000,
            max_edit_cost: 1_000,
        }
    }
}

/// What a diff line is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DiffLineKind {
    /// Unchanged.
    Context,
    /// Only in the new text.
    Added,
    /// Only in the old text.
    Removed,
}

/// One line of a hunk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffLine {
    /// What it is.
    pub kind: DiffLineKind,
    /// 1-based line number in the old text, for context and removed lines.
    pub old_number: Option<u64>,
    /// 1-based line number in the new text, for context and added lines.
    pub new_number: Option<u64>,
    /// The text, without its `\n`.
    pub text: String,
    /// The line ends its side without a newline.
    pub missing_newline: bool,
}

/// One `@@` hunk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffHunk {
    /// First old line (the line before the hunk when `old_count` is 0).
    pub old_start: u64,
    /// Old lines covered.
    pub old_count: u64,
    /// First new line (the line before the hunk when `new_count` is 0).
    pub new_start: u64,
    /// New lines covered.
    pub new_count: u64,
    /// The text after the second `@@`, often the enclosing function.
    pub section: String,
    /// The lines.
    pub lines: Vec<DiffLine>,
}

impl DiffHunk {
    /// `@@ -old_start,old_count +new_start,new_count @@ section`, counts of 1 omitted.
    #[must_use]
    pub fn header(&self) -> String {
        let range = |start: u64, count: u64| {
            if count == 1 {
                start.to_string()
            } else {
                format!("{start},{count}")
            }
        };
        let mut header = format!(
            "@@ -{} +{} @@",
            range(self.old_start, self.old_count),
            range(self.new_start, self.new_count)
        );
        if !self.section.is_empty() {
            header.push(' ');
            header.push_str(&self.section);
        }
        header
    }
}

/// How the file changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FileChangeKind {
    /// A new file.
    Added,
    /// A removed file.
    Deleted,
    /// Changed in place.
    Modified,
    /// Moved, possibly with changes.
    Renamed,
    /// Copied, possibly with changes.
    Copied,
}

/// The diff of one file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileDiff {
    /// The old path; `None` for an added file.
    pub old_path: Option<String>,
    /// The new path; `None` for a deleted file.
    pub new_path: Option<String>,
    /// How it changed.
    pub change: FileChangeKind,
    /// The hunks, in order.
    pub hunks: Vec<DiffHunk>,
    /// The patch says the file is binary; there are no hunks.
    pub binary: bool,
    /// The edit budget ran out: the changed region is one removal and one addition.
    pub approximate: bool,
    /// The changed region is too large to diff; there are no hunks.
    pub too_large: bool,
}

/// Added and removed line counts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DiffStats {
    /// Added lines.
    pub added: u64,
    /// Removed lines.
    pub removed: u64,
}

/// One row of a side-by-side view.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SplitRow {
    /// The start of hunk `index`.
    Hunk {
        /// Index into [`FileDiff::hunks`].
        index: usize,
        /// [`DiffHunk::header`].
        header: String,
    },
    /// A line pair. A missing side is blank.
    Line {
        /// The old side.
        left: Option<SplitCell>,
        /// The new side.
        right: Option<SplitCell>,
    },
}

/// One side of a [`SplitRow::Line`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SplitCell {
    /// What the line is.
    pub kind: DiffLineKind,
    /// 1-based line number on its side.
    pub number: u64,
    /// The text.
    pub text: String,
    /// For a removed line paired with an added one: the bytes that differ between them
    /// (everything between their common prefix and suffix), in UTF-8 bytes of `text`.
    pub changed: Option<TextRange>,
}

impl FileDiff {
    /// The path to show: the new path, or the old one for a deletion.
    #[must_use]
    pub fn display_path(&self) -> &str {
        self.new_path
            .as_deref()
            .or(self.old_path.as_deref())
            .unwrap_or_default()
    }

    /// Added and removed lines across hunks.
    #[must_use]
    pub fn stats(&self) -> DiffStats {
        let mut stats = DiffStats::default();
        for line in self.hunks.iter().flat_map(|hunk| &hunk.lines) {
            match line.kind {
                DiffLineKind::Added => stats.added += 1,
                DiffLineKind::Removed => stats.removed += 1,
                DiffLineKind::Context => {}
            }
        }
        stats
    }

    /// Whether there is nothing to show: no hunks and not binary or too large.
    #[must_use]
    pub const fn is_identical(&self) -> bool {
        self.hunks.is_empty() && !self.binary && !self.too_large
    }

    /// The diff as `git diff` text, for copying. [`parse_unified`] reads it back.
    #[must_use]
    pub fn to_unified(&self) -> String {
        let old = self.old_path.as_deref().unwrap_or("/dev/null");
        let new = self.new_path.as_deref().unwrap_or("/dev/null");
        let a = self
            .old_path
            .as_deref()
            .or(self.new_path.as_deref())
            .unwrap_or_default();
        let b = self
            .new_path
            .as_deref()
            .or(self.old_path.as_deref())
            .unwrap_or_default();
        let mut out = format!("diff --git a/{a} b/{b}\n");
        match self.change {
            FileChangeKind::Added => out.push_str("new file mode 100644\n"),
            FileChangeKind::Deleted => out.push_str("deleted file mode 100644\n"),
            FileChangeKind::Renamed => {
                for piece in ["rename from ", a, "\nrename to ", b, "\n"] {
                    out.push_str(piece);
                }
            }
            FileChangeKind::Copied => {
                for piece in ["copy from ", a, "\ncopy to ", b, "\n"] {
                    out.push_str(piece);
                }
            }
            FileChangeKind::Modified => {}
        }
        if self.binary {
            let (old, new) = (prefixed("a/", old), prefixed("b/", new));
            for piece in ["Binary files ", &old, " and ", &new, " differ\n"] {
                out.push_str(piece);
            }
            return out;
        }
        if self.hunks.is_empty() {
            return out;
        }
        let (old, new) = (prefixed("a/", old), prefixed("b/", new));
        for piece in ["--- ", &old, "\n+++ ", &new, "\n"] {
            out.push_str(piece);
        }
        for hunk in &self.hunks {
            out.push_str(&hunk.header());
            out.push('\n');
            for line in &hunk.lines {
                out.push(match line.kind {
                    DiffLineKind::Context => ' ',
                    DiffLineKind::Added => '+',
                    DiffLineKind::Removed => '-',
                });
                out.push_str(&line.text);
                out.push('\n');
                if line.missing_newline {
                    out.push_str("\\ No newline at end of file\n");
                }
            }
        }
        out
    }

    /// Rows for a side-by-side view: removals and the additions that follow them are paired
    /// row by row, with the differing span of each pair marked.
    #[must_use]
    pub fn side_by_side(&self) -> Vec<SplitRow> {
        let mut rows = Vec::new();
        for (index, hunk) in self.hunks.iter().enumerate() {
            rows.push(SplitRow::Hunk {
                index,
                header: hunk.header(),
            });
            let mut removed: Vec<&DiffLine> = Vec::new();
            let mut added: Vec<&DiffLine> = Vec::new();
            for line in &hunk.lines {
                match line.kind {
                    DiffLineKind::Removed if added.is_empty() => removed.push(line),
                    DiffLineKind::Removed => {
                        flush(&mut rows, &mut removed, &mut added);
                        removed.push(line);
                    }
                    DiffLineKind::Added => added.push(line),
                    DiffLineKind::Context => {
                        flush(&mut rows, &mut removed, &mut added);
                        rows.push(SplitRow::Line {
                            left: Some(cell(line, line.old_number, None)),
                            right: Some(cell(line, line.new_number, None)),
                        });
                    }
                }
            }
            flush(&mut rows, &mut removed, &mut added);
        }
        rows
    }
}

fn prefixed(prefix: &str, path: &str) -> String {
    if path == "/dev/null" {
        path.to_owned()
    } else {
        format!("{prefix}{path}")
    }
}

fn cell(line: &DiffLine, number: Option<u64>, changed: Option<TextRange>) -> SplitCell {
    SplitCell {
        kind: line.kind,
        number: number.unwrap_or_default(),
        text: line.text.clone(),
        changed,
    }
}

fn flush<'a>(
    rows: &mut Vec<SplitRow>,
    removed: &mut Vec<&'a DiffLine>,
    added: &mut Vec<&'a DiffLine>,
) {
    let count = removed.len().max(added.len());
    for index in 0..count {
        let left = removed.get(index).copied();
        let right = added.get(index).copied();
        let (left_span, right_span) = match (left, right) {
            (Some(old), Some(new)) => changed_spans(&old.text, &new.text),
            _ => (None, None),
        };
        rows.push(SplitRow::Line {
            left: left.map(|line| cell(line, line.old_number, left_span)),
            right: right.map(|line| cell(line, line.new_number, right_span)),
        });
    }
    removed.clear();
    added.clear();
}

/// The spans of `old` and `new` between their common prefix and suffix, on char boundaries.
fn changed_spans(old: &str, new: &str) -> (Option<TextRange>, Option<TextRange>) {
    let prefix: usize = old
        .chars()
        .zip(new.chars())
        .take_while(|(a, b)| a == b)
        .map(|(a, _)| a.len_utf8())
        .sum();
    let old_rest = old.get(prefix..).unwrap_or_default();
    let new_rest = new.get(prefix..).unwrap_or_default();
    let suffix: usize = old_rest
        .chars()
        .rev()
        .zip(new_rest.chars().rev())
        .take_while(|(a, b)| a == b)
        .map(|(a, _)| a.len_utf8())
        .sum();
    let span = |text: &str| {
        let start = u64::try_from(prefix).ok()?;
        let end = u64::try_from(text.len().saturating_sub(suffix).max(prefix)).ok()?;
        Some(TextRange { start, end })
    };
    (span(old), span(new))
}

// Computing.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Op {
    Equal,
    Delete,
    Insert,
}

/// Lines of `text`, each with whether it is the final line and lacks a newline.
fn split_lines(text: &str) -> Vec<(&str, bool)> {
    if text.is_empty() {
        return Vec::new();
    }
    let ends_with_newline = text.ends_with('\n');
    let body = text.strip_suffix('\n').unwrap_or(text);
    let mut lines: Vec<(&str, bool)> = body.split('\n').map(|line| (line, false)).collect();
    if !ends_with_newline && let Some(last) = lines.last_mut() {
        last.1 = true;
    }
    lines
}

/// The diff of two texts. `None` means the side does not exist (an added or deleted file).
#[must_use]
pub fn diff_texts(
    old_path: Option<&str>,
    new_path: Option<&str>,
    before: Option<&str>,
    after: Option<&str>,
    options: &DiffOptions,
) -> FileDiff {
    let change = match (before, after, old_path, new_path) {
        (None, Some(_), ..) => FileChangeKind::Added,
        (_, None, ..) => FileChangeKind::Deleted,
        (Some(_), Some(_), Some(old), Some(new)) if old != new => FileChangeKind::Renamed,
        _ => FileChangeKind::Modified,
    };
    let mut diff = FileDiff {
        old_path: before.and(old_path).map(str::to_owned),
        new_path: after.and(new_path).map(str::to_owned),
        change,
        hunks: Vec::new(),
        binary: false,
        approximate: false,
        too_large: false,
    };
    if before.is_none() && after.is_none() {
        diff.old_path = old_path.map(str::to_owned);
        return diff;
    }
    let old = split_lines(before.unwrap_or_default());
    let new = split_lines(after.unwrap_or_default());
    let Some((ops, approximate)) = edit_script(&old, &new, options) else {
        diff.too_large = true;
        return diff;
    };
    diff.approximate = approximate;
    diff.hunks = hunks(&ops, &old, &new, options.context_lines);
    diff
}

impl FileDiffContent {
    /// The diff of the server's before and after text.
    #[must_use]
    pub fn diff(&self, options: &DiffOptions) -> FileDiff {
        let path = self.path.as_str();
        diff_texts(
            Some(path),
            Some(path),
            self.before.as_deref(),
            self.after.as_deref(),
            options,
        )
    }
}

/// The full edit script, or `None` when the middle is over `max_lines`.
fn edit_script(
    old: &[(&str, bool)],
    new: &[(&str, bool)],
    options: &DiffOptions,
) -> Option<(Vec<Op>, bool)> {
    let prefix = old.iter().zip(new).take_while(|(a, b)| a == b).count();
    let old_rest = old.get(prefix..).unwrap_or_default();
    let new_rest = new.get(prefix..).unwrap_or_default();
    let suffix = old_rest
        .iter()
        .rev()
        .zip(new_rest.iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    let old_middle = old_rest.get(..old_rest.len() - suffix).unwrap_or_default();
    let new_middle = new_rest.get(..new_rest.len() - suffix).unwrap_or_default();
    let limit = usize::try_from(options.max_lines).unwrap_or(usize::MAX);
    if old_middle.len() > limit || new_middle.len() > limit {
        return None;
    }
    let (a, b) = intern(old_middle, new_middle);
    let budget = usize::try_from(options.max_edit_cost).unwrap_or(usize::MAX);
    let (middle, approximate) = myers(&a, &b, budget).map_or_else(
        || {
            let mut ops = vec![Op::Delete; a.len()];
            ops.extend(std::iter::repeat_n(Op::Insert, b.len()));
            (ops, true)
        },
        |ops| (ops, false),
    );
    let mut ops = vec![Op::Equal; prefix];
    ops.extend(middle);
    ops.extend(std::iter::repeat_n(Op::Equal, suffix));
    Some((ops, approximate))
}

fn intern<'a>(old: &[(&'a str, bool)], new: &[(&'a str, bool)]) -> (Vec<u32>, Vec<u32>) {
    let mut ids: HashMap<(&'a str, bool), u32> = HashMap::new();
    let mut ids_of = |lines: &[(&'a str, bool)]| -> Vec<u32> {
        lines
            .iter()
            .map(|line| {
                let next = u32::try_from(ids.len()).unwrap_or(u32::MAX);
                *ids.entry(*line).or_insert(next)
            })
            .collect()
    };
    let a = ids_of(old);
    let b = ids_of(new);
    (a, b)
}

/// The stored `V` row of one Myers step: `x` for diagonals `-d-1..=d+1`.
struct Row {
    d: i64,
    xs: Vec<i64>,
}

impl Row {
    fn x(&self, k: i64) -> i64 {
        usize::try_from(k + self.d + 1)
            .ok()
            .and_then(|index| self.xs.get(index))
            .copied()
            .unwrap_or(0)
    }
}

fn line(lines: &[u32], index: i64) -> Option<u32> {
    usize::try_from(index)
        .ok()
        .and_then(|index| lines.get(index))
        .copied()
}

#[allow(
    clippy::many_single_char_names,
    reason = "the notation of Myers' paper"
)]
/// Myers' greedy shortest edit script, or `None` past `budget` edits.
fn myers(a: &[u32], b: &[u32], budget: usize) -> Option<Vec<Op>> {
    let n = i64::try_from(a.len()).ok()?;
    let m = i64::try_from(b.len()).ok()?;
    let max_d = i64::try_from(a.len().saturating_add(b.len()).min(budget)).ok()?;
    let mut trace: Vec<Row> = Vec::new();
    let mut previous = Row {
        d: -1,
        xs: vec![0; 1],
    };
    for d in 0..=max_d {
        let mut row = Row {
            d,
            xs: vec![0; usize::try_from(2 * d + 3).ok()?],
        };
        for k in (-d..=d).step_by(2) {
            let down = k == -d || (k != d && previous.x(k - 1) < previous.x(k + 1));
            let mut x = if down {
                previous.x(k + 1)
            } else {
                previous.x(k - 1) + 1
            };
            let mut y = x - k;
            while x < n && y < m && line(a, x) == line(b, y) {
                x += 1;
                y += 1;
            }
            *row.xs.get_mut(usize::try_from(k + d + 1).ok()?)? = x;
            if x >= n && y >= m {
                trace.push(previous);
                return Some(backtrack(&trace, n, m));
            }
        }
        trace.push(std::mem::replace(&mut previous, row));
    }
    None
}

#[allow(
    clippy::many_single_char_names,
    reason = "the notation of Myers' paper"
)]
/// Walks the stored rows back from `(n, m)`. `trace[d]` is the row before step `d`.
fn backtrack(trace: &[Row], n: i64, m: i64) -> Vec<Op> {
    let mut ops = Vec::new();
    let (mut x, mut y) = (n, m);
    for (d, previous) in trace.iter().enumerate().skip(1).rev() {
        let d = i64::try_from(d).unwrap_or(i64::MAX);
        let k = x - y;
        let down = k == -d || (k != d && previous.x(k - 1) < previous.x(k + 1));
        let previous_k = if down { k + 1 } else { k - 1 };
        let previous_x = previous.x(previous_k);
        let previous_y = previous_x - previous_k;
        while x > previous_x && y > previous_y {
            ops.push(Op::Equal);
            x -= 1;
            y -= 1;
        }
        ops.push(if down { Op::Insert } else { Op::Delete });
        x = previous_x;
        y = previous_y;
    }
    while x > 0 && y > 0 {
        ops.push(Op::Equal);
        x -= 1;
        y -= 1;
    }
    ops.reverse();
    ops
}

/// One op with its line indexes.
struct Step {
    op: Op,
    old: usize,
    new: usize,
}

fn steps(ops: &[Op]) -> Vec<Step> {
    let (mut old, mut new) = (0, 0);
    ops.iter()
        .map(|&op| {
            let step = Step { op, old, new };
            match op {
                Op::Equal => {
                    old += 1;
                    new += 1;
                }
                Op::Delete => old += 1,
                Op::Insert => new += 1,
            }
            step
        })
        .collect()
}

fn hunks(ops: &[Op], old: &[(&str, bool)], new: &[(&str, bool)], context: u32) -> Vec<DiffHunk> {
    let steps = steps(ops);
    let context = usize::try_from(context).unwrap_or(usize::MAX);
    let changes: Vec<usize> = steps
        .iter()
        .enumerate()
        .filter(|(_, step)| step.op != Op::Equal)
        .map(|(index, _)| index)
        .collect();
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    for &index in &changes {
        let start = index.saturating_sub(context);
        let end = index
            .saturating_add(context)
            .saturating_add(1)
            .min(steps.len());
        match ranges.last_mut() {
            Some(range) if start <= range.1 => range.1 = end,
            _ => ranges.push((start, end)),
        }
    }
    ranges
        .into_iter()
        .map(|(start, end)| hunk(steps.get(start..end).unwrap_or_default(), old, new))
        .collect()
}

fn number(index: usize) -> u64 {
    u64::try_from(index).unwrap_or(u64::MAX).saturating_add(1)
}

fn hunk(steps: &[Step], old: &[(&str, bool)], new: &[(&str, bool)]) -> DiffHunk {
    let first = steps.first();
    let old_position = first.map_or(0, |step| step.old);
    let new_position = first.map_or(0, |step| step.new);
    let mut lines = Vec::with_capacity(steps.len());
    for step in steps {
        let (kind, source, old_number, new_number) = match step.op {
            Op::Equal => (
                DiffLineKind::Context,
                new.get(step.new),
                Some(number(step.old)),
                Some(number(step.new)),
            ),
            Op::Delete => (
                DiffLineKind::Removed,
                old.get(step.old),
                Some(number(step.old)),
                None,
            ),
            Op::Insert => (
                DiffLineKind::Added,
                new.get(step.new),
                None,
                Some(number(step.new)),
            ),
        };
        let (text, missing_newline) = source.copied().unwrap_or_default();
        lines.push(DiffLine {
            kind,
            old_number,
            new_number,
            text: text.to_owned(),
            missing_newline,
        });
    }
    let count = |kind: DiffLineKind| {
        u64::try_from(
            lines
                .iter()
                .filter(|line| line.kind == DiffLineKind::Context || line.kind == kind)
                .count(),
        )
        .unwrap_or(u64::MAX)
    };
    let old_count = count(DiffLineKind::Removed);
    let new_count = count(DiffLineKind::Added);
    let start = |position: usize, count: u64| {
        let position = u64::try_from(position).unwrap_or(u64::MAX);
        if count == 0 { position } else { position + 1 }
    };
    DiffHunk {
        old_start: start(old_position, old_count),
        old_count,
        new_start: start(new_position, new_count),
        new_count,
        section: String::new(),
        lines,
    }
}

// Parsing.

/// Why a patch could not be read.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("The diff could not be read (line {line}): {message}")]
pub struct DiffParseError {
    /// The 1-based patch line.
    pub line: usize,
    /// What was wrong.
    pub message: String,
}

/// Parses `git diff` / `gh pr diff` output, or a plain unified diff, into one [`FileDiff`] per
/// file. Text before the first file header (mail headers, commit messages) is ignored.
///
/// # Errors
///
/// A malformed hunk header, a hunk whose lines do not match its counts, or a line that is
/// neither context, addition, removal nor a no-newline marker inside a hunk.
pub fn parse_unified(patch: &str) -> Result<Vec<FileDiff>, DiffParseError> {
    let mut parser = Parser::default();
    for (index, raw) in patch.split_terminator('\n').enumerate() {
        parser.line(index + 1, raw)?;
    }
    parser.finish(patch.split_terminator('\n').count())
}

#[derive(Default)]
struct Parser {
    files: Vec<FileDiff>,
    current: Option<PendingFile>,
}

#[derive(Default)]
#[allow(
    clippy::option_option,
    reason = "`None`: no `---`/`+++` line yet; `Some(None)`: the side is `/dev/null`"
)]
struct PendingFile {
    diff_git: Option<(String, String)>,
    old_path: Option<Option<String>>,
    new_path: Option<Option<String>>,
    kind: Option<FileChangeKind>,
    rename_from: Option<String>,
    rename_to: Option<String>,
    binary: bool,
    in_binary_patch: bool,
    hunks: Vec<DiffHunk>,
    open: Option<OpenHunk>,
}

struct OpenHunk {
    hunk: DiffHunk,
    old_left: u64,
    new_left: u64,
    old_next: u64,
    new_next: u64,
}

fn parse_error(line: usize, message: impl Into<String>) -> DiffParseError {
    DiffParseError {
        line,
        message: message.into(),
    }
}

impl Parser {
    fn line(&mut self, number: usize, raw: &str) -> Result<(), DiffParseError> {
        if let Some(file) = self.current.as_mut()
            && let Some(open) = file.open.as_mut()
        {
            if open.old_left > 0 || open.new_left > 0 {
                return open.body_line(number, raw);
            }
            if let Some(marker) = raw.strip_prefix('\\') {
                return open.no_newline(number, marker);
            }
            if let Some(done) = file.open.take() {
                file.hunks.push(done.hunk);
            }
        }
        if let Some(rest) = raw.strip_prefix("diff --git ") {
            self.start_file();
            if let Some(file) = self.current.as_mut() {
                file.diff_git = split_git_paths(rest);
            }
            return Ok(());
        }
        if raw.starts_with("--- ")
            && self
                .current
                .as_ref()
                .is_none_or(|file| file.old_path.is_some() || !file.hunks.is_empty())
        {
            self.start_file();
        }
        let Some(file) = self.current.as_mut() else {
            return Ok(());
        };
        file.header_line(number, raw)
    }

    fn start_file(&mut self) {
        if let Some(file) = self.current.take() {
            self.files.push(file.finish());
        }
        self.current = Some(PendingFile::default());
    }

    fn finish(mut self, lines: usize) -> Result<Vec<FileDiff>, DiffParseError> {
        if let Some(file) = self.current.as_ref()
            && let Some(open) = file.open.as_ref()
            && (open.old_left > 0 || open.new_left > 0)
        {
            return Err(parse_error(lines, "the patch ends inside a hunk"));
        }
        if let Some(file) = self.current.take() {
            self.files.push(file.finish());
        }
        Ok(self.files)
    }
}

impl PendingFile {
    fn header_line(&mut self, number: usize, raw: &str) -> Result<(), DiffParseError> {
        if self.in_binary_patch {
            return Ok(());
        }
        if let Some(path) = raw.strip_prefix("--- ") {
            self.old_path = Some(patch_path(path, "a/"));
        } else if let Some(path) = raw.strip_prefix("+++ ") {
            self.new_path = Some(patch_path(path, "b/"));
        } else if raw.starts_with("@@") {
            self.open = Some(OpenHunk::parse(number, raw)?);
        } else if raw.starts_with("new file mode") {
            self.kind = Some(FileChangeKind::Added);
        } else if raw.starts_with("deleted file mode") {
            self.kind = Some(FileChangeKind::Deleted);
        } else if let Some(path) = raw.strip_prefix("rename from ") {
            self.kind = Some(FileChangeKind::Renamed);
            self.rename_from = Some(unquote(path));
        } else if let Some(path) = raw.strip_prefix("rename to ") {
            self.rename_to = Some(unquote(path));
        } else if let Some(path) = raw.strip_prefix("copy from ") {
            self.kind = Some(FileChangeKind::Copied);
            self.rename_from = Some(unquote(path));
        } else if let Some(path) = raw.strip_prefix("copy to ") {
            self.rename_to = Some(unquote(path));
        } else if raw.starts_with("Binary files ") {
            self.binary = true;
        } else if raw.starts_with("GIT binary patch") {
            self.binary = true;
            self.in_binary_patch = true;
        } else if !self.hunks.is_empty() && raw.starts_with(['+', '-', ' ']) {
            return Err(parse_error(
                number,
                "a hunk line after the hunk's counted lines",
            ));
        }
        // Other extended headers (`index`, `old mode`, `similarity index`, ...) carry nothing
        // the viewer shows.
        Ok(())
    }

    fn finish(mut self) -> FileDiff {
        if let Some(open) = self.open.take() {
            self.hunks.push(open.hunk);
        }
        let (git_old, git_new) = self
            .diff_git
            .map_or((None, None), |(old, new)| (Some(old), Some(new)));
        let old_path = match self.old_path {
            Some(path) => path,
            None => self.rename_from.clone().or(git_old),
        };
        let new_path = match self.new_path {
            Some(path) => path,
            None => self.rename_to.clone().or(git_new),
        };
        let change = self.kind.unwrap_or(match (&old_path, &new_path) {
            (None, Some(_)) => FileChangeKind::Added,
            (Some(_), None) => FileChangeKind::Deleted,
            (Some(old), Some(new)) if old != new => FileChangeKind::Renamed,
            _ => FileChangeKind::Modified,
        });
        let (old_path, new_path) = match change {
            FileChangeKind::Added => (None, new_path.or(old_path)),
            FileChangeKind::Deleted => (old_path.or(new_path), None),
            _ => (old_path, new_path),
        };
        FileDiff {
            old_path,
            new_path,
            change,
            hunks: self.hunks,
            binary: self.binary,
            approximate: false,
            too_large: false,
        }
    }
}

impl OpenHunk {
    fn parse(number: usize, raw: &str) -> Result<Self, DiffParseError> {
        let malformed = || parse_error(number, format!("malformed hunk header {raw:?}"));
        let rest = raw.strip_prefix("@@ -").ok_or_else(malformed)?;
        let (ranges, section) = rest.split_once(" @@").ok_or_else(malformed)?;
        let (old, new) = ranges.split_once(" +").ok_or_else(malformed)?;
        let range = |text: &str| -> Option<(u64, u64)> {
            match text.split_once(',') {
                Some((start, count)) => Some((start.parse().ok()?, count.parse().ok()?)),
                None => Some((text.parse().ok()?, 1)),
            }
        };
        let (old_start, old_count) = range(old).ok_or_else(malformed)?;
        let (new_start, new_count) = range(new).ok_or_else(malformed)?;
        // Line numbers past the integer limit name no real file.
        let next = |start: u64, count: u64| {
            let after_last = start.checked_add(count.max(1)).ok_or_else(malformed)?;
            Ok(if count == 0 { after_last } else { start })
        };
        Ok(Self {
            hunk: DiffHunk {
                old_start,
                old_count,
                new_start,
                new_count,
                section: section.trim_start().to_owned(),
                lines: Vec::new(),
            },
            old_left: old_count,
            new_left: new_count,
            old_next: next(old_start, old_count)?,
            new_next: next(new_start, new_count)?,
        })
    }

    fn body_line(&mut self, number: usize, raw: &str) -> Result<(), DiffParseError> {
        if let Some(marker) = raw.strip_prefix('\\') {
            return self.no_newline(number, marker);
        }
        let (kind, text) = match raw.chars().next() {
            Some(' ') => (DiffLineKind::Context, raw.get(1..).unwrap_or_default()),
            // Some tools strip the space from an empty context line.
            None => (DiffLineKind::Context, ""),
            Some('+') => (DiffLineKind::Added, raw.get(1..).unwrap_or_default()),
            Some('-') => (DiffLineKind::Removed, raw.get(1..).unwrap_or_default()),
            Some(_) => {
                return Err(parse_error(
                    number,
                    format!("{raw:?} is not a hunk line; the hunk header promised more lines"),
                ));
            }
        };
        let uses_old = kind != DiffLineKind::Added;
        let uses_new = kind != DiffLineKind::Removed;
        if (uses_old && self.old_left == 0) || (uses_new && self.new_left == 0) {
            return Err(parse_error(
                number,
                "the hunk has more lines than its header says",
            ));
        }
        let mut line = DiffLine {
            kind,
            old_number: None,
            new_number: None,
            text: text.to_owned(),
            missing_newline: false,
        };
        if uses_old {
            line.old_number = Some(self.old_next);
            self.old_next += 1;
            self.old_left -= 1;
        }
        if uses_new {
            line.new_number = Some(self.new_next);
            self.new_next += 1;
            self.new_left -= 1;
        }
        self.hunk.lines.push(line);
        Ok(())
    }

    fn no_newline(&mut self, number: usize, marker: &str) -> Result<(), DiffParseError> {
        let last = self
            .hunk
            .lines
            .last_mut()
            .ok_or_else(|| parse_error(number, format!("\\{marker} before any hunk line")))?;
        last.missing_newline = true;
        Ok(())
    }
}

/// A `---`/`+++` path: `/dev/null` is none; the `a/`/`b/` prefix and a trailing tab-separated
/// timestamp are dropped.
fn patch_path(raw: &str, prefix: &str) -> Option<String> {
    let raw = if raw.starts_with('"') {
        raw
    } else {
        raw.split_once('\t').map_or(raw, |(path, _)| path)
    };
    let path = unquote(raw.trim_end());
    if path == "/dev/null" {
        return None;
    }
    Some(
        path.strip_prefix(prefix)
            .map_or_else(|| path.clone(), str::to_owned),
    )
}

/// The two paths of `diff --git a/X b/Y`.
fn split_git_paths(rest: &str) -> Option<(String, String)> {
    if rest.starts_with('"') {
        let (old, new) = split_quoted(rest)?;
        return Some((strip(&old, "a/"), strip(&new, "b/")));
    }
    let rest = rest.strip_prefix("a/")?;
    // With equal names the split is unambiguous even when they contain " b/".
    let length = rest.len().checked_sub(3)? / 2;
    if let (Some(old), Some(new)) = (rest.get(..length), rest.get(length..))
        && let Some(new) = new.strip_prefix(" b/")
        && old == new
    {
        return Some((old.to_owned(), new.to_owned()));
    }
    let (old, new) = rest.split_once(" b/")?;
    Some((old.to_owned(), new.to_owned()))
}

fn strip(path: &str, prefix: &str) -> String {
    path.strip_prefix(prefix).unwrap_or(path).to_owned()
}

fn split_quoted(rest: &str) -> Option<(String, String)> {
    let mut escaped = false;
    for (index, character) in rest.char_indices().skip(1) {
        match character {
            '\\' if !escaped => escaped = true,
            '"' if !escaped => {
                let (first, second) = rest.split_at(index + 1);
                return Some((unquote(first), unquote(second.trim_start())));
            }
            _ => escaped = false,
        }
    }
    None
}

/// Git's C-style quoting: `"a\tb\303\251"`. An unquoted path is returned as is.
fn unquote(raw: &str) -> String {
    let Some(inner) = raw
        .strip_prefix('"')
        .and_then(|rest| rest.strip_suffix('"'))
    else {
        return raw.to_owned();
    };
    let mut bytes = Vec::with_capacity(inner.len());
    let mut chars = inner.chars().peekable();
    while let Some(character) = chars.next() {
        if character != '\\' {
            let mut buffer = [0; 4];
            bytes.extend_from_slice(character.encode_utf8(&mut buffer).as_bytes());
            continue;
        }
        match chars.next() {
            Some('n') => bytes.push(b'\n'),
            Some('t') => bytes.push(b'\t'),
            Some('"') => bytes.push(b'"'),
            Some(digit @ '0'..='7') => {
                let mut value = digit.to_digit(8).unwrap_or_default();
                for _ in 0..2 {
                    if let Some(next) = chars.peek().and_then(|c| c.to_digit(8)) {
                        value = value * 8 + next;
                        chars.next();
                    }
                }
                bytes.push(u8::try_from(value).unwrap_or(b'?'));
            }
            Some('\\') | None => bytes.push(b'\\'),
            Some(other) => {
                bytes.push(b'\\');
                let mut buffer = [0; 4];
                bytes.extend_from_slice(other.encode_utf8(&mut buffer).as_bytes());
            }
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

#[cfg(test)]
#[path = "diff_tests.rs"]
mod tests;
