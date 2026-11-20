//! The extension bridge: catalog, documents, messages, permissions and method parameters.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};

use super::*;

fn identity() -> ExtensionIdentity {
    ExtensionIdentity {
        extension_id: "example.hello-page".to_owned(),
        page_id: "example.hello-page.home".to_owned(),
        view: "hello".to_owned(),
        nonce: "0a1b2c".to_owned(),
        api_version: EXTENSION_RPC_VERSION,
    }
}

fn message(kind: &str, extra: &Value) -> String {
    let mut message = json!({
        "source": EXTENSION_RPC_SOURCE, "type": kind, "extensionId": "example.hello-page",
        "pageId": "example.hello-page.home", "view": "hello", "nonce": "0a1b2c", "apiVersion": 1,
    });
    if let (Some(target), Some(extra)) = (message.as_object_mut(), extra.as_object()) {
        target.extend(extra.clone());
    }
    message.to_string()
}

fn page(id: &str, route: &str) -> ExtensionPage {
    ExtensionPage {
        id: id.to_owned(),
        title: "Page".to_owned(),
        route: route.to_owned(),
        view: "view".to_owned(),
    }
}

fn catalog_item(id: &str, navigation: &Value) -> Value {
    json!({"id": id, "display_name": id, "version": "1", "status": "enabled",
           "permissions": [], "pages": [{"id": format!("{id}.home"), "title": "Home",
           "route": "home", "view": "home"}], "primary_navigation": navigation,
           "browser": {"declared": false, "has_styles": false}})
}

#[test]
fn navigation_sorts_by_order_then_id_across_extensions_and_skips_missing_pages() {
    let catalog = json!({"object": "list", "data": [
        catalog_item("example.b", &json!([
            {"id": "b.second", "label": "B", "page": "example.b.home", "icon": null, "order": 5},
            {"id": "b.gone", "label": "Gone", "page": "example.b.missing", "order": 0}])),
        catalog_item("example.a", &json!([
            {"id": "a.first", "label": "A", "page": "example.a.home", "icon": "search", "order": 5}])),
    ]});
    let extensions = decode_catalog(&catalog).unwrap();
    assert_eq!(extensions[0].bundle, None, "no declared bundle");
    let entries = navigation_entries(&extensions);
    let ids: Vec<&str> = entries
        .iter()
        .map(|entry| entry.navigation.id.as_str())
        .collect();
    assert_eq!(ids, ["a.first", "b.second"]);
    assert_eq!(entries[0].page.route, "home");
    let (extension, page) = resolve_page(&extensions, "example.b", "home").unwrap();
    assert_eq!(
        (extension.id.as_str(), page.id.as_str()),
        ("example.b", "example.b.home")
    );
    assert!(resolve_page(&extensions, "example.b", "nowhere").is_none());
}

#[test]
fn the_catalog_refuses_routes_and_assets_it_cannot_address() {
    let bad_route = json!({"object": "list", "data": [{"id": "example.a", "display_name": "A",
        "status": "enabled", "pages": [{"id": "p", "title": "P", "route": "a/b", "view": "v"}]}]});
    assert!(
        decode_catalog(&bad_route)
            .unwrap_err()
            .contains("one path segment")
    );
    let foreign_asset = json!({"object": "list", "data": [{"id": "example.a", "display_name": "A",
        "status": "enabled", "browser": {"digest": "d1",
        "script_url": "/v1/extensions/example.b/assets/d1/extension.js"}}]});
    assert!(
        decode_catalog(&foreign_asset)
            .unwrap_err()
            .contains("assets")
    );
    assert!(decode_catalog(&json!({"data": []})).is_err(), "not a list");
}

#[test]
fn the_document_bootstraps_the_identity_styles_and_script_under_a_nonce_policy() {
    let document = build_extension_document("alert('</script>')", "body{}", &identity());
    assert!(document.contains("script-src 'nonce-0a1b2c'"));
    assert!(document.contains("connect-src 'none'"));
    assert!(document.contains("<script nonce=\"0a1b2c\">"));
    assert!(document.contains(r#""extensionId":"example.hello-page""#));
    assert!(document.contains(&STANDARD.encode("alert('</script>')")));
    assert!(document.contains(&STANDARD.encode("body{}")));
    assert_eq!(
        document.matches("</script>").count(),
        1,
        "the bundle can't end the bootstrap"
    );
}

#[test]
fn the_host_page_frames_the_document_sandboxed_to_scripts() {
    let page = build_host_page("<p>\"hi\"</script>", "A \"page\" <b>", "0a1b2c");
    assert!(page.contains("sandbox=\"allow-scripts\""));
    assert!(page.contains("title=\"A &quot;page&quot; &lt;b&gt;\""));
    assert!(page.contains("messageHandlers.omnigentExtension"));
    assert_eq!(
        page.matches("</script>").count(),
        1,
        "the document can't end the relay"
    );
    assert!(page.contains(r"</script>"));
}

#[test]
fn inbound_messages_must_match_the_mount_and_fit_the_budget() {
    let identity = identity();
    assert_eq!(
        parse_inbound(&message("ready", &json!({})), &identity),
        Some(ExtensionInbound::Ready)
    );
    let request = message(
        "request",
        &json!({"requestId": "r1", "method": "theme.getCurrent", "params": {}}),
    );
    assert_eq!(
        parse_inbound(&request, &identity),
        Some(ExtensionInbound::Request {
            request_id: "r1".to_owned(),
            method: "theme.getCurrent".to_owned(),
            params: Some(json!({})),
        })
    );
    let mut other_mount = identity.clone();
    other_mount.nonce = "ffff".to_owned();
    assert_eq!(parse_inbound(&request, &other_mount), None);
    let huge = message(
        "request",
        &json!({"requestId": "r2", "method": "storage.user.set",
                "params": {"key": "k", "value": "x".repeat(40_000)}}),
    );
    assert_eq!(
        parse_inbound(&huge, &identity),
        None,
        "80 KB counted as UTF-16 bytes"
    );
    let deep = (0..25).fold(json!(1), |inner, _| json!([inner]));
    let nested = message(
        "request",
        &json!({"requestId": "r3", "method": "m", "params": deep}),
    );
    assert_eq!(
        parse_inbound(&nested, &identity),
        None,
        "over 20 levels deep"
    );
    assert_eq!(
        parse_inbound(&message("cancel", &json!({})), &identity),
        None,
        "no requestId"
    );
    assert_eq!(parse_inbound("not json", &identity), None);
    assert_eq!(
        parse_inbound(
            &message("incompatible", &json!({"sdkApiVersion": 2})),
            &identity
        ),
        Some(ExtensionInbound::Incompatible {
            sdk_api_version: 2.0
        })
    );
}

#[test]
fn permissions_grant_only_their_methods() {
    let granted = granted_host_methods(&["navigation".to_owned()]);
    assert!(granted.contains(&"navigation.openPage".to_owned()));
    assert!(
        granted.contains(&"theme.getCurrent".to_owned()),
        "theme needs no permission"
    );
    assert!(!granted.contains(&"storage.user.get".to_owned()));
    let mut sorted = granted.clone();
    sorted.sort();
    assert_eq!(granted, sorted);
    assert_eq!(
        host_method_permission("projects.create"),
        Some(Some("projects.write"))
    );
    assert_eq!(host_method_permission("theme.subscribe"), Some(None));
    assert_eq!(host_method_permission("files.read"), None);
}

#[test]
fn responses_carry_the_result_or_say_it_is_too_large() {
    let identity = identity();
    let ok: Value = serde_json::from_str(&response_message(
        &identity,
        "r1",
        "theme.getCurrent",
        &theme_result(true),
    ))
    .unwrap();
    assert_eq!(ok["type"], "response");
    assert_eq!(ok["result"], json!({"theme": "dark"}));
    let large = json!("x".repeat(40_000));
    let refused: Value = serde_json::from_str(&response_message(
        &identity,
        "r2",
        "storage.user.get",
        &large,
    ))
    .unwrap();
    assert_eq!(refused["error"]["code"], "ResponseTooLarge");
    let page: Value = serde_json::from_str(&response_message(
        &identity,
        "r3",
        "sessions.listPage",
        &large,
    ))
    .unwrap();
    assert_eq!(page["result"], large, "a session page has a larger budget");
    let failed: Value = serde_json::from_str(&error_response_message(
        &identity,
        "r4",
        "HostError",
        &"e".repeat(600),
    ))
    .unwrap();
    assert_eq!(
        failed["error"]["message"].as_str().unwrap().len(),
        MAX_ERROR_CHARS
    );
    let init: Value = serde_json::from_str(&init_message(
        &identity,
        &["b".to_owned(), "a".to_owned(), "a".to_owned()],
    ))
    .unwrap();
    assert_eq!(init["capabilities"], json!(["a", "b"]));
    assert!(event_message(&identity, "theme.changed", &theme_result(false)).is_some());
    assert!(event_message(&identity, "big", &large).is_none());
    assert!(dispose_message(&identity).contains(r#""type":"dispose""#));
}

#[test]
fn method_parameters_are_checked_as_the_web_checks_them() {
    let pages = [page("p.home", "home")];
    assert_eq!(
        page_route_param(
            Some(&json!({"pageId": "p.home", "params": {"tab": 2}})),
            &pages
        )
        .unwrap(),
        "home"
    );
    assert_eq!(
        page_route_param(Some(&json!({"pageId": "elsewhere"})), &pages)
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    assert_eq!(
        page_route_param(
            Some(&json!({"pageId": "p.home", "params": {"x": [1]}})),
            &pages
        )
        .unwrap_err()
        .message,
        "Page parameter x is invalid"
    );
    assert_eq!(
        session_id_param(Some(&json!({"sessionId": ""})))
            .unwrap_err()
            .message,
        "sessionId is invalid"
    );
    assert_eq!(new_session_project_param(None), Ok(None));
    assert_eq!(
        new_session_project_param(Some(&json!({"projectId": null}))),
        Ok(None)
    );
    assert_eq!(
        new_session_project_param(Some(&json!({"projectId": "proj_1"}))),
        Ok(Some("proj_1".to_owned()))
    );
    assert_eq!(
        new_session_project_param(Some(&json!(null)))
            .unwrap_err()
            .code,
        "InvalidParams"
    );
    assert_eq!(
        external_url_param(Some(&json!({"url": 3})))
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    assert_eq!(
        project_name_param(Some(&json!({"name": "  Docs  "}))).unwrap(),
        "Docs"
    );
    assert!(project_name_param(Some(&json!({"name": "   "}))).is_err());
}

#[test]
fn storage_keys_and_values_follow_the_web_limits() {
    assert_eq!(
        storage_key_param(Some(&json!({"key": "prefs.v1"}))).unwrap(),
        "prefs.v1"
    );
    for key in [
        json!(""),
        json!(".hidden"),
        json!("a/b"),
        json!("k".repeat(129)),
        json!(5),
    ] {
        assert_eq!(
            storage_key_param(Some(&json!({"key": key})))
                .unwrap_err()
                .code,
            "InvalidKey"
        );
    }
    assert_eq!(
        storage_key_param(Some(&json!([]))).unwrap_err().code,
        "InvalidParams"
    );
    let write = storage_write_param(Some(&json!({"key": "k", "value": {"a": [1, true]}}))).unwrap();
    assert_eq!((write.json.as_str(), write.size), (r#"{"a":[1,true]}"#, 14));
    assert_eq!(
        storage_write_param(Some(&json!({"key": "k"})))
            .unwrap_err()
            .code,
        "InvalidValue"
    );
    let large = json!({"key": "k", "value": "x".repeat(32 * 1024)});
    assert_eq!(
        storage_write_param(Some(&large)).unwrap_err().code,
        "QuotaExceeded"
    );
}

#[test]
fn projects_and_pull_requests_are_bounded_projections() {
    let project = project_result(Some("proj_1"), &"n".repeat(150), Some("🚀")).unwrap();
    assert_eq!(project["name"].as_str().unwrap().chars().count(), 100);
    assert_eq!(
        project_result(None, "Label only", None).unwrap_err().code,
        "HostError"
    );
    let projects = cached_projects_result(&[
        (Some("proj_1".to_owned()), "One".to_owned(), None),
        (None, "Label".to_owned(), None),
    ]);
    assert_eq!(
        projects,
        json!([{"id": "proj_1", "name": "One", "icon": null}])
    );
    assert_eq!(
        pull_request_result(4, "T", "open", "http://example.com/pr/4"),
        Value::Null
    );
    assert_eq!(
        pull_request_result(4, "T", "open", "https://example.com/pr/4")["number"],
        json!(4)
    );
}

fn row(id: &str) -> ExtensionSessionRow {
    ExtensionSessionRow {
        id: id.to_owned(),
        title: Some("t".repeat(256)),
        title_provisional: false,
        status: "idle".to_owned(),
        unread: false,
        workspace: Some("w".repeat(512)),
        git_branch: None,
        project_id: None,
        created_at: 1.0,
        updated_at: 2.0,
    }
}

#[test]
fn session_page_requests_default_and_bound_the_limit() {
    assert_eq!(
        session_page_request(Some(&json!({}))).unwrap(),
        SessionPageRequest {
            after: None,
            limit: 25
        }
    );
    assert_eq!(
        session_page_request(Some(&json!({"after": "c", "limit": 1000})))
            .unwrap()
            .after
            .as_deref(),
        Some("c")
    );
    for params in [
        json!({"limit": 0}),
        json!({"limit": 1001}),
        json!({"limit": 2.5}),
        json!({"after": ""}),
    ] {
        assert_eq!(
            session_page_request(Some(&params)).unwrap_err().code,
            "InvalidParams",
            "{params}"
        );
    }
}

#[test]
fn a_session_page_keeps_what_fits_and_continues_after_it() {
    let rows: Vec<ExtensionSessionRow> = (0..400)
        .map(|index| row(&format!("conv_{index}")))
        .collect();
    let page = SessionRows {
        rows,
        has_more: false,
        last_id: None,
    };
    let result = session_page_result(&page).unwrap();
    let kept = result["sessions"].as_array().unwrap().len();
    assert!(kept > 0 && kept < 400, "{kept}");
    assert_eq!(result["hasMore"], json!(true));
    assert_eq!(result["nextCursor"], json!(format!("conv_{}", kept - 1)));

    let small = SessionRows {
        rows: vec![row("conv_a")],
        has_more: true,
        last_id: Some("cursor_9".to_owned()),
    };
    assert_eq!(
        session_page_result(&small).unwrap()["nextCursor"],
        json!("cursor_9")
    );
    let lost = SessionRows {
        rows: Vec::new(),
        has_more: true,
        last_id: None,
    };
    assert_eq!(session_page_result(&lost).unwrap_err().code, "HostError");
    assert_eq!(
        cached_sessions_result(&[row("conv_a"), row("conv_b")], 1)
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn session_rows_reject_malformed_pages() {
    let page = json!({"data": [{"id": "conv_a", "status": "waiting", "created_at": 1,
        "updated_at": 2, "title": "t".repeat(300)}], "has_more": false});
    let rows = decode_session_rows(&page, 25).unwrap();
    assert_eq!(rows.rows[0].title.as_ref().unwrap().chars().count(), 256);
    let too_many = json!({"data": [{"id": "a"}, {"id": "b"}], "has_more": false});
    assert_eq!(
        decode_session_rows(&too_many, 1).unwrap_err().message,
        "Session list response is malformed"
    );
    let no_paging = json!({"data": []});
    assert_eq!(
        decode_session_rows(&no_paging, 1).unwrap_err().message,
        "Session pagination is malformed"
    );
}
