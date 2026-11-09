//! A session's transcript as JSON Lines, in the web's export format: one `session_meta` record,
//! then every item oldest first, each as the server sent it.

use std::collections::BTreeSet;

use serde_json::{Map, Value};

use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

const EXPORT_PAGE_LIMIT: u32 = 500;

pub(super) fn record(kind: &str, value: Value, path: &str) -> Result<String, SessionError> {
    let Value::Object(fields) = value else {
        return Err(SessionError::MalformedResponse {
            detail: format!("{path}: not an object"),
        });
    };
    let mut line = Map::new();
    line.insert("record_type".to_owned(), Value::from(kind));
    line.extend(fields);
    Ok(Value::Object(line).to_string())
}

impl<T: HttpTransport> ClientCore<T> {
    /// `session_id`'s metadata and full history as JSON Lines (`.jsonl`), as the web exports it.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; the read errors;
    /// [`SessionError::MalformedResponse`] for a page that is not the expected shape, and
    /// [`SessionError::InvalidPagination`] for a page that would repeat itself.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn export_transcript(&self, session_id: &str) -> Result<String, SessionError> {
        let result = self.read_transcript(session_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn read_transcript(&self, session_id: &str) -> Result<String, SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}");
        let meta = self
            .get_json(
                &path,
                &[
                    ("include_items", "false".to_owned()),
                    ("include_liveness", "false".to_owned()),
                ],
            )
            .await?;
        let mut lines = vec![record("session_meta", meta, &path)?];
        let items_path = format!("{path}/items");
        let mut after: Option<String> = None;
        let mut cursors = BTreeSet::new();
        loop {
            let mut query = vec![
                ("limit", EXPORT_PAGE_LIMIT.to_string()),
                ("order", "asc".to_owned()),
            ];
            if let Some(cursor) = &after {
                query.push(("after", cursor.clone()));
            }
            let page = self.get_json(&items_path, &query).await?;
            let malformed = |detail: &str| SessionError::MalformedResponse {
                detail: format!("{items_path}: {detail}"),
            };
            let items = page
                .get("data")
                .and_then(Value::as_array)
                .ok_or_else(|| malformed("`data` is not an array"))?;
            for item in items {
                lines.push(record("item", item.clone(), &items_path)?);
            }
            let has_more = page.get("has_more").and_then(Value::as_bool) == Some(true);
            let last = page
                .get("last_id")
                .and_then(Value::as_str)
                .map(str::to_owned);
            match last {
                Some(last) if has_more => {
                    if !cursors.insert(last.clone()) {
                        return Err(SessionError::InvalidPagination);
                    }
                    after = Some(last);
                }
                _ => break,
            }
        }
        let mut text = lines.join("\n");
        text.push('\n');
        Ok(text)
    }
}
