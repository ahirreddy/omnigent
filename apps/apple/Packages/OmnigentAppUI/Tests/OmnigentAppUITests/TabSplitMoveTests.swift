import Foundation
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@Suite("Tab split view: moving a tab to the other pane")
struct TabSplitMoveTests {
  /// A chat and another session's side chat on the left, a browser page alone on the right,
  /// the left pane focused on the chat.
  private struct PageOnTheRight {
    let store = TabStore()
    let chat: AppTab
    let page: AppTab
    let side: AppTab

    init() {
      chat = store.open(.chat(sessionID: "s1"), placement: .end)
      page = store.open(.browser(browserID: UUID()), placement: .end)
      side = store.open(.sideChat(sessionID: "s2", rowID: "r"), placement: .end)
      store.select(chat.id)
      store.show(page.id, in: .trailing)
      store.focus(.leading)
    }
  }

  @Test("A pane's only tab trades places with the tab the other pane shows; the split stays")
  func tradesPlaces() throws {
    let tabs = PageOnTheRight()
    let store = tabs.store
    let chat = tabs.chat
    let page = tabs.page
    // The page is alone on the right: moved left, the chat it replaces goes right.
    store.show(page.id, in: .leading)
    var state = try #require(store.splitState)
    #expect(state.leadingID == page.id)
    #expect(state.trailingID == chat.id)
    #expect(state.focused == .leading)
    #expect(store.selectedID == page.id)
    #expect(store.pane(of: tabs.side.id) == .leading, "the left pane's other tab stays there")
    #expect(store.tabs.map(\.id) == [tabs.side.id, page.id, chat.id])
    // And back the same way, from the pane without focus.
    store.show(chat.id, in: .leading)
    state = try #require(store.splitState)
    #expect(state.leadingID == chat.id)
    #expect(state.trailingID == page.id)
    #expect(store.selectedID == chat.id)
    #expect(store.materialized.isSuperset(of: [chat.id, page.id]))
  }

  @Test("Two tabs side by side swap sides either way")
  func swapsTwoTabs() {
    let store = TabStore()
    let chat = store.open(.chat(sessionID: "s1"), placement: .end)
    let shell = store.open(.terminal(sessionID: "s1", terminalID: "t1"), placement: .end)
    store.select(chat.id)
    store.toggleSplit()
    #expect(store.splitState?.leadingID == chat.id)
    #expect(store.splitState?.trailingID == shell.id)
    store.show(chat.id, in: .trailing)
    #expect(store.splitState?.leadingID == shell.id)
    #expect(store.splitState?.trailingID == chat.id)
    #expect(store.splitState?.focused == .trailing)
    store.show(chat.id, in: .leading)
    #expect(store.splitState?.leadingID == chat.id)
    #expect(store.splitState?.trailingID == shell.id)
    #expect(store.splitState?.focused == .leading)
  }

  @Test("The tab a pane shows moves to the other pane; the pane it left shows its neighbour")
  func movesShownTab() throws {
    let tabs = PageOnTheRight()
    let store = tabs.store
    store.show(tabs.chat.id, in: .trailing)
    let state = try #require(store.splitState)
    #expect(state.leadingID == tabs.side.id)
    #expect(state.trailingID == tabs.chat.id)
    #expect(state.focused == .trailing)
    #expect(store.pane(of: tabs.page.id) == .trailing, "the right pane keeps its other tab")
  }
}
