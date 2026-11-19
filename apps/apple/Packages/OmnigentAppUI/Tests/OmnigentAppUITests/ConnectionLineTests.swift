import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// What the connection lines say: one plain reason, and one line per outage.
@MainActor
@Suite("Connection lines", .timeLimit(.minutes(1)))
struct ConnectionLineTests {
  private let server = "http://127.0.0.1:6767"

  @Test("A reason is the system's own words, without the layers that carried it")
  func plainReasons() {
    let refused = CoreError.Transport(
      kind: .offline, message: "offline: Could not connect to the server.")
    #expect(ConnectionReason.text(refused) == "Could not connect to the server.")
    let lost = CoreError.Link(
      kind: .connection, message: "connection failed: offline: Could not connect to the server.",
      requiresSignIn: false)
    #expect(ConnectionReason.text(lost) == "Could not connect to the server.")
    let ended = CoreError.Link(
      kind: .endOfStream, message: "stream ended without [DONE]", requiresSignIn: false)
    #expect(ConnectionReason.text(ended) == "The server closed the connection.")
    let silent = CoreError.Link(
      kind: .stalled, message: "no data for 45000 ms", requiresSignIn: false)
    #expect(ConnectionReason.text(silent) == "The server stopped responding.")
    #expect(
      ConnectionReason.text(.HttpStatus(status: 502, body: "")) == "The server answered HTTP 502.")
  }

  @Test("While the window says the server is away, the composer's line does not repeat it")
  func oneLinePerOutage() async throws {
    let store = try await ConversationFixtures.store()
    let lost = CoreError.Link(kind: .connection, message: "lost", requiresSignIn: false)
    store.linkChanged(.reconnecting(reason: lost, failures: 2, delayMs: 2_000))
    let alone = ComposerAdapter.state(store, isStopping: false, dismissedError: nil)
    #expect(alone.connection != nil, "a session's own stream problem shows under its composer")
    let covered = ComposerAdapter.state(
      store, isStopping: false, dismissedError: nil, windowShowsOutage: true)
    #expect(covered.connection == nil)
    #expect(covered.statusPlaceholder == nil, "no Reconnect below to point at")

    let health = ConnectionHealth()
    _ = health.observe(server: server, signal: .reachable)
    #expect(!ConnectionIssuesBanner.showsOutage(health))
    _ = health.observe(server: server, signal: .disrupted(.reconnecting(reason: lost, failures: 1)))
    #expect(ConnectionIssuesBanner.showsOutage(health))
    _ = health.observe(server: server, signal: .disrupted(.offline))
    #expect(!ConnectionIssuesBanner.showsOutage(health), "offline keeps the composer's own line")
  }
}
