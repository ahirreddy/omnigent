import Foundation
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@Suite("Tab migration")
struct TabMigrationTests {
  private func tab(_ id: String, _ content: AppTabContent, pinned: Bool = false) -> AppTab {
    AppTab(id: id, content: content, isPinned: pinned)
  }

  @Test("A window's tabs split by session; browser tabs follow the session they opened from")
  func groupsBySession() {
    let snapshot = TabWindowSnapshot(
      tabs: [
        tab("early", .browser(browserID: UUID())),
        tab("a", .chat(sessionID: "a")),
        tab("a-shell", .terminal(sessionID: "a", terminalID: "t")),
        tab("a-page", .browser(browserID: UUID())),
        tab("blank", .newTab),
        tab("inbox", .inbox),
        tab("b", .chat(sessionID: "b")),
        tab("b-side", .sideChat(sessionID: "b", rowID: "r")),
      ],
      selectedID: "b-side",
      closed: [
        tab("gone", .terminal(sessionID: "a", terminalID: "x")),
        tab("gone-page", .browser(browserID: UUID())),
      ])
    let grouped = TabMigration.group(snapshot)
    #expect(grouped.page == .chat(sessionID: "b"))
    #expect(grouped.groups["a"]?.tabs.map(\.id) == ["early", "a", "a-shell", "a-page"])
    #expect(grouped.groups["b"]?.tabs.map(\.id) == ["b", "b-side"])
    #expect(grouped.groups["b"]?.selectedID == "b-side")
    #expect(grouped.groups["a"]?.selectedID == nil, "a falls back to its chat")
    #expect(grouped.groups["a"]?.closed.map(\.id) == ["gone"])
    #expect(grouped.groups["b"]?.closed.map(\.id) == ["gone-page"], "a closed page joins b")
  }

  @Test("A session-less page stays the window's page; a split survives only within a session")
  func pageAndSplit() {
    let snapshot = TabWindowSnapshot(
      tabs: [
        tab("a", .chat(sessionID: "a")),
        tab("a-shell", .terminal(sessionID: "a", terminalID: "t")),
        tab("b", .chat(sessionID: "b")),
        tab("canvas", .canvas),
      ],
      selectedID: "canvas",
      split: TabSplitSnapshot(
        trailingIDs: ["a-shell", "b"], focused: .trailing, otherSelectedID: "a",
        fraction: 0.4))
    let grouped = TabMigration.group(snapshot)
    #expect(grouped.page == .canvas)
    #expect(grouped.groups["a"]?.split?.trailingIDs == ["a-shell"])
    #expect(grouped.groups["a"]?.split?.fraction == 0.4)
    #expect(grouped.groups["b"]?.split == nil, "b's only tab can't fill two panes")
  }

  @Test("A session in several windows keeps the newest window's tabs")
  func newestWindowWins() {
    let old = LegacyWindowRecord(
      window: UUID(), launch: UUID(), savedAt: Date(timeIntervalSince1970: 100),
      snapshot: TabWindowSnapshot(tabs: [
        tab("old-chat", .chat(sessionID: "s")),
        tab("old-shell", .terminal(sessionID: "s", terminalID: "old")),
      ]))
    let new = LegacyWindowRecord(
      window: UUID(), launch: UUID(), savedAt: Date(timeIntervalSince1970: 200),
      snapshot: TabWindowSnapshot(tabs: [
        tab("new-chat", .chat(sessionID: "s")),
        tab("new-shell", .terminal(sessionID: "s", terminalID: "new")),
      ]))
    let migrated = TabMigration.migrate([old, new])
    #expect(migrated.windows.count == 2)
    #expect(migrated.sessions["s"]?.snapshot.tabs.map(\.id) == ["new-chat", "new-shell"])
    #expect(migrated.sessions["s"]?.savedAt == new.savedAt)
  }
}
