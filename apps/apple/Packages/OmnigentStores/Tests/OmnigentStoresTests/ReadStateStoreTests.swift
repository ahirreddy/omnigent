import OmnigentCoreFFI
import Testing

@testable import OmnigentStores

@MainActor
private func waitUntil(
  _ description: String, timeout: Duration = .seconds(10), _ condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("timed out waiting for \(description)")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

/// Read state and declared terminals through the core's offline demo server, which keeps the
/// viewer's read state like the server does.
@MainActor
struct ReadStateStoreTests {
  @Test(.timeLimit(.minutes(1))) func newActivityIsUnreadUntilOpenedThroughTheDemoCore()
    async throws
  {
    let store = try await PreviewData.connectedDemoStore()
    let list = store.sessionList
    try await waitUntil("the sample list") { list.isLoaded && list.sessionsByID.count == 3 }
    // First sight reads as read.
    #expect(list.unreadIDs.isEmpty)

    let conversation = try #require(store.conversation("demo-question"))
    store.setView(sessionID: "demo-question", focused: true)
    try await waitUntil("the pending decision") { !conversation.decisions.pending.isEmpty }
    let card = try #require(conversation.decisions.pending.first)
    await conversation.decisions.resolve(card, with: .answer(value: "Sessions and chat"))
    try await waitUntil("the session to accept messages") {
      list.attention(of: "demo-question").state != .needsYou && conversation.isHydrated
    }
    conversation.composer.text = "Keep going"
    await conversation.composer.send()
    let sendError = conversation.composer.lastError
    #expect(sendError == nil, "\(String(describing: sendError))")

    // The user moves on; the reply finishes in the background.
    store.setView(sessionID: "demo-design", focused: true)
    try await waitUntil("the finished reply to be unread", timeout: .seconds(30)) {
      list.unreadIDs == ["demo-question"]
    }
    #expect(list.attention(of: "demo-question").state == .unread)
    #expect(list.attentionTotals.unread == 1)

    // Opening it reads it.
    store.setView(sessionID: "demo-question", focused: true)
    try await waitUntil("the opened session to be read") { list.unreadIDs.isEmpty }
    #expect(list.attention(of: "demo-question").state == .idle)
    #expect(store.issues.isEmpty, "\(store.issues)")
  }

  @Test func theSampleAgentsDeclareNoTerminals() async throws {
    let store = try await PreviewData.connectedDemoStore()
    try await waitUntil("the sample list") { store.sessionList.isLoaded }
    let terminals = try #require(store.terminals("demo-design"))
    #expect(!terminals.knowsDeclaredTerminalNames)
    await terminals.loadDeclaredTerminalNames()
    #expect(terminals.knowsDeclaredTerminalNames)
    #expect(terminals.declaredTerminalNames.isEmpty)
    #expect(terminals.lastError == nil)
  }
}
