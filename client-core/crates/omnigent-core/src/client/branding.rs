//! The server operator's branding (`/v1/info.branding`, `GET /v1/branding/logo/{variant}`).
//!
//! As the web's `parseBranding`: the app name, the new-session heading (an explicit empty one
//! hides it), the logos, and whether "Powered by Omnigent" shows. Wrongly typed fields read as
//! unset, as on the web, so a server's branding never stops its pages from loading.

use serde_json::Value;

use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// The logo route; the server publishes each variant's path under it.
const LOGO_PREFIX: &str = "/v1/branding/logo/";
/// The largest logo the server serves.
pub const MAX_LOGO_BYTES: usize = 5 * 1024 * 1024;

/// The operator's branding, when it sets any.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct Branding {
    /// Replaces "Omnigent" where the app names itself.
    pub app_name: Option<String>,
    /// Replaces the new-session heading; `Some("")` hides it.
    pub heading: Option<String>,
    /// The main logo's path, shown in place of the mascot.
    pub logo_main: Option<String>,
    /// The working indicator's logo path.
    pub logo_loading: Option<String>,
    /// The favicon's path.
    pub logo_favicon: Option<String>,
    /// "Powered by Omnigent" shows.
    pub powered_by: bool,
}

impl Branding {
    /// The branding in a `/v1/info` body, or `None` when it sets nothing (or is missing).
    #[must_use]
    pub fn from_info(info: &Value) -> Option<Self> {
        let branding = info.get("branding")?.as_object()?;
        let text = |value: Option<&Value>| {
            value
                .and_then(Value::as_str)
                .filter(|text| !text.trim().is_empty())
                .map(str::to_owned)
        };
        let logos = branding.get("logos").and_then(Value::as_object);
        let logo = |variant: &str| {
            text(logos.and_then(|logos| logos.get(variant)))
                .filter(|path| path.starts_with(LOGO_PREFIX))
        };
        let parsed = Self {
            app_name: text(branding.get("app_name")),
            heading: branding
                .get("heading")
                .and_then(Value::as_str)
                .map(str::to_owned),
            logo_main: logo("main"),
            logo_loading: logo("loading"),
            logo_favicon: logo("favicon"),
            powered_by: branding.get("powered_by").and_then(Value::as_bool) != Some(false),
        };
        let unset = Self {
            powered_by: true,
            ..Self::default()
        };
        (parsed != unset).then_some(parsed)
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// A branding logo's bytes, by the path `/v1/info.branding.logos` gave.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] for a path outside the logo route,
    /// [`SessionError::MalformedResponse`] for an empty or oversized image, and the read errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn branding_logo(&self, path: &str) -> Result<Vec<u8>, SessionError> {
        let result = async {
            let variant = path
                .strip_prefix(LOGO_PREFIX)
                .filter(|variant| {
                    !variant.is_empty() && variant.bytes().all(|byte| byte.is_ascii_lowercase())
                })
                .ok_or_else(|| SessionError::InvalidIdentifier {
                    value: path.to_owned(),
                })?;
            let response = self
                .read(self.prepare("GET", &format!("{LOGO_PREFIX}{variant}"), &[], None)?)
                .await?;
            if response.body.is_empty() || response.body.len() > MAX_LOGO_BYTES {
                return Err(SessionError::MalformedResponse {
                    detail: format!("{path}: {} bytes is not a logo", response.body.len()),
                });
            }
            Ok(response.body)
        }
        .await;
        self.dispatch();
        result
    }
}

#[cfg(test)]
#[path = "branding_tests.rs"]
mod tests;
