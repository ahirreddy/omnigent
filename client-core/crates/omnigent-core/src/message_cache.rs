//! The device's saved copy of what the server returned: each opened session's snapshot and
//! history items, and the session list's rows, so a session seen before opens without network.
//!
//! Sans-IO: this module names the files, encodes and decodes them, and decides what to evict.
//! The host reads and writes the files. Under the cache root, per server and per account
//! (hashed, so no URL, user id or session id becomes a file name):
//!
//! - `<server>/<account>/sessions.json`: the session list's rows and the projects.
//! - `<server>/<account>/conversations/<session>.json`: one session's snapshot and items.
//! - `<server>/last-account.json`: the account that last connected, for an offline start that
//!   names none.
//!
//! What a file holds is the user's data: no error here carries any of it, only which part of a
//! file failed and how.

use omnigent_protocol::{
    ConversationItem, DecodeError, FromWire, SessionListItem, SessionSnapshot,
};
use serde_json::{Map, Value};
use sha2::{Digest as _, Sha256};

use crate::project_settings::ProjectSortMode;
use crate::projects::ProjectSummary;
use crate::reconcile::HistoryItems;
use crate::server_url;

/// The file format this build writes and reads; files of another version are discarded.
pub const FORMAT_VERSION: u64 = 1;
/// The most the saved conversations of every server and account may take on disk.
pub const MAX_CACHE_BYTES: u64 = 100 * 1024 * 1024;
/// The most items one saved conversation keeps; the oldest go first.
pub const MAX_SAVED_ITEMS: usize = 2_000;
/// The folder of an account's saved conversations.
pub const CONVERSATIONS_DIR: &str = "conversations";
/// The session list's file in an account's folder.
pub const LIST_FILE: &str = "sessions.json";
/// The last-connected account's file in a server's folder.
pub const LAST_ACCOUNT_FILE: &str = "last-account.json";
/// The API root the server's manifest last named, in its folder: a connect reads `/v1/info`
/// there beside the manifest, and again only when the manifest names another.
pub const ENDPOINT_FILE: &str = "endpoint.json";

/// Why the saved copy could not be used. Messages name the part of a file and the failure,
/// never what the file holds.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CacheError {
    /// A file could not be read.
    #[error("The saved copy of {what} could not be read: {cause}")]
    Read {
        /// The file's role, for example "the session list".
        what: String,
        /// The file system's reason.
        cause: String,
    },
    /// A file could not be written or removed.
    #[error("The saved copy of {what} could not be written: {cause}")]
    Write {
        /// The file's role.
        what: String,
        /// The file system's reason.
        cause: String,
    },
    /// A file did not decode; it is discarded.
    #[error("The saved copy of {what} was damaged and was discarded: {cause}")]
    Corrupt {
        /// The file's role.
        what: String,
        /// Where and how decoding failed.
        cause: String,
    },
    /// Data could not be encoded.
    #[error("The saved copy of {what} could not be encoded: {cause}")]
    Encode {
        /// The file's role.
        what: String,
        /// The encoder's reason.
        cause: String,
    },
}

/// The role of a session's file, for messages.
pub const CONVERSATION_ROLE: &str = "a session";
/// The role of the session list's file, for messages.
pub const LIST_ROLE: &str = "the session list";
/// The role of the last-account file, for messages.
pub const ACCOUNT_ROLE: &str = "the last signed-in account";
/// The role of the endpoint file, for messages.
pub const ENDPOINT_ROLE: &str = "the server's API address";

/// Lower-case hex of the first 16 bytes of `text`'s SHA-256: a file name that reveals nothing.
fn hashed(text: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut hex = String::with_capacity(32);
    for byte in Sha256::digest(text.as_bytes()).iter().take(16) {
        for nibble in [byte >> 4, byte & 0x0F] {
            if let Some(digit) = HEX.get(usize::from(nibble)) {
                hex.push(char::from(*digit));
            }
        }
    }
    hex
}

/// The folder name of `server_url`'s saved copy.
///
/// The URL is normalized as connecting does (a Databricks workspace by its API root), so a typed
/// and a canonical URL share it. `None` for a URL that does not normalize.
#[must_use]
pub fn server_key(server_url: &str) -> Option<String> {
    let url = server_url::normalize(server_url, true).ok()?;
    let url = if server_url::is_databricks_workspace(&url) {
        server_url::databricks_api_root(&url)
    } else {
        url
    };
    Some(hashed(&server_url::display(&url)))
}

/// The folder name of `user_id`'s saved copy on one server.
#[must_use]
pub fn account_key(user_id: &str) -> String {
    hashed(user_id)
}

/// The last-connected account's file of the server whose key is `server_key`.
#[must_use]
pub fn last_account_path(server_key: &str) -> String {
    format!("{server_key}/{LAST_ACCOUNT_FILE}")
}

/// The API root the manifest of the server whose key is `server_key` named last.
#[must_use]
pub fn endpoint_path(server_key: &str) -> String {
    format!("{server_key}/{ENDPOINT_FILE}")
}

/// One account on one server: where its saved copy lives under the cache root.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CacheScope {
    server: String,
    account: String,
}

impl CacheScope {
    /// The scope of `user_id` on `server_url`; `None` for a URL that does not normalize.
    #[must_use]
    pub fn new(server_url: &str, user_id: &str) -> Option<Self> {
        Some(Self {
            server: server_key(server_url)?,
            account: account_key(user_id),
        })
    }

    /// A scope from keys already hashed (a server key and a saved last account).
    #[must_use]
    pub const fn from_keys(server: String, account: String) -> Self {
        Self { server, account }
    }

    /// The server's folder name.
    #[must_use]
    pub fn server_key(&self) -> &str {
        &self.server
    }

    /// The account's folder name.
    #[must_use]
    pub fn account_key(&self) -> &str {
        &self.account
    }

    /// The account's folder, relative to the cache root.
    #[must_use]
    pub fn account_dir(&self) -> String {
        format!("{}/{}", self.server, self.account)
    }

    /// The session list's file.
    #[must_use]
    pub fn list_path(&self) -> String {
        format!("{}/{LIST_FILE}", self.account_dir())
    }

    /// `session_id`'s file.
    #[must_use]
    pub fn conversation_path(&self, session_id: &str) -> String {
        format!(
            "{}/{CONVERSATIONS_DIR}/{}.json",
            self.account_dir(),
            hashed(session_id)
        )
    }
}

/// One session as saved: its snapshot and its history items as loaded.
#[derive(Debug, Clone, PartialEq)]
pub struct SavedConversation {
    /// When it was saved, ms since the Unix epoch.
    pub saved_at_ms: u64,
    /// The session as last read (`include_items=false`).
    pub session: SessionSnapshot,
    /// Items above the newest page (older pages the reader loaded), oldest first.
    pub older: Vec<ConversationItem>,
    /// The newest page as last read and the items committed on the stream since, oldest first.
    pub newest: Vec<ConversationItem>,
    /// The cursor for the page above every saved item; `None` when history is complete.
    pub older_cursor: Option<String>,
}

impl SavedConversation {
    /// What to save of a session the sync holds: its `history`, with the `streamed` items the
    /// stream committed after the newest page was read, at most [`MAX_SAVED_ITEMS`] of them.
    #[must_use]
    pub fn new(
        saved_at_ms: u64,
        session: SessionSnapshot,
        history: HistoryItems,
        streamed: &[ConversationItem],
    ) -> Self {
        let mut newest = history.newest;
        for item in streamed {
            if let Some(slot) = newest.iter_mut().find(|known| known.id == item.id) {
                slot.clone_from(item);
            } else {
                newest.push(item.clone());
            }
        }
        Self {
            saved_at_ms,
            session,
            older: history.older,
            newest,
            older_cursor: history.cursor,
        }
        .capped()
    }

    /// Every saved item, oldest first.
    pub fn items(&self) -> impl Iterator<Item = &ConversationItem> {
        self.older.iter().chain(&self.newest)
    }

    /// Drops the oldest items past [`MAX_SAVED_ITEMS`]. Paging then goes on from the oldest
    /// kept item: the server's `after` cursor is the id of a page's oldest item.
    fn capped(mut self) -> Self {
        let total = self.older.len() + self.newest.len();
        let Some(excess) = total
            .checked_sub(MAX_SAVED_ITEMS)
            .filter(|excess| *excess > 0)
        else {
            return self;
        };
        if excess <= self.older.len() {
            self.older = self.older.split_off(excess);
        } else {
            let from_newest = (excess - self.older.len()).min(self.newest.len());
            self.older.clear();
            self.newest = self.newest.split_off(from_newest);
        }
        let oldest = self.items().next().map(|item| item.id.clone());
        self.older_cursor = oldest;
        self
    }
}

/// The session list as saved: the rows of every page, pin and folder read loaded, and the
/// projects the folders are drawn from.
#[derive(Debug, Clone, PartialEq)]
pub struct SavedSessionList {
    /// When it was saved, ms since the Unix epoch.
    pub saved_at_ms: u64,
    /// Rows in the server's order.
    pub rows: Vec<SessionListItem>,
    /// The projects as last read; `None` before a read landed (and in older files).
    pub projects: Option<SavedProjects>,
    /// The account the rows were read for, which decides the ones it owns (its folders' rows)
    /// before a connection confirms it; `None` in older files.
    pub viewer_id: Option<String>,
}

/// The caller's projects as saved, in their display order, and how they sort.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedProjects {
    /// The projects.
    pub projects: Vec<ProjectSummary>,
    /// How the sidebar sorts them.
    pub sort: ProjectSortMode,
}

impl SavedSessionList {
    /// The rows of a later page: a row already saved is replaced in place, a new one appended.
    pub fn upsert(&mut self, rows: &[SessionListItem]) {
        for row in rows {
            if let Some(slot) = self.rows.iter_mut().find(|known| known.id == row.id) {
                slot.clone_from(row);
            } else {
                self.rows.push(row.clone());
            }
        }
    }

    /// Removes the rows of `ids`; returns whether any was saved.
    pub fn remove(&mut self, ids: &[String]) -> bool {
        let before = self.rows.len();
        self.rows.retain(|row| !ids.contains(&row.id));
        self.rows.len() != before
    }
}

fn encode_error(what: &str, error: &serde_json::Error) -> CacheError {
    CacheError::Encode {
        what: what.to_owned(),
        cause: format!("{:?} error", error.classify()),
    }
}

fn corrupt(what: &str, cause: impl Into<String>) -> CacheError {
    CacheError::Corrupt {
        what: what.to_owned(),
        cause: cause.into(),
    }
}

/// A decode failure without the decoder's message, which can quote the data.
fn decode_cause(error: &DecodeError) -> String {
    match error {
        DecodeError::Syntax { .. } => "not valid JSON".to_owned(),
        DecodeError::NotAnObject { context } => format!("{context} is not an object"),
        DecodeError::MissingField { context, field } => {
            format!("{context} has no usable `{field}`")
        }
        DecodeError::Invalid { context, .. } => format!("{context} has an unexpected shape"),
    }
}

/// The header fields every file starts with.
fn envelope(saved_at_ms: u64) -> Map<String, Value> {
    let mut fields = Map::new();
    fields.insert("version".to_owned(), Value::from(FORMAT_VERSION));
    fields.insert("saved_at_ms".to_owned(), Value::from(saved_at_ms));
    fields
}

fn to_bytes(what: &str, fields: Map<String, Value>) -> Result<Vec<u8>, CacheError> {
    serde_json::to_vec(&Value::Object(fields)).map_err(|error| encode_error(what, &error))
}

/// A file's fields after its version and save time are checked.
fn open_envelope(what: &str, bytes: &[u8]) -> Result<(Map<String, Value>, u64), CacheError> {
    let value: Value = serde_json::from_slice(bytes).map_err(|error| {
        corrupt(
            what,
            format!(
                "{:?} error at line {}, column {}",
                error.classify(),
                error.line(),
                error.column()
            ),
        )
    })?;
    let Value::Object(mut fields) = value else {
        return Err(corrupt(what, "the file is not a JSON object"));
    };
    match fields
        .remove("version")
        .and_then(|version| version.as_u64())
    {
        Some(FORMAT_VERSION) => {}
        Some(version) => return Err(corrupt(what, format!("format version {version}"))),
        None => return Err(corrupt(what, "no format version")),
    }
    let saved_at_ms = fields
        .remove("saved_at_ms")
        .and_then(|saved| saved.as_u64())
        .ok_or_else(|| corrupt(what, "no save time"))?;
    Ok((fields, saved_at_ms))
}

fn decode_list_of<T: FromWire>(
    what: &str,
    fields: &mut Map<String, Value>,
    key: &str,
) -> Result<Vec<T>, CacheError> {
    let Some(Value::Array(values)) = fields.remove(key) else {
        return Err(corrupt(what, format!("`{key}` is not a list")));
    };
    values
        .into_iter()
        .enumerate()
        .map(|(index, value)| {
            T::from_value(value)
                .map_err(|error| corrupt(what, format!("{key}[{index}]: {}", decode_cause(&error))))
        })
        .collect()
}

/// A saved conversation's file.
///
/// # Errors
///
/// [`CacheError::Encode`] when a part does not encode.
pub fn encode_conversation(saved: &SavedConversation) -> Result<Vec<u8>, CacheError> {
    let what = CONVERSATION_ROLE;
    let mut fields = envelope(saved.saved_at_ms);
    let encoded = |error: serde_json::Error| encode_error(what, &error);
    fields.insert(
        "session".to_owned(),
        serde_json::to_value(&saved.session).map_err(encoded)?,
    );
    fields.insert(
        "older".to_owned(),
        serde_json::to_value(&saved.older).map_err(encoded)?,
    );
    fields.insert(
        "newest".to_owned(),
        serde_json::to_value(&saved.newest).map_err(encoded)?,
    );
    fields.insert(
        "older_cursor".to_owned(),
        saved
            .older_cursor
            .as_ref()
            .map_or(Value::Null, |cursor| Value::String(cursor.clone())),
    );
    to_bytes(what, fields)
}

/// Decodes `session_id`'s saved conversation.
///
/// # Errors
///
/// [`CacheError::Corrupt`] for a file that is not this format, or holds another session.
pub fn decode_conversation(
    bytes: &[u8],
    session_id: &str,
) -> Result<SavedConversation, CacheError> {
    let what = CONVERSATION_ROLE;
    let (mut fields, saved_at_ms) = open_envelope(what, bytes)?;
    let session = SessionSnapshot::from_value(fields.remove("session").unwrap_or(Value::Null))
        .map_err(|error| corrupt(what, format!("session: {}", decode_cause(&error))))?;
    if session.id != session_id {
        return Err(corrupt(what, "the file holds another session"));
    }
    let older = decode_list_of(what, &mut fields, "older")?;
    let newest = decode_list_of(what, &mut fields, "newest")?;
    let older_cursor = match fields.remove("older_cursor") {
        None | Some(Value::Null) => None,
        Some(Value::String(cursor)) if !cursor.is_empty() => Some(cursor),
        Some(_) => return Err(corrupt(what, "`older_cursor` is not a cursor")),
    };
    Ok(SavedConversation {
        saved_at_ms,
        session,
        older,
        newest,
        older_cursor,
    })
}

/// A saved session list's file.
///
/// # Errors
///
/// [`CacheError::Encode`] when a row does not encode.
pub fn encode_list(list: &SavedSessionList) -> Result<Vec<u8>, CacheError> {
    let what = LIST_ROLE;
    let mut fields = envelope(list.saved_at_ms);
    let rows = serde_json::to_value(&list.rows).map_err(|error| encode_error(what, &error))?;
    fields.insert("rows".to_owned(), rows);
    if let Some(viewer) = &list.viewer_id {
        fields.insert("viewer_id".to_owned(), Value::String(viewer.clone()));
    }
    if let Some(saved) = &list.projects {
        let projects = saved
            .projects
            .iter()
            .map(|project| {
                serde_json::json!({"id": project.id, "name": project.name, "icon": project.icon})
            })
            .collect();
        fields.insert("projects".to_owned(), Value::Array(projects));
        let sort = match saved.sort {
            ProjectSortMode::Alphabetical => "alphabetical",
            ProjectSortMode::Manual => "manual",
        };
        fields.insert("project_sort".to_owned(), Value::from(sort));
    }
    to_bytes(what, fields)
}

/// Decodes a saved session list.
///
/// # Errors
///
/// [`CacheError::Corrupt`] for a file that is not this format.
pub fn decode_list(bytes: &[u8]) -> Result<SavedSessionList, CacheError> {
    let what = LIST_ROLE;
    let (mut fields, saved_at_ms) = open_envelope(what, bytes)?;
    let rows = decode_list_of(what, &mut fields, "rows")?;
    let projects = decode_projects(&mut fields)?;
    let viewer_id = match fields.remove("viewer_id") {
        None | Some(Value::Null) => None,
        Some(Value::String(viewer)) => Some(viewer),
        Some(_) => return Err(corrupt(what, "`viewer_id` is not a string")),
    };
    Ok(SavedSessionList {
        saved_at_ms,
        rows,
        projects,
        viewer_id,
    })
}

/// A saved list's projects; `None` when it saved none.
fn decode_projects(fields: &mut Map<String, Value>) -> Result<Option<SavedProjects>, CacheError> {
    let what = LIST_ROLE;
    let Some(projects) = fields.remove("projects") else {
        return Ok(None);
    };
    let Value::Array(projects) = projects else {
        return Err(corrupt(what, "`projects` is not a list"));
    };
    let text =
        |project: &Value, key: &str| project.get(key).and_then(Value::as_str).map(str::to_owned);
    let projects = projects
        .iter()
        .enumerate()
        .map(|(index, project)| {
            let name = text(project, "name")
                .ok_or_else(|| corrupt(what, format!("projects[{index}] has no usable `name`")))?;
            Ok(ProjectSummary {
                id: text(project, "id"),
                name,
                icon: text(project, "icon"),
            })
        })
        .collect::<Result<Vec<_>, CacheError>>()?;
    let sort = match fields
        .remove("project_sort")
        .as_ref()
        .and_then(Value::as_str)
    {
        Some("alphabetical") => ProjectSortMode::Alphabetical,
        Some("manual") => ProjectSortMode::Manual,
        _ => return Err(corrupt(what, "no usable `project_sort`")),
    };
    Ok(Some(SavedProjects { projects, sort }))
}

/// The last-account file naming `account_key`.
///
/// # Errors
///
/// [`CacheError::Encode`] when it does not encode.
pub fn encode_last_account(account_key: &str, saved_at_ms: u64) -> Result<Vec<u8>, CacheError> {
    let mut fields = envelope(saved_at_ms);
    fields.insert("account".to_owned(), Value::String(account_key.to_owned()));
    to_bytes(ACCOUNT_ROLE, fields)
}

/// The account key a last-account file names.
///
/// # Errors
///
/// [`CacheError::Corrupt`] for a file that is not this format or names no account folder.
pub fn decode_last_account(bytes: &[u8]) -> Result<String, CacheError> {
    let what = ACCOUNT_ROLE;
    let (mut fields, _) = open_envelope(what, bytes)?;
    match fields.remove("account") {
        Some(Value::String(account))
            if account.len() == 32 && account.bytes().all(|byte| byte.is_ascii_hexdigit()) =>
        {
            Ok(account)
        }
        _ => Err(corrupt(what, "no account folder")),
    }
}

/// The endpoint file naming `base_url`.
///
/// # Errors
///
/// [`CacheError::Encode`] when it does not encode.
pub fn encode_endpoint(base_url: &str, saved_at_ms: u64) -> Result<Vec<u8>, CacheError> {
    let mut fields = envelope(saved_at_ms);
    fields.insert("base_url".to_owned(), Value::String(base_url.to_owned()));
    to_bytes(ENDPOINT_ROLE, fields)
}

/// The API root an endpoint file names.
///
/// # Errors
///
/// [`CacheError::Corrupt`] for a file that is not this format or names no address.
pub fn decode_endpoint(bytes: &[u8]) -> Result<String, CacheError> {
    let (mut fields, _) = open_envelope(ENDPOINT_ROLE, bytes)?;
    match fields.remove("base_url") {
        Some(Value::String(base_url)) if !base_url.is_empty() => Ok(base_url),
        _ => Err(corrupt(ENDPOINT_ROLE, "no address")),
    }
}

/// One saved conversation's file, for eviction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CachedFile {
    /// Its size on disk.
    pub bytes: u64,
    /// When a session last opened or saved it, ms since the Unix epoch.
    pub last_used_ms: u64,
    /// Never evicted (the file just written).
    pub keep: bool,
}

/// The indexes of the `files` to delete, the least recently used first, so the rest take at
/// most `cap` bytes. A kept file is never chosen, even when the rest still exceed the cap.
#[must_use]
pub fn evictions(files: &[CachedFile], cap: u64) -> Vec<usize> {
    let mut total = files
        .iter()
        .fold(0_u64, |total, file| total.saturating_add(file.bytes));
    if total <= cap {
        return Vec::new();
    }
    let mut candidates: Vec<(usize, &CachedFile)> = files
        .iter()
        .enumerate()
        .filter(|(_, file)| !file.keep)
        .collect();
    candidates.sort_by_key(|(index, file)| (file.last_used_ms, *index));
    let mut evicted = Vec::new();
    for (index, file) in candidates {
        if total <= cap {
            break;
        }
        total = total.saturating_sub(file.bytes);
        evicted.push(index);
    }
    evicted
}

#[cfg(test)]
#[path = "message_cache_tests.rs"]
mod tests;
