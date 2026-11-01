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
    let tabA = store.open(.chat(sessionID: "a"), placement: .end)
    let tabB = store.open(.chat(sessionID: "b"), placement: .end)
    let tabC = store.open(.chat(sessionID: "c"), placement: .end)
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
    let tabA = store.open(.chat(sessionID: "a"), placement: .end)
    let tabB = store.open(.chat(sessionID: "b"), placement: .end)
    let tabC = store.open(.chat(sessionID: "c"), placement: .end)
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
    let tabA = store.open(.chat(sessionID: "a"), placement: .end)
    store.open(.chat(sessionID: "b"), placement: .end)
    let copy = try #require(store.duplicate(tabA.id))
    #expect(
      store.tabs.map(\.content) == [
        .chat(sessionID: "a"), .chat(sessionID: "a"), .chat(sessionID: "b"),
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
    let tabA = store.open(.chat(sessionID: "a"))
    store.open(.chat(sessionID: "b"))
    store.setPinned(tabA.id, true)
    store.close(tabA.id)
    store.reopenClosed()
    #expect(changes == 5)
  }
}

@Suite("Tab persistence")
struct TabPersistenceTests {
  private func directory() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "omnigent-tabs-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private let server = "https://omnigent.example/"

  private func remove(_ folder: URL) {
    do {
      try FileManager.default.removeItem(at: folder)
    } catch CocoaError.fileNoSuchFile {
      // Nothing was written.
    } catch {
      Issue.record(error, "could not remove \(folder.path)")
    }
  }

  @Test("A window's tabs survive a relaunch, in order, pinned, selected and with closed tabs")
  func roundTrip() throws {
    let folder = directory()
    defer { remove(folder) }
    let window = UUID()
    let first = TabPersistence(directory: folder, debounce: .milliseconds(1))
    #expect(first.claim(window: window, server: server) == nil)
    let store = TabStore()
    let chat = store.open(.chat(sessionID: "s1"))
    store.open(.terminal(sessionID: "s1", terminalID: "t1"), title: "zsh")
    let page = store.open(.browser(browserID: UUID()), browserState: Data("page".utf8))
    store.setPinned(chat.id, true)
    let gone = store.open(.sideChat(sessionID: "s1", rowID: "r1"), title: "Why?")
    store.close(gone.id)
    store.select(page.id)
    first.register(window: window, server: server) { store.snapshot }
    first.flush()
    #expect(first.issue == nil)

    // A new launch with a new window id (window restoration off) adopts the saved window.
    let second = TabPersistence(directory: folder)
    let relaunched = UUID()
    let saved = try #require(second.claim(window: relaunched, server: server))
    #expect(saved == store.snapshot)
    let restored = TabStore(saved)
    #expect(restored.tabs.map(\.content) == store.tabs.map(\.content))
    #expect(restored.tabs.first?.isPinned == true)
    #expect(restored.selectedID == page.id)
    #expect(restored.closed.map(\.id) == [gone.id])
    #expect(restored.materialized == [page.id], "only the selected tab builds")
    // A second window in the same launch gets a fresh strip.
    #expect(second.claim(window: UUID(), server: server) == nil)
  }

  @Test("A restored window claims its own record; another server's tabs stay separate")
  func ownRecordAndServers() throws {
    let folder = directory()
    defer { remove(folder) }
    let window = UUID()
    let writer = TabPersistence(directory: folder, debounce: .milliseconds(1))
    let tabA = TabStore()
    tabA.open(.chat(sessionID: "a"))
    let tabB = TabStore()
    tabB.open(.inbox)
    writer.register(window: window, server: server) { tabA.snapshot }
    writer.register(window: window, server: "https://other.example") { tabB.snapshot }
    writer.flush()
    let reader = TabPersistence(directory: folder)
    #expect(
      reader.claim(window: window, server: server)?.tabs.map(\.content) == [.chat(sessionID: "a")])
    #expect(
      reader.claim(window: window, server: "https://OTHER.example/")?.tabs.map(\.content) == [
        .inbox
      ])
  }

  @Test("Closing a window drops its saved tabs; quitting keeps them")
  func windowClose() {
    let folder = directory()
    defer { remove(folder) }
    let kept = UUID()
    let closed = UUID()
    let writer = TabPersistence(directory: folder, debounce: .milliseconds(1))
    let store = TabStore()
    store.open(.canvas)
    writer.register(window: kept, server: server) { store.snapshot }
    writer.register(window: closed, server: server) { store.snapshot }
    writer.flush()
    writer.windowClosed(closed)
    let reader = TabPersistence(directory: folder)
    #expect(reader.claim(window: closed, server: server) != nil, "the kept window is adopted")
    #expect(reader.claim(window: UUID(), server: server) == nil, "the closed window is gone")
  }

  @Test("Debounced saves land after the interval, and a write reads the latest tabs")
  func debounce() async throws {
    let folder = directory()
    defer { remove(folder) }
    let window = UUID()
    let writer = TabPersistence(directory: folder, debounce: .milliseconds(20))
    let store = TabStore()
    writer.register(window: window, server: server) { store.snapshot }
    store.onChange = { writer.scheduleSave(server: server) }
    store.open(.chat(sessionID: "a"))
    store.open(.chat(sessionID: "b"))
    try await Task.sleep(for: .milliseconds(200))
    let reader = TabPersistence(directory: folder)
    let saved = try #require(reader.claim(window: window, server: server))
    #expect(saved.tabs.map(\.content) == [.chat(sessionID: "a"), .chat(sessionID: "b")])
  }

  @Test("A tab of an unknown kind is skipped and reported; the rest restore")
  func unknownKind() throws {
    let folder = directory()
    defer { remove(folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let window = UUID()
    let json = """
      {"version": 1, "server": "\(server)", "windows": [{
        "window": "\(window.uuidString)", "launch": "\(UUID().uuidString)",
        "savedAt": "2026-11-01T10:00:00Z", "selectedID": "b", "closed": [],
        "tabs": [
          {"id": "a", "isPinned": false, "content": {"hologram": {"sessionID": "x"}}},
          {"id": "b", "isPinned": false, "content": {"chat": {"sessionID": "s"}}}
        ]}]}
      """
    let file = folder.appending(path: "\(TabPersistence.key(server)).json")
    try Data(json.utf8).write(to: file)
    let reader = TabPersistence(directory: folder)
    let saved = try #require(reader.claim(window: UUID(), server: server))
    #expect(saved.tabs.map(\.id) == ["b"])
    #expect(reader.issue != nil)
  }

  @Test("An unreadable file is reported and left alone")
  func unreadable() throws {
    let folder = directory()
    defer { remove(folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "\(TabPersistence.key(server)).json")
    try Data("not json".utf8).write(to: file)
    let persistence = TabPersistence(directory: folder, debounce: .milliseconds(1))
    #expect(persistence.claim(window: UUID(), server: server) == nil)
    #expect(persistence.issue != nil)
    persistence.register(window: UUID(), server: server) { TabWindowSnapshot() }
    persistence.flush()
    let contents = try Data(contentsOf: file)
    #expect(contents == Data("not json".utf8))
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
