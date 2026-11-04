//! Agent info reads.

use futures::executor::block_on;

use super::SessionError;
use super::agent_info::AgentInfo;
use super::test_support::{Reply, RouteTransport, connected};

#[test]
fn agent_info_lists_mcp_servers_and_session_policies() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/agents/agent_1",
        r#"{"id":"agent_1","name":"Polly","mcp_servers":[{"name":"github"},{"name":"github"},{"name":"linear"}]}"#,
    );
    transport.ok(
        "/v1/sessions/conv_a/policies",
        r#"{"object":"list","data":[{"name":"block_push","source":"spec"},{"name":"audit","source":"admin"}]}"#,
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.agent_info("conv_a", "agent_1")),
        Ok(AgentInfo {
            name: "Polly".into(),
            tools: vec!["github".into(), "linear".into()],
            policies: vec!["block_push".into(), "audit".into()],
        })
    );
}

#[test]
fn an_older_server_without_session_policies_lists_none() {
    let transport = RouteTransport::local();
    transport.ok("/v1/agents/agent_1", r#"{"id":"agent_1","name":"Polly"}"#);
    transport.enqueue(
        "GET",
        "/v1/sessions/conv_a/policies",
        vec![
            Reply::json(404, r#"{"detail":"Not Found"}"#),
            Reply::json(500, "{}"),
        ],
    );
    let core = connected(transport);
    let info = block_on(core.agent_info("conv_a", "agent_1")).unwrap();
    assert!(info.tools.is_empty() && info.policies.is_empty());
    assert_eq!(
        block_on(core.agent_info("conv_a", "agent_1")),
        Err(SessionError::HttpStatus { status: 500 })
    );
}
