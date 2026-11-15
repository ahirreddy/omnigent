import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores
@testable import OmnigentTerminalStores
@testable import OmnigentUIComponents

/// What a window's session chrome is built from: the session's chat as the window builds it,
/// over the state the window keeps for the session.
extension ConversationWiringTests {
  /// How often the session's chat was brought on screen.
  final class Reveals {
    var count = 0
  }

  private struct Chrome {
    let surface: SessionSurface
    let kept: SessionChromeState
    let wired: Wired
    let choice: SessionViewChoice
    let reveals: Reveals
  }

  /// `conv_a`'s chrome over the chat ``wired(_:settings:tabRoutes:)`` builds.
  private func chrome(
    _ server: AppServer = threeSessionServer(), terminals: TerminalStore? = nil
  ) async throws -> Chrome {
    var wired = try await wired(server)
    let (choice, reveals) = (SessionViewChoice(), Reveals())
    let kept = SessionChromeState(viewChoice: choice) { reveals.count += 1 }
    if let terminals {
      var chat = wired.container
      chat = ConversationContainer(
        conversation: chat.conversation, summary: chat.summary, terminals: terminals,
        workspace: nil, panel: nil, changedFilesRevision: { 0 }, navigation: chat.navigation,
        opener: chat.opener, openSession: chat.openSession, retry: {}, server: chat.server,
        makeForkStore: chat.makeForkStore)
      wired = Wired(
        container: chat, store: wired.store, opened: wired.opened, server: wired.server,
        sheets: wired.sheets)
    }
    return Chrome(
      surface: SessionSurface(chat: wired.container, kept: kept), kept: kept, wired: wired,
      choice: choice, reveals: reveals)
  }

  @Test("The panel's links open through the window, and one that would not open is reported")
  func chromeLinks() async throws {
    let chrome = try await chrome()
    let actions = chrome.surface.chrome.actions
    let link = try #require(URL(string: "https://example.com/pull/7"))
    actions.openURL?(link)
    try await eventually("the link") { chrome.wired.opened.urls == [link] }
    #expect(chrome.kept.failures.messages.isEmpty)

    chrome.wired.opened.succeeds = false
    actions.openURL?(link)
    try await eventually("the report") { !chrome.kept.failures.messages.isEmpty }
    #expect(chrome.kept.failures.messages == ["Could not open https://example.com/pull/7."])

    actions.openSession?("conv_b")
    #expect(chrome.wired.opened.sessions == ["conv_b"])
    chrome.wired.store.record(.InvalidState(message: "a failed turn"))
    #expect(chrome.surface.chrome.state.errorMessage == nil, "read when the chrome is built")
    let failed = SessionSurface(chat: chrome.wired.container, kept: chrome.kept)
    #expect(failed.state.errorMessage == "a failed turn")
    actions.dismissError?()
    #expect(chrome.wired.store.errors.isEmpty, "the Info tab's error is dismissed")
  }

  @Test("Export reads the transcript into the session's save panel, or says why it could not")
  func chromeExport() async throws {
    struct DiskFull: LocalizedError {
      var errorDescription: String? { "The disk is full." }
    }
    let chrome = try await chrome()
    chrome.surface.chrome.extras.exportTranscript?()
    try await eventually("the report") { !chrome.kept.failures.messages.isEmpty }
    #expect(chrome.kept.failures.messages[0].hasPrefix("Could not export the transcript"))
    #expect(chrome.kept.export == nil)

    chrome.kept.failures.messages = []
    let file = FileManager.default.temporaryDirectory.appending(path: "t.jsonl")
    chrome.surface.exportFinished(.success(file))
    #expect(chrome.kept.failures.messages.isEmpty)
    chrome.surface.exportFinished(.failure(DiskFull()))
    #expect(
      chrome.kept.failures.messages == ["Could not save the transcript: The disk is full."])
  }

  @Test("The session menu's Fork opens the session's fork sheet, kept with the window")
  func chromeFork() async throws {
    let server = threeSessionServer()
    let row = sessionRow("conv_a", host: "mac", workspace: "/w", updatedAt: 9)
      .replacingOccurrences(of: "\"host_id\"", with: "\"agent_id\":\"ag_claude\",\"host_id\"")
    server.route(
      "/v1/sessions", method: "GET", .json(#"{"object":"list","data":[\#(row)],"has_more":false}"#))
    let chrome = try await chrome(server)
    let extras = chrome.surface.chrome.extras
    let summary = try #require(chrome.surface.state.summary)
    let fork = try #require(extras.sessionActions.fork, "the session can be forked")
    #expect(chrome.kept.forkFlow.sheet == nil)
    fork(summary)
    try await eventually("the sheet") { chrome.kept.forkFlow.sheet != nil }
    #expect(chrome.surface.chrome.fork.wrappedValue?.id == chrome.kept.forkFlow.sheet?.id)
    extras.forkActions?.cancel()
    #expect(chrome.kept.forkFlow.sheet == nil)
  }

  @Test("A session this app cannot fork has no Fork in the window's session menu")
  func chromeWithoutFork() async throws {
    var chat = try await wired().container
    chat.makeForkStore = nil
    #expect(chat.forkSource == nil, "this app cannot fork it")
    let surface = SessionSurface(
      chat: chat, kept: SessionChromeState(viewChoice: SessionViewChoice()) {})
    #expect(surface.chrome.extras.sessionActions.fork == nil)
  }

  @Test("Away from a conversation the menus toggle the panel and the session's Chat or Terminal")
  func chromeCommands() async throws {
    let session = try await signedInSession(threeSessionServer())
    session.open("conv_a")
    let terminals = try #require(session.terminalStores["conv_a"])
    let plain = try await chrome()
    #expect(plain.surface.commands.toggleViewMode == nil, "a session with no terminal view")
    #expect(plain.surface.commands.openChanges == nil, "no window panel to show them in")

    let agent = TerminalResource(
      id: "terminal_agent", sessionId: "conv_a", terminalName: "agent", sessionKey: "1",
      running: true, environment: nil, directAttachUrl: nil, isAgentTerminal: true,
      displayLabel: "Agent")
    terminals.terminals.apply(
      terminals: [TerminalRow(terminal: agent, status: .idle)], harness: .ready(terminal: agent))
    let ready = try await chrome(terminals: terminals)
    let commands = ready.surface.commands
    #expect(ready.surface.state.terminalAvailable)
    #expect(!ready.kept.panel.isShown)
    commands.toggleInspector?()
    #expect(ready.kept.panel.isShown)
    commands.toggleInspector?()
    #expect(!ready.kept.panel.isShown)

    let toggleMode = try #require(commands.toggleViewMode)
    toggleMode()
    #expect(ready.choice.mode == .terminal)
    #expect(ready.reveals.count == 1, "the chat comes on screen for the choice")
    toggleMode()
    #expect(ready.choice.mode == .chat)
    #expect(ready.kept.mode == .chat)
  }

  @Test("A chat in a window that shows the panel sends Pull Requests to the window's panel")
  func hostedChatShowsTheWindowsPanel() async throws {
    let session = try await signedInSession(threeSessionServer())
    let tabs = WindowTabs(
      session: session, context: TabWindowContext(), showAll: {}, fail: { _ in })
    let routes = tabs.routes(for: "conv_a")
    let panel = try #require(routes.windowPanel, "a Mac window shows the session's panel")
    #expect(panel.isSessionChat)
    #expect(tabs.routes(for: "conv_b", in: "conv_a").windowPanel?.isSessionChat == false)
    let wired = try await wired(tabRoutes: routes)
    #expect(wired.container.windowLoadsPanel, "the window reads the panel's data")
    #expect(wired.container.workspaceSlots.files == nil, "the chat builds no panel of its own")

    wired.container.toolRoutes.showPullRequests()
    #expect(panel.chrome.inspectorTab == .pullRequests)
    #expect(panel.chrome.panel.isShown)
    #expect(session.tabs.chrome("conv_a") === panel.chrome, "the session's, for the window's life")

    session.tabs.removeSessions(["conv_a"])
    #expect(session.tabs.chrome("conv_a") !== panel.chrome, "a removed session's state goes")
  }
}
