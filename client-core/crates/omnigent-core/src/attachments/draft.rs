//! Per-session attachment drafts: staging, upload state, and send batches.
//!
//! The store is sans-IO. The host runs each upload:
//!
//! 1. [`AttachmentDraftStore::begin_upload`] admits it and returns an [`UploadAttempt`];
//! 2. the host builds the request with [`super::UploadTarget::request`], sends it, and reports
//!    progress through [`AttachmentDraftStore::update_progress`];
//! 3. the host maps the result with [`super::UploadTarget::response`] and passes it to
//!    [`AttachmentDraftStore::finish_upload`]. To cancel, the host cancels its request and reports
//!    [`crate::http::TransportError::Cancelled`], which leaves the item uncertain.
//!
//! Sending a message works the same way: [`AttachmentDraftStore::begin_submission`] captures the
//! uploaded references, and [`AttachmentDraftStore::finish_submission`] applies the outcome to
//! exactly the files captured. Uploaded files are reused across explicit retries; uncertain uploads
//! and uncertain sends are never retried automatically.
//!
//! A queued message takes its draft's uploaded files with it: [`AttachmentDraftStore::hold`]
//! moves them into a hold that [`AttachmentDraftStore::begin_held_submission`] sends later,
//! [`AttachmentDraftStore::restore`] puts back in the draft, or [`AttachmentDraftStore::discard`]
//! drops.

use std::collections::{BTreeMap, BTreeSet};

use super::policy::{MAX_DRAFT_BYTES, MAX_FILES_PER_DRAFT, MAX_STORED_BYTES, UploadFile};
use super::upload::{UploadError, UploadUncertainty, UploadedAttachment};
use crate::ledger::SubmissionOutcome;

/// The draft a file belongs to: one session in one delivery scope (server plus account).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct DraftKey {
    /// Delivery scope (server plus account).
    pub scope: String,
    /// Session id.
    pub session_id: String,
}

impl DraftKey {
    /// A key for `session_id` in `scope`.
    pub fn new(scope: impl Into<String>, session_id: impl Into<String>) -> Self {
        Self {
            scope: scope.into(),
            session_id: session_id.into(),
        }
    }
}

/// Identifies one staged file. Unique within one store.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct DraftItemId(u64);

impl DraftItemId {
    /// The raw id, for FFI mirrors and UI identity.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

/// Identifies the files held for one queued message. Unique within one store.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct HoldId(u64);

impl HoldId {
    /// The raw id, for FFI mirrors.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }

    /// The id with raw value `id`, as an FFI mirror passes it back.
    #[must_use]
    pub const fn new(id: u64) -> Self {
        Self(id)
    }
}

/// Where a staged file's upload stands.
#[derive(Debug, Clone, PartialEq)]
pub enum UploadState {
    /// Not uploaded yet.
    Staged,
    /// Upload in flight; progress in `0.0..=1.0`, never decreasing.
    Uploading {
        /// Fraction sent.
        progress: f64,
    },
    /// Stored on the server.
    Uploaded(UploadedAttachment),
    /// The server refused the file; an explicit retry may upload it again.
    Failed(UploadError),
    /// The file may already be stored. It is kept but cannot be retried or sent; the user must
    /// review the session's files and remove it.
    Uncertain(UploadUncertainty),
}

/// One staged file.
#[derive(Debug, Clone, PartialEq)]
pub struct DraftItem {
    id: DraftItemId,
    file: UploadFile,
    state: UploadState,
}

impl DraftItem {
    /// The item's id.
    #[must_use]
    pub const fn id(&self) -> DraftItemId {
        self.id
    }

    /// The staged file; its bytes are kept until the item is removed.
    #[must_use]
    pub const fn file(&self) -> &UploadFile {
        &self.file
    }

    /// Upload state.
    #[must_use]
    pub const fn state(&self) -> &UploadState {
        &self.state
    }
}

/// The files staged for one session.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AttachmentDraft {
    items: Vec<DraftItem>,
    selection_error: Option<String>,
}

impl AttachmentDraft {
    /// Staged files, in the order they were added.
    #[must_use]
    pub fn items(&self) -> &[DraftItem] {
        &self.items
    }

    /// The last file-picker error the host recorded.
    #[must_use]
    pub fn selection_error(&self) -> Option<&str> {
        self.selection_error.as_deref()
    }

    /// Whether any file is staged.
    #[must_use]
    pub const fn has_attachments(&self) -> bool {
        !self.items.is_empty()
    }

    fn bytes(&self) -> usize {
        bytes_of(&self.items)
    }

    fn item(&self, id: DraftItemId) -> Option<&DraftItem> {
        self.items.iter().find(|item| item.id == id)
    }

    fn item_mut(&mut self, id: DraftItemId) -> Option<&mut DraftItem> {
        self.items.iter_mut().find(|item| item.id == id)
    }
}

fn bytes_of(items: &[DraftItem]) -> usize {
    items.iter().fold(0, |total, item| {
        total.saturating_add(item.file.data().len())
    })
}

/// An upload the store admitted. Pass it back to report progress and the result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadAttempt {
    id: u64,
    key: DraftKey,
    item: DraftItemId,
}

impl UploadAttempt {
    /// The draft the file belongs to.
    #[must_use]
    pub const fn key(&self) -> &DraftKey {
        &self.key
    }

    /// The file being uploaded.
    #[must_use]
    pub const fn item(&self) -> DraftItemId {
        self.item
    }
}

/// The attachments captured for one message send.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachmentSubmission {
    id: u64,
    key: DraftKey,
    attachments: Vec<UploadedAttachment>,
    item_ids: BTreeSet<DraftItemId>,
    /// The hold the files were sent from, rather than the draft.
    hold: Option<HoldId>,
}

impl AttachmentSubmission {
    /// The draft the batch was taken from.
    #[must_use]
    pub const fn key(&self) -> &DraftKey {
        &self.key
    }

    /// The uploaded references to send, in draft order.
    #[must_use]
    pub fn attachments(&self) -> &[UploadedAttachment] {
        &self.attachments
    }
}

/// Why the store refused a request. Nothing changes when one is returned.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DraftError {
    /// Adding the file would exceed the per-draft count or byte cap, or the cap across drafts.
    #[error(
        "keep at most {MAX_FILES_PER_DRAFT} attachments and 25 MB per draft (100 MB across drafts)"
    )]
    DraftLimit,
    /// No such file in this draft.
    #[error("no such attachment in this draft")]
    UnknownItem,
    /// The file is part of a send in flight or an unreviewed uncertain send.
    #[error("this attachment is part of a message that is being sent or needs review")]
    Locked,
    /// The file's upload is in flight.
    #[error("this attachment is uploading")]
    UploadInFlight,
    /// The file is already uploaded; it is reused rather than uploaded again.
    #[error("this attachment is already uploaded")]
    AlreadyUploaded,
    /// The file's upload outcome is uncertain, so it must not be uploaded again.
    #[error("this attachment may already be stored; review the session files before retrying")]
    UploadUncertain,
    /// The attempt is not the upload in flight for its file.
    #[error("this upload attempt is no longer current")]
    StaleAttempt,
    /// Progress must be a finite number.
    #[error("upload progress must be a finite number")]
    InvalidProgress,
    /// A send is in flight, an earlier send is unreviewed, or a file is not uploaded.
    #[error("wait for attachments to finish uploading and review any errors")]
    NotReady,
    /// The batch is not the send in flight for its draft (a duplicate or late completion).
    #[error("this attachment batch is no longer current")]
    StaleSubmission,
    /// The store has issued every possible id.
    #[error("attachment draft ids are exhausted")]
    IdsExhausted,
}

/// All attachment drafts of one app session.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AttachmentDraftStore {
    next_id: u64,
    drafts: BTreeMap<DraftKey, AttachmentDraft>,
    submissions: BTreeMap<DraftKey, AttachmentSubmission>,
    uncertain_submissions: BTreeSet<DraftKey>,
    in_flight: BTreeMap<DraftItemId, u64>,
    held: BTreeMap<HoldId, (DraftKey, Vec<DraftItem>)>,
}

const EMPTY_DRAFT: &AttachmentDraft = &AttachmentDraft {
    items: Vec::new(),
    selection_error: None,
};

impl AttachmentDraftStore {
    /// An empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    fn allocate(&mut self) -> Result<u64, DraftError> {
        let id = self.next_id;
        self.next_id = id.checked_add(1).ok_or(DraftError::IdsExhausted)?;
        Ok(id)
    }

    /// The draft for `key` (empty if nothing was ever staged there).
    #[must_use]
    pub fn draft(&self, key: &DraftKey) -> &AttachmentDraft {
        self.drafts.get(key).unwrap_or(EMPTY_DRAFT)
    }

    /// Stages `file` in `key`'s draft.
    ///
    /// # Errors
    ///
    /// [`DraftError::DraftLimit`] past [`MAX_FILES_PER_DRAFT`] files or [`MAX_DRAFT_BYTES`] in
    /// the draft, or [`MAX_STORED_BYTES`] across all drafts.
    pub fn add(&mut self, file: UploadFile, key: &DraftKey) -> Result<DraftItemId, DraftError> {
        let draft = self.draft(key);
        let size = file.data().len();
        let stored = self
            .drafts
            .values()
            .map(|draft| draft.items.as_slice())
            .chain(self.held.values().map(|(_, items)| items.as_slice()))
            .fold(0, |total: usize, items| {
                total.saturating_add(bytes_of(items))
            });
        if draft.items.len() >= MAX_FILES_PER_DRAFT
            || draft.bytes().saturating_add(size) > MAX_DRAFT_BYTES
            || stored.saturating_add(size) > MAX_STORED_BYTES
        {
            return Err(DraftError::DraftLimit);
        }
        let id = DraftItemId(self.allocate()?);
        self.drafts
            .entry(key.clone())
            .or_default()
            .items
            .push(DraftItem {
                id,
                file,
                state: UploadState::Staged,
            });
        Ok(id)
    }

    /// Records (or clears) the file-picker error shown with `key`'s draft.
    pub fn record_selection_error(&mut self, key: &DraftKey, message: Option<String>) {
        self.drafts.entry(key.clone()).or_default().selection_error = message;
    }

    /// Whether `item` is part of a send in flight, or `key` has an unreviewed uncertain send.
    #[must_use]
    pub fn is_locked(&self, key: &DraftKey, item: DraftItemId) -> bool {
        self.submissions
            .get(key)
            .is_some_and(|batch| batch.item_ids.contains(&item))
            || self.uncertain_submissions.contains(key)
    }

    /// Admits an upload of `item`, which must be staged or failed.
    ///
    /// # Errors
    ///
    /// [`DraftError::UnknownItem`], [`DraftError::Locked`], [`DraftError::UploadInFlight`],
    /// [`DraftError::AlreadyUploaded`] or [`DraftError::UploadUncertain`].
    pub fn begin_upload(
        &mut self,
        key: &DraftKey,
        item: DraftItemId,
    ) -> Result<UploadAttempt, DraftError> {
        if self.is_locked(key, item) {
            return Err(DraftError::Locked);
        }
        if self.in_flight.contains_key(&item) {
            return Err(DraftError::UploadInFlight);
        }
        match self.draft(key).item(item).map(|item| &item.state) {
            None => return Err(DraftError::UnknownItem),
            Some(UploadState::Staged | UploadState::Failed(_)) => {}
            Some(UploadState::Uploading { .. }) => return Err(DraftError::UploadInFlight),
            Some(UploadState::Uploaded(_)) => return Err(DraftError::AlreadyUploaded),
            Some(UploadState::Uncertain(_)) => return Err(DraftError::UploadUncertain),
        }
        let id = self.allocate()?;
        self.set_state(key, item, UploadState::Uploading { progress: 0.0 })?;
        self.in_flight.insert(item, id);
        Ok(UploadAttempt {
            id,
            key: key.clone(),
            item,
        })
    }

    fn check_current(&self, attempt: &UploadAttempt) -> Result<(), DraftError> {
        if self.in_flight.get(&attempt.item) == Some(&attempt.id) {
            Ok(())
        } else {
            Err(DraftError::StaleAttempt)
        }
    }

    fn set_state(
        &mut self,
        key: &DraftKey,
        item: DraftItemId,
        state: UploadState,
    ) -> Result<(), DraftError> {
        let item = self
            .drafts
            .get_mut(key)
            .and_then(|draft| draft.item_mut(item))
            .ok_or(DraftError::UnknownItem)?;
        item.state = state;
        Ok(())
    }

    /// Reports upload progress. Values are clamped to `0.0..=1.0` and never move backwards.
    ///
    /// # Errors
    ///
    /// [`DraftError::StaleAttempt`] for an attempt that is no longer in flight;
    /// [`DraftError::InvalidProgress`] for a non-finite value.
    pub fn update_progress(
        &mut self,
        attempt: &UploadAttempt,
        progress: f64,
    ) -> Result<(), DraftError> {
        self.check_current(attempt)?;
        if !progress.is_finite() {
            return Err(DraftError::InvalidProgress);
        }
        let previous = match self
            .draft(&attempt.key)
            .item(attempt.item)
            .map(|item| &item.state)
        {
            Some(UploadState::Uploading { progress }) => *progress,
            Some(_) => return Err(DraftError::StaleAttempt),
            None => return Err(DraftError::UnknownItem),
        };
        let progress = previous.max(progress.clamp(0.0, 1.0));
        self.set_state(
            &attempt.key,
            attempt.item,
            UploadState::Uploading { progress },
        )
    }

    /// Applies the mapped upload result. An upload confirmed for another session is uncertain;
    /// [`UploadError::Uncertain`] keeps the item uncertain; any other error marks it failed.
    ///
    /// # Errors
    ///
    /// [`DraftError::StaleAttempt`] for an attempt that is no longer in flight.
    pub fn finish_upload(
        &mut self,
        attempt: &UploadAttempt,
        result: Result<UploadedAttachment, UploadError>,
    ) -> Result<(), DraftError> {
        self.check_current(attempt)?;
        self.in_flight.remove(&attempt.item);
        let state = match result {
            Ok(uploaded) if uploaded.session_id == attempt.key.session_id => {
                UploadState::Uploaded(uploaded)
            }
            Ok(uploaded) => UploadState::Uncertain(UploadUncertainty::SessionMismatch {
                returned: uploaded.session_id,
            }),
            Err(UploadError::Uncertain(reason)) => UploadState::Uncertain(reason),
            Err(error) => UploadState::Failed(error),
        };
        self.set_state(&attempt.key, attempt.item, state)
    }

    /// Removes a staged file and its bytes.
    ///
    /// # Errors
    ///
    /// [`DraftError::Locked`], [`DraftError::UploadInFlight`] or [`DraftError::UnknownItem`].
    pub fn remove(&mut self, key: &DraftKey, item: DraftItemId) -> Result<(), DraftError> {
        if self.is_locked(key, item) {
            return Err(DraftError::Locked);
        }
        if self.in_flight.contains_key(&item) {
            return Err(DraftError::UploadInFlight);
        }
        let draft = self.drafts.get_mut(key).ok_or(DraftError::UnknownItem)?;
        let before = draft.items.len();
        draft.items.retain(|candidate| candidate.id != item);
        if draft.items.len() == before {
            return Err(DraftError::UnknownItem);
        }
        Ok(())
    }

    /// Whether [`Self::begin_submission`] would succeed: no send in flight or unreviewed, and
    /// every staged file uploaded.
    #[must_use]
    pub fn can_submit(&self, key: &DraftKey) -> bool {
        !self.submissions.contains_key(key)
            && !self.uncertain_submissions.contains(key)
            && self
                .draft(key)
                .items
                .iter()
                .all(|item| matches!(item.state, UploadState::Uploaded(_)))
    }

    /// Captures the uploaded references of `key`'s draft for one send.
    ///
    /// # Errors
    ///
    /// [`DraftError::NotReady`] unless [`Self::can_submit`].
    pub fn begin_submission(&mut self, key: &DraftKey) -> Result<AttachmentSubmission, DraftError> {
        if !self.can_submit(key) {
            return Err(DraftError::NotReady);
        }
        let id = self.allocate()?;
        let items = &self.draft(key).items;
        let batch = AttachmentSubmission {
            id,
            key: key.clone(),
            attachments: items
                .iter()
                .filter_map(|item| match &item.state {
                    UploadState::Uploaded(uploaded) => Some(uploaded.clone()),
                    _ => None,
                })
                .collect(),
            item_ids: items.iter().map(|item| item.id).collect(),
            hold: None,
        };
        self.submissions.insert(key.clone(), batch.clone());
        Ok(batch)
    }

    /// Applies a send's outcome: accepted removes exactly the captured files, rejected keeps them
    /// for an explicit retry, uncertain keeps them and blocks the draft until reviewed.
    ///
    /// # Errors
    ///
    /// [`DraftError::StaleSubmission`] when `batch` is not the send in flight for its draft.
    pub fn finish_submission(
        &mut self,
        batch: &AttachmentSubmission,
        outcome: SubmissionOutcome,
    ) -> Result<(), DraftError> {
        if self.submissions.get(&batch.key) != Some(batch) {
            return Err(DraftError::StaleSubmission);
        }
        self.submissions.remove(&batch.key);
        match outcome {
            SubmissionOutcome::Accepted if batch.hold.is_some() => {
                self.held.retain(|id, _| Some(*id) != batch.hold);
            }
            SubmissionOutcome::Accepted => {
                if let Some(draft) = self.drafts.get_mut(&batch.key) {
                    draft
                        .items
                        .retain(|item| !batch.item_ids.contains(&item.id));
                }
            }
            SubmissionOutcome::Rejected => {}
            SubmissionOutcome::Uncertain => {
                self.uncertain_submissions.insert(batch.key.clone());
            }
        }
        Ok(())
    }

    /// Moves every file of `key`'s draft into a new hold, for a message queued to send later.
    /// `None` when the draft has no files.
    ///
    /// # Errors
    ///
    /// [`DraftError::NotReady`] unless [`Self::can_submit`]: every file must be uploaded first.
    pub fn hold(&mut self, key: &DraftKey) -> Result<Option<HoldId>, DraftError> {
        if !self.draft(key).has_attachments() {
            return Ok(None);
        }
        if !self.can_submit(key) {
            return Err(DraftError::NotReady);
        }
        let id = HoldId(self.allocate()?);
        let items = self
            .drafts
            .get_mut(key)
            .map(|draft| std::mem::take(&mut draft.items))
            .unwrap_or_default();
        self.held.insert(id, (key.clone(), items));
        Ok(Some(id))
    }

    /// The files of `key`'s hold `id`, in the order they were added.
    ///
    /// # Errors
    ///
    /// [`DraftError::UnknownItem`] when `key` has no such hold.
    pub fn held(&self, key: &DraftKey, id: HoldId) -> Result<&[DraftItem], DraftError> {
        match self.held.get(&id) {
            Some((owner, items)) if owner == key => Ok(items),
            _ => Err(DraftError::UnknownItem),
        }
    }

    /// Puts hold `id`'s files back at the end of `key`'s draft (a queued message pulled back to
    /// edit).
    ///
    /// # Errors
    ///
    /// [`DraftError::UnknownItem`], [`DraftError::Locked`] while the hold is being sent, and
    /// [`DraftError::DraftLimit`] when the draft has no room for them; the hold then stays.
    pub fn restore(&mut self, key: &DraftKey, id: HoldId) -> Result<(), DraftError> {
        let items = self.held(key, id)?;
        if self.is_sending_hold(key, id) {
            return Err(DraftError::Locked);
        }
        let draft = self.draft(key);
        if draft.items.len() + items.len() > MAX_FILES_PER_DRAFT
            || draft.bytes().saturating_add(bytes_of(items)) > MAX_DRAFT_BYTES
        {
            return Err(DraftError::DraftLimit);
        }
        let (_, items) = self.held.remove(&id).ok_or(DraftError::UnknownItem)?;
        self.drafts
            .entry(key.clone())
            .or_default()
            .items
            .extend(items);
        Ok(())
    }

    /// Drops hold `id` (its queued message was removed). Files stay stored on the server.
    ///
    /// # Errors
    ///
    /// [`DraftError::UnknownItem`] and [`DraftError::Locked`] while the hold is being sent.
    pub fn discard(&mut self, key: &DraftKey, id: HoldId) -> Result<(), DraftError> {
        self.held(key, id)?;
        if self.is_sending_hold(key, id) {
            return Err(DraftError::Locked);
        }
        self.held.remove(&id);
        Ok(())
    }

    fn is_sending_hold(&self, key: &DraftKey, id: HoldId) -> bool {
        self.submissions
            .get(key)
            .is_some_and(|batch| batch.hold == Some(id))
    }

    /// Captures hold `id`'s files for one send. An accepted send drops the hold; a rejected or
    /// uncertain one keeps it, as [`Self::finish_submission`] says.
    ///
    /// # Errors
    ///
    /// [`DraftError::UnknownItem`]; [`DraftError::NotReady`] while a send to `key` is in flight
    /// or unreviewed.
    pub fn begin_held_submission(
        &mut self,
        key: &DraftKey,
        id: HoldId,
    ) -> Result<AttachmentSubmission, DraftError> {
        let items = self.held(key, id)?;
        if self.submissions.contains_key(key) || self.uncertain_submissions.contains(key) {
            return Err(DraftError::NotReady);
        }
        let attachments = items
            .iter()
            .filter_map(|item| match &item.state {
                UploadState::Uploaded(uploaded) => Some(uploaded.clone()),
                _ => None,
            })
            .collect();
        let item_ids = items.iter().map(|item| item.id).collect();
        let batch = AttachmentSubmission {
            id: self.allocate()?,
            key: key.clone(),
            attachments,
            item_ids,
            hold: Some(id),
        };
        self.submissions.insert(key.clone(), batch.clone());
        Ok(batch)
    }

    /// Records that the user reviewed `key`'s uncertain send. Returns whether it was uncertain.
    /// Uncertain uploads stay uncertain; only sends are acknowledged here.
    pub fn acknowledge_uncertainty(&mut self, key: &DraftKey) -> bool {
        self.uncertain_submissions.remove(key)
    }
}

#[cfg(test)]
#[path = "draft_hold_tests.rs"]
mod hold_tests;

#[cfg(test)]
mod tests {
    use url::Url;

    use super::*;
    use crate::attachments::policy::MAX_PDF_BYTES;
    use crate::http::TransportError;

    fn key() -> DraftKey {
        DraftKey::new("server/account", "session_a")
    }

    fn file_named(name: &str) -> UploadFile {
        UploadFile::new(name, None, b"retained bytes".to_vec()).unwrap()
    }

    fn file() -> UploadFile {
        file_named("notes.txt")
    }

    /// Stands in for the host's uploader and counts how many uploads actually ran.
    #[derive(Default)]
    struct Uploader {
        count: usize,
    }

    impl Uploader {
        fn upload(
            &mut self,
            attempt: &UploadAttempt,
            store: &AttachmentDraftStore,
        ) -> UploadedAttachment {
            self.count += 1;
            let item = store.draft(attempt.key()).item(attempt.item()).unwrap();
            UploadedAttachment {
                server_url: Url::parse("http://127.0.0.1:6767").unwrap(),
                user_id: None,
                session_id: attempt.key().session_id.clone(),
                id: format!("file_{}", self.count),
                filename: item.file().filename().to_owned(),
                is_image: false,
            }
        }

        /// Runs a whole upload, as the Swift `store.upload(_:in:using:)` does.
        fn run(
            &mut self,
            store: &mut AttachmentDraftStore,
            key: &DraftKey,
            item: DraftItemId,
        ) -> Result<(), DraftError> {
            let attempt = store.begin_upload(key, item)?;
            let uploaded = self.upload(&attempt, store);
            store.finish_upload(&attempt, Ok(uploaded))
        }
    }

    fn fail(
        store: &mut AttachmentDraftStore,
        key: &DraftKey,
        item: DraftItemId,
        error: UploadError,
    ) -> Result<(), DraftError> {
        let attempt = store.begin_upload(key, item)?;
        store.finish_upload(&attempt, Err(error))
    }

    #[test]
    fn progress_for_an_attempt_whose_item_was_removed_elsewhere_is_stale() {
        let mut store = AttachmentDraftStore::default();
        let item = store.add(file(), &key()).unwrap();
        let attempt = store.begin_upload(&key(), item).unwrap();
        store
            .finish_upload(&attempt, Err(UploadError::Rejected { status: 413 }))
            .unwrap();
        assert_eq!(
            store.update_progress(&attempt, 0.5),
            Err(DraftError::StaleAttempt)
        );
    }

    #[test]
    fn ids_keys_and_the_selection_error_read_back() {
        assert_eq!(HoldId::new(7).get(), 7);
        let mut store = AttachmentDraftStore::default();
        assert_eq!(store.draft(&key()).selection_error(), None);
        store.record_selection_error(&key(), Some("too big".to_owned()));
        assert_eq!(store.draft(&key()).selection_error(), Some("too big"));
        store.record_selection_error(&key(), None);
        assert_eq!(store.draft(&key()).selection_error(), None);
    }

    #[test]
    fn upload_attempts_cannot_cross_each_other() {
        let mut store = AttachmentDraftStore::default();
        let item = store.add(file(), &key()).unwrap();
        let attempt = store.begin_upload(&key(), item).unwrap();
        assert_eq!(attempt.key(), &key());
        assert_eq!(
            store.begin_upload(&key(), item),
            Err(DraftError::UploadInFlight)
        );
        assert_eq!(store.remove(&key(), item), Err(DraftError::UploadInFlight));
        store
            .finish_upload(&attempt, Err(UploadError::Rejected { status: 413 }))
            .unwrap();
        // A late progress report for an attempt that already ended.
        assert_eq!(
            store.update_progress(&attempt, 0.5),
            Err(DraftError::StaleAttempt)
        );
    }

    #[test]
    fn draft_count_and_aggregate_byte_limits() {
        let mut store = AttachmentDraftStore::new();
        for _ in 0..MAX_FILES_PER_DRAFT {
            store.add(file(), &key()).unwrap();
        }
        assert_eq!(store.add(file(), &key()), Err(DraftError::DraftLimit));
        let big = UploadFile::new("large.pdf", None, vec![0; MAX_PDF_BYTES]).unwrap();
        let other = DraftKey::new(key().scope, "other");
        store.add(big.clone(), &other).unwrap();
        assert_eq!(store.add(big.clone(), &other), Err(DraftError::DraftLimit));
        for index in 0..3 {
            store
                .add(
                    big.clone(),
                    &DraftKey::new(key().scope, format!("big_{index}")),
                )
                .unwrap();
        }
        assert_eq!(
            store.add(big, &DraftKey::new(key().scope, "over_global")),
            Err(DraftError::DraftLimit)
        );
    }

    #[test]
    fn successful_upload_is_reused_on_explicit_send_retry_and_scoped_to_session() {
        let mut store = AttachmentDraftStore::new();
        let mut uploader = Uploader::default();
        let id = store.add(file(), &key()).unwrap();
        uploader.run(&mut store, &key(), id).unwrap();
        assert_eq!(
            uploader.run(&mut store, &key(), id),
            Err(DraftError::AlreadyUploaded)
        );
        assert_eq!(uploader.count, 1);
        let first = store.begin_submission(&key()).unwrap();
        assert_eq!(store.begin_submission(&key()), Err(DraftError::NotReady));
        assert_eq!(store.remove(&key(), id), Err(DraftError::Locked));
        assert_eq!(store.draft(&key()).items().len(), 1);
        store
            .finish_submission(&first, SubmissionOutcome::Rejected)
            .unwrap();
        assert_eq!(
            store.draft(&key()).items()[0].file().data(),
            b"retained bytes"
        );
        let retry = store.begin_submission(&key()).unwrap();
        assert_eq!(retry.attachments(), first.attachments());
        store
            .finish_submission(&retry, SubmissionOutcome::Accepted)
            .unwrap();
        assert!(!store.draft(&key()).has_attachments());
        let other = DraftKey::new("other/account", key().session_id);
        assert!(!store.draft(&other).has_attachments());
    }

    #[test]
    fn accepted_snapshot_only_removes_captured_files_even_after_scope_switch() {
        let mut store = AttachmentDraftStore::new();
        let mut uploader = Uploader::default();
        let first = store.add(file(), &key()).unwrap();
        uploader.run(&mut store, &key(), first).unwrap();
        let batch = store.begin_submission(&key()).unwrap();
        let added_later = store.add(file_named("later.txt"), &key()).unwrap();
        let other = DraftKey::new("different-server/account", key().session_id);
        let other_id = store.add(file(), &other).unwrap();
        store
            .finish_submission(&batch, SubmissionOutcome::Accepted)
            .unwrap();
        let ids = |store: &AttachmentDraftStore, key: &DraftKey| -> Vec<DraftItemId> {
            store.draft(key).items().iter().map(DraftItem::id).collect()
        };
        assert_eq!(ids(&store, &key()), vec![added_later]);
        assert_eq!(ids(&store, &other), vec![other_id]);
        assert_eq!(
            store.finish_submission(&batch, SubmissionOutcome::Accepted),
            Err(DraftError::StaleSubmission)
        );
        assert_eq!(ids(&store, &key()), vec![added_later]);
    }

    #[test]
    fn uncertain_send_retains_files_and_blocks_duplicate_until_explicit_review() {
        let mut store = AttachmentDraftStore::new();
        let mut uploader = Uploader::default();
        let id = store.add(file(), &key()).unwrap();
        uploader.run(&mut store, &key(), id).unwrap();
        let batch = store.begin_submission(&key()).unwrap();
        store
            .finish_submission(&batch, SubmissionOutcome::Uncertain)
            .unwrap();
        assert!(!store.can_submit(&key()));
        assert_eq!(store.begin_submission(&key()), Err(DraftError::NotReady));
        assert_eq!(store.remove(&key(), id), Err(DraftError::Locked));
        assert!(store.draft(&key()).has_attachments());
        assert!(!store.acknowledge_uncertainty(&DraftKey::new("wrong", key().session_id)));
        assert!(!store.can_submit(&key()));
        assert!(store.acknowledge_uncertainty(&key()));
        let retry = store.begin_submission(&key()).unwrap();
        assert_eq!(retry.attachments(), batch.attachments());
        assert_eq!(uploader.count, 1);
    }

    #[test]
    fn rejected_upload_retains_file_and_explicit_retry_only_uploads_failed_item() {
        let mut store = AttachmentDraftStore::new();
        let mut uploader = Uploader::default();
        let ready = store.add(file_named("ready.txt"), &key()).unwrap();
        let failed = store.add(file_named("failed.txt"), &key()).unwrap();
        uploader.run(&mut store, &key(), ready).unwrap();
        fail(
            &mut store,
            &key(),
            failed,
            UploadError::Rejected { status: 413 },
        )
        .unwrap();
        assert!(!store.can_submit(&key()));
        assert_eq!(store.begin_submission(&key()), Err(DraftError::NotReady));
        let item = &store.draft(&key()).items()[1];
        assert_eq!(item.file().filename(), "failed.txt");
        assert_eq!(
            item.state(),
            &UploadState::Failed(UploadError::Rejected { status: 413 })
        );
        assert_eq!(
            uploader.run(&mut store, &key(), ready),
            Err(DraftError::AlreadyUploaded)
        );
        uploader.run(&mut store, &key(), failed).unwrap();
        assert!(store.can_submit(&key()));
        assert_eq!(uploader.count, 2);
    }

    #[test]
    fn uncertain_upload_cannot_be_retried_or_become_transcript_submission() {
        let mut store = AttachmentDraftStore::new();
        let id = store.add(file(), &key()).unwrap();
        let reason = UploadUncertainty::UnexpectedStatus { status: 500 };
        fail(
            &mut store,
            &key(),
            id,
            UploadError::Uncertain(reason.clone()),
        )
        .unwrap();
        let mut uploader = Uploader::default();
        assert_eq!(
            uploader.run(&mut store, &key(), id),
            Err(DraftError::UploadUncertain)
        );
        assert!(!store.acknowledge_uncertainty(&key()));
        assert_eq!(
            uploader.run(&mut store, &key(), id),
            Err(DraftError::UploadUncertain)
        );
        assert_eq!(uploader.count, 0);
        assert_eq!(store.begin_submission(&key()), Err(DraftError::NotReady));
        let item = &store.draft(&key()).items()[0];
        assert_eq!(item.file().data(), b"retained bytes");
        assert_eq!(item.state(), &UploadState::Uncertain(reason));
        // The user may still remove it after reviewing the session's files.
        store.remove(&key(), id).unwrap();
        assert!(!store.draft(&key()).has_attachments());
    }

    #[test]
    fn cancel_in_flight_preserves_bytes_and_prevents_concurrent_duplicate_upload() {
        let mut store = AttachmentDraftStore::new();
        let id = store.add(file(), &key()).unwrap();
        let attempt = store.begin_upload(&key(), id).unwrap();
        store.update_progress(&attempt, 0.4).unwrap();
        store.update_progress(&attempt, 0.1).unwrap();
        assert_eq!(
            store.draft(&key()).items()[0].state(),
            &UploadState::Uploading { progress: 0.4 }
        );
        assert_eq!(
            store.update_progress(&attempt, f64::NAN),
            Err(DraftError::InvalidProgress)
        );
        let mut uploader = Uploader::default();
        assert_eq!(
            uploader.run(&mut store, &key(), id),
            Err(DraftError::UploadInFlight)
        );
        assert_eq!(store.remove(&key(), id), Err(DraftError::UploadInFlight));
        assert!(store.draft(&key()).has_attachments());

        // The host cancels its request and reports the cancellation.
        let cancelled = UploadUncertainty::Transport(TransportError::Cancelled);
        store
            .finish_upload(&attempt, Err(UploadError::Uncertain(cancelled.clone())))
            .unwrap();
        let item = &store.draft(&key()).items()[0];
        assert_eq!(item.state(), &UploadState::Uncertain(cancelled));
        assert_eq!(item.file().data(), b"retained bytes");
        assert_eq!(uploader.count, 0);
        assert_eq!(
            store.update_progress(&attempt, 0.9),
            Err(DraftError::StaleAttempt)
        );
        assert_eq!(
            store.finish_upload(&attempt, Err(UploadError::Forbidden)),
            Err(DraftError::StaleAttempt)
        );
    }

    #[test]
    fn upload_confirmed_for_another_session_is_uncertain() {
        let mut store = AttachmentDraftStore::new();
        let id = store.add(file(), &key()).unwrap();
        let attempt = store.begin_upload(&key(), id).unwrap();
        let mut uploaded = Uploader::default().upload(&attempt, &store);
        uploaded.session_id = "session_b".into();
        store.finish_upload(&attempt, Ok(uploaded)).unwrap();
        assert_eq!(
            store.draft(&key()).items()[0].state(),
            &UploadState::Uncertain(UploadUncertainty::SessionMismatch {
                returned: "session_b".into()
            })
        );
        assert_eq!(
            store.remove(&key(), DraftItemId(999)),
            Err(DraftError::UnknownItem)
        );
        assert_eq!(
            store.begin_upload(&key(), DraftItemId(999)),
            Err(DraftError::UnknownItem)
        );
    }
}
