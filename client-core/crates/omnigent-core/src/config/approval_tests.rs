//! Approval-mode vocabulary tests. The values mirror the server's validation lists
//! (`_CLAUDE_NATIVE_PERMISSION_MODES`, `CODEX_NATIVE_PERMISSION_PRESETS`, `DEVIN_PERMISSION_MODES`).

use std::collections::BTreeMap;

use omnigent_protocol::Field;

use super::*;

fn configured(wrapper: &str, mode: Option<&str>) -> SessionConfiguration {
    SessionConfiguration {
        wrapper: Some(wrapper.to_owned()),
        approval_mode: mode.map(str::to_owned),
        ..SessionConfiguration::default()
    }
}

fn values(menu: &ApprovalModeMenu) -> Vec<&str> {
    menu.options
        .iter()
        .map(|option| option.value.as_str())
        .collect()
}

fn labels(pairs: &[(&str, &str)]) -> Field<BTreeMap<String, String>> {
    Field::Present(
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect(),
    )
}

#[test]
fn claude_offers_its_shift_tab_modes_under_clear_names() {
    let menu = approval_mode_menu(&configured("claude-code-native-ui", Some("default"))).unwrap();
    assert_eq!(menu.field, ApprovalModeField::PermissionMode);
    assert_eq!(values(&menu), ["default", "acceptEdits", "plan", "auto"]);
    let titles: Vec<&str> = menu.options.iter().map(|o| o.title.as_str()).collect();
    assert_eq!(
        titles,
        ["Ask first", "Auto-edit", "Plan only", "Auto-approve"]
    );
    assert_eq!(menu.selected_option().unwrap().harness_title, "Manual");
    assert_eq!(menu.next().unwrap().value, "acceptEdits");
}

#[test]
fn codex_maps_approve_for_me_to_auto_approve_and_never_offers_read_only() {
    let menu = approval_mode_menu(&configured("codex-native-ui", Some("approve-for-me"))).unwrap();
    assert_eq!(menu.field, ApprovalModeField::ApprovalMode);
    assert_eq!(
        values(&menu),
        ["ask-for-approval", "approve-for-me", "full-access"]
    );
    let selected = menu.selected_option().unwrap();
    assert_eq!(selected.title, "Auto-approve");
    assert_eq!(selected.harness_title, "Approve for me");
    assert_eq!(menu.options.last().unwrap().risk, FullAccess);
    assert_eq!(menu.next().unwrap().value, "full-access");
}

#[test]
fn devin_uses_its_own_rungs() {
    let menu = approval_mode_menu(&configured("devin-native-ui", Some("dangerous"))).unwrap();
    assert_eq!(
        values(&menu),
        ["normal", "accept-edits", "smart", "dangerous"]
    );
    assert_eq!(menu.next().unwrap().value, "normal", "cycling wraps");
}

#[test]
fn launch_only_modes_show_but_are_never_cycle_targets() {
    let menu = approval_mode_menu(&configured(
        "claude-code-native-ui",
        Some("bypassPermissions"),
    ))
    .unwrap();
    let selected = menu.selected_option().unwrap();
    assert_eq!(selected.title, "Full access");
    assert!(!selected.switchable);
    assert_eq!(menu.next(), None);
    let codex = approval_mode_menu(&configured("codex-native-ui", Some("read-only"))).unwrap();
    assert_eq!(codex.selected_option().unwrap().title, "Read only");
    assert_eq!(codex.next(), None);
}

#[test]
fn unknown_and_unreported_modes_are_never_guessed() {
    let unset = approval_mode_menu(&configured("codex-native-ui", None)).unwrap();
    assert_eq!(unset.selected_option(), None);
    assert_eq!(unset.next(), None);
    let raw = approval_mode_menu(&configured("claude-code-native-ui", Some("newMode"))).unwrap();
    let option = raw.selected_option().unwrap();
    assert_eq!(option.title, "newMode");
    assert!(!option.switchable);
}

#[test]
fn harnesses_without_a_live_switch_have_no_menu() {
    assert_eq!(approval_mode_menu(&configured("pi-native-ui", None)), None);
    assert_eq!(approval_mode_menu(&SessionConfiguration::default()), None);
}

#[test]
fn the_confirmed_label_wins_then_the_launch_flag() {
    let claude = Some("claude-code-native-ui");
    let args = Field::Present(vec!["--permission-mode".to_owned(), "plan".to_owned()]);
    assert_eq!(
        reported_approval_mode(
            claude,
            &labels(&[("omnigent.claude_native.permission_mode", "auto")]),
            &args
        ),
        Some(Some("auto".to_owned()))
    );
    assert_eq!(
        reported_approval_mode(claude, &labels(&[]), &args),
        Some(Some("plan".to_owned()))
    );
    assert_eq!(
        reported_approval_mode(claude, &labels(&[]), &Field::Present(vec![])),
        Some(None)
    );
    assert_eq!(
        reported_approval_mode(claude, &labels(&[]), &Field::Absent),
        None,
        "a list row keeps a mode read from the launch flag"
    );
}

#[test]
fn codex_reads_only_its_label() {
    let codex = Some("codex-native-ui");
    let args = Field::Present(vec!["--permission-mode".to_owned(), "plan".to_owned()]);
    assert_eq!(
        reported_approval_mode(codex, &labels(&[]), &args),
        Some(None)
    );
    assert_eq!(
        reported_approval_mode(
            codex,
            &labels(&[("omnigent.codex_native.approval_mode", "full-access")]),
            &Field::Absent
        ),
        Some(Some("full-access".to_owned()))
    );
    assert_eq!(
        reported_approval_mode(Some("other"), &labels(&[]), &args),
        Some(None)
    );
}

#[test]
fn steering_follows_the_executors_live_queue_support() {
    let session = |harness: &str| SessionConfiguration {
        harness: Some(harness.to_owned()),
        ..SessionConfiguration::default()
    };
    assert!(session("codex-native").supports_steering());
    assert!(session("native-claude").supports_steering());
    assert!(!session("claude-sdk").supports_steering());
    assert!(!session("copilot").supports_steering());
    assert!(!SessionConfiguration::default().supports_steering());
}

#[test]
fn launch_modes_offer_launch_only_modes_and_send_flags_only_off_default() {
    let claude = launch_approval_mode_menu(Some("claude-code-native-ui")).unwrap();
    assert_eq!(claude.selected.as_deref(), Some("default"));
    assert!(
        claude
            .options
            .iter()
            .any(|o| o.value == "bypassPermissions")
    );
    assert!(claude.options.iter().all(|o| o.switchable));
    assert_eq!(
        launch_approval_args(Some("claude-code-native-ui"), "default"),
        None
    );
    assert_eq!(
        launch_approval_args(Some("claude-code-native-ui"), "bypassPermissions"),
        Some(vec!["--permission-mode".into(), "bypassPermissions".into()])
    );
    let codex = launch_approval_mode_menu(Some("codex-native-ui")).unwrap();
    let values: Vec<_> = codex.options.iter().map(|o| o.value.as_str()).collect();
    assert_eq!(
        values,
        ["ask-for-approval", "read-only", "full-access", "bypass"]
    );
    // Bypass is a launch label, never flags, and only Codex has it.
    assert_eq!(
        launch_approval_args(Some("codex-native-ui"), "bypass"),
        None
    );
    assert!(is_codex_bypass(Some("codex-native-ui"), Some("bypass")));
    assert!(!is_codex_bypass(Some("devin-native-ui"), Some("bypass")));
    assert!(!is_codex_bypass(
        Some("codex-native-ui"),
        Some("full-access")
    ));
    assert_eq!(
        launch_approval_args(Some("codex-native-ui"), "full-access"),
        Some(
            [
                "--sandbox",
                "danger-full-access",
                "--ask-for-approval",
                "never"
            ]
            .map(String::from)
            .to_vec()
        )
    );
    assert_eq!(
        launch_approval_args(Some("codex-native-ui"), "approve-for-me"),
        None
    );
    assert_eq!(launch_approval_mode_menu(Some("pi-native-ui")), None);
    assert_eq!(
        launch_approval_args(Some("devin-native-ui"), "smart").map(|args| args.len()),
        Some(2)
    );
}
