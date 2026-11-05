//! Session workspace files.
//!
//! Directory pages, file content with its preview, path and content search, changed files and
//! per-file diffs. Records mirror `omnigent_core::workspace`; the preview, tree order, grouping,
//! totals and diff are computed by the core.
//!
//! Paths are the core's normalized environment-relative text: no leading slash, `""` for the
//! root. Every path argument is validated by the core before anything is sent.

use omnigent_core::workspace as core;

use crate::client::ClientCore;
use crate::errors::CoreError;

/// The kind of a workspace failure; mirrors the Swift `WorkspaceFailure.Kind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum WorkspaceErrorKind {
    /// Not connected, signed out, or the network failed.
    NotConnected,
    /// A path, identifier or query that cannot be sent, or that the server refused.
    InvalidInput,
    /// The file or directory does not exist.
    NotFound,
    /// The file has no changes this session.
    NotChanged,
    /// The session has no filesystem, or its change list could not be computed.
    Unavailable,
    /// No access to the path.
    Forbidden,
    /// The session's runner is offline.
    RunnerOffline,
    /// Content search is turned off on the server.
    SearchDisabled,
    /// Content search ran but failed (for example an invalid regular expression).
    SearchFailed,
    /// Any other server or decoding failure.
    Server,
}

pub(crate) fn workspace_error(error: core::WorkspaceError) -> CoreError {
    use core::WorkspaceError as E;
    use omnigent_core::SessionError as S;
    let kind = match &error {
        E::InvalidPath(_)
        | E::InvalidIdentifier { .. }
        | E::InvalidQuery { .. }
        | E::Rejected { .. }
        | E::Session(S::InvalidIdentifier { .. }) => WorkspaceErrorKind::InvalidInput,
        E::Session(S::NotConnected | S::Unauthorized { .. } | S::Transport(_) | S::Cancelled) => {
            WorkspaceErrorKind::NotConnected
        }
        E::Session(S::Forbidden) | E::Forbidden { .. } | E::PathUnreachable { .. } => {
            WorkspaceErrorKind::Forbidden
        }
        E::Session(S::SessionNotFound { .. }) | E::Unavailable { .. } => {
            WorkspaceErrorKind::Unavailable
        }
        E::NotFound { .. } => WorkspaceErrorKind::NotFound,
        E::NotChanged { .. } => WorkspaceErrorKind::NotChanged,
        E::ChangesUnavailable { .. } => WorkspaceErrorKind::Unavailable,
        E::ContentSearchDisabled => WorkspaceErrorKind::SearchDisabled,
        E::SearchFailed { .. } => WorkspaceErrorKind::SearchFailed,
        E::RunnerOffline { .. } => WorkspaceErrorKind::RunnerOffline,
        E::Session(_)
        | E::Server { .. }
        | E::UnexpectedKind { .. }
        | E::MalformedResponse { .. } => WorkspaceErrorKind::Server,
    };
    let requires_sign_in = matches!(&error, E::Session(session) if session.requires_sign_in());
    CoreError::Workspace {
        kind,
        message: error.to_string(),
        requires_sign_in,
    }
}

fn path_error(error: core::PathError) -> CoreError {
    workspace_error(core::WorkspaceError::InvalidPath(error))
}

/// What a filesystem entry is.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum WorkspaceEntryKind {
    /// A regular file.
    File,
    /// A directory.
    Directory,
    /// A symbolic link the server did not resolve.
    Symlink,
    /// A socket, device or other special file.
    Other,
    /// A type newer than this client.
    Unknown {
        /// The type as sent.
        value: String,
    },
}

/// One file or directory.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct WorkspaceEntry {
    /// Environment-relative path.
    pub path: String,
    /// The base name.
    pub name: String,
    /// What it is.
    pub kind: WorkspaceEntryKind,
    /// Size in bytes, for files.
    pub size: Option<u64>,
    /// Last modification, Unix seconds.
    pub modified_at: Option<i64>,
}

/// One page of a directory, in tree order (directories first, then by name).
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct WorkspaceDirectoryPage {
    /// The directory listed.
    pub directory: String,
    /// Entries in tree order.
    pub entries: Vec<WorkspaceEntry>,
    /// Pass as `after` to read the next page; `None` on the last page.
    pub next_cursor: Option<String>,
}

/// Matches from a file-name search.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct WorkspacePathSearchResult {
    /// The directory searched.
    pub directory: String,
    /// Matches, environment-relative.
    pub entries: Vec<WorkspaceEntry>,
    /// The result limit was reached; there may be more matches.
    pub has_more: bool,
    /// The server stopped before covering the tree, so a missing file may exist.
    pub truncated: bool,
}

/// How a file changed this session.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum WorkspaceChangeStatus {
    /// New this session.
    Created,
    /// Changed, including renames (git reports the new path).
    Modified,
    /// Removed.
    Deleted,
    /// A status newer than this client.
    Unknown {
        /// The status as sent.
        value: String,
    },
}

/// One changed file.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct WorkspaceChangedFile {
    /// Environment-relative path.
    pub path: String,
    /// The status.
    pub status: WorkspaceChangeStatus,
    /// Size in bytes.
    pub size: Option<u64>,
    /// Last modification, Unix seconds.
    pub modified_at: Option<i64>,
    /// Lines added, when the server counted them.
    pub lines_added: Option<u64>,
    /// Lines removed, when the server counted them.
    pub lines_removed: Option<u64>,
}

/// Summary counts for the changed files.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct WorkspaceChangeTotals {
    /// Created files.
    pub created: u64,
    /// Modified files.
    pub modified: u64,
    /// Deleted files.
    pub deleted: u64,
    /// Known added lines.
    pub lines_added: u64,
    /// Known removed lines.
    pub lines_removed: u64,
}

/// The session's changed files.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct WorkspaceChanges {
    /// Entries sorted by path.
    pub files: Vec<WorkspaceChangedFile>,
    /// Totals.
    pub totals: WorkspaceChangeTotals,
    /// The server capped the list.
    pub has_more: bool,
}

/// One environment of a session.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct WorkspaceEnvironment {
    /// Environment id, for example `default`.
    pub id: String,
    /// Display name.
    pub name: Option<String>,
    /// `primary`, ...
    pub role: Option<String>,
    /// The environment type the server reports.
    pub environment_type: Option<String>,
    /// The absolute root on the machine that runs the environment, when reported.
    pub root: Option<String>,
    /// The home directory on that machine, to expand `~` in cited paths, when reported.
    pub home: Option<String>,
    /// Paths outside the root are reachable.
    pub unconfined: Option<bool>,
    /// The session's primary environment.
    pub is_primary: bool,
}

/// Line terminators in shown text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum LineEnding {
    /// `\n`.
    Lf,
    /// `\r\n`.
    CrLf,
    /// Both.
    Mixed,
}

/// A recognised image format.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
#[allow(missing_docs, reason = "variant names are the format names")]
pub enum ImageFormat {
    Png,
    Jpeg,
    Gif,
    Webp,
    Bmp,
    Tiff,
    Heic,
    Ico,
}

/// A syntax-highlighting hint, from the file name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
#[allow(missing_docs, reason = "variant names are the language names")]
pub enum SyntaxLanguage {
    Bash,
    C,
    Cpp,
    CSharp,
    Css,
    Dockerfile,
    Go,
    Html,
    Java,
    JavaScript,
    Json,
    Kotlin,
    Makefile,
    Markdown,
    ObjectiveC,
    Php,
    Python,
    Ruby,
    Rust,
    Scala,
    Sql,
    Swift,
    Toml,
    TypeScript,
    Xml,
    Yaml,
}

/// Why a file is shown as binary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum BinaryReason {
    /// The server returned bytes that are not text or a known image.
    NotText,
    /// The text contains NUL bytes.
    NulBytes,
    /// An image larger than the server's read cap.
    TruncatedImage,
}

/// Text ready for a monospaced viewer.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TextPreview {
    /// The text shown, without a byte-order mark.
    pub text: String,
    /// Lines in `text`.
    pub line_count: u64,
    /// Line terminators in the shown text.
    pub line_ending: LineEnding,
    /// The file started with a UTF-8 byte-order mark.
    pub has_bom: bool,
    /// The highlighting hint.
    pub language: Option<SyntaxLanguage>,
    /// Highlighting should be skipped (a line is longer than the limit).
    pub skip_highlighting: bool,
    /// This client cut the text at its preview limits.
    pub clipped: bool,
    /// The server returned only part of the file.
    pub server_truncated: bool,
}

/// What a viewer should show for a file.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum FilePreview {
    /// Text.
    Text {
        /// The text and its facts.
        preview: TextPreview,
    },
    /// An image.
    Image {
        /// Its format.
        format: ImageFormat,
        /// The bytes.
        data: Vec<u8>,
    },
    /// Not shown.
    Binary {
        /// Why.
        reason: BinaryReason,
        /// Bytes returned.
        byte_count: u64,
    },
}

/// A file and its preview.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct WorkspaceFile {
    /// Environment-relative path.
    pub path: String,
    /// The media type the server reported.
    pub content_type: Option<String>,
    /// File size in bytes.
    pub byte_count: u64,
    /// The server returned only part of the file.
    pub truncated: bool,
    /// What to show.
    pub preview: FilePreview,
}

/// A file's bytes as the server returned them, for sharing or previewing outside the app.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct WorkspaceFileBytes {
    /// Environment-relative path.
    pub path: String,
    /// The media type the server reported.
    pub content_type: Option<String>,
    /// The server returned only part of the file.
    pub truncated: bool,
    /// The content: UTF-8 text re-encoded, or the bytes of a binary file.
    pub bytes: Vec<u8>,
}

/// A half-open range.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TextRange {
    /// Start, inclusive.
    pub start: u64,
    /// End, exclusive.
    pub end: u64,
}

/// One matching line.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ContentMatch {
    /// Environment-relative path.
    pub path: String,
    /// 1-based line.
    pub line: u64,
    /// 1-based column.
    pub column: u64,
    /// The line's text.
    pub text: String,
    /// The first match within `text`, in UTF-16 code units (Swift `String.utf16`).
    pub match_utf16: TextRange,
    /// The same range in UTF-8 bytes.
    pub match_utf8: TextRange,
}

/// The matches in one file.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ContentSearchFile {
    /// Environment-relative path.
    pub path: String,
    /// Its matches, in order.
    pub matches: Vec<ContentMatch>,
}

/// Lines whose text matched a content search, grouped by file.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ContentSearchResult {
    /// Files in the order their first match arrived.
    pub files: Vec<ContentSearchFile>,
    /// The server stopped at the limit.
    pub truncated: bool,
    /// A server warning to show next to the results.
    pub warning: Option<String>,
}

/// A file-name search.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PathSearchQuery {
    /// The text to find in names and paths.
    pub query: String,
    /// The directory to search under; `""` for the root.
    #[uniffi(default)]
    pub under: String,
    /// Globs a match must satisfy.
    #[uniffi(default)]
    pub include: Vec<String>,
    /// Globs that exclude a match.
    #[uniffi(default)]
    pub exclude: Vec<String>,
    /// The most matches; `None` for the server maximum.
    #[uniffi(default)]
    pub limit: Option<u32>,
}

/// A content search.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ContentSearchQuery {
    /// The text or pattern.
    pub query: String,
    /// Match case.
    #[uniffi(default)]
    pub case_sensitive: bool,
    /// `query` is a regular expression.
    #[uniffi(default)]
    pub regex: bool,
    /// Globs a file must satisfy.
    #[uniffi(default)]
    pub include: Vec<String>,
    /// Globs that exclude a file.
    #[uniffi(default)]
    pub exclude: Vec<String>,
    /// The most matches; `None` for the server maximum.
    #[uniffi(default)]
    pub limit: Option<u32>,
}

/// What kind of line a diff line is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum DiffLineKind {
    /// Unchanged.
    Context,
    /// Added.
    Added,
    /// Removed.
    Removed,
}

/// One line of a hunk.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct DiffLine {
    /// The kind.
    pub kind: DiffLineKind,
    /// The line number before, for context and removed lines.
    pub old_number: Option<u64>,
    /// The line number after, for context and added lines.
    pub new_number: Option<u64>,
    /// The text, without its terminator.
    pub text: String,
    /// The line has no terminating newline.
    pub missing_newline: bool,
}

/// One hunk.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct DiffHunk {
    /// First old line.
    pub old_start: u64,
    /// Old line count.
    pub old_count: u64,
    /// First new line.
    pub new_start: u64,
    /// New line count.
    pub new_count: u64,
    /// The section heading after `@@`, if any.
    pub section: String,
    /// `@@ -a,b +c,d @@ section`.
    pub header: String,
    /// The lines.
    pub lines: Vec<DiffLine>,
}

/// How a file changed in a diff.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
#[allow(missing_docs, reason = "variant names are the change kinds")]
pub enum FileChangeKind {
    Added,
    Deleted,
    Modified,
    Renamed,
    Copied,
}

/// One side of a side-by-side row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SplitCell {
    /// The kind.
    pub kind: DiffLineKind,
    /// The line number on this side.
    pub number: u64,
    /// The text.
    pub text: String,
    /// The changed span within `text`, in UTF-8 bytes, for paired changed lines.
    pub changed: Option<TextRange>,
}

/// One side-by-side row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SplitRow {
    /// A hunk header.
    Hunk {
        /// The hunk's index.
        index: u64,
        /// Its header.
        header: String,
    },
    /// A line pair.
    Line {
        /// The old side.
        left: Option<SplitCell>,
        /// The new side.
        right: Option<SplitCell>,
    },
}

/// One file's diff.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct FileDiff {
    /// The path before.
    pub old_path: Option<String>,
    /// The path after.
    pub new_path: Option<String>,
    /// How it changed.
    pub change: FileChangeKind,
    /// Hunks.
    pub hunks: Vec<DiffHunk>,
    /// Side-by-side rows.
    pub split_rows: Vec<SplitRow>,
    /// Added lines.
    pub added: u64,
    /// Removed lines.
    pub removed: u64,
    /// A binary file: no hunks.
    pub binary: bool,
    /// The diff is approximate (the edit was too costly to minimise).
    pub approximate: bool,
    /// Too large to diff: no hunks.
    pub too_large: bool,
    /// The path to show.
    pub display_path: String,
    /// No differences.
    pub is_identical: bool,
}

fn entry(entry: core::WorkspaceEntry) -> WorkspaceEntry {
    WorkspaceEntry {
        path: entry.path.as_str().to_owned(),
        name: entry.name,
        kind: match entry.kind {
            core::EntryKind::File => WorkspaceEntryKind::File,
            core::EntryKind::Directory => WorkspaceEntryKind::Directory,
            core::EntryKind::Symlink => WorkspaceEntryKind::Symlink,
            core::EntryKind::Other => WorkspaceEntryKind::Other,
            core::EntryKind::Unknown(value) => WorkspaceEntryKind::Unknown { value },
        },
        size: entry.size,
        modified_at: entry.modified_at,
    }
}

const fn range(range: core::TextRange) -> TextRange {
    TextRange {
        start: range.start,
        end: range.end,
    }
}

const fn line_kind(kind: core::DiffLineKind) -> DiffLineKind {
    match kind {
        core::DiffLineKind::Context => DiffLineKind::Context,
        core::DiffLineKind::Added => DiffLineKind::Added,
        core::DiffLineKind::Removed => DiffLineKind::Removed,
    }
}

fn split_cell(cell: core::SplitCell) -> SplitCell {
    SplitCell {
        kind: line_kind(cell.kind),
        number: cell.number,
        text: cell.text,
        changed: cell.changed.map(range),
    }
}

impl From<core::FileDiff> for FileDiff {
    fn from(diff: core::FileDiff) -> Self {
        let stats = diff.stats();
        let split_rows = diff
            .side_by_side()
            .into_iter()
            .map(|row| match row {
                core::SplitRow::Hunk { index, header } => SplitRow::Hunk {
                    index: u64::try_from(index).unwrap_or(u64::MAX),
                    header,
                },
                core::SplitRow::Line { left, right } => SplitRow::Line {
                    left: left.map(split_cell),
                    right: right.map(split_cell),
                },
            })
            .collect();
        Self {
            display_path: diff.display_path().to_owned(),
            is_identical: diff.is_identical(),
            change: match diff.change {
                core::FileChangeKind::Added => FileChangeKind::Added,
                core::FileChangeKind::Deleted => FileChangeKind::Deleted,
                core::FileChangeKind::Modified => FileChangeKind::Modified,
                core::FileChangeKind::Renamed => FileChangeKind::Renamed,
                core::FileChangeKind::Copied => FileChangeKind::Copied,
            },
            hunks: diff
                .hunks
                .into_iter()
                .map(|hunk| DiffHunk {
                    header: hunk.header(),
                    old_start: hunk.old_start,
                    old_count: hunk.old_count,
                    new_start: hunk.new_start,
                    new_count: hunk.new_count,
                    section: hunk.section,
                    lines: hunk
                        .lines
                        .into_iter()
                        .map(|line| DiffLine {
                            kind: line_kind(line.kind),
                            old_number: line.old_number,
                            new_number: line.new_number,
                            text: line.text,
                            missing_newline: line.missing_newline,
                        })
                        .collect(),
                })
                .collect(),
            split_rows,
            added: stats.added,
            removed: stats.removed,
            old_path: diff.old_path,
            new_path: diff.new_path,
            binary: diff.binary,
            approximate: diff.approximate,
            too_large: diff.too_large,
        }
    }
}

const fn syntax(language: core::SyntaxLanguage) -> SyntaxLanguage {
    use core::SyntaxLanguage as L;
    match language {
        L::Bash => SyntaxLanguage::Bash,
        L::C => SyntaxLanguage::C,
        L::Cpp => SyntaxLanguage::Cpp,
        L::CSharp => SyntaxLanguage::CSharp,
        L::Css => SyntaxLanguage::Css,
        L::Dockerfile => SyntaxLanguage::Dockerfile,
        L::Go => SyntaxLanguage::Go,
        L::Html => SyntaxLanguage::Html,
        L::Java => SyntaxLanguage::Java,
        L::JavaScript => SyntaxLanguage::JavaScript,
        L::Json => SyntaxLanguage::Json,
        L::Kotlin => SyntaxLanguage::Kotlin,
        L::Makefile => SyntaxLanguage::Makefile,
        L::Markdown => SyntaxLanguage::Markdown,
        L::ObjectiveC => SyntaxLanguage::ObjectiveC,
        L::Php => SyntaxLanguage::Php,
        L::Python => SyntaxLanguage::Python,
        L::Ruby => SyntaxLanguage::Ruby,
        L::Rust => SyntaxLanguage::Rust,
        L::Scala => SyntaxLanguage::Scala,
        L::Sql => SyntaxLanguage::Sql,
        L::Swift => SyntaxLanguage::Swift,
        L::Toml => SyntaxLanguage::Toml,
        L::TypeScript => SyntaxLanguage::TypeScript,
        L::Xml => SyntaxLanguage::Xml,
        L::Yaml => SyntaxLanguage::Yaml,
    }
}

fn preview(preview: core::FilePreview) -> FilePreview {
    match preview {
        core::FilePreview::Text(text) => FilePreview::Text {
            preview: TextPreview {
                text: text.text,
                line_count: text.line_count,
                line_ending: match text.line_ending {
                    core::LineEnding::Lf => LineEnding::Lf,
                    core::LineEnding::CrLf => LineEnding::CrLf,
                    core::LineEnding::Mixed => LineEnding::Mixed,
                },
                has_bom: text.has_bom,
                language: text.language.map(syntax),
                skip_highlighting: text.skip_highlighting,
                clipped: text.clipped,
                server_truncated: text.server_truncated,
            },
        },
        core::FilePreview::Image { format, bytes } => FilePreview::Image {
            format: match format {
                core::ImageFormat::Png => ImageFormat::Png,
                core::ImageFormat::Jpeg => ImageFormat::Jpeg,
                core::ImageFormat::Gif => ImageFormat::Gif,
                core::ImageFormat::Webp => ImageFormat::Webp,
                core::ImageFormat::Bmp => ImageFormat::Bmp,
                core::ImageFormat::Tiff => ImageFormat::Tiff,
                core::ImageFormat::Heic => ImageFormat::Heic,
                core::ImageFormat::Ico => ImageFormat::Ico,
            },
            data: bytes,
        },
        core::FilePreview::Binary { reason, byte_count } => FilePreview::Binary {
            reason: match reason {
                core::BinaryReason::NotText => BinaryReason::NotText,
                core::BinaryReason::NulBytes => BinaryReason::NulBytes,
                core::BinaryReason::TruncatedImage => BinaryReason::TruncatedImage,
            },
            byte_count,
        },
    }
}

fn environment(environment: core::WorkspaceEnvironment) -> WorkspaceEnvironment {
    WorkspaceEnvironment {
        is_primary: environment.is_primary(),
        id: environment.id,
        name: environment.name,
        role: environment.role,
        environment_type: environment.environment_type,
        root: environment.root,
        home: environment.home,
        unconfined: environment.unconfined,
    }
}

fn changes(list: &core::ChangesList) -> WorkspaceChanges {
    let totals = list.totals();
    WorkspaceChanges {
        files: list
            .sorted_by_path()
            .into_iter()
            .map(|file| WorkspaceChangedFile {
                path: file.path.as_str().to_owned(),
                status: match file.status {
                    core::ChangeStatus::Created => WorkspaceChangeStatus::Created,
                    core::ChangeStatus::Modified => WorkspaceChangeStatus::Modified,
                    core::ChangeStatus::Deleted => WorkspaceChangeStatus::Deleted,
                    core::ChangeStatus::Unknown(value) => WorkspaceChangeStatus::Unknown { value },
                },
                size: file.size,
                modified_at: file.modified_at,
                lines_added: file.lines_added,
                lines_removed: file.lines_removed,
            })
            .collect(),
        totals: WorkspaceChangeTotals {
            created: totals.created,
            modified: totals.modified,
            deleted: totals.deleted,
            lines_added: totals.lines_added,
            lines_removed: totals.lines_removed,
        },
        has_more: list.has_more,
    }
}

fn content_result(result: &core::ContentSearchResult) -> ContentSearchResult {
    let content_match = |found: core::ContentMatch| ContentMatch {
        path: found.path.as_str().to_owned(),
        line: found.line,
        column: found.column,
        text: found.text,
        match_utf16: range(found.match_utf16),
        match_utf8: range(found.match_utf8),
    };
    ContentSearchResult {
        files: result
            .files()
            .into_iter()
            .map(|file| ContentSearchFile {
                path: file.path.as_str().to_owned(),
                matches: file.matches.into_iter().map(content_match).collect(),
            })
            .collect(),
        truncated: result.truncated,
        warning: result.warning.clone(),
    }
}

fn parse(path: &str) -> Result<core::WorkspacePath, CoreError> {
    core::WorkspacePath::parse(path).map_err(path_error)
}

/// What saving an edited file did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum WorkspaceSave {
    /// The new content was written.
    Saved {
        /// The save created the file.
        created: bool,
    },
    /// The file changed since it was read, so nothing was written.
    Conflict {
        /// Its text now; `None` when it was deleted or is no longer readable text.
        latest: Option<String>,
    },
}

impl From<core::FileSave> for WorkspaceSave {
    fn from(save: core::FileSave) -> Self {
        match save {
            core::FileSave::Saved(written) => Self::Saved {
                created: written.created,
            },
            core::FileSave::Conflict { latest } => Self::Conflict { latest },
        }
    }
}

fn parse_file(path: &str) -> Result<core::WorkspacePath, CoreError> {
    core::WorkspacePath::parse_file(path).map_err(path_error)
}

/// The normalized form of an environment-relative path, or why it cannot be sent.
///
/// # Errors
///
/// [`CoreError::Workspace`] kind `InvalidInput`.
#[uniffi::export]
pub fn normalize_workspace_path(path: String) -> Result<String, CoreError> {
    parse(&path).map(|path| path.as_str().to_owned())
}

/// The absolute location of `path` under the environment `root` the server reported, for
/// "Reveal in Finder" or "Copy absolute path". Only meaningful on the machine running the
/// environment.
///
/// # Errors
///
/// [`CoreError::Workspace`] kind `InvalidInput` for a path that cannot be inside the workspace.
#[uniffi::export]
pub fn absolute_location(root: String, path: String) -> Result<String, CoreError> {
    Ok(core::absolute_location(&root, &parse(&path)?))
}

/// The globs of a comma- or whitespace-separated filter field.
#[must_use]
#[uniffi::export]
pub fn split_workspace_globs(raw: String) -> Vec<String> {
    core::split_globs(&raw)
}

/// Parses `git diff` or plain unified-diff text into one diff per file.
///
/// # Errors
///
/// [`CoreError::Decode`] with the line that could not be read.
#[uniffi::export]
pub fn parse_unified_diff(patch: String) -> Result<Vec<FileDiff>, CoreError> {
    core::parse_unified(&patch)
        .map(|diffs| diffs.into_iter().map(Into::into).collect())
        .map_err(|error| CoreError::Decode {
            message: error.to_string(),
        })
}

/// The diff of `before` and `after` (either absent for an added or deleted file).
#[must_use]
#[uniffi::export]
pub fn diff_workspace_texts(
    old_path: Option<String>,
    new_path: Option<String>,
    before: Option<String>,
    after: Option<String>,
) -> FileDiff {
    core::diff_texts(
        old_path.as_deref(),
        new_path.as_deref(),
        before.as_deref(),
        after.as_deref(),
        &core::DiffOptions::default(),
    )
    .into()
}

#[uniffi::export]
impl ClientCore {
    /// The session's environments.
    ///
    /// # Errors
    ///
    /// [`CoreError::Workspace`].
    pub async fn workspace_environments(
        &self,
        session_id: String,
    ) -> Result<Vec<WorkspaceEnvironment>, CoreError> {
        self.sessions()
            .workspace_environments(&session_id)
            .await
            .map(|environments| environments.into_iter().map(environment).collect())
            .map_err(workspace_error)
    }

    /// One environment, including its absolute root when the server reports it.
    ///
    /// # Errors
    ///
    /// [`CoreError::Workspace`].
    pub async fn workspace_environment(
        &self,
        session_id: String,
        environment_id: String,
    ) -> Result<WorkspaceEnvironment, CoreError> {
        self.sessions()
            .workspace_environment(&session_id, &environment_id)
            .await
            .map(environment)
            .map_err(workspace_error)
    }

    /// One page of the directory `path` (`""` for the root), in tree order. `after` is the
    /// previous page's `next_cursor`; `limit` defaults to the server maximum.
    ///
    /// # Errors
    ///
    /// [`CoreError::Workspace`]; kind `Server` when `path` is a file.
    pub async fn list_workspace_directory(
        &self,
        session_id: String,
        environment_id: String,
        path: String,
        after: Option<String>,
        limit: Option<u32>,
    ) -> Result<WorkspaceDirectoryPage, CoreError> {
        let mut query = core::DirectoryQuery::first_page(parse(&path)?);
        query.after = after;
        if let Some(limit) = limit {
            query.limit = limit;
        }
        let page = self
            .sessions()
            .list_workspace_directory(&session_id, &environment_id, query)
            .await
            .map_err(workspace_error)?;
        let mut entries = page.entries;
        core::sort_for_tree(&mut entries);
        Ok(WorkspaceDirectoryPage {
            directory: page.directory.as_str().to_owned(),
            entries: entries.into_iter().map(entry).collect(),
            next_cursor: page.next_cursor,
        })
    }

    /// The file `path` and its preview (text with its facts, an image, or why it is binary).
    ///
    /// # Errors
    ///
    /// [`CoreError::Workspace`]; kind `InvalidInput` for the root, `Server` for a directory.
    pub async fn read_workspace_file(
        &self,
        session_id: String,
        environment_id: String,
        path: String,
    ) -> Result<WorkspaceFile, CoreError> {
        let content = self
            .sessions()
            .read_workspace_file(&session_id, &environment_id, parse_file(&path)?)
            .await
            .map_err(workspace_error)?;
        Ok(WorkspaceFile {
            preview: preview(content.preview(&core::PreviewLimits::default())),
            path: content.path.as_str().to_owned(),
            content_type: content.content_type,
            byte_count: content.byte_count,
            truncated: content.truncated,
        })
    }

    /// The file `path`'s content as bytes, for sharing it or opening it in another app.
    ///
    /// # Errors
    ///
    /// [`CoreError::Workspace`]; kind `InvalidInput` for the root, `Server` for a directory.
    pub async fn read_workspace_file_bytes(
        &self,
        session_id: String,
        environment_id: String,
        path: String,
    ) -> Result<WorkspaceFileBytes, CoreError> {
        let content = self
            .sessions()
            .read_workspace_file(&session_id, &environment_id, parse_file(&path)?)
            .await
            .map_err(workspace_error)?;
        Ok(WorkspaceFileBytes {
            path: content.path.as_str().to_owned(),
            content_type: content.content_type,
            truncated: content.truncated,
            bytes: match content.body {
                core::FileBody::Text(text) => text.into_bytes(),
                core::FileBody::Binary(bytes) => bytes,
            },
        })
    }

    /// Saves `content` as the file `path`. With `base` (the text the edit started from), the
    /// file is read first and a change by someone else since is returned as a conflict, with
    /// nothing written; without it the file is overwritten.
    ///
    /// # Errors
    ///
    /// [`CoreError::Workspace`]; kind `Forbidden` without edit access.
    pub async fn save_workspace_file(
        &self,
        session_id: String,
        environment_id: String,
        path: String,
        content: String,
        base: Option<String>,
    ) -> Result<WorkspaceSave, CoreError> {
        self.sessions()
            .save_workspace_file(
                &session_id,
                &environment_id,
                parse_file(&path)?,
                content,
                base.as_deref(),
            )
            .await
            .map(Into::into)
            .map_err(workspace_error)
    }

    /// Files whose name or path contains the query.
    ///
    /// # Errors
    ///
    /// [`CoreError::Workspace`].
    pub async fn search_workspace_paths(
        &self,
        session_id: String,
        environment_id: String,
        query: PathSearchQuery,
    ) -> Result<WorkspacePathSearchResult, CoreError> {
        let mut search = core::PathSearchQuery::new(query.query);
        search.under = parse(&query.under)?;
        search.include = query.include;
        search.exclude = query.exclude;
        if let Some(limit) = query.limit {
            search.limit = limit;
        }
        let result = self
            .sessions()
            .search_workspace_paths(&session_id, &environment_id, search)
            .await
            .map_err(workspace_error)?;
        Ok(WorkspacePathSearchResult {
            directory: result.directory.as_str().to_owned(),
            entries: result.entries.into_iter().map(entry).collect(),
            has_more: result.has_more,
            truncated: result.truncated,
        })
    }

    /// Lines whose text matches the query, grouped by file.
    ///
    /// # Errors
    ///
    /// [`CoreError::Workspace`]; kind `SearchFailed` when the search failed (an invalid regular
    /// expression) and `SearchDisabled` when the server has the feature off.
    pub async fn search_workspace_content(
        &self,
        session_id: String,
        environment_id: String,
        query: ContentSearchQuery,
    ) -> Result<ContentSearchResult, CoreError> {
        let mut search = core::ContentSearchQuery::new(query.query);
        search.case_sensitive = query.case_sensitive;
        search.regex = query.regex;
        search.include = query.include;
        search.exclude = query.exclude;
        if let Some(limit) = query.limit {
            search.limit = limit;
        }
        self.sessions()
            .search_workspace_content(&session_id, &environment_id, search)
            .await
            .map(|result| content_result(&result))
            .map_err(workspace_error)
    }

    /// Every file changed this session, sorted by path, with totals.
    ///
    /// # Errors
    ///
    /// [`CoreError::Workspace`]; kind `Unavailable` when git failed.
    pub async fn workspace_changes(
        &self,
        session_id: String,
        environment_id: String,
    ) -> Result<WorkspaceChanges, CoreError> {
        self.sessions()
            .workspace_changes(&session_id, &environment_id)
            .await
            .map(|list| changes(&list))
            .map_err(workspace_error)
    }

    /// The diff of the changed file `path`, computed by the core from the server's before and
    /// after text, with side-by-side rows.
    ///
    /// # Errors
    ///
    /// [`CoreError::Workspace`]; kind `NotChanged` for a file with no changes.
    pub async fn workspace_file_diff(
        &self,
        session_id: String,
        environment_id: String,
        path: String,
    ) -> Result<FileDiff, CoreError> {
        self.sessions()
            .workspace_file_diff(&session_id, &environment_id, parse_file(&path)?)
            .await
            .map(|content| content.diff(&core::DiffOptions::default()).into())
            .map_err(workspace_error)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[allow(clippy::too_many_lines, reason = "one case per error kind")]
    fn workspace_errors_keep_their_kind() {
        use omnigent_core::workspace::WorkspaceError as E;
        let cases = [
            (
                E::InvalidPath(omnigent_core::workspace::PathError::Traversal),
                WorkspaceErrorKind::InvalidInput,
            ),
            (
                E::Session(omnigent_core::SessionError::NotConnected),
                WorkspaceErrorKind::NotConnected,
            ),
            (
                E::NotFound {
                    path: "a".into(),
                    message: "gone".into(),
                },
                WorkspaceErrorKind::NotFound,
            ),
            (
                E::NotChanged { path: "a".into() },
                WorkspaceErrorKind::NotChanged,
            ),
            (
                E::RunnerOffline {
                    message: "offline".into(),
                },
                WorkspaceErrorKind::RunnerOffline,
            ),
            (E::ContentSearchDisabled, WorkspaceErrorKind::SearchDisabled),
            (
                E::SearchFailed {
                    message: "regex".into(),
                },
                WorkspaceErrorKind::SearchFailed,
            ),
            (
                E::PathUnreachable {
                    message: "outside".into(),
                    reachable_roots: vec!["/w".into()],
                },
                WorkspaceErrorKind::Forbidden,
            ),
            (
                E::ChangesUnavailable {
                    message: "git".into(),
                },
                WorkspaceErrorKind::Unavailable,
            ),
            (
                E::MalformedResponse { detail: "x".into() },
                WorkspaceErrorKind::Server,
            ),
        ];
        for (error, expected) in cases {
            let message = error.to_string();
            let CoreError::Workspace {
                kind,
                message: shown,
                requires_sign_in,
            } = workspace_error(error)
            else {
                panic!("not a workspace error");
            };
            assert_eq!(kind, expected, "{message}");
            assert_eq!(shown, message);
            assert_eq!(
                requires_sign_in,
                expected == WorkspaceErrorKind::NotConnected,
                "{message}"
            );
        }
        let CoreError::Workspace {
            requires_sign_in, ..
        } = workspace_error(E::Session(omnigent_core::SessionError::Unauthorized {
            reason: None,
        }))
        else {
            panic!("not a workspace error");
        };
        assert!(requires_sign_in);
    }

    #[test]
    fn paths_are_validated_before_any_request() {
        assert_eq!(
            normalize_workspace_path("src//lib.rs".into()).ok(),
            Some("src/lib.rs".into())
        );
        assert!(matches!(
            normalize_workspace_path("../etc".into()),
            Err(CoreError::Workspace {
                kind: WorkspaceErrorKind::InvalidInput,
                ..
            })
        ));
        assert_eq!(
            absolute_location("/work/repo/".into(), "src/main.rs".into()).ok(),
            Some("/work/repo/src/main.rs".into())
        );
        assert_eq!(
            absolute_location("/work/repo".into(), String::new()).ok(),
            Some("/work/repo".into())
        );
    }

    #[test]
    fn diffs_carry_stats_and_side_by_side_rows() {
        let diff = diff_workspace_texts(
            Some("a.txt".into()),
            Some("a.txt".into()),
            Some("one\ntwo\n".into()),
            Some("one\nthree\n".into()),
        );
        assert_eq!((diff.added, diff.removed), (1, 1));
        assert!(!diff.is_identical);
        assert_eq!(diff.display_path, "a.txt");
        assert!(matches!(
            diff.split_rows.first(),
            Some(SplitRow::Hunk { .. })
        ));
        assert!(diff.hunks[0].header.starts_with("@@ "));
        let parsed =
            parse_unified_diff("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n".into()).unwrap();
        assert_eq!(parsed.len(), 1);
        assert_eq!((parsed[0].added, parsed[0].removed), (1, 1));
    }
}
