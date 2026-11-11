import Foundation
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@Suite("Tabs kept built while hidden")
struct TabKeepAliveTests {
  @Test("The selected tab and the most recently shown chats stay built, in strip order")
  func recentChats() {
    let store = TabStore()
    let first = store.open(.chat(sessionID: "s1"))
    let second = store.open(.chat(sessionID: "s2"))
    let third = store.open(.chat(sessionID: "s3"), placement: .end)
    let fourth = store.open(.chat(sessionID: "s4"), placement: .end)
    store.select(second.id)
    #expect(store.recentIDs.prefix(4) == [second.id, fourth.id, third.id, first.id])
    #expect(store.keptAlive(limit: 3).map(\.id) == [second.id, third.id, fourth.id])
    #expect(store.keptAlive(limit: 1).map(\.id) == [second.id])
    #expect(store.keptAlive().count == 4, "all four are within the limit")
  }

  @Test("Every session kept open has a place for its chat to stay built")
  func limitsAgree() {
    #expect(TabStore.keptAliveLimit >= SessionTabGroups.liveLimit)
    let store = TabStore()
    let chats = (0..<TabStore.keptAliveLimit + 2).map {
      store.open(.chat(sessionID: "s\($0)"), placement: .end).id
    }
    #expect(store.keptAlive().map(\.id) == Array(chats.suffix(TabStore.keptAliveLimit)))
  }

  @Test("Terminals, pages and other tabs are rebuilt; a closed chat is not kept")
  func onlyConversations() {
    let store = TabStore()
    let chat = store.open(.chat(sessionID: "s1"))
    let side = store.open(.sideChat(sessionID: "s1", rowID: "r1"))
    let shell = store.open(.terminal(sessionID: "s1", terminalID: "t1"))
    let blank = store.open(.newTab)
    #expect(store.keptAlive().map(\.id) == [chat.id, side.id, blank.id])
    store.select(shell.id)
    #expect(store.keptAlive().map(\.id) == [chat.id, side.id, shell.id])
    store.requestClose(side.id)
    #expect(store.keptAlive().map(\.id) == [chat.id, shell.id])
  }

  @Test("A selected terminal takes no chat's place, so the way back builds no chat again")
  func otherKindsTakeNoPlace() {
    let store = TabStore()
    let chats = ["s1", "s2", "s3"].map { store.open(.chat(sessionID: $0), placement: .end).id }
    let shell = store.open(.terminal(sessionID: "s1", terminalID: "t1"), placement: .end)
    #expect(store.keptAlive().map(\.id) == chats + [shell.id])
    #expect(store.keptAlive(limit: 1).map(\.id) == [chats[2], shell.id])
    #expect(store.keptAlive(limit: 0).map(\.id) == [shell.id])
    store.select(chats[2])
    #expect(store.keptAlive().map(\.id) == chats, "the same chats as behind the terminal")
    #expect(store.keptAlive(limit: 0).map(\.id) == [chats[2]], "the selected tab always stays")
  }

  @Test("A split keeps both panes' chats built, with the recent chats behind them")
  func split() {
    let store = TabStore()
    let behind = store.open(.chat(sessionID: "s0"))
    let left = store.open(.chat(sessionID: "s1"), placement: .end)
    let right = store.open(.chat(sessionID: "s2"), placement: .end)
    #expect(store.shownTabs.map(\.id) == [right.id])
    store.select(left.id)
    store.show(right.id, in: .trailing)
    #expect(store.split != nil)
    #expect(store.shownTabs.map(\.id) == [right.id, left.id], "the focused pane's tab first")
    #expect(store.keptAlive().map(\.id) == [behind.id, left.id, right.id])
    #expect(store.keptAlive(limit: 2).map(\.id) == [left.id, right.id])
    #expect(
      store.keptAlive(limit: 1).map(\.id) == [left.id, right.id], "what shows always stays")
    store.focus(.leading)
    #expect(store.shownTabs.map(\.id) == [left.id, right.id])
    #expect(store.keptAlive(limit: 2).map(\.id) == [left.id, right.id])
    store.closeSplit()
    #expect(store.shownTabs.map(\.id) == [left.id])
    #expect(store.keptAlive(limit: 2).map(\.id) == [left.id, right.id], "the pane that left")
  }

  @Test("A terminal in a split's other pane is built with it, and takes no chat's place")
  func splitWithTerminal() {
    let store = TabStore()
    let behind = store.open(.chat(sessionID: "s0"))
    let chat = store.open(.chat(sessionID: "s1"), placement: .end)
    let shell = store.open(.terminal(sessionID: "s1", terminalID: "t1"), placement: .end)
    store.select(chat.id)
    store.show(shell.id, in: .trailing)
    #expect(Set(store.shownTabs.map(\.id)) == [chat.id, shell.id])
    #expect(store.keptAlive(limit: 2).map(\.id) == [behind.id, chat.id, shell.id])
    store.focus(.leading)
    #expect(store.keptAlive(limit: 2).map(\.id) == [behind.id, chat.id, shell.id])
  }

  @Test("No tab selected: nothing shows and nothing is kept")
  func nothingSelected() {
    let store = TabStore()
    #expect(store.shownTabs.isEmpty)
    #expect(store.keptAlive().isEmpty)
  }

  @Test("A window's owner moves among as many sessions as stay open, and none closes")
  func rotation() {
    let groups = SessionTabGroups()
    let sessions = (0..<SessionTabGroups.liveLimit).map { "s\($0)" }
    for _ in 0..<2 {
      for id in sessions { groups.show(.session(id)) }
    }
    #expect(groups.liveSessionIDs == Set(sessions))
    #expect(Set(groups.keptAlive().map(\.content)) == Set(sessions.map { .chat(sessionID: $0) }))
    groups.show(.session("one more"))
    #expect(!groups.liveSessionIDs.contains(sessions[0]), "the least recently shown closes")
    #expect(!groups.keptAlive().contains { $0.content == .chat(sessionID: sessions[0]) })
  }

  @Test("A split session's panes both stay built: shown, behind another session, under a page")
  func splitStaysBuilt() throws {
    let groups = SessionTabGroups()
    groups.showChat("a")
    let groupA = try #require(groups.current)
    let chat = try #require(groupA.selected)
    let side = groupA.open(.sideChatSession(parentID: "a", childID: "side"), select: false)
    groupA.show(side.id, in: .trailing)
    #expect(groups.keptAlive().map(\.id) == [chat.id, side.id])
    #expect(groups.keptAlive(limit: 1).map(\.id) == [chat.id, side.id], "what shows stays")
    // Both panes count as shown as recently as each other, whichever has the focus.
    groups.show(.session("b"))
    let behind = groups.keptAlive(limit: 3).map(\.content)
    #expect(
      behind == [chat.content, side.content, .chat(sessionID: "b")],
      "the split's panes stay built behind b")
    groups.show(.session("c"))
    #expect(
      Set(groups.keptAlive(limit: 3).map(\.content))
        == [.chat(sessionID: "c"), .chat(sessionID: "b"), side.content],
      "then the focused pane's tab outlasts the other")
    // A session-less page over the split keeps both panes, hidden.
    groups.show(.session("a"))
    groups.show(.inbox)
    #expect(Set(groups.keptAlive(limit: 2).map(\.id)) == [chat.id, side.id])
    // A browser beside the chat is built with it and takes no chat's place.
    groups.show(.session("a"))
    let page = try #require(groups.open(.browser(browserID: UUID()), select: false))
    groupA.show(page.id, in: .trailing)
    #expect(Set(groups.keptAlive(limit: 1).map(\.id)) == [page.id, chat.id])
  }

  @Test("A session that closed comes back with what it shows: its other chats wait their turn")
  func reopenedBuildsWhatShows() throws {
    let groups = SessionTabGroups()
    groups.liveLimit = 2
    groups.showChat("a")
    let groupA = try #require(groups.current)
    let chat = try #require(groupA.selected)
    let side = groupA.open(.sideChatSession(parentID: "a", childID: "side"))
    groupA.select(chat.id)
    groups.show(.session("b"))
    #expect(
      groups.keptAlive().map(\.content) == [chat.content, side.content, .chat(sessionID: "b")],
      "a is still open, with both its chats built")
    groups.show(.session("c"))
    #expect(!groups.liveSessionIDs.contains("a"))
    groups.show(.session("a"))
    #expect(
      groups.keptAlive().map(\.content) == [chat.content, .chat(sessionID: "c")],
      "the side chat is not built behind the chat that opens again")
    groupA.select(side.id)
    groupA.select(chat.id)
    #expect(groups.keptAlive().map(\.id).contains(side.id), "once shown, it stays built")
  }
}
