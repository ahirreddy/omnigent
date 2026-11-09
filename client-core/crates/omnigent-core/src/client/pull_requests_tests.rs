//! The right panel's server reads: stored pull requests and the panel features.

use futures::executor::block_on;

use super::SessionError;
use super::pull_requests::{PanelFeatures, PullRequestStatus};
use super::test_support::{Reply, RouteTransport, connected, query_value};

const PATH: &str = "/v1/sessions/conv_a/pull-requests";

#[test]
fn panel_features_read_info_and_default_to_unsupported() {
    let core = connected(RouteTransport::local());
    core.transport().enqueue(
        "GET",
        "/v1/info",
        vec![
            Reply::json(
                200,
                r#"{"session_pull_requests":true,"features":{"workspace_content_search":true}}"#,
            ),
            Reply::json(200, r#"{"single_user":true}"#),
            Reply::json(200, r#"{"features":"on"}"#),
        ],
    );
    assert_eq!(
        block_on(core.panel_features()),
        Ok(PanelFeatures {
            content_search: true,
            pull_requests: true
        })
    );
    assert_eq!(
        block_on(core.panel_features()),
        Ok(PanelFeatures::default())
    );
    assert!(matches!(
        block_on(core.panel_features()),
        Err(SessionError::MalformedResponse { .. })
    ));
}

#[test]
fn session_pull_requests_page_through_the_list_and_map_states() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("GET"),
        PATH,
        None,
        Reply::json(
            200,
            r#"{"object":"list","data":[
                {"url":"https://github.com/o/r/pull/1","host":"github.com","repository":"o/r",
                 "number":1,"title":"Fix login","relationship":"created","provider":"github",
                 "provider_display":{"display_name":"GitHub"},"state":"OPEN","is_draft":true,
                 "state_checked_at":1700000000.5,"first_seen_at":1,"last_seen_at":2}],
              "last_id":"https://github.com/o/r/pull/1","has_more":true,"synced":false}"#,
        ),
    );
    transport.respond(
        Some("GET"),
        PATH,
        Some("https://github.com/o/r/pull/1"),
        Reply::json(
            200,
            r#"{"object":"list","data":[
                {"url":"https://github.com/o/r/pull/2","host":"github.com","repository":"o/r",
                 "number":2,"title":" ","relationship":"inferred","state":"MERGED"},
                {"url":"https://github.com/o/r/pull/3","host":"github.com","repository":"o/r",
                 "number":3,"relationship":"attached","state":null}],
              "last_id":"https://github.com/o/r/pull/3","has_more":false,"synced":true}"#,
        ),
    );
    let core = connected(transport);
    let list = block_on(core.session_pull_requests("conv_a")).unwrap();
    assert!(list.synced);
    let first = &list.pull_requests[0];
    assert_eq!(first.number, 1);
    assert_eq!(first.title.as_deref(), Some("Fix login"));
    assert_eq!(first.provider_name.as_deref(), Some("GitHub"));
    assert_eq!(first.status, PullRequestStatus::Draft);
    assert_eq!(first.state_checked_at, Some(1_700_000_000.5));
    assert_eq!(
        list.pull_requests[1].title, None,
        "a blank title is no title"
    );
    assert_eq!(list.pull_requests[1].status, PullRequestStatus::Merged);
    assert_eq!(list.pull_requests[2].status, PullRequestStatus::Unknown);
    let requests = core.transport().taken();
    let reads: Vec<_> = requests.iter().filter(|r| r.url.contains(PATH)).collect();
    assert_eq!(reads.len(), 2);
    assert_eq!(query_value(reads[0], "limit").as_deref(), Some("100"));
    assert_eq!(
        query_value(reads[1], "after").as_deref(),
        Some("https://github.com/o/r/pull/1")
    );
}

#[test]
fn session_pull_requests_refuse_a_stuck_cursor_bad_ids_and_bad_rows() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "GET",
        PATH,
        vec![
            Reply::json(200, r#"{"data":[],"has_more":true,"last_id":null}"#),
            Reply::json(200, r#"{"data":[{"url":"u","repository":"o/r"}]}"#),
            Reply::json(404, r#"{"detail":"Not Found"}"#),
        ],
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.session_pull_requests("conv_a")),
        Err(SessionError::InvalidPagination)
    );
    assert!(matches!(
        block_on(core.session_pull_requests("conv_a")),
        Err(SessionError::MalformedResponse { .. })
    ));
    assert_eq!(
        block_on(core.session_pull_requests("conv_a")),
        Err(SessionError::HttpStatus { status: 404 })
    );
    assert!(matches!(
        block_on(core.session_pull_requests("../x")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
}

#[test]
fn pull_request_status_follows_the_provider_state() {
    assert_eq!(
        PullRequestStatus::of(Some("open"), false),
        PullRequestStatus::Open
    );
    assert_eq!(
        PullRequestStatus::of(Some("CLOSED"), true),
        PullRequestStatus::Closed
    );
    assert_eq!(
        PullRequestStatus::of(Some("LOCKED"), false),
        PullRequestStatus::Unknown
    );
    assert_eq!(
        PullRequestStatus::of(None, false),
        PullRequestStatus::Unknown
    );
}

#[test]
fn a_server_that_never_finishes_paging_stops_after_the_page_limit() {
    let core = connected(RouteTransport::local());
    let pages = (0..25)
        .map(|page| {
            Reply::json(
                200,
                format!(r#"{{"data":[],"has_more":true,"last_id":"pr_{page}"}}"#),
            )
        })
        .collect();
    core.transport().enqueue("GET", PATH, pages);
    assert_eq!(
        block_on(core.session_pull_requests("conv_a")),
        Err(SessionError::InvalidPagination)
    );
}
