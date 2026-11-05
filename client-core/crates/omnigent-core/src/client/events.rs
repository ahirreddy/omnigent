//! Writes to a session: messages, interrupts and decision answers (`POST /v1/sessions/{id}/events`
//! and the elicitation resolve route), plus attachment uploads and changed-file reads.
//!
//! Every message send is gated, in order:
//!
//! 1. the [`SubmissionLedger`](crate::ledger::SubmissionLedger) admits it (no send in flight, no
//!    unreviewed uncertain send) and the session's staged attachments are captured;
//! 2. the attachments are checked against the session, server and account
//!    ([`UploadTarget::validate_message_attachments`]);
//! 3. a fresh editable-session preflight: not read-only, not archived, able to execute, and the
//!    session's live stream is open and hydrated;
//! 4. the `POST`. Its outcome completes the ledger operation and the attachment batch.
//!
//! The events route has no idempotency key: an unclear outcome is
//! [`SessionError::DeliveryUncertain`] and blocks the session's next send until the user reviews
//! it ([`ClientCore::acknowledge_uncertain_send`]). Nothing is ever re-posted automatically.
//! Messages ask the server to refuse rather than record a turn while the session's host is
//! offline: that refusal is [`SessionError::HostOffline`], and the caller keeps the message.

use serde_json::{Value, json};
use url::Url;

use super::json::{as_object, opt_bool, opt_str};
use super::requests::{HOST_OFFLINE_HOLD_HEADER, validate_identifier};
use super::{ChangedFilesFetch, ClientCore, ClientEvent, SessionError, lock};
use crate::attachments::{
    AttachmentDraft, AttachmentSubmission, DraftError, DraftItem, DraftItemId, DraftKey, HoldId,
    UploadError, UploadFile, UploadTarget, UploadUncertainty, UploadedAttachment,
};
use crate::auth::endpoint::DATABRICKS_ORG_HEADER;
use crate::auth::hosted::HostedConnection;
use crate::decisions::{Decision, DecisionError, DecisionResponse, ResolveRoute};
use crate::http::{HttpHeader, HttpTransport, TransportError};
use crate::ledger::{SubmissionOperation, SubmissionOutcome};

/// An Inbox reply refused because the session's host is offline (the web's wording).
const HOST_OFFLINE_REPLY: &str = "The host for this session is offline, so the reply wasn\u{2019}t sent. Try again once it reconnects.";

/// The server's acknowledgement of a message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageSubmission {
    /// The message was persisted or queued.
    pub queued: bool,
    /// The persisted item; it arrives again in `session.input.consumed.data.item_id`.
    pub item_id: Option<String>,
    /// A native-terminal pending input; cleared by `session.input.consumed.data.cleared_pending_id`.
    pub pending_id: Option<String>,
}

/// A sent message and the composer state after it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageSent {
    /// The acknowledgement.
    pub submission: MessageSubmission,
    /// The composer text to show now: cleared when the sent draft was not edited meanwhile.
    pub draft: String,
}

/// The changed-files section of a session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChangedFilesUpdate {
    /// The environment's changes.
    Loaded(Vec<ChangedFile>),
    /// The read failed; shown in place of the list.
    Unavailable(String),
}

/// One changed file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangedFile {
    /// Workspace-relative path.
    pub path: String,
    /// `modified`, `added`, `deleted`, ...
    pub status: String,
}

enum Acknowledgement {
    Accepted(MessageSubmission),
    Denied(Option<String>),
}

fn acknowledgement(value: &Value) -> Result<Acknowledgement, String> {
    let object = as_object(value, "acknowledgement")?;
    let queued = opt_bool(object, "queued")?.ok_or("`queued` is missing")?;
    if opt_bool(object, "denied")? == Some(true) {
        return Ok(Acknowledgement::Denied(opt_str(object, "reason")?));
    }
    Ok(Acknowledgement::Accepted(MessageSubmission {
        queued,
        item_id: opt_str(object, "item_id")?,
        pending_id: opt_str(object, "pending_id")?,
    }))
}

/// The `message` event body: attachment blocks first, then the text unless it is blank.
fn message_body(text: &str, attachments: &[UploadedAttachment]) -> Value {
    let mut content: Vec<Value> = attachments
        .iter()
        .map(|attachment| {
            let kind = if attachment.is_image {
                "input_image"
            } else {
                "input_file"
            };
            json!({"type": kind, "file_id": attachment.id, "filename": attachment.filename})
        })
        .collect();
    if !text.trim().is_empty() {
        content.push(json!({"type": "input_text", "text": text}));
    }
    json!({"type": "message", "data": {"role": "user", "content": content}})
}

fn changed_files(value: &Value) -> Result<Vec<ChangedFile>, String> {
    let entries = match value {
        Value::Array(entries) => entries,
        // The server answers `{object: "list", data: [...]}`; NativeLab fixtures use `entries`.
        Value::Object(object) => match object.get("data").or_else(|| object.get("entries")) {
            Some(Value::Array(entries)) => entries,
            _ => return Err("`data` is not an array".to_owned()),
        },
        _ => return Err("changes is not an object".to_owned()),
    };
    entries
        .iter()
        .map(|entry| {
            let object = as_object(entry, "change")?;
            Ok(ChangedFile {
                path: super::json::req_str(object, "path")?,
                status: opt_str(object, "status")?.unwrap_or_default(),
            })
        })
        .collect()
}

/// What a send posts for the composer text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SendPayload {
    /// A user `message` with the text and the staged attachments.
    Message,
    /// A user `message` whose `preamble` (one marker line per `@`-tagged workspace path, see
    /// [`crate::mentions::mention_preamble`]) goes ahead of the text.
    Mentioning {
        /// The marker lines.
        preamble: String,
    },
    /// A skill run on the server (`slash_command`); the text is its typed invocation.
    Skill {
        /// The skill name.
        name: String,
        /// Everything after the name.
        arguments: String,
    },
    /// The harness's compact control (`compact`); the text is the typed `/compact`.
    Compact,
}

impl SendPayload {
    /// A user message (with or without tagged paths), rather than a command.
    const fn is_message(&self) -> bool {
        matches!(self, Self::Message | Self::Mentioning { .. })
    }

    /// Whether it carries content of its own beyond the text.
    fn has_preamble(&self) -> bool {
        matches!(self, Self::Mentioning { preamble } if !preamble.trim().is_empty())
    }

    fn body(&self, text: &str, attachments: &[UploadedAttachment]) -> Value {
        match self {
            Self::Message => message_body(text, attachments),
            Self::Mentioning { preamble } => {
                message_body(&format!("{preamble}{text}"), attachments)
            }
            Self::Skill { name, arguments } => json!({
                "type": "slash_command",
                "data": {"kind": "skill", "name": name, "arguments": arguments},
            }),
            Self::Compact => json!({"type": "compact", "data": {}}),
        }
    }
}

/// The files a message carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AttachmentSource {
    /// None.
    Nothing,
    /// The composer's staged files.
    Staged,
    /// The files held for a queued message.
    Held(HoldId),
}

/// What a send captured before its request went out.
struct SendGate {
    operation: SubmissionOperation,
    batch: Option<AttachmentSubmission>,
    key: DraftKey,
}

impl<T: HttpTransport> ClientCore<T> {
    fn draft_key(&self, session_id: &str) -> Result<DraftKey, SessionError> {
        let scope = lock(&self.state).scope()?;
        Ok(DraftKey::new(scope, session_id))
    }

    fn upload_target(&self, session_id: &str) -> Result<(UploadTarget, bool), SessionError> {
        let state = lock(&self.state);
        let server = state.connected.as_ref().ok_or(SessionError::NotConnected)?;
        // The confirmed connection decides, not the host: an accounts server on 127.0.0.1 has
        // real users, and its uploads carry the signed-in account like any other server's.
        let local = state
            .connection
            .as_ref()
            .is_some_and(HostedConnection::is_single_user);
        let server_url =
            Url::parse(&server.base_url).map_err(|error| SessionError::MalformedResponse {
                detail: format!("connected base URL: {error}"),
            })?;
        Ok((
            UploadTarget {
                server_url,
                session_id: session_id.to_owned(),
                user_id: (!local).then(|| server.user_id.clone()),
            },
            local,
        ))
    }

    /// The composer text the core tracks for `session_id` (empty when none was set).
    ///
    /// # Errors
    ///
    /// [`SessionError::NotConnected`].
    pub fn composer_text(&self, session_id: &str) -> Result<String, SessionError> {
        let key = self.draft_key(session_id)?;
        Ok(lock(&self.state)
            .composer
            .get(&(key.scope, key.session_id))
            .cloned()
            .unwrap_or_default())
    }

    /// Records the composer text for `session_id`, so a send that completes after the user kept
    /// typing does not clear the newer text.
    ///
    /// # Errors
    ///
    /// [`SessionError::NotConnected`].
    pub fn update_composer(&self, session_id: &str, text: &str) -> Result<(), SessionError> {
        let key = self.draft_key(session_id)?;
        lock(&self.state)
            .composer
            .insert((key.scope, key.session_id), text.to_owned());
        Ok(())
    }

    /// Stages `file` in `session_id`'s attachment draft.
    ///
    /// # Errors
    ///
    /// [`SessionError::NotConnected`] and [`SessionError::Draft`].
    pub fn add_attachment(
        &self,
        session_id: &str,
        file: UploadFile,
    ) -> Result<DraftItemId, SessionError> {
        let key = self.draft_key(session_id)?;
        Ok(lock(&self.state).drafts.add(file, &key)?)
    }

    /// Removes a staged file.
    ///
    /// # Errors
    ///
    /// [`SessionError::NotConnected`] and [`SessionError::Draft`].
    pub fn remove_attachment(
        &self,
        session_id: &str,
        item: DraftItemId,
    ) -> Result<(), SessionError> {
        let key = self.draft_key(session_id)?;
        Ok(lock(&self.state).drafts.remove(&key, item)?)
    }

    /// `session_id`'s attachment draft.
    ///
    /// # Errors
    ///
    /// [`SessionError::NotConnected`].
    pub fn attachment_draft(&self, session_id: &str) -> Result<AttachmentDraft, SessionError> {
        let key = self.draft_key(session_id)?;
        Ok(lock(&self.state).drafts.draft(&key).clone())
    }

    /// Moves `session_id`'s uploaded files out of its composer to go with a queued message;
    /// `None` when there are none. Returns the hold and its files.
    ///
    /// # Errors
    ///
    /// [`SessionError::NotConnected`]; [`SessionError::Draft`] while a file is not uploaded.
    pub fn hold_attachments(
        &self,
        session_id: &str,
    ) -> Result<Option<(HoldId, Vec<DraftItem>)>, SessionError> {
        let key = self.draft_key(session_id)?;
        let mut state = lock(&self.state);
        let Some(hold) = state.drafts.hold(&key)? else {
            return Ok(None);
        };
        Ok(Some((hold, state.drafts.held(&key, hold)?.to_vec())))
    }

    /// Puts a queued message's files back in `session_id`'s composer.
    ///
    /// # Errors
    ///
    /// [`SessionError::NotConnected`] and [`SessionError::Draft`] (no such hold, being sent, or
    /// no room in the draft).
    pub fn restore_held_attachments(
        &self,
        session_id: &str,
        hold: HoldId,
    ) -> Result<(), SessionError> {
        let key = self.draft_key(session_id)?;
        Ok(lock(&self.state).drafts.restore(&key, hold)?)
    }

    /// Forgets a removed queued message's files.
    ///
    /// # Errors
    ///
    /// [`SessionError::NotConnected`] and [`SessionError::Draft`] (no such hold, or being sent).
    pub fn discard_held_attachments(
        &self,
        session_id: &str,
        hold: HoldId,
    ) -> Result<(), SessionError> {
        let key = self.draft_key(session_id)?;
        Ok(lock(&self.state).drafts.discard(&key, hold)?)
    }

    /// Uploads one staged file to `session_id` with the multipart `boundary` (random in
    /// production). Runs the editable-session preflight first; the file is never uploaded twice.
    ///
    /// # Errors
    ///
    /// [`SessionError::Draft`] when the item cannot be uploaded now, the preflight errors, and
    /// [`SessionError::Upload`] (a `401` also ends the connection).
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn upload_attachment(
        &self,
        session_id: &str,
        item: DraftItemId,
        boundary: &str,
    ) -> Result<UploadedAttachment, SessionError> {
        let result = self.upload(session_id, item, boundary, true).await;
        self.dispatch();
        result
    }

    /// Uploads one staged file to a session this client just created, before its live stream
    /// opens (for the first message). Otherwise as [`Self::upload_attachment`].
    ///
    /// # Errors
    ///
    /// As [`Self::upload_attachment`] without `StreamNotReady`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn upload_first_attachment(
        &self,
        session_id: &str,
        item: DraftItemId,
        boundary: &str,
    ) -> Result<UploadedAttachment, SessionError> {
        let result = self.upload(session_id, item, boundary, false).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn upload(
        &self,
        session_id: &str,
        item: DraftItemId,
        boundary: &str,
        require_live_stream: bool,
    ) -> Result<UploadedAttachment, SessionError> {
        validate_identifier(session_id)?;
        let key = self.draft_key(session_id)?;
        self.require_sendable(session_id, require_live_stream)
            .await?;
        let (target, _) = self.upload_target(session_id)?;
        let (attempt, file, mut request, epoch) = {
            let mut state = lock(&self.state);
            let file = state
                .drafts
                .draft(&key)
                .items()
                .iter()
                .find(|candidate| candidate.id() == item)
                .map(|candidate| candidate.file().clone())
                .ok_or(DraftError::UnknownItem)?;
            let attempt = state.drafts.begin_upload(&key, item)?;
            let request = match target.request(&file, boundary) {
                Ok(request) => request,
                Err(error) => {
                    state.drafts.finish_upload(&attempt, Err(error.clone()))?;
                    return Err(error.into());
                }
            };
            (attempt, file, request, state.epoch)
        };
        {
            let state = lock(&self.state);
            if let Some(connection) = state.connection.as_ref() {
                if let Some(org) = connection.endpoint().databricks_org_id() {
                    request
                        .headers
                        .push(HttpHeader::new(DATABRICKS_ORG_HEADER, org));
                }
                if let Some(authorization) = connection.authorization() {
                    request
                        .headers
                        .push(HttpHeader::new("Authorization", authorization.expose()));
                }
            }
        }
        let result = self.transport.send(request).await;
        let mut state = lock(&self.state);
        let mapped = if state.epoch == epoch {
            target.response(&file, result)
        } else {
            Err(UploadError::Uncertain(UploadUncertainty::Transport(
                TransportError::Other {
                    message: "the connection ended while the upload was in flight".into(),
                },
            )))
        };
        state.drafts.finish_upload(&attempt, mapped.clone())?;
        if mapped == Err(UploadError::Unauthorized) {
            state.authentication_failed();
        }
        Ok(mapped?)
    }

    /// The preflight every message and upload runs: editable, not archived, able to execute,
    /// and the session's live stream is open and hydrated.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn require_sendable(
        &self,
        session_id: &str,
        require_live_stream: bool,
    ) -> Result<(), SessionError> {
        let summary = self.editable(session_id).await?;
        if summary.is_archived {
            return Err(SessionError::Archived);
        }
        if let Some(reason) = summary
            .configuration
            .as_ref()
            .and_then(crate::config::session::SessionConfiguration::execution_unavailable_reason)
        {
            return Err(SessionError::ExecutionUnavailable {
                reason: reason.to_owned(),
            });
        }
        if require_live_stream && !lock(&self.state).live_sessions.contains(session_id) {
            return Err(SessionError::StreamNotReady);
        }
        Ok(())
    }

    /// Sends `text` and every uploaded attachment staged for `session_id`, through the full
    /// send gate (see the [module docs](self)).
    ///
    /// # Errors
    ///
    /// [`SessionError::EmptyMessage`] when there is neither text nor an attachment;
    /// [`SessionError::Ledger`] and [`SessionError::Draft`] when a send is in flight, unreviewed
    /// or attachments are not uploaded; [`SessionError::Upload`] for attachments of another
    /// session; the preflight errors; [`SessionError::MessageDenied`] for a policy denial; and
    /// the write errors, of which only [`SessionError::DeliveryUncertain`] may have delivered.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn send_message(
        &self,
        session_id: &str,
        text: &str,
    ) -> Result<MessageSent, SessionError> {
        let result = self.send(session_id, text, true).await;
        self.dispatch();
        result
    }

    /// Sends `text` with the `@`-tagged workspace `paths` as marker lines ahead of it, through
    /// the same gate as [`Self::send_message`]. The composer keeps only `text`.
    ///
    /// # Errors
    ///
    /// As [`Self::send_message`]; text-less paths are a message of their own.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn send_message_mentioning(
        &self,
        session_id: &str,
        text: &str,
        harness: Option<&str>,
        paths: &[String],
    ) -> Result<MessageSent, SessionError> {
        let payload = SendPayload::Mentioning {
            preamble: crate::mentions::mention_preamble(harness, paths),
        };
        let result = self
            .send_payload(session_id, text, &payload, true, AttachmentSource::Staged)
            .await;
        self.dispatch();
        result
    }

    /// Sends a queued message: `text` with the files of `hold` (none when `None`) and the
    /// `@`-tagged `paths` ahead of it, through the same gate as [`Self::send_message`]. The
    /// composer's own staged files stay in its draft.
    ///
    /// # Errors
    ///
    /// As [`Self::send_message`]; [`SessionError::Draft`] for a hold this session does not have.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn send_queued_message(
        &self,
        session_id: &str,
        text: &str,
        hold: Option<HoldId>,
        harness: Option<&str>,
        paths: &[String],
    ) -> Result<MessageSent, SessionError> {
        let payload = if paths.is_empty() {
            SendPayload::Message
        } else {
            SendPayload::Mentioning {
                preamble: crate::mentions::mention_preamble(harness, paths),
            }
        };
        let attachments = hold.map_or(AttachmentSource::Nothing, AttachmentSource::Held);
        let result = self
            .send_payload(session_id, text, &payload, true, attachments)
            .await;
        self.dispatch();
        result
    }

    /// Sends the composer `text` as `payload` through the same gate as
    /// [`Self::send_message`]. A skill or compact control never carries attachments.
    ///
    /// # Errors
    ///
    /// As [`Self::send_message`], plus [`SessionError::Draft`] when attachments are staged for
    /// a skill or compact control.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn send_command(
        &self,
        session_id: &str,
        text: &str,
        payload: SendPayload,
    ) -> Result<MessageSent, SessionError> {
        let result = self
            .send_payload(session_id, text, &payload, true, AttachmentSource::Staged)
            .await;
        self.dispatch();
        result
    }

    /// Sends `text` alone to a session that is not open here (the Inbox's reply): the same
    /// ledger and editable-session preflight as [`Self::send_message`], without the live-stream
    /// requirement and without the composer's staged attachments.
    ///
    /// # Errors
    ///
    /// As [`Self::send_message`], less [`SessionError::StreamNotReady`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn send_reply(
        &self,
        session_id: &str,
        text: &str,
    ) -> Result<MessageSent, SessionError> {
        let result = self
            .send_payload(
                session_id,
                text,
                &SendPayload::Message,
                false,
                AttachmentSource::Nothing,
            )
            .await
            .map_err(|error| match error {
                // The Inbox keeps the reply in its field rather than holding it for the host.
                SessionError::HostOffline { .. } => SessionError::HostOffline {
                    message: HOST_OFFLINE_REPLY.to_owned(),
                },
                other => other,
            });
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(crate) async fn send(
        &self,
        session_id: &str,
        text: &str,
        require_live_stream: bool,
    ) -> Result<MessageSent, SessionError> {
        self.send_payload(
            session_id,
            text,
            &SendPayload::Message,
            require_live_stream,
            AttachmentSource::Staged,
        )
        .await
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn send_payload(
        &self,
        session_id: &str,
        text: &str,
        payload: &SendPayload,
        require_live_stream: bool,
        attachments: AttachmentSource,
    ) -> Result<MessageSent, SessionError> {
        validate_identifier(session_id)?;
        let key = self.draft_key(session_id)?;
        let gate = {
            let mut state = lock(&self.state);
            let has_attachments = match attachments {
                AttachmentSource::Nothing => false,
                AttachmentSource::Staged => state.drafts.draft(&key).has_attachments(),
                AttachmentSource::Held(hold) => !state.drafts.held(&key, hold)?.is_empty(),
            };
            if text.trim().is_empty() && !has_attachments && !payload.has_preamble() {
                return Err(SessionError::EmptyMessage);
            }
            if has_attachments && !payload.is_message() {
                return Err(DraftError::NotReady.into());
            }
            if attachments == AttachmentSource::Staged
                && has_attachments
                && !state.drafts.can_submit(&key)
            {
                return Err(DraftError::NotReady.into());
            }
            let operation = state.ledger.begin(&key.scope, session_id, text)?;
            let captured = match attachments {
                _ if !has_attachments => Ok(None),
                AttachmentSource::Held(hold) => {
                    state.drafts.begin_held_submission(&key, hold).map(Some)
                }
                _ => state.drafts.begin_submission(&key).map(Some),
            };
            let batch = match captured {
                Ok(batch) => batch,
                Err(error) => {
                    state
                        .ledger
                        .complete(&operation, SubmissionOutcome::Rejected, text)?;
                    return Err(error.into());
                }
            };
            SendGate {
                operation,
                batch,
                key,
            }
        };
        let result = self
            .deliver(session_id, text, payload, &gate, require_live_stream)
            .await;
        let outcome = match &result {
            Ok(_) => SubmissionOutcome::Accepted,
            Err(error) => error.submission_outcome(),
        };
        let mut state = lock(&self.state);
        let current = state
            .composer
            .get(&(gate.key.scope.clone(), gate.key.session_id.clone()))
            .cloned()
            .unwrap_or_else(|| text.to_owned());
        let resolution = state.ledger.complete(&gate.operation, outcome, &current)?;
        if let Some(batch) = &gate.batch {
            state.drafts.finish_submission(batch, outcome)?;
        }
        if outcome != SubmissionOutcome::Rejected {
            state.request_rehydration(session_id);
        }
        let submission = result?;
        state.composer.insert(
            (gate.key.scope.clone(), gate.key.session_id.clone()),
            resolution.draft.clone(),
        );
        Ok(MessageSent {
            submission,
            draft: resolution.draft,
        })
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn deliver(
        &self,
        session_id: &str,
        text: &str,
        payload: &SendPayload,
        gate: &SendGate,
        require_live_stream: bool,
    ) -> Result<MessageSubmission, SessionError> {
        let attachments = gate
            .batch
            .as_ref()
            .map(|batch| batch.attachments().to_vec())
            .unwrap_or_default();
        let (target, local) = self.upload_target(session_id)?;
        target.validate_message_attachments(&attachments, local)?;
        self.require_sendable(session_id, require_live_stream)
            .await?;
        let path = format!("/v1/sessions/{session_id}/events");
        let mut prepared =
            self.prepare("POST", &path, &[], Some(&payload.body(text, &attachments)))?;
        if payload.is_message() {
            // The caller keeps a message refused for an offline host, so none is recorded.
            prepared
                .request
                .headers
                .push(HttpHeader::new(HOST_OFFLINE_HOLD_HEADER, "on"));
        }
        let response = self.write(prepared).await?;
        let value: Value = serde_json::from_slice(&response.body).map_err(|error| {
            SessionError::DeliveryUncertain {
                detail: format!("unreadable acknowledgement from {path}: {error}"),
            }
        })?;
        match acknowledgement(&value).map_err(|detail| SessionError::DeliveryUncertain {
            detail: format!("unreadable {path} acknowledgement: {detail}"),
        })? {
            Acknowledgement::Accepted(submission) => Ok(submission),
            Acknowledgement::Denied(reason) => Err(SessionError::MessageDenied { reason }),
        }
    }

    /// Records that the user reviewed the uncertain send to `session_id`, unblocking the next
    /// one. Returns whether it was uncertain.
    ///
    /// # Errors
    ///
    /// [`SessionError::NotConnected`].
    pub fn acknowledge_uncertain_send(&self, session_id: &str) -> Result<bool, SessionError> {
        let key = self.draft_key(session_id)?;
        let mut state = lock(&self.state);
        let attachments = state.drafts.acknowledge_uncertainty(&key);
        let message = state.ledger.acknowledge_uncertainty(&key.scope, session_id);
        Ok(attachments || message)
    }

    /// Whether a send to `session_id` is in flight or unreviewed.
    ///
    /// # Errors
    ///
    /// [`SessionError::NotConnected`].
    pub fn is_send_blocked(&self, session_id: &str) -> Result<bool, SessionError> {
        let key = self.draft_key(session_id)?;
        Ok(lock(&self.state).ledger.is_blocked(&key.scope, session_id))
    }

    /// Cancels the session's active turn (`type: "interrupt"`, never the owner-only
    /// `stop_session`).
    ///
    /// # Errors
    ///
    /// The preflight errors ([`SessionError::ReadOnly`] included) and the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn interrupt(&self, session_id: &str) -> Result<(), SessionError> {
        let result = self.interrupt_session(session_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn interrupt_session(&self, session_id: &str) -> Result<(), SessionError> {
        self.editable(session_id).await?;
        let path = format!("/v1/sessions/{session_id}/events");
        self.write(self.prepare(
            "POST",
            &path,
            &[],
            Some(&json!({"type": "interrupt", "data": {}})),
        )?)
        .await?;
        lock(&self.state).request_rehydration(session_id);
        Ok(())
    }

    /// Answers the pending decision `decision_id` shown in `session_id`, after re-reading the
    /// session so a stale card is never answered. A card mirrored from a child session posts to
    /// the child, which must be editable too.
    ///
    /// # Errors
    ///
    /// [`SessionError::Decision`] when the card is gone or the answer is not one it offered (no
    /// request is made), the preflight errors and the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn resolve_decision(
        &self,
        session_id: &str,
        decision_id: &str,
        response: &DecisionResponse,
    ) -> Result<(), SessionError> {
        let result = self.resolve(session_id, decision_id, response).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn resolve(
        &self,
        session_id: &str,
        decision_id: &str,
        response: &DecisionResponse,
    ) -> Result<(), SessionError> {
        validate_identifier(decision_id)?;
        self.editable(session_id).await?;
        let (decoded, _) = self.fetch_snapshot(session_id).await?;
        let decision = decoded
            .snapshot
            .pending_elicitations
            .iter()
            .find(|request| request.elicitation_id == decision_id)
            .map(|request| Decision::from_request(request, session_id))
            .ok_or_else(|| DecisionError::NotFound {
                decision_id: decision_id.to_owned(),
            })?;
        let request = decision.resolve_request(response)?;
        if request.session_id != session_id {
            self.editable(&request.session_id).await?;
        }
        let body = request.body(ResolveRoute::Dedicated).map_err(|error| {
            SessionError::MalformedResponse {
                detail: error.to_string(),
            }
        })?;
        let path = format!(
            "/v1/sessions/{}/elicitations/{}/resolve",
            request.session_id, request.elicitation_id
        );
        self.write(self.prepare("POST", &path, &[], Some(&body))?)
            .await?;
        let mut state = lock(&self.state);
        state.request_rehydration(session_id);
        if request.session_id != session_id {
            state.request_rehydration(&request.session_id);
        }
        Ok(())
    }

    /// The decisions `session_id` is waiting on now, read fresh from the server (mirrored child
    /// cards included), whether or not the session is open. Hosts use it to check that a request
    /// shown outside the app, such as in a notification, is still current before acting on it.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request, and the read errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn pending_decisions(&self, session_id: &str) -> Result<Vec<Decision>, SessionError> {
        let result = self.fetch_snapshot(session_id).await.map(|(decoded, _)| {
            decoded
                .snapshot
                .pending_elicitations
                .iter()
                .map(|request| Decision::from_request(request, session_id))
                .collect()
        });
        self.dispatch();
        result
    }

    /// Handles `session.changed_files.invalidated` for `session_id`: one session-scoped read of
    /// the environment's changes, published as [`ClientEvent::ChangedFiles`]. Nothing is read
    /// for a session that is not live. An invalidation that arrives while a read is in flight
    /// makes that read repeat once it finishes, instead of starting a second one.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn invalidate_changed_files(&self, session_id: &str, environment_id: &str) {
        self.load_changed_files(session_id, environment_id).await;
        self.dispatch();
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn load_changed_files(&self, session_id: &str, environment_id: &str) {
        let key = (session_id.to_owned(), environment_id.to_owned());
        let connection_epoch = {
            let mut state = lock(&self.state);
            if !state.live_sessions.contains(session_id) {
                return;
            }
            let fetch = state.changed_files.entry(key.clone()).or_default();
            fetch.epoch = fetch.epoch.wrapping_add(1);
            if fetch.in_flight {
                return;
            }
            fetch.in_flight = true;
            state.epoch
        };
        loop {
            let started = lock(&self.state)
                .changed_files
                .get(&key)
                .map_or(0, |fetch| fetch.epoch);
            let update = match self.fetch_changed_files(session_id, environment_id).await {
                Ok(files) => ChangedFilesUpdate::Loaded(files),
                Err(error) => {
                    ChangedFilesUpdate::Unavailable(format!("Changed files unavailable: {error}"))
                }
            };
            let mut state = lock(&self.state);
            if state.epoch != connection_epoch || !state.live_sessions.contains(session_id) {
                state.changed_files.remove(&key);
                return;
            }
            let fetch = state.changed_files.entry(key.clone()).or_default();
            if fetch.epoch != started {
                continue;
            }
            *fetch = ChangedFilesFetch {
                epoch: fetch.epoch,
                in_flight: false,
            };
            state.events.push(ClientEvent::ChangedFiles {
                session_id: session_id.to_owned(),
                environment_id: environment_id.to_owned(),
                update,
            });
            return;
        }
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn fetch_changed_files(
        &self,
        session_id: &str,
        environment_id: &str,
    ) -> Result<Vec<ChangedFile>, SessionError> {
        validate_identifier(session_id)?;
        validate_identifier(environment_id)?;
        let path =
            format!("/v1/sessions/{session_id}/resources/environments/{environment_id}/changes");
        let value = self.get_json(&path, &[]).await?;
        changed_files(&value).map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        })
    }
}

#[cfg(test)]
mod changed_files_tests {
    use super::{ChangedFile, changed_files};
    use serde_json::Value;

    #[test]
    fn server_list_envelope_decodes() {
        let recorded: Value = serde_json::from_str(include_str!(
            "../../../../fixtures/workspace/recorded-changes.json"
        ))
        .unwrap();
        let files = changed_files(&recorded["response"]).unwrap();
        assert_eq!(
            files.first(),
            Some(&ChangedFile {
                path: "src/new_file.rs".into(),
                status: "created".into(),
            })
        );
    }

    #[test]
    fn missing_list_is_an_error() {
        let error = changed_files(&serde_json::json!({"object": "list"})).unwrap_err();
        assert!(error.contains("`data`"), "{error}");
    }
}
