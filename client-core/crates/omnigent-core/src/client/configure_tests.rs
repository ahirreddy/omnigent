//! Session configuration REST tests, ported from `NativeLab`'s `SessionConfigurationTests`.

use std::pin::pin;

use futures::executor::block_on;
use omnigent_protocol::{FromWire, ServerStreamEvent};
use serde_json::{Value, json};

use super::SessionError;
use super::sessions::SessionSummary;
use super::sessions::test_support::{summary_of, wire};
use super::test_support::{
    Reply, RouteTransport, envelopes, fixture_lines, lines_after_connect, live, still_pending,
};
use crate::config::session::{ConfigurationEdit, ConfigurationError};
use crate::reconcile::ConversationSync;

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
fn smart_routing_is_one_patch_whose_acknowledgement_is_checked() {
    let routed = merged(&json!({"cost_control_mode_override": "on"}));
    for cached in [false, true] {
        let transport = RouteTransport::local();
        transport.respond(Some("PATCH"), PATH, None, patched(&routed));
        let core = live(transport);
        if cached {
            core.apply_session_rows(vec![wire(&fields(), true)])
                .unwrap();
        }
        let saved = block_on(core.set_smart_routing(true, "conv_a")).unwrap();
        assert_eq!(
            saved.configuration.unwrap().routing_mode.as_deref(),
            Some("on")
        );
        assert_eq!(
            lines_after_connect(&core),
            ["PATCH /v1/sessions/conv_a"],
            "cached row: {cached}"
        );
        assert_eq!(
            mutation_bodies(core.transport()),
            vec![json!({"cost_control_mode_override": "on"})]
        );
        assert_eq!(
            core.cached_summary("conv_a")
                .unwrap()
                .configuration
                .unwrap()
                .routing_mode
                .as_deref(),
            Some("on")
        );

        // The acknowledgement still shows the mode on.
        let error = block_on(core.set_smart_routing(false, "conv_a")).unwrap_err();
        assert!(
            matches!(error, SessionError::DeliveryUncertain { .. }),
            "{error:?}"
        );
    }
}

#[test]
fn smart_routing_is_refused_by_the_cached_row_or_a_closed_stream_without_a_request() {
    let core = live(RouteTransport::local());
    core.apply_session_rows(vec![wire(&fields(), false)])
        .unwrap();
    assert_eq!(
        block_on(core.set_smart_routing(true, "conv_a")),
        Err(SessionError::ReadOnly)
    );
    // No cached row and no stream: nothing says the session is ready for the change.
    assert_eq!(
        block_on(core.set_smart_routing(true, "conv_b")),
        Err(SessionError::StreamNotReady)
    );
    assert_eq!(lines_after_connect(&core), Vec::<String>::new());
}

#[test]
fn a_refused_smart_routing_patch_reads_as_the_removed_check_did() {
    for (status, expected) in [
        (403, SessionError::ReadOnly),
        (
            404,
            SessionError::SessionNotFound {
                session_id: "conv_a".into(),
            },
        ),
    ] {
        let transport = RouteTransport::local();
        transport.respond(Some("PATCH"), PATH, None, Reply::json(status, "{}"));
        let core = live(transport);
        assert_eq!(
            block_on(core.set_smart_routing(true, "conv_a")),
            Err(expected),
            "{status}"
        );
    }
}

fn patched(fields: &Value) -> Reply {
    Reply::json(200, wire(fields, true).to_string())
}

fn switch_script() -> Vec<crate::client::test_support::Envelope> {
    envelopes(&format!(
        "{CONFIG}HarnessSwitchRetainsSessionAndChecksTargetAcknowledgement.jsonl"
    ))
}

#[test]
fn resetting_a_model_needs_the_server_to_drop_it() {
    let transport = RouteTransport::local();
    stub_session(&transport, &fields());
    transport.respond(Some("PATCH"), PATH, None, patched(&fields()));
    let core = live(transport);
    let mut edit = edit_from(&fields());
    edit.select_model(None);
    assert!(matches!(
        block_on(core.apply_configuration(&edit, "conv_a")),
        Err(SessionError::DeliveryUncertain { .. })
    ));
}

#[test]
fn an_effort_only_edit_skips_the_model_patch() {
    let transport = RouteTransport::local();
    stub_session(&transport, &fields());
    let acknowledged = merged(&json!({"reasoning_effort": "low"}));
    transport.respond(Some("PATCH"), PATH, None, patched(&acknowledged));
    let core = live(transport);
    let mut edit = edit_from(&fields());
    edit.effort = Some("low".into());
    block_on(core.apply_configuration(&edit, "conv_a")).unwrap();
    assert_eq!(
        mutation_bodies(core.transport()),
        [json!({"reasoning_effort": "low"})]
    );
}

#[test]
fn a_selection_changed_between_the_two_patches_stops_the_second() {
    let transport = RouteTransport::local();
    let acknowledged = merged(&json!({"model_override": "sample-fast"}));
    transport.enqueue(
        "GET",
        PATH,
        vec![
            patched(&fields()),
            patched(&merged(&json!({"model_override": "someone-elses"}))),
        ],
    );
    transport.respond(Some("PATCH"), PATH, None, patched(&acknowledged));
    let core = live(transport);
    let mut edit = edit_from(&fields());
    edit.select_model(Some("sample-fast".into()));
    edit.effort = Some("low".into());
    assert!(block_on(core.apply_configuration(&edit, "conv_a")).is_err());
    assert_eq!(mutation_bodies(core.transport()).len(), 1, "only the model");
}

#[test]
fn an_acknowledgement_naming_another_session_is_uncertain() {
    let mut other = wire(&fields(), true);
    other["id"] = json!("conv_b");
    let other = Reply::json(200, other.to_string());

    let transport = RouteTransport::local();
    stub_session(&transport, &fields());
    transport.respond(Some("PATCH"), PATH, None, other.clone());
    let core = live(transport);
    let mut edit = edit_from(&fields());
    edit.select_model(Some("sample-fast".into()));
    assert!(matches!(
        block_on(core.apply_configuration(&edit, "conv_a")),
        Err(SessionError::DeliveryUncertain { detail }) if detail.contains("another session")
    ));

    let transport = RouteTransport::local();
    stub_session(&transport, &claude_fields("default"));
    transport.respond(Some("PATCH"), PATH, None, other.clone());
    let core = live(transport);
    assert!(matches!(
        block_on(core.set_approval_mode("acceptEdits", "conv_a")),
        Err(SessionError::DeliveryUncertain { detail }) if detail.contains("another session")
    ));

    let baseline = summary(&fields()).configuration.unwrap();
    let transport = RouteTransport::local();
    for envelope in &switch_script()[..3] {
        transport.respond(Some("GET"), &envelope.path, None, envelope.reply.clone());
    }
    transport.respond(
        Some("POST"),
        "/v1/sessions/conv_a/switch-agent",
        None,
        other,
    );
    let core = live(transport);
    assert!(matches!(
        block_on(core.switch_harness("target", &baseline, "conv_a")),
        Err(SessionError::DeliveryUncertain { detail }) if detail.contains("another session")
    ));
}

#[test]
fn a_crossing_event_makes_a_switch_or_approval_change_read_again() {
    let event =
        ServerStreamEvent::from_value(json!({"type": "session.model", "model": "new"})).unwrap();
    let baseline = summary(&fields()).configuration.unwrap();
    let transport = RouteTransport::local();
    for envelope in &switch_script()[..3] {
        transport.respond(Some("GET"), &envelope.path, None, envelope.reply.clone());
    }
    let switch = "/v1/sessions/conv_a/switch-agent";
    transport.respond(Some("POST"), switch, None, patched(&fields()));
    let gate = transport.gate("POST", switch);
    let core = live(transport);
    let mut operation = pin!(core.switch_harness("target", &baseline, "conv_a"));
    assert!(still_pending(operation.as_mut()));
    core.record_stream_event("conv_a", &event);
    gate.open();
    assert!(matches!(
        block_on(operation),
        Err(SessionError::DeliveryUncertain { .. })
    ));

    let transport = RouteTransport::local();
    transport.enqueue(
        "GET",
        PATH,
        vec![
            patched(&claude_fields("default")),
            patched(&claude_fields("acceptEdits")),
        ],
    );
    transport.respond(
        Some("PATCH"),
        PATH,
        None,
        patched(&claude_fields("default")),
    );
    let gate = transport.gate("PATCH", PATH);
    let core = live(transport);
    let mut operation = pin!(core.set_approval_mode("acceptEdits", "conv_a"));
    assert!(still_pending(operation.as_mut()));
    core.record_stream_event("conv_a", &event);
    gate.open();
    let saved = block_on(operation).unwrap();
    assert_eq!(
        saved.configuration.unwrap().approval_mode.as_deref(),
        Some("acceptEdits"),
        "the fresh read wins over the stale acknowledgement"
    );
}

#[test]
fn approval_mode_needs_an_owner_a_live_unarchived_session_and_a_host() {
    let transport = RouteTransport::local();
    let mut read_only = wire(&claude_fields("default"), false);
    read_only["permission_level"] = json!(1);
    transport.respond(
        Some("GET"),
        PATH,
        None,
        Reply::json(200, read_only.to_string()),
    );
    let core = live(transport);
    assert_eq!(
        block_on(core.set_approval_mode("acceptEdits", "conv_a")).unwrap_err(),
        SessionError::ReadOnly
    );

    let transport = RouteTransport::local();
    let mut archived = claude_fields("default");
    archived["archived"] = json!(true);
    stub_session(&transport, &archived);
    let core = live(transport);
    assert_eq!(
        block_on(core.set_approval_mode("acceptEdits", "conv_a")).unwrap_err(),
        SessionError::Archived
    );

    let transport = RouteTransport::local();
    stub_session(&transport, &claude_fields("default"));
    let core = super::test_support::connected(transport);
    assert_eq!(
        block_on(core.set_approval_mode("acceptEdits", "conv_a")).unwrap_err(),
        SessionError::StreamNotReady
    );

    let transport = RouteTransport::local();
    let mut offline = claude_fields("default");
    offline["host_online"] = json!(false);
    offline["runner_online"] = json!(false);
    stub_session(&transport, &offline);
    let core = live(transport);
    assert!(matches!(
        block_on(core.set_approval_mode("acceptEdits", "conv_a")),
        Err(SessionError::Configuration(ConfigurationError::Unavailable(reason)))
            if reason.contains("Reconnect")
    ));
}

#[test]
fn an_expired_sign_in_during_the_host_preview_ends_the_read() {
    let transport = RouteTransport::local();
    transport.script(&format!(
        "{CONFIG}HostPreviewFailureDoesNotHideHarnessCatalog.jsonl"
    ));
    transport.enqueue("GET", MODEL_OPTIONS, vec![Reply::json(401, "{}")]);
    let core = live(transport);
    assert!(block_on(core.configuration_catalog("conv_a")).is_ok());
    let got = block_on(core.configuration_catalog("conv_a"));
    assert!(
        matches!(got, Err(SessionError::Unauthorized { .. })),
        "{got:?}"
    );
}

#[test]
fn a_change_during_the_model_preview_stops_the_edit_before_any_write() {
    let transport = RouteTransport::local();
    let previewing = merged(&json!({"model_options": []}));
    stub_session(&transport, &previewing);
    transport.ok(
        MODEL_OPTIONS,
        r#"{"models":[{"id":"sample-balanced","supportedReasoningEfforts":[{"reasoningEffort":"low"}]}]}"#,
    );
    let gate = transport.gate("GET", MODEL_OPTIONS);
    let core = live(transport);
    let mut edit = edit_from(&previewing);
    edit.effort = Some("low".into());
    let mut apply = pin!(core.apply_configuration(&edit, "conv_a"));
    assert!(still_pending(apply.as_mut()));
    let event =
        ServerStreamEvent::from_value(json!({"type": "session.model", "model": "new"})).unwrap();
    core.record_stream_event("conv_a", &event);
    gate.open();
    assert_eq!(
        block_on(apply),
        Err(SessionError::Configuration(
            ConfigurationError::ChangedElsewhere
        ))
    );
    assert_eq!(mutation_bodies(core.transport()), Vec::<Value>::new());
}

#[test]
fn a_switch_to_a_target_the_catalog_rules_out_says_why_and_never_posts() {
    let transport = RouteTransport::local();
    for envelope in &switch_script()[..3] {
        transport.respond(Some("GET"), &envelope.path, None, envelope.reply.clone());
    }
    transport.respond(
        Some("GET"),
        "/v1/hosts",
        None,
        Reply::json(
            200,
            r#"{"hosts":[{"host_id":"demo-host","name":"Host","status":"offline"}]}"#,
        ),
    );
    let core = live(transport);
    let baseline = summary(&fields()).configuration.unwrap();
    assert_eq!(
        block_on(core.switch_harness("target", &baseline, "conv_a")),
        Err(SessionError::Configuration(
            ConfigurationError::Unavailable("The session's host must be online.".into())
        ))
    );
    assert_eq!(mutation_bodies(core.transport()), Vec::<Value>::new());
}

#[test]
fn a_read_crossed_by_a_newer_row_returns_the_newer_row() {
    let transport = RouteTransport::local();
    stub_session(&transport, &merged(&json!({"title": "Stale"})));
    transport.ok(
        "/v1/sessions/conv_a/items",
        r#"{"data":[],"has_more":false}"#,
    );
    let gate = transport.gate("GET", PATH);
    let core = live(transport);
    let mut read = pin!(core.conversation_snapshot("conv_a"));
    assert!(still_pending(read.as_mut()));
    core.apply_session_rows(vec![wire(&merged(&json!({"title": "Newer"})), true)])
        .unwrap();
    gate.open();
    assert_eq!(block_on(read).unwrap().summary.title, "Newer");
    assert_eq!(core.cached_summary("conv_a").unwrap().title, "Newer");
}

#[test]
fn a_changed_files_refresh_overlapping_a_settings_save_keeps_its_result() {
    const CHANGES: &str = "/v1/sessions/conv_a/resources/environments/default/changes";
    let transport = RouteTransport::local();
    stub_session(&transport, &fields());
    transport.ok(
        "/v1/sessions/conv_a/items",
        r#"{"data":[],"has_more":false}"#,
    );
    let acknowledged = merged(&json!({"reasoning_effort": "low"}));
    transport.respond(Some("PATCH"), PATH, None, patched(&acknowledged));
    transport.ok(
        CHANGES,
        r#"{"entries":[{"path":"src/lib.rs","status":"modified"}]}"#,
    );
    let save_gate = transport.gate("PATCH", PATH);
    let changes_gate = transport.gate("GET", CHANGES);
    let core = live(transport);
    let mut sync = ConversationSync::new("conv_a");
    let request = sync.open_stream();
    block_on(core.hydrate(&mut sync, &request)).unwrap();
    let mut edit = edit_from(&fields());
    edit.effort = Some("low".into());
    // The save's snapshot read leaves an undelivered event, delivered while the refresh reads.
    let mut save = pin!(core.apply_configuration(&edit, "conv_a"));
    assert!(still_pending(save.as_mut()));
    let refreshed = {
        let mut refresh = pin!(core.refresh_changed_files(&mut sync, "default"));
        assert!(still_pending(refresh.as_mut()));
        save_gate.open();
        block_on(save).unwrap();
        changes_gate.open();
        block_on(refresh)
    };
    assert!(refreshed.is_some(), "the refresh lost its result");
    let files = sync
        .published()
        .and_then(|snapshot| snapshot.event_state.changed_files.clone())
        .unwrap();
    assert!(files.contains_key("default"));
}
