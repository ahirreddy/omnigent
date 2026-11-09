//! Files held for queued messages.

use url::Url;

use super::*;

fn key() -> DraftKey {
    DraftKey::new("server/account", "session_a")
}

fn file(name: &str) -> UploadFile {
    UploadFile::new(name, None, b"held bytes".to_vec()).unwrap()
}

/// Stages and uploads `names` in `key`'s draft.
fn uploaded(store: &mut AttachmentDraftStore, names: &[&str]) -> Vec<DraftItemId> {
    names
        .iter()
        .map(|name| {
            let id = store.add(file(name), &key()).unwrap();
            let attempt = store.begin_upload(&key(), id).unwrap();
            let reference = UploadedAttachment {
                server_url: Url::parse("http://127.0.0.1:6767").unwrap(),
                user_id: None,
                session_id: key().session_id,
                id: format!("file_{}", id.get()),
                filename: (*name).to_owned(),
                is_image: false,
            };
            store.finish_upload(&attempt, Ok(reference)).unwrap();
            id
        })
        .collect()
}

fn ids(items: &[DraftItem]) -> Vec<DraftItemId> {
    items.iter().map(DraftItem::id).collect()
}

#[test]
fn holding_takes_the_uploaded_files_out_of_the_draft() {
    let mut store = AttachmentDraftStore::new();
    assert_eq!(store.hold(&key()), Ok(None));
    let uploaded = uploaded(&mut store, &["a.txt", "b.png"]);
    let hold = store.hold(&key()).unwrap().unwrap();
    assert!(!store.draft(&key()).has_attachments());
    assert_eq!(ids(store.held(&key(), hold).unwrap()), uploaded);
    let other = DraftKey::new("other/account", key().session_id);
    assert_eq!(store.held(&other, hold), Err(DraftError::UnknownItem));
    // The draft takes new files meanwhile.
    store.add(file("c.txt"), &key()).unwrap();
}

#[test]
fn a_file_still_uploading_cannot_be_held() {
    let mut store = AttachmentDraftStore::new();
    let id = store.add(file("a.txt"), &key()).unwrap();
    assert_eq!(store.hold(&key()), Err(DraftError::NotReady));
    store.begin_upload(&key(), id).unwrap();
    assert_eq!(store.hold(&key()), Err(DraftError::NotReady));
    assert!(store.draft(&key()).has_attachments());
}

#[test]
fn a_held_send_drops_the_hold_only_once_accepted() {
    let mut store = AttachmentDraftStore::new();
    uploaded(&mut store, &["a.txt"]);
    let hold = store.hold(&key()).unwrap().unwrap();
    let staged = store.add(file("staged.txt"), &key()).unwrap();
    let batch = store.begin_held_submission(&key(), hold).unwrap();
    assert_eq!(batch.attachments().len(), 1);
    assert_eq!(batch.attachments()[0].filename, "a.txt");
    assert_eq!(store.discard(&key(), hold), Err(DraftError::Locked));
    assert_eq!(store.restore(&key(), hold), Err(DraftError::Locked));
    store
        .finish_submission(&batch, SubmissionOutcome::Rejected)
        .unwrap();
    let retry = store.begin_held_submission(&key(), hold).unwrap();
    store
        .finish_submission(&retry, SubmissionOutcome::Accepted)
        .unwrap();
    assert_eq!(store.held(&key(), hold), Err(DraftError::UnknownItem));
    // The draft's own files never went with it.
    assert_eq!(ids(store.draft(&key()).items()), [staged]);
}

#[test]
fn restoring_puts_the_files_back_when_the_draft_has_room() {
    let mut store = AttachmentDraftStore::new();
    let uploaded = uploaded(&mut store, &["a.txt", "b.txt"]);
    let hold = store.hold(&key()).unwrap().unwrap();
    let mut staged = Vec::new();
    for index in 0..MAX_FILES_PER_DRAFT - 1 {
        staged.push(store.add(file(&format!("{index}.txt")), &key()).unwrap());
    }
    assert_eq!(store.restore(&key(), hold), Err(DraftError::DraftLimit));
    assert!(store.held(&key(), hold).is_ok());
    for item in &staged[1..] {
        store.remove(&key(), *item).unwrap();
    }
    store.restore(&key(), hold).unwrap();
    assert_eq!(
        ids(store.draft(&key()).items()),
        [staged[0], uploaded[0], uploaded[1]]
    );
}

#[test]
fn discarding_forgets_the_hold() {
    let mut store = AttachmentDraftStore::new();
    uploaded(&mut store, &["a.txt"]);
    let hold = store.hold(&key()).unwrap().unwrap();
    store.discard(&key(), hold).unwrap();
    assert_eq!(store.discard(&key(), hold), Err(DraftError::UnknownItem));
    assert_eq!(
        store.begin_held_submission(&key(), hold),
        Err(DraftError::UnknownItem)
    );
}

#[test]
fn a_held_send_waits_for_the_running_send_and_a_locked_item_cannot_upload_again() {
    let mut store = AttachmentDraftStore::new();
    let items = uploaded(&mut store, &["a.txt"]);
    let hold = store.hold(&key()).unwrap().unwrap();
    let more = uploaded(&mut store, &["b.txt"]);
    let batch = store.begin_submission(&key()).unwrap();
    assert_eq!(batch.key(), &key());
    assert_eq!(
        store.begin_held_submission(&key(), hold).map(|_| ()),
        Err(DraftError::NotReady)
    );
    assert_eq!(
        store.begin_upload(&key(), more[0]).map(|_| ()),
        Err(DraftError::Locked)
    );
    assert_eq!(items.len(), 1);
}
