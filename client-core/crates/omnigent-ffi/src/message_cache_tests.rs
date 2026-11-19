//! The saved copy on disk: whole writes, damaged files, eviction and deletion.

use std::path::Path;

use futures::channel::mpsc::{self, UnboundedReceiver};
use omnigent_core::message_cache::{
    self as cache, CacheError, CacheScope, SavedConversation, SavedSessionList,
};
use omnigent_protocol::{ConversationItem, FromWire, SessionListItem, SessionSnapshot};

use super::{CacheFailureScope, MessageCache};
use crate::cache_driver::SavedMsg;
use crate::engine::Msg;
use crate::test_support::TempFolder;

fn scope(user_id: &str) -> CacheScope {
    CacheScope::new("http://127.0.0.1:6767", user_id).unwrap()
}

/// `session_id`'s copy with one message, saved at `at_ms`. Ids of one length save to files of
/// one size.
fn conversation(session_id: &str, at_ms: u64) -> SavedConversation {
    let session = SessionSnapshot::from_json(
        format!(r#"{{"id":"{session_id}","status":"idle","created_at":1}}"#).as_bytes(),
    )
    .unwrap();
    let item = ConversationItem::from_json(
        br#"{"id":"msg_1","type":"message","role":"assistant","content":"Saved"}"#,
    )
    .unwrap();
    SavedConversation {
        saved_at_ms: at_ms,
        session,
        older: Vec::new(),
        newest: vec![item],
        older_cursor: None,
    }
}

fn store(folder: &Path, cap: u64) -> (MessageCache, UnboundedReceiver<Msg>) {
    let (report, failures) = mpsc::unbounded();
    (MessageCache::with_cap(folder, report, cap), failures)
}

/// The failures reported so far.
fn failures(reports: &mut UnboundedReceiver<Msg>) -> Vec<(CacheFailureScope, CacheError)> {
    let mut found = Vec::new();
    while let Ok(message) = reports.try_recv() {
        if let Msg::Saved(SavedMsg::Failed { failure, error }) = message {
            found.push((failure, error));
        }
    }
    found
}

fn no_failures(reports: &mut UnboundedReceiver<Msg>) {
    let reported = failures(reports);
    assert!(reported.is_empty(), "{reported:?}");
}

fn files_under(folder: &Path) -> Vec<String> {
    let mut found = Vec::new();
    let mut pending = vec![folder.to_path_buf()];
    while let Some(next) = pending.pop() {
        let Ok(entries) = std::fs::read_dir(&next) else {
            continue;
        };
        for entry in entries {
            let path = entry.unwrap().path();
            if path.is_dir() {
                pending.push(path);
            } else {
                found.push(
                    path.strip_prefix(folder)
                        .unwrap()
                        .to_string_lossy()
                        .into_owned(),
                );
            }
        }
    }
    found.sort();
    found
}

#[test]
fn a_write_lands_whole_and_reads_back() {
    let folder = TempFolder::new("cache-write");
    let (store, mut reports) = store(&folder.0, cache::MAX_CACHE_BYTES);
    let account = scope("local");
    assert_eq!(store.read_conversation(&account, "conv_a").unwrap(), None);
    store.save_conversation(&account, "conv_a", conversation("conv_a", 5));
    store.save_conversation(&account, "conv_a", conversation("conv_a", 6));
    let list = SavedSessionList {
        saved_at_ms: 7,
        rows: vec![
            SessionListItem::from_json(br#"{"id":"conv_a","status":"idle","created_at":1}"#)
                .unwrap(),
        ],
        projects: None,
    };
    store.save_list(&account, list.clone());
    store.save_last_account(&account, 8);
    store.flush();
    assert_eq!(
        store.read_conversation(&account, "conv_a").unwrap(),
        Some(conversation("conv_a", 6))
    );
    assert_eq!(store.read_list(&account).unwrap(), Some(list));
    assert_eq!(
        store.read_last_account(account.server_key()).unwrap(),
        Some(account.account_key().to_owned())
    );
    // Three files and no temporary one is left, and no name says whose it is.
    let files = files_under(&folder.0);
    assert_eq!(files.len(), 3, "{files:?}");
    assert!(
        files.iter().all(|file| !file.contains("conv_a")),
        "{files:?}"
    );
    no_failures(&mut reports);
}

#[test]
fn a_damaged_file_is_reported_and_discarded() {
    let folder = TempFolder::new("cache-damaged");
    let (store, mut reports) = store(&folder.0, cache::MAX_CACHE_BYTES);
    let account = scope("local");
    let path = folder.0.join(account.conversation_path("conv_a"));
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, b"{\"version\":1,\"saved_at").unwrap();
    let error = store.read_conversation(&account, "conv_a").unwrap_err();
    assert!(matches!(error, CacheError::Corrupt { .. }), "{error:?}");
    store.flush();
    assert!(!path.exists(), "the damaged file is discarded");
    assert_eq!(store.read_conversation(&account, "conv_a").unwrap(), None);
    // A file that cannot be read at all is a read error, and stays.
    let list = folder.0.join(account.list_path());
    std::fs::create_dir_all(&list).unwrap();
    assert!(matches!(
        store.read_list(&account),
        Err(CacheError::Read { .. })
    ));
    no_failures(&mut reports);
}

#[test]
fn a_failed_write_is_reported_once() {
    let folder = TempFolder::new("cache-unwritable");
    // A file where the cache folder belongs: nothing can be written under it.
    std::fs::write(&folder.0, b"not a folder").unwrap();
    let (store, mut reports) = store(&folder.0, cache::MAX_CACHE_BYTES);
    let account = scope("local");
    store.save_conversation(&account, "conv_a", conversation("conv_a", 1));
    store.save_conversation(&account, "conv_b", conversation("conv_b", 2));
    store.flush();
    let reported = failures(&mut reports);
    assert_eq!(reported.len(), 1, "{reported:?}");
    let (scope, error) = &reported[0];
    assert_eq!(*scope, CacheFailureScope::Session("conv_a".into()));
    assert!(matches!(error, CacheError::Write { .. }), "{error:?}");
    std::fs::remove_file(&folder.0).unwrap();
}

#[test]
fn eviction_keeps_the_cap_dropping_the_least_recently_opened() {
    let folder = TempFolder::new("cache-evict");
    let size = u64::try_from(
        cache::encode_conversation(&conversation("conv_a", 1))
            .unwrap()
            .len(),
    )
    .unwrap();
    let (store, mut reports) = store(&folder.0, size * 3 + size / 2);
    let account = scope("local");
    for (index, id) in ["conv_a", "conv_b", "conv_c"].iter().enumerate() {
        let at = 1_000 * (u64::try_from(index).unwrap() + 1);
        store.save_conversation(&account, id, conversation(id, at));
        store.flush();
    }
    // Opening conv_a makes conv_b the least recently opened.
    store.touch_conversation(&account, "conv_a", 4_000);
    store.save_conversation(&account, "conv_d", conversation("conv_d", 5_000));
    store.flush();
    let saved = |id: &str| store.read_conversation(&account, id).unwrap().is_some();
    assert!(saved("conv_a") && saved("conv_c") && saved("conv_d"));
    assert!(!saved("conv_b"));
    no_failures(&mut reports);
}

#[test]
fn forgetting_an_account_or_a_server_deletes_only_its_files() {
    let folder = TempFolder::new("cache-forget");
    let (store, mut reports) = store(&folder.0, cache::MAX_CACHE_BYTES);
    let ada = scope("ada");
    let grace = scope("grace");
    let elsewhere = CacheScope::new("https://omnigent.example.com", "ada").unwrap();
    for account in [&ada, &grace, &elsewhere] {
        store.save_conversation(account, "conv_a", conversation("conv_a", 1));
    }
    store.save_last_account(&ada, 2);
    store.forget_account(&ada);
    store.flush();
    assert_eq!(store.read_conversation(&ada, "conv_a").unwrap(), None);
    assert_eq!(store.read_last_account(ada.server_key()).unwrap(), None);
    assert!(store.read_conversation(&grace, "conv_a").unwrap().is_some());
    // Signing out of one account leaves the record naming another alone.
    store.save_last_account(&grace, 3);
    store.forget_account(&ada);
    store.flush();
    assert!(
        store
            .read_last_account(grace.server_key())
            .unwrap()
            .is_some()
    );
    store.forget_server(grace.server_key().to_owned());
    store.flush();
    assert_eq!(store.read_conversation(&grace, "conv_a").unwrap(), None);
    assert!(!folder.0.join(grace.server_key()).exists());
    assert!(
        store
            .read_conversation(&elsewhere, "conv_a")
            .unwrap()
            .is_some()
    );
    no_failures(&mut reports);
}
