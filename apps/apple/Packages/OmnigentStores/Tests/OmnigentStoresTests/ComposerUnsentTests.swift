import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// What happens to a message between Send and the server's answer, and after a refusal.
@MainActor
@Suite("Messages that left the composer and were not accepted", .timeLimit(.minutes(1)))
struct ComposerUnsentTests {
  private let eventsPath = "/v1/sessions/conv_a/events"

  /// Sends `text`, types `newer` while the server's answer is held, then lets the answer through.
  private func send(_ text: String, thenType newer: String, in live: LiveComposer) async throws {
    let gate = live.server.hold(eventsPath, method: "POST")
    let composer = live.composer
    composer.text = text
    let sending = Task { _ = await composer.send() }
    try await eventually("the post") { gate.arrivals == 1 }
    composer.text = newer
    gate.release()
    await sending.value
  }

  private func refuseMessages(_ live: LiveComposer) {
    live.server.fail(eventsPath, method: "POST", status: 400, detail: "no")
  }

  @Test("A refused draft returns whole to the empty field: text, quotes and paths")
  func refusalRestoresTheDraft() async throws {
    let live = try await LiveComposer()
    refuseMessages(live)
    let composer = live.composer
    composer.text = "Look:"
    composer.quote("a line")
    composer.text = "reply"
    composer.addMention("src/")

    await composer.send()

    #expect(composer.text == "reply")
    #expect(composer.quotes == [ReplyQuote(before: "Look:", text: "a line")])
    #expect(composer.mentions == ["src/"])
    #expect(composer.unsentOffers.isEmpty)
    #expect(composer.lastError != nil)
    #expect(live.conversation.rows.isEmpty, "the row shown at the send is withdrawn")
  }

  @Test("A refusal never overwrites newer text: the message is offered, and Restore appends it")
  func refusalOffersTheMessage() async throws {
    let live = try await LiveComposer()
    refuseMessages(live)
    let composer = live.composer

    try await send("hello", thenType: "newer", in: live)

    #expect(composer.text == "newer")
    let failure = try #require(composer.lastError)
    #expect(composer.unsentOffers.map(\.draft) == [SavedDraft(text: "hello")])
    #expect(composer.unsentOffers.first?.failure == failure.message)

    composer.restoreUnsent()
    #expect(composer.text == "newer\n\nhello")
    #expect(composer.unsentOffers.isEmpty)
    #expect(composer.lastError == failure, "the failure stays until it is dismissed")
    #expect(live.postedTexts == ["hello"], "never sent again on its own")
  }

  @Test("Offers stack oldest first, and dropping them leaves the field alone")
  func offersStackAndDrop() async throws {
    let live = try await LiveComposer()
    refuseMessages(live)
    let composer = live.composer
    try await send("one", thenType: "two", in: live)
    try await send("two", thenType: "three", in: live)
    #expect(composer.unsentOffers.map(\.draft.text) == ["one", "two"])

    composer.restoreUnsent()
    #expect(composer.text == "three\n\none\n\ntwo")

    try await send(composer.text, thenType: "four", in: live)
    #expect(composer.unsentOffers.count == 1)
    composer.discardUnsent()
    composer.discardUnsent()
    #expect(composer.unsentOffers.isEmpty)
    #expect(composer.text == "four")
  }

  @Test("A second send while the first is out queues, and leaves once the first is accepted")
  func secondSendFollows() async throws {
    let live = try await LiveComposer()
    live.acceptMessages()
    let gate = live.server.hold(eventsPath, method: "POST")
    let composer = live.composer
    composer.text = "first"
    let sending = Task { _ = await composer.send() }
    try await eventually("the post") { gate.arrivals == 1 }

    composer.text = "second"
    await composer.send()
    #expect(composer.text.isEmpty)
    #expect(composer.queue.items.map(\.text) == ["second"])
    #expect(live.postedTexts == ["first"], "one send in flight per session")
    await composer.send()
    #expect(composer.lastError != nil, "an empty field has nothing to queue")

    gate.release()
    await sending.value
    #expect(live.postedTexts == ["first", "second"])
    #expect(composer.queue.items.isEmpty)
    #expect(composer.followUps.isEmpty)
  }

  @Test("When the first is refused the second stays queued, and goes after the next accepted send")
  func secondSendWaitsOutARefusal() async throws {
    let live = try await LiveComposer()
    refuseMessages(live)
    let gate = live.server.hold(eventsPath, method: "POST")
    let composer = live.composer
    composer.text = "first"
    let sending = Task { _ = await composer.send() }
    try await eventually("the post") { gate.arrivals == 1 }
    composer.text = "second"
    await composer.send()
    gate.release()
    await sending.value

    #expect(composer.text == "first", "the field was empty, so the refused text is back")
    #expect(composer.queue.items.map(\.state) == [.queued])
    #expect(live.postedTexts == ["first"], "the second was not sent on its own")

    live.acceptMessages()
    await composer.send()
    #expect(live.postedTexts == ["first", "first", "second"])
    #expect(composer.queue.items.isEmpty)
  }

  @Test("A message that may have arrived is offered after newer text, and the review still blocks")
  func uncertainWithNewerText() async throws {
    let live = try await LiveComposer()
    live.server.dropConnection(eventsPath, method: "POST")
    let composer = live.composer

    try await send("hello", thenType: "newer", in: live)

    #expect(composer.lastError?.isDeliveryUncertain == true)
    #expect(composer.isBlocked)
    #expect(composer.text == "newer")
    #expect(
      composer.unsentOffers.first?.failure
        == "It may have been sent. Check the conversation before retrying.")
    composer.acknowledgeUncertainSend()
    #expect(!composer.isBlocked)
    #expect(composer.unsentOffers.count == 1, "the review does not drop the text")
    #expect(live.postedTexts.count == 1)
  }

  @Test("Uploaded files leave with the send and come back with a refused one")
  func filesLeaveAndReturn() async throws {
    let live = try await LiveComposer()
    refuseMessages(live)
    let composer = live.composer
    try await live.attachUploadedFile()
    let gate = live.server.hold(eventsPath, method: "POST")
    composer.text = "with a file"
    let sending = Task { _ = await composer.send() }
    try await eventually("the post") { gate.arrivals == 1 }
    #expect(composer.attachments.items.isEmpty)
    #expect(composer.text.isEmpty)
    gate.release()
    await sending.value

    #expect(composer.text == "with a file")
    #expect(composer.attachments.items.map(\.filename) == ["a.txt"])
    #expect(composer.unsentOffers.isEmpty)
  }

  @Test("An offered message keeps its files, and Restore returns them to the draft")
  func offeredFiles() async throws {
    let live = try await LiveComposer()
    refuseMessages(live)
    let composer = live.composer
    try await live.attachUploadedFile()

    try await send("with a file", thenType: "newer", in: live)
    #expect(composer.attachments.items.isEmpty)
    #expect(composer.unsentOffers.first?.extras.files.map(\.name) == ["a.txt"])

    composer.restoreUnsent()
    #expect(composer.attachments.items.map(\.filename) == ["a.txt"])
    #expect(composer.text == "newer\n\nwith a file")
  }

  @Test("A file added while the send was out counts as newer content: the message is offered")
  func fileAddedMeanwhile() async throws {
    let live = try await LiveComposer()
    refuseMessages(live)
    let composer = live.composer
    let gate = live.server.hold(eventsPath, method: "POST")
    composer.text = "hello"
    let sending = Task { _ = await composer.send() }
    try await eventually("the post") { gate.arrivals == 1 }
    composer.addAttachment(filename: "a.txt", mediaType: "text/plain", data: Data("hi".utf8))
    gate.release()
    await sending.value

    #expect(composer.text.isEmpty)
    #expect(composer.attachments.items.count == 1)
    #expect(composer.unsentOffers.map(\.draft.text) == ["hello"])
  }

  @Test("An offered file that cannot return keeps its message offered; dropping it says why")
  func offeredFilesWithNoConnection() async throws {
    let live = try await LiveComposer()
    refuseMessages(live)
    let composer = live.composer
    try await live.attachUploadedFile()
    try await send("with a file", thenType: "newer", in: live)
    live.store.disconnect()
    try await eventually("the disconnect") { live.store.phase == .disconnected }

    composer.lastError = nil
    composer.restoreUnsent()
    #expect(composer.lastError != nil)
    #expect(composer.unsentOffers.count == 1, "the message stays rather than losing its file")
    #expect(composer.text == "newer")

    composer.lastError = nil
    composer.discardUnsent()
    #expect(composer.lastError != nil)
    #expect(composer.unsentOffers.isEmpty)
  }

  @Test("A file that is not uploaded keeps everything in the draft, with the reason")
  func fileNotUploaded() async throws {
    let live = try await LiveComposer()
    live.acceptMessages()
    let composer = live.composer
    composer.addAttachment(filename: "a.txt", mediaType: "text/plain", data: Data("hi".utf8))
    composer.text = "with a file"

    await composer.send()

    #expect(composer.lastError != nil)
    #expect(composer.text == "with a file")
    #expect(composer.attachments.items.count == 1)
    #expect(live.postedTexts.isEmpty)
  }

  @Test("The text is in the saved drafts while it is out, so a relaunch gets it back as the draft")
  func survivesAQuit() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "drafts.json")
    let live = try await LiveComposer()
    live.acceptMessages()
    let archive = ComposerDraftArchive(fileURL: file)
    live.store.draftArchive = archive
    let account = try #require(live.store.connectedServer?.accountId)
    let gate = live.server.hold(eventsPath, method: "POST")
    let composer = live.composer
    composer.text = "hello"
    let sending = Task { _ = await composer.send() }
    try await eventually("the post") { gate.arrivals == 1 }
    #expect(composer.text.isEmpty)
    #expect(archive.draft(account: account, session: "conv_a") == SavedDraft(text: "hello"))
    composer.text = "newer"
    #expect(
      archive.draft(account: account, session: "conv_a") == SavedDraft(text: "newer\n\nhello"))
    composer.text = ""
    archive.flush()

    // A new core and archive read the same file, as after quitting while the send was out.
    let relaunched = try await connectedStore(RouteServer())
    relaunched.draftArchive = ComposerDraftArchive(fileURL: file)
    let restored = try #require(relaunched.conversation("conv_a"))
    #expect(restored.composer.text == "hello")
    #expect(restored.composer.queue.isEmpty, "it is a draft, not a send")
    relaunched.closeConversation("conv_a")

    gate.release()
    await sending.value
    #expect(archive.draft(account: account, session: "conv_a") == nil, "accepted: forgotten")
  }

  @Test("A refused message that is offered stays in the saved drafts until it is dropped")
  func offersAreSaved() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let live = try await LiveComposer()
    refuseMessages(live)
    let archive = ComposerDraftArchive(fileURL: folder.appending(path: "drafts.json"))
    live.store.draftArchive = archive
    let account = try #require(live.store.connectedServer?.accountId)

    try await send("hello", thenType: "newer", in: live)
    #expect(
      archive.draft(account: account, session: "conv_a") == SavedDraft(text: "newer\n\nhello"))

    live.composer.discardUnsent()
    #expect(archive.draft(account: account, session: "conv_a") == SavedDraft(text: "newer"))
  }
}

/// How a message that was not sent rejoins the draft, as the web joins them.
struct SavedDraftJoinTests {
  @Test("Text joins as a new paragraph, counting the line ends already there")
  func paragraphs() {
    #expect(SavedDraft(text: "a").appending(SavedDraft(text: "b")).text == "a\n\nb")
    #expect(SavedDraft(text: "a\n").appending(SavedDraft(text: "b")).text == "a\n\nb")
    #expect(SavedDraft(text: "a\n\n").appending(SavedDraft(text: "\nb")).text == "a\n\n\nb")
    #expect(SavedDraft(text: "").appending(SavedDraft(text: "b")).text == "b")
    #expect(SavedDraft(text: "a").appending(SavedDraft(text: "")).text == "a")
  }

  @Test("The later draft's first quote takes the earlier text before it; paths join once")
  func quotesAndPaths() {
    let earlier = SavedDraft(
      text: "typed since", quotes: [.init(before: "", text: "kept")], mentions: ["src/"])
    let later = SavedDraft(
      text: "reply",
      quotes: [.init(before: "Look:", text: "first"), .init(before: "and", text: "second")],
      mentions: ["src/", "docs/"])

    let joined = earlier.appending(later)

    #expect(joined.text == "reply")
    #expect(
      joined.quotes == [
        .init(before: "", text: "kept"), .init(before: "typed since\n\nLook:", text: "first"),
        .init(before: "and", text: "second"),
      ])
    #expect(joined.mentions == ["src/", "docs/"])
  }
}
