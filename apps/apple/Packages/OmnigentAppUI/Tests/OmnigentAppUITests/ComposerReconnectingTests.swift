import OmnigentCoreFFI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

@MainActor
@Suite("Composer while reconnecting")
struct ComposerReconnectingTests {
  @Test("A session waiting on a stream that is retrying says it is reconnecting, not loading")
  func reconnectingNotLoading() async throws {
    let loading = try await ConversationFixtures.store(hydrated: false)
    #expect(ComposerAdapter.availability(loading).reason?.contains("load") == true)
    let failure = CoreError.InvalidState(message: "down")
    loading.linkChanged(.reconnecting(reason: failure, failures: 1, delayMs: 2_000))
    #expect(ComposerAdapter.availability(loading).reason == "Reconnecting\u{2026}")
    // A first attempt still pending, before any failure, is loading.
    loading.linkChanged(.reconnecting(reason: failure, failures: 0, delayMs: 0))
    #expect(ComposerAdapter.availability(loading).reason?.contains("load") == true)
  }
}
