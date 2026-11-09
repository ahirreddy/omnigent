//! Inbox comments, replies and the usage report over the fake host.

use omnigent_core::comments as core_comments;
use omnigent_core::usage as core_usage;
use serde_json::json;

use crate::errors::CoreError;
use crate::inbox::{
    DailyCost, FileComment, ModelCost, SessionUsage, UsageReport, comment_inbox,
    file_comment_lines, format_cost_usd, line_at_character, line_character_range, usage_day,
    usage_window, usage_window_start,
};
use crate::test_support::{connected, json as reply};

fn comment(id: &str, author: Option<&str>, created_at: i64) -> FileComment {
    FileComment {
        id: id.into(),
        session_id: "s1".into(),
        path: "a.rs".into(),
        body: format!("body of {id}"),
        is_open: true,
        anchor: Some("two".into()),
        start_index: Some(4),
        author: author.map(str::to_owned),
        created_at,
        updated_at_micros: u64::MAX,
    }
}

#[test]
fn a_comment_round_trips_every_field_through_the_core() {
    let original = comment("c1", Some("ann"), -7);
    let core = core_comments::FileComment::from(original.clone());
    assert_eq!(core.id, "c1");
    assert_eq!(core.session_id, "s1");
    assert_eq!(core.path, "a.rs");
    assert_eq!(core.body, "body of c1");
    assert!(core.is_open);
    assert_eq!(core.anchor.as_deref(), Some("two"));
    assert_eq!(core.start_index, Some(4));
    assert_eq!(core.author.as_deref(), Some("ann"));
    assert_eq!(core.created_at, -7);
    assert_eq!(core.updated_at_micros, u64::MAX);
    assert_eq!(FileComment::from(core), original);
}

#[test]
fn lines_are_counted_in_characters_and_ranges_leave_out_the_break() {
    assert_eq!(line_at_character("é\ntwo".into(), 2), Some(2));
    assert_eq!(line_at_character("x".into(), 99), None);
    assert_eq!(line_at_character(String::new(), u64::MAX), None);
    assert_eq!(
        line_character_range("one\ntwo\n".into(), 2),
        Some(vec![4, 7])
    );
    assert_eq!(line_character_range("one".into(), 5), None);
    assert_eq!(line_character_range("one".into(), u64::MAX), None);
}

#[test]
fn comment_lines_follow_the_anchor_and_the_inbox_hides_the_seen_and_ones_own() {
    let lines = file_comment_lines(
        vec![comment("c1", None, 1)],
        "a.rs".into(),
        "one\ntwo\n".into(),
    );
    assert_eq!(lines[0].line, Some(2));
    assert_eq!(lines[0].comment.id, "c1");
    assert_eq!(
        file_comment_lines(vec![comment("c1", None, 1)], "b.rs".into(), String::new()),
        []
    );
    let inbox = comment_inbox(
        vec![
            comment("old", Some("bob"), 1),
            comment("new", Some("bob"), 2),
            comment("mine", Some("me"), 3),
            comment("seen", Some("bob"), 4),
        ],
        vec!["seen".into()],
        Some("me".into()),
    );
    assert_eq!(
        inbox.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(),
        ["new", "old"]
    );
}

#[test]
fn usage_converts_both_ways_and_a_window_keeps_each_field() {
    let session = SessionUsage {
        id: "s1".into(),
        title: Some("Fix".into()),
        created_at: 1_793_700_000,
        updated_at: 1_793_750_000,
        cost_usd: 1.25,
        models: vec![ModelCost {
            model: "sonnet".into(),
            cost_usd: 1.25,
        }],
        harness: Some("claude-code".into()),
    };
    let core = core_usage::SessionUsage::from(session.clone());
    assert_eq!(core.models, [("sonnet".to_owned(), 1.25)]);
    assert_eq!(SessionUsage::from(core), session);
    assert_eq!(
        DailyCost::from(core_usage::DailyCost::from(DailyCost {
            day: "2026-11-03".into(),
            cost_usd: 0.5
        })),
        DailyCost {
            day: "2026-11-03".into(),
            cost_usd: 0.5
        }
    );

    let report = UsageReport {
        daily_costs: vec![
            DailyCost {
                day: "2026-10-01".into(),
                cost_usd: 2.0,
            },
            DailyCost {
                day: "2026-11-03".into(),
                cost_usd: 0.5,
            },
        ],
        sessions: vec![session],
    };
    let window = usage_window(report.clone(), Some("2026-11-01".into()), None);
    assert!((window.total_cost_usd - 0.5).abs() < 1e-9);
    assert_eq!(window.daily_costs.len(), 1);
    assert_eq!(window.daily_costs[0].day, "2026-11-03");
    assert_eq!(window.sessions[0].id, "s1");
    assert_eq!(window.by_harness[0].name, "claude-code");
    assert!((window.by_harness[0].cost_usd - 1.25).abs() < 1e-9);
    assert_eq!(window.by_model[0].name, "sonnet");

    let until = usage_window(report, None, Some("2026-10-02".into()));
    assert_eq!(until.daily_costs[0].day, "2026-10-01");
    assert_eq!(until.sessions, []);
}

#[test]
fn days_and_costs_format_like_the_core() {
    assert_eq!(usage_day(0), "1970-01-01");
    assert_eq!(usage_day(-1), "1969-12-31");
    assert_eq!(usage_window_start(7, 1_793_865_600), "2026-10-30");
    assert_eq!(format_cost_usd(1.234), "$1.23");
    assert_eq!(format_cost_usd(0.001), "<$0.01");
}

#[test]
fn comments_are_listed_added_updated_and_deleted() {
    let mut harness = connected();
    let list = "/v1/sessions/s1/comments";
    let row = r#"{"id":"c9","conversation_id":"s1","path":"a.rs","start_index":3,"end_index":5,
        "body":"why?","status":"draft","created_at":10,"updated_at":1500000,"anchor_content":"cd","created_by":"ann"}"#;
    harness
        .http
        .route_method("GET", list, reply(200, &format!("[{row}]")));
    harness.http.route_method("POST", list, reply(200, row));
    harness
        .http
        .route_method("PATCH", &format!("{list}/c9"), reply(200, row));
    harness
        .http
        .route_method("DELETE", &format!("{list}/c9"), reply(204, ""));

    let listed = harness
        .call(|core| async move { core.session_comments("s1".into()).await })
        .unwrap();
    let expected = FileComment {
        id: "c9".into(),
        session_id: "s1".into(),
        path: "a.rs".into(),
        body: "why?".into(),
        is_open: true,
        anchor: Some("cd".into()),
        start_index: Some(3),
        author: Some("ann".into()),
        created_at: 10,
        updated_at_micros: 1_500_000,
    };
    assert_eq!(listed, std::slice::from_ref(&expected));

    let added = harness
        .call(|core| async move {
            core.add_session_comment(
                "s1".into(),
                "a.rs".into(),
                " why? ".into(),
                3,
                5,
                Some("cd".into()),
            )
            .await
        })
        .unwrap();
    assert_eq!(added, expected);
    let (line, body) = harness.last_request();
    assert_eq!(line, format!("POST {list}"));
    assert_eq!(body["path"], json!("a.rs"));
    assert_eq!(body["body"], json!("why?"));
    assert_eq!(body["start_index"], json!(3));
    assert_eq!(body["end_index"], json!(5));
    assert_eq!(body["anchor_content"], json!("cd"));

    let updated = harness
        .call(|core| async move {
            core.update_session_comment("s1".into(), "c9".into(), Some("new".into()), Some(false))
                .await
        })
        .unwrap();
    assert_eq!(updated.id, "c9");
    let (line, body) = harness.last_request();
    assert_eq!(line, format!("PATCH {list}/c9"));
    assert_eq!(body["body"], json!("new"));
    assert_eq!(body["status"], json!("addressed"));

    harness
        .call(|core| async move { core.delete_session_comment("s1".into(), "c9".into()).await })
        .unwrap();
    assert_eq!(harness.last_request().0, format!("DELETE {list}/c9"));
}

#[test]
fn a_reply_and_sent_comments_answer_the_submission_fields() {
    let mut harness = connected();
    harness.writable_session("conv_a");
    let sent = harness
        .call(|core| async move { core.send_reply("conv_a".into(), "hello".into()).await })
        .unwrap();
    assert!(sent.queued);
    assert_eq!(sent.item_id.as_deref(), Some("i1"));
    assert_eq!(sent.pending_id.as_deref(), Some("p1"));
    assert_eq!(sent.draft, "");
    let (line, body) = harness.last_request();
    assert_eq!(line, "POST /v1/sessions/conv_a/events");
    assert_eq!(body["data"]["content"][0]["text"], json!("hello"));

    harness.http.route(
        "/v1/sessions/conv_a/comments/send",
        reply(200, r#"{"formatted_message":"Please address"}"#),
    );
    let sent = harness
        .call(|core| async move {
            core.send_comments_to_agent("conv_a".into(), vec!["c1".into()])
                .await
        })
        .unwrap();
    assert!(sent.queued);
    assert_eq!(sent.item_id.as_deref(), Some("i1"));
    assert_eq!(sent.pending_id.as_deref(), Some("p1"));
    let bodies = harness.last_request().1;
    assert_eq!(
        bodies["data"]["content"][0]["text"],
        json!("Please address")
    );

    let error = harness
        .call(|core| async move { core.send_comments_to_agent("conv_a".into(), vec![]).await })
        .unwrap_err();
    assert!(matches!(error, CoreError::Session { .. }), "{error:?}");
}

#[test]
fn latest_output_and_the_usage_report_map_their_fields() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions/s1/items",
        reply(
            200,
            r#"{"data":[{"id":"i3","type":"message","role":"assistant",
                "content":[{"type":"output_text","text":"Done."}]}],"has_more":false}"#,
        ),
    );
    let output = harness
        .call(|core| async move { core.latest_output("s1".into()).await })
        .unwrap()
        .unwrap();
    assert_eq!(output.item_id, "i3");
    assert_eq!(output.preview, "Done.");
    assert_eq!(output.full_text, None);

    harness.http.route(
        "/v1/sessions/s2/items",
        reply(200, r#"{"data":[],"has_more":false}"#),
    );
    assert_eq!(
        harness
            .call(|core| async move { core.latest_output("s2".into()).await })
            .unwrap(),
        None
    );

    harness.http.route(
        "/v1/usage",
        reply(
            200,
            r#"{"daily_costs":[{"day":"2026-11-03","cost_usd":0.5}],"sessions":[{"id":"s1",
                "created_at":17,"updated_at":18,"title":"Fix","cost_usd":1.25,
                "models":{"opus":0.25,"sonnet":1.0},"harness":"claude-code"}]}"#,
        ),
    );
    let report = harness
        .call(|core| async move { core.usage_report().await })
        .unwrap();
    assert_eq!(report.daily_costs[0].day, "2026-11-03");
    let session = &report.sessions[0];
    assert_eq!(session.id, "s1");
    assert_eq!(session.title.as_deref(), Some("Fix"));
    assert_eq!((session.created_at, session.updated_at), (17, 18));
    assert_eq!(session.harness.as_deref(), Some("claude-code"));
    assert_eq!(session.models[0].model, "sonnet");
    assert!((session.models[0].cost_usd - 1.0).abs() < 1e-9);
}
