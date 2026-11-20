//! Reads for extension pages: the installed extensions (`GET /v1/extensions`), their bundle
//! assets, and the session list pages the `sessions.listPage` host method answers with.

use serde_json::Value;

use super::requests::{Prepared, error_code};
use super::{ClientCore, SessionError, lock};
use crate::extensions::{
    Extension, ExtensionHostError, SessionPageRequest, SessionRows, asset_path, decode_catalog,
    decode_session_rows,
};
use crate::http::{HttpResponse, HttpTransport, TransportError};

const CATALOG_PATH: &str = "/v1/extensions";
const SESSIONS_PATH: &str = "/v1/sessions";

/// A bundle asset as read.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ExtensionAsset {
    /// The asset's text.
    Loaded(String),
    /// The server no longer has this digest (it restarted with another build): read the catalog
    /// again for the current one.
    Stale,
}

impl<T: HttpTransport> ClientCore<T> {
    /// The enabled extensions. A server without the route has none.
    ///
    /// # Errors
    ///
    /// The read errors and [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn extensions(&self) -> Result<Vec<Extension>, SessionError> {
        let result = match self.get_json(CATALOG_PATH, &[]).await {
            Ok(value) => decode_catalog(&value).map_err(|detail| SessionError::MalformedResponse {
                detail: format!("{CATALOG_PATH}: {detail}"),
            }),
            Err(SessionError::HttpStatus { status: 404 }) => Ok(Vec::new()),
            Err(error) => Err(error),
        };
        self.dispatch();
        result
    }

    /// Reads the asset at `url`, one of extension `extension_id`'s bundle assets.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidInput`] for a URL that is not one of the extension's assets; the
    /// read errors; [`SessionError::MalformedResponse`] for text that is not UTF-8.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn extension_asset(
        &self,
        extension_id: &str,
        url: &str,
    ) -> Result<ExtensionAsset, SessionError> {
        let result = async {
            let path = asset_path(url, extension_id).ok_or_else(|| SessionError::InvalidInput {
                reason: "not one of the extension's assets".to_owned(),
            })?;
            match self.read(self.prepare("GET", path, &[], None)?).await {
                Ok(response) => String::from_utf8(response.body)
                    .map(ExtensionAsset::Loaded)
                    .map_err(|_| SessionError::MalformedResponse {
                        detail: format!("{path}: not UTF-8 text"),
                    }),
                Err(SessionError::HttpStatus { status: 404 }) => Ok(ExtensionAsset::Stale),
                Err(error) => Err(error),
            }
        }
        .await;
        self.dispatch();
        result
    }

    /// A page of the caller's top-level, unarchived sessions, most recently changed first, as
    /// `sessions.listPage` reads it.
    ///
    /// # Errors
    ///
    /// What the extension is told: `PermissionDenied` (401, 403), `Unavailable` (5xx),
    /// `StaleCursor` (the page before is gone), `HostError` otherwise.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn extension_session_rows(
        &self,
        request: &SessionPageRequest,
    ) -> Result<SessionRows, ExtensionHostError> {
        let result = async {
            let mut query = vec![
                ("limit", request.limit.to_string()),
                ("sort_by", "updated_at".to_owned()),
                ("order", "desc".to_owned()),
                ("kind", "default".to_owned()),
                ("visibility", "all".to_owned()),
                ("include_archived", "false".to_owned()),
            ];
            if let Some(after) = &request.after {
                query.push(("after", after.clone()));
            }
            let failed = || ExtensionHostError::host("Session list request failed");
            let prepared = self
                .prepare("GET", SESSIONS_PATH, &query, None)
                .map_err(|_| failed())?;
            let response = self.read_any_status(prepared).await.map_err(|_| failed())?;
            match response.status {
                200 => {}
                401 | 403 => {
                    return Err(ExtensionHostError::new(
                        "PermissionDenied",
                        "Session list access was denied",
                    ));
                }
                status if status >= 500 => {
                    return Err(ExtensionHostError::new(
                        "Unavailable",
                        "Session list is unavailable",
                    ));
                }
                400 if error_code(&response.body).as_deref() == Some("stale_cursor") => {
                    return Err(ExtensionHostError::new(
                        "StaleCursor",
                        "Session list cursor is no longer valid",
                    ));
                }
                status => {
                    return Err(ExtensionHostError::host(format!(
                        "Session list request failed ({status})"
                    )));
                }
            }
            let value: Value = serde_json::from_slice(&response.body)
                .map_err(|_| ExtensionHostError::host("Malformed session list response"))?;
            decode_session_rows(&value, request.limit)
        }
        .await;
        self.dispatch();
        result
    }

    /// Sends `prepared` and returns the server's answer whatever its status, keeping the read
    /// rules otherwise: a result from an older connection is [`SessionError::NotConnected`] and
    /// a `401` ends the connection.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn read_any_status(&self, prepared: Prepared) -> Result<HttpResponse, SessionError> {
        let result = self
            .send_routed(prepared.request, prepared.addressing)
            .await;
        let mut state = lock(&self.state);
        if state.epoch != prepared.epoch || !state.is_connected() {
            return Err(SessionError::NotConnected);
        }
        let response = result.map_err(|error| match error {
            TransportError::Cancelled => SessionError::Cancelled,
            other => SessionError::Transport(other),
        })?;
        if response.status == 401 {
            state.authentication_failed();
        }
        Ok(response)
    }
}

#[cfg(test)]
#[path = "extension_reads_tests.rs"]
mod tests;
