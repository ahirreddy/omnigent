//! Messages sent from outside the composer with files of their own.

use futures::executor::block_on;
use serde_json::json;

use super::SessionError;
use super::test_support::{Reply, RouteTransport, body_json, cache_row, connected, live};
use crate::attachments::UploadFile;

const UPLOAD: &str = "/v1/sessions/conv_a/resources/files";
const EVENTS: &str = "/v1/sessions/conv_a/events";

fn transport() -> RouteTransport {
    let transport = RouteTransport::local();
    transport.ok(EVENTS, r#"{"queued":true}"#);
    transport.respond(
        Some("POST"),
        UPLOAD,
        None,
        Reply::json(201, r#"{"id":"file_1","session_id":"conv_a"}"#),
    );
    transport
}

fn screenshot() -> UploadFile {
    UploadFile::new(
        "design-element.png",
        Some("image/png"),
        b"\x89PNG-bytes".to_vec(),
    )
    .unwrap()
}

fn lines(core: &super::ClientCore<RouteTransport>) -> Vec<String> {
    core.transport().lines().split_off(2)
}

#[test]
fn files_upload_then_the_message_posts_leaving_the_composer_alone() {
    let core = live(transport());
    core.update_composer("conv_a", "still typing").unwrap();
    let staged = core
        .add_attachment(
            "conv_a",
            UploadFile::new("mine.txt", None, b"x".to_vec()).unwrap(),
        )
        .unwrap();
    let sent =
        block_on(core.send_external_message("conv_a", "Make it red", &[screenshot()], "boundary"))
            .unwrap();
    assert!(sent.queued);
    assert_eq!(
        lines(&core),
        [format!("POST {UPLOAD}"), format!("POST {EVENTS}")]
    );
    let body = body_json(core.transport().writes().last().unwrap());
    assert_eq!(
        body["data"]["content"],
        json!([
            {"type": "input_image", "file_id": "file_1", "filename": "design-element.png"},
            {"type": "input_text", "text": "Make it red"},
        ])
    );
    // The composer's text, staged file and send state are untouched.
    assert_eq!(core.composer_text("conv_a").unwrap(), "still typing");
    let draft = core.attachment_draft("conv_a").unwrap();
    assert_eq!(draft.items().len(), 1);
    assert_eq!(draft.items()[0].id(), staged);
    assert!(!core.is_send_blocked("conv_a").unwrap());
}

#[test]
fn needs_no_open_stream_but_needs_something_to_send() {
    let core = connected(transport());
    block_on(core.send_external_message("conv_a", "Words only", &[], "boundary")).unwrap();
    assert_eq!(lines(&core), [format!("POST {EVENTS}")]);
    assert_eq!(
        block_on(core.send_external_message("conv_a", "  ", &[], "boundary")),
        Err(SessionError::EmptyMessage)
    );
    assert!(matches!(
        block_on(core.send_external_message("../x", "Hi", &[], "boundary")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}

#[test]
fn a_refused_upload_posts_nothing() {
    let transport = transport();
    transport.respond(Some("POST"), UPLOAD, None, Reply::json(403, "{}"));
    let core = live(transport);
    assert_eq!(
        block_on(core.send_external_message("conv_a", "Hi", &[screenshot()], "boundary")),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(lines(&core), [format!("POST {UPLOAD}")]);
}

#[test]
fn an_archived_session_is_refused_before_any_upload() {
    let core = live(transport());
    cache_row(
        &core,
        r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"archived":true}"#,
    );
    assert_eq!(
        block_on(core.send_external_message("conv_a", "Hi", &[screenshot()], "boundary")),
        Err(SessionError::Archived)
    );
    assert_eq!(lines(&core), Vec::<String>::new());
}

#[test]
fn an_offline_host_refuses_the_message_and_the_composer_stays_free() {
    let transport = transport();
    transport.respond(
        Some("POST"),
        EVENTS,
        None,
        Reply::json(
            503,
            r#"{"error":{"code":"host_offline","message":"asleep"}}"#,
        ),
    );
    let core = live(transport);
    assert!(matches!(
        block_on(core.send_external_message("conv_a", "Hi", &[screenshot()], "boundary")),
        Err(SessionError::HostOffline { .. })
    ));
    assert!(!core.is_send_blocked("conv_a").unwrap());
}
