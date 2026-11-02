//! Demo tests, ported from `NativeLab`'s `DemoSessionClientTests`, `MobileCoreTests` (the demo
//! client and persistence rows) and `SessionConfigurationTests` (the demo configuration row).
//! Every operation runs through the real [`ClientCore`] over the [`DemoTransport`].

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::future::{Future, ready};
use std::sync::Arc;

use futures::executor::block_on;
use omnigent_protocol::{ItemData, ItemStatus};

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
    let archived = block_on(core.edit_session(&created, SessionChange::Archived(true))).unwrap();
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
    let restored = block_on(core.edit_session(&created, SessionChange::Archived(false))).unwrap();
    assert!(!restored.is_archived);
    for change in [
        SessionChange::Title("New".into()),
        SessionChange::Archived(true),
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
    block_on(core.edit_session("demo-design", SessionChange::Archived(true))).unwrap();
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
