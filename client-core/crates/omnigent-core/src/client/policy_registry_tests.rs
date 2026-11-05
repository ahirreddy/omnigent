//! The policy registry, adding a default policy from it, and member invites.

use std::collections::BTreeMap;

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::test_support::{Reply, RouteTransport, connected};
use super::{
    PolicyParamKind, PolicyRegistryEntry, coerce_policy_params, invite_from, suggested_policy_name,
};

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

fn values(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
        .collect()
}

fn registry() -> Vec<PolicyRegistryEntry> {
    let transport = RouteTransport::local();
    transport.ok("/v1/policy-registry", REGISTRY);
    block_on(connected(transport).policy_registry()).unwrap()
}

#[test]
fn registry_reads_each_parameter_kind_and_default() {
    let entries = registry();
    assert_eq!(entries.len(), 2);
    let factory = &entries[0];
    assert!(factory.is_factory && !entries[1].is_factory && entries[1].params.is_empty());
    let kinds: Vec<(&str, PolicyParamKind)> = factory
        .params
        .iter()
        .map(|param| (param.key.as_str(), param.kind))
        .collect();
    assert_eq!(
        kinds,
        vec![
            ("mode", PolicyParamKind::Choice),
            ("note", PolicyParamKind::Text),
            ("pii", PolicyParamKind::MultiChoice),
            ("points", PolicyParamKind::Object),
            ("ratio", PolicyParamKind::Number),
            ("repos", PolicyParamKind::List),
            ("strict", PolicyParamKind::Boolean),
            ("window", PolicyParamKind::Integer),
        ]
    );
    let param = |key: &str| {
        factory
            .params
            .iter()
            .find(|param| param.key == key)
            .unwrap()
    };
    assert_eq!(param("window").default_value, "10");
    assert!(param("window").required && !param("strict").required);
    assert_eq!(param("strict").default_value, "true");
    assert_eq!(param("mode").options, vec!["ask", "deny"]);
    assert_eq!(param("pii").default_value, "ssn");
    assert_eq!(suggested_policy_name(factory), "detect_loop");
}

#[test]
fn coercion_types_values_and_skips_empty_ones() {
    let params = registry().remove(0).params;
    let coerced = coerce_policy_params(
        &params,
        &values(&[
            ("window", " 20 "),
            ("strict", "false"),
            ("mode", "deny"),
            ("pii", "ssn, email,"),
            ("points", r#"{"web": 2}"#),
            ("ratio", "0.5"),
            ("note", ""),
        ]),
    )
    .unwrap();
    assert_eq!(
        serde_json::Value::Object(coerced),
        json!({"window": 20, "strict": false, "mode": "deny", "pii": ["ssn", "email"],
               "points": {"web": 2}, "ratio": 0.5})
    );
    let integer = |raw: &str| coerce_policy_params(&params, &values(&[("window", raw)]));
    assert_eq!(
        integer("2.5").unwrap_err(),
        "window must be an integer, e.g. 20"
    );
    let object = coerce_policy_params(&params, &values(&[("points", "[1]")]));
    assert!(object.unwrap_err().contains("must be a JSON object"));
    let number = coerce_policy_params(&params, &values(&[("ratio", "inf")]));
    assert_eq!(number.unwrap_err(), "ratio must be a number, e.g. 0.5");
}

#[test]
fn adding_a_policy_sends_its_coerced_parameters() {
    let entries = registry();
    let transport = RouteTransport::local();
    transport.respond(
        Some("POST"),
        "/v1/policies",
        None,
        Reply::json(
            200,
            r#"{"id":"pol-9","name":"loops","handler":"p.loop","enabled":true}"#,
        ),
    );
    let core = connected(transport);
    let added =
        block_on(core.add_default_policy(&entries[0], " loops ", &values(&[("window", "5")])))
            .unwrap();
    assert_eq!(added.id.as_deref(), Some("pol-9"));
    block_on(core.add_default_policy(&entries[1], "os", &values(&[("window", "5")]))).unwrap();
    let bodies = core.transport().write_bodies();
    assert_eq!(
        bodies[0],
        json!({"name": "loops", "type": "python", "handler": "p.loop",
               "factory_params": {"window": 5}})
    );
    // A callable takes no parameters.
    assert_eq!(
        bodies[1],
        json!({"name": "os", "type": "python", "handler": "p.os"})
    );

    // Bad input is refused before any request.
    let refused = block_on(core.add_default_policy(&entries[0], "x", &values(&[("window", "a")])));
    assert!(matches!(
        refused,
        Err(SessionError::Rejected { status: 400, .. })
    ));
    let unnamed = block_on(core.add_default_policy(&entries[1], "  ", &values(&[])));
    assert!(matches!(
        unnamed,
        Err(SessionError::Rejected { status: 400, .. })
    ));
    assert_eq!(core.transport().write_bodies().len(), 2);
}

#[test]
fn invites_link_to_the_connected_server() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("POST"),
        "/auth/invite",
        None,
        Reply::json(
            200,
            r#"{"token":"a+b","register_url":"http://internal:1/register?invite=a+b",
                "expires_at":1700000000,"is_admin":true}"#,
        ),
    );
    let core = connected(transport);
    let invite = block_on(core.invite_member(true)).unwrap();
    let base = core.connected_server().unwrap().base_url;
    assert_eq!(
        invite.url,
        format!("{}/register?invite=a%2Bb", base.trim_end_matches('/'))
    );
    assert_eq!(invite.expires_at, Some(1_700_000_000));
    assert!(invite.is_admin);
    assert_eq!(
        core.transport().write_bodies()[0],
        json!({"is_admin": true})
    );

    assert!(invite_from(&json!({"token": ""}), "https://x").is_err());
    let plain = invite_from(&json!({"token": "t"}), "https://x/mount/").unwrap();
    assert_eq!(plain.url, "https://x/mount/register?invite=t");
    assert!(!plain.is_admin && plain.expires_at.is_none());
}
