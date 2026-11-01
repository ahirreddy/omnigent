import Foundation
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
    store.closeConversation(ids[0])
    store.closeConversation(ids[1])
  }
}
