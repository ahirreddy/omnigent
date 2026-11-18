//! The Tasks tab's journal reads, against pages in the server's shape.

use futures::executor::block_on;

use super::SessionError;
use super::test_support::{Reply, RouteTransport, connected, query_value};

const PATH: &str = "/v1/sessions/conv_a/journal";

fn page(entries: &str, last: Option<&str>, has_more: bool) -> Reply {
    let last = last.map_or_else(|| "null".to_owned(), |id| format!("\"{id}\""));
    Reply::json(
        200,
        format!(
            r#"{{"object":"list","data":[{entries}],"first_id":null,"last_id":{last},"has_more":{has_more}}}"#
        ),
    )
}

fn entry(id: &str, position: i64, kind: &str, step: Option<&str>, content: &str) -> String {
    let step = step.map_or_else(|| "null".to_owned(), |step| format!("\"{step}\""));
    format!(
        r#"{{"id":"{id}","position":{position},"created_at":{},"scheduled_task_run_id":null,"step":{step},"author":{{"type":"agent"}},"kind":"{kind}","content":{content},"workflow_id":null}}"#,
        1_795_080_000 + position
    )
}

#[test]
fn a_short_journal_is_one_page_and_its_run_boundary() {
    let core = connected(RouteTransport::local());
    let plan = entry(
        "p",
        0,
        "plan",
        None,
        r#"{"version":1,"name":"Ship","steps":[{"id":"a","name":"A","depends_on":[]}]}"#,
    );
    let status = entry("s", 1, "status", Some("a"), r#"{"status":"started"}"#);
    core.transport().enqueue(
        "GET",
        PATH,
        vec![
            page(&format!("{status},{plan}"), Some("p"), false),
            page("", None, false),
        ],
    );
    let entries = block_on(core.session_journal("conv_a")).unwrap();
    let ids: Vec<&str> = entries.iter().map(|entry| entry.id.as_str()).collect();
    assert_eq!(ids, ["p", "s"]);
    let sent = core.transport().taken();
    let reads: Vec<(Option<String>, Option<String>, Option<String>)> = sent
        .iter()
        .filter(|request| request.url.contains("/journal"))
        .map(|request| {
            (
                query_value(request, "order"),
                query_value(request, "limit"),
                query_value(request, "kind"),
            )
        })
        .collect();
    assert_eq!(
        reads,
        [
            (Some("desc".into()), Some("100".into()), None),
            (
                Some("desc".into()),
                Some("1".into()),
                Some("plan_status".into())
            ),
        ]
    );
}

#[test]
fn with_older_pages_the_plan_and_each_steps_newest_status_are_read() {
    let core = connected(RouteTransport::local());
    let plan = entry(
        "p",
        0,
        "plan",
        None,
        r#"{"version":1,"name":"Ship","steps":[{"id":"a","name":"A","depends_on":[]},{"id":"b","name":"B","depends_on":["a"]}]}"#,
    );
    let newest = entry("n", 300, "note", None, r#"{"body":"busy"}"#);
    let a_done = entry("sa", 3, "status", Some("a"), r#"{"status":"done"}"#);
    let boundary = r#"{"id":"r","position":1,"created_at":1,"scheduled_task_run_id":null,"step":null,"author":{"type":"omnigent"},"kind":"plan_status","content":{"status":"started"},"workflow_id":"wf_1"}"#;
    core.transport().enqueue(
        "GET",
        PATH,
        vec![
            page(&newest, Some("n"), true),
            page(&plan, Some("p"), true),
            page(&a_done, Some("sa"), false),
            page("", None, false),
            page(boundary, Some("r"), false),
            page(&plan, Some("p"), false),
        ],
    );
    let entries = block_on(core.session_journal("conv_a")).unwrap();
    let ids: Vec<&str> = entries.iter().map(|entry| entry.id.as_str()).collect();
    assert_eq!(
        ids,
        ["p", "r", "sa", "n"],
        "merged in position order, without repeats"
    );
    let sent = core.transport().taken();
    let queries: Vec<(Option<String>, Option<String>, Option<String>)> = sent
        .iter()
        .filter(|request| request.url.contains("/journal"))
        .map(|request| {
            (
                query_value(request, "kind"),
                query_value(request, "step"),
                query_value(request, "after"),
            )
        })
        .collect();
    assert_eq!(
        queries,
        [
            (None, None, None),
            (Some("plan".into()), None, None),
            (Some("status".into()), Some("a".into()), None),
            (Some("status".into()), Some("b".into()), None),
            (Some("plan_status".into()), None, None),
            (Some("plan".into()), None, Some("r".into())),
        ]
    );
}

#[test]
fn a_catch_up_reads_forward_and_gives_up_after_five_pages() {
    let core = connected(RouteTransport::local());
    let one = entry("e1", 1, "note", None, r#"{"body":"x"}"#);
    let two = entry("e2", 2, "note", None, r#"{"body":"y"}"#);
    core.transport().enqueue(
        "GET",
        PATH,
        vec![page(&one, Some("e1"), true), page(&two, Some("e2"), false)],
    );
    let caught = block_on(core.session_journal_since("conv_a", "e0"))
        .unwrap()
        .unwrap();
    assert_eq!(caught.len(), 2);
    let afters: Vec<Option<String>> = core
        .transport()
        .taken()
        .iter()
        .filter(|request| request.url.contains("/journal"))
        .map(|request| query_value(request, "after"))
        .collect();
    assert_eq!(afters, [Some("e0".into()), Some("e1".into())]);
    core.transport().enqueue(
        "GET",
        PATH,
        (0..5).map(|_| page(&one, Some("e1"), true)).collect(),
    );
    assert_eq!(
        block_on(core.session_journal_since("conv_a", "e0")),
        Ok(None)
    );
}

#[test]
fn a_server_without_journals_and_a_bad_page_are_errors() {
    let core = connected(RouteTransport::local());
    core.transport().enqueue(
        "GET",
        PATH,
        vec![
            Reply::json(404, r#"{"detail":"Not Found"}"#),
            Reply::json(200, r#"{"data":[{"id":"x"}]}"#),
        ],
    );
    assert!(block_on(core.session_journal("conv_a")).is_err());
    assert!(matches!(
        block_on(core.session_journal("conv_a")),
        Err(SessionError::MalformedResponse { .. })
    ));
    assert!(matches!(
        block_on(core.session_journal("../x")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}
