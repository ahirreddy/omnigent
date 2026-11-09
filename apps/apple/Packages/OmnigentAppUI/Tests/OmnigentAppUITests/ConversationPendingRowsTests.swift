import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// A message being sent reaches the transcript through both of the adapter's row readers.
@MainActor
@Suite("Conversation pending rows")
struct ConversationPendingRowsTests {
  @Test("a sent message shows in the rows and moves the revision the transcript follows")
  func pendingMessageReachesTheTranscript() async throws {
    let store = try await ConversationFixtures.store()
    let before = ConversationAdapter.liveRows(store).read().revision

    _ = store.showSending("Ship it")

    let live = ConversationAdapter.liveRows(store).read()
    #expect(live.rows.map(\.text) == ["Ship it"])
    #expect(live.revision != before)
    let state = ConversationAdapter.state(store, summary: nil)
    #expect(state.rows.map(\.text) == ["Ship it"])
    #expect(ConversationAdapter.screenState(store, summary: nil).transcriptStatus?.isEmpty == false)
  }
}

/// The connection line under the composer owns stream problems, so they aren't a card as well.
@MainActor
@Suite("Conversation failure cards")
struct ConversationFailureCardTests {
  private let streamFailure = CoreError.Link(
    kind: .httpStatus, message: "HTTP 500", requiresSignIn: false)

  @Test("a lost stream shows on the connection line only, and leaves with it")
  func streamFailures() async throws {
    let store = try await ConversationFixtures.store()
    store.linkChanged(.reconnecting(reason: streamFailure, failures: 2, delayMs: 2_000))
    #expect(ConversationAdapter.errorMessage(store) == nil)
    #expect(ConversationAdapter.connectionStatus(store)?.contains("HTTP 500") == true)

    store.linkChanged(.failed(error: streamFailure))
    #expect(ConversationAdapter.errorMessage(store) == nil)
    #expect(ComposerAdapter.connection(store)?.isFailure == true)
  }

  @Test("other failures stay a card, and a turn's failure falls back to it")
  func otherFailures() async throws {
    let store = try await ConversationFixtures.store()
    store.failure("The turn failed")
    #expect(ConversationAdapter.errorMessage(store) == "The turn failed")
    store.record(.InvalidState(message: "Could not save"))
    #expect(ConversationAdapter.errorMessage(store) == "Could not save")
  }

  @Test("a session whose stream gave up on 404s reads as no longer available")
  func goneSession() async throws {
    let store = try await ConversationFixtures.store()
    let notFound = CoreError.Link(kind: .notFound, message: "HTTP 404", requiresSignIn: false)
    store.linkChanged(.failed(error: notFound))
    #expect(ConversationAdapter.errorMessage(store) == nil)
    #expect(ConversationAdapter.connectionStatus(store) == "This session is no longer available.")
    #expect(ComposerAdapter.connection(store) == nil)
  }
}
