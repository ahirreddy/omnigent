//! `/rewind`: the picker's prompts, the rewind request, and what refuses it.

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::test_support::{
    Reply, RouteTransport, cache_row, connected, lines_after_connect, query_value,
};
use super::*;

const SCRIPT: &str = "sessions/ComposerParity--RewindPromptsAndRewind.jsonl";

#[test]
fn prompts_list_the_users_messages_newest_first_across_pages() {
    let transport = RouteTransport::local();
    transport.load(SCRIPT);
    let core = connected(transport);
    let page = block_on(core.rewind_prompts("conv_a", None)).unwrap();
    let listed: Vec<(&str, &str)> = page
        .prompts
        .iter()
        .map(|prompt| (prompt.item_id.as_str(), prompt.text.as_str()))
        .collect();
    // Assistant messages and hidden context (a loaded skill's body) are not prompts.
    assert_eq!(
        listed,
        [
            ("msg_3", "Add a test for the parser"),
            ("msg_2", ""),
            ("msg_1", "Fix the parser\nand its tests"),
        ]
    );
    assert_eq!(page.prompts[0].created_at, Some(1_763_460_003.0));
    assert_eq!(page.older_cursor, None);
    let requests = core.transport().taken().split_off(2);
    assert_eq!(requests.len(), 2);
    for request in &requests {
        assert_eq!(query_value(request, "type").as_deref(), Some("message"));
        assert_eq!(query_value(request, "order").as_deref(), Some("desc"));
        assert_eq!(query_value(request, "limit").as_deref(), Some("200"));
    }
    assert_eq!(query_value(&requests[0], "after"), None);
    assert_eq!(
        query_value(&requests[1], "after").as_deref(),
        Some("msg_skill")
    );
}

#[test]
fn a_long_session_stops_after_five_pages_with_a_cursor_for_older_prompts() {
    let transport = RouteTransport::local();
    for page in 0..=REWIND_PROMPT_PAGES {
        let body = json!({
            "object": "list",
            "data": [{"id": format!("msg_{page}"), "type": "message", "role": "user",
                      "content": [{"type": "input_text", "text": format!("prompt {page}")}]}],
            "last_id": format!("msg_{page}"),
            "has_more": page < REWIND_PROMPT_PAGES,
        });
        transport.enqueue(
            "GET",
            "/v1/sessions/conv_a/items",
            vec![Reply::json(200, body.to_string())],
        );
    }
    let core = connected(transport);
    let first = block_on(core.rewind_prompts("conv_a", None)).unwrap();
    assert_eq!(first.prompts.len(), REWIND_PROMPT_PAGES);
    assert_eq!(first.older_cursor.as_deref(), Some("msg_4"));
    let older = block_on(core.rewind_prompts("conv_a", first.older_cursor.as_deref())).unwrap();
    assert_eq!(older.prompts[0].item_id, "msg_5");
    assert_eq!(older.older_cursor, None);
    let last = core.transport().taken().pop().unwrap();
    assert_eq!(query_value(&last, "after").as_deref(), Some("msg_4"));
}

#[test]
fn a_repeated_cursor_or_a_malformed_page_fails_instead_of_looping() {
    let transport = RouteTransport::local();
    transport.ok(
        "/v1/sessions/conv_a/items",
        r#"{"data":[],"last_id":"msg_1","has_more":true}"#,
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.rewind_prompts("conv_a", Some("msg_1"))),
        Err(SessionError::InvalidPagination)
    );
    core.transport()
        .ok("/v1/sessions/conv_a/items", r#"{"has_more":false}"#);
    assert!(matches!(
        block_on(core.rewind_prompts("conv_a", None)),
        Err(SessionError::MalformedResponse { .. })
    ));
    assert!(matches!(
        block_on(core.rewind_prompts("../x", None)),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}

#[test]
fn rewind_posts_the_prompt_and_returns_the_new_session() {
    let transport = RouteTransport::local();
    transport.load(SCRIPT);
    let core = connected(transport);
    let rewound = block_on(core.rewind_session("conv_a", "msg_3")).unwrap();
    assert_eq!(
        rewound,
        Rewound {
            session_id: "conv_rewound".into(),
            prompt: "Add a test for the parser".into(),
            attachments: vec![RewindAttachment {
                is_image: true,
                file_id: Some("file_new".into()),
                image_url: None,
                file_data: None,
                filename: "diagram.png".into(),
            }],
            attachments_incomplete: false,
        }
    );
    assert_eq!(
        lines_after_connect(&core),
        ["POST /v1/sessions/conv_a/rewind"]
    );
    assert_eq!(
        core.transport().write_bodies(),
        [json!({"item_id": "msg_3"})]
    );
}

#[test]
fn an_older_answer_without_attachments_and_an_inline_one_decode() {
    let older = Rewound::from_value(&json!({"session_id": "conv_b", "prompt": "Hi"})).unwrap();
    assert!(older.attachments.is_empty() && !older.attachments_incomplete);
    let inline = Rewound::from_value(&json!({
        "session_id": "conv_b",
        "prompt": "",
        "attachments_incomplete": true,
        "attachments": [{"type": "input_file", "file_id": null,
                         "file_data": "data:application/pdf;base64,AAAA", "filename": "a.pdf"}]
    }))
    .unwrap();
    assert!(inline.attachments_incomplete);
    assert_eq!(
        inline.attachments[0].file_data.as_deref(),
        Some("data:application/pdf;base64,AAAA")
    );
    assert!(!inline.attachments[0].is_image && inline.attachments[0].file_id.is_none());
    assert!(
        Rewound::from_value(&json!({"session_id": "c", "attachments": [{"type": "x"}]})).is_err()
    );
}

fn rewound(attachments: Vec<RewindAttachment>) -> Rewound {
    Rewound {
        session_id: "conv_rewound".into(),
        prompt: "Add a test for the parser".into(),
        attachments,
        attachments_incomplete: false,
    }
}

fn file(file_id: Option<&str>, data: Option<&str>, filename: &str) -> RewindAttachment {
    RewindAttachment {
        is_image: false,
        file_id: file_id.map(str::to_owned),
        image_url: None,
        file_data: data.map(str::to_owned),
        filename: filename.into(),
    }
}

#[test]
fn the_prompt_and_its_readable_files_return_to_the_new_composer() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("GET"),
        "/v1/sessions/conv_rewound/resources/files/file_new/content",
        None,
        Reply::Typed {
            status: 200,
            content_type: "image/png".into(),
            body: b"\x89PNG".to_vec(),
        },
    );
    let core = connected(transport);
    let image = RewindAttachment {
        is_image: true,
        ..file(Some("file_new"), None, "diagram.png")
    };
    let restored = block_on(core.restore_rewound_prompt(&rewound(vec![
        image,
        file(None, Some("data:text/plain;base64,aGVsbG8="), "notes.txt"),
        file(Some("file_gone"), None, "gone.pdf"),
        file(None, Some("data:text/plain,hello"), "plain.txt"),
    ])))
    .unwrap();
    assert!(restored.text_restored);
    let names: Vec<&str> = restored
        .unrestored
        .iter()
        .map(|missing| missing.filename.as_str())
        .collect();
    assert_eq!(names, ["gone.pdf", "plain.txt"]);
    assert_eq!(
        core.composer_text("conv_rewound").unwrap(),
        "Add a test for the parser"
    );
    let draft = core.attachment_draft("conv_rewound").unwrap();
    let staged: Vec<(&str, &[u8])> = draft
        .items()
        .iter()
        .map(|item| (item.file().filename(), item.file().data()))
        .collect();
    assert_eq!(
        staged,
        [
            ("diagram.png", b"\x89PNG".as_slice()),
            ("notes.txt", b"hello".as_slice())
        ]
    );
}

#[test]
fn a_draft_already_in_the_new_composer_wins_over_the_prompt() {
    let core = connected(RouteTransport::local());
    core.update_composer("conv_rewound", "my own words")
        .unwrap();
    let restored = block_on(core.restore_rewound_prompt(&rewound(vec![file(
        None,
        Some("data:text/plain;base64,aGVsbG8="),
        "notes.txt",
    )])))
    .unwrap();
    assert_eq!(restored, RestoredPrompt::default());
    assert_eq!(core.composer_text("conv_rewound").unwrap(), "my own words");
    assert!(
        !core
            .attachment_draft("conv_rewound")
            .unwrap()
            .has_attachments()
    );
    assert_eq!(lines_after_connect(&core), Vec::<String>::new());
}

#[test]
fn a_refused_or_unreadable_rewind_says_why() {
    let core = connected(RouteTransport::local());
    cache_row(
        &core,
        r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":1}"#,
    );
    assert_eq!(
        block_on(core.rewind_session("conv_a", "msg_3")),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(lines_after_connect(&core), Vec::<String>::new());

    let transport = RouteTransport::local();
    transport.respond(
        Some("POST"),
        "/v1/sessions/conv_a/rewind",
        None,
        Reply::json(
            400,
            r#"{"error":{"code":"invalid_input","message":"Stop the current turn first."}}"#,
        ),
    );
    let core = connected(transport);
    assert!(matches!(
        block_on(core.rewind_session("conv_a", "msg_3")),
        Err(SessionError::Rejected { status: 400, message }) if message.contains("Stop")
    ));
    core.transport().respond(
        Some("POST"),
        "/v1/sessions/conv_a/rewind",
        None,
        Reply::json(200, r#"{"prompt":"no id"}"#),
    );
    assert!(matches!(
        block_on(core.rewind_session("conv_a", "msg_3")),
        Err(SessionError::DeliveryUncertain { .. })
    ));
    assert!(matches!(
        block_on(core.rewind_session("conv_a", "bad id")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}
