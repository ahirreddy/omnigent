import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentStores

/// The phone reading posture keeps drafts per session: leaving a session closes its stream, and
/// coming back restores what the user had typed.
@MainActor
struct DraftPersistenceTests {
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

  @Test(.timeLimit(.minutes(1))) func draftsSurviveClosingAndReopeningASession() async throws {
    let store = try await PreviewData.connectedDemoStore()
    let list = store.sessionList
    try await waitUntil("the sample list") { list.sessionsByID.count >= 2 }
    let ids = list.sessionsByID.keys.sorted()
    let first = try #require(store.conversation(ids[0]))
    try await waitUntil("the first session") { first.isHydrated }
    first.composer.text = "Draft for the first session"
    let second = try #require(store.conversation(ids[1]))
    try await waitUntil("the second session") { second.isHydrated }
    second.composer.text = "Another draft"

    store.closeConversation(ids[0])
    #expect(store.conversations[ids[0]] == nil)
    let reopened = try #require(store.conversation(ids[0]))
    try await waitUntil("the restored draft") {
      reopened.composer.text == "Draft for the first session"
    }
    #expect(reopened.composer.text == "Draft for the first session")
    #expect(second.composer.text == "Another draft")
    // The sidebar's draft marker follows whether each composer holds text.
    #expect(list.draftSessionIDs == [ids[0], ids[1]])
    second.composer.text = "  "
    #expect(list.draftSessionIDs == [ids[0]])
    store.closeConversation(ids[0])
    store.closeConversation(ids[1])
  }

  @Test(.timeLimit(.minutes(1))) func quoteBlocksSurviveReopeningAndRelaunching() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "drafts.json")
    let expected = [ReplyQuote(before: "Look here:", text: "quoted line\nsecond line")]

    let store = try await PreviewData.connectedDemoStore()
    store.draftArchive = ComposerDraftArchive(fileURL: file)
    try await waitUntil("the sample list") { !store.sessionList.sessionsByID.isEmpty }
    let sessionID = try #require(store.sessionList.sessionsByID.keys.min())
    let first = try #require(store.conversation(sessionID))
    try await waitUntil("the session") { first.isHydrated }
    first.composer.text = "Look here:"
    first.composer.quote("quoted line\nsecond line")
    first.composer.text = "and reply"
    first.composer.addMention("src/main.swift")
    #expect(first.composer.quotes == expected)

    // Reopened in the same launch: the core holds the flattened text, the archive the blocks.
    store.closeConversation(sessionID)
    let reopened = try #require(store.conversation(sessionID))
    try await waitUntil("the reopened session") { reopened.isHydrated }
    #expect(reopened.composer.quotes == expected)
    #expect(reopened.composer.text == "and reply")
    store.draftArchive?.flush()
    store.closeConversation(sessionID)

    // A new core and archive read from the same file, as after a relaunch.
    let relaunched = try await PreviewData.connectedDemoStore()
    relaunched.draftArchive = ComposerDraftArchive(fileURL: file)
    #expect(relaunched.draftArchive?.lastError == nil)
    let restored = try #require(relaunched.conversation(sessionID))
    try await waitUntil("the relaunched session") { restored.isHydrated }
    #expect(restored.composer.quotes == expected)
    #expect(restored.composer.text == "and reply")
    #expect(restored.composer.mentions == ["src/main.swift"])
    #expect(restored.composer.draftMessage == first.composer.draftMessage)
    #expect(relaunched.sessionList.draftSessionIDs.contains(sessionID))
    relaunched.closeConversation(sessionID)
  }
}

/// The archive file keeps structured drafts and still reads the plain text earlier versions wrote.
@MainActor
struct SavedDraftArchiveTests {
  @Test func structuredDraftsRoundTripAndPlainTextStillReads() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "drafts.json")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"server|alice":{"conv_old":"plain text"}}"#.utf8).write(to: file)

    let archive = ComposerDraftArchive(fileURL: file)
    #expect(archive.lastError == nil)
    #expect(
      archive.draft(account: "server|alice", session: "conv_old") == SavedDraft(text: "plain text"))
    let draft = SavedDraft(
      text: "reply", quotes: [.init(before: "", text: "a quote")], mentions: ["docs/"])
    archive.record(draft, account: "server|alice", session: "conv_new")
    // A draft holding only a quote or a path is kept; an empty one is forgotten.
    let quoteOnly = SavedDraft(text: " ", quotes: [.init(before: "", text: "q")])
    archive.record(quoteOnly, account: "server|alice", session: "conv_quote")
    archive.record(SavedDraft(text: "  "), account: "server|alice", session: "conv_old")
    archive.flush()
    #expect(archive.lastError == nil)

    let reopened = ComposerDraftArchive(fileURL: file)
    #expect(reopened.draft(account: "server|alice", session: "conv_new") == draft)
    #expect(reopened.draft(account: "server|alice", session: "conv_quote") == quoteOnly)
    #expect(reopened.sessions(account: "server|alice") == ["conv_new", "conv_quote"])
    #expect(draft.message == "> a quote\n\nreply")
  }
}
