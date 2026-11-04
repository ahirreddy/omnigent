import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentStores

/// The composer's local slash commands: `/help` shows the menu without sending, `/new` is left
/// to the caller, and the menu comes from the core's rules, cached with the configuration.
@MainActor
struct SlashCommandStoreTests {
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

  private func composer() async throws -> (ComposerStore, () -> Void) {
    let store = try await PreviewData.connectedDemoStore()
    try await waitUntil("the sample list") { !store.sessionList.sessionsByID.isEmpty }
    let id = try #require(store.sessionList.sessionsByID.keys.min())
    let conversation = try #require(store.conversation(id))
    try await waitUntil("the session") { conversation.isHydrated }
    await conversation.composer.loadConfiguration()
    try #require(conversation.composer.configuration != nil)
    return (conversation.composer, { store.closeConversation(id) })
  }

  @Test(.timeLimit(.minutes(1))) func helpShowsTheMenuAndKeepsTheDraft() async throws {
    let (composer, close) = try await composer()
    defer { close() }
    let names = composer.slashCommands.map(\.name)
    #expect(names.contains("help"))
    #expect(names.contains("new"))
    composer.text = "/help"
    let outcome = await composer.send()
    #expect(outcome == .handled)
    #expect(composer.commandNotice?.contains("/new") == true)
    #expect(composer.text == "/help")
    #expect(composer.lastError == nil)
    composer.dismissCommandNotice()
    #expect(composer.commandNotice == nil)
  }

  @Test(.timeLimit(.minutes(1))) func mentionsSearchTheTypedQueryAndShowFailures() async throws {
    let (composer, close) = try await composer()
    defer { close() }
    composer.searchMentions = { query in
      if query == "bad" { throw CoreError.InvalidState(message: "offline") }
      return ["src/\(query).swift"]
    }
    composer.text = "see @ma"
    try await waitUntil("results") { composer.mentionCandidates == ["src/ma.swift"] }
    composer.text = "see @bad"
    try await waitUntil("the failure") { composer.mentionProblem != nil }
    #expect(composer.mentionCandidates.isEmpty)
    #expect(composer.mentionProblem?.contains("offline") == true)
    composer.text = "see "
    #expect(composer.mentionProblem == nil)
  }

  @Test(.timeLimit(.minutes(1))) func newIsLeftToTheCallerAndClearsTheDraft() async throws {
    let (composer, close) = try await composer()
    defer { close() }
    composer.text = "/new"
    #expect(await composer.send() == .newSession)
    #expect(composer.text.isEmpty)
    composer.text = "/new now"
    #expect(await composer.send() == .handled)
    #expect(composer.commandNotice == "/new does not accept arguments")
  }
}

@Suite("Mention queries")
struct MentionQueryTests {
  @Test("Only an @ at the start or after a space, with nothing typed past a space")
  func queries() {
    #expect(ComposerStore.mentionQuery(in: "@")?.isEmpty == true)
    #expect(ComposerStore.mentionQuery(in: "look at @src/Ma") == "src/Ma")
    #expect(ComposerStore.mentionQuery(in: "mail me@example") == nil)
    #expect(ComposerStore.mentionQuery(in: "@src/main.swift and") == nil)
    #expect(ComposerStore.mentionQuery(in: "no mention") == nil)
  }
}
