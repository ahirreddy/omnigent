//! Agent-posted Inbox items and automation failures, in main's wire shapes.

use futures::executor::block_on;
use serde_json::{Value, json};

use super::super::SessionError;
use super::super::test_support::{Reply, RouteTransport, connected, path_of, query_value};
use super::{
    AgentInboxPage, AutomationFailurePage, InboxLinkTarget, InboxResolution,
    inbox_item_kind_label, inbox_item_preview, safe_web_link,
};

const ITEM_ID: &str = "0123456789abcdef0123456789abcdef";

fn item(overrides: &Value) -> Value {
    let mut item = json!({
        "id": ITEM_ID,
        "user_id": "ada",
        "source_session_id": "fedcba9876543210fedcba9876543210",
        "agent_id": "agent-1",
        "kind": "followup",
        "title": "Review the flaky test",
        "body_md": "## Why\nIt failed twice today.",
        "links": [
            {"type": "pr", "ref": "https://example.com/org/repo/pull/7", "label": "PR 7"},
            {"type": "session", "ref": "fedcba9876543210fedcba9876543210"},
            {"type": "url", "ref": "https://example.com/org/repo/pull/7"},
            {"type": "url", "ref": "javascript:alert(1)"},
            {"type": "url", "ref": "https://user:pw@example.com/"}
        ],
        "actions": [
            {"label": "Fix it", "prompt": "Fix the flaky test"},
            {"label": 3, "prompt": "skipped"}
        ],
        "media": [
            {"type": "chart", "chart": {
                "version": 1, "type": "line", "title": "Failures", "unit": "%",
                "x": ["Mon", "Tue"],
                "series": [{"name": "rate", "values": [1, null], "emphasis": true}],
                "highlight": {"from": "Mon", "to": "Tue"},
                "markers": [{"x": "Tue", "label": "deploy"}],
                "source": {"label": "CI", "href": "https://example.com/ci"}
            }},
            {"type": "chart", "chart": {"version": 2, "type": "line"}},
            {"type": "video", "url": "https://example.com/v"}
        ],
        "primary_link": "https://example.com/org/repo/pull/7",
        "topic": "flaky-test",
        "dedupe_key": "v1:abc",
        "status": "unread",
        "resolution": "none",
        "feedback_text": null,
        "created_at": 1_731_900_000,
        "resolved_at": null,
        "expires_at": null,
        "resolution_action": null
    });
    if let (Some(item), Some(overrides)) = (item.as_object_mut(), overrides.as_object()) {
        for (key, value) in overrides {
            item.insert(key.clone(), value.clone());
        }
    }
    item
}

#[test]
fn a_page_decodes_items_links_actions_charts_and_counts() {
    let page = AgentInboxPage::from_value(&json!({
        "data": [item(&json!({}))],
        "next_cursor": "1731900000:0123456789abcdef0123456789abcdef",
        "unread_count": 100,
        "unread_count_capped": true
    }))
    .unwrap();
    assert_eq!(
        page.next_cursor.as_deref(),
        Some("1731900000:0123456789abcdef0123456789abcdef")
    );
    assert_eq!((page.unread_count, page.unread_count_capped), (100, true));
    let item = &page.items[0];
    assert!(item.is_unread() && item.is_open());
    assert_eq!(item.created_at, 1_731_900_000);
    // One link per target, in order; unsafe references are dropped.
    let targets: Vec<_> = item.links.iter().map(|link| link.target.clone()).collect();
    assert_eq!(
        targets,
        [
            Some(InboxLinkTarget::Web(
                "https://example.com/org/repo/pull/7".into()
            )),
            Some(InboxLinkTarget::Session(
                "fedcba9876543210fedcba9876543210".into()
            )),
        ]
    );
    assert_eq!(item.links[0].title(), "PR 7");
    assert_eq!(item.links[1].title(), "Open session");
    assert_eq!(item.actions.len(), 1);
    assert_eq!(item.actions[0].prompt, "Fix the flaky test");
    assert_eq!(item.charts.len(), 1);
    let chart = &item.charts[0];
    assert!(!chart.is_bar);
    assert_eq!(chart.unit.as_deref(), Some("%"));
    assert_eq!(chart.series[0].values, [Some(1.0), None]);
    assert_eq!(chart.highlight, Some(("Mon".into(), "Tue".into())));
    assert_eq!(chart.markers, [("Tue".into(), "deploy".into())]);
    assert_eq!(
        chart.source,
        Some(("CI".into(), Some("https://example.com/ci".into())))
    );
}

#[test]
fn a_chart_this_client_cannot_draw_is_dropped() {
    let bad_charts = [
        json!({"version": 1, "type": "pie", "title": "t", "x": ["a"], "series": [{"name": "s", "values": [1]}]}),
        json!({"version": 1, "type": "bar", "title": " ", "x": ["a"], "series": [{"name": "s", "values": [1]}]}),
        json!({"version": 1, "type": "bar", "title": "t", "x": ["a"], "series": [{"name": "s", "values": [1, 2]}]}),
        json!({"version": 1, "type": "bar", "title": "t", "x": ["a"], "series": [{"name": "s", "values": [1]}], "highlight": {"from": "a", "to": "z"}}),
        json!({"version": 1, "type": "bar", "title": "t", "x": ["a"], "series": [{"name": "s", "values": [1]}], "unit": 3}),
        json!({"version": 1, "type": "bar", "title": "t", "x": [], "series": [{"name": "s", "values": []}]}),
    ];
    for chart in bad_charts {
        let page = AgentInboxPage::from_value(&json!({
            "data": [item(&json!({"media": [{"type": "chart", "chart": chart}]}))],
            "next_cursor": null, "unread_count": 0, "unread_count_capped": false
        }))
        .unwrap();
        assert!(page.items[0].charts.is_empty(), "{chart}");
    }
}

#[test]
fn a_malformed_page_is_an_error() {
    assert!(AgentInboxPage::from_value(&json!({"data": [{"id": 1}]})).is_err());
    assert!(AgentInboxPage::from_value(&json!({"next_cursor": null})).is_err());
}

#[test]
fn list_asks_for_open_items_and_follows_the_cursor() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        "/v1/inbox/items",
        json!({"data": [item(&json!({}))], "next_cursor": null, "unread_count": 1,
               "unread_count_capped": false})
        .to_string(),
    );
    let page = block_on(core.agent_inbox_items(Some("5:abc"))).unwrap();
    assert_eq!(page.items.len(), 1);
    let request = core.transport().taken().pop().unwrap();
    assert_eq!(path_of(&request), "/v1/inbox/items");
    assert_eq!(query_value(&request, "limit").as_deref(), Some("50"));
    assert_eq!(query_value(&request, "after").as_deref(), Some("5:abc"));
    let url = url::Url::parse(&request.url).unwrap();
    let statuses: Vec<_> = url
        .query_pairs()
        .filter(|(key, _)| key == "status")
        .map(|(_, value)| value.into_owned())
        .collect();
    assert_eq!(statuses, ["unread", "read"]);
}

#[test]
fn reads_and_resolutions_patch_the_item_and_return_the_counts() {
    let core = connected(RouteTransport::local());
    let path = format!("/v1/inbox/items/{ITEM_ID}");
    let mut answer = item(&json!({"status": "read"}));
    answer["unread_count"] = json!(4);
    answer["unread_count_capped"] = json!(false);
    core.transport().ok(&path, answer.to_string());
    let update = block_on(core.mark_agent_inbox_item(ITEM_ID, true)).unwrap();
    assert_eq!(update.item.status, "read");
    assert_eq!(update.unread_count, 4);
    block_on(core.resolve_agent_inbox_item(ITEM_ID, InboxResolution::ActionTaken(0))).unwrap();
    block_on(core.resolve_agent_inbox_item(ITEM_ID, InboxResolution::NotNow)).unwrap();
    assert!(
        core.transport()
            .writes()
            .iter()
            .all(|request| request.method == "PATCH")
    );
    assert_eq!(
        core.transport().write_bodies(),
        [
            json!({"status": "read"}),
            json!({"resolution": "action_taken", "resolution_action": 0}),
            json!({"resolution": "not_now"}),
        ]
    );

    assert!(matches!(
        block_on(core.mark_agent_inbox_item("../x", true)),
        Err(SessionError::InvalidIdentifier { .. })
    ));
    core.transport().respond(
        Some("PATCH"),
        &path,
        None,
        Reply::json(
            404,
            r#"{"error":{"code":"not_found","message":"Inbox item not found"}}"#,
        ),
    );
    assert!(matches!(
        block_on(core.mark_agent_inbox_item(ITEM_ID, false)),
        Err(SessionError::Rejected { status: 404, .. })
    ));
}

#[test]
fn dismiss_reasons_are_the_webs_in_order() {
    let reasons: Vec<_> = InboxResolution::DISMISS_REASONS
        .iter()
        .map(|reason| (reason.label(), reason.wire()))
        .collect();
    assert_eq!(
        reasons,
        [
            ("Already done", "already_done"),
            ("Useful, no action needed", "useful"),
            ("Not relevant", "not_relevant"),
            ("Incorrect", "incorrect"),
            ("Not now", "not_now"),
        ]
    );
}

#[test]
fn previews_and_labels_follow_the_web() {
    assert_eq!(inbox_item_preview("\n\n## Heading\nbody"), "Heading");
    assert_eq!(inbox_item_preview("> quoted"), "quoted");
    assert_eq!(inbox_item_preview("12. step"), "step");
    assert_eq!(inbox_item_preview("- * item"), "* item");
    assert_eq!(inbox_item_preview("   "), "");
    let long = "x".repeat(250);
    let preview = inbox_item_preview(&long);
    assert_eq!(preview.chars().count(), 200);
    assert!(preview.ends_with('\u{2026}'));
    assert_eq!(inbox_item_kind_label("followup"), "Suggested follow-up");
    assert_eq!(inbox_item_kind_label("reminder"), "Reminder");
    assert_eq!(inbox_item_kind_label("info"), "For your information");
    assert_eq!(inbox_item_kind_label("new-kind"), "For your information");
}

#[test]
fn only_plain_web_links_are_safe() {
    assert_eq!(
        safe_web_link(" https://example.com/a ").as_deref(),
        Some("https://example.com/a")
    );
    assert!(safe_web_link("HTTP://example.com").is_some());
    assert!(safe_web_link("ftp://example.com").is_none());
    assert!(safe_web_link("https://user@example.com").is_none());
    assert!(safe_web_link("example.com").is_none());
}


#[test]
fn automation_failures_decode_with_the_webs_reasons() {
    let page = AutomationFailurePage::from_value(&json!({
        "data": [
            {"task_id": "t1", "task_name": "Nightly", "run_id": "r1", "scheduled_at": 10,
             "finished_at": 20, "error_code": "host_offline"},
            {"task_id": "t2", "task_name": "Weekly", "run_id": "r2", "scheduled_at": 30,
             "finished_at": null, "error_code": null}
        ],
        "next_cursor": "5:t2"
    }))
    .unwrap();
    assert_eq!(page.next_cursor.as_deref(), Some("5:t2"));
    assert_eq!(
        page.failures[0].reason(),
        "Host \u{00B7} The host was offline."
    );
    assert_eq!(page.failures[0].at(), 20);
    assert_eq!(page.failures[1].reason(), "Run failed.");
    assert_eq!(page.failures[1].at(), 30);

    // A page can be empty and still continue.
    let empty =
        AutomationFailurePage::from_value(&json!({"data": [], "next_cursor": "9:t9"})).unwrap();
    assert!(empty.failures.is_empty() && empty.next_cursor.is_some());
}

#[test]
fn automation_failures_page_by_cursor() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        "/v1/scheduled-tasks/inbox",
        r#"{"data":[],"next_cursor":null}"#,
    );
    let page = block_on(core.automation_failures(Some("5:t2"))).unwrap();
    assert!(page.failures.is_empty() && page.next_cursor.is_none());
    let request = core.transport().taken().pop().unwrap();
    assert_eq!(query_value(&request, "limit").as_deref(), Some("50"));
    assert_eq!(query_value(&request, "after").as_deref(), Some("5:t2"));

    core.transport().ok("/v1/scheduled-tasks/inbox", r#"{"data":7}"#);
    assert!(matches!(
        block_on(core.automation_failures(None)),
        Err(SessionError::MalformedResponse { .. })
    ));
}
