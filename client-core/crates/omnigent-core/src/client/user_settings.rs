//! The caller's own server-side settings (`/v1/settings`): the guidance the server adds to the
//! prompt that names the caller's sessions, as the web's `SessionTitleInstructionsControl`.
//! Servers advertise it with `/v1/info.session_title_instructions`.

use serde_json::{Value, json};

use super::json::{as_object, opt_str, opt_u64};
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

const TITLE_INSTRUCTIONS_PATH: &str = "/v1/settings/session-title-instructions";

/// The server's limit until its first answer reports one.
pub const DEFAULT_TITLE_INSTRUCTIONS_MAX_CHARS: u64 = 4000;

/// The caller's saved title instructions and the limit the server enforces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionTitleInstructions {
    /// Saved guidance; `None` when only the server's or the default title prompt applies.
    pub instructions: Option<String>,
    /// The longest guidance the server accepts, in characters (code points).
    pub max_chars: u64,
}

impl SessionTitleInstructions {
    /// Decodes a `GET` or `PUT` answer.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, TITLE_INSTRUCTIONS_PATH)?;
        Ok(Self {
            instructions: opt_str(object, "instructions")?.filter(|text| !text.is_empty()),
            max_chars: opt_u64(object, "max_chars")?
                .unwrap_or(DEFAULT_TITLE_INSTRUCTIONS_MAX_CHARS),
        })
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// The caller's title instructions (`GET /v1/settings/session-title-instructions`).
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn session_title_instructions(
        &self,
    ) -> Result<SessionTitleInstructions, SessionError> {
        let result = self.get_json(TITLE_INSTRUCTIONS_PATH, &[]).await;
        self.dispatch();
        SessionTitleInstructions::from_value(&result?).map_err(|detail| {
            SessionError::MalformedResponse {
                detail: format!("{TITLE_INSTRUCTIONS_PATH}: {detail}"),
            }
        })
    }

    /// Saves the caller's title instructions, trimmed; blank or `None` clears them
    /// (`PUT /v1/settings/session-title-instructions`).
    ///
    /// # Errors
    ///
    /// `Rejected` (400) for guidance over the server's limit; the write errors;
    /// `DeliveryUncertain` for an unreadable acknowledgement.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn save_session_title_instructions(
        &self,
        instructions: Option<&str>,
    ) -> Result<SessionTitleInstructions, SessionError> {
        let trimmed = instructions.map(str::trim).filter(|text| !text.is_empty());
        let body = json!({ "instructions": trimmed });
        let result = self
            .write_json("PUT", TITLE_INSTRUCTIONS_PATH, &body)
            .await;
        self.dispatch();
        SessionTitleInstructions::from_value(&result?).map_err(|detail| {
            SessionError::DeliveryUncertain {
                detail: format!("unreadable {TITLE_INSTRUCTIONS_PATH} acknowledgement: {detail}"),
            }
        })
    }
}

#[cfg(test)]
#[path = "user_settings_tests.rs"]
mod tests;
