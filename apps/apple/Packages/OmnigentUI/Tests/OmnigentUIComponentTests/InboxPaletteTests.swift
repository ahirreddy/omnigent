import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Inbox triage and palette")
struct InboxPaletteTests {
  @Test("Reading does not resolve a request, and pinning alone does not keep an item, as the web")
  func filters() {
    let items = InboxTriageSamples.state.items
    let awaiting = InboxTriage.items(items, filter: .awaiting, search: "")
    #expect(awaiting.contains { $0.id == "in2" && !$0.isUnread && $0.isUnresolved })
    #expect(!awaiting.contains { $0.id == "in4" })
    let unread = InboxTriage.items(items, filter: .unread, search: "")
    #expect(!unread.contains { $0.id == "in2" })
    // Read and pinned: neither unread nor waiting.
    #expect(!unread.contains { $0.id == "in4" })
    #expect(InboxTriage.items(items, filter: .all, search: "Build Mac").map(\.id) == ["in5"])
  }

  @Test("The count pill describes approvals, comments and unread sessions")
  func countSummary() {
    let items = InboxTriageSamples.state.items
    #expect(InboxTriage.summary(items) == "3 approvals \u{00B7} 1 comment \u{00B7} 1 unread")
    #expect(InboxTriage.summary([]).isEmpty)
  }

  @Test("Items group newest first under the web's recency headers")
  func recencyGroups() throws {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = try #require(TimeZone(identifier: "UTC"))
    let groups = InboxTriage.groups(
      InboxTriageSamples.state.items, now: PreviewData.now, calendar: utc)
    #expect(groups.map(\.title) == ["Just now", "Earlier today", "Yesterday", "This week"])
    #expect(groups.flatMap(\.items).map(\.id) == ["in5", "in1", "in2", "in3", "in4"])
    let old = InboxItem(
      id: "old", kind: .unread, sessionId: "s", sessionTitle: "Old", preview: "",
      date: PreviewData.now.addingTimeInterval(-30 * 86_400))
    #expect(
      InboxTriage.groups([old], now: PreviewData.now, calendar: utc).map(\.title) == ["Older"])
  }

  @Test("Unread lists replies and comments, not pending requests")
  func unreadExcludesRequests() {
    var request = InboxTriageSamples.state.items[0]
    request.isUnread = true
    #expect(request.isUnresolved)
    #expect(InboxTriage.items([request], filter: .unread, search: "").isEmpty)
    var comment = InboxItem(
      id: "c1", kind: .comment, sessionId: "s", sessionTitle: "Docs", preview: "bob: Why?",
      date: PreviewData.now)
    comment.comment = InboxComment(author: "bob", path: "src/app.rs", body: "Why?")
    #expect(InboxTriage.items([comment], filter: .unread, search: "app.rs").map(\.id) == ["c1"])
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

  @Test("Automations and Usage follow Open Inbox only when the server offers them")
  func offeredPages() {
    var state = PaletteViewState(scope: "Mac Studio", sessions: [])
    let none = PaletteCatalog.entries(state: state, commands: SessionCommandActions())
    #expect(!none.contains { $0.target == .automations || $0.target == .usage })
    state.showsAutomations = true
    state.showsUsage = true
    let targets = PaletteCatalog.entries(state: state, commands: SessionCommandActions())
      .map(\.target)
    let inbox = targets.firstIndex(of: .inbox) ?? 0
    #expect(Array(targets[inbox...].prefix(3)) == [.inbox, .automations, .usage])
    state.showsAutomations = false
    #expect(
      !PaletteCatalog.entries(state: state, commands: SessionCommandActions())
        .contains { $0.target == .automations })
  }

  private func entry(_ id: String, _ title: String, detail: String = "") -> PaletteEntry {
    PaletteEntry(id: id, title: title, detail: detail, symbol: "tray", target: .inbox)
  }
}
