import OmnigentCoreFFI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// When the app tries the server again on its own, and how often.
@MainActor
@Suite("Automatic reconnect", .timeLimit(.minutes(1)))
struct AutomaticReconnectTests {
  private let lost = CoreError.Link(
    kind: .connection, message: "connection lost", requiresSignIn: false)

  @Test("The app's tries widen from 2 seconds to a 30-second ceiling")
  func schedule() {
    let delays = (1...7).map { AutomaticReconnect.delay(attempt: $0) }
    #expect(delays == [2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
    #expect(AutomaticReconnect.delay(attempt: 0) == .seconds(2))
  }

  @Test("Only a link that gave up waits for the app; a reconnecting one is the core's to retry")
  func whoRetries() async throws {
    let store = try await ConversationFixtures.connection()
    #expect(!AutomaticReconnect.waitsForTheApp(store))
    store.apply(.updatesLinkChanged(state: .live))
    store.apply(.updatesLinkChanged(state: .reconnecting(reason: lost, failures: 3, delayMs: 5)))
    #expect(store.health.reachability.isDisrupted)
    #expect(!AutomaticReconnect.waitsForTheApp(store), "the core is retrying")
    store.apply(.updatesLinkChanged(state: .failed(error: lost)))
    #expect(AutomaticReconnect.waitsForTheApp(store))
    store.apply(.updatesLinkChanged(state: .live))
    #expect(!AutomaticReconnect.waitsForTheApp(store))
  }

  @Test("A connect on its way is left to finish")
  func connectInFlight() async throws {
    let store = try await ConversationFixtures.connection()
    #expect(!AutomaticReconnect.isConnecting(store))
    store.apply(.connectionChanged(phase: .discovering(serverUrl: "http://127.0.0.1:6767")))
    #expect(AutomaticReconnect.isConnecting(store))
  }
}
