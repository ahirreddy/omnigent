//! `/rewind` for Claude sessions: the prompts the picker lists (`GET .../items?type=message`) and
//! the rewind itself (`POST /v1/sessions/{id}/rewind`), as the web's `fetchRewindPrompts` and
//! `rewindSession` do.

use std::collections::BTreeSet;

use base64::Engine as _;
use serde_json::{Value, json};

use super::json::{as_object, opt_array, opt_bool, opt_str, req_str};
use super::requests::{missing_session, page_query, refused_write, validate_identifier};
use super::{ClientCore, SessionError, lock};
use crate::attachments::UploadFile;
use crate::attachments::preview::PREVIEW_EXTENSIONS;
use crate::http::HttpTransport;

/// Message pages one read of the picker's prompts covers.
pub const REWIND_PROMPT_PAGES: usize = 5;
/// Items per page.
pub const REWIND_PROMPT_PAGE_SIZE: u32 = 200;

/// One of a session's prompts, as the `/rewind` picker lists it.
#[derive(Debug, Clone, PartialEq)]
pub struct RewindPrompt {
    /// The prompt's item id.
    pub item_id: String,
    /// Its text parts, joined by newlines; empty for a prompt of attachments only.
    pub text: String,
    /// When the server recorded it, in epoch seconds.
    pub created_at: Option<f64>,
}

/// A batch of prompts, newest first.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RewindPrompts {
    /// The prompts.
    pub prompts: Vec<RewindPrompt>,
    /// Pass back to read older prompts; `None` once none remain.
    pub older_cursor: Option<String>,
}

/// A file the chosen prompt attached, as the rewound session holds it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RewindAttachment {
    /// An `input_image` rather than an `input_file`.
    pub is_image: bool,
    /// The rewound session's copy of the file; `None` for one carried inline.
    pub file_id: Option<String>,
    /// An image carried inline, as a `data:image/...` URI.
    pub image_url: Option<String>,
    /// A document carried inline, as a base64 `data:` URI.
    pub file_data: Option<String>,
    /// The attachment's name.
    pub filename: String,
}

/// What a rewind returned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rewound {
    /// The new session that continues from just before the prompt.
    pub session_id: String,
    /// The prompt's text, for the new session's composer.
    pub prompt: String,
    /// The prompt's attachments, in prompt order.
    pub attachments: Vec<RewindAttachment>,
    /// Some attachments could not be restored; the user attaches them again.
    pub attachments_incomplete: bool,
}

impl Rewound {
    /// Decodes a `POST .../rewind` answer. Servers that return no attachments leave the list
    /// empty.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "rewind")?;
        let attachments = opt_array(object, "attachments")?
            .map(|rows| rows.iter().map(attachment_from).collect())
            .transpose()?
            .unwrap_or_default();
        Ok(Self {
            session_id: req_str(object, "session_id")?,
            prompt: opt_str(object, "prompt")?.unwrap_or_default(),
            attachments,
            attachments_incomplete: opt_bool(object, "attachments_incomplete")?.unwrap_or(false),
        })
    }
}

fn attachment_from(value: &Value) -> Result<RewindAttachment, String> {
    let object = as_object(value, "attachment")?;
    let non_empty = |key: &str| -> Result<Option<String>, String> {
        Ok(opt_str(object, key)?.filter(|text| !text.is_empty()))
    };
    let kind = req_str(object, "type")?;
    if kind != "input_file" && kind != "input_image" {
        return Err(format!("attachment `type` {kind:?} is not a file or image"));
    }
    Ok(RewindAttachment {
        is_image: kind == "input_image",
        file_id: non_empty("file_id")?,
        image_url: non_empty("image_url")?,
        file_data: non_empty("file_data")?,
        filename: req_str(object, "filename")?,
    })
}

/// The prompt one listed item is, or `None` for an assistant message, hidden context
/// (`is_meta`) or another kind of item.
fn prompt_from(item: &Value) -> Result<Option<RewindPrompt>, String> {
    let object = as_object(item, "item")?;
    if opt_str(object, "type")?.as_deref() != Some("message")
        || opt_str(object, "role")?.as_deref() != Some("user")
        || opt_bool(object, "is_meta")? == Some(true)
    {
        return Ok(None);
    }
    let text = opt_array(object, "content")?
        .into_iter()
        .flatten()
        .filter(|part| part.get("type").and_then(Value::as_str) == Some("input_text"))
        .filter_map(|part| part.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    Ok(Some(RewindPrompt {
        item_id: req_str(object, "id")?,
        text,
        created_at: object.get("created_at").and_then(Value::as_f64),
    }))
}

impl<T: HttpTransport> ClientCore<T> {
    /// The session's prompts for the `/rewind` picker, newest first: up to
    /// [`REWIND_PROMPT_PAGES`] pages of its messages, from `after` (an earlier batch's
    /// `older_cursor`) or the newest.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] and [`SessionError::InvalidPagination`] before any
    /// request; [`SessionError::SessionNotFound`] for a `404`; the read errors;
    /// [`SessionError::MalformedResponse`]; [`SessionError::InvalidPagination`] for a cursor that
    /// repeats.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn rewind_prompts(
        &self,
        session_id: &str,
        after: Option<&str>,
    ) -> Result<RewindPrompts, SessionError> {
        let result = self.read_rewind_prompts(session_id, after).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn read_rewind_prompts(
        &self,
        session_id: &str,
        after: Option<&str>,
    ) -> Result<RewindPrompts, SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}/items");
        let malformed = |detail: String| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        };
        let mut prompts = Vec::new();
        let mut cursor = after.map(str::to_owned);
        let mut seen = BTreeSet::new();
        for _ in 0..REWIND_PROMPT_PAGES {
            let mut query = page_query(cursor.as_deref(), REWIND_PROMPT_PAGE_SIZE)?;
            query.push(("type", "message".to_owned()));
            let page = self
                .get_json(&path, &query)
                .await
                .map_err(missing_session(session_id))?;
            let object = as_object(&page, "items page").map_err(malformed)?;
            let items = opt_array(object, "data")
                .map_err(malformed)?
                .ok_or_else(|| malformed("`data` is missing".to_owned()))?;
            for item in items {
                if let Some(prompt) = prompt_from(item).map_err(malformed)? {
                    prompts.push(prompt);
                }
            }
            let has_more = opt_bool(object, "has_more").map_err(malformed)? == Some(true);
            let last_id = opt_str(object, "last_id")
                .map_err(malformed)?
                .filter(|id| !id.is_empty());
            let Some(next) = last_id.filter(|_| has_more) else {
                return Ok(RewindPrompts {
                    prompts,
                    older_cursor: None,
                });
            };
            if !seen.insert(next.clone()) || cursor.as_deref() == Some(next.as_str()) {
                return Err(SessionError::InvalidPagination);
            }
            cursor = Some(next);
        }
        Ok(RewindPrompts {
            prompts,
            older_cursor: cursor,
        })
    }

    /// Continues a Claude session from just before its prompt `item_id`: the server forks the
    /// earlier history onto the same host and runner and links the source to the fork. The
    /// caller opens the fork with the prompt in its composer.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; [`SessionError::ReadOnly`] when
    /// the cached row is read-only or the server answers `403` (rewinding needs the owner);
    /// [`SessionError::SessionNotFound`] for its `404`; the write errors (a `400` for a running
    /// turn or another harness, a `409` while the session is already moving);
    /// [`SessionError::DeliveryUncertain`] when the answer is unreadable, since the fork may
    /// exist.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn rewind_session(
        &self,
        session_id: &str,
        item_id: &str,
    ) -> Result<Rewound, SessionError> {
        let result = self.post_rewind(session_id, item_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn post_rewind(&self, session_id: &str, item_id: &str) -> Result<Rewound, SessionError> {
        self.cached_editable(session_id)?;
        validate_identifier(item_id)?;
        let path = format!("/v1/sessions/{session_id}/rewind");
        let answer = self
            .write_json("POST", &path, &json!({"item_id": item_id}))
            .await
            .map_err(refused_write(session_id))?;
        // The source gains a notice that links to the fork.
        lock(&self.state).request_rehydration(session_id);
        Rewound::from_value(&answer).map_err(|detail| SessionError::DeliveryUncertain {
            detail: format!("{path}: {detail}"),
        })
    }

    /// Puts a rewound prompt back in its new session's composer: the text, then each attachment
    /// it can read back from the new session's copy (or its inline `data:` URI), staged to upload
    /// on send. A composer that already holds a draft keeps it, as on the web.
    ///
    /// # Errors
    ///
    /// [`SessionError::NotConnected`]. A file that cannot be restored is named in
    /// [`RestoredPrompt::unrestored`] instead.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn restore_rewound_prompt(
        &self,
        rewound: &Rewound,
    ) -> Result<RestoredPrompt, SessionError> {
        let session_id = rewound.session_id.as_str();
        let untouched = self.composer_text(session_id)?.trim().is_empty()
            && !self.attachment_draft(session_id)?.has_attachments();
        if !untouched {
            return Ok(RestoredPrompt::default());
        }
        self.update_composer(session_id, &rewound.prompt)?;
        let mut unrestored = Vec::new();
        for attachment in &rewound.attachments {
            let staged = match self.rewound_file(session_id, attachment).await {
                Ok(file) => self
                    .add_attachment(session_id, file)
                    .map(drop)
                    .map_err(|error| error.to_string()),
                Err(reason) => Err(reason),
            };
            if let Err(reason) = staged {
                unrestored.push(UnrestoredAttachment {
                    filename: attachment.filename.clone(),
                    reason,
                });
            }
        }
        Ok(RestoredPrompt {
            text_restored: true,
            unrestored,
        })
    }

    /// One rewound attachment as a file to stage, or why it cannot be.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn rewound_file(
        &self,
        session_id: &str,
        attachment: &RewindAttachment,
    ) -> Result<UploadFile, String> {
        let inline = attachment
            .image_url
            .as_deref()
            .or(attachment.file_data.as_deref());
        let (media_type, data) = match (&attachment.file_id, inline) {
            (Some(file_id), _) => {
                let preview = self
                    .attachment_preview(session_id, file_id)
                    .await
                    .map_err(|error| error.to_string())?;
                let media_type = PREVIEW_EXTENSIONS
                    .iter()
                    .find(|(_, extension)| *extension == preview.file_extension)
                    .map(|(media_type, _)| (*media_type).to_owned());
                (media_type, preview.data)
            }
            (None, Some(uri)) => {
                let (media_type, data) =
                    decode_data_uri(uri).ok_or("its inline data is not a base64 data URI")?;
                (Some(media_type), data)
            }
            (None, None) => return Err("the server returned neither a file nor its data".into()),
        };
        UploadFile::under(
            &attachment.filename,
            media_type.as_deref(),
            data,
            &self.attachment_policy(),
        )
        .map_err(|error| error.to_string())
    }
}

/// What [`ClientCore::restore_rewound_prompt`] put back.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RestoredPrompt {
    /// The prompt's text went into the composer; `false` when a draft was already there.
    pub text_restored: bool,
    /// Attachments that could not be restored; the user attaches them again.
    pub unrestored: Vec<UnrestoredAttachment>,
}

/// An attachment of a rewound prompt that is not in the new composer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnrestoredAttachment {
    /// Its name.
    pub filename: String,
    /// Why it could not be restored.
    pub reason: String,
}

/// The media type and bytes of a `data:<type>[;…];base64,<data>` URI.
fn decode_data_uri(uri: &str) -> Option<(String, Vec<u8>)> {
    let rest = uri.strip_prefix("data:")?;
    let (header, payload) = rest.split_once(',')?;
    let mut parts = header.split(';');
    let media_type = parts.next().filter(|value| value.contains('/'))?.to_owned();
    if !parts.any(|part| part.eq_ignore_ascii_case("base64")) {
        return None;
    }
    let data = base64::engine::general_purpose::STANDARD
        .decode(payload.trim())
        .ok()?;
    Some((media_type, data))
}

#[cfg(test)]
#[path = "rewind_tests.rs"]
mod tests;
