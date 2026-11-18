//! The poll intervals, case by case as the web's `usePullRequests.test.ts` pins them.

use serde_json::{Value, json};

use super::PullRequestInfo;
use super::polling::{
    PULL_REQUEST_LIST_POLL_MS, PULL_REQUEST_POLL_MS, PULL_REQUEST_TRACKING_POLL_MS,
    PullRequestPolling, host_offline_retry_delay_ms, linked_poll_ms,
};
use crate::client::pull_requests::PullRequestStatus;

const FAST: Option<u64> = Some(PULL_REQUEST_POLL_MS);
/// The linked rows' states, the selected PR's state, and the interval they poll at.
type LinkedCase<'a> = (&'a [Option<&'a str>], Option<&'a str>, Option<u64>);
const LIST: Option<u64> = Some(PULL_REQUEST_LIST_POLL_MS);

/// A set-up session with an open PR whose two checks passed (the web test's `ready()`).
fn ready() -> Value {
    json!({
        "object": "session.github.info",
        "available": true,
        "gh_available": true,
        "authenticated": true,
        "branch": "feature",
        "repo": {"name_with_owner": "o/r"},
        "base_ref": "main",
        "pr": {
            "number": 1, "title": "t", "state": "OPEN", "url": "u", "is_draft": false,
            "author": null, "base_ref": "main", "head_ref": "feature",
            "checks": {"passing": 2, "failing": 0, "pending": 0, "total": 2, "runs": []}
        }
    })
}

fn with(mut body: Value, edit: impl FnOnce(&mut Value)) -> Value {
    edit(&mut body);
    body
}

fn polling(body: &Value) -> PullRequestPolling {
    PullRequestInfo::from_value(body).unwrap().polling
}

fn panel(body: &Value) -> Option<u64> {
    polling(body).panel_ms
}

#[test]
fn list_rows_refresh_slowly_and_rest_once_closed_or_merged() {
    assert_eq!(PullRequestPolling::WITHOUT_INFO.list_ms, LIST);
    assert_eq!(polling(&ready()).list_ms, LIST);
    for state in ["CLOSED", "MERGED"] {
        let settled = with(ready(), |body| body["pr"]["state"] = json!(state));
        assert_eq!(polling(&settled).list_ms, None, "{state}");
    }
}

#[test]
fn the_panel_polls_setup_states_the_user_fixes_outside_the_app() {
    assert_eq!(PullRequestPolling::WITHOUT_INFO.panel_ms, FAST);
    let edits: [fn(&mut Value); 5] = [
        |body| body["available"] = json!(false),
        |body| body["gh_available"] = json!(false),
        |body| body["authenticated"] = json!(false),
        |body| body["repo"] = Value::Null,
        |body| body["repo"] = json!({"name_with_owner": null}),
    ];
    for edit in edits {
        let body = with(ready(), |body| {
            body["pr"] = Value::Null;
            edit(body);
        });
        assert_eq!(panel(&body), FAST, "{body}");
    }
    assert_eq!(PullRequestInfo::not_found("x").polling.panel_ms, FAST);
}

#[test]
fn the_panel_polls_while_waiting_for_a_pr_and_while_checks_are_unsettled() {
    assert_eq!(panel(&with(ready(), |body| body["pr"] = Value::Null)), FAST);
    let running = with(ready(), |body| {
        body["pr"]["checks"] = json!({"passing": 0, "failing": 0, "pending": 1, "total": 1});
    });
    assert_eq!(panel(&running), FAST);
    let unregistered = with(ready(), |body| {
        body["pr"]["checks"] = json!({"passing": 0, "failing": 0, "pending": 0, "total": 0});
    });
    assert_eq!(panel(&unregistered), FAST);
}

#[test]
fn the_sign_in_state_comes_from_auth_else_the_legacy_fields() {
    let auth = |authenticated: bool, cli: bool| {
        with(ready(), |body| {
            body["auth"] = json!({"authenticated": authenticated, "hint": null,
                "cli": {"name": "forge", "available": cli}, "accounts": null,
                "selected_account": null});
        })
    };
    assert_eq!(panel(&auth(false, false)), FAST);
    assert_eq!(panel(&auth(false, true)), FAST);
    assert_eq!(panel(&auth(true, true)), None);
    assert_eq!(
        panel(&auth(true, false)),
        None,
        "a token signs in without the CLI"
    );
    assert_eq!(
        panel(&with(ready(), |body| body["gh_available"] = json!(false))),
        FAST
    );
}

#[test]
fn incomplete_results_keep_polling_even_when_settled() {
    let merged = || with(ready(), |body| body["pr"]["state"] = json!("MERGED"));
    let edits: [fn(&mut Value); 3] = [
        |body| body["warnings"] = json!(["Lookup failed."]),
        |body| body["pr"]["checks"]["partial"] = json!(true),
        |body| body["pr"]["comments_partial"] = json!(true),
    ];
    for edit in edits {
        assert_eq!(panel(&with(merged(), edit)), FAST);
    }
    let discovery = with(merged(), |body| {
        body["discovery_warnings"] = json!(["gitlab down"]);
    });
    assert_eq!(
        panel(&discovery),
        None,
        "other remotes' warnings don't count"
    );
}

#[test]
fn the_panel_rests_once_nothing_is_left_to_watch() {
    assert_eq!(panel(&ready()), None);
    for state in ["MERGED", "CLOSED"] {
        assert_eq!(
            panel(&with(ready(), |body| body["pr"]["state"] = json!(state))),
            None
        );
    }
    for state in ["OPEN", "MERGED", "CLOSED"] {
        let body = with(ready(), |body| {
            body["pr"]["state"] = json!(state);
            body["pr"]["timeline_partial"] = json!(true);
        });
        assert_eq!(panel(&body), None, "{state}");
    }
    let draft = with(ready(), |body| {
        body["pr"]["is_draft"] = json!(true);
        body["pr"]["checks"]["pending"] = json!(1);
    });
    assert_eq!(panel(&draft), FAST, "a draft is open");
}

#[test]
fn a_host_that_links_prs_polls_the_open_panel_every_ten_seconds() {
    let tracking = with(ready(), |body| body["tracking_available"] = json!(true));
    assert_eq!(panel(&tracking), Some(PULL_REQUEST_TRACKING_POLL_MS));
    let merged = with(tracking, |body| body["pr"]["state"] = json!("MERGED"));
    assert_eq!(panel(&merged), Some(PULL_REQUEST_TRACKING_POLL_MS));
}

#[test]
fn linked_prs_poll_until_every_known_state_is_settled() {
    assert_eq!(PullRequestPolling::WITHOUT_INFO.linked_ms, None);
    let cases: [LinkedCase<'_>; 9] = [
        (&[], None, None),
        (&[Some("MERGED"), Some("closed")], None, None),
        (&[], Some("MERGED"), None),
        (&[Some("OPEN")], Some("CLOSED"), None),
        (&[Some("MERGED"), Some("OPEN")], None, LIST),
        (&[Some("CLOSED"), Some("UNKNOWN")], None, LIST),
        (&[None], None, LIST),
        (&[Some("CLOSED")], Some("UNKNOWN"), LIST),
        (&[Some("CLOSED"), Some("OPEN")], Some("MERGED"), LIST),
    ];
    for (states, selected, expected) in cases {
        let rows: Vec<Value> = states
            .iter()
            .enumerate()
            .map(|(index, state)| {
                json!({"url": format!("pr-{index}"), "host": "github.com",
                    "repository": "org/repo", "number": index + 1,
                    "relationship": "attached", "state": state})
            })
            .collect();
        let body = with(ready(), |body| {
            body["prs"] = Value::Array(rows);
            body["pr"] = selected.map_or(Value::Null, |state| {
                json!({"number": 1, "title": "t", "state": state, "url": "pr-0",
                    "checks": {"passing": 0, "failing": 0, "pending": 0, "total": 0}})
            });
        });
        assert_eq!(
            polling(&body).linked_ms,
            expected,
            "{states:?} with {selected:?}"
        );
    }
    assert_eq!(linked_poll_ms([PullRequestStatus::Merged]), None);
    assert_eq!(
        linked_poll_ms([PullRequestStatus::Closed, PullRequestStatus::Draft]),
        LIST
    );
}

#[test]
fn host_offline_retries_back_off_to_fifteen_seconds_then_rest() {
    let delays: Vec<_> = (0..14).map(host_offline_retry_delay_ms).collect();
    assert_eq!(
        delays,
        [
            Some(1_000),
            Some(2_000),
            Some(4_000),
            Some(8_000),
            Some(15_000),
            Some(15_000),
            Some(15_000),
            Some(15_000),
            Some(15_000),
            Some(15_000),
            Some(15_000),
            Some(15_000),
            Some(15_000),
            None,
        ]
    );
    assert_eq!(host_offline_retry_delay_ms(u32::MAX), None);
}
