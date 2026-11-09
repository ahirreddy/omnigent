//! Replica routing over a Databricks workspace connection: the routing key on session requests,
//! the keyless re-address after `wrong_replica`, and learning an unknown session's host.

use futures::executor::block_on;

use super::test_support::{Reply, RouteTransport, core, header, path_of};
use super::{SLICE_KEY_HEADER, SessionError};
use crate::auth::SecretString;
use crate::auth::endpoint::ServerEndpoint;

const MOUNT: &str = "/api/2.0/omnigent";
const WORKSPACE: &str = "https://dbc-1.cloud.databricks.com/api/2.0/omnigent";
const WRONG_REPLICA: &str =
    r#"{"error":{"code":"wrong_replica","message":"host shell inventory is on another replica"}}"#;

fn workspace(transport: RouteTransport) -> super::ClientCore<RouteTransport> {
    let core = core(transport);
    block_on(core.connect(
        ServerEndpoint::new(WORKSPACE).unwrap(),
        Some(SecretString::new("token")),
        None,
    ))
    .unwrap();
    core
}

fn listed(transport: &RouteTransport) {
    transport.ok(
        &format!("{MOUNT}/v1/sessions"),
        r#"{"object":"list","data":[
            {"id":"conv_a","status":"idle","created_at":1,"host_id":"host_a"},
            {"id":"conv_b","status":"idle","created_at":2,"host_id":"host_a"}
        ],"has_more":false}"#,
    );
}

/// The routing key each request to `path` carried, in order.
fn keys(transport: &RouteTransport, path: &str) -> Vec<Option<String>> {
    transport
        .taken()
        .iter()
        .filter(|request| path_of(request) == path)
        .map(|request| header(request, SLICE_KEY_HEADER).map(str::to_owned))
        .collect()
}

#[test]
fn session_requests_carry_their_hosts_key_and_lists_the_modal_one() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    transport.ok(
        &format!("{MOUNT}/v1/sessions/conv_a/agent"),
        r#"{"terminals":["bash"]}"#,
    );
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();
    let terminals = block_on(core.declared_terminal_names("conv_a")).unwrap();
    assert_eq!(terminals, Some(vec!["bash".to_owned()]));
    block_on(core.sessions()).unwrap();

    let transport = &core.transport;
    assert_eq!(
        keys(transport, &format!("{MOUNT}/v1/sessions/conv_a/agent")),
        [Some("host_a".to_owned())]
    );
    assert_eq!(
        keys(transport, &format!("{MOUNT}/v1/sessions")),
        [None, Some("host_a".to_owned())],
        "the first list is unkeyed; later ones carry the modal host"
    );
    assert_eq!(
        core.slice_key("/v1/sessions/conv_b/stream").as_deref(),
        Some("host_a")
    );
    assert_eq!(core.modal_slice_key().as_deref(), Some("host_a"));
}

#[test]
fn a_wrong_replica_refusal_is_retried_keyless_and_the_host_remembered() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    let agent = format!("{MOUNT}/v1/sessions/conv_a/agent");
    transport.enqueue(
        "GET",
        &agent,
        vec![
            Reply::json(400, WRONG_REPLICA),
            Reply::json(200, r#"{"terminals":["bash"]}"#),
        ],
    );
    transport.ok(&agent, r#"{"terminals":["zsh"]}"#);
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();

    let first = block_on(core.declared_terminal_names("conv_a")).unwrap();
    assert_eq!(
        first,
        Some(vec!["bash".to_owned()]),
        "the keyless retry answered"
    );
    let second = block_on(core.declared_terminal_names("conv_a")).unwrap();
    assert_eq!(second, Some(vec!["zsh".to_owned()]));
    assert_eq!(
        keys(&core.transport, &agent),
        [Some("host_a".to_owned()), None, None],
        "keyed, then keyless once, then keyless from the start"
    );
    assert_eq!(core.slice_key("/v1/sessions/conv_a/stream"), None);
}

#[test]
fn an_unknown_sessions_host_is_learned_from_its_snapshot() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    let agent = format!("{MOUNT}/v1/sessions/conv_new/agent");
    transport.enqueue(
        "GET",
        &agent,
        vec![
            Reply::json(400, WRONG_REPLICA),
            Reply::json(200, r#"{"terminals":["bash"]}"#),
        ],
    );
    transport.ok(
        &format!("{MOUNT}/v1/sessions/conv_new"),
        r#"{"id":"conv_new","status":"idle","created_at":3,"host_id":"host_n"}"#,
    );
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();

    let terminals = block_on(core.declared_terminal_names("conv_new")).unwrap();
    assert_eq!(terminals, Some(vec!["bash".to_owned()]));
    assert_eq!(
        keys(&core.transport, &agent),
        [None, Some("host_n".to_owned())],
        "unkeyed (host unknown), then keyed with the snapshot's host"
    );
}

#[test]
fn other_refusals_and_other_servers_are_not_rerouted() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    let agent = format!("{MOUNT}/v1/sessions/conv_a/agent");
    transport.respond(
        None,
        &agent,
        None,
        Reply::json(400, r#"{"error":{"code":"runner_unavailable"}}"#),
    );
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();
    let result = block_on(core.declared_terminal_names("conv_a"));
    assert!(
        matches!(result, Err(SessionError::HttpStatus { status: 400 })),
        "{result:?}"
    );
    assert_eq!(keys(&core.transport, &agent).len(), 1, "not re-addressed");

    // A non-workspace server gets no key at all.
    let local = super::test_support::connected(RouteTransport::local());
    assert_eq!(local.slice_key("/v1/sessions/conv_a/stream"), None);
    assert_eq!(local.modal_slice_key(), None);
}

#[test]
fn a_sub_agents_host_is_its_nearest_host_bound_ancestors() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    let agent = format!("{MOUNT}/v1/sessions/conv_child/agent");
    transport.enqueue(
        "GET",
        &agent,
        vec![
            Reply::json(400, WRONG_REPLICA),
            Reply::json(200, r#"{"terminals":[]}"#),
        ],
    );
    transport.ok(
        &format!("{MOUNT}/v1/sessions/conv_child"),
        r#"{"id":"conv_child","status":"idle","created_at":3,"host_id":null,"parent_session_id":"conv_mid"}"#,
    );
    transport.ok(
        &format!("{MOUNT}/v1/sessions/conv_mid"),
        r#"{"id":"conv_mid","status":"idle","created_at":2,"parent_session_id":"conv_root"}"#,
    );
    transport.ok(
        &format!("{MOUNT}/v1/sessions/conv_root"),
        r#"{"id":"conv_root","status":"idle","created_at":1,"host_id":"host_r"}"#,
    );
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();

    block_on(core.declared_terminal_names("conv_child")).unwrap();
    assert_eq!(
        keys(&core.transport, &agent),
        [None, Some("host_r".to_owned())],
        "keyed with the root's host after walking the chain"
    );
}

#[test]
fn terminal_requests_are_routed_like_the_rest() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    let terminals = format!("{MOUNT}/v1/sessions/conv_a/resources/terminals");
    transport.enqueue(
        "GET",
        &terminals,
        vec![
            Reply::json(400, WRONG_REPLICA),
            Reply::json(200, r#"{"object":"list","data":[],"has_more":false}"#),
        ],
    );
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();
    let listed = block_on(core.list_terminals("conv_a")).unwrap();
    assert_eq!(listed.len(), 0, "{listed:?}");
    assert_eq!(
        keys(&core.transport, &terminals),
        [Some("host_a".to_owned()), None],
        "keyed by the session's host, then re-addressed keyless"
    );
}

#[test]
fn a_demoted_host_that_still_refuses_is_keyed_again_next_time() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    let agent = format!("{MOUNT}/v1/sessions/conv_a/agent");
    let terminals = Reply::json(200, r#"{"terminals":["bash"]}"#);
    transport.enqueue(
        "GET",
        &agent,
        vec![
            Reply::json(400, WRONG_REPLICA),
            terminals.clone(),
            Reply::json(400, WRONG_REPLICA),
            terminals,
        ],
    );
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();
    block_on(core.declared_terminal_names("conv_a")).unwrap();
    assert!(matches!(
        block_on(core.declared_terminal_names("conv_a")),
        Err(SessionError::HttpStatus { status: 400 } | SessionError::Rejected { status: 400, .. })
    ));
    block_on(core.declared_terminal_names("conv_a")).unwrap();
    assert_eq!(
        keys(&core.transport, &agent),
        [
            Some("host_a".to_owned()),
            None,
            None,
            Some("host_a".to_owned())
        ],
        "keyed, keyless retry, keyless and refused, keyed again"
    );
}

#[test]
fn a_refusal_with_nothing_to_learn_is_reported_as_is() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    let core = workspace(transport);
    // A route with no session of its own, before any list named a host.
    let info = format!("{MOUNT}/v1/connections/github/status");
    core.transport
        .respond(None, &info, None, Reply::json(400, WRONG_REPLICA));
    assert!(block_on(core.provider_connection("github")).is_err());
    assert_eq!(keys(&core.transport, &info), [None], "not re-addressed");
    block_on(core.sessions()).unwrap();

    // A session whose snapshot is unreadable, or names no host through a parent cycle.
    let agent = |id: &str| format!("{MOUNT}/v1/sessions/{id}/agent");
    for id in ["conv_gone", "conv_loop", "conv_none"] {
        core.transport
            .respond(None, &agent(id), None, Reply::json(400, WRONG_REPLICA));
    }
    core.transport.respond(
        None,
        &format!("{MOUNT}/v1/sessions/conv_gone"),
        None,
        Reply::json(404, "{}"),
    );
    core.transport.ok(
        &format!("{MOUNT}/v1/sessions/conv_loop"),
        r#"{"id":"conv_loop","status":"idle","created_at":1,"parent_session_id":"conv_loop_b"}"#,
    );
    core.transport.ok(
        &format!("{MOUNT}/v1/sessions/conv_loop_b"),
        r#"{"id":"conv_loop_b","status":"idle","created_at":1,"parent_session_id":"conv_loop"}"#,
    );
    core.transport.ok(
        &format!("{MOUNT}/v1/sessions/conv_none"),
        r#"{"id":"conv_none","status":"idle","created_at":1}"#,
    );
    for id in ["conv_gone", "conv_loop", "conv_none"] {
        assert!(block_on(core.declared_terminal_names(id)).is_err(), "{id}");
        assert_eq!(keys(&core.transport, &agent(id)), [None], "{id}");
    }
}

#[test]
fn a_refused_stream_flips_between_keyed_and_keyless() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    let core = workspace(transport);
    let stream = "/v1/sessions/conv_a/stream";
    core.stream_refused(stream, true);
    assert_eq!(core.slice_key(stream), None, "no host known yet");
    block_on(core.sessions()).unwrap();
    assert_eq!(core.slice_key(stream).as_deref(), Some("host_a"));
    assert_eq!(core.modal_slice_key().as_deref(), Some("host_a"));
    core.stream_refused(stream, true);
    assert_eq!(core.slice_key(stream), None);
    core.stream_refused(stream, false);
    assert_eq!(core.slice_key(stream).as_deref(), Some("host_a"));

    let local = super::test_support::connected(RouteTransport::local());
    local.stream_refused(stream, true);
    assert_eq!(local.slice_key(stream), None);
    assert_eq!(local.modal_slice_key(), None);
}
