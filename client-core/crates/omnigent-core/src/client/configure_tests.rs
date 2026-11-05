//! Session configuration REST tests, ported from `NativeLab`'s `SessionConfigurationTests`.

use std::pin::pin;

use futures::executor::block_on;
use omnigent_protocol::{FromWire, ServerStreamEvent};
use serde_json::{Value, json};

use super::SessionError;
use super::sessions::SessionSummary;
use super::sessions::test_support::{summary_of, wire};
use super::test_support::{Reply, RouteTransport, envelopes, fixture_lines, live, still_pending};
use crate::config::session::{ConfigurationEdit, ConfigurationError};

const CONFIG: &str = "sessions/SessionConfiguration--";
const PATH: &str = "/v1/sessions/conv_a";
const MODEL_OPTIONS: &str = "/v1/hosts/demo-host/harnesses/codex-native/model-options";

fn fields() -> Value {
    json!({
        "harness": "codex-native", "agent_id": "clone",
        "labels": {"omnigent.wrapper": "codex-native-ui"},
        "model_override": "sample-balanced", "reasoning_effort": "high", "host_id": "demo-host",
        "host_online": true, "runner_online": true,
        "model_options": [
            {"id": "sample-balanced", "isDefault": true,
             "supportedReasoningEfforts": [{"reasoningEffort": "high"}, {"reasoningEffort": "low"}]},
            {"id": "sample-fast", "supportedReasoningEfforts": [{"reasoningEffort": "low"}]},
        ],
    })
}

fn merged(overrides: &Value) -> Value {
    let mut base = fields();
    for (key, value) in overrides.as_object().unwrap() {
        base[key] = value.clone();
    }
    base
}

fn summary(fields: &Value) -> SessionSummary {
    summary_of(fields, None, true)
}

fn edit_from(fields: &Value) -> ConfigurationEdit {
    ConfigurationEdit::new(summary(fields).configuration.unwrap())
}

fn mutation_bodies(transport: &RouteTransport) -> Vec<Value> {
    transport.write_bodies()
}

fn stub_session(transport: &RouteTransport, fields: &Value) {
    transport.respond(
        Some("GET"),
        PATH,
        None,
        Reply::json(200, wire(fields, true).to_string()),
    );
}

#[test]
fn model_and_effort_patch_are_ordered_and_use_explicit_reset_sentinels() {
    let transport = RouteTransport::local();
    transport.script(&format!(
        "{CONFIG}ModelAndEffortPatchAreOrderedAndUseExplicitResetSentinels.jsonl"
    ));
    let core = live(transport);
    let mut edit = edit_from(&fields());
    edit.model = None;
    edit.effort = None;
    let saved = block_on(core.apply_configuration(&edit, "conv_a")).unwrap();
    let configuration = saved.configuration.unwrap();
    assert_eq!(configuration.model_override, None);
    assert_eq!(configuration.effort, None);
    assert_eq!(
        mutation_bodies(core.transport()),
        vec![
            json!({"model_override": "default"}),
            json!({"reasoning_effort": "default"})
        ]
    );
    let lines = core.transport().lines();
    let patch_positions: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, line)| line.starts_with("PATCH"))
        .map(|(index, _)| index)
        .collect();
    assert_eq!(
        lines[patch_positions[0] + 1],
        format!("GET {PATH}"),
        "a re-read separates the two writes"
    );
}

#[test]
fn busy_read_only_archived_offline_and_unstreamed_sessions_never_patch() {
    let scenarios = envelopes(&format!(
        "{CONFIG}BusyReadOnlyArchivedOfflineAndUnstreamedSessionsNeverPatch.jsonl"
    ));
    assert_eq!(scenarios.len(), 6);
    let expectations: [fn(&SessionError) -> bool; 5] = [
        |error| *error == SessionError::Busy,
        |error| *error == SessionError::ReadOnly,
        |error| *error == SessionError::Archived,
        |error| {
            matches!(
                error,
                SessionError::Configuration(ConfigurationError::Unavailable(_))
            )
        },
        |error| *error == SessionError::Busy,
    ];
    for (scenario, expected) in scenarios.iter().zip(expectations) {
        let transport = RouteTransport::local();
        transport.respond(Some("GET"), PATH, None, scenario.reply.clone());
        let core = live(transport);
        let mut edit = edit_from(&fields());
        edit.model = Some("sample-fast".into());
        let error = block_on(core.apply_configuration(&edit, "conv_a")).unwrap_err();
        assert!(expected(&error), "{scenario:?}: {error:?}");
        assert_eq!(mutation_bodies(core.transport()), Vec::<Value>::new());
    }
    let transport = RouteTransport::local();
    transport.respond(Some("GET"), PATH, None, scenarios[5].reply.clone());
    let core = super::test_support::connected(transport);
    let mut edit = edit_from(&fields());
    edit.model = Some("sample-fast".into());
    assert_eq!(
        block_on(core.apply_configuration(&edit, "conv_a")),
        Err(SessionError::StreamNotReady)
    );
    assert_eq!(mutation_bodies(core.transport()), Vec::<Value>::new());
}

#[test]
fn changed_selection_and_removed_catalog_option_never_patch() {
    for scenario in envelopes(&format!(
        "{CONFIG}ChangedSelectionAndRemovedCatalogOptionNeverPatch.jsonl"
    )) {
        let transport = RouteTransport::local();
        transport.respond(Some("GET"), PATH, None, scenario.reply.clone());
        let core = live(transport);
        let mut edit = edit_from(&fields());
        edit.model = Some("sample-fast".into());
        assert!(block_on(core.apply_configuration(&edit, "conv_a")).is_err());
        assert_eq!(mutation_bodies(core.transport()), Vec::<Value>::new());
    }
}

#[test]
fn uncertain_model_patch_is_never_retried_or_followed_by_effort_patch() {
    let transport = RouteTransport::local();
    transport.script(&format!(
        "{CONFIG}UncertainModelPatchIsNeverRetriedOrFollowedByEffortPatch.jsonl"
    ));
    let core = live(transport);
    let mut edit = edit_from(&fields());
    edit.select_model(Some("sample-fast".into()));
    assert!(matches!(
        block_on(core.apply_configuration(&edit, "conv_a")),
        Err(SessionError::DeliveryUncertain { .. })
    ));
    assert_eq!(mutation_bodies(core.transport()).len(), 1);
}

#[test]
fn partial_success_requires_review_when_second_write_fails() {
    let transport = RouteTransport::local();
    transport.script(&format!(
        "{CONFIG}PartialSuccessRequiresReviewWhenSecondWriteFails.jsonl"
    ));
    let core = live(transport);
    let mut edit = edit_from(&fields());
    edit.select_model(Some("sample-fast".into()));
    assert!(matches!(
        block_on(core.apply_configuration(&edit, "conv_a")),
        Err(SessionError::DeliveryUncertain { .. })
    ));
    assert_eq!(mutation_bodies(core.transport()).len(), 2);
}

#[test]
fn unacknowledged_and_malformed_mutation_snapshots_are_uncertain() {
    let all = envelopes(&format!(
        "{CONFIG}UnacknowledgedAndMalformedMutationSnapshotsAreUncertain.jsonl"
    ));
    for pair in all.chunks(2) {
        let transport = RouteTransport::local();
        transport.respond(Some("GET"), PATH, None, pair[0].reply.clone());
        transport.respond(Some("PATCH"), PATH, None, pair[1].reply.clone());
        let core = live(transport);
        let mut edit = edit_from(&fields());
        edit.select_model(Some("sample-fast".into()));
        assert!(
            matches!(
                block_on(core.apply_configuration(&edit, "conv_a")),
                Err(SessionError::DeliveryUncertain { .. })
            ),
            "{pair:?}"
        );
        assert_eq!(mutation_bodies(core.transport()).len(), 1);
    }
}

#[test]
fn harness_switch_retains_session_and_checks_target_acknowledgement() {
    let transport = RouteTransport::local();
    transport.script(&format!(
        "{CONFIG}HarnessSwitchRetainsSessionAndChecksTargetAcknowledgement.jsonl"
    ));
    let core = live(transport);
    let baseline = summary(&fields()).configuration.unwrap();
    let saved = block_on(core.switch_harness("target", &baseline, "conv_a")).unwrap();
    assert_eq!(saved.id, "conv_a");
    let configuration = saved.configuration.unwrap();
    assert_eq!(configuration.harness.as_deref(), Some("claude-native"));
    assert_eq!(configuration.model_override, None);
    assert_eq!(
        mutation_bodies(core.transport()),
        vec![json!({"agent_id": "target"})]
    );
    // An acknowledgement that still shows the old agent is not a switch.
    let script = envelopes(&format!(
        "{CONFIG}HarnessSwitchRetainsSessionAndChecksTargetAcknowledgement.jsonl"
    ));
    let transport = RouteTransport::local();
    for envelope in &script[..3] {
        transport.respond(Some("GET"), &envelope.path, None, envelope.reply.clone());
    }
    transport.respond(
        Some("POST"),
        "/v1/sessions/conv_a/switch-agent",
        None,
        Reply::json(200, wire(&fields(), true).to_string()),
    );
    let core = live(transport);
    assert!(matches!(
        block_on(core.switch_harness("target", &baseline, "conv_a")),
        Err(SessionError::DeliveryUncertain { .. })
    ));
}

#[test]
fn host_preview_stays_separate_and_cannot_follow_another_harness() {
    let transport = RouteTransport::local();
    transport.script(&format!(
        "{CONFIG}HostPreviewStaysSeparateAndCannotFollowAnotherHarness.jsonl"
    ));
    let core = live(transport);
    let catalog = block_on(core.configuration_catalog("conv_a")).unwrap();
    assert_eq!(
        catalog
            .model_options
            .iter()
            .map(|m| m.id.as_str())
            .collect::<Vec<_>>(),
        ["sample-fast"]
    );
    assert_eq!(catalog.model_options_error, None);
    let current = summary(&merged(&json!({"model_options": []})))
        .configuration
        .unwrap();
    assert_eq!(
        catalog
            .configuration_by_adding_model_options(&current)
            .models,
        catalog.model_options
    );
    let mut switched = current;
    switched.harness = Some("claude-native".into());
    assert_eq!(
        catalog
            .configuration_by_adding_model_options(&switched)
            .models,
        []
    );
    let confirmed = core
        .cached_summary("conv_a")
        .unwrap()
        .configuration
        .unwrap();
    assert_eq!(confirmed.models, []);
    assert_eq!(mutation_bodies(core.transport()), Vec::<Value>::new());
}

#[test]
fn host_preview_failure_does_not_hide_harness_catalog() {
    let transport = RouteTransport::local();
    transport.script(&format!(
        "{CONFIG}HostPreviewFailureDoesNotHideHarnessCatalog.jsonl"
    ));
    let core = live(transport);
    let catalog = block_on(core.configuration_catalog("conv_a")).unwrap();
    assert_eq!(catalog.agents.len(), 1);
    assert_eq!(catalog.model_options, []);
    assert!(catalog.model_options_error.is_some());
}

#[test]
fn apply_revalidates_host_preview_before_any_write() {
    let transport = RouteTransport::local();
    transport.script(&format!(
        "{CONFIG}ApplyRevalidatesHostPreviewBeforeAnyWrite.jsonl"
    ));
    let core = live(transport);
    let mut edit = edit_from(&merged(&json!({"model_options": []})));
    edit.model = Some("sample-fast".into());
    edit.effort = None;
    assert!(matches!(
        block_on(core.apply_configuration(&edit, "conv_a")),
        Err(SessionError::Configuration(_))
    ));
    assert_eq!(mutation_bodies(core.transport()), Vec::<Value>::new());
    assert_eq!(
        core.transport()
            .lines()
            .iter()
            .filter(|line| line.ends_with(MODEL_OPTIONS))
            .count(),
        1
    );
}

#[test]
fn changed_event_during_mutation_uses_fresh_acknowledgement_not_stale_response() {
    let transport = RouteTransport::local();
    transport.script(&format!(
        "{CONFIG}ChangedEventDuringMutationUsesFreshAcknowledgementNotStaleResponse.jsonl"
    ));
    let gate = transport.gate("PATCH", PATH);
    let core = live(transport);
    let event_line = &fixture_lines(
        "sse/SessionConfiguration--ChangedEventDuringMutationUsesFreshAcknowledgementNotStaleResponse--event.jsonl",
    )[0];
    let event = ServerStreamEvent::from_value(event_line["data"].clone()).unwrap();
    let mut edit = edit_from(&fields());
    edit.select_model(Some("sample-fast".into()));
    let mut operation = pin!(core.apply_configuration(&edit, "conv_a"));
    assert!(still_pending(operation.as_mut()));
    core.record_stream_event("conv_a", &event);
    gate.open();
    assert!(matches!(
        block_on(operation),
        Err(SessionError::DeliveryUncertain { .. })
    ));
    let confirmed = core
        .cached_summary("conv_a")
        .unwrap()
        .configuration
        .unwrap();
    assert_eq!(confirmed.model_override.as_deref(), Some("external-model"));
    assert_eq!(mutation_bodies(core.transport()).len(), 1);
}

#[test]
fn concurrent_configuration_mutation_is_rejected_before_second_write() {
    let transport = RouteTransport::local();
    transport.script(&format!(
        "{CONFIG}ConcurrentConfigurationMutationIsRejectedBeforeSecondWrite.jsonl"
    ));
    let gate = transport.gate("PATCH", PATH);
    let core = live(transport);
    let mut edit = edit_from(&merged(&json!({"reasoning_effort": null})));
    edit.select_model(Some("sample-fast".into()));
    let mut first = pin!(core.apply_configuration(&edit, "conv_a"));
    assert!(still_pending(first.as_mut()));
    assert_eq!(
        block_on(core.apply_configuration(&edit, "conv_a")),
        Err(SessionError::Busy)
    );
    gate.open();
    block_on(first).unwrap();
    assert_eq!(mutation_bodies(core.transport()).len(), 1);
}

#[test]
fn stream_event_crossing_snapshot_read_rejects_stale_configuration() {
    let transport = RouteTransport::local();
    stub_session(&transport, &fields());
    let gate = transport.gate("GET", PATH);
    let core = live(transport);
    let event =
        ServerStreamEvent::from_value(json!({"type": "session.model", "model": "new"})).unwrap();
    let mut read = pin!(core.configuration_snapshot("conv_a"));
    assert!(still_pending(read.as_mut()));
    core.record_stream_event("conv_a", &event);
    gate.open();
    assert_eq!(
        block_on(read),
        Err(SessionError::Configuration(
            ConfigurationError::ChangedElsewhere
        ))
    );
    assert_eq!(core.cached_summary("conv_a"), None);
}

#[test]
fn list_event_crossing_snapshot_read_rejects_stale_configuration() {
    let transport = RouteTransport::local();
    stub_session(&transport, &fields());
    let gate = transport.gate("GET", PATH);
    let core = live(transport);
    let mut read = pin!(core.configuration_snapshot("conv_a"));
    assert!(still_pending(read.as_mut()));
    core.apply_session_rows(vec![wire(
        &merged(&json!({"model_override": "external"})),
        true,
    )])
    .unwrap();
    gate.open();
    assert_eq!(
        block_on(read),
        Err(SessionError::Configuration(
            ConfigurationError::ChangedElsewhere
        ))
    );
    // A list row carries no model override, so the cached configuration keeps the earlier
    // value; the point is that the stale snapshot did not replace the newer row.
    assert!(core.cached_summary("conv_a").is_some());
}

fn claude_fields(mode: &str) -> Value {
    json!({
        "harness": "claude-native", "agent_id": "claude",
        "labels": {
            "omnigent.wrapper": "claude-code-native-ui",
            "omnigent.claude_native.permission_mode": mode,
        },
        "host_id": "demo-host", "host_online": true, "runner_online": true,
    })
}

#[test]
fn approval_mode_patches_the_harness_field_while_a_turn_runs() {
    let transport = RouteTransport::local();
    let mut running = claude_fields("default");
    running["status"] = json!("running");
    stub_session(&transport, &running);
    let mut landed = claude_fields("acceptEdits");
    landed["status"] = json!("running");
    transport.respond(
        Some("PATCH"),
        PATH,
        None,
        Reply::json(200, wire(&landed, true).to_string()),
    );
    let core = live(transport);
    let saved = block_on(core.set_approval_mode("acceptEdits", "conv_a")).unwrap();
    assert_eq!(
        saved.configuration.unwrap().approval_mode.as_deref(),
        Some("acceptEdits")
    );
    assert_eq!(
        mutation_bodies(core.transport()),
        vec![json!({"permission_mode": "acceptEdits"})]
    );
}

#[test]
fn approval_mode_rejects_launch_only_modes_and_reports_a_different_landing() {
    let transport = RouteTransport::local();
    stub_session(&transport, &claude_fields("default"));
    let core = live(transport);
    let error = block_on(core.set_approval_mode("bypassPermissions", "conv_a")).unwrap_err();
    assert!(
        matches!(
            error,
            SessionError::Configuration(ConfigurationError::Unavailable(_))
        ),
        "{error:?}"
    );
    assert_eq!(mutation_bodies(core.transport()), Vec::<Value>::new());

    let transport = RouteTransport::local();
    stub_session(&transport, &claude_fields("default"));
    transport.respond(
        Some("PATCH"),
        PATH,
        None,
        Reply::json(200, wire(&claude_fields("plan"), true).to_string()),
    );
    let core = live(transport);
    let error = block_on(core.set_approval_mode("auto", "conv_a")).unwrap_err();
    assert_eq!(
        error,
        SessionError::Configuration(ConfigurationError::Unavailable(
            "Claude Code stayed in Plan only instead of switching to Auto-approve.".into()
        ))
    );
}

#[test]
fn approval_mode_without_an_acknowledged_mode_is_uncertain() {
    let transport = RouteTransport::local();
    let fields = merged(&json!({}));
    stub_session(&transport, &fields);
    transport.respond(
        Some("PATCH"),
        PATH,
        None,
        Reply::json(200, wire(&fields, true).to_string()),
    );
    let core = live(transport);
    let error = block_on(core.set_approval_mode("full-access", "conv_a")).unwrap_err();
    assert!(
        matches!(error, SessionError::DeliveryUncertain { .. }),
        "{error:?}"
    );
    assert_eq!(
        mutation_bodies(core.transport()),
        vec![json!({"approval_mode": "full-access"})]
    );
}

#[test]
fn smart_routing_patches_the_cost_control_mode_and_checks_the_acknowledgement() {
    let transport = RouteTransport::local();
    stub_session(&transport, &fields());
    let routed = merged(&json!({"cost_control_mode_override": "on"}));
    transport.respond(
        Some("PATCH"),
        PATH,
        None,
        Reply::json(200, wire(&routed, true).to_string()),
    );
    let core = live(transport);
    let saved = block_on(core.set_smart_routing(true, "conv_a")).unwrap();
    assert_eq!(
        saved.configuration.unwrap().routing_mode.as_deref(),
        Some("on")
    );
    assert_eq!(
        mutation_bodies(core.transport()),
        vec![json!({"cost_control_mode_override": "on"})]
    );

    let transport = RouteTransport::local();
    stub_session(&transport, &routed);
    transport.respond(
        Some("PATCH"),
        PATH,
        None,
        Reply::json(200, wire(&routed, true).to_string()),
    );
    let core = live(transport);
    let error = block_on(core.set_smart_routing(false, "conv_a")).unwrap_err();
    assert!(
        matches!(error, SessionError::DeliveryUncertain { .. }),
        "{error:?}"
    );
}
