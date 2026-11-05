//! Server settings: capability gating, members, policies, sharing, the MCP registry, provider
//! connections, password change, import and archived sessions.

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::test_support::{
    Reply, RouteTransport, body_json, connected, path_of, query_value,
};
use super::{
    DefaultPolicy, ImportResult, Member, ProviderConnection, ServerSettingsInfo, SharingUpdate,
};

#[test]
fn info_reads_admin_mode_and_known_connections() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        "/v1/info",
        r#"{"single_user":false,"accounts_enabled":true,"archive_worktree_cleanup":true,
            "login_url":"/login","enabled_connections":["mcp","github","slack","databricks"],
            "agent_install":true,"agent_detail":true,
            "features":{"custom_agents_settings_ui":true}}"#,
    );
    assert_eq!(
        block_on(core.server_settings_info()).unwrap(),
        ServerSettingsInfo {
            user_id: "local".into(),
            is_admin: true,
            single_user: false,
            accounts_enabled: true,
            mcp_registry: true,
            connections: vec!["github".into(), "databricks".into()],
            archive_worktree_cleanup: true,
            has_login_session: true,
            custom_agents: true,
            agent_detail: true,
        }
    );

    // An older server's info: every capability off.
    let core = connected(RouteTransport::local());
    let info = block_on(core.server_settings_info()).unwrap();
    assert!(info.single_user && !info.mcp_registry && info.connections.is_empty());
    assert!(!info.archive_worktree_cleanup && !info.has_login_session);
    assert!(!info.custom_agents && !info.agent_detail);

    // The Custom Agents page also needs `agent_install`.
    let core = connected(RouteTransport::local());
    core.transport().ok(
        "/v1/info",
        r#"{"single_user":true,"features":{"custom_agents_settings_ui":true}}"#,
    );
    assert!(!block_on(core.server_settings_info()).unwrap().custom_agents);
}

#[test]
fn info_reads_an_sso_login_session_without_accounts() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        "/v1/info",
        r#"{"single_user":false,"accounts_enabled":false,"login_url":"/auth/oidc/login"}"#,
    );
    let info = block_on(core.server_settings_info()).unwrap();
    assert!(info.has_login_session && !info.accounts_enabled);

    // Header single-user mode reports a null login URL.
    let core = connected(RouteTransport::local());
    core.transport()
        .ok("/v1/info", r#"{"single_user":true,"login_url":null}"#);
    assert!(
        !block_on(core.server_settings_info())
            .unwrap()
            .has_login_session
    );
}

#[test]
fn members_list_remove_and_reset_by_user_id() {
    let transport = RouteTransport::local();
    transport.ok(
        "/auth/users",
        r#"{"users":[{"id":"ada@example.com","is_admin":true,"created_at":1700000000.5,
            "last_login_at":null,"has_password":true}]}"#,
    );
    transport.respond(
        Some("DELETE"),
        "/auth/users/ada@example.com",
        None,
        Reply::json(204, ""),
    );
    transport.ok(
        "/auth/users/ada@example.com/reset",
        r#"{"id":"ada@example.com","new_password":"fresh"}"#,
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.members()).unwrap(),
        vec![Member {
            id: "ada@example.com".into(),
            is_admin: true,
            created_at: Some(1_700_000_000),
            last_login_at: None,
            has_password: true,
        }]
    );
    block_on(core.remove_member("ada@example.com")).unwrap();
    assert_eq!(
        block_on(core.reset_member_password("ada@example.com")).unwrap(),
        "fresh"
    );
    assert_eq!(
        block_on(core.remove_member("..")),
        Err(SessionError::InvalidIdentifier { value: "..".into() })
    );
    let paths: Vec<String> = core.transport().writes().iter().map(path_of).collect();
    assert_eq!(
        paths,
        [
            "/auth/users/ada@example.com",
            "/auth/users/ada@example.com/reset"
        ]
    );
}

#[test]
fn members_report_a_non_admin_as_forbidden() {
    let transport = RouteTransport::local();
    transport.respond(
        None,
        "/auth/users",
        None,
        Reply::json(403, r#"{"error":"admin only"}"#),
    );
    let core = connected(transport);
    assert_eq!(block_on(core.members()), Err(SessionError::Forbidden));
}

#[test]
fn password_change_validates_before_sending() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("POST"),
        "/auth/users/me/password",
        None,
        Reply::json(204, ""),
    );
    let core = connected(transport);
    assert!(matches!(
        block_on(core.change_password("", "long enough")),
        Err(SessionError::Rejected { status: 400, .. })
    ));
    assert!(matches!(
        block_on(core.change_password("old", "short")),
        Err(SessionError::Rejected { status: 400, .. })
    ));
    assert_eq!(core.transport().writes().len(), 0);
    block_on(core.change_password("old", "long enough")).unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        [json!({"old_password": "old", "new_password": "long enough"})]
    );
}

#[test]
fn policies_list_toggle_and_delete() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("GET"),
        "/v1/policies",
        None,
        Reply::json(
            200,
            r#"{"object":"list","data":[
                {"id":"pol-1","name":"Ask","handler":"a.b","enabled":true},
                {"id":null,"name":"Config","handler":"c.d","enabled":true,"source":"config"}]}"#,
        ),
    );
    transport.respond(
        Some("PATCH"),
        "/v1/policies/pol-1",
        None,
        Reply::json(
            200,
            r#"{"id":"pol-1","name":"Ask","handler":"a.b","enabled":false}"#,
        ),
    );
    transport.respond(
        Some("DELETE"),
        "/v1/policies/pol-1",
        None,
        Reply::json(204, ""),
    );
    let core = connected(transport);
    let policies = block_on(core.default_policies()).unwrap();
    assert_eq!(
        policies[1],
        DefaultPolicy {
            id: None,
            name: "Config".into(),
            handler: "c.d".into(),
            enabled: true,
            from_config: true,
        }
    );
    let toggled = block_on(core.set_default_policy_enabled("pol-1", false)).unwrap();
    assert!(!toggled.enabled && !toggled.from_config);
    block_on(core.delete_default_policy("pol-1")).unwrap();
    assert_eq!(
        core.transport().write_bodies()[0],
        json!({"enabled": false})
    );
}

#[test]
fn sharing_reads_and_sends_only_the_changed_fields() {
    let state = r#"{"object":"sharing","sharing_mode":"on","editable":true,
        "options":["on","read_only","off"],"public_sharing_enabled":false,
        "public_sharing_editable":true,"default_public_sessions":"off",
        "default_public_sessions_editable":false,"default_public_sessions_options":["off","all"]}"#;
    let transport = RouteTransport::local();
    transport.ok("/v1/sharing", state);
    let core = connected(transport);
    let sharing = block_on(core.sharing_settings()).unwrap();
    assert_eq!(sharing.mode, "on");
    assert_eq!(sharing.mode_options, ["on", "read_only", "off"]);
    assert!(sharing.public_sharing_editable && !sharing.default_public_sessions_editable);
    assert_eq!(sharing.public_max_level, None);

    assert!(matches!(
        block_on(core.update_sharing(&SharingUpdate::default())),
        Err(SessionError::Rejected { status: 400, .. })
    ));
    let update = SharingUpdate {
        public_sharing: Some(true),
        ..SharingUpdate::default()
    };
    block_on(core.update_sharing(&update)).unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        [json!({"public_sharing": true})]
    );
}

#[test]
fn mcp_services_follow_pages_and_connect_with_a_token() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "GET",
        "/v1/mcp-registry/services",
        vec![
            Reply::json(
                200,
                r#"{"data":[{"id":"docs","title":"Docs","auth":"bearer","connected":false,
                    "tools":["search"]}],"next_cursor":"docs"}"#,
            ),
            Reply::json(
                200,
                r#"{"data":[{"id":"wiki","title":"Wiki","auth":"oauth","connected":true}],
                    "next_cursor":null}"#,
            ),
        ],
    );
    transport.ok(
        "/v1/mcp-registry/services/docs/connection",
        r#"{"connected":true}"#,
    );
    transport.ok(
        "/v1/mcp-registry/services/wiki/test",
        r#"{"tools":["read","write"]}"#,
    );
    let core = connected(transport);
    let services = block_on(core.mcp_services()).unwrap();
    assert_eq!(services.len(), 2);
    assert!(services[0].accepts_token() && !services[0].can_disconnect());
    assert!(services[1].can_disconnect());
    let reads: Vec<Option<String>> = core
        .transport()
        .taken()
        .iter()
        .filter(|request| path_of(request) == "/v1/mcp-registry/services")
        .map(|request| query_value(request, "after"))
        .collect();
    assert_eq!(reads, [None, Some("docs".into())]);

    assert!(matches!(
        block_on(core.connect_mcp_service("docs", "two words")),
        Err(SessionError::Rejected { status: 400, .. })
    ));
    block_on(core.connect_mcp_service("docs", " tok ")).unwrap();
    assert_eq!(core.transport().write_bodies(), [json!({"token": "tok"})]);
    assert_eq!(
        block_on(core.test_mcp_service("wiki")).unwrap(),
        ["read", "write"]
    );
}

#[test]
fn provider_connections_name_the_account() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/connections/github/status",
        r#"{"enabled":true,"connected":true,"login":"octocat"}"#,
    );
    transport.ok(
        "/v1/connections/databricks/status",
        r#"{"enabled":true,"connected":true,"databricks_user":"ada","workspace_host":"w.cloud"}"#,
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.provider_connection("github")).unwrap(),
        ProviderConnection {
            provider: "github".into(),
            connected: true,
            account: Some("octocat".into()),
        }
    );
    assert_eq!(
        block_on(core.provider_connection("databricks"))
            .unwrap()
            .account
            .as_deref(),
        Some("ada at w.cloud")
    );
    assert!(matches!(
        block_on(core.provider_connection("../info")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}

#[test]
fn import_lists_online_hosts_and_reports_the_tally() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/hosts",
        r#"{"hosts":[{"host_id":"h2","name":"zeta","status":"online"},
            {"host_id":"h1","name":"alpha","status":"online"},
            {"host_id":"h3","name":"gone","status":"offline"},
            {"host_id":"h4","name":"box","status":"online","sandbox_provider":"modal"}]}"#,
    );
    transport.ok(
        "/v1/imports/local",
        r#"{"imported":2,"already_imported":1,"failed":1,"sessions":[],
            "failures":[{"external_session_id":"x1","source":"codex","reason":"unreadable"}]}"#,
    );
    let core = connected(transport);
    let names: Vec<String> = block_on(core.import_hosts())
        .unwrap()
        .into_iter()
        .map(|host| host.name)
        .collect();
    assert_eq!(names, ["alpha", "zeta"]);
    assert!(matches!(
        block_on(core.import_local_sessions("h1", "vim", 10, None)),
        Err(SessionError::InvalidIdentifier { .. })
    ));
    assert_eq!(
        block_on(core.import_local_sessions("h1", "all", 0, None)),
        Err(SessionError::InvalidPageLimit { limit: 0 })
    );
    assert_eq!(
        block_on(core.import_local_sessions("h1", "codex", 25, None)).unwrap(),
        ImportResult {
            imported: 2,
            already_imported: 1,
            failed: 1,
            failures: vec!["x1: unreadable".into()],
        }
    );
    assert_eq!(
        body_json(&core.transport().writes()[0]),
        json!({"host_id": "h1", "source": "codex", "limit": 25})
    );
}

#[test]
fn import_by_session_id_sends_the_trimmed_id_for_one_harness() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/imports/local",
        r#"{"imported":1,"already_imported":0,"failed":0}"#,
    );
    let core = connected(transport);
    for (id, source) in [("  ", "claude"), ("abc", "all")] {
        assert!(matches!(
            block_on(core.import_local_sessions("h1", source, 1, Some(id))),
            Err(SessionError::Rejected { status: 400, .. })
        ));
    }
    let long = "x".repeat(129);
    assert!(matches!(
        block_on(core.import_local_sessions("h1", "claude", 1, Some(&long))),
        Err(SessionError::Rejected { status: 400, .. })
    ));
    assert_eq!(core.transport().writes().len(), 0);
    assert_eq!(
        block_on(core.import_local_sessions("h1", "claude", 25, Some(" sess-1 ")))
            .unwrap()
            .imported,
        1
    );
    assert_eq!(
        body_json(&core.transport().writes()[0]),
        json!({"host_id": "h1", "source": "claude", "limit": 25, "session_id": "sess-1"})
    );
}

#[test]
fn archived_page_asks_for_archived_and_drops_others() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sessions",
        r#"{"object":"list","data":[
            {"id":"a1","title":"Old","status":"idle","created_at":1,"updated_at":2,"archived":true},
            {"id":"b2","title":"Live","status":"idle","created_at":1,"updated_at":3,"archived":false}],
            "has_more":false}"#,
    );
    let core = connected(transport);
    let page = block_on(core.archived_session_page(None, 50)).unwrap();
    let ids: Vec<&str> = page.sessions.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(ids, ["a1"]);
    let list = core
        .transport()
        .taken()
        .into_iter()
        .find(|request| path_of(request) == "/v1/sessions")
        .unwrap();
    assert_eq!(
        query_value(&list, "visibility").as_deref(),
        Some("archived")
    );
}
