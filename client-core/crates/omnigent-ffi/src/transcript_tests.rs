//! Transcript conversions, row ops, and the session calls that live with them.

use std::sync::Arc;

use omnigent_core::recovery::FailureRecovery as CoreRecovery;

use super::core;
use super::*;
use crate::errors::CoreError;
use crate::test_support::{connected, json};

fn row(id: &str) -> Row {
    Row {
        id: id.to_owned(),
        role: RowRole::User,
        text: String::new(),
        is_streaming: false,
        activity: None,
        attachments: Vec::new(),
        call_id: None,
        response_id: None,
        interrupted: false,
        author: None,
        agent: None,
        created_at: None,
        is_ephemeral: false,
        is_activity_only: false,
    }
}

#[test]
fn recovery_converts_both_ways() {
    for (ours, theirs) in [
        (FailureRecovery::Continue, CoreRecovery::Continue),
        (FailureRecovery::Resume, CoreRecovery::Resume),
    ] {
        assert_eq!(FailureRecovery::from(theirs), ours);
        assert_eq!(CoreRecovery::from(ours), theirs);
    }
}

#[test]
fn every_activity_and_attachment_kind_converts() {
    use core::ActivityKind as K;
    for (theirs, ours) in [
        (K::ToolCall, ActivityKind::ToolCall),
        (K::ToolResult, ActivityKind::ToolResult),
        (K::NativeTool, ActivityKind::NativeTool),
        (K::Reasoning, ActivityKind::Reasoning),
        (K::Compaction, ActivityKind::Compaction),
        (K::Command, ActivityKind::Command),
        (K::Terminal, ActivityKind::Terminal),
        (K::Routing, ActivityKind::Routing),
        (K::Resource, ActivityKind::Resource),
        (K::Error, ActivityKind::Error),
        (K::Unknown, ActivityKind::Unknown),
        (K::Retry, ActivityKind::Retry),
        (K::File, ActivityKind::File),
        (K::Policy, ActivityKind::Policy),
        (K::ClientTask, ActivityKind::ClientTask),
        (K::Browser, ActivityKind::Browser),
        (K::Sidechat, ActivityKind::Sidechat),
    ] {
        assert_eq!(ActivityKind::from(theirs), ours);
    }
    for (theirs, ours) in [
        (core::AttachmentKind::Image, AttachmentKind::Image),
        (core::AttachmentKind::File, AttachmentKind::File),
        (core::AttachmentKind::Audio, AttachmentKind::Audio),
        (core::AttachmentKind::Video, AttachmentKind::Video),
    ] {
        let attachment = Attachment::from(core::Attachment {
            id: "a1".into(),
            kind: theirs,
            title: "photo".into(),
            reference: Some("file_1".into()),
            mime_type: Some("image/png".into()),
            is_embedded: true,
        });
        assert_eq!(attachment.kind, ours);
        assert_eq!(attachment.id, "a1");
        assert_eq!(attachment.title, "photo");
        assert_eq!(attachment.reference.as_deref(), Some("file_1"));
        assert_eq!(attachment.mime_type.as_deref(), Some("image/png"));
        assert!(attachment.is_embedded);
    }
}

#[test]
fn row_ops_that_do_not_fit_are_refused_and_name_the_problem() {
    let two = || vec![row("a"), row("b")];
    assert!(matches!(
        apply_row_ops(
            two(),
            vec![RowOp::Insert {
                index: 3,
                row: row("c"),
            }]
        ),
        Err(CoreError::RowOps { .. })
    ));
    assert!(matches!(
        apply_row_ops(
            two(),
            vec![RowOp::Update {
                index: 2,
                row: row("a"),
            }]
        ),
        Err(CoreError::RowOps { .. })
    ));
    assert!(matches!(
        apply_row_ops(
            two(),
            vec![RowOp::Update {
                index: 0,
                row: row("b"),
            }]
        ),
        Err(CoreError::RowOps { .. })
    ));
    assert!(matches!(
        apply_row_ops(two(), vec![RowOp::Remove { id: "z".into() }]),
        Err(CoreError::RowOps { .. })
    ));
    assert!(matches!(
        apply_row_ops(
            two(),
            vec![RowOp::Insert {
                index: u32::MAX,
                row: row("c"),
            }]
        ),
        Err(CoreError::RowOps { .. })
    ));
    let applied = apply_row_ops(
        two(),
        vec![
            RowOp::Remove { id: "a".into() },
            RowOp::Insert {
                index: 1,
                row: row("c"),
            },
            RowOp::Update {
                index: 0,
                row: row("b"),
            },
        ],
    )
    .unwrap();
    let ids: Vec<&str> = applied.iter().map(|row| row.id.as_str()).collect();
    assert_eq!(ids, ["b", "c"]);
}

#[test]
fn exporting_reads_the_session_and_its_items_and_reports_a_failed_read() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions/conv_a",
        json(200, r#"{"id":"conv_a","status":"idle","created_at":1}"#),
    );
    harness.http.route(
        "/v1/sessions/conv_a/items",
        json(200, r#"{"object":"list","data":[],"has_more":false}"#),
    );
    let core = Arc::clone(&harness.core);
    let exported = harness
        .run(async move { core.export_transcript("conv_a".into()).await })
        .unwrap();
    assert!(exported.contains("session_meta"), "{exported}");

    harness
        .http
        .route("/v1/sessions/conv_a", json(500, r#"{"detail":"boom"}"#));
    let core = Arc::clone(&harness.core);
    assert!(matches!(
        harness.run(async move { core.export_transcript("conv_a".into()).await }),
        Err(CoreError::Session { .. })
    ));
}

#[test]
fn agent_info_names_its_tools_and_policies() {
    let mut harness = connected();
    harness.http.route(
        "/v1/agents/agent_1",
        json(200, r#"{"name":"Helper","mcp_servers":[{"name":"docs"}]}"#),
    );
    harness.http.route(
        "/v1/sessions/conv_a/policies",
        json(200, r#"{"data":[{"name":"no-rm"}]}"#),
    );
    let core = Arc::clone(&harness.core);
    let info = harness
        .run(async move { core.agent_info("conv_a".into(), "agent_1".into()).await })
        .unwrap();
    assert_eq!(info.name, "Helper");
    assert_eq!(info.tools, ["docs"]);

    harness
        .http
        .route("/v1/agents/agent_1", json(404, r#"{"detail":"no"}"#));
    let core = Arc::clone(&harness.core);
    assert!(matches!(
        harness.run(async move { core.agent_info("conv_a".into(), "agent_1".into()).await }),
        Err(CoreError::Session { .. })
    ));
}

#[test]
fn recovering_a_turn_reports_a_refusal() {
    let mut harness = connected();
    let core = Arc::clone(&harness.core);
    let result = harness.run(async move {
        core.recover_turn("conv_a".into(), FailureRecovery::Continue)
            .await
    });
    assert!(
        matches!(result, Err(CoreError::Session { .. })),
        "{result:?}"
    );
}
