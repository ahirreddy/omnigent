import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentTerminalUI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores
@testable import OmnigentTerminalStores

/// What the conversation shows once its agent, sharing and terminal have answered.
extension ConversationWiringTests {
  private func terminalRow() -> TerminalRow {
    TerminalRow(
      terminal: TerminalResource(
        id: "terminal_agent", sessionId: "conv_a", terminalName: "agent", sessionKey: "1",
        running: true, environment: nil, directAttachUrl: nil, isAgentTerminal: true,
        displayLabel: "Agent"),
      status: .idle)
  }

  /// `conv_a`'s page showing its terminal over `store`.
  private func terminalPage(
    _ store: ConversationStore, terminals: TerminalStore
  ) -> ConversationContainer {
    let route = ConversationModeRoute()
    route.mode = .terminal
    return ConversationContainer(
      conversation: store, summary: nil, terminals: terminals, workspace: nil, panel: nil,
      changedFilesRevision: 0, navigation: SessionCommandActions(),
      opener: ExternalURLOpener { _ in true }, openSession: { _ in }, retry: {},
      modeRoute: route, failureList: ConversationFailures(), forkFlow: ForkFlow(),
      livenessSheets: SessionLivenessSheets())
  }

  @Test("The agent's name, tools and policies reach the page once read")
  func agentDetails() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/agents/ag_claude", .json(#"{"name":"Helper","mcp_servers":[{"name":"docs"}]}"#))
    server.route("/v1/sessions/conv_a/policies", .json(#"{"data":[{"name":"no-rm"}]}"#))
    let wired = try await wired(server)
    #expect(wired.container.state.agentInfo == nil)
    await wired.store.loadAgentInfo(agentID: "ag_claude")
    let info = try #require(wired.container.state.agentInfo)
    #expect(info.name == "Helper")
    #expect(info.tools == ["docs"])
    #expect(info.policies == ["no-rm"])
  }

  @Test("A save panel that couldn't write the transcript says why; a saved file says nothing")
  func savingFinishes() async throws {
    struct DiskFull: LocalizedError {
      var errorDescription: String? { "The disk is full." }
    }
    let wired = try await wired()
    let file = FileManager.default.temporaryDirectory.appending(path: "t.jsonl")
    wired.container.exportFinished(.success(file))
    #expect(wired.container.failures.isEmpty)
    wired.container.exportFinished(.failure(DiskFull()))
    #expect(wired.container.failures == ["Could not save the transcript: The disk is full."])
  }

  @Test("A session's terminal shows the agent's surface once it's ready")
  func harnessReady() async throws {
    let session = try await signedInSession(threeSessionServer())
    session.open("conv_a")
    let store = try #require(session.connection.conversations["conv_a"])
    store.apply(
      revision: 1,
      change: TranscriptChange(rows: [], header: ConversationFixtures.header(), sections: []))
    let terminals = try #require(session.terminalStores["conv_a"])
    let row = terminalRow()
    terminals.terminals.apply(terminals: [row], harness: .ready(terminal: row.terminal))

    let page = OffscreenWindow(terminalPage(store, terminals: terminals), width: 900, height: 600)
    defer { page.close() }
    try await settle(page, until: "the surface") { showsSurface(page) }
  }

  @Test("Share offers the session's link once it has a store, unless it's turned off")
  func sharing() async throws {
    let wired = try await wired()
    #expect(wired.container.share(over: nil) == nil)
    let store = ShareStore(core: wired.store.core, sessionID: "conv_a")
    #expect(
      wired.container.share(over: store)?.state.link?.absoluteString.contains("conv_a") == true)
    var hidden = wired.container
    hidden.offersShare = false
    #expect(hidden.share(over: store) == nil)
  }

  @Test("A terminal that can't start says why")
  func harnessFailed() throws {
    let screen = OffscreenWindow(
      ConversationHarnessTerminal(surface: nil, harness: nil, error: .surfaceCreationFailed),
      width: 500, height: 400)
    defer { screen.close() }
    #expect(try screen.shows(String(describing: GhosttyError.surfaceCreationFailed)))
  }

  private func showsSurface<Content: View>(_ screen: OffscreenWindow<Content>) -> Bool {
    screen.allViews.contains { String(describing: type(of: $0)).contains("Surface") }
  }
}
