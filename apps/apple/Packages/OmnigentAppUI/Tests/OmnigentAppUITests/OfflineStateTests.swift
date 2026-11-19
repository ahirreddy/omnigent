import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// What the transcript, the composer and the sidebar say while the server cannot be reached and
/// they show this device's saved copy.
@MainActor
@Suite("Offline state", .timeLimit(.minutes(1)))
struct OfflineStateTests {
  private func row(_ id: String, _ text: String) -> OmnigentCoreFFI.Row {
    OmnigentCoreFFI.Row(
      id: id, role: .assistant, text: text, isStreaming: false, activity: nil, attachments: [],
      callId: nil, responseId: nil, interrupted: false, author: nil, agent: nil,
      createdAt: nil, isEphemeral: false, isActivityOnly: false)
  }

  @Test("An offline session says it shows saved messages, on a quiet line, and can't send")
  func offlineSession() async throws {
    let store = try await ConversationFixtures.store(rows: [row("msg_1", "Saved")], hydrated: false)
    store.offlineChanged(true)
    #expect(ConversationAdapter.connectionStatus(store) == ConversationAdapter.offlineStatus)
    let notice = try #require(ComposerAdapter.connection(store))
    #expect(notice.message == ConversationAdapter.offlineStatus)
    #expect(notice.isOffline)
    #expect(!notice.isFailure)
    #expect(
      ComposerAdapter.availability(store)
        == .unavailable(reason: "Offline \u{2014} you can send once the server is back."))
    let screen = ConversationAdapter.screenState(store, summary: nil)
    #expect(screen.connectionStatus == ConversationAdapter.offlineStatus)
    #expect(!screen.isHydrating)

    store.offlineChanged(false)
    #expect(ConversationAdapter.connectionStatus(store) != ConversationAdapter.offlineStatus)
    #expect(ComposerAdapter.connection(store)?.isOffline != true)
  }

  @Test("An offline session with nothing saved says so instead of loading")
  func offlineWithNothingSaved() async throws {
    let store = try await ConversationFixtures.store(hydrated: false)
    #expect(ConversationAdapter.isHydrating(store))
    store.offlineChanged(true)
    #expect(!ConversationAdapter.isHydrating(store))
    #expect(ConversationAdapter.connectionStatus(store) == ConversationAdapter.offlineEmptyStatus)
  }

  @Test("The sidebar says its list is saved while offline, and the sessions show")
  func offlineSidebar() async throws {
    let connection = try await ConversationFixtures.connection()
    let session = ServerSession(connection: connection)
    #expect(SidebarAdapter.savedListNotice(connection) == nil)
    connection.apply(
      .connectionChanged(
        phase: .failed(serverUrl: "http://127.0.0.1:6767", error: .InvalidState(message: "x"))))
    connection.apply(.offlineChanged(serverUrl: "http://127.0.0.1:6767"))
    #expect(SidebarAdapter.savedListNotice(connection) == .offline(SidebarAdapter.offlineText))
    #expect(session.showsSessions)
    #expect(!session.isSignedIn)
    connection.apply(.offlineChanged(serverUrl: nil))
    #expect(SidebarAdapter.savedListNotice(connection) == nil)
    #expect(!session.showsSessions)
  }

  @Test(
    "A launch shows the saved sessions while it connects, marked as refreshing, until the server's")
  func savedListWhileConnecting() async throws {
    let connection = try await ConversationFixtures.connection()
    let session = ServerSession(connection: connection)
    let server = "http://127.0.0.1:6767"
    connection.apply(.connectionChanged(phase: .discovering(serverUrl: server)))
    #expect(!session.showsSessions)
    connection.apply(.savedListShown(serverUrl: server))
    let saved = ConversationFixtures.summary("saved")
    connection.apply(.sessionListChanged(change: .reset(sessions: [saved])))
    connection.apply(.sessionListLoaded)
    #expect(session.showsSessions)
    #expect(!session.isSignedIn)
    #expect(
      SidebarAdapter.savedListNotice(connection) == .refreshing(SidebarAdapter.refreshingText))
    #expect(connection.sessionList.visible.map(\.id) == ["saved"])

    // The connect ends at a sign-in screen: the saved list goes with the mark.
    connection.apply(.connectionChanged(phase: .disconnected))
    connection.apply(.savedListShown(serverUrl: nil))
    #expect(!session.showsSessions)
    #expect(SidebarAdapter.savedListNotice(connection) == nil)
    #expect(connection.sessionList.visible.isEmpty)
  }
}
