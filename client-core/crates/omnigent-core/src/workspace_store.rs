//! The offline sample workspace: its saved form, recovery after an interrupted run, and the
//! host storage it is read from and written to.
//!
//! Port of `NativeLab`'s `LocalWorkspace.swift`. The workspace is the [`crate::demo`] server's
//! state (each session's snapshot with its items and pending decisions, plus a revision) and the
//! composer drafts, so a relaunch shows exactly what was there, drafts included byte for byte.
//!
//! Loading never writes: a corrupt file, a future `version`, or duplicate session ids fail with
//! a [`WorkspaceError`] and the stored bytes stay untouched for the user to recover. A loaded
//! workspace is recovered: a reply that was streaming when the app closed keeps its partial text
//! with a note, stops streaming, and its session goes idle.

use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;

use omnigent_protocol::sessions::{SessionSnapshot, SessionStatus};
use omnigent_protocol::{ContentPart, ItemData, ItemStatus, TextPartKind};
use serde_json::{Map, Value};

use crate::client::json::{as_object, opt_array, opt_object, opt_u64};

/// The only workspace format this build reads and writes.
pub const WORKSPACE_VERSION: u64 = 1;

/// The note appended to a reply interrupted by the app closing.
pub const INTERRUPTED_REPLY_NOTE: &str = "Sample reply interrupted when the app closed.";

/// One saved session.
#[derive(Debug, Clone, PartialEq)]
pub struct WorkspaceSession {
    /// Bumped by every change.
    pub revision: u64,
    /// The session as the demo server serves it, items and pending decisions included.
    pub snapshot: SessionSnapshot,
}

/// The saved workspace.
#[derive(Debug, Clone, PartialEq)]
pub struct Workspace {
    /// The format version; only [`WORKSPACE_VERSION`] loads.
    pub version: u64,
    /// Sessions, in list order.
    pub sessions: Vec<WorkspaceSession>,
    /// Composer drafts by session id, exactly as typed.
    pub drafts: BTreeMap<String, String>,
}

impl Workspace {
    /// A current-version workspace.
    #[must_use]
    pub const fn new(sessions: Vec<WorkspaceSession>, drafts: BTreeMap<String, String>) -> Self {
        Self {
            version: WORKSPACE_VERSION,
            sessions,
            drafts,
        }
    }

    /// The workspace with every reply that was still streaming finished: its partial text keeps
    /// a note (or becomes the note), it stops streaming, its session goes idle, and that
    /// session's revision is bumped. Applying it twice changes nothing more.
    #[must_use]
    pub fn recovering_interrupted_replies(mut self) -> Self {
        for session in &mut self.sessions {
            let streaming = session.snapshot.items.iter().any(is_streaming);
            if !streaming && !session.snapshot.status.is_busy() {
                continue;
            }
            for item in &mut session.snapshot.items {
                if is_streaming(item) {
                    append_text(item, INTERRUPTED_REPLY_NOTE);
                    item.status = Some(ItemStatus::Completed);
                }
            }
            session.snapshot.status = SessionStatus::Idle;
            session.revision = session.revision.saturating_add(1);
        }
        self
    }
}

/// An assistant message still being written.
pub(crate) fn is_streaming(item: &omnigent_protocol::ConversationItem) -> bool {
    item.status == Some(ItemStatus::InProgress) && matches!(item.data, ItemData::Message(_))
}

/// Appends `note` to a message's text: as the text when empty, else after a blank line.
pub(crate) fn append_text(item: &mut omnigent_protocol::ConversationItem, note: &str) {
    let ItemData::Message(message) = &mut item.data else {
        return;
    };
    let partial = message.visible_text();
    let text = if partial.is_empty() {
        note.to_owned()
    } else {
        format!("{partial}\n\n{note}")
    };
    message.content = vec![ContentPart::Text {
        kind: TextPartKind::OutputText,
        text,
    }];
}

/// Why a workspace could not be read or written.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum WorkspaceError {
    /// The stored bytes are not a workspace.
    #[error("the saved workspace is corrupt: {message}")]
    Corrupt {
        /// What was wrong.
        message: String,
    },
    /// The workspace was written by a newer build.
    #[error("the saved workspace has version {version}, which this build cannot read")]
    UnsupportedVersion {
        /// The stored version.
        version: u64,
    },
    /// Two sessions share an id.
    #[error("the saved workspace lists session {id} twice")]
    DuplicateSession {
        /// The repeated id.
        id: String,
    },
    /// The workspace could not be encoded.
    #[error("could not encode the workspace: {message}")]
    Encode {
        /// Encoder detail.
        message: String,
    },
    /// The host storage failed.
    #[error("workspace storage failed: {message}")]
    Storage {
        /// Host detail.
        message: String,
    },
}

fn encode_error(error: &serde_json::Error) -> WorkspaceError {
    WorkspaceError::Encode {
        message: error.to_string(),
    }
}

/// Encodes `workspace` as JSON.
///
/// # Errors
///
/// [`WorkspaceError::Encode`].
pub fn encode(workspace: &Workspace) -> Result<Vec<u8>, WorkspaceError> {
    let sessions = workspace
        .sessions
        .iter()
        .map(|session| {
            let mut entry = Map::new();
            entry.insert("revision".into(), Value::from(session.revision));
            entry.insert(
                "session".into(),
                serde_json::to_value(&session.snapshot).map_err(|error| encode_error(&error))?,
            );
            Ok(Value::Object(entry))
        })
        .collect::<Result<Vec<_>, WorkspaceError>>()?;
    let mut object = Map::new();
    object.insert("version".into(), Value::from(workspace.version));
    object.insert("sessions".into(), Value::Array(sessions));
    object.insert(
        "drafts".into(),
        Value::Object(
            workspace
                .drafts
                .iter()
                .map(|(id, text)| (id.clone(), Value::String(text.clone())))
                .collect(),
        ),
    );
    serde_json::to_vec(&Value::Object(object)).map_err(|error| encode_error(&error))
}

/// Decodes [`encode`]'s output, without recovery.
///
/// # Errors
///
/// [`WorkspaceError::Corrupt`], [`WorkspaceError::UnsupportedVersion`] and
/// [`WorkspaceError::DuplicateSession`].
pub fn decode(bytes: &[u8]) -> Result<Workspace, WorkspaceError> {
    let corrupt = |message: String| WorkspaceError::Corrupt { message };
    let value: Value = serde_json::from_slice(bytes).map_err(|error| corrupt(error.to_string()))?;
    let object = as_object(&value, "workspace").map_err(corrupt)?;
    let version = opt_u64(object, "version")
        .map_err(corrupt)?
        .ok_or_else(|| corrupt("`version` is missing".into()))?;
    if version != WORKSPACE_VERSION {
        return Err(WorkspaceError::UnsupportedVersion { version });
    }
    let mut ids = BTreeSet::new();
    let sessions = opt_array(object, "sessions")
        .map_err(corrupt)?
        .ok_or_else(|| corrupt("`sessions` is missing".into()))?
        .iter()
        .map(|entry| {
            let entry = as_object(entry, "session entry").map_err(corrupt)?;
            let revision = opt_u64(entry, "revision")
                .map_err(corrupt)?
                .ok_or_else(|| corrupt("`revision` is missing".into()))?;
            let snapshot: SessionSnapshot = omnigent_protocol::FromWire::from_value(
                entry
                    .get("session")
                    .cloned()
                    .ok_or_else(|| corrupt("`session` is missing".into()))?,
            )
            .map_err(|error| corrupt(error.to_string()))?;
            if !ids.insert(snapshot.id.clone()) {
                return Err(WorkspaceError::DuplicateSession { id: snapshot.id });
            }
            Ok(WorkspaceSession { revision, snapshot })
        })
        .collect::<Result<Vec<_>, WorkspaceError>>()?;
    let drafts = opt_object(object, "drafts")
        .map_err(corrupt)?
        .map(|drafts| {
            drafts
                .iter()
                .map(|(id, text)| {
                    text.as_str()
                        .map(|text| (id.clone(), text.to_owned()))
                        .ok_or_else(|| corrupt(format!("draft {id:?} is not a string")))
                })
                .collect::<Result<BTreeMap<_, _>, WorkspaceError>>()
        })
        .transpose()?
        .unwrap_or_default();
    Ok(Workspace {
        version,
        sessions,
        drafts,
    })
}

/// The host's storage for the workspace file (on Apple, an atomic write with complete file
/// protection unless open). `read` returns `None` when nothing was saved yet.
pub trait WorkspaceStorage {
    /// The stored bytes.
    fn read(&self) -> impl Future<Output = Result<Option<Vec<u8>>, WorkspaceError>>;
    /// Replaces the stored bytes atomically.
    fn write(&self, bytes: Vec<u8>) -> impl Future<Output = Result<(), WorkspaceError>>;
}

/// Loads and saves the workspace through the host's [`WorkspaceStorage`].
#[derive(Debug)]
pub struct WorkspaceStore<S> {
    storage: S,
}

impl<S: WorkspaceStorage> WorkspaceStore<S> {
    /// A store over `storage`.
    pub const fn new(storage: S) -> Self {
        Self { storage }
    }

    /// The storage.
    pub const fn storage(&self) -> &S {
        &self.storage
    }

    /// The saved workspace, recovered, or `None` when nothing was saved. Never writes.
    ///
    /// # Errors
    ///
    /// The storage error, or see [`decode`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host storage; WASM hosts are !Send by design"
    )]
    pub async fn load(&self) -> Result<Option<Workspace>, WorkspaceError> {
        let Some(bytes) = self.storage.read().await? else {
            return Ok(None);
        };
        Ok(Some(decode(&bytes)?.recovering_interrupted_replies()))
    }

    /// Saves `workspace`.
    ///
    /// # Errors
    ///
    /// [`WorkspaceError::Encode`] or the storage error.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host storage; WASM hosts are !Send by design"
    )]
    pub async fn save(&self, workspace: &Workspace) -> Result<(), WorkspaceError> {
        self.storage.write(encode(workspace)?).await
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::future::ready;

    use futures::executor::block_on;
    use serde_json::json;

    use super::*;

    #[derive(Debug, Default)]
    struct MemoryFile {
        bytes: RefCell<Option<Vec<u8>>>,
        writes: RefCell<usize>,
    }

    impl WorkspaceStorage for MemoryFile {
        fn read(&self) -> impl Future<Output = Result<Option<Vec<u8>>, WorkspaceError>> {
            ready(Ok(self.bytes.borrow().clone()))
        }

        fn write(&self, bytes: Vec<u8>) -> impl Future<Output = Result<(), WorkspaceError>> {
            *self.bytes.borrow_mut() = Some(bytes);
            *self.writes.borrow_mut() += 1;
            ready(Ok(()))
        }
    }

    fn running_session() -> WorkspaceSession {
        let snapshot = omnigent_protocol::FromWire::from_value(json!({
            "id": "running", "status": "running", "created_at": 1, "title": "Demo",
            "items": [{
                "id": "reply", "type": "message", "role": "assistant", "status": "in_progress",
                "content": [{"type": "output_text", "text": "Partial"}]
            }]
        }))
        .unwrap();
        WorkspaceSession {
            revision: 8,
            snapshot,
        }
    }

    fn text_of(session: &WorkspaceSession) -> String {
        match &session.snapshot.items[0].data {
            ItemData::Message(message) => message.visible_text(),
            other => panic!("not a message: {other:?}"),
        }
    }

    #[test]
    fn a_note_is_only_appended_to_messages() {
        let mut item: omnigent_protocol::ConversationItem = serde_json::from_value(json!({
            "id": "i1", "type": "reasoning", "summary": [],
        }))
        .unwrap();
        let before = item.clone();
        append_text(&mut item, "stopped");
        assert_eq!(item, before);
    }

    #[test]
    fn recovery_preserves_partial_text_and_ends_streaming() {
        let drafts = BTreeMap::from([("running".to_owned(), "Next question".to_owned())]);
        let recovered =
            Workspace::new(vec![running_session()], drafts).recovering_interrupted_replies();
        let session = &recovered.sessions[0];
        assert_eq!(session.revision, 9);
        assert_eq!(session.snapshot.status, SessionStatus::Idle);
        assert_eq!(
            text_of(session),
            "Partial\n\nSample reply interrupted when the app closed."
        );
        assert!(!is_streaming(&session.snapshot.items[0]));
        assert_eq!(recovered.drafts["running"], "Next question");
        assert_eq!(
            recovered.clone().recovering_interrupted_replies(),
            recovered
        );
    }

    #[test]
    fn empty_streaming_reply_becomes_the_note() {
        let mut session = running_session();
        if let ItemData::Message(message) = &mut session.snapshot.items[0].data {
            message.content.clear();
        }
        let recovered =
            Workspace::new(vec![session], BTreeMap::new()).recovering_interrupted_replies();
        assert_eq!(text_of(&recovered.sessions[0]), INTERRUPTED_REPLY_NOTE);
    }

    #[test]
    fn corrupt_or_future_store_throws_and_leaves_file_untouched() {
        let file = MemoryFile::default();
        *file.bytes.borrow_mut() = Some(b"not-json".to_vec());
        let store = WorkspaceStore::new(file);
        assert!(matches!(
            block_on(store.load()),
            Err(WorkspaceError::Corrupt { .. })
        ));
        assert_eq!(
            store.storage().bytes.borrow().as_deref(),
            Some(&b"not-json"[..])
        );
        assert_eq!(*store.storage().writes.borrow(), 0);
        let mut future = Workspace::new(Vec::new(), BTreeMap::new());
        future.version = 999;
        block_on(store.save(&future)).unwrap();
        let saved = store.storage().bytes.borrow().clone();
        assert_eq!(
            block_on(store.load()),
            Err(WorkspaceError::UnsupportedVersion { version: 999 })
        );
        assert_eq!(*store.storage().bytes.borrow(), saved);
    }

    #[test]
    fn duplicate_session_i_ds_are_rejected_by_store() {
        let store = WorkspaceStore::new(MemoryFile::default());
        let session = crate::demo::sample_workspace().unwrap().sessions[0].clone();
        block_on(store.save(&Workspace::new(
            vec![session.clone(), session],
            BTreeMap::new(),
        )))
        .unwrap();
        assert_eq!(
            block_on(store.load()),
            Err(WorkspaceError::DuplicateSession {
                id: "demo-design".into()
            })
        );
    }

    #[test]
    fn missing_store_loads_nothing() {
        let store = WorkspaceStore::new(MemoryFile::default());
        assert_eq!(block_on(store.load()), Ok(None));
    }

    #[test]
    fn an_encoder_failure_reads_as_an_encode_error() {
        let failure = serde_json::from_str::<Value>("{").unwrap_err();
        let message = failure.to_string();
        assert_eq!(encode_error(&failure), WorkspaceError::Encode { message });
    }
}
