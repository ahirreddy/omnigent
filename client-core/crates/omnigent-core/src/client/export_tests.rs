//! Transcript export: metadata first, then every page of items in order.

use futures::executor::block_on;
use serde_json::{Value, json};

use super::SessionError;
use super::test_support::{Reply, RouteTransport, connected, query_value};

#[test]
fn export_writes_meta_then_every_page_in_order() {
    let transport = RouteTransport::local();
    transport.ok("/v1/sessions/conv_a", r#"{"id":"conv_a","title":"T"}"#);
    transport.enqueue(
        "GET",
        "/v1/sessions/conv_a/items",
        vec![
            Reply::json(
                200,
                r#"{"data":[{"id":"i1","type":"message"}],"has_more":true,"last_id":"i1"}"#,
            ),
            Reply::json(
                200,
                r#"{"data":[{"id":"i2","type":"message"}],"has_more":false}"#,
            ),
        ],
    );
    let core = connected(transport);
    let text = block_on(core.export_transcript("conv_a")).unwrap();
    let lines: Vec<Value> = text
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(
        lines,
        [
            json!({"record_type": "session_meta", "id": "conv_a", "title": "T"}),
            json!({"record_type": "item", "id": "i1", "type": "message"}),
            json!({"record_type": "item", "id": "i2", "type": "message"}),
        ]
    );
    assert!(text.ends_with('\n'));
    let pages: Vec<_> = core
        .transport()
        .taken()
        .into_iter()
        .filter(|request| request.url.contains("/items"))
        .collect();
    assert_eq!(query_value(&pages[0], "order").as_deref(), Some("asc"));
    assert_eq!(query_value(&pages[0], "after"), None);
    assert_eq!(query_value(&pages[1], "after").as_deref(), Some("i1"));
}

#[test]
fn export_refuses_a_repeating_cursor_and_a_malformed_page() {
    let transport = RouteTransport::local();
    transport.ok("/v1/sessions/conv_a", r#"{"id":"conv_a"}"#);
    let repeating = r#"{"data":[],"has_more":true,"last_id":"i1"}"#;
    transport.enqueue(
        "GET",
        "/v1/sessions/conv_a/items",
        vec![
            Reply::json(200, repeating),
            Reply::json(200, repeating),
            Reply::json(200, r#"{"items":[]}"#),
        ],
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.export_transcript("conv_a")),
        Err(SessionError::InvalidPagination)
    );
    assert!(matches!(
        block_on(core.export_transcript("conv_a")),
        Err(SessionError::MalformedResponse { .. })
    ));
}

#[test]
fn export_stops_at_a_cursor_that_comes_back() {
    let page = |last: &str| {
        Reply::json(
            200,
            format!(
                r#"{{"data":[{{"id":"{last}","type":"message"}}],"has_more":true,"last_id":"{last}"}}"#
            ),
        )
    };
    let transport = RouteTransport::local();
    transport.ok("/v1/sessions/conv_a", r#"{"id":"conv_a"}"#);
    transport.enqueue(
        "GET",
        "/v1/sessions/conv_a/items",
        vec![page("i1"), page("i2"), page("i1")],
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.export_transcript("conv_a")),
        Err(SessionError::InvalidPagination)
    );
}
