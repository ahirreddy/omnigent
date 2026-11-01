//! Session client REST tests, ported from `NativeLab`'s `LocalServerSessionClientTests`,
//! `HostedServerAuthenticationTests` (the inventory race) and `SessionExecutionReadinessTests`
//! (the submission rows).

use std::future::Future;
use std::pin::pin;

use futures::executor::block_on;
use omnigent_protocol::{ConversationItem, ItemData};
use serde_json::{Value, json};

use super::events::{ChangedFile, ChangedFilesUpdate};
use super::sessions::{SessionChange, SummaryStatus};
use super::test_support::{
    MOUNT, Reply, RouteTransport, body_json, connected, connected_hosted, core, envelopes, header,
    live, path_of, query_value, record, still_pending,
};
use super::{ClientEvent, SessionError};
use crate::attachments::UploadFile;
use crate::decisions::DecisionResponse;
use crate::http::TransportError;
use crate::realtime::WatchSet;

const SESSIONS: &str = "sessions/LocalServerSessionClient--";

fn item_text(item: &ConversationItem) -> String {
    match &item.data {
        ItemData::Message(message) => message.visible_text(),
        other => format!("{other:?}"),
    }
}

#[test]
fn changed_files_invalidation_fetches_session_scoped_details_without_polling() {
    let transport = RouteTransport::local();
    transport.load(&format!(
        "{SESSIONS}ChangedFilesInvalidationFetchesSessionScopedDetailsWithoutPolling.json"
    ));
    let core = live(transport);
    let recorder = record(&core);
    block_on(core.invalidate_changed_files("conv_a", "default"));
    assert_eq!(
        recorder.take(),
        vec![ClientEvent::ChangedFiles {
            session_id: "conv_a".into(),
            environment_id: "default".into(),
            update: ChangedFilesUpdate::Loaded(vec![ChangedFile {
                path: "Sources/App.swift".into(),
                status: "modified".into(),
            }]),
        }]
    );
    let lines = core.transport().lines();
    assert_eq!(
        lines
            .iter()
            .filter(|line| line.ends_with("/changes"))
            .count(),
        1
    );
    assert_eq!(core.transport().writes(), []);
}

#[test]
fn changed_files_failure_is_visible_and_wrong_session_never_fetches() {
    let core = live(RouteTransport::local());
    block_on(core.invalidate_changed_files("other", "default"));
    assert_eq!(core.transport().taken().len(), 2);
    let recorder = record(&core);
    block_on(core.invalidate_changed_files("conv_a", "default"));
    let events = recorder.take();
    let [ClientEvent::ChangedFiles { update, .. }] = events.as_slice() else {
        panic!("expected one changed-files event: {events:?}");
    };
    let ChangedFilesUpdate::Unavailable(message) = update else {
        panic!("expected unavailable: {update:?}");
    };
    assert!(message.contains("unavailable"), "{message}");
}

#[test]
fn submit_uses_real_message_wire_and_retains_accepted_queue_identity() {
    let transport = RouteTransport::local();
    transport.writable_session("[]");
    transport.load(&format!(
        "{SESSIONS}SubmitUsesRealMessageWireAndRetainsAcceptedQueueIdentity.jsonl"
    ));
    let core = live(transport);
    let sent = block_on(core.send_message("conv_a", " Exact draft\n")).unwrap();
    assert!(sent.submission.queued);
    assert_eq!(sent.submission.item_id.as_deref(), Some("item1"));
    assert_eq!(sent.submission.pending_id.as_deref(), Some("pending1"));
    assert_eq!(sent.draft, "");
    let posts = core.transport().writes();
    assert_eq!(posts.len(), 1);
    assert_eq!(
        body_json(&posts[0]),
        json!({"type": "message", "data": {"role": "user", "content": [
            {"type": "input_text", "text": " Exact draft\n"}
        ]}})
    );
    assert_eq!(header(&posts[0], "Authorization"), None);
    assert_eq!(header(&posts[0], "Cookie"), None);
    assert_eq!(header(&posts[0], "Content-Type"), Some("application/json"));
}

#[test]
fn send_requires_hydrated_live_stream_and_does_not_retry_uncertain_post() {
    let transport = RouteTransport::local();
    transport.writable_session("[]");
    transport.load(&format!(
        "{SESSIONS}SendRequiresHydratedLiveStreamAndDoesNotRetryUncertainPOST.jsonl"
    ));
    let core = connected(transport);
    assert_eq!(
        block_on(core.send_message("conv_a", "Hello")),
        Err(SessionError::StreamNotReady)
    );
    assert_eq!(core.transport().writes(), []);
    assert_eq!(core.is_send_blocked("conv_a"), Ok(false));
    core.set_live_session(Some("conv_a"));
    assert!(matches!(
        block_on(core.send_message("conv_a", "Hello")),
        Err(SessionError::DeliveryUncertain { .. })
    ));
    assert_eq!(core.transport().writes().len(), 1);
    // The uncertain send blocks the next one until the user reviews it; nothing is re-posted.
    assert!(matches!(
        block_on(core.send_message("conv_a", "Hello")),
        Err(SessionError::Ledger(_))
    ));
    assert_eq!(core.transport().writes().len(), 1);
    assert_eq!(core.acknowledge_uncertain_send("conv_a"), Ok(true));
    assert_eq!(core.is_send_blocked("conv_a"), Ok(false));
}

#[test]
fn denied_and_malformed_acknowledgements_are_not_success() {
    let transport = RouteTransport::local();
    transport.writable_session("[]");
    transport.load(&format!(
        "{SESSIONS}DeniedAndMalformedAcknowledgementsAreNotSuccess.jsonl"
    ));
    let core = live(transport);
    assert_eq!(
        block_on(core.send_message("conv_a", "Hello")),
        Err(SessionError::MessageDenied { reason: None })
    );
    core.update_composer("conv_a", "Hello").unwrap();
    assert_eq!(core.composer_text("conv_a").unwrap(), "Hello");
    assert!(matches!(
        block_on(core.send_message("conv_a", "Hello")),
        Err(SessionError::DeliveryUncertain { .. })
    ));
    assert_eq!(core.composer_text("conv_a").unwrap(), "Hello");
    assert_eq!(core.transport().writes().len(), 2);
}

#[test]
fn interrupt_uses_interrupt_not_owner_stop_session() {
    let transport = RouteTransport::local();
    transport.writable_session("[]");
    transport.load(&format!(
        "{SESSIONS}InterruptUsesInterruptNotOwnerStopSession.json"
    ));
    let core = connected(transport);
    block_on(core.interrupt("conv_a")).unwrap();
    let writes = core.transport().writes();
    assert_eq!(writes.len(), 1);
    assert_eq!(path_of(&writes[0]), "/v1/sessions/conv_a/events");
    assert_eq!(
        body_json(&writes[0]),
        json!({"type": "interrupt", "data": {}})
    );
}

#[test]
fn inventory_follows_later_page_and_watches_pending_session_outside_visible_page() {
    let transport = RouteTransport::local();
    let prefix =
        format!("{SESSIONS}InventoryFollowsLaterPageAndWatchesPendingSessionOutsideVisiblePage--");
    transport.load(&format!("{prefix}pages.jsonl"));
    transport.load(&format!("{prefix}conv-later.json"));
    transport.load(
        "items/LocalServerSessionClient--InventoryFollowsLaterPageAndWatchesPendingSessionOutsideVisiblePage--conv-later-items.json",
    );
    let core = connected(transport);
    let first_page: Vec<String> = (1..=50).map(|n| format!("conv_{n}")).collect();
    let visible = block_on(core.session_page(None, 50)).unwrap();
    assert_eq!(
        visible
            .sessions
            .iter()
            .map(|s| s.id.clone())
            .collect::<Vec<_>>(),
        first_page
    );
    assert!(
        visible
            .sessions
            .iter()
            .all(|s| s.status != SummaryStatus::NeedsResponse)
    );
    let inventory = block_on(core.session_inventory()).unwrap();
    let mut expected = first_page;
    expected.push("conv_later".into());
    assert_eq!(
        inventory.iter().map(|s| s.id.clone()).collect::<Vec<_>>(),
        expected
    );
    let pending: Vec<_> = inventory
        .iter()
        .filter(|s| s.status == SummaryStatus::NeedsResponse)
        .collect();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].id, "conv_later");
    assert!(pending[0].is_archived);

    let lists: Vec<_> = core
        .transport()
        .taken()
        .into_iter()
        .filter(|request| path_of(request) == "/v1/sessions")
        .collect();
    assert_eq!(lists.len(), 3);
    assert_eq!(query_value(&lists[1], "after"), None);
    assert_eq!(query_value(&lists[2], "after").as_deref(), Some("conv_50"));
    for request in &lists[1..] {
        assert_eq!(query_value(request, "limit").as_deref(), Some("500"));
        assert_eq!(query_value(request, "kind").as_deref(), Some("any"));
        assert_eq!(
            query_value(request, "include_archived").as_deref(),
            Some("true")
        );
        assert_eq!(query_value(request, "visibility").as_deref(), Some("all"));
    }

    let watch = WatchSet::new(inventory.iter().map(|s| s.id.clone())).unwrap();
    assert!(watch.contains("conv_later"));
    assert_eq!(watch.ids().len(), 51);
    let conversation = block_on(core.conversation_page(&pending[0].id, 50)).unwrap();
    assert_eq!(conversation.decisions.len(), 1);
    assert_eq!(conversation.decisions[0].id, "later_approval");
    assert_eq!(conversation.decisions[0].target_session_id, "conv_later");

    let recorder = record(&core);
    let frame = &super::test_support::fixture_lines(&format!("{prefix}ws.jsonl"))[0];
    let rows = frame["message"]["items"].as_array().unwrap().clone();
    let changed = core.apply_session_rows(rows).unwrap();
    assert_eq!(changed.len(), 1);
    assert_eq!(changed[0].id, "conv_later");
    assert_eq!(changed[0].status, SummaryStatus::Idle);
    let events = recorder.take();
    assert!(
        matches!(&events[0], ClientEvent::SessionsChanged { sessions } if sessions[0].id == "conv_later")
    );
    assert_eq!(events[1], ClientEvent::InventoryInvalidated);
}

/// A blocking HTTP/1.1 transport over a TCP socket, only for the opt-in live-server smoke test.
struct LoopbackTransport;

impl crate::http::HttpTransport for LoopbackTransport {
    fn send(
        &self,
        request: crate::http::HttpRequest,
    ) -> impl Future<Output = Result<crate::http::HttpResponse, TransportError>> {
        use std::io::{Read as _, Write as _};
        let result = (|| {
            let url = url::Url::parse(&request.url).map_err(|e| e.to_string())?;
            let address = format!(
                "{}:{}",
                url.host_str().unwrap_or_default(),
                url.port_or_known_default().unwrap_or(80)
            );
            let mut stream = std::net::TcpStream::connect(address).map_err(|e| e.to_string())?;
            let target = url.query().map_or_else(
                || url.path().to_owned(),
                |query| format!("{}?{query}", url.path()),
            );
            write!(
                stream,
                "{} {target} HTTP/1.1\r\nHost: {}\r\nAccept: application/json\r\nConnection: close\r\n\r\n",
                request.method,
                url.host_str().unwrap_or_default()
            )
            .map_err(|e| e.to_string())?;
            let mut raw = Vec::new();
            stream.read_to_end(&mut raw).map_err(|e| e.to_string())?;
            let text = String::from_utf8_lossy(&raw).into_owned();
            let (head, body) = text.split_once("\r\n\r\n").ok_or("no header end")?;
            let status = head
                .split(' ')
                .nth(1)
                .and_then(|status| status.parse().ok())
                .ok_or("no status")?;
            assert!(
                !head.to_ascii_lowercase().contains("transfer-encoding: chunked"),
                "the smoke transport does not decode chunked bodies"
            );
            Ok(crate::http::HttpResponse {
                status,
                headers: vec![crate::http::HttpHeader::new("Content-Type", "application/json")],
                body: body.as_bytes().to_vec(),
            })
        })()
        .map_err(|message: String| TransportError::Other { message });
        std::future::ready(result)
    }
}

#[test]
#[ignore = "needs a seeded local server; run with OMNI_LOCAL_API_TESTS=1"]
fn opt_in_local_server_fixture_smoke() {
    if std::env::var("OMNI_LOCAL_API_TESTS").as_deref() != Ok("1") {
        return;
    }
    let core = super::ClientCore::new(LoopbackTransport, super::test_support::DEBUG);
    let server = block_on(core.connect(
        crate::auth::endpoint::ServerEndpoint::new("http://127.0.0.1:6767").unwrap(),
        None,
        None,
    ))
    .unwrap();
    assert_eq!(server.user_id, "local");
    let mut page = block_on(core.session_page(None, 2)).unwrap();
    assert_eq!(page.sessions.len(), 2);
    let mut sessions = page.sessions.clone();
    let mut cursors = std::collections::BTreeSet::new();
    while let Some(after) = page.next_cursor.clone() {
        assert!(cursors.insert(after.clone()));
        page = block_on(core.session_page(Some(&after), 2)).unwrap();
        sessions.extend(page.sessions.clone());
    }
    assert!(sessions.len() >= 3);
    let fixture = "f1000000000000000000000000000001";
    assert_eq!(
        sessions.iter().find(|s| s.id == fixture).unwrap().title,
        "Local API validation"
    );
    let latest = block_on(core.conversation_page(fixture, 50)).unwrap();
    assert!(!latest.summary.is_read_only);
    assert_eq!(latest.decisions, []);
    let older = block_on(core.history_page(fixture, latest.next_cursor.as_deref(), 50)).unwrap();
    assert_eq!(older.next_cursor, None);
    let texts: Vec<String> = older
        .items
        .iter()
        .chain(&latest.items)
        .map(item_text)
        .collect();
    assert_eq!(
        texts,
        (1..=60)
            .map(|n| format!("Local API fixture message {n:02}."))
            .collect::<Vec<_>>()
    );
}

#[test]
fn reads_require_successful_connect() {
    let core = core(RouteTransport::local());
    assert_eq!(block_on(core.sessions()), Err(SessionError::NotConnected));
    assert_eq!(
        block_on(core.conversation_snapshot("conv_a")).unwrap_err(),
        SessionError::NotConnected
    );
    assert_eq!(
        block_on(core.history_page("conv_a", None, 50)),
        Err(SessionError::NotConnected)
    );
    assert_eq!(core.transport().taken(), []);
}

#[test]
fn session_pages_preserve_order_and_read_only_metadata() {
    let transport = RouteTransport::local();
    transport.load(&format!(
        "{SESSIONS}SessionPagesPreserveOrderAndReadOnlyMetadata--page1.json"
    ));
    let core = connected(transport);
    let page = block_on(core.session_page(Some("conv_before"), 2)).unwrap();
    let ids: Vec<&str> = page.sessions.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(ids, ["conv_new", "conv_old"]);
    assert_eq!(page.next_cursor.as_deref(), Some("conv_old"));
    let (newest, oldest) = (&page.sessions[0], &page.sessions[1]);
    assert!(!newest.is_read_only);
    assert!(oldest.is_read_only);
    assert!(newest.is_pinned);
    assert_eq!(newest.status, SummaryStatus::Running);
    assert_eq!(newest.updated_at, 30);
    assert_eq!(newest.workspace, "/workspace");
    assert!(oldest.is_archived);
    assert_eq!(oldest.status, SummaryStatus::NeedsResponse);
    assert_eq!(oldest.title, "Untitled session");
    let request = core.transport().taken().pop().unwrap();
    for (name, value) in [
        ("order", "desc"),
        ("sort_by", "updated_at"),
        ("limit", "2"),
        ("after", "conv_before"),
        ("include_archived", "true"),
        ("visibility", "all"),
    ] {
        assert_eq!(
            query_value(&request, name).as_deref(),
            Some(value),
            "{name}"
        );
    }
}

#[test]
fn conversation_page_loads_metadata_and_latest_history_with_increasing_revisions() {
    let transport = RouteTransport::local();
    transport.load(&format!(
        "{SESSIONS}ConversationPageLoadsMetadataAndLatestHistoryWithIncreasingRevisions--session.json"
    ));
    transport.load(
        "items/LocalServerSessionClient--ConversationPageLoadsMetadataAndLatestHistoryWithIncreasingRevisions--items.json",
    );
    let core = connected(transport);
    let first = block_on(core.conversation_page("conv_a", 1)).unwrap();
    let second = block_on(core.conversation_snapshot("conv_a")).unwrap();
    assert_eq!(first.next_cursor.as_deref(), Some("msg_1"));
    assert_eq!(
        first.items.iter().map(item_text).collect::<Vec<_>>(),
        ["Ready"]
    );
    assert_eq!(first.summary.status, SummaryStatus::NeedsResponse);
    assert!(first.summary.is_read_only);
    assert_eq!(
        first
            .decisions
            .iter()
            .map(|d| d.id.as_str())
            .collect::<Vec<_>>(),
        ["pending_1"]
    );
    assert!(second.revision > first.revision);
    let snapshot_request = core
        .transport()
        .taken()
        .into_iter()
        .find(|request| path_of(request) == "/v1/sessions/conv_a")
        .unwrap();
    assert_eq!(
        query_value(&snapshot_request, "include_items").as_deref(),
        Some("false")
    );
}

#[test]
fn invalid_and_repeated_pagination_cursors_fail() {
    for envelope in envelopes(&format!(
        "{SESSIONS}InvalidAndRepeatedPaginationCursorsFail.jsonl"
    )) {
        let transport = RouteTransport::local();
        transport.respond(None, &envelope.path, None, envelope.reply.clone());
        let core = connected(transport);
        assert_eq!(
            block_on(core.session_page(Some("same"), 50)),
            Err(SessionError::InvalidPagination),
            "{envelope:?}"
        );
    }
}

#[test]
fn status_failures_and_redirect_responses_are_explicit() {
    for (status, expected) in [
        (301, SessionError::RedirectNotAllowed { status: 301 }),
        (302, SessionError::RedirectNotAllowed { status: 302 }),
        (401, SessionError::Unauthorized { reason: None }),
        (403, SessionError::Forbidden),
        (404, SessionError::HttpStatus { status: 404 }),
        (500, SessionError::HttpStatus { status: 500 }),
        (204, SessionError::HttpStatus { status: 204 }),
    ] {
        let transport = RouteTransport::local();
        transport.respond(None, "/v1/sessions", None, Reply::json(status, "{}"));
        let core = connected(transport);
        assert_eq!(block_on(core.sessions()), Err(expected), "{status}");
        assert_eq!(core.transport().taken().len(), 3);
    }
}

#[test]
fn response_from_different_url_is_rejected() {
    // Hosts never follow redirects (`HttpResponse` has no final URL), so a response "from a
    // different URL" can only reach the core as the redirect itself: rejected, not followed.
    let transport = RouteTransport::local();
    transport.respond(None, "/v1/sessions", None, Reply::json(307, "{}"));
    let core = connected(transport);
    assert_eq!(
        block_on(core.sessions()),
        Err(SessionError::RedirectNotAllowed { status: 307 })
    );
    assert_eq!(core.transport().taken().len(), 3);
}

#[test]
fn transport_failure_and_cancellation_are_distinct() {
    for (failure, expected) in [
        (
            TransportError::Offline {
                message: "cannotConnectToHost".into(),
            },
            SessionError::Transport(TransportError::Offline {
                message: "cannotConnectToHost".into(),
            }),
        ),
        (
            TransportError::Timeout {
                message: "timedOut".into(),
            },
            SessionError::Transport(TransportError::Timeout {
                message: "timedOut".into(),
            }),
        ),
        (TransportError::Cancelled, SessionError::Cancelled),
    ] {
        let transport = RouteTransport::local();
        transport.respond(None, "/v1/sessions", None, Reply::Fail(failure));
        let core = connected(transport);
        assert_eq!(block_on(core.sessions()), Err(expected));
        assert!(
            core.is_connected(),
            "a transport failure keeps the connection"
        );
    }
    // Connect keeps the kinds too.
    let transport = RouteTransport::local();
    transport.respond(
        None,
        "/v1/info",
        None,
        Reply::Fail(TransportError::Cancelled),
    );
    let core = core(transport);
    assert_eq!(
        block_on(core.connect(
            crate::auth::endpoint::ServerEndpoint::new("http://127.0.0.1:6767").unwrap(),
            None,
            None
        )),
        Err(SessionError::Cancelled)
    );
}

#[test]
fn authentication_loss_revokes_read_access_until_reconnected() {
    let transport = RouteTransport::local();
    transport.respond(None, "/v1/sessions", None, Reply::json(401, "{}"));
    let core = connected(transport);
    let recorder = record(&core);
    assert_eq!(
        block_on(core.sessions()),
        Err(SessionError::Unauthorized { reason: None })
    );
    assert_eq!(block_on(core.sessions()), Err(SessionError::NotConnected));
    assert_eq!(core.transport().taken().len(), 3);
    assert_eq!(
        recorder.take(),
        vec![ClientEvent::ConnectionChanged { connected: false }]
    );
    core.transport()
        .ok("/v1/sessions", r#"{"data":[],"has_more":false}"#);
    block_on(core.reconnect()).unwrap();
    assert_eq!(block_on(core.sessions()), Ok(Vec::new()));
}

#[test]
fn invalid_identifiers_and_limits_never_make_resource_requests() {
    let core = connected(RouteTransport::local());
    for id in ["", "../info", "a/b", "a?token=x", "a#fragment"] {
        assert!(
            matches!(
                block_on(core.conversation_snapshot(id)),
                Err(SessionError::InvalidIdentifier { .. })
            ),
            "{id:?}"
        );
    }
    for limit in [0, 1001] {
        let expected = SessionError::InvalidPageLimit { limit };
        assert_eq!(
            block_on(core.session_page(None, limit)),
            Err(expected.clone())
        );
        assert_eq!(
            block_on(core.history_page("conv_a", None, limit)),
            Err(expected.clone())
        );
        assert_eq!(
            block_on(core.conversation_page("conv_a", limit)).unwrap_err(),
            expected
        );
    }
    assert_eq!(
        block_on(core.session_page(Some(""), 50)),
        Err(SessionError::InvalidPagination)
    );
    assert_eq!(core.transport().taken().len(), 2);
}

#[test]
fn read_only_permission_prevents_mutation_requests() {
    let transport = RouteTransport::local();
    transport.load(&format!(
        "{SESSIONS}ReadOnlyPermissionPreventsMutationRequests.json"
    ));
    let core = live(transport);
    assert_eq!(
        block_on(core.send_message("conv_a", "Hello")),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(
        block_on(core.interrupt("conv_a")),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(
        block_on(core.resolve_decision("conv_a", "d", &DecisionResponse::Approve)),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(
        block_on(core.edit_session("conv_a", SessionChange::Title("Changed".into()))),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(
        block_on(core.edit_session("conv_a", SessionChange::Archived(true))),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(core.transport().writes(), []);
    // Creation needs a host and an agent; an empty selection never posts.
    assert!(matches!(
        block_on(core.create_session(&crate::creation::CreationSelection::default(), "New")),
        Err(SessionError::InvalidIdentifier { .. })
    ));
    assert_eq!(core.transport().writes(), []);
}

#[test]
fn disconnect_discards_in_flight_inventory() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    let path = format!("{MOUNT}/v1/sessions");
    transport.load("sessions/HostedServerAuthentication--DisconnectDiscardsInFlightInventory.json");
    let gate = transport.gate("GET", &path);
    let core = connected_hosted(transport);
    let mut operation = pin!(core.sessions());
    assert!(still_pending(operation.as_mut()));
    assert!(
        core.transport()
            .lines()
            .last()
            .unwrap()
            .ends_with("/v1/sessions")
    );
    core.disconnect();
    gate.open();
    assert_eq!(block_on(operation), Err(SessionError::NotConnected));
    assert_eq!(core.cached_summaries(), []);
    let sessions_request = core.transport().taken().pop().unwrap();
    assert_eq!(
        header(&sessions_request, "Authorization"),
        Some(format!("Bearer {}", super::test_support::TOKEN).as_str())
    );
}

#[test]
fn connected_host_and_wakeable_host_allow_stopped_runner_submissions() {
    let all = envelopes(
        "sessions/SessionExecutionReadiness--ConnectedHostAndWakeableHostAllowStoppedRunnerSubmissions.jsonl",
    );
    for pair in all.chunks(2) {
        let transport = RouteTransport::local();
        transport.respond(None, &pair[0].path, None, pair[0].reply.clone());
        transport.respond(
            None,
            "/v1/sessions/conv_a/items",
            None,
            Reply::json(200, r#"{"data":[],"has_more":false}"#),
        );
        transport.respond(Some("POST"), &pair[1].path, None, pair[1].reply.clone());
        let core = live(transport);
        let sent = block_on(core.send_message("conv_a", "Wake this session")).unwrap();
        assert!(sent.submission.queued);
        let writes = core.transport().writes();
        assert_eq!(writes.len(), 1);
        assert_eq!(Some(body_json(&writes[0])), pair[1].body);
    }
}

#[test]
fn unavailable_session_never_posts_text_or_attachment_message() {
    for envelope in envelopes(
        "sessions/SessionExecutionReadiness--UnavailableSessionNeverPostsTextOrAttachmentMessage.jsonl",
    ) {
        let transport = RouteTransport::local();
        transport.respond(None, &envelope.path, None, envelope.reply.clone());
        let core = live(transport);
        let Reply::Response { body, .. } = &envelope.reply else {
            panic!("expected a response");
        };
        let fields: Value = serde_json::from_str(body).unwrap();
        let reason = super::sessions::test_support::summary_of(&fields, None, true)
            .configuration
            .unwrap()
            .execution_unavailable_reason()
            .unwrap()
            .to_owned();
        let expected = SessionError::ExecutionUnavailable { reason };
        assert_eq!(
            block_on(core.send_message("conv_a", "Keep this draft")),
            Err(expected.clone())
        );
        let file = UploadFile::new("draft.txt", Some("text/plain"), b"draft".to_vec()).unwrap();
        let item = core.add_attachment("conv_a", file).unwrap();
        assert_eq!(
            block_on(core.upload_attachment("conv_a", item, "boundary-1")),
            Err(expected.clone())
        );
        assert_eq!(
            block_on(core.send_message("conv_a", "Keep this draft")),
            Err(SessionError::Draft(
                crate::attachments::DraftError::NotReady
            ))
        );
        assert_eq!(
            core.transport().writes(),
            [],
            "{:?}",
            core.transport().lines()
        );
    }
}

#[test]
fn hosted_requests_carry_bearer_and_never_a_cookie() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    transport.ok(
        &format!("{MOUNT}/v1/sessions"),
        r#"{"data":[],"has_more":false}"#,
    );
    let core = connected_hosted(transport);
    block_on(core.sessions()).unwrap();
    for request in core.transport().taken() {
        assert!(header(&request, "Authorization").is_some());
        assert_eq!(header(&request, "Cookie"), None);
    }
}

#[test]
fn edits_trim_titles_pin_with_a_stamp_and_publish_the_acknowledgement() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("GET"),
        "/v1/sessions/conv_a",
        None,
        Reply::json(
            200,
            r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#,
        ),
    );
    transport.respond(
        Some("PATCH"),
        "/v1/sessions/conv_a",
        None,
        Reply::json(
            200,
            r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"title":"Renamed","labels":{"omnigent.pinned":"42"}}"#,
        ),
    );
    let core = connected(transport);
    let recorder = record(&core);
    let renamed =
        block_on(core.edit_session("conv_a", SessionChange::Title("  Renamed  ".into()))).unwrap();
    assert_eq!(renamed.title, "Renamed");
    block_on(core.edit_session(
        "conv_a",
        SessionChange::Pinned {
            pinned: true,
            at_ms: 42,
        },
    ))
    .unwrap();
    block_on(core.edit_session(
        "conv_a",
        SessionChange::Pinned {
            pinned: false,
            at_ms: 43,
        },
    ))
    .unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        vec![
            json!({"title": "Renamed"}),
            json!({"labels": {"omnigent.pinned": "42"}}),
            json!({"labels": {"omnigent.pinned": ""}}),
        ]
    );
    for title in [" \n ".to_owned(), "x".repeat(121)] {
        assert_eq!(
            block_on(core.edit_session("conv_a", SessionChange::Title(title))),
            Err(SessionError::InvalidTitle)
        );
    }
    assert_eq!(core.transport().writes().len(), 3);
    assert!(recorder
        .take()
        .iter()
        .any(|event| matches!(event, ClientEvent::SessionsChanged { sessions } if sessions[0].title == "Renamed")));
}
