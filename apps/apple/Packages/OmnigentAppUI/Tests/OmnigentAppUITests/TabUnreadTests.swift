import Foundation
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@Suite("Tab unread marks")
struct TabUnreadTests {
  @Test("A background tab whose work settles is unread until it is shown")
  func settlesWhileHidden() {
    let store = TabStore()
    let shell = store.open(.terminal(sessionID: "s1", terminalID: "t1"))
    let chat = store.open(.chat(sessionID: "s1"))
    store.noteBusy([shell.id])
    #expect(store.unread.isEmpty, "still busy")
    store.noteBusy([])
    #expect(store.unread == [shell.id])
    store.select(chat.id)
    #expect(store.unread == [shell.id], "selecting another tab keeps it")
    store.select(shell.id)
    #expect(store.unread.isEmpty, "showing it reads it")
  }

  @Test("Work that settles in view, or in the other pane, is already read")
  func settlesInView() {
    let store = TabStore()
    let left = store.open(.chat(sessionID: "s1"))
    let right = store.open(.chat(sessionID: "s2"))
    store.noteBusy([left.id, right.id])
    store.noteBusy([])
    #expect(store.unread == [left.id], "only the hidden one")
    store.show(left.id, in: .leading)
    #expect(store.unread.isEmpty, "the split shows it")
    store.noteBusy([right.id])
    store.noteBusy([])
    #expect(store.unread.isEmpty, "the other pane's tab is on screen")
  }

  @Test("A closed tab drops its mark")
  func closedTab() {
    let store = TabStore()
    let shell = store.open(.terminal(sessionID: "s1", terminalID: "t1"))
    store.open(.newTab)
    store.noteBusy([shell.id])
    store.noteBusy([])
    store.close(shell.id)
    #expect(store.unread.isEmpty)
  }

  @Test("Unread shows only when nothing more urgent does")
  func statusPriority() {
    #expect(TabAdapter.status(.none, isUnread: true) == .unread)
    #expect(TabAdapter.status(.exited, isUnread: true) == .unread)
    #expect(TabAdapter.status(.needsYou, isUnread: true) == .needsYou)
    #expect(TabAdapter.status(.running, isUnread: true) == .running)
    #expect(TabAdapter.status(.none, isUnread: false) == .none)
  }

  @Test("Agent names read as display names, never raw ids")
  func agentNames() {
    #expect(TabAdapter.agentDisplayName("tabs_fixture_agent") == "Tabs fixture agent")
    #expect(TabAdapter.agentDisplayName("codex-native") == "Codex")
    #expect(TabAdapter.agentDisplayName("claude") == "Claude Code")
    #expect(TabAdapter.agentDisplayName("Release Bot") == "Release Bot")
    #expect(TabAdapter.agentDisplayName("  ").isEmpty)
  }
}
