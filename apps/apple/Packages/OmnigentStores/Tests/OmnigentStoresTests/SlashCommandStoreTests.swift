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

  @Test(.timeLimit(.minutes(1))) func contextAndMcpAnswerLocally() async throws {
    let (composer, close) = try await composer()
    defer { close() }
    let names = composer.slashCommands.map(\.name)
    #expect(names.contains("context"))
    #expect(names.contains("mcp"))
    composer.text = "/context"
    #expect(await composer.send() == .handled)
    #expect(composer.commandNotice?.contains("Items in context:") == true)
    #expect(composer.text == "/context")
    composer.text = "/mcp"
    #expect(await composer.send() == .handled)
    #expect(composer.commandNotice?.contains("MCP servers") == true)
    composer.text = "/mcp all"
    #expect(await composer.send() == .handled)
    #expect(composer.commandNotice == "Usage: /mcp")
  }

  @Test(.timeLimit(.minutes(1))) func mentionsGoAheadOfQueuedTextAndUpPullsItBack() async throws {
    let (composer, close) = try await composer()
    defer { close() }
    composer.addMention("src/a.swift")
    composer.addMention("src/a.swift")
    composer.addMention("docs/")
    #expect(composer.mentions == ["src/a.swift", "docs/"])
    composer.removeMention("docs/")
    composer.text = "look at this"
    composer.queueDraft()
    #expect(composer.mentions.isEmpty)
    let queued = try #require(composer.queue.items.last)
    #expect(queued.text == "look at this")
    #expect(queued.extras.mentions == ["src/a.swift"])
    #expect(composer.takeLastQueued() == "look at this")
    #expect(composer.mentions == ["src/a.swift"], "Up brings the paths back too")
    #expect(composer.queue.isEmpty)
    #expect(composer.takeLastQueued() == nil)
  }

  @Test(.timeLimit(.minutes(1))) func repliesQuoteAsBlocksAndQueueAsMarkdown() async throws {
    let (composer, close) = try await composer()
    defer { close() }
    composer.text = "About this:"
    composer.quote("line one\nline two")
    #expect(composer.quotes == [ReplyQuote(before: "About this:", text: "line one\nline two")])
    #expect(composer.text.isEmpty)
    composer.text = "Why?"
    #expect(composer.draftMessage == "About this:\n\n> line one\n> line two\n\nWhy?")
    composer.queueDraft()
    #expect(composer.queue.items.last?.text == "About this:\n\n> line one\n> line two\n\nWhy?")
    #expect(composer.quotes.isEmpty && composer.text.isEmpty)
    composer.quote("again")
    composer.removeQuote(at: 0)
    #expect(composer.quotes.isEmpty)
  }

  @Test(.timeLimit(.minutes(1))) func sideIsLeftToTheCallerWithItsQuestion() async throws {
    let (composer, close) = try await composer()
    defer { close() }
    try #require(composer.slashCommands.contains { $0.name == "side" })
    composer.text = "/side why is CI red?"
    // Codex forks its own side chat from the typed command.
    guard composer.configuration?.harness != "codex-native" else {
      #expect(composer.slashAction() == .sendText)
      return
    }
    #expect(await composer.send() == .sideChat(question: "why is CI red?"))
    #expect(composer.text == "/side why is CI red?", "kept until the side chat exists")
  }
}

/// Drafts kept in a file across launches, per account and session.
@MainActor
struct ComposerDraftArchiveTests {
  @Test func draftsSurviveReopeningAndBlankTextForgetsThem() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "drafts.json")
    let archive = ComposerDraftArchive(fileURL: file)
    archive.record(SavedDraft(text: "half a thought"), account: "server|alice", session: "conv_a")
    archive.record(SavedDraft(text: "other"), account: "server|bob", session: "conv_b")
    archive.record(SavedDraft(text: "   "), account: "server|bob", session: "conv_b")
    archive.flush()
    #expect(archive.lastError == nil)
    let reopened = ComposerDraftArchive(fileURL: file)
    #expect(reopened.draft(account: "server|alice", session: "conv_a")?.text == "half a thought")
    #expect(reopened.sessions(account: "server|alice") == ["conv_a"])
    #expect(reopened.sessions(account: "server|bob").isEmpty)
  }

  @Test func anUnreadableFileIsReported() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("not json".utf8).write(to: file)
    let archive = ComposerDraftArchive(fileURL: file)
    #expect(archive.lastError?.contains("could not be read") == true)
    #expect(archive.sessions(account: "a").isEmpty)
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
