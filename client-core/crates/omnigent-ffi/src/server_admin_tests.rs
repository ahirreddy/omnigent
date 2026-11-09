//! The Settings window's server calls over the fake host: every field of each record and each
//! export's request.

#![allow(
    clippy::too_many_lines,
    reason = "each record's fields are asserted together"
)]

use serde_json::json;

use crate::errors::CoreError;
use crate::server_admin::{
    DefaultPolicyRecord, ImportHostRecord, ImportResultRecord, ProviderConnectionRecord,
    ServerMemberRecord, ServerSettingsInfo, SharingUpdateRecord, import_sources, max_import_limit,
    min_password_length,
};
use crate::sessions::SessionListStatus;
use crate::test_support::{connected, json as reply};

#[test]
fn settings_info_maps_each_capability_to_its_own_field() {
    let mut harness = connected();
    harness.http.route(
        "/v1/info",
        reply(
            200,
            r#"{"single_user":false,"accounts_enabled":true,"archive_worktree_cleanup":true,
                "login_url":"/login","enabled_connections":["mcp","github"],
                "agent_install":true,"agent_detail":false,
                "features":{"custom_agents_settings_ui":true}}"#,
        ),
    );
    harness
        .http
        .route("/v1/me", reply(200, r#"{"user_id":"ada","is_admin":true}"#));
    let info = harness
        .call(|core| async move { core.server_settings_info().await })
        .unwrap();
    assert_eq!(
        info,
        ServerSettingsInfo {
            user_id: "ada".into(),
            is_admin: true,
            single_user: false,
            accounts_enabled: true,
            mcp_registry: true,
            connections: vec!["github".into()],
            archive_worktree_cleanup: true,
            has_login_session: true,
            custom_agents: true,
            agent_detail: false,
        }
    );
    harness.http.route(
        "/v1/info",
        reply(200, r#"{"single_user":true,"agent_detail":true}"#),
    );
    let info = harness
        .call(|core| async move { core.server_settings_info().await })
        .unwrap();
    assert!(info.single_user && info.agent_detail);
    assert!(!info.accounts_enabled && !info.mcp_registry && !info.has_login_session);
    assert!(!info.archive_worktree_cleanup && !info.custom_agents);
}

#[test]
fn members_are_listed_removed_and_reset_by_id() {
    let mut harness = connected();
    harness.http.route_method(
        "GET",
        "/auth/users",
        reply(
            200,
            r#"{"users":[{"id":"ada","is_admin":true,"created_at":-5,"last_login_at":9007199254740993,"has_password":true}]}"#,
        ),
    );
    harness
        .http
        .route_method("DELETE", "/auth/users/ada", reply(204, ""));
    harness.http.route(
        "/auth/users/ada/reset",
        reply(200, r#"{"id":"ada","new_password":"fresh"}"#),
    );
    harness
        .http
        .route("/auth/users/me/password", reply(204, ""));
    let members = harness
        .call(|core| async move { core.server_members().await })
        .unwrap();
    assert_eq!(
        members,
        [ServerMemberRecord {
            id: "ada".into(),
            is_admin: true,
            created_at: Some(-5),
            last_login_at: Some(9_007_199_254_740_993),
            has_password: true,
        }]
    );
    harness
        .call(|core| async move { core.remove_server_member("ada".into()).await })
        .unwrap();
    assert_eq!(harness.last_request().0, "DELETE /auth/users/ada");
    let password = harness
        .call(|core| async move { core.reset_server_member_password("ada".into()).await })
        .unwrap();
    assert_eq!(password, "fresh");
    assert_eq!(harness.last_request().0, "POST /auth/users/ada/reset");
    harness
        .call(|core| async move {
            core.change_password("old".into(), "long enough".into())
                .await
        })
        .unwrap();
    assert_eq!(
        harness.last_request(),
        (
            "POST /auth/users/me/password".into(),
            json!({"old_password": "old", "new_password": "long enough"})
        )
    );
}

#[test]
fn a_forbidden_member_list_is_a_session_error() {
    let mut harness = connected();
    harness
        .http
        .route("/auth/users", reply(403, r#"{"error":"admin only"}"#));
    let error = harness
        .call(|core| async move { core.server_members().await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Session { .. }), "{error:?}");
}

#[test]
fn policies_are_listed_toggled_and_deleted() {
    let mut harness = connected();
    harness.http.route_method(
        "GET",
        "/v1/policies",
        reply(
            200,
            r#"{"data":[{"id":"p1","name":"Ask","handler":"a.b","enabled":true},
                {"id":null,"name":"Config","handler":"c.d","enabled":false,"source":"config"}]}"#,
        ),
    );
    harness.http.route_method(
        "PATCH",
        "/v1/policies/p1",
        reply(
            200,
            r#"{"id":"p1","name":"Ask","handler":"a.b","enabled":false}"#,
        ),
    );
    harness
        .http
        .route_method("DELETE", "/v1/policies/p1", reply(204, ""));
    let policies = harness
        .call(|core| async move { core.default_policies().await })
        .unwrap();
    assert_eq!(
        policies,
        [
            DefaultPolicyRecord {
                id: Some("p1".into()),
                name: "Ask".into(),
                handler: "a.b".into(),
                enabled: true,
                from_config: false,
            },
            DefaultPolicyRecord {
                id: None,
                name: "Config".into(),
                handler: "c.d".into(),
                enabled: false,
                from_config: true,
            }
        ]
    );
    let toggled = harness
        .call(|core| async move { core.set_default_policy_enabled("p1".into(), false).await })
        .unwrap();
    assert!(!toggled.enabled);
    assert_eq!(
        harness.last_request(),
        ("PATCH /v1/policies/p1".into(), json!({"enabled": false}))
    );
    harness
        .call(|core| async move { core.delete_default_policy("p1".into()).await })
        .unwrap();
    assert_eq!(harness.last_request().0, "DELETE /v1/policies/p1");
}

#[test]
fn sharing_maps_every_setting_and_sends_only_what_changed() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sharing",
        reply(
            200,
            r#"{"sharing_mode":"read_only","editable":true,"options":["on","off"],
                "public_sharing_enabled":true,"public_sharing_editable":false,
                "public_sharing_max_level":"view","public_sharing_max_level_editable":true,
                "public_sharing_max_level_options":["view","edit"],
                "default_public_sessions":"all","default_public_sessions_editable":false,
                "default_public_sessions_options":["off","all"]}"#,
        ),
    );
    let sharing = harness
        .call(|core| async move { core.sharing_settings().await })
        .unwrap();
    assert_eq!(sharing.mode, "read_only");
    assert!(sharing.mode_editable);
    assert_eq!(sharing.mode_options, ["on", "off"]);
    assert!(sharing.public_sharing);
    assert!(!sharing.public_sharing_editable);
    assert_eq!(sharing.public_max_level.as_deref(), Some("view"));
    assert!(sharing.public_max_level_editable);
    assert_eq!(sharing.public_max_level_options, ["view", "edit"]);
    assert_eq!(sharing.default_public_sessions.as_deref(), Some("all"));
    assert!(!sharing.default_public_sessions_editable);
    assert_eq!(sharing.default_public_sessions_options, ["off", "all"]);

    let updated = harness
        .call(|core| async move {
            core.update_sharing(SharingUpdateRecord {
                mode: Some("off".into()),
                public_sharing: Some(false),
                public_max_level: Some("edit".into()),
                default_public_sessions: Some("none".into()),
            })
            .await
        })
        .unwrap();
    assert_eq!(updated.mode, "read_only");
    let (line, body) = harness.last_request();
    assert_eq!(line, "PUT /v1/sharing");
    assert_eq!(body["public_sharing"], json!(false));
    assert_eq!(body["public_sharing_max_level"], json!("edit"));
    assert_eq!(body["default_public_sessions"], json!("none"));
    assert_eq!(body["sharing_mode"], json!("off"));
}

#[test]
fn archived_sessions_ask_for_the_archive_and_keep_the_cursor() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions",
        reply(
            200,
            r#"{"data":[{"id":"a1","title":"Old","status":"idle","created_at":1,"updated_at":2,"archived":true}],
                "has_more":true,"last_id":"a1"}"#,
        ),
    );
    let page = harness
        .call(|core| async move { core.archived_sessions(Some("z".into()), 50).await })
        .unwrap();
    assert_eq!(
        harness.last_query("visibility").as_deref(),
        Some("archived")
    );
    assert_eq!(harness.last_query("after").as_deref(), Some("z"));
    assert_eq!(page.sessions[0].id, "a1");
    assert_eq!(page.sessions[0].status, SessionListStatus::Idle);
    assert!(page.sessions[0].is_archived);
    assert_eq!(page.next_cursor.as_deref(), Some("a1"));
}

#[test]
fn mcp_services_derive_what_each_auth_kind_offers() {
    let mut harness = connected();
    harness.http.route(
        "/v1/mcp-registry/services",
        reply(
            200,
            r#"{"data":[
                {"id":"docs","title":"Docs","description":"D","auth":"bearer","connected":false,"tools":["search"]},
                {"id":"wiki","title":"Wiki","auth":"oauth","connected":false},
                {"id":"oauthed","title":"O","auth":"oauth","connected":true},
                {"id":"open","title":"Open","auth":"none","connected":false},
                {"id":"gh","title":"GH","auth":"github","connected":true}]}"#,
        ),
    );
    let services = harness
        .call(|core| async move { core.mcp_services().await })
        .unwrap();
    let flags: Vec<(&str, bool, bool, bool, bool)> = services
        .iter()
        .map(|service| {
            (
                service.id.as_str(),
                service.connected,
                service.accepts_token,
                service.can_disconnect,
                service.connects_in_browser,
            )
        })
        .collect();
    assert_eq!(
        flags,
        [
            ("docs", false, true, false, false),
            ("wiki", false, false, false, true),
            ("oauthed", true, false, true, false),
            ("open", false, false, false, false),
            ("gh", true, false, false, false),
        ]
    );
    assert_eq!(services[0].title, "Docs");
    assert_eq!(services[0].description.as_deref(), Some("D"));
    assert_eq!(services[0].tools, ["search"]);

    let connection = "/v1/mcp-registry/services/docs/connection";
    harness
        .http
        .route_method("PUT", connection, reply(200, r#"{"connected":true}"#));
    harness
        .http
        .route_method("POST", connection, reply(200, r#"{"connected":true}"#));
    harness
        .http
        .route_method("DELETE", connection, reply(200, "{}"));
    harness.http.route(
        "/v1/mcp-registry/services/docs/test",
        reply(200, r#"{"tools":["read","write"]}"#),
    );
    harness
        .call(|core| async move {
            core.connect_mcp_service("docs".into(), " tok ".into())
                .await
        })
        .unwrap();
    let (line, body) = harness.last_request();
    assert!(line.ends_with(connection), "{line}");
    assert_eq!(body["token"], json!("tok"));
    harness
        .call(|core| async move { core.disconnect_mcp_service("docs".into()).await })
        .unwrap();
    assert_eq!(harness.last_request().0, format!("DELETE {connection}"));
    assert_eq!(
        harness
            .call(|core| async move { core.test_mcp_service("docs".into()).await })
            .unwrap(),
        ["read", "write"]
    );
}

#[test]
fn provider_connections_read_and_disconnect() {
    let mut harness = connected();
    harness.http.route(
        "/v1/connections/github/status",
        reply(
            200,
            r#"{"enabled":true,"connected":true,"login":"octocat"}"#,
        ),
    );
    harness
        .http
        .route("/v1/connections/github/disconnect", reply(200, "{}"));
    assert_eq!(
        harness
            .call(|core| async move { core.provider_connection("github".into()).await })
            .unwrap(),
        ProviderConnectionRecord {
            provider: "github".into(),
            connected: true,
            account: Some("octocat".into()),
        }
    );
    harness
        .call(|core| async move { core.disconnect_provider("github".into()).await })
        .unwrap();
    assert_eq!(
        harness.last_request().0,
        "POST /v1/connections/github/disconnect"
    );
}

#[test]
fn imports_read_their_hosts_and_post_the_selection() {
    let mut harness = connected();
    harness.http.route(
        "/v1/hosts",
        reply(
            200,
            r#"{"hosts":[{"host_id":"h2","name":"zeta","status":"online"},
                {"host_id":"h1","name":"alpha","status":"online"},
                {"host_id":"h3","name":"off","status":"offline"}]}"#,
        ),
    );
    harness.http.route(
        "/v1/imports/local",
        reply(
            200,
            r#"{"imported":2,"already_imported":3,"failed":1,
                "failures":[{"external_session_id":"x1","reason":"unreadable"}]}"#,
        ),
    );
    assert_eq!(
        harness
            .call(|core| async move { core.import_hosts().await })
            .unwrap(),
        [
            ImportHostRecord {
                host_id: "h1".into(),
                name: "alpha".into()
            },
            ImportHostRecord {
                host_id: "h2".into(),
                name: "zeta".into()
            }
        ]
    );
    let result = harness
        .call(|core| async move {
            core.import_local_sessions("h1".into(), "claude".into(), 25, Some("s1".into()))
                .await
        })
        .unwrap();
    assert_eq!(
        result,
        ImportResultRecord {
            imported: 2,
            already_imported: 3,
            failed: 1,
            failures: vec!["x1: unreadable".into()],
        }
    );
    assert_eq!(
        harness.last_request(),
        (
            "POST /v1/imports/local".into(),
            json!({"host_id": "h1", "source": "claude", "limit": 25, "session_id": "s1"})
        )
    );
}

#[test]
fn the_import_and_password_limits_are_the_cores() {
    let sources = import_sources();
    assert_eq!(
        sources.len(),
        omnigent_core::server_admin::IMPORT_SOURCES.len()
    );
    assert_eq!(
        sources[0].id,
        omnigent_core::server_admin::IMPORT_SOURCES[0].id
    );
    assert_eq!(
        sources[0].title,
        omnigent_core::server_admin::IMPORT_SOURCES[0].title
    );
    assert_eq!(
        max_import_limit(),
        omnigent_core::server_admin::MAX_IMPORT_LIMIT
    );
    assert_eq!(
        usize::try_from(min_password_length()).unwrap(),
        omnigent_core::server_admin::MIN_PASSWORD_CHARS
    );
}
