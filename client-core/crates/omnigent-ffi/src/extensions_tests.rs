//! The extension bridge's exported functions keep the core's checks and shapes.

use super::*;

fn identity() -> ExtensionIdentity {
    ExtensionIdentity {
        extension_id: "example.hello-page".to_owned(),
        page_id: "example.hello-page.home".to_owned(),
        view: "hello".to_owned(),
        nonce: "0a1b2c".to_owned(),
        api_version: 1,
    }
}

#[test]
fn requests_round_trip_their_parameters_as_json() {
    let text = r#"{"source":"omnigent-extension","type":"request","extensionId":"example.hello-page",
        "pageId":"example.hello-page.home","view":"hello","nonce":"0a1b2c","apiVersion":1,
        "requestId":"r1","method":"storage.user.set","params":{"key":"k","value":[1]}}"#;
    let Some(ExtensionInbound::Request {
        request_id,
        method,
        params_json,
    }) = extension_inbound(text.to_owned(), identity())
    else {
        panic!("expected a request");
    };
    assert_eq!(
        (request_id.as_str(), method.as_str()),
        ("r1", "storage.user.set")
    );
    let write = extension_storage_write(params_json).unwrap();
    assert_eq!(
        (write.key.as_str(), write.json.as_str(), write.size),
        ("k", "[1]", 3)
    );
}

#[test]
fn faults_carry_the_sdk_codes_and_bad_results_become_host_errors() {
    assert_eq!(
        extension_storage_key(Some("not json".to_owned())),
        Err(ExtensionHostFault::Failed {
            code: "InvalidParams".to_owned(),
            message: "Expected an object".to_owned(),
        })
    );
    let answer = extension_response_message(identity(), "r1".into(), "m".into(), "{".into());
    assert!(answer.contains(r#""code":"HostError""#), "{answer}");
    let theme = extension_response_message(
        identity(),
        "r2".into(),
        "theme.getCurrent".into(),
        extension_theme_result(false),
    );
    assert!(theme.contains(r#""result":{"theme":"light"}"#), "{theme}");
}

#[test]
fn navigation_entries_come_back_sorted_with_their_pages() {
    let page = ExtensionPage {
        id: "example.a.home".to_owned(),
        title: "Home".to_owned(),
        route: "home".to_owned(),
        view: "home".to_owned(),
    };
    let extension = Extension {
        id: "example.a".to_owned(),
        display_name: "A".to_owned(),
        version: "1".to_owned(),
        permissions: vec!["navigation".to_owned()],
        pages: vec![page.clone()],
        navigation: vec![ExtensionNavigation {
            id: "example.a.nav".to_owned(),
            label: "A".to_owned(),
            page: page.id.clone(),
            icon: Some("dashboard".to_owned()),
            order: 1,
        }],
        bundle: None,
    };
    let entries = extension_navigation_entries(vec![extension]);
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].page, page);
    assert_eq!(
        extension_page_route(Some(r#"{"pageId":"example.a.home"}"#.into()), vec![page]),
        Ok("home".to_owned())
    );
}
