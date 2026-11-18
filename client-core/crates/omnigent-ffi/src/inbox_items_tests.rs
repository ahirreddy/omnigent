//! Agent-posted Inbox items and automation failures over the fake host.

use serde_json::json;

use crate::inbox_items::{InboxDismissReason, InboxLinkRecord, inbox_dismiss_options};
use crate::test_support::{connected, json as reply};

const ITEM_ID: &str = "0123456789abcdef0123456789abcdef";

fn item_json(status: &str) -> serde_json::Value {
    json!({
        "id": ITEM_ID, "user_id": "ada", "source_session_id": "fedcba9876543210fedcba9876543210",
        "agent_id": "agent-1", "kind": "reminder", "title": "Renew the cert",
        "body_md": "- It expires Friday.\nMore detail.",
        "links": [{"type": "session", "ref": "fedcba9876543210fedcba9876543210", "label": "Run"},
                  {"type": "url", "ref": "https://example.com/cert"}],
        "actions": [{"label": "Renew", "prompt": "Renew the cert"}],
        "media": [{"type": "chart", "chart": {"version": 1, "type": "bar", "title": "Days left",
            "x": ["a", "b"], "series": [{"name": "days", "values": [3, 2]}],
            "source": {"label": "Ops"}}}],
        "primary_link": null, "topic": "cert", "dedupe_key": "v1:x", "status": status,
        "resolution": "none", "feedback_text": null, "created_at": 42, "resolved_at": null,
        "expires_at": null, "resolution_action": null
    })
}

#[test]
fn items_map_labels_previews_links_and_charts() {
    let mut harness = connected();
    harness.http.route(
        "/v1/inbox/items",
        reply(
            200,
            &json!({"data": [item_json("unread")], "next_cursor": null, "unread_count": 3,
                    "unread_count_capped": false})
            .to_string(),
        ),
    );
    let page = harness
        .call(|core| async move { core.agent_inbox_items(None).await })
        .unwrap();
    assert_eq!(page.unread_count, 3);
    let item = &page.items[0];
    assert_eq!(item.kind_label, "Reminder");
    assert_eq!(item.preview, "It expires Friday.");
    assert!(item.is_unread && item.is_open);
    assert_eq!(
        item.links,
        [
            InboxLinkRecord {
                title: "Run".into(),
                session_id: Some("fedcba9876543210fedcba9876543210".into()),
                web_url: None,
            },
            InboxLinkRecord {
                title: "https://example.com/cert".into(),
                session_id: None,
                web_url: Some("https://example.com/cert".into()),
            },
        ]
    );
    let chart = &item.charts[0];
    assert!(chart.is_bar);
    assert_eq!(chart.series[0].values, [Some(3.0), Some(2.0)]);
    assert_eq!(chart.source_label.as_deref(), Some("Ops"));
    assert_eq!(chart.source_url, None);
}

#[test]
fn reads_actions_and_dismissals_patch_the_item() {
    let mut harness = connected();
    let path = format!("/v1/inbox/items/{ITEM_ID}");
    let mut answer = item_json("done");
    answer["unread_count"] = json!(0);
    answer["unread_count_capped"] = json!(false);
    harness.http.route(&path, reply(200, &answer.to_string()));
    let read = harness
        .call(|core| async move { core.mark_agent_inbox_item(ITEM_ID.into(), true).await })
        .unwrap();
    assert!(!read.item.is_open);
    assert_eq!(harness.last_request().1, json!({"status": "read"}));
    harness
        .call(|core| async move { core.take_agent_inbox_action(ITEM_ID.into(), 0).await })
        .unwrap();
    assert_eq!(
        harness.last_request(),
        (
            format!("PATCH {path}"),
            json!({"resolution": "action_taken", "resolution_action": 0})
        )
    );
    harness
        .call(|core| async move {
            core.dismiss_agent_inbox_item(ITEM_ID.into(), InboxDismissReason::Useful)
                .await
        })
        .unwrap();
    assert_eq!(harness.last_request().1, json!({"resolution": "useful"}));
}

#[test]
fn the_dismiss_menu_follows_the_web() {
    let labels: Vec<_> = inbox_dismiss_options()
        .into_iter()
        .map(|option| option.label)
        .collect();
    assert_eq!(
        labels,
        [
            "Already done",
            "Useful, no action needed",
            "Not relevant",
            "Incorrect",
            "Not now"
        ]
    );
}

#[test]
fn automation_failures_carry_the_reason_and_time() {
    let mut harness = connected();
    harness.http.route(
        "/v1/scheduled-tasks/inbox",
        reply(
            200,
            r#"{"data":[{"task_id":"t1","task_name":"Nightly","run_id":"r1","scheduled_at":10,
                "finished_at":null,"error_code":"no_online_host"}],"next_cursor":"1:t1"}"#,
        ),
    );
    let page = harness
        .call(|core| async move { core.automation_failures(None).await })
        .unwrap();
    assert_eq!(page.next_cursor.as_deref(), Some("1:t1"));
    let failure = &page.failures[0];
    assert_eq!(failure.reason, "Host \u{00B7} None of your hosts was online.");
    assert_eq!(failure.at, 10);
}
