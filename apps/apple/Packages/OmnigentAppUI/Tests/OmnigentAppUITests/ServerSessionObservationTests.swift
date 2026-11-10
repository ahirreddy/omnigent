import Observation
import OmnigentStores
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentAppUI

/// A tab that shows one session reads that session's stores, not every open session's.
@MainActor
@Suite("Server session observation", .serialized, .timeLimit(.minutes(1)))
struct ServerSessionObservationTests {
  @Test("a view that read one session's stores is not told when another session opens or closes")
  func oneSessionsReaderIgnoresOtherSessions() async throws {
    let session = try await signedInSession(threeSessionServer())
    let readsA = {
      _ = (
        session.terminals(of: "conv_a"), session.workspace(of: "conv_a"),
        session.panel(of: "conv_a")
      )
    }
    #expect(!observationNotifies(readsA) { session.open("conv_b") })
    #expect(!observationNotifies(readsA) { session.close("conv_b") })
    #expect(session.terminals(of: "conv_a") == nil)
    #expect(session.workspace(of: "conv_a") == nil)
    #expect(session.panel(of: "conv_a") == nil)

    // Its own session opening and closing reach it, with the stores that opened.
    #expect(observationNotifies(readsA) { session.open("conv_a") })
    let terminals = try #require(session.terminals(of: "conv_a"))
    let workspace = try #require(session.workspace(of: "conv_a"))
    let panel = try #require(session.panel(of: "conv_a"))
    #expect(terminals === session.terminalStores["conv_a"])
    #expect(workspace === session.workspaces["conv_a"])
    #expect(panel === session.panels["conv_a"])
    #expect(observationNotifies(readsA) { session.close("conv_a") })
    #expect(session.terminals(of: "conv_a") == nil)
    #expect(session.workspace(of: "conv_a") == nil)
    #expect(session.panel(of: "conv_a") == nil)
  }

  @Test("the terminal names a session's agent declares reach the view that reads that session")
  func declaredNamesReachTheirReader() async throws {
    let server = threeSessionServer()
    server.route("/v1/sessions/conv_a/agent", .json(#"{"terminals":["zsh","bash"]}"#))
    server.route("/v1/sessions/conv_b/agent", .json(#"{"terminals":["fish"]}"#))
    let session = try await signedInSession(server)
    #expect(session.declaredTerminalNames(in: "conv_a") == .unknown)
    let told = Mutex(false)
    withObservationTracking {
      _ = session.declaredTerminalNames(in: "conv_a")
    } onChange: {
      told.withLock { $0 = true }
    }
    await session.loadDeclaredTerminalNames(["conv_b"])
    #expect(session.declaredTerminalNames(in: "conv_b") == .names(["fish"]))
    #expect(!told.withLock { $0 }, "another session's names")
    await session.loadDeclaredTerminalNames(["conv_a"])
    #expect(told.withLock { $0 })
    #expect(session.declaredTerminalNames(in: "conv_a") == .names(["zsh", "bash"]))
  }
}
