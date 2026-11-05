//! Attachment previews: only this session's files are fetched, and the response's media type and
//! status decide what comes back.

use futures::executor::block_on;

use super::SessionError;
use super::test_support::{LOCAL, Reply, RouteTransport, connected};
use crate::attachments::PreviewError;

const CONTENT: &str = "/v1/sessions/conv_a/resources/files/file_1/content";

fn png(status: u16) -> Reply {
    Reply::Typed {
        status,
        content_type: "image/png".to_owned(),
        body: vec![0x89, b'P', b'N', b'G'],
    }
}

#[test]
fn a_file_id_path_or_url_of_this_session_reads_its_content() {
    let transport = RouteTransport::local();
    transport.enqueue("GET", CONTENT, vec![png(200), png(200), png(200)]);
    let core = connected(transport);
    for reference in ["file_1", CONTENT, &format!("{LOCAL}{CONTENT}")] {
        let preview = block_on(core.attachment_preview("conv_a", reference)).unwrap();
        assert_eq!(preview.file_extension, "png");
        assert_eq!(preview.data, [0x89, b'P', b'N', b'G']);
    }
    let sent = core.transport().taken();
    let content: Vec<_> = sent
        .iter()
        .filter(|request| request.url.ends_with(CONTENT))
        .collect();
    assert_eq!(content.len(), 3);
    assert!(
        content[0]
            .headers
            .iter()
            .any(|header| header.name == "Accept" && header.value == "*/*")
    );
}

#[test]
fn other_references_are_never_fetched() {
    let core = connected(RouteTransport::local());
    for reference in [
        "https://example.com/cat.png",
        "/v1/sessions/conv_b/resources/files/file_1/content",
        "../file_1",
    ] {
        assert_eq!(
            block_on(core.attachment_preview("conv_a", reference)),
            Err(SessionError::Preview(PreviewError::NotASessionFile))
        );
    }
    assert_eq!(
        block_on(core.attachment_preview("../x", "file_1")),
        Err(SessionError::InvalidIdentifier {
            value: "../x".to_owned()
        })
    );
    assert!(
        core.transport()
            .taken()
            .iter()
            .all(|request| !request.url.contains("/resources/"))
    );
}

#[test]
fn active_content_and_failures_are_refused() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "GET",
        CONTENT,
        vec![
            Reply::Typed {
                status: 200,
                content_type: "image/svg+xml".to_owned(),
                body: b"<svg/>".to_vec(),
            },
            png(403),
            png(404),
        ],
    );
    let core = connected(transport);
    assert!(matches!(
        block_on(core.attachment_preview("conv_a", "file_1")),
        Err(SessionError::Preview(PreviewError::UnsupportedMedia { .. }))
    ));
    assert_eq!(
        block_on(core.attachment_preview("conv_a", "file_1")),
        Err(SessionError::Preview(PreviewError::Forbidden))
    );
    assert_eq!(
        block_on(core.attachment_preview("conv_a", "file_1")),
        Err(SessionError::Preview(PreviewError::HttpStatus {
            status: 404
        }))
    );
}

#[test]
fn unauthorized_ends_the_connection() {
    let transport = RouteTransport::local();
    transport.enqueue("GET", CONTENT, vec![png(401)]);
    let core = connected(transport);
    assert_eq!(
        block_on(core.attachment_preview("conv_a", "file_1")),
        Err(SessionError::Preview(PreviewError::Unauthorized))
    );
    assert!(!core.is_connected());
}
