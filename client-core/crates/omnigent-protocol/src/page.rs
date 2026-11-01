//! Cursor pages (`GET /v1/sessions`, `GET /v1/sessions/{id}/items`).

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

use crate::error::{DecodeError, FromWire};

/// One page of a cursor-paginated list: `{object, data, first_id, last_id, has_more}`.
///
/// Rows keep the server's order and are not de-duplicated; the cursor is opaque.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Page<T> {
    /// Rows in server order.
    pub data: Vec<T>,
    /// Id of the first row, when sent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_id: Option<String>,
    /// Id of the last row: the `after` cursor for the next page.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_id: Option<String>,
    /// Whether another page follows.
    pub has_more: bool,
}

/// A page that claims more rows but gives no usable cursor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PageCursorError {
    /// `has_more` is true and `last_id` is missing or empty.
    MissingCursor,
    /// `has_more` is true and `last_id` repeats the cursor this page was requested with.
    RepeatedCursor {
        /// The repeated cursor.
        cursor: String,
    },
}

impl std::fmt::Display for PageCursorError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingCursor => f.write_str("page has more rows but no cursor"),
            Self::RepeatedCursor { cursor } => write!(f, "page repeated cursor {cursor:?}"),
        }
    }
}

impl std::error::Error for PageCursorError {}

impl<T> Page<T> {
    /// The `after` cursor for the next page, or `None` on the last page. A page whose rows are all
    /// hidden still yields its cursor.
    ///
    /// # Errors
    ///
    /// More rows are claimed but the cursor is missing, empty, or equal to `requested_after`
    /// (which would loop forever).
    pub fn next_cursor(
        &self,
        requested_after: Option<&str>,
    ) -> Result<Option<&str>, PageCursorError> {
        if !self.has_more {
            return Ok(None);
        }
        match self.last_id.as_deref() {
            None | Some("") => Err(PageCursorError::MissingCursor),
            Some(cursor) if Some(cursor) == requested_after => {
                Err(PageCursorError::RepeatedCursor {
                    cursor: cursor.to_owned(),
                })
            }
            Some(cursor) => Ok(Some(cursor)),
        }
    }
}

#[derive(Deserialize)]
struct RawPage {
    data: Vec<Value>,
    #[serde(default)]
    first_id: Option<String>,
    #[serde(default)]
    last_id: Option<String>,
    has_more: bool,
}

impl<T: FromWire> FromWire for Page<T> {
    fn from_value(value: Value) -> Result<Self, DecodeError> {
        if !value.is_object() {
            return Err(DecodeError::NotAnObject {
                context: "page".to_owned(),
            });
        }
        let raw: RawPage = crate::error::decode_as(value, || "page".to_owned())?;
        let data = raw
            .data
            .into_iter()
            .enumerate()
            .map(|(index, row)| {
                T::from_value(row).map_err(|error| DecodeError::Invalid {
                    context: format!("page row {index}"),
                    message: error.to_string(),
                })
            })
            .collect::<Result<_, _>>()?;
        Ok(Self {
            data,
            first_id: raw.first_id,
            last_id: raw.last_id,
            has_more: raw.has_more,
        })
    }
}

impl<'de, T: FromWire> Deserialize<'de> for Page<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = Value::deserialize(deserializer)?;
        Self::from_value(value).map_err(serde::de::Error::custom)
    }
}
