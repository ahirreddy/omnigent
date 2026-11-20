import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores
@testable import OmnigentTerminalStores

/// The split Terminal view's actions (`splittable_terminal_view_ui`): who gets them, and what
/// Split Right and Close Pane ask the server for.
extension ConversationWiringTests {
  private struct SplitPage {
    let container: ConversationContainer
    let terminals: TerminalStore
    let server: AppServer
    let defaults: UserDefaults
  }

  private func splitRow(_ id: String, isAgent: Bool) -> TerminalRow {
    TerminalRow(
      terminal: TerminalResource(
        id: id, sessionId: "conv_a", terminalName: isAgent ? "agent" : "zsh", sessionKey: id,
        running: true, environment: nil, directAttachUrl: nil, isAgentTerminal: isAgent,
        displayLabel: isAgent ? "Agent" : "zsh"),
      status: .idle)
  }

  private func splitServer() -> AppServer {
    let server = threeSessionServer()
    server.route("/v1/sessions/conv_a/agent", .json(#"{"terminals":["zsh","bash"]}"#))
    server.route(
      "/v1/sessions/conv_a/resources/terminals",
      .json(#"{"object":"list","data":[],"has_more":false}"#))
    server.route(
      "/v1/sessions/conv_a/resources/terminals", method: "POST",
      .json(#"{"id":"terminal_zsh_1","type":"terminal","metadata":{"running":true}}"#, status: 201))
    return server
  }

  /// `conv_a` in Terminal view with its agent's pane up, for a viewer at `permission`.
  private func splitPage(permission: Int64 = 4, offered: Bool = true) async throws -> SplitPage {
    let server = splitServer()
    let session = try await signedInSession(server)
    // Stores of their own, so the core's reads for an open session replace neither the header
    // nor the terminal list the test gives them.
    let core = try #require(session.connection.core)
    let store = ConversationStore(sessionID: "conv_a", core: core)
    let header = SessionHeader(
      id: "conv_a", title: "A", status: .idle, readOnly: false, archived: false,
      permissionLevel: permission, failureMessage: nil,
      settings: ConversationFixtures.settings(harness: "claude-native"))
    store.apply(revision: 1, change: TranscriptChange(rows: [], header: header, sections: []))
    let terminals = TerminalStore(terminals: SessionTerminalsStore(sessionID: "conv_a", core: core))
    let agent = splitRow("terminal_agent", isAgent: true)
    terminals.terminals.apply(terminals: [agent], harness: .ready(terminal: agent.terminal))
    await terminals.terminals.loadDeclaredTerminalNames()
    let suite = "terminal-split-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let container = ConversationContainer(
      conversation: store, summary: nil, terminals: terminals, workspace: nil, panel: nil,
      changedFilesRevision: { 0 }, navigation: SessionCommandActions(),
      opener: ExternalURLOpener { _ in true }, openSession: { _ in }, retry: {},
      offersTerminalSplit: offered, terminalSplits: TerminalSplitRegistry(defaults: defaults),
      failureList: ConversationFailures(), forkFlow: ForkFlow(),
      livenessSheets: SessionLivenessSheets())
    return SplitPage(container: container, terminals: terminals, server: server, defaults: defaults)
  }

  @Test("The Terminal view splits for its owner where the server offers it, at regular width")
  func terminalSplitOffered() async throws {
    let page = try await splitPage()
    let controls = try #require(
      page.container.terminalSplitControls(isRegularWidth: true) { _ in })
    #expect(controls.shells == ["zsh", "bash"])
    #expect(page.container.terminalSplitControls(isRegularWidth: false) { _ in } == nil)
    let viewer = try await splitPage(permission: 1)
    #expect(viewer.container.terminalSplitControls(isRegularWidth: true) { _ in } == nil)
    let off = try await splitPage(offered: false)
    #expect(off.container.terminalSplitControls(isRegularWidth: true) { _ in } == nil)
    let shells = ConversationContainer.splitShells(["zsh", "bash"], preferred: "bash")
    #expect(shells == ["bash", "zsh"])
    #expect(ConversationContainer.splitShells(["zsh"], preferred: "fish") == ["zsh"])
  }

  @Test("Split Right starts the chosen shell beside the agent's pane and remembers it")
  func terminalSplitRight() async throws {
    let page = try await splitPage()
    var reported: [String] = []
    let controls = try #require(
      page.container.terminalSplitControls(isRegularWidth: true) { reported.append($0) })
    controls.split(.columns, "bash")
    try await eventually("the split") { controls.panes.state != nil }
    #expect(controls.panes.state?.layout.keys == [.agent, .shell("terminal_zsh_1")])
    #expect(controls.panes.state?.focused == .shell("terminal_zsh_1"))
    let body = try page.server.posted("/v1/sessions/conv_a/resources/terminals").last
    #expect(String(describing: body).contains("bash"))
    #expect(PreferredTerminal.stored(in: page.defaults) == "bash")
    #expect(reported.isEmpty)

    // A listed shell asks before it ends; one the list no longer holds just goes.
    let agent = splitRow("terminal_agent", isAgent: true)
    page.terminals.terminals.apply(
      terminals: [agent, splitRow("terminal_zsh_1", isAgent: false)],
      harness: .ready(terminal: agent.terminal))
    controls.close(.shell("terminal_zsh_1"))
    #expect(controls.panes.closingShell == "terminal_zsh_1")
    controls.panes.closingShell = nil
    controls.panes.split(with: "terminal_gone", axis: .rows)
    controls.close(.shell("terminal_gone"))
    #expect(controls.panes.state?.layout.keys == [.agent, .shell("terminal_zsh_1")])
  }
}
