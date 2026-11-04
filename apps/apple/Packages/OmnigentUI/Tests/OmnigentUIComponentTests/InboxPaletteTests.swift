import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Inbox triage and palette")
struct InboxPaletteTests {
  @Test("Reading does not resolve a request, and pinned updates survive either filter")
  func filters() {
    let items = InboxTriageSamples.state.items
    let awaiting = InboxTriage.items(items, filter: .awaiting, search: "")
    #expect(awaiting.contains { $0.id == "in2" && !$0.isUnread && $0.isUnresolved })
    #expect(awaiting.contains { $0.id == "in4" && $0.isPinned })
    let unread = InboxTriage.items(items, filter: .unread, search: "")
    #expect(!unread.contains { $0.id == "in2" })
    #expect(unread.contains { $0.id == "in4" })
    #expect(InboxTriage.groups(items).map(\.title) == ["Pinned", "Needs you", "Unread"])
    #expect(InboxTriage.items(items, filter: .all, search: "Build Mac").map(\.id) == ["in5"])
  }

  @Test("Resolving advances to the next request without losing selection on refresh or failure")
  func selection() {
    let before = InboxTriage.items(InboxTriageSamples.state.items, filter: .all, search: "")
    #expect(InboxTriage.selection("in2", previous: before, current: before.reversed()) == "in2")
    var after = before
    let index = after.firstIndex { $0.id == "in2" }
    if let index {
      after[index].phase = .failed(message: "Offline")
      #expect(InboxTriage.selection("in2", previous: before, current: after) == "in2")
      after[index].phase = .answered(summary: "Answered")
    }
    #expect(InboxTriage.selection("in2", previous: before, current: after) == "in5")
    #expect(
      InboxTriage.selection("in2", previous: before, current: after.filter { $0.id != "in2" })
        == "in5")
    #expect(InboxTriage.selection("in2", previous: before, current: []) == nil)
    if let nextIndex = after.firstIndex(where: { $0.id == "in5" }) {
      after[nextIndex].isReadOnly = true
      #expect(InboxTriage.selection("in2", previous: before, current: after) == "in1")
    }
    var placeholder = before.first { $0.id == "in2" }
    placeholder?.id = "loading"
    placeholder?.decision = nil
    if let placeholder {
      #expect(InboxTriage.selection("loading", previous: [placeholder], current: before) == "in2")
    }
  }

  @Test("Movement clamps at list boundaries and binary approval respects phase and permissions")
  func movementAndApproval() throws {
    let items = InboxTriageSamples.state.items
    #expect(InboxTriage.move(nil, by: 1, in: items) == items.first?.id)
    #expect(InboxTriage.move(items.first?.id, by: -1, in: items) == items.first?.id)
    #expect(InboxTriage.move(items.last?.id, by: 1, in: items) == items.last?.id)
    #expect(InboxTriage.move(nil, by: 1, in: []) == nil)
    var item = try #require(items.first)
    #expect(item.canApprove)
    item.phase = .resolving
    #expect(!item.canApprove)
    item.phase = .failed(message: "Try again")
    item.decision?.answered = true
    #expect(item.canApprove)
    item.isReadOnly = true
    #expect(!item.canApprove)
    #expect(items.first { $0.id == "in2" }?.canApprove == false)
  }

  @Test("Fuzzy search ranks prefixes, matches context, folds accents and keeps ties stable")
  func fuzzySearch() {
    let entries = [
      entry("refresh", "Refresh authentication", detail: "Working · Codex"),
      entry("auth", "Auth refresh", detail: "Needs you · Claude Code"),
      entry("accent", "Résumé du déploiement", detail: "Build Mac"),
    ]
    #expect(PaletteSearch.results(entries, query: "auth").map(\.id) == ["auth", "refresh"])
    #expect(PaletteSearch.results(entries, query: "  aRf  ").map(\.id).contains("auth"))
    #expect(PaletteSearch.results(entries, query: "resume").map(\.id) == ["accent"])
    #expect(PaletteSearch.results(entries, query: "needs you").map(\.id) == ["auth"])
    #expect(PaletteSearch.results(entries, query: "zzzz").isEmpty)
    #expect(PaletteSearch.results(entries, query: "  ") == entries)
    #expect(
      PaletteSearch.results([entry("one", "Same"), entry("two", "Same")], query: "sm").map(\.id)
        == ["one", "two"])
    #expect(PaletteSearch.results([entry("one", "A")], query: "aa").isEmpty)
  }

  @Test("Palette offers eleven scoped commands and disables unavailable session actions")
  func commands() {
    let state = PaletteViewState(scope: "Mac Studio", sessions: [])
    let entries = PaletteCatalog.entries(state: state, commands: SessionCommandActions())
    #expect(entries.count == 11)
    #expect(
      entries.filter { !$0.isEnabled }.map(\.target) == [
        .nextRequest, .changes, .composer, .toggleTerminal, .toggleInspector,
      ])
    #expect(entries.suffix(3).map(\.target) == [.settings, .toggleSidebar, .toggleInspector])
    let available = PaletteCatalog.entries(
      state: state,
      commands: SessionCommandActions(focusComposer: {}, toggleViewMode: {}, openChanges: {}))
    #expect(available.first { $0.target == .changes }?.isEnabled == true)
    #expect(available.first { $0.target == .composer }?.shortcut == "⌃⇧L")
  }

  private func entry(_ id: String, _ title: String, detail: String = "") -> PaletteEntry {
    PaletteEntry(id: id, title: title, detail: detail, symbol: "tray", target: .inbox)
  }
}
