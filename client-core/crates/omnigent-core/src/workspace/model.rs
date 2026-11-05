//! Decoded workspace listings: directory pages, path search, changed files, environments and
//! session files.
//!
//! Shapes, as recorded in `client-core/fixtures/workspace/recorded-*.json`:
//!
//! - entry: `{id, object: "session.environment.filesystem.entry", name, path, type, bytes,
//!   modified_at}`, `type` one of `file`, `directory`, `symlink`, `other`;
//! - directory page: `{object: "list", base, data, first_id, last_id, has_more}`. Entry paths are
//!   environment-root-relative (`src/lib.rs` when listing `src`);
//! - path search: `{object: "list", base, data, has_more, truncated}`. Entry paths are relative
//!   to the directory searched (`lib.rs` when searching under `src`);
//! - changes: `{object: "list", data: [{path, name, status, bytes, modified_at, lines_added,
//!   lines_removed}], has_more}`. `NativeLab` also accepted `{entries: [...]}` and a bare array;
//!   both still decode.

use std::cmp::Ordering;

use serde_json::{Map, Value};

use super::error::WorkspaceError;
use super::path::WorkspacePath;
use crate::client::json::{as_object, opt_array, opt_bool, opt_object, opt_str, opt_u64, req_str};

/// What a filesystem entry is.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum EntryKind {
    /// A regular file.
    File,
    /// A directory.
    Directory,
    /// A symbolic link the server did not resolve.
    Symlink,
    /// A socket, device or other special file.
    Other,
    /// A type newer than this client.
    Unknown(String),
}

impl EntryKind {
    fn parse(raw: &str) -> Self {
        match raw {
            "file" => Self::File,
            "directory" => Self::Directory,
            "symlink" => Self::Symlink,
            "other" => Self::Other,
            other => Self::Unknown(other.to_owned()),
        }
    }

    /// Whether the entry can be expanded in a tree.
    #[must_use]
    pub const fn is_directory(&self) -> bool {
        matches!(self, Self::Directory)
    }
}

/// One file or directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceEntry {
    /// Environment-root-relative path.
    pub path: WorkspacePath,
    /// The base name.
    pub name: String,
    /// What it is.
    pub kind: EntryKind,
    /// Size in bytes, for files.
    pub size: Option<u64>,
    /// Last modification, Unix seconds.
    pub modified_at: Option<i64>,
}

/// How entry paths in a payload are rooted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Rooting {
    /// Root-relative; a path that is not inside the listed directory is resolved under it.
    Listing,
    /// Relative to the searched directory.
    Search,
}

/// Directories first, then names compared case-insensitively, then exactly: the order a file
/// tree shows.
pub fn sort_for_tree(entries: &mut [WorkspaceEntry]) {
    entries.sort_by(compare_for_tree);
}

fn compare_for_tree(left: &WorkspaceEntry, right: &WorkspaceEntry) -> Ordering {
    right
        .kind
        .is_directory()
        .cmp(&left.kind.is_directory())
        .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
        .then_with(|| left.name.cmp(&right.name))
}

/// One page of a directory listing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirectoryPage {
    /// The directory listed.
    pub directory: WorkspacePath,
    /// Entries in server order (ascending by id).
    pub entries: Vec<WorkspaceEntry>,
    /// Pass as `after` to read the next page; set exactly when there are more entries.
    pub next_cursor: Option<String>,
}

impl DirectoryPage {
    /// Whether more entries follow.
    #[must_use]
    pub const fn has_more(&self) -> bool {
        self.next_cursor.is_some()
    }
}

/// Matching entries from a path search.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathSearchResult {
    /// The directory searched.
    pub directory: WorkspacePath,
    /// Matches, environment-root-relative.
    pub entries: Vec<WorkspaceEntry>,
    /// The result limit was reached; there may be more matches.
    pub has_more: bool,
    /// The server stopped scanning before it covered the tree, so a missing file may exist.
    pub truncated: bool,
}

/// How a file changed this session.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ChangeStatus {
    /// New this session.
    Created,
    /// Changed (git reports renames and copies as a change to the new path).
    Modified,
    /// Removed.
    Deleted,
    /// A status newer than this client.
    Unknown(String),
}

impl ChangeStatus {
    fn parse(raw: &str) -> Self {
        match raw {
            "created" | "added" => Self::Created,
            "modified" => Self::Modified,
            "deleted" => Self::Deleted,
            other => Self::Unknown(other.to_owned()),
        }
    }
}

/// One changed file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangedFileEntry {
    /// Environment-root-relative path.
    pub path: WorkspacePath,
    /// The status.
    pub status: ChangeStatus,
    /// Current size in bytes; `None` for a deleted file.
    pub size: Option<u64>,
    /// Last modification, Unix seconds.
    pub modified_at: Option<i64>,
    /// Lines added, when the server could count them (not for binary or untracked files).
    pub lines_added: Option<u64>,
    /// Lines removed, when known.
    pub lines_removed: Option<u64>,
}

/// The session's changed files.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangesList {
    /// Entries in server order (newest first).
    pub entries: Vec<ChangedFileEntry>,
    /// The server capped the list.
    pub has_more: bool,
}

impl ChangesList {
    /// Totals across entries; unknown counts are skipped.
    #[must_use]
    pub fn totals(&self) -> ChangeTotals {
        let mut totals = ChangeTotals::default();
        for entry in &self.entries {
            match entry.status {
                ChangeStatus::Created => totals.created += 1,
                ChangeStatus::Modified | ChangeStatus::Unknown(_) => totals.modified += 1,
                ChangeStatus::Deleted => totals.deleted += 1,
            }
            totals.lines_added += entry.lines_added.unwrap_or(0);
            totals.lines_removed += entry.lines_removed.unwrap_or(0);
        }
        totals
    }

    /// Entries sorted by path, for a stable list.
    #[must_use]
    pub fn sorted_by_path(&self) -> Vec<ChangedFileEntry> {
        let mut entries = self.entries.clone();
        entries.sort_by(|left, right| left.path.cmp(&right.path));
        entries
    }
}

/// Summary counts for a [`ChangesList`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ChangeTotals {
    /// Created files.
    pub created: u64,
    /// Modified files (including unknown statuses).
    pub modified: u64,
    /// Deleted files.
    pub deleted: u64,
    /// Known added lines.
    pub lines_added: u64,
    /// Known removed lines.
    pub lines_removed: u64,
}

/// The before and after text the server keeps for a changed file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileDiffContent {
    /// Environment-root-relative path.
    pub path: WorkspacePath,
    /// Content before the session's first change; `None` for a new (or renamed-to) file.
    pub before: Option<String>,
    /// Current content; `None` for a deleted file.
    pub after: Option<String>,
}

/// One environment of a session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceEnvironment {
    /// The id to address it by, for example `default`.
    pub id: String,
    /// Display name.
    pub name: Option<String>,
    /// `primary`, `terminal`, ...
    pub role: Option<String>,
    /// For example `caller_process`.
    pub environment_type: Option<String>,
    /// The absolute root on the machine that runs it, when reported.
    pub root: Option<String>,
    /// The home directory on that machine, to expand `~` in cited paths, when reported.
    pub home: Option<String>,
    /// Whether the environment is unconfined (`sandbox.type: none`), when reported.
    pub unconfined: Option<bool>,
}

impl WorkspaceEnvironment {
    /// Whether this is the session's primary environment.
    #[must_use]
    pub fn is_primary(&self) -> bool {
        self.role.as_deref() == Some("primary") || self.id == "default"
    }
}

/// A file uploaded to the session (`/resources/files`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionFile {
    /// The file id.
    pub id: String,
    /// The original file name.
    pub filename: String,
    /// Size in bytes, when reported.
    pub size: Option<u64>,
    /// Upload time, Unix seconds.
    pub created_at: Option<i64>,
}

/// One page of session files.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionFilesPage {
    /// Files in server order.
    pub files: Vec<SessionFile>,
    /// Pass as `after` to read the next page; set exactly when there are more.
    pub next_cursor: Option<String>,
}

// Decoding.

pub(super) fn opt_i64(object: &Map<String, Value>, key: &str) -> Result<Option<i64>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_i64()
            .map(Some)
            .ok_or_else(|| format!("`{key}` is not an integer")),
    }
}

fn server_path(raw: &str) -> Result<WorkspacePath, String> {
    WorkspacePath::parse(raw)
        .map_err(|error| format!("unsafe path {raw:?} from the server: {error}"))
}

pub(super) fn entry(
    value: &Value,
    directory: &WorkspacePath,
    rooting: Rooting,
) -> Result<WorkspaceEntry, String> {
    let object = as_object(value, "entry")?;
    let raw = req_str(object, "path")?;
    let relative = server_path(&raw)?;
    let path = match rooting {
        Rooting::Listing if relative.is_within(directory) => relative,
        Rooting::Listing | Rooting::Search => directory
            .join(relative.as_str())
            .map_err(|error| format!("unsafe path {raw:?}: {error}"))?,
    };
    if path.is_root() {
        return Err("an entry names the environment root".to_owned());
    }
    let name = opt_str(object, "name")?
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| path.name().to_owned());
    let kind = EntryKind::parse(&req_str(object, "type")?);
    Ok(WorkspaceEntry {
        path,
        name,
        kind,
        size: opt_u64(object, "bytes")?,
        modified_at: opt_i64(object, "modified_at")?,
    })
}

fn list_data(object: &Map<String, Value>) -> Result<&Vec<Value>, String> {
    opt_array(object, "data")?.ok_or_else(|| "`data` is missing".to_owned())
}

/// Rejects a file payload where a listing was expected.
fn require_list(object: &Map<String, Value>, path: &WorkspacePath) -> Result<(), WorkspaceError> {
    match opt_str(object, "object").map_err(|error| WorkspaceError::malformed("listing", error))? {
        Some(kind) if kind.ends_with("file_content") => Err(WorkspaceError::UnexpectedKind {
            path: path.to_string(),
            expected: "directory",
            actual: "file",
        }),
        _ => Ok(()),
    }
}

/// The next cursor of a `has_more` page: `last_id`, which must be new.
fn next_cursor(
    object: &Map<String, Value>,
    after: Option<&str>,
    has_more: bool,
) -> Result<Option<String>, String> {
    if !has_more {
        return Ok(None);
    }
    match opt_str(object, "last_id")? {
        Some(last) if !last.is_empty() && Some(last.as_str()) != after => Ok(Some(last)),
        _ => Err("`has_more` is true without a new `last_id` cursor".to_owned()),
    }
}

pub(super) fn directory_page(
    value: &Value,
    directory: &WorkspacePath,
    after: Option<&str>,
) -> Result<DirectoryPage, WorkspaceError> {
    let context = "directory listing";
    let object = as_object(value, context).map_err(|e| WorkspaceError::malformed(context, e))?;
    require_list(object, directory)?;
    let decode = || -> Result<DirectoryPage, String> {
        let entries = list_data(object)?
            .iter()
            .map(|value| entry(value, directory, Rooting::Listing))
            .collect::<Result<Vec<_>, _>>()?;
        let has_more = opt_bool(object, "has_more")?.unwrap_or(false);
        Ok(DirectoryPage {
            directory: directory.clone(),
            entries,
            next_cursor: next_cursor(object, after, has_more)?,
        })
    };
    decode().map_err(|error| WorkspaceError::malformed(context, error))
}

pub(super) fn path_search(
    value: &Value,
    directory: &WorkspacePath,
) -> Result<PathSearchResult, WorkspaceError> {
    let context = "path search";
    let decode = || -> Result<PathSearchResult, String> {
        let object = as_object(value, context)?;
        let entries = list_data(object)?
            .iter()
            .map(|value| entry(value, directory, Rooting::Search))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(PathSearchResult {
            directory: directory.clone(),
            entries,
            has_more: opt_bool(object, "has_more")?.unwrap_or(false),
            truncated: opt_bool(object, "truncated")?.unwrap_or(false),
        })
    };
    decode().map_err(|error| WorkspaceError::malformed(context, error))
}

fn changed_entry(value: &Value) -> Result<ChangedFileEntry, String> {
    let object = as_object(value, "change")?;
    let path = server_path(&req_str(object, "path")?)?;
    if path.is_root() {
        return Err("a change names the environment root".to_owned());
    }
    let status = opt_str(object, "status")?.map_or_else(
        || ChangeStatus::Unknown(String::new()),
        |status| ChangeStatus::parse(&status),
    );
    Ok(ChangedFileEntry {
        path,
        status,
        size: opt_u64(object, "bytes")?,
        modified_at: opt_i64(object, "modified_at")?,
        lines_added: opt_u64(object, "lines_added")?,
        lines_removed: opt_u64(object, "lines_removed")?,
    })
}

pub(super) fn changes(value: &Value) -> Result<ChangesList, WorkspaceError> {
    let context = "changed files";
    let decode = || -> Result<ChangesList, String> {
        let (entries, has_more) = match value {
            Value::Array(entries) => (entries, false),
            Value::Object(object) => {
                let Some(entries) = opt_array(object, "data")?.or(opt_array(object, "entries")?)
                else {
                    return Err("`data` is missing".to_owned());
                };
                (entries, opt_bool(object, "has_more")?.unwrap_or(false))
            }
            _ => return Err("changes is not an object".to_owned()),
        };
        Ok(ChangesList {
            entries: entries
                .iter()
                .map(changed_entry)
                .collect::<Result<Vec<_>, _>>()?,
            has_more,
        })
    };
    decode().map_err(|error| WorkspaceError::malformed(context, error))
}

pub(super) fn file_diff(
    value: &Value,
    requested: &WorkspacePath,
) -> Result<FileDiffContent, WorkspaceError> {
    let context = "file diff";
    let decode = || -> Result<FileDiffContent, String> {
        let object = as_object(value, context)?;
        let path = match opt_str(object, "path")? {
            Some(raw) => server_path(&raw)?,
            None => requested.clone(),
        };
        if &path != requested {
            return Err(format!("asked for {requested}, got {path}"));
        }
        Ok(FileDiffContent {
            path,
            before: opt_str(object, "before")?,
            after: opt_str(object, "after")?,
        })
    };
    decode().map_err(|error| WorkspaceError::malformed(context, error))
}

fn environment(value: &Value) -> Result<WorkspaceEnvironment, String> {
    let object = as_object(value, "environment")?;
    let empty = Map::new();
    let metadata = opt_object(object, "metadata")?.unwrap_or(&empty);
    let reachable = opt_object(metadata, "reachable")?;
    Ok(WorkspaceEnvironment {
        id: req_str(object, "id")?,
        name: opt_str(object, "name")?,
        role: opt_str(metadata, "role")?,
        environment_type: opt_str(metadata, "environment_type")?,
        root: opt_str(metadata, "root")?,
        home: opt_str(metadata, "home")?,
        unconfined: reachable
            .map(|reachable| opt_bool(reachable, "unconfined"))
            .transpose()?
            .flatten(),
    })
}

pub(super) fn environments(value: &Value) -> Result<Vec<WorkspaceEnvironment>, WorkspaceError> {
    let context = "environments";
    let decode = || -> Result<Vec<WorkspaceEnvironment>, String> {
        let object = as_object(value, context)?;
        list_data(object)?.iter().map(environment).collect()
    };
    decode().map_err(|error| WorkspaceError::malformed(context, error))
}

pub(super) fn single_environment(value: &Value) -> Result<WorkspaceEnvironment, WorkspaceError> {
    environment(value).map_err(|error| WorkspaceError::malformed("environment", error))
}

fn session_file(value: &Value) -> Result<SessionFile, String> {
    let object = as_object(value, "file")?;
    let empty = Map::new();
    let metadata = opt_object(object, "metadata")?.unwrap_or(&empty);
    let filename = match opt_str(metadata, "filename")? {
        Some(name) => name,
        None => opt_str(object, "name")?.ok_or("`metadata.filename` is missing")?,
    };
    Ok(SessionFile {
        id: req_str(object, "id")?,
        filename,
        size: opt_u64(metadata, "bytes")?,
        created_at: opt_i64(metadata, "created_at")?,
    })
}

pub(super) fn session_files(
    value: &Value,
    after: Option<&str>,
) -> Result<SessionFilesPage, WorkspaceError> {
    let context = "session files";
    let decode = || -> Result<SessionFilesPage, String> {
        let object = as_object(value, context)?;
        let files = list_data(object)?
            .iter()
            .map(session_file)
            .collect::<Result<Vec<_>, _>>()?;
        let has_more = opt_bool(object, "has_more")?.unwrap_or(false);
        Ok(SessionFilesPage {
            files,
            next_cursor: next_cursor(object, after, has_more)?,
        })
    };
    decode().map_err(|error| WorkspaceError::malformed(context, error))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(path: &str, name: &str, kind: EntryKind) -> WorkspaceEntry {
        WorkspaceEntry {
            path: WorkspacePath::parse(path).unwrap(),
            name: name.to_owned(),
            kind,
            size: None,
            modified_at: None,
        }
    }

    #[test]
    fn tree_order_puts_directories_first_then_names_case_insensitively() {
        let mut entries = vec![
            file("b.rs", "b.rs", EntryKind::File),
            file("Zeta", "Zeta", EntryKind::Directory),
            file("A.md", "A.md", EntryKind::File),
            file("alpha", "alpha", EntryKind::Directory),
            file("a.md", "a.md", EntryKind::File),
        ];
        sort_for_tree(&mut entries);
        let names: Vec<_> = entries.iter().map(|entry| entry.name.as_str()).collect();
        assert_eq!(names, ["alpha", "Zeta", "A.md", "a.md", "b.rs"]);
    }

    #[test]
    fn listing_and_search_rooting() {
        let src = WorkspacePath::parse("src").unwrap();
        let echoed = serde_json::json!({"path": "src/lib.rs", "type": "file"});
        let bare = serde_json::json!({"path": "lib.rs", "type": "file"});
        assert_eq!(
            entry(&echoed, &src, Rooting::Listing)
                .unwrap()
                .path
                .as_str(),
            "src/lib.rs"
        );
        assert_eq!(
            entry(&bare, &src, Rooting::Listing).unwrap().path.as_str(),
            "src/lib.rs"
        );
        assert_eq!(
            entry(&bare, &src, Rooting::Search).unwrap().path.as_str(),
            "src/lib.rs"
        );
        assert_eq!(
            entry(&echoed, &src, Rooting::Search).unwrap().path.as_str(),
            "src/src/lib.rs",
            "search paths are always relative to the searched directory"
        );
        let unsafe_entry = serde_json::json!({"path": "../etc/passwd", "type": "file"});
        assert!(entry(&unsafe_entry, &src, Rooting::Listing).is_err());
        let absolute = serde_json::json!({"path": "/etc/passwd", "type": "file"});
        assert!(entry(&absolute, &WorkspacePath::root(), Rooting::Listing).is_err());
        let unknown = serde_json::json!({"path": "x", "type": "fifo", "name": ""});
        let decoded = entry(&unknown, &WorkspacePath::root(), Rooting::Listing).unwrap();
        assert_eq!(decoded.kind, EntryKind::Unknown("fifo".into()));
        assert_eq!(decoded.name, "x");
    }

    #[test]
    fn has_more_needs_a_fresh_cursor() {
        let root = WorkspacePath::root();
        let page = serde_json::json!({"object": "list", "data": [], "has_more": true});
        assert!(directory_page(&page, &root, None).is_err());
        let stuck =
            serde_json::json!({"object": "list", "data": [], "has_more": true, "last_id": "a"});
        assert!(directory_page(&stuck, &root, Some("a")).is_err());
        assert_eq!(
            directory_page(&stuck, &root, None)
                .unwrap()
                .next_cursor
                .as_deref(),
            Some("a")
        );
    }

    #[test]
    fn changes_accept_the_native_lab_shapes() {
        let entries =
            serde_json::json!({"entries": [{"path": "Sources/App.swift", "status": "modified"}]});
        let bare = serde_json::json!([{"path": "Sources/App.swift", "status": "modified"}]);
        for value in [entries, bare] {
            let list = changes(&value).unwrap();
            assert_eq!(list.entries.len(), 1);
            assert_eq!(list.entries[0].status, ChangeStatus::Modified);
        }
        assert!(changes(&serde_json::json!({"object": "list"})).is_err());
        assert!(
            changes(&serde_json::json!({"data": [{"path": "../x", "status": "created"}]})).is_err()
        );
    }
}
