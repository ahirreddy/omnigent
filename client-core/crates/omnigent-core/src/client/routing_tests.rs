//! Replica routing over a Databricks workspace connection: the routing key on session requests,
//! the keyless re-address after `wrong_replica`, and learning an unknown session's host.

use futures::executor::block_on;

use super::test_support::{Reply, RouteTransport, core, header, path_of, query_value};
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
fn an_unknown_sessions_host_is_looked_up_before_its_first_request() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    let agent = format!("{MOUNT}/v1/sessions/conv_new/agent");
    transport.ok(&agent, r#"{"terminals":["bash"]}"#);
    let snapshot = format!("{MOUNT}/v1/sessions/conv_new");
    transport.ok(
        &snapshot,
        r#"{"id":"conv_new","status":"idle","created_at":3,"host_id":"host_n"}"#,
    );
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();

    let terminals = block_on(core.declared_terminal_names("conv_new")).unwrap();
    assert_eq!(terminals, Some(vec!["bash".to_owned()]));
    assert_eq!(
        keys(&core.transport, &agent),
        [Some("host_n".to_owned())],
        "keyed with the snapshot's host on the first attempt"
    );
    let lookups: Vec<_> = core
        .transport
        .taken()
        .into_iter()
        .filter(|request| path_of(request) == snapshot)
        .collect();
    assert_eq!(lookups.len(), 1);
    for (name, value) in super::requests::ROUTING_SNAPSHOT_QUERY {
        assert_eq!(
            query_value(&lookups[0], name).as_deref(),
            Some(value),
            "{name}: only the routing fields are read"
        );
    }
    assert_eq!(header(&lookups[0], SLICE_KEY_HEADER), None);
}

#[test]
fn a_host_bound_after_an_empty_lookup_is_learned_from_the_refusal() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    let agent = format!("{MOUNT}/v1/sessions/conv_new/agent");
    transport.enqueue(
        "GET",
        &agent,
        vec![
            Reply::json(200, r#"{"terminals":[]}"#),
            Reply::json(400, WRONG_REPLICA),
            Reply::json(200, r#"{"terminals":["bash"]}"#),
        ],
    );
    // A managed session has no host until its sandbox binds.
    transport.enqueue(
        "GET",
        &format!("{MOUNT}/v1/sessions/conv_new"),
        vec![
            Reply::json(
                200,
                r#"{"id":"conv_new","status":"idle","created_at":3,"host_id":null}"#,
            ),
            Reply::json(
                200,
                r#"{"id":"conv_new","status":"idle","created_at":3,"host_id":"host_n"}"#,
            ),
        ],
    );
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();

    block_on(core.declared_terminal_names("conv_new")).unwrap();
    let terminals = block_on(core.declared_terminal_names("conv_new")).unwrap();
    assert_eq!(terminals, Some(vec!["bash".to_owned()]));
    assert_eq!(
        keys(&core.transport, &agent),
        [None, None, Some("host_n".to_owned())],
        "unkeyed after the empty lookup, unkeyed and refused, then keyed with the learned host"
    );
    assert_eq!(
        core.transport
            .taken()
            .iter()
            .filter(|request| path_of(request) == format!("{MOUNT}/v1/sessions/conv_new"))
            .count(),
        2,
        "the empty lookup is not repeated before the second request, only after its refusal"
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
    transport.ok(&agent, r#"{"terminals":[]}"#);
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
        [Some("host_r".to_owned())],
        "keyed with the root's host after walking the chain"
    );
}

/// What a replica without the runner's tunnel answers for a sub-agent's stream and files, and
/// the sub-agent's and a side chat's snapshots, as a two-replica server sent them.
const STREAM_ON_ANOTHER_REPLICA: &str =
    r#"{"error":{"code":"wrong_replica","message":"session runner is on another replica; retry"}}"#;
const FILES_ON_ANOTHER_REPLICA: &str = r#"{"error":{"code":"wrong_replica","message":"runner 'runner_1' is offline for conversation 'conv_child'"}}"#;
const SUB_AGENT_SNAPSHOT: &str = r#"{"id":"conv_child","agent_id":"ag_1","agent_name":"codex-native-parent","status":"idle","background_task_count":null,"background_tasks":null,"created_at":1794446599,"updated_at":1794446599,"title":"codex-native-ui-subagent:thr_worker_1","labels":{"omnigent.codex_native.agent_role":"worker","omnigent.wrapper":"codex-native-ui-subagent"},"runner_id":"runner_1","host_id":null,"runner_online":false,"host_online":null,"host_resumable":false,"items":[],"permission_level":null,"sub_agent_name":"Codex","kind":"sub_agent","parent_session_id":"conv_a","root_conversation_id":"conv_a","harness":"claude-sdk","pending_elicitations":[],"workspace":null,"archived":false,"todos":[],"model_options":[],"side_chat_parent_id":null}"#;
const SIDE_CHAT_SNAPSHOT: &str = r#"{"id":"conv_side","agent_id":"ag_1","agent_name":"codex-native-parent","status":"idle","created_at":1794446604,"updated_at":1794446604,"title":"Side chat","labels":{"omnigent.client_surface":"cli","omnigent.fork.source_id":"conv_a","omnigent.side_chat":"1","omnigent.side_chat.source_id":"conv_a","omnigent.wrapper":"codex-native-ui"},"runner_id":"runner_1","host_id":null,"runner_online":false,"host_online":null,"items":[],"sub_agent_name":null,"kind":"default","parent_session_id":null,"root_conversation_id":"conv_side","harness":"claude-sdk","pending_elicitations":[],"archived":false,"todos":[],"model_options":[],"side_chat_parent_id":"conv_a"}"#;

fn changes(session: &str) -> String {
    format!("{MOUNT}/v1/sessions/{session}/resources/environments/default/changes")
}

#[test]
fn a_sub_agents_files_are_read_from_its_parents_replica() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    transport.ok(
        &format!("{MOUNT}/v1/sessions/conv_child"),
        SUB_AGENT_SNAPSHOT,
    );
    transport.ok(&changes("conv_child"), r#"{"object":"list","data":[]}"#);
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();

    block_on(core.workspace_changes("conv_child", "default")).unwrap();
    assert_eq!(
        keys(&core.transport, &changes("conv_child")),
        [Some("host_a".to_owned())],
        "the workspace read is keyed by the parent's host"
    );
}

#[test]
fn a_workspace_read_refused_by_the_wrong_replica_is_re_addressed() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    transport.enqueue(
        "GET",
        &changes("conv_a"),
        vec![
            Reply::json(400, FILES_ON_ANOTHER_REPLICA),
            Reply::json(200, r#"{"object":"list","data":[]}"#),
        ],
    );
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();

    block_on(core.workspace_changes("conv_a", "default")).unwrap();
    assert_eq!(
        keys(&core.transport, &changes("conv_a")),
        [Some("host_a".to_owned()), None],
        "keyed, then once more without the key"
    );
    assert!(super::routing::is_wrong_replica(
        400,
        STREAM_ON_ANOTHER_REPLICA.as_bytes()
    ));
}

#[test]
fn a_sub_agents_stream_is_keyed_once_its_host_is_resolved() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    transport.ok(
        &format!("{MOUNT}/v1/sessions/conv_child"),
        SUB_AGENT_SNAPSHOT,
    );
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();

    let stream = "/v1/sessions/conv_child/stream";
    assert!(core.stream_needs_host("conv_child"));
    assert_eq!(
        core.slice_key(stream),
        None,
        "unkeyed is what every replica but one refuses"
    );
    assert!(block_on(core.resolve_session_host("conv_child")));
    assert!(!core.stream_needs_host("conv_child"));
    assert_eq!(core.slice_key(stream).as_deref(), Some("host_a"));
    assert!(
        !core.stream_needs_host("conv_a"),
        "a listed session needs no lookup"
    );
}

#[test]
fn a_side_chats_stream_is_keyed_by_the_session_it_was_forked_from() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    transport.ok(
        &format!("{MOUNT}/v1/sessions/conv_side"),
        SIDE_CHAT_SNAPSHOT,
    );
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();

    assert!(block_on(core.resolve_session_host("conv_side")));
    assert_eq!(
        core.slice_key("/v1/sessions/conv_side/stream").as_deref(),
        Some("host_a")
    );
}

#[test]
fn a_stream_whose_host_cannot_be_found_opens_unkeyed_and_asks_again() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    let snapshot = format!("{MOUNT}/v1/sessions/conv_gone");
    transport.enqueue(
        "GET",
        &snapshot,
        vec![
            Reply::json(404, r#"{"error":{"code":"not_found","message":"gone"}}"#),
            Reply::json(
                200,
                r#"{"id":"conv_gone","status":"idle","created_at":3,"parent_session_id":"conv_a"}"#,
            ),
        ],
    );
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();

    assert!(!block_on(core.resolve_session_host("conv_gone")));
    assert_eq!(core.slice_key("/v1/sessions/conv_gone/stream"), None);
    assert!(
        core.stream_needs_host("conv_gone"),
        "a stream's refusal has no body to learn from, so the next attempt looks again"
    );
    assert!(block_on(core.resolve_session_host("conv_gone")));
    assert_eq!(
        core.slice_key("/v1/sessions/conv_gone/stream").as_deref(),
        Some("host_a")
    );
}

#[test]
fn a_child_named_on_its_parents_stream_needs_no_lookup() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();
    let before = core.transport.taken().len();

    let updated = serde_json::json!({
        "type": "session.child_session.updated",
        "conversation_id": "conv_a",
        "child_session_id": "conv_child",
        "child": {"id": "conv_child", "parent_session_id": "conv_a", "busy": true},
    });
    let created = serde_json::json!({
        "type": "session.created",
        "conversation_id": "conv_b",
        "child_session_id": "conv_other",
    });
    for (session, event) in [("conv_a", updated), ("conv_b", created)] {
        let event = crate::reducer::decode_event(event, session)
            .unwrap()
            .unwrap();
        core.record_stream_event(session, &event);
    }

    for child in ["conv_child", "conv_other"] {
        assert!(!core.stream_needs_host(child), "{child}");
        assert_eq!(
            core.slice_key(&format!("/v1/sessions/{child}/stream"))
                .as_deref(),
            Some("host_a"),
            "{child}"
        );
    }
    assert_eq!(core.transport.taken().len(), before, "nothing was read");
}

#[test]
fn a_request_built_before_its_sessions_host_was_learned_is_keyed_without_a_lookup() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    let agent = format!("{MOUNT}/v1/sessions/conv_child/agent");
    transport.ok(&agent, r#"{"terminals":[]}"#);
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();

    // Built while nothing was known of the session: it names the session to look up.
    let prepared = core
        .prepare("GET", "/v1/sessions/conv_child/agent", &[], None)
        .unwrap();
    let addressing = prepared.addressing.clone().unwrap();
    assert_eq!(addressing.host, None);
    assert_eq!(addressing.unresolved_session.as_deref(), Some("conv_child"));

    // Its parent's stream names it before the request goes out.
    let created = serde_json::json!({
        "type": "session.created",
        "conversation_id": "conv_a",
        "child_session_id": "conv_child",
    });
    let event = crate::reducer::decode_event(created, "conv_a")
        .unwrap()
        .unwrap();
    core.record_stream_event("conv_a", &event);

    block_on(core.send_routed(prepared.request, prepared.addressing)).unwrap();
    assert_eq!(
        keys(&core.transport, &agent),
        [Some("host_a".to_owned())],
        "keyed by the host learned meanwhile"
    );
    let snapshot = format!("{MOUNT}/v1/sessions/conv_child");
    assert!(
        core.transport
            .taken()
            .iter()
            .all(|request| path_of(request) != snapshot),
        "what is already known is not read again"
    );
}

#[test]
fn an_answer_to_a_sub_agents_request_goes_to_its_parents_replica() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    listed(&transport);
    // The parent's snapshot carries the sub-agent's request, mirrored with its target.
    transport.ok(
        &format!("{MOUNT}/v1/sessions/conv_a"),
        r#"{"id":"conv_a","status":"running","created_at":1,"host_id":"host_a","permission_level":4,"pending_elicitations":[{"elicitation_id":"ask1","params":{"target_session_id":"conv_child","message":"Run the migration?"}}]}"#,
    );
    // A replica without the runner accepts the answer and drops it, so nothing would re-address.
    let resolve = format!("{MOUNT}/v1/sessions/conv_child/elicitations/ask1/resolve");
    transport.respond(
        Some("POST"),
        &resolve,
        None,
        Reply::json(200, r#"{"queued":false}"#),
    );
    let core = workspace(transport);
    block_on(core.sessions()).unwrap();

    block_on(core.resolve_decision(
        "conv_a",
        "ask1",
        &crate::decisions::DecisionResponse::Approve,
    ))
    .unwrap();
    assert_eq!(
        keys(&core.transport, &resolve),
        [Some("host_a".to_owned())],
        "keyed by the session whose chat showed the request"
    );
    assert!(
        !core
            .transport
            .taken()
            .iter()
            .any(|request| path_of(request) == format!("{MOUNT}/v1/sessions/conv_child")),
        "the child is not read to find its host"
    );
}

#[test]
fn a_session_on_a_server_that_does_not_route_by_host_is_never_looked_up() {
    let core = super::test_support::connected(RouteTransport::local());
    assert!(!core.stream_needs_host("conv_child"));
    let before = core.transport.taken().len();
    assert!(!block_on(core.resolve_session_host("conv_child")));
    assert_eq!(core.transport.taken().len(), before);
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
