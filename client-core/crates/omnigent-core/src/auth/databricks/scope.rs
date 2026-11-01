//! Credential scopes: which saved grant a workspace URL uses. Port of `DatabricksCredentialScope`
//! in `web/ios/Omnigent/DatabricksCredentialStore.swift`.

use url::Url;

use super::config::OAuthConfiguration;
use super::error::DatabricksError;
use super::query;
use crate::auth::SecureStoreKey;
use crate::auth::mode::ServerAuthentication;

/// One saved grant: the normalized workspace origin, the optional `o=` id, and the client id.
///
/// Paths, host case and an explicit `:443` never create separate scopes; different `o=` values on
/// one host always do.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct CredentialScope {
    /// `https://<lowercase host>` with no port, path or trailing slash.
    workspace_origin: String,
    /// The same origin as a URL (path `/`).
    origin_url: Url,
    client_id: String,
    workspace_id: Option<String>,
}

impl CredentialScope {
    /// The scope for `workspace_url` under `configuration`.
    ///
    /// # Errors
    ///
    /// [`DatabricksError::InvalidWorkspace`] unless the URL is `https` on a Databricks workspace
    /// host with no userinfo and no port other than 443, and carries at most one `o=` whose value
    /// is a non-empty ASCII decimal string.
    pub fn new(
        workspace_url: &Url,
        configuration: &OAuthConfiguration,
    ) -> Result<Self, DatabricksError> {
        let host = workspace_url
            .host_str()
            .filter(|host| !host.is_empty())
            .ok_or(DatabricksError::InvalidWorkspace)?;
        if workspace_url.scheme() != "https"
            || ServerAuthentication::for_host(Some(host))
                != ServerAuthentication::DatabricksWorkspace
            || !workspace_url.username().is_empty()
            || workspace_url.password().is_some()
            || workspace_url.port().is_some_and(|port| port != 443)
        {
            return Err(DatabricksError::InvalidWorkspace);
        }
        let workspace_origin = format!("https://{}", host.to_ascii_lowercase());
        let origin_url =
            Url::parse(&workspace_origin).map_err(|_| DatabricksError::InvalidWorkspace)?;
        Ok(Self {
            workspace_origin,
            origin_url,
            client_id: configuration.client_id().to_owned(),
            workspace_id: workspace_id(workspace_url)?,
        })
    }

    /// `https://<host>`, without a trailing slash.
    #[must_use]
    pub fn workspace_origin(&self) -> &str {
        &self.workspace_origin
    }

    /// The workspace origin as a URL (path `/`).
    #[must_use]
    pub const fn workspace_origin_url(&self) -> &Url {
        &self.origin_url
    }

    /// The workspace host, lowercase.
    #[must_use]
    pub fn host(&self) -> &str {
        self.workspace_origin
            .strip_prefix("https://")
            .unwrap_or(&self.workspace_origin)
    }

    /// The exact OAuth client id.
    #[must_use]
    pub fn client_id(&self) -> &str {
        &self.client_id
    }

    /// The `o=` workspace id, when the URL selected one.
    #[must_use]
    pub fn workspace_id(&self) -> Option<&str> {
        self.workspace_id.as_deref()
    }

    /// The Keychain account string. The origin is length-prefixed so no component can collide
    /// with the separator. Scopes without `o=` keep the original (pre-`o=`) format byte for byte so
    /// existing grants stay readable.
    #[must_use]
    pub fn account(&self) -> String {
        let base = format!(
            "{}:{}{}",
            self.workspace_origin.len(),
            self.workspace_origin,
            self.client_id
        );
        match &self.workspace_id {
            None => base,
            Some(id) => format!("o:{}:{id}:{base}", id.len()),
        }
    }

    /// Where the host's secure store keeps this scope's credential record.
    #[must_use]
    pub fn store_key(&self) -> SecureStoreKey {
        SecureStoreKey::new(SecureStoreKey::DATABRICKS_NAMESPACE, self.account())
    }
}

/// The single `o=` value of `url`, if any.
fn workspace_id(url: &Url) -> Result<Option<String>, DatabricksError> {
    let Some(raw) = url.query() else {
        return Ok(None);
    };
    let items = query::items(raw).ok_or(DatabricksError::InvalidWorkspace)?;
    match query::values(&items, "o").as_slice() {
        [] => Ok(None),
        [Some(value)] if is_decimal_id(value) => Ok(Some((*value).to_owned())),
        _ => Err(DatabricksError::InvalidWorkspace),
    }
}

/// A non-empty string of ASCII digits. Workspace ids are never parsed as numbers.
pub(super) fn is_decimal_id(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::databricks::test_support::{config_with, scope};

    /// `DatabricksCredentialStoreTests::testScopeCanonicalizationAndIsolation`.
    #[test]
    fn databricks_scope_canonicalization_and_isolation() {
        let first = scope("https://DBC-123.cloud.databricks.com:443/omnigent/c/abc?view=chat#view");
        let same = scope("https://dbc-123.cloud.databricks.com");
        assert_eq!(first, same);
        assert_eq!(first.account(), same.account());
        let other_client = CredentialScope::new(
            &Url::parse("https://dbc-123.cloud.databricks.com").unwrap(),
            &config_with("other-client"),
        )
        .unwrap();
        assert_ne!(first, other_client);
        assert_ne!(first.account(), other_client.account());
        assert_ne!(first, scope("https://adb-123.azuredatabricks.net"));
        assert_eq!(
            first.workspace_origin(),
            "https://dbc-123.cloud.databricks.com"
        );
    }

    /// `DatabricksCredentialStoreTests::testWorkspaceIDsSeparateScopesWithoutChangingLegacyKeys`.
    #[test]
    fn databricks_workspace_id_scopes_and_legacy_key() {
        let base = "https://dbc-123.cloud.databricks.com";
        let legacy = scope(base);
        assert_eq!(
            legacy.account(),
            format!("{}:{base}test-client", base.len())
        );
        let first = scope(&format!("{base}/omnigent?o=123"));
        let same = scope(&format!("{base}/omnigent/c/abc?view=chat&o=123#fragment"));
        let other = scope(&format!("{base}/omnigent?o=456"));
        assert_eq!(first, same);
        assert_eq!(first.account(), same.account());
        assert_ne!(first.account(), other.account());
        assert_ne!(first.account(), legacy.account());
        assert_eq!(first.workspace_id(), Some("123"));
        assert_eq!(
            first.account(),
            format!("o:3:123:{}:{base}test-client", base.len())
        );
        for query in ["o=", "o", "o=123&o=456", "o=abc", "o=-1", "o=12%203"] {
            let url = Url::parse(&format!("{base}/omnigent?{query}")).unwrap();
            assert_eq!(
                CredentialScope::new(&url, &config_with("test-client")),
                Err(DatabricksError::InvalidWorkspace),
                "{query}"
            );
        }
    }

    #[test]
    fn store_key_uses_databricks_namespace() {
        let key = scope("https://dbc-123.cloud.databricks.com").store_key();
        assert_eq!(key.namespace, SecureStoreKey::DATABRICKS_NAMESPACE);
        assert_eq!(
            key.account,
            "36:https://dbc-123.cloud.databricks.comtest-client"
        );
    }
}
