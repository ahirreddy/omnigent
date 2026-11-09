import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentStores

private func userRow(_ id: String, _ text: String) -> Row {
  Row(
    id: id, role: .user, text: text, isStreaming: false, activity: nil, attachments: [],
    callId: nil, responseId: nil, interrupted: false, author: nil, agent: nil, createdAt: 1,
    isEphemeral: false, isActivityOnly: false)
}

@Suite("Messages waiting for their echo")
struct PendingMessagesTests {
  @Test("an echo matches by item id even when the server reworded the text")
  func matchesByItemID() throws {
    var pending = PendingMessages()
    let added = pending.add(text: "hello", attachments: [], transcript: [])
    let rowID = try #require(added)
    pending.acknowledge(rowID, itemID: "item_1")
    pending.retireEchoes(in: [userRow("item_2", "unrelated"), userRow("item_1", "reworded")])
    #expect(pending.rows.isEmpty)
  }

  @Test("a stream echo beating the acknowledgement matches by text, past any preamble")
  func matchesByText() {
    for (sent, echoed) in [
      ("hello", "hello"), ("hello\n", "  hello "), ("look", "@src/a.swift\n\nlook"),
      ("日本語 🎉", "日本語 🎉"),
    ] {
      var pending = PendingMessages()
      _ = pending.add(text: sent, attachments: [], transcript: [])
      pending.retireEchoes(in: [userRow("item", echoed)])
      #expect(pending.rows.isEmpty, "\(sent) against \(echoed)")
    }
  }

  @Test("an older row with the same text is no echo, wherever it shows up")
  func olderRowsAreNotEchoes() {
    var pending = PendingMessages()
    let shown = [userRow("old", "yes")]
    _ = pending.add(text: "yes", attachments: [], transcript: shown)
    pending.retireEchoes(in: shown)
    #expect(pending.rows.count == 1)
    // A page of older history arrives above what was shown.
    pending.retireEchoes(in: [userRow("older", "yes")] + shown)
    #expect(pending.rows.count == 1)
    pending.retireEchoes(in: [userRow("older", "yes")] + shown + [userRow("new", "yes")])
    #expect(pending.rows.isEmpty)
  }

  @Test("each echo retires one message, so the same text sent twice shows twice")
  func oneEchoPerMessage() {
    var pending = PendingMessages()
    _ = pending.add(text: "again", attachments: [], transcript: [])
    _ = pending.add(text: "again", attachments: [], transcript: [])
    let first = userRow("item_1", "again")
    pending.retireEchoes(in: [first])
    #expect(pending.rows.count == 1)
    pending.retireEchoes(in: [first])
    #expect(pending.rows.count == 1)
    pending.retireEchoes(in: [first, userRow("item_2", "again")])
    #expect(pending.rows.isEmpty)
  }

  @Test("an assistant row or a preview is never an echo")
  func onlyPersistedUserRowsEcho() {
    var pending = PendingMessages()
    _ = pending.add(text: "hello", attachments: [], transcript: [])
    var assistant = userRow("reply", "hello")
    assistant.role = .assistant
    var preview = userRow("live:other", "hello")
    preview.isEphemeral = true
    pending.retireEchoes(in: [assistant, preview])
    #expect(pending.rows.count == 1)
  }

  @Test("a blank message shows nothing; files alone show, and any new user row echoes them")
  func blankAndFileOnlyMessages() throws {
    var pending = PendingMessages()
    #expect(pending.add(text: " \n", attachments: [], transcript: []) == nil)
    #expect(pending.generation == 0)
    let file = PendingMessages.attachment(id: "1", name: "a.png", mediaType: nil, isImage: true)
    let added = pending.add(text: "", attachments: [file], transcript: [])
    let rowID = try #require(added)
    #expect(pending.rows.first?.attachments == [file])
    #expect(pending.rows.first?.id == rowID)
    pending.retireEchoes(in: [userRow("item", "")])
    #expect(pending.rows.isEmpty)
  }

  @Test("the rows read as a user's previews, and every change moves the generation")
  func rowShapeAndGeneration() throws {
    var pending = PendingMessages()
    let added = pending.add(text: " hi ", attachments: [], transcript: [])
    let rowID = try #require(added)
    let row = try #require(pending.rows.first)
    #expect(row.role == .user)
    #expect(row.text == "hi")
    #expect(row.isEphemeral)
    #expect(pending.generation == 1)
    pending.withdraw("unknown")
    #expect(pending.generation == 1)
    pending.withdraw(rowID)
    #expect(pending.generation == 2)
    #expect(pending.rows.isEmpty)
  }
}

@MainActor
@Suite("Sending shows the message at once", .serialized)
struct OptimisticSendTests {
  private static let echo = """
    {"object":"list","data":[{"id":"item_1","type":"message","role":"user","status":"completed",\
    "content":[{"type":"input_text","text":"Ship it"}],"created_at":1}],"has_more":false}
    """

  @Test("a follow-up shows before the server answers, and its echo doesn't duplicate it")
  func followUpShowsAtOnce() async throws {
    let gate = EventsGate()
    let (connection, conversation) = try await LiveConversationFixture.connected(gate)
    defer { connection.closeConversation(liveSessionID) }
    let revision = conversation.displayRevision

    conversation.composer.text = "Ship it"
    let sending = Task { await conversation.composer.send() }
    try await LiveConversationFixture.waitUntil("the POST") { gate.isWaiting }
    #expect(conversation.displayRows.map(\.text) == ["Ship it"])
    #expect(conversation.displayRows.first?.isEphemeral == true)
    #expect(conversation.rows.isEmpty)
    #expect(!conversation.transcriptDigest.isEmpty)
    #expect(conversation.displayRevision != revision)

    gate.setItems(Self.echo)
    gate.release(.json(#"{"queued":true,"item_id":"item_1"}"#))
    _ = await sending.value
    try await LiveConversationFixture.waitUntil("the echo") { conversation.rows.count == 1 }
    #expect(conversation.displayRows.map(\.id) == ["item_1"])
    #expect(conversation.composer.lastError == nil)
    #expect(conversation.composer.text.isEmpty)
  }

  @Test("a refused message leaves the transcript and stays in the draft")
  func refusalWithdrawsTheRow() async throws {
    let gate = EventsGate()
    let (connection, conversation) = try await LiveConversationFixture.connected(gate)
    defer { connection.closeConversation(liveSessionID) }

    conversation.composer.text = "Ship it"
    let sending = Task { await conversation.composer.send() }
    try await LiveConversationFixture.waitUntil("the POST") { gate.isWaiting }
    #expect(conversation.displayRows.count == 1)
    gate.release(.json(#"{"detail":"no"}"#, status: 400))
    _ = await sending.value
    #expect(conversation.displayRows.isEmpty)
    #expect(conversation.composer.lastError != nil)
    #expect(conversation.composer.text == "Ship it")
  }

  @Test("a queued message shows when it goes out, not while it waits")
  func queuedMessageShowsWhenSent() async throws {
    let gate = EventsGate()
    let (connection, conversation) = try await LiveConversationFixture.connected(gate)
    defer { connection.closeConversation(liveSessionID) }

    conversation.composer.text = "Ship it"
    conversation.composer.queueDraft()
    #expect(conversation.displayRows.isEmpty)
    let id = try #require(conversation.composer.queue.items.first?.id)
    let sending = Task { await conversation.composer.sendQueuedNow(id) }
    try await LiveConversationFixture.waitUntil("the POST") { gate.isWaiting }
    #expect(conversation.displayRows.map(\.text) == ["Ship it"])
    gate.release(.json(#"{"detail":"no"}"#, status: 400))
    await sending.value
    #expect(conversation.displayRows.isEmpty)
  }

  @Test("a new session opens with its first message showing, sent or being sent")
  func firstMessageShowsInTheNewSession() async throws {
    let gate = EventsGate()
    let (connection, conversation) = try await LiveConversationFixture.connected(gate)
    defer { connection.closeConversation(liveSessionID) }
    let creation = try #require(connection.creation())

    let creating = Task {
      await creation.createThenSend(firstMessage: "Ship it") { _ in (liveSessionID, nil) }
    }
    try await LiveConversationFixture.waitUntil("the POST") { gate.isWaiting }
    #expect(creation.phase == .created(sessionID: liveSessionID, firstMessageError: nil))
    #expect(conversation.displayRows.map(\.text) == ["Ship it"])

    gate.setItems(Self.echo)
    gate.release(.json(#"{"queued":true,"item_id":"item_1"}"#))
    await creating.value
    try await LiveConversationFixture.waitUntil("the echo") { conversation.rows.count == 1 }
    #expect(conversation.displayRows.map(\.id) == ["item_1"])
  }

  @Test("a first message that failed leaves no row behind")
  func failedFirstMessageLeavesNoRow() async throws {
    let gate = EventsGate()
    let (connection, conversation) = try await LiveConversationFixture.connected(gate)
    defer { connection.closeConversation(liveSessionID) }
    let creation = try #require(connection.creation())

    let creating = Task {
      await creation.createThenSend(firstMessage: "Ship it") { _ in (liveSessionID, nil) }
    }
    try await LiveConversationFixture.waitUntil("the POST") { gate.isWaiting }
    gate.release(.json(#"{"detail":"no"}"#, status: 400))
    await creating.value
    #expect(conversation.displayRows.isEmpty)
    guard case .created(_, .some) = creation.phase else {
      Issue.record("expected a first-message failure, got \(creation.phase)")
      return
    }
  }
}
