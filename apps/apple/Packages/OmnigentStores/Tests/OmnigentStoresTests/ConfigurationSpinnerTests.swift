import OmnigentCoreFFI
import Testing

@testable import OmnigentStores

/// The configuration menu's spinner follows ``ComposerStore/isApplyingConfiguration``. The small
/// circle beside the approval chip is the context ring, not this spinner.
@MainActor
@Suite("The configuration spinner can't stick", .serialized)
struct ConfigurationSpinnerTests {
  @Test("every kind of failed change ends the spinner and says why")
  func failuresEndTheSpinner() async throws {
    let gate = EventsGate()
    let (connection, conversation) = try await LiveConversationFixture.connected(gate)
    defer { connection.closeConversation(liveSessionID) }
    let composer = conversation.composer
    await composer.loadConfiguration()
    try #require(composer.configuration != nil)

    let changes: [(String, @MainActor () async -> Void)] = [
      ("effort", { await composer.selectEffort("low") }),
      ("model", { await composer.selectModel("no-such-model") }),
      ("harness", { await composer.switchHarness(to: "no-such-agent") }),
    ]
    for (name, change) in changes {
      await change()
      #expect(!composer.isApplyingConfiguration, "\(name)")
      #expect(composer.configurationError != nil, "\(name)")
    }
  }

  @Test("a change cancelled while in flight ends the spinner too")
  func cancellationEndsTheSpinner() async throws {
    let gate = EventsGate()
    let (connection, conversation) = try await LiveConversationFixture.connected(gate)
    defer { connection.closeConversation(liveSessionID) }
    let composer = conversation.composer
    await composer.loadConfiguration()
    let change = Task { await composer.selectEffort("low") }
    change.cancel()
    await change.value
    #expect(!composer.isApplyingConfiguration)
  }
}
