import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// What the user sees when a message goes out, is refused, or may not have arrived.
@MainActor
@Suite("Sending from the composer", .timeLimit(.minutes(1)))
struct ComposerSendTests {
  @Test("A send clears the draft and allows the next one")
  func sends() async throws {
    let live = try await LiveComposer()
    live.acceptMessages()
    let composer = live.composer
    #expect(!composer.canSend, "nothing to send yet")
    composer.text = "hello"
    #expect(composer.canSend)
    #expect(await composer.send() == .handled)
    #expect(composer.text.isEmpty)
    #expect(composer.lastError == nil)
    #expect(!composer.isSending)
    #expect(!composer.isBlocked)
    #expect(live.postedTexts == ["hello"])
  }

  @Test("A refusal returns the draft to the field to fix and try again")
  func refused() async throws {
    let live = try await LiveComposer()
    live.server.fail("/v1/sessions/conv_a/events", method: "POST", status: 400, detail: "no")
    let composer = live.composer
    composer.text = "hello"
    await composer.send()
    #expect(composer.text == "hello")
    #expect(composer.lastError != nil)
    #expect(!composer.isBlocked, "a definite refusal needs no review")
    #expect(composer.canSend)

    live.acceptMessages()
    await composer.send()
    #expect(composer.text.isEmpty)
    #expect(composer.lastError == nil)
  }

  @Test("A send that may have arrived blocks the next until the user reviews it")
  func uncertain() async throws {
    let live = try await LiveComposer()
    live.server.dropConnection("/v1/sessions/conv_a/events", method: "POST")
    let composer = live.composer
    composer.text = "hello"
    await composer.send()
    #expect(composer.lastError?.isDeliveryUncertain == true)
    #expect(composer.isBlocked)
    #expect(!composer.canSend)
    #expect(composer.text == "hello", "the draft is back to send again after the review")
    #expect(composer.unsentOffers.isEmpty)

    composer.acknowledgeUncertainSend()
    #expect(!composer.isBlocked)
    #expect(composer.lastError == nil)
    #expect(live.postedTexts.count == 1, "never retried on its own")
  }

  @Test("The field is empty the moment a send starts, and text typed meanwhile stays")
  func typingDuringSend() async throws {
    let live = try await LiveComposer()
    live.acceptMessages()
    let gate = live.server.hold("/v1/sessions/conv_a/events", method: "POST")
    let composer = live.composer
    composer.text = "first"
    let sending = Task { _ = await composer.send() }
    try await eventually("the post") { gate.arrivals == 1 }
    #expect(composer.isSending)
    #expect(composer.text.isEmpty, "the server has not answered yet")
    #expect(!composer.canSend)
    composer.text = "typed meanwhile"
    gate.release()
    await sending.value
    #expect(composer.text == "typed meanwhile")
    #expect(!composer.isSending)
    #expect(composer.lastError == nil)
    #expect(live.postedTexts == ["first"])
  }

  @Test("A message for an offline host waits in the queue and goes when the host returns")
  func heldForHost() async throws {
    let live = try await LiveComposer()
    live.hostIsOffline()
    let composer = live.composer
    composer.text = "hello"
    await composer.send()
    #expect(composer.text.isEmpty)
    #expect(composer.lastError == nil, "a held message is not a failure")
    #expect(composer.commandNotice == "The host is offline.")
    #expect(composer.queue.items.map(\.text) == ["hello"])
    #expect(composer.queue.items.first?.state == .waitingForHost)
    #expect(composer.queue.isHoldingForHost)

    live.acceptMessages()
    await composer.releaseHeldMessages()
    #expect(composer.queue.items.isEmpty)
    #expect(live.postedTexts.last == "hello")
  }

  @Test("Text typed while the offline refusal comes back stays in the field")
  func typingDuringOfflineRefusal() async throws {
    let live = try await LiveComposer()
    live.hostIsOffline()
    let gate = live.server.hold("/v1/sessions/conv_a/events", method: "POST")
    let composer = live.composer
    composer.text = "hello"
    let sending = Task { _ = await composer.send() }
    try await eventually("the post") { gate.arrivals == 1 }
    composer.text = "newer"
    gate.release()
    await sending.value
    #expect(composer.text == "newer")
    #expect(composer.queue.items.map(\.text) == ["hello"])
  }

  @Test("The header reporting the host online releases held messages")
  func hostComesBack() async throws {
    let live = try await LiveComposer()
    live.hostIsOffline()
    let composer = live.composer
    composer.text = "hello"
    await composer.send()

    live.acceptMessages()
    composer.hostCameOnline()
    try await eventually("the held message") { composer.queue.items.isEmpty }
    #expect(live.postedTexts.last == "hello")

    let posts = live.postedTexts.count
    composer.hostCameOnline()
    await composer.releaseHeldMessages()
    #expect(live.postedTexts.count == posts, "nothing is held any more")
  }

  @Test("Held messages wait for a running turn to end")
  func heldDuringATurn() async throws {
    let live = try await LiveComposer()
    live.hostIsOffline()
    let composer = live.composer
    composer.conversationFacts = {
      ConversationFacts(
        tokensUsed: nil, contextWindow: nil, items: 0, mcpServers: [], agentLoaded: false,
        isRunning: true, hostOnline: true)
    }
    composer.text = "hello"
    await composer.send()
    #expect(composer.hostRecheck != nil, "the host reads online, so a timer tries again")

    live.acceptMessages()
    await composer.releaseHeldMessages()
    #expect(composer.hostRecheck == nil)
    #expect(composer.queue.items.map(\.state) == [.queued])
    #expect(live.postedTexts.count == 1)
  }

  @Test("Attachments stage, and a refused upload leaves the file to retry or remove")
  func attachments() async throws {
    let live = try await LiveComposer()
    let composer = live.composer
    composer.addAttachment(filename: "a.txt", mediaType: "text/plain", data: Data("hi".utf8))
    let item = try #require(composer.attachments.items.first)
    #expect(composer.lastError == nil)
    #expect(composer.canSend, "a file alone can be sent")

    await composer.upload(item.id)
    #expect(composer.lastError != nil)
    #expect(composer.attachments.items.count == 1)

    composer.removeAttachment(item.id)
    #expect(composer.attachments.items.isEmpty)
    composer.removeAttachment(item.id)
    #expect(composer.lastError != nil, "removing it twice says so")
    await composer.upload(item.id)
    #expect(composer.lastError != nil)
  }

  @Test("A draft for another session shows when that session opens")
  func seedsOtherSessions() async throws {
    let live = try await LiveComposer()
    live.composer.seedDraft("question", forSession: "conv_b")
    #expect(live.composer.lastError == nil)
    let other = try #require(live.store.conversation("conv_b"))
    other.composer.streamReady()
    #expect(other.composer.text == "question")
  }
}
