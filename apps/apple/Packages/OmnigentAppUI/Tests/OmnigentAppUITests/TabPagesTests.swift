import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentTerminalStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// What a tab's page shows, side chats starting from their tab, and closing a shell.
@MainActor
@Suite("Tab pages", .serialized, .timeLimit(.minutes(1)))
struct TabPagesTests {
  private final class Failures {
    var messages: [String] = []
  }

  private func session(_ server: AppServer = threeSessionServer()) async throws -> ServerSession {
    try await signedInSession(server)
  }

  @Test("A browser tab shows its page; a build without one says so")
  func browserTab() throws {
    let host = FakeBrowserHost()
    let page = host.makePage(url: URL(string: "https://example.com"))
    let navigation = BrowserTabNavigation(showSessions: {}, tabsButton: AnyView(EmptyView()))
    let shown = OffscreenWindow(
      BrowserTabContainer(
        host: host, tab: AppTab(content: .browser(browserID: page.id)), browserID: page.id,
        navigation: navigation, changed: {}),
      width: 400, height: 300)
    defer { shown.close() }
    #expect(try shown.shows("Page example.com"))
    let none = OffscreenWindow(
      BrowserTabContainer(
        host: nil, tab: AppTab(content: .browser(browserID: page.id)), browserID: page.id,
        navigation: navigation, changed: {}),
      width: 400, height: 300)
    defer { none.close() }
    #expect(try none.shows("Browser Unavailable"))
  }

  @Test("An agent's browser shows when it runs one")
  func agentBrowser() throws {
    let host = FakeBrowserHost()
    let shown = OffscreenWindow(
      AgentBrowserTabContainer(host: host, sessionID: "conv_agent", showChat: {}), width: 400,
      height: 300)
    defer { shown.close() }
    #expect(try shown.shows("Agent page"))
  }

  @Test("A terminal tab whose session lost it says it closed; a failed read says why")
  func terminalPages() async throws {
    let session = try await session()
    session.open("conv_a")
    let store = try #require(session.terminalStores["conv_a"])
    let other = TerminalRow(
      terminal: TerminalResource(
        id: "terminal_other", sessionId: "conv_a", terminalName: "zsh", sessionKey: "1",
        running: true, environment: nil, directAttachUrl: nil, isAgentTerminal: false,
        displayLabel: "zsh"),
      status: .idle)
    store.terminals.apply(terminals: [other], harness: .notTerminalFirst)
    let closed = OffscreenWindow(
      TerminalTabView(
        session: session, sessionID: "conv_a", terminalID: "terminal_gone", showChat: {}),
      width: 500, height: 400)
    defer { closed.close() }
    try await settle(closed, untilShowing: "Terminal Closed")

    let harness = OffscreenWindow(
      HarnessTabView(session: session, sessionID: "conv_a", showChat: {}), width: 500, height: 400)
    defer { harness.close() }
    try await pause(harness)
    #expect(try harness.shownText().contains { $0.contains("terminal") || $0.contains("Terminal") })
  }

  @Test("A side question whose conversation isn't open waits for it")
  func sideChatPage() async throws {
    let session = try await session()
    let waiting = SideChatTabContainer(
      session: session, sessionID: "conv_a", rowID: "row", showChat: {})
    let screen = OffscreenWindow(waiting, width: 500, height: 400)
    defer { screen.close() }
    try await pause(screen)
    #expect(try screen.shows("Loading the side chat\u{2026}"))
  }

  private func sideChatServer() -> AppServer {
    let server = threeSessionServer()
    let row =
      #"{"id":"conv_a","status":"idle","created_at":1,"updated_at":5,"host_id":"mac","runner_id":"r1","runner_online":true,"host_online":true,"workspace":"/w","permission_level":4}"#
    server.route("/v1/sessions/conv_a", .json(row))
    server.route(
      "/v1/sessions/conv_a/fork", method: "POST",
      .json(#"{"id":"conv_side","status":"idle","created_at":5,"permission_level":4}"#, status: 201)
    )
    server.route(
      "/v1/sessions/conv_side",
      .json(#"{"id":"conv_side","status":"idle","created_at":5,"permission_level":4}"#))
    server.route(
      "/v1/sessions/conv_side/events", method: "POST", .json(#"{"queued":false}"#, status: 202))
    server.route(
      "/v1/hosts/mac/runners", method: "POST", .json(#"{"runner_id":"r1"}"#, status: 201))
    return server
  }

  private func pendingTab(_ session: ServerSession, draft: String) -> String {
    session.tabs.open(.chat(sessionID: "conv_a"))
    let group = session.tabs.group("conv_a")
    let tab = group.open(.sideChatSession(parentID: "conv_a", childID: nil))
    session.sideChatDrafts.update(tab.id) { $0.text = draft }
    return tab.id
  }

  @Test("Sending starts the side chat and the tab becomes it")
  func sideChatStarts() async throws {
    let server = sideChatServer()
    let session = try await session(server)
    session.open("conv_a")
    let failures = Failures()
    let tabID = pendingTab(session, draft: "why?")
    PendingSideChatTab.start(
      session: session, tabID: tabID, parentID: "conv_a", fail: { failures.messages.append($0) })
    #expect(session.sideChatDrafts.draft(tabID).isStarting)
    try await eventually("the tab to change") {
      session.tabs.tab(tabID)?.tab.content
        == .sideChatSession(parentID: "conv_a", childID: "conv_side")
    }
    #expect(session.sideChatDrafts.drafts[tabID] == nil, "the draft left with the send")
    #expect(failures.messages.isEmpty)
  }

  @Test("A first message that fails keeps the words in the new side chat and says so")
  func sideChatMessageFails() async throws {
    let server = sideChatServer()
    server.route(
      "/v1/sessions/conv_side/events", method: "POST", .json(#"{"detail":"no"}"#, status: 500))
    let session = try await session(server)
    session.open("conv_a")
    let failures = Failures()
    let tabID = pendingTab(session, draft: "why?")
    PendingSideChatTab.start(
      session: session, tabID: tabID, parentID: "conv_a", fail: { failures.messages.append($0) })
    try await eventually("the failure") { !failures.messages.isEmpty }
    #expect(failures.messages.first?.hasPrefix("The side chat started") == true)
  }

  @Test("A side chat the server refuses keeps the draft for another try")
  func sideChatRefused() async throws {
    let server = sideChatServer()
    server.route(
      "/v1/sessions/conv_a/fork", method: "POST", .json(#"{"detail":"no"}"#, status: 500))
    let session = try await session(server)
    session.open("conv_a")
    let tabID = pendingTab(session, draft: "why?")
    PendingSideChatTab.start(session: session, tabID: tabID, parentID: "conv_a", fail: { _ in })
    try await eventually("the failure") { session.sideChatDrafts.draft(tabID).failure != nil }
    let draft = session.sideChatDrafts.draft(tabID)
    #expect(draft.failure?.hasPrefix("Couldn't start a side chat") == true)
    #expect(draft.text == "why?")
    #expect(!draft.isStarting)
  }

  @Test("Nothing starts from an empty draft, and a conversation that isn't open says so")
  func sideChatWithoutAParent() async throws {
    let session = try await session()
    let tabID = pendingTab(session, draft: "  \n")
    PendingSideChatTab.start(session: session, tabID: tabID, parentID: "conv_a", fail: { _ in })
    #expect(session.sideChatDrafts.draft(tabID).failure == nil)
    #expect(!session.sideChatDrafts.draft(tabID).isStarting)
    session.sideChatDrafts.update(tabID) { $0.text = "why?" }
    PendingSideChatTab.start(session: session, tabID: tabID, parentID: "conv_a", fail: { _ in })
    #expect(session.sideChatDrafts.draft(tabID).failure == "The conversation isn't open.")
    session.sideChatDrafts.remove(tabID)
    #expect(session.sideChatDrafts.drafts[tabID] == nil)
  }

  @Test("A typed /side sends at once")
  func sideChatSendNow() async throws {
    let server = sideChatServer()
    let session = try await session(server)
    session.open("conv_a")
    let window = WindowTabs(
      session: session, context: TabWindowContext(), showAll: {}, fail: { _ in })
    session.tabs.open(.chat(sessionID: "conv_a"))
    window.openPendingSideChat("conv_a", draft: "why?", sendNow: true)
    try await eventually("the fork") {
      !server.requests("POST", "/v1/sessions/conv_a/fork").isEmpty
    }
  }

  @Test("Close Shell ends the terminal as well as the tab; a failure says so")
  func closeShell() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/sessions/conv_a/resources/terminals/terminal_a", method: "DELETE",
      .json(#"{"detail":"no"}"#, status: 500))
    let session = try await session(server)
    session.open("conv_a")
    session.tabs.show(.session("conv_a"))
    let group = session.tabs.group("conv_a")
    let tab = group.open(.terminal(sessionID: "conv_a", terminalID: "terminal_a"), title: "zsh")
    let failures = Failures()
    let confirmation = CloseShellConfirmation(
      session: session, fail: { failures.messages.append($0) })

    confirmation.closeShell()
    #expect(group.tabs.contains { $0.id == tab.id }, "nothing was asked")
    group.closingShell = tab.id
    confirmation.closeShell()
    #expect(!group.tabs.contains { $0.id == tab.id })
    try await eventually("the failure") { !failures.messages.isEmpty }
    #expect(failures.messages.first?.hasPrefix("The shell could not be closed") == true)
    #expect(
      !server.requests("DELETE", "/v1/sessions/conv_a/resources/terminals/terminal_a").isEmpty)
  }

  @Test("A shell's strip status follows the terminal's")
  func shellStatus() {
    let terminal = TerminalResource(
      id: "t", sessionId: nil, terminalName: "zsh", sessionKey: "1", running: true,
      environment: nil, directAttachUrl: nil, isAgentTerminal: false, displayLabel: "zsh")
    #expect(
      TabAdapter.terminalStatus(TerminalRow(terminal: terminal, status: .active))
        == .terminalActivity)
    #expect(TabAdapter.terminalStatus(TerminalRow(terminal: terminal, status: .exited)) == .exited)
    #expect(TabAdapter.terminalStatus(TerminalRow(terminal: terminal, status: .idle)) == .none)
    #expect(TabAdapter.terminalStatus(TerminalRow(terminal: terminal, status: .unknown)) == .none)
  }

  @Test("A file asked for before its session opens shows once it does")
  func pendingFile() async throws {
    let server = threeSessionServer()
    let session = try await session(server)
    session.openFile("README.md", at: 3, in: "conv_a")
    #expect(session.workspaces["conv_a"] == nil)
    session.open("conv_a")
    #expect(session.workspaces["conv_a"] != nil)
    session.openFile("README.md", at: nil, in: "conv_a")
    #expect(session.unsavedFilePaths.isEmpty)
    #expect(await session.saveUnsavedFiles().isEmpty)
    session.discardUnsavedFiles()
    #expect(session.connectedURL?.absoluteString.isEmpty == false)
    session.close("conv_a")
    #expect(session.workspaces["conv_a"] == nil)
  }
}
