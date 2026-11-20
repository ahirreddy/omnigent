//! A started session's `/mcp` panel, merged as the web's composer merges it.

use futures::executor::block_on;

use super::{
    AgentMcp, AgentMcpServer, LiveMcpRead, LiveMcpServer, McpAccount, McpLive, McpPanelSession,
    McpPanelSources, McpSignIn, SourceRead, mcp_panel, mcp_settings_target,
};
use crate::client::SessionError;
use crate::client::harness_inventory::HostMcpServer;
use crate::client::server_admin::McpService;
use crate::client::test_support::{Reply, RouteTransport, body_json, connected};

fn host(name: &str, plugin: Option<&str>, auth: Option<&str>, url: Option<&str>) -> HostMcpServer {
    HostMcpServer {
        name: name.into(),
        harness: "claude".into(),
        plugin: plugin.map(str::to_owned),
        source_id: None,
        url_host: Some("mcp.example.com".into()),
        enabled: None,
        managed: false,
        locked: false,
        auth_status: auth.map(str::to_owned),
        sign_in_url: url.map(str::to_owned),
    }
}

fn agent(servers: &[(&str, &str)], loads_user_settings: bool) -> SourceRead<AgentMcp> {
    SourceRead::Loaded(AgentMcp {
        servers: servers
            .iter()
            .map(|(name, transport)| AgentMcpServer {
                name: (*name).into(),
                description: None,
                transport: (*transport).into(),
            })
            .collect(),
        loads_user_settings,
    })
}

fn live(name: &str, status: &str) -> LiveMcpServer {
    LiveMcpServer {
        name: name.into(),
        status: status.into(),
        error: (status == "failed").then(|| "spawn failed".to_owned()),
    }
}

fn service(id: &str, auth: &str, connected: bool) -> McpService {
    McpService {
        id: id.into(),
        title: id.into(),
        description: Some(format!("The {id} service")),
        auth: auth.into(),
        connected,
        tools: Vec::new(),
    }
}

fn sources() -> McpPanelSources {
    McpPanelSources {
        host_family: Some("claude".into()),
        has_host: true,
        claude_sdk: false,
        agent: None,
        host: None,
        registry: None,
        live: None,
    }
}

#[test]
fn host_rows_carry_account_state_and_live_connections() {
    let panel = mcp_panel(&McpPanelSources {
        claude_sdk: true,
        agent: Some(agent(&[], true)),
        host: Some(SourceRead::Loaded(vec![
            host(
                "docs",
                Some("kit"),
                Some("sign_in_required"),
                Some("https://sign.example.com/a"),
            ),
            host("files", None, Some("connected"), None),
            host("notes", None, Some("sign_in_required"), Some("file:///etc")),
            HostMcpServer {
                harness: "codex".into(),
                ..host("other", None, None, None)
            },
        ])),
        live: Some(SourceRead::Loaded(LiveMcpRead::Live(vec![
            live("plugin:kit:docs", "needs-auth"),
            live("project", "failed"),
        ]))),
        ..sources()
    });
    let names: Vec<&str> = panel.rows.iter().map(|row| row.name.as_str()).collect();
    assert_eq!(
        names,
        ["docs", "files", "notes", "project"],
        "only the session's harness"
    );
    let docs = &panel.rows[0];
    assert_eq!(
        docs.description.as_deref(),
        Some("kit plugin \u{00B7} mcp.example.com")
    );
    assert_eq!(docs.account, Some(McpAccount::SignInRequired));
    assert_eq!(
        docs.sign_in,
        Some(McpSignIn::Url("https://sign.example.com/a".into()))
    );
    assert_eq!(docs.live_name.as_deref(), Some("plugin:kit:docs"));
    assert_eq!(
        panel.rows[1].live,
        Some(McpLive {
            status: "not-loaded".into(),
            error: None
        })
    );
    assert_eq!(panel.rows[2].sign_in, None, "only a web page opens");
    assert_eq!(
        panel.rows[3].key, "live:project",
        "a server only the CLI loaded"
    );
    assert_eq!(
        panel.rows[3]
            .live
            .as_ref()
            .and_then(|live| live.error.as_deref()),
        Some("spawn failed")
    );
    assert_eq!(
        panel.poll_after_ms,
        Some(5_000),
        "a host row awaits sign-in"
    );
    assert_eq!(panel.status, None);
}

#[test]
fn agent_servers_take_host_rows_and_registry_state() {
    let panel = mcp_panel(&McpPanelSources {
        agent: Some(agent(
            &[
                ("docs", "http"),
                ("search", "registry"),
                ("vault", "registry"),
                ("gone", "registry"),
            ],
            true,
        )),
        host: Some(SourceRead::Loaded(vec![
            host("docs", Some("kit"), Some("connected"), None),
            host(
                "docs",
                None,
                Some("sign_in_required"),
                Some("https://sign.example.com/b"),
            ),
        ])),
        registry: Some(SourceRead::Loaded(vec![
            service("search", "oauth", false),
            service("vault", "bearer", false),
        ])),
        ..sources()
    });
    let docs = &panel.rows[0];
    assert_eq!(
        panel.rows.iter().filter(|row| row.name == "docs").count(),
        1
    );
    assert_eq!(docs.key, "host:plugin:kit:docs");
    assert_eq!(
        docs.account, None,
        "the agent's server takes no host account state"
    );
    assert_eq!(
        docs.description.as_deref(),
        Some("kit plugin \u{00B7} mcp.example.com")
    );
    let search = &panel.rows[1];
    assert_eq!(search.account, Some(McpAccount::SignInRequired));
    assert_eq!(
        search.sign_in,
        Some(McpSignIn::Registry {
            service_id: "search".into(),
            typed: false
        })
    );
    assert_eq!(search.description.as_deref(), Some("The search service"));
    assert_eq!(
        panel.rows[2].sign_in,
        Some(McpSignIn::Registry {
            service_id: "vault".into(),
            typed: true
        })
    );
    assert_eq!(panel.rows[3].account, Some(McpAccount::Unavailable));
}

#[test]
fn statuses_say_what_could_not_be_read() {
    let failed = mcp_panel(&McpPanelSources {
        claude_sdk: true,
        agent: Some(SourceRead::Failed),
        host: Some(SourceRead::Loaded(vec![
            host("mine", None, None, None),
            HostMcpServer {
                managed: true,
                ..host("pinned", None, None, None)
            },
        ])),
        live: Some(SourceRead::Loaded(LiveMcpRead::NotRunning)),
        ..sources()
    });
    let names: Vec<&str> = failed.rows.iter().map(|row| row.name.as_str()).collect();
    assert_eq!(names, ["pinned"], "only managed servers without the agent");
    assert_eq!(
        failed.status.as_deref(),
        Some(
            "Couldn\u{2019}t load this session\u{2019}s agent, so only managed MCP servers are \
             shown. Live connection status appears once this session\u{2019}s agent is running; \
             send a message to start it."
        )
    );
    let no_host = mcp_panel(&McpPanelSources {
        has_host: false,
        ..sources()
    });
    assert_eq!(
        no_host.status.as_deref(),
        Some("Host MCP servers unavailable: this session has no known host.")
    );
    let unreadable = mcp_panel(&McpPanelSources {
        agent: Some(agent(&[("search", "registry")], true)),
        host: Some(SourceRead::Failed),
        registry: Some(SourceRead::Failed),
        ..sources()
    });
    assert_eq!(
        unreadable.status.as_deref(),
        Some(
            "Couldn\u{2019}t load MCP servers from this session\u{2019}s host. Couldn\u{2019}t \
             check MCP service connections."
        )
    );
    let connecting = mcp_panel(&McpPanelSources {
        live: Some(SourceRead::Loaded(LiveMcpRead::Live(vec![live(
            "a", "pending",
        )]))),
        ..sources()
    });
    assert_eq!(connecting.poll_after_ms, Some(2_000));
}

#[test]
fn the_panel_reads_each_source_and_reconnect_reports_a_refusal() {
    let transport = RouteTransport::local();
    transport
        .ok(
            "/v1/agents/agent_1",
            r#"{"name":"Helper","loads_user_settings":true,
                "mcp_servers":[{"name":"search","transport":"registry"}]}"#,
        )
        .ok(
            "/v1/hosts/h1/mcp-servers",
            r#"{"mcp_servers":[{"name":"docs","harness":"claude","auth_status":"connected"}]}"#,
        )
        .ok(
            "/v1/mcp-registry/services",
            r#"{"data":[{"id":"search","title":"Search","auth":"oauth","connected":true}]}"#,
        )
        .ok(
            "/v1/sessions/conv_a/live-mcp-servers",
            r#"{"live":true,"servers":[{"name":"docs","status":"connected"}]}"#,
        );
    transport.enqueue(
        "POST",
        "/v1/sessions/conv_a/live-mcp-servers/reconnect",
        vec![
            Reply::json(
                200,
                r#"{"live":true,"servers":[],"reconnect_error":"token expired"}"#,
            ),
            Reply::json(
                409,
                r#"{"error":{"message":"This session's agent isn't running yet."}}"#,
            ),
        ],
    );
    let core = connected(transport);
    let session = McpPanelSession {
        session_id: "conv_a",
        agent_id: Some("agent_1"),
        harness: Some("claude-sdk"),
        host_id: Some("h1"),
    };
    let panel = block_on(core.session_mcp_panel(session)).expect("panel");
    assert_eq!(panel.settings_harness.as_deref(), Some("claude-native"));
    assert_eq!(panel.settings_host_id.as_deref(), Some("h1"));
    let names: Vec<&str> = panel.rows.iter().map(|row| row.name.as_str()).collect();
    assert_eq!(names, ["docs", "search"]);
    assert_eq!(
        panel.rows[0].live.as_ref().map(|live| live.status.as_str()),
        Some("connected")
    );
    assert_eq!(panel.rows[1].account, Some(McpAccount::Connected));
    assert_eq!(
        block_on(core.reconnect_live_mcp_server("conv_a", "docs")),
        Ok(Some("token expired".into()))
    );
    assert!(matches!(
        block_on(core.reconnect_live_mcp_server("conv_a", "docs")),
        Err(SessionError::Rejected { status: 409, .. })
    ));
    assert_eq!(
        body_json(&core.transport().writes()[0]),
        serde_json::json!({"name": "docs"})
    );
    let other = McpPanelSession {
        session_id: "a/b",
        ..session
    };
    assert!(matches!(
        block_on(core.session_mcp_panel(other)),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}

#[test]
fn a_server_without_the_live_route_reads_as_unsupported() {
    let transport = RouteTransport::local();
    transport.respond(
        None,
        "/v1/sessions/conv_a/live-mcp-servers",
        None,
        Reply::json(404, r#"{"detail":"Not Found"}"#),
    );
    let core = connected(transport);
    let session = McpPanelSession {
        session_id: "conv_a",
        agent_id: None,
        harness: Some("claude-sdk"),
        host_id: None,
    };
    let panel = block_on(core.session_mcp_panel(session)).expect("panel");
    assert_eq!(panel.rows, Vec::new());
    assert_eq!(panel.status, None, "no host and no live status to explain");
}

#[test]
fn go_to_settings_opens_the_session_harness_on_its_host() {
    let owned = |harness: Option<&str>, host: Option<&str>| {
        (harness.map(str::to_owned), host.map(str::to_owned))
    };
    assert_eq!(
        mcp_settings_target(Some("codex-native"), Some("h1")),
        owned(Some("codex-native"), Some("h1"))
    );
    assert_eq!(
        mcp_settings_target(Some("native-pi"), None),
        owned(Some("native-pi"), None)
    );
    assert_eq!(
        mcp_settings_target(Some("claude-sdk"), Some("h1")),
        owned(Some("claude-native"), Some("h1"))
    );
    assert_eq!(
        mcp_settings_target(Some("claude-sdk"), None),
        owned(None, None)
    );
    assert_eq!(
        mcp_settings_target(Some("openai-agents"), Some("h2")),
        owned(None, Some("h2"))
    );
}
