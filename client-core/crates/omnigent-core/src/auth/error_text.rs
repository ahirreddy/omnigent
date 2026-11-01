//! User-facing connection-error text and recovery bookkeeping.
//!
//! Port of `OmnigentWebView.connectionErrorMessage`, the navigation-failure filter, and
//! `RecoveryPage` / `RecoveryIntent` from web/ios. Hosts describe platform errors as a
//! [`PlatformError`] (domain, code, localized text); classification keys on domain and code,
//! never on the localized text.

use url::Url;

use crate::server_url;

/// Foundation's `NSURLErrorDomain`.
pub const NS_URL_ERROR_DOMAIN: &str = "NSURLErrorDomain";
/// `NSURLErrorCancelled`.
pub const NS_URL_ERROR_CANCELLED: i64 = -999;
/// `NSURLErrorCannotFindHost`.
pub const NS_URL_ERROR_CANNOT_FIND_HOST: i64 = -1003;
/// `NSURLErrorDNSLookupFailed`.
pub const NS_URL_ERROR_DNS_LOOKUP_FAILED: i64 = -1006;

/// The message for a DNS failure on a managed (Jamf-compliance-gated) device.
pub const JAMF_COMPLIANCE_MESSAGE: &str =
    "Couldn\u{2019}t reach the server. Check your device\u{2019}s compliance status in Jamf.";

/// A platform error as the host reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlatformError {
    /// The error domain (`NSURLErrorDomain` for URL loading).
    pub domain: String,
    /// The domain's code.
    pub code: i64,
    /// The platform's localized description, shown verbatim when nothing better applies.
    pub localized_description: String,
}

impl PlatformError {
    /// Whether this is a URL-loading DNS failure (cannot find host, DNS lookup failed).
    #[must_use]
    pub fn is_dns_failure(&self) -> bool {
        self.domain == NS_URL_ERROR_DOMAIN
            && matches!(
                self.code,
                NS_URL_ERROR_CANNOT_FIND_HOST | NS_URL_ERROR_DNS_LOOKUP_FAILED
            )
    }

    /// Whether this is URL loading's own cancellation.
    #[must_use]
    pub fn is_cancellation(&self) -> bool {
        self.domain == NS_URL_ERROR_DOMAIN && self.code == NS_URL_ERROR_CANCELLED
    }
}

/// The message for a failed connection: the Jamf compliance hint for DNS failures when
/// Databricks-internal features are enabled, otherwise the platform's own message.
#[must_use]
pub fn connection_error_message(
    error: &PlatformError,
    databricks_internal_features: bool,
) -> String {
    if databricks_internal_features && error.is_dns_failure() {
        JAMF_COMPLIANCE_MESSAGE.to_owned()
    } else {
        error.localized_description.clone()
    }
}

/// What a page-load failure should show, or `None` when it must be ignored.
///
/// Ignored are URL loading's own cancellation and a failure for a URL off the pinned server
/// origin (a subresource or a page the user navigated away to). The flag is read at failure
/// time, never captured earlier.
#[must_use]
pub fn navigation_failure_message(
    error: &PlatformError,
    failed_url: &Url,
    pinned_origin: &str,
    databricks_internal_features: bool,
) -> Option<String> {
    if error.is_cancellation() || server_url::origin(failed_url) != pinned_origin {
        return None;
    }
    Some(connection_error_message(
        error,
        databricks_internal_features,
    ))
}

/// A page to restore after recovery, valid only for the destination it was recorded for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecoveryPage {
    /// The page to restore.
    pub url: String,
    /// The connection destination it was recorded under.
    pub initial_url: String,
}

impl RecoveryPage {
    /// The page, if `current_initial_url` is exactly the recorded destination.
    #[must_use]
    pub fn url_for(&self, current_initial_url: &str) -> Option<&str> {
        (current_initial_url == self.initial_url).then_some(self.url.as_str())
    }
}

/// Whether a connection is a silent recovery or an explicit connect.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionIntent {
    /// Re-establish the session the user was already in.
    Recover,
    /// A fresh connect.
    Connect,
}

/// A recovery started for one destination. Any other destination connects normally, so a later
/// explicit Connect is never treated as a silent recovery.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecoveryIntent {
    /// The destination the recovery was started for.
    pub initial_url: String,
}

impl RecoveryIntent {
    /// The intent for `current_initial_url`.
    #[must_use]
    pub fn intent_for(&self, current_initial_url: &str) -> ConnectionIntent {
        if current_initial_url == self.initial_url {
            ConnectionIntent::Recover
        } else {
            ConnectionIntent::Connect
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn url_error(code: i64, description: &str) -> PlatformError {
        PlatformError {
            domain: NS_URL_ERROR_DOMAIN.into(),
            code,
            localized_description: description.into(),
        }
    }

    #[test]
    fn dns_failure_shows_jamf_hint_only_when_enabled() {
        for code in [
            NS_URL_ERROR_CANNOT_FIND_HOST,
            NS_URL_ERROR_DNS_LOOKUP_FAILED,
        ] {
            let error = url_error(
                code,
                "A server with the specified hostname could not be found.",
            );
            assert_eq!(
                connection_error_message(&error, true),
                JAMF_COMPLIANCE_MESSAGE
            );
            assert_eq!(
                connection_error_message(&error, false),
                error.localized_description
            );
        }
    }

    #[test]
    fn dns_mapping_ignores_localized_description() {
        let error = url_error(NS_URL_ERROR_CANNOT_FIND_HOST, "Serveur introuvable");
        assert_eq!(
            connection_error_message(&error, true),
            JAMF_COMPLIANCE_MESSAGE
        );
    }

    #[test]
    fn other_network_errors_keep_original_message() {
        // cannotConnectToHost, timedOut, notConnectedToInternet, networkConnectionLost,
        // secureConnectionFailed, serverCertificateUntrusted, cancelled.
        for code in [
            -1004,
            -1001,
            -1009,
            -1005,
            -1200,
            -1202,
            NS_URL_ERROR_CANCELLED,
        ] {
            let error = url_error(code, "original");
            assert_eq!(connection_error_message(&error, true), "original", "{code}");
        }
    }

    #[test]
    fn same_code_other_domain_is_not_dns() {
        for code in [
            NS_URL_ERROR_CANNOT_FIND_HOST,
            NS_URL_ERROR_DNS_LOOKUP_FAILED,
        ] {
            let error = PlatformError {
                domain: "OmnigentTests".into(),
                code,
                localized_description: "Unrelated failure".into(),
            };
            assert_eq!(connection_error_message(&error, true), "Unrelated failure");
        }
    }

    #[test]
    fn navigation_failure_message_uses_current_flag() {
        let pinned = "https://server.invalid";
        let failed = Url::parse("https://server.invalid").unwrap();
        let error = url_error(NS_URL_ERROR_CANNOT_FIND_HOST, "not found");
        let messages: Vec<_> = [true, true, false, false]
            .into_iter()
            .map(|enabled| navigation_failure_message(&error, &failed, pinned, enabled))
            .collect();
        assert_eq!(
            messages,
            [
                Some(JAMF_COMPLIANCE_MESSAGE.to_owned()),
                Some(JAMF_COMPLIANCE_MESSAGE.to_owned()),
                Some("not found".to_owned()),
                Some("not found".to_owned()),
            ]
        );
        assert_eq!(
            navigation_failure_message(
                &url_error(NS_URL_ERROR_CANCELLED, "cancelled"),
                &failed,
                pinned,
                true
            ),
            None,
            "cancellation is ignored"
        );
        assert_eq!(
            navigation_failure_message(
                &error,
                &Url::parse("https://unrelated.invalid").unwrap(),
                pinned,
                true
            ),
            None,
            "off-origin failures are ignored"
        );
    }

    #[test]
    fn recovery_page_applies_only_to_recorded_destination() {
        let page = RecoveryPage {
            url: "https://omnigent.example.com/c/old".into(),
            initial_url: "https://omnigent.example.com".into(),
        };
        assert_eq!(
            page.url_for("https://omnigent.example.com"),
            Some("https://omnigent.example.com/c/old")
        );
        assert_eq!(page.url_for("https://omnigent.example.com/c/new"), None);
        assert_eq!(page.url_for("https://other.example.com"), None);
    }

    #[test]
    fn recovery_intent_applies_only_to_started_destination() {
        let workspace = "https://workspace.cloud.databricks.com/ml/omnigents?o=1";
        let intent = RecoveryIntent {
            initial_url: workspace.into(),
        };
        assert_eq!(intent.intent_for(workspace), ConnectionIntent::Recover);
        assert_eq!(
            intent.intent_for("https://omnigent.example.com"),
            ConnectionIntent::Connect
        );
        assert_eq!(
            intent.intent_for("https://workspace.cloud.databricks.com/ml/omnigents/c/x?o=1"),
            ConnectionIntent::Connect
        );
    }
}
