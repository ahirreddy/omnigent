import Foundation
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@Suite("Tab persistence")
@MainActor
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

  /// A window's groups bound to `persistence` the way ``TabRestoration`` binds them.
  private func bind(
    _ groups: SessionTabGroups, window: UUID, to persistence: TabPersistence
  ) {
    let server = server
    groups.loadSaved = { persistence.savedTabs(session: $0, server: server, for: window) }
    groups.onRemove = { persistence.removeSessions($0, server: server) }
    persistence.register(
      window: window, server: server,
      snapshot: {
        TabWindowState(
          page: groups.page,
          groups: groups.groups.filter { $0.value.changedAt != nil }.mapValues {
            TabGroupState(snapshot: $0.snapshot, changedAt: $0.changedAt)
          })
      },
      group: { id in
        groups.groups[id].map { TabGroupState(snapshot: $0.snapshot, changedAt: $0.changedAt) }
      })
    groups.onChange = { _ in persistence.scheduleSave(server: server) }
  }

  @Test("A session's tabs and the window's page survive a relaunch")
  func roundTrip() throws {
    let folder = directory()
    defer { remove(folder) }
    let window = UUID()
    let first = TabPersistence(directory: folder, debounce: .milliseconds(1))
    #expect(first.claim(window: window, server: server) == nil)
    let groups = SessionTabGroups()
    bind(groups, window: window, to: first)
    groups.show(.session("s1"))
    let store = try #require(groups.current)
    let chat = try #require(store.selected)
    store.open(.terminal(sessionID: "s1", terminalID: "t1"), title: "zsh")
    let page = store.open(.browser(browserID: UUID()), browserState: Data("page".utf8))
    store.setPinned(chat.id, true)
    let gone = store.open(.sideChat(sessionID: "s1", rowID: "r1"), title: "Why?")
    store.close(gone.id)
    store.select(page.id)
    groups.show(.inbox)
    first.flush()
    #expect(first.issue == nil)

    // A new launch with a new window id (window restoration off) adopts the saved window.
    let second = TabPersistence(directory: folder)
    let relaunched = UUID()
    #expect(second.claim(window: relaunched, server: server) == .inbox)
    let restored = SessionTabGroups()
    bind(restored, window: relaunched, to: second)
    restored.show(.session("s1"))
    let group = try #require(restored.current)
    #expect(group.tabs.map(\.content) == store.tabs.map(\.content))
    #expect(group.tabs.first?.isPinned == true)
    #expect(group.selectedID == page.id, "the session comes back on its selected tab")
    #expect(group.closed.map(\.id) == [gone.id])
    #expect(group.materialized == [page.id], "only the selected tab builds")
    // A second window in the same launch starts on no page.
    #expect(second.claim(window: UUID(), server: server) == nil)
  }

  @Test("A session showing just its chat saves nothing, and going back to it clears its record")
  func defaultGroupsLeaveNoRecord() throws {
    let folder = directory()
    defer { remove(folder) }
    let window = UUID()
    let writer = TabPersistence(directory: folder, debounce: .milliseconds(1))
    let groups = SessionTabGroups()
    bind(groups, window: window, to: writer)
    groups.show(.session("plain"))
    groups.show(.session("busy"))
    let busy = try #require(groups.current)
    let shell = busy.open(.terminal(sessionID: "busy", terminalID: "t"))
    writer.flush()
    #expect(
      TabPersistence(directory: folder).savedTabs(session: "plain", server: server, for: UUID())
        == nil)
    #expect(
      TabPersistence(directory: folder).savedTabs(session: "busy", server: server, for: UUID())?
        .selectedID == shell.id)
    busy.closeShell(shell.id)
    busy.select(busy.tabs[0].id)
    writer.flush()
    #expect(
      TabPersistence(directory: folder).savedTabs(session: "busy", server: server, for: UUID())
        == nil)
  }

  @Test("Another window showing a session gets its newest tabs, live or saved")
  func sharedAcrossWindows() throws {
    let folder = directory()
    defer { remove(folder) }
    let persistence = TabPersistence(directory: folder, debounce: .seconds(60))
    let left = SessionTabGroups()
    let right = SessionTabGroups()
    let leftWindow = UUID()
    let rightWindow = UUID()
    bind(left, window: leftWindow, to: persistence)
    bind(right, window: rightWindow, to: persistence)
    left.show(.session("s"))
    let shell = try #require(left.current).open(.terminal(sessionID: "s", terminalID: "t"))
    // Not written yet: the right window reads the left one's live tabs.
    right.show(.session("s"))
    #expect(right.current?.tabs.map(\.content) == left.current?.tabs.map(\.content))
    #expect(right.current?.selectedID == shell.id)
    // The right window changes them last, so its tabs are the ones saved.
    try #require(right.current).select(try #require(right.current?.tabs.first).id)
    persistence.flush()
    let saved = TabPersistence(directory: folder).savedTabs(
      session: "s", server: server, for: UUID())
    #expect(saved?.selectedID == right.current?.tabs.first?.id)
  }

  @Test("Archived or deleted sessions lose their saved tabs")
  func removal() throws {
    let folder = directory()
    defer { remove(folder) }
    let writer = TabPersistence(directory: folder, debounce: .milliseconds(1))
    let groups = SessionTabGroups()
    bind(groups, window: UUID(), to: writer)
    groups.show(.session("s"))
    try #require(groups.current).open(.terminal(sessionID: "s", terminalID: "t"))
    writer.flush()
    groups.removeSessions(["s"])
    writer.flush()
    #expect(
      TabPersistence(directory: folder).savedTabs(session: "s", server: server, for: UUID()) == nil)
  }

  @Test("A restored window claims its own page; another server's stay separate")
  func ownRecordAndServers() {
    let folder = directory()
    defer { remove(folder) }
    let window = UUID()
    let writer = TabPersistence(directory: folder, debounce: .milliseconds(1))
    writer.register(window: window, server: server) { TabWindowState(page: .session("a")) }
    writer.register(window: window, server: "https://other.example") {
      TabWindowState(page: .inbox)
    }
    writer.flush()
    let reader = TabPersistence(directory: folder)
    #expect(reader.claim(window: window, server: server) == .session("a"))
    #expect(reader.claim(window: window, server: "https://OTHER.example/") == .inbox)
  }

  @Test("Closing a window drops its page, not its sessions' tabs; quitting keeps both")
  func windowClose() throws {
    let folder = directory()
    defer { remove(folder) }
    let kept = UUID()
    let closed = UUID()
    let writer = TabPersistence(directory: folder, debounce: .milliseconds(1))
    let groups = SessionTabGroups()
    bind(groups, window: closed, to: writer)
    groups.show(.session("s"))
    try #require(groups.current).open(.terminal(sessionID: "s", terminalID: "t"))
    writer.register(window: kept, server: server) { TabWindowState(page: .canvas) }
    writer.flush()
    writer.windowClosed(closed)
    let reader = TabPersistence(directory: folder)
    #expect(reader.claim(window: closed, server: server) == .canvas, "the kept window is adopted")
    #expect(reader.claim(window: UUID(), server: server) == nil, "the closed window is gone")
    #expect(reader.savedTabs(session: "s", server: server, for: UUID())?.tabs.count == 2)
  }

  @Test("Debounced saves land after the interval")
  func debounce() async throws {
    let folder = directory()
    defer { remove(folder) }
    let window = UUID()
    let writer = TabPersistence(directory: folder, debounce: .milliseconds(20))
    let groups = SessionTabGroups()
    bind(groups, window: window, to: writer)
    groups.show(.session("a"))
    groups.show(.usage)
    // Poll rather than sleep a fixed time: a busy or throttled machine delays the save.
    let deadline = ContinuousClock.now + .seconds(10)
    var saved = TabPersistence(directory: folder).claim(window: window, server: server)
    while saved != .usage, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
      saved = TabPersistence(directory: folder).claim(window: window, server: server)
    }
    #expect(saved == .usage, "the debounced save never landed")
  }

  @Test("Format-1 windows are grouped by session, an unknown tab skipped and reported")
  func migratesFormatOne() throws {
    let folder = directory()
    defer { remove(folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let window = UUID()
    let json = """
      {"version": 1, "server": "\(server)", "windows": [{
        "window": "\(window.uuidString)", "launch": "\(UUID().uuidString)",
        "savedAt": "2026-11-01T10:00:00Z", "selectedID": "t", "closed": [],
        "tabs": [
          {"id": "a", "isPinned": false, "content": {"hologram": {"sessionID": "x"}}},
          {"id": "b", "isPinned": false, "content": {"chat": {"sessionID": "s"}}},
          {"id": "t", "isPinned": false,
           "content": {"terminal": {"sessionID": "s", "terminalID": "zsh"}}},
          {"id": "c", "isPinned": false, "content": {"chat": {"sessionID": "u"}}}
        ]}]}
      """
    let file = folder.appending(path: "\(TabPersistence.key(server)).json")
    try Data(json.utf8).write(to: file)
    let reader = TabPersistence(directory: folder)
    #expect(reader.claim(window: UUID(), server: server) == .session("s"))
    let saved = try #require(reader.savedTabs(session: "s", server: server, for: UUID()))
    #expect(saved.tabs.map(\.id) == ["b", "t"])
    #expect(saved.selectedID == "t")
    #expect(reader.issue != nil, "the unknown tab is reported")
    #expect(
      reader.savedTabs(session: "u", server: server, for: UUID()) == nil,
      "a session with just its chat needs no record")
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
    persistence.register(window: UUID(), server: server) { TabWindowState(page: nil) }
    persistence.flush()
    let contents = try Data(contentsOf: file)
    #expect(contents == Data("not json".utf8))
  }
}
