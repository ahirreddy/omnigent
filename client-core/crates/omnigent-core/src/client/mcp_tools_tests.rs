//! The MCP tool probe a harness page's rows run when they open.

use futures::executor::block_on;

use super::SessionError;
use super::mcp_tools::{McpConnection, McpToolsRead};
use super::test_support::{Reply, RouteTransport, body_json, connected};

const PROBE: &str = "/v1/hosts/h1/mcp-servers/tools";

#[test]
fn a_probe_lists_the_tools_and_says_how_the_connection_went() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "POST",
        PROBE,
        vec![
            Reply::json(
                200,
                r#"{"tools":[{"name":"search","description":"Find pages"},
                             {"name":"fetch","description":" "}],
                    "connection":"connected","truncated":true}"#,
            ),
            Reply::json(
                200,
                r#"{"tools":[],"connection":"needs_auth","truncated":false}"#,
            ),
            Reply::json(404, r#"{"detail":"Not Found"}"#),
            Reply::json(501, r#"{"detail":"update the host to list MCP tools"}"#),
            Reply::json(503, r#"{"detail":"host MCP probe capacity exhausted"}"#),
        ],
    );
    let core = connected(transport);
    let probe = |plugin| block_on(core.mcp_server_tools("h1", "claude", "docs", plugin, None));
    let Ok(McpToolsRead::Probed(found)) = probe(Some("kit")) else {
        panic!("expected the tools");
    };
    assert_eq!(found.connection, McpConnection::Connected);
    assert!(found.truncated);
    assert_eq!(found.tools[0].description.as_deref(), Some("Find pages"));
    assert_eq!(
        found.tools[1].description, None,
        "a blank description is none"
    );
    let Ok(McpToolsRead::Probed(locked)) = probe(None) else {
        panic!("expected a probe");
    };
    assert_eq!(locked.connection, McpConnection::NeedsAuth);
    assert_eq!(probe(None), Ok(McpToolsRead::RouteMissing));
    assert_eq!(probe(None), Ok(McpToolsRead::HostOutdated));
    assert_eq!(probe(None), Ok(McpToolsRead::Busy));
    let requests = core.transport().writes();
    assert_eq!(
        body_json(&requests[0]),
        serde_json::json!({"harness": "claude", "server": "docs", "plugin": "kit"})
    );
    assert!(matches!(
        block_on(core.mcp_server_tools("a/b", "claude", "docs", None, None)),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}
