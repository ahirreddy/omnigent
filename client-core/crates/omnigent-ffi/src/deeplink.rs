//! `omnigent://` deep links.

use omnigent_core::deeplink as core;
use url::Url;

use crate::errors::{CoreError, core_error};

/// Which shell's link grammar applies.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DeepLinkPolicy {
    /// The macOS desktop app: `omnigent://host` opens the server home.
    Desktop,
    /// iOS: only conversation links.
    Ios,
}

/// Where a link goes on its server.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum DeepLinkRoute {
    /// The server's home.
    Home,
    /// One conversation.
    Conversation {
        /// The session id, decoded.
        session_id: String,
    },
}

/// A desktop launcher's acknowledgment request (`desktop_ack`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DeepLinkAcknowledgment {
    /// The launcher's loopback port.
    pub port: u16,
    /// The nonce to echo.
    pub nonce: String,
    /// The callback path to request on the port.
    pub callback_path: String,
}

/// A parsed `omnigent://` link.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DeepLink {
    /// The server origin, `scheme://host[:port]` (http for loopback, https otherwise).
    pub origin: String,
    /// The host.
    pub host: String,
    /// The explicit port, if any.
    pub port: Option<u16>,
    /// A loopback server.
    pub is_loopback: bool,
    /// Where it goes.
    pub route: DeepLinkRoute,
    /// The SPA path (`/` or `/c/<id>`).
    pub path: String,
    /// The acknowledgment the launcher asked for (desktop only).
    pub acknowledgment: Option<DeepLinkAcknowledgment>,
}

impl From<DeepLinkPolicy> for core::DeepLinkPolicy {
    fn from(policy: DeepLinkPolicy) -> Self {
        match policy {
            DeepLinkPolicy::Desktop => Self::Desktop,
            DeepLinkPolicy::Ios => Self::Ios,
        }
    }
}

impl From<core::DeepLinkRoute> for DeepLinkRoute {
    fn from(route: core::DeepLinkRoute) -> Self {
        match route {
            core::DeepLinkRoute::Home => Self::Home,
            core::DeepLinkRoute::Conversation { session_id } => Self::Conversation { session_id },
        }
    }
}

impl From<DeepLinkRoute> for core::DeepLinkRoute {
    fn from(route: DeepLinkRoute) -> Self {
        match route {
            DeepLinkRoute::Home => Self::Home,
            DeepLinkRoute::Conversation { session_id } => Self::Conversation { session_id },
        }
    }
}

/// Parses an `omnigent://` link with `policy`.
///
/// # Errors
///
/// [`CoreError::DeepLink`] with the reason.
#[uniffi::export]
pub fn parse_deep_link(raw: String, policy: DeepLinkPolicy) -> Result<DeepLink, CoreError> {
    let link = core::OmnigentDeepLink::parse_with(&raw, policy.into()).map_err(core_error)?;
    Ok(DeepLink {
        origin: link.origin.serialized(),
        host: link.origin.host().to_owned(),
        port: link.origin.port(),
        is_loopback: link.origin.is_loopback(),
        path: link.route.path(),
        route: link.route.into(),
        acknowledgment: link.acknowledgment.map(|ack| DeepLinkAcknowledgment {
            port: ack.port(),
            nonce: ack.nonce().to_owned(),
            callback_path: ack.callback_path(),
        }),
    })
}

/// The web URL that opens `route` on `server_url`, keeping its mount, `?o=` selector and
/// fragment.
///
/// # Errors
///
/// [`CoreError::InvalidUrl`] when `server_url` is not a hierarchical URL.
#[uniffi::export]
pub fn conversation_url(server_url: String, route: DeepLinkRoute) -> Result<String, CoreError> {
    let url = Url::parse(&server_url).map_err(|error| CoreError::InvalidUrl {
        message: format!("{server_url}: {error}"),
    })?;
    core::conversation_url(&url, &route.into())
        .map(String::from)
        .map_err(|error| CoreError::InvalidUrl {
            message: error.to_string(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_conversation_link() {
        let link = parse_deep_link(
            "omnigent://127.0.0.1:6767/c/abc123".into(),
            DeepLinkPolicy::Desktop,
        )
        .unwrap();
        assert_eq!(link.origin, "http://127.0.0.1:6767");
        assert!(link.is_loopback);
        assert_eq!(
            link.route,
            DeepLinkRoute::Conversation {
                session_id: "abc123".into()
            }
        );
        assert!(matches!(
            parse_deep_link("https://x".into(), DeepLinkPolicy::Ios),
            Err(CoreError::DeepLink { .. })
        ));
    }

    #[test]
    fn builds_conversation_urls_under_the_mount() {
        assert_eq!(
            conversation_url(
                "https://h.example.com/omnigent/?o=1".into(),
                DeepLinkRoute::Conversation {
                    session_id: "s1".into()
                }
            )
            .unwrap(),
            "https://h.example.com/omnigent/c/s1?o=1"
        );
    }
}
