//! Session configuration and execution-readiness tests, ported from `NativeLab`'s
//! `SessionConfigurationTests` and `SessionExecutionReadinessTests` (the pure rows; the REST rows
//! are in `client::configure_tests` and `client::client_tests`).

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::*;
use crate::client::sessions::SessionSummary;
use crate::client::sessions::test_support::{summary_of, wire};
use crate::client::test_support::fixture_json;
use crate::demo::{demo_catalog, demo_configuration};

fn summary(fields: &Value, previous: Option<&SessionSummary>) -> SessionSummary {
    summary_of(fields, previous, true)
}

fn configuration(fields: &Value, previous: Option<&SessionSummary>) -> SessionConfiguration {
    summary(fields, previous).configuration.unwrap()
}

/// The `wire` object of a fixture, minus the base keys the summary helper adds.
fn fixture_fields(path: &str, key: &str) -> Value {
    let mut value = fixture_json(path)[key].clone();
    if let Value::Object(object) = &mut value {
        for base in ["id", "status", "created_at", "permission_level"] {
            object.remove(base);
        }
    }
    value
}

fn choice(id: &str) -> ModelChoice {
    ModelChoice {
        id: id.into(),
        ..ModelChoice::default()
    }
}

fn efforts(values: &[&str]) -> Vec<ReasoningChoice> {
    values
        .iter()
        .map(|value| ReasoningChoice {
            reasoning_effort: (*value).to_owned(),
            description: None,
        })
        .collect()
}

#[test]
fn missing_identifiers_are_not_defaults_or_model_matches() {
    let model = choice("m1");
    assert!(!model.matches(None));
    assert!(model.matches(Some("m1")));
    assert!(!model.matches(Some("unknown")));
    let missing = configuration(
        &fixture_fields(
            "sessions/SessionConfiguration--MissingIdentifiersAreNotDefaultsOrModelMatches--missing.json",
            "wire",
        ),
        None,
    );
    assert_eq!(missing.harness_label(), "Harness not reported");
    assert_eq!(missing.model_label(), "Model not reported");
    assert_eq!(missing.effort_label(), "Not reported");
    let cleared = configuration(
        &fixture_fields(
            "sessions/SessionConfiguration--MissingIdentifiersAreNotDefaultsOrModelMatches--cleared.json",
            "wire",
        ),
        None,
    );
    assert_eq!(cleared.model_label(), "Harness default");
    assert_eq!(cleared.effort_label(), "Harness default");
}

#[test]
fn unknown_i_ds_remain_visible_and_unchanged_selection_is_valid() {
    let mut current = demo_configuration();
    current.harness = Some("future-harness".into());
    current.model_override = Some("provider.unlisted-model".into());
    current.effort = Some("future-effort".into());
    assert_eq!(
        current.identity_label(),
        "future-harness · provider.unlisted-model"
    );
    assert_eq!(current.effort_label(), "Future-Effort");
    assert_eq!(
        ConfigurationEdit::new(current.clone()).validate(&current),
        Ok(())
    );
}

#[test]
fn default_effort_uses_runner_default_not_agent_spec_model() {
    let mut current = demo_configuration();
    current.base_model = Some("sample-fast".into());
    assert_eq!(current.efforts(None), ["low", "high"]);
    assert_eq!(current.efforts(Some("sample-fast")), ["low"]);
    current.models = vec![ModelChoice {
        supported_reasoning_efforts: Some(efforts(&["low"])),
        ..choice("sample-fast")
    }];
    assert_eq!(current.efforts(None), Vec::<String>::new());
    assert_eq!(
        current.efforts(Some("not-advertised")),
        Vec::<String>::new()
    );
}

#[test]
fn selecting_model_clears_only_unsupported_effort() {
    let mut current = demo_configuration();
    current.effort = Some("high".into());
    let mut edit = ConfigurationEdit::new(current.clone());
    edit.select_model(Some("sample-fast".into()));
    assert_eq!(edit.effort, None);
    assert!(edit.has_changes());
    assert_eq!(edit.validate(&current), Ok(()));
    edit.effort = Some("high".into());
    assert!(edit.validate(&current).is_err());
    edit.effort = Some("low".into());
    assert_eq!(edit.validate(&current), Ok(()));
    // A supported effort survives a model change.
    let mut low = demo_configuration();
    low.effort = Some("low".into());
    let mut edit = ConfigurationEdit::new(low);
    edit.select_model(Some("sample-fast".into()));
    assert_eq!(edit.effort.as_deref(), Some("low"));
}

#[test]
fn hidden_and_unknown_models_cannot_be_new_selections() {
    let mut current = demo_configuration();
    current.models.push(ModelChoice {
        hidden: Some(true),
        ..choice("hidden")
    });
    for model in ["hidden", "unknown"] {
        let mut edit = ConfigurationEdit::new(current.clone());
        edit.model = Some(model.into());
        assert!(edit.validate(&current).is_err(), "{model}");
    }
    current.model_override = Some("hidden".into());
    assert_eq!(
        ConfigurationEdit::new(current.clone()).validate(&current),
        Ok(())
    );
    current.routing_mode = Some("on".into());
    let mut edit = ConfigurationEdit::new(current.clone());
    edit.model = Some("sample-fast".into());
    assert!(edit.validate(&current).is_err());
    assert_eq!(current.model_label(), "Smart routing");
}

#[test]
fn catalog_changes_revalidate_choices_but_do_not_invent_selection_conflict() {
    let original = demo_configuration();
    let mut edit = ConfigurationEdit::new(original.clone());
    edit.model = Some("sample-fast".into());
    let mut current = original.clone();
    current.models.retain(|model| model.id != "sample-fast");
    assert!(original.same_selection(&current));
    assert!(matches!(
        edit.validate(&current),
        Err(ConfigurationError::Unavailable(_))
    ));
    let mut current = original;
    current.effort = Some("high".into());
    assert_eq!(
        edit.validate(&current),
        Err(ConfigurationError::ChangedElsewhere)
    );
}

#[test]
fn harness_and_host_changes_do_not_borrow_stale_capabilities() {
    let path =
        "sessions/SessionConfiguration--HarnessAndHostChangesDoNotBorrowStaleCapabilities.json";
    let fixture = fixture_json(path);
    let detailed = summary(&fixture_fields(path, "base_wire"), None);
    let cases = fixture["cases"].as_array().unwrap();
    let switched = configuration(&cases[0]["fields"], Some(&detailed));
    assert_eq!(switched.models, []);
    assert_eq!(switched.wrapper, None);
    assert_eq!(switched.model_override, None);
    let moved = configuration(&cases[1]["fields"], Some(&detailed));
    assert_eq!(moved.host_online, None);
    assert_eq!(moved.runner_online, None);
}

#[test]
fn configuration_flags_decode_from_older_saved_configuration() {
    let fixture = fixture_json(
        "sessions/SessionConfiguration--ConfigurationFlagsDecodeFromOlderSavedConfiguration.json",
    );
    let mut saved = demo_configuration().to_value();
    for key in fixture["remove_keys"].as_array().unwrap() {
        saved.as_object_mut().unwrap().remove(key.as_str().unwrap());
    }
    let restored = SessionConfiguration::from_value(&saved).unwrap();
    assert_eq!(
        restored.model_override.as_deref(),
        fixture["expect"]["modelOverride"].as_str()
    );
    assert_eq!(restored.effort_reported, None);
    assert_eq!(
        SessionConfiguration::from_value(&demo_configuration().to_value()),
        Ok(demo_configuration())
    );
    assert!(SessionConfiguration::from_value(&json!({"hostOnline": "yes"})).is_err());
}

#[test]
fn harness_safety_requires_correct_online_configured_host_and_history_support() {
    let current = demo_configuration();
    let target = HarnessChoice {
        id: "target".into(),
        name: "Claude".into(),
        harness: Some("claude-native".into()),
        builtin: Some(true),
    };
    assert_eq!(demo_catalog().unavailable_reason(&target, &current), None);
    let unsafe_target = HarnessChoice {
        id: "cursor".into(),
        harness: Some("cursor-native".into()),
        ..target.clone()
    };
    assert!(
        demo_catalog()
            .unavailable_reason(&unsafe_target, &current)
            .is_some()
    );
    let host = |host_id: &str, readiness: HarnessReadiness| ConfigurationHost {
        host_id: host_id.into(),
        name: "Host".into(),
        status: "online".into(),
        configured_harnesses: Some(BTreeMap::from([
            ("claude-native".to_owned(), readiness),
            ("agents_sdk".to_owned(), readiness),
        ])),
    };
    let other_host = ConfigurationCatalog {
        agents: vec![target.clone()],
        host: Some(host("other", HarnessReadiness::Ready)),
        ..ConfigurationCatalog::default()
    };
    assert!(other_host.unavailable_reason(&target, &current).is_some());
    let needs_auth = ConfigurationCatalog {
        agents: vec![target.clone()],
        host: Some(host("demo-host", HarnessReadiness::NeedsAuthentication)),
        ..ConfigurationCatalog::default()
    };
    assert_eq!(
        needs_auth.unavailable_reason(&target, &current).as_deref(),
        Some(crate::creation::AUTHENTICATION_REQUIRED)
    );
    // An SDK harness's sign-in is only a warning: its agent may bring its own credentials.
    let sdk_target = HarnessChoice {
        id: "sdk".into(),
        harness: Some("agents_sdk".into()),
        ..target.clone()
    };
    assert_eq!(needs_auth.unavailable_reason(&sdk_target, &current), None);
    let mut child = current.clone();
    child.parent_id = Some("parent".into());
    assert!(demo_catalog().unavailable_reason(&target, &child).is_some());
    let same = HarnessChoice {
        id: "different-clone".into(),
        harness: Some("native-codex".into()),
        ..target.clone()
    };
    assert_eq!(
        demo_catalog()
            .unavailable_reason(&same, &current)
            .as_deref(),
        Some("Current harness")
    );
    let scoped = HarnessChoice {
        id: "scoped".into(),
        builtin: Some(false),
        ..target
    };
    assert!(
        demo_catalog()
            .unavailable_reason(&scoped, &current)
            .is_some()
    );
}

#[test]
fn sdk_harnesses_are_recognized_by_every_server_spelling() {
    for harness in [
        "claude-sdk",
        "claude_sdk",
        "claude",
        "openai-agents",
        "openai-agents-sdk",
        "agents_sdk",
        "antigravity",
        "agy",
        "google-antigravity",
    ] {
        assert!(is_sdk_harness(Some(harness)), "{harness}");
    }
    for harness in [
        "claude-native",
        "native-claude",
        "codex",
        "codex-native",
        "antigravity-native",
        "agy-native",
        "pi",
    ] {
        assert!(!is_sdk_harness(Some(harness)), "{harness}");
    }
    assert!(!is_sdk_harness(None));
}

#[test]
fn provider_families_match_backend_carry_settings_policy() {
    for harness in [
        "codex-native",
        "native-codex",
        "qwen",
        "qwen-native",
        "native-qwen",
        "antigravity",
        "openai-agents-sdk",
    ] {
        assert_eq!(provider_family(Some(harness)), Some("openai"), "{harness}");
    }
    assert_eq!(provider_family(Some("native-claude")), Some("anthropic"));
    assert_eq!(provider_family(Some("native-antigravity")), Some("gemini"));
    assert_eq!(provider_family(Some("pi-native")), None);
    assert_eq!(provider_family(Some("unknown")), None);
}

#[test]
fn readiness_uses_execution_metadata_rather_than_harness_or_permissions() {
    let fixture = fixture_json(
        "sessions/SessionExecutionReadiness--ReadinessUsesExecutionMetadataRatherThanHarnessOrPermissions.json",
    );
    let cases = fixture["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 15);
    for case in cases {
        let label = case["label"].as_str().unwrap();
        let value = summary(&case["fields"], None);
        let available = case["expect_available"].as_bool().unwrap();
        assert_eq!(
            value
                .configuration
                .as_ref()
                .unwrap()
                .execution_unavailable_reason()
                .is_none(),
            available,
            "{label}"
        );
        assert!(!value.is_read_only, "{label}");
        assert!(value.can_rename(), "{label}");
    }
}

#[test]
fn sparse_projection_keeps_no_connection_reason_and_write_permissions() {
    let fixture = fixture_json(
        "sessions/SessionExecutionReadiness--SparseProjectionKeepsNoConnectionReasonAndWritePermissions.json",
    );
    let initial = summary(&fixture["base_fields"], None);
    let case = &fixture["cases"][0];
    let projected = summary_of(
        &case["fields"],
        Some(&initial),
        case["include_permission"].as_bool().unwrap(),
    );
    let reason = |summary: &SessionSummary| {
        summary
            .configuration
            .as_ref()
            .unwrap()
            .execution_unavailable_reason()
    };
    assert_eq!(reason(&projected), reason(&initial));
    assert!(reason(&projected).unwrap().contains("tap New session"));
    assert!(!projected.is_read_only);
    assert_eq!(
        projected.configuration.as_ref().unwrap().runner_bound,
        Some(false)
    );
    assert_eq!(projected.permission_level, Some(4));
}

#[test]
fn sparse_projection_preserves_managed_resume_but_explicit_false_disables_it() {
    let fixture = fixture_json(
        "sessions/SessionExecutionReadiness--SparseProjectionPreservesManagedResumeButExplicitFalseDisablesIt.json",
    );
    let initial = summary(&fixture["base_fields"], None);
    let projected = summary(&fixture["cases"][0]["fields"], Some(&initial));
    let configuration = projected.configuration.clone().unwrap();
    assert_eq!(configuration.host_resumable, Some(true));
    assert_eq!(configuration.execution_unavailable_reason(), None);
    let disabled = configuration_of(&fixture["cases"][1]["fields"], &projected);
    assert_eq!(disabled.host_resumable, Some(false));
    assert!(
        disabled
            .execution_unavailable_reason()
            .unwrap()
            .contains("host is offline")
    );
}

fn configuration_of(fields: &Value, previous: &SessionSummary) -> SessionConfiguration {
    configuration(fields, Some(previous))
}

#[test]
fn explicit_null_clears_resume_and_changing_hosts_clears_old_liveness() {
    let fixture = fixture_json(
        "sessions/SessionExecutionReadiness--ExplicitNullClearsResumeAndChangingHostsClearsOldLiveness.json",
    );
    let initial = summary(&fixture["base_fields"], None);
    let cases = fixture["cases"].as_array().unwrap();
    let cleared = configuration_of(&cases[0]["fields"], &initial);
    assert_eq!(cleared.host_resumable, None);
    assert!(cleared.execution_unavailable_reason().is_some());
    let moved = configuration_of(&cases[1]["fields"], &initial);
    assert_eq!(moved.host_online, None);
    assert_eq!(moved.runner_online, None);
    assert_eq!(moved.host_resumable, None);
    assert_eq!(moved.execution_unavailable_reason(), None);
    let unbound = configuration_of(&cases[2]["fields"], &initial);
    assert_eq!(unbound.host_resumable, None);
    assert!(unbound.execution_unavailable_reason().is_some());
}

#[test]
fn a_session_whose_sandbox_is_starting_takes_messages_until_the_launch_ends() {
    // What a new sandbox session reports: a native harness, no runner and no host yet.
    let unbound = json!({
        "harness": "codex-native", "runner_id": null, "runner_online": false, "host_id": null
    });
    let with = |status: Value| {
        let mut fields = unbound.clone();
        fields["sandbox_status"] = status;
        fields
    };
    let reason = configuration(&unbound, None).execution_unavailable_reason();
    assert!(reason.unwrap().contains("no execution connection"));
    for stage in [
        "provisioning",
        "action_required",
        "cloning",
        "starting",
        "connecting",
    ] {
        let launching = configuration(&with(json!({ "stage": stage })), None);
        assert_eq!(launching.sandbox_launching, Some(true), "{stage}");
        assert_eq!(launching.execution_unavailable_reason(), None, "{stage}");
    }
    let started = summary(&with(json!({ "stage": "provisioning" })), None);
    // A read that says nothing of the launch leaves the last answer standing.
    let silent = configuration_of(&unbound, &started);
    assert_eq!(silent.sandbox_launching, Some(true));
    for ended in [
        json!({ "stage": "failed", "error": "quota" }),
        json!({ "stage": "ready" }),
        Value::Null,
    ] {
        let over = configuration_of(&with(ended.clone()), &started);
        assert_eq!(over.sandbox_launching, Some(false), "{ended}");
        assert!(over.execution_unavailable_reason().is_some(), "{ended}");
    }
    // The sandbox's host arriving ends the launch, whatever was last said of it.
    let bound = configuration_of(
        &json!({
            "harness": "codex-native", "host_id": "sandbox-1", "host_online": true,
            "runner_id": "runner-1", "runner_online": true
        }),
        &started,
    );
    assert_eq!(bound.sandbox_launching, None);
    assert_eq!(bound.execution_unavailable_reason(), None);
    let saved = started.configuration.unwrap();
    assert_eq!(
        SessionConfiguration::from_value(&saved.to_value()).unwrap(),
        saved
    );
}

#[test]
fn harness_change_does_not_erase_session_execution_metadata() {
    let fixture = fixture_json(
        "sessions/SessionExecutionReadiness--HarnessChangeDoesNotEraseSessionExecutionMetadata.json",
    );
    let initial = summary(&fixture["base_fields"], None);
    let changed = configuration_of(&fixture["cases"][0]["fields"], &initial);
    assert_eq!(changed.host_id.as_deref(), Some("managed"));
    assert_eq!(changed.host_online, Some(false));
    assert_eq!(changed.runner_online, Some(false));
    assert_eq!(changed.host_resumable, Some(true));
    assert_eq!(changed.execution_unavailable_reason(), None);
}

#[test]
fn older_saved_configuration_without_resumability_remains_decodable() {
    let fixture = fixture_json(
        "sessions/SessionExecutionReadiness--OlderSavedConfigurationWithoutResumabilityRemainsDecodable.json",
    );
    let value = SessionConfiguration::from_value(&fixture["saved_configuration"]).unwrap();
    assert_eq!(value.host_resumable, None);
    assert_eq!(value.execution_unavailable_reason(), None);
}

#[test]
fn unbound_failed_session_keeps_failure_history_separate_from_readiness() {
    let fixture = fixture_json(
        "sessions/SessionExecutionReadiness--UnboundFailedSessionKeepsFailureHistorySeparateFromReadiness.json",
    );
    let value = summary(&fixture["cases"][0]["fields"], None);
    assert!(value.failure_message.is_some());
    assert!(
        value
            .configuration
            .as_ref()
            .unwrap()
            .execution_unavailable_reason()
            .unwrap()
            .contains("no execution connection")
    );
    assert!(!value.is_read_only);
    // The wire helper is the same one the summary tests use.
    assert_eq!(wire(&json!({}), true)["permission_level"], 4);
}

#[test]
fn model_choice_round_trips_and_keeps_absent_efforts_distinct() {
    let absent = ModelChoice::from_value(&json!({"id": "m"})).unwrap();
    let empty =
        ModelChoice::from_value(&json!({"id": "m", "supportedReasoningEfforts": []})).unwrap();
    assert_eq!(absent.supported_reasoning_efforts, None);
    assert_eq!(empty.supported_reasoning_efforts, Some(Vec::new()));
    let full = ModelChoice::from_value(&json!({
        "id": "m", "model": "wire", "displayName": "Shown", "hidden": false, "isDefault": true,
        "defaultReasoningEffort": "low", "supportedReasoningEfforts": [{"reasoningEffort": "low"}]
    }))
    .unwrap();
    assert_eq!(ModelChoice::from_value(&full.to_value()), Ok(full.clone()));
    assert_eq!(full.title(), "Shown");
    assert_eq!(full.value(), "wire");
    assert!(full.matches(Some("wire")) && full.matches(Some("m")));
}

#[test]
fn efforts_depend_on_the_wrapper_and_the_catalog() {
    let of_wrapper = |wrapper: &str| {
        let mut configuration = demo_configuration();
        configuration.wrapper = Some(wrapper.to_owned());
        configuration.models = Vec::new();
        configuration.efforts(None)
    };
    assert_eq!(of_wrapper("pi-native-ui"), Vec::<String>::new());
    assert_eq!(
        of_wrapper("claude-code-native-ui"),
        CLAUDE_EFFORTS.map(str::to_owned).to_vec()
    );
}

#[test]
fn a_harness_row_names_itself_and_readiness_gaps_are_explained() {
    let current = demo_configuration();
    let target = HarnessChoice {
        id: "target".into(),
        name: "Claude".into(),
        harness: Some("claude-native".into()),
        builtin: Some(true),
    };
    assert_eq!(target.title(), harness_label(Some("claude-native")));
    let readiness = |ready: Option<HarnessReadiness>| {
        let catalog = ConfigurationCatalog {
            agents: vec![target.clone()],
            host: Some(ConfigurationHost {
                host_id: "demo-host".into(),
                name: "Host".into(),
                status: "online".into(),
                configured_harnesses: ready
                    .map(|ready| BTreeMap::from([("claude-native".to_owned(), ready)])),
            }),
            ..ConfigurationCatalog::default()
        };
        catalog.unavailable_reason(&target, &current)
    };
    assert_eq!(
        readiness(None).as_deref(),
        Some("Host readiness has not been reported.")
    );
    assert_eq!(
        readiness(Some(HarnessReadiness::NotReady)).as_deref(),
        Some("This harness is not configured on the host.")
    );
}

#[test]
fn a_session_read_reports_its_sandbox_launch_until_it_ends_or_a_host_arrives() {
    use crate::sandbox_state::LaunchStage;
    let unbound = json!({
        "harness": "codex-native", "runner_id": null, "runner_online": false, "host_id": null
    });
    let with = |status: Value| {
        let mut fields = unbound.clone();
        fields["sandbox_status"] = status;
        fields
    };
    let waiting = summary(
        &with(json!({
            "stage": "action_required", "provider": "arclet", "details": "Sign in on your laptop."
        })),
        None,
    );
    let launch = waiting
        .configuration
        .clone()
        .and_then(|configuration| configuration.sandbox_launch)
        .expect("a launch");
    assert_eq!(launch.stage, LaunchStage::ActionRequired);
    assert_eq!(launch.provider.as_deref(), Some("arclet"));
    assert_eq!(launch.details.as_deref(), Some("Sign in on your laptop."));
    // A read that says nothing of the launch leaves the last answer standing.
    assert_eq!(
        configuration_of(&unbound, &waiting).sandbox_launch,
        Some(launch)
    );
    let failed = configuration_of(
        &with(json!({"stage": "failed", "error": "quota"})),
        &waiting,
    )
    .sandbox_launch
    .expect("a failed launch");
    assert_eq!(
        (failed.stage, failed.error.as_deref()),
        (LaunchStage::Failed, Some("quota"))
    );
    for ended in [json!({ "stage": "ready" }), Value::Null] {
        let over = configuration_of(&with(ended.clone()), &waiting);
        assert_eq!(over.sandbox_launch, None, "{ended}");
    }
    // The sandbox's host arriving ends the launch, whatever was last said of it.
    let bound = configuration_of(
        &json!({"harness": "codex-native", "host_id": "sandbox-1", "host_online": true}),
        &waiting,
    );
    assert_eq!(bound.sandbox_launch, None);
    let mut saved = waiting.configuration.expect("configuration").to_value();
    assert_eq!(saved["sandboxLaunch"]["stage"], "action_required");
    let restored = SessionConfiguration::from_value(&saved).expect("decodes");
    assert_eq!(
        restored.sandbox_launch.map(|launch| launch.stage),
        Some(LaunchStage::ActionRequired)
    );
    saved["sandboxLaunch"] = Value::Null;
    let cleared = SessionConfiguration::from_value(&saved).expect("decodes");
    assert_eq!(cleared.sandbox_launch, None);
    saved["sandboxLaunch"] = json!({"stage": 1});
    assert!(SessionConfiguration::from_value(&saved).is_err());
}
