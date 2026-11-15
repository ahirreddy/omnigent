import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// The whole signed-in window, offscreen, over the core's demo server.
@MainActor
@Suite("Connected window", .serialized, .timeLimit(.minutes(1)))
struct ConnectedAppTests {
  private typealias Screen = OffscreenWindow<AppWindowRoot>

  private func window(
    page: SidebarDestination? = nil
  ) async throws -> (Screen, (ServerSession, WindowSelection)) {
    let session = try await connectedDemo()
    let selection = WindowSelection(page)
    let screen = OffscreenWindow(
      AppWindowRoot(session: session, selection: selection), width: 1200, height: 800)
    return (screen, (session, selection))
  }

  private static let sessionTitles = [
    "Native mobile design", "Choose the first release", "Project notes",
  ]

  /// Waits for the sidebar to list every demo session.
  private func waitForSessions(_ screen: Screen) async throws {
    for title in Self.sessionTitles {
      try await settle(screen, untilShowing: title, contains: true)
    }
  }

  /// Waits for the session's chat to show its request card, or none, with its editor holding
  /// the keyboard.
  private func waitForComposer(_ screen: Screen, pending: Bool) async throws {
    try await settle(screen, until: "the chat's editor to take the keyboard") {
      let showsRequest = (try? screen.shows("Apply the sample design?")) == true
      let editor = screen.window.firstResponder as? NSTextView
      return showsRequest == pending && editor?.isEditable == true
    }
  }

  @Test("The sidebar lists the server's sessions")
  func theSidebarLists() async throws {
    let (screen, _) = try await window()
    defer { screen.close() }
    try await waitForSessions(screen)
    try await settle(screen, untilShowing: "Offline demo", contains: true)
    let shown = try screen.shownText()
    for title in Self.sessionTitles {
      #expect(shown.contains { $0.contains(title) }, "\(title) in \(shown)")
    }
    #expect(shown.contains { $0.contains("Offline demo") }, "the server's name is in the switcher")
  }

  @Test("Clicking a row opens that session, with its chat as the only tab")
  func clickingARowOpens() async throws {
    let (screen, (session, selection)) = try await window()
    defer { screen.close() }
    try await waitForSessions(screen)
    // The list's rows run top to bottom, and the last session is its last row.
    let rows = screen.allViews.filter { String(describing: type(of: $0)) == "ListTableRowView" }
    try screen.click(try #require(rows.last))
    try await settle(screen, until: "the page") { selection.page == .session("demo-notes") }
    try await settle(screen, until: "the session to open") {
      session.connection.conversations["demo-notes"] != nil
    }
    #expect(session.tabs.current?.tabs.map(\.content) == [.chat(sessionID: "demo-notes")])
    #expect(session.openSessionIDs.contains("demo-notes"))
    #expect(session.connection.conversations["demo-notes"] != nil)
  }

  @Test("Switching sessions swaps the tab strip and brings each session's tabs back")
  func switchingSessions() async throws {
    let (screen, (session, selection)) = try await window(page: .session("demo-notes"))
    defer { screen.close() }
    session.tabs.open(.newTab)
    try await settle(screen, until: "the new tab") { session.tabs.current?.tabs.count == 2 }
    #expect(session.tabs.current?.tabs.count == 2)
    let chosen = session.tabs.current?.selectedID

    selection.page = .session("demo-question")
    try await settle(screen, until: "the other session's tabs") {
      session.tabs.page == .session("demo-question")
    }
    #expect(session.tabs.current?.tabs.map(\.content) == [.chat(sessionID: "demo-question")])

    selection.page = .session("demo-notes")
    try await settle(screen, until: "the first session's tabs") {
      session.tabs.page == .session("demo-notes")
    }
    #expect(session.tabs.current?.tabs.count == 2, "tabs belong to their session")
    #expect(session.tabs.current?.selectedID == chosen)
  }

  @Test(
    "Each session-less page shows what it is, without a tab strip",
    arguments: [
      (SidebarDestination.newSession, "What should we build?"),
      (.inbox, "2 need you"),
      (.canvas, "Canvas is not enabled on this server"),
      (.automations, "Couldn’t load automations."),
      (.usage, "Failed to load usage data"),
    ])
  func sessionlessPages(page: SidebarDestination, heading: String) async throws {
    let (screen, (session, _)) = try await window(page: page)
    defer { screen.close() }
    try await settle(screen, untilShowing: heading)
    #expect(session.tabs.page == page)
    #expect(session.tabs.current == nil)
    #expect(try screen.shows(heading))
  }

  @Test("With nothing chosen the window asks for a session")
  func nothingChosen() async throws {
    let (screen, (session, _)) = try await window()
    defer { screen.close() }
    try await settle(screen, untilShowing: "No Session Selected")
    #expect(session.tabs.page == nil)
    #expect(try screen.shows("No Session Selected"))
    #expect(try screen.shows("Choose a session in the sidebar, or start a new one."))
  }

  @Test("A session's chat shows its transcript")
  func aSessionShowsItsTranscript() async throws {
    let (screen, _) = try await window(page: .session("demo-design"))
    defer { screen.close() }
    try await settle(screen, untilShowing: "Apply the sample design?")
    try await settle(screen, untilShowing: "1 request needs you")
    #expect(try screen.shows("Apply the sample design?"), "the pending approval")
    #expect(try screen.shows("Help me make the mobile session screen easier to scan."))
    #expect(try screen.shows("1 request needs you"))
  }

  @Test("With a request pending, Return keeps the words and says what's needed first")
  func aPendingRequestHoldsTheMessage() async throws {
    let (screen, (session, _)) = try await window(page: .session("demo-design"))
    defer { screen.close() }
    try await waitForComposer(screen, pending: true)
    let composer = try #require(session.connection.conversations["demo-design"]?.composer)
    try screen.type("ship it")
    try await settle(screen, until: "the keys") { composer.text == "ship it" }
    #expect(composer.text == "ship it", "the keys reach the composer")
    try screen.press(keyCode: 36, characters: "\r")
    try await settle(
      screen, untilShowing: "Respond to the pending request before sending a message.")
    #expect(composer.text == "ship it")
    #expect(try screen.shows("Respond to the pending request before sending a message."))
  }

  @Test("Command-Return approves the pending request, and the next message then sends")
  func approvingThenSending() async throws {
    let (screen, (session, _)) = try await window(page: .session("demo-design"))
    defer { screen.close() }
    try await waitForComposer(screen, pending: true)
    let conversation = try #require(session.connection.conversations["demo-design"])
    #expect(conversation.decisions.cards.count == 1)
    #expect(try pressShortcut(screen, keyCode: 36, characters: "\r", modifiers: .command))
    try await settle(screen, until: "the answer") { conversation.decisions.cards.isEmpty }
    try await waitForComposer(screen, pending: false)
    try screen.type("ship it")
    try await settle(screen, until: "the keys") { conversation.composer.text == "ship it" }
    try screen.press(keyCode: 36, characters: "\r")
    try await settle(screen, until: "the send") { conversation.composer.text.isEmpty }
    try await settle(screen, untilShowing: "ship it")
    #expect(try screen.shows("ship it"))
  }

  @Test("A session the viewer can only read says so and sends nothing")
  func aReadOnlySession() async throws {
    let (screen, _) = try await window(page: .session("demo-notes"))
    defer { screen.close() }
    try await settle(screen, untilShowing: "You can read this session but not send.")
    try await settle(screen, untilShowing: "This shared session is read-only.")
    #expect(try screen.shows("You can read this session but not send."))
    #expect(try screen.shows("This shared session is read-only."))
  }

  @Test(
    "Every kind of tab shows in its session",
    arguments: [
      (AppTabContent.newTab, "Opens in"),
      // A tab left for the agent's terminal shows its session's chat.
      (
        .harness(sessionID: "demo-design"),
        "Help me make the mobile session screen easier to scan."
      ),
      (.terminal(sessionID: "demo-design", terminalID: "t1"), "Connecting…"),
      (.sideChat(sessionID: "demo-design", rowID: "row"), "Side Chat Unavailable"),
      (.sideChatSession(parentID: "demo-design", childID: nil), "Ask a side question…"),
      (.sideChatSession(parentID: "demo-design", childID: "demo-notes"), "What should we work on?"),
      (.browser(browserID: UUID()), "Browser Unavailable"),
      (.agentBrowser(sessionID: "demo-design"), "No Agent Browser"),
      (.remoteBrowser(sessionID: "demo-design", tabID: "r1"), "Remote Browser Unavailable"),
    ])
  func everyKindOfTab(content: AppTabContent, expected: String) async throws {
    let (screen, (session, _)) = try await window(page: .session("demo-design"))
    defer { screen.close() }
    try await settle(screen, until: "the session's tabs") { session.tabs.current != nil }
    session.tabs.current?.open(content)
    try await settle(screen, untilShowing: expected)
    #expect(session.tabs.current?.selected?.content == content)
    #expect(try screen.shows(expected))
  }

  @Test("The window's page and tabs come back in a new window of the same server")
  func restoringAWindow() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { removeFolder(folder) }
    let windowID = UUID()
    do {
      let session = try await connectedDemo()
      let selection = WindowSelection(.session("demo-design"))
      let persistence = TabPersistence(directory: folder, debounce: .milliseconds(1))
      let context = TabWindowContext(window: windowID, persistence: persistence)
      let screen = OffscreenWindow(
        AppWindowRoot(session: session, selection: selection, tabContext: context),
        width: 1200, height: 800)
      try await settle(screen, until: "the session's tabs") { session.tabs.current != nil }
      session.tabs.open(.newTab)
      try await settle(screen, until: "the new tab") { session.tabs.current?.tabs.count == 2 }
      let chat = try #require(session.tabs.current?.tabs.first?.id)
      session.tabs.current?.select(chat)
      try await settle(screen, until: "the chat's tab") { session.tabs.current?.selectedID == chat }
      selection.page = .inbox
      try await settle(screen, until: "the inbox") { session.tabs.page == .inbox }
      selection.page = .session("demo-design")
      let server = try #require(session.connection.connectedServer?.baseUrl)
      try await settle(screen, until: "the window's page and tabs to be saved") {
        let saved = TabPersistence(directory: folder)
        let tabs = saved.savedTabs(session: "demo-design", server: server, for: UUID())
        return saved.claim(window: windowID, server: server) == .session("demo-design")
          && tabs?.tabs.map(\.content) == [.chat(sessionID: "demo-design"), .newTab]
          && tabs?.selectedID == chat
      }
      screen.close()
    }
    let session = try await connectedDemo()
    let selection = WindowSelection()
    let persistence = TabPersistence(directory: folder, debounce: .milliseconds(1))
    let context = TabWindowContext(window: windowID, persistence: persistence)
    let screen = OffscreenWindow(
      AppWindowRoot(session: session, selection: selection, tabContext: context),
      width: 1200, height: 800)
    defer { screen.close() }
    try await settle(screen, until: "the saved page") { selection.page != nil }
    #expect(selection.page == .session("demo-design"))
    #expect(
      session.tabs.current?.tabs.map(\.content) == [.chat(sessionID: "demo-design"), .newTab])
    #expect(session.tabs.current?.selected?.content == .chat(sessionID: "demo-design"))
  }

  @Test("A session deleted elsewhere leaves the window on no session and drops its tabs")
  func aSessionRemovedElsewhere() async throws {
    let (screen, (session, selection)) = try await window(page: .session("demo-design"))
    defer { screen.close() }
    try await settle(screen, until: "the session's tabs") {
      session.tabs.groups["demo-design"] != nil
    }
    session.tabs.removeSessions(["demo-design"])
    try await settle(screen, until: "the page to clear") {
      selection.page != .session("demo-design")
    }
    #expect(session.tabs.groups["demo-design"] == nil)
    #expect(try screen.shows("No Session Selected"))
  }

  @Test("Failed tab starts and connection problems show above the page until dismissed")
  func banners() async throws {
    let (screen, (session, _)) = try await window(page: .newSession)
    defer { screen.close() }
    session.connection.issues.append(
      CoreIssue(id: 1, scope: .connection, error: .InvalidState(message: "The disk is on fire")))
    try await settle(screen, untilShowing: "The disk is on fire")
    #expect(try screen.shows("The disk is on fire"))
    session.connection.dismissIssues()
    try await settle(screen, until: "the banner to go") {
      (try? screen.shows("The disk is on fire")) == false
    }
    try await settle(screen, untilShowing: "What should we build?")
    #expect(try screen.shows("What should we build?"))
    #expect(try !screen.shows("The disk is on fire"))
  }
}

private func removeFolder(_ folder: URL) {
  do {
    try FileManager.default.removeItem(at: folder)
  } catch {
    Issue.record("could not remove \(folder.path): \(error)")
  }
}
