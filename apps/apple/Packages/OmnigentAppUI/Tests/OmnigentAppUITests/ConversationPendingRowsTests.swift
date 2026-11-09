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
