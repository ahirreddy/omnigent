//! The first prose line of a thought, which a settled reasoning row previews in its header
//! (`reasoningPreview` in `web/src/components/blocks/ReasoningView.tsx`).

/// The first line of `text` worth previewing, as plain text: fences and thematic breaks are
/// skipped, and leading heading, quote and list markers, `**strong**` and `` `code` `` marks
/// are removed. Empty when no line has prose, for example `"**Planning** the fix"` gives
/// `"Planning the fix"`.
#[must_use]
pub(super) fn reasoning_preview(text: &str) -> String {
    for raw in text.split('\n') {
        let stripped = strip_ansi(raw);
        let line = stripped.trim();
        if line.is_empty() || is_markup_only(line) {
            continue;
        }
        let preview = unwrap_inline_code(&unwrap_strong(without_block_markers(line)));
        let preview = preview.trim();
        if !preview.is_empty() {
            return preview.to_owned();
        }
    }
    String::new()
}

/// A code fence, or a thematic break such as `---` or `* * *`.
fn is_markup_only(line: &str) -> bool {
    if line.starts_with("```") || line.starts_with("~~~") {
        return true;
    }
    let is_mark = |character: char| matches!(character, '-' | '*' | '_');
    line.starts_with(is_mark)
        && line
            .chars()
            .all(|character| is_mark(character) || character.is_whitespace())
        && line.chars().filter(|character| is_mark(*character)).count() >= 3
}

/// `line` without its leading `#`, `>`, `-`, `*`, `+` and `1.` markers.
fn without_block_markers(mut line: &str) -> &str {
    loop {
        let rest = heading_marker(line)
            .or_else(|| line.strip_prefix('>').map(str::trim_start))
            .or_else(|| {
                line.strip_prefix(['-', '*', '+'])
                    .and_then(spaced_after_marker)
            })
            .or_else(|| {
                let digits = line.trim_start_matches(|c: char| c.is_ascii_digit());
                (digits.len() < line.len())
                    .then(|| digits.strip_prefix(['.', ')']))
                    .flatten()
                    .and_then(spaced_after_marker)
            });
        match rest {
            Some(rest) => line = rest,
            None => return line,
        }
    }
}

/// One to six `#`, then whitespace.
fn heading_marker(line: &str) -> Option<&str> {
    let rest = line.trim_start_matches('#');
    let hashes = line.len() - rest.len();
    (1..=6)
        .contains(&hashes)
        .then_some(rest)
        .and_then(spaced_after_marker)
}

/// `rest` after the whitespace a marker needs, when it has some.
fn spaced_after_marker(rest: &str) -> Option<&str> {
    let trimmed = rest.trim_start();
    (trimmed.len() < rest.len()).then_some(trimmed)
}

/// `**strong**` spans as their text (`__` is left alone: it would mangle `__init__.py`).
fn unwrap_strong(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut rest = line;
    while let Some(at) = rest.find("**") {
        let (before, marked) = rest.split_at_checked(at).unwrap_or((rest, ""));
        out.push_str(before);
        let inner_start = marked.get(2..).unwrap_or_default();
        // The span holds at least one character before its closing `**`.
        let first = inner_start.chars().next().map_or(0, char::len_utf8);
        let close = inner_start
            .get(first..)
            .and_then(|after| after.find("**"))
            .filter(|_| first > 0);
        if let Some((inner, after)) =
            close.and_then(|end| inner_start.split_at_checked(first + end))
        {
            out.push_str(inner);
            rest = after.get(2..).unwrap_or_default();
        } else {
            out.push('*');
            rest = marked.get(1..).unwrap_or_default();
        }
    }
    out.push_str(rest);
    out
}

/// `` `code` `` spans as their text.
fn unwrap_inline_code(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut rest = line;
    while let Some(at) = rest.find('`') {
        let (before, marked) = rest.split_at_checked(at).unwrap_or((rest, ""));
        out.push_str(before);
        let inner_start = marked.get(1..).unwrap_or_default();
        if let Some(end) = inner_start.find('`').filter(|end| *end > 0) {
            out.push_str(inner_start.get(..end).unwrap_or_default());
            rest = inner_start.get(end + 1..).unwrap_or_default();
        } else {
            out.push('`');
            rest = inner_start;
        }
    }
    out.push_str(rest);
    out
}

/// `text` without terminal control sequences (`stripAnsi` in `web/src/lib/ansi.ts`): CSI and OSC
/// in 7- and 8-bit forms, single-character escapes and stray C1 controls.
#[must_use]
pub(super) fn strip_ansi(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut at = 0;
    while let Some(&character) = chars.get(at) {
        let rest = chars.get(at + 1..).unwrap_or_default();
        let skipped = match character {
            '\u{1b}' => 1 + escape_len(rest),
            '\u{9b}' => 1 + csi_len(rest).unwrap_or(0),
            '\u{9d}' => 1 + osc_len(rest, &['\u{7}', '\u{9c}'], &['\u{7}', '\u{9c}', '\u{1b}']),
            '\u{80}'..='\u{9f}' => 1,
            _ => {
                out.push(character);
                1
            }
        };
        at += skipped;
    }
    out
}

/// The characters after `ESC` that belong to its sequence.
fn escape_len(rest: &[char]) -> usize {
    match rest.first().copied() {
        Some('[') => csi_len(rest.get(1..).unwrap_or_default()).map_or(0, |len| len + 1),
        Some(']') => {
            let body = rest.get(1..).unwrap_or_default();
            let len = osc_len(body, &['\u{7}'], &['\u{7}', '\u{1b}']);
            // A string terminator (`ESC \\`) ends it too, when no bell did.
            let terminated = len > 0 && body.get(len - 1) == Some(&'\u{7}');
            let string_terminator =
                !terminated && body.get(len..len + 2) == Some(&['\u{1b}', '\\'][..]);
            1 + len + if string_terminator { 2 } else { 0 }
        }
        Some('@'..='Z' | '\\'..='_') => 1,
        _ => 0,
    }
}

/// A control sequence's parameters, intermediates and final byte; `None` without a final byte.
fn csi_len(rest: &[char]) -> Option<usize> {
    let parameters = rest.iter().take_while(|c| ('0'..='?').contains(*c)).count();
    let intermediates = rest
        .get(parameters..)?
        .iter()
        .take_while(|c| (' '..='/').contains(*c))
        .count();
    let end = parameters + intermediates;
    rest.get(end)
        .filter(|c| ('@'..='~').contains(*c))
        .map(|_| end + 1)
}

/// An operating-system command's text up to a line break or `stops`, plus a terminator in
/// `terminators` right after it.
fn osc_len(rest: &[char], terminators: &[char], stops: &[char]) -> usize {
    let body = rest
        .iter()
        .take_while(|c| **c != '\n' && !stops.contains(c))
        .count();
    let terminated = rest.get(body).is_some_and(|c| terminators.contains(c));
    body + usize::from(terminated)
}

#[cfg(test)]
#[path = "reasoning_preview_tests.rs"]
mod tests;
