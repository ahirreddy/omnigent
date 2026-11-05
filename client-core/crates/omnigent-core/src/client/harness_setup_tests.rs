//! Harness setup over REST: the catalog, installs and credential writes.

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::test_support::{Reply, RouteTransport, body_json, connected, path_of};
use crate::harness_accounts::{LoginStartOutcome, LoginState, StartupRead};
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

#[test]
fn device_login_starts_polls_and_cancels_on_the_account_key() {
    let core = connected(RouteTransport::local());
    core.transport()
        .ok(
            "/v1/hosts/h1/harnesses/codex/login",
            r#"{"login_id":"l1","verification_url":"https://auth.openai.com/device",
                "user_code":"AB-12","expires_at":1700000000}"#,
        )
        .ok(
            "/v1/hosts/h1/harnesses/codex/login/l1",
            r#"{"status":"succeeded","error":null,"expired":false,
                "configured_harnesses":{"codex-native":true}}"#,
        );
    let LoginStartOutcome::Started(start) =
        block_on(core.start_harness_login("h1", "codex-native")).unwrap()
    else {
        panic!("expected a new sign-in");
    };
    assert_eq!(start.user_code, "AB-12");
    let status = block_on(core.harness_login_status("h1", "native-codex", "l1")).unwrap();
    assert_eq!(status.state, LoginState::Succeeded);
    assert!(status.snapshot.is_ready("codex-native"));
    block_on(core.cancel_harness_login("h1", "codex-native", "l1")).unwrap();
    let writes = core.transport().writes();
    assert_eq!(writes[1].method, "DELETE");
    assert_eq!(path_of(&writes[1]), "/v1/hosts/h1/harnesses/codex/login/l1");
}

#[test]
fn a_busy_login_resumes_and_an_unsupported_one_is_rejected() {
    let core = connected(RouteTransport::local());
    core.transport().respond(
        None,
        "/v1/hosts/h1/harnesses/codex/login",
        None,
        Reply::json(409, r#"{"code":"login_busy","login_id":"l9"}"#),
    );
    assert_eq!(
        block_on(core.start_harness_login("h1", "codex-native")).unwrap(),
        LoginStartOutcome::Busy {
            login_id: "l9".into()
        }
    );
    core.transport().respond(
        None,
        "/v1/hosts/h1/harnesses/codex/login",
        None,
        Reply::json(
            409,
            r#"{"error":{"code":"login_unsupported","message":"no harness login here"}}"#,
        ),
    );
    assert_eq!(
        block_on(core.start_harness_login("h1", "codex-native")),
        Err(SessionError::Rejected {
            status: 409,
            message: "no harness login here".into()
        })
    );
}

#[test]
fn sign_out_returns_the_refreshed_accounts() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        "/v1/hosts/h1/harnesses/claude/logout",
        r#"{"configured_harnesses":{"claude-native":"needs-auth"},"harness_accounts":null}"#,
    );
    let snapshot = block_on(core.sign_out_harness("h1", "claude-native")).unwrap();
    assert_eq!(
        snapshot.harnesses.unwrap().get("claude-native"),
        Some(&HarnessAvailability::NeedsAuth)
    );
    assert_eq!(snapshot.accounts, None);
}

#[test]
fn refresh_falls_back_to_the_last_reported_readiness() {
    let core = connected(RouteTransport::local());
    core.transport()
        .respond(
            None,
            "/v1/hosts/h1/harnesses/refresh",
            None,
            Reply::json(409, r#"{"error":{"code":"refresh_unsupported"}}"#),
        )
        .ok(
            "/v1/hosts/h1",
            r#"{"host_id":"h1","configured_harnesses":{"codex-native":true}}"#,
        );
    let snapshot = block_on(core.refresh_harnesses("h1")).unwrap();
    assert!(snapshot.is_ready("codex-native"));
}

#[test]
fn install_reports_the_version_and_startup_reads_or_is_absent() {
    let core = connected(RouteTransport::local());
    core.transport()
        .ok(
            "/v1/hosts/h1/harnesses/codex-native/install",
            r#"{"configured_harnesses":{"codex-native":true},"version":"0.50.0",
                "gateway_inference":{"codex-native":false}}"#,
        )
        .ok(
            "/v1/hosts/h1/harnesses/claude-native/startup",
            r#"{"command":"claude","resolved_path":null,"command_source":"default","arg_count":0}"#,
        )
        .respond(
            None,
            "/v1/hosts/h1/harnesses/pi-native/startup",
            None,
            Reply::json(404, "{}"),
        );
    let outcome = block_on(core.install_harness_reporting("h1", "codex-native")).unwrap();
    assert_eq!(outcome.version.as_deref(), Some("0.50.0"));
    assert!(outcome.snapshot.is_ready("codex-native"));
    let StartupRead::Loaded(startup) =
        block_on(core.harness_startup("h1", "claude-native", "Mac")).unwrap()
    else {
        panic!("expected a startup command");
    };
    assert_eq!(startup.source, "Default command on Mac.");
    assert_eq!(
        block_on(core.harness_startup("h1", "pi-native", "Mac")).unwrap(),
        StartupRead::NotReported
    );
}
