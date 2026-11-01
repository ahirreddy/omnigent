//! Saved settings and organization-managed preferences, backed by host storage.

use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use omnigent_core::config::managed as managed_core;
use omnigent_core::config::settings as settings_core;
use serde_json::Value;

use crate::errors::{CoreError, core_error};
use crate::host::{ManagedPreferenceSource, SettingsStorage};

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

struct ForeignSettings(Arc<dyn SettingsStorage>);

impl fmt::Debug for ForeignSettings {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ForeignSettings")
    }
}

impl settings_core::SettingsStorage for ForeignSettings {
    fn get(&self, key: &str) -> Result<Option<Value>, settings_core::SettingsStorageError> {
        let text =
            self.0
                .get(key.to_owned())
                .map_err(|error| settings_core::SettingsStorageError {
                    message: error.to_string(),
                })?;
        text.map(|text| {
            serde_json::from_str(&text).map_err(|error| settings_core::SettingsStorageError {
                message: format!("the stored value is not JSON: {error}"),
            })
        })
        .transpose()
    }

    fn set(
        &self,
        key: &str,
        value: Option<Value>,
    ) -> Result<(), settings_core::SettingsStorageError> {
        self.0
            .set(key.to_owned(), value.map(|value| value.to_string()))
            .map_err(|error| settings_core::SettingsStorageError {
                message: error.to_string(),
            })
    }
}

/// An Electron setting that was not imported.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SkippedSetting {
    /// The Electron key.
    pub key: String,
    /// The value as JSON text.
    pub value: String,
    /// Why, for display.
    pub reason: String,
}

/// What an Electron settings import did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ElectronImportReport {
    /// The saved server was imported.
    pub imported_server_url: bool,
    /// Recent servers imported.
    pub imported_recent_servers: u64,
    /// Settings left out.
    pub skipped: Vec<SkippedSetting>,
}

/// The user's saved server, recent servers and protocol grants.
#[derive(uniffi::Object)]
pub struct SettingsStore {
    inner: Mutex<settings_core::SettingsStore<ForeignSettings>>,
}

impl fmt::Debug for SettingsStore {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SettingsStore")
    }
}

#[uniffi::export]
impl SettingsStore {
    /// Loads the settings from `storage`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Settings`] when storage fails or holds an unexpected value.
    #[uniffi::constructor]
    pub fn load(storage: Arc<dyn SettingsStorage>) -> Result<Arc<Self>, CoreError> {
        let inner =
            settings_core::SettingsStore::load(ForeignSettings(storage)).map_err(core_error)?;
        Ok(Arc::new(Self {
            inner: Mutex::new(inner),
        }))
    }

    /// The saved server, if any.
    pub fn server_url(&self) -> Option<String> {
        lock(&self.inner).server_url().map(str::to_owned)
    }

    /// Recent servers, newest first.
    pub fn recent_servers(&self) -> Vec<String> {
        lock(&self.inner).recent_servers().to_vec()
    }

    /// Saves (or clears) the server.
    ///
    /// # Errors
    ///
    /// [`CoreError::Settings`].
    pub fn set_server_url(&self, url: Option<String>) -> Result<(), CoreError> {
        lock(&self.inner).set_server_url(url).map_err(core_error)
    }

    /// Puts `url` at the head of the recent servers.
    ///
    /// # Errors
    ///
    /// [`CoreError::Settings`].
    pub fn remember_recent_server(&self, url: String) -> Result<(), CoreError> {
        lock(&self.inner)
            .remember_recent_server(&url)
            .map_err(core_error)
    }

    /// The server to open at launch, if auto-open is on.
    ///
    /// # Errors
    ///
    /// [`CoreError::Settings`].
    pub fn auto_open_server_url(&self) -> Result<Option<String>, CoreError> {
        lock(&self.inner)
            .auto_open_server_url()
            .map(|url| url.map(str::to_owned))
            .map_err(core_error)
    }

    /// Records a successful connection to the saved server.
    ///
    /// # Errors
    ///
    /// [`CoreError::Settings`].
    pub fn connection_succeeded(&self) -> Result<(), CoreError> {
        lock(&self.inner).connection_succeeded().map_err(core_error)
    }

    /// Stops auto-opening `server_url` after a failed OIDC sign-in. Returns whether it changed.
    ///
    /// # Errors
    ///
    /// [`CoreError::Settings`].
    pub fn stop_auto_opening_oidc_server(&self, server_url: String) -> Result<bool, CoreError> {
        lock(&self.inner)
            .stop_auto_opening_oidc_server(&server_url)
            .map_err(core_error)
    }

    /// Suppresses auto-opening `server_url` until the next successful connection. Returns
    /// whether it changed.
    ///
    /// # Errors
    ///
    /// [`CoreError::Settings`].
    pub fn suppress_auto_opening_oidc_server(&self, server_url: String) -> Result<bool, CoreError> {
        lock(&self.inner)
            .suppress_auto_opening_oidc_server(&server_url)
            .map_err(core_error)
    }

    /// The saved or recent server URL with `origin`.
    pub fn known_server_url(&self, origin: String) -> Option<String> {
        lock(&self.inner)
            .known_server_url(&origin)
            .map(str::to_owned)
    }

    /// The origins of the saved and recent servers.
    pub fn known_origins(&self) -> Vec<String> {
        lock(&self.inner).known_origins()
    }

    /// Whether external links with `scheme` may open from `origin`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Settings`].
    pub fn is_protocol_allowed(&self, scheme: String, origin: String) -> Result<bool, CoreError> {
        lock(&self.inner)
            .is_protocol_allowed(&scheme, &origin)
            .map_err(core_error)
    }

    /// Lets external links with `scheme` open from `origin`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Settings`].
    pub fn allow_protocol(&self, scheme: String, origin: String) -> Result<(), CoreError> {
        lock(&self.inner)
            .allow_protocol(&scheme, &origin)
            .map_err(core_error)
    }

    /// Imports the Electron app's settings (JSON object text).
    ///
    /// # Errors
    ///
    /// [`CoreError::Decode`] for text that is not JSON, [`CoreError::Settings`] otherwise.
    pub fn import_electron_settings(
        &self,
        json: String,
    ) -> Result<ElectronImportReport, CoreError> {
        let value: Value = serde_json::from_str(&json).map_err(|error| CoreError::Decode {
            message: format!("Electron settings are not JSON: {error}"),
        })?;
        let report = lock(&self.inner)
            .import_electron_settings(&value)
            .map_err(core_error)?;
        Ok(ElectronImportReport {
            imported_server_url: report.imported_server_url,
            imported_recent_servers: u64::try_from(report.imported_recent_servers)
                .unwrap_or(u64::MAX),
            skipped: report
                .skipped
                .into_iter()
                .map(|skipped| SkippedSetting {
                    key: skipped.key,
                    value: skipped.value,
                    reason: format!("{:?}", skipped.reason),
                })
                .collect(),
        })
    }
}

/// An organization server.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ManagedServer {
    /// The server URL.
    pub url: String,
    /// The administrator's name for it.
    pub name: Option<String>,
    /// Its origin.
    pub origin: String,
    /// `host[:port]`.
    pub authority: String,
    /// The name, or the host.
    pub display_name: String,
}

/// The effective `serverUrls` and where they came from.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ManagedServers {
    /// The domain they were read from, if any sets them.
    pub servers_domain: Option<String>,
    /// An MDM profile forces them.
    pub servers_are_forced: bool,
    /// Organization servers, most preferred first.
    pub servers: Vec<ManagedServer>,
}

impl From<managed_core::ManagedServer> for ManagedServer {
    fn from(server: managed_core::ManagedServer) -> Self {
        Self {
            display_name: server.display_name().to_owned(),
            url: server.url,
            name: server.name,
            origin: server.origin,
            authority: server.authority,
        }
    }
}

struct ForeignManaged {
    source: Arc<dyn ManagedPreferenceSource>,
    decode_errors: Arc<Mutex<Vec<String>>>,
}

impl managed_core::ManagedPreferenceSource for ForeignManaged {
    fn value(&self, key: &str, domain: &str) -> Option<Value> {
        let text = self.source.value(key.to_owned(), domain.to_owned())?;
        match serde_json::from_str(&text) {
            Ok(value) => Some(value),
            Err(error) => {
                lock(&self.decode_errors).push(format!(
                    "managed preference {key:?} in {domain} is not JSON: {error}"
                ));
                None
            }
        }
    }

    fn is_forced(&self, key: &str, domain: &str) -> bool {
        self.source.is_forced(key.to_owned(), domain.to_owned())
    }
}

/// Organization-managed (MDM) preferences across `UserDefaults` domains: the first domain that
/// sets a key wins.
#[derive(uniffi::Object)]
pub struct ManagedPreferences {
    inner: managed_core::ManagedPreferences<ForeignManaged>,
    decode_errors: Arc<Mutex<Vec<String>>>,
}

impl fmt::Debug for ManagedPreferences {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ManagedPreferences")
            .field("domains", &self.inner.domains())
            .finish_non_exhaustive()
    }
}

impl ManagedPreferences {
    fn checked<T>(
        &self,
        result: Result<T, managed_core::ManagedConfigError>,
    ) -> Result<T, CoreError> {
        let errors = std::mem::take(&mut *lock(&self.decode_errors));
        if !errors.is_empty() {
            return Err(CoreError::Decode {
                message: errors.join("; "),
            });
        }
        result.map_err(core_error)
    }
}

#[uniffi::export]
impl ManagedPreferences {
    /// Reads `domains`, in order.
    #[uniffi::constructor]
    pub fn new(domains: Vec<String>, source: Arc<dyn ManagedPreferenceSource>) -> Arc<Self> {
        let decode_errors = Arc::new(Mutex::new(Vec::new()));
        Arc::new(Self {
            inner: managed_core::ManagedPreferences::new(
                domains,
                ForeignManaged {
                    source,
                    decode_errors: Arc::clone(&decode_errors),
                },
            ),
            decode_errors,
        })
    }

    /// The macOS desktop domains: the app's own, then `ai.omnigent.mac` and
    /// `ai.omnigent.desktop`.
    #[uniffi::constructor]
    pub fn desktop(
        bundle_identifier: Option<String>,
        source: Arc<dyn ManagedPreferenceSource>,
    ) -> Arc<Self> {
        Self::new(
            managed_core::desktop_domains(bundle_identifier.as_deref()),
            source,
        )
    }

    /// The domains read, in order.
    pub fn domains(&self) -> Vec<String> {
        self.inner.domains().to_vec()
    }

    /// The organization servers.
    ///
    /// # Errors
    ///
    /// [`CoreError::ManagedConfig`] for an invalid value in the winning domain,
    /// [`CoreError::Decode`] when the host returned a value that is not JSON.
    pub fn servers(&self) -> Result<ManagedServers, CoreError> {
        let snapshot = self.checked(self.inner.servers())?;
        Ok(ManagedServers {
            servers_domain: snapshot.servers_domain,
            servers_are_forced: snapshot.servers_are_forced,
            servers: snapshot.servers.into_iter().map(Into::into).collect(),
        })
    }

    /// Whether Databricks-internal features are enabled.
    ///
    /// # Errors
    ///
    /// As [`Self::servers`].
    pub fn databricks_internal_features_enabled(&self) -> Result<bool, CoreError> {
        self.checked(self.inner.databricks_internal_features_enabled())
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;
    use crate::host::SettingsStorageError;

    #[derive(Default)]
    struct MemorySettings(Mutex<HashMap<String, String>>);

    impl SettingsStorage for MemorySettings {
        fn get(&self, key: String) -> Result<Option<String>, SettingsStorageError> {
            Ok(lock(&self.0).get(&key).cloned())
        }

        fn set(&self, key: String, value: Option<String>) -> Result<(), SettingsStorageError> {
            match value {
                Some(value) => lock(&self.0).insert(key, value),
                None => lock(&self.0).remove(&key),
            };
            Ok(())
        }
    }

    struct Prefs(HashMap<(String, String), String>);

    impl ManagedPreferenceSource for Prefs {
        fn value(&self, key: String, domain: String) -> Option<String> {
            self.0.get(&(key, domain)).cloned()
        }

        fn is_forced(&self, _key: String, _domain: String) -> bool {
            true
        }
    }

    #[test]
    fn settings_round_trip_through_host_storage() {
        let storage = Arc::new(MemorySettings::default());
        let store = SettingsStore::load(storage.clone()).unwrap();
        store
            .set_server_url(Some("https://omnigent.example.com".into()))
            .unwrap();
        store
            .remember_recent_server("https://omnigent.example.com".into())
            .unwrap();
        let reloaded = SettingsStore::load(storage).unwrap();
        assert_eq!(
            reloaded.server_url().as_deref(),
            Some("https://omnigent.example.com")
        );
        assert_eq!(reloaded.recent_servers(), ["https://omnigent.example.com"]);
    }

    #[test]
    fn corrupt_stored_settings_are_errors() {
        let storage = Arc::new(MemorySettings::default());
        lock(&storage.0).insert(
            settings_core::keys::SERVER_URL.to_owned(),
            "{not json".to_owned(),
        );
        let error = SettingsStore::load(storage).unwrap_err();
        assert!(matches!(error, CoreError::Settings { .. }), "{error:?}");
    }

    #[test]
    fn managed_servers_and_invalid_host_json() {
        let domain = "ai.omnigent.mac".to_owned();
        let mut values = HashMap::new();
        values.insert(
            ("serverUrls".to_owned(), domain.clone()),
            r#"["https://corp.example.com"]"#.to_owned(),
        );
        let prefs = ManagedPreferences::new(vec![domain.clone()], Arc::new(Prefs(values)));
        let servers = prefs.servers().unwrap();
        assert_eq!(servers.servers_domain.as_deref(), Some(domain.as_str()));
        assert_eq!(servers.servers.len(), 1);
        assert_eq!(servers.servers[0].authority, "corp.example.com");

        let mut broken = HashMap::new();
        broken.insert(("serverUrls".to_owned(), domain.clone()), "[".to_owned());
        let prefs = ManagedPreferences::new(vec![domain], Arc::new(Prefs(broken)));
        assert!(matches!(prefs.servers(), Err(CoreError::Decode { .. })));
    }
}
