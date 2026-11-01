//! Session workspace files: browsing, content, search and changes.
//!
//! Everything a files panel needs from the server, sans-IO:
//!
//! - [`path`]: [`WorkspacePath`], a normalized environment-relative path that cannot leave the
//!   root. Every path sent or received goes through it.
//! - [`request`]: [`WorkspaceRequest`], a validated request for one route, built into an
//!   `HttpRequest` and decoded from the `HttpResponse` with the workspace status policy.
//! - [`model`], [`content`] and [`search`]: the decoded records: directory pages with cursors,
//!   file content with binary, image and syntax detection, path search, content search with
//!   UTF-16 and UTF-8 match ranges, changed files, environments and session files.
//! - [`diff`]: a unified-diff model computed from the server's before/after text (pure Rust
//!   Myers) or parsed from a patch, with hunks, stats and side-by-side rows.
//! - [`error`]: [`WorkspaceError`], which keeps the server's reason for every failure.
//!
//! [`ClientCore`](crate::ClientCore) sends these through the host transport; see
//! `ClientCore::workspace` and the typed wrappers (`list_workspace_directory`,
//! `read_workspace_file`, `search_workspace_paths`, `search_workspace_content`,
//! `workspace_changes`, `workspace_file_diff`, `workspace_environments`, `session_files`).
//!
//! The ground truth is the server: `omnigent/server/routes/sessions/routes_resources.py` and the
//! runner's `omnigent/runner/resource_routes.py`, `environment_filesystem.py` and
//! `content_search.py`. Recorded responses are in `client-core/fixtures/workspace/`.

mod client;
pub mod content;
pub mod diff;
pub mod error;
pub mod model;
pub mod path;
pub mod request;
pub mod search;

pub use content::{
    BinaryReason, FileBody, FileContent, FilePreview, ImageFormat, LineEnding, PreviewLimits,
    SERVER_READ_CAP_BYTES, SyntaxLanguage, TextPreview, line_count,
};
pub use diff::{
    DiffHunk, DiffLine, DiffLineKind, DiffOptions, DiffParseError, DiffStats, FileChangeKind,
    FileDiff, SplitCell, SplitRow, diff_texts, parse_unified,
};
pub use error::WorkspaceError;
pub use model::{
    ChangeStatus, ChangeTotals, ChangedFileEntry, ChangesList, DirectoryPage, EntryKind,
    FileDiffContent, PathSearchResult, SessionFile, SessionFilesPage, WorkspaceEntry,
    WorkspaceEnvironment, sort_for_tree,
};
pub use path::{MAX_PATH_BYTES, PathError, WorkspacePath, absolute_location};
pub use request::{
    DEFAULT_ENVIRONMENT_ID, DirectoryQuery, MAX_DIRECTORY_LIMIT, SessionFilesQuery,
    WorkspaceOperation, WorkspaceRequest, WorkspaceResponse,
};
pub use search::{
    ContentMatch, ContentSearchFile, ContentSearchQuery, ContentSearchResult, MAX_QUERY_CHARS,
    MAX_SEARCH_LIMIT, PathSearchQuery, TextRange, split_globs, utf16_to_utf8,
};

#[cfg(test)]
mod tests;
