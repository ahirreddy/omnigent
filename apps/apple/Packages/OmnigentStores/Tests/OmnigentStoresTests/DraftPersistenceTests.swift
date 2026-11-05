import Foundation
import Observation
import Synchronization
import Testing

@testable import OmnigentStores

/// The phone reading posture keeps drafts per session: leaving a session closes its stream, and
/// coming back restores what the user had typed.
@MainActor
struct DraftPersistenceTests {
  private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
      guard ContinuousClock.now < deadline else {
        Issue.record("Timed out waiting for \(what)")
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  @Test(.timeLimit(.minutes(1))) func draftsSurviveClosingAndReopeningASession() async throws {
    let store = try await PreviewData.connectedDemoStore()
    let list = store.sessionList
    try await waitUntil("the sample list") { list.sessionsByID.count >= 2 }
    let ids = list.sessionsByID.keys.sorted()
    let first = try #require(store.conversation(ids[0]))
    try await waitUntil("the first session") { first.isHydrated }
    first.composer.text = "Draft for the first session"
    let second = try #require(store.conversation(ids[1]))
    try await waitUntil("the second session") { second.isHydrated }
    second.composer.text = "Another draft"

    store.closeConversation(ids[0])
    #expect(store.conversations[ids[0]] == nil)
    let reopened = try #require(store.conversation(ids[0]))
    try await waitUntil("the restored draft") {
      reopened.composer.text == "Draft for the first session"
    }
    #expect(reopened.composer.text == "Draft for the first session")
    #expect(second.composer.text == "Another draft")
    // The sidebar's draft marker follows whether each composer holds text.
    #expect(list.draftSessionIDs == [ids[0], ids[1]])
    second.composer.text = "  "
    #expect(list.draftSessionIDs == [ids[0]])
    store.closeConversation(ids[0])
    store.closeConversation(ids[1])
  }

  @Test(.timeLimit(.minutes(1))) func hasDraftChangesOnlyWhenTheDraftEmptiesOrFills() async throws {
    let store = try await PreviewData.connectedDemoStore()
    let list = store.sessionList
    try await waitUntil("the sample list") { !list.sessionsByID.isEmpty }
    let id = try #require(list.sessionsByID.keys.min())
    let composer = try #require(store.conversation(id)).composer
    try await waitUntil("the session") { store.conversations[id]?.isHydrated == true }
    let flips = Mutex(0)
    func track() {
      withObservationTracking {
        _ = composer.hasDraft
      } onChange: {
        flips.withLock { $0 += 1 }
      }
    }
    track()
    composer.text = " \n"
    #expect(!composer.hasDraft)
    #expect(flips.withLock { $0 } == 0)
    composer.text = "H"
    #expect(composer.hasDraft)
    track()
    // Typing on, or adding trailing space, leaves it alone.
    composer.text = "Hello"
    composer.text = "Hello \n"
    #expect(flips.withLock { $0 } == 1)
    composer.text = ""
    #expect(!composer.hasDraft)
    #expect(flips.withLock { $0 } == 2)
    store.closeConversation(id)
  }

  @Test func blankDraftsAreWhitespaceAndNewlinesOnly() {
    #expect(!ComposerStore.isNonBlank(""))
    #expect(!ComposerStore.isNonBlank(" \t\n\r\u{00A0}\u{2029}"))
    #expect(ComposerStore.isNonBlank("  x "))
    // The same rule as trimming whitespace and newlines.
    for text in ["\u{200B}", "\u{3000}a", "\n\n", "é", "\u{FEFF}"] {
      #expect(
        ComposerStore.isNonBlank(text)
          == !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }
}
