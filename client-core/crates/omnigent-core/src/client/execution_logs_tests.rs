//! Execution logs read a session's items oldest first, a page at a time.

use futures::executor::block_on;

use crate::client::SessionError;
use crate::client::test_support::{RouteTransport, connected, path_of, query_value};

#[test]
fn items_read_oldest_first_and_say_where_the_next_page_starts() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sessions/conv_a/items",
        r#"{"data":[{"id":"item_1","type":"message","role":"user"},{"type":"reasoning"}],
            "has_more":true,"last_id":"item_2"}"#,
    );
    let core = connected(transport);
    let page = block_on(core.raw_session_items("conv_a", Some("item_0"))).expect("page");
    assert_eq!(page.next.as_deref(), Some("item_2"));
    assert_eq!(page.items[0].id.as_deref(), Some("item_1"));
    assert_eq!(page.items[1].id, None);
    assert_eq!(page.items[1].compact, r#"{"type":"reasoning"}"#);
    assert!(page.items[0].pretty.contains("\n  \"role\": \"user\""));
    let requests = core.transport().taken();
    let request = requests
        .iter()
        .find(|request| path_of(request) == "/v1/sessions/conv_a/items")
        .expect("the items read");
    assert_eq!(query_value(request, "order").as_deref(), Some("asc"));
    assert_eq!(query_value(request, "after").as_deref(), Some("item_0"));
    assert!(matches!(
        block_on(core.raw_session_items("a/b", None)),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}

#[test]
fn the_last_page_has_no_next() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sessions/conv_a/items",
        r#"{"data":[],"has_more":false,"last_id":"item_9"}"#,
    );
    let core = connected(transport);
    let page = block_on(core.raw_session_items("conv_a", None)).expect("page");
    assert_eq!(page.items, Vec::new());
    assert_eq!(page.next, None);
}
