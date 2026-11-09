import Foundation
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// What each menu command, tab strip action and conversation route does to the window's tabs.
@MainActor
@Suite("Tab commands", .timeLimit(.minutes(1)))
struct TabCommandWiringTests {
  private struct Window {
    let tabs: WindowTabs
    let session: ServerSession
    let store: TabStore
  }

  private func opened() throws -> Window {
    let session = try ServerSession.demo()
    let tabs = WindowTabs(
      session: session, context: TabWindowContext(browser: FakeBrowserHost()), showAll: {},
      fail: { _ in })
    session.tabs.showChat("s1")
    return Window(tabs: tabs, session: session, store: try #require(session.tabs.current))
  }

  @Test("New Tab, Close Tab and Pin Tab act on the selected tab")
  func newCloseAndPin() throws {
    let window = try opened()
    let (tabs, store) = (window.tabs, window.store)
    tabs.commands.newTab()
    #expect(store.selected?.content == .newTab)
    let added = try #require(store.selected)

    let pin = try #require(tabs.commands.togglePinned)
    pin()
    #expect(store.tabs.first { $0.id == added.id }?.isPinned == true)
    let unpin = try #require(tabs.commands.togglePinned)
    unpin()
    #expect(store.tabs.first { $0.id == added.id }?.isPinned == false)

    let close = try #require(tabs.commands.closeTab)
    close()
    #expect(!store.tabs.contains { $0.id == added.id })
    #expect(store.tabs.map(\.content) == [.chat(sessionID: "s1")])
  }

  @Test("Next and Previous Tab go round, and appear only with a second tab")
  func cycling() throws {
    let window = try opened()
    let (tabs, store) = (window.tabs, window.store)
    #expect(tabs.commands.selectNextTab == nil)
    let first = try #require(store.selected)
    store.open(.harness(sessionID: "s1"))
    let second = try #require(store.selected)
    let next = try #require(tabs.commands.selectNextTab)
    next()
    #expect(store.selected?.id == first.id, "past the last tab comes back to the first")
    let previous = try #require(tabs.commands.selectPreviousTab)
    previous()
    #expect(store.selected?.id == second.id)
  }

  @Test("Duplicate Tab copies a browser tab beside it")
  func duplicating() throws {
    let window = try opened()
    let (tabs, store) = (window.tabs, window.store)
    #expect(tabs.commands.duplicateTab == nil, "the primary chat has no copy")
    tabs.openBrowser(url: URL(string: "https://example.com"), in: "s1")
    let duplicate = try #require(tabs.commands.duplicateTab)
    duplicate()
    #expect(store.tabs.count == 3)
  }

  @Test("The split commands move the tab across, change focus and resize")
  func splitCommands() throws {
    let window = try opened()
    let (tabs, store) = (window.tabs, window.store)
    store.open(.harness(sessionID: "s1"))
    let harness = try #require(store.selected)
    let move = try #require(tabs.commands.moveTabToOtherPane)
    move()
    #expect(store.split != nil)
    #expect(store.pane(of: harness.id) == .trailing)

    let focus = try #require(tabs.commands.focusPane)
    focus(.leading)
    #expect(store.split?.focused == .leading)

    let actions = tabs.actions(store)
    actions.focusPane?(.trailing)
    #expect(store.split?.focused == .trailing)
    actions.setSplitFraction?(0.6)
    #expect(store.split?.fraction == TabSplitState.clamp(0.6))
    actions.showInPane?(harness.id, .leading)
    #expect(store.split == nil, "the pane it left is empty, so the window is whole again")
    actions.showInPane?(harness.id, .trailing)
    #expect(store.pane(of: harness.id) == .trailing)
    actions.closeSplit?()
    #expect(store.split == nil)
  }

  @Test("The strip's New Tab opens the New Tab page")
  func stripNewTab() throws {
    let window = try opened()
    let (tabs, store) = (window.tabs, window.store)
    tabs.actions(store).newTab()
    #expect(store.selected?.content == .newTab)
  }

  @Test("Show Terminal on an open terminal goes back to the chat")
  func toggleTerminal() throws {
    let window = try opened()
    let (tabs, store) = (window.tabs, window.store)
    store.open(.harness(sessionID: "s1"))
    let toggle = try #require(tabs.commands.toggleTerminal)
    toggle()
    #expect(store.selected?.content == .chat(sessionID: "s1"))
  }

  @Test("A conversation's routes open their tabs in that session's group")
  func routes() throws {
    let window = try opened()
    let session = window.session
    let routes = window.tabs.routes(for: "s2")
    let group = session.tabs.group("s2")

    routes.openHarness()
    #expect(group.selected?.content == .harness(sessionID: "s2"))
    routes.openTerminal("t1")
    #expect(group.selected?.content == .terminal(sessionID: "s2", terminalID: "t1"))
    routes.openSideChat("row", "Why")
    #expect(group.selected?.content == .sideChat(sessionID: "s2", rowID: "row"))
    #expect(group.selected?.title == "Why")

    routes.openSession("s3")
    #expect(session.tabs.page == .session("s3"))

    routes.openNewSideChat?("Draft", false)
    #expect(group.selected?.content == .sideChatSession(parentID: "s2", childID: nil))
    let tab = try #require(group.selected)
    #expect(session.sideChatDrafts.draft(tab.id).text == "Draft")

    routes.openBrowser?()
    #expect(group.tabs.contains { if case .browser = $0.content { true } else { false } })
  }
}
