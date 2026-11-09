import Foundation
import OmnigentCoreFFI
import OmnigentRemoteBrowser
import OmnigentTerminalUI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Synchronization
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores
@testable import OmnigentTerminalStores

/// A remote browser that hands its listener to the test, which then says what the tab is doing.
nonisolated private final class ScriptedRemoteBrowser: RemoteBrowserConnecting, Sendable {
  private let base = FixtureRemoteBrowser(latency: .milliseconds(1))
  let listener = Mutex<(any RemoteBrowserListener)?>(nil)

  func profiles(sessionID: String) async throws -> [RemoteBrowserProfile] {
    try await base.profiles(sessionID: sessionID)
  }

  func createTab(sessionID: String, url: String?, profile: String?) async throws
    -> RemoteBrowserTab
  {
    try await base.createTab(sessionID: sessionID, url: url, profile: profile)
  }

  func closeTab(sessionID: String, tabID: String) async throws {
    try await base.closeTab(sessionID: sessionID, tabID: tabID)
  }

  func attach(
    sessionID: String, tabID: String, mode: RemoteBrowserMode, hostID: String?,
    listener: any RemoteBrowserListener
  ) -> any RemoteBrowserDriverProtocol {
    self.listener.withLock { $0 = listener }
    return base.attach(
      sessionID: sessionID, tabID: tabID, mode: mode, hostID: hostID, listener: listener)
  }
}

/// What a session's tabs say about themselves on the strip, and what their pages show.
@MainActor
@Suite("Session tab details", .serialized, .timeLimit(.minutes(1)))
struct SessionTabDetailsTests {
  private func session(
    _ server: AppServer = threeSessionServer(), remote: (any RemoteBrowserConnecting)? = nil
  ) async throws -> ServerSession {
    SystemSideEffects.install()
    let connection = try await signedInStore(server)
    try await eventually("the session list") { connection.sessionList.isLoaded }
    return ServerSession(
      connection: connection, opener: ExternalURLOpener { _ in true }, remoteBrowser: remote)
  }

  @Test("A chat tab's tooltip is its session's status line; other tabs have none")
  func statusDetails() async throws {
    let session = try await session()
    session.tabs.show(.session("conv_a"))
    session.open("conv_a")
    let store = try #require(session.tabs.current)
    let chat = try #require(store.selected)
    let shell = store.open(.terminal(sessionID: "conv_a", terminalID: "t"))
    let details = TabAdapter.statusDetails(session)
    #expect(details.detail(of: chat.id) != nil)
    #expect(details.detail(of: shell.id) == nil)
    #expect(details.detail(of: "gone") == nil)
  }

  @Test("A side chat's tab shows it working while its session runs")
  func sideChatTabRuns() async throws {
    let session = try await session()
    session.open("conv_b")
    let conversation = try #require(session.connection.conversations["conv_b"])
    conversation.apply(
      revision: 1,
      change: TranscriptChange(
        rows: [],
        header: SessionHeader(
          id: "conv_b", title: "B", status: .running, readOnly: false, archived: false,
          permissionLevel: 4, failureMessage: nil, settings: ConversationFixtures.settings()),
        sections: []))
    let tab = AppTab(content: .sideChatSession(parentID: "conv_a", childID: "conv_b"))
    #expect(TabAdapter.item(tab, session: session, browser: nil).status == .running)
    let idle = AppTab(content: .sideChatSession(parentID: "conv_a", childID: nil))
    #expect(TabAdapter.item(idle, session: session, browser: nil).status == .none)
  }

  @Test("A remote tab's status follows its connection")
  func remoteStatuses() async throws {
    let remote = ScriptedRemoteBrowser()
    let session = try await session(remote: remote)
    let registry = try #require(session.remoteBrowsers)
    let store = registry.store(sessionID: "conv_a", tabID: "tab_1", record: nil)
    registry.attach(store, mode: .control, hostID: "mac")
    let listener = try #require(remote.listener.withLock { $0 })
    // The fixture reports first that it has no such tab; the script speaks after that.
    try await eventually("the first state") { store.isEnded }
    let tab = AppTab(content: .remoteBrowser(sessionID: "conv_a", tabID: "tab_1"))

    var snapshot = RemoteBrowserSnapshot.initial(url: "https://a.example/", profile: "work")
    snapshot.nav?.title = "A"
    snapshot.nav?.loading = true
    listener.onState(snapshot: snapshot)
    try await eventually("loading") {
      TabAdapter.item(tab, session: session, browser: nil).status == .loading
    }
    #expect(TabAdapter.item(tab, session: session, browser: nil).title == "A")

    snapshot.nav?.loading = false
    snapshot.connection = .failed(failure: .wrongReplica, message: "lost it", requiresSignIn: false)
    listener.onState(snapshot: snapshot)
    try await eventually("failed") {
      TabAdapter.item(tab, session: session, browser: nil).status == .failed
    }

    snapshot.connection = .closed(reason: .serverClosed(code: 1000, reason: "done"))
    listener.onState(snapshot: snapshot)
    try await eventually("exited") {
      TabAdapter.item(tab, session: session, browser: nil).status == .exited
    }
  }

  @Test("A remote tab's page: off in this build, then waiting for its session, then the page")
  func remotePage() async throws {
    let off = try await session()
    let tab = AppTab(content: .remoteBrowser(sessionID: "conv_a", tabID: "tab_1"))
    let build = OffscreenWindow(
      remotePage(off, tab: tab) { _, _ in }, width: 500, height: 400)
    defer { build.close() }
    try await settle(build, untilShowing: "Remote Browser Unavailable")

    let session = try await session(remote: FixtureRemoteBrowser(latency: .milliseconds(1)))
    let screen = OffscreenWindow(
      remotePage(session, tab: tab) { _, _ in }, width: 500, height: 400)
    defer { screen.close() }
    try await settle(screen, untilShowing: "Opening the remote browser\u{2026}")

    session.open("conv_a")
    let conversation = try #require(session.connection.conversations["conv_a"])
    conversation.apply(
      revision: 1,
      change: TranscriptChange(
        rows: [], header: ConversationFixtures.header(), sections: []))
    try await settle(screen, until: "the store") {
      session.remoteBrowsers?.existingStore(sessionID: "conv_a", tabID: "tab_1") != nil
    }
    #expect(try !screen.shows("Opening the remote browser\u{2026}"))
  }

  private func remotePage(
    _ session: ServerSession, tab: AppTab,
    reopen: @escaping @MainActor (String, RemoteBrowserTabRecord) -> Void
  ) -> RemoteBrowserTabContainer {
    RemoteBrowserTabContainer(
      session: session, tab: tab, sessionID: "conv_a", tabID: "tab_1", reopen: reopen,
      showSessions: {},
      tabsButton: { TabSwitcherButton(state: TabsState(tabs: []), actions: TabActions()) })
  }

  @Test("New-tab menus read the machine's remote browser profiles")
  func remoteProfiles() async throws {
    let plain = try await session()
    await plain.loadRemoteBrowserProfiles("conv_a")
    let session = try await session(remote: FixtureRemoteBrowser(latency: .milliseconds(1)))
    await session.loadRemoteBrowserProfiles(nil)
    #expect(session.remoteBrowsers?.profiles["conv_a"] == nil)
    await session.loadRemoteBrowserProfiles("conv_a")
    #expect(session.remoteBrowsers?.profiles["conv_a"]?.isEmpty == false)
  }

  @Test("A terminal that can't start says why on its tab's page and on the agent's")
  func terminalFailures() async throws {
    let session = try await session()
    session.open("conv_a")
    let store = try #require(session.terminalStores["conv_a"])
    store.lastError = .surfaceCreationFailed
    let message = String(describing: GhosttyError.surfaceCreationFailed)

    let page = OffscreenWindow(
      TerminalTabView(session: session, sessionID: "conv_a", terminalID: "t", showChat: {}),
      width: 500, height: 400)
    defer { page.close() }
    try await settle(page, untilShowing: "Terminal Unavailable")

    let harness = OffscreenWindow(
      HarnessTabView(session: session, sessionID: "conv_a", showChat: {}), width: 500, height: 400)
    defer { harness.close() }
    try await pause(harness)
    #expect(try harness.shownText().contains { $0.contains(message) })
  }

  @Test("A side question shows what was asked and what came back")
  func sideChatAnswer() async throws {
    let session = try await session()
    session.open("conv_a")
    let conversation = try #require(session.connection.conversations["conv_a"])
    let activity = OmnigentCoreFFI.Activity(
      kind: .sidechat, title: "Side question", summary: "Why?", status: "done",
      details: [
        DetailSection(
          id: "question", title: "Question", text: "Why is the sky blue?", isCode: false),
        DetailSection(id: "answer", title: "Answer", text: "Scattering.", isCode: false),
      ], isFailure: false, recovery: nil)
    var row = ConversationFixtures.userRow("question", text: "", role: .assistant)
    row.activity = activity
    conversation.apply(
      revision: 1,
      change: TranscriptChange(
        rows: [RowOp.insert(index: 0, row: row)], header: ConversationFixtures.header(),
        sections: []))
    let screen = OffscreenWindow(
      SideChatTabContainer(session: session, sessionID: "conv_a", rowID: "question", showChat: {}),
      width: 500, height: 400)
    defer { screen.close() }
    try await settle(screen, untilShowing: "Why is the sky blue?")
    #expect(try screen.shows("Scattering."))
  }

  @Test("Attachments the server sent keep what they are")
  func attachmentKinds() {
    let kinds: [(OmnigentCoreFFI.AttachmentKind, OmnigentUIComponents.AttachmentKind)] = [
      (.image, .image), (.file, .file), (.audio, .audio), (.video, .video),
    ]
    for (sent, shown) in kinds {
      let attachment = OmnigentUIComponents.Attachment(
        OmnigentCoreFFI.Attachment(
          id: "a", kind: sent, title: "t", reference: "r", mimeType: "m", isEmbedded: true))
      #expect(attachment.kind == shown)
      #expect(attachment.reference == "r" && attachment.isEmbedded)
    }
  }
}
