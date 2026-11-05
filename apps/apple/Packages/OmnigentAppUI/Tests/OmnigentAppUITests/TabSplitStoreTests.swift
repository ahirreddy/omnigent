import Foundation
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@Suite("Primary chats")
struct PrimaryChatTests {
  @Test("A session's primary chat cannot be closed, torn off, duplicated or bulk-closed")
  func notClosable() {
    let store = TabStore()
    let chat = store.open(.chat(sessionID: "s1"))
    let shell = store.open(.terminal(sessionID: "s1", terminalID: "t1"))
    let page = store.open(.browser(browserID: UUID()))
    #expect(!store.canClose(chat.id))
    #expect(store.canClose(shell.id))
    store.close(chat.id)
    #expect(store.tab(chat.id) != nil)
    #expect(store.detach(chat.id) == nil, "tearing it off would close it here")
    #expect(store.duplicate(chat.id) == nil)
    store.closeOthers(page.id)
    #expect(store.tabs.map(\.id) == [chat.id, page.id], "Close Other Tabs keeps the chat")
    store.closeToRight(page.id)
    store.select(chat.id)
    store.closeToRight(chat.id)
    #expect(store.tabs.map(\.id) == [chat.id])
    store.closeAll { _ in true }
    #expect(store.tabs.map(\.id) == [chat.id])
    #expect(!store.closed.contains { $0.id == chat.id }, "never on the recently-closed stack")
  }

  @Test("Navigating from a primary chat opens beside it instead of replacing it")
  func notReplaced() {
    let store = TabStore()
    let chat = store.open(.chat(sessionID: "s1"))
    store.navigate(to: .chat(sessionID: "s2")) { _ in true }
    #expect(store.tab(chat.id)?.content == .chat(sessionID: "s1"))
    #expect(store.selected?.content == .chat(sessionID: "s2"))
    store.replace(chat.id, with: .inbox)
    #expect(store.tab(chat.id)?.content == .chat(sessionID: "s1"))
    #expect(store.tabs.contains { $0.content == .inbox })
  }

  @Test("It is selected and left like any tab; only its session's removal takes it away")
  func leavesWithSession() {
    let store = TabStore()
    let chat = store.open(.chat(sessionID: "s1"))
    store.open(.sideChat(sessionID: "s1", rowID: "r"))
    let other = store.open(.chat(sessionID: "s2"))
    let gone = store.open(.terminal(sessionID: "s1", terminalID: "t"))
    store.close(gone.id)
    store.select(other.id)
    #expect(store.selectedID == other.id, "focus moves away freely")
    store.removeSessions(["s1"])
    #expect(store.tab(chat.id) == nil)
    #expect(store.tabs.map(\.id) == [other.id])
    #expect(store.closed.isEmpty, "a removed session's tabs are not reopenable")
    // Saved files from before keep no primary chat on the closed stack.
    let restored = TabStore(
      TabWindowSnapshot(tabs: [], closed: [AppTab(content: .chat(sessionID: "s3"))]))
    #expect(restored.closed.isEmpty)
  }

  @Test("The primary chat leads its session's tabs and carries them when moved")
  func leadsSession() {
    let store = TabStore()
    let chat = store.open(.chat(sessionID: "s1"), placement: .end)
    let shell = store.open(.terminal(sessionID: "s1", terminalID: "t"), placement: .end)
    let page = store.open(.browser(browserID: UUID()), placement: .end)
    store.move(shell.id, to: 0)
    #expect(store.tabs.map(\.id) == [chat.id, shell.id, page.id], "the shell cannot pass it")
    store.move(chat.id, to: 1)
    #expect(store.tabs.map(\.id) == [page.id, chat.id, shell.id], "the chat brings its shell")
    store.move(chat.id, to: 0)
    #expect(store.tabs.map(\.id) == [chat.id, shell.id, page.id])
    // A session tab restored ahead of its chat follows it.
    let restored = TabStore(
      TabWindowSnapshot(tabs: [
        AppTab(id: "t", content: .terminal(sessionID: "s", terminalID: "t")),
        AppTab(id: "c", content: .chat(sessionID: "s")),
      ]))
    #expect(restored.tabs.map(\.id) == ["c", "t"])
  }

  @Test("Only the primary chat and its terminals offer Show Terminal")
  func terminalViewOnlyOnPrimaryChat() {
    #expect(WindowTabs.offersTerminal(.chat(sessionID: "s")))
    #expect(WindowTabs.offersTerminal(.harness(sessionID: "s")))
    #expect(WindowTabs.offersTerminal(.terminal(sessionID: "s", terminalID: "t")))
    #expect(!WindowTabs.offersTerminal(.sideChat(sessionID: "s", rowID: "r")))
    #expect(!WindowTabs.offersTerminal(.agentBrowser(sessionID: "s")))
    #expect(!WindowTabs.offersTerminal(.browser(browserID: UUID())))
  }

  @Test("Close Tab and Show Terminal are off on a side chat; Close Tab off on a primary chat")
  func commands() throws {
    let session = try ServerSession.demo()
    let tabs = WindowTabs(
      session: session, context: TabWindowContext(), showAll: {}, fail: { _ in })
    session.tabs.open(.chat(sessionID: "s1"))
    #expect(tabs.commands.closeTab == nil)
    #expect(tabs.commands.toggleTerminal != nil)
    session.tabs.open(.sideChat(sessionID: "s1", rowID: "r"))
    #expect(tabs.commands.closeTab != nil)
    #expect(tabs.commands.toggleTerminal == nil)
    #expect(
      TabAdapter.state(session.tabs, session: session, browser: nil, issue: nil).tabs.map(
        \.isClosable) == [false, true])
  }
}

@Suite("Tab split view")
struct TabSplitStoreTests {
  /// A chat, a browser page and another session's side chat, the chat selected.
  private struct Three {
    let store = TabStore()
    let chat: AppTab
    let page: AppTab
    let side: AppTab

    init() {
      chat = store.open(.chat(sessionID: "s1"), placement: .end)
      page = store.open(.browser(browserID: UUID()), placement: .end)
      side = store.open(.sideChat(sessionID: "s2", rowID: "r"), placement: .end)
      store.select(chat.id)
    }
  }

  @Test("Showing a tab in the right pane splits the window; each pane keeps its own tab")
  func split() throws {
    let three = Three()
    let store = three.store
    let chat = three.chat
    let page = three.page
    let side = three.side
    store.show(page.id, in: .trailing)
    let state = try #require(store.splitState)
    #expect(state.leadingID == chat.id)
    #expect(state.trailingID == page.id)
    #expect(state.focused == .trailing)
    #expect(store.selectedID == page.id)
    #expect(store.materialized.isSuperset(of: [chat.id, page.id]))
    #expect(store.pane(of: side.id) == .leading)
    #expect(store.tabs.map(\.id) == [chat.id, side.id, page.id], "the left pane's tabs first")
    // Selecting a tab of the other pane focuses that pane and keeps this one's tab.
    store.select(side.id)
    #expect(store.splitState?.focused == .leading)
    #expect(store.splitState?.leadingID == side.id)
    #expect(store.splitState?.trailingID == page.id)
    store.focus(.trailing)
    #expect(store.selectedID == page.id)
    // A new tab opens in the focused pane.
    let blank = store.open(.newTab)
    #expect(store.pane(of: blank.id) == .trailing)
  }

  @Test("Moving a pane's last tab away, or closing it, goes back to one pane")
  func collapse() {
    let three = Three()
    let store = three.store
    let chat = three.chat
    let page = three.page
    let side = three.side
    store.show(page.id, in: .trailing)
    store.show(side.id, in: .trailing)
    #expect(store.pane(of: side.id) == .trailing)
    #expect(store.splitState?.trailingID == side.id)
    store.close(side.id)
    #expect(store.splitState?.trailingID == page.id, "the pane shows its other tab")
    store.close(page.id)
    #expect(store.split == nil)
    #expect(store.selectedID == chat.id)
    // A primary chat moves between panes too; moving it back closes the emptied pane.
    store.open(.inbox)
    store.show(chat.id, in: .trailing)
    #expect(store.pane(of: chat.id) == .trailing)
    store.show(chat.id, in: .leading)
    #expect(store.split == nil)
  }

  @Test("Splitting a single tab adds a new-tab page; Show Split View pairs the next tab")
  func toggle() {
    let store = TabStore()
    let chat = store.open(.chat(sessionID: "s1"))
    store.toggleSplit()
    #expect(store.splitState?.leadingID == chat.id)
    #expect(store.selected?.content == .newTab, "the new pane has focus to choose its tab")
    store.toggleSplit()
    #expect(store.split == nil)
    let three = Three()
    let paired = three.store
    let first = three.chat
    let page = three.page
    paired.toggleSplit()
    #expect(paired.splitState?.leadingID == first.id)
    #expect(paired.splitState?.trailingID == page.id)
    #expect(paired.selectedID == first.id, "focus stays where it was")
  }

  @Test("The divider's share is kept in range")
  func fraction() {
    let three = Three()
    let store = three.store
    let page = three.page
    store.setSplitFraction(0.4)
    #expect(store.split == nil, "nothing to resize without a split")
    store.show(page.id, in: .trailing)
    store.setSplitFraction(0.05)
    #expect(store.splitState?.fraction == TabSplitState.fractionRange.lowerBound)
    store.setSplitFraction(0.6)
    #expect(store.splitState?.fraction == 0.6)
  }

  @Test("The split stays in the model at compact widths, so the panes come back")
  func compactKeepsSplit() throws {
    let session = try ServerSession.demo()
    let page = session.tabs.open(.browser(browserID: UUID()))
    session.tabs.open(.chat(sessionID: "s1"))
    session.tabs.show(page.id, in: .trailing)
    let compact = WindowTabs(
      session: session, context: TabWindowContext(), showAll: {}, fail: { _ in },
      supportsSplit: false)
    #expect(compact.actions.showInPane == nil, "no split items at compact width")
    #expect(!compact.commands.supportsSplit)
    #expect(session.tabs.split != nil, "the layout waits for the window to widen")
    let wide = WindowTabs(
      session: session, context: TabWindowContext(), showAll: {}, fail: { _ in })
    #expect(wide.actions.showInPane != nil)
    #expect(wide.commands.isSplit)
    #expect(wide.commands.focusPane != nil)
  }

  @Test("The split survives a relaunch: panes, focus and divider")
  func persistence() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "omnigent-split-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer {
      do {
        try FileManager.default.removeItem(at: folder)
      } catch {
        Issue.record(error, "could not remove \(folder.path)")
      }
    }
    let server = "https://omnigent.example"
    let three = Three()
    let store = three.store
    let chat = three.chat
    let page = three.page
    store.show(page.id, in: .trailing)
    store.setSplitFraction(0.35)
    store.focus(.leading)
    let writer = TabPersistence(directory: folder, debounce: .milliseconds(1))
    writer.register(window: UUID(), server: server) { store.snapshot }
    writer.flush()
    let reader = TabPersistence(directory: folder)
    let saved = try #require(reader.claim(window: UUID(), server: server))
    #expect(saved == store.snapshot)
    let restored = TabStore(saved)
    #expect(restored.splitState == store.splitState)
    #expect(restored.selectedID == chat.id)
    #expect(restored.materialized == [chat.id, page.id], "both panes' tabs build")
  }

  @Test("A split from a newer app, or a broken one, restores the tabs in one pane")
  func lenientSplit() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "omnigent-split-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer {
      do {
        try FileManager.default.removeItem(at: folder)
      } catch {
        Issue.record(error, "could not remove \(folder.path)")
      }
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let server = "https://omnigent.example/"
    func record(_ split: String) -> String {
      """
      {"window": "\(UUID().uuidString)", "launch": "\(UUID().uuidString)",
        "savedAt": "2026-11-01T10:00:00Z", "selectedID": "a", "closed": [], "split": \(split),
        "tabs": [
          {"id": "a", "isPinned": false, "content": {"chat": {"sessionID": "s"}}},
          {"id": "b", "isPinned": false, "content": {"inbox": {}}}
        ]}
      """
    }
    let newer = record(
      #"{"version": 9, "trailingIDs": ["b"], "focused": "leading", "fraction": 0.5}"#)
    let json = #"{"version": 1, "server": "\#(server)", "windows": [\#(newer)]}"#
    let file = folder.appending(path: "\(TabPersistence.key(server)).json")
    try Data(json.utf8).write(to: file)
    let reader = TabPersistence(directory: folder)
    let saved = try #require(reader.claim(window: UUID(), server: server))
    #expect(saved.tabs.map(\.id) == ["a", "b"])
    #expect(saved.split == nil)
    #expect(reader.issue?.description.contains("newer version") == true)

    let broken = record(#"{"version": 1, "trailingIDs": "b"}"#)
    try Data(#"{"version": 1, "server": "\#(server)", "windows": [\#(broken)]}"#.utf8).write(
      to: file)
    let second = TabPersistence(directory: folder)
    let kept = try #require(second.claim(window: UUID(), server: server))
    #expect(kept.tabs.count == 2)
    #expect(kept.split == nil)
    // A pane whose tabs did not restore leaves one pane.
    let orphan = TabStore(
      TabWindowSnapshot(
        tabs: [AppTab(id: "a", content: .inbox)],
        split: TabSplitSnapshot(
          trailingIDs: ["gone"], focused: .trailing, otherSelectedID: nil, fraction: 0.5)))
    #expect(orphan.split == nil)
    #expect(orphan.selectedID == "a")
  }
}

@Suite("Session tab lifecycle")
struct SessionTabsLifecycleTests {
  @Test("Deleted and newly archived sessions lose their tabs; unarchived ones keep them")
  func departed() {
    let gone = SessionTabsLifecycle.departed(
      previous: ["kept": false, "deleted": false, "archived": false, "old": true],
      current: ["kept": false, "archived": true, "old": false])
    #expect(gone == ["deleted", "archived"])
  }
}

@Suite("Sub-agents beside the chat")
struct OpenBesideTests {
  @Test("A sub-agent opens in the pane beside the selected chat, splitting the window")
  func opensBeside() {
    let store = TabStore()
    let parent = store.open(.chat(sessionID: "parent"))
    store.openBeside(.chat(sessionID: "child"))
    let child = store.tabs.first { $0.content == .chat(sessionID: "child") }
    #expect(store.pane(of: parent.id) == .leading)
    #expect(child.map { store.pane(of: $0.id) } == .trailing)
    #expect(store.selected?.id == child?.id)
    // From the right pane, the next one opens on the left.
    store.openBeside(.chat(sessionID: "grandchild"))
    let grandchild = store.tabs.first { $0.content == .chat(sessionID: "grandchild") }
    #expect(grandchild.map { store.pane(of: $0.id) } == .leading)
  }

  @Test("Only web pages open in the in-app browser")
  func inAppLinks() throws {
    #expect(WindowTabs.opensInApp(try #require(URL(string: "https://example.com/a"))))
    #expect(WindowTabs.opensInApp(try #require(URL(string: "HTTP://example.com"))))
    #expect(!WindowTabs.opensInApp(try #require(URL(string: "mailto:a@example.com"))))
    #expect(!WindowTabs.opensInApp(try #require(URL(string: "file:///tmp/a"))))
  }
}
