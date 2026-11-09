//! Queued messages: the composer's files held for them, and their sends.

use futures::executor::block_on;
use serde_json::json;

use super::test_support::{Reply, RouteTransport, body_json, live};
use super::{SessionError, lock};
use crate::attachments::{DraftError, DraftKey, UploadFile};
use crate::ledger::SubmissionOutcome;

const UPLOAD: &str = "/v1/sessions/conv_a/resources/files";

fn transport() -> RouteTransport {
    let transport = RouteTransport::local();
    transport.writable_session("[]");
    transport.ok("/v1/sessions/conv_a/events", r#"{"queued":true}"#);
    transport.respond(
        Some("POST"),
        UPLOAD,
        None,
        Reply::json(201, r#"{"id":"file_1","session_id":"conv_a"}"#),
    );
    transport
}

fn file(name: &str) -> UploadFile {
    UploadFile::new(name, Some("text/plain"), b"notes".to_vec()).unwrap()
}

#[test]
fn a_queued_message_sends_its_held_files_and_leaves_the_draft_alone() {
    let core = live(transport());
    let item = core.add_attachment("conv_a", file("plan.txt")).unwrap();
    block_on(core.upload_attachment("conv_a", item, "boundary")).unwrap();
    let (hold, held_items) = core.hold_attachments("conv_a").unwrap().unwrap();
    assert_eq!(held_items.len(), 1);
    assert!(!core.attachment_draft("conv_a").unwrap().has_attachments());
    // A file staged after queueing stays in the composer.
    core.add_attachment("conv_a", file("later.txt")).unwrap();
    core.update_composer("conv_a", "still typing").unwrap();
    let paths = ["src/lib.rs".to_owned()];
    let sent = block_on(core.send_queued_message("conv_a", "then this", Some(hold), None, &paths))
        .unwrap();
    assert_eq!(sent.draft, "still typing");
    let body = body_json(core.transport().writes().last().unwrap());
    assert_eq!(
        body["data"]["content"],
        json!([
            {"type": "input_file", "file_id": "file_1", "filename": "plan.txt"},
            {"type": "input_text", "text": "[Attached: src/lib.rs]\n\nthen this"},
        ])
    );
    assert_eq!(core.attachment_draft("conv_a").unwrap().items().len(), 1);
    assert_eq!(
        core.discard_held_attachments("conv_a", hold),
        Err(SessionError::Draft(DraftError::UnknownItem))
    );
}

#[test]
fn files_alone_are_a_queued_message_and_can_go_back_to_the_composer() {
    let core = live(transport());
    assert_eq!(core.hold_attachments("conv_a"), Ok(None));
    let item = core.add_attachment("conv_a", file("plan.txt")).unwrap();
    assert_eq!(
        core.hold_attachments("conv_a"),
        Err(SessionError::Draft(DraftError::NotReady))
    );
    block_on(core.upload_attachment("conv_a", item, "boundary")).unwrap();
    let (hold, _) = core.hold_attachments("conv_a").unwrap().unwrap();
    core.restore_held_attachments("conv_a", hold).unwrap();
    assert_eq!(core.attachment_draft("conv_a").unwrap().items().len(), 1);
    let (hold, _) = core.hold_attachments("conv_a").unwrap().unwrap();
    block_on(core.send_queued_message("conv_a", "", Some(hold), None, &[])).unwrap();
    let body = body_json(core.transport().writes().last().unwrap());
    assert_eq!(body["data"]["content"].as_array().unwrap().len(), 1);
    assert!(matches!(
        block_on(core.send_queued_message("conv_a", " ", None, None, &[])),
        Err(SessionError::EmptyMessage)
    ));
}

/// No public path has a files send in flight without its ledger entry, so this seeds one: a
/// capture that fails after the ledger began must not leave the session unable to send.
#[test]
fn a_held_send_that_cannot_capture_its_files_leaves_nothing_in_flight() {
    let core = live(transport());
    let item = core.add_attachment("conv_a", file("plan.txt")).unwrap();
    block_on(core.upload_attachment("conv_a", item, "boundary")).unwrap();
    let (hold, _) = core.hold_attachments("conv_a").unwrap().unwrap();
    let writes_before = core.transport().writes().len();
    let stuck = {
        let mut state = lock(&core.state);
        let key = DraftKey::new(state.scope().unwrap(), "conv_a");
        state.drafts.begin_submission(&key).unwrap()
    };
    assert_eq!(
        block_on(core.send_queued_message("conv_a", "then this", Some(hold), None, &[])),
        Err(SessionError::Draft(DraftError::NotReady))
    );
    assert_eq!(core.transport().writes().len(), writes_before);
    lock(&core.state)
        .drafts
        .finish_submission(&stuck, SubmissionOutcome::Rejected)
        .unwrap();
    block_on(core.send_queued_message("conv_a", "then this", Some(hold), None, &[])).unwrap();
    assert_eq!(core.transport().writes().len(), writes_before + 1);
}
