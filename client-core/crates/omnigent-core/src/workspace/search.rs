//! Query validation for path and content search, and content-search results with match
//! ranges.
//!
//! Content search answers `{matches: [{path, line, column, text, match_start, match_end}],
//! truncated, warning}`. `line` and `column` are 1-based; `column`, `match_start` and
//! `match_end` count UTF-16 code units, and the two offsets index `text`, a preview of the line
//! (cut to about 400 characters around the first match, with `…` marking a cut). A failed
//! search (an invalid regular expression, missing ripgrep) still answers 200, with
//! `{"error": "<text>"}`.
//!
//! ripgrep runs without `--sort`, so match order varies between runs; [`ContentSearchResult`]
//! orders matches by path, then line and column.

use serde_json::Value;

use super::error::{ServerFailure, WorkspaceError};
use super::path::WorkspacePath;
use crate::client::json::{as_object, opt_array, opt_bool, opt_str, opt_u64, req_str};

/// The most results either search returns.
pub const MAX_SEARCH_LIMIT: u32 = 500;
/// The longest query or filter list the server accepts, in characters.
pub const MAX_QUERY_CHARS: usize = 4096;

/// A path (file name) search.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathSearchQuery {
    /// Case-insensitive substring of the name or relative path.
    pub query: String,
    /// The directory to search under; the root searches everything.
    pub under: WorkspacePath,
    /// Globs a result must match, for example `src/**` or `*.{ts,tsx}`.
    pub include: Vec<String>,
    /// Globs that drop a result.
    pub exclude: Vec<String>,
    /// At most this many results, `1..=500`.
    pub limit: u32,
}

impl PathSearchQuery {
    /// A search of the whole environment with the server's default limit.
    #[must_use]
    pub fn new(query: impl Into<String>) -> Self {
        Self {
            query: query.into(),
            under: WorkspacePath::root(),
            include: Vec::new(),
            exclude: Vec::new(),
            limit: MAX_SEARCH_LIMIT,
        }
    }

    pub(super) fn validate(&self) -> Result<(), WorkspaceError> {
        validate_query(&self.query)?;
        validate_limit(self.limit)?;
        joined_globs(&self.include)?;
        joined_globs(&self.exclude)?;
        Ok(())
    }
}

/// A content (text) search.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContentSearchQuery {
    /// A single-line literal, or a ripgrep regular expression when `regex`.
    pub query: String,
    /// Letter case must match.
    pub case_sensitive: bool,
    /// Interpret `query` as a regular expression.
    pub regex: bool,
    /// Globs a file must match; an explicit include overrides ignore rules, as in ripgrep.
    pub include: Vec<String>,
    /// Globs that exclude files; they win over includes.
    pub exclude: Vec<String>,
    /// At most this many matching lines, `1..=500`.
    pub limit: u32,
}

impl ContentSearchQuery {
    /// A literal, case-insensitive search with the server's default limit.
    #[must_use]
    pub fn new(query: impl Into<String>) -> Self {
        Self {
            query: query.into(),
            case_sensitive: false,
            regex: false,
            include: Vec::new(),
            exclude: Vec::new(),
            limit: MAX_SEARCH_LIMIT,
        }
    }

    pub(super) fn validate(&self) -> Result<(), WorkspaceError> {
        validate_query(&self.query)?;
        validate_limit(self.limit)?;
        for globs in [&self.include, &self.exclude] {
            if globs
                .iter()
                .flat_map(|glob| split_globs(glob))
                .any(|pattern| pattern.starts_with('!'))
            {
                return Err(invalid(
                    "Use the Include and Exclude fields instead of ! prefixes.",
                ));
            }
            joined_globs(globs)?;
        }
        Ok(())
    }
}

fn invalid(reason: &str) -> WorkspaceError {
    WorkspaceError::InvalidQuery {
        reason: reason.to_owned(),
    }
}

fn validate_query(query: &str) -> Result<(), WorkspaceError> {
    if query.trim().is_empty() {
        return Err(invalid("Enter something to search for."));
    }
    if query.chars().count() > MAX_QUERY_CHARS {
        return Err(invalid("Search queries are limited to 4,096 characters."));
    }
    if query.contains(['\0', '\r', '\n']) {
        return Err(invalid("Search for a single line of text."));
    }
    Ok(())
}

fn validate_limit(limit: u32) -> Result<(), WorkspaceError> {
    if (1..=MAX_SEARCH_LIMIT).contains(&limit) {
        Ok(())
    } else {
        Err(invalid("Request between 1 and 500 search results."))
    }
}

/// The comma-separated wire form of `globs`, blanks dropped.
pub(super) fn joined_globs(globs: &[String]) -> Result<String, WorkspaceError> {
    let kept: Vec<&str> = globs
        .iter()
        .map(|glob| glob.trim())
        .filter(|glob| !glob.is_empty())
        .collect();
    let joined = kept.join(",");
    if joined.contains(['\0', '\r', '\n']) {
        return Err(invalid("File filters must be single-line glob patterns."));
    }
    if joined.chars().count() > MAX_QUERY_CHARS {
        return Err(invalid("File filters are limited to 4,096 characters."));
    }
    Ok(joined)
}

/// Splits a comma-separated filter field the way the server does: on top-level commas only,
/// so `*.{js,ts}, src/**` is two patterns.
#[must_use]
pub fn split_globs(raw: &str) -> Vec<String> {
    let mut patterns = Vec::new();
    let mut current = String::new();
    let mut depth = 0_u32;
    for character in raw.chars() {
        match character {
            '{' => depth += 1,
            '}' => depth = depth.saturating_sub(1),
            ',' if depth == 0 => {
                patterns.push(std::mem::take(&mut current));
                continue;
            }
            _ => {}
        }
        current.push(character);
    }
    patterns.push(current);
    patterns
        .into_iter()
        .map(|pattern| pattern.trim().to_owned())
        .filter(|pattern| !pattern.is_empty())
        .collect()
}

/// A half-open range of offsets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TextRange {
    /// First offset.
    pub start: u64,
    /// One past the last offset.
    pub end: u64,
}

/// One matching line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContentMatch {
    /// Environment-root-relative path.
    pub path: WorkspacePath,
    /// 1-based line number.
    pub line: u64,
    /// 1-based column of the match in the full line, in UTF-16 code units.
    pub column: u64,
    /// The line preview.
    pub text: String,
    /// The first match within `text`, in UTF-16 code units (Swift `String.utf16`, JavaScript).
    pub match_utf16: TextRange,
    /// The same range in UTF-8 bytes (Rust `str`, Swift `String.utf8`).
    pub match_utf8: TextRange,
}

/// Matches in one file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContentSearchFile {
    /// The file.
    pub path: WorkspacePath,
    /// Its matches, by line.
    pub matches: Vec<ContentMatch>,
}

/// A finished content search.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContentSearchResult {
    /// Matches by path, then line and column.
    pub matches: Vec<ContentMatch>,
    /// The search stopped early (the limit, the 15 s budget, or read errors): results are
    /// partial and "no matches" is not definitive.
    pub truncated: bool,
    /// Why results may be incomplete, in the server's words.
    pub warning: Option<String>,
}

impl ContentSearchResult {
    /// Matches grouped by file, files by path.
    #[must_use]
    pub fn files(&self) -> Vec<ContentSearchFile> {
        let mut files: Vec<ContentSearchFile> = Vec::new();
        for found in &self.matches {
            match files.last_mut() {
                Some(file) if file.path == found.path => file.matches.push(found.clone()),
                _ => files.push(ContentSearchFile {
                    path: found.path.clone(),
                    matches: vec![found.clone()],
                }),
            }
        }
        files
    }
}

/// Converts UTF-16 offsets into `text` to UTF-8 byte offsets.
///
/// # Errors
///
/// When an offset is past the end or splits a surrogate pair.
pub fn utf16_to_utf8(text: &str, range: TextRange) -> Result<TextRange, String> {
    if range.start > range.end {
        return Err(format!("range {}..{} is reversed", range.start, range.end));
    }
    let mut start = None;
    let mut end = None;
    let mut units = 0_u64;
    for (index, character) in text.char_indices() {
        let byte = u64::try_from(index).map_err(|error| error.to_string())?;
        if units == range.start {
            start.get_or_insert(byte);
        }
        if units == range.end {
            end.get_or_insert(byte);
        }
        units += u64::try_from(character.len_utf16()).map_err(|error| error.to_string())?;
    }
    let length = u64::try_from(text.len()).map_err(|error| error.to_string())?;
    if units == range.start {
        start.get_or_insert(length);
    }
    if units == range.end {
        end.get_or_insert(length);
    }
    match (start, end) {
        (Some(start), Some(end)) => Ok(TextRange { start, end }),
        _ => Err(format!(
            "range {}..{} does not fall on character boundaries of a {units}-unit line",
            range.start, range.end
        )),
    }
}

fn content_match(value: &Value) -> Result<ContentMatch, String> {
    let object = as_object(value, "match")?;
    let raw_path = req_str(object, "path")?;
    let path = WorkspacePath::parse(&raw_path)
        .map_err(|error| format!("unsafe path {raw_path:?} from the server: {error}"))?;
    let text = req_str(object, "text")?;
    let required = |key: &str| -> Result<u64, String> {
        opt_u64(object, key)?.ok_or_else(|| format!("`{key}` is missing"))
    };
    let match_utf16 = TextRange {
        start: required("match_start")?,
        end: required("match_end")?,
    };
    let match_utf8 = utf16_to_utf8(&text, match_utf16)?;
    Ok(ContentMatch {
        path,
        line: required("line")?,
        column: opt_u64(object, "column")?.unwrap_or(1),
        text,
        match_utf16,
        match_utf8,
    })
}

pub(super) fn content_search(value: &Value) -> Result<ContentSearchResult, WorkspaceError> {
    let context = "content search";
    let object = as_object(value, context).map_err(|e| WorkspaceError::malformed(context, e))?;
    if object.contains_key("error") {
        let failure = ServerFailure::from_value(value);
        return Err(WorkspaceError::SearchFailed {
            message: failure
                .message
                .unwrap_or_else(|| "Content search could not run in this workspace.".to_owned()),
        });
    }
    let decode = || -> Result<ContentSearchResult, String> {
        let mut matches = opt_array(object, "matches")?
            .ok_or("`matches` is missing")?
            .iter()
            .map(content_match)
            .collect::<Result<Vec<_>, _>>()?;
        matches.sort_by(|left, right| {
            (&left.path, left.line, left.column).cmp(&(&right.path, right.line, right.column))
        });
        Ok(ContentSearchResult {
            matches,
            truncated: opt_bool(object, "truncated")?.unwrap_or(false),
            warning: opt_str(object, "warning")?.filter(|warning| !warning.trim().is_empty()),
        })
    };
    decode().map_err(|error| WorkspaceError::malformed(context, error))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oversized_file_filters_are_refused() {
        assert_eq!(joined_globs(&["a".repeat(4096)]).unwrap().len(), 4096);
        assert!(joined_globs(&["a".repeat(4097)]).is_err());
    }

    #[test]
    fn utf16_offsets_become_byte_offsets() {
        let text = "😀 fixture needle again.";
        let range = utf16_to_utf8(text, TextRange { start: 11, end: 17 }).unwrap();
        assert_eq!(range, TextRange { start: 13, end: 19 });
        assert_eq!(text.get(13..19), Some("needle"));
        assert_eq!(
            utf16_to_utf8("abc", TextRange { start: 3, end: 3 }).unwrap(),
            TextRange { start: 3, end: 3 }
        );
        assert!(
            utf16_to_utf8("😀", TextRange { start: 1, end: 2 }).is_err(),
            "splits a pair"
        );
        assert!(utf16_to_utf8("abc", TextRange { start: 0, end: 4 }).is_err());
        assert!(utf16_to_utf8("abc", TextRange { start: 2, end: 1 }).is_err());
    }

    #[test]
    fn glob_lists_split_on_top_level_commas() {
        assert_eq!(split_globs("*.{js,ts}, src/**,,"), ["*.{js,ts}", "src/**"]);
        assert_eq!(split_globs(""), Vec::<String>::new());
        assert_eq!(
            joined_globs(&["  src/** ".into(), String::new(), "*.md".into()]).unwrap(),
            "src/**,*.md"
        );
    }

    #[test]
    fn queries_are_validated_before_sending() {
        assert!(ContentSearchQuery::new("  ").validate().is_err());
        assert!(ContentSearchQuery::new("a\nb").validate().is_err());
        assert!(
            ContentSearchQuery::new("x".repeat(4097))
                .validate()
                .is_err()
        );
        let mut query = ContentSearchQuery::new("needle");
        assert_eq!(query.validate(), Ok(()));
        query.limit = 0;
        assert!(query.validate().is_err());
        query.limit = 501;
        assert!(query.validate().is_err());
        query.limit = 10;
        query.exclude = vec!["!src/**".into()];
        assert!(query.validate().is_err());
        let mut path = PathSearchQuery::new("main");
        assert_eq!(path.validate(), Ok(()));
        path.include = vec!["a\nb".into()];
        assert!(path.validate().is_err());
    }

    #[test]
    fn a_two_hundred_with_an_error_is_a_failed_search() {
        let value = serde_json::json!({"error": "regex parse error"});
        assert_eq!(
            content_search(&value),
            Err(WorkspaceError::SearchFailed {
                message: "regex parse error".into()
            })
        );
    }
}
