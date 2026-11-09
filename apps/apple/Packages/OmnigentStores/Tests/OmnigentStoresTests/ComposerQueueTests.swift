import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// Messages held for the end of the running turn: their order, edits and failures.
@MainActor
@Suite("The composer's queue", .timeLimit(.minutes(1)))
struct ComposerQueueTests {
  private func queued(_ texts: String...) async throws -> LiveComposer {
    let live = try await LiveComposer()
    for text in texts {
      live.composer.text = text
      live.composer.queueDraft()
    }
    return live
  }

  private func texts(_ composer: ComposerStore) -> [String] { composer.queue.items.map(\.text) }

  @Test("Queuing clears the draft; an empty draft is refused")
  func queues() async throws {
    let live = try await queued("one")
    let composer = live.composer
    #expect(composer.text.isEmpty)
    #expect(texts(composer) == ["one"])
    composer.queueDraft()
    #expect(composer.lastError?.message == "Type a message to queue.")
    #expect(texts(composer) == ["one"])
  }

  @Test("A queued message can be edited, moved and removed; stale ids say so")
  func edits() async throws {
    let live = try await queued("one", "two")
    let composer = live.composer
    let first = try #require(composer.queue.items.first?.id)
    composer.editQueued(first, text: "uno")
    #expect(texts(composer) == ["uno", "two"])
    composer.moveQueued(fromOffsets: IndexSet(integer: 1), toOffset: 0)
    #expect(texts(composer) == ["two", "uno"])
    composer.removeQueued(first)
    #expect(texts(composer) == ["two"])
    composer.removeQueued(first)
    #expect(composer.lastError?.message == "That message is no longer queued.")
    composer.editQueued(first, text: "gone")
    #expect(composer.lastError?.message == "That message is no longer queued.")
    await composer.sendQueuedNow(first)
    #expect(composer.lastError?.message == "That message is no longer queued.")
  }

  @Test("Up in an empty composer takes the newest message back, with its paths")
  func takesLast() async throws {
    let live = try await LiveComposer()
    let composer = live.composer
    #expect(composer.takeLastQueued() == nil)
    composer.addMention("src/a.swift")
    composer.text = "one"
    composer.queueDraft()
    #expect(composer.mentions.isEmpty)
    #expect(composer.takeLastQueued() == "one")
    #expect(composer.mentions == ["src/a.swift"])
    #expect(composer.queue.items.isEmpty)
  }

  @Test("The message being sent can't be taken back or sent twice")
  func sendingStays() async throws {
    let live = try await queued("one")
    live.acceptMessages()
    let gate = live.server.hold("/v1/sessions/conv_a/events", method: "POST")
    let composer = live.composer
    let id = try #require(composer.queue.items.first?.id)
    let sending = Task { await composer.sendQueuedNow(id) }
    try await eventually("the post") { gate.arrivals == 1 }
    #expect(composer.takeLastQueued() == nil)
    await composer.sendQueuedNow(id)
    #expect(composer.lastError?.message == "Wait for the current send to finish.")
    gate.release()
    await sending.value
    #expect(composer.queue.items.isEmpty)
    #expect(live.postedTexts == ["one"])
  }

  @Test("The turn ending sends only the oldest message")
  func drains() async throws {
    let live = try await queued("one", "two")
    live.acceptMessages()
    let composer = live.composer
    await composer.drainQueue(isRunning: true)
    #expect(live.postedTexts.isEmpty, "a turn is still running")
    await composer.drainQueue(isRunning: false)
    #expect(live.postedTexts == ["one"])
    #expect(texts(composer) == ["two"])
  }

  @Test("Send all keeps order and stops at the first that doesn't go out")
  func sendsAll() async throws {
    let live = try await queued("one", "two")
    live.server.fail("/v1/sessions/conv_a/events", method: "POST", status: 400, detail: "no")
    let composer = live.composer
    await composer.sendAllQueuedNow()
    #expect(live.postedTexts == ["one"])
    #expect(texts(composer) == ["one", "two"])
    guard case .failed = composer.queue.items.first?.state else {
      Issue.record("state: \(String(describing: composer.queue.items.first?.state))")
      return
    }
    #expect(composer.lastError != nil)

    live.acceptMessages()
    await composer.sendAllQueuedNow()
    #expect(texts(composer) == ["one"], "the failed one waits for the user; the rest go")
    #expect(live.postedTexts.last == "two")
  }

  @Test("A queued send that may have arrived warns before a retry and blocks the next")
  func uncertainQueuedSend() async throws {
    let live = try await queued("one")
    live.server.dropConnection("/v1/sessions/conv_a/events", method: "POST")
    let composer = live.composer
    let id = try #require(composer.queue.items.first?.id)
    await composer.sendQueuedNow(id)
    #expect(
      composer.queue.items.first?.state
        == .failed("It may have been sent. Check the conversation before retrying."))
    #expect(composer.isBlocked)
    await composer.drainQueue(isRunning: false)
    #expect(live.postedTexts.count == 1)
  }

  @Test("A queued message for an offline host waits and says why")
  func queuedHostOffline() async throws {
    let live = try await queued("one")
    live.hostIsOffline()
    let composer = live.composer
    let id = try #require(composer.queue.items.first?.id)
    await composer.sendQueuedNow(id)
    #expect(composer.queue.items.first?.state == .waitingForHost)
    #expect(composer.commandNotice == "The host is offline.")
    #expect(composer.lastError == nil)
  }

  @Test("A queued message keeps its uploaded files and returns them when taken back")
  func queuedFiles() async throws {
    let live = try await LiveComposer()
    let composer = live.composer
    composer.addAttachment(filename: "a.txt", mediaType: "text/plain", data: Data("hi".utf8))
    let item = try #require(composer.attachments.items.first)
    live.server.route(
      "/v1/sessions/conv_a/resources/files", method: "POST",
      .json(#"{"id":"file_1","session_id":"conv_a"}"#, status: 201))
    await composer.upload(item.id)
    try #require(composer.lastError == nil, "\(String(describing: composer.lastError))")

    composer.text = "one"
    composer.queueDraft()
    #expect(composer.attachments.items.isEmpty)
    #expect(composer.queue.items.first?.extras.files.map(\.name) == ["a.txt"])

    #expect(composer.takeLastQueued() == "one")
    #expect(composer.attachments.items.count == 1)

    composer.text = "two"
    composer.queueDraft()
    let id = try #require(composer.queue.items.first?.id)
    composer.removeQueued(id)
    #expect(composer.attachments.items.isEmpty, "removing the message forgets its files")
    #expect(composer.lastError == nil)
  }

  @Test("A file still uploading keeps everything in the draft")
  func fileStillUploading() async throws {
    let live = try await LiveComposer()
    let composer = live.composer
    composer.addAttachment(filename: "a.txt", mediaType: "text/plain", data: Data("hi".utf8))
    composer.text = "one"
    composer.queueDraft()
    #expect(composer.lastError != nil)
    #expect(composer.text == "one")
    #expect(composer.queue.items.isEmpty)
    #expect(composer.attachments.items.count == 1)
  }
}
