import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

@MainActor
@Suite("A session the server no longer has", .serialized)
struct MissingSessionTests {
  private let notFound = CoreError.Link(
    kind: .notFound, message: "HTTP 404", requiresSignIn: false)

  @Test("a saved tab's stream answering 404 flags the session and shows no failure")
  func staleTab() async throws {
    let streams = FakeEventStreamTransport()
    let (connection, _) = try await LiveConversationFixture.connected(
      EventsGate(), streams: streams)
    defer { connection.closeConversation("gone") }
    let stale = try #require(connection.conversation("gone"))
    var opened = await streams.waitForOpen()
    while !opened.0.url.hasSuffix("/v1/sessions/gone/stream") {
      opened = await streams.waitForOpen()
    }
    opened.1.response(status: 404, headers: [])
    try await LiveConversationFixture.waitUntil("the 404") { stale.answeredNotFoundBeforeLoading }
    #expect(stale.errors.isEmpty)
    #expect(!stale.isClosed)
  }

  @Test("a session that loaded and then answers 404 waits for the core to give up")
  func loadedThen404() async throws {
    let (connection, conversation) = try await LiveConversationFixture.connected(EventsGate())
    defer { connection.closeConversation(liveSessionID) }
    conversation.linkChanged(.reconnecting(reason: notFound, failures: 1, delayMs: 1_000))
    #expect(!conversation.answeredNotFoundBeforeLoading)
    #expect(!conversation.isClosed)

    conversation.linkChanged(.failed(error: notFound))
    #expect(conversation.isClosed)
  }

  @Test("loading clears an earlier 404, as when a proxy's backend finished restarting")
  func loadingClearsIt() async throws {
    let (connection, conversation) = try await LiveConversationFixture.connected(EventsGate())
    defer { connection.closeConversation(liveSessionID) }
    let stale = try #require(connection.conversation("later"))
    defer { connection.closeConversation("later") }
    stale.record(notFound)
    #expect(stale.answeredNotFoundBeforeLoading)
    stale.hydrated()
    #expect(!stale.answeredNotFoundBeforeLoading)
    #expect(conversation.errors.isEmpty)
  }

  @Test("other stream failures still count as errors, and don't close the session")
  func otherFailures() async throws {
    let (connection, conversation) = try await LiveConversationFixture.connected(EventsGate())
    defer { connection.closeConversation(liveSessionID) }
    let failure = CoreError.Link(kind: .httpStatus, message: "HTTP 500", requiresSignIn: false)
    conversation.linkChanged(.failed(error: failure))
    #expect(conversation.errors == [failure])
    #expect(!conversation.isClosed)
  }
}
