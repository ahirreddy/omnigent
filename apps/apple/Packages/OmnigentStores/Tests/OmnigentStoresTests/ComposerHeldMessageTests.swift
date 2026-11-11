import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// What happens to a message the server refused because its host is offline.
@MainActor
@Suite("Messages held for an offline host", .timeLimit(.minutes(1)))
struct ComposerHeldMessageTests {
  private let eventsPath = "/v1/sessions/conv_a/events"

  private func facts(hostOnline: Bool) -> ConversationFacts {
    ConversationFacts(
      tokensUsed: nil, contextWindow: nil, items: 0, mcpServers: [], agentLoaded: false,
      isRunning: false, hostOnline: hostOnline)
  }

  @Test("A host that reads online gets the message again when the timer ends, with no event")
  func retriedAfterTheDelay() async throws {
    let live = try await LiveComposer()
    let composer = live.composer
    let online = facts(hostOnline: true)
    composer.conversationFacts = { online }
    composer.hostRecheckDelay = .milliseconds(20)
    live.hostIsOffline()
    composer.text = "hello"

    await composer.send()
    #expect(composer.queue.items.map(\.state) == [.waitingForHost])

    live.acceptMessages()
    try await eventually("the retry") { composer.queue.items.isEmpty }
    #expect(composer.hostRecheck == nil)
    #expect(live.postedTexts.last == "hello")
  }

  @Test("A host that reads offline starts no timer: its coming back is what retries")
  func noTimerWhileOffline() async throws {
    let live = try await LiveComposer()
    let composer = live.composer
    let offline = facts(hostOnline: false)
    composer.conversationFacts = { offline }
    live.hostIsOffline()
    composer.text = "hello"

    await composer.send()

    #expect(composer.queue.items.map(\.state) == [.waitingForHost])
    #expect(composer.hostRecheck == nil)
  }

  @Test("A file added while the send was out stays in the draft; the message is held without it")
  func fileAddedDuringTheSend() async throws {
    let live = try await LiveComposer()
    let composer = live.composer
    live.hostIsOffline()
    let gate = live.server.hold(eventsPath, method: "POST")
    composer.text = "hello"

    let sending = Task { await composer.send() }
    try await eventually("the post") { gate.arrivals == 1 }
    composer.addAttachment(filename: "a.txt", mediaType: "text/plain", data: Data("hi".utf8))
    gate.release()
    _ = await sending.value

    #expect(composer.lastError == nil, "a held message is not a failure")
    #expect(composer.queue.items.map(\.text) == ["hello"])
    #expect(composer.queue.items.first?.extras.isEmpty == true)
    #expect(composer.text.isEmpty)
    #expect(composer.attachments.items.count == 1)
  }

  @Test("A held message keeps the path it was sent with, whatever the draft tags meanwhile")
  func pathsAreHeldWithTheMessage() async throws {
    let live = try await LiveComposer()
    let composer = live.composer
    live.hostIsOffline()
    let gate = live.server.hold(eventsPath, method: "POST")
    composer.addMention("src/")

    let sending = Task { await composer.send() }
    try await eventually("the post") { gate.arrivals == 1 }
    #expect(composer.mentions.isEmpty, "the path left with the message")
    composer.addMention("docs/")
    gate.release()
    _ = await sending.value

    #expect(composer.queue.items.map(\.extras.mentions) == [["src/"]])
    #expect(composer.queue.items.first?.state == .waitingForHost)
    #expect(composer.mentions == ["docs/"])
    #expect(composer.lastError == nil)
  }
}
