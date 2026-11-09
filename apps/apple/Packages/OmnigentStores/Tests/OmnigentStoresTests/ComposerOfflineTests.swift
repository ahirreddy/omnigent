import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The composer of a session left open after the connection ended: what the user does there
/// reports the failure rather than vanishing.
@MainActor
@Suite("A composer with no connection", .timeLimit(.minutes(1)))
struct ComposerOfflineTests {
  private func offline() async throws -> (ConnectionStore, ComposerStore) {
    let store = try await connectedStore(RouteServer())
    let conversation = try #require(store.conversation("conv_a"))
    store.disconnect()
    try await eventually("the disconnect") { store.phase == .disconnected }
    return (store, conversation.composer)
  }

  @Test("Typing keeps the text and reports the failure")
  func typing() async throws {
    let (_, composer) = try await offline()
    composer.text = "still here"
    #expect(composer.text == "still here")
    #expect(composer.lastError != nil)
  }

  @Test("A file added, removed or reviewed reports the failure")
  func attachments() async throws {
    let (_, composer) = try await offline()
    composer.addAttachment(filename: "a.txt", mediaType: "text/plain", data: Data("x".utf8))
    #expect(composer.lastError != nil)
    #expect(composer.attachments.items.isEmpty)
    composer.lastError = nil
    composer.removeAttachment(1)
    #expect(composer.lastError != nil)
    composer.lastError = nil
    composer.acknowledgeUncertainSend()
    #expect(composer.lastError != nil)
  }

  @Test("Stream and status refreshes report the failure and change nothing")
  func refreshes() async throws {
    let (_, composer) = try await offline()
    composer.streamReady()
    #expect(composer.lastError != nil)
    composer.lastError = nil
    composer.refreshBlocked()
    #expect(composer.lastError != nil)
    composer.lastError = nil
    composer.seedDraft("hi", forSession: "conv_a")
    #expect(composer.lastError != nil)
  }

  @Test("Queueing with files that can't be held keeps the message in the draft")
  func queueing() async throws {
    let (_, composer) = try await offline()
    composer.text = "queue me"
    composer.lastError = nil
    composer.queueDraft()
    #expect(composer.queue.items.isEmpty)
    #expect(composer.text == "queue me")
    #expect(composer.lastError != nil)
  }
}
