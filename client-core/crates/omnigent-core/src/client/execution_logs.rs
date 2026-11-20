//! Execution logs: a session's items as raw JSON, oldest first, as the web's
//! `ExecutionLogsPanel` lists them (`GET /v1/sessions/{id}/items?order=asc`).

use serde_json::Value;

use super::json::{as_object, opt_array, opt_bool, opt_str};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// Items read per page, as the web.
const PAGE_SIZE: &str = "50";

/// One item as the server stores it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawItem {
    /// Its id, when it has one.
    pub id: Option<String>,
    /// The item on one line.
    pub compact: String,
    /// The item indented two spaces per level.
    pub pretty: String,
}

/// A page of items.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawItemsPage {
    /// The items, oldest first.
    pub items: Vec<RawItem>,
    /// Where the next page starts; `None` on the last page.
    pub next: Option<String>,
}

impl<T: HttpTransport> ClientCore<T> {
    /// A page of `session_id`'s items as raw JSON, oldest first, starting after `after`.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; the read errors;
    /// [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn raw_session_items(
        &self,
        session_id: &str,
        after: Option<&str>,
    ) -> Result<RawItemsPage, SessionError> {
        let result = async {
            validate_identifier(session_id)?;
            let path = format!("/v1/sessions/{session_id}/items");
            let mut query = vec![("limit", PAGE_SIZE.to_owned()), ("order", "asc".to_owned())];
            if let Some(after) = after {
                query.push(("after", after.to_owned()));
            }
            let value = self.get_json(&path, &query).await?;
            raw_items_page(&value).map_err(|detail| SessionError::MalformedResponse {
                detail: format!("{path}: {detail}"),
            })
        }
        .await;
        self.dispatch();
        result
    }
}

fn raw_items_page(value: &Value) -> Result<RawItemsPage, String> {
    let object = as_object(value, "items")?;
    let items = opt_array(object, "data")?
        .ok_or("`data` is missing")?
        .iter()
        .map(|item| RawItem {
            id: item
                .get("id")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .map(str::to_owned),
            compact: item.to_string(),
            pretty: serde_json::to_string_pretty(item).unwrap_or_else(|_| item.to_string()),
        })
        .collect();
    // `has_more` says more exist; `last_id` is where they start.
    let next = if opt_bool(object, "has_more")? == Some(true) {
        opt_str(object, "last_id")?.filter(|id| !id.is_empty())
    } else {
        None
    };
    Ok(RawItemsPage { items, next })
}

#[cfg(test)]
#[path = "execution_logs_tests.rs"]
mod tests;
