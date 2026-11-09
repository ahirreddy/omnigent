//! Saved settings and managed preferences over host storage that can fail.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use omnigent_core::config::settings::keys;

use crate::config::{ManagedPreferences, SettingsStore, SkippedSetting};
use crate::errors::CoreError;
use crate::host::{ManagedPreferenceSource, SettingsStorage, SettingsStorageError};

const SERVER: &str = "https://omnigent.example.com";

#[derive(Default)]
struct FlakyStorage {
    values: Mutex<HashMap<String, String>>,
    failing: AtomicBool,
}

impl FlakyStorage {
    fn check(&self) -> Result<(), SettingsStorageError> {
        if self.failing.load(Ordering::SeqCst) {
            return Err(SettingsStorageError::Failed {
                message: "disk full".into(),
            });
        }
        Ok(())
    }
}

impl SettingsStorage for FlakyStorage {
    fn get(&self, key: String) -> Result<Option<String>, SettingsStorageError> {
        self.check()?;
        Ok(self.values.lock().unwrap().get(&key).cloned())
    }

    fn set(&self, key: String, value: Option<String>) -> Result<(), SettingsStorageError> {
        self.check()?;
        match value {
            Some(value) => self.values.lock().unwrap().insert(key, value),
            None => self.values.lock().unwrap().remove(&key),
        };
        Ok(())
    }
}

fn store() -> (Arc<FlakyStorage>, Arc<SettingsStore>) {
    let storage = Arc::new(FlakyStorage::default());
    let store = SettingsStore::load(storage.clone()).unwrap();
    (storage, store)
}

#[test]
fn auto_open_follows_a_refusal_until_the_next_connection() {
    let (storage, store) = store();
    assert_eq!(store.auto_open_server_url().unwrap(), None);
    store.set_server_url(Some(SERVER.into())).unwrap();
    assert_eq!(
        store.auto_open_server_url().unwrap().as_deref(),
        Some(SERVER)
    );

    assert!(
        !store
            .suppress_auto_opening_oidc_server("https://other.example.com".into())
            .unwrap()
    );
    assert!(
        store
            .suppress_auto_opening_oidc_server(SERVER.into())
            .unwrap()
    );
    assert_eq!(store.auto_open_server_url().unwrap(), None);
    assert_eq!(
        store.server_url().as_deref(),
        Some(SERVER),
        "kept as the prefill"
    );
    assert!(
        storage
            .values
            .lock()
            .unwrap()
            .contains_key(keys::AUTO_OPEN_SUPPRESSED_SERVER)
    );

    store.connection_succeeded().unwrap();
    assert_eq!(
        store.auto_open_server_url().unwrap().as_deref(),
        Some(SERVER)
    );

    assert!(store.stop_auto_opening_oidc_server(SERVER.into()).unwrap());
    assert_eq!(store.auto_open_server_url().unwrap(), None);
}

#[test]
fn known_servers_and_protocol_grants_read_what_was_saved() {
    let (_, store) = store();
    store
        .set_server_url(Some(format!("{SERVER}/mount")))
        .unwrap();
    store
        .remember_recent_server("https://b.example.com/x".into())
        .unwrap();
    assert_eq!(
        store.known_server_url(SERVER.into()).as_deref(),
        Some("https://omnigent.example.com/mount")
    );
    assert_eq!(
        store
            .known_server_url("https://b.example.com".into())
            .as_deref(),
        Some("https://b.example.com/x")
    );
    assert_eq!(
        store.known_server_url("https://none.example.com".into()),
        None
    );
    assert_eq!(store.known_origins(), [SERVER, "https://b.example.com"]);

    assert!(
        !store
            .is_protocol_allowed("vscode".into(), SERVER.into())
            .unwrap()
    );
    store
        .allow_protocol("VSCode".into(), SERVER.into())
        .unwrap();
    assert!(
        store
            .is_protocol_allowed("vscode".into(), SERVER.into())
            .unwrap()
    );
    assert!(
        !store
            .is_protocol_allowed("vscode".into(), "https://b.example.com".into())
            .unwrap()
    );
}

#[test]
fn an_electron_import_reports_what_it_took_and_skipped() {
    let (_, store) = store();
    let report = store
        .import_electron_settings(
            r#"{"server_url":"https://a.example.com",
                "recent_servers":["https://b.example.com",7,"https://c.example.com"]}"#
                .into(),
        )
        .unwrap();
    assert!(report.imported_server_url);
    assert_eq!(report.imported_recent_servers, 2);
    assert_eq!(
        report.skipped,
        [SkippedSetting {
            key: "recent_servers[1]".into(),
            value: "7".into(),
            reason: "NotAString".into(),
        }]
    );
    assert_eq!(store.server_url().as_deref(), Some("https://a.example.com"));

    assert!(matches!(
        store.import_electron_settings("{nope".into()),
        Err(CoreError::Decode { .. })
    ));
    assert!(matches!(
        store.import_electron_settings("[]".into()),
        Err(CoreError::Settings { .. })
    ));
}

#[test]
fn a_failing_store_reports_each_write_and_read() {
    let (storage, store) = store();
    store.set_server_url(Some(SERVER.into())).unwrap();
    storage.failing.store(true, Ordering::SeqCst);

    let settings_error = |result: Result<(), CoreError>| {
        let Err(CoreError::Settings { message }) = result else {
            panic!("not a settings error: {result:?}");
        };
        assert!(message.contains("disk full"), "{message}");
    };
    settings_error(store.set_server_url(None));
    settings_error(store.remember_recent_server("https://x.example.com".into()));
    settings_error(store.connection_succeeded());
    settings_error(store.allow_protocol("vscode".into(), SERVER.into()));
    settings_error(store.auto_open_server_url().map(|_| ()));
    settings_error(
        store
            .is_protocol_allowed("vscode".into(), SERVER.into())
            .map(|_| ()),
    );
    settings_error(
        store
            .stop_auto_opening_oidc_server(SERVER.into())
            .map(|_| ()),
    );
    settings_error(
        store
            .suppress_auto_opening_oidc_server(SERVER.into())
            .map(|_| ()),
    );
    settings_error(
        store
            .import_electron_settings(r#"{"recent_servers":["https://y.example.com"]}"#.into())
            .map(|_| ()),
    );
    settings_error(SettingsStore::load(storage).map(|_| ()));
}

struct Preferences {
    values: HashMap<(String, String), String>,
    forced: bool,
}

impl ManagedPreferenceSource for Preferences {
    fn value(&self, key: String, domain: String) -> Option<String> {
        self.values.get(&(key, domain)).cloned()
    }

    fn is_forced(&self, _key: String, _domain: String) -> bool {
        self.forced
    }
}

#[test]
fn managed_preferences_read_the_winning_domain_and_each_server_field() {
    let source = Preferences {
        values: HashMap::from([
            (
                ("serverUrls".to_owned(), "ai.omnigent.mac".to_owned()),
                r#"["https://corp.example.com:8443/x?omnigentServerName=Corp"]"#.to_owned(),
            ),
            (
                (
                    "databricksInternalFeaturesEnabled".to_owned(),
                    "ai.omnigent.mac".to_owned(),
                ),
                "true".to_owned(),
            ),
        ]),
        forced: true,
    };
    let preferences = ManagedPreferences::desktop(Some("my.app".into()), Arc::new(source));
    assert_eq!(
        preferences.domains(),
        ["my.app", "ai.omnigent.mac", "ai.omnigent.desktop"]
    );
    let servers = preferences.servers().unwrap();
    assert_eq!(servers.servers_domain.as_deref(), Some("ai.omnigent.mac"));
    assert!(servers.servers_are_forced);
    let server = &servers.servers[0];
    assert_eq!(server.url, "https://corp.example.com:8443/x");
    assert_eq!(server.name.as_deref(), Some("Corp"));
    assert_eq!(server.origin, "https://corp.example.com:8443");
    assert_eq!(server.authority, "corp.example.com:8443");
    assert_eq!(server.display_name, "Corp");
    assert!(preferences.databricks_internal_features_enabled().unwrap());
    assert!(format!("{preferences:?}").contains("ai.omnigent.desktop"));
}

#[test]
fn a_wrong_managed_value_is_a_managed_config_error_with_its_domain() {
    let source = Preferences {
        values: HashMap::from([(
            ("serverUrls".to_owned(), "d".to_owned()),
            r#""not a list""#.to_owned(),
        )]),
        forced: false,
    };
    let preferences = ManagedPreferences::new(vec!["d".into()], Arc::new(source));
    let Err(CoreError::ManagedConfig { domain, .. }) = preferences.servers() else {
        panic!("not a managed config error");
    };
    assert_eq!(domain.as_deref(), Some("d"));
}

#[test]
fn stores_print_their_name_only() {
    let (_, store) = store();
    assert_eq!(format!("{store:?}"), "SettingsStore");
}
