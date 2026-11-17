use omnigent_protocol::{ConversationItem, FromWire, SessionListItem, SessionSnapshot};
use serde_json::Value;

use super::*;
use crate::reconcile::{ConversationSync, HistoryItems, HistoryPaging, history_rows};
use crate::reducer::TurnStatus;
use crate::sessions::saved_summaries;

fn fixture(path: &str) -> Value {
    let full = format!("{}/../../fixtures/{path}", env!("CARGO_MANIFEST_DIR"));
    let text = std::fs::read_to_string(&full).unwrap_or_else(|error| panic!("{full}: {error}"));
    serde_json::from_str(&text).unwrap()
}

fn session(json: &str) -> SessionSnapshot {
    SessionSnapshot::from_json(json.as_bytes()).unwrap()
}

fn idle_session() -> SessionSnapshot {
    session(
        r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"title":"Plans"}"#,
    )
}

fn message(id: &str, text: &str) -> ConversationItem {
    ConversationItem::from_json(
        format!(r#"{{"id":"{id}","type":"message","role":"assistant","content":"{text}"}}"#)
            .as_bytes(),
    )
    .unwrap()
}

fn messages(ids: &[&str]) -> Vec<ConversationItem> {
    ids.iter().map(|id| message(id, id)).collect()
}

fn saved(older: &[&str], newest: &[&str], cursor: Option<&str>) -> SavedConversation {
    SavedConversation {
        saved_at_ms: 7,
        session: idle_session(),
        older: messages(older),
        newest: messages(newest),
        older_cursor: cursor.map(str::to_owned),
    }
}

fn row_ids(sync: &ConversationSync) -> Vec<String> {
    sync.published()
        .map(|snapshot| snapshot.rows.iter().map(|row| row.id.clone()).collect())
        .unwrap_or_default()
}

/// Every item the item fixtures hold that this client decodes: arrays, and pages' `data`.
fn fixture_items() -> Vec<(String, ConversationItem)> {
    let directory = format!("{}/../../fixtures/items", env!("CARGO_MANIFEST_DIR"));
    let mut items = Vec::new();
    for entry in std::fs::read_dir(&directory).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        // A file of several JSON lines holds events, not a page of items.
        let Ok(value) = serde_json::from_str::<Value>(&std::fs::read_to_string(&path).unwrap())
        else {
            continue;
        };
        let values = match value {
            Value::Array(values) => values,
            Value::Object(mut fields) => match fields.remove("data") {
                Some(Value::Array(values)) => values,
                _ => continue,
            },
            _ => continue,
        };
        for value in values {
            if let Ok(item) = ConversationItem::from_value(value) {
                items.push((name.clone(), item));
            }
        }
    }
    items
}

#[test]
fn every_fixture_item_and_the_session_come_back_from_a_saved_file() {
    let items = fixture_items();
    assert!(items.len() > 50, "{} items", items.len());
    let snapshot = SessionSnapshot::from_value(
        fixture("sessions/recorded-session-get-no-items.json")["response"].clone(),
    )
    .unwrap();
    let id = snapshot.id.clone();
    let original = SavedConversation {
        saved_at_ms: 1_800_000_000_000,
        session: snapshot,
        older: items.iter().map(|(_, item)| item.clone()).collect(),
        newest: vec![message("msg_last", "Last")],
        older_cursor: Some("cursor_1".to_owned()),
    };
    let decoded = decode_conversation(&encode_conversation(&original).unwrap(), &id).unwrap();
    for ((name, item), back) in items.iter().zip(&decoded.older) {
        assert_eq!(item, back, "{name}: {}", item.id);
    }
    assert_eq!(decoded, original);
}

#[test]
fn a_saved_session_list_comes_back_and_shows_as_the_list_shows_it() {
    let rows: Vec<SessionListItem> =
        fixture("sessions/recorded-sessions-list.json")["response"]["data"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| SessionListItem::from_value(row.clone()).unwrap())
            .collect();
    let list = SavedSessionList {
        saved_at_ms: 3,
        rows: rows.clone(),
    };
    let decoded = decode_list(&encode_list(&list).unwrap()).unwrap();
    assert_eq!(decoded, list);
    let summaries = saved_summaries(&decoded.rows).unwrap();
    let ids: Vec<&str> = summaries
        .iter()
        .map(|summary| summary.id.as_str())
        .collect();
    let expected: Vec<&str> = rows.iter().map(|row| row.id.as_str()).collect();
    assert_eq!(ids, expected);
    assert_eq!(summaries[0].title, "fixture delete session");
}

#[test]
fn saved_list_rows_take_later_pages_and_removals() {
    let row = |id: &str, title: &str| {
        SessionListItem::from_json(
            format!(r#"{{"id":"{id}","status":"idle","created_at":1,"title":"{title}"}}"#)
                .as_bytes(),
        )
        .unwrap()
    };
    let mut list = SavedSessionList {
        saved_at_ms: 1,
        rows: vec![row("a", "A"), row("b", "B")],
    };
    list.upsert(&[row("b", "B2"), row("c", "C")]);
    let titles: Vec<_> = list
        .rows
        .iter()
        .map(|row| row.title.value().cloned())
        .collect();
    assert_eq!(
        titles,
        [Some("A".into()), Some("B2".into()), Some("C".into())]
    );
    assert!(list.remove(&["a".to_owned()]));
    assert!(!list.remove(&["a".to_owned()]));
    assert_eq!(list.rows.len(), 2);
}

#[test]
fn a_damaged_file_says_where_it_broke_without_quoting_what_it_holds() {
    let good = encode_conversation(&saved(&[], &["msg_1"], None)).unwrap();
    let truncated = good.get(..good.len() / 2).unwrap();
    for (bytes, expected) in [
        (truncated.to_vec(), "Eof error at line 1"),
        (b"[]".to_vec(), "not a JSON object"),
        (
            br#"{"version":99,"saved_at_ms":1}"#.to_vec(),
            "format version 99",
        ),
        (br#"{"saved_at_ms":1}"#.to_vec(), "no format version"),
    ] {
        let error = decode_conversation(&bytes, "conv_a").unwrap_err();
        assert!(matches!(error, CacheError::Corrupt { .. }), "{error:?}");
        assert!(error.to_string().contains(expected), "{error}");
    }
    assert!(
        decode_conversation(&good, "conv_b")
            .unwrap_err()
            .to_string()
            .contains("another session")
    );
    // A secret in an item of the wrong shape never reaches the message.
    let mut value: Value = serde_json::from_slice(&good).unwrap();
    value["newest"][0]["created_at"] = serde_json::json!("words-the-user-wrote");
    let error = decode_conversation(&serde_json::to_vec(&value).unwrap(), "conv_a").unwrap_err();
    let text = error.to_string();
    assert!(text.contains("newest[0]"), "{text}");
    assert!(!text.contains("the-user-wrote"), "{text}");
}

#[test]
fn files_are_named_by_hashes_per_server_and_account() {
    let typed = CacheScope::new("127.0.0.1:6767", "local").unwrap();
    let canonical = CacheScope::new("http://127.0.0.1:6767/", "local").unwrap();
    assert_eq!(typed, canonical);
    let other_user = CacheScope::new("http://127.0.0.1:6767", "ada").unwrap();
    assert_eq!(other_user.server_key(), typed.server_key());
    assert_ne!(other_user.account_key(), typed.account_key());
    let other_server = CacheScope::new("https://omnigent.example.com", "local").unwrap();
    assert_ne!(other_server.server_key(), typed.server_key());
    let path = typed.conversation_path("conv_secret_id");
    assert!(path.starts_with(&format!(
        "{}/{}/conversations/",
        typed.server_key(),
        typed.account_key()
    )));
    for text in [
        &path,
        &typed.list_path(),
        &last_account_path(typed.server_key()),
    ] {
        assert!(
            !text.contains("127.0.0.1") && !text.contains("local") && !text.contains("conv_"),
            "{text}"
        );
    }
    assert!(CacheScope::new("not a url at all ::", "local").is_none());
    let account =
        decode_last_account(&encode_last_account(typed.account_key(), 5).unwrap()).unwrap();
    assert_eq!(account, typed.account_key());
    assert!(decode_last_account(&encode_last_account("../escape", 5).unwrap()).is_err());
}

#[test]
fn eviction_takes_the_least_recently_used_first_and_never_the_kept_file() {
    let file = |bytes, last_used_ms, keep| CachedFile {
        bytes,
        last_used_ms,
        keep,
    };
    let files = [
        file(40, 300, false),
        file(40, 100, false),
        file(40, 200, false),
        file(40, 50, true),
    ];
    assert_eq!(evictions(&files, 160), Vec::<usize>::new());
    assert_eq!(evictions(&files, 120), [1]);
    assert_eq!(evictions(&files, 80), [1, 2]);
    // The kept file stays even when the rest cannot make room for it.
    assert_eq!(evictions(&files, 0), [1, 2, 0]);
}

#[test]
fn a_saved_copy_keeps_the_newest_items_and_pages_on_from_the_oldest_kept() {
    let older: Vec<String> = (0..MAX_SAVED_ITEMS)
        .map(|index| format!("old_{index:05}"))
        .collect();
    let older: Vec<&str> = older.iter().map(String::as_str).collect();
    let history = HistoryItems {
        older: messages(&older),
        newest: messages(&["new_1", "new_2"]),
        cursor: Some("old_00000".to_owned()),
    };
    let saved = SavedConversation::new(1, idle_session(), history, &[]);
    assert_eq!(saved.items().count(), MAX_SAVED_ITEMS);
    assert_eq!(saved.older_cursor.as_deref(), Some("old_00002"));
    assert_eq!(saved.newest.len(), 2);
    let under = SavedConversation::new(
        1,
        idle_session(),
        HistoryItems {
            older: messages(&["old_1"]),
            newest: messages(&["new_1"]),
            cursor: Some("old_1".to_owned()),
        },
        &[],
    );
    assert_eq!(under.older_cursor.as_deref(), Some("old_1"));
}

#[test]
fn items_the_stream_committed_join_the_newest_page_by_id() {
    let history = HistoryItems {
        older: Vec::new(),
        newest: messages(&["msg_1", "msg_2"]),
        cursor: None,
    };
    let streamed = [message("msg_2", "longer"), message("msg_3", "new")];
    let saved = SavedConversation::new(1, idle_session(), history, &streamed);
    let ids: Vec<&str> = saved.newest.iter().map(|item| item.id.as_str()).collect();
    assert_eq!(ids, ["msg_1", "msg_2", "msg_3"]);
    assert_eq!(saved.newest[1], streamed[0]);
}

#[test]
fn a_saved_copy_opens_as_rows_before_any_stream() {
    let mut saved = saved(&["msg_1"], &["msg_2", "msg_3"], Some("msg_1"));
    saved.session = session(
        r#"{"id":"conv_a","status":"running","created_at":1,"permission_level":4,"title":"Plans"}"#,
    );
    let mut sync = ConversationSync::new("conv_a");
    let update = sync.restore_saved(&saved).unwrap();
    assert_eq!(update.changes.rows.len(), 3);
    assert_eq!(row_ids(&sync), ["msg_1", "msg_2", "msg_3"]);
    let header = &sync.published().unwrap().header;
    assert_eq!(header.title, "Plans");
    // Nothing runs while a saved copy shows.
    assert_eq!(header.status, TurnStatus::Idle);
    assert_eq!(
        sync.history_paging(),
        HistoryPaging {
            has_older: true,
            is_loading: false
        }
    );
    // Shown once; a second copy or another session's changes nothing.
    assert!(sync.restore_saved(&saved).unwrap().changes.is_empty());
    let mut other = ConversationSync::new("conv_b");
    assert!(other.restore_saved(&saved).unwrap().changes.is_empty());
    assert!(other.published().is_none());
}

#[test]
fn the_first_hydration_replaces_the_saved_rows_and_keeps_saved_pages_that_join() {
    let mut sync = ConversationSync::new("conv_a");
    sync.restore_saved(&saved(
        &["msg_1", "msg_2"],
        &["msg_3", "msg_4"],
        Some("msg_1"),
    ))
    .unwrap();
    let request = sync.open_stream();
    // The server's newest page shares msg_4, which changed, and adds msg_5.
    let page = [message("msg_4", "edited"), message("msg_5", "msg_5")];
    let update = sync
        .finish_hydration_page(&request, &idle_session(), &page, Some("msg_4"))
        .unwrap();
    assert!(!update.changes.is_empty());
    assert_eq!(
        row_ids(&sync),
        ["msg_1", "msg_2", "msg_3", "msg_4", "msg_5"]
    );
    let rows = &sync.published().unwrap().rows;
    assert_eq!(rows[3].text, "edited");
    assert_eq!(sync.begin_older_history().unwrap().cursor, "msg_1");
    let held = sync.history_items();
    assert_eq!(held.newest, page);
    assert_eq!(held.older, messages(&["msg_1", "msg_2", "msg_3"]));
}

#[test]
fn a_hydration_that_no_longer_joins_drops_the_saved_rows() {
    let mut sync = ConversationSync::new("conv_a");
    sync.restore_saved(&saved(&["msg_1"], &["msg_2"], Some("msg_1")))
        .unwrap();
    let request = sync.open_stream();
    let page = messages(&["msg_8", "msg_9"]);
    sync.finish_hydration_page(&request, &idle_session(), &page, Some("msg_8"))
        .unwrap();
    assert_eq!(row_ids(&sync), ["msg_8", "msg_9"]);
    assert_eq!(sync.begin_older_history().unwrap().cursor, "msg_8");
    // Rows are shown now, so a saved copy no longer applies.
    assert!(
        sync.restore_saved(&saved(&[], &["msg_1"], None))
            .unwrap()
            .changes
            .is_empty()
    );
}

#[test]
fn the_history_held_is_what_hydration_and_older_pages_read() {
    let mut sync = ConversationSync::new("conv_a");
    assert_eq!(sync.history_items(), HistoryItems::default());
    let request = sync.open_stream();
    sync.finish_hydration_page(
        &request,
        &idle_session(),
        &messages(&["msg_3", "msg_4"]),
        Some("msg_3"),
    )
    .unwrap();
    let older = sync.begin_older_history().unwrap();
    sync.finish_older_history(&older, &messages(&["msg_1", "msg_2"]), None)
        .unwrap();
    let held = sync.history_items();
    assert_eq!(held.older, messages(&["msg_1", "msg_2"]));
    assert_eq!(held.newest, messages(&["msg_3", "msg_4"]));
    assert_eq!(held.cursor, None);
    let restored = SavedConversation::new(9, idle_session(), held, &[]);
    let rows = history_rows(&restored.items().cloned().collect::<Vec<_>>()).unwrap();
    assert_eq!(rows.len(), 4);
}
