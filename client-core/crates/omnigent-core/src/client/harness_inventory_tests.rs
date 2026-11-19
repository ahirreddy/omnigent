//! A harness's MCP servers, skills and plugins on a host, in main's wire shapes.

use futures::executor::block_on;

use super::super::SessionError;
use super::super::test_support::{Reply, RouteTransport, connected, path_of, query_value};
use super::{
    HostMcpServer, HostPlugin, harness_inventory, inventory_family, mcp_server_display_name,
    skill_pages_open,
};
use crate::slash::Skill;

fn skill(name: &str) -> Skill {
    Skill {
        name: name.into(),
        description: format!("about {name}"),
        display_name: None,
    }
}

fn server(name: &str, harness: &str, plugin: Option<&str>) -> HostMcpServer {
    HostMcpServer {
        name: name.into(),
        harness: harness.into(),
        plugin: plugin.map(str::to_owned),
        source_id: None,
        url_host: Some("mcp.example.com".into()),
        enabled: None,
    }
}

#[test]
fn families_names_and_skill_pages_follow_the_web() {
    assert_eq!(inventory_family("claude-native"), Some("claude"));
    assert_eq!(inventory_family("pi-native"), Some("pi"));
    assert_eq!(inventory_family("gemini-native"), None);
    assert!(skill_pages_open("codex") && !skill_pages_open("pi"));
    assert_eq!(mcp_server_display_name("github"), "GitHub");
    assert_eq!(mcp_server_display_name("PAGERDUTY"), "PagerDuty");
    assert_eq!(mcp_server_display_name("My-Server"), "my-server");
}

#[test]
fn plugin_skills_and_servers_group_under_their_plugin_without_a_plugin_list() {
    let servers = [
        server("linear", "claude", None),
        server("lint", "claude", Some("toolkit")),
        server("other", "codex", None),
    ];
    let skills = [skill("review"), skill("toolkit:lint")];
    let inventory = harness_inventory("claude", &servers, &skills, None);
    assert_eq!(
        inventory
            .mcp_servers
            .iter()
            .map(|row| row.id.as_str())
            .collect::<Vec<_>>(),
        ["claude:linear", "claude:plugin:toolkit:lint"]
    );
    assert_eq!(inventory.mcp_servers[0].title, "Linear");
    assert_eq!(
        inventory.mcp_servers[1].detail.as_deref(),
        Some("toolkit plugin \u{00B7} mcp.example.com")
    );
    assert_eq!(inventory.skills.len(), 1);
    assert_eq!(inventory.skills[0].name, "review");
    let plugin = &inventory.plugins[0];
    assert_eq!(plugin.id, "claude:toolkit");
    assert_eq!(plugin.detail, "1 skill \u{00B7} 1 MCP");
    assert_eq!(plugin.skills[0].name, "toolkit:lint");
    assert_eq!(plugin.skills[0].title, "lint");
}

#[test]
fn claudes_plugin_list_replaces_the_names_with_details_and_notices() {
    let mut off = server("db", "claude", Some("data"));
    off.enabled = Some(false);
    off.source_id = Some("m1".into());
    let plugins = [
        HostPlugin {
            id: Some("p1".into()),
            name: "data".into(),
            marketplace: "official".into(),
            version: Some("1.2".into()),
            description: Some("Data tools".into()),
            enabled: true,
            skills: vec![(Some("s1".into()), "query".into())],
            mcp_servers: vec![(Some("m1".into()), "db".into())],
            has_skill_entries: true,
            has_mcp_entries: true,
            has_hooks: true,
            has_commands: false,
        },
        HostPlugin {
            id: None,
            name: "old".into(),
            marketplace: "community".into(),
            version: None,
            description: None,
            enabled: false,
            skills: vec![(None, "a".into()), (None, "b".into())],
            mcp_servers: Vec::new(),
            has_skill_entries: false,
            has_mcp_entries: false,
            has_hooks: false,
            has_commands: false,
        },
    ];
    let inventory = harness_inventory("claude", &[off], &[], Some(&plugins));
    let data = &inventory.plugins[0];
    assert_eq!(
        data.detail,
        "v1.2 \u{00B7} official \u{00B7} Enabled \u{00B7} 1 skill \u{00B7} 1 MCP \u{00B7} Hooks"
    );
    assert_eq!(data.skills[0].source_id.as_deref(), Some("s1"));
    assert_eq!(data.skills[0].name, "data:query");
    assert!(data.mcp_servers[0].is_off);
    assert_eq!(data.skills_notice, None);
    let old = &inventory.plugins[1];
    assert_eq!(old.id, "claude:old@community");
    assert_eq!(
        old.mcp_notice.as_deref(),
        Some("This plugin is disabled. Enable it in Claude Code to inspect MCP tools.")
    );
    assert!(
        old.skills_notice
            .as_deref()
            .is_some_and(|text| text.starts_with("Update"))
    );
}

#[test]
fn one_failed_read_leaves_the_others() {
    let core = connected(RouteTransport::local());
    core.transport().respond(
        Some("GET"),
        "/v1/hosts/h1/mcp-servers",
        None,
        Reply::json(
            501,
            r#"{"detail":"update the host to list its MCP servers"}"#,
        ),
    );
    core.transport().ok(
        "/v1/skills",
        r#"{"skills":[{"name":"review","description":"Review a diff"}],"warnings":[]}"#,
    );
    core.transport().respond(
        Some("GET"),
        "/v1/hosts/h1/plugins",
        None,
        Reply::json(404, r#"{"detail":"not found"}"#),
    );
    let read = block_on(core.host_harness_inventory("h1", "claude-native")).unwrap();
    assert_eq!(read.mcp_servers, super::InventoryRead::Unsupported);
    assert_eq!(read.skills, super::InventoryRead::Loaded);
    assert_eq!(read.plugins, super::InventoryRead::Loaded);
    assert_eq!(read.inventory.skills[0].name, "review");
    let skills_read = core
        .transport()
        .taken()
        .into_iter()
        .find(|request| path_of(request) == "/v1/skills")
        .unwrap();
    assert_eq!(query_value(&skills_read, "path").as_deref(), Some("~"));
    assert_eq!(
        query_value(&skills_read, "harness").as_deref(),
        Some("claude-native")
    );
    assert!(matches!(
        block_on(core.host_harness_inventory("h1", "gemini-native")),
        Err(SessionError::InvalidInput { .. })
    ));
}

#[test]
fn reads_mcp_servers_plugins_and_skill_contents() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        "/v1/hosts/h1/mcp-servers",
        r#"{"mcp_servers":[{"name":"github","harness":"claude","transport":"http","scope":"user",
            "managed":false,"enabled":"false","locked":false,"url_host":"api.example.com"}]}"#,
    );
    let servers = block_on(core.host_mcp_servers("h1")).unwrap();
    assert_eq!(servers[0].enabled, Some(false));
    assert_eq!(servers[0].url_host.as_deref(), Some("api.example.com"));

    core.transport().respond(
        Some("GET"),
        "/v1/hosts/h1/plugins",
        None,
        Reply::json(
            501,
            r#"{"detail":"update the host to see installed plugins"}"#,
        ),
    );
    assert_eq!(block_on(core.host_plugins("h1")), Ok(None));
    core.transport().respond(
        Some("GET"),
        "/v1/hosts/h1/plugins",
        None,
        Reply::json(
            200,
            r#"{"plugins":[{"id":"p1","harness":"claude","name":"data","marketplace":"m",
            "enabled":true,"skills":["q"],"mcp_servers":[],"has_hooks":false,
            "has_commands":true,"skill_entries":[{"id":"s1","name":"q"}]}]}"#,
        ),
    );
    let plugins = block_on(core.host_plugins("h1")).unwrap().unwrap();
    assert!(plugins[0].has_skill_entries && !plugins[0].has_mcp_entries);

    core.transport().ok(
        "/v1/hosts/h1/harnesses/claude-native/skills/data:q",
        r##"{"name":"data:q","description":"Query","content":"# Q","truncated":true}"##,
    );
    let content =
        block_on(core.host_skill_content("h1", "claude-native", "data:q", Some("s1"))).unwrap();
    assert!(content.truncated && content.content == "# Q");
    let request = core.transport().taken().pop().unwrap();
    assert_eq!(query_value(&request, "source_id").as_deref(), Some("s1"));
    assert!(path_of(&request).ends_with("/skills/data:q"));
    assert!(matches!(
        block_on(core.host_skill_content("h1", "claude-native", "../etc", None)),
        Err(SessionError::InvalidIdentifier { .. })
    ));

    core.transport().respond(
        Some("GET"),
        "/v1/hosts/h1/mcp-servers",
        None,
        Reply::json(
            409,
            r#"{"error":{"code":"conflict","message":"host is offline"}}"#,
        ),
    );
    assert!(matches!(
        block_on(core.host_mcp_servers("h1")),
        Err(SessionError::HttpStatus { status: 409 })
    ));
}
