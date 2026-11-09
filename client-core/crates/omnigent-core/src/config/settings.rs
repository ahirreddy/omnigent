//! The platform-independent half of the shells' settings store.
//!
//! It covers the saved (default) server, the recent-server list, auto-open suppression after a
//! refused sign-in, protocol-handler grants, and import of the Electron shell's `settings.json`.
//!
//! Port of `web/ios/Omnigent/SettingsStore.swift`; the recents, known-server and import rules
//! also follow `rememberRecentServer`, `findKnownServerUrl` and `knownOrigins` in
//! `web/electron/src/main.js`. Persistence goes through [`SettingsStorage`]; the iOS host backs it
//! with `UserDefaults` under the same keys the Swift store used ([`keys`]), so existing installs
//! keep their data.
//!
//! Every value read from storage is type-checked. A stored value of the wrong type is a typed
//! [`SettingsError::UnexpectedValue`] rather than a silent default; the host decides whether to
//! clear the key.

use std::collections::BTreeMap;
use std::fmt;

use serde_json::{Map, Value};

use crate::config::origin_identity;

/// The storage keys, shared with the Swift `SettingsStore`.
pub mod keys {
    /// The saved server URL (`String`).
    pub const SERVER_URL: &str = "omnigent.serverURL";
    /// Recent server URLs, most recent first (`[String]`).
    pub const RECENT_SERVERS: &str = "omnigent.recentServers";
    /// Protocol-handler grants, origin to schemes (`[String: [String]]`).
    pub const ALLOWED_PROTOCOLS: &str = "omnigent.allowedProtocols";
    /// The saved server whose last sign-in was refused (`String`).
    pub const AUTO_OPEN_SUPPRESSED_SERVER: &str = "omnigent.autoOpenSuppressedServer";
}

/// How many recent servers are kept.
pub const MAX_RECENT_SERVERS: usize = 5;

/// A host storage failure, with the platform's message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsStorageError {
    /// Host-provided detail.
    pub message: String,
}

impl fmt::Display for SettingsStorageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for SettingsStorageError {}

/// Host key-value persistence (`UserDefaults`, a JSON file, `localStorage`). Values are JSON:
/// strings, arrays of strings, and objects of arrays of strings.
pub trait SettingsStorage {
    /// The value stored under `key`, or `None`.
    ///
    /// # Errors
    ///
    /// [`SettingsStorageError`] when the store cannot be read.
    fn get(&self, key: &str) -> Result<Option<Value>, SettingsStorageError>;

    /// Stores `value` under `key`; `None` removes the key.
    ///
    /// # Errors
    ///
    /// [`SettingsStorageError`] when the store cannot be written.
    fn set(&self, key: &str, value: Option<Value>) -> Result<(), SettingsStorageError>;
}

/// Why a settings operation failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SettingsError {
    /// The host store failed for `key`.
    Storage {
        /// The key being read or written.
        key: String,
        /// The host's error.
        source: SettingsStorageError,
    },
    /// The stored value under `key` has the wrong type.
    UnexpectedValue {
        /// The key.
        key: String,
        /// What was expected, for example `"an array of strings"`.
        expected: &'static str,
    },
    /// The Electron settings to import are not a JSON object.
    ImportNotAnObject,
}

impl fmt::Display for SettingsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Storage { key, source } => {
                write!(f, "settings storage failed for {key}: {source}")
            }
            Self::UnexpectedValue { key, expected } => {
                write!(f, "stored setting {key} is not {expected}")
            }
            Self::ImportNotAnObject => f.write_str("the settings to import are not a JSON object"),
        }
    }
}

impl std::error::Error for SettingsError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Storage { source, .. } => Some(source),
            Self::UnexpectedValue { .. } | Self::ImportNotAnObject => None,
        }
    }
}

/// The user's server settings over a host store. Mirrors the Swift store: the saved server and
/// recents are cached, while suppression and protocol grants are read from storage on each use.
#[derive(Debug)]
pub struct SettingsStore<S> {
    storage: S,
    server_url: Option<String>,
    recent_servers: Vec<String>,
}

impl<S: SettingsStorage> SettingsStore<S> {
    /// Loads the saved server and recents.
    ///
    /// # Errors
    ///
    /// [`SettingsError`] when storage fails or holds a value of the wrong type.
    pub fn load(storage: S) -> Result<Self, SettingsError> {
        let server_url = read_string(&storage, keys::SERVER_URL)?;
        let recent_servers = read_string_list(&storage, keys::RECENT_SERVERS)?.unwrap_or_default();
        Ok(Self {
            storage,
            server_url,
            recent_servers,
        })
    }

    /// The host store.
    pub const fn storage(&self) -> &S {
        &self.storage
    }

    /// The saved (default) server URL: the Connect prefill and, unless suppressed, the server
    /// opened on launch.
    #[must_use]
    pub fn server_url(&self) -> Option<&str> {
        self.server_url.as_deref()
    }

    /// Recent server URLs, most recent first, at most [`MAX_RECENT_SERVERS`].
    #[must_use]
    pub fn recent_servers(&self) -> &[String] {
        &self.recent_servers
    }

    /// Saves (or clears) the server URL. Choosing another server ends a refused server's
    /// suppression.
    ///
    /// # Errors
    ///
    /// [`SettingsError`] when storage fails; the cached value is unchanged then.
    pub fn set_server_url(&mut self, url: Option<String>) -> Result<(), SettingsError> {
        write(
            &self.storage,
            keys::SERVER_URL,
            url.clone().map(Value::String),
        )?;
        self.server_url = url;
        let suppressed = read_string(&self.storage, keys::AUTO_OPEN_SUPPRESSED_SERVER)?;
        if suppressed.is_some() && suppressed != self.server_url {
            write(&self.storage, keys::AUTO_OPEN_SUPPRESSED_SERVER, None)?;
        }
        Ok(())
    }

    /// Records `url` (the clean server URL, never a `/c/<id>` load URL) at the head of the
    /// recents, de-duplicated and capped at [`MAX_RECENT_SERVERS`].
    ///
    /// # Errors
    ///
    /// [`SettingsError`] when storage fails; the cached list is unchanged then.
    pub fn remember_recent_server(&mut self, url: &str) -> Result<(), SettingsError> {
        let recents = with_recent(url, &self.recent_servers);
        write(
            &self.storage,
            keys::RECENT_SERVERS,
            Some(string_list(&recents)),
        )?;
        self.recent_servers = recents;
        Ok(())
    }

    /// Clears the saved server when `matches` accepts it (for example a Databricks credential
    /// scope comparison done by the host). Returns whether it was cleared.
    ///
    /// # Errors
    ///
    /// [`SettingsError`] when storage fails.
    pub fn stop_auto_opening_matching(
        &mut self,
        matches: impl FnOnce(&str) -> bool,
    ) -> Result<bool, SettingsError> {
        match self.server_url.as_deref() {
            Some(saved) if matches(saved) => {
                self.set_server_url(None)?;
                Ok(true)
            }
            _ => Ok(false),
        }
    }

    /// After signing out of an OIDC server, stops reopening it on launch. Its grant is per origin,
    /// so a saved URL anywhere on that origin is cleared; recents stay for an explicit reconnect.
    /// Returns whether the saved server was cleared.
    ///
    /// # Errors
    ///
    /// [`SettingsError`] when storage fails.
    pub fn stop_auto_opening_oidc_server(
        &mut self,
        server_url: &str,
    ) -> Result<bool, SettingsError> {
        let target = origin_identity(server_url);
        self.stop_auto_opening_matching(|saved| same_origin(saved, target.as_deref()))
    }

    /// After an OIDC server refuses a sign-in, keeps it as the Connect prefill but stops reopening
    /// it on launch. Returns whether the suppression was recorded.
    ///
    /// # Errors
    ///
    /// [`SettingsError`] when storage fails.
    pub fn suppress_auto_opening_oidc_server(
        &mut self,
        server_url: &str,
    ) -> Result<bool, SettingsError> {
        let target = origin_identity(server_url);
        let Some(saved) = self
            .server_url
            .as_deref()
            .filter(|saved| same_origin(saved, target.as_deref()))
        else {
            return Ok(false);
        };
        write(
            &self.storage,
            keys::AUTO_OPEN_SUPPRESSED_SERVER,
            Some(Value::String(saved.to_owned())),
        )?;
        Ok(true)
    }

    /// The saved server to open on launch; `None` when there is none or its sign-in was refused.
    ///
    /// # Errors
    ///
    /// [`SettingsError`] when storage fails.
    pub fn auto_open_server_url(&self) -> Result<Option<&str>, SettingsError> {
        let suppressed = read_string(&self.storage, keys::AUTO_OPEN_SUPPRESSED_SERVER)?;
        Ok(self
            .server_url
            .as_deref()
            .filter(|saved| suppressed.as_deref() != Some(*saved)))
    }

    /// A server loaded: a refusal recorded for it no longer applies.
    ///
    /// # Errors
    ///
    /// [`SettingsError`] when storage fails.
    pub fn connection_succeeded(&mut self) -> Result<(), SettingsError> {
        write(&self.storage, keys::AUTO_OPEN_SUPPRESSED_SERVER, None)
    }

    /// The recorded URL (origin, or origin plus workspace mount) of a server the user connected to
    /// whose origin is `origin`, the saved server first, then recents. Reusing it lets a deep link
    /// to a known workspace open without probing for the mount.
    #[must_use]
    pub fn known_server_url(&self, origin: &str) -> Option<&str> {
        self.candidates()
            .find(|candidate| origin_identity(candidate).as_deref() == Some(origin))
    }

    /// Origins of every server the user connected to (saved server and recents), in that order,
    /// without duplicates. A deep link to one of these needs no consent.
    #[must_use]
    pub fn known_origins(&self) -> Vec<String> {
        let mut origins: Vec<String> = Vec::new();
        for origin in self.candidates().filter_map(origin_identity) {
            if !origins.contains(&origin) {
                origins.push(origin);
            }
        }
        origins
    }

    /// Whether the user allowed `origin` to open `scheme` links (for example `vscode`).
    ///
    /// # Errors
    ///
    /// [`SettingsError`] when storage fails or holds a value of the wrong type.
    pub fn is_protocol_allowed(&self, scheme: &str, origin: &str) -> Result<bool, SettingsError> {
        let scheme = scheme.to_lowercase();
        Ok(self
            .allowed_protocols()?
            .get(origin)
            .is_some_and(|schemes| schemes.contains(&scheme)))
    }

    /// Allows `origin` to open `scheme` links from now on.
    ///
    /// # Errors
    ///
    /// [`SettingsError`] when storage fails or holds a value of the wrong type.
    pub fn allow_protocol(&mut self, scheme: &str, origin: &str) -> Result<(), SettingsError> {
        let mut grants = self.allowed_protocols()?;
        let schemes = grants.entry(origin.to_owned()).or_default();
        let scheme = scheme.to_lowercase();
        if !schemes.contains(&scheme) {
            schemes.push(scheme);
        }
        let object: Map<String, Value> = grants
            .into_iter()
            .map(|(origin, schemes)| (origin, string_list(&schemes)))
            .collect();
        write(
            &self.storage,
            keys::ALLOWED_PROTOCOLS,
            Some(Value::Object(object)),
        )
    }

    /// Imports the Electron shell's `settings.json` (`server_url`, `recent_servers`) for a user
    /// moving to the native app. An already saved native server is kept; imported recents follow
    /// the native ones, de-duplicated and capped. Entries that cannot be imported are listed in
    /// the report, not dropped silently.
    ///
    /// # Errors
    ///
    /// [`SettingsError::ImportNotAnObject`], or a storage failure.
    pub fn import_electron_settings(
        &mut self,
        electron: &Value,
    ) -> Result<ElectronImportReport, SettingsError> {
        let Value::Object(settings) = electron else {
            return Err(SettingsError::ImportNotAnObject);
        };
        let mut report = ElectronImportReport::default();

        match settings.get("server_url") {
            None | Some(Value::Null) => {}
            Some(Value::String(url)) if self.server_url.is_none() => {
                self.set_server_url(Some(url.clone()))?;
                report.imported_server_url = true;
            }
            Some(Value::String(_)) => report.skipped.push(SkippedSetting {
                key: "server_url".to_owned(),
                value: electron_value(settings, "server_url"),
                reason: SkipReason::AlreadySet,
            }),
            Some(other) => report.skipped.push(SkippedSetting {
                key: "server_url".to_owned(),
                value: other.to_string(),
                reason: SkipReason::NotAString,
            }),
        }

        let mut recents = self.recent_servers.clone();
        match settings.get("recent_servers") {
            None | Some(Value::Null) => {}
            Some(Value::Array(entries)) => {
                for (index, entry) in entries.iter().enumerate() {
                    let key = format!("recent_servers[{index}]");
                    match entry {
                        Value::String(url) if recents.contains(url) => {}
                        Value::String(_) if recents.len() >= MAX_RECENT_SERVERS => {
                            report.skipped.push(SkippedSetting {
                                key,
                                value: entry.to_string(),
                                reason: SkipReason::RecentServersFull,
                            });
                        }
                        Value::String(url) => {
                            recents.push(url.clone());
                            report.imported_recent_servers += 1;
                        }
                        other => report.skipped.push(SkippedSetting {
                            key,
                            value: other.to_string(),
                            reason: SkipReason::NotAString,
                        }),
                    }
                }
            }
            Some(other) => report.skipped.push(SkippedSetting {
                key: "recent_servers".to_owned(),
                value: other.to_string(),
                reason: SkipReason::NotAnArray,
            }),
        }
        if recents != self.recent_servers {
            write(
                &self.storage,
                keys::RECENT_SERVERS,
                Some(string_list(&recents)),
            )?;
            self.recent_servers = recents;
        }
        Ok(report)
    }

    fn candidates(&self) -> impl Iterator<Item = &str> {
        self.server_url
            .as_deref()
            .into_iter()
            .chain(self.recent_servers.iter().map(String::as_str))
    }

    fn allowed_protocols(&self) -> Result<BTreeMap<String, Vec<String>>, SettingsError> {
        let unexpected = || SettingsError::UnexpectedValue {
            key: keys::ALLOWED_PROTOCOLS.to_owned(),
            expected: "an object of string arrays",
        };
        let Some(value) = read(&self.storage, keys::ALLOWED_PROTOCOLS)? else {
            return Ok(BTreeMap::new());
        };
        let Value::Object(object) = value else {
            return Err(unexpected());
        };
        object
            .into_iter()
            .map(|(origin, schemes)| {
                strings_of(schemes)
                    .map(|schemes| (origin, schemes))
                    .ok_or_else(unexpected)
            })
            .collect()
    }
}

/// What [`SettingsStore::import_electron_settings`] did.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ElectronImportReport {
    /// Whether `server_url` became the saved server.
    pub imported_server_url: bool,
    /// How many recent servers were added.
    pub imported_recent_servers: usize,
    /// Values that were not imported, and why.
    pub skipped: Vec<SkippedSetting>,
}

/// One Electron setting that was not imported.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkippedSetting {
    /// The Electron key, with an index for list entries (`recent_servers[2]`).
    pub key: String,
    /// The value as JSON text.
    pub value: String,
    /// Why it was skipped.
    pub reason: SkipReason,
}

/// Why an Electron setting was not imported.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkipReason {
    /// The value is not a string.
    NotAString,
    /// The value is not an array.
    NotAnArray,
    /// The native store already has a saved server.
    AlreadySet,
    /// The recent-server list is already at [`MAX_RECENT_SERVERS`].
    RecentServersFull,
}

/// `url` at the head of `existing`, de-duplicated and capped.
fn with_recent(url: &str, existing: &[String]) -> Vec<String> {
    std::iter::once(url)
        .chain(
            existing
                .iter()
                .map(String::as_str)
                .filter(|recent| *recent != url),
        )
        .take(MAX_RECENT_SERVERS)
        .map(str::to_owned)
        .collect()
}

/// Whether `saved` parses to the origin `target`. A URL with no origin matches nothing.
fn same_origin(saved: &str, target: Option<&str>) -> bool {
    target.is_some_and(|target| origin_identity(saved).as_deref() == Some(target))
}

fn electron_value(settings: &Map<String, Value>, key: &str) -> String {
    settings.get(key).map(Value::to_string).unwrap_or_default()
}

fn string_list(values: &[String]) -> Value {
    Value::Array(values.iter().cloned().map(Value::String).collect())
}

fn strings_of(value: Value) -> Option<Vec<String>> {
    let Value::Array(entries) = value else {
        return None;
    };
    entries
        .into_iter()
        .map(|entry| match entry {
            Value::String(text) => Some(text),
            _ => None,
        })
        .collect()
}

fn read(storage: &impl SettingsStorage, key: &str) -> Result<Option<Value>, SettingsError> {
    storage.get(key).map_err(|source| SettingsError::Storage {
        key: key.to_owned(),
        source,
    })
}

fn write(
    storage: &impl SettingsStorage,
    key: &str,
    value: Option<Value>,
) -> Result<(), SettingsError> {
    storage
        .set(key, value)
        .map_err(|source| SettingsError::Storage {
            key: key.to_owned(),
            source,
        })
}

fn read_string(storage: &impl SettingsStorage, key: &str) -> Result<Option<String>, SettingsError> {
    match read(storage, key)? {
        None => Ok(None),
        Some(Value::String(text)) => Ok(Some(text)),
        Some(_) => Err(SettingsError::UnexpectedValue {
            key: key.to_owned(),
            expected: "a string",
        }),
    }
}

fn read_string_list(
    storage: &impl SettingsStorage,
    key: &str,
) -> Result<Option<Vec<String>>, SettingsError> {
    read(storage, key)?
        .map(|value| {
            strings_of(value).ok_or_else(|| SettingsError::UnexpectedValue {
                key: key.to_owned(),
                expected: "an array of strings",
            })
        })
        .transpose()
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::rc::Rc;

    use serde_json::json;

    use super::*;

    /// In-memory `UserDefaults`. Clones share one map, so a second store over a clone models a
    /// relaunch.
    #[derive(Debug, Clone, Default)]
    struct MemoryStorage {
        values: Rc<RefCell<HashMap<String, Value>>>,
        fail_writes: Rc<RefCell<bool>>,
    }

    impl SettingsStorage for MemoryStorage {
        fn get(&self, key: &str) -> Result<Option<Value>, SettingsStorageError> {
            Ok(self.values.borrow().get(key).cloned())
        }

        fn set(&self, key: &str, value: Option<Value>) -> Result<(), SettingsStorageError> {
            if *self.fail_writes.borrow() {
                return Err(SettingsStorageError {
                    message: "disk full".to_owned(),
                });
            }
            let mut values = self.values.borrow_mut();
            match value {
                Some(value) => values.insert(key.to_owned(), value),
                None => values.remove(key),
            };
            Ok(())
        }
    }

    fn store(storage: &MemoryStorage) -> SettingsStore<MemoryStorage> {
        SettingsStore::load(storage.clone()).unwrap()
    }

    fn set(store: &mut SettingsStore<MemoryStorage>, url: &str) {
        store.set_server_url(Some(url.to_owned())).unwrap();
    }

    // MARK: web/ios SettingsStoreTests.swift

    #[test]
    fn a_failed_write_is_reported_when_suppressing_auto_open() {
        let storage = MemoryStorage::default();
        let mut store = store(&storage);
        set(&mut store, "https://omnigent.example.com");
        *storage.fail_writes.borrow_mut() = true;
        assert!(
            store
                .suppress_auto_opening_oidc_server("https://omnigent.example.com")
                .is_err()
        );
    }

    #[test]
    fn saved_protocol_grants_of_the_wrong_shape_are_refused() {
        let storage = MemoryStorage::default();
        storage
            .set(keys::ALLOWED_PROTOCOLS, Some(json!(5)))
            .unwrap();
        let settings = SettingsStore::load(storage).unwrap();
        assert!(settings.is_protocol_allowed("mailto", "https://x").is_err());
    }

    #[test]
    fn errors_describe_what_was_stored_and_have_no_source_of_their_own() {
        use std::error::Error;

        let unexpected = SettingsError::UnexpectedValue {
            key: "k".to_owned(),
            expected: "a string",
        };
        assert_eq!(unexpected.to_string(), "stored setting k is not a string");
        assert!(unexpected.source().is_none());
        assert_eq!(
            SettingsError::ImportNotAnObject.to_string(),
            "the settings to import are not a JSON object"
        );
        assert!(SettingsError::ImportNotAnObject.source().is_none());
    }

    #[test]
    fn an_import_reports_wrong_shapes_and_nulls_change_nothing() {
        let storage = MemoryStorage::default();
        let mut store = store(&storage);
        assert_eq!(store.storage().get("nothing"), Ok(None));
        assert_eq!(
            store.import_electron_settings(&json!(7)),
            Err(SettingsError::ImportNotAnObject)
        );
        let report = store
            .import_electron_settings(&json!({"server_url": null, "recent_servers": null}))
            .unwrap();
        assert_eq!(report, ElectronImportReport::default());
        let report = store
            .import_electron_settings(&json!({"server_url": 7}))
            .unwrap();
        assert_eq!(report.skipped[0].reason, SkipReason::NotAString);
        assert_eq!(report.skipped[0].value, "7");
    }

    #[test]
    fn a_failed_write_during_an_import_keeps_the_old_recents() {
        let storage = MemoryStorage::default();
        let mut store = store(&storage);
        *storage.fail_writes.borrow_mut() = true;
        assert!(
            store
                .import_electron_settings(&json!({"recent_servers": ["http://a"]}))
                .is_err()
        );
        assert_eq!(store.recent_servers().len(), 0);
    }

    #[test]
    fn settings_recent_servers_deduped_capped() {
        let mut store = store(&MemoryStorage::default());
        for host in ["a", "b", "c", "d", "e", "f", "c"] {
            store
                .remember_recent_server(&format!("https://{host}.example.com"))
                .unwrap();
        }
        assert_eq!(store.recent_servers().len(), MAX_RECENT_SERVERS);
        assert_eq!(
            store.recent_servers().first().map(String::as_str),
            Some("https://c.example.com")
        );
        assert!(
            !store
                .recent_servers()
                .contains(&"https://a.example.com".to_owned())
        );
    }

    #[test]
    fn settings_protocol_grant_scoped_by_origin() {
        let storage = MemoryStorage::default();
        let mut store = store(&storage);
        store
            .allow_protocol("vscode", "https://one.example.com")
            .unwrap();
        assert!(
            store
                .is_protocol_allowed("vscode", "https://one.example.com")
                .unwrap()
        );
        assert!(
            !store
                .is_protocol_allowed("vscode", "https://two.example.com")
                .unwrap()
        );
        // Schemes fold case and are not duplicated.
        store
            .allow_protocol("VSCode", "https://one.example.com")
            .unwrap();
        assert!(
            store
                .is_protocol_allowed("VSCODE", "https://one.example.com")
                .unwrap()
        );
        assert_eq!(
            storage.get(keys::ALLOWED_PROTOCOLS).unwrap(),
            Some(json!({"https://one.example.com": ["vscode"]}))
        );
    }

    #[test]
    fn settings_oidc_signout_stops_auto_open_for_one_server() {
        let mut store = store(&MemoryStorage::default());
        set(&mut store, "https://omnigent.example.com/omnigent");
        store
            .remember_recent_server("https://omnigent.example.com/omnigent")
            .unwrap();

        assert!(
            !store
                .stop_auto_opening_oidc_server("https://other.example.com")
                .unwrap()
        );
        assert_eq!(
            store.server_url(),
            Some("https://omnigent.example.com/omnigent")
        );

        assert!(
            store
                .stop_auto_opening_oidc_server("https://OMNIGENT.example.com/omnigent/")
                .unwrap()
        );
        assert_eq!(store.server_url(), None);
        assert_eq!(
            store.recent_servers(),
            ["https://omnigent.example.com/omnigent"]
        );
    }

    #[test]
    fn settings_oidc_signout_ipv6_origin() {
        let mut store = store(&MemoryStorage::default());
        set(&mut store, "http://[::1]:6767");
        store
            .stop_auto_opening_oidc_server("http://[::1]:6768/")
            .unwrap();
        assert_eq!(store.server_url(), Some("http://[::1]:6767"));
        store
            .stop_auto_opening_oidc_server("http://[::1]:6767/omnigent/")
            .unwrap();
        assert_eq!(store.server_url(), None);
    }

    #[test]
    fn settings_refused_server_prefilled_not_reopened() {
        let storage = MemoryStorage::default();
        let mut store = store(&storage);
        let saved = "https://omnigent.example.com/omnigent";
        set(&mut store, saved);
        assert_eq!(store.auto_open_server_url().unwrap(), Some(saved));

        assert!(
            !store
                .suppress_auto_opening_oidc_server("https://other.example.com")
                .unwrap()
        );
        assert_eq!(store.auto_open_server_url().unwrap(), Some(saved));

        assert!(
            store
                .suppress_auto_opening_oidc_server("https://omnigent.example.com/omnigent/")
                .unwrap()
        );
        assert_eq!(store.server_url(), Some(saved));
        assert_eq!(store.auto_open_server_url().unwrap(), None);
        assert_eq!(store.recent_servers(), Vec::<String>::new());
        // The suppression survives a relaunch.
        let relaunched = SettingsStore::load(storage).unwrap();
        assert_eq!(relaunched.auto_open_server_url().unwrap(), None);
        assert_eq!(relaunched.server_url(), Some(saved));

        // Reconnecting to the same server keeps it until a load succeeds.
        set(&mut store, saved);
        assert_eq!(store.auto_open_server_url().unwrap(), None);
        store.connection_succeeded().unwrap();
        assert_eq!(store.auto_open_server_url().unwrap(), Some(saved));
    }

    #[test]
    fn settings_choosing_other_server_ends_suppression() {
        let mut store = store(&MemoryStorage::default());
        set(&mut store, "https://omnigent.example.com");
        store
            .suppress_auto_opening_oidc_server("https://omnigent.example.com")
            .unwrap();
        set(&mut store, "https://other.example.com");
        assert_eq!(
            store.auto_open_server_url().unwrap(),
            Some("https://other.example.com")
        );
        set(&mut store, "https://omnigent.example.com");
        assert_eq!(
            store.auto_open_server_url().unwrap(),
            Some("https://omnigent.example.com")
        );
    }

    #[test]
    fn settings_known_server_url_matches_origin() {
        let mut store = store(&MemoryStorage::default());
        store
            .remember_recent_server("https://my-workspace.cloud.databricks.com/ml/omnigents")
            .unwrap();
        assert_eq!(
            store.known_server_url("https://my-workspace.cloud.databricks.com"),
            Some("https://my-workspace.cloud.databricks.com/ml/omnigents")
        );
    }

    #[test]
    fn settings_known_server_url_none_for_unseen() {
        let mut store = store(&MemoryStorage::default());
        store
            .remember_recent_server("https://other.example.com")
            .unwrap();
        assert_eq!(
            store.known_server_url("https://never-seen.example.com"),
            None
        );
    }

    // MARK: Additional behaviour

    #[test]
    fn known_origins_cover_saved_server_and_recents_once() {
        let mut store = store(&MemoryStorage::default());
        set(&mut store, "http://[::1]:6767/omnigent");
        for url in [
            "https://a.example.com/x",
            "not a url",
            "https://A.example.com/y",
        ] {
            store.remember_recent_server(url).unwrap();
        }
        assert_eq!(
            store.known_origins(),
            ["http://[::1]:6767", "https://a.example.com"]
        );
        // The saved server wins over recents, and IPv6 origins resolve.
        assert_eq!(
            store.known_server_url("http://[::1]:6767"),
            Some("http://[::1]:6767/omnigent")
        );
    }

    #[test]
    fn stop_auto_opening_matching_uses_host_predicate() {
        let mut store = store(&MemoryStorage::default());
        assert!(!store.stop_auto_opening_matching(|_| true).unwrap());
        set(&mut store, "https://ws.example.com/?o=1");
        assert!(
            !store
                .stop_auto_opening_matching(|saved| saved.ends_with("o=2"))
                .unwrap()
        );
        assert!(
            store
                .stop_auto_opening_matching(|saved| saved.ends_with("o=1"))
                .unwrap()
        );
        assert_eq!(store.server_url(), None);
    }

    #[test]
    fn unparseable_saved_server_matches_no_oidc_origin() {
        let mut store = store(&MemoryStorage::default());
        set(&mut store, "not a url");
        assert!(!store.stop_auto_opening_oidc_server("not a url").unwrap());
        assert!(!store.suppress_auto_opening_oidc_server("also bad").unwrap());
        assert_eq!(store.server_url(), Some("not a url"));
    }

    #[test]
    fn wrong_stored_types_are_errors_not_defaults() {
        let storage = MemoryStorage::default();
        storage
            .set(
                keys::RECENT_SERVERS,
                Some(json!(["https://a.example.com", 1])),
            )
            .unwrap();
        assert_eq!(
            SettingsStore::load(storage.clone()).unwrap_err(),
            SettingsError::UnexpectedValue {
                key: keys::RECENT_SERVERS.to_owned(),
                expected: "an array of strings"
            }
        );
        storage.set(keys::RECENT_SERVERS, None).unwrap();
        storage.set(keys::SERVER_URL, Some(json!(42))).unwrap();
        assert!(matches!(
            SettingsStore::load(storage.clone()),
            Err(SettingsError::UnexpectedValue { .. })
        ));
        storage.set(keys::SERVER_URL, None).unwrap();
        storage
            .set(
                keys::ALLOWED_PROTOCOLS,
                Some(json!({"https://a": "vscode"})),
            )
            .unwrap();
        let store = store(&storage);
        assert!(matches!(
            store.is_protocol_allowed("vscode", "https://a"),
            Err(SettingsError::UnexpectedValue { .. })
        ));
    }

    #[test]
    fn storage_failures_are_reported_and_leave_the_cache_unchanged() {
        let storage = MemoryStorage::default();
        let mut store = store(&storage);
        *storage.fail_writes.borrow_mut() = true;
        let error = store
            .set_server_url(Some("https://a.example.com".to_owned()))
            .unwrap_err();
        assert_eq!(
            error,
            SettingsError::Storage {
                key: keys::SERVER_URL.to_owned(),
                source: SettingsStorageError {
                    message: "disk full".to_owned()
                }
            }
        );
        assert_eq!(store.server_url(), None);
        assert!(
            store
                .remember_recent_server("https://a.example.com")
                .is_err()
        );
        assert_eq!(store.recent_servers(), Vec::<String>::new());
        assert!(std::error::Error::source(&error).is_some());
    }

    #[test]
    fn imports_electron_settings_without_dropping_anything_silently() {
        let mut store = store(&MemoryStorage::default());
        store
            .remember_recent_server("https://native.example.com")
            .unwrap();
        let report = store
            .import_electron_settings(&json!({
                "server_url": "http://localhost:8000/",
                "recent_servers": [
                    "http://localhost:8000/", "https://native.example.com", 7,
                    "https://b.example.com", "https://c.example.com", "https://d.example.com",
                    "https://e.example.com",
                ],
                "server_names": {"ignored": "by design"},
            }))
            .unwrap();
        assert!(report.imported_server_url);
        assert_eq!(report.imported_recent_servers, 4);
        assert_eq!(
            report.skipped,
            [
                SkippedSetting {
                    key: "recent_servers[2]".to_owned(),
                    value: "7".to_owned(),
                    reason: SkipReason::NotAString
                },
                SkippedSetting {
                    key: "recent_servers[6]".to_owned(),
                    value: "\"https://e.example.com\"".to_owned(),
                    reason: SkipReason::RecentServersFull
                },
            ]
        );
        assert_eq!(store.server_url(), Some("http://localhost:8000/"));
        assert_eq!(
            store.recent_servers(),
            [
                "https://native.example.com",
                "http://localhost:8000/",
                "https://b.example.com",
                "https://c.example.com",
                "https://d.example.com",
            ]
        );

        // A second import keeps the saved server.
        let again = store
            .import_electron_settings(
                &json!({"server_url": "https://x.example.com", "recent_servers": "bad"}),
            )
            .unwrap();
        assert!(!again.imported_server_url);
        assert_eq!(
            again.skipped.iter().map(|s| s.reason).collect::<Vec<_>>(),
            [SkipReason::AlreadySet, SkipReason::NotAnArray]
        );
        assert_eq!(
            store.import_electron_settings(&json!([])),
            Err(SettingsError::ImportNotAnObject)
        );
    }
}
