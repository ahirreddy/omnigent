import Foundation
import Testing

@testable import OmnigentAppUI

@Suite("Window tabs")
struct TabStoreTests {
  @Test("Opening a session's chat twice focuses the first tab; new tabs open after the selection")
  func openAndFocus() {
    let store = TabStore()
    let first = store.open(.chat(sessionID: "s1"))
    let second = store.open(.chat(sessionID: "s2"))
    let again = store.open(.chat(sessionID: "s1"))
    #expect(again.id == first.id)
    #expect(store.selectedID == first.id)
    store.open(.terminal(sessionID: "s1", terminalID: "t1"))
    #expect(
      store.tabs.map(\.content) == [
        .chat(sessionID: "s1"), .terminal(sessionID: "s1", terminalID: "t1"),
        .chat(sessionID: "s2"),
      ])
    #expect(store.tab(second.id) != nil)
    // Two new-tab pages and two browser pages are separate tabs.
    store.open(.newTab)
    store.open(.newTab)
    #expect(store.tabs.count { $0.content == .newTab } == 2)
  }

  @Test("Closing a shell tab asks first and is not offered to Reopen; other tabs close at once")
  func closeShell() {
    let store = TabStore()
    store.open(.chat(sessionID: "s1"))
    let shell = store.open(.terminal(sessionID: "s1", terminalID: "t1"))
    let side = store.open(.sideChat(sessionID: "s1", rowID: "r"))
    store.requestClose(side.id)
    #expect(store.tab(side.id) == nil)
    store.requestClose(shell.id)
    #expect(store.closingShell == shell.id)
    #expect(store.tab(shell.id) != nil, "the shell waits for the confirmation")
    let ended = store.closeShell(shell.id)
    #expect(ended?.sessionID == "s1" && ended?.terminalID == "t1")
    #expect(store.tab(shell.id) == nil)
    #expect(store.closingShell == nil)
    #expect(!store.closed.contains { $0.id == shell.id })
  }

  @Test("Navigating from the new-tab page replaces it; a session open elsewhere is focused")
  func navigate() {
    let store = TabStore()
    let chat = store.open(.chat(sessionID: "s1"))
    let blank = store.open(.newTab)
    store.navigate(to: .chat(sessionID: "s2"))
    #expect(store.tab(blank.id)?.content == .chat(sessionID: "s2"))
    store.open(.newTab)
    store.navigate(to: .chat(sessionID: "s1"))
    #expect(store.selectedID == chat.id)
    #expect(!store.tabs.contains { $0.content == .newTab }, "the blank tab gave way to s1")
  }

  @Test("Closing selects the tab to the right, else the left; Reopen restores it in place")
  func closeAndReopen() throws {
    let store = TabStore()
    let tabA = store.open(.sideChat(sessionID: "a", rowID: "r"), placement: .end)
    let tabB = store.open(.sideChat(sessionID: "b", rowID: "r"), placement: .end)
    let tabC = store.open(.sideChat(sessionID: "c", rowID: "r"), placement: .end)
    store.select(tabB.id)
    store.close(tabB.id)
    #expect(store.selectedID == tabC.id)
    store.close(tabC.id)
    #expect(store.selectedID == tabA.id)
    #expect(store.closed.map(\.id) == [tabB.id, tabC.id])
    let reopened = try #require(store.reopenClosed())
    #expect(reopened.id == tabC.id)
    #expect(store.selectedID == tabC.id)
    #expect(store.closed.map(\.id) == [tabB.id])
    // A closed new-tab page is not worth reopening.
    let blank = store.open(.newTab)
    store.close(blank.id)
    #expect(store.closed.map(\.id) == [tabB.id])
  }

  @Test("Pinned tabs stay first, and moves stay within their group")
  func pinAndReorder() {
    let store = TabStore()
    let tabA = store.open(.sideChat(sessionID: "a", rowID: "r"), placement: .end)
    let tabB = store.open(.sideChat(sessionID: "b", rowID: "r"), placement: .end)
    let tabC = store.open(.sideChat(sessionID: "c", rowID: "r"), placement: .end)
    store.setPinned(tabC.id, true)
    #expect(store.tabs.map(\.id) == [tabC.id, tabA.id, tabB.id])
    store.move(tabA.id, to: 0)
    #expect(
      store.tabs.map(\.id) == [tabC.id, tabA.id, tabB.id],
      "an unpinned tab cannot pass a pinned one")
    store.move(tabB.id, to: 1)
    #expect(store.tabs.map(\.id) == [tabC.id, tabB.id, tabA.id])
    store.setPinned(tabC.id, false)
    #expect(store.tabs.map(\.id) == [tabC.id, tabB.id, tabA.id])
    #expect(store.tabs.allSatisfy { !$0.isPinned })
    // Close Others keeps pinned tabs.
    store.setPinned(tabA.id, true)
    store.closeOthers(tabB.id)
    #expect(store.tabs.map(\.id) == [tabA.id, tabB.id])
  }

  @Test("Command-1 through 8 select by position, Command-9 the last; cycling wraps")
  func selectByPosition() {
    let store = TabStore()
    let ids = (0..<4).map { store.open(.chat(sessionID: "s\($0)"), placement: .end).id }
    store.select(position: 0)
    #expect(store.selectedID == ids[0])
    store.select(position: 8)
    #expect(store.selectedID == ids[3])
    store.selectNext()
    #expect(store.selectedID == ids[0])
    store.selectPrevious()
    #expect(store.selectedID == ids[3])
    store.select(position: 6)
    #expect(store.selectedID == ids[3], "a position past the end selects nothing new")
  }

  @Test("Duplicate copies the tab next to it; Close Tabs to the Right keeps the left side")
  func duplicateAndCloseRight() throws {
    let store = TabStore()
    let tabA = store.open(.sideChat(sessionID: "a", rowID: "r"), placement: .end)
    store.open(.sideChat(sessionID: "b", rowID: "r"), placement: .end)
    let copy = try #require(store.duplicate(tabA.id))
    #expect(
      store.tabs.map(\.content) == [
        .sideChat(sessionID: "a", rowID: "r"), .sideChat(sessionID: "a", rowID: "r"),
        .sideChat(sessionID: "b", rowID: "r"),
      ])
    #expect(store.selectedID == copy.id)
    store.closeToRight(tabA.id)
    #expect(store.tabs.map(\.id) == [tabA.id])
    // A browser tab duplicates only with a new page from the browser host.
    let page = store.open(.browser(browserID: UUID()))
    #expect(store.duplicate(page.id) == nil)
    let other = UUID()
    let pageCopy = try #require(store.duplicate(page.id, browser: (other, Data("s".utf8))))
    #expect(pageCopy.content == .browser(browserID: other))
    #expect(pageCopy.browserState == Data("s".utf8))
  }

  @Test("Tearing off removes the tab without remembering it; the other window adopts it")
  func tearOff() throws {
    let source = TabStore()
    let tabA = source.open(.chat(sessionID: "a"))
    let shell = source.open(.terminal(sessionID: "a", terminalID: "t"))
    var closedPages: [String] = []
    source.willClose = { tab in
      closedPages.append(tab.id)
      return tab
    }
    let moved = try #require(source.detach(shell.id))
    #expect(source.tabs.map(\.id) == [tabA.id])
    #expect(source.closed.isEmpty)
    #expect(closedPages.isEmpty, "a torn-off tab keeps its live content")
    let target = TabStore()
    target.adopt([moved])
    #expect(target.tabs.map(\.id) == [shell.id])
    #expect(target.selectedID == shell.id)
    #expect(target.materialized == [shell.id])
  }

  @Test("Closing a browser tab lets the host keep the page's final state for Reopen")
  func browserClose() throws {
    let store = TabStore()
    store.willClose = { tab in
      var tab = tab
      tab.browserState = Data("final".utf8)
      return tab
    }
    let page = store.open(.browser(browserID: UUID()), browserState: Data("first".utf8))
    store.close(page.id)
    let reopened = try #require(store.reopenClosed())
    #expect(reopened.browserState == Data("final".utf8))
  }

  @Test("Restored tabs build only when selected, and keep their sessions out until then")
  func lazyRestore() {
    let tabs = [
      AppTab(id: "1", content: .chat(sessionID: "a"), isPinned: true),
      AppTab(id: "2", content: .terminal(sessionID: "b", terminalID: "t"), title: "zsh"),
      AppTab(id: "3", content: .browser(browserID: UUID()), title: "Docs"),
    ]
    let store = TabStore(TabWindowSnapshot(tabs: tabs, selectedID: "2"))
    #expect(store.materialized == ["2"])
    #expect(store.liveSessionIDs == ["b"])
    store.select("1")
    #expect(store.liveSessionIDs == ["a", "b"])
    store.close("2")
    #expect(store.liveSessionIDs == ["a"])
  }

  @Test("Every change notifies the window so it can save")
  func changeNotifications() {
    let store = TabStore()
    var changes = 0
    store.onChange = { changes += 1 }
    let tabA = store.open(.sideChat(sessionID: "a", rowID: "r"))
    store.open(.chat(sessionID: "b"))
    store.setPinned(tabA.id, true)
    store.close(tabA.id)
    store.reopenClosed()
    #expect(changes == 5)
  }
}

@Suite("Tab titles and terminals")
struct TabAdapterTitleTests {
  @Test("A browser tab shows its page title, else its host, never blank")
  func pageTitle() {
    let url = URL(string: "https://www.example.com/docs")
    #expect(TabAdapter.pageTitle("Docs", url: url) == "Docs")
    #expect(TabAdapter.pageTitle("  ", url: url) == "example.com")
    #expect(TabAdapter.pageTitle("", url: nil) == "Browser")
  }

  @Test("New Terminal offers the declared names, the default while unknown, none when empty")
  func declaredTerminals() {
    #expect(DeclaredTerminals.unknown.choices == [ServerSession.defaultTerminalName])
    #expect(DeclaredTerminals.names(["zsh", "bash"]).choices == ["zsh", "bash"])
    #expect(DeclaredTerminals.names([]).choices.isEmpty)
  }
}
