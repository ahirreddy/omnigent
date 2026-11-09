//! Reply drafts and the files held for a queued message, over the fake host.

use omnigent_core::reply_draft as core;
use serde_json::json as value;

use crate::queue::{
    ReplyDraft, ReplyQuote, reply_draft_message, reply_draft_quoting, reply_draft_removing,
};
use crate::test_support::{Harness, connected, json};

fn quote(before: &str, text: &str) -> ReplyQuote {
    ReplyQuote {
        before: before.to_owned(),
        text: text.to_owned(),
    }
}

#[test]
fn a_draft_keeps_its_quotes_and_text_both_ways() {
    let draft = ReplyDraft {
        quotes: vec![quote("Look:", "x")],
        text: "after".into(),
    };
    let on_core = core::ReplyDraft::from(draft.clone());
    assert_eq!(on_core.quotes[0].before, "Look:");
    assert_eq!(on_core.quotes[0].text, "x");
    assert_eq!(on_core.text, "after");
    assert_eq!(ReplyDraft::from(on_core), draft);
}

#[test]
fn quoting_removing_and_the_message_follow_the_draft() {
    let draft = reply_draft_quoting(
        ReplyDraft {
            quotes: vec![],
            text: "Look:".into(),
        },
        "first\nsecond".into(),
    );
    assert_eq!(draft.quotes, [quote("Look:", "first\nsecond")]);
    assert_eq!(draft.text, "");
    let replied = ReplyDraft {
        text: "Why?".into(),
        ..draft
    };
    assert_eq!(
        reply_draft_message(replied.clone()),
        "Look:\n\n> first\n> second\n\nWhy?"
    );
    let removed = reply_draft_removing(replied.clone(), 0);
    assert_eq!(removed.quotes, []);
    assert_eq!(removed.text, "Look:\n\nWhy?");
    assert_eq!(reply_draft_removing(replied.clone(), u32::MAX), replied);
}

fn with_uploads() -> Harness {
    let harness = connected();
    harness.writable_session("conv_a");
    harness.http.route_method(
        "POST",
        "/v1/sessions/conv_a/resources/files",
        json(201, r#"{"id":"file_1","session_id":"conv_a"}"#),
    );
    harness
}

fn stage_and_upload(harness: &mut Harness, name: &str) -> u64 {
    let filename = name.to_owned();
    let item = harness
        .core
        .add_attachment(
            "conv_a".into(),
            filename,
            Some("text/plain".into()),
            b"notes".to_vec(),
        )
        .unwrap();
    harness
        .call(move |core| async move { core.upload_attachment("conv_a".into(), item).await })
        .unwrap();
    item
}

#[test]
fn held_files_go_with_the_queued_message_and_leave_the_composer() {
    let mut harness = with_uploads();
    assert_eq!(
        harness.core.hold_attachments("conv_a".into()).unwrap(),
        None
    );

    let item = stage_and_upload(&mut harness, "plan.txt");
    let held = harness
        .core
        .hold_attachments("conv_a".into())
        .unwrap()
        .unwrap();
    assert_eq!(held.items.len(), 1);
    assert_eq!(held.items[0].id, item);
    assert_eq!(held.items[0].filename, "plan.txt");
    assert_eq!(held.items[0].media_type, "text/plain");
    assert_eq!(held.items[0].byte_count, 5);

    let hold_id = held.id;
    let sent = harness
        .call(move |core| async move {
            core.send_queued_message(
                "conv_a".into(),
                "then this".into(),
                Some(hold_id),
                None,
                vec!["src/lib.rs".into()],
            )
            .await
        })
        .unwrap();
    assert!(sent.queued);
    assert_eq!(sent.item_id.as_deref(), Some("i1"));
    let (line, body) = harness.last_request();
    assert_eq!(line, "POST /v1/sessions/conv_a/events");
    assert_eq!(
        body["data"]["content"],
        value!([
            {"type": "input_file", "file_id": "file_1", "filename": "plan.txt"},
            {"type": "input_text", "text": "[Attached: src/lib.rs]\n\nthen this"},
        ])
    );
    // The send consumed the hold.
    assert!(
        harness
            .core
            .discard_held_attachments("conv_a".into(), hold_id)
            .is_err()
    );
}

#[test]
fn a_hold_can_go_back_to_the_composer_or_be_discarded() {
    let mut harness = with_uploads();
    stage_and_upload(&mut harness, "plan.txt");
    let hold = harness
        .core
        .hold_attachments("conv_a".into())
        .unwrap()
        .unwrap()
        .id;
    harness
        .core
        .restore_held_attachments("conv_a".into(), hold)
        .unwrap();
    assert!(
        harness
            .core
            .restore_held_attachments("conv_a".into(), hold)
            .is_err()
    );
    assert_eq!(
        harness
            .core
            .attachment_draft("conv_a".into())
            .unwrap()
            .items
            .len(),
        1
    );
    let second = harness
        .core
        .hold_attachments("conv_a".into())
        .unwrap()
        .unwrap()
        .id;
    harness
        .core
        .discard_held_attachments("conv_a".into(), second)
        .unwrap();
    assert_eq!(
        harness.core.hold_attachments("conv_a".into()).unwrap(),
        None
    );
}

#[test]
fn a_file_not_yet_uploaded_cannot_be_held_and_an_empty_message_is_refused() {
    let mut harness = with_uploads();
    harness
        .core
        .add_attachment("conv_a".into(), "plan.txt".into(), None, b"x".to_vec())
        .unwrap();
    assert!(harness.core.hold_attachments("conv_a".into()).is_err());
    let empty = harness.call(|core| async move {
        core.send_queued_message("conv_a".into(), " ".into(), None, None, vec![])
            .await
    });
    assert!(empty.is_err());
}
