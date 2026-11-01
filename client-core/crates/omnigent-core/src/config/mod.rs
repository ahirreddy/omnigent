//! Client configuration logic.
//!
//! - [`managed`]: organization-provided (MDM) server lists and feature flags.
//! - [`settings`]: the user's saved server, recent servers and protocol grants.

pub mod managed;
pub mod session;
pub mod settings;

use url::Url;

/// `scheme://host[:port]`, lowercased, for any URL with a host, including IPv6 literals. `None`
/// when `raw` does not parse or has no host.
///
/// Port of iOS `URL.omnigentOriginIdentity`. Unlike that helper, the scheme's default port is
/// dropped (`https://h:443` equals `https://h`), because the URL parser canonicalizes it.
pub(crate) fn origin_identity(raw: &str) -> Option<String> {
    let url = Url::parse(raw).ok()?;
    let host = url.host_str().filter(|host| !host.is_empty())?;
    let scheme = url.scheme();
    let identity = url.port().map_or_else(
        || format!("{scheme}://{host}"),
        |port| format!("{scheme}://{host}:{port}"),
    );
    Some(identity.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::origin_identity;

    #[test]
    fn origin_identity_covers_ipv6_and_folds_case() {
        assert_eq!(
            origin_identity("HTTP://[::1]:6767/omnigent/").as_deref(),
            Some("http://[::1]:6767")
        );
        assert_eq!(
            origin_identity("https://OMNIGENT.example.com:443/x?y#z").as_deref(),
            Some("https://omnigent.example.com")
        );
        assert_eq!(origin_identity("not a url"), None);
        assert_eq!(origin_identity("mailto:a@b.c"), None);
    }
}
