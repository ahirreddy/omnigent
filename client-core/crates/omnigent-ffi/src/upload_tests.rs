//! Attachments through the real offline demo core, which has no entropy source for random
//! multipart boundaries.

use std::sync::Arc;

use crate::test_support::Harness;

#[test]
fn the_offline_demo_uploads_an_attachment() {
    let mut harness = Harness::demo();
    let core = Arc::clone(&harness.core);
    harness
        .run(async move { core.connect(String::new(), None).await })
        .unwrap();
    harness.core.open_session("demo-design".into());
    harness.pump();
    let item_id = harness
        .core
        .add_attachment(
            "demo-design".into(),
            "notes.txt".into(),
            Some("text/plain".into()),
            b"notes".to_vec(),
        )
        .unwrap();
    let core = Arc::clone(&harness.core);
    let uploaded =
        harness.run(async move { core.upload_attachment("demo-design".into(), item_id).await });
    assert!(uploaded.is_ok(), "{uploaded:?}");
}
