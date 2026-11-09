import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The drafts file: an unreadable or unwritable file costs drafts, so the user must hear about it.
@MainActor
@Suite("The drafts file", .timeLimit(.minutes(1)))
struct DraftArchiveFileTests {
  private let folder = FileManager.default.temporaryDirectory
    .appending(path: "draft-archive-\(UUID().uuidString)")

  private var fileURL: URL { folder.appending(path: "composer-drafts.json") }

  private func cleanUp() throws {
    if FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.removeItem(at: folder)
    }
  }

  @Test("Changes reach the file after the delay, and a relaunch reads them")
  func savesAfterTheDelay() async throws {
    defer { #expect(throws: Never.self) { try cleanUp() } }
    let archive = ComposerDraftArchive(fileURL: fileURL, saveDelay: .milliseconds(1))
    archive.record(SavedDraft(text: "hello"), account: "a", session: "s") { _ in }
    try await eventually("the file") { FileManager.default.fileExists(atPath: fileURL.path) }
    #expect(archive.lastError == nil)

    let relaunched = ComposerDraftArchive(fileURL: fileURL)
    #expect(relaunched.draft(account: "a", session: "s")?.text == "hello")
    #expect(relaunched.sessions(account: "a") == ["s"])
    #expect(relaunched.sessions(account: "b").isEmpty)
  }

  @Test("A file that can't be written reports the failure and keeps the draft in memory")
  func saveFailure() async throws {
    defer { #expect(throws: Never.self) { try cleanUp() } }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let blocker = folder.appending(path: "blocker")
    try Data().write(to: blocker)
    let archive = ComposerDraftArchive(
      fileURL: blocker.appending(path: "composer-drafts.json"), saveDelay: .milliseconds(1))
    var reported: [String] = []
    archive.record(SavedDraft(text: "hello"), account: "a", session: "s") { reported.append($0) }
    try await eventually("the failure") { archive.lastError != nil }
    #expect(reported.count == 1)
    #expect(reported.first?.contains("could not be saved") == true)
    #expect(archive.draft(account: "a", session: "s")?.text == "hello")
  }

  @Test("A damaged file is reported on connect, and the sidebar still marks what can be read")
  func damagedFileIsReported() async throws {
    defer { #expect(throws: Never.self) { try cleanUp() } }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: fileURL)
    let archive = ComposerDraftArchive(fileURL: fileURL)
    #expect(archive.lastError?.contains("could not be read") == true)

    let store = try disconnectedStore(RouteServer())
    store.draftArchive = archive
    await store.connect(serverURL: "http://127.0.0.1:6767")
    try await eventually("the connection") { store.isSignedIn }
    try await eventually("the report") {
      store.issues.contains { $0.error.message.contains("could not be read") }
    }
  }

  @Test("A session's draft comes back in an empty composer, and failing to save it is reported")
  func keepsDraftsForSessions() async throws {
    defer { #expect(throws: Never.self) { try cleanUp() } }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let blocker = folder.appending(path: "blocker")
    try Data().write(to: blocker)
    let archive = ComposerDraftArchive(
      fileURL: blocker.appending(path: "composer-drafts.json"), saveDelay: .milliseconds(1))
    let store = try await connectedStore(RouteServer())
    store.draftArchive = archive
    let conversation = try #require(store.conversation("conv_a"))
    store.dismissIssues()
    conversation.composer.text = "typing"
    try await eventually("the failure") { archive.lastError != nil }
    try await eventually("the session's failure") {
      store.issues.contains { $0.error.message.contains("could not be saved") }
    }
  }

  @Test("Text typed since is newer than the saved draft, so the file doesn't overwrite it")
  func newerTextWins() async throws {
    defer { #expect(throws: Never.self) { try cleanUp() } }
    let archive = ComposerDraftArchive(fileURL: fileURL, saveDelay: .seconds(60))
    let store = try await connectedStore(RouteServer())
    let account = try #require(store.connectedServer?.accountId)
    archive.record(SavedDraft(text: "saved"), account: account, session: "conv_a") { _ in }
    store.draftArchive = archive
    let conversation = try #require(store.conversation("conv_a"))
    #expect(conversation.composer.text == "saved")

    store.closeConversation("conv_a")
    let core = try #require(store.core)
    try core.updateComposer(sessionId: "conv_a", text: "typed since")
    let reopened = try #require(store.conversation("conv_a"))
    #expect(reopened.composer.text != "saved")
  }
}
