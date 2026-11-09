//! Demo tests, ported from `NativeLab`'s `DemoSessionClientTests`, `MobileCoreTests` (the demo
//! client and persistence rows) and `SessionConfigurationTests` (the demo configuration row).
//! Every operation runs through the real [`ClientCore`] over the [`DemoTransport`].

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::future::{Future, ready};
use std::sync::Arc;

use futures::executor::block_on;
use omnigent_protocol::{Field, ItemData, ItemStatus};

use super::*;
use crate::client::sessions::{SessionChange, SummaryStatus};
use crate::client::test_support::{DEBUG, record};
use crate::config::session::ConfigurationEdit;
use crate::creation::CreationSelection;
use crate::workspace_store::{WorkspaceStorage, WorkspaceStore, decode, encode};
use crate::{ClientCore, ClientEvent, ClientListener, SessionError};

fn demo_core(transport: DemoTransport) -> ClientCore<DemoTransport> {
    let core = ClientCore::new(transport, DEBUG);
    block_on(core.connect(demo_endpoint().unwrap(), None, None)).unwrap();
    core
}

fn sample() -> ClientCore<DemoTransport> {
    demo_core(DemoTransport::sample().unwrap())
}

fn selection() -> CreationSelection {
    CreationSelection {
        host_id: DEMO_HOST_ID.into(),
        agent_id: "demo-codex".into(),
        workspace: "/demo".into(),
        model: None,
        ..CreationSelection::default()
    }
}

fn create(core: &ClientCore<DemoTransport>, title: &str) -> String {
    block_on(core.create_session(&selection(), title))
        .unwrap()
        .session_id
}

fn send(
    core: &ClientCore<DemoTransport>,
    session_id: &str,
    text: &str,
) -> Result<(), SessionError> {
    core.set_live_session(session_id, true);
    block_on(core.send_message(session_id, text)).map(|_| ())
}

fn texts(session: &WorkspaceSession) -> Vec<String> {
    session
        .snapshot
        .items
        .iter()
        .map(|item| match &item.data {
            ItemData::Message(message) => message.visible_text(),
            other => format!("{other:?}"),
        })
        .collect()
}

fn streaming(session: &WorkspaceSession) -> usize {
    session
        .snapshot
        .items
        .iter()
        .filter(|item| item.status == Some(ItemStatus::InProgress))
        .count()
}

#[derive(Debug, Default)]
struct MemoryFile(RefCell<Option<Vec<u8>>>);

impl WorkspaceStorage for MemoryFile {
    fn read(&self) -> impl Future<Output = Result<Option<Vec<u8>>, WorkspaceError>> {
        ready(Ok(self.0.borrow().clone()))
    }

    fn write(&self, bytes: Vec<u8>) -> impl Future<Output = Result<(), WorkspaceError>> {
        *self.0.borrow_mut() = Some(bytes);
        ready(Ok(()))
    }
}

#[test]
fn initial_updates_include_every_session_and_new_sessions_are_published() {
    let core = sample();
    let ids: BTreeSet<String> = block_on(core.sessions())
        .unwrap()
        .into_iter()
        .map(|summary| summary.id)
        .collect();
    assert_eq!(
        ids,
        BTreeSet::from([
            "demo-design".into(),
            "demo-question".into(),
            "demo-notes".into()
        ])
    );
    let recorder = record(&core);
    let receipt = block_on(core.create_session(&selection(), "  A focused session  ")).unwrap();
    let created = receipt.summary.clone().unwrap();
    assert!(recorder.take().contains(&ClientEvent::SessionsChanged {
        sessions: vec![created.clone()]
    }));
    assert_eq!(created.title, "A focused session");
    assert_eq!(created.status, SummaryStatus::Idle);
    assert!(!created.is_read_only);
    let history = block_on(core.history_page(&receipt.session_id, None, 50)).unwrap();
    assert_eq!(history.items, []);
    assert_eq!(
        block_on(core.sessions())
            .unwrap()
            .first()
            .map(|s| s.id.clone()),
        Some(receipt.session_id.clone())
    );
    let second = create(&core, "\n ");
    assert_ne!(second, receipt.session_id);
    assert_eq!(
        block_on(core.conversation_snapshot(&second))
            .unwrap()
            .summary
            .title,
        DEFAULT_TITLE
    );
}

#[test]
fn send_constraints_leave_existing_state_unchanged() {
    let core = sample();
    let demo = core.transport();
    let notes = demo.session("demo-notes");
    assert_eq!(
        send(&core, "demo-notes", "Change these notes"),
        Err(SessionError::ReadOnly)
    );
    assert_eq!(demo.session("demo-notes"), notes);
    let design = demo.session("demo-design");
    assert_eq!(
        send(&core, "demo-design", "Continue"),
        Err(SessionError::Rejected {
            status: 409,
            message: "Respond to the pending request before sending a message.".into()
        })
    );
    assert_eq!(demo.session("demo-design"), design);
    let empty = create(&core, "Empty input");
    let before = demo.session(&empty);
    assert_eq!(
        send(&core, &empty, " \t\n "),
        Err(SessionError::EmptyMessage)
    );
    assert_eq!(demo.session(&empty), before);
}

#[test]
fn reply_streams_increasing_revisions_and_finishes_in_its_own_session() {
    let core = sample();
    let demo = core.transport();
    let created = create(&core, "Streaming");
    let untouched = demo.session("demo-notes");
    send(&core, &created, "  Hello from the phone  ").unwrap();
    let mut history = vec![demo.session(&created).unwrap()];
    while demo.is_replying() {
        let changed = demo.advance_replies();
        assert_eq!(changed, vec![created.clone()]);
        history.push(demo.session(&created).unwrap());
    }
    assert!(history.len() > 3);
    assert!(history.iter().any(|session| streaming(session) == 1));
    for pair in history.windows(2) {
        assert!(pair[0].revision < pair[1].revision);
    }
    let last = history.last().unwrap();
    assert_eq!(texts(last), ["Hello from the phone", DEMO_REPLY_TEXT]);
    assert_eq!(streaming(last), 0);
    let page = block_on(core.conversation_snapshot(&created)).unwrap();
    assert_eq!(page.summary.status, SummaryStatus::Idle);
    assert_eq!(page.items.len(), 2);
    assert_eq!(demo.session("demo-notes"), untouched);
}

#[test]
fn interrupt_cancels_reply_and_does_not_change_another_running_session() {
    let core = sample();
    let demo = core.transport();
    let first = create(&core, "First");
    let second = create(&core, "Second");
    send(&core, &first, "First prompt").unwrap();
    send(&core, &second, "Second prompt").unwrap();
    let second_before = demo.session(&second);
    assert_eq!(
        send(&core, &first, "Duplicate while running"),
        Err(SessionError::Rejected {
            status: 409,
            message: "Wait for the reply or stop it before sending another message.".into()
        })
    );
    block_on(core.interrupt(&first)).unwrap();
    let stopped = demo.session(&first).unwrap();
    assert_eq!(
        texts(&stopped).last().map(String::as_str),
        Some(REPLY_STOPPED)
    );
    assert_eq!(streaming(&stopped), 0);
    assert_eq!(
        block_on(core.conversation_snapshot(&first))
            .unwrap()
            .summary
            .status,
        SummaryStatus::Idle
    );
    assert_eq!(demo.session(&second), second_before);
    assert_eq!(
        block_on(core.conversation_snapshot(&second))
            .unwrap()
            .summary
            .status,
        SummaryStatus::Running
    );
    send(&core, &first, "Try again").unwrap();
    let restarted = demo.session(&first).unwrap();
    assert_eq!(restarted.snapshot.items.len(), 4);
    assert_eq!(restarted.snapshot.items[1], stopped.snapshot.items[1]);
    assert_ne!(restarted.snapshot.items[3].id, stopped.snapshot.items[1].id);
    block_on(core.interrupt(&first)).unwrap();
    block_on(core.interrupt(&second)).unwrap();
    let settled = demo.session(&first);
    block_on(core.interrupt(&first)).unwrap();
    assert_eq!(demo.session(&first), settled);
    assert_eq!(streaming(&settled.unwrap()), 0);
}

#[test]
fn cancelling_subscriber_removes_its_continuation() {
    #[derive(Debug)]
    struct Quiet;
    impl ClientListener for Quiet {
        fn on_event(&self, _: ClientEvent) {}
    }
    let core = sample();
    let id = core.subscribe(Arc::new(Quiet));
    assert_eq!(core.listener_count(), 1);
    assert!(core.unsubscribe(id));
    assert_eq!(core.listener_count(), 0);
    assert!(!core.unsubscribe(id));
}

#[test]
fn unknown_session_operations_fail_without_creating_state() {
    let core = sample();
    let before = core.transport().workspace(BTreeMap::new());
    let missing = || SessionError::SessionNotFound {
        session_id: "missing".into(),
    };
    assert_eq!(
        block_on(core.conversation_snapshot("missing")).unwrap_err(),
        missing()
    );
    assert_eq!(send(&core, "missing", "Hello"), Err(missing()));
    assert_eq!(block_on(core.interrupt("missing")), Err(missing()));
    assert_eq!(
        block_on(core.resolve_decision(
            "missing",
            "decision-design",
            &crate::decisions::DecisionResponse::Approve
        )),
        Err(missing())
    );
    assert_eq!(core.transport().workspace(BTreeMap::new()), before);
    assert_eq!(core.is_send_blocked("missing"), Ok(false));
}

#[test]
fn rename_pin_archive_restore_and_read_only_guards() {
    let core = sample();
    let demo = core.transport();
    let created = create(&core, "Original");
    let original = demo.session(&created).unwrap();
    demo.set_now(DEFAULT_NOW + 600);
    block_on(core.edit_session(&created, SessionChange::Title("  Renamed  ".into()))).unwrap();
    block_on(core.edit_session(
        &created,
        SessionChange::Pinned {
            pinned: true,
            at_ms: 1,
        },
    ))
    .unwrap();
    let archived = block_on(core.edit_session(
        &created,
        SessionChange::Archived {
            archived: true,
            delete_worktree: false,
        },
    ))
    .unwrap();
    assert_eq!(archived.title, "Renamed");
    assert!(archived.is_pinned);
    assert!(archived.is_archived);
    let saved = demo.session(&created).unwrap();
    assert_eq!(saved.revision, original.revision + 3);
    assert_eq!(saved.snapshot.updated_at, original.snapshot.updated_at);
    assert_eq!(
        send(&core, &created, "No hidden sends"),
        Err(SessionError::Archived)
    );
    let restored = block_on(core.edit_session(
        &created,
        SessionChange::Archived {
            archived: false,
            delete_worktree: false,
        },
    ))
    .unwrap();
    assert!(!restored.is_archived);
    for change in [
        SessionChange::Title("New".into()),
        SessionChange::Archived {
            archived: true,
            delete_worktree: false,
        },
    ] {
        assert_eq!(
            block_on(core.edit_session("demo-notes", change)),
            Err(SessionError::ReadOnly)
        );
    }
    // A viewer may pin, as on the real server (NativeLab's demo refused it).
    assert!(
        block_on(core.edit_session(
            "demo-notes",
            SessionChange::Pinned {
                pinned: true,
                at_ms: 2
            }
        ))
        .unwrap()
        .is_pinned
    );
}

#[test]
fn invalid_rename_does_not_mutate_session() {
    let core = sample();
    let before = core.transport().session("demo-design");
    for title in [" \n ".to_owned(), "x".repeat(121)] {
        assert_eq!(
            block_on(core.edit_session("demo-design", SessionChange::Title(title))),
            Err(SessionError::InvalidTitle)
        );
    }
    assert_eq!(core.transport().session("demo-design"), before);
}

#[test]
fn persistence_round_trips_organization_and_exact_drafts() {
    let store = WorkspaceStore::new(MemoryFile::default());
    assert_eq!(block_on(store.load()), Ok(None));
    let core = sample();
    block_on(core.edit_session("demo-design", SessionChange::Title("Mobile review".into())))
        .unwrap();
    block_on(core.edit_session(
        "demo-design",
        SessionChange::Archived {
            archived: true,
            delete_worktree: false,
        },
    ))
    .unwrap();
    let snapshot = core.transport().session("demo-design").unwrap();
    let drafts = BTreeMap::from([
        (
            "demo-design".to_owned(),
            "  First line\n\n日本語 👋\n".to_owned(),
        ),
        ("another".to_owned(), "Separate".to_owned()),
    ]);
    let workspace = Workspace::new(vec![snapshot.clone()], drafts);
    block_on(store.save(&workspace)).unwrap();
    let loaded = block_on(store.load()).unwrap().unwrap();
    assert_eq!(loaded, workspace);
    assert_eq!(decode(&encode(&workspace).unwrap()), Ok(workspace));
    let restarted = demo_core(DemoTransport::new(loaded));
    assert_eq!(restarted.transport().session("demo-design"), Some(snapshot));
    let page = block_on(restarted.conversation_snapshot("demo-design")).unwrap();
    assert_eq!(page.summary.title, "Mobile review");
    assert!(page.summary.is_archived);
}

#[test]
fn restart_does_not_reuse_message_or_session_i_ds() {
    let first = sample();
    let session = create(&first, "Before relaunch");
    send(&first, &session, "One").unwrap();
    block_on(first.interrupt(&session)).unwrap();
    let saved = first.transport().workspace(BTreeMap::new());
    let before = Workspace::new(
        saved
            .sessions
            .into_iter()
            .filter(|candidate| candidate.snapshot.id == session)
            .collect(),
        BTreeMap::new(),
    );
    let second = demo_core(DemoTransport::new(before));
    send(&second, &session, "Two").unwrap();
    block_on(second.interrupt(&session)).unwrap();
    let after = second.transport().session(&session).unwrap();
    assert_eq!(after.snapshot.items.len(), 4);
    let unique: BTreeSet<&str> = after
        .snapshot
        .items
        .iter()
        .map(|item| item.id.as_str())
        .collect();
    assert_eq!(unique.len(), 4);
    let another = create(&second, "After relaunch");
    assert_ne!(another, session);
}

#[test]
fn demo_upgrade_and_new_sessions_publish_reported_configuration() {
    let original = sample_workspace().unwrap().sessions[0].clone();
    assert!(original.snapshot.harness.is_absent());
    let core = demo_core(DemoTransport::new(Workspace::new(
        vec![original.clone()],
        BTreeMap::new(),
    )));
    assert_eq!(
        core.transport().revision(&original.snapshot.id),
        Some(original.revision + 1)
    );
    let upgraded = block_on(core.conversation_snapshot(&original.snapshot.id)).unwrap();
    assert_eq!(upgraded.summary.configuration, Some(demo_configuration()));
    let created = block_on(core.create_session(&selection(), "Configuration test")).unwrap();
    let summary = created.summary.unwrap();
    assert_eq!(summary.configuration, Some(demo_configuration()));
    let items_before = core
        .transport()
        .session(&created.session_id)
        .unwrap()
        .snapshot
        .items;
    let mut edit = ConfigurationEdit::new(demo_configuration());
    edit.select_model(Some("sample-fast".into()));
    core.set_live_session(&created.session_id, true);
    let configured = block_on(core.apply_configuration(&edit, &created.session_id)).unwrap();
    assert_eq!(
        configured.configuration.unwrap().model_override.as_deref(),
        Some("sample-fast")
    );
    assert_eq!(
        core.transport()
            .session(&created.session_id)
            .unwrap()
            .snapshot
            .items,
        items_before
    );
}

#[test]
fn demo_decisions_resolve_through_the_client() {
    let core = sample();
    block_on(core.resolve_decision(
        "demo-question",
        "decision-question",
        &crate::decisions::DecisionResponse::Answer("Approvals first".into()),
    ))
    .unwrap();
    let question = block_on(core.conversation_snapshot("demo-question")).unwrap();
    assert_eq!(question.decisions, []);
    assert_eq!(question.summary.status, SummaryStatus::Idle);
    block_on(core.resolve_decision(
        "demo-design",
        "decision-design",
        &crate::decisions::DecisionResponse::Approve,
    ))
    .unwrap();
    assert_eq!(
        core.transport()
            .session("demo-design")
            .unwrap()
            .snapshot
            .pending_elicitations,
        []
    );
}

#[test]
fn demo_harness_switch_and_catalog_routes() {
    let core = sample();
    let workspaces = block_on(core.creation_workspaces(DEMO_HOST_ID)).unwrap();
    assert_eq!(workspaces.len(), 1);
    let models = block_on(core.creation_models("demo-codex", DEMO_HOST_ID)).unwrap();
    assert_eq!(models.len(), 2);
    let created = create(&core, "Switch");
    core.set_live_session(&created, true);
    let switched =
        block_on(core.switch_harness("demo-claude", &demo_configuration(), &created)).unwrap();
    let configuration = switched.configuration.unwrap();
    assert_eq!(configuration.harness.as_deref(), Some("claude-native"));
    assert_eq!(
        configuration.wrapper.as_deref(),
        Some("claude-code-native-ui")
    );
}

#[test]
fn the_demo_design_approval_lists_the_files_its_patch_changes() {
    use crate::decisions::FileChangeKind;

    let core = sample();
    let design = block_on(core.conversation_snapshot("demo-design")).unwrap();
    let card = &design.decisions[0];
    assert_eq!(
        card.message.as_deref().map(|m| m.lines().next()),
        Some(Some("Apply the sample design?"))
    );
    let files: Vec<_> = card
        .permissions
        .file_changes
        .iter()
        .map(|file| {
            (
                file.path.as_str(),
                file.kind,
                file.lines_added,
                file.lines_removed,
            )
        })
        .collect();
    assert_eq!(
        files,
        [
            (
                "Omni/iOS/SessionRow.swift",
                Some(FileChangeKind::Modify),
                Some(4),
                Some(1)
            ),
            (
                "Omni/iOS/AttentionSection.swift",
                Some(FileChangeKind::Create),
                Some(11),
                Some(0)
            ),
        ]
    );
    assert!(
        card.tool_input
            .as_deref()
            .unwrap()
            .starts_with("apply_patch({\n  \"changes\":[")
    );
}

#[test]
fn the_demo_keeps_the_viewers_read_state() {
    let core = sample();
    let rows = |core: &ClientCore<DemoTransport>| block_on(core.sessions()).unwrap();
    let design = |rows: Vec<crate::client::sessions::SessionSummary>| {
        rows.into_iter()
            .find(|row| row.id == "demo-design")
            .unwrap()
    };
    let read = design(rows(&core)).viewer_read;
    assert_eq!(
        read,
        Some(crate::client::sessions::ViewerRead {
            last_seen: None,
            unread: false
        })
    );
    let mark = crate::read_state::ReadMark {
        session_id: "demo-design".into(),
        last_seen: DEFAULT_NOW + 5,
        unread: false,
    };
    block_on(core.put_read_state(&mark)).unwrap();
    assert_eq!(
        design(rows(&core)).viewer_read,
        Some(crate::client::sessions::ViewerRead {
            last_seen: Some(DEFAULT_NOW + 5),
            unread: false
        })
    );
    let missing = crate::read_state::ReadMark {
        session_id: "missing".into(),
        ..mark
    };
    assert!(matches!(
        block_on(core.put_read_state(&missing)),
        Err(SessionError::Rejected { status: 404, .. })
    ));
}

#[test]
fn a_file_queued_while_the_demo_replies_sends_after_the_reply() {
    let core = sample();
    let demo = core.transport();
    let created =
        block_on(core.create_session_and_send(&selection(), "Files", "Plan it in detail"))
            .unwrap()
            .receipt
            .session_id;
    core.set_live_session(&created, true);
    assert!(demo.is_replying());
    let file =
        crate::attachments::UploadFile::new("plan.txt", Some("text/plain"), b"notes".to_vec())
            .unwrap();
    let item = core.add_attachment(&created, file).unwrap();
    block_on(core.upload_attachment(&created, item, "boundary")).unwrap();
    let (hold, _) = core.hold_attachments(&created).unwrap().unwrap();
    while demo.is_replying() {
        demo.advance_replies();
    }
    block_on(core.send_queued_message(&created, "see the plan", Some(hold), None, &[])).unwrap();
    let session = demo.session(&created).unwrap();
    let sent = session
        .snapshot
        .items
        .iter()
        .find_map(|item| match &item.data {
            ItemData::Message(message) if message.content.len() == 2 => {
                Some(message.visible_text())
            }
            _ => None,
        });
    assert_eq!(sent.as_deref(), Some("see the plan"));
}

#[test]
fn asking_for_detail_streams_the_longer_reply() {
    let core = sample();
    let demo = core.transport();
    let created = create(&core, "Detail");
    send(&core, &created, "Explain it In Detail").unwrap();
    let mut ticks = 0;
    while demo.is_replying() {
        demo.advance_replies();
        ticks += 1;
    }
    assert!(
        ticks > 60,
        "long enough to queue a follow-up while it streams"
    );
    let session = demo.session(&created).unwrap();
    assert_eq!(texts(&session).last().unwrap(), DEMO_DETAILED_REPLY_TEXT);
}

#[test]
fn a_session_launches_in_the_chosen_approval_mode() {
    let core = sample();
    let chosen = CreationSelection {
        agent_id: "demo-claude".into(),
        approval_mode: Some("acceptEdits".into()),
        ..selection()
    };
    let created = block_on(core.create_session(&chosen, "Mode")).unwrap();
    let transport = core.transport();
    let snapshot = transport.session(&created.session_id).unwrap().snapshot;
    assert_eq!(
        snapshot.terminal_launch_args.value().cloned(),
        Some(vec![
            "--permission-mode".to_owned(),
            "acceptEdits".to_owned()
        ])
    );
}

#[test]
fn a_running_session_switches_approval_mode_through_its_label() {
    let transport = DemoTransport::sample().unwrap();
    let request = HttpRequest {
        method: "PATCH".into(),
        url: format!("{DEMO_SERVER_URL}/v1/sessions/demo-design"),
        headers: Vec::new(),
        body: Some(br#"{"approval_mode":"full-access"}"#.to_vec()),
    };
    assert_eq!(block_on(transport.send(request)).unwrap().status, 200);
    let snapshot = transport.session("demo-design").unwrap().snapshot;
    assert_eq!(
        snapshot.labels.value().unwrap().get(APPROVAL_MODE_LABEL),
        Some(&"full-access".to_owned())
    );
}

#[test]
fn only_the_owner_deletes_a_session() {
    let core = sample();
    let notes = block_on(core.delete_session("demo-notes"));
    assert!(notes.is_err(), "a read-only session was deleted");
    block_on(core.delete_session("demo-design")).unwrap();
    let demo = core.transport();
    assert!(demo.session("demo-design").is_none());
    assert!(demo.session("demo-notes").is_some());
}

/// A raw request to the demo server, as the client would make it.
fn raw(transport: &DemoTransport, method: &str, path: &str, body: Option<&Value>) -> (u16, Value) {
    let response = transport.handle(&HttpRequest {
        method: method.to_owned(),
        url: format!("https://demo.invalid{path}"),
        headers: Vec::new(),
        body: body.map(|body| serde_json::to_vec(body).unwrap()),
    });
    (
        response.status,
        serde_json::from_slice(&response.body).unwrap(),
    )
}

fn first_session_id(transport: &DemoTransport) -> String {
    let (status, listed) = raw(transport, "GET", "/v1/sessions", None);
    assert_eq!(status, 200);
    listed["data"][0]["id"].as_str().unwrap().to_owned()
}

/// A demo server whose only sessions are the sample, with `permission_level` set on all of them.
fn at_permission(level: i64) -> DemoTransport {
    let transport = DemoTransport::sample().unwrap();
    for session in &mut transport.lock().sessions {
        session.snapshot.permission_level = Field::Present(level);
    }
    transport
}

#[test]
fn the_demo_server_refuses_what_a_real_server_refuses() {
    let transport = DemoTransport::sample().unwrap();
    let id = first_session_id(&transport);
    let session = format!("/v1/sessions/{id}");
    let events = format!("{session}/events");
    let cases = [
        ("GET", "/v1/nope".to_owned(), None, 404),
        ("PATCH", session.clone(), Some(json!({"nope": 1})), 422),
        ("PATCH", session.clone(), Some(json!([])), 422),
        ("PATCH", session.clone(), Some(json!({"labels": 7})), 422),
        (
            "PATCH",
            session.clone(),
            Some(json!({"labels": {"a": 7}})),
            422,
        ),
        ("PATCH", session, Some(json!({"model_override": 7})), 422),
        ("POST", events.clone(), Some(json!({"type": "nope"})), 400),
        ("POST", events, Some(json!({})), 400),
        (
            "POST",
            "/v1/sessions".to_owned(),
            Some(json!({"agent_id": "demo-codex", "host_id": "someone-else"})),
            400,
        ),
    ];
    for (method, path, body, status) in cases {
        assert_eq!(
            raw(&transport, method, &path, body.as_ref()).0,
            status,
            "{method} {path} {body:?}"
        );
    }
}

#[test]
fn the_demo_server_answers_invalid_json_and_a_bad_url() {
    let transport = DemoTransport::sample().unwrap();
    let id = first_session_id(&transport);
    let response = transport.handle(&HttpRequest {
        method: "PATCH".to_owned(),
        url: format!("https://demo.invalid/v1/sessions/{id}"),
        headers: Vec::new(),
        body: Some(b"{not json".to_vec()),
    });
    assert_eq!(response.status, 400);
    let response = transport.handle(&HttpRequest {
        method: "GET".to_owned(),
        url: "not a url".to_owned(),
        headers: Vec::new(),
        body: None,
    });
    assert_eq!(response.status, 400);
}

#[test]
fn each_permission_level_gets_only_what_it_may_do() {
    let viewer = at_permission(0);
    let id = first_session_id(&viewer);
    let session = format!("/v1/sessions/{id}");
    let decision = format!("{session}/elicitations/decision_1/resolve");
    let writes = [
        ("PATCH", session.clone(), json!({"title": "x"})),
        ("DELETE", session.clone(), Value::Null),
        (
            "POST",
            format!("{session}/events"),
            json!({"type": "interrupt"}),
        ),
        ("POST", decision, json!({"action": "accept"})),
        (
            "POST",
            format!("{session}/switch-agent"),
            json!({"agent_id": "demo-claude"}),
        ),
    ];
    for (method, path, body) in writes {
        assert_eq!(
            raw(&viewer, method, &path, Some(&body)).0,
            403,
            "{method} {path}"
        );
    }
    let editor = at_permission(2);
    assert_eq!(
        raw(&editor, "PATCH", &session, Some(&json!({"archived": true}))).0,
        403,
        "archiving belongs to the owner"
    );
    assert_eq!(raw(&editor, "DELETE", &session, None).0, 403);
}

#[test]
fn the_session_list_and_items_page_after_a_cursor() {
    let transport = DemoTransport::sample().unwrap();
    let (_, listed) = raw(&transport, "GET", "/v1/sessions?limit=1", None);
    assert_eq!(listed["data"].as_array().unwrap().len(), 1);
    assert_eq!(listed["has_more"], json!(true));
    let last = listed["last_id"].as_str().unwrap();
    let (_, next) = raw(
        &transport,
        "GET",
        &format!("/v1/sessions?after={last}&limit=100"),
        None,
    );
    assert!(
        next["data"]
            .as_array()
            .unwrap()
            .iter()
            .all(|row| row["id"] != json!(last)),
        "the cursor row is not repeated"
    );
    assert_eq!(next["has_more"], json!(false));
    let (_, gone) = raw(&transport, "GET", "/v1/sessions?after=sess_missing", None);
    assert_eq!(gone["data"], json!([]), "an unknown cursor ends the list");

    let id = first_session_id(&transport);
    let items = format!("/v1/sessions/{id}/items");
    let (_, page) = raw(&transport, "GET", &format!("{items}?limit=1"), None);
    let first = page["data"][0]["id"].as_str().unwrap();
    let (_, rest) = raw(
        &transport,
        "GET",
        &format!("{items}?after={first}&limit=100"),
        None,
    );
    assert!(
        rest["data"]
            .as_array()
            .unwrap()
            .iter()
            .all(|row| row["id"] != json!(first))
    );
    let (_, none) = raw(
        &transport,
        "GET",
        &format!("{items}?after=item_missing"),
        None,
    );
    assert_eq!(none["data"], json!([]));
}

#[test]
fn the_demo_server_answers_the_read_routes_for_a_session() {
    let transport = DemoTransport::sample().unwrap();
    let id = first_session_id(&transport);
    let (status, agent) = raw(&transport, "GET", &format!("/v1/sessions/{id}/agent"), None);
    assert_eq!(status, 200);
    assert_eq!(agent["terminals"], json!([]));
    let changes = format!("/v1/sessions/{id}/resources/environments/env/changes");
    assert_eq!(
        raw(&transport, "GET", &changes, None).1,
        json!({"entries": []})
    );
    let missing = "/v1/sessions/sess_missing/resources/environments/env/changes";
    assert_eq!(raw(&transport, "GET", missing, None).0, 404);
    assert_eq!(
        raw(&transport, "GET", "/v1/sessions/sess_missing/agent", None).0,
        404
    );
}

#[test]
fn patching_labels_and_overrides_clears_and_sets() {
    let transport = DemoTransport::sample().unwrap();
    let id = first_session_id(&transport);
    let session = format!("/v1/sessions/{id}");
    let (_, set) = raw(
        &transport,
        "PATCH",
        &session,
        Some(&json!({"labels": {"note": "x"}})),
    );
    assert_eq!(set["labels"]["note"], json!("x"));
    let (_, cleared) = raw(
        &transport,
        "PATCH",
        &session,
        Some(&json!({"labels": {"note": ""}})),
    );
    assert_eq!(cleared["labels"].get("note"), None);

    let (_, model) = raw(
        &transport,
        "PATCH",
        &session,
        Some(&json!({"model_override": "m1"})),
    );
    assert_eq!(model["model_override"], json!("m1"));
    for clearing in [json!("default"), json!("off"), json!("reset"), Value::Null] {
        raw(
            &transport,
            "PATCH",
            &session,
            Some(&json!({"model_override": "m1"})),
        );
        let (status, cleared) = raw(
            &transport,
            "PATCH",
            &session,
            Some(&json!({"model_override": clearing})),
        );
        assert_eq!(status, 200);
        assert_eq!(cleared["model_override"], Value::Null);
    }
    let (_, mode) = raw(
        &transport,
        "PATCH",
        &session,
        Some(&json!({"permission_mode": "plan"})),
    );
    assert_eq!(mode["labels"][PERMISSION_MODE_LABEL], json!("plan"));
}

#[test]
fn an_empty_message_is_refused() {
    let transport = DemoTransport::sample().unwrap();
    let (_, created) = raw(
        &transport,
        "POST",
        "/v1/sessions",
        Some(&json!({"agent_id": "demo-codex", "host_id": DEMO_HOST_ID})),
    );
    let events = format!("/v1/sessions/{}/events", created["id"].as_str().unwrap());
    let empty = json!({"type": "message", "content": [{"type": "input_text", "text": ""}]});
    assert_eq!(raw(&transport, "POST", &events, Some(&empty)).0, 400);
}

#[test]
fn an_archived_session_refuses_a_message() {
    let transport = DemoTransport::sample().unwrap();
    let id = first_session_id(&transport);
    raw(
        &transport,
        "PATCH",
        &format!("/v1/sessions/{id}"),
        Some(&json!({"archived": true})),
    );
    let (status, body) = raw(
        &transport,
        "POST",
        &format!("/v1/sessions/{id}/events"),
        Some(&json!({"type": "message", "content": [{"type": "input_text", "text": "hi"}]})),
    );
    assert_eq!(status, 409);
    assert!(
        body["detail"].as_str().unwrap().contains("Restore"),
        "{body}"
    );
}

#[test]
fn creating_with_a_model_and_a_harness_keeps_them() {
    let transport = DemoTransport::sample().unwrap();
    let (status, created) = raw(
        &transport,
        "POST",
        "/v1/sessions",
        Some(&json!({
            "agent_id": "demo-claude",
            "host_id": DEMO_HOST_ID,
            "title": "  Trim me  ",
            "model_override": "m1",
        })),
    );
    assert_eq!(status, 201);
    assert_eq!(created["model_override"], json!("m1"));
    assert_eq!(created["harness"], json!("claude-native"));
    assert_eq!(
        created["labels"]["omnigent.wrapper"],
        json!("claude-code-native-ui")
    );
    let (_, switched) = raw(
        &transport,
        "POST",
        &format!(
            "/v1/sessions/{}/switch-agent",
            created["id"].as_str().unwrap()
        ),
        Some(&json!({"agent_id": "demo-codex"})),
    );
    assert_eq!(
        switched["labels"]["omnigent.wrapper"],
        json!("codex-native-ui")
    );
}

#[test]
fn the_catalog_lists_the_demo_host_and_agents() {
    let catalog = demo_catalog();
    assert_eq!(
        catalog
            .agents
            .iter()
            .map(|agent| agent.id.as_str())
            .collect::<Vec<_>>(),
        ["demo-codex", "demo-claude"]
    );
    assert_eq!(catalog.host.unwrap().host_id, DEMO_HOST_ID);
}

#[test]
fn a_broken_fixture_is_a_workspace_error() {
    for text in [
        "{",
        "{}",
        r#"{"session": {}}"#,
        r#"{"session": {"updatedAt": 1}}"#,
    ] {
        assert!(
            matches!(fixture_session(text), Err(WorkspaceError::Corrupt { .. })),
            "{text}"
        );
    }
}

#[test]
fn a_reply_whose_session_or_item_disappeared_stops_streaming() {
    let core = sample();
    let session = create(&core, "One");
    send(&core, &session, "hello").unwrap();
    let transport = core.transport();
    assert!(transport.is_replying());
    let mut state = transport.lock();
    let reply_item = state.replies.values().next().unwrap().item_id.clone();
    state
        .sessions
        .iter_mut()
        .find(|row| row.snapshot.id == session)
        .unwrap()
        .snapshot
        .items
        .retain(|item| item.id != reply_item);
    drop(state);
    assert_eq!(transport.advance_replies(), Vec::<String>::new());
    assert!(!transport.is_replying());

    send(&core, &create(&core, "Two"), "hello").unwrap();
    assert!(transport.is_replying());
    transport.lock().sessions.clear();
    assert_eq!(transport.advance_replies(), Vec::<String>::new());
    assert!(!transport.is_replying());
}

#[test]
fn a_decision_answer_is_checked_against_its_schema() {
    let transport = DemoTransport::sample().unwrap();
    let id = transport
        .lock()
        .sessions
        .iter()
        .find(|session| !session.snapshot.pending_elicitations.is_empty())
        .map(|session| session.snapshot.id.clone())
        .unwrap();
    let decision = transport
        .session(&id)
        .unwrap()
        .snapshot
        .pending_elicitations[0]
        .elicitation_id
        .clone();
    let route = format!("/v1/sessions/{id}/elicitations/{decision}/resolve");
    for refused in [json!({}), json!({"action": "other"})] {
        assert_eq!(
            raw(&transport, "POST", &route, Some(&refused)).0,
            422,
            "{refused}"
        );
    }
    assert_eq!(
        raw(
            &transport,
            "POST",
            &route,
            Some(&json!({"action": "decline"}))
        )
        .0,
        202
    );
    assert_eq!(
        raw(
            &transport,
            "POST",
            &route,
            Some(&json!({"action": "decline"}))
        )
        .0,
        404,
        "a second answer finds it gone"
    );
}

#[test]
fn workspace_ids_list_every_session_and_item() {
    let workspace = sample_workspace().unwrap();
    let sessions = session_ids(&workspace);
    assert_eq!(sessions.len(), workspace.sessions.len());
    assert!(sessions.contains(&workspace.sessions[0].snapshot.id));
    let items = item_ids(&workspace);
    let total: usize = workspace
        .sessions
        .iter()
        .map(|session| session.snapshot.items.len())
        .sum();
    assert_eq!(items.len(), total, "item ids never collide across sessions");
}

#[test]
fn a_blank_message_with_nothing_attached_is_refused() {
    let transport = DemoTransport::sample().unwrap();
    let (_, created) = raw(
        &transport,
        "POST",
        "/v1/sessions",
        Some(&json!({"agent_id": "demo-codex", "host_id": DEMO_HOST_ID})),
    );
    let events = format!("/v1/sessions/{}/events", created["id"].as_str().unwrap());
    let blank =
        json!({"type": "message", "data": {"content": [{"type": "input_text", "text": "  "}]}});
    let (status, body) = raw(&transport, "POST", &events, Some(&blank));
    assert_eq!(status, 400);
    assert!(
        body["detail"].as_str().unwrap().contains("Write a message"),
        "{body}"
    );
}

#[test]
fn accepting_a_decision_with_no_fields_takes_no_content() {
    let transport = DemoTransport::sample().unwrap();
    let found = transport.lock().sessions.iter_mut().find_map(|session| {
        let pending = session.snapshot.pending_elicitations.first_mut()?;
        pending.params.requested_schema =
            serde_json::from_value(json!({"properties": {}})).unwrap();
        Some((session.snapshot.id.clone(), pending.elicitation_id.clone()))
    });
    let (id, decision) = found.unwrap();
    let route = format!("/v1/sessions/{id}/elicitations/{decision}/resolve");
    let extra = json!({"action": "accept", "content": {"name": "x"}});
    assert_eq!(raw(&transport, "POST", &route, Some(&extra)).0, 422);
    let plain = json!({"action": "accept"});
    assert_eq!(raw(&transport, "POST", &route, Some(&plain)).0, 202);
}

#[test]
fn a_session_that_does_not_encode_to_an_object_is_a_server_error() {
    let not_json = serde_json::from_str::<Value>("{").unwrap_err();
    for encoded in [Err(not_json), Ok(Value::Null)] {
        let Err(Reject(status, detail)) = encoded_fields(encoded) else {
            panic!("expected a rejection");
        };
        assert_eq!((status, detail), (500, "Could not encode the session"));
    }
}

#[test]
fn labels_that_are_not_an_object_are_a_server_error_and_missing_ones_are_created() {
    let mut object = Map::new();
    labels_mut(&mut object)
        .unwrap()
        .insert("a".into(), json!("b"));
    assert_eq!(Value::Object(object), json!({"labels": {"a": "b"}}));
    let mut broken = Map::from_iter([("labels".to_owned(), json!(3))]);
    let Err(Reject(status, detail)) = labels_mut(&mut broken) else {
        panic!("expected a rejection");
    };
    assert_eq!((status, detail), (500, "labels are not an object"));
}

#[test]
fn a_word_only_goes_onto_a_message() {
    let mut item = ConversationItem::from_parts("i1", "reasoning", Map::new(), None).unwrap();
    let before = item.clone();
    append_word(&mut item, "word");
    assert_eq!(item, before);
}

#[test]
fn a_list_row_adds_the_viewer_fields_and_leaves_a_non_object_alone() {
    assert_eq!(list_row(Value::Null, 2, None), Value::Null);
    assert_eq!(
        list_row(
            json!({"id": "a", "items": [], "pending_elicitations": []}),
            2,
            Some(&(9, true))
        ),
        json!({
            "id": "a",
            "pending_elicitations_count": 2,
            "viewer_last_seen": 9,
            "viewer_unread": true,
        })
    );
}
