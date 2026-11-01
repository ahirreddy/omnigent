//! Ported `NativeNotificationTests`, the notification rows of `HostedServerAuthenticationTests`
//! and `DatabricksRoutingTests`, and the web `useIdleNotifications` behaviour.

use omnigent_protocol::SessionListItem;
use serde_json::{Value, json};

use super::*;
use crate::auth::SecretString;
use crate::auth::endpoint::ServerEndpoint;
use crate::http::{HttpRequest, HttpResponse, TransportError};

const TOKEN: &str = "fixture-token-not-a-real-credential";

fn payload(server: &str, user: &str, workspace: &str, session: &str, event: &str) -> Value {
    json!({"omnigent": {
        "version": 1, "server_url": server, "user_id": user, "workspace_id": workspace,
        "session_id": session, "event_id": event, "kind": "approval"
    }})
}

fn default_payload() -> Value {
    payload("https://example.invalid", "alice", "0", "conv_a", "event_a")
}

fn route(value: &Value) -> NotificationRoute {
    NotificationRoute::from_payload(value).unwrap()
}

#[allow(
    clippy::unnecessary_wraps,
    reason = "the mappers take the host transport result"
)]
fn response(status: u16, body: &str) -> Result<HttpResponse, TransportError> {
    Ok(HttpResponse {
        status,
        headers: Vec::new(),
        body: body.as_bytes().to_vec(),
    })
}

fn header<'a>(request: &'a HttpRequest, name: &str) -> Option<&'a str> {
    request
        .headers
        .iter()
        .find(|header| header.name.eq_ignore_ascii_case(name))
        .map(|header| header.value.as_str())
}

// --- NativeNotificationTests --------------------------------------------------------------------

#[test]
fn scoped_route_canonicalizes_origin_and_rejects_untrusted_navigation() {
    let canonical = route(&payload(
        "https://EXAMPLE.invalid:443/",
        "alice",
        "0",
        "conv_a",
        "event_a",
    ));
    assert_eq!(canonical.scope.server_url(), "https://example.invalid");
    assert_eq!(canonical.session_id, "conv_a");
    assert_eq!(canonical.kind, NotificationKind::Approval);
    assert_eq!(
        NotificationRoute::from_payload(&json!({"navigatePath": "/sessions/conv_a"})),
        Err(NotificationError::MissingPayload)
    );
    for session in [
        "../other",
        "conv_a?redirect=evil",
        "conv_a/other",
        "",
        "conv_a%2Fother",
    ] {
        assert_eq!(
            NotificationRoute::from_payload(&payload(
                "https://example.invalid",
                "alice",
                "0",
                session,
                "e"
            )),
            Err(NotificationError::InvalidIdentifier {
                field: "session_id"
            }),
            "{session}"
        );
    }
    for server in [
        "file:///tmp",
        "https://user:pass@example.invalid",
        "https://example.invalid/%2e%2e/other",
        "https://example.invalid?q=1",
    ] {
        assert!(
            matches!(
                NotificationRoute::from_payload(&payload(server, "alice", "0", "conv_a", "e")),
                Err(NotificationError::InvalidServerUrl(_))
            ),
            "{server}"
        );
    }
    let mut unknown_kind = default_payload();
    unknown_kind["omnigent"]["kind"] = json!("open_url");
    assert_eq!(
        NotificationRoute::from_payload(&unknown_kind),
        Err(NotificationError::UnknownKind {
            kind: "open_url".to_owned()
        })
    );
    let mut future = default_payload();
    future["omnigent"]["version"] = json!(2);
    assert!(matches!(
        NotificationRoute::from_payload(&future),
        Err(NotificationError::UnsupportedVersion { .. })
    ));
    let bob = route(&payload(
        "https://example.invalid",
        "bob",
        "0",
        "conv_a",
        "event_a",
    ));
    let workspace = route(&payload(
        "https://example.invalid",
        "alice",
        "1",
        "conv_a",
        "event_a",
    ));
    assert_ne!(canonical.scope, bob.scope);
    assert_ne!(canonical.scope, workspace.scope);
}

#[test]
fn dedup_persists_and_scopes_every_identity_component() {
    let mut ledger = NotificationLedger::new();
    let first = route(&default_payload());
    assert!(ledger.insert(&first));
    assert!(!ledger.insert(&first));
    let mut ledger = NotificationLedger::from_json(&ledger.to_json()).unwrap();
    assert!(!ledger.insert(&first));
    for value in [
        payload("https://other.invalid", "alice", "0", "conv_a", "event_a"),
        payload("https://example.invalid", "bob", "0", "conv_a", "event_a"),
        payload("https://example.invalid", "alice", "1", "conv_a", "event_a"),
        payload("https://example.invalid", "alice", "0", "conv_b", "event_a"),
        payload("https://example.invalid", "alice", "0", "conv_a", "event_b"),
    ] {
        assert!(ledger.insert(&route(&value)), "{value}");
    }
    let mut activation = NotificationLedger::new();
    assert!(
        activation.insert(&first),
        "presentation must not consume the tap"
    );
    for malformed in [
        json!({}),
        json!({"version": 1}),
        json!({"version": 1, "keys": [1]}),
    ] {
        assert!(matches!(
            NotificationLedger::from_json(&malformed),
            Err(NotificationError::MalformedLedger { .. })
        ));
    }
}

#[test]
fn ledger_is_bounded_and_retains_recent_events() {
    let event = |index: usize| {
        route(&payload(
            "https://example.invalid",
            "alice",
            "0",
            "conv_a",
            &format!("e_{index}"),
        ))
    };
    let mut ledger = NotificationLedger::new();
    for index in 0..=MAX_LEDGER_ENTRIES {
        assert!(ledger.insert(&event(index)));
    }
    assert_eq!(ledger.len(), MAX_LEDGER_ENTRIES);
    assert!(!ledger.insert(&event(MAX_LEDGER_ENTRIES)));
    assert!(ledger.insert(&event(0)));
}

#[test]
fn loopback_development_scope_is_exact() {
    for address in ["http://127.0.0.1:6767", "http://[::1]:6767"] {
        let scope = NotificationScope::in_default_workspace(address, "local").unwrap();
        assert!(scope.is_loopback_development(), "{address}");
    }
    for address in [
        "http://localhost:6767",
        "http://192.168.0.1:6767",
        "http://127.0.0.1.evil.invalid",
    ] {
        assert!(
            NotificationScope::in_default_workspace(address, "local").is_err(),
            "{address}"
        );
    }
    assert!(
        !NotificationScope::in_default_workspace("http://127.0.0.1", "alice")
            .unwrap()
            .is_loopback_development()
    );
    assert!(
        !NotificationScope::new("http://127.0.0.1", "local", "1")
            .unwrap()
            .is_loopback_development()
    );
    assert_eq!(
        NotificationScope::new("http://127.0.0.1", "", "0"),
        Err(NotificationError::EmptyIdentity { field: "user_id" })
    );
}

#[test]
fn http_registration_contract_and_redirect_rejection() {
    let endpoint = ServerEndpoint::new("https://example.invalid").unwrap();
    let registration = PushRegistration::new(
        "install_a",
        "ab",
        "sandbox",
        "ai.test",
        ["conv_b", "conv_a", "conv_a"].map(str::to_owned),
    )
    .unwrap();
    let request = register_request(&endpoint, None, &registration).unwrap();
    assert_eq!(request.method, "PUT");
    assert_eq!(
        request.url,
        "https://example.invalid/v1/notifications/devices"
    );
    assert_eq!(header(&request, "Content-Type"), Some("application/json"));
    let body: Value = serde_json::from_slice(request.body.as_deref().unwrap()).unwrap();
    assert_eq!(body["session_ids"], json!(["conv_a", "conv_b"]));
    assert_eq!(
        body.get("user_id"),
        None,
        "identity comes from authentication"
    );
    assert_eq!(
        mutation_response(response(204, "")),
        Ok(PushSupport::Supported(()))
    );
    // Hosts never follow redirects, so a redirect arrives as a 3xx and is rejected.
    let capabilities = capabilities_request(&endpoint, None).unwrap();
    assert_eq!(capabilities.method, "GET");
    assert_eq!(
        capabilities_response(response(302, "")),
        Err(PushError::Redirect { status: 302 })
    );
    assert!(matches!(
        PushRegistration::new("install/a", "ab", "sandbox", "ai.test", Vec::new()),
        Err(PushError::InvalidIdentifier { .. })
    ));
    assert!(matches!(
        PushRegistration::new("install_a", "ab", "sandbox", "ai.test", ["../x".to_owned()]),
        Err(PushError::InvalidIdentifier { .. })
    ));
    assert_eq!(
        PushRegistration::new("install_a", "", "sandbox", "ai.test", Vec::new()),
        Err(PushError::EmptyField {
            field: "device_token"
        })
    );
}

#[test]
fn push_routes_missing_on_the_server_are_a_typed_unsupported_result() {
    assert_eq!(
        capabilities_response(response(404, "Not Found")),
        Ok(PushSupport::Unsupported)
    );
    assert_eq!(
        mutation_response(response(404, "Not Found")),
        Ok(PushSupport::Unsupported)
    );
    let capabilities = capabilities_response(response(
        200,
        r#"{"available": false, "missing_configuration": ["APNS_KEY"], "workspace_id": "0",
            "server_url": null, "local_development": true}"#,
    ))
    .unwrap();
    assert_eq!(
        capabilities,
        PushSupport::Supported(PushCapabilities {
            available: false,
            missing_configuration: vec!["APNS_KEY".to_owned()],
            server_url: None,
            environment: None,
            topic: None,
            workspace_id: "0".to_owned(),
            local_development: Some(true),
        })
    );
    assert!(matches!(
        capabilities_response(response(
            200,
            r#"{"available": "yes", "workspace_id": "0"}"#
        )),
        Err(PushError::Decode { .. })
    ));
    assert!(matches!(
        capabilities_response(response(200, "<html>")),
        Err(PushError::Decode { .. })
    ));
    assert!(matches!(
        mutation_response(response(500, "boom")),
        Err(PushError::HttpStatus { status: 500, .. })
    ));
    assert_eq!(
        mutation_response(Err(TransportError::Cancelled)),
        Err(PushError::Transport(TransportError::Cancelled))
    );
}

// --- HostedServerAuthenticationTests, DatabricksRoutingTests ------------------------------------

#[test]
fn unauthorized_clears_connection_and_mounted_notification_mutation_uses_bearer() {
    let endpoint = ServerEndpoint::new("https://example.invalid/api/2.0/omnigent").unwrap();
    let bearer = SecretString::new(TOKEN);
    let request = unregister_request(&endpoint, Some(&bearer), "install_a").unwrap();
    assert_eq!(request.method, "DELETE");
    assert_eq!(
        request.url,
        "https://example.invalid/api/2.0/omnigent/v1/notifications/devices/install_a"
    );
    assert_eq!(
        header(&request, "Authorization"),
        Some(format!("Bearer {TOKEN}").as_str())
    );
    assert_eq!(
        mutation_response(response(204, "")),
        Ok(PushSupport::Supported(()))
    );
    // 401 is typed so the session client drops the connection (WP5 owns the connection state).
    assert_eq!(
        mutation_response(response(401, "")),
        Err(PushError::Unauthorized)
    );
    assert_eq!(
        mutation_response(response(403, "")),
        Err(PushError::Forbidden)
    );
    assert!(matches!(
        unregister_request(&endpoint, Some(&bearer), "../install"),
        Err(PushError::InvalidIdentifier { .. })
    ));
    // NativeLab refused a bearer for any loopback root, treating every loopback server as
    // single-user. An accounts server on 127.0.0.1 authenticates device registration with its
    // bearer like a hosted one, so the request now carries it.
    let local = ServerEndpoint::new("http://127.0.0.1:6767").unwrap();
    let request = unregister_request(&local, Some(&bearer), "install_a").unwrap();
    assert_eq!(
        request.url,
        "http://127.0.0.1:6767/v1/notifications/devices/install_a"
    );
    assert_eq!(
        header(&request, "Authorization"),
        Some(format!("Bearer {TOKEN}").as_str())
    );
}

#[test]
fn notification_scope_includes_mount_and_account() {
    let first =
        NotificationScope::in_default_workspace("https://EXAMPLE.invalid:443/api/one/", "alice")
            .unwrap();
    assert_eq!(first.server_url(), "https://example.invalid/api/one");
    assert_ne!(
        first,
        NotificationScope::in_default_workspace("https://example.invalid/api/two", "alice")
            .unwrap()
    );
    assert_ne!(
        first,
        NotificationScope::in_default_workspace(first.server_url(), "bob").unwrap()
    );
    assert_eq!(
        first,
        NotificationScope::in_default_workspace(first.server_url(), "alice").unwrap()
    );
}

#[test]
fn both_notification_clients_use_header_and_strip_scope_query() {
    let endpoint =
        ServerEndpoint::new("https://fixture.cloud.databricks.com/api/2.0/omnigent?o=123").unwrap();
    let bearer = SecretString::new(TOKEN);
    let registration =
        PushRegistration::new("install_a", "ab", "sandbox", "ai.test", Vec::new()).unwrap();
    for request in [
        unregister_request(&endpoint, Some(&bearer), "install_a").unwrap(),
        register_request(&endpoint, Some(&bearer), &registration).unwrap(),
        capabilities_request(&endpoint, Some(&bearer)).unwrap(),
    ] {
        assert_eq!(header(&request, "X-Databricks-Org-Id"), Some("123"));
        assert!(!request.url.contains('?'), "{}", request.url);
        assert!(request.url.starts_with(
            "https://fixture.cloud.databricks.com/api/2.0/omnigent/v1/notifications/"
        ));
    }
}

// --- Foreground presentation --------------------------------------------------------------------

#[test]
fn foreground_push_for_the_viewed_session_is_suppressed_and_deduplicated() {
    let pushed = route(&default_payload());
    let scope = pushed.scope.clone();
    let viewing = ViewContext {
        active_session_id: Some("conv_a".to_owned()),
        window_focused: true,
    };
    let mut presented = NotificationLedger::new();
    assert_eq!(
        foreground_presentation(&pushed, Some(&scope), &viewing, &mut presented),
        PushPresentation::SuppressViewed
    );
    assert_eq!(
        foreground_presentation(
            &pushed,
            Some(&scope),
            &ViewContext::default(),
            &mut presented
        ),
        PushPresentation::Duplicate
    );
    let other_account =
        NotificationScope::in_default_workspace("https://example.invalid", "bob").unwrap();
    let mut fresh = NotificationLedger::new();
    assert_eq!(
        foreground_presentation(&pushed, Some(&other_account), &viewing, &mut fresh),
        PushPresentation::Present
    );
    let blurred = ViewContext {
        window_focused: false,
        ..viewing
    };
    let mut fresh = NotificationLedger::new();
    assert_eq!(
        foreground_presentation(&pushed, Some(&scope), &blurred, &mut fresh),
        PushPresentation::Present
    );
}

// --- useIdleNotifications ----------------------------------------------------------------------

fn row(id: &str, status: &str, extra: &Value) -> SessionListItem {
    let mut value =
        json!({"id": id, "status": status, "created_at": 1, "title": format!("Title {id}")});
    if let (Some(object), Some(extra)) = (value.as_object_mut(), extra.as_object()) {
        object.extend(extra.clone());
    }
    serde_json::from_value(value).unwrap()
}

fn idle_view() -> ViewContext {
    ViewContext {
        active_session_id: Some("viewed".to_owned()),
        window_focused: true,
    }
}

#[test]
fn turn_end_notifies_only_after_the_idle_settle_window() {
    let view = idle_view();
    let mut tracker = AttentionTracker::new();
    let none = json!({});
    assert_eq!(
        tracker.observe(&[row("a", "running", &none)], &view, 0, true),
        []
    );
    assert_eq!(
        tracker.observe(&[row("a", "idle", &none)], &view, 1_000, true),
        []
    );
    assert_eq!(tracker.next_deadline_ms(), Some(1_000 + IDLE_SETTLE_MS));
    assert_eq!(tracker.due(&view, 1_000 + IDLE_SETTLE_MS - 1), []);
    let fired = tracker.due(&view, 1_000 + IDLE_SETTLE_MS);
    assert_eq!(
        fired,
        [AttentionNotification {
            session_id: "a".to_owned(),
            kind: NotificationKind::Completed,
            title: Some("Title a".to_owned()),
        }]
    );
    assert_eq!(fired[0].default_body(), IDLE_BODY);
    assert_eq!(tracker.next_deadline_ms(), None);

    // A second finish stays silent until the user views the session.
    tracker.observe(&[row("a", "running", &none)], &view, 20_000, true);
    tracker.observe(&[row("a", "failed", &none)], &view, 21_000, true);
    assert_eq!(tracker.next_deadline_ms(), None);
    let viewing_a = ViewContext {
        active_session_id: Some("a".to_owned()),
        window_focused: true,
    };
    tracker.observe(&[row("a", "failed", &none)], &viewing_a, 22_000, true);
    tracker.observe(&[row("a", "running", &none)], &view, 23_000, true);
    tracker.observe(&[row("a", "failed", &none)], &view, 24_000, true);
    let fired = tracker.due(&view, 24_000 + IDLE_SETTLE_MS);
    assert_eq!(fired.len(), 1);
    assert_eq!(fired[0].kind, NotificationKind::Failed);
}

#[test]
fn resuming_within_the_settle_window_cancels_the_turn_end() {
    let view = idle_view();
    let none = json!({});
    let mut tracker = AttentionTracker::new();
    tracker.observe(&[row("a", "running", &none)], &view, 0, true);
    tracker.observe(&[row("a", "idle", &none)], &view, 1_000, true);
    tracker.observe(&[row("a", "running", &none)], &view, 5_000, true);
    assert_eq!(tracker.next_deadline_ms(), None);
    tracker.observe(&[row("a", "idle", &none)], &view, 8_000, true);
    assert_eq!(tracker.due(&view, 1_000 + IDLE_SETTLE_MS), []);
    assert_eq!(tracker.due(&view, 8_000 + IDLE_SETTLE_MS).len(), 1);

    // A session that leaves the list drops its queued cue.
    tracker.observe(&[row("b", "running", &none)], &view, 30_000, true);
    tracker.observe(&[row("b", "idle", &none)], &view, 31_000, true);
    tracker.observe(&[], &view, 32_000, true);
    assert_eq!(tracker.due(&view, 60_000), []);
}

#[test]
fn new_elicitation_notifies_immediately_and_cancels_the_turn_end() {
    let view = idle_view();
    let mut tracker = AttentionTracker::new();
    let zero = json!({"pending_elicitations_count": 0});
    let one = json!({"pending_elicitations_count": 1});
    // Already-pending at first sight never notifies.
    assert_eq!(
        tracker.observe(&[row("a", "running", &one)], &view, 0, true),
        []
    );
    tracker.observe(&[row("a", "running", &zero)], &view, 1_000, true);
    tracker.observe(&[row("a", "idle", &zero)], &view, 2_000, true);
    assert!(tracker.next_deadline_ms().is_some());
    let fired = tracker.observe(&[row("a", "idle", &one)], &view, 3_000, true);
    assert_eq!(fired.len(), 1);
    assert_eq!(fired[0].kind, NotificationKind::Approval);
    assert_eq!(fired[0].default_body(), ELICITATION_BODY);
    assert_eq!(tracker.next_deadline_ms(), None);
    // A steady count or a decrease does not notify.
    assert_eq!(
        tracker.observe(&[row("a", "idle", &one)], &view, 4_000, true),
        []
    );
    assert_eq!(
        tracker.observe(&[row("a", "idle", &zero)], &view, 5_000, true),
        []
    );
}

#[test]
fn viewed_offline_archived_and_unpermitted_sessions_do_not_notify() {
    let none = json!({});
    let one = json!({"pending_elicitations_count": 1});
    let zero = json!({"pending_elicitations_count": 0});
    let cases = [
        ("viewed", none.clone(), zero.clone(), one.clone(), true),
        (
            "offline",
            json!({"runner_online": false}),
            json!({"runner_online": false, "pending_elicitations_count": 0}),
            json!({"runner_online": false, "pending_elicitations_count": 1}),
            true,
        ),
        (
            "archived",
            json!({"archived": true}),
            json!({"archived": true, "pending_elicitations_count": 0}),
            json!({"archived": true, "pending_elicitations_count": 1}),
            true,
        ),
        ("muted", none, zero, one, false),
    ];
    for (id, flags, before, after, can_notify) in cases {
        let view = idle_view();
        let mut tracker = AttentionTracker::new();
        tracker.observe(&[row(id, "running", &before)], &view, 0, can_notify);
        tracker.observe(&[row(id, "idle", &flags)], &view, 1_000, can_notify);
        assert_eq!(tracker.due(&view, 60_000), [], "{id}");
        assert_eq!(
            tracker.observe(&[row(id, "idle", &after)], &view, 61_000, can_notify),
            [],
            "{id}"
        );
    }
    // Opening the session during the settle window, or its runner dropping, cancels the cue.
    let view = idle_view();
    let none = json!({});
    let mut tracker = AttentionTracker::new();
    tracker.observe(
        &[row("a", "running", &none), row("b", "running", &none)],
        &view,
        0,
        true,
    );
    tracker.observe(
        &[row("a", "idle", &none), row("b", "idle", &none)],
        &view,
        1_000,
        true,
    );
    tracker.observe(
        &[
            row("a", "idle", &none),
            row("b", "idle", &json!({"runner_online": false})),
        ],
        &view,
        2_000,
        true,
    );
    let opened_a = ViewContext {
        active_session_id: Some("a".to_owned()),
        window_focused: true,
    };
    assert_eq!(tracker.due(&opened_a, 60_000), []);
}

#[test]
fn badge_counts_waiting_or_unseen_sessions_except_the_viewed_one() {
    let rows = [
        row("viewed", "idle", &json!({"pending_elicitations_count": 1})),
        row("waiting", "idle", &json!({"pending_elicitations_count": 2})),
        row("unseen", "idle", &json!({})),
        row("seen", "idle", &json!({})),
        row(
            "archived",
            "idle",
            &json!({"archived": true, "pending_elicitations_count": 1}),
        ),
    ];
    let ids = unread_badge_ids(&rows, &idle_view(), |row| row.id == "unseen");
    assert_eq!(ids.into_iter().collect::<Vec<_>>(), ["unseen", "waiting"]);
    let blurred = ViewContext {
        window_focused: false,
        ..idle_view()
    };
    assert_eq!(unread_badge_ids(&rows, &blurred, |_| false).len(), 2);
}
