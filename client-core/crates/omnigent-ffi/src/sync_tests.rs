//! `ConversationSync` through its JSON surface, with stale tokens and out-of-order input.

use super::*;

const SESSION: &str = "conv_a";

fn snapshot(status: &str) -> String {
    serde_json::json!({"id": SESSION, "status": status, "created_at": 1}).to_string()
}

fn message_item(id: &str, text: &str) -> Value {
    serde_json::json!({
        "id": id,
        "type": "message",
        "role": "user",
        "created_at": 1,
        "content": [{"type": "input_text", "text": text}],
    })
}

fn items(entries: &[Value]) -> String {
    Value::Array(entries.to_vec()).to_string()
}

fn hydrated() -> Arc<ConversationSync> {
    let sync = ConversationSync::new(SESSION.into());
    let request = sync.open_stream();
    sync.finish_hydration(
        request,
        snapshot("idle"),
        items(&[message_item("m1", "hi")]),
    )
    .unwrap();
    sync
}

fn row(status: &str) -> String {
    serde_json::json!([{"id": SESSION, "status": status, "created_at": 1, "updated_at": 5}])
        .to_string()
}

fn decode_message(error: &CoreError) -> String {
    let CoreError::Decode { message } = error else {
        panic!("{error:?}");
    };
    message.clone()
}

#[test]
fn tokens_and_syncs_describe_themselves() {
    let sync = ConversationSync::new(SESSION.into());
    assert_eq!(sync.session_id(), SESSION);
    assert_eq!(
        format!("{sync:?}"),
        "ConversationSync { session_id: \"conv_a\", .. }"
    );
    let request = sync.open_stream();
    assert_eq!(request.session_id(), SESSION);
    assert_eq!(
        format!("{request:?}"),
        "HydrationRequest { session_id: \"conv_a\", .. }"
    );
    assert_eq!(
        format!("{:?}", sync.begin_configuration_read(SESSION.into())),
        "ConfigurationRead { session_id: \"conv_a\", .. }"
    );
    assert_eq!(format!("{:?}", sync.begin_list_read()), "ListRead");
}

#[test]
fn nothing_is_published_before_the_first_history_read() {
    let sync = ConversationSync::new(SESSION.into());
    assert_eq!(sync.rows(), []);
    assert_eq!(sync.header(), None);
    assert_eq!(sync.decisions(), []);
    assert_eq!(sync.sections(), []);
    assert!(!sync.is_hydrating());
    // No stream yet, so there is nothing to read for.
    assert!(sync.request_hydration().is_none() || sync.is_hydrating());
}

#[test]
fn a_read_publishes_rows_and_events_during_it_are_applied_after() {
    let sync = ConversationSync::new(SESSION.into());
    let request = sync.open_stream();
    assert!(sync.is_hydrating());
    // A second ask is queued, not started.
    assert!(sync.request_hydration().is_none());
    let delta = serde_json::json!({
        "type": "response.output_text.delta",
        "item_id": "reply",
        "delta": "streamed",
        "output_index": 0,
        "content_index": 0,
    });
    sync.handle_event(delta.to_string()).unwrap();

    let update = sync
        .finish_hydration(
            request,
            snapshot("running"),
            items(&[message_item("m1", "hi")]),
        )
        .unwrap();
    assert!(update.revision > 0);
    let ids: Vec<String> = sync.rows().into_iter().map(|row| row.id).collect();
    assert!(ids.contains(&"m1".to_owned()), "{ids:?}");
    assert!(sync.header().is_some());
    // The ask made during the read comes back as the next read.
    assert!(update.hydrate.is_some());
}

#[test]
fn every_undecodable_input_says_what_was_wrong_and_changes_nothing() {
    let sync = hydrated();
    let rows = sync.rows();
    let revision = sync.handle_list_rows("[]".into()).unwrap().revision;

    assert!(
        decode_message(&sync.handle_event("not json".into()).unwrap_err()).starts_with("event:")
    );
    assert!(matches!(
        sync.handle_event(
            serde_json::json!({"type": "response.output_text.delta", "delta": {}}).to_string()
        ),
        Err(CoreError::Sync { .. })
    ));

    let request = sync.open_stream();
    assert!(
        decode_message(
            &sync
                .finish_hydration(Arc::clone(&request), "{".into(), "[]".into())
                .unwrap_err()
        )
        .starts_with("session:")
    );
    assert!(
        decode_message(
            &sync
                .finish_hydration(Arc::clone(&request), snapshot("idle"), "{".into())
                .unwrap_err()
        )
        .starts_with("items:")
    );
    assert_eq!(
        decode_message(
            &sync
                .finish_hydration(Arc::clone(&request), snapshot("idle"), "{}".into())
                .unwrap_err()
        ),
        "items: not a JSON array"
    );
    assert!(
        decode_message(
            &sync
                .finish_hydration(Arc::clone(&request), snapshot("idle"), "[7]".into())
                .unwrap_err()
        )
        .starts_with("item:")
    );
    assert!(sync.hydration_failed(request));

    assert!(
        decode_message(&sync.handle_list_rows("{".into()).unwrap_err())
            .starts_with("session rows:")
    );
    assert_eq!(
        decode_message(&sync.handle_list_rows("{}".into()).unwrap_err()),
        "session rows: not a JSON array"
    );
    assert!(
        decode_message(&sync.handle_list_rows("[7]".into()).unwrap_err())
            .starts_with("session row:")
    );
    assert!(sync.handle_list_rows(row("from-the-future")).is_err());
    let read = sync.begin_list_read();
    assert!(sync.finish_list_read(read, row("from-the-future")).is_err());
    let read = sync.begin_list_read();
    assert!(sync.finish_list_read(read, "{".into()).is_err());

    let read = sync.begin_configuration_read(SESSION.into());
    assert!(
        decode_message(
            &sync
                .finish_configuration_read(read, "{".into())
                .unwrap_err()
        )
        .starts_with("session:")
    );
    assert_eq!(sync.rows(), rows);
    assert!(sync.handle_list_rows("[]".into()).unwrap().revision >= revision);
}

#[test]
fn a_read_from_a_closed_stream_is_stale() {
    let sync = ConversationSync::new(SESSION.into());
    let stale = sync.open_stream();
    sync.close_stream();
    assert!(!sync.is_hydrating());
    assert!(!sync.hydration_failed(Arc::clone(&stale)), "not current");
    let update = sync
        .finish_hydration(stale, snapshot("idle"), items(&[message_item("old", "x")]))
        .unwrap();
    assert_eq!(update.change, None);
    assert_eq!(sync.rows(), []);

    let current = sync.open_stream();
    assert!(sync.hydration_failed(Arc::clone(&current)));
    assert!(!sync.hydration_failed(current), "a failure counts once");
}

#[test]
fn configuration_reads_lose_to_a_restart_and_to_another_session() {
    let sync = hydrated();
    let read = sync.begin_configuration_read(SESSION.into());
    let update = sync.finish_configuration_read(read, snapshot("idle"));
    assert!(update.is_ok(), "{update:?}");

    let read = sync.begin_configuration_read(SESSION.into());
    sync.stop();
    assert!(matches!(
        sync.finish_configuration_read(read, snapshot("idle")),
        Err(CoreError::ConfigurationRead { .. })
    ));

    let sync = hydrated();
    let read = sync.begin_configuration_read("another".into());
    assert!(matches!(
        sync.finish_configuration_read(read, snapshot("idle")),
        Err(CoreError::ConfigurationRead { .. })
    ));
}

#[test]
fn list_rows_update_the_header_and_a_removal_stops_the_watch() {
    let sync = hydrated();
    let read = sync.begin_list_read();
    let finished = sync.finish_list_read(read, row("running")).unwrap();
    assert!(finished.revision > 0);
    let framed = sync.handle_list_rows(row("idle")).unwrap();
    assert!(framed.revision >= finished.revision);
    assert!(!sync.handle_removed(vec!["another".into()]));
    assert!(sync.handle_removed(vec![SESSION.into()]));
    let after = sync
        .handle_event(
            serde_json::json!({"type": "response.output_text.delta", "item_id": "x", "delta": "late"})
                .to_string(),
        )
        .unwrap();
    assert_eq!(after.change, None, "later input for this watch is dropped");
}

#[test]
fn stopping_drops_every_later_input() {
    let sync = hydrated();
    let request = sync.open_stream();
    sync.stop();
    sync.stop();
    let update = sync
        .finish_hydration(
            request,
            snapshot("idle"),
            items(&[message_item("late", "x")]),
        )
        .unwrap();
    assert_eq!(update.change, None);
    assert!(sync.request_hydration().is_none());
    let ids: Vec<String> = sync.rows().into_iter().map(|row| row.id).collect();
    assert!(!ids.contains(&"late".to_owned()), "{ids:?}");
}

#[test]
fn a_failed_turn_surfaces_as_an_effect_with_its_headers_and_decisions() {
    let sync = hydrated();
    let update = sync
        .handle_event(
            serde_json::json!({
                "type": "response.failed",
                "response": {
                    "id": "r1",
                    "status": "failed",
                    "error": {"code": "x", "message": "the model refused"},
                },
            })
            .to_string(),
        )
        .unwrap();
    assert!(
        update
            .effects
            .error
            .as_deref()
            .is_some_and(|message| message.contains("refused")),
        "{:?}",
        update.effects
    );
    assert_eq!(sync.decisions(), []);
    let sections = sync.sections();
    assert_eq!(sections.len(), sync.sections().len());
}
