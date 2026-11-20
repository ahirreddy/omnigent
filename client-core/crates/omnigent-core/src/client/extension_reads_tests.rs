//! Extension reads: the catalog, bundle assets and the session pages host methods answer with.

use futures::executor::block_on;

use super::ExtensionAsset;
use crate::client::SessionError;
use crate::client::test_support::{Reply, RouteTransport, connected, path_of, query_value};
use crate::extensions::SessionPageRequest;

const CATALOG: &str = r#"{"object":"list","data":[
  {"object":"extension","id":"example.hello-page","display_name":"Hello Extension",
   "distribution":"example-hello","version":"1.0.0","extension_api":1,"status":"enabled",
   "permissions":["navigation","storage.user"],
   "pages":[{"id":"example.hello-page.home","title":"Hello Extension","route":"hello","view":"hello"}],
   "primary_navigation":[{"id":"example.hello-page.nav","label":"Hello Extension",
     "page":"example.hello-page.home","icon":"puzzle","order":10,"when":null}],
   "browser":{"declared":true,"has_styles":false,"digest":"abc123",
     "script_url":"/v1/extensions/example.hello-page/assets/abc123/extension.js","style_url":null}},
  {"object":"extension","id":"example.broken","display_name":"Broken","distribution":"x",
   "version":"0.1.0","extension_api":1,"status":"unavailable","permissions":[],"pages":[],
   "primary_navigation":[],"browser":{"declared":true,"has_styles":false}}]}"#;

#[test]
fn the_catalog_keeps_enabled_extensions_with_their_pages_and_bundle() {
    let transport = RouteTransport::local();
    transport.ok("/v1/extensions", CATALOG);
    let core = connected(transport);
    let extensions = block_on(core.extensions()).expect("catalog");
    assert_eq!(extensions.len(), 1);
    let extension = &extensions[0];
    assert_eq!(extension.id, "example.hello-page");
    assert_eq!(extension.permissions, ["navigation", "storage.user"]);
    assert_eq!(extension.pages[0].route, "hello");
    assert_eq!(extension.navigation[0].icon.as_deref(), Some("puzzle"));
    let bundle = extension.bundle.as_ref().expect("bundle");
    assert_eq!(bundle.digest, "abc123");
    assert_eq!(bundle.style_url, None);
}

#[test]
fn a_server_without_extensions_has_none_and_a_bad_catalog_says_why() {
    let core = connected(RouteTransport::local());
    assert_eq!(block_on(core.extensions()), Ok(Vec::new()));

    let transport = RouteTransport::local();
    transport.ok(
        "/v1/extensions",
        r#"{"object":"list","data":[{"id":"nodot","status":"enabled"}]}"#,
    );
    let core = connected(transport);
    match block_on(core.extensions()) {
        Err(SessionError::MalformedResponse { detail }) => {
            assert!(detail.contains("extension 0"), "{detail}");
        }
        other => panic!("expected a malformed catalog, got {other:?}"),
    }
}

#[test]
fn assets_read_as_text_and_a_stale_digest_says_so() {
    let transport = RouteTransport::local();
    let url = "/v1/extensions/example.hello-page/assets/abc123/extension.js";
    transport.respond(
        None,
        url,
        None,
        Reply::Typed {
            status: 200,
            content_type: "text/javascript".to_owned(),
            body: b"console.log('hi')".to_vec(),
        },
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.extension_asset("example.hello-page", url)),
        Ok(ExtensionAsset::Loaded("console.log('hi')".to_owned()))
    );
    let stale = "/v1/extensions/example.hello-page/assets/old/extension.js";
    assert_eq!(
        block_on(core.extension_asset("example.hello-page", stale)),
        Ok(ExtensionAsset::Stale)
    );
}

#[test]
fn an_asset_of_another_extension_or_route_is_never_read() {
    let core = connected(RouteTransport::local());
    for url in [
        "/v1/extensions/example.other/assets/abc/extension.js",
        "/v1/extensions/example.hello-page/assets/abc/other.js",
        "/v1/extensions/example.hello-page/assets/a.b/extension.js",
        "https://example.com/v1/extensions/example.hello-page/assets/abc/extension.js",
        "/v1/sessions",
    ] {
        assert!(
            matches!(
                block_on(core.extension_asset("example.hello-page", url)),
                Err(SessionError::InvalidInput { .. })
            ),
            "{url}"
        );
    }
    assert!(
        core.transport()
            .taken()
            .iter()
            .all(|request| !path_of(request).contains("/assets/")),
        "no asset read was sent"
    );
}

#[test]
fn a_session_page_asks_for_top_level_unarchived_sessions_newest_first() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sessions",
        r#"{"data":[{"id":"conv_a","title":"Fix the build","status":"running","created_at":1,
            "updated_at":2.5,"workspace":"/w","git_branch":"main","project_id":null}],
            "has_more":true,"last_id":"conv_a"}"#,
    );
    let core = connected(transport);
    let request = SessionPageRequest {
        after: Some("conv_0".to_owned()),
        limit: 5,
    };
    let rows = block_on(core.extension_session_rows(&request)).expect("rows");
    assert!(rows.has_more);
    assert_eq!(rows.last_id.as_deref(), Some("conv_a"));
    assert_eq!(rows.rows[0].git_branch.as_deref(), Some("main"));
    let requests = core.transport().taken();
    let sent = requests
        .iter()
        .rev()
        .find(|request| path_of(request) == "/v1/sessions")
        .expect("the list read");
    for (name, value) in [
        ("limit", "5"),
        ("sort_by", "updated_at"),
        ("order", "desc"),
        ("kind", "default"),
        ("visibility", "all"),
        ("include_archived", "false"),
        ("after", "conv_0"),
    ] {
        assert_eq!(query_value(sent, name).as_deref(), Some(value), "{name}");
    }
}

#[test]
fn session_page_failures_carry_the_codes_the_sdk_knows() {
    let cases = [
        (403, "{}", "PermissionDenied"),
        (503, "{}", "Unavailable"),
        (
            400,
            r#"{"error":{"code":"stale_cursor","message":"gone"}}"#,
            "StaleCursor",
        ),
        (400, r#"{"error":{"code":"invalid_input"}}"#, "HostError"),
        (
            200,
            r#"{"data":[{"id":"a","status":"paused","created_at":1,"updated_at":1}],"has_more":false}"#,
            "HostError",
        ),
    ];
    for (status, body, code) in cases {
        let transport = RouteTransport::local();
        transport.respond(None, "/v1/sessions", None, Reply::json(status, body));
        let core = connected(transport);
        let request = SessionPageRequest {
            after: None,
            limit: 25,
        };
        let error = block_on(core.extension_session_rows(&request)).expect_err("a failure");
        assert_eq!(error.code, code, "{status} {body}");
    }
}
