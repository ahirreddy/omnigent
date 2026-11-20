//! Comments on an HTML file's rendered preview, anchored to its source as the web's
//! `htmlCommentBridge` anchors them (`findAnchorInSource`, `anchorOccurrence`).
//!
//! The preview reports the rendered text a reader selected and which copy of it (in document
//! order) they picked. The comment stores that text as its anchor, with the offsets of the same
//! copy in the source. Matching tolerates whitespace, since rendered prose collapses the
//! newlines and indentation the source spells out, and skips source that never renders: tags
//! (so attribute values), comments, and the contents of `script`, `style`, `title` and
//! `noscript`. Offsets count characters (code points), as every comment's do.

use super::comments::FileComment;

/// The elements whose contents never render as text.
const HIDDEN_ELEMENTS: [&str; 4] = ["script", "style", "title", "noscript"];

/// Where a comment on `selected` text goes in `source`: the `occurrence` (0-based, counting only
/// rendered text) of the whitespace-tolerant match. `None` when that copy isn't in the source.
#[must_use]
pub fn html_anchor_range(source: &str, selected: &str, occurrence: u64) -> Option<(u64, u64)> {
    let source: Vec<char> = source.chars().collect();
    let pieces = anchor_pieces(selected)?;
    let skipped = non_rendered_ranges(&source);
    rendered_matches(&source, &pieces, &skipped)
        .nth(usize::try_from(occurrence).ok()?)
        .map(|(start, end)| (to_u64(start), to_u64(end)))
}

/// Which copy (0-based, in document order, counting only rendered text) of `anchor` the comment
/// starting at `start` is on, so a repeated phrase highlights only the one commented. 0 when the
/// anchor is blank.
#[must_use]
pub fn html_anchor_occurrence(source: &str, anchor: &str, start: u64) -> u64 {
    let source: Vec<char> = source.chars().collect();
    let Some(pieces) = anchor_pieces(anchor) else {
        return 0;
    };
    let skipped = non_rendered_ranges(&source);
    let before = rendered_matches(&source, &pieces, &skipped)
        .take_while(|(index, _)| to_u64(*index) < start)
        .count();
    to_u64(before)
}

/// Whether `path` previews as HTML, as the viewer renders `.html`, `.htm` and `.svg` files.
#[must_use]
pub fn previews_as_html(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path).to_ascii_lowercase();
    match name.rsplit_once('.') {
        Some((stem, extension)) => !stem.is_empty() && matches!(extension, "html" | "htm" | "svg"),
        None => false,
    }
}

/// The copy of an HTML file's comment's anchor its preview highlights; `None` for other files
/// and for comments without anchor text.
#[must_use]
pub fn comment_html_occurrence(comment: &FileComment, text: &str) -> Option<u64> {
    if !previews_as_html(&comment.path) {
        return None;
    }
    let anchor = comment.anchor.as_deref()?;
    Some(html_anchor_occurrence(
        text,
        anchor,
        comment.start_index.unwrap_or_default(),
    ))
}

fn to_u64(value: usize) -> u64 {
    u64::try_from(value).unwrap_or(u64::MAX)
}

/// Every code point through U+0020 separates words, as the preview's whitespace folding does.
const fn is_folded_space(character: char) -> bool {
    character <= ' '
}

/// JavaScript's `trim` whitespace.
const fn is_trimmed_space(character: char) -> bool {
    character.is_whitespace() || character == '\u{feff}'
}

/// The anchor's words: the trimmed text split on runs of folded whitespace. `None` when blank.
fn anchor_pieces(anchor: &str) -> Option<Vec<Vec<char>>> {
    let trimmed = anchor.trim_matches(is_trimmed_space);
    if trimmed.is_empty() {
        return None;
    }
    let mut pieces = vec![Vec::new()];
    let mut in_space = false;
    for character in trimmed.chars() {
        if is_folded_space(character) {
            in_space = true;
            continue;
        }
        if in_space {
            pieces.push(Vec::new());
            in_space = false;
        }
        if let Some(piece) = pieces.last_mut() {
            piece.push(character);
        }
    }
    if in_space {
        pieces.push(Vec::new());
    }
    Some(pieces)
}

/// The end of the anchor matched at `start`: each word in turn, one or more folded spaces
/// between them.
fn match_at(source: &[char], start: usize, pieces: &[Vec<char>]) -> Option<usize> {
    let mut at = start;
    for (index, piece) in pieces.iter().enumerate() {
        if index > 0 {
            let spaces = source
                .get(at..)?
                .iter()
                .take_while(|character| is_folded_space(**character))
                .count();
            if spaces == 0 {
                return None;
            }
            at += spaces;
        }
        if source.get(at..at + piece.len())? != piece.as_slice() {
            return None;
        }
        at += piece.len();
    }
    (at > start).then_some(at)
}

/// The anchor's non-overlapping matches in document order, outside source that never renders.
fn rendered_matches<'a>(
    source: &'a [char],
    pieces: &'a [Vec<char>],
    skipped: &'a [(usize, usize)],
) -> impl Iterator<Item = (usize, usize)> + 'a {
    let mut from = 0;
    std::iter::from_fn(move || {
        while from < source.len() {
            let start = from;
            if let Some(end) = match_at(source, start, pieces) {
                from = end;
                if !in_ranges(start, skipped) {
                    return Some((start, end));
                }
            } else {
                from += 1;
            }
        }
        None
    })
}

/// Whether `index` falls in any of the `ranges`, sorted by start.
fn in_ranges(index: usize, ranges: &[(usize, usize)]) -> bool {
    for (start, end) in ranges {
        if index < *start {
            break;
        }
        if index < *end {
            return true;
        }
    }
    false
}

/// The `[start, end)` ranges of `source` that never render as text, sorted by start: comments,
/// hidden elements with their contents, and every tag.
fn non_rendered_ranges(source: &[char]) -> Vec<(usize, usize)> {
    let mut ranges = comment_ranges(source);
    ranges.extend(hidden_element_ranges(source));
    ranges.extend(tag_ranges(source));
    ranges.sort_unstable();
    ranges
}

fn find(source: &[char], from: usize, needle: &str) -> Option<usize> {
    let needle: Vec<char> = needle.chars().collect();
    (from..source.len()).find(|start| {
        source
            .get(*start..*start + needle.len())
            .is_some_and(|window| window == needle.as_slice())
    })
}

/// `<!-- … -->`.
fn comment_ranges(source: &[char]) -> Vec<(usize, usize)> {
    let mut ranges = Vec::new();
    let mut from = 0;
    while let Some(start) = find(source, from, "<!--") {
        let Some(close) = find(source, start + 4, "-->") else {
            break;
        };
        ranges.push((start, close + 3));
        from = close + 3;
    }
    ranges
}

/// `<…>`: each `<` to the next `>`.
fn tag_ranges(source: &[char]) -> Vec<(usize, usize)> {
    let mut ranges = Vec::new();
    let mut from = 0;
    while let Some(start) = (from..source.len()).find(|index| source.get(*index) == Some(&'<')) {
        let Some(close) = (start + 1..source.len()).find(|index| source.get(*index) == Some(&'>'))
        else {
            break;
        };
        ranges.push((start, close + 1));
        from = close + 1;
    }
    ranges
}

const fn is_word(character: char) -> bool {
    character.is_ascii_alphanumeric() || character == '_'
}

/// Whether `source` at `at` spells `name`, ignoring ASCII case.
fn spells(source: &[char], at: usize, name: &str) -> bool {
    name.chars().enumerate().all(|(offset, expected)| {
        source
            .get(at + offset)
            .is_some_and(|character| character.eq_ignore_ascii_case(&expected))
    })
}

/// A hidden element from its opening tag through its first closing tag (`</name >`).
fn hidden_element_ranges(source: &[char]) -> Vec<(usize, usize)> {
    let mut ranges = Vec::new();
    let mut index = 0;
    while index < source.len() {
        let opened = (source.get(index) == Some(&'<'))
            .then(|| {
                HIDDEN_ELEMENTS.iter().find(|name| {
                    spells(source, index + 1, name)
                        && !source
                            .get(index + 1 + name.len())
                            .copied()
                            .is_some_and(is_word)
                })
            })
            .flatten();
        let closed = opened.and_then(|name| closing_tag_end(source, index + 1 + name.len(), name));
        if let Some(end) = closed {
            ranges.push((index, end));
            index = end;
        } else {
            index += 1;
        }
    }
    ranges
}

/// The end of the first `</name>` (spaces allowed before `>`) from `from`.
fn closing_tag_end(source: &[char], from: usize, name: &str) -> Option<usize> {
    let mut at = from;
    while let Some(start) = find(source, at, "</") {
        if spells(source, start + 2, name) {
            let after = start + 2 + name.len();
            let spaces = source.get(after..).map_or(0, |rest| {
                rest.iter().take_while(|c| c.is_whitespace()).count()
            });
            if source.get(after + spaces) == Some(&'>') {
                return Some(after + spaces + 1);
            }
        }
        at = start + 2;
    }
    None
}

#[cfg(test)]
#[path = "html_comments_tests.rs"]
mod tests;
