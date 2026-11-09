//! Approval-mode menus and the live switch, over the fake host.

use omnigent_core::config::approval as core;
use serde_json::json as value;

use crate::approval::{ApprovalRisk, approval_mode_menu, launch_approval_mode_menu};
use crate::test_support::{configuration_on, connected, json};

#[test]
fn every_risk_maps() {
    for (on_core, on_ffi) in [
        (core::ApprovalRisk::ReadOnly, ApprovalRisk::ReadOnly),
        (core::ApprovalRisk::Ask, ApprovalRisk::Ask),
        (core::ApprovalRisk::AutoEdit, ApprovalRisk::AutoEdit),
        (core::ApprovalRisk::AutoApprove, ApprovalRisk::AutoApprove),
        (core::ApprovalRisk::FullAccess, ApprovalRisk::FullAccess),
    ] {
        assert_eq!(ApprovalRisk::from(on_core), on_ffi);
    }
}

#[test]
fn the_live_menu_reads_the_configuration_and_names_the_next_mode() {
    let mut configuration = configuration_on("claude-native");
    assert_eq!(approval_mode_menu(configuration.clone()), None);
    configuration.wrapper = Some("claude-code-native-ui".into());
    configuration.approval_mode = Some("default".into());
    let menu = approval_mode_menu(configuration.clone()).unwrap();
    assert_eq!(menu.harness, "Claude Code");
    assert_eq!(menu.selected.as_deref(), Some("default"));
    assert_eq!(menu.next.as_deref(), Some("acceptEdits"));
    assert_eq!(menu.options[0].value, "default");
    assert_eq!(menu.options[0].title, "Ask first");
    assert_eq!(menu.options[0].harness_title, "Manual");
    assert_eq!(
        menu.options[0].description,
        "Asks before edits and commands"
    );
    assert_eq!(menu.options[0].risk, ApprovalRisk::Ask);
    assert!(menu.options[0].switchable);

    configuration.approval_mode = Some("bypassPermissions".into());
    let launch_only = approval_mode_menu(configuration).unwrap();
    assert_eq!(launch_only.next, None);
    let current = launch_only.options.last().unwrap();
    assert_eq!(current.value, "bypassPermissions");
    assert_eq!(current.risk, ApprovalRisk::FullAccess);
    assert!(!current.switchable);
}

#[test]
fn the_launch_menu_selects_the_default_and_offers_no_next() {
    assert_eq!(launch_approval_mode_menu(None), None);
    let menu = launch_approval_mode_menu(Some("codex-native-ui".into())).unwrap();
    assert_eq!(menu.harness, "Codex");
    assert_eq!(menu.next, None);
    assert_eq!(
        menu.selected.as_deref(),
        Some(menu.options[0].value.as_str())
    );
    assert!(menu.options.iter().any(|option| option.value == "bypass"));
}

const CLAUDE_SESSION: &str = r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,
    "harness":"claude-native","agent_id":"claude","host_id":"demo-host",
    "host_online":true,"runner_online":true,
    "labels":{"omnigent.wrapper":"claude-code-native-ui",
              "omnigent.claude_native.permission_mode":"MODE"}}"#;

#[test]
fn switching_patches_the_harness_field_and_reads_back_the_summary() {
    let mut harness = connected();
    harness.http.route_method(
        "GET",
        "/v1/sessions/conv_a",
        json(200, &CLAUDE_SESSION.replace("MODE", "default")),
    );
    harness.http.route_method(
        "PATCH",
        "/v1/sessions/conv_a",
        json(200, &CLAUDE_SESSION.replace("MODE", "acceptEdits")),
    );
    harness.core.sessions().set_live_session("conv_a", true);
    let summary = harness
        .call(|core| async move {
            core.set_approval_mode("conv_a".into(), "acceptEdits".into())
                .await
        })
        .unwrap();
    assert_eq!(summary.id, "conv_a");
    assert_eq!(
        summary.configuration.unwrap().approval_mode.as_deref(),
        Some("acceptEdits")
    );
    assert_eq!(
        harness.last_request(),
        (
            "PATCH /v1/sessions/conv_a".to_owned(),
            value!({"permission_mode": "acceptEdits"})
        )
    );

    let refused = harness.call(|core| async move {
        core.set_approval_mode("conv_a".into(), "bypassPermissions".into())
            .await
    });
    assert!(refused.is_err());
}
