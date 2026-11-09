// Tests for the harness setup checklist; the web's lib/harnessSetup.test.ts covers the same rules.
use serde_json::json;

use super::*;

fn codex() -> HarnessDefinition {
    HarnessDefinition::from_value(&json!({
        "id": "codex-native",
        "label": "Codex",
        "setup_steps": [
            {"kind": "install", "title": "Install Codex", "detail": "We'll install Codex.",
             "action": "install", "command": null, "status_key": "installed"},
            {"kind": "auth", "title": "Sign in", "detail": "Sign in to Codex.",
             "action": "command", "command": "codex login", "status_key": "authed"},
            {"kind": "note", "title": "Optional", "detail": "", "action": "command",
             "command": "omni setup", "status_key": null}
        ]
    }))
    .unwrap()
}

fn host(availability: &Value) -> SetupHost {
    SetupHost::from_value(&json!({
        "host_id": "h1", "name": "Mac", "status": "online",
        "configured_harnesses": {"codex-native": availability}
    }))
    .unwrap()
}

fn enabled() -> SetupFeatures {
    SetupFeatures::from_value(&json!({
        "features": {"harness_install": true},
        "installable_harnesses": ["codex-native"]
    }))
    .unwrap()
}

#[test]
fn availability_maps_every_reported_value() {
    let cases = [
        (json!(true), HarnessAvailability::Ready),
        (json!(false), HarnessAvailability::NotConfigured),
        (json!("needs-auth"), HarnessAvailability::NeedsAuth),
        (json!("binary-missing"), HarnessAvailability::BinaryMissing),
        (json!("version-too-low"), HarnessAvailability::VersionTooLow),
        (json!("weird"), HarnessAvailability::Other("weird".into())),
        (json!(3), HarnessAvailability::Other("3".into())),
    ];
    for (value, expected) in cases {
        assert_eq!(HarnessAvailability::from_value(&value), expected, "{value}");
    }
}

#[test]
fn missing_binary_offers_install_then_a_locked_credential_form() {
    let plan = setup_plan(
        Some(&codex()),
        "codex-native",
        Some(&host(&json!("binary-missing"))),
        &enabled(),
    );
    assert_eq!(plan.steps.len(), 2, "the untracked step is dropped");
    assert_eq!(plan.steps[0].control, SetupStepControl::Install);
    assert_eq!(
        plan.steps[1].control,
        SetupStepControl::Credential { enabled: false }
    );
    assert_eq!(plan.steps[1].command.as_deref(), Some("codex login"));
    assert!(!plan.all_done && !plan.needs_omni_setup);
}

#[test]
fn installed_harness_unlocks_the_credential_form() {
    let plan = setup_plan(
        Some(&codex()),
        "codex-native",
        Some(&host(&json!("needs-auth"))),
        &enabled(),
    );
    assert_eq!(plan.steps[0].status, SetupStepStatus::Done);
    assert_eq!(plan.steps[0].detail, "Installed on the host.");
    assert_eq!(
        plan.steps[1].control,
        SetupStepControl::Credential { enabled: true }
    );
}

#[test]
fn ready_harness_is_all_done() {
    let plan = setup_plan(
        Some(&codex()),
        "codex-native",
        Some(&host(&json!(true))),
        &enabled(),
    );
    assert!(plan.all_done);
    assert!(
        plan.steps
            .iter()
            .all(|step| step.control == SetupStepControl::None)
    );
}

#[test]
fn without_the_feature_steps_are_commands_to_copy() {
    let plan = setup_plan(
        Some(&codex()),
        "codex-native",
        Some(&host(&json!("binary-missing"))),
        &SetupFeatures::default(),
    );
    assert_eq!(
        plan.steps[0].control,
        SetupStepControl::Command("omni setup".into())
    );
    assert!(!plan.steps[0].detail.contains("We'll"));
    assert_eq!(
        plan.steps[1].control,
        SetupStepControl::Command("codex login".into())
    );
    assert!(!plan.needs_omni_setup);
}

#[test]
fn a_host_without_tmux_adds_a_step_for_it_and_is_not_ready() {
    let plan = setup_plan(
        Some(&codex()),
        "codex-native",
        Some(&host(&json!("tmux-unavailable"))),
        &SetupFeatures::default(),
    );
    assert!(!plan.all_done);
    let statuses: Vec<_> = plan.steps.iter().map(|step| step.status).collect();
    assert_eq!(
        statuses,
        [
            SetupStepStatus::Done,
            SetupStepStatus::Done,
            SetupStepStatus::Todo
        ]
    );
    let tmux = plan.steps.last().unwrap();
    assert_eq!(tmux.kind, "tmux");
    assert_eq!(
        tmux.control,
        SetupStepControl::Command("brew install tmux".into())
    );
    assert_eq!(
        HarnessAvailability::from_value(&json!("tmux-unavailable")).label(),
        "Needs tmux"
    );
}

#[test]
fn nothing_actionable_points_at_omni_setup() {
    let definition = HarnessDefinition::from_value(&json!({
        "id": "goose-native",
        "setup_steps": [{"kind": "install", "title": "Set up", "detail": "", "action": "setup",
                         "status_key": "installed"}]
    }))
    .unwrap();
    let plan = setup_plan(
        Some(&definition),
        "goose-native",
        Some(&host(&json!(false))),
        &enabled(),
    );
    assert!(plan.needs_omni_setup);
    assert_eq!(definition.label, "goose-native");
    let empty = setup_plan(None, "goose-native", None, &enabled());
    assert!(empty.steps.is_empty() && empty.needs_omni_setup && !empty.all_done);
}

#[test]
fn offline_host_cannot_install_or_authenticate() {
    let mut offline = host(&json!("binary-missing"));
    offline.status = "offline".into();
    assert!(!installable(&enabled(), "codex-native", Some(&offline)));
    assert!(!authable(&enabled(), "codex-native", Some(&offline)));
    assert!(!installable(
        &enabled(),
        "goose-native",
        Some(&host(&json!(false)))
    ));
    assert!(!authable(
        &enabled(),
        "goose-native",
        Some(&host(&json!(false)))
    ));
}

#[test]
fn adopt_stays_within_the_harness_families() {
    let detected = [
        DetectedCredential {
            family: "anthropic".into(),
            source: "$ANTHROPIC_API_KEY".into(),
            env_var: Some("ANTHROPIC_API_KEY".into()),
        },
        DetectedCredential {
            family: "openai".into(),
            source: "$OPENAI_API_KEY".into(),
            env_var: Some("OPENAI_API_KEY".into()),
        },
    ];
    assert_eq!(
        adoptable_credential("codex-native", &detected).map(|found| found.family),
        Some("openai".into())
    );
    assert_eq!(
        adoptable_credential("pi-native", &detected[1..]).map(|found| found.family),
        Some("openai".into())
    );
    assert_eq!(adoptable_credential("claude-native", &detected[1..]), None);
    assert_eq!(adoptable_credential("goose-native", &detected), None);
}

#[test]
fn credential_bodies_are_validated_before_sending() {
    assert_eq!(
        credential_body(&CredentialInput::Key {
            secret: " sk-1 ".into()
        }),
        Ok(json!({"kind": "key", "secret": "sk-1"}))
    );
    assert!(
        credential_body(&CredentialInput::Key {
            secret: "  ".into()
        })
        .is_err()
    );
    assert!(
        credential_body(&CredentialInput::Gateway {
            base_url: "ftp://x".into(),
            secret: "k".into()
        })
        .is_err()
    );
    assert_eq!(
        credential_body(&CredentialInput::Gateway {
            base_url: "https://openrouter.ai/api/v1".into(),
            secret: "k".into()
        }),
        Ok(json!({"kind": "gateway", "base_url": "https://openrouter.ai/api/v1", "secret": "k"}))
    );
    assert_eq!(
        credential_body(&CredentialInput::Adopt {
            env_var: "OPENAI_API_KEY".into()
        }),
        Ok(json!({"kind": "adopt", "env_var": "OPENAI_API_KEY"}))
    );
}

#[test]
fn inventory_is_neutral_for_unreported_harnesses() {
    let rows = inventory(Some(&host(&json!("needs-auth"))));
    assert_eq!(rows.len(), INVENTORY.len());
    let codex = rows
        .iter()
        .find(|row| row.harness.harness == "codex-native")
        .unwrap();
    assert!(codex.needs_setup && !codex.ready);
    assert_eq!(codex.status.as_deref(), Some("Needs sign-in"));
    let claude = &rows[0];
    assert_eq!(claude.status, None);
    assert!(!claude.needs_setup);
}

#[test]
fn hosts_order_online_first_and_sandboxes_last() {
    let row = |id: &str, status: &str, sandbox: Option<&str>| SetupHost {
        host_id: id.into(),
        name: id.into(),
        status: status.into(),
        sandbox_provider: sandbox.map(str::to_owned),
        ..SetupHost::default()
    };
    let ordered = ordered_hosts(vec![
        row("a", "offline", None),
        row("b", "online", Some("modal")),
        row("c", "online", None),
    ]);
    let ids: Vec<_> = ordered.iter().map(|host| host.host_id.as_str()).collect();
    assert_eq!(ids, ["c", "b", "a"]);
}

#[test]
fn acknowledgement_needs_readiness() {
    assert_eq!(
        acknowledged_availability(&json!({"configured_harnesses": {"codex-native": true}}))
            .unwrap()
            .get("codex-native"),
        Some(&HarnessAvailability::Ready)
    );
    assert!(acknowledged_availability(&json!({"object": "harness_install"})).is_err());
}

#[test]
fn definitions_take_the_steps_map_by_every_spelling() {
    let definitions = harness_definitions(&json!({
        "data": [{"id": "codex", "label": "Codex CLI", "setup_steps": []}],
        "setup_steps": {
            "codex": [{"kind": "install", "title": "Install", "detail": "", "action": "install"}],
            "codex-native": [{"kind": "auth", "title": "Sign in", "detail": "", "action": "auth",
                              "command": "codex login", "status_key": "authed"}]
        }
    }))
    .unwrap();
    assert_eq!(definitions[0].label, "Codex CLI");
    assert_eq!(definitions[0].setup_steps.len(), 1);
    assert_eq!(definitions[1].id, "codex-native");
    assert_eq!(definitions[1].label, "Codex");
    assert!(harness_definitions(&json!({"setup_steps": {}})).is_err());
}

#[test]
fn a_ready_harness_reads_configured_and_unknown_steps_stay_unknown() {
    assert_eq!(HarnessAvailability::Ready.label(), "Configured");
    assert_eq!(done_detail("auth"), "Signed in on the host.");
    assert_eq!(done_detail("note"), "Done.");
    assert_eq!(
        step_status(Some("mystery"), Some(&HarnessAvailability::Ready)),
        SetupStepStatus::Unknown
    );
}
