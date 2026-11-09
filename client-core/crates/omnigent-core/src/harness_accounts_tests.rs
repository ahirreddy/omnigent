// Ports of web/src/lib/harnessFix.test.ts, pages/settings/HarnessFixDialog.test.tsx and the
// details cases of SettingsHarnessesSection.test.tsx.

use serde_json::{Value, json};

use super::*;

fn host(extra: &Value) -> SetupHost {
    let mut row = json!({"host_id": "h1", "name": "Mac", "status": "online"});
    for (key, value) in extra.as_object().unwrap() {
        row[key] = value.clone();
    }
    SetupHost::from_value(&row).unwrap()
}

fn features() -> SetupFeatures {
    SetupFeatures {
        harness_install: true,
        installable_harnesses: vec!["codex-native".into(), "claude-native".into()],
    }
}

#[test]
fn account_keys_fold_aliases_and_the_native_affix() {
    assert_eq!(account_key("codex-native"), "codex");
    assert_eq!(account_key("native-claude"), "claude");
    assert_eq!(account_key("agy-native"), "antigravity");
    assert_eq!(account_key("pi"), "pi");
}

#[test]
fn fix_mode_follows_the_readiness() {
    assert_eq!(
        fix_mode(Some(&HarnessAvailability::VersionTooLow)),
        FixMode::Update
    );
    assert_eq!(
        fix_mode(Some(&HarnessAvailability::BinaryMissing)),
        FixMode::Install
    );
    assert_eq!(
        fix_mode(Some(&HarnessAvailability::NotConfigured)),
        FixMode::Install
    );
    assert_eq!(
        fix_mode(Some(&HarnessAvailability::NeedsAuth)),
        FixMode::Reconfigure
    );
    assert_eq!(fix_mode(None), FixMode::Reconfigure);
}

#[test]
fn decodes_accounts_gateway_and_login_support() {
    let host = host(&json!({
        "harness_login_supported": true,
        "gateway_inference": {"claude-native": true, "codex-native": false},
        "harness_accounts": {
            "codex": {"kind": "chatgpt", "email": "a@b.co", "plan": "plus", "expired": true},
            "pi": {"kind": "providers", "providers": [
                {"id": "x", "label": "Anthropic", "auth_type": "api_key"},
                {"id": "y", "label": "OpenAI", "auth_type": "oauth"}
            ]}
        }
    }));
    assert!(host.login_supported);
    assert_eq!(host.gateway("claude-native"), Some(true));
    assert_eq!(host.gateway("pi-native"), None);
    let codex = host.account("native-codex").unwrap();
    assert!(codex.expired);
    assert_eq!(codex.identity().as_deref(), Some("a@b.co \u{b7} plus"));
    assert_eq!(
        provider_details(host.account("pi-native").unwrap()),
        "Anthropic (API key) \u{b7} OpenAI (oauth)"
    );
    let bare = SetupHost::from_value(&json!({"host_id": "h"})).unwrap();
    assert!(!bare.login_supported);
    assert_eq!(bare.accounts, None);
}

#[test]
fn switching_needs_the_login_routes_and_a_personal_account() {
    let chatgpt = json!({"codex": {"kind": "chatgpt"}, "claude": {"kind": "api_key"}});
    let supported = host(&json!({"harness_login_supported": true, "harness_accounts": chatgpt}));
    assert!(can_switch_account(&supported, "codex-native"));
    assert!(!can_switch_account(&supported, "claude-native"));
    let unsupported = host(&json!({"harness_accounts": chatgpt}));
    assert!(!can_switch_account(&unsupported, "codex-native"));
    assert!(supports_device_login(&supported, "codex-native"));
    assert!(!supports_device_login(&supported, "claude-native"));
}

#[test]
fn personal_login_commands_match_the_web() {
    assert_eq!(
        personal_login_command("codex-native", Some("ignored"), None).as_deref(),
        Some("codex login --device-auth")
    );
    assert_eq!(
        personal_login_command("claude-native", None, Some(" o'neil@x.io ")).as_deref(),
        Some(r#"claude auth login --claudeai --email 'o'"'"'neil@x.io'"#)
    );
    assert_eq!(
        personal_login_command("claude-native", Some("claude login"), Some("a@b.co")).as_deref(),
        Some("claude login --email a@b.co")
    );
    assert_eq!(
        personal_login_command("pi-native", Some("pi login"), None),
        None
    );
    assert_eq!(personal_login_command("goose-native", None, None), None);
    assert_eq!(shell_argument(""), "''");
}

#[test]
fn ready_subscription_offers_switch_account() {
    let host = host(&json!({
        "harness_login_supported": true,
        "configured_harnesses": {"codex-native": true},
        "harness_accounts": {"codex": {"kind": "chatgpt", "email": "a@b.co", "plan": "pro"}}
    }));
    let detail = harness_detail(&host, "codex-native", "Codex", &features());
    assert!(detail.ready);
    assert_eq!(
        detail.status.as_deref(),
        Some("Configured \u{b7} a@b.co \u{b7} pro")
    );
    assert_eq!(detail.warning, None);
    assert_eq!(detail.credential.label, "Personal subscription");
    assert_eq!(
        detail.credential.action,
        Some(CredentialAction::SwitchAccount)
    );
}

#[test]
fn expired_sign_in_offers_sign_in_again() {
    let host = host(&json!({
        "configured_harnesses": {"codex-native": "needs-auth"},
        "harness_accounts": {"codex": {"kind": "chatgpt", "email": "a@b.co", "expired": true}}
    }));
    let detail = harness_detail(&host, "codex-native", "Codex", &features());
    assert_eq!(detail.credential.label, "Sign-in expired");
    assert!(detail.credential.warning);
    assert!(
        detail
            .credential
            .description
            .starts_with("a@b.co \u{2014} new sessions on Mac")
    );
    assert_eq!(
        detail.credential.action,
        Some(CredentialAction::SignInAgain)
    );
    assert_eq!(detail.warning, None);
}

#[test]
fn missing_sign_in_offers_reconfigure() {
    let host = host(&json!({"configured_harnesses": {"claude-native": "needs-auth"}}));
    let detail = harness_detail(&host, "claude-native", "Claude Code", &features());
    assert_eq!(detail.credential.label, "Not signed in");
    assert_eq!(
        detail.credential.description,
        "No Claude subscription or API key on Mac, so new sessions can\u{2019}t use Claude Code."
    );
    assert_eq!(
        detail.credential.action,
        Some(CredentialAction::Reconfigure)
    );
    assert_eq!(detail.mode, FixMode::Reconfigure);
}

#[test]
fn outdated_harness_warns_with_update() {
    let host = host(&json!({"configured_harnesses": {"codex-native": "version-too-low"}}));
    let detail = harness_detail(&host, "codex-native", "Codex", &features());
    let warning = detail.warning.unwrap();
    assert_eq!(warning.action_label, "Update");
    assert_eq!(warning.mode, FixMode::Update);
    assert_eq!(
        warning.message,
        "Codex is out of date on Mac. Update it so new sessions can use Codex."
    );
    assert_eq!(detail.status.as_deref(), Some("Outdated"));
}

#[test]
fn not_installable_or_sandboxed_hosts_cannot_fix_from_the_app() {
    let host_row = host(&json!({"configured_harnesses": {"goose-native": false}}));
    let detail = harness_detail(&host_row, "goose-native", "Goose", &features());
    assert_eq!(detail.warning.unwrap().action_label, "Set Up");
    let sandbox = host(&json!({
        "sandbox_provider": "modal",
        "configured_harnesses": {"codex-native": "needs-auth"}
    }));
    let detail = harness_detail(&sandbox, "codex-native", "Codex", &features());
    assert!(!detail.can_fix);
    assert_eq!(detail.credential.action, None);
}

#[test]
fn gateway_credential_reads_as_isaac() {
    let host = host(&json!({
        "configured_harnesses": {"claude-native": true},
        "gateway_inference": {"claude-native": true}
    }));
    let detail = harness_detail(&host, "claude-native", "Claude Code", &features());
    assert_eq!(detail.credential.label, "Isaac");
    assert_eq!(detail.status.as_deref(), Some("Configured \u{b7} Isaac"));
}

#[test]
fn login_start_requires_an_https_link() {
    let start = LoginStart::from_value(&json!({
        "login_id": "l1", "verification_url": "https://auth.openai.com/device",
        "user_code": "ABCD-1234", "expires_at": 1_700_000_000
    }))
    .unwrap();
    assert_eq!(start.user_code, "ABCD-1234");
    for url in [
        "http://auth.openai.com/device",
        "https://",
        "javascript:alert(1)",
    ] {
        let result = LoginStart::from_value(&json!({
            "login_id": "l1", "verification_url": url, "user_code": "A", "expires_at": 1
        }));
        assert!(result.is_err(), "{url}");
    }
}

#[test]
fn busy_login_reads_flat_and_nested_bodies() {
    assert_eq!(
        busy_login_id(&json!({"code": "login_busy", "login_id": "l2"})).as_deref(),
        Some("l2")
    );
    assert_eq!(
        busy_login_id(&json!({"error": {"code": "login_busy", "login_id": "l3"}})).as_deref(),
        Some("l3")
    );
    assert_eq!(
        busy_login_id(&json!({"code": "other", "login_id": "l4"})),
        None
    );
    assert_eq!(busy_login_id(&json!({"code": "login_busy"})), None);
}

#[test]
fn login_status_carries_the_refreshed_snapshot() {
    let status = LoginStatus::from_value(&json!({
        "status": "succeeded", "error": null, "expired": false,
        "configured_harnesses": {"codex-native": true},
        "harness_accounts": {"codex": {"kind": "chatgpt", "email": "a@b.co"}}
    }))
    .unwrap();
    assert_eq!(status.state, LoginState::Succeeded);
    assert!(status.snapshot.is_ready("codex-native"));
    let mut target = host(&json!({"configured_harnesses": {"codex-native": "needs-auth"}}));
    status.snapshot.apply(&mut target);
    assert_eq!(
        target.availability("codex-native"),
        Some(&HarnessAvailability::Ready)
    );
    assert_eq!(
        target.account("codex-native").unwrap().email.as_deref(),
        Some("a@b.co")
    );
    let failed = LoginStatus::from_value(&json!({"status": "weird", "error": "x"})).unwrap();
    assert_eq!(failed.state, LoginState::Failed);
    assert_eq!(failed.snapshot, HostSnapshot::default());
}

#[test]
fn startup_reads_command_environment_and_arguments() {
    let startup = HarnessStartup::from_value(
        &json!({
            "command": "claude", "resolved_path": "/usr/local/bin/claude",
            "command_source": "env", "arg_count": 2, "args": ["--a", ""],
            "configured_args": [], "environment": {
                "inherit": false, "variables": {"B": "2", "A": "1"}, "unset": ["X"]
            }
        }),
        "claude-native",
        "Mac",
    )
    .unwrap();
    assert_eq!(startup.command, "/usr/local/bin/claude");
    assert!(startup.found);
    assert_eq!(startup.source, "From OMNIGENT_CLAUDE_PATH on Mac.");
    assert_eq!(startup.args, Some(vec!["--a".to_owned(), String::new()]));
    assert_eq!(
        startup.environment,
        Some(vec![
            ("A".to_owned(), "1".to_owned()),
            ("B".to_owned(), "2".to_owned())
        ])
    );
    assert!(!startup.inherits_environment);
    assert_eq!(startup.unset, vec!["X".to_owned()]);
    assert!(!startup.host_outdated);
}

#[test]
fn startup_from_an_older_host() {
    let startup = HarnessStartup::from_value(
        &json!({"command": "codex", "resolved_path": null, "command_source": "config",
                "arg_count": 3}),
        "codex-native",
        "Box",
    )
    .unwrap();
    assert_eq!(startup.command, "codex");
    assert!(!startup.found);
    assert_eq!(
        startup.source,
        "From harness.codex-native in ~/.omnigent/config.yaml on Box."
    );
    assert_eq!(startup.args, None);
    assert_eq!(startup.environment, None);
    assert!(startup.host_outdated);
}

#[test]
fn a_broken_or_tmuxless_harness_explains_itself() {
    let row = host(&json!({"configured_harnesses": {"codex-native": "spawn-failed"}}));
    let warning = harness_detail(&row, "codex-native", "Codex", &features())
        .warning
        .unwrap();
    assert_eq!(
        warning.message,
        "Codex isn\u{2019}t working on Mac. Run setup again to fix it."
    );
    assert_eq!(warning.action_label, "Reconfigure");
    let row = host(&json!({"configured_harnesses": {"codex-native": "tmux-unavailable"}}));
    let warning = harness_detail(&row, "codex-native", "Codex", &features())
        .warning
        .unwrap();
    assert_eq!(
        warning.message,
        "Codex needs tmux on Mac, so new sessions can\u{2019}t use Codex."
    );
    let row = host(&json!({"configured_harnesses": {"codex-native": false}}));
    let warning = harness_detail(&row, "codex-native", "Codex", &features())
        .warning
        .unwrap();
    assert_eq!(warning.action_label, "Install");
}

#[test]
fn a_ready_harness_describes_its_account_kind() {
    let detail = |account: Value| {
        let row = host(&json!({
            "configured_harnesses": {"pi": true},
            "harness_accounts": {"pi": account},
        }));
        harness_detail(&row, "pi", "Pi", &features())
    };
    let providers = detail(json!({"kind": "providers", "providers": [
        {"id": "a", "label": "Alpha", "auth_type": "api"},
        {"id": "b", "label": "Beta", "auth_type": "oauth"},
    ]}));
    assert_eq!(providers.credential.label, "Providers");
    assert_eq!(
        providers.status.as_deref(),
        Some("Configured \u{b7} Alpha, Beta")
    );
    let none = detail(json!({"kind": "providers", "providers": []}));
    assert_eq!(none.credential.description, "No providers configured");
    assert_eq!(none.status.as_deref(), Some("Configured"));
    let key = detail(json!({"kind": "api_key"}));
    assert_eq!(key.credential.label, "API key");
    assert_eq!(
        key.credential.description,
        "Uses an API key configured on this host"
    );
}

#[test]
fn missing_credentials_name_what_the_harness_takes() {
    let description = |harness: &str| {
        let row = host(&json!({"configured_harnesses": {harness: "needs-auth"}}));
        harness_detail(&row, harness, "Tool", &features())
            .credential
            .description
    };
    assert_eq!(
        description("pi"),
        "No API key or gateway credential on Mac, so new sessions can\u{2019}t use Tool."
    );
    assert_eq!(
        description("goose-native"),
        "No credentials on Mac, so new sessions can\u{2019}t use Tool."
    );
}

#[test]
fn a_snapshot_applies_its_gateway_report() {
    let mut row = host(&json!({}));
    let snapshot = HostSnapshot::from_object(
        json!({"gateway_inference": {"pi": true}})
            .as_object()
            .unwrap(),
    )
    .unwrap();
    snapshot.apply(&mut row);
    assert_eq!(row.gateway("pi"), Some(true));
}
