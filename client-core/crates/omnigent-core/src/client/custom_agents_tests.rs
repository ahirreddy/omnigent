//! Custom agents over REST: listing, installing a bundle, editing and removing.

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::test_support::{Reply, RouteTransport, connected, header, path_of, query_value};
use crate::custom_agents::AgentRemoval;

#[test]
fn lists_the_callers_agents_across_pages() {
    let core = connected(RouteTransport::local());
    core.transport()
        .respond(
            None,
            "/v1/agents",
            None,
            Reply::json(
                200,
                r#"{"data":[{"id":"a1","name":"one","harness":"codex"}],"has_more":true,"last_id":"a1"}"#,
            ),
        )
        .respond(
            None,
            "/v1/agents",
            Some("a1"),
            Reply::json(200, r#"{"data":[{"id":"a2","name":"two"}],"has_more":false}"#),
        );
    let agents = block_on(core.managed_agents(true)).unwrap();
    assert_eq!(
        agents
            .iter()
            .map(|agent| agent.id.as_str())
            .collect::<Vec<_>>(),
        ["a1", "a2"]
    );
    let requests = core.transport().taken();
    let listed: Vec<_> = requests
        .iter()
        .filter(|request| path_of(request) == "/v1/agents")
        .collect();
    assert_eq!(query_value(listed[0], "scope").as_deref(), Some("user"));
}

#[test]
fn installs_a_bundle_as_multipart() {
    let core = connected(RouteTransport::local());
    core.transport()
        .ok("/v1/agents", r#"{"id":"a1","name":"reviewer"}"#);
    let agent =
        block_on(core.install_agent_bundle(b"\x1f\x8bgz", "agent.tar.gz", "B0und")).unwrap();
    assert_eq!(agent.name, "reviewer");
    let writes = core.transport().writes();
    assert_eq!(
        header(&writes[0], "Content-Type"),
        Some("multipart/form-data; boundary=B0und")
    );
    let body = String::from_utf8_lossy(writes[0].body.as_deref().unwrap()).into_owned();
    assert!(body.starts_with(
        "--B0und\r\nContent-Disposition: form-data; name=\"bundle\"; filename=\"agent.tar.gz\""
    ));
    assert!(body.ends_with("\r\n--B0und--\r\n"));

    assert!(matches!(
        block_on(core.install_agent_bundle(b"", "a.tar.gz", "B0und")),
        Err(SessionError::InvalidInput { .. })
    ));
    assert!(matches!(
        block_on(core.install_agent_bundle(b"x--B0undy", "a.tar.gz", "B0und")),
        Err(SessionError::InvalidInput { .. })
    ));
    assert_eq!(core.transport().writes().len(), 1);
}

#[test]
fn config_carries_its_etag_into_the_patch() {
    let core = connected(RouteTransport::local());
    let config = r#"{"id":"a1","name":"r","version":2,"model":"m","harness":"codex"}"#;
    core.transport()
        .ok("/v1/agents/a1/config", config)
        .ok("/v1/agents/a1", config);
    let loaded = block_on(core.agent_config("a1")).unwrap();
    assert_eq!(loaded.version, 2);
    block_on(core.update_agent_config("a1", Some("\"v2\""), &json!({"model": "m"}))).unwrap();
    let writes = core.transport().writes();
    assert_eq!(writes[0].method, "PATCH");
    assert_eq!(header(&writes[0], "If-Match"), Some("\"v2\""));
}

#[test]
fn removal_reports_agents_in_use_unless_forced() {
    let core = connected(RouteTransport::local());
    core.transport().respond(
        Some("DELETE"),
        "/v1/agents/a1",
        None,
        Reply::json(
            409,
            r#"{"error":{"code":"agent_in_use","message":"2 session(s) still use 'r'"},"sessions_in_use":"2"}"#,
        ),
    );
    assert_eq!(
        block_on(core.remove_agent("a1", false)),
        Ok(AgentRemoval::InUse {
            message: "2 session(s) still use 'r'".into()
        })
    );
    core.transport().respond(
        Some("DELETE"),
        "/v1/agents/a1",
        None,
        Reply::json(200, r#"{"id":"a1","deleted":true}"#),
    );
    assert_eq!(
        block_on(core.remove_agent("a1", true)),
        Ok(AgentRemoval::Removed)
    );
    let writes = core.transport().writes();
    assert_eq!(query_value(&writes[1], "force").as_deref(), Some("true"));
}
