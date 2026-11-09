import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing
import UniformTypeIdentifiers

@testable import OmnigentAppUI

@MainActor
@Suite("Composer actions")
struct ComposerAdapterActionsTests {
  private func composer() async throws -> ComposerStore {
    try await ConversationFixtures.store().composer
  }

  /// The extras for a composer whose turn is running, so a queue change never drains.
  private func extras(_ composer: ComposerStore) -> ComposerExtraActions {
    ComposerAdapter.extras(composer, isRunning: { true }, reconnect: {}, prompts: { ["last"] })
  }

  private func message(id: String) -> QueuedMessage {
    QueuedMessage(id: id, text: "", state: .queued, files: [], mentions: [])
  }

  @Test("A queued message whose id names nothing changes nothing")
  func queueIdsThatNameNothing() async throws {
    let composer = try await composer()
    let extras = extras(composer)
    composer.text = "later"
    extras.queueDraft?()
    #expect(composer.queue.items.map(\.text) == ["later"])
    #expect(composer.text.isEmpty)

    for id in ["", "abc", "-1", "99999999", "99999999999999999999999", "1.5"] {
      extras.editQueued?(message(id: id), "edited")
      extras.removeQueued?(message(id: id))
      extras.sendQueuedNow?(message(id: id))
    }
    #expect(composer.queue.items.map(\.text) == ["later"])
  }

  @Test("A queued message can be edited and removed by its id")
  func queueEdits() async throws {
    let composer = try await composer()
    let extras = extras(composer)
    composer.text = "first"
    extras.queueDraft?()
    let item = try #require(composer.queue.items.first)
    extras.editQueued?(message(id: String(item.id)), "edited")
    #expect(composer.queue.items.map(\.text) == ["edited"])
    extras.removeQueued?(message(id: String(item.id)))
    #expect(composer.queue.items.isEmpty)
  }

  @Test("Moves outside the queue are ignored or clamped")
  func queueMoves() async throws {
    let composer = try await composer()
    let extras = extras(composer)
    for text in ["a", "b", "c"] {
      composer.text = text
      extras.queueDraft?()
    }
    extras.moveQueued?(IndexSet([99]), 0)
    #expect(composer.queue.items.map(\.text) == ["a", "b", "c"])
    extras.moveQueued?(IndexSet([0]), 1_000)
    #expect(composer.queue.items.map(\.text) == ["b", "c", "a"])
    extras.moveQueued?(IndexSet([2]), -1_000)
    #expect(composer.queue.items.map(\.text) == ["a", "b", "c"])
    extras.moveQueued?(IndexSet(), 1)
    #expect(composer.queue.items.map(\.text) == ["a", "b", "c"])
  }

  @Test("Quote actions at an index that doesn't exist do nothing")
  func quoteActions() async throws {
    let composer = try await composer()
    let extras = extras(composer)
    composer.text = "before"
    composer.quote("selected")
    extras.quotes.remove?(-1)
    extras.quotes.remove?(99)
    extras.quotes.editLead?(-1, "x")
    extras.quotes.editLead?(99, "x")
    #expect(composer.quotes.map(\.before) == ["before"])
    extras.quotes.editLead?(0, "lead")
    #expect(composer.quotes.map(\.before) == ["lead"])
    extras.quotes.remove?(0)
    #expect(composer.quotes.isEmpty)
    #expect(composer.text == "lead")
  }

  @Test("Mentions attach and detach by path; recall and history use the prompts given")
  func mentionsAndRecall() async throws {
    let composer = try await composer()
    let extras = extras(composer)
    extras.attachMention?("src/a.swift")
    #expect(composer.mentions == ["src/a.swift"])
    extras.removeMention?("not/attached.swift")
    #expect(composer.mentions == ["src/a.swift"])
    extras.removeMention?("src/a.swift")
    #expect(composer.mentions.isEmpty)
    #expect(extras.recallPrevious?() == "last")
    #expect(extras.history.prompts?() == ["last"])
    #expect(extras.history.takeLastQueued?() == nil)
  }

  @Test("A file that can't be read is reported by name and the rest still go in")
  func addingFiles() async throws {
    let composer = try await composer()
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      do {
        try FileManager.default.removeItem(at: directory)
      } catch {
        Issue.record(error)
      }
    }
    let readable = directory.appending(path: "notes.txt")
    try Data("hello".utf8).write(to: readable)
    let failures = await ComposerAdapter.add(
      [
        .file(url: directory.appending(path: "missing.txt")),
        .file(url: readable),
        .data(Data(), suggestedName: "", contentType: .png),
      ], to: composer)
    #expect(failures.count == 1)
    #expect(failures.first?.hasPrefix("Could not read missing.txt") == true)
    #expect(composer.attachments.items.contains { $0.filename == "notes.txt" })
  }
}
