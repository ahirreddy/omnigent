import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// A view that shows one session's conversation hears of that session opening and closing only.
@MainActor
@Suite("Open conversation observation", .timeLimit(.minutes(1)))
struct OpenConversationObservationTests {
  @Test("a view that read one session's conversation is not told when another opens or closes")
  func oneSessionsReaderIgnoresOtherSessions() async throws {
    let store = try await connectedStore(RouteServer())
    let readsA = { _ = store.openConversation("conv_a") }
    #expect(!observationNotifies(readsA) { _ = store.conversation("conv_b") })
    #expect(!observationNotifies(readsA) { store.closeConversation("conv_b") })
    #expect(store.openConversation("conv_a") == nil)

    // Its own conversation opening and closing reach it, with the store that opened.
    #expect(observationNotifies(readsA) { _ = store.conversation("conv_a") })
    let opened = try #require(store.openConversation("conv_a"))
    #expect(opened === store.conversations["conv_a"])
    #expect(observationNotifies(readsA) { store.closeConversation("conv_a") })
    #expect(store.openConversation("conv_a") == nil)

    // A reader of every open conversation still hears of each.
    let readsAll = { _ = store.conversations }
    #expect(observationNotifies(readsAll) { _ = store.conversation("conv_b") })
    #expect(observationNotifies(readsAll) { store.closeConversation("conv_b") })
  }
}
