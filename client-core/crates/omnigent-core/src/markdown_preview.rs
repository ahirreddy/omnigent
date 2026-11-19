//! Markdown as plain text, for a preview that shows only its start, such as a workflow step's
//! line in the Tasks tab (`web/src/lib/markdownPreviewText.ts`).

/// A preview shows a few lines at most, so it reads only this many characters of the source.
const PREVIEW_SOURCE_MAX_CHARS: usize = 2000;
/// Code spans wait behind this private-use character while the inline rules run, so their
/// characters stay as written.
const PLACEHOLDER: char = '\u{E000}';
/// What follows a block that ends without punctuation.
const BLOCK_SEPARATOR: &str = " \u{00B7} ";

struct Block {
    text: String,
    /// A paragraph, list item or heading, whose inline Markdown can span its lines.
    inline: bool,
}

/// Markdown as plain text on one line, for a preview that cuts it short.
///
/// The syntax goes and the text stays. Code keeps its characters, a link its label and a table
/// its cells. A paragraph's lines join with spaces. Each block follows the one before after a
/// space, or after " · " when that one ends without punctuation. Empty when no text remains.
///
/// For example, `"**Inputs:** the pull request\n\n- Fix the tests\n- Push"` reads
/// `"Inputs: the pull request · Fix the tests · Push"`.
#[must_use]
pub fn markdown_preview_text(markdown: &str) -> String {
    let source: String = markdown.chars().take(PREVIEW_SOURCE_MAX_CHARS).collect();
    // Lines end at `\r\n`, `\r` or `\n`.
    let source = source.replace("\r\n", "\n").replace('\r', "\n");
    let mut blocks: Vec<Block> = Vec::new();
    // The open code fence's character and length.
    let mut fence: Option<(char, usize)> = None;
    // Whether the line before ended its block: a blank line, heading, table row, rule or code.
    let mut block_ended = true;
    for line in source.split('\n') {
        let fence_line = fence_line(line);
        if let Some((character, length)) = fence {
            // A closing fence repeats the opening character at least as many times.
            let closes = fence_line.is_some_and(|(close, count, rest)| {
                close == character && count >= length && rest.trim().is_empty()
            });
            if closes {
                fence = None;
            } else {
                blocks.push(Block {
                    text: line.to_owned(),
                    inline: false,
                });
            }
            block_ended = true;
        } else if let Some((character, length, _)) = fence_line {
            fence = Some((character, length));
            block_ended = true;
        } else if line.trim().is_empty() || is_rule_line(line) || is_table_delimiter_line(line) {
            block_ended = true;
        } else if let Some(row) = table_row(line) {
            // A cell's escaped pipes are pipes, even in its code.
            let cells: Vec<String> = table_cells(row)
                .iter()
                .map(|cell| {
                    inline_plain_text(&cell.replace("\\|", "|"))
                        .trim()
                        .to_owned()
                })
                .filter(|cell| !cell.is_empty())
                .collect();
            blocks.push(Block {
                text: cells.join(BLOCK_SEPARATOR),
                inline: false,
            });
            block_ended = true;
        } else {
            let unquoted = without_quote_markers(line);
            let (marker, content) = unquoted
                .split_at_checked(block_marker_len(unquoted))
                .unwrap_or(("", unquoted));
            // A line without a marker goes on with the paragraph or list item before it.
            match blocks.last_mut() {
                Some(last) if !block_ended && marker.is_empty() && last.inline => {
                    last.text.push(' ');
                    last.text.push_str(content);
                }
                _ => blocks.push(Block {
                    text: content.to_owned(),
                    inline: true,
                }),
            }
            // A heading takes one line.
            block_ended = marker.trim_start().starts_with('#');
        }
    }
    let mut text = String::new();
    for block in blocks {
        let plain = if block.inline {
            inline_plain_text(&block.text)
        } else {
            block.text
        };
        let plain = plain.split_whitespace().collect::<Vec<_>>().join(" ");
        if plain.is_empty() {
            continue;
        }
        if !text.is_empty() {
            text.push_str(if ends_with_punctuation(&text) {
                " "
            } else {
                BLOCK_SEPARATOR
            });
        }
        text.push_str(&plain);
    }
    text
}

/// `line` after the up to three spaces a fence or rule may be indented by; `None` past them.
fn without_indent(line: &str) -> Option<&str> {
    let rest = line.trim_start_matches(' ');
    (line.len() - rest.len() <= 3).then_some(rest)
}

/// A fence's character, its length and the text after it: up to three spaces, then three or
/// more backticks or tildes.
fn fence_line(line: &str) -> Option<(char, usize, &str)> {
    let rest = without_indent(line)?;
    let character = rest.chars().next().filter(|c| matches!(*c, '`' | '~'))?;
    let after = rest.trim_start_matches(character);
    let length = rest.len() - after.len();
    (length >= 3).then_some((character, length, after))
}

/// A thematic break, or a setext heading's underline.
fn is_rule_line(line: &str) -> bool {
    let Some(rest) = without_indent(line) else {
        return false;
    };
    let rest = rest.trim_end_matches([' ', '\t']);
    if !rest.is_empty() && rest.chars().all(|c| c == '=') {
        return true;
    }
    let Some(mark) = rest
        .chars()
        .next()
        .filter(|c| matches!(*c, '-' | '*' | '_'))
    else {
        return false;
    };
    rest.chars().all(|c| c == mark || c == ' ' || c == '\t')
        && rest.chars().filter(|c| *c == mark).count() >= 3
}

/// A table's delimiter row, e.g. `| --- | :-: |`: two or more cells of dashes.
fn is_table_delimiter_line(line: &str) -> bool {
    let trimmed = line.trim_matches([' ', '\t']);
    let inner = trimmed.strip_prefix('|').unwrap_or(trimmed);
    let inner = inner.strip_suffix('|').unwrap_or(inner);
    let cells: Vec<&str> = inner.split('|').collect();
    cells.len() >= 2
        && cells.iter().all(|cell| {
            let cell = cell.trim_matches([' ', '\t']);
            let cell = cell.strip_prefix(':').unwrap_or(cell);
            let cell = cell.strip_suffix(':').unwrap_or(cell);
            !cell.is_empty() && cell.chars().all(|c| c == '-')
        })
}

/// A table row's text between its outer pipes.
fn table_row(line: &str) -> Option<&str> {
    line.trim_matches([' ', '\t'])
        .strip_prefix('|')?
        .strip_suffix('|')
}

/// A row's cells: runs of anything but a pipe, unless a backslash escapes it.
fn table_cells(row: &str) -> Vec<String> {
    let mut cells = Vec::new();
    let mut cell = String::new();
    let mut characters = row.chars();
    while let Some(character) = characters.next() {
        match character {
            '\\' => match characters.next() {
                Some(escaped) => {
                    cell.push('\\');
                    cell.push(escaped);
                }
                None => cells.push(std::mem::take(&mut cell)),
            },
            '|' => cells.push(std::mem::take(&mut cell)),
            _ => cell.push(character),
        }
    }
    cells.push(cell);
    cells.retain(|cell| !cell.is_empty());
    cells
}

/// `line` without a quote's markers, which a quoted paragraph repeats on each of its lines.
fn without_quote_markers(line: &str) -> &str {
    let mut rest = line.trim_start_matches([' ', '\t']);
    while let Some(after) = rest.strip_prefix('>') {
        rest = after.strip_prefix([' ', '\t']).unwrap_or(after);
    }
    rest
}

/// The length of what starts a block on `line`: a heading's hashes, or a list item's marker and
/// its task box, with the spaces before them; 0 for none.
fn block_marker_len(line: &str) -> usize {
    let spaced = |rest: &str| rest.is_empty() || rest.starts_with([' ', '\t']);
    let rest = line.trim_start_matches([' ', '\t']);
    let after_hashes = rest.trim_start_matches('#');
    let hashes = rest.len() - after_hashes.len();
    if (1..=6).contains(&hashes) && spaced(after_hashes) {
        return line.len() - after_hashes.len();
    }
    let after_digits = rest.trim_start_matches(|c: char| c.is_ascii_digit());
    let digits = rest.len() - after_digits.len();
    let after = match rest.strip_prefix(['-', '*', '+']) {
        Some(after) => after,
        None if (1..=9).contains(&digits) => match after_digits.strip_prefix(['.', ')']) {
            Some(after) => after,
            None => return 0,
        },
        None => return 0,
    };
    if !spaced(after) {
        return 0;
    }
    // A task box after the marker: `[ ]`, `[x]` or `[X]`, then a space or the end.
    let task = after.trim_start_matches([' ', '\t']);
    let boxed = (task.len() < after.len())
        .then(|| {
            ["[ ]", "[x]", "[X]"]
                .iter()
                .find_map(|mark| task.strip_prefix(mark))
        })
        .flatten()
        .filter(|rest| spaced(rest));
    line.len() - boxed.unwrap_or(after).len()
}

/// A sentence or clause ends `text`, so the next block follows after a space.
fn ends_with_punctuation(text: &str) -> bool {
    text.trim_end_matches(['"', '\'', ')', ']'])
        .ends_with(['.', '!', '?', ':', ';', ','])
}

/// An inline rule: at a position, the end of what it matched and what replaces it.
type InlineRule = fn(&[char], usize) -> Option<(usize, Vec<char>)>;

/// A block's inline Markdown as plain text.
fn inline_plain_text(source: &str) -> String {
    // The source's own placeholder characters go first, so none reads as a placeholder.
    let characters: Vec<char> = source.chars().filter(|c| *c != PLACEHOLDER).collect();
    let mut codes: Vec<Vec<char>> = Vec::new();
    let mut text = replace_all(&characters, |text, at| {
        let (end, before, code) = code_span(text, at)?;
        let mut placeholder: Vec<char> = before.into_iter().collect();
        placeholder.push(PLACEHOLDER);
        placeholder.extend(codes.len().to_string().chars());
        placeholder.push(PLACEHOLDER);
        codes.push(text.get(code).unwrap_or_default().to_vec());
        Some((end, placeholder))
    });
    let rules: [InlineRule; 8] = [
        image,
        link,
        reference_link,
        autolink,
        strong,
        emphasis,
        strikethrough,
        escape,
    ];
    for rule in rules {
        text = replace_all(&text, rule);
    }
    restore_code(&text, &codes)
}

/// Replaces each match `rule` finds at a position, left to right, as a global regular
/// expression replacement does.
fn replace_all(
    text: &[char],
    mut rule: impl FnMut(&[char], usize) -> Option<(usize, Vec<char>)>,
) -> Vec<char> {
    let mut out = Vec::with_capacity(text.len());
    let mut at = 0;
    while let Some(&character) = text.get(at) {
        match rule(text, at) {
            Some((end, replacement)) if end > at => {
                out.extend(replacement);
                at = end;
            }
            _ => {
                out.push(character);
                at += 1;
            }
        }
    }
    out
}

/// `text` from `from` on; empty past its end.
fn tail(text: &[char], from: usize) -> &[char] {
    text.get(from..).unwrap_or_default()
}

const fn is_word(character: char) -> bool {
    character.is_ascii_alphanumeric() || character == '_'
}

/// Where a match may start at `at`: at the very start, or after a character `before_allowed`
/// takes, which the match keeps.
fn starts(
    text: &[char],
    at: usize,
    before_allowed: fn(char) -> bool,
) -> Vec<(Option<char>, usize)> {
    let mut starts = Vec::new();
    if at == 0 {
        starts.push((None, 0));
    }
    if let Some(&before) = text.get(at).filter(|c| before_allowed(**c)) {
        starts.push((Some(before), at + 1));
    }
    starts
}

/// A code span at `at`: a run of backticks no backslash escapes, its code, then a run of as
/// many. Returns the match's end, the character kept before it and the code's range.
fn code_span(text: &[char], at: usize) -> Option<(usize, Option<char>, std::ops::Range<usize>)> {
    for (before, run) in starts(text, at, |c| c != '`' && c != '\\') {
        if text.get(run) != Some(&'`') {
            continue;
        }
        let ticks = tail(text, run).iter().take_while(|c| **c == '`').count();
        let code = run + ticks;
        // The code ends with something other than a backtick, before a run of exactly as many.
        let close = (code + 1..=text.len().saturating_sub(ticks)).find(|end| {
            text.get(end - 1) != Some(&'`')
                && text
                    .get(*end..end + ticks)
                    .is_some_and(|run| run.iter().all(|c| *c == '`'))
                && text.get(end + ticks) != Some(&'`')
        });
        if let Some(end) = close {
            return Some((end + ticks, before, code..end));
        }
    }
    None
}

/// `[label]` at `at`, the first `]` closing it; with `allow_empty`, the label may be empty.
fn bracketed(text: &[char], at: usize, allow_empty: bool) -> Option<(Vec<char>, usize)> {
    if text.get(at) != Some(&'[') {
        return None;
    }
    let label = tail(text, at + 1);
    let length = label.iter().position(|c| *c == ']')?;
    let label = label.get(..length).unwrap_or_default();
    (allow_empty || length > 0).then(|| (label.to_vec(), at + length + 2))
}

/// A link's `(destination "title")` at `at`, balanced parentheses one level deep; the end.
fn destination(text: &[char], at: usize) -> Option<usize> {
    if text.get(at) != Some(&'(') {
        return None;
    }
    let plain = |c: &char| !matches!(*c, '(' | ')') && !c.is_whitespace();
    let mut end = at + 1;
    loop {
        match text.get(end) {
            Some(c) if plain(c) => end += 1,
            Some(&'(') => {
                let inner = end + 1 + tail(text, end + 1).iter().take_while(|c| plain(c)).count();
                if text.get(inner) != Some(&')') {
                    break;
                }
                end = inner + 1;
            }
            _ => break,
        }
    }
    let gap = tail(text, end)
        .iter()
        .take_while(|c| matches!(**c, ' ' | '\t'))
        .count();
    if gap > 0 && text.get(end + gap) == Some(&'"') {
        let title = end + gap + 1;
        if let Some(quote) = tail(text, title).iter().position(|c| *c == '"') {
            let after = title + quote + 1;
            if text.get(after) == Some(&')') {
                return Some(after + 1);
            }
        }
    }
    (text.get(end) == Some(&')')).then_some(end + 1)
}

/// An image shows its alt text.
fn image(text: &[char], at: usize) -> Option<(usize, Vec<char>)> {
    if text.get(at) != Some(&'!') {
        return None;
    }
    let (alt, after) = bracketed(text, at + 1, true)?;
    Some((destination(text, after)?, alt))
}

/// A link shows its label.
fn link(text: &[char], at: usize) -> Option<(usize, Vec<char>)> {
    let (label, after) = bracketed(text, at, false)?;
    Some((destination(text, after)?, label))
}

/// A reference link, `[label][ref]`, shows its label.
fn reference_link(text: &[char], at: usize) -> Option<(usize, Vec<char>)> {
    let (label, after) = bracketed(text, at, false)?;
    let (_, end) = bracketed(text, after, true)?;
    Some((end, label))
}

/// `<https://…>` and `<mailto:…>` show their address.
fn autolink(text: &[char], at: usize) -> Option<(usize, Vec<char>)> {
    if text.get(at) != Some(&'<') {
        return None;
    }
    let rest = tail(text, at + 1);
    let scheme = ["https:", "http:", "mailto:"]
        .into_iter()
        .find_map(|scheme| {
            let scheme: Vec<char> = scheme.chars().collect();
            rest.starts_with(&scheme).then_some(scheme.len())
        })?;
    let address = tail(rest, scheme)
        .iter()
        .take_while(|c| !c.is_whitespace() && !matches!(**c, '<' | '>'))
        .count();
    let end = scheme + address;
    let shown = rest
        .get(..end)
        .filter(|_| address > 0 && rest.get(end) == Some(&'>'))?;
    Some((at + 2 + end, shown.to_vec()))
}

/// A span between two of the same delimiter, which keeps its text: the delimiter opens after
/// the start or a character `before` allows, the text starts with what `first` allows and ends
/// with what `last` allows, and the closing delimiter comes before what `after` allows.
struct Span {
    before: fn(char) -> bool,
    delimiters: &'static [&'static str],
    first: fn(char) -> bool,
    last: fn(char) -> bool,
    after: fn(Option<char>) -> bool,
}

impl Span {
    fn at(&self, text: &[char], at: usize) -> Option<(usize, Vec<char>)> {
        for (before, open) in starts(text, at, self.before) {
            for delimiter in self.delimiters {
                let delimiter: Vec<char> = delimiter.chars().collect();
                if !tail(text, open).starts_with(&delimiter) {
                    continue;
                }
                let start = open + delimiter.len();
                if !text.get(start).is_some_and(|c| (self.first)(*c)) {
                    continue;
                }
                let close = (start + 1..=text.len()).find(|end| {
                    text.get(end - 1).is_some_and(|c| (self.last)(*c))
                        && tail(text, *end).starts_with(&delimiter)
                        && (self.after)(text.get(end + delimiter.len()).copied())
                });
                if let Some(end) = close {
                    let mut kept: Vec<char> = before.into_iter().collect();
                    kept.extend_from_slice(text.get(start..end).unwrap_or_default());
                    return Some((end + delimiter.len(), kept));
                }
            }
        }
        None
    }
}

/// Neither a delimiter nor part of a word follows, so `snake_case` stays.
fn ends_word(next: Option<char>) -> bool {
    next.is_none_or(|c| c != '*' && c != '_' && !is_word(c))
}

const fn opens_word(before: char) -> bool {
    before != '\\' && before != '*' && before != '_' && !is_word(before)
}

/// Strong keeps its text.
fn strong(text: &[char], at: usize) -> Option<(usize, Vec<char>)> {
    Span {
        before: opens_word,
        delimiters: &["**", "__"],
        first: |c| !c.is_whitespace(),
        last: |c| !c.is_whitespace(),
        after: ends_word,
    }
    .at(text, at)
}

/// Emphasis keeps its text.
fn emphasis(text: &[char], at: usize) -> Option<(usize, Vec<char>)> {
    Span {
        before: opens_word,
        delimiters: &["*", "_"],
        first: |c| !c.is_whitespace() && c != '*' && c != '_',
        last: |c| !c.is_whitespace() && c != '\\',
        after: ends_word,
    }
    .at(text, at)
}

/// Strikethrough keeps its text.
fn strikethrough(text: &[char], at: usize) -> Option<(usize, Vec<char>)> {
    Span {
        before: |c| c != '\\' && c != '~',
        delimiters: &["~~"],
        first: |c| !c.is_whitespace(),
        last: |c| !c.is_whitespace(),
        after: |next| next != Some('~'),
    }
    .at(text, at)
}

/// An escaped character shows as itself.
fn escape(text: &[char], at: usize) -> Option<(usize, Vec<char>)> {
    if text.get(at) != Some(&'\\') {
        return None;
    }
    let escaped = *text.get(at + 1)?;
    "\\`*_{}[]()#+.!|<>~-"
        .contains(escaped)
        .then(|| (at + 2, vec![escaped]))
}

/// The code spans back in place of their placeholders.
fn restore_code(text: &[char], codes: &[Vec<char>]) -> String {
    let mut out = String::with_capacity(text.len());
    let mut at = 0;
    while let Some(&character) = text.get(at) {
        if character == PLACEHOLDER {
            let digits = tail(text, at + 1)
                .iter()
                .take_while(|c| c.is_ascii_digit())
                .count();
            let close = at + 1 + digits;
            if digits > 0 && text.get(close) == Some(&PLACEHOLDER) {
                let index: String = text.get(at + 1..close).unwrap_or_default().iter().collect();
                if let Some(code) = index.parse::<usize>().ok().and_then(|i| codes.get(i)) {
                    out.extend(code);
                    at = close + 1;
                    continue;
                }
            }
        }
        out.push(character);
        at += 1;
    }
    out
}

#[cfg(test)]
#[path = "markdown_preview_tests.rs"]
mod tests;
