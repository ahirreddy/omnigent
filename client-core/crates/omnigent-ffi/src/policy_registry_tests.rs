//! The policy registry's records, adding a default policy, and member invites.

use std::collections::HashMap;

use omnigent_core::policy_registry as core;
use serde_json::json as value;

use crate::policy_registry::{PolicyParamKind, PolicyRegistryEntry};
use crate::test_support::{connected, json};

const REGISTRY: &str = r#"{"object":"list","data":[
  {"handler":"p.loop","kind":"factory","name":"Detect Loop","description":"Stops loops",
   "params_schema":{"type":"object","required":["window"],"properties":{
     "window":{"type":"integer","description":"Calls","default":10},
     "strict":{"type":"boolean","default":true},
     "mode":{"type":"string","enum":["ask","deny"]},
     "pii":{"type":"array","items":{"type":"string","enum":["ssn","email"]},"default":["ssn"]},
     "repos":{"type":"array","items":{"type":"string"}},
     "points":{"type":"object"},
     "ratio":{"type":"number"},
     "note":{"type":"string"}}}},
  {"handler":"p.os","kind":"callable","name":"Ask On OS Tools","description":"","params_schema":null}
]}"#;

#[test]
fn every_parameter_kind_maps_both_ways() {
    for (on_core, on_ffi) in [
        (core::PolicyParamKind::Text, PolicyParamKind::Text),
        (core::PolicyParamKind::Integer, PolicyParamKind::Integer),
        (core::PolicyParamKind::Number, PolicyParamKind::Number),
        (core::PolicyParamKind::Boolean, PolicyParamKind::Boolean),
        (core::PolicyParamKind::Choice, PolicyParamKind::Choice),
        (core::PolicyParamKind::List, PolicyParamKind::List),
        (
            core::PolicyParamKind::MultiChoice,
            PolicyParamKind::MultiChoice,
        ),
        (core::PolicyParamKind::Object, PolicyParamKind::Object),
    ] {
        assert_eq!(PolicyParamKind::from(on_core), on_ffi);
        assert_eq!(core::PolicyParamKind::from(on_ffi), on_core);
    }
}

#[test]
fn the_registry_reads_each_field_and_a_factory_sends_its_typed_parameters() {
    let mut harness = connected();
    harness
        .http
        .route("/v1/policy-registry", json(200, REGISTRY));
    let entries: Vec<PolicyRegistryEntry> = harness
        .call(|core| async move { core.policy_registry().await })
        .unwrap();
    assert_eq!(harness.last_request_line(), "GET /v1/policy-registry");

    let factory = entries[0].clone();
    assert_eq!(
        (
            factory.handler.as_str(),
            factory.name.as_str(),
            factory.description.as_str(),
            factory.is_factory,
            factory.suggested_name.as_str(),
        ),
        ("p.loop", "Detect Loop", "Stops loops", true, "detect_loop")
    );
    assert!(!entries[1].is_factory);
    assert_eq!(entries[1].suggested_name, "ask_on_os_tools");
    let window = factory
        .params
        .iter()
        .find(|param| param.key == "window")
        .unwrap();
    assert_eq!(window.kind, PolicyParamKind::Integer);
    assert_eq!(window.description.as_deref(), Some("Calls"));
    assert_eq!(window.default_value, "10");
    assert!(window.required);
    let mode = factory
        .params
        .iter()
        .find(|param| param.key == "mode")
        .unwrap();
    assert_eq!(mode.kind, PolicyParamKind::Choice);
    assert_eq!(mode.options, ["ask", "deny"]);
    assert!(!mode.required);

    harness.http.route_method(
        "POST",
        "/v1/policies",
        json(
            200,
            r#"{"id":"pol-9","name":"loops","handler":"p.loop","enabled":true}"#,
        ),
    );
    let values = HashMap::from([
        ("window".to_owned(), " 5 ".to_owned()),
        ("strict".to_owned(), "false".to_owned()),
        ("pii".to_owned(), "ssn, email".to_owned()),
    ]);
    let added = harness
        .call(|core| async move {
            core.add_default_policy(factory, " loops ".into(), values)
                .await
        })
        .unwrap();
    assert_eq!(added.id.as_deref(), Some("pol-9"));
    assert_eq!(
        harness.last_request(),
        (
            "POST /v1/policies".to_owned(),
            value!({"name": "loops", "type": "python", "handler": "p.loop",
                "factory_params": {"window": 5, "strict": false, "pii": ["ssn", "email"]}})
        )
    );
}

#[test]
fn a_wrong_value_or_a_refused_read_is_an_error() {
    let mut harness = connected();
    harness
        .http
        .route("/v1/policy-registry", json(200, REGISTRY));
    let entry = harness
        .call(|core| async move { core.policy_registry().await })
        .unwrap()
        .remove(0);
    let values = HashMap::from([("window".to_owned(), "2.5".to_owned())]);
    let refused = harness
        .call(|core| async move { core.add_default_policy(entry, "loops".into(), values).await });
    assert!(
        format!("{refused:?}").contains("window must be an integer"),
        "{refused:?}"
    );

    harness
        .http
        .route("/v1/policy-registry", json(403, r#"{"detail":"no"}"#));
    assert!(
        harness
            .call(|core| async move { core.policy_registry().await })
            .is_err()
    );
}

#[test]
fn an_invite_reads_its_link_expiry_and_role() {
    let mut harness = connected();
    harness.http.route_method(
        "POST",
        "/auth/invite",
        json(
            200,
            r#"{"token":"a+b","register_url":"http://internal:1/register?invite=a+b",
                "expires_at":1700000000,"is_admin":true}"#,
        ),
    );
    let invite = harness
        .call(|core| async move { core.invite_member(true).await })
        .unwrap();
    assert_eq!(invite.url, "http://127.0.0.1:6767/register?invite=a%2Bb");
    assert_eq!(invite.expires_at, Some(1_700_000_000));
    assert!(invite.is_admin);
    assert_eq!(
        harness.last_request(),
        ("POST /auth/invite".to_owned(), value!({"is_admin": true}))
    );

    harness
        .http
        .route_method("POST", "/auth/invite", json(403, r#"{"detail":"no"}"#));
    assert!(
        harness
            .call(|core| async move { core.invite_member(false).await })
            .is_err()
    );
}
