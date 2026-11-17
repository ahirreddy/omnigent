//! The device's saved copy of sessions on disk; [`omnigent_core::message_cache`] names, encodes
//! and evicts the files. Reads run on the caller's thread. Writes run in order on one background
//! thread, each into a temporary file renamed into place, so a reader never sees half a file.
//! Every failure goes to the engine as [`SavedMsg::Failed`]; a damaged file is discarded.

use std::fs::{self, File};
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use futures::channel::mpsc::UnboundedSender;
use omnigent_core::message_cache::{
    self as cache, CacheError, CacheScope, CachedFile, SavedConversation, SavedSessionList,
};

use crate::cache_driver::SavedMsg;
use crate::engine::{Msg, lock};
use crate::runtime::post;

/// Where a failure shows: on its session, on the session list, or on the connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CacheFailureScope {
    Session(String),
    List,
    Connection,
}

/// Work for the writer thread.
enum Job {
    Conversation {
        scope: CacheScope,
        session_id: String,
        saved: Box<SavedConversation>,
    },
    List {
        scope: CacheScope,
        list: SavedSessionList,
    },
    LastAccount {
        scope: CacheScope,
        at_ms: u64,
    },
    Touch {
        scope: CacheScope,
        session_id: String,
        at_ms: u64,
    },
    Discard {
        path: String,
        failure: CacheFailureScope,
        what: &'static str,
    },
    ForgetAccount {
        scope: CacheScope,
    },
    ForgetServer {
        server_key: String,
    },
    #[cfg(test)]
    Flush(Sender<()>),
}

impl Job {
    /// The file a write job replaces whole, so an earlier write to it in the same batch can go.
    fn replaced_file(&self) -> Option<String> {
        match self {
            Self::Conversation {
                scope, session_id, ..
            } => Some(scope.conversation_path(session_id)),
            Self::List { scope, .. } => Some(scope.list_path()),
            _ => None,
        }
    }
}

/// The saved copy under one cache root.
pub(crate) struct MessageCache {
    root: PathBuf,
    report: UnboundedSender<Msg>,
    /// The most the saved conversations may take on disk.
    cap: u64,
    writer: Mutex<Option<Sender<Job>>>,
}

impl std::fmt::Debug for MessageCache {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("MessageCache")
    }
}

fn system_time(ms: u64) -> SystemTime {
    UNIX_EPOCH
        .checked_add(Duration::from_millis(ms))
        .unwrap_or(UNIX_EPOCH)
}

fn read_error(what: &str, error: &io::Error) -> CacheError {
    CacheError::Read {
        what: what.to_owned(),
        cause: error.to_string(),
    }
}

fn write_error(what: &str, error: &io::Error) -> CacheError {
    CacheError::Write {
        what: what.to_owned(),
        cause: error.to_string(),
    }
}

impl MessageCache {
    /// The saved copy under `root`, reporting background failures to `report`. Nothing is
    /// created until the first write.
    pub(crate) fn new(root: impl Into<PathBuf>, report: UnboundedSender<Msg>) -> Self {
        Self::with_cap(root, report, cache::MAX_CACHE_BYTES)
    }

    /// [`Self::new`] with another cap on the saved conversations' bytes.
    pub(crate) fn with_cap(
        root: impl Into<PathBuf>,
        report: UnboundedSender<Msg>,
        cap: u64,
    ) -> Self {
        Self {
            root: root.into(),
            report,
            cap,
            writer: Mutex::new(None),
        }
    }

    /// `session_id`'s saved copy, `None` when nothing is saved. A damaged file is discarded.
    ///
    /// # Errors
    ///
    /// The file could not be read, or did not decode.
    pub(crate) fn read_conversation(
        &self,
        scope: &CacheScope,
        session_id: &str,
    ) -> Result<Option<SavedConversation>, CacheError> {
        let path = scope.conversation_path(session_id);
        let Some(bytes) = self.read(&path, cache::CONVERSATION_ROLE)? else {
            return Ok(None);
        };
        cache::decode_conversation(&bytes, session_id)
            .map(Some)
            .inspect_err(|_| {
                self.discard(
                    path,
                    CacheFailureScope::Session(session_id.to_owned()),
                    cache::CONVERSATION_ROLE,
                );
            })
    }

    /// The saved session list, `None` when nothing is saved. A damaged file is discarded.
    ///
    /// # Errors
    ///
    /// The file could not be read, or did not decode.
    pub(crate) fn read_list(
        &self,
        scope: &CacheScope,
    ) -> Result<Option<SavedSessionList>, CacheError> {
        let path = scope.list_path();
        let Some(bytes) = self.read(&path, cache::LIST_ROLE)? else {
            return Ok(None);
        };
        cache::decode_list(&bytes).map(Some).inspect_err(|_| {
            self.discard(path, CacheFailureScope::List, cache::LIST_ROLE);
        })
    }

    /// The account that last connected to the server of `server_key`, `None` when none did.
    ///
    /// # Errors
    ///
    /// The file could not be read, or did not decode.
    pub(crate) fn read_last_account(&self, server_key: &str) -> Result<Option<String>, CacheError> {
        let path = cache::last_account_path(server_key);
        let Some(bytes) = self.read(&path, cache::ACCOUNT_ROLE)? else {
            return Ok(None);
        };
        cache::decode_last_account(&bytes)
            .map(Some)
            .inspect_err(|_| {
                self.discard(path, CacheFailureScope::Connection, cache::ACCOUNT_ROLE);
            })
    }

    fn read(&self, relative: &str, what: &str) -> Result<Option<Vec<u8>>, CacheError> {
        match fs::read(self.root.join(relative)) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(read_error(what, &error)),
        }
    }

    /// Saves `session_id`'s copy.
    pub(crate) fn save_conversation(
        &self,
        scope: &CacheScope,
        session_id: &str,
        saved: SavedConversation,
    ) {
        self.send(Job::Conversation {
            scope: scope.clone(),
            session_id: session_id.to_owned(),
            saved: Box::new(saved),
        });
    }

    /// Saves the session list.
    pub(crate) fn save_list(&self, scope: &CacheScope, list: SavedSessionList) {
        self.send(Job::List {
            scope: scope.clone(),
            list,
        });
    }

    /// Records `scope`'s account as the one that last connected to its server.
    pub(crate) fn save_last_account(&self, scope: &CacheScope, at_ms: u64) {
        self.send(Job::LastAccount {
            scope: scope.clone(),
            at_ms,
        });
    }

    /// Marks `session_id`'s copy used at `at_ms`, so eviction keeps it longer.
    pub(crate) fn touch_conversation(&self, scope: &CacheScope, session_id: &str, at_ms: u64) {
        self.send(Job::Touch {
            scope: scope.clone(),
            session_id: session_id.to_owned(),
            at_ms,
        });
    }

    /// Deletes a file that could not be used.
    pub(crate) fn discard(&self, path: String, failure: CacheFailureScope, what: &'static str) {
        self.send(Job::Discard {
            path,
            failure,
            what,
        });
    }

    /// Deletes `scope`'s account's saved copy (signing out).
    pub(crate) fn forget_account(&self, scope: &CacheScope) {
        self.send(Job::ForgetAccount {
            scope: scope.clone(),
        });
    }

    /// Deletes every account's saved copy of one server (removing the server).
    pub(crate) fn forget_server(&self, server_key: String) {
        self.send(Job::ForgetServer { server_key });
    }

    /// Waits until every job sent before this one is done.
    #[cfg(test)]
    pub(crate) fn flush(&self) {
        let (done, wait) = mpsc::channel();
        self.send(Job::Flush(done));
        wait.recv_timeout(Duration::from_secs(30))
            .expect("the message cache writer finished its jobs");
    }

    fn failed(&self, failure: CacheFailureScope, error: CacheError) {
        post(
            &self.report,
            Msg::Saved(SavedMsg::Failed { failure, error }),
        );
    }

    /// Hands `job` to the writer thread, starting it on first use and again after it ended.
    fn send(&self, job: Job) {
        let mut writer = lock(&self.writer);
        let job = match writer.as_ref() {
            Some(sender) => match sender.send(job) {
                Ok(()) => return,
                Err(mpsc::SendError(job)) => job,
            },
            None => job,
        };
        let (sender, jobs) = mpsc::channel();
        let state = Writer::new(self.root.clone(), self.report.clone(), self.cap);
        let started = std::thread::Builder::new()
            .name("omnigent-message-cache".to_owned())
            .spawn(move || state.run(&jobs));
        match started {
            Ok(_) => {
                if let Err(mpsc::SendError(unsent)) = sender.send(job) {
                    drop(unsent);
                    drop(writer);
                    self.failed(
                        CacheFailureScope::Connection,
                        CacheError::Write {
                            what: "sessions".to_owned(),
                            cause: "the writer stopped".to_owned(),
                        },
                    );
                    return;
                }
                *writer = Some(sender);
            }
            Err(error) => {
                drop(writer);
                self.failed(
                    CacheFailureScope::Connection,
                    write_error("sessions", &error),
                );
            }
        }
    }
}

/// The writer thread's state.
struct Writer {
    root: PathBuf,
    report: UnboundedSender<Msg>,
    cap: u64,
    /// The bytes every saved conversation takes, once scanned.
    total: Option<u64>,
    /// The last failure reported; the same one again is not repeated until a write succeeds.
    last_failure: Option<CacheError>,
    temp_counter: u64,
}

impl Writer {
    const fn new(root: PathBuf, report: UnboundedSender<Msg>, cap: u64) -> Self {
        Self {
            root,
            report,
            cap,
            total: None,
            last_failure: None,
            temp_counter: 0,
        }
    }

    fn run(mut self, jobs: &Receiver<Job>) {
        while let Ok(first) = jobs.recv() {
            let mut batch = vec![first];
            batch.extend(jobs.try_iter());
            let replaced: Vec<Option<String>> = batch.iter().map(Job::replaced_file).collect();
            for (index, job) in batch.into_iter().enumerate() {
                let superseded = replaced.get(index).cloned().flatten().is_some_and(|file| {
                    replaced
                        .iter()
                        .skip(index + 1)
                        .any(|later| later.as_deref() == Some(file.as_str()))
                });
                if !superseded {
                    self.handle(job);
                }
            }
        }
    }

    fn handle(&mut self, job: Job) {
        match job {
            Job::Conversation {
                scope,
                session_id,
                saved,
            } => self.write_conversation(&scope, &session_id, &saved),
            Job::List { scope, list } => {
                let result = cache::encode_list(&list).and_then(|bytes| {
                    self.write(
                        &scope.list_path(),
                        &bytes,
                        list.saved_at_ms,
                        cache::LIST_ROLE,
                    )
                    .map(|_| ())
                });
                self.outcome(CacheFailureScope::List, result);
            }
            Job::LastAccount { scope, at_ms } => {
                let path = cache::last_account_path(scope.server_key());
                let result =
                    cache::encode_last_account(scope.account_key(), at_ms).and_then(|bytes| {
                        self.write(&path, &bytes, at_ms, cache::ACCOUNT_ROLE)
                            .map(|_| ())
                    });
                self.outcome(CacheFailureScope::Connection, result);
            }
            Job::Touch {
                scope,
                session_id,
                at_ms,
            } => {
                let result = self.touch(&scope.conversation_path(&session_id), at_ms);
                self.outcome(CacheFailureScope::Session(session_id), result);
            }
            Job::Discard {
                path,
                failure,
                what,
            } => {
                let result =
                    remove_file(&self.root.join(path)).map_err(|error| write_error(what, &error));
                self.total = None;
                self.outcome(failure, result);
            }
            Job::ForgetAccount { scope } => {
                let result = self.forget_account(&scope);
                self.total = None;
                self.outcome(CacheFailureScope::Connection, result);
            }
            Job::ForgetServer { server_key } => {
                let result = remove_dir(&self.root.join(&server_key))
                    .map_err(|error| write_error("this server's sessions", &error));
                self.total = None;
                self.outcome(CacheFailureScope::Connection, result);
            }
            #[cfg(test)]
            Job::Flush(done) => {
                // A test that stopped waiting has nothing to be told.
                done.send(()).unwrap_or(());
            }
        }
    }

    fn write_conversation(
        &mut self,
        scope: &CacheScope,
        session_id: &str,
        saved: &SavedConversation,
    ) {
        let path = scope.conversation_path(session_id);
        let result = cache::encode_conversation(saved).and_then(|bytes| {
            self.write(&path, &bytes, saved.saved_at_ms, cache::CONVERSATION_ROLE)
        });
        match result {
            Ok((previous, written)) => {
                self.succeeded();
                self.account_for(&path, previous, written);
            }
            Err(error) => self.report(CacheFailureScope::Session(session_id.to_owned()), error),
        }
    }

    /// Writes `bytes` to `relative` through a temporary file, stamped as used at `at_ms`.
    /// Returns the sizes of the file it replaced (0 for none) and of the new one.
    fn write(
        &mut self,
        relative: &str,
        bytes: &[u8],
        at_ms: u64,
        what: &str,
    ) -> Result<(u64, u64), CacheError> {
        let path = self.root.join(relative);
        let failed = |error: io::Error| write_error(what, &error);
        let parent = path
            .parent()
            .ok_or_else(|| failed(io::Error::other("the file has no folder")))?;
        fs::create_dir_all(parent).map_err(failed)?;
        let previous = match fs::metadata(&path) {
            Ok(metadata) => metadata.len(),
            Err(error) if error.kind() == io::ErrorKind::NotFound => 0,
            Err(error) => return Err(failed(error)),
        };
        self.temp_counter = self.temp_counter.wrapping_add(1);
        let name = path
            .file_name()
            .map_or_else(String::new, |name| name.to_string_lossy().into_owned());
        let temp = parent.join(format!(
            ".{name}.{}.{}.tmp",
            std::process::id(),
            self.temp_counter
        ));
        let written = Self::write_temp(&temp, bytes, at_ms).and_then(|()| fs::rename(&temp, &path));
        if let Err(error) = written {
            return Err(match remove_file(&temp) {
                Ok(()) => failed(error),
                Err(cleanup) => failed(io::Error::other(format!(
                    "{error}; its temporary file stayed: {cleanup}"
                ))),
            });
        }
        Ok((previous, u64::try_from(bytes.len()).unwrap_or(u64::MAX)))
    }

    fn write_temp(temp: &Path, bytes: &[u8], at_ms: u64) -> io::Result<()> {
        let mut file = File::create(temp)?;
        file.write_all(bytes)?;
        file.set_modified(system_time(at_ms))
    }

    fn touch(&self, relative: &str, at_ms: u64) -> Result<(), CacheError> {
        let path = self.root.join(relative);
        match fs::OpenOptions::new().write(true).open(&path) {
            Ok(file) => file
                .set_modified(system_time(at_ms))
                .map_err(|error| write_error(cache::CONVERSATION_ROLE, &error)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(write_error(cache::CONVERSATION_ROLE, &error)),
        }
    }

    /// Removes the account's folder, and the server's last-account record when it names it.
    fn forget_account(&self, scope: &CacheScope) -> Result<(), CacheError> {
        let what = "this account's sessions";
        remove_dir(&self.root.join(scope.account_dir()))
            .map_err(|error| write_error(what, &error))?;
        let record = self.root.join(cache::last_account_path(scope.server_key()));
        let names_it = match fs::read(&record) {
            Ok(bytes) => cache::decode_last_account(&bytes)
                .map_or(true, |account| account == scope.account_key()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => false,
            Err(error) => return Err(read_error(cache::ACCOUNT_ROLE, &error)),
        };
        if names_it {
            remove_file(&record).map_err(|error| write_error(cache::ACCOUNT_ROLE, &error))?;
        }
        Ok(())
    }

    /// Keeps the running total after a conversation write, evicting when it passes the cap.
    fn account_for(&mut self, written_path: &str, previous: u64, written: u64) {
        // Not scanned yet: the first write scans, evicting if the cap is passed.
        let total = self.total.map_or(u64::MAX, |total| {
            total.saturating_sub(previous).saturating_add(written)
        });
        if total <= self.cap {
            self.total = Some(total);
            return;
        }
        self.evict(&self.root.join(written_path));
    }

    /// Scans every saved conversation and deletes the least recently used past the cap,
    /// never `keep`.
    fn evict(&mut self, keep: &Path) {
        let files = match self.conversation_files() {
            Ok(files) => files,
            Err(error) => {
                self.total = None;
                self.report(
                    CacheFailureScope::Connection,
                    read_error("the saved sessions", &error),
                );
                return;
            }
        };
        let cached: Vec<CachedFile> = files
            .iter()
            .map(|(path, bytes, last_used_ms)| CachedFile {
                bytes: *bytes,
                last_used_ms: *last_used_ms,
                keep: path == keep,
            })
            .collect();
        let mut total = cached
            .iter()
            .fold(0_u64, |total, file| total.saturating_add(file.bytes));
        for index in cache::evictions(&cached, self.cap) {
            let Some((path, bytes, _)) = files.get(index) else {
                continue;
            };
            match remove_file(path) {
                Ok(()) => total = total.saturating_sub(*bytes),
                Err(error) => self.report(
                    CacheFailureScope::Connection,
                    write_error(cache::CONVERSATION_ROLE, &error),
                ),
            }
        }
        self.total = Some(total);
    }

    /// Every saved conversation file: its path, size and last use.
    fn conversation_files(&self) -> io::Result<Vec<(PathBuf, u64, u64)>> {
        let mut files = Vec::new();
        for server in folders(&self.root)? {
            for account in folders(&server)? {
                let conversations = account.join(cache::CONVERSATIONS_DIR);
                let entries = match fs::read_dir(&conversations) {
                    Ok(entries) => entries,
                    Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                    Err(error) => return Err(error),
                };
                for entry in entries {
                    let entry = entry?;
                    let path = entry.path();
                    if path.extension().is_none_or(|extension| extension != "json") {
                        continue;
                    }
                    let metadata = entry.metadata()?;
                    let last_used_ms = metadata
                        .modified()?
                        .duration_since(UNIX_EPOCH)
                        .map_or(0, |since| {
                            u64::try_from(since.as_millis()).unwrap_or(u64::MAX)
                        });
                    files.push((path, metadata.len(), last_used_ms));
                }
            }
        }
        Ok(files)
    }

    fn outcome(&mut self, failure: CacheFailureScope, result: Result<(), CacheError>) {
        match result {
            Ok(()) => self.succeeded(),
            Err(error) => self.report(failure, error),
        }
    }

    fn succeeded(&mut self) {
        self.last_failure = None;
    }

    fn report(&mut self, failure: CacheFailureScope, error: CacheError) {
        if self.last_failure.as_ref() == Some(&error) {
            return;
        }
        self.last_failure = Some(error.clone());
        post(
            &self.report,
            Msg::Saved(SavedMsg::Failed { failure, error }),
        );
    }
}

/// The folders directly in `path`; none when it does not exist.
fn folders(path: &Path) -> io::Result<Vec<PathBuf>> {
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let mut folders = Vec::new();
    for entry in entries {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            folders.push(entry.path());
        }
    }
    Ok(folders)
}

fn remove_file(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        result => result,
    }
}

fn remove_dir(path: &Path) -> io::Result<()> {
    match fs::remove_dir_all(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        result => result,
    }
}

#[cfg(test)]
#[path = "message_cache_tests.rs"]
mod tests;
