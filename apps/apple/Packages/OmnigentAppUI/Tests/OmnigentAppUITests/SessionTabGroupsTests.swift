import Foundation
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@Suite("Session tab groups")
@MainActor
struct SessionTabGroupsTests {
  @Test("Each session has its own tabs; switching swaps them and coming back restores the tab")
  func switching() throws {
    let groups = SessionTabGroups()
    groups.show(.session("a"))
    let groupA = try #require(groups.current)
    #expect(groupA.tabs.map(\.content) == [.chat(sessionID: "a")], "a session starts on its chat")
    let shell = try #require(groups.open(.terminal(sessionID: "a", terminalID: "t")))
    let side = try #require(groups.open(.sideChat(sessionID: "a", rowID: "r")))
    groups.current?.select(shell.id)

    groups.show(.session("b"))
    #expect(groups.current?.tabs.map(\.content) == [.chat(sessionID: "b")])
    #expect(groups.selected?.content == .chat(sessionID: "b"))

    groups.show(.session("a"))
    #expect(groups.current === groupA)
    #expect(groups.current?.tabs.map(\.id).contains(side.id) == true)
    #expect(groups.selected?.id == shell.id, "the terminal, not the chat, is still selected")
  }

  @Test("Session-less pages have no tabs; a session's tab opened elsewhere shows its session")
  func pages() throws {
    let groups = SessionTabGroups()
    groups.show(.inbox)
    #expect(groups.current == nil)
    #expect(groups.open(.usage) == nil)
    #expect(groups.page == .usage, "a page kind shows the page instead of a tab")
    #expect(groups.open(.newTab) == nil, "a new-tab page needs a session")
    let shell = try #require(groups.open(.terminal(sessionID: "a", terminalID: "t")))
    #expect(groups.page == .session("a"))
    #expect(groups.selected?.id == shell.id)
    let page = try #require(groups.open(.browser(browserID: UUID())))
    #expect(groups.tab(page.id)?.sessionID == "a", "a browser tab joins the shown session")
  }

  @Test("The session shown last keeps its tabs for the strip while a page covers it")
  func lastShown() throws {
    let groups = SessionTabGroups()
    #expect(groups.lastShown == nil)
    groups.show(.session("a"))
    let groupA = try #require(groups.current)
    #expect(groups.lastShown === groupA)
    groups.show(.usage)
    #expect(groups.current == nil)
    #expect(groups.lastShown === groupA, "going to a page changes nothing the strip reads")
    groups.show(.session("b"))
    #expect(groups.lastShown === groups.current)
    #expect(groups.lastShown !== groupA)
  }

  @Test("Links to a conversation show its chat, whichever tab was selected")
  func showChat() throws {
    let groups = SessionTabGroups()
    groups.open(.terminal(sessionID: "a", terminalID: "t"))
    groups.show(.inbox)
    groups.showChat("a")
    #expect(groups.page == .session("a"))
    #expect(groups.selected?.content == .chat(sessionID: "a"))
  }

  @Test("The primary chat can't close; ⌘1–9, cycling and Reopen stay within the session")
  func closingRules() throws {
    let groups = SessionTabGroups()
    groups.show(.session("a"))
    let groupA = try #require(groups.current)
    let chat = try #require(groupA.selected)
    let shell = groupA.open(.terminal(sessionID: "a", terminalID: "t"))
    let side = groupA.open(.sideChat(sessionID: "a", rowID: "r"))
    #expect(!groupA.canClose(chat.id))
    groupA.close(chat.id)
    #expect(groupA.tab(chat.id) != nil)
    groupA.close(side.id)

    groups.show(.session("b"))
    let groupB = try #require(groups.current)
    groupB.open(.browser(browserID: UUID()))
    #expect(groupB.closed.isEmpty, "b has nothing to reopen: a's closed tab stays with a")
    groupB.select(position: 0)
    #expect(groupB.selected?.content == .chat(sessionID: "b"))
    groupB.selectNext()
    groupB.selectNext()
    #expect(groupB.selected?.content == .chat(sessionID: "b"), "cycling wraps within b")

    groups.show(.session("a"))
    #expect(groupA.reopenClosed()?.id == side.id)
    groupA.select(position: 8)
    #expect(groupA.selected?.id == groupA.tabs.last?.id)
    #expect(groupA.tabs.map(\.id).contains(shell.id))
  }

  @Test("Split view holds two tabs of the same session and survives switching away")
  func split() throws {
    let groups = SessionTabGroups()
    groups.show(.session("a"))
    let groupA = try #require(groups.current)
    let chat = try #require(groupA.selected)
    let shell = groupA.open(.terminal(sessionID: "a", terminalID: "t"), select: false)
    groupA.show(shell.id, in: .trailing)
    #expect(groupA.splitState?.leadingID == chat.id)
    #expect(groupA.splitState?.trailingID == shell.id)
    groups.show(.session("b"))
    #expect(groups.current?.split == nil, "b is not split")
    groups.show(.session("a"))
    #expect(groups.current?.splitState?.trailingID == shell.id)
  }

  @Test("Archived sessions leave; the window shows the previous session")
  func removal() throws {
    let groups = SessionTabGroups()
    var removed: Set<String> = []
    groups.onRemove = { removed.formUnion($0) }
    groups.show(.session("a"))
    groups.show(.session("b"))
    groups.removeSessions(["b"])
    #expect(groups.groups["b"] == nil)
    #expect(groups.page == .session("a"))
    #expect(removed == ["b"])
    groups.removeSessions(["a"])
    #expect(groups.page == nil)
  }

  @Test("The few most recent sessions stay live; recent chats across them stay built")
  func keepAlive() throws {
    let groups = SessionTabGroups()
    #expect(groups.liveLimit == SessionTabGroups.liveLimit)
    groups.liveLimit = 3
    for id in ["a", "b", "c", "d"] { groups.show(.session(id)) }
    #expect(groups.liveSessionIDs == ["b", "c", "d"])
    let kept = groups.keptAlive().map(\.content)
    #expect(Set(kept) == [.chat(sessionID: "c"), .chat(sessionID: "d"), .chat(sessionID: "b")])
    // A terminal shown in d takes no chat's place: all three stay built behind it.
    let shell = try #require(groups.open(.terminal(sessionID: "d", terminalID: "t")))
    #expect(Set(groups.keptAlive().map(\.content)) == Set(kept + [shell.content]))
    #expect(
      Set(groups.keptAlive(limit: 1).map(\.content)) == [shell.content, .chat(sessionID: "d")])
    // Under a session-less page the chats stay built, all hidden.
    groups.show(.inbox)
    #expect(groups.keptAlive().contains { $0.content == .chat(sessionID: "d") })
  }

  @Test("Saved tabs are fitted to their session: its own tabs and pages, its chat first")
  func normalized() {
    let page = AppTab(content: .browser(browserID: UUID()), isPinned: true)
    let other = AppTab(content: .chat(sessionID: "other"))
    let inbox = AppTab(content: .inbox)
    let shell = AppTab(content: .terminal(sessionID: "s", terminalID: "t"))
    let snapshot = TabWindowSnapshot(
      tabs: [page, other, inbox, shell], selectedID: other.id,
      closed: [AppTab(content: .terminal(sessionID: "other", terminalID: "x"))])
    let fitted = SessionTabGroups.normalized(snapshot, for: "s")
    #expect(
      fitted.tabs.map(\.content) == [
        page.content, .chat(sessionID: "s"), shell.content,
      ])
    #expect(fitted.selectedID == fitted.tabs[1].id, "a selection that left falls back to the chat")
    #expect(fitted.closed.isEmpty)
    #expect(SessionTabGroups.isDefault(SessionTabGroups.normalized(TabWindowSnapshot(), for: "s")))
  }

  @Test("A chat's Chat or Terminal choice is kept per session, until the session leaves")
  func viewChoices() {
    let groups = SessionTabGroups()
    #expect(groups.viewMode("a") == .chat, "a chat starts in its chat view")
    #expect(groups.viewChoice("a").mode == nil, "nothing is chosen yet")
    let choice = groups.viewChoice("a")
    #expect(groups.viewChoice("a") === choice, "one choice per session")
    groups.setViewMode(.terminal, for: "a")
    groups.setViewMode(.terminal, for: "a")
    groups.setViewMode(.chat, for: "b")
    #expect(groups.viewMode("a") == .terminal)
    #expect(groups.viewChoice("b").mode == .chat)

    groups.removeSessions(["a"])
    #expect(groups.viewChoice("a").mode == nil, "an archived session's choice goes with it")
    #expect(groups.viewMode("b") == .chat)
    groups.setViewMode(.terminal, for: "b")
    groups.reset()
    #expect(groups.viewChoice("b").mode == nil, "another server starts over")
  }

  @Test("Tabs saved with the agent's terminal in a tab of its own show it in the chat instead")
  func savedHarnessTab() {
    let chat = AppTab(content: .chat(sessionID: "s"))
    let harness = AppTab(content: .harness(sessionID: "s"))
    let onHarness = TabWindowSnapshot(
      tabs: [chat, harness], selectedID: harness.id, closed: [harness])
    let onChat = TabWindowSnapshot(tabs: [chat, harness], selectedID: chat.id)
    #expect(SessionTabGroups.selectsHarness(onHarness))
    #expect(!SessionTabGroups.selectsHarness(onChat))
    #expect(!SessionTabGroups.selectsHarness(TabWindowSnapshot()))
    #expect(!SessionTabGroups.belongsInGroup(harness.content))

    let groups = SessionTabGroups()
    groups.loadSaved = { $0 == "s" ? onHarness : onChat }
    let group = groups.group("s")
    #expect(group.tabs.map(\.content) == [chat.content], "the terminal's own tab is gone")
    #expect(group.selected?.content == chat.content)
    #expect(group.closed.isEmpty, "and cannot be reopened")
    #expect(groups.viewMode("s") == .terminal, "the chat shows the terminal it was left on")

    #expect(groups.group("other").tabs.map(\.content) == [.chat(sessionID: "other")])
    #expect(groups.viewChoice("other").mode == nil, "left on the chat, it stays on the chat")
  }

  @Test("A page another window shows gets a page of its own, from the same saved state")
  func reassignsPagesInUse() throws {
    let shown = UUID()
    let free = UUID()
    let snapshot = TabWindowSnapshot(tabs: [
      AppTab(content: .browser(browserID: shown), browserState: Data("a".utf8)),
      AppTab(content: .browser(browserID: free)),
    ])
    let groups = SessionTabGroups()
    groups.loadSaved = { _ in snapshot }
    groups.pageInUse = { $0 == shown }
    let group = groups.group("s")
    let pages = group.tabs.compactMap(\.content.browserID)
    #expect(pages.count == 2)
    #expect(!pages.contains(shown))
    #expect(pages.contains(free))
    let moved = group.tabs.first { $0.content.browserID.map { $0 != free } ?? false }
    #expect(moved?.browserState == Data("a".utf8))
  }
}
