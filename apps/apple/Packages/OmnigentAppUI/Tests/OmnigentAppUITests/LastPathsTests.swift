import AppKit
import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// Paths behind one person's rarer steps: quotes, side chats, torn-off tabs, older windows.
@MainActor
@Suite("Rarer paths", .serialized, .timeLimit(.minutes(1)))
struct LastPathsTests {
  @Test("A quoted selection shows on the composer")
  func quotes() async throws {
    let store = try await ConversationFixtures.store()
    store.composer.quote("the line")
    let state = ComposerAdapter.state(store, isStopping: false, dismissedError: nil)
    #expect(state.quotes.map(\.text) == ["the line"])
  }

  @Test("Dismiss on a connection problem's banner clears it")
  func dismissingABanner() throws {
    let connection = ConnectionStore(startupError: .InvalidState(message: "The disk is on fire"))
    let screen = OffscreenWindow(ConnectionIssuesBanner(connection: connection), width: 500)
    defer { screen.close() }
    #expect(try screen.shows("The disk is on fire"))
    let controls = screen.controlFrames
    #expect(controls.count == 1, "\(controls)")
    try screen.clickControl(at: controls.count - 1)
    #expect(connection.issues.isEmpty)
  }

  @Test("Reopening on this Mac's server starts it and connects; another server isn't touched")
  func resumingTheLocalServer() throws {
    let local = "http://127.0.0.1:\(LocalInstall.port)"
    let setup = StartsLocalServer(url: local)
    let signIn = SignInController(
      store: ConnectionStore(startupError: .InvalidState(message: "no core")),
      defaults: try scratchDefaults())
    signIn.directory.recentServers = [local]
    signIn.resumeLocalServer()
    #expect(setup.starts == 0, "nothing to start with until the app offers local setup")

    signIn.localSetup = setup
    signIn.directory.recentServers = ["https://omnigent.example.com", local]
    signIn.resumeLocalServer()
    #expect(setup.starts == 0, "the last server used is elsewhere")

    signIn.directory.recentServers = [local]
    signIn.resumeLocalServer()
    #expect(setup.starts == 1)
    #expect(signIn.state.lastServerUrl == local, "the window connects once it's up")
    signIn.actions.localSetup?.start()
    #expect(setup.starts == 2)
  }

  @Test("A session's agent tab keeps a name when the session isn't listed")
  func harnessTabName() throws {
    let session = try ServerSession.demo()
    let tab = AppTab(content: .harness(sessionID: "gone"))
    #expect(TabAdapter.item(tab, session: session, browser: nil).title == "Agent Terminal")
  }

  @Test("Tabs torn off another window join this one and the first is selected")
  func adoptingTabs() throws {
    let session = try ServerSession.demo()
    session.tabs.showChat("s1")
    let store = try #require(session.tabs.current)
    let moved = AppTab(content: .terminal(sessionID: "s1", terminalID: "t1"))
    store.adopt([moved])
    #expect(store.selected?.id == moved.id)
    store.adopt([moved])
    #expect(store.tabs.filter { $0.id == moved.id }.count == 1, "already here isn't added twice")
  }

  @Test("Fresh windows each take a different window left from an earlier launch")
  func claimingAnEarlierWindow() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer {
      do {
        try FileManager.default.removeItem(at: folder)
      } catch {
        Issue.record(error, "could not remove \(folder.path)")
      }
    }
    let server = "http://server"
    for page in [SidebarDestination.inbox, .usage] {
      let writer = TabPersistence(directory: folder, debounce: .milliseconds(1))
      writer.register(window: UUID(), server: server) {
        TabWindowState(page: page, groups: [:])
      }
      writer.flush()
      try await Task.sleep(for: .milliseconds(5))
    }
    let reader = TabPersistence(directory: folder)
    // Saved within a second of each other, so either may read as the newer.
    let first = try #require(reader.claim(window: UUID(), server: server))
    let second = try #require(reader.claim(window: UUID(), server: server))
    #expect(Set([first, second]) == [.inbox, .usage])
    #expect(reader.claim(window: UUID(), server: server) == nil)
  }

  @Test("A second connection to the same server takes over supervision")
  func supervisionFollowsTheNewestConnection() async throws {
    let connections = SupervisionConnections()
    let first = try await signedInStore(threeSessionServer())
    let second = try await signedInStore(threeSessionServer())
    connections.register(first)
    connections.register(second)
    #expect(connections.connections.contains { $0 === second })
    #expect(!connections.connections.contains { $0 === first })
  }

  @Test("New Session in a project's menu opens the form on it")
  func newSessionInProject() async throws {
    let session = try await signedInSession(threeSessionServer())
    let selection = WindowSelection()
    let actions = connectedView(session, selection).sidebarActions
    actions.newSessionInProject?(SessionProject(id: "p1", name: "Alpha", sessionIds: [], icon: nil))
    #expect(selection.page == .newSession)
  }

  @Test("Project pages in the sidebar say which are loaded, have more and are loading")
  func projectPaging() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[],"has_more":true,"last_id":"x"}"#))
    let connection = try await signedInStore(server)
    let list = connection.sessionList
    try await eventually("the list") { list.isLoaded }
    await list.paging.loadProject(ProjectSummary(id: "p1", name: "Alpha", icon: nil), id: "p1")
    let paging = SidebarAdapter.paging(list.paging)
    #expect(paging.loadedProjects == ["p1"])
    #expect(paging.projectsWithMore == ["p1"])
    #expect(paging.loadingProjects.isEmpty)
  }

  @Test("A pending side chat's draft, Send and Dismiss work from its page")
  func pendingSideChatPage() async throws {
    SystemSideEffects.install()
    let session = try await signedInSession(threeSessionServer())
    session.open("conv_a")
    let tab = try #require(
      session.tabs.group("conv_a").open(.sideChatSession(parentID: "conv_a", childID: nil)))
    session.sideChatDrafts.update(tab.id) { $0.failure = "Could not start" }
    final class Failures { var messages: [String] = [] }
    let failures = Failures()
    let screen = OffscreenWindow(
      PendingSideChatTab(
        session: session, tabID: tab.id, parentID: "conv_a",
        fail: { failures.messages.append($0) }), width: 800, height: 600)
    defer { screen.close() }
    try await settle(screen, untilShowing: "Could not start", contains: true)
    let field = try #require(
      screen.allViews.compactMap { $0 as? NSTextView }.first as NSView?
        ?? screen.allViews.compactMap { $0 as? NSTextField }.first)
    try screen.click(field)
    try screen.type("why?")
    try await settle(screen, until: "the draft") {
      session.sideChatDrafts.draft(tab.id).text == "why?"
    }
    try await settle(screen, until: "Dismiss") {
      for index in screen.controlFrames.indices.reversed()
      where session.sideChatDrafts.draft(tab.id).failure != nil {
        do {
          try screen.clickControl(at: index)
        } catch {
          Issue.record(error)
        }
      }
      return session.sideChatDrafts.draft(tab.id).failure == nil
    }
    try screen.press(keyCode: 36, characters: "\r")
    try await settle(screen, until: "the send") {
      session.sideChatDrafts.draft(tab.id).isStarting
        || session.sideChatDrafts.draft(tab.id).failure != nil
    }
  }
}

/// Stands in for this Mac's local server: starting it hands the window its address.
private final class StartsLocalServer: LocalSetupSource {
  let url: String
  var starts = 0

  init(url: String) { self.url = url }

  var state: LocalSetupState { LocalSetupState(cli: .checking, server: .stopped) }

  func actions(connect: @escaping @MainActor (String) -> Void) -> LocalSetupActions {
    LocalSetupActions(
      start: { [self] in
        starts += 1
        connect(url)
      },
      recheckCLI: {}, hostAfterSignIn: { _ in })
  }

  func didSignIn(to baseUrl: String) {}
}
