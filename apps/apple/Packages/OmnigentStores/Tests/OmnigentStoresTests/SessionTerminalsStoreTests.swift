import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The session's terminal list: opening and closing shells, and what the agent declares.
@MainActor
@Suite("Session terminals", .timeLimit(.minutes(1)))
struct SessionTerminalsStoreTests {
  private func resource(_ id: String, agent: Bool = false) -> TerminalResource {
    TerminalResource(
      id: id, sessionId: "conv_a", terminalName: id, sessionKey: "key", running: true,
      environment: nil, directAttachUrl: nil, isAgentTerminal: agent, displayLabel: id)
  }

  private func terminals(_ server: RouteServer) async throws -> SessionTerminalsStore {
    try #require(try await connectedStore(server).terminals("conv_a"))
  }

  @Test("The agent's declared names load; an older server leaves them unknown")
  func declaredNames() async throws {
    let server = RouteServer()
    let terminals = try await terminals(server)
    await terminals.loadDeclaredTerminalNames()
    #expect(terminals.lastError != nil)
    #expect(!terminals.knowsDeclaredTerminalNames)
    terminals.dismissError()
    #expect(terminals.lastError == nil)

    server.route("/v1/sessions/conv_a/agent", .json(#"{"id":"a1","terminals":["zsh","bash"]}"#))
    await terminals.loadDeclaredTerminalNames()
    #expect(terminals.declaredTerminalNames == ["zsh", "bash"])
    #expect(terminals.knowsDeclaredTerminalNames)

    server.route("/v1/sessions/conv_a/agent", .json(#"{"id":"a1"}"#))
    await terminals.loadDeclaredTerminalNames()
    #expect(terminals.declaredTerminalNames.isEmpty)
    #expect(!terminals.knowsDeclaredTerminalNames)
  }

  @Test("A refused create or close says why and leaves nothing busy")
  func refusedWrites() async throws {
    let server = RouteServer()
    server.fail("/v1/sessions/conv_a/resources/terminals/terminal_zsh", method: "DELETE")
    let terminals = try await terminals(server)
    #expect(await terminals.create("zsh") == nil)
    #expect(terminals.lastError != nil)
    #expect(!terminals.isBusy)
    terminals.dismissError()
    await terminals.delete("terminal_zsh")
    #expect(terminals.lastError != nil)
    #expect(!terminals.isBusy)
  }

  @Test("The user's shells leave out the agent's own terminal")
  func userShells() async throws {
    let terminals = try await terminals(RouteServer())
    terminals.apply(
      terminals: [
        TerminalRow(terminal: resource("agent", agent: true), status: .active),
        TerminalRow(terminal: resource("zsh"), status: .active),
      ],
      harness: .startingUp)
    #expect(terminals.userShells.map(\.terminal.id) == ["zsh"])
    #expect(terminals.harness == .startingUp)
    terminals.refresh()
  }
}
