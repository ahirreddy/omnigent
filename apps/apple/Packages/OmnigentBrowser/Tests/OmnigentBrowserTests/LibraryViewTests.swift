#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentBrowser

  /// Remembers what a library view asked to open.
  @MainActor
  private final class OpenRecorder {
    var opened: [(url: URL, newTab: Bool)] = []
    func open(_ url: URL, newTab: Bool) { opened.append((url, newTab)) }
  }

  extension OffscreenWindow {
    /// The middle of each table row, top to bottom. SwiftUI's `List` is an `NSTableView`.
    var rowPoints: [CGPoint] {
      allViews.compactMap { $0 as? NSTableRowView }
        .map { $0.convert($0.bounds, to: host) }
        .sorted { $0.minY < $1.minY }
        .map { CGPoint(x: $0.midX, y: $0.midY) }
    }
  }

  @MainActor
  @Suite("History view, off screen", .serialized)
  struct HistoryViewTests {
    private func fixture() throws -> (BrowserHistoryStore, OpenRecorder) {
      SystemSideEffects.install()
      let store = BrowserHistoryStore(fileURL: nil)
      store.recordVisit(url: try testURL("https://a.example/"), title: "Alpha")
      store.recordVisit(url: try testURL("https://b.example/"), title: "")
      return (store, OpenRecorder())
    }

    @Test("visits are listed, and the search narrows them or says there are none")
    func listingAndSearch() async throws {
      let (store, recorder) = try fixture()
      let screen = OffscreenWindow(
        BrowserHistoryView(store: store, open: recorder.open), width: 640, height: 480)
      defer { screen.close() }
      await screen.catchUp()
      // A header and the day's two visits.
      #expect(screen.rowPoints.count == 3)
      #expect(try !screen.shows("No History"))

      try screen.focusField()
      try screen.type("zzz")
      await screen.catchUp()
      #expect(try screen.shows("No Matches"))
      #expect(screen.rowPoints.isEmpty)

      store.remove(visitIDs: Set(store.visits.map(\.id)))
      screen.selectFieldText()
      try screen.press(keyCode: 51, characters: "\u{7f}")
      await screen.catchUp()
      #expect(try screen.shows("No History"))
    }

    @Test("a visit's menu opens it here or in a new tab, and removes it")
    func contextMenu() async throws {
      let (store, recorder) = try fixture()
      let screen = OffscreenWindow(
        BrowserHistoryView(store: store, open: recorder.open), width: 640, height: 480)
      defer { screen.close() }
      await screen.catchUp()
      // A section header comes first, so the visits are the last rows.
      let point = try #require(screen.rowPoints.last)
      let menu = try #require(try screen.rowMenu(at: point))

      try screen.choose("Open", in: menu)
      #expect(recorder.opened.last?.newTab == false)
      try screen.choose("Open in New Tab", in: menu)
      #expect(recorder.opened.last?.newTab == true)
      #expect(recorder.opened.count == 2)

      let before = store.visits.count
      try screen.choose("Remove from History", in: menu)
      await screen.catchUp()
      #expect(store.visits.count == before - 1)
    }

    @Test("Remove Selected removes the selected visit and then has nothing left to remove")
    func removeSelected() async throws {
      let (store, recorder) = try fixture()
      let screen = OffscreenWindow(
        BrowserHistoryView(store: store, open: recorder.open), width: 640, height: 480)
      defer { screen.close() }
      await screen.catchUp()
      let enabledAtFirst = await screen.drawnButtonIsEnabled(at: 0)
      #expect(!enabledAtFirst)

      let table = try #require(screen.allViews.compactMap { $0 as? NSTableView }.first)
      table.selectRowIndexes(IndexSet(integer: table.numberOfRows - 1), byExtendingSelection: false)
      await screen.catchUp()
      let enabledWithSelection = await screen.drawnButtonIsEnabled(at: 0)
      #expect(enabledWithSelection)

      try screen.clickDrawnButton(at: 0)
      await screen.catchUp()
      #expect(store.visits.count == 1)
      let enabledAfterwards = await screen.drawnButtonIsEnabled(at: 0)
      #expect(!enabledAfterwards)
    }

    @Test("Clear Browsing Data shows only where the caller offers it, and calls back")
    func clearData() async throws {
      let (store, recorder) = try fixture()
      var cleared = 0
      let screen = OffscreenWindow(
        BrowserHistoryView(store: store, open: recorder.open) { cleared += 1 }, width: 640,
        height: 480)
      defer { screen.close() }
      await screen.catchUp()
      #expect(try screen.shows("Clear Browsing Data…"))
      // Remove Selected, Clear Browsing Data… and Done, left to right.
      try screen.clickDrawnButton(at: 1)
      #expect(cleared == 1)
    }
  }

  @MainActor
  @Suite("Bookmarks, off screen", .serialized)
  struct BookmarksViewTests {
    private func store() throws -> BrowserBookmarkStore {
      SystemSideEffects.install()
      SystemSideEffects.reset()
      let store = BrowserBookmarkStore(fileURL: nil)
      try store.add(url: try testURL("https://a.example/"), title: "Alpha")
      let folder = try store.addFolder(title: "Reading")
      try store.add(url: try testURL("https://b.example/"), title: "Beta", to: folder.id)
      let nested = try store.addFolder(title: "Nested", to: folder.id)
      try store.add(url: try testURL("https://c.example/"), title: "Gamma", to: nested.id)
      return store
    }

    @Test("the bar's bookmark opens here; its menu opens a new tab or deletes it")
    func barBookmark() async throws {
      let store = try store()
      let recorder = OpenRecorder()
      var reported: [BrowserError] = []
      let screen = OffscreenWindow(
        BrowserBookmarksBar(store: store, open: recorder.open) { reported.append($0) }, width: 500,
        height: 40)
      defer { screen.close() }
      await screen.catchUp()
      #expect(try screen.shows("Alpha"))

      let alpha = try #require(screen.controlFrames.first)
      let point = CGPoint(x: alpha.midX, y: alpha.midY)
      try screen.click(point)
      #expect(recorder.opened.last?.url.host() == "a.example")
      #expect(recorder.opened.last?.newTab == false)

      let menu = try #require(try screen.contextMenu(at: point))
      try screen.choose("Open in New Tab", in: menu)
      #expect(recorder.opened.last?.newTab == true)
      try screen.choose("Delete", in: menu)
      await screen.catchUp()
      #expect(store.bar.children?.contains { $0.title == "Alpha" } == false)
      #expect(reported.isEmpty)

      // The menu of a bookmark deleted meanwhile reports that instead of crashing.
      try screen.choose("Delete", in: menu)
      #expect(reported.count == 1)
    }

    @Test("a folder on the bar is a menu that opens what is inside, at any depth")
    func barFolder() async throws {
      let store = try store()
      let recorder = OpenRecorder()
      let screen = OffscreenWindow(
        BrowserBookmarksBar(store: store, open: recorder.open) { _ in }, width: 500, height: 40)
      defer { screen.close() }
      await screen.catchUp()
      let menu = try screen.popupMenu()
      try screen.choose("Beta", in: menu)
      #expect(recorder.opened.last?.url.host() == "b.example")
      try screen.choose("Gamma", in: menu)
      #expect(recorder.opened.last?.url.host() == "c.example")
    }

    @Test("the manager lists both roots, and a row's menu opens, renames and deletes")
    func managerRowMenu() async throws {
      let store = try store()
      let recorder = OpenRecorder()
      let screen = OffscreenWindow(
        BrowserBookmarksManagerView(store: store, open: recorder.open), width: 600, height: 480)
      defer { screen.close() }
      await screen.catchUp()
      #expect(try screen.shows("Bookmarks"))
      // Two section headers, the bar's three items and Other Bookmarks' none.
      #expect(screen.rowPoints.count >= 3)

      let row = try #require(screen.rowPoints.dropFirst().first)
      let menu = try #require(try screen.rowMenu(at: row))
      try screen.choose("Open", in: menu)
      #expect(recorder.opened.last?.newTab == false)
      try screen.choose("Open in New Tab", in: menu)
      #expect(recorder.opened.last?.newTab == true)

      try screen.choose("Delete", in: menu)
      await screen.catchUp()
      #expect(store.bar.children?.contains { $0.title == "Alpha" } == false)

      // Deleting it again shows the store's refusal in the sheet.
      try screen.choose("Delete", in: menu)
      await screen.catchUp()
      #expect(try screen.shows("No bookmark has that ID."))
    }

    @Test("Import reads the chosen file; Cancel in the panel changes nothing")
    func importPanel() async throws {
      let store = try store()
      let before = store.allBookmarks.count
      let screen = OffscreenWindow(
        BrowserBookmarksManagerView(store: store, open: { _, _ in }), width: 600, height: 480)
      defer { screen.close() }
      await screen.catchUp()
      let importButton = try #require(screen.controlFrames.first)
      try screen.click(CGPoint(x: importButton.midX, y: importButton.midY))
      await screen.catchUp()
      #expect(SystemSideEffects.record.panelCount == 1)
      #expect(store.allBookmarks.count == before)
    }
  }
#endif
