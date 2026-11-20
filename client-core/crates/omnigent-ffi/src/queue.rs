//! What a queued message carries: the composer's files held for it, and the reply draft's
//! quote blocks.

use omnigent_core::attachments::{HoldId, UploadFile};
use omnigent_core::reply_draft as core;

use crate::client::{ClientCore, DraftAttachment, MessageSent};
use crate::engine::Msg;
use crate::errors::CoreError;

/// The composer's files, taken out of its draft to go with a queued message.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HeldAttachments {
    /// Identifies the hold.
    pub id: u64,
    /// The files, in the order they were added.
    pub items: Vec<DraftAttachment>,
}

/// A file a message from outside the composer carries (a design tool's screenshot).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExternalAttachment {
    /// The file name.
    pub filename: String,
    /// The declared media type, if any.
    pub media_type: Option<String>,
    /// The bytes.
    pub data: Vec<u8>,
}

/// One quoted selection and the text typed before it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ReplyQuote {
    /// The text typed before the quote.
    pub before: String,
    /// The quoted text.
    pub text: String,
}

/// A composer draft with quote blocks (the web's `replyDraft`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ReplyDraft {
    /// The quotes, in order.
    pub quotes: Vec<ReplyQuote>,
    /// The text after the last quote.
    pub text: String,
}

impl From<ReplyDraft> for core::ReplyDraft {
    fn from(draft: ReplyDraft) -> Self {
        Self {
            quotes: draft
                .quotes
                .into_iter()
                .map(|quote| core::ReplyQuote {
                    before: quote.before,
                    text: quote.text,
                })
                .collect(),
            text: draft.text,
        }
    }
}

impl From<core::ReplyDraft> for ReplyDraft {
    fn from(draft: core::ReplyDraft) -> Self {
        Self {
            quotes: draft
                .quotes
                .into_iter()
                .map(|quote| ReplyQuote {
                    before: quote.before,
                    text: quote.text,
                })
                .collect(),
            text: draft.text,
        }
    }
}

/// The message `draft` sends: its quotes as Markdown block quotes, a blank line apart.
#[uniffi::export]
pub fn reply_draft_message(draft: ReplyDraft) -> String {
    core::ReplyDraft::from(draft).message()
}

/// `draft` with `selection` quoted after its text; the reply starts empty.
#[uniffi::export]
pub fn reply_draft_quoting(draft: ReplyDraft, selection: String) -> ReplyDraft {
    core::ReplyDraft::from(draft).quoting(&selection).into()
}

/// `draft` without quote `index`; its leading text joins the text after it.
#[uniffi::export]
pub fn reply_draft_removing(draft: ReplyDraft, index: u32) -> ReplyDraft {
    let index = usize::try_from(index).unwrap_or(usize::MAX);
    core::ReplyDraft::from(draft).removing(index).into()
}

#[uniffi::export]
impl ClientCore {
    /// Sends `text` with `files` to `session_id` from outside its composer (the Browser design
    /// tools' requests): the files upload to the session, then the message posts. The
    /// composer's draft, files and send state are left alone; nothing is retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Attachment`] for a file the server will not take; [`CoreError::Session`]:
    /// the upload and send errors (`HostOffline` and `MessageDenied` were refused; check
    /// `delivery_uncertain`).
    pub async fn send_external_message(
        &self,
        session_id: String,
        text: String,
        files: Vec<ExternalAttachment>,
    ) -> Result<(), CoreError> {
        let policy = self.sessions().attachment_policy();
        let files = files
            .into_iter()
            .map(|file| {
                UploadFile::under(
                    &file.filename,
                    file.media_type.as_deref(),
                    file.data,
                    &policy,
                )
            })
            .collect::<Result<Vec<_>, _>>()
            .map_err(CoreError::from)?;
        let boundary = self.inner.upload_boundary(0)?;
        self.sessions()
            .send_external_message(&session_id, &text, &files, &boundary)
            .await
            .map(|_| ())
            .map_err(CoreError::from)
    }

    /// Takes `session_id`'s uploaded files out of its composer to go with a queued message;
    /// `None` when it has none.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: not connected, or a file is not uploaded yet.
    pub fn hold_attachments(
        &self,
        session_id: String,
    ) -> Result<Option<HeldAttachments>, CoreError> {
        let held = self
            .sessions()
            .hold_attachments(&session_id)
            .map_err(CoreError::from)?;
        Ok(held.map(|(id, items)| HeldAttachments {
            id: id.get(),
            items: items.iter().map(Into::into).collect(),
        }))
    }

    /// Puts a queued message's files back in `session_id`'s composer.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: no such hold, being sent, or no room in the draft.
    pub fn restore_held_attachments(&self, session_id: String, hold: u64) -> Result<(), CoreError> {
        self.sessions()
            .restore_held_attachments(&session_id, HoldId::new(hold))
            .map_err(CoreError::from)
    }

    /// Forgets a removed queued message's files.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: no such hold, or being sent.
    pub fn discard_held_attachments(&self, session_id: String, hold: u64) -> Result<(), CoreError> {
        self.sessions()
            .discard_held_attachments(&session_id, HoldId::new(hold))
            .map_err(CoreError::from)
    }

    /// Sends a queued message: `text` with the files of `hold` and the `@`-tagged `paths` ahead
    /// of it (worded for `harness`). The composer's own files stay in its draft.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]; check `delivery_uncertain`.
    pub async fn send_queued_message(
        &self,
        session_id: String,
        text: String,
        hold: Option<u64>,
        harness: Option<String>,
        paths: Vec<String>,
    ) -> Result<MessageSent, CoreError> {
        let sent = self
            .sessions()
            .send_queued_message(
                &session_id,
                &text,
                hold.map(HoldId::new),
                harness.as_deref(),
                &paths,
            )
            .await;
        // A refused send's working state is gone by the time it answers.
        self.events_published().await;
        let sent = sent.map_err(CoreError::from)?;
        if self.is_demo() {
            self.post(Msg::DemoKick);
        }
        Ok(sent.into())
    }
}
