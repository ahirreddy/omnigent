//! Session configuration: records both ways, the menus' rules, and the REST calls.

use omnigent_core::config::session as core;
use omnigent_core::creation::HarnessReadiness as CoreReadiness;
use serde_json::json as value;

use crate::configuration::{
    ConfigurationCatalog, ConfigurationEdit, ConfigurationHost, HarnessChoice, HarnessReadiness,
    HarnessStatus, ModelChoice, ReasoningChoice, SessionConfiguration, configuration_edit,
    configuration_efforts, configuration_labels, configuration_select_model,
    configuration_supports_effort, configuration_supports_models, configuration_supports_steering,
    configuration_with_catalog_models, execution_unavailable_reason, harness_map, harness_statuses,
    harness_switch_unavailable_reason,
};
use crate::errors::CoreError;
use crate::test_support::{Harness, connected, json};

fn codex() -> SessionConfiguration {
    SessionConfiguration {
        agent_id: Some("clone".into()),
        harness: Some("codex-native".into()),
        wrapper: Some("codex-native-ui".into()),
        model_override: Some("fast".into()),
        effort: Some("high".into()),
        host_id: Some("demo-host".into()),
        host_online: Some(true),
        runner_online: Some(true),
        models: vec![model("balanced", &["high", "low"]), model("fast", &["low"])],
        ..core::SessionConfiguration::default().into()
    }
}

fn model(id: &str, efforts: &[&str]) -> ModelChoice {
    ModelChoice {
        id: id.to_owned(),
        model: None,
        display_name: None,
        description: None,
        hidden: None,
        is_default: None,
        default_reasoning_effort: None,
        supported_reasoning_efforts: Some(
            efforts
                .iter()
                .map(|effort| ReasoningChoice {
                    reasoning_effort: (*effort).to_owned(),
                    description: None,
                })
                .collect(),
        ),
        title: id.to_owned(),
        value: id.to_owned(),
    }
}

#[test]
fn a_reasoning_choice_and_a_model_keep_every_field_both_ways() {
    let choice = ReasoningChoice {
        reasoning_effort: "high".into(),
        description: Some("deep".into()),
    };
    let on_core = core::ReasoningChoice::from(choice.clone());
    assert_eq!(on_core.reasoning_effort, "high");
    assert_eq!(on_core.description.as_deref(), Some("deep"));
    assert_eq!(ReasoningChoice::from(on_core), choice);

    let on_core = core::ModelChoice {
        id: "id".into(),
        model: Some("provider".into()),
        display_name: Some("Shown".into()),
        description: Some("Text".into()),
        hidden: Some(true),
        is_default: Some(false),
        default_reasoning_effort: Some("low".into()),
        supported_reasoning_efforts: Some(vec![core::ReasoningChoice {
            reasoning_effort: "low".into(),
            description: None,
        }]),
    };
    let title = on_core.title().to_owned();
    let wire_value = on_core.value().to_owned();
    let mapped = ModelChoice::from(on_core.clone());
    assert_eq!(mapped.title, title);
    assert_eq!(mapped.value, wire_value);
    assert_eq!(mapped.id, "id");
    assert_eq!(mapped.model.as_deref(), Some("provider"));
    assert_eq!(mapped.display_name.as_deref(), Some("Shown"));
    assert_eq!(mapped.description.as_deref(), Some("Text"));
    assert_eq!(mapped.hidden, Some(true));
    assert_eq!(mapped.is_default, Some(false));
    assert_eq!(mapped.default_reasoning_effort.as_deref(), Some("low"));
    assert_eq!(core::ModelChoice::from(mapped), on_core);
}

#[test]
fn a_configuration_edit_and_a_harness_choice_keep_every_field_both_ways() {
    let edit = ConfigurationEdit {
        baseline: codex(),
        model: Some("balanced".into()),
        effort: Some("low".into()),
    };
    let on_core = core::ConfigurationEdit::from(edit.clone());
    assert_eq!(on_core.model.as_deref(), Some("balanced"));
    assert_eq!(on_core.effort.as_deref(), Some("low"));
    assert_eq!(on_core.baseline.agent_id.as_deref(), Some("clone"));
    assert_eq!(ConfigurationEdit::from(on_core), edit);

    let on_core = core::HarnessChoice {
        id: "ag".into(),
        name: "Claude".into(),
        harness: Some("claude-native".into()),
        builtin: Some(true),
    };
    let mapped = HarnessChoice::from(on_core.clone());
    assert_eq!(mapped.id, "ag");
    assert_eq!(mapped.name, "Claude");
    assert_eq!(mapped.harness.as_deref(), Some("claude-native"));
    assert_eq!(mapped.builtin, Some(true));
    assert_eq!(mapped.title, on_core.title());
    assert_eq!(mapped.preserves_history, on_core.preserves_history());
    assert_eq!(core::HarnessChoice::from(mapped), on_core);
}

#[test]
fn every_readiness_and_a_host_and_catalog_map_both_ways() {
    for (on_core, on_ffi) in [
        (CoreReadiness::Ready, HarnessReadiness::Ready),
        (CoreReadiness::NotReady, HarnessReadiness::NotReady),
        (
            CoreReadiness::NeedsAuthentication,
            HarnessReadiness::NeedsAuthentication,
        ),
        (CoreReadiness::Unknown, HarnessReadiness::Unknown),
    ] {
        assert_eq!(HarnessReadiness::from(on_core), on_ffi);
        assert_eq!(CoreReadiness::from(on_ffi), on_core);
    }
    let statuses = vec![HarnessStatus {
        harness: "claude-native".into(),
        readiness: HarnessReadiness::NotReady,
    }];
    assert_eq!(harness_statuses(harness_map(statuses.clone())), statuses);

    let host = ConfigurationHost {
        host_id: "h".into(),
        name: "Mac".into(),
        status: "online".into(),
        configured_harnesses: Some(statuses),
    };
    let on_core = core::ConfigurationHost::from(host.clone());
    assert_eq!(on_core.host_id, "h");
    assert_eq!(on_core.name, "Mac");
    assert_eq!(on_core.status, "online");
    assert_eq!(ConfigurationHost::from(on_core), host);

    let catalog = ConfigurationCatalog {
        agents: vec![HarnessChoice::from(core::HarnessChoice {
            id: "ag".into(),
            name: "Claude".into(),
            harness: Some("claude-native".into()),
            builtin: Some(true),
        })],
        host: Some(host),
        model_options: vec![ModelChoice::from(core::ModelChoice {
            id: "m".into(),
            model: None,
            display_name: None,
            description: None,
            hidden: None,
            is_default: None,
            default_reasoning_effort: None,
            supported_reasoning_efforts: None,
        })],
        model_options_error: Some("offline".into()),
        model_options_identity: Some(codex()),
    };
    let on_core = core::ConfigurationCatalog::from(catalog.clone());
    assert_eq!(on_core.agents[0].id, "ag");
    assert_eq!(on_core.model_options[0].id, "m");
    assert_eq!(on_core.model_options_error.as_deref(), Some("offline"));
    assert_eq!(ConfigurationCatalog::from(on_core), catalog);
}

#[test]
fn the_rules_read_the_configuration() {
    let labels = configuration_labels(codex());
    assert_eq!(labels.harness, "Codex");
    assert_eq!(labels.model, "fast");
    assert_eq!(labels.effort, "High");
    assert_eq!(labels.identity, "Codex \u{b7} fast");

    assert_eq!(
        configuration_efforts(codex(), Some("balanced".into())),
        ["high", "low"]
    );
    assert_eq!(configuration_efforts(codex(), Some("fast".into())), ["low"]);
    assert!(configuration_supports_models(codex()));
    assert!(configuration_supports_effort(codex()));
    assert!(configuration_supports_steering(codex()));
    let other = crate::test_support::configuration_on("unknown");
    assert!(!configuration_supports_models(other.clone()));
    assert!(!configuration_supports_effort(other));

    assert_eq!(execution_unavailable_reason(codex()), None);
    let offline = SessionConfiguration {
        runner_online: Some(false),
        host_online: Some(false),
        ..codex()
    };
    assert!(execution_unavailable_reason(offline).is_some());
}

#[test]
fn an_edit_starts_from_the_baseline_and_picking_a_model_clears_an_unsupported_effort() {
    let edit = configuration_edit(codex());
    assert_eq!(edit.baseline, codex());
    assert_eq!(edit.model.as_deref(), Some("fast"));
    assert_eq!(edit.effort.as_deref(), Some("high"));

    let kept = configuration_select_model(edit.clone(), Some("balanced".into()));
    assert_eq!(kept.model.as_deref(), Some("balanced"));
    assert_eq!(kept.effort.as_deref(), Some("high"));
    let cleared = configuration_select_model(
        ConfigurationEdit {
            effort: Some("low".into()),
            ..edit
        },
        Some("balanced".into()),
    );
    assert_eq!(cleared.effort.as_deref(), Some("low"));
}

#[test]
fn the_catalog_supplies_models_and_says_why_a_switch_is_unavailable() {
    let current = SessionConfiguration {
        models: vec![],
        ..codex()
    };
    let target = HarnessChoice::from(core::HarnessChoice {
        id: "target".into(),
        name: "Claude".into(),
        harness: Some("claude-native".into()),
        builtin: Some(true),
    });
    let catalog = |readiness: HarnessReadiness| ConfigurationCatalog {
        agents: vec![target.clone()],
        host: Some(ConfigurationHost {
            host_id: "demo-host".into(),
            name: "Mac".into(),
            status: "online".into(),
            configured_harnesses: Some(vec![HarnessStatus {
                harness: "claude-native".into(),
                readiness,
            }]),
        }),
        model_options: vec![model("preview", &[])],
        model_options_error: None,
        model_options_identity: Some(current.clone()),
    };
    let with_models =
        configuration_with_catalog_models(catalog(HarnessReadiness::Ready), current.clone());
    assert_eq!(with_models.models[0].id, "preview");

    assert_eq!(
        harness_switch_unavailable_reason(
            catalog(HarnessReadiness::Ready),
            target.clone(),
            current.clone()
        ),
        None
    );
    assert!(
        harness_switch_unavailable_reason(catalog(HarnessReadiness::NotReady), target, current)
            .is_some()
    );
}

const SESSION: &str = r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,
    "harness":"codex-native","agent_id":"clone","labels":{"omnigent.wrapper":"codex-native-ui"},
    "model_override":"balanced","reasoning_effort":"high","host_id":"demo-host",
    "host_online":true,"runner_online":true,"model_options":MODELS}"#;
const MODELS: &str = r#"[{"id":"balanced","isDefault":true,"supportedReasoningEfforts":[{"reasoningEffort":"high"},{"reasoningEffort":"low"}]},
    {"id":"fast","supportedReasoningEfforts":[{"reasoningEffort":"low"}]}]"#;

fn session(harness: &Harness, models: &str) {
    harness.http.route_method(
        "GET",
        "/v1/sessions/conv_a",
        json(200, &SESSION.replace("MODELS", models)),
    );
    harness.core.sessions().set_live_session("conv_a", true);
}

#[test]
fn a_snapshot_reads_the_configuration_and_reports_a_failure() {
    let mut harness = connected();
    session(&harness, MODELS);
    let summary = harness
        .call(|core| async move { core.configuration_snapshot("conv_a".into()).await })
        .unwrap();
    let configuration = summary.configuration.unwrap();
    assert_eq!(configuration.agent_id.as_deref(), Some("clone"));
    assert_eq!(configuration.model_override.as_deref(), Some("balanced"));
    assert_eq!(configuration.effort.as_deref(), Some("high"));

    harness
        .http
        .route_method("GET", "/v1/sessions/conv_a", json(500, "{}"));
    assert!(matches!(
        harness.call(|core| async move { core.configuration_snapshot("conv_a".into()).await }),
        Err(CoreError::Session { .. })
    ));
}

#[test]
fn the_catalog_reads_agents_host_and_preview() {
    let mut harness = connected();
    session(&harness, "[]");
    harness.http.route(
        "/v1/hosts",
        json(
            200,
            r#"{"hosts":[{"host_id":"demo-host","name":"Mac","status":"online",
                "configured_harnesses":{"claude-native":true}}]}"#,
        ),
    );
    harness.http.route(
        "/v1/agents",
        json(
            200,
            r#"{"data":[{"id":"target","name":"Claude","harness":"claude-native","builtin":true}],"has_more":false}"#,
        ),
    );
    harness.http.route(
        "/v1/hosts/demo-host/harnesses/codex-native/model-options",
        json(200, r#"{"models":[{"id":"preview","model":"provider"}]}"#),
    );
    let catalog = harness
        .call(|core| async move { core.configuration_catalog("conv_a".into()).await })
        .unwrap();
    assert_eq!(catalog.agents[0].id, "target");
    assert_eq!(catalog.host.as_ref().unwrap().host_id, "demo-host");
    assert_eq!(
        catalog.host.unwrap().configured_harnesses.unwrap()[0].readiness,
        HarnessReadiness::Ready
    );
    assert_eq!(catalog.model_options[0].value, "provider");
    assert_eq!(catalog.model_options_error, None);
    assert_eq!(
        catalog.model_options_identity.unwrap().agent_id.as_deref(),
        Some("clone")
    );

    harness.http.route("/v1/hosts", json(500, "{}"));
    assert!(
        harness
            .call(|core| async move { core.configuration_catalog("conv_a".into()).await })
            .is_err()
    );
}

#[test]
fn applying_patches_the_effort_and_reports_a_guard() {
    let mut harness = connected();
    session(&harness, MODELS);
    harness.http.route_method(
        "PATCH",
        "/v1/sessions/conv_a",
        json(
            200,
            &SESSION.replace("MODELS", MODELS).replace(
                r#""reasoning_effort":"high""#,
                r#""reasoning_effort":"low""#,
            ),
        ),
    );
    let baseline = harness
        .call(|core| async move { core.configuration_snapshot("conv_a".into()).await })
        .unwrap()
        .configuration
        .unwrap();
    let edit = ConfigurationEdit {
        model: baseline.model_override.clone(),
        effort: Some("low".into()),
        baseline,
    };
    let saved = harness
        .call({
            let edit = edit.clone();
            move |core| async move { core.apply_configuration("conv_a".into(), edit).await }
        })
        .unwrap();
    assert_eq!(saved.id, "conv_a");
    assert_eq!(saved.configuration.unwrap().effort.as_deref(), Some("low"));
    assert_eq!(
        harness.last_request(),
        (
            "PATCH /v1/sessions/conv_a".to_owned(),
            value!({"reasoning_effort": "low"})
        )
    );

    harness.core.sessions().set_live_session("conv_a", false);
    assert!(matches!(
        harness
            .call(move |core| async move { core.apply_configuration("conv_a".into(), edit).await }),
        Err(CoreError::Session { .. })
    ));
}

#[test]
fn switching_posts_the_target_and_refuses_a_moved_selection() {
    let mut harness = connected();
    session(&harness, MODELS);
    harness.http.route(
        "/v1/hosts",
        json(
            200,
            r#"{"hosts":[{"host_id":"demo-host","name":"Mac","status":"online",
                "configured_harnesses":{"claude-native":true}}]}"#,
        ),
    );
    harness.http.route(
        "/v1/agents",
        json(
            200,
            r#"{"data":[{"id":"target","name":"Claude","harness":"claude-native","builtin":true}],"has_more":false}"#,
        ),
    );
    harness.http.route_method(
        "POST",
        "/v1/sessions/conv_a/switch-agent",
        json(
            200,
            r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,
                "harness":"claude-native","agent_id":"target-clone",
                "labels":{"omnigent.wrapper":"claude-code-native-ui"},"host_id":"demo-host",
                "host_online":true,"runner_online":true}"#,
        ),
    );
    let baseline = harness
        .call(|core| async move { core.configuration_snapshot("conv_a".into()).await })
        .unwrap()
        .configuration
        .unwrap();
    let saved = harness
        .call({
            let baseline = baseline.clone();
            move |core| async move {
                core.switch_harness("conv_a".into(), "target".into(), baseline)
                    .await
            }
        })
        .unwrap();
    assert_eq!(
        saved.configuration.unwrap().harness.as_deref(),
        Some("claude-native")
    );
    assert_eq!(
        harness.last_request(),
        (
            "POST /v1/sessions/conv_a/switch-agent".to_owned(),
            value!({"agent_id": "target"})
        )
    );

    harness.core.sessions().set_live_session("conv_a", false);
    assert!(
        harness
            .call(move |core| async move {
                core.switch_harness("conv_a".into(), "target".into(), baseline)
                    .await
            })
            .is_err()
    );
}
