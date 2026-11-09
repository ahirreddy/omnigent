//! Harness setup and account fixes over the fake host: every conversion arm, both directions,
//! and each export's request.

#![allow(
    clippy::too_many_lines,
    reason = "catalogs and plans are asserted field by field"
)]

use omnigent_core::harness_accounts as core_accounts;
use omnigent_core::harness_setup as core_setup;
use serde_json::json;

use crate::harness_accounts::{
    GatewayInferenceEntry, HarnessAccount, HarnessAccountEntry, HarnessAccountProvider,
    HarnessCredentialAction, HarnessFixMode, HarnessHostSnapshot, HarnessLoginStartOutcome,
    HarnessLoginState, HarnessStartupRead, HarnessStartupVariable, harness_detail,
    harness_personal_login_command, harness_setup_catalog_applying_snapshot,
    harness_snapshot_is_ready, host_id_from_cli_config,
};
use crate::harness_setup::{
    DetectedCredential, HarnessAvailability, HarnessAvailabilityEntry, HarnessCredentialInput,
    HarnessDefinition, HarnessSetupCatalog, SetupHost, SetupStep, SetupStepControl,
    SetupStepStatus, adoptable_harness_credential, harness_inventory,
    harness_setup_catalog_applying, harness_setup_plan,
};
use crate::test_support::{connected, json as reply};

fn ready_entry(harness: &str, availability: HarnessAvailability) -> HarnessAvailabilityEntry {
    HarnessAvailabilityEntry {
        harness: harness.into(),
        availability,
    }
}

fn step(kind: &str, action: &str, command: Option<&str>) -> SetupStep {
    SetupStep {
        kind: kind.into(),
        title: format!("{kind} title"),
        detail: format!("{kind} detail"),
        action: action.into(),
        command: command.map(str::to_owned),
        status_key: Some(
            if kind == "install" {
                "installed"
            } else {
                "authed"
            }
            .to_owned(),
        ),
    }
}

fn catalog(harnesses: Vec<HarnessAvailabilityEntry>) -> HarnessSetupCatalog {
    HarnessSetupCatalog {
        harness_install: true,
        installable_harnesses: vec!["codex-native".into(), "claude-native".into()],
        harnesses: vec![HarnessDefinition {
            id: "claude-native".into(),
            label: "Claude Label".into(),
            setup_steps: vec![
                step("install", "install", None),
                step("auth", "command", Some("claude setup-token")),
            ],
        }],
        hosts: vec![SetupHost {
            host_id: "h1".into(),
            name: "Mac".into(),
            status: "online".into(),
            sandbox_provider: None,
            harnesses: Some(harnesses),
            accounts: Some(vec![HarnessAccountEntry {
                key: "codex".into(),
                account: HarnessAccount {
                    kind: "chatgpt".into(),
                    email: Some("a@b.co".into()),
                    org: Some("Org".into()),
                    plan: Some("pro".into()),
                    providers: vec![HarnessAccountProvider {
                        id: "p".into(),
                        label: "Provider".into(),
                        auth_type: "oauth".into(),
                    }],
                    expired: true,
                    identity: None,
                },
            }]),
            gateway_inference: Some(vec![GatewayInferenceEntry {
                harness: "claude-native".into(),
                enabled: true,
            }]),
            login_supported: true,
        }],
    }
}

#[test]
fn availability_round_trips_through_every_arm() {
    for (ffi, core) in [
        (
            HarnessAvailability::Ready,
            core_setup::HarnessAvailability::Ready,
        ),
        (
            HarnessAvailability::NeedsAuth,
            core_setup::HarnessAvailability::NeedsAuth,
        ),
        (
            HarnessAvailability::BinaryMissing,
            core_setup::HarnessAvailability::BinaryMissing,
        ),
        (
            HarnessAvailability::VersionTooLow,
            core_setup::HarnessAvailability::VersionTooLow,
        ),
        (
            HarnessAvailability::NotConfigured,
            core_setup::HarnessAvailability::NotConfigured,
        ),
        (
            HarnessAvailability::TmuxUnavailable,
            core_setup::HarnessAvailability::TmuxUnavailable,
        ),
        (
            HarnessAvailability::Other {
                value: "\"odd\"".into(),
            },
            core_setup::HarnessAvailability::Other("\"odd\"".into()),
        ),
    ] {
        assert_eq!(HarnessAvailability::from(core.clone()), ffi);
        assert_eq!(core_setup::HarnessAvailability::from(ffi), core);
    }
}

#[test]
fn a_catalog_round_trips_every_field_to_the_core_and_back() {
    let original = catalog(vec![ready_entry(
        "codex-native",
        HarnessAvailability::Ready,
    )]);
    let core = core_setup::HarnessSetupCatalog::from(original.clone());
    assert!(core.features.harness_install);
    assert_eq!(core.features.installable_harnesses[1], "claude-native");
    let definition = core.definition("claude-native").unwrap();
    assert_eq!(definition.label, "Claude Label");
    assert_eq!(definition.setup_steps[1].kind, "auth");
    assert_eq!(definition.setup_steps[1].action, "command");
    assert_eq!(
        definition.setup_steps[1].command.as_deref(),
        Some("claude setup-token")
    );
    let host = core.host("h1").unwrap();
    assert_eq!(host.name, "Mac");
    assert!(host.login_supported);
    assert_eq!(host.gateway("claude-native"), Some(true));
    assert_eq!(
        host.account("codex-native").unwrap().plan.as_deref(),
        Some("pro")
    );

    let mut back = HarnessSetupCatalog::from(core);
    // Back from the core the identity is computed, where the record built here had none.
    let account = &mut back.hosts[0].accounts.as_mut().unwrap()[0].account;
    assert_eq!(account.identity.as_deref(), Some("a@b.co \u{b7} pro"));
    account.identity = None;
    assert_eq!(back, original);
}

#[test]
fn a_plan_names_the_definition_host_and_each_steps_status_and_control() {
    let plan = harness_setup_plan(
        catalog(vec![ready_entry(
            "claude-native",
            HarnessAvailability::NeedsAuth,
        )]),
        "claude-native".into(),
        "h1".into(),
    );
    assert_eq!(plan.harness, "claude-native");
    assert_eq!(plan.label, "Claude Label");
    assert_eq!(plan.host_name.as_deref(), Some("Mac"));
    assert!(!plan.all_done);
    assert!(!plan.needs_omni_setup);
    assert_eq!(plan.steps.len(), 2);
    assert_eq!(plan.steps[0].kind, "install");
    assert_eq!(plan.steps[0].title, "install title");
    assert_eq!(plan.steps[0].status, SetupStepStatus::Done);
    assert_eq!(plan.steps[0].control, SetupStepControl::None);
    assert_eq!(plan.steps[1].status, SetupStepStatus::Todo);
    assert_eq!(
        plan.steps[1].control,
        SetupStepControl::Credential { enabled: true }
    );
    assert_eq!(plan.steps[1].command.as_deref(), Some("claude setup-token"));

    let missing = harness_setup_plan(
        catalog(vec![ready_entry(
            "claude-native",
            HarnessAvailability::BinaryMissing,
        )]),
        "claude-native".into(),
        "h1".into(),
    );
    assert_eq!(missing.steps[0].control, SetupStepControl::Install);
    assert_eq!(
        missing.steps[1].control,
        SetupStepControl::Credential { enabled: false }
    );

    let mut unreported = catalog(vec![]);
    unreported.hosts[0].harnesses = None;
    let plan = harness_setup_plan(unreported, "claude-native".into(), "h1".into());
    assert_eq!(plan.steps[0].status, SetupStepStatus::Unknown);

    // A step the sheet can only hand over as a command, on a server that cannot install.
    let mut read_only = catalog(vec![ready_entry(
        "goose-native",
        HarnessAvailability::BinaryMissing,
    )]);
    read_only.harness_install = false;
    read_only.harnesses[0].id = "goose-native".into();
    read_only.harnesses[0].setup_steps = vec![step("other", "command", Some("goose configure"))];
    let plan = harness_setup_plan(read_only, "goose-native".into(), "h1".into());
    assert_eq!(
        plan.steps[0].control,
        SetupStepControl::Command {
            command: "goose configure".into()
        }
    );

    // An unknown harness on an unknown host falls back to its built-in label and no host.
    let plan = harness_setup_plan(catalog(vec![]), "codex-native".into(), "nope".into());
    assert_eq!(plan.label, "Codex");
    assert_eq!(plan.host_name, None);
}

#[test]
fn applying_readiness_changes_only_the_named_host() {
    let entries = vec![ready_entry("codex-native", HarnessAvailability::Ready)];
    let original = catalog(vec![]);
    let applied = harness_setup_catalog_applying(original.clone(), "h1".into(), entries.clone());
    assert_eq!(applied.hosts[0].harnesses.as_ref(), Some(&entries));
    assert_eq!(
        harness_setup_catalog_applying(original.clone(), "other".into(), entries),
        original
    );
}

#[test]
fn the_inventory_marks_each_harness_on_its_host() {
    let rows = harness_inventory(
        catalog(vec![
            ready_entry("codex-native", HarnessAvailability::Ready),
            ready_entry("claude-native", HarnessAvailability::NeedsAuth),
        ]),
        "h1".into(),
    );
    let codex = rows
        .iter()
        .find(|row| row.harness == "codex-native")
        .unwrap();
    assert_eq!(codex.name, "Codex");
    assert_ne!(codex.description, "");
    assert!(codex.ready);
    assert!(!codex.needs_setup);
    assert!(codex.status.as_deref().unwrap().starts_with("Configured"));
    let claude = rows
        .iter()
        .find(|row| row.harness == "claude-native")
        .unwrap();
    assert!(!claude.ready);
    assert!(claude.needs_setup);

    let neutral = harness_inventory(catalog(vec![]), "unknown".into());
    assert_eq!(
        neutral.len(),
        rows.len(),
        "every harness, even with no host"
    );
    assert!(neutral.iter().all(|row| row.status.is_none()));
}

#[test]
fn only_a_credential_of_the_harness_family_can_be_adopted() {
    let openai = DetectedCredential {
        family: "openai".into(),
        source: "$OPENAI_API_KEY".into(),
        env_var: Some("OPENAI_API_KEY".into()),
    };
    let anthropic = DetectedCredential {
        family: "anthropic".into(),
        source: "$ANTHROPIC_API_KEY".into(),
        env_var: Some("ANTHROPIC_API_KEY".into()),
    };
    assert_eq!(
        adoptable_harness_credential(
            "codex-native".into(),
            vec![anthropic.clone(), openai.clone()]
        ),
        Some(openai)
    );
    assert_eq!(
        adoptable_harness_credential("codex-native".into(), vec![anthropic]),
        None
    );
}

#[test]
fn the_catalog_reads_info_harnesses_and_hosts() {
    let mut harness = connected();
    harness.http.route(
        "/v1/info",
        reply(
            200,
            r#"{"single_user":true,"features":{"harness_install":true},
                "installable_harnesses":["codex-native"]}"#,
        ),
    );
    harness.http.route(
        "/v1/harnesses",
        reply(
            200,
            r#"{"data":[{"id":"codex-native","label":"Codex","setup_steps":[
                {"kind":"auth","title":"T","detail":"D","action":"command","command":"codex login","status_key":"K"}]}]}"#,
        ),
    );
    harness.http.route(
        "/v1/hosts",
        reply(
            200,
            r#"{"hosts":[{"host_id":"h1","name":"Mac","status":"online","sandbox_provider":"modal",
                "configured_harnesses":{"codex-native":"binary-missing"},
                "harness_login_supported":true}]}"#,
        ),
    );
    let catalog = harness
        .call(|core| async move { core.harness_setup_catalog().await })
        .unwrap();
    assert!(catalog.harness_install);
    assert_eq!(catalog.installable_harnesses, ["codex-native"]);
    let step = &catalog.harnesses[0].setup_steps[0];
    assert_eq!(
        (
            step.kind.as_str(),
            step.title.as_str(),
            step.detail.as_str(),
            step.action.as_str()
        ),
        ("auth", "T", "D", "command")
    );
    assert_eq!(step.command.as_deref(), Some("codex login"));
    assert_eq!(step.status_key.as_deref(), Some("K"));
    let host = &catalog.hosts[0];
    assert_eq!(host.sandbox_provider.as_deref(), Some("modal"));
    assert!(host.login_supported);
    assert_eq!(
        host.harnesses.as_deref(),
        Some(
            &[ready_entry(
                "codex-native",
                HarnessAvailability::BinaryMissing
            )][..]
        )
    );
}

#[test]
fn install_and_each_credential_kind_post_to_the_harness_and_answer_readiness() {
    let mut harness = connected();
    let install = "/v1/hosts/h1/harnesses/codex-native/install";
    let credential = "/v1/hosts/h1/harnesses/codex-native/credential";
    harness.http.route(
        install,
        reply(
            200,
            r#"{"configured_harnesses":{"codex-native":"needs-auth"},"version":"0.5"}"#,
        ),
    );
    harness.http.route(
        credential,
        reply(200, r#"{"configured_harnesses":{"codex-native":true}}"#),
    );
    let installed = harness
        .call(|core| async move {
            core.install_harness("h1".into(), "codex-native".into())
                .await
        })
        .unwrap();
    assert_eq!(
        installed,
        [ready_entry("codex-native", HarnessAvailability::NeedsAuth)]
    );
    assert_eq!(harness.last_request().0, format!("POST {install}"));

    let outcome = harness
        .call(|core| async move {
            core.install_harness_reporting("h1".into(), "codex-native".into())
                .await
        })
        .unwrap();
    assert_eq!(outcome.version.as_deref(), Some("0.5"));
    assert_eq!(
        outcome.snapshot.harnesses,
        Some(vec![ready_entry(
            "codex-native",
            HarnessAvailability::NeedsAuth
        )])
    );

    for (input, body) in [
        (
            HarnessCredentialInput::Key {
                secret: "sk-1".into(),
            },
            json!({"kind": "key", "secret": "sk-1"}),
        ),
        (
            HarnessCredentialInput::Gateway {
                base_url: "https://gw.example".into(),
                secret: "sk-2".into(),
            },
            json!({"kind": "gateway", "base_url": "https://gw.example", "secret": "sk-2"}),
        ),
        (
            HarnessCredentialInput::Adopt {
                env_var: "OPENAI_API_KEY".into(),
            },
            json!({"kind": "adopt", "env_var": "OPENAI_API_KEY"}),
        ),
    ] {
        let ready = harness
            .call(|core| async move {
                core.store_harness_credential("h1".into(), "codex-native".into(), input)
                    .await
            })
            .unwrap();
        assert_eq!(
            ready,
            [ready_entry("codex-native", HarnessAvailability::Ready)]
        );
        assert_eq!(harness.last_request(), (format!("POST {credential}"), body));
    }
}

#[test]
fn detected_credentials_map_each_field() {
    let mut harness = connected();
    harness.http.route(
        "/v1/hosts/h1/credentials/detected",
        reply(
            200,
            r#"{"credentials":[{"family":"openai","source":"shell","env_var":"OPENAI_API_KEY"}]}"#,
        ),
    );
    let detected = harness
        .call(|core| async move { core.detected_credentials("h1".into()).await })
        .unwrap();
    assert_eq!(
        detected,
        [DetectedCredential {
            family: "openai".into(),
            source: "shell".into(),
            env_var: Some("OPENAI_API_KEY".into()),
        }]
    );
}

#[test]
fn details_carry_the_host_account_and_login_command() {
    let mut expired = catalog(vec![ready_entry(
        "codex-native",
        HarnessAvailability::NeedsAuth,
    )]);
    expired.harnesses[0].id = "codex-native".into();
    let detail = harness_detail(
        expired.clone(),
        "codex-native".into(),
        "Codex".into(),
        "h1".into(),
    )
    .unwrap();
    assert_eq!(detail.harness, "codex-native");
    assert_eq!(detail.name, "Codex");
    assert_eq!(detail.host_name, "Mac");
    assert!(!detail.ready);
    assert!(detail.can_fix);
    assert_eq!(detail.mode, HarnessFixMode::Reconfigure);
    assert_eq!(detail.credential_label, "Sign-in expired");
    assert!(detail.credential_description.starts_with("a@b.co"));
    assert!(detail.credential_warning);
    assert_eq!(
        detail.credential_action,
        Some(HarnessCredentialAction::SignInAgain)
    );
    let account = detail.account.unwrap();
    assert_eq!(account.kind, "chatgpt");
    assert_eq!(account.org.as_deref(), Some("Org"));
    assert_eq!(account.providers[0].label, "Provider");
    assert_eq!(account.providers[0].auth_type, "oauth");
    assert!(account.expired);
    assert!(detail.supports_device_login);
    assert_eq!(
        detail.personal_login_command.as_deref(),
        Some("codex login --device-auth")
    );

    assert_eq!(
        harness_detail(
            expired.clone(),
            "codex-native".into(),
            "Codex".into(),
            "other".into()
        ),
        None,
        "an unknown host has no details"
    );

    // A live subscription offers switching; an outdated one warns with the update.
    let mut live = expired.clone();
    live.hosts[0].harnesses = Some(vec![ready_entry(
        "codex-native",
        HarnessAvailability::Ready,
    )]);
    live.hosts[0].accounts.as_mut().unwrap()[0].account.expired = false;
    let detail = harness_detail(live, "codex-native".into(), "Codex".into(), "h1".into()).unwrap();
    assert!(detail.ready);
    assert_eq!(
        detail.credential_action,
        Some(HarnessCredentialAction::SwitchAccount)
    );

    let mut outdated = expired.clone();
    outdated.hosts[0].harnesses = Some(vec![ready_entry(
        "codex-native",
        HarnessAvailability::VersionTooLow,
    )]);
    let detail =
        harness_detail(outdated, "codex-native".into(), "Codex".into(), "h1".into()).unwrap();
    let warning = detail.warning.unwrap();
    assert_eq!(warning.action_label, "Update");
    assert_eq!(warning.mode, HarnessFixMode::Update);
    assert!(warning.message.contains("out of date on Mac"));

    let mut signed_out = expired;
    signed_out.hosts[0].accounts = None;
    signed_out.hosts[0].harnesses = Some(vec![ready_entry(
        "claude-native",
        HarnessAvailability::NeedsAuth,
    )]);
    let detail = harness_detail(
        signed_out,
        "claude-native".into(),
        "Claude".into(),
        "h1".into(),
    )
    .unwrap();
    assert_eq!(
        detail.credential_action,
        Some(HarnessCredentialAction::Reconfigure)
    );
    assert_eq!(detail.account, None);
}

#[test]
fn fix_modes_and_login_commands_map_their_harness() {
    for (core, ffi) in [
        (core_accounts::FixMode::Install, HarnessFixMode::Install),
        (core_accounts::FixMode::Update, HarnessFixMode::Update),
        (
            core_accounts::FixMode::Reconfigure,
            HarnessFixMode::Reconfigure,
        ),
        (core_accounts::FixMode::Switch, HarnessFixMode::Switch),
    ] {
        assert_eq!(HarnessFixMode::from(core), ffi);
    }
    let mut with_login = catalog(vec![]);
    // Claude's configured step is the login, with the email added when given.
    assert_eq!(
        harness_personal_login_command(
            with_login.clone(),
            "claude-native".into(),
            Some("a@b.co".into())
        )
        .as_deref(),
        Some("claude setup-token --email a@b.co")
    );
    with_login.harnesses[0].setup_steps[1].kind = "other".into();
    assert_eq!(
        harness_personal_login_command(with_login.clone(), "claude-native".into(), None).as_deref(),
        Some("claude auth login --claudeai")
    );
    assert_eq!(
        harness_personal_login_command(with_login, "goose-native".into(), None),
        None
    );
}

#[test]
fn a_snapshot_applies_to_its_host_and_reports_readiness() {
    let snapshot = HarnessHostSnapshot {
        harnesses: Some(vec![ready_entry(
            "claude-native",
            HarnessAvailability::Ready,
        )]),
        accounts: Some(vec![HarnessAccountEntry {
            key: "claude".into(),
            account: HarnessAccount {
                kind: "subscription".into(),
                email: Some("c@d.io".into()),
                org: None,
                plan: None,
                providers: vec![],
                expired: false,
                identity: None,
            },
        }]),
        gateway_inference: Some(vec![GatewayInferenceEntry {
            harness: "codex-native".into(),
            enabled: true,
        }]),
    };
    assert!(harness_snapshot_is_ready(
        snapshot.clone(),
        "claude-native".into()
    ));
    assert!(!harness_snapshot_is_ready(
        snapshot.clone(),
        "codex-native".into()
    ));

    let original = catalog(vec![]);
    let applied =
        harness_setup_catalog_applying_snapshot(original.clone(), "h1".into(), snapshot.clone());
    let host = &applied.hosts[0];
    assert_eq!(
        host.harnesses.as_deref(),
        Some(&[ready_entry("claude-native", HarnessAvailability::Ready)][..])
    );
    let accounts = host.accounts.as_ref().unwrap();
    assert_eq!(accounts[0].key, "claude");
    assert_eq!(accounts[0].account.identity.as_deref(), Some("c@d.io"));
    assert_eq!(
        host.gateway_inference.as_deref(),
        Some(
            &[GatewayInferenceEntry {
                harness: "codex-native".into(),
                enabled: true
            }][..]
        )
    );
    assert_eq!(
        harness_setup_catalog_applying_snapshot(original.clone(), "other".into(), snapshot),
        original,
        "another host's snapshot changes nothing"
    );

    let empty = HarnessHostSnapshot {
        harnesses: None,
        accounts: None,
        gateway_inference: None,
    };
    assert!(!harness_snapshot_is_ready(empty, "claude-native".into()));
}

#[test]
fn device_sign_in_starts_polls_every_state_and_cancels() {
    let mut harness = connected();
    let start = "/v1/hosts/h1/harnesses/codex/login";
    harness.http.route(
        start,
        reply(
            200,
            r#"{"login_id":"l1","verification_url":"https://auth.example/device",
                "user_code":"AB-12","expires_at":9007199254740993}"#,
        ),
    );
    let outcome = harness
        .call(|core| async move {
            core.start_harness_login("h1".into(), "codex-native".into())
                .await
        })
        .unwrap();
    let HarnessLoginStartOutcome::Started { login } = outcome else {
        panic!("expected a new sign-in: {outcome:?}");
    };
    assert_eq!(login.login_id, "l1");
    assert_eq!(login.verification_url, "https://auth.example/device");
    assert_eq!(login.user_code, "AB-12");
    assert_eq!(login.expires_at, 9_007_199_254_740_993);
    assert_eq!(harness.last_request().0, format!("POST {start}"));

    harness.http.route(
        start,
        reply(409, r#"{"code":"login_busy","login_id":"l9"}"#),
    );
    assert_eq!(
        harness
            .call(|core| async move {
                core.start_harness_login("h1".into(), "codex-native".into())
                    .await
            })
            .unwrap(),
        HarnessLoginStartOutcome::Busy {
            login_id: "l9".into()
        }
    );

    let status_path = format!("{start}/l1");
    for (wire, state) in [
        ("pending", HarnessLoginState::Pending),
        ("succeeded", HarnessLoginState::Succeeded),
        ("failed", HarnessLoginState::Failed),
        ("cancelled", HarnessLoginState::Cancelled),
        ("expired", HarnessLoginState::Expired),
    ] {
        harness.http.route_method(
            "GET",
            &status_path,
            reply(
                200,
                &format!(
                    r#"{{"status":"{wire}","error":"why","configured_harnesses":{{"codex-native":true}}}}"#
                ),
            ),
        );
        let status = harness
            .call(|core| async move {
                core.harness_login_status("h1".into(), "codex-native".into(), "l1".into())
                    .await
            })
            .unwrap();
        assert_eq!(status.state, state, "{wire}");
        assert_eq!(status.error.as_deref(), Some("why"));
        assert_eq!(
            status.snapshot.harnesses,
            Some(vec![ready_entry(
                "codex-native",
                HarnessAvailability::Ready
            )])
        );
    }

    harness
        .http
        .route_method("DELETE", &status_path, reply(200, "{}"));
    harness
        .call(|core| async move {
            core.cancel_harness_login("h1".into(), "codex-native".into(), "l1".into())
                .await
        })
        .unwrap();
    assert_eq!(harness.last_request().0, format!("DELETE {status_path}"));
}

#[test]
fn sign_out_and_refresh_answer_a_snapshot_with_accounts_and_gateway() {
    let mut harness = connected();
    let body = r#"{"configured_harnesses":{"claude-native":"needs-auth"},
        "harness_accounts":{"claude":{"kind":"none"}},
        "gateway_inference":{"claude-native":false}}"#;
    harness
        .http
        .route("/v1/hosts/h1/harnesses/claude/logout", reply(200, body));
    harness
        .http
        .route("/v1/hosts/h1/harnesses/refresh", reply(200, body));
    let snapshot = harness
        .call(|core| async move {
            core.sign_out_harness("h1".into(), "claude-native".into())
                .await
        })
        .unwrap();
    assert_eq!(
        harness.last_request().0,
        "POST /v1/hosts/h1/harnesses/claude/logout"
    );
    assert_eq!(
        snapshot.harnesses,
        Some(vec![ready_entry(
            "claude-native",
            HarnessAvailability::NeedsAuth
        )])
    );
    assert_eq!(snapshot.accounts.as_ref().unwrap()[0].key, "claude");
    assert_eq!(snapshot.accounts.as_ref().unwrap()[0].account.kind, "none");
    assert_eq!(
        snapshot.gateway_inference,
        Some(vec![GatewayInferenceEntry {
            harness: "claude-native".into(),
            enabled: false
        }])
    );
    let refreshed = harness
        .call(|core| async move { core.refresh_harnesses("h1".into()).await })
        .unwrap();
    assert_eq!(refreshed, snapshot);
    assert_eq!(
        harness.last_request().0,
        "POST /v1/hosts/h1/harnesses/refresh"
    );
}

#[test]
fn a_startup_read_maps_each_outcome_and_field() {
    let mut harness = connected();
    let path = "/v1/hosts/h1/harnesses/pi-native/startup";
    harness.http.route(
        path,
        reply(
            200,
            r#"{"command":"pi","resolved_path":"/bin/pi","command_source":"env",
                "args":["--x"],"arg_count":1,"configured_args":["--x"],
                "environment":{"variables":{"A":"1","B":"2"},"inherit":false,"unset":["C"]}}"#,
        ),
    );
    let read = |harness: &mut crate::test_support::Harness| {
        harness.call(|core| async move {
            core.harness_startup("h1".into(), "pi-native".into(), "Mac".into())
                .await
        })
    };
    let HarnessStartupRead::Loaded { startup } = read(&mut harness).unwrap() else {
        panic!("expected a startup command");
    };
    assert_eq!(startup.command, "/bin/pi");
    assert!(startup.found);
    assert_eq!(startup.source, "From OMNIGENT_PI_PATH on Mac.");
    assert_eq!(startup.args, Some(vec!["--x".to_owned()]));
    assert_eq!(startup.arg_count, 1);
    assert_eq!(
        startup.environment,
        Some(vec![
            HarnessStartupVariable {
                name: "A".into(),
                value: "1".into()
            },
            HarnessStartupVariable {
                name: "B".into(),
                value: "2".into()
            }
        ])
    );
    assert!(!startup.inherits_environment);
    assert_eq!(startup.unset, ["C"]);
    assert!(!startup.host_outdated);

    harness.http.route(path, reply(404, "{}"));
    assert_eq!(read(&mut harness).unwrap(), HarnessStartupRead::NotReported);
    harness.http.route(path, reply(501, "{}"));
    assert_eq!(
        read(&mut harness).unwrap(),
        HarnessStartupRead::HostOutdated
    );
}

#[test]
fn the_cli_config_names_this_machines_host() {
    assert_eq!(
        host_id_from_cli_config("host:\n  host_id: host_AAAA0000bbbb1111cccc2222dddd3333\n".into())
            .as_deref(),
        Some("aaaa0000bbbb1111cccc2222dddd3333")
    );
    assert_eq!(host_id_from_cli_config(String::new()), None);
}
