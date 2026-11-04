//! Harness setup over REST: the catalog, installs and credential writes.

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::test_support::{RouteTransport, body_json, connected, path_of};
use crate::harness_setup::{CredentialInput, HarnessAvailability};

const HOSTS: &str = r#"{"hosts":[
  {"host_id":"off","name":"Old","status":"offline","configured_harnesses":null},
  {"host_id":"h1","name":"Mac","status":"online",
   "configured_harnesses":{"codex-native":"binary-missing"}}]}"#;

#[test]
fn catalog_reads_features_steps_and_hosts_online_first() {
    let core = connected(RouteTransport::local());
    core.transport()
        .ok(
            "/v1/info",
            r#"{"single_user":true,"features":{"harness_install":true},
                "installable_harnesses":["codex-native"]}"#,
        )
        .ok(
            "/v1/harnesses",
            r#"{"data":[{"id":"codex-native","label":"Codex","setup_steps":[]}]}"#,
        )
        .ok("/v1/hosts", HOSTS);
    let catalog = block_on(core.harness_setup_catalog()).unwrap();
    assert!(catalog.features.harness_install);
    assert_eq!(catalog.definition("codex-native").unwrap().label, "Codex");
    assert_eq!(catalog.hosts[0].host_id, "h1");
    assert_eq!(
        catalog.host("h1").unwrap().availability("codex-native"),
        Some(&HarnessAvailability::BinaryMissing)
    );

    // An older server: no features, no /v1/harnesses.
    let older = connected(RouteTransport::local());
    older.transport().ok("/v1/hosts", HOSTS);
    let catalog = block_on(older.harness_setup_catalog()).unwrap();
    assert!(!catalog.features.harness_install && catalog.harnesses.is_empty());
}

#[test]
fn install_and_credential_return_refreshed_readiness() {
    let core = connected(RouteTransport::local());
    core.transport()
        .ok(
            "/v1/hosts/h1/harnesses/codex-native/install",
            r#"{"configured_harnesses":{"codex-native":"needs-auth"}}"#,
        )
        .ok(
            "/v1/hosts/h1/harnesses/codex-native/credential",
            r#"{"configured_harnesses":{"codex-native":true}}"#,
        );
    let installed = block_on(core.install_harness("h1", "codex-native")).unwrap();
    assert_eq!(
        installed.get("codex-native"),
        Some(&HarnessAvailability::NeedsAuth)
    );
    let input = CredentialInput::Key {
        secret: "sk-1".into(),
    };
    let ready = block_on(core.store_harness_credential("h1", "codex-native", &input)).unwrap();
    assert_eq!(ready.get("codex-native"), Some(&HarnessAvailability::Ready));
    let writes = core.transport().writes();
    assert_eq!(
        writes.iter().map(path_of).collect::<Vec<_>>(),
        [
            "/v1/hosts/h1/harnesses/codex-native/install",
            "/v1/hosts/h1/harnesses/codex-native/credential"
        ]
    );
    assert_eq!(
        body_json(&writes[1]),
        json!({"kind": "key", "secret": "sk-1"})
    );
}

#[test]
fn invalid_input_sends_nothing() {
    let core = connected(RouteTransport::local());
    let blank = CredentialInput::Key { secret: " ".into() };
    assert!(matches!(
        block_on(core.store_harness_credential("h1", "codex-native", &blank)),
        Err(SessionError::InvalidInput { .. })
    ));
    assert!(matches!(
        block_on(core.install_harness("../x", "codex-native")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
    assert_eq!(core.transport().writes().len(), 0);
}

#[test]
fn detected_credentials_are_decoded() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        "/v1/hosts/h1/credentials/detected",
        r#"{"credentials":[{"family":"openai","source":"$OPENAI_API_KEY","env_var":"OPENAI_API_KEY"}]}"#,
    );
    let detected = block_on(core.detected_credentials("h1")).unwrap();
    assert_eq!(detected[0].env_var.as_deref(), Some("OPENAI_API_KEY"));
}
