import Foundation
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// What the strip does to its tabs beyond opening and closing them.
@MainActor
@Suite("Tab store details", .timeLimit(.minutes(1)))
struct TabStoreDetailTests {
  @Test("Restoring a window replaces its tabs and retires the ones that left")
  func restoring() {
    let store = TabStore()
    let leaving = store.open(.terminal(sessionID: "s1", terminalID: "t1"))
    var retired: [AppTabContent] = []
    store.willClose = { tab in
      retired.append(tab.content)
      return tab
    }
    let kept = AppTab(content: .inbox)
    store.restore(
      TabWindowSnapshot(tabs: [kept], selectedID: kept.id, closed: [], split: nil))
    #expect(store.tabs.map(\.id) == [kept.id])
    #expect(store.selectedID == kept.id)
    #expect(store.tab(leaving.id) == nil)
    #expect(retired == [leaving.content])
  }

  @Test("A saved split whose selections are in the wrong panes picks a tab in each")
  func aBrokenSplitSelection() {
    let left = AppTab(content: .inbox)
    let right = AppTab(content: .usage)
    let store = TabStore()
    store.restore(
      TabWindowSnapshot(
        tabs: [left, right], selectedID: right.id, closed: [],
        split: TabSplitSnapshot(
          trailingIDs: [right.id], focused: .leading, otherSelectedID: left.id, fraction: 0.4)))
    #expect(store.selectedID == left.id, "the focused pane's own tab")
    #expect(store.splitState?.activeID(.trailing) == right.id)
    #expect(store.splitState?.activeID(.leading) == left.id)
  }

  @Test("A tab's page reports its title and state; nothing new saves nothing")
  func recording() {
    let store = TabStore()
    let page = store.open(.browser(browserID: UUID()))
    var changes = 0
    store.onChange = { changes += 1 }
    store.record(page.id, title: "Docs", browserState: Data("state".utf8))
    #expect(store.tab(page.id)?.title == "Docs")
    #expect(store.tab(page.id)?.browserState == Data("state".utf8))
    #expect(changes == 1)

    store.record(page.id, title: "Docs")
    #expect(store.tab(page.id)?.browserState == Data("state".utf8), "a title alone keeps the state")
    #expect(changes == 1)
    store.record("gone", title: "Nothing")
    #expect(changes == 1)
    store.contentChanged()
    #expect(changes == 2)
  }

  @Test("Moving a tab to the pane it's in just selects it")
  func moveToTheSamePane() {
    let store = TabStore()
    let first = store.open(.inbox)
    let second = store.open(.usage)
    let third = store.open(.canvas)
    store.show(third.id, in: .trailing)
    store.select(first.id)
    store.show(second.id, in: .leading)
    #expect(store.selectedID == second.id)
    #expect(store.pane(of: second.id) == .leading)
  }

  @Test("Reopening a closed tab whose page is open again goes to that one")
  func reopeningAFocusedTab() {
    let store = TabStore()
    store.open(.chat(sessionID: "s1"))
    let inbox = store.open(.inbox)
    store.close(inbox.id)
    let again = store.open(.inbox)
    store.open(.usage)
    let reopened = store.reopenClosed()
    #expect(reopened?.id == again.id)
    #expect(store.selectedID == again.id)
    #expect(store.tabs.count(where: { $0.content == .inbox }) == 1)
  }

  @Test("The recently shown list forgets closed tabs once it's full")
  func recents() {
    let store = TabStore()
    let closing = store.open(.browser(browserID: UUID()))
    store.select(closing.id)
    store.close(closing.id)
    for _ in 0..<20 { store.open(.browser(browserID: UUID())) }
    #expect(!store.recentIDs.contains(closing.id))
    #expect(store.recentIDs.count <= 16)
    #expect(store.recentIDs.allSatisfy { store.tab($0) != nil })
  }

  @Test("A tab of any session can be selected or closed by its id")
  func acrossSessions() throws {
    let groups = SessionTabGroups()
    groups.show(.session("one"))
    let shell = try #require(groups.current).open(.terminal(sessionID: "one", terminalID: "t"))
    groups.show(.session("two"))
    groups.select(shell.id)
    #expect(groups.page == .session("one"))
    #expect(groups.current?.selectedID == shell.id)
    groups.close(shell.id)
    #expect(groups.groups["one"]?.tab(shell.id) == nil)

    groups.select("nothing")
    groups.close("nothing")
    #expect(groups.page == .session("one"), "an unknown tab changes nothing")
  }
}

/// Saved tabs that can't be used as they are, and a full store.
@MainActor
@Suite("Tab persistence limits", .timeLimit(.minutes(1)))
struct TabPersistenceLimitTests {
  private let server = "https://omnigent.example/"

  private func folder() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "omnigent-tabs-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func remove(_ folder: URL) {
    do {
      try FileManager.default.removeItem(at: folder)
    } catch {
      Issue.record(error, "could not remove \(folder.path)")
    }
  }

  private func register(
    _ persistence: TabPersistence, window: UUID, groups: SessionTabGroups
  ) {
    persistence.register(
      window: window, server: server,
      snapshot: {
        TabWindowState(
          page: groups.page,
          groups: groups.groups.mapValues {
            TabGroupState(snapshot: $0.snapshot, changedAt: $0.changedAt)
          })
      })
  }

  @Test("Tabs saved by a newer app are left alone and the window says so")
  func aNewerFile() throws {
    let directory = folder()
    defer { remove(directory) }
    let window = UUID()
    let first = TabPersistence(directory: directory, debounce: .milliseconds(1))
    let groups = SessionTabGroups()
    groups.show(.session("s1"))
    try #require(groups.current).open(.inbox)
    register(first, window: window, groups: groups)
    first.flush()
    let file = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
    var json = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    json["version"] = TabPersistence.version + 1
    let future = try JSONSerialization.data(withJSONObject: json)
    try future.write(to: file)

    let second = TabPersistence(directory: directory, debounce: .milliseconds(1))
    #expect(second.claim(window: UUID(), server: server) == nil)
    #expect(second.issue?.description.contains("newer version") == true)
    second.flush()
    #expect(try Data(contentsOf: file) == future, "a fix can still read it")
  }

  @Test("Past the limit the sessions changed longest ago lose their saved tabs")
  func theSessionLimit() throws {
    let directory = folder()
    defer { remove(directory) }
    let window = UUID()
    let persistence = TabPersistence(directory: directory, debounce: .milliseconds(1))
    let snapshot = TabWindowSnapshot(
      tabs: [AppTab(content: .inbox)], selectedID: nil, closed: [], split: nil)
    let base = Date(timeIntervalSince1970: 1_000)
    var states: [String: TabGroupState] = [:]
    for index in 0...TabPersistence.sessionLimit {
      states["s\(index)"] = TabGroupState(
        snapshot: snapshot, changedAt: base.addingTimeInterval(Double(index)))
    }
    persistence.register(
      window: window, server: server,
      snapshot: { TabWindowState(page: nil, groups: states) })
    persistence.flush()
    #expect(persistence.savedTabs(session: "s0", server: server, for: window) == nil)
    #expect(persistence.savedTabs(session: "s1", server: server, for: window) != nil)
  }

  @Test("Tabs that can't be written say so, and a later save clears it")
  func aFailedSave() throws {
    let directory = folder()
    defer { remove(directory) }
    try Data().write(to: directory)
    let window = UUID()
    let persistence = TabPersistence(directory: directory, debounce: .milliseconds(1))
    let groups = SessionTabGroups()
    register(persistence, window: window, groups: groups)
    persistence.flush()
    #expect(persistence.issue?.description.hasPrefix("Tabs could not be saved") == true)

    try FileManager.default.removeItem(at: directory)
    persistence.scheduleSave(server: server)
    persistence.flush()
    #expect(persistence.issue == nil)
  }

  @Test("The app's store lives under Application Support, the demo's apart")
  func applicationSupport() throws {
    let app = try TabPersistence.applicationSupport(bundleID: "ai.omnigent.tests")
    #expect(app.issue == nil)
    let base = try #require(URL(string: "file:///base/"))
    #expect(
      TabPersistence.directory(in: base, bundleID: "b", isDemo: false)
        != TabPersistence.directory(in: base, bundleID: "b", isDemo: true))
  }
}
